import Foundation

/// T3's duration labels: `formatDuration` for finished work and
/// `formatElapsedSeconds` for a live timer.
public enum TranscriptDuration {
    public static func format(_ seconds: TimeInterval) -> String {
        let milliseconds = seconds * 1_000
        guard milliseconds.isFinite, milliseconds >= 0 else { return "0ms" }
        if milliseconds < 1_000 { return "\(max(1, Int(milliseconds.rounded())))ms" }
        if milliseconds < 10_000 {
            let tenths = (milliseconds / 100).rounded() / 10
            return tenths >= 10 ? "10s" : String(format: "%.1fs", tenths)
        }
        // Round first so 59.5 seconds never renders as "60s".
        guard let total = Int(exactly: (milliseconds / 1_000).rounded()) else { return "0ms" }
        if total < 60 { return "\(total)s" }
        let hours = total / 3_600, minutes = (total % 3_600) / 60, rest = total % 60
        return [hours > 0 ? "\(hours)h" : nil, minutes > 0 ? "\(minutes)m" : nil, rest > 0 ? "\(rest)s" : nil].compactMap { $0 }.joined(separator: " ")
    }

    public static func elapsed(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(exactly: seconds.rounded(.down)) ?? 0) : 0
        let minutes = total / 60
        if minutes == 0 { return "\(total)s" }
        let hours = minutes / 60
        if hours == 0 { return "\(minutes)m " + String(format: "%02ds", total % 60) }
        return "\(hours)h " + String(format: "%02dm", minutes % 60)
    }
}

/// Bounded windows over tool output so a multi-megabyte log never reaches a
/// single `Text`. Only the window's bytes are scanned.
public enum TranscriptOutputTail {
    public static func head(_ text: String, maxLines: Int = 200, maxBytes: Int = 65_536) -> (text: String, truncated: Bool) {
        guard maxLines > 0, maxBytes > 0 else { return ("", !text.isEmpty) }
        let utf8 = text.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: maxBytes, limitedBy: utf8.endIndex) ?? utf8.endIndex
        var truncated = end != utf8.endIndex
        var lines = 0, cursor = utf8.startIndex
        while cursor < end {
            if utf8[cursor] == UInt8(ascii: "\n") { lines += 1; if lines == maxLines { end = cursor; truncated = utf8.index(after: cursor) < utf8.endIndex; break } }
            cursor = utf8.index(after: cursor)
        }
        while end > utf8.startIndex, end < utf8.endIndex, UTF8.isContinuation(utf8[end]) { end = utf8.index(before: end) }
        return (String(decoding: utf8[utf8.startIndex..<end], as: UTF8.self), truncated)
    }

    public static func tail(_ text: String, maxLines: Int = 200, maxBytes: Int = 65_536) -> (text: String, truncated: Bool) {
        guard maxLines > 0, maxBytes > 0 else { return ("", !text.isEmpty) }
        let utf8 = text.utf8
        var start = utf8.index(utf8.endIndex, offsetBy: -maxBytes, limitedBy: utf8.startIndex) ?? utf8.startIndex
        var truncated = start != utf8.startIndex
        while start < utf8.endIndex, start > utf8.startIndex, UTF8.isContinuation(utf8[start]) { start = utf8.index(after: start) }
        var lines = 0, cursor = utf8.endIndex
        // A trailing newline does not start an extra visible line.
        if cursor > start, utf8[utf8.index(before: cursor)] == UInt8(ascii: "\n") { cursor = utf8.index(before: cursor) }
        while cursor > start {
            let previous = utf8.index(before: cursor)
            if utf8[previous] == UInt8(ascii: "\n") { lines += 1; if lines == maxLines { start = cursor; truncated = true; break } }
            cursor = previous
        }
        return (String(decoding: utf8[start..<utf8.endIndex], as: UTF8.self), truncated)
    }
}

/// T3 collapses user messages longer than 8 lines or 600 visible characters.
/// Markdown link syntax counts as its visible label.
public enum TranscriptUserMessageCollapse {
    public static let maximumLines = 8
    public static let maximumCharacters = 600

    public static func shouldCollapse(_ text: String) -> Bool {
        let visible = visibleText(text)
        guard !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return visible.count > maximumCharacters || visible.split(separator: "\n", omittingEmptySubsequences: false).count > maximumLines
    }

    private static let link = try! NSRegularExpression(pattern: #"!?\[([^\]\n]*)\]\((?:<[^>\n]*>|[^\s)]*)\)"#)

    static func visibleText(_ text: String) -> String {
        guard text.contains("](") else { return text }
        return link.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }
}

/// Proposed plan text helpers matching T3's `proposedPlan.ts`.
public enum TranscriptPlanText {
    public static func title(_ plan: String) -> String? {
        for line in plan.split(whereSeparator: \.isNewline) {
            if let heading = heading(String(line)) { return heading }
        }
        return nil
    }
    /// Drops a leading title heading and a following "Summary" heading.
    public static func displayed(_ plan: String) -> String {
        var lines = trimmedEnd(plan).components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if let first = lines.first, heading(first) != nil { lines.removeFirst() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        if let first = lines.first, heading(first)?.lowercased() == "summary" {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        }
        return lines.joined(separator: "\n")
    }
    public static func canCollapse(_ plan: String) -> Bool {
        plan.count > 900 || plan.components(separatedBy: "\n").count > 20
    }
    public static func collapsedPreview(_ plan: String, maxLines: Int = 10) -> String {
        var preview: [String] = [], visible = 0, more = false
        for line in trimmedEnd(displayed(plan)).components(separatedBy: "\n").map(trimmedEnd) {
            let isVisible = !line.trimmingCharacters(in: .whitespaces).isEmpty
            if isVisible, visible >= maxLines { more = true; break }
            preview.append(line); if isVisible { visible += 1 }
        }
        while preview.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { preview.removeLast() }
        if preview.isEmpty { return title(plan) ?? String(localized: "Plan preview unavailable.") }
        if more { preview += ["", "..."] }
        return preview.joined(separator: "\n")
    }
    public static func filename(_ plan: String) -> String {
        let source = (title(plan) ?? "plan").lowercased().filter { !"`'\".,!?()[]{}".contains($0) }
        var slug = "", dash = false
        for scalar in source.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) { slug.unicodeScalars.append(scalar); dash = false }
            else if !dash, !slug.isEmpty { slug.append("-"); dash = true }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return (slug.isEmpty ? "plan" : String(slug.prefix(80))) + ".md"
    }
    public static func exportContents(_ plan: String) -> String { trimmedEnd(plan) + "\n" }
    public static func implementationPrompt(_ plan: String) -> String {
        "PLEASE IMPLEMENT THIS PLAN:\n" + plan.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func heading(_ line: String) -> String? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent), hashes = rest.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), rest.dropFirst(hashes).first == " " || rest.dropFirst(hashes).first == "\t" else { return nil }
        let text = rest.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
    static func trimmedEnd(_ text: String) -> String {
        var value = Substring(text)
        while let last = value.last, last.isWhitespace { value = value.dropLast() }
        return String(value)
    }
}

/// A one-line preview of streaming reasoning: the newest bold `**Heading**`
/// when the provider writes summary headings, otherwise the newest non-empty
/// line with inline Markdown markers removed. Only the tail is inspected, so
/// the cost per token stays constant.
public enum TranscriptReasoningPreview {
    public static func line(_ markdown: String, limit: Int = 160) -> String {
        guard limit > 0 else { return "" }
        let tail = TranscriptOutputTail.tail(markdown, maxLines: 512, maxBytes: 4_096).text
        let lines = tail.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var chosen = lines.last(where: { $0.hasPrefix("**") && $0.hasSuffix("**") && $0.count > 4 }) ?? lines.last ?? ""
        for marker in ["#", "-", "*", "+", ">"] where chosen.hasPrefix(marker + " ") { chosen = String(chosen.dropFirst(2)) }
        while chosen.hasPrefix("#") { chosen = String(chosen.dropFirst()).trimmingCharacters(in: .whitespaces) }
        chosen = chosen.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "~~", with: "")
        chosen = chosen.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return chosen.count > limit ? String(chosen.prefix(limit - 1)) + "…" : chosen
    }
}

public enum TranscriptTimestampFormat: String, CaseIterable, Identifiable, Sendable {
    case system, twelveHour, twentyFourHour
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: String(localized: "System")
        case .twelveHour: String(localized: "12-hour")
        case .twentyFourHour: String(localized: "24-hour")
        }
    }
}

/// T3's day-aware message timestamps: a time today, "yesterday at" a time,
/// otherwise a numeric date (with the year when it differs) and time.
public struct TranscriptTimestamp: Sendable {
    public var format: TranscriptTimestampFormat
    public var locale: Locale
    public var calendar: Calendar
    public init(format: TranscriptTimestampFormat = .system, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        self.format = format; self.locale = locale
        var calendar = Calendar(identifier: .gregorian); calendar.locale = locale; calendar.timeZone = timeZone
        self.calendar = calendar
    }

    public func time(_ date: Date) -> String { formatter(template: format == .twelveHour ? "hmma" : format == .twentyFourHour ? "HHmm" : "jmm").string(from: date) }

    public func dayAware(_ date: Date, now: Date = Date()) -> String {
        let time = time(date)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return time }
        if days == 1 { return String(localized: "yesterday at \(time)") }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatter(template: sameYear ? "Md" : "yMd").string(from: date) + " " + time
    }

    /// "3:04 PM, 4th June 2026": English ordinal and month, matching T3's tooltip.
    public func tooltip(_ date: Date) -> String {
        let day = calendar.component(.day, from: date), year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        var english = Calendar(identifier: .gregorian); english.locale = Locale(identifier: "en_US")
        let name = english.monthSymbols[max(0, min(11, month - 1))]
        let suffix: String
        switch (day % 100, day % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(time(date)), \(day)\(suffix) \(name) \(year)"
    }

    private func formatter(template: String) -> DateFormatter {
        let key = [template, locale.identifier, calendar.timeZone.identifier].joined(separator: "|")
        return TranscriptFormatterCache.shared.formatter(key) {
            let formatter = DateFormatter()
            formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
    }
}

/// Formatting with a configured `DateFormatter` is thread-safe; creation and
/// template localization are the expensive parts, so formatters are reused.
private final class TranscriptFormatterCache: @unchecked Sendable {
    static let shared = TranscriptFormatterCache()
    private let lock = NSLock()
    private var values: [String: DateFormatter] = [:]
    func formatter(_ key: String, make: () -> DateFormatter) -> DateFormatter {
        lock.lock(); defer { lock.unlock() }
        if let value = values[key] { return value }
        if values.count > 64 { values.removeAll() }
        let value = make(); values[key] = value; return value
    }
}
