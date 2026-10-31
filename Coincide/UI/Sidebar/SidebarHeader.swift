import AppKit
import CoincideKit

/// The rows above the projects: start a thread, search the threads, and every schedule. They are plain rows that light
/// up on hover, in the place of toolbar buttons and a bordered search field.
final class SidebarHeaderView: NSView {
    static let rowHeight: CGFloat = 32

    let searchField = NSSearchField()
    private let newThreadRow: SidebarActionRow
    private let searchRow = SidebarSearchRow()
    /// Opens the Scheduled panel; lit while it shows, with how many schedules are active.
    let schedulesRow: SidebarActionRow

    init(onNewThread: @escaping () -> Void, onSchedules: @escaping () -> Void = {}) {
        newThreadRow = SidebarActionRow(
            symbol: "square.and.pencil", title: String(localized: "New Thread"), action: onNewThread)
        schedulesRow = SidebarActionRow(symbol: "clock", title: String(localized: "Scheduled"), action: onSchedules)
        super.init(frame: .zero)
        searchRow.field = searchField
        let stack = NSStackView(views: [newThreadRow, searchRow, schedulesRow])
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
            schedulesRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            newThreadRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            searchRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            schedulesRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the shortcut that starts a thread, as the menu has it.
    func setNewThreadShortcut(_ keys: String?) {
        newThreadRow.shortcut = keys
    }

    /// The Scheduled row's shortcut, its count of active schedules and whether the panel shows.
    func setSchedules(shortcut: String?, active: Int, isOpen: Bool) {
        schedulesRow.shortcut = shortcut
        schedulesRow.count = active > 0 ? "\(active)" : nil
        schedulesRow.isActive = isOpen
    }
}

/// A sidebar row that runs an action: a symbol, a title and, on hover, its shortcut. A count, such as the active
/// schedules', shows in the shortcut's place until the pointer is over the row.
final class SidebarActionRow: NSControl, PointerCursorControl {
    var shortcut: String? {
        didSet { update() }
    }
    var count: String? {
        didSet { update() }
    }
    /// Lit like a selected row while what it opens shows.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            setAccessibilitySelected(isActive)
            needsDisplay = true
        }
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
        let fill: NSColor? = isPressed || isActive ? Theme.sidebarSelection : isHovered ? Theme.sidebarHover : nil
        layer?.backgroundColor = fill?.cgColor
    }

    private func update() {
        needsDisplay = true
        let showsCount = !isHovered || shortcut == nil
        shortcutLabel.stringValue = (showsCount ? count : shortcut) ?? ""
        shortcutLabel.alphaValue = isHovered || (showsCount && count != nil) ? 1 : 0
        shortcutLabel.font = showsCount && count != nil ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
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
