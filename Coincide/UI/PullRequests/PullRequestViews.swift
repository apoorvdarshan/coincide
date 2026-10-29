import AppKit
import CoincideKit

/// A small symbol button for panel headers that sits on the theme's hover fill, as the rail's buttons do.
final class PanelIconButton: NSButton {
    private var isHovered = false

    init(symbol: String, label: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        image = Theme.symbol(symbol, size: 12, weight: .medium)
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        self.target = target
        self.action = action
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        updateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var isEnabled: Bool {
        didSet { updateTint() }
    }

    override var isHighlighted: Bool {
        didSet { updateTint() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateTint()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    private func updateTint() {
        contentTintColor = !isEnabled ? .quaternaryLabelColor : isHovered ? .labelColor : .secondaryLabelColor
        let fill: NSColor? = isHighlighted ? Theme.sidebarSelection : isHovered && isEnabled ? Theme.sidebarHover : nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill?.cgColor
        }
    }
}

/// A label that wraps to whatever width layout gives it. A plain wrapping field measures its height for the width
/// it had before, so in a column that resizes it would keep the wrong number of lines.
final class WrappingLabel: NSTextField {
    convenience init(font: NSFont, color: NSColor = .labelColor) {
        self.init(wrappingLabelWithString: "")
        self.font = font
        textColor = color
        isSelectable = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    override func layout() {
        super.layout()
        guard preferredMaxLayoutWidth != bounds.width else { return }
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}

/// Buttons in a row that wraps onto more lines when the panel is too narrow for them, with the trailing space left
/// free, as the actions under a pull request's title.
final class FlowingButtonRow: NSView {
    var buttons: [NSView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            buttons.forEach(addSubview)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private let spacing: CGFloat = 8

    /// Lays the row out again after buttons were shown, hidden or retitled.
    func buttonsChanged() {
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: frames(width: bounds.width).map(\.maxY).max() ?? 0)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        for (button, frame) in zip(visibleButtons, frames(width: bounds.width)) { button.frame = frame }
    }

    private var visibleButtons: [NSView] { buttons.filter { !$0.isHidden } }

    private func frames(width: CGFloat) -> [NSRect] {
        var frames: [NSRect] = []
        var origin = NSPoint.zero
        var lineHeight: CGFloat = 0
        for button in visibleButtons {
            let size = button.intrinsicContentSize
            if origin.x > 0, origin.x + size.width > width {
                origin = NSPoint(x: 0, y: origin.y + lineHeight + spacing)
                lineHeight = 0
            }
            frames.append(NSRect(origin: origin, size: NSSize(width: min(size.width, max(width, 1)), height: size.height)))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

/// A pull request's description, rendered with the transcript's Markdown and as tall as its text at the width it
/// is given. Web links open as the transcript's do (`LinkRouting`); anything else a link could name is ignored.
final class PullRequestMarkdownView: NSView {
    private let textView = ChatTextView()
    private var rendered = NSAttributedString()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.onOpenLink = { [weak self] link in
            guard let request = link as? WebLinkRequest else { return false }
            LinkRouting.open(request, from: self?.window)
            return true
        }
        textView.setAccessibilityLabel(String(localized: "Description"))
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func setMarkdown(_ markdown: String) {
        var style = ChatMarkdownStyle(fontSize: Theme.fontSize, textColor: Theme.ink)
        style.webLinkHint = LinkRouting.hint(opensInDefaultBrowser: LinkRouting.opensInDefaultBrowser)
        rendered = ChatMarkdownRenderer.render(markdown, style: style).string
        textView.setText(rendered)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ChatTextMeasurer.shared.height(of: rendered, width: bounds.width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
    }
}

/// One check of a pull request: its status, its name, and a link to its run when it has one. The whole row opens
/// the run.
final class PullRequestCheckRow: NSControl {
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let link = NSImageView()
    private let url: URL?
    private var isHovered = false

    init(_ check: PullRequestCheck) {
        url = check.url.flatMap(URL.init(string:))
        super.init(frame: .zero)
        let glyph = PullRequestGlyph.check(check.status)
        icon.image = glyph.image(size: 12)
        icon.contentTintColor = glyph.color
        nameLabel.stringValue = check.name
        nameLabel.font = .systemFont(ofSize: Theme.fontSize - 1)
        nameLabel.textColor = Theme.ink
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        statusLabel.stringValue = glyph.label
        statusLabel.font = .systemFont(ofSize: Theme.fontSize - 2)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        link.image = Theme.symbol("arrow.up.right", size: 9, weight: .semibold)
        link.contentTintColor = .tertiaryLabelColor
        link.isHidden = url == nil
        let row = NSStackView(views: [icon, nameLabel, NSView(), statusLabel, link])
        row.spacing = 6
        row.setHuggingPriority(.init(1), for: .horizontal)
        row.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
        ])
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(url == nil ? .staticText : .button)
        setAccessibilityLabel("\(check.name), \(glyph.label)")
        toolTip = url == nil ? check.name : String(localized: "Open \(check.name) in the browser")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard url != nil else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateFill()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateFill()
    }

    /// Taken without a tracking loop, so the row gets the mouse-up and opens the run like a link.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        openRun()
    }

    override func accessibilityPerformPress() -> Bool {
        openRun()
        return url != nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func openRun() {
        guard let url else { return }
        ChangeRequestLinks.openChangeRequest(url, from: window)
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHovered ? Theme.sidebarHover.cgColor : nil
        }
    }
}

/// A pull request in the list: its state, title, checks and review on the first line; number, author and branch,
/// and how long ago it changed, on the second, as T3 Code's pull request rows.
final class PullRequestRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PullRequestRow")

    /// Opens the pull request, for VoiceOver's press as for a click on the row.
    var onPress: (() -> Void)?

    private static var titleFont: NSFont { .systemFont(ofSize: Theme.fontSize - 1, weight: .medium) }
    private static var metaFont: NSFont { .systemFont(ofSize: Theme.fontSize - 2) }

    /// Two lines in the fonts of the current text size, with room around them.
    static var height: CGFloat {
        ceil(Theme.lineHeight(of: titleFont) + Theme.lineHeight(of: metaFont)) + 20
    }

    private let stateIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let checksIcon = NSImageView()
    private let reviewIcon = NSImageView()
    private let metaLabel = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        ageLabel.textColor = .tertiaryLabelColor
        ageLabel.setContentCompressionResistancePriority(.init(400), for: .horizontal)
        for icon in [checksIcon, reviewIcon] { icon.setContentCompressionResistancePriority(.init(500), for: .horizontal) }
        let firstLine = NSStackView(views: [titleLabel, NSView(), checksIcon, reviewIcon])
        firstLine.spacing = 5
        firstLine.setHuggingPriority(.init(1), for: .horizontal)
        let secondLine = NSStackView(views: [metaLabel, NSView(), ageLabel])
        secondLine.spacing = 6
        secondLine.setHuggingPriority(.init(1), for: .horizontal)
        let lines = NSStackView(views: [firstLine, secondLine])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        for view in [stateIcon, lines] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            stateIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stateIcon.centerYAnchor.constraint(equalTo: firstLine.centerYAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 16),
            lines.leadingAnchor.constraint(equalTo: stateIcon.trailingAnchor, constant: 8),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            lines.centerYAnchor.constraint(equalTo: centerYAnchor),
            firstLine.widthAnchor.constraint(equalTo: lines.widthAnchor),
            secondLine.widthAnchor.constraint(equalTo: lines.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ pullRequest: PullRequestSummary) {
        let state = PullRequestGlyph.state(pullRequest.state, isDraft: pullRequest.isDraft)
        stateIcon.image = state.image(size: 13)
        stateIcon.contentTintColor = state.color
        titleLabel.stringValue = pullRequest.title
        titleLabel.font = Self.titleFont
        titleLabel.textColor = pullRequest.isDraft ? .secondaryLabelColor : Theme.ink
        var meta = ["#\(pullRequest.number)"]
        if pullRequest.isDraft { meta.append(String(localized: "Draft")) }
        if let author = pullRequest.author { meta.append(author) }
        meta.append(pullRequest.headBranch)
        metaLabel.stringValue = meta.joined(separator: " · ")
        metaLabel.font = Self.metaFont
        ageLabel.stringValue = pullRequest.updatedAt.map { Formatting.compactAge(of: $0) } ?? ""
        ageLabel.font = .monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .regular)
        let checks = pullRequest.checksState.map(PullRequestGlyph.checks)
        checksIcon.image = checks?.image(size: 12)
        checksIcon.contentTintColor = checks?.color
        checksIcon.toolTip = checks?.label
        checksIcon.isHidden = checks == nil
        let review = pullRequest.reviewDecision.map(PullRequestGlyph.review)
        reviewIcon.image = review?.image(size: 12)
        reviewIcon.contentTintColor = review?.color
        reviewIcon.toolTip = review?.label
        reviewIcon.isHidden = review == nil
        let spoken = [pullRequest.title, metaLabel.stringValue, state.label, checks?.label, review?.label]
        setAccessibilityLabel(spoken.compactMap(\.self).joined(separator: ", "))
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}

/// The list of pull requests: Return opens the selected one, and the context menu opens as a themed popup.
final class PullRequestTableView: NSTableView {
    var onActivate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0 {
            onActivate?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        ThemedContextMenu.show(super.menu(for: event), for: event, in: window)
    }
}
