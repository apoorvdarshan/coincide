import AppKit
import CoincideKit

extension NSPasteboard.PasteboardType {
    static let coincideProject = NSPasteboard.PasteboardType("com.apoorvdarshan.coincide.project")
}

/// Projects and their threads, ported from T3's sidebar: a source list with a search field,
/// per-project new-thread buttons, status badges, context menus, inline rename, drag to reorder
/// projects and drop to add folders.
final class SidebarViewController: NSViewController {
    /// Called when the user picks a thread, or when the open thread disappears (with its neighbour, or nil).
    var onSelectThread: ((UUID?) -> Void)?

    private let store = AppStore.shared
    private var nodes = SidebarNodeCache()
    private var header: SidebarNode { nodes.header }
    private var token: ObservationToken?

    private lazy var topRows = SidebarHeaderView { AppEvents.newThread() }
    private var searchField: NSSearchField { topRows.searchField }
    private let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()
    private let emptyView = SidebarEmptyView()

    private var selectedThreadID: UUID?
    private var query = ""
    private var searchQuery = PaletteSearch.Query("")
    private var isSearching: Bool { !searchQuery.isEmpty }
    /// Projects showing every thread instead of the first few.
    private var expandedLists: Set<UUID> = []
    private var isSyncingSelection = false
    private var isSyncingExpansion = false
    private var hasLoaded = false
    private var keptIDs: (projects: Set<UUID>, threads: Set<UUID>) = ([], [])
    private var editing: (node: SidebarNode, original: String)?
    private var clockTimer: Timer?
    private var runningTimer: Timer?
    private var jumpHintTimer: Timer?
    private var flagsMonitor: Any?
    private var showsJumpHints = false {
        didSet {
            guard showsJumpHints != oldValue else { return }
            jumpOrder = showsJumpHints ? Array(visibleThreadIDs.prefix(9)) : []
            refreshVisibleThreadRows()
        }
    }
    /// The first nine visible threads while the jump hints show.
    private var jumpOrder: [UUID] = []
    /// The open thread when it is listed past its project's "Show more" cut.
    private var openThreadPastCut: UUID?
    /// The folder the context menu's "Open In" items act on.
    private var menuFolder: URL?

    // MARK: Public API

    /// Highlights the open thread, revealing it if its project is collapsed or its row is past "Show more".
    func select(threadID: UUID?) {
        let changed = threadID != selectedThreadID
        selectedThreadID = threadID
        guard hasLoaded else { return }
        if let threadID, let thread = store.summary(threadID), !isSearching,
            store.project(thread.projectID)?.isExpanded == false
        {
            store.updateProject(thread.projectID) { $0.isExpanded = true }
        }
        let hasRow = threadID.flatMap { nodes.existing(.thread($0)) }.map { outlineView.row(forItem: $0) >= 0 } ?? true
        // A changed selection can move a thread past "Show more" in or out of view.
        if changed || !hasRow {
            rebuild()
        } else {
            syncSelection()
        }
        if let threadID, let node = nodes.existing(.thread(threadID)) {
            let row = outlineView.row(forItem: node)
            if row >= 0 { outlineView.scrollRowToVisible(row) }
        }
    }

    /// Threads in the order the sidebar shows them, for Previous/Next Thread and Command-1…9.
    var visibleThreadIDs: [UUID] {
        header.children.filter { outlineView.isItemExpanded($0) }.flatMap { $0.children.compactMap(\.threadID) }
    }

    /// Starts inline rename, first clearing a search or expanding a project that hides the row.
    func beginRename(threadID: UUID) {
        guard let thread = store.summary(threadID) else { return }
        if isSearching {
            searchField.stringValue = ""
            searchChanged()
        }
        if store.project(thread.projectID)?.isExpanded == false {
            store.updateProject(thread.projectID) { $0.isExpanded = true }
        }
        guard let node = nodes.existing(.thread(threadID)) else { return }
        beginRename(node)
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: View

    override func loadView() {
        // Opaque, a step darker than the conversation, in place of the sidebar's translucent material.
        let root = SolidBackgroundView(color: Theme.sidebarBackground)
        searchField.placeholderString = String(localized: "Search")
        searchField.setAccessibilityLabel(String(localized: "Search threads and projects"))
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        topRows.setNewThreadShortcut(KeyBindingsController.shared.displayString(for: .newThread))
        topRows.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        // Plain, not source list: a source list draws selection with a system material the theme cannot reach.
        outlineView.style = .plain
        outlineView.backgroundColor = .clear
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 14
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.registerForDraggedTypes([.coincideProject, .fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setAccessibilityLabel(String(localized: "Projects and threads"))
        outlineView.onDelete = { [weak self] in self?.deleteSelectedThread() }
        outlineView.onActivate = { AppEvents.post(.coincideFocusComposer) }

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyView.onAddProject = { [weak self] in ThreadActions.addProject(in: self?.view.window) }
        emptyView.isHidden = true
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        for view: NSView in [topRows, scrollView, emptyView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            topRows.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            topRows.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            topRows.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: topRows.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        token = store.observe { [weak self] change in self?.handle(change) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityChanged(_:)), name: .coincideThreadActivityChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(hideJumpHints), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyBindingsChanged), name: KeyBindingsController.didChangeNotification, object: nil)
        // Project folders are moved and deleted in other apps.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        hasLoaded = true
        rebuild()
        if let selectedThreadID { select(threadID: selectedThreadID) }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleTimes(runningOnly: false) }
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.modifiersChanged(event)
            return event
        }
        updateRunningTimer()
    }

    // MARK: Store changes

    private func handle(_ change: StoreChange) {
        switch change {
        case .projects, .threadList:
            rebuild()
        case .thread(let id):
            refreshThreadRow(id)
        case .runState(let id):
            refreshThreadRow(id)
            updateRunningTimer()
        case .items, .settings, .providers:
            break
        }
    }

    @objc private func applicationDidBecomeActive() {
        refreshProjectRows()
    }

    @objc private func activityChanged(_ note: Notification) {
        guard let id = note.userInfo?["threadID"] as? UUID else { return }
        refreshThreadRow(id)
    }

    // MARK: Tree

    private var showsArchived: Bool { UIState.shared.values.showsArchivedThreads }

    /// Recomputes the tree from the store and applies the difference to the outline.
    private func rebuild() {
        guard hasLoaded else { return }
        let oldProjects = header.children
        let oldChildren = Dictionary(uniqueKeysWithValues: oldProjects.map { (ObjectIdentifier($0), $0.children) })
        openThreadPastCut = nil
        var projectNodes: [SidebarNode] = []
        var allThreadIDs = Set<UUID>()
        for project in store.projects {
            let all = store.threads(in: project.id, includeArchived: showsArchived)
            allThreadIDs.formUnion(all.map(\.id))
            var threads = all
            if isSearching {
                let projectMatches =
                    PaletteSearch.scoreTerms(searchQuery, name: project.name, keywords: [], typos: false) != nil
                if !projectMatches {
                    threads = all.filter { thread in
                        PaletteSearch.scoreThread(
                            searchQuery, title: thread.title, branch: thread.branch, project: project.name,
                            updatedAt: thread.updatedAt, typos: false,
                            branchPrefix: store.settings.worktreeBranchPrefix) != nil
                    }
                    if threads.isEmpty { continue }
                }
            }
            let node = nodes.node(.project(project.id))
            node.children = children(for: project, threads: threads)
            projectNodes.append(node)
        }
        header.children = projectNodes
        handOffSelectionIfNeeded(oldChildren: oldChildren)

        if !outlineView.hasRows || oldProjects != projectNodes {
            outlineView.reloadData()
        } else {
            for node in projectNodes {
                let old = oldChildren[ObjectIdentifier(node)] ?? []
                guard old != node.children else { continue }
                apply(from: old, to: node)
            }
        }
        syncExpansion()
        syncSelection()
        refreshProjectRows()
        updateEmptyState()

        let projectIDs = Set(store.projects.map(\.id))
        nodes.prune(keeping: projectIDs.union(keptIDs.projects), threadIDs: allThreadIDs.union(keptIDs.threads))
        keptIDs = (projectIDs, allThreadIDs)
    }

    private func children(for project: Project, threads: [ThreadSummary]) -> [SidebarNode] {
        if threads.isEmpty { return [nodes.node(.empty(project.id))] }
        let limit = UIState.shared.values.sidebarThreadLimit
        if isSearching || limit <= 0 || threads.count <= limit {
            return threads.map { nodes.node(.thread($0.id)) }
        }
        if expandedLists.contains(project.id) {
            return threads.map { nodes.node(.thread($0.id)) } + [nodes.node(.showLess(project.id))]
        }
        // The open thread stays listed past the cut, as in T3, so it alone does not need "Show more".
        var visible = Array(threads.prefix(limit))
        if let selectedThreadID, let open = threads.dropFirst(limit).first(where: { $0.id == selectedThreadID }) {
            visible.append(open)
            openThreadPastCut = open.id
        }
        let visibleIDs = Set(visible.map(\.id))
        let hidden = threads.filter { !visibleIDs.contains($0.id) }
        var result = visible.map { nodes.node(.thread($0.id)) }
        if !hidden.isEmpty {
            let more = nodes.node(.showMore(project.id))
            more.hiddenThreadIDs = hidden.map(\.id)
            result.append(more)
        }
        return result
    }

    /// Inserts and removes changed rows with a fade, so new and reordered threads are easy to follow.
    private func apply(from old: [SidebarNode], to node: SidebarNode) {
        guard outlineView.isItemExpanded(node) else {
            outlineView.reloadItem(node, reloadChildren: true)
            return
        }
        let difference = node.children.difference(from: old)
        var removed = IndexSet()
        var inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        outlineView.beginUpdates()
        if !removed.isEmpty { outlineView.removeItems(at: removed, inParent: node, withAnimation: .effectFade) }
        if !inserted.isEmpty { outlineView.insertItems(at: inserted, inParent: node, withAnimation: .effectFade) }
        outlineView.endUpdates()
        // Rows that kept their place may still show stale "Show more" counts.
        for child in node.children where child.threadID == nil {
            let row = outlineView.row(forItem: child)
            if row >= 0 { outlineView.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
        }
    }

    /// When the open thread is deleted or archived away, opens its neighbour in the same project, as T3 does.
    private func handOffSelectionIfNeeded(oldChildren: [ObjectIdentifier: [SidebarNode]]) {
        guard let selected = selectedThreadID else { return }
        if let thread = store.summary(selected), !thread.isArchived || showsArchived { return }
        var fallback: UUID?
        for siblings in oldChildren.values {
            let ids = siblings.compactMap(\.threadID)
            guard let index = ids.firstIndex(of: selected) else { continue }
            let stillListed = { (id: UUID) in self.nodes.existing(.thread(id)).map { self.isListed($0) } ?? false }
            fallback = ids[(index + 1)...].first(where: stillListed) ?? ids[..<index].last(where: stillListed)
            break
        }
        selectedThreadID = fallback
        let callback = onSelectThread
        DispatchQueue.main.async { callback?(fallback) }
    }

    private func isListed(_ node: SidebarNode) -> Bool {
        header.children.contains { $0.children.contains(node) }
    }

    private func syncExpansion() {
        isSyncingExpansion = true
        defer { isSyncingExpansion = false }
        if !outlineView.isItemExpanded(header) { outlineView.expandItem(header) }
        for node in header.children {
            guard let id = node.projectID else { continue }
            let expand = isSearching || (store.project(id)?.isExpanded ?? true)
            if expand && !outlineView.isItemExpanded(node) {
                outlineView.expandItem(node)
            } else if !expand && outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            }
        }
    }

    private func syncSelection() {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        guard let id = selectedThreadID, let node = nodes.existing(.thread(id)) else {
            outlineView.deselectAll(nil)
            return
        }
        let row = outlineView.row(forItem: node)
        if row < 0 {
            outlineView.deselectAll(nil)
        } else if outlineView.selectedRow != row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    private func updateEmptyState() {
        // Before the first project and chat, the sidebar invites adding a project rather than listing an empty Chats.
        let hasChats = store.chatsProject.map { !store.threads(in: $0.id).isEmpty } ?? false
        if !store.projects.contains(where: { !$0.isChats }), !hasChats {
            emptyView.showNoProjects()
            emptyView.isHidden = false
            scrollView.isHidden = true
        } else if isSearching && header.children.isEmpty {
            emptyView.showNoResults(for: query)
            emptyView.isHidden = false
            scrollView.isHidden = false
        } else {
            emptyView.isHidden = true
            scrollView.isHidden = false
        }
    }

    // MARK: Rows

    private func sidebarNode(atRow row: Int) -> SidebarNode? {
        row >= 0 ? outlineView.item(atRow: row) as? SidebarNode : nil
    }

    /// T3's status priority: approval, then working, then unseen failure, then unseen completion.
    private func status(of threadID: UUID) -> ThreadRowModel.Status {
        let runner = ThreadRunner.shared
        let activity = ThreadActivity.shared
        let pending = activity.pendingApprovalCount(threadID)
        if pending > 0 { return .approval(count: pending) }
        if runner.isStarting(threadID) { return .starting }
        if let turn = runner.turn(threadID) { return .running(since: turn.startedAt) }
        switch activity.unseen(threadID) {
        case .failed?: return .failed
        case .completed?: return .completed
        case nil: return .idle
        }
    }

    private func rowModel(for thread: ThreadSummary, project: Project?) -> ThreadRowModel {
        let status = status(of: thread.id)
        var lines = [thread.title]
        var place = project?.name ?? ""
        if let branch = thread.branch, !branch.isEmpty { place += place.isEmpty ? branch : " · \(branch)" }
        if !place.isEmpty { lines.append(place) }
        if let forkedFrom = ThreadForking.forkedFromDescription(thread.id) { lines.append(forkedFrom) }
        lines.append("\(thread.selection.provider.displayName) · \(ProviderRegistry.shared.displayName(for: thread.selection))")
        let others = thread.sessionProviders.filter { $0 != thread.selection.provider }
        if !others.isEmpty {
            lines.append(String(localized: "Handed off from \(others.map(\.displayName).formatted(.list(type: .and)))"))
        }
        if let label = status.label { lines.append(label) }
        let background = ThreadRunner.shared.backgroundTasks(thread.id)
        if !status.isRunning, !background.isEmpty {
            lines.append(String(localized: "Working in the background: \(background.map(\.task.title).formatted(.list(type: .and)))"))
        }
        // A turn the agent started itself shows as working like any other; the tooltip says why.
        if let note = AgentTurns.shared.runningNote(in: thread.id) { lines.append(note) }
        var jumpHint: String?
        if showsJumpHints, let index = jumpOrder.firstIndex(of: thread.id), let command = KeyCommand.jumpToThread(index + 1) {
            jumpHint = KeyBindingsController.shared.displayString(for: command)
        }
        return ThreadRowModel(
            title: thread.title, provider: thread.selection.provider, isPinned: thread.isPinned,
            isArchived: thread.isArchived, status: status, updatedAt: thread.updatedAt,
            canArchive: ThreadActions.canArchive(thread.id), canFork: ThreadForking.canFork(thread.id),
            hasBackgroundWork: !background.isEmpty, toolTip: lines.joined(separator: "\n"),
            accessibilityLabel: [thread.title, status.label, project?.name].compactMap(\.self).joined(separator: ", "),
            jumpHint: jumpHint)
    }

    /// The most urgent status among threads, for collapsed projects and "Show more" rows.
    private func strongestStatus(of threadIDs: [UUID]) -> ThreadRowModel.Status? {
        let strongest = threadIDs.map(status(of:)).max { $0.priority < $1.priority }
        return strongest == .idle ? nil : strongest
    }

    private func refreshThreadRow(_ id: UUID) {
        guard let node = nodes.existing(.thread(id)), let thread = store.summary(id) else { return }
        let row = outlineView.row(forItem: node)
        if row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThreadCell {
            cell.configure(rowModel(for: thread, project: store.project(thread.projectID)))
        }
        refreshProjectRows(only: thread.projectID)
    }

    /// Updates project rows (their collapsed status) and "Show more" rows (their hidden status).
    private func refreshProjectRows(only projectID: UUID? = nil) {
        for node in header.children {
            guard let id = node.projectID, projectID == nil || id == projectID else { continue }
            let row = outlineView.row(forItem: node)
            if row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ProjectCell,
                let project = store.project(id)
            {
                cell.configure(project: project, hiddenStatus: collapsedStatus(of: node))
            }
            if let more = nodes.existing(.showMore(id)) {
                let moreRow = outlineView.row(forItem: more)
                if moreRow >= 0, let cell = outlineView.view(atColumn: 0, row: moreRow, makeIfNecessary: false) as? SidebarNoteCell {
                    configureShowMore(cell, more)
                }
            }
        }
    }

    private func collapsedStatus(of node: SidebarNode) -> ThreadRowModel.Status? {
        guard !outlineView.isItemExpanded(node), let id = node.projectID else { return nil }
        return strongestStatus(of: store.threads(in: id).map(\.id))
    }

    private func configureShowMore(_ cell: SidebarNoteCell, _ node: SidebarNode) {
        guard let id = node.projectID else { return }
        cell.configure(
            text: String(localized: "Show \(node.hiddenThreadIDs.count) more"), symbol: "chevron.down",
            hiddenStatus: strongestStatus(of: node.hiddenThreadIDs)
        ) { [weak self] in self?.showAllThreads(true, in: id) }
    }

    /// "Show more" and "Show less".
    private func showAllThreads(_ showAll: Bool, in projectID: UUID) {
        if showAll { expandedLists.insert(projectID) } else { expandedLists.remove(projectID) }
        rebuild()
    }

    private func refreshVisibleThreadRows() {
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let id = self.sidebarNode(atRow: row)?.threadID, let thread = self.store.summary(id),
                let cell = rowView.view(atColumn: 0) as? ThreadCell
            else { return }
            cell.configure(self.rowModel(for: thread, project: self.store.project(thread.projectID)))
        }
    }

    private func refreshVisibleTimes(runningOnly: Bool) {
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let id = self.sidebarNode(atRow: row)?.threadID, let cell = rowView.view(atColumn: 0) as? ThreadCell else { return }
            if !runningOnly || ThreadRunner.shared.isRunning(id) { cell.refreshTime() }
        }
    }

    private func updateRunningTimer() {
        let running = !ThreadRunner.shared.runningThreadIDs.isEmpty
        if running, runningTimer == nil {
            runningTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibleTimes(runningOnly: true) }
            }
        } else if !running {
            runningTimer?.invalidate()
            runningTimer = nil
        }
    }

    // MARK: Go to Thread hints

    /// Holding the modifier keys of a Go to Thread shortcut (Command, unless the user changed them) shows each of
    /// the first nine threads' shortcut, as T3 does.
    private func modifiersChanged(_ event: NSEvent) {
        hideJumpHints()
        guard KeyBindingsController.shared.showsThreadJumpHints(for: event.modifierFlags), view.window?.isKeyWindow == true
        else { return }
        // Wait a moment, so ordinary shortcuts do not flash the hints.
        jumpHintTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSApp.isActive, KeyBindingsController.shared.showsThreadJumpHints(for: NSEvent.modifierFlags)
                else { return }
                self.showsJumpHints = true
            }
        }
    }

    /// Also runs when Coincide goes to the background, which hides the keys' release from it.
    @objc private func hideJumpHints() {
        jumpHintTimer?.invalidate()
        jumpHintTimer = nil
        showsJumpHints = false
    }

    /// New shortcuts change the hints shown, or whether the keys held still show them.
    @objc private func keyBindingsChanged() {
        topRows.setNewThreadShortcut(KeyBindingsController.shared.displayString(for: .newThread))
        guard showsJumpHints else { return }
        if KeyBindingsController.shared.showsThreadJumpHints(for: NSEvent.modifierFlags) {
            refreshVisibleThreadRows()
        } else {
            hideJumpHints()
        }
    }

    // MARK: Actions

    @objc private func searchChanged() {
        query = searchField.stringValue
        searchQuery = PaletteSearch.Query(query)
        rebuild()
    }

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard let node = sidebarNode(atRow: row) else { return }
        switch node.kind {
        case .project:
            let point = outlineView.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            // The disclosure triangle toggles the row itself.
            guard !outlineView.frameOfOutlineCell(atRow: row).contains(point) else { return }
            if outlineView.isItemExpanded(node) {
                outlineView.animator().collapseItem(node)
            } else {
                outlineView.animator().expandItem(node)
            }
        case .showMore(let id):
            showAllThreads(true, in: id)
        case .showLess(let id):
            showAllThreads(false, in: id)
        case .header, .thread, .empty:
            break
        }
    }

    @objc private func rowDoubleClicked() {
        let row = outlineView.clickedRow
        guard let node = sidebarNode(atRow: row), node.threadID != nil else { return }
        beginRename(node)
    }

    @objc private func addProject() {
        ThreadActions.addProject(in: view.window)
    }

    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        let archived = NSMenuItem(
            title: String(localized: "Show Archived Threads"), action: #selector(toggleShowArchived), keyEquivalent: "")
        archived.target = self
        archived.state = showsArchived ? .on : .off
        menu.addItem(archived)
        let limitItem = NSMenuItem(title: String(localized: "Threads per Project"), action: nil, keyEquivalent: "")
        let limits = NSMenu()
        for limit in [3, 6, 10, 20, 0] {
            let title = limit == 0 ? String(localized: "All") : limit.formatted()
            let item = NSMenuItem(title: title, action: #selector(setThreadLimit(_:)), keyEquivalent: "")
            item.target = self
            item.tag = limit
            item.state = UIState.shared.values.sidebarThreadLimit == limit ? .on : .off
            limits.addItem(item)
        }
        limitItem.submenu = limits
        menu.addItem(limitItem)
        menu.addItem(.separator())
        let expand = NSMenuItem(title: String(localized: "Expand All Projects"), action: #selector(expandAll), keyEquivalent: "")
        expand.target = self
        let collapse = NSMenuItem(
            title: String(localized: "Collapse All Projects"), action: #selector(collapseAll), keyEquivalent: "")
        collapse.target = self
        menu.addItem(expand)
        menu.addItem(collapse)
        ThemedPopup.show(menu: menu, from: sender, preferAbove: false)
    }

    @objc private func toggleShowArchived() {
        UIState.shared.update { $0.showsArchivedThreads.toggle() }
        rebuild()
    }

    @objc private func setThreadLimit(_ sender: NSMenuItem) {
        UIState.shared.update { $0.sidebarThreadLimit = sender.tag }
        expandedLists.removeAll()
        rebuild()
    }

    @objc private func expandAll() {
        for project in store.projects where !project.isExpanded {
            store.updateProject(project.id) { $0.isExpanded = true }
        }
    }

    @objc private func collapseAll() {
        for project in store.projects where project.isExpanded {
            store.updateProject(project.id) { $0.isExpanded = false }
        }
    }

    private func deleteSelectedThread() {
        guard let id = sidebarNode(atRow: outlineView.selectedRow)?.threadID else { return }
        ThreadActions.delete(id, in: view.window)
    }

    /// A thread row's archive button and VoiceOver actions.
    private func perform(_ command: ThreadCell.Command, onThread id: UUID) {
        switch command {
        case .togglePin: ThreadActions.togglePin(id)
        case .rename: beginRename(threadID: id)
        case .fork: ThreadForking.fork(id)
        case .toggleArchived: ThreadActions.toggleArchived(id)
        case .delete: ThreadActions.delete(id, in: view.window)
        }
    }

    // MARK: Rename

    private func beginRename(_ node: SidebarNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
            let field = cell.textField
        else { return }
        editing = (node, field.stringValue)
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endRename(_ field: NSTextField) {
        guard let editing else { return }
        self.editing = nil
        field.isEditable = false
        field.isSelectable = false
        field.delegate = nil
        let title = field.stringValue
        switch editing.node.kind {
        case .thread(let id):
            ThreadActions.rename(id, to: title)
            field.stringValue = store.summary(id)?.title ?? editing.original
        case .project(let id):
            ThreadActions.rename(project: id, to: title)
            field.stringValue = store.project(id)?.name ?? editing.original
        default:
            break
        }
    }
}

// MARK: - Outline data source and delegate

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SidebarNode else { return store.projects.isEmpty ? 0 : 1 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNode else { return header }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        switch node.kind {
        case .header, .project: return true
        default: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind == .header
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind != .header
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind != .header
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.isSelectable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SidebarNode else { return 28 }
        switch node.kind {
        case .header: return 26
        case .project, .thread: return 28
        case .showMore, .showLess, .empty: return 24
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? SidebarNode)?.threadID.flatMap { store.summary($0)?.title }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ThemedTableRowView(inset: 10)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        switch node.kind {
        case .header:
            return reuse("header") {
                SidebarHeaderCell(target: self, addAction: #selector(addProject), optionsAction: #selector(showOptions(_:)))
            }
        case .project(let id):
            let cell = reuse("project") { ProjectCell(frame: .zero) }
            if let project = store.project(id) {
                cell.configure(project: project, hiddenStatus: collapsedStatus(of: node))
            }
            cell.onNewThread = { ThreadActions.newThread(in: id) }
            return cell
        case .thread(let id):
            let cell = reuse("thread") { ThreadCell(frame: .zero) }
            if let thread = store.summary(id) {
                cell.configure(rowModel(for: thread, project: store.project(thread.projectID)))
            }
            cell.onCommand = { [weak self] command in self?.perform(command, onThread: id) }
            return cell
        case .showMore:
            let cell = reuse("note") { SidebarNoteCell(frame: .zero) }
            configureShowMore(cell, node)
            return cell
        case .showLess(let id):
            let cell = reuse("note") { SidebarNoteCell(frame: .zero) }
            cell.configure(text: String(localized: "Show less"), symbol: "chevron.up") { [weak self] in
                self?.showAllThreads(false, in: id)
            }
            return cell
        case .empty(let id):
            let cell = reuse("note") { SidebarNoteCell(frame: .zero) }
            let isChats = store.project(id)?.isChats == true
            cell.configure(text: isChats ? String(localized: "No chats yet") : String(localized: "No threads yet"), symbol: nil)
            return cell
        }
    }

    private func reuse<Cell: NSView>(_ identifier: String, make: () -> Cell) -> Cell {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let cell = outlineView.makeView(withIdentifier: id, owner: self) as? Cell { return cell }
        let cell = make()
        cell.identifier = id
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        guard let id = sidebarNode(atRow: outlineView.selectedRow)?.threadID else {
            // Clicking empty space must not close the open thread.
            syncSelection()
            return
        }
        guard id != selectedThreadID else { return }
        let previous = selectedThreadID
        selectedThreadID = id
        onSelectThread?(id)
        // The previously open thread was only listed because it was open; tuck it back behind "Show more".
        if previous != nil, previous == openThreadPastCut {
            DispatchQueue.main.async { [weak self] in self?.rebuild() }
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        expansionChanged(notification, expanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        expansionChanged(notification, expanded: false)
    }

    private func expansionChanged(_ notification: Notification, expanded: Bool) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode, case .project(let id) = node.kind else { return }
        refreshProjectRows(only: id)
        guard !isSyncingExpansion, !isSearching, store.project(id)?.isExpanded != expanded else { return }
        store.updateProject(id) { $0.isExpanded = expanded }
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarNode, case .project(let id) = node.kind, !isSearching,
            let project = store.project(id), !project.isChats
        else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(id.uuidString, forType: .coincideProject)
        pasteboardItem.setString(project.url.absoluteString, forType: .fileURL)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        if pasteboard.availableType(from: [.coincideProject]) != nil, (info.draggingSource as AnyObject?) === outlineView {
            guard !isSearching else { return [] }
            outlineView.setDropItem(header, dropChildIndex: projectDropIndex(item: item as? SidebarNode, childIndex: index))
            return .move
        }
        guard !SidebarEmptyView.folders(on: pasteboard).isEmpty else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    /// Turns any proposed drop point into a gap between projects.
    private func projectDropIndex(item: SidebarNode?, childIndex: Int) -> Int {
        guard let item else { return header.children.count }
        if item.kind == .header {
            return childIndex == NSOutlineViewDropOnItemIndex ? header.children.count : childIndex
        }
        let owner = item.projectID.flatMap { id in header.children.firstIndex { $0.projectID == id } }
            ?? header.children.firstIndex { $0.children.contains(item) }
        guard let owner else { return header.children.count }
        if case .project = item.kind, childIndex == NSOutlineViewDropOnItemIndex { return owner }
        return owner + 1
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pasteboard = info.draggingPasteboard
        if let value = pasteboard.string(forType: .coincideProject), (info.draggingSource as AnyObject?) === outlineView {
            guard let id = UUID(uuidString: value), let source = store.projects.firstIndex(where: { $0.id == id }) else {
                return false
            }
            // Chats stay below every project.
            let lastProject = store.projects.lastIndex { !$0.isChats } ?? 0
            let destination = min(index > source ? index - 1 : index, lastProject)
            if destination != source { store.moveProject(from: source, to: destination) }
            return true
        }
        let folders = SidebarEmptyView.folders(on: pasteboard)
        guard !folders.isEmpty else { return false }
        ThreadActions.addProjects(folders)
        return true
    }
}

// MARK: - Context menu

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuFolder = nil
        let node = sidebarNode(atRow: outlineView.clickedRow)
        switch node?.kind {
        case .thread(let id):
            buildThreadMenu(menu, id)
        case .project(let id), .showMore(let id), .showLess(let id), .empty(let id):
            buildProjectMenu(menu, id)
        case .header, nil:
            menu.addItem(item(String(localized: "Add Project…"), #selector(addProject)))
            menu.addItem(.separator())
            let archived = item(String(localized: "Show Archived Threads"), #selector(toggleShowArchived))
            archived.state = showsArchived ? .on : .off
            menu.addItem(archived)
            menu.addItem(item(String(localized: "Expand All Projects"), #selector(expandAll)))
            menu.addItem(item(String(localized: "Collapse All Projects"), #selector(collapseAll)))
        }
    }

    private func buildThreadMenu(_ menu: NSMenu, _ id: UUID) {
        guard let thread = store.summary(id) else { return }
        menuFolder = ThreadActions.folder(for: id)
        menu.addItem(item(String(localized: "Rename…"), #selector(renameFromMenu(_:)), id))
        menu.addItem(item(thread.isPinned ? String(localized: "Unpin") : String(localized: "Pin"), #selector(pinFromMenu(_:)), id))
        let unseen = ThreadActivity.shared.unseen(id) != nil
        menu.addItem(
            item(unseen ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"), #selector(toggleUnread(_:)), id))
        if let branch = thread.branch, !branch.isEmpty {
            menu.addItem(item(String(localized: "New Thread on \(branch)"), #selector(newThreadOnBranch(_:)), id))
        }
        let fork = item(String(localized: "Fork Thread"), #selector(forkFromMenu(_:)), id)
        fork.isEnabled = ThreadForking.canFork(id)
        menu.addItem(fork)
        menu.addItem(.separator())
        addOpenItems(to: menu)
        menu.addItem(item(String(localized: "Copy Thread ID"), #selector(copyThreadID(_:)), id))
        menu.addItem(.separator())
        let archive = item(
            thread.isArchived ? String(localized: "Unarchive") : String(localized: "Archive"), #selector(archiveFromMenu(_:)), id)
        archive.isEnabled = ThreadActions.canArchive(id)
        menu.addItem(archive)
        menu.addItem(item(String(localized: "Delete…"), #selector(deleteFromMenu(_:)), id))
    }

    private func buildProjectMenu(_ menu: NSMenu, _ id: UUID) {
        guard let project = store.project(id) else { return }
        menuFolder = project.url
        if project.isChats {
            // Chats have no folder of the user's to open, rename or remove.
            menu.addItem(item(String(localized: "New Chat"), #selector(newThreadFromMenu(_:)), id))
            return
        }
        menu.addItem(item(String(localized: "New Thread"), #selector(newThreadFromMenu(_:)), id))
        menu.addItem(.separator())
        addOpenItems(to: menu)
        menu.addItem(.separator())
        if !FileManager.default.fileExists(atPath: project.path) {
            menu.addItem(item(String(localized: "Locate Folder…"), #selector(locateProjectFromMenu(_:)), id))
        }
        menu.addItem(item(String(localized: "Rename…"), #selector(renameProjectFromMenu(_:)), id))
        menu.addItem(item(String(localized: "Remove from Coincide…"), #selector(removeProjectFromMenu(_:)), id))
    }

    private func addOpenItems(to menu: NSMenu) {
        OpenTargets.reload()
        if let preferred = OpenTargets.preferred {
            let open = item(String(localized: "Open in \(preferred.name)"), #selector(openInTarget(_:)))
            open.representedObject = preferred.bundleID
            open.image = preferred.icon
            menu.addItem(open)
        }
        let openIn = NSMenuItem(title: String(localized: "Open In"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for entry in OpenTargets.menuItems(target: self, action: #selector(openInTarget(_:))) { submenu.addItem(entry) }
        openIn.submenu = submenu
        menu.addItem(openIn)
        menu.addItem(item(String(localized: "Reveal in Finder"), #selector(revealFromMenu)))
        menu.addItem(item(String(localized: "Copy Path"), #selector(copyPathFromMenu)))
    }

    private func item(_ title: String, _ action: Selector, _ id: UUID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    @objc private func renameFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        beginRename(threadID: id)
    }

    @objc private func pinFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        ThreadActions.togglePin(id)
    }

    @objc private func toggleUnread(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        if ThreadActivity.shared.unseen(id) != nil {
            ThreadActivity.shared.markSeen(id)
        } else {
            ThreadActions.markUnread(id)
        }
    }

    @objc private func newThreadOnBranch(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let thread = store.summary(id) else { return }
        ThreadActions.newThread(in: thread.projectID, basedOn: thread)
    }

    /// Forks the conversation through its latest settled turn and opens the fork.
    @objc private func forkFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        ThreadForking.fork(id)
    }

    @objc private func copyThreadID(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        NSPasteboard.general.setText(id.uuidString)
    }

    @objc private func archiveFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        ThreadActions.toggleArchived(id)
    }

    @objc private func deleteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        ThreadActions.delete(id, in: view.window)
    }

    @objc private func newThreadFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        ThreadActions.newThread(in: id)
    }

    @objc private func renameProjectFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let node = nodes.existing(.project(id)) else { return }
        beginRename(node)
    }

    @objc private func locateProjectFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        ThreadActions.locateProject(id, in: view.window)
    }

    @objc private func removeProjectFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        ThreadActions.removeProject(id, in: view.window)
    }

    @objc private func openInTarget(_ sender: NSMenuItem) {
        guard let folder = menuFolder, let id = sender.representedObject as? String, let target = OpenTargets.target(withBundleID: id)
        else { return }
        OpenTargets.open(folder, with: target)
    }

    @objc private func revealFromMenu() {
        guard let menuFolder else { return }
        ThreadActions.reveal(menuFolder)
    }

    @objc private func copyPathFromMenu() {
        guard let menuFolder else { return }
        NSPasteboard.general.setText(menuFolder.path)
    }
}

// MARK: - Search field and rename editing

extension SidebarViewController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === searchField {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
                // Move into the results, opening the first thread.
                guard let first = (0..<outlineView.numberOfRows).first(where: { sidebarNode(atRow: $0)?.isSelectable == true }) else {
                    return false
                }
                view.window?.makeFirstResponder(outlineView)
                outlineView.selectRowIndexes([first], byExtendingSelection: false)
                return true
            default:
                return false
            }
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let editing, let field = control as? NSTextField {
            field.stringValue = editing.original
            view.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field !== searchField else { return }
        endRename(field)
    }
}

// MARK: - Outline view

/// Adds Delete to delete the selected thread and Return to jump to the composer.
final class SidebarOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    var onActivate: (() -> Void)?

    var hasRows: Bool { numberOfRows > 0 }

    override func menu(for event: NSEvent) -> NSMenu? {
        ThemedContextMenu.show(super.menu(for: event), for: event, in: window)
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .delete?, .deleteForward?:
            onDelete?()
        case .carriageReturn?, .enter?:
            onActivate?()
        default:
            super.keyDown(with: event)
        }
    }
}
