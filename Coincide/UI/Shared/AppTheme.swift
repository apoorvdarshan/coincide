import AppKit
import CoincideKit
import Synchronization

/// A color theme for the window's surfaces: the rail and thread list, the conversation, the composer and panels,
/// their borders and the conversation's text. Coincide uses one dark theme and one light theme, and shows whichever
/// matches the appearance. Controls and menus keep the system's colors.
nonisolated struct AppTheme: Identifiable, @unchecked Sendable {
    let id: String
    /// A proper name, the same in every language.
    let name: String
    let isDark: Bool
    /// The navigation rail and the thread list.
    let sidebar: NSColor
    let content: NSColor
    /// The composer and the floating panels.
    let surface: NSColor
    /// Bars and banners over the conversation.
    let raised: NSColor
    let border: NSColor
    var borderWidth: CGFloat = 1
    /// The conversation's text, or nil for the system's label color.
    var ink: NSColor?
    /// How strongly hovered and selected rows are filled.
    var emphasis: CGFloat = 1

    static let defaultDarkID = "carbon"
    static let defaultLightID = "carbon-light"

    static let dark: [AppTheme] = [
        AppTheme(
            id: "carbon", name: "Carbon", isDark: true, sidebar: hex(0x0B0B0B), content: hex(0x000000), surface: hex(0x161616),
            raised: hex(0x141414), border: hex(0x2A2A2A)),
        AppTheme(
            id: "graphite", name: "Graphite", isDark: true, sidebar: hex(0x181818), content: hex(0x212121),
            surface: hex(0x2B2B2B), raised: hex(0x282828), border: NSColor(white: 1, alpha: 0.08)),
        AppTheme(
            id: "midnight", name: "Midnight", isDark: true, sidebar: hex(0x0E1320), content: hex(0x141A28),
            surface: hex(0x1C2333), raised: hex(0x1A2130), border: hex(0x2A3347), ink: hex(0xDCE3F0)),
        AppTheme(
            id: "slate", name: "Slate", isDark: true, sidebar: hex(0x23262B), content: hex(0x2A2E34), surface: hex(0x333840),
            raised: hex(0x31353C), border: hex(0x40464F), ink: hex(0xD8DCE2)),
        AppTheme(
            id: "forest", name: "Forest", isDark: true, sidebar: hex(0x0D1410), content: hex(0x111A15), surface: hex(0x18241D),
            raised: hex(0x16211A), border: hex(0x26362C), ink: hex(0xD4E2D8)),
        AppTheme(
            id: "plum", name: "Plum", isDark: true, sidebar: hex(0x140F18), content: hex(0x1A1420), surface: hex(0x241B2C),
            raised: hex(0x211928), border: hex(0x352841), ink: hex(0xE6DDF0)),
        AppTheme(
            id: "ocean", name: "Ocean", isDark: true, sidebar: hex(0x08161B), content: hex(0x0C1D23), surface: hex(0x12292F),
            raised: hex(0x10252B), border: hex(0x1E3B43), ink: hex(0xD3EBEF)),
        AppTheme(
            id: "ember", name: "Ember", isDark: true, sidebar: hex(0x15100D), content: hex(0x1B1512), surface: hex(0x261D18),
            raised: hex(0x231B16), border: hex(0x3A2C24), ink: hex(0xEDE2D6)),
        AppTheme(
            id: "dusk", name: "Dusk", isDark: true, sidebar: hex(0x12111F), content: hex(0x171627), surface: hex(0x201F35),
            raised: hex(0x1D1C31), border: hex(0x2F2D4A), ink: hex(0xDEDCF5)),
        AppTheme(
            id: "phosphor", name: "Phosphor", isDark: true, sidebar: hex(0x040805), content: hex(0x060B07),
            surface: hex(0x0D150F), raised: hex(0x0B130D), border: hex(0x1C2B1F), ink: hex(0xB7F5C2)),
        AppTheme(
            id: "high-contrast", name: "High Contrast", isDark: true, sidebar: hex(0x000000), content: hex(0x000000),
            surface: hex(0x000000), raised: hex(0x000000), border: hex(0xFFFFFF), borderWidth: 2, ink: hex(0xFFFFFF),
            emphasis: 2.5),
    ]

    static let light: [AppTheme] = [
        AppTheme(
            id: "carbon-light", name: "Carbon Light", isDark: false, sidebar: hex(0xF5F5F5), content: hex(0xFFFFFF),
            surface: hex(0xFFFFFF), raised: hex(0xF5F5F5), border: hex(0xE1E1E1), ink: hex(0x111111)),
        AppTheme(
            id: "paper", name: "Paper", isDark: false, sidebar: hex(0xF2F0EC), content: hex(0xFBFAF8), surface: hex(0xFFFFFF),
            raised: hex(0xF2F0EC), border: hex(0xE4E0D8)),
        AppTheme(
            id: "arctic", name: "Arctic", isDark: false, sidebar: hex(0xEDF2F6), content: hex(0xF7FAFC), surface: hex(0xFFFFFF),
            raised: hex(0xEDF2F6), border: hex(0xD9E2EA), ink: hex(0x1E2A36)),
        AppTheme(
            id: "sepia", name: "Sepia", isDark: false, sidebar: hex(0xEEE5D3), content: hex(0xF6EFE1), surface: hex(0xFBF6EC),
            raised: hex(0xEEE5D3), border: hex(0xDDD0B8), ink: hex(0x3B2F22)),
        AppTheme(
            id: "rose", name: "Rose", isDark: false, sidebar: hex(0xF5EBED), content: hex(0xFCF6F7), surface: hex(0xFFFFFF),
            raised: hex(0xF5EBED), border: hex(0xEBD8DC), ink: hex(0x2E1D24)),
        AppTheme(
            id: "lavender", name: "Lavender", isDark: false, sidebar: hex(0xEFEBF8), content: hex(0xF8F6FC),
            surface: hex(0xFFFFFF), raised: hex(0xEFEBF8), border: hex(0xDDD6EE), ink: hex(0x241F33)),
        AppTheme(
            id: "sand", name: "Sand", isDark: false, sidebar: hex(0xEDE9E1), content: hex(0xF7F5F0), surface: hex(0xFFFFFF),
            raised: hex(0xEDE9E1), border: hex(0xDDD7CB), ink: hex(0x2B2A24)),
        AppTheme(
            id: "mint", name: "Mint", isDark: false, sidebar: hex(0xEAF4EE), content: hex(0xF5FAF7), surface: hex(0xFFFFFF),
            raised: hex(0xEAF4EE), border: hex(0xD3E6DA), ink: hex(0x1C2A22)),
    ]

    static func dark(_ id: String) -> AppTheme {
        dark.first { $0.id == id } ?? dark[0]
    }

    static func light(_ id: String) -> AppTheme {
        light.first { $0.id == id } ?? light[0]
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// A small picture of the theme for its menu item: the rail, the conversation and a composer.
    func swatch(size: NSSize = NSSize(width: 28, height: 18)) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            content.setFill()
            outline.fill()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            sidebar.setFill()
            NSRect(x: 0, y: 0, width: rect.width * 0.32, height: rect.height).fill()
            surface.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.width * 0.42, y: 3, width: rect.width * 0.5, height: 5), xRadius: 2, yRadius: 2)
                .fill()
            (ink ?? (isDark ? NSColor.white : NSColor.black)).withAlphaComponent(0.8).setFill()
            NSRect(x: rect.width * 0.42, y: rect.height - 6, width: rect.width * 0.4, height: 1.5).fill()
            NSGraphicsContext.restoreGraphicsState()
            border.setStroke()
            outline.lineWidth = 1
            outline.stroke()
            return true
        }
    }
}

/// The dark and light themes in use. Colors resolve through it on whatever thread draws them, so it is locked rather
/// than tied to the main actor; `ThemeController` keeps it in step with settings.
nonisolated final class ThemeSelection: Sendable {
    static let shared = ThemeSelection()

    private let ids = Mutex((dark: AppTheme.defaultDarkID, light: AppTheme.defaultLightID))

    func set(dark: String, light: String) {
        ids.withLock { $0 = (dark, light) }
    }

    func theme(for appearance: NSAppearance) -> AppTheme {
        let (dark, light) = ids.withLock { $0 }
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? AppTheme.dark(dark) : AppTheme.light(light)
    }

    /// A color that takes `key` from the theme of the appearance it is drawn in.
    nonisolated static func color(_ key: @escaping @Sendable (AppTheme) -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in key(ThemeSelection.shared.theme(for: appearance)) }
    }
}

/// Applies the themes chosen in settings, and redraws the windows when they change.
final class ThemeController {
    static let shared = ThemeController()

    private var token: ObservationToken?
    private var applied: (dark: String, light: String)?

    /// Applies the saved themes and follows settings. Called once at launch.
    func start() {
        guard token == nil else { return }
        apply(redraw: false)
        token = AppStore.shared.observe { [weak self] change in
            guard change == .settings else { return }
            self?.apply(redraw: true)
        }
    }

    private func apply(redraw: Bool) {
        let settings = AppStore.shared.settings
        guard applied?.dark != settings.darkTheme || applied?.light != settings.lightTheme else { return }
        applied = (settings.darkTheme, settings.lightTheme)
        ThemeSelection.shared.set(dark: settings.darkTheme, light: settings.lightTheme)
        guard redraw else { return }
        // Views resolve their colors when the appearance changes, so passing every window through another appearance
        // and back has them all pick up the new theme, layers included.
        for window in NSApp.windows {
            let appearance = window.appearance
            window.appearance = NSAppearance(named: window.effectiveAppearance.isDark ? .aqua : .darkAqua)
            window.appearance = appearance
            window.backgroundColor = Theme.contentBackground
            window.contentView?.needsDisplay = true
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
