import Foundation

/// What an agent asks of its thread's `coincide_schedule` capability. The thread always comes from the capability's
/// grant, never from the request, so one thread can't name another's schedules.
public enum ScheduleRequest: Sendable, Equatable {
    case list
    case create(name: String, prompt: String, schedule: JSONValue)
    case update(id: UUID, name: String?, prompt: String?, schedule: JSONValue?)
    case pause(UUID)
    case resume(UUID)
    case delete(UUID)
    case runNow(UUID)

    /// The longest name and prompt an agent may give a schedule.
    public static let maximumNameLength = 200
    public static let maximumPromptBytes = 20_000

    public init(json: JSONValue) throws(ScheduleError) {
        guard let object = json.object, let action = object["action"]?.string else {
            throw .invalidRequest("Send a JSON object with an action.")
        }
        func only(_ keys: Set<String>) throws(ScheduleError) {
            let unknown = Set(object.keys).subtracting(keys.union(["action"]))
            guard unknown.isEmpty else {
                throw .invalidRequest("Unknown fields: \(unknown.sorted().joined(separator: ", ")).")
            }
        }
        func id() throws(ScheduleError) -> UUID {
            guard let text = object["id"]?.string, let id = UUID(uuidString: text) else {
                throw .invalidRequest("Give the schedule's id, as list returns it.")
            }
            return id
        }
        func text(_ key: String, limit: Int) throws(ScheduleError) -> String? {
            guard let value = object[key] else { return nil }
            guard let text = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.utf8.count <= limit else {
                throw .invalidRequest("“\(key)” must be text of at most \(limit) bytes.")
            }
            return text
        }
        switch action {
        case "list":
            try only([])
            self = .list
        case "create":
            try only(["name", "prompt", "schedule"])
            guard let name = try text("name", limit: Self.maximumNameLength), let prompt = try text("prompt", limit: Self.maximumPromptBytes),
                let schedule = object["schedule"]
            else { throw .invalidRequest("create needs name, prompt and schedule.") }
            self = .create(name: name, prompt: prompt, schedule: schedule)
        case "update":
            try only(["id", "name", "prompt", "schedule"])
            let name = try text("name", limit: Self.maximumNameLength), prompt = try text("prompt", limit: Self.maximumPromptBytes)
            guard name != nil || prompt != nil || object["schedule"] != nil else {
                throw .invalidRequest("update needs id and at least one of name, prompt and schedule.")
            }
            self = .update(id: try id(), name: name, prompt: prompt, schedule: object["schedule"])
        case "pause", "resume", "delete", "run-now", "run_now", "runNow":
            try only(["id"])
            let id = try id()
            switch action {
            case "pause": self = .pause(id)
            case "resume": self = .resume(id)
            case "delete": self = .delete(id)
            default: self = .runNow(id)
            }
        default:
            throw .invalidRequest("Unknown action “\(action)”. Use list, create, update, pause, resume, delete or run-now.")
        }
    }
}

// MARK: - Agent-facing schedules

extension TaskRecurrence {
    private static let dayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// Reads an agent's `schedule` object: `kind` and its fields, with an optional IANA `timeZone` (the user's by default).
    public init(spec: JSONValue, now: Date, defaultTimeZone: TimeZone) throws(ScheduleError) {
        guard let object = spec.object, let kindName = object["kind"]?.string else {
            throw .invalidRequest("schedule must be an object with a kind.")
        }
        var zone = defaultTimeZone
        if let name = object["timeZone"] {
            guard let identifier = name.string, let named = TimeZone(identifier: identifier) else {
                throw .invalidRequest("timeZone must be an IANA time zone such as Europe/Paris.")
            }
            zone = named
        }
        func only(_ keys: Set<String>) throws(ScheduleError) {
            let unknown = Set(object.keys).subtracting(keys.union(["kind", "timeZone"]))
            guard unknown.isEmpty else {
                throw .invalidRequest("Unknown schedule fields: \(unknown.sorted().joined(separator: ", ")).")
            }
        }
        func time() throws(ScheduleError) -> (Int, Int) {
            let parts = object["time"]?.string?.split(separator: ":").map { Int($0) } ?? []
            guard parts.count == 2, let hour = parts[0], let minute = parts[1], (0...23).contains(hour), (0...59).contains(minute) else {
                throw .invalidRequest("time must be 24-hour HH:MM, such as 09:30.")
            }
            return (hour, minute)
        }
        func day(_ value: JSONValue?) throws(ScheduleError) -> Int {
            let name = value?.string?.lowercased() ?? ""
            guard name.count >= 3, let index = Self.dayNames.firstIndex(where: { $0.hasPrefix(name) }) else {
                throw .invalidRequest("Name days in English, such as monday or mon.")
            }
            return index + 1
        }
        let zoneID = zone.identifier
        switch kindName {
        case "once":
            try only(["at", "inMinutes"])
            let date: Date
            if let minutes = object["inMinutes"]?.exactInt, object["at"] == nil {
                guard (1...525_600).contains(minutes) else { throw .invalidRequest("inMinutes must be 1 to 525600.") }
                date = now.addingTimeInterval(TimeInterval(minutes * 60))
            } else if let text = object["at"]?.string, object["inMinutes"] == nil, let parsed = Self.date(text, in: zone) {
                date = parsed
            } else {
                throw .invalidRequest("once needs at (such as 2026-11-02T09:00, in the schedule's time zone) or inMinutes.")
            }
            guard date > now else { throw .pastDate }
            self.init(kind: .once, timeZoneID: zoneID, date: date)
        case "daily", "weekdays":
            try only(["time"])
            let (hour, minute) = try time()
            self.init(kind: kindName == "daily" ? .daily : .weekdays, timeZoneID: zoneID, hour: hour, minute: minute)
        case "weekly":
            try only(["time", "day"])
            let (hour, minute) = try time()
            self.init(kind: .weekly, timeZoneID: zoneID, hour: hour, minute: minute, weekday: try day(object["day"]))
        case "days":
            try only(["time", "days"])
            let (hour, minute) = try time()
            guard let names = object["days"]?.array, !names.isEmpty, names.count <= 7 else {
                throw .invalidRequest("days must list one to seven days, such as [\"mon\", \"thu\"].")
            }
            var days: [Int] = []
            for name in names { days.append(try day(name)) }
            self.init(kind: .days, timeZoneID: zoneID, hour: hour, minute: minute, weekdays: Array(Set(days)).sorted())
        case "interval":
            try only(["minutes", "hours"])
            let minutes: Int
            switch (object["minutes"]?.exactInt, object["hours"]?.exactInt) {
            case (let value?, nil): minutes = value
            case (nil, let value?): minutes = value * 60
            default: throw .invalidRequest("interval needs minutes or hours.")
            }
            guard (Self.minimumIntervalMinutes...Self.maximumIntervalMinutes).contains(minutes) else {
                throw .invalidRequest("Repeat every 5 minutes to 31 days.")
            }
            self.init(kind: .interval, timeZoneID: zoneID, date: now.addingTimeInterval(TimeInterval(minutes * 60)), intervalMinutes: minutes)
        case "cron":
            try only(["expression"])
            guard let expression = object["expression"]?.string else {
                throw .invalidRequest("cron needs expression, such as \"0 9 * * 1-5\".")
            }
            do { _ = try CronExpression(expression) } catch { throw .invalidRequest(error.localizedDescription) }
            self.init(kind: .cron, timeZoneID: zoneID, cron: expression.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            throw .invalidRequest("Unknown schedule kind “\(kindName)”. Use once, daily, weekly, weekdays, days, interval or cron.")
        }
        if let error = validationError { throw .invalidRequest(error) }
    }

    /// A date and time with an offset, or a local one read in `zone`.
    static func date(_ text: String, in zone: TimeZone) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = options
            if let date = iso.date(from: trimmed) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// The agent-facing shape `init(spec:)` reads.
    public var spec: JSONValue {
        let time = String(format: "%02d:%02d", hour, minute)
        var object: [String: JSONValue] = ["kind": .string(kind.rawValue), "timeZone": .string(timeZoneID)]
        switch kind {
        case .once: object["at"] = .string(Self.isoString(date, zoneID: timeZoneID))
        case .daily, .weekdays: object["time"] = .string(time)
        case .weekly:
            object["time"] = .string(time)
            object["day"] = .string(Self.dayNames[(weekday - 1 + 7) % 7])
        case .days:
            object["time"] = .string(time)
            object["days"] = .array((weekdays ?? []).sorted().map { .string(Self.dayNames[($0 - 1 + 7) % 7]) })
        case .interval: object["minutes"] = .number(Double(intervalMinutes ?? 0))
        case .cron: object["expression"] = .string(cron ?? "")
        }
        return .object(object)
    }

    static func isoString(_ date: Date, zoneID: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: zoneID) ?? .current
        return iso.string(from: date)
    }
}

// MARK: - Descriptions

extension TaskRecurrence {
    /// A sentence for the schedule, such as "Weekdays at 9:00", in the user's language and the schedule's time zone.
    public var summary: String {
        let zone = TimeZone(identifier: timeZoneID) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = .current
        let time = Self.time(hour: hour, minute: minute, zone: zone)
        switch kind {
        case .once:
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.timeZone = zone
            return String(localized: "Once, \(formatter.string(from: date))")
        case .daily: return String(localized: "Every day at \(time)")
        case .weekly:
            let day = calendar.weekdaySymbols[(weekday - 1 + 7) % 7]
            return String(localized: "Every \(day) at \(time)")
        case .weekdays: return String(localized: "Weekdays at \(time)")
        case .days:
            // In the order of the user's week.
            let first = calendar.firstWeekday
            let days = (weekdays ?? []).sorted { ($0 - first + 7) % 7 < ($1 - first + 7) % 7 }
            let names = days.map { calendar.shortWeekdaySymbols[($0 - 1 + 7) % 7] }
            let list = ListFormatter.localizedString(byJoining: names)
            return String(localized: "\(list) at \(time)")
        case .interval:
            let minutes = intervalMinutes ?? 0
            if minutes % 1440 == 0 {
                let days = minutes / 1440
                return days == 1 ? String(localized: "Every 24 hours") : String(localized: "Every \(days) days")
            }
            if minutes % 60 == 0 {
                let hours = minutes / 60
                return hours == 1 ? String(localized: "Every hour") : String(localized: "Every \(hours) hours")
            }
            return String(localized: "Every \(minutes) minutes")
        case .cron: return String(localized: "Custom schedule: \(cron ?? "")")
        }
    }

    /// `hour`:`minute` the way the user's locale writes a time.
    static func time(hour: Int, minute: Int, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)) ?? Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = zone
        return formatter.string(from: date)
    }
}
