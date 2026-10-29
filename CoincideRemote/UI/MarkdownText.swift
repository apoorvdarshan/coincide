import SwiftUI

/// Agents' replies, rendered from markdown: headings, paragraphs, lists, quotes, rules, tables and fenced code blocks,
/// with inline emphasis, code and links.
struct MarkdownText: View {
    let text: String
    var font: Font = .body
    @Environment(\.theme) private var theme

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Self.inline(text)).font(font).foregroundStyle(theme.ink)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).font(font.monospacedDigit()).foregroundStyle(theme.secondaryInk)
                        Text(Self.inline(item.text)).font(font).foregroundStyle(theme.ink)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(theme.border).frame(width: 3)
                Text(Self.inline(text)).font(font).foregroundStyle(theme.secondaryInk)
            }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .rule:
            Divider()
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .body.monospaced()
            result[run.range].backgroundColor = Color.primary.opacity(0.07)
        }
        return result
    }
}

struct CodeBlock: View {
    let language: String?
    let code: String
    @Environment(\.theme) private var theme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "code")
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.secondaryInk)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? Text("Copied") : Text("Copy code"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.callout.monospaced())
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(theme.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A markdown block. Inline syntax inside each is left to `AttributedString`.
enum MarkdownBlock: Equatable {
    struct ListItem: Equatable {
        var marker: String
        var text: String
        var depth: Int
    }

    case heading(Int, String)
    case paragraph(String)
    case list([ListItem])
    case quote(String)
    case code(String?, String)
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var quote: [String] = []
        var code: [String]?
        var language: String?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !list.isEmpty { blocks.append(.list(list)) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            paragraph = []
            list = []
            quote = []
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    blocks.append(.code(language, lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = []
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if let heading = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(heading, String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !list.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                list.append(item)
                continue
            }
            if !list.isEmpty, line.hasPrefix("  ") {
                // A continuation of the last list item.
                list[list.count - 1].text += " " + trimmed
                continue
            }
            if !list.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(line)
        }
        if let lines = code { blocks.append(.code(language, lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        let depth = min(indent / 2, 4)
        for bullet in ["- [ ] ", "- [x] ", "* [ ] ", "* [x] "] where rest.hasPrefix(bullet) {
            return ListItem(marker: bullet.contains("x") ? "☑︎" : "☐", text: String(rest.dropFirst(bullet.count)), depth: depth)
        }
        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            return ListItem(marker: "•", text: String(rest.dropFirst(2)), depth: depth)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return ListItem(marker: "\(digits).", text: String(after.dropFirst(2)), depth: depth)
            }
        }
        return nil
    }
}
