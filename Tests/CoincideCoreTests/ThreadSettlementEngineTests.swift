import Foundation
import Testing
import CSQLite
@testable import CoincideCore

private final class SettlementTestSignal<Value: Sendable>: @unchecked Sendable {
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

private actor SettlementOutputObserver {
    private(set) var latest: ProjectScriptOutputSnapshot?
    private(set) var ordered = true
    func receive(_ value: ProjectScriptOutputSnapshot) {
        if let latest, value.sequence <= latest.sequence { ordered = false }
        latest = value
    }
}

private actor SettlementCompletionFlag {
    private(set) var value = false
    func finish() { value = true }
}

/// The synchronous handoff and actual STARTED acknowledgement have independent gates.
private final class SettlementExecutionPeer: ProjectScriptExecutionSession, @unchecked Sendable {
    let plan: ProjectScriptExecutionPlan
    private let lock = NSLock()
    private let started = SettlementTestSignal<Void>(), exit = SettlementTestSignal<ProjectScriptCommandExit>()
    private let closeGate = SettlementTestSignal<Void>()
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

private actor SettlementCheckoutPeer: WorkspaceWorktreeSession {
    let request: GitWorktreeRequest
    let configuration: ProjectConfiguration
    let reuseIsMain: Bool
    private let release = SettlementTestSignal<Void>()
    private(set) var runs = 0
    init(_ request: GitWorktreeRequest, configuration: ProjectConfiguration, reuseIsMain: Bool = false) {
        self.request = request; self.configuration = configuration; self.reuseIsMain = reuseIsMain
    }
    func prepare() throws -> GitWorktreePlan {
        let identity = GitWorktreeNodeIdentity(device: 1, inode: 42)
        let branch: String, reuse: Bool
        switch request.selection {
        case .createBranch(let value, _), .existingBranch(let value): branch = value; reuse = false
        case .reuse: branch = "fixture"; reuse = true
        }
        let common = request.sourcePath + "/.git", admin = reuseIsMain ? common : common + "/worktrees/reused"
        let adminIdentity = reuseIsMain ? identity : GitWorktreeNodeIdentity(device: 1, inode: 43)
        return try .init(request: request, sourcePath: request.sourcePath,
            commonDirectoryPath: common, sourceIdentity: identity,
            commonDirectoryIdentity: identity, destinationParentIdentity: identity,
            branch: branch, baseCommit: String(repeating: "a", count: 40), destinationIdentity: reuse ? identity : nil,
            worktreeGitDirectoryPath: reuse ? admin : nil, worktreeGitDirectoryIdentity: reuse ? adminIdentity : nil,
            sourceGitDirectoryPath: reuse ? admin : nil, sourceGitDirectoryIdentity: reuse ? adminIdentity : nil)
    }
    func run(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult {
        runs += 1
        try await release.wait(); try Task.checkCancellation()
        if case .reuse = request.selection { }
        else {
            let destination = URL(fileURLWithPath: request.destinationPath)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try JSONEncoder().encode(configuration).write(to: destination.appendingPathComponent("t3.json"))
        }
        return .init(destinationPath: plan.destinationPath, headCommit: plan.baseCommit, branch: plan.branch)
    }
    func inspectCompletion(_ plan: GitWorktreePlan) -> GitWorktreeResult? { nil }
    func complete() { release.finish(.success(())) }
    func cancel() { release.finish(.failure(CancellationError())) }
}

private struct SettlementCapturedTurn: Sendable {
    let input: ProviderInput
    let configuration: ProviderConfiguration
}
private actor SettlementProviderPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private let closeGate = SettlementTestSignal<Void>()
    private var holdClose = false
    private(set) var closes = 0
    private(set) var isClosed = false
    private(set) var turns: [SettlementCapturedTurn] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [.init(id: "settlement-fixture", name: "Setup fixture")] }
    func send(text: String, thread: CodingThread) { send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) { runID = thread.activeRun?.id; turns.append(.init(input: input, configuration: .init(thread: thread))) }
    func finish() { if let runID { sink.yield(.context(runID: runID, event: .completed(.idle))) } }
    func interrupt() { if let runID { sink.yield(.context(runID: runID, event: .completed(.interrupted))) } }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func ask(_ request: ApprovalRequest) { sink.yield(.sessionApproval(request)) }
    func holdClosure() { holdClose = true }
    func releaseClosure() { closeGate.finish(.success(())) }
    func close() async {
        closes += 1
        if holdClose { _ = try? await closeGate.waitIgnoringCancellation() }
        isClosed = true; sink.finish()
    }
}

private final class SettlementEngineHarness: @unchecked Sendable {
    let configuration: ProjectConfiguration
    let ignoresScriptWaitCancellation: Bool
    let throwsScriptFactory: Bool
    let reuseIsMain: Bool
    private let lock = NSLock()
    private var checkouts: [UUID: SettlementCheckoutPeer] = [:]
    private var scripts: [UUID: SettlementExecutionPeer] = [:]
    private var providers: [UUID: [SettlementProviderPeer]] = [:]
    init(configuration: ProjectConfiguration, ignoresScriptWaitCancellation: Bool = false, throwsScriptFactory: Bool = false, reuseIsMain: Bool = false) {
        self.configuration = configuration; self.ignoresScriptWaitCancellation = ignoresScriptWaitCancellation
        self.throwsScriptFactory = throwsScriptFactory; self.reuseIsMain = reuseIsMain
    }
    func checkout(_ request: GitWorktreeRequest) -> SettlementCheckoutPeer {
        lock.withLock {
            if let value = checkouts[request.id] { return value }
            let value = SettlementCheckoutPeer(request, configuration: configuration, reuseIsMain: reuseIsMain); checkouts[request.id] = value; return value
        }
    }
    func script(_ plan: ProjectScriptExecutionPlan) -> SettlementExecutionPeer {
        lock.withLock {
            if let value = scripts[plan.id] { return value }
            let value = SettlementExecutionPeer(plan, ignoresWaitCancellation: ignoresScriptWaitCancellation); scripts[plan.id] = value; return value
        }
    }
    func provider(_ thread: CodingThread) -> SettlementProviderPeer {
        lock.withLock {
            let value = SettlementProviderPeer(); providers[thread.id, default: []].append(value); return value
        }
    }
    func providerSessions(_ threadID: UUID) -> [SettlementProviderPeer] { lock.withLock { providers[threadID] ?? [] } }
    func scriptSessions() -> [SettlementExecutionPeer] { lock.withLock { Array(scripts.values) } }
    func engine(_ database: URL, planner: WorkspaceEngine.ProjectScriptPlanner? = nil) throws -> WorkspaceEngine {
        let factory: WorkspaceEngine.ProjectScriptFactory = {
            if self.throwsScriptFactory { throw ProjectScriptExecutionError(.helperUnavailable) }
            return self.script($0)
        }
        if let planner {
            return try WorkspaceEngine(url: database, providerFactory: { self.provider($0) }, identityResolver: { _ in nil },
                worktreeFactory: { self.checkout($0) }, projectScriptPlanner: planner, projectScriptFactory: factory)
        }
        return try WorkspaceEngine(url: database, providerFactory: { self.provider($0) }, identityResolver: { _ in nil },
            worktreeFactory: { self.checkout($0) }, projectScriptFactory: factory)
    }
    func releaseAll() async {
        let values = lock.withLock { (Array(checkouts.values), Array(scripts.values), providers.values.flatMap { $0 }) }
        for checkout in values.0 { await checkout.cancel() }
        for script in values.1 { script.releaseAll() }
        for provider in values.2 { await provider.releaseClosure() }
    }
}

private struct SettlementEngineFixture {
    let root: URL, engine: WorkspaceEngine, harness: SettlementEngineHarness
    let project: WorkspaceProject, thread: CodingThread
    var databaseURL: URL { root.appendingPathComponent("workspace.sqlite") }
    func currentThread() async throws -> CodingThread { try #require(await engine.current().snapshot.threads.first { $0.id == thread.id }) }
    func currentSettlement() async throws -> ThreadSettlement { try #require(try await currentThread().settlement) }
    func currentScript() async throws -> ThreadProjectScriptRun { try #require(try await currentSettlement().script) }
    func awaitingApproval() async throws -> ThreadProjectScriptRun {
        try await waitSettlement { try await currentScript().phase == .awaitingApproval }
        return try await currentScript()
    }
    func approve(_ run: ThreadProjectScriptRun) async throws -> SettlementExecutionPeer {
        let plan = try #require(run.plan)
        try await engine.approveProjectScript(threadID: thread.id, runID: run.id, expectedPlan: plan)
        try await waitSettlement { harness.scriptSessions().first { $0.plan.id == run.id }?.starts == 1 }
        return harness.script(plan)
    }
    func completeCheckout(review: Bool = false) async throws {
        try await engine.beginWorktreePreparation(threadID: thread.id,
            selection: .createBranch(name: "settlement-fixture", baseRef: "HEAD"), reviewSetup: review)
        let request = try #require(try await currentThread().workspacePreparation?.request)
        let peer = harness.checkout(request)
        try await waitSettlement { await peer.runs == 1 }
        await peer.complete()
        try await waitSettlement { try await currentThread().workspacePreparation?.isReady == true }
    }
    func settle(review: Bool = true) async throws -> ThreadSettlement {
        let current = try await currentThread()
        try await engine.settleThread(threadID: thread.id, expectedWorkspacePath: current.workspacePath, reviewScript: review)
        return try await currentSettlement()
    }
}

private func withSettlementEngine(scripts: [ProjectScript], ignoresScriptWaitCancellation: Bool = false, throwsScriptFactory: Bool = false, reuseIsMain: Bool = false,
                             planner: WorkspaceEngine.ProjectScriptPlanner? = nil,
                             _ body: (SettlementEngineFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace().resolvingSymlinksInPath(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source 工作"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let configuration = try ProjectConfiguration(scripts: scripts)
    let harness = SettlementEngineHarness(configuration: configuration, ignoresScriptWaitCancellation: ignoresScriptWaitCancellation,
                                     throwsScriptFactory: throwsScriptFactory, reuseIsMain: reuseIsMain)
    try JSONEncoder().encode(configuration).write(to: source.appendingPathComponent("t3.json"))
    let engine = try harness.engine(root.appendingPathComponent("workspace.sqlite"), planner: planner), project = WorkspaceProject(path: source.path)
    let thread = CodingThread(project: project)
    do {
        try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        try await body(.init(root: root, engine: engine, harness: harness, project: project, thread: thread))
        await harness.releaseAll(); await engine.shutdown()
    } catch { await harness.releaseAll(); await engine.shutdown(); throw error }
}

private func waitSettlement(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The settlement engine fixture did not reach its controlled state.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementRequiresExplicitGenerationAndIdleProviderCompletionNeverRunsCleanup() async throws {
    let script = try ProjectScript(name: "Explicit cleanup", command: "printf cleanup", runOnSettle: true)
    try await withSettlementEngine(scripts: [script]) { f in
        try await f.completeCheckout()
        let initial = try await f.settle(review: false), preparationID = try await f.currentThread().workspacePreparation?.id
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.beginWorktreePreparation(threadID: f.thread.id,
                selection: .createBranch(name: "must-resume-before-changing-worktree", baseRef: "HEAD"))
        }
        #expect(try await f.currentSettlement().id == initial.id)
        #expect(try await f.currentThread().workspacePreparation?.id == preparationID)
        try await f.engine.resumeThread(threadID: f.thread.id, generationID: initial.id)
        try await waitSettlement { try await f.currentThread().settlement == nil }
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Normal provider turn"))
        try await waitSettlement { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
        let provider = try #require(f.harness.providerSessions(f.thread.id).first)
        await provider.finish(); try await waitSettlement {
            let thread = try await f.currentThread()
            return thread.state == .idle && thread.heldPostRunCheckpoint == nil
        }
        #expect(try await f.currentThread().settlement == nil)
        #expect(f.harness.scriptSessions().isEmpty)
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.settleThread(threadID: f.thread.id, expectedWorkspacePath: f.project.path, reviewScript: true)
        }
        #expect(try await f.currentThread().settlement == nil)
        let first = try await f.settle(review: false)
        #expect(first.phase == .settled && first.script == nil && first.id != initial.id)
        let again = try await f.settle(review: true)
        #expect(again == first)
        let settled = try await f.currentThread()
        #expect(!(await f.engine.current().snapshot.providerReady(for: settled)))
        var legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settled)) as? [String: Any])
        legacyObject.removeValue(forKey: "settlement")
        let legacy = try JSONDecoder().decode(CodingThread.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        #expect(legacy.settlement == nil)
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.resumeThread(threadID: f.thread.id, generationID: UUID()) }
        #expect(try await f.currentSettlement() == first)
        try await f.engine.resumeThread(threadID: f.thread.id, generationID: first.id)
        try await waitSettlement { try await f.currentThread().settlement == nil }
        let resumed = try await f.currentThread()
        #expect(await f.engine.current().snapshot.providerReady(for: resumed))
        #expect(f.harness.scriptSessions().isEmpty)
    }
}

@Test
func settlementRejectsBusyQueuedAndUnansweredRuntimeRequests() throws {
    let project = WorkspaceProject(path: "/fixture/settlement-blockers"), original = CodingThread(project: project)
    var busy = original; busy.state = .running
    busy.activeRun = .init(id: UUID(), configuration: .init(thread: original), startedAt: Date())
    var queued = original
    queued.queuedTurns = [.init(id: UUID(), text: "Do not lose this turn", configuration: .init(thread: queued), createdAt: Date())]
    var question = original
    question.runtimeRequests = [.init(request: .init(id: .string("unanswered"), method: "fixture/question", params: .object([:])), sessionScoped: true)]
    for thread in [busy, queued, question] {
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        #expect(!snapshot.canSettle(threadID: thread.id))
        #expect(throws: WorkspaceCommandError.self) {
            try WorkspaceDecision.make(.client(.settleThread(threadID: thread.id, expectedWorkspacePath: thread.workspacePath, reviewScript: false)),
                id: UUID(), snapshot: snapshot, now: Date())
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementRejectsUnfinishedCheckoutAndSetupBeforeCreatingAnyGeneration() async throws {
    let script = try ProjectScript(name: "Unapproved setup", command: "printf setup", runOnWorktreeCreate: true, runOnSettle: true)
    try await withSettlementEngine(scripts: [script]) { f in
        try await f.engine.beginWorktreePreparation(threadID: f.thread.id,
            selection: .createBranch(name: "unfinished-settlement", baseRef: "HEAD"), reviewSetup: true)
        let preparation = try #require(try await f.currentThread().workspacePreparation), checkout = f.harness.checkout(preparation.request)
        try await waitSettlement { await checkout.runs == 1 }
        await #expect(throws: WorkspaceCommandError.self) { _ = try await f.settle() }
        #expect(try await f.currentThread().settlement == nil)
        await checkout.complete()
        try await waitSettlement { try await f.currentThread().workspacePreparation?.setup?.phase == .awaitingApproval }
        await #expect(throws: WorkspaceCommandError.self) { _ = try await f.settle() }
        #expect(try await f.currentThread().settlement == nil)
        #expect(f.harness.scriptSessions().isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementSelectsFirstCleanupRoleAndRequiresTheExactReviewedPlan() async throws {
    let scripts: [ProjectScript] = [
        try .init(name: "Setup only", command: "printf setup", runOnWorktreeCreate: true),
        try .init(name: "First cleanup", command: "printf first-cleanup", runOnSettle: true),
        try .init(name: "Later cleanup", command: "printf later-cleanup", runOnSettle: true)
    ]
    try await withSettlementEngine(scripts: scripts) { f in
        try await f.completeCheckout(); let settlement = try await f.settle(), run = try await f.awaitingApproval()
        let plan = try #require(run.plan), thread = try await f.currentThread()
        #expect(plan.scriptIndex == 1 && plan.script == scripts[1])
        #expect(thread.projectScript(runID: run.id) == run && thread.projectScriptRole(runID: run.id) == .settle)
        #expect(f.harness.scriptSessions().isEmpty)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var script = try #require(object["script"] as? [String: Any]); script["command"] = "printf unreviewed-cleanup"; object["script"] = script
        let changed = try JSONDecoder().decode(ProjectScriptExecutionPlan.self, from: JSONSerialization.data(withJSONObject: object))
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.approveProjectScript(threadID: f.thread.id, runID: run.id, expectedPlan: changed)
        }
        #expect(f.harness.scriptSessions().isEmpty)
        let peer = try await f.approve(run)
        #expect(peer.starts == 1)
        #expect(try await f.currentSettlement().id == settlement.id)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.load().threads.first?.settlement?.script?.phase == .starting)
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementAsyncFlagAndSuccessfulExitNeverReleaseTheSettledProviderGate() async throws {
    for asynchronous in [false, true] {
        let script = try ProjectScript(name: "Cleanup gate", command: "printf cleanup", runOnSettle: true, runsAsynchronously: asynchronous)
        try await withSettlementEngine(scripts: [script]) { f in
            try await f.completeCheckout(); let generation = try await f.settle(), run = try await f.awaitingApproval()
            let peer = try await f.approve(run); peer.acknowledgeStart()
            try await waitSettlement { try await f.currentScript().phase == .running }
            var current = try await f.currentThread()
            #expect(!(await f.engine.current().snapshot.providerReady(for: current)))
            peer.complete(.exited(0))
            try await waitSettlement { try await f.currentScript().phase == .succeeded }
            current = try await f.currentThread()
            #expect(current.settlement?.id == generation.id && current.isSettled)
            #expect(!(await f.engine.current().snapshot.providerReady(for: current)))
            #expect(f.harness.providerSessions(f.thread.id).isEmpty && !peer.isClosed)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementResumeRetainsSuccessfulBackgroundOwnerUntilCloseBeforeBecomingActive() async throws {
    let script = try ProjectScript(name: "Retained cleanup job", command: "printf retained", runOnSettle: true)
    try await withSettlementEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let generation = try await f.settle(), run = try await f.awaitingApproval()
        let peer = try await f.approve(run); peer.acknowledgeStart(); peer.complete(.exited(0)); peer.holdClosure()
        try await waitSettlement { try await f.currentScript().phase == .succeeded }
        try await f.engine.resumeThread(threadID: f.thread.id, generationID: generation.id)
        try await waitSettlement { peer.closes > 0 }
        let resuming = try await f.currentThread()
        #expect(resuming.settlement?.phase == .resuming && resuming.settlement?.id == generation.id)
        #expect(resuming.settlement?.script?.commandExit == .exited(0) && !peer.isClosed)
        #expect(!(await f.engine.current().snapshot.providerReady(for: resuming)))
        peer.releaseClosure()
        try await waitSettlement { try await f.currentThread().settlement == nil }
        let active = try await f.currentThread()
        #expect(peer.isClosed && active.workspacePreparation?.isReady == true)
        #expect(await f.engine.current().snapshot.providerReady(for: active))
        #expect(peer.starts == 1 && f.harness.providerSessions(f.thread.id).isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementSubmitCapturesFIFOConfigurationAndWaitsForCleanupDrainBeforeProviderStart() async throws {
    let script = try ProjectScript(name: "Submit while settled", command: "printf cleanup", runOnSettle: true)
    try await withSettlementEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let generation = try await f.settle(), run = try await f.awaitingApproval()
        let peer = try await f.approve(run); peer.acknowledgeStart(); peer.holdClosure()
        try await waitSettlement { try await f.currentScript().phase == .running }
        let attachment = try await f.engine.attachments.importData(Data("Captured resume context".utf8), name: "resume-context.txt")
        try await f.engine.dispatch(.editThread(f.thread.id, .model("captured-first")))
        try await f.engine.dispatch(.addAttachments(threadID: f.thread.id, attachments: [attachment]))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "First resumed turn"))
        try await waitSettlement { peer.closes > 0 }
        try await f.engine.dispatch(.editThread(f.thread.id, .model("captured-second")))
        try await f.engine.dispatch(.editThread(f.thread.id, .permission(.autoAcceptEdits)))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Second resumed turn"))
        try await f.engine.dispatch(.editThread(f.thread.id, .draft("Keep the unsent draft")))
        let waiting = try await f.currentThread()
        #expect(waiting.settlement?.id == generation.id && waiting.settlement?.phase == .resuming)
        #expect(waiting.queuedTurns.count == 2 && waiting.messages.isEmpty && !peer.isClosed)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty && peer.starts == 1)
        peer.releaseClosure()
        try await waitSettlement { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
        let provider = try #require(f.harness.providerSessions(f.thread.id).first), first = try #require(await provider.turns.first)
        #expect(first.configuration.model == "captured-first" && first.configuration.permission == .supervised)
        #expect(first.input.text.contains(attachment.id.uuidString) && first.input.text.contains("First resumed turn"))
        #expect(try await f.currentThread().settlement == nil)
        await provider.finish(); try await waitSettlement { await provider.turns.count == 2 }
        let second = await provider.turns[1]
        #expect(second.configuration.model == "captured-second" && second.configuration.permission == .autoAcceptEdits)
        #expect(second.input.text == "Second resumed turn")
        #expect(try await f.currentThread().draft == "Keep the unsent draft")
        #expect(peer.isClosed && peer.starts == 1)
        await provider.finish()
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementSubmittedResumePreservesExplicitQueuePauseAcrossAnotherSubmitAndDrain() async throws {
    let script = try ProjectScript(name: "Paused resume", command: "printf cleanup", runOnSettle: true)
    try await withSettlementEngine(scripts: [script]) { f in
        try await f.completeCheckout(); _ = try await f.settle(); let run = try await f.awaitingApproval()
        let peer = try await f.approve(run); peer.acknowledgeStart(); peer.holdClosure()
        try await waitSettlement { try await f.currentScript().phase == .running }
        try await f.engine.dispatch(.editThread(f.thread.id, .model("captured-before-pause")))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "First paused resume turn"))
        try await waitSettlement { peer.closes > 0 }
        try await f.engine.dispatch(.interrupt(threadID: f.thread.id))
        try await f.engine.dispatch(.editThread(f.thread.id, .model("captured-after-pause")))
        try await f.engine.dispatch(.editThread(f.thread.id, .permission(.autoAcceptEdits)))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Second paused resume turn"))
        let waiting = try await f.currentThread()
        #expect(waiting.settlement?.phase == .resuming && waiting.queuePaused && waiting.queuedTurns.count == 2)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty && !peer.isClosed)
        peer.releaseClosure()
        try await waitSettlement { try await f.currentThread().settlement == nil }
        let paused = try await f.currentThread()
        #expect(paused.queuePaused && paused.queuedTurns.count == 2 && paused.messages.isEmpty)
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
        try await f.engine.dispatch(.resumeQueue(threadID: f.thread.id))
        try await waitSettlement { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
        let provider = try #require(f.harness.providerSessions(f.thread.id).first), first = try #require(await provider.turns.first)
        #expect(first.input.text == "First paused resume turn")
        #expect(first.configuration.model == "captured-before-pause" && first.configuration.permission == .supervised)
        await provider.finish(); try await waitSettlement { await provider.turns.count == 2 }
        let second = await provider.turns[1]
        #expect(second.input.text == "Second paused resume turn")
        #expect(second.configuration.model == "captured-after-pause" && second.configuration.permission == .autoAcceptEdits)
        #expect(peer.starts == 1 && peer.isClosed)
        await provider.finish()
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementDrainsSuccessfulSetupBackgroundJobBeforeDiscoveringCleanupRole() async throws {
    let entered = SettlementCompletionFlag()
    let planner: WorkspaceEngine.ProjectScriptPlanner = { context in
        if context.role == .settle { await entered.finish() }
        return try await ProjectScriptSetupPlanner.plan(context)
    }
    let scripts = [try ProjectScript(name: "Setup", command: "printf setup", runOnWorktreeCreate: true, runsAsynchronously: false),
                   try ProjectScript(name: "Cleanup", command: "printf cleanup", runOnSettle: true)]
    try await withSettlementEngine(scripts: scripts, planner: planner) { f in
        try await f.completeCheckout(review: true)
        try await waitSettlement { try await f.currentThread().workspacePreparation?.setup?.phase == .awaitingApproval }
        let setup = try #require(try await f.currentThread().workspacePreparation?.setup), peer = try await f.approve(setup)
        peer.acknowledgeStart(); peer.complete(.exited(0)); peer.holdClosure()
        try await waitSettlement { try await f.currentThread().workspacePreparation?.setup?.phase == .succeeded }
        _ = try await f.settle()
        try await waitSettlement { peer.closes > 0 }
        #expect(await entered.value == false)
        #expect(try await f.currentScript().plan == nil)
        #expect(!peer.isClosed)
        peer.releaseClosure()
        let cleanup = try await f.awaitingApproval()
        #expect(await entered.value)
        #expect(cleanup.plan?.script == scripts[1] && peer.isClosed)
        #expect(f.harness.scriptSessions().count == 1)
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementJoinsArchivedSetupCloseAndKeepsSubmittedResumeHeldUntilThatDrain() async throws {
    let entered = SettlementCompletionFlag()
    let planner: WorkspaceEngine.ProjectScriptPlanner = { context in
        if context.role == .settle { await entered.finish() }
        return try await ProjectScriptSetupPlanner.plan(context)
    }
    let scripts = [try ProjectScript(name: "Setup", command: "printf setup", runOnWorktreeCreate: true, runsAsynchronously: false),
                   try ProjectScript(name: "Cleanup", command: "printf cleanup", runOnSettle: true)]
    try await withSettlementEngine(scripts: scripts, planner: planner) { f in
        try await f.completeCheckout(review: true)
        try await waitSettlement { try await f.currentThread().workspacePreparation?.setup?.phase == .awaitingApproval }
        let setup = try #require(try await f.currentThread().workspacePreparation?.setup), peer = try await f.approve(setup)
        peer.acknowledgeStart(); peer.complete(.exited(0)); peer.holdClosure()
        try await waitSettlement { try await f.currentThread().workspacePreparation?.setup?.phase == .succeeded }
        try await f.engine.dispatch(.editThread(f.thread.id, .archived(true)))
        try await waitSettlement { peer.closes > 0 }
        try await f.engine.dispatch(.editThread(f.thread.id, .archived(false)))
        let generation = try await f.settle()
        let other = CodingThread(project: f.project)
        try await f.engine.dispatch(.createThread(other))
        try await f.engine.dispatch(.submit(threadID: other.id, text: "Same-project thread remains responsive"))
        try await waitSettlement { await f.harness.providerSessions(other.id).first?.turns.count == 1 }
        #expect(await entered.value == false)
        #expect(!peer.isClosed)
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Resume only after the old setup drains"))
        let waiting = try await f.currentThread()
        #expect(waiting.settlement?.id == generation.id && waiting.settlement?.phase == .resuming)
        #expect(waiting.queuedTurns.count == 1 && f.harness.providerSessions(f.thread.id).isEmpty)
        peer.releaseClosure()
        try await waitSettlement { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
        #expect(try await f.currentThread().settlement == nil)
        #expect(await entered.value == false)
        #expect(peer.isClosed && f.harness.scriptSessions().count == 1)
        await f.harness.providerSessions(f.thread.id).first?.finish()
        await f.harness.providerSessions(other.id).first?.finish()
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementJoinsOnlyItsOwnPriorIdleProviderCloseAndKeepsExplicitResumeHeld() async throws {
    let entered = SettlementCompletionFlag()
    let planner: WorkspaceEngine.ProjectScriptPlanner = { context in
        if context.role == .settle { await entered.finish() }
        return try await ProjectScriptSetupPlanner.plan(context)
    }
    let script = try ProjectScript(name: "Cleanup", command: "printf cleanup", runOnSettle: true)
    try await withSettlementEngine(scripts: [script], planner: planner) { f in
        try await f.completeCheckout()
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Create a retained provider session"))
        try await waitSettlement { await f.harness.providerSessions(f.thread.id).first?.turns.count == 1 }
        let provider = try #require(f.harness.providerSessions(f.thread.id).first)
        await provider.finish(); try await waitSettlement { try await f.currentThread().state == .idle }
        await provider.holdClosure()
        try await f.engine.dispatch(.editThread(f.thread.id, .archived(true)))
        try await waitSettlement { await provider.closes > 0 }
        try await f.engine.dispatch(.editThread(f.thread.id, .archived(false)))
        let generation = try await f.settle()
        let other = CodingThread(project: f.project)
        try await f.engine.dispatch(.createThread(other))
        try await f.engine.dispatch(.submit(threadID: other.id, text: "Another thread must not join this provider close"))
        try await waitSettlement { await f.harness.providerSessions(other.id).first?.turns.count == 1 }
        #expect(await entered.value == false)
        try await f.engine.resumeThread(threadID: f.thread.id, generationID: generation.id)
        let waiting = try await f.currentThread()
        #expect(waiting.settlement?.id == generation.id && waiting.settlement?.phase == .resuming)
        #expect(await provider.isClosed == false)
        #expect(f.harness.providerSessions(f.thread.id).count == 1 && f.harness.scriptSessions().isEmpty)
        await provider.releaseClosure()
        try await waitSettlement { try await f.currentThread().settlement == nil }
        #expect(await provider.isClosed)
        #expect(await entered.value == false)
        await f.harness.providerSessions(other.id).first?.finish()
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementRetryReplansChangedConfigurationAfterDrainingAndRequiresFreshApproval() async throws {
    let original = try ProjectScript(name: "Original cleanup", command: "printf old-cleanup", runOnSettle: true)
    try await withSettlementEngine(scripts: [original]) { f in
        try await f.completeCheckout(); let generation = try await f.settle(), old = try await f.awaitingApproval()
        let peer = try await f.approve(old); peer.acknowledgeStart(); peer.holdClosure(); peer.complete(.exited(7))
        try await waitSettlement { try await f.currentScript().phase == .failed }
        let changed = try ProjectScript(name: "Changed cleanup", command: "printf reviewed-new-cleanup", runOnSettle: true)
        let root = URL(fileURLWithPath: try await f.currentThread().workspacePath)
        try JSONEncoder().encode(try ProjectConfiguration(scripts: [changed])).write(to: root.appendingPathComponent("t3.json"), options: .atomic)
        try await f.engine.retryProjectScript(threadID: f.thread.id, runID: old.id)
        try await waitSettlement { peer.closes > 0 }
        #expect(f.harness.scriptSessions().count == 1 && !peer.isClosed)
        peer.releaseClosure()
        let fresh = try await f.awaitingApproval(), oldPlan = try #require(old.plan), newPlan = try #require(fresh.plan)
        #expect(fresh.id != old.id && fresh.previousPlans == [oldPlan])
        #expect(newPlan.script == changed && newPlan.configurationRevision != oldPlan.configurationRevision)
        #expect(try await f.currentSettlement().id == generation.id)
        #expect(f.harness.scriptSessions().count == 1 && f.harness.providerSessions(f.thread.id).isEmpty)
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.approveProjectScript(threadID: f.thread.id, runID: old.id, expectedPlan: oldPlan)
        }
        let next = try await f.approve(fresh); next.acknowledgeStart(); next.complete(.exited(0))
        try await waitSettlement { try await f.currentScript().phase == .succeeded }
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementSkipsUnprovenLegacyMainAndProjectSharedLinkedCheckouts() async throws {
    let script = try ProjectScript(name: "Dedicated cleanup only", command: "printf must-not-start", runOnSettle: true)
    for kind in ["legacy", "main", "linked"] {
        try await withSettlementEngine(scripts: [script], reuseIsMain: kind == "main") { f in
            if kind != "legacy" {
                try await f.engine.beginWorktreePreparation(threadID: f.thread.id, selection: .reuse(path: f.project.path))
                let preparation = try #require(try await f.currentThread().workspacePreparation), peer = f.harness.checkout(preparation.request)
                try await waitSettlement { await peer.runs == 1 }; await peer.complete()
                try await waitSettlement { try await f.currentThread().workspacePreparation?.isReady == true }
                let ready = try #require(try await f.currentThread().workspacePreparation)
                #expect(ready.permitsProjectSetup == (kind == "linked"))
            }
            let generation = try await f.settle()
            try await waitSettlement { try await f.currentScript().phase == .skipped }
            let current = try await f.currentThread()
            #expect(current.settlement?.id == generation.id && current.workspacePath == f.project.path)
            #expect(current.settlement?.script?.plan == nil)
            #expect(f.harness.scriptSessions().isEmpty && f.harness.providerSessions(f.thread.id).isEmpty)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementSkipWaitsForCloseAndLeavesTheConversationSettledUntilExplicitResume() async throws {
    let script = try ProjectScript(name: "Skip cleanup", command: "printf cleanup", runOnSettle: true)
    try await withSettlementEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let generation = try await f.settle(), run = try await f.awaitingApproval()
        let peer = try await f.approve(run); peer.acknowledgeStart(); peer.holdClosure()
        try await waitSettlement { try await f.currentScript().phase == .running }
        try await f.engine.skipProjectScript(threadID: f.thread.id, runID: run.id)
        try await waitSettlement { peer.closes > 0 }
        #expect(try await f.currentScript().phase == .stopping)
        #expect(!peer.isClosed && f.harness.providerSessions(f.thread.id).isEmpty)
        peer.releaseClosure()
        try await waitSettlement { try await f.currentScript().phase == .skipped }
        let settled = try await f.currentThread()
        #expect(settled.settlement?.id == generation.id && settled.settlement?.phase == .settled)
        #expect(!(await f.engine.current().snapshot.providerReady(for: settled)))
        try await f.engine.resumeThread(threadID: f.thread.id, generationID: generation.id)
        try await waitSettlement { try await f.currentThread().settlement == nil }
        #expect(f.harness.providerSessions(f.thread.id).isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementOutputAndStopResolveTheCleanupRunWithoutReleasingItsGeneration() async throws {
    let script = try ProjectScript(name: "Visible cleanup", command: "printf cleanup", runOnSettle: true)
    try await withSettlementEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let generation = try await f.settle(), run = try await f.awaitingApproval()
        let peer = try await f.approve(run); peer.acknowledgeStart()
        try await waitSettlement { try await f.currentScript().phase == .running }
        let observer = SettlementOutputObserver(), stream = try await f.engine.projectScriptOutput(threadID: f.thread.id, runID: run.id)
        let reader = Task { for await value in stream { await observer.receive(value) } }
        do {
            peer.emit(Data("cleanup output 終😀\n".utf8))
            try await waitSettlement { await observer.latest?.text.contains("cleanup output 終😀") == true }
            peer.holdClosure()
            try await f.engine.stopProjectScript(threadID: f.thread.id, runID: run.id)
            try await waitSettlement { peer.closes > 0 && peer.consumersEnded == 1 }
            #expect(await observer.latest?.isClosed == false)
            #expect(try await f.currentScript().phase == .stopping)
            peer.releaseClosure()
            try await waitSettlement { try await f.currentScript().phase == .cancelled }
            await reader.value
            #expect(await observer.latest?.isClosed == true)
            let settled = try await f.currentThread()
            #expect(settled.settlement?.id == generation.id && settled.settlement?.phase == .settled)
            #expect(!(await f.engine.current().snapshot.providerReady(for: settled)))
        } catch { peer.releaseClosure(); reader.cancel(); await reader.value; throw error }
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementRestartCancelsLostAcknowledgementOutboxWithoutReplayingCleanupOrResuming() async throws {
    let script = try ProjectScript(name: "Lost cleanup acknowledgement", command: "printf may-have-run", runOnSettle: true)
    try await withSettlementEngine(scripts: [script]) { f in
        try await f.completeCheckout(); let generation = try await f.settle(), run = try await f.awaitingApproval()
        let peer = try await f.approve(run), captured = await f.engine.current().snapshot
        #expect(captured.threads.first?.settlement?.script?.phase == .starting)
        await f.engine.shutdown()
        let database = try WorkspaceDatabase(url: f.databaseURL), plan = try #require(run.plan)
        let abandoned = PendingWorkspaceEffect(request: .startThreadScript(threadID: f.thread.id, owner: .settlement(generationID: generation.id), plan: plan))
        _ = try await database.commit(captured, event: "fixture.settlement-lost-ack", commandID: UUID(), effects: [abandoned])
        let claimed = try #require(try await database.claimNextEffect(workerID: UUID()))
        #expect(claimed.id == abandoned.id && claimed.status == .running)
        let reopened = try f.harness.engine(f.databaseURL)
        do {
            let loaded = try await reopened.load(), thread = try #require(loaded.threads.first)
            #expect(thread.settlement?.id == generation.id && thread.settlement?.phase == .settled)
            #expect(thread.settlement?.script?.id == run.id && thread.settlement?.script?.phase == .interrupted)
            #expect(thread.settlement?.script?.error == ThreadProjectScriptRun.settleInterruptedError)
            #expect(!loaded.providerReady(for: thread) && f.harness.providerSessions(f.thread.id).isEmpty)
            #expect(f.harness.scriptSessions().count == 1 && peer.starts == 1)
            #expect(try await database.effects().first { $0.id == abandoned.id }?.status == .cancelled)
            #expect(try await database.rebuildProjection().snapshot == (await reopened.current().snapshot))
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    }
}

@Test(.timeLimit(.minutes(1)))
func settlementRemovalFencesLateCleanupStatusFromReaddedProjectAndThreadIDs() async throws {
    let script = try ProjectScript(name: "Removed cleanup", command: "printf owned-cleanup", runOnSettle: true)
    try await withSettlementEngine(scripts: [script], ignoresScriptWaitCancellation: true) { f in
        try await f.completeCheckout(); let generation = try await f.settle(), run = try await f.awaitingApproval()
        let peer = try await f.approve(run); peer.holdClosure()
        try await f.engine.dispatch(.removeProject(projectID: f.project.id, expectedThreadIDs: [f.thread.id]))
        try await waitSettlement { peer.closes > 0 }
        let finished = SettlementCompletionFlag()
        let cleanup = Task { await f.engine.awaitProjectRemovalCleanup(projectID: f.project.id); await finished.finish() }
        try await f.engine.dispatch(.addProjectWithThread(project: f.project, thread: f.thread))
        let otherProject = WorkspaceProject(path: f.root.appendingPathComponent("unrelated").path), other = CodingThread(project: otherProject)
        try await f.engine.dispatch(.addProjectWithThread(project: otherProject, thread: other))
        try await f.engine.dispatch(.submit(threadID: other.id, text: "Unrelated provider stays responsive"))
        try await waitSettlement { await f.harness.providerSessions(other.id).first?.turns.count == 1 }
        #expect(await finished.value == false)
        peer.acknowledgeStart(); peer.complete(.exited(0)); peer.releaseClosure(); await cleanup.value
        let replacement = try await f.currentThread()
        #expect(replacement.settlement == nil && replacement.workspacePreparation == nil && replacement.messages.isEmpty)
        #expect(replacement.workspacePath == f.project.path && f.harness.providerSessions(f.thread.id).isEmpty)
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.resumeThread(threadID: f.thread.id, generationID: generation.id) }
        #expect(await f.engine.current().error == nil)
        await f.harness.providerSessions(other.id).first?.finish()
    }
}
