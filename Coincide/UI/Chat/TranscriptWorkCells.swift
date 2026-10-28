import AppKit
import CoincideKit

// MARK: - Turn header

/// Opens a turn's response: "Working for 12s" while it runs, then a "Worked for 2m 13s" toggle
/// that folds the turn's tool calls, reasoning and interim replies. Below a message steered into the
/// turn, "Continued for 20s" folds the work after it.
final class TranscriptTurnHeaderCell: TranscriptCell {
    private static let contentHeight: CGFloat = 28

    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let separator = NSBox()
    private var startedAt: Date?
    private var isToggle = false
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.textColor = .secondaryLabelColor
        separator.boxType = .separator
        for view in [label, chevron, separator] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard case .turnHeader(let header) = row.kind else { return }
        label.font = .monospacedDigitSystemFont(ofSize: Theme.fontSize - 1, weight: .regular)
        switch header {
        case .working(let startedAt):
            self.startedAt = startedAt
            isToggle = false
            chevron.isHidden = true
            setAccessibilityRole(.staticText)
            refreshLiveState()
        case .worked(let duration, let isExpanded):
            showToggle(String(localized: "Worked for \(TranscriptLabels.duration(duration))"), isExpanded: isExpanded)
        case .continued(let duration, let isExpanded):
            showToggle(String(localized: "Continued for \(TranscriptLabels.duration(duration))"), isExpanded: isExpanded)
        }
        label.textColor = isHovered && isToggle ? .labelColor : .secondaryLabelColor
        window?.invalidateCursorRects(for: self)
    }

    private func showToggle(_ title: String, isExpanded: Bool) {
        startedAt = nil
        isToggle = true
        chevron.isHidden = false
        chevron.image = Theme.symbol(isExpanded ? "chevron.down" : "chevron.right", size: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        label.stringValue = title
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityValue(isExpanded ? 1 : 0)
        setAccessibilityLabel(title)
    }

    override func refreshLiveState() {
        guard let startedAt else { return }
        label.stringValue = String(localized: "Working for \(TranscriptLabels.elapsed(Date().timeIntervalSince(startedAt)))")
        setAccessibilityLabel(label.stringValue)
        needsLayout = true
    }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        contentHeight + 12
    }

    override func layout() {
        super.layout()
        let column = TranscriptMetrics.column(width: bounds.width)
        let size = label.intrinsicContentSize
        label.frame = NSRect(
            x: column.x + 4, y: ((Self.contentHeight - size.height) / 2).rounded(), width: ceil(size.width) + 2, height: size.height)
        chevron.frame = NSRect(x: label.frame.maxX + 2, y: (Self.contentHeight - 12) / 2, width: 12, height: 12)
        separator.frame = NSRect(x: column.x, y: Self.contentHeight + 2, width: column.width, height: 1)
    }

    private var toggleRect: NSRect {
        NSRect(x: label.frame.minX - 4, y: 0, width: chevron.frame.maxX - label.frame.minX + 8, height: Self.contentHeight)
    }

    override func resetCursorRects() {
        if isToggle { addCursorRect(toggleRect, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(toggleRect.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        label.textColor = hovered && isToggle ? .labelColor : .secondaryLabelColor
    }

    override func mouseUp(with event: NSEvent) {
        guard isToggle, toggleRect.contains(convert(event.locationInWindow, from: nil)), let row else { return }
        host?.toggle(row.id)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isToggle, let row else { return false }
        host?.toggle(row.id)
        return true
    }
}

// MARK: - Tool call

/// One tool call: category symbol, title, status and, when expanded, its input and output.
final class TranscriptToolCell: TranscriptCell {
    private let header = TranscriptDisclosureHeader()
    private let panel = TranscriptDetailPanel()
    private var item: TranscriptItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(header)
        addSubview(panel)
        header.onToggle = { [weak self] in
            guard let self, let row = self.row else { return }
            self.host?.toggle(row.id)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard let id = row.itemID, let item = host.item(id) else { return }
        self.item = item
        let category = item.category ?? .other
        let highlights = findHighlights
        let title = TranscriptFindStyle.highlight(
            Self.title(item), ranges: highlights.ranges(in: .title), current: highlights.currentRange(in: .title))
        let isExpandable = TranscriptToolDetail.hasDetail(item)
        let isExpanded = isExpandable && host.isExpanded(row.id)
        header.configure(
            symbol: category.symbolName, symbolColor: item.status == .failed ? Theme.failure : .secondaryLabelColor, title: title,
            detail: TranscriptToolDetail.durationText(item), status: TranscriptToolDetail.status(item), isExpandable: isExpandable,
            isExpanded: isExpanded)
        panel.isHidden = !isExpanded
        panel.textView.setFindHighlights(highlights.ranges(in: .detail), current: highlights.currentRange(in: .detail))
        if isExpanded { panel.setText(TranscriptToolDetail.text(for: item, cache: host.textCache).string, textHeight: 0) }
        needsDisplay = true
    }

    /// The call's one-line title, as its header shows it.
    static func title(_ item: TranscriptItem) -> NSAttributedString {
        TranscriptText.inlineLabel(
            item.title ?? TranscriptLabels.categoryName(item.category ?? .other), font: .systemFont(ofSize: Theme.fontSize - 1),
            color: .secondaryLabelColor)
    }

    override func findTarget(for match: TranscriptFindMatch) -> TranscriptFindTarget? {
        switch match.field {
        case .title:
            TranscriptFindTarget(rect: convert(header.titleFrame, from: header), textView: nil, range: match.range)
        case .detail where !panel.isHidden:
            findTarget(match.range, in: panel.textView, panel: panel)
        default:
            nil
        }
    }

    override class var measuresText: Bool { true }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        var height = TranscriptMetrics.workRowHeight
        if TranscriptToolDetail.hasDetail(item), host.isExpanded(row.id) {
            height += 4 + panelHeight(item, width: width, row: row, host: host) + 6
        }
        return height + bottomSpacing(for: row)
    }

    override class func estimatedHeight(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard host.isExpanded(row.id) else { return TranscriptMetrics.workRowHeight + bottomSpacing(for: row) }
        return TranscriptMetrics.workRowHeight + 10 + TranscriptMetrics.detailMaxHeight / 2 + bottomSpacing(for: row)
    }

    private static func indent(_ row: TranscriptRow) -> CGFloat {
        if case .tool(true) = row.kind { return TranscriptMetrics.nestedIndent }
        return 0
    }

    private static func panelFrame(width: CGFloat, row: TranscriptRow) -> (x: CGFloat, width: CGFloat) {
        let column = TranscriptMetrics.column(width: width)
        let x = column.x + indent(row) + TranscriptMetrics.detailIndent
        return (x, column.x + column.width - x)
    }

    private static func textWidth(width: CGFloat, row: TranscriptRow) -> CGFloat {
        panelFrame(width: width, row: row).width - TranscriptDetailPanel.padding * 2
    }

    private static func panelHeight(_ item: TranscriptItem, width: CGFloat, row: TranscriptRow, host: TranscriptHost) -> CGFloat {
        let size = host.textCache.size(
            for: item.id, style: .toolDetail, source: TranscriptToolDetail.source(item), width: textWidth(width: width, row: row)
        ) { _ in TranscriptToolDetail.render(item) }
        return TranscriptDetailPanel.height(forTextHeight: size.height)
    }

    override var copyText: String? {
        guard let item else { return nil }
        return [item.detail ?? item.title, item.text.isEmpty ? nil : item.text].compactMap { $0 }.joined(separator: "\n\n")
    }

    override func layout() {
        super.layout()
        guard let row, let item, let host else { return }
        let column = TranscriptMetrics.column(width: bounds.width)
        let indent = Self.indent(row)
        header.frame = NSRect(x: column.x + indent, y: 0, width: column.width - indent, height: TranscriptMetrics.workRowHeight)
        guard !panel.isHidden else { return }
        let frame = Self.panelFrame(width: bounds.width, row: row)
        let height = Self.panelHeight(item, width: bounds.width, row: row, host: host)
        panel.frame = NSRect(x: frame.x, y: TranscriptMetrics.workRowHeight + 4, width: frame.width, height: height)
        let textSize = host.textCache.size(
            for: item.id, style: .toolDetail, source: TranscriptToolDetail.source(item), width: Self.textWidth(width: bounds.width, row: row)
        ) { _ in TranscriptToolDetail.render(item) }
        panel.setText(TranscriptToolDetail.text(for: item, cache: host.textCache).string, textHeight: textSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row, case .tool(true) = row.kind else { return }
        TranscriptGuide.draw(in: bounds, row: row)
    }
}

/// The vertical guide that ties a group's expanded calls to its header.
@MainActor
enum TranscriptGuide {
    static func draw(in bounds: NSRect, row: TranscriptRow) {
        let column = TranscriptMetrics.column(width: bounds.width)
        let end = row.continuesWork ? bounds.height : TranscriptMetrics.workRowHeight / 2
        NSColor.separatorColor.setFill()
        NSRect(x: column.x + 10, y: 0, width: 1, height: end).fill()
    }
}

/// Builds the expanded view of a tool call: the command, diff or input, then its output.
@MainActor
enum TranscriptToolDetail {
    /// Output beyond this is trimmed from the front; the end of a log matters most.
    static let outputLimit = 60_000

    static func source(_ item: TranscriptItem) -> String {
        "\(item.category?.rawValue ?? "")\u{1}\(item.title ?? "")\u{1}\(item.detail ?? "")\u{1}\(item.text)"
    }

    static func hasDetail(_ item: TranscriptItem) -> Bool {
        let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (!detail.isEmpty && detail != item.title) || !item.text.allSatisfy(\.isWhitespace)
    }

    static func status(_ item: TranscriptItem) -> TranscriptDisclosureHeader.Status {
        switch item.status {
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .declined: .declined
        case .waiting: .waiting
        case nil: .none
        }
    }

    static func durationText(_ item: TranscriptItem) -> String? {
        guard item.status != .running, let end = item.completedAt else { return nil }
        let duration = end.timeIntervalSince(item.createdAt)
        return duration >= 1 ? TranscriptLabels.duration(duration) : nil
    }

    static func text(for item: TranscriptItem, cache: TranscriptTextCache) -> ChatRenderedText {
        cache.text(for: item.id, style: .toolDetail, source: source(item)) { _ in render(item) }
    }

    static func render(_ item: TranscriptItem) -> ChatRenderedText {
        let output = NSMutableAttributedString()
        let font = ChatFonts.mono(Theme.fontSize - 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 1
        func append(_ text: String, color: NSColor = .labelColor) -> NSRange {
            let start = output.length
            output.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
            return NSRange(location: start, length: output.length - start)
        }
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let result = cleanOutput(item.text)

        switch item.category ?? .other {
        case .command:
            let command = detail ?? title.map(stripTicks) ?? ""
            if !command.isEmpty {
                _ = append("$ ", color: .secondaryLabelColor)
                ChatSyntaxHighlighter.highlight(output, range: append(command), language: "bash")
            }
            if let result {
                if output.length > 0 { _ = append("\n\n") }
                _ = append(result)
            }
        case .fileChange:
            if let detail, detail != title {
                let range = append(detail)
                if ChatSyntaxHighlighter.looksLikeDiff(detail) { ChatSyntaxHighlighter.highlightDiff(output, range: range) }
            }
            if let result {
                if output.length > 0 { _ = append("\n\n") }
                _ = append(result, color: .secondaryLabelColor)
            }
        default:
            if let detail, detail != title { appendStructured(detail, to: output, append: append) }
            if let result {
                if output.length > 0 { _ = append("\n\n") }
                appendStructured(result, to: output, append: append)
            }
        }
        return ChatRenderedText(string: output, codeBlocks: [])
    }

    private static func appendStructured(_ text: String, to output: NSMutableAttributedString, append: (String, NSColor) -> NSRange) {
        if let first = text.first, first == "{" || first == "[", let value = JSONValue.parse(text) {
            ChatSyntaxHighlighter.highlight(output, range: append(value.prettyJSON, .labelColor), language: "json")
        } else if ChatSyntaxHighlighter.looksLikeDiff(text) {
            ChatSyntaxHighlighter.highlightDiff(output, range: append(text, .labelColor))
        } else {
            _ = append(text, .labelColor)
        }
    }

    private static func cleanOutput(_ text: String) -> String? {
        var cleaned = text
        if cleaned.contains("\u{1B}") {
            cleaned = cleaned.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.utf16.count > outputLimit else { return cleaned }
        let tail = String(cleaned.suffix(outputLimit))
        return String(localized: "… earlier output trimmed …") + "\n" + tail
    }

    private static func stripTicks(_ title: String) -> String {
        guard let open = title.firstIndex(of: "`"), let close = title.lastIndex(of: "`"), open < close else { return title }
        return String(title[title.index(after: open)..<close])
    }
}

// MARK: - Group of tool calls

/// Consecutive tool calls folded into one line, "Ran 3 commands and read 2 files". While one of
/// them runs, the line names it instead and shows a spinner.
final class TranscriptGroupCell: TranscriptCell {
    private let header = TranscriptDisclosureHeader()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(header)
        header.onToggle = { [weak self] in
            guard let self, let row = self.row else { return }
            self.host?.toggle(row.id)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard case .group(let ids, let isExpanded) = row.kind else { return }
        let items = ids.compactMap(host.item)
        let running = items.last { $0.status == .running }
        let font = NSFont.systemFont(ofSize: Theme.fontSize - 1)
        let title: NSAttributedString
        if let running {
            let text = running.kind == .reasoning ? String(localized: "Thinking") : running.title ?? TranscriptLabels.categoryName(running.category ?? .other)
            title = TranscriptText.inlineLabel(text, font: font, color: .secondaryLabelColor)
        } else {
            title = NSAttributedString(string: TranscriptLabels.summary(of: items), attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
        let failed = items.last { $0.kind == .tool }?.status == .failed
        header.configure(
            symbol: running.map { $0.kind == .reasoning ? "brain" : ($0.category ?? .other).symbolName } ?? TranscriptLabels.symbol(for: items),
            title: title, status: running != nil ? .running : failed ? .failed : .none, isExpandable: true, isExpanded: isExpanded,
            shimmer: running != nil)
    }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        TranscriptMetrics.workRowHeight + bottomSpacing(for: row)
    }

    override var copyText: String? {
        guard let row, case .group(let ids, _) = row.kind, let host else { return nil }
        return ids.compactMap(host.item).map { $0.title ?? $0.text }.joined(separator: "\n")
    }

    override func layout() {
        super.layout()
        let column = TranscriptMetrics.column(width: bounds.width)
        header.frame = NSRect(x: column.x, y: 0, width: column.width, height: TranscriptMetrics.workRowHeight)
    }
}

// MARK: - Reasoning

/// The agent's reasoning: "Thought for 4s" with the first sentence, expanding to the full text.
final class TranscriptReasoningCell: TranscriptCell {
    private static let maxTextHeight: CGFloat = 380

    private let header = TranscriptDisclosureHeader()
    private let panel = TranscriptDetailPanel()
    private var item: TranscriptItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        panel.drawsBackground = false
        addSubview(header)
        addSubview(panel)
        header.onToggle = { [weak self] in
            guard let self, let row = self.row else { return }
            self.host?.toggle(row.id)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard let id = row.itemID, let item = host.item(id) else { return }
        self.item = item
        let isRunning = item.status == .running
        let isExpanded = host.isExpanded(row.id)
        let font = NSFont.systemFont(ofSize: Theme.fontSize - 1)
        let title = NSMutableAttributedString(
            string: isRunning ? String(localized: "Thinking") : Self.thoughtLabel(item),
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        if !isExpanded {
            let preview = TranscriptLabels.thoughtPreview(item.text)
            if !preview.isEmpty {
                title.append(NSAttributedString(string: "  " + preview, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
        header.configure(
            symbol: "brain", title: title, status: isRunning ? .running : .none, isExpandable: true, isExpanded: isExpanded, shimmer: isRunning)
        panel.isHidden = !isExpanded
        if isExpanded { panel.textView.onOpenLink = { [weak host] link in host?.openLink(link) ?? false } }
        let highlights = findHighlights
        panel.textView.setFindHighlights(highlights.ranges(in: .body), current: highlights.currentRange(in: .body))
        needsDisplay = true
    }

    override func findTarget(for match: TranscriptFindMatch) -> TranscriptFindTarget? {
        guard match.field == .body, !panel.isHidden else { return nil }
        return findTarget(match.range, in: panel.textView, panel: panel)
    }

    private static func thoughtLabel(_ item: TranscriptItem) -> String {
        guard let end = item.completedAt else { return String(localized: "Thought") }
        let duration = end.timeIntervalSince(item.createdAt)
        return duration >= 1 ? String(localized: "Thought for \(TranscriptLabels.duration(duration))") : String(localized: "Thought")
    }

    override class var measuresText: Bool { true }

    private static func indent(_ row: TranscriptRow) -> CGFloat {
        if case .reasoning(true) = row.kind { return TranscriptMetrics.nestedIndent }
        return 0
    }

    private static func textFrame(width: CGFloat, row: TranscriptRow) -> (x: CGFloat, width: CGFloat) {
        let column = TranscriptMetrics.column(width: width)
        let x = column.x + indent(row) + TranscriptMetrics.detailIndent
        return (x, column.x + column.width - x)
    }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        var height = TranscriptMetrics.workRowHeight
        if host.isExpanded(row.id) {
            let size = TranscriptText.markdownSize(item, .reasoning, width: textFrame(width: width, row: row).width, cache: host.textCache)
            height += 2 + min(maxTextHeight, size.height) + 8
        }
        return height + bottomSpacing(for: row)
    }

    override class func estimatedHeight(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard host.isExpanded(row.id), let id = row.itemID, let item = host.item(id) else {
            return TranscriptMetrics.workRowHeight + bottomSpacing(for: row)
        }
        let text = TranscriptEstimate.textHeight(item.text, width: textFrame(width: width, row: row).width)
        return TranscriptMetrics.workRowHeight + 10 + min(maxTextHeight, text) + bottomSpacing(for: row)
    }

    override var copyText: String? { item?.text }

    override func layout() {
        super.layout()
        guard let row, let item, let host else { return }
        let column = TranscriptMetrics.column(width: bounds.width)
        let indent = Self.indent(row)
        header.frame = NSRect(x: column.x + indent, y: 0, width: column.width - indent, height: TranscriptMetrics.workRowHeight)
        guard !panel.isHidden else { return }
        let frame = Self.textFrame(width: bounds.width, row: row)
        let size = TranscriptText.markdownSize(item, .reasoning, width: frame.width, cache: host.textCache)
        panel.frame = NSRect(x: frame.x, y: TranscriptMetrics.workRowHeight + 2, width: frame.width, height: min(Self.maxTextHeight, size.height))
        panel.setText(TranscriptText.markdown(item, .reasoning, cache: host.textCache), textHeight: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row, case .reasoning(true) = row.kind else { return }
        TranscriptGuide.draw(in: bounds, row: row)
    }
}

// MARK: - Live status

/// The bottom line while a turn runs and nothing else shows activity: "Thinking…".
final class TranscriptLiveCell: TranscriptCell {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.textColor = .secondaryLabelColor
        addSubview(spinner)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard case .live(let status) = row.kind else { return }
        label.font = .systemFont(ofSize: Theme.fontSize - 1)
        switch status {
        case .starting(let provider): label.stringValue = String(localized: "Starting \(provider.displayName)…")
        case .thinking: label.stringValue = String(localized: "Thinking…")
        }
        setAccessibilityLabel(label.stringValue)
        spinner.startAnimation(nil)
        TranscriptShimmer.set(true, on: label)
    }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        TranscriptMetrics.workRowHeight + TranscriptMetrics.workSpacing
    }

    override func layout() {
        super.layout()
        let column = TranscriptMetrics.column(width: bounds.width)
        spinner.frame = NSRect(x: column.x + 3, y: (TranscriptMetrics.workRowHeight - 14) / 2, width: 14, height: 14)
        let size = label.intrinsicContentSize
        label.frame = NSRect(
            x: column.x + 26, y: ((TranscriptMetrics.workRowHeight - size.height) / 2).rounded(), width: ceil(size.width) + 2, height: size.height)
        TranscriptShimmer.layout(label)
    }
}

/// Empty space before the first row and after the last, so the transcript never sits flush against
/// the top edge or the composer.
final class TranscriptSpacerCell: TranscriptCell {
    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        if case .spacer(let height) = row.kind { return height }
        return TranscriptMetrics.edgePadding
    }
}

extension TranscriptLabels {
    static func categoryName(_ category: ToolCategory) -> String {
        switch category {
        case .command: String(localized: "Command")
        case .fileChange: String(localized: "File change")
        case .read: String(localized: "Read file")
        case .search: String(localized: "Search")
        case .web: String(localized: "Web search")
        case .mcp: String(localized: "MCP tool")
        case .task: String(localized: "Subagent")
        case .todo: String(localized: "Plan update")
        case .other: String(localized: "Tool")
        }
    }
}
