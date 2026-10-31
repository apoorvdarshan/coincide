import AppKit
import CoincideKit

/// The rows above the projects: start a thread, and search the threads. Both are plain rows that light up on hover,
/// in the place of a toolbar button and a bordered search field.
final class SidebarHeaderView: NSView {
    static let rowHeight: CGFloat = 32

    let searchField = NSSearchField()
    private let newThreadRow: SidebarActionRow
    private let searchRow = SidebarSearchRow()

    init(onNewThread: @escaping () -> Void) {
        newThreadRow = SidebarActionRow(
            symbol: "square.and.pencil", title: String(localized: "New Thread"), action: onNewThread)
        super.init(frame: .zero)
        searchRow.field = searchField
        let stack = NSStackView(views: [newThreadRow, searchRow])
        stack.orientation = .vertical
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            newThreadRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            newThreadRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            searchRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the shortcut that starts a thread, as the menu has it.
    func setNewThreadShortcut(_ keys: String?) {
        newThreadRow.shortcut = keys
    }
}

/// A sidebar row that runs an action: a symbol, a title and, on hover, its shortcut.
final class SidebarActionRow: NSControl, PointerCursorControl {
    var shortcut: String? {
        didSet { shortcutLabel.stringValue = shortcut ?? "" }
    }

    private let icon = NSImageView()
    private let titleLabel: NSTextField
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let run: () -> Void
    private var isHovered = false
    private var isPressed = false

    init(symbol: String, title: String, action: @escaping () -> Void) {
        titleLabel = NSTextField(labelWithString: title)
        run = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        icon.image = Theme.symbol(symbol, size: 14)
        icon.contentTintColor = .labelColor
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.font = .systemFont(ofSize: 12)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.alphaValue = 0
        for view in [icon, titleLabel, shortcutLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        update()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        update()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        update()
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        update()
        if bounds.contains(convert(event.locationInWindow, from: nil)) { run() }
    }

    override func accessibilityPerformPress() -> Bool {
        run()
        return true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let fill: NSColor? = isPressed ? Theme.sidebarSelection : isHovered ? Theme.sidebarHover : nil
        layer?.backgroundColor = fill?.cgColor
    }

    private func update() {
        needsDisplay = true
        shortcutLabel.alphaValue = isHovered ? 1 : 0
    }
}

/// The search field dressed as a sidebar row: the same symbol column and title position as the rows around it,
/// with no bezel. It fills in while it has focus or holds a search.
final class SidebarSearchRow: NSView {
    var field: NSSearchField? {
        didSet {
            guard let field else { return }
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .systemFont(ofSize: 13)
            // The row draws its own magnifier, lined up with the other rows' symbols.
            (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
                field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            NotificationCenter.default.addObserver(
                self, selector: #selector(fieldChanged), name: NSControl.textDidBeginEditingNotification, object: field)
            NotificationCenter.default.addObserver(
                self, selector: #selector(fieldChanged), name: NSControl.textDidEndEditingNotification, object: field)
            NotificationCenter.default.addObserver(
                self, selector: #selector(fieldChanged), name: NSControl.textDidChangeNotification, object: field)
        }
    }

    private let icon = NSImageView()
    private var isHovered = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        icon.image = Theme.symbol("magnifyingglass", size: 14)
        icon.contentTintColor = .labelColor
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    /// A click anywhere on the row starts typing in the field.
    override func mouseDown(with event: NSEvent) {
        guard let field else { return }
        window?.makeFirstResponder(field)
    }

    @objc private func fieldChanged() {
        needsDisplay = true
    }

    private var isActive: Bool {
        guard let field else { return false }
        return field.currentEditor() != nil || !field.stringValue.isEmpty
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let fill: NSColor? = isActive ? Theme.sidebarSelection : isHovered ? Theme.sidebarHover : nil
        layer?.backgroundColor = fill?.cgColor
    }
}
