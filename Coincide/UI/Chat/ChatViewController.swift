import AppKit
import CoincideKit
import QuickLookUI

/// A thread's timeline above its composer.
///
/// The transcript follows T3 Code's chat view: user bubbles, Markdown replies with the provider and
/// model that wrote them, tool calls folded into a work log per turn, approvals, plans, errors and
/// each turn's changed files. It updates incrementally from store changes, follows new output while
/// the reader is at the bottom, and offers "Jump to Latest" otherwise. ⌘F opens T3's thread find bar
/// over it.
final class ChatViewController: NSViewController {
    var threadID: UUID? {
        didSet {
            guard threadID != oldValue else { return }
            if let oldValue, oldValue == displayedThreadID { scrollStates[oldValue] = list.scrollState() }
            transcriptHold = threadID.map(store.holdTranscript)
            loadThread()
        }
    }

    let textCache = TranscriptTextCache()

    private let store = AppStore.shared
    private let runner = ThreadRunner.shared
    private let registry = ProviderRegistry.shared
    private let list = TranscriptListController()
    private let composer = ComposerViewController()
    private let composerContainer = NSView()
    private let noThreadView = ChatNoThreadView()
    private let welcomeView = ChatWelcomeView()
    private lazy var jumpButton: NSButton = {
        let button = ThemedButton(title: String(localized: "Jump to Latest"), style: .secondary, target: self, action: #selector(jumpToLatest))
        button.isCapsule = true
        button.font = .systemFont(ofSize: 12, weight: .medium)
        // Floats over the conversation, so it casts a soft shadow.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        button.shadow = shadow
        button.image = Theme.symbol("arrow.down", size: 11, weight: .semibold)
        button.imagePosition = .imageLeading
        button.toolTip = String(localized: "Scroll to the newest messages")
        return button
    }()

    private var observation: ObservationToken?
    /// Keeps the open thread's transcript in memory.
    private var transcriptHold: TranscriptHold?
    private var displayedThreadID: UUID?
    private var itemsByID: [UUID: TranscriptItem] = [:]
    private var revisions: [UUID: Int] = [:]
    /// Items whose content or revision changed since the last rebuild: their `itemsByID` entries, and the
    /// rows of finished turns kept in `settledRows`, may be out of date.
    private var changedSinceRebuild = Set<UUID>()
    /// The rows of the thread's finished turns, reused while a turn streams.
    private var settledRows: TranscriptSettledRows?
    private var expanded: [UUID: Set<TranscriptRowID>] = [:]
    private var scrollStates: [UUID: TranscriptScrollState] = [:]
    private var changedFileSignatures: [UUID: Int] = [:]
    /// The displayed thread's fork dividers, placed after their turns (see `refreshForkMarkers`).
    private var forkMarkers = TranscriptForkMarkers()
    private var pendingItemIDs = Set<UUID>()
    private var needsFullReload = false
    private var updateScheduled = false
    private var lastUpdate = Date.distantPast
    /// How long the last transcript update took.
    private var updateCost: TimeInterval = 0
    private var liveTimer: Timer?
    /// The displayed thread's turn as last seen running, to look for its checkpoint once it ends.
    private var runningTurn: ThreadRunner.TurnState?
    private let findBar = TranscriptFindBar()
    private let finder = TranscriptFinder()
    /// The last query, kept while the find bar is closed, as the find pasteboard would.
    private var findQuery = ""
    private var pendingFind: DispatchWorkItem?
    private var findRefreshScheduled = false
    private var appliedFontSize = 0.0
    private var appliedReplyTypeface = ReplyTypeface.newYork
    private var appliedThemes = (dark: "", light: "")
    private var rails: [TranscriptRowID: TranscriptRail] = [:]
    private var composerAtBottom: NSLayoutConstraint!
    private var composerCentered: NSLayoutConstraint!
    private var appliedShowReasoning = true
    private var previewURLs: [URL] = []
    private var previewIndex = 0

    /// Streaming deltas arrive faster than anyone reads; apply them at most this often.
    private static let updateInterval: TimeInterval = 1.0 / 30
    private static let slowestUpdateInterval: TimeInterval = 0.25
    /// The find bar's height and its gap to the toolbar, kept free above the first row while it shows.
    private static let findBarReserve: CGFloat = 44

    // MARK: View

    override func loadView() {
        let root = SolidBackgroundView(color: Theme.contentBackground)
        view = root
        list.host = self
        list.onPinnedChange = { [weak self] pinned in self?.setJumpButtonVisible(!pinned) }
        let tableView = list.tableView
        tableView.onToggleRow = { [weak self] row, expand in self?.toggleRow(at: row, expand: expand) }
        tableView.onCopyRow = { [weak self] row in self?.copyRow(at: row) }
        tableView.onEscape = { [weak self] in self?.escapeFromTranscript() }
        tableView.onTypeAhead = { [weak self] event in self?.typeIntoComposer(event) }
        tableView.menu = rowMenu()
        findBar.onQueryChange = { [weak self] query in self?.findQueryChanged(query) }
        findBar.onNext = { [weak self] in self?.findNext() }
        findBar.onPrevious = { [weak self] in self?.findPrevious() }
        findBar.onClose = { [weak self] in self?.closeFindBar() }
        findBar.isHidden = true

        addChild(composer)
        welcomeView.onChooseAgent = { [weak self] kind in self?.switchAgent(to: kind) }
        for subview in [list.scrollView, welcomeView, welcomeView.setupView, composerContainer, jumpButton, findBar, noThreadView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        let findBarWidth = findBar.widthAnchor.constraint(equalToConstant: TranscriptFindBar.width)
        findBarWidth.priority = .defaultHigh
        let composerView = composer.view
        composerView.translatesAutoresizingMaskIntoConstraints = false
        composerContainer.addSubview(composerView)
        composerAtBottom = composerContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        // In an empty thread the composer waits a little below the middle, under the headline and agents.
        composerCentered = composerContainer.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: 48)
        let collapsedComposer = composerContainer.heightAnchor.constraint(equalToConstant: 0)
        collapsedComposer.priority = .defaultLow
        NSLayoutConstraint.activate([
            list.scrollView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            list.scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.scrollView.bottomAnchor.constraint(equalTo: composerContainer.topAnchor),

            welcomeView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            welcomeView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            welcomeView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            welcomeView.bottomAnchor.constraint(equalTo: composerContainer.topAnchor),

            composerContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            composerContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            composerAtBottom,
            collapsedComposer,

            welcomeView.setupView.topAnchor.constraint(equalTo: composerContainer.bottomAnchor, constant: 18),
            welcomeView.setupView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            welcomeView.setupView.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            welcomeView.setupView.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            welcomeView.setupView.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
            composerView.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            composerView.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor),
            composerView.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor),
            composerView.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor),

            jumpButton.centerXAnchor.constraint(equalTo: list.scrollView.centerXAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: composerContainer.topAnchor, constant: -12),

            findBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            findBar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 14),
            findBarWidth,

            noThreadView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            noThreadView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            noThreadView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            noThreadView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        jumpButton.isHidden = true
        jumpButton.alphaValue = 0
        appliedFontSize = store.settings.fontSize
        appliedReplyTypeface = store.settings.replyTypeface
        appliedThemes = (store.settings.darkTheme, store.settings.lightTheme)
        appliedShowReasoning = store.settings.showReasoning
        observation = store.observe { [weak self] change in self?.handle(change) }
        loadThread()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if displayedThreadID != nil { list.scrollToBottom() }
    }

    /// Puts the caret in the composer, or does so once the view is in a window.
    func focusComposer() {
        guard displayedThreadID != nil else { return }
        composer.focus()
    }

    func canShowComposerPicker(_ picker: ComposerViewController.Picker) -> Bool {
        composer.canShowPicker(picker)
    }

    func showComposerPicker(_ picker: ComposerViewController.Picker) {
        composer.showPicker(picker)
    }

    // MARK: Composer settings

    /// The composer's model choice, from the command palette: switches agent when the model is another's.
    func chooseModel(_ selection: ModelSelection) {
        composer.select(selection)
    }

    /// Continues the thread with another agent, as `/codex` and the like do.
    func switchAgent(to provider: ProviderKind) {
        composer.switchAgent(to: provider)
    }

    func chooseEffort(_ effort: String) {
        composer.setEffort(effort)
    }

    func chooseAccessMode(_ mode: AccessMode) {
        composer.setAccessMode(mode)
    }

    func chooseInteractionMode(_ mode: InteractionMode) {
        composer.setInteractionMode(mode)
    }

    // MARK: Thread

    private func loadThread() {
        guard isViewLoaded else { return }
        // Find belongs to the thread it was opened in, as in T3.
        hideFindBar(relayout: false)
        composer.threadID = threadID
        pendingItemIDs.removeAll()
        needsFullReload = false
        // Revisions restart, so heights cached for them could describe content that changed while the
        // thread was hidden.
        revisions.removeAll()
        list.forgetHeights()
        changedSinceRebuild.removeAll()
        settledRows = nil
        changedFileSignatures.removeAll()
        guard let threadID, store.thread(threadID) != nil else {
            displayedThreadID = nil
            runningTurn = nil
            itemsByID.removeAll()
            textCache.removeAll()
            forkMarkers = TranscriptForkMarkers()
            list.update([], reload: true)
            updateChrome()
            updateLiveTimer()
            return
        }
        displayedThreadID = threadID
        runningTurn = runner.turn(threadID)
        refreshChangedFiles()
        refreshForkMarkers()
        rebuild(reload: true)
        textCache.retain(only: Set(itemsByID.keys))
        list.restore(scrollStates[threadID])
        updateChrome()
        updateLiveTimer()
    }

    /// Lays out the rows again. Streaming updates touch a few items of the last turn, so only those items
    /// are looked up again and only the last turn's rows are rebuilt, however long the thread is.
    private func rebuild(reload: Bool = false, keeping anchor: TranscriptRowID? = nil) {
        guard let threadID, let thread = store.thread(threadID) else { return }
        if reload || needsFullReload {
            itemsByID = Dictionary(thread.items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            settledRows = nil
        } else {
            // Items change in place or are appended (anything else reloads), and the changing ones are the
            // newest, so look for them from the end.
            for id in changedSinceRebuild { itemsByID[id] = thread.items.last { $0.id == id } }
        }
        let rows = builder(for: thread).build(reusing: &settledRows, changed: changedSinceRebuild)
        changedSinceRebuild.removeAll()
        let items = itemsByID
        rails = TranscriptRail.rails(
            for: rows, provider: { items[$0]?.provider }, runningProvider: runner.turn(thread.id)?.provider ?? thread.selection.provider)
        list.update(rows, reload: reload, keeping: anchor)
        list.refreshRails()
    }

    /// Marks an item's rows as changed, for cached heights and the rows kept for finished turns.
    private func bumpRevision(_ id: UUID) {
        revisions[id, default: 0] += 1
        changedSinceRebuild.insert(id)
    }

    /// Lays out the thread's rows: what runs now, which rows are open, and the turns agents started themselves.
    private func builder(for thread: ChatThread) -> TranscriptBuilder {
        let turn = runner.turn(thread.id)
        var builder = TranscriptBuilder(items: thread.items)
        builder.runningTurnID = turn?.userItemID
        builder.turnStartedAt = turn?.startedAt
        builder.isStarting = runner.isStarting(thread.id)
        builder.runningProvider = turn?.provider ?? thread.selection.provider
        let background = runner.backgroundTasks(thread.id)
        if let first = background.first {
            builder.backgroundWork = (first.provider, background.map(\.task.title))
        }
        builder.showReasoning = store.settings.showReasoning
        builder.expanded = expanded[thread.id] ?? []
        builder.agentTurnIDs = AgentTurns.shared.anchors(in: thread.id)
        builder.topReserve = findBar.isHidden ? 0 : Self.findBarReserve
        builder.revisions = revisions
        builder.changedFiles = changedFileSignatures
        builder.forkMarkers = forkMarkers
        return builder
    }

    /// Places T3's fork dividers: in a fork, "Forked from conversation" after the copied history; in a thread
    /// that was forked, "Conversation fork" after each turn a fork copied through (unless that turn was
    /// rewound away since). Returns whether they changed.
    @discardableResult
    private func refreshForkMarkers() -> Bool {
        var placed = TranscriptForkMarkers()
        if let threadID = displayedThreadID, let thread = store.thread(threadID) {
            var markers: [(anchor: UUID?, marker: TranscriptForkMarker)] = []
            if let lineage = store.lineage(of: threadID) {
                let parent = store.summary(lineage.parentThreadID)
                let marker = TranscriptForkMarker(
                    direction: .forkedFrom, threadID: lineage.parentThreadID, title: parent?.title ?? lineage.parentTitle,
                    isAvailable: parent != nil)
                markers.append((lineage.forkPoint(in: thread.items), marker))
            }
            for (fork, lineage) in store.forks(of: threadID) {
                guard let anchor = lineage.parentItemID, thread.items.contains(where: { $0.id == anchor }) else { continue }
                markers.append((anchor, TranscriptForkMarker(direction: .forkedTo, threadID: fork.id, title: fork.title, isAvailable: true)))
            }
            if !markers.isEmpty { placed = builder(for: thread).placeForkMarkers(markers) }
        }
        guard placed != forkMarkers else { return false }
        forkMarkers = placed
        return true
    }

    private func updateChrome() {
        guard let threadID, let thread = store.thread(threadID) else {
            noThreadView.update(hasProjects: !store.projects.isEmpty)
            noThreadView.isHidden = false
            welcomeView.isHidden = true
            list.scrollView.isHidden = true
            composerContainer.isHidden = true
            setJumpButtonVisible(false)
            return
        }
        noThreadView.isHidden = true
        composerContainer.isHidden = false
        list.scrollView.isHidden = false
        let isEmpty = thread.items.isEmpty && !runner.isRunning(threadID)
        welcomeView.isHidden = !isEmpty
        welcomeView.setupView.isHidden = !isEmpty
        placeComposer(centered: isEmpty)
        if isEmpty { welcomeView.update(thread: thread, project: store.project(thread.projectID), registry: registry) }
    }

    /// Moves the composer between the middle of an empty thread and the bottom of a conversation. Sending the first
    /// message slides it down, unless the user asked for less motion.
    private func placeComposer(centered: Bool) {
        guard composerCentered.isActive != centered else { return }
        let animates = view.window != nil && !centered && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        composerAtBottom.isActive = !centered
        composerCentered.isActive = centered
        guard animates else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: Store changes

    private func handle(_ change: StoreChange) {
        switch change {
        case .items(let id, let changed, let appended):
            guard id == displayedThreadID else { return }
            if changed.isEmpty && !appended {
                needsFullReload = true
            } else {
                pendingItemIDs.formUnion(changed)
                changedSinceRebuild.formUnion(changed)
            }
            scheduleUpdate()
        case .runState(let id):
            guard id == displayedThreadID else { return }
            runStateChanged()
        case .thread(let id):
            guard id == displayedThreadID else { return }
            updateChrome()
        case .threadList, .projects:
            if let threadID, !store.hasThread(threadID) {
                scrollStates[threadID] = nil
                expanded[threadID] = nil
                self.threadID = nil
                return
            }
            if displayedThreadID == nil || !welcomeView.isHidden { updateChrome() }
            // A fork was made, renamed or deleted, or the thread this one was forked from.
            if refreshForkMarkers() { rebuild() }
        case .settings:
            settingsChanged()
        case .providers:
            if !welcomeView.isHidden { updateChrome() }
        }
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        // When an update is expensive, space them out so they never take more than about half the time.
        let interval = min(Self.slowestUpdateInterval, max(Self.updateInterval, updateCost * 2))
        let delay = max(0, interval - Date().timeIntervalSince(lastUpdate))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.applyPendingUpdate()
        }
    }

    private func applyPendingUpdate() {
        updateScheduled = false
        lastUpdate = Date()
        let start = CFAbsoluteTimeGetCurrent()
        defer { updateCost = CFAbsoluteTimeGetCurrent() - start }
        guard let threadID = displayedThreadID, let thread = store.thread(threadID) else { return }
        let reload = needsFullReload
        if reload {
            for item in thread.items { revisions[item.id, default: 0] += 1 }
            changedFileSignatures = changedFileSignatures.filter { id, _ in thread.items.contains { $0.id == id } }
        }
        for id in pendingItemIDs { bumpRevision(id) }
        pendingItemIDs.removeAll()
        needsFullReload = false
        // A rewind can cut the turn a fork divider followed.
        if reload { refreshForkMarkers() }
        rebuild(reload: reload)
        if reload { list.scrollToBottom() }
        updateChrome()
        scheduleFindRefresh()
    }

    private func runStateChanged() {
        guard let threadID = displayedThreadID else { return }
        let turn = runner.turn(threadID)
        // A turn of the user's ended: its after-turn checkpoint is on its way. Agents' own turns have none.
        if let finished = runningTurn, finished.userItemID != turn?.userItemID, !finished.isAgentInitiated {
            watchCheckpoints(for: finished.userItemID)
        }
        runningTurn = turn
        // A turn an agent started itself ends the previous turn, which a fork divider may follow.
        refreshForkMarkers()
        rebuild()
        list.reconfigureVisibleCells()
        updateChrome()
        updateLiveTimer()
    }

    private func settingsChanged() {
        let settings = store.settings
        guard
            settings.fontSize != appliedFontSize || settings.showReasoning != appliedShowReasoning
                || settings.replyTypeface != appliedReplyTypeface || settings.darkTheme != appliedThemes.dark
                || settings.lightTheme != appliedThemes.light
        else { return }
        appliedThemes = (settings.darkTheme, settings.lightTheme)
        appliedFontSize = settings.fontSize
        appliedReplyTypeface = settings.replyTypeface
        appliedShowReasoning = settings.showReasoning
        textCache.removeAll()
        list.invalidateHeights()
        rebuild(reload: true)
        scheduleFindRefresh()
    }

    private func updateLiveTimer() {
        let running = displayedThreadID.map(runner.isRunning) ?? false
        guard running else {
            liveTimer?.invalidate()
            liveTimer = nil
            return
        }
        guard liveTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.list.refreshLiveState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    // MARK: Checkpoints

    /// Records which finished turns changed files. Returns whether anything changed.
    @discardableResult
    private func refreshChangedFiles(turns: [UUID]? = nil) -> Bool {
        guard let threadID = displayedThreadID ?? threadID, let thread = store.thread(threadID) else { return false }
        let runningTurn = runner.isRunning(threadID) ? runner.turn(threadID)?.userItemID : nil
        let ids = turns ?? thread.items.filter { $0.kind == .user }.map(\.id)
        var didChange = false
        for id in ids where id != runningTurn {
            let files = CheckpointService.shared.changedFiles(threadID: threadID, userItemID: id)
            let signature = files.isEmpty ? nil : files.hashValue
            if changedFileSignatures[id] != signature {
                changedFileSignatures[id] = signature
                didChange = true
            }
        }
        return didChange
    }

    /// The after-turn checkpoint is captured asynchronously, so look for its changes a few times.
    private func watchCheckpoints(for turnID: UUID) {
        let threadID = displayedThreadID
        Task { [weak self] in
            for delay in [0.3, 1.0, 2.5, 6.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.displayedThreadID == threadID else { return }
                if self.refreshChangedFiles(turns: [turnID]) { self.rebuild() }
                self.list.reconfigureVisibleCells()
            }
        }
    }

    // MARK: Jump to latest

    private func setJumpButtonVisible(_ visible: Bool) {
        let show = visible && displayedThreadID != nil && !list.rows.isEmpty
        guard show != !jumpButton.isHidden || jumpButton.alphaValue != (show ? 1 : 0) else { return }
        if show { jumpButton.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            jumpButton.animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !show, self.jumpButton.alphaValue == 0 else { return }
                self.jumpButton.isHidden = true
            }
        }
    }

    @objc private func jumpToLatest() {
        list.scrollToBottom(animated: true)
    }

    // MARK: Find

    /// Opens the find bar with the last query selected, or puts the caret back in it when it is open.
    /// Like T3's thread find, opening it searches from the first row on screen.
    func showFindBar() {
        guard displayedThreadID != nil else { return }
        if findBar.isHidden {
            findBar.setQuery(findQuery)
            revealFindBar()
            runFind(navigating: true)
        }
        findBar.focus()
    }

    /// Opens the find bar searching for `query`, from the first row on screen.
    func find(_ query: String) {
        guard displayedThreadID != nil else { return }
        pendingFind?.cancel()
        pendingFind = nil
        findQuery = query
        findBar.setQuery(query)
        revealFindBar()
        runFind(navigating: true)
    }

    func closeFindBar() {
        guard !findBar.isHidden else { return }
        let hadFocus = findBar.hasFocus
        hideFindBar()
        if hadFocus { composer.focus() }
    }

    /// Shows the bar and keeps room for it above the first row.
    private func revealFindBar() {
        guard findBar.isHidden else { return }
        findBar.isHidden = false
        rebuild()
    }

    /// Closes the find bar without moving focus. Opening another thread lays out its rows anew, so it
    /// passes `relayout: false`.
    private func hideFindBar(relayout: Bool = true) {
        pendingFind?.cancel()
        pendingFind = nil
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        finder.reset()
        guard relayout else { return }
        rebuild()
        list.reconfigurePreparedCells()
    }

    func findNext() {
        stepFind(by: 1)
    }

    func findPrevious() {
        stepFind(by: -1)
    }

    private func stepFind(by delta: Int) {
        guard displayedThreadID != nil else { return }
        if findBar.isHidden {
            // Find Next with the bar closed searches again for the last query, as in other apps.
            guard !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return showFindBar() }
            findBar.setQuery(findQuery)
            revealFindBar()
            runFind(navigating: true)
            return
        }
        if let pending = pendingFind {
            // Return right after typing: search now, which lands on the first match from here.
            pending.cancel()
            pendingFind = nil
            runFind(navigating: true)
            return
        }
        guard !finder.matches.isEmpty else { return NSSound.beep() }
        finder.step(delta)
        findResultsChanged()
        revealCurrentMatch()
    }

    /// "Use Selection for Find": searches for the text selected in the conversation or the composer.
    private func useSelectionForFind() {
        guard let selection = selectedTextForFind else { return }
        find(selection)
    }

    private var selectedTextForFind: String? {
        guard let textView = view.window?.firstResponder as? NSTextView, !textView.isFieldEditor else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (textView.string as NSString).length else { return nil }
        let text = (textView.string as NSString).substring(with: range)
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(TranscriptFinder.maxQueryLength))
    }

    private func findQueryChanged(_ query: String) {
        findQuery = query
        pendingFind?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFind = nil
            self.runFind(navigating: true)
        }
        pendingFind = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Searches the thread for the find bar's query. A new search starts from the first row on screen and
    /// scrolls to its first match; refreshing while output streams in keeps the current match and the view.
    private func runFind(navigating: Bool) {
        guard !findBar.isHidden, let threadID = displayedThreadID, let thread = store.thread(threadID) else { return }
        finder.search(
            findBar.query, in: thread.items, revisions: revisions, showReasoning: store.settings.showReasoning,
            textCache: textCache, keepingCurrent: !navigating, from: navigating ? list.firstVisibleItemID() : nil)
        findResultsChanged(announcing: navigating)
        if navigating { revealCurrentMatch() }
    }

    private func findResultsChanged(announcing: Bool = true) {
        findBar.showCount(current: finder.currentIndex, total: finder.matches.count, isTruncated: finder.isTruncated)
        list.reconfigurePreparedCells()
        guard announcing, !finder.query.isEmpty else { return }
        NSAccessibility.post(
            element: findBar, notification: .announcementRequested,
            userInfo: [.announcement: findBar.countDescription, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// Output that streams in while the find bar is open is searched too, at most a few times a second.
    private func scheduleFindRefresh() {
        guard !findBar.isHidden, !findRefreshScheduled else { return }
        findRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.findRefreshScheduled = false
            guard self.pendingFind == nil else { return }
            self.runFind(navigating: false)
        }
    }

    /// Brings the current match into view: opens the turn, group of tool calls and row folding it away,
    /// scrolls to it (inside a tool call's output too) and points it out.
    /// The open rows with whatever folds `itemID` away opened too: its turn's work and its group of tool calls.
    private func rowsOpened(toShow itemID: UUID, in thread: ChatThread) -> Set<TranscriptRowID> {
        let rowID = TranscriptRowID.item(itemID)
        var open = expanded[thread.id] ?? []
        var layout = builder(for: thread)
        var rows = layout.build()
        if !rows.contains(where: { $0.id == rowID }), let header = layout.foldingHeader(of: itemID) {
            open.insert(header)
            layout.expanded = open
            rows = layout.build()
        }
        let group = rows.first { row in
            if case .group(let ids, _) = row.kind { return ids.contains(itemID) }
            return false
        }
        if !rows.contains(where: { $0.id == rowID }), let group { open.insert(group.id) }
        return open
    }

    private func revealCurrentMatch() {
        guard let threadID = displayedThreadID, let thread = store.thread(threadID), let match = finder.current,
            let item = itemsByID[match.itemID]
        else { return }
        let rowID = TranscriptRowID.item(match.itemID)
        var open = rowsOpened(toShow: match.itemID, in: thread)
        if !open.contains(rowID), rowHidesMatch(match, of: item) {
            open.insert(rowID)
            bumpRevision(match.itemID)
        }
        if open != (expanded[threadID] ?? []) {
            expanded[threadID] = open
            rebuild()
        }

        guard let index = list.index(of: rowID) else { return }
        list.reveal(row: index)
        guard let cell = list.cell(at: index) else { return }
        cell.layoutSubtreeIfNeeded()
        guard let target = cell.findTarget(for: match) else { return }
        list.reveal(row: index, rect: target.rect)
        if let textView = target.textView {
            // Once the scroll has drawn, so the indicator lands on the match.
            DispatchQueue.main.async { textView.showFindIndicator(for: target.range) }
        }
    }

    /// Whether the match's own row folds it away: a thought or a tool call's output shows once the row is
    /// open, and a long message shows its start until "Show full message".
    private func rowHidesMatch(_ match: TranscriptFindMatch, of item: TranscriptItem) -> Bool {
        switch item.kind {
        case .reasoning:
            return true
        case .tool:
            return match.field == .detail
        case .user:
            guard TranscriptUserCell.shouldCollapse(item.text), let row = list.rows.first(where: { $0.id == .item(item.id) })
            else { return false }
            return TranscriptUserCell.hides(match.range, of: item, row: row, width: list.tableView.bounds.width, host: self)
        default:
            return false
        }
    }

    /// Escape in the conversation closes the find bar first, then returns to the composer.
    private func escapeFromTranscript() {
        if findBar.isHidden {
            composer.focus()
        } else {
            hideFindBar()
        }
    }

    /// Find…, Find Next, Find Previous and Use Selection for Find from the Edit menu, while focus is in
    /// the chat; the main window passes them on from the sidebar and the diff. The terminal keeps its own.
    override func performTextFinderAction(_ sender: Any?) {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag, let action = NSTextFinder.Action(rawValue: tag)
        else { return }
        switch action {
        case .showFindInterface: showFindBar()
        case .nextMatch: findNext()
        case .previousMatch: findPrevious()
        case .setSearchString: useSelectionForFind()
        case .hideFindInterface: closeFindBar()
        default: break
        }
    }

    // MARK: Keyboard

    private func toggleRow(at index: Int, expand: Bool?) {
        guard index < list.rows.count else { return }
        let row = list.rows[index]
        let canToggle: Bool =
            switch row.kind {
            case .user:
                row.itemID.flatMap { itemsByID[$0] }.map { TranscriptUserCell.shouldCollapse($0.text) } ?? false
            case .tool:
                row.itemID.flatMap { itemsByID[$0] }.map(TranscriptToolDetail.hasDetail) ?? false
            default:
                row.isExpandable
            }
        guard canToggle else { return }
        if let expand, expand == isExpanded(row.id) { return }
        toggle(row.id)
    }

    private func copyRow(at index: Int) {
        guard let cell = list.tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? TranscriptCell,
            let text = cell.copyText, !text.isEmpty
        else { return }
        copyToPasteboard(text)
    }

    /// Typing while the transcript has focus goes to the composer.
    private func typeIntoComposer(_ event: NSEvent) {
        composer.focus()
        guard let responder = view.window?.firstResponder, responder !== list.tableView else { return }
        responder.keyDown(with: event)
    }

    // MARK: Context menu

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // Items are enabled as they are built (editing waits for the turn to end).
        menu.autoenablesItems = false
        return menu
    }

    @objc private func copyClickedRow(_ sender: NSMenuItem) {
        copyRow(at: sender.tag)
    }

    @objc private func rewindClickedRow(_ sender: NSMenuItem) {
        guard let id = list.rows[safe: sender.tag]?.itemID else { return }
        rewindTurn(id)
    }

    @objc private func forkClickedRow(_ sender: NSMenuItem) {
        guard let row = list.rows[safe: sender.tag], let id = Self.turnItemID(of: row) else { return }
        forkTurn(id)
    }

    @objc private func openClickedFork(_ sender: NSMenuItem) {
        guard case .fork(let marker)? = list.rows[safe: sender.tag]?.kind else { return }
        openThread(marker.threadID)
    }

    @objc private func toggleClickedRow(_ sender: NSMenuItem) {
        toggleRow(at: sender.tag, expand: nil)
    }

    /// An item of the turn a row shows, for forking through that turn.
    private static func turnItemID(of row: TranscriptRow) -> UUID? {
        switch row.id {
        case .item(let id), .turnHeader(let id), .group(let id), .changedFiles(let id): id
        case .fork, .live, .header, .footer: nil
        }
    }

    // MARK: Rewind

    private func present(_ alert: ThemedAlert, then handle: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = view.window else {
            handle(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: handle)
    }

    /// Removes the conversation from `item` on and hands its text back to the composer.
    private func rewind(to item: TranscriptItem) {
        guard let threadID = displayedThreadID else { return }
        store.truncate(threadID, from: item.id)
        composer.setDraft(item.text, imagePaths: item.attachments ?? [], context: item.context ?? [])
    }

    /// Puts files back the way they were before the turn, then rewinds to it.
    private func restoreFilesAndRewind(to item: TranscriptItem, in threadID: UUID) {
        Task { @MainActor [weak self] in
            do {
                try await CheckpointService.shared.restore(threadID: threadID, toBefore: item.id)
                guard let self, self.displayedThreadID == threadID else { return }
                self.rewind(to: item)
            } catch {
                self?.present(error)
            }
        }
    }

    private func present(_ error: Error) {
        let alert = ThemedAlert(error: error)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - TranscriptHost

extension ChatViewController: TranscriptHost {
    var isThreadRunning: Bool { displayedThreadID.map(runner.isRunning) ?? false }

    func item(_ id: UUID) -> TranscriptItem? {
        itemsByID[id]
    }

    func isExpanded(_ id: TranscriptRowID) -> Bool {
        guard let threadID = displayedThreadID else { return false }
        return expanded[threadID]?.contains(id) ?? false
    }

    func toggle(_ id: TranscriptRowID) {
        guard let threadID = displayedThreadID else { return }
        var set = expanded[threadID] ?? []
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        expanded[threadID] = set
        if case .item(let itemID) = id { bumpRevision(itemID) }
        rebuild(keeping: id)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.setText(text)
    }

    /// T3's "Edit from here?": every message of the user's can be rewound to, keeping files as they are; when
    /// the turn's checkpoint can be restored, "Revert Files Too" puts them back the way they were before it.
    func rewindTurn(_ itemID: UUID) {
        guard let threadID = displayedThreadID, let item = itemsByID[itemID], item.kind == .user, !runner.isRunning(threadID) else {
            NSSound.beep()
            return
        }
        let canRestoreFiles = CheckpointService.shared.canRestore(threadID: threadID, userItemID: itemID)
        let alert = ThemedAlert()
        alert.messageText = String(localized: "Edit from here?")
        if canRestoreFiles {
            alert.informativeText = String(
                localized: "The conversation is rewound to before this message, which returns to the composer. “Revert Files Too” also puts files back the way they were before it, undoing any edits since."
            )
            alert.addButton(withTitle: String(localized: "Revert and Keep Changes"))
            alert.addButton(withTitle: String(localized: "Revert Files Too")).hasDestructiveAction = true
        } else {
            alert.informativeText = String(
                localized: "The conversation is rewound to before this message, which returns to the composer. Files on disk are not changed.")
            alert.addButton(withTitle: String(localized: "Edit from Here"))
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            // An agent may have started a turn of its own while the alert was open.
            guard let self, self.displayedThreadID == threadID, !self.runner.isRunning(threadID),
                self.store.item(itemID, in: threadID) != nil
            else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.rewind(to: item)
            case .alertSecondButtonReturn where canRestoreFiles:
                self.restoreFilesAndRewind(to: item, in: threadID)
            default:
                break
            }
        }
    }

    func forkTurn(_ itemID: UUID) {
        guard let threadID = displayedThreadID else { return }
        ThreadForking.fork(threadID, through: itemID)
    }

    func canFork(_ itemID: UUID) -> Bool {
        guard let threadID = displayedThreadID else { return false }
        return ThreadForking.canFork(threadID, through: itemID)
    }

    func openThread(_ threadID: UUID) {
        guard store.hasThread(threadID) else {
            NSSound.beep()
            return
        }
        AppEvents.openThread(threadID)
    }

    func showDiff(turnID: UUID, path: String?) {
        guard let threadID = displayedThreadID else { return }
        AppEvents.showTurnDiff(threadID: threadID, turnID: turnID, path: path)
    }

    /// Opens a link from the transcript. Agents write these links, so nothing they point at is run:
    /// web and mail links open, other schemes ask first, and files open in an editor (see `SafeLinks`).
    func openLink(_ link: Any) -> Bool {
        if let url = link as? URL {
            if url.isFileURL { return openFile(url.path) }
            SafeLinks.openExternal(url, from: view.window)
            return true
        }
        guard let text = link as? String, !text.isEmpty else { return false }
        if text.hasPrefix("#") { return true }
        if text.hasPrefix("www."), let url = URL(string: "https://" + text) {
            SafeLinks.openExternal(url, from: view.window)
            return true
        }
        return openFile(text)
    }

    /// Opens a path from a reply, relative to the thread's folder; `file.swift:12` and `#L12` suffixes are ignored.
    /// Files outside the thread's folder open only once the user agrees.
    private func openFile(_ reference: String) -> Bool {
        var path = reference.removingPercentEncoding ?? reference
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if let range = path.range(of: #"(:\d+)+$"#, options: .regularExpression) { path.removeSubrange(range) }
        path = (path as NSString).expandingTildeInPath
        let base = displayedThreadID.flatMap(store.workingDirectory(for:))
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : (base?.appendingPathComponent(path) ?? URL(fileURLWithPath: path))
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return true
        }
        SafeLinks.openFile(url, inside: base, from: view.window)
        return true
    }

    func quote(_ text: String, from itemID: UUID) {
        composer.addContext(MessageContext(.quote(.init(text: text, provider: item(itemID)?.provider))))
    }

    func openContext(_ context: MessageContext, from anchor: NSView) {
        MessageContextDetails.show(context, from: anchor) { [weak self] url in self?.previewAttachments([url.path], selected: 0) }
    }

    func previewAttachments(_ paths: [String], selected: Int) {
        previewURLs = paths.map { URL(fileURLWithPath: $0) }
        previewIndex = selected
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = selected
        } else {
            view.window?.makeFirstResponder(list.tableView)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func changedFiles(for turnID: UUID) -> [ChangedFile] {
        guard let threadID = displayedThreadID else { return [] }
        return CheckpointService.shared.changedFiles(threadID: threadID, userItemID: turnID)
    }

    func modelLabel(for meta: AssistantMeta) -> String {
        guard let model = modelName(for: meta) else { return meta.provider.displayName }
        return "\(meta.provider.displayName) · \(model)"
    }

    func modelName(for meta: AssistantMeta) -> String? {
        guard let modelID = meta.modelID, !modelID.isEmpty, modelID != "default" else { return nil }
        return registry.displayName(for: ModelSelection(provider: meta.provider, modelID: modelID))
    }

    func rail(for id: TranscriptRowID) -> TranscriptRail? {
        rails[id]
    }

    func findHighlights(for itemID: UUID) -> TranscriptFindHighlights? {
        findBar.isHidden ? nil : finder.highlights(for: itemID)
    }
}

// MARK: - Find commands

extension ChatViewController: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performTextFinderAction(_:)) else { return true }
        guard displayedThreadID != nil, let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
        switch action {
        case .showFindInterface, .nextMatch, .previousMatch: return true
        case .setSearchString: return selectedTextForFind != nil
        case .hideFindInterface: return !findBar.isHidden
        default: return false
        }
    }
}

// MARK: - Context menu

extension ChatViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let index = list.tableView.clickedRow
        guard index >= 0, let row = list.rows[safe: index] else { return }
        switch row.kind {
        case .live, .spacer: return
        default: break
        }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        if case .fork(let marker) = row.kind {
            add(TranscriptForkCell.actionLabel(marker), #selector(openClickedFork(_:)))
            menu.items.last?.isEnabled = marker.isAvailable
            add(String(localized: "Copy"), #selector(copyClickedRow(_:)))
            return
        }
        if case .user = row.kind {
            add(String(localized: "Copy Message"), #selector(copyClickedRow(_:)))
            add(String(localized: "Edit from Here…"), #selector(rewindClickedRow(_:)))
            menu.items.last?.isEnabled = !isThreadRunning
        } else {
            if row.isExpandable {
                add(isExpanded(row.id) ? String(localized: "Collapse") : String(localized: "Expand"), #selector(toggleClickedRow(_:)))
            }
            add(String(localized: "Copy"), #selector(copyClickedRow(_:)))
        }
        // Any row of a turn forks the conversation through that turn, once the turn is over (as in T3).
        if let id = Self.turnItemID(of: row) {
            menu.addItem(.separator())
            add(String(localized: "Fork from Here"), #selector(forkClickedRow(_:)))
            menu.items.last?.isEnabled = canFork(id)
        }
    }
}

// MARK: - Quick Look

extension ChatViewController: @preconcurrency QLPreviewPanelDataSource {
    // Quick Look calls these on the main thread.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !previewURLs.isEmpty }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.currentPreviewItemIndex = previewIndex
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs[index] as NSURL
    }
}
