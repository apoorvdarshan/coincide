import AppKit
import UniformTypeIdentifiers

/// The completion list for `@` mentions and `/` commands. It floats above the composer in a borderless
/// child window, so the text view keeps keyboard focus while the composer moves the selection.
final class ComposerSuggestionPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onChoose: ((ComposerSuggestion) -> Void)?

    private(set) var items: [ComposerSuggestion] = []
    private var panel: NSPanel?
    private let tableView = SuggestionTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var iconCache: [String: NSImage] = [:]
    private let rowHeight: CGFloat = 30
    private let maxVisibleRows = 8
    private let padding: CGFloat = 6

    var isVisible: Bool { panel?.isVisible == true }

    var selectedItem: ComposerSuggestion? {
        items.indices.contains(tableView.selectedRow) ? items[tableView.selectedRow] : nil
    }

    /// Shows `items` (or `emptyText` when there are none) just above `anchor`.
    func show(_ items: [ComposerSuggestion], emptyText: String?, listLabel: String, above anchor: NSView) {
        let previous = selectedItem
        self.items = items
        let panel = panel ?? makePanel()
        tableView.reloadData()
        tableView.setAccessibilityLabel(listLabel)
        let row = previous.flatMap { items.firstIndex(of: $0) } ?? 0
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        emptyLabel.stringValue = emptyText ?? ""
        emptyLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty
        position(panel, above: anchor)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = max(tableView.selectedRow, offset > 0 ? -1 : 0)
        let row = (current + offset + items.count) % items.count
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Keeps the panel glued to the composer as it grows or the window resizes.
    func reposition(above anchor: NSView) {
        if let panel, panel.isVisible { position(panel, above: anchor) }
    }

    private func position(_ panel: NSPanel, above anchor: NSView) {
        guard let window = anchor.window else { return }
        let rows = CGFloat(min(max(items.count, 1), maxVisibleRows))
        let height = items.isEmpty ? 40 : rows * rowHeight + padding * 2
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var frame = NSRect(x: anchorFrame.minX, y: anchorFrame.maxY + 6, width: anchorFrame.width, height: height)
        if let screen = window.screen?.visibleFrame, frame.maxY > screen.maxY {
            // Below the anchor when it fits there; otherwise above it, pinned to the top of the anchor's own screen
            // so the list never spills onto a display arranged above or below.
            let below = anchorFrame.minY - 6 - height
            frame.origin.y = below >= screen.minY ? below : screen.maxY - height
        }
        panel.setFrame(frame, display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = SuggestionWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = .zero
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: padding, left: 0, bottom: padding, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scrollView)
        content.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        let glass = NSGlassEffectView()
        glass.cornerRadius = 14
        glass.contentView = content
        panel.contentView = glass
        self.panel = panel
        return panel
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        onChoose?(items[row])
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SuggestionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell =
            tableView.makeView(withIdentifier: SuggestionCellView.identifier, owner: nil) as? SuggestionCellView
            ?? SuggestionCellView()
        switch items[row] {
        case .file(let entry):
            cell.show(
                icon: icon(for: entry), title: entry.isDirectory ? entry.name + "/" : entry.name,
                detail: entry.parent, tint: nil)
        case .command(let command):
            let icon =
                if case .agent(let provider) = command {
                    Theme.logo(for: provider, size: 14)
                } else {
                    NSImage(systemSymbolName: command.symbolName, accessibilityDescription: nil)
                }
            cell.show(icon: icon, title: command.title, detail: command.summary, tint: .secondaryLabelColor)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        announceSelection()
    }

    /// Focus stays in the composer, so VoiceOver hears the highlighted suggestion this way.
    private func announceSelection() {
        guard isVisible, let item = selectedItem, let row = items.firstIndex(of: item) else { return }
        let name =
            switch item {
            case .file(let entry): entry.path
            case .command(let command): "\(command.title), \(command.summary)"
            }
        NSAccessibility.post(
            element: tableView, notification: .announcementRequested,
            userInfo: [
                .announcement: String(localized: "\(name), \(row + 1) of \(items.count)"),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }

    private func icon(for entry: ComposerFileEntry) -> NSImage {
        let key = entry.isDirectory ? "/" : (entry.name as NSString).pathExtension.lowercased()
        if let cached = iconCache[key] { return cached }
        let type = entry.isDirectory ? UTType.folder : UTType(filenameExtension: key) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        iconCache[key] = image
        return image
    }
}

/// Never takes key status, so typing keeps going to the composer.
private final class SuggestionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Selects the row under the pointer, like a menu, and takes clicks without activating the panel.
private final class SuggestionTableView: NSTableView {
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, row != selectedRow { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }
}

/// Draws the selection as a rounded accent capsule, as menus do.
private final class SuggestionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

private final class SuggestionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ComposerSuggestionCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = title
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown
        for view in [icon, title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Tint for symbol icons; nil keeps a full-color file icon as it is.
    private var tint: NSColor?

    func show(icon image: NSImage?, title text: String, detail detailText: String, tint: NSColor?) {
        icon.image = image
        self.tint = tint
        icon.contentTintColor = tint.map { backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : $0 }
        title.stringValue = text
        detail.stringValue = detailText
        setAccessibilityLabel(detailText.isEmpty ? text : "\(text), \(detailText)")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            detail.textColor = emphasized ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
            icon.contentTintColor = tint.map { emphasized ? .alternateSelectedControlTextColor : $0 }
        }
    }
}
