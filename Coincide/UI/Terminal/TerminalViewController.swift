import AppKit
import CoincideKit

/// The integrated terminal of the selected thread: a slim header with the thread's terminal tabs and
/// the active tab's panes. Every thread keeps its shells running while another thread is shown, until
/// the thread is deleted or the app quits.
final class TerminalViewController: NSViewController {
    var threadID: UUID? {
        didSet {
            guard threadID != oldValue, isViewLoaded else { return }
            let refocus = terminalHasFocus
            showThread()
            if refocus { focusActiveTerminal() }
        }
    }

    private let header = TerminalHeaderView()
    private let body = NSView()
    private let emptyState = TerminalEmptyStateView()
    private var terminals: ThreadTerminals?
    private weak var shownContent: NSView?
    private var shownTabCount = 0
    private var storeToken: ObservationToken?
    private var isShown = false
    private var windowJustChanged = false
    private var visibilityCheckScheduled = false

    override func loadView() {
        let root = TerminalContainerView()
        root.onVisibilityChange = { [weak self] windowChanged in
            guard let self else { return }
            if windowChanged { self.windowJustChanged = true }
            self.scheduleVisibilityCheck()
        }
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(String(localized: "Terminal"))

        header.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        emptyState.frame = body.bounds
        emptyState.autoresizingMask = [.width, .height]
        emptyState.onNewTerminal = { [weak self] in self?.newTerminal() }
        body.addSubview(emptyState)
        root.addSubview(header)
        root.addSubview(body)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: TerminalHeaderView.height),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        header.onSelectTab = { [weak self] id in self?.selectTab(id) }
        header.onCloseTab = { [weak self] id in self?.closeTab(id) }
        header.onNewTab = { [weak self] in self?.newTerminal() }
        header.onSplit = { [weak self] layout in self?.split(layout) }
        header.onHide = { AppEvents.post(.coincideToggleTerminal) }

        view = root
        storeToken = AppStore.shared.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .threadList, .projects:
                // The thread may have been deleted, or its project folder moved.
                self.reloadTabs()
            case .thread(let id) where id == self.threadID:
                self.updateDirectory()
            default:
                break
            }
        }
        showThread()
    }

    /// Focuses the active terminal, starting one when the thread has none.
    func focus() {
        if terminals?.tabs.isEmpty == true {
            newTerminal()
        } else {
            focusActiveTerminal()
        }
    }

    // MARK: Showing a thread

    private func showThread() {
        terminals?.onChange = nil
        terminals = threadID.map { TerminalSessionManager.shared.terminals(for: $0) }
        terminals?.onChange = { [weak self] change in self?.terminalsChanged(change) }
        reloadTabs()
    }

    private func terminalsChanged(_ change: ThreadTerminals.Change) {
        guard let terminals else { return }
        switch change {
        case .tabs:
            let hadTabs = shownTabCount > 0
            reloadTabs()
            // As in T3 Code, closing the last terminal closes the panel. It collapses in place: the window's
            // toggle action would also bring back a window that was closed or minimized, as when a shell
            // exits by itself.
            if hadTabs, terminals.tabs.isEmpty, isShown, canCreateTerminals,
                let drawer = parent as? ChatTerminalSplitViewController, drawer.isTerminalOpen
            {
                drawer.toggleTerminal()
            }
        case .session(let session):
            if let tab = terminals.tab(containing: session) { header.updateTab(headerTab(for: tab)) }
            if session === terminals.activeSession { updateDirectory() }
        }
    }

    private func reloadTabs() {
        let tabs = terminals?.tabs ?? []
        shownTabCount = tabs.count
        for session in tabs.flatMap(\.sessions) { connect(session) }
        header.setTabs(
            tabs.map(headerTab(for:)), activeID: terminals?.activeTab?.id, canSplit: terminals?.canSplit ?? false,
            hasThread: canCreateTerminals)
        showActiveTab()
        updateDirectory()
    }

    private func showActiveTab() {
        guard let tab = terminals?.activeTab else {
            shownContent?.removeFromSuperview()
            shownContent = nil
            updateEmptyState()
            emptyState.isHidden = false
            return
        }
        tab.contentView.show(tab.sessions.map(\.paneView), layout: tab.layout)
        if shownContent !== tab.contentView {
            shownContent?.removeFromSuperview()
            tab.contentView.frame = body.bounds
            tab.contentView.autoresizingMask = [.width, .height]
            body.addSubview(tab.contentView)
            shownContent = tab.contentView
        }
        emptyState.isHidden = true
    }

    private func headerTab(for tab: TerminalTab) -> TerminalHeaderView.Tab {
        let title = tab.activeSession?.title ?? ""
        let symbol: String
        if tab.sessions.count == 1 {
            symbol = "terminal"
        } else {
            symbol = tab.layout == .sideBySide ? "rectangle.split.2x1" : "rectangle.split.1x2"
        }
        let toolTip = tab.sessions.map { session in
            "\(session.title) — \((session.directory.path as NSString).abbreviatingWithTildeInPath)"
        }.joined(separator: "\n")
        var hasExited = false
        if case .exited = tab.activeSession?.state { hasExited = true }
        return TerminalHeaderView.Tab(id: tab.id, title: title, symbolName: symbol, toolTip: toolTip, hasExited: hasExited)
    }

    /// The active terminal's directory, or where a new one would start.
    private func updateDirectory() {
        if let session = terminals?.activeSession {
            header.setDirectory(session.directory)
        } else if let threadID, canCreateTerminals {
            header.setDirectory(TerminalLaunch.directory(for: threadID).url)
        } else {
            header.setDirectory(nil)
        }
    }

    private func updateEmptyState() {
        emptyState.configure(canCreate: canCreateTerminals)
    }

    private var canCreateTerminals: Bool {
        guard let threadID else { return false }
        return AppStore.shared.hasThread(threadID)
    }

    /// Routes a session's focus, shortcuts and context menu to this controller while it is shown here.
    private func connect(_ session: TerminalSession) {
        let terminal = session.terminalView
        terminal.onFocus = { [weak self, weak session] in
            guard let self, let session else { return }
            self.terminals?.activate(session)
        }
        terminal.onCommand = { [weak self, weak session] command in
            guard let self, let session else { return }
            self.perform(command, from: session)
        }
        terminal.contextMenu = { [weak self, weak session] in
            guard let self, let session else { return nil }
            return self.contextMenu(for: session)
        }
    }

    // MARK: Actions

    private func perform(_ command: TerminalCommand, from session: TerminalSession) {
        switch command {
        case .newTab:
            newTerminal()
        case .split(let layout):
            split(layout)
        case .close:
            close([session])
        case .selectTab(let offset):
            terminals?.selectTab(offset: offset)
            focusActiveTerminal()
        case .focusPane(let offset):
            guard let tab = terminals?.tab(containing: session), tab.sessions.count > 1,
                let index = tab.sessions.firstIndex(where: { $0 === session })
            else { return }
            let next = tab.sessions[(index + offset + tab.sessions.count) % tab.sessions.count]
            view.window?.makeFirstResponder(next.terminalView)
        }
    }

    private func newTerminal() {
        guard canCreateTerminals, let terminals else { return }
        terminals.addTab()
        focusActiveTerminal()
    }

    private func split(_ layout: TerminalTab.Layout) {
        guard canCreateTerminals, let terminals else { return }
        guard terminals.split(layout) != nil else {
            NSSound.beep()
            return
        }
        focusActiveTerminal()
    }

    private func selectTab(_ id: UUID) {
        guard let tab = terminals?.tabs.first(where: { $0.id == id }) else { return }
        terminals?.activate(tab)
        focusActiveTerminal()
    }

    private func closeTab(_ id: UUID) {
        guard let terminals, let tab = terminals.tabs.first(where: { $0.id == id }) else { return }
        confirmClosing(tab.sessions) { [weak self, weak terminals] in
            let refocus = self?.terminalHasFocus ?? false
            terminals?.close(tab)
            if refocus { self?.focusActiveTerminal() }
        }
    }

    private func close(_ sessions: [TerminalSession]) {
        guard let terminals, !sessions.isEmpty else { return }
        confirmClosing(sessions) { [weak self, weak terminals] in
            let refocus = self?.terminalHasFocus ?? false
            for session in sessions { terminals?.close(session) }
            if refocus { self?.focusActiveTerminal() }
        }
    }

    /// Asks before stopping a running job, as Terminal does; idle shells close right away.
    private func confirmClosing(_ sessions: [TerminalSession], then close: @escaping () -> Void) {
        let busy = sessions.filter(\.isBusy)
        guard !busy.isEmpty, let window = view.window, window.attachedSheet == nil else {
            close()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if busy.count == 1 {
            alert.messageText = String(localized: "Close this terminal?")
            alert.informativeText = String(
                localized: "“\(busy[0].title)” is still running. Closing the terminal stops it.")
        } else {
            let names = ListFormatter.localizedString(byJoining: busy.map { "“\($0.title)”" })
            alert.messageText = String(localized: "Close these terminals?")
            alert.informativeText = String(localized: "\(names) are still running. Closing the terminals stops them.")
        }
        alert.addButton(withTitle: String(localized: "Close")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { close() }
        }
    }

    // MARK: Context menu

    private func contextMenu(for session: TerminalSession) -> NSMenu {
        let terminal = session.terminalView
        // The menu acts on the pane that was clicked, so it becomes the focused one.
        terminal.window?.makeFirstResponder(terminal)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let running = session.state == .running
        menu.addItem(
            item(String(localized: "Copy"), #selector(ShellTerminalView.copy(_:)), "c", target: terminal,
                enabled: terminal.selectionActive))
        menu.addItem(item(String(localized: "Paste"), #selector(ShellTerminalView.paste(_:)), "v", target: terminal, enabled: running))
        menu.addItem(item(String(localized: "Select All"), #selector(ShellTerminalView.selectAll(_:)), "a", target: terminal))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Clear"), #selector(clearTerminal(_:)), "k", session: session))
        if terminal.isScrolledUp {
            menu.addItem(item(String(localized: "Jump to Bottom"), #selector(scrollTerminalToBottom(_:)), "", session: session))
        }
        menu.addItem(.separator())
        let canSplit = terminals?.canSplit ?? false
        menu.addItem(item(String(localized: "New Terminal"), #selector(newTerminalTab(_:)), "t"))
        menu.addItem(item(String(localized: "Split Right"), #selector(splitTerminalRight(_:)), "d", enabled: canSplit))
        menu.addItem(item(String(localized: "Split Down"), #selector(splitTerminalDown(_:)), "D", enabled: canSplit))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Close Terminal"), #selector(closeTerminal(_:)), "w", session: session))
        return menu
    }

    private func item(
        _ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil, session: TerminalSession? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        item.representedObject = session
        item.isEnabled = enabled
        return item
    }

    @objc private func clearTerminal(_ sender: NSMenuItem) {
        (sender.representedObject as? TerminalSession)?.terminalView.clear()
    }

    @objc private func scrollTerminalToBottom(_ sender: NSMenuItem) {
        (sender.representedObject as? TerminalSession)?.terminalView.scrollToBottom()
    }

    @objc private func newTerminalTab(_ sender: Any?) {
        newTerminal()
    }

    @objc private func splitTerminalRight(_ sender: Any?) {
        split(.sideBySide)
    }

    @objc private func splitTerminalDown(_ sender: Any?) {
        split(.stacked)
    }

    @objc private func closeTerminal(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession else { return }
        close([session])
    }

    // MARK: Focus and visibility

    private var terminalHasFocus: Bool {
        guard isViewLoaded, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    private func focusActiveTerminal() {
        guard let terminal = terminals?.activeSession?.terminalView, let window = view.window, terminal.window === window else {
            return
        }
        window.makeFirstResponder(terminal)
    }

    /// Visibility settles after the split view finishes collapsing or expanding the panel.
    private func scheduleVisibilityCheck() {
        guard !visibilityCheckScheduled else { return }
        visibilityCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.visibilityCheckScheduled = false
            self.updateVisibility()
        }
    }

    private func updateVisibility() {
        let visible = (view as? TerminalContainerView)?.isShowingContent ?? false
        // Showing up with the window (at launch) must not take focus from the composer.
        let opened = !windowJustChanged
        windowJustChanged = false
        guard visible != isShown else { return }
        isShown = visible
        if visible {
            if terminals?.tabs.isEmpty == true, canCreateTerminals {
                terminals?.addTab()
            }
            if opened { focusActiveTerminal() }
        } else if terminalHasFocus {
            AppEvents.post(.coincideFocusComposer)
        }
    }
}

/// The controller's root view. It reports when it joins or leaves a window, is hidden or shown, or
/// collapses to nothing, which is how the panel's visibility is tracked.
private final class TerminalContainerView: NSView {
    var onVisibilityChange: ((_ windowChanged: Bool) -> Void)?

    var isShowingContent: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor && bounds.width > 1 && bounds.height > TerminalHeaderView.height
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = TerminalTheme.background.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onVisibilityChange?(true)
    }

    override func viewDidHide() {
        super.viewDidHide()
        onVisibilityChange?(false)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onVisibilityChange?(false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let wasShowing = isShowingContent
        super.setFrameSize(newSize)
        if isShowingContent != wasShowing { onVisibilityChange?(false) }
    }
}

/// Shown when the thread has no terminal yet, or no thread is selected.
private final class TerminalEmptyStateView: NSView {
    var onNewTerminal: (() -> Void)?

    private let message = NSTextField(wrappingLabelWithString: "")
    private let newButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView(image: Theme.symbol("apple.terminal", size: 28, weight: .light) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        icon.setAccessibilityElement(false)
        message.font = Theme.bodyFont
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        newButton.title = String(localized: "New Terminal")
        newButton.bezelStyle = .push
        newButton.target = self
        newButton.action = #selector(newTerminal)
        newButton.toolTip = String(localized: "New Terminal (⌘T)")

        let stack = NSStackView(views: [icon, message, newButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(14, after: message)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(canCreate: Bool) {
        message.stringValue =
            canCreate
            ? String(localized: "No terminal sessions for this thread yet.")
            : String(localized: "Select a thread to open a terminal.")
        newButton.isHidden = !canCreate
    }

    @objc private func newTerminal() {
        onNewTerminal?()
    }
}
