import Foundation

/// Reads Codex's rate-limit snapshots (`account/rateLimits/read` and `account/rateLimits/updated`) as usage
/// windows, following T3 Code's `codexUsageLimits`.
enum CodexUsageLimits {
    nonisolated static let sessionMinutes = 5 * 60
    nonisolated static let weekMinutes = 7 * 24 * 60
    nonisolated static let monthMinutes = 30 * 24 * 60

    /// The windows of a snapshot. `primary` and `secondary` are positions, not lengths: without a reported
    /// length, paid plans use a five-hour and a weekly window and Free and Go a monthly one. Snapshots of a
    /// model's own limit (another `limitId`) are left out of the main allowance.
    nonisolated static func windows(from snapshot: JSONValue?) -> [UsageLimitWindow] {
        guard let snapshot, snapshot.object != nil else { return [] }
        if let limitID = snapshot["limitId"]?.string, limitID != "codex" { return [] }
        return windows(ofBucket: snapshot)
    }

    /// The windows of one bucket's snapshot, whichever limit it is.
    private nonisolated static func windows(ofBucket snapshot: JSONValue) -> [UsageLimitWindow] {
        let monthlyPlan = ["free", "go"].contains(snapshot["planType"]?.string ?? "")
        // With credits on the account, Codex keeps working past the plan's windows and spends credits.
        let credits = snapshot["credits"]
        let continuesOnCredits = credits?["unlimited"]?.bool == true || credits?["hasCredits"]?.bool == true
        var windows: [UsageLimitWindow] = []
        for (id, fallback) in [("primary", monthlyPlan ? monthMinutes : sessionMinutes), ("secondary", weekMinutes)] {
            guard let window = snapshot[id], let used = window["usedPercent"]?.number, used.isFinite else { continue }
            let minutes = window["windowDurationMins"]?.int ?? fallback
            let kind = kind(forMinutes: minutes)
            windows.append(
                UsageLimitWindow(
                    id: id, kind: kind, label: label(for: kind), usedPercent: used,
                    resetsAt: date(fromEpochSeconds: window["resetsAt"]?.number), durationMinutes: minutes,
                    continuesOnCredits: continuesOnCredits))
        }
        if let individual = snapshot["individualLimit"], let remaining = individual["remainingPercent"]?.number,
            remaining.isFinite
        {
            windows.append(
                UsageLimitWindow(
                    id: "individual", kind: .monthly, label: String(localized: "Monthly credit limit"),
                    usedPercent: 100 - remaining, resetsAt: date(fromEpochSeconds: individual["resetsAt"]?.number)))
        }
        return windows
    }

    /// The windows of an `account/rateLimits/read` result: the `codex` bucket when Codex lists buckets,
    /// otherwise its single-bucket view.
    nonisolated static func windows(fromRead result: JSONValue) -> [UsageLimitWindow] {
        windows(from: mainSnapshot(fromRead: result))
    }

    private nonisolated static func mainSnapshot(fromRead result: JSONValue) -> JSONValue? {
        let codex = result.at("rateLimitsByLimitId.codex")
        return codex?.object != nil ? codex : result["rateLimits"]
    }

    /// Everything an `account/rateLimits/read` result tells: the main windows, the plan, the credits and the limits of
    /// single models that Codex lists as buckets of their own (as CodexBar shows Codex Spark's).
    nonisolated static func limits(fromRead result: JSONValue, at date: Date) -> UsageLimits {
        let main = mainSnapshot(fromRead: result)
        var modelWindows: [UsageLimitWindow] = []
        let buckets = (result["rateLimitsByLimitId"]?.object ?? [:]).sorted { $0.key < $1.key }
        for (id, bucket) in buckets where id != "codex" && bucket.object != nil {
            let name = bucket["limitName"]?.string?.trimmedNonEmpty ?? bucket["normalModelSlug"]?.string?.trimmedNonEmpty ?? id
            for var window in windows(ofBucket: bucket) where window.id != "individual" {
                window.id = id + "/" + window.id
                window.label = String(localized: "\(name) · \(window.label)")
                window.continuesOnCredits = false
                modelWindows.append(window)
            }
        }
        return UsageLimits(
            windows: windows(from: main), checkedAt: date, plan: main?["planType"]?.string.flatMap(plan),
            credits: credits(main?["credits"]), modelWindows: modelWindows, figures: figures(fromRead: result),
            notes: notes(fromRead: result))
    }

    /// The amounts a read reports besides its percentages: the workspace's credit limit for this member, used against
    /// its cap, and the rate-limit resets the account may redeem.
    nonisolated static func figures(fromRead result: JSONValue) -> [UsageFigure] {
        var figures: [UsageFigure] = []
        if let individual = mainSnapshot(fromRead: result)?["individualLimit"], individual.object != nil {
            func amount(_ key: String) -> Double? { individual[key]?.string.flatMap { Double($0) } ?? individual[key]?.number }
            let limit = amount("limit")
            let used = amount("used")
            if limit != nil || used != nil {
                figures.append(
                    UsageFigure(
                        id: "individual", label: String(localized: "Credit limit"), unit: .credits, used: used, limit: limit,
                        resetsAt: date(fromEpochSeconds: individual["resetsAt"]?.number)))
            }
        }
        if let resets = result["rateLimitResetCredits"], let count = resets["availableCount"]?.number, count.isFinite, count > 0 {
            let expiries = (resets["credits"]?.array ?? []).filter { ($0["status"]?.string ?? "available") == "available" }
                .compactMap { date(fromEpochSeconds: $0["expiresAt"]?.number) }
            figures.append(
                UsageFigure(
                    id: "reset_credits", label: String(localized: "Limit resets available"), unit: .count, remaining: count,
                    expiresAt: expiries.min()))
        }
        return figures
    }

    /// Why Codex may stop although its windows have room: a workspace out of credits or past its spend control.
    nonisolated static func notes(fromRead result: JSONValue) -> [String] {
        let main = mainSnapshot(fromRead: result)
        var notes: [String] = []
        switch main?["rateLimitReachedType"]?.string {
        case "workspace_owner_credits_depleted"?, "workspace_member_credits_depleted"?:
            notes.append(String(localized: "The workspace is out of credits."))
        case "workspace_owner_usage_limit_reached"?, "workspace_member_usage_limit_reached"?:
            notes.append(String(localized: "The workspace’s usage limit is reached."))
        default:
            if main?["spendControlReached"]?.bool == true {
                notes.append(String(localized: "The workspace’s spend control is reached."))
            }
        }
        return notes
    }

    /// The plan's name, or nil for one Codex does not know.
    nonisolated static func plan(_ type: String) -> String? {
        type.isEmpty || type == "unknown" ? nil : type
    }

    nonisolated static func credits(_ value: JSONValue?) -> UsageCredits? {
        guard let value, value.object != nil, let hasCredits = value["hasCredits"]?.bool else { return nil }
        let balance = value["balance"]?.string?.trimmedNonEmpty ?? value["balance"]?.number.map { String($0) }
        return UsageCredits(hasCredits: hasCredits, unlimited: value["unlimited"]?.bool ?? false, balance: balance)
    }

    nonisolated static func kind(forMinutes minutes: Int) -> UsageLimitWindow.Kind {
        if minutes >= monthMinutes { return .monthly }
        if minutes >= weekMinutes { return .weekly }
        return .session
    }

    nonisolated static func label(for kind: UsageLimitWindow.Kind) -> String {
        switch kind {
        case .session: String(localized: "Session")
        case .weekly: String(localized: "Weekly")
        case .monthly: String(localized: "Monthly")
        case .other: String(localized: "Other")
        }
    }

    nonisolated static func date(fromEpochSeconds seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0, seconds < 8.64e12 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
