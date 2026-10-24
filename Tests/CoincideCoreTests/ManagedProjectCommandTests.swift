import Foundation
import Testing
@testable import CoincideCore

private struct ManagedProviderInvocation: Sendable {
    let threadID: UUID
    let projectID: UUID
    let workspacePath: String
    let prompt: String
    let readme: String
}

private actor ManagedCommandProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var invocations: [ManagedProviderInvocation] = []
    private(set) var closed = false
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) throws {
        let readme = try String(contentsOf: URL(fileURLWithPath: thread.workspacePath).appendingPathComponent("README.md"), encoding: .utf8)
        invocations.append(.init(threadID: thread.id, projectID: thread.projectID, workspacePath: thread.workspacePath, prompt: text, readme: readme))
        runID = thread.activeRun?.id
        emit(.thread("managed-project-\(thread.id)")); emit(.turn(UUID().uuidString))
    }
    func finish() { emit(.completed(.idle)) }
    func interrupt() { emit(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { closed = true; sink.finish() }
    private func emit(_ event: ProviderEvent) {
        if let runID { sink.yield(.context(runID: runID, event: event)) }
        else { sink.yield(event) }
    }
}

private final class ManagedCommandHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: [ManagedCommandProvider]] = [:]
    func make(_ thread: CodingThread) -> any ProviderSession {
        lock.lock(); defer { lock.unlock() }
        let provider = ManagedCommandProvider(); values[thread.id, default: []].append(provider); return provider
    }
    func providers(_ threadID: UUID) -> [ManagedCommandProvider] {
        lock.lock(); defer { lock.unlock() }; return values[threadID] ?? []
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.values.reduce(0) { $0 + $1.count } }
}

private struct ManagedCommandFixture {
    let root: URL
    let engine: WorkspaceEngine
    let harness: ManagedCommandHarness
    var databaseURL: URL { root.appendingPathComponent("workspace.sqlite") }
    /// Registration receives an already-created folder. Repository scaffolding has its own tests.
    func preparedProject(_ folder: String, title: String = "Managed Project") throws -> WorkspaceProject {
        let url = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "# \(title)\n\nPrepared workspace: \(folder)\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        var project = WorkspaceProject(path: url.path); project.name = title; return project
    }
}
private func withManagedCommands(_ body: (ManagedCommandFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let harness = ManagedCommandHarness()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { harness.make($0) })
    do {
        _ = try await engine.load(); try await body(.init(root: root, engine: engine, harness: harness))
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}
private func waitManagedCommand(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Managed project command test timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1))) func managedProjectRegistrationPersistsFullTitleAndStarterTogetherWithoutStartingProvider() async throws {
    FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration begin\n".utf8))
    try await withManagedCommands { f in
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration fixture-ready\n".utf8))
        let title = "Café & 日本 — A complete project display title"
        let project = try f.preparedProject("cafe-japan", title: title)
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration project-prepared\n".utf8))
        var thread = CodingThread(project: project); thread.draft = "Keep this unsent starter draft"
        let starter = thread, commandID = UUID(), before = await f.engine.current()
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration before-dispatch\n".utf8))
        let receipt = try await f.engine.dispatch(.addProjectWithThread(project: project, thread: starter), id: commandID)
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration after-dispatch\n".utf8))
        let after = await f.engine.current().snapshot
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration snapshot-read\n".utf8))
        #expect(after.projects == [project] && after.threads == [starter])
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration snapshot-comparison-finished\n".utf8))
        #expect(after.projects[0].name == title && after.threads[0].workspacePath == project.path)
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration metadata-check-finished\n".utf8))
        #expect(after.workspaceReady(for: starter) && after.threads[0].messages.isEmpty && after.threads[0].activeRun == nil)
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration readiness-check-finished\n".utf8))
        #expect(f.harness.count == 0)
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration memory-checks-finished\n".utf8))
        let database = try WorkspaceDatabase(url: f.databaseURL)
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration database-open\n".utf8))
        #expect(try await database.receipt(commandID) == receipt)
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration receipt-read\n".utf8))
        #expect(try await database.effects(commandID: commandID).isEmpty)
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration effects-read\n".utf8))
        let records = try await database.journal(after: before.sequence)
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration journal-read\n".utf8))
        #expect(!records.isEmpty && records.allSatisfy { $0.commandID == commandID })
        #expect(records.contains { if case .projectUpserted(let value) = $0.event { value == project } else { false } })
        #expect(records.contains { if case .threadMetadataUpserted(let value) = $0.event { value.id == starter.id && value.projectID == project.id } else { false } })
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration before-rebuild\n".utf8))
        #expect(try await database.rebuildProjection().snapshot == after)
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration after-rebuild\n".utf8))
        #expect(try String(contentsOf: URL(fileURLWithPath: project.path).appendingPathComponent("README.md"), encoding: .utf8).contains(title))
        FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration body-finished\n".utf8))
    }
    FileHandle.standardError.write(Data("COINCIDE_TEST_PHASE managedProjectRegistration cleanup-finished\n".utf8))
}

@Test(.timeLimit(.minutes(1))) func managedProjectRegistrationSurvivesRestartWithoutRecreatingFolderOrFirstConversation() async throws {
    try await withManagedCommands { f in
        let project = try f.preparedProject("restart-folder", title: "Full restart title 🌍")
        let starter = CodingThread(project: project), id = UUID()
        let command = WorkspaceCommand.addProjectWithThread(project: project, thread: starter)
        let receipt = try await f.engine.dispatch(command, id: id)
        let readmeURL = URL(fileURLWithPath: project.path).appendingPathComponent("README.md")
        try "User edits made after registration\n".write(to: readmeURL, atomically: true, encoding: .utf8)
        let persisted = await f.engine.current().snapshot
        await f.engine.shutdown()
        let reopened = try WorkspaceEngine(url: f.databaseURL, providerFactory: { f.harness.make($0) })
        do {
            let recovered = try await reopened.load()
            #expect(recovered == persisted && recovered.projects[0].name == "Full restart title 🌍")
            #expect(recovered.threads[0].workspacePath == project.path && recovered.threads[0].projectID == project.id)
            #expect(try await reopened.dispatch(command, id: id) == receipt)
            #expect(await reopened.current().snapshot == recovered && f.harness.count == 0)
            #expect(try String(contentsOf: readmeURL, encoding: .utf8) == "User edits made after registration\n")
            let database = try WorkspaceDatabase(url: f.databaseURL)
            #expect(try await database.rebuildProjection().snapshot == recovered)
            #expect(try await database.effects().isEmpty)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    }
}

@Test(.timeLimit(.minutes(1))) func managedProjectCommandDeduplicatesReceiptAndRejectsChangedPayloadWithoutRevertingNewerEdits() async throws {
    try await withManagedCommands { f in
        let project = try f.preparedProject("deduplicated"), starter = CodingThread(project: project), id = UUID()
        let command = WorkspaceCommand.addProjectWithThread(project: project, thread: starter)
        let first = try await f.engine.dispatch(command, id: id)
        try await f.engine.dispatch(.editThread(starter.id, .title("A newer conversation title")))
        let beforeDuplicate = await f.engine.current()
        #expect(try await f.engine.dispatch(command, id: id) == first)
        #expect(await f.engine.current().snapshot == beforeDuplicate.snapshot)
        #expect(await f.engine.current().sequence == beforeDuplicate.sequence)
        var changedProject = project; changedProject.name = "A conflicting payload"
        let collision = WorkspaceCommand.addProjectWithThread(project: changedProject, thread: starter)
        do { try await f.engine.dispatch(collision, id: id); Issue.record("A reused command identity accepted a different payload.") }
        catch WorkspaceCommitError.commandIDCollision { }
        #expect(await f.engine.current().snapshot == beforeDuplicate.snapshot && f.harness.count == 0)
        #expect(await f.engine.current().error == nil)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.receipt(id) == first)
        #expect(try await database.effects().isEmpty)
    }
}

private enum InvalidManagedStarter: String, CaseIterable {
    case wrongProject, wrongWorkspace, populatedHistory, activeRun, queuedTurn
}
@Test(.timeLimit(.minutes(1))) func invalidManagedStarterRejectsTheWholeRegistrationAndKeepsPreparedFiles() async throws {
    try await withManagedCommands { f in
        let database = try WorkspaceDatabase(url: f.databaseURL), baseline = await f.engine.current()
        let eventCount = try await database.journalEventCount()
        for invalid in InvalidManagedStarter.allCases {
            let project = try f.preparedProject("rejected-" + invalid.rawValue)
            var candidate = CodingThread(project: project)
            switch invalid {
            case .wrongProject: candidate.projectID = UUID()
            case .wrongWorkspace: candidate.workspacePath = f.root.path
            case .populatedHistory: candidate.messages = [.init(role: .user, text: "Not a new conversation")]
            case .activeRun:
                candidate.activeRun = .init(id: UUID(), configuration: .init(thread: candidate), startedAt: Date())
                candidate.state = .running
            case .queuedTurn:
                candidate.queuedTurns = [.init(id: UUID(), text: "Already queued", configuration: .init(thread: candidate), createdAt: Date())]
            }
            let proposed = candidate, commandID = UUID()
            await #expect(throws: WorkspaceCommandError.self) {
                try await f.engine.dispatch(.addProjectWithThread(project: project, thread: proposed), id: commandID)
            }
            let unchanged = await f.engine.current()
            #expect(unchanged.snapshot == baseline.snapshot && unchanged.sequence == baseline.sequence)
            #expect(unchanged.error == nil && f.harness.count == 0)
            #expect(try await database.journalEventCount() == eventCount)
            #expect(try await database.receipt(commandID)?.rejection != nil)
            #expect(try await database.effects().isEmpty)
            #expect(try String(contentsOf: URL(fileURLWithPath: project.path).appendingPathComponent("README.md"), encoding: .utf8).contains("Prepared workspace"))
        }
        // Rejections do not poison the workspace or block a later valid creation.
        let project = try f.preparedProject("valid-after-rejections"), thread = CodingThread(project: project)
        try await f.engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        #expect(await f.engine.current().snapshot.projects == [project])
    }
}

@Test(.timeLimit(.minutes(1))) func managedProjectRegistrationRejectsExistingProjectPathProjectIdentityAndThreadIdentity() async throws {
    try await withManagedCommands { f in
        let existing = try f.preparedProject("existing"), existingThread = CodingThread(project: existing)
        try await f.engine.dispatch(.addProject(existing)); try await f.engine.dispatch(.createThread(existingThread))
        let baseline = await f.engine.current()
        var duplicateID = try f.preparedProject("different-folder"); duplicateID.id = existing.id
        let alias = f.root.appendingPathComponent("existing-parent-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
        let duplicatePath = WorkspaceProject(path: alias.appendingPathComponent("existing").path)
        #expect(duplicatePath.path == existing.path)
        let newProject = try f.preparedProject("new-project-reused-thread")
        var duplicateThread = CodingThread(project: newProject); duplicateThread.id = existingThread.id
        let candidates: [(WorkspaceProject, CodingThread)] = [
            (duplicateID, CodingThread(project: duplicateID)),
            (duplicatePath, CodingThread(project: duplicatePath)),
            (newProject, duplicateThread),
        ]
        for (project, thread) in candidates {
            await #expect(throws: WorkspaceCommandError.self) {
                try await f.engine.dispatch(.addProjectWithThread(project: project, thread: thread))
            }
            #expect(await f.engine.current().snapshot == baseline.snapshot)
            #expect(await f.engine.current().sequence == baseline.sequence && f.harness.count == 0)
        }
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.effects().isEmpty)
    }
}

@Test(.timeLimit(.minutes(1))) func managedRegistrationCannotSmuggleCloneStateOrStartACloneEffect() async throws {
    try await withManagedCommands { f in
        let plan = try GitClonePlan.prepare(source: "https://example.invalid/native.git", destination: f.root.appendingPathComponent("not-a-managed-create"))
        var project = WorkspaceProject(path: plan.destinationPath); project.clone = .init(plan: plan)
        let proposed = project, starter = CodingThread(project: proposed), before = await f.engine.current()
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.dispatch(.addProjectWithThread(project: proposed, thread: starter))
        }
        #expect(await f.engine.current().snapshot == before.snapshot && f.harness.count == 0)
        #expect(!FileManager.default.fileExists(atPath: plan.stagingPath) && !FileManager.default.fileExists(atPath: plan.destinationPath))
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.effects().isEmpty)
    }
}

@Test(.timeLimit(.minutes(1))) func concurrentManagedRegistrationsForOneFolderHaveExactlyOneProjectAndStarterWinner() async throws {
    try await withManagedCommands { f in
        let firstProject = try f.preparedProject("one-folder"), firstThread = CodingThread(project: firstProject)
        let secondProject = WorkspaceProject(path: firstProject.path), secondThread = CodingThread(project: secondProject)
        async let first: WorkspaceCommandReceipt? = try? f.engine.dispatch(.addProjectWithThread(project: firstProject, thread: firstThread))
        async let second: WorkspaceCommandReceipt? = try? f.engine.dispatch(.addProjectWithThread(project: secondProject, thread: secondThread))
        let results = await (first, second)
        #expect([results.0, results.1].compactMap { $0 }.count == 1)
        let state = await f.engine.current().snapshot
        #expect(state.projects.count == 1 && state.threads.count == 1)
        #expect(state.threads[0].projectID == state.projects[0].id && state.threads[0].workspacePath == firstProject.path)
        #expect(Set([firstProject.id, secondProject.id]).contains(state.projects[0].id) && f.harness.count == 0)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.rebuildProjection().snapshot == state)
        #expect(try await database.effects().isEmpty)
    }
}

@Test(.timeLimit(.minutes(1))) func newlyRegisteredManagedProjectStartsItsFirstTurnInItsFolderWithoutDisturbingOpenWork() async throws {
    try await withManagedCommands { f in
        let openProject = try f.preparedProject("open-work", title: "Existing project"), openThread = CodingThread(project: openProject)
        try await f.engine.dispatch(.addProject(openProject)); try await f.engine.dispatch(.createThread(openThread))
        try await f.engine.dispatch(.submit(threadID: openThread.id, text: "Keep existing work running"))
        try await waitManagedCommand { await f.harness.providers(openThread.id).first?.invocations.count == 1 }
        try await waitManagedCommand { await f.engine.current().snapshot.threads.first { $0.id == openThread.id }?.activeRun?.nativeTurnID != nil }
        let existingProvider = try #require(f.harness.providers(openThread.id).first)
        let existingBefore = try #require(await f.engine.current().snapshot.threads.first { $0.id == openThread.id })
        let managed = try f.preparedProject("new-managed-folder", title: "New managed project"), starter = CodingThread(project: managed)
        try await f.engine.dispatch(.addProjectWithThread(project: managed, thread: starter))
        #expect(await f.engine.current().snapshot.threads.first { $0.id == openThread.id } == existingBefore)
        #expect(await existingProvider.closed == false && f.harness.providers(starter.id).isEmpty)
        try await f.engine.dispatch(.submit(threadID: starter.id, text: "First managed turn"))
        try await waitManagedCommand { await f.harness.providers(starter.id).first?.invocations.count == 1 }
        let provider = try #require(f.harness.providers(starter.id).first), invocation = try #require(await provider.invocations.first)
        #expect(invocation.projectID == managed.id && invocation.threadID == starter.id)
        #expect(invocation.workspacePath == managed.path && invocation.prompt == "First managed turn")
        #expect(invocation.readme.contains("New managed project") && invocation.readme.contains("new-managed-folder"))
        #expect(await existingProvider.closed == false && f.harness.providers(openThread.id).count == 1)
        await provider.finish(); await existingProvider.finish()
        // Provider idle is published before the automatic post-run observation.
        // Compare replay only after both turns and their checkpoint effects settle.
        try await waitManagedCommand {
            await f.engine.current().snapshot.threads.allSatisfy { thread in
                let records = thread.runHistory ?? []
                return thread.state == .idle && thread.activeRun == nil && thread.queuedTurns.isEmpty && records.count == 1 && records.allSatisfy { record in
                    guard record.status == .completed, let checkpoints = record.checkpoints,
                          checkpoints.providerReleased, checkpoints.pendingStart == nil, let post = checkpoints.postRun else { return false }
                    return !checkpoints.baseline.phase.isRunning && !post.phase.isRunning
                }
            }
        }
        let finished = await f.engine.current().snapshot, database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(finished.threads.first { $0.id == starter.id }?.messages.first?.text == "First managed turn")
        #expect(try await database.rebuildProjection().snapshot == finished)
    }
}
