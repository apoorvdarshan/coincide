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
            credits: credits(main?["credits"]), modelWindows: modelWindows)
    }

    /// The plan's name, or nil for one Codex does not know.
    nonisolated static func plan(_ type: String) -> String? {
        type.isEmpty || type == "unknown" ? nil : type
    }

    nonisolated static func credits(_ value: JSONValue?) -> UsageCredits? {
        guard let value, value.object != nil, let hasCredits = value["hasCredits"]?.bool else { return nil }
        let balance = value["balance"]?.string?.trimmedNonEmpty ?? value["balance"]?.number.map { $0.formatted() }
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
