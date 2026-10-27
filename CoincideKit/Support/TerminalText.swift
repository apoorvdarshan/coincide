import Foundation

/// Cleaning up what agent CLIs print for a terminal before Coincide shows it.
public enum TerminalText {
    /// Removes terminal escape sequences: colors and cursor movement (CSI), titles and hyperlinks (OSC,
    /// keeping the link text), and other two-character escapes.
    public nonisolated static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") || text.contains("\u{9B}") else { return text }
        return text
            // OSC: ESC ] … terminated by BEL or ESC \ (hyperlinks wrap their text in two of these).
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            // CSI: ESC [ (or the one-byte form) parameters, intermediates and a final byte.
            .replacingOccurrences(of: "(?:\u{1B}\\[|\u{9B})[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            // Character set selection: ESC ( B and the like.
            .replacingOccurrences(of: "\u{1B}[()*+][0-9A-Za-z]", with: "", options: .regularExpression)
            // Other escapes: ESC followed by one byte (keypad modes, index, …).
            .replacingOccurrences(of: "\u{1B}[@-Z\\\\^_=><78]", with: "", options: .regularExpression)
    }

    /// The text without surrounding whitespace, or nil when nothing is left.
    public nonisolated static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The last `count` non-blank lines of what a process printed, escape sequences removed, at most
    /// `maxLength` characters (the end is kept). Nil when nothing is left.
    public nonisolated static func tail(_ text: String, lines count: Int, maxLength: Int) -> String? {
        let lines = stripANSI(text).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let joined = lines.suffix(count).joined(separator: "\n")
        return joined.count > maxLength ? String(joined.suffix(maxLength)) : joined
    }
}
