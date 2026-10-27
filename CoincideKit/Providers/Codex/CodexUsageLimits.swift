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
        let monthlyPlan = ["free", "go"].contains(snapshot["planType"]?.string ?? "")
        var windows: [UsageLimitWindow] = []
        for (id, fallback) in [("primary", monthlyPlan ? monthMinutes : sessionMinutes), ("secondary", weekMinutes)] {
            guard let window = snapshot[id], let used = window["usedPercent"]?.number, used.isFinite else { continue }
            let minutes = window["windowDurationMins"]?.int ?? fallback
            let kind = kind(forMinutes: minutes)
            windows.append(
                UsageLimitWindow(
                    id: id, kind: kind, label: label(for: kind), usedPercent: used,
                    resetsAt: date(fromEpochSeconds: window["resetsAt"]?.number), durationMinutes: minutes))
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
        windows(from: result.at("rateLimitsByLimitId.codex") ?? result["rateLimits"])
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
