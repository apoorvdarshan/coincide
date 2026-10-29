import Foundation

/// How a usage window reads in the composer, following T3 Code's usage limits: bars show what is left,
/// the reset time counts down, and the pace compares spending with how much of the window has passed.
extension UsageLimitWindow {
    /// Spending compared with the time that has passed in the window.
    public enum Pace: Sendable, Hashable {
        /// Spending faster than the window elapses.
        case ahead
        case onPace
        /// Headroom left for the rest of the window.
        case under
    }

    /// Used from this percentage on, the composer warns that the limit is near.
    public nonisolated static let warningPercent: Double = 90

    /// Whole percent of the window left.
    public nonisolated var remainingPercent: Int { Int((100 - usedPercent).rounded()) }

    public nonisolated var isExhausted: Bool { usedPercent >= 100 }

    /// Used up with nothing to fall back on, so the agent can't work until the window resets.
    public nonisolated var blocksWork: Bool { isExhausted && !continuesOnCredits }

    public nonisolated var isNearLimit: Bool { usedPercent >= Self.warningPercent }

    /// How much of the window has passed, 0–1, when its length and reset time are known.
    public nonisolated func elapsedShare(at now: Date) -> Double? {
        guard let resetsAt, let durationMinutes, durationMinutes > 0 else { return nil }
        let length = Double(durationMinutes) * 60
        return min(1, max(0, (length - resetsAt.timeIntervalSince(now)) / length))
    }

    /// T3's reading: more than five points either side of even spending is ahead of or under pace.
    public nonisolated func pace(at now: Date) -> Pace? {
        guard let elapsed = elapsedShare(at: now) else { return nil }
        let gap = usedPercent - elapsed * 100
        if gap > 5 { return .ahead }
        if gap < -5 { return .under }
        return .onPace
    }

    /// "resets in 2h 5m", or nil without a reset time.
    public nonisolated func resetDescription(at now: Date) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return String(localized: "resets now") }
        if remaining < 60 { return String(localized: "resets momentarily") }
        return String(localized: "resets in \(Self.duration(remaining))")
    }

    /// "2d 3h", "4h 10m" or "12m", rounded down like T3's countdowns.
    public nonisolated static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        let days = minutes / (24 * 60)
        let hours = minutes % (24 * 60) / 60
        if days > 0 { return String(localized: "\(days)d \(hours)h") }
        if hours > 0 { return String(localized: "\(hours)h \(minutes % 60)m") }
        return String(localized: "\(minutes)m")
    }
}

extension UsageLimits {
    /// The windows as they stand at `now`: one whose reset time has passed starts over, until the agent reports
    /// it again.
    public nonisolated func current(at now: Date) -> UsageLimits {
        func current(_ window: UsageLimitWindow) -> UsageLimitWindow {
            guard let resetsAt = window.resetsAt, resetsAt <= now else { return window }
            var reset = window
            reset.usedPercent = 0
            reset.resetsAt = nil
            return reset
        }
        var limits = with(windows: windows.map(current), checkedAt: checkedAt)
        limits.modelWindows = modelWindows.map(current)
        limits.figures = figures.map { $0.current(at: now) }
        return limits
    }

    /// The window to warn about: an exhausted one that resets last (all of them must reset before work can go on),
    /// preferring one that stops work over one the agent continues past on credits, otherwise the fullest one at
    /// or past the warning level.
    public nonisolated var warning: UsageLimitWindow? {
        let blocking = windows.filter(\.blocksWork)
        let exhausted = blocking.isEmpty ? windows.filter(\.isExhausted) : blocking
        if !exhausted.isEmpty {
            return exhausted.max { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
        }
        return windows.filter(\.isNearLimit).max { $0.usedPercent < $1.usedPercent }
    }

    /// One line for VoiceOver and tooltips: "Session: 62% left, resets in 2h 5m. Weekly: 80% left."
    public nonisolated func summary(at now: Date) -> String {
        windows.map { window in
            let left = String(localized: "\(window.label): \(window.remainingPercent)% left")
            guard let reset = window.resetDescription(at: now) else { return left }
            return left + ", " + reset
        }.joined(separator: ". ")
    }

    /// What the composer says about a window near or at its limit: how much is used, or how much is left when `mode`
    /// shows what is left. The two add up to 100, and neither reads as the limit reached before it is.
    public nonisolated static func warningText(
        for window: UsageLimitWindow, provider: ProviderKind, mode: UsageDisplayMode = .used, at now: Date
    ) -> String {
        let name = provider.displayName
        let limit = window.label.lowercased()
        if window.isExhausted, window.continuesOnCredits {
            if let resetsAt = window.resetsAt, resetsAt > now {
                return String(
                    localized: "\(name) \(limit) limit reached. Using credits until it resets in \(UsageLimitWindow.duration(resetsAt.timeIntervalSince(now))).")
            }
            return String(localized: "\(name) \(limit) limit reached. Using credits.")
        }
        if window.isExhausted {
            if let resetsAt = window.resetsAt, resetsAt > now {
                return String(
                    localized: "\(name) usage limit reached. The \(limit) limit resets in \(UsageLimitWindow.duration(resetsAt.timeIntervalSince(now))).")
            }
            return String(localized: "\(name) usage limit reached.")
        }
        let used = Int(window.usedPercent.rounded(.down))
        if mode == .remaining {
            let left = 100 - used
            if let resetsAt = window.resetsAt, resetsAt > now {
                return String(
                    localized: "\(left)% of your \(name) \(limit) limit is left. It resets in \(UsageLimitWindow.duration(resetsAt.timeIntervalSince(now))).")
            }
            return String(localized: "\(left)% of your \(name) \(limit) limit is left.")
        }
        if let resetsAt = window.resetsAt, resetsAt > now {
            return String(
                localized: "\(used)% of your \(name) \(limit) limit is used. It resets in \(UsageLimitWindow.duration(resetsAt.timeIntervalSince(now))).")
        }
        return String(localized: "\(used)% of your \(name) \(limit) limit is used.")
    }

    /// Identifies a warning, so dismissing it lasts until the window resets or gets worse.
    public nonisolated static func warningKey(for window: UsageLimitWindow, provider: ProviderKind) -> String {
        let stage = window.isExhausted ? (window.continuesOnCredits ? "credits" : "reached") : "near"
        let reset = window.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "-"
        return "\(provider.rawValue)/\(window.id)/\(stage)/\(reset)"
    }
}
