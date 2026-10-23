import Foundation

/// Table export matching T3's clipboard serializers. Formulas and footnote references
/// keep their authored source, and code keeps its backticks.
public enum MarkdownTableExport {
    public static func markdown(headers: [[MarkdownSpan]], rows: [[[MarkdownSpan]]], alignments: [MarkdownBlock.ColumnAlignment]) -> String {
        let columns = headers.count
        func row(_ cells: [[MarkdownSpan]]) -> String {
            "| " + (0..<columns).map { index in
                (index < cells.count ? inlineMarkdown(cells[index]) : "")
                    .replacingOccurrences(of: #"\n+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|")
            }.joined(separator: " | ") + " |"
        }
        let separator = "| " + (0..<columns).map { index -> String in
            switch index < alignments.count ? alignments[index] : .left { case .center: ":---:"; case .right: "---:"; case .left: "---" }
        }.joined(separator: " | ") + " |"
        return ([row(headers), separator] + rows.map(row)).joined(separator: "\n")
    }

    /// RFC 4180 quoting with whitespace collapsed inside each cell.
    public static func csv(headers: [[MarkdownSpan]], rows: [[[MarkdownSpan]]]) -> String {
        let columns = headers.count
        return ([headers] + rows).map { cells in
            (0..<columns).map { index -> String in
                let value = (index < cells.count ? plainText(cells[index]) : "")
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                return value.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    public static func plainText(_ spans: [MarkdownSpan]) -> String {
        spans.map { span in
            if let formula = span.formula { return formula.source.replacingOccurrences(of: "\\|", with: "|") }
            if span.style.contains(.footnoteReference) || !span.style.isDisjoint(with: .math) { return span.source ?? span.text }
            return span.text
        }.joined()
    }

    /// Inline Markdown for spans, wrapping runs that share a style once.
    public static func inlineMarkdown(_ spans: [MarkdownSpan]) -> String {
        spans.map { span -> String in
            if let formula = span.formula { return formula.source.replacingOccurrences(of: "\\|", with: "|") }
            if let source = span.source, span.style.contains(.footnoteReference) || !span.style.isDisjoint(with: .math) { return source }
            var text = span.text
            if span.style.contains(.code) || span.style.contains(.keyboard) {
                let longest = text.components(separatedBy: CharacterSet(charactersIn: "`").inverted).map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: max(1, longest + (longest > 0 ? 1 : 0)))
                let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
                text = fence + pad + text + pad + fence
            } else {
                text = text.replacingOccurrences(of: #"([\\`*_\[\]])"#, with: #"\\$1"#, options: .regularExpression)
            }
            let core = text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return text }
            let leading = String(text.prefix { $0 == " " }), trailing = String(text.reversed().prefix { $0 == " " })
            var wrapped = core
            if span.style.contains(.strike) { wrapped = "~~\(wrapped)~~" }
            if span.style.contains(.emphasis) { wrapped = "*\(wrapped)*" }
            if span.style.contains(.strong) { wrapped = "**\(wrapped)**" }
            if span.style.contains(.superscript) { wrapped = "<sup>\(wrapped)</sup>" }
            if span.style.contains(.subscript) { wrapped = "<sub>\(wrapped)</sub>" }
            if let destination = span.destination { wrapped = "[\(wrapped)](<\(destination.replacingOccurrences(of: ">", with: "%3E"))>)" }
            return leading + wrapped + trailing
        }.joined()
    }
}
