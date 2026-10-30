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
    /// Where the reader was when the transcript's width started to change (a panel opening beside the chat, a divider
    /// drag, a window resize), kept until `applyFrameChange` lays the rows out at the new width. Taken before the
    /// scroll view resizes, since the clip view can shift by a few points while it does.
    private var placeBeforeResize: (id: TranscriptRowID, offset: CGFloat)?

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
        // The conversation starts below the title bar rather than scrolling under it: the title bar is transparent, so
        // text scrolled beneath would run into the thread's title.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onReaderScroll = { [weak self] upward in self?.readerScrolled(upward: upward) }
        scrollView.onWidthWillChange = { [weak self] in self?.noteWidthWillChange() }
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
    /// stays where it is on screen, as when the reader expands it. A reload keeps the row the reader is scrolled to
    /// in place, as when a setting lays every row out again.
    func update(_ newRows: [TranscriptRow], reload: Bool = false, keeping anchor: TranscriptRowID? = nil) {
        if reload || rows.isEmpty || newRows.isEmpty {
            let place = scrollState()
            let around = visibleRange(margin: 1)
            var anchorID: TranscriptRowID?
            if case .anchor(let id, _) = place { anchorID = id }
            let oldIndex = anchorID.flatMap { index(of: $0) }
            rows = newRows
            // Scrolled up to a row that stays, the rows around the reader (wherever the new rows put them) are measured
            // exactly from the start, so they don't change height under them once measured.
            if let anchorID, let oldIndex, let newIndex = index(of: anchorID) {
                let shift = newIndex - oldIndex
                let lower = max(0, min(around.lowerBound + shift, newRows.count))
                exactRange = lower..<max(lower, min(around.upperBound + shift, newRows.count))
            } else {
                exactRange = Self.tail(of: newRows.count)
            }
            tableView.reloadData()
            learnHeights(of: rows.indices)
            tableView.tile()
            keep(place)
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
                // Below a long reply that came in above the view (as when a finished turn lays out its reply again), rows
                // placed by a guessed height would draw over the reply (see `learnHeights`).
                learnHeights(of: inserted)
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

    /// Has the cells shown pick up their rails again, after rows came or went around them.
    func refreshRails() {
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? TranscriptCell)?.refreshRail()
        }
    }

    /// Reconfigures the rows on screen, for state rows do not encode (such as whether a turn runs).
    func reconfigureVisibleCells() {
        guard let host else { return }
        let range = visibleRange(margin: 0)
        for index in range where index < rows.count {
            (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TranscriptCell)?.configure(rows[index], host: host)
        }
    }

    /// Reconfigures every row the table has prepared, on screen or just off it, for find highlights.
    func reconfigurePreparedCells() {
        guard let host else { return }
        tableView.enumerateAvailableRowViews { rowView, index in
            guard index < rows.count, let cell = rowView.view(atColumn: 0) as? TranscriptCell else { return }
            cell.configure(rows[index], host: host)
        }
    }

    /// Forgets every measurement without reloading, for when another thread loads: row revisions start
    /// over then, so a height measured on an earlier visit could pass for one of content changed since.
    func forgetHeights() {
        heights.removeAll()
    }

    /// Forgets every measurement, for font size changes and the other settings that lay rows out anew. The row the
    /// reader is scrolled to stays in place, though the rows above it change height.
    func invalidateHeights() {
        let place = scrollState()
        heights.removeAll()
        exactRange = visibleRange(margin: 1)
        tableView.reloadData()
        learnHeights(of: rows.indices)
        keep(place)
        scheduleRefine()
    }

    /// Puts the row the reader was scrolled to back where it was on screen, if it is still there.
    private func keep(_ place: TranscriptScrollState) {
        guard case .anchor(let id, let offset) = place, !isPinnedToBottom, let index = index(of: id) else { return }
        scroll(toY: tableView.rect(ofRow: index).minY - offset)
    }

    func refreshLiveState() {
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? TranscriptCell)?.refreshLiveState()
        }
    }

    func index(of id: TranscriptRowID) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    /// The item of the first row the reader can see below the toolbar, for searches that start where they are.
    func firstVisibleItemID() -> UUID? {
        let clip = scrollView.contentView
        let top = clip.bounds.minY + clip.contentInsets.top
        let visible = NSRect(x: 0, y: top, width: tableView.bounds.width, height: max(1, clip.bounds.maxY - top))
        let range = tableView.rows(in: visible)
        guard range.location != NSNotFound else { return nil }
        for index in range.location..<min(rows.count, NSMaxRange(range)) {
            switch rows[index].id {
            case .item(let id), .turnHeader(let id), .group(let id), .changedFiles(let id): return id
            case .fork, .live, .header, .footer: continue
            }
        }
        return nil
    }

    /// The cell showing a row, once the row is on screen.
    func cell(at index: Int) -> TranscriptCell? {
        guard index < rows.count else { return nil }
        return tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? TranscriptCell
    }

    // MARK: Heights

    /// The cell class that draws rows of a kind.
    static func cellType(for kind: TranscriptRow.Kind) -> TranscriptCell.Type {
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
        case .fork: TranscriptForkCell.self
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
        case .fork: TranscriptForkCell()
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
        let type = Self.cellType(for: row.kind)
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

    /// Has the table ask for the heights of `indexes` now. The table asks for a row's height only once it needs it: rows
    /// it inserts, and every row of a long transcript it loads or reloads at once (a thread restored at launch, another
    /// thread opened). Until then it places the rows after them by a guessed height, and it does not move them again
    /// when it learns the real one, so rows would draw over one another, scrolling or not, and the bottom would land
    /// short of the last row. Asking before it places them puts every row where it belongs.
    private func learnHeights(of indexes: some Sequence<Int>) {
        for index in indexes { _ = tableView.rect(ofRow: index) }
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

    /// Scrolls a row to the middle of the visible area, or with `rect` (in the row's coordinates) that part
    /// of it, as find does for its current match. The rows around it are measured first, so it lands where
    /// it is drawn. Leaving the bottom stops following new output, as scrolling there yourself would.
    func reveal(row index: Int, rect: NSRect? = nil) {
        guard index < rows.count else { return }
        measureExactly(around: index)
        let clip = scrollView.contentView
        let rowRect = tableView.rect(ofRow: index)
        let target = rect.map { $0.offsetBy(dx: rowRect.minX, dy: rowRect.minY) } ?? rowRect
        let top = clip.contentInsets.top
        let visibleHeight = max(1, clip.bounds.height - top - clip.contentInsets.bottom)
        // Something taller than most of the view starts near its top instead.
        let y = target.height > visibleHeight * 0.7 ? target.minY - top - 24 : target.midY - top - visibleHeight / 2
        scroll(toY: y)
        isPinnedToBottom = distanceFromBottom <= Self.followThreshold
        scheduleRefine()
    }

    /// Measures the rows within about a screen of `index` exactly, so scrolling there lands right.
    private func measureExactly(around index: Int) {
        let screen = max(200, scrollView.contentView.bounds.height)
        var changed = IndexSet()
        func measure(_ row: Int) -> CGFloat {
            let previous = heights[rows[row].id]?.value
            let value = height(at: row, exact: true)
            if value != previous { changed.insert(row) }
            return value
        }
        _ = measure(index)
        var lower = index
        var above: CGFloat = 0
        while lower > 0, above < screen {
            lower -= 1
            above += measure(lower)
        }
        var upper = index
        var below: CGFloat = 0
        while upper < rows.count - 1, below < screen {
            upper += 1
            below += measure(upper)
        }
        exactRange = lower..<(upper + 1)
        if !changed.isEmpty { noteHeights(changed) }
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

    private func noteWidthWillChange() {
        guard placeBeforeResize == nil, !isPinnedToBottom, !isAnimatingScroll, case .anchor(let id, let offset) = scrollState()
        else { return }
        placeBeforeResize = (id, offset)
    }

    private func applyFrameChange() {
        let newWidth = tableView.bounds.width
        let place = placeBeforeResize
        placeBeforeResize = nil
        if abs(newWidth - width) > 0.5 {
            width = newWidth
            guard !rows.isEmpty else { return }
            exactRange = visibleRange(margin: 0)
            if let place, !isPinnedToBottom, let index = index(of: place.id) {
                noteHeights(IndexSet(integersIn: 0..<rows.count))
                scroll(toY: tableView.rect(ofRow: index).minY - place.offset)
            } else {
                preservingAnchor { noteHeights(IndexSet(integersIn: 0..<rows.count)) }
            }
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
        let identifier = NSUserInterfaceItemIdentifier(String(describing: Self.cellType(for: item.kind)))
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
    override func menu(for event: NSEvent) -> NSMenu? {
        ThemedContextMenu.show(super.menu(for: event), for: event, in: window)
    }

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
    /// Called before the scroll view takes a new width, while what the reader sees is still in place.
    var onWidthWillChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        if abs(newSize.width - frame.width) > 0.5 { onWidthWillChange?() }
        super.setFrameSize(newSize)
    }

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
        Theme.sidebarSelection.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
