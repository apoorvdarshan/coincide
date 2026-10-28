import AppKit
import CoincideKit

/// Builds the composer's menus: reasoning effort and access mode. (The agent and model picker is `ModelPickerViewController`.)
/// Items carry their value in `representedObject`.
enum ComposerMenus {
    static func effortMenu(model: ModelOption, current: String?, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: String(localized: "Reasoning Effort")))
        let selected = current ?? model.defaultEffort
        for effort in model.efforts {
            let item = NSMenuItem(title: effortTitle(effort), action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = effort
            item.state = effort == selected ? .on : .off
            if effort == model.defaultEffort { item.subtitle = String(localized: "Default") }
            menu.addItem(item)
        }
        return menu
    }

    static func accessMenu(current: AccessMode, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mode in AccessMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = mode
            item.state = mode == current ? .on : .off
            item.image = NSImage(systemSymbolName: symbolName(for: mode), accessibilityDescription: nil)
            item.subtitle = summary(for: mode)
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Labels

    static func symbolName(for mode: AccessMode) -> String {
        switch mode {
        case .fullAccess: "lock.open"
        case .approval: "lock"
        }
    }

    static func summary(for mode: AccessMode) -> String {
        switch mode {
        case .fullAccess: String(localized: "Runs commands and edits files without asking.")
        case .approval: String(localized: "Asks before running commands and changing files.")
        }
    }

    static func effortTitle(_ effort: String) -> String {
        switch effort.lowercased() {
        case "none", "off": String(localized: "Off")
        case "auto": String(localized: "Auto")
        case "minimal": String(localized: "Minimal")
        case "low": String(localized: "Low")
        case "medium": String(localized: "Medium")
        case "high": String(localized: "High")
        case "xhigh", "extra-high", "extra_high": String(localized: "Extra High")
        case "max", "maximum": String(localized: "Max")
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }

    /// Why a provider cannot be used right now, with its setup hint when it has one.
    static func statusText(_ kind: ProviderKind, registry: ProviderRegistry) -> String {
        let status = registry.status(kind)
        let hint = registry.provider(kind)?.setupHint
        switch status.state {
        case .ready:
            return String(localized: "Ready")
        case .notInstalled:
            return [String(localized: "Not installed."), hint].compactMap { $0 }.joined(separator: " ")
        case .notAuthenticated:
            return [String(localized: "Not signed in."), hint].compactMap { $0 }.joined(separator: " ")
        case .error:
            return status.message ?? String(localized: "Could not start.")
        case .unknown:
            if registry.isRefreshing { return String(localized: "Checking…") }
            return status.message ?? String(localized: "Not checked yet.")
        }
    }
}
