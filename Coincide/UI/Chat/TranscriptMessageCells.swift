import AppKit
import CoincideKit
import QuartzCore

// MARK: - User message

/// The user's message: a right-aligned bubble with image thumbnails, long text folded behind
/// "Show full message", and copy / edit / revert actions that appear on hover.
final class TranscriptUserCell: TranscriptCell {
    private static let padding: CGFloat = 12
    private static let collapsedTextHeight: CGFloat = 176
    private static let thumbnailGap: CGFloat = 8

    private let bubble = TranscriptBubbleView()
    private let textView = ChatTextView()
    private var thumbnails: [TranscriptThumbnailView] = []
    private let toggleButton = NSButton(title: "", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "")
    private lazy var editButton = TranscriptIconButton(
        symbol: "pencil", label: String(localized: "Edit and resend"), action: #selector(edit), target: self)
    private lazy var revertButton = TranscriptIconButton(
        symbol: "arrow.uturn.backward", label: String(localized: "Revert to before this message"), action: #selector(revert), target: self)
    private lazy var copyButton = TranscriptIconButton(
        symbol: "doc.on.doc", label: String(localized: "Copy message"), action: #selector(copyMessage), target: self)
    private var isHovered = false
    private var item: TranscriptItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 16
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
        timeLabel.alignment = .right
        for view in [timeLabel, editButton, revertButton, copyButton] as [NSView] {
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
        timeLabel.stringValue = TranscriptFormat.timestamp(item.createdAt)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .regular)
        timeLabel.toolTip = TranscriptFormat.fullTimestamp(item.createdAt)
        let running = host.isThreadRunning
        editButton.isEnabled = !running
        revertButton.isHidden = !host.canRevert(item.id)
        revertButton.isEnabled = !running
        setAccessibilityLabel(String(localized: "You"))
        updateActionsVisibility(animated: false)
    }

    override class var measuresText: Bool { true }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        return layout(for: item, row: row, width: width, host: host).height
    }

    override class func estimatedHeight(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        let content = TranscriptMetrics.column(width: width).width * 0.8 - padding * 2
        let text = TranscriptEstimate.textHeight(item.text, width: content)
        let images = (item.attachments ?? []).isEmpty ? 0 : CGFloat(((item.attachments?.count ?? 0) + 1) / 2) * 86
        return min(text, collapsedTextHeight + 24) + images + padding * 2 + 28 + bottomSpacing(for: row)
    }

    override var copyText: String? { item?.text }

    private struct Layout {
        var bubble: NSRect
        var thumbnails: [NSRect]
        var text: NSRect
        var toggle: NSRect?
        var actionsY: CGFloat
        var height: CGFloat
        var isCollapsed: Bool
    }

    static func shouldCollapse(_ text: String) -> Bool {
        text.count > 600 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 8
    }

    private static func layout(for item: TranscriptItem, row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> Layout {
        let column = TranscriptMetrics.column(width: width)
        let maxBubble = (column.width * 0.8).rounded(.down)
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
        var y = padding
        if let last = thumbnails.last { y = last.maxY + (hasText ? thumbnailGap : 0) }
        let textHeight = isCollapsed ? collapsedTextHeight : textSize.height
        let text = NSRect(x: padding, y: y, width: min(maxContent, textSize.width + 1), height: textHeight)
        y += hasText ? textHeight : 0
        var toggle: NSRect?
        var contentWidth = max(text.width, thumbnails.map { $0.maxX - padding }.max() ?? 0)
        if canCollapse {
            toggle = NSRect(x: padding - 4, y: y + 6, width: 130, height: 18)
            y += 24
            contentWidth = max(contentWidth, 126)
        }
        let bubbleWidth = min(maxBubble, ceil(contentWidth) + padding * 2)
        let bubble = NSRect(x: column.x + column.width - bubbleWidth, y: 0, width: bubbleWidth, height: y + padding)
        let actionsY = bubble.maxY + 4
        return Layout(
            bubble: bubble, thumbnails: thumbnails, text: text, toggle: toggle, actionsY: actionsY,
            height: actionsY + 20 + bottomSpacing(for: row) - 4, isCollapsed: isCollapsed)
    }

    override func layout() {
        super.layout()
        guard let row, let item, let host else { return }
        let layout = Self.layout(for: item, row: row, width: bounds.width, host: host)
        bubble.frame = layout.bubble
        textView.frame = layout.text
        for (index, frame) in layout.thumbnails.enumerated() where index < thumbnails.count {
            thumbnails[index].frame = frame
        }
        toggleButton.isHidden = layout.toggle == nil
        if let toggle = layout.toggle {
            toggleButton.frame = toggle
            toggleButton.title = layout.isCollapsed ? String(localized: "Show full message") : String(localized: "Show less")
            toggleButton.alignment = .left
        }
        updateFade(collapsed: layout.isCollapsed)
        let column = TranscriptMetrics.column(width: bounds.width)
        var x = column.x + column.width
        for button in [copyButton, revertButton, editButton] where !button.isHidden {
            x -= 22
            button.frame = NSRect(x: x, y: layout.actionsY, width: 22, height: 20)
        }
        timeLabel.sizeToFit()
        let timeWidth = ceil(timeLabel.frame.width)
        timeLabel.frame = NSRect(x: x - timeWidth - 6, y: layout.actionsY + 2, width: timeWidth, height: 16)
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
        let views = [timeLabel, editButton, revertButton, copyButton] as [NSView]
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

    @objc private func edit() {
        guard let item else { return }
        host?.editMessage(item.id)
    }

    @objc private func revert() {
        guard let item else { return }
        host?.revertTurn(item.id)
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

/// An agent reply rendered as Markdown. Code blocks get copy buttons; the turn's final reply ends
/// with which provider and model answered, a copy button and the time.
final class TranscriptAssistantCell: TranscriptCell {
    private static let textInset: CGFloat = 4
    private static let metaHeight: CGFloat = 20

    private let textView = ChatTextView()
    private var codeButtons: [TranscriptIconButton] = []
    private var rendered = ChatRenderedText.empty
    private let providerIcon = NSImageView()
    private let modelLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private lazy var copyButton = TranscriptIconButton(
        symbol: "doc.on.doc", label: String(localized: "Copy response"), action: #selector(copyResponse), target: self)
    private var item: TranscriptItem?
    private var meta: AssistantMeta?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(textView)
        providerIcon.imageScaling = .scaleProportionallyDown
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.lineBreakMode = .byTruncatingTail
        timeLabel.textColor = .tertiaryLabelColor
        for view in [providerIcon, modelLabel, timeLabel, copyButton] as [NSView] { addSubview(view) }
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
        rendered = TranscriptText.markdown(item, .assistant, cache: host.textCache)
        textView.setText(rendered)
        textView.onOpenLink = { [weak host] link in host?.openLink(link) ?? false }
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
        for view in [providerIcon, modelLabel, timeLabel, copyButton] as [NSView] { view.isHidden = !showsMeta }
        if let meta {
            providerIcon.image = Theme.symbol(meta.provider.symbolName, size: 11, weight: .semibold)
            providerIcon.contentTintColor = Theme.color(for: meta.provider)
            modelLabel.stringValue = host.modelLabel(for: meta)
            modelLabel.font = .systemFont(ofSize: Theme.fontSize - 2, weight: .medium)
            let date = item.completedAt ?? item.createdAt
            timeLabel.stringValue = TranscriptFormat.timestamp(date)
            timeLabel.toolTip = TranscriptFormat.fullTimestamp(date)
            timeLabel.font = .monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .regular)
        }
        setAccessibilityLabel(meta.map { host.modelLabel(for: $0) } ?? item.provider?.displayName ?? String(localized: "Agent"))
    }

    override class var measuresText: Bool { true }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        let textWidth = TranscriptMetrics.column(width: width).width - textInset * 2
        let size = TranscriptText.markdownSize(item, .assistant, width: textWidth, cache: host.textCache)
        return size.height + footerHeight(row) + bottomSpacing(row)
    }

    override class func estimatedHeight(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id) else { return 0 }
        let textWidth = TranscriptMetrics.column(width: width).width - textInset * 2
        return TranscriptEstimate.textHeight(item.text, width: textWidth) + footerHeight(row) + bottomSpacing(row)
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

    override func layout() {
        super.layout()
        guard let item, let host else { return }
        let column = TranscriptMetrics.column(width: bounds.width)
        let textWidth = column.width - Self.textInset * 2
        let size = TranscriptText.markdownSize(item, .assistant, width: textWidth, cache: host.textCache)
        textView.frame = NSRect(x: column.x + Self.textInset, y: 0, width: textWidth, height: size.height)
        layoutCodeButtons()
        guard meta != nil else { return }
        let y = textView.frame.maxY + 8
        var x = column.x + Self.textInset
        providerIcon.frame = NSRect(x: x, y: y + 2, width: 14, height: 16)
        x += 18
        modelLabel.sizeToFit()
        let labelWidth = min(modelLabel.frame.width, column.width * 0.6)
        modelLabel.frame = NSRect(x: x, y: y + 2, width: labelWidth, height: 16)
        x += labelWidth + 4
        copyButton.frame = NSRect(x: x, y: y, width: 22, height: Self.metaHeight)
        x += 24
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
