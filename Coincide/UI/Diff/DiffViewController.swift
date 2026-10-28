import AppKit
import CoincideKit

/// The diff inspector: what changed in the thread's folder (uncommitted, on the branch, or in one
/// turn) as a file list over a line-numbered unified diff, with T3 Code's commit / push / pull
/// request actions in a floating bar.
final class DiffViewController: NSViewController {
    enum Scope: Equatable {
        case uncommitted
        case branch
        case latestTurn
        case turn(UUID)
    }

    var threadID: UUID? {
        didSet {
            guard threadID != oldValue else { return }
            diff = nil
            status = nil
            pullRequest = nil
            sourceControl = nil
            banner.dismiss()
            lastRunKey = threadID.map(runKey)
            reload()
            // A git action that finished while another thread was shown reports when its thread is back.
            if let threadID, let report = deferredReports.removeValue(forKey: threadID) { report() }
        }
    }

    private let store = AppStore.shared
    private let git = GitService.shared
    private let checkpoints = CheckpointService.shared
    private let runner = ThreadRunner.shared

    private let scopeButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let summaryLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let splitView = NSSplitView()
    private let fileList = DiffFileListView(frame: .zero)
    private let document = DiffDocumentView(frame: .zero)
    private let emptyState = DiffEmptyStateView(frame: .zero)
    private let actionsBar = GitActionsBar(frame: .zero)
    private let banner = GitResultBanner(frame: .zero)

    private var scopes: [UUID: Scope] = [:]
    /// File to select once the next turn diff loads, from `showTurn(_:in:path:)`.
    private var pendingPath: String?
    private var diff: GitDiff?
    private var status: GitStatus?
    private var pullRequest: GitPullRequest?
    /// The host of the branch's remote, which names its pull requests (merge requests on GitLab).
    private var sourceControl: SourceControlHost?
    private var loadTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var generation = 0
    private var actionProgress: String?
    /// The thread the running git action belongs to. Only one action runs at a time.
    private var actionThreadID: UUID?
    /// Results of git actions that finished while another thread was shown, shown when it is again.
    private var deferredReports: [UUID: () -> Void] = [:]
    private var observation: ObservationToken?
    private var needsReload = false
    private var fontSize = Theme.fontSize
    private var sizedFileCount = -1
    private var pendingReload: Task<Void, Never>?
    private var pendingReloadDeadline: ContinuousClock.Instant?
    /// When the last load started, for `liveRefreshFloor`.
    private var lastLoadStart: ContinuousClock.Instant?
    /// The floor of an automatic reload asked for while a load ran; it follows that load.
    private var queuedReloadFloor: Duration?
    /// The run state the diff was last read for (see `RunKey`).
    private var lastRunKey: RunKey?
    /// The finished tool that last asked for a reload, so later updates to it do not ask again.
    private var lastWorkspaceChangeID: UUID?
    /// The folder the shown changes were read from.
    private var loadedFolder: URL?

    private static let ignoreWhitespaceKey = "DiffIgnoreWhitespace"
    private var ignoreWhitespace: Bool {
        get { UserDefaults.standard.bool(forKey: Self.ignoreWhitespaceKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.ignoreWhitespaceKey) }
    }

    // MARK: View

    override func loadView() {
        let root = NSView()
        root.setAccessibilityLabel(String(localized: "Diff"))

        scopeButton.controlSize = .regular
        scopeButton.target = self
        scopeButton.setAccessibilityLabel(String(localized: "Changes to show"))
        scopeButton.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.image = Theme.symbol("arrow.clockwise", size: 12, weight: .medium)
        refreshButton.imagePosition = .imageOnly
        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))
        refreshButton.toolTip = String(localized: "Refresh")
        refreshButton.setAccessibilityLabel(String(localized: "Refresh"))
        optionsButton.isBordered = false
        (optionsButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        optionsButton.toolTip = String(localized: "Diff options")
        optionsButton.setAccessibilityLabel(String(localized: "Diff options"))
        let options = NSMenu()
        options.addItem(withTitle: "", action: nil, keyEquivalent: "").image = Theme.symbol("ellipsis.circle", size: 14)
        options.delegate = self
        optionsButton.menu = options

        let header = NSStackView(views: [scopeButton, summaryLabel, NSView(), spinner, refreshButton, optionsButton])
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        header.setHuggingPriority(.init(1), for: .horizontal)
        let divider = NSBox()
        divider.boxType = .separator

        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(fileList)
        splitView.addArrangedSubview(document)
        splitView.setHoldingPriority(.init(260), forSubviewAt: 0)
        splitView.setHoldingPriority(.init(250), forSubviewAt: 1)
        fileList.onSelect = { [weak self] index in self?.document.scrollToFile(at: index) }
        document.onVisibleFileChange = { [weak self] index in self?.fileList.select(index) }

        actionsBar.onQuickAction = { [weak self] in self?.runQuickAction() }
        actionsBar.menuProvider = { [weak self] in self?.actionsMenu() ?? NSMenu() }
        emptyState.isHidden = true

        for view in [header, divider, splitView, emptyState, banner, actionsBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: safe.topAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            emptyState.centerYAnchor.constraint(equalTo: splitView.centerYAnchor, constant: -20),
            actionsBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            actionsBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            actionsBar.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -10),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            banner.bottomAnchor.constraint(equalTo: actionsBar.topAnchor, constant: -8),
        ])
        document.bottomInset = 64
        view = root
        rebuildScopeMenu()
        updateActionsBar()
        observe()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // When the inspector opens with an animation, this runs while its view is still hidden.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            if self.loadTask == nil, self.needsReload || self.diff == nil { self.reload() }
        }
    }

    private var isVisible: Bool { isViewLoaded && view.window != nil && !view.isHiddenOrHasHiddenAncestor }

    private var thread: ChatThread? { threadID.flatMap(store.thread) }
    private var cwd: URL? { threadID.flatMap(store.workingDirectory(for:)) }

    private var scope: Scope {
        get { threadID.flatMap { scopes[$0] } ?? .uncommitted }
        set { if let threadID { scopes[threadID] = newValue } }
    }

    // MARK: Observation

    private func observe() {
        observation = store.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .runState(let id) where id == self.threadID:
                // Also sent for every token-usage update while a turn runs. Only a turn starting or ending,
                // or a checkpoint landing, changes what the diff shows.
                let key = self.runKey(id)
                guard key != self.lastRunKey else { return }
                self.lastRunKey = key
                self.scheduleReload()
            case .items(let id, let changed, _) where id == self.threadID && self.finishedWorkspaceChange(changed, in: id):
                // While a turn runs, the diff follows the agent's commands and edits, as in T3 Code: once one
                // finishes, at most every `liveRefreshFloor`. A git diff is too costly to repeat on a timer.
                self.scheduleReload(floor: Self.liveRefreshFloor)
            case .thread(let id) where id == self.threadID:
                // The thread may have moved into (or out of) a worktree.
                if self.cwd != self.loadedFolder { self.reload() }
            case .projects where self.cwd != self.loadedFolder:
                // The project's folder was located somewhere else.
                self.reload()
            case .settings where self.fontSize != Theme.fontSize:
                self.fontSize = Theme.fontSize
                if let diff = self.diff { self.show(diff, keepPosition: true) }
            default:
                break
            }
        }
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(repositoryChanged(_:)), name: GitService.repositoryDidChangeNotification, object: nil)
        center.addObserver(
            self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification,
            object: nil)
    }

    @objc private func repositoryChanged(_ notification: Notification) {
        guard let path = notification.userInfo?["path"] as? String, let root = status?.rootPath ?? cwd?.path else { return }
        let changed = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if changed.hasPrefix(root) || root.hasPrefix(changed) { scheduleReload() }
    }

    @objc private func applicationDidBecomeActive() { scheduleReload() }

    /// The least time between automatic reloads for the agent's edits (T3 Code's live-refresh floor).
    private static let liveRefreshFloor: Duration = .seconds(10)

    /// Coalesces bursts of change notifications into one reload, `floor` after the last load started at the
    /// earliest. A load that is running is never cut short, since its git processes would run on anyway:
    /// the reload follows it instead.
    private func scheduleReload(floor: Duration = .zero) {
        guard loadTask == nil else {
            queuedReloadFloor = min(queuedReloadFloor ?? floor, floor)
            return
        }
        var deadline = ContinuousClock.now + .milliseconds(400)
        if let lastLoadStart { deadline = max(deadline, lastLoadStart + floor) }
        if pendingReload != nil, let pending = pendingReloadDeadline, pending <= deadline { return }
        pendingReload?.cancel()
        pendingReloadDeadline = deadline
        pendingReload = Task { [weak self] in
            try? await Task.sleep(until: deadline)
            guard !Task.isCancelled, let self else { return }
            self.pendingReload = nil
            self.pendingReloadDeadline = nil
            self.reload(keepPosition: true)
        }
    }

    /// What of the thread's run state the diff depends on.
    private struct RunKey: Equatable {
        var isRunning: Bool
        var checkpointCount: Int
        var latestCheckpoint: UUID?
        var latestFinishedAt: Date?
    }

    private func runKey(_ threadID: UUID) -> RunKey {
        let turns = checkpoints.checkpoints(threadID: threadID)
        return RunKey(
            isRunning: runner.isRunning(threadID), checkpointCount: turns.count, latestCheckpoint: turns.last?.userItemID,
            latestFinishedAt: turns.last?.afterAt)
    }

    /// Whether a tool that can change files (a command or an edit, not a read or search) just finished in the
    /// running turn: T3 Code's workspace mutation.
    private func finishedWorkspaceChange(_ changed: [UUID], in threadID: UUID) -> Bool {
        guard runner.isRunning(threadID) else { return false }
        for id in changed.reversed() where id != lastWorkspaceChangeID {
            guard let item = store.item(id, in: threadID), item.kind == .tool, let status = item.status,
                status != .running, status != .waiting
            else { continue }
            switch item.category {
            case .read, .search, .web, .todo: continue
            default: break
            }
            lastWorkspaceChangeID = id
            return true
        }
        return false
    }

    /// Shows one turn's changes, selecting `path` when given. Call once the inspector is open.
    func showTurn(_ turnID: UUID, in threadID: UUID, path: String?) {
        scopes[threadID] = .turn(turnID)
        guard threadID == self.threadID else { return }
        pendingPath = path
        reload()
    }

    // MARK: Loading

    @objc private func refresh(_ sender: Any?) { reload(keepPosition: true) }

    private enum Content {
        case diff(GitDiff, root: URL?)
        case empty(DiffEmptyStateView.Message)
    }

    /// Reloads the diff for the current scope and the git status for the action bar.
    private func reload(keepPosition: Bool = false) {
        guard isVisible else {
            needsReload = true
            return
        }
        needsReload = false
        pendingReload?.cancel()
        pendingReload = nil
        pendingReloadDeadline = nil
        // This load reads everything reported so far.
        queuedReloadFloor = nil
        lastLoadStart = .now
        loadedFolder = cwd
        rebuildScopeMenu()
        generation += 1
        let generation = generation
        loadTask?.cancel()
        spinner.startAnimation(nil)
        loadTask = Task { [weak self] in
            guard let self else { return }
            let content = await self.loadContent()
            guard generation == self.generation, !Task.isCancelled else { return }
            self.loadTask = nil
            self.spinner.stopAnimation(nil)
            self.apply(content, keepPosition: keepPosition)
            // Changes reported while this load ran may have come too late for it.
            if let floor = self.queuedReloadFloor {
                self.queuedReloadFloor = nil
                self.scheduleReload(floor: floor)
            }
        }
        reloadStatus()
    }

    private func loadContent() async -> Content {
        guard let threadID, let thread else { return .empty(.noThread) }
        guard let cwd, FileManager.default.fileExists(atPath: cwd.path) else {
            return .empty(.folderMissing(cwd?.path ?? ""))
        }
        guard let root = await git.repositoryRoot(cwd) else { return .empty(.notRepository) }
        do {
            switch scope {
            case .uncommitted:
                let diff = try await git.workingTreeDiff(cwd, ignoreWhitespace: ignoreWhitespace)
                return diff.files.isEmpty ? .empty(.noUncommittedChanges) : .diff(diff, root: root)
            case .branch:
                let diff = try await git.branchDiff(cwd, ignoreWhitespace: ignoreWhitespace)
                return diff.files.isEmpty ? .empty(.noBranchChanges(diff.baseLabel)) : .diff(diff, root: root)
            case .latestTurn, .turn:
                guard let checkpoint = selectedCheckpoint(thread) else {
                    return .empty(store.settings.checkpointsEnabled ? .noTurns : .checkpointsOff)
                }
                guard
                    let patch = await checkpoints.turnDiff(
                        threadID: threadID, userItemID: checkpoint.userItemID, ignoreWhitespace: ignoreWhitespace)
                else { return .empty(.failed(String(localized: "This turn's changes are no longer available."))) }
                let diff = await GitService.parseDiff(patch, files: checkpoint.files)
                let turnRoot = await git.repositoryRoot(URL(fileURLWithPath: checkpoint.cwd)) ?? root
                return diff.files.isEmpty ? .empty(.noTurnChanges) : .diff(diff, root: turnRoot)
            }
        } catch {
            return .empty(.failed(error.localizedDescription))
        }
    }

    private func apply(_ content: Content, keepPosition: Bool) {
        switch content {
        case .empty(let message):
            diff = nil
            emptyState.show(message, action: message == .notRepository ? { [weak self] in self?.initializeRepository() } : nil)
            emptyState.isHidden = false
            splitView.isHidden = true
            summaryLabel.stringValue = ""
        case .diff(let diff, let root):
            emptyState.isHidden = true
            splitView.isHidden = false
            fileList.rootURL = root
            document.rootURL = root
            let unchanged = diff == self.diff
            self.diff = diff
            let target = pendingPath.flatMap { path in diff.files.firstIndex { $0.path == path } }
            pendingPath = nil
            if !unchanged {
                show(diff, keepPosition: keepPosition, revealing: target)
            } else if let target {
                document.scrollToFile(at: target)
                fileList.select(target)
            }
            summaryLabel.attributedStringValue = Self.summary(diff)
        }
        updateActionsBar()
    }

    /// Shows `diff`, and the file at `target` once the document has it: the document only gets the new
    /// diff after its presentation is made in the background.
    private func show(_ diff: GitDiff, keepPosition: Bool, revealing target: Int? = nil) {
        fileList.show(diff.files)
        sizeFileList(fileCount: diff.files.count)
        Task { [weak self] in
            let presentation = await Task.detached(priority: .userInitiated) { DiffPresentation.make(diff) }.value
            guard let self, self.diff == diff else { return }
            self.document.show(diff, presentation: presentation, keepPosition: keepPosition && target == nil)
            if let target {
                self.document.scrollToFile(at: target)
                // After the scroll, which may have reported another file at the top.
                self.fileList.select(target)
            }
        }
    }

    /// Gives the file list room for its files, up to a third of the panel. Only a change in the number
    /// of files moves the divider, so where the user dragged it is kept otherwise.
    private func sizeFileList(fileCount: Int) {
        guard fileCount != sizedFileCount else { return }
        view.layoutSubtreeIfNeeded()
        let height = splitView.bounds.height
        guard height > 0 else { return }
        sizedFileCount = fileCount
        splitView.setPosition(min(CGFloat(fileCount) * 24 + 8, max(96, height / 3)), ofDividerAt: 0)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let diff, diff.files.count != sizedFileCount { sizeFileList(fileCount: diff.files.count) }
    }

    private static func summary(_ diff: GitDiff) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .medium)
        let files = diff.files.count == 1 ? String(localized: "1 file") : String(localized: "\(diff.files.count) files")
        let text = NSMutableAttributedString(
            string: files + "  ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        text.append(NSAttributedString(string: "+\(diff.additions)", attributes: [.font: font, .foregroundColor: DiffColors.addition]))
        text.append(NSAttributedString(string: " "))
        text.append(NSAttributedString(string: "−\(diff.deletions)", attributes: [.font: font, .foregroundColor: DiffColors.deletion]))
        if diff.isTruncated {
            text.append(
                NSAttributedString(
                    string: "  " + String(localized: "(partial)"),
                    attributes: [.font: font, .foregroundColor: NSColor.systemOrange]))
        }
        return text
    }

    // MARK: Scope

    /// The thread's turns that have checkpoints, newest first, with their turn numbers.
    private func turns(_ thread: ChatThread) -> [(number: Int, checkpoint: TurnCheckpoint)] {
        var numbers: [UUID: Int] = [:]
        var count = 0
        for item in thread.items where item.opensUserTurn {
            count += 1
            numbers[item.id] = count
        }
        return checkpoints.checkpoints(threadID: thread.id).compactMap { checkpoint in
            numbers[checkpoint.userItemID].map { ($0, checkpoint) }
        }.reversed()
    }

    private func selectedCheckpoint(_ thread: ChatThread) -> TurnCheckpoint? {
        let turns = turns(thread)
        switch scope {
        case .latestTurn: return turns.first?.checkpoint
        case .turn(let id): return turns.first { $0.checkpoint.userItemID == id }?.checkpoint
        case .uncommitted, .branch: return nil
        }
    }

    private func rebuildScopeMenu() {
        let menu = NSMenu()
        let title: String
        let turns = thread.map(turns) ?? []
        switch scope {
        case .uncommitted: title = String(localized: "Uncommitted Changes")
        case .branch: title = String(localized: "Branch Changes")
        case .latestTurn: title = String(localized: "Latest Turn")
        case .turn(let id):
            title = turns.first { $0.checkpoint.userItemID == id }.map { String(localized: "Turn \($0.number)") }
                ?? String(localized: "Turn")
        }
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        func add(_ title: String, _ scope: Scope, symbol: String) {
            let item = menu.addItem(withTitle: title, action: #selector(selectScope(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ScopeBox(scope)
            item.state = self.scope == scope ? .on : .off
            item.image = Theme.symbol(symbol)
        }
        add(String(localized: "Uncommitted Changes"), .uncommitted, symbol: "plus.forwardslash.minus")
        add(String(localized: "Branch Changes"), .branch, symbol: "arrow.triangle.branch")
        menu.addItem(.separator())
        add(String(localized: "Latest Turn"), .latestTurn, symbol: "clock.arrow.circlepath")
        let turnsItem = menu.addItem(withTitle: String(localized: "Turns"), action: nil, keyEquivalent: "")
        if turns.isEmpty {
            turnsItem.isEnabled = false
            if !store.settings.checkpointsEnabled { turnsItem.title = String(localized: "Turn checkpoints are off") }
        } else {
            let submenu = NSMenu()
            for turn in turns {
                let item = submenu.addItem(
                    withTitle: Self.turnTitle(number: turn.number, checkpoint: turn.checkpoint),
                    action: #selector(selectScope(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ScopeBox(.turn(turn.checkpoint.userItemID))
                item.state = scope == .turn(turn.checkpoint.userItemID) ? .on : .off
            }
            turnsItem.submenu = submenu
        }
        scopeButton.menu = menu
        scopeButton.setTitle(title)
    }

    private static func turnTitle(number: Int, checkpoint: TurnCheckpoint) -> String {
        guard let finished = checkpoint.afterAt else { return String(localized: "Turn \(number) · Running") }
        let files = checkpoint.files.count
        let time = finished.formatted(date: .omitted, time: .shortened)
        return files == 1
            ? String(localized: "Turn \(number) · \(time) · 1 file")
            : String(localized: "Turn \(number) · \(time) · \(files) files")
    }

    @objc private func selectScope(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ScopeBox, box.scope != scope else { return }
        scope = box.scope
        diff = nil
        reload()
    }

    // MARK: Git status and actions

    private func reloadStatus() {
        guard let cwd else {
            status = nil
            updateActionsBar()
            return
        }
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            guard let self else { return }
            let status = try? await self.git.status(cwd)
            guard !Task.isCancelled, cwd == self.cwd else { return }
            self.status = status
            self.updateActionsBar()
            if status?.hasRemote == true {
                let host = await self.git.sourceControlHost(cwd, branch: status?.branch)
                guard !Task.isCancelled, cwd == self.cwd else { return }
                self.sourceControl = host
            } else {
                self.sourceControl = nil
            }
            if let branch = status?.branch, status?.hasUpstream == true {
                let pullRequest = await self.git.openPullRequest(for: branch, in: cwd)
                guard !Task.isCancelled, cwd == self.cwd else { return }
                self.pullRequest = pullRequest
            } else {
                self.pullRequest = nil
            }
            self.updateActionsBar()
        }
    }

    /// What the repository's host calls pull requests.
    private var changeRequestTerm: ChangeRequestTerm { sourceControl?.kind.changeRequest ?? .pullRequest }

    private var quickAction: GitQuickAction {
        GitQuickAction.resolve(
            status: status, isBusy: actionProgress != nil, hasOpenPullRequest: pullRequest != nil, term: changeRequestTerm)
    }

    private func updateActionsBar() {
        let visible = status?.isRepository == true && thread != nil
        actionsBar.isHidden = !visible
        guard visible, let status else { return }
        actionsBar.update(
            GitActionsBar.State(
                branch: status.branch, ahead: status.ahead, behind: status.behind, upstream: status.upstream,
                pullRequest: pullRequest, changeRequestTerm: changeRequestTerm, quickAction: quickAction,
                // Another thread's action shows here as busy buttons, not as this thread's progress.
                progress: actionThreadID == threadID ? actionProgress : nil))
    }

    private func runQuickAction() {
        switch quickAction.kind {
        case .run(let action): perform(action)
        case .pull: pull()
        case .hint(let hint): banner.show(title: quickAction.title, detail: hint, isError: false)
        }
    }

    private func actionsMenu() -> NSMenu {
        let menu = NSMenu()
        let availability = GitActionAvailability.resolve(
            status: status, isBusy: actionProgress != nil, hasOpenPullRequest: pullRequest != nil)
        func add(_ title: String, symbol: String, enabled: Bool, _ handler: @escaping () -> Void) {
            let item = menu.addItem(withTitle: title, action: enabled ? #selector(MenuAction.run(_:)) : nil, keyEquivalent: "")
            let action = MenuAction(handler)
            item.target = action
            item.representedObject = action
            item.image = Theme.symbol(symbol)
        }
        add(String(localized: "Commit…"), symbol: "checkmark.circle", enabled: availability.canCommit) { [weak self] in
            self?.showCommitSheet()
        }
        if availability.showsRemoteActions {
            add(String(localized: "Push"), symbol: "arrow.up.circle", enabled: availability.canPush) { [weak self] in
                self?.perform(.push)
            }
            let term = changeRequestTerm
            if let pullRequest, let url = URL(string: pullRequest.url) {
                add(term.viewTitle(pullRequest.number), symbol: "arrow.triangle.pull", enabled: true) { [weak self] in
                    ChangeRequestLinks.openChangeRequest(url, from: self?.view.window)
                }
            } else {
                add(term.createMenuTitle, symbol: "arrow.triangle.pull", enabled: availability.canCreatePR) {
                    [weak self] in self?.perform(.createPR)
                }
            }
            menu.addItem(.separator())
            add(
                String(localized: "Pull"), symbol: "arrow.down.circle",
                enabled: actionProgress == nil && status?.hasUpstream == true && (status?.behind ?? 0) > 0
            ) { [weak self] in self?.pull() }
        }
        if status?.branch == nil {
            menu.addItem(.separator())
            let note = menu.addItem(withTitle: changeRequestTerm.detachedHeadNote, action: nil, keyEquivalent: "")
            note.isEnabled = false
        }
        return menu
    }

    private func showCommitSheet() {
        guard let status, status.hasChanges else { return }
        let sheet = CommitSheetController(branch: status.branch, isDefaultBranch: status.isDefaultBranch, files: status.files)
        let threadID = self.threadID
        sheet.onCommit = { [weak self] choice in
            // The files picked are in this thread's folder.
            guard let self, self.threadID == threadID else { return }
            self.perform(.commit, message: choice.message, paths: choice.paths, featureBranch: choice.onNewBranch)
        }
        presentAsSheet(sheet)
    }

    /// Runs a stacked git action. Pushing from the default branch asks first, offering a feature branch.
    private func perform(
        _ action: GitStackedAction, message: String? = nil, paths: [String]? = nil, featureBranch: Bool = false,
        confirmed: Bool = false
    ) {
        // Without the status, whether this is the default branch (and so needs asking) is unknown.
        guard let threadID, let thread, let cwd, let status, actionProgress == nil else { return }
        if !confirmed, !featureBranch,
            GitQuickAction.requiresDefaultBranchConfirmation(action, isDefaultBranch: status.isDefaultBranch)
        {
            confirmDefaultBranch(action) { [weak self] choice in
                // The question named this thread's branch.
                guard let self, self.threadID == threadID else { return }
                self.perform(action, message: message, paths: paths, featureBranch: choice, confirmed: true)
            }
            return
        }
        actionProgress = String(localized: "Starting…")
        actionThreadID = threadID
        banner.dismiss()
        updateActionsBar()
        let request = GitActionRequest(
            action: action, commitMessage: message, filePaths: paths, featureBranch: featureBranch,
            selection: thread.selection, threadContext: Handoff.transcript(thread.items, budget: 16_000))
        Task { [weak self] in
            guard let self else { return }
            let report: () -> Void
            do {
                let result = try await self.git.run(request, in: cwd) { [weak self] label in
                    self?.actionProgress = label
                    self?.updateActionsBar()
                }
                if let branch = result.createdBranch {
                    self.store.updateThread(threadID) { $0.branch = branch }
                }
                // Without a signed-in CLI the pull request is finished on the host's page, opened at once
                // while its thread is shown; the result's button opens it again, or later.
                if case .openChangeRequestPage(let page) = result.followUp, self.threadID == threadID {
                    ChangeRequestLinks.openPage(page, from: self.view.window)
                }
                report = { [weak self] in self?.showResult(result, threadID: threadID) }
            } catch {
                report = { [weak self] in self?.showFailure(error) }
            }
            self.finishAction(in: threadID, report: report)
        }
    }

    /// Ends the running git action. Its result shows in the thread it ran in: now when that thread is
    /// shown, else once it is again, so a follow-up never acts on another thread's folder.
    private func finishAction(in threadID: UUID, report: @escaping () -> Void) {
        actionProgress = nil
        actionThreadID = nil
        if self.threadID == threadID {
            report()
        } else {
            deferredReports[threadID] = report
        }
        reload(keepPosition: true)
    }

    private func showResult(_ result: GitActionResult, threadID: UUID) {
        let term = result.changeRequestTerm
        switch result.followUp {
        case .run(let next):
            let title = next == .push ? String(localized: "Push") : GitStackedAction.createPR.title(for: term)
            banner.show(title: result.title, detail: result.detail, isError: false, actionTitle: title) { [weak self] in
                guard let self, self.threadID == threadID else { return }
                self.perform(next)
            }
        case .openPullRequest(let url):
            banner.show(title: result.title, detail: result.detail, isError: false, actionTitle: term.viewButtonTitle) {
                [weak self] in ChangeRequestLinks.openChangeRequest(url, from: self?.view.window)
            }
        case .openChangeRequestPage(let url):
            let name = result.host?.displayName ?? ""
            banner.show(
                title: result.title, detail: result.detail, isError: false,
                actionTitle: String(localized: "Open \(name)")
            ) { [weak self] in ChangeRequestLinks.openPage(url, from: self?.view.window) }
        case nil:
            banner.show(title: result.title, detail: result.detail, isError: false)
        }
    }

    private func showFailure(_ error: Error) {
        let gitError = error as? GitError
        banner.show(title: error.localizedDescription, detail: gitError?.detail, isError: true)
    }

    /// T3 Code's default-branch question: continue there, or move the work to a feature branch.
    private func confirmDefaultBranch(_ action: GitStackedAction, completion: @escaping (_ featureBranch: Bool) -> Void) {
        guard let window = view.window, let status else { return }
        let branch = status.branch ?? "HEAD"
        let commits = action.includesCommit
        let alert = NSAlert()
        switch action {
        case .commitPush, .push:
            alert.messageText =
                commits ? String(localized: "Commit and push to the default branch?") : String(localized: "Push to the default branch?")
        default:
            alert.messageText = changeRequestTerm.defaultBranchQuestion(commits: commits)
        }
        alert.informativeText = String(
            localized:
                "This works on “\(branch)”. You can continue on this branch, or create a feature branch and run the same action there."
        )
        let canBranch = commits && status.hasChanges
        if canBranch { alert.addButton(withTitle: String(localized: "Use a Feature Branch")) }
        alert.addButton(withTitle: commits ? String(localized: "Continue on \(branch)") : String(localized: "Push to \(branch)"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            switch (canBranch, index) {
            case (true, 0): completion(true)
            case (true, 1), (false, 0): completion(false)
            default: break
            }
        }
    }

    private func pull() {
        guard let threadID, let cwd, actionProgress == nil else { return }
        actionProgress = String(localized: "Pulling…")
        actionThreadID = threadID
        updateActionsBar()
        Task { [weak self] in
            guard let self else { return }
            let report: () -> Void
            do {
                let result = try await self.git.pull(cwd)
                let title =
                    result == .pulled ? String(localized: "Pulled the latest changes") : String(localized: "Already up to date")
                report = { [weak self] in self?.banner.show(title: title, detail: nil, isError: false) }
            } catch {
                report = { [weak self] in self?.showFailure(error) }
            }
            self.finishAction(in: threadID, report: report)
        }
    }

    private func initializeRepository() {
        guard let threadID, let cwd else { return }
        Task { [weak self] in
            do {
                try await self?.git.initializeRepository(cwd)
            } catch {
                if self?.threadID == threadID { self?.showFailure(error) }
            }
            self?.reload()
        }
    }
}

extension DiffViewController: NSMenuDelegate {
    /// The options menu, rebuilt each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let icon = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        icon.image = Theme.symbol("ellipsis.circle", size: 14)
        let whitespace = menu.addItem(
            withTitle: String(localized: "Ignore Whitespace"), action: #selector(toggleWhitespace), keyEquivalent: "")
        whitespace.target = self
        whitespace.state = ignoreWhitespace ? .on : .off
        let collapse = menu.addItem(
            withTitle: document.allCollapsed ? String(localized: "Expand All Files") : String(localized: "Collapse All Files"),
            action: diff == nil ? nil : #selector(toggleCollapseAll), keyEquivalent: "")
        collapse.target = self
        menu.addItem(.separator())
        let reveal = menu.addItem(
            withTitle: String(localized: "Reveal Folder in Finder"), action: cwd == nil ? nil : #selector(revealFolder),
            keyEquivalent: "")
        reveal.target = self
    }

    @objc private func toggleWhitespace() {
        ignoreWhitespace.toggle()
        reload(keepPosition: true)
    }

    @objc private func toggleCollapseAll() {
        document.setAllCollapsed(!document.allCollapsed)
    }

    @objc private func revealFolder() {
        guard let cwd else { return }
        NSWorkspace.shared.activateFileViewerSelecting([cwd])
    }
}

extension DiffViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int)
        -> CGFloat
    {
        48
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int)
        -> CGFloat
    {
        splitView.bounds.height - 120
    }
}

/// Wraps a scope for a menu item's represented object.
private final class ScopeBox: NSObject {
    let scope: DiffViewController.Scope

    init(_ scope: DiffViewController.Scope) {
        self.scope = scope
    }
}

/// A menu item target that runs a closure; the item keeps it alive as its represented object.
private final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run(_ sender: NSMenuItem) { handler() }
}

/// Centered symbol, title, message and optional button for when there is no diff to show.
final class DiffEmptyStateView: NSView {
    enum Message: Equatable {
        case noThread
        case folderMissing(String)
        case notRepository
        case noUncommittedChanges
        case noBranchChanges(String?)
        case noTurns
        case checkpointsOff
        case noTurnChanges
        case failed(String)
    }

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.contentTintColor = .tertiaryLabelColor
        titleLabel.font = .systemFont(ofSize: Theme.fontSize + 1, weight: .semibold)
        titleLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: Theme.fontSize - 1)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        button.bezelStyle = .push
        button.target = self
        button.action = #selector(runAction)
        let stack = NSStackView(views: [icon, titleLabel, messageLabel, button])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(12, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ message: Message, action: (() -> Void)?) {
        let content: (symbol: String, title: String, text: String, button: String?)
        switch message {
        case .noThread:
            content = (
                "plus.forwardslash.minus", String(localized: "No Thread Selected"),
                String(localized: "Select a thread to see the changes in its folder."), nil
            )
        case .folderMissing(let path):
            content = ("folder.badge.minus", String(localized: "Folder Not Found"), path, nil)
        case .notRepository:
            content = (
                "externaldrive.connected.to.line.below", String(localized: "Not a Git Repository"),
                String(localized: "Changes, turn diffs and checkpoints need Git."), String(localized: "Initialize Git")
            )
        case .noUncommittedChanges:
            content = (
                "checkmark.circle", String(localized: "No Uncommitted Changes"),
                String(localized: "The working tree matches the last commit."), nil
            )
        case .noBranchChanges(let base):
            content = (
                "checkmark.circle", String(localized: "No Changes on This Branch"),
                base.map { String(localized: "Nothing differs from \($0).") } ?? "", nil
            )
        case .noTurns:
            content = (
                "clock.arrow.circlepath", String(localized: "No Turns Yet"),
                String(localized: "Each turn's changes appear here once the agent starts working."), nil
            )
        case .checkpointsOff:
            content = (
                "clock.arrow.circlepath", String(localized: "Turn Checkpoints Are Off"),
                String(localized: "Turn on checkpoints in Settings to see each turn's changes."), nil
            )
        case .noTurnChanges:
            content = (
                "checkmark.circle", String(localized: "No Files Changed"),
                String(localized: "This turn didn't change any files."), nil
            )
        case .failed(let text):
            content = ("exclamationmark.triangle", String(localized: "Couldn't Load the Changes"), text, nil)
        }
        icon.image = Theme.symbol(content.symbol, size: 28, weight: .light)
        titleLabel.stringValue = content.title
        messageLabel.stringValue = content.text
        messageLabel.isHidden = content.text.isEmpty
        button.title = content.button ?? ""
        button.isHidden = content.button == nil || action == nil
        self.action = action
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([content.title, content.text].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    @objc private func runAction() { action?() }
}
