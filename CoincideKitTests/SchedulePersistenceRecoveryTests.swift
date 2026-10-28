import Foundation
import Testing
@testable import CoincideKit

@MainActor @Suite(.serialized) struct SchedulePersistenceRecoveryTests {
    @Test func consumedOneTimeTaskStaysConsumedAcrossPauseResumeAndEditorChanges() throws {
        let fixture = try RecoveryFixture(kind: .once)
        defer { fixture.cleanUp() }
        try fixture.scheduler.runNow(fixture.task.id)
        fixture.scheduler.finished(threadID: try #require(fixture.runs.last), outcome: .completed)
        try fixture.scheduler.setPaused(fixture.task.id, true)
        try fixture.scheduler.setPaused(fixture.task.id, false)
        #expect(fixture.saved.nextRunAt == nil)
        try fixture.scheduler.setPaused(fixture.task.id, true)
        var edit = fixture.saved
        edit.isPaused = false; edit.name = "Renamed"
        // For a one-time task, changing the display zone does not select a new occurrence.
        edit.recurrence.timeZoneID = "Asia/Kolkata"
        try fixture.scheduler.save(edit)
        fixture.now = fixture.due
        fixture.scheduler.tick()
        #expect(fixture.runs.count == 1)
        #expect(fixture.saved.nextRunAt == nil)

        edit = fixture.saved
        edit.recurrence.date = fixture.now.addingTimeInterval(3600)
        try fixture.scheduler.save(edit)
        fixture.now = edit.recurrence.date
        fixture.scheduler.tick()
        #expect(fixture.runs.count == 2)
    }

    @Test func failedCompletionIsRetriedBeforeAnyFurtherDispatch() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.now = fixture.due; fixture.scheduler.tick()
        let restore = try fixture.blockWrites()
        fixture.scheduler.finished(threadID: try #require(fixture.runs.last), outcome: .completed)
        #expect(fixture.saved.activeThreadID != nil)
        fixture.now = fixture.due.addingTimeInterval(86_400)
        fixture.scheduler.tick()
        #expect(throws: ScheduleError.self) { try fixture.scheduler.runNow(fixture.task.id) }
        #expect(fixture.madeThreads == 1)
        try restore()
        fixture.scheduler.tick()
        #expect(fixture.saved.activeThreadID == nil)
        #expect(fixture.saved.lastOutcome == .completed)
        #expect(fixture.saved.lastFinishedAt == fixture.due)
        #expect(fixture.runs.count == 1)
        let reopened = ScheduledTaskStore(directory: fixture.directory)
        #expect(reopened.task(fixture.task.id)?.activeThreadID == nil)
        fixture.now = try #require(fixture.saved.nextRunAt)
        fixture.scheduler.tick()
        #expect(fixture.runs.count == 2)
    }

    @Test func failedWakeSaveNeverDispatchesTheMissedOneTimeOccurrence() throws {
        let fixture = try RecoveryFixture(kind: .once)
        defer { fixture.cleanUp() }
        let restore = try fixture.blockWrites()
        fixture.now = fixture.due.addingTimeInterval(86_400)
        fixture.scheduler.resume(afterRelaunch: true)
        fixture.scheduler.tick()
        #expect(fixture.runs.isEmpty)
        try restore()
        fixture.scheduler.tick()
        #expect(fixture.runs.isEmpty)
        #expect(fixture.saved.nextRunAt == nil)
        #expect(fixture.saved.lastOutcome == .missed)
        #expect(ScheduledTaskStore(directory: fixture.directory).task(fixture.task.id)?.lastOutcome == .missed)
    }

    @Test func failedOverlapSaveStillConsumesTheSlotWhenBackgroundWorkEnds() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let restore = try fixture.blockWrites()
        fixture.canStart = false; fixture.now = fixture.due
        fixture.scheduler.tick()
        fixture.canStart = true
        try restore()
        fixture.scheduler.tick()
        #expect(fixture.runs.isEmpty)
        fixture.now = try #require(fixture.saved.nextRunAt)
        fixture.scheduler.tick()
        #expect(fixture.runs.count == 1)
    }

    @Test func failedLaunchSaveNeverSubmitsAndRetriesItsPausedFailure() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let restore = try fixture.blockWrites()
        fixture.now = fixture.due
        fixture.scheduler.tick(); fixture.scheduler.tick()
        #expect(fixture.madeThreads == 1)
        #expect(fixture.runs.isEmpty)
        try restore()
        fixture.scheduler.tick()
        #expect(fixture.saved.isPaused && fixture.saved.lastOutcome == .failed)
        #expect(fixture.saved.activeThreadID == nil)
        #expect(fixture.madeThreads == 1 && fixture.runs.isEmpty)
    }

    @Test func retryDoesNotResurrectATaskDeletedAfterItsCompletionSaveFailed() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.now = fixture.due; fixture.scheduler.tick()
        let restore = try fixture.blockWrites()
        fixture.scheduler.finished(threadID: try #require(fixture.runs.last), outcome: .completed)
        try restore()
        try fixture.store.delete(fixture.task.id)
        fixture.scheduler.tick()
        #expect(fixture.store.tasks.isEmpty)
    }
}

@MainActor private final class RecoveryFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-schedule-recovery-\(UUID())")
    let due = ISO8601DateFormatter().date(from: "2026-10-28T09:00:00Z")!
    var now = ISO8601DateFormatter().date(from: "2026-10-28T08:00:00Z")!
    let store: ScheduledTaskStore
    let task: ScheduledTask
    var runs: [UUID] = []
    var madeThreads = 0
    var canStart = true
    var saved: ScheduledTask { store.task(task.id)! }
    lazy var scheduler = TaskScheduler(store: store, now: { [unowned self] in now },
        canStart: { [unowned self] _ in canStart }, makeThread: { [unowned self] _ in
            madeThreads += 1; return UUID()
        }, startThread: { [unowned self] id, _ in runs.append(id) })

    init(kind: TaskRecurrence.Kind = .daily) throws {
        store = ScheduledTaskStore(directory: directory)
        task = ScheduledTask(name: "Review", projectID: UUID(), prompt: "Review changes",
            recurrence: TaskRecurrence(kind: kind, timeZoneID: "UTC", date: due, hour: 9), now: now)
        try store.save(task)
    }

    func blockWrites() throws -> () throws -> Void {
        let file = directory.appendingPathComponent("scheduled-tasks.json")
        let data = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        return {
            try FileManager.default.removeItem(at: file)
            try data.write(to: file, options: .atomic)
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
