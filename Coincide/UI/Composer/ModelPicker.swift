import AppKit
import CoincideKit

/// The composer's agent and model picker, a themed popup in place of the long system menu: a search field, a tab per
/// agent with its logo, the chosen agent's models in a short scrolling list with their context sizes, and the
/// current model's reasoning efforts as chips. A search looks through every ready agent's models.
final class ModelPickerViewController: NSViewController, ThemedPopupContent, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
{
    var close: (() -> Void)?
    var onSizeChange: (() -> Void)?
    var onSelect: ((ModelSelection) -> Void)?
    var onEffort: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?

    private let registry: ProviderRegistry
    private var current: ModelSelection
    private var shownKind: ProviderKind
    private var models: [ModelOption] = []

    private let searchField = NSSearchField()
    private let tabs = NSStackView()
    private var tabButtons: [ProviderKind: PickerTabButton] = [:]
    private let tableView = ThemedPopupTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let effortRow = NSStackView()
    private let effortLabel = NSTextField(labelWithString: String(localized: "Reasoning"))
    private let effortChips = NSStackView()

    static let width: CGFloat = 340
    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 9

    init(current: ModelSelection, registry: ProviderRegistry) {
        self.current = current
        self.registry = registry
        shownKind = current.provider
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        let searchIcon = NSImageView(image: Theme.symbol("magnifyingglass", size: 12) ?? NSImage())
        searchIcon.contentTintColor = .secondaryLabelColor
        searchField.placeholderString = String(localized: "Search models")
        searchField.delegate = self
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil

        tabs.orientation = .horizontal
        tabs.distribution = .fillEqually
        tabs.spacing = 4
        for kind in registry.orderedKinds {
            let button = PickerTabButton(kind: kind, isReady: registry.status(kind).state == .ready) { [weak self] in
                self?.show(kind)
            }
            tabButtons[kind] = button
            tabs.addArrangedSubview(button)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.style = .plain
        tableView.rowHeight = Self.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.onActivate = { [weak self] in self?.chooseSelection() }
        tableView.onMove = { [weak self] delta in self?.moveSelection(delta) }
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = true

        effortLabel.font = .systemFont(ofSize: 11)
        effortLabel.textColor = .secondaryLabelColor
        effortChips.orientation = .horizontal
        effortChips.spacing = 4
        effortRow.orientation = .horizontal
        effortRow.spacing = 8
        effortRow.setViews([effortLabel, effortChips], in: .leading)

        let refresh = PickerTextButton(title: String(localized: "Refresh"), symbol: "arrow.clockwise") { [weak self] in
            self?.onRefresh?()
        }
        let settings = PickerTextButton(title: String(localized: "Agent Settings…"), symbol: "gearshape") { [weak self] in
            self?.close?()
            self?.onSettings?()
        }
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.setViews([refresh], in: .leading)
        footer.setViews([settings], in: .trailing)

        let dividers = (0..<3).map { _ in ThemedDivider() }
        let views: [NSView] = [searchIcon, searchField, tabs, scrollView, statusLabel, effortRow, footer] + dividers
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let listHeight = scrollView.heightAnchor.constraint(equalToConstant: CGFloat(Self.visibleRows) * Self.rowHeight + 8)
        listHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            searchIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            dividers[0].topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            tabs.topAnchor.constraint(equalTo: dividers[0].bottomAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            tabs.heightAnchor.constraint(equalToConstant: 34),
            dividers[1].topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: dividers[1].bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listHeight,
            statusLabel.topAnchor.constraint(equalTo: dividers[1].bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            dividers[2].topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            effortRow.topAnchor.constraint(equalTo: dividers[2].bottomAnchor, constant: 10),
            effortRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            effortRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: effortRow.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        for divider in dividers {
            NSLayoutConstraint.activate([
                divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                divider.heightAnchor.constraint(equalToConstant: 1),
            ])
        }
        view = root
        reload()
        updateEfforts()
        preferredContentSize = root.fittingSize
    }

    func popupDidOpen() {
        view.window?.makeFirstResponder(searchField)
        if let index = models.firstIndex(where: { isCurrent($0) }) {
            select(index)
        } else {
            moveSelection(1)
        }
    }

    // MARK: Content

    private var query: String { searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased() }

    private func show(_ kind: ProviderKind) {
        shownKind = kind
        searchField.stringValue = ""
        reload()
        moveSelection(1)
    }

    private func reload() {
        let isSearching = !query.isEmpty
        if isSearching {
            models = registry.readyKinds.flatMap { kind in
                registry.models(for: kind).filter {
                    $0.displayName.lowercased().contains(query) || $0.modelID.lowercased().contains(query)
                        || kind.displayName.lowercased().contains(query)
                }
            }
        } else if registry.status(shownKind).state == .ready {
            var list = registry.models(for: shownKind)
            if shownKind == current.provider, !list.contains(where: { $0.modelID == current.modelID }) {
                list.insert(ModelOption(provider: shownKind, modelID: current.modelID, displayName: current.modelID), at: 0)
            }
            models = list
        } else {
            models = []
        }
        for (kind, button) in tabButtons { button.isSelected = !isSearching && kind == shownKind }
        let unavailable = !isSearching && registry.status(shownKind).state != .ready
        statusLabel.isHidden = !unavailable
        statusLabel.stringValue =
            unavailable ? "\(shownKind.displayName): \(ComposerMenus.statusText(shownKind, registry: registry))" : ""
        scrollView.isHidden = unavailable
        if isSearching, models.isEmpty {
            statusLabel.isHidden = false
            statusLabel.stringValue = String(localized: "No models match.")
        }
        tableView.reloadData()
    }

    private func isCurrent(_ model: ModelOption) -> Bool {
        model.provider == current.provider && model.modelID == current.modelID
    }

    /// Chips for the current model's reasoning efforts; hidden when it has none.
    private func updateEfforts() {
        let model = registry.model(for: current)
        let efforts = model?.efforts ?? []
        effortRow.isHidden = efforts.isEmpty
        let selected = current.effort ?? model?.defaultEffort
        effortChips.setViews(
            efforts.map { effort in
                PickerChip(title: ComposerMenus.effortTitle(effort), isSelected: effort == selected) { [weak self] in
                    self?.current.effort = effort
                    self?.onEffort?(effort)
                    self?.updateEfforts()
                }
            }, in: .leading)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { models.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = ModelPickerRowView()
        let model = models[row]
        view.configure(model, isCurrent: isCurrent(model), showsAgent: !query.isEmpty)
        view.isHighlighted = row == tableView.selectedRow
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        for index in 0..<models.count {
            (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ModelPickerRowView)?.isHighlighted =
                index == tableView.selectedRow
        }
    }

    private func select(_ index: Int) {
        guard models.indices.contains(index) else { return }
        tableView.selectRowIndexes([index], byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    private func moveSelection(_ delta: Int) {
        guard !models.isEmpty else { return }
        let index = tableView.selectedRow
        select(index < 0 ? 0 : min(max(index + delta, 0), models.count - 1))
    }

    @objc private func rowClicked() {
        guard models.indices.contains(tableView.clickedRow) else { return }
        choose(models[tableView.clickedRow])
    }

    private func chooseSelection() {
        guard models.indices.contains(tableView.selectedRow) else { return }
        choose(models[tableView.selectedRow])
    }

    private func choose(_ model: ModelOption) {
        close?()
        onSelect?(ModelSelection(provider: model.provider, modelID: model.modelID, effort: model.defaultEffort))
    }

    func controlTextDidChange(_ obj: Notification) {
        reload()
        moveSelection(1)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)): chooseSelection()
        case #selector(NSResponder.cancelOperation(_:)): close?()
        case #selector(NSResponder.insertTab(_:)): cycleAgent(1)
        case #selector(NSResponder.insertBacktab(_:)): cycleAgent(-1)
        default: return false
        }
        return true
    }

    /// Tab and Shift-Tab step through the agents.
    private func cycleAgent(_ delta: Int) {
        let kinds = registry.orderedKinds
        guard let index = kinds.firstIndex(of: shownKind), !kinds.isEmpty else { return }
        show(kinds[(index + delta + kinds.count) % kinds.count])
    }
}

/// A model in the picker: a check for the current one, its name (with the agent's logo while searching), a Default tag,
/// and its context size.
final class ModelPickerRowView: NSView {
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { needsDisplay = true } }
    }

    private let check = NSImageView()
    private let logo = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let defaultTag = PickerTag()
    private let contextLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        check.image = Theme.symbol("checkmark", size: 11, weight: .semibold)
        check.contentTintColor = Theme.ink
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = .labelColor
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = Theme.ink
        nameLabel.lineBreakMode = .byTruncatingTail
        contextLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.alignment = .right
        for view in [check, logo, nameLabel, defaultTag, contextLabel] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ model: ModelOption, isCurrent: Bool, showsAgent: Bool) {
        check.isHidden = !isCurrent
        logo.isHidden = !showsAgent
        logo.image = Theme.logo(for: model.provider)
        nameLabel.stringValue = model.displayName
        nameLabel.font = .systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
        defaultTag.isHidden = model.modelID != "default"
        defaultTag.title = String(localized: "Default")
        contextLabel.stringValue = SettingsFormat.contextWindow(model.contextWindow) ?? ""
        toolTip = model.modelID == "default" || model.displayName == model.modelID ? nil : model.modelID
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            [showsAgent ? model.provider.displayName : nil, model.displayName, contextLabel.stringValue.nonEmpty]
                .compactMap { $0 }.joined(separator: ", "))
        setAccessibilitySelected(isCurrent)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        check.frame = NSRect(x: 14, y: midY - 7, width: 14, height: 14)
        var x: CGFloat = 34
        if !logo.isHidden {
            logo.frame = NSRect(x: x, y: midY - 7, width: 14, height: 14)
            x += 20
        }
        contextLabel.sizeToFit()
        let contextWidth = ceil(contextLabel.frame.width)
        contextLabel.frame = NSRect(x: bounds.width - 16 - contextWidth, y: midY - 8, width: contextWidth, height: 16)
        let tagWidth = defaultTag.isHidden ? 0 : defaultTag.fittingWidth + 6
        nameLabel.sizeToFit()
        let available = contextLabel.frame.minX - 8 - x - tagWidth
        let nameWidth = min(ceil(nameLabel.frame.width), max(40, available))
        nameLabel.frame = NSRect(x: x, y: midY - 9, width: nameWidth, height: 18)
        defaultTag.frame = NSRect(x: nameLabel.frame.maxX + 6, y: midY - 8, width: defaultTag.fittingWidth, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        Theme.sidebarSelection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

/// A small outlined label, such as Default beside a model.
final class PickerTag: NSView {
    var title = "" {
        didSet { needsDisplay = true }
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
    }

    var fittingWidth: CGFloat { ceil((title as NSString).size(withAttributes: attributes).width) + 12 }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        Theme.surfaceBorder.setStroke()
        path.stroke()
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

/// An agent's tab in the picker: its logo, filled while shown, dimmed when the agent is not set up.
final class PickerTabButton: NSControl {
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    private let logo = NSImageView()
    private let run: () -> Void
    private var isHovered = false

    init(kind: ProviderKind, isReady: Bool, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        logo.image = Theme.logo(for: kind)
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = .labelColor
        logo.alphaValue = isReady ? 1 : 0.35
        logo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 18),
            logo.heightAnchor.constraint(equalToConstant: 18),
        ])
        toolTip = kind.displayName
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(kind.displayName)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { run() }
    }

    override func accessibilityPerformPress() -> Bool {
        run()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        setAccessibilityValue(isSelected ? 1 : 0)
        guard isSelected || isHovered else { return }
        (isSelected ? Theme.sidebarSelection : Theme.sidebarHover).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

/// A rounded choice chip, filled while chosen, such as a reasoning effort.
final class PickerChip: NSControl {
    private let title: String
    private let isChosen: Bool
    private let run: () -> Void
    private var isHovered = false

    private var attributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 11, weight: isChosen ? .semibold : .regular),
            .foregroundColor: isChosen ? Theme.ink : NSColor.secondaryLabelColor,
        ]
    }

    init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        isChosen = isSelected
        run = action
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setAccessibilityValue(isSelected ? 1 : 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: attributes).width) + 18, height: 22)
    }

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

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { run() }
    }

    override func accessibilityPerformPress() -> Bool {
        run()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        if isChosen {
            Theme.sidebarSelection.setFill()
            path.fill()
        } else if isHovered {
            Theme.sidebarHover.setFill()
            path.fill()
        }
        Theme.surfaceBorder.setStroke()
        path.stroke()
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

/// A small borderless text button with a symbol, for the picker's footer.
final class PickerTextButton: NSButton {
    private let run: () -> Void

    init(title: String, symbol: String, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        self.title = title
        image = Theme.symbol(symbol, size: 11)
        imagePosition = .imageLeading
        isBordered = false
        font = .systemFont(ofSize: 11)
        contentTintColor = .secondaryLabelColor
        target = self
        self.action = #selector(clicked)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func clicked() { run() }
}
