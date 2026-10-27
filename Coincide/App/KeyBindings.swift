import AppKit
import CoincideKit

/// Gives the menu bar's commands the user's shortcuts (`AppSettings.shortcutOverrides`) at launch and whenever they
/// change, as T3 Code reloads its keybindings. Menu items take part through their identifier
/// (`NSUserInterfaceItemIdentifier.keyCommand`).
///
/// The menu bar's fixed items (Copy, Close Window, Settings…) keep their shortcuts: a command set to one gets none.
/// AppKit enforces much the same: it refuses a standard item's shortcut to another item, and when it installs a menu
/// it drops the shortcut of the later of two items that share one, which could otherwise take ⌘C from Copy.
final class KeyBindingsController {
    static let shared = KeyBindingsController()

    /// Posted after the menu bar's shortcuts change, for anything that shows a command's shortcut.
    static let didChangeNotification = Notification.Name("CoincideKeyBindingsDidChange")

    private(set) var bindings: KeyBindings
    /// Shortcuts of the menu bar's fixed items, as of the last update.
    private var fixed: Set<KeyShortcut> = []
    private let store: AppStore
    private weak var menu: NSMenu?
    private var token: ObservationToken?

    init(store: AppStore = .shared) {
        self.store = store
        bindings = store.settings.keyBindings
    }

    /// Gives `menu`'s command items their shortcuts now and after every change to them. Call it once the menu is
    /// built, before it becomes the main menu.
    func attach(to menu: NSMenu) {
        self.menu = menu
        bindings = store.settings.keyBindings
        apply(to: menu)
        guard token == nil else { return }
        token = store.observe { [weak self] change in
            if change == .settings { self?.settingsChanged() }
        }
    }

    /// The shortcut the command's menu item has: none when another command or a fixed menu item has its shortcut.
    func menuShortcut(for command: KeyCommand) -> KeyShortcut? {
        bindings.menuShortcut(for: command, keeping: fixed)
    }

    /// The command's shortcut as the menu bar shows it ("⇧⌘K"), or nil when it has none. For tooltips and lists.
    func displayString(for command: KeyCommand) -> String? {
        menuShortcut(for: command)?.displayString
    }

    /// A tooltip naming the command's shortcut after `text`, such as "Stop (⌘.)"; just `text` when the command has
    /// none. Views that show one update it on `didChangeNotification`.
    func toolTip(_ text: String, for command: KeyCommand) -> String {
        guard let keys = displayString(for: command) else { return text }
        return String(localized: "\(text) (\(keys))")
    }

    /// The modifiers of the Go to Thread shortcuts, each once (`KeyBindings.threadJumpModifiers(keeping:)`).
    var threadJumpModifiers: [KeyModifiers] {
        bindings.threadJumpModifiers(keeping: fixed)
    }

    /// Whether holding `flags` (and nothing else) shows the sidebar's thread numbers: they are the modifiers of a Go
    /// to Thread shortcut, as T3 shows its jump hints.
    func showsThreadJumpHints(for flags: NSEvent.ModifierFlags) -> Bool {
        let held = KeyModifiers(flags)
        return !held.isEmpty && threadJumpModifiers.contains(held)
    }

    private func settingsChanged() {
        let latest = store.settings.keyBindings
        guard latest != bindings else { return }
        bindings = latest
        if let menu { apply(to: menu) }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func apply(to menu: NSMenu) {
        fixed = Set(Self.fixedMenuShortcuts(in: menu).map(\.shortcut))
        var targets: [(item: NSMenuItem, shortcut: KeyShortcut?)] = []
        func collect(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu, submenu !== NSApp.servicesMenu { collect(submenu) }
                guard let identifier = item.identifier else { continue }
                if identifier == .increaseFontSizeWithoutShift {
                    targets.append((item, usesCommandEquals ? Self.commandEquals : nil))
                } else if let command = KeyCommand(menuItemIdentifier: identifier) {
                    targets.append((item, menuShortcut(for: command)))
                }
            }
        }
        collect(menu)
        // Clear the items whose shortcut changes before giving any its new one, so no two share one even for a moment.
        for target in targets where KeyShortcut(menuItem: target.item) != target.shortcut { set(nil, on: target.item) }
        for target in targets { set(target.shortcut, on: target.item) }
    }

    /// Command-= reaches Increase Font Size without Shift while it keeps its default Command-+ and nothing else has
    /// Command-=.
    private var usesCommandEquals: Bool {
        menuShortcut(for: .increaseFontSize) == KeyCommand.increaseFontSize.defaultShortcut
            && bindings.commands(using: Self.commandEquals).isEmpty && !fixed.contains(Self.commandEquals)
    }

    private static let commandEquals = shortcut("mod+=")

    private func set(_ shortcut: KeyShortcut?, on item: NSMenuItem) {
        item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = shortcut?.modifiers.modifierFlags ?? []
    }

    // MARK: Other shortcuts

    /// The menu bar's items with a shortcut that can't be changed here, such as Copy, Close Window and Settings.
    func fixedMenuShortcuts() -> [FixedMenuShortcut] {
        guard let menu = menu ?? NSApp.mainMenu else { return [] }
        return Self.fixedMenuShortcuts(in: menu)
    }

    private static func fixedMenuShortcuts(in menu: NSMenu) -> [FixedMenuShortcut] {
        var result: [FixedMenuShortcut] = []
        func collect(_ menu: NSMenu, path: [String]) {
            guard menu !== NSApp.servicesMenu else { return }
            for item in menu.items where !item.isSeparatorItem {
                if let submenu = item.submenu {
                    collect(submenu, path: path + [item.title])
                    continue
                }
                guard item.identifier?.isKeyCommand != true, !item.isHidden || item.allowsKeyEquivalentWhenHidden,
                    !item.title.isEmpty, let shortcut = KeyShortcut(menuItem: item)
                else { continue }
                result.append(
                    FixedMenuShortcut(shortcut: shortcut, path: path + [item.title], action: item.action.map(NSStringFromSelector) ?? ""))
            }
        }
        collect(menu, path: [])
        return result
    }

    /// Everything else that uses shortcuts: macOS, the menu bar's fixed items, the composer and a focused terminal.
    static func reservedShortcuts(fixed: [FixedMenuShortcut]) -> [ReservedShortcut] {
        let menuItems = fixed.map { ReservedShortcut(shortcut: $0.shortcut, title: $0.title, owner: .app) }
        // A shortcut macOS puts in the menu bar itself, such as Emoji & Symbols, is named once, by its menu item.
        let system = ReservedShortcut.macOS.filter { reserved in !fixed.contains { $0.shortcut == reserved.shortcut } }
        let composer = composerKeys.map {
            ReservedShortcut(shortcut: $0.shortcut, title: String(localized: "Composer › \($0.title)"), owner: .app)
        }
        let terminal = terminalKeys.flatMap { entry in
            entry.shortcuts.map { ReservedShortcut(shortcut: $0, title: entry.title, owner: .focusedView("terminal")) }
        }
        return system + menuItems + composer + terminal
    }

    /// Keys a focused terminal keeps for itself (`ShellTerminalView.handleKeyDown`), as in T3 Code.
    static let terminalKeys: [(title: String, shortcuts: [KeyShortcut])] = [
        (String(localized: "New terminal"), [shortcut("mod+t"), shortcut("mod+n")]),
        (String(localized: "Split right"), [shortcut("mod+d")]),
        (String(localized: "Split down"), [shortcut("mod+shift+d")]),
        (String(localized: "Close terminal"), [shortcut("mod+w")]),
        (String(localized: "Clear"), [shortcut("mod+k")]),
        (String(localized: "Previous and next terminal tab"), [shortcut("mod+shift+["), shortcut("mod+shift+]")]),
        (String(localized: "Previous and next pane"), [shortcut("mod+alt+arrowleft"), shortcut("mod+alt+arrowright")]),
        (String(localized: "Move to the start or end of the line"), [shortcut("mod+arrowleft"), shortcut("mod+arrowright")]),
        (String(localized: "Move by word"), [shortcut("alt+arrowleft"), shortcut("alt+arrowright")]),
    ]

    /// Keys the composer handles itself. The menu bar sees keys first, so a command given one takes it from the composer.
    static let composerKeys: [(title: String, shortcut: KeyShortcut)] = [
        (String(localized: "Send message"), shortcut("mod+enter"))
    ]

    private static func shortcut(_ text: String) -> KeyShortcut {
        guard let shortcut = KeyShortcut(text) else { preconditionFailure("Invalid built-in shortcut \(text)") }
        return shortcut
    }
}

/// A menu bar item whose shortcut can't be changed here.
struct FixedMenuShortcut: Hashable {
    let shortcut: KeyShortcut
    /// Menu titles down to the item: ["Edit", "Copy"].
    let path: [String]
    /// The item's action, such as "copy:".
    let action: String

    var title: String { path.joined(separator: " › ") }
}

extension NSUserInterfaceItemIdentifier {
    private static let keyCommandPrefix = "keyCommand:"

    /// The identifier of a menu item that runs `command`; `KeyBindingsController` gives it the command's shortcut.
    static func keyCommand(_ command: KeyCommand) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(keyCommandPrefix + command.rawValue)
    }

    /// The hidden item that lets Command-= increase the font size without Shift.
    static let increaseFontSizeWithoutShift = NSUserInterfaceItemIdentifier(keyCommandPrefix + "view.increaseFontSize=")

    /// Whether the item belongs to a command whose shortcut the user sets.
    var isKeyCommand: Bool { rawValue.hasPrefix(Self.keyCommandPrefix) }

    fileprivate var keyCommandID: String? {
        isKeyCommand ? String(rawValue.dropFirst(Self.keyCommandPrefix.count)) : nil
    }
}

extension KeyCommand {
    /// The command a menu item runs, from its identifier.
    init?(menuItemIdentifier: NSUserInterfaceItemIdentifier) {
        guard let id = menuItemIdentifier.keyCommandID else { return nil }
        self.init(rawValue: id)
    }
}

extension KeyModifiers {
    /// Command, Option, Control and Shift of AppKit modifier flags; other flags are left out.
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        if contains(.shift) { flags.insert(.shift) }
        return flags
    }
}

extension KeyShortcut {
    /// The shortcut a key press records, or nil for a modifier key on its own or a key that types nothing. The key is
    /// the one the keyboard layout gives with no modifiers, so Shift-Command-[ is `mod+shift+[`, as menus spell it.
    init?(event: NSEvent) {
        guard event.type == .keyDown,
            let shortcut = KeyShortcut.recorded(
                keyCode: event.keyCode, character: event.characters(byApplyingModifiers: []),
                modifiers: KeyModifiers(event.modifierFlags))
        else { return nil }
        self = shortcut
    }

    /// A menu item's shortcut, or nil when it has none or needs the Function key, which shortcuts here can't hold.
    init?(menuItem: NSMenuItem) {
        guard !menuItem.keyEquivalent.isEmpty, !menuItem.keyEquivalentModifierMask.contains(.function) else { return nil }
        self.init(menuKeyEquivalent: menuItem.keyEquivalent, modifiers: KeyModifiers(menuItem.keyEquivalentModifierMask))
    }
}
