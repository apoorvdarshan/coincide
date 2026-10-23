import Darwin
import Foundation
import Testing
@testable import CoincideCore

private func scratchTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-owned-scratch-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}
private func scratchCreation(_ allocation: ScratchWorkspaceAllocation, draft: String = "", prompt: String? = nil, provider: ProviderKind = .codex) throws -> ScratchThreadCreation {
    var thread = CodingThread(project: allocation.project, model: "captured-model")
    thread.id = allocation.threadID; thread.workspacePath = allocation.workspacePath; thread.scratchWorkspace = allocation.receipt
    thread.createdAt = allocation.receipt.createdAt; thread.updatedAt = allocation.receipt.createdAt
    thread.permission = .auto; thread.checkpointPolicy = .disabled; thread.draft = draft; thread.provider = provider
    if provider == .claude {
        thread.claudeRuntimeConfiguration = try ClaudeRuntimeConfiguration.capture(workspacePath: allocation.workspacePath,
            executable: "/usr/bin/false", configurationDirectory: allocation.workspacePath + "-private-claude-home",
            environment: ["HOME": allocation.workspacePath])
    }
    return .init(allocation: allocation, thread: thread, prompt: prompt)
}
private actor ScratchTestRecorder {
    struct Input: Sendable { let text: String; let thread: CodingThread }
    private(set) var inputs: [Input] = []
    private(set) var factories = 0
    func addFactory() { factories += 1 }
    func append(text: String, thread: CodingThread) { inputs.append(.init(text: text, thread: thread)) }
}
private actor ScratchTestPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    nonisolated let supportsAppMCP = true
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private let recorder: ScratchTestRecorder
    init(_ recorder: ScratchTestRecorder) { self.recorder = recorder; let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func configureAppMCP(_ connection: AppMCPConnection) {}
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) async {
        await recorder.append(text: text, thread: thread)
        guard let id = thread.activeRun?.id else { return }
        sink.yield(.context(runID: id, event: .thread(thread.id.uuidString.lowercased())))
        sink.yield(.context(runID: id, event: .turn(id.uuidString.lowercased())))
    }
    func interrupt() { sink.yield(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { sink.finish() }
}
private func scratchEventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !(await condition()) { guard ContinuousClock.now < deadline else { throw ScratchWorkspaceError("The controlled scratch boundary was not reached.") }; try await Task.sleep(for: .milliseconds(5)) }
}

@Test func scratchAllocatorCreatesOnePrivateProjectAndUniquePromptFoldersWithoutGitOrSetupAndReplaysOnlyExactClaims() throws {
    let root = try scratchTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let service = ScratchWorkspaceService(dataRoot: root), command = UUID(), threadID = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
    let first = try service.prepare(commandID: command, threadID: threadID, namingText: "Fix MY parser and add tests after this", now: now)
    let replay = try ScratchWorkspaceService(dataRoot: root).prepare(commandID: command, threadID: threadID, namingText: "Fix MY parser and add tests after this")
    #expect(first == replay && first.project.name == "No project")
    #expect(first.receipt.folderName.hasPrefix("2027-01-15-fix-my-parser-and-add-"))
    #expect(ScratchWorkspaceService.folderWords("é / HELLO__123 world four five six") == "hello-123-world-four-five")
    let second = try service.prepare(commandID: UUID(), threadID: UUID(), namingText: "Fix MY parser and add tests after this", now: now)
    #expect(second.project.id == first.project.id && second.receipt.project == first.receipt.project && second.workspacePath != first.workspacePath)
    for allocation in [first, second] {
        let url = URL(fileURLWithPath: allocation.workspacePath)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("t3.json").path))
        var info = stat(); let status = lstat(url.path, &info)
        #expect(status == 0 && info.st_uid == getuid() && info.st_mode & 0o077 == 0)
    }
    #expect(throws: ScratchWorkspaceError.self) { _ = try service.prepare(commandID: command, threadID: UUID(), namingText: "Fix MY parser and add tests after this") }
    #expect(throws: ScratchWorkspaceError.self) { _ = try service.prepare(commandID: command, threadID: threadID, namingText: "different authored intent") }
    let marker = service.root.appendingPathComponent(".coincide-scratch-project.json")
    var info = stat(); let status = lstat(marker.path, &info)
    #expect(status == 0 && info.st_mode & 0o077 == 0 && info.st_nlink == 1)
}

@Test(.timeLimit(.minutes(1)))
func scratchRegistrationAtomicallyPublishesSelectionAndKeepsAllUserFilesThroughSettleArchiveAndRestart() async throws {
    let root = try scratchTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("workspace.sqlite"), recorder = ScratchTestRecorder(), id = UUID()
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in Issue.record("Opening a scratch draft cannot start a provider"); return ScratchTestPeer(recorder) }, identityResolver: { _ in Issue.record("Scratch has no repository discovery"); return nil })
    do {
        let allocation = try await engine.prepareScratchWorkspace(commandID: id, threadID: UUID(), namingText: "Keep a literal draft")
        let draft = "  literal cafe\u{301}\n ", creation = try scratchCreation(allocation, draft: draft)
        let accepted = try await engine.createScratchThread(creation, commandID: id)
        let duplicate = try await engine.createScratchThread(creation, commandID: id)
        #expect(accepted == duplicate && accepted.rejection == nil)
        let current = await engine.current(), thread = try #require(current.snapshot.threads.first)
        #expect(current.snapshot.projects.count == 1 && current.snapshot.threads.count == 1 && current.snapshot.effectiveSidebarPreferences.selectedThreadID == thread.id)
        #expect(thread.workspacePreparation == nil && thread.settlement == nil && thread.providerThreadID == nil && thread.activeRun == nil && current.snapshot.workspaceReady(for: thread))
        #expect(thread.draft.utf8.elementsEqual(draft.utf8) && thread.messages.isEmpty && thread.checkpointPolicy == .disabled)
        let file = URL(fileURLWithPath: allocation.workspacePath).appendingPathComponent("user-work.txt")
        try Data("keep user bytes e\u{301}\n".utf8).write(to: file)
        _ = try await engine.dispatch(.settleThread(threadID: thread.id, expectedWorkspacePath: thread.workspacePath, reviewScript: true))
        let settled = await engine.current()
        #expect(settled.snapshot.threads[0].settlement?.script?.phase == .skipped)
        _ = try await engine.dispatch(.editThread(thread.id, .archived(true)))
        let archived = await engine.current()
        #expect(archived.snapshot.threads[0].isArchived && archived.snapshot.threads[0].settlement?.script?.phase == .cancelled)
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep user bytes e\u{301}\n")
        await engine.shutdown()
        let reopened = try WorkspaceEngine(url: database, providerFactory: { _ in Issue.record("Receipt recovery cannot replay input"); return ScratchTestPeer(recorder) }, identityResolver: { _ in nil })
        do {
            let recovered = try await reopened.createScratchThread(creation, commandID: id)
            #expect(recovered == accepted)
            let rows = try await reopened.scratchWorkspaceRecoveries()
            #expect(rows.count == 1 && rows[0].phase == .accepted)
            var refused = false
            do { _ = try await reopened.discardEmptyScratchAllocation(commandID: id) } catch { refused = true }
            #expect(refused && FileManager.default.fileExists(atPath: file.path))
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
        #expect(await recorder.inputs.isEmpty)
    } catch { await engine.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func scratchFirstInputCapturesActualClaudeFolderAndExactLiteralOnceWithoutCopyingNativeContext() async throws {
    let root = try scratchTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = ScratchTestRecorder(), id = UUID(), database = root.appendingPathComponent("workspace.sqlite")
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in ScratchTestPeer(recorder) }, identityResolver: { _ in nil })
    do {
        let allocation = try await engine.prepareScratchWorkspace(commandID: id, threadID: UUID(), namingText: "First independent task")
        let prompt = "  exact first prompt e\u{301}\n ", creation = try scratchCreation(allocation, prompt: prompt, provider: .claude)
        let accepted = try await engine.createScratchThread(creation, commandID: id)
        try await scratchEventually { await recorder.inputs.count == 1 }
        let inputs = await recorder.inputs
        let input = try #require(inputs.first)
        #expect(input.text.utf8.elementsEqual(prompt.utf8))
        let configuration = try #require(input.thread.activeRun?.configuration)
        #expect(configuration.workspacePath.utf8.elementsEqual(allocation.workspacePath.utf8) && configuration.claudeRuntimeConfiguration?.registeredWorkspacePath.utf8.elementsEqual(allocation.workspacePath.utf8) == true)
        #expect(configuration.nativeThreadID == nil && configuration.permission == .auto && configuration.model == "captured-model")
        #expect(input.thread.activeRun?.id == id && input.thread.contextTransferLineage == nil)
        let duplicate = try await engine.createScratchThread(creation, commandID: id)
        let duplicateCount = await recorder.inputs.count
        #expect(duplicate == accepted && duplicateCount == 1)
        let changed = try scratchCreation(allocation, prompt: "a different input", provider: .claude)
        var refused = false
        do { _ = try await engine.createScratchThread(changed, commandID: id) } catch { refused = true }
        let refusedCount = await recorder.inputs.count
        #expect(refused && refusedCount == 1)
    } catch { await engine.shutdown(); throw error }
    await engine.shutdown()
}

@Test(.timeLimit(.minutes(1)))
func scratchOrdinaryCommandsCannotForgeReceiptsAndReplacedFoldersNeverReachTheProvider() async throws {
    let root = try scratchTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = ScratchTestRecorder(), id = UUID()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in ScratchTestPeer(recorder) }, identityResolver: { _ in nil })
    do {
        let allocation = try await engine.prepareScratchWorkspace(commandID: id, threadID: UUID())
        let creation = try scratchCreation(allocation)
        var rejected = false
        do { _ = try await engine.dispatch(.addProject(allocation.project)) } catch { rejected = true }
        #expect(rejected)
        _ = try await engine.createScratchThread(creation, commandID: id)
        rejected = false
        do { _ = try await engine.dispatch(.createThread(creation.thread)) } catch { rejected = true }
        #expect(rejected)
        var forged = creation.thread; forged.id = UUID(); forged.scratchWorkspace = nil
        rejected = false
        do { _ = try await engine.dispatch(.createThread(forged)) } catch { rejected = true }
        #expect(rejected)
        let current = await engine.current()
        var invalid = creation.thread; invalid.id = UUID()
        #expect(!current.snapshot.workspaceReady(for: invalid))
        var recreated = creation.thread; recreated.createdAt = recreated.createdAt.addingTimeInterval(1)
        var changed = current.snapshot; changed.threads = [recreated]
        #expect(!changed.workspaceReady(for: recreated))
        let backup = allocation.workspacePath + "-owned-backup"
        try FileManager.default.moveItem(atPath: allocation.workspacePath, toPath: backup)
        try FileManager.default.createDirectory(atPath: allocation.workspacePath, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let foreign = URL(fileURLWithPath: allocation.workspacePath).appendingPathComponent("foreign.txt")
        try Data("foreign bytes".utf8).write(to: foreign)
        rejected = false
        do { try await engine.validateScratchWorkspace(threadID: allocation.threadID, workspacePath: allocation.workspacePath) } catch { rejected = true }
        #expect(rejected)
        _ = try await engine.dispatch(.submit(threadID: allocation.threadID, text: "must not reach a replaced folder"))
        try await scratchEventually { await engine.current().snapshot.threads.first?.runHistory?.last?.status.isTerminal == true }
        #expect(await recorder.inputs.isEmpty)
        #expect(try String(contentsOf: foreign, encoding: .utf8) == "foreign bytes")
        #expect(FileManager.default.fileExists(atPath: backup))
    } catch { await engine.shutdown(); throw error }
    await engine.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func scratchUnknownOriginalRequestIsSealedWithoutReplayAndCleanupNeverDeletesUserContents(hasFiles: Bool) async throws {
    let root = try scratchTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in Issue.record("Cleanup cannot replay a saved input"); throw CancellationError() }, identityResolver: { _ in nil })
    do {
        let id = UUID(), allocation = try await engine.prepareScratchWorkspace(commandID: id, threadID: UUID())
        let creation = try scratchCreation(allocation, prompt: "saved original task")
        let service = ScratchWorkspaceService(dataRoot: root), payload = try ScratchWorkspaceService.bytes(EngineCommand.scratchThreadAccepted(creation))
        try service.recordSubmission(creation, payload: payload)
        let file = URL(fileURLWithPath: allocation.workspacePath).appendingPathComponent("user.txt")
        if hasFiles { try Data("owned user work".utf8).write(to: file) }
        let before = try await engine.scratchWorkspaceRecoveries()
        #expect(before.first?.phase == .uncertain)
        let removed = try await engine.discardEmptyScratchAllocation(commandID: id)
        #expect(removed == !hasFiles)
        if hasFiles { #expect(try String(contentsOf: file, encoding: .utf8) == "owned user work") }
        else { #expect(!FileManager.default.fileExists(atPath: allocation.workspacePath)) }
        var refused = false
        do { _ = try await engine.createScratchThread(creation, commandID: id) } catch { refused = true }
        #expect(refused)
        let current = await engine.current()
        #expect(current.snapshot.threads.isEmpty)
    } catch { await engine.shutdown(); throw error }
    await engine.shutdown()
}

@Test(.timeLimit(.minutes(1)))
func scratchFreshContextReuseRequiresAnOwnedPhysicalGrantAndNeverDeletesTheSharedSourceFolder() async throws {
    let root = try scratchTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in throw CancellationError() }, identityResolver: { _ in nil })
    do {
        let id = UUID(), source = try await engine.prepareScratchWorkspace(commandID: id, threadID: UUID())
        _ = try await engine.createScratchThread(scratchCreation(source), commandID: id)
        let file = URL(fileURLWithPath: source.workspacePath).appendingPathComponent("source-code.txt")
        try Data("unchanged code".utf8).write(to: file)
        let grantID = UUID(), destinationID = UUID()
        let grant = try await engine.prepareScratchWorkspaceReuse(sourceThreadID: source.threadID, destinationThreadID: destinationID, commandID: grantID)
        #expect(grant.workspacePath.utf8.elementsEqual(source.workspacePath.utf8) && grant.receipt.identity == source.receipt.identity)
        #expect(grant.threadID == destinationID && grant.receipt.sharedFrom == source.receipt.commandID)
        let created = try scratchCreation(grant)
        _ = try await engine.createScratchThread(created, commandID: grantID)
        let cancelledID = UUID(), cancelled = try await engine.prepareScratchWorkspaceReuse(sourceThreadID: destinationID, destinationThreadID: UUID(), commandID: cancelledID)
        #expect(cancelled.receipt.sharedFrom == source.receipt.commandID)
        let discarded = try await engine.discardEmptyScratchAllocation(commandID: cancelledID)
        #expect(discarded && FileManager.default.fileExists(atPath: file.path))
        try ScratchWorkspaceService(dataRoot: root).validate(thread: created.thread)
        #expect(try String(contentsOf: file, encoding: .utf8) == "unchanged code")
    } catch { await engine.shutdown(); throw error }
    await engine.shutdown()
}

@Test(arguments: [false, true])
func scratchAllocatorRefusesUnknownOrSymlinkedRootsWithoutAdoptingOrRemovingTheirFiles(symlink: Bool) throws {
    let root = try scratchTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let foreign = root.appendingPathComponent("Foreign")
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = foreign.appendingPathComponent("foreign.txt"); try Data("keep".utf8).write(to: file)
    let scratch = root.appendingPathComponent("Scratch")
    if symlink { try FileManager.default.createSymbolicLink(at: scratch, withDestinationURL: foreign) }
    else { try FileManager.default.moveItem(at: foreign, to: scratch) }
    var refused = false
    do { _ = try ScratchWorkspaceService(dataRoot: root).prepare(commandID: UUID(), threadID: UUID(), namingText: "") } catch { refused = true }
    #expect(refused)
    let retained = symlink ? file : scratch.appendingPathComponent("foreign.txt")
    #expect(try String(contentsOf: retained, encoding: .utf8) == "keep")
}

private actor ScratchToolProbe {
    private(set) var actions: [AppMCPAction] = []
    func perform(_ action: AppMCPAction) -> JSONValue { actions.append(action); return .object(["accepted": .bool(true)]) }
}
@Test func scratchMCPLaunchIsExplicitAndBoundedWhileProjectOmissionStillInheritsTheCaller() async throws {
    let project = WorkspaceProject(path: "/private/synthetic-scratch-tool")
    let thread = CodingThread(project: project), probe = ScratchToolProbe()
    let context = AppMCPContext(scope: .init(sessionID: UUID(), threadID: thread.id, projectID: project.id, provider: .codex,
        runtimeID: UUID(), incarnation: UUID(), providerInstanceID: CodexRuntimeConfiguration.defaultInstanceID,
        workspacePath: thread.workspacePath, permission: .supervised, capabilities: [.orchestration, .worktree]),
        runID: UUID(), configuration: .init(thread: thread))
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let view = AppMCPView(snapshot: snapshot, sequence: 1)
    let tools = AppMCPTools(client: .init(read: { _ in view }, perform: { action, _ in await probe.perform(action) }))
    let explicit = await tools.call(name: "t3_thread_launch", arguments: .object(["scratch": .bool(true), "title": .string("Private scratch"), "message": .string("  exact prompt e\u{301}\n ")]), context: context)
    #expect(!explicit.isError)
    let actions = await probe.actions
    let first = try #require(actions.first)
    if case .launchThread(let request) = first {
        #expect(request.scratch && request.projectID == nil && request.workspace == .root)
        #expect(request.creation.prompt?.utf8.elementsEqual("  exact prompt e\u{301}\n ".utf8) == true)
    } else { Issue.record("Scratch must use the ordinary closed launch action") }
    let inherited = await tools.call(name: "t3_thread_launch", arguments: .object(["title": .string("Caller project")]), context: context)
    #expect(!inherited.isError)
    let all = await probe.actions
    let last = try #require(all.last)
    if case .launchThread(let request) = last { #expect(!request.scratch && request.projectID == project.id) }
    else { Issue.record("Project omission must retain the existing caller-project route") }
    let invalidInputs: [JSONValue] = [
        .object(["scratch": .bool(true), "projectId": .string(project.id.uuidString), "title": .string("Wrong")]),
        .object(["scratch": .bool(true), "workspaceStrategy": .object(["type": .string("root")]), "title": .string("Wrong")]),
        .object(["scratch": .string("true"), "title": .string("Wrong")]),
        .object(["scratch": .bool(true), "executable": .string("/private/foreign"), "title": .string("Wrong")])
    ]
    for invalid in invalidInputs {
        let result = await tools.call(name: "t3_thread_launch", arguments: invalid, context: context)
        #expect(result.isError)
    }
    let contextOnly = AppMCPTools(client: .init(read: { _ in view }, perform: { action, _ in await probe.perform(action) }), allowedToolNames: ["t3_context_read"])
    let refused = await contextOnly.call(name: "t3_thread_launch", arguments: .object(["scratch": .bool(true), "title": .string("No writes")]), context: context)
    #expect(refused.isError)
    #expect(await probe.actions.count == 2)
}

@Test(.timeLimit(.minutes(1)))
func scratchMCPActiveCallerCreatesOneIndependentOwnedFolderWithInheritedPermissionWithoutChangingParentDraft() async throws {
    let root = try scratchTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
    let project = WorkspaceProject(path: workspace.path), recorder = ScratchTestRecorder()
    var parent = CodingThread(project: project, model: "captured-model")
    parent.permission = .supervised; parent.checkpointPolicy = .disabled; parent.draft = "Keep parent literal draft"
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [parent]
    let database = root.appendingPathComponent("workspace.sqlite")
    try await WorkspaceDatabase(url: database).save(snapshot, event: "fixture.scratch-mcp")
    let engine = try WorkspaceEngine(url: database, appMCPEnabled: true, providerFactory: { _ in ScratchTestPeer(recorder) }, identityResolver: { _ in nil })
    do {
        _ = try await engine.dispatch(.submitFromAppMCP(threadID: parent.id, text: "Parent run", queueEvenWhenIdle: false))
        try await scratchEventually { (try? await engine.appMCPContext(threadID: parent.id)) != nil }
        let context = try await engine.appMCPContext(threadID: parent.id)
        let value = try await engine.performScopedAppMCP(.launchThread(.init(scratch: true,
            creation: .init(title: "Independent scratch", prompt: "  independent exact task\n "))), context: context)
        let text = try #require(value["threadId"].string), childID = try #require(UUID(uuidString: text))
        try await scratchEventually { await recorder.inputs.contains { $0.thread.id == childID } }
        let current = await engine.current(), child = try #require(current.snapshot.threads.first { $0.id == childID })
        let original = try #require(current.snapshot.threads.first { $0.id == parent.id })
        #expect(child.projectID != project.id && child.scratchWorkspace != nil && child.permission == .supervised)
        #expect(child.workspacePreparation == nil && child.contextTransferLineage == nil && child.delegatedTaskLineage == nil)
        #expect(child.createdByAppMCP?.threadID == parent.id && original.draft.utf8.elementsEqual(parent.draft.utf8))
        #expect(current.snapshot.workspaceReady(for: child) && child.activeRun?.configuration.workspacePath.utf8.elementsEqual(child.workspacePath.utf8) == true)
        #expect(child.messages.filter { $0.role == .user }.first?.text.utf8.elementsEqual("  independent exact task\n ".utf8) == true)
    } catch { await engine.shutdown(); throw error }
    await engine.shutdown()
}

@Test(arguments: ["missing", "corrupt", "replaced"])
func scratchStorageFailuresRemainTypedRefusalsAndDoNotBlockIndependentAllocations(mode: String) throws {
    let root = try scratchTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let service = ScratchWorkspaceService(dataRoot: root), commandID = UUID()
    let allocation = try service.prepare(commandID: commandID, threadID: UUID(), namingText: "Original")
    let claim = service.root.appendingPathComponent("allocation-" + commandID.uuidString.lowercased() + ".json")
    switch mode {
    case "missing": try FileManager.default.removeItem(at: claim)
    case "corrupt": try Data("{invalid private claim".utf8).write(to: claim)
    default:
        try FileManager.default.moveItem(atPath: allocation.workspacePath, toPath: allocation.workspacePath + "-retained")
        try FileManager.default.createDirectory(atPath: allocation.workspacePath, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    #expect(throws: ScratchWorkspaceError.self) { try service.validate(allocation) }
    let independent = try service.prepare(commandID: UUID(), threadID: UUID(), namingText: "Independent")
    #expect(independent.project.id == allocation.project.id && independent.workspacePath != allocation.workspacePath)
    try service.validate(independent)
}
