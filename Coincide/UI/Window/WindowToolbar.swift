import AppKit
import CoincideKit

extension NSToolbarItem.Identifier {
    static let newThread = NSToolbarItem.Identifier("coincide.newThread")
    /// Coincide's own sidebar button, plain like the other items (the system's always draws a bezel).
    static let sidebar = NSToolbarItem.Identifier("coincide.sidebar")
    static let threadTitle = NSToolbarItem.Identifier("coincide.threadTitle")
    static let runStatus = NSToolbarItem.Identifier("coincide.runStatus")
    static let projectScripts = NSToolbarItem.Identifier("coincide.projectScripts")
    static let openIn = NSToolbarItem.Identifier("coincide.openIn")
    static let toggleTerminal = NSToolbarItem.Identifier("coincide.toggleTerminal")
    static let toggleDiff = NSToolbarItem.Identifier("coincide.toggleDiff")
    /// The diff, pull request and browser preview buttons (`InspectorPanelButtons`).
    static let inspectorPanels = NSToolbarItem.Identifier("coincide.inspectorPanels")
}

/// The unified toolbar: the thread title, project scripts and run status over the chat, then the buttons of the panels
/// that open on the right (`InspectorPanelButtons`) at the window's top-right corner, over the inspector when it is
/// open. The sidebar, new thread, "Open in", terminal and diff buttons can be added with Customize Toolbar.
extension MainWindowController: NSToolbarDelegate, NSToolbarItemValidation, NSMenuDelegate {
    func makeToolbar() -> NSToolbar {
        // A new identifier, so toolbars saved before the right panels' buttons moved here start from the new defaults.
        let toolbar = NSToolbar(identifier: "MainToolbar5")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        return toolbar
    }

    /// The navigation rail has the buttons of the places and of the terminal in its drawer; the panels that open on the
    /// right (the terminal too, when Settings › General puts it there) have theirs on the right, after the inspector's tracking separator. That keeps them at the window's top-right corner
    /// whether the inspector is open (they sit over its top edge) or closed (they follow the scripts and status), so
    /// they don't move when it opens. The flexible space before them pushes them to the trailing edge.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace, .sidebarTrackingSeparator, .threadTitle, .flexibleSpace, .projectScripts, .runStatus,
            .inspectorTrackingSeparator, .flexibleSpace, .inspectorPanels,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.sidebar, .newThread, .openIn, .toggleTerminal, .toggleDiff, .flexibleSpace, .space]
    }

    /// With `flag` false, AppKit wants an item for the Customize Toolbar palette: a static copy that is
    /// neither kept in `toolbarItems` nor given the live run status view. An item dragged from the palette
    /// into the toolbar is asked for again with `flag` true.
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch itemIdentifier {
        case .threadTitle:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = flag ? threadTitle : ThreadTitleView()
            item.label = String(localized: "Thread")
            item.paletteLabel = String(localized: "Thread")
            item.isBordered = false
            item.visibilityPriority = .high
        case .runStatus where !flag:
            item = paletteItem(itemIdentifier, label: String(localized: "Status"), symbol: "clock")
        case .openIn where !flag:
            item = paletteItem(itemIdentifier, label: String(localized: "Open In"), symbol: "arrow.up.forward.app")
        case .sidebar:
            item = button(
                itemIdentifier, label: String(localized: "Sidebar"), symbol: "sidebar.left",
                toolTip: KeyBindingsController.shared.toolTip(String(localized: "Sidebar"), for: .toggleSidebar),
                action: #selector(toggleSidebarPanel(_:)))
        case .newThread:
            item = button(
                itemIdentifier, label: String(localized: "New Thread"), symbol: "square.and.pencil",
                toolTip: KeyBindingsController.shared.toolTip(String(localized: "New Thread"), for: .newThread),
                action: #selector(newThread(_:)))
        case .toggleTerminal:
            item = button(
                itemIdentifier, label: String(localized: "Terminal"), symbol: "terminal", toolTip: "",
                action: #selector(toggleTerminalPanel(_:)))
        case .toggleDiff:
            item = button(
                itemIdentifier, label: String(localized: "Diff"), symbol: "plus.forwardslash.minus", toolTip: "",
                action: #selector(toggleDiffPanel(_:)))
        case .projectScripts where !flag:
            return paletteItem(itemIdentifier, label: String(localized: "Scripts"), symbol: "play.rectangle")
        case .inspectorPanels where !flag:
            return paletteItem(itemIdentifier, label: String(localized: "Right Panels"), symbol: "sidebar.right")
        case .inspectorPanels:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = panelButtons
            // The group draws its own themed pill, like the scripts control, so the toolbar adds no bezel of its own.
            item.isBordered = false
            item.label = String(localized: "Right Panels")
            item.paletteLabel = String(localized: "Right Panels")
            item.visibilityPriority = .high
        case .projectScripts:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = projectScripts
            // The control draws its own themed pill, so the toolbar adds no bezel of its own.
            item.isBordered = false
            item.label = String(localized: "Scripts")
            item.visibilityPriority = .high
            item.isHidden = !projectScripts.isAvailable
        case .runStatus:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = runStatus
            // The status draws its own themed pill, so the toolbar adds no bezel of its own.
            item.isBordered = false
            item.label = String(localized: "Status")
            item.visibilityPriority = .high
            item.isHidden = runStatus.state == .idle
        case .openIn:
            let menuItem = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            menuItem.menu = NSMenu()
            menuItem.menu.delegate = self
            // The split button's dropdown half takes its accessibility label from the menu; the button half
            // reads its own from the image (see `updateOpenInItem`).
            menuItem.menu.setAccessibilityLabel(String(localized: "Choose App to Open In"))
            menuItem.showsIndicator = true
            menuItem.target = self
            menuItem.action = #selector(openInPreferred(_:))
            menuItem.isBordered = false
            item = menuItem
        default:
            return nil
        }
        guard flag else { return item }
        toolbarItems[itemIdentifier] = item
        updatePanelItems()
        updateOpenInItem()
        return item
    }

    /// Forgets an item the user took out of the toolbar, so updates stop going to it.
    func toolbarDidRemoveItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem,
            toolbarItems[item.itemIdentifier] === item
        else { return }
        toolbarItems[item.itemIdentifier] = nil
    }

    private func paletteItem(_ identifier: NSToolbarItem.Identifier, label: String, symbol: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier, label: String, symbol: String, toolTip: String, action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = false
        return item
    }

    /// Keeps toggle labels, tooltips and symbols in step with the panels.
    func updatePanelItems() {
        let keyBindings = KeyBindingsController.shared
        updateRail()
        if let item = toolbarItems[.toggleTerminal] {
            let open = splitController.isTerminalOpen
            item.toolTip = keyBindings.toolTip(
                open ? String(localized: "Hide Terminal") : String(localized: "Show Terminal"), for: .toggleTerminal)
            item.image = NSImage(systemSymbolName: open ? "terminal.fill" : "terminal", accessibilityDescription: item.label)
        }
        if let item = toolbarItems[.toggleDiff] {
            let open = splitController.isDiffOpen
            item.toolTip = keyBindings.toolTip(open ? String(localized: "Hide Diff") : String(localized: "Show Diff"), for: .toggleDiff)
        }
    }

    /// The tooltips name the menu commands' shortcuts, which the user can change.
    @objc func updateToolbarShortcuts() {
        toolbarItems[.newThread]?.toolTip = KeyBindingsController.shared.toolTip(String(localized: "New Thread"), for: .newThread)
        toolbarItems[.sidebar]?.toolTip = KeyBindingsController.shared.toolTip(String(localized: "Sidebar"), for: .toggleSidebar)
        updatePanelItems()
        updateOpenInItem()
    }

    /// Lights the rail's and the toolbar's buttons for the open panels and enables Open In when there is a folder.
    func updateRail() {
        let terminalOpen = splitController.isTerminalOpen
        rail.update(threadsOpen: splitController.isSidebarOpen, terminalOpen: terminalOpen, canOpenFolder: openFolder != nil)
        panelButtons.update(open: splitController.isInspectorOpen ? splitController.inspector.panel : nil)
    }

    /// Follows Settings › General's terminal placement, live: the terminal moves, shells and all, between the drawer
    /// below the chat (its button in the rail) and the inspector (its button in the top-right group).
    func updateTerminalPlacement() {
        let placement = AppStore.shared.settings.terminalPlacement
        splitController.setTerminalPlacement(placement)
        rail.showsTerminalButton = placement == .bottom
        panelButtons.showsTerminal = placement == .right
        updatePanelItems()
    }

    /// Shows the preferred app's icon and name on the "Open in" button.
    @objc func updateOpenInItem() {
        updateRail()
        rail.updateOpenInTarget()
        guard let item = toolbarItems[.openIn] else { return }
        let target = OpenTargets.preferred
        let title = target.map { String(localized: "Open in \($0.name)") } ?? String(localized: "Open in Editor")
        // A copy, because the split button reads its accessibility label from the image and icons are shared.
        let image =
            target?.icon.copy() as? NSImage ?? NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        image?.accessibilityDescription = title
        item.image = image
        item.label = String(localized: "Open In")
        item.paletteLabel = String(localized: "Open In")
        item.toolTip = KeyBindingsController.shared.toolTip(title, for: .openInEditor)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier == .openIn ? openFolder != nil : true
    }

    // MARK: "Open in" menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        OpenTargets.reload()
        menu.removeAllItems()
        for item in OpenTargets.menuItems(target: self, action: #selector(openInApp(_:))) { menu.addItem(item) }
        updateOpenInItem()
    }
}
