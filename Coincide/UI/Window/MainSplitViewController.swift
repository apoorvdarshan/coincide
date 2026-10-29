import AppKit
import CoincideKit

/// Thread list | chat over a collapsible terminal | inspector (the diff, the pull requests or the browser preview),
/// right of the navigation rail (`MainRootViewController`). Panel sizes and visibility are remembered in `UIState`.
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
    private(set) lazy var inspector = InspectorViewController(diff: diff, pullRequests: pullRequests, preview: preview)
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

    var isSidebarOpen: Bool { !sidebarItem.isCollapsed }
    var isInspectorOpen: Bool { !inspectorItem.isCollapsed }
    var isDiffOpen: Bool { !inspectorItem.isCollapsed && inspector.panel == .diff }
    var isPullRequestsOpen: Bool { !inspectorItem.isCollapsed && inspector.panel == .pullRequests }
    var isPreviewOpen: Bool { !inspectorItem.isCollapsed && inspector.panel == .preview }
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

    init(state: UIState = .shared) {
        self.state = state
        inspectorFraction = state.values.inspectorFraction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        let values = state.values
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
        inspectorItem.isCollapsed = !values.isInspectorOpen

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
        super.viewDidLoad()
        content.onTerminalToggled = { [weak self] in self?.onPanelsChanged?() }
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
        sidebarItem.animator().isCollapsed.toggle()
    }

    /// Opens the inspector on the diff.
    func showDiffPanel() {
        showInspector(.diff)
    }

    func toggleDiffPanel() {
        toggleInspector(.diff)
    }

    func togglePreviewPanel() { toggleInspector(.preview) }

    /// Opens the inspector on the browser preview, leaving it open if it already shows it.
    func showPreviewPanel() { showInspector(.preview) }

    func togglePullRequestsPanel() {
        toggleInspector(.pullRequests)
    }

    /// Closes the inspector when it shows `panel`, otherwise shows `panel` in it, opening it if it is closed: the
    /// toolbar's diff, pull request and preview buttons (`InspectorPanelButtons`) work like tabs of one column.
    private func toggleInspector(_ panel: UIState.InspectorPanel) {
        if !inspectorItem.isCollapsed, inspector.panel == panel {
            closeInspector()
        } else {
            showInspector(panel)
        }
    }

    private func showInspector(_ panel: UIState.InspectorPanel) {
        if inspector.panel != panel {
            inspector.show(panel)
            onPanelsChanged?()
        }
        guard inspectorItem.isCollapsed else { return }
        openInspector()
    }

    /// Opens the inspector at its share. The thread list keeps its width: the space comes from the chat, and from the
    /// window when the chat and the panel would not both get their minimums.
    private func openInspector() {
        // Closed, the inspector leaves the chat everything right of the thread list.
        let available = Double(content.view.frame.width - splitView.dividerThickness)
        growWindow(by: CGFloat(InspectorWidth.shortfall(available: available)))
        let target = InspectorWidth.panelWidth(fraction: inspectorFraction, available: available)
        // The split view animates back to the width the inspector closed at. When that is still its width, let it
        // animate and hold the share afterwards; otherwise (a first opening, the window resized meanwhile) open it in
        // place at the share, rather than animate to one width and then jump to another.
        if let closedInspectorWidth, abs(Double(closedInspectorWidth) - target) < 1, view.window?.isVisible == true {
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

    private func closeInspector() {
        closedInspectorWidth = inspector.view.frame.width
        releaseProportion()
        inspectorItem.animator().isCollapsed = true
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

    func setThreadID(_ threadID: UUID?) {
        content.setThreadID(threadID)
        diff.threadID = threadID
        pullRequests.threadID = threadID
        preview.threadID = threadID
    }
}

/// The inspector column: the diff or the pull requests, one at a time, as T3 Code's right panel switches between
/// them. It has no tabs of its own; the toolbar's buttons (`InspectorPanelButtons`) choose. A panel not showing is out of the window, so it loads
/// nothing until it shows again.
final class InspectorViewController: NSTabViewController {
    init(diff: DiffViewController, pullRequests: PullRequestsViewController, preview: PreviewViewController = PreviewViewController()) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .unspecified
        transitionOptions = []
        canPropagateSelectedChildViewControllerTitle = false
        addTabViewItem(NSTabViewItem(viewController: diff))
        addTabViewItem(NSTabViewItem(viewController: pullRequests))
        addTabViewItem(NSTabViewItem(viewController: preview))
        selectedTabViewItemIndex = Self.panels.firstIndex(of: UIState.shared.values.inspectorPanel) ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let panels: [UIState.InspectorPanel] = [.diff, .pullRequests, .preview]
    var panel: UIState.InspectorPanel { Self.panels[selectedTabViewItemIndex] }

    func show(_ panel: UIState.InspectorPanel) {
        selectedTabViewItemIndex = Self.panels.firstIndex(of: panel) ?? 0
        UIState.shared.update { $0.inspectorPanel = panel }
    }
}

/// The chat on top and the thread's terminal in a drawer below it, toggled with Command-J.
final class ChatTerminalSplitViewController: NSSplitViewController {
    let chat = ChatViewController()
    let terminal = TerminalViewController()
    private var terminalItem: NSSplitViewItem!
    private var hasSizedTerminal = false
    private var hasRestoredLayout = false
    var onTerminalToggled: (() -> Void)?

    var isTerminalOpen: Bool { !terminalItem.isCollapsed }

    private static let defaultTerminalHeight: CGFloat = 260

    override func viewDidLoad() {
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        let chatItem = NSSplitViewItem(viewController: chat)
        chatItem.minimumThickness = 200
        chatItem.holdingPriority = .defaultLow
        terminalItem = NSSplitViewItem(viewController: terminal)
        terminalItem.canCollapse = true
        terminalItem.minimumThickness = 120
        terminalItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 10)
        terminalItem.isCollapsed = !UIState.shared.values.isTerminalOpen
        addSplitViewItem(chatItem)
        addSplitViewItem(terminalItem)
        super.viewDidLoad()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasRestoredLayout else { return }
        hasRestoredLayout = true
        if !terminalItem.isCollapsed { sizeTerminal() }
    }

    func setThreadID(_ threadID: UUID?) {
        chat.threadID = threadID
        terminal.threadID = threadID
    }

    /// Opens or closes the terminal drawer. Closing a focused terminal returns focus to the composer;
    /// once open, the terminal controller starts a shell if the thread has none and focuses it.
    func toggleTerminal() {
        let opening = terminalItem.isCollapsed
        if opening {
            if hasSizedTerminal {
                terminalItem.animator().isCollapsed = false
            } else {
                terminalItem.isCollapsed = false
                sizeTerminal()
            }
        } else {
            let terminalHadFocus = (view.window?.firstResponder as? NSView)?.isDescendant(of: terminal.view) ?? false
            saveLayout()
            terminalItem.animator().isCollapsed = true
            if terminalHadFocus { AppEvents.post(.coincideFocusComposer) }
        }
        UIState.shared.update { $0.isTerminalOpen = opening }
        onTerminalToggled?()
    }

    func saveLayout() {
        guard !terminalItem.isCollapsed else { return }
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
