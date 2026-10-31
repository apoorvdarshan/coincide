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
