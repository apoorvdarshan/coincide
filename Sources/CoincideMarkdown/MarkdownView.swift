import AppKit
import SwiftUI

public struct MarkdownView: View {
    private let source: String
    private let workspace: URL?
    private let mathEnabled: Bool
    private let openFile: (URL, Int?) -> Void
    @State private var document: MarkdownDocument?
    public init(_ source: String, workspace: URL? = nil, mathEnabled: Bool = true, openFile: @escaping (URL, Int?) -> Void = { _, _ in }) {
        self.source = source; self.workspace = workspace; self.mathEnabled = mathEnabled; self.openFile = openFile
    }
    public var body: some View {
        Group {
            if let document { MarkdownBlocksView(blocks: document.blocks, workspace: workspace, openFile: openFile) }
            else { Text(source).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .font(.system(size: 15)).lineSpacing(4)
        .task(id: ParseIdentity(source: source, mathEnabled: mathEnabled)) {
            let parsed = await MarkdownParser.shared.parse(source, mathEnabled: mathEnabled)
            guard !Task.isCancelled else { return }; document = parsed
        }
    }
    private struct ParseIdentity: Equatable { let source: String; let mathEnabled: Bool }
}

struct MarkdownBlocksView: View {
    var blocks: [MarkdownBlock]
    var workspace: URL?
    var openFile: (URL, Int?) -> Void
    @State private var tableWidth: CGFloat = 0
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func children(_ blocks: [MarkdownBlock]) -> AnyView {
        AnyView(MarkdownBlocksView(blocks: blocks, workspace: workspace, openFile: openFile))
    }
    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let spans): inline(spans)
        case .heading(let level, let spans):
            inline(spans).font(.system(size: [26.0, 22, 19, 17, 16, 15][min(5, max(0, level - 1))], weight: .semibold))
                .accessibilityAddTraits(.isHeader).padding(.top, 4)
        case .code(let language, let text): MarkdownCodeView(language: language, source: text)
        case .math(let latex): NativeMathView(latex: latex)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.35)).frame(width: 3)
                children(blocks)
            }.fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
        case .alert(let kind, let blocks):
            let presentation = MarkdownAlertPresentation(kind)
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(presentation.color.opacity(0.7)).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    Label(presentation.title, systemImage: presentation.symbol)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(presentation.color)
                        .accessibilityAddTraits(.isHeader)
                    children(blocks)
                }
            }.fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .contain)
        case .details(let summary, let initiallyOpen, let blocks):
            NativeMarkdownDetails(initiallyOpen: initiallyOpen, summary: inline(summary), emptySummary: summary.isEmpty,
                content: children(blocks))
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
        case .table(let headers, let rows, let alignments):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { index in
                            inline(headers[index], alignment: alignment(alignments, index)).fontWeight(.semibold).padding(10).frame(minWidth: 90, maxWidth: .infinity, alignment: alignment(alignments, index))
                                .background(Color.primary.opacity(0.06))
                        }
                    }
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(headers.indices, id: \.self) { column in
                                inline(column < rows[row].count ? rows[row][column] : [], alignment: alignment(alignments, column)).padding(10)
                                    .frame(minWidth: 90, maxWidth: .infinity, alignment: alignment(alignments, column))
                                    .background(Color.primary.opacity(row.isMultiple(of: 2) ? 0.02 : 0.045))
                            }
                        }
                    }
                }.frame(minWidth: tableWidth)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)) }.clipShape(RoundedRectangle(cornerRadius: 8))
        case .rule: Divider().padding(.vertical, 3)
        case .literal(let source): Text(source).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
    private func alignment(_ values: [MarkdownBlock.ColumnAlignment], _ index: Int) -> Alignment {
        guard index < values.count else { return .leading }
        return switch values[index] { case .left: .leading; case .center: .center; case .right: .trailing }
    }
    private func inline(_ spans: [MarkdownSpan], alignment: Alignment = .leading) -> some View {
        inlineText(spans).textSelection(.enabled).frame(maxWidth: .infinity, alignment: alignment)
            .contextMenu {
                let formulas = spans.compactMap(\.formula)
                ForEach(Array(formulas.enumerated()), id: \.offset) { index, formula in
                    Button(formulas.count == 1 ? "Copy Formula" : "Copy Formula \(index + 1)") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(formula.copySource, forType: .string)
                    }
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                guard let target = MarkdownLinkTarget.resolve(url.absoluteString, workspace: workspace) else { return .discarded }
                switch target {
                case .external(let url): return .systemAction(url)
                case .file(let url, let line): openFile(url, line); return .handled
                }
            })
    }
    private func inlineText(_ spans: [MarkdownSpan]) -> Text {
        spans.reduce(Text("")) { result, span in
            if let formula = span.formula, span.destination == nil,
               let rendered = NativeMath.render(formula.latex, dark: scheme == .dark, display: formula.display) {
                return result + Text(Image(nsImage: rendered.image)).baselineOffset(-rendered.descent)
                    .accessibilityLabel("Inline equation: \(formula.latex)")
            }
            return result + Text(attributed([span]))
        }
    }
    private func attributed(_ spans: [MarkdownSpan]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var part = AttributedString(span.text)
            var intent: InlinePresentationIntent = []
            if span.style.contains(.strong) { intent.insert(.stronglyEmphasized) }
            if span.style.contains(.emphasis) { intent.insert(.emphasized) }
            if span.style.contains(.strike) { intent.insert(.strikethrough) }
            if span.style.contains(.code) {
                part.font = .system(size: 13, design: .monospaced); part.backgroundColor = Color.primary.opacity(0.06)
            }
            part.inlinePresentationIntent = intent
            if let destination = span.destination, let target = MarkdownLinkTarget.resolve(destination, workspace: workspace) {
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

private struct NativeMarkdownDetails<Summary: View>: View {
    let summary: Summary
    let emptySummary: Bool
    let content: AnyView
    @State private var expanded: Bool
    init(initiallyOpen: Bool, summary: Summary, emptySummary: Bool, content: AnyView) {
        self.summary = summary; self.emptySummary = emptySummary; self.content = content
        _expanded = State(initialValue: initiallyOpen)
    }
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            DisclosureGroup(isExpanded: $expanded) { content.padding(.top, 8).padding(.bottom, 6) } label: {
                if emptySummary { Text("Details").fontWeight(.medium) }
                else { summary.fontWeight(.medium) }
            }.padding(.vertical, 8).accessibilityIdentifier("markdown-details")
            Divider()
        }
    }
}

/// System colors adapt to the native appearance; labels and symbols preserve
/// each alert's meaning without relying on color or announcing a live warning.
@MainActor private struct MarkdownAlertPresentation {
    let title: String
    let symbol: String
    let color: Color
    init(_ kind: MarkdownAlertKind) {
        switch kind {
        case .note: title = String(localized: "Note"); symbol = "info.circle"; color = Color(nsColor: .systemBlue)
        case .tip: title = String(localized: "Tip"); symbol = "lightbulb"; color = Color(nsColor: .systemGreen)
        case .important: title = String(localized: "Important"); symbol = "exclamationmark.bubble"; color = Color(nsColor: .systemPurple)
        case .warning: title = String(localized: "Warning"); symbol = "exclamationmark.triangle"; color = Color(nsColor: .systemOrange)
        case .caution: title = String(localized: "Caution"); symbol = "exclamationmark.octagon"; color = Color(nsColor: .systemRed)
        }
    }
}

private struct MarkdownCodeView: View {
    let language: String
    let source: String
    @State private var copied = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source, forType: .string); copied = true
                } label: { Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption) }
                .buttonStyle(.plain).accessibilityLabel("Copy code")
            }.padding(.horizontal, 12).padding(.vertical, 9).background(Color.primary.opacity(0.04))
            Divider()
            ScrollView(.horizontal) {
                Text(AttributedString(CodeHighlight.attributed(source, language: language))).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: source) { copied = false }
    }
}
