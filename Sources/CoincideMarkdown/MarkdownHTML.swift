import Foundation

/// A small, inert HTML subset for agent replies: `<details>/<summary>`, `<br>`, `<kbd>`,
/// `<sub>/<sup>`, emphasis, code, `<a href>`, `<img alt>`, headings and transparent
/// containers. Nothing is executed or loaded; any other element keeps the block literal.
enum MarkdownHTML {
    enum Kind: Equatable {
        case text(String)
        case start(String, [String: String], selfClosing: Bool)
        case end(String)
        case comment
        case other
    }
    struct Token: Equatable { var kind: Kind; var range: Range<Int> }

    static let inlineStyles: [String: MarkdownSpan.Style] = [
        "b": .strong, "strong": .strong, "i": .emphasis, "em": .emphasis, "s": .strike, "del": .strike, "strike": .strike,
        "code": .code, "tt": .code, "samp": .code, "kbd": .keyboard, "sub": .subscript, "sup": .superscript,
        "mark": [], "u": [], "ins": [], "span": [], "small": [], "abbr": [], "cite": [], "q": [], "var": .emphasis, "dfn": .emphasis, "time": []
    ]
    static let containers: Set<String> = ["p", "div", "center", "section", "article", "header", "footer", "figure", "figcaption", "blockquote"]
    static let headings: [String: Int] = ["h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6]
    static let other: Set<String> = ["br", "hr", "img", "a", "pre", "details", "summary", "wbr"]
    static func isAllowed(_ name: String) -> Bool { inlineStyles[name] != nil || containers.contains(name) || headings[name] != nil || other.contains(name) }
    private static let rawText: Set<String> = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext", "noscript", "template"]

    static func tokenize(_ raw: String) -> (scalars: [Unicode.Scalar], tokens: [Token]) {
        let s = Array(raw.unicodeScalars)
        var tokens: [Token] = [], index = 0, textStart = 0
        func flushText(_ end: Int) {
            if end > textStart { tokens.append(.init(kind: .text(String(String.UnicodeScalarView(s[textStart..<end]))), range: textStart..<end)) }
        }
        func starts(_ prefix: String, at position: Int) -> Bool {
            let p = Array(prefix.unicodeScalars)
            return position + p.count <= s.count && Array(s[position..<(position + p.count)]) == p
        }
        while index < s.count {
            guard s[index] == "<" else { index += 1; continue }
            if starts("<!--", at: index) {
                flushText(index)
                var end = index + 4
                while end < s.count, !starts("-->", at: end) { end += 1 }
                end = min(s.count, end + 3)
                tokens.append(.init(kind: .comment, range: index..<end)); index = end; textStart = end; continue
            }
            if starts("<!", at: index) || starts("<?", at: index) {
                flushText(index)
                var end = index + 2
                while end < s.count, s[end] != ">" { end += 1 }
                end = min(s.count, end + 1)
                tokens.append(.init(kind: .other, range: index..<end)); index = end; textStart = end; continue
            }
            guard let (kind, end) = tag(s, at: index) else { index += 1; continue }
            flushText(index)
            tokens.append(.init(kind: kind, range: index..<end)); index = end; textStart = end
            if case .start(let name, _, false) = kind, rawText.contains(name) {
                // Raw-text elements end only at their own closing tag.
                var close = index
                while close < s.count, !(s[close] == "<" && starts("</", at: close) && String(String.UnicodeScalarView(s[(close + 2)..<min(s.count, close + 2 + name.count)])).lowercased() == name) { close += 1 }
                if close > index { tokens.append(.init(kind: .other, range: index..<close)) }
                index = close; textStart = close
            }
        }
        flushText(s.count)
        return (s, tokens)
    }

    /// One start or end tag beginning at `start`, with lowercased name and attributes.
    static func tag(_ s: [Unicode.Scalar], at start: Int) -> (Kind, Int)? {
        guard start + 1 < s.count, s[start] == "<" else { return nil }
        var index = start + 1
        let closing = s[index] == "/"
        if closing { index += 1 }
        let nameStart = index
        while index < s.count, s[index].isASCII, s[index].properties.isAlphabetic || (index > nameStart && (s[index].properties.numericType != nil || s[index] == "-")) { index += 1 }
        guard index > nameStart else { return nil }
        let name = String(String.UnicodeScalarView(s[nameStart..<index])).lowercased()
        var attributes: [String: String] = [:]
        while index < s.count {
            while index < s.count, s[index].properties.isWhitespace { index += 1 }
            guard index < s.count else { return nil }
            if s[index] == ">" { return (closing ? .end(name) : .start(name, attributes, selfClosing: false), index + 1) }
            if s[index] == "/", index + 1 < s.count, s[index + 1] == ">", !closing { return (.start(name, attributes, selfClosing: true), index + 2) }
            guard !closing else { return nil }
            let keyStart = index
            while index < s.count, !s[index].properties.isWhitespace, !"=>/\"'<".unicodeScalars.contains(s[index]) { index += 1 }
            guard index > keyStart else { return nil }
            let key = String(String.UnicodeScalarView(s[keyStart..<index])).lowercased()
            var value = ""
            var lookahead = index
            while lookahead < s.count, s[lookahead].properties.isWhitespace { lookahead += 1 }
            if lookahead < s.count, s[lookahead] == "=" {
                index = lookahead + 1
                while index < s.count, s[index].properties.isWhitespace { index += 1 }
                guard index < s.count else { return nil }
                if s[index] == "\"" || s[index] == "'" {
                    let quote = s[index]
                    var close = index + 1
                    while close < s.count, s[close] != quote { close += 1 }
                    guard close < s.count else { return nil }
                    value = String(String.UnicodeScalarView(s[(index + 1)..<close])); index = close + 1
                } else {
                    let valueStart = index
                    while index < s.count, !s[index].properties.isWhitespace, s[index] != ">" { index += 1 }
                    value = String(String.UnicodeScalarView(s[valueStart..<index]))
                }
            }
            if attributes[key] == nil { attributes[key] = decodeEntities(value) }
        }
        return nil
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "trade": "™",
                                       "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "rarr": "→", "larr": "←",
                                       "uarr": "↑", "darr": "↓", "times": "×", "deg": "°", "plusmn": "±", "check": "✓", "zwj": "\u{200D}", "emsp": "\u{2003}", "ensp": "\u{2002}"]
        var result = "", rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semicolon = after.prefix(32).firstIndex(of: ";") {
                let name = String(after[..<semicolon])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") { replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) } }
                else if name.hasPrefix("#") { replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) } }
                else { replacement = named[name] }
                if let replacement, replacement != "\0" { result += replacement; rest = after[after.index(after: semicolon)...]; continue }
            }
            result += "&"; rest = after
        }
        return result + rest
    }

    /// Converts a block of allowlisted HTML into blocks, or `nil` to keep it literal.
    static func blocks(_ raw: String) -> [MarkdownBlock]? {
        let tokens = tokenize(raw).tokens
        for token in tokens {
            switch token.kind {
            case .start(let name, _, _), .end(let name): guard isAllowed(name) else { return nil }
            case .other: return nil
            default: break
            }
        }
        var builder = InlineBuilder(), result: [MarkdownBlock] = [], heading: Int?, index = 0
        func flush() {
            let spans = builder.finish()
            guard !spans.isEmpty else { return }
            result.append(heading.map { .heading(level: $0, spans) } ?? .paragraph(spans))
        }
        while index < tokens.count {
            let token = tokens[index]
            switch token.kind {
            case .start(let name, _, _) where containers.contains(name), .end(let name) where containers.contains(name): flush()
            case .start(let name, _, _) where headings[name] != nil: flush(); heading = headings[name]
            case .end(let name) where headings[name] != nil: flush(); heading = nil
            case .start("hr", _, _): flush(); result.append(.rule)
            case .start("pre", _, _):
                flush()
                var end = index + 1
                while end < tokens.count, tokens[end].kind != .end("pre") { end += 1 }
                let code = tokens[(index + 1)..<end].compactMap { if case .text(let text) = $0.kind { decodeEntities(text) } else { nil } }.joined()
                result.append(.code(language: "", text: code.hasPrefix("\n") ? String(code.dropFirst()) : code, meta: "", closed: end < tokens.count))
                index = end
            case .start("details", _, _), .end("details"), .start("summary", _, _), .end("summary"), .comment: break
            default: builder.add(token)
            }
            index += 1
        }
        flush()
        return result
    }

    /// Collects inline tokens into styled spans, collapsing HTML whitespace.
    struct InlineBuilder {
        private var spans: [MarkdownSpan] = []
        private var styles: [(String, MarkdownSpan.Style)] = [], links: [String?] = []
        var style: MarkdownSpan.Style { styles.reduce([]) { $0.union($1.1) } }
        mutating func add(_ token: Token) {
            switch token.kind {
            case .text(let text):
                let collapsed = decodeEntities(text).replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
                append(collapsed)
            case .start("br", _, _): append("\n")
            case .start("img", let attributes, _):
                let alt = attributes["alt"].map { decodeEntities($0) } ?? ""
                spans.append(.init(text: alt.isEmpty ? "Image" : "Image: \(alt)", style: style, destination: attributes["src"] ?? (links.last ?? nil)))
            case .start("a", let attributes, false): links.append(attributes["href"])
            case .end("a"): if !links.isEmpty { links.removeLast() }
            case .start(let name, _, false):
                if let value = inlineStyles[name] { styles.append((name, value)) }
            case .end(let name):
                if let last = styles.lastIndex(where: { $0.0 == name }) { styles.remove(at: last) }
            default: break
            }
        }
        private mutating func append(_ text: String) {
            guard !text.isEmpty else { return }
            let destination = links.last ?? nil
            if let last = spans.last, last.style == style, last.destination == destination, last.source == nil { spans[spans.count - 1].text += text }
            else { spans.append(.init(text: text, style: style, destination: destination)) }
        }
        mutating func finish() -> [MarkdownSpan] {
            defer { spans = [] }
            var result = spans
            // Trim collapsed whitespace at the edges and around line breaks.
            while let first = result.first, first.text.allSatisfy({ $0 == " " }) { result.removeFirst() }
            while let last = result.last, last.text.allSatisfy({ $0 == " " }) { result.removeLast() }
            guard !result.isEmpty else { return [] }
            result[0].text = String(result[0].text.drop { $0 == " " })
            result[result.count - 1].text = String(result[result.count - 1].text.reversed().drop { $0 == " " }.reversed())
            for index in result.indices {
                result[index].text = result[index].text.replacingOccurrences(of: " \n", with: "\n").replacingOccurrences(of: "\n ", with: "\n")
            }
            return result.filter { !$0.text.isEmpty }
        }
    }

    struct DetailsOpening {
        var summary: [MarkdownSpan]
        var open: Bool
        /// Markdown after `</summary>` inside the opening block, up to a closing tag if present.
        var body: String
        /// Text after a `</details>` found in the same block, when the element closes there.
        var trailing: String?
    }

    /// An HTML block that starts with `<details>`, with its optional summary.
    static func detailsOpening(_ raw: String) -> DetailsOpening? {
        let (s, tokens) = tokenize(raw)
        guard let first = tokens.first(where: { if case .text(let text) = $0.kind { !text.allSatisfy(\.isWhitespace) } else { $0.kind != .comment } }),
              case .start("details", let attributes, false) = first.kind, let firstIndex = tokens.firstIndex(of: first) else { return nil }
        var index = firstIndex + 1, summary: [MarkdownSpan] = [], bodyStart = first.range.upperBound
        while index < tokens.count, case .text(let text) = tokens[index].kind, text.allSatisfy(\.isWhitespace) { index += 1 }
        if index < tokens.count, case .start("summary", _, false) = tokens[index].kind {
            var builder = InlineBuilder(), end = index + 1
            while end < tokens.count, tokens[end].kind != .end("summary") {
                if case .start(let name, _, _) = tokens[end].kind, !isAllowed(name) || containers.contains(name) {} else { builder.add(tokens[end]) }
                end += 1
            }
            guard end < tokens.count else { return nil }
            summary = builder.finish(); bodyStart = tokens[end].range.upperBound; index = end + 1
        }
        var depth = 1
        for token in tokens[index...] {
            if case .start("details", _, false) = token.kind { depth += 1 }
            if token.kind == .end("details") {
                depth -= 1
                if depth == 0 {
                    return .init(summary: summary, open: attributes["open"] != nil, body: string(s, bodyStart..<token.range.lowerBound), trailing: string(s, token.range.upperBound..<s.count))
                }
            }
        }
        return .init(summary: summary, open: attributes["open"] != nil, body: string(s, bodyStart..<s.count), trailing: nil)
    }

    /// Adjusts `depth` by this block's `<details>` tags and splits at the tag that closes it.
    static func detailsClose(_ raw: String, depth: inout Int) -> (before: String, after: String)? {
        let (s, tokens) = tokenize(raw)
        for token in tokens {
            if case .start("details", _, false) = token.kind { depth += 1 }
            if token.kind == .end("details") {
                depth -= 1
                if depth == 0 { return (string(s, 0..<token.range.lowerBound), string(s, token.range.upperBound..<s.count)) }
            }
        }
        return nil
    }

    private static func string(_ s: [Unicode.Scalar], _ range: Range<Int>) -> String { String(String.UnicodeScalarView(s[range])) }
}
