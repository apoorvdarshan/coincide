import AppKit
import CoincideKit
import SwiftUI

/// Keyboard shortcuts, as T3 Code's Keybindings settings: every menu command with its shortcut, changed by clicking
/// it and pressing new keys. Shortcuts that clash with another command, macOS or Coincide's fixed shortcuts are
/// marked. Keys that only work in one place (the composer, the terminal…) are listed after them and stay fixed.
struct KeyboardSettingsView: View {
    let model: SettingsModel
    @State private var fixedMenuShortcuts: [FixedMenuShortcut] = []
    @State private var filter = ""
    @State private var showsOnlyConflicts = false
    @State private var recording: KeyCommand?
    @State private var isConfirmingResetAll = false

    var body: some View {
        let bindings = model.settings.keyBindings
        let reserved = KeyBindingsController.reservedShortcuts(fixed: fixedMenuShortcuts)
        let conflicted = Set(bindings.commandsWithConflicts(reserved: reserved))
        let commandGroups = filteredCommandGroups(bindings: bindings, conflicted: conflicted)
        let fixedGroups = showsOnlyConflicts ? [] : filtered(otherMenuGroups + placeGroups)
        Form {
            Section {
                SettingsPaneHeader(title: String(localized: "Keyboard Shortcuts")) {
                    SettingsIconTile(symbol: SettingsSection.keyboard.symbolName, color: SettingsSection.keyboard.tint, size: 44)
                } subtitle: {
                    Text(
                        "Click a shortcut, then press the keys you want. Standard macOS shortcuts such as Copy and Close Window stay as they are."
                    )
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter", text: $filter, prompt: Text("Filter shortcuts"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                }
                if !conflicted.isEmpty || showsOnlyConflicts {
                    HStack {
                        Label {
                            Text(conflicted.isEmpty ? "No shortcuts conflict." : "Some shortcuts conflict.")
                        } icon: {
                            Image(systemName: conflicted.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(conflicted.isEmpty ? .green : .orange)
                        }
                        Spacer()
                        Toggle("Show only conflicts", isOn: $showsOnlyConflicts)
                            .toggleStyle(.checkbox)
                    }
                }
            }
            if !bindings.issues.isEmpty {
                ShortcutIssuesSection(issues: bindings.issues) {
                    model.update { $0.removeUnusableShortcuts() }
                }
            }
            if commandGroups.isEmpty && fixedGroups.isEmpty {
                Section {
                    if filter.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView("No Conflicts", systemImage: "checkmark.circle")
                    } else {
                        ContentUnavailableView.search(text: filter)
                    }
                }
            }
            ForEach(commandGroups) { group in
                Section {
                    ForEach(group.commands) { command in
                        let shortcut = bindings.shortcut(for: command)
                        let messages = messages(for: command, shortcut: shortcut, bindings: bindings, reserved: reserved)
                        KeyBindingRow(
                            command: command, shortcut: shortcut, isCustomized: bindings.isCustomized(command),
                            warnings: messages.warnings, notes: messages.notes, isRecording: recording == command,
                            onRecordingChange: { isRecording in
                                if isRecording {
                                    recording = command
                                } else if recording == command {
                                    recording = nil
                                }
                            },
                            onChange: { shortcut in model.update { $0.setShortcut(shortcut, for: command) } },
                            onReset: { model.update { $0.resetShortcut(for: command) } })
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
            if !commandGroups.isEmpty {
                Section {
                    HStack {
                        Text(
                            "When two commands share a shortcut, a changed one wins over a default one. Fixed menu shortcuts such as Copy keep their keys."
                        )
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset All…") { isConfirmingResetAll = true }
                            .disabled(model.settings.shortcutOverrides.isEmpty)
                    }
                }
            }
            ForEach(fixedGroups) { group in
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
                    Text("App Shortcuts added for Coincide in System Settings › Keyboard take priority over these.")
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
        .onAppear { fixedMenuShortcuts = KeyBindingsController.shared.fixedMenuShortcuts() }
        .alert("Reset all keyboard shortcuts?", isPresented: $isConfirmingResetAll) {
            Button("Reset All", role: .destructive) { model.update { $0.resetAllShortcuts() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every menu command goes back to its default shortcut.")
        }
    }

    // MARK: Commands

    /// Commands by menu, with Go to Thread 1–9 in a group of their own.
    private var allCommandGroups: [CommandGroup] {
        let groups = KeyCommand.Menu.allCases.map { menu in
            CommandGroup(
                title: menu.title, commands: KeyCommand.allCases.filter { $0.menu == menu && $0.threadJumpIndex == nil })
        }
        let held = threadJumpModifiers.map { $0.glyphs.joined() }
        let jumps = CommandGroup(
            title: String(localized: "Go to Thread"), commands: KeyCommand.allCases.filter { $0.threadJumpIndex != nil },
            note: held.isEmpty
                ? String(localized: "Threads are counted from the top of the sidebar.")
                : String(
                    localized: "Threads are counted from the top of the sidebar. Hold \(held.formatted(.list(type: .or))) to see their numbers."))
        return (groups + [jumps]).filter { !$0.commands.isEmpty }
    }

    /// The modifier keys that show the sidebar's thread numbers: those of the Go to Thread shortcuts.
    private var threadJumpModifiers: [KeyModifiers] {
        model.settings.keyBindings.threadJumpModifiers(keeping: Set(fixedMenuShortcuts.map(\.shortcut)))
    }

    private func filteredCommandGroups(bindings: KeyBindings, conflicted: Set<KeyCommand>) -> [CommandGroup] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return allCommandGroups.compactMap { group in
            let commands = group.commands.filter { command in
                if showsOnlyConflicts, !conflicted.contains(command) { return false }
                guard !query.isEmpty else { return true }
                let shortcut = bindings.shortcut(for: command)
                // Like T3's keybinding search: the name, the id and the keys.
                return [group.title, command.title, command.rawValue, shortcut?.displayString ?? "", shortcut?.stringValue ?? ""]
                    .contains { $0.localizedStandardContains(query) }
            }
            return commands.isEmpty ? nil : CommandGroup(title: group.title, commands: commands, note: group.note)
        }
    }

    /// Sentences about what else uses the command's shortcut: warnings, and notes on keys a focused terminal keeps.
    private func messages(
        for command: KeyCommand, shortcut: KeyShortcut?, bindings: KeyBindings, reserved: [ReservedShortcut]
    ) -> (warnings: [String], notes: [String]) {
        guard let shortcut else { return ([], []) }
        let keys = shortcut.displayString
        var warnings: [String] = []
        var notes: [String] = []
        for conflict in bindings.conflicts(for: command, reserved: reserved) {
            switch conflict {
            case .command(let other, runsInstead: true):
                warnings.append(String(localized: "\(keys) runs \(name(other.title)) instead."))
            case .command(let other, runsInstead: false):
                warnings.append(String(localized: "Also assigned to \(name(other.title))."))
            case .reserved(let reserved):
                switch reserved.owner {
                case .system:
                    warnings.append(String(localized: "macOS uses \(keys) for \(name(reserved.title))."))
                case .app:
                    // Menu items keep their shortcuts; keys the composer handles go to the menu command.
                    warnings.append(
                        fixedMenuShortcuts.contains { $0.title == reserved.title }
                            ? String(localized: "\(keys) stays with \(name(reserved.title)), so this command has no shortcut.")
                            : String(localized: "Takes \(keys) from \(name(reserved.title))."))
                case .focusedView:
                    notes.append(String(localized: "In a focused terminal, \(keys) does “\(reserved.title)” instead."))
                }
            }
        }
        return (warnings, notes)
    }

    /// A command or menu item's name inside a sentence, without the ellipsis its menu title may end with.
    private func name(_ title: String) -> String {
        title.hasSuffix("…") ? String(title.dropLast()) : title
    }

    // MARK: Fixed shortcuts

    /// Menu items with a fixed shortcut that aren't standard macOS commands, such as Settings.
    private var otherMenuGroups: [ShortcutGroup] {
        let shortcuts = fixedMenuShortcuts.filter { !ShortcutGroup.standardActions.contains($0.action) }.map {
            Shortcut($0.title, $0.shortcut.glyphs)
        }
        guard !shortcuts.isEmpty else { return [] }
        return [ShortcutGroup(title: String(localized: "Other Menu Commands"), shortcuts: shortcuts)]
    }

    /// Keys that work in one part of the window. Composer keys follow the "Send messages with" and "Follow-up behavior"
    /// settings.
    private var placeGroups: [ShortcutGroup] {
        let sendOnReturn = model.settings.sendOnReturn
        let steers = model.settings.followUpBehavior == .steer
        var composer = [
            Shortcut(
                steers
                    ? String(localized: "Send message, or steer the agent with it while it works")
                    : String(localized: "Send message, or queue it while the agent works"),
                sendOnReturn ? ["↩"] : ["⌘", "↩"]),
            Shortcut(
                steers
                    ? String(localized: "Queue the message instead while the agent works")
                    : String(localized: "Steer the agent with the message instead while it works"),
                sendOnReturn ? ["⌘", "↩"] : ["⇧", "⌘", "↩"]),
        ]
        if sendOnReturn {
            composer.append(Shortcut(String(localized: "Send the first queued message into the current turn"), ["⇧", "⌘", "↩"]))
        }
        composer += [
            Shortcut(String(localized: "Insert new line"), sendOnReturn ? ["⇧", "↩"] : ["↩"]),
            Shortcut(String(localized: "Switch between Build and Plan"), ["⇧", "⇥"]),
            Shortcut(String(localized: "Earlier and later messages you sent"), ["↑"], or: ["↓"]),
            Shortcut(String(localized: "Edit the last queued message"), ["⌥", "↑"]),
            Shortcut(String(localized: "Insert the highlighted file or command"), ["⇥"]),
            Shortcut(String(localized: "Close file and command suggestions"), ["⎋"]),
        ]
        return [
            ShortcutGroup(
                title: String(localized: "Composer"), shortcuts: composer,
                note: String(localized: "Type @ to mention a file and / for commands.")),
            ShortcutGroup(
                title: String(localized: "Sidebar"),
                shortcuts: [
                    Shortcut(String(localized: "Move to the composer"), ["↩"]),
                    Shortcut(String(localized: "Delete thread"), ["⌫"]),
                ]
                    + (threadJumpModifiers.isEmpty
                        ? []
                        : [
                            Shortcut(
                                String(localized: "Show thread numbers for Go to Thread"),
                                threadJumpModifiers.map { [String(localized: "Hold")] + $0.glyphs })
                        ])),
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
                shortcuts: KeyBindingsController.terminalKeys.map { entry in
                    Shortcut(entry.title, entry.shortcuts.map(\.glyphs))
                },
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

private struct CommandGroup: Identifiable {
    let title: String
    let commands: [KeyCommand]
    var note: String?

    var id: String { title }
}

/// One fixed shortcut: one or two key combinations, as key caps.
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

    init(_ title: String, _ combos: [[String]]) {
        self.title = title
        self.combos = combos
    }

    var id: String { title + combos.flatMap(\.self).joined() }
}

private struct ShortcutGroup: Identifiable {
    let title: String
    let shortcuts: [Shortcut]
    var note: String?

    var id: String { title }

    /// Standard macOS commands every app has; the pane lists Coincide's own commands.
    static let standardActions: Set<String> = [
        "undo:", "redo:", "cut:", "copy:", "paste:", "pasteAsPlainText:", "pasteAndMatchStyle:", "delete:",
        "selectAll:", "performFindPanelAction:", "performTextFinderAction:", "centerSelectionInVisibleArea:",
        "showGuessPanel:", "checkSpelling:", "toggleContinuousSpellChecking:", "startSpeaking:", "stopSpeaking:",
        "orderFrontCharacterPalette:", "hide:", "hideOtherApplications:", "unhideAllApplications:", "terminate:",
        "orderFrontStandardAboutPanel:", "showHelp:", "performClose:", "closeAll:", "performMiniaturize:", "performZoom:",
        "toggleFullScreen:", "arrangeInFront:", "selectNextTab:", "selectPreviousTab:", "toggleTabBar:",
        "toggleTabOverview:", "mergeAllWindows:", "moveTabToNewWindow:", "runPageLayout:", "print:",
    ]

    /// Key glyphs read out by name, for VoiceOver.
    static func spoken(_ keys: [String]) -> String {
        keys.map { key in
            switch key {
            case "⌘": String(localized: "key.command", defaultValue: "Command", comment: "Spoken name of the ⌘ key")
            case "⇧": String(localized: "Shift")
            case "⌥": String(localized: "Option")
            case "⌃": String(localized: "Control")
            case "↩": String(localized: "Return")
            case "⌤": String(localized: "Enter")
            case "⎋": String(localized: "Escape")
            case "⇥": String(localized: "Tab")
            case "⌫": String(localized: "key.delete", defaultValue: "Delete", comment: "Spoken name of the ⌫ key")
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
