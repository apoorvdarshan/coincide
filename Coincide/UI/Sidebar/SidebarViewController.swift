import AppKit
import CoincideKit

extension NSPasteboard.PasteboardType {
    static let coincideProject = NSPasteboard.PasteboardType("com.apoorvdarshan.coincide.project")
    static let coincideThread = NSPasteboard.PasteboardType("com.apoorvdarshan.coincide.thread")
    static let coincideSection = NSPasteboard.PasteboardType("com.apoorvdarshan.coincide.section")
    static let coincideBot = NSPasteboard.PasteboardType("com.apoorvdarshan.coincide.bot")
}

/// Projects and their threads, ported from T3's sidebar: a source list with a search field,
/// per-project new-thread buttons, status badges, context menus, inline rename, drag to reorder
/// projects, drag threads to another project and drop to add folders. Pinned threads of every
/// project are listed together in a section of their own; sections can be dragged into any order, and collapsed to
/// their header by clicking it.
final class SidebarViewController: NSViewController {
    /// Called when the user picks a thread, or when the open thread disappears (with its neighbour, or nil).
    var onSelectThread: ((UUID?) -> Void)?

    private let store = AppStore.shared
    private var nodes = SidebarNodeCache()
    private var header: SidebarNode { nodes.header }
    private var pinnedSection: SidebarNode { nodes.pinned }
    private var botsSection: SidebarNode { nodes.bots }
    private var sections: [SidebarNode] = []
    /// Real projects live under Projects; project-free conversations live directly under Chats, and pinned threads
    /// of both directly under Pinned. In the order the sidebar shows them.
    private var threadContainers: [SidebarNode] {
        sections.flatMap { $0 === header ? header.children : [$0] }
    }
    private var token: ObservationToken?

    private lazy var topRows = SidebarHeaderView(
        onNewThread: { AppEvents.newThread() },
        onSchedules: { NSApp.sendAction(#selector(MainWindowController.toggleSchedulesPanel(_:)), to: nil, from: nil) })
    private var schedulesOpen = false
    private var searchField: NSSearchField { topRows.searchField }
    private let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()
    private let emptyView = SidebarEmptyView()

    private var selectedThreadID: UUID?
    private var selectedInboxIDs: Set<UUID> = []
    private var query = ""
    /// Threads whose messages match the search, with the matching line, found after a short pause in typing.
    private var messageMatches: [UUID: String] = [:]
    private var messageSearch: Task<Void, Never>?
    private var searchQuery = PaletteSearch.Query("")
    private var isSearching: Bool { !searchQuery.isEmpty }
    /// Projects showing every thread instead of the first few.
    private var expandedLists: Set<UUID> = []
    private var isSyncingSelection = false
    private var isSyncingExpansion = false
    private var hasLoaded = false
    private var keptIDs: (projects: Set<UUID>, threads: Set<UUID>) = ([], [])
    private var editing: (node: SidebarNode, original: String)?
    /// Watches for a click outside the field being renamed, which finishes the rename.
    private var renameClickMonitor: Any?
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
    /// The cut the lists were last built with, which follows the sidebar's height unless the user chose one.
    private var appliedThreadLimit = 0
    /// The sections the outline was last built with collapsed, so a change slides their rows in or out.
    private var appliedCollapsed: Set<SidebarSection> = []
    /// The threads each collapsed section hides, for the status dot on its header.
    private var hiddenThreads: [SidebarSection: [UUID]] = [:]
    /// The folder the context menu's "Open In" items act on.
    private var menuFolder: URL?

    // MARK: Public API

    /// Highlights the open thread, revealing it if its project is collapsed or its row is past "Show more". A newly
    /// opened thread also expands its collapsed section; the thread open at launch leaves it as the user left it.
    func select(threadID: UUID?) {
        let changed = threadID != selectedThreadID
        selectedThreadID = threadID
        selectedInboxIDs = Set([threadID].compactMap { $0 })
        guard hasLoaded else { return }
        if changed, let threadID { revealSection(of: threadID) }
        if let threadID, let thread = store.summary(threadID), !isSearching, !thread.isPinned,
            let project = store.project(thread.projectID), !project.isChats, !project.isExpanded
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
        threadContainers.filter { outlineView.isItemExpanded($0) }.flatMap { $0.children.compactMap(\.threadID) }
    }

    /// Starts inline rename, first clearing a search or expanding a project that hides the row.
    func beginRename(threadID: UUID) {
        guard let thread = store.summary(threadID) else { return }
        if isSearching {
            searchField.stringValue = ""
            searchChanged()
        }
        if !thread.isPinned, let project = store.project(thread.projectID), !project.isChats, !project.isExpanded {
            store.updateProject(thread.projectID) { $0.isExpanded = true }
        }
        if revealSection(of: threadID) { rebuild() }
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
        updateSchedulesRow()
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
        outlineView.allowsMultipleSelection = true
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.registerForDraggedTypes([.coincideSection, .coincideBot, .coincideProject, .coincideThread, .fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setAccessibilityLabel(String(localized: "Projects and threads"))
        outlineView.onDelete = { [weak self] in self?.deleteSelectedThread() }
        outlineView.onActivate = { AppEvents.post(.coincideFocusComposer) }
        outlineView.onMouseActivation = { [weak self] node, modifiers, rename in
            guard let self else { return }
            let row = self.outlineView.row(forItem: node)
            if rename, node.threadID == self.selectedThreadID, self.editing == nil {
                self.beginRename(node)
            } else {
                self.focusComposerAfterClick(at: row, modifiers: modifiers)
            }
        }

        scrollView.documentView = outlineView
        // The "Show more" cut follows the sidebar's height.
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyView.onAddProject = { [weak self] in ThreadActions.addProject(in: self?.view.window) }
        emptyView.isHidden = true
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        // Undo after deleting, archiving or moving threads is Edit › Undo (⌘Z), not a bar of its own.
        for view: NSView in [topRows, scrollView, emptyView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            topRows.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            topRows.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            topRows.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: topRows.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),
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
            self, selector: #selector(inboxChanged), name: ThreadInbox.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutChanged), name: .coincideSidebarLayoutChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityChanged(_:)), name: .coincideThreadActivityChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(hideJumpHints), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyBindingsChanged), name: KeyBindingsController.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(schedulesChanged), name: ScheduledTasks.didChange, object: nil)
        // Project folders are moved and deleted in other apps.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sidebarResized), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sidebarResized), name: NSWindow.didEndLiveResizeNotification, object: nil)
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
        case .projects, .threadList, .bots:
            rebuild()
        case .thread(let id):
            refreshThreadRow(id)
        case .runState(let id):
            refreshSnoozedThread(id)
            updateRunningTimer()
        case .items(let id, _, _):
            if UIState.shared.values.settledThreads[id.uuidString] != nil { rebuild() }
        case .settings, .providers:
            break
        }
    }

    @objc private func applicationDidBecomeActive() {
        refreshProjectRows()
    }

    /// Rebuilds when a taller or shorter sidebar moves the automatic "Show more" cut, once a live resize ends.
    @objc private func sidebarResized() {
        guard hasLoaded, UIState.shared.values.sidebarThreadsPerProject == nil, view.window?.inLiveResize != true,
            threadLimit != appliedThreadLimit
        else { return }
        rebuild()
    }

    @objc private func activityChanged(_ note: Notification) {
        guard let id = note.userInfo?["threadID"] as? UUID else { return }
        refreshSnoozedThread(id)
    }

    private func refreshSnoozedThread(_ id: UUID) {
        if store.summary(id)?.snoozedUntil != nil || UIState.shared.values.settledThreads[id.uuidString] != nil { rebuild() }
        refreshThreadRow(id)
    }

    // MARK: Tree

    private var showsArchived: Bool { UIState.shared.values.showsArchivedThreads }
    private var showsSnoozed: Bool { UIState.shared.values.showsSnoozedThreads }
    private var showsSettled: Bool { UIState.shared.values.showsSettledThreads }

    /// Sections collapsed to their header. A search lists every match, collapsed or not.
    private var collapsedSections: Set<SidebarSection> {
        isSearching ? [] : SidebarOrdering.collapsedSections(saved: UIState.shared.values.collapsedSections)
    }

    /// Every node whose children the outline shows: the sections, and the projects under Projects.
    private var parentNodes: [SidebarNode] {
        sections + header.children
    }

    /// Recomputes the tree from the store and applies the difference to the outline.
    private func rebuild() {
        guard hasLoaded else { return }
        let oldSections = sections
        let oldProjects = header.children
        let oldChildren = Dictionary(parentNodes.map { (ObjectIdentifier($0), $0.children) }, uniquingKeysWith: { first, _ in first })
        openThreadPastCut = nil
        let ui = UIState.shared.values
        let limit = threadLimit
        appliedThreadLimit = limit
        let collapsed = collapsedSections
        let toggled = collapsed.symmetricDifference(appliedCollapsed)
        appliedCollapsed = collapsed
        hiddenThreads = [:]
        var projectNodes: [SidebarNode] = []
        var chatsNode: SidebarNode?
        var pinned: [ThreadSummary] = []
        var allThreadIDs = Set<UUID>()
        let now = Date()
        let lastActivity = SidebarOrdering.lastActivity(of: store.threadSummaries.values)
        for project in SidebarOrdering.sortedProjects(store.projects, by: ui.projectSort, lastActivity: lastActivity) {
            let listed = store.threads(in: project.id, includeArchived: showsArchived).filter { thread in
                (showsSnoozed || isSearching || !ThreadSnooze.isHidden(thread, now: now))
                    && (showsSettled || isSearching || !ThreadInbox.isHidden(thread))
            }
            let all = SidebarOrdering.sortedThreads(listed, by: project.isChats ? ui.chatSort : ui.threadSort)
            allThreadIDs.formUnion(all.map(\.id))
            var threads = all
            var projectMatches = true
            if isSearching {
                projectMatches = PaletteSearch.scoreTerms(searchQuery, name: project.name, keywords: [], typos: false) != nil
                if !projectMatches {
                    threads = all.filter { thread in
                        messageMatches[thread.id] != nil
                            || PaletteSearch.scoreThread(
                                searchQuery, title: thread.title, branch: thread.branch, project: project.name,
                                updatedAt: thread.updatedAt, typos: false,
                                branchPrefix: store.settings.worktreeBranchPrefix) != nil
                    }
                }
            }
            // Pinned threads are listed under Pinned instead, though they stay in their project.
            pinned += threads.filter(\.isPinned)
            threads.removeAll(where: \.isPinned)
            if !projectMatches && threads.isEmpty { continue }
            let section: SidebarSection = project.isChats ? .chats : .projects
            hiddenThreads[section, default: []] += threads.map(\.id)
            let node = nodes.node(project.isChats ? .chats(project.id) : .project(project.id))
            node.children = collapsed.contains(section) ? [] : children(for: project, threads: threads, limit: limit)
            if project.isChats { chatsNode = node } else { projectNodes.append(node) }
        }
        let pinnedIDs = pinnedOrder().filter(Set(pinned.map(\.id)).contains)
        let bots = listedBots()
        hiddenThreads[.pinned] = pinnedIDs
        if collapsed.contains(.bots) { hiddenThreads[.bots] = bots.flatMap { store.conversations(of: $0.id).map(\.id) } }
        // A collapsed section keeps its header; its rows go.
        pinnedSection.children = collapsed.contains(.pinned) ? [] : pinnedIDs.map { nodes.node(.thread($0)) }
        header.children = collapsed.contains(.projects) ? [] : projectNodes
        botsSection.children = collapsed.contains(.bots) ? [] : bots.map { nodes.node(.bot($0.id)) }
        var shown: [SidebarSection: SidebarNode] = [:]
        if !bots.isEmpty { shown[.bots] = botsSection }
        if !pinnedIDs.isEmpty { shown[.pinned] = pinnedSection }
        if !isSearching || !projectNodes.isEmpty { shown[.projects] = header }
        if let chatsNode { shown[.chats] = chatsNode }
        sections = SidebarOrdering.sectionOrder(saved: ui.sidebarSections).compactMap { shown[$0] }
        handOffSelectionIfNeeded(oldChildren: oldChildren)

        // Collapsing or expanding Projects slides its projects out or in rather than reloading the outline.
        let projectsChanged = oldProjects != header.children && !toggled.contains(.projects)
        if !outlineView.hasRows || projectsChanged || oldSections != sections {
            outlineView.reloadData()
        } else {
            // Nodes new to the outline arrive with their parent.
            let changed = parentNodes.filter { node in
                oldChildren[ObjectIdentifier(node)].map { $0 != node.children } ?? false
            }
            apply(changed, from: oldChildren, sliding: Set(sections.filter { $0.section.map(toggled.contains) == true }))
        }
        syncExpansion()
        syncSelection()
        refreshProjectRows()
        refreshSectionHeaders()
        updateEmptyState()

        let projectIDs = Set(store.projects.map(\.id))
        nodes.prune(keeping: projectIDs.union(keptIDs.projects), threadIDs: allThreadIDs.union(keptIDs.threads))
        keptIDs = (projectIDs, allThreadIDs)
    }

    /// The bots the Bots section lists, in the chosen order: all of them, or while searching those whose name or
    /// conversations match.
    private func listedBots() -> [Bot] {
        let bots = SidebarOrdering.sortedBots(
            store.bots, by: UIState.shared.values.botSort,
            lastActivity: SidebarOrdering.lastBotActivity(of: store.threadSummaries.values))
        guard isSearching else { return bots }
        return bots.filter { bot in
            PaletteSearch.scoreTerms(searchQuery, name: bot.displayName, keywords: [], typos: false) != nil
                || store.conversations(of: bot.id).contains { thread in
                    messageMatches[thread.id] != nil
                        || PaletteSearch.scoreTerms(searchQuery, name: thread.title, keywords: [], typos: false) != nil
                }
        }
    }

    /// The section a thread is listed in.
    private func section(of threadID: UUID) -> SidebarSection? {
        guard let thread = store.summary(threadID) else { return nil }
        if thread.botID != nil { return .bots }
        if thread.isPinned { return .pinned }
        return store.project(thread.projectID)?.isChats == true ? .chats : .projects
    }

    /// Expands the collapsed section a thread is listed in. Returns whether it was collapsed; the caller rebuilds.
    @discardableResult
    private func revealSection(of threadID: UUID) -> Bool {
        guard let section = section(of: threadID), collapsedSections.contains(section) else { return false }
        UIState.shared.update { values in
            values.collapsedSections = SidebarOrdering.savedCollapsedSections(
                saved: values.collapsedSections, setting: section, collapsed: false)
        }
        return true
    }

    /// Collapses a section to its header, or expands it again. A search shows every section in full, so it waits.
    private func toggleSection(_ section: SidebarSection) {
        guard !isSearching else { return }
        let collapse = !collapsedSections.contains(section)
        UIState.shared.update { values in
            values.collapsedSections = SidebarOrdering.savedCollapsedSections(
                saved: values.collapsedSections, setting: section, collapsed: collapse)
        }
        rebuild()
    }

    /// Updates the section headers: their disclosure state, and the status a collapsed section hides.
    private func refreshSectionHeaders() {
        for node in sections {
            let row = outlineView.row(forItem: node)
            if row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarHeaderCell {
                configureHeader(cell, node)
            }
        }
    }

    private func configureHeader(_ cell: SidebarHeaderCell, _ node: SidebarNode) {
        guard let section = node.section else { return }
        let collapsed = collapsedSections.contains(section)
        cell.configure(
            isCollapsed: collapsed, canCollapse: !isSearching,
            hiddenStatus: collapsed ? strongestStatus(of: hiddenThreads[section] ?? []) : nil)
        cell.onToggle = { [weak self] in self?.toggleSection(section) }
    }

    /// Threads a list shows before "Show more": the user's choice, or as many as a little more than fill the sidebar.
    private var threadLimit: Int {
        UIState.shared.values.sidebarThreadsPerProject
            ?? SidebarOrdering.automaticThreadLimit(visibleHeight: scrollView.contentView.bounds.height)
    }

    /// The Pinned section's order, saved as threads are pinned and unpinned anywhere.
    private func pinnedOrder() -> [UUID] {
        let saved = UIState.shared.values.pinnedThreads
        let order = SidebarOrdering.pinnedOrder(saved: saved, pinned: store.threadSummaries.values.filter(\.isPinned))
        let strings = order.map(\.uuidString)
        if strings != saved { UIState.shared.update { $0.pinnedThreads = strings } }
        return order
    }

    private func children(for project: Project, threads: [ThreadSummary], limit: Int) -> [SidebarNode] {
        if threads.isEmpty { return [nodes.node(.empty(project.id))] }
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

    /// Inserts and removes changed rows with a fade, so new and reordered threads are easy to follow; the rows of
    /// `sliding` sections, which were just collapsed or expanded, also slide up or down, as a project's do. A thread
    /// that changes lists (pinned, unpinned or moved to another project) leaves its old list before it joins the new
    /// one, so the outline never holds it twice.
    private func apply(
        _ changed: [SidebarNode], from oldChildren: [ObjectIdentifier: [SidebarNode]], sliding: Set<SidebarNode> = []
    ) {
        guard !changed.isEmpty else { return }
        let expanded = changed.filter { outlineView.isItemExpanded($0) }
        var insertions: [(node: SidebarNode, rows: IndexSet)] = []
        outlineView.beginUpdates()
        for node in expanded {
            var removed = IndexSet()
            var inserted = IndexSet()
            for change in node.children.difference(from: oldChildren[ObjectIdentifier(node)] ?? []) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            if !removed.isEmpty {
                outlineView.removeItems(
                    at: removed, inParent: node, withAnimation: sliding.contains(node) ? [.effectFade, .slideUp] : .effectFade)
            }
            insertions.append((node, inserted))
        }
        outlineView.endUpdates()
        for node in changed where !outlineView.isItemExpanded(node) { outlineView.reloadItem(node, reloadChildren: true) }
        outlineView.beginUpdates()
        for (node, rows) in insertions where !rows.isEmpty {
            outlineView.insertItems(
                at: rows, inParent: node, withAnimation: sliding.contains(node) ? [.effectFade, .slideDown] : .effectFade)
        }
        outlineView.endUpdates()
        // Rows that kept their place may still show stale "Show more" counts.
        for node in expanded {
            for child in node.children where child.threadID == nil {
                let row = outlineView.row(forItem: child)
                if row >= 0 { outlineView.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
            }
        }
    }

    /// When the open thread is deleted, archived or snoozed away, opens its neighbour in the same project.
    private func handOffSelectionIfNeeded(oldChildren: [ObjectIdentifier: [SidebarNode]]) {
        guard let selected = selectedThreadID else { return }
        if let thread = store.summary(selected), !thread.isArchived || showsArchived,
            showsSnoozed || isSearching || !ThreadSnooze.isHidden(thread),
            showsSettled || isSearching || !ThreadInbox.isHidden(thread)
        { return }
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
        DispatchQueue.main.async { [weak self] in
            // A bulk action can remove several successive neighbours before this callback runs.
            guard self?.selectedThreadID == fallback else { return }
            callback?(fallback)
        }
    }

    private func isListed(_ node: SidebarNode) -> Bool {
        threadContainers.contains { $0.children.contains(node) }
    }

    private func syncExpansion() {
        isSyncingExpansion = true
        defer { isSyncingExpansion = false }
        for section in sections where !outlineView.isItemExpanded(section) { outlineView.expandItem(section) }
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
        // A bot's conversation highlights the bot's row.
        guard let id = selectedThreadID,
            let node = nodes.existing(.thread(id)) ?? store.summary(id)?.botID.flatMap({ nodes.existing(.bot($0)) })
        else {
            outlineView.deselectAll(nil)
            return
        }
        let rows = IndexSet(selectedInboxIDs.compactMap { id in
            nodes.existing(.thread(id)).map { outlineView.row(forItem: $0) }
        }.filter { $0 >= 0 })
        let row = outlineView.row(forItem: node)
        let desired = rows.isEmpty ? (row < 0 ? IndexSet() : IndexSet(integer: row)) : rows
        if outlineView.selectedRowIndexes != desired {
            outlineView.selectRowIndexes(desired, byExtendingSelection: false)
        }
        selectedInboxIDs = Set(desired.compactMap { sidebarNode(atRow: $0)?.threadID })
    }

    private func updateEmptyState() {
        if store.projects.isEmpty {
            emptyView.showNoProjects()
            emptyView.isHidden = false
            scrollView.isHidden = true
        } else if isSearching && sections.isEmpty {
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
        let registry = ProviderRegistry.shared
        let agent = registry.accountName(for: thread.selection).map { "\(thread.selection.provider.displayName) (\($0))" }
            ?? thread.selection.provider.displayName
        lines.append("\(agent) · \(registry.displayName(for: thread.selection))")
        let others = thread.sessionProviders.filter { $0 != thread.selection.provider }
        if !others.isEmpty {
            lines.append(String(localized: "Handed off from \(others.map(\.displayName).formatted(.list(type: .and)))"))
        }
        if let label = status.label { lines.append(label) }
        if let until = thread.snoozedUntil, until > Date() {
            lines.append(String(localized: "Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))"))
        }
        if ThreadInbox.shared.isSettled(thread) { lines.append(String(localized: "Settled")) }
        if isSearching, let match = messageMatches[thread.id] { lines.append("“\(match)”") }
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
            title: thread.title, place: thread.isPinned ? project?.name : nil, provider: thread.selection.provider,
            isPinned: thread.isPinned,
            isArchived: thread.isArchived, status: status, updatedAt: thread.updatedAt,
            canArchive: ThreadActions.canArchive(thread.id), canFork: ThreadForking.canFork(thread.id),
            hasBackgroundWork: !background.isEmpty, toolTip: lines.joined(separator: "\n"),
            accessibilityLabel: [thread.title, status.label, project?.name].compactMap(\.self).joined(separator: ", "),
            jumpHint: jumpHint, schedule: scheduleNote([thread.id]))
    }

    /// The most urgent status among threads, for collapsed projects and "Show more" rows.
    private func strongestStatus(of threadIDs: [UUID]) -> ThreadRowModel.Status? {
        let strongest = threadIDs.map(status(of:)).max { $0.priority < $1.priority }
        return strongest == .idle ? nil : strongest
    }

    private func refreshThreadRow(_ id: UUID) {
        // A collapsed section's header shows what its threads are doing.
        if !appliedCollapsed.isEmpty { refreshSectionHeaders() }
        if let botID = store.summary(id)?.botID {
            refreshBotRow(botID)
            return
        }
        guard let node = nodes.existing(.thread(id)), let thread = store.summary(id) else { return }
        let row = outlineView.row(forItem: node)
        if row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThreadCell {
            cell.configure(rowModel(for: thread, project: store.project(thread.projectID)))
        }
        refreshProjectRows(only: thread.projectID)
    }

    private func refreshBotRow(_ botID: UUID) {
        guard let node = nodes.existing(.bot(botID)), let model = botRowModel(botID) else { return }
        let row = outlineView.row(forItem: node)
        if row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BotCell {
            cell.configure(model)
        }
    }

    /// A bot's row: its latest message, and the most pressing status among its conversations.
    private func botRowModel(_ botID: UUID) -> BotRowModel? {
        guard let bot = store.bot(botID) else { return nil }
        let conversations = store.conversations(of: botID)
        let latest = conversations.first
        let status = strongestStatus(of: conversations.map(\.id)) ?? .idle
        var lines = [bot.displayName]
        if let personality = bot.personality?.displayName { lines.append(String(localized: "Personality: \(personality)")) }
        if let latest { lines.append(latest.title) }
        lines.append("\(bot.selection.provider.displayName) · \(ProviderRegistry.shared.displayName(for: bot.selection))")
        lines.append((bot.workingDirectory.path as NSString).abbreviatingWithTildeInPath)
        if let label = status.label { lines.append(label) }
        if isSearching, let match = conversations.lazy.compactMap({ self.messageMatches[$0.id] }).first { lines.append("“\(match)”") }
        return BotRowModel(
            name: bot.displayName, avatar: bot.avatar, preview: latest?.preview ?? String(localized: "Say hello"),
            updatedAt: latest?.updatedAt, status: status, toolTip: lines.joined(separator: "\n"),
            accessibilityLabel: [bot.displayName, status.label, latest?.preview].compactMap(\.self).joined(separator: ", "),
            schedule: scheduleNote(conversations.map(\.id)))
    }

    /// Updates project rows (their collapsed status) and "Show more" rows (their hidden status).
    private func refreshProjectRows(only projectID: UUID? = nil) {
        for node in threadContainers {
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
        return strongestStatus(of: store.threads(in: id).filter { !$0.isPinned }.map(\.id))
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

    // MARK: Schedules

    /// Lights the Scheduled row while the panel shows.
    func setSchedulesOpen(_ open: Bool) {
        guard open != schedulesOpen else { return }
        schedulesOpen = open
        updateSchedulesRow()
    }

    private func updateSchedulesRow() {
        let active = ScheduledTasks.shared.schedules.tasks.filter(\.isActive).count
        topRows.setSchedules(
            shortcut: KeyBindingsController.shared.displayString(for: .showSchedules), active: active, isOpen: schedulesOpen)
    }

    /// Schedules changed: the rows' clocks and the Scheduled row's count follow.
    @objc private func schedulesChanged() {
        updateSchedulesRow()
        guard hasLoaded else { return }
        refreshVisibleThreadRows()
    }

    /// The tooltip of a row's clock: the active schedules of these threads; nil when they have none.
    private func scheduleNote(_ threadIDs: [UUID]) -> String? {
        let service = ScheduledTasks.shared
        let tasks = threadIDs.flatMap { service.tasks(inThread: $0) }
        guard tasks.contains(where: \.isActive) else { return nil }
        return SchedulePresentation.threadToolTip(tasks)
    }

    private func refreshVisibleThreadRows() {
        for node in botsSection.children { if let id = node.botID { refreshBotRow(id) } }
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let id = self.sidebarNode(atRow: row)?.threadID, let thread = self.store.summary(id),
                let cell = rowView.view(atColumn: 0) as? ThreadCell
            else { return }
            cell.configure(self.rowModel(for: thread, project: self.store.project(thread.projectID)))
        }
    }

    private func refreshVisibleTimes(runningOnly: Bool) {
        outlineView.enumerateAvailableRowViews { rowView, row in
            if let cell = rowView.view(atColumn: 0) as? BotCell {
                cell.refreshTime()
                return
            }
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
        updateSchedulesRow()
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
        searchMessages()
        rebuild()
    }

    /// Looks for the query in every thread's messages once typing pauses, then adds those threads to the results.
    private func searchMessages() {
        messageSearch?.cancel()
        let text = query
        guard text.trimmingCharacters(in: .whitespaces).count >= 2 else {
            messageMatches = [:]
            return
        }
        messageSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            let matches = await store.searchMessages(text)
            guard !Task.isCancelled, query == text else { return }
            messageMatches = matches
            rebuild()
        }
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
        case .bots, .pinned, .header, .chats:
            // A click on a section's header, outside its buttons, collapses or expands it.
            if let section = node.section { toggleSection(section) }
        case .bot, .thread:
            outlineView.recordMouseActivation()
        case .empty:
            break
        }
    }

    /// Mouse activation hands typing to the chat after AppKit finishes selecting the row. Selection-change callbacks
    /// alone also run for arrow keys and bulk actions, which must keep their focus in the outline.
    func focusComposerAfterClick(at row: Int, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.intersection([.command, .shift, .control]).isEmpty,
            outlineView.selectedRowIndexes.count == 1, outlineView.isRowSelected(row),
            let node = sidebarNode(atRow: row), let selectedThreadID
        else { return }
        let isOpenThread = node.threadID == selectedThreadID
        let isOpenBot = node.botID.map { store.summary(selectedThreadID)?.botID == $0 } ?? false
        guard isOpenThread || isOpenBot else { return }
        outlineView.onActivate?()
    }

    @objc private func rowDoubleClicked() {
        let row = outlineView.clickedRow
        guard let node = sidebarNode(atRow: row), node.isSelectable else { return }
        outlineView.recordMouseActivation()
    }

    @objc private func addProject() {
        ThreadActions.addProject(in: view.window)
    }

    @objc private func newChat() {
        ThreadActions.newChat()
    }

    @objc private func newBot() {
        BotActions.newBot(in: view.window)
    }

    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        let archived = NSMenuItem(
            title: String(localized: "Show Archived Threads"), action: #selector(toggleShowArchived), keyEquivalent: "")
        archived.target = self
        archived.state = showsArchived ? .on : .off
        menu.addItem(archived)
        let snoozed = NSMenuItem(
            title: String(localized: "Show Snoozed Threads"), action: #selector(toggleShowSnoozed), keyEquivalent: "")
        snoozed.target = self
        snoozed.state = showsSnoozed ? .on : .off
        menu.addItem(snoozed)
        let settled = item(String(localized: "Show Settled Threads"), #selector(toggleShowSettled))
        settled.state = showsSettled ? .on : .off
        menu.addItem(settled)
        menu.addItem(.separator())
        addSortMenus(to: menu)
        menu.addItem(threadLimitMenu())
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

    /// "Threads per Project": fit to the sidebar (the default), a fixed number, or all.
    private func threadLimitMenu() -> NSMenuItem {
        let limitItem = NSMenuItem(title: String(localized: "Threads per Project"), action: nil, keyEquivalent: "")
        let current = UIState.shared.values.sidebarThreadsPerProject
        let limits = NSMenu()
        let fit = item(String(localized: "Fit to Sidebar"), #selector(setThreadLimit(_:)))
        fit.tag = -1
        fit.state = current == nil ? .on : .off
        let fitted = SidebarOrdering.automaticThreadLimit(visibleHeight: scrollView.contentView.bounds.height)
        fit.subtitle = String(localized: "\(fitted) in this window")
        limits.addItem(fit)
        limits.addItem(.separator())
        // A number chosen in an earlier version stays offered.
        for limit in Set([10, 20, 50] + [current ?? 10].filter { $0 > 0 }).sorted() + [0] {
            let entry = item(limit == 0 ? String(localized: "All") : AppNumbers.current.integer(limit), #selector(setThreadLimit(_:)))
            entry.tag = limit
            entry.state = current == limit ? .on : .off
            limits.addItem(entry)
        }
        limitItem.submenu = limits
        return limitItem
    }

    @objc private func setThreadLimit(_ sender: NSMenuItem) {
        UIState.shared.update { $0.sidebarThreadsPerProject = sender.tag < 0 ? nil : sender.tag }
        expandedLists.removeAll()
        rebuild()
    }

    /// "Sort Projects By" and "Sort Threads By", for the Projects options and the sidebar's context menu.
    private func addSortMenus(to menu: NSMenu) {
        let values = UIState.shared.values
        let projects = NSMenu()
        for sort in ProjectSort.allCases {
            let entry = item(sort.title, #selector(setProjectSort(_:)))
            entry.representedObject = sort.rawValue
            entry.state = values.projectSort == sort ? .on : .off
            if sort == .manual { entry.subtitle = String(localized: "Drag projects to reorder them") }
            projects.addItem(entry)
        }
        let projectsItem = NSMenuItem(title: String(localized: "Sort Projects By"), action: nil, keyEquivalent: "")
        projectsItem.submenu = projects
        menu.addItem(projectsItem)
        let threadsItem = NSMenuItem(title: String(localized: "Sort Threads By"), action: nil, keyEquivalent: "")
        threadsItem.submenu = threadSortMenu(selected: values.threadSort, action: #selector(setThreadSort(_:)))
        menu.addItem(threadsItem)
    }

    private func threadSortMenu(selected: ThreadSort, action: Selector) -> NSMenu {
        let menu = NSMenu()
        for sort in ThreadSort.allCases {
            let entry = item(sort.title, action)
            entry.representedObject = sort.rawValue
            entry.state = selected == sort ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func setProjectSort(_ sender: NSMenuItem) {
        guard let sort = (sender.representedObject as? String).flatMap(ProjectSort.init(rawValue:)) else { return }
        UIState.shared.update { $0.projectSort = sort }
        rebuild()
    }

    @objc private func setThreadSort(_ sender: NSMenuItem) {
        guard let sort = (sender.representedObject as? String).flatMap(ThreadSort.init(rawValue:)) else { return }
        UIState.shared.update { $0.threadSort = sort }
        rebuild()
    }

    @objc private func setChatSort(_ sender: NSMenuItem) {
        guard let sort = (sender.representedObject as? String).flatMap(ThreadSort.init(rawValue:)) else { return }
        UIState.shared.update { $0.chatSort = sort }
        rebuild()
    }

    /// The Bots header's options: how bots are sorted.
    @objc private func showBotOptions(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: String(localized: "Sort Bots By")))
        for entry in botSortMenu().items {
            entry.menu?.removeItem(entry)
            menu.addItem(entry)
        }
        ThemedPopup.show(menu: menu, from: sender, preferAbove: false)
    }

    private func botSortMenu() -> NSMenu {
        let menu = NSMenu()
        for sort in BotSort.allCases {
            let entry = item(sort.title, #selector(setBotSort(_:)))
            entry.representedObject = sort.rawValue
            entry.state = UIState.shared.values.botSort == sort ? .on : .off
            if sort == .manual { entry.subtitle = String(localized: "Drag bots to reorder them") }
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func setBotSort(_ sender: NSMenuItem) {
        guard let sort = (sender.representedObject as? String).flatMap(BotSort.init(rawValue:)) else { return }
        UIState.shared.update {
            $0.botSort = sort
            $0.choseBotSort = true
        }
        rebuild()
    }

    /// The Chats header's options: how chats are sorted.
    @objc private func showChatOptions(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: String(localized: "Sort Chats By")))
        for entry in threadSortMenu(selected: UIState.shared.values.chatSort, action: #selector(setChatSort(_:))).items {
            entry.menu?.removeItem(entry)
            menu.addItem(entry)
        }
        ThemedPopup.show(menu: menu, from: sender, preferAbove: false)
    }

    @objc private func expandAll() {
        for project in store.projects where !project.isChats && !project.isExpanded {
            store.updateProject(project.id) { $0.isExpanded = true }
        }
    }

    @objc private func collapseAll() {
        for project in store.projects where !project.isChats && project.isExpanded {
            store.updateProject(project.id) { $0.isExpanded = false }
        }
    }

    private func deleteSelectedThread() {
        ThreadActions.delete(outlineView.selectedRowIndexes.compactMap { sidebarNode(atRow: $0)?.threadID }, in: view.window)
    }

    /// A thread row's archive button and VoiceOver actions.
    private func perform(_ command: ThreadCell.Command, onThread id: UUID) {
        switch command {
        case .togglePin: ThreadActions.togglePin(id)
        case .rename: beginRename(threadID: id)
        case .fork: ThreadForking.fork(id)
        case .toggleArchived: ThreadActions.toggleArchived(id, in: view.window)
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
        field.window?.invalidateCursorRects(for: field)
        field.delegate = self
        view.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            // The theme's selection and caret, not the system's blue.
            editor.selectedTextAttributes = [.backgroundColor: Theme.textSelection]
            editor.insertionPointColor = Theme.accent
            editor.selectAll(nil)
        }
        // A click outside the field finishes the rename, even on views that don't take focus (the transcript).
        renameClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self, weak field] event in
            guard let self, let field, event.window === field.window else { return event }
            let point = field.convert(event.locationInWindow, from: nil)
            if !field.bounds.contains(point) { field.window?.makeFirstResponder(nil) }
            return event
        }
    }

    private func endRename(_ field: NSTextField) {
        if let monitor = renameClickMonitor {
            NSEvent.removeMonitor(monitor)
            renameClickMonitor = nil
        }
        guard let editing else { return }
        self.editing = nil
        field.isEditable = false
        field.isSelectable = false
        field.window?.invalidateCursorRects(for: field)
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
        guard let node = item as? SidebarNode else { return sections.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNode else { return sections[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        switch node.kind {
        case .bots, .pinned, .header, .chats, .project: return true
        default: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isSection == true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        (item as? SidebarNode)?.isSection != true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        (item as? SidebarNode)?.isSection != true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.isSelectable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SidebarNode else { return SidebarMetrics.rowHeight }
        switch node.kind {
        // Reordering sections reloads the outline, so the first header's height follows it.
        case .bots, .pinned, .header, .chats:
            return node === sections.first ? SidebarMetrics.firstSectionHeaderHeight : SidebarMetrics.sectionHeaderHeight
        case .bot: return 44
        case .project, .thread: return SidebarMetrics.rowHeight
        case .showMore, .showLess, .empty: return 24
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? SidebarNode)?.threadID.flatMap { store.summary($0)?.title }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        // "No threads yet" is the only row a click does nothing on.
        var isEmptyNote = false
        if let node = item as? SidebarNode, case .empty = node.kind { isEmptyNote = true }
        return ThemedTableRowView(inset: 10, isClickable: !isEmptyNote)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        switch node.kind {
        case .bots:
            return headerCell(node, "botsHeader") {
                SidebarHeaderCell(
                    title: String(localized: "Bots"), target: self, add: (#selector(newBot), "plus", String(localized: "New Bot…")),
                    optionsAction: #selector(showBotOptions(_:)), optionsLabel: String(localized: "Bots Options"))
            }
        case .bot(let id):
            let cell = reuse("bot") { BotCell(frame: .zero) }
            if let model = botRowModel(id) { cell.configure(model) }
            return cell
        case .pinned:
            return headerCell(node, "pinnedHeader") { SidebarHeaderCell(title: String(localized: "Pinned"), target: self) }
        case .header:
            return headerCell(node, "header") {
                SidebarHeaderCell(
                    title: String(localized: "Projects"), target: self,
                    add: (#selector(addProject), "folder.badge.plus", String(localized: "Add Project…")),
                    optionsAction: #selector(showOptions(_:)))
            }
        case .chats:
            return headerCell(node, "chatsHeader") {
                SidebarHeaderCell(
                    title: String(localized: "Chats"), target: self,
                    add: (#selector(newChat), "square.and.pencil", String(localized: "New Chat")),
                    optionsAction: #selector(showChatOptions(_:)), optionsLabel: String(localized: "Chats Options"))
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
            let text: String
            if store.threads(in: id, includeArchived: showsArchived).contains(where: \.isPinned) {
                text = isChats ? String(localized: "Only pinned chats") : String(localized: "Only pinned threads")
            } else {
                text = isChats ? String(localized: "No chats yet") : String(localized: "No threads yet")
            }
            cell.configure(text: text, symbol: nil)
            return cell
        }
    }

    private func headerCell(_ node: SidebarNode, _ identifier: String, make: () -> SidebarHeaderCell) -> SidebarHeaderCell {
        let cell = reuse(identifier, make: make)
        configureHeader(cell, node)
        return cell
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
        selectedInboxIDs = Set(outlineView.selectedRowIndexes.compactMap { sidebarNode(atRow: $0)?.threadID })
        // Extending selection prepares a bulk action without navigating away from the open conversation.
        if selectedInboxIDs.count > 1 { return }
        if let botID = sidebarNode(atRow: outlineView.selectedRow)?.botID {
            // A bot's row opens its latest conversation, which then highlights the row.
            if selectedThreadID.flatMap({ store.summary($0)?.botID }) != botID { BotActions.open(botID) }
            return
        }
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
        // Projects leaving with a collapsed Projects section keep their own state.
        guard !isSyncingExpansion, !isSearching, header.children.contains(node), store.project(id)?.isExpanded != expanded
        else { return }
        store.updateProject(id) { $0.isExpanded = expanded }
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarNode, editing == nil else { return nil }
        if let section = node.section {
            guard !isSearching else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(section.rawValue, forType: .coincideSection)
            return pasteboardItem
        }
        if let id = node.threadID {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(id.uuidString, forType: .coincideThread)
            return pasteboardItem
        }
        if let id = node.botID {
            guard !isSearching else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(id.uuidString, forType: .coincideBot)
            return pasteboardItem
        }
        guard case .project(let id) = node.kind, !isSearching, let project = store.project(id), !project.isChats
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
        if pasteboard.availableType(from: [.coincideSection]) != nil, (info.draggingSource as AnyObject?) === outlineView {
            guard !isSearching else { return [] }
            outlineView.setDropItem(nil, dropChildIndex: sectionDropIndex(item: item as? SidebarNode, childIndex: index))
            return .move
        }
        if pasteboard.availableType(from: [.coincideBot]) != nil, (info.draggingSource as AnyObject?) === outlineView {
            // Sorted by name or activity, bots have no order of the user's to change.
            guard !isSearching, UIState.shared.values.botSort == .manual,
                let index = botDropIndex(item: item as? SidebarNode, childIndex: index)
            else { return [] }
            outlineView.setDropItem(botsSection, dropChildIndex: index)
            return .move
        }
        if pasteboard.availableType(from: [.coincideProject]) != nil, (info.draggingSource as AnyObject?) === outlineView {
            // Sorted by name or activity, projects have no order of the user's to change.
            guard !isSearching, UIState.shared.values.projectSort == .manual else { return [] }
            outlineView.setDropItem(header, dropChildIndex: projectDropIndex(item: item as? SidebarNode, childIndex: index))
            return .move
        }
        if (info.draggingSource as AnyObject?) === outlineView, let threads = draggedThreads(info), !threads.isEmpty {
            return validateThreadDrop(threads, item: item as? SidebarNode, childIndex: index)
        }
        guard !SidebarEmptyView.folders(on: pasteboard).isEmpty else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    /// Places pinned threads before `target` in the Pinned order (at the end without one). The saved order also holds
    /// pinned threads hidden for now, such as snoozed ones, which keep their places.
    private func reorderPinned(_ threads: [UUID], before target: UUID?) {
        let order = pinnedOrder()
        let index = target.flatMap { order.firstIndex(of: $0) } ?? order.count
        let reordered = SidebarOrdering.reordered(order, moving: threads, to: index)
        UIState.shared.update { $0.pinnedThreads = reordered.map(\.uuidString) }
        rebuild()
    }

    /// Turns any proposed drop point into a gap between sections: above a section's header, below its rows.
    private func sectionDropIndex(item: SidebarNode?, childIndex: Int) -> Int {
        guard let item else { return childIndex == NSOutlineViewDropOnItemIndex ? sections.count : childIndex }
        var owner: SidebarNode? = item
        while let node = owner, !sections.contains(node) { owner = outlineView.parent(forItem: node) as? SidebarNode }
        guard let owner, let position = sections.firstIndex(of: owner) else { return sections.count }
        return owner === item && childIndex == NSOutlineViewDropOnItemIndex ? position : position + 1
    }

    /// Turns a proposed drop point in Bots into a gap between bots: before the bot dropped on. Nil outside Bots.
    private func botDropIndex(item: SidebarNode?, childIndex: Int) -> Int? {
        if item === botsSection {
            return childIndex == NSOutlineViewDropOnItemIndex ? botsSection.children.count : childIndex
        }
        return item.flatMap { botsSection.children.firstIndex(of: $0) }
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

    private func draggedThreads(_ info: NSDraggingInfo) -> [UUID]? {
        let ids = info.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: .coincideThread).flatMap(UUID.init) }
        return ids?.isEmpty == false ? ids : nil
    }

    /// Pinned threads dragged within Pinned change its order. Threads dropped on a project, on Chats or among a
    /// project's threads move there, the project's row lighting up as the target.
    private func validateThreadDrop(_ threads: [UUID], item: SidebarNode?, childIndex: Int) -> NSDragOperation {
        guard let item else { return [] }
        if item === pinnedSection || pinnedSection.children.contains(item) {
            guard !isSearching, threads.allSatisfy({ store.summary($0)?.isPinned == true }) else { return [] }
            let index = item === pinnedSection
                ? (childIndex == NSOutlineViewDropOnItemIndex ? pinnedSection.children.count : childIndex)
                : pinnedSection.children.firstIndex(of: item) ?? pinnedSection.children.count
            outlineView.setDropItem(pinnedSection, dropChildIndex: index)
            return .move
        }
        let destination = item.projectID ?? item.threadID.flatMap { store.summary($0)?.projectID }
        guard let destination, let project = store.project(destination), ThreadActions.canMove(threads, to: destination),
            let target = nodes.existing(project.isChats ? .chats(destination) : .project(destination)),
            outlineView.row(forItem: target) >= 0
        else { return [] }
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if (info.draggingSource as AnyObject?) === outlineView,
            let section = info.draggingPasteboard.string(forType: .coincideSection).flatMap(SidebarSection.init(rawValue:))
        {
            let target = sections.indices.contains(index) ? sections[index].section : nil
            guard target != section else { return true }
            UIState.shared.update { values in
                values.sidebarSections = SidebarOrdering.savedSectionOrder(saved: values.sidebarSections, moving: section, before: target)
            }
            rebuild()
            return true
        }
        if (info.draggingSource as AnyObject?) === outlineView, let threads = draggedThreads(info) {
            guard let node = item as? SidebarNode else { return false }
            if node === pinnedSection {
                reorderPinned(threads, before: index < pinnedSection.children.count ? pinnedSection.children[index].threadID : nil)
            } else if let projectID = node.projectID {
                ThreadActions.move(threads, to: projectID)
            } else {
                return false
            }
            return true
        }
        let pasteboard = info.draggingPasteboard
        if let value = pasteboard.string(forType: .coincideBot), (info.draggingSource as AnyObject?) === outlineView {
            guard let id = UUID(uuidString: value), let source = store.bots.firstIndex(where: { $0.id == id }) else { return false }
            // Rows follow the store's order while bots are sorted by hand; the bot it was dropped before places it.
            let order = store.bots.map(\.id)
            let target = botsSection.children.indices.contains(index) ? botsSection.children[index].botID : nil
            let reordered = SidebarOrdering.reordered(order, moving: [id], to: target.flatMap(order.firstIndex(of:)) ?? order.count)
            if let destination = reordered.firstIndex(of: id), destination != source { store.moveBot(from: source, to: destination) }
            return true
        }
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
            if selectedInboxIDs.count > 1, selectedInboxIDs.contains(id) {
                buildBulkMenu(menu, Array(selectedInboxIDs))
            } else {
                buildThreadMenu(menu, id)
            }
        case .chats(let id), .project(let id), .showMore(let id), .showLess(let id), .empty(let id):
            buildProjectMenu(menu, id)
        case .bot(let id):
            buildBotMenu(menu, id)
        case .bots:
            menu.addItem(item(String(localized: "New Bot…"), #selector(newBot)))
            menu.addItem(.separator())
            let sort = NSMenuItem(title: String(localized: "Sort Bots By"), action: nil, keyEquivalent: "")
            sort.submenu = botSortMenu()
            menu.addItem(sort)
        case .pinned, .header, nil:
            menu.addItem(item(String(localized: "Add Project…"), #selector(addProject)))
            menu.addItem(.separator())
            addSortMenus(to: menu)
            menu.addItem(.separator())
            let archived = item(String(localized: "Show Archived Threads"), #selector(toggleShowArchived))
            archived.state = showsArchived ? .on : .off
            menu.addItem(archived)
            let snoozed = item(String(localized: "Show Snoozed Threads"), #selector(toggleShowSnoozed))
            snoozed.state = showsSnoozed ? .on : .off
            menu.addItem(snoozed)
            let settled = item(String(localized: "Show Settled Threads"), #selector(toggleShowSettled))
            settled.state = showsSettled ? .on : .off
            menu.addItem(settled)
            menu.addItem(item(String(localized: "Expand All Projects"), #selector(expandAll)))
            menu.addItem(item(String(localized: "Collapse All Projects"), #selector(collapseAll)))
        }
    }

    private func buildBotMenu(_ menu: NSMenu, _ id: UUID) {
        guard store.bot(id) != nil else { return }
        menu.addItem(item(String(localized: "New Conversation"), #selector(newConversationFromMenu(_:)), id))
        let past = NSMenuItem(title: String(localized: "Past Conversations"), action: nil, keyEquivalent: "")
        past.submenu = BotActions.pastConversationsMenu(for: id, target: self, action: #selector(openConversationFromMenu(_:)))
        menu.addItem(past)
        // In its latest conversation, which the bot's row opens.
        if let latest = store.conversations(of: id).first {
            menu.addItem(item(String(localized: "Schedule…"), #selector(scheduleFromMenu(_:)), latest.id))
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Edit Bot…"), #selector(editBotFromMenu(_:)), id))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Delete Bot…"), #selector(deleteBotFromMenu(_:)), id))
    }

    @objc private func newConversationFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        BotActions.newConversation(with: id)
    }

    @objc private func openConversationFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        AppEvents.openThread(id)
    }

    @objc private func editBotFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        BotActions.edit(id, in: view.window)
    }

    @objc private func deleteBotFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        BotActions.delete(id, in: view.window)
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
        menu.addItem(item(String(localized: "Schedule…"), #selector(scheduleFromMenu(_:)), id))
        addMoveMenu(to: menu, [id])
        menu.addItem(.separator())
        addOpenItems(to: menu)
        menu.addItem(item(String(localized: "Copy Thread ID"), #selector(copyThreadID(_:)), id))
        menu.addItem(.separator())
        if let until = thread.snoozedUntil, until > Date() {
            menu.addItem(item(String(localized: "Unsnooze"), #selector(unsnoozeFromMenu(_:)), id))
        } else {
            let snooze = NSMenuItem(title: String(localized: "Snooze"), action: nil, keyEquivalent: "")
            let presets = NSMenu(title: snooze.title)
            for preset in ThreadSnooze.presets() {
                let entry = item(preset.title, #selector(snoozeFromMenu(_:)))
                entry.representedObject = (id, preset.date) as (UUID, Date)
                entry.subtitle = preset.detail
                presets.addItem(entry)
            }
            snooze.submenu = presets
            menu.addItem(snooze)
        }
        let settled = ThreadInbox.shared.isSettled(thread)
        let settle = item(settled ? String(localized: "Unsettle") : String(localized: "Settle"), #selector(settleFromMenu(_:)))
        settle.representedObject = ([id], !settled)
        if !settled { settle.subtitle = String(localized: "Returns when new activity arrives") }
        settle.isEnabled = settled || (!ThreadRunner.shared.isRunning(id)
            && ThreadActivity.shared.pendingApprovalCount(id) == 0 && ThreadActivity.shared.pendingQuestionCount(id) == 0)
        menu.addItem(settle)
        let archive = item(
            thread.isArchived ? String(localized: "Unarchive") : String(localized: "Archive"), #selector(archiveFromMenu(_:)), id)
        archive.isEnabled = ThreadActions.canArchive(id)
        menu.addItem(archive)
        menu.addItem(item(String(localized: "Delete…"), #selector(deleteFromMenu(_:)), id))
    }

    private func buildBulkMenu(_ menu: NSMenu, _ ids: [UUID]) {
        let archive = item(String(localized: "Archive Threads"), #selector(archiveMany(_:)))
        archive.representedObject = (ids, true)
        archive.isEnabled = ids.allSatisfy { !ThreadRunner.shared.isRunning($0) }
        menu.addItem(archive)
        if ids.contains(where: { store.summary($0)?.isArchived == true }) {
            let unarchive = item(String(localized: "Unarchive Threads"), #selector(archiveMany(_:)))
            unarchive.representedObject = (ids, false)
            menu.addItem(unarchive)
        }
        for settled in [true, false] {
            let entry = item(settled ? String(localized: "Settle Threads") : String(localized: "Unsettle Threads"), #selector(settleFromMenu(_:)))
            entry.representedObject = (ids, settled)
            entry.isEnabled = !settled || ids.allSatisfy {
                !ThreadRunner.shared.isRunning($0) && ThreadActivity.shared.pendingApprovalCount($0) == 0
                    && ThreadActivity.shared.pendingQuestionCount($0) == 0
            }
            menu.addItem(entry)
        }
        addMoveMenu(to: menu, ids)
        let delete = item(String(localized: "Delete Threads"), #selector(deleteMany(_:)))
        delete.representedObject = ids
        menu.addItem(.separator())
        menu.addItem(delete)
    }

    /// "Move to Project": every other project in the sidebar's order, then Chats. Disabled, with the reason, while a
    /// thread can't move.
    private func addMoveMenu(to menu: NSMenu, _ ids: [UUID]) {
        let move = NSMenuItem(title: String(localized: "Move to Project"), action: nil, keyEquivalent: "")
        if let blocker = ids.lazy.compactMap(ThreadActions.moveBlocker).first {
            move.isEnabled = false
            move.subtitle = blocker
            menu.addItem(move)
            return
        }
        let current = Set(ids.compactMap { store.summary($0)?.projectID })
        let projects = SidebarOrdering.sortedProjects(
            store.projects, by: UIState.shared.values.projectSort,
            lastActivity: SidebarOrdering.lastActivity(of: store.threadSummaries.values))
        let destinations = NSMenu()
        for project in projects where !project.isChats && !(current.count == 1 && current.contains(project.id)) {
            let entry = item(project.name, #selector(moveFromMenu(_:)))
            entry.representedObject = (ids, project.id) as ([UUID], UUID?)
            entry.image = Theme.symbol("folder", size: 12)
            destinations.addItem(entry)
        }
        // Chats is offered before the first chat made it.
        if !(current.count == 1 && current.contains(store.chatsProject?.id ?? UUID())) {
            if !destinations.items.isEmpty { destinations.addItem(.separator()) }
            let chats = item(String(localized: "Chats"), #selector(moveFromMenu(_:)))
            chats.representedObject = (ids, store.chatsProject?.id) as ([UUID], UUID?)
            chats.image = Theme.symbol("bubble.left.and.bubble.right", size: 12)
            destinations.addItem(chats)
        }
        move.submenu = destinations
        move.isEnabled = !destinations.items.isEmpty
        menu.addItem(move)
    }

    @objc private func moveFromMenu(_ sender: NSMenuItem) {
        guard let (ids, projectID) = sender.representedObject as? ([UUID], UUID?) else { return }
        ThreadActions.move(ids, to: projectID ?? store.ensureChatsProject().id)
    }

    @objc private func archiveMany(_ sender: NSMenuItem) {
        guard let (ids, archived) = sender.representedObject as? ([UUID], Bool) else { return }
        if archived {
            ThreadActions.archive(ids, in: view.window)
        } else {
            ThreadInbox.shared.archive(ids, archived: false)
        }
    }

    @objc private func settleFromMenu(_ sender: NSMenuItem) {
        guard let (ids, settled) = sender.representedObject as? ([UUID], Bool) else { return }
        ThreadInbox.shared.settle(ids, settled: settled)
    }

    @objc private func deleteMany(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [UUID] else { return }
        ThreadActions.delete(ids, in: view.window)
    }

    @objc private func toggleShowSettled() {
        UIState.shared.update { $0.showsSettledThreads.toggle() }
        rebuild()
    }

    @objc private func inboxChanged() {
        rebuild()
    }

    /// The phone changed how the sidebar sorts or how many threads a project shows.
    @objc private func layoutChanged() {
        expandedLists.removeAll()
        rebuild()
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
        menu.addItem(item(String(localized: "Project Defaults…"), #selector(projectDefaultsFromMenu(_:)), id))
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

    @objc private func projectDefaultsFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let project = store.project(id), !project.isChats else { return }
        let editor = ProjectDefaultsEditor(project: project, store: store, registry: .shared)
        editor.onSave = { [weak store] defaults in
            store?.updateProject(id) { $0.threadDefaults = defaults }
        }
        presentAsSheet(editor)
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

    /// A new schedule that sends a message into the thread.
    @objc private func scheduleFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        ScheduleActions.newSchedule(inThread: id, in: view.window)
    }

    @objc private func copyThreadID(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        NSPasteboard.general.setText(id.uuidString)
    }

    @objc private func snoozeFromMenu(_ sender: NSMenuItem) {
        guard let (id, date) = sender.representedObject as? (UUID, Date) else { return }
        ThreadSnooze.shared.snooze(id, until: date)
    }

    @objc private func unsnoozeFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        ThreadSnooze.shared.unsnooze(id)
    }

    @objc private func toggleShowSnoozed() {
        UIState.shared.update { $0.showsSnoozedThreads.toggle() }
        rebuild()
    }

    @objc private func archiveFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        ThreadActions.toggleArchived(id, in: view.window)
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
    var onMouseActivation: ((SidebarNode, NSEvent.ModifierFlags, Bool) -> Void)?
    private var trackingMouseDown = false
    private var mouseActivated = false
    private var renameCandidate: (kind: SidebarNode.Kind, timestamp: TimeInterval)?

    /// NSTableView actions run inside its mouse-tracking loop. Handing focus over
    /// there lets AppKit take it back before the click finishes.
    func recordMouseActivation() {
        if trackingMouseDown { mouseActivated = true }
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        let node = row >= 0 ? item(atRow: row) as? SidebarNode : nil
        let plainClick = event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
        let wasSelected = row >= 0 && selectedRowIndexes.count == 1 && isRowSelected(row)
        let field = row >= 0 ? (view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField : nil
        let onTitle = field.map { !$0.isEditable && $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
        let previous = renameCandidate
        let rename = event.clickCount == 2 && plainClick && wasSelected && onTitle && node?.threadID != nil
            && previous?.kind == node?.kind && previous.map {
                event.timestamp >= $0.timestamp && event.timestamp - $0.timestamp <= NSEvent.doubleClickInterval
            } == true
        renameCandidate = nil
        trackingMouseDown = true
        mouseActivated = false
        super.mouseDown(with: event)
        trackingMouseDown = false
        guard mouseActivated, let node else { return }
        if event.clickCount == 1, plainClick, wasSelected, onTitle, node.threadID != nil {
            renameCandidate = (node.kind, event.timestamp)
        }
        onMouseActivation?(node, event.modifierFlags, rename)
    }

    var hasRows: Bool { numberOfRows > 0 }
    override var undoManager: UndoManager? { ThreadInbox.shared.undoManager }
    @objc func undo(_ sender: Any?) { ThreadInbox.shared.undo() }
    @objc func redo(_ sender: Any?) { ThreadInbox.shared.redo() }

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
