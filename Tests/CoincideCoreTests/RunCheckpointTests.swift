import Foundation
import Testing
import CSQLite
@testable import CoincideCore

private final class RunCheckpointSignal<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var waiters: [CheckedContinuation<Value, any Error>] = []
    func wait(ignoringCancellation: Bool = false) async throws -> Value {
        if ignoringCancellation { return try await waitIgnoringCancellation() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await waitIgnoringCancellation()
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
    private func waitIgnoringCancellation() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let current = lock.withLock { () -> Result<Value, any Error>? in
                if let result { return result }
                waiters.append(continuation); return nil
            }
            if let current { continuation.resume(with: current) }
        }
    }
    func finish(_ value: Result<Value, any Error>) {
        let pending = lock.withLock { () -> [CheckedContinuation<Value, any Error>] in
            guard result == nil else { return [] }
            result = value; let values = waiters; waiters = []; return values
        }
        for waiter in pending { waiter.resume(with: value) }
    }
}

private final class RunCheckpointAttemptPeer: @unchecked Sendable {
    let plan: GitCheckpointPlan
    private let databaseURL: URL
    private let lock = NSLock()
    private let preparation = RunCheckpointSignal<Void>()
    private let captured = RunCheckpointSignal<GitCheckpointReceipt>()
    private let inspected = RunCheckpointSignal<GitCheckpointInspection>()
    private var prepareCount = 0, captureCount = 0, inspectCount = 0, scratchCount = 0
    private var ignoresCancellation = false
    private var observed: WorkspaceSnapshot?
    private let scratchResult: GitCheckpointScratchResult
    private let capturedAt = Date()
    init(id: UUID, root: URL, databaseURL: URL, scratchResult: GitCheckpointScratchResult, ignoresCancellation: Bool) throws {
        let identity = GitWorktreeNodeIdentity(device: 1, inode: 42)
        plan = try .init(id: id, workspacePath: root.path, repositoryPath: root.path, gitDirectoryPath: root.path + "/.git",
            commonDirectoryPath: root.path + "/.git", workspaceIdentity: identity, repositoryIdentity: identity,
            gitDirectoryIdentity: identity, commonDirectoryIdentity: identity, objectDirectoryIdentity: identity,
            headCommit: String(repeating: "a", count: 40), configurationDigest: String(repeating: "b", count: 64), indexRevision: nil)
        self.databaseURL = databaseURL; self.scratchResult = scratchResult; self.ignoresCancellation = ignoresCancellation
    }
    var prepares: Int { lock.withLock { prepareCount } }
    var captures: Int { lock.withLock { captureCount } }
    var inspections: Int { lock.withLock { inspectCount } }
    var scratchFinalizations: Int { lock.withLock { scratchCount } }
    var captureObservation: WorkspaceSnapshot? { lock.withLock { observed } }
    func prepare() async throws -> GitCheckpointPlan {
        let ignores = lock.withLock { prepareCount += 1; return ignoresCancellation }
        try await preparation.wait(ignoringCancellation: ignores)
        return plan
    }
    func capture() async throws -> GitCheckpointReceipt {
        let ignores = lock.withLock { captureCount += 1; return ignoresCancellation }
        let database = try WorkspaceDatabase(url: databaseURL), snapshot = try await database.load()
        lock.withLock { observed = snapshot }
        return try await captured.wait(ignoringCancellation: ignores)
    }
    func inspect() async throws -> GitCheckpointInspection {
        let ignores = lock.withLock { inspectCount += 1; return ignoresCancellation }
        return try await inspected.wait(ignoringCancellation: ignores)
    }
    func finalize() -> GitCheckpointScratchResult { lock.withLock { scratchCount += 1 }; return scratchResult }
    func resolve() { preparation.finish(.success(())) }
    func failPreparation(_ kind: GitCheckpointError.Kind) { preparation.finish(.failure(GitCheckpointError(kind))) }
    func receipt() throws -> GitCheckpointReceipt {
        try .init(plan: plan, commit: String(repeating: "c", count: 40), tree: String(repeating: "d", count: 40), capturedAt: capturedAt)
    }
    func complete() throws { captured.finish(.success(try receipt())) }
    func failCapture(_ kind: GitCheckpointError.Kind = .commandFailed) { captured.finish(.failure(GitCheckpointError(kind))) }
    func recover(_ value: GitCheckpointInspection) { inspected.finish(.success(value)) }
    func releaseAll() {
        preparation.finish(.failure(CancellationError())); captured.finish(.failure(CancellationError())); inspected.finish(.failure(CancellationError()))
    }
}

private struct RunCheckpointDiffCall: Sendable {
    let from: GitCheckpointReceipt, to: GitCheckpointReceipt
    let paths: [String]?
    let ignoreWhitespace: Bool
    let maxBytes: Int
}

private struct RunCheckpointWorkspacePeer: RunCheckpointSession {
    let root: URL
    let harness: RunCheckpointHarness
    func prepare(id: UUID) async throws -> GitCheckpointPlan { try await harness.attempt(id, at: root).prepare() }
    func capture(_ plan: GitCheckpointPlan) async throws -> GitCheckpointReceipt { try await harness.attempt(plan.id, at: root).capture() }
    func inspect(_ plan: GitCheckpointPlan) async throws -> GitCheckpointInspection { try await harness.attempt(plan.id, at: root).inspect() }
    func finalizeScratch(_ receipt: GitCheckpointReceipt) async throws -> GitCheckpointScratchResult { try harness.attempt(receipt.plan.id, at: root).finalize() }
    func diff(from: GitCheckpointReceipt, to: GitCheckpointReceipt, paths: [String]?, ignoreWhitespace: Bool, maxBytes: Int) async throws -> GitCheckpointDiff {
        harness.recordDiff(.init(from: from, to: to, paths: paths, ignoreWhitespace: ignoreWhitespace, maxBytes: maxBytes))
        return .init(patch: "Fixture checkpoint diff\n", truncated: false)
    }
}

private struct RunCheckpointSentTurn: Sendable {
    let input: ProviderInput
    let configuration: ProviderConfiguration
    let runID: UUID?
}

private actor RunCheckpointProviderPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var currentRun: UUID?
    private(set) var turns: [RunCheckpointSentTurn] = []
    private(set) var interrupts = 0
    private(set) var closes = 0
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [.init(id: "checkpoint-fixture", name: "Checkpoint fixture")] }
    func send(text: String, thread: CodingThread) { send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) {
        currentRun = thread.activeRun?.id
        turns.append(.init(input: input, configuration: .init(thread: thread), runID: currentRun))
    }
    func finish(_ state: ThreadState = .idle) {
        if let currentRun { sink.yield(.context(runID: currentRun, event: .completed(state))) }
    }
    func activity(_ value: ProviderActivity) { sink.yield(.activity(value)) }
    func interrupt() { interrupts += 1; finish(.interrupted) }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { closes += 1; sink.finish() }
}

private final class RunCheckpointHarness: @unchecked Sendable {
    let databaseURL: URL
    let scratchResult: GitCheckpointScratchResult
    let ignoresCancellation: Bool
    private let lock = NSLock()
    private var attempts: [UUID: RunCheckpointAttemptPeer] = [:]
    private var providers: [UUID: [RunCheckpointProviderPeer]] = [:]
    private var roots: [URL] = []
    private var diffs: [RunCheckpointDiffCall] = []
    init(databaseURL: URL, scratchResult: GitCheckpointScratchResult = .removed, ignoresCancellation: Bool = false) {
        self.databaseURL = databaseURL; self.scratchResult = scratchResult; self.ignoresCancellation = ignoresCancellation
    }
    func attempt(_ id: UUID, at root: URL) throws -> RunCheckpointAttemptPeer {
        try lock.withLock {
            if let value = attempts[id] { return value }
            let value = try RunCheckpointAttemptPeer(id: id, root: root, databaseURL: databaseURL, scratchResult: scratchResult, ignoresCancellation: ignoresCancellation)
            attempts[id] = value; return value
        }
    }
    func checkpoint(_ root: URL) -> RunCheckpointWorkspacePeer {
        lock.withLock { roots.append(root) }; return .init(root: root, harness: self)
    }
    func provider(_ thread: CodingThread) -> RunCheckpointProviderPeer {
        lock.withLock { let value = RunCheckpointProviderPeer(); providers[thread.id, default: []].append(value); return value }
    }
    func providerSessions(_ id: UUID) -> [RunCheckpointProviderPeer] { lock.withLock { providers[id] ?? [] } }
    func checkpointAttempts() -> [RunCheckpointAttemptPeer] { lock.withLock { Array(attempts.values) } }
    func checkpointRoots() -> [URL] { lock.withLock { roots } }
    func recordDiff(_ call: RunCheckpointDiffCall) { lock.withLock { diffs.append(call) } }
    func diffCalls() -> [RunCheckpointDiffCall] { lock.withLock { diffs } }
    func sent(_ id: UUID) async -> [RunCheckpointSentTurn] {
        var result: [RunCheckpointSentTurn] = []
        for provider in providerSessions(id) { result += await provider.turns }
        return result
    }
    func engine() throws -> WorkspaceEngine {
        try WorkspaceEngine(url: databaseURL, providerFactory: { self.provider($0) }, identityResolver: { _ in nil }, checkpointFactory: { self.checkpoint($0) })
    }
    func releaseAll() { for peer in checkpointAttempts() { peer.releaseAll() } }
}

private struct RunCheckpointFixture {
    let root: URL, source: URL
    let engine: WorkspaceEngine
    let harness: RunCheckpointHarness
    let project: WorkspaceProject, thread: CodingThread
    var databaseURL: URL { harness.databaseURL }
    func currentThread() async throws -> CodingThread { try #require(await engine.current().snapshot.threads.first { $0.id == thread.id }) }
    func peekRecord(_ id: UUID? = nil) async -> ThreadRunRecord? {
        let records = await engine.current().snapshot.threads.first { $0.id == thread.id }?.runHistory ?? []
        if let id { return records.first { $0.id == id } }
        return records.last
    }
    func record(_ id: UUID? = nil) async throws -> ThreadRunRecord { try #require(await peekRecord(id)) }
    func peekCheckpoint(_ stage: RunCheckpointStage, runID: UUID? = nil) async -> ThreadRunCheckpointAttempt? {
        guard let checkpoints = await peekRecord(runID)?.checkpoints else { return nil }
        return stage == .baseline ? checkpoints.baseline : checkpoints.postRun
    }
    func checkpoint(_ stage: RunCheckpointStage, runID: UUID? = nil) async throws -> ThreadRunCheckpointAttempt {
        try #require(await peekCheckpoint(stage, runID: runID))
    }
    func peer(_ attempt: ThreadRunCheckpointAttempt) throws -> RunCheckpointAttemptPeer {
        try harness.attempt(attempt.id, at: URL(fileURLWithPath: attempt.workspacePath))
    }
    @discardableResult func complete(_ stage: RunCheckpointStage, runID: UUID? = nil) async throws -> ThreadRunCheckpointAttempt {
        try await waitRunCheckpoint { await peekCheckpoint(stage, runID: runID)?.phase == .resolving }
        let attempt = try await checkpoint(stage, runID: runID), peer = try peer(attempt)
        try await waitRunCheckpoint { peer.prepares == 1 }
        peer.resolve()
        try await waitRunCheckpoint { await peekCheckpoint(stage, runID: runID)?.phase == .capturing && peer.captureObservation != nil }
        try peer.complete()
        try await waitRunCheckpoint { await peekCheckpoint(stage, runID: runID)?.phase == .ready }
        return try await checkpoint(stage, runID: runID)
    }
    @discardableResult func start(_ text: String = "First checkpointed turn") async throws -> ThreadRunRecord {
        try await engine.dispatch(.submit(threadID: thread.id, text: text))
        let record = try await record()
        try await complete(.baseline, runID: record.id)
        try await waitRunCheckpoint { await harness.sent(thread.id).contains { $0.runID == record.id } }
        return try await self.record(record.id)
    }
    func provider() throws -> RunCheckpointProviderPeer { try #require(harness.providerSessions(thread.id).last) }
}

private func withRunCheckpoint(scratchResult: GitCheckpointScratchResult = .removed, ignoresCancellation: Bool = false,
                               _ body: (RunCheckpointFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace().resolvingSymlinksInPath(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source 工作")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let harness = RunCheckpointHarness(databaseURL: root.appendingPathComponent("workspace.sqlite"), scratchResult: scratchResult, ignoresCancellation: ignoresCancellation)
    let engine = try harness.engine(), project = WorkspaceProject(path: source.path), thread = CodingThread(project: project, model: "initial-model")
    do {
        try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        try await body(.init(root: root, source: source, engine: engine, harness: harness, project: project, thread: thread))
        harness.releaseAll(); await engine.shutdown()
    } catch { harness.releaseAll(); await engine.shutdown(); throw error }
}

private func waitRunCheckpoint(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The run checkpoint fixture did not reach its gate.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func runCheckpointSQL(_ url: URL, _ statement: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw CoincideError("The checkpoint fixture database could not be opened.") }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else { throw CoincideError("The checkpoint fixture database change failed.") }
}

@Test(.timeLimit(.minutes(1)))
func runCheckpointCommitsBaselinePlanBeforeCaptureAndReleasesOnlyTheOriginalPayload() async throws {
    try await withRunCheckpoint { f in
        let note = try await f.engine.attachments.importData(Data("Captured attachment bytes".utf8), name: "note.txt")
        try await f.engine.dispatch(.addAttachments(threadID: f.thread.id, attachments: [note]))
        try await f.engine.dispatch(.editThread(f.thread.id, .permission(.autoAcceptEdits)))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Original accepted payload"))
        let run = try await f.record(), attempt = try await f.checkpoint(.baseline), peer = try f.peer(attempt)
        #expect(attempt.phase == .resolving)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        try await waitRunCheckpoint { peer.prepares == 1 }
        peer.resolve()
        try await waitRunCheckpoint { peer.captureObservation != nil }
        let observedThread = try #require(peer.captureObservation?.threads.first { $0.id == f.thread.id })
        let observed = try #require(observedThread.runCheckpoint(runID: run.id, stage: .baseline))
        #expect(observed.phase == .capturing && observed.plan == peer.plan)
        let pending = observedThread.runHistory?.first { $0.id == run.id }?.checkpoints?.pendingStart
        #expect(pending?.prompt == "Original accepted payload" && pending?.attachments == [note])
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        try await f.engine.dispatch(.editThread(f.thread.id, .model("later-model")))
        try await f.engine.dispatch(.editThread(f.thread.id, .permission(.fullAccess)))
        try await f.engine.dispatch(.editThread(f.thread.id, .draft("Keep this later draft")))
        try await f.engine.dispatch(.editThread(f.thread.id, .checkpointPolicy(.disabled)))
        try peer.complete()
        try await waitRunCheckpoint { await f.harness.sent(f.thread.id).count == 1 }
        let sent = try #require(await f.harness.sent(f.thread.id).first), current = try await f.currentThread()
        #expect(sent.input.text.contains("Original accepted payload"))
        #expect(sent.configuration.model == "initial-model" && sent.configuration.permission == .autoAcceptEdits)
        #expect(current.draft == "Keep this later draft")
        #expect(current.messages.first(where: { $0.role == .user })?.attachments == [note])
        let recorded = try await f.record(run.id)
        #expect(recorded.checkpoints?.baseline.phase == .ready && recorded.checkpoints?.providerReleased == true)
        #expect(recorded.checkpoints?.pendingStart == nil)
        #expect(try await WorkspaceDatabase(url: f.databaseURL).rebuildProjection().snapshot == (await f.engine.current().snapshot))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["notRepository", "prepareFailure", "captureFailure"])
func runCheckpointBaselineFailureAutomaticallyReleasesTheAcceptedProviderPayload(failure: String) async throws {
    try await withRunCheckpoint { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Must still reach the provider"))
        let run = try await f.record(), attempt = try await f.checkpoint(.baseline), peer = try f.peer(attempt)
        try await waitRunCheckpoint { peer.prepares == 1 }
        if failure == "notRepository" { peer.failPreparation(.notRepository) }
        else if failure == "prepareFailure" { peer.failPreparation(.commandFailed) }
        else {
            peer.resolve()
            try await waitRunCheckpoint { peer.captures == 1 }
            peer.failCapture()
        }
        try await waitRunCheckpoint { await f.harness.sent(f.thread.id).count == 1 }
        let recorded = try await f.record(run.id), sent = try #require(await f.harness.sent(f.thread.id).first)
        #expect(sent.input.text == "Must still reach the provider")
        #expect(recorded.checkpoints?.providerReleased == true && recorded.checkpoints?.pendingStart == nil)
        #expect(recorded.checkpoints?.baseline.phase == (failure == "notRepository" ? .unavailable : .failed))
        if failure == "notRepository" { #expect(recorded.checkpoints?.baseline.unavailableReason == .notRepository) }
        else { #expect(recorded.checkpoints?.baseline.error == ThreadRunCheckpointAttempt.failureMessage) }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [RunCheckpointPhase.resolving, .capturing])
func runCheckpointStopDuringBaselineNeverCreatesOrSendsAProviderAfterLateCompletion(phase: RunCheckpointPhase) async throws {
    try await withRunCheckpoint(ignoresCancellation: true) { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Stop before provider release"))
        let run = try await f.record(), attempt = try await f.checkpoint(.baseline), peer = try f.peer(attempt)
        try await waitRunCheckpoint { peer.prepares == 1 }
        if phase == .capturing {
            peer.resolve()
            try await waitRunCheckpoint { peer.captures == 1 }
        }
        try await f.engine.dispatch(.interrupt(threadID: f.thread.id))
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        peer.resolve(); try peer.complete()
        try await waitRunCheckpoint { try await f.currentThread().activeRun == nil }
        let stopped = try await f.record(run.id)
        #expect(stopped.status == .interrupted && stopped.stopRequested)
        #expect(stopped.checkpoints?.providerReleased == false && stopped.checkpoints?.pendingStart == nil)
        #expect(stopped.checkpoints?.baseline.phase == .interrupted)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func runCheckpointPostRunCaptureHoldsFIFOAndEachQueuedTurnKeepsItsCapturedPolicy() async throws {
    try await withRunCheckpoint { f in
        let first = try await f.start()
        try await f.engine.dispatch(.editThread(f.thread.id, .model("second-model")))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Second captured automatic turn"))
        try await f.engine.dispatch(.editThread(f.thread.id, .checkpointPolicy(.disabled)))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Third captured disabled turn"))
        try await f.engine.dispatch(.editThread(f.thread.id, .model("later-preference")))
        try await f.provider().finish()
        try await waitRunCheckpoint { await f.peekCheckpoint(.postRun, runID: first.id)?.phase == .resolving }
        #expect(await f.harness.sent(f.thread.id).count == 1)
        #expect(try await f.currentThread().queuedTurns.count == 2)
        let post = try await f.checkpoint(.postRun, runID: first.id), postPeer = try f.peer(post)
        postPeer.resolve()
        try await waitRunCheckpoint { postPeer.captures == 1 }
        #expect(await f.harness.sent(f.thread.id).count == 1)
        try postPeer.complete()
        try await waitRunCheckpoint { await f.peekRecord()?.id != first.id }
        let second = try await f.record()
        #expect(second.checkpoints?.baseline.phase == .resolving)
        #expect(await f.harness.sent(f.thread.id).count == 1)
        try await f.complete(.baseline, runID: second.id)
        try await waitRunCheckpoint { await f.harness.sent(f.thread.id).count == 2 }
        let sentSecond = try #require(await f.harness.sent(f.thread.id).last)
        #expect(sentSecond.input.text == "Second captured automatic turn" && sentSecond.configuration.model == "second-model")
        try await f.provider().finish()
        try await f.complete(.postRun, runID: second.id)
        try await waitRunCheckpoint { await f.harness.sent(f.thread.id).count == 3 }
        let third = try await f.record(), sent = await f.harness.sent(f.thread.id)
        #expect(third.checkpoints == nil)
        #expect(sent.map(\.input.text) == ["First checkpointed turn", "Second captured automatic turn", "Third captured disabled turn"])
    }
}

@Test(.timeLimit(.minutes(1)))
func runCheckpointPostFailureHoldsQueueAndRetryCapturesALaterObservation() async throws {
    try await withRunCheckpoint { f in
        let first = try await f.start()
        try await f.engine.dispatch(.editThread(f.thread.id, .checkpointPolicy(.disabled)))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Queued behind final checkpoint"))
        try await f.provider().finish()
        try await waitRunCheckpoint { await f.peekCheckpoint(.postRun, runID: first.id)?.phase == .resolving }
        let old = try await f.checkpoint(.postRun, runID: first.id), oldPeer = try f.peer(old)
        oldPeer.resolve(); try await waitRunCheckpoint { oldPeer.captures == 1 }; oldPeer.failCapture()
        try await waitRunCheckpoint { await f.peekCheckpoint(.postRun, runID: first.id)?.phase == .failed }
        #expect(try await f.record(first.id).status == .completed)
        #expect(await f.harness.sent(f.thread.id).count == 1)
        try await f.engine.retryPostRunCheckpoint(threadID: f.thread.id, runID: first.id, expectedAttemptID: old.id)
        let fresh = try await f.checkpoint(.postRun, runID: first.id)
        #expect(fresh.id != old.id && fresh.isLaterObservation)
        #expect(try await f.record(first.id).checkpoints?.previousPostRunAttempts.first?.id == old.id)
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.continueAfterPostRunCheckpoint(threadID: f.thread.id, runID: first.id, expectedAttemptID: old.id)
        }
        try await f.engine.dispatch(.interrupt(threadID: f.thread.id))
        try await f.complete(.postRun, runID: first.id)
        #expect(await f.harness.sent(f.thread.id).count == 1)
        #expect(try await f.currentThread().queuePaused)
        try await f.engine.dispatch(.resumeQueue(threadID: f.thread.id))
        try await waitRunCheckpoint { await f.harness.sent(f.thread.id).count == 2 }
        #expect(try await f.record(first.id).checkpoints?.baseline.receipt == first.checkpoints?.baseline.receipt)
        #expect(try await f.record(first.id).checkpoints?.postRun?.id == fresh.id)
    }
}

@Test(.timeLimit(.minutes(1)))
func runCheckpointContinueAfterFinalFailureReleasesTheQueueExactlyOnce() async throws {
    try await withRunCheckpoint { f in
        let first = try await f.start()
        try await f.engine.dispatch(.editThread(f.thread.id, .checkpointPolicy(.disabled)))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Continue this queued payload"))
        try await f.provider().finish()
        try await waitRunCheckpoint { await f.peekCheckpoint(.postRun, runID: first.id)?.phase == .resolving }
        let attempt = try await f.checkpoint(.postRun, runID: first.id), peer = try f.peer(attempt)
        peer.failPreparation(.commandFailed)
        try await waitRunCheckpoint { await f.peekCheckpoint(.postRun, runID: first.id)?.phase == .failed }
        #expect(await f.harness.sent(f.thread.id).count == 1)
        try await f.engine.continueAfterPostRunCheckpoint(threadID: f.thread.id, runID: first.id, expectedAttemptID: attempt.id)
        try await waitRunCheckpoint { await f.harness.sent(f.thread.id).count == 2 }
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.continueAfterPostRunCheckpoint(threadID: f.thread.id, runID: first.id, expectedAttemptID: attempt.id)
        }
        #expect(await f.harness.sent(f.thread.id).map(\.input.text) == ["First checkpointed turn", "Continue this queued payload"])
        #expect(try await f.currentThread().queuedTurns.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func runCheckpointCleanupWarningKeepsSavedEvidenceReadyAndDoesNotBlockTheProvider() async throws {
    try await withRunCheckpoint(scratchResult: .preserved) { f in
        let run = try await f.start()
        let baseline = try await f.checkpoint(.baseline, runID: run.id), peer = try f.peer(baseline)
        try await waitRunCheckpoint {
            let warning = await f.peekCheckpoint(.baseline, runID: run.id)?.cleanupWarning
            return peer.scratchFinalizations == 1 && warning != nil
        }
        let saved = try await f.checkpoint(.baseline, runID: run.id)
        #expect(saved.phase == .ready && saved.receipt != nil)
        #expect(saved.cleanupWarning == ThreadRunCheckpointAttempt.cleanupWarningMessage)
        #expect(await f.harness.sent(f.thread.id).count == 1)
        try await f.provider().finish()
        let post = try await f.complete(.postRun, runID: run.id), postPeer = try f.peer(post)
        try await waitRunCheckpoint {
            let warning = await f.peekCheckpoint(.postRun, runID: run.id)?.cleanupWarning
            return postPeer.scratchFinalizations == 1 && warning != nil
        }
        #expect(try await f.checkpoint(.postRun, runID: run.id).phase == .ready)
        #expect(try await f.currentThread().heldPostRunCheckpoint == nil)
    }
}

@Test func runCheckpointNewSubmissionsCaptureAutomaticPolicyWhileLegacyQueuedMessagesRemainDisabled() throws {
    let project = WorkspaceProject(path: "/fixture/checkpoint"), thread = CodingThread(project: project)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    #expect(thread.checkpointPolicy == nil && thread.effectiveCheckpointPolicy == .automatic)
    let first = try WorkspaceDecision.make(.client(.submit(threadID: thread.id, text: "New automatic payload")), id: UUID(), snapshot: snapshot, now: Date())
    #expect(first.snapshot.threads[0].runHistory?.last?.checkpoints?.baseline.phase == .resolving)
    let queued = try WorkspaceDecision.make(.client(.submit(threadID: thread.id, text: "New queued payload")), id: UUID(), snapshot: first.snapshot, now: Date())
    #expect(queued.snapshot.threads[0].queuedTurns.last?.checkpointPolicy == .automatic)
    let legacy = QueuedTurn(id: UUID(), text: "Legacy queued payload", configuration: .init(thread: thread), createdAt: Date())
    var legacyJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    legacyJSON.removeValue(forKey: "checkpointPolicy")
    let decoded = try JSONDecoder().decode(QueuedTurn.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
    #expect(decoded.checkpointPolicy == nil)
    snapshot.threads[0].queuedTurns = [decoded]; snapshot.threads[0].queuePaused = true
    let resumed = try WorkspaceDecision.make(.client(.resumeQueue(threadID: thread.id)), id: UUID(), snapshot: snapshot, now: Date())
    #expect(resumed.snapshot.threads[0].runHistory?.last?.checkpoints == nil)
    #expect(resumed.effects.contains { if case .providerStart = $0.request { return true }; return false })
    #expect(!resumed.effects.contains { if case .resolveRunCheckpoint = $0.request { return true }; return false })
    var threadJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(thread)) as? [String: Any])
    threadJSON.removeValue(forKey: "checkpointPolicy")
    #expect(try JSONDecoder().decode(CodingThread.self, from: JSONSerialization.data(withJSONObject: threadJSON)).effectiveCheckpointPolicy == .automatic)
    let record = try #require(first.snapshot.threads[0].runHistory?.last)
    var recordJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    recordJSON.removeValue(forKey: "checkpoints")
    #expect(try JSONDecoder().decode(ThreadRunRecord.self, from: JSONSerialization.data(withJSONObject: recordJSON)).checkpoints == nil)
}

@Test(.timeLimit(.minutes(1)))
func runCheckpointAgentInitiatedWorkRecordsUnavailableBaselineAndCapturesItsObservedEnd() async throws {
    try await withRunCheckpoint { f in
        let first = try await f.start(), provider = try f.provider()
        await provider.finish(); try await f.complete(.postRun, runID: first.id)
        let preparedBefore = f.harness.checkpointAttempts().reduce(0) { $0 + $1.prepares }, agentID = UUID()
        await provider.activity(.init(id: agentID, state: .running, finishesRun: false))
        try await waitRunCheckpoint { await f.peekRecord()?.id == agentID }
        let agent = try await f.record(agentID)
        #expect(agent.origin == .agent && agent.userMessageID == nil)
        #expect(agent.checkpoints?.baseline.phase == .unavailable)
        #expect(agent.checkpoints?.baseline.unavailableReason == .agentInitiated)
        #expect(agent.checkpoints?.providerReleased == true && agent.checkpoints?.pendingStart == nil)
        #expect(f.harness.checkpointAttempts().reduce(0) { $0 + $1.prepares } == preparedBefore)
        await provider.activity(.init(id: agentID, state: .idle, stopReason: .string("end_turn")))
        try await f.complete(.postRun, runID: agentID)
        #expect(try await f.record(agentID).status == .completed)
        #expect(try await f.checkpoint(.postRun, runID: agentID).receipt != nil)
        #expect(await f.harness.sent(f.thread.id).count == 1)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [ThreadState.interrupted, .failed])
func runCheckpointOnlyKnownCompletedOrInterruptedProviderBoundariesCaptureFinalState(state: ThreadState) async throws {
    try await withRunCheckpoint { f in
        let run = try await f.start()
        try await f.provider().finish(state)
        if state == .interrupted {
            try await f.complete(.postRun, runID: run.id)
            #expect(try await f.record(run.id).status == .interrupted)
            #expect(try await f.currentThread().queuePaused)
        } else {
            try await waitRunCheckpoint { await f.peekRecord(run.id)?.status == .failed }
            let recorded = try await f.record(run.id)
            #expect(recorded.checkpoints?.postRun?.phase == .unavailable)
            #expect(recorded.checkpoints?.postRun?.unavailableReason == .failedRun)
            #expect(f.harness.checkpointAttempts().reduce(0) { $0 + $1.prepares } == 1)
        }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [RunCheckpointStage.baseline, .postRun])
func runCheckpointRestartInspectsExistingEvidenceWithoutRecaptureOrProviderReplay(stage: RunCheckpointStage) async throws {
    try await withRunCheckpoint { f in
        let run: ThreadRunRecord
        if stage == .baseline {
            try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Unacknowledged provider payload"))
            run = try await f.record()
        } else {
            run = try await f.start()
            try await f.provider().finish()
        }
        try await waitRunCheckpoint { await f.peekCheckpoint(stage, runID: run.id)?.phase == .resolving }
        let attempt = try await f.checkpoint(stage, runID: run.id), peer = try f.peer(attempt)
        peer.resolve(); try await waitRunCheckpoint { peer.captureObservation != nil }
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Queued across restart"))
        let captured = await f.engine.current().snapshot
        f.harness.releaseAll(); await f.engine.shutdown()
        let database = try WorkspaceDatabase(url: f.databaseURL)
        let abandoned = PendingWorkspaceEffect(request: .captureRunCheckpoint(threadID: f.thread.id, runID: run.id, stage: stage, plan: peer.plan))
        _ = try await database.commit(captured, event: "fixture.run-checkpoint-lost-ack", commandID: UUID(), effects: [abandoned])
        let claimed = try #require(try await database.claimNextEffect(workerID: UUID()))
        #expect(claimed.id == abandoned.id && claimed.status == .running)
        let recoveredHarness = RunCheckpointHarness(databaseURL: f.databaseURL)
        for record in captured.threads.flatMap({ $0.runHistory ?? [] }) {
            guard let checkpoints = record.checkpoints else { continue }
            for attempt in [checkpoints.baseline] + (checkpoints.postRun.map { [$0] } ?? []) {
                guard let plan = attempt.plan else { continue }
                let recoveredPeer = try recoveredHarness.attempt(plan.id, at: URL(fileURLWithPath: plan.workspacePath))
                recoveredPeer.recover(.ready(try attempt.receipt ?? recoveredPeer.receipt()))
            }
        }
        let reopened = try recoveredHarness.engine()
        do {
            _ = try await reopened.load()
            try await waitRunCheckpoint {
                await reopened.current().snapshot.threads.first { $0.id == f.thread.id }?.runCheckpoint(runID: run.id, stage: stage)?.phase == .ready
            }
            await reopened.drainCheckpointInspections()
            await reopened.drainCommands()
            let restored = try #require(await reopened.current().snapshot.threads.first { $0.id == f.thread.id })
            #expect(restored.activeRun == nil && restored.queuePaused)
            #expect(restored.queuedTurns.map(\.text) == ["Queued across restart"])
            #expect(restored.runHistory?.first { $0.id == run.id }?.checkpoints?.pendingStart == nil)
            #expect(recoveredHarness.providerSessions(f.thread.id).isEmpty)
            #expect(recoveredHarness.checkpointAttempts().allSatisfy { $0.prepares == 0 && $0.captures == 0 })
            #expect(recoveredHarness.checkpointAttempts().contains { $0.inspections == 1 })
            #expect(try await database.effects().first { $0.id == abandoned.id }?.status == .cancelled)
            #expect(try await database.rebuildProjection().snapshot == (await reopened.current().snapshot))
            recoveredHarness.releaseAll(); await reopened.shutdown()
        } catch { recoveredHarness.releaseAll(); await reopened.shutdown(); throw error }
    }
}

@Test(.timeLimit(.minutes(1)))
func runCheckpointLateRestartInspectionPreservesANewerExplicitResumeAndFIFO() async throws {
    try await withRunCheckpoint { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Never replay this interrupted provider payload"))
        let oldRun = try await f.record(), oldAttempt = try await f.checkpoint(.baseline), oldPeer = try f.peer(oldAttempt)
        oldPeer.resolve(); try await waitRunCheckpoint { oldPeer.captureObservation != nil }
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Explicitly resumed FIFO first"))
        let captured = await f.engine.current().snapshot
        f.harness.releaseAll(); await f.engine.shutdown()
        let database = try WorkspaceDatabase(url: f.databaseURL)
        _ = try await database.commit(captured, event: "fixture.held-restart-inspection", commandID: UUID())
        let recoveredHarness = RunCheckpointHarness(databaseURL: f.databaseURL)
        let inspection = try recoveredHarness.attempt(oldAttempt.id, at: f.source), reopened = try recoveredHarness.engine()
        let resumed = RunCheckpointFixture(root: f.root, source: f.source, engine: reopened, harness: recoveredHarness, project: f.project, thread: f.thread)
        do {
            _ = try await reopened.load()
            try await waitRunCheckpoint { inspection.inspections == 1 }
            #expect(try await resumed.currentThread().queuePaused)
            try await reopened.dispatch(.resumeQueue(threadID: f.thread.id))
            let newRun = try await resumed.record(), newAttempt = try await resumed.checkpoint(.baseline), newPeer = try resumed.peer(newAttempt)
            try await waitRunCheckpoint { newPeer.prepares == 1 }
            #expect(newRun.id != oldRun.id)
            #expect(try await resumed.currentThread().queuePaused == false)
            try await reopened.dispatch(.editThread(f.thread.id, .checkpointPolicy(.disabled)))
            try await reopened.dispatch(.submit(threadID: f.thread.id, text: "Explicitly resumed FIFO second"))
            inspection.recover(.ready(try inspection.receipt()))
            await reopened.drainCheckpointInspections()
            #expect(try await resumed.checkpoint(.baseline, runID: oldRun.id).phase == .ready)
            #expect(try await resumed.currentThread().queuePaused == false)
            #expect(recoveredHarness.providerSessions(f.thread.id).isEmpty)
            #expect(try await resumed.record(oldRun.id).checkpoints?.providerReleased == false)
            #expect(try await resumed.record(oldRun.id).checkpoints?.pendingStart == nil)
            let effects = try await database.effects()
            #expect(!effects.contains { effect in
                if case .providerStart(_, let runID, _, _, _) = effect.request { return runID == oldRun.id }
                return false
            })
            try await resumed.complete(.baseline, runID: newRun.id)
            try await waitRunCheckpoint { await recoveredHarness.sent(f.thread.id).count == 1 }
            try await resumed.provider().finish()
            try await resumed.complete(.postRun, runID: newRun.id)
            try await waitRunCheckpoint { await recoveredHarness.sent(f.thread.id).count == 2 }
            #expect(await recoveredHarness.sent(f.thread.id).map(\.input.text) == ["Explicitly resumed FIFO first", "Explicitly resumed FIFO second"])
            recoveredHarness.releaseAll(); await reopened.shutdown()
        } catch { recoveredHarness.releaseAll(); await reopened.shutdown(); throw error }
    }
}

private actor RunCheckpointCompletionFlag {
    private(set) var value = false
    func finish() { value = true }
}

@Test(.timeLimit(.minutes(1)))
func runCheckpointCancellingASecondBaselineWaitingForAPriorDrainNeverJoinsItself() async throws {
    try await withRunCheckpoint(ignoresCancellation: true) { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "First held baseline"))
        let first = try await f.checkpoint(.baseline), firstPeer = try f.peer(first)
        firstPeer.resolve(); try await waitRunCheckpoint { firstPeer.captureObservation != nil }
        try await f.engine.dispatch(.interrupt(threadID: f.thread.id))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Second baseline must wait for the first drain"))
        let secondRun = try await f.record(), second = try await f.checkpoint(.baseline), secondPeer = try f.peer(second)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        try await waitRunCheckpoint {
            try await database.effects().contains { effect in
                guard effect.status == .running else { return false }
                if case .resolveRunCheckpoint(let thread, let run, .baseline, let attempt) = effect.request {
                    return thread == f.thread.id && run == secondRun.id && attempt == second.id
                }
                return false
            }
        }
        await f.engine.drainCommands()
        try await f.engine.dispatch(.editThread(f.thread.id, .draft("The command inbox remains responsive while joining the first drain")))
        #expect(secondPeer.prepares == 0 && f.harness.providerSessions(f.thread.id).isEmpty)
        try await f.engine.dispatch(.interrupt(threadID: f.thread.id))
        try await f.engine.dispatch(.editThread(f.thread.id, .archived(true)))
        try await f.engine.dispatch(.removeProject(projectID: f.project.id, expectedThreadIDs: [f.thread.id]))
        let removed = RunCheckpointCompletionFlag()
        let removal = Task { await f.engine.awaitProjectRemovalCleanup(projectID: f.project.id); await removed.finish() }
        #expect(await removed.value == false)
        try firstPeer.complete()
        try await waitRunCheckpoint { await removed.value }
        await removal.value
        let closed = RunCheckpointCompletionFlag()
        let shutdown = Task { await f.engine.shutdown(); await closed.finish() }
        try await waitRunCheckpoint { await closed.value }
        await shutdown.value
        #expect(secondPeer.prepares == 0 && secondPeer.captures == 0)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        #expect(await f.engine.current().snapshot.threads.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func runCheckpointRemovalAwaitsAnOwnedCaptureAndFencesLateResultsFromReaddedIDsAndPaths() async throws {
    try await withRunCheckpoint(ignoresCancellation: true) { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Removed pending baseline"))
        let run = try await f.record(), attempt = try await f.checkpoint(.baseline), peer = try f.peer(attempt)
        peer.resolve(); try await waitRunCheckpoint { peer.captureObservation != nil }
        try await f.engine.dispatch(.removeProject(projectID: f.project.id, expectedThreadIDs: [f.thread.id]))
        let flag = RunCheckpointCompletionFlag()
        let cleanup = Task { await f.engine.awaitProjectRemovalCleanup(projectID: f.project.id); await flag.finish() }
        var replacementProject = f.project
        replacementProject.path = f.root.appendingPathComponent("Replacement source").path
        var replacement = CodingThread(project: replacementProject); replacement.id = f.thread.id
        try await f.engine.dispatch(.addProjectWithThread(project: replacementProject, thread: replacement))
        let unrelatedProject = WorkspaceProject(path: f.root.appendingPathComponent("Unrelated").path)
        var unrelated = CodingThread(project: unrelatedProject); unrelated.checkpointPolicy = .disabled
        try await f.engine.dispatch(.addProjectWithThread(project: unrelatedProject, thread: unrelated))
        try await f.engine.dispatch(.submit(threadID: unrelated.id, text: "Unrelated commands stay responsive"))
        try await waitRunCheckpoint { await f.harness.sent(unrelated.id).count == 1 }
        #expect(await flag.value == false)
        try peer.complete(); await cleanup.value
        let current = try await f.currentThread()
        #expect(current.workspacePath == replacement.workspacePath && current.runHistory == nil && current.messages.isEmpty)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        #expect(await f.engine.current().error == nil)
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.retryPostRunCheckpoint(threadID: f.thread.id, runID: run.id, expectedAttemptID: attempt.id)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func runCheckpointDiffUsesOnlyTheSelectedRunsSavedReceiptsAndByteLimit() async throws {
    try await withRunCheckpoint { f in
        let run = try await f.start()
        await #expect(throws: GitCheckpointError.self) { try await f.engine.runCheckpointDiff(threadID: f.thread.id, runID: run.id, maxBytes: 73) }
        try await f.provider().finish()
        try await f.complete(.postRun, runID: run.id)
        let diff = try await f.engine.runCheckpointDiff(threadID: f.thread.id, runID: run.id, maxBytes: 73)
        #expect(diff.patch == "Fixture checkpoint diff\n")
        let call = try #require(f.harness.diffCalls().last), record = try await f.record(run.id)
        #expect(call.from == record.checkpoints?.baseline.receipt && call.to == record.checkpoints?.postRun?.receipt)
        #expect(call.maxBytes == 73 && call.paths == nil && !call.ignoreWhitespace)
        await #expect(throws: GitCheckpointError.self) { try await f.engine.runCheckpointDiff(threadID: f.thread.id, runID: UUID(), maxBytes: 73) }
        #expect(f.harness.diffCalls().count == 1)
    }
}

@Test(.timeLimit(.minutes(1)))
func runCheckpointRejectedPlanCommitNeverStartsCaptureOrCreatesAProvider() async throws {
    try await withRunCheckpoint { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Plan commit must succeed first"))
        let attempt = try await f.checkpoint(.baseline), peer = try f.peer(attempt)
        try await waitRunCheckpoint { peer.prepares == 1 }
        try runCheckpointSQL(f.databaseURL, "CREATE TRIGGER reject_checkpoint_event BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'fixture rollback'); END")
        peer.resolve()
        try await waitRunCheckpoint { await f.engine.current().error != nil }
        #expect(peer.captures == 0 && f.harness.providerSessions(f.thread.id).isEmpty)
        let persisted = try await WorkspaceDatabase(url: f.databaseURL).load()
        let checkpoint = try #require(persisted.threads.first { $0.id == f.thread.id }?.runHistory?.last?.checkpoints?.baseline)
        #expect(checkpoint.phase == .resolving && checkpoint.plan == nil)
        try runCheckpointSQL(f.databaseURL, "DROP TRIGGER reject_checkpoint_event")
    }
}
