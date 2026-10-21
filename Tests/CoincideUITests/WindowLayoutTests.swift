import AppKit
import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

@Test func initialMainWindowFitsTheSelectedDisplayWithoutShrinkingLargeDisplayDefaults() {
    #expect(MainWindowSizing.size(fitting: CGSize(width: 1024, height: 674)) == CGSize(width: 1024, height: 674))
    #expect(MainWindowSizing.size(fitting: CGSize(width: 900, height: 1200)) == CGSize(width: 900, height: 820))
    #expect(MainWindowSizing.size(fitting: CGSize(width: 2560, height: 1400)) == CGSize(width: 1280, height: 820))
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
