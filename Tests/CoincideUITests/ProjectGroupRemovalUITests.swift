import CoincideCore
import CoincideTerminal
import Darwin
import Foundation
import Testing
@testable import Coincide

private actor GroupRemovalProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var closeStarted = false
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) {
        if let runID = thread.activeRun?.id {
            sink.yield(.context(runID: runID, event: .thread("group-removal-fixture")))
            sink.yield(.context(runID: runID, event: .turn(UUID().uuidString)))
        }
    }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() async {
        guard !closeStarted else { return }; closeStarted = true; sink.finish()
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { released = true; let saved = waiter; waiter = nil; saved?.resume() }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func groupedRemovalKeepsASurvivingArchivedConversationVisibleAndRestoresItOnRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-group-removal-archived-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var projects: [WorkspaceProject] = [], identities: [String: RepositoryIdentity] = [:]
    let remote = try #require(RepositoryIdentity.normalizedRemote("https://example.invalid/Team/Repo.git"))
    for name in ["A", "B", "C"] {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = WorkspaceProject(path: directory.path); projects.append(project)
        if name != "C" { identities[project.path] = try RepositoryIdentity(remote: remote, remoteName: "origin", rootPath: project.path, projectRelativePath: "") }
    }
    let active = CodingThread(project: projects[2])
    var removed = CodingThread(project: projects[1]), surviving = CodingThread(project: projects[2])
    removed.isArchived = true; surviving.isArchived = true
    var initial = WorkspaceSnapshot(); initial.projects = projects; initial.threads = [removed, active, surviving]
    initial.sidebarPreferences = .init(selectedThreadID: removed.id)
    let url = root.appendingPathComponent("workspace.sqlite"), resolverValues = identities
    _ = try await WorkspaceDatabase(url: url).commit(initial, event: "fixture.archived-group-removal", commandID: UUID())
    let engine = try WorkspaceEngine(url: url, identityResolver: { resolverValues[$0.path] })
    let store = WorkspaceStore(engine: engine, managedProjectsRoot: root.appendingPathComponent("Projects"))
    await store.load()
    do {
        try await waitGroupRemoval { store.projectGroup(containing: projects[0].id)?.memberProjectIDs.count == 2 }
        #expect(store.showArchived && store.selectedThreadID == removed.id)
        let group = try #require(store.projectGroup(containing: projects[0].id))
        try await store.removeProjectGroup(#require(store.projectGroupRemovalRequest(group.key)))
        #expect(store.selectedThreadID == surviving.id && store.selectedProjectID == projects[2].id && store.showArchived)
        #expect(store.visibleThreads.map(\.id) == [surviving.id] && store.snapshot.threads == [active, surviving])
        await store.shutdown()
        let reopened = WorkspaceStore(databaseURL: url); await reopened.load()
        #expect(reopened.selectedThreadID == surviving.id && reopened.showArchived && reopened.visibleThreads.map(\.id) == [surviving.id])
        await reopened.shutdown()
    } catch { await store.shutdown(); throw error }
}
private actor GroupRemovalProbe {
    private(set) var finished = false
    func finish() { finished = true }
}
@MainActor private func waitGroupRemoval(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Grouped removal did not settle.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func removingAGroupLocksEveryCheckoutStopsBothWindowsAndDoesNotAwaitUnrelatedCleanup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-group-removal-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var projects: [WorkspaceProject] = [], identities: [String: RepositoryIdentity] = [:]
    let remote = try #require(RepositoryIdentity.normalizedRemote("https://example.invalid/Team/Grouped.git"))
    let bytes = Data("All checkout files survive grouped removal.\n".utf8)
    for name in ["A", "B", "Survivor", "Unrelated"] {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent("keep.txt"))
        let project = WorkspaceProject(path: directory.path); projects.append(project)
        if name == "A" || name == "B" { identities[project.path] = try RepositoryIdentity(remote: remote, remoteName: "origin", rootPath: project.path, projectRelativePath: "") }
    }
    let a = projects[0], b = projects[1], survivor = projects[2], unrelated = projects[3]
    let threadA = CodingThread(project: a), threadD = CodingThread(project: unrelated)
    var threadB = CodingThread(project: b); threadB.isArchived = true
    var survivingThread = CodingThread(project: survivor); survivingThread.workspacePath = a.path
    let databaseURL = root.appendingPathComponent("workspace.sqlite")
    var initial = WorkspaceSnapshot(); initial.projects = projects; initial.threads = [threadA, threadB, survivingThread, threadD]
    let database = try WorkspaceDatabase(url: databaseURL)
    _ = try await database.commit(initial, event: "fixture.grouped-removal-ui", commandID: UUID())
    let providerA = GroupRemovalProvider(), providerD = GroupRemovalProvider(), resolverValues = identities
    let engine = try WorkspaceEngine(url: databaseURL, providerFactory: { $0.projectID == a.id ? providerA : providerD }, identityResolver: { resolverValues[$0.path] })
    let store = WorkspaceStore(engine: engine, managedProjectsRoot: root.appendingPathComponent("Projects"))
    await store.load()
    let windowOne = TerminalWorkspaceStore(), windowTwo = TerminalWorkspaceStore()
    store.registerTerminals(windowOne); store.registerTerminals(windowTwo)
    let terminalA = try LocalTerminalSession(directory: URL(fileURLWithPath: a.path), executable: "/bin/sh", arguments: ["-c", "exec sleep 120"])
    let terminalB = try LocalTerminalSession(directory: URL(fileURLWithPath: b.path), executable: "/bin/sh", arguments: ["-c", "exec sleep 120"])
    let terminalC = try LocalTerminalSession(directory: URL(fileURLWithPath: survivor.path), executable: "/bin/sh", arguments: ["-c", "exec sleep 120"])
    defer { terminalA.close(); terminalB.close(); terminalC.close() }
    windowOne.sessions[threadA.id] = [terminalA]; windowTwo.sessions[threadB.id] = [terminalB]; windowTwo.sessions[survivingThread.id] = [terminalC]
    let inspector = store.gitInspector(path: a.path)
    store.fileNavigation = .init(workspacePath: a.path, path: "keep.txt", line: 1)
    var removingGroup: Task<Void, any Error>?, removingOther: Task<Void, any Error>?
    do {
        try await waitGroupRemoval { store.projectGroup(containing: a.id)?.memberProjectIDs.count == 2 }
        try await engine.dispatch(.submit(threadID: threadA.id, text: "Hold grouped cleanup"))
        try await engine.dispatch(.submit(threadID: threadD.id, text: "Hold unrelated cleanup"))
        try await waitGroupRemoval { store.thread(threadA.id)?.activeRun?.nativeTurnID != nil && store.thread(threadD.id)?.activeRun?.nativeTurnID != nil }
        let group = try #require(store.projectGroup(containing: a.id))
        let preservedThreads = store.snapshot.threads
        store.renameProjectGroup(group, title: "All Grouped Checkouts")
        try await waitGroupRemoval { store.snapshot.projects.filter { $0.name == "All Grouped Checkouts" }.count == 2 }
        #expect(store.snapshot.threads == preservedThreads && store.snapshot.projects.map(\.path) == projects.map(\.path))
        let early = try #require(store.projectGroupRemovalRequest(group.key)), dirtyA = UUID(), dirtyB = UUID()
        store.setEditorDirty(dirtyA, workspacePath: a.path, dirty: true); store.setEditorDirty(dirtyB, workspacePath: b.path, dirty: true)
        do { try await store.removeProjectGroup(early); Issue.record("New dirty editors were silently discarded.") }
        catch { #expect(error.localizedDescription.contains("unsaved")) }
        #expect(store.canEditWorkspace(a.path) && store.canEditWorkspace(b.path))
        let beforeThread = try #require(store.projectGroupRemovalRequest(group.key)), newThread = CodingThread(project: b)
        try await engine.dispatch(.createThread(newThread))
        try await waitGroupRemoval { store.thread(newThread.id) != nil }
        do { try await store.removeProjectGroup(beforeThread); Issue.record("A new conversation was silently included.") }
        catch { #expect(error.localizedDescription.contains("changed")) }
        #expect(store.canEditWorkspace(a.path) && store.canEditWorkspace(b.path))

        let otherRequest = try #require(store.projectRemovalRequest(unrelated.id)), otherDone = GroupRemovalProbe()
        removingOther = Task { try await store.removeProject(otherRequest); await otherDone.finish() }
        try await waitGroupRemoval { await providerD.closeStarted && !store.snapshot.projects.contains { $0.id == unrelated.id } }
        let request = try #require(store.projectGroupRemovalRequest(group.key)), groupDone = GroupRemovalProbe()
        #expect(Set(request.projects.map(\.id)) == [a.id, b.id] && Set(request.threadIDs) == [threadA.id, threadB.id, newThread.id])
        #expect(request.dirtyEditorIDs == [dirtyA, dirtyB])
        store.selectedThreadID = threadA.id; store.selectedProjectID = a.id
        removingGroup = Task { try await store.removeProjectGroup(request); await groupDone.finish() }
        try await waitGroupRemoval { await providerA.closeStarted && store.snapshot.projects.map(\.id) == [survivor.id] }
        #expect(!store.canEditWorkspace(a.path) && !store.canEditWorkspace(b.path) && !store.canEditWorkspace(unrelated.path))
        #expect(store.canEditWorkspace(survivor.path) && store.thread(survivingThread.id)?.workspacePath == a.path)
        #expect(store.gitInspector(path: a.path) === inspector && store.fileNavigation?.workspacePath == a.path)
        #expect(store.snapshot.threads == [survivingThread] && store.selectedThreadID == survivingThread.id)
        await providerA.release()
        try await waitGroupRemoval { await groupDone.finished }
        try await removingGroup?.value
        #expect(await otherDone.finished == false)
        #expect(store.canEditWorkspace(a.path) && store.canEditWorkspace(b.path) && !store.canEditWorkspace(unrelated.path))
        #expect(windowOne.sessions[threadA.id] == nil && windowTwo.sessions[threadB.id] == nil)
        #expect(windowTwo.sessions[survivingThread.id]?.first === terminalC && terminalC.lifecycle == .running)
        #expect(terminalA.lifecycle != .running && terminalB.lifecycle != .running)
        for project in projects { #expect(try Data(contentsOf: URL(fileURLWithPath: project.path).appendingPathComponent("keep.txt")) == bytes) }
        await providerD.release(); try await removingOther?.value
        #expect(store.errorMessage == nil)
        await store.shutdown()
        let reopened = WorkspaceStore(databaseURL: databaseURL); await reopened.load()
        #expect(reopened.snapshot.projects.map(\.id) == [survivor.id] && reopened.snapshot.threads == [survivingThread])
        #expect(reopened.selectedThreadID == survivingThread.id)
        await reopened.shutdown()
    } catch {
        await providerA.release(); await providerD.release()
        _ = await removingGroup?.result; _ = await removingOther?.result; await store.shutdown(); throw error
    }
}
