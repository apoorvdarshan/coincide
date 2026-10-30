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
        // Unlike a balance alone, this is Claude explicitly reporting that the turn is using extra usage.
        if info["isUsingOverage"]?.bool == true, info["overageStatus"]?.string != "rejected",
            info["overageDisabledReason"]?.string?.trimmedNonEmpty == nil {
            for index in windows.indices { windows[index].continuesOnCredits = true }
        }
        return windows
    }

    /// The windows of a `get_usage` answer, whose percentages run from 0 to 100. Nil when Claude Code has no
    /// plan limits to report (an API key, say).
    nonisolated static func windows(fromUsage response: JSONValue) -> [UsageLimitWindow]? {
        guard response["rate_limits_available"]?.bool == true, let limits = response["rate_limits"], limits.object != nil
        else { return nil }
        var windows: [UsageLimitWindow] = []
        let canUseExtraUsage = extraUsageAvailable(limits)
        for bucket in ["five_hour", "seven_day"] {
            guard let value = limits[bucket], let utilization = value["utilization"]?.number, utilization.isFinite,
                var window = window(bucket, usedPercent: utilization, resetsAt: date(fromISO: value["resets_at"]?.string))
            else { continue }
            window.continuesOnCredits = canUseExtraUsage
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

    /// The amounts a `get_usage` answer reports besides its percentages: extra usage spent this period against its cap
    /// (in minor units of its currency, cents for USD), the spend budget, and dollar allowances such as promotional
    /// cloud credits. Empty when Claude Code has no plan limits to report.
    nonisolated static func figures(fromUsage response: JSONValue) -> [UsageFigure] {
        guard response["rate_limits_available"]?.bool == true, let limits = response["rate_limits"], limits.object != nil
        else { return [] }
        var figures: [UsageFigure] = []
        // The period's end is the reset time of the active spend row in `limits`, as Claude Code pairs them.
        let spendRows = (limits["limits"]?.array ?? []).filter { $0["kind"]?.string == "spend" }
        let spendReset = date(fromISO: (spendRows.first { $0["is_active"]?.bool == true } ?? spendRows.first)?["resets_at"]?.string)
        if let extra = limits["extra_usage"], extra.object != nil {
            let currency = extra["currency"]?.string?.trimmedNonEmpty?.uppercased() ?? "USD"
            let scale = minorUnitScale(currency)
            if extra["is_enabled"]?.bool == true {
                figures.append(
                    UsageFigure(
                        id: "extra_usage", label: String(localized: "Extra usage"), unit: .currency(currency),
                        used: extra["used_credits"]?.number.map { $0 / scale }, limit: extra["monthly_limit"]?.number.map { $0 / scale },
                        resetsAt: spendReset, detail: extra["monthly_limit"]?.number == nil ? String(localized: "No cap") : nil))
            } else {
                figures.append(
                    UsageFigure(id: "extra_usage", label: String(localized: "Extra usage"), unit: .currency(currency), detail: String(localized: "Off")))
            }
        }
        if let spend = limits["spend"], spend["enabled"]?.bool == true, let used = spend["used"],
            let currency = used["currency"]?.string?.trimmedNonEmpty?.uppercased(), let usedMinor = used["amount_minor"]?.number
        {
            let exponent = used["exponent"]?.number ?? 2
            let limit = spend["limit"]
            let limitAmount =
                limit?["currency"]?.string?.uppercased() == currency
                ? limit?["amount_minor"]?.number.map { $0 / pow(10, limit?["exponent"]?.number ?? exponent) } : nil
            figures.append(
                UsageFigure(
                    id: "spend", label: String(localized: "Spend"), unit: .currency(currency), used: usedMinor / pow(10, exponent),
                    limit: limitAmount, resetsAt: spendReset))
        }
        // Dollar allowances, which the endpoint reports in whole dollars. Only named ones are shown: a label from the
        // answer, or the promotional cloud credits CodexBar knows by their bucket.
        for (bucket, value) in (limits.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard value.object != nil, let limit = value["limit_dollars"]?.number, limit.isFinite, limit > 0,
                let label = value["label"]?.string?.trimmedNonEmpty ?? (bucket == "iguana_necktie" ? String(localized: "Cloud credits") : nil)
            else { continue }
            var used = value["used_dollars"]?.number
            let remaining = value["remaining_dollars"]?.number
            if used == nil, remaining == nil, let utilization = value["utilization"]?.number, utilization.isFinite {
                used = limit * min(100, max(0, utilization)) / 100
            }
            // Promotional credits end at their `resets_at` rather than start over.
            let end = date(fromISO: value["resets_at"]?.string)
            let expires = bucket == "iguana_necktie" && value["label"] == nil
            figures.append(
                UsageFigure(
                    id: bucket, label: label, unit: .currency("USD"), used: used, limit: limit, remaining: remaining,
                    resetsAt: expires ? nil : end, expiresAt: expires ? end : nil))
        }
        return figures
    }

    /// How many minor units make one unit of `currency`: 100 for USD, 1 for JPY.
    nonisolated static func minorUnitScale(_ currency: String) -> Double {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return pow(10, Double(formatter.maximumFractionDigits))
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

    /// Explicitly enabled extra usage with budget left (or the provider's uncapped setting). A balance or
    /// promotional credit bucket alone never enables overage, and an exhausted spend cap cannot be bypassed.
    private nonisolated static func extraUsageAvailable(_ limits: JSONValue) -> Bool {
        if let extra = limits["extra_usage"], let enabled = extra["is_enabled"]?.bool {
            guard enabled, extra["user_disabled"]?.bool != true else { return false }
            guard let cap = extra["monthly_limit"], !cap.isNull else { return true }
            guard let limit = cap.number, limit.isFinite, limit > 0 else { return false }
            if let used = extra["used_credits"]?.number { return used.isFinite && used >= 0 && used < limit }
            if let percent = extra["utilization"]?.number { return percent.isFinite && percent >= 0 && percent < 100 }
            return false
        }
        guard let spend = limits["spend"], spend["enabled"]?.bool == true else { return false }
        guard let cap = spend["limit"], !cap.isNull else { return true }
        guard let used = spend["used"], let usedAmount = used["amount_minor"]?.number,
            let limitAmount = cap["amount_minor"]?.number, usedAmount.isFinite, limitAmount.isFinite,
            usedAmount >= 0, limitAmount > usedAmount,
            let currency = used["currency"]?.string, !currency.isEmpty, currency == cap["currency"]?.string,
            used["exponent"]?.number == cap["exponent"]?.number else { return false }
        return true
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
