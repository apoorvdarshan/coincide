import AppKit
import CoincideKit

/// How a schedule reads in the thread's clock popup, the Scheduled panel and the sidebar.
enum SchedulePresentation {
    /// A schedule's state as a short label, with the badge color it shows in; nil for an active schedule waiting for
    /// its next run, which needs no badge.
    struct Status: Equatable {
        var label: String
        var color: NSColor
    }

    static func status(_ task: ScheduledTask, isRunning: Bool) -> Status? {
        if task.isAwaitingApproval { return Status(label: String(localized: "Needs approval"), color: .systemOrange) }
        if isRunning || task.activeThreadID != nil { return Status(label: String(localized: "Running"), color: Theme.ink) }
        if task.pendingDelivery != nil { return Status(label: String(localized: "Waiting for thread"), color: Theme.ink) }
        switch task.pauseReason {
        case .threadArchived: return Status(label: String(localized: "Thread archived"), color: .secondaryLabelColor)
        case .threadDeleted: return Status(label: String(localized: "Thread deleted"), color: .systemRed)
        case nil: break
        }
        if task.isPaused {
            return task.lastOutcome == .failed
                ? Status(label: String(localized: "Failed · Paused"), color: .systemRed)
                : Status(label: String(localized: "Paused"), color: .secondaryLabelColor)
        }
        if task.proposal != nil { return Status(label: String(localized: "Change needs approval"), color: .systemOrange) }
        switch task.lastOutcome {
        case .failed: return Status(label: String(localized: "Failed"), color: .systemRed)
        case .missed: return Status(label: String(localized: "Missed"), color: .systemOrange)
        case .interrupted: return Status(label: String(localized: "Interrupted"), color: .systemOrange)
        case .completed where task.nextRunAt == nil: return Status(label: String(localized: "Done"), color: .secondaryLabelColor)
        default: return nil
        }
    }

    /// Why a paused schedule is paused, or what its last run did, for its tooltip and second line.
    static func note(_ task: ScheduledTask) -> String? {
        switch task.pauseReason {
        case .threadArchived: return String(localized: "Paused because its thread is archived. It resumes when you unarchive the thread.")
        case .threadDeleted: return String(localized: "Paused because its thread was deleted. Delete the schedule, or undo deleting the thread.")
        case nil: break
        }
        if task.isAwaitingApproval { return String(localized: "An agent created this schedule. It runs once you allow it.") }
        if task.pendingDelivery != nil { return String(localized: "Its thread is busy; the run is sent when the current turn ends.") }
        return task.lastMessage
    }

    /// The next run, as short as it can be said: "9:00" today, "Tue 9:00" this week, a date further out.
    static func compactTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if (1...6).contains(days) { return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The next run in full, with its zone when it isn't the Mac's.
    static func fullTime(_ date: Date, zoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        formatter.timeZone = TimeZone(identifier: zoneID) ?? .current
        let text = formatter.string(from: date)
        return zoneID == TimeZone.current.identifier ? text : text + " (" + zoneID + ")"
    }

    /// The second line of a schedule's row: how often it runs, then its next run or why it won't.
    static func detail(_ task: ScheduledTask, now: Date = Date()) -> String {
        var parts = [task.recurrence.summary]
        if task.isActive, let next = task.pendingDelivery == nil ? task.nextRunAt : nil {
            parts.append(String(localized: "Next: \(fullTime(next, zoneID: task.recurrence.timeZoneID))"))
        } else if task.isActive, task.nextRunAt == nil, task.pendingDelivery == nil {
            parts.append(String(localized: "No future runs"))
        }
        return parts.joined(separator: " · ")
    }

    /// The tooltip of a thread's sidebar row clock and of its toolbar button: its schedules and next run.
    static func threadToolTip(_ tasks: [ScheduledTask]) -> String? {
        guard !tasks.isEmpty else { return nil }
        let active = tasks.filter(\.isActive)
        var lines = [
            tasks.count == 1
                ? String(localized: "1 scheduled task") : String(localized: "\(tasks.count) scheduled tasks")
        ]
        if let next = active.compactMap({ task in task.nextRunAt.map { (task, $0) } }).min(by: { $0.1 < $1.1 }) {
            lines.append(String(localized: "Next: \(next.0.name), \(fullTime(next.1, zoneID: next.0.recurrence.timeZoneID))"))
        } else if active.isEmpty {
            lines.append(String(localized: "All paused"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Groups

    /// Where a schedule's runs go, which the Scheduled panel groups by.
    enum Owner: Hashable {
        case bot(UUID)
        case thread(UUID)
        /// A project task: every run starts a new thread there.
        case project(UUID)
    }

    struct Group: Equatable {
        var owner: Owner
        var title: String
        var subtitle: String?
        var tasks: [ScheduledTask]
    }

    static func owner(of task: ScheduledTask, botOf: (UUID) -> UUID?) -> Owner {
        guard let threadID = task.threadID else { return .project(task.projectID) }
        return botOf(threadID).map(Owner.bot) ?? .thread(threadID)
    }

    /// Schedules grouped by bot, thread and project: the groups with the soonest run first, and inside each group, the
    /// soonest schedule first. `matches` filters schedules, as the panel's search and filter do.
    static func groups(
        _ tasks: [ScheduledTask], botOf: (UUID) -> UUID?, title: (Owner) -> (String, String?), matches: (ScheduledTask) -> Bool = { _ in true }
    ) -> [Group] {
        var byOwner: [Owner: [ScheduledTask]] = [:]
        var order: [Owner] = []
        for task in tasks where matches(task) {
            let owner = owner(of: task, botOf: botOf)
            if byOwner[owner] == nil { order.append(owner) }
            byOwner[owner, default: []].append(task)
        }
        let groups = order.map { owner in
            let (heading, subtitle) = title(owner)
            return Group(owner: owner, title: heading, subtitle: subtitle, tasks: byOwner[owner, default: []].sorted(by: ScheduledTasks.soonestFirst))
        }
        func soonest(_ group: Group) -> Date { group.tasks.first.flatMap { $0.isActive ? $0.nextRunAt : nil } ?? .distantFuture }
        return groups.sorted { lhs, rhs in
            let left = soonest(lhs), right = soonest(rhs)
            return left == right ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending : left < right
        }
    }

    /// Whether a schedule matches the panel's search: its name, prompt, schedule or where it runs.
    static func matches(_ task: ScheduledTask, query: String, place: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [task.name, task.prompt, task.recurrence.summary, place].contains { $0.localizedStandardContains(query) }
    }
}

/// What the Scheduled panel lists.
enum ScheduleFilter: String, CaseIterable {
    case all, active, paused, attention

    var title: String {
        switch self {
        case .all: String(localized: "All Schedules")
        case .active: String(localized: "Active")
        case .paused: String(localized: "Paused")
        case .attention: String(localized: "Needs Attention")
        }
    }

    func includes(_ task: ScheduledTask) -> Bool {
        switch self {
        case .all: true
        case .active: task.isActive
        case .paused: task.isPaused
        case .attention:
            task.isAwaitingApproval || task.proposal != nil || task.pauseReason != nil || task.lastOutcome == .failed
                || task.lastOutcome == .missed
        }
    }
}
