import Foundation

public struct TaskRecurrence: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case once, daily, weekly }
    public var kind: Kind
    public var timeZoneID: String
    public var date: Date
    public var hour: Int
    public var minute: Int
    /// Calendar weekday: Sunday is 1.
    public var weekday: Int

    public init(kind: Kind = .daily, timeZoneID: String = TimeZone.current.identifier,
        date: Date = Date(), hour: Int = 9, minute: Int = 0, weekday: Int = 2) {
        self.kind = kind; self.timeZoneID = timeZoneID; self.date = date
        self.hour = hour; self.minute = minute; self.weekday = weekday
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.kind == rhs.kind, lhs.timeZoneID == rhs.timeZoneID else { return false }
        if lhs.kind == .once { return lhs.date == rhs.date }
        return lhs.hour == rhs.hour && lhs.minute == rhs.minute && (lhs.kind != .weekly || lhs.weekday == rhs.weekday)
    }

    public var isValid: Bool {
        TimeZone(identifier: timeZoneID) != nil && (0...23).contains(hour) && (0...59).contains(minute)
            && (1...7).contains(weekday) && date.timeIntervalSinceReferenceDate.isFinite
    }

    /// Skipped clock times run at the first valid time; repeated clock times use their first occurrence.
    public func next(after now: Date) -> Date? {
        guard isValid else { return nil }
        if kind == .once { return date > now ? date : nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        let match = DateComponents(hour: hour, minute: minute, second: 0)
        let today = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            if kind == .weekly, calendar.component(.weekday, from: day) != weekday { continue }
            // Search from the day's start, not from `now`: after the first 01:30 on a fall-back day,
            // Calendar otherwise returns the second 01:30 even with repeatedTimePolicy.first.
            if let candidate = calendar.nextDate(after: day.addingTimeInterval(-1), matching: match,
                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
                calendar.isDate(candidate, inSameDayAs: day), candidate > now { return candidate }
        }
        return nil
    }
}

public struct ScheduledTask: Identifiable, Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case completed, failed, interrupted, missed }
    public var id: UUID
    public var name: String
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

    public init(id: UUID = UUID(), name: String, projectID: UUID, prompt: String, recurrence: TaskRecurrence,
        isPaused: Bool = false, now: Date = Date()) {
        self.id = id; self.name = name; self.projectID = projectID; self.prompt = prompt
        self.recurrence = recurrence; self.isPaused = isPaused
        self.nextRunAt = recurrence.next(after: now)
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 1024
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.utf8.count <= 1_048_576
            && recurrence.isValid
    }
}

public enum ScheduleError: LocalizedError {
    case invalidTask, alreadyRunning, missingProject, unavailableProvider, pastDate, storage(String)
    public var errorDescription: String? {
        switch self {
        case .invalidTask: String(localized: "Enter a task name, prompt and valid schedule.")
        case .alreadyRunning: String(localized: "This scheduled task is already running.")
        case .missingProject: String(localized: "The scheduled task's project is no longer available.")
        case .unavailableProvider: String(localized: "No ready agent is available for this scheduled task.")
        case .pastDate: String(localized: "Choose a future date for a one-time task.")
        case .storage(let detail): String(localized: "Could not save scheduled tasks: \(detail)")
        }
    }
}
