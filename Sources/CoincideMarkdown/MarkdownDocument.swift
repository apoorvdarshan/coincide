import Foundation
import Markdown

public struct MarkdownSpan: Sendable, Equatable {
    public struct Style: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let strong = Self(rawValue: 1)
        public static let emphasis = Self(rawValue: 2)
        public static let strike = Self(rawValue: 4)
        public static let code = Self(rawValue: 8)
        public static let inlineMath = Self(rawValue: 16)
        public static let displayMath = Self(rawValue: 32)
        public static let footnoteReference = Self(rawValue: 64)
        public static let keyboard = Self(rawValue: 128)
        public static let superscript = Self(rawValue: 256)
        public static let `subscript` = Self(rawValue: 512)
        public static let math: Self = [.inlineMath, .displayMath]
    }
    public var text: String
    public var style: Style = []
    public var destination: String?
    public var formula: MarkdownFormula? = nil
    /// Authored source for formulas and footnote references, kept for copying and for
    /// showing formulas as written when Render math is off.
    public var source: String?
}

public struct MarkdownListItem: Sendable, Equatable {
    public var checked: Bool?
    public var blocks: [MarkdownBlock]
}

/// GitHub alert markers (`> [!NOTE]`) recognized on the first line of a quote.
public enum MarkdownAlertKind: String, Sendable, CaseIterable {
    case note, tip, important, warning, caution
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public struct MarkdownFootnote: Sendable, Equatable {
    public var number: Int
    public var label: String
    public var blocks: [MarkdownBlock]
}

public indirect enum MarkdownBlock: Sendable, Equatable {
    case paragraph([MarkdownSpan])
    case heading(level: Int, [MarkdownSpan])
    /// `language` is the first info-string word and `meta` the rest. `closed` is false
    /// for a fence still streaming, so diagrams and Run wait for the closing marker.
    case code(language: String, text: String, meta: String = "", closed: Bool = true)
    case math(String)
    case quote([MarkdownBlock])
    case alert(kind: MarkdownAlertKind, blocks: [MarkdownBlock])
    case details(summary: [MarkdownSpan], initiallyOpen: Bool, blocks: [MarkdownBlock])
    case list(start: UInt?, items: [MarkdownListItem])
    case table(headers: [[MarkdownSpan]], rows: [[[MarkdownSpan]]], alignments: [ColumnAlignment])
    case footnotes([MarkdownFootnote])
    case artifactTemplate(CodexArtifactTemplate)
    case rule
    case literal(String)

    public enum ColumnAlignment: Sendable { case left, center, right }
    public static func alert(_ kind: MarkdownAlertKind, _ blocks: [MarkdownBlock]) -> Self { .alert(kind: kind, blocks: blocks) }
    public static func details(summary: [MarkdownSpan], open: Bool, _ blocks: [MarkdownBlock]) -> Self {
        .details(summary: summary, initiallyOpen: open, blocks: blocks)
    }
}

public struct MarkdownParseOptions: Sendable, Hashable {
    /// Renders the safe HTML subset. User-authored text keeps all HTML literal.
    public var rawHTML: Bool
    var footnotes = true
    public init(rawHTML: Bool = true) { self.rawHTML = rawHTML }
}

/// A native, inert rendering model. HTML outside the safe subset is displayed as source,
/// and nothing is ever executed or loaded.
public struct MarkdownDocument: Sendable, Equatable {
    public var blocks: [MarkdownBlock]
    public var footnotes: [MarkdownFootnote] {
        guard case .footnotes(let notes)? = blocks.last else { return [] }
        return notes
    }
    static let parseOptions: ParseOptions = [.disableSmartOpts]

    public init(parsing source: String, options: MarkdownParseOptions = .init(), mathEnabled: Bool = true) {
        self.init(parsing: source, options: options, mathEnabled: mathEnabled, nesting: 0)
    }

    init(parsing source: String, options: MarkdownParseOptions, mathEnabled: Bool, nesting: Int) {
        guard source.utf8.count <= 1_048_576, nesting < 16 else { blocks = [.literal(source)]; return }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // One source-owned pass handles the pinned math flow and note bodies;
        // collision-free markers preserve every authored private-use scalar.
        let lines = normalized.components(separatedBy: "\n")
        let document = Document(parsing: normalized, options: Self.parseOptions)
        guard MarkdownSourceTransform.mayApply(normalized) else {
            blocks = MarkdownBlockBuilder(options: options, nesting: nesting, mathEnabled: mathEnabled).blocks(document, lines: lines); return
        }
        var transform = MarkdownSourceTransform(math: mathEnabled, footnotes: options.footnotes, source: normalized)
        let transformed = transform.apply(lines, document: document)
        // Definitions share the message's numbering, so a note referenced only from another
        // note is still listed. Each label is transformed once, in first-reference order.
        var notes: [[String]] = []
        while notes.count < transform.footnoteOrder.count {
            let text = transform.definitions[transform.footnoteOrder[notes.count]] ?? ""
            notes.append(transform.apply(text.components(separatedBy: "\n"), document: Document(parsing: text, options: Self.parseOptions), collecting: false))
        }
        let builder = MarkdownBlockBuilder(options: options, nesting: nesting, mathEnabled: mathEnabled, formulas: transform.formulas,
            footnotes: transform.footnoteOrder, artifacts: transform.artifacts, separators: true, markers: transform.markers)
        func parse(_ part: [String]) -> Document { Document(parsing: part.joined(separator: "\n"), options: Self.parseOptions) }
        var result = transformed == lines ? builder.blocks(document, lines: lines) : builder.blocks(parse(transformed), lines: transformed)
        if !notes.isEmpty {
            result.append(.footnotes(notes.enumerated().map { index, part in
                MarkdownFootnote(number: index + 1, label: transform.footnoteOrder[index], blocks: builder.blocks(parse(part), lines: part))
            }))
        }
        blocks = result
    }
}

/// Converts swift-markdown nodes into the inert block model.
final class MarkdownBlockBuilder {
    let options: MarkdownParseOptions
    let nesting: Int
    let mathEnabled: Bool
    let mathFormulas: [String: MarkdownFormula]
    let mathClosing: String
    let formulas: [MarkdownSourceFormula]
    let footnotes: [String]
    let artifacts: [CodexArtifactTemplate]
    /// Whether the source passes ran, so sentinel and separator scalars are mapped back.
    let separators: Bool
    let markers: MarkdownSourceMarkers
    private var lines: [String] = []

    init(options: MarkdownParseOptions, nesting: Int, mathEnabled: Bool = true, mathFormulas: [String: MarkdownFormula] = [:], mathClosing: String = "",
         formulas: [MarkdownSourceFormula] = [], footnotes: [String] = [], artifacts: [CodexArtifactTemplate] = [], separators: Bool = false, markers: MarkdownSourceMarkers = .init(source: "")) {
        self.options = options; self.nesting = nesting; self.mathEnabled = mathEnabled; self.mathFormulas = mathFormulas
        self.mathClosing = mathClosing; self.formulas = formulas; self.footnotes = footnotes; self.artifacts = artifacts; self.separators = separators; self.markers = markers
    }

    func blocks(_ document: Document, lines: [String]) -> [MarkdownBlock] {
        self.lines = lines
        return blocks(Array(document.children).map { .node($0) }, depth: 0)
    }

    private func nestedBlocks(_ markdown: String) -> [MarkdownBlock] {
        guard !markdown.allSatisfy(\.isWhitespace) else { return [] }
        var nested = options; nested.footnotes = false
        return MarkdownDocument(parsing: markdown, options: nested, mathEnabled: mathEnabled, nesting: nesting + 1).blocks
    }

    /// A sibling block, or the rest of an HTML block after a `</details>` closed inside it.
    private enum Item { case node(any Markup), html(String) }
    private func blocks(_ nodes: [any Markup], depth: Int) -> [MarkdownBlock] { blocks(nodes.map { .node($0) }, depth: depth) }

    /// Sibling blocks, pairing an opening `<details>` HTML block with its closing block. The
    /// HTML left after a closing tag goes back through the loop, so consecutive disclosures
    /// in one HTML block pair too.
    private func blocks(_ siblings: [Item], depth: Int) -> [MarkdownBlock] {
        var items = siblings, result: [MarkdownBlock] = [], index = 0
        func raw(_ item: Item) -> String? {
            switch item { case .html(let raw): raw; case .node(let node): (node as? HTMLBlock).map { restore($0.rawHTML) } }
        }
        while index < items.count {
            guard options.rawHTML, depth < 64, let html = raw(items[index]) else {
                if case .node(let node) = items[index] { result += block(node, depth: depth) } else if let html = raw(items[index]) { result += htmlBlocks(html) }
                index += 1; continue
            }
            guard let opening = MarkdownHTML.detailsOpening(html) else {
                if let split = MarkdownHTML.splitBeforeUnclosedDetails(html) { result += htmlBlocks(split.before); items[index] = .html(split.rest); continue }
                result += htmlBlocks(html); index += 1; continue
            }
            if let trailing = opening.trailing {
                result.append(.details(summary: opening.summary, open: opening.open, detailsIntroduction(opening.body)))
                if trailing.allSatisfy(\.isWhitespace) { index += 1 } else { items[index] = .html(trailing) }
                continue
            }
            // An incomplete streamed disclosure remains visible, inert source.
            var depthCount = 1, end = index + 1, split: (before: String, after: String)?
            while end < items.count {
                if let closing = raw(items[end]), let found = MarkdownHTML.detailsClose(closing, depth: &depthCount) { split = found; break }
                end += 1
            }
            guard end < items.count else { result.append(.literal(html)); index += 1; continue }
            var content = detailsIntroduction(opening.body) + blocks(Array(items[(index + 1)..<min(end, items.count)]), depth: depth + 1)
            if let split { content += nestedBlocks(split.before) }
            result.append(.details(summary: opening.summary, open: opening.open, content))
            if let split, !split.after.allSatisfy(\.isWhitespace) { items[end] = .html(split.after); index = end } else { index = end + 1 }
        }
        return result
    }

    private func htmlBlocks(_ raw: String) -> [MarkdownBlock] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmed.firstIndex(of: ">"), let formula = mathFormulas[String(trimmed[...end])],
           String(trimmed[...end]) + mathClosing == trimmed { return [.math(formula.latex)] }
        guard options.rawHTML else { return [.literal(raw)] }
        return MarkdownHTML.blocks(raw) ?? [.literal(raw)]
    }

    private func detailsIntroduction(_ raw: String) -> [MarkdownBlock] {
        guard !raw.allSatisfy(\.isWhitespace) else { return [] }
        if let blank = raw.range(of: #"\n[ \t]*\n"#, options: .regularExpression) {
            let introduction = String(raw[..<blank.lowerBound]), body = String(raw[blank.upperBound...])
            let prefix = introduction.allSatisfy(\.isWhitespace) ? [] : htmlBlocks(introduction)
            return prefix + nestedBlocks(body)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let spans = MarkdownHTML.inlinePreservingBreaks(trimmed) { return spans.isEmpty ? [] : [.paragraph(spans)] }
        return htmlBlocks(raw)
    }

    private func block(_ node: any Markup, depth: Int) -> [MarkdownBlock] {
        guard depth < 64 else { return [.literal(node.format())] }
        switch node {
        case let heading as Heading: return [.heading(level: heading.level, spans(Array(heading.children)))]
        case let paragraph as Paragraph: return paragraphBlocks(Array(paragraph.children))
        case let code as CodeBlock:
            let info = (code.language ?? "").trimmingCharacters(in: .whitespaces)
            let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let meta = info.dropFirst(language.count).trimmingCharacters(in: .whitespaces)
            let closed = fenced(code) ? closedFence(code) : true
            if mathEnabled, language.lowercased() == "math", closed { return [.math(code.code)] }
            // Removed footnote definitions can turn a later line into code or HTML on the second parse.
            return [.code(language: language, text: restore(code.code), meta: meta, closed: closed)]
        case let quote as BlockQuote: return [quoteBlock(Array(quote.children), depth: depth)]
        case let list as OrderedList: return [.list(start: list.startIndex, items: items(list, depth: depth))]
        case let list as UnorderedList: return [.list(start: nil, items: items(list, depth: depth))]
        case let table as Table:
            let headers = Array(table.head.cells.map { self.spans(Array($0.children)) })
            let rows = Array(table.body.rows.map { row in Array(row.cells.map { self.spans(Array($0.children)) }) })
            let alignments: [MarkdownBlock.ColumnAlignment] = table.columnAlignments.map { alignment in
                switch alignment { case .center?: .center; case .right?: .right; default: .left }
            }
            return [.table(headers: headers, rows: rows, alignments: alignments)]
        case is ThematicBreak: return [.rule]
        case let html as HTMLBlock:
            let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            if let end = raw.firstIndex(of: ">"), let formula = mathFormulas[String(raw[...end])],
               String(raw[...end]) + mathClosing == raw { return [.math(formula.latex)] }
            return htmlBlocks(restore(html.rawHTML))
        default:
            let children = blocks(Array(node.children), depth: depth + 1)
            return children.isEmpty ? [.literal(node.format())] : children
        }
    }

    /// T3's GitHub alert rules: a marker alone on the quote's first line becomes the title;
    /// a marker sharing its line with other content leaves an ordinary quote.
    private func quoteBlock(_ children: [any Markup], depth: Int) -> MarkdownBlock {
        guard let paragraph = children.first as? Paragraph else { return .quote(blocks(children, depth: depth + 1)) }
        let inlines = Array(paragraph.children)
        var count = 0, marker = ""
        while count < inlines.count, let text = inlines[count] as? Markdown.Text { marker += text.string; count += 1 }
        guard marker.hasPrefix("[!"), marker.hasSuffix("]"), let kind = MarkdownAlertKind(rawValue: String(marker.dropFirst(2).dropLast()).lowercased()),
              count == inlines.count || inlines[count] is SoftBreak else { return .quote(blocks(children, depth: depth + 1)) }
        let remainder = count < inlines.count ? Array(inlines[(count + 1)...]) : []
        let first = remainder.isEmpty ? [] : paragraphBlocks(remainder)
        return .alert(kind, first + blocks(Array(children.dropFirst()), depth: depth + 1))
    }

    /// A paragraph, split around artifact-template cards and display math blocks; a lone
    /// display formula becomes a block too.
    private func paragraphBlocks(_ inlines: [any Markup]) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = [], group: [any Markup] = []
        func flush() {
            while group.first is SoftBreak || group.first is LineBreak || isSeparator(group.first) { group.removeFirst() }
            while group.last is SoftBreak || group.last is LineBreak || isSeparator(group.last) { group.removeLast() }
            defer { group = [] }
            let parts = spans(group)
            guard !parts.isEmpty else { return }
            let visible = parts.filter { !($0.text.allSatisfy(\.isWhitespace) && $0.style.isDisjoint(with: .math)) }
            if visible.count == 1, visible[0].style.contains(.displayMath), visible[0].destination == nil { result.append(.math(visible[0].text)); return }
            result.append(.paragraph(parts))
        }
        for node in inlines {
            if let code = node as? InlineCode, let (kind, index) = markers.decode(code.code) {
                if kind == "A", index < artifacts.count { flush(); result.append(.artifactTemplate(artifacts[index])); continue }
                if kind == "D", index < formulas.count { flush(); result.append(.math(formulas[index].tex)); continue }
            }
            group.append(node)
        }
        flush()
        return result
    }
    /// Text where cmark paired a sentinel's backticks differently than the source pass
    /// expected (raw HTML or code spans the pass could not see): each sentinel goes back to
    /// its authored source, with its own backticks, and separators are dropped.
    private func restore(_ text: String) -> String {
        let marks: Set<Unicode.Scalar> = [markers.open, markers.close, markers.separator]
        guard separators, text.unicodeScalars.contains(where: { marks.contains($0) }) else { return text }
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView(), index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == markers.open, index + 1 < scalars.count, "AMFD".unicodeScalars.contains(scalars[index + 1]) {
                var end = index + 2, number = 0
                while end < scalars.count, end - index < 12, scalars[end].isASCII, let digit = Int(String(scalars[end])) { number = number * 10 + digit; end += 1 }
                var close = end
                while close < scalars.count, scalars[close] == markers.separator || scalars[close] == ">" || scalars[close].properties.isWhitespace { close += 1 }
                if close < scalars.count, scalars[close] == markers.close { end = close + 1 }
                if end > index + 2, let source = authored(Character(scalars[index + 1]), number) {
                    if result.last == "`" { result.removeLast() }
                    result.append(contentsOf: source.unicodeScalars)
                    index = end < scalars.count && scalars[end] == "`" ? end + 1 : end; continue
                }
            }
            if !marks.contains(scalar) { result.append(scalar) }
            index += 1
        }
        return String(result)
    }
    private func authored(_ kind: Character, _ index: Int) -> String? {
        switch kind {
        case "M", "D": index < formulas.count ? formulas[index].source : nil
        case "F": index < footnotes.count ? "[^\(footnotes[index])]" : nil
        case "A": index < artifacts.count ? artifacts[index].displayName : nil
        default: nil
        }
    }
    private func isSeparator(_ node: (any Markup)?) -> Bool {
        guard separators, let text = node as? Markdown.Text else { return false }
        return text.string.unicodeScalars.allSatisfy { $0 == markers.separator || $0.properties.isWhitespace }
    }

    /// Fences start at the block's column (UTF-8 bytes), after any list marker on that line.
    /// An indented code block starts at its own first line, so that line is its content.
    private func fenced(_ code: CodeBlock) -> Bool {
        guard let opening = openingLine(code) else { return false }
        let scalars = Array(opening.unicodeScalars), start = MarkdownSourceTransform.container(scalars, lists: true).end
        let rest = scalars[start...]
        guard rest.starts(with: "```".unicodeScalars) || rest.starts(with: "~~~".unicodeScalars) else { return false }
        let first = code.code.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        func trimmed(_ text: Substring) -> Substring { text.prefix(text.count - text.reversed().prefix { $0 == " " || $0 == "\t" }.count) }
        return code.code.isEmpty || trimmed(first) != trimmed(opening)
    }
    private func openingLine(_ code: CodeBlock) -> Substring? {
        guard let range = code.range, range.lowerBound.line > 0, range.lowerBound.line <= lines.count else { return nil }
        let line = lines[range.lowerBound.line - 1], utf8 = line.utf8
        let offset = min(utf8.count, max(0, range.lowerBound.column - 1))
        guard let start = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex), let index = start.samePosition(in: line) else { return Substring(line) }
        return line[index...]
    }

    private func closedFence(_ code: CodeBlock) -> Bool {
        guard let range = code.range, range.upperBound.line > range.lowerBound.line,
              range.lowerBound.line > 0, range.upperBound.line <= lines.count, let opening = openingLine(code) else { return false }
        let closing = lines[range.upperBound.line - 1]
        guard let marker = opening.firstIndex(where: { $0 == "`" || $0 == "~" }) else { return false }
        let character = opening[marker], count = opening[marker...].prefix(while: { $0 == character }).count
        let tail = closing.trimmingCharacters(in: CharacterSet(charactersIn: " >\t"))
        return count >= 3 && tail.count >= count && tail.allSatisfy { $0 == character }
    }

    private func items(_ node: any Markup, depth: Int) -> [MarkdownListItem] {
        node.children.compactMap { child in
            guard let item = child as? ListItem else { return nil }
            if item.checkbox == nil, let recovered = nestedTask(item, depth: depth) { return recovered }
            return MarkdownListItem(checked: item.checkbox.map { $0 == .checked }, blocks: blocks(Array(item.children), depth: depth + 1))
        }
    }

    /// Require the actual source marker, never decoded entities or escaped/code text.
    private func nestedTask(_ item: ListItem, depth: Int) -> MarkdownListItem? {
        var ancestor = item.parent, nested = false
        while let parent = ancestor {
            if parent is BlockQuote || parent is ListItem { nested = true; break }
            ancestor = parent.parent
        }
        let children = Array(item.children)
        guard nested, let paragraph = children.first as? Paragraph else { return nil }
        let inline = Array(paragraph.children)
        guard let text = inline.first as? Markdown.Text, let location = text.range?.lowerBound,
              location.line > 0, location.line <= lines.count, location.column > 0 else { return nil }
        let raw = Array(lines[location.line - 1].utf8.dropFirst(location.column - 1))
        guard raw.count >= 4, raw[0] == 91, raw[2] == 93, [32, 88, 120].contains(raw[1]),
              raw[3] == 32 || raw[3] == 9 else { return nil }
        let marker = String(decoding: raw.prefix(3), as: UTF8.self)
        guard text.string.hasPrefix(marker) else { return nil }
        let remainder = String(text.string.dropFirst(3).drop(while: { $0 == " " || $0 == "\t" }))
        let first = (remainder.isEmpty ? [] : [MarkdownSpan(text: remainder)]) + spans(Array(inline.dropFirst()))
        var body: [MarkdownBlock] = first.isEmpty ? [] : [.paragraph(first)]
        body += blocks(Array(children.dropFirst()), depth: depth + 1)
        return .init(checked: raw[1] != 32, blocks: body)
    }

    /// Inline siblings. Adjacent text nodes merge before autolinking, and allowlisted
    /// inline HTML tags style the siblings between a matched start and end tag.
    func spans(_ nodes: [any Markup], style: MarkdownSpan.Style = [], destination: String? = nil, depth: Int = 0) -> [MarkdownSpan] {
        guard depth < 64 else { return [.init(text: nodes.map { $0.format() }.joined(), style: style)] }
        var tags: [Int: MarkdownHTML.Kind] = [:], closes: [Int: Int] = [:], matchedEnds = Set<Int>()
        if options.rawHTML {
            var open: [(String, Int)] = []
            for (index, node) in nodes.enumerated() {
                guard let html = node as? InlineHTML else { continue }
                let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.hasPrefix("<!--") { tags[index] = .comment; continue }
                let scalars = Array(raw.unicodeScalars)
                guard let (kind, end) = MarkdownHTML.tag(scalars, at: 0), end == scalars.count else { continue }
                switch kind {
                case .start(let name, _, let selfClosing) where MarkdownHTML.isAllowed(name) && !MarkdownHTML.containers.contains(name) && MarkdownHTML.headings[name] == nil:
                    tags[index] = kind
                    if !selfClosing, !["br", "img", "wbr", "hr"].contains(name) { open.append((name, index)) }
                case .end(let name) where MarkdownHTML.isAllowed(name):
                    tags[index] = kind
                    if let match = open.lastIndex(where: { $0.0 == name }) { closes[open[match].1] = index; matchedEnds.insert(index); open.removeSubrange(match...) }
                default: break
                }
            }
        }
        var result: [MarkdownSpan] = [], text = "", styles: [(Int, MarkdownSpan.Style)] = [], links: [(Int, String?)] = []
        var currentStyle: MarkdownSpan.Style { styles.reduce(style) { $0.union($1.1) } }
        var currentDestination: String? { links.last.map { $0.1 } ?? destination }
        func flush() {
            guard !text.isEmpty else { return }
            if currentDestination == nil, !currentStyle.contains(.code) { result += MarkdownAutolink.spans(text, style: currentStyle) }
            else { result.append(.init(text: text, style: currentStyle, destination: currentDestination)) }
            text = ""
        }
        for (index, node) in nodes.enumerated() {
            if let value = node as? Markdown.Text {
                text += restore(value.string); continue
            }
            flush()
            if let kind = tags[index] {
                switch kind {
                case .comment: continue
                case .start("br", _, _): result.append(.init(text: "\n", style: currentStyle)); continue
                case .start("wbr", _, _), .start("hr", _, _): continue
                case .start("img", let attributes, _):
                    let alt = attributes["alt"] ?? ""
                    result.append(.init(text: alt.isEmpty ? "Image" : "Image: \(alt)", style: currentStyle, destination: attributes["src"] ?? currentDestination)); continue
                case .start(let name, let attributes, _):
                    guard let close = closes[index] else { break }
                    if name == "a" { links.append((close, attributes["href"])) } else { styles.append((close, MarkdownHTML.inlineStyles[name] ?? [])) }
                    continue
                case .end where matchedEnds.contains(index):
                    styles.removeAll { $0.0 == index }; links.removeAll { $0.0 == index }; continue
                default: break
                }
            }
            result += span(node, style: currentStyle, destination: currentDestination, depth: depth + 1)
        }
        flush()
        return result
    }

    private func span(_ node: any Markup, style: MarkdownSpan.Style, destination: String?, depth: Int) -> [MarkdownSpan] {
        var style = style, destination = destination
        switch node {
        case let code as InlineCode:
            if let (kind, index) = markers.decode(code.code) {
                if kind == "M" || kind == "D", index < formulas.count {
                    let formula = formulas[index]
                    let typed = MarkdownFormula(source: formula.source, latex: formula.tex, display: formula.display)
                    return [.init(text: formula.tex, style: style.union(formula.display ? .displayMath : .inlineMath),
                        destination: destination, formula: typed, source: formula.source)]
                }
                if kind == "F", index < footnotes.count { return [.init(text: "\(index + 1)", style: style.union(.footnoteReference), source: "[^\(footnotes[index])]")] }
            }
            return [.init(text: restore(code.code), style: style.union(.code), destination: destination)]
        case is Strong: style.insert(.strong)
        case is Emphasis: style.insert(.emphasis)
        case is Strikethrough: style.insert(.strike)
        case let link as Markdown.Link: destination = link.destination.map(restore)
        case let image as Markdown.Image:
            // Formulas and footnote references in alt text keep their authored source.
            let text = spans(Array(image.children), depth: depth).map { $0.source ?? $0.text }.joined()
            return [.init(text: text.isEmpty ? "Image" : "Image: \(text)", style: style, destination: image.source.map(restore))]
        case is SoftBreak, is LineBreak: return [.init(text: "\n", style: style)]
        case let html as InlineHTML:
            if let formula = mathFormulas[html.rawHTML] {
                return [.init(text: formula.latex, style: style.union(formula.display ? .displayMath : .inlineMath),
                    destination: destination, formula: formula, source: formula.source)]
            }
            if !mathClosing.isEmpty, html.rawHTML == mathClosing { return [] }
            return [.init(text: restore(html.rawHTML), style: style, destination: destination)]
        default: break
        }
        return spans(Array(node.children), style: style, destination: destination, depth: depth)
    }
}

/// Parsing is off the UI actor, with a bounded cache for unchanged transcript rows.
public actor MarkdownParser {
    public static let shared = MarkdownParser()
    private struct Key: Hashable { var source: String; var options: MarkdownParseOptions; var mathEnabled: Bool }
    private var cache: [Key: MarkdownDocument] = [:]
    private var order: [Key] = []
    private var bytes = 0
    public func parse(_ source: String, options: MarkdownParseOptions = .init(), mathEnabled: Bool = true) -> MarkdownDocument {
        let key = Key(source: source, options: options, mathEnabled: mathEnabled)
        if let cached = cache[key] { return cached }
        let document = MarkdownDocument(parsing: source, options: options, mathEnabled: mathEnabled)
        let size = source.utf8.count
        if size <= 262_144 {
            while bytes + size > 2_097_152 || order.count >= 128 {
                guard !order.isEmpty else { break }
                let oldest = order.removeFirst(); bytes -= oldest.source.utf8.count; cache.removeValue(forKey: oldest)
            }
            cache[key] = document; order.append(key); bytes += size
        }
        return document
    }
}
