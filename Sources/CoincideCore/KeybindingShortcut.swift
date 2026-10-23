import Foundation

/// T3 key syntax: modifiers and one key joined by `+`, such as `mod+shift+[` or `mod++`.
/// `mod` is Command on macOS. Keys are lowercase; `space` and `esc` are aliases.
public struct KeybindingShortcut: Hashable, Codable, Sendable {
    public static let maxLength = 64
    public var key: String
    public var meta: Bool
    public var control: Bool
    public var shift: Bool
    public var option: Bool
    public var mod: Bool
    public init(key: String, meta: Bool = false, control: Bool = false, shift: Bool = false, option: Bool = false, mod: Bool = false) {
        self.key = key; self.meta = meta; self.control = control; self.shift = shift; self.option = option; self.mod = mod
    }

    /// Port of T3 `parseKeybindingShortcut`. Returns nil for an empty token, two keys or no key.
    public init?(parsing value: String) {
        guard value.utf16.count <= Self.maxLength else { return nil }
        var tokens = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var trailingEmpty = 0
        while tokens.last == "" { trailingEmpty += 1; tokens.removeLast() }
        if trailingEmpty > 0 { tokens.append("+") }
        guard !tokens.isEmpty, !tokens.contains(where: \.isEmpty) else { return nil }
        var key: String?
        var meta = false, control = false, shift = false, option = false, mod = false
        for token in tokens {
            switch token {
            case "cmd", "meta": meta = true
            case "ctrl", "control": control = true
            case "shift": shift = true
            case "alt", "option": option = true
            case "mod": mod = true
            default:
                guard key == nil else { return nil }
                key = token == "space" ? " " : token == "esc" ? "escape" : token
            }
        }
        guard let key else { return nil }
        self.init(key: key, meta: meta, control: control, shift: shift, option: option, mod: mod)
    }

    /// T3 server `encodeShortcut`: canonical `mod+meta+ctrl+alt+shift+key`; nil when a key contains `+`.
    public var encoded: String? {
        guard !key.isEmpty, key == "+" || !key.contains("+") else { return nil }
        var parts: [String] = []
        if mod { parts.append("mod") }
        if meta { parts.append("meta") }
        if control { parts.append("ctrl") }
        if option { parts.append("alt") }
        if shift { parts.append("shift") }
        parts.append(key == " " ? "space" : key)
        return parts.joined(separator: "+")
    }

    /// Effective modifiers on macOS, where `mod` is Command. Two shortcuts with the
    /// same conflict key fire on the same keystroke.
    public var conflictKey: String {
        [key, meta || mod ? "meta" : "", control ? "ctrl" : "", shift ? "shift" : "", option ? "alt" : ""].joined(separator: "|")
    }
    public var usesCommand: Bool { meta || mod }

    /// Native menu glyph order ⌃⌥⇧⌘ followed by the key.
    public var label: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (usesCommand ? "⌘" : "") + Self.keyLabel(key)
    }
    /// Spoken form for accessibility, such as "Command Shift [".
    public var accessibilityLabel: String {
        var parts: [String] = []
        if control { parts.append("Control") }
        if option { parts.append("Option") }
        if shift { parts.append("Shift") }
        if usesCommand { parts.append("Command") }
        parts.append(Self.spokenKey(key))
        return parts.joined(separator: " ")
    }
    public static func keyLabel(_ key: String) -> String {
        switch key {
        case " ": "Space"
        case "escape": "⎋"
        case "enter": "↩"
        case "tab": "⇥"
        case "backspace": "⌫"
        case "delete": "⌦"
        case "arrowup": "↑"
        case "arrowdown": "↓"
        case "arrowleft": "←"
        case "arrowright": "→"
        case "home": "↖"
        case "end": "↘"
        case "pageup": "⇞"
        case "pagedown": "⇟"
        default: key.count == 1 ? key.uppercased() : key.prefix(1).uppercased() + key.dropFirst()
        }
    }
    static func spokenKey(_ key: String) -> String {
        switch key {
        case " ": "Space"
        case "escape": "Escape"
        case "enter": "Return"
        case "arrowup": "Up Arrow"
        case "arrowdown": "Down Arrow"
        case "arrowleft": "Left Arrow"
        case "arrowright": "Right Arrow"
        case "pageup": "Page Up"
        case "pagedown": "Page Down"
        default: keyLabel(key)
        }
    }

    public func matches(_ stroke: KeyStroke) -> Bool { matchesModifiers(stroke) && stroke.keys.contains(key) }
    /// T3 `matchesKeybindingShortcutModifiers` on macOS.
    public func matchesModifiers(_ stroke: KeyStroke) -> Bool {
        stroke.command == usesCommand && stroke.control == control && stroke.shift == shift && stroke.option == option
    }
}

/// A platform-neutral key press. `keys` holds every name the press can match:
/// the layout character, an ASCII letter for its physical key on non-Latin
/// layouts, and the US-position key for digits and punctuation (so ⇧⌘[ matches `mod+shift+[`).
public struct KeyStroke: Hashable, Sendable {
    public var keys: Set<String>
    public var command: Bool
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public init(keys: Set<String>, command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false) {
        self.keys = keys; self.command = command; self.control = control; self.option = option; self.shift = shift
    }
    public var hasModifiers: Bool { command || control || option || shift }

    /// - Parameters:
    ///   - keyCode: the macOS virtual key code (`NSEvent.keyCode`).
    ///   - characters: `charactersIgnoringModifiers`, which keeps the Shift glyph.
    public init(keyCode: UInt16, characters: String?, command: Bool, control: Bool, option: Bool, shift: Bool) {
        var keys = Set<String>()
        if let special = Self.specialKeys[keyCode] { keys.insert(special) }
        else {
            let layout = (characters ?? "").lowercased()
            if !layout.isEmpty { keys.insert(layout == "esc" ? "escape" : layout) }
            if let physical = Self.physicalKeys[keyCode] {
                if physical.count == 1, physical.first!.isLetter {
                    // Letter codes apply only when the layout key is not already an ASCII letter.
                    if !(layout.count == 1 && layout.first!.isASCII && layout.first!.isLetter) { keys.insert(physical) }
                } else { keys.insert(physical) }
            }
        }
        self.init(keys: keys, command: command, control: control, option: option, shift: shift)
    }

    public static let specialKeys: [UInt16: String] = [
        36: "enter", 76: "enter", 48: "tab", 49: " ", 51: "backspace", 117: "delete", 53: "escape",
        123: "arrowleft", 124: "arrowright", 125: "arrowdown", 126: "arrowup", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]
    /// ANSI positions, the macOS counterpart of T3 `EVENT_CODE_SHORTCUT_KEYS` plus `Key*` letter codes.
    public static let physicalKeys: [UInt16: String] = [
        50: "`", 42: "\\", 33: "[", 30: "]", 43: ",", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9", 24: "=", 27: "-", 47: ".", 39: "'", 41: ";", 44: "/",
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j", 40: "k", 37: "l", 46: "m",
        45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
    ]
}

/// T3 `US_SHIFTED_TO_UNSHIFTED_KEYS`.
public let usShiftedToUnshifted: [String: String] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "~": "`", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
]
