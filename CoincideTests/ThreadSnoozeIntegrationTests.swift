import AppKit
import Testing

@testable import Coincide
@testable import CoincideKit

@MainActor
@Suite(.serialized)
struct ThreadSnoozeIntegrationTests {
    @Test func wakingAnOverdueBatchUpdatesEachThreadOnceAndKeepsTheNextTimer() async throws {
        let folder = TemporaryDirectory("snooze-batch")
        let store = AppStore(directory: folder.url)
        let project = store.addProject(at: folder.url)
        let overdue = (0..<12).map { _ in store.createThread(in: project.id).id }
        for id in overdue {
            store.updateThread(id) { $0.snoozedUntil = Date().addingTimeInterval(-60) }
        }
        let next = store.createThread(in: project.id).id
        store.updateThread(next) { $0.snoozedUntil = Date().addingTimeInterval(0.2) }
        var wakes: [UUID: Int] = [:]
        let token = store.observe {
            if case .thread(let id) = $0 { wakes[id, default: 0] += 1 }
        }
        let snooze = ThreadSnooze(store: store)
        snooze.start()
        snooze.start()
        #expect(overdue.allSatisfy { store.summary($0)?.snoozedUntil == nil && wakes[$0] == 1 })
        #expect(store.summary(next)?.snoozedUntil != nil)
        let deadline = Date().addingTimeInterval(8)
        while store.summary(next)?.snoozedUntil != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.summary(next)?.snoozedUntil == nil)
        #expect(wakes[next] == 1)
        withExtendedLifetime((token, snooze)) {}
    }

    @Test func snoozeSurvivesRestartAndIndexRebuildingWithoutLoadingTheTranscript() throws {
        let folder = TemporaryDirectory("snooze-persistence")
        let store = AppStore(directory: folder.url)
        let project = store.addProject(at: folder.url)
        let id = store.createThread(in: project.id).id
        let until = Date(timeIntervalSince1970: 2_000_000_000)
        let snooze = ThreadSnooze(store: store)
        snooze.snooze(id, until: until)
        store.flush()

        let indexed = AppStore(directory: folder.url)
        #expect(indexed.summary(id)?.snoozedUntil == until)
        #expect(indexed.transcriptReads == 0)
        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("thread-index.json"))
        let rebuilt = AppStore(directory: folder.url)
        #expect(rebuilt.summary(id)?.snoozedUntil == until)
        #expect(rebuilt.transcriptReads == 0)
        #expect(rebuilt.thread(id)?.snoozedUntil == until)
        ThreadSnooze(store: rebuilt).unsnooze(id)
        rebuilt.flush()
        #expect(AppStore(directory: folder.url).summary(id)?.snoozedUntil == nil)
    }

    @Test func snoozingAndUnsnoozingImmediatelyUpdateTheSidebar() throws {
        let folder = TemporaryDirectory("snooze-sidebar")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        let previous = UIState.shared.values.showsSnoozedThreads
        UIState.shared.update { $0.showsSnoozedThreads = false }
        defer {
            store.removeProject(project.id)
            UIState.shared.update { $0.showsSnoozedThreads = previous }
        }
        let id = store.createThread(in: project.id).id
        let sidebar = SidebarViewController()
        _ = sidebar.view
        #expect(sidebar.visibleThreadIDs.contains(id))
        let snooze = ThreadSnooze(store: store)
        snooze.snooze(id, until: Date().addingTimeInterval(600))
        #expect(!sidebar.visibleThreadIDs.contains(id))
        snooze.unsnooze(id)
        #expect(sidebar.visibleThreadIDs.contains(id))

        // Passive sidebar selection must not cancel a saved snooze during window restoration or handoff.
        snooze.snooze(id, until: Date().addingTimeInterval(600))
        sidebar.select(threadID: id)
        #expect(!sidebar.visibleThreadIDs.contains(id))
        #expect(store.summary(id)?.snoozedUntil != nil)
    }

    @Test func windowRestorationPreservesSnoozeAndAnExplicitOpenCancelsIt() {
        let folder = TemporaryDirectory("snooze-restoration")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        let previousSelection = UIState.shared.values.selectedThreadID
        let id = store.createThread(in: project.id).id
        let until = Date().addingTimeInterval(600)
        ThreadSnooze.shared.snooze(id, until: until)
        UIState.shared.update { $0.selectedThreadID = id }
        let controller = MainWindowController()
        defer {
            controller.window?.close()
            store.removeProject(project.id)
            UIState.shared.update { $0.selectedThreadID = previousSelection }
        }
        #expect(controller.selectedThreadID != id)
        #expect(store.summary(id)?.snoozedUntil == until)
        controller.open(id)
        #expect(controller.selectedThreadID == id)
        #expect(store.summary(id)?.snoozedUntil == nil)
        #expect(controller.sidebar.visibleThreadIDs.contains(id))
    }

    @Test func waitingInputRevealsASnoozedThreadAndAnsweringHidesItAgain() {
        let folder = TemporaryDirectory("snooze-attention")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        let previous = UIState.shared.values.showsSnoozedThreads
        UIState.shared.update { $0.showsSnoozedThreads = false }
        defer {
            store.removeProject(project.id)
            UIState.shared.update { $0.showsSnoozedThreads = previous }
        }
        ThreadActivity.shared.start()
        let id = store.createThread(in: project.id).id
        let sidebar = SidebarViewController()
        _ = sidebar.view
        ThreadSnooze.shared.snooze(id, until: Date().addingTimeInterval(600))
        #expect(!sidebar.visibleThreadIDs.contains(id))
        for kind: TranscriptItem.Kind in [.approval, .question] {
            let item = store.append(TranscriptItem(kind: kind, status: .waiting), to: id)
            #expect(sidebar.visibleThreadIDs.contains(id))
            store.updateItem(item, in: id) { $0.status = .completed }
            #expect(!sidebar.visibleThreadIDs.contains(id))
        }
    }
}
