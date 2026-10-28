import AppKit
import CoincideKit

extension NSToolbarItem.Identifier {
    static let newThread = NSToolbarItem.Identifier("coincide.newThread")
    static let runStatus = NSToolbarItem.Identifier("coincide.runStatus")
    static let openIn = NSToolbarItem.Identifier("coincide.openIn")
    static let toggleTerminal = NSToolbarItem.Identifier("coincide.toggleTerminal")
    static let toggleDiff = NSToolbarItem.Identifier("coincide.toggleDiff")
}

/// The unified toolbar: sidebar toggle and new thread over the sidebar; the thread title, run status,
/// "Open in" picker and terminal toggle over the chat; and the diff toggle over the inspector.
extension MainWindowController: NSToolbarDelegate, NSToolbarItemValidation, NSMenuDelegate {
    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, .flexibleSpace, .newThread, .sidebarTrackingSeparator, .flexibleSpace, .runStatus, .openIn,
            .toggleTerminal, .inspectorTrackingSeparator, .flexibleSpace, .toggleDiff,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    /// With `flag` false, AppKit wants an item for the Customize Toolbar palette: a static copy that is
    /// neither kept in `toolbarItems` nor given the live run status view. An item dragged from the palette
    /// into the toolbar is asked for again with `flag` true.
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch itemIdentifier {
        case .runStatus where !flag:
            item = paletteItem(itemIdentifier, label: String(localized: "Status"), symbol: "clock")
        case .openIn where !flag:
            item = paletteItem(itemIdentifier, label: String(localized: "Open In"), symbol: "arrow.up.forward.app")
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
        case .runStatus:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = runStatus
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
            menuItem.isBordered = true
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
        item.isBordered = true
        return item
    }

    /// Keeps toggle labels, tooltips and symbols in step with the panels.
    func updatePanelItems() {
        let keyBindings = KeyBindingsController.shared
        if let item = toolbarItems[.toggleTerminal] {
            let open = splitController.content.isTerminalOpen
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
        updatePanelItems()
        updateOpenInItem()
    }

    /// Shows the preferred app's icon and name on the "Open in" button.
    @objc func updateOpenInItem() {
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
