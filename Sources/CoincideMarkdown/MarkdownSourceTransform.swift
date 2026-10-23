import Foundation
import Markdown

/// A formula found outside code before cmark parses the line, so Markdown escapes,
/// emphasis and table pipes cannot rewrite its TeX.
struct MarkdownSourceFormula: Sendable, Equatable {
    var tex: String
    var source: String
    var display: Bool
}

/// All marker scalars are absent from the complete authored message. Decoding
/// can therefore remove only generated markers, never private-use user text.
struct MarkdownSourceMarkers {
    let open: Unicode.Scalar, close: Unicode.Scalar, separator: Unicode.Scalar
    init(source: String) {
        let authored = Set(source.unicodeScalars)
        var found: [Unicode.Scalar] = []
        for value in UInt32(0xE000)...0x10FFFF {
            if let scalar = Unicode.Scalar(value), !authored.contains(scalar) { found.append(scalar) }
            if found.count == 3 { break }
        }
        // A bounded 1 MiB source cannot contain this entire scalar range.
        open = found[0]; close = found[1]; separator = found[2]
    }
    func sentinel(_ kind: Character, _ index: Int) -> String { "`\(open)\(kind)\(index)\(close)`" }
    func decode(_ code: String) -> (kind: Character, index: Int)? {
        let scalars = code.unicodeScalars
        guard scalars.count >= 4, scalars.first == open, scalars.last == close else { return nil }
        let body = String(String.UnicodeScalarView(scalars.dropFirst().dropLast().filter { $0 != separator && !$0.properties.isWhitespace && $0 != ">" }))
        guard let kind = body.first, let index = Int(body.dropFirst()), index >= 0 else { return nil }
        return (kind, index)
    }
}

/// Source-level passes that cmark cannot express: math, footnotes and Codex directives.
/// The line count never changes, so code and HTML line numbers from the first parse stay
/// valid. Each construct becomes an inline code span holding a private-use sentinel that
/// the block builder maps back; a display block keeps its first line and leaves its other
/// lines blank inside their container.
struct MarkdownSourceTransform {
    let markers: MarkdownSourceMarkers
    let math: Bool, footnotes: Bool, directives: Bool
    private(set) var formulas: [MarkdownSourceFormula] = []
    private(set) var footnoteOrder: [String] = []
    private(set) var definitions: [String: String] = [:]
    private(set) var artifacts: [CodexArtifactTemplate] = []
    init(math: Bool = true, footnotes: Bool = true, directives: Bool = true, source: String = "") {
        self.math = math; self.footnotes = footnotes; self.directives = directives; markers = .init(source: source)
    }
    static func mayApply(_ source: String) -> Bool {
        return source.contains("$") || source.contains("\\(") || source.contains("\\[") || source.contains("[^")
            || source.contains(":codex-") || source.contains("::artifact-template")
    }

    /// Line facts from the first parse: code and HTML lines are never rewritten, and a
    /// formula may span lines only inside one paragraph.
    struct Layout {
        var protected = Set<Int>()
        var paragraph: [Int: Int] = [:]
        var quoteDepth: [Int] = []
        /// Table rows: GFM splits cells at unescaped pipes before code spans pair.
        var tableRows = Set<Int>()
        init(_ document: Document) {
            func visit(_ node: any Markup, depth: Int, quotes: Int) {
                guard depth < 64 else { return }
                if node is CodeBlock || node is HTMLBlock, let range = node.range {
                    for line in range.lowerBound.line...max(range.lowerBound.line, range.upperBound.line) { protected.insert(line - 1) }
                } else if node is Table, let range = node.range {
                    for line in range.lowerBound.line...max(range.lowerBound.line, range.upperBound.line) { tableRows.insert(line - 1) }
                } else if node is Paragraph || node is Heading, let range = node.range {
                    for line in range.lowerBound.line...max(range.lowerBound.line, range.upperBound.line) { paragraph[line - 1] = quoteDepth.count }
                    quoteDepth.append(quotes)
                } else {
                    for child in node.children { visit(child, depth: depth + 1, quotes: quotes + (node is BlockQuote ? 1 : 0)) }
                }
            }
            visit(document, depth: 0, quotes: 0)
        }
    }

    /// Applies every pass to `lines`, which `document` parsed. Footnote definitions are
    /// collected only when `collecting` (the message itself, not a definition body).
    mutating func apply(_ lines: [String], document: Document, collecting: Bool = true) -> [String] {
        let layout = Layout(document)
        var output = lines, skipped = layout.protected
        if footnotes, collecting { collectDefinitions(&output, skipped: &skipped) }
        if math { displayBlocks(&output, skipped: &skipped, nativeProtected: layout.protected) }
        if directives {
            for index in output.indices where !skipped.contains(index) {
                guard output[index].contains("::artifact-template"), let template = CodexDirectives.artifactLine(output[index]) else { continue }
                artifacts.append(template); output[index] = markers.sentinel("A", artifacts.count - 1); skipped.insert(index)
            }
        }
        // Chunks of adjacent non-blank lines bound code spans like paragraphs do.
        var index = 0
        while index < output.count {
            guard !skipped.contains(index), !output[index].allSatisfy(\.isWhitespace) else { index += 1; continue }
            var end = index
            while end + 1 < output.count, !skipped.contains(end + 1), !output[end + 1].allSatisfy(\.isWhitespace) { end += 1 }
            let chunk = output[index...end].joined(separator: "\n")
            if chunk.contains("$") || chunk.contains("\\(") || chunk.contains("\\[") || chunk.contains("[^") || chunk.contains(":codex-") {
                let transformed = inline(chunk, paragraphs: (index...end).map { layout.paragraph[$0] }, quoteDepth: layout.quoteDepth,
                                         tableRows: (index...end).map { layout.tableRows.contains($0) }).components(separatedBy: "\n")
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

    // MARK: Display blocks

    /// A line's container prefix: quote markers (each with one optional space), list
    /// markers when `lists`, then indentation. `column` is the width after the last quote
    /// marker (`quoteEnd`), so continuation lines of a list item can be compared with it.
    struct Container { var end: Int; var quoteEnd: Int; var quotes: Int; var column: Int; var list: Bool }
    static func container(_ s: [Unicode.Scalar], quotes limit: Int = .max, lists: Bool) -> Container {
        var index = 0, quoteEnd = 0, quotes = 0, column = 0, list = false
        while index < s.count {
            var probe = index, width = column
            while probe < s.count, s[probe] == " " || s[probe] == "\t" { width += s[probe] == "\t" ? 4 - width % 4 : 1; probe += 1 }
            if quotes < limit, probe < s.count, s[probe] == ">" {
                quotes += 1; index = probe + 1; column = 0
                if index < s.count, s[index] == " " { index += 1 }
                quoteEnd = index; continue
            }
            if lists, let marker = listMarker(s, at: probe) {
                index = marker; column = width + (marker - probe); list = true; continue
            }
            index = probe; column = width; break
        }
        return Container(end: index, quoteEnd: quoteEnd, quotes: quotes, column: column, list: list)
    }
    /// The index after a bullet or ordered list marker and its single following space.
    private static func listMarker(_ s: [Unicode.Scalar], at start: Int) -> Int? {
        guard start < s.count else { return nil }
        var index = start
        if "-*+".unicodeScalars.contains(s[index]) { index += 1 } else {
            while index < s.count, index - start < 9, s[index].isASCII, s[index].properties.numericType != nil { index += 1 }
            guard index > start, index < s.count, s[index] == "." || s[index] == ")" else { return nil }
            index += 1
        }
        guard index < s.count, s[index] == " " || s[index] == "\t" else { return nil }
        return index + 1
    }

    enum DollarRun: Equatable { case none, close(Int), trailing }
    /// The first unescaped run of at least `size` dollars: a close when only whitespace
    /// follows it, as T3's patched math flow requires.
    static func dollarRun(_ s: [Unicode.Scalar], from start: Int, size: Int) -> DollarRun {
        var index = start, slashes = 0
        while index < s.count {
            if s[index] == "$", slashes % 2 == 0 {
                var run = 0
                while index + run < s.count, s[index + run] == "$" { run += 1 }
                if run >= size { return s[(index + run)...].allSatisfy({ $0.properties.isWhitespace }) ? .close(index) : .trailing }
                index += run; slashes = 0; continue
            }
            slashes = s[index] == "\\" ? slashes + 1 : 0
            index += 1
        }
        return .none
    }

    /// T3's math flow: `$$` (or `\[`) opening a line inside its container, closed by a
    /// later line ending in `$$` (or a `\]` line). Same-line content after `$$` is part of
    /// the formula; text after a closing `$$` leaves the lines to inline math.
    /// Once opened outside code/HTML, pinned flow math owns later fence-looking
    /// lines. The initial Markdown parse cannot retroactively hide its closer.
    private mutating func displayBlocks(_ lines: inout [String], skipped: inout Set<Int>, nativeProtected: Set<Int>) {
        let excludedDefinitions = skipped.subtracting(nativeProtected)
        var failures: [String: Int] = [:], index = 0
        while index < lines.count {
            defer { index += 1 }
            guard !skipped.contains(index), lines[index].contains("$$") || lines[index].contains("\\[") else { continue }
            let s = Array(lines[index].unicodeScalars), opener = Self.container(s, lists: true)
            var marker = opener.end, size = 0
            while marker < s.count, s[marker] == "$" { marker += 1; size += 1 }
            let bracket = size == 0 && marker + 1 < s.count && s[marker] == "\\" && s[marker + 1] == "["
            guard size >= 2 || bracket else { continue }
            var content: [String] = [], end: Int?
            if bracket {
                marker += 2
                guard s[marker...].allSatisfy({ $0.properties.isWhitespace }) else { continue }
            } else {
                let rest = Array(s[marker...])
                switch Self.dollarRun(rest, from: 0, size: size) {
                case .trailing: continue
                case .close(let at):
                    content = [String(String.UnicodeScalarView(rest[..<at])).trimmingCharacters(in: .whitespaces)]; end = index
                case .none:
                    let first = String(String.UnicodeScalarView(rest)).trimmingCharacters(in: .whitespaces)
                    if !first.isEmpty { content = [first] }
                }
            }
            let key = "\(bracket)|\(size)|\(opener.quotes)|\(opener.column)|\(opener.list)"
            if end == nil, let failed = failures[key], failed > index { continue }
            var line = index + 1
            scan: while end == nil, line < lines.count, !excludedDefinitions.contains(line) {
                let t = Array(lines[line].unicodeScalars), inner = Self.container(t, quotes: opener.quotes, lists: false)
                let blank = t[inner.end...].allSatisfy { $0.properties.isWhitespace }
                // Flow content has no lazy lines: a shorter quote or a dedented list line ends it.
                if inner.quotes < opener.quotes || (opener.list && !blank && inner.column < opener.column) { break }
                var start = inner.quoteEnd, width = 0
                while start < t.count, width < opener.column, t[start] == " " || t[start] == "\t" { width += t[start] == "\t" ? 4 - width % 4 : 1; start += 1 }
                let text = Array(t[start...])
                if bracket {
                    if String(String.UnicodeScalarView(text)).trimmingCharacters(in: .whitespaces) == "\\]" { end = line; break }
                } else {
                    switch Self.dollarRun(text, from: 0, size: size) {
                    case .trailing: break scan
                    case .close(let at):
                        let tail = String(String.UnicodeScalarView(text[..<at]))
                        if !tail.allSatisfy(\.isWhitespace) { content.append(tail.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)) }
                        end = line; break scan
                    case .none: break
                    }
                }
                content.append(blank ? "" : String(String.UnicodeScalarView(text)))
                line += 1
            }
            guard let end else { failures[key] = line; continue }
            let tex = content.joined(separator: "\n")
            guard !tex.allSatisfy(\.isWhitespace) else { continue }
            formulas.append(.init(tex: tex, source: lines[index...end].joined(separator: "\n"), display: true))
            lines[index] = String(String.UnicodeScalarView(s[..<opener.end])) + markers.sentinel("D", formulas.count - 1)
            for blanked in index..<end {
                // Keep each line inside its quote so the container does not end early.
                let t = Array(lines[blanked + 1].unicodeScalars), inner = Self.container(t, quotes: opener.quotes, lists: false)
                lines[blanked + 1] = inner.quotes == 0 ? "" : String(String.UnicodeScalarView(t[..<inner.quoteEnd]))
            }
            for line in index...end { skipped.insert(line) }
            index = end
        }
    }

    // MARK: Inline scanner

    /// Rewrites one chunk of adjacent lines. `paragraphs` gives each line's paragraph in the
    /// first parse; formulas cross a line ending only within one paragraph.
    mutating func inline(_ text: String, paragraphs: [Int?] = [], quoteDepth: [Int] = [], tableRows: [Bool] = []) -> String {
        let s = Array(text.unicodeScalars), n = s.count
        var output = String.UnicodeScalarView(), copied = 0, index = 0, brackets = 0
        // Line geometry: the end of each line and of its paragraph run.
        var lineStarts = [0]
        for position in s.indices where s[position] == "\n" { lineStarts.append(position + 1) }
        func lineEnd(_ line: Int) -> Int { line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : n }
        func paragraph(_ line: Int) -> Int? { line < paragraphs.count ? paragraphs[line] : nil }
        var runEnds = Array(repeating: 0, count: lineStarts.count)
        for line in lineStarts.indices.reversed() {
            let continues = paragraph(line) != nil && line + 1 < lineStarts.count && paragraph(line + 1) == paragraph(line)
            runEnds[line] = continues ? runEnds[line + 1] : lineEnd(line)
        }
        func line(of position: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high { let mid = (low + high + 1) / 2; if lineStarts[mid] <= position { low = mid } else { high = mid - 1 } }
            return low
        }
        func depth(_ line: Int) -> Int { paragraph(line).map { $0 < quoteDepth.count ? quoteDepth[$0] : 0 } ?? 0 }
        /// The container prefix of a paragraph continuation line: indentation and its quote markers.
        func prefixEnd(_ start: Int, quotes: Int) -> Int {
            var position = start, found = 0
            while position < n {
                if s[position] == " " || s[position] == "\t" { position += 1; continue }
                if s[position] == ">", found < quotes { found += 1; position += 1; continue }
                break
            }
            return position
        }
        // Links: each unescaped `(` matched with its `)` on the same line.
        var parens: [Int: Int] = [:]
        if text.contains("](") {
            var stack: [Int] = [], position = 0
            while position < n {
                switch s[position] {
                case "\\": position += 2; continue
                case "(": stack.append(position)
                case ")": if let open = stack.popLast() { parens[open] = position }
                case "\n": stack.removeAll()
                default: break
                }
                position += 1
            }
        }
        // Unmatched backtick runs are escaped before a sentinel so they cannot pair with it.
        var unmatched: [(start: Int, length: Int)] = [], nextUnmatched = 0, noBacktickClose: [String: Int] = [:]
        /// Where a code span starting at `position` must close: its paragraph, or its table cell.
        func codeSpanLimit(_ position: Int) -> Int {
            let current = line(of: position)
            guard current < tableRows.count, tableRows[current] else { return runEnds[current] }
            var probe = position
            let end = lineEnd(current)
            while probe < end { if s[probe] == "\\" { probe += 2; continue }; if s[probe] == "|" { break }; probe += 1 }
            return min(probe, end)
        }
        var escapedScans: [Unicode.Scalar: (from: Int, stop: Int, limit: Int, result: Int?)] = [:]
        let escapes = math || footnotes
        func copy(upTo end: Int) {
            var cursor = copied
            while escapes, nextUnmatched < unmatched.count, unmatched[nextUnmatched].start < end {
                let run = unmatched[nextUnmatched]; nextUnmatched += 1
                guard run.start >= cursor else { continue }
                output.append(contentsOf: s[cursor..<run.start])
                for _ in 0..<run.length { output.append("\\"); output.append("`") }
                cursor = run.start + run.length
            }
            output.append(contentsOf: s[cursor..<end])
        }
        func replace(_ end: Int, with replacement: String) {
            copy(upTo: index); output.append(contentsOf: replacement.unicodeScalars); copied = end; index = end
        }
        /// A sentinel for `start..<end`, spread over the same lines so the line count holds.
        func placeholder(_ kind: Character, _ number: Int, end: Int) {
            copy(upTo: index)
            if output.last == "`" { output.append(markers.separator) }
            var value = "`\(markers.open)\(kind)\(number)"
            let breaks = s[index..<end].indices.filter { s[$0] == "\n" }
            if breaks.isEmpty { value += "\(markers.close)`" }
            for (offset, position) in breaks.enumerated() {
                let quotes = depth(line(of: position + 1))
                value += "\n" + String(String.UnicodeScalarView(s[(position + 1)..<prefixEnd(position + 1, quotes: quotes)]))
                value += offset == breaks.count - 1 ? "\(markers.close)`" : "\(markers.separator)"
            }
            output.append(contentsOf: value.unicodeScalars)
            if end < n, s[end] == "`" { output.append(markers.separator) }
            copied = end; index = end
        }
        /// Formula text with continuation-line container prefixes removed.
        func tex(_ range: Range<Int>) -> String {
            var result = String.UnicodeScalarView(), position = range.lowerBound
            while position < range.upperBound {
                result.append(s[position])
                if s[position] == "\n" { position = min(range.upperBound, prefixEnd(position + 1, quotes: depth(line(of: position + 1)))); continue }
                position += 1
            }
            return String(result)
        }
        func source(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(s[range])) }
        /// T3's `\(…\)`/`\[…\]` closer search, remembered so repeated unclosed openers stay linear.
        func escapedEnd(from start: Int, closer: Unicode.Scalar, limit: Int) -> Int? {
            if let scan = escapedScans[closer], scan.limit == limit, scan.from <= start, start <= scan.stop { return scan.result }
            var position = start, result: Int?
            while position + 1 < limit {
                if s[position] == "\\" {
                    if s[position + 1] == closer { result = position; break }
                    position += 2; continue
                }
                if s[position] == "`" { break }
                position += 1
            }
            escapedScans[closer] = (start, result ?? position, limit, result)
            return result
        }
        while index < n {
            let scalar = s[index]
            switch scalar {
            case "\\":
                guard index + 1 < n else { index += 1; continue }
                let next = s[index + 1]
                if math, next == "(" || next == "[", let end = escapedEnd(from: index + 2, closer: next == "(" ? ")" : "]", limit: runEnds[line(of: index)]), end > index + 2 {
                    let body = source((index + 2)..<end)
                    // T3 keeps `\[1\]` citations literal: a display bracket needs substantive TeX.
                    let substantive = next == "(" || body.unicodeScalars.contains { !"\\ ,\n".unicodeScalars.contains($0) && !($0.isASCII && $0.properties.numericType != nil) }
                    if substantive, !body.allSatisfy(\.isWhitespace) {
                        formulas.append(.init(tex: tex((index + 2)..<end), source: source(index..<(end + 2)), display: next == "["))
                        placeholder("M", formulas.count - 1, end: end + 2); continue
                    }
                }
                index += next.isASCII && next.properties.generalCategory.isPunctuationOrSymbol ? 2 : 1
            case "`":
                var run = 0
                while index + run < n, s[index + run] == "`" { run += 1 }
                let limit = codeSpanLimit(index + run), key = "\(run)|\(limit)"
                if let failed = noBacktickClose[key], failed <= index { unmatched.append((index, run)); index += run; continue }
                if let close = Self.backtickClose(s, from: index + run, length: run, limit: limit) { index = close + run }
                else { noBacktickClose[key] = index; unmatched.append((index, run)); index += run }
            case "<":
                // Raw tags and autolinks keep their attribute and URL text.
                var end = index + 1
                if end < n, s[end].properties.isAlphabetic || s[end] == "/" || s[end] == "!" || s[end] == "?" {
                    while end < n, s[end] != ">", s[end] != "\n", s[end] != "<" { end += 1 }
                    index = end < n && s[end] == ">" ? end + 1 : index + 1
                } else { index += 1 }
            case "$":
                let current = line(of: index)
                if math, let (end, display) = Self.dollarMath(s, at: index, lineEnd: lineEnd(current), paragraphEnd: runEnds[current]),
                   case let closing = line(of: end - 1), closing == current || prefixEnd(lineStarts[closing], quotes: depth(closing)) < end - (display ? 2 : 1) {
                    // A closer opening a continuation line (after its container prefix) follows a line ending.
                    let markers = display ? 2 : 1
                    var formula = tex((index + markers)..<(end - markers))
                    let authored = source(index..<end)
                    if current < tableRows.count ? tableRows[current] : Self.tableRow(s, at: index) {
                        // GFM unescapes `\|` in table cells before inline parsing.
                        formula = formula.replacingOccurrences(of: "\\|", with: "|")
                    }
                    if display { formula = formula.trimmingCharacters(in: .whitespacesAndNewlines) }
                    formulas.append(.init(tex: formula, source: authored, display: display))
                    placeholder("M", formulas.count - 1, end: end); continue
                }
                while index < n, s[index] == "$" { index += 1 }
            case "[":
                if footnotes, index + 1 < n, s[index + 1] == "^" {
                    var end = index + 2
                    while end < n, end - index < 104, s[end] != "]", !s[end].properties.isWhitespace, s[end] != "[" { end += 1 }
                    if end < n, s[end] == "]", end > index + 2, !(end + 1 < n && s[end + 1] == ":") {
                        let label = source((index + 2)..<end).lowercased()
                        if definitions[label] != nil {
                            if !footnoteOrder.contains(label) { footnoteOrder.append(label) }
                            placeholder("F", footnoteOrder.firstIndex(of: label) ?? 0, end: end + 1); continue
                        }
                    }
                }
                brackets += 1; index += 1
            case "]":
                brackets = max(0, brackets - 1)
                // Link destinations keep `$`, `[^` and directive text literal.
                if index + 1 < n, s[index + 1] == "(" { index = parens[index + 1].map { $0 + 1 } ?? index + 1 } else { index += 1 }
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

    /// T3's patched micromark math text: no whitespace (or comma) just inside a single
    /// dollar, matching padding for `$$`, no digit after the closer (`$5 and $10`), no
    /// backtick or `://` inside, and a single dollar never crosses a line. Coincide also
    /// rejects an opener touching a letter or digit (`US$5`) and shell joins such as
    /// `$PATH:$HOME`, because math renders by default here.
    static func dollarMath(_ s: [Unicode.Scalar], at start: Int, lineEnd: Int, paragraphEnd: Int) -> (end: Int, display: Bool)? {
        let n = s.count
        func word(_ value: Unicode.Scalar) -> Bool { value.properties.isAlphabetic || value.properties.numericType != nil }
        func padding(_ value: Unicode.Scalar) -> Bool { value == " " || value == "\t" || value == "," }
        if start > 0, word(s[start - 1]) { return nil }
        var size = 0
        while start + size < n, s[start + size] == "$" { size += 1 }
        guard size <= 2 else { return nil }
        var index = start + size
        guard index < n, s[index] != "\n" else { return nil }
        let openPadding = padding(s[index])
        if size == 1, openPadding { return nil }
        let limit = size == 1 ? lineEnd : paragraphEnd
        var slashes = 0, previous: Unicode.Scalar = " ", beforePrevious: Unicode.Scalar = " "
        while index < min(n, limit) {
            let value = s[index]
            if value == "`" { return nil }
            if value == "$", slashes % 2 == 0 {
                var run = 0
                while index + run < n, s[index + run] == "$" { run += 1 }
                guard run == size else { index += run; slashes = 0; previous = "$"; continue }
                let before = s[index - 1], after: Unicode.Scalar? = index + run < n ? s[index + run] : nil
                if before == "\n" || after.map({ $0.isASCII && $0.properties.numericType != nil }) == true || padding(before) != openPadding { return nil }
                if let after, after.properties.isAlphabetic || after == "_", [":", "/", "="].contains(before) { return nil }
                return (index + run, size == 2)
            }
            if value == "/", previous == "/", beforePrevious == ":" { return nil }
            beforePrevious = previous; previous = value
            slashes = value == "\\" ? slashes + 1 : 0
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
    static func backtickClose(_ s: [Unicode.Scalar], from start: Int, length: Int, limit: Int) -> Int? {
        var index = start
        while index < limit {
            guard s[index] == "`" else { index += 1; continue }
            var run = 0
            while index + run < limit, s[index + run] == "`" { run += 1 }
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
