import AppKit
import CoincideKit
import QuartzCore

/// What transcript cells need from the chat: data, cached text, and actions.
@MainActor
protocol TranscriptHost: AnyObject {
    var threadID: UUID? { get }
    var isThreadRunning: Bool { get }
    var textCache: TranscriptTextCache { get }

    func item(_ id: UUID) -> TranscriptItem?
    func isExpanded(_ id: TranscriptRowID) -> Bool
    func toggle(_ id: TranscriptRowID)
    func copyToPasteboard(_ text: String)
    /// T3's "Edit from here": rewinds the conversation to before a message of the user's and hands the
    /// message back to the composer, optionally restoring files too.
    func rewindTurn(_ itemID: UUID)
    /// T3's "Fork from this response": a new thread with the conversation through the turn holding the item.
    func forkTurn(_ itemID: UUID)
    func canFork(_ itemID: UUID) -> Bool
    func openThread(_ threadID: UUID)
    func showDiff(turnID: UUID, path: String?)
    func openLink(_ link: Any) -> Bool
    func previewAttachments(_ paths: [String], selected: Int)
    /// Attaches text selected in an agent's reply or plan, or in a message of the user's, to the composer's message,
    /// as a quote (Reply).
    func quote(_ text: String, from itemID: UUID)
    /// Shows the whole of context attached to a message of the user's, beside its pill.
    func openContext(_ context: MessageContext, from anchor: NSView)
    func changedFiles(for turnID: UUID) -> [ChangedFile]
    func modelLabel(for meta: AssistantMeta) -> String
    /// The model's display name, or nil when the agent's default model answered.
    func modelName(for meta: AssistantMeta) -> String?
    /// The row's piece of the agent rail, if the rail runs through it.
    func rail(for id: TranscriptRowID) -> TranscriptRail?
    /// The find bar's matches in an item, while the find bar shows some.
    func findHighlights(for itemID: UUID) -> TranscriptFindHighlights?
    /// The transcript item of a provider's tool call, such as the one that started a background task.
    func toolCallItem(_ toolCallID: String, provider: ProviderKind) -> UUID?
    /// Scrolls to an item, opening whatever folds it away.
    func reveal(_ itemID: UUID)
}

extension TranscriptHost {
    func toolCallItem(_ toolCallID: String, provider: ProviderKind) -> UUID? { nil }
    func reveal(_ itemID: UUID) {}
}

/// Shared transcript geometry. Everything lays out in a centered column, with the agent rail in a gutter on its left.
enum TranscriptMetrics {
    static let edgePadding: CGFloat = 16
    static let messageSpacing: CGFloat = 18
    static let workRowHeight: CGFloat = 26
    static let workSpacing: CGFloat = 10
    static let detailIndent: CGFloat = 26
    static let nestedIndent: CGFloat = 24
    static let detailMaxHeight: CGFloat = 320

    /// Where rows lay out their content: the centered column, less the rail's gutter.
    static func column(width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let frame = self.frame(width: width)
        return (frame.x + Theme.railGutter, frame.width - Theme.railGutter)
    }

    /// The centered column with the rail's gutter, which the composer lines up with.
    static func frame(width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let available = max(120 + Theme.railGutter, width - Theme.horizontalPadding * 2)
        let columnWidth = min(Theme.contentMaxWidth, available)
        return (((width - columnWidth) / 2).rounded(.down), columnWidth)
    }

    /// The center of the rail.
    static func railX(width: CGFloat) -> CGFloat {
        frame(width: width).x + 10
    }
}

/// Base class for transcript rows. Cells are flipped and lay out by hand; each kind reports
/// its exact height for a width (and, when measuring is expensive, a cheap estimate).
class TranscriptCell: NSTableCellView {
    weak var host: TranscriptHost?
    private(set) var row: TranscriptRow?
    private let railView = TranscriptRailView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // First, so it stays behind the row's content.
        addSubview(railView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ row: TranscriptRow, host: TranscriptHost) {
        self.row = row
        self.host = host
        railView.rail = host.rail(for: row.id)
        needsLayout = true
    }

    /// Picks up the row's rail again, after rows around it came or went.
    func refreshRail() {
        guard let row, let host else { return }
        railView.rail = host.rail(for: row.id)
    }

    /// Where the rail's node for this row sits, from the row's top: the middle of its first line.
    var railNodeY: CGFloat { 10 }

    override func layout() {
        super.layout()
        railView.frame = NSRect(x: TranscriptMetrics.railX(width: bounds.width) - 12, y: 0, width: 24, height: bounds.height)
        railView.nodeY = railNodeY
    }

    class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat { 0 }

    class func estimatedHeight(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        height(for: row, width: width, host: host)
    }

    /// Whether measuring needs text layout; cheap rows are always measured exactly.
    class var measuresText: Bool { false }

    /// Refreshes timers and live labels without reconfiguring.
    func refreshLiveState() {}

    /// What ⌘C copies when the row is selected.
    var copyText: String? { nil }

    /// The find bar's matches in this row's item.
    var findHighlights: TranscriptFindHighlights {
        guard let id = row?.itemID else { return TranscriptFindHighlights() }
        return host?.findHighlights(for: id) ?? TranscriptFindHighlights()
    }

    /// Where the row shows a find match, after scrolling any panel inside it to the match. Rows lay out
    /// before they are asked.
    func findTarget(for match: TranscriptFindMatch) -> TranscriptFindTarget? { nil }

    /// The target for a match drawn by `textView`, a descendant of the cell.
    func findTarget(_ range: NSRange, in textView: ChatTextView, panel: TranscriptDetailPanel? = nil) -> TranscriptFindTarget? {
        guard let rect = textView.rect(for: range) else { return nil }
        panel?.reveal(rect)
        return TranscriptFindTarget(rect: convert(rect, from: textView), textView: textView, range: range)
    }

    /// Toggled by the table's row selection, for rows that reveal actions on hover.
    var isRowSelected = false {
        didSet { if isRowSelected != oldValue { selectionChanged() } }
    }

    func selectionChanged() {}

    static func bottomSpacing(for row: TranscriptRow) -> CGFloat {
        row.isWorkLog && row.continuesWork ? 0 : row.isWorkLog ? TranscriptMetrics.workSpacing : TranscriptMetrics.messageSpacing
    }
}

/// The user's message card. Lays out top-down like the cells; its color follows the appearance.
final class TranscriptBubbleView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.userBubble.cgColor
    }
}

/// Rendered text and measured sizes, cached per item until its text changes. Text that keeps
/// changing (a streaming reply, growing tool output) re-renders and re-measures only its changed blocks.
@MainActor
final class TranscriptTextCache {
    enum Style: Hashable {
        case assistant, user, reasoning, plan, approval, error, toolDetail
    }

    private struct Key: Hashable {
        var id: UUID
        var style: Style
    }

    private struct Entry {
        var source: String
        var text: ChatRenderedText
        var sizes: [CGFloat: NSSize] = [:]
        let blocks: ChatRenderCache
        /// Set once the text has changed after its first render.
        var liveMeasurer: ChatLiveMeasurer?
    }

    /// Changing texts measured with their own layout; older ones fall back to the shared measurer.
    private static let liveMeasurerLimit = 4

    private var entries: [Key: Entry] = [:]
    private var liveKeys: [Key] = []

    /// The rendered text for an item. `source` identifies the content; `render` runs when it changed
    /// and receives the block cache of the previous rendering.
    func text(for id: UUID, style: Style, source: String, render: (ChatRenderCache) -> ChatRenderedText) -> ChatRenderedText {
        let key = Key(id: id, style: style)
        if let entry = entries[key], entry.source == source { return entry.text }
        guard var entry = entries[key] else {
            let blocks = ChatRenderCache()
            let entry = Entry(source: source, text: render(blocks), blocks: blocks)
            entries[key] = entry
            return entry.text
        }
        entry.text = render(entry.blocks)
        entry.source = source
        entry.sizes.removeAll()
        if entry.liveMeasurer == nil {
            entry.liveMeasurer = ChatLiveMeasurer()
            liveKeys.append(key)
            if liveKeys.count > Self.liveMeasurerLimit { entries[liveKeys.removeFirst()]?.liveMeasurer = nil }
        }
        entries[key] = entry
        return entry.text
    }

    func size(for id: UUID, style: Style, source: String, width: CGFloat, render: (ChatRenderCache) -> ChatRenderedText) -> NSSize {
        let key = Key(id: id, style: style)
        let text = self.text(for: id, style: style, source: source, render: render)
        if let size = entries[key]?.sizes[width] { return size }
        let size = entries[key]?.liveMeasurer?.size(of: text, width: width) ?? ChatTextMeasurer.shared.size(of: text.string, width: width)
        if entries[key]?.sizes.count ?? 0 > 6 { entries[key]?.sizes.removeAll() }
        entries[key]?.sizes[width] = size
        return size
    }

    func removeAll() {
        entries.removeAll()
        liveKeys.removeAll()
    }

    /// Drops entries for items that are no longer in the given set.
    func retain(only ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key.id) }
        liveKeys.removeAll { entries[$0] == nil }
    }
}

// MARK: - Markdown for items

@MainActor
enum TranscriptText {
    static func style(_ style: TranscriptTextCache.Style) -> ChatMarkdownStyle {
        var markdownStyle = baseStyle(style)
        markdownStyle.webLinkHint = LinkRouting.hint(opensInDefaultBrowser: LinkRouting.opensInDefaultBrowser)
        return markdownStyle
    }

    private static func baseStyle(_ style: TranscriptTextCache.Style) -> ChatMarkdownStyle {
        switch style {
        case .assistant: ChatMarkdownStyle(fontSize: Theme.replyFontSize, textColor: Theme.ink, isSerif: Theme.usesSerifReplies)
        case .approval, .error, .toolDetail: ChatMarkdownStyle(fontSize: Theme.fontSize)
        case .user: ChatMarkdownStyle(fontSize: Theme.fontSize, textColor: Theme.ink, preservesLineBreaks: true)
        case .reasoning: ChatMarkdownStyle(fontSize: Theme.fontSize - 1, textColor: .secondaryLabelColor)
        case .plan: ChatMarkdownStyle(fontSize: Theme.fontSize, textColor: Theme.ink, dimsCompletedTasks: true)
        }
    }

    static func markdown(_ item: TranscriptItem, _ style: TranscriptTextCache.Style, cache: TranscriptTextCache) -> ChatRenderedText {
        cache.text(for: item.id, style: style, source: item.text) { blocks in
            ChatMarkdownRenderer.render(item.text, style: self.style(style), cache: blocks)
        }
    }

    static func markdownSize(_ item: TranscriptItem, _ style: TranscriptTextCache.Style, width: CGFloat, cache: TranscriptTextCache) -> NSSize {
        cache.size(for: item.id, style: style, source: item.text, width: width) { blocks in
            ChatMarkdownRenderer.render(item.text, style: self.style(style), cache: blocks)
        }
    }

    /// A one-line label from inline Markdown, with code spans in monospace.
    static func inlineLabel(_ markdown: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func append(_ inlines: [ChatMarkdown.Inline], bold: Bool) {
            for inline in inlines {
                switch inline {
                case .text(let text):
                    result.append(NSAttributedString(string: text, attributes: [.font: bold ? ChatFonts.body(font.pointSize, weight: .semibold) : font, .foregroundColor: color]))
                case .code(let code):
                    result.append(NSAttributedString(string: code, attributes: [.font: ChatFonts.mono(font.pointSize - 1), .foregroundColor: color]))
                case .emphasis(let children), .strikethrough(let children), .link(_, let children):
                    append(children, bold: bold)
                case .strong(let children):
                    append(children, bold: true)
                case .image(let alt, _):
                    result.append(NSAttributedString(string: alt, attributes: [.font: font, .foregroundColor: color]))
                case .softBreak, .lineBreak:
                    result.append(NSAttributedString(string: " ", attributes: [.font: font]))
                }
            }
        }
        let firstLine = markdown.split(whereSeparator: \.isNewline).first.map(String.init) ?? markdown
        for block in ChatMarkdown.parse(firstLine) {
            switch block {
            case .paragraph(let inlines), .heading(_, let inlines): append(inlines, bold: false)
            default: result.append(NSAttributedString(string: firstLine, attributes: [.font: font, .foregroundColor: color]))
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }
}

// MARK: - Controls

/// Small borderless symbol button used for row actions (copy, edit, revert, view diff).
final class TranscriptIconButton: NSButton {
    private var restoreTask: Task<Void, Never>?
    private var symbolName = ""

    convenience init(symbol: String, label: String, action: Selector?, target: AnyObject?) {
        self.init(frame: NSRect(x: 0, y: 0, width: 22, height: 20))
        isBordered = false
        bezelStyle = .accessoryBarAction
        imagePosition = .imageOnly
        setSymbol(symbol)
        toolTip = label
        setAccessibilityLabel(label)
        contentTintColor = .secondaryLabelColor
        self.action = action
        self.target = target
    }

    func setSymbol(_ name: String) {
        guard name != symbolName else { return }
        symbolName = name
        image = Theme.symbol(name, size: 11, weight: .medium)
    }

    /// Shows a checkmark briefly after a successful copy.
    func flashConfirmation() {
        let original = symbolName
        setSymbol("checkmark")
        contentTintColor = Theme.success
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            self.setSymbol(original)
            self.contentTintColor = .secondaryLabelColor
        }
    }
}

/// The clickable header of a work-log row: symbol, label, status and disclosure chevron.
final class TranscriptDisclosureHeader: NSView {
    enum Status: Equatable {
        case none, running, completed, failed, declined, waiting
    }

    var onToggle: (() -> Void)?

    private let iconView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let chevron = NSImageView()
    private var isHovered = false
    private var isExpandable = false
    private var isExpanded = false
    private var status: Status = .none
    private var isShimmering = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        iconView.imageScaling = .scaleProportionallyDown
        labelField.lineBreakMode = .byTruncatingTail
        labelField.cell?.truncatesLastVisibleLine = true
        labelField.maximumNumberOfLines = 1
        labelField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.maximumNumberOfLines = 1
        detailField.textColor = .tertiaryLabelColor
        detailField.alignment = .right
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        chevron.imageScaling = .scaleProportionallyDown
        for view in [iconView, labelField, detailField, statusIcon, spinner, chevron] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        symbol: String, symbolColor: NSColor = .secondaryLabelColor, title: NSAttributedString, detail: String? = nil,
        status: Status, isExpandable: Bool, isExpanded: Bool, shimmer: Bool = false
    ) {
        iconView.image = Theme.symbol(symbol, size: 12, weight: .medium)
        iconView.contentTintColor = symbolColor
        labelField.attributedStringValue = title
        detailField.stringValue = detail ?? ""
        detailField.font = .monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .regular)
        detailField.isHidden = (detail ?? "").isEmpty
        self.status = status
        self.isExpandable = isExpandable
        self.isExpanded = isExpanded
        switch status {
        case .running:
            statusIcon.isHidden = true
            spinner.startAnimation(nil)
        case .none:
            statusIcon.isHidden = true
            spinner.stopAnimation(nil)
        case .completed, .failed, .declined, .waiting:
            spinner.stopAnimation(nil)
            statusIcon.isHidden = false
            let (name, color): (String, NSColor) =
                switch status {
                case .completed: ("checkmark", .tertiaryLabelColor)
                case .failed: ("xmark", Theme.failure)
                case .declined: ("nosign", Theme.warning)
                default: ("hourglass", Theme.warning)
                }
            statusIcon.image = Theme.symbol(name, size: 10, weight: .semibold)
            statusIcon.contentTintColor = color
        }
        chevron.isHidden = !isExpandable
        chevron.image = Theme.symbol(isExpanded ? "chevron.down" : "chevron.right", size: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        isShimmering = shimmer
        TranscriptShimmer.set(shimmer, on: labelField)
        setAccessibilityLabel(accessibilityDescription(title: title.string))
        if isExpandable { setAccessibilityValue(isExpanded ? 1 : 0) }
        setAccessibilityRole(isExpandable ? .disclosureTriangle : .staticText)
        needsLayout = true
        needsDisplay = true
    }

    /// Where the title is drawn, in the header's coordinates.
    var titleFrame: NSRect {
        layoutSubtreeIfNeeded()
        return labelField.frame
    }

    private func accessibilityDescription(title: String) -> String {
        switch status {
        case .running: String(localized: "\(title), running")
        case .failed: String(localized: "\(title), failed")
        case .declined: String(localized: "\(title), declined")
        case .waiting: String(localized: "\(title), waiting")
        default: title
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        iconView.frame = NSRect(x: 2, y: (height - 16) / 2, width: 16, height: 16)
        var trailing = bounds.width - 2
        if !chevron.isHidden {
            chevron.frame = NSRect(x: trailing - 12, y: (height - 12) / 2, width: 12, height: 12)
            trailing -= 18
        }
        if status == .running {
            spinner.frame = NSRect(x: trailing - 14, y: (height - 14) / 2, width: 14, height: 14)
            trailing -= 20
        } else if !statusIcon.isHidden {
            statusIcon.frame = NSRect(x: trailing - 12, y: (height - 12) / 2, width: 12, height: 12)
            trailing -= 18
        }
        if !detailField.isHidden {
            let width = min(140, ceil(detailField.cell?.cellSize.width ?? 0))
            detailField.frame = NSRect(x: trailing - width, y: (height - 16) / 2, width: width, height: 16)
            trailing -= width + 6
        }
        let labelHeight = ceil(labelField.intrinsicContentSize.height)
        let labelX: CGFloat = 26
        // The cell's size includes its text padding, which a short title like "Thought" needs to not truncate.
        let labelWidth = min(max(0, trailing - labelX), ceil(labelField.cell?.cellSize.width ?? labelField.intrinsicContentSize.width))
        labelField.frame = NSRect(x: labelX, y: ((height - labelHeight) / 2).rounded(), width: max(0, labelWidth), height: labelHeight)
        if isShimmering { TranscriptShimmer.layout(labelField) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isExpandable, isHovered else { return }
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        labelField.textColor = isExpandable ? .labelColor : .secondaryLabelColor
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        labelField.textColor = .secondaryLabelColor
        needsDisplay = true
    }

    override func resetCursorRects() {
        if isExpandable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isExpandable else { return super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard isExpandable, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isExpandable else { return false }
        onToggle?()
        return true
    }
}

/// A scroll view for content inside a transcript row. When it cannot scroll further (or has nothing
/// to scroll) the gesture goes to the transcript, so reading down a thread never gets stuck.
final class TranscriptNestedScrollView: NSScrollView {
    private var forwardsGesture = false

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began || (event.phase == [] && event.momentumPhase == []) {
            forwardsGesture = !canScroll(by: event)
        }
        if forwardsGesture, let outer = enclosingScrollView {
            outer.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func canScroll(by event: NSEvent) -> Bool {
        guard let document = documentView else { return false }
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { return document.frame.width > contentView.bounds.width + 1 }
        let maxY = document.frame.height - contentView.bounds.height
        guard maxY > 1 else { return false }
        let y = contentView.bounds.origin.y
        return event.scrollingDeltaY > 0 ? y > 0.5 : y < maxY - 0.5
    }
}

/// A rounded panel showing long text (tool output, reasoning) with its own scroller past a height.
final class TranscriptDetailPanel: NSView {
    static let padding: CGFloat = 10

    let textView = ChatTextView()
    private let scrollView = TranscriptNestedScrollView()
    var drawsBackground = true {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = textView
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Height for text of the given height, capped so long output scrolls inside the panel.
    static func height(forTextHeight textHeight: CGFloat, maxHeight: CGFloat = TranscriptMetrics.detailMaxHeight, padded: Bool = true) -> CGFloat {
        let padding = padded ? padding * 2 : 0
        return min(maxHeight, ceil(textHeight) + padding)
    }

    func setText(_ text: NSAttributedString, textHeight: CGFloat) {
        textView.setText(text)
        sizeText(height: textHeight)
    }

    /// Rendered Markdown updates only the blocks that changed, as reasoning streams in.
    func setText(_ rendered: ChatRenderedText, textHeight: CGFloat) {
        textView.setText(rendered)
        sizeText(height: textHeight)
    }

    private func sizeText(height: CGFloat) {
        let inset = drawsBackground ? Self.padding : 0
        let contentWidth = max(10, bounds.width - inset * 2)
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(height, 1))
        needsLayout = true
    }

    /// Scrolls the panel's own scroller so `rect` (in the text view's coordinates) is in view, in the
    /// middle when the panel scrolls at all. The transcript around it does not move.
    func reveal(_ rect: NSRect) {
        layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let visible = clip.bounds
        let maxY = max(0, textView.frame.height - visible.height)
        guard maxY > 0, rect.minY < visible.minY || rect.maxY > visible.maxY else { return }
        let y = min(max(0, rect.midY - visible.height / 2), maxY).rounded()
        clip.setBoundsOrigin(NSPoint(x: visible.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    override func layout() {
        super.layout()
        let inset = drawsBackground ? Self.padding : 0
        // Not insetBy: insetting an empty rect yields the null rect, whose origin is infinite.
        scrollView.frame = NSRect(x: inset, y: inset, width: max(0, bounds.width - inset * 2), height: max(0, bounds.height - inset * 2))
        if abs(textView.frame.width - scrollView.contentSize.width) > 0.5 {
            textView.frame.size.width = scrollView.contentSize.width
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard drawsBackground else { return }
        Theme.codeBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// A moving highlight across a label, for "Working…" and "Thinking…". Off when motion is reduced.
@MainActor
enum TranscriptShimmer {
    static func set(_ active: Bool, on view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let animate = active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animate {
            layer.mask = nil
            return
        }
        guard layer.mask == nil else { return }
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [NSColor(white: 0, alpha: 0.45).cgColor, NSColor.black.cgColor, NSColor(white: 0, alpha: 0.45).cgColor]
        gradient.locations = [0, 0.15, 0.3]
        gradient.frame = layer.bounds.insetBy(dx: -layer.bounds.width, dy: 0)
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [0, 0.15, 0.3]
        animation.toValue = [0.7, 0.85, 1]
        animation.duration = 1.6
        animation.repeatCount = .infinity
        gradient.add(animation, forKey: "shimmer")
        layer.mask = gradient
    }

    static func layout(_ view: NSView) {
        guard let layer = view.layer, let mask = layer.mask else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = layer.bounds.insetBy(dx: -layer.bounds.width, dy: 0)
        CATransaction.commit()
    }
}

// MARK: - Formatting

@MainActor
enum TranscriptFormat {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd jmm")
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter
    }()

    /// "3:42 PM" today, "Oct 21, 3:42 PM" otherwise.
    static func timestamp(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? timeFormatter.string(from: date) : dayTimeFormatter.string(from: date)
    }

    static func fullTimestamp(_ date: Date) -> String {
        fullFormatter.string(from: date)
    }
}
