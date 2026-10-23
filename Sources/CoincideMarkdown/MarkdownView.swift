import AppKit
import SwiftUI

/// What block views need from the hosting message.
struct MarkdownRenderContext {
    var workspace: URL?
    var openFile: (URL, Int?) -> Void
    var runShell: ((String) -> Void)?
    var isStreaming = false
    var footnotes: [MarkdownFootnote] = []
}

public struct MarkdownView: View {
    private struct ParseKey: Hashable { var source: String; var options: MarkdownParseOptions }
    private let source: String
    private let workspace: URL?
    private let options: MarkdownParseOptions
    private let isStreaming: Bool
    private let runShell: ((String) -> Void)?
    private let openFile: (URL, Int?) -> Void
    @State private var document: MarkdownDocument?
    /// - Parameters:
    ///   - rawHTML: Renders the safe HTML subset (`<details>`, `<kbd>`, …). Pass `false` for
    ///     user-authored text so all HTML stays literal.
    ///   - isStreaming: Hides actions that should wait for a finished message.
    ///   - runShell: Shows "Run in terminal" on closed single-line shell fences and receives the
    ///     exact trimmed command when clicked. It is never called while rendering.
    public init(_ source: String, workspace: URL? = nil, rawHTML: Bool = true, isStreaming: Bool = false,
                runShell: ((String) -> Void)? = nil, openFile: @escaping (URL, Int?) -> Void = { _, _ in }) {
        self.source = source; self.workspace = workspace; self.options = MarkdownParseOptions(rawHTML: rawHTML)
        self.isStreaming = isStreaming; self.runShell = runShell; self.openFile = openFile
    }
    public var body: some View {
        Group {
            if let document {
                MarkdownBlocksView(blocks: document.blocks, context: .init(workspace: workspace, openFile: openFile, runShell: runShell,
                                                                           isStreaming: isStreaming, footnotes: document.footnotes))
            } else { Text(source).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .font(.system(size: 15)).lineSpacing(4)
        .task(id: ParseKey(source: source, options: options)) {
            let parsed = await MarkdownParser.shared.parse(source, options: options)
            guard !Task.isCancelled else { return }; document = parsed
        }
    }
}

struct MarkdownBlocksView: View {
    var blocks: [MarkdownBlock]
    var context: MarkdownRenderContext
    @AppStorage(MarkdownPreferences.renderMathKey) private var renderMath = true
    init(blocks: [MarkdownBlock], context: MarkdownRenderContext) { self.blocks = blocks; self.context = context }
    init(blocks: [MarkdownBlock], workspace: URL?, openFile: @escaping (URL, Int?) -> Void) {
        var notes: [MarkdownFootnote] = []
        if case .footnotes(let found)? = blocks.last { notes = found }
        self.init(blocks: blocks, context: .init(workspace: workspace, openFile: openFile, footnotes: notes))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func children(_ blocks: [MarkdownBlock]) -> AnyView {
        AnyView(MarkdownBlocksView(blocks: blocks, context: context))
    }
    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let spans): MarkdownInlineText(spans: spans, context: context).frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let spans):
            MarkdownInlineText(spans: spans, context: context).font(.system(size: [26.0, 22, 19, 17, 16, 15][min(5, max(0, level - 1))], weight: .semibold))
                .accessibilityAddTraits(.isHeader).padding(.top, 4).frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let text, let meta, let closed):
            if language.lowercased() == "mermaid" { MermaidBlockView(source: text, meta: meta, closed: closed, context: context) }
            else { MarkdownCodeView(language: language, meta: meta, source: text, closed: closed, context: context) }
        case .math(let latex):
            if renderMath { NativeMathView(latex: latex) } else { MarkdownCodeView(language: "math", meta: "", source: latex, closed: true, context: context) }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.35)).frame(width: 3)
                children(blocks)
            }.fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
        case .alert(let kind, let blocks): MarkdownAlertView(kind: kind, content: children(blocks))
        case .details(let summary, let open, let blocks): MarkdownDetailsView(summary: summary, open: open, blocks: blocks, context: context)
        case .list(let start, let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            if let checked = item.checked { Image(systemName: checked ? "checkmark.square.fill" : "square").accessibilityLabel(checked ? "Completed" : "Not completed") }
                            else { Text(start.map { "\($0 + UInt(index))." } ?? "•").monospacedDigit() }
                        }.foregroundStyle(.secondary).frame(minWidth: 20, alignment: .trailing)
                        children(item.blocks)
                    }
                }
            }
        case .table(let headers, let rows, let alignments): MarkdownTableView(headers: headers, rows: rows, alignments: alignments, context: context)
        case .footnotes(let notes): MarkdownFootnotesView(notes: notes, context: context)
        case .artifactTemplate(let template): CodexArtifactTemplateCard(template: template)
        case .rule: Divider().padding(.vertical, 3)
        case .literal(let source): Text(source).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}

/// One run of inline text. Formulas typeset as baseline-aligned images inside the same
/// `Text`, so selection, wrapping and links keep working around them.
struct MarkdownInlineText: View {
    static let footnoteScheme = "coincide-footnote"
    private struct Footnote: Identifiable { let id: Int }
    let spans: [MarkdownSpan]
    let context: MarkdownRenderContext
    var alignment: TextAlignment = .leading
    @AppStorage(MarkdownPreferences.renderMathKey) private var renderMath = true
    @Environment(\.colorScheme) private var scheme
    @State private var footnote: Footnote?

    var body: some View {
        text.textSelection(.enabled).multilineTextAlignment(alignment)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == Self.footnoteScheme {
                    if let number = Int(url.absoluteString.dropFirst(Self.footnoteScheme.count + 1)) { footnote = Footnote(id: number) }
                    return .handled
                }
                guard let target = MarkdownLinkTarget.resolve(url.absoluteString, workspace: context.workspace) else { return .discarded }
                switch target {
                case .external(let url): return .systemAction(url)
                case .file(let url, let line): context.openFile(url, line); return .handled
                }
            })
            .popover(item: $footnote, arrowEdge: .bottom) { selection in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Footnote \(selection.id)").font(.caption).foregroundStyle(.secondary)
                    if let note = context.footnotes.first(where: { $0.number == selection.id }) {
                        MarkdownBlocksView(blocks: note.blocks, context: context).font(.system(size: 13)).lineSpacing(3)
                    }
                }.padding(14).frame(width: 340, alignment: .leading)
            }
    }

    private var text: Text {
        guard renderMath, spans.contains(where: { !$0.style.isDisjoint(with: .math) }) else { return Text(attributed(spans)) }
        var result = Text(verbatim: ""), pending: [MarkdownSpan] = []
        func flush() {
            guard !pending.isEmpty else { return }
            result = Text("\(result)\(Text(attributed(pending)))"); pending = []
        }
        for span in spans {
            let display = span.style.contains(.displayMath)
            guard !span.style.isDisjoint(with: .math),
                  let rendered = NativeMath.rendered(span.text, dark: scheme == .dark, display: display, fontSize: display ? 17 : 15),
                  let image = rendered.cgImage else { pending.append(span); continue }
            flush()
            let scale = CGFloat(image.width) / max(1, rendered.image.size.width)
            let formula = Text(Image(image, scale: scale, label: Text(verbatim: "Formula: \(span.text)"))).baselineOffset(-rendered.descent)
            result = Text("\(result)\(formula)")
        }
        flush()
        return result
    }

    private func attributed(_ spans: [MarkdownSpan]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            let math = !span.style.isDisjoint(with: .math)
            var part = AttributedString(math ? (span.source ?? span.text) : span.text)
            var intent: InlinePresentationIntent = []
            if span.style.contains(.strong) { intent.insert(.stronglyEmphasized) }
            if span.style.contains(.emphasis) { intent.insert(.emphasized) }
            if span.style.contains(.strike) { intent.insert(.strikethrough) }
            if span.style.contains(.code) || (math && renderMath) {
                part.font = .system(size: 13, design: .monospaced); part.backgroundColor = Color.primary.opacity(0.06)
            }
            if span.style.contains(.keyboard) {
                part.font = .system(size: 12, weight: .medium, design: .monospaced); part.backgroundColor = Color.primary.opacity(0.1)
            }
            if span.style.contains(.superscript) || span.style.contains(.footnoteReference) { part.font = .system(size: 11); part.baselineOffset = 6 }
            if span.style.contains(.subscript) { part.font = .system(size: 11); part.baselineOffset = -3 }
            part.inlinePresentationIntent = intent
            if span.style.contains(.footnoteReference), let number = Int(span.text) {
                part.link = URL(string: "\(Self.footnoteScheme):\(number)"); part.foregroundColor = .accentColor
            } else if let destination = span.destination, let target = MarkdownLinkTarget.resolve(destination, workspace: context.workspace) {
                switch target {
                case .external(let url): part.link = url
                case .file(let url, let line):
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    if let line { components?.fragment = "L\(line)" }; part.link = components?.url
                }
            }
            result += part
        }
        return result
    }
}
