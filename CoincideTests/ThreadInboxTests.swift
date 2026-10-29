import AppKit
import Testing

@testable import Coincide
@testable import CoincideKit

@MainActor
struct ThreadInboxTests {
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
