import Foundation
import Testing
@testable import CoincideKit

private func scheduleDate(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }

@Suite struct TaskRecurrenceTests {
    @Test func dailyUsesTheNamedZoneAcrossBothDaylightSavingTransitions() {
        let recurrence = TaskRecurrence(kind: .daily, timeZoneID: "America/New_York", hour: 2, minute: 30)
        // The missing 02:30 runs at the next valid wall time, 03:00, rather than disappearing for a day.
        #expect(recurrence.next(after: scheduleDate("2026-03-08T05:00:00Z")) == scheduleDate("2026-03-08T07:00:00Z"))
        var repeated = recurrence; repeated.hour = 1
        let first = scheduleDate("2026-11-01T05:30:00Z")
        #expect(repeated.next(after: scheduleDate("2026-11-01T04:00:00Z")) == first)
        #expect(repeated.next(after: first) == scheduleDate("2026-11-02T06:30:00Z"))
        #expect(repeated.next(after: scheduleDate("2026-11-01T05:45:00Z")) == scheduleDate("2026-11-02T06:30:00Z"))
    }
    @Test func weeklyAndOneTimeDatesAreStrictlyInTheFuture() {
        let monday = TaskRecurrence(kind: .weekly, timeZoneID: "Asia/Kolkata", hour: 9, minute: 15, weekday: 2)
        #expect(monday.next(after: scheduleDate("2026-10-28T12:00:00Z")) == scheduleDate("2026-11-02T03:45:00Z"))
        let once = TaskRecurrence(kind: .once, date: scheduleDate("2026-10-29T12:00:00Z"))
        #expect(once.next(after: scheduleDate("2026-10-28T12:00:00Z")) == once.date)
        #expect(once.next(after: once.date) == nil)
        #expect(TaskRecurrence(timeZoneID: "not/a/zone").next(after: Date()) == nil)
    }
}

@MainActor @Suite(.serialized) struct TaskSchedulerTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-scheduler-" + UUID().uuidString)
    private let project = UUID()
    private func task(at date: Date, kind: TaskRecurrence.Kind = .daily) -> ScheduledTask {
        ScheduledTask(name: "Review", projectID: project, prompt: "Review today's changes",
            recurrence: TaskRecurrence(kind: kind, timeZoneID: "UTC", date: date.addingTimeInterval(3600), hour: 9), now: date)
    }

    @Test func consumesOccurrenceOnDiskBeforeLaunchAndNeverOverlaps() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = scheduleDate("2026-10-28T08:00:00Z")
        let store = ScheduledTaskStore(directory: directory)
        let value = task(at: now); try store.save(value)
        var runs: [UUID] = []
        let scheduler = TaskScheduler(store: store, now: { now }, makeThread: { _ in UUID() }, startThread: { id, prompt in
            let persisted = ScheduledTaskStore(directory: directory).task(value.id)
            #expect(persisted?.activeThreadID == id)
            #expect(persisted?.lastFiredOccurrence == now)
            #expect(prompt == value.prompt)
            runs.append(id)
        })
        now = scheduleDate("2026-10-28T09:00:00Z")
        scheduler.tick(); scheduler.tick()
        #expect(runs.count == 1)
        #expect(throws: ScheduleError.self) { try scheduler.runNow(value.id) }
        now = scheduleDate("2026-10-29T10:00:00Z")
        scheduler.tick()
        #expect(runs.count == 1)
        scheduler.finished(threadID: runs[0], outcome: .completed)
        #expect(store.task(value.id)?.nextRunAt == scheduleDate("2026-10-30T09:00:00Z"))
        scheduler.tick()
        #expect(runs.count == 1)
    }

    @Test func relaunchAndWakeSkipBacklogsAndRecoverInterruptedRuns() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = scheduleDate("2026-10-28T08:00:00Z")
        let store = ScheduledTaskStore(directory: directory)
        var running = task(at: now)
        running.activeThreadID = UUID(); running.lastThreadID = running.activeThreadID
        running.lastFiredOccurrence = now; running.lastRunAt = now
        try store.save(running)
        let oneTime = task(at: now, kind: .once); try store.save(oneTime)
        var count = 0
        let scheduler = TaskScheduler(store: store, now: { now }, makeThread: { _ in UUID() }, startThread: { _, _ in count += 1 })
        now = scheduleDate("2026-10-29T11:00:00Z")
        scheduler.resume(afterRelaunch: true); scheduler.tick()
        #expect(count == 0)
        #expect(store.task(running.id)?.activeThreadID == nil)
        #expect(store.task(running.id)?.lastOutcome == .interrupted)
        #expect(store.task(running.id)?.nextRunAt == scheduleDate("2026-10-30T09:00:00Z"))
        #expect(store.task(oneTime.id)?.lastOutcome == .missed)
        #expect(store.task(oneTime.id)?.nextRunAt == nil)
        try scheduler.runNow(running.id)
        let active = store.task(running.id)?.activeThreadID
        now = scheduleDate("2026-10-31T11:00:00Z")
        scheduler.resume(afterRelaunch: false)
        #expect(store.task(running.id)?.activeThreadID == active)
        #expect(store.task(running.id)?.nextRunAt == scheduleDate("2026-11-01T09:00:00Z"))
        #expect(count == 1)
    }

    @Test func pausedTaskDoesNotRunUntilExplicitlyRequestedAndOnceIsConsumed() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = scheduleDate("2026-10-28T08:00:00Z")
        let store = ScheduledTaskStore(directory: directory)
        var value = task(at: now, kind: .once); value.isPaused = true; try store.save(value)
        var count = 0
        let scheduler = TaskScheduler(store: store, now: { now }, makeThread: { _ in UUID() }, startThread: { _, _ in count += 1 })
        try scheduler.runNow(value.id)
        #expect(count == 1)
        #expect(store.task(value.id)?.isPaused == true)
        #expect(store.task(value.id)?.nextRunAt == nil)
        scheduler.finished(threadID: try #require(store.task(value.id)?.activeThreadID), outcome: .completed)
        now = scheduleDate("2026-10-29T10:00:00Z")
        scheduler.tick()
        #expect(count == 1)
    }

    @Test func editingAStaleCopyCannotEraseAnActiveRunOrItsHistory() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = scheduleDate("2026-10-28T08:00:00Z")
        let store = ScheduledTaskStore(directory: directory)
        var value = task(at: now); try store.save(value)
        let scheduler = TaskScheduler(store: store, now: { now }, makeThread: { _ in UUID() }, startThread: { _, _ in })
        try scheduler.runNow(value.id)
        let active = store.task(value.id)?.activeThreadID
        value.name = "Renamed"
        try scheduler.save(value)
        #expect(store.task(value.id)?.activeThreadID == active)
        #expect(store.task(value.id)?.lastRunAt == now)
        #expect(store.task(value.id)?.name == "Renamed")
    }

    @Test func invalidConfigurationPausesInsteadOfRetryingAndCorruptDataIsPreserved() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = scheduleDate("2026-10-28T08:00:00Z")
        let store = ScheduledTaskStore(directory: directory)
        let value = task(at: now); try store.save(value)
        var attempts = 0
        let scheduler = TaskScheduler(store: store, now: { now }, makeThread: { _ in attempts += 1; throw ScheduleError.missingProject }, startThread: { _, _ in Issue.record("Must not launch") })
        now = scheduleDate("2026-10-28T09:00:00Z")
        scheduler.tick(); scheduler.tick()
        #expect(attempts == 1)
        #expect(store.task(value.id)?.lastOutcome == .failed)
        #expect(store.task(value.id)?.isPaused == true)
        let file = directory.appendingPathComponent("scheduled-tasks.json")
        try Data("unreadable schedule data".utf8).write(to: file)
        let reopened = ScheduledTaskStore(directory: directory)
        #expect(reopened.loadError != nil)
        #expect(throws: ScheduleError.self) { try reopened.save(value) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "unreadable schedule data")
    }

    @Test func pendingProviderResumeSkipsOverlappingSlotsInsteadOfDelayingThem() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = scheduleDate("2026-10-28T09:00:00Z")
        let store = ScheduledTaskStore(directory: directory)
        let value = task(at: now.addingTimeInterval(-3600)); try store.save(value)
        var occupied = true, count = 0
        let scheduler = TaskScheduler(store: store, now: { now }, canStart: { _ in !occupied },
            makeThread: { _ in UUID() }, startThread: { _, _ in count += 1 })
        scheduler.tick()
        #expect(count == 0)
        #expect(throws: ScheduleError.self) { try scheduler.runNow(value.id) }
        occupied = false
        scheduler.tick()
        #expect(count == 0)
        #expect(store.task(value.id)?.nextRunAt == scheduleDate("2026-10-29T09:00:00Z"))
        now = scheduleDate("2026-10-29T09:00:00Z")
        scheduler.tick()
        #expect(count == 1)
    }

    @Test func persistedConsumedOccurrenceCannotBeDispatchedAgain() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = scheduleDate("2026-10-28T09:00:00Z")
        let store = ScheduledTaskStore(directory: directory)
        var value = task(at: now.addingTimeInterval(-3600))
        value.lastFiredOccurrence = now
        try store.save(value)
        let scheduler = TaskScheduler(store: store, now: { now }, makeThread: { _ in Issue.record("Already consumed"); return UUID() }, startThread: { _, _ in })
        scheduler.tick()
        #expect(store.task(value.id)?.nextRunAt == scheduleDate("2026-10-29T09:00:00Z"))
    }
}
