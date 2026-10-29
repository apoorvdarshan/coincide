import AppKit
import CoincideKit

/// The browser panel's tabs: a compact themed strip with a close button on the selected tab (and on others while the
/// pointer is over them), middle-click to close, and a new-tab button at the end.
final class PreviewTabStrip: NSView {
    struct Tab: Equatable {
        var id: String
        var title: String
        var isActive: Bool
        var isLoading: Bool
    }

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onNew: (() -> Void)?
    /// Whether ⌘W and ⌘T reach the panel, for the buttons' tooltips.
    var shortcutsActive = false { didSet { if shortcutsActive != oldValue { updateTooltips() } } }
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private(set) lazy var newButton = PanelIconButton(symbol: "plus", label: String(localized: "New Tab"), target: self, action: #selector(newTab))
    private(set) var buttons: [PreviewTabButton] = []
    private var widths: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        newButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(newButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            newButton.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 2),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 1),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            document.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        // The scroll view takes the room the tabs need, up to the strip's width.
        let fit = scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        fit.priority = .defaultHigh
        fit.isActive = true
        scroll.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -30).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(String(localized: "Tabs"))
        updateTooltips()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ tabs: [Tab]) {
        while buttons.count > tabs.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < tabs.count {
            let button = PreviewTabButton()
            button.onSelect = { [weak self, weak button] in if let id = button?.tabID { self?.onSelect?(id) } }
            button.onClose = { [weak self, weak button] in if let id = button?.tabID { self?.onClose?(id) } }
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        for (button, tab) in zip(buttons, tabs) { button.show(tab) }
        updateTooltips()
        needsLayout = true
        if let active = buttons.first(where: \.isActive) { active.scrollToVisible(active.bounds) }
    }

    override func layout() {
        // Tabs share the strip, between a readable minimum and a comfortable maximum; past that the strip scrolls.
        let available = max(0, bounds.width - 32)
        let width = buttons.isEmpty ? 0 : min(180, max(84, (available - CGFloat(buttons.count - 1) * 2) / CGFloat(buttons.count)))
        for button in buttons { button.width = width }
        super.layout()
    }

    private func updateTooltips() {
        newButton.toolTip = shortcutsActive ? String(localized: "New Tab ⌘T") : String(localized: "New Tab")
        for button in buttons { button.closeTooltip = shortcutsActive ? String(localized: "Close Tab ⌘W") : String(localized: "Close Tab") }
    }

    @objc private func newTab() { onNew?() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One tab: its title (or a spinner's worth of "Loading…"), a close button, selection and hover fills.
final class PreviewTabButton: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var tabID = ""
    private(set) var isActive = false
    private var isHovered = false
    private let title = NSTextField(labelWithString: "")
    private(set) lazy var close: NSButton = {
        let button = NSButton(image: Theme.symbol("xmark", size: 8, weight: .bold) ?? NSImage(), target: self, action: #selector(closeTab))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(String(localized: "Close Tab"))
        return button
    }()
    var closeTooltip = "" { didSet { close.toolTip = closeTooltip } }
    private var widthConstraint: NSLayoutConstraint!
    var width: CGFloat {
        get { widthConstraint.constant }
        set { if widthConstraint.constant != newValue { widthConstraint.constant = newValue } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        title.font = .systemFont(ofSize: 11.5)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [title, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        widthConstraint = widthAnchor.constraint(equalToConstant: 140)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: 26),
            close.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 4),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ tab: PreviewTabStrip.Tab) {
        tabID = tab.id
        isActive = tab.isActive
        let name = tab.title.isEmpty ? (tab.isLoading ? String(localized: "Loading…") : String(localized: "New Tab")) : tab.title
        title.stringValue = name
        title.textColor = tab.isActive ? Theme.ink : .secondaryLabelColor
        toolTip = name
        setAccessibilityLabel(name)
        setAccessibilityValue(tab.isActive)
        refresh()
    }

    private func refresh() {
        close.isHidden = !(isActive || isHovered)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = (isActive ? Theme.sidebarSelection : isHovered ? Theme.sidebarHover : .clear).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { isHovered = false; refresh() }
    override func mouseDown(with event: NSEvent) { onSelect?() }

    /// A middle-click closes the tab, as in other browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() } else { super.otherMouseUp(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    @objc private func closeTab() { onClose?() }
}

/// The browser panel's background view, which takes the panel's shortcuts while focus is inside it.
final class PreviewPanelView: SolidBackgroundView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Whether the key window's focus is in this panel: one of its views, or the field editor of one of its fields.
    var containsFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let view = responder as? NSView, view.isDescendant(of: self) {
            if let editor = view as? NSTextView, editor.isFieldEditor { return true }
            return true
        }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            return field.isDescendant(of: self)
        }
        return false
    }
}
