import Foundation
import Testing

@testable import CoincideKit

struct KeyShortcutParsingTests {
    @Test func readsT3KeybindingSyntax() throws {
        let shortcut = try #require(KeyShortcut("mod+shift+k"))
        #expect(shortcut.key == "k")
        #expect(shortcut.modifiers == [.command, .shift])
        #expect(KeyShortcut("Mod+Shift+K") == shortcut)
        #expect(KeyShortcut("shift+mod+k") == shortcut)
        #expect(KeyShortcut(" mod + shift + k ") == shortcut)
        for command in ["cmd+k", "command+k", "meta+k"] {
            #expect(KeyShortcut(command) == KeyShortcut("mod+k"), "\(command)")
        }
        #expect(KeyShortcut("control+option+f5") == KeyShortcut("ctrl+alt+f5"))
        #expect(KeyShortcut("ctrl+alt+f5")?.modifiers == [.control, .option])
    }

    @Test func plusIsAKeyAtTheEnd() {
        #expect(KeyShortcut("mod++") == KeyShortcut(key: "+", modifiers: .command))
        #expect(KeyShortcut("+") == KeyShortcut(key: "+"))
        #expect(KeyShortcut("mod+-")?.key == "-")
        #expect(KeyShortcut("mod++k") == nil)
    }

    @Test func keyNamesAndAliases() {
        #expect(KeyShortcut("mod+escape")?.key == "esc")
        #expect(KeyShortcut("mod+esc")?.key == "esc")
        #expect(KeyShortcut("mod+return")?.key == "enter")
        #expect(KeyShortcut("ctrl+space")?.key == "space")
        #expect(KeyShortcut("mod+arrowup")?.key == "arrowup")
        #expect(KeyShortcut("f20")?.key == "f20")
        #expect(KeyShortcut(key: " ", modifiers: .command)?.key == "space")
    }

    @Test func rejectsWhatIsNotOneKey() {
        for text in ["", "   ", "mod", "mod+shift", "mod+k+j", "mod+foo", "mod+f21", "mod+f0", "mod+f01", "mod+ +k", "fn+k"] {
            #expect(KeyShortcut(text) == nil, "\(text)")
        }
        #expect(KeyShortcut(key: "\u{7}") == nil)
        #expect(KeyShortcut(key: "\u{F700}") == nil)
        #expect(KeyShortcut(key: "ab") == nil)
    }

    @Test func writesCanonicalTextThatReadsBack() throws {
        let shortcut = try #require(KeyShortcut("shift+alt+ctrl+mod+k"))
        #expect(shortcut.stringValue == "mod+ctrl+alt+shift+k")
        #expect(shortcut.description == shortcut.stringValue)
        #expect(KeyShortcut("mod++")?.stringValue == "mod++")
        #expect(KeyShortcut("mod+escape")?.stringValue == "mod+esc")
        var samples = KeyCommand.allCases.compactMap(\.defaultShortcut) + ReservedShortcut.macOS.map(\.shortcut)
        samples += ["mod+space", "ctrl+delete", "mod+backspace", "alt+pagedown", "f12", "mod+shift+/"].compactMap(KeyShortcut.init)
        for sample in samples {
            #expect(KeyShortcut(sample.stringValue) == sample, "\(sample)")
        }
    }
}

struct KeyShortcutFormattingTests {
    @Test func showsGlyphsInAppleOrder() {
        #expect(KeyShortcut("mod+shift+k")?.displayString == "⇧⌘K")
        #expect(KeyShortcut("mod+ctrl+alt+shift+k")?.glyphs == ["⌃", "⌥", "⇧", "⌘", "K"])
        #expect(KeyShortcut("mod+enter")?.displayString == "⌘↩")
        #expect(KeyShortcut("ctrl+f5")?.displayString == "⌃F5")
        #expect(KeyShortcut("mod+.")?.displayString == "⌘.")
        #expect(KeyShortcut("mod+shift+[")?.displayString == "⇧⌘[")
        #expect(KeyShortcut("mod+space")?.displayString == "⌘Space")
        #expect(KeyShortcut("alt+arrowleft")?.displayString == "⌥←")
        #expect(KeyShortcut("mod+backspace")?.displayString == "⌘⌫")
        #expect(KeyShortcut("mod+delete")?.displayString == "⌘⌦")
    }

    @Test func modifiersAloneShowTheirGlyphsInAppleOrder() {
        #expect(KeyModifiers([.command, .shift, .control, .option]).glyphs == ["⌃", "⌥", "⇧", "⌘"])
        #expect(KeyModifiers.command.glyphs == ["⌘"])
        #expect(KeyModifiers().glyphs.isEmpty)
    }

    @Test func readsOutKeysByName() {
        #expect(KeyShortcut("mod+shift+k")?.spokenDescription == "Shift Command K")
        #expect(KeyShortcut("ctrl+alt+arrowup")?.spokenDescription == "Control Option Up Arrow")
        #expect(KeyShortcut("mod+enter")?.spokenDescription == "Command Return")
    }

    @Test func menusNeedCommandOrControlUnlessFunctionKey() {
        #expect(KeyShortcut("mod+k")?.isUsableInMenus == true)
        #expect(KeyShortcut("ctrl+k")?.isUsableInMenus == true)
        #expect(KeyShortcut("f5")?.isUsableInMenus == true)
        #expect(KeyShortcut("shift+f5")?.isUsableInMenus == true)
        #expect(KeyShortcut("k")?.isUsableInMenus == false)
        #expect(KeyShortcut("shift+k")?.isUsableInMenus == false)
        #expect(KeyShortcut("alt+arrowup")?.isUsableInMenus == false)
    }
}

struct KeyShortcutMenuTests {
    @Test func spellsKeyEquivalentsTheWayAppKitDoes() {
        #expect(KeyShortcut("mod+k")?.menuKeyEquivalent == "k")
        #expect(KeyShortcut("mod+shift+k")?.menuKeyEquivalent == "k")
        #expect(KeyShortcut("mod+enter")?.menuKeyEquivalent == "\r")
        #expect(KeyShortcut("mod+tab")?.menuKeyEquivalent == "\t")
        #expect(KeyShortcut("mod+space")?.menuKeyEquivalent == " ")
        #expect(KeyShortcut("mod+esc")?.menuKeyEquivalent == "\u{1B}")
        #expect(KeyShortcut("mod+backspace")?.menuKeyEquivalent == "\u{8}")
        #expect(KeyShortcut("mod+delete")?.menuKeyEquivalent == "\u{F728}")
        #expect(KeyShortcut("mod+arrowup")?.menuKeyEquivalent == "\u{F700}")
        #expect(KeyShortcut("f1")?.menuKeyEquivalent == "\u{F704}")
        #expect(KeyShortcut("f20")?.menuKeyEquivalent == "\u{F717}")
    }

    @Test func readsMenuKeyEquivalents() {
        #expect(KeyShortcut(menuKeyEquivalent: "K", modifiers: .command) == KeyShortcut("mod+shift+k"))
        #expect(KeyShortcut(menuKeyEquivalent: "[", modifiers: [.command, .shift]) == KeyShortcut("mod+shift+["))
        #expect(KeyShortcut(menuKeyEquivalent: "\r", modifiers: .command) == KeyShortcut("mod+enter"))
        #expect(KeyShortcut(menuKeyEquivalent: "\u{3}", modifiers: .command) == KeyShortcut("mod+enter"))
        #expect(KeyShortcut(menuKeyEquivalent: "\u{7F}", modifiers: .command) == KeyShortcut("mod+backspace"))
        #expect(KeyShortcut(menuKeyEquivalent: "\u{F708}", modifiers: []) == KeyShortcut("f5"))
        #expect(KeyShortcut(menuKeyEquivalent: "", modifiers: .command) == nil)
        #expect(KeyShortcut(menuKeyEquivalent: "ab", modifiers: .command) == nil)
        let keys = ["enter", "tab", "space", "esc", "backspace", "delete", "arrowup", "arrowdown", "arrowleft", "arrowright",
            "home", "end", "pageup", "pagedown"] + (1...20).map { "f\($0)" } + ["k", "1", "[", "+", "."]
        for key in keys {
            let shortcut = KeyShortcut(key: key, modifiers: [.command, .option])
            #expect(shortcut.flatMap { KeyShortcut(menuKeyEquivalent: $0.menuKeyEquivalent, modifiers: $0.modifiers) } == shortcut, "\(key)")
        }
    }

    @Test func recordsKeyPresses() {
        // kVK_ANSI_K, kVK_Return, kVK_Command, kVK_F1, kVK_ANSI_LeftBracket.
        #expect(KeyShortcut.recorded(keyCode: 0x28, character: "k", modifiers: [.command, .shift]) == KeyShortcut("mod+shift+k"))
        #expect(KeyShortcut.recorded(keyCode: 0x28, character: "K", modifiers: .command) == KeyShortcut("mod+k"))
        #expect(KeyShortcut.recorded(keyCode: 0x21, character: "[", modifiers: [.command, .shift]) == KeyShortcut("mod+shift+["))
        // kVK_ANSI_F with Option: the key's own character, not the "ƒ" Option types.
        #expect(KeyShortcut.recorded(keyCode: 0x03, character: "f", modifiers: [.command, .option]) == KeyShortcut("mod+alt+f"))
        #expect(KeyShortcut.recorded(keyCode: 0x31, character: " ", modifiers: .control) == KeyShortcut("ctrl+space"))
        #expect(KeyShortcut.recorded(keyCode: 0x24, character: "\r", modifiers: .command) == KeyShortcut("mod+enter"))
        #expect(KeyShortcut.recorded(keyCode: 0x4C, character: "\u{3}", modifiers: .command) == KeyShortcut("mod+enter"))
        #expect(KeyShortcut.recorded(keyCode: 0x7A, character: "\u{F704}", modifiers: []) == KeyShortcut("f1"))
        #expect(KeyShortcut.recorded(keyCode: 0x7E, character: nil, modifiers: .control) == KeyShortcut("ctrl+arrowup"))
        #expect(KeyShortcut.recorded(keyCode: 0x37, character: "", modifiers: .command) == nil)
        #expect(KeyShortcut.recorded(keyCode: 0x38, character: nil, modifiers: .shift) == nil)
        #expect(KeyShortcut.recorded(keyCode: 0x28, character: "", modifiers: .command) == nil)
        #expect(KeyShortcut.recorded(keyCode: 0x28, character: nil, modifiers: .command) == nil)
    }
}

struct KeyCommandTests {
    @Test func defaultsAreUsableDistinctAndFreeOfMacOSShortcuts() {
        let defaults = KeyCommand.allCases.compactMap(\.defaultShortcut)
        #expect(defaults.count == 27)
        #expect(Set(defaults).count == defaults.count)
        #expect(defaults.allSatisfy { $0.isUsableInMenus })
        let reserved = Set(ReservedShortcut.macOS.map(\.shortcut))
        #expect(reserved.isDisjoint(with: defaults))
        #expect(KeyBindings().commandsWithConflicts(reserved: ReservedShortcut.macOS).isEmpty)
    }

    @Test func defaultsMatchT3WhereT3HasTheCommand() {
        #expect(KeyCommand.newThread.defaultShortcut == KeyShortcut("mod+n"))
        #expect(KeyCommand.toggleSidebar.defaultShortcut == KeyShortcut("mod+b"))
        #expect(KeyCommand.toggleTerminal.defaultShortcut == KeyShortcut("mod+j"))
        #expect(KeyCommand.commandPalette.defaultShortcut == KeyShortcut("mod+k"))
        #expect(KeyCommand.chooseModel.defaultShortcut == KeyShortcut("mod+shift+m"))
        #expect(KeyCommand.increaseFontSize.defaultShortcut == KeyShortcut("mod++"))
        #expect(KeyCommand.planMode.defaultShortcut == nil)
        #expect(KeyCommand.newThread.rawValue == "chat.new")
        #expect(KeyCommand.accessMode.rawValue == "composer.mode")
    }

    @Test func threadJumpsAreNumbered() {
        for index in 1...9 {
            let command = KeyCommand.jumpToThread(index)
            #expect(command?.threadJumpIndex == index)
            #expect(command?.defaultShortcut == KeyShortcut("mod+\(index)"))
            #expect(command?.menu == .thread)
        }
        #expect(KeyCommand.jumpToThread(0) == nil)
        #expect(KeyCommand.jumpToThread(10) == nil)
        #expect(KeyCommand.stopTurn.threadJumpIndex == nil)
    }

    @Test func commandsAreGroupedByMenuInMenuBarOrder() {
        let menus = KeyCommand.allCases.map(\.menu)
        let order = KeyCommand.Menu.allCases
        #expect(menus == menus.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
        #expect(Set(KeyCommand.allCases.map(\.title)).count == KeyCommand.allCases.count)
    }
}

struct KeyBindingsTests {
    @Test func defaultsApplyWithoutOverrides() {
        let bindings = KeyBindings()
        #expect(bindings.shortcut(for: .stopTurn) == KeyShortcut("mod+."))
        #expect(bindings.shortcut(for: .renameThread) == nil)
        #expect(bindings.customized.isEmpty)
        #expect(bindings.issues.isEmpty)
        for command in KeyCommand.allCases {
            #expect(bindings.menuShortcut(for: command) == command.defaultShortcut)
        }
    }

    @Test func overridesChangeAndRemoveShortcuts() {
        let bindings = KeyBindings(overrides: [
            "thread.stop": "mod+shift+.", "sidebar.toggle": "", "thread.rename": "ctrl+r", "composer.planMode": "",
            "chat.new": "Mod+N",
        ])
        #expect(bindings.shortcut(for: .stopTurn) == KeyShortcut("mod+shift+."))
        #expect(bindings.shortcut(for: .toggleSidebar) == nil)
        #expect(bindings.shortcut(for: .renameThread) == KeyShortcut("ctrl+r"))
        #expect(bindings.shortcut(for: .newThread) == KeyShortcut("mod+n"))
        // Removing a shortcut a command never had, or choosing its default, changes nothing.
        #expect(bindings.customized == [.stopTurn, .toggleSidebar, .renameThread])
    }

    @Test func unusableOverridesKeepTheDefaultAndAreReported() {
        let bindings = KeyBindings(overrides: [
            "thread.stop": "mod+banana", "thread.pin": "p", "thread.explode": "mod+e", "sidebar.toggle": "mod+shift+b",
        ])
        #expect(bindings.shortcut(for: .stopTurn) == KeyCommand.stopTurn.defaultShortcut)
        #expect(bindings.shortcut(for: .pinThread) == KeyCommand.pinThread.defaultShortcut)
        #expect(bindings.customized == [.toggleSidebar])
        #expect(
            bindings.issues == [
                KeyBindings.Issue(commandID: "thread.explode", value: "mod+e", reason: .unknownCommand),
                KeyBindings.Issue(commandID: "thread.pin", value: "p", reason: .needsCommandOrControl),
                KeyBindings.Issue(commandID: "thread.stop", value: "mod+banana", reason: .unreadable),
            ])
    }

    @Test func aChangedShortcutWinsOverADefaultOne() {
        let bindings = KeyBindings(overrides: ["thread.rename": "mod+k"])
        let commandK = KeyShortcut("mod+k")!
        #expect(bindings.commands(using: commandK) == [.commandPalette, .renameThread])
        #expect(bindings.command(runBy: commandK) == .renameThread)
        #expect(bindings.menuShortcut(for: .renameThread) == commandK)
        #expect(bindings.menuShortcut(for: .commandPalette) == nil)
        #expect(bindings.shortcut(for: .commandPalette) == commandK)
        #expect(bindings.conflicts(for: .commandPalette, reserved: []) == [.command(.renameThread, runsInstead: true)])
        #expect(bindings.conflicts(for: .renameThread, reserved: []) == [.command(.commandPalette, runsInstead: false)])
        #expect(bindings.commandsWithConflicts(reserved: []) == [.commandPalette, .renameThread])
    }

    @Test func amongChangedShortcutsTheEarlierMenuItemWins() {
        let bindings = KeyBindings(overrides: ["thread.archive": "mod+shift+r", "thread.rename": "mod+shift+r"])
        let shortcut = KeyShortcut("mod+shift+r")!
        #expect(bindings.command(runBy: shortcut) == .renameThread)
        #expect(bindings.menuShortcut(for: .archiveThread) == nil)
        #expect(bindings.conflicts(for: .archiveThread, reserved: []) == [.command(.renameThread, runsInstead: true)])
    }

    @Test func aRemovedShortcutFreesItsKeys() {
        let bindings = KeyBindings(overrides: ["commandPalette.toggle": "", "thread.rename": "mod+k"])
        let commandK = KeyShortcut("mod+k")!
        #expect(bindings.shortcut(for: .commandPalette) == nil)
        #expect(bindings.menuShortcut(for: .commandPalette) == nil)
        #expect(bindings.conflicts(for: .commandPalette, reserved: ReservedShortcut.macOS).isEmpty)
        #expect(bindings.commands(using: commandK) == [.renameThread])
        #expect(bindings.conflicts(for: .renameThread, reserved: []).isEmpty)
        #expect(bindings.command(runBy: KeyShortcut("mod+shift+k")!) == nil)
        #expect(bindings.customized == [.commandPalette, .renameThread])
    }

    @Test func fixedMenuItemsKeepTheirShortcuts() {
        let bindings = KeyBindings(overrides: ["project.add": "mod+c", "thread.rename": "mod+w"])
        let fixed: Set<KeyShortcut> = [KeyShortcut("mod+c")!, KeyShortcut("mod+w")!]
        #expect(bindings.shortcut(for: .addProject) == KeyShortcut("mod+c"))
        #expect(bindings.menuShortcut(for: .addProject, keeping: fixed) == nil)
        #expect(bindings.menuShortcut(for: .renameThread, keeping: fixed) == nil)
        #expect(bindings.menuShortcut(for: .addProject) == KeyShortcut("mod+c"))
        #expect(bindings.menuShortcut(for: .newThread, keeping: fixed) == KeyShortcut("mod+n"))
    }

    @Test func threadNumbersShowForTheModifiersOfTheJumpShortcuts() {
        #expect(KeyBindings().threadJumpModifiers() == [.command])
        // Each set of modifiers once, in the commands' order.
        let mixed = KeyBindings(overrides: ["thread.jump.2": "ctrl+2", "thread.jump.3": "ctrl+3", "thread.jump.5": "mod+shift+5"])
        #expect(mixed.threadJumpModifiers() == [.command, .control, [.command, .shift]])
        // A jump without a menu shortcut, removed or given to another command, or held by a fixed menu item, counts not.
        var overrides = Dictionary(uniqueKeysWithValues: (1...9).map { ("thread.jump.\($0)", "") })
        #expect(KeyBindings(overrides: overrides).threadJumpModifiers().isEmpty)
        overrides["thread.jump.1"] = "ctrl+1"
        overrides["thread.stop"] = "ctrl+1"
        overrides["thread.jump.2"] = "alt+mod+2"
        let taken = KeyBindings(overrides: overrides)
        #expect(taken.threadJumpModifiers() == [[.command, .option]])
        #expect(taken.threadJumpModifiers(keeping: [KeyShortcut("alt+mod+2")!]).isEmpty)
    }

    @Test func reservedShortcutsConflict() throws {
        let spotlight = try #require(ReservedShortcut.macOS.first { $0.shortcut == KeyShortcut("mod+space") })
        #expect(spotlight.owner == .system)
        let copy = ReservedShortcut(shortcut: KeyShortcut("mod+c")!, title: "Edit › Copy", owner: .app)
        let split = ReservedShortcut(shortcut: KeyShortcut("mod+d")!, title: "Split right", owner: .focusedView("terminal"))
        let reserved = ReservedShortcut.macOS + [copy, copy, split]

        let bindings = KeyBindings(overrides: ["thread.rename": "mod+space", "thread.copyPath": "mod+c"])
        #expect(bindings.conflicts(for: .renameThread, reserved: reserved) == [.reserved(spotlight)])
        #expect(bindings.conflicts(for: .copyThreadPath, reserved: reserved) == [.reserved(copy)])
        // A key a focused terminal keeps is worth a note, not a warning.
        let diff = bindings.conflicts(for: .toggleDiff, reserved: reserved)
        #expect(diff == [.reserved(split)])
        #expect(diff.allSatisfy { !$0.isWarning })
        #expect(bindings.commandsWithConflicts(reserved: reserved) == [.renameThread, .copyThreadPath])
        #expect(bindings.conflicts(for: .planMode, reserved: reserved).isEmpty)
    }
}

struct ShortcutSettingsTests {
    @Test func settingTheDefaultRemovesTheOverride() throws {
        var settings = AppSettings()
        settings.setShortcut(KeyShortcut("mod+shift+."), for: .stopTurn)
        #expect(settings.shortcutOverrides == ["thread.stop": "mod+shift+."])
        settings.setShortcut(KeyCommand.stopTurn.defaultShortcut, for: .stopTurn)
        #expect(settings.shortcutOverrides.isEmpty)
        settings.setShortcut(nil, for: .stopTurn)
        #expect(settings.shortcutOverrides == ["thread.stop": ""])
        #expect(settings.keyBindings.shortcut(for: .stopTurn) == nil)
        settings.setShortcut(nil, for: .renameThread)
        #expect(settings.shortcutOverrides["thread.rename"] == nil)
        settings.resetShortcut(for: .stopTurn)
        #expect(settings.shortcutOverrides.isEmpty)
    }

    @Test func resettingAllAndRemovingUnusableOverrides() {
        var settings = AppSettings()
        settings.shortcutOverrides = ["thread.stop": "nope", "thread.rename": "mod+r", "thread.unknown": "mod+u"]
        settings.removeUnusableShortcuts()
        #expect(settings.shortcutOverrides == ["thread.rename": "mod+r"])
        settings.resetAllShortcuts()
        #expect(settings.shortcutOverrides.isEmpty)
    }

    @Test func overridesSaveAndLoadWithTheOtherSettings() throws {
        var settings = AppSettings()
        settings.setShortcut(KeyShortcut("ctrl+alt+r"), for: .renameThread)
        settings.setShortcut(nil, for: .toggleDiff)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.keyBindings.shortcut(for: .renameThread) == KeyShortcut("ctrl+alt+r"))

        // Older files have no overrides; hand-edited ones may hold values that are not text.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize": 15}"#.utf8))
        #expect(old.shortcutOverrides.isEmpty)
        #expect(old.fontSize == 15)
        let edited = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"shortcutOverrides": {"thread.stop": 5, "thread.pin": null, "chat.new": "mod+t"}}"#.utf8))
        #expect(edited.shortcutOverrides == ["thread.stop": "5", "chat.new": "mod+t"])
        #expect(edited.keyBindings.issues.map(\.commandID) == ["thread.stop"])
        let broken = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"shortcutOverrides": [1, 2]}"#.utf8))
        #expect(broken.shortcutOverrides.isEmpty)
    }
}
