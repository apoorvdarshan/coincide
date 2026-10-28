import AppKit
import CoincideKit

/// The strip under the composer (T3 Code's branch toolbar): where the thread runs and on which branch.
///
/// Before the first message the thread can stay in the project's checkout or move to a new worktree
/// (started from a branch picked here). Threads in the project's checkout can switch or create
/// branches; otherwise the branch is shown read-only.
final class BranchToolbarView: NSView {
    var threadID: UUID? {
        didSet {
            guard threadID != oldValue else { return }
            status = nil
            statusFolder = nil
            wasRunning = threadID.map(runner.isRunning) ?? false
            render()
            scheduleRefresh(after: 0)
        }
    }

    private let store = AppStore.shared
    private let git = GitService.shared
    private let worktrees = WorktreeService.shared
    private let runner = ThreadRunner.shared
    private let workspaceButton = ComposerControlButton(frame: .zero)
    private let branchButton = ComposerControlButton(frame: .zero)
    private let spinner = NSProgressIndicator()
    private var status: GitStatus?
    /// The folder `status` was read from.
    private var statusFolder: URL?
    private var observation: ObservationToken?
    private var refreshTask: Task<Void, Never>?
    private weak var branchPopup: ThemedPopup?
    /// Whether the thread's turn was running at the last run-state change.
    private var wasRunning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        branchButton.target = self
        branchButton.action = #selector(showBranchPicker)
        let row = NSStackView(views: [workspaceButton, spinner, NSView(), branchButton])
        row.spacing = 4
        row.setHuggingPriority(.init(1), for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)

        observation = store.observe { [weak self] change in
            guard let self, let threadID = self.threadID else { return }
            switch change {
            case .thread(threadID):
                // Sent for drafts and titles too; git only needs another look when the folder changed.
                self.render()
                if self.cwd != self.statusFolder { self.scheduleRefresh() }
            case .runState(threadID):
                self.render()
                // Also sent for every token-usage update while a turn runs. Git only needs another look when a
                // turn starts or ends.
                let running = self.runner.isRunning(threadID)
                if running != self.wasRunning {
                    self.wasRunning = running
                    self.scheduleRefresh()
                }
            case .items(threadID, _, true):
                self.render()
            case .projects:
                if self.cwd != self.statusFolder { self.scheduleRefresh() }
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
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { scheduleRefresh(after: 0) }
    }

    private var thread: ChatThread? { threadID.flatMap(store.thread) }

    // MARK: Refresh

    @objc private func repositoryChanged(_ notification: Notification) {
        guard let path = notification.userInfo?["path"] as? String, let root = status?.rootPath ?? cwd?.path else { return }
        let changed = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if changed.hasPrefix(root) || root.hasPrefix(changed) { scheduleRefresh() }
    }

    @objc private func applicationDidBecomeActive() { scheduleRefresh() }

    private var cwd: URL? { threadID.flatMap(store.workingDirectory(for:)) }

    private func scheduleRefresh(after delay: Double = 0.2) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        guard window != nil, let threadID, let cwd else {
            render()
            return
        }
        let status = (try? await git.status(cwd)) ?? .notRepository
        guard !Task.isCancelled, threadID == self.threadID else { return }
        self.status = status
        statusFolder = cwd
        // Until it starts, a thread in the project's checkout is on whatever branch the folder is on.
        if let branch = status.branch, let thread, thread.worktreePath == nil, !thread.hasUserMessages,
            thread.branch != branch
        {
            store.updateThread(threadID) { $0.branch = branch }
        }
        render()
    }

    // MARK: Display

    private func render() {
        guard let threadID, let thread, let status, status.isRepository else {
            isHidden = true
            return
        }
        isHidden = false
        let started = thread.hasUserMessages
        let preparing = worktrees.isPreparing(threadID)
        let busy = preparing || runner.isRunning(threadID)
        let newWorktreeBase = started ? nil : worktrees.baseBranch(for: threadID)

        if preparing {
            spinner.startAnimation(nil)
            workspaceButton.configure(title: String(localized: "Preparing worktree…"), symbolName: "folder.badge.plus", chevron: false)
            workspaceButton.menuProvider = nil
            workspaceButton.isEnabled = false
        } else {
            spinner.stopAnimation(nil)
            let title: String
            let symbol: String
            if thread.worktreePath == nil {
                title = started ? String(localized: "Local checkout") : String(localized: "Current checkout")
                symbol = "folder"
            } else if newWorktreeBase != nil {
                title = String(localized: "New worktree")
                symbol = "folder.badge.plus"
            } else {
                title = started ? String(localized: "Worktree") : String(localized: "Current worktree")
                symbol = "square.stack.3d.up"
            }
            workspaceButton.configure(title: title, symbolName: symbol, chevron: true)
            workspaceButton.menuProvider = { [weak self] in self?.workspaceMenu() }
            workspaceButton.isEnabled = true
        }
        workspaceButton.toolTip = cwd?.path
        workspaceButton.setAccessibilityLabel(String(localized: "Workspace: \(workspaceButton.attributedTitle.string)"))

        let current = status.branch
        if let newWorktreeBase {
            branchButton.configure(title: String(localized: "From \(newWorktreeBase)"), symbolName: "arrow.triangle.branch", chevron: true)
            branchButton.toolTip = String(localized: "The branch the new worktree starts from")
            branchButton.isEnabled = !busy
        } else if thread.worktreePath == nil {
            let mismatch = started && thread.branch != nil && current != nil && thread.branch != current
            branchButton.configure(
                title: current ?? String(localized: "Detached HEAD"),
                symbolName: mismatch ? "exclamationmark.triangle" : "arrow.triangle.branch",
                symbolTint: mismatch ? .systemOrange : nil, chevron: true)
            branchButton.toolTip =
                mismatch
                ? String(localized: "This thread started on \(thread.branch ?? ""); the folder is now on \(current ?? "").")
                : String(localized: "Switch or create a branch")
            branchButton.isEnabled = !busy
        } else {
            branchButton.configure(
                title: current ?? thread.branch ?? String(localized: "Detached HEAD"), symbolName: "arrow.triangle.branch",
                chevron: false)
            branchButton.toolTip = thread.worktreePath
            branchButton.isEnabled = true
        }
        branchButton.setAccessibilityLabel(String(localized: "Branch: \(branchButton.attributedTitle.string)"))
    }

    // MARK: Workspace

    private func workspaceMenu() -> NSMenu? {
        guard let threadID, let thread else { return nil }
        let menu = NSMenu()
        if !thread.hasUserMessages {
            let local = menu.addItem(
                withTitle: String(localized: "Current Checkout"), action: #selector(useCheckout), keyEquivalent: "")
            local.target = self
            local.image = Theme.symbol("folder")
            local.state = thread.worktreePath == nil ? .on : .off
            let worktree = menu.addItem(
                withTitle: String(localized: "New Worktree"), action: #selector(useNewWorktree), keyEquivalent: "")
            worktree.target = self
            worktree.image = Theme.symbol("folder.badge.plus")
            worktree.state = worktrees.baseBranch(for: threadID) != nil ? .on : .off
            if let previous = worktrees.previousWorktree(for: threadID) {
                let title =
                    previous.branch.map { String(localized: "Previous Worktree (\($0))") }
                    ?? String(localized: "Previous Worktree")
                let item = menu.addItem(withTitle: title, action: #selector(usePreviousWorktree), keyEquivalent: "")
                item.target = self
                item.image = Theme.symbol("square.stack.3d.up")
                item.toolTip = previous.path
                item.state = thread.worktreePath == previous.path ? .on : .off
            }
            menu.addItem(.separator())
        }
        if let cwd {
            let reveal = menu.addItem(withTitle: String(localized: "Reveal in Finder"), action: #selector(revealFolder), keyEquivalent: "")
            reveal.target = self
            let copy = menu.addItem(withTitle: String(localized: "Copy Path"), action: #selector(copyFolderPath), keyEquivalent: "")
            copy.target = self
            copy.representedObject = cwd.path
        }
        return menu
    }

    @objc private func useCheckout() {
        guard let threadID else { return }
        Task { await worktrees.useProjectCheckout(threadID: threadID) }
    }

    @objc private func useNewWorktree() {
        guard let threadID, worktrees.baseBranch(for: threadID) == nil else { return }
        Task { await run { try await self.worktrees.useNewWorktree(threadID: threadID, baseBranch: nil) } }
    }

    @objc private func usePreviousWorktree() {
        guard let threadID, let previous = worktrees.previousWorktree(for: threadID) else { return }
        Task { await worktrees.useExistingWorktree(threadID: threadID, path: previous.path, branch: previous.branch) }
    }

    @objc private func revealFolder() {
        guard let cwd else { return }
        NSWorkspace.shared.activateFileViewerSelecting([cwd])
    }

    @objc private func copyFolderPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.setText(path)
    }

    // MARK: Branches

    @objc private func showBranchPicker() {
        guard let threadID, let thread, let cwd, branchPopup == nil else { return }
        let base = thread.hasUserMessages ? nil : worktrees.baseBranch(for: threadID)
        guard base != nil || thread.worktreePath == nil else { return }
        let mode: BranchPickerController.Mode = base != nil ? .base : .checkout
        // A new worktree's base comes from the project's branches, not the worktree's.
        let folder = base != nil ? store.project(thread.projectID)?.url ?? cwd : cwd
        let picker = BranchPickerController(mode: mode, cwd: folder, selected: base ?? status?.branch)
        picker.onPick = { [weak self] pick in
            Task { await self?.handle(pick, mode: mode, threadID: threadID, cwd: cwd) }
        }
        branchPopup = ThemedPopup.show(picker, from: branchButton)
    }

    private func handle(_ pick: BranchPickerController.Pick, mode: BranchPickerController.Mode, threadID: UUID, cwd: URL)
        async
    {
        switch (mode, pick) {
        case (.base, .branch(let branch)):
            await run { try await self.worktrees.useNewWorktree(threadID: threadID, baseBranch: branch.name) }
        case (.base, .create):
            break
        case (.checkout, .branch(let branch)):
            if let path = branch.worktreePath, !branch.isCurrent {
                // Git checks a branch out in one folder at a time; before the first message the
                // thread can move to that folder instead.
                if store.summary(threadID)?.hasUserMessages == false {
                    await worktrees.useExistingWorktree(threadID: threadID, path: path, branch: branch.name)
                } else {
                    present(
                        GitError(
                            String(localized: "“\(branch.name)” is checked out in another worktree."),
                            detail: String(localized: "Git can check a branch out in only one folder at a time: \(path)")))
                }
                return
            }
            await run {
                let checkedOut = try await self.git.checkout(branch.name, in: cwd)
                self.store.updateThread(threadID) { $0.branch = checkedOut }
            }
        case (.checkout, .create(let name)):
            await run {
                let created = try await self.git.createBranch(name, in: cwd)
                self.store.updateThread(threadID) { $0.branch = created }
            }
        }
        scheduleRefresh(after: 0)
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        guard let window else { return }
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = error.localizedDescription
        if let detail = (error as? GitError)?.detail { alert.informativeText = detail }
        alert.beginSheetModal(for: window)
    }
}

