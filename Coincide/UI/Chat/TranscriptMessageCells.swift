import AppKit
import CoincideKit
import QuartzCore

// MARK: - User message

extension UserMessageSide {
    /// Whether messages on this side sit on the transcript's right. A right-to-left interface mirrors the sides, as
    /// chat apps do there: the user's messages go to the left by default.
    func isOnRight(in direction: NSUserInterfaceLayoutDirection) -> Bool {
        (self == .right) == (direction == .leftToRight)
    }

    /// The side's name as it shows in an interface laid out in `direction`.
    func title(in direction: NSUserInterfaceLayoutDirection) -> String {
        isOnRight(in: direction) ? UserMessageSide.right.displayName : UserMessageSide.left.displayName
    }
}

/// The user's message: a quiet card with image thumbnails, pills for the context attached to it (quotes, terminal
/// output, diff comments, files), long text folded behind "Show full message", and T3's "Edit from here" and copy
/// actions that appear on hover. A message steered into a running turn carries T3's "Steer" mark above the card.
///
/// The card hugs its content and, by default, sits on the right across from the agents' replies, as in a chat app
/// (Settings › General › Your messages); the actions and the "Steer" mark line up with the card's outer edge. On the
/// left it sits on the agent rail, which marks it with a ring. The card's text keeps its own alignment wherever the
/// card sits.
final class TranscriptUserCell: TranscriptCell {
    /// The widest the card gets on the right, as a share of the column, so a long message still reads as a reply's
    /// counterpart rather than a page of its own.
    static let maxWidthFraction: CGFloat = 0.75
    /// The widest the card gets on the rail, as before the setting.
    static let railMaxWidthFraction: CGFloat = 0.8
    /// Below this column width the card on the right may take the whole column: a narrower card would wrap a few
    /// words a line.
    static let narrowColumnWidth: CGFloat = 440
    private static let padding: CGFloat = 12
    private static let collapsedTextHeight: CGFloat = 176
    private static let thumbnailGap: CGFloat = 8
    private static let pillGap: CGFloat = 6
    /// The "Steer" mark's line and the gap below it.
    private static let steerMarkHeight: CGFloat = 14
    private static let steerMarkGap: CGFloat = 4

    private let bubble = TranscriptBubbleView()
    private let textView = ChatTextView()
    private var thumbnails: [TranscriptThumbnailView] = []
    private var pills: [MessageContextPill] = []
    private let toggleButton = NSButton(title: "", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "")
    private let steerIcon = NSImageView()
    private let steerLabel = NSTextField(labelWithString: String(localized: "Steer"))
    private lazy var rewindButton = TranscriptIconButton(
        symbol: "arrow.uturn.backward", label: String(localized: "Edit from here"), action: #selector(rewind), target: self)
    private lazy var copyButton = TranscriptIconButton(
        symbol: "doc.on.doc", label: String(localized: "Copy message"), action: #selector(copyMessage), target: self)
    private var isHovered = false
    private var item: TranscriptItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.layer?.cornerCurve = .continuous
        addSubview(bubble)
        textView.wantsLayer = true
        bubble.addSubview(textView)
        toggleButton.isBordered = false
        toggleButton.bezelStyle = .accessoryBarAction
        toggleButton.font = .systemFont(ofSize: Theme.fontSize - 2, weight: .medium)
        toggleButton.contentTintColor = .secondaryLabelColor
        toggleButton.target = self
        toggleButton.action = #selector(toggleExpanded)
        bubble.addSubview(toggleButton)
        timeLabel.textColor = .tertiaryLabelColor
        steerIcon.contentTintColor = .secondaryLabelColor
        steerLabel.textColor = .secondaryLabelColor
        for view in [steerIcon, steerLabel] as [NSView] {
            view.toolTip = String(localized: "Steered the active turn")
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        for view in [timeLabel, rewindButton, copyButton] as [NSView] {
            view.alphaValue = 0
            addSubview(view)
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
        textView.setText(TranscriptText.markdown(item, .user, cache: host.textCache))
        textView.onOpenLink = { [weak host] link in host?.openLink(link) ?? false }
        textView.onQuote = { [weak host] text in host?.quote(text, from: id) }
        let highlights = findHighlights
        textView.setFindHighlights(highlights.ranges(in: .body), current: highlights.currentRange(in: .body))
        let attachments = item.attachments ?? []
        while thumbnails.count < attachments.count {
            let thumbnail = TranscriptThumbnailView()
            thumbnail.onOpen = { [weak self] index in self?.openAttachment(index) }
            bubble.addSubview(thumbnail)
            thumbnails.append(thumbnail)
        }
        for (index, thumbnail) in thumbnails.enumerated() {
            thumbnail.isHidden = index >= attachments.count
            if index < attachments.count { thumbnail.configure(path: attachments[index], index: index) }
        }
        let context = item.context ?? []
        while pills.count < context.count {
            let pill = MessageContextPill()
            pill.onOpen = { [weak self] context, anchor in self?.host?.openContext(context, from: anchor) }
            bubble.addSubview(pill)
            pills.append(pill)
        }
        for (index, pill) in pills.enumerated() {
            pill.isHidden = index >= context.count
            if index < context.count { pill.configure(context[index]) }
        }
        timeLabel.stringValue = TranscriptFormat.timestamp(item.createdAt)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .regular)
        timeLabel.toolTip = TranscriptFormat.fullTimestamp(item.createdAt)
        // As in T3, the conversation cannot be rewound while a turn runs.
        rewindButton.isEnabled = !host.isThreadRunning
        steerIcon.isHidden = !item.isSteered
        steerLabel.isHidden = !item.isSteered
        if item.isSteered {
            steerIcon.image = Theme.symbol("arrow.uturn.forward", size: Theme.fontSize - 3, weight: .medium)
            steerLabel.font = .systemFont(ofSize: Theme.fontSize - 2)
        }
        setAccessibilityLabel(item.isSteered ? String(localized: "You, steered the active turn") : String(localized: "You"))
        updateActionsVisibility(animated: false)
    }

    override class var measuresText: Bool { true }

    /// The middle of the card's first line.
    override var railNodeY: CGFloat {
        let lineHeight = Theme.lineHeight(of: Theme.bodyFont)
        return (item.map(Self.steerMarkSpace) ?? 0) + Self.padding + (lineHeight / 2).rounded()
    }

    /// The rail rings the message only while the card sits on it.
    override var showsRailNode: Bool { !Theme.userMessageSide.isOnRight(in: userInterfaceLayoutDirection) }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        return layout(for: item, row: row, width: width, host: host).height
    }

    override class func estimatedHeight(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        let content = maxBubbleWidth(column: TranscriptMetrics.column(width: width).width, side: Theme.userMessageSide) - padding * 2
        let text = TranscriptEstimate.textHeight(item.text, width: content)
        let images = (item.attachments ?? []).isEmpty ? 0 : CGFloat(((item.attachments?.count ?? 0) + 1) / 2) * 86
        let context = (item.context ?? []).isEmpty ? 0 : MessageContextPill.height + pillGap
        return steerMarkSpace(item) + min(text, collapsedTextHeight + 24) + images + context + padding * 2 + 20
            + bottomSpacing(for: row)
    }

    override var copyText: String? { item?.text }

    override func findTarget(for match: TranscriptFindMatch) -> TranscriptFindTarget? {
        match.field == .body ? findTarget(match.range, in: textView) : nil
    }

    /// Where the row's parts go. The bubble's contents are in the bubble's coordinates.
    struct Layout {
        /// The "Steer" mark's line, above the bubble, across the column.
        var steerMark: NSRect?
        var bubble: NSRect
        var thumbnails: [NSRect]
        var pills: [NSRect]
        var text: NSRect
        var toggle: NSRect?
        var actionsY: CGFloat
        var height: CGFloat
        var isCollapsed: Bool
        /// Whether the card sits on the transcript's right; the actions and the "Steer" mark line up with its right
        /// edge then.
        var isOnRight: Bool
        /// Whether the card's contents and its rows of actions run right to left, mirrored.
        var isRightToLeft: Bool
    }

    /// The widest the card gets in a column `column` points wide.
    static func maxBubbleWidth(column: CGFloat, side: UserMessageSide) -> CGFloat {
        switch side {
        case .left: (column * railMaxWidthFraction).rounded(.down)
        case .right: column < narrowColumnWidth ? column : (column * maxWidthFraction).rounded(.down)
        }
    }

    private static func steerMarkSpace(_ item: TranscriptItem) -> CGFloat {
        item.isSteered ? steerMarkHeight + steerMarkGap : 0
    }

    static func shouldCollapse(_ text: String) -> Bool {
        text.count > 600 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 8
    }

    /// Whether the folded message hides `range` of its text, below "Show full message" or in its fade.
    static func hides(_ range: NSRange, of item: TranscriptItem, row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> Bool {
        let layout = layout(for: item, row: row, width: width, host: host)
        guard layout.isCollapsed else { return false }
        let text = TranscriptText.markdown(item, .user, cache: host.textCache).string
        guard let rect = ChatTextMeasurer.shared.rect(of: range, in: text, width: layout.text.width) else { return true }
        return rect.maxY > collapsedTextHeight - 24
    }

    /// The row's layout at `width`. Only the card's side and the direction move things sideways; heights depend on
    /// the side alone, through the card's widest.
    static func layout(
        for item: TranscriptItem, row: TranscriptRow, width: CGFloat, host: TranscriptHost,
        side: UserMessageSide = Theme.userMessageSide, direction: NSUserInterfaceLayoutDirection = .leftToRight
    ) -> Layout {
        let column = TranscriptMetrics.column(width: width)
        let maxBubble = maxBubbleWidth(column: column.width, side: side)
        let maxContent = maxBubble - padding * 2
        let attachments = item.attachments ?? []
        let thumbWidth = min(104, ((maxContent - thumbnailGap) / 2).rounded(.down))
        let thumbHeight = (thumbWidth * 0.75).rounded()
        var thumbnails: [NSRect] = []
        for index in attachments.indices {
            let x = padding + CGFloat(index % 2) * (thumbWidth + thumbnailGap)
            let y = padding + CGFloat(index / 2) * (thumbHeight + thumbnailGap)
            thumbnails.append(NSRect(x: x, y: y, width: thumbWidth, height: thumbHeight))
        }
        let hasText = !item.text.allSatisfy(\.isWhitespace)
        let textSize = hasText ? TranscriptText.markdownSize(item, .user, width: maxContent, cache: host.textCache) : .zero
        let canCollapse = hasText && shouldCollapse(item.text) && textSize.height > collapsedTextHeight + 20
        let isCollapsed = canCollapse && !host.isExpanded(row.id)
        let context = item.context ?? []
        var y = padding
        if let last = thumbnails.last { y = last.maxY + (hasText || !context.isEmpty ? thumbnailGap : 0) }
        var pills = pillFrames(for: context, x: padding, y: y, maxWidth: maxContent)
        if let bottom = pills.map(\.maxY).max() { y = bottom + (hasText ? thumbnailGap : 0) }
        let textHeight = isCollapsed ? collapsedTextHeight : textSize.height
        var text = NSRect(x: padding, y: y, width: min(maxContent, textSize.width + 1), height: textHeight)
        y += hasText ? textHeight : 0
        var toggle: NSRect?
        var contentWidth = max(text.width, (thumbnails + pills).map { $0.maxX - padding }.max() ?? 0)
        if canCollapse {
            toggle = NSRect(x: padding - 4, y: y + 6, width: 130, height: 18)
            y += 24
            contentWidth = max(contentWidth, 126)
        }
        let bubbleWidth = min(maxBubble, ceil(contentWidth) + padding * 2)
        let isOnRight = side.isOnRight(in: direction)
        let isRightToLeft = direction == .rightToLeft
        if isRightToLeft {
            // The card's contents run from its right edge.
            func mirror(_ rect: NSRect) -> NSRect {
                NSRect(x: bubbleWidth - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
            }
            thumbnails = thumbnails.map(mirror)
            pills = pills.map(mirror)
            text = mirror(text)
            toggle = toggle.map(mirror)
        }
        let top = steerMarkSpace(item)
        let x = isOnRight ? column.x + column.width - bubbleWidth : column.x
        let bubble = NSRect(x: x, y: top, width: bubbleWidth, height: y + padding)
        let actionsY = bubble.maxY + 4
        let steerMark = item.isSteered ? NSRect(x: column.x, y: 0, width: column.width, height: steerMarkHeight) : nil
        return Layout(
            steerMark: steerMark, bubble: bubble, thumbnails: thumbnails, pills: pills, text: text, toggle: toggle,
            actionsY: actionsY, height: actionsY + 20 + bottomSpacing(for: row) - 12, isCollapsed: isCollapsed,
            isOnRight: isOnRight, isRightToLeft: isRightToLeft)
    }

    /// The left edges of a row of items `widths` wide, in reading order, with `gaps[i]` between the `i`th and the
    /// next. The row starts at `edge`, or ends there when it `alignsRight`; right to left, the first item is the
    /// rightmost.
    static func rowOrigins(widths: [CGFloat], gaps: [CGFloat], edge: CGFloat, alignsRight: Bool, rightToLeft: Bool) -> [CGFloat] {
        let total = widths.reduce(0, +) + gaps.prefix(max(0, widths.count - 1)).reduce(0, +)
        var x = alignsRight ? edge - total : edge
        var origins = [CGFloat](repeating: 0, count: widths.count)
        let order = rightToLeft ? Array(widths.indices.reversed()) : Array(widths.indices)
        for (position, index) in order.enumerated() {
            origins[index] = x
            x += widths[index]
            if position < order.count - 1 { x += gaps[rightToLeft ? index - 1 : index] }
        }
        return origins
    }

    /// The context pills, left to right from (`x`, `y`), wrapping to a new line at `maxWidth`.
    private static func pillFrames(for context: [MessageContext], x: CGFloat, y: CGFloat, maxWidth: CGFloat) -> [NSRect] {
        var frames: [NSRect] = []
        var cursor = NSPoint(x: x, y: y)
        for item in context {
            let width = MessageContextPill.width(for: item, maxWidth: maxWidth)
            if cursor.x > x, cursor.x + width > x + maxWidth {
                cursor = NSPoint(x: x, y: cursor.y + MessageContextPill.height + pillGap)
            }
            frames.append(NSRect(x: cursor.x, y: cursor.y, width: width, height: MessageContextPill.height))
            cursor.x += width + pillGap
        }
        return frames
    }

    override func layout() {
        super.layout()
        guard let row, let item, let host else { return }
        let layout = Self.layout(for: item, row: row, width: bounds.width, host: host, direction: userInterfaceLayoutDirection)
        bubble.frame = layout.bubble
        textView.frame = layout.text
        for (index, frame) in layout.thumbnails.enumerated() where index < thumbnails.count {
            thumbnails[index].frame = frame
        }
        for (index, frame) in layout.pills.enumerated() where index < pills.count {
            pills[index].frame = frame
        }
        toggleButton.isHidden = layout.toggle == nil
        if let toggle = layout.toggle {
            toggleButton.frame = toggle
            toggleButton.title = layout.isCollapsed ? String(localized: "Show full message") : String(localized: "Show less")
            toggleButton.alignment = layout.isRightToLeft ? .right : .left
        }
        updateFade(collapsed: layout.isCollapsed)
        if let mark = layout.steerMark {
            // Over the card, at its outer edge: the icon, then the label.
            let iconSize: CGFloat = 12
            steerLabel.sizeToFit()
            let labelSize = NSSize(width: ceil(steerLabel.frame.width), height: ceil(steerLabel.frame.height))
            let origins = Self.rowOrigins(
                widths: [iconSize, labelSize.width], gaps: [3],
                edge: layout.isOnRight ? layout.bubble.maxX - 2 : layout.bubble.minX + 2,
                alignsRight: layout.isOnRight, rightToLeft: layout.isRightToLeft)
            steerIcon.frame = NSRect(x: origins[0], y: mark.minY + (mark.height - iconSize) / 2, width: iconSize, height: iconSize)
            steerLabel.frame = NSRect(
                x: origins[1], y: mark.minY + ((mark.height - labelSize.height) / 2).rounded(),
                width: labelSize.width, height: labelSize.height)
        }
        // The actions line up under the card's outer edge: edit, copy, then the time, in reading order. A button's
        // symbol sits inside its frame, so a button at the edge reaches 3 points past it.
        timeLabel.sizeToFit()
        let timeWidth = ceil(timeLabel.frame.width)
        let overhang: CGFloat = layout.isOnRight == layout.isRightToLeft ? 3 : 0
        let origins = Self.rowOrigins(
            widths: [22, 22, timeWidth], gaps: [0, 4],
            edge: layout.isOnRight ? layout.bubble.maxX + overhang : layout.bubble.minX - overhang,
            alignsRight: layout.isOnRight, rightToLeft: layout.isRightToLeft)
        rewindButton.frame = NSRect(x: origins[0], y: layout.actionsY, width: 22, height: 20)
        copyButton.frame = NSRect(x: origins[1], y: layout.actionsY, width: 22, height: 20)
        timeLabel.frame = NSRect(x: origins[2], y: layout.actionsY + 2, width: timeWidth, height: 16)
    }

    private func updateFade(collapsed: Bool) {
        guard let layer = textView.layer else { return }
        guard collapsed else {
            layer.mask = nil
            return
        }
        let mask = (layer.mask as? CAGradientLayer) ?? CAGradientLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = layer.bounds
        let fade = min(1, 28 / max(1, layer.bounds.height))
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        // Layer coordinates in a flipped view still run bottom-up for gradients.
        mask.startPoint = CGPoint(x: 0.5, y: 1)
        mask.endPoint = CGPoint(x: 0.5, y: 0)
        mask.locations = [0, NSNumber(value: Double(1 - fade)), 1]
        layer.mask = mask
        CATransaction.commit()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateActionsVisibility(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateActionsVisibility(animated: true)
    }

    override func selectionChanged() {
        updateActionsVisibility(animated: true)
    }

    private func updateActionsVisibility(animated: Bool) {
        let alpha: CGFloat = isHovered || isRowSelected ? 1 : 0
        let views = [timeLabel, rewindButton, copyButton] as [NSView]
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                for view in views { view.animator().alphaValue = alpha }
            }
        } else {
            for view in views { view.alphaValue = alpha }
        }
    }

    // MARK: Actions

    @objc private func toggleExpanded() {
        guard let row else { return }
        host?.toggle(row.id)
    }

    @objc private func rewind() {
        guard let item else { return }
        host?.rewindTurn(item.id)
    }

    @objc private func copyMessage() {
        guard let item else { return }
        host?.copyToPasteboard(item.text)
        copyButton.flashConfirmation()
    }

    private func openAttachment(_ index: Int) {
        guard let attachments = item?.attachments else { return }
        host?.previewAttachments(attachments, selected: index)
    }
}

// MARK: - Assistant message

/// An agent reply rendered as Markdown, in New York unless the user chose the system font. Code blocks get copy
/// buttons; the turn's final reply ends with which agent and model answered, copy and fork buttons and the time.
final class TranscriptAssistantCell: TranscriptCell {
    private static let textInset: CGFloat = 4
    private static let metaHeight: CGFloat = 20

    private let textView = ChatTextView()
    private var mediaViews: [TranscriptMediaView] = []
    private var codeButtons: [TranscriptIconButton] = []
    private var rendered = ChatRenderedText.empty
    private let modelLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private lazy var copyButton = TranscriptIconButton(
        symbol: "doc.on.doc", label: String(localized: "Copy response"), action: #selector(copyResponse), target: self)
    private lazy var forkButton = TranscriptIconButton(
        symbol: "arrow.triangle.branch", label: String(localized: "Fork from this response"), action: #selector(fork), target: self)
    private var item: TranscriptItem?
    private var meta: AssistantMeta?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(textView)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.lineBreakMode = .byTruncatingTail
        timeLabel.textColor = .tertiaryLabelColor
        for view in [modelLabel, timeLabel, copyButton, forkButton] as [NSView] { addSubview(view) }
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
        if case .assistant(let meta) = row.kind { self.meta = meta } else { meta = nil }
        let media = TranscriptMediaCache.media(item, directory: host.mediaDirectory)
        if mediaViews.map(\.media) != media {
            mediaViews.forEach { $0.removeFromSuperview() }
            mediaViews = media.map { output in
                let view = TranscriptMediaView(media: output)
                view.onOpen = { [weak host] url in
                    if url.isFileURL { host?.previewAttachments([url.path], selected: 0) }
                    else { _ = host?.openLink(url) }
                }
                addSubview(view)
                return view
            }
        }
        rendered = TranscriptText.markdown(item, .assistant, cache: host.textCache)
        textView.setText(rendered)
        textView.onOpenLink = { [weak host] link in host?.openLink(link) ?? false }
        textView.onQuote = { [weak host] text in host?.quote(text, from: id) }
        let highlights = findHighlights
        textView.setFindHighlights(highlights.ranges(in: .body), current: highlights.currentRange(in: .body))
        while codeButtons.count < rendered.codeBlocks.count {
            let button = TranscriptIconButton(symbol: "doc.on.doc", label: String(localized: "Copy code"), action: #selector(copyCode(_:)), target: self)
            addSubview(button)
            codeButtons.append(button)
        }
        for (index, button) in codeButtons.enumerated() {
            button.isHidden = index >= rendered.codeBlocks.count
            button.tag = index
        }
        let showsMeta = meta != nil
        for view in [modelLabel, timeLabel, copyButton] as [NSView] { view.isHidden = !showsMeta }
        // T3 forks from finished responses only; the meta row ends a turn that is over.
        forkButton.isHidden = !showsMeta || !host.canFork(item.id)
        if let meta {
            modelLabel.attributedStringValue = Self.signature(meta, host: host)
            let date = item.completedAt ?? item.createdAt
            timeLabel.stringValue = TranscriptFormat.timestamp(date)
            timeLabel.toolTip = TranscriptFormat.fullTimestamp(date)
            timeLabel.font = .monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .regular)
        }
        setAccessibilityLabel(meta.map { host.modelLabel(for: $0) } ?? item.provider?.displayName ?? String(localized: "Agent"))
    }

    override class var measuresText: Bool { true }

    /// The middle of the reply's first line.
    override var railNodeY: CGFloat {
        (Theme.lineHeight(of: ChatFonts.body(Theme.replyFontSize, serif: Theme.usesSerifReplies)) / 2).rounded()
    }

    /// The agent's name in its color, then the model. In a bot's conversation, the bot with its avatar comes first.
    private static func signature(_ meta: AssistantMeta, host: TranscriptHost) -> NSAttributedString {
        let size = Theme.fontSize - 2
        let result = NSMutableAttributedString()
        if let bot = host.threadID.flatMap({ AppStore.shared.bot(forThread: $0) }) {
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let side = (font.capHeight + 6).rounded()
            let avatar = NSTextAttachment()
            avatar.image = BotAvatarArt.image(bot.avatar, size: side)
            avatar.bounds = NSRect(x: 0, y: ((font.capHeight - side) / 2).rounded(), width: side, height: side)
            result.append(NSAttributedString(attachment: avatar))
            result.append(NSAttributedString(
                string: " \(bot.displayName)  ", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        result.append(NSAttributedString(
            string: meta.provider.displayName,
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: Theme.color(for: meta.provider)]))
        if let model = host.modelName(for: meta) {
            result.append(
                NSAttributedString(
                    string: "  " + model, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return result
    }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        let textWidth = TranscriptMetrics.column(width: width).width - textInset * 2
        let size = TranscriptText.markdownSize(item, .assistant, width: textWidth, cache: host.textCache)
        return size.height + TranscriptMediaCache.height(item, width: textWidth, directory: host.mediaDirectory) + footerHeight(row) + bottomSpacing(row)
    }

    override class func estimatedHeight(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        let textWidth = TranscriptMetrics.column(width: width).width - textInset * 2
        return TranscriptEstimate.textHeight(item.text, width: textWidth) + TranscriptMediaCache.height(item, width: textWidth, directory: host.mediaDirectory) + footerHeight(row) + bottomSpacing(row)
    }

    private static func footerHeight(_ row: TranscriptRow) -> CGFloat {
        if case .assistant(let meta) = row.kind, meta != nil { return 8 + metaHeight }
        return 0
    }

    private static func bottomSpacing(_ row: TranscriptRow) -> CGFloat {
        if case .assistant(let meta) = row.kind, meta != nil { return TranscriptMetrics.messageSpacing }
        return 12
    }

    override var copyText: String? { item?.text }

    override func findTarget(for match: TranscriptFindMatch) -> TranscriptFindTarget? {
        match.field == .body ? findTarget(match.range, in: textView) : nil
    }

    override func layout() {
        super.layout()
        guard let item, let host else { return }
        let column = TranscriptMetrics.column(width: bounds.width)
        let textWidth = column.width - Self.textInset * 2
        let size = TranscriptText.markdownSize(item, .assistant, width: textWidth, cache: host.textCache)
        textView.frame = NSRect(x: column.x + Self.textInset, y: 0, width: textWidth, height: size.height)
        layoutCodeButtons()
        var mediaY = textView.frame.maxY
        for view in mediaViews {
            mediaY += 12
            let height = view.media.height(width: textWidth)
            view.frame = NSRect(x: column.x + Self.textInset, y: mediaY, width: textWidth, height: height)
            mediaY += height
        }
        guard meta != nil else { return }
        let y = mediaY + 8
        var x = column.x + Self.textInset
        modelLabel.sizeToFit()
        let labelWidth = min(modelLabel.frame.width, column.width * 0.6)
        modelLabel.frame = NSRect(x: x, y: y + 2, width: labelWidth, height: 16)
        x += labelWidth + 4
        copyButton.frame = NSRect(x: x, y: y, width: 22, height: Self.metaHeight)
        x += 24
        if !forkButton.isHidden {
            forkButton.frame = NSRect(x: x - 2, y: y, width: 22, height: Self.metaHeight)
            x += 22
        }
        timeLabel.sizeToFit()
        timeLabel.frame = NSRect(x: x, y: y + 2, width: timeLabel.frame.width, height: 16)
    }

    private func layoutCodeButtons() {
        guard !rendered.codeBlocks.isEmpty, let layoutManager = textView.layoutManager, let container = textView.textContainer,
            let storage = textView.textStorage
        else { return }
        layoutManager.ensureLayout(for: container)
        for (index, block) in rendered.codeBlocks.enumerated() where index < codeButtons.count {
            guard NSMaxRange(block.range) <= storage.length,
                let textBlock = (storage.attribute(.paragraphStyle, at: block.range.location, effectiveRange: nil) as? NSParagraphStyle)?
                    .textBlocks.last as? ChatCodeTextBlock
            else {
                codeButtons[index].isHidden = true
                continue
            }
            var range = block.range
            if NSMaxRange(range) < storage.length { range.length += 1 }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let frame = textBlock.boundsRect(withFrame: layoutManager.boundsRect(for: textBlock, glyphRange: glyphs))
            codeButtons[index].frame = NSRect(
                x: textView.frame.minX + frame.maxX - 28, y: textView.frame.minY + frame.minY + 3, width: 24, height: 20)
        }
    }

    @objc private func copyCode(_ sender: TranscriptIconButton) {
        guard rendered.codeBlocks.indices.contains(sender.tag) else { return }
        host?.copyToPasteboard(rendered.codeBlocks[sender.tag].code)
        sender.flashConfirmation()
    }

    @objc private func copyResponse() {
        guard let item else { return }
        host?.copyToPasteboard(item.text)
        copyButton.flashConfirmation()
    }

    @objc private func fork() {
        guard let item else { return }
        host?.forkTurn(item.id)
    }
}

// MARK: - Thumbnails

/// An attached image in a user message; opens Quick Look on click.
final class TranscriptThumbnailView: NSView {
    var onOpen: ((Int) -> Void)?
    private var path: String?
    private var index = 0
    private var loadTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.contentsGravity = .resizeAspectFill
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(path: String, index: Int) {
        self.index = index
        let name = (path as NSString).lastPathComponent
        setAccessibilityLabel(String(localized: "Preview \(name)"))
        toolTip = name
        guard path != self.path else { return }
        self.path = path
        layer?.contents = nil
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = await TranscriptImageLoader.shared.thumbnail(for: path, maxPixelSize: 320)
            guard !Task.isCancelled, let self, self.path == path else { return }
            self.layer?.contents = image
        }
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(index)
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?(index)
        return true
    }
}

/// Downsampled thumbnails for attached images, decoded off the main thread and cached.
@MainActor
final class TranscriptImageLoader {
    static let shared = TranscriptImageLoader()

    private let cache = NSCache<NSString, CGImage>()

    func thumbnail(for path: String, maxPixelSize: Int) async -> CGImage? {
        let key = "\(path)#\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .userInitiated) {
            Self.decode(path: path, maxPixelSize: maxPixelSize)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private nonisolated static func decode(path: String, maxPixelSize: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Estimates

/// Cheap height guesses for rows that are far from the viewport and not yet measured.
@MainActor
enum TranscriptEstimate {
    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let fontSize = Theme.fontSize
        let lineHeight = (fontSize * 1.55).rounded()
        let charsPerLine = max(10, width / (fontSize * 0.52))
        var lines: CGFloat = 0
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                inCode.toggle()
                lines += 1.5
                continue
            }
            lines += inCode ? 1 : max(1, ceil(CGFloat(line.count) / charsPerLine))
        }
        return lines * lineHeight
    }
}
