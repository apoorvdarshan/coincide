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
    case math(String)
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
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let document = Document(parsing: normalized)
        if !normalized.contains("$$"), !normalized.contains("\\[") {
            blocks = Self.blocks(document, depth: 0, lines: lines); return
        }
        var protected = Set<Int>()
        func protect(_ node: any Markup, depth: Int = 0) {
            guard depth < 64 else { return }
            if node is CodeBlock || node is HTMLBlock, let range = node.range {
                for line in range.lowerBound.line...range.upperBound.line { protected.insert(line - 1) }
            } else { for child in node.children { protect(child, depth: depth + 1) } }
        }
        protect(document)
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let dollars = lines.indices.filter { trimmed[$0] == "$$" && !protected.contains($0) }
        let brackets = lines.indices.filter { trimmed[$0] == "\\]" && !protected.contains($0) }
        var dollarIndex = 0, bracketIndex = 0
        var result: [MarkdownBlock] = [], start = 0, index = 0
        while index < lines.count {
            let opening = trimmed[index]
            guard !protected.contains(index), lines[index].prefix(while: { $0 == " " }).count < 4,
                  opening == "$$" || opening == "\\[" else { index += 1; continue }
            while dollarIndex < dollars.count && dollars[dollarIndex] <= index { dollarIndex += 1 }
            while bracketIndex < brackets.count && brackets[bracketIndex] <= index { bracketIndex += 1 }
            let end = opening == "$$" ? (dollarIndex < dollars.count ? dollars[dollarIndex] : nil) : (bracketIndex < brackets.count ? brackets[bracketIndex] : nil)
            guard let end else { index += 1; continue }
            if index > start {
                let part = Array(lines[start..<index])
                result += Self.blocks(Document(parsing: part.joined(separator: "\n")), depth: 0, lines: part)
            }
            result.append(.math(lines[(index + 1)..<end].joined(separator: "\n")))
            index = end + 1; start = index
        }
        if start == 0 { result = Self.blocks(document, depth: 0, lines: lines) }
        else if start < lines.count {
            let part = Array(lines[start...])
            result += Self.blocks(Document(parsing: part.joined(separator: "\n")), depth: 0, lines: part)
        }
        blocks = result
    }
    private static func blocks(_ parent: any Markup, depth: Int, lines: [String]) -> [MarkdownBlock] {
        parent.children.flatMap { block($0, depth: depth, lines: lines) }
    }
    private static func block(_ node: any Markup, depth: Int, lines: [String]) -> [MarkdownBlock] {
        guard depth < 64 else { return [.literal(node.format())] }
        switch node {
        case let heading as Heading: return [.heading(level: heading.level, spans(heading))]
        case let paragraph as Paragraph: return [.paragraph(spans(paragraph))]
        case let code as CodeBlock:
            if code.language?.lowercased() == "math", closedFence(code, lines: lines) { return [.math(code.code)] }
            return [.code(language: code.language ?? "", text: code.code)]
        case let quote as BlockQuote: return [.quote(blocks(quote, depth: depth + 1, lines: lines))]
        case let list as OrderedList: return [.list(start: list.startIndex, items: items(list, depth: depth, lines: lines))]
        case let list as UnorderedList: return [.list(start: nil, items: items(list, depth: depth, lines: lines))]
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
            let children = blocks(node, depth: depth + 1, lines: lines)
            return children.isEmpty ? [.literal(node.format())] : children
        }
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
    private static func items(_ node: any Markup, depth: Int, lines: [String]) -> [MarkdownListItem] {
        node.children.compactMap { child in
            guard let item = child as? ListItem else { return nil }
            return MarkdownListItem(checked: item.checkbox.map { $0 == .checked }, blocks: blocks(item, depth: depth + 1, lines: lines))
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
