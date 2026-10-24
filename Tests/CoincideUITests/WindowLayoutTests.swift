import AppKit
import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

@Test func initialMainWindowFillsTheSelectedDisplay() {
    #expect(MainWindowSizing.size(fitting: CGSize(width: 1024, height: 674)) == CGSize(width: 1024, height: 674))
    #expect(MainWindowSizing.size(fitting: CGSize(width: 900, height: 1200)) == CGSize(width: 900, height: 1200))
    #expect(MainWindowSizing.size(fitting: CGSize(width: 2560, height: 1400)) == CGSize(width: 2560, height: 1400))
}

@MainActor @Test func chatLayoutAcceptsANarrowDetailBesideTheSidebar() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-window-layout-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"))
    let project = WorkspaceProject(path: root.path)
    let thread = CodingThread(project: project)
    store.snapshot.projects = [project]; store.snapshot.threads = [thread]
    store.selectedThreadID = thread.id; store.selectedProjectID = project.id; store.isLoading = false
    let detail = NSHostingController(rootView: ChatView(store: store, threadID: thread.id))
    // Probe the SwiftUI minimum directly, rather than an NSWindow's default zero minimum.
    #expect(detail.sizeThatFits(in: CGSize(width: 0, height: 600)).width <= 632)
    let workspace = NSHostingController(rootView: ContentView(store: store).frame(minWidth: 900, minHeight: 600))
    #expect(workspace.sizeThatFits(in: CGSize(width: 900, height: 600)).width <= 900)
    await store.shutdown()
}

@MainActor @Test func embeddedSettingsNavigationKeepsConversationAndDraftInOneWindow() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-settings-layout-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"))
    let project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project); thread.draft = "Unsent native chat"
    store.snapshot.projects = [project]; store.snapshot.threads = [thread]
    store.selectedThreadID = thread.id; store.selectedProjectID = project.id; store.isLoading = false
    for page in [SettingsPage.general, .appearance, .configuration, .skills, .commands, .mcp, .plugins, .hooks, .sessions] {
        store.showSettings(page)
        #expect(store.showingSettings && store.settingsPage == page)
        let controller = NSHostingController(rootView: ContentView(store: store).frame(width: 900, height: 600))
        let size = controller.sizeThatFits(in: CGSize(width: 900, height: 600))
        #expect(size.width <= 901 && size.height <= 601)
        #expect(store.selectedThreadID == thread.id && store.selectedThread?.draft == "Unsent native chat")
        store.showChat()
        #expect(!store.showingSettings && store.selectedThreadID == thread.id)
    }
    await store.shutdown()
}
