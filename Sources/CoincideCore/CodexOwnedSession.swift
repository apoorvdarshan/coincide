import Foundation

/// Runtime-only resources. Neither the opaque revision nor these closures belong
/// in configuration, workspace events, persistence, or diagnostic output.
public struct CodexOwnedSessionResource: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let session: any ProviderSession
    public let credentialRevision: UUID
    public let release: @Sendable () async -> Void
    public init(session: any ProviderSession, credentialRevision: UUID, release: @escaping @Sendable () async -> Void) {
        self.session = session; self.credentialRevision = credentialRevision; self.release = release
    }
    public var description: String { "CodexOwnedSessionResource(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct CodexOwnedSessionAccess: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let credentialRevision: UUID
    /// Broker-enforced single use, pinned to the credential already validated
    /// by acquireAccess; resolving must not perform another unbound refresh.
    public let resolve: @Sendable () async throws -> CodexOwnedSessionResource
    public let release: @Sendable () async -> Void
    public init(credentialRevision: UUID, resolve: @escaping @Sendable () async throws -> CodexOwnedSessionResource,
                release: @escaping @Sendable () async -> Void) {
        self.credentialRevision = credentialRevision; self.resolve = resolve; self.release = release
    }
    public var description: String { "CodexOwnedSessionAccess(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Lazy native Codex delegation for an exact captured owned-account binding.
/// The broker owns credential/network/home/installation work; initialization is inert.
public actor CodexOwnedSession: ProviderSession, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public typealias AcquireAccess = @Sendable () async throws -> CodexOwnedSessionAccess
    public typealias AccountSnapshot = @Sendable () async throws -> CodexAccountSnapshot
    public nonisolated let events: AsyncStream<ProviderEvent>
    public nonisolated var description: String { "CodexOwnedSession(redacted)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let configuration: CodexRuntimeConfiguration
    private let cwd: URL
    private let acquireAccess: AcquireAccess
    private let accountSnapshot: AccountSnapshot
    private struct Live: Sendable {
        let epoch: UUID
        let resource: CodexOwnedSessionResource
        let reader: Task<Void, Never>
    }
    private final class Launch {
        let id = UUID(), refresh: Bool
        var waiters: [UUID: CheckedContinuation<Live, any Error>] = [:]
        init(refresh: Bool) { self.refresh = refresh }
    }
    private struct Call: Sendable {
        let epoch: UUID?
        let cancel: @Sendable () -> Void
        let drain: Task<Void, Never>
    }
    private var live: Live?
    private var launch: Launch?
    // Keep the Sendable cleanup handle separate from actor-owned mutable
    // continuations so nonisolated deinit never reads the Launch holder.
    private var launchTask: Task<Void, Never>?
    private var calls: [UUID: Call] = [:]
    private var admission: UUID?
    private var preparingRunID: UUID?
    private struct Foreground { let token: UUID; let runID: UUID? }
    private var foreground: Foreground?
    private var activeRunID: UUID? { foreground?.runID }
    private var nativeTurnID: String?
    private var nativeThreadID: String?
    private var sessionRequests: Set<JSONValueID> = []
    private var activityID: UUID?
    private var blocked = false
    private var historyUncertain = false
    private var closing = false
    private var closeTask: Task<Void, Never>?
    // Approval IDs are arbitrary JSON values; encoding is private, bounded by
    // the already validated native request, and never used as auth identity.
    private struct JSONValueID: Hashable { let bytes: Data }

    public init(configuration: CodexRuntimeConfiguration, cwd: URL, acquireAccess: @escaping AcquireAccess,
                accountSnapshot: @escaping AccountSnapshot) {
        self.configuration = configuration; self.cwd = cwd; self.acquireAccess = acquireAccess; self.accountSnapshot = accountSnapshot
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation
    }
    public func models() async throws -> [ProviderModel] {
        let child = try await ensure(refresh: false)
        return try await call(epoch: child.epoch) { try await child.resource.session.models() }
    }
    public func openCodeInventory() async throws -> OpenCodeMetadataSnapshot {
        let child = try await ensure(refresh: false)
        return try await call(epoch: child.epoch) { try await child.resource.session.openCodeInventory() }
    }
    public func acpConnectionInfo() async throws -> ACPConnectionInfo {
        let child = try await ensure(refresh: false)
        return try await call(epoch: child.epoch) { try await child.resource.session.acpConnectionInfo() }
    }
    public func codexDefaultModelSelection() async throws -> CodexDefaultModelSelection {
        let child = try await ensure(refresh: false)
        return try await call(epoch: child.epoch) { try await child.resource.session.codexDefaultModelSelection() }
    }
    public func codexAccountSnapshot() async throws -> CodexAccountSnapshot {
        try validate()
        let read = accountSnapshot
        let value = try await call(epoch: nil) { try await read() }
        // Owned identity is supplied by the vault. Native CLI quota bars do not
        // describe the independently scoped token-sharing subscription.
        return .init(identity: value.identity, usage: .unsupported, checkedAt: value.checkedAt)
    }
    public func send(text: String, thread: CodingThread) async throws { try await send(input: .init(text: text), thread: thread) }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        try validate()
        guard !historyUncertain else { throw ProviderHistoryError(.outcomeUncertain) }
        guard !busy, admission == nil else { throw CoincideError("A Codex turn or history operation is already running.") }
        let captured = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        try validate(captured)
        let id = UUID(); admission = id; preparingRunID = thread.activeRun?.id
        defer { if admission == id { admission = nil; preparingRunID = nil } }
        let child = try await ensure(refresh: true)
        try Task.checkCancellation(); guard !closing, admission == id, !busy else { throw CancellationError() }
        var presented = thread
        presented.provider = .codex; presented.workspacePath = captured.workspacePath
        presented.model = captured.model; presented.reasoningEffort = captured.reasoningEffort; presented.permission = captured.permission
        presented.codexRuntimeConfiguration = captured.codexRuntimeConfiguration
        presented.providerThreadID = captured.nativeThreadID ?? thread.providerThreadID ?? nativeThreadID
        let runID = thread.activeRun?.id
        foreground = .init(token: id, runID: runID); nativeTurnID = nil
        admission = nil; preparingRunID = nil // Native terminal may admit a successor before this RPC acknowledgement.
        let configured = presented
        do { try await call(epoch: child.epoch) { try await child.resource.session.send(input: input, thread: configured) } }
        catch {
            // A late old RPC failure cannot invalidate an observed successor.
            if !closing, live?.epoch == child.epoch, foreground?.token == id { blocked = true }
            throw error
        }
    }
    public func steeringCapabilities() async -> ProviderSteeringCapabilities {
        guard !closing, !blocked, let child = live else { return .init(unavailableReason: ProviderSteeringError(.noActiveTurn).localizedDescription) }
        return await child.resource.session.steeringCapabilities()
    }
    public func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) async throws -> ProviderSteeringReceipt {
        guard !closing, !blocked, let child = live, activeRunID == thread.activeRun?.id,
              activeRunID != nil, nativeTurnID == expectedTurnID else { throw ProviderSteeringError(.staleTarget) }
        try validate(thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread))
        return try await call(epoch: child.epoch) {
            try await child.resource.session.steer(input: input, thread: thread, expectedTurnID: expectedTurnID, clientMessageID: clientMessageID)
        }
    }
    public func interrupt() async throws {
        if admission != nil || (live == nil && launch != nil) { await close(); return }
        guard !closing, let child = live else { return }
        try await call(epoch: child.epoch) { try await child.resource.session.interrupt() }
    }
    public func interrupt(expectedRunID: UUID) async throws {
        if admission != nil, preparingRunID == expectedRunID { await close(); return }
        guard !closing, activeRunID == expectedRunID, let child = live else { throw ProviderSteeringError(.staleTarget) }
        try await call(epoch: child.epoch) { try await child.resource.session.interrupt(expectedRunID: expectedRunID) }
    }
    public func respond(_ request: ApprovalRequest, allow: Bool) async throws {
        let child = try existing()
        try await call(epoch: child.epoch) { try await child.resource.session.respond(request, allow: allow) }
    }
    public func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {
        let child = try existing()
        try await call(epoch: child.epoch) { try await child.resource.session.answer(request, answers: answers) }
    }
    public func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]]) async throws {
        let child = try existing()
        try await call(epoch: child.epoch) { try await child.resource.session.selectAnswers(request, selections: selections) }
    }
    public func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]], notes: [String: String]) async throws {
        let child = try existing()
        try await call(epoch: child.epoch) { try await child.resource.session.selectAnswers(request, selections: selections, notes: notes) }
    }
    public func choose(_ request: ApprovalRequest, optionID: String) async throws {
        let child = try existing()
        try await call(epoch: child.epoch) { try await child.resource.session.choose(request, optionID: optionID) }
    }
    public func historyCapabilities(threadID: String) async throws -> ProviderHistoryCapabilities {
        let child = try await ensure(refresh: false)
        return try await call(epoch: child.epoch) { try await child.resource.session.historyCapabilities(threadID: threadID) }
    }
    public func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot {
        let child = try await ensure(refresh: false)
        return try await call(epoch: child.epoch) { try await child.resource.session.conversationSnapshot(threadID: threadID) }
    }
    public func historyPage(threadID: String, cursor: String? = nil, limit: Int = 100) async throws -> ProviderHistoryPage {
        let child = try await ensure(refresh: false)
        return try await call(epoch: child.epoch) { try await child.resource.session.historyPage(threadID: threadID, cursor: cursor, limit: limit) }
    }
    public func forkConversation(source: ProviderConversationReference, boundary: ProviderHistoryBoundary, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot {
        try validate(configuration)
        let id = try reserveHistory(); defer { if admission == id { admission = nil } }
        let child = try await ensure(refresh: true)
        guard !closing, admission == id, !busy else { throw CancellationError() }
        do {
            let result = try await call(epoch: child.epoch) {
                try await child.resource.session.forkConversation(source: source, boundary: boundary, configuration: configuration)
            }
            nativeThreadID = result.reference.nativeThreadID; return result
        } catch { markHistoryUncertain(error); throw error }
    }
    public func revertConversation(thread: ProviderConversationReference, beforeTurnID: String, expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot {
        let id = try reserveHistory(); defer { if admission == id { admission = nil } }
        let child = try await ensure(refresh: true)
        guard !closing, admission == id, !busy else { throw CancellationError() }
        do {
            let result = try await call(epoch: child.epoch) {
                try await child.resource.session.revertConversation(thread: thread, beforeTurnID: beforeTurnID, expectedHeadTurnID: expectedHeadTurnID)
            }
            nativeThreadID = result.reference.nativeThreadID; return result
        } catch { markHistoryUncertain(error); throw error }
    }
    private func reserveHistory() throws -> UUID {
        try validate()
        guard !historyUncertain else { throw ProviderHistoryError(.outcomeUncertain) }
        guard !busy, admission == nil else { throw ProviderHistoryError(.notIdle) }
        let id = UUID(); admission = id; return id
    }
    private func markHistoryUncertain(_ error: any Error) {
        if error is CancellationError || (error as? ProviderHistoryError)?.kind == .outcomeUncertain { historyUncertain = true }
    }
    private var busy: Bool { foreground != nil || activityID != nil || !sessionRequests.isEmpty || blocked }
    private func validate() throws {
        try configuration.validate()
        guard !closing, configuration.authenticationMode == .ownedChatGPT, configuration.accountBinding != nil,
              configuration.homeDirectory != nil else { throw CodexAccountError.signInRequired }
    }
    private func validate(_ value: ProviderConfiguration) throws {
        try validate()
        guard value.provider == .codex, value.codexRuntimeBinding == configuration,
              value.workspacePath == cwd.path else { throw CodexAccountError.staleAccount }
    }
    private func existing() throws -> Live {
        guard !closing, let live else { throw CodexAccountError.signInRequired }; return live
    }

    private func ensure(refresh: Bool) async throws -> Live {
        try validate(); try Task.checkCancellation()
        if !refresh, let live { return live }
        if let pending = launch {
            let value = try await wait(pending)
            if refresh && !pending.refresh { return try await ensure(refresh: true) }
            return value
        }
        let pending = Launch(refresh: refresh); launch = pending
        launchTask = Task {
            let result: Result<Live, any Error>
            do { result = .success(try await self.prepare(pending.id)) }
            catch { result = .failure(error) }
            self.finishLaunch(pending.id, result: result)
        }
        return try await wait(pending)
    }
    private func wait(_ pending: Launch) async throws -> Live {
        let id = UUID(), launchID = pending.id
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending.waiters[id] = $0 }
        } onCancel: { Task { await self.cancelWaiter(id, launchID: launchID) } }
    }
    private func cancelWaiter(_ id: UUID, launchID: UUID) {
        guard let pending = launch, pending.id == launchID else { return }
        pending.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if pending.waiters.isEmpty { launchTask?.cancel() }
    }
    private func finishLaunch(_ id: UUID, result: Result<Live, any Error>) {
        guard let pending = launch, pending.id == id else { return }
        launch = nil; launchTask = nil; let waiters = pending.waiters; pending.waiters = [:]
        for waiter in waiters.values { waiter.resume(with: result) }
    }
    private func prepare(_ id: UUID) async throws -> Live {
        let access = try await acquireAccess()
        do {
            try Task.checkCancellation(); guard !closing, launch?.id == id else { throw CancellationError() }
            if let current = live {
                if current.resource.credentialRevision == access.credentialRevision { await access.release(); return current }
                guard !busy else { throw CodexAccountError.staleAccount }
                live = nil // Fence the old stream before closing it.
                await retire(current)
                try Task.checkCancellation(); guard !closing, launch?.id == id else { throw CancellationError() }
            }
            let resource = try await access.resolve()
            guard !Task.isCancelled, !closing, launch?.id == id, resource.credentialRevision == access.credentialRevision else {
                await resource.session.close(); await resource.release(); throw CancellationError()
            }
            let epoch = UUID(), stream = resource.session.events
            let reader = Task { [weak self] in
                for await event in stream { await self?.consume(event, epoch: epoch) }
                await self?.sourceEnded(epoch)
            }
            let value = Live(epoch: epoch, resource: resource, reader: reader)
            live = value; blocked = false
            await access.release(); return value
        } catch { await access.release(); throw error }
    }
    private func call<T: Sendable>(epoch: UUID?, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !closing else { throw CancellationError() }
        let id = UUID(), task = Task { try Task.checkCancellation(); return try await work() }
        calls[id] = .init(epoch: epoch, cancel: { task.cancel() }, drain: Task { _ = await task.result })
        defer { calls.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func consume(_ event: ProviderEvent, epoch: UUID) {
        guard !closing, live?.epoch == epoch else { return }
        update(event, scope: nil)
        continuation.yield(event)
    }
    private func update(_ event: ProviderEvent, scope: UUID?) {
        switch event {
        case .context(let id, let nested): update(nested, scope: id)
        case .thread(let id): if scope == nil || scope == activeRunID { nativeThreadID = id }
        case .turn(let id): if scope == activeRunID { nativeTurnID = id }
        case .completed, .failure:
            if foreground != nil, scope == activeRunID { foreground = nil; nativeTurnID = nil }
        case .connectionClosed: blocked = true; foreground = nil; nativeTurnID = nil
        case .activity(let value):
            if value.state != .idle { activityID = value.id }
            else if value.finishesRun && activityID == value.id { activityID = nil }
        case .sessionApproval(let value): if let bytes = try? JSONEncoder().encode(value.id) { sessionRequests.insert(.init(bytes: bytes)) }
        case .sessionApprovalDismissed(let id): if let bytes = try? JSONEncoder().encode(id) { sessionRequests.remove(.init(bytes: bytes)) }
        default: break
        }
    }
    private func sourceEnded(_ epoch: UUID) {
        guard !closing, live?.epoch == epoch, !blocked else { return }
        blocked = true; foreground = nil; nativeTurnID = nil
        continuation.yield(.connectionClosed("The owned Codex connection ended. No input was automatically resent."))
    }
    private func retire(_ child: Live) async {
        let owned = calls.values.filter { $0.epoch == child.epoch }
        for call in owned { call.cancel() }
        await child.resource.session.close()
        for call in owned { await call.drain.value }
        child.reader.cancel(); await child.reader.value
        await child.resource.release()
    }
    public func close() async {
        if let closeTask { await closeTask.value; return }
        closing = true; admission = nil; preparingRunID = nil
        let child = live; live = nil
        let pending = launch
        let pendingTask = launchTask
        pendingTask?.cancel()
        if let pending {
            let waiters = pending.waiters; pending.waiters = [:]
            for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        let owned = Array(calls.values)
        for call in owned { call.cancel() }
        let task = Task {
            await pendingTask?.value
            if let child { await self.retire(child) }
            for call in owned { await call.drain.value }
            self.continuation.finish()
        }
        closeTask = task; await task.value
    }
    deinit {
        launchTask?.cancel()
        let child = live
        for call in calls.values { call.cancel() }
        Task {
            if let child { await child.resource.session.close(); child.reader.cancel(); await child.reader.value; await child.resource.release() }
        }
    }
}
