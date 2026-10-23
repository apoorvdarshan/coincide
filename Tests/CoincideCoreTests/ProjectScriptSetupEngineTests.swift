import Foundation
import Testing
import CSQLite
@testable import CoincideCore

private final class SetupTestSignal<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var waiters: [CheckedContinuation<Value, any Error>] = []
    func wait() async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await waitIgnoringCancellation()
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
    func waitIgnoringCancellation() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let current = lock.withLock { () -> Result<Value, any Error>? in
                if let result { return result }
                waiters.append(continuation); return nil
            }
            if let current { continuation.resume(with: current) }
        }
    }
    func finish(_ result: Result<Value, any Error>) {
        let pending = lock.withLock { () -> [CheckedContinuation<Value, any Error>] in
            guard self.result == nil else { return [] }
            self.result = result; let values = waiters; waiters = []; return values
        }
        for waiter in pending { waiter.resume(with: result) }
    }
}

private actor SetupOutputObserver {
    private(set) var latest: ProjectScriptOutputSnapshot?
    private(set) var ordered = true
    func receive(_ value: ProjectScriptOutputSnapshot) {
        if let latest, value.sequence <= latest.sequence { ordered = false }
        latest = value
    }
}

private actor SetupCompletionFlag {
    private(set) var value = false
    func finish() { value = true }
}

/// The synchronous handoff and actual STARTED acknowledgement have independent gates.
private final class SetupExecutionPeer: ProjectScriptExecutionSession, @unchecked Sendable {
    let plan: ProjectScriptExecutionPlan
    private let lock = NSLock()
    private let started = SetupTestSignal<Void>(), exit = SetupTestSignal<ProjectScriptCommandExit>()
    private let closeGate = SetupTestSignal<Void>()
    private let ignoresWaitCancellation: Bool
    private let stream: AsyncStream<ProjectScriptOutputChunk>
    private let sink: AsyncStream<ProjectScriptOutputChunk>.Continuation
    private var preparedCount = 0, startCount = 0, closeCount = 0, consumerCount = 0, consumerEndCount = 0
    private var holdClose = false, closed = false
    init(_ plan: ProjectScriptExecutionPlan, ignoresWaitCancellation: Bool = false) {
        self.plan = plan; self.ignoresWaitCancellation = ignoresWaitCancellation
        let pair = AsyncStream<ProjectScriptOutputChunk>.makeStream()
        stream = pair.stream; sink = pair.continuation
    }
    var prepares: Int { lock.withLock { preparedCount } }
    var starts: Int { lock.withLock { startCount } }
    var closes: Int { lock.withLock { closeCount } }
    var consumers: Int { lock.withLock { consumerCount } }
    var consumersEnded: Int { lock.withLock { consumerEndCount } }
    var isClosed: Bool { lock.withLock { closed } }
    func prepare() async throws { lock.withLock { preparedCount += 1 } }
    func start() throws {
        try lock.withLock {
            guard !closed, startCount == 0 else { throw ProjectScriptExecutionError(.closed) }
            startCount += 1
        }
    }
    func waitUntilStarted() async throws {
        if ignoresWaitCancellation { try await started.waitIgnoringCancellation() }
        else { try await started.wait() }
    }
    func waitForCommandExit() async throws -> ProjectScriptCommandExit {
        if ignoresWaitCancellation { return try await exit.waitIgnoringCancellation() }
        return try await exit.wait()
    }
    func acknowledgeStart() { started.finish(.success(())) }
    func complete(_ value: ProjectScriptCommandExit) { exit.finish(.success(value)) }
    func failStart() { started.finish(.failure(ProjectScriptExecutionError(.launchFailed))) }
    func holdClosure() { lock.withLock { holdClose = true } }
    func releaseClosure() { closeGate.finish(.success(())) }
    func emit(_ data: Data, sequence: UInt64 = 0) { sink.yield(.init(sequence: sequence, data: data)) }
    func consumeOutput(_ receive: @escaping @Sendable (ProjectScriptOutputChunk) async -> Void) async throws {
        lock.withLock { consumerCount += 1 }
        defer { lock.withLock { consumerEndCount += 1 } }
        for await chunk in stream { try Task.checkCancellation(); await receive(chunk) }
    }
    func sendInput(_ data: Data) async throws { }
    func resize(columns: Int, rows: Int) async throws { }
    func close() async {
        let held = lock.withLock { closeCount += 1; return holdClose }
        if held { _ = try? await closeGate.waitIgnoringCancellation() }
        lock.withLock { closed = true }
        started.finish(.failure(CancellationError())); exit.finish(.failure(CancellationError())); sink.finish()
    }
    func releaseAll() {
        closeGate.finish(.success(())); started.finish(.failure(CancellationError()))
        exit.finish(.failure(CancellationError())); sink.finish()
    }
}

private actor SetupCheckoutPeer: WorkspaceWorktreeSession {
    let request: GitWorktreeRequest
    let configuration: ProjectConfiguration
    private let release = SetupTestSignal<Void>()
    private(set) var runs = 0
    init(_ request: GitWorktreeRequest, configuration: ProjectConfiguration) {
        self.request = request; self.configuration = configuration
    }
    func prepare() throws -> GitWorktreePlan {
        let identity = GitWorktreeNodeIdentity(device: 1, inode: 42)
        let branch: String
        switch request.selection {
        case .createBranch(let value, _), .existingBranch(let value): branch = value
        case .reuse: branch = "fixture"
        }
        return try .init(request: request, sourcePath: request.sourcePath,
            commonDirectoryPath: request.sourcePath + "/.git", sourceIdentity: identity,
            commonDirectoryIdentity: identity, destinationParentIdentity: identity,
            branch: branch, baseCommit: String(repeating: "a", count: 40))
    }
    func run(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult {
        runs += 1
        try await release.wait(); try Task.checkCancellation()
        let destination = URL(fileURLWithPath: request.destinationPath)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try JSONEncoder().encode(configuration).write(to: destination.appendingPathComponent("t3.json"))
        return .init(destinationPath: plan.destinationPath, headCommit: plan.baseCommit, branch: plan.branch)
    }
    func inspectCompletion(_ plan: GitWorktreePlan) -> GitWorktreeResult? { nil }
    func complete() { release.finish(.success(())) }
    func cancel() { release.finish(.failure(CancellationError())) }
}

private actor SetupProviderPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var turns: [ProviderInput] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [.init(id: "setup-fixture", name: "Setup fixture")] }
    func send(text: String, thread: CodingThread) { send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) { runID = thread.activeRun?.id; turns.append(input) }
    func finish() { if let runID { sink.yield(.context(runID: runID, event: .completed(.idle))) } }
    func interrupt() { if let runID { sink.yield(.context(runID: runID, event: .completed(.interrupted))) } }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { sink.finish() }
}

private final class SetupEngineHarness: @unchecked Sendable {
    let configuration: ProjectConfiguration
    let ignoresScriptWaitCancellation: Bool
    let throwsScriptFactory: Bool
    private let lock = NSLock()
    private var checkouts: [UUID: SetupCheckoutPeer] = [:]
    private var scripts: [UUID: SetupExecutionPeer] = [:]
    private var providers: [UUID: [SetupProviderPeer]] = [:]
    init(configuration: ProjectConfiguration, ignoresScriptWaitCancellation: Bool = false, throwsScriptFactory: Bool = false) {
        self.configuration = configuration; self.ignoresScriptWaitCancellation = ignoresScriptWaitCancellation
        self.throwsScriptFactory = throwsScriptFactory
    }
    func checkout(_ request: GitWorktreeRequest) -> SetupCheckoutPeer {
        lock.withLock {
            if let value = checkouts[request.id] { return value }
            let value = SetupCheckoutPeer(request, configuration: configuration); checkouts[request.id] = value; return value
        }
    }
    func script(_ plan: ProjectScriptExecutionPlan) -> SetupExecutionPeer {
        lock.withLock {
            if let value = scripts[plan.id] { return value }
            let value = SetupExecutionPeer(plan, ignoresWaitCancellation: ignoresScriptWaitCancellation); scripts[plan.id] = value; return value
        }
    }
    func provider(_ thread: CodingThread) -> SetupProviderPeer {
        lock.withLock {
            let value = SetupProviderPeer(); providers[thread.id, default: []].append(value); return value
        }
    }
    func providerSessions(_ threadID: UUID) -> [SetupProviderPeer] { lock.withLock { providers[threadID] ?? [] } }
    func scriptSessions() -> [SetupExecutionPeer] { lock.withLock { Array(scripts.values) } }
    func engine(_ database: URL, planner: WorkspaceEngine.ProjectScriptPlanner? = nil,
                checkoutFactory: @escaping WorkspaceEngine.PullRequestCheckoutFactory = { GitHubPullRequestCheckoutService(request: $0) }) throws -> WorkspaceEngine {
        let factory: WorkspaceEngine.ProjectScriptFactory = {
            if self.throwsScriptFactory { throw ProjectScriptExecutionError(.helperUnavailable) }
            return self.script($0)
        }
        if let planner {
            return try WorkspaceEngine(url: database, providerFactory: { self.provider($0) }, identityResolver: { _ in nil },
                worktreeFactory: { self.checkout($0) }, projectScriptPlanner: planner, projectScriptFactory: factory, pullRequestCheckoutFactory: checkoutFactory)
        }
        return try WorkspaceEngine(url: database, providerFactory: { self.provider($0) }, identityResolver: { _ in nil },
            worktreeFactory: { self.checkout($0) }, projectScriptFactory: factory, pullRequestCheckoutFactory: checkoutFactory)
    }
    func releaseAll() async {
        let values = lock.withLock { (Array(checkouts.values), Array(scripts.values)) }
        for checkout in values.0 { await checkout.cancel() }
        for script in values.1 { script.releaseAll() }
    }
}

private struct SetupEngineFixture {
    let root: URL, engine: WorkspaceEngine, harness: SetupEngineHarness
    let project: WorkspaceProject, thread: CodingThread
    var databaseURL: URL { root.appendingPathComponent("workspace.sqlite") }
    func currentThread() async throws -> CodingThread { try #require(await engine.current().snapshot.threads.first { $0.id == thread.id }) }
    func currentSetup() async throws -> ThreadProjectScriptRun { try #require(try await currentThread().workspacePreparation?.setup) }
    func awaitingApproval() async throws -> ThreadProjectScriptRun {
        try await waitSetup { try await currentSetup().phase == .awaitingApproval }
        return try await currentSetup()
    }
    func approve(_ run: ThreadProjectScriptRun) async throws -> SetupExecutionPeer {
        let plan = try #require(run.plan)
        try await engine.approveProjectScript(threadID: thread.id, runID: run.id, expectedPlan: plan)
        try await waitSetup { harness.scriptSessions().first { $0.plan.id == run.id }?.starts == 1 }
        return harness.script(plan)
    }
    func completeCheckout(review: Bool = true) async throws {
        try await engine.beginWorktreePreparation(threadID: thread.id,
            selection: .createBranch(name: "setup-fixture", baseRef: "HEAD"), reviewSetup: review)
        let request = try #require(try await currentThread().workspacePreparation?.request)
        let peer = harness.checkout(request)
        try await waitSetup { await peer.runs == 1 }
        await peer.complete()
        try await waitSetup { try await currentThread().workspacePreparation?.isReady == true }
    }
}

private func withSetupEngine(scripts: [ProjectScript], ignoresScriptWaitCancellation: Bool = false, throwsScriptFactory: Bool = false,
                             planner: WorkspaceEngine.ProjectScriptPlanner? = nil,
                             checkoutFactory: @escaping WorkspaceEngine.PullRequestCheckoutFactory = { GitHubPullRequestCheckoutService(request: $0) },
                             _ body: (SetupEngineFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace().resolvingSymlinksInPath(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source 工作"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let configuration = try ProjectConfiguration(scripts: scripts)
    let harness = SetupEngineHarness(configuration: configuration, ignoresScriptWaitCancellation: ignoresScriptWaitCancellation,
                                     throwsScriptFactory: throwsScriptFactory)
    try JSONEncoder().encode(configuration).write(to: source.appendingPathComponent("t3.json"))
    let engine = try harness.engine(root.appendingPathComponent("workspace.sqlite"), planner: planner, checkoutFactory: checkoutFactory), project = WorkspaceProject(path: source.path)
    let thread = CodingThread(project: project)
    do {
        try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        try await body(.init(root: root, engine: engine, harness: harness, project: project, thread: thread))
        await harness.releaseAll(); await engine.shutdown()
    } catch { await harness.releaseAll(); await engine.shutdown(); throw error }
}

private func waitSetup(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The setup engine fixture did not reach its controlled state.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func setupReviewSelectsFirstRoleAndNeverStartsWithoutExactApproval() async throws {
    let scripts: [ProjectScript] = [
        try .init(name: "Manual only", command: "printf manual"),
        try .init(name: "First setup", command: "printf first", runOnWorktreeCreate: true),
        try .init(name: "Second setup", command: "printf second", runOnWorktreeCreate: true)
    ]
    try await withSetupEngine(scripts: scripts) { f in
        #expect(f.harness.scriptSessions().isEmpty)
        try await f.completeCheckout()
        let run = try await f.awaitingApproval(), plan = try #require(run.plan)
        let preparedThread = try await f.currentThread()
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(plan.scriptIndex == 1 && plan.script == scripts[1])
        #expect(plan.projectRoot == f.project.path && plan.workspacePath == preparedThread.workspacePath)
        #expect(try await database.load().threads.first?.workspacePreparation?.setup == run)
        let pendingEffects = try await database.effects()
        #expect(!pendingEffects.contains { if case .startProjectScript = $0.request { true } else { false } })
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Hold until approved"))
        #expect(f.harness.scriptSessions().isEmpty && f.harness.providerSessions(f.thread.id).isEmpty)
        #expect(await f.engine.current().snapshot.workspaceReady(for: preparedThread))
        #expect(!(await f.engine.current().snapshot.providerReady(for: preparedThread)))
        await #expect(throws: (any Error).self) { try await f.engine.models(thread: preparedThread) }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var script = try #require(object["script"] as? [String: Any]); script["command"] = "printf unreviewed"; object["script"] = script
        let unreviewed = try JSONDecoder().decode(ProjectScriptExecutionPlan.self, from: JSONSerialization.data(withJSONObject: object))
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.approveProjectScript(threadID: f.thread.id, runID: run.id, expectedPlan: unreviewed)
        }
        #expect(f.harness.scriptSessions().isEmpty)
        let peer = try await f.approve(run)
        #expect(peer.starts == 1 && peer.prepares == 1)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        #expect(try await database.load().threads.first?.workspacePreparation?.setup?.phase == .starting)
    }
}

@Test(.timeLimit(.minutes(1)))
func setupRequiresExplicitReviewChoiceAndMissingRoleDoesNotBlockProvider() async throws {
    for review in [false, true] {
        let script = try ProjectScript(name: "Declared script", command: "printf declared", runOnWorktreeCreate: !review)
        try await withSetupEngine(scripts: [script]) { f in
            #expect(f.harness.scriptSessions().isEmpty)
            try await f.completeCheckout(review: review)
            if review { try await waitSetup { try await f.currentSetup().phase == .skipped } }
            else {
                let preparation = try #require(try await f.currentThread().workspacePreparation)
                #expect(preparation.setup == nil)
                var legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preparation)) as? [String: Any])
                legacyObject.removeValue(forKey: "setup")
                let legacy = try JSONDecoder().decode(ThreadWorkspacePreparation.self, from: JSONSerialization.data(withJSONObject: legacyObject))
                #expect(legacy == preparation && legacy.setup == nil)
            }
            try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "No setup command was selected"))
            try await waitSetup { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
            #expect(f.harness.scriptSessions().isEmpty)
            await f.harness.providerSessions(f.thread.id).first?.finish()
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func setupSkipBeforeCheckoutCompletesWithoutWaitingForGitOrStartingDiscovery() async throws {
    let script = try ProjectScript(name: "Skip before checkout", command: "printf must-not-start", runOnWorktreeCreate: true)
    try await withSetupEngine(scripts: [script]) { f in
        try await f.engine.beginWorktreePreparation(threadID: f.thread.id,
            selection: .createBranch(name: "skip-pending-checkout", baseRef: "HEAD"), reviewSetup: true)
        let preparation = try #require(try await f.currentThread().workspacePreparation), run = try #require(preparation.setup)
        let checkout = f.harness.checkout(preparation.request)
        try await waitSetup { await checkout.runs == 1 }
        #expect(run.phase == .waitingForCheckout)
        try await f.engine.skipProjectScript(threadID: f.thread.id, runID: run.id)
        try await waitSetup { try await f.currentSetup().phase == .skipped }
        let waiting = try await f.currentThread()
        #expect(waiting.workspacePreparation?.isReady == false && f.harness.scriptSessions().isEmpty)
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Wait only for checkout"))
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        await checkout.complete()
        try await waitSetup { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
        #expect(try await f.currentSetup().id == run.id)
        #expect(try await f.currentSetup().phase == .skipped)
        let database = try WorkspaceDatabase(url: f.databaseURL), effects = try await database.effects()
        #expect(!effects.contains { if case .resolveProjectScript = $0.request { true } else { false } })
        #expect(f.harness.scriptSessions().isEmpty)
        await f.harness.providerSessions(f.thread.id).first?.finish()
    }
}

@Test
func setupReusingMainCheckoutFromLinkedProjectSkipsSetupAndRemainsProviderReady() throws {
    let project = WorkspaceProject(path: "/fixture/coincide-main-reuse/linked"), mainPath = "/fixture/coincide-main-reuse/main"
    let common = mainPath + "/.git", commonIdentity = GitWorktreeNodeIdentity(device: 1, inode: 20)
    let sourceIdentity = GitWorktreeNodeIdentity(device: 1, inode: 21), sourceAdminIdentity = GitWorktreeNodeIdentity(device: 1, inode: 22)
    let request = GitWorktreeRequest(sourcePath: project.path, destinationRoot: "/fixture/coincide-main-reuse/managed", selection: .reuse(path: mainPath))
    let plan = try GitWorktreePlan(request: request, sourcePath: project.path,
        commonDirectoryPath: common, sourceIdentity: sourceIdentity, commonDirectoryIdentity: commonIdentity,
        destinationParentIdentity: .init(device: 1, inode: 23), branch: "main", baseCommit: String(repeating: "a", count: 40),
        destinationIdentity: .init(device: 1, inode: 24), worktreeGitDirectoryPath: common,
        worktreeGitDirectoryIdentity: commonIdentity, sourceGitDirectoryPath: common + "/worktrees/linked",
        sourceGitDirectoryIdentity: sourceAdminIdentity)
    var thread = CodingThread(project: project)
    var preparation = ThreadWorkspacePreparation(request: request, reviewSetup: true)
    preparation.phase = .preparing; preparation.plan = plan
    thread.workspacePath = mainPath; thread.workspacePreparation = preparation
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let result = GitWorktreeResult(destinationPath: mainPath, headCommit: plan.baseCommit, branch: plan.branch)
    let decision = try WorkspaceDecision.make(.effectResult(.prepareWorktree(threadID: thread.id, plan: plan), .worktreePrepared(result)),
        id: UUID(), snapshot: snapshot, now: Date())
    let ready = try #require(decision.snapshot.threads.first), completed = try #require(ready.workspacePreparation)
    #expect(project.path != mainPath && plan.sourceGitDirectoryPath != common)
    #expect(completed.isReady && !completed.permitsProjectSetup)
    #expect(completed.setup?.phase == .skipped && completed.setup?.plan == nil)
    #expect(!decision.effects.contains { if case .resolveProjectScript = $0.request { true } else { false } })
    #expect(decision.snapshot.providerReady(for: ready))
    try completed.validate(thread: ready)
}

@Test(.timeLimit(.minutes(1)))
func setupAsyncReleasesOnlyAfterActualStartedAndLaterFailurePreservesFIFO() async throws {
    let script = try ProjectScript(name: "Async setup", command: "printf async", runOnWorktreeCreate: true)
    try await withSetupEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let run = try await f.awaitingApproval()
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first queued turn"))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "second queued turn"))
        let peer = try await f.approve(run)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        #expect(try await f.currentThread().queuedTurns.count == 2)
        peer.acknowledgeStart()
        try await waitSetup { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
        peer.complete(.exited(7))
        try await waitSetup { try await f.currentSetup().phase == .failed }
        let failed = try await f.currentSetup(), thread = try await f.currentThread()
        #expect(failed.commandExit == .exited(7) && failed.error == ThreadProjectScriptRun.executionError)
        #expect(await f.engine.current().snapshot.providerReady(for: thread))
        #expect(thread.queuedTurns.map(\.text) == ["second queued turn"])
        let provider = try #require(f.harness.providerSessions(f.thread.id).first)
        await provider.finish(); try await waitSetup { await provider.turns.count == 2 }
        #expect(await provider.turns.map(\.text) == ["first queued turn", "second queued turn"])
        await provider.finish()
    }
}

@Test(.timeLimit(.minutes(1)))
func setupBlockingRequiresExitZeroAndSkipWaitsForOwnedSessionClose() async throws {
    let script = try ProjectScript(name: "Blocking setup", command: "printf blocking", runOnWorktreeCreate: true, runsAsynchronously: false)
    try await withSetupEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let run = try await f.awaitingApproval()
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Keep queued through failed setup"))
        let peer = try await f.approve(run); peer.acknowledgeStart()
        try await waitSetup { try await f.currentSetup().phase == .running }
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        peer.holdClosure(); peer.complete(.exited(7))
        try await waitSetup { try await f.currentSetup().phase == .failed }
        let blocked = try await f.currentThread()
        #expect(f.harness.providerSessions(f.thread.id).isEmpty && blocked.queuedTurns.count == 1)
        try await f.engine.skipProjectScript(threadID: f.thread.id, runID: run.id)
        try await waitSetup { peer.closes > 0 }
        #expect(try await f.currentSetup().phase == .stopping)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty && !peer.isClosed)
        peer.releaseClosure()
        try await waitSetup { try await f.currentSetup().phase == .skipped }
        try await waitSetup { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
        #expect(peer.isClosed)
        await f.harness.providerSessions(f.thread.id).first?.finish()
    }
}

@Test(.timeLimit(.minutes(1)))
func setupStopKeepsBlockingQueueHeldUntilDrainAndRequiresAnExplicitSkipToContinue() async throws {
    let script = try ProjectScript(name: "Cancelled setup", command: "printf cancel", runOnWorktreeCreate: true, runsAsynchronously: false)
    try await withSetupEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let run = try await f.awaitingApproval()
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Held until user continues"))
        let peer = try await f.approve(run); peer.acknowledgeStart(); peer.holdClosure()
        try await waitSetup { try await f.currentSetup().phase == .running }
        try await f.engine.stopProjectScript(threadID: f.thread.id, runID: run.id)
        try await waitSetup { peer.closes > 0 }
        #expect(try await f.currentSetup().phase == .stopping)
        #expect(!peer.isClosed && f.harness.providerSessions(f.thread.id).isEmpty)
        peer.releaseClosure()
        try await waitSetup { try await f.currentSetup().phase == .cancelled }
        #expect(try await f.currentThread().queuePaused)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        try await f.engine.dispatch(.resumeQueue(threadID: f.thread.id))
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        try await f.engine.skipProjectScript(threadID: f.thread.id, runID: run.id)
        try await waitSetup { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
        await f.harness.providerSessions(f.thread.id).first?.finish()
    }
}

@Test(.timeLimit(.minutes(1)))
func setupRetryDrainsOldOwnerThenNeedsFreshReviewBeforeStartingAgain() async throws {
    let script = try ProjectScript(name: "Retry setup", command: "printf retry", runOnWorktreeCreate: true, runsAsynchronously: false)
    try await withSetupEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let old = try await f.awaitingApproval()
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Never duplicate this turn"))
        let peer = try await f.approve(old); peer.acknowledgeStart(); peer.holdClosure(); peer.complete(.exited(7))
        try await waitSetup { try await f.currentSetup().phase == .failed }
        try await f.engine.retryProjectScript(threadID: f.thread.id, runID: old.id)
        try await waitSetup { peer.closes > 0 }
        let stopping = try await f.currentSetup()
        #expect(stopping.id == old.id && stopping.phase == .stopping)
        #expect(f.harness.scriptSessions().count == 1 && f.harness.providerSessions(f.thread.id).isEmpty)
        peer.releaseClosure()
        let fresh = try await f.awaitingApproval()
        let oldPlan = try #require(old.plan)
        #expect(fresh.id != old.id && fresh.previousPlans == [oldPlan])
        #expect(f.harness.scriptSessions().count == 1 && peer.starts == 1)
        let next = try await f.approve(fresh); next.acknowledgeStart(); next.complete(.exited(0))
        try await waitSetup { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
        #expect(try await f.currentSetup().commandExit == .exited(0))
        await f.harness.providerSessions(f.thread.id).first?.finish()
    }
}

@Test(.timeLimit(.minutes(1)))
func setupSuccessfulCommandRetainsReadinessAndExitEvidenceWhileBackgroundOwnerStops() async throws {
    let script = try ProjectScript(name: "Successful setup", command: "printf success", runOnWorktreeCreate: true, runsAsynchronously: false)
    try await withSetupEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let run = try await f.awaitingApproval()
        let peer = try await f.approve(run); peer.acknowledgeStart(); peer.complete(.exited(0))
        try await waitSetup { try await f.currentSetup().phase == .succeeded }
        #expect(!peer.isClosed)
        peer.holdClosure()
        try await f.engine.stopProjectScript(threadID: f.thread.id, runID: run.id)
        try await waitSetup { peer.closes > 0 }
        let stopping = try await f.currentThread()
        #expect(stopping.workspacePreparation?.setup?.commandExit == .exited(0))
        #expect(await f.engine.current().snapshot.providerReady(for: stopping))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Setup already succeeded"))
        #expect(f.harness.providerSessions(f.thread.id).isEmpty, "The automatic baseline waits for the already-stopping background owner to drain.")
        peer.releaseClosure()
        try await waitSetup { peer.isClosed }
        try await waitSetup { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
        let closed = try await f.currentThread()
        #expect(closed.workspacePreparation?.setup?.commandExit == .exited(0))
        #expect(await f.engine.current().snapshot.providerReady(for: closed))
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.load().threads.first?.workspacePreparation?.setup?.commandExit == .exited(0))
        await f.harness.providerSessions(f.thread.id).first?.finish()
    }
}

private final class SetupPRCheckoutObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var destination: String?
    private var policies: [GitHubPullRequestCheckoutPolicy] = []
    func select(_ path: String) { lock.withLock { destination = path } }
    var preparedPolicies: [GitHubPullRequestCheckoutPolicy] { lock.withLock { policies } }
    func plan(_ request: GitHubPullRequestCheckoutRequest) throws -> GitHubPullRequestCheckoutPlan {
        let target = try lock.withLock { () throws -> String in
            policies.append(request.policy)
            guard let destination else { throw CoincideError("The owned setup checkout was not selected.") }; return destination
        }
        let seed = PullRequestCheckoutFixture(path: request.sourcePath), base = try seed.plan(request, reuse: true)
        return try .init(request: request, sourcePath: base.sourcePath, repositoryPath: base.repositoryPath,
            commonDirectoryPath: base.commonDirectoryPath, destinationPath: target, pullRequest: base.pullRequest,
            requestedBranch: base.requestedBranch, requestedHeadCommit: base.requestedHeadCommit,
            disposition: .reuseWorktree, proof: base.proof, baseRemote: base.baseRemote,
            headRemote: base.headRemote, existingBranchCommit: base.existingBranchCommit, destinationParentIdentity: base.destinationParentIdentity)
    }
}

private struct SetupPRCheckoutSession: GitHubPullRequestCheckoutSession {
    let request: GitHubPullRequestCheckoutRequest
    let peer: SetupPRCheckoutObservation
    func prepare() async throws -> GitHubPullRequestCheckoutPlan { try peer.plan(request) }
    func run(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutResult { throw CoincideError("Review must not start a checkout.") }
    func inspectCompletion(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutInspection { .unconfirmed }
}

@Test(.timeLimit(.minutes(1)))
func pullRequestCheckoutRetainedSuccessfulSetupHelperAutomaticallyUsesReadOnlyReuseWithoutClosingItsOwner() async throws {
    let script = try ProjectScript(name: "Retained target helper", command: "printf fixture", runOnWorktreeCreate: true, runsAsynchronously: false)
    let checkout = SetupPRCheckoutObservation()
    try await withSetupEngine(scripts: [script], checkoutFactory: { SetupPRCheckoutSession(request: $0, peer: checkout) }) { f in
        try await f.completeCheckout(); let run = try await f.awaitingApproval()
        let peer = try await f.approve(run); peer.acknowledgeStart(); peer.complete(.exited(0))
        try await waitSetup { try await f.currentSetup().phase == .succeeded }
        let before = try await f.currentThread()
        #expect(!peer.isClosed && peer.closes == 0)
        checkout.select(before.workspacePath)
        let seed = PullRequestCheckoutFixture(path: f.project.path)
        let review = try await f.engine.reviewPullRequestCheckout(projectID: f.project.id, workspacePath: f.project.path,
            reference: seed.request().reference, mode: .worktree, configuration: .init(thread: before), checkpointPolicy: .disabled)
        #expect(review.plan.isReadOnly && review.plan.request.policy == .inspectOnly)
        #expect(checkout.preparedPolicies == [.refresh, .inspectOnly])
        #expect(review.plan.affectedWorkspacePaths.isEmpty && !peer.isClosed && peer.closes == 0 && peer.starts == 1)
        #expect(try await f.currentThread() == before)
        await f.engine.discardPullRequestCheckoutReview(reviewID: review.id)
    }
}

@Test(.timeLimit(.minutes(1)))
func setupApprovalCommitRollbackNeverConstructsOrStartsAnExecutionSession() async throws {
    let script = try ProjectScript(name: "Atomic approval", command: "printf atomic", runOnWorktreeCreate: true)
    try await withSetupEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let run = try await f.awaitingApproval(), plan = try #require(run.plan)
        let database = try WorkspaceDatabase(url: f.databaseURL), before = try await database.revision()
        var connection: OpaquePointer?
        #expect(sqlite3_open(f.databaseURL.path, &connection) == SQLITE_OK)
        let handle = try #require(connection); defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "CREATE TRIGGER reject_setup_approval BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'fixture rollback'); END", nil, nil, nil) == SQLITE_OK)
        do {
            try await f.engine.approveProjectScript(threadID: f.thread.id, runID: run.id, expectedPlan: plan)
            Issue.record("An approval with a rejected durable transaction succeeded.")
        } catch { }
        #expect(try await database.revision() == before)
        #expect(f.harness.scriptSessions().isEmpty && f.harness.providerSessions(f.thread.id).isEmpty)
        #expect(sqlite3_exec(handle, "DROP TRIGGER reject_setup_approval", nil, nil, nil) == SQLITE_OK)
    }
}

@Test(.timeLimit(.minutes(1)))
func setupLostStartedAcknowledgementRestartsInterruptedWithoutReplayingScriptOrQueue() async throws {
    let script = try ProjectScript(name: "Lost acknowledgement", command: "printf may-have-run", runOnWorktreeCreate: true)
    try await withSetupEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let run = try await f.awaitingApproval()
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Keep this queued after restart"))
        let peer = try await f.approve(run)
        #expect(peer.starts == 1 && f.harness.providerSessions(f.thread.id).isEmpty)
        let unacknowledged = await f.engine.current().snapshot
        #expect(unacknowledged.threads.first?.workspacePreparation?.setup?.phase == .starting)
        await f.engine.shutdown()
        let database = try WorkspaceDatabase(url: f.databaseURL)
        // Restore both durable intent and a running outbox lease before acknowledgement.
        let preparation = try #require(unacknowledged.threads.first?.workspacePreparation), plan = try #require(run.plan)
        let abandoned = PendingWorkspaceEffect(request: .startProjectScript(threadID: f.thread.id, attemptID: preparation.id, plan: plan))
        _ = try await database.commit(unacknowledged, event: "fixture.lost-start-ack", commandID: UUID(), effects: [abandoned])
        let claimed = try #require(try await database.claimNextEffect(workerID: UUID()))
        #expect(claimed.id == abandoned.id && claimed.status == .running)
        let reopened = try f.harness.engine(f.databaseURL)
        do {
            let loaded = try await reopened.load(), thread = try #require(loaded.threads.first)
            #expect(thread.workspacePreparation?.setup?.id == run.id)
            #expect(thread.workspacePreparation?.setup?.phase == .interrupted && thread.queuePaused)
            #expect(thread.workspacePreparation?.setup?.error == ThreadProjectScriptRun.interruptedError)
            #expect(thread.queuedTurns.map(\.text) == ["Keep this queued after restart"])
            try await reopened.dispatch(.resumeQueue(threadID: f.thread.id))
            #expect(f.harness.scriptSessions().count == 1 && peer.starts == 1)
            #expect(f.harness.providerSessions(f.thread.id).isEmpty)
            #expect(try await database.effects().first { $0.id == abandoned.id }?.status == .cancelled)
            #expect(try await database.rebuildProjection().snapshot == (await reopened.current().snapshot))
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    }
}

@Test(.timeLimit(.minutes(1)))
func setupRemovalWaitsForAlreadyStoppingSessionWithoutResurrectingReaddedOwnerIDs() async throws {
    let script = try ProjectScript(name: "Removed owner", command: "printf owned", runOnWorktreeCreate: true, runsAsynchronously: false)
    try await withSetupEngine(scripts: [script], ignoresScriptWaitCancellation: true) { f in
        try await f.completeCheckout(); let run = try await f.awaitingApproval()
        let peer = try await f.approve(run); peer.holdClosure()
        try await f.engine.stopProjectScript(threadID: f.thread.id, runID: run.id)
        try await waitSetup { peer.closes > 0 }
        try await f.engine.dispatch(.removeProject(projectID: f.project.id, expectedThreadIDs: [f.thread.id]))
        let removed = SetupCompletionFlag()
        let cleanup = Task { await f.engine.awaitProjectRemovalCleanup(projectID: f.project.id); await removed.finish() }
        try await f.engine.dispatch(.addProjectWithThread(project: f.project, thread: f.thread))
        let unrelated = WorkspaceProject(path: f.root.appendingPathComponent("unrelated").path), otherThread = CodingThread(project: unrelated)
        try await f.engine.dispatch(.addProjectWithThread(project: unrelated, thread: otherThread))
        try await f.engine.dispatch(.submit(threadID: otherThread.id, text: "Other project remains responsive"))
        try await waitSetup { await f.harness.providerSessions(otherThread.id).first?.turns.count == 1 }
        #expect(await removed.value == false)
        peer.acknowledgeStart(); peer.complete(.exited(0)); peer.releaseClosure()
        await cleanup.value
        #expect(await removed.value)
        let replacement = try await f.currentThread()
        #expect(replacement.workspacePreparation == nil && replacement.workspacePath == f.project.path)
        #expect(replacement.messages.isEmpty && replacement.queuedTurns.isEmpty)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty && peer.starts == 1 && peer.isClosed)
        #expect(await f.engine.current().error == nil)
        await f.harness.providerSessions(otherThread.id).first?.finish()
    }
}

@Test(.timeLimit(.minutes(1)))
func setupArchiveUnarchiveRetryUsesExistingDrainToCompleteItsCurrentPendingAction() async throws {
    let script = try ProjectScript(name: "Archive during setup", command: "printf archive", runOnWorktreeCreate: true, runsAsynchronously: false)
    try await withSetupEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let old = try await f.awaitingApproval()
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Preserve this turn through archive and retry"))
        let peer = try await f.approve(old); peer.acknowledgeStart(); peer.holdClosure()
        try await waitSetup { try await f.currentSetup().phase == .running }
        try await f.engine.dispatch(.editThread(f.thread.id, .archived(true)))
        try await waitSetup { peer.closes > 0 }
        #expect(try await f.currentSetup().phase == .cancelled)
        try await f.engine.dispatch(.editThread(f.thread.id, .archived(false)))
        try await f.engine.retryProjectScript(threadID: f.thread.id, runID: old.id)
        let stopping = try await f.currentSetup()
        #expect(stopping.id == old.id && stopping.phase == .stopping && stopping.pendingAction == .retry)
        #expect(!peer.isClosed && peer.starts == 1 && f.harness.scriptSessions().count == 1)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        peer.releaseClosure()
        let fresh = try await f.awaitingApproval(), oldPlan = try #require(old.plan)
        #expect(fresh.id != old.id && fresh.previousPlans == [oldPlan] && peer.isClosed)
        #expect(f.harness.scriptSessions().count == 1)
        let next = try await f.approve(fresh); next.acknowledgeStart(); next.complete(.exited(0))
        try await waitSetup { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
        let provider = try #require(f.harness.providerSessions(f.thread.id).first)
        #expect(await provider.turns.map(\.text) == ["Preserve this turn through archive and retry"])
        await provider.finish()
    }
}

@Test(.timeLimit(.minutes(1)))
func setupFactoryFailureClosesAnExistingReviewOutputStreamWithoutConstructingACommand() async throws {
    let script = try ProjectScript(name: "Unavailable helper", command: "printf must-not-start", runOnWorktreeCreate: true)
    try await withSetupEngine(scripts: [script], throwsScriptFactory: true) { f in
        try await f.completeCheckout(); let run = try await f.awaitingApproval(), plan = try #require(run.plan)
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Keep the provider queued"))
        let observer = SetupOutputObserver(), stream = try await f.engine.projectScriptOutput(threadID: f.thread.id, runID: run.id)
        let reader = Task { for await value in stream { await observer.receive(value) } }
        do {
            try await waitSetup { await observer.latest != nil }
            #expect(await observer.latest?.isClosed == false)
            try await f.engine.approveProjectScript(threadID: f.thread.id, runID: run.id, expectedPlan: plan)
            try await waitSetup { try await f.currentSetup().phase == .failed }
            try await waitSetup { await observer.latest?.isClosed == true }
            #expect(try await f.currentSetup().error == ThreadProjectScriptRun.executionError)
            #expect(f.harness.scriptSessions().isEmpty && f.harness.providerSessions(f.thread.id).isEmpty)
            #expect(try await f.currentThread().queuedTurns.map(\.text) == ["Keep the provider queued"])
            await reader.value
        } catch { reader.cancel(); await reader.value; throw error }
    }
}

@Test(.timeLimit(.minutes(1)))
func setupDiscoveryWithoutAnExecutionOwnerClosesExistingOutputForSkippedAndFailedPlans() async throws {
    for fails in [false, true] {
        let entered = SetupCompletionFlag(), release = SetupTestSignal<Void>()
        let script = try ProjectScript(name: "Discovery fixture", command: "printf must-not-start", runOnWorktreeCreate: true)
        let planner: WorkspaceEngine.ProjectScriptPlanner = { _ in
            await entered.finish(); try await release.wait()
            if fails { throw CoincideError("Isolated planner fixture failure") }
            return nil
        }
        try await withSetupEngine(scripts: [script], planner: planner) { f in
            try await f.completeCheckout()
            try await waitSetup { await entered.value }
            let run = try await f.currentSetup()
            #expect(run.phase == .discovering)
            let observer = SetupOutputObserver(), stream = try await f.engine.projectScriptOutput(threadID: f.thread.id, runID: run.id)
            let reader = Task { for await value in stream { await observer.receive(value) } }
            do {
                try await waitSetup { await observer.latest != nil }
                #expect(await observer.latest?.isClosed == false)
                release.finish(.success(()))
                let expected: ThreadProjectScriptRunPhase = fails ? .failed : .skipped
                try await waitSetup { try await f.currentSetup().phase == expected }
                try await waitSetup { await observer.latest?.isClosed == true }
                #expect(f.harness.scriptSessions().isEmpty && f.harness.providerSessions(f.thread.id).isEmpty)
                #expect(try await f.currentSetup().plan == nil)
                if fails { #expect(try await f.currentSetup().error == ThreadProjectScriptRun.discoveryError) }
                await reader.value
            } catch { release.finish(.failure(CancellationError())); reader.cancel(); await reader.value; throw error }
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func setupOutputHasOneTransportConsumerAndBoundedUnicodeSnapshotsForEveryWindowWithoutPersistence() async throws {
    let script = try ProjectScript(name: "Visible setup", command: "printf visible", runOnWorktreeCreate: true, runsAsynchronously: false)
    try await withSetupEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let run = try await f.awaitingApproval()
        let peer = try await f.approve(run); peer.acknowledgeStart()
        try await waitSetup { try await f.currentSetup().phase == .running }
        let first = SetupOutputObserver(), second = SetupOutputObserver()
        let firstStream = try await f.engine.projectScriptOutput(threadID: f.thread.id, runID: run.id)
        let secondStream = try await f.engine.projectScriptOutput(threadID: f.thread.id, runID: run.id)
        let one = Task { for await value in firstStream { await first.receive(value) } }
        let two = Task { for await value in secondStream { await second.receive(value) } }
        var shutdown: Task<Void, Never>?
        do {
            let prefix = Data("visible-😀é𝒜".utf8)
            peer.emit(Data(prefix.prefix(9))); peer.emit(Data(prefix.dropFirst(9)), sequence: 1)
            try await waitSetup { await first.latest?.text.contains("visible-😀é𝒜") == true }
            let initial = try #require(await first.latest)
            #expect(!initial.text.contains("�"))
            let before = await f.engine.current().sequence
            let privateMarker = "private-buffer-" + UUID().uuidString, marker = privateMarker + "-終😀"
            let line = String(repeating: "界😀é", count: 40) + "\n"
            let bytes = Data(("\n" + String(repeating: "A", count: 600) + "\n" + String(repeating: line, count: 1_200) + marker).utf8)
            for index in stride(from: 0, to: bytes.count, by: 16_384) {
                peer.emit(Data(bytes.dropFirst(index).prefix(16_384)), sequence: UInt64(2 + index / 16_384))
            }
            try await waitSetup {
                let a = await first.latest, b = await second.latest
                return a?.text.hasSuffix(marker) == true && b?.text.hasSuffix(marker) == true
            }
            let a = try #require(await first.latest), b = try #require(await second.latest)
            #expect(a.runID == run.id && a.text == b.text && a.truncated && b.truncated)
            #expect(a.text.utf8.count <= 65_536 && a.text.split(separator: "\n", omittingEmptySubsequences: false).count <= 500)
            #expect(a.text.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy { $0.unicodeScalars.count <= 400 })
            #expect(!a.text.contains("�") && peer.consumers == 1)
            let firstOrdered = await first.ordered, secondOrdered = await second.ordered
            #expect(firstOrdered && secondOrdered)
            #expect(await f.engine.current().sequence == before)
            let snapshot = await f.engine.current().snapshot, database = try WorkspaceDatabase(url: f.databaseURL)
            let rebuilt = try await database.rebuildProjection().snapshot
            #expect(!String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains(privateMarker))
            #expect(!String(decoding: try JSONEncoder().encode(rebuilt), as: UTF8.self).contains(privateMarker))
            peer.holdClosure()
            try await f.engine.stopProjectScript(threadID: f.thread.id, runID: run.id)
            try await waitSetup { peer.closes > 0 && peer.consumersEnded == 1 }
            let draining = try await f.engine.projectScriptOutput(threadID: f.thread.id, runID: run.id)
            var iterator = draining.makeAsyncIterator()
            let drainingSnapshot = await iterator.next(), duringDrain = try #require(drainingSnapshot)
            #expect(!duringDrain.isClosed && !peer.isClosed)
            #expect(await first.latest?.isClosed == false)
            #expect(await second.latest?.isClosed == false)
            let shutdownFinished = SetupCompletionFlag()
            shutdown = Task { await f.engine.shutdown(); await shutdownFinished.finish() }
            try await waitSetup {
                do { _ = try await f.engine.load(); return false }
                catch { return true }
            }
            // Let the 30 ms coalesced presentation update run while owned close is held.
            try await Task.sleep(for: .milliseconds(60))
            #expect(await shutdownFinished.value == false)
            #expect(await first.latest?.isClosed == false)
            #expect(await second.latest?.isClosed == false)
            peer.releaseClosure()
            await shutdown?.value
            await one.value; await two.value
            #expect(await first.latest?.isClosed == true)
            #expect(await second.latest?.isClosed == true)
        } catch {
            peer.releaseClosure(); await shutdown?.value
            one.cancel(); two.cancel(); await one.value; await two.value; throw error
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func appOwnedSetupActionOverridesT3JSONAndStillRequiresExactReview() async throws {
    let scripts: [ProjectScript] = [try .init(name: "File setup", command: "printf file", runOnWorktreeCreate: true)]
    try await withSetupEngine(scripts: scripts) { f in
        let key = ProjectSettingsKey.primary(for: f.project), root = ProjectSettingsFiles.root(dataRoot: f.root)
        let actions = try ProjectActions.adding(.init(name: "App setup", command: "printf app", runOnWorktreeCreate: true, waitForSetup: true), to: [])
        try ProjectSettingsFiles.save(.init(key: key, actions: actions), root: root)
        try await f.completeCheckout()
        let run = try await f.awaitingApproval(), plan = try #require(run.plan)
        #expect(plan.script.name == "App setup" && plan.script.command == "printf app" && !plan.script.runsAsynchronously)
        #expect(plan.configurationRevision == nil && plan.projectAction?.actionID == actions[0].id && plan.projectAction?.settingsKey == key)
        #expect(f.harness.scriptSessions().isEmpty, "Discovery of an app-owned role never starts a script.")
        let reopened = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await reopened.load().threads.first?.workspacePreparation?.setup?.plan == plan, "The journal round-trips the action pin.")
        let peer = try await f.approve(run)
        #expect(peer.plan == plan && peer.starts == 1)
    }
}
