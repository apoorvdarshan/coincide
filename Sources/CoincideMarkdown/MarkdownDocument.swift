import Foundation
import Markdown

public struct MarkdownSpan: Sendable, Equatable {
    public struct Style: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let strong = Self(rawValue: 1)
        public static let emphasis = Self(rawValue: 2)
        public static let strike = Self(rawValue: 4)
        public static let code = Self(rawValue: 8)
    }
    public var text: String
    public var style: Style = []
    public var destination: String?
    public var formula: MarkdownFormula? = nil
}

public struct MarkdownListItem: Sendable, Equatable {
    public var checked: Bool?
    public var blocks: [MarkdownBlock]
}

public enum MarkdownAlertKind: String, CaseIterable, Sendable {
    case note, tip, important, warning, caution
}

public indirect enum MarkdownBlock: Sendable, Equatable {
    case paragraph([MarkdownSpan])
    case heading(level: Int, [MarkdownSpan])
    case code(language: String, text: String)
    case math(String)
    case quote([MarkdownBlock])
    case alert(kind: MarkdownAlertKind, blocks: [MarkdownBlock])
    case details(summary: [MarkdownSpan], initiallyOpen: Bool, blocks: [MarkdownBlock])
    case list(start: UInt?, items: [MarkdownListItem])
    case table(headers: [[MarkdownSpan]], rows: [[[MarkdownSpan]]], alignments: [ColumnAlignment])
    case rule
    case literal(String)

    public enum ColumnAlignment: Sendable { case left, center, right }
}

/// A native, inert rendering model. HTML is displayed as source, never executed.
public struct MarkdownDocument: Sendable, Equatable {
    public var blocks: [MarkdownBlock]
    public init(parsing source: String, mathEnabled: Bool = true) {
        blocks = Self.parse(source, mathEnabled: mathEnabled, detailsDepth: 0)
    }
    private static func parse(_ source: String, mathEnabled: Bool, detailsDepth: Int) -> [MarkdownBlock] {
        guard source.utf8.count <= 1_048_576, detailsDepth < 16 else { return [.literal(source)] }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let details = MarkdownDetailsSyntax(normalized)
        let math = mathEnabled ? MarkdownMathSyntax(details.source) : nil
        let prepared = math?.source ?? details.source
        let context = Context(mathEnabled: mathEnabled, formulas: math?.opening ?? [:], closing: math?.closing ?? "", details: details.values, detailsDepth: detailsDepth)
        return Self.blocks(Document(parsing: prepared), depth: 0, lines: prepared.components(separatedBy: "\n"), context: context)
    }
    private struct Context {
        let mathEnabled: Bool
        let formulas: [String: MarkdownFormula]
        let closing: String
        let details: [String: MarkdownDetailsSyntax.Value]
        let detailsDepth: Int
    }
    private static func blocks(_ parent: any Markup, depth: Int, lines: [String], context: Context) -> [MarkdownBlock] {
        parent.children.flatMap { block($0, depth: depth, lines: lines, context: context) }
    }
    private static func block(_ node: any Markup, depth: Int, lines: [String], context: Context) -> [MarkdownBlock] {
        guard depth < 64 else { return [.literal(node.format())] }
        switch node {
        case let heading as Heading: return [.heading(level: heading.level, spans(heading, context: context))]
        case let paragraph as Paragraph: return paragraphBlocks(spans(paragraph, context: context))
        case let code as CodeBlock:
            if let detail = context.details[code.language ?? ""] {
                let introduction: [MarkdownBlock] = detail.rawIntroduction.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ? [.paragraph(detail.rawIntroduction)] : []
                let body = introduction + parse(detail.body, mathEnabled: context.mathEnabled, detailsDepth: context.detailsDepth + 1)
                return [.details(summary: detail.summary, initiallyOpen: detail.initiallyOpen, blocks: body)]
            }
            if context.mathEnabled, code.language?.lowercased() == "math", closedFence(code, lines: lines) { return [.math(code.code)] }
            return [.code(language: code.language ?? "", text: code.code)]
        case let quote as BlockQuote:
            if let alert = githubAlert(quote, depth: depth, lines: lines, context: context) { return [alert] }
            return [.quote(blocks(quote, depth: depth + 1, lines: lines, context: context))]
        case let list as OrderedList: return [.list(start: list.startIndex, items: items(list, depth: depth, lines: lines, context: context))]
        case let list as UnorderedList: return [.list(start: nil, items: items(list, depth: depth, lines: lines, context: context))]
        case let table as Table:
            let headers = Array(table.head.cells.map { spans($0, context: context) })
            let rows = Array(table.body.rows.map { row in Array(row.cells.map { spans($0, context: context) }) })
            let alignments: [MarkdownBlock.ColumnAlignment] = table.columnAlignments.map { alignment in
                switch alignment { case .center?: .center; case .right?: .right; default: .left }
            }
            return [.table(headers: headers, rows: rows, alignments: alignments)]
        case is ThematicBreak: return [.rule]
        case let html as HTMLBlock:
            let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("<coincide-math-"), let end = raw.firstIndex(of: ">"),
               let formula = context.formulas[String(raw[...end])], String(raw[...end]) + context.closing == raw {
                return paragraphBlocks([.init(text: formula.source, formula: formula)])
            }
            return [.literal(html.rawHTML)]
        default:
            let children = blocks(node, depth: depth + 1, lines: lines, context: context)
            return children.isEmpty ? [.literal(node.format())] : children
        }
    }
    private static let alertMarker = try! NSRegularExpression(pattern: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\n|$)"#, options: [.caseInsensitive])

    /// Match the first parsed text node, like the pinned remark plugin. Swift
    /// Markdown models ordinary newlines as SoftBreak siblings; a hard break
    /// or styled sibling on the marker's own line must remain an ordinary quote.
    /// Only the marker is removed; subsequent inline styles and blocks survive.
    private static func githubAlert(_ quote: BlockQuote, depth: Int, lines: [String], context: Context) -> MarkdownBlock? {
        let quoted = Array(quote.children)
        guard let paragraph = quoted.first as? Paragraph else { return nil }
        let inline = Array(paragraph.children)
        guard let text = inline.first as? Markdown.Text,
              let match = alertMarker.firstMatch(in: text.string, range: NSRange(text.string.startIndex..., in: text.string)),
              let kindRange = Range(match.range(at: 1), in: text.string),
              let kind = MarkdownAlertKind(rawValue: text.string[kindRange].lowercased()),
              let markerRange = Range(match.range, in: text.string) else { return nil }
        let markerEndsItsLine = text.string[markerRange].hasSuffix("\n")
        let remainder = String(text.string[markerRange.upperBound...])
        var tail = Array(inline.dropFirst())
        if remainder.isEmpty, !markerEndsItsLine, !tail.isEmpty {
            guard tail.first.map({ $0 is SoftBreak }) == true else { return nil }
            tail.removeFirst()
        }
        var firstParagraph: [MarkdownSpan] = remainder.isEmpty ? [] : [.init(text: remainder)]
        for child in tail { firstParagraph += spans(child, context: context) }
        var content: [MarkdownBlock] = firstParagraph.isEmpty ? [] : paragraphBlocks(firstParagraph)
        for child in quoted.dropFirst() { content += block(child, depth: depth + 1, lines: lines, context: context) }
        return .alert(kind: kind, blocks: content)
    }
    private static func paragraphBlocks(_ spans: [MarkdownSpan]) -> [MarkdownBlock] {
        guard spans.contains(where: { $0.formula?.display == true && $0.destination == nil }) else { return [.paragraph(spans)] }
        var result: [MarkdownBlock] = [], plain: [MarkdownSpan] = []
        func flush() {
            while plain.last?.text == "\n" { plain.removeLast() }
            if plain.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { result.append(.paragraph(plain)) }
            plain = []
        }
        for span in spans {
            if let formula = span.formula, formula.display, span.destination == nil { flush(); result.append(.math(formula.latex)) }
            else { if plain.isEmpty && span.text == "\n" { continue }; plain.append(span) }
        }
        flush(); return result
    }
    private static func closedFence(_ code: CodeBlock, lines: [String]) -> Bool {
        guard let range = code.range, range.upperBound.line > range.lowerBound.line,
              range.lowerBound.line > 0, range.upperBound.line <= lines.count else { return false }
        let opening = lines[range.lowerBound.line - 1], closing = lines[range.upperBound.line - 1]
        guard let marker = opening.firstIndex(where: { $0 == "`" || $0 == "~" }) else { return false }
        let character = opening[marker], count = opening[marker...].prefix(while: { $0 == character }).count
        let tail = closing.trimmingCharacters(in: CharacterSet(charactersIn: " >\t"))
        return count >= 3 && tail.count >= count && tail.allSatisfy { $0 == character }
    }
    private static func items(_ node: any Markup, depth: Int, lines: [String], context: Context) -> [MarkdownListItem] {
        node.children.compactMap { child in
            guard let item = child as? ListItem else { return nil }
            if item.checkbox == nil, let task = nestedTask(item, depth: depth, lines: lines, context: context) { return task }
            return MarkdownListItem(checked: item.checkbox.map { $0 == .checked }, blocks: blocks(item, depth: depth + 1, lines: lines, context: context))
        }
    }
    /// The pinned cmark task extension scans the physical line from offset zero,
    /// so a quote prefix prevents it from recognizing an otherwise valid task.
    /// Recover only a nested item's first plain-text marker, verified against
    /// its exact source position: escaped, entity and code spellings stay text.
    private static func nestedTask(_ item: ListItem, depth: Int, lines: [String], context: Context) -> MarkdownListItem? {
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
        var first: [MarkdownSpan] = remainder.isEmpty ? [] : [.init(text: remainder)]
        for child in inline.dropFirst() { first += spans(child, context: context) }
        var body = first.isEmpty ? [] : paragraphBlocks(first)
        for child in children.dropFirst() { body += block(child, depth: depth + 1, lines: lines, context: context) }
        return .init(checked: raw[1] != 32, blocks: body)
    }
    private static func spans(_ node: any Markup, context: Context, style: MarkdownSpan.Style = [], destination: String? = nil, depth: Int = 0) -> [MarkdownSpan] {
        guard depth < 64 else { return [.init(text: node.format(), style: style)] }
        var style = style, destination = destination
        switch node {
        case let text as Markdown.Text: return [.init(text: text.string, style: style, destination: destination)]
        case let code as InlineCode: return [.init(text: code.code, style: style.union(.code), destination: destination)]
        case is Strong: style.insert(.strong)
        case is Emphasis: style.insert(.emphasis)
        case is Strikethrough: style.insert(.strike)
        case let link as Markdown.Link: destination = link.destination
        case let image as Markdown.Image:
            let alt = image.plainText.isEmpty ? "Image" : "Image: \(image.plainText)"
            return [.init(text: alt, style: style, destination: image.source)]
        case is SoftBreak, is LineBreak: return [.init(text: "\n", style: style)]
        case let html as InlineHTML:
            if let formula = context.formulas[html.rawHTML] { return [.init(text: formula.source, style: style, destination: destination, formula: formula)] }
            if !context.closing.isEmpty, html.rawHTML == context.closing { return [] }
            return [.init(text: html.rawHTML, style: style)]
        default: break
        }
        return node.children.flatMap { spans($0, context: context, style: style, destination: destination, depth: depth + 1) }
    }
}

/// Parsing is off the UI actor, with a bounded cache for unchanged transcript rows.
public actor MarkdownParser {
    public static let shared = MarkdownParser()
    private struct Key: Hashable { let source: String; let mathEnabled: Bool }
    private var cache: [Key: MarkdownDocument] = [:]
    private var order: [Key] = []
    private var bytes = 0
    public func parse(_ source: String, mathEnabled: Bool = true) -> MarkdownDocument {
        let key = Key(source: source, mathEnabled: mathEnabled)
        if let cached = cache[key] { return cached }
        let document = MarkdownDocument(parsing: source, mathEnabled: mathEnabled)
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
