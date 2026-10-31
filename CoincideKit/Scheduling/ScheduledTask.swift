import Foundation

public struct TaskRecurrence: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case once, daily, weekly
        /// Monday to Friday at `hour`:`minute`.
        case weekdays
        /// The days in `weekdays` at `hour`:`minute`.
        case days
        /// Every `intervalMinutes`, counted from `date`.
        case interval
        /// A five-field cron expression (`cron`), read in `timeZoneID`.
        case cron
    }

    /// Repeating schedules never run more often than this.
    public static let minimumIntervalMinutes = 5
    /// A month, so a mistyped unit can't park a schedule for years.
    public static let maximumIntervalMinutes = 31 * 24 * 60

    public var kind: Kind
    public var timeZoneID: String
    /// `once`: when it runs. `interval`: the first run, which later runs are counted from.
    public var date: Date
    public var hour: Int
    public var minute: Int
    /// Calendar weekday: Sunday is 1.
    public var weekday: Int
    /// `days`: the calendar weekdays it runs on (Sunday is 1). Nil for the other kinds and in files from before.
    public var weekdays: [Int]?
    /// `interval`: the minutes between runs.
    public var intervalMinutes: Int?
    /// `cron`: minute, hour, day of month, month and day of week.
    public var cron: String?

    public init(kind: Kind = .daily, timeZoneID: String = TimeZone.current.identifier,
        date: Date = Date(), hour: Int = 9, minute: Int = 0, weekday: Int = 2,
        weekdays: [Int]? = nil, intervalMinutes: Int? = nil, cron: String? = nil) {
        self.kind = kind; self.timeZoneID = timeZoneID; self.date = date
        self.hour = hour; self.minute = minute; self.weekday = weekday
        self.weekdays = weekdays; self.intervalMinutes = intervalMinutes; self.cron = cron
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        switch lhs.kind {
        case .once: return lhs.date == rhs.date
        case .interval: return lhs.date == rhs.date && lhs.intervalMinutes == rhs.intervalMinutes
        case .cron: return lhs.timeZoneID == rhs.timeZoneID && lhs.cron == rhs.cron
        case .daily, .weekly, .weekdays, .days:
            guard lhs.timeZoneID == rhs.timeZoneID, lhs.hour == rhs.hour, lhs.minute == rhs.minute else { return false }
            if lhs.kind == .weekly { return lhs.weekday == rhs.weekday }
            if lhs.kind == .days { return Set(lhs.weekdays ?? []) == Set(rhs.weekdays ?? []) }
            return true
        }
    }

    /// The calendar weekdays a `weekdays` schedule runs on, Monday to Friday.
    public static let workWeek: Set<Int> = [2, 3, 4, 5, 6]

    public var isValid: Bool { validationError == nil }

    /// Why the schedule can't run, or nil when it can.
    public var validationError: String? {
        guard TimeZone(identifier: timeZoneID) != nil else { return String(localized: "Choose a valid time zone.") }
        guard date.timeIntervalSinceReferenceDate.isFinite, (0...23).contains(hour), (0...59).contains(minute),
            (1...7).contains(weekday)
        else { return String(localized: "Choose a valid time.") }
        switch kind {
        case .once, .daily, .weekly, .weekdays: return nil
        case .days:
            let days = weekdays ?? []
            return !days.isEmpty && days.allSatisfy((1...7).contains) ? nil : String(localized: "Choose at least one day.")
        case .interval:
            guard let minutes = intervalMinutes, (Self.minimumIntervalMinutes...Self.maximumIntervalMinutes).contains(minutes) else {
                return String(localized: "Repeat every 5 minutes to 31 days.")
            }
            return nil
        case .cron:
            do { _ = try CronExpression(cron ?? "") } catch { return error.localizedDescription }
            return nil
        }
    }

    /// The calendar weekdays a day-based schedule runs on.
    private var runDays: Set<Int>? {
        switch kind {
        case .weekly: [weekday]
        case .weekdays: Self.workWeek
        case .days: Set(weekdays ?? [])
        default: nil
        }
    }

    /// Skipped clock times run at the first valid time; repeated clock times use their first occurrence.
    public func next(after now: Date) -> Date? {
        guard isValid else { return nil }
        switch kind {
        case .once: return date > now ? date : nil
        case .interval:
            let step = TimeInterval((intervalMinutes ?? Self.minimumIntervalMinutes) * 60)
            guard date <= now else { return date }
            // Whole steps from the first run, so the clock times stay put however late the Mac woke.
            let steps = ((now.timeIntervalSince(date)) / step).rounded(.down) + 1
            var candidate = date.addingTimeInterval(steps * step)
            while candidate <= now { candidate = candidate.addingTimeInterval(step) }
            return candidate
        case .cron:
            guard let zone = TimeZone(identifier: timeZoneID), let expression = try? CronExpression(cron ?? "") else { return nil }
            return expression.next(after: now, in: zone)
        case .daily, .weekly, .weekdays, .days:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneID)!
            let match = DateComponents(hour: hour, minute: minute, second: 0)
            let today = calendar.startOfDay(for: now)
            let days = runDays
            for offset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                if let days, !days.contains(calendar.component(.weekday, from: day)) { continue }
                // Search from the day's start, not from `now`: after the first 01:30 on a fall-back day,
                // Calendar otherwise returns the second 01:30 even with repeatedTimePolicy.first.
                if let candidate = calendar.nextDate(after: day.addingTimeInterval(-1), matching: match,
                    matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
                    calendar.isDate(candidate, inSameDayAs: day), candidate > now { return candidate }
            }
            return nil
        }
    }

    /// The next `count` runs after `now`, for a preview.
    public func upcoming(after now: Date, count: Int) -> [Date] {
        var runs: [Date] = []
        var cursor = now
        while runs.count < count, let next = next(after: cursor) {
            runs.append(next)
            cursor = next
        }
        return runs
    }

    /// Whether it runs more than once.
    public var repeats: Bool { kind != .once }
}

public enum ScheduleError: LocalizedError, Equatable {
    case invalidTask, alreadyRunning, missingProject, unavailableProvider, pastDate, storage(String)
    case threadMissing, threadArchived, awaitingApproval, notFound
    case limitReached(Int), rateLimited
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTask: String(localized: "Enter a task name, prompt and valid schedule.")
        case .alreadyRunning: String(localized: "This scheduled task is already running.")
        case .missingProject: String(localized: "The scheduled task's project is no longer available.")
        case .unavailableProvider: String(localized: "No ready agent is available for this scheduled task.")
        case .pastDate: String(localized: "Choose a future date for a one-time task.")
        case .storage(let detail): String(localized: "Could not save scheduled tasks: \(detail)")
        case .threadMissing: String(localized: "The thread this schedule sends to was deleted.")
        case .threadArchived: String(localized: "The thread this schedule sends to is archived. Unarchive it to run the schedule.")
        case .awaitingApproval: String(localized: "This schedule is waiting for the user to allow it.")
        case .notFound: String(localized: "This thread has no schedule with that id.")
        case .limitReached(let count): String(localized: "A thread can have at most \(count) schedules.")
        case .rateLimited: String(localized: "Too many schedules were created in this thread just now. Try again in a few minutes.")
        case .invalidRequest(let detail): detail
        }
    }
}

// MARK: - Cron

/// A standard five-field cron expression: minute, hour, day of month, month and day of week, each `*`, a number, a
/// range (`1-5`), a list (`1,15`) or a step (`*/15`, `9-17/2`). Months and days take English names (`JAN`, `MON`);
/// Sunday is 0 or 7. As in cron, a day that matches either a restricted day of month or a restricted day of week runs.
/// `@hourly`, `@daily`, `@weekly`, `@monthly` and `@yearly` are shorthands.
public struct CronExpression: Equatable, Sendable {
    public let minutes: [Int]
    public let hours: [Int]
    public let daysOfMonth: Set<Int>
    public let months: Set<Int>
    /// 0 is Sunday.
    public let daysOfWeek: Set<Int>
    let restrictsDayOfMonth: Bool
    let restrictsDayOfWeek: Bool

    public enum Failure: LocalizedError, Equatable {
        case fieldCount
        case invalid(field: String, value: String)
        case tooFrequent
        case neverRuns

        public var errorDescription: String? {
            switch self {
            case .fieldCount:
                String(localized: "A cron expression has five fields: minute, hour, day of month, month and day of week.")
            case .invalid(let field, let value): String(localized: "“\(value)” isn't a valid \(field).")
            case .tooFrequent: String(localized: "Runs must be at least 5 minutes apart.")
            case .neverRuns: String(localized: "This expression never matches a date.")
            }
        }
    }

    private static let shorthands = [
        "@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@weekly": "0 0 * * 0",
        "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *",
    ]
    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    public init(_ text: String) throws(Failure) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expanded = Self.shorthands[trimmed] ?? trimmed
        let fields = expanded.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5, expanded.utf8.count <= 256 else { throw .fieldCount }
        minutes = try Self.parse(fields[0], range: 0...59, name: String(localized: "minute")).sorted()
        hours = try Self.parse(fields[1], range: 0...23, name: String(localized: "hour")).sorted()
        daysOfMonth = try Self.parse(fields[2], range: 1...31, name: String(localized: "day of the month"))
        months = try Self.parse(fields[3], range: 1...12, name: String(localized: "month"), names: Self.monthNames, nameBase: 1)
        let week = try Self.parse(fields[4], range: 0...7, name: String(localized: "day of the week"), names: Self.dayNames, nameBase: 0)
        daysOfWeek = Set(week.map { $0 % 7 })
        restrictsDayOfMonth = !fields[2].hasPrefix("*")
        restrictsDayOfWeek = !fields[4].hasPrefix("*")
        guard minimumGap >= TaskRecurrence.minimumIntervalMinutes else { throw .tooFrequent }
        // Feb 30 and the like: no day of any month matches.
        guard Self.anyDayMatches(daysOfMonth: daysOfMonth, months: months) || restrictsDayOfWeek else { throw .neverRuns }
    }

    /// The fewest minutes between two runs on the same or consecutive days.
    var minimumGap: Int {
        let times = hours.flatMap { hour in minutes.map { hour * 60 + $0 } }.sorted()
        guard let first = times.first, let last = times.last else { return .max }
        var gap = first + 24 * 60 - last
        for (earlier, later) in zip(times, times.dropFirst()) { gap = min(gap, later - earlier) }
        return gap
    }

    private static func anyDayMatches(daysOfMonth: Set<Int>, months: Set<Int>) -> Bool {
        let lengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return months.contains { month in daysOfMonth.contains { $0 <= lengths[month - 1] } }
    }

    private static func parse(_ field: String, range: ClosedRange<Int>, name: String, names: [String] = [], nameBase: Int = 0)
        throws(Failure) -> Set<Int>
    {
        func value(_ text: String) throws(Failure) -> Int {
            if let number = Int(text), range.contains(number) { return number }
            if let index = names.firstIndex(of: text) { return index + nameBase }
            throw .invalid(field: name, value: field)
        }
        var result = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard !part.isEmpty else { throw .invalid(field: name, value: field) }
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count <= 2 else { throw .invalid(field: name, value: field) }
            var step = 1
            if pieces.count == 2 {
                guard let parsed = Int(pieces[1]), parsed > 0, parsed <= range.upperBound + 1 else {
                    throw .invalid(field: name, value: field)
                }
                step = parsed
            }
            let bounds: ClosedRange<Int>
            if pieces[0] == "*" {
                bounds = range
            } else if let dash = pieces[0].firstIndex(of: "-") {
                let low = try value(String(pieces[0][..<dash]))
                let high = try value(String(pieces[0][pieces[0].index(after: dash)...]))
                guard low <= high else { throw .invalid(field: name, value: field) }
                bounds = low...high
            } else {
                let single = try value(pieces[0])
                // "5/15" means from 5 to the end, every 15.
                bounds = pieces.count == 2 ? single...range.upperBound : single...single
            }
            result.formUnion(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
        }
        return result
    }

    /// Whether `day` (its month, day of month and weekday in `calendar`) is one the expression runs on.
    func runs(on day: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.month, .day, .weekday], from: day)
        guard let month = parts.month, let dayOfMonth = parts.day, let weekday = parts.weekday, months.contains(month) else {
            return false
        }
        let monthDay = daysOfMonth.contains(dayOfMonth), weekDay = daysOfWeek.contains(weekday - 1)
        switch (restrictsDayOfMonth, restrictsDayOfWeek) {
        case (true, true): return monthDay || weekDay
        case (true, false): return monthDay
        case (false, true): return weekDay
        case (false, false): return true
        }
    }

    /// The first run after `now`, read in `zone`. Skipped clock times run at the first valid time; repeated clock
    /// times use their first occurrence, as `TaskRecurrence.next(after:)` does. Nil when nothing matches for 5 years.
    public func next(after now: Date, in zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        for offset in 0..<(366 * 5) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today), runs(on: day, calendar: calendar) else {
                continue
            }
            let start = day.addingTimeInterval(-1)
            for hour in hours {
                for minute in minutes {
                    guard let candidate = calendar.nextDate(after: start, matching: DateComponents(hour: hour, minute: minute, second: 0),
                        matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
                        calendar.isDate(candidate, inSameDayAs: day)
                    else { continue }
                    if candidate > now { return candidate }
                }
            }
        }
        return nil
    }
}

// MARK: - Tasks

/// A change an agent asked for, waiting for the user to allow it (Settings › General › Approve schedules agents create).
public struct ScheduleProposal: Codable, Equatable, Sendable {
    /// The approval card in the thread's transcript.
    public var itemID: UUID
    public var name: String
    public var prompt: String
    public var recurrence: TaskRecurrence
    public var proposedAt: Date

    public init(itemID: UUID, name: String, prompt: String, recurrence: TaskRecurrence, proposedAt: Date = Date()) {
        self.itemID = itemID; self.name = name; self.prompt = prompt; self.recurrence = recurrence; self.proposedAt = proposedAt
    }
}

public struct ScheduledTask: Identifiable, Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case completed, failed, interrupted, missed }
    /// Why Coincide paused the schedule on its own; it resumes when the reason goes away.
    public enum PauseReason: String, Codable, Sendable { case threadArchived, threadDeleted }

    public var id: UUID
    public var name: String
    /// A project task's project; a thread schedule's thread's project, for grouping.
    public var projectID: UUID
    public var prompt: String
    public var recurrence: TaskRecurrence
    public var isPaused: Bool
    public var nextRunAt: Date?
    /// The consumed occurrence is persisted before its agent starts, including manual runs.
    public var lastFiredOccurrence: Date?
    public var lastRunAt: Date?
    public var lastFinishedAt: Date?
    public var lastOutcome: Outcome?
    public var lastMessage: String?
    public var lastThreadID: UUID?
    public var activeThreadID: UUID?
    /// The thread each run sends its prompt into, as a new message from the user. Nil for a project task, whose every
    /// run starts a new thread.
    public var threadID: UUID?
    /// An agent created it through the thread's `coincide_schedule` capability.
    public var createdByAgent: Bool?
    /// An agent created it and the user hasn't allowed it yet: it never runs. Its approval card is `proposal`.
    public var awaitingApproval: Bool?
    /// What an agent asked to create or change, until the user allows or declines it.
    public var proposal: ScheduleProposal?
    public var pauseReason: PauseReason?
    /// An occurrence that came due while its thread was busy: it is sent once the thread is idle.
    public var pendingDelivery: Date?

    public init(id: UUID = UUID(), name: String, projectID: UUID, prompt: String, recurrence: TaskRecurrence,
        isPaused: Bool = false, threadID: UUID? = nil, now: Date = Date()) {
        self.id = id; self.name = name; self.projectID = projectID; self.prompt = prompt
        self.recurrence = recurrence; self.isPaused = isPaused; self.threadID = threadID
        self.nextRunAt = recurrence.next(after: now)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, projectID, prompt, recurrence, isPaused, nextRunAt, lastFiredOccurrence, lastRunAt, lastFinishedAt
        case lastOutcome, lastMessage, lastThreadID, activeThreadID, threadID, createdByAgent, awaitingApproval, proposal
        case pauseReason, pendingDelivery
    }

    /// The fields every version writes must read; the others are left empty when this version can't read them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        prompt = try container.decode(String.self, forKey: .prompt)
        recurrence = try container.decode(TaskRecurrence.self, forKey: .recurrence)
        isPaused = try container.decode(Bool.self, forKey: .isPaused)
        nextRunAt = try container.decodeIfPresent(Date.self, forKey: .nextRunAt)
        lastFiredOccurrence = try container.decodeIfPresent(Date.self, forKey: .lastFiredOccurrence)
        lastRunAt = container.lenient(Date.self, forKey: .lastRunAt)
        lastFinishedAt = container.lenient(Date.self, forKey: .lastFinishedAt)
        lastOutcome = container.lenient(Outcome.self, forKey: .lastOutcome)
        lastMessage = container.lenient(String.self, forKey: .lastMessage)
        lastThreadID = container.lenient(UUID.self, forKey: .lastThreadID)
        activeThreadID = container.lenient(UUID.self, forKey: .activeThreadID)
        threadID = container.lenient(UUID.self, forKey: .threadID)
        createdByAgent = container.lenient(Bool.self, forKey: .createdByAgent)
        awaitingApproval = container.lenient(Bool.self, forKey: .awaitingApproval)
        proposal = container.lenient(ScheduleProposal.self, forKey: .proposal)
        pauseReason = container.lenient(PauseReason.self, forKey: .pauseReason)
        pendingDelivery = container.lenient(Date.self, forKey: .pendingDelivery)
    }

    public var isValid: Bool {
        Self.isValid(name: name, prompt: prompt) && recurrence.isValid
    }

    static func isValid(name: String, prompt: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 1024
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.utf8.count <= 1_048_576
    }

    /// Waiting for the user to allow what an agent created.
    public var isAwaitingApproval: Bool { awaitingApproval == true }
    /// Whether it may run on its own: not paused and allowed.
    public var isActive: Bool { !isPaused && !isAwaitingApproval }
    public var isThreadSchedule: Bool { threadID != nil }
}
