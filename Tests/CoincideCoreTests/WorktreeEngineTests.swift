import Foundation
import Testing
import CSQLite
@testable import CoincideCore

private actor EngineWorktreePeer: WorkspaceWorktreeSession {
    let request: GitWorktreeRequest
    private var prepareGate: CheckedContinuation<Void, any Error>?
    private var runGate: CheckedContinuation<Void, any Error>?
    private var inspectionGate: CheckedContinuation<Void, any Error>?
    private var resolved = false
    private var evidence = false
    private var submoduleWarning = false
    private var holdCancellation = false
    private var holdInspection = false
    private(set) var prepares = 0
    private(set) var runs = 0
    private(set) var inspections = 0
    private(set) var cancellations = 0
    init(_ request: GitWorktreeRequest) { self.request = request }
    func plan() throws -> GitWorktreePlan {
        let identity = GitWorktreeNodeIdentity(device: 1, inode: 42)
        let branch: String
        let reuse: Bool
        switch request.selection {
        case .createBranch(let name, _), .existingBranch(let name): branch = name; reuse = false
        case .reuse: branch = "main"; reuse = true
        }
        return try GitWorktreePlan(request: request, sourcePath: request.sourcePath,
            commonDirectoryPath: request.sourcePath + "/.git", sourceIdentity: identity,
            commonDirectoryIdentity: identity, destinationParentIdentity: identity,
            branch: branch, baseCommit: String(repeating: "a", count: 40),
            destinationIdentity: reuse ? identity : nil,
            worktreeGitDirectoryPath: reuse ? request.sourcePath + "/.git/worktrees/fixture" : nil,
            worktreeGitDirectoryIdentity: reuse ? identity : nil)
    }
    func result() throws -> GitWorktreeResult {
        let plan = try plan()
        return .init(destinationPath: plan.destinationPath, headCommit: plan.baseCommit, branch: plan.branch,
                     submoduleWarning: submoduleWarning ? GitWorktreeResult.submoduleFailureWarning : nil)
    }
    func prepare() async throws -> GitWorktreePlan {
        prepares += 1
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if !resolved { try await withCheckedThrowingContinuation { prepareGate = $0 } }
            return try plan()
        } onCancel: { Task { await self.cancel() } }
    }
    func run(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult {
        runs += 1
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { runGate = $0 }
            return try result()
        } onCancel: { Task { await self.cancel() } }
    }
    func inspectCompletion(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult? {
        inspections += 1
        return try await withTaskCancellationHandler {
            if holdInspection { try await withCheckedThrowingContinuation { inspectionGate = $0 } }
            return evidence ? try result() : nil
        } onCancel: { Task { await self.cancel() } }
    }
    func resolve() { resolved = true; let saved = prepareGate; prepareGate = nil; saved?.resume() }
    func succeed(withSubmoduleWarning: Bool = false) { submoduleWarning = withSubmoduleWarning; evidence = true; let saved = runGate; runGate = nil; saved?.resume() }
    func markCompleted() { evidence = true }
    func fail(_ message: String = "Fixture Git preparation failed") {
        let saved = runGate ?? prepareGate; runGate = nil; prepareGate = nil
        saved?.resume(throwing: CoincideError(message))
    }
    func completeWhileCancelled() {
        evidence = true; let saved = runGate; runGate = nil; saved?.resume(throwing: CancellationError())
    }
    func keepCancellationPending() { holdCancellation = true }
    func gateInspections() { holdInspection = true; holdCancellation = true }
    func releaseInspection() { holdInspection = false; let saved = inspectionGate; inspectionGate = nil; saved?.resume() }
    private func cancel() {
        cancellations += 1
        guard !holdCancellation else { return }
        let saved = [prepareGate, runGate, inspectionGate]; prepareGate = nil; runGate = nil; inspectionGate = nil
        for continuation in saved { continuation?.resume(throwing: CancellationError()) }
    }
    func releaseAll() {
        holdCancellation = false; holdInspection = false
        let saved = [prepareGate, runGate, inspectionGate]; prepareGate = nil; runGate = nil; inspectionGate = nil
        for continuation in saved { continuation?.resume(throwing: CancellationError()) }
    }
}
private struct EngineWorktreeTurn: Sendable {
    let input: ProviderInput
    let configuration: ProviderConfiguration
}
private actor WorktreeProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var turns: [EngineWorktreeTurn] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [.init(id: "fixture", name: "Fixture")] }
    func send(text: String, thread: CodingThread) { send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) {
        runID = thread.activeRun?.id; turns.append(.init(input: input, configuration: .init(thread: thread)))
    }
    func finish() { if let runID { sink.yield(.context(runID: runID, event: .completed(.idle))) } }
    func interrupt() { if let runID { sink.yield(.context(runID: runID, event: .completed(.interrupted))) } }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { sink.finish() }
}
private final class WorktreeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [UUID: EngineWorktreePeer] = [:]
    private var providers: [UUID: [WorktreeProvider]] = [:]
    func peer(_ request: GitWorktreeRequest) -> EngineWorktreePeer {
        lock.lock(); defer { lock.unlock() }
        if let peer = peers[request.id] { return peer }
        let peer = EngineWorktreePeer(request); peers[request.id] = peer; return peer
    }
    func provider(_ thread: CodingThread) -> any ProviderSession {
        lock.lock(); defer { lock.unlock() }
        let provider = WorktreeProvider(); providers[thread.id, default: []].append(provider); return provider
    }
    func sessions(_ threadID: UUID) -> [WorktreeProvider] { lock.lock(); defer { lock.unlock() }; return providers[threadID] ?? [] }
    func allPeers() -> [EngineWorktreePeer] { lock.lock(); defer { lock.unlock() }; return Array(peers.values) }
    func release() async { for peer in allPeers() { await peer.releaseAll() } }
    func engine(_ database: URL) throws -> WorkspaceEngine {
        try WorkspaceEngine(url: database, providerFactory: { self.provider($0) }, identityResolver: { _ in nil }, worktreeFactory: { self.peer($0) })
    }
}
private struct WorktreeEngineFixture {
    let root: URL
    let engine: WorkspaceEngine
    let harness: WorktreeHarness
    let project: WorkspaceProject
    let thread: CodingThread
    var databaseURL: URL { root.appendingPathComponent("workspace.sqlite") }
    func currentThread() async throws -> CodingThread { try #require(await engine.current().snapshot.threads.first { $0.id == thread.id }) }
    func begin(_ selection: GitWorktreeSelection = .createBranch(name: "feature/native", baseRef: "HEAD"), submodules: ProjectWorktreeSubmoduleMode = .none) async throws -> EngineWorktreePeer {
        try await engine.beginWorktreePreparation(threadID: thread.id, selection: selection, submodules: submodules)
        let state = try #require(await currentThread().workspacePreparation)
        return harness.peer(state.request)
    }
}
private func withWorktreeEngine(_ body: (WorktreeEngineFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let harness = WorktreeHarness(), engine = try harness.engine(root.appendingPathComponent("workspace.sqlite"))
    let project = WorkspaceProject(path: source.path)
    var thread = CodingThread(project: project); thread.providerThreadID = "fixture-old-source-session"
    do {
        try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        try await body(.init(root: root, engine: engine, harness: harness, project: project, thread: thread))
        await harness.release(); await engine.shutdown()
    } catch { await harness.release(); await engine.shutdown(); throw error }
}
private func waitWorktree(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Worktree engine fixture did not reach its explicit state") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1))) func worktreeSubmoduleIntentHoldsProviderUntilFinalResultAndPersistsWarningAcrossRestart() async throws {
    try await withWorktreeEngine { f in
        let peer = try await f.begin(submodules: .recursive)
        try await waitWorktree { await peer.prepares == 1 }
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.load().threads.first?.workspacePreparation?.request.submodules == .recursive)
        try await f.engine.dispatch(.editThread(f.thread.id, .model("captured-before-modules")))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Wait for selected submodules"))
        await peer.resolve(); try await waitWorktree { await peer.runs == 1 }
        let pending = try await f.currentThread()
        #expect(pending.workspacePreparation?.plan?.request.submodules == .recursive)
        #expect(!pending.isBusy && pending.queuedTurns.count == 1 && pending.messages.isEmpty)
        #expect(f.harness.sessions(f.thread.id).isEmpty)
        await #expect(throws: (any Error).self) { try await f.engine.models(thread: pending) }
        await peer.succeed(withSubmoduleWarning: true)
        try await waitWorktree { await f.harness.sessions(f.thread.id).first?.turns.count == 1 }
        let provider = try #require(f.harness.sessions(f.thread.id).first)
        #expect(await provider.turns.first?.configuration.model == "captured-before-modules")
        await provider.finish(); try await waitWorktree { try await f.currentThread().state == .idle }
        let ready = try #require(try await f.currentThread().workspacePreparation)
        #expect(ready.isReady && ready.result?.submoduleWarning == GitWorktreeResult.submoduleFailureWarning)
        #expect(try await database.rebuildProjection().snapshot.threads.first?.workspacePreparation == ready)
        await f.engine.shutdown()
        let reopened = try f.harness.engine(f.databaseURL)
        _ = try await reopened.load()
        #expect(await reopened.current().snapshot.threads.first?.workspacePreparation == ready)
        #expect(await peer.runs == 1)
        await reopened.shutdown()
    }
}

@Test(.timeLimit(.minutes(1))) func worktreeIntentAndResolvedPlanGateFIFOAndPreserveCapturedInputs() async throws {
    try await withWorktreeEngine { f in
        let peer = try await f.begin()
        try await waitWorktree { await peer.prepares == 1 }
        let initial = try await f.currentThread(), state = try #require(initial.workspacePreparation)
        #expect(initial.workspacePath == state.destinationPath && initial.workspacePath != f.project.path)
        #expect(initial.providerThreadID == nil && initial.runtimeID == nil)
        #expect(await f.engine.current().snapshot.workspaceReady(for: f.thread) == false)
        await #expect(throws: (any Error).self) { try await f.engine.models(thread: initial) }
        #expect(f.harness.sessions(f.thread.id).isEmpty)
        let attachment = try await f.engine.attachments.importData(Data("Frozen local context".utf8), name: "context.txt")
        try await f.engine.dispatch(.editThread(f.thread.id, .model("first")))
        try await f.engine.dispatch(.addAttachments(threadID: f.thread.id, attachments: [attachment]))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first turn"))
        try await f.engine.dispatch(.editThread(f.thread.id, .model("second")))
        try await f.engine.dispatch(.editThread(f.thread.id, .permission(.autoAcceptEdits)))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "second turn"))
        try await f.engine.dispatch(.editThread(f.thread.id, .draft("Keep the unsent draft")))
        try await f.engine.dispatch(.resumeQueue(threadID: f.thread.id))
        let waiting = try await f.currentThread()
        #expect(waiting.messages.isEmpty && waiting.activeRun == nil && waiting.queuedTurns.count == 2)
        #expect(waiting.queuedTurns.allSatisfy { $0.configuration.workspacePath == state.destinationPath })
        #expect(f.harness.sessions(f.thread.id).isEmpty)
        #expect(await peer.runs == 0)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.load().threads.first?.workspacePreparation?.plan == nil)
        await peer.resolve()
        try await waitWorktree { await peer.runs == 1 }
        let planned = try #require(try await database.load().threads.first?.workspacePreparation)
        let resolvedPlan = try await peer.plan()
        #expect(planned.phase == .preparing && planned.plan == resolvedPlan)
        let rows = try await database.effects()
        #expect(rows.contains { if case .resolveWorktree = $0.request { $0.status == .succeeded } else { false } })
        #expect(rows.contains { if case .prepareWorktree = $0.request { $0.status == .running } else { false } })
        // The fake Git executor still publishes an existing local checkout directory.
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: state.destinationPath), withIntermediateDirectories: true)
        await peer.succeed()
        try await waitWorktree { await f.harness.sessions(f.thread.id).first?.turns.count == 1 }
        let provider = try #require(f.harness.sessions(f.thread.id).first), first = try #require(await provider.turns.first)
        #expect(first.configuration.workspacePath == state.destinationPath && first.configuration.nativeThreadID == nil)
        #expect(first.configuration.model == "first" && first.configuration.permission == .supervised)
        #expect(first.input.text.contains("context.txt") && first.input.text.contains(attachment.id.uuidString))
        #expect(try await f.engine.attachments.data(for: attachment) == Data("Frozen local context".utf8))
        await provider.finish()
        try await waitWorktree { await provider.turns.count == 2 }
        let second = await provider.turns[1]
        #expect(second.configuration.model == "second" && second.configuration.permission == .autoAcceptEdits)
        #expect(second.configuration.workspacePath == state.destinationPath && second.input.text == "second turn")
        await provider.finish()
        try await waitWorktree { try await f.currentThread().state == .idle }
        let ready = await f.engine.current().snapshot
        #expect(ready.threads[0].messages.filter { $0.role == .user }.map(\.text) == ["first turn", "second turn"])
        #expect(ready.threads[0].messages.first?.attachments == [attachment] && ready.threads[0].draft == "Keep the unsent draft")
        #expect(try await database.rebuildProjection().snapshot == ready)
    }
}

@Test(.timeLimit(.minutes(1))) func failedWorktreeRetryPreservesPartialBytesAndRebasesOnlyQueuedCWD() async throws {
    try await withWorktreeEngine { f in
        let peer = try await f.begin(submodules: .topLevel); try await waitWorktree { await peer.prepares == 1 }
        await peer.resolve(); try await waitWorktree { await peer.runs == 1 }
        let old = try #require(try await f.currentThread().workspacePreparation)
        let partial = URL(fileURLWithPath: old.destinationPath); try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let sentinel = partial.appendingPathComponent("untracked.txt"), bytes = Data("Never remove a partial checkout".utf8)
        try bytes.write(to: sentinel)
        try await f.engine.dispatch(.editThread(f.thread.id, .model("captured")))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "after retry"))
        await peer.fail(); try await waitWorktree { try await f.currentThread().workspacePreparation?.phase == .failed }
        try await f.engine.retryWorktreePreparation(f.thread.id)
        let retried = try #require(try await f.currentThread().workspacePreparation), next = f.harness.peer(retried.request)
        #expect(retried.id != old.id && retried.destinationPath != old.destinationPath)
        #expect(old.request.submodules == .topLevel && retried.request.submodules == .topLevel)
        #expect(retried.previousAttempts == [.init(request: old.request, plan: old.plan)])
        let queued = try #require(try await f.currentThread().queuedTurns.first)
        #expect(queued.configuration.model == "captured" && queued.configuration.workspacePath == retried.destinationPath && queued.configuration.nativeThreadID == nil)
        #expect(try Data(contentsOf: sentinel) == bytes)
        let before = await f.engine.current().snapshot
        let stale = try WorkspaceDecision.make(.effectResult(.prepareWorktree(threadID: f.thread.id, plan: try #require(old.plan)), .worktreePrepared(try await peer.result())), id: UUID(), snapshot: before, now: Date())
        #expect(stale.snapshot == before && stale.effects.isEmpty)
        try await waitWorktree { await next.prepares == 1 }; await next.resolve(); try await waitWorktree { await next.runs == 1 }; await next.succeed()
        try await waitWorktree { await f.harness.sessions(f.thread.id).first?.turns.count == 1 }
        let sent = try #require(await f.harness.sessions(f.thread.id).first?.turns.first)
        #expect(sent.configuration.workspacePath == retried.destinationPath && sent.input.text == "after retry")
        #expect(try Data(contentsOf: sentinel) == bytes)
        await f.harness.sessions(f.thread.id).first?.finish()
    }
}

@Test(.timeLimit(.minutes(1))) func cancelledResolutionCannotReleaseQueueAndRetryNeedsReadiness() async throws {
    try await withWorktreeEngine { f in
        let oldPeer = try await f.begin(); try await waitWorktree { await oldPeer.prepares == 1 }
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "held"))
        let cancelID = UUID()
        let receipt = try await f.engine.dispatch(.cancelWorktreePreparation(f.thread.id), id: cancelID)
        #expect(try await f.engine.dispatch(.cancelWorktreePreparation(f.thread.id), id: cancelID) == receipt)
        try await waitWorktree { try await f.currentThread().workspacePreparation?.phase == .cancelled }
        #expect(try await f.currentThread().queuePaused)
        try await f.engine.retryWorktreePreparation(f.thread.id)
        let state = try #require(try await f.currentThread().workspacePreparation), next = f.harness.peer(state.request)
        try await f.engine.dispatch(.resumeQueue(threadID: f.thread.id))
        #expect(f.harness.sessions(f.thread.id).isEmpty)
        try await waitWorktree { await next.prepares == 1 }; await next.resolve(); try await waitWorktree { await next.runs == 1 }
        #expect(f.harness.sessions(f.thread.id).isEmpty)
        await next.succeed(); try await waitWorktree { await f.harness.sessions(f.thread.id).first?.turns.count == 1 }
        #expect(await oldPeer.runs == 0)
        await f.harness.sessions(f.thread.id).first?.finish()
    }
}

@Test(.timeLimit(.minutes(1))) func worktreeLateCompletionAfterCancelIsReadyButKeepsQueuePaused() async throws {
    try await withWorktreeEngine { f in
        let peer = try await f.begin(); try await waitWorktree { await peer.prepares == 1 }; await peer.resolve(); try await waitWorktree { await peer.runs == 1 }
        await peer.keepCancellationPending()
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Do not start automatically"))
        try await f.engine.cancelWorktreePreparation(f.thread.id)
        try await f.engine.dispatch(.resumeQueue(threadID: f.thread.id))
        try await waitWorktree { await peer.cancellations > 0 }
        await peer.completeWhileCancelled()
        try await waitWorktree { try await f.currentThread().workspacePreparation?.isReady == true }
        let ready = try await f.currentThread()
        #expect(ready.queuePaused && ready.messages.isEmpty && ready.queuedTurns.count == 1)
        #expect(f.harness.sessions(f.thread.id).isEmpty)
        try await f.engine.dispatch(.resumeQueue(threadID: f.thread.id))
        try await waitWorktree { await f.harness.sessions(f.thread.id).first?.turns.count == 1 }
        await f.harness.sessions(f.thread.id).first?.finish()
    }
}

@Test(.timeLimit(.minutes(1))) func worktreeRestartPromotesOnlySavedCompletionAndNeverReleasesQueue() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source"), managed = root.appendingPathComponent("Worktrees")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let project = WorkspaceProject(path: source.path), harness = WorktreeHarness()
    let request = GitWorktreeRequest(sourcePath: source.path, destinationRoot: managed.path, selection: .existingBranch(name: "saved"))
    let peer = harness.peer(request), plan = try await peer.plan()
    var thread = CodingThread(project: project); thread.workspacePath = request.destinationPath
    var preparation = ThreadWorkspacePreparation(request: request); preparation.plan = plan; preparation.phase = .preparing
    thread.workspacePreparation = preparation; thread.draft = "Unsent after restart"
    thread.queuedTurns = [.init(id: UUID(), text: "waiting", configuration: .init(thread: thread), createdAt: Date())]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let databaseURL = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: databaseURL), effectID = UUID()
    _ = try await database.commit(snapshot, event: "fixture.prepared", commandID: UUID(), effects: [.init(id: effectID, request: .prepareWorktree(threadID: thread.id, plan: plan))])
    _ = try await database.claimNextEffect(workerID: UUID())
    await peer.markCompleted()
    let engine = try harness.engine(databaseURL)
    do {
        let opened = try await engine.load()
        #expect(opened.threads[0].workspacePreparation?.phase == .interrupted && opened.threads[0].queuePaused)
        try await waitWorktree { await engine.current().snapshot.threads[0].workspacePreparation?.isReady == true }
        let loaded = await engine.current().snapshot, recovered = try #require(loaded.threads.first)
        #expect(recovered.workspacePreparation?.isReady == true && recovered.workspacePath == request.destinationPath)
        #expect(recovered.queuePaused && recovered.messages.isEmpty && recovered.queuedTurns.count == 1 && recovered.draft == "Unsent after restart")
        #expect(harness.sessions(thread.id).isEmpty)
        #expect(await peer.prepares == 0)
        #expect(await peer.runs == 0)
        #expect(await peer.inspections == 1)
        #expect(try await database.effects().first { $0.id == effectID }?.status == .cancelled)
        #expect(try await database.rebuildProjection().snapshot == loaded)
        try await engine.dispatch(.resumeQueue(threadID: thread.id))
        try await waitWorktree { await harness.sessions(thread.id).first?.turns.count == 1 }
        #expect(await harness.sessions(thread.id).first?.turns.first?.configuration.workspacePath == request.destinationPath)
        await harness.sessions(thread.id).first?.finish(); await engine.shutdown()
    } catch { await harness.release(); await engine.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func unresolvedWorktreeIntentRestartsInterruptedWithoutGitAndCanRetryIntoFreshFolder() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let project = WorkspaceProject(path: source.path), harness = WorktreeHarness()
    let request = GitWorktreeRequest(sourcePath: source.path, destinationRoot: root.appendingPathComponent("Worktrees").path, selection: .createBranch(name: "pending", baseRef: "HEAD"))
    var thread = CodingThread(project: project); thread.workspacePath = request.destinationPath; thread.workspacePreparation = .init(request: request)
    thread.queuedTurns = [.init(id: UUID(), text: "Keep this prompt", configuration: .init(thread: thread), createdAt: Date())]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let databaseURL = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: databaseURL)
    _ = try await database.commit(snapshot, event: "fixture.intent", commandID: UUID(), effects: [.init(id: request.id, request: .resolveWorktree(threadID: thread.id, request: request))])
    let engine = try harness.engine(databaseURL)
    do {
        let loaded = try await engine.load()
        #expect(loaded.threads[0].workspacePreparation?.phase == .interrupted && loaded.threads[0].queuePaused)
        #expect(harness.allPeers().isEmpty && harness.sessions(thread.id).isEmpty)
        try await engine.dispatch(.resumeQueue(threadID: thread.id))
        #expect(harness.sessions(thread.id).isEmpty)
        try await engine.retryWorktreePreparation(thread.id)
        let retried = try #require(await engine.current().snapshot.threads[0].workspacePreparation)
        #expect(retried.id != request.id && retried.destinationPath != request.destinationPath && retried.previousAttempts.first?.request == request)
        let peer = harness.peer(retried.request); try await waitWorktree { await peer.prepares == 1 }
        #expect(await peer.runs == 0)
        await harness.release(); await engine.shutdown()
    } catch { await harness.release(); await engine.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func removingGatedWorktreeCannotResurrectReaddedIDsAndUnrelatedTurnRemainsResponsive() async throws {
    try await withWorktreeEngine { f in
        let peer = try await f.begin(submodules: .recursive); await peer.keepCancellationPending(); try await waitWorktree { await peer.prepares == 1 }
        let otherProject = WorkspaceProject(path: f.root.appendingPathComponent("unrelated").path), other = CodingThread(project: otherProject)
        try await f.engine.dispatch(.addProjectWithThread(project: otherProject, thread: other))
        try await f.engine.dispatch(.removeProject(projectID: f.project.id, expectedThreadIDs: [f.thread.id]))
        try await waitWorktree { await peer.cancellations > 0 }
        try await f.engine.dispatch(.addProjectWithThread(project: f.project, thread: f.thread))
        try await f.engine.dispatch(.submit(threadID: other.id, text: "unrelated continues"))
        try await waitWorktree { await f.harness.sessions(other.id).first?.turns.count == 1 }
        await peer.resolve()
        await f.engine.awaitProjectRemovalCleanup(projectID: f.project.id)
        let snapshot = await f.engine.current().snapshot, readded = try #require(snapshot.threads.first { $0.id == f.thread.id })
        #expect(readded.workspacePreparation == nil && readded.workspacePath == f.project.path && readded.messages.isEmpty)
        #expect(await peer.runs == 0 && f.harness.sessions(f.thread.id).isEmpty)
        #expect(await f.engine.current().error == nil)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.effects().filter { $0.request.worktreeAttemptID != nil }.allSatisfy { $0.status == .cancelled })
        await f.harness.sessions(other.id).first?.finish()
    }
}

@Test(.timeLimit(.minutes(1))) func retryInspectionIsOwnedUntilRemovalAndOldResultCannotReviveReaddedConversation() async throws {
    try await withWorktreeEngine { f in
        let peer = try await f.begin(); try await waitWorktree { await peer.prepares == 1 }; await peer.resolve(); try await waitWorktree { await peer.runs == 1 }
        await peer.fail(); try await waitWorktree { try await f.currentThread().workspacePreparation?.phase == .failed }
        await peer.gateInspections()
        let previousInspections = await peer.inspections
        let retry = Task { try await f.engine.retryWorktreePreparation(f.thread.id) }
        do {
            try await waitWorktree { await peer.inspections > previousInspections }
            try await f.engine.dispatch(.removeProject(projectID: f.project.id, expectedThreadIDs: [f.thread.id]))
            try await f.engine.dispatch(.addProjectWithThread(project: f.project, thread: f.thread))
            await peer.markCompleted(); await peer.releaseInspection()
            await #expect(throws: CancellationError.self) { try await retry.value }
            await f.engine.awaitProjectRemovalCleanup(projectID: f.project.id)
            let current = try await f.currentThread()
            #expect(current.workspacePreparation == nil && current.workspacePath == f.project.path && current.messages.isEmpty)
            #expect(await peer.prepares == 1)
            #expect(await peer.runs == 1)
            #expect(await f.engine.current().error == nil)
        } catch { await peer.releaseInspection(); retry.cancel(); _ = try? await retry.value; throw error }
    }
}

@Test(.timeLimit(.minutes(1))) func failedEmptyWorktreeCanChooseCorrectedSelectionWithoutLosingAttemptHistory() async throws {
    try await withWorktreeEngine { f in
        let peer = try await f.begin(.createBranch(name: "first-choice", baseRef: "missing-local-ref"))
        try await waitWorktree { await peer.prepares == 1 }; await peer.fail("The local base ref does not exist")
        try await waitWorktree { try await f.currentThread().workspacePreparation?.phase == .failed }
        let old = try #require(try await f.currentThread().workspacePreparation)
        let corrected = try await f.begin(.existingBranch(name: "corrected"))
        let state = try #require(try await f.currentThread().workspacePreparation)
        #expect(state.request.sourcePath == f.project.path && state.request.selection == .existingBranch(name: "corrected"))
        #expect(state.previousAttempts == [.init(request: old.request, plan: nil)] && state.id != old.id)
        try await waitWorktree { await corrected.prepares == 1 }; await corrected.resolve(); try await waitWorktree { await corrected.runs == 1 }; await corrected.succeed()
        try await waitWorktree { try await f.currentThread().workspacePreparation?.isReady == true }
        let ready = try await f.currentThread()
        #expect(ready.messages.isEmpty && ready.workspacePath == state.destinationPath)
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.dispatch(.editThread(f.thread.id, .workspacePath(f.project.path))) }
        try await f.engine.dispatch(.editThread(f.thread.id, .workspacePath(ready.workspacePath)))
        #expect(try await f.currentThread() == ready)
        #expect(await f.engine.current().error == nil)
        let next = try await f.begin(.existingBranch(name: "next-checkout"))
        #expect(try await f.currentThread().workspacePreparation?.request.sourcePath == ready.workspacePath)
        try await waitWorktree { await next.prepares == 1 }
    }
}

@Test(.timeLimit(.minutes(1))) func worktreeCommandsRejectSeededStateAndCredentialURLBeforeSnapshotOrOutbox() async throws {
    try await withWorktreeEngine { f in
        let request = GitWorktreeRequest(sourcePath: f.project.path, destinationRoot: f.engine.worktreesRoot.path, selection: .existingBranch(name: "seeded"))
        var seeded = CodingThread(project: f.project); seeded.workspacePath = request.destinationPath; seeded.workspacePreparation = .init(request: request)
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.dispatch(.createThread(seeded)) }
        let secret = ["fixture", "private", "base"].joined(separator: "-")
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.beginWorktreePreparation(threadID: f.thread.id, selection: .createBranch(name: "safe-branch", baseRef: "https://user:" + secret + "@example.invalid/repo"))
        }
        let snapshot = await f.engine.current().snapshot, database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(snapshot.threads.count == 1 && snapshot.threads[0].workspacePreparation == nil && snapshot.threads[0].workspacePath == f.project.path)
        #expect(try await database.effects().isEmpty)
        for suffix in ["", "-wal", "-shm"] {
            if let bytes = try? Data(contentsOf: URL(fileURLWithPath: f.databaseURL.path + suffix)) { #expect(bytes.range(of: Data(secret.utf8)) == nil) }
        }
        #expect(f.harness.allPeers().isEmpty)
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first normal turn"))
        try await waitWorktree { await f.harness.sessions(f.thread.id).first?.turns.count == 1 }
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.beginWorktreePreparation(threadID: f.thread.id, selection: .existingBranch(name: "too-late")) }
        #expect(f.harness.allPeers().isEmpty)
        await f.harness.sessions(f.thread.id).first?.finish()
    }
}

@Test(.timeLimit(.minutes(1))) func worktreeIntentTransactionRollsBackPlanOutboxAndReceiptTogether() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let project = WorkspaceProject(path: root.appendingPathComponent("source").path), thread = CodingThread(project: project)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let databaseURL = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: databaseURL)
    _ = try await database.commit(snapshot, event: "fixture.original", commandID: UUID())
    let base = try await database.revision(), request = GitWorktreeRequest(sourcePath: project.path, destinationRoot: root.appendingPathComponent("Worktrees").path, selection: .existingBranch(name: "atomic"))
    let commandID = UUID(), decision = try WorkspaceDecision.make(.beginWorktreePreparation(threadID: thread.id, request: request, expectedSourcePath: thread.workspacePath, previousAttemptID: nil, incarnation: UUID()), id: commandID, snapshot: base.snapshot, now: Date())
    var connection: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &connection) == SQLITE_OK)
    let handle = try #require(connection); defer { sqlite3_close(handle) }
    #expect(sqlite3_exec(handle, "CREATE TRIGGER reject_worktree_audit BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'fixture rollback'); END", nil, nil, nil) == SQLITE_OK)
    await #expect(throws: (any Error).self) {
        try await database.commit(decision.snapshot, event: "fixture.intent", commandID: commandID, expectedSequence: base.sequence, effects: decision.effects)
    }
    #expect(try await database.revision() == base)
    #expect(try await database.effects().isEmpty)
    #expect(try await database.receipt(commandID) == nil)
    #expect(sqlite3_exec(handle, "DROP TRIGGER reject_worktree_audit", nil, nil, nil) == SQLITE_OK)
    let receipt = try await database.commit(decision.snapshot, event: "fixture.intent", commandID: commandID, expectedSequence: base.sequence, effects: decision.effects)
    #expect(try await database.receipt(commandID) == receipt)
    #expect(try await database.rebuildProjection().snapshot == decision.snapshot)
    let wrong = GitWorktreeRequest(sourcePath: project.path, destinationRoot: request.destinationRoot, selection: .existingBranch(name: "other"))
    await #expect(throws: (any Error).self) {
        try await database.commit(decision.snapshot, event: "fixture.bad-effect", commandID: UUID(), effects: [.init(request: .resolveWorktree(threadID: thread.id, request: wrong))])
    }
    #expect(try await database.effects().count == 1)
}

@Test func worktreePreparationValidatesCompletionAndLegacyThreadsWithoutPreparationStillDecode() async throws {
    let project = WorkspaceProject(path: "/tmp/coincide-worktree-model-source")
    var thread = CodingThread(project: project)
    let legacyData = try JSONEncoder().encode(thread)
    var object = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
    object.removeValue(forKey: "workspacePreparation")
    let decoded = try JSONDecoder().decode(CodingThread.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded == thread && decoded.workspacePreparation == nil)
    let request = GitWorktreeRequest(sourcePath: project.path, destinationRoot: "/tmp/coincide-worktree-model-managed", selection: .existingBranch(name: "model"))
    let peer = EngineWorktreePeer(request), plan = try await peer.plan()
    thread.workspacePath = request.destinationPath
    var state = ThreadWorkspacePreparation(request: request); state.phase = .completed
    thread.workspacePreparation = state
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(snapshot) }
    state.plan = plan; state.result = .init(destinationPath: request.destinationPath, headCommit: String(repeating: "c", count: 40), branch: plan.branch)
    snapshot.threads[0].workspacePreparation = state
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(snapshot) }
    state.result = try await peer.result(); snapshot.threads[0].workspacePreparation = state
    try WorkspaceJournal.validate(snapshot)
    state.result = .init(destinationPath: plan.destinationPath, headCommit: plan.baseCommit, branch: plan.branch,
                         submoduleWarning: GitWorktreeResult.submoduleFailureWarning)
    snapshot.threads[0].workspacePreparation = state
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(snapshot) }
    state.phase = .preparing; state.result = nil; snapshot.threads[0].workspacePreparation = state
    var wrongConfiguration = ProviderConfiguration(thread: thread); wrongConfiguration.workspacePath = project.path
    snapshot.threads[0].queuedTurns = [.init(id: UUID(), text: "captured in another folder", configuration: wrongConfiguration, createdAt: Date())]
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(snapshot) }
    snapshot.threads[0].queuedTurns[0].configuration.workspacePath = request.destinationPath
    try WorkspaceJournal.validate(snapshot)
}

private actor WorktreeLoadFlag {
    private(set) var finished = false
    func finish() { finished = true }
}
@Test(.timeLimit(.minutes(1))) func worktreeCompletionProbeCannotBlockLoadOrUnrelatedCommands() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let project = WorkspaceProject(path: source.path), harness = WorktreeHarness()
    let request = GitWorktreeRequest(sourcePath: source.path, destinationRoot: root.appendingPathComponent("Worktrees").path, selection: .existingBranch(name: "background"))
    let peer = harness.peer(request), plan = try await peer.plan()
    await peer.gateInspections()
    var thread = CodingThread(project: project); thread.workspacePath = request.destinationPath
    var state = ThreadWorkspacePreparation(request: request); state.plan = plan; state.phase = .preparing
    thread.workspacePreparation = state; thread.queuedTurns = [.init(id: UUID(), text: "Held during recovery", configuration: .init(thread: thread), createdAt: Date())]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let databaseURL = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: databaseURL)
    _ = try await database.commit(snapshot, event: "fixture.interrupted-plan", commandID: UUID())
    let engine = try harness.engine(databaseURL), flag = WorktreeLoadFlag()
    let loading = Task { let value = try await engine.load(); await flag.finish(); return value }
    do {
        try await waitWorktree { await peer.inspections == 1 }
        try await waitWorktree { await flag.finished }
        let loaded = try await loading.value
        #expect(loaded.threads[0].workspacePreparation?.phase == .interrupted && loaded.threads[0].queuePaused)
        let otherProject = WorkspaceProject(path: root.appendingPathComponent("other").path), other = CodingThread(project: otherProject)
        try await engine.dispatch(.addProjectWithThread(project: otherProject, thread: other))
        try await engine.dispatch(.submit(threadID: other.id, text: "Independent while inspection is gated"))
        try await waitWorktree { await harness.sessions(other.id).first?.turns.count == 1 }
        #expect(harness.sessions(thread.id).isEmpty)
        #expect(await engine.current().snapshot.threads.first { $0.id == thread.id }?.workspacePreparation?.isReady == false)
        await peer.markCompleted(); await peer.releaseInspection()
        try await waitWorktree { await engine.current().snapshot.threads.first { $0.id == thread.id }?.workspacePreparation?.isReady == true }
        let recovered = try #require(await engine.current().snapshot.threads.first { $0.id == thread.id })
        #expect(recovered.queuePaused && recovered.messages.isEmpty && harness.sessions(thread.id).isEmpty)
        await harness.sessions(other.id).first?.finish(); await engine.shutdown()
    } catch {
        await peer.releaseInspection(); loading.cancel(); _ = try? await loading.value
        await harness.release(); await engine.shutdown(); throw error
    }
}
