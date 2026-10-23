import Foundation
import Testing
@testable import CoincideCore

private func stroke(_ keyCode: UInt16, _ characters: String, command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false) -> KeyStroke {
    KeyStroke(keyCode: keyCode, characters: characters, command: command, control: control, option: option, shift: shift)
}

@Test func keybindingShortcutsParseT3SyntaxAliasesAndTrailingPlus() throws {
    let bracket = try #require(KeybindingShortcut(parsing: "mod+shift+["))
    #expect(bracket == .init(key: "[", shift: true, mod: true) && bracket.encoded == "mod+shift+[" && bracket.label == "⇧⌘[")
    let plus = try #require(KeybindingShortcut(parsing: "mod++"))
    #expect(plus.key == "+" && plus.mod && plus.encoded == "mod++")
    #expect(KeybindingShortcut(parsing: "Ctrl + Space")?.key == " " && KeybindingShortcut(parsing: "ctrl+space")?.control == true)
    #expect(KeybindingShortcut(parsing: "esc")?.key == "escape" && KeybindingShortcut(parsing: "option+cmd+k") == .init(key: "k", meta: true, option: true))
    #expect(KeybindingShortcut(parsing: "control+alt+meta+x")?.label == "⌃⌥⌘X")
    for invalid in ["mod", "mod+shift", "a+b", "mod++a", "mod+ +k", "+mod+k"] { #expect(KeybindingShortcut(parsing: invalid) == nil, "\(invalid)") }
    // As in T3, the parser reads an empty value as "+"; rule validation rejects empty keys first.
    #expect(throws: (any Error).self) { try KeybindingsConfigStore.validate(.init(key: " ", command: .threadPin)) }
    #expect(KeybindingShortcut(parsing: "mod+arrowup")?.label == "⌘↑" && KeybindingShortcut(parsing: "mod+enter")?.accessibilityLabel == "Command Return")
}

@Test func keybindingWhenExpressionsKeepT3PrecedenceDepthAndUnknownFalse() throws {
    let node = try #require(KeybindingWhen(parsing: "!(a && b) || c"))
    #expect(node == .or(.not(.and(.identifier("a"), .identifier("b"))), .identifier("c")))
    #expect(node.evaluate(.init(["a": true, "b": true])) == false && node.evaluate(.init(["a": true, "b": true, "c": true])))
    #expect(node.evaluate(.init(["a": true])) && KeybindingWhen(parsing: "missing")?.evaluate(.init()) == false)
    #expect(KeybindingWhen(parsing: "true")?.evaluate(.init()) == true && KeybindingWhen(parsing: "!false")?.evaluate(.init()) == true)
    // && binds tighter than ||, and canonical text round-trips without extra parentheses.
    let mixed = try #require(KeybindingWhen(parsing: "a || b && c"))
    #expect(mixed == .or(.identifier("a"), .and(.identifier("b"), .identifier("c"))) && mixed.expression == "a || b && c")
    let triple = try #require(KeybindingWhen(parsing: "!terminalFocus && !previewFocus && !fileEditorFocus"))
    #expect(triple.expression == "!terminalFocus && !previewFocus && !fileEditorFocus")
    for text in ["(a || b) && c", "a && (b && c)", "!(a || b)", "a || (b || c)", "x.y-z_1 && !!w"] {
        let parsed = try #require(KeybindingWhen(parsing: text))
        #expect(KeybindingWhen(parsing: parsed.expression) == parsed, "\(text) -> \(parsed.expression)")
    }
    for invalid in ["", "a &&", "(a", "a)", "a & b", "1abc", "a ||| b", "a b"] { #expect(KeybindingWhen(parsing: invalid) == nil, "\(invalid)") }
    #expect(KeybindingWhen(parsing: String(repeating: "(", count: 64) + "a" + String(repeating: ")", count: 64)) != nil)
    #expect(KeybindingWhen(parsing: String(repeating: "(", count: 65) + "a" + String(repeating: ")", count: 65)) == nil)
    #expect(KeybindingWhen(parsing: String(repeating: "!", count: 64) + "a") != nil && KeybindingWhen(parsing: String(repeating: "!", count: 65) + "a") == nil)
    #expect(KeybindingContext.unknownIdentifiers(in: KeybindingWhen(parsing: "terminalFocus && mystery || isDesktop")) == ["mystery"])
}

@Test func keyStrokesNormalizeShiftedPunctuationDigitsAndNonLatinLetters() {
    // ⇧⌘[ arrives as "{" on a US layout and still matches the bracket shortcut.
    let previous = KeybindingShortcut(parsing: "mod+shift+[")!
    #expect(previous.matches(stroke(33, "{", command: true, shift: true)))
    #expect(!previous.matches(stroke(33, "[", command: true)) && !previous.matches(stroke(33, "{", command: true, option: true, shift: true)))
    #expect(KeybindingShortcut(parsing: "mod+1")!.matches(stroke(18, "1", command: true)))
    #expect(KeybindingShortcut(parsing: "mod+shift+1")!.matches(stroke(18, "!", command: true, shift: true)))
    // A Cyrillic layout still matches by physical letter position; a Latin layout keeps its own letters.
    #expect(KeybindingShortcut(parsing: "mod+k")!.matches(stroke(40, "л", command: true)))
    #expect(!KeybindingShortcut(parsing: "mod+z")!.matches(stroke(16, "y", command: true)) && KeybindingShortcut(parsing: "mod+y")!.matches(stroke(16, "y", command: true)))
    #expect(KeybindingShortcut(parsing: "mod+enter")!.matches(stroke(36, "\r", command: true)) && KeybindingShortcut(parsing: "escape")!.matches(stroke(53, "\u{1b}")))
    #expect(KeybindingShortcut(parsing: "alt+arrowup")!.matches(stroke(126, "\u{F700}", option: true)))
    // Control is distinct from Command for `mod`.
    #expect(!KeybindingShortcut(parsing: "mod+k")!.matches(stroke(40, "k", control: true)) && KeybindingShortcut(parsing: "ctrl+k")!.matches(stroke(40, "k", control: true)))
}

@Test func keybindingResolutionUsesLastMatchingRuleAcrossCommandsAndConditions() {
    let rules: [KeybindingRule] = [
        .init(key: "mod+j", command: .terminalToggle),
        .init(key: "mod+j", command: .rightPanelToggle, when: "terminalOpen && !terminalFocus"),
        .init(key: "mod+d", command: .terminalSplit, when: "terminalFocus"),
        .init(key: "mod+d", command: .diffToggle, when: "!terminalFocus"),
    ]
    let bindings = KeybindingResolver.compile(rules), j = stroke(38, "j", command: true), d = stroke(2, "d", command: true)
    #expect(KeybindingResolver.resolve(j, in: bindings, context: .init()) == .terminalToggle)
    #expect(KeybindingResolver.resolve(j, in: bindings, context: .init(["terminalOpen": true])) == .rightPanelToggle)
    #expect(KeybindingResolver.resolve(j, in: bindings, context: .init(["terminalOpen": true, "terminalFocus": true])) == .terminalToggle)
    #expect(KeybindingResolver.resolve(d, in: bindings, context: .init(["terminalFocus": true])) == .terminalSplit)
    #expect(KeybindingResolver.resolve(d, in: bindings, context: .init()) == .diffToggle)
    #expect(KeybindingResolver.resolve(stroke(40, "k", command: true), in: bindings, context: .init()) == nil)
    #expect(KeybindingResolver.isBound(d, in: bindings) && !KeybindingResolver.isBound(stroke(40, "k", command: true), in: bindings))
    // The menu label skips a shortcut claimed by a later applicable rule.
    #expect(KeybindingResolver.shortcut(for: .terminalToggle, in: bindings, context: .init(["terminalOpen": true])) == nil)
    #expect(KeybindingResolver.shortcut(for: .terminalToggle, in: bindings)?.label == "⌘J")
}

@Test func customRulesReplaceEveryDefaultForTheirCommandAndKeepTheNewest256() throws {
    let custom = KeybindingResolver.compile([.init(key: "mod+g", command: .terminalToggle), .init(key: "mod+alt+i", command: .commandPaletteToggle)])
    let merged = KeybindingResolver.merge(custom)
    #expect(!merged.contains { $0.command == .terminalToggle && $0.shortcut.key == "j" })
    #expect(merged.filter { $0.command == .commandPaletteToggle }.count == 1 && merged.suffix(2) == custom[...])
    #expect(merged.contains { $0.command == .rightPanelToggle && $0.shortcut.key == "b" })
    // ⌥⌘I now opens the palette: the later custom rule wins over the inspector default.
    #expect(KeybindingResolver.resolve(stroke(34, "i", command: true, option: true), in: merged, context: .menu) == .commandPaletteToggle)
    #expect(KeybindingResolver.merge([]) == KeybindingDefaults.resolved)
    let many = (0..<300).map { KeybindingRule(key: "mod+alt+shift+\($0 % 10)", command: .threadPin, when: "w\($0)") }
    let compiled = KeybindingResolver.compile(many)
    #expect(compiled.count == 256 && compiled.first?.whenText == "w44" && compiled.last?.whenText == "w299")
    #expect(KeybindingResolver.merge(compiled).count == 256)
}

@Test func coincideDefaultsCompileWithoutDuplicateShortcutContextsAndCoverTheMenuSurface() throws {
    #expect(KeybindingDefaults.resolved.count == KeybindingDefaults.rules.count)
    let contexts = KeybindingDefaults.rules.compactMap(\.shortcutContext)
    #expect(contexts.count == KeybindingDefaults.rules.count && Set(contexts).count == contexts.count)
    for rule in KeybindingDefaults.rules {
        #expect(rule.command.isKnown && rule.command.availability != .unavailable && rule.command.availability != .unknown, "\(rule.command)")
        try KeybindingsConfigStore.validate(rule)
        #expect(KeybindingContext.unknownIdentifiers(in: rule.when.flatMap(KeybindingWhen.init(parsing:))).isEmpty, "\(rule.command)")
    }
    let labels: [(KeybindingCommand, String)] = [(.commandPaletteToggle, "⌘K"), (.sidebarToggle, "⌘B"), (.navigationBack, "⌘["), (.threadNext, "⇧⌘]"),
        (.threadJumps[0], "⌘1"), (.threadCopyReference, "⇧⌘C"), (.chatFind, "⌘F"), (.appearanceCycle, "⌥⇧⌘A"), (.rightPanelToggle, "⌥⌘I"),
        (.projectNew, "⇧⌘N"), (.projectAdd, "⌘O"), (.windowNew, "⌥⌘N"), (.threadStop, "⌘."), (.terminalToggle, "⌘J"), (.viewReopenClosed, "⇧⌘T")]
    for (command, label) in labels { #expect(KeybindingResolver.shortcut(for: command, in: KeybindingDefaults.resolved)?.label == label, "\(command)") }
    // Terminal-scoped reservations do not label menus outside the terminal.
    #expect(KeybindingResolver.shortcut(for: .terminalNew, in: KeybindingDefaults.resolved) == nil)
    #expect(KeybindingResolver.shortcut(for: .chatNew, in: KeybindingDefaults.resolved)?.label == "⌘N")
}

@Test func keybindingCommandsAcceptT3IDsScriptsAndCoincideAdditionsOnly() {
    #expect(KeybindingCommand("preview.toggle").availability == .unavailable && KeybindingCommand("preview.toggle").isKnown)
    #expect(KeybindingCommand.terminalNew.availability == .reserved && KeybindingCommand.chatFind.availability == .available)
    #expect(KeybindingCommand("script.test.run").scriptID == "test" && KeybindingCommand("script.a-1.run").availability == .project)
    for invalid in ["script.Test.run", "script.-a.run", "script..run", "script.\(String(repeating: "a", count: 25)).run", "foo.bar", "thread.jump.10"] {
        #expect(!KeybindingCommand(invalid).isKnown, "\(invalid)")
    }
    #expect(KeybindingCommand("script.\(String(repeating: "a", count: 24)).run").isKnown)
    #expect(KeybindingCatalog.t3StaticCommands.count == 84 && Set(KeybindingCatalog.t3StaticCommands).count == 84)
    #expect(KeybindingCommand.threadJumps[8].threadJumpNumber == 9 && KeybindingCommand.threadJump(10) == nil)
    #expect(KeybindingCommand("composer.sendAndNewThread").label == "Composer: Send And New Thread" && KeybindingCommand("script.dev-server.run").label == "Run Script: Dev Server")
    #expect(KeybindingCatalog.group(.threadPin) == "Threads" && KeybindingCatalog.group(.terminalSplit) == "Terminal" && KeybindingCatalog.group(.projectAdd) == "Projects & Windows")
}

@Test func threadJumpHintsFollowHeldModifiersAndHideForTerminalFocus() {
    let bindings = KeybindingDefaults.resolved
    #expect(KeybindingResolver.showsThreadJumpHints(command: true, control: false, option: false, shift: false, bindings: bindings, context: .menu))
    #expect(!KeybindingResolver.showsThreadJumpHints(command: true, control: false, option: false, shift: true, bindings: bindings, context: .menu))
    #expect(!KeybindingResolver.showsThreadJumpHints(command: true, control: false, option: false, shift: false, bindings: bindings,
                                                     context: .init(["isDesktop": true, "terminalFocus": true])))
    #expect(!KeybindingResolver.showsThreadJumpHints(command: true, control: false, option: false, shift: false, bindings: bindings,
                                                     context: .init(["isDesktop": true, "modelPickerOpen": true])))
    let remapped = KeybindingResolver.merge(KeybindingResolver.compile(KeybindingCommand.threadJumps.enumerated().map {
        .init(key: "ctrl+\($0.offset + 1)", command: $0.element)
    }))
    #expect(KeybindingResolver.showsThreadJumpHints(command: false, control: true, option: false, shift: false, bindings: remapped, context: .menu))
    #expect(!KeybindingResolver.showsThreadJumpHints(command: true, control: false, option: false, shift: false, bindings: remapped, context: .menu))
}
