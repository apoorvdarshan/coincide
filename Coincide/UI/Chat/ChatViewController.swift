import AppKit
import CoincideKit
import QuickLookUI

/// A thread's timeline above its composer.
///
/// The transcript follows T3 Code's chat view: user bubbles, Markdown replies with the provider and
/// model that wrote them, tool calls folded into a work log per turn, approvals, plans, errors and
/// each turn's changed files. It updates incrementally from store changes, follows new output while
/// the reader is at the bottom, and offers "Jump to Latest" otherwise.
final class ChatViewController: NSViewController {
    var threadID: UUID? {
        didSet {
            guard threadID != oldValue else { return }
            if let oldValue, oldValue == displayedThreadID { scrollStates[oldValue] = list.scrollState() }
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
        let button = NSButton(title: String(localized: "Jump to Latest"), target: self, action: #selector(jumpToLatest))
        button.bezelStyle = .glass
        button.borderShape = .capsule
        button.controlSize = .regular
        button.image = Theme.symbol("arrow.down", size: 11, weight: .semibold)
        button.imagePosition = .imageLeading
        button.toolTip = String(localized: "Scroll to the newest messages")
        return button
    }()

    private var observation: ObservationToken?
    private var displayedThreadID: UUID?
    private var itemsByID: [UUID: TranscriptItem] = [:]
    private var revisions: [UUID: Int] = [:]
    private var expanded: [UUID: Set<TranscriptRowID>] = [:]
    private var scrollStates: [UUID: TranscriptScrollState] = [:]
    /// Input on waiting question and approval cards, by item.
    private var inputDrafts: [UUID: TranscriptInputDraft] = [:]
    private var changedFileSignatures: [UUID: Int] = [:]
    private var pendingItemIDs = Set<UUID>()
    private var needsFullReload = false
    private var updateScheduled = false
    private var lastUpdate = Date.distantPast
    /// How long the last transcript update took.
    private var updateCost: TimeInterval = 0
    private var liveTimer: Timer?
    private var wasRunning = false
    private var appliedFontSize = 0.0
    private var appliedShowReasoning = true
    private var previewURLs: [URL] = []
    private var previewIndex = 0

    /// Streaming deltas arrive faster than anyone reads; apply them at most this often.
    private static let updateInterval: TimeInterval = 1.0 / 30
    private static let slowestUpdateInterval: TimeInterval = 0.25

    // MARK: View

    override func loadView() {
        let root = NSView()
        view = root
        list.host = self
        list.onPinnedChange = { [weak self] pinned in self?.setJumpButtonVisible(!pinned) }
        let tableView = list.tableView
        tableView.onToggleRow = { [weak self] row, expand in self?.toggleRow(at: row, expand: expand) }
        tableView.onCopyRow = { [weak self] row in self?.copyRow(at: row) }
        tableView.onEscape = { [weak self] in self?.composer.focus() }
        tableView.onTypeAhead = { [weak self] event in self?.typeIntoComposer(event) }
        tableView.menu = rowMenu()

        addChild(composer)
        for subview in [list.scrollView, welcomeView, composerContainer, jumpButton, noThreadView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        let composerView = composer.view
        composerView.translatesAutoresizingMaskIntoConstraints = false
        composerContainer.addSubview(composerView)
        let collapsedComposer = composerContainer.heightAnchor.constraint(equalToConstant: 0)
        collapsedComposer.priority = .defaultLow
        NSLayoutConstraint.activate([
            list.scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            list.scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.scrollView.bottomAnchor.constraint(equalTo: composerContainer.topAnchor),

            welcomeView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            welcomeView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            welcomeView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            welcomeView.bottomAnchor.constraint(equalTo: composerContainer.topAnchor),

            composerContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            composerContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            composerContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            collapsedComposer,
            composerView.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            composerView.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor),
            composerView.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor),
            composerView.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor),

            jumpButton.centerXAnchor.constraint(equalTo: list.scrollView.centerXAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: composerContainer.topAnchor, constant: -12),

            noThreadView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            noThreadView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            noThreadView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            noThreadView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        jumpButton.isHidden = true
        jumpButton.alphaValue = 0
        appliedFontSize = store.settings.fontSize
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

    // MARK: Thread

    private func loadThread() {
        guard isViewLoaded else { return }
        composer.threadID = threadID
        pendingItemIDs.removeAll()
        needsFullReload = false
        revisions.removeAll()
        changedFileSignatures.removeAll()
        guard let threadID, store.thread(threadID) != nil else {
            displayedThreadID = nil
            itemsByID.removeAll()
            textCache.removeAll()
            list.update([], reload: true)
            updateChrome()
            updateLiveTimer()
            return
        }
        displayedThreadID = threadID
        wasRunning = runner.isRunning(threadID)
        refreshChangedFiles()
        rebuild(reload: true)
        textCache.retain(only: Set(itemsByID.keys))
        list.restore(scrollStates[threadID])
        updateChrome()
        updateLiveTimer()
    }

    private func rebuild(reload: Bool = false, keeping anchor: TranscriptRowID? = nil) {
        guard let threadID, let thread = store.thread(threadID) else { return }
        itemsByID = Dictionary(thread.items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        // Drafts of this thread's cards that no longer wait are done; other threads keep theirs.
        inputDrafts = inputDrafts.filter { id, _ in itemsByID[id].map { $0.status == .waiting } ?? true }
        let turn = runner.turn(threadID)
        var builder = TranscriptBuilder(items: thread.items)
        builder.runningTurnID = runner.isRunning(threadID) ? turn?.userItemID : nil
        builder.turnStartedAt = turn?.startedAt
        builder.isStarting = runner.isStarting(threadID)
        builder.runningProvider = turn?.provider ?? thread.selection.provider
        builder.showReasoning = store.settings.showReasoning
        builder.expanded = expanded[threadID] ?? []
        builder.revisions = revisions
        builder.changedFiles = changedFileSignatures
        list.update(builder.build(), reload: reload, keeping: anchor)
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
        if isEmpty { welcomeView.update(thread: thread, project: store.project(thread.projectID), registry: registry) }
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
            }
            scheduleUpdate()
        case .runState(let id):
            guard id == displayedThreadID else { return }
            runStateChanged()
        case .thread(let id):
            guard id == displayedThreadID else { return }
            updateChrome()
        case .threadList, .projects:
            if let threadID, store.thread(threadID) == nil {
                scrollStates[threadID] = nil
                expanded[threadID] = nil
                self.threadID = nil
            } else if displayedThreadID == nil {
                updateChrome()
            }
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
        for id in pendingItemIDs { revisions[id, default: 0] += 1 }
        pendingItemIDs.removeAll()
        needsFullReload = false
        rebuild(reload: reload)
        if reload { list.scrollToBottom() }
        updateChrome()
    }

    private func runStateChanged() {
        guard let threadID = displayedThreadID else { return }
        let running = runner.isRunning(threadID)
        if wasRunning && !running, let last = store.thread(threadID)?.items.last(where: { $0.kind == .user }) {
            watchCheckpoints(for: last.id)
        }
        wasRunning = running
        rebuild()
        list.reconfigureVisibleCells()
        updateChrome()
        updateLiveTimer()
    }

    private func settingsChanged() {
        let settings = store.settings
        guard settings.fontSize != appliedFontSize || settings.showReasoning != appliedShowReasoning else { return }
        appliedFontSize = settings.fontSize
        appliedShowReasoning = settings.showReasoning
        textCache.removeAll()
        list.invalidateHeights()
        rebuild(reload: true)
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
        return menu
    }

    @objc private func copyClickedRow(_ sender: NSMenuItem) {
        copyRow(at: sender.tag)
    }

    @objc private func editClickedRow(_ sender: NSMenuItem) {
        guard let id = list.rows[safe: sender.tag]?.itemID else { return }
        editMessage(id)
    }

    @objc private func revertClickedRow(_ sender: NSMenuItem) {
        guard let id = list.rows[safe: sender.tag]?.itemID else { return }
        revertTurn(id)
    }

    @objc private func toggleClickedRow(_ sender: NSMenuItem) {
        toggleRow(at: sender.tag, expand: nil)
    }

    // MARK: Rewind

    private func confirm(title: String, message: String, action: String, isDestructive: Bool, then perform: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let confirm = alert.addButton(withTitle: action)
        confirm.hasDestructiveAction = isDestructive
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else {
            if alert.runModal() == .alertFirstButtonReturn { perform() }
            return
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { perform() }
        }
    }

    /// Removes the conversation from `item` on and hands its text back to the composer.
    private func rewind(to item: TranscriptItem) {
        guard let threadID = displayedThreadID else { return }
        store.truncate(threadID, from: item.id)
        composer.setDraft(item.text, imagePaths: item.attachments ?? [])
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
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
        if case .item(let itemID) = id { revisions[itemID, default: 0] += 1 }
        rebuild(keeping: id)
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func editMessage(_ itemID: UUID) {
        guard let threadID = displayedThreadID, let item = itemsByID[itemID], item.kind == .user, !runner.isRunning(threadID) else {
            NSSound.beep()
            return
        }
        confirm(
            title: String(localized: "Edit this message?"),
            message: String(
                localized: "The conversation from this message on is removed so you can change it and send it again. Files on disk are not changed."),
            action: String(localized: "Edit Message"), isDestructive: false
        ) { [weak self] in
            self?.rewind(to: item)
        }
    }

    func revertTurn(_ itemID: UUID) {
        guard let threadID = displayedThreadID, let item = itemsByID[itemID], !runner.isRunning(threadID),
            CheckpointService.shared.canRestore(threadID: threadID, userItemID: itemID)
        else {
            NSSound.beep()
            return
        }
        confirm(
            title: String(localized: "Revert to before this message?"),
            message: String(
                localized: "Files go back to how they were before this turn, and the conversation from this message on is removed. The message returns to the composer."
            ),
            action: String(localized: "Revert"), isDestructive: true
        ) { [weak self] in
            Task { @MainActor [weak self] in
                do {
                    try await CheckpointService.shared.restore(threadID: threadID, toBefore: itemID)
                    guard let self, self.displayedThreadID == threadID else { return }
                    self.rewind(to: item)
                } catch {
                    self?.present(error)
                }
            }
        }
    }

    func canRevert(_ itemID: UUID) -> Bool {
        guard let threadID = displayedThreadID else { return false }
        return CheckpointService.shared.canRestore(threadID: threadID, userItemID: itemID)
    }

    func respond(to itemID: UUID, optionID: String, text: String?) {
        guard let threadID = displayedThreadID else { return }
        runner.respond(threadID: threadID, itemID: itemID, optionID: optionID, text: text)
        inputDrafts[itemID] = nil
    }

    func answer(_ itemID: UUID, answers: [String: [String]]) {
        guard let threadID = displayedThreadID else { return }
        runner.answer(threadID: threadID, itemID: itemID, answers: answers)
        inputDrafts[itemID] = nil
    }

    func dismissQuestion(_ itemID: UUID) {
        guard let threadID = displayedThreadID else { return }
        runner.dismissQuestion(threadID: threadID, itemID: itemID)
        inputDrafts[itemID] = nil
    }

    func inputDraft(for itemID: UUID) -> TranscriptInputDraft {
        if let draft = inputDrafts[itemID] { return draft }
        let draft = TranscriptInputDraft()
        inputDrafts[itemID] = draft
        return draft
    }

    func showDiff(turnID: UUID, path: String?) {
        guard let threadID = displayedThreadID else { return }
        AppEvents.showTurnDiff(threadID: threadID, turnID: turnID, path: path)
    }

    func openLink(_ link: Any) -> Bool {
        if let url = link as? URL {
            if url.isFileURL { return openFile(url.path) }
            return NSWorkspace.shared.open(url)
        }
        guard let text = link as? String, !text.isEmpty else { return false }
        if text.hasPrefix("#") { return true }
        if text.hasPrefix("www."), let url = URL(string: "https://" + text) { return NSWorkspace.shared.open(url) }
        return openFile(text)
    }

    /// Opens a path from a reply, relative to the thread's folder; `file.swift:12` and `#L12` suffixes are ignored.
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
        NSWorkspace.shared.open(url)
        return true
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
        guard let modelID = meta.modelID, !modelID.isEmpty, modelID != "default" else { return meta.provider.displayName }
        let model = registry.displayName(for: ModelSelection(provider: meta.provider, modelID: modelID))
        return "\(meta.provider.displayName) · \(model)"
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
        if case .user = row.kind, let id = row.itemID {
            let running = isThreadRunning
            add(String(localized: "Copy Message"), #selector(copyClickedRow(_:)))
            add(String(localized: "Edit and Resend…"), #selector(editClickedRow(_:)))
            menu.items.last?.isEnabled = !running
            if canRevert(id) {
                add(String(localized: "Revert to Before This Message…"), #selector(revertClickedRow(_:)))
                menu.items.last?.isEnabled = !running
            }
            return
        }
        if row.isExpandable {
            add(isExpanded(row.id) ? String(localized: "Collapse") : String(localized: "Expand"), #selector(toggleClickedRow(_:)))
        }
        add(String(localized: "Copy"), #selector(copyClickedRow(_:)))
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
