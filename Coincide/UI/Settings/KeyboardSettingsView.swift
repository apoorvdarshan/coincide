import AppKit
import CoincideKit
import SwiftUI

/// Keyboard shortcuts. Menu shortcuts are read from the menu bar, so the list always matches what the
/// app does; keys that only work in one place (the composer, the terminal…) are listed with them.
struct KeyboardSettingsView: View {
    let model: SettingsModel
    @State private var menuGroups: [ShortcutGroup] = []
    @State private var filter = ""

    var body: some View {
        let groups = filtered(menuGroups + placeGroups)
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
                            ShortcutKeys(combos: shortcut.combos)
                        } label: {
                            Text(shortcut.title)
                        }
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if let note = group.note {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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

    /// Keys that work in one part of the window. Composer keys follow the "Send messages with" setting.
    private var placeGroups: [ShortcutGroup] {
        let sendOnReturn = model.settings.sendOnReturn
        return [
            ShortcutGroup(
                title: String(localized: "Composer"),
                shortcuts: [
                    Shortcut(String(localized: "Send message, or queue it while the agent works"), sendOnReturn ? ["↩"] : ["⌘", "↩"]),
                    Shortcut(String(localized: "Insert new line"), sendOnReturn ? ["⇧", "↩"] : ["↩"]),
                    Shortcut(String(localized: "Switch between Build and Plan"), ["⇧", "⇥"]),
                    Shortcut(String(localized: "Earlier and later messages you sent"), ["↑"], or: ["↓"]),
                    Shortcut(String(localized: "Edit the last queued message"), ["⌥", "↑"]),
                    Shortcut(String(localized: "Insert the highlighted file or command"), ["⇥"]),
                    Shortcut(String(localized: "Close file and command suggestions"), ["⎋"]),
                ],
                note: String(localized: "Type @ to mention a file and / for commands.")),
            ShortcutGroup(
                title: String(localized: "Sidebar"),
                shortcuts: [
                    Shortcut(String(localized: "Move to the composer"), ["↩"]),
                    Shortcut(String(localized: "Delete thread"), ["⌫"]),
                    Shortcut(String(localized: "Show thread numbers for ⌘1…⌘9"), [String(localized: "Hold"), "⌘"]),
                ]),
            ShortcutGroup(
                title: String(localized: "Conversation"),
                shortcuts: [
                    Shortcut(String(localized: "Expand or collapse the selected entry"), ["→"], or: ["←"]),
                    Shortcut(String(localized: "Open or close the selected entry"), [String(localized: "Space")], or: ["↩"]),
                    Shortcut(String(localized: "Copy the selected entry"), ["⌘", "C"]),
                    Shortcut(String(localized: "Back to the composer"), ["⎋"]),
                    Shortcut(String(localized: "Find in the thread"), ["⌘", "F"]),
                    Shortcut(String(localized: "Next and previous match"), ["⌘", "G"], or: ["⇧", "⌘", "G"]),
                    Shortcut(String(localized: "Close the find bar"), ["⎋"]),
                ],
                note: String(localized: "Typing while the conversation has focus goes to the composer.")),
            ShortcutGroup(
                title: String(localized: "Terminal"),
                shortcuts: [
                    Shortcut(String(localized: "New terminal"), ["⌘", "T"], or: ["⌘", "N"]),
                    Shortcut(String(localized: "Split right"), ["⌘", "D"]),
                    Shortcut(String(localized: "Split down"), ["⇧", "⌘", "D"]),
                    Shortcut(String(localized: "Close terminal"), ["⌘", "W"]),
                    Shortcut(String(localized: "Clear"), ["⌘", "K"]),
                    Shortcut(String(localized: "Previous and next terminal tab"), ["⇧", "⌘", "["], or: ["⇧", "⌘", "]"]),
                    Shortcut(String(localized: "Previous and next pane"), ["⌥", "⌘", "←"], or: ["⌥", "⌘", "→"]),
                    Shortcut(String(localized: "Move to the start or end of the line"), ["⌘", "←"], or: ["⌘", "→"]),
                    Shortcut(String(localized: "Move by word"), ["⌥", "←"], or: ["⌥", "→"]),
                ],
                note: String(
                    localized: "While a terminal has focus these keys act on it instead of the menu commands they share, as in T3 Code.")),
            ShortcutGroup(
                title: String(localized: "Command Palette"),
                shortcuts: [
                    Shortcut(String(localized: "Choose a result"), ["↑"], or: ["↓"]),
                    Shortcut(String(localized: "Run the chosen result"), ["↩"]),
                    Shortcut(String(localized: "Complete a folder path"), ["⇥"]),
                    Shortcut(String(localized: "Back to the previous list"), ["⌫"]),
                    Shortcut(String(localized: "Close"), ["⎋"]),
                ],
                note: String(localized: "Start with / or ~ to add a folder as a project.")),
        ]
    }

    private func filtered(_ groups: [ShortcutGroup]) -> [ShortcutGroup] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let matches = group.shortcuts.filter {
                $0.title.localizedStandardContains(query) || $0.combos.flatMap(\.self).joined().localizedStandardContains(query)
                    || group.title.localizedStandardContains(query)
            }
            return matches.isEmpty ? nil : ShortcutGroup(title: group.title, shortcuts: matches, note: group.note)
        }
    }
}

/// One or two key combinations, as key caps.
private struct ShortcutKeys: View {
    let combos: [[String]]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(combos.enumerated()), id: \.offset) { index, keys in
                if index > 0 {
                    Text("or")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SettingsKeyCaps(keys: keys)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combos.map(ShortcutGroup.spoken).formatted(.list(type: .or)))
    }
}

private struct Shortcut: Identifiable {
    let title: String
    /// Alternatives, each a list of keys pressed together.
    let combos: [[String]]

    init(_ title: String, _ keys: [String], or alternative: [String]? = nil) {
        self.title = title
        combos = [keys] + (alternative.map { [$0] } ?? [])
    }

    var id: String { title + combos.flatMap(\.self).joined() }
}

private struct ShortcutGroup: Identifiable {
    let title: String
    let shortcuts: [Shortcut]
    var note: String?

    var id: String { title }

    /// Standard macOS commands every app has; the pane lists Coincide's own commands.
    private static let standardActions: Set<String> = [
        "undo:", "redo:", "cut:", "copy:", "paste:", "pasteAsPlainText:", "pasteAndMatchStyle:", "delete:",
        "selectAll:", "performFindPanelAction:", "performTextFinderAction:", "centerSelectionInVisibleArea:",
        "showGuessPanel:", "checkSpelling:", "toggleContinuousSpellChecking:", "startSpeaking:", "stopSpeaking:",
        "orderFrontCharacterPalette:", "hide:", "hideOtherApplications:", "unhideAllApplications:", "terminate:",
        "orderFrontStandardAboutPanel:", "showHelp:", "performClose:", "closeAll:", "performMiniaturize:", "performZoom:",
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
        for item in menu.items where !item.isSeparatorItem && !item.isAlternate {
            let action = item.action.map(NSStringFromSelector) ?? ""
            // Command-1 … Command-9 are hidden items; list them once.
            if action == "jumpToThread:" {
                if item.tag == 1 {
                    shortcuts.append(Shortcut(String(localized: "Go to Thread 1–9"), ["⌘", "1…9"]))
                }
                continue
            }
            guard !item.isHidden else { continue }
            if let submenu = item.submenu {
                collect(submenu, path: path + [item.title], into: &shortcuts)
            } else if !item.keyEquivalent.isEmpty, !item.title.isEmpty, !standardActions.contains(action) {
                let title = (path + [item.title]).joined(separator: " › ")
                let shortcut = Shortcut(title, keys(item.keyEquivalent, item.keyEquivalentModifierMask))
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

    /// Key glyphs read out by name, for VoiceOver.
    static func spoken(_ keys: [String]) -> String {
        keys.map { key in
            switch key {
            case "⌘": String(localized: "Command")
            case "⇧": String(localized: "Shift")
            case "⌥": String(localized: "Option")
            case "⌃": String(localized: "Control")
            case "↩": String(localized: "Return")
            case "⌤": String(localized: "Enter")
            case "⎋": String(localized: "Escape")
            case "⇥": String(localized: "Tab")
            case "⌫": String(localized: "Delete")
            case "⌦": String(localized: "Forward Delete")
            case "↑": String(localized: "Up Arrow")
            case "↓": String(localized: "Down Arrow")
            case "←": String(localized: "Left Arrow")
            case "→": String(localized: "Right Arrow")
            default: key
            }
        }.joined(separator: " ")
    }
}
