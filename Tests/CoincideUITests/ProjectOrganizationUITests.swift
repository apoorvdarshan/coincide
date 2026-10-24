import AppKit
import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

@MainActor private func waitOrganizationUI(_ predicate: () async throws -> Bool, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Project organization did not settle at test line \(line).") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func organizationUIRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-organization-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeProjectOrganizationKeepsManualOrderAcrossSortModesAndPersistsCollapseRenameAndDrafts() async throws {
    let root = try organizationUIRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("workspace.sqlite")
    var projects: [WorkspaceProject] = []
    for (index, name) in ["Alpha", "Beta", "Gamma"].enumerated() {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        var project = WorkspaceProject(path: path.path)
        project.createdAt = Date(timeIntervalSince1970: Double(index + 1) * 10); project.updatedAt = project.createdAt
        projects.append(project)
    }
    let plan = try GitClonePlan.prepare(source: "https://example.invalid/native.git", destination: root.appendingPathComponent("Cloning"))
    var cloneProject = WorkspaceProject(path: plan.destinationPath)
    var clone = ProjectCloneState(plan: plan); clone.phase = .failed; clone.error = "The fixture remote is unavailable."
    cloneProject.clone = clone; projects.append(cloneProject)
    var threads: [CodingThread] = []
    for index in projects.indices {
        var thread = CodingThread(project: projects[index])
        thread.title = ["Selected conversation", "Assistant activity", "Another project", "Waiting checkout"][index]
        thread.createdAt = Date(timeIntervalSince1970: [100, 300, 200, 20][index])
        thread.updatedAt = Date(timeIntervalSince1970: index == 1 ? 20_000 : [500, 400, 450, 20][index])
        if index < 3 {
            var user = ChatMessage(role: .user, text: "User request in \(projects[index].name)")
            user.createdAt = Date(timeIntervalSince1970: [500, 400, 450][index]); thread.messages.append(user)
        }
        if index == 1 {
            var assistant = ChatMessage(role: .assistant, text: "A later agent update must not reorder user activity")
            assistant.createdAt = Date(timeIntervalSince1970: 30_000); thread.messages.append(assistant)
        }
        threads.append(thread)
    }
    var hidden = CodingThread(project: projects[0]); hidden.title = "Collapsed sibling"
    hidden.createdAt = Date(timeIntervalSince1970: 99); hidden.updatedAt = Date(timeIntervalSince1970: 499)
    threads.append(hidden)
    var initial = WorkspaceSnapshot(); initial.projects = projects; initial.threads = threads
    let storage = try WorkspaceDatabase(url: database)
    _ = try await storage.commit(initial, event: "fixture.project-organization", commandID: UUID())
    let store = WorkspaceStore(databaseURL: database)
    await store.load()
    do {
        let a = projects[0].id, b = projects[1].id, c = projects[2].id, d = projects[3].id, selected = threads[0].id
        #expect(store.projectSortMode == .updatedAt && store.orderedProjects.map(\.id) == [a, c, b, d])
        #expect(store.snapshot.projects.map(\.id) == [a, b, c, d] && store.selectedThreadID == selected)
        store.setDraft("Preserve the unsent draft", id: selected)
        try await waitOrganizationUI { store.snapshot.threads.first { $0.id == selected }?.draft == "Preserve the unsent draft" }
        let preservedThreads = store.snapshot.threads
        store.setProjectExpanded(a, expanded: false)
        try await waitOrganizationUI { !store.isProjectExpanded(a) }
        #expect(store.sidebarThreads(projectID: a).map(\.id) == [selected])
        #expect(store.selectedThreadID == selected && store.thread(selected)?.draft == "Preserve the unsent draft")
        store.search = "No conversation matches this query"
        #expect(store.sidebarThreads(projectID: a).isEmpty && store.selectedThreadID == selected)
        #expect(store.orderedProjects.map(\.id) == [a, c, b, d])
        store.search = ""; store.showArchived = true
        #expect(store.sidebarThreads(projectID: a).isEmpty)
        store.showArchived = false
        #expect(store.sidebarThreads(projectID: a).map(\.id) == [selected])
        store.setProjectSortMode(.createdAt)
        try await waitOrganizationUI { store.projectSortMode == .createdAt }
        #expect(store.orderedProjects.map(\.id) == [b, c, a, d])
        #expect(store.snapshot.projects.map(\.id) == [a, b, c, d])
        store.setProjectSortMode(.manual)
        try await waitOrganizationUI { store.projectSortMode == .manual }
        store.moveProject(c, by: -1)
        try await waitOrganizationUI { store.orderedProjects.map(\.id) == [a, c, b, d] }
        store.moveProjects(fromOffsets: IndexSet([0, 1]), toOffset: 4)
        try await waitOrganizationUI { store.snapshot.projects.map(\.id) == [b, d, a, c] }
        store.setProjectSortMode(.updatedAt)
        try await waitOrganizationUI { store.projectSortMode == .updatedAt }
        #expect(store.orderedProjects.map(\.id) == [a, c, b, d] && store.snapshot.projects.map(\.id) == [b, d, a, c])
        store.setProjectSortMode(.manual)
        try await waitOrganizationUI { store.projectSortMode == .manual }
        #expect(store.orderedProjects.map(\.id) == [b, d, a, c])
        store.renameProject(d, title: "  Renamed Clone  ")
        try await waitOrganizationUI { store.snapshot.projects.first { $0.id == d }?.name == "Renamed Clone" }
        let renamed = try #require(store.snapshot.projects.first { $0.id == d })
        #expect(renamed.path == projects[3].path && renamed.clone == clone && renamed.createdAt == projects[3].createdAt)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed Clone").path))
        #expect(store.snapshot.threads == preservedThreads && store.errorMessage == nil)
        if ProcessInfo.processInfo.environment["COINCIDE_RENDER_ORGANIZATION"] == "1" { try await captureProjectOrganization(store) }
        await store.shutdown()

        let reopened = WorkspaceStore(databaseURL: database)
        await reopened.load()
        #expect(reopened.projectSortMode == .manual && reopened.orderedProjects.map(\.id) == [b, d, a, c])
        #expect(!reopened.isProjectExpanded(a) && reopened.sidebarThreads(projectID: a).map(\.id) == [selected])
        #expect(reopened.thread(selected)?.draft == "Preserve the unsent draft")
        #expect(reopened.snapshot.projects.first { $0.id == d }?.name == "Renamed Clone")
        #expect(reopened.snapshot.projects.first { $0.id == d }?.clone == clone)
        await reopened.shutdown()
    } catch { await store.shutdown(); throw error }
}

private actor OrganizationUIProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var prompts: [String] = []
    private(set) var interruptions = 0
    private(set) var closures = 0
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) {
        runID = thread.activeRun?.id; prompts.append(text)
        emit(.thread("organization-fixture")); emit(.turn(UUID().uuidString))
    }
    func finish() { emit(.completed(.idle)) }
    func interrupt() { interruptions += 1; emit(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { closures += 1; sink.finish() }
    private func emit(_ event: ProviderEvent) {
        if let runID { sink.yield(.context(runID: runID, event: event)) } else { sink.yield(event) }
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeProjectCollapseRenameAndReorderPreserveAnActiveAgentQueuedTurnAndComposerDraft() async throws {
    let root = try organizationUIRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("workspace.sqlite"), provider = OrganizationUIProvider()
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in provider })
    let installation = CodexInstallation(rootURL: root.appendingPathComponent("Tools/Codex"), release: nil,
        localResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") })
    let store = WorkspaceStore(engine: engine, codexInstallation: installation)
    await store.load()
    do {
        store.addProject(at: root)
        try await waitOrganizationUI { store.snapshot.projects.count == 1 && store.selectedProjectID != nil }
        let projectID = try #require(store.selectedProjectID)
        store.newThread(projectID: projectID)
        try await waitOrganizationUI { store.selectedThreadID != nil }
        let threadID = try #require(store.selectedThreadID)
        #expect(store.thread(threadID)?.provider == .codex, "The synthetic session uses a supported provider without executing a CLI.")
        #expect(await store.submit("First running turn", threadID: threadID).value)
        try await waitOrganizationUI { await provider.prompts.count == 1 && store.thread(threadID)?.activeRun?.nativeTurnID != nil }
        #expect(await store.submit("Second queued turn", threadID: threadID).value)
        store.setDraft("Unsent while the agent works", id: threadID)
        try await waitOrganizationUI { store.snapshot.threads.first { $0.id == threadID }?.draft == "Unsent while the agent works" }
        let before = try #require(store.thread(threadID))
        let other = root.appendingPathComponent("Another Project")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        store.addProject(at: other)
        try await waitOrganizationUI { store.snapshot.projects.count == 2 }
        store.setProjectSortMode(.manual)
        try await waitOrganizationUI { store.projectSortMode == .manual }
        store.setProjectExpanded(projectID, expanded: false)
        store.renameProject(projectID, title: "Working Project")
        store.moveProject(projectID, by: 1)
        try await waitOrganizationUI {
            !store.isProjectExpanded(projectID) && store.snapshot.projects.first { $0.id == projectID }?.name == "Working Project"
                && store.snapshot.projects.last?.id == projectID
        }
        #expect(store.thread(threadID) == before && store.selectedThreadID == threadID)
        #expect(store.sidebarThreads(projectID: projectID).map(\.id) == [threadID])
        #expect(await provider.prompts == ["First running turn"])
        let interruptions = await provider.interruptions, closures = await provider.closures
        #expect(interruptions == 0 && closures == 0)
        await provider.finish()
        try await waitOrganizationUI { await provider.prompts.count == 2 }
        #expect(await provider.prompts == ["First running turn", "Second queued turn"])
        await provider.finish()
        try await waitOrganizationUI { store.thread(threadID)?.state == .idle && store.thread(threadID)?.queuedTurns.isEmpty == true }
        #expect(store.thread(threadID)?.draft == "Unsent while the agent works" && store.errorMessage == nil)
        #expect(store.thread(threadID)?.workspacePath == before.workspacePath && !store.isProjectExpanded(projectID))
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}

@MainActor private func captureProjectOrganization(_ store: WorkspaceStore) async throws {
    _ = NSApplication.shared
    let originalAppearance = NSApp.appearance
    defer { NSApp.appearance = originalAppearance }
    for scheme in [ColorScheme.light, .dark] {
        let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        NSApp.appearance = appearance
        for width in [CGFloat(280), 340] {
            let hosting = NSHostingView(rootView: SidebarView(store: store, onNewProject: { })
                .environment(\.colorScheme, scheme).environment(\.controlActiveState, .active).frame(width: width, height: 680)
                .background(scheme == .light ? Color.white : Color(white: 0.12)))
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 680), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance; hosting.appearance = appearance
            window.isReleasedWhenClosed = false; window.contentView = hosting
            defer { window.close() }
            appearance.performAsCurrentDrawingAppearance { hosting.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(180))
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            appearance.performAsCurrentDrawingAppearance {
                hosting.layoutSubtreeIfNeeded()
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            }
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-project-organization-\(scheme == .light ? "light" : "dark")-\(Int(width)).png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
            print("Native project organization preview: \(path.path)")
        }
    }
}
