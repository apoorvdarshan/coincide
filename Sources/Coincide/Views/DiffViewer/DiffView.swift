import AppKit
import CoincideCore
import SwiftUI

/// Native rich diff review: file tree, unified or split rows, token colors, wrapping, optional
/// whitespace filtering, per-file collapse, copy path and open in an editor.
struct DiffView: View {
    let diff: UnifiedDiff
    var workspacePath: String? = nil
    var store: WorkspaceStore? = nil
    /// Nil when the source cannot re-read without whitespace changes.
    var ignoreWhitespace: Binding<Bool>? = nil
    var focusPath: String? = nil
    var emptyTitle = String(localized: "No Changes")
    var emptyDescription = String(localized: "There are no changes in this view.")
    var showsTruncationNotice = true
    @AppStorage(DiffViewerDefaults.layout) private var layoutValue = DiffLayout.unified.rawValue
    @AppStorage(DiffViewerDefaults.wrap) private var wrap = false
    @AppStorage(DiffViewerDefaults.showTree) private var showTree = true
    @State private var collapse = DiffCollapseState()
    @State private var scrollTarget: String?
    private var layout: DiffLayout { DiffLayout(rawValue: layoutValue) ?? .unified }

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if diff.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle", description: Text(emptyDescription))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    if showTree, proxy.size.width >= 560 {
                        let treeWidth = min(240, proxy.size.width * 0.32)
                        HStack(spacing: 0) {
                            tree.frame(width: treeWidth)
                            Divider()
                            files(width: proxy.size.width - treeWidth - 1)
                        }
                    } else {
                        VStack(spacing: 0) {
                            if showTree, diff.files.count > 1 { tree.frame(height: min(150, CGFloat(diff.files.count) * 24 + 12)); Divider() }
                            files(width: proxy.size.width)
                        }
                    }
                }
            }
            if diff.truncated && showsTruncationNotice {
                Divider()
                Label("Preview size limit reached. Some changes are not shown.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5)
                    .accessibilityIdentifier("diff-truncated")
            }
        }
        .accessibilityIdentifier("diff-view")
        .onAppear { if let focusPath { reveal(focusPath) } }
        .onChange(of: focusPath) { if let focusPath { reveal(focusPath) } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("Layout", selection: $layoutValue) {
                Image(systemName: "rectangle").accessibilityLabel("Unified").tag(DiffLayout.unified.rawValue)
                Image(systemName: "rectangle.split.2x1").accessibilityLabel("Split").tag(DiffLayout.split.rawValue)
            }.pickerStyle(.segmented).labelsHidden().fixedSize().help("Unified or split layout").accessibilityIdentifier("diff-layout")
            Menu {
                Toggle("Wrap Lines", isOn: $wrap)
                if let ignoreWhitespace { Toggle("Hide Whitespace Changes", isOn: ignoreWhitespace) }
                Toggle("Show File Tree", isOn: $showTree)
                Divider()
                Button("Collapse All Files") { collapse.collapseAll(diff.files) }.disabled(diff.isEmpty)
                Button("Expand All Files") { collapse.expandAll(diff.files) }.disabled(diff.isEmpty)
            } label: { Image(systemName: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).fixedSize().help("Diff view options").accessibilityLabel("Diff view options").accessibilityIdentifier("diff-options")
            Spacer(minLength: 4)
            if !diff.isEmpty {
                HStack(spacing: 5) {
                    Text("\(diff.files.count) \(diff.files.count == 1 ? String(localized: "file") : String(localized: "files"))").foregroundStyle(.secondary)
                    Text("+\(diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.deletions)").foregroundStyle(.red)
                }.font(.caption.monospacedDigit()).lineLimit(1)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(diff.files.count) files, \(diff.additions) additions, \(diff.deletions) deletions")
            }
        }.controlSize(.small)
    }

    private var tree: some View {
        List(DiffFileTree.build(diff.files), children: \.optionalChildren) { node in
            Button { if let id = node.fileID { scrollTarget = id; reveal(id: id) } } label: {
                HStack(spacing: 5) {
                    Image(systemName: node.isFolder ? "folder" : "doc.text").foregroundStyle(.secondary).imageScale(.small)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    if let status = node.status {
                        Text(DiffPresentation.statusLetter(status)).font(.caption2.weight(.semibold).monospaced()).foregroundStyle(DiffPresentation.statusColor(status))
                    }
                }.font(.caption).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(node.isFolder)
                .accessibilityLabel(node.isFolder ? "Folder \(node.path)" : "\(node.path), \(node.status.map(DiffPresentation.statusName) ?? ""), \(node.additions) additions, \(node.deletions) deletions")
        }.listStyle(.sidebar).accessibilityIdentifier("diff-file-tree")
    }

    private func files(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(diff.files) { file in
                        Section {
                            if !collapse.isCollapsed(file) { DiffFileBody(file: file, layout: layout, wrap: wrap, minWidth: max(0, width)) }
                        } header: {
                            DiffFileHeader(file: file, collapsed: collapse.isCollapsed(file), toggle: { collapse.toggle(file) },
                                           workspacePath: workspacePath, store: store)
                        }.id(file.id)
                    }
                }
            }
            // Code keeps a readable semantic backing rather than translucent chrome.
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: scrollTarget) {
                guard let scrollTarget else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(scrollTarget, anchor: .top) }
                self.scrollTarget = nil
            }
        }
    }

    private func reveal(_ path: String) {
        guard let file = diff.files.first(where: { $0.path == path || $0.oldPath == path }) else { return }
        reveal(id: file.id)
    }
    private func reveal(id: String) {
        guard let file = diff.files.first(where: { $0.id == id }) else { return }
        if collapse.isCollapsed(file) { collapse.setCollapsed(false, file) }
        scrollTarget = id
    }
}

struct DiffFileHeader: View {
    let file: UnifiedDiffFile
    let collapsed: Bool
    let toggle: () -> Void
    var workspacePath: String?
    var store: WorkspaceStore?
    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").frame(width: 12)
            }.buttonStyle(.plain).accessibilityLabel(collapsed ? "Expand \(file.path)" : "Collapse \(file.path)")
            Text(DiffPresentation.statusLetter(file.status)).font(.caption.weight(.bold).monospaced())
                .foregroundStyle(DiffPresentation.statusColor(file.status)).help(DiffPresentation.statusName(file.status))
            Group {
                if let old = file.oldPath, let new = file.newPath, old != new { Text(old + " → " + new) } else { Text(file.path) }
            }.font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 4)
            if file.isBinary { Text("Binary").font(.caption2).foregroundStyle(.secondary) }
            Text("+\(file.additions)").font(.caption2.monospacedDigit()).foregroundStyle(.green)
            Text("−\(file.deletions)").font(.caption2.monospacedDigit()).foregroundStyle(.red)
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy Path").accessibilityLabel("Copy path of \(file.path)")
            if let workspacePath, let store, file.newPath != nil {
                Button {
                    store.openFile(URL(fileURLWithPath: workspacePath).appendingPathComponent(file.path), line: file.firstChangedLine, workspacePath: workspacePath)
                } label: { Image(systemName: "doc.text.magnifyingglass") }.buttonStyle(.borderless).help("Show in Files")
                    .accessibilityLabel("Show \(file.path) in Files")
                ExternalEditorMenu(store: store, workspacePath: workspacePath, relativePath: file.path, line: file.firstChangedLine, title: String(localized: "Open in Editor"), compact: true)
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: toggle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(file.path), \(DiffPresentation.statusName(file.status)), \(file.additions) additions, \(file.deletions) deletions")
        .accessibilityIdentifier("diff-file-header-\(file.path)")
    }
}

struct DiffFileBody: View {
    let file: UnifiedDiffFile
    let layout: DiffLayout
    let wrap: Bool
    var minWidth: CGFloat = 0
    private var language: String { DiffPresentation.language(forExtension: file.fileExtension) }
    var body: some View {
        if file.hunks.isEmpty {
            Text(file.note ?? (file.isBinary ? String(localized: "Binary file not shown.") : file.status == .modeChanged
                    ? String(localized: "File mode changed from \(file.oldMode ?? "?") to \(file.newMode ?? "?").") : String(localized: "No text changes.")))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if layout == .unified && !wrap {
            // Equal-width rows: every background spans the widest line and at least the viewport.
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) { rows; Color.clear.frame(width: minWidth, height: 0) }
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else { rows }
        if file.isTruncated {
            Text("The rest of this file's changes are beyond the preview limit.").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(DiffRenderRow.rows(for: file, layout: layout)) { row in
                switch row {
                case .hunk(_, let header):
                    Text(header).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 8).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08))
                case .line(_, let line):
                    DiffLineRow(line: line, language: language, wrap: wrap, showsBothNumbers: true)
                case .split(_, let pair):
                    HStack(spacing: 0) {
                        DiffLineRow(line: pair.left, language: language, wrap: wrap, side: .left).frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        DiffLineRow(line: pair.right, language: language, wrap: wrap, side: .right).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

struct DiffLineRow: View {
    enum Side { case left, right }
    let line: UnifiedDiffLine?
    let language: String
    let wrap: Bool
    var showsBothNumbers = false
    var side: Side = .left
    private static let font = Font.system(size: 11.5, design: .monospaced)
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if showsBothNumbers {
                number(line?.oldLine); number(line?.newLine)
            } else { number(side == .left ? line?.oldLine : line?.newLine) }
            Text(marker).font(Self.font).foregroundStyle(markerColor).frame(width: 14)
            content
                .font(Self.font)
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap && showsBothNumbers, vertical: true)
                .truncationMode(.tail)
                .textSelection(.enabled)
            if wrap || !showsBothNumbers { Spacer(minLength: 0) }
        }
        .padding(.trailing, 8).padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
    @ViewBuilder private var content: some View {
        if let line {
            if line.kind == .noNewline { Text(line.text).italic().foregroundStyle(.secondary) }
            else { Text(DiffHighlightCache.attributed(line.text, language: language)) }
        } else { Text(" ") }
    }
    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            .frame(width: 40, alignment: .trailing).padding(.trailing, 4)
    }
    private var marker: String {
        switch line?.kind { case .addition: "+"; case .deletion: "−"; default: " " }
    }
    private var markerColor: Color { line?.kind == .addition ? .green : line?.kind == .deletion ? .red : .secondary }
    private var background: Color {
        switch line?.kind {
        case .addition: Color.green.opacity(0.14)
        case .deletion: Color.red.opacity(0.14)
        case nil: Color.secondary.opacity(0.06)
        default: .clear
        }
    }
    private var accessibilityText: String {
        guard let line else { return String(localized: "Empty") }
        switch line.kind {
        case .addition: return String(localized: "Added line \(line.newLine ?? 0): \(line.text)")
        case .deletion: return String(localized: "Removed line \(line.oldLine ?? 0): \(line.text)")
        case .context: return String(localized: "Line \(line.newLine ?? 0): \(line.text)")
        case .noNewline: return line.text
        }
    }
}
