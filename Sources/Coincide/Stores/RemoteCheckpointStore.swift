import CoincideCore
import Foundation
import Observation

struct RemoteCheckpointTransport: Sendable {
    var bind: @Sendable (RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget
    var read: @Sendable (RemoteCheckpointReadRequest) async throws -> RemoteCheckpointReadResult
    var review: @Sendable (RemoteCheckpointReviewRequest) async throws -> RemoteCheckpointReview
    var discard: @Sendable (RemoteCheckpointDiscardRequest) async throws -> RemoteCheckpointDiscardResult
    static func live(_ client: RemoteEnvironmentClient) -> Self {
        .init(bind: { try await client.bindCheckpointWorkspace($0) }, read: { try await client.readCheckpoints($0) },
            review: { try await client.reviewCheckpointRestore($0) }, discard: { try await client.discardCheckpointRestoreReview($0) })
    }
}

private struct RemoteCheckpointKey: Hashable { let environmentID: UUID, threadID: UUID; let path: Data }

@MainActor @Observable
final class RemoteCheckpointStore {
    typealias Perform = @MainActor (RemoteEnvironmentCommand) async -> Bool
    typealias CanRestore = @MainActor (RunCheckpointRestoreReview) -> Bool
    private(set) var current: RemoteCheckpointWorkspace?
    @ObservationIgnored private var models: [RemoteCheckpointKey: RemoteCheckpointWorkspace] = [:]
    @ObservationIgnored private var clientIdentity: ObjectIdentifier?
    @ObservationIgnored private var closed = false
    func review(id: UUID) -> RemoteCheckpointReview? { models.values.compactMap(\.restoreReview).first { $0.id == id } }
    func select(target: RemoteWorkspaceTarget?, thread: CodingThread?, snapshot: WorkspaceSnapshot, client: RemoteEnvironmentClient?,
                supported: Bool, canWrite: Bool, canMutate: Bool, perform: @escaping Perform,
                canRestore: @escaping CanRestore = { _ in true }) async {
        let identity = client.map(ObjectIdentifier.init)
        if identity != clientIdentity { disconnect(); clientIdentity = identity }
        await select(target: target, thread: thread, snapshot: snapshot, transport: client.map(RemoteCheckpointTransport.live),
            supported: supported, canWrite: canWrite, canMutate: canMutate, perform: perform, canRestore: canRestore)
    }
    func select(target: RemoteWorkspaceTarget?, thread: CodingThread?, snapshot: WorkspaceSnapshot, transport: RemoteCheckpointTransport?,
                supported: Bool, canWrite: Bool, canMutate: Bool, perform: @escaping Perform,
                canRestore: @escaping CanRestore = { _ in true }) async {
        guard !closed else { return }
        guard let target, let thread, thread.id == target.threadID, thread.projectID == target.projectID else { clearSelection(); return }
        let key = RemoteCheckpointKey(environmentID: target.environmentID, threadID: target.threadID, path: Data(target.workspacePath.utf8))
        let model: RemoteCheckpointWorkspace
        if let existing = models[key] { model = existing }
        else { model = .init(target: target); models[key] = model }
        if current !== model { current?.disconnect() }
        current = model
        model.update(target: target, thread: thread, snapshot: snapshot, transport: transport, supported: supported,
            canWrite: canWrite, canMutate: canMutate, perform: perform, canRestore: canRestore)
    }
    func clearSelection() { current?.disconnect(); current = nil }
    func disconnect() { clientIdentity = nil; for model in models.values { model.disconnect() } }
    func shutdown() async { closed = true; disconnect(); for model in models.values { await model.drainReads() } }
    func cancelShutdown() { closed = false }
}

@MainActor @Observable
final class RemoteCheckpointWorkspace {
    private(set) var target: RemoteWorkspaceTarget
    private(set) var thread: CodingThread?
    private(set) var inventory: RemoteCheckpointInventory?
    private(set) var diff: RemoteCheckpointDiff?
    private(set) var restoreReview: RemoteCheckpointReview?
    private(set) var operations: [RunCheckpointRestoreOperation] = []
    private(set) var isLoading = false
    private(set) var isLoadingDiff = false
    private(set) var isReviewing = false
    private(set) var isActing = false
    private(set) var errorMessage: String?
    private(set) var diffError: String?
    private(set) var restoreError: String?
    private(set) var connected = false
    private(set) var supported = false
    private(set) var writesAllowed = false
    private(set) var mutationsAllowed = false
    @ObservationIgnored private var transport: RemoteCheckpointTransport?
    @ObservationIgnored private var perform: RemoteCheckpointStore.Perform?
    @ObservationIgnored private var preflight: RemoteCheckpointStore.CanRestore = { _ in true }
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var inventoryRead = UUID()
    @ObservationIgnored private var diffRead = UUID()
    @ObservationIgnored private var reviewRead = UUID()
    @ObservationIgnored private var diffSource: Data?
    private struct OwnedRead { let cancel: @Sendable () -> Void; let drain: Task<Void, Never> }
    @ObservationIgnored private var reads: [UUID: OwnedRead] = [:]
    @ObservationIgnored private var cleanup: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var protectedReviews: Set<UUID> = []
    @ObservationIgnored private var activeReviewCalls = 0
    @ObservationIgnored private var reviewWaiters: [CheckedContinuation<Void, Never>] = []
    init(target: RemoteWorkspaceTarget) { self.target = target }
    var canRead: Bool { connected && supported && transport != nil }
    var policy: RunCheckpointPolicy { thread?.effectiveCheckpointPolicy ?? inventory?.policy ?? .disabled }
    var banner: RunCheckpointBannerPresentation? { thread.flatMap(RunCheckpointPresentation.banner) }
    var canApply: Bool {
        guard canRead, writesAllowed, mutationsAllowed, !isActing, !isReviewing, let review = restoreReview,
              !operations.contains(where: { $0.id == review.id }), preflight(review.value) else { return false }
        return exactAttempt(runID: review.value.runID, stage: review.value.stage, id: review.value.attemptID).map { Self.same($0, review.value.checkpoint) } == true
    }
    var unavailableMessage: String? {
        if !supported { return "Update CoincideEnvironment on the remote Mac to enable run checkpoints." }
        if !connected { return "Reconnect to read saved remote checkpoints or recover an earlier restore." }
        if !writesAllowed { return "Inspect the current remote request before starting another checkpoint action." }
        if !mutationsAllowed { return "Save or discard remote editor changes and finish work using these files before restoring them." }
        return nil
    }
    func update(target: RemoteWorkspaceTarget, thread: CodingThread, snapshot: WorkspaceSnapshot, transport: RemoteCheckpointTransport?,
                supported: Bool, canWrite: Bool, canMutate: Bool, perform: @escaping RemoteCheckpointStore.Perform,
                canRestore: @escaping RemoteCheckpointStore.CanRestore) {
        let unchanged = Self.sameCapture(self.target, target)
        if !unchanged { disconnect(); inventory = nil; diff = nil }
        let policyChanged = self.thread.map { $0.effectiveCheckpointPolicy != thread.effectiveCheckpointPolicy } ?? false
        self.target = .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID,
            configuration: target.configuration, rootID: target.rootID ?? (unchanged ? self.target.rootID : nil))
        self.thread = thread; self.transport = transport; connected = transport != nil; self.supported = supported
        writesAllowed = canWrite; mutationsAllowed = canMutate; self.perform = perform; preflight = canRestore
        operations = Array((snapshot.checkpointRestoreOperations ?? []).filter { $0.review.threadID == thread.id && $0.review.projectID == thread.projectID }.reversed())
        if policyChanged, restoreReview != nil { clearReview(); restoreError = "Checkpoint policy changed. Review the current files again before restoring." }
        if let review = restoreReview, exactAttempt(runID: review.value.runID, stage: review.value.stage, id: review.value.attemptID).map({ Self.same($0, review.value.checkpoint) }) != true {
            clearReview(); restoreError = "The saved checkpoint changed. Review its current state again before restoring files."
        }
        if let diff, !matchesDiff(diff) || diffSource != currentDiffSource(runID: diff.runID) { self.diff = nil; diffSource = nil; diffRead = UUID(); isLoadingDiff = false }
    }
    func restoreUnavailableReason(runID: UUID, stage: RunCheckpointStage, attemptID: UUID) -> String? {
        if let reason = unavailableMessage { return reason }
        guard let run = inventory?.runs.first(where: { $0.id == runID }), let attempt = exactAttempt(runID: runID, stage: stage, id: attemptID),
              attempt.phase == .ready, attempt.receipt != nil,
              ([run.baseline] + run.previousPostRunAttempts + (run.postRun.map { [$0] } ?? [])).contains(where: { $0.id == attemptID && Self.same($0, attempt) }) else {
            return "Refresh the remote checkpoint inventory before reviewing this exact saved observation."
        }
        return run.restoreUnavailableReasons[attemptID]
    }
    func refresh() async {
        guard canRead, let transport else { return }
        let owner = generation, token = UUID(), captured = target; inventoryRead = token; isLoading = true; errorMessage = nil
        defer { if inventoryRead == token { isLoading = false } }
        do {
            let bound = try await read { try await transport.bind(captured) }
            guard owner == generation, inventoryRead == token else { return }
            guard Self.sameCapture(bound, captured), bound.rootID != nil else { throw RemoteCheckpointFailure(.invalidTarget) }
            let result = try await read { try await transport.read(.init(target: bound, query: .inventory)) }
            guard owner == generation, inventoryRead == token else { return }
            guard Self.same(result.target, bound), case .inventory(let value) = result.value,
                  value.runs.count <= 10_000, Set(value.runs.map(\.id)).count == value.runs.count else { throw RemoteCheckpointFailure(.invalidRequest) }
            for run in value.runs {
                guard let native = thread?.runHistory?.first(where: { $0.id == run.id })?.checkpoints,
                      Self.same(native.baseline, run.baseline), Self.same(native.postRun, run.postRun),
                      Self.same(native.previousPostRunAttempts, run.previousPostRunAttempts),
                      Set(run.restoreUnavailableReasons.keys).isSubset(of: Set(([run.baseline] + run.previousPostRunAttempts + (run.postRun.map { [$0] } ?? [])).map(\.id))),
                      run.restoreUnavailableReasons.values.allSatisfy({ $0.utf8.count <= 8_192 }) else { throw RemoteCheckpointFailure(.invalidTarget) }
            }
            target = bound; inventory = value
        } catch is CancellationError { }
        catch { if owner == generation, inventoryRead == token { errorMessage = Self.message(error) } }
    }
    func loadDiff(runID: UUID) async {
        guard canRead, let transport, let checkpoints = thread?.runHistory?.first(where: { $0.id == runID })?.checkpoints,
              RunCheckpointPresentation.canShowDiff(checkpoints), let post = checkpoints.postRun else { return }
        let owner = generation, token = UUID(), captured = target, source = currentDiffSource(runID: runID)
        diffRead = token; isLoadingDiff = true; diffError = nil; diff = nil; diffSource = nil
        defer { if diffRead == token { isLoadingDiff = false } }
        do {
            let bound = try await read { try await transport.bind(captured) }
            guard owner == generation, diffRead == token else { return }
            guard Self.sameCapture(bound, captured), bound.rootID != nil else { throw RemoteCheckpointFailure(.invalidTarget) }
            let result = try await read { try await transport.read(.init(target: bound, query: .runDiff(runID: runID,
                baselineAttemptID: checkpoints.baseline.id, postRunAttemptID: post.id, maxBytes: 262_144))) }
            guard owner == generation, diffRead == token else { return }
            guard Self.same(result.target, bound), case .diff(let value) = result.value,
                  value.runID == runID, value.baselineAttemptID == checkpoints.baseline.id, value.postRunAttemptID == post.id,
                  value.patch.utf8.count <= 262_144, matchesDiff(value), currentDiffSource(runID: runID) == source else { throw RemoteCheckpointFailure(.invalidTarget) }
            target = bound; diff = value; diffSource = source
        } catch is CancellationError { }
        catch { if owner == generation, diffRead == token { diffError = Self.message(error) } }
    }
    @discardableResult func prepareRestore(runID: UUID, stage: RunCheckpointStage, attemptID: UUID) async -> UUID? {
        guard !Task.isCancelled, canRead, writesAllowed, mutationsAllowed, !isActing, !isReviewing,
              restoreUnavailableReason(runID: runID, stage: stage, attemptID: attemptID) == nil,
              let transport, let attempt = exactAttempt(runID: runID, stage: stage, id: attemptID) else { return nil }
        clearReview()
        let owner = generation, token = UUID(), captured = target; reviewRead = token; isReviewing = true; restoreError = nil
        activeReviewCalls += 1
        defer {
            if reviewRead == token { isReviewing = false }
            activeReviewCalls -= 1
            if activeReviewCalls == 0 { let waiters = reviewWaiters; reviewWaiters = []; waiters.forEach { $0.resume() } }
        }
        do {
            let result = try await read { try await transport.review(.init(target: captured, runID: runID, stage: stage, attemptID: attemptID)) }
            try result.value.validate()
            guard Self.same(result.target, captured), result.id == result.value.id,
                  result.digest == (try RemoteCheckpointProtocol.digest(target: captured, value: result.value)),
                  result.value.threadID == captured.threadID, result.value.projectID == captured.projectID,
                  result.value.runID == runID, result.value.stage == stage, result.value.attemptID == attemptID,
                  Self.same(result.value.checkpoint, attempt), result.value.workspacePath.utf8.elementsEqual(captured.workspacePath.utf8) else { throw RemoteCheckpointFailure(.staleReview) }
            guard !Task.isCancelled, owner == generation, reviewRead == token, mutationsAllowed, preflight(result.value),
                  exactAttempt(runID: runID, stage: stage, id: attemptID).map({ Self.same($0, attempt) }) == true else { await discard(result, transport: transport); return nil }
            restoreReview = result
            return result.id
        } catch is CancellationError { }
        catch { if owner == generation, reviewRead == token { restoreError = Self.message(error) } }
        return nil
    }
    func applyRestore() async {
        guard canApply, let review = restoreReview else { return }
        // A false parent result can mean the exact original command is still
        // unconfirmed. Host operation recovery owns its scratch from now on.
        protectedReviews.insert(review.id)
        if await execute(.beginRestore(reviewID: review.id, digest: review.digest), target: review.target), restoreReview?.id == review.id { restoreReview = nil }
    }
    func retryPostRun(runID: UUID, attemptID: UUID) async {
        guard mutationsAllowed, let held = thread?.heldPostRunCheckpoint, held.runID == runID,
              held.attempt.id == attemptID, held.attempt.canRetryPostRun, thread?.isArchived == false else { return }
        _ = await execute(.retryPostRun(runID: runID, attemptID: attemptID))
    }
    func continuePostRun(runID: UUID, attemptID: UUID) async {
        guard mutationsAllowed, let held = thread?.heldPostRunCheckpoint, held.runID == runID,
              held.attempt.id == attemptID, held.attempt.canContinuePostRun, thread?.isArchived == false else { return }
        _ = await execute(.continuePostRun(runID: runID, attemptID: attemptID))
    }
    func recover(_ operationID: UUID, acknowledge: Bool = false) async {
        guard operations.contains(where: { $0.id == operationID && $0.phase == .unconfirmed && $0.acknowledgedAt == nil }) else { return }
        _ = await execute(acknowledge ? .acknowledgeRestore(operationID: operationID) : .inspectRestore(operationID: operationID))
    }
    private func execute(_ action: RemoteCheckpointAction, target: RemoteWorkspaceTarget? = nil) async -> Bool {
        guard canRead, writesAllowed, !isActing, let perform, let transport else { return false }
        isActing = true; defer { isActing = false }
        var captured = target ?? self.target
        if action.requiresBoundRoot, captured.rootID == nil {
            let requested = captured, owner = generation
            do {
                let bound = try await read { try await transport.bind(requested) }
                guard owner == generation, Self.sameCapture(bound, requested), bound.rootID != nil else { return false }
                self.target = bound; captured = bound
            } catch { errorMessage = Self.message(error); return false }
        }
        let accepted = await perform(.checkpoint(target: captured, action: action))
        if !accepted { errorMessage = "The checkpoint action was refused or its result is unconfirmed. Check the remote window's saved request before continuing." }
        return accepted
    }
    func clearReview(id: UUID? = nil) {
        guard id == nil || restoreReview?.id == id else { return }
        let old = restoreReview, transport = transport; restoreReview = nil; reviewRead = UUID(); isReviewing = false
        if let old, let transport { scheduleDiscard(old, transport: transport) }
    }
    private func discard(_ value: RemoteCheckpointReview, transport: RemoteCheckpointTransport) async {
        scheduleDiscard(value, transport: transport)
        await cleanup[value.id]?.value
    }
    private func scheduleDiscard(_ value: RemoteCheckpointReview, transport: RemoteCheckpointTransport) {
        guard !protectedReviews.contains(value.id), cleanup[value.id] == nil else { return }
        let request = RemoteCheckpointDiscardRequest(target: value.target, reviewID: value.id, digest: value.digest)
        let task = Task { [weak self] in
            _ = try? await transport.discard(request)
            self?.cleanup.removeValue(forKey: value.id)
        }
        cleanup[value.id] = task
    }
    private func exactAttempt(runID: UUID, stage: RunCheckpointStage, id: UUID) -> ThreadRunCheckpointAttempt? {
        thread?.runCheckpoint(runID: runID, stage: stage, expectedAttemptID: id)
    }
    private func matchesDiff(_ value: RemoteCheckpointDiff) -> Bool {
        guard let checkpoints = thread?.runHistory?.first(where: { $0.id == value.runID })?.checkpoints else { return false }
        return checkpoints.baseline.id == value.baselineAttemptID && checkpoints.postRun?.id == value.postRunAttemptID && RunCheckpointPresentation.canShowDiff(checkpoints)
    }
    private func currentDiffSource(runID: UUID) -> Data? {
        guard let checkpoints = thread?.runHistory?.first(where: { $0.id == runID })?.checkpoints else { return nil }
        return try? RemoteCheckpointProtocol.payload([checkpoints.baseline.receipt, checkpoints.postRun?.receipt])
    }
    private func read<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard connected else { throw CancellationError() }
        let id = UUID(), task = Task { try await operation() }
        reads[id] = .init(cancel: { task.cancel() }, drain: Task { _ = await task.result })
        defer { reads.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func disconnect() {
        if let restoreReview, let transport { scheduleDiscard(restoreReview, transport: transport) }
        generation = UUID(); inventoryRead = UUID(); diffRead = UUID(); reviewRead = UUID()
        connected = false; writesAllowed = false; mutationsAllowed = false; transport = nil; perform = nil; restoreReview = nil
        isLoading = false; isLoadingDiff = false; isReviewing = false
        for value in reads.values { value.cancel() }
    }
    func drainReads() async {
        for value in Array(reads.values) { await value.drain.value }
        if activeReviewCalls > 0 { await withCheckedContinuation { reviewWaiters.append($0) } }
        while !cleanup.isEmpty { for task in Array(cleanup.values) { await task.value } }
    }
    private static func sameCapture(_ a: RemoteWorkspaceTarget, _ b: RemoteWorkspaceTarget) -> Bool {
        a.environmentID == b.environmentID && a.projectID == b.projectID && a.threadID == b.threadID &&
            a.workspacePath.utf8.elementsEqual(b.workspacePath.utf8) && same(a.configuration, b.configuration)
    }
    private static func same<T: Encodable>(_ a: T, _ b: T) -> Bool { (try? RemoteCheckpointProtocol.payload(a)) == (try? RemoteCheckpointProtocol.payload(b)) }
    private static func message(_ error: any Error) -> String {
        (error as? RemoteCheckpointFailure)?.localizedDescription ?? (error as? RemoteEnvironmentClientError)?.localizedDescription ??
            "The remote checkpoint or workspace changed. Refresh and review its current state before continuing."
    }
}
