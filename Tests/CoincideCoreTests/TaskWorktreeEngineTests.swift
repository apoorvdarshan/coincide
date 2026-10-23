import Foundation
import Testing
@testable import CoincideCore

private final class DelegatedWorktreeSetupPeer: ProjectScriptExecutionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var plan: ProjectScriptExecutionPlan?
    private let exits: AsyncStream<ProjectScriptCommandExit>
    private let exitSink: AsyncStream<ProjectScriptCommandExit>.Continuation
    private let output: AsyncStream<ProjectScriptOutputChunk>
    private let outputSink: AsyncStream<ProjectScriptOutputChunk>.Continuation
    init() { (exits, exitSink) = AsyncStream.makeStream(); (output, outputSink) = AsyncStream.makeStream() }
    var hasStarted: Bool { lock.withLock { started } }
    var capturedPlan: ProjectScriptExecutionPlan? { lock.withLock { plan } }
    func capture(_ value: ProjectScriptExecutionPlan) throws -> DelegatedWorktreeSetupPeer {
        try value.validate(); lock.withLock { plan = value }; return self
    }
    func prepare() async throws { }
    func start() throws { lock.withLock { started = true } }
    func waitUntilStarted() async throws { guard hasStarted else { throw ProjectScriptExecutionError(.launchFailed) } }
    func waitForCommandExit() async throws -> ProjectScriptCommandExit {
        for await exit in exits { return exit }; throw CancellationError()
    }
    func consumeOutput(_ receive: @escaping @Sendable (ProjectScriptOutputChunk) async -> Void) async throws {
        for await value in output { await receive(value) }
    }
    func sendInput(_ data: Data) async throws { }
    func resize(columns: Int, rows: Int) async throws { }
    func succeed() { exitSink.yield(.exited(0)); exitSink.finish() }
    func close() async { exitSink.finish(); outputSink.finish() }
}

@Test(.timeLimit(.minutes(1)))
func delegatedTaskIsolatedEnginePinsCleanParentHeadAndGatesExactFirstBriefBehindOwnedSetup() async throws {
    let f = try await WorktreeFixture.make()
    let host = f.root.appendingPathComponent("Host", isDirectory: true)
    try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
    let configuration = try ProjectConfiguration(scripts: [.init(name: "Controlled task setup", command: "fixture-command-must-never-execute", runOnWorktreeCreate: true, runsAsynchronously: false)])
    try JSONEncoder().encode(configuration).write(to: f.source.appendingPathComponent("t3.json"))
    _ = try await f.run(["add", "--", "t3.json"]); _ = try await f.run(["commit", "-m", "Private controlled setup declaration"])
    let head = String(decoding: try await f.run(["rev-parse", "HEAD"]).output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    try Data("Staged private parent bytes\n".utf8).write(to: f.source.appendingPathComponent("README.md"))
    _ = try await f.run(["add", "--", "README.md"])
    try Data("Unstaged private parent bytes\n".utf8).write(to: f.source.appendingPathComponent("README.md"))
    try Data("Never copy untracked bytes\n".utf8).write(to: f.source.appendingPathComponent("untracked-parent.txt"))
    let originalIndex = try Data(contentsOf: f.source.appendingPathComponent(".git/index"))
    let peer = DelegatedTaskTestPeer(), setup = DelegatedWorktreeSetupPeer()
    let engine = try WorkspaceEngine(url: host.appendingPathComponent("workspace.sqlite"),
        providerFactory: { DelegatedTaskTestSession(peer: peer, id: $0.id) }, identityResolver: { _ in nil },
        worktreeFactory: { f.service($0) }, projectScriptFactory: { try setup.capture($0) })
    do {
        _ = try await engine.load()
        let project = WorkspaceProject(path: f.source.path); var parent = CodingThread(project: project); parent.checkpointPolicy = .disabled
        _ = try await engine.dispatch(.addProjectWithThread(project: project, thread: parent))
        _ = try await engine.dispatch(.submit(threadID: parent.id, text: "Parent's live work"))
        try await taskEventually { await engine.current().snapshot.threads.first(where: { $0.id == parent.id })?.activeRun?.nativeTurnID != nil }
        let current = try #require(await engine.current().snapshot.threads.first { $0.id == parent.id })
        var target = ProviderConfiguration(thread: current); target.nativeThreadID = nil
        let request = DelegatedTaskRequest(parentThreadID: current.id, parentRunID: try #require(current.activeRun?.id),
            expectedConfiguration: .init(thread: current), configuration: target, task: "Only this exact isolated task brief", isolation: .worktree)
        let accepted = try await engine.createDelegatedTask(request)
        try await taskEventually { setup.hasStarted }
        let child = try #require(await engine.current().snapshot.threads.first { $0.id == accepted.childThreadID })
        #expect(child.workspacePreparation?.plan?.baseCommit == head && child.workspacePreparation?.result?.headCommit == head)
        #expect(child.activeRun == nil && child.queuedTurns.first?.text == request.prompt)
        #expect(await peer.inputs[child.id] == nil)
        #expect(setup.capturedPlan?.workspacePath == child.workspacePath && setup.capturedPlan?.script.command == "fixture-command-must-never-execute")
        #expect(try String(contentsOfFile: child.workspacePath + "/README.md", encoding: .utf8) == "Committed bytes\n")
        #expect(!FileManager.default.fileExists(atPath: child.workspacePath + "/untracked-parent.txt"))
        setup.succeed()
        try await taskEventually { await peer.inputs[child.id]?.count == 1 }
        #expect(await peer.inputs[child.id] == [request.prompt])
        #expect(try Data(contentsOf: f.source.appendingPathComponent(".git/index")) == originalIndex)
        #expect(try String(contentsOf: f.source.appendingPathComponent("README.md"), encoding: .utf8) == "Unstaged private parent bytes\n")
        await engine.shutdown(); f.cleanup()
    } catch { await setup.close(); await engine.shutdown(); throw error }
}
