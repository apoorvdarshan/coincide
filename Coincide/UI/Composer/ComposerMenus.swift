import AppKit
import CoincideKit

/// Builds the composer's menus: the agent and model picker, reasoning effort and access mode.
/// Items carry their value in `representedObject`.
enum ComposerMenus {
    /// Models listed inline per provider; longer lists move the rest into a submenu.
    private static let inlineModelLimit = 12

    /// Ready providers with their models, then the others, disabled, with how to set them up.
    static func modelMenu(
        current: ModelSelection, registry: ProviderRegistry, target: AnyObject, choose: Selector, refresh: Selector,
        settings: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let ready = registry.readyKinds
        for kind in ready {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(providerHeader(kind))
            var models = registry.models(for: kind)
            if kind == current.provider, !models.contains(where: { $0.modelID == current.modelID }) {
                models.insert(ModelOption(provider: kind, modelID: current.modelID, displayName: current.modelID), at: 0)
            }
            let inline =
                models.count > inlineModelLimit
                ? Array(models.prefix(inlineModelLimit - 2)) + models.dropFirst(inlineModelLimit - 2).filter {
                    $0.modelID == current.modelID && kind == current.provider
                }
                : models
            for model in inline {
                menu.addItem(modelItem(model, current: current, target: target, action: choose))
            }
            if models.count > inline.count {
                let more = NSMenuItem(title: String(localized: "More \(kind.displayName) Models"), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for model in models {
                    submenu.addItem(modelItem(model, current: current, target: target, action: choose))
                }
                more.submenu = submenu
                menu.addItem(more)
            }
        }

        let unavailable = registry.orderedKinds.filter { !ready.contains($0) }
        if !unavailable.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: String(localized: "Not Available")))
            for kind in unavailable {
                let item = NSMenuItem(title: kind.displayName, action: nil, keyEquivalent: "")
                item.image = providerImage(kind)
                item.subtitle = statusText(kind, registry: registry)
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: String(localized: "Refresh Providers"), action: refresh, keyEquivalent: "")
        refreshItem.target = target
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshItem.isEnabled = !registry.isRefreshing
        menu.addItem(refreshItem)
        let settingsItem = NSMenuItem(title: String(localized: "Provider Settings…"), action: settings, keyEquivalent: "")
        settingsItem.target = target
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        return menu
    }

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

    /// The access modes `provider` offers, with the one the thread runs in checked.
    static func accessMenu(current: AccessMode, provider: ProviderKind, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = provider.accessMode(for: current)
        for mode in provider.accessModes {
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

    static func providerImage(_ kind: ProviderKind, size: CGFloat = 13) -> NSImage? {
        NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: kind.displayName)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [Theme.color(for: kind)])))
    }

    private static func providerHeader(_ kind: ProviderKind) -> NSMenuItem {
        let item = NSMenuItem.sectionHeader(title: kind.displayName)
        item.image = providerImage(kind, size: 11)
        return item
    }

    private static func modelItem(_ model: ModelOption, current: ModelSelection, target: AnyObject, action: Selector)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: model.displayName, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = ModelSelection(provider: model.provider, modelID: model.modelID, effort: model.defaultEffort)
        item.state = model.provider == current.provider && model.modelID == current.modelID ? .on : .off
        if model.displayName != model.modelID, model.modelID != "default" { item.toolTip = model.modelID }
        return item
    }
}
