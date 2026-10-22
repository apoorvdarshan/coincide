import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct ClaudeWorkspaceCaptureFixture {
    let root: URL, source: URL, destination: URL, alias: URL
    let runtime: ClaudeRuntimeConfiguration
    let snapshot: WorkspaceSnapshot
    init() throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-workspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let pointer = requested.path.withCString({ realpath($0, nil) }) else { throw CoincideError("The private Claude workspace fixture is unavailable.") }
        root = URL(fileURLWithPath: String(cString: pointer)); free(pointer)
        source = root.appendingPathComponent("Original Workspace")
        destination = root.appendingPathComponent("Actual Destination 工作")
        alias = root.appendingPathComponent("Registered Alias")
        for path in [source, destination] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        runtime = .init(executable: root.appendingPathComponent("never-executed-claude").path,
            configurationDirectory: root.appendingPathComponent("Private Native Configuration").path, workspacePath: source.path)
        let project = WorkspaceProject(path: source.path)
        var thread = CodingThread(project: project); thread.workspacePath = source.path
        thread.provider = .claude; thread.claudeRuntimeConfiguration = runtime; thread.checkpointPolicy = .disabled
        thread.draft = "Keep this unsent text 工作 😀"
        var value = WorkspaceSnapshot(); value.projects = [project]; value.threads = [thread]; snapshot = value
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1)))
func claudeWorkspaceEngineCapturesPhysicalAliasBeforeAtomicRegisteredPathEdit() async throws {
    let fixture = try ClaudeWorkspaceCaptureFixture(); defer { fixture.cleanup() }
    let database = fixture.root.appendingPathComponent("workspace.sqlite")
    try await WorkspaceDatabase(url: database).save(fixture.snapshot, event: "claude.workspace.fixture")
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in
        Issue.record("Changing an empty Claude workspace must not launch a provider."); throw CancellationError()
    }, identityResolver: { _ in nil }, worktreeFactory: { _ in
        Issue.record("A direct workspace edit must not create a worktree."); throw CancellationError()
    })
    do {
        _ = try await engine.load()
        _ = try await engine.dispatch(.editThread(fixture.snapshot.threads[0].id, .workspacePath(fixture.alias.path)))
        let current = await engine.current().snapshot
        let thread = try #require(current.threads.first)
        #expect(thread.workspacePath == fixture.alias.path)
        #expect(thread.claudeRuntimeConfiguration?.registeredWorkspacePath == fixture.alias.path)
        #expect(thread.claudeRuntimeConfiguration?.workspacePath == fixture.destination.path)
        #expect(thread.claudeRuntimeConfiguration?.executable == fixture.runtime.executable)
        #expect(thread.claudeRuntimeConfiguration?.configurationDirectory == fixture.runtime.configurationDirectory)
        #expect(thread.draft == fixture.snapshot.threads[0].draft && thread.messages.isEmpty && thread.activeRun == nil)
        try WorkspaceJournal.validate(current)
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}

@Test func claudeWorkspacePureCaptureRejectsChangedLauncherOrHomeAndDoesNotResolveAliasDuringReduction() throws {
    let fixture = try ClaudeWorkspaceCaptureFixture(); defer { fixture.cleanup() }
    let desired = try fixture.runtime.replacingWorkspace(fixture.alias.path, physicalPath: fixture.destination.path)
    let threadID = fixture.snapshot.threads[0].id
    try FileManager.default.removeItem(at: fixture.alias)
    let valid = try WorkspaceDecision.make(.client(.editThread(threadID, .claudeWorkspace(desired))), id: UUID(), snapshot: fixture.snapshot, now: Date())
    #expect(valid.snapshot.threads[0].claudeRuntimeConfiguration == desired)
    #expect(valid.snapshot.threads[0].workspacePath == fixture.alias.path)
    for changedLauncher in [false, true] {
        let foreign = ClaudeRuntimeConfiguration(instanceID: desired.instanceID,
            executable: changedLauncher ? fixture.root.appendingPathComponent("another-launcher").path : desired.executable,
            configurationDirectory: changedLauncher ? desired.configurationDirectory : fixture.root.appendingPathComponent("Another Native Home").path,
            projectDirectoryName: desired.projectDirectoryName, workspacePath: desired.workspacePath,
            registeredWorkspacePath: desired.registeredWorkspacePath, precompactProfile: desired.precompactProfile)
        #expect(throws: WorkspaceCommandError.self) {
            _ = try WorkspaceDecision.make(.client(.editThread(threadID, .claudeWorkspace(foreign))), id: UUID(), snapshot: fixture.snapshot, now: Date())
        }
    }
}

@Test(arguments: [false, true])
func claudeWorktreeRetryRebindsHeaderAndCapturedFIFOToReviewedFutureAliasWithoutAmbientRecapture(captured: Bool) throws {
    let fixture = try ClaudeWorkspaceCaptureFixture(); defer { fixture.cleanup() }
    let selection = GitWorktreeSelection.createBranch(name: "feature/native-capture", baseRef: "HEAD")
    let old = GitWorktreeRequest(sourcePath: fixture.source.path, destinationRoot: fixture.alias.path, selection: selection)
    let next = GitWorktreeRequest(sourcePath: fixture.source.path, destinationRoot: fixture.alias.path, selection: selection)
    let oldPhysical = fixture.destination.appendingPathComponent(old.id.uuidString).path
    let nextPhysical = try ClaudeRuntimeValidation.physical(next.destinationPath, allowMissing: true)
    var snapshot = fixture.snapshot, thread = snapshot.threads[0]
    thread.workspacePath = old.destinationPath
    if captured { thread.claudeRuntimeConfiguration = try fixture.runtime.replacingWorkspace(old.destinationPath, physicalPath: oldPhysical) }
    else { thread.claudeRuntimeConfiguration = nil }
    var preparation = ThreadWorkspacePreparation(request: old); preparation.phase = .interrupted
    thread.workspacePreparation = preparation; thread.queuePaused = true
    var queued = ProviderConfiguration(thread: thread); queued.model = "future-queued-model"; queued.permission = .fullAccess
    let queuedID = UUID()
    thread.queuedTurns = [.init(id: queuedID, text: "Retain queued input and settings", configuration: queued, createdAt: Date())]
    snapshot.threads[0] = thread; try WorkspaceJournal.validate(snapshot)
    let reviewed = try thread.claudeRuntimeConfiguration?.replacingWorkspace(next.destinationPath, physicalPath: nextPhysical)
    // This tests the reducer's captured handoff, never a second filesystem/PATH
    // lookup during replay. No worktree or destination is created by this test.
    try FileManager.default.removeItem(at: fixture.alias)
    let decision = try WorkspaceDecision.make(.beginWorktreePreparation(threadID: thread.id, request: next,
        expectedSourcePath: old.destinationPath, previousAttemptID: old.id, incarnation: UUID(),
        claudeRuntimeConfiguration: reviewed), id: next.id, snapshot: snapshot, now: Date())
    let rebound = decision.snapshot.threads[0], successor = try #require(rebound.queuedTurns.first)
    #expect(rebound.workspacePath == next.destinationPath && rebound.workspacePreparation?.previousAttempts.first?.request == old)
    #expect(successor.id == queuedID && successor.configuration.workspacePath == next.destinationPath)
    #expect(successor.configuration.model == "future-queued-model" && successor.configuration.permission == .fullAccess)
    #expect(successor.configuration.nativeThreadID == nil && successor.configuration.claudeLaunchSelection == nil)
    if captured {
        #expect(rebound.claudeRuntimeConfiguration == reviewed && successor.configuration.claudeRuntimeConfiguration == reviewed)
        #expect(reviewed?.workspacePath == nextPhysical && reviewed?.registeredWorkspacePath == next.destinationPath)
        #expect(reviewed?.executable == fixture.runtime.executable && reviewed?.configurationDirectory == fixture.runtime.configurationDirectory)
    } else { #expect(rebound.claudeRuntimeConfiguration == nil && successor.configuration.claudeRuntimeConfiguration == nil) }
    #expect(!FileManager.default.fileExists(atPath: nextPhysical))
    #expect(decision.effects.count == 1)
}

private func claudeWorkspaceHeldSnapshot(_ kind: String) throws -> (WorkspaceSnapshot, UUID, String) {
    if kind == "restore" {
        var fixture = try CheckpointRestoreFixture(provider: .claude)
        let review = try fixture.review(); _ = try fixture.accept(review)
        return (fixture.snapshot, fixture.threadID, fixture.thread.workspacePath)
    }
    if kind == "creation" {
        var fixture = PullRequestCreationFixture(); fixture.snapshot.threads[0].provider = .claude
        let review = try fixture.review(), operation = fixture.operation(review); _ = try fixture.accept(operation)
        return (fixture.snapshot, fixture.threadID, fixture.snapshot.threads[0].workspacePath)
    }
    var fixture = PullRequestCheckoutFixture()
    let request = try fixture.request(), plan = try fixture.plan(request), review = try fixture.review(plan)
    _ = try fixture.command(.pullRequestCheckoutAccepted(.init(review: review)))
    return (fixture.snapshot, fixture.threadID, fixture.snapshot.threads[0].workspacePath)
}

private func claudeWorkspaceWithoutFileHolds(_ value: WorkspaceSnapshot) -> WorkspaceSnapshot {
    var result = value
    result.checkpointRestoreOperations = nil; result.pullRequestCreations = nil; result.pullRequestCheckouts = nil
    return result
}

@Test(arguments: ["restore", "creation", "checkout"])
func claudeWorkspaceCapturedEditCannotBypassHeldDestinationGuard(kind: String) throws {
    let fixture = try ClaudeWorkspaceCaptureFixture(); defer { fixture.cleanup() }
    var (locked, _, heldPath) = try claudeWorkspaceHeldSnapshot(kind)
    locked.projects += fixture.snapshot.projects; locked.threads += fixture.snapshot.threads
    try WorkspaceJournal.validate(locked)
    let threadID = fixture.snapshot.threads[0].id
    let target = try fixture.runtime.replacingWorkspace(heldPath, physicalPath: heldPath)
    let command = EngineCommand.client(.editThread(threadID, .claudeWorkspace(target)))
    let unlocked = try WorkspaceDecision.make(command, id: UUID(), snapshot: claudeWorkspaceWithoutFileHolds(locked), now: Date())
    #expect(unlocked.snapshot.threads.last?.workspacePath == heldPath)
    #expect(throws: WorkspaceCommandError.self) { _ = try WorkspaceDecision.make(command, id: UUID(), snapshot: locked, now: Date()) }
    #expect(locked.threads.last == fixture.snapshot.threads[0])
}

@Test(arguments: ["restore", "creation", "checkout"])
func claudeWorkspaceCapturedSubmitCannotBypassHeldSourceGuard(kind: String) throws {
    let (locked, threadID, heldPath) = try claudeWorkspaceHeldSnapshot(kind)
    try WorkspaceJournal.validate(locked)
    let capture = ClaudeRuntimeConfiguration(executable: "/fixture/never-executed-claude", configurationDirectory: "/fixture/private-native-config",
        workspacePath: heldPath, registeredWorkspacePath: heldPath)
    let command = EngineCommand.client(.submitCapturedClaude(threadID: threadID, text: "Must remain unsent while held", configuration: capture))
    let unlocked = try WorkspaceDecision.make(command, id: UUID(), snapshot: claudeWorkspaceWithoutFileHolds(locked), now: Date())
    #expect(unlocked.snapshot.threads.first(where: { $0.id == threadID })?.activeRun?.configuration.claudeRuntimeConfiguration == capture)
    #expect(throws: WorkspaceCommandError.self) { _ = try WorkspaceDecision.make(command, id: UUID(), snapshot: locked, now: Date()) }
    #expect(locked.threads.first(where: { $0.id == threadID })?.activeRun == nil)
}
