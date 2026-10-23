import Foundation
import Markdown

public struct MarkdownFormula: Sendable, Equatable {
    public let source: String
    public let latex: String
    public let display: Bool
    public var copySource: String {
        let value = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        return display ? "\\[\n\(value)\n\\]" : "\\(\(value)\\)"
    }
}

/// The pinned LLM-math grammar uses four delimiters, exact dollar-run matching,
/// escaped closers, conservative single-dollar whitespace/price rules and no
/// crossing code spans or table rows. Generated HTML tags are inert parser
/// tokens only: they are consumed into typed formula spans, never executed.
struct MarkdownMathSyntax {
    let source: String
    let opening: [String: MarkdownFormula]
    let closing: String

    init(_ source: String) {
        guard source.contains("$") || source.contains("\\(") || source.contains("\\[") else {
            self.source = source; opening = [:]; closing = ""; return
        }
        let bytes = Array(source.utf8)
        guard !bytes.isEmpty else { self.source = source; opening = [:]; closing = ""; return }
        var escaped = [Bool](repeating: false, count: bytes.count), slashRun = 0
        for index in bytes.indices { escaped[index] = slashRun % 2 == 1; slashRun = bytes[index] == 92 ? slashRun + 1 : 0 }
        var lineEnds = [Bool](repeating: true, count: bytes.count + 1)
        for index in bytes.indices.reversed() { lineEnds[index] = bytes[index] == 10 || (bytes[index] == 32 || bytes[index] == 9) && lineEnds[index + 1] }
        let parsed = Document(parsing: source)
        let lines = Self.lineOffsets(bytes)
        var protected = [Bool](repeating: false, count: bytes.count), tableRows: Set<Int> = []
        var owners: [(range: Range<Int>, prefix: String)] = []
        func bounds(_ node: any Markup) -> Range<Int>? {
            guard let range = node.range, range.lowerBound.line > 0, range.upperBound.line > 0,
                  range.lowerBound.line <= lines.count, range.upperBound.line <= lines.count else { return nil }
            let start = lines[range.lowerBound.line - 1] + range.lowerBound.column - 1
            let end = lines[range.upperBound.line - 1] + range.upperBound.column - 1
            guard start >= 0, start <= end, end <= bytes.count else { return nil }; return start..<end
        }
        func protect(_ range: Range<Int>) { for index in range { protected[index] = true } }
        func visit(_ node: any Markup, depth: Int) {
            guard depth < 64 else { if let range = bounds(node) { protect(range) }; return }
            if node is CodeBlock || node is InlineCode || node is HTMLBlock || node is InlineHTML || node is Markdown.Image {
                if let range = bounds(node) { protect(range) }; return
            }
            if node is Table, let range = node.range {
                for line in range.lowerBound.line...range.upperBound.line { tableRows.insert(line - 1) }
            }
            if node is Paragraph || node is Heading, let range = bounds(node) {
                let line = Self.line(range.lowerBound, offsets: lines)
                let prefix = Self.containerPrefix(bytes[lines[line]..<range.lowerBound]) ?? ""
                owners.append((range, prefix))
            }
            if let link = node as? Markdown.Link, let range = bounds(link) {
                let raw = String(decoding: bytes[range], as: UTF8.self)
                if raw.hasPrefix("[") {
                    // A destination/title/reference identifier is never math;
                    // parsed label children remain eligible, including styles.
                    protect(range)
                    for child in link.children {
                        if let visible = bounds(child) { for index in visible { protected[index] = false } }
                        visit(child, depth: depth + 1)
                    }
                } else { protect(range) }
                return
            }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        visit(parsed, depth: 0)
        owners.sort { $0.range.lowerBound < $1.range.lowerBound }
        func owner(_ index: Int) -> (range: Range<Int>, prefix: String)? {
            var low = 0, high = owners.count
            while low < high { let middle = (low + high) / 2; if owners[middle].range.lowerBound <= index { low = middle + 1 } else { high = middle } }
            guard low > 0, owners[low - 1].range.contains(index) else { return nil }; return owners[low - 1]
        }
        if let urls = try? NSRegularExpression(pattern: #"(?:https?://|www\.)[^\s<>]+"#) {
            for match in urls.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range, in: source) else { continue }
                guard let lower = range.lowerBound.samePosition(in: source.utf8), let upper = range.upperBound.samePosition(in: source.utf8) else { continue }
                let start = source.utf8.distance(from: source.utf8.startIndex, to: lower)
                let end = source.utf8.distance(from: source.utf8.startIndex, to: upper)
                // Explicit Markdown/angle links already have precise AST
                // boundaries; do not let a bare-URL fallback consume math that
                // immediately follows their closing parenthesis/bracket.
                if protected[start] { continue }
                protect(start..<end)
            }
        }
        // Reference definitions have no ordinary block in the cmark tree.
        // Keep their destinations and indented continuation titles untouched.
        var definition = false
        for (line, start) in lines.enumerated() {
            let end = line + 1 < lines.count ? lines[line + 1] : bytes.count
            let text = String(decoding: bytes[start..<end], as: UTF8.self)
            if text.range(of: #"^ {0,3}\[[^\]\n]+\]:[ \t]*"#, options: .regularExpression) != nil { protect(start..<end); definition = true }
            else if definition && (text.hasPrefix(" ") || text.hasPrefix("\t")) { protect(start..<end) }
            else { definition = false }
        }
        var prefix = "coincide-math-" + UUID().uuidString.lowercased()
        while source.contains(prefix) { prefix += "x" }
        let endTag = "</" + prefix + ">"
        var replacements: [(Range<Int>, String)] = [], formulas: [String: MarkdownFormula] = [:]
        var index = 0, work = max(4_096, bytes.count * 12)
        while index < bytes.count, work > 0, formulas.count < 2_048 {
            defer { index += 1 }; work -= 1
            guard !protected[index], !escaped[index] else { continue }
            let dollar = bytes[index] == 36
            let tex = bytes[index] == 92 && index + 1 < bytes.count && (bytes[index + 1] == 40 || bytes[index + 1] == 91)
            guard dollar || tex else { continue }
            if dollar, index > 0, bytes[index - 1] == 36, !escaped[index - 1] { continue }
            var count = 2
            if dollar { count = 1; while index + count < bytes.count, bytes[index + count] == 36 { count += 1 } }
            let bodyStart = index + count
            guard bodyStart < bytes.count else { continue }
            let line = Self.line(index, offsets: lines)
            let container = Self.containerPrefix(bytes[lines[line]..<index])
            let openingLineEnds = lineEnds[bodyStart]
            let flow = (dollar && count >= 2 || tex && bytes[index + 1] == 91 && openingLineEnds) && container != nil
            let containing = owner(index)
            let blockFlow = flow && openingLineEnds
            let singleLine = tableRows.contains(line) || dollar && count == 1
            func match(asFlow: Bool) -> (range: Range<Int>, valueEnd: Int)? {
                if dollar && !asFlow && (bytes[bodyStart] == 10 || count == 1 && Self.space(bytes[bodyStart])) { return nil }
                var cursor = bodyStart
                let limit = asFlow ? bytes.count : (tableRows.contains(line) ? (line + 1 < lines.count ? lines[line + 1] - 1 : bytes.count) : containing?.range.upperBound ?? bytes.count)
                while cursor < limit, work > 0 {
                    work -= 1
                    if !asFlow && (bytes[cursor] == 96 || protected[cursor]) { return nil }
                    if bytes[cursor] == 10 && singleLine { return nil }
                    if dollar && !asFlow && cursor >= bodyStart + 2 && bytes[cursor - 2] == 58 && bytes[cursor - 1] == 47 && bytes[cursor] == 47 { return nil }
                    if dollar && bytes[cursor] == 36 && !escaped[cursor] {
                        var size = 1; while cursor + size < bytes.count, bytes[cursor + size] == 36 { size += 1 }
                        let end = cursor + size
                        if size == count || asFlow && size >= count {
                            if asFlow {
                                guard lineEnds[end] else { return nil }
                            } else {
                                let sameWhitespace = Self.space(bytes[bodyStart]) == (cursor > bodyStart && Self.space(bytes[cursor - 1]))
                                let afterDigit = end < bytes.count && (48...57).contains(bytes[end])
                                guard cursor > bodyStart, bytes[cursor - 1] != 10, !afterDigit, sameWhitespace else { return nil }
                            }
                            return (index..<end, cursor)
                        }
                        cursor += size; continue
                    }
                    if tex && bytes[cursor] == 92 && cursor + 1 < bytes.count && !escaped[cursor],
                       bytes[cursor + 1] == (bytes[index + 1] == 40 ? 41 : 93) {
                        let end = cursor + 2
                        if asFlow && !lineEnds[end] { return nil }
                        let body = bytes[bodyStart..<cursor]
                        let substantive = body.contains { $0 != 92 && $0 != 32 && $0 != 44 && $0 != 10 && $0 != 13 && !(48...57).contains($0) }
                        guard asFlow || bytes[index + 1] == 40 || substantive else { return nil }
                        return (index..<end, cursor)
                    }
                    cursor += 1
                }
                return nil
            }
            let matched = flow ? match(asFlow: true) ?? match(asFlow: false) : match(asFlow: false)
            guard let matched else { continue }
            let range = matched.range, valueEnd = matched.valueEnd
            var latex = String(decoding: bytes[bodyStart..<valueEnd], as: UTF8.self)
            if let prefix = container ?? containing?.prefix { latex = Self.stripContainer(latex, prefix: prefix) }
            if blockFlow {
                var content = latex.components(separatedBy: "\n")
                if content.first?.allSatisfy({ $0 == " " || $0 == "\t" }) == true { content.removeFirst() }
                if content.last?.allSatisfy({ $0 == " " || $0 == "\t" }) == true { content.removeLast() }
                latex = content.joined(separator: "\n")
            }
            let tag = "<" + prefix + "-" + String(formulas.count) + ">"
            formulas[tag] = .init(source: String(decoding: bytes[range], as: UTF8.self), latex: latex, display: dollar ? count >= 2 : bytes[index + 1] == 91)
            replacements.append((range, tag + endTag)); index = range.upperBound - 1
        }
        var result = Data(), copied = 0
        for (range, replacement) in replacements {
            result.append(contentsOf: bytes[copied..<range.lowerBound]); result.append(contentsOf: replacement.utf8); copied = range.upperBound
        }
        result.append(contentsOf: bytes[copied...])
        self.source = String(decoding: result, as: UTF8.self); opening = formulas; closing = endTag
    }

    private static func space(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 44 }
    private static func lineOffsets(_ bytes: [UInt8]) -> [Int] { [0] + bytes.indices.filter { bytes[$0] == 10 }.map { $0 + 1 } }
    private static func line(_ offset: Int, offsets: [Int]) -> Int {
        var low = 0, high = offsets.count
        while low + 1 < high { let middle = (low + high) / 2; if offsets[middle] <= offset { low = middle } else { high = middle } }
        return low
    }
    private static func containerPrefix(_ bytes: ArraySlice<UInt8>) -> String? {
        guard bytes.count <= 512 else { return nil }
        let prefix = String(decoding: bytes, as: UTF8.self)
        guard prefix.range(of: #"^[ \t]*(?:>[ \t]*)*(?:(?:[-+*]|[0-9]{1,9}[.)])[ \t]+)?$"#, options: .regularExpression) != nil else { return nil }
        return prefix
    }
    private static func stripContainer(_ text: String, prefix: String) -> String {
        guard !prefix.isEmpty else { return text }
        let continuation = prefix.replacingOccurrences(of: #"(?:[-+*]|[0-9]{1,9}[.)])(?=[ \t]+$)"#, with: { String(repeating: " ", count: $0.count) })
        return text.components(separatedBy: "\n").enumerated().map { line, text in
            guard line > 0 else { return text }
            if text.hasPrefix(continuation) { return String(text.dropFirst(continuation.count)) }
            if text.trimmingCharacters(in: .whitespaces) == continuation.trimmingCharacters(in: .whitespaces) { return "" }
            return text
        }.joined(separator: "\n")
    }
}

private extension String {
    func replacingOccurrences(of pattern: String, with transform: (Substring) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return self }
        var result = self
        for match in expression.matches(in: self, range: NSRange(startIndex..., in: self)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }; result.replaceSubrange(range, with: transform(result[range]))
        }
        return result
    }
}
