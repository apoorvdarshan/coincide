import AppKit
import CoincideKit

/// The main window: sidebar | chat + terminal | diff inspector, a unified toolbar, and the
/// open thread. Cross-controller requests arrive through `AppEvents`.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let splitController = MainSplitViewController()
    private(set) lazy var root = MainRootViewController(split: splitController)
    var rail: NavigationRailViewController { root.rail }
    let runStatus = RunStatusView()
    let projectScripts = ProjectScriptsControl()
    var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    let threadTitle = ThreadTitleView()

    private let store = AppStore.shared
    private var token: ObservationToken?
    private(set) var selectedThreadID: UUID?
    private var hasOpenedThread = false

    var sidebar: SidebarViewController { splitController.sidebar }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.title = "Coincide"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.backgroundColor = Theme.contentBackground
        // The toolbar shows the theme's colors under it rather than a band of its own.
        window.titlebarAppearsTransparent = true
        // The toolbar shows the title after the thread list (`ThreadTitleView`); the window's would sit over the list.
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 820, height: 520)
        let savedFrame = UIState.shared.values.windowFrame
        self.init(window: window)
        shouldCascadeWindows = false
        window.contentViewController = root
        window.toolbar = makeToolbar()
        if let savedFrame {
            window.setFrame(from: savedFrame)
        } else {
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
        }
        // Only now, so the sizing above is not saved as the user's frame.
        window.delegate = self
        configure()
    }

    private func configure() {
        // Text fields edit through the window's shared field editor; it selects in the theme's colors too.
        (window?.fieldEditor(true, for: nil) as? NSTextView)?.selectedTextAttributes = [.backgroundColor: Theme.textSelection]
        sidebar.onSelectThread = { [weak self] id in self?.open(id, unsnooze: false) }
        splitController.onPanelsChanged = { [weak self] in self?.updatePanelItems() }
        runStatus.onStop = { [weak self] in self?.stopTurn(nil) }
        projectScripts.onVisibilityChange = { [weak self] visible in
            self?.toolbarItems[.projectScripts]?.isHidden = !visible
        }
        // A script started in the open thread shows its terminal.
        ProjectScripts.shared.onShowTerminal = { [weak self] threadID in
            guard let self, threadID == selectedThreadID, !splitController.content.isTerminalOpen else { return }
            splitController.content.toggleTerminal()
        }
        runStatus.onVisibilityChange = { [weak self] visible in
            self?.toolbarItems[.runStatus]?.isHidden = !visible
        }
        token = store.observe { [weak self] change in self?.handle(change) }

        let center = NotificationCenter.default
        let events: [(Notification.Name, Selector)] = [
            (.coincideOpenThread, #selector(openThreadEvent(_:))),
            (.coincideNewThread, #selector(newThreadEvent(_:))),
            (.coincideAddProject, #selector(addProject(_:))),
            (.coincideShowTurnDiff, #selector(showTurnDiff(_:))),
            (.coincideToggleTerminal, #selector(toggleTerminalPanel(_:))),
            (.coincideThreadActivityChanged, #selector(activityChanged(_:))),
            (OpenTargets.preferredDidChange, #selector(updateOpenInItem)),
            (KeyBindingsController.didChangeNotification, #selector(updateToolbarShortcuts)),
        ]
        for (name, selector) in events { center.addObserver(self, selector: selector, name: name, object: nil) }

        let saved = UIState.shared.values.selectedThreadID.flatMap { store.summary($0) }
        let initial = saved.flatMap { ThreadSnooze.isHidden($0) ? nil : $0.id }
            ?? store.recentThreads.first(where: { !ThreadSnooze.isHidden($0) })?.id
        open(initial, unsnooze: false)
        updatePanelItems()
    }

    // MARK: Selection

    /// Shows a thread in the chat, terminal and diff panes, and highlights it in the sidebar.
    /// As in T3, the composer takes focus, unless the user is working in the sidebar, terminal or diff.
    func open(_ threadID: UUID?, unsnooze: Bool = true) {
        let threadID = threadID.flatMap { store.hasThread($0) ? $0 : nil }
        // Explicit opens (palette, notifications, keyboard navigation) bring a conversation back.
        // Restoring the window and the sidebar's automatic neighbour selection preserve its snooze.
        if unsnooze, let threadID, store.summary(threadID)?.snoozedUntil != nil {
            ThreadSnooze.shared.unsnooze(threadID)
        }
        guard threadID != selectedThreadID || !hasOpenedThread else { return }
        hasOpenedThread = true
        selectedThreadID = threadID
        splitController.setThreadID(threadID)
        sidebar.select(threadID: threadID)
        ThreadActivity.shared.visibleThreadID = threadID
        if let threadID { NotificationController.shared.clearDelivered(for: threadID) }
        UIState.shared.update { $0.selectedThreadID = threadID }
        updateTitle()
        updateRunStatus()
        updateRail()
        if threadID != nil, !isFocusInSidePanel { splitController.content.chat.focusComposer() }
    }

    /// Whether keyboard focus is in the sidebar, the terminal or the inspector, where it stays when the thread changes.
    private var isFocusInSidePanel: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return [sidebar.view, splitController.content.terminal.view, splitController.inspector.view].contains {
            responder.isDescendant(of: $0)
        }
    }

    var selectedThread: ThreadSummary? { selectedThreadID.flatMap { store.summary($0) } }

    /// The project new threads go to: the open thread's, else the first one.
    var currentProjectID: UUID? { selectedThread?.projectID ?? store.projects.first?.id }

    private func handle(_ change: StoreChange) {
        switch change {
        case .thread(let id) where id == selectedThreadID:
            updateTitle()
        case .runState(let id) where id == selectedThreadID:
            updateRunStatus()
        case .projects, .threadList:
            // The open thread may be gone; the sidebar then opens its neighbour.
            updateTitle()
            updateRunStatus()
        default:
            break
        }
    }

    @objc private func activityChanged(_ note: Notification) {
        guard let id = note.userInfo?["threadID"] as? UUID, id == selectedThreadID else { return }
        updateRunStatus()
    }

    /// Thread title, with project and branch as the subtitle and the folder as the proxy icon.
    /// Runs on every metadata change (drafts included), so it only touches what changed.
    private func updateTitle() {
        guard let window else { return }
        var title = "Coincide"
        var subtitle = ""
        var folder: URL?
        if let thread = selectedThread {
            title = thread.title
            let project = store.project(thread.projectID)
            subtitle = project?.isChats == true ? String(localized: "Chat") : project?.name ?? ""
            if project?.isChats != true, let branch = thread.branch, !branch.isEmpty {
                subtitle += subtitle.isEmpty ? branch : " · \(branch)"
            }
            folder = store.workingDirectory(for: thread.id)
        }
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
        threadTitle.set(title: title, subtitle: subtitle)
        if window.representedURL != folder { window.representedURL = folder }
    }

    private func updateRunStatus() {
        projectScripts.threadID = selectedThreadID
        guard let id = selectedThreadID else {
            runStatus.update(.idle)
            return
        }
        let runner = ThreadRunner.shared
        let pending = ThreadActivity.shared.pendingApprovalCount(id)
        if pending > 0 {
            runStatus.update(.approval(count: pending))
        } else if runner.isStarting(id) {
            runStatus.update(.starting)
        } else if let turn = runner.turn(id) {
            // A turn the agent started itself runs and stops like any other; the tooltip says why it runs.
            runStatus.update(.running(since: turn.startedAt, note: AgentTurns.shared.runningNote(in: id)))
        } else {
            runStatus.update(.idle)
        }
    }

    // MARK: AppEvents

    @objc private func openThreadEvent(_ note: Notification) {
        guard let id = note.userInfo?["threadID"] as? UUID else { return }
        showWindow(nil)
        open(id)
    }

    @objc private func newThreadEvent(_ note: Notification) {
        newThread(in: note.userInfo?["projectID"] as? UUID)
    }

    func newThread(in projectID: UUID?) {
        showWindow(nil)
        if projectID == nil, store.settings.newThreadStartsChat {
            ThreadActions.newChat()
            return
        }
        guard let project = projectID ?? currentProjectID else {
            ThreadActions.addProject(in: window)
            return
        }
        ThreadActions.newThread(in: project)
    }

    // MARK: Actions

    /// A thread without a project, whatever New Thread does.
    @objc func newChat(_ sender: Any?) {
        showWindow(nil)
        ThreadActions.newChat()
    }

    @objc func newThread(_ sender: Any?) {
        newThread(in: nil)
    }

    @objc func newThreadInProject(_ sender: NSMenuItem) {
        newThread(in: sender.representedObject as? UUID)
    }

    @objc func addProject(_ sender: Any?) {
        showWindow(nil)
        ThreadActions.addProject(in: window)
    }

    @objc func toggleSidebarPanel(_ sender: Any?) {
        splitController.toggleSidebarPanel()
    }

    @objc func toggleTerminalPanel(_ sender: Any?) {
        showWindow(nil)
        splitController.content.toggleTerminal()
    }

    @objc func toggleDiffPanel(_ sender: Any?) {
        showWindow(nil)
        splitController.toggleDiffPanel()
    }

    @objc func togglePreviewPanel(_ sender: Any?) {
        showWindow(nil)
        splitController.togglePreviewPanel()
    }

    @objc func togglePullRequestsPanel(_ sender: Any?) {
        showWindow(nil)
        splitController.togglePullRequestsPanel()
    }

    /// Opens the diff inspector on one turn's changes.
    @objc private func showTurnDiff(_ notification: Notification) {
        guard let threadID = notification.userInfo?["threadID"] as? UUID,
            let turnID = notification.userInfo?["turnID"] as? UUID
        else { return }
        showWindow(nil)
        splitController.showDiffPanel()
        splitController.diff.showTurn(turnID, in: threadID, path: notification.userInfo?["path"] as? String)
    }

    /// Command-K opens the palette, or closes it when it is showing.
    @objc func showCommandPalette(_ sender: Any?) {
        let palette = CommandPaletteController.shared
        // Check first: showing the window would take focus from the palette and close it.
        guard !palette.isVisible else {
            palette.dismiss()
            return
        }
        showWindow(nil)
        palette.show(in: window)
    }

    @objc func searchThreads(_ sender: Any?) {
        showWindow(nil)
        if !splitController.isSidebarOpen { splitController.toggleSidebarPanel() }
        sidebar.focusSearch()
    }

    /// Find…, Find Next and Find Previous reach the window when focus is outside the chat, in the sidebar or
    /// the diff; as in T3 Code they search the open thread. The chat handles them itself when it has focus,
    /// and the terminal keeps them for its own search.
    override func performTextFinderAction(_ sender: Any?) {
        splitController.content.chat.performTextFinderAction(sender)
    }

    /// Opens the find bar over the open thread.
    func findInThread() {
        showWindow(nil)
        splitController.content.chat.showFindBar()
    }

    @objc func stopTurn(_ sender: Any?) {
        guard let id = selectedThreadID else { return }
        ThreadRunner.shared.stop(threadID: id)
    }

    @objc func previousThread(_ sender: Any?) {
        stepThread(by: -1)
    }

    @objc func nextThread(_ sender: Any?) {
        stepThread(by: 1)
    }

    private func stepThread(by offset: Int) {
        let ids = sidebar.visibleThreadIDs
        guard !ids.isEmpty else { return }
        guard let current = selectedThreadID, let index = ids.firstIndex(of: current) else {
            open(offset > 0 ? ids.first : ids.last)
            return
        }
        let next = index + offset
        guard ids.indices.contains(next) else { return }
        open(ids[next])
    }

    /// Command-1 … Command-9: the nth thread in the sidebar, as in T3.
    @objc func jumpToThread(_ sender: NSMenuItem) {
        let ids = sidebar.visibleThreadIDs
        let index = sender.tag - 1
        guard ids.indices.contains(index) else { return }
        open(ids[index])
    }

    @objc func showModelPicker(_ sender: Any?) {
        splitController.content.chat.showComposerPicker(.model)
    }

    @objc func showEffortPicker(_ sender: Any?) {
        splitController.content.chat.showComposerPicker(.effort)
    }

    @objc func showAccessPicker(_ sender: Any?) {
        splitController.content.chat.showComposerPicker(.access)
    }

    @objc func togglePlanMode(_ sender: Any?) {
        guard let thread = selectedThread else { return }
        store.updateThread(thread.id) { $0.interactionMode = thread.interactionMode == .plan ? .build : .plan }
    }

    @objc func renameThread(_ sender: Any?) {
        guard let id = selectedThreadID else { return }
        if !splitController.isSidebarOpen { splitController.toggleSidebarPanel() }
        sidebar.beginRename(threadID: id)
    }

    @objc func togglePinThread(_ sender: Any?) {
        guard let id = selectedThreadID else { return }
        ThreadActions.togglePin(id)
    }

    @objc func toggleArchiveThread(_ sender: Any?) {
        guard let id = selectedThreadID else { return }
        ThreadActions.toggleArchived(id)
    }

    @objc func deleteThread(_ sender: Any?) {
        guard let id = selectedThreadID else { return }
        ThreadActions.delete(id, in: window)
    }

    @objc func copyThreadPath(_ sender: Any?) {
        guard let id = selectedThreadID, let folder = ThreadActions.folder(for: id) else { return }
        NSPasteboard.general.setText(folder.path)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let folder = openFolder else { return }
        ThreadActions.reveal(folder)
    }

    /// The folder "Open in" acts on: the open thread's worktree or project, else the current project.
    /// Nil when that folder was moved or deleted.
    var openFolder: URL? {
        let folder: URL?
        if let id = selectedThreadID, let threadFolder = ThreadActions.folder(for: id) {
            folder = threadFolder
        } else {
            folder = currentProjectID.flatMap { store.project($0)?.url }
        }
        return folder.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    @objc func openInPreferred(_ sender: Any?) {
        guard let folder = openFolder, let target = OpenTargets.preferred else { return }
        OpenTargets.open(folder, with: target)
    }

    @objc func openInApp(_ sender: NSMenuItem) {
        guard let folder = openFolder, let id = sender.representedObject as? String,
            let target = OpenTargets.target(withBundleID: id)
        else { return }
        OpenTargets.open(folder, with: target)
    }

    @objc func increaseFontSize(_ sender: Any?) {
        changeFontSize(by: 1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        changeFontSize(by: -1)
    }

    @objc func resetFontSize(_ sender: Any?) {
        store.updateSettings { $0.fontSize = AppSettings().fontSize }
    }

    private func changeFontSize(by delta: Double) {
        let size = min(24, max(10, store.settings.fontSize + delta))
        guard size != store.settings.fontSize else { return }
        store.updateSettings { $0.fontSize = size }
    }

    // MARK: NSWindowDelegate

    /// Zoom (the green button with Option, Window › Zoom, or double-clicking the title bar) fills the screen's visible
    /// area. Without this AppKit picks a width of its own and only the height fills.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        newFrame
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame()
    }

    func windowWillClose(_ notification: Notification) {
        saveLayout()
        CommandPaletteController.shared.dismiss()
    }

    /// Remembers the window frame and panel sizes.
    func saveLayout() {
        saveFrame()
        splitController.saveLayout()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let id = selectedThreadID { ThreadActivity.shared.markSeen(id) }
    }

    private func saveFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frameDescriptor
        UIState.shared.update { $0.windowFrame = frame }
    }
}

// MARK: - Menu validation

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let thread = selectedThread
        switch menuItem.action {
        case #selector(toggleSidebarPanel(_:)):
            menuItem.title = splitController.isSidebarOpen ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")
        case #selector(toggleTerminalPanel(_:)):
            menuItem.title =
                splitController.content.isTerminalOpen ? String(localized: "Hide Terminal") : String(localized: "Show Terminal")
        case #selector(toggleDiffPanel(_:)):
            menuItem.title = splitController.isDiffOpen ? String(localized: "Hide Diff") : String(localized: "Show Diff")
        case #selector(togglePreviewPanel(_:)):
            menuItem.title = splitController.isPreviewOpen ? String(localized: "Hide Browser Preview") : String(localized: "Show Browser Preview")
        case #selector(togglePullRequestsPanel(_:)):
            menuItem.title =
                splitController.isPullRequestsOpen
                ? String(localized: "Hide Pull Requests") : String(localized: "Show Pull Requests")
        case #selector(stopTurn(_:)):
            return thread.map { ThreadRunner.shared.isRunning($0.id) } ?? false
        case #selector(previousThread(_:)), #selector(nextThread(_:)):
            return !sidebar.visibleThreadIDs.isEmpty
        case #selector(jumpToThread(_:)):
            return window?.isKeyWindow == true && sidebar.visibleThreadIDs.count >= menuItem.tag
        case #selector(togglePinThread(_:)):
            menuItem.title = thread?.isPinned == true ? String(localized: "Unpin Thread") : String(localized: "Pin Thread")
            return thread != nil
        case #selector(toggleArchiveThread(_:)):
            menuItem.title =
                thread?.isArchived == true ? String(localized: "Unarchive Thread") : String(localized: "Archive Thread")
            return thread.map { ThreadActions.canArchive($0.id) } ?? false
        case #selector(renameThread(_:)), #selector(deleteThread(_:)), #selector(copyThreadPath(_:)):
            return thread != nil
        case #selector(showModelPicker(_:)):
            return window?.isVisible == true && splitController.content.chat.canShowComposerPicker(.model)
        case #selector(showEffortPicker(_:)):
            return window?.isVisible == true && splitController.content.chat.canShowComposerPicker(.effort)
        case #selector(showAccessPicker(_:)):
            return window?.isVisible == true && splitController.content.chat.canShowComposerPicker(.access)
        case #selector(togglePlanMode(_:)):
            menuItem.state = thread?.interactionMode == .plan ? .on : .off
            return thread != nil
        case #selector(openInPreferred(_:)):
            let target = OpenTargets.preferred
            menuItem.title = target.map { String(localized: "Open in \($0.name)") } ?? String(localized: "Open in Editor")
            return openFolder != nil && target != nil
        case #selector(openInApp(_:)), #selector(revealInFinder(_:)):
            return openFolder != nil
        case #selector(decreaseFontSize(_:)):
            return store.settings.fontSize > 10
        case #selector(increaseFontSize(_:)):
            return store.settings.fontSize < 24
        case #selector(performTextFinderAction(_:)):
            return window?.isVisible == true && splitController.content.chat.validateUserInterfaceItem(menuItem)
        default:
            break
        }
        return true
    }
}
