import Foundation

/// GFM extended autolink literals (`https://…`, `www.…`, `name@example.com`) found in
/// plain text runs. Destinations still pass through `MarkdownLinkTarget.resolve`.
enum MarkdownAutolink {
    struct Match: Equatable { var range: Range<Int>; var destination: String }

    static func spans(_ text: String, style: MarkdownSpan.Style) -> [MarkdownSpan] {
        guard text.contains(where: { $0 == ":" || $0 == "." || $0 == "@" }) else { return [.init(text: text, style: style)] }
        let s = Array(text.unicodeScalars), found = matches(s)
        guard !found.isEmpty else { return [.init(text: text, style: style)] }
        var result: [MarkdownSpan] = [], cursor = 0
        func piece(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(s[range])) }
        for match in found {
            if match.range.lowerBound > cursor { result.append(.init(text: piece(cursor..<match.range.lowerBound), style: style)) }
            result.append(.init(text: piece(match.range), style: style, destination: match.destination)); cursor = match.range.upperBound
        }
        if cursor < s.count { result.append(.init(text: piece(cursor..<s.count), style: style)) }
        return result
    }

    static func matches(_ s: [Unicode.Scalar]) -> [Match] {
        var result: [Match] = [], index = 0
        func text(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(s[range])) }
        while index < s.count {
            if s[index] == ":", index + 2 < s.count, s[index + 1] == "/", s[index + 2] == "/" {
                var start = index
                while start > 0, s[start - 1].isASCII, s[start - 1].properties.isAlphabetic { start -= 1 }
                let scheme = text(start..<index).lowercased()
                if ["http", "https"].contains(scheme), start == 0 || !isAlphanumeric(s[start - 1]), result.last.map({ $0.range.upperBound <= start }) ?? true,
                   let domainEnd = domain(s, from: index + 3, allowShort: true) {
                    let end = delimit(s, start: start, end: pathEnd(s, from: domainEnd))
                    if end > index + 3 { result.append(.init(range: start..<end, destination: text(start..<end))); index = end; continue }
                }
            } else if s[index] == "w", index + 4 <= s.count, text(index..<(index + 4)) == "www.",
                      index == 0 || s[index - 1].properties.isWhitespace || "*_~(".unicodeScalars.contains(s[index - 1]),
                      let domainEnd = domain(s, from: index, allowShort: false) {
                let end = delimit(s, start: index, end: pathEnd(s, from: domainEnd))
                if end > index + 4 { result.append(.init(range: index..<end, destination: "https://" + text(index..<end))); index = end; continue }
            }
            index += 1
        }
        // Emails outside URL matches.
        var emails: [Match] = []
        index = 0
        while index < s.count {
            guard s[index] == "@" else { index += 1; continue }
            var start = index
            while start > 0, isLocal(s[start - 1]) { start -= 1 }
            guard start < index, start == 0 || !["/", ":"].contains(s[start - 1]),
                  !result.contains(where: { $0.range.overlaps(start..<(index + 1)) }) else { index += 1; continue }
            var end = index + 1, periods = 0
            while end < s.count, s[end].isASCII, isAlphanumeric(s[end]) || s[end] == "-" || s[end] == "_" || s[end] == "." {
                if s[end] == "." {
                    guard end + 1 < s.count, s[end + 1].isASCII, isAlphanumeric(s[end + 1]) || s[end + 1] == "-" || s[end + 1] == "_" else { break }
                    periods += 1
                }
                end += 1
            }
            guard periods > 0, end > index + 1, s[end - 1] != "-", s[end - 1] != "_" else { index += 1; continue }
            emails.append(.init(range: start..<end, destination: "mailto:" + text(start..<end))); index = end
        }
        return (result + emails).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func isAlphanumeric(_ value: Unicode.Scalar) -> Bool { value.properties.isAlphabetic || value.properties.numericType != nil }
    private static func isLocal(_ value: Unicode.Scalar) -> Bool { value.isASCII && (isAlphanumeric(value) || ".+-_".unicodeScalars.contains(value)) }

    /// cmark-gfm `check_domain`: host characters with no underscore in the last two labels.
    private static func domain(_ s: [Unicode.Scalar], from start: Int, allowShort: Bool) -> Int? {
        var index = start, periods = 0, underscoresBefore = 0, underscores = 0
        while index < s.count {
            let value = s[index]
            if value == "_" { underscores += 1 }
            else if value == "." {
                guard index + 1 < s.count, isAlphanumeric(s[index + 1]) || s[index + 1] == "-" || s[index + 1] == "_" else { break }
                underscoresBefore = underscores; underscores = 0; periods += 1
            } else if !(isAlphanumeric(value) || value == "-") { break }
            index += 1
        }
        guard index > start, underscoresBefore == 0, underscores == 0, allowShort || periods > 0 else { return nil }
        return index
    }
    private static func pathEnd(_ s: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < s.count, !s[index].properties.isWhitespace, s[index] != "<" { index += 1 }
        return index
    }
    /// cmark-gfm `autolink_delim`: trailing punctuation, unbalanced `)` and entity-like `&x;`.
    private static func delimit(_ s: [Unicode.Scalar], start: Int, end initial: Int) -> Int {
        var end = initial, opening = 0, closing = 0
        for index in start..<end { if s[index] == "(" { opening += 1 } else if s[index] == ")" { closing += 1 } }
        while end > start {
            switch s[end - 1] {
            case ")":
                guard closing > opening else { return end }
                closing -= 1; end -= 1
            case "?", "!", ".", ",", ":", "*", "_", "~", "'", "\"": end -= 1
            case ";":
                var entity = end - 2
                while entity > start, s[entity].isASCII, s[entity].properties.isAlphabetic { entity -= 1 }
                end = entity < end - 2 && s[entity] == "&" ? entity : end - 1
            default: return end
            }
        }
        return end
    }
}
