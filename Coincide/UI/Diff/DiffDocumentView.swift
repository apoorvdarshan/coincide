import AppKit
import CoincideKit

/// Facts about a diff that don't depend on which files are collapsed, computed off the main actor.
nonisolated struct DiffPresentation: Sendable {
    struct LineKey: Hashable, Sendable {
        var file: Int
        var hunk: Int
        var line: Int
    }

    /// The changed part of a line paired with its replacement, in UTF-16 offsets.
    var highlights: [LineKey: Range<Int>] = [:]
    /// The widest line, in character cells (a tab counts as four).
    var maxColumns = 0
    var maxLineNumber = 1

    static let empty = DiffPresentation()

    static func make(_ diff: GitDiff) -> DiffPresentation {
        var presentation = DiffPresentation()
        for (fileIndex, file) in diff.files.enumerated() {
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                presentation.maxLineNumber = max(
                    presentation.maxLineNumber, hunk.oldStart + hunk.oldCount, hunk.newStart + hunk.newCount)
                let lines = hunk.lines
                for line in lines {
                    let tabs = line.text.utf8.reduce(0) { $0 + ($1 == 0x09 ? 1 : 0) }
                    presentation.maxColumns = max(
                        presentation.maxColumns, min(line.text.utf16.count, DiffLineView.maxDrawnLength) + tabs * 3)
                }
                // Pair a run of deletions with the run of additions that replaces it.
                var index = 0
                while index < lines.count {
                    guard lines[index].kind == .deletion else {
                        index += 1
                        continue
                    }
                    var additionsStart = index
                    while additionsStart < lines.count, lines[additionsStart].kind == .deletion { additionsStart += 1 }
                    var additionsEnd = additionsStart
                    while additionsEnd < lines.count, lines[additionsEnd].kind == .addition { additionsEnd += 1 }
                    let pairs = min(additionsStart - index, additionsEnd - additionsStart)
                    for offset in 0..<pairs {
                        guard
                            let ranges = changedRanges(
                                lines[index + offset].text, lines[additionsStart + offset].text)
                        else { continue }
                        presentation.highlights[LineKey(file: fileIndex, hunk: hunkIndex, line: index + offset)] = ranges.0
                        presentation.highlights[LineKey(file: fileIndex, hunk: hunkIndex, line: additionsStart + offset)] =
                            ranges.1
                    }
                    index = max(additionsEnd, index + 1)
                }
            }
        }
        return presentation
    }

    /// The differing middle of two lines, or nil when they barely overlap (highlighting the
    /// whole line would only add noise).
    static func changedRanges(_ old: String, _ new: String) -> (Range<Int>, Range<Int>)? {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        guard a.count < 2_000, b.count < 2_000, !a.isEmpty || !b.isEmpty else { return nil }
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let oldRange = prefix..<(a.count - suffix)
        let newRange = prefix..<(b.count - suffix)
        let shared = prefix + suffix
        guard shared > 0, shared * 3 >= max(a.count, b.count) else { return nil }
        return (oldRange, newRange)
    }
}

/// One row of the diff table.
nonisolated enum DiffRow: Hashable, Sendable {
    enum Note: Hashable, Sendable {
        case binary
        case unchanged
        case notLoaded
    }

    case file(Int)
    case hunk(file: Int, hunk: Int)
    case line(file: Int, hunk: Int, line: Int)
    case note(file: Int, Note)

    var file: Int {
        switch self {
        case .file(let file), .hunk(let file, _), .line(let file, _, _), .note(let file, _): file
        }
    }
}

/// Fonts and sizes shared by every row.
struct DiffMetrics {
    let font: NSFont
    let numberFont: NSFont
    let charWidth: CGFloat
    let lineHeight: CGFloat
    let textHeight: CGFloat
    let numberColumnWidth: CGFloat
    let markerWidth: CGFloat

    init(fontSize: CGFloat, maxLineNumber: Int) {
        font = .monospacedSystemFont(ofSize: max(9, fontSize - 1), weight: .regular)
        numberFont = .monospacedDigitSystemFont(ofSize: max(8, fontSize - 2), weight: .regular)
        charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        textHeight = ceil(font.ascender - font.descender + font.leading)
        lineHeight = textHeight + 4
        let digits = max(3, String(maxLineNumber).count)
        let numberCharWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        numberColumnWidth = ceil(CGFloat(digits) * numberCharWidth) + 14
        markerWidth = ceil(charWidth) + 10
    }

    var gutterWidth: CGFloat { numberColumnWidth * 2 + markerWidth }
    var textOrigin: CGFloat { gutterWidth + 4 }
    var fileHeaderHeight: CGFloat { max(30, textHeight + 14) }
    var hunkHeight: CGFloat { lineHeight + 6 }
    var noteHeight: CGFloat { lineHeight + 14 }

    func contentWidth(columns: Int) -> CGFloat { textOrigin + CGFloat(columns) * charWidth + 32 }

    var textAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = charWidth * 4
        style.lineBreakMode = .byClipping
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
    }
}

/// Diff colors; dynamic, so they follow light and dark mode.
enum DiffColors {
    static var additionBackground: NSColor { Theme.addition }
    static var deletionBackground: NSColor { Theme.deletion }
    static let additionGutter = Theme.dynamic(.systemGreen, alpha: 0.24)
    static let deletionGutter = Theme.dynamic(.systemRed, alpha: 0.24)
    static let additionHighlight = Theme.dynamic(.systemGreen, alpha: 0.38)
    static let deletionHighlight = Theme.dynamic(.systemRed, alpha: 0.38)
    static let contextGutter = Theme.dynamic(.labelColor, alpha: 0.035)
    static let hunkBackground = Theme.dynamic(.systemBlue, alpha: 0.08)
    static let headerTint = Theme.dynamic(.labelColor, alpha: 0.035)
    static var headerBackground: NSColor { .controlBackgroundColor }
    static var addition: NSColor { .systemGreen }
    static var deletion: NSColor { .systemRed }

    static func status(_ status: ChangedFile.Status) -> (letter: String, color: NSColor) {
        switch status {
        case .added: ("A", .systemGreen)
        case .untracked: ("U", .systemGreen)
        case .modified: ("M", .systemOrange)
        case .deleted: ("D", .systemRed)
        case .renamed: ("R", .systemBlue)
        }
    }

    static func statusName(_ status: ChangedFile.Status) -> String {
        switch status {
        case .added: String(localized: "Added")
        case .untracked: String(localized: "Untracked")
        case .modified: String(localized: "Modified")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        }
    }
}

/// A scrolling, line-numbered unified diff of several files. Only visible rows exist as views,
/// so diffs with tens of thousands of lines stay fast; file headers float while their file scrolls.
final class DiffDocumentView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// Called with the index of the file at the top of the view as the user scrolls.
    var onVisibleFileChange: ((Int) -> Void)?
    /// Called when the user collapses or expands a file.
    var onCollapseChange: (() -> Void)?
    /// Repository root, used to open and reveal files.
    var rootURL: URL?
    /// Attaches a comment on selected lines to the composer's message. Commenting is offered while it is set.
    var onAddComment: ((MessageContext) -> Void)?
    private(set) var collapsedPaths: Set<String> = []

    private let scrollView = NSScrollView()
    private let tableView = DiffTableView()
    private var diff = GitDiff.empty
    private var presentation = DiffPresentation.empty
    private var rows: [DiffRow] = []
    /// Row of each file's header.
    private var fileRows: [Int] = []
    private var metrics = DiffMetrics(fontSize: Theme.fontSize, maxLineNumber: 1)
    private var lastVisibleFile = -1
    private var lastPinnedX: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = []
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.floatsGroupRows = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .textBackgroundColor
        tableView.dataSource = self
        tableView.delegate = self
        tableView.copyHandler = { [weak self] in self?.copySelection() }
        tableView.commentHandler = { [weak self] in self?.commentOnSelection() }
        tableView.canComment = { [weak self] in self?.commentTarget() != nil }
        tableView.setAccessibilityLabel(String(localized: "Diff"))
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewChanged), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewChanged), name: NSView.frameDidChangeNotification,
            object: scrollView.contentView)
    }

    /// Space kept clear under the last row, for floating chrome.
    var bottomInset: CGFloat = 0 {
        didSet { scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0) }
    }

    var fileCount: Int { diff.files.count }

    // MARK: Content

    /// Shows a new diff. With `keepPosition`, the file at the top stays where it was.
    func show(_ diff: GitDiff, presentation: DiffPresentation, keepPosition: Bool) {
        let anchor = keepPosition ? currentAnchor() : nil
        self.diff = diff
        self.presentation = presentation
        let paths = Set(diff.files.map(\.path))
        collapsedPaths.formIntersection(paths)
        metrics = DiffMetrics(fontSize: Theme.fontSize, maxLineNumber: presentation.maxLineNumber)
        rebuildRows()
        if let anchor {
            restore(anchor)
        } else {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        lastVisibleFile = -1
        clipViewChanged()
    }

    func setCollapsed(_ collapsed: Bool, path: String) {
        let anchorRow = diff.files.firstIndex { $0.path == path }.map { fileRows[$0] }
        let offset = anchorRow.map { tableView.rect(ofRow: $0).minY - scrollView.contentView.bounds.minY }
        if collapsed { collapsedPaths.insert(path) } else { collapsedPaths.remove(path) }
        rebuildRows()
        if let index = diff.files.firstIndex(where: { $0.path == path }), let offset {
            let y = tableView.rect(ofRow: fileRows[index]).minY - offset
            scrollTo(y: y)
        }
        onCollapseChange?()
    }

    func setAllCollapsed(_ collapsed: Bool) {
        collapsedPaths = collapsed ? Set(diff.files.map(\.path)) : []
        rebuildRows()
        scrollTo(y: 0)
        onCollapseChange?()
    }

    var allCollapsed: Bool { !diff.files.isEmpty && collapsedPaths.count == diff.files.count }

    func scrollToFile(at index: Int) {
        guard fileRows.indices.contains(index) else { return }
        scrollTo(y: tableView.rect(ofRow: fileRows[index]).minY)
        lastVisibleFile = index
    }

    private func scrollTo(y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, tableView.frame.height - clip.bounds.height + bottomInset)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    private func rebuildRows() {
        rows.removeAll(keepingCapacity: true)
        fileRows.removeAll(keepingCapacity: true)
        for (fileIndex, file) in diff.files.enumerated() {
            fileRows.append(rows.count)
            rows.append(.file(fileIndex))
            guard !collapsedPaths.contains(file.path) else { continue }
            if file.isBinary {
                rows.append(.note(file: fileIndex, .binary))
            } else if file.hunks.isEmpty {
                rows.append(.note(file: fileIndex, file.additions + file.deletions > 0 ? .notLoaded : .unchanged))
            } else {
                for (hunkIndex, hunk) in file.hunks.enumerated() {
                    rows.append(.hunk(file: fileIndex, hunk: hunkIndex))
                    for lineIndex in hunk.lines.indices {
                        rows.append(.line(file: fileIndex, hunk: hunkIndex, line: lineIndex))
                    }
                }
            }
        }
        updateColumnWidth()
        tableView.reloadData()
    }

    private func updateColumnWidth() {
        guard let column = tableView.tableColumns.first else { return }
        let width = max(metrics.contentWidth(columns: presentation.maxColumns), scrollView.contentView.bounds.width)
        if abs(column.width - width) > 0.5 { column.width = width }
    }

    // MARK: Position

    private struct Anchor {
        var path: String
        var offset: CGFloat
        var x: CGFloat
    }

    private func currentAnchor() -> Anchor? {
        let clip = scrollView.contentView.bounds
        let row = tableView.row(at: NSPoint(x: 0, y: clip.minY + 1))
        guard rows.indices.contains(row) else { return nil }
        let file = rows[row].file
        guard diff.files.indices.contains(file) else { return nil }
        return Anchor(
            path: diff.files[file].path, offset: clip.minY - tableView.rect(ofRow: fileRows[file]).minY, x: clip.minX)
    }

    private func restore(_ anchor: Anchor) {
        guard let index = diff.files.firstIndex(where: { $0.path == anchor.path }) else {
            scrollTo(y: 0)
            return
        }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: anchor.x, y: clip.bounds.minY))
        scrollTo(y: tableView.rect(ofRow: fileRows[index]).minY + anchor.offset)
    }

    @objc private func clipViewChanged() {
        updateColumnWidth()
        let bounds = scrollView.contentView.bounds
        if abs(bounds.minX - lastPinnedX) > 0.1 {
            lastPinnedX = bounds.minX
            // Gutters and headers stay put while the text scrolls sideways.
            tableView.enumerateAvailableRowViews { rowView, _ in
                rowView.subviews.forEach { $0.needsDisplay = true }
            }
        }
        guard !rows.isEmpty else { return }
        let row = tableView.row(at: NSPoint(x: 0, y: bounds.minY + 1))
        guard rows.indices.contains(row) else { return }
        let file = rows[row].file
        if file != lastVisibleFile {
            lastVisibleFile = file
            onVisibleFileChange?(file)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .file: metrics.fileHeaderHeight
        case .hunk: metrics.hunkHeight
        case .line: metrics.lineHeight
        case .note: metrics.noteHeight
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .file = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .line = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("diffRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffRowView ?? DiffRowView()
        view.identifier = identifier
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .file(let index):
            let view = reuse(DiffFileHeaderView.self, "fileHeader")
            let file = diff.files[index]
            view.configure(file: file, collapsed: collapsedPaths.contains(file.path), metrics: metrics)
            view.onToggle = { [weak self] in
                guard let self else { return }
                self.setCollapsed(!self.collapsedPaths.contains(file.path), path: file.path)
            }
            return view
        case .hunk(let fileIndex, let hunkIndex):
            let view = reuse(DiffHunkView.self, "hunk")
            view.configure(hunk: diff.files[fileIndex].hunks[hunkIndex], metrics: metrics)
            return view
        case .line(let fileIndex, let hunkIndex, let lineIndex):
            let view = reuse(DiffLineView.self, "line")
            let key = DiffPresentation.LineKey(file: fileIndex, hunk: hunkIndex, line: lineIndex)
            view.configure(
                line: diff.files[fileIndex].hunks[hunkIndex].lines[lineIndex], highlight: presentation.highlights[key],
                metrics: metrics)
            return view
        case .note(let fileIndex, let note):
            let view = reuse(DiffNoteView.self, "note")
            view.configure(text: Self.noteText(note, file: diff.files[fileIndex]), metrics: metrics)
            return view
        }
    }

    private func reuse<View: DiffRowContentView>(_ type: View.Type, _ name: String) -> View {
        let identifier = NSUserInterfaceItemIdentifier(name)
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? View { return view }
        let view = View(frame: .zero)
        view.identifier = identifier
        view.clipView = scrollView.contentView
        return view
    }

    private static func noteText(_ note: DiffRow.Note, file: FileDiff) -> String {
        switch note {
        case .binary: return String(localized: "Binary file not shown.")
        case .notLoaded: return String(localized: "The diff for this file is too large to show.")
        case .unchanged:
            if let mode = file.modeChange { return String(localized: "File mode changed: \(mode)") }
            if file.status == .renamed { return String(localized: "Renamed without content changes.") }
            return String(localized: "No content changes.")
        }
    }

    // MARK: Copy and context menu

    private func selectedText() -> String {
        tableView.selectedRowIndexes.compactMap { row -> String? in
            guard case .line(let file, let hunk, let line) = rows[row] else { return nil }
            let diffLine = diff.files[file].hunks[hunk].lines[line]
            return diffLine.kind == .noNewline ? nil : diffLine.text
        }.joined(separator: "\n")
    }

    private func copySelection() {
        let text = selectedText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.setText(text)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        if case .line = rows[row] {
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let title =
                tableView.selectedRowIndexes.count > 1 ? String(localized: "Copy Lines") : String(localized: "Copy Line")
            menu.addItem(withTitle: title, action: #selector(copyLines), keyEquivalent: "").target = self
            if onAddComment != nil {
                menu.addItem(withTitle: String(localized: "Comment…"), action: #selector(commentOnLines), keyEquivalent: "").target =
                    self
            }
            menu.addItem(.separator())
        }
        let file = diff.files[rows[row].file]
        FileActions.addItems(to: menu, path: file.path, root: rootURL, deleted: file.status == .deleted)
    }

    @objc private func copyLines() { copySelection() }

    @objc private func commentOnLines() { commentOnSelection() }

    // MARK: Comments

    /// The selected lines to comment on: those in the file of the line clicked or, from the keyboard, of the first
    /// selected line, as indexes into the file's hunks.
    private func commentTarget() -> (file: Int, lines: [(hunk: Int, line: Int)], rows: [Int])? {
        let selected = tableView.selectedRowIndexes.filter { rows.indices.contains($0) }
        let anchor = tableView.clickedRow >= 0 && selected.contains(tableView.clickedRow) ? tableView.clickedRow : selected.first
        guard let anchor else { return nil }
        let fileIndex = rows[anchor].file
        var lines: [(hunk: Int, line: Int)] = []
        var lineRows: [Int] = []
        for row in selected {
            guard case .line(let file, let hunk, let line) = rows[row], file == fileIndex else { continue }
            lines.append((hunk, line))
            lineRows.append(row)
        }
        guard !lines.isEmpty, diff.files.indices.contains(fileIndex) else { return nil }
        return (fileIndex, lines, lineRows)
    }

    /// Opens the comment field under the selected lines; what the user writes goes to the composer with the lines.
    private func commentOnSelection() {
        guard let onAddComment, let target = commentTarget() else { return }
        let file = diff.files[target.file]
        guard let draft = MessageContext.DiffComment(file: file, lines: target.lines, comment: "") else { return }
        let editor = DiffCommentEditor(draft: draft)
        editor.onAdd = { text in
            guard let comment = MessageContext.DiffComment(file: file, lines: target.lines, comment: text) else { return }
            onAddComment(MessageContext(.diffComment(comment)))
        }
        // Under the last selected line where the text starts, or at the top when the lines scrolled away.
        let visible = tableView.visibleRect
        var anchor = tableView.rect(ofRow: target.rows.max() ?? 0).intersection(visible)
        if anchor.isEmpty { anchor = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: metrics.lineHeight) }
        anchor.origin.x = visible.minX + metrics.textOrigin
        anchor.size.width = max(1, anchor.width - metrics.textOrigin)
        ThemedPopup.show(editor, from: tableView, rect: anchor, preferAbove: false)
    }
}

/// Lets ⌘C copy the selected lines and Add Selection to Composer (⌘L) comment on them.
final class DiffTableView: NSTableView, ComposerSelectionSource {
    var copyHandler: (() -> Void)?
    var commentHandler: (() -> Void)?
    var canComment: (() -> Bool)?

    override func menu(for event: NSEvent) -> NSMenu? {
        ThemedContextMenu.show(super.menu(for: event), for: event, in: window)
    }

    var addToComposerTitle: String { String(localized: "Comment on Selected Lines…") }

    var canAddSelectionToComposer: Bool { canComment?() ?? false }

    func addSelectionToComposer() { commentHandler?() }

    @objc func copy(_ sender: Any?) { copyHandler?() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

/// Row background that keeps diff colors visible under the selection.
final class DiffRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.sidebarSelection.setFill()
        bounds.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isGroupRowStyle {
            DiffColors.headerBackground.setFill()
            dirtyRect.fill()
        } else {
            super.drawBackground(in: dirtyRect)
        }
    }
}

/// A row's content. Gutters and headers stay at the visible left edge while text scrolls sideways;
/// the clip view is held directly because a floating header row has no enclosing scroll view.
class DiffRowContentView: NSView {
    weak var clipView: NSClipView?

    required override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var pinnedX: CGFloat { clipView?.bounds.minX ?? 0 }
    var pinnedWidth: CGFloat { clipView?.bounds.width ?? bounds.width }
}

/// One line of a hunk, drawn directly for speed.
final class DiffLineView: DiffRowContentView {
    /// Longer lines are cut, so a minified file can't stall drawing.
    nonisolated static let maxDrawnLength = 3_000

    private var line = DiffLine(kind: .context, text: "")
    private var highlight: Range<Int>?
    private var metrics = DiffMetrics(fontSize: 13, maxLineNumber: 1)

    override var isOpaque: Bool { false }

    func configure(line: DiffLine, highlight: Range<Int>?, metrics: DiffMetrics) {
        self.line = line
        self.highlight = highlight
        self.metrics = metrics
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let background: NSColor?
        let gutter: NSColor
        let marker: (String, NSColor)?
        switch line.kind {
        case .addition:
            background = DiffColors.additionBackground
            gutter = DiffColors.additionGutter
            marker = ("+", DiffColors.addition)
        case .deletion:
            background = DiffColors.deletionBackground
            gutter = DiffColors.deletionGutter
            marker = ("−", DiffColors.deletion)
        case .context, .noNewline:
            background = nil
            gutter = DiffColors.contextGutter
            marker = nil
        }
        if let background {
            background.setFill()
            dirtyRect.fill()
        }

        let pinned = pinnedX
        let textY = (bounds.height - metrics.textHeight) / 2
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: pinned + metrics.gutterWidth, y: 0, width: max(0, bounds.width - pinned), height: bounds.height).clip()
        drawText(at: NSPoint(x: metrics.textOrigin, y: textY))
        NSGraphicsContext.restoreGraphicsState()

        // The gutter is drawn last, pinned to the visible left edge.
        let gutterRect = NSRect(x: pinned, y: 0, width: metrics.gutterWidth, height: bounds.height)
        NSColor.textBackgroundColor.setFill()
        gutterRect.fill()
        gutter.setFill()
        gutterRect.fill()
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: metrics.numberFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let numberY = (bounds.height - (metrics.numberFont.ascender - metrics.numberFont.descender)) / 2
        for (number, column) in [(line.oldLine, 0), (line.newLine, 1)] {
            guard let number else { continue }
            let text = String(number) as NSString
            let width = text.size(withAttributes: numberAttributes).width
            let right = pinned + metrics.numberColumnWidth * CGFloat(column + 1) - 7
            text.draw(at: NSPoint(x: right - width, y: numberY), withAttributes: numberAttributes)
        }
        if let marker {
            (marker.0 as NSString).draw(
                at: NSPoint(x: pinned + metrics.numberColumnWidth * 2 + 5, y: textY),
                withAttributes: [.font: metrics.font, .foregroundColor: marker.1])
        }
    }

    private func drawText(at point: NSPoint) {
        var text = line.text
        if line.kind == .noNewline {
            text = String(localized: "No newline at end of file")
        } else if text.utf16.count > Self.maxDrawnLength {
            text = String(text.utf16.prefix(Self.maxDrawnLength)) ?? String(text.prefix(Self.maxDrawnLength / 2))
            text += " …"
        }
        var attributes = metrics.textAttributes
        if line.kind == .noNewline {
            attributes[.foregroundColor] = NSColor.tertiaryLabelColor
        }
        let string = NSMutableAttributedString(string: text, attributes: attributes)
        if let highlight, highlight.upperBound <= string.length, !highlight.isEmpty {
            let color = line.kind == .addition ? DiffColors.additionHighlight : DiffColors.deletionHighlight
            string.addAttribute(
                .backgroundColor, value: color,
                range: NSRange(location: highlight.lowerBound, length: highlight.count))
        }
        string.draw(at: point)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override func accessibilityLabel() -> String? {
        switch line.kind {
        case .addition: String(localized: "Added line \(line.newLine ?? 0): \(line.text)")
        case .deletion: String(localized: "Removed line \(line.oldLine ?? 0): \(line.text)")
        case .context: String(localized: "Line \(line.newLine ?? 0): \(line.text)")
        case .noNewline: String(localized: "No newline at end of file")
        }
    }
}

/// `@@ -a,b +c,d @@ section` between hunks.
final class DiffHunkView: DiffRowContentView {
    private var text = ""
    private var metrics = DiffMetrics(fontSize: 13, maxLineNumber: 1)

    func configure(hunk: DiffHunk, metrics: DiffMetrics) {
        text = hunk.header
        self.metrics = metrics
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        DiffColors.hunkBackground.setFill()
        dirtyRect.fill()
        let pinned = pinnedX
        let attributes: [NSAttributedString.Key: Any] = [
            .font: metrics.font, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let y = (bounds.height - metrics.textHeight) / 2
        (text as NSString).draw(at: NSPoint(x: pinned + metrics.textOrigin, y: y), withAttributes: attributes)
        let dots = "⋯" as NSString
        dots.draw(
            at: NSPoint(x: pinned + metrics.numberColumnWidth - 18, y: y),
            withAttributes: [.font: metrics.font, .foregroundColor: NSColor.tertiaryLabelColor])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { String(localized: "Hunk \(text)") }
}

/// A one-line note in place of a file's hunks.
final class DiffNoteView: DiffRowContentView {
    private var text = ""
    private var metrics = DiffMetrics(fontSize: 13, maxLineNumber: 1)

    func configure(text: String, metrics: DiffMetrics) {
        self.text = text
        self.metrics = metrics
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Theme.fontSize - 1), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: pinnedX + metrics.textOrigin, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { text }
}

/// A file's header: disclosure chevron, status, path and line counts. Clicking toggles the file.
final class DiffFileHeaderView: DiffRowContentView {
    var onToggle: (() -> Void)?
    private var file = FileDiff(path: "", status: .modified)
    private var collapsed = false
    private var metrics = DiffMetrics(fontSize: 13, maxLineNumber: 1)

    func configure(file: FileDiff, collapsed: Bool, metrics: DiffMetrics) {
        self.file = file
        self.collapsed = collapsed
        self.metrics = metrics
        toolTip = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 { onToggle?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        DiffColors.headerBackground.setFill()
        dirtyRect.fill()
        DiffColors.headerTint.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: dirtyRect.minX, y: bounds.maxY - 1, width: dirtyRect.width, height: 1).fill()
        NSRect(x: dirtyRect.minX, y: 0, width: dirtyRect.width, height: 1).fill()

        let left = pinnedX + 10
        let right = pinnedX + pinnedWidth - 10
        let midY = bounds.height / 2
        var x = left

        if let chevron = Theme.symbol(collapsed ? "chevron.right" : "chevron.down", size: 10, weight: .semibold) {
            let tinted = chevron.tinted(.secondaryLabelColor)
            tinted.draw(in: NSRect(x: x, y: midY - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height))
        }
        x += 16

        let status = DiffColors.status(file.status)
        let badgeFont = NSFont.monospacedSystemFont(ofSize: max(9, Theme.fontSize - 3), weight: .bold)
        let badgeRect = NSRect(x: x, y: midY - 8, width: 16, height: 16)
        status.color.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4).fill()
        let letter = status.letter as NSString
        let letterAttributes: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: status.color]
        let letterSize = letter.size(withAttributes: letterAttributes)
        letter.draw(
            at: NSPoint(x: badgeRect.midX - letterSize.width / 2, y: badgeRect.midY - letterSize.height / 2),
            withAttributes: letterAttributes)
        x += 24

        let counts = NSMutableAttributedString()
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .medium)
        if file.isBinary {
            counts.append(
                NSAttributedString(
                    string: String(localized: "Binary"),
                    attributes: [.font: countFont, .foregroundColor: NSColor.secondaryLabelColor]))
        } else {
            counts.append(
                NSAttributedString(string: "+\(file.additions)", attributes: [.font: countFont, .foregroundColor: DiffColors.addition]))
            counts.append(NSAttributedString(string: "  "))
            counts.append(
                NSAttributedString(string: "−\(file.deletions)", attributes: [.font: countFont, .foregroundColor: DiffColors.deletion]))
        }
        let countsSize = counts.size()
        counts.draw(at: NSPoint(x: right - countsSize.width, y: midY - countsSize.height / 2))

        let path = FileActions.attributedPath(file.path, oldPath: file.oldPath, size: Theme.fontSize - 1)
        let available = right - countsSize.width - 12 - x
        let pathSize = path.size()
        let rect = NSRect(x: x, y: midY - pathSize.height / 2, width: max(0, available), height: pathSize.height)
        path.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? {
        let state = collapsed ? String(localized: "collapsed") : String(localized: "expanded")
        return String(
            localized:
                "\(file.path), \(DiffColors.statusName(file.status)), \(file.additions) added, \(file.deletions) removed, \(state)"
        )
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Open, reveal and copy actions for a changed file.
enum FileActions {
    static func url(_ path: String, root: URL?) -> URL? {
        root?.appendingPathComponent(path)
    }

    /// `dir/` in secondary color followed by the file name, for one-line display.
    static func attributedPath(_ path: String, oldPath: String?, size: CGFloat) -> NSAttributedString {
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingHead
        let result = NSMutableAttributedString()
        if !directory.isEmpty {
            result.append(
                NSAttributedString(
                    string: directory + "/",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: style,
                    ]))
        }
        result.append(
            NSAttributedString(
                string: name,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: style,
                ]))
        if let oldPath, oldPath != path {
            result.append(
                NSAttributedString(
                    string: "  ← " + (oldPath as NSString).lastPathComponent,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.tertiaryLabelColor,
                        .paragraphStyle: style,
                    ]))
        }
        return result
    }

    static func addItems(to menu: NSMenu, path: String, root: URL?, deleted: Bool) {
        let target = FileActionTarget.shared
        let fileURL = url(path, root: root)
        func add(_ title: String, _ action: Selector, _ value: Any?, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = target
            item.representedObject = value
            menu.addItem(item)
        }
        add(String(localized: "Open File"), #selector(FileActionTarget.open(_:)), fileURL, enabled: !deleted && fileURL != nil)
        add(
            String(localized: "Reveal in Finder"), #selector(FileActionTarget.reveal(_:)), fileURL,
            enabled: !deleted && fileURL != nil)
        menu.addItem(.separator())
        add(String(localized: "Copy Path"), #selector(FileActionTarget.copy(_:)), path)
        if let fileURL {
            add(String(localized: "Copy Full Path"), #selector(FileActionTarget.copy(_:)), fileURL.path)
        }
    }
}

final class FileActionTarget: NSObject {
    static let shared = FileActionTarget()

    @objc func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        // Repository files may be scripts or apps; never hand them to their default handler.
        SafeLinks.openFile(url, from: NSApp.keyWindow)
    }

    @objc func reveal(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func copy(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.setText(text)
    }
}
