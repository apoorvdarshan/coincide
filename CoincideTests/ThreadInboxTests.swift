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
}
