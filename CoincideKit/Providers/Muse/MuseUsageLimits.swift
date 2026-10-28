import Foundation

/// Muse's subscription usage (`usage/read` and `usage/changed`) and its quota refusals, following T3 Code's Muse
/// `protocol.ts` and `usageLimits.ts`.
struct MuseSubscriptionUsage: Equatable {
    struct Window: Equatable {
        /// Verbatim from Meta, so it may exceed 100.
        var usedPercent: Double
        var resetsAt: Date
        var durationMinutes: Int?
    }

    /// The provider's rolling usage block (about five hours) and the weekly one.
    var window: Window
    var weekly: Window

    /// The latest instant a JavaScript Date holds (T3's `LATEST_DATE_MS`); a later stamp is not a date.
    static let latestMilliseconds = 8.64e15

    /// Reads a `SubscriptionUsage` object; nil when any part is missing or out of range, as T3's schema rejects it.
    init?(_ value: JSONValue?) {
        guard let value, let window = Self.window(value["window"], needsDuration: true),
            let weekly = Self.window(value["weekly"], needsDuration: false)
        else { return nil }
        self.window = window
        self.weekly = weekly
    }

    init(window: Window, weekly: Window) {
        self.window = window
        self.weekly = weekly
    }

    private static func window(_ value: JSONValue?, needsDuration: Bool) -> Window? {
        guard let used = value?["usedPercent"]?.number, used.isFinite, used >= 0, let resets = date(value?["resetsAtMs"])
        else { return nil }
        let minutes = value?["windowDurationMins"]?.number
        if needsDuration { guard let minutes, minutes.isFinite, minutes > 0 else { return nil } }
        return Window(usedPercent: used, resetsAt: resets, durationMinutes: minutes.flatMap { Int(exactly: $0.rounded()) })
    }

    static func date(_ milliseconds: JSONValue?) -> Date? {
        guard let value = milliseconds?.number, value.isFinite, value > 0, value <= latestMilliseconds else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }

    /// The composer's usage windows: the rolling block as the session window, then the weekly one.
    var windows: [UsageLimitWindow] {
        let minutes = window.durationMinutes ?? 5 * 60
        let kind = CodexUsageLimits.kind(forMinutes: minutes)
        return [
            UsageLimitWindow(
                id: "window", kind: kind, label: CodexUsageLimits.label(for: kind), usedPercent: window.usedPercent,
                resetsAt: window.resetsAt, durationMinutes: minutes),
            UsageLimitWindow(
                id: "weekly", kind: .weekly, label: CodexUsageLimits.label(for: .weekly), usedPercent: weekly.usedPercent,
                resetsAt: weekly.resetsAt, durationMinutes: CodexUsageLimits.weekMinutes),
        ]
    }
}

enum MuseUsageLimits {
    /// A refusal for a used-up subscription. Credential proxies may leave `error.quota` out of a 429, so the text
    /// counts too (T3's `isMuseUsageLimitFailure`).
    static func isUsageLimitFailure(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.contains(/\b429\b/) && message.contains(/(?i)quota|usage limit/)
    }

    /// When work can go on after a quota stop: every used-up window must reset first, so the latest future reset of
    /// the usage report's exhausted windows, the refusal's `quota` and a reset its text names (T3's
    /// `museUsageLimitResetAt`). Nil when none lies ahead.
    static func resetDate(usage: MuseSubscriptionUsage?, now: Date, quotaReset: Date?, message: String?) -> Date? {
        var resets = [usage?.window, usage?.weekly].compactMap { window in
            window.flatMap { $0.usedPercent >= 100 ? $0.resetsAt : nil }
        }
        if let quotaReset { resets.append(quotaReset) }
        if let named = namedReset(in: message) { resets.append(named) }
        let latest = Date(timeIntervalSince1970: MuseSubscriptionUsage.latestMilliseconds / 1000)
        return resets.filter { $0 > now && $0 <= latest }.max()
    }

    /// The time in "… resets at 2026-10-13T10:45:52Z" of a refusal relayed through a proxy.
    static func namedReset(in message: String?) -> Date? {
        guard let message,
            let match = message.firstMatch(
                of: /(?i)\bresets at (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))/)
        else { return nil }
        let text = String(match.output.1)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// What a failed turn shows for a quota stop: when the limit resets, if known, and Muse's own words.
    static func failureMessage(detail: String?, resetsAt: Date?) -> String {
        let summary =
            resetsAt.map {
                String(localized: "Muse Code usage limit reached. It resets \($0.formatted(date: .abbreviated, time: .shortened)).")
            } ?? String(localized: "Muse Code usage limit reached. Try again later.")
        guard let detail = TerminalText.nonEmpty(detail) else { return summary }
        return summary + "\n\n" + detail
    }
}
