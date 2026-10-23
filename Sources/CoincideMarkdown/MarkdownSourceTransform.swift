import Foundation

/// A formula found outside code before cmark parses the line, so Markdown escapes,
/// emphasis and table pipes cannot rewrite its TeX.
struct MarkdownFormula: Sendable, Equatable {
    var tex: String
    var source: String
    var display: Bool
}

/// Source-level passes that cmark cannot express: inline math, footnotes and Codex
/// directives. Replacements stay on their original line, so protected code and HTML
/// line numbers from the first parse remain valid. Each construct becomes an inline
/// code span holding a private-use sentinel that the block builder maps back.
struct MarkdownSourceTransform {
    static let open: Unicode.Scalar = "\u{E000}", close: Unicode.Scalar = "\u{E001}"
    let math: Bool, footnotes: Bool, directives: Bool
    private(set) var formulas: [MarkdownFormula] = []
    private(set) var footnoteOrder: [String] = []
    private(set) var definitions: [String: String] = [:]
    private(set) var artifacts: [CodexArtifactTemplate] = []
    init(math: Bool = true, footnotes: Bool = true, directives: Bool = true) { self.math = math; self.footnotes = footnotes; self.directives = directives }

    static func sentinel(_ kind: Character, _ index: Int) -> String { "`\u{E000}\(kind)\(index)\u{E001}`" }
    static func decode(_ code: String) -> (kind: Character, index: Int)? {
        let scalars = code.unicodeScalars
        guard scalars.count >= 4, scalars.first == open, scalars.last == close else { return nil }
        let body = String(String.UnicodeScalarView(scalars.dropFirst().dropLast()))
        guard let kind = body.first, let index = Int(body.dropFirst()), index >= 0 else { return nil }
        return (kind, index)
    }
    static func mayApply(_ source: String) -> Bool {
        guard !source.unicodeScalars.contains(open) else { return false }
        return source.contains("$") || source.contains("\\(") || source.contains("\\[") || source.contains("[^")
            || source.contains(":codex-") || source.contains("::artifact-template")
    }

    /// Applies every pass to lines outside `excluded` (code, HTML and display math).
    mutating func apply(_ lines: [String], excluded: Set<Int>) -> [String] {
        var output = lines, skipped = excluded
        if footnotes { collectDefinitions(&output, skipped: &skipped) }
        if directives {
            for index in output.indices where !skipped.contains(index) {
                guard output[index].contains("::artifact-template"), let template = CodexDirectives.artifactLine(output[index]) else { continue }
                artifacts.append(template); output[index] = Self.sentinel("A", artifacts.count - 1); skipped.insert(index)
            }
        }
        // Chunks of adjacent non-blank lines bound multi-line code spans like paragraphs do.
        var index = 0
        while index < output.count {
            guard !skipped.contains(index), !output[index].allSatisfy(\.isWhitespace) else { index += 1; continue }
            var end = index
            while end + 1 < output.count, !skipped.contains(end + 1), !output[end + 1].allSatisfy(\.isWhitespace) { end += 1 }
            let chunk = output[index...end].joined(separator: "\n")
            if chunk.contains("$") || chunk.contains("\\(") || chunk.contains("\\[") || chunk.contains("[^") || chunk.contains(":codex-") {
                let transformed = inline(chunk).components(separatedBy: "\n")
                if transformed.count == end - index + 1 { output.replaceSubrange(index...end, with: transformed) }
            }
            index = end + 1
        }
        return output
    }

    /// GFM footnote definitions at a block start, with indented or lazy continuation lines.
    private mutating func collectDefinitions(_ lines: inout [String], skipped: inout Set<Int>) {
        var index = 0
        while index < lines.count {
            let previousBlank = index == 0 || lines[index - 1].allSatisfy(\.isWhitespace)
            guard !skipped.contains(index), previousBlank, let (label, first) = Self.definitionStart(lines[index]) else { index += 1; continue }
            var content = [first], end = index + 1
            while end < lines.count {
                let line = lines[end]
                if line.allSatisfy(\.isWhitespace) {
                    guard end + 1 < lines.count, Self.indentation(lines[end + 1]) >= 4 else { break }
                    content.append(""); end += 1; continue
                }
                if Self.indentation(line) >= 4 { content.append(Self.dropIndentation(line, 4)); end += 1; continue }
                guard !skipped.contains(end), !(content.last ?? "").isEmpty, Self.definitionStart(line) == nil, !Self.startsBlock(line) else { break }
                content.append(line); end += 1
            }
            if definitions[label] == nil { definitions[label] = content.joined(separator: "\n") }
            for removed in index..<end { lines[removed] = ""; skipped.insert(removed) }
            index = end
        }
    }
    static func definitionStart(_ line: String) -> (String, String)? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, trimmed.hasPrefix("[^"), let close = trimmed.firstIndex(of: "]") else { return nil }
        let label = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close]
        let after = trimmed[trimmed.index(after: close)...]
        guard !label.isEmpty, label.count <= 100, !label.contains(where: { $0.isWhitespace || $0 == "[" }), after.hasPrefix(":") else { return nil }
        return (label.lowercased(), String(after.dropFirst().drop { $0 == " " || $0 == "\t" }))
    }
    private static func indentation(_ line: String) -> Int {
        var width = 0
        for character in line { if character == " " { width += 1 } else if character == "\t" { width += 4 - width % 4 } else { break } }
        return width
    }
    private static func dropIndentation(_ line: String, _ count: Int) -> String {
        var width = 0, index = line.startIndex
        while index < line.endIndex, width < count, line[index] == " " || line[index] == "\t" {
            width += line[index] == "\t" ? 4 - width % 4 : 1; index = line.index(after: index)
        }
        return String(line[index...])
    }
    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix("|") || trimmed.hasPrefix("<") { return true }
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " { return true }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        return !digits.isEmpty && digits.count <= 9 && [".", ")"].contains(trimmed.dropFirst(digits.count).first) && trimmed.dropFirst(digits.count + 1).first == " "
    }

    // MARK: Inline scanner

    mutating func inline(_ text: String) -> String {
        let s = Array(text.unicodeScalars), n = s.count
        var output = String.UnicodeScalarView(), copied = 0, index = 0, brackets = 0
        func isSpace(_ value: Unicode.Scalar) -> Bool { value.properties.isWhitespace }
        func replace(_ end: Int, with replacement: String) {
            output.append(contentsOf: s[copied..<index]); output.append(contentsOf: replacement.unicodeScalars); copied = end; index = end
        }
        func backtickAdjacent(_ end: Int) -> Bool { (index > 0 && s[index - 1] == "`") || (end < n && s[end] == "`") }
        while index < n {
            let scalar = s[index]
            switch scalar {
            case "\\":
                guard index + 1 < n else { index += 1; continue }
                let next = s[index + 1]
                if math, next == "(" || next == "[", let end = Self.escapedMathEnd(s, from: index + 2, closer: next == "(" ? ")" : "]"), !backtickAdjacent(end + 2) {
                    let tex = String(String.UnicodeScalarView(s[(index + 2)..<end]))
                    if !tex.allSatisfy(\.isWhitespace) {
                        formulas.append(.init(tex: tex, source: String(String.UnicodeScalarView(s[index..<(end + 2)])), display: next == "["))
                        replace(end + 2, with: Self.sentinel("M", formulas.count - 1)); continue
                    }
                }
                index += next.isASCII && next.properties.generalCategory.isPunctuationOrSymbol ? 2 : 1
            case "`":
                var run = 0
                while index + run < n, s[index + run] == "`" { run += 1 }
                index = Self.backtickClose(s, from: index + run, length: run).map { $0 + run } ?? index + run
            case "<":
                // Raw tags and autolinks keep their attribute and URL text.
                var end = index + 1
                if end < n, s[end].properties.isAlphabetic || s[end] == "/" || s[end] == "!" || s[end] == "?" {
                    while end < n, s[end] != ">", s[end] != "\n", s[end] != "<" { end += 1 }
                    index = end < n && s[end] == ">" ? end + 1 : index + 1
                } else { index += 1 }
            case "$":
                if math, let (end, display) = Self.dollarMath(s, at: index), !backtickAdjacent(end) {
                    let markers = display ? 2 : 1
                    var tex = String(String.UnicodeScalarView(s[(index + markers)..<(end - markers)])), source = String(String.UnicodeScalarView(s[index..<end]))
                    if Self.tableRow(s, at: index) {
                        // GFM unescapes `\|` in table cells before inline parsing.
                        tex = tex.replacingOccurrences(of: "\\|", with: "|"); source = source.replacingOccurrences(of: "\\|", with: "|")
                    }
                    formulas.append(.init(tex: tex, source: source, display: display))
                    replace(end, with: Self.sentinel("M", formulas.count - 1)); continue
                }
                while index < n, s[index] == "$" { index += 1 }
            case "[":
                if footnotes, index + 1 < n, s[index + 1] == "^" {
                    var end = index + 2
                    while end < n, end - index < 104, s[end] != "]", !isSpace(s[end]), s[end] != "[" { end += 1 }
                    if end < n, s[end] == "]", end > index + 2, !(end + 1 < n && s[end + 1] == ":") {
                        let label = String(String.UnicodeScalarView(s[(index + 2)..<end])).lowercased()
                        if definitions[label] != nil, !backtickAdjacent(end + 1) {
                            if !footnoteOrder.contains(label) { footnoteOrder.append(label) }
                            replace(end + 1, with: Self.sentinel("F", footnoteOrder.firstIndex(of: label) ?? 0)); continue
                        }
                    }
                }
                brackets += 1; index += 1
            case "]":
                brackets = max(0, brackets - 1)
                if index + 1 < n, s[index + 1] == "(" {
                    // Link destinations keep `$`, `[^` and directive text literal.
                    var end = index + 2, depth = 1
                    while end < n, s[end] != "\n" {
                        if s[end] == "\\" { end += 2; continue }
                        if s[end] == "(" { depth += 1 } else if s[end] == ")" { depth -= 1; if depth == 0 { break } }
                        end += 1
                    }
                    index = end < n && s[end] == ")" ? end + 1 : index + 1
                } else { index += 1 }
            case ":":
                if directives, index == 0 || s[index - 1] != ":", let directive = CodexDirectives.inline(s, at: index) {
                    if brackets == 0 || directive.isFollowUp { replace(directive.end, with: directive.replacement); continue }
                    index = directive.end; continue
                }
                index += 1
            default: index += 1
            }
        }
        output.append(contentsOf: s[copied..<n])
        return String(output)
    }

    /// Single-dollar text math follows Pandoc: no space just inside either delimiter and
    /// no digit right after the closer, so `$5 and $10` stays text. Delimiters touching a
    /// letter or digit outside (`$PATH:$HOME`, `US$5`) are not math either, because math
    /// renders by default here. `$$…$$` stays on one line.
    static func dollarMath(_ s: [Unicode.Scalar], at start: Int) -> (end: Int, display: Bool)? {
        let n = s.count
        func word(_ value: Unicode.Scalar) -> Bool { value.properties.isAlphabetic || value.properties.numericType != nil }
        if start > 0, word(s[start - 1]) { return nil }
        var run = 0
        while start + run < n, s[start + run] == "$" { run += 1 }
        guard run <= 2 else { return nil }
        var index = start + run
        guard index < n, !s[index].properties.isWhitespace, s[index] != "$" else { return nil }
        while index < n, s[index] != "\n" {
            if s[index] == "\\" { index += 2; continue }
            if s[index] == "`" { return nil }
            if s[index] == "$" {
                if run == 2 {
                    guard index + 1 < n, s[index + 1] == "$", !s[index - 1].properties.isWhitespace else { return nil }
                    return (index + 2, true)
                }
                guard !s[index - 1].properties.isWhitespace else { return nil }
                if index + 1 < n, s[index + 1] == "$" || word(s[index + 1]) { return nil }
                return (index + 1, false)
            }
            index += 1
        }
        return nil
    }
    /// Whether the line holding `index` reads as a pipe table row.
    static func tableRow(_ s: [Unicode.Scalar], at index: Int) -> Bool {
        var start = index
        while start > 0, s[start - 1] != "\n" { start -= 1 }
        while start < index, s[start] == " " || s[start] == "\t" { start += 1 }
        return s[start] == "|"
    }
    static func escapedMathEnd(_ s: [Unicode.Scalar], from start: Int, closer: Unicode.Scalar) -> Int? {
        var index = start
        while index + 1 < s.count, s[index] != "\n" {
            if s[index] == "\\" {
                if s[index + 1] == closer { return index > start ? index : nil }
                index += 2; continue
            }
            if s[index] == "`" { return nil }
            index += 1
        }
        return nil
    }
    static func backtickClose(_ s: [Unicode.Scalar], from start: Int, length: Int) -> Int? {
        var index = start
        while index < s.count {
            guard s[index] == "`" else { index += 1; continue }
            var run = 0
            while index + run < s.count, s[index + run] == "`" { run += 1 }
            if run == length { return index }
            index += run
        }
        return nil
    }
}

extension Unicode.GeneralCategory {
    var isPunctuationOrSymbol: Bool {
        switch self {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: true
        default: false
        }
    }
}
