import AppKit
import SwiftUI

/// Highlighted code per appearance. Small blocks highlight on the main actor; larger ones
/// highlight in the background (debounced while their fence is still open) and only
/// finished fences are stored, so streaming prefixes do not evict useful entries.
@MainActor enum CodeHighlightCache {
    struct Key: Hashable, Sendable { var source: String; var language: String; var dark: Bool; var increasedContrast: Bool }
    static let synchronousLimit = 8_192
    private final class Entry { let text: AttributedString; init(_ text: AttributedString) { self.text = text } }
    private static let cache: NSCache<NSString, Entry> = {
        let value = NSCache<NSString, Entry>(); value.countLimit = 256; value.totalCostLimit = 8_388_608; return value
    }()
    private static func name(_ key: Key) -> NSString { "\(key.dark)|\(key.increasedContrast)|\(key.language)|\(key.source)" as NSString }
    static func cached(_ key: Key) -> AttributedString? { cache.object(forKey: name(key))?.text }
    static func store(_ key: Key, _ text: AttributedString) { cache.setObject(Entry(text), forKey: name(key), cost: key.source.utf16.count * 2) }
    static func highlight(_ key: Key) -> AttributedString {
        CodeHighlight.attributedString(key.source, language: key.language, dark: key.dark, increasedContrast: key.increasedContrast)
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
}

private struct BlockChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)) }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A fenced code block with its title, language badge, wrap toggle, optional Run and Copy.
struct MarkdownCodeView: View {
    let language: String
    let meta: String
    let source: String
    let closed: Bool
    let context: MarkdownRenderContext
    @AppStorage(MarkdownPreferences.wordWrapKey) private var wordWrap = true
    @State private var wrapOverride: Bool?
    @State private var copied = false
    @State private var background: (key: CodeHighlightCache.Key, text: AttributedString)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var wrapped: Bool { wrapOverride ?? wordWrap }

    /// Cached or small blocks color immediately. A large block shows its last background
    /// result plus the new plain tail until the next result arrives.
    private func highlighted(_ key: CodeHighlightCache.Key) -> AttributedString {
        if let cached = CodeHighlightCache.cached(key) { return cached }
        if key.source.utf16.count <= CodeHighlightCache.synchronousLimit {
            let text = CodeHighlightCache.highlight(key)
            if closed { CodeHighlightCache.store(key, text) }
            return text
        }
        if let background, background.key.language == key.language, background.key.dark == key.dark, background.key.increasedContrast == key.increasedContrast,
           key.source.hasPrefix(background.key.source) {
            return background.text + AttributedString(String(key.source.dropFirst(background.key.source.count)))
        }
        return AttributedString(key.source)
    }

    var body: some View {
        let title = CodeFence.title(meta)
        let languageLabel = CodeHighlight.label(for: language) ?? (language.isEmpty ? nil : language)
        let command = context.runShell == nil ? nil : CodeFence.runnableCommand(language: language, code: source, closed: closed, streaming: context.isStreaming)
        // The fence's final newline is not a visible line; copying keeps the exact source.
        let shown = source.hasSuffix("\n") ? String(source.dropLast()) : source
        let key = CodeHighlightCache.Key(source: shown, language: language, dark: scheme == .dark, increasedContrast: contrast == .increased)
        let highlighted = highlighted(key)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let title {
                    Label(title, systemImage: "doc.text").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(.primary.opacity(0.8))
                    if let languageLabel {
                        Text(languageLabel).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.primary.opacity(0.07), in: Capsule())
                    }
                } else { Text(languageLabel ?? "Code").font(.caption) }
                Spacer(minLength: 8)
                HStack(spacing: 12) {
                    Button { wrapOverride = !wrapped } label: { Image(systemName: "arrow.turn.down.left").foregroundStyle(wrapped ? Color.accentColor : .secondary) }
                        .help(wrapped ? "Disable line wrap" : "Wrap lines").accessibilityLabel(wrapped ? "Disable line wrap" : "Wrap lines")
                        .accessibilityAddTraits(wrapped ? .isSelected : []).accessibilityIdentifier("markdown.code.wrap")
                    if let command, let runShell = context.runShell {
                        Button { runShell(command) } label: { Image(systemName: "play") }
                            .help("Run in terminal").accessibilityLabel("Run in terminal").accessibilityIdentifier("markdown.code.run")
                    }
                    Button { copyToPasteboard(source); copied = true } label: {
                        Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                    }.accessibilityLabel("Copy code").accessibilityIdentifier("markdown.code.copy")
                }.buttonStyle(.plain).accessibilityElement(children: .contain).accessibilityLabel("Code block actions")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 9).background(Color.primary.opacity(0.04))
            Divider()
            if wrapped {
                Text(highlighted).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    Text(highlighted).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .modifier(BlockChrome())
        .onChange(of: source) { copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2)); copied = false
        }
        .task(id: key) {
            guard key.source.utf16.count > CodeHighlightCache.synchronousLimit, CodeHighlightCache.cached(key) == nil else { return }
            if !closed {
                // A streaming fence changes with every token; highlight once it pauses.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            let text = await Task.detached(priority: .userInitiated) {
                CodeHighlight.attributedString(key.source, language: key.language, dark: key.dark, increasedContrast: key.increasedContrast)
            }.value
            guard !Task.isCancelled else { return }
            if closed { CodeHighlightCache.store(key, text) }
            background = (key, text)
        }
    }
}

/// Mermaid fences: a native drawing for the supported subset once the fence closes,
/// with a source toggle; anything else stays readable source.
struct MermaidBlockView: View {
    let source: String
    let meta: String
    let closed: Bool
    let context: MarkdownRenderContext
    @State private var showCode = false
    @State private var copied = false
    var body: some View {
        let layout = closed && !context.isStreaming ? MermaidLayoutCache.layout(source) : nil
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(CodeFence.title(meta) ?? "Mermaid diagram", systemImage: "point.3.connected.trianglepath.dotted").font(.caption)
                Spacer(minLength: 8)
                HStack(spacing: 12) {
                    if layout != nil {
                        Button { showCode.toggle() } label: { Image(systemName: showCode ? "point.3.connected.trianglepath.dotted" : "chevron.left.forwardslash.chevron.right") }
                            .help(showCode ? "Show diagram" : "Show code").accessibilityLabel(showCode ? "Show diagram" : "Show code")
                    }
                    Button { copyToPasteboard(source); copied = true } label: {
                        Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                    }.accessibilityLabel("Copy diagram source")
                }.buttonStyle(.plain)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 9).background(Color.primary.opacity(0.04))
            Divider()
            if let layout, !showCode {
                ScrollView(.horizontal) { MermaidCanvas(layout: layout).padding(12) }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    Text(source).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                if closed, !context.isStreaming, layout == nil {
                    Text("Shown as source. Coincide draws flowcharts and sequence diagrams natively; this diagram uses syntax outside that subset.")
                        .font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom], 12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .modifier(BlockChrome())
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2)); copied = false
        }
    }
}

/// Caps a table cell at T3's 24rem so long cells wrap (or truncate when collapsed).
struct MarkdownCellWidth: Layout {
    var maximum: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(child.sizeThatFits(.unspecified).width, maximum, proposal.width ?? .infinity)
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let width = min(child.sizeThatFits(.unspecified).width, maximum, bounds.width)
        child.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}

struct MarkdownTableView: View {
    let headers: [[MarkdownSpan]]
    let rows: [[[MarkdownSpan]]]
    let alignments: [MarkdownBlock.ColumnAlignment]
    let context: MarkdownRenderContext
    @AppStorage(MarkdownPreferences.wordWrapKey) private var wordWrap = true
    @State private var expandOverride: Bool?
    @State private var copied = false
    @State private var tableWidth: CGFloat = 0
    private var expanded: Bool { expandOverride ?? wordWrap }
    /// Only tables with long cells offer the toggle, like T3's clipped-cell check.
    private var hasLongCells: Bool { (headers + rows.flatMap { $0 }).contains { MarkdownTableExport.plainText($0).count > 48 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                // Row separators instead of per-cell fills, so rows of mixed height stay even.
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { index in cell(headers[index], column: index).fontWeight(.semibold) }
                    }
                    Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    ForEach(rows.indices, id: \.self) { row in
                        if row > 0 { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                        GridRow {
                            ForEach(headers.indices, id: \.self) { column in cell(column < rows[row].count ? rows[row][column] : [], column: column) }
                        }
                    }
                }.frame(minWidth: tableWidth)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
            .background(Color.primary.opacity(0.025))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)) }.clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 12) {
                if hasLongCells {
                    Button { expandOverride = !expanded } label: { Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                        .help(expanded ? "Collapse table cells" : "Expand table cells").accessibilityLabel(expanded ? "Collapse table cells" : "Expand table cells")
                        .accessibilityIdentifier("markdown.table.wrap")
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Copy as Markdown") { copyToPasteboard(MarkdownTableExport.markdown(headers: headers, rows: rows, alignments: alignments)); copied = true }
                    Button("Copy as CSV") { copyToPasteboard(MarkdownTableExport.csv(headers: headers, rows: rows)); copied = true }
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(copied ? "Copied" : "Copy table").accessibilityLabel(copied ? "Copied" : "Copy table").accessibilityIdentifier("markdown.table.copy")
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2)); copied = false
        }
    }

    /// Only the last column stretches, so a narrow table fills the lane without the grid
    /// shrinking measured columns.
    private func cell(_ spans: [MarkdownSpan], column index: Int) -> some View {
        let value = index < alignments.count ? alignments[index] : .left
        let frame: Alignment = switch value { case .left: .topLeading; case .center: .top; case .right: .topTrailing }
        let text: TextAlignment = switch value { case .left: .leading; case .center: .center; case .right: .trailing }
        let column: HorizontalAlignment = switch value { case .left: .leading; case .center: .center; case .right: .trailing }
        // Wide lanes fit an expanded table without sideways scrolling, as T3 does from 36rem.
        let cap = tableWidth > 0 ? min(384, max(160, tableWidth - 110 * CGFloat(max(0, headers.count - 1)) - 20)) : 384
        return MarkdownCellWidth(maximum: cap) {
            MarkdownInlineText(spans: spans, context: context, alignment: text).lineLimit(expanded ? nil : 1).truncationMode(.tail)
        }.padding(10).frame(minWidth: 90, maxWidth: index == headers.count - 1 ? .infinity : nil, alignment: frame).gridColumnAlignment(column)
    }
}

struct MarkdownAlertView: View {
    let kind: MarkdownAlertKind
    let content: AnyView
    @Environment(\.colorSchemeContrast) private var contrast
    private var color: Color {
        switch kind { case .note: .blue; case .tip: .green; case .important: .purple; case .warning: .orange; case .caution: .red }
    }
    private var symbol: String {
        switch kind {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.bubble"
        case .warning: "exclamationmark.triangle"
        case .caution: "exclamationmark.octagon"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(contrast == .increased ? 1 : 0.75)).frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                Label(kind.title, systemImage: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                    .accessibilityLabel("\(kind.title):").accessibilityAddTraits(.isHeader)
                content
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(contrast == .increased ? 10 : 0)
        .overlay { if contrast == .increased { RoundedRectangle(cornerRadius: 6).strokeBorder(color, lineWidth: 1) } }
        .accessibilityElement(children: .contain).accessibilityIdentifier("markdown.alert.\(kind.rawValue)")
    }
}

/// `<details>`: a native disclosure, initially open only with the `open` attribute.
struct MarkdownDetailsView: View {
    let summary: [MarkdownSpan]
    let blocks: [MarkdownBlock]
    let context: MarkdownRenderContext
    @State private var expanded: Bool
    init(summary: [MarkdownSpan], open: Bool, blocks: [MarkdownBlock], context: MarkdownRenderContext) {
        self.summary = summary; self.blocks = blocks; self.context = context; _expanded = State(initialValue: open)
    }
    var body: some View {
        let title = summary.isEmpty ? "Details" : summary.map(\.text).joined()
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).fontWeight(.medium).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hides the details" : "Shows the details").accessibilityIdentifier("markdown.details.toggle")
            if expanded { MarkdownBlocksView(blocks: blocks, context: context).padding(.top, 10) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)) }
    }
}

struct MarkdownFootnotesView: View {
    let notes: [MarkdownFootnote]
    let context: MarkdownRenderContext
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            ForEach(notes, id: \.number) { note in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(note.number).").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 20, alignment: .trailing)
                    MarkdownBlocksView(blocks: note.blocks, context: context)
                }.accessibilityElement(children: .contain).accessibilityLabel("Footnote \(note.number)")
            }
        }
        .font(.system(size: 13)).lineSpacing(3)
        .accessibilityElement(children: .contain).accessibilityLabel("Footnotes").accessibilityIdentifier("markdown.footnotes")
    }
}

/// Codex `::artifact-template` card. Using a template needs composer wiring, so the card
/// only identifies it.
struct CodexArtifactTemplateCard: View {
    let template: CodexArtifactTemplate
    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: template.artifactKind.symbol).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)) }
                Image(systemName: "sparkles").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 15, height: 15).background(Color.accentColor, in: Circle()).offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(template.displayName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(template.artifactKind.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)) }
        .accessibilityElement(children: .combine).accessibilityLabel("\(template.displayName) template, \(template.artifactKind.label)")
        .accessibilityIdentifier("markdown.artifactTemplate")
    }
}
