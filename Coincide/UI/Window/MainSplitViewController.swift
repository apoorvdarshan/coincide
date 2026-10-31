import AppKit
import CoincideKit

/// Thread list | chat over a collapsible terminal | inspector (the diff, the pull requests or the browser preview),
/// right of the navigation rail (`MainRootViewController`). Panel sizes and visibility are remembered in `UIState`; the
/// inspector's, open or closed and on which panel, for each thread (`InspectorFollow`).
///
/// Settings › General can put the terminal in the inspector instead, as a fourth panel (`TerminalPlacement`). Switching
/// moves the same terminal controller, with its running shells, between the two places (`setTerminalPlacement`).
///
/// The inspector keeps a share of the space right of the thread list rather than a width (`InspectorWidth`): a
/// constraint holds it at that multiple of the chat's width, above the split items' holding priorities, so resizing,
/// zooming, full screen and hiding the thread list all keep the proportion while the thread list keeps its width.
/// The user changes the share with `InspectorDividerHandle`, which sits over the divider.
final class MainSplitViewController: NSSplitViewController {
    let sidebar = SidebarViewController()
    let content = ChatTerminalSplitViewController()
    let diff = DiffViewController()
    let pullRequests = PullRequestsViewController()
    let preview = PreviewViewController()
    let schedules = SchedulesPanelController()
    private(set) lazy var inspector = InspectorViewController(
        diff: diff, pullRequests: pullRequests, preview: preview, schedules: schedules)
    let dividerHandle = InspectorDividerHandle()

    private let state: UIState
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var observations: [NSKeyValueObservation] = []
    private var hasRestoredLayout = false
    /// Holds the inspector at its share while it is open.
    private var proportion: NSLayoutConstraint?
    /// The share in use: the saved one, or the drag's while the user drags. Nil is the default.
    private(set) var inspectorFraction: Double?
    /// The inspector's width when it last closed: the split view opens it at that width again.
    private var closedInspectorWidth: CGFloat?
    /// The open thread, whose panel the inspector remembers (`notePanel`).
    private(set) var threadID: UUID?

    var isSidebarOpen: Bool { !sidebarItem.isCollapsed }
    var isInspectorOpen: Bool { !inspectorItem.isCollapsed }
    var isDiffOpen: Bool { !inspectorItem.isCollapsed && inspector.panel == .diff }
    var isPullRequestsOpen: Bool { !inspectorItem.isCollapsed && inspector.panel == .pullRequests }
    var isPreviewOpen: Bool { !inspectorItem.isCollapsed && inspector.panel == .preview }
    var isSchedulesOpen: Bool { !inspectorItem.isCollapsed && inspector.panel == .schedules }
    /// Where the terminal opens: in the drawer below the chat or in the inspector.
    private(set) var terminalPlacement: TerminalPlacement
    /// Whether the terminal shows, wherever it is.
    var isTerminalOpen: Bool {
        switch terminalPlacement {
        case .bottom: content.isTerminalOpen
        case .right: !inspectorItem.isCollapsed && inspector.panel == .terminal
        }
    }
    /// Called after the sidebar, terminal or diff opens or closes, so the toolbar and menus can follow.
    var onPanelsChanged: (() -> Void)?

    private static let defaultSidebarWidth: CGFloat = 288
    // How the columns give way, weakest first. All of it sits below the split view's divider drags (490) and the
    // window's own size (500), so both still move everything, and above what the views inside ask for: the composer
    // prefers its full width at 270 (`ComposerViewController.fullWidthPriority`), over the hugging of its controls.
    /// The chat and the inspector hold their widths: a window resize falls on them, shared out by `proportion`.
    static let contentHoldingPriority = NSLayoutConstraint.Priority(280)
    /// The inspector's share of the space right of the thread list: beats the holds above, so the share wins when the
    /// window or the thread list changes size, and gives way to the items' minimums, the panel's first.
    static let proportionPriority = NSLayoutConstraint.Priority(300)
    /// The thread list keeps its width over the share: opening the panel or resizing the window doesn't move it.
    static let sidebarHoldingPriority = NSLayoutConstraint.Priority(320)
    static let proportionIdentifier = "Coincide.inspectorProportion"

    init(state: UIState = .shared, terminalPlacement: TerminalPlacement = AppStore.shared.settings.terminalPlacement) {
        self.state = state
        self.terminalPlacement = terminalPlacement
        inspectorFraction = state.values.inspectorFraction
        super.init(nibName: nil, bundle: nil)
        // Before the drawer loads, so a terminal on the right never starts out in it.
        content.hostsTerminal = terminalPlacement == .bottom
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        let values = state.values
        preview.isPresented = values.isInspectorOpen && values.inspectorPanel == .preview
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = Self.sidebarHoldingPriority
        sidebarItem.isCollapsed = values.isSidebarCollapsed

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = CGFloat(InspectorWidth.minimumChatWidth)
        contentItem.holdingPriority = Self.contentHoldingPriority

        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = CGFloat(InspectorWidth.minimumPanelWidth)
        inspectorItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        inspectorItem.holdingPriority = Self.contentHoldingPriority
        inspectorItem.canCollapse = true
        if terminalPlacement == .right {
            inspector.attachTerminal(content.terminal, select: values.inspectorPanel == .terminal)
        }
        inspectorItem.isCollapsed = !values.isInspectorOpen

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
        super.viewDidLoad()
        content.onTerminalToggled = { [weak self] in self?.onPanelsChanged?() }
        // As in T3 Code, closing the last terminal closes the panel, wherever it is.
        content.terminal.onLastTerminalClosed = { [weak self] in
            guard let self, self.isTerminalOpen else { return }
            self.toggleTerminalPanel()
        }
        // Closing the browser's last tab closes the browser the same way.
        preview.onLastTabClosed = { [weak self] in self?.hidePreviewPanel() }
        installDividerHandle()
        if !inspectorItem.isCollapsed { holdProportion() }

        // The toolbar's sidebar button toggles the item directly, so follow the item itself.
        observations = [
            sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                let collapsed = item.isCollapsed
                MainActor.assumeIsolated {
                    self?.state.update { $0.isSidebarCollapsed = collapsed }
                    self?.onPanelsChanged?()
                }
            },
            inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                let collapsed = item.isCollapsed
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if collapsed { self.releaseProportion() }
                    self.preview.isPresented = !collapsed && self.inspector.panel == .preview
                    self.dividerHandle.isHidden = collapsed
                    self.state.update { $0.isInspectorOpen = !collapsed }
                    self.onPanelsChanged?()
                }
            },
        ]
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasRestoredLayout else { return }
        hasRestoredLayout = true
        // Positions are set once the window has its real size, so they are not scaled away.
        if !sidebarItem.isCollapsed {
            splitView.setPosition(state.values.listWidth.map { CGFloat($0) } ?? Self.defaultSidebarWidth, ofDividerAt: 0)
        }
    }

    func toggleSidebarPanel() {
        if !sidebarItem.isCollapsed { saveLayout() }
        setCollapsed(sidebarItem, !sidebarItem.isCollapsed)
    }

    /// Opens the inspector on the diff.
    func showDiffPanel() {
        showInspector(.diff)
    }

    func toggleDiffPanel() {
        toggleInspector(.diff)
    }

    func togglePreviewPanel() {
        toggleInspector(.preview)
        // Like a new tab, an empty browser opens with the cursor in its address field, once the panel has joined the window.
        guard isPreviewOpen else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPreviewOpen else { return }
            self.preview.focusAddressIfBlank()
        }
    }

    /// Opens the inspector on the browser preview, leaving it open if it already shows it.
    func showPreviewPanel() { showInspector(.preview) }

    /// Hides the browser only if it is the inspector's visible panel; other panels are left alone.
    func hidePreviewPanel() {
        guard isPreviewOpen else { return }
        closeInspector()
        notePanel(nil)
    }

    func togglePullRequestsPanel() {
        toggleInspector(.pullRequests)
    }

    /// Opens or closes the Scheduled panel, which stays open across threads. It opens on the open thread's schedules
    /// when it has any (`SchedulesPanelController.prepareToShow`).
    func toggleSchedulesPanel() {
        if !isSchedulesOpen { schedules.prepareToShow() }
        toggleInspector(.schedules)
        guard isSchedulesOpen else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isSchedulesOpen else { return }
            self.schedules.focusSearch()
        }
    }

    func showSchedulesPanel() {
        if !isSchedulesOpen { schedules.prepareToShow() }
        showInspector(.schedules)
    }

    /// Opens or closes the terminal: its drawer below the chat, or its panel in the inspector, which another panel's
    /// button switches away from like a tab. Opening it focuses its terminal, so typing and ⌘T or ⌘W reach it at once.
    func toggleTerminalPanel() {
        switch terminalPlacement {
        case .bottom: content.toggleTerminal()
        case .right: toggleInspector(.terminal)
        }
        // Asked for here rather than left to the panel noticing it shows: in either place the terminal joins the window
        // as it opens (a collapsed drawer's view is out of it), which the panel takes for the window appearing with
        // it, when focus stays with the composer. Once it shows, it starts a terminal if the thread has none.
        guard isTerminalOpen else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isTerminalOpen else { return }
            self.content.terminal.focus()
        }
    }

    /// Moves the terminal between the drawer below the chat and the inspector, taking the same controller, and so the
    /// thread's running shells, along: nothing restarts. An open terminal stays open in its new place and a closed one
    /// stays closed; the inspector's other panels are left as they were.
    func setTerminalPlacement(_ placement: TerminalPlacement) {
        guard placement != terminalPlacement else { return }
        guard isViewLoaded else {
            terminalPlacement = placement
            content.hostsTerminal = placement == .bottom
            return
        }
        let wasOpen = isTerminalOpen
        let hadFocus = (view.window?.firstResponder as? NSView)?.isDescendant(of: content.terminal.view) ?? false
        terminalPlacement = placement
        switch placement {
        case .right:
            content.detachTerminal()
            inspector.attachTerminal(content.terminal, select: false)
            if wasOpen { showInspector(.terminal) }
        case .bottom:
            if wasOpen {
                // In place: the panel is about to leave the column, so there is nothing to animate.
                closeInspector(animated: false)
                notePanel(nil)
            }
            inspector.detachTerminal()
            content.attachTerminal(open: wasOpen)
        }
        onPanelsChanged?()
        if hadFocus { content.terminal.focus() }
    }

    /// Closes the inspector when it shows `panel`, otherwise shows `panel` in it, opening it if it is closed: the
    /// toolbar's diff, pull request, preview and (on the right) terminal buttons (`InspectorPanelButtons`) work like
    /// tabs of one column.
    private func toggleInspector(_ panel: UIState.InspectorPanel) {
        if !inspectorItem.isCollapsed, inspector.panel == panel {
            closeInspector()
            notePanel(nil)
        } else {
            showInspector(panel)
        }
    }

    private func showInspector(_ panel: UIState.InspectorPanel) {
        preview.isPresented = panel == .preview && !inspectorItem.isCollapsed
        notePanel(panel)
        if inspector.panel != panel {
            inspector.show(panel)
            onPanelsChanged?()
        }
        guard inspectorItem.isCollapsed else { return }
        openInspector()
    }

    // MARK: Following the thread

    /// Remembers the open thread's panel (nil: closed) after the user, or an agent in front of them, opens, closes or
    /// switches the inspector, so the column comes back that way with the thread (`followThread`).
    private func notePanel(_ panel: UIState.InspectorPanel?) {
        // The window-wide panel isn't a thread's: showing or closing it leaves what the thread remembers.
        guard let threadID, panel?.isWindowWide != true, !(panel == nil && inspector.panel.isWindowWide) else { return }
        let key = threadID.uuidString
        guard state.values.threadPanels[key] != panel else { return }
        state.update { $0.threadPanels[key] = panel }
    }

    /// Opens, closes or switches the inspector for the thread just opened (`InspectorFollow`). In place, so changing
    /// threads never slides the column in or out, and at the share, so the panel comes back as wide as it was.
    private func followThread() {
        let change = InspectorFollow.change(
            isOpen: !inspectorItem.isCollapsed, panel: inspector.panel,
            saved: threadID.flatMap { state.values.threadPanels[$0.uuidString] }, available: inspector.panels)
        switch change {
        case .none:
            break
        case .show(let panel):
            if inspector.panel != panel {
                inspector.show(panel)
                onPanelsChanged?()
            }
            guard inspectorItem.isCollapsed else { break }
            if hasRestoredLayout {
                openInspector(animated: false)
            } else {
                // At launch, before the window's first layout: as `viewDidLoad` opens a saved inspector. The chat's
                // width isn't real yet, so measuring it would widen the window for nothing.
                inspectorItem.isCollapsed = false
                holdProportion()
            }
        case .close:
            closeInspector(animated: false)
        }
        preview.isPresented = isPreviewOpen
    }

    /// Opens the inspector at its share. The thread list keeps its width: the space comes from the chat, and from the
    /// window when the chat and the panel would not both get their minimums.
    private func openInspector(animated: Bool = true) {
        // Closed, the inspector leaves the chat everything right of the thread list.
        let available = Double(content.view.frame.width - splitView.dividerThickness)
        growWindow(by: CGFloat(InspectorWidth.shortfall(available: available)))
        let target = InspectorWidth.panelWidth(fraction: inspectorFraction, available: available)
        // The split view animates back to the width the inspector closed at. When that is still its width, let it
        // animate and hold the share afterwards; otherwise (a first opening, the window resized meanwhile) open it in
        // place at the share, rather than animate to one width and then jump to another.
        if animated, let closedInspectorWidth, abs(Double(closedInspectorWidth) - target) < 1, showsPanelChanges {
            NSAnimationContext.runAnimationGroup { _ in
                self.inspectorItem.animator().isCollapsed = false
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.inspectorItem.isCollapsed else { return }
                    self.holdProportion()
                }
            }
        } else {
            inspectorItem.isCollapsed = false
            holdProportion()
            view.layoutSubtreeIfNeeded()
        }
    }

    private func closeInspector(animated: Bool = true) {
        preview.isPresented = false
        closedInspectorWidth = inspector.view.frame.width
        releaseProportion()
        if animated {
            setCollapsed(inspectorItem, true)
        } else {
            inspectorItem.isCollapsed = true
        }
    }

    /// Widens the window (on its screen, keeping it there) so the chat and the inspector both fit. Full screen stays.
    private func growWindow(by shortfall: CGFloat) {
        guard shortfall > 0, let window = view.window, !window.styleMask.contains(.fullScreen) else { return }
        var frame = window.frame
        frame.size.width += ceil(shortfall)
        if let visible = window.screen?.visibleFrame, frame.maxX > visible.maxX {
            frame.origin.x = max(visible.minX, visible.maxX - frame.width)
        }
        window.setFrame(frame, display: true)
    }

    // MARK: Inspector width

    /// Holds the open inspector at the current share of the space right of the thread list.
    private func holdProportion() {
        proportion?.isActive = false
        let constraint = inspector.view.widthAnchor.constraint(
            equalTo: content.view.widthAnchor, multiplier: CGFloat(InspectorWidth.ratio(for: inspectorFraction)))
        constraint.priority = Self.proportionPriority
        constraint.identifier = Self.proportionIdentifier
        constraint.isActive = true
        proportion = constraint
    }

    /// Lets go of the share before the inspector closes, so the closed inspector doesn't pull the chat to nothing.
    private func releaseProportion() {
        proportion?.isActive = false
        proportion = nil
    }

    /// The space right of the thread list that the chat and the open inspector share.
    private var availableWidth: Double {
        Double(content.view.frame.width + inspector.view.frame.width)
    }

    private func installDividerHandle() {
        dividerHandle.translatesAutoresizingMaskIntoConstraints = false
        // Above the split view, so it takes the clicks a few points either side of the divider. Tied to the chat, which
        // never collapses: a constraint on the inspector's view would go when the split view takes that view out.
        view.addSubview(dividerHandle)
        NSLayoutConstraint.activate([
            dividerHandle.centerXAnchor.constraint(equalTo: content.view.trailingAnchor, constant: splitView.dividerThickness / 2),
            dividerHandle.widthAnchor.constraint(equalToConstant: InspectorDividerHandle.hitWidth),
            dividerHandle.topAnchor.constraint(equalTo: splitView.topAnchor),
            dividerHandle.bottomAnchor.constraint(equalTo: splitView.bottomAnchor),
        ])
        dividerHandle.isHidden = inspectorItem.isCollapsed
        dividerHandle.onDrag = { [weak self] x in self?.dragDivider(to: x) }
        dividerHandle.onDragEnded = { [weak self] in self?.saveInspectorFraction() }
        dividerHandle.onReset = { [weak self] in self?.resetInspectorWidth() }
    }

    /// Moves the divider to `x` (in this controller's view) while the user drags: the share follows the pointer, within
    /// both minimums, and the layout follows the share.
    func dragDivider(to x: CGFloat) {
        guard !inspectorItem.isCollapsed else { return }
        let right = splitView.convert(splitView.bounds, to: view).maxX
        let width = Double(right - x - splitView.dividerThickness / 2)
        guard let fraction = InspectorWidth.fraction(panelWidth: width, available: availableWidth) else { return }
        inspectorFraction = fraction
        holdProportion()
        view.layoutSubtreeIfNeeded()
    }

    /// Remembers the dragged share for every panel and the next launch.
    func saveInspectorFraction() {
        let fraction = inspectorFraction
        state.update { $0.inspectorFraction = fraction }
    }

    /// Double-clicking the divider: back to half and half, for every panel.
    func resetInspectorWidth() {
        inspectorFraction = nil
        state.update { $0.inspectorFraction = nil }
        guard !inspectorItem.isCollapsed else { return }
        holdProportion()
        view.layoutSubtreeIfNeeded()
    }

    /// Remembers the open panels' sizes. Called before a panel closes and when the window closes. The inspector's share
    /// is saved as the user drags it.
    func saveLayout() {
        let sidebarWidth = sidebarItem.isCollapsed ? nil : Double(sidebar.view.frame.width)
        if let sidebarWidth { state.update { $0.listWidth = sidebarWidth } }
        content.saveLayout()
    }

    /// Shows `threadID` in every panel, then the inspector as the thread last left it (`followThread`).
    func setThreadID(_ threadID: UUID?) {
        self.threadID = threadID
        content.setThreadID(threadID)
        diff.threadID = threadID
        pullRequests.threadID = threadID
        preview.threadID = threadID
        schedules.threadID = threadID
        if isViewLoaded { followThread() }
    }
}

/// The inspector column: the diff, the pull requests, the browser preview or, when Settings › General puts it on the
/// right, the terminal, one at a time, as T3 Code's right panel switches between them. It has no tabs of its own; the
/// toolbar's buttons (`InspectorPanelButtons`) choose. A panel not showing is out of the window, so it loads nothing
/// until it shows again; the terminal's shells keep running meanwhile, as they do in a closed drawer.
final class InspectorViewController: NSTabViewController {
    init(
        diff: DiffViewController, pullRequests: PullRequestsViewController, preview: PreviewViewController = PreviewViewController(),
        schedules: SchedulesPanelController = SchedulesPanelController()
    ) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .unspecified
        transitionOptions = []
        canPropagateSelectedChildViewControllerTitle = false
        addTabViewItem(NSTabViewItem(viewController: diff))
        addTabViewItem(NSTabViewItem(viewController: pullRequests))
        addTabViewItem(NSTabViewItem(viewController: preview))
        addTabViewItem(NSTabViewItem(viewController: schedules))
        // The terminal's panel is added only with the terminal (`attachTerminal`).
        selectedTabViewItemIndex = panels.firstIndex(of: UIState.shared.values.inspectorPanel) ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The panels in tab order.
    private(set) var panels: [UIState.InspectorPanel] = [.diff, .pullRequests, .preview, .schedules]
    var panel: UIState.InspectorPanel { panels[selectedTabViewItemIndex] }
    var hasTerminal: Bool { panels.contains(.terminal) }

    func show(_ panel: UIState.InspectorPanel) {
        guard let index = panels.firstIndex(of: panel) else { return }
        selectedTabViewItemIndex = index
        UIState.shared.update { $0.inspectorPanel = panel }
    }

    /// Adds the terminal as the last panel, showing it when `select` is true.
    func attachTerminal(_ terminal: NSViewController, select: Bool) {
        guard !hasTerminal else { return }
        // A collapsed drawer leaves its view hidden.
        terminal.view.isHidden = false
        addTabViewItem(NSTabViewItem(viewController: terminal))
        panels.append(.terminal)
        if select { selectedTabViewItemIndex = panels.count - 1 }
    }

    /// Takes the terminal's panel out, so the terminal can go back below the chat. When it was the chosen panel, the
    /// column goes back to the diff.
    func detachTerminal() {
        guard let index = panels.firstIndex(of: .terminal) else { return }
        let wasSelected = selectedTabViewItemIndex == index
        if wasSelected { selectedTabViewItemIndex = 0 }
        removeTabViewItem(tabViewItems[index])
        panels.remove(at: index)
        if wasSelected || UIState.shared.values.inspectorPanel == .terminal {
            UIState.shared.update { $0.inspectorPanel = .diff }
        }
    }
}

/// The chat on top and the thread's terminal in a drawer below it, toggled with Command-J. With the terminal on the
/// right (`TerminalPlacement.right`), the drawer has no terminal and the chat takes the whole height.
final class ChatTerminalSplitViewController: NSSplitViewController {
    let chat = ChatViewController()
    let terminal = TerminalViewController()
    /// Whether the drawer starts out with the terminal. Set before the view loads.
    var hostsTerminal = true
    private var terminalItem: NSSplitViewItem?
    private var hasSizedTerminal = false
    private var hasRestoredLayout = false
    var onTerminalToggled: (() -> Void)?

    var isTerminalOpen: Bool { terminalItem.map { !$0.isCollapsed } ?? false }

    private static let defaultTerminalHeight: CGFloat = 260

    override func viewDidLoad() {
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        let chatItem = NSSplitViewItem(viewController: chat)
        chatItem.minimumThickness = 200
        chatItem.holdingPriority = .defaultLow
        addSplitViewItem(chatItem)
        if hostsTerminal {
            let item = makeTerminalItem(collapsed: !UIState.shared.values.isTerminalOpen)
            addSplitViewItem(item)
            terminalItem = item
        }
        super.viewDidLoad()
    }

    private func makeTerminalItem(collapsed: Bool) -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: terminal)
        item.canCollapse = true
        item.minimumThickness = 120
        item.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 10)
        item.isCollapsed = collapsed
        return item
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasRestoredLayout else { return }
        hasRestoredLayout = true
        if isTerminalOpen { sizeTerminal() }
    }

    /// Takes the terminal out of the drawer, so it can go to the inspector. Its shells keep running.
    func detachTerminal() {
        guard let item = terminalItem else { return }
        saveLayout()
        removeSplitViewItem(item)
        terminalItem = nil
        UIState.shared.update { $0.isTerminalOpen = false }
    }

    /// Puts the terminal back in the drawer, open or closed.
    func attachTerminal(open: Bool) {
        guard terminalItem == nil else { return }
        terminal.view.isHidden = false
        let item = makeTerminalItem(collapsed: !open)
        addSplitViewItem(item)
        terminalItem = item
        if open {
            view.layoutSubtreeIfNeeded()
            sizeTerminal()
        }
        UIState.shared.update { $0.isTerminalOpen = open }
    }

    func setThreadID(_ threadID: UUID?) {
        chat.threadID = threadID
        terminal.threadID = threadID
    }

    /// Opens or closes the terminal drawer. Closing a focused terminal returns focus to the composer; once open, the
    /// terminal controller starts a shell if the thread has none, and `MainSplitViewController.toggleTerminalPanel`
    /// focuses it.
    func toggleTerminal() {
        guard let terminalItem else { return }
        let opening = terminalItem.isCollapsed
        if opening {
            if hasSizedTerminal {
                setCollapsed(terminalItem, false)
            } else {
                terminalItem.isCollapsed = false
                sizeTerminal()
            }
        } else {
            let terminalHadFocus = (view.window?.firstResponder as? NSView)?.isDescendant(of: terminal.view) ?? false
            saveLayout()
            setCollapsed(terminalItem, true)
            if terminalHadFocus { AppEvents.post(.coincideFocusComposer) }
        }
        UIState.shared.update { $0.isTerminalOpen = opening }
        onTerminalToggled?()
    }

    func saveLayout() {
        guard isTerminalOpen else { return }
        let height = Double(terminal.view.frame.height)
        if height > 0 { UIState.shared.update { $0.terminalHeight = height } }
    }

    private func sizeTerminal() {
        hasSizedTerminal = true
        let height = UIState.shared.values.terminalHeight.map { CGFloat($0) } ?? Self.defaultTerminalHeight
        let position = splitView.bounds.height - height - splitView.dividerThickness
        splitView.setPosition(max(200, position), ofDividerAt: 0)
    }
}

extension NSSplitViewController {
    /// Whether the window shows a panel opening or closing. The split view animates that on the display's refresh, so
    /// in a window no screen shows (off every screen, covered, or on a display that is asleep) the animation can stall
    /// and leave the columns at their old widths.
    var showsPanelChanges: Bool {
        guard let window = view.window else { return false }
        return window.isVisible && window.screen != nil && window.occlusionState.contains(.visible)
    }

    /// Opens or closes `item`: animated when the window shows it, otherwise in place.
    func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool) {
        if showsPanelChanges {
            item.animator().isCollapsed = collapsed
        } else {
            item.isCollapsed = collapsed
        }
    }
}
