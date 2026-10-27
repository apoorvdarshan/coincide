import AppKit
import CoincideKit

/// A rounded card filling the transcript column.
final class TranscriptCardView: NSView {
    var fillColor: NSColor = Theme.cardBackground {
        didSet { needsDisplay = true }
    }
    var strokeColor: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - Approval

/// An agent asking permission: what it wants to do and, once answered, the answer. As in T3 Code the
/// choices themselves are in the approval banner above the composer, so a waiting card only says so.
final class TranscriptApprovalCell: TranscriptCell {
    private static let padding: CGFloat = 12
    private static let detailMaxHeight: CGFloat = 160
    private static let statusHeight: CGFloat = 18

    private let card = TranscriptCardView()
    private let icon = NSImageView()
    private let kindLabel = NSTextField(labelWithString: "")
    private let titleView = ChatTextView()
    private let detailPanel = TranscriptDetailPanel()
    private let resolutionIcon = NSImageView()
    private let resolutionLabel = NSTextField(labelWithString: "")
    private var item: TranscriptItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(card)
        kindLabel.font = .systemFont(ofSize: Theme.fontSize - 2, weight: .semibold)
        resolutionLabel.lineBreakMode = .byTruncatingTail
        for view in [icon, kindLabel, titleView, detailPanel, resolutionIcon, resolutionLabel] as [NSView] {
            card.addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard let id = row.itemID, let item = host.item(id) else { return }
        self.item = item
        let isWaiting = item.status == .waiting
        let accent = isWaiting ? Theme.warning : NSColor.secondaryLabelColor
        card.strokeColor = isWaiting ? Theme.waitingStroke : .separatorColor
        icon.image = Theme.symbol((item.category ?? .other).symbolName, size: 11, weight: .semibold)
        icon.contentTintColor = accent
        kindLabel.stringValue = Self.kindLabel(item.category)
        kindLabel.textColor = accent
        titleView.setText(Self.title(item, cache: host.textCache).string)
        titleView.onOpenLink = { [weak host] link in host?.openLink(link) ?? false }
        let hasDetail = Self.detail(item) != nil
        detailPanel.isHidden = !hasDetail
        if hasDetail { detailPanel.setText(Self.detailText(item, cache: host.textCache).string, textHeight: 0) }
        let highlights = findHighlights
        titleView.setFindHighlights(highlights.ranges(in: .title), current: highlights.currentRange(in: .title))
        detailPanel.textView.setFindHighlights(highlights.ranges(in: .detail), current: highlights.currentRange(in: .detail))

        resolutionLabel.font = .systemFont(ofSize: Theme.fontSize - 1)
        resolutionLabel.textColor = .secondaryLabelColor
        if isWaiting {
            resolutionIcon.image = Theme.symbol("hourglass", size: 11, weight: .semibold)
            resolutionIcon.contentTintColor = Theme.warning
            resolutionLabel.stringValue = String(localized: "Waiting for your answer below")
            resolutionLabel.toolTip = nil
        } else {
            let declined = item.status == .declined
            resolutionIcon.image = Theme.symbol(declined ? "xmark.circle.fill" : "checkmark.circle.fill", size: 12, weight: .regular)
            resolutionIcon.contentTintColor = declined ? Theme.failure : Theme.success
            let resolution = item.approval?.resolution ?? (declined ? String(localized: "Declined") : String(localized: "Approved"))
            let reply = item.approval?.responseText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            resolutionLabel.stringValue = reply.isEmpty ? resolution : String(localized: "\(resolution): “\(reply)”")
            resolutionLabel.toolTip = reply.isEmpty ? nil : reply
        }
        setAccessibilityLabel("\(kindLabel.stringValue): \(item.title ?? ""), \(resolutionLabel.stringValue)")
    }

    override func findTarget(for match: TranscriptFindMatch) -> TranscriptFindTarget? {
        switch match.field {
        case .title: findTarget(match.range, in: titleView)
        case .detail where !detailPanel.isHidden: findTarget(match.range, in: detailPanel.textView, panel: detailPanel)
        default: nil
        }
    }

    static func kindLabel(_ category: ToolCategory?) -> String {
        switch category {
        case .command: String(localized: "Command approval")
        case .fileChange: String(localized: "File change approval")
        case .read: String(localized: "File read approval")
        case .web: String(localized: "Web access approval")
        case .mcp: String(localized: "Tool approval")
        default: String(localized: "Approval needed")
        }
    }

    static func title(_ item: TranscriptItem, cache: TranscriptTextCache) -> ChatRenderedText {
        let source = item.title ?? kindLabel(item.category)
        return cache.text(for: item.id, style: .approval, source: source) { blocks in
            ChatMarkdownRenderer.render(source, style: ChatMarkdownStyle(fontSize: Theme.fontSize), cache: blocks)
        }
    }

    static func detail(_ item: TranscriptItem) -> String? {
        let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty || detail == item.title ? nil : detail
    }

    /// The request rendered like a tool call's input; approvals carry no output.
    private static func request(_ item: TranscriptItem) -> TranscriptItem {
        var request = item
        request.text = ""
        return request
    }

    static func detailText(_ item: TranscriptItem, cache: TranscriptTextCache) -> ChatRenderedText {
        TranscriptToolDetail.text(for: request(item), cache: cache)
    }

    private static func detailSize(_ item: TranscriptItem, width: CGFloat, host: TranscriptHost) -> NSSize {
        let request = request(item)
        return host.textCache.size(for: item.id, style: .toolDetail, source: TranscriptToolDetail.source(request), width: width) { _ in
            TranscriptToolDetail.render(request)
        }
    }

    override class var measuresText: Bool { true }

    private struct Layout {
        var title: NSRect
        var detail: NSRect?
        var statusY: CGFloat
        var cardHeight: CGFloat
    }

    private static func layout(_ item: TranscriptItem, width: CGFloat, host: TranscriptHost) -> Layout {
        let column = TranscriptMetrics.column(width: width)
        let inner = column.width - padding * 2
        var y = padding + 18
        let titleSize = host.textCache.size(for: item.id, style: .approval, source: item.title ?? kindLabel(item.category), width: inner) { _ in
            title(item, cache: host.textCache)
        }
        let titleRect = NSRect(x: padding, y: y, width: inner, height: titleSize.height)
        y = titleRect.maxY
        var detailRect: NSRect?
        if detail(item) != nil {
            let size = detailSize(item, width: inner - TranscriptDetailPanel.padding * 2, host: host)
            let height = TranscriptDetailPanel.height(forTextHeight: size.height, maxHeight: detailMaxHeight)
            detailRect = NSRect(x: padding, y: y + 8, width: inner, height: height)
            y += 8 + height
        }
        let statusY = y + 10
        return Layout(title: titleRect, detail: detailRect, statusY: statusY, cardHeight: statusY + statusHeight + padding)
    }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        return layout(item, width: width, host: host).cardHeight + bottomSpacing(for: row)
    }

    override var copyText: String? {
        guard let item else { return nil }
        return [item.title, item.detail].compactMap { $0 }.joined(separator: "\n")
    }

    override func layout() {
        super.layout()
        guard let item, let host else { return }
        let column = TranscriptMetrics.column(width: bounds.width)
        let layout = Self.layout(item, width: bounds.width, host: host)
        card.frame = NSRect(x: column.x, y: 0, width: column.width, height: layout.cardHeight)
        icon.frame = NSRect(x: Self.padding, y: Self.padding, width: 14, height: 14)
        kindLabel.frame = NSRect(x: Self.padding + 20, y: Self.padding - 1, width: column.width - Self.padding * 2 - 20, height: 16)
        titleView.frame = layout.title
        if let detail = layout.detail {
            detailPanel.frame = detail
            let size = Self.detailSize(item, width: detail.width - TranscriptDetailPanel.padding * 2, host: host)
            detailPanel.setText(Self.detailText(item, cache: host.textCache).string, textHeight: size.height)
        }
        resolutionIcon.frame = NSRect(x: Self.padding, y: layout.statusY + 1, width: 16, height: 16)
        resolutionLabel.frame = NSRect(
            x: Self.padding + 22, y: layout.statusY, width: column.width - Self.padding * 2 - 22, height: Self.statusHeight)
    }
}

// MARK: - Plan

/// The agent's plan or todo list, with progress.
final class TranscriptPlanCell: TranscriptCell {
    private static let padding: CGFloat = 12

    private let card = TranscriptCardView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: String(localized: "Plan"))
    private let progressLabel = NSTextField(labelWithString: "")
    private let textView = ChatTextView()
    private var item: TranscriptItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(card)
        icon.image = Theme.symbol("checklist", size: 12, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor
        progressLabel.textColor = .secondaryLabelColor
        for view in [icon, titleLabel, progressLabel, textView] as [NSView] { card.addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard let id = row.itemID, let item = host.item(id) else { return }
        self.item = item
        titleLabel.font = .systemFont(ofSize: Theme.fontSize - 1, weight: .semibold)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .regular)
        let progress = Self.progress(item.text)
        progressLabel.stringValue = progress.total > 0 ? String(localized: "\(progress.done) of \(progress.total) done") : ""
        textView.setText(TranscriptText.markdown(item, .plan, cache: host.textCache))
        textView.onOpenLink = { [weak host] link in host?.openLink(link) ?? false }
        let highlights = findHighlights
        textView.setFindHighlights(highlights.ranges(in: .body), current: highlights.currentRange(in: .body))
        setAccessibilityLabel(String(localized: "Plan") + (progressLabel.stringValue.isEmpty ? "" : ", \(progressLabel.stringValue)"))
    }

    override func findTarget(for match: TranscriptFindMatch) -> TranscriptFindTarget? {
        match.field == .body ? findTarget(match.range, in: textView) : nil
    }

    /// Counts task items, including nested ones.
    static func progress(_ markdown: String) -> (done: Int, total: Int) {
        var done = 0
        var total = 0
        func visit(_ blocks: [ChatMarkdown.Block]) {
            for block in blocks {
                switch block {
                case .list(let list):
                    for item in list.items {
                        if let checked = item.task {
                            total += 1
                            if checked { done += 1 }
                        }
                        visit(item.blocks)
                    }
                case .quote(let children):
                    visit(children)
                default:
                    break
                }
            }
        }
        visit(ChatMarkdown.parse(markdown))
        return (done, total)
    }

    override class var measuresText: Bool { true }

    private static func textWidth(_ width: CGFloat) -> CGFloat {
        TranscriptMetrics.column(width: width).width - padding * 2
    }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        let size = TranscriptText.markdownSize(item, .plan, width: textWidth(width), cache: host.textCache)
        return padding + 18 + 8 + size.height + padding + bottomSpacing(for: row)
    }

    override class func estimatedHeight(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        return padding * 2 + 26 + TranscriptEstimate.textHeight(item.text, width: textWidth(width)) + bottomSpacing(for: row)
    }

    override var copyText: String? { item?.text }

    override func layout() {
        super.layout()
        guard let item, let host else { return }
        let column = TranscriptMetrics.column(width: bounds.width)
        let width = Self.textWidth(bounds.width)
        let size = TranscriptText.markdownSize(item, .plan, width: width, cache: host.textCache)
        let cardHeight = Self.padding + 18 + 8 + size.height + Self.padding
        card.frame = NSRect(x: column.x, y: 0, width: column.width, height: cardHeight)
        icon.frame = NSRect(x: Self.padding, y: Self.padding + 1, width: 14, height: 16)
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: Self.padding + 20, y: Self.padding)
        progressLabel.sizeToFit()
        progressLabel.frame.origin = NSPoint(x: column.width - Self.padding - progressLabel.frame.width, y: Self.padding + 1)
        textView.frame = NSRect(x: Self.padding, y: Self.padding + 26, width: width, height: size.height)
    }
}

// MARK: - Changed files

/// Files the turn changed, from its checkpoints; opens the diff panel.
final class TranscriptChangedFilesCell: TranscriptCell {
    private static let padding: CGFloat = 10
    private static let headerHeight: CGFloat = 24
    private static let fileRowHeight: CGFloat = 24
    private static let visibleFiles = 6

    private let card = TranscriptCardView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private lazy var diffButton: NSButton = {
        let button = NSButton(title: String(localized: "View Diff"), target: self, action: #selector(showDiff))
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.image = Theme.symbol("plusminus", size: 11, weight: .medium)
        button.imagePosition = .imageLeading
        button.contentTintColor = .secondaryLabelColor
        button.font = .systemFont(ofSize: Theme.fontSize - 2, weight: .medium)
        return button
    }()
    private var fileRows: [TranscriptFileRow] = []
    private var files: [ChangedFile] = []
    private var turnID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(card)
        for view in [titleLabel, statsLabel, diffButton] as [NSView] { card.addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard case .changedFiles(let turnID) = row.kind else { return }
        self.turnID = turnID
        files = host.changedFiles(for: turnID)
        titleLabel.stringValue = files.count == 1 ? String(localized: "1 changed file") : String(localized: "\(files.count) changed files")
        titleLabel.font = .systemFont(ofSize: Theme.fontSize - 1, weight: .semibold)
        statsLabel.attributedStringValue = Self.stats(
            additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions })
        let rowCount = Self.rowCount(files.count)
        while fileRows.count < rowCount {
            let fileRow = TranscriptFileRow()
            fileRow.onOpen = { [weak self] path in self?.open(path) }
            card.addSubview(fileRow)
            fileRows.append(fileRow)
        }
        for (index, fileRow) in fileRows.enumerated() {
            fileRow.isHidden = index >= rowCount
            guard index < rowCount else { continue }
            if index < min(files.count, Self.visibleFiles) || files.count == Self.visibleFiles + 1 {
                fileRow.configure(file: files[index])
            } else {
                fileRow.configureMore(count: files.count - Self.visibleFiles)
            }
        }
        setAccessibilityLabel(titleLabel.stringValue)
    }

    /// Up to six files, plus a "more" row when there are more than seven.
    private static func rowCount(_ files: Int) -> Int {
        files <= visibleFiles + 1 ? files : visibleFiles + 1
    }

    static func stats(additions: Int, deletions: Int) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .medium)
        let text = NSMutableAttributedString()
        if additions > 0 || deletions == 0 {
            text.append(NSAttributedString(string: "+\(additions)", attributes: [.font: font, .foregroundColor: NSColor.systemGreen]))
        }
        if deletions > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            text.append(NSAttributedString(string: "−\(deletions)", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
        }
        return text
    }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard case .changedFiles(let turnID) = row.kind else { return 0 }
        let rows = CGFloat(rowCount(host.changedFiles(for: turnID).count))
        return padding + headerHeight + 4 + rows * fileRowHeight + padding - 4 + bottomSpacing(for: row)
    }

    override var copyText: String? { files.map(\.path).joined(separator: "\n") }

    override func layout() {
        super.layout()
        guard let row else { return }
        let column = TranscriptMetrics.column(width: bounds.width)
        card.frame = NSRect(x: column.x, y: 0, width: column.width, height: bounds.height - Self.bottomSpacing(for: row))
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: Self.padding + 4, y: Self.padding + (Self.headerHeight - titleLabel.frame.height) / 2)
        statsLabel.sizeToFit()
        statsLabel.frame.origin = NSPoint(x: titleLabel.frame.maxX + 8, y: Self.padding + (Self.headerHeight - statsLabel.frame.height) / 2)
        let buttonWidth = ceil(diffButton.intrinsicContentSize.width) + 8
        diffButton.frame = NSRect(x: column.width - Self.padding - buttonWidth, y: Self.padding, width: buttonWidth, height: Self.headerHeight)
        var y = Self.padding + Self.headerHeight + 4
        for fileRow in fileRows where !fileRow.isHidden {
            fileRow.frame = NSRect(x: Self.padding - 4, y: y, width: column.width - Self.padding * 2 + 8, height: Self.fileRowHeight)
            y += Self.fileRowHeight
        }
    }

    @objc private func showDiff() {
        guard let turnID else { return }
        host?.showDiff(turnID: turnID, path: nil)
    }

    private func open(_ path: String?) {
        guard let turnID else { return }
        host?.showDiff(turnID: turnID, path: path)
    }
}

/// One file in the changed-files card, or the "N more files" row.
final class TranscriptFileRow: NSView {
    var onOpen: ((String?) -> Void)?

    private let icon = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private var path: String?
    private var isHovered = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        for view in [icon, pathLabel, statsLabel] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(file: ChangedFile) {
        path = file.path
        let (symbol, color): (String, NSColor) =
            switch file.status {
            case .added, .untracked: ("plus.square", .systemGreen)
            case .deleted: ("minus.square", .systemRed)
            case .renamed: ("arrow.right.square", .systemBlue)
            case .modified: ("pencil.and.outline", .systemOrange)
            }
        icon.image = Theme.symbol(symbol, size: 11, weight: .regular)
        icon.contentTintColor = color
        icon.isHidden = false
        pathLabel.stringValue = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        pathLabel.font = .monospacedSystemFont(ofSize: Theme.fontSize - 2, weight: .regular)
        pathLabel.textColor = .labelColor
        statsLabel.attributedStringValue = TranscriptChangedFilesCell.stats(additions: file.additions, deletions: file.deletions)
        statsLabel.isHidden = false
        toolTip = file.path
        setAccessibilityLabel(String(localized: "\(file.path), \(file.additions) additions, \(file.deletions) deletions"))
        needsLayout = true
    }

    func configureMore(count: Int) {
        path = nil
        icon.isHidden = true
        statsLabel.isHidden = true
        pathLabel.stringValue = String(localized: "\(count) more files…")
        pathLabel.font = .systemFont(ofSize: Theme.fontSize - 2, weight: .medium)
        pathLabel.textColor = .secondaryLabelColor
        toolTip = nil
        setAccessibilityLabel(pathLabel.stringValue)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        icon.frame = NSRect(x: 6, y: (height - 14) / 2, width: 14, height: 14)
        statsLabel.sizeToFit()
        let statsWidth = statsLabel.isHidden ? 0 : statsLabel.frame.width
        statsLabel.frame = NSRect(x: bounds.width - 6 - statsWidth, y: (height - statsLabel.frame.height) / 2, width: statsWidth, height: statsLabel.frame.height)
        let x: CGFloat = icon.isHidden ? 8 : 26
        let labelHeight = ceil(pathLabel.intrinsicContentSize.height)
        pathLabel.frame = NSRect(x: x, y: (height - labelHeight) / 2, width: max(0, statsLabel.frame.minX - 8 - x), height: labelHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(path)
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?(path)
        return true
    }
}

// MARK: - Error and notice

/// A failed turn or provider error, in red with the full message selectable.
final class TranscriptErrorCell: TranscriptCell {
    private static let padding: CGFloat = 10
    private static let textX: CGFloat = 34

    private let card = TranscriptCardView()
    private let icon = NSImageView()
    private let textView = ChatTextView()
    private var item: TranscriptItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.fillColor = Theme.failureFill
        card.strokeColor = Theme.failureStroke
        icon.image = Theme.symbol("exclamationmark.triangle.fill", size: 12, weight: .regular)
        icon.contentTintColor = Theme.failure
        addSubview(card)
        card.addSubview(icon)
        card.addSubview(textView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Error"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func text(_ item: TranscriptItem, cache: TranscriptTextCache) -> ChatRenderedText {
        cache.text(for: item.id, style: .error, source: item.text) { _ in
            ChatRenderedText(
                string: NSAttributedString(
                    string: item.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    attributes: [.font: ChatFonts.body(Theme.fontSize), .foregroundColor: NSColor.labelColor]),
                codeBlocks: [])
        }
    }

    private static func textSize(_ item: TranscriptItem, width: CGFloat, host: TranscriptHost) -> NSSize {
        let textWidth = TranscriptMetrics.column(width: width).width - textX - padding
        return host.textCache.size(for: item.id, style: .error, source: item.text, width: textWidth) { _ in text(item, cache: host.textCache) }
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard let id = row.itemID, let item = host.item(id) else { return }
        self.item = item
        textView.setText(Self.text(item, cache: host.textCache).string)
        let highlights = findHighlights
        textView.setFindHighlights(highlights.ranges(in: .body), current: highlights.currentRange(in: .body))
    }

    override func findTarget(for match: TranscriptFindMatch) -> TranscriptFindTarget? {
        match.field == .body ? findTarget(match.range, in: textView) : nil
    }

    override class var measuresText: Bool { true }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        return max(18, textSize(item, width: width, host: host).height) + padding * 2 + bottomSpacing(for: row)
    }

    override var copyText: String? { item?.text }

    override func layout() {
        super.layout()
        guard let row, let item, let host else { return }
        let column = TranscriptMetrics.column(width: bounds.width)
        let size = Self.textSize(item, width: bounds.width, host: host)
        card.frame = NSRect(x: column.x, y: 0, width: column.width, height: bounds.height - Self.bottomSpacing(for: row))
        icon.frame = NSRect(x: 12, y: Self.padding + 1, width: 16, height: 16)
        textView.frame = NSRect(x: Self.textX, y: Self.padding, width: column.width - Self.textX - Self.padding, height: max(18, size.height))
    }
}

/// A short system note, such as "Interrupted", centered between hairlines.
final class TranscriptNoticeCell: TranscriptCell {
    private let label = NSTextField(labelWithString: "")
    private var item: TranscriptItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard let id = row.itemID, let item = host.item(id) else { return }
        self.item = item
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(
            string: Self.label(item),
            attributes: [
                .font: NSFont.systemFont(ofSize: Theme.fontSize - 2, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
        let highlights = findHighlights
        label.attributedStringValue = TranscriptFindStyle.highlight(
            text, ranges: highlights.ranges(in: .body), current: highlights.currentRange(in: .body))
        label.toolTip = item.text
        setAccessibilityLabel(item.text)
        needsLayout = true
        needsDisplay = true
    }

    /// The notice's first line, which is all the row shows.
    static func label(_ item: TranscriptItem) -> String {
        item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? item.text
    }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        22 + TranscriptMetrics.messageSpacing - 4
    }

    override var copyText: String? { item?.text }

    override func findTarget(for match: TranscriptFindMatch) -> TranscriptFindTarget? {
        guard match.field == .body else { return nil }
        layoutSubtreeIfNeeded()
        return TranscriptFindTarget(rect: label.frame, textView: nil, range: match.range)
    }

    override func layout() {
        super.layout()
        let column = TranscriptMetrics.column(width: bounds.width)
        let width = min(column.width - 80, ceil(label.intrinsicContentSize.width) + 4)
        label.frame = NSRect(x: column.x + (column.width - width) / 2, y: 3, width: width, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let column = TranscriptMetrics.column(width: bounds.width)
        NSColor.separatorColor.setFill()
        let y: CGFloat = 11
        NSRect(x: column.x, y: y, width: max(0, label.frame.minX - 10 - column.x), height: 1).fill()
        let right = label.frame.maxX + 10
        NSRect(x: right, y: y, width: max(0, column.x + column.width - right), height: 1).fill()
    }
}
