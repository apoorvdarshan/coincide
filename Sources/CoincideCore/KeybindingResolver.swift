import Foundation

/// One configuration entry: `{ "key": "mod+k", "command": "commandPalette.toggle", "when": "!terminalFocus" }`.
public struct KeybindingRule: Hashable, Codable, Sendable {
    public var key: String
    public var command: KeybindingCommand
    public var when: String?
    public init(key: String, command: KeybindingCommand, when: String? = nil) {
        self.key = key; self.command = command
        let trimmed = when?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.when = trimmed?.isEmpty == false ? trimmed : nil
    }
    /// Same command, shortcut and condition (T3 `isSameKeybindingRule`), compared in
    /// canonical form so `Mod+K` in a hand-edited file still matches `mod+k`.
    public func isSame(as other: KeybindingRule) -> Bool { command == other.command && canonical == other.canonical }
    private var canonical: String {
        let key = KeybindingShortcut(parsing: key)?.encoded ?? key
        let when = when.map { KeybindingWhen(parsing: $0)?.expression ?? $0 } ?? ""
        return key + "\u{0}" + when
    }
    /// Canonical shortcut plus `when` text; two rules with one context fire on the same keystroke in the same state.
    public var shortcutContext: String? {
        guard let encoded = KeybindingShortcut(parsing: key)?.encoded else { return nil }
        return encoded + "\u{0}" + (when.map { KeybindingWhen(parsing: $0)?.expression ?? $0 } ?? "")
    }
    public var resolved: ResolvedKeybinding? { ResolvedKeybinding(self) }
}

/// A compiled rule. Invalid keys or `when` expressions never compile.
public struct ResolvedKeybinding: Hashable, Sendable {
    public let command: KeybindingCommand
    public let shortcut: KeybindingShortcut
    public let when: KeybindingWhen?
    public init(command: KeybindingCommand, shortcut: KeybindingShortcut, when: KeybindingWhen? = nil) {
        self.command = command; self.shortcut = shortcut; self.when = when
    }
    public init?(_ rule: KeybindingRule) {
        guard let shortcut = KeybindingShortcut(parsing: rule.key) else { return nil }
        if let text = rule.when {
            guard let when = KeybindingWhen(parsing: text) else { return nil }
            self.init(command: rule.command, shortcut: shortcut, when: when)
        } else { self.init(command: rule.command, shortcut: shortcut) }
    }
    /// The display key used by settings rows: `mod+shift+[` style with `esc`/`space` aliases.
    public var keyText: String {
        var parts: [String] = []
        if shortcut.mod { parts.append("mod") }
        if shortcut.meta { parts.append("meta") }
        if shortcut.control { parts.append("ctrl") }
        if shortcut.option { parts.append("alt") }
        if shortcut.shift { parts.append("shift") }
        parts.append(shortcut.key == " " ? "space" : shortcut.key == "escape" ? "esc" : shortcut.key)
        return parts.joined(separator: "+")
    }
    public var whenText: String { when?.expression ?? "" }
    public var rule: KeybindingRule { .init(key: keyText, command: command, when: when?.expression) }
    public func applies(in context: KeybindingContext) -> Bool { when?.evaluate(context) ?? true }
}

public enum KeybindingResolver {
    public static let maxRules = 256

    /// T3 `compileResolvedKeybindingsConfig`: invalid rules drop and the newest 256 remain.
    public static func compile(_ rules: [KeybindingRule]) -> [ResolvedKeybinding] {
        Array(rules.compactMap(ResolvedKeybinding.init).suffix(maxRules))
    }

    /// T3 `mergeWithDefaultKeybindings`: a command that appears in the file replaces all of that command's defaults.
    public static func merge(_ custom: [ResolvedKeybinding], defaults: [ResolvedKeybinding] = KeybindingDefaults.resolved) -> [ResolvedKeybinding] {
        guard !custom.isEmpty else { return defaults }
        let overridden = Set(custom.map(\.command))
        let merged = defaults.filter { !overridden.contains($0.command) } + custom
        return Array(merged.suffix(maxRules))
    }

    /// The last rule whose key and condition both match wins, even across commands.
    public static func resolve(_ stroke: KeyStroke, in bindings: [ResolvedKeybinding], context: KeybindingContext) -> KeybindingCommand? {
        bindings.last { $0.applies(in: context) && $0.shortcut.matches(stroke) }?.command
    }
    /// Whether any rule uses this keystroke, regardless of its condition.
    public static func isBound(_ stroke: KeyStroke, in bindings: [ResolvedKeybinding]) -> Bool {
        bindings.contains { $0.shortcut.matches(stroke) }
    }

    /// T3 `effectiveShortcutsForCommand`: newest first, skipping a shortcut that a later applicable rule already claims.
    public static func effectiveShortcuts(for command: KeybindingCommand, in bindings: [ResolvedKeybinding],
                                          context: KeybindingContext = .menu) -> [KeybindingShortcut] {
        var claimed = Set<String>(), result: [KeybindingShortcut] = []
        for binding in bindings.reversed() where binding.applies(in: context) {
            guard claimed.insert(binding.shortcut.conflictKey).inserted else { continue }
            if binding.command == command { result.append(binding.shortcut) }
        }
        return result
    }
    public static func shortcut(for command: KeybindingCommand, in bindings: [ResolvedKeybinding],
                                context: KeybindingContext = .menu) -> KeybindingShortcut? {
        effectiveShortcuts(for: command, in: bindings, context: context).first
    }

    /// T3 `shouldShowThreadJumpHintsForModifiers`: hints appear while the held modifiers
    /// exactly match an effective jump shortcut, never while a terminal has focus.
    public static func showsThreadJumpHints(command: Bool, control: Bool, option: Bool, shift: Bool,
                                            bindings: [ResolvedKeybinding], context: KeybindingContext) -> Bool {
        guard !context["terminalFocus"] else { return false }
        let held = KeyStroke(keys: [], command: command, control: control, option: option, shift: shift)
        return KeybindingCommand.threadJumps.contains { jump in
            shortcut(for: jump, in: bindings, context: context)?.matchesModifiers(held) == true
        }
    }
}

/// Coincide's default table. T3 defaults apply where Coincide has the surface;
/// three existing macOS window shortcuts keep their Coincide meaning (see docs/KEYBOARD.md).
public enum KeybindingDefaults {
    public static let rules: [KeybindingRule] = [
        .init(key: "mod+b", command: .sidebarToggle),
        .init(key: "mod+[", command: .navigationBack, when: "!terminalFocus"),
        .init(key: "mod+]", command: .navigationForward, when: "!terminalFocus"),
        .init(key: "mod+j", command: .terminalToggle),
        .init(key: "mod+alt+b", command: .rightPanelToggle),
        .init(key: "mod+alt+i", command: .rightPanelToggle),
        .init(key: "mod+d", command: .terminalSplit, when: "terminalFocus"),
        .init(key: "mod+shift+d", command: .terminalSplitVertical, when: "terminalFocus"),
        .init(key: "mod+n", command: .terminalNew, when: "terminalFocus"),
        .init(key: "mod+w", command: .terminalClose, when: "terminalFocus"),
        .init(key: "mod+shift+t", command: .viewReopenClosed),
        .init(key: "mod+d", command: .diffToggle, when: "!terminalFocus"),
        .init(key: "mod+k", command: .commandPaletteToggle, when: "!terminalFocus"),
        .init(key: "mod+p", command: .filePickerToggle, when: "!terminalFocus"),
        .init(key: "mod+shift+f", command: .projectSearchToggle, when: "!terminalFocus"),
        .init(key: "mod+alt+a", command: .themeSelect, when: "!terminalFocus"),
        .init(key: "mod+alt+shift+a", command: .appearanceCycle, when: "!terminalFocus"),
        .init(key: "mod+n", command: .chatNew, when: "!terminalFocus"),
        .init(key: "mod+f", command: .chatFind, when: "!terminalFocus && !previewFocus && !fileEditorFocus"),
        .init(key: "mod+shift+[", command: .threadPrevious),
        .init(key: "mod+shift+]", command: .threadNext),
        .init(key: "mod+.", command: .threadStop),
        .init(key: "mod+shift+c", command: .threadCopyReference, when: "!terminalFocus"),
        .init(key: "mod+shift+s", command: .threadSettle, when: "!terminalFocus"),
        .init(key: "mod+shift+p", command: .threadPin, when: "!terminalFocus"),
    ] + KeybindingCommand.threadJumps.enumerated().map { .init(key: "mod+\($0.offset + 1)", command: $0.element, when: "!modelPickerOpen && isDesktop") } + [
        .init(key: "mod+shift+n", command: .projectNew),
        .init(key: "mod+o", command: .projectAdd),
        .init(key: "mod+shift+o", command: .projectClone),
        .init(key: "mod+alt+n", command: .windowNew),
        .init(key: "mod+alt+r", command: .remoteOpen),
    ]
    public static let resolved = KeybindingResolver.compile(rules)

    /// T3 `LATE_DEFAULT_KEYBINDINGS`: a default added beside an existing rule for
    /// installs that already have a file. Coincide has none yet; the mechanism is tested.
    public struct LateDefault: Sendable, Equatable {
        public let id: String
        public let alongside: KeybindingRule
        public let rule: KeybindingRule
        public init(id: String, alongside: KeybindingRule, rule: KeybindingRule) { self.id = id; self.alongside = alongside; self.rule = rule }
    }
    public static let late: [LateDefault] = []
}
