import AppKit
import CoincideKit

/// Builds the composer's menus: reasoning effort, speed and access mode. (The agent and model picker is `ModelPickerViewController`.)
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

    /// Standard speed, then the faster ones the model offers. Standard's item carries no value.
    static func speedMenu(model: ModelOption, current: String?, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: String(localized: "Speed")))
        let selected = model.speed(current)
        let standard = NSMenuItem(title: ComposerSpeedControl.standardTitle, action: action, keyEquivalent: "")
        standard.target = target
        standard.state = selected == nil ? .on : .off
        standard.image = NSImage(systemSymbolName: ComposerSpeedControl.standardSymbol, accessibilityDescription: nil)
        standard.subtitle = String(localized: "Default")
        menu.addItem(standard)
        for speed in model.speeds {
            let item = NSMenuItem(title: speed.name, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = speed.id
            item.state = speed == selected ? .on : .off
            item.image = NSImage(systemSymbolName: ComposerSpeedControl.fastSymbol, accessibilityDescription: nil)
            item.subtitle = speed.detail
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

    /// Queue, Steer and Interrupt, for what a message sent while the agent works does. Steer is shown but can't be
    /// picked for an agent that doesn't take messages mid-turn, saying why.
    static func followUpMenu(current: FollowUpBehavior, provider: ProviderKind, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for behavior in [FollowUpBehavior.queue, .steer, .interrupt] {
            let item = NSMenuItem(title: behavior.displayName, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = behavior.rawValue
            item.state = behavior == current ? .on : .off
            item.image = NSImage(systemSymbolName: symbolName(for: behavior), accessibilityDescription: nil)
            let available = ComposerDispatch.isAvailable(behavior, for: provider)
            item.isEnabled = available
            item.subtitle = available ? summary(for: behavior) : unavailableReason(for: provider)
            item.toolTip = item.subtitle
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Labels

    static func symbolName(for behavior: FollowUpBehavior) -> String {
        switch behavior {
        case .queue: "text.line.last.and.arrowtriangle.forward"
        case .steer: "arrow.turn.up.right"
        case .interrupt: "forward.end"
        }
    }

    static func summary(for behavior: FollowUpBehavior) -> String {
        switch behavior {
        case .queue: String(localized: "Messages sent while the agent works wait for its turn to end.")
        case .steer: String(localized: "Messages sent while the agent works go into its current turn.")
        case .interrupt: String(localized: "Messages sent while the agent works stop its turn and go next.")
        }
    }

    /// Why Steer can't be picked for the agent.
    static func unavailableReason(for provider: ProviderKind) -> String {
        String(localized: "\(provider.displayName) can’t take messages while it works.")
    }

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
    /// For one of the agent's accounts (nil for its default one). An added account's setup is in Settings, not the
    /// CLI's hint, so it shows the account's own message.
    static func statusText(_ kind: ProviderKind, account: String? = nil, registry: ProviderRegistry) -> String {
        let status = registry.status(kind, account: account)
        let isDefault = registry.account(account, of: kind).isDefault
        let hint = isDefault ? registry.provider(kind)?.setupHint : status.message
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
