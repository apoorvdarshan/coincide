import Foundation
import Testing
@testable import CoincideKit

private func at(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }

// MARK: - Saved files

@MainActor @Suite struct ScheduledTaskCompatibilityTests {
    /// A file written before thread schedules, cron and the other kinds: every task keeps working as a project task.
    @Test func tasksSavedBeforeThreadSchedulesDecodeUnchanged() throws {
        let project = UUID(), id = UUID()
        let json = """
            {"version":1,"tasks":[{"id":"\(id.uuidString)","name":"Review","projectID":"\(project.uuidString)",
            "prompt":"Review today's changes","isPaused":false,"nextRunAt":"2026-10-29T09:00:00Z",
            "lastOutcome":"completed","lastThreadID":"\(UUID().uuidString)",
            "recurrence":{"kind":"weekly","timeZoneID":"UTC","date":"2026-10-28T08:00:00Z","hour":9,"minute":0,"weekday":5}}]}
            """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-schedule-compat-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("scheduled-tasks.json"))
        let store = ScheduledTaskStore(directory: directory)
        #expect(store.loadError == nil)
        let task = try #require(store.task(id))
        #expect(task.threadID == nil && !task.isThreadSchedule)
        #expect(task.isActive && !task.isAwaitingApproval && task.proposal == nil && task.pauseReason == nil)
        #expect(task.recurrence.kind == .weekly && task.recurrence.weekdays == nil && task.recurrence.cron == nil)
        #expect(task.lastOutcome == .completed)
        #expect(task.recurrence.next(after: at("2026-10-28T08:00:00Z")) == at("2026-10-29T09:00:00Z"))
        // Saving it back writes none of the new fields.
        try store.save(task)
        let written = try String(contentsOf: directory.appendingPathComponent("scheduled-tasks.json"), encoding: .utf8)
        for key in ["threadID", "awaitingApproval", "proposal", "pauseReason", "pendingDelivery", "cron", "intervalMinutes"] {
            #expect(!written.contains("\"\(key)\""), "\(key) was written for an old task")
        }
    }

    /// A field this version can't read leaves only that field empty, not the whole file.
    @Test func unreadableNewFieldsAreLeftEmpty() throws {
        let json = """
            {"id":"\(UUID().uuidString)","name":"N","projectID":"\(UUID().uuidString)","prompt":"P","isPaused":false,
            "recurrence":{"kind":"daily","timeZoneID":"UTC","date":"2026-10-28T08:00:00Z","hour":9,"minute":0,"weekday":2},
            "pauseReason":"somethingNewer","threadID":"not a uuid","proposal":42}
            """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(ScheduledTask.self, from: Data(json.utf8))
        #expect(task.pauseReason == nil && task.threadID == nil && task.proposal == nil)
    }

    /// The transcript's schedule mark is written only on the messages a schedule sent, and old items read as before.
    @Test func scheduleMarkIsOptionalOnTranscriptItems() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let plain = TranscriptItem(kind: .user, text: "Hi")
        #expect(!String(decoding: try encoder.encode(plain), as: UTF8.self).contains("schedule"))
        let mark = TranscriptItem.ScheduleMark(id: UUID(), name: "Standup")
        let marked = TranscriptItem(kind: .user, text: "Hi", schedule: mark)
        #expect(try decoder.decode(TranscriptItem.self, from: encoder.encode(marked)).schedule == mark)
        let old = #"{"id":"\#(UUID().uuidString)","kind":"user","text":"Hi","createdAt":0}"#
        #expect(try decoder.decode(TranscriptItem.self, from: Data(old.utf8)).schedule == nil)
        let damaged = #"{"id":"\#(UUID().uuidString)","kind":"user","text":"Hi","schedule":"oops"}"#
        #expect(try decoder.decode(TranscriptItem.self, from: Data(damaged.utf8)).schedule == nil)
    }
}

// MARK: - Recurrence

@Suite struct RecurrenceKindTests {
    @Test func weekdaysAndSelectedDaysSkipTheOtherDays() {
        // 2026-10-30 is a Friday.
        let weekdays = TaskRecurrence(kind: .weekdays, timeZoneID: "UTC", hour: 9, minute: 0)
        #expect(weekdays.next(after: at("2026-10-30T10:00:00Z")) == at("2026-11-02T09:00:00Z"))
        #expect(weekdays.next(after: at("2026-10-30T08:00:00Z")) == at("2026-10-30T09:00:00Z"))
        let days = TaskRecurrence(kind: .days, timeZoneID: "UTC", hour: 18, minute: 30, weekdays: [1, 4])
        #expect(days.upcoming(after: at("2026-10-30T00:00:00Z"), count: 3)
            == [at("2026-11-01T18:30:00Z"), at("2026-11-04T18:30:00Z"), at("2026-11-08T18:30:00Z")])
        #expect(TaskRecurrence(kind: .days, timeZoneID: "UTC", weekdays: []).validationError != nil)
        #expect(TaskRecurrence(kind: .days, timeZoneID: "UTC", weekdays: [9]).validationError != nil)
    }

    @Test func selectedDaysKeepTheirWallTimeAcrossDaylightSaving() {
        let days = TaskRecurrence(kind: .days, timeZoneID: "America/New_York", hour: 9, minute: 0, weekdays: [1, 2])
        // Sunday 1 November 2026 is when New York falls back: 9:00 is 14:00 UTC that day, 13:00 the week before.
        #expect(days.next(after: at("2026-10-27T00:00:00Z")) == at("2026-11-01T14:00:00Z"))
        #expect(days.next(after: at("2026-10-25T00:00:00Z")) == at("2026-10-25T13:00:00Z"))
    }

    @Test func intervalsCountWholeStepsFromTheirFirstRunAndNeverRunTooOften() {
        let start = at("2026-10-28T09:00:00Z")
        let every = TaskRecurrence(kind: .interval, timeZoneID: "UTC", date: start, intervalMinutes: 90)
        #expect(every.next(after: at("2026-10-28T08:00:00Z")) == start)
        #expect(every.next(after: start) == at("2026-10-28T10:30:00Z"))
        // However late the Mac wakes, the runs stay on the same grid.
        #expect(every.next(after: at("2026-10-29T13:01:00Z")) == at("2026-10-29T13:30:00Z"))
        // Elapsed time, so a daylight-saving change doesn't move it: New York's fall back is 2026-11-01T06:00Z.
        let hourly = TaskRecurrence(kind: .interval, timeZoneID: "America/New_York", date: at("2026-11-01T05:00:00Z"), intervalMinutes: 60)
        #expect(hourly.upcoming(after: at("2026-11-01T05:00:00Z"), count: 2) == [at("2026-11-01T06:00:00Z"), at("2026-11-01T07:00:00Z")])
        #expect(TaskRecurrence(kind: .interval, intervalMinutes: 4).validationError != nil)
        #expect(TaskRecurrence(kind: .interval, intervalMinutes: 5).validationError == nil)
        #expect(TaskRecurrence(kind: .interval, intervalMinutes: nil).validationError != nil)
        #expect(TaskRecurrence(kind: .interval, intervalMinutes: 31 * 24 * 60 + 1).validationError != nil)
    }

    @Test func newKindsCompareByWhatTheyRun() {
        let a = TaskRecurrence(kind: .days, timeZoneID: "UTC", weekdays: [2, 4])
        var b = a; b.weekdays = [4, 2]
        #expect(a == b)
        b.weekdays = [2]
        #expect(a != b)
        let cron = TaskRecurrence(kind: .cron, timeZoneID: "UTC", cron: "0 9 * * 1-5")
        var other = cron; other.hour = 3
        #expect(cron == other)
        other.cron = "0 10 * * 1-5"
        #expect(cron != other)
    }
}

@Suite struct CronExpressionTests {
    @Test func readsNumbersRangesListsStepsAndNames() throws {
        let weekdays = try CronExpression("0 9 * * mon-fri")
        #expect(weekdays.minutes == [0] && weekdays.hours == [9] && weekdays.daysOfWeek == [1, 2, 3, 4, 5])
        let steps = try CronExpression("*/15 9-17/4 1,15 JAN,jul *")
        #expect(steps.minutes == [0, 15, 30, 45] && steps.hours == [9, 13, 17])
        #expect(steps.daysOfMonth == [1, 15] && steps.months == [1, 7])
        #expect(try CronExpression("30 6 * * 7").daysOfWeek == [0])
        #expect(try CronExpression("10/20 * * * *").minutes == [10, 30, 50])
        #expect(try CronExpression("@daily") == CronExpression("0 0 * * *"))
        #expect(try CronExpression("  @Hourly ") == CronExpression("0 * * * *"))
    }

    @Test func rejectsWhatCronWouldNotRunOrRunsTooOften() {
        for bad in ["", "* * * *", "0 9 * * * *", "60 * * * *", "0 24 * * *", "0 9 0 * *", "0 9 * 13 *", "0 9 * * 8",
            "5-1 * * * *", "*/0 * * * *", "0 9 * * funday", "0,,5 * * * *", "0 9 * * 1/"] {
            #expect(throws: CronExpression.Failure.self, "\(bad)") { try CronExpression(bad) }
        }
        #expect(throws: CronExpression.Failure.tooFrequent) { try CronExpression("* * * * *") }
        #expect(throws: CronExpression.Failure.tooFrequent) { try CronExpression("*/4 * * * *") }
        // :58 and the next hour's :01 are three minutes apart.
        #expect(throws: CronExpression.Failure.tooFrequent) { try CronExpression("58,1 * * * *") }
        #expect(throws: CronExpression.Failure.neverRuns) { try CronExpression("0 9 30 2 *") }
        #expect((try? CronExpression("*/5 * * * *")) != nil)
        #expect(TaskRecurrence(kind: .cron, cron: "* * * * *").validationError != nil)
    }

    @Test func runsOnEitherRestrictedDayAsCronDoes() throws {
        // The 13th, or any Friday: 2026-11-06 is a Friday, the 13th is a Friday too.
        let expression = try CronExpression("0 12 13 * 5")
        let utc = TimeZone(identifier: "UTC")!
        var cursor = at("2026-11-01T00:00:00Z")
        var runs: [Date] = []
        for _ in 0..<3 {
            cursor = try #require(expression.next(after: cursor, in: utc))
            runs.append(cursor)
        }
        #expect(runs == [at("2026-11-06T12:00:00Z"), at("2026-11-13T12:00:00Z"), at("2026-11-20T12:00:00Z")])
        // Leap days are found years ahead.
        #expect(try CronExpression("0 0 29 2 *").next(after: at("2026-03-01T00:00:00Z"), in: utc) == at("2028-02-29T00:00:00Z"))
    }

    @Test func followsTheZonesDaylightSavingLikeTheOtherKinds() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        let nightly = try CronExpression("30 2 * * *")
        // The missing 02:30 of spring forward runs at 03:00, the next valid time.
        #expect(nightly.next(after: at("2026-03-08T05:00:00Z"), in: newYork) == at("2026-03-08T07:00:00Z"))
        let early = try CronExpression("30 1 * * *")
        // The repeated 01:30 of fall back runs once, at its first occurrence.
        #expect(early.next(after: at("2026-11-01T04:00:00Z"), in: newYork) == at("2026-11-01T05:30:00Z"))
        #expect(early.next(after: at("2026-11-01T05:30:00Z"), in: newYork) == at("2026-11-02T06:30:00Z"))
        let recurrence = TaskRecurrence(kind: .cron, timeZoneID: "Asia/Kolkata", cron: "15 9 * * 1")
        #expect(recurrence.next(after: at("2026-10-28T12:00:00Z")) == at("2026-11-02T03:45:00Z"))
        #expect(recurrence.upcoming(after: at("2026-10-28T12:00:00Z"), count: 3).count == 3)
    }
}

// MARK: - Agent-facing schedules

@Suite struct ScheduleSpecTests {
    private let now = at("2026-10-30T10:00:00Z")
    private let utc = TimeZone(identifier: "UTC")!

    private func spec(_ json: String) throws -> TaskRecurrence {
        try TaskRecurrence(spec: try #require(JSONValue.parse(json)), now: now, defaultTimeZone: utc)
    }

    @Test func readsEveryKindInTheUsersZoneUnlessOneIsNamed() throws {
        #expect(try spec(#"{"kind":"daily","time":"09:30"}"#) == TaskRecurrence(kind: .daily, timeZoneID: utc.identifier, hour: 9, minute: 30))
        #expect(try spec(#"{"kind":"weekly","day":"Thursday","time":"18:00"}"#).weekday == 5)
        #expect(try spec(#"{"kind":"weekdays","time":"08:00","timeZone":"Europe/Paris"}"#).timeZoneID == "Europe/Paris")
        #expect(try spec(#"{"kind":"days","days":["mon","fri","mon"],"time":"07:05"}"#).weekdays == [2, 6])
        #expect(try spec(#"{"kind":"interval","hours":2}"#).intervalMinutes == 120)
        #expect(try spec(#"{"kind":"interval","minutes":30}"#).next(after: now) == now.addingTimeInterval(1800))
        #expect(try spec(#"{"kind":"cron","expression":"0 9 * * 1-5"}"#).cron == "0 9 * * 1-5")
        #expect(try spec(#"{"kind":"once","inMinutes":20}"#).date == now.addingTimeInterval(1200))
        #expect(try spec(#"{"kind":"once","at":"2026-11-02T09:00"}"#).date == at("2026-11-02T09:00:00Z"))
        #expect(try spec(#"{"kind":"once","at":"2026-11-02T09:00:00+05:30"}"#).date == at("2026-11-02T03:30:00Z"))
        // What it reads, it writes back.
        let days = try spec(#"{"kind":"days","days":["tue","sat"],"time":"06:00"}"#)
        #expect(try TaskRecurrence(spec: days.spec, now: now, defaultTimeZone: utc) == days)
    }

    @Test func refusesWhatCantRun() {
        for bad in [
            #"{"kind":"daily","time":"9am"}"#, #"{"kind":"daily"}"#, #"{"kind":"weekly","day":"someday","time":"09:00"}"#,
            #"{"kind":"days","days":[],"time":"09:00"}"#, #"{"kind":"interval","minutes":2}"#, #"{"kind":"interval"}"#,
            #"{"kind":"cron","expression":"* * * * *"}"#, #"{"kind":"once","at":"2026-10-01T09:00"}"#,
            #"{"kind":"once","inMinutes":0}"#, #"{"kind":"hourly"}"#, #"{"kind":"daily","time":"09:00","timeZone":"Mars/Base"}"#,
            #"{"kind":"daily","time":"09:00","extra":true}"#, #"[]"#,
        ] {
            #expect(throws: ScheduleError.self, "\(bad)") { try spec(bad) }
        }
    }

    @Test func requestsHaveSmallStrictShapes() throws {
        let id = UUID()
        #expect(try ScheduleRequest(json: ["action": "list"]) == .list)
        #expect(try ScheduleRequest(json: ["action": "run-now", "id": .string(id.uuidString)]) == .runNow(id))
        #expect(try ScheduleRequest(json: ["action": "runNow", "id": .string(id.uuidString)]) == .runNow(id))
        #expect(try ScheduleRequest(json: ["action": "pause", "id": .string(id.uuidString)]) == .pause(id))
        let create = try ScheduleRequest(json: ["action": "create", "name": " Standup ", "prompt": "Summarize", "schedule": ["kind": "daily", "time": "09:00"]])
        #expect(create == .create(name: "Standup", prompt: "Summarize", schedule: ["kind": "daily", "time": "09:00"]))
        for bad: JSONValue in [
            [:], ["action": "approve", "id": .string(id.uuidString)], ["action": "list", "thread": "other"],
            ["action": "pause"], ["action": "pause", "id": "nope"], ["action": "create", "name": "N", "prompt": "P"],
            ["action": "create", "name": "", "prompt": "P", "schedule": [:]], ["action": "update", "id": .string(id.uuidString)],
            ["action": "create", "name": .string(String(repeating: "n", count: 201)), "prompt": "P", "schedule": [:]],
            ["action": "allow", "id": .string(id.uuidString)],
        ] {
            #expect(throws: ScheduleError.self, "\(bad.compactJSON)") { try ScheduleRequest(json: bad) }
        }
    }
}

// MARK: - Thread schedules

@MainActor @Suite(.serialized) struct ThreadScheduleTests {
    @Test func sendsIntoItsOwnThreadAfterPersistingTheOccurrence() throws {
        let fixture = ThreadFixture()
        defer { fixture.cleanUp() }
        let task = try fixture.add()
        fixture.now = fixture.due
        fixture.scheduler.tick()
        #expect(fixture.delivered.map(\.id) == [task.id])
        #expect(fixture.delivered.first?.threadID == fixture.thread)
        #expect(fixture.made == 0)
        let saved = fixture.saved(task)
        #expect(saved.activeThreadID == fixture.thread && saved.lastThreadID == fixture.thread)
        #expect(saved.lastFiredOccurrence == fixture.due)
        #expect(saved.nextRunAt == fixture.due.addingTimeInterval(86_400))
        // The persisted state was on disk when the prompt went out.
        #expect(fixture.persistedAtDelivery.first?.lastFiredOccurrence == fixture.due)
        fixture.scheduler.tick()
        #expect(fixture.delivered.count == 1)
        fixture.scheduler.finished(threadID: fixture.thread, outcome: .completed)
        #expect(fixture.saved(task).activeThreadID == nil && fixture.saved(task).lastOutcome == .completed)
    }

    @Test func waitsOnceForABusyThreadInsteadOfInterruptingOrPilingUp() throws {
        let fixture = ThreadFixture()
        defer { fixture.cleanUp() }
        let task = try fixture.add(kind: .interval)
        fixture.state = .busy
        fixture.now = fixture.due
        fixture.scheduler.tick()
        #expect(fixture.delivered.isEmpty)
        #expect(fixture.saved(task).pendingDelivery == fixture.due)
        #expect(fixture.saved(task).lastFiredOccurrence == fixture.due)
        // Two more occurrences come due while the thread is still busy: still one run waiting.
        fixture.now = fixture.due.addingTimeInterval(3 * 3600 + 60)
        fixture.scheduler.tick()
        fixture.scheduler.tick()
        #expect(fixture.delivered.isEmpty)
        #expect(fixture.saved(task).pendingDelivery == fixture.due)
        #expect(fixture.saved(task).nextRunAt == fixture.due.addingTimeInterval(4 * 3600))
        fixture.state = .ready
        fixture.scheduler.tick()
        #expect(fixture.delivered.count == 1)
        #expect(fixture.saved(task).pendingDelivery == nil)
        fixture.scheduler.tick()
        #expect(fixture.delivered.count == 1)
        // Run Now on a busy thread waits for it too.
        fixture.state = .busy
        try fixture.scheduler.runNow(task.id)
        #expect(fixture.delivered.count == 1 && fixture.saved(task).pendingDelivery == fixture.now)
        fixture.state = .ready
        fixture.scheduler.tick()
        #expect(fixture.delivered.count == 2)
    }

    @Test func aRelaunchSkipsTheRunThatWasWaitingForItsThread() throws {
        let fixture = ThreadFixture()
        defer { fixture.cleanUp() }
        let task = try fixture.add()
        fixture.state = .busy
        fixture.now = fixture.due
        fixture.scheduler.tick()
        #expect(fixture.saved(task).pendingDelivery != nil)
        fixture.state = .ready
        fixture.scheduler.resume(afterRelaunch: true)
        fixture.scheduler.tick()
        #expect(fixture.delivered.isEmpty)
        #expect(fixture.saved(task).pendingDelivery == nil && fixture.saved(task).lastOutcome == .missed)
    }

    @Test func archivedOrDeletedThreadsPauseTheirSchedulesAndSayWhy() throws {
        let fixture = ThreadFixture()
        defer { fixture.cleanUp() }
        let task = try fixture.add()
        let userPaused = try fixture.add(name: "Mine")
        try fixture.scheduler.setPaused(userPaused.id, true)
        fixture.state = .archived
        fixture.now = fixture.due
        fixture.scheduler.tick()
        #expect(fixture.delivered.isEmpty)
        #expect(fixture.saved(task).isPaused && fixture.saved(task).pauseReason == .threadArchived)
        #expect(fixture.saved(userPaused).pauseReason == nil)
        #expect(throws: ScheduleError.threadArchived) { try fixture.scheduler.runNow(task.id) }
        #expect(throws: ScheduleError.threadArchived) { try fixture.scheduler.setPaused(task.id, false) }
        fixture.state = .missing
        fixture.scheduler.reconcileThreads()
        #expect(fixture.saved(task).pauseReason == .threadDeleted)
        #expect(throws: ScheduleError.threadMissing) { try fixture.scheduler.runNow(task.id) }
        // The thread comes back (undo): the schedule Coincide paused resumes; the one the user paused stays paused.
        fixture.state = .ready
        fixture.scheduler.reconcileThreads()
        #expect(fixture.saved(task).isActive && fixture.saved(task).pauseReason == nil)
        #expect(fixture.saved(task).nextRunAt == fixture.due.addingTimeInterval(86_400))
        #expect(fixture.saved(userPaused).isPaused)
        #expect(fixture.delivered.isEmpty)
    }

    @Test func aFailedDeliveryPausesWithTheReason() throws {
        let fixture = ThreadFixture()
        defer { fixture.cleanUp() }
        let task = try fixture.add()
        fixture.failure = ScheduleError.unavailableProvider
        fixture.now = fixture.due
        fixture.scheduler.tick()
        fixture.scheduler.tick()
        #expect(fixture.attempts == 1)
        #expect(fixture.saved(task).isPaused && fixture.saved(task).lastOutcome == .failed)
        #expect(fixture.saved(task).activeThreadID == nil)
    }

    @Test func nothingAnAgentCreatedRunsBeforeTheUserAllowsIt() throws {
        let fixture = ThreadFixture()
        defer { fixture.cleanUp() }
        var task = ScheduledTask(name: "Agent's", projectID: fixture.project, prompt: "Check CI",
            recurrence: TaskRecurrence(kind: .daily, timeZoneID: "UTC", hour: 9), threadID: fixture.thread, now: fixture.now)
        task.awaitingApproval = true
        try fixture.scheduler.save(task)
        fixture.now = fixture.due
        fixture.scheduler.tick()
        #expect(throws: ScheduleError.awaitingApproval) { try fixture.scheduler.runNow(task.id) }
        try fixture.scheduler.setPaused(task.id, false)
        fixture.scheduler.tick()
        #expect(fixture.delivered.isEmpty)
        try fixture.scheduler.approve(task.id)
        #expect(!fixture.saved(task).isAwaitingApproval)
        fixture.now = fixture.due.addingTimeInterval(86_400)
        fixture.scheduler.tick()
        #expect(fixture.delivered.map(\.id) == [task.id])
    }
}

@MainActor private final class ThreadFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-thread-schedule-\(UUID())")
    let due = at("2026-10-28T09:00:00Z")
    var now = at("2026-10-28T08:00:00Z")
    let project = UUID(), thread = UUID()
    var state = ScheduleThreadState.ready
    var delivered: [ScheduledTask] = []
    var persistedAtDelivery: [ScheduledTask] = []
    var made = 0, attempts = 0
    var failure: Error?
    let store: ScheduledTaskStore
    lazy var scheduler = TaskScheduler(store: store, now: { [unowned self] in now },
        makeThread: { [unowned self] _ in made += 1; return UUID() }, startThread: { _, _ in },
        threadState: { [unowned self] id in id == thread ? state : .missing },
        deliver: { [unowned self] task in
            attempts += 1
            if let failure { throw failure }
            persistedAtDelivery.append(ScheduledTaskStore(directory: directory).task(task.id)!)
            delivered.append(task)
        })

    init() { store = ScheduledTaskStore(directory: directory) }

    @discardableResult
    func add(name: String = "Standup", kind: TaskRecurrence.Kind = .daily) throws -> ScheduledTask {
        let recurrence =
            kind == .interval
            ? TaskRecurrence(kind: .interval, timeZoneID: "UTC", date: due, intervalMinutes: 60)
            : TaskRecurrence(kind: kind, timeZoneID: "UTC", hour: 9)
        let task = ScheduledTask(name: name, projectID: project, prompt: "Post the standup", recurrence: recurrence, threadID: thread, now: now)
        try scheduler.save(task)
        return task
    }

    func saved(_ task: ScheduledTask) -> ScheduledTask { store.task(task.id)! }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
