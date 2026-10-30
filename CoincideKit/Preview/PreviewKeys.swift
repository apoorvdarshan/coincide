import Foundation

/// A key an agent presses in the browser, such as `Enter`, `Shift+Tab` or `Meta+a`, as a real key event (so pages
/// see trusted keystrokes and default actions like submitting a form happen). Only named keys and single printable
/// characters with Meta (Command), Control, Alt (Option) and Shift.
public struct KeyPress: Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    /// What the key types with its modifiers, and without them, as `NSEvent` wants them.
    public var characters: String
    public var charactersIgnoringModifiers: String
    public var command = false
    public var control = false
    public var option = false
    public var shift = false

    /// Named keys: macOS virtual key code and the character AppKit reports for it.
    nonisolated static let named: [String: (UInt16, String)] = [
        "enter": (36, "\r"), "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "), "backspace": (51, "\u{7f}"),
        "escape": (53, "\u{1b}"), "esc": (53, "\u{1b}"), "delete": (117, "\u{F728}"), "home": (115, "\u{F729}"),
        "end": (119, "\u{F72B}"), "pageup": (116, "\u{F72C}"), "pagedown": (121, "\u{F72D}"),
        "arrowleft": (123, "\u{F702}"), "arrowright": (124, "\u{F703}"), "arrowdown": (125, "\u{F701}"), "arrowup": (126, "\u{F700}"),
    ]

    /// US keyboard key codes of printable characters (lowercase and unshifted).
    nonisolated static let printable: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// Symbols typed with Shift on a US keyboard, by the key that types them.
    nonisolated static let shifted: [Character: UInt16] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22, "&": 26, "*": 28, "(": 25, ")": 29, "_": 27, "+": 24, "{": 33,
        "}": 30, "|": 42, ":": 41, "\"": 39, "<": 43, ">": 47, "?": 44, "~": 50,
    ]

    /// Parses `Enter`, `Shift+Tab`, `Meta+a`, `Control+Enter`… (case-insensitive; `Cmd`, `Command`, `Ctrl`, `Option`
    /// and `Opt` work too). Nil for anything else.
    public nonisolated init?(_ text: String) {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        // "Meta++" names the plus key.
        var keyName = parts.last ?? ""
        var modifierNames = Array(parts.dropLast())
        if keyName.isEmpty, parts.count >= 2, parts[parts.count - 2].isEmpty {
            keyName = "+"
            modifierNames = Array(parts.dropLast(2))
        }
        guard !keyName.isEmpty, modifierNames.count <= 4 else { return nil }
        for modifier in modifierNames {
            switch modifier.lowercased() {
            case "meta", "cmd", "command": command = true
            case "control", "ctrl": control = true
            case "alt", "option", "opt": option = true
            case "shift": shift = true
            default: return nil
            }
        }
        if let (code, character) = Self.named[keyName.lowercased()] {
            keyCode = code
            characters = character
            charactersIgnoringModifiers = character
            return
        }
        guard keyName.count == 1, let character = keyName.first, character.isASCII, !character.isWhitespace else { return nil }
        if let code = Self.shifted[character] {
            keyCode = code
            shift = true
            characters = String(character)
            charactersIgnoringModifiers = String(character)
            return
        }
        let lower = Character(character.lowercased())
        guard let code = Self.printable[lower] else { return nil }
        if character.isUppercase { shift = true }
        keyCode = code
        charactersIgnoringModifiers = String(lower)
        characters = shift ? String(lower).uppercased() : String(lower)
    }
}
