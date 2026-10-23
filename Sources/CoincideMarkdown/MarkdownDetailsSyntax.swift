import Foundation
import Markdown

/// Only structural details/summary and a small inert inline-label vocabulary
/// are interpreted. Other HTML remains visible source; no attributes execute.
struct MarkdownDetailsSyntax {
    struct Value {
        let source: String
        let summary: [MarkdownSpan]
        let rawIntroduction: [MarkdownSpan]
        let body: String
        let initiallyOpen: Bool
    }
    let source: String
    let values: [String: Value]
    init(_ source: String) {
        guard source.range(of: "<details", options: .caseInsensitive) != nil else { self.source = source; values = [:]; return }
        let bytes = Array(source.utf8), document = Document(parsing: source)
        var blocked: [Range<Int>] = [], contentBlocked: [Range<Int>] = [], lineStarts = [0]
        for index in bytes.indices where bytes[index] == 10 { lineStarts.append(index + 1) }
        func visit(_ node: any Markup, depth: Int, nested: Bool) {
            guard depth < 64 else { return }
            if node is CodeBlock || node is InlineCode || node is Markdown.Link || node is Markdown.Image {
                if let range = node.range, range.lowerBound.line <= lineStarts.count, range.upperBound.line <= lineStarts.count {
                    let start = lineStarts[range.lowerBound.line - 1] + range.lowerBound.column - 1
                    let end = lineStarts[range.upperBound.line - 1] + range.upperBound.column - 1
                    if start >= 0, start <= end, end <= bytes.count { blocked.append(start..<end); contentBlocked.append(start..<end) }
                }
                return
            }
            if let html = node as? HTMLBlock, nested || !html.rawHTML.lowercased().hasPrefix("<details") {
                if let range = node.range, range.lowerBound.line <= lineStarts.count, range.upperBound.line <= lineStarts.count {
                    let start = lineStarts[range.lowerBound.line - 1] + range.lowerBound.column - 1
                    let end = lineStarts[range.upperBound.line - 1] + range.upperBound.column - 1
                    if start >= 0, start <= end, end <= bytes.count { blocked.append(start..<end) }
                }
                return
            }
            for child in node.children { visit(child, depth: depth + 1, nested: nested || node is BlockQuote || node is ListItem) }
        }
        visit(document, depth: 0, nested: false)
        var mask = [Bool](repeating: false, count: bytes.count), bodyMask = [Bool](repeating: false, count: bytes.count)
        for range in blocked { for index in range { mask[index] = true } }
        for range in contentBlocked { for index in range { bodyMask[index] = true } }
        var id = "coincide-details-" + UUID().uuidString.lowercased()
        while source.contains(id) { id += "x" }
        var values: [String: Value] = [:], result = Data(), copied = 0, cursor = 0
        while cursor < bytes.count, values.count < 128 {
            guard !mask[cursor], bytes[cursor] == 60, let opening = Self.tag(bytes, at: cursor), opening.name == "details", !opening.closing,
                  Self.isBlockStart(bytes, at: cursor) else { cursor += 1; continue }
            guard let parsed = Self.read(bytes, opening: opening, blocked: bodyMask) else { break }
            guard let value = parsed.value else { cursor = parsed.end; continue }
            let key = id + "-" + String(values.count)
            values[key] = value
            result.append(contentsOf: bytes[copied..<cursor])
            result.append(contentsOf: ("\n\n```" + key + "\n```\n\n").utf8)
            copied = parsed.end; cursor = parsed.end
        }
        result.append(contentsOf: bytes[copied...]); self.source = String(decoding: result, as: UTF8.self); self.values = values
    }
    private static func isBlockStart(_ bytes: [UInt8], at index: Int) -> Bool {
        var start = index
        while start > 0 && bytes[start - 1] != 10 { start -= 1 }
        return index - start <= 3 && bytes[start..<index].allSatisfy { $0 == 32 }
    }
    private struct Tag { let range: Range<Int>; let name: String; let closing: Bool; let attributes: Set<String> }
    private static func tag(_ bytes: [UInt8], at start: Int) -> Tag? {
        guard bytes[start] == 60 else { return nil }
        var cursor = start + 1, closing = false
        if cursor < bytes.count, bytes[cursor] == 47 { closing = true; cursor += 1 }
        let nameStart = cursor
        while cursor < bytes.count, (65...90).contains(bytes[cursor]) || (97...122).contains(bytes[cursor]) || (48...57).contains(bytes[cursor]) || bytes[cursor] == 45 || bytes[cursor] == 58 { cursor += 1 }
        guard cursor > nameStart, cursor - start <= 4_096 else { return nil }
        let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
        var attributes: Set<String> = []
        while cursor < bytes.count, cursor - start <= 4_096 {
            while cursor < bytes.count && [9, 10, 13, 32, 47].contains(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.count else { return nil }
            if bytes[cursor] == 62 { return .init(range: start..<(cursor + 1), name: name, closing: closing, attributes: attributes) }
            let attributeStart = cursor
            while cursor < bytes.count, bytes[cursor] != 61, bytes[cursor] != 62, ![9, 10, 13, 32, 47].contains(bytes[cursor]) { cursor += 1 }
            guard cursor > attributeStart else { return nil }
            attributes.insert(String(decoding: bytes[attributeStart..<cursor], as: UTF8.self).lowercased())
            while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
            if cursor < bytes.count, bytes[cursor] == 61 {
                cursor += 1
                while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
                if cursor < bytes.count, bytes[cursor] == 34 || bytes[cursor] == 39 {
                    let quote = bytes[cursor]; cursor += 1
                    while cursor < bytes.count && bytes[cursor] != quote { cursor += 1 }
                    guard cursor < bytes.count else { return nil }; cursor += 1
                } else { while cursor < bytes.count && ![9, 10, 13, 32, 62].contains(bytes[cursor]) { cursor += 1 } }
            }
        }
        return nil
    }
    private static func read(_ bytes: [UInt8], opening: Tag, blocked: [Bool]) -> (value: Value?, end: Int)? {
        var cursor = opening.range.upperBound, depth = 1, summary: Range<Int>?, summaryContent: Range<Int>?
        while cursor < bytes.count {
            guard !blocked[cursor], bytes[cursor] == 60 else { cursor += 1; continue }
            if bytes[cursor...].starts(with: Array("<!--".utf8)) {
                let tail = String(decoding: bytes[cursor...], as: UTF8.self)
                guard let end = tail.range(of: "-->") else { return nil }
                cursor += tail[..<end.upperBound].utf8.count; continue
            }
            guard let tag = tag(bytes, at: cursor) else { cursor += 1; continue }
            if ["script", "style", "pre", "textarea", "code"].contains(tag.name), !tag.closing {
                // Structural tokens inside raw-text HTML are never controls.
                let tail = String(decoding: bytes[tag.range.upperBound...], as: UTF8.self)
                guard let end = tail.range(of: "</" + tag.name + ">", options: .caseInsensitive) else { return nil }
                cursor = tag.range.upperBound + tail[..<end.upperBound].utf8.count; continue
            }
            if tag.name == "details" {
                depth += tag.closing ? -1 : 1
                guard depth <= 16 else { return nil }
                if depth == 0 {
                    let start = opening.range.upperBound, end = tag.range.lowerBound
                    let raw = String(decoding: bytes[start..<end], as: UTF8.self)
                    let prefixLength: Int
                    if let blank = raw.range(of: #"\n[ \t]*\n"#, options: .regularExpression) { prefixLength = raw[..<blank.upperBound].utf8.count }
                    else { prefixLength = raw.utf8.count }
                    let boundary = start + prefixLength
                    var introduction = Data(), body = Data()
                    for index in start..<end where summary?.contains(index) != true {
                        if index < boundary { introduction.append(bytes[index]) } else { body.append(bytes[index]) }
                    }
                    let title: [MarkdownSpan]
                    if let summaryContent { guard let parsed = inlineHTML(String(decoding: bytes[summaryContent], as: UTF8.self)) else { return (nil, tag.range.upperBound) }; title = parsed }
                    else { title = [] }
                    guard let intro = inlineHTML(String(decoding: introduction, as: UTF8.self)) else { return (nil, tag.range.upperBound) }
                    return (.init(source: String(decoding: bytes[opening.range.lowerBound..<tag.range.upperBound], as: UTF8.self), summary: title, rawIntroduction: intro, body: String(decoding: body, as: UTF8.self), initiallyOpen: opening.attributes.contains("open")), tag.range.upperBound)
                }
            }
            if depth == 1, tag.name == "summary", !tag.closing, summary == nil {
                var end = tag.range.upperBound
                while end < bytes.count {
                    if bytes[end] == 60, let close = Self.tag(bytes, at: end), close.name == "summary", close.closing {
                        summary = tag.range.lowerBound..<close.range.upperBound; summaryContent = tag.range.upperBound..<close.range.lowerBound; break
                    }
                    end += 1
                }
                guard let summary else { return nil }; cursor = summary.upperBound; continue
            }
            cursor = tag.range.upperBound
        }
        return nil
    }
    private static func inlineHTML(_ source: String) -> [MarkdownSpan]? {
        let bytes = Array(source.utf8)
        var result: [MarkdownSpan] = [], stack: [(String, MarkdownSpan.Style)] = [], cursor = 0, start = 0
        func append(_ end: Int) {
            guard end > start else { return }
            let style = stack.reduce(MarkdownSpan.Style()) { $0.union($1.1) }
            result.append(.init(text: decode(String(decoding: bytes[start..<end], as: UTF8.self)), style: style))
        }
        while cursor < bytes.count {
            guard bytes[cursor] == 60, let tag = tag(bytes, at: cursor) else { cursor += 1; continue }
            append(cursor)
            let style: MarkdownSpan.Style
            switch tag.name { case "b", "strong": style = .strong; case "i", "em": style = .emphasis; case "s", "del": style = .strike; case "code": style = .code; case "br": style = []; default: return nil }
            if tag.name == "br" { result.append(.init(text: "\n")) }
            else if tag.closing { guard stack.last?.0 == tag.name else { return nil }; stack.removeLast() }
            else { guard stack.count < 32 else { return nil }; stack.append((tag.name, style)) }
            cursor = tag.range.upperBound; start = cursor
        }
        append(bytes.count); return stack.isEmpty ? result : nil
    }
    private static func decode(_ source: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"&(?:amp|lt|gt|quot|apos|nbsp|#[0-9]+|#x[0-9a-fA-F]+);"#) else { return source }
        var result = source
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range]), names = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": "\u{a0}"]
            let replacement: String?
            if let named = names[token] { replacement = named }
            else {
                let hex = token.hasPrefix("&#x"), digits = token.dropFirst(hex ? 3 : 2).dropLast()
                replacement = UInt32(digits, radix: hex ? 16 : 10).flatMap(UnicodeScalar.init).map(String.init)
            }
            if let replacement { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}
