import CoincideCore
import Foundation
import Testing
@testable import Coincide

private struct GroupingUIFixture: Sendable {
    let root: URL
    let projects: [WorkspaceProject]
    let identities: [String: RepositoryIdentity]
    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-grouping-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = try #require(RepositoryIdentity.normalizedRemote("https://github.com/Team/Repository.git"))
        var projects: [WorkspaceProject] = [], identities: [String: RepositoryIdentity] = [:]
        for name in ["Checkout A", "Checkout B", "Other"] {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try "Preserve \(name)".write(to: path.appendingPathComponent("sentinel.txt"), atomically: true, encoding: .utf8)
            let project = WorkspaceProject(path: path.path)
            if name != "Other" { identities[project.path] = try RepositoryIdentity(remote: remote, remoteName: "origin", rootPath: project.path, projectRelativePath: "") }
            projects.append(project)
        }
        return .init(root: root, projects: projects, identities: identities)
    }
}

private actor GroupingUIProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private(set) var prompts: [String] = []
    private(set) var closures = 0
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) {
        prompts.append(text)
        if let run = thread.activeRun?.id {
            sink.yield(.context(runID: run, event: .thread("grouping-fixture")))
            sink.yield(.context(runID: run, event: .turn(UUID().uuidString)))
        }
    }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { closures += 1; sink.finish() }
}

@MainActor private func waitGroupingUI(_ predicate: () async throws -> Bool, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Checkout grouping did not settle at test line \(line).") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func groupedCheckoutControlsPreserveRunningOwnershipAndRouteOnlyNewConversations() async throws {
    let fixture = try GroupingUIFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let database = fixture.root.appendingPathComponent("workspace.sqlite"), provider = GroupingUIProvider()
    var initial = WorkspaceSnapshot(); initial.projects = fixture.projects
    initial.threads = fixture.projects.map { CodingThread(project: $0) }
    let storage = try WorkspaceDatabase(url: database)
    _ = try await storage.commit(initial, event: "fixture.checkout-grouping", commandID: UUID())
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in provider }, identityResolver: { fixture.identities[$0.path] })
    let store = WorkspaceStore(engine: engine, managedProjectsRoot: fixture.root.appendingPathComponent("Projects"))
    await store.load()
    do {
        let a = fixture.projects[0], b = fixture.projects[1], other = fixture.projects[2], threadA = initial.threads[0].id
        try await waitGroupingUI { store.snapshot.projects.filter { $0.repositoryIdentity != nil }.count == 2 }
        var group = try #require(store.projectGroup(containing: a.id))
        #expect(Set(group.memberProjectIDs) == [a.id, b.id] && group.members.count == 2)
        #expect(store.orderedProjectGroups.count == 2)
        store.selectedThreadID = threadA; store.selectedProjectID = a.id
        // Opening another checkout selects that project without rebinding the visible thread.
        store.selectedProjectID = b.id; store.newThread()
        try await waitGroupingUI { store.snapshot.threads.count == 4 }
        #expect(store.selectedThread?.projectID == b.id && store.selectedThread?.workspacePath == b.path)
        store.selectedThreadID = threadA; store.selectedProjectID = a.id
        #expect(await store.submit("Running in checkout A", threadID: threadA).value)
        try await waitGroupingUI { await provider.prompts.count == 1 && store.thread(threadA)?.activeRun?.nativeTurnID != nil }
        #expect(await store.submit("Queued in checkout A", threadID: threadA).value)
        store.setDraft("Unsent A draft", id: threadA)
        try await waitGroupingUI { store.snapshot.threads.first { $0.id == threadA }?.draft == "Unsent A draft" }
        let ownedThread = try #require(store.thread(threadA)), canonicalOrder = store.snapshot.projects.map(\.id)
        let effectIDs = try await storage.effects().map(\.id)
        store.setProjectGroupExpanded(group, expanded: false)
        try await waitGroupingUI { !store.isProjectGroupExpanded(group.key) }
        #expect(store.sidebarThreads(groupKey: group.key).map(\.id) == [threadA])
        #expect(store.thread(threadA) == ownedThread && store.selectedThreadID == threadA)
        store.setProjectGroupingMode(.separate)
        try await waitGroupingUI { store.projectGroupingMode == .separate && store.orderedProjectGroups.count == 3 }
        store.setProjectGroupingMode(.repository)
        try await waitGroupingUI { store.projectGroupingMode == .repository && store.orderedProjectGroups.count == 2 }
        store.setProjectGroupingOverride(a.id, mode: .separate)
        try await waitGroupingUI { store.orderedProjectGroups.count == 3 }
        store.setProjectGroupingOverride(a.id, mode: nil)
        try await waitGroupingUI { store.orderedProjectGroups.count == 2 }
        #expect(store.thread(threadA) == ownedThread && store.snapshot.projects.map(\.id) == canonicalOrder)
        #expect(try await storage.effects().map(\.id) == effectIDs)
        #expect(await provider.prompts == ["Running in checkout A"])
        #expect(await provider.closures == 0)

        group = try #require(store.projectGroup(containing: a.id))
        store.setProjectGroupCheckout(group, projectID: b.id)
        try await waitGroupingUI { store.snapshot.effectiveSidebarPreferences.activeProjectByGroup[group.key] == b.id }
        #expect(store.selectedThreadID == threadA && store.thread(threadA) == ownedThread)
        store.newThread()
        try await waitGroupingUI { store.snapshot.threads.count == 5 && store.selectedThreadID != threadA }
        let created = try #require(store.selectedThread)
        #expect(created.projectID == b.id && created.workspacePath == b.path)
        #expect(store.thread(threadA) == ownedThread)
        store.setProjectSortMode(.manual)
        try await waitGroupingUI { store.projectSortMode == .manual }
        store.moveProjectGroup(group.key, by: 1)
        try await waitGroupingUI { store.snapshot.projects.map(\.id) == [other.id, a.id, b.id] }
        #expect(store.selectedThreadID == created.id && store.thread(threadA) == ownedThread)
        store.renameProject(b.id, title: "My second checkout")
        try await waitGroupingUI { store.snapshot.projects.first { $0.id == b.id }?.name == "My second checkout" }
        let survivingThreads = store.snapshot.threads.filter { $0.projectID != a.id }
        let removal = try #require(store.projectRemovalRequest(a.id))
        try await store.removeProject(removal)
        #expect(store.snapshot.threads == survivingThreads && store.selectedThreadID == created.id)
        #expect(store.snapshot.projects.map(\.id) == [other.id, b.id])
        let count = store.snapshot.threads.count
        store.newThread(projectID: a.id)
        #expect(store.snapshot.threads.count == count && store.selectedThreadID == created.id)
        for project in fixture.projects {
            #expect(try String(contentsOfFile: project.path + "/sentinel.txt", encoding: .utf8) == "Preserve \(URL(fileURLWithPath: project.path).lastPathComponent)")
        }
        #expect(await provider.closures == 1 && store.errorMessage == nil)
        try await waitGroupingUI { store.snapshot.effectiveSidebarPreferences.selectedThreadID == created.id }
        await store.shutdown()

        let reopenedEngine = try WorkspaceEngine(url: database, identityResolver: { fixture.identities[$0.path] })
        let reopened = WorkspaceStore(engine: reopenedEngine, managedProjectsRoot: fixture.root.appendingPathComponent("Projects"))
        await reopened.load()
        #expect(reopened.projectSortMode == .manual && reopened.orderedProjectGroups.count == 2)
        let remaining = try #require(reopened.projectGroup(containing: b.id))
        #expect(reopened.snapshot.effectiveSidebarPreferences.activeProjectByGroup[remaining.key] == b.id)
        #expect(reopened.snapshot.projects.first { $0.id == b.id }?.name == "My second checkout")
        #expect(reopened.thread(created.id)?.projectID == b.id && reopened.thread(created.id)?.workspacePath == b.path)
        #expect(reopened.selectedThreadID == created.id && reopened.selectedProjectID == b.id)
        await reopened.shutdown()
    } catch { await store.shutdown(); throw error }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func groupedCheckoutCollapseRejectsStaleMembersWithoutTouchingConversations() async throws {
    let fixture = try GroupingUIFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let database = fixture.root.appendingPathComponent("workspace.sqlite")
    var initial = WorkspaceSnapshot(); initial.projects = fixture.projects
    initial.threads = fixture.projects.map { CodingThread(project: $0) }
    let storage = try WorkspaceDatabase(url: database)
    _ = try await storage.commit(initial, event: "fixture.stale-checkout-group", commandID: UUID())
    let remote = try #require(RepositoryIdentity.normalizedRemote("git@github.com:Team/Repository.git"))
    let engine = try WorkspaceEngine(url: database, identityResolver: { url in
        if url.lastPathComponent == "Other" { return nil }
        return try RepositoryIdentity(remote: remote, remoteName: "origin", rootPath: url.path, projectRelativePath: "")
    })
    let store = WorkspaceStore(engine: engine, managedProjectsRoot: fixture.root.appendingPathComponent("Projects"))
    await store.load()
    do {
        let a = fixture.projects[0]
        try await waitGroupingUI { store.projectGroup(containing: a.id)?.memberProjectIDs.count == 2 }
        let captured = try #require(store.projectGroup(containing: a.id)), threads = store.snapshot.threads
        let thirdURL = fixture.root.appendingPathComponent("Checkout C")
        try FileManager.default.createDirectory(at: thirdURL, withIntermediateDirectories: true)
        store.addProject(at: thirdURL)
        try await waitGroupingUI { store.projectGroup(containing: a.id)?.memberProjectIDs.count == 3 }
        store.setProjectGroupExpanded(captured, expanded: false)
        try await waitGroupingUI { store.errorMessage != nil }
        #expect(store.isProjectGroupExpanded(captured.key) && store.snapshot.threads == threads)
        #expect(store.snapshot.effectiveSidebarPreferences.groupExpandedByKey[captured.key] == nil)
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}
