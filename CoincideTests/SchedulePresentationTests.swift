import AppKit
import CoincideKit
import Testing

@testable import Coincide

@MainActor struct SchedulePresentationTests {
    private let base = ISO8601DateFormatter().date(from: "2026-10-28T09:00:00Z")!

    @Test func theNextRunIsSaidAsShortlyAsItCanBe() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        let today = now.addingTimeInterval(3600)
        #expect(SchedulePresentation.compactTime(today, now: now, calendar: calendar) == today.formatted(date: .omitted, time: .shortened))
        let soon = calendar.date(byAdding: .day, value: 2, to: today)!
        #expect(SchedulePresentation.compactTime(soon, now: now, calendar: calendar).hasSuffix(soon.formatted(date: .omitted, time: .shortened)))
        let later = calendar.date(byAdding: .day, value: 20, to: today)!
        #expect(!SchedulePresentation.compactTime(later, now: now, calendar: calendar).contains(later.formatted(date: .omitted, time: .shortened)))
    }

    @Test func statusesSayWhyASchedulesWontRun() {
        var task = ScheduledTask(name: "N", projectID: UUID(), prompt: "P", recurrence: TaskRecurrence(), threadID: UUID(), now: base)
        #expect(SchedulePresentation.status(task, isRunning: false) == nil)
        task.awaitingApproval = true
        #expect(SchedulePresentation.status(task, isRunning: false)?.label == "Needs approval")
        task.awaitingApproval = nil
        task.isPaused = true; task.pauseReason = .threadArchived
        #expect(SchedulePresentation.status(task, isRunning: false)?.label == "Thread archived")
        #expect(SchedulePresentation.note(task)?.contains("unarchive") == true)
        task.isPaused = false; task.pauseReason = nil; task.pendingDelivery = base
        #expect(SchedulePresentation.status(task, isRunning: false)?.label == "Waiting for thread")
        #expect(!ScheduleFilter.paused.includes(task) && ScheduleFilter.active.includes(task))
        // This Thread is the open thread's schedules only.
        #expect(ScheduleFilter.thisThread.includes(task, threadID: task.threadID))
        #expect(!ScheduleFilter.thisThread.includes(task, threadID: UUID()))
        #expect(!ScheduleFilter.thisThread.includes(task))
    }

    @Test func groupsAreBotsThreadsAndProjectsSoonestFirst() {
        let bot = UUID(), botThread = UUID(), thread = UUID(), project = UUID()
        func task(_ name: String, thread: UUID?, hour: Int) -> ScheduledTask {
            ScheduledTask(name: name, projectID: project, prompt: name,
                recurrence: TaskRecurrence(kind: .daily, timeZoneID: "UTC", hour: hour), threadID: thread, now: base)
        }
        let tasks = [
            task("Project", thread: nil, hour: 10), task("Late thread", thread: thread, hour: 23),
            task("Bot", thread: botThread, hour: 12), task("Early thread", thread: thread, hour: 11),
        ]
        let groups = SchedulePresentation.groups(
            tasks, botOf: { $0 == botThread ? bot : nil }, title: { owner in ("\(owner)", nil) })
        #expect(groups.map(\.owner) == [.project(project), .thread(thread), .bot(bot)])
        #expect(groups[1].tasks.map(\.name) == ["Early thread", "Late thread"])
        let filtered = SchedulePresentation.groups(
            tasks, botOf: { $0 == botThread ? bot : nil }, title: { _ in ("", nil) },
            matches: { SchedulePresentation.matches($0, query: "early", place: "") })
        #expect(filtered.flatMap(\.tasks).map(\.name) == ["Early thread"])
    }
}

/// The Scheduled panel opens on the open thread's schedules (This Thread) when it has some, follows the window to other
/// threads while it shows them, and otherwise opens on the filter the user last chose, which This Thread never replaces.
/// Its own store and service, and no window.
@MainActor @Suite(.serialized) struct SchedulesPanelFilterTests {
    @Test func thePanelOpensOnTheThreadsSchedules() throws {
        let key = "ScheduleFilter"
        let savedFilter = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(savedFilter, forKey: key) }
        UserDefaults.standard.set(ScheduleFilter.paused.rawValue, forKey: key)
        let directory = TemporaryDirectory("schedules-panel-filter")
        let store = AppStore(directory: directory.url)
        let service = ScheduledTasks(store: store)
        let project = store.addProject(at: directory.url)
        let first = store.createThread(in: project.id).id, second = store.createThread(in: project.id).id
        let empty = store.createThread(in: project.id).id
        func task(_ name: String, thread: UUID?, paused: Bool = false) throws -> ScheduledTask {
            let task = ScheduledTask(
                name: name, projectID: project.id, prompt: name, recurrence: TaskRecurrence(hour: 9), isPaused: paused, threadID: thread)
            try service.scheduler.save(task)
            return task
        }
        let inFirst = try task("First", thread: first), inSecond = try task("Second", thread: second, paused: true)
        let eachRun = try task("Each run", thread: nil, paused: true)
        defer { store.flush() }

        let panel = SchedulesPanelController(service: service, store: store)
        panel.threadID = first
        panel.prepareToShow()
        _ = panel.view
        #expect(panel.filter == .thisThread)
        #expect(panel.shownTasks.map(\.id) == [inFirst.id])
        // Moving to another thread with the panel open lists that thread's.
        panel.threadID = second
        #expect(panel.shownTasks.map(\.id) == [inSecond.id])
        panel.threadID = empty
        #expect(panel.shownTasks.isEmpty)
        // This Thread isn't remembered: the saved filter is still the user's.
        #expect(UserDefaults.standard.string(forKey: key) == ScheduleFilter.paused.rawValue)

        // Opened from a thread without schedules, or with none open, it shows the filter the user chose.
        panel.prepareToShow()
        #expect(panel.filter == .paused)
        #expect(Set(panel.shownTasks.map(\.id)) == [inSecond.id, eachRun.id])
        panel.threadID = nil
        UserDefaults.standard.set(ScheduleFilter.all.rawValue, forKey: key)
        panel.prepareToShow()
        #expect(panel.filter == .all)
        #expect(Set(panel.shownTasks.map(\.id)) == [inFirst.id, inSecond.id, eachRun.id])
    }
}
