import AppKit
import CoincideKit

/// A borderless footer control: a symbol, a title and, for menus, a chevron. It highlights on hover
/// and, when it has a menu, opens it above itself on mouse-down like a pull-down button.
final class ComposerControlButton: NSButton {
    /// Builds the menu to show when pressed. Nil for plain buttons, which send their action.
    var menuProvider: (() -> NSMenu?)? {
        didSet { setAccessibilityRole(menuProvider == nil ? .button : .menuButton) }
    }
    /// Shows only the symbol, for narrow composers.
    var isCompact = false {
        didSet { if isCompact != oldValue { updateTitle() } }
    }
    /// Draws the control as switched on, like the Plan toggle.
    var isActive = false {
        didSet { updateAppearance() }
    }

    private var label = ""
    private var symbolName = ""
    private var symbolColor: NSColor?
    private var showsChevron = false
    private var isHovered = false
    private var isMenuOpen = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .imageLeading
        imageHugsTitle = true
        imageScaling = .scaleNone
        font = .systemFont(ofSize: 12, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        setContentHuggingPriority(.required, for: .horizontal)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, symbolName: String, symbolTint: NSColor? = nil, chevron: Bool) {
        guard title != label || symbolName != self.symbolName || symbolTint != symbolColor || chevron != showsChevron
        else { return }
        label = title
        self.symbolName = symbolName
        symbolColor = symbolTint
        showsChevron = chevron
        image = Theme.symbol(symbolName, size: 12, weight: .medium)
        updateTitle()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width(compact: isCompact), height: 26)
    }

    /// The width the control needs with or without its title, for fitting the footer.
    func width(compact: Bool) -> CGFloat {
        let title = titleText(compact: compact)
        let symbolWidth = image?.size.width ?? 0
        guard title.length > 0 else { return ceil(symbolWidth) + 12 }
        return ceil(symbolWidth + 5 + title.size().width) + 14
    }

    private func titleText(compact: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if !compact, !label.isEmpty {
            text.append(NSAttributedString(string: label, attributes: [.font: font ?? .systemFont(ofSize: 12)]))
        }
        if showsChevron {
            let chevron = NSTextAttachment()
            chevron.image = Theme.symbol("chevron.down", size: 8, weight: .bold)
            if text.length > 0 { text.append(NSAttributedString(string: " ")) }
            text.append(NSAttributedString(attachment: chevron))
        }
        return text
    }

    private func updateTitle() {
        let text = titleText(compact: isCompact)
        attributedTitle = text
        imagePosition = text.length == 0 ? .imageOnly : .imageLeading
        updateAppearance()
        invalidateIntrinsicContentSize()
    }

    private func updateAppearance() {
        let emphasized = isHovered || isMenuOpen || isHighlighted
        let textColor: NSColor = isActive ? .controlAccentColor : emphasized ? .labelColor : .secondaryLabelColor
        if attributedTitle.length > 0 {
            let text = NSMutableAttributedString(attributedString: attributedTitle)
            text.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: 0, length: text.length))
            super.attributedTitle = text
        }
        contentTintColor = isActive ? .controlAccentColor : symbolColor ?? textColor
        let background: NSColor? =
            if isMenuOpen || isHighlighted {
                NSColor.labelColor.withAlphaComponent(0.12)
            } else if isActive {
                NSColor.controlAccentColor.withAlphaComponent(isHovered ? 0.2 : 0.14)
            } else if isHovered, isEnabled {
                NSColor.labelColor.withAlphaComponent(0.07)
            } else {
                nil
            }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = background?.cgColor
        }
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard menuProvider != nil, isEnabled else { return super.mouseDown(with: event) }
        showMenu()
    }

    override func performClick(_ sender: Any?) {
        guard menuProvider != nil else { return super.performClick(sender) }
        showMenu()
    }

    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }

    /// Briefly washes the control in `color`, to draw the eye to a change such as a new agent.
    func flash(_ color: NSColor) {
        guard let layer else { return }
        var start: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { start = color.withAlphaComponent(0.3).cgColor }
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = start
        animation.toValue = layer.backgroundColor ?? NSColor.clear.cgColor
        animation.duration = 0.8
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "flash")
    }

    /// Opens the control's menu just above it.
    func showMenu() {
        guard let menu = menuProvider?(), let window else { return }
        let frame = window.convertToScreen(convert(bounds, to: nil))
        isMenuOpen = true
        updateAppearance()
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.maxY + menu.size.height + 4), in: nil)
        isMenuOpen = false
        isHovered = false
        updateAppearance()
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}

/// The round primary button: sends, queues while a turn runs, or stops the turn.
final class ComposerSendButton: NSButton {
    enum Mode {
        case send
        case queue
        case stop
    }

    var mode: Mode = .send {
        didSet { if mode != oldValue { update() } }
    }

    override var isEnabled: Bool {
        didSet { update() }
    }

    override var isHighlighted: Bool {
        didSet { update() }
    }

    static let side: CGFloat = 28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    private func update() {
        let symbol =
            switch mode {
            case .send: "arrow.up"
            case .queue: "text.line.last.and.arrowtriangle.forward"
            case .stop: "stop.fill"
            }
        image = Theme.symbol(symbol, size: mode == .stop ? 10 : 12, weight: .bold)
        let fill: NSColor =
            if !isEnabled {
                NSColor.labelColor.withAlphaComponent(0.1)
            } else if mode == .stop {
                .labelColor
            } else {
                .controlAccentColor
            }
        contentTintColor = !isEnabled ? .tertiaryLabelColor : mode == .stop ? .windowBackgroundColor : .white
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.withAlphaComponent(isHighlighted ? fill.alphaComponent * 0.75 : fill.alphaComponent).cgColor
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// How full the context window is, drawn as a ring. Clicking it shows token counts and cost.
final class ComposerContextMeter: NSButton {
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private var usage = TokenUsage()
    private var contextWindow: Int?
    private var fraction: Double? {
        guard let used = usage.inputTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(used) / Double(contextWindow))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        wantsLayer = true
        for shape in [track, progress] {
            shape.fillColor = nil
            shape.lineWidth = 2.5
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        target = self
        action = #selector(showDetails)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }

    func update(usage: TokenUsage, contextWindow: Int?) {
        self.usage = usage
        self.contextWindow = contextWindow
        let summary = Self.summary(usage: usage, contextWindow: contextWindow)
        toolTip = summary
        setAccessibilityLabel(summary)
        needsLayout = true
        updateColors()
    }

    override func layout() {
        super.layout()
        // A full turn from 12 o'clock, clockwise on screen whichever way the view's y axis points.
        let path = CGMutablePath()
        let start: CGFloat = isFlipped ? -.pi / 2 : .pi / 2
        path.addArc(
            center: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 6, startAngle: start,
            endAngle: start + (isFlipped ? 2 : -2) * .pi, clockwise: !isFlipped)
        for shape in [track, progress] {
            shape.frame = bounds
            shape.path = path
        }
        progress.strokeEnd = fraction ?? 0
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let value = fraction ?? 0
        let color: NSColor = value > 0.9 ? .systemRed : value > 0.75 ? .systemOrange : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.35).cgColor
            progress.strokeColor = color.cgColor
        }
    }

    @objc private func showDetails() {
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSViewController()
        controller.view = detailsView()
        popover.contentViewController = controller
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    private func detailsView() -> NSView {
        let title = NSTextField(labelWithString: String(localized: "Context window"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let headline = NSTextField(labelWithString: Self.headline(usage: usage, contextWindow: contextWindow))
        headline.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        headline.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, NSView(), headline])
        header.orientation = .horizontal
        var rows: [NSView] = [header]
        if let fraction {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = false
            bar.controlSize = .small
            bar.minValue = 0
            bar.maxValue = 1
            bar.doubleValue = fraction
            rows.append(bar)
        }
        let details: [(String, String?)] = [
            (String(localized: "Output tokens"), usage.outputTokens.map(Self.formatTokens)),
            (String(localized: "Cached input"), usage.cachedInputTokens.map(Self.formatTokens)),
            (String(localized: "Cost"), usage.costUSD.map(Self.formatCost)),
        ]
        for (name, value) in details {
            guard let value else { continue }
            let nameLabel = NSTextField(labelWithString: name)
            let valueLabel = NSTextField(labelWithString: value)
            for label in [nameLabel, valueLabel] {
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                label.textColor = .secondaryLabelColor
            }
            let row = NSStackView(views: [nameLabel, NSView(), valueLabel])
            row.orientation = .horizontal
            rows.append(row)
        }
        let note = NSTextField(wrappingLabelWithString: String(localized: "Agents compact their context automatically when it fills up."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        rows.append(note)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return stack
    }

    // MARK: Formatting

    static func formatTokens(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<10_000: String(format: "%.1fk", Double(value) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        case ..<999_500: "\(Int((Double(value) / 1_000).rounded()))k"
        default: String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }

    static func formatCost(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value > 0 && value < 0.01 ? 4 : 2)))
    }

    private static func headline(usage: TokenUsage, contextWindow: Int?) -> String {
        let used = formatTokens(usage.inputTokens ?? 0)
        guard let contextWindow, contextWindow > 0 else { return used }
        let percent = Double(usage.inputTokens ?? 0) / Double(contextWindow)
        return "\(percent.formatted(.percent.precision(.fractionLength(0)))) · \(used)/\(formatTokens(contextWindow))"
    }

    static func summary(usage: TokenUsage, contextWindow: Int?) -> String {
        let used = formatTokens(usage.inputTokens ?? 0)
        guard let contextWindow, contextWindow > 0 else {
            return String(localized: "Context window: \(used) tokens used")
        }
        let percent = min(1, Double(usage.inputTokens ?? 0) / Double(contextWindow))
            .formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "Context window: \(percent) used (\(used) of \(formatTokens(contextWindow)) tokens)")
    }
}
