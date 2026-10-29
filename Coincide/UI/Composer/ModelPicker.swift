import AppKit
import CoincideKit

/// The composer's agent and model picker, a themed popup in place of the long system menu: a search field, a Favorites
/// tab and a tab per agent with its logo, the chosen tab's models in a short scrolling list with their context sizes,
/// and the current model's reasoning efforts and speeds as chips. A search looks through every ready agent's models.
/// As in T3 Code, a model's star (shown on hover, or from its context menu) makes it a favorite, listed first; models
/// hidden in Settings › Models are left out.
final class ModelPickerViewController: NSViewController, ThemedPopupContent, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
{
    var close: (() -> Void)?
    var onSizeChange: (() -> Void)?
    var onSelect: ((ModelSelection) -> Void)?
    var onEffort: ((String) -> Void)?
    /// The speed chosen for the current model; nil for standard.
    var onSpeed: ((String?) -> Void)?
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?

    /// What a tab lists: the favorites of every agent, or one agent's models.
    private enum Tab: Hashable {
        case favorites
        case agent(ProviderKind)
    }

    private let registry: ProviderRegistry
    private let store: AppStore
    private var current: ModelSelection
    private var shownTab: Tab
    /// The account each agent tab lists the models of: the thread's for its agent, else the agent's first ready one.
    private var shownAccounts: [ProviderKind: String] = [:]
    private var models: [ModelOption] = []

    private let searchField = NSSearchField()
    private let tabs = NSStackView()
    /// The agent's accounts as chips, under the tabs, when the shown agent has more than one.
    private let accountRow = NSStackView()
    private let accountLabel = NSTextField(labelWithString: String(localized: "Account"))
    private let accountChips = NSStackView()
    private var tabButtons: [Tab: PickerTabButton] = [:]
    private let tableView = ThemedPopupTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let traits = NSStackView()
    private let effortRow = NSStackView()
    private let effortLabel = NSTextField(labelWithString: String(localized: "Reasoning"))
    private let effortChips = NSStackView()
    private let speedRow = NSStackView()
    private let speedLabel = NSTextField(labelWithString: String(localized: "Speed"))
    private let speedChips = NSStackView()

    static let width: CGFloat = 340
    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 9

    /// Opens on the favorites when there are any, as T3 Code's picker does, else on the current agent.
    init(current: ModelSelection, registry: ProviderRegistry, store: AppStore) {
        self.current = current
        self.registry = registry
        self.store = store
        shownTab = registry.favoriteModels.isEmpty ? .agent(current.provider) : .favorites
        super.init(nibName: nil, bundle: nil)
    }

    private var tabOrder: [Tab] { [.favorites] + registry.orderedKinds.map { .agent($0) } }

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
        for tab in tabOrder {
            let button: PickerTabButton
            switch tab {
            case .favorites:
                button = PickerTabButton(image: Theme.symbol("star.fill", size: 15) ?? NSImage(), label: String(localized: "Favorites")) {
                    [weak self] in self?.show(tab)
                }
            case .agent(let kind):
                button = PickerTabButton(kind: kind, isReady: registry.isReady(kind)) { [weak self] in
                    self?.show(tab)
                }
            }
            tabButtons[tab] = button
            tabs.addArrangedSubview(button)
        }

        accountLabel.font = .systemFont(ofSize: 11)
        accountLabel.textColor = .secondaryLabelColor
        accountChips.orientation = .horizontal
        accountChips.spacing = 4
        accountRow.orientation = .horizontal
        accountRow.spacing = 8
        accountRow.setViews([accountLabel, accountChips], in: .leading)
        let header = NSStackView(views: [tabs, accountRow])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8
        header.detachesHiddenViews = true

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
        tableView.rowMenu = { [weak self] row in self?.menu(forRow: row) }
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = true

        for label in [effortLabel, speedLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        // The chips of both rows start in one column.
        let labelWidth = ceil(max(effortLabel.fittingSize.width, speedLabel.fittingSize.width))
        for (row, label, chips) in [(effortRow, effortLabel, effortChips), (speedRow, speedLabel, speedChips)] {
            label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
            chips.orientation = .horizontal
            chips.spacing = 4
            row.orientation = .horizontal
            row.spacing = 8
            row.setViews([label, chips], in: .leading)
        }
        traits.orientation = .vertical
        traits.alignment = .leading
        traits.spacing = 8
        traits.setViews([effortRow, speedRow], in: .top)

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
        let views: [NSView] = [searchIcon, searchField, header, scrollView, statusLabel, traits, footer] + dividers
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
            header.topAnchor.constraint(equalTo: dividers[0].bottomAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            tabs.widthAnchor.constraint(equalTo: header.widthAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 34),
            accountLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            dividers[1].topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: dividers[1].bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listHeight,
            statusLabel.topAnchor.constraint(equalTo: dividers[1].bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            dividers[2].topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            traits.topAnchor.constraint(equalTo: dividers[2].bottomAnchor, constant: 10),
            traits.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            traits.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: traits.bottomAnchor, constant: 8),
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
        updateSpeeds()
        preferredContentSize = root.fittingSize
    }

    /// Shows the current model, marked by its check, without highlighting it; the arrows start from there.
    func popupDidOpen() {
        view.window?.makeFirstResponder(searchField)
        if let index = models.firstIndex(where: { isCurrent($0) }) { tableView.scrollRowToVisible(index) }
    }

    // MARK: Content

    private var query: String { searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased() }

    private func show(_ tab: Tab) {
        shownTab = tab
        searchField.stringValue = ""
        reload()
        moveSelection(1)
    }

    /// Whether the rows mix agents, so each shows its agent's logo.
    private var mixesAgents: Bool { !query.isEmpty || shownTab == .favorites }

    private func reload() {
        let isSearching = !query.isEmpty
        var unavailable: ProviderKind?
        var hidesAll = false
        if isSearching {
            models = registry.readyKinds.flatMap { kind in
                registry.pickerModels(for: kind, current: current).filter {
                    $0.displayName.lowercased().contains(query) || $0.modelID.lowercased().contains(query)
                        || kind.displayName.lowercased().contains(query)
                }
            }
        } else {
            switch shownTab {
            case .favorites:
                models = registry.favoriteModels
            case .agent(let kind) where registry.status(kind, account: shownAccount(kind)).state == .ready:
                let account = shownAccount(kind)
                var list = registry.pickerModels(for: kind, account: account, current: current)
                if kind == current.provider, account == current.account, !list.contains(where: { $0.modelID == current.modelID }) {
                    list.insert(ModelOption(provider: kind, modelID: current.modelID, displayName: current.modelID), at: 0)
                }
                models = list
                hidesAll = list.isEmpty && store.settings.hiddenModels.contains { $0.provider == kind }
            case .agent(let kind):
                models = []
                unavailable = kind
            }
        }
        for (tab, button) in tabButtons { button.isSelected = !isSearching && tab == shownTab }
        updateAccounts(isSearching: isSearching)
        let status: String? =
            if let unavailable {
                unavailableText(unavailable)
            } else if !models.isEmpty {
                nil
            } else if isSearching {
                String(localized: "No models match.")
            } else if shownTab == .favorites {
                String(localized: "No favorites yet. Star a model to keep it here.")
            } else if hidesAll {
                String(localized: "Every model is hidden. Settings › Models shows them again.")
            } else {
                String(localized: "No models yet.")
            }
        statusLabel.isHidden = status == nil
        statusLabel.stringValue = status ?? ""
        scrollView.isHidden = unavailable != nil
        tableView.reloadData()
    }

    /// In an agent's tab a model is current only for the account the thread runs.
    private func isCurrent(_ model: ModelOption) -> Bool {
        guard model.provider == current.provider, model.modelID == current.modelID else { return false }
        if case .agent(let kind) = shownTab, query.isEmpty { return shownAccount(kind) == current.account }
        return true
    }

    // MARK: Accounts

    /// The account an agent's tab shows: the one chosen in it, else the thread's for its agent, else the first ready.
    private func shownAccount(_ kind: ProviderKind) -> String {
        if let chosen = shownAccounts[kind] { return chosen }
        let accounts = registry.accounts(for: kind)
        if kind == current.provider, accounts.contains(where: { $0.id == current.account }) { return current.account }
        return (accounts.first { registry.status(kind, account: $0.id).state == .ready } ?? accounts[0]).id
    }

    /// The account a model chosen outside its agent's tab runs with: the thread's for its agent, else the shown one.
    private func account(choosing model: ModelOption) -> String? {
        if case .agent(let kind) = shownTab, query.isEmpty, kind == model.provider { return shownAccount(kind) }
        if model.provider == current.provider { return current.accountID }
        return ProviderAccount.storedID(shownAccount(model.provider))
    }

    /// Chips for the shown agent's accounts; hidden while searching, on Favorites, and for agents with one account.
    private func updateAccounts(isSearching: Bool) {
        var shown: [ProviderAccount] = []
        if !isSearching, case .agent(let kind) = shownTab {
            let accounts = registry.accounts(for: kind)
            if accounts.count > 1 { shown = accounts }
        }
        let wasHidden = accountRow.isHidden
        accountRow.isHidden = shown.isEmpty
        accountChips.setViews(
            shown.map { account in
                let kind = account.provider
                let ready = registry.status(kind, account: account.id).state == .ready
                let chip = PickerChip(title: account.name, isSelected: account.id == shownAccount(kind)) { [weak self] in
                    self?.shownAccounts[kind] = account.id
                    self?.reload()
                    self?.moveSelection(1)
                }
                chip.alphaValue = ready ? 1 : 0.55
                chip.toolTip = ready ? nil : ComposerMenus.statusText(kind, account: account.id, registry: registry)
                return chip
            }, in: .leading)
        if wasHidden != accountRow.isHidden, isViewLoaded, view.window != nil {
            view.layoutSubtreeIfNeeded()
            preferredContentSize = view.fittingSize
            onSizeChange?()
        }
    }

    private func unavailableText(_ kind: ProviderKind) -> String {
        let account = shownAccount(kind)
        let name = registry.accounts(for: kind).count > 1 ? registry.account(account, of: kind).name : kind.displayName
        return "\(name): \(ComposerMenus.statusText(kind, account: account, registry: registry))"
    }

    // MARK: Favorites

    /// Stars or unstars a model and lists it again in its new place, keeping it highlighted if it was.
    private func toggleFavorite(_ model: ModelOption) {
        let isFavorite = store.settings.isFavorite(model.reference)
        let highlighted = models.indices.contains(tableView.selectedRow) ? models[tableView.selectedRow].id : nil
        store.updateSettings { $0.setFavorite(!isFavorite, model.reference) }
        reload()
        if let highlighted, let index = models.firstIndex(where: { $0.id == highlighted }) {
            select(index)
        } else {
            tableView.deselectAll(nil)
        }
    }

    /// A row's context menu: star or unstar the model, or hide it (Settings › Models shows it again).
    private func menu(forRow row: Int) -> NSMenu? {
        guard models.indices.contains(row) else { return nil }
        let model = models[row]
        let isFavorite = store.settings.isFavorite(model.reference)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let favorite = menu.addItem(
            withTitle: isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
            action: #selector(toggleFavoriteItem(_:)), keyEquivalent: "")
        favorite.image = Theme.symbol(isFavorite ? "star.slash" : "star")
        let hide = menu.addItem(withTitle: String(localized: "Hide Model"), action: #selector(hideItem(_:)), keyEquivalent: "")
        hide.image = Theme.symbol("eye.slash")
        // The current model always shows, so hiding it would change nothing yet.
        hide.isEnabled = !isCurrent(model)
        menu.addItem(.separator())
        let manage = menu.addItem(
            withTitle: String(localized: "Manage Models…"), action: #selector(manageModels(_:)), keyEquivalent: "")
        manage.image = Theme.symbol("slider.horizontal.3")
        for item in menu.items {
            item.target = self
            item.representedObject = model
        }
        return menu
    }

    @objc private func toggleFavoriteItem(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? ModelOption else { return }
        toggleFavorite(model)
    }

    @objc private func hideItem(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? ModelOption else { return }
        store.updateSettings { $0.setHidden(true, model.reference) }
        reload()
        tableView.deselectAll(nil)
    }

    @objc private func manageModels(_ sender: NSMenuItem) {
        close?()
        AppEvents.showSettings(section: .models)
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

    /// Chips for the current model's speeds, standard first; hidden when it runs at one speed.
    private func updateSpeeds() {
        let model = registry.model(for: current)
        let speeds = model?.speeds ?? []
        speedRow.isHidden = speeds.isEmpty
        let selected = model?.speed(current.speed)
        let standard = PickerChip(title: String(localized: "Standard"), isSelected: selected == nil) { [weak self] in
            self?.chooseSpeed(nil)
        }
        speedChips.setViews(
            [standard]
                + speeds.map { speed in
                    let chip = PickerChip(title: speed.name, isSelected: speed == selected) { [weak self] in
                        self?.chooseSpeed(speed.id)
                    }
                    chip.toolTip = speed.detail
                    return chip
                }, in: .leading)
    }

    private func chooseSpeed(_ speed: String?) {
        current.speed = speed
        onSpeed?(speed)
        updateSpeeds()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { models.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = ModelPickerRowView()
        let model = models[row]
        view.configure(
            model, isCurrent: isCurrent(model), showsAgent: mixesAgents, isFavorite: store.settings.isFavorite(model.reference))
        view.onToggleFavorite = { [weak self] in self?.toggleFavorite(model) }
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
        var index = tableView.selectedRow
        // With nothing highlighted yet, the arrows start from the current model.
        if index < 0, let current = models.firstIndex(where: { isCurrent($0) }) { index = current - (delta > 0 ? 1 : -1) }
        select(index < 0 ? 0 : min(max(index + delta, 0), models.count - 1))
    }

    /// A click on a row's star stars or unstars the model; anywhere else chooses it.
    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard models.indices.contains(row) else { return }
        if let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ModelPickerRowView,
            let event = NSApp.currentEvent, view.starContains(view.convert(event.locationInWindow, from: nil))
        {
            return toggleFavorite(models[row])
        }
        choose(models[row])
    }

    private func chooseSelection() {
        guard models.indices.contains(tableView.selectedRow) else { return }
        choose(models[tableView.selectedRow])
    }

    private func choose(_ model: ModelOption) {
        let account = account(choosing: model)
        close?()
        onSelect?(ModelSelection(provider: model.provider, modelID: model.modelID, effort: model.defaultEffort, accountID: account))
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
        case #selector(NSResponder.insertTab(_:)): cycleTab(1)
        case #selector(NSResponder.insertBacktab(_:)): cycleTab(-1)
        default: return false
        }
        return true
    }

    /// Tab and Shift-Tab step through Favorites and the agents.
    private func cycleTab(_ delta: Int) {
        let tabs = tabOrder
        guard let index = tabs.firstIndex(of: shownTab) else { return }
        show(tabs[(index + delta + tabs.count) % tabs.count])
    }
}

/// A model in the picker: a check for the current one, its name (with the agent's logo when the list mixes agents), a
/// Default tag, its context size and its star: filled in the accent for a favorite, otherwise shown on hover and while
/// highlighted, in a column kept for it.
final class ModelPickerRowView: NSView {
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
            updateStar()
        }
    }
    /// Stars or unstars the model, for VoiceOver's action on the row.
    var onToggleFavorite: (() -> Void)?

    private let check = NSImageView()
    private let logo = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let defaultTag = PickerTag()
    private let contextLabel = NSTextField(labelWithString: "")
    private let star = NSImageView()
    private var isFavorite = false
    private var isHovered = false

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
        star.imageScaling = .scaleNone
        // VoiceOver stars the model with the row's own action.
        star.setAccessibilityElement(false)
        for view in [check, logo, nameLabel, defaultTag, contextLabel, star] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ model: ModelOption, isCurrent: Bool, showsAgent: Bool, isFavorite: Bool) {
        check.isHidden = !isCurrent
        logo.isHidden = !showsAgent
        logo.image = Theme.logo(for: model.provider)
        nameLabel.stringValue = model.displayName
        nameLabel.font = .systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
        defaultTag.isHidden = model.modelID != "default"
        defaultTag.title = String(localized: "Default")
        contextLabel.stringValue = SettingsFormat.contextWindow(model.contextWindow) ?? ""
        self.isFavorite = isFavorite
        updateStar()
        toolTip = model.modelID == "default" || model.displayName == model.modelID ? nil : model.modelID
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            [
                showsAgent ? model.provider.displayName : nil, model.displayName, contextLabel.stringValue.nonEmpty,
                isFavorite ? String(localized: "Favorite") : nil,
            ]
            .compactMap { $0 }.joined(separator: ", "))
        setAccessibilitySelected(isCurrent)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(
                name: isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")
            ) { [weak self] in
                self?.onToggleFavorite?()
                return true
            }
        ])
        needsLayout = true
    }

    /// Whether a point (in the row's coordinates) hits the star, with some room around it.
    func starContains(_ point: NSPoint) -> Bool {
        star.frame.insetBy(dx: -6, dy: -7).contains(point)
    }

    private func updateStar() {
        let shown = isFavorite || isHovered || isHighlighted
        star.isHidden = !shown
        guard shown else { return }
        star.image = Theme.symbol(isFavorite ? "star.fill" : "star", size: 11, weight: .medium)
        star.contentTintColor = isFavorite ? Theme.accent : .tertiaryLabelColor
        star.toolTip = isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        // A row listed again under the pointer (after a star was clicked) gets no entered event until the pointer moves.
        if let window {
            setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }

    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateStar()
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
        star.frame = NSRect(x: bounds.width - 30, y: midY - 8, width: 16, height: 16)
        contextLabel.sizeToFit()
        let contextWidth = ceil(contextLabel.frame.width)
        contextLabel.frame = NSRect(x: star.frame.minX - 6 - contextWidth, y: midY - 8, width: contextWidth, height: 16)
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

/// A tab in the picker: an agent's logo (dimmed when the agent is not set up) or the Favorites star, filled while shown.
final class PickerTabButton: NSControl {
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    private let logo = NSImageView()
    private let run: () -> Void
    private var isHovered = false

    convenience init(kind: ProviderKind, isReady: Bool, action: @escaping () -> Void) {
        self.init(image: Theme.logo(for: kind), label: kind.displayName, isDimmed: !isReady, action: action)
    }

    init(image: NSImage, label: String, isDimmed: Bool = false, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        logo.image = image
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = .labelColor
        logo.alphaValue = isDimmed ? 0.35 : 1
        logo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 18),
            logo.heightAnchor.constraint(equalToConstant: 18),
        ])
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(label)
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
