import AppKit
import SwiftTerm

/// Terminal font and color preferences shared by local and remote terminals.
/// T3 has a terminal font family and a size from 8 to 20 points; its ANSI
/// palette, cursor and selection follow the light or dark theme.
public struct TerminalAppearance: Equatable, Sendable {
    public enum Theme: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .system: String(localized: "Match Appearance")
            case .light: String(localized: "Light")
            case .dark: String(localized: "Dark")
            }
        }
    }
    public static let fontFamilyKey = "terminalFontFamily"
    public static let fontSizeKey = "terminalFontSize"
    public static let themeKey = "terminalTheme"
    public static let resumeRestoredShellsKey = "terminalResumeRestoredShells"
    public static let defaultFontSize = 12.0
    public static let fontSizes = 8.0...20.0

    public var fontFamily: String
    public var fontSize: Double
    public var theme: Theme
    public init(fontFamily: String = "", fontSize: Double = defaultFontSize, theme: Theme = .system) {
        self.fontFamily = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fontSize = Self.clampedSize(fontSize); self.theme = theme
    }
    public init(fontFamily: String, fontSize: Double, theme rawTheme: String) {
        self.init(fontFamily: fontFamily, fontSize: fontSize, theme: Theme(rawValue: rawTheme) ?? .system)
    }

    public static func clampedSize(_ size: Double) -> Double {
        guard size.isFinite else { return defaultFontSize }
        return min(fontSizes.upperBound, max(fontSizes.lowerBound, size.rounded()))
    }

    /// The chosen family's regular monospaced face, or the system monospaced font
    /// when the family is empty, missing or proportional.
    @MainActor public var font: NSFont {
        if !fontFamily.isEmpty, let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: fontSize),
           font.isFixedPitch { return font }
        return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Installed fixed-pitch families, sorted for a picker.
    @MainActor public static func monospacedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard !family.hasPrefix("."), let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Light or dark resolution for an effective appearance.
    public func isDark(appearance: NSAppearance?) -> Bool {
        switch theme {
        case .light: false
        case .dark: true
        case .system: appearance?.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
        }
    }

    public struct Colors: Equatable, Sendable {
        public let palette: [String]
        public let foreground: String?
        public let background: String?
        public let cursor: String
        public let selection: String
        public let selectionAlpha: Double
    }

    /// T3's VS Code-derived ANSI palettes, cursor and selection colors. A fixed
    /// light or dark theme also fixes the background and foreground; Match
    /// Appearance keeps the system text colors. Increased contrast deepens the
    /// dim light-palette colors and strengthens the selection.
    public func colors(dark: Bool, increasedContrast: Bool = false) -> Colors {
        let light = ["000000", "cd3131", "107c10", "949800", "0451a5", "bc05bc", "0598bc", "555555",
                     "666666", "cd3131", "14ce14", "b5ba00", "0451a5", "bc05bc", "0598bc", "a5a5a5"]
        let darkPalette = ["000000", "cd3131", "0dbc79", "e5e510", "2472c8", "bc3fbc", "11a8cd", "e5e5e5",
                           "666666", "f14c4c", "23d18b", "f5f543", "3b8eea", "d670d6", "29b8db", "e5e5e5"]
        var palette = dark ? darkPalette : light
        if increasedContrast && !dark {
            palette[3] = "6b6e00"; palette[11] = "7d8000"; palette[15] = "6e6e6e"; palette[10] = "0a8a0a"
        }
        let fixed = theme != .system
        return .init(palette: palette, foreground: fixed ? (dark ? "edf1f7" : "1c2129") : nil,
                     background: fixed ? (dark ? "0e1218" : "ffffff") : nil,
                     cursor: dark ? "b4cbff" : "26384e", selection: dark ? "b4cbff" : "253f63",
                     selectionAlpha: increasedContrast ? 0.45 : (dark ? 0.25 : 0.2))
    }

    /// Applies font and colors without restarting a process.
    @MainActor public func apply(to view: TerminalView) {
        let font = font
        if view.font != font { view.font = font }
        let dark = isDark(appearance: view.effectiveAppearance)
        let colors = colors(dark: dark, increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        view.installColors(colors.palette.map(Self.terminalColor))
        view.nativeForegroundColor = colors.foreground.map(Self.nsColor) ?? .textColor
        view.nativeBackgroundColor = colors.background.map(Self.nsColor) ?? .textBackgroundColor
        view.caretColor = Self.nsColor(colors.cursor)
        view.selectedTextBackgroundColor = Self.nsColor(colors.selection).withAlphaComponent(colors.selectionAlpha)
        view.selectedTextForegroundColor = view.nativeForegroundColor
    }

    /// The background behind the terminal view, matching `apply(to:)`.
    public func backgroundColor(systemIsDark: Bool) -> NSColor {
        let dark = theme == .system ? systemIsDark : theme == .dark
        return colors(dark: dark).background.map(Self.nsColor) ?? .textBackgroundColor
    }

    static func components(_ hex: String) -> (UInt8, UInt8, UInt8) {
        let value = UInt32(hex, radix: 16) ?? 0
        return (UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff))
    }
    static func terminalColor(_ hex: String) -> SwiftTerm.Color {
        let (red, green, blue) = components(hex)
        return .init(red8: UInt16(red), green8: UInt16(green), blue8: UInt16(blue))
    }
    static func nsColor(_ hex: String) -> NSColor {
        let (red, green, blue) = components(hex)
        return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}
