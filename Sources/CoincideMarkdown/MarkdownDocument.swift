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
    case code(language: String, text: String, meta: String, closed: Bool)
    case math(String)
    case quote([MarkdownBlock])
    case alert(MarkdownAlertKind, [MarkdownBlock])
    case details(summary: [MarkdownSpan], open: Bool, [MarkdownBlock])
    case list(start: UInt?, items: [MarkdownListItem])
    case table(headers: [[MarkdownSpan]], rows: [[[MarkdownSpan]]], alignments: [ColumnAlignment])
    case footnotes([MarkdownFootnote])
    case artifactTemplate(CodexArtifactTemplate)
    case rule
    case literal(String)

    public enum ColumnAlignment: Sendable { case left, center, right }
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

    public init(parsing source: String, options: MarkdownParseOptions = .init()) { self.init(parsing: source, options: options, nesting: 0) }

    init(parsing source: String, options: MarkdownParseOptions, nesting: Int) {
        guard source.utf8.count <= 1_048_576, nesting < 6 else { blocks = [.literal(source)]; return }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let document = Document(parsing: normalized, options: Self.parseOptions)
        let transforms = MarkdownSourceTransform.mayApply(normalized)
        guard transforms || normalized.contains("$$") || normalized.contains("\\[") else {
            blocks = MarkdownBlockBuilder(options: options, nesting: nesting).blocks(document, lines: lines); return
        }
        var excluded = Self.protectedLines(document)
        let segments = Self.displayMathSegments(lines, protected: excluded)
        for case .math(_, let range) in segments { excluded.formUnion(range) }
        var transform = MarkdownSourceTransform(footnotes: options.footnotes)
        let transformed = transforms ? transform.apply(lines, excluded: excluded) : lines
        let builder = MarkdownBlockBuilder(options: options, nesting: nesting, formulas: transform.formulas, footnotes: transform.footnoteOrder, artifacts: transform.artifacts)
        var result: [MarkdownBlock] = []
        if segments == [.markdown(0..<lines.count)], transformed == lines {
            result = builder.blocks(document, lines: lines)
        } else {
            for segment in segments {
                switch segment {
                case .markdown(let range):
                    let part = Array(transformed[range])
                    result += builder.blocks(Document(parsing: part.joined(separator: "\n"), options: Self.parseOptions), lines: part)
                case .math(let tex, _): result.append(.math(tex))
                }
            }
        }
        if !transform.footnoteOrder.isEmpty {
            var nested = options; nested.footnotes = false
            result.append(.footnotes(transform.footnoteOrder.enumerated().map { index, label in
                MarkdownFootnote(number: index + 1, label: label, blocks: MarkdownDocument(parsing: transform.definitions[label] ?? "", options: nested, nesting: nesting + 1).blocks)
            }))
        }
        blocks = result
    }

    /// Lines owned by code and HTML blocks, which source passes never rewrite.
    static func protectedLines(_ document: Document) -> Set<Int> {
        var protected = Set<Int>()
        func protect(_ node: any Markup, depth: Int = 0) {
            guard depth < 64 else { return }
            if node is CodeBlock || node is HTMLBlock, let range = node.range {
                for line in range.lowerBound.line...max(range.lowerBound.line, range.upperBound.line) { protected.insert(line - 1) }
            } else { for child in node.children { protect(child, depth: depth + 1) } }
        }
        protect(document)
        return protected
    }

    enum Segment: Equatable { case markdown(Range<Int>), math(String, ClosedRange<Int>) }

    /// Closed whole-line `$$ … $$` and `\[ … \]` formulas outside code and HTML.
    static func displayMathSegments(_ lines: [String], protected: Set<Int>) -> [Segment] {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let dollars = lines.indices.filter { trimmed[$0] == "$$" && !protected.contains($0) }
        let brackets = lines.indices.filter { trimmed[$0] == "\\]" && !protected.contains($0) }
        guard !dollars.isEmpty || !brackets.isEmpty else { return [.markdown(0..<lines.count)] }
        var dollarIndex = 0, bracketIndex = 0
        var result: [Segment] = [], start = 0, index = 0
        while index < lines.count {
            let opening = trimmed[index]
            guard !protected.contains(index), lines[index].prefix(while: { $0 == " " }).count < 4,
                  opening == "$$" || opening == "\\[" else { index += 1; continue }
            while dollarIndex < dollars.count && dollars[dollarIndex] <= index { dollarIndex += 1 }
            while bracketIndex < brackets.count && brackets[bracketIndex] <= index { bracketIndex += 1 }
            let end = opening == "$$" ? (dollarIndex < dollars.count ? dollars[dollarIndex] : nil) : (bracketIndex < brackets.count ? brackets[bracketIndex] : nil)
            guard let end else { index += 1; continue }
            if index > start { result.append(.markdown(start..<index)) }
            result.append(.math(lines[(index + 1)..<end].joined(separator: "\n"), index...end))
            index = end + 1; start = index
        }
        if start < lines.count || result.isEmpty { result.append(.markdown(start..<lines.count)) }
        return result
    }
}

/// Converts swift-markdown nodes into the inert block model.
final class MarkdownBlockBuilder {
    let options: MarkdownParseOptions
    let nesting: Int
    let formulas: [MarkdownFormula]
    let footnotes: [String]
    let artifacts: [CodexArtifactTemplate]
    private var lines: [String] = []

    init(options: MarkdownParseOptions, nesting: Int, formulas: [MarkdownFormula] = [], footnotes: [String] = [], artifacts: [CodexArtifactTemplate] = []) {
        self.options = options; self.nesting = nesting; self.formulas = formulas; self.footnotes = footnotes; self.artifacts = artifacts
    }

    func blocks(_ document: Document, lines: [String]) -> [MarkdownBlock] {
        self.lines = lines
        return blocks(Array(document.children), depth: 0)
    }

    private func nestedBlocks(_ markdown: String) -> [MarkdownBlock] {
        guard !markdown.allSatisfy(\.isWhitespace) else { return [] }
        var nested = options; nested.footnotes = false
        return MarkdownDocument(parsing: markdown, options: nested, nesting: nesting + 1).blocks
    }

    /// Sibling blocks, pairing an opening `<details>` HTML block with its closing block.
    private func blocks(_ nodes: [any Markup], depth: Int) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = [], index = 0
        while index < nodes.count {
            guard options.rawHTML, depth < 64, let html = nodes[index] as? HTMLBlock, let opening = MarkdownHTML.detailsOpening(html.rawHTML) else {
                result += block(nodes[index], depth: depth); index += 1; continue
            }
            if let trailing = opening.trailing {
                result.append(.details(summary: opening.summary, open: opening.open, nestedBlocks(opening.body)))
                if !trailing.allSatisfy(\.isWhitespace) { result += htmlBlocks(trailing) }
                index += 1; continue
            }
            // Unclosed details extend to the end of their container, as an HTML parser would.
            var depthCount = 1, end = index + 1, split: (before: String, after: String)?
            while end < nodes.count {
                if let closing = nodes[end] as? HTMLBlock, let found = MarkdownHTML.detailsClose(closing.rawHTML, depth: &depthCount) { split = found; break }
                end += 1
            }
            var content = nestedBlocks(opening.body) + blocks(Array(nodes[(index + 1)..<min(end, nodes.count)]), depth: depth + 1)
            if let split { content += nestedBlocks(split.before) }
            result.append(.details(summary: opening.summary, open: opening.open, content))
            if let split, !split.after.allSatisfy(\.isWhitespace) { result += htmlBlocks(split.after) }
            index = end + 1
        }
        return result
    }

    private func htmlBlocks(_ raw: String) -> [MarkdownBlock] {
        guard options.rawHTML else { return [.literal(raw)] }
        return MarkdownHTML.blocks(raw) ?? [.literal(raw)]
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
            if language.lowercased() == "math", closed { return [.math(code.code)] }
            return [.code(language: language, text: code.code, meta: meta, closed: closed)]
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
        case let html as HTMLBlock: return htmlBlocks(html.rawHTML)
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
              count == inlines.count || inlines[count] is SoftBreak || inlines[count] is LineBreak else { return .quote(blocks(children, depth: depth + 1)) }
        let remainder = count < inlines.count ? Array(inlines[(count + 1)...]) : []
        let first = remainder.isEmpty ? [] : paragraphBlocks(remainder)
        return .alert(kind, first + blocks(Array(children.dropFirst()), depth: depth + 1))
    }

    /// A paragraph, split around artifact-template cards; a lone display formula becomes a block.
    private func paragraphBlocks(_ inlines: [any Markup]) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = [], group: [any Markup] = []
        func flush() {
            while group.first is SoftBreak || group.first is LineBreak { group.removeFirst() }
            while group.last is SoftBreak || group.last is LineBreak { group.removeLast() }
            defer { group = [] }
            let parts = spans(group)
            guard !parts.isEmpty else { return }
            let visible = parts.filter { !($0.text.allSatisfy(\.isWhitespace) && $0.style.isDisjoint(with: .math)) }
            if visible.count == 1, visible[0].style.contains(.displayMath), visible[0].destination == nil { result.append(.math(visible[0].text)); return }
            result.append(.paragraph(parts))
        }
        for node in inlines {
            if let code = node as? InlineCode, let (kind, index) = MarkdownSourceTransform.decode(code.code), kind == "A", index < artifacts.count {
                flush(); result.append(.artifactTemplate(artifacts[index])); continue
            }
            group.append(node)
        }
        flush()
        return result
    }

    private func fenced(_ code: CodeBlock) -> Bool {
        guard let range = code.range, range.lowerBound.line > 0, range.lowerBound.line <= lines.count else { return false }
        let opening = lines[range.lowerBound.line - 1].drop { $0 == " " || $0 == ">" || $0 == "\t" }
        return opening.hasPrefix("```") || opening.hasPrefix("~~~")
    }

    private func closedFence(_ code: CodeBlock) -> Bool {
        guard let range = code.range, range.upperBound.line > range.lowerBound.line,
              range.lowerBound.line > 0, range.upperBound.line <= lines.count else { return false }
        let opening = lines[range.lowerBound.line - 1], closing = lines[range.upperBound.line - 1]
        guard let marker = opening.firstIndex(where: { $0 == "`" || $0 == "~" }) else { return false }
        let character = opening[marker], count = opening[marker...].prefix(while: { $0 == character }).count
        let tail = closing.trimmingCharacters(in: CharacterSet(charactersIn: " >\t"))
        return count >= 3 && tail.count >= count && tail.allSatisfy { $0 == character }
    }

    private func items(_ node: any Markup, depth: Int) -> [MarkdownListItem] {
        node.children.compactMap { child in
            guard let item = child as? ListItem else { return nil }
            return MarkdownListItem(checked: item.checkbox.map { $0 == .checked }, blocks: blocks(Array(item.children), depth: depth + 1))
        }
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
            if let value = node as? Markdown.Text { text += value.string; continue }
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
            if let (kind, index) = MarkdownSourceTransform.decode(code.code) {
                if kind == "M", index < formulas.count {
                    let formula = formulas[index]
                    return [.init(text: formula.tex, style: style.union(formula.display ? .displayMath : .inlineMath), destination: destination, source: formula.source)]
                }
                if kind == "F", index < footnotes.count { return [.init(text: "\(index + 1)", style: style.union(.footnoteReference), source: "[^\(footnotes[index])]")] }
            }
            return [.init(text: code.code, style: style.union(.code), destination: destination)]
        case is Strong: style.insert(.strong)
        case is Emphasis: style.insert(.emphasis)
        case is Strikethrough: style.insert(.strike)
        case let link as Markdown.Link: destination = link.destination
        case let image as Markdown.Image:
            let alt = image.plainText.isEmpty ? "Image" : "Image: \(image.plainText)"
            return [.init(text: alt, style: style, destination: image.source)]
        case is SoftBreak, is LineBreak: return [.init(text: "\n", style: style)]
        case let html as InlineHTML: return [.init(text: html.rawHTML, style: style, destination: destination)]
        default: break
        }
        return spans(Array(node.children), style: style, destination: destination, depth: depth)
    }
}

/// Parsing is off the UI actor, with a bounded cache for unchanged transcript rows.
public actor MarkdownParser {
    public static let shared = MarkdownParser()
    private struct Key: Hashable { var source: String; var options: MarkdownParseOptions }
    private var cache: [Key: MarkdownDocument] = [:]
    private var order: [Key] = []
    private var bytes = 0
    public func parse(_ source: String, options: MarkdownParseOptions = .init()) -> MarkdownDocument {
        let key = Key(source: source, options: options)
        if let cached = cache[key] { return cached }
        let document = MarkdownDocument(parsing: source, options: options)
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
