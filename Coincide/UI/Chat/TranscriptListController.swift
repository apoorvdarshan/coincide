import AppKit
import CoincideKit

/// Where a thread was scrolled to, so returning to it lands in the same place.
enum TranscriptScrollState {
    case bottom
    case anchor(TranscriptRowID, offset: CGFloat)
}

/// Owns the transcript table: rows, heights, incremental updates and scrolling.
///
/// Rows near the viewport are measured exactly; the rest use cheap estimates until they scroll
/// close, and every height change keeps the content under the reader in place. While the reader is
/// at the bottom, the list follows new content.
@MainActor
final class TranscriptListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = TranscriptScrollView()
    let tableView = TranscriptTableView()
    weak var host: TranscriptHost?

    private(set) var rows: [TranscriptRow] = []
    /// Called when following the bottom starts or stops.
    var onPinnedChange: ((Bool) -> Void)?

    private(set) var isPinnedToBottom = true {
        didSet { if isPinnedToBottom != oldValue { onPinnedChange?(isPinnedToBottom) } }
    }

    private struct Height {
        var revision: Int
        var continuesWork: Bool
        var width: CGFloat
        var value: CGFloat
        var isExact: Bool
    }

    private static let followThreshold: CGFloat = 40

    private var heights: [TranscriptRowID: Height] = [:]
    private var exactRange: Range<Int> = 0..<0
    private var width: CGFloat = 0
    private var lastClipLayout: [CGFloat] = []
    private var isAdjustingScroll = false
    private var isAnimatingScroll = false
    private var refineScheduled = false
    private var frameChangeScheduled = false

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = false
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(String(localized: "Conversation"))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onReaderScroll = { [weak self] upward in self?.readerScrolled(upward: upward) }
        tableView.onReaderScroll = { [weak self] in self?.readerScrolledAndSettled() }
        tableView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(tableFrameChanged), name: NSView.frameDidChangeNotification, object: tableView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScrolled), name: NSScrollView.didLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScrolled), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    @objc private func liveScrolled(_ notification: Notification) {
        readerScrolled()
    }

    // MARK: Updates

    /// Shows new rows. Rows whose identity survived keep their views; those that changed are
    /// reconfigured in place, so streaming text never rebuilds the list. With `anchor`, that row
    /// stays where it is on screen, as when the reader expands it.
    func update(_ newRows: [TranscriptRow], reload: Bool = false, keeping anchor: TranscriptRowID? = nil) {
        if reload || rows.isEmpty || newRows.isEmpty {
            rows = newRows
            exactRange = Self.tail(of: newRows.count)
            tableView.reloadData()
            tableView.tile()
            scheduleRefine()
            return
        }
        let old = rows
        let limit = min(old.count, newRows.count)
        var prefix = 0
        while prefix < limit, old[prefix].id == newRows[prefix].id { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < newRows.count - prefix,
            old[old.count - 1 - suffix].id == newRows[newRows.count - 1 - suffix].id
        {
            suffix += 1
        }
        let removed = IndexSet(integersIn: prefix..<(old.count - suffix))
        let inserted = IndexSet(integersIn: prefix..<(newRows.count - suffix))
        var changed = IndexSet()
        for index in 0..<prefix where old[index] != newRows[index] { changed.insert(index) }
        for offset in 0..<suffix where old[old.count - 1 - offset] != newRows[newRows.count - 1 - offset] {
            changed.insert(newRows.count - 1 - offset)
        }
        guard !removed.isEmpty || !inserted.isEmpty || !changed.isEmpty else { return }

        exactRange = visibleRange(margin: 1).union(isPinnedToBottom ? Self.tail(of: newRows.count) : 0..<0)
        preservingAnchor(anchor) {
            rows = newRows
            if !removed.isEmpty || !inserted.isEmpty {
                tableView.beginUpdates()
                tableView.removeRows(at: removed, withAnimation: [])
                tableView.insertRows(at: inserted, withAnimation: [])
                tableView.endUpdates()
            }
            guard !changed.isEmpty else { return }
            for index in changed {
                guard let host, let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TranscriptCell else { continue }
                cell.configure(rows[index], host: host)
            }
            noteHeights(changed)
        }
        scheduleRefine()
    }

    /// Reconfigures the rows on screen, for state rows do not encode (such as whether a turn runs).
    func reconfigureVisibleCells() {
        guard let host else { return }
        let range = visibleRange(margin: 0)
        for index in range where index < rows.count {
            (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TranscriptCell)?.configure(rows[index], host: host)
        }
    }

    /// Forgets every measurement, for font size changes.
    func invalidateHeights() {
        heights.removeAll()
        exactRange = visibleRange(margin: 1)
        tableView.reloadData()
        scheduleRefine()
    }

    func refreshLiveState() {
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? TranscriptCell)?.refreshLiveState()
        }
    }

    func index(of id: TranscriptRowID) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    // MARK: Heights

    private func cellType(for kind: TranscriptRow.Kind) -> TranscriptCell.Type {
        switch kind {
        case .user: TranscriptUserCell.self
        case .assistant: TranscriptAssistantCell.self
        case .reasoning: TranscriptReasoningCell.self
        case .tool: TranscriptToolCell.self
        case .group: TranscriptGroupCell.self
        case .approval: TranscriptApprovalCell.self
        case .question: TranscriptQuestionCell.self
        case .plan: TranscriptPlanCell.self
        case .error: TranscriptErrorCell.self
        case .notice: TranscriptNoticeCell.self
        case .turnHeader: TranscriptTurnHeaderCell.self
        case .changedFiles: TranscriptChangedFilesCell.self
        case .live: TranscriptLiveCell.self
        case .spacer: TranscriptSpacerCell.self
        }
    }

    private func makeCell(for kind: TranscriptRow.Kind) -> TranscriptCell {
        switch kind {
        case .user: TranscriptUserCell()
        case .assistant: TranscriptAssistantCell()
        case .reasoning: TranscriptReasoningCell()
        case .tool: TranscriptToolCell()
        case .group: TranscriptGroupCell()
        case .approval: TranscriptApprovalCell()
        case .question: TranscriptQuestionCell()
        case .plan: TranscriptPlanCell()
        case .error: TranscriptErrorCell()
        case .notice: TranscriptNoticeCell()
        case .turnHeader: TranscriptTurnHeaderCell()
        case .changedFiles: TranscriptChangedFilesCell()
        case .live: TranscriptLiveCell()
        case .spacer: TranscriptSpacerCell()
        }
    }

    private func height(at index: Int, exact: Bool) -> CGFloat {
        let row = rows[index]
        let cached = heights[row.id]
        let sameContent = cached.map { $0.revision == row.revision && $0.continuesWork == row.continuesWork } ?? false
        if let cached, sameContent, cached.width == width, cached.isExact || !exact { return cached.value }
        guard let host else { return 1 }
        let type = cellType(for: row.kind)
        let isExact = exact || !type.measuresText
        let value: CGFloat
        if isExact {
            value = type.height(for: row, width: width, host: host)
        } else if let cached, sameContent {
            // Measured at another width; close enough until the row comes into view.
            value = cached.value
        } else {
            value = type.estimatedHeight(for: row, width: width, host: host)
        }
        let height = max(1, ceil(value))
        heights[row.id] = Height(revision: row.revision, continuesWork: row.continuesWork, width: width, value: height, isExact: isExact)
        return height
    }

    private func noteHeights(_ indexes: IndexSet) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
        NSAnimationContext.endGrouping()
    }

    private func scheduleRefine() {
        guard !refineScheduled else { return }
        refineScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refineScheduled = false
            self.refineVisibleHeights()
        }
    }

    /// Measures estimated rows that are on screen or about to be.
    private func refineVisibleHeights() {
        guard !rows.isEmpty else { return }
        let range = visibleRange(margin: 1)
        var changed = IndexSet()
        for index in range where index < rows.count {
            let row = rows[index]
            if let cached = heights[row.id], cached.isExact, cached.width == width, cached.revision == row.revision,
                cached.continuesWork == row.continuesWork
            {
                continue
            }
            let previous = heights[row.id]?.value
            if height(at: index, exact: true) != previous { changed.insert(index) }
        }
        guard !changed.isEmpty else { return }
        preservingAnchor { noteHeights(changed) }
        // Exact heights can pull more rows into view.
        scheduleRefine()
    }

    private func visibleRange(margin screens: CGFloat) -> Range<Int> {
        let visible = scrollView.contentView.documentVisibleRect
        let rect = visible.insetBy(dx: 0, dy: -visible.height * screens)
        let range = tableView.rows(in: rect)
        guard range.location != NSNotFound, range.length > 0 else { return 0..<0 }
        return range.location..<min(rows.count, NSMaxRange(range))
    }

    private static func tail(of count: Int) -> Range<Int> {
        max(0, count - 24)..<count
    }

    // MARK: Scrolling

    var distanceFromBottom: CGFloat {
        let clip = scrollView.contentView
        return tableView.frame.height + clip.contentInsets.bottom - clip.bounds.maxY
    }

    func scrollToBottom(animated: Bool = false) {
        isPinnedToBottom = true
        let clip = scrollView.contentView
        let target = max(-clip.contentInsets.top, tableView.frame.height + clip.contentInsets.bottom - clip.bounds.height)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            scroll(toY: target)
            return
        }
        isAnimatingScroll = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAnimatingScroll = false
                self.scrollView.reflectScrolledClipView(clip)
                if self.isPinnedToBottom { self.scrollToBottom() }
            }
        }
    }

    func scrollState() -> TranscriptScrollState {
        if isPinnedToBottom { return .bottom }
        let visible = scrollView.contentView.bounds
        let index = tableView.row(at: NSPoint(x: visible.midX, y: max(0, visible.minY) + 1))
        guard index >= 0, index < rows.count else { return .bottom }
        return .anchor(rows[index].id, offset: tableView.rect(ofRow: index).minY - visible.minY)
    }

    func restore(_ state: TranscriptScrollState?) {
        guard case .anchor(let id, let offset) = state, let index = index(of: id) else {
            scrollToBottom()
            return
        }
        isPinnedToBottom = false
        scroll(toY: tableView.rect(ofRow: index).minY - offset)
        isPinnedToBottom = distanceFromBottom <= Self.followThreshold
        scheduleRefine()
    }

    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let minY = -clip.contentInsets.top
        let maxY = max(minY, tableView.frame.height + clip.contentInsets.bottom - clip.bounds.height)
        let target = min(max(y, minY), maxY).rounded()
        guard abs(clip.bounds.origin.y - target) > 0.25 else { return }
        isAdjustingScroll = true
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        isAdjustingScroll = false
    }

    /// Applies changes while a row stays put on screen: `explicit` if given, otherwise the row at the
    /// top of the viewport, or the bottom when following.
    private func preservingAnchor(_ explicit: TranscriptRowID? = nil, _ changes: () -> Void) {
        let explicitIndex = explicit.flatMap { index(of: $0) }
        if explicitIndex == nil, isPinnedToBottom || isAnimatingScroll {
            changes()
            if isPinnedToBottom && !isAnimatingScroll { scrollToBottom() }
            return
        }
        let visible = scrollView.contentView.bounds
        let anchor = explicitIndex ?? tableView.row(at: NSPoint(x: visible.midX, y: max(0, visible.minY) + 1))
        guard anchor >= 0, anchor < rows.count else {
            changes()
            return
        }
        let id = rows[anchor].id
        let offset = tableView.rect(ofRow: anchor).minY - visible.minY
        changes()
        guard let index = index(of: id) else { return }
        scroll(toY: tableView.rect(ofRow: index).minY - offset)
        if explicitIndex != nil { isPinnedToBottom = distanceFromBottom <= Self.followThreshold }
    }

    @objc private func clipBoundsChanged(_ notification: Notification) {
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let layout = [clip.bounds.width, clip.bounds.height, insets.top, insets.bottom]
        if layout != lastClipLayout {
            lastClipLayout = layout
            if isPinnedToBottom && !isAdjustingScroll && !isAnimatingScroll { scrollToBottom() }
        }
        scheduleRefine()
    }

    /// Only the reader's own scrolling (wheel, trackpad, scroller, keyboard) starts or stops following.
    /// Any scroll up leaves the bottom at once, so streaming output never pulls the reader back down;
    /// scrolling back to within reach of the bottom follows again.
    private func readerScrolled(upward: Bool = false) {
        guard !isAdjustingScroll, !isAnimatingScroll else { return }
        isPinnedToBottom = distanceFromBottom <= (upward ? 1 : Self.followThreshold)
    }

    /// Keyboard scrolling animates, so check again once it has settled.
    private func readerScrolledAndSettled() {
        readerScrolled()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.readerScrolled() }
    }

    @objc private func tableFrameChanged(_ notification: Notification) {
        // The table posts this while it tiles; respond once it is done.
        guard !frameChangeScheduled else { return }
        frameChangeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameChangeScheduled = false
            self.applyFrameChange()
        }
    }

    private func applyFrameChange() {
        let newWidth = tableView.bounds.width
        if abs(newWidth - width) > 0.5 {
            width = newWidth
            guard !rows.isEmpty else { return }
            exactRange = visibleRange(margin: 0)
            preservingAnchor { noteHeights(IndexSet(integersIn: 0..<rows.count)) }
            scheduleRefine()
        } else if isPinnedToBottom && !isAdjustingScroll && !isAnimatingScroll {
            scrollToBottom()
        }
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if width == 0 { width = tableView.bounds.width }
        return height(at: row, exact: exactRange.contains(row))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let host, row < rows.count else { return nil }
        let item = rows[row]
        let identifier = NSUserInterfaceItemIdentifier(String(describing: cellType(for: item.kind)))
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? TranscriptCell) ?? {
            let cell = makeCell(for: item.kind)
            cell.identifier = identifier
            return cell
        }()
        cell.configure(item, host: host)
        cell.isRowSelected = tableView.selectedRowIndexes.contains(row)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("TranscriptRowView")
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? TranscriptRowView { return view }
        let view = TranscriptRowView()
        view.identifier = identifier
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row].kind {
        case .live, .spacer: false
        default: true
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = tableView.selectedRowIndexes
        tableView.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? TranscriptCell)?.isRowSelected = selected.contains(row)
        }
    }
}

private extension Range where Bound == Int {
    func union(_ other: Range<Int>) -> Range<Int> {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return Swift.min(lowerBound, other.lowerBound)..<Swift.max(upperBound, other.upperBound)
    }
}

// MARK: - Table

/// The transcript table: keyboard navigation over rows (arrows move, Space or Return opens and
/// closes, ⌘C copies, Escape returns to the composer) and typing goes to the composer.
final class TranscriptTableView: NSTableView {
    var onToggleRow: ((Int, _ expand: Bool?) -> Void)?
    var onCopyRow: ((Int) -> Void)?
    var onEscape: (() -> Void)?
    var onTypeAhead: ((NSEvent) -> Void)?
    var onReaderScroll: (() -> Void)?

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        handleKey(event)
        onReaderScroll?()
    }

    private func handleKey(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 49, 36, 76:
            if selectedRow >= 0 {
                onToggleRow?(selectedRow, nil)
                return
            }
        case 123 where modifiers.isEmpty:
            if selectedRow >= 0 {
                onToggleRow?(selectedRow, false)
                return
            }
        case 124 where modifiers.isEmpty:
            if selectedRow >= 0 {
                onToggleRow?(selectedRow, true)
                return
            }
        case 53:
            onEscape?()
            return
        default:
            if modifiers.subtracting(.shift).isEmpty, let characters = event.characters, !characters.isEmpty,
                characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            {
                onTypeAhead?(event)
                return
            }
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard selectedRow >= 0 else { return }
        onCopyRow?(selectedRow)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
}

/// Reports the reader's scrolling, which decides whether the transcript follows new output.
final class TranscriptScrollView: NSScrollView {
    /// Called after each wheel or trackpad scroll; the argument is true when scrolling toward older content.
    var onReaderScroll: ((_ upward: Bool) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onReaderScroll?(event.scrollingDeltaY > 0)
    }
}

/// Draws keyboard selection as a soft rounded highlight around the transcript column.
final class TranscriptRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        guard isEmphasized else { return }
        let column = TranscriptMetrics.column(width: bounds.width)
        let rect = NSRect(x: column.x - 8, y: 0, width: column.width + 16, height: bounds.height).insetBy(dx: 0, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
