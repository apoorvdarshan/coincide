import AppKit
import Testing

@testable import Coincide
@testable import CoincideKit

@MainActor
struct ThreadInboxTests {
    /// Includes NSTableView's mouse-tracking loop; calling the action helper alone
    /// misses the focus it restores after dispatching an action.
    private func click(_ outline: NSOutlineView, row: Int, count: Int = 1, at time: TimeInterval,
                       onTitle: Bool = true, modifiers: NSEvent.ModifierFlags = []) throws {
        let window = try #require(outline.window)
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        let field = try #require(cell.textField)
        let title = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: outline)
        let point = onTitle ? title : outline.convert(NSPoint(x: field.frame.minX - 3, y: field.frame.midY), from: cell)
        let location = outline.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                pressure: type == .leftMouseDown ? 1 : 0))
        }
        window.makeFirstResponder(outline)
        window.postEvent(try event(.leftMouseUp), atStart: true)
        outline.mouseDown(with: try event(.leftMouseDown))
    }

    @Test func nativeThreadClicksFocusAfterTrackingAndOnlyDeliberateTitleDoubleClicksRename() throws {
        let folder = TemporaryDirectory("inbox-native-click")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        defer { store.removeProject(project.id) }
        let first = store.createThread(in: project.id).id
        let second = store.createThread(in: project.id).id
        let sidebar = SidebarViewController()
        let outline = try #require(findOutline(in: sidebar.view))
        let composer = ComposerViewController()
        let window = TerminalFocus.KeyWindow(size: NSSize(width: 1000, height: 700))
        defer { window.close() }
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
        composer.view.frame = NSRect(x: 300, y: 0, width: 700, height: 150)
        window.contentView?.addSubview(sidebar.view)
        window.contentView?.addSubview(composer.view)
        sidebar.select(threadID: first)
        composer.threadID = first
        sidebar.onSelectThread = { composer.threadID = $0 }
        sidebar.view.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
        func row(_ id: UUID) throws -> Int {
            try #require((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.threadID == id })
        }
        func field(_ id: UUID) throws -> NSTextField {
            try #require((outline.view(atColumn: 0, row: row(id), makeIfNecessary: true) as? NSTableCellView)?.textField)
        }
        let start = ProcessInfo.processInfo.systemUptime
        try click(outline, row: row(second), at: start)
        #expect(composer.threadID == second)
        #expect(window.firstResponder === composer.textView)
        window.firstResponder?.keyDown(with: TerminalFocus.key("q", keyCode: 12, in: window))
        #expect(composer.textView.string == "q")
        // Opening a thread and immediately clicking again is navigation, not rename.
        try click(outline, row: row(second), count: 2, at: start + 0.01)
        #expect(try !field(second).isEditable)
        #expect(window.firstResponder === composer.textView)
        // Rapid clicks across two different thread identities must not become rename.
        try click(outline, row: row(first), at: start + 1)
        try click(outline, row: row(second), count: 2, at: start + 1.01)
        #expect(try !field(second).isEditable)
        #expect(window.firstResponder === composer.textView)
        // The icon/margin remains navigation even on the selected thread.
        try click(outline, row: row(second), at: start + 2, onTitle: false)
        try click(outline, row: row(second), count: 2, at: start + 2.01, onTitle: false)
        #expect(try !field(second).isEditable)
        // A deliberate double click on the already-selected title still renames.
        try click(outline, row: row(second), at: start + 3)
        try click(outline, row: row(second), count: 2, at: start + 3.01)
        let title = try field(second)
        #expect(title.isEditable && title.isSelectable)
        #expect(title.currentEditor() === window.firstResponder)
        window.makeFirstResponder(composer.textView)
        #expect(!title.isEditable)
        #expect(!window.isVisible)
    }

    @Test func clickingAThreadFocusesItsComposerAndAcceptsTypingImmediately() throws {
        let folder = TemporaryDirectory("inbox-click-focus")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        defer { store.removeProject(project.id) }
        let first = store.createThread(in: project.id).id
        let second = store.createThread(in: project.id).id
        let sidebar = SidebarViewController()
        let outline = try #require(findOutline(in: sidebar.view))
        let composer = ComposerViewController()
        let window = TerminalFocus.KeyWindow(size: NSSize(width: 1000, height: 700))
        defer { window.close() }
        window.contentView?.addSubview(sidebar.view)
        window.contentView?.addSubview(composer.view)
        sidebar.select(threadID: first)
        composer.threadID = first
        sidebar.onSelectThread = { composer.threadID = $0 }
        let row = try #require((0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? SidebarNode)?.threadID == second
        })
        window.makeFirstResponder(outline)
        outline.selectRowIndexes([row], byExtendingSelection: false)
        // Keyboard selection keeps the outline usable for further navigation.
        #expect(window.firstResponder === outline)
        #expect(composer.threadID == second)
        sidebar.focusComposerAfterClick(at: row, modifiers: [])
        #expect(window.firstResponder === composer.textView)
        window.firstResponder?.keyDown(with: TerminalFocus.key("q", keyCode: 12, in: window))
        #expect(composer.textView.string == "q")

        // Clicking the already-open conversation must work too, without a selection-change notification.
        window.makeFirstResponder(outline)
        sidebar.focusComposerAfterClick(at: row, modifiers: [])
        #expect(window.firstResponder === composer.textView)
        #expect(composer.textView.string == "q")

        for modifier in [NSEvent.ModifierFlags.command, .shift] {
            window.makeFirstResponder(outline)
            sidebar.focusComposerAfterClick(at: row, modifiers: modifier)
            #expect(window.firstResponder === outline)
        }
        outline.selectRowIndexes(IndexSet((0..<outline.numberOfRows).filter {
            guard let id = (outline.item(atRow: $0) as? SidebarNode)?.threadID else { return false }
            return [first, second].contains(id)
        }), byExtendingSelection: false)
        sidebar.focusComposerAfterClick(at: row, modifiers: [])
        #expect(window.firstResponder === outline)
    }

    @Test func archivingSeveralThreadsHandsOffOnlyToTheSurvivingNeighbour() async {
        let folder = TemporaryDirectory("inbox-neighbour")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        defer { store.removeProject(project.id) }
        let ids = (0..<3).map { _ in store.createThread(in: project.id).id }
        let sidebar = SidebarViewController()
        _ = sidebar.view
        sidebar.select(threadID: ids[0])
        var opened: [UUID?] = []
        sidebar.onSelectThread = { opened.append($0) }
        ThreadInbox.shared.archive(Array(ids.prefix(2)), archived: true)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(opened == [ids[2]])
    }

    @Test func selectingSeveralThreadsDoesNotNavigateAndSurvivesListUpdates() throws {
        let folder = TemporaryDirectory("inbox-selection")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        defer { store.removeProject(project.id) }
        let ids = (0..<3).map { _ in store.createThread(in: project.id).id }
        let sidebar = SidebarViewController()
        let outline = try #require(findOutline(in: sidebar.view))
        sidebar.select(threadID: ids[0])
        var opened: [UUID?] = []
        sidebar.onSelectThread = { opened.append($0) }
        let rows = IndexSet((0..<outline.numberOfRows).filter { row in
            guard let id = (outline.item(atRow: row) as? SidebarNode)?.threadID else { return false }
            return ids.contains(id)
        })
        #expect(rows.count == 3)
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        #expect(opened.isEmpty)
        store.updateThread(ids[1]) { $0.title = "Renamed in the selection" }
        let selected = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarNode)?.threadID }
        #expect(Set(selected) == Set(ids))
    }

    private func findOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap { findOutline(in: $0) }.first
    }

    @Test func archiveAndDeletionUndoRedoKeepTheWholeSelection() throws {
        let folder = TemporaryDirectory("inbox-undo")
        let store = AppStore(directory: folder.url)
        let ui = UIState(directory: folder.url)
        let inbox = ThreadInbox(store: store, ui: ui)
        let project = store.addProject(at: folder.url)
        let ids = (0..<3).map { _ in store.createThread(in: project.id).id }
        try autoreleasepool {
        inbox.archive(ids, archived: true)
        #expect(ids.allSatisfy { store.summary($0)?.isArchived == true })
        inbox.undo()
        #expect(ids.allSatisfy { store.summary($0)?.isArchived == false })
        inbox.redo()
        #expect(ids.allSatisfy { store.summary($0)?.isArchived == true })
        try inbox.delete(ids)
        #expect(ids.allSatisfy { !store.hasThread($0) && store.canUndoDeletion(of: $0) })
        inbox.undo()
        #expect(ids.allSatisfy { store.summary($0)?.isArchived == true })
        inbox.redo()
        #expect(ids.allSatisfy { !store.hasThread($0) })
        inbox.undoManager.removeAllActions()
        }
        #expect(ids.allSatisfy { !store.canUndoDeletion(of: $0) })
    }

    /// With the sidebar's Undo bar gone, Edit › Undo (⌘Z) in the main window undoes the last inbox action wherever the
    /// focus is, unless the focused view has its own edit to undo; in the thread list it always does.
    @Test func undoInTheMainWindowReachesTheInboxWithoutABar() throws {
        let folder = TemporaryDirectory("inbox-window-undo")
        let store = AppStore(directory: folder.url)
        let ui = UIState(directory: folder.url)
        let inbox = ThreadInbox(store: store, ui: ui, isRunning: { _ in false }, endSessions: { _ in })
        let project = store.addProject(at: folder.url)
        let id = store.createThread(in: project.id).id
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.inbox = { inbox }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(text)
        window.makeFirstResponder(text)
        let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        #expect(!window.validateMenuItem(undo))
        inbox.archive([id], archived: true)
        #expect(store.summary(id)?.isArchived == true)
        #expect(window.validateMenuItem(undo))
        #expect(undo.title == inbox.undoManager.undoMenuItemTitle)
        window.undo(nil)
        #expect(store.summary(id)?.isArchived == false)
        #expect(window.validateMenuItem(redo))
        window.redo(nil)
        #expect(store.summary(id)?.isArchived == true)
        // The sidebar has no bar left, and keeps routing ⌘Z to the shared inbox itself.
        let sidebar = SidebarViewController()
        #expect(findButton(titled: "Undo", in: sidebar.view) == nil)
        inbox.undoManager.removeAllActions()
        window.close()
    }

    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { findButton(titled: title, in: $0) }.first
    }

    @Test func settledThreadsStaySettledAfterRelaunchButReturnForNewActivity() throws {
        let folder = TemporaryDirectory("inbox-settle")
        let store = AppStore(directory: folder.url)
        let ui = UIState(directory: folder.url)
        let inbox = ThreadInbox(store: store, ui: ui)
        let project = store.addProject(at: folder.url)
        let id = store.createThread(in: project.id).id
        inbox.settle([id], settled: true)
        #expect(inbox.isSettled(try #require(store.summary(id))))
        ui.flush()
        let reopened = ThreadInbox(store: store, ui: UIState(directory: folder.url))
        #expect(reopened.isSettled(try #require(store.summary(id))))
        inbox.undo()
        #expect(!inbox.isSettled(try #require(store.summary(id))))
        inbox.redo()
        #expect(inbox.isSettled(try #require(store.summary(id))))
        store.updateThread(id) { $0.updatedAt = Date().addingTimeInterval(1) }
        #expect(!inbox.isSettled(try #require(store.summary(id))))
    }

    @Test func archiveRedoSkipsNewlyRunningThreadsAndUndoKeepsTheRestOfTheBatch() {
        let folder = TemporaryDirectory("inbox-running-redo")
        let store = AppStore(directory: folder.url)
        var running: Set<UUID> = []
        let inbox = ThreadInbox(store: store, ui: UIState(directory: folder.url), isRunning: { running.contains($0) })
        let project = store.addProject(at: folder.url)
        let ids = (0..<2).map { _ in store.createThread(in: project.id).id }
        inbox.archive(ids, archived: true)
        inbox.undo()
        running.insert(ids[0])
        inbox.redo()
        #expect(store.summary(ids[0])?.isArchived == false)
        #expect(store.summary(ids[1])?.isArchived == true)
        inbox.undo()
        #expect(ids.allSatisfy { store.summary($0)?.isArchived == false })
        inbox.redo()
        #expect(store.summary(ids[0])?.isArchived == false)
        #expect(store.summary(ids[1])?.isArchived == true)
        inbox.undoManager.removeAllActions()
        store.flush()
    }
}
