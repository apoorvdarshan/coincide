import Foundation

/// A link activated in terminal output. Detection belongs to the emulator; this
/// type only interprets the matched text, ported from T3's terminal-links and
/// fileLinks rules. Paths are never opened here, only resolved.
public enum TerminalLinkTarget: Equatable, Sendable {
    case web(URL)
    case file(path: String, line: Int?, column: Int?)

    public static let maximumLength = 4_096

    /// Returns nil for empty, oversized, control-bearing or unsupported links.
    /// Relative paths resolve against `currentDirectory` and `~/` against `homeDirectory`.
    public static func resolve(_ raw: String, currentDirectory: String,
                               homeDirectory: String = NSHomeDirectory()) -> TerminalLinkTarget? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.utf8.count <= maximumLength,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        // Stack traces wrap locations: `at f (src/a.js:1:2)`.
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}"), ("<", ">")] as [(Character, Character)]
        where text.count > 2 && text.first == open && trimClosingDelimiters(text, path: true).last == close {
            text = String(trimClosingDelimiters(text, path: true).dropFirst().dropLast())
        }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            let trimmed = trimClosingDelimiters(text, path: false)
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty else { return nil }
            return .web(url)
        }
        if lower.hasPrefix("file://") {
            let trimmed = trimClosingDelimiters(text, path: true)
            let position = splitPosition(trimmed)
            guard let url = URL(string: position.path), url.isFileURL, url.host.map({ $0.isEmpty || $0.lowercased() == "localhost" }) ?? true,
                  url.path.hasPrefix("/") else { return nil }
            return .file(path: URL(fileURLWithPath: url.path).standardizedFileURL.path, line: position.line, column: position.column)
        }
        // Any other URI scheme (mailto:, ssh:, javascript:, custom handlers) is refused.
        // `name.ext:12[:3]` is a position, not a scheme.
        if let colon = text.firstIndex(of: ":"), text[..<colon].count > 1, text.first?.isLetter == true,
           text[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) {
            let rest = trimClosingDelimiters(String(text[text.index(after: colon)...]), path: true)
            let isPosition = !rest.isEmpty && rest.split(separator: ":", omittingEmptySubsequences: false).count <= 2 &&
                rest.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
            if !isPosition { return nil }
        }
        var path = unquoted(trimClosingDelimiters(text, path: true))
        guard !path.isEmpty else { return nil }
        let position = splitPosition(path)
        path = position.path
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let resolved: String
        if path == "~" { resolved = homeDirectory }
        else if path.hasPrefix("~/") { resolved = join(homeDirectory, String(path.dropFirst(2))) }
        else if path.hasPrefix("/") { resolved = path }
        else { resolved = join(currentDirectory, path) }
        guard resolved.hasPrefix("/") else { return nil }
        return .file(path: URL(fileURLWithPath: resolved).standardizedFileURL.path, line: position.line, column: position.column)
    }

    /// Drops trailing sentence punctuation (and a compiler's trailing colon for
    /// paths) plus closing brackets that have no matching opener.
    public static func trimClosingDelimiters(_ value: String, path: Bool) -> String {
        let punctuation: Set<Character> = path ? [".", ",", ";", ":", "!", "?"] : [".", ",", ";", "!", "?"]
        var output = value
        func trimPunctuation() { while let last = output.last, punctuation.contains(last) { output.removeLast() } }
        trimPunctuation()
        var changed = true
        while changed {
            changed = false
            for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] as [(Character, Character)] {
                while output.last == close, output.filter({ $0 == open }).count < output.filter({ $0 == close }).count {
                    output.removeLast(); changed = true
                }
            }
            let before = output.count; trimPunctuation(); if output.count != before { changed = true }
        }
        return output
    }

    /// Splits a trailing `:line` or `:line:column` suffix with positive numbers.
    public static func splitPosition(_ value: String) -> (path: String, line: Int?, column: Int?) {
        var parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var numbers: [Int] = []
        while numbers.count < 2, parts.count > 1, let last = parts.last, !last.isEmpty, last.count <= 9,
              last.allSatisfy(\.isASCII), let number = Int(last), number > 0 {
            numbers.insert(number, at: 0); parts.removeLast()
        }
        let path = parts.joined(separator: ":")
        guard !path.isEmpty else { return (value, nil, nil) }
        return (path, numbers.first, numbers.count > 1 ? numbers[1] : nil)
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, ["\"", "'", "`"].contains(first) else { return value }
        var inner = value.dropFirst()
        if let close = inner.firstIndex(of: first) {
            // `"path with spaces":12:3` keeps its position outside the closing quote.
            let suffix = inner[inner.index(after: close)...]
            inner = inner[..<close]
            return String(inner) + (suffix.hasPrefix(":") ? String(suffix) : "")
        }
        return String(inner)
    }

    private static func join(_ base: String, _ next: String) -> String {
        var base = base
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        var next = Substring(next)
        while next.hasPrefix("/") { next = next.dropFirst() }
        return base == "/" ? "/" + next : base + "/" + next
    }
}
