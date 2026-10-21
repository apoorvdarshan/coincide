import AppKit
import SwiftUI

public struct MarkdownView: View {
    private let source: String
    private let workspace: URL?
    private let openFile: (URL, Int?) -> Void
    @State private var document: MarkdownDocument?
    public init(_ source: String, workspace: URL? = nil, openFile: @escaping (URL, Int?) -> Void = { _, _ in }) {
        self.source = source; self.workspace = workspace; self.openFile = openFile
    }
    public var body: some View {
        Group {
            if let document { MarkdownBlocksView(blocks: document.blocks, workspace: workspace, openFile: openFile) }
            else { Text(source).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .font(.system(size: 15)).lineSpacing(4)
        .task(id: source) {
            let parsed = await MarkdownParser.shared.parse(source)
            guard !Task.isCancelled else { return }; document = parsed
        }
    }
}

struct MarkdownBlocksView: View {
    var blocks: [MarkdownBlock]
    var workspace: URL?
    var openFile: (URL, Int?) -> Void
    @State private var tableWidth: CGFloat = 0
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
        Text(attributed(spans)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: alignment)
            .environment(\.openURL, OpenURLAction { url in
                guard let target = MarkdownLinkTarget.resolve(url.absoluteString, workspace: workspace) else { return .discarded }
                switch target {
                case .external(let url): return .systemAction(url)
                case .file(let url, let line): openFile(url, line); return .handled
                }
            })
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
