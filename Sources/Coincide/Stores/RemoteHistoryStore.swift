import CoincideCore
import Foundation
import Observation

struct RemoteHistoryTransport: Sendable {
    var bind: @Sendable (RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget
    var read: @Sendable (RemoteHistoryReadRequest) async throws -> RemoteHistoryReadResult
    var review: @Sendable (RemoteHistoryReviewRequest) async throws -> RemoteHistoryReview
    var discard: @Sendable (RemoteHistoryDiscardRequest) async throws -> RemoteHistoryDiscardResult
    var document: @Sendable (RemoteProjectionContentReference, RemoteHistoryBinding, RemoteWorkspaceTarget) async throws -> Data
    static func live(_ client: RemoteEnvironmentClient) -> Self {
        .init(bind: { try await client.bindHistoryWorkspace($0) }, read: { try await client.readHistory($0) },
            review: { try await client.reviewHistory($0) }, discard: { try await client.discardHistoryReview($0) },
            document: { try await client.historyDocument($0, binding: $1, target: $2) })
    }
}
private struct RemoteHistoryKey: Hashable { let environmentID: UUID, threadID: UUID; let path: Data }

@MainActor @Observable
final class RemoteHistoryStore {
    typealias Perform = @MainActor (RemoteEnvironmentCommand) async -> Bool
    typealias CanRestoreFiles = @MainActor ([String]) -> Bool
    private(set) var current: RemoteHistoryWorkspace?
    @ObservationIgnored private var models: [RemoteHistoryKey: RemoteHistoryWorkspace] = [:]
    @ObservationIgnored private var clientIdentity: ObjectIdentifier?
    @ObservationIgnored private var closed = false
    func review(id: UUID) -> RemoteHistoryReview? { models.values.compactMap { $0.review(id: id) }.first }
    func select(target: RemoteWorkspaceTarget?, projection: RemoteProjectionStore, client: RemoteEnvironmentClient?, supported: Bool,
                canWrite: Bool, canRestoreFiles: @escaping CanRestoreFiles, perform: @escaping Perform,
                openConversation: @escaping @MainActor (UUID) -> Void) async {
        let identity = client.map(ObjectIdentifier.init)
        if identity != clientIdentity { disconnect(); clientIdentity = identity }
        await select(target: target, projection: projection, transport: client.map(RemoteHistoryTransport.live), supported: supported,
            canWrite: canWrite, canRestoreFiles: canRestoreFiles, perform: perform, openConversation: openConversation)
    }
    func select(target: RemoteWorkspaceTarget?, projection: RemoteProjectionStore, transport: RemoteHistoryTransport?, supported: Bool,
                canWrite: Bool, canRestoreFiles: @escaping CanRestoreFiles, perform: @escaping Perform,
                openConversation: @escaping @MainActor (UUID) -> Void) async {
        guard !closed, let target else { clearSelection(); return }
        let key = RemoteHistoryKey(environmentID: target.environmentID, threadID: target.threadID, path: Data(target.workspacePath.utf8))
        let model = models[key] ?? RemoteHistoryWorkspace(target: target); models[key] = model
        if current !== model { current?.disconnect() }; current = model
        model.update(target: target, projection: projection, transport: transport, supported: supported, canWrite: canWrite,
            canRestoreFiles: canRestoreFiles, perform: perform, openConversation: openConversation)
        await model.synchronize()
    }
    func clearSelection() { current?.disconnect(); current = nil }
    func disconnect() { clientIdentity = nil; for model in models.values { model.disconnect() } }
    func shutdown() async { closed = true; disconnect(); for model in models.values { await model.drain() } }
    func cancelShutdown() { closed = false }
}

@MainActor @Observable
final class RemoteHistoryWorkspace {
    private(set) var target: RemoteWorkspaceTarget
    private(set) var projection: RemoteProjectionStore?
    private(set) var keepReview: RemoteHistoryReview?
    private(set) var filesReview: RemoteHistoryReview?
    private(set) var controls: RemoteHistoryThreadControls?
    private(set) var operationViews: [UUID: RemoteHistoryOperationView] = [:]
    private(set) var isReviewing = false
    private(set) var isReviewingFiles = false
    private(set) var isActing = false
    private(set) var errorMessage: String?
    private(set) var filesError: String?
    private(set) var connected = false
    private(set) var supported = false
    private(set) var writesAllowed = false
    var title = ""
    @ObservationIgnored private var transport: RemoteHistoryTransport?
    @ObservationIgnored private var perform: RemoteHistoryStore.Perform?
    @ObservationIgnored private var canRestoreFiles: RemoteHistoryStore.CanRestoreFiles = { _ in false }
    @ObservationIgnored private var open: (@MainActor (UUID) -> Void)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var reviewRead = UUID()
    @ObservationIgnored private var filesRead = UUID()
    @ObservationIgnored private var controlsRead = UUID()
    @ObservationIgnored private var operationReads: [UUID: UUID] = [:]
    @ObservationIgnored private var operationVersions: [UUID: String] = [:]
    @ObservationIgnored private var leaseTargets: [UUID: RemoteWorkspaceTarget] = [:]
    @ObservationIgnored private var syncSequence: Int64?
    @ObservationIgnored private var synchronization: Task<Void, Never>?
    @ObservationIgnored private var synchronizationID = UUID()
    @ObservationIgnored private var synchronizationDrains: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var ownedReviews: [UUID: RemoteHistoryReview] = [:]
    @ObservationIgnored private var activeReviewCalls = 0
    @ObservationIgnored private var reviewWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var cleanup: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingForkNavigation: UUID?
    private struct OwnedRead { let cancel: @Sendable () -> Void; let drain: Task<Void, Never> }
    @ObservationIgnored private var reads: [UUID: OwnedRead] = [:]
    init(target: RemoteWorkspaceTarget) { self.target = target }
    var canRead: Bool { connected && supported && transport != nil }
    var summaries: [RemoteOperationSummary] { projection?.currentOperations.filter { $0.kind == .conversationHistory } ?? [] }
    var runs: [RemoteRunSummary] { projection?.runs ?? [] }
    var unavailableMessage: String? {
        if !supported { return "Update CoincideEnvironment on the remote Mac to enable conversation history." }
        if !connected { return "Reconnect to review or recover remote conversation history. Your local draft stays here." }
        if !writesAllowed { return "Inspect the unconfirmed remote request before starting another history action." }
        return nil
    }
    func review(id: UUID) -> RemoteHistoryReview? { ownedReviews[id] }
    func update(target: RemoteWorkspaceTarget, projection: RemoteProjectionStore, transport: RemoteHistoryTransport?, supported: Bool,
                canWrite: Bool, canRestoreFiles: @escaping RemoteHistoryStore.CanRestoreFiles,
                perform: @escaping RemoteHistoryStore.Perform, openConversation: @escaping @MainActor (UUID) -> Void) {
        let unchanged = Self.sameCapture(self.target, target)
        if !unchanged { disconnect() }
        self.target = .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID,
            configuration: target.configuration, rootID: target.rootID ?? (unchanged ? self.target.rootID : nil))
        self.projection = projection; self.transport = transport; connected = transport != nil; self.supported = supported
        writesAllowed = canWrite; self.canRestoreFiles = canRestoreFiles; self.perform = perform; open = openConversation
    }
    func synchronize() async {
        guard canRead else { return }
        if let synchronization { await synchronization.value; return }
        let owner = generation, id = UUID(); synchronizationID = id
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == owner, self.synchronizationID == id { self.synchronization = nil } }
            while self.generation == owner, self.canRead, !Task.isCancelled {
                let complete = await self.synchronizeOnce()
                guard complete, self.generation == owner,
                      self.projection?.control?.binding.sequence != self.syncSequence else { return }
            }
        }
        synchronization = task
        await task.value
    }
    private func synchronizeOnce() async -> Bool {
        guard canRead, let transport, let sequence = projection?.control?.binding.sequence, syncSequence != sequence else { return true }
        syncSequence = sequence
        let owner = generation, token = UUID(), captured = target; controlsRead = token
        do {
            let result = try await read { try await transport.read(.init(target: captured, query: .controls)) }
            guard owner == generation, controlsRead == token, Self.sameCapture(result.target, captured), case .controls(let controls) = result.value else { return false }
            self.controls = controls
            let heads = Array(summaries.prefix(4))
            for summary in heads {
                guard owner == generation, controlsRead == token else { return false }
                if operationVersions[summary.id] != summary.fingerprint { await loadOperation(summary.id) }
            }
            return true
        } catch is CancellationError { }
        catch { if owner == generation, controlsRead == token { errorMessage = Self.message(error); syncSequence = nil } }
        return false
    }
    func availability(runID: UUID, kind: ConversationHistoryKind) -> RemoteProjectionAvailability {
        guard canRead, writesAllowed, !isActing, !isReviewing, !isReviewingFiles,
              let run = runs.first(where: { $0.id == runID }) else { return .init(allowed: false, reason: unavailableMessage ?? "Load this exact recorded run before reviewing history.") }
        return kind == .forkAfterRun ? run.fork : run.rewind
    }
    @discardableResult func prepare(runID: UUID, kind: ConversationHistoryKind, files: RemoteHistoryFilesChoice = .keep) async -> UUID? {
        guard !Task.isCancelled, canRead, writesAllowed, !isActing, let transport else { return nil }
        if files == .keep {
            guard availability(runID: runID, kind: kind).allowed else { return nil }
            clearReviews(); isReviewing = true; errorMessage = nil
        } else {
            guard kind == .rewindBeforeRun, let keep = keepReview, keep.value.runID == runID,
                  keep.value.restoreFiles.allowed, canRestoreFiles([target.workspacePath]), !isReviewingFiles else { return nil }
            clearReview(id: filesReview?.id); isReviewingFiles = true; filesError = nil
        }
        let owner = generation, token = UUID(), captured = target
        if files == .keep { reviewRead = token } else { filesRead = token }
        activeReviewCalls += 1
        defer {
            if files == .keep, reviewRead == token { isReviewing = false }
            if files == .restore, filesRead == token { isReviewingFiles = false }
            activeReviewCalls -= 1
            if activeReviewCalls == 0 { let waiters = reviewWaiters; reviewWaiters = []; waiters.forEach { $0.resume() } }
        }
        var returned: RemoteHistoryReview?
        do {
            let bound = captured.rootID == nil ? try await read { try await transport.bind(captured) } : captured
            guard owner == generation, Self.sameCapture(bound, captured), bound.rootID != nil, !Task.isCancelled else { return nil }
            let value = try await read { try await transport.review(.init(target: bound, runID: runID, kind: kind, files: files,
                recallPromptOnSuccess: kind == .rewindBeforeRun)) }
            returned = value
            try Self.validate(value, target: bound, runID: runID, kind: kind, files: files)
            let source = try JSONDecoder().decode(ProviderConfiguration.self, from: await transport.document(value.value.sourceConfiguration, value.binding, bound))
            let targetConfiguration = try JSONDecoder().decode(ProviderConfiguration.self, from: await transport.document(value.value.targetConfiguration, value.binding, bound))
            guard Self.same(source, bound.configuration), targetConfiguration.workspacePath.utf8.elementsEqual(value.value.workspacePath.utf8),
                  targetConfiguration.provider == source.provider else { throw RemoteHistoryFailure(.staleReview) }
            let suggested: String
            if value.value.suggestedTitle.complete { suggested = value.value.suggestedTitle.preview }
            else if let reference = value.value.suggestedTitle.content,
                    let text = String(data: try await transport.document(reference, value.binding, bound), encoding: .utf8) { suggested = text }
            else { throw RemoteHistoryFailure(.invalidRequest) }
            let currentToken = files == .keep ? reviewRead : filesRead
            guard !Task.isCancelled, owner == generation, currentToken == token, canRead,
                  Self.sameCapture(self.target, captured), files == .keep || canRestoreFiles(value.value.mutatingPaths) else {
                scheduleDiscard(value, transport: transport); return nil
            }
            self.target = bound; ownedReviews[value.id] = value; leaseTargets[value.binding.leaseID] = value.target
            if files == .keep { keepReview = value; if title.isEmpty { title = suggested } }
            else { filesReview = value }
            return value.id
        } catch is CancellationError { if let returned { scheduleDiscard(returned, transport: transport) } }
        catch {
            if let returned { scheduleDiscard(returned, transport: transport) }
            if owner == generation, (files == .keep ? reviewRead : filesRead) == token {
                if files == .keep { errorMessage = Self.message(error) } else { filesError = Self.message(error) }
            }
        }
        return nil
    }
    func canAccept(_ review: RemoteHistoryReview) -> Bool {
        canRead && writesAllowed && !isActing && !isReviewing && !isReviewingFiles && ownedReviews[review.id] == review &&
            Self.sameCapture(target, review.target) && (review.value.files == nil || canRestoreFiles(review.value.mutatingPaths)) &&
            (review.value.kind != .forkAfterRun || (!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count <= 4_096 && !title.contains("\0")))
    }
    @discardableResult func accept(_ review: RemoteHistoryReview) async -> Bool {
        guard canAccept(review) else { return false }
        let owner = generation
        let accepted = await execute(.begin(reviewID: review.id, digest: review.digest, title: review.value.kind == .forkAfterRun ? title : nil), target: review.target)
        guard owner == generation else { return accepted }
        if accepted {
            if review.value.kind == .forkAfterRun { pendingForkNavigation = review.id; openAppliedFork() }
            clearReviews()
            syncSequence = nil; await synchronize()
        }
        return accepted
    }
    private func openAppliedFork() {
        guard let id = pendingForkNavigation, let value = operationViews[id], value.operation.phase == "applied",
              value.operation.actions[RemoteOperationAction.openConversation.rawValue]?.allowed == true,
              let target = value.operation.targetThreadID else { return }
        pendingForkNavigation = nil; open?(target)
    }
    func loadOperation(_ id: UUID) async {
        guard canRead, let transport, summaries.contains(where: { $0.id == id }) else { return }
        let owner = generation, token = UUID(), captured = target; operationReads[id] = token
        let version = summaries.first(where: { $0.id == id })?.fingerprint
        var unused: RemoteHistoryBinding?
        do {
            let result = try await read { try await transport.read(.init(target: captured, query: .operation(operationID: id))) }
            guard case .operation(let value) = result.value else { throw RemoteHistoryFailure(.invalidRequest) }
            unused = value.binding
            guard owner == generation, operationReads[id] == token, Self.sameCapture(result.target, captured),
                  value.operation.id == id, value.binding.objectID == id, value.binding.threadID == captured.threadID,
                  value.binding.environmentID == captured.environmentID else { throw CancellationError() }
            guard owner == generation, operationReads[id] == token, !Task.isCancelled else { throw CancellationError() }
            if let previous = operationViews[id], previous.binding != value.binding { await release(previous.binding, target: captured, transport: transport) }
            guard owner == generation, operationReads[id] == token else { throw CancellationError() }
            operationViews[id] = value; unused = nil
            leaseTargets[value.binding.leaseID] = captured; operationVersions[id] = version
            openAppliedFork()
        } catch is CancellationError { }
        catch { if owner == generation, operationReads[id] == token { errorMessage = Self.message(error) } }
        if let unused { await release(unused, target: captured, transport: transport) }
    }
    func act(_ action: RemoteOperationAction, operationID: UUID) async {
        guard let value = operationViews[operationID], value.operation.actions[action.rawValue]?.allowed == true else { return }
        switch action {
        case .inspectProvider: _ = await execute(.inspectProvider(operationID: operationID))
        case .inspectFiles: _ = await execute(.inspectFiles(operationID: operationID))
        case .acknowledgeFiles: _ = await execute(.acknowledgeFiles(operationID: operationID))
        case .recallPrompt: _ = await execute(.recallPrompt(operationID: operationID))
        case .dismissRecall: _ = await execute(.dismissRecall(operationID: operationID))
        case .openConversation: if let id = value.operation.targetThreadID { open?(id) }
        default: break
        }
    }
    func inspectClaude() async {
        guard let controls, controls.canInspectClaudeResume, let selection = controls.claudeSelectionID, let consumer = controls.claudeConsumerRunID else { return }
        _ = await execute(.inspectClaudeResume(selectionID: selection, consumerRunID: consumer))
    }
    private func execute(_ action: RemoteHistoryAction, target explicit: RemoteWorkspaceTarget? = nil) async -> Bool {
        guard canRead, writesAllowed, !isActing, let transport, let perform else { return false }
        let owner = generation; var captured = explicit ?? target
        isActing = true; defer { if owner == generation { isActing = false } }
        do {
            if captured.rootID == nil, action.requiresBoundRoot {
                let requested = captured
                captured = try await read { try await transport.bind(requested) }
                guard owner == generation, Self.sameCapture(captured, requested), captured.rootID != nil else { return false }
                target = captured
            }
            let accepted = await perform(.history(target: captured, action: action))
            guard owner == generation else { return accepted }
            if !accepted { errorMessage = "This history action was refused or its result is unconfirmed. Check the saved remote request; it will not be repeated." }
            syncSequence = nil
            await synchronize()
            return accepted
        } catch { if owner == generation { errorMessage = Self.message(error) }; return false }
    }
    func clearReview(id: UUID?) {
        guard let id, let value = ownedReviews.removeValue(forKey: id) else { return }
        if keepReview?.id == id { keepReview = nil; reviewRead = UUID(); isReviewing = false }
        if filesReview?.id == id { filesReview = nil; filesRead = UUID(); isReviewingFiles = false }
        if let transport { scheduleDiscard(value, transport: transport) }
    }
    func clearReviews() { for id in Array(ownedReviews.keys) { clearReview(id: id) }; reviewRead = UUID(); filesRead = UUID() }
    func document(_ reference: RemoteProjectionContentReference, binding: RemoteHistoryBinding) async throws -> Data {
        guard canRead, let transport else { throw RemoteHistoryFailure(.unavailable) }
        return try await transport.document(reference, binding, leaseTargets[binding.leaseID] ?? target)
    }
    func leasedRead(_ query: RemoteHistoryQuery) async throws -> RemoteHistoryValue {
        guard canRead, let transport else { throw RemoteHistoryFailure(.unavailable) }
        let owner = generation
        let binding: RemoteHistoryBinding?
        switch query { case .prefix(let value, _, _), .paths(let value, _), .content(let value, _, _, _), .release(let value): binding = value; default: binding = nil }
        let captured = binding.flatMap { leaseTargets[$0.leaseID] } ?? target
        let result = try await read { try await transport.read(.init(target: captured, query: query)) }
        guard owner == generation, Self.sameCapture(result.target, captured), !Task.isCancelled else { throw CancellationError() }
        return result.value
    }
    private func scheduleDiscard(_ review: RemoteHistoryReview, transport: RemoteHistoryTransport) {
        guard cleanup[review.id] == nil else { return }
        let request = RemoteHistoryDiscardRequest(target: review.target, reviewID: review.id, digest: review.digest)
        cleanup[review.id] = Task { [weak self] in _ = try? await transport.discard(request); self?.cleanup.removeValue(forKey: review.id) }
    }
    private func release(_ binding: RemoteHistoryBinding, target: RemoteWorkspaceTarget, transport: RemoteHistoryTransport) async {
        let captured = leaseTargets[binding.leaseID] ?? target
        _ = try? await transport.read(.init(target: captured, query: .release(binding: binding)))
        leaseTargets.removeValue(forKey: binding.leaseID)
    }
    private func read<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard connected else { throw CancellationError() }
        let id = UUID(), task = Task { try await body() }
        reads[id] = .init(cancel: { task.cancel() }, drain: Task { _ = await task.result })
        defer { reads.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func disconnect() {
        if let synchronization {
            let id = synchronizationID
            synchronization.cancel(); synchronizationDrains[id] = synchronization
            self.synchronization = nil; synchronizationID = UUID()
        }
        clearReviews()
        if let transport {
            let releases = operationViews.values.map { ($0.binding, leaseTargets[$0.binding.leaseID] ?? target) }
            for (binding, captured) in releases {
                let id = UUID()
                cleanup[id] = Task { [weak self] in
                    _ = try? await transport.read(.init(target: captured, query: .release(binding: binding)))
                    self?.cleanup.removeValue(forKey: id)
                }
            }
        }
        generation = UUID(); reviewRead = UUID(); filesRead = UUID(); controlsRead = UUID(); syncSequence = nil
        connected = false; writesAllowed = false; transport = nil; perform = nil; open = nil; pendingForkNavigation = nil
        isReviewing = false; isReviewingFiles = false; isActing = false
        operationReads = [:]; operationVersions = [:]
        operationViews = [:]; controls = nil; leaseTargets = [:]
        target = .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID, configuration: target.configuration)
        for value in reads.values { value.cancel() }
    }
    func drain() async {
        while !synchronizationDrains.isEmpty {
            let values = synchronizationDrains; synchronizationDrains = [:]
            for task in values.values { await task.value }
        }
        for value in Array(reads.values) { await value.drain.value }
        if activeReviewCalls > 0 { await withCheckedContinuation { reviewWaiters.append($0) } }
        while !cleanup.isEmpty { for task in Array(cleanup.values) { await task.value } }
    }
    static func sameCapture(_ a: RemoteWorkspaceTarget, _ b: RemoteWorkspaceTarget) -> Bool {
        a.environmentID == b.environmentID && a.projectID == b.projectID && a.threadID == b.threadID &&
            a.workspacePath.utf8.elementsEqual(b.workspacePath.utf8) && same(a.configuration, b.configuration)
    }
    private static func same<T: Encodable>(_ a: T, _ b: T) -> Bool { (try? RemoteHistoryProtocol.payload(a)) == (try? RemoteHistoryProtocol.payload(b)) }
    private static func validate(_ value: RemoteHistoryReview, target: RemoteWorkspaceTarget, runID: UUID, kind: ConversationHistoryKind, files: RemoteHistoryFilesChoice) throws {
        guard same(value.target, target), value.id == value.binding.objectID, value.digest == value.binding.digest,
              value.binding.environmentID == target.environmentID, value.binding.threadID == target.threadID,
              value.value.runID == runID, value.value.kind == kind, value.value.provider == target.configuration.provider,
              value.value.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              (files == .restore) == (value.value.files != nil), value.value.sourceConfiguration.kind == .configuration,
              value.value.targetConfiguration.kind == .configuration else { throw RemoteHistoryFailure(.staleReview) }
    }
    private static func message(_ error: any Error) -> String {
        (error as? RemoteHistoryFailure)?.localizedDescription ?? (error as? RemoteEnvironmentClientError)?.localizedDescription ??
            "The remote conversation or its native history changed. Refresh and review the exact boundary again before continuing."
    }
}

/// Only the retained bounded window participates in duplicate checking; this
/// never builds a growing identity ledger for an unbounded remote history.
enum RemoteHistoryPageValidation {
    static func messages(_ page: RemoteHistoryPage<RemoteMessageSummary>, binding: RemoteHistoryBinding,
                         offset: Int, total: Int, retained: [RemoteMessageSummary]) throws {
        try validate(page, binding: binding, offset: offset, total: total,
            retained: retained.map { Data($0.id.utf8) }, keys: page.items.map { Data($0.id.utf8) })
    }
    static func paths(_ page: RemoteHistoryPage<String>, binding: RemoteHistoryBinding,
                      offset: Int, total: Int, retained: [String]) throws {
        try validate(page, binding: binding, offset: offset, total: total,
            retained: retained.map { Data($0.utf8) }, keys: page.items.map { Data($0.utf8) })
    }
    private static func validate<T>(_ page: RemoteHistoryPage<T>, binding: RemoteHistoryBinding,
                                    offset: Int, total: Int, retained: [Data], keys: [Data]) throws {
        guard page.binding == binding, page.offset == offset, page.totalCount == total, offset >= 0, offset <= total,
              page.items.count <= total - offset, page.complete == (page.nextCursor == nil),
              page.complete == (offset + page.items.count == total), page.complete || !page.items.isEmpty,
              Set(keys).count == keys.count, Set(keys).isDisjoint(with: retained) else { throw RemoteHistoryFailure(.staleCursor) }
    }
}
