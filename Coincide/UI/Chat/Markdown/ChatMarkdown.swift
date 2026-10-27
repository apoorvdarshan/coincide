import Foundation

/// GitHub-flavored Markdown as agents write it: headings, paragraphs, emphasis, inline code, links,
/// lists with task items, block quotes, tables, rules and fenced code. An unclosed fence runs to the
/// end of the text, so a message that is still streaming renders sensibly mid-block.
nonisolated enum ChatMarkdown {
    indirect enum Block: Hashable, Sendable {
        case paragraph([Inline])
        case heading(level: Int, [Inline])
        case code(language: String?, text: String)
        case quote([Block])
        case list(List)
        case table(Table)
        case rule
    }

    struct List: Hashable, Sendable {
        var isOrdered: Bool
        var start: Int
        /// Tight lists render their items without paragraph spacing.
        var isTight: Bool
        var items: [ListItem]
    }

    struct ListItem: Hashable, Sendable {
        /// `nil` for a plain item, otherwise whether the task box is checked.
        var task: Bool?
        var blocks: [Block]
    }

    enum Alignment: Hashable, Sendable {
        case none, left, center, right
    }

    struct Table: Hashable, Sendable {
        var alignments: [Alignment]
        var header: [[Inline]]
        var rows: [[[Inline]]]
    }

    indirect enum Inline: Hashable, Sendable {
        case text(String)
        case code(String)
        case emphasis([Inline])
        case strong([Inline])
        case strikethrough([Inline])
        case link(destination: String, [Inline])
        case image(alt: String, source: String)
        case softBreak
        case lineBreak
    }

    static func parse(_ text: String) -> [Block] {
        var parser = BlockParser(lines: splitLines(Array(text.utf8)[...]).lines)
        return parser.parse()
    }

    /// A text's top-level blocks with the line each starts on, so that once the text has grown it can be
    /// parsed again from its last blocks only (see `reparsed(_:)`), as T3 Code's incremental Markdown does.
    struct Document: Sendable {
        /// The text, as UTF-8.
        let bytes: [UInt8]
        let blocks: [Block]
        /// The line each top-level block starts on, and that line's UTF-8 offset.
        let startLines: [Int]
        let startOffsets: [Int]
        /// The index of the text's last line, the only one that may be incomplete, and its UTF-8 offset.
        let lastLine: Int
        let lastLineOffset: Int

        init(parsing bytes: [UInt8]) {
            let (blocks, startLines, lineStarts) = Self.parse(bytes[...])
            self.init(
                bytes: bytes, blocks: blocks, startLines: startLines, startOffsets: startLines.map { lineStarts[$0] },
                lastLine: lineStarts.count - 1, lastLineOffset: lineStarts[lineStarts.count - 1])
        }

        private init(bytes: [UInt8], blocks: [Block], startLines: [Int], startOffsets: [Int], lastLine: Int, lastLineOffset: Int) {
            self.bytes = bytes
            self.blocks = blocks
            self.startLines = startLines
            self.startOffsets = startOffsets
            self.lastLine = lastLine
            self.lastLineOffset = lastLineOffset
        }

        /// The document of `bytes`, and how many of its leading blocks are this document's own.
        ///
        /// When every complete line of this text starts `bytes` unchanged, as while a reply streams in, the
        /// blocks that start at least two lines before this text's last line are kept, and only the text
        /// from the last of the others on is parsed. A top-level block reads at most one line past the
        /// start of the next (a paragraph checks whether its next line starts a table), so the kept blocks
        /// never read the last line, the only one that can have changed; the text from where the next
        /// block starts parses the same on its own as within the whole text. Restarting at the last block
        /// alone would not do: a growing last line can join the block before it (`Intro` then `#`, which
        /// is an empty heading, becomes one paragraph once the line reads `#123 fixed`).
        func reparsed(_ bytes: [UInt8]) -> (document: Document, kept: Int) {
            guard lastLine >= 2, bytes.count >= lastLineOffset,
                let reparse = startLines.lastIndex(where: { $0 <= lastLine - 2 }), reparse > 0,
                bytes.withUnsafeBufferPointer({ new in
                    self.bytes.withUnsafeBufferPointer { old in memcmp(new.baseAddress!, old.baseAddress!, lastLineOffset) == 0 }
                })
            else { return (Document(parsing: bytes), 0) }
            let firstLine = startLines[reparse]
            let offset = startOffsets[reparse]
            let (blocks, startLines, lineStarts) = Self.parse(bytes[offset...])
            let document = Document(
                bytes: bytes, blocks: Array(self.blocks[..<reparse]) + blocks,
                startLines: Array(self.startLines[..<reparse]) + startLines.map { firstLine + $0 },
                startOffsets: Array(startOffsets[..<reparse]) + startLines.map { offset + lineStarts[$0] },
                lastLine: firstLine + lineStarts.count - 1, lastLineOffset: offset + lineStarts[lineStarts.count - 1])
            return (document, reparse)
        }

        /// Top-level blocks with their start lines, and where each line of `bytes` starts.
        private static func parse(_ bytes: ArraySlice<UInt8>) -> (blocks: [Block], startLines: [Int], lineStarts: [Int]) {
            let (lines, lineStarts) = splitLines(bytes)
            var parser = BlockParser(lines: lines)
            let blocks = parser.parse()
            return (blocks, parser.starts, lineStarts)
        }
    }

    /// Inline content as plain text, for labels, accessibility and copying.
    static func plainText(_ inlines: [Inline]) -> String {
        var result = ""
        for inline in inlines {
            switch inline {
            case .text(let text), .code(let text): result += text
            case .emphasis(let children), .strong(let children), .strikethrough(let children), .link(_, let children):
                result += plainText(children)
            case .image(let alt, _): result += alt
            case .softBreak: result += " "
            case .lineBreak: result += "\n"
            }
        }
        return result
    }

    /// Splits into lines and expands leading tabs, so indentation is counted in spaces. Also returns where
    /// each line starts, as an offset from the start of `bytes`.
    private static func splitLines(_ bytes: ArraySlice<UInt8>) -> (lines: [[UInt8]], starts: [Int]) {
        var lines: [[UInt8]] = []
        var starts = [0]
        var current: [UInt8] = []
        var inIndent = true
        for (offset, byte) in bytes.enumerated() {
            switch byte {
            case .newline:
                if current.last == .carriageReturn { current.removeLast() }
                lines.append(current)
                starts.append(offset + 1)
                current.removeAll(keepingCapacity: true)
                inIndent = true
            case .tab where inIndent:
                current.append(contentsOf: repeatElement(.space, count: 4 - current.count % 4))
            default:
                if byte != .space { inIndent = false }
                current.append(byte)
            }
        }
        if current.last == .carriageReturn { current.removeLast() }
        lines.append(current)
        return (lines, starts)
    }
}

// MARK: - Blocks

nonisolated private struct BlockParser {
    let lines: [[UInt8]]
    var index = 0
    /// The line each block `parse()` returned starts on.
    private(set) var starts: [Int] = []

    init(lines: [[UInt8]]) {
        self.lines = lines
    }

    mutating func parse() -> [ChatMarkdown.Block] {
        var blocks: [ChatMarkdown.Block] = []
        while index < lines.count {
            let line = lines[index]
            if line.isBlankLine {
                index += 1
                continue
            }
            let indent = line.leadingSpaces
            starts.append(index)
            if indent >= 4 {
                blocks.append(indentedCode())
            } else if let fence = Self.fence(line, indent: indent) {
                blocks.append(fencedCode(fence))
            } else if let heading = Self.atxHeading(line, indent: indent) {
                blocks.append(heading)
                index += 1
            } else if Self.isRule(line, indent: indent) {
                blocks.append(.rule)
                index += 1
            } else if line[indent] == .greaterThan {
                blocks.append(quote())
            } else if let marker = Self.listMarker(line, indent: indent) {
                blocks.append(list(marker))
            } else if isTableStart(at: index) {
                blocks.append(table())
            } else {
                blocks.append(paragraph())
            }
        }
        return blocks
    }

    // MARK: Leaf blocks

    private mutating func paragraph() -> ChatMarkdown.Block {
        var text: [UInt8] = []
        var lineCount = 0
        while index < lines.count {
            let line = lines[index]
            if line.isBlankLine { break }
            let indent = line.leadingSpaces
            if lineCount > 0, indent < 4 {
                if Self.isSetextUnderline(line, indent: indent, marker: .equals) {
                    index += 1
                    return .heading(level: 1, InlineParser.parse(text))
                }
                if Self.isSetextUnderline(line, indent: indent, marker: .hyphen) {
                    index += 1
                    return .heading(level: 2, InlineParser.parse(text))
                }
                if Self.interruptsParagraph(line, indent: indent) || isTableStart(at: index) { break }
            }
            if lineCount > 0 { text.append(.newline) }
            text.append(contentsOf: line[indent...])
            lineCount += 1
            index += 1
        }
        return .paragraph(InlineParser.parse(text))
    }

    private mutating func indentedCode() -> ChatMarkdown.Block {
        var code: [[UInt8]] = []
        while index < lines.count {
            let line = lines[index]
            if line.isBlankLine {
                code.append([])
            } else if line.leadingSpaces >= 4 {
                code.append(Array(line[4...]))
            } else {
                break
            }
            index += 1
        }
        while code.last?.isEmpty == true { code.removeLast() }
        return .code(language: nil, text: code.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n"))
    }

    private struct Fence {
        var marker: UInt8
        var length: Int
        var indent: Int
        var info: String
    }

    private static func fence(_ line: [UInt8], indent: Int) -> Fence? {
        let marker = line[indent]
        guard marker == .backtick || marker == .tilde else { return nil }
        var end = indent
        while end < line.count, line[end] == marker { end += 1 }
        guard end - indent >= 3 else { return nil }
        let info = line[end...]
        if marker == .backtick, info.contains(.backtick) { return nil }
        return Fence(marker: marker, length: end - indent, indent: indent, info: String(decoding: info, as: UTF8.self))
    }

    private mutating func fencedCode(_ fence: Fence) -> ChatMarkdown.Block {
        index += 1
        var code: [String] = []
        while index < lines.count {
            let line = lines[index]
            let indent = line.leadingSpaces
            if indent < 4, indent < line.count, line[indent] == fence.marker {
                var end = indent
                while end < line.count, line[end] == fence.marker { end += 1 }
                if end - indent >= fence.length, line[end...].allSatisfy({ $0 == .space }) {
                    index += 1
                    break
                }
            }
            code.append(String(decoding: line[min(fence.indent, indent)...], as: UTF8.self))
            index += 1
        }
        let language = fence.info.split(whereSeparator: \.isWhitespace).first.map { String($0) }
        return .code(language: language, text: code.joined(separator: "\n"))
    }

    private static func atxHeading(_ line: [UInt8], indent: Int) -> ChatMarkdown.Block? {
        var end = indent
        while end < line.count, line[end] == .hash, end - indent < 7 { end += 1 }
        let level = end - indent
        guard (1...6).contains(level), end == line.count || line[end] == .space else { return nil }
        var content = Array(line[end...]).trimmingSpaces()
        // A closing run of #s is decoration, not content.
        if let last = content.lastIndex(where: { $0 != .hash }) {
            if last < content.count - 1, content[last] == .space {
                content = Array(content[...last]).trimmingSpaces()
            }
        } else {
            content = []
        }
        return .heading(level: level, InlineParser.parse(content))
    }

    private static func isRule(_ line: [UInt8], indent: Int) -> Bool {
        let marker = line[indent]
        guard marker == .asterisk || marker == .hyphen || marker == .underscore else { return false }
        var count = 0
        for byte in line[indent...] {
            if byte == marker {
                count += 1
            } else if byte != .space {
                return false
            }
        }
        return count >= 3
    }

    private static func isSetextUnderline(_ line: [UInt8], indent: Int, marker: UInt8) -> Bool {
        var end = indent
        while end < line.count, line[end] == marker { end += 1 }
        return end > indent && line[end...].allSatisfy { $0 == .space }
    }

    private static func interruptsParagraph(_ line: [UInt8], indent: Int) -> Bool {
        if fence(line, indent: indent) != nil || atxHeading(line, indent: indent) != nil || isRule(line, indent: indent) {
            return true
        }
        if line[indent] == .greaterThan { return true }
        if let marker = listMarker(line, indent: indent) {
            return !marker.isEmpty && (!marker.isOrdered || marker.number == 1)
        }
        return false
    }

    /// Whether a line would begin a block of its own instead of continuing a lazy paragraph.
    private static func startsBlock(_ line: [UInt8], indent: Int) -> Bool {
        guard indent < 4 else { return false }
        return fence(line, indent: indent) != nil || atxHeading(line, indent: indent) != nil
            || isRule(line, indent: indent) || line[indent] == .greaterThan || listMarker(line, indent: indent) != nil
    }

    // MARK: Containers

    private mutating func quote() -> ChatMarkdown.Block {
        var inner: [[UInt8]] = []
        while index < lines.count {
            let line = lines[index]
            let indent = line.leadingSpaces
            if indent < 4, indent < line.count, line[indent] == .greaterThan {
                var start = indent + 1
                if start < line.count, line[start] == .space { start += 1 }
                inner.append(Array(line[start...]))
            } else if !line.isBlankLine, let last = inner.last, !last.isBlankLine, !Self.startsBlock(line, indent: indent) {
                inner.append(Array(line[indent...]))
            } else {
                break
            }
            index += 1
        }
        var parser = BlockParser(lines: inner)
        return .quote(parser.parse())
    }

    private struct ListMarker {
        var isOrdered: Bool
        /// The bullet character, or the delimiter after the number.
        var symbol: UInt8
        var number: Int
        var contentOffset: Int
        var isEmpty: Bool

        func continues(_ other: ListMarker) -> Bool {
            isOrdered == other.isOrdered && symbol == other.symbol
        }
    }

    private static func listMarker(_ line: [UInt8], indent: Int) -> ListMarker? {
        var position = indent
        let first = line[position]
        var marker: ListMarker
        if first == .hyphen || first == .plus || first == .asterisk {
            position += 1
            marker = ListMarker(isOrdered: false, symbol: first, number: 0, contentOffset: 0, isEmpty: false)
        } else if first.isDigit {
            var number = 0
            while position < line.count, line[position].isDigit, position - indent < 9 {
                number = number * 10 + Int(line[position] - .zero)
                position += 1
            }
            guard position < line.count, line[position] == .period || line[position] == .closeParen else { return nil }
            marker = ListMarker(isOrdered: true, symbol: line[position], number: number, contentOffset: 0, isEmpty: false)
            position += 1
        } else {
            return nil
        }
        let markerEnd = position
        if position == line.count {
            marker.isEmpty = true
            marker.contentOffset = markerEnd + 1
            return marker
        }
        guard line[position] == .space else { return nil }
        while position < line.count, line[position] == .space { position += 1 }
        if position == line.count {
            marker.isEmpty = true
            marker.contentOffset = markerEnd + 1
        } else if position - markerEnd > 4 {
            marker.contentOffset = markerEnd + 1
        } else {
            marker.contentOffset = position
        }
        return marker
    }

    private mutating func list(_ firstMarker: ListMarker) -> ChatMarkdown.Block {
        var items: [ChatMarkdown.ListItem] = []
        var isTight = true
        var marker = firstMarker
        while true {
            let first = lines[index]
            var itemLines: [[UInt8]] = [marker.isEmpty ? [] : Array(first[min(marker.contentOffset, first.count)...])]
            index += 1
            var blankRun = 0
            var nextMarker: ListMarker?
            while index < lines.count {
                let line = lines[index]
                if line.isBlankLine {
                    blankRun += 1
                    index += 1
                    continue
                }
                let indent = line.leadingSpaces
                if indent >= marker.contentOffset {
                    if blankRun > 0 {
                        if itemLines.contains(where: { !$0.isBlankLine }) { isTight = false }
                        itemLines.append(contentsOf: repeatElement([], count: blankRun))
                    }
                    itemLines.append(Array(line[marker.contentOffset...]))
                    blankRun = 0
                    index += 1
                    continue
                }
                if indent < 4, !Self.isRule(line, indent: indent), let candidate = Self.listMarker(line, indent: indent),
                    candidate.continues(marker)
                {
                    nextMarker = candidate
                    if blankRun > 0 { isTight = false }
                    break
                }
                let continuesParagraph =
                    blankRun == 0 && !Self.startsBlock(line, indent: indent) && itemLines.last.map { !$0.isBlankLine } == true
                if continuesParagraph {
                    itemLines.append(Array(line[indent...]))
                    index += 1
                    continue
                }
                break
            }
            items.append(Self.listItem(itemLines))
            guard let next = nextMarker else { break }
            marker = next
        }
        return .list(ChatMarkdown.List(isOrdered: firstMarker.isOrdered, start: firstMarker.number, isTight: isTight, items: items))
    }

    private static func listItem(_ lines: [[UInt8]]) -> ChatMarkdown.ListItem {
        var lines = lines
        var task: Bool?
        if let first = lines.first, first.count >= 3, first[0] == .openBracket, first[2] == .closeBracket,
            first.count == 3 || first[3] == .space
        {
            switch first[1] {
            case .space: task = false
            case UInt8(ascii: "x"), UInt8(ascii: "X"): task = true
            default: break
            }
            if task != nil { lines[0] = Array(first.dropFirst(min(4, first.count))) }
        }
        var parser = BlockParser(lines: lines)
        return ChatMarkdown.ListItem(task: task, blocks: parser.parse())
    }

    // MARK: Tables

    private func isTableStart(at position: Int) -> Bool {
        guard position + 1 < lines.count else { return false }
        let header = lines[position]
        guard header.contains(.pipe), let alignments = Self.delimiterRow(lines[position + 1]) else { return false }
        return Self.cells(header).count == alignments.count
    }

    private static func delimiterRow(_ line: [UInt8]) -> [ChatMarkdown.Alignment]? {
        guard line.contains(.pipe) else { return nil }
        var alignments: [ChatMarkdown.Alignment] = []
        for cell in cells(line) {
            guard !cell.isEmpty else { return nil }
            let left = cell.first == .colon
            let right = cell.last == .colon
            let dashes = cell.dropFirst(left ? 1 : 0).dropLast(right && cell.count > 1 ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == .hyphen }) else { return nil }
            alignments.append(left && right ? .center : left ? .left : right ? .right : .none)
        }
        return alignments.isEmpty ? nil : alignments
    }

    /// Splits a table row on unescaped pipes, dropping the optional outer ones.
    private static func cells(_ line: [UInt8]) -> [[UInt8]] {
        var row = line.trimmingSpaces()
        if row.first == .pipe { row.removeFirst() }
        if row.last == .pipe, row.count < 2 || row[row.count - 2] != .backslash { row.removeLast() }
        var cells: [[UInt8]] = []
        var current: [UInt8] = []
        var position = 0
        while position < row.count {
            let byte = row[position]
            if byte == .backslash, position + 1 < row.count, row[position + 1] == .pipe {
                current.append(.pipe)
                position += 2
                continue
            }
            if byte == .pipe {
                cells.append(current.trimmingSpaces())
                current = []
            } else {
                current.append(byte)
            }
            position += 1
        }
        cells.append(current.trimmingSpaces())
        return cells
    }

    private mutating func table() -> ChatMarkdown.Block {
        let header = Self.cells(lines[index]).map(InlineParser.parse)
        let alignments = Self.delimiterRow(lines[index + 1]) ?? []
        index += 2
        var rows: [[[ChatMarkdown.Inline]]] = []
        while index < lines.count {
            let line = lines[index]
            if line.isBlankLine || Self.startsBlock(line, indent: line.leadingSpaces) { break }
            var row = Self.cells(line).map(InlineParser.parse)
            if row.count > alignments.count { row.removeLast(row.count - alignments.count) }
            while row.count < alignments.count { row.append([]) }
            rows.append(row)
            index += 1
        }
        return .table(ChatMarkdown.Table(alignments: alignments, header: header, rows: rows))
    }
}

// MARK: - Inlines

/// Tokenizes inline text, resolves links as their brackets close, then pairs emphasis delimiters
/// with CommonMark's delimiter-run rules.
nonisolated private struct InlineParser {
    private enum Token {
        case inline(ChatMarkdown.Inline)
        case delimiter(Delimiter)
        case bracket(isImage: Bool, isActive: Bool)
    }

    private struct Delimiter {
        var marker: UInt8
        var count: Int
        var canOpen: Bool
        var canClose: Bool
    }

    private let bytes: [UInt8]
    private var position = 0
    private var tokens: [Token] = []
    private var text: [UInt8] = []

    static func parse(_ bytes: [UInt8]) -> [ChatMarkdown.Inline] {
        guard !bytes.isEmpty else { return [] }
        var parser = InlineParser(bytes: bytes)
        return parser.run()
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private mutating func run() -> [ChatMarkdown.Inline] {
        while position < bytes.count {
            let byte = bytes[position]
            switch byte {
            case .backslash: escape()
            case .backtick: codeSpan()
            case .asterisk, .underscore, .tilde: delimiterRun(byte)
            case .openBracket:
                flush()
                tokens.append(.bracket(isImage: false, isActive: true))
                position += 1
            case .exclamation where position + 1 < bytes.count && bytes[position + 1] == .openBracket:
                flush()
                tokens.append(.bracket(isImage: true, isActive: true))
                position += 2
            case .closeBracket: closeBracket()
            case .lessThan: angleAutolink()
            case .newline: lineEnd()
            case .ampersand: entity()
            case UInt8(ascii: "h"), UInt8(ascii: "w"):
                if !bareURL() {
                    text.append(byte)
                    position += 1
                }
            default:
                text.append(byte)
                position += 1
            }
        }
        flush()
        return Self.resolveEmphasis(tokens)
    }

    private mutating func flush() {
        guard !text.isEmpty else { return }
        tokens.append(.inline(.text(String(decoding: text, as: UTF8.self))))
        text.removeAll(keepingCapacity: true)
    }

    private mutating func escape() {
        let next = position + 1
        if next < bytes.count, bytes[next] == .newline {
            flush()
            tokens.append(.inline(.lineBreak))
            position += 2
        } else if next < bytes.count, bytes[next].isASCIIPunctuation {
            text.append(bytes[next])
            position += 2
        } else {
            text.append(.backslash)
            position += 1
        }
    }

    private mutating func codeSpan() {
        let start = position
        while position < bytes.count, bytes[position] == .backtick { position += 1 }
        let length = position - start
        var search = position
        while search < bytes.count {
            guard bytes[search] == .backtick else {
                search += 1
                continue
            }
            let runStart = search
            while search < bytes.count, bytes[search] == .backtick { search += 1 }
            if search - runStart == length {
                var content = bytes[position..<runStart].map { $0 == .newline ? .space : $0 }
                if content.count > 2, content.first == .space, content.last == .space, content.contains(where: { $0 != .space }) {
                    content = Array(content.dropFirst().dropLast())
                }
                flush()
                tokens.append(.inline(.code(String(decoding: content, as: UTF8.self))))
                position = search
                return
            }
        }
        text.append(contentsOf: bytes[start..<position])
    }

    private mutating func delimiterRun(_ marker: UInt8) {
        let start = position
        while position < bytes.count, bytes[position] == marker { position += 1 }
        let count = position - start
        let before = start > 0 ? bytes[start - 1] : .space
        let after = position < bytes.count ? bytes[position] : .space
        let leftFlanking = !after.isMarkdownWhitespace && (!after.isASCIIPunctuation || before.isMarkdownWhitespace || before.isASCIIPunctuation)
        let rightFlanking = !before.isMarkdownWhitespace && (!before.isASCIIPunctuation || after.isMarkdownWhitespace || after.isASCIIPunctuation)
        var canOpen = leftFlanking
        var canClose = rightFlanking
        if marker == .underscore {
            canOpen = leftFlanking && (!rightFlanking || before.isASCIIPunctuation)
            canClose = rightFlanking && (!leftFlanking || after.isASCIIPunctuation)
        }
        if marker == .tilde, count != 2 {
            text.append(contentsOf: bytes[start..<position])
            return
        }
        flush()
        tokens.append(.delimiter(Delimiter(marker: marker, count: count, canOpen: canOpen, canClose: canClose)))
    }

    private mutating func lineEnd() {
        var trailingSpaces = 0
        while text.last == .space {
            text.removeLast()
            trailingSpaces += 1
        }
        flush()
        tokens.append(.inline(trailingSpaces >= 2 ? .lineBreak : .softBreak))
        position += 1
        while position < bytes.count, bytes[position] == .space { position += 1 }
    }

    private mutating func entity() {
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", "\u{00A0}"),
        ]
        for (name, value) in entities where bytes.starts(with: name.utf8, at: position) {
            text.append(contentsOf: value.utf8)
            position += name.utf8.count
            return
        }
        text.append(.ampersand)
        position += 1
    }

    private mutating func closeBracket() {
        guard let openerIndex = tokens.lastIndex(where: { if case .bracket = $0 { return true } else { return false } }),
            case .bracket(let isImage, let isActive) = tokens[openerIndex]
        else {
            text.append(.closeBracket)
            position += 1
            return
        }
        flush()
        guard isActive, let (destination, end) = linkDestination(after: position + 1) else {
            tokens[openerIndex] = .inline(.text(isImage ? "![" : "["))
            text.append(.closeBracket)
            position += 1
            return
        }
        let children = Self.resolveEmphasis(Array(tokens[(openerIndex + 1)...]))
        tokens.removeSubrange(openerIndex...)
        if isImage {
            tokens.append(.inline(.image(alt: ChatMarkdown.plainText(children), source: destination)))
        } else {
            tokens.append(.inline(.link(destination: destination, children)))
            // Links cannot contain links.
            for index in tokens.indices {
                if case .bracket(false, _) = tokens[index] { tokens[index] = .bracket(isImage: false, isActive: false) }
            }
        }
        position = end
    }

    /// Parses `(destination "title")` starting at `start`; returns the destination and the index after `)`.
    private func linkDestination(after start: Int) -> (String, Int)? {
        guard start < bytes.count, bytes[start] == .openParen else { return nil }
        var cursor = start + 1
        func skipSpace() {
            while cursor < bytes.count, bytes[cursor] == .space || bytes[cursor] == .newline { cursor += 1 }
        }
        skipSpace()
        var destination: [UInt8] = []
        if cursor < bytes.count, bytes[cursor] == .lessThan {
            cursor += 1
            while cursor < bytes.count, bytes[cursor] != .greaterThan {
                guard bytes[cursor] != .newline, bytes[cursor] != .lessThan else { return nil }
                destination.append(bytes[cursor])
                cursor += 1
            }
            guard cursor < bytes.count else { return nil }
            cursor += 1
        } else {
            var depth = 0
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if byte == .space || byte == .newline { break }
                if byte == .backslash, cursor + 1 < bytes.count, bytes[cursor + 1].isASCIIPunctuation {
                    destination.append(bytes[cursor + 1])
                    cursor += 2
                    continue
                }
                if byte == .openParen { depth += 1 }
                if byte == .closeParen {
                    if depth == 0 { break }
                    depth -= 1
                }
                destination.append(byte)
                cursor += 1
            }
        }
        skipSpace()
        if cursor < bytes.count, let close = Self.titleCloser(bytes[cursor]) {
            cursor += 1
            while cursor < bytes.count, bytes[cursor] != close { cursor += 1 }
            guard cursor < bytes.count else { return nil }
            cursor += 1
            skipSpace()
        }
        guard cursor < bytes.count, bytes[cursor] == .closeParen else { return nil }
        return (String(decoding: destination, as: UTF8.self), cursor + 1)
    }

    private static func titleCloser(_ opener: UInt8) -> UInt8? {
        switch opener {
        case .quote, .apostrophe: opener
        case .openParen: .closeParen
        default: nil
        }
    }

    private mutating func angleAutolink() {
        for tag in ["<br>", "<br/>", "<br />", "<BR>"] where bytes.starts(with: tag.utf8, at: position) {
            flush()
            tokens.append(.inline(.lineBreak))
            position += tag.utf8.count
            return
        }
        var cursor = position + 1
        while cursor < bytes.count, bytes[cursor] != .greaterThan, bytes[cursor] != .lessThan, !bytes[cursor].isMarkdownWhitespace {
            cursor += 1
        }
        if cursor < bytes.count, bytes[cursor] == .greaterThan {
            let content = String(decoding: bytes[(position + 1)..<cursor], as: UTF8.self)
            if let colon = content.firstIndex(of: ":"), content.distance(from: content.startIndex, to: colon) >= 2,
                content[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) })
            {
                flush()
                tokens.append(.inline(.link(destination: content, [.text(content)])))
                position = cursor + 1
                return
            }
        }
        text.append(.lessThan)
        position += 1
    }

    /// GFM's extended autolinks: `https://…`, `http://…` and `www.…` after whitespace or `(*_~`.
    private mutating func bareURL() -> Bool {
        if position > 0 {
            let before = bytes[position - 1]
            guard before.isMarkdownWhitespace || before == .openParen || before == .asterisk || before == .underscore
                || before == .tilde
            else { return false }
        }
        let prefixes = ["https://", "http://", "www."]
        guard let prefix = prefixes.first(where: { bytes.starts(with: $0.utf8, at: position) }) else { return false }
        var end = position + prefix.utf8.count
        while end < bytes.count, !bytes[end].isMarkdownWhitespace, bytes[end] != .lessThan { end += 1 }
        // Trailing punctuation belongs to the sentence, as does an unbalanced closing parenthesis.
        while end > position + prefix.utf8.count {
            let last = bytes[end - 1]
            if [UInt8.period, .comma, .colon, .semicolon, .exclamation, .question, .asterisk, .underscore, .tilde, .quote, .apostrophe]
                .contains(last)
            {
                end -= 1
            } else if last == .closeParen {
                let slice = bytes[position..<end]
                if slice.filter({ $0 == .closeParen }).count > slice.filter({ $0 == .openParen }).count { end -= 1 } else { break }
            } else {
                break
            }
        }
        guard end > position + prefix.utf8.count else { return false }
        let label = String(decoding: bytes[position..<end], as: UTF8.self)
        flush()
        tokens.append(.inline(.link(destination: prefix == "www." ? "http://" + label : label, [.text(label)])))
        position = end
        return true
    }

    // MARK: Emphasis

    private final class Node {
        var inline: ChatMarkdown.Inline?
        var delimiter: Delimiter?
        let originalCount: Int
        var previous: Node?
        var next: Node?

        init(inline: ChatMarkdown.Inline?, delimiter: Delimiter?) {
            self.inline = inline
            self.delimiter = delimiter
            originalCount = delimiter?.count ?? 0
        }

        var literal: ChatMarkdown.Inline? {
            if let inline { return inline }
            guard let delimiter, delimiter.count > 0 else { return nil }
            return .text(String(repeating: Character(Unicode.Scalar(delimiter.marker)), count: delimiter.count))
        }
    }

    private static func resolveEmphasis(_ tokens: [Token]) -> [ChatMarkdown.Inline] {
        let head = Node(inline: nil, delimiter: nil)
        var tail = head
        for token in tokens {
            let node: Node
            switch token {
            case .inline(let inline): node = Node(inline: inline, delimiter: nil)
            case .delimiter(let delimiter): node = Node(inline: nil, delimiter: delimiter)
            case .bracket(let isImage, _): node = Node(inline: .text(isImage ? "![" : "["), delimiter: nil)
            }
            tail.next = node
            node.previous = tail
            tail = node
        }

        var closer = head.next
        while let current = closer {
            guard let closing = current.delimiter, closing.canClose, closing.count > 0 else {
                closer = current.next
                continue
            }
            var candidate = current.previous
            var opener: Node?
            while let node = candidate, node !== head {
                if let opening = node.delimiter, opening.marker == closing.marker, opening.canOpen, opening.count > 0 {
                    let oddMatch =
                        closing.marker != .tilde && (opening.canClose || closing.canOpen)
                        && (node.originalCount + current.originalCount) % 3 == 0
                        && !(node.originalCount % 3 == 0 && current.originalCount % 3 == 0)
                    let tildeMismatch = closing.marker == .tilde && opening.count != closing.count
                    if !oddMatch && !tildeMismatch {
                        opener = node
                        break
                    }
                }
                candidate = node.previous
            }
            guard let opener, var opening = opener.delimiter else {
                closer = current.next
                continue
            }
            var closingRun = closing
            let used = closing.marker == .tilde ? closing.count : (closing.count >= 2 && opening.count >= 2 ? 2 : 1)
            var children: [ChatMarkdown.Inline] = []
            var node = opener.next
            while let inner = node, inner !== current {
                if let literal = inner.literal { children.append(literal) }
                node = inner.next
            }
            let wrapped: ChatMarkdown.Inline =
                closing.marker == .tilde ? .strikethrough(merge(children)) : used == 2 ? .strong(merge(children)) : .emphasis(merge(children))
            let container = Node(inline: wrapped, delimiter: nil)
            opener.next = container
            container.previous = opener
            container.next = current
            current.previous = container

            opening.count -= used
            closingRun.count -= used
            opener.delimiter = opening
            current.delimiter = closingRun
            if opening.count == 0 { unlink(opener) }
            if closingRun.count == 0 {
                closer = current.next
                unlink(current)
            }
        }

        var result: [ChatMarkdown.Inline] = []
        var node = head.next
        while let current = node {
            if let literal = current.literal { result.append(literal) }
            node = current.next
        }
        return merge(result)
    }

    private static func unlink(_ node: Node) {
        node.previous?.next = node.next
        node.next?.previous = node.previous
    }

    /// Joins adjacent text runs so renderers see fewer, longer runs.
    private static func merge(_ inlines: [ChatMarkdown.Inline]) -> [ChatMarkdown.Inline] {
        var result: [ChatMarkdown.Inline] = []
        for inline in inlines {
            if case .text(let next) = inline, case .text(let previous) = result.last {
                result[result.count - 1] = .text(previous + next)
            } else {
                result.append(inline)
            }
        }
        return result
    }
}

// MARK: - Bytes

nonisolated private extension UInt8 {
    static let tab = UInt8(ascii: "\t")
    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let exclamation = UInt8(ascii: "!")
    static let quote = UInt8(ascii: "\"")
    static let hash = UInt8(ascii: "#")
    static let ampersand = UInt8(ascii: "&")
    static let apostrophe = UInt8(ascii: "'")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let asterisk = UInt8(ascii: "*")
    static let plus = UInt8(ascii: "+")
    static let comma = UInt8(ascii: ",")
    static let hyphen = UInt8(ascii: "-")
    static let period = UInt8(ascii: ".")
    static let zero = UInt8(ascii: "0")
    static let colon = UInt8(ascii: ":")
    static let semicolon = UInt8(ascii: ";")
    static let lessThan = UInt8(ascii: "<")
    static let equals = UInt8(ascii: "=")
    static let greaterThan = UInt8(ascii: ">")
    static let question = UInt8(ascii: "?")
    static let openBracket = UInt8(ascii: "[")
    static let backslash = UInt8(ascii: "\\")
    static let closeBracket = UInt8(ascii: "]")
    static let underscore = UInt8(ascii: "_")
    static let backtick = UInt8(ascii: "`")
    static let pipe = UInt8(ascii: "|")
    static let tilde = UInt8(ascii: "~")

    var isDigit: Bool { self >= 0x30 && self <= 0x39 }
    var isMarkdownWhitespace: Bool { self == .space || self == .tab || self == .newline || self == .carriageReturn }
    var isASCIIPunctuation: Bool {
        (0x21...0x2F).contains(self) || (0x3A...0x40).contains(self) || (0x5B...0x60).contains(self) || (0x7B...0x7E).contains(self)
    }
}

nonisolated private extension Array where Element == UInt8 {
    var leadingSpaces: Int { firstIndex { $0 != .space } ?? count }
    var isBlankLine: Bool { allSatisfy { $0 == .space || $0 == .tab } }

    func trimmingSpaces() -> [UInt8] {
        guard let first = firstIndex(where: { $0 != .space && $0 != .tab }),
            let last = lastIndex(where: { $0 != .space && $0 != .tab })
        else { return [] }
        return Array(self[first...last])
    }

    func starts(with prefix: String.UTF8View, at offset: Int) -> Bool {
        var index = offset
        for byte in prefix {
            guard index < count, self[index] == byte else { return false }
            index += 1
        }
        return true
    }
}
