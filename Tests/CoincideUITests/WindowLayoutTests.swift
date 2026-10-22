import AppKit
import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

@Test func initialMainWindowFitsTheSelectedDisplayWithoutShrinkingLargeDisplayDefaults() {
    #expect(MainWindowSizing.size(fitting: CGSize(width: 1024, height: 674)) == CGSize(width: 1024, height: 674))
    #expect(MainWindowSizing.size(fitting: CGSize(width: 900, height: 1200)) == CGSize(width: 900, height: 820))
    #expect(MainWindowSizing.size(fitting: CGSize(width: 2560, height: 1400)) == CGSize(width: 1280, height: 820))
    #expect(NativeInspectorSizing.size(fitting: ProposedViewSize(width: .infinity, height: .nan)) == .zero)
    #expect(NativeInspectorSizing.size(fitting: ProposedViewSize(width: 760, height: 600)) == CGSize(width: 760, height: 600))
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

@MainActor @Test func inspectorSizeConstraintsStayBoundedAsFilesLoadAndDirtyEditorContentChanges() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-inspector-layout-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("notes.txt")
    try Data("Saved inspector bytes\n".utf8).write(to: file)
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"))
    let project = WorkspaceProject(path: root.path)
    let thread = CodingThread(project: project)
    store.snapshot.projects = [project]; store.snapshot.threads = [thread]
    let files = try store.fileBrowser(path: root.path)
    let controller = NativeInspectorSplitController(detail: AnyView(Text("Conversation")),
        inspector: AnyView(WorkspaceFilesView(model: files, navigation: nil)))
    let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 760, height: 600),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = controller
    defer { window.close() }
    controller.setInspectorPresented(true)
    do {
        func checkBounds() {
            #expect(controller.detailHost.sizingOptions.isEmpty && controller.inspectorHost.sizingOptions.isEmpty)
            #expect(controller.detailHost.sceneBridgingOptions.isEmpty && controller.inspectorHost.sceneBridgingOptions.isEmpty)
            for host in [controller.detailHost, controller.inspectorHost] {
                #expect(host.view.intrinsicContentSize.width == NSView.noIntrinsicMetric)
                #expect(host.view.intrinsicContentSize.height == NSView.noIntrinsicMetric)
            }
            for width in [CGFloat(540), 760, 1200] {
                window.setContentSize(CGSize(width: width, height: 600)); controller.view.layoutSubtreeIfNeeded()
                let detail = controller.detailHost.view.frame, inspector = controller.inspectorHost.view.frame
                #expect(detail.minX >= 0 && detail.width >= 239)
                #expect(inspector.width >= 280 && inspector.width <= 600)
                #expect(inspector.minX >= detail.maxX && abs(inspector.maxX - controller.view.bounds.maxX) < 1)
                #expect(inspector.height == 600 && detail.height == 600)
            }
        }
        checkBounds(); await files.start(); checkBounds()
        #expect(await files.open("notes.txt"))
        files.setContents(String(repeating: "Unsaved wide editor content 😀 ", count: 200))
        checkBounds()
        let hostIdentity = ObjectIdentifier(controller.inspectorHost)
        controller.splitView.setPosition(controller.view.bounds.width - controller.splitView.dividerThickness - 500, ofDividerAt: 0)
        #expect(abs(controller.inspectorHost.view.frame.width - 500) < 1)
        controller.setInspectorPresented(false)
        #expect(controller.splitView.arrangedSubviews.count == 1)
        #expect(controller.detailHost.view.frame == controller.view.bounds)
        controller.update(detail: AnyView(Text("Updated conversation")), inspector: AnyView(WorkspaceFilesView(model: files, navigation: nil)))
        controller.setInspectorPresented(true); controller.view.layoutSubtreeIfNeeded()
        #expect(ObjectIdentifier(controller.inspectorHost) == hostIdentity)
        #expect(abs(controller.inspectorHost.view.frame.width - 500) < 1)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(files.isDirty && saved == "Saved inspector bytes\n")
        #expect(try store.fileBrowser(path: root.path) === files)
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}

private struct InspectorFocusField: NSViewRepresentable {
    let field: NSTextField
    func makeNSView(context: Context) -> NSTextField { field }
    func updateNSView(_ nsView: NSTextField, context: Context) { }
}

@MainActor @Test func nativeInspectorPreservesConversationFirstResponderWhenRootsUpdateOrInspectorCloses() async throws {
    _ = NSApplication.shared
    let conversation = NSTextField(string: "Unsent conversation"), inspector = NSTextField(string: "Inspector input")
    let detailRoot = AnyView(InspectorFocusField(field: conversation)), inspectorRoot = AnyView(InspectorFocusField(field: inspector))
    let controller = NativeInspectorSplitController(detail: detailRoot, inspector: inspectorRoot)
    let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 760, height: 600),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = controller
    defer { window.close() }
    controller.setInspectorPresented(true)
    controller.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)); controller.view.layoutSubtreeIfNeeded()
    #expect(controller.detailHost.parent === controller && controller.inspectorHost.parent === controller)
    #expect(window.makeFirstResponder(conversation))
    let responder = try #require(window.firstResponder)
    controller.update(detail: detailRoot, inspector: inspectorRoot)
    controller.view.layoutSubtreeIfNeeded(); await Task.yield()
    #expect(window.firstResponder === responder)
    controller.setInspectorPresented(false)
    #expect(window.firstResponder === responder)
    controller.setInspectorPresented(true)
    #expect(window.firstResponder === responder)
    #expect(conversation.stringValue == "Unsent conversation")
}
