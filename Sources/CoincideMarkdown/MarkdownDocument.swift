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
}

public struct MarkdownListItem: Sendable, Equatable {
    public var checked: Bool?
    public var blocks: [MarkdownBlock]
}

public indirect enum MarkdownBlock: Sendable, Equatable {
    case paragraph([MarkdownSpan])
    case heading(level: Int, [MarkdownSpan])
    case code(language: String, text: String)
    case quote([MarkdownBlock])
    case list(start: UInt?, items: [MarkdownListItem])
    case table(headers: [[MarkdownSpan]], rows: [[[MarkdownSpan]]], alignments: [ColumnAlignment])
    case rule
    case literal(String)

    public enum ColumnAlignment: Sendable { case left, center, right }
}

/// A native, inert rendering model. HTML is displayed as source, never executed.
public struct MarkdownDocument: Sendable, Equatable {
    public var blocks: [MarkdownBlock]
    public init(parsing source: String) {
        guard source.utf8.count <= 1_048_576 else { blocks = [.literal(source)]; return }
        let document = Document(parsing: source)
        blocks = Self.blocks(document, depth: 0)
    }
    private static func blocks(_ parent: any Markup, depth: Int) -> [MarkdownBlock] {
        parent.children.flatMap { block($0, depth: depth) }
    }
    private static func block(_ node: any Markup, depth: Int) -> [MarkdownBlock] {
        guard depth < 64 else { return [.literal(node.format())] }
        switch node {
        case let heading as Heading: return [.heading(level: heading.level, spans(heading))]
        case let paragraph as Paragraph: return [.paragraph(spans(paragraph))]
        case let code as CodeBlock: return [.code(language: code.language ?? "", text: code.code)]
        case let quote as BlockQuote: return [.quote(blocks(quote, depth: depth + 1))]
        case let list as OrderedList: return [.list(start: list.startIndex, items: items(list, depth: depth))]
        case let list as UnorderedList: return [.list(start: nil, items: items(list, depth: depth))]
        case let table as Table:
            let headers = Array(table.head.cells.map { spans($0) })
            let rows = Array(table.body.rows.map { row in Array(row.cells.map { spans($0) }) })
            let alignments: [MarkdownBlock.ColumnAlignment] = table.columnAlignments.map { alignment in
                switch alignment { case .center?: .center; case .right?: .right; default: .left }
            }
            return [.table(headers: headers, rows: rows, alignments: alignments)]
        case is ThematicBreak: return [.rule]
        case let html as HTMLBlock: return [.literal(html.rawHTML)]
        default:
            let children = blocks(node, depth: depth + 1)
            return children.isEmpty ? [.literal(node.format())] : children
        }
    }
    private static func items(_ node: any Markup, depth: Int) -> [MarkdownListItem] {
        node.children.compactMap { child in
            guard let item = child as? ListItem else { return nil }
            return MarkdownListItem(checked: item.checkbox.map { $0 == .checked }, blocks: blocks(item, depth: depth + 1))
        }
    }
    private static func spans(_ node: any Markup, style: MarkdownSpan.Style = [], destination: String? = nil, depth: Int = 0) -> [MarkdownSpan] {
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
        case let html as InlineHTML: return [.init(text: html.rawHTML, style: style)]
        default: break
        }
        return node.children.flatMap { spans($0, style: style, destination: destination, depth: depth + 1) }
    }
}

/// Parsing is off the UI actor, with a bounded cache for unchanged transcript rows.
public actor MarkdownParser {
    public static let shared = MarkdownParser()
    private var cache: [String: MarkdownDocument] = [:]
    private var order: [String] = []
    private var bytes = 0
    public func parse(_ source: String) -> MarkdownDocument {
        if let cached = cache[source] { return cached }
        let document = MarkdownDocument(parsing: source)
        let size = source.utf8.count
        if size <= 262_144 {
            while bytes + size > 2_097_152 || order.count >= 128 {
                guard !order.isEmpty else { break }
                let oldest = order.removeFirst(); bytes -= oldest.utf8.count; cache.removeValue(forKey: oldest)
            }
            cache[source] = document; order.append(source); bytes += size
        }
        return document
    }
}
