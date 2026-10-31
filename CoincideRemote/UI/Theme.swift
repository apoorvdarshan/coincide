import CoincideRemoteKit
import Observation
import SwiftUI

/// The look the user picked: the Mac's own themes (followed by default) or ones chosen here.
@MainActor
@Observable
final class AppearanceSettings {
    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: String(localized: "System")
            case .light: String(localized: "Light")
            case .dark: String(localized: "Dark")
            }
        }
    }

    var followsMac: Bool { didSet { save() } }
    var mode: Mode { didSet { save() } }
    var darkThemeID: String { didSet { save() } }
    var lightThemeID: String { didSet { save() } }

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        followsMac = defaults.object(forKey: "theme.followsMac") as? Bool ?? true
        mode = Mode(rawValue: defaults.string(forKey: "theme.mode") ?? "") ?? .system
        darkThemeID = defaults.string(forKey: "theme.dark") ?? RemotePalette.defaultDarkID
        lightThemeID = defaults.string(forKey: "theme.light") ?? RemotePalette.defaultLightID
    }

    private func save() {
        defaults.set(followsMac, forKey: "theme.followsMac")
        defaults.set(mode.rawValue, forKey: "theme.mode")
        defaults.set(darkThemeID, forKey: "theme.dark")
        defaults.set(lightThemeID, forKey: "theme.light")
    }

    /// The appearance and themes in effect, from the Mac when following it.
    func resolved(server: RemoteServerInfo?) -> (mode: Mode, dark: RemotePalette, light: RemotePalette) {
        if followsMac, let theme = server?.theme {
            return (Mode(rawValue: theme.appearance) ?? .system, RemotePalette.dark(theme.darkThemeID), RemotePalette.light(theme.lightThemeID))
        }
        return (mode, RemotePalette.dark(darkThemeID), RemotePalette.light(lightThemeID))
    }
}

/// Colors of the theme in use, for the color scheme on screen.
struct Theme: Equatable {
    var palette: RemotePalette

    var sidebar: Color { Color(hex: palette.sidebar) }
    var content: Color { Color(hex: palette.content) }
    var surface: Color { Color(hex: palette.surface) }
    var raised: Color { Color(hex: palette.raised) }
    var border: Color { Color(hex: palette.border) }
    var accent: Color { Color(hex: palette.accent) }
    /// Buttons, toolbars and the tab bar: the theme's ink, as the Mac draws its chrome, so the accent stays for the
    /// few marks it highlights (the text cursor, a plan in progress).
    var control: Color { palette.ink.map { Color(hex: $0) } ?? (isDark ? .white : .black) }
    /// Text and symbols on a control-colored fill.
    var onControl: Color { isDark ? .black : .white }
    var ink: Color { palette.ink.map { Color(hex: $0) } ?? .primary }
    var secondaryInk: Color { ink.opacity(0.62) }
    /// The quietest text: a project's name after a pinned thread, disclosure triangles, archived marks.
    var tertiaryInk: Color { ink.opacity(0.38) }
    /// Agents' replies in New York, as the Mac sets them unless the user chose the system font.
    var serifReplies = true
    /// The user's messages on the left of the conversation rather than the right (Settings › General on the Mac).
    var userMessagesOnLeft = false
    var isDark: Bool { palette.isDark }
    var borderWidth: CGFloat { palette.borderWidth }
    /// A quiet fill for cards and the user's messages.
    var card: Color { (isDark ? Color.white : Color.black).opacity(0.05 * palette.emphasis) }
    var selection: Color { (isDark ? Color.white : Color.black).opacity(0.09 * palette.emphasis) }
    var codeBackground: Color { (isDark ? Color.white : Color.black).opacity(0.06) }

    func agent(_ provider: String?) -> Color {
        let colors = RemotePalette.agentColor(provider ?? "")
        return Color(hex: isDark ? colors.dark : colors.light)
    }

    static let fallback = Theme(palette: RemotePalette.dark[0])
}

/// The glass prominent button in the theme's control color, with its label in the color that reads on it.
private struct ProminentButton: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.buttonStyle(.glassProminent).foregroundStyle(theme.onControl)
    }
}

extension View {
    func prominentButton() -> some View { modifier(ProminentButton()) }
}

/// Switches in the system's green. The controls' tint is the theme's ink (white on dark themes), which would hide the
/// switch's white knob on its track.
struct ThemedSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(.green)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.fallback
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Puts the right palette in the environment for the color scheme on screen, and applies the appearance.
struct ThemedRoot<Content: View>: View {
    let appearance: AppearanceSettings
    let server: RemoteServerInfo?
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let resolved = appearance.resolved(server: server)
        let palette = colorScheme == .dark ? resolved.dark : resolved.light
        let theme = Theme(
            palette: palette, serifReplies: server?.usesSerifReplies ?? true,
            userMessagesOnLeft: server?.userMessageSide == "left")
        content
            .environment(\.theme, theme)
            .tint(theme.control)
            .preferredColorScheme(resolved.mode == .system ? nil : (resolved.mode == .dark ? .dark : .light))
    }
}

/// An agent's mark from the asset catalog, drawn as the Mac draws it (`Theme.logo(for:)`): Codex, Cursor, Grok and
/// OpenCode have one-color marks that take the color of the text around them; Claude's and Antigravity's keep their own.
struct AgentLogo: View {
    let provider: String
    var size: CGFloat = 16
    /// The color of a one-color mark: the theme's text color unless the row is quieter (archived, say).
    var tint: Color?
    @Environment(\.theme) private var theme

    var body: some View {
        Image(Self.assetName(provider))
            .resizable()
            .renderingMode(Self.keepsColors(provider) ? .original : .template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(tint ?? theme.ink)
            .accessibilityHidden(true)
    }

    /// Whether the mark keeps its own colors rather than taking the text's.
    static func keepsColors(_ provider: String) -> Bool { provider == "claude" || provider == "antigravity" }

    static func assetName(_ provider: String) -> String {
        switch provider {
        case "claude": "AgentClaude"
        case "codex": "AgentCodex"
        case "cursor": "AgentCursor"
        case "grok": "AgentGrok"
        case "opencode": "AgentOpenCode"
        case "antigravity": "AgentAntigravity"
        default: "AgentCodex"
        }
    }

    static func name(_ provider: String) -> String {
        switch provider {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "cursor": "Cursor"
        case "grok": "Grok Build"
        case "opencode": "OpenCode"
        case "antigravity": "Antigravity"
        default: provider.capitalized
        }
    }
}
