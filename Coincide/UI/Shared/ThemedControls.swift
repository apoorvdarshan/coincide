import AppKit
import CoincideKit

/// A rounded button drawn in the theme instead of the system bezel. Primary buttons are filled with the text color,
/// destructive ones with red, and secondary ones sit on the theme's raised fill with a border.
final class ThemedButton: NSButton {
    enum Style {
        case primary
        case secondary
        case plain
    }

    var style: Style = .secondary {
        didSet { needsDisplay = true }
    }
    /// Fully rounded ends, for a floating pill such as Jump to Latest.
    var isCapsule = false {
        didSet { needsDisplay = true }
    }

    private var isHovered = false

    convenience init(title: String, style: Style, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.style = style
        self.target = target
        self.action = action
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        font = .systemFont(ofSize: 13, weight: .medium)
        focusRingType = .default
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 13)])
        let imageWidth = image.map { $0.size.width + 6 } ?? 0
        return NSSize(width: ceil(text.width + imageWidth) + 28, height: 28)
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    /// The button paints its own fill across its bounds, so its frame must be exactly the size it is laid out at: the
    /// default push style's alignment insets would make the frame, and the fill, larger than the layout allows for.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = isCapsule ? bounds.height / 2 : 8
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let destructive = hasDestructiveAction && style == .primary
        let fill: NSColor?
        let text: NSColor
        switch style {
        case .primary:
            fill = destructive ? .systemRed : Theme.ink
            text = destructive ? .white : Theme.contentBackground
        case .secondary:
            fill = Theme.raisedFill
            text = Theme.ink
        case .plain:
            fill = isHovered ? Theme.sidebarHover : nil
            text = hasDestructiveAction ? .systemRed : .secondaryLabelColor
        }
        if let fill {
            var color = fill
            if isHighlighted { color = fill.blended(withFraction: 0.2, of: .black) ?? fill }
            if isHovered, style != .plain, !isHighlighted { color = fill.blended(withFraction: 0.08, of: style == .primary ? .gray : .white) ?? fill }
            color.withAlphaComponent(isEnabled ? 1 : 0.5).setFill()
            path.fill()
        }
        if style == .secondary {
            Theme.surfaceBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: text.withAlphaComponent(isEnabled ? 1 : 0.5),
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        var x = (bounds.width - size.width) / 2
        if let image {
            let imageSize = image.size
            x += (imageSize.width + 6) / 2
            let imageRect = NSRect(
                x: x - imageSize.width - 6, y: (bounds.height - imageSize.height) / 2, width: imageSize.width,
                height: imageSize.height)
            let tinted = NSImage(size: imageSize, flipped: false) { rect in
                image.draw(in: rect)
                text.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: imageRect)
        }
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// A checkbox drawn in the theme: a rounded square that fills with the text color and shows a check when on. As a
/// radio button it is a circle with a dot.
final class ThemedCheckbox: NSButton {
    private var isRadio = false

    convenience init(label title: String, target: AnyObject?, action: Selector?, radio: Bool = false) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        if radio {
            isRadio = true
            setButtonType(.radio)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.switch)
        isBordered = false
        font = .systemFont(ofSize: 13)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 13)])
        return NSSize(width: ceil(text.width) + 26, height: max(18, ceil(text.height)))
    }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 1, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let path =
            isRadio
            ? NSBezierPath(ovalIn: box.insetBy(dx: 0.5, dy: 0.5))
            : NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        if isRadio, state == .on {
            Theme.ink.setFill()
            path.fill()
            Theme.contentBackground.setFill()
            NSBezierPath(ovalIn: box.insetBy(dx: 5, dy: 5)).fill()
        } else if state == .on {
            Theme.ink.setFill()
            path.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 4, y: box.midY))
            check.line(to: NSPoint(x: box.minX + 7, y: box.midY + (isFlipped ? 3 : -3)))
            check.line(to: NSPoint(x: box.maxX - 3.5, y: box.midY + (isFlipped ? -3.5 : 3.5)))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            Theme.contentBackground.setStroke()
            check.stroke()
        } else {
            Theme.raisedFill.setFill()
            path.fill()
            Theme.surfaceBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13), .foregroundColor: isEnabled ? Theme.ink : NSColor.tertiaryLabelColor,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: box.maxX + 8, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

/// An alert in the app's theme, with the parts of `NSAlert` the app uses: a message, informative text, buttons (the
/// first is the default, a "Cancel" one answers Escape), an optional "don't ask again" checkbox, and running modally
/// or as a sheet. Responses use `NSAlert`'s values.
final class ThemedAlert: NSObject {
    var messageText = ""
    var informativeText = ""
    var alertStyle: NSAlert.Style = .warning
    var showsSuppressionButton = false
    private(set) var buttons: [ThemedButton] = []
    private(set) lazy var suppressionButton: NSButton? = ThemedCheckbox(
        title: String(localized: "Don’t ask again"), target: nil, action: nil)

    private var panel: ThemedAlertPanel?
    private var sheetParent: NSWindow?
    /// Holds the alert while it shows, as `NSAlert` does, so callers can let go of it after presenting.
    private var presented: ThemedAlert?

    override init() {
        super.init()
    }

    /// An alert describing `error`, as `NSAlert(error:)` makes one.
    convenience init(error: Error) {
        self.init()
        let error = error as NSError
        messageText = error.localizedDescription
        informativeText = error.localizedRecoverySuggestion ?? error.localizedFailureReason ?? ""
        alertStyle = .critical
    }

    @discardableResult
    func addButton(withTitle title: String) -> ThemedButton {
        let button = ThemedButton(title: title, style: buttons.isEmpty ? .primary : .secondary, target: self, action: #selector(buttonPressed(_:)))
        button.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + buttons.count
        if buttons.isEmpty { button.keyEquivalent = "\r" }
        if title == String(localized: "Cancel") { button.keyEquivalent = "\u{1b}" }
        buttons.append(button)
        return button
    }

    @discardableResult
    func runModal() -> NSApplication.ModalResponse {
        let panel = makePanel()
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2, y: parent.frame.midY - panel.frame.height / 2 + 80))
        } else {
            panel.center()
        }
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return response
    }

    func beginSheetModal(for window: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        let panel = makePanel()
        sheetParent = window
        window.beginSheet(panel) { response in completionHandler?(response) }
    }

    private func makePanel() -> ThemedAlertPanel {
        if buttons.isEmpty { addButton(withTitle: String(localized: "OK")) }
        let title = NSTextField(wrappingLabelWithString: messageText)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Theme.ink
        let info = NSTextField(wrappingLabelWithString: informativeText)
        info.font = .systemFont(ofSize: 13)
        info.textColor = .secondaryLabelColor
        info.isHidden = informativeText.isEmpty
        info.isSelectable = true
        let icon = NSImageView(
            image: Theme.symbol(alertStyle == .critical ? "exclamationmark.triangle.fill" : "questionmark.circle", size: 20)
                ?? NSImage())
        icon.contentTintColor = alertStyle == .critical ? .systemRed : .secondaryLabelColor
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        // The default button sits at the trailing end, as in macOS alerts.
        buttonRow.setViews(buttons.reversed(), in: .trailing)
        var rows: [NSView] = [icon, title, info]
        if showsSuppressionButton, let suppressionButton { rows.append(suppressionButton) }
        rows.append(buttonRow)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: rows[rows.count - 2])
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(equalToConstant: 336),
            info.widthAnchor.constraint(equalTo: title.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: title.widthAnchor),
        ])
        let surface = FlatSurfaceView(style: .floating)
        surface.cornerRadius = 16
        surface.contentView = stack
        let panel = ThemedAlertPanel()
        panel.contentView = surface
        panel.setContentSize(stack.fittingSize)
        panel.onCancel = { [weak self] in self?.cancel() }
        if let first = buttons.first { panel.defaultButtonCell = first.cell as? NSButtonCell }
        self.panel = panel
        presented = self
        return panel
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        finish(NSApplication.ModalResponse(rawValue: sender.tag))
    }

    /// Escape answers with the Cancel button, or the last button when there is none.
    private func cancel() {
        let cancel = buttons.first { $0.title == String(localized: "Cancel") } ?? buttons.last
        if let cancel { finish(NSApplication.ModalResponse(rawValue: cancel.tag)) }
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard let panel else { return }
        if let parent = sheetParent {
            parent.endSheet(panel, returnCode: response)
        } else {
            NSApp.stopModal(withCode: response)
        }
        self.panel = nil
        presented = nil
    }
}

/// The alert's window: borderless and see-through outside its rounded surface.
final class ThemedAlertPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// A list row whose selection is the theme's soft fill, never the system's accent or its emphasized look, so the
/// row's text keeps its colors when selected. Tables using it must not use the source-list style, whose selection is a
/// system material drawn outside the row view.
final class ThemedTableRowView: NSTableRowView {
    private let inset: CGFloat

    init(inset: CGFloat = 6) {
        self.inset = inset
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        Theme.sidebarSelection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

/// A thin bar showing how full something is, on a quiet track, in place of the system's accent-colored progress bar.
final class ThemedProgressBar: NSView {
    var fraction: CGFloat {
        didSet { needsDisplay = true }
    }

    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(fraction: CGFloat, color: NSColor) {
        self.fraction = fraction
        self.color = color
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }

    override func accessibilityValue() -> Any? { NSNumber(value: Double(fraction)) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        Theme.sidebarSelection.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let width = bounds.width * min(max(fraction, 0), 1)
        guard width > 0 else { return }
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(width, bounds.height), height: bounds.height), xRadius: radius, yRadius: radius)
            .fill()
    }
}

/// A text field in the app's theme: a rounded raised fill with a border, in place of the system's bezel.
final class ThemedTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { ThemedTextFieldCell.self }
        set {}
    }

    convenience init(placeholder: String, monospaced: Bool = false) {
        self.init(frame: .zero)
        placeholderString = placeholder
        font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        layer.backgroundColor = Theme.raisedFill.cgColor
        let focused = currentEditor() != nil
        layer.borderWidth = focused ? 1.5 : 1
        layer.borderColor = (focused ? Theme.ink.withAlphaComponent(0.45) : Theme.surfaceBorder).cgColor
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        needsDisplay = true
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        needsDisplay = true
    }
}

/// Keeps the text of a `ThemedTextField` clear of its rounded edges, while drawing and while editing.
final class ThemedTextFieldCell: NSTextFieldCell {
    private func inset(_ rect: NSRect) -> NSRect {
        let lineHeight = (font ?? .systemFont(ofSize: 13)).boundingRectForFont.height.rounded(.up)
        let y = rect.minY + max(0, (rect.height - lineHeight) / 2)
        return NSRect(x: rect.minX + 8, y: y, width: rect.width - 16, height: min(lineHeight, rect.height))
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { inset(super.drawingRect(forBounds: rect)) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inset(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int,
        length selLength: Int
    ) {
        super.select(withFrame: inset(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}
