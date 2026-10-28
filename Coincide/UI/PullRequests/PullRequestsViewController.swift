import AppKit
import CoincideKit

/// The pull request workspace in the inspector, ported from T3 Code's pull requests panel: the open pull requests of
/// the open thread's repository, filtered to all of them, the user's own or those waiting on their review, and one
/// pull request's description and checks with its actions. It shares the inspector with the diff, so a pull request
/// sits beside the conversation it is discussed in, and the rail switches between the two.
final class PullRequestsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var threadID: UUID? {
        didSet {
            guard threadID != oldValue else { return }
            // A thread of the same project shares its repository, so an open pull request stays open: checking one
            // out opens its new thread with the pull request still showing.
            if project(of: oldValue) != project(of: threadID) {
                closeDetail()
                pullRequests = []
                tableView.reloadData()
                banner.dismiss()
            }
            reload()
        }
    }

    private let store = AppStore.shared
    private let service = PullRequestService.shared

    private let header = NSStackView()
    private let filterButton = ThemedPopUpButton(frame: .zero, pullsDown: true)
    private let countLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private lazy var backButton = PanelIconButton(
        symbol: "chevron.left", label: String(localized: "All Pull Requests"), target: self, action: #selector(back(_:)))
    private lazy var browserButton = PanelIconButton(
        symbol: "safari", label: String(localized: "Open in Browser"), target: self, action: #selector(openShownInBrowser(_:)))
    private lazy var refreshButton = PanelIconButton(
        symbol: "arrow.clockwise", label: String(localized: "Refresh"), target: self, action: #selector(refresh(_:)))
    private let tableView = PullRequestTableView()
    private let scrollView = NSScrollView()
    private let emptyState = DiffEmptyStateView(frame: .zero)
    private let detailView = PullRequestDetailView(frame: .zero)
    private let banner = GitResultBanner(frame: .zero)

    private static let filterKey = "PullRequestFilter"
    private var filter: PullRequestFilter {
        get { UserDefaults.standard.string(forKey: Self.filterKey).flatMap(PullRequestFilter.init(rawValue:)) ?? .open }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.filterKey) }
    }

    private var pullRequests: [PullRequestSummary] = []
    /// The pull request open in the detail, and its details once loaded.
    private var shown: PullRequestSummary?
    private var detail: PullRequestDetail?
    private var detailLoadedAt: Date?
    /// An action (merge, ready, check out) is running; the detail's buttons wait for it.
    private var isBusy = false
    private var loadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var generation = 0
    /// Loads running, for the spinner.
    private var activity = 0
    private var needsReload = false
    private var observation: ObservationToken?
    private var fontSize: CGFloat = 0

    // MARK: View

    override func loadView() {
        let root = SolidBackgroundView(color: Theme.contentBackground)
        root.setAccessibilityLabel(String(localized: "Pull Requests"))

        filterButton.controlSize = .regular
        filterButton.isBordered = false
        filterButton.setAccessibilityLabel(String(localized: "Pull requests to show"))
        filterButton.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: Theme.fontSize - 1, weight: .regular)
        detailLabel.font = .systemFont(ofSize: Theme.fontSize, weight: .semibold)
        detailLabel.textColor = Theme.ink
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        header.setViews(
            [backButton, filterButton, countLabel, detailLabel, NSView(), spinner, browserButton, refreshButton], in: .leading)
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        header.setHuggingPriority(.init(1), for: .horizontal)
        let divider = ThemedDivider(frame: .zero)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pullRequest"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.onActivate = { [weak self] in self?.openSelected() }
        tableView.setAccessibilityLabel(String(localized: "Pull requests"))
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        tableView.menu = rowMenu
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 60, right: 0)

        detailView.onMerge = { [weak self] anchor in self?.chooseMergeMethod(from: anchor) }
        detailView.onMarkReady = { [weak self] in self?.markReady() }
        detailView.onCheckOut = { [weak self] in self?.checkOutShown() }
        detailView.onReview = { [weak self] in self?.reviewShown() }
        detailView.isHidden = true
        emptyState.isHidden = true

        for view in [header, divider, scrollView, detailView, emptyState, banner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: safe.topAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            detailView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            detailView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -20),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            banner.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
        ])
        view = root
        rebuildFilterMenu()
        updateHeader()

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification,
            object: nil)
        // The rows and the detail follow the text size setting, as the transcript and the diff do.
        fontSize = Theme.fontSize
        observation = store.observe { [weak self] change in
            guard let self, case .settings = change, self.fontSize != Theme.fontSize else { return }
            self.fontSize = Theme.fontSize
            self.tableView.reloadData()
            if let shown = self.shown { self.detailView.show(shown, detail: self.detail, isBusy: self.isBusy) }
        }
    }

    /// Escape goes back from a pull request to the list.
    override func cancelOperation(_ sender: Any?) {
        guard shown != nil else { return }
        back(sender)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The inspector may still be animating open; its view is hidden until then.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.needsReload || self.loadTask == nil else { return }
            self.reload()
        }
    }

    private var isVisible: Bool { isViewLoaded && view.window != nil && !view.isHiddenOrHasHiddenAncestor }

    /// Coming back to the app picks up what changed on GitHub meanwhile, at most every thirty seconds (the list's
    /// cache), so switching apps doesn't run `gh` each time.
    @objc private func applicationDidBecomeActive() {
        guard isVisible else { return }
        reload()
    }

    private func project(of threadID: UUID?) -> UUID? {
        threadID.flatMap { store.summary($0)?.projectID }
    }

    private var folder: URL? { threadID.flatMap(store.workingDirectory(for:)) }

    // MARK: Loading

    @objc private func refresh(_ sender: Any?) {
        reload(force: true)
    }

    /// Reads the list for the current filter, showing the last one read at once. With `force` the list is read
    /// again even when it is recent. An open pull request's details are read again with it.
    private func reload(force: Bool = false) {
        guard isViewLoaded, isVisible else {
            needsReload = true
            return
        }
        needsReload = false
        generation += 1
        let generation = generation
        loadTask?.cancel()
        guard let threadID, let cwd = store.workingDirectory(for: threadID) else {
            showState(symbol: "arrow.triangle.pull", title: String(localized: "No Thread Selected"),
                text: String(localized: "Select a thread to see its repository’s pull requests."))
            return
        }
        guard FileManager.default.fileExists(atPath: cwd.path) else {
            showState(symbol: "folder.badge.minus", title: String(localized: "Folder Not Found"), text: cwd.path)
            return
        }
        let filter = filter
        if let cached = service.cachedPullRequests(filter, in: cwd) { showList(cached) }
        // Checks finish without the list changing, so an open pull request is read again too, as often as the list.
        if shown != nil, force || detailLoadedAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true { loadDetail() }
        beginActivity()
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.generation { self.loadTask = nil } }
            let availability = await service.availability(cwd)
            guard generation == self.generation else { return endActivity() }
            guard availability == .ready else {
                endActivity()
                showUnavailable(availability)
                return
            }
            do {
                let list = try await service.pullRequests(filter, in: cwd, maxAge: force ? 0 : 30)
                guard generation == self.generation else { return endActivity() }
                showList(list)
            } catch {
                guard generation == self.generation else { return endActivity() }
                if service.cachedPullRequests(filter, in: cwd) == nil {
                    showState(
                        symbol: "exclamationmark.triangle", title: String(localized: "Couldn’t Load the Pull Requests"),
                        text: Self.describe(error), button: String(localized: "Try Again")
                    ) { [weak self] in self?.reload(force: true) }
                } else {
                    report(error)
                }
            }
            endActivity()
        }
    }

    private func beginActivity() {
        activity += 1
        spinner.startAnimation(nil)
    }

    private func endActivity() {
        activity = max(0, activity - 1)
        if activity == 0 { spinner.stopAnimation(nil) }
    }

    private func showUnavailable(_ availability: PullRequestService.Availability) {
        switch availability {
        case .ready:
            break
        case .notRepository:
            showState(
                symbol: "externaldrive.connected.to.line.below", title: String(localized: "Not a Git Repository"),
                text: String(localized: "Pull requests need a Git repository on GitHub."))
        case .noRemote:
            showState(
                symbol: "icloud.slash", title: String(localized: "No Remote"),
                text: String(localized: "Push this repository to GitHub to see its pull requests here."))
        case .unsupportedHost(let host):
            showState(
                symbol: "arrow.triangle.pull", title: String(localized: "Pull Requests Need GitHub"),
                text: String(localized: "This repository is on \(host). Coincide lists pull requests from GitHub."))
        case .needsGitHubCLI:
            showState(
                symbol: "terminal", title: String(localized: "GitHub CLI Needed"), text: PullRequestService.setupMessage)
        }
    }

    /// Shows a message in place of the list. An open pull request closes, since there is nothing behind it.
    private func showState(
        symbol: String, title: String, text: String, button: String? = nil, action: (() -> Void)? = nil
    ) {
        closeDetail()
        pullRequests = []
        tableView.reloadData()
        countLabel.stringValue = ""
        emptyState.show(symbol: symbol, title: title, text: text, button: button, action: action)
        emptyState.isHidden = false
        scrollView.isHidden = true
    }

    private func showList(_ list: [PullRequestSummary]) {
        let selected = tableView.selectedRow >= 0 && tableView.selectedRow < pullRequests.count
            ? pullRequests[tableView.selectedRow].number : nil
        pullRequests = list
        tableView.reloadData()
        if let selected, let row = list.firstIndex(where: { $0.number == selected }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        countLabel.stringValue = list.isEmpty ? "" : "\(list.count)"
        scrollView.isHidden = shown != nil
        if list.isEmpty {
            let (title, text): (String, String) =
                switch filter {
                case .open: (String(localized: "No Open Pull Requests"), String(localized: "Open pull requests of this repository show here."))
                case .mine: (String(localized: "No Pull Requests of Yours"), String(localized: "Pull requests you open in this repository show here."))
                case .reviewRequested:
                    (String(localized: "No Reviews Requested"), String(localized: "Pull requests waiting on your review show here."))
                }
            emptyState.show(symbol: filter.symbolName, title: title, text: text)
        }
        emptyState.isHidden = !list.isEmpty || shown != nil
    }

    // MARK: Filter

    private func rebuildFilterMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: filter.title, action: nil, keyEquivalent: "")
        for option in PullRequestFilter.allCases {
            let item = menu.addItem(withTitle: option.title, action: #selector(selectFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == filter ? .on : .off
            item.image = Theme.symbol(option.symbolName)
        }
        filterButton.menu = menu
        filterButton.setTitle(filter.title)
    }

    @objc private func selectFilter(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = PullRequestFilter(rawValue: raw), option != filter
        else { return }
        filter = option
        rebuildFilterMenu()
        pullRequests = []
        tableView.reloadData()
        reload()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { pullRequests.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { PullRequestRowCell.height }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ThemedTableRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell =
            tableView.makeView(withIdentifier: PullRequestRowCell.identifier, owner: nil) as? PullRequestRowCell
            ?? PullRequestRowCell()
        let pullRequest = pullRequests[row]
        cell.show(pullRequest)
        cell.onPress = { [weak self] in self?.open(pullRequest) }
        return cell
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard pullRequests.indices.contains(row) else { return }
        open(pullRequests[row])
    }

    private func openSelected() {
        let row = tableView.selectedRow
        guard pullRequests.indices.contains(row) else { return }
        open(pullRequests[row])
    }

    /// The row's context menu, filled for the row clicked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard pullRequests.indices.contains(row) else { return }
        let pullRequest = pullRequests[row]
        func add(_ title: String, symbol: String, _ handler: @escaping () -> Void) {
            let action = PullRequestMenuAction(handler)
            let item = menu.addItem(withTitle: title, action: #selector(PullRequestMenuAction.run(_:)), keyEquivalent: "")
            item.target = action
            item.representedObject = action
            item.image = Theme.symbol(symbol)
        }
        add(String(localized: "Open in Browser"), symbol: "safari") { [weak self] in self?.openInBrowser(pullRequest) }
        add(String(localized: "Copy Link"), symbol: "link") { NSPasteboard.general.setText(pullRequest.url) }
        add(String(localized: "Mention in Message"), symbol: "number") { AppEvents.mentionPullRequest(pullRequest) }
        menu.addItem(.separator())
        add(String(localized: "Check Out in New Thread"), symbol: "arrow.triangle.branch") { [weak self] in
            self?.checkOut(pullRequest)
        }
    }

    // MARK: Detail

    private func open(_ pullRequest: PullRequestSummary) {
        shown = pullRequest
        detail = nil
        banner.dismiss()
        scrollView.isHidden = true
        emptyState.isHidden = true
        detailView.isHidden = false
        detailView.show(pullRequest, detail: nil, isBusy: isBusy)
        updateHeader()
        loadDetail()
    }

    @objc private func back(_ sender: Any?) {
        closeDetail()
        showList(pullRequests)
        view.window?.makeFirstResponder(tableView)
    }

    private func closeDetail() {
        detailTask?.cancel()
        detailTask = nil
        guard shown != nil else { return }
        shown = nil
        detail = nil
        detailLoadedAt = nil
        detailView.isHidden = true
        scrollView.isHidden = false
        updateHeader()
    }

    /// Reads the open pull request's description, checks and mergeability.
    private func loadDetail() {
        guard let shown, let cwd = folder else { return }
        detailTask?.cancel()
        let number = shown.number
        detailLoadedAt = Date()
        beginActivity()
        detailTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<PullRequestDetail, Error>
            do {
                result = .success(try await service.pullRequest(number, in: cwd))
            } catch {
                result = .failure(error)
            }
            endActivity()
            guard !Task.isCancelled, self.shown?.number == number else { return }
            switch result {
            case .success(let loaded):
                detail = loaded
                self.shown = loaded.summary
            case .failure(let error):
                report(error)
            }
            updateHeader()
            detailView.show(self.shown ?? shown, detail: detail, isBusy: isBusy)
        }
    }

    private func updateHeader() {
        let inDetail = shown != nil
        backButton.isHidden = !inDetail
        detailLabel.isHidden = !inDetail
        browserButton.isHidden = !inDetail
        filterButton.isHidden = inDetail
        countLabel.isHidden = inDetail
        detailLabel.stringValue = shown.map { "#\($0.number)" } ?? ""
        detailLabel.toolTip = shown?.title
    }

    @objc private func openShownInBrowser(_ sender: Any?) {
        guard let shown else { return }
        openInBrowser(shown)
    }

    private func openInBrowser(_ pullRequest: PullRequestSummary) {
        guard let url = URL(string: pullRequest.url) else { return NSSound.beep() }
        ChangeRequestLinks.openChangeRequest(url, from: view.window)
    }

    // MARK: Actions

    /// Offers the merge methods the repository allows, as GitHub's merge button does.
    private func chooseMergeMethod(from anchor: NSView) {
        guard let shown, let detail, detail.canMerge, let cwd = folder else { return }
        Task { [weak self] in
            guard let methods = await self?.service.mergeMethods(in: cwd), self?.shown?.number == shown.number,
                self?.folder == cwd, anchor.window != nil
            else { return }
            let menu = NSMenu()
            for method in methods {
                let action = PullRequestMenuAction { [weak self] in self?.confirmMerge(detail, method: method, in: cwd) }
                let item = menu.addItem(
                    withTitle: method.title, action: #selector(PullRequestMenuAction.run(_:)), keyEquivalent: "")
                item.target = action
                item.representedObject = action
            }
            ThemedPopup.show(menu: menu, from: anchor, preferAbove: false)
        }
    }

    private func confirmMerge(_ detail: PullRequestDetail, method: PullRequestMergeMethod, in cwd: URL) {
        guard let window = view.window else { return }
        let pullRequest = detail.summary
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = method.question(pullRequest.number)
        alert.informativeText = String(
            localized: "“\(pullRequest.title)” is merged into \(pullRequest.baseBranch) on GitHub. Its branch is kept.")
        alert.addButton(withTitle: String(localized: "Merge"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.run(String(localized: "Merged pull request #\(pullRequest.number).")) {
                try await self.service.merge(detail, method: method, in: cwd)
            }
        }
    }

    private func reviewShown() {
        guard let detail, let cwd = folder, !isBusy else { return }
        let sheet = PullRequestReviewSheet(number: detail.summary.number)
        sheet.onSubmit = { [weak self] event, body in
            guard let self else { return }
            self.setBusy(true)
            defer { self.setBusy(false) }
            try await self.service.review(detail, event: event, body: body, in: cwd)
            self.banner.show(title: String(localized: "Review submitted."), detail: nil, isError: false)
            self.reload(force: true)
        }
        presentAsSheet(sheet)
    }

    private func markReady() {
        guard let shown, let cwd = folder else { return }
        run(String(localized: "Pull request #\(shown.number) is ready for review.")) {
            try await self.service.markReady(shown.number, in: cwd)
        }
    }

    /// Runs one action on GitHub, then reports it and reads the list and the open pull request again.
    private func run(_ success: String, _ action: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        setBusy(true)
        Task {
            do {
                try await action()
                banner.show(title: success, detail: nil, isError: false)
            } catch {
                report(error)
            }
            setBusy(false)
            reload(force: true)
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy { beginActivity() } else { endActivity() }
        if let shown { detailView.show(shown, detail: detail, isBusy: busy) }
    }

    private func checkOutShown() {
        guard let shown else { return }
        checkOut(shown)
    }

    /// Checks the pull request out in a worktree of its own and opens a new thread there (T3 Code's "Checkout pull
    /// request" in a new worktree).
    private func checkOut(_ pullRequest: PullRequestSummary) {
        guard !isBusy, let threadID, let summary = store.summary(threadID), let project = store.project(summary.projectID)
        else { return }
        let prefix = store.settings.worktreeBranchPrefix
        setBusy(true)
        Task {
            do {
                let worktree = try await service.prepareWorktree(for: pullRequest, in: project.url, branchPrefix: prefix)
                ThreadActions.newThread(in: project.id, worktreePath: worktree.path, branch: worktree.branch)
                if worktree.reused {
                    banner.show(
                        title: String(localized: "Opened a thread in the worktree that has #\(pullRequest.number) checked out."),
                        detail: Formatting.abbreviatedPath(worktree.path), isError: false)
                }
            } catch {
                report(error)
            }
            setBusy(false)
        }
    }

    private func report(_ error: Error) {
        let gitError = error as? GitError
        banner.show(title: gitError?.message ?? error.localizedDescription, detail: gitError?.detail, isError: true)
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? GitError else { return error.localizedDescription }
        return [error.message, error.detail].compactMap(\.self).joined(separator: "\n")
    }
}

/// A menu item target that runs a closure; the item keeps it alive as its represented object.
private final class PullRequestMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run(_ sender: NSMenuItem) { handler() }
}
