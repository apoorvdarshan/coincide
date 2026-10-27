import AppKit
import CoincideKit
import SwiftUI

/// Keyboard shortcuts, read from the menu bar so the list always matches what the app does.
struct KeyboardSettingsView: View {
    let model: SettingsModel
    @State private var menuGroups: [ShortcutGroup] = []
    @State private var filter = ""

    var body: some View {
        let groups = filtered([composerGroup] + menuGroups)
        Form {
            Section {
                SettingsPaneHeader(title: String(localized: "Keyboard Shortcuts")) {
                    SettingsIconTile(symbol: SettingsSection.keyboard.symbolName, color: SettingsSection.keyboard.tint, size: 44)
                } subtitle: {
                    Text("Shortcuts for Coincide’s commands. Standard macOS shortcuts such as Copy and Close Window work as usual.")
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter", text: $filter, prompt: Text("Filter shortcuts"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                }
            }
            if groups.isEmpty {
                Section {
                    ContentUnavailableView.search(text: filter)
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.shortcuts) { shortcut in
                        LabeledContent {
                            SettingsKeyCaps(keys: shortcut.keys)
                        } label: {
                            Text(shortcut.title)
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }
            Section {
                HStack {
                    Text("To change a menu shortcut, add an App Shortcut for Coincide in System Settings › Keyboard.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Keyboard Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { menuGroups = ShortcutGroup.menuGroups(NSApp.mainMenu) }
    }

    /// Composer keys follow the "Send messages with" setting.
    private var composerGroup: ShortcutGroup {
        let sendOnReturn = model.settings.sendOnReturn
        return ShortcutGroup(
            title: String(localized: "Composer"),
            shortcuts: [
                Shortcut(title: String(localized: "Send message"), keys: sendOnReturn ? ["↩"] : ["⌘", "↩"]),
                Shortcut(title: String(localized: "Insert new line"), keys: sendOnReturn ? ["⇧", "↩"] : ["↩"]),
            ])
    }

    private func filtered(_ groups: [ShortcutGroup]) -> [ShortcutGroup] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let matches = group.shortcuts.filter {
                $0.title.localizedStandardContains(query) || $0.keys.joined().localizedStandardContains(query)
                    || group.title.localizedStandardContains(query)
            }
            return matches.isEmpty ? nil : ShortcutGroup(title: group.title, shortcuts: matches)
        }
    }
}

private struct Shortcut: Identifiable {
    let title: String
    let keys: [String]

    var id: String { title + keys.joined() }
}

private struct ShortcutGroup: Identifiable {
    let title: String
    let shortcuts: [Shortcut]

    var id: String { title }

    /// Standard macOS commands every app has; the pane lists Coincide's own commands.
    private static let standardActions: Set<String> = [
        "undo:", "redo:", "cut:", "copy:", "paste:", "pasteAsPlainText:", "pasteAndMatchStyle:", "delete:",
        "selectAll:", "performFindPanelAction:", "performTextFinderAction:", "centerSelectionInVisibleArea:",
        "showGuessPanel:", "checkSpelling:", "toggleContinuousSpellChecking:", "startSpeaking:", "stopSpeaking:",
        "orderFrontCharacterPalette:", "hide:", "hideOtherApplications:", "unhideAllApplications:", "terminate:",
        "orderFrontStandardAboutPanel:", "showHelp:", "performClose:", "performMiniaturize:", "performZoom:",
        "toggleFullScreen:", "arrangeInFront:", "selectNextTab:", "selectPreviousTab:", "toggleTabBar:",
        "toggleTabOverview:", "mergeAllWindows:", "moveTabToNewWindow:", "runPageLayout:", "print:",
    ]

    /// One group per top-level menu, listing every item with a key equivalent.
    static func menuGroups(_ menu: NSMenu?) -> [ShortcutGroup] {
        guard let menu else { return [] }
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Coincide"
        return menu.items.enumerated().compactMap { index, item in
            guard let submenu = item.submenu else { return nil }
            var shortcuts: [Shortcut] = []
            collect(submenu, path: [], into: &shortcuts)
            guard !shortcuts.isEmpty else { return nil }
            let title = index == 0 ? appName : (item.title.isEmpty ? submenu.title : item.title)
            return ShortcutGroup(title: title, shortcuts: shortcuts)
        }
    }

    private static func collect(_ menu: NSMenu, path: [String], into shortcuts: inout [Shortcut]) {
        guard menu !== NSApp.servicesMenu else { return }
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                collect(submenu, path: path + [item.title], into: &shortcuts)
            } else if !item.keyEquivalent.isEmpty, !item.title.isEmpty,
                !standardActions.contains(item.action.map(NSStringFromSelector) ?? "")
            {
                let title = (path + [item.title]).joined(separator: " › ")
                let shortcut = Shortcut(title: title, keys: keys(item.keyEquivalent, item.keyEquivalentModifierMask))
                if !shortcuts.contains(where: { $0.id == shortcut.id }) { shortcuts.append(shortcut) }
            }
        }
    }

    /// Modifier glyphs in Apple's order (⌃ ⌥ ⇧ ⌘) followed by the key.
    static func keys(_ keyEquivalent: String, _ modifiers: NSEvent.ModifierFlags) -> [String] {
        var modifiers = modifiers
        if keyEquivalent.count == 1, keyEquivalent.first?.isUppercase == true { modifiers.insert(.shift) }
        var keys: [String] = []
        if modifiers.contains(.function) { keys.append("fn") }
        if modifiers.contains(.control) { keys.append("⌃") }
        if modifiers.contains(.option) { keys.append("⌥") }
        if modifiers.contains(.shift) { keys.append("⇧") }
        if modifiers.contains(.command) { keys.append("⌘") }
        keys.append(glyph(keyEquivalent))
        return keys
    }

    private static func glyph(_ key: String) -> String {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return key.uppercased() }
        switch Int(scalar.value) {
        case 0x0D: return "↩"
        case 0x03: return "⌤"
        case 0x1B: return "⎋"
        case 0x09: return "⇥"
        case 0x19: return "⇤"
        case 0x08, 0x7F: return "⌫"
        case 0x20: return String(localized: "Space")
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSDeleteFunctionKey: return "⌦"
        case NSHomeFunctionKey: return "↖"
        case NSEndFunctionKey: return "↘"
        case NSPageUpFunctionKey: return "⇞"
        case NSPageDownFunctionKey: return "⇟"
        case NSF1FunctionKey...NSF35FunctionKey: return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        default: return key.uppercased()
        }
    }
}
