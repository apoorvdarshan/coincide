import AppKit
import CoincideKit

// MARK: - Panel

/// A popup in the app's theme: a borderless child panel on a flat surface, in place of the system's menus. It opens
/// next to a control, takes the keyboard while it is up, and closes when it loses focus or Escape is pressed. One opened
/// from inside another, such as a context menu over the model picker's list, rides above it and hands the keyboard
/// back when it closes.
final class ThemedPopup: NSObject {
    private static var current: ThemedPopup?

    private let panel: ThemedPopupPanel
    private let content: NSViewController & ThemedPopupContent
    private weak var parent: NSWindow?
    private var onClose: (() -> Void)?
    private var isClosing = false
    /// The popup opened from inside this one, which stays open under it.
    private var child: ThemedPopup?
    /// The popup this one was opened from.
    private weak var host: ThemedPopup?

    private init(content: NSViewController & ThemedPopupContent, over parent: NSWindow) {
        self.content = content
        panel = ThemedPopupPanel(over: parent)
        super.init()
    }

    /// Opens `content` beside `anchor`: above it when it fits there and `preferAbove` is set, otherwise below, and
    /// always on the anchor's screen.
    @discardableResult
    static func show(
        _ content: NSViewController & ThemedPopupContent, from anchor: NSView, rect: NSRect? = nil, preferAbove: Bool = true,
        onClose: (() -> Void)? = nil
    ) -> ThemedPopup? {
        guard let window = anchor.window else { return nil }
        let frame = window.convertToScreen(anchor.convert(rect ?? anchor.bounds, to: nil))
        return show(content, anchorRect: frame, in: window, preferAbove: preferAbove, onClose: onClose)
    }

    /// Opens `content` at a point on screen, as a context menu opens under the pointer.
    @discardableResult
    static func show(
        _ content: NSViewController & ThemedPopupContent, at point: NSPoint, in window: NSWindow, onClose: (() -> Void)? = nil
    ) -> ThemedPopup? {
        show(content, anchorRect: NSRect(origin: point, size: .zero), in: window, preferAbove: false, onClose: onClose)
    }

    private static func show(
        _ content: NSViewController & ThemedPopupContent, anchorRect: NSRect, in window: NSWindow, preferAbove: Bool,
        onClose: (() -> Void)?
    ) -> ThemedPopup? {
        let popup = ThemedPopup(content: content, over: window)
        popup.parent = window
        popup.onClose = onClose
        var host = current
        while let candidate = host, candidate.panel !== window { host = candidate.child }
        if let host {
            host.child?.close(refocus: false)
            host.child = popup
            popup.host = host
        } else {
            current?.close()
            current = popup
        }
        popup.open(anchorRect: anchorRect, screen: window.screen?.visibleFrame, preferAbove: preferAbove)
        return popup
    }

    private func open(anchorRect: NSRect, screen: NSRect?, preferAbove: Bool) {
        let surface = FlatSurfaceView(style: .floating)
        surface.cornerRadius = 12
        surface.contentView = content.view
        panel.contentView = surface
        panel.appearance = parent?.effectiveAppearance
        panel.onCancel = { [weak self] in self?.close() }
        panel.onResignKey = { [weak self] in self?.resignedKey() }
        content.close = { [weak self] in self?.close() }
        content.onSizeChange = { [weak self] in self?.resize() }
        let size = content.preferredContentSize
        let frame = Self.frame(size: size, anchor: anchorRect, screen: screen, preferAbove: preferAbove)
        opensAbove = frame.minY >= anchorRect.maxY
        panel.setFrame(frame, display: false)
        parent?.addChildWindow(panel, ordered: .above)
        // A quick fade, as menus open, unless the user asked for less motion.
        let fades = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if fades { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        content.popupDidOpen()
        if fades {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Keeps the edge nearest the anchor in place when the content's size changes, as a search narrows a list.
    private func resize() {
        guard panel.isVisible else { return }
        var frame = panel.frame
        let size = content.preferredContentSize
        if !opensAbove { frame.origin.y = frame.maxY - size.height }
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private var opensAbove = true

    /// Where the panel goes: above or below the anchor with a small gap, inside the screen.
    static func frame(size: NSSize, anchor: NSRect, screen: NSRect?, preferAbove: Bool) -> NSRect {
        let gap: CGFloat = 6
        var origin = NSPoint(x: anchor.minX, y: preferAbove ? anchor.maxY + gap : anchor.minY - gap - size.height)
        guard let screen else { return NSRect(origin: origin, size: size) }
        if preferAbove, origin.y + size.height > screen.maxY { origin.y = anchor.minY - gap - size.height }
        if !preferAbove, origin.y < screen.minY { origin.y = anchor.maxY + gap }
        origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        return NSRect(origin: origin, size: size)
    }

    func close() {
        close(refocus: true)
    }

    /// With `refocus`, gives the keyboard back to the window (or popup) this one opened over.
    private func close(refocus: Bool) {
        guard !isClosing else { return }
        isClosing = true
        // Over a non-activating panel (the menu bar item's) Coincide is usually not active, and the keyboard goes back
        // to that panel only if this popup still had it: not after a click in another app took it.
        let hadKeyboard = panel.isKeyWindow
        child?.close(refocus: false)
        if Self.current === self { Self.current = nil }
        if host?.child === self { host?.child = nil }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if refocus, NSApp.isActive || (hadKeyboard && parent?.styleMask.contains(.nonactivatingPanel) == true) {
            parent?.makeKey()
        }
        onClose?()
    }

    /// Losing the keyboard closes the popup, unless it went to one opened from inside it. A popup opened from another
    /// takes that one along too, unless the keyboard went back to it.
    private func resignedKey() {
        guard !isClosing, child == nil else { return }
        guard let host else { return close() }
        close(refocus: false)
        DispatchQueue.main.async { [weak host] in
            guard let host, !host.isClosing, !host.panel.isKeyWindow else { return }
            host.close()
        }
    }
}

/// What a themed popup shows. It reports its size and can close the popup, after which actions run.
@MainActor
protocol ThemedPopupContent: AnyObject {
    var close: (() -> Void)? { get set }
    var onSizeChange: (() -> Void)? { get set }
    func popupDidOpen()
}

/// The popup's window: borderless and see-through outside the surface, with the window shadow. As a child window it
/// rides above its parent only. Over a non-activating panel, such as the menu bar item's, it is one too, on the same
/// level and Spaces, so it shows where that panel does (over a full-screen app) and takes the keyboard without
/// activating Coincide.
final class ThemedPopupPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onResignKey: (() -> Void)?

    init(over parent: NSWindow? = nil) {
        let followsParent = parent?.styleMask.contains(.nonactivatingPanel) == true
        super.init(
            contentRect: .zero, styleMask: followsParent ? [.borderless, .nonactivatingPanel] : [.borderless], backing: .buffered,
            defer: true)
        if let parent, followsParent {
            level = parent.level
            collectionBehavior = parent.collectionBehavior
        }
        isExcludedFromWindowsMenu = true
        hidesOnDeactivate = !followsParent
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - Menu

/// Any `NSMenu` drawn as a themed popup: section headers, separators, items with their images, check marks,
/// subtitles and submenus (which open in place, with a way back). Choosing an item closes the popup and sends the
/// item's action as the system menu would. Long menus get a search field.
final class ThemedMenuViewController: NSViewController, ThemedPopupContent, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
{
    enum Row {
        case header(String)
        case separator
        case item(NSMenuItem)
        case back(String)
    }

    var close: (() -> Void)?
    var onSizeChange: (() -> Void)?

    private let rootMenu: NSMenu
    private var stack: [NSMenu] = []
    private var rows: [Row] = []
    private let searchField = NSSearchField()
    private let tableView = ThemedPopupTableView()
    private let scrollView = NSScrollView()
    private var showsSearch = false
    private static let searchThreshold = 12
    private static let maxHeight: CGFloat = 420
    private let minimumWidth: CGFloat
    /// A pull-down button's menu starts with the button's own title, which the list leaves out.
    private let dropsFirstItem: Bool

    init(menu: NSMenu, minimumWidth: CGFloat = 200, dropsFirstItem: Bool = false) {
        rootMenu = menu
        self.minimumWidth = minimumWidth
        self.dropsFirstItem = dropsFirstItem
        super.init(nibName: nil, bundle: nil)
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.delegate?.menuWillOpen?(menu)
        stack = [menu]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        let searchIcon = NSImageView(image: Theme.symbol("magnifyingglass", size: 12) ?? NSImage())
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = String(localized: "Search")
        searchField.delegate = self
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        // The icon sits beside the field; the cell's own would overlap the text once the bezel is gone.
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.onActivate = { [weak self] in self?.activateSelection() }
        tableView.onMove = { [weak self] delta in self?.moveSelection(delta) }
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        // Room above the first row and below the last, so their highlights never touch the edges. The scroll view
        // would otherwise set its own insets.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let divider = ThemedDivider()
        divider.translatesAutoresizingMaskIntoConstraints = false
        for view in [searchIcon, searchField, divider, scrollView] as [NSView] { root.addSubview(view) }
        showsSearch = Self.itemCount(rootMenu) > Self.searchThreshold
        searchField.isHidden = !showsSearch
        searchIcon.isHidden = !showsSearch
        divider.isHidden = !showsSearch
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            scrollView.topAnchor.constraint(equalTo: showsSearch ? divider.bottomAnchor : root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        rebuild()
    }

    /// Nothing is highlighted until the pointer moves over a row or an arrow key picks one, as in a menu.
    func popupDidOpen() {
        view.window?.makeFirstResponder(showsSearch ? searchField : tableView)
    }

    // MARK: Rows

    private static func itemCount(_ menu: NSMenu) -> Int {
        menu.items.filter { !$0.isHidden && !$0.isSeparatorItem && !$0.isSectionHeader }.count
    }

    private func rebuild() {
        let menu = stack.last ?? rootMenu
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var rows: [Row] = []
        if stack.count > 1, let parent = stack.dropLast().last, let title = parent.items.first(where: { $0.submenu === menu })?.title {
            rows.append(.back(title))
        }
        if query.isEmpty {
            for (index, item) in menu.items.enumerated() where !item.isHidden && !(dropsFirstItem && index == 0 && menu === rootMenu) {
                if item.isSeparatorItem {
                    if let last = rows.last, case .item = last { rows.append(.separator) }
                } else if item.isSectionHeader {
                    rows.append(.header(item.title))
                } else {
                    rows.append(.item(item))
                }
            }
            while let last = rows.last, case .separator = last { rows.removeLast() }
        } else {
            // A search looks through submenus too, and lists matches without their sections.
            var seen = Set<String>()
            func collect(_ menu: NSMenu) {
                for (index, item) in menu.items.enumerated()
                where !item.isHidden && !item.isSeparatorItem && !item.isSectionHeader
                    && !(dropsFirstItem && index == 0 && menu === rootMenu)
                {
                    if let submenu = item.submenu {
                        collect(submenu)
                    } else if item.title.lowercased().contains(query) || (item.subtitle ?? "").lowercased().contains(query) {
                        // A submenu can repeat items shown inline, such as the full list of a long menu.
                        if seen.insert("\(item.title)\u{0}\(item.subtitle ?? "")\u{0}\(item.action.map(NSStringFromSelector) ?? "")").inserted {
                            rows.append(.item(item))
                        }
                    }
                }
            }
            collect(rootMenu)
        }
        self.rows = rows
        tableView.reloadData()
        preferredContentSize = measuredSize()
        onSizeChange?()
    }

    private func measuredSize() -> NSSize {
        var width = minimumWidth
        var height: CGFloat = 12
        for row in rows {
            height += Self.height(of: row)
            width = max(width, ThemedMenuRowView.width(for: row))
        }
        if showsSearch { height += 47 }
        if rows.isEmpty { height += 34 }
        return NSSize(width: min(ceil(width), 380), height: min(ceil(height), Self.maxHeight))
    }

    private static func height(of row: Row) -> CGFloat {
        switch row {
        case .header: 26
        case .separator: 9
        case .item(let item): item.subtitle?.isEmpty == false ? 40 : 28
        case .back: 28
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { Self.height(of: rows[row]) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = ThemedMenuRowView()
        view.configure(rows[row])
        view.isHighlighted = row == tableView.selectedRow
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { isSelectable(row) }

    func tableViewSelectionDidChange(_ notification: Notification) {
        for index in 0..<rows.count {
            (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ThemedMenuRowView)?.isHighlighted =
                index == tableView.selectedRow
        }
    }

    private func isSelectable(_ row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        switch rows[row] {
        case .item(let item): return item.isEnabled
        case .back: return true
        case .header, .separator: return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        var index = tableView.selectedRow
        for _ in 0..<rows.count {
            index = index < 0 ? (delta > 0 ? 0 : rows.count - 1) : (index + delta + rows.count) % rows.count
            if isSelectable(index) {
                tableView.selectRowIndexes([index], byExtendingSelection: false)
                tableView.scrollRowToVisible(index)
                return
            }
        }
    }

    // MARK: Actions

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard isSelectable(row) else { return }
        activate(row)
    }

    private func activateSelection() {
        guard isSelectable(tableView.selectedRow) else { return }
        activate(tableView.selectedRow)
    }

    private func activate(_ row: Int) {
        switch rows[row] {
        case .back:
            stack.removeLast()
            rebuild()
        case .item(let item):
            if let submenu = item.submenu {
                submenu.delegate?.menuNeedsUpdate?(submenu)
                stack.append(submenu)
                searchField.stringValue = ""
                rebuild()
                return
            }
            close?()
            rootMenu.delegate?.menuDidClose?(rootMenu)
            if let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
        case .header, .separator:
            break
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        rebuild()
        moveSelection(1)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)): close?()
        default: return false
        }
        return true
    }
}

/// The popup's list: Return chooses the selected row, the arrows move between choosable rows.
final class ThemedPopupTableView: NSTableView {
    var onActivate: (() -> Void)?
    var onMove: ((Int) -> Void)?
    /// The context menu for a row, which opens as a themed popup over this one.
    var rowMenu: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return ThemedContextMenu.show(rowMenu?(row), for: event, in: window)
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .carriageReturn?, .enter?: onActivate?()
        case .downArrow?: onMove?(1)
        case .upArrow?: onMove?(-1)
        default: super.keyDown(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, row != selectedRow, delegate?.tableView?(self, shouldSelectRow: row) == true {
            selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    /// The pointer leaving the list clears the highlight, as in a menu.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        deselectAll(nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
}

/// A row of a themed menu: a check column, the item's image, title and subtitle, and a chevron for a submenu. The
/// highlighted row sits on a rounded fill in the theme.
final class ThemedMenuRowView: NSView {
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { needsDisplay = true } }
    }

    private let check = NSImageView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var kind: ThemedMenuViewController.Row = .separator

    override var isFlipped: Bool { true }

    static let checkX: CGFloat = 10
    static let iconX: CGFloat = 28
    static let textX: CGFloat = 50

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        check.image = Theme.symbol("checkmark", size: 11, weight: .semibold)
        check.contentTintColor = Theme.ink
        icon.imageScaling = .scaleProportionallyDown
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        chevron.image = Theme.symbol("chevron.right", size: 10, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        for view in [check, icon, titleLabel, subtitleLabel, chevron] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ row: ThemedMenuViewController.Row) {
        kind = row
        for view in [check, icon, titleLabel, subtitleLabel, chevron] as [NSView] { view.isHidden = true }
        switch row {
        case .header(let title):
            titleLabel.isHidden = false
            titleLabel.stringValue = title
            titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            titleLabel.textColor = .secondaryLabelColor
            setAccessibilityElement(false)
        case .separator:
            setAccessibilityElement(false)
        case .back(let title):
            icon.isHidden = false
            icon.image = Theme.symbol("chevron.left", size: 11, weight: .semibold)
            icon.contentTintColor = .secondaryLabelColor
            titleLabel.isHidden = false
            titleLabel.stringValue = title
            titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
            titleLabel.textColor = .secondaryLabelColor
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(String(localized: "Back to \(title)"))
        case .item(let item):
            check.isHidden = item.state == .off
            check.image = Theme.symbol(item.state == .mixed ? "minus" : "checkmark", size: 11, weight: .semibold)
            if let image = item.image {
                icon.isHidden = false
                icon.image = image
                icon.contentTintColor = item.isEnabled ? .labelColor : .tertiaryLabelColor
            }
            titleLabel.isHidden = false
            titleLabel.stringValue = item.title
            titleLabel.font = .systemFont(ofSize: 13)
            titleLabel.textColor = item.isEnabled ? Theme.ink : .tertiaryLabelColor
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                subtitleLabel.isHidden = false
                subtitleLabel.stringValue = subtitle
            }
            chevron.isHidden = item.submenu == nil
            toolTip = item.toolTip
            setAccessibilityElement(true)
            setAccessibilityRole(.menuItem)
            setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
            setAccessibilitySelected(item.state == .on)
            setAccessibilityEnabled(item.isEnabled)
        }
        needsLayout = true
    }

    static func width(for row: ThemedMenuViewController.Row) -> CGFloat {
        switch row {
        case .header(let title):
            return textX + (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width + 16
        case .separator:
            return 0
        case .back(let title):
            return textX + (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width + 16
        case .item(let item):
            let title = (item.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
            let subtitle = ((item.subtitle ?? "") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
            return textX + max(title, min(subtitle, 300)) + (item.submenu == nil ? 18 : 34)
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        switch kind {
        case .header:
            titleLabel.frame = NSRect(x: Self.checkX + 4, y: 8, width: width - 24, height: 15)
        case .separator:
            break
        case .back, .item:
            let hasSubtitle = !subtitleLabel.isHidden
            check.frame = NSRect(x: Self.checkX + 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
            icon.frame = NSRect(x: Self.iconX, y: (bounds.height - 16) / 2, width: 16, height: 16)
            let textX = icon.isHidden && kind.isBack == false ? Self.textX - 18 : Self.textX
            let trailing: CGFloat = chevron.isHidden ? 12 : 28
            if hasSubtitle {
                titleLabel.frame = NSRect(x: textX, y: 5, width: width - textX - trailing, height: 17)
                subtitleLabel.frame = NSRect(x: textX, y: 21, width: width - textX - trailing, height: 14)
            } else {
                titleLabel.frame = NSRect(x: textX, y: (bounds.height - 17) / 2, width: width - textX - trailing, height: 17)
            }
            chevron.frame = NSRect(x: width - 22, y: (bounds.height - 12) / 2, width: 12, height: 12)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .separator:
            Theme.surfaceBorder.setFill()
            NSRect(x: 10, y: (bounds.height / 2).rounded(.down), width: bounds.width - 20, height: 1).fill()
        case .item, .back:
            guard isHighlighted else { return }
            Theme.sidebarSelection.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 7, yRadius: 7).fill()
        case .header:
            break
        }
    }
}

extension ThemedMenuViewController.Row {
    var isBack: Bool {
        if case .back = self { return true }
        return false
    }
}

/// A one-point line in the theme's border color.
final class ThemedDivider: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        layer?.backgroundColor = Theme.surfaceBorder.cgColor
    }
}

/// A pull-down button whose menu opens as a themed popup. Its menu, title item and items stay as AppKit has them, so
/// the code that fills it is unchanged.
final class ThemedPopUpButton: NSPopUpButton {
    override func mouseDown(with event: NSEvent) {
        showThemedMenu()
    }

    override func performClick(_ sender: Any?) {
        showThemedMenu()
    }

    override func accessibilityPerformPress() -> Bool {
        showThemedMenu()
        return true
    }

    private func showThemedMenu() {
        guard isEnabled, let menu else { return }
        highlight(true)
        let content = ThemedMenuViewController(menu: menu, minimumWidth: max(200, bounds.width), dropsFirstItem: pullsDown)
        ThemedPopup.show(content, from: self, preferAbove: false) { [weak self] in self?.highlight(false) }
    }
}

/// A table whose context menu opens as a themed popup.
final class ThemedMenuTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        ThemedContextMenu.show(super.menu(for: event), for: event, in: window)
    }
}

/// A label whose context menu opens as a themed popup.
final class ThemedMenuLabel: NSTextField {
    override func menu(for event: NSEvent) -> NSMenu? {
        ThemedContextMenu.show(super.menu(for: event), for: event, in: window)
    }
}

/// Context menus as themed popups: views call this from `menu(for:)` and return its result, which is always nil so
/// the system menu stays closed.
@MainActor
enum ThemedContextMenu {
    static func show(_ menu: NSMenu?, for event: NSEvent, in window: NSWindow?) -> NSMenu? {
        guard let menu, let window else { return nil }
        ThemedPopup.show(contextMenu: menu, for: event, in: window)
        return nil
    }
}

extension ThemedPopup {
    /// Shows `menu` as a themed popup beside `anchor`, in place of `NSMenu.popUp`.
    @discardableResult
    static func show(menu: NSMenu, from anchor: NSView, preferAbove: Bool = true, onClose: (() -> Void)? = nil) -> ThemedPopup? {
        show(ThemedMenuViewController(menu: menu, minimumWidth: max(200, anchor.bounds.width)), from: anchor, preferAbove: preferAbove, onClose: onClose)
    }

    /// Shows `menu` as a themed context menu under the pointer.
    @discardableResult
    static func show(contextMenu menu: NSMenu, for event: NSEvent, in window: NSWindow) -> ThemedPopup? {
        let point = window.convertPoint(toScreen: event.locationInWindow)
        return show(ThemedMenuViewController(menu: menu), at: point, in: window)
    }
}

// MARK: - Details

/// A themed popup showing one view at its fitting size, for details such as usage limits that need no list. The
/// content can be swapped while the popup is up, as the numbers behind it change.
final class ThemedPopupViewHost: NSViewController, ThemedPopupContent {
    var close: (() -> Void)?
    var onSizeChange: (() -> Void)?

    private var content: NSView

    init(_ content: NSView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        install(content)
    }

    func setContent(_ newContent: NSView) {
        content.removeFromSuperview()
        content = newContent
        guard isViewLoaded else { return }
        install(newContent)
        onSizeChange?()
    }

    private func install(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        preferredContentSize = content.fittingSize
    }

    func popupDidOpen() {}
}
