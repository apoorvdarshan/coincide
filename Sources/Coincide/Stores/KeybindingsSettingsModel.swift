import CoincideCore
import Foundation

enum KeybindingSource: String, Sendable { case `default` = "Default", custom = "Custom", project = "Project" }

/// One Settings row (T3 `KeybindingRow`).
struct KeybindingRow: Identifiable, Equatable {
    let id: String
    let command: KeybindingCommand
    let key: String
    let when: String
    let shortcut: KeybindingShortcut
    let source: KeybindingSource
    let defaultKey: String?
    let defaultWhen: String
    var conflicts: [String] = []
    var label: String { command.label }
    var rule: KeybindingRule { .init(key: key, command: command, when: when.isEmpty ? nil : when) }
    var defaultRule: KeybindingRule? { defaultKey.map { .init(key: $0, command: command, when: defaultWhen.isEmpty ? nil : defaultWhen) } }
    var canReset: Bool { source == .custom && defaultKey != nil }
    var canRemove: Bool { source != .default }
}

/// Port of T3 `KeybindingsSettings.logic`.
enum KeybindingsSettingsModel {
    static func rows(_ keybindings: [ResolvedKeybinding], defaults: [ResolvedKeybinding] = KeybindingDefaults.resolved) -> [KeybindingRow] {
        var byID: [String: KeybindingRow] = [:], order: [String] = []
        for binding in keybindings {
            let key = binding.keyText, when = binding.whenText
            let id = [binding.command.rawValue, key, when].joined(separator: "\u{0}")
            let isDefault = defaults.contains { $0.command == binding.command && $0.keyText == key && $0.whenText == when }
            let fallback = defaults.first { $0.command == binding.command && $0.keyText == key && $0.whenText == when }
                ?? defaults.first { $0.command == binding.command && $0.whenText == when }
                ?? defaults.first { $0.command == binding.command }
            let source: KeybindingSource = binding.command.scriptID != nil ? .project : isDefault ? .default : .custom
            if byID[id] == nil { order.append(id) }
            byID[id] = .init(id: id, command: binding.command, key: key, when: when, shortcut: binding.shortcut, source: source,
                             defaultKey: fallback?.keyText, defaultWhen: fallback?.whenText ?? "")
        }
        var rows = order.compactMap { byID[$0] }
        rows = rows.map { row in
            var copy = row; copy.conflicts = conflictLabels(rows, rowID: row.id, shortcut: row.shortcut, when: row.when); return copy
        }
        return rows.sorted {
            let left = $0.label, right = $1.label
            if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            return $0.key < $1.key
        }
    }

    /// Other commands that fire on the same keystroke when either condition is empty or both are equal.
    static func conflictLabels(_ rows: [KeybindingRow], rowID: String?, shortcut: KeybindingShortcut?, when: String) -> [String] {
        guard let shortcut else { return [] }
        let labels = rows.filter { candidate in
            candidate.id != rowID && candidate.shortcut.conflictKey == shortcut.conflictKey
                && (candidate.when.isEmpty || when.isEmpty || candidate.when == when)
        }.map(\.label)
        return Array(Set(labels)).sorted()
    }

    static func filter(_ rows: [KeybindingRow], query: String) -> [KeybindingRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            [row.command.rawValue, row.label, row.key, row.shortcut.label, row.when, row.source.rawValue].contains { $0.lowercased().contains(query) }
        }
    }

    static func groups(_ rows: [KeybindingRow]) -> [(title: String, rows: [KeybindingRow])] {
        let grouped = Dictionary(grouping: rows) { KeybindingCatalog.group($0.command) }
        return KeybindingCatalog.groupOrder.compactMap { title in grouped[title].map { (title, $0) } }
    }

    enum WhenDraft: Equatable { case empty, valid(KeybindingWhen, unknown: [String]), invalid(String) }
    static func parseWhen(_ text: String) -> WhenDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        guard trimmed.count <= KeybindingWhen.maxLength, let node = KeybindingWhen(parsing: trimmed) else {
            return .invalid(String(localized: "Use variables with !, &&, || and parentheses."))
        }
        return .valid(node, unknown: KeybindingContext.unknownIdentifiers(in: node))
    }

    /// Commands for a new binding: every Coincide-dispatched or reserved command.
    static var commandOptions: [KeybindingCommand] {
        KeybindingCatalog.allCommands.filter { [.available, .reserved].contains($0.availability) }
    }

    /// T3 `keybindingFromKeyboardEvent` with layout characters on macOS: Command
    /// records as `mod`; a US shifted glyph records as its key plus Shift.
    static func recordedKey(keyCode: UInt16, characters: String?, command: Bool, control: Bool, option: Bool, shift: Bool) -> String? {
        let physical = KeyStroke.specialKeys[keyCode] ?? KeyStroke.physicalKeys[keyCode]
        let layout = (characters ?? "").lowercased()
        var key: String
        if let special = KeyStroke.specialKeys[keyCode] { key = special }
        else if layout.count == 1, let first = layout.first, first.isASCII, first.isLetter { key = layout }
        else if option || layout.count != 1 { guard let physical else { return nil }; key = physical }
        else {
            let unshifted = shift ? usShiftedToUnshifted[layout] : nil
            key = unshifted != nil && unshifted == physical ? physical! : layout
        }
        if CharacterSet.controlCharacters.contains(key.unicodeScalars.first!) || (0xF700...0xF8FF).contains(key.unicodeScalars.first!.value) {
            guard let physical else { return nil }; key = physical
        }
        let token: String = key == " " ? "space" : key == "escape" ? "esc" : key
        var parts: [String] = []
        if command { parts.append("mod") }
        if control { parts.append("ctrl") }
        if option { parts.append("alt") }
        if shift { parts.append("shift") }
        parts.append(token)
        return parts.joined(separator: "+")
    }
}
