import AppKit
import SwiftUI

public enum CodeTokenKind: String, Sendable, CaseIterable {
    case keyword, type, function, string, number, comment, attribute, tag, variable, constant, inserted, deleted, meta, heading
}

/// Token colors modelled on Xcode's default light and dark themes, with stronger
/// variants when Increase Contrast is on. Plain text keeps the label color.
public enum CodeTheme {
    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    private static func palette(_ kind: CodeTokenKind, dark: Bool, increasedContrast: Bool) -> UInt32 {
        switch (kind, dark, increasedContrast) {
        case (.keyword, false, false), (.heading, false, false), (.constant, false, false): 0x9B2393
        case (.keyword, false, true), (.heading, false, true), (.constant, false, true): 0x7A1772
        case (.keyword, true, false), (.heading, true, false), (.constant, true, false): 0xFF7AB2
        case (.keyword, true, true), (.heading, true, true), (.constant, true, true): 0xFFA3CB
        case (.type, false, false): 0x6C36A9
        case (.type, false, true): 0x4E2183
        case (.type, true, false): 0xDABAFF
        case (.type, true, true): 0xE8D4FF
        case (.function, false, false): 0x326D74
        case (.function, false, true): 0x1F4F55
        case (.function, true, false): 0x67B7A4
        case (.function, true, true): 0x8FD8C6
        case (.string, false, false): 0xC41A16
        case (.string, false, true): 0x9A0F0C
        case (.string, true, false): 0xFC6A5D
        case (.string, true, true): 0xFF9A90
        case (.number, false, false): 0x1C00CF
        case (.number, false, true): 0x14009A
        case (.number, true, false): 0xD0BF69
        case (.number, true, true): 0xEBDB8C
        case (.comment, false, false): 0x5D6C79
        case (.comment, false, true): 0x3F4B55
        case (.comment, true, false): 0x7F8C98
        case (.comment, true, true): 0xA7B2BC
        case (.attribute, false, false): 0x815F03
        case (.attribute, false, true): 0x5E4400
        case (.attribute, true, false): 0xBF8555
        case (.attribute, true, true): 0xDDA67A
        case (.tag, false, false): 0x0F68A0
        case (.tag, false, true): 0x0A4C76
        case (.tag, true, false): 0x5DD8FF
        case (.tag, true, true): 0x96E6FF
        case (.variable, false, false): 0x3E8087
        case (.variable, false, true): 0x285E63
        case (.variable, true, false): 0x9EF1DD
        case (.variable, true, true): 0xC2F7EA
        case (.inserted, false, false): 0x1A7F37
        case (.inserted, false, true): 0x0F5C26
        case (.inserted, true, false): 0x3FB950
        case (.inserted, true, true): 0x6FD97C
        case (.deleted, false, false): 0xCF222E
        case (.deleted, false, true): 0x9C1620
        case (.deleted, true, false): 0xF85149
        case (.deleted, true, true): 0xFF8A82
        case (.meta, false, false): 0x6F42C1
        case (.meta, false, true): 0x512E96
        case (.meta, true, false): 0xD2A8FF
        case (.meta, true, true): 0xE4CCFF
        }
    }
    public static func color(_ kind: CodeTokenKind, dark: Bool, increasedContrast: Bool = false) -> NSColor {
        hex(palette(kind, dark: dark, increasedContrast: increasedContrast))
    }
    /// An appearance-resolving color for AppKit text views.
    public static func dynamicColor(_ kind: CodeTokenKind) -> NSColor {
        NSColor(name: NSColor.Name("Coincide.code.\(kind.rawValue)")) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            return color(kind, dark: dark, increasedContrast: match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua)
        }
    }
}
