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
    let hosting = NSHostingView(rootView: ChatView(store: store, threadID: thread.id))
    hosting.sizingOptions = [.minSize]
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 620, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    // The hosted view's minimum width must fit next to a 268-point sidebar on a 900-point window.
    #expect(window.contentMinSize.width <= 632)
    window.close()
    await store.shutdown()
}
