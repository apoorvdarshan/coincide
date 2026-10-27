import Foundation

/// Reads Claude Code's plan limits as usage windows, following T3 Code's `claudeUsageLimits`: the `get_usage`
/// control request when probing, and `rate_limit_event` frames while turns run.
enum ClaudeUsageLimits {
    nonisolated static let sessionMinutes = 5 * 60
    nonisolated static let weekMinutes = 7 * 24 * 60

    /// The plan's main windows, by Claude's bucket name.
    private nonisolated static func window(_ bucket: String, usedPercent: Double, resetsAt: Date?) -> UsageLimitWindow? {
        switch bucket {
        case "five_hour":
            UsageLimitWindow(
                id: bucket, kind: .session, label: String(localized: "Session"), usedPercent: usedPercent,
                resetsAt: resetsAt, durationMinutes: sessionMinutes)
        case "seven_day":
            UsageLimitWindow(
                id: bucket, kind: .weekly, label: String(localized: "Weekly"), usedPercent: usedPercent, resetsAt: resetsAt,
                durationMinutes: weekMinutes)
        default:
            nil
        }
    }

    /// A weekly limit of one model, such as "Weekly · Opus".
    private nonisolated static func scopedWindow(_ name: String, usedPercent: Double, resetsAt: Date?) -> UsageLimitWindow {
        let slug = name.lowercased().replacing(/[^a-z0-9]+/, with: "_")
        return UsageLimitWindow(
            id: "seven_day_\(slug)", kind: .weekly, label: String(localized: "Weekly · \(name)"), usedPercent: usedPercent,
            resetsAt: resetsAt, durationMinutes: weekMinutes)
    }

    /// The bucket Claude Code reports a model's own weekly limit under while turns run. It names no model: as in
    /// T3 Code, it is the first per-model window `get_usage` listed, and is left out until a check named it.
    nonisolated static let overageIncludedBucket = "seven_day_overage_included"

    /// The windows a `rate_limit_event` frame reports. Its utilization runs from 0 to 1. Newer Claude Code versions
    /// list every unified window; older ones name the one window the event is about. `overageIncludedName` is the
    /// model the overage-included bucket stands for (`overageIncludedName(fromUsage:)`).
    nonisolated static func windows(fromEvent frame: JSONValue, overageIncludedName: String? = nil) -> [UsageLimitWindow] {
        guard let info = frame["rate_limit_info"] else { return [] }
        func window(_ bucket: String, utilization: Double?, resetsAt: Double?) -> UsageLimitWindow? {
            guard let utilization, utilization.isFinite else { return nil }
            let reset = date(fromEpochSeconds: resetsAt)
            if bucket == overageIncludedBucket {
                return overageIncludedName.map { scopedWindow($0, usedPercent: utilization * 100, resetsAt: reset) }
            }
            return Self.window(bucket, usedPercent: utilization * 100, resetsAt: reset)
        }
        var windows: [UsageLimitWindow] = []
        var buckets: Set<String> = []
        for (bucket, value) in (info["unifiedWindows"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            buckets.insert(bucket)
            guard let window = window(bucket, utilization: value["utilization"]?.number, resetsAt: value["resetsAt"]?.number)
            else { continue }
            windows.append(window)
        }
        if let bucket = info["rateLimitType"]?.string, !buckets.contains(bucket),
            let window = window(bucket, utilization: info["utilization"]?.number, resetsAt: info["resetsAt"]?.number)
        {
            windows.append(window)
        }
        return windows
    }

    /// The windows of a `get_usage` answer, whose percentages run from 0 to 100. Nil when Claude Code has no
    /// plan limits to report (an API key, say).
    nonisolated static func windows(fromUsage response: JSONValue) -> [UsageLimitWindow]? {
        guard response["rate_limits_available"]?.bool == true, let limits = response["rate_limits"], limits.object != nil
        else { return nil }
        var windows: [UsageLimitWindow] = []
        for bucket in ["five_hour", "seven_day"] {
            guard let value = limits[bucket], let utilization = value["utilization"]?.number, utilization.isFinite,
                let window = window(bucket, usedPercent: utilization, resetsAt: date(fromISO: value["resets_at"]?.string))
            else { continue }
            windows.append(window)
        }
        // Per-model weekly limits, as T3 Code reads them: `model_scoped` lists the ones Claude Code shows (its
        // `limits` rows include ones it hides).
        for entry in modelScoped(limits) {
            windows.append(scopedWindow(entry.name, usedPercent: entry.utilization, resetsAt: date(fromISO: entry.resetsAt)))
        }
        if let spend = spendPercent(limits) {
            windows.append(UsageLimitWindow(id: "monthly_spend", kind: .monthly, label: String(localized: "Monthly spend"), usedPercent: spend))
        }
        return windows
    }

    /// The model `rate_limit_event`'s overage-included bucket stands for: the first per-model window of a `get_usage`
    /// answer (Claude Code allows overage for one model).
    nonisolated static func overageIncludedName(fromUsage response: JSONValue) -> String? {
        guard response["rate_limits_available"]?.bool == true, let limits = response["rate_limits"] else { return nil }
        return modelScoped(limits).first?.name
    }

    private nonisolated static func modelScoped(_ limits: JSONValue) -> [(name: String, utilization: Double, resetsAt: String?)] {
        (limits["model_scoped"]?.array ?? []).compactMap { entry in
            guard let name = entry["display_name"]?.string, !name.isEmpty, let utilization = entry["utilization"]?.number,
                utilization.isFinite
            else { return nil }
            return (name, utilization, entry["resets_at"]?.string)
        }
    }

    /// How much of the monthly spend budget is used, when one is on: from the amounts when they are in the same
    /// currency and scale (the reported percent is rounded), else from extra usage.
    private nonisolated static func spendPercent(_ limits: JSONValue) -> Double? {
        if let spend = limits["spend"], spend["enabled"]?.bool == true, let used = spend["used"], let limit = spend["limit"],
            let currency = used["currency"]?.string, !currency.isEmpty, currency == limit["currency"]?.string,
            used["exponent"]?.number == limit["exponent"]?.number,
            let percent = percent(used: used["amount_minor"]?.number, limit: limit["amount_minor"]?.number)
        {
            return percent
        }
        guard let extra = limits["extra_usage"], extra["is_enabled"]?.bool == true else { return nil }
        let percent =
            percent(used: extra["used_credits"]?.number, limit: extra["monthly_limit"]?.number) ?? extra["utilization"]?.number
        guard let percent, percent.isFinite, percent >= 0 else { return nil }
        return min(100, percent)
    }

    private nonisolated static func percent(used: Double?, limit: Double?) -> Double? {
        guard let used, let limit, used.isFinite, limit.isFinite, used >= 0, limit > 0 else { return nil }
        return min(100, used / limit * 100)
    }

    nonisolated static func date(fromEpochSeconds seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0, seconds < 8.64e12 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// `2026-10-27T14:10:00.340563+00:00`: Claude writes microseconds, which the system parser does not take,
    /// and a reset time needs no fraction of a second.
    nonisolated static func date(fromISO text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let whole = text.replacing(/\.\d+(?=(?:Z|[+-]\d{2}:?\d{2})$)/, with: "")
        return try? Date.ISO8601FormatStyle().parse(whole)
    }
}
