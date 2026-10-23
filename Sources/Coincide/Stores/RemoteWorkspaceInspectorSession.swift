import CoincideCore
import Foundation
import Observation

/// Typed transport seam keeps remote paths out of local FileService/GitService.
struct RemoteWorkspaceInspectorTransport: Sendable {
    var bind: @Sendable (RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget
    var read: @Sendable (RemoteWorkspaceReadRequest) async throws -> RemoteWorkspaceReadResult
    var begin: @Sendable (RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation
    var status: @Sendable (RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation?
    var cancel: @Sendable (RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation?

    static func live(_ client: RemoteEnvironmentClient) -> Self {
        .init(bind: { try await client.bindWorkspace($0) }, read: { try await client.readWorkspace($0) },
            begin: { try await client.beginWorkspaceOperation($0) }, status: { try await client.workspaceOperation($0) },
            cancel: { try await client.cancelWorkspaceOperation($0) })
    }
}

@MainActor @Observable
final class RemoteWorkspaceInspectorSession {
    private(set) var target: RemoteWorkspaceTarget
    private(set) var pending: RemoteWorkspaceMutationRequest?
    private(set) var operation: RemoteWorkspaceOperation?
    private(set) var isConnected = false
    private(set) var isBinding = false
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    @ObservationIgnored var operationFinished: (@MainActor (RemoteWorkspaceMutationRequest, RemoteWorkspaceOperation) -> Void)?
    @ObservationIgnored private let pendingStore: RemoteWorkspacePendingStore
    @ObservationIgnored private var transport: RemoteWorkspaceInspectorTransport?
    @ObservationIgnored private var clientIdentity: ObjectIdentifier?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var writesAllowed = false
    @ObservationIgnored private var pendingLoaded = false
    @ObservationIgnored private var pendingLoadFailed = false
    @ObservationIgnored private var appliedResultID: UUID?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(target: RemoteWorkspaceTarget, pendingStore: RemoteWorkspacePendingStore) {
        self.target = target; self.pendingStore = pendingStore
    }

    var hasUnresolvedOperation: Bool { pending != nil || pendingLoadFailed }
    var canRead: Bool { isConnected && !isBinding && target.rootID != nil }
    var canMutate: Bool { canRead && writesAllowed && !isWorking && pending == nil && !pendingLoadFailed }
    var canCheckResult: Bool { transport != nil && pending != nil && !isWorking }
    var canDismissOperation: Bool { pending != nil && !isWorking && operation?.state != .running && operation?.state != .accepted }

    func connect(client: RemoteEnvironmentClient?, canMutate: Bool) async {
        guard let client else { disconnect(); return }
        let identity = ObjectIdentifier(client)
        writesAllowed = canMutate
        if clientIdentity == identity, isConnected || isBinding { return }
        clientIdentity = identity
        await connect(transport: .live(client), canMutate: canMutate)
    }

    func connect(transport: RemoteWorkspaceInspectorTransport, canMutate: Bool) async {
        generation = UUID(); let owner = generation
        pollTask?.cancel(); pollTask = nil
        self.transport = transport; writesAllowed = canMutate
        isConnected = false; isBinding = true; errorMessage = nil
        defer { if generation == owner { isBinding = false } }
        do {
            if !pendingLoaded {
                let saved = try await pendingStore.load(environmentID: target.environmentID, threadID: target.threadID)
                guard generation == owner else { return }
                if let saved {
                    guard saved.target.environmentID == target.environmentID, saved.target.threadID == target.threadID else {
                        throw RemoteWorkspaceFailure(.invalidTarget)
                    }
                    pending = saved
                    // A thread can move to another worktree while an old-root
                    // result remains unknown. Recover that exact request while
                    // binding reads to the current root; never rebind its write.
                    if Self.sameWorkspace(saved.target, target) { target = saved.target }
                    notice = "An earlier operation has no confirmed result. Check its result; it will not be repeated."
                }
                pendingLoaded = true; pendingLoadFailed = false
            }
            let bound = try await transport.bind(target)
            guard generation == owner else { return }
            guard Self.sameWorkspace(bound, target), let rootID = bound.rootID,
                  target.rootID == nil || target.rootID == rootID else { throw RemoteWorkspaceFailure(.staleRoot) }
            target = bound; isConnected = true
        } catch {
            guard generation == owner else { return }
            if !pendingLoaded { pendingLoadFailed = true }
            errorMessage = Self.safeMessage(error)
        }
    }

    func disconnect() {
        generation = UUID(); clientIdentity = nil; transport = nil
        pendingLoaded = false
        pollTask?.cancel(); pollTask = nil
        isConnected = false; isBinding = false; isWorking = false
        if pending != nil { notice = "The operation's result is unconfirmed. Reconnect and check it before making another change." }
    }

    /// Old retained editors may inspect their exact durable operation through
    /// the same trusted environment without regaining file/Git mutation access.
    func connectForRecovery(client: RemoteEnvironmentClient) async {
        let owner = generation
        guard await client.expectedEnvironmentID() == target.environmentID, generation == owner else { return }
        let identity = ObjectIdentifier(client)
        if clientIdentity == identity, transport != nil, !isConnected { return }
        clientIdentity = identity
        transport = .live(client); writesAllowed = false
        isConnected = false; isBinding = false
        do {
            let saved = try await pendingStore.load(environmentID: target.environmentID, threadID: target.threadID)
            guard generation == owner else { return }
            if let saved, Self.sameWorkspace(saved.target, target) { pending = saved; pendingLoaded = true }
            pendingLoadFailed = false
        } catch { if generation == owner { pendingLoadFailed = true; errorMessage = Self.safeMessage(error) } }
    }

    func shutdown() async {
        let polling = pollTask
        disconnect()
        await polling?.value
    }

    func read(_ query: RemoteWorkspaceQuery) async throws -> RemoteWorkspaceValue {
        guard canRead, let transport else { throw RemoteWorkspaceFailure(.unavailable) }
        let owner = generation, requested = target
        let result = try await transport.read(.init(target: requested, query: query))
        guard generation == owner, canRead else { throw CancellationError() }
        guard Self.sameWorkspace(result.target, requested), result.target.rootID == requested.rootID else {
            throw RemoteWorkspaceFailure(.invalidTarget)
        }
        return result.value
    }

    func perform(_ mutation: RemoteWorkspaceMutation,
                 beforeBegin: (@MainActor (RemoteWorkspaceMutationRequest) async throws -> Void)? = nil) async {
        guard canMutate, let transport else { return }
        let owner = generation, request = RemoteWorkspaceMutationRequest(target: target, mutation: mutation)
        isWorking = true; errorMessage = nil; notice = nil
        defer { if generation == owner { isWorking = false } }
        do {
            try await beforeBegin?(request)
            guard generation == owner, !Task.isCancelled else { return }
            // Durable local intent precedes every network write. A lost reply
            // leaves this exact identity/payload available after app restart.
            try await pendingStore.save(request: request)
            guard generation == owner else { return }
            pending = request; operation = nil
            let result = try await transport.begin(request)
            guard generation == owner else { return }
            try await accept(result, for: request, owner: owner)
            if pending != nil, result.state == .accepted || result.state == .running { startPolling(owner: owner) }
        } catch {
            guard generation == owner else { return }
            errorMessage = Self.safeMessage(error)
            if pending != nil { notice = "The change may have been applied. Check its result; it will not be sent again automatically." }
        }
    }

    /// Observes the already journaled operation. Leaving this wait never
    /// creates a second request or implies that the host stopped the write.
    func waitForOperation(id: UUID, timeout: Duration = .seconds(30)) async -> RemoteWorkspaceOperation? {
        let owner = generation, deadline = ContinuousClock.now + timeout
        while !Task.isCancelled, generation == owner {
            if let operation, operation.request.id == id,
               operation.state == .finished || operation.state == .uncertain { return operation }
            guard pending?.id == id, canRead, ContinuousClock.now < deadline else { return nil }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        return nil
    }

    func checkResult() async {
        guard canCheckResult, let transport, let request = pending else { return }
        let owner = generation
        isWorking = true; defer { if generation == owner { isWorking = false } }
        do {
            if let result = try await transport.status(request) {
                guard generation == owner else { return }
                try await accept(result, for: request, owner: owner)
                if pending != nil, result.state == .accepted || result.state == .running { startPolling(owner: owner) }
            } else if generation == owner {
                notice = "No operation record is available. Inspect the remote file or Git status before dismissing this request; nothing was repeated."
            }
        } catch { if generation == owner { errorMessage = Self.safeMessage(error) } }
    }

    func cancelOperation() async {
        guard canCheckResult, let transport, let request = pending else { return }
        let owner = generation
        isWorking = true; defer { if generation == owner { isWorking = false } }
        do {
            if let result = try await transport.cancel(request) {
                guard generation == owner else { return }
                try await accept(result, for: request, owner: owner)
            }
            if generation == owner, pending != nil {
                notice = "Cancellation was requested. Inspect the final result; changes may already have been applied."
            }
        } catch { if generation == owner { errorMessage = Self.safeMessage(error) } }
    }

    func dismissOperation() async {
        guard canDismissOperation, let request = pending else { return }
        let owner = generation
        isWorking = true; defer { if generation == owner { isWorking = false } }
        do {
            try await pendingStore.archive(request: request)
            guard generation == owner else { return }
            pending = nil; operation = nil; pollTask?.cancel(); pollTask = nil
            notice = "The exact request was retained in local history. Nothing was repeated."
        } catch { if generation == owner { errorMessage = Self.safeMessage(error) } }
    }

    private func startPolling(owner: UUID) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == owner { self.pollTask = nil } }
            do {
                while !Task.isCancelled, self.generation == owner, let request = self.pending, let transport = self.transport {
                    try await Task.sleep(for: .milliseconds(250))
                    guard self.generation == owner else { return }
                    guard let result = try await transport.status(request) else {
                        self.notice = "The operation's result is unavailable. Check it again before making another change."; return
                    }
                    guard self.generation == owner else { return }
                    try await self.accept(result, for: request, owner: owner)
                    if result.state == .finished || result.state == .uncertain { return }
                }
            } catch is CancellationError { }
            catch { if self.generation == owner { self.errorMessage = Self.safeMessage(error) } }
        }
    }

    private func accept(_ value: RemoteWorkspaceOperation, for request: RemoteWorkspaceMutationRequest, owner: UUID) async throws {
        guard generation == owner, pending?.id == request.id else { return }
        guard try Self.exactBytes(value.request) == Self.exactBytes(request) else { throw RemoteWorkspaceFailure(.commandCollision) }
        operation = value
        if value.state == .finished {
            if appliedResultID != request.id {
                if Self.sameWorkspace(request.target, target), request.target.rootID == target.rootID { operationFinished?(request, value) }
                appliedResultID = request.id
            }
            try await pendingStore.remove(request: request)
            guard generation == owner else { return }
            pending = nil; notice = nil
            if let failure = value.failure { errorMessage = failure.localizedDescription }
        } else if value.state == .uncertain {
            notice = "The operation stopped without a confirmed outcome. Inspect the remote workspace before dismissing it; it will not be repeated."
        }
    }

    static func sameWorkspace(_ lhs: RemoteWorkspaceTarget, _ rhs: RemoteWorkspaceTarget) -> Bool {
        lhs.environmentID == rhs.environmentID && lhs.projectID == rhs.projectID && lhs.threadID == rhs.threadID && lhs.workspacePath.utf8.elementsEqual(rhs.workspacePath.utf8)
    }
    private static func exactBytes(_ value: RemoteWorkspaceMutationRequest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func safeMessage(_ error: any Error) -> String {
        if let failure = error as? RemoteWorkspaceFailure { return failure.localizedDescription }
        if let failure = error as? RemoteEnvironmentClientError { return failure.localizedDescription }
        if let failure = error as? RemoteEnvironmentStorageError { return failure.localizedDescription }
        return "The remote workspace operation could not be completed. Your drafts were retained."
    }
}
