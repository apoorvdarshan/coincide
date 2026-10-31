import AppKit
import CoincideKit

/// Every schedule in one place, in the inspector beside the conversation (View › Scheduled Tasks, ⌥⌘S, the clock in
/// the toolbar's top-right group and the sidebar's Scheduled row): grouped by the bot, thread or project its runs go
/// to, the soonest first. Bots' groups show the bot's character, threads' their title and project. A row opens its
/// thread; its actions pause or resume it, run it now, edit or delete it, and Add schedules into the open thread or a
/// project. Opened from a thread with schedules, it lists just those (This Thread) until the filter menu says
/// otherwise. The panel stays open while the window moves between threads.
final class SchedulesPanelController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// The open thread, which Add schedules into.
    var threadID: UUID? {
        didSet { if threadID != oldValue, isViewLoaded { reload() } }
    }

    private enum Row {
        case header(SchedulePresentation.Group)
        case task(ScheduledTask)
    }

    private let service: ScheduledTasks
    private let store: AppStore
    private let tableView = SchedulesTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let searchRow = SidebarSearchRow()
    private let filterButton = ThemedPopUpButton(frame: .zero, pullsDown: true)
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var addButton = PanelIconButton(symbol: "plus", label: String(localized: "New Scheduled Task"), target: self, action: #selector(add(_:)))
    private var rows: [Row] = []
    private var observations: [NSObjectProtocol] = []
    private var storeObservation: ObservationToken?
    private var timer: Timer?

    private static let filterKey = "ScheduleFilter"
    /// The filter the user last chose other than This Thread, kept between launches.
    private var savedFilter: ScheduleFilter {
        get {
            let saved = UserDefaults.standard.string(forKey: Self.filterKey).flatMap(ScheduleFilter.init(rawValue:)) ?? .all
            return saved == .thisThread ? .all : saved
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.filterKey) }
    }
    /// Whether the panel lists only the open thread's schedules (This Thread). It follows the window to other threads.
    private var showsThisThread = false
    /// What the panel lists.
    private(set) var filter: ScheduleFilter {
        get { showsThisThread ? .thisThread : savedFilter }
        set {
            showsThisThread = newValue == .thisThread
            if newValue != .thisThread { savedFilter = newValue }
            if isViewLoaded { reload() }
        }
    }

    init(service: ScheduledTasks = .shared, store: AppStore = .shared) {
        self.service = service
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        timer?.invalidate()
        observations.forEach(NotificationCenter.default.removeObserver)
    }

    override func loadView() {
        let root = SolidBackgroundView(color: Theme.contentBackground)
        root.setAccessibilityLabel(String(localized: "Scheduled Tasks"))
        let title = NSTextField(labelWithString: String(localized: "Scheduled"))
        title.font = .systemFont(ofSize: Theme.fontSize, weight: .semibold)
        title.textColor = Theme.ink
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: Theme.fontSize - 1, weight: .regular)
        filterButton.controlSize = .regular
        filterButton.isBordered = false
        filterButton.setAccessibilityLabel(String(localized: "Schedules to show"))
        filterButton.target = self
        filterButton.action = #selector(filterChanged(_:))
        let header = NSStackView(views: [title, countLabel, NSView(), filterButton, addButton])
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 4, right: 8)
        header.setHuggingPriority(.init(1), for: .horizontal)
        searchField.placeholderString = String(localized: "Search schedules")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityLabel(String(localized: "Search schedules"))
        searchRow.field = searchField
        let divider = ThemedDivider(frame: .zero)

        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("schedule")))
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.floatsGroupRows = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(String(localized: "Scheduled Tasks"))
        tableView.menuForRow = { [weak self] row in self?.menu(forRow: row) }
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 40, right: 0)
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: Theme.fontSize - 1)
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: Theme.fontSize - 2)

        for view in [header, searchRow, divider, errorLabel, scrollView, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: safe.topAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            searchRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            searchRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            searchRow.topAnchor.constraint(equalTo: header.bottomAnchor),
            searchRow.heightAnchor.constraint(equalToConstant: SidebarHeaderView.rowHeight),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 6),
            divider.heightAnchor.constraint(equalToConstant: 1),
            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            errorLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
        ])
        view = root
        observations.append(NotificationCenter.default.addObserver(forName: ScheduledTasks.didChange, object: service, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        storeObservation = store.observe { [weak self] change in
            switch change {
            case .threadList, .bots, .projects, .settings: self?.reload()
            case .thread(let id) where self?.service.schedules.tasks.contains(where: { $0.threadID == id }) == true: self?.reload()
            default: break
            }
        }
        rebuildFilterMenu()
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reload()
        // Next runs read "Today 9:00", "Tomorrow…": keep them current while the panel shows.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.invalidate()
        timer = nil
    }

    /// As the panel opens: on the open thread's schedules (This Thread) when it has any, so they come first, otherwise
    /// on the filter the user last chose. The filter menu switches to every schedule.
    func prepareToShow() {
        let thread = threadID.map { !service.tasks(inThread: $0).isEmpty } ?? false
        filter = thread ? .thisThread : savedFilter
    }

    /// Puts the cursor in the search field.
    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: Data

    private func reload() {
        guard isViewLoaded else { return }
        let all = service.schedules.tasks
        let query = searchField.stringValue
        let filter = filter, threadID = threadID
        let groups = SchedulePresentation.groups(
            all, botOf: { [store] in store.summary($0)?.botID }, title: { [weak self] in self?.title(for: $0) ?? ("", nil) },
            matches: { [weak self] task in
                guard let self else { return false }
                return filter.includes(task, threadID: threadID)
                    && SchedulePresentation.matches(task, query: query, place: placeName(of: task))
            })
        rows = groups.flatMap { group in [Row.header(group)] + group.tasks.map(Row.task) }
        tableView.reloadData()
        countLabel.stringValue = all.isEmpty ? "" : "\(all.count)"
        filterButton.title = filter.title
        (filterButton.menu?.items.first)?.title = filter.title
        // This Thread needs a thread open.
        for item in filterButton.menu?.items ?? [] where item.representedObject as? String == ScheduleFilter.thisThread.rawValue {
            item.isEnabled = threadID != nil
        }
        let error = service.schedules.loadError ?? service.lastError
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.stringValue =
            all.isEmpty
            ? String(localized: "Nothing is scheduled yet. Ask an agent in any thread to do something later or on a schedule, or choose Schedule… from a thread’s menu.")
            : filter == .thisThread && query.isEmpty
                ? String(localized: "Nothing is scheduled here yet. Add a schedule, or ask the agent to do something later or on a schedule.")
                : String(localized: "No schedules match.")
        addButton.isEnabled = service.schedules.loadError == nil
    }

    private func title(for owner: SchedulePresentation.Owner) -> (String, String?) {
        switch owner {
        case .bot(let id):
            let bot = store.bot(id)
            return (bot?.displayName ?? String(localized: "Bot"), String(localized: "Bot"))
        case .thread(let id):
            guard let thread = store.summary(id) else { return (String(localized: "Deleted thread"), nil) }
            let project = store.project(thread.projectID)
            return (thread.title, project?.isChats == true ? String(localized: "Chat") : project?.name)
        case .project(let id):
            return (store.project(id)?.name ?? String(localized: "Project unavailable"), String(localized: "A new thread each run"))
        }
    }

    /// Where a schedule's runs go, for search.
    private func placeName(of task: ScheduledTask) -> String {
        let owner = SchedulePresentation.owner(of: task, botOf: { [store] in store.summary($0)?.botID })
        let (title, subtitle) = self.title(for: owner)
        let thread = task.threadID.flatMap { store.summary($0)?.title } ?? ""
        return [title, subtitle ?? "", thread].joined(separator: " ")
    }

    /// The schedules the list shows, in order.
    var shownTasks: [ScheduledTask] {
        rows.compactMap { if case .task(let task) = $0 { task } else { nil } }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row), case .header = rows[row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 1 }
        switch rows[row] {
        case .header: return 34
        case .task: return ScheduleRowView.height + 2
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard rows.indices.contains(row), case .header = rows[row] else { return ThemedTableRowView() }
        return ScheduleGroupRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let group):
            let cell = tableView.makeView(withIdentifier: ScheduleGroupCell.identifier, owner: nil) as? ScheduleGroupCell ?? ScheduleGroupCell()
            cell.show(group, store: store)
            cell.onOpen = { [weak self] in self?.openGroup(group) }
            return cell
        case .task(let task):
            let cell = NSTableCellView()
            let row = ScheduleRowView()
            row.show(task, isRunning: service.hasActiveWork(task) && task.activeThreadID != nil)
            row.onAction = { [weak self] action in self?.perform(action, on: task) }
            row.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                row.topAnchor.constraint(equalTo: cell.topAnchor, constant: 1),
                row.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -1),
            ])
            return cell
        }
    }

    // MARK: Actions

    private func openGroup(_ group: SchedulePresentation.Group) {
        switch group.owner {
        case .thread(let id): if store.summary(id) != nil { AppEvents.openThread(id) }
        case .bot: if let task = group.tasks.first { ScheduleActions.open(task) }
        case .project: break
        }
    }

    private func perform(_ action: ScheduleRowView.Action, on task: ScheduledTask) {
        let window = view.window
        switch action {
        case .open: ScheduleActions.open(task)
        case .togglePause: ScheduleActions.togglePause(task.id, in: window)
        case .runNow: ScheduleActions.runNow(task.id, in: window)
        case .edit: ScheduleActions.edit(task.id, in: window)
        case .delete: ScheduleActions.confirmDelete(task.id, in: window)
        }
    }

    private func menu(forRow row: Int) -> NSMenu? {
        guard rows.indices.contains(row), case .task(let task) = rows[row] else { return nil }
        let menu = NSMenu()
        func item(_ title: String, _ action: ScheduleRowView.Action, enabled: Bool = true) {
            let entry = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = (task.id, action) as (UUID, ScheduleRowView.Action)
            entry.isEnabled = enabled
            menu.addItem(entry)
        }
        menu.autoenablesItems = false
        item(task.threadID == nil ? String(localized: "Open Last Run") : String(localized: "Open Thread"), .open,
            enabled: (task.threadID ?? task.lastThreadID).flatMap { store.summary($0) } != nil)
        menu.addItem(.separator())
        item(task.isPaused ? String(localized: "Resume") : String(localized: "Pause"), .togglePause,
            enabled: !task.isAwaitingApproval && task.pauseReason == nil)
        item(String(localized: "Run Now"), .runNow, enabled: !task.isAwaitingApproval && task.pauseReason == nil)
        item(String(localized: "Edit…"), .edit)
        menu.addItem(.separator())
        item(String(localized: "Delete…"), .delete)
        return menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let (id, action) = sender.representedObject as? (UUID, ScheduleRowView.Action),
            let task = service.schedules.task(id)
        else { return }
        perform(action, on: task)
    }

    @objc private func add(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let inThread = NSMenuItem(title: String(localized: "Schedule in This Thread…"), action: #selector(addInThread), keyEquivalent: "")
        inThread.target = self
        inThread.isEnabled = threadID.flatMap { store.summary($0) } != nil
        menu.addItem(inThread)
        let project = NSMenuItem(title: String(localized: "New Thread Each Run…"), action: #selector(addProjectTask), keyEquivalent: "")
        project.target = self
        project.subtitle = String(localized: "Starts a new thread in a project at each run")
        project.isEnabled = store.projects.contains { $0.id != AppStore.botsProjectID }
        menu.addItem(project)
        ThemedPopup.show(menu: menu, from: sender, preferAbove: false)
    }

    @objc private func addInThread() {
        guard let threadID else { return }
        ScheduleActions.newSchedule(inThread: threadID, in: view.window)
    }

    @objc private func addProjectTask() {
        let current = threadID.flatMap { store.summary($0)?.projectID }
        ScheduleActions.newProjectTask(projectID: current == AppStore.botsProjectID ? nil : current, in: view.window)
    }

    private func rebuildFilterMenu() {
        let menu = NSMenu()
        // A pull-down's first item is its title.
        menu.addItem(NSMenuItem(title: filter.title, action: nil, keyEquivalent: ""))
        for option in ScheduleFilter.allCases {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.rawValue
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        filterButton.menu = menu
    }

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let option = ScheduleFilter(rawValue: raw) else { return }
        filter = option
    }

    @objc private func searchChanged(_ sender: NSSearchField) { reload() }

    func controlTextDidChange(_ notification: Notification) { reload() }
}

/// The panel's list: its context menu opens as a themed popup, for the row under the pointer.
final class SchedulesTableView: NSTableView {
    var menuForRow: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let menu = menuForRow?(row) else { return nil }
        return ThemedContextMenu.show(menu, for: event, in: window)
    }
}

/// A group's floating heading: the content background, so rows scroll under it cleanly.
final class ScheduleGroupRowView: NSTableRowView {
    override var isGroupRowStyle: Bool {
        get { true }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.contentBackground.setFill()
        bounds.fill()
    }
}

/// A group's heading: the bot's character, the agent's logo for a thread or a folder for a project, then its title
/// and where it is. A click opens the group's thread.
final class ScheduleGroupCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ScheduleGroup")
    var onOpen: (() -> Void)?

    private let avatar = BotAvatarView(size: 20)
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        titleLabel.font = .systemFont(ofSize: Theme.fontSize - 1, weight: .semibold)
        titleLabel.textColor = Theme.ink
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        subtitleLabel.font = .systemFont(ofSize: Theme.fontSize - 2)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.init(90), for: .horizontal)
        countLabel.font = .monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        let leading = NSView()
        for view in [avatar, icon] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            leading.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: leading.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            leading.widthAnchor.constraint(equalToConstant: 20), leading.heightAnchor.constraint(equalToConstant: 20),
            icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
        ])
        let stack = NSStackView(views: [leading, titleLabel, subtitleLabel, NSView(), countLabel])
        stack.spacing = 6
        stack.setCustomSpacing(8, after: leading)
        stack.setHuggingPriority(.init(1), for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ group: SchedulePresentation.Group, store: AppStore) {
        titleLabel.stringValue = group.title
        subtitleLabel.stringValue = group.subtitle ?? ""
        subtitleLabel.isHidden = (group.subtitle ?? "").isEmpty
        countLabel.stringValue = "\(group.tasks.count)"
        switch group.owner {
        case .bot(let id):
            avatar.isHidden = false
            icon.isHidden = true
            if let bot = store.bot(id) { avatar.avatar = bot.avatar }
        case .thread(let id):
            avatar.isHidden = true
            icon.isHidden = false
            icon.image = store.summary(id).map { Theme.logo(for: $0.selection.provider, size: 14) } ?? Theme.symbol("bubble.left", size: 12)
            icon.contentTintColor = .labelColor
        case .project:
            avatar.isHidden = true
            icon.isHidden = false
            icon.image = Theme.symbol("folder", size: 12, weight: .medium)
            icon.contentTintColor = .secondaryLabelColor
        }
        toolTip = [group.title, group.subtitle].compactMap(\.self).joined(separator: "\n")
        setAccessibilityLabel([group.title, group.subtitle].compactMap(\.self).joined(separator: ", "))
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?()
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
}
