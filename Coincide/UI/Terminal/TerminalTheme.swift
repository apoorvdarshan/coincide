import AppKit
import SwiftTerm

/// Terminal colors for light and dark appearance. The ANSI palettes and caret colors are T3 Code's;
/// text, background and selection use the system's semantic colors.
enum TerminalTheme {
    /// Behind the terminal and its header, so they read as one surface.
    static var background: NSColor { .textBackgroundColor }

    /// Applies the colors for the view's effective appearance. SwiftTerm stores plain RGB, so this
    /// runs again whenever the appearance changes.
    static func apply(to view: TerminalView) {
        let appearance = view.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        appearance.performAsCurrentDrawingAppearance {
            view.nativeForegroundColor = resolved(.textColor)
            view.nativeBackgroundColor = resolved(background)
            view.selectedTextBackgroundColor = resolved(.selectedTextBackgroundColor)
            view.selectedTextForegroundColor = resolved(.selectedTextColor)
        }
        view.caretColor = isDark ? rgb(0xB4CBFF) : rgb(0x26384E)
        view.installColors((isDark ? darkPalette : lightPalette).map(terminalColor))
    }

    private static let lightPalette: [UInt32] = [
        0x000000, 0xCD3131, 0x107C10, 0x949800, 0x0451A5, 0xBC05BC, 0x0598BC, 0x555555,
        0x666666, 0xCD3131, 0x14CE14, 0xB5BA00, 0x0451A5, 0xBC05BC, 0x0598BC, 0xA5A5A5,
    ]

    private static let darkPalette: [UInt32] = [
        0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
        0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5,
    ]

    private static func resolved(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func terminalColor(_ value: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16((value >> 16) & 0xFF), green8: UInt16((value >> 8) & 0xFF), blue8: UInt16(value & 0xFF))
    }
}
