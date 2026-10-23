import AppKit
import CoincideCore
import CoincideMarkdown
import SwiftUI

enum TranscriptToolSymbol {
    static func name(_ kind: TranscriptToolKind) -> String {
        switch kind {
        case .command: "terminal"
        case .read: "eye"
        case .edit: "square.and.pencil"
        case .search: "magnifyingglass"
        case .webSearch, .fetch: "globe"
        case .task: "person.2"
        case .todo: "checklist"
        case .plan: "list.bullet.clipboard"
        case .mcp: "puzzlepiece.extension"
        case .compaction: "arrow.down.right.and.arrow.up.left"
        case .other: "hammer"
        }
    }
}

/// Status glyph shared by cards and work groups: a spinner while running and a
/// failure badge only when the transcript proves a failure.
struct TranscriptToolStatusView: View {
    let status: TranscriptToolStatus
    var exitCode: Int? = nil
    var body: some View {
        if status == .running { ProgressView().controlSize(.mini).accessibilityLabel("Running") }
        else if let exitCode, exitCode != 0 {
            Text("Exit \(exitCode)").font(.caption2.monospacedDigit()).foregroundStyle(.red)
                .padding(.horizontal, 5).padding(.vertical, 1).background(Color.red.opacity(0.12), in: Capsule())
        } else if status == .failed {
            Label("Failed", systemImage: "exclamationmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.red).help("This tool call failed")
        } else if status == .declined {
            Label("Declined", systemImage: "hand.raised").labelStyle(.iconOnly).foregroundStyle(.secondary).help("This tool call was declined")
        } else if status == .cancelled {
            Label("Stopped", systemImage: "stop.circle").labelStyle(.iconOnly).foregroundStyle(.secondary).help("This tool call was stopped")
        }
    }
}

struct TranscriptDiffStatLabel: View {
    let additions: Int
    let deletions: Int
    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("−\(deletions)").foregroundStyle(.red)
        }.font(.caption.monospacedDigit())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "\(additions) lines added, \(deletions) lines removed"))
    }
}

/// One tool call: a compact row that expands into per-tool detail. Unknown tools
/// keep the generic input/output/details disclosure.
struct ToolCardView: View {
    let card: TranscriptToolCard
    var entity: ProviderEntity? = nil
    var workspacePath: String? = nil
    var caption: String? = nil
    @Binding var expanded: Bool
    var openFile: (URL, Int?) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: { header }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityTitle)
                .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
                .accessibilityHint(String(localized: "Shows tool details"))
            if expanded {
                ToolCardDetail(card: card, entity: entity, workspacePath: workspacePath, openFile: openFile)
                    .padding(.leading, 22).transition(.opacity)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: TranscriptToolSymbol.name(card.kind))
                .frame(width: 15).foregroundStyle(card.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(card.kind == .command ? .system(.callout, design: .monospaced) : .callout)
                    .lineLimit(1).truncationMode(.tail)
                if let caption { Text(caption).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
            if card.changes.contains(where: { !$0.countsComplete }) { Text("Partial changes").font(.caption2).foregroundStyle(.secondary) }
            else if let stat = card.stat, stat.additions + stat.deletions > 0 { TranscriptDiffStatLabel(additions: stat.additions, deletions: stat.deletions) }
            TranscriptToolStatusView(status: card.status, exitCode: card.exitCode)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary).contentShape(Rectangle())
    }

    private var accessibilityTitle: String {
        var parts = [card.kind == .command ? String(localized: "Command \(card.title)") : card.title]
        if card.changes.contains(where: { !$0.countsComplete }) { parts.append(String(localized: "partial changes")) }
        else if let stat = card.stat { parts.append(String(localized: "\(stat.additions) added, \(stat.deletions) removed")) }
        switch card.status {
        case .running: parts.append(String(localized: "running"))
        case .failed: parts.append(String(localized: "failed"))
        case .cancelled: parts.append(String(localized: "stopped"))
        case .declined: parts.append(String(localized: "declined"))
        default: if let code = card.exitCode, code != 0 { parts.append(String(localized: "exit code \(code)")) }
        }
        return parts.joined(separator: ", ")
    }
}

struct ToolCardDetail: View {
    @AppStorage("renderMathInMarkdown") private var renderMathInMarkdown = false
    let card: TranscriptToolCard
    var entity: ProviderEntity?
    var workspacePath: String?
    var openFile: (URL, Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let detail = card.detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            switch card.kind {
            case .command:
                CommandOutputView(command: card.subject, cwd: card.cwd, output: card.output, exitCode: card.exitCode)
            case .edit where !card.changes.isEmpty:
                ForEach(card.changes) { change in
                    TranscriptFileDiffView(change: change, workspacePath: workspacePath, openFile: openFile)
                }
                if let output = card.output { TranscriptOutputText(text: output, title: String(localized: "Output")) }
            case .todo:
                TranscriptTodoList(todos: card.todos)
            case .plan:
                MarkdownView(card.plan ?? "", workspace: workspacePath.map { URL(fileURLWithPath: $0) }, mathEnabled: renderMathInMarkdown, openFile: openFile)
            default:
                if !card.paths.isEmpty { pathList }
                if let input = card.input, card.kind != .read { TranscriptOutputText(text: input, title: String(localized: "Input")) }
                if let output = card.output { TranscriptOutputText(text: output, title: card.kind == .read ? String(localized: "Contents") : String(localized: "Output")) }
                if card.input == nil, card.output == nil, card.paths.isEmpty, entity == nil {
                    Text("No details were recorded for this tool call.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let entity {
                DisclosureGroup("Details") {
                    Text(TranscriptOutputTail.head(entity.fields.pretty, maxBytes: 32_768).text)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pathList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(Set(card.paths)).sorted(), id: \.self) { path in
                Button {
                    openFile(TranscriptPaths.url(path, workspacePath: workspacePath), nil)
                } label: {
                    Label(TranscriptToolPresentation.relative(path, to: workspacePath), systemImage: "doc")
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.link).help(String(localized: "Open \(path)")).disabled(workspacePath == nil)
            }
        }
    }
}

enum TranscriptPaths {
    static func url(_ path: String, workspacePath: String?) -> URL {
        if path.hasPrefix("/") || workspacePath == nil { return URL(fileURLWithPath: path).standardizedFileURL }
        return URL(fileURLWithPath: workspacePath!).appendingPathComponent(path).standardizedFileURL
    }
}

/// `$ command`, then a bounded output tail with Copy Output and a full view.
struct CommandOutputView: View {
    let command: String?
    var cwd: String?
    let output: String?
    var exitCode: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let command {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$").foregroundStyle(.tertiary)
                    Text(command).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.font(.system(.caption, design: .monospaced))
                    .accessibilityElement(children: .combine).accessibilityLabel(String(localized: "Command \(command)"))
            }
            if let cwd { Text(cwd).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
            if let output, !output.isEmpty { TranscriptOutputText(text: output, title: nil, tail: true) }
            else { Text("No output").font(.caption).foregroundStyle(.tertiary) }
            if let exitCode { Text("Exit code \(exitCode)").font(.caption2.monospacedDigit()).foregroundStyle(exitCode == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red)) }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)) }
    }
}

/// Long outputs are bounded to a head or tail window; the full text opens in a
/// separate sheet and copies without rendering.
struct TranscriptOutputText: View {
    let text: String
    var title: String?
    var tail = false
    @State private var showAll = false
    var body: some View {
        let window = tail ? TranscriptOutputTail.tail(text) : TranscriptOutputTail.head(text)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let title { Text(title).font(.caption).foregroundStyle(.secondary) }
                if window.truncated { Text(tail ? "Showing the end" : "Showing the beginning").font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Copy Output", systemImage: "doc.on.doc").labelStyle(.iconOnly) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy output").accessibilityLabel("Copy output")
                if window.truncated { Button("Show All") { showAll = true }.buttonStyle(.link).font(.caption) }
            }
            // The window is already bounded, so its line count sizes the panel.
            ScrollView(.vertical) {
                Text(window.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(260, CGFloat(window.text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }) * 15 + 4))
        }
        .sheet(isPresented: $showAll) { TranscriptFullOutputSheet(text: text, title: title ?? String(localized: "Output")) }
    }
}

struct TranscriptFullOutputSheet: View {
    let text: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let window = TranscriptOutputTail.head(text, maxLines: 50_000, maxBytes: 2_097_152)
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.title3).padding(16)
            Divider()
            TranscriptPlainTextViewport(text: window.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if window.truncated { Text("Showing the first 2 MB. Copy includes everything.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Copy All") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(minWidth: 420, idealWidth: 720, minHeight: 300, idealHeight: 520)
    }
}

/// Native lazy text layout keeps a large explicitly opened output from being
/// measured in full by SwiftUI. The viewport never executes or interprets text.
struct TranscriptPlainTextViewport: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView(text: text) }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, !view.string.utf8.elementsEqual(text.utf8) else { return }
        view.string = text
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 640, height: proposal.height ?? 400)
    }
    static func makeScrollView(text: String) -> NSScrollView {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true; storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false; layout.addTextContainer(container)
        let view = NSTextView(frame: .init(x: 0, y: 0, width: 640, height: 400), textContainer: container)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = .init(width: 12, height: 12)
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.textColor = .labelColor; view.drawsBackground = false
        view.setAccessibilityLabel("Recorded tool output"); view.setAccessibilityIdentifier("transcript-full-output")
        view.string = text
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.documentView = view
        return scroll
    }
}

struct TranscriptTodoList: View {
    let todos: [TranscriptTodo]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : todo.isActive ? "circle.dotted" : "circle")
                        .foregroundStyle(todo.isCompleted ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .accessibilityLabel(todo.isCompleted ? String(localized: "Completed") : todo.isActive ? String(localized: "In progress") : String(localized: "Not started"))
                    Text(todo.text).strikethrough(todo.isCompleted).foregroundStyle(todo.isCompleted ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }.font(.callout).accessibilityElement(children: .combine)
            }
        }
    }
}

/// Reasoning: "Thinking" with a live one-line preview while streaming, then
/// "Thought for Xs" (or "Thought"); expanded content renders as Markdown.
struct ReasoningRowView: View {
    @AppStorage("renderMathInMarkdown") private var renderMathInMarkdown = false
    let text: String
    let live: Bool
    let duration: TimeInterval?
    @Binding var expanded: Bool
    var workspace: URL?
    var openFile: (URL, Int?) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "brain").frame(width: 15).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.callout)
                        if !expanded {
                            let preview = TranscriptReasoningPreview.line(text)
                            if !preview.isEmpty { Text(preview).font(.caption).foregroundStyle(.tertiary).lineLimit(live ? 2 : 1) }
                        }
                    }
                    if live { ProgressView().controlSize(.mini) }
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
                    Spacer(minLength: 0)
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? String(localized: "Expanded") : TranscriptReasoningPreview.line(text))
            .accessibilityIdentifier("transcript-reasoning")
            if expanded {
                MarkdownView(text, workspace: workspace, mathEnabled: renderMathInMarkdown, openFile: openFile)
                    .foregroundStyle(.secondary).padding(.leading, 22)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var title: String {
        if live { return String(localized: "Thinking") }
        return duration.map { String(localized: "Thought for \(TranscriptDuration.format($0))") } ?? String(localized: "Thought")
    }
}

/// Consecutive tool/reasoning rows of one run. Collapsed, it reads like T3's
/// work log ("Ran 2 commands and read 3 files"); while live it names the newest
/// entry instead.
struct TranscriptWorkGroupView<Entry: View>: View {
    let group: TranscriptWorkGroup
    let toggle: () -> Void
    @ViewBuilder let entry: (TranscriptEntry) -> Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: symbol).frame(width: 15).accessibilityHidden(true)
                    Text(label).font(.callout).lineLimit(1).truncationMode(.tail)
                    if group.live { ProgressView().controlSize(.mini) }
                    else if group.hasFailure { TranscriptToolStatusView(status: .failed) }
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(group.expanded ? 90 : 0)).accessibilityHidden(true)
                    Spacer(minLength: 0)
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.hasFailure ? String(localized: "\(label), a tool call failed") : label)
            .accessibilityValue(group.expanded ? String(localized: "Expanded") : String(localized: "\(group.entries.count) items collapsed"))
            .accessibilityIdentifier("transcript-group-\(group.entries.first?.id ?? "")")
            if group.expanded {
                VStack(alignment: .leading, spacing: 8) { ForEach(group.entries) { entry($0) } }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1).padding(.leading, 6) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var latest: TranscriptEntry? { group.entries.last(where: \.isLive) ?? group.entries.last }
    private var label: String {
        guard group.live, let latest else { return group.summary }
        let title = latest.isReasoning ? String(localized: "Thinking") : latest.card?.title ?? group.summary
        return String(localized: "\(title) · \(group.entries.count) steps")
    }
    private var symbol: String {
        if group.live, let card = latest?.card { return TranscriptToolSymbol.name(card.kind) }
        let kinds = Set(group.entries.map { $0.card?.kind })
        if kinds == [nil] { return "brain" }
        if kinds.count == 1, let kind = kinds.first, let kind { return TranscriptToolSymbol.name(kind) }
        return "hammer"
    }
}

/// "Worked for 2m 13s": a completed run's intermediate work behind one row.
struct TurnFoldRow: View {
    let fold: TranscriptTurnFold
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Text(fold.label).font(.callout)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(fold.expanded ? 90 : 0)).accessibilityHidden(true)
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).accessibilityHidden(true)
            }.foregroundStyle(.secondary).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(fold.label)
        .accessibilityValue(fold.expanded ? String(localized: "Expanded") : String(localized: "\(fold.hiddenCount) items hidden"))
        .accessibilityHint(fold.expanded ? String(localized: "Hides this turn's work") : String(localized: "Shows this turn's work"))
        .accessibilityIdentifier("transcript-fold-\(fold.runID)")
    }
}
