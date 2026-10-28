import AppKit
import CoincideKit

/// Thread list | chat over a collapsible terminal | diff inspector, right of the navigation rail
/// (`MainRootViewController`). Panel sizes and visibility are remembered in `UIState`.
final class MainSplitViewController: NSSplitViewController {
    let sidebar = SidebarViewController()
    let content = ChatTerminalSplitViewController()
    let diff = DiffViewController()

    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var observations: [NSKeyValueObservation] = []
    /// The inspector has been given its width this session; after that the split view remembers it.
    private var hasSizedInspector = false
    private var hasRestoredLayout = false

    var isSidebarOpen: Bool { !sidebarItem.isCollapsed }
    var isDiffOpen: Bool { !inspectorItem.isCollapsed }
    /// Called after the sidebar, terminal or diff opens or closes, so the toolbar and menus can follow.
    var onPanelsChanged: (() -> Void)?

    private static let defaultSidebarWidth: CGFloat = 252
    private static let defaultInspectorWidth: CGFloat = 480

    override func viewDidLoad() {
        let state = UIState.shared.values
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = state.isSidebarCollapsed

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 420

        inspectorItem = NSSplitViewItem(inspectorWithViewController: diff)
        inspectorItem.minimumThickness = 320
        inspectorItem.maximumThickness = 1100
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = !state.isInspectorOpen

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
        super.viewDidLoad()
        content.onTerminalToggled = { [weak self] in self?.onPanelsChanged?() }

        // The toolbar's sidebar button toggles the item directly, so follow the item itself.
        observations = [
            sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                let collapsed = item.isCollapsed
                MainActor.assumeIsolated {
                    UIState.shared.update { $0.isSidebarCollapsed = collapsed }
                    self?.onPanelsChanged?()
                }
            },
            inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                let collapsed = item.isCollapsed
                MainActor.assumeIsolated {
                    UIState.shared.update { $0.isInspectorOpen = !collapsed }
                    self?.onPanelsChanged?()
                }
            },
        ]
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasRestoredLayout else { return }
        hasRestoredLayout = true
        // Positions are set once the window has its real size, so they are not scaled away.
        let state = UIState.shared.values
        if !sidebarItem.isCollapsed {
            splitView.setPosition(state.threadListWidth.map { CGFloat($0) } ?? Self.defaultSidebarWidth, ofDividerAt: 0)
        }
        if !inspectorItem.isCollapsed { sizeInspector() }
    }

    func toggleSidebarPanel() {
        if !sidebarItem.isCollapsed { saveLayout() }
        sidebarItem.animator().isCollapsed.toggle()
    }

    /// Opens the inspector if it is closed.
    func showDiffPanel() {
        if inspectorItem.isCollapsed { toggleDiffPanel() }
    }

    func toggleDiffPanel() {
        if inspectorItem.isCollapsed {
            if hasSizedInspector {
                inspectorItem.animator().isCollapsed = false
            } else {
                // The first opening has no earlier width to return to; give it the saved one.
                inspectorItem.isCollapsed = false
                sizeInspector()
            }
        } else {
            saveLayout()
            inspectorItem.animator().isCollapsed = true
        }
    }

    private func sizeInspector() {
        hasSizedInspector = true
        let width = UIState.shared.values.inspectorWidth.map { CGFloat($0) } ?? Self.defaultInspectorWidth
        splitView.setPosition(splitView.bounds.width - width - splitView.dividerThickness, ofDividerAt: 1)
    }

    /// Remembers the open panels' sizes. Called before a panel closes and when the window closes.
    func saveLayout() {
        let sidebarWidth = sidebarItem.isCollapsed ? nil : Double(sidebar.view.frame.width)
        let inspectorWidth = inspectorItem.isCollapsed ? nil : Double(diff.view.frame.width)
        UIState.shared.update { state in
            if let sidebarWidth { state.threadListWidth = sidebarWidth }
            if let inspectorWidth { state.inspectorWidth = inspectorWidth }
        }
        content.saveLayout()
    }

    func setThreadID(_ threadID: UUID?) {
        content.setThreadID(threadID)
        diff.threadID = threadID
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
