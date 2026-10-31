import Foundation

// The Mac's scheduled tasks (`scheduledTasks`, `saveScheduledTask`, `scheduledTaskAction`): a prompt that runs in a
// project on a schedule, each run in a new thread. Every type decodes leniently: a schedule kind or field a newer Mac
// adds reads as unknown or is skipped, and the phone leaves such a task's schedule alone when it edits the rest.

/// When a task runs, in the time zone it was set in.
public struct RemoteTaskRecurrence: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case once, daily, weekly
        /// A kind a newer Mac added; the phone shows the Mac's description and keeps it when saving.
        case unknown

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// The kinds the phone can set.
        public static let editable: [Kind] = [.once, .daily, .weekly]
    }

    public var kind: Kind
    public var timeZoneID: String
    /// The day of a one-time task.
    public var date: Date
    public var hour: Int
    public var minute: Int
    /// 1 is Sunday, as `Calendar` counts.
    public var weekday: Int

    public init(
        kind: Kind = .daily, timeZoneID: String = TimeZone.current.identifier, date: Date = Date(), hour: Int = 9,
        minute: Int = 0, weekday: Int = 2
    ) {
        self.kind = kind
        self.timeZoneID = timeZoneID
        self.date = date
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
    }

    private enum CodingKeys: String, CodingKey { case kind, timeZoneID, date, hour, minute, weekday }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .unknown
        timeZoneID = (try? container.decode(String.self, forKey: .timeZoneID)) ?? TimeZone.current.identifier
        date = (try? container.decode(Date.self, forKey: .date)) ?? Date()
        hour = (try? container.decode(Int.self, forKey: .hour)) ?? 9
        minute = (try? container.decode(Int.self, forKey: .minute)) ?? 0
        weekday = (try? container.decode(Int.self, forKey: .weekday)) ?? 2
    }
}

/// A scheduled task as the Mac's Scheduled Tasks window lists it.
public struct RemoteScheduledTask: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Hashable, Sendable {
        case scheduled, running, paused, failed, interrupted, missed, completed
        case unknown

        public init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var id: UUID
    public var name: String
    public var projectID: UUID
    public var prompt: String
    public var recurrence: RemoteTaskRecurrence
    public var isPaused: Bool
    public var state: State
    /// "Scheduled", "Failed · Paused", as the Mac words the task's state.
    public var stateText: String
    /// "Daily at 9:00 AM", as the Mac describes the schedule.
    public var scheduleText: String
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    /// Why the last run failed, or what it said.
    public var lastMessage: String?
    /// The thread the last run opened.
    public var lastThreadID: UUID?
    /// Whether "Run Now" can start it: not running, and its project free.
    public var canRunNow: Bool
    /// The thread each run sends its prompt into, for a thread schedule; nil for a project task (or from an older Mac).
    public var threadID: UUID?
    /// The bot whose conversation that thread is, for its artwork.
    public var botID: UUID?
    /// An agent created it and it waits for the user to allow it, in the thread's approval card.
    public var needsApproval: Bool?
    /// An agent created it.
    public var createdByAgent: Bool?

    public init(
        id: UUID, name: String, projectID: UUID, prompt: String, recurrence: RemoteTaskRecurrence, isPaused: Bool = false,
        state: State = .scheduled, stateText: String = "", scheduleText: String = "", nextRunAt: Date? = nil,
        lastRunAt: Date? = nil, lastMessage: String? = nil, lastThreadID: UUID? = nil, canRunNow: Bool = true,
        threadID: UUID? = nil, botID: UUID? = nil, needsApproval: Bool? = nil, createdByAgent: Bool? = nil
    ) {
        self.threadID = threadID
        self.botID = botID
        self.needsApproval = needsApproval
        self.createdByAgent = createdByAgent
        self.id = id
        self.name = name
        self.projectID = projectID
        self.prompt = prompt
        self.recurrence = recurrence
        self.isPaused = isPaused
        self.state = state
        self.stateText = stateText
        self.scheduleText = scheduleText
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastMessage = lastMessage
        self.lastThreadID = lastThreadID
        self.canRunNow = canRunNow
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, projectID, prompt, recurrence, isPaused, state, stateText, scheduleText, nextRunAt, lastRunAt,
            lastMessage, lastThreadID, canRunNow, threadID, botID, needsApproval, createdByAgent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        projectID = try container.decode(UUID.self, forKey: .projectID)
        prompt = (try? container.decode(String.self, forKey: .prompt)) ?? ""
        recurrence = (try? container.decode(RemoteTaskRecurrence.self, forKey: .recurrence)) ?? RemoteTaskRecurrence(kind: .unknown)
        isPaused = (try? container.decode(Bool.self, forKey: .isPaused)) ?? false
        state = (try? container.decode(State.self, forKey: .state)) ?? .unknown
        stateText = (try? container.decode(String.self, forKey: .stateText)) ?? ""
        scheduleText = (try? container.decode(String.self, forKey: .scheduleText)) ?? ""
        nextRunAt = try? container.decodeIfPresent(Date.self, forKey: .nextRunAt)
        lastRunAt = try? container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastMessage = try? container.decodeIfPresent(String.self, forKey: .lastMessage)
        lastThreadID = try? container.decodeIfPresent(UUID.self, forKey: .lastThreadID)
        canRunNow = (try? container.decode(Bool.self, forKey: .canRunNow)) ?? false
        threadID = try? container.decodeIfPresent(UUID.self, forKey: .threadID)
        botID = try? container.decodeIfPresent(UUID.self, forKey: .botID)
        needsApproval = try? container.decodeIfPresent(Bool.self, forKey: .needsApproval)
        createdByAgent = try? container.decodeIfPresent(Bool.self, forKey: .createdByAgent)
    }

    public var isThreadSchedule: Bool { threadID != nil }
}

/// The Mac's scheduled tasks, and why they couldn't be read or the last run couldn't start, if so.
public struct RemoteScheduledTasks: Codable, Hashable, Sendable {
    public var tasks: [RemoteScheduledTask]
    public var error: String?

    public init(tasks: [RemoteScheduledTask] = [], error: String? = nil) {
        self.tasks = tasks
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case tasks, error }

    /// A task that doesn't decode is left out rather than losing the list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = (try? container.decode([LenientTask].self, forKey: .tasks)) ?? []
        tasks = lenient.compactMap(\.task)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
    }

    private struct LenientTask: Decodable {
        var task: RemoteScheduledTask?
        init(from decoder: Decoder) throws { task = try? RemoteScheduledTask(from: decoder) }
    }
}

/// A task the phone creates (no `id`) or edits. A nil `recurrence` keeps the task's schedule, for one whose kind the
/// phone doesn't know.
public struct RemoteScheduledTaskDraft: Codable, Hashable, Sendable {
    public var id: UUID?
    public var name: String
    public var projectID: UUID
    public var prompt: String
    public var recurrence: RemoteTaskRecurrence?
    public var isPaused: Bool
    /// A new thread schedule's thread: each run sends the prompt into it. Ignored when editing, and by an older Mac.
    public var threadID: UUID?

    public init(
        id: UUID? = nil, name: String, projectID: UUID, prompt: String, recurrence: RemoteTaskRecurrence?, isPaused: Bool = false,
        threadID: UUID? = nil
    ) {
        self.threadID = threadID
        self.id = id
        self.name = name
        self.projectID = projectID
        self.prompt = prompt
        self.recurrence = recurrence
        self.isPaused = isPaused
    }
}

/// Something done to a scheduled task from its row.
public struct RemoteScheduledTaskCommand: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable {
        case pause, resume, runNow, delete
        case unknown

        public init(from decoder: Decoder) throws {
            self = Action(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var taskID: UUID
    public var action: Action

    public init(taskID: UUID, action: Action) {
        self.taskID = taskID
        self.action = action
    }
}

// MARK: - Grouping

/// Where a scheduled task's runs go, which the phone's list groups by, as the Mac's Scheduled panel does.
public enum RemoteScheduleOwner: Hashable, Sendable {
    case bot(UUID)
    case thread(UUID)
    /// A project task: each run starts a new thread there.
    case project(UUID)

    public init(_ task: RemoteScheduledTask) {
        if let bot = task.botID {
            self = .bot(bot)
        } else if let thread = task.threadID {
            self = .thread(thread)
        } else {
            self = .project(task.projectID)
        }
    }

    /// Tasks grouped by owner: the group with the soonest run first, and in each group the soonest task first. Paused
    /// tasks and tasks without a next run sort after the others, by name.
    public static func groups(_ tasks: [RemoteScheduledTask]) -> [(owner: RemoteScheduleOwner, tasks: [RemoteScheduledTask])] {
        func next(_ task: RemoteScheduledTask) -> Date { task.isPaused ? .distantFuture : task.nextRunAt ?? .distantFuture }
        var order: [RemoteScheduleOwner] = []
        var byOwner: [RemoteScheduleOwner: [RemoteScheduledTask]] = [:]
        for task in tasks {
            let owner = RemoteScheduleOwner(task)
            if byOwner[owner] == nil { order.append(owner) }
            byOwner[owner, default: []].append(task)
        }
        let grouped = order.map { owner in
            (owner: owner, tasks: byOwner[owner, default: []].sorted {
                next($0) == next($1) ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : next($0) < next($1)
            })
        }
        return grouped.enumerated().sorted { lhs, rhs in
            let left = lhs.element.tasks.first.map(next) ?? .distantFuture
            let right = rhs.element.tasks.first.map(next) ?? .distantFuture
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }
}

extension RemoteThreadSummary {
    /// The next run, as short as the thread's clock can say it: "9:00" today, "Tue 9:00" within the week, a date further
    /// out. Nil when the thread has no active schedule.
    public func compactNextRun(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let date = nextScheduledRun else { return nil }
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if (1...6).contains(days) { return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Whether the thread has schedules, for the clock in its header.
    public var hasSchedules: Bool { (scheduleCount ?? 0) > 0 }
}
