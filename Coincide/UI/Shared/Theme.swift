import AppKit
import CoincideKit

/// Shared look: fonts, spacing and colors. Colors are semantic so light and dark mode both work.
enum Theme {
    static var fontSize: CGFloat { CGFloat(AppStore.shared.settings.fontSize) }
    static var bodyFont: NSFont { .systemFont(ofSize: fontSize) }
    static var boldFont: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }
    static var smallFont: NSFont { .systemFont(ofSize: fontSize - 2) }
    static var monoFont: NSFont { .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular) }
    static var smallMonoFont: NSFont { .monospacedSystemFont(ofSize: fontSize - 2, weight: .regular) }
    /// Agents' replies, in New York unless the user chose the system font. New York runs small next to San Francisco,
    /// so it is set a point larger.
    static var usesSerifReplies: Bool { AppStore.shared.settings.replyTypeface == .newYork }
    static var replyFontSize: CGFloat { usesSerifReplies ? fontSize + 1 : fontSize }
    /// Where the user's messages sit in the conversation (Settings › General › Your messages).
    static var userMessageSide: UserMessageSide { AppStore.shared.settings.userMessageSide }

    /// The height of a line of `font`, cached since rows ask on every layout.
    static func lineHeight(of font: NSFont) -> CGFloat {
        if let height = lineHeights[font] { return height }
        let height = NSLayoutManager().defaultLineHeight(for: font)
        lineHeights[font] = height
        return height
    }

    private static var lineHeights: [NSFont: CGFloat] = [:]

    /// New York, Apple's serif, in a weight of the system font.
    static func serifFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// The transcript and composer are centered in a column no wider than this.
    static let contentMaxWidth: CGFloat = 820
    /// The gutter left of the transcript where the agent rail runs.
    static let railGutter: CGFloat = 34
    static let horizontalPadding: CGFloat = 24
    static let cornerRadius: CGFloat = 10
    static let smallCornerRadius: CGFloat = 6

    static var secondaryText: NSColor { .secondaryLabelColor }
    static var tertiaryText: NSColor { .tertiaryLabelColor }
    static var separator: NSColor { .separatorColor }
    /// The window's surfaces, flat and opaque, from the dark or light theme in use (`AppTheme`): the rail and thread
    /// list, the conversation, the composer and panels, and the bars over the conversation.
    static let sidebarBackground = ThemeSelection.color { $0.sidebar }
    static let contentBackground = ThemeSelection.color { $0.content }
    static let composerFill = ThemeSelection.color { $0.surface }
    static let raisedFill = ThemeSelection.color { $0.raised }
    static let floatingFill = ThemeSelection.color { $0.surface }
    static let surfaceBorder = ThemeSelection.color { $0.border }
    /// The conversation's text.
    static let ink = ThemeSelection.color { $0.ink ?? .labelColor }
    /// Rows and buttons while hovered and while selected or pressed.
    static let sidebarHover = ThemeSelection.color { theme in
        (theme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.05 * theme.emphasis)
    }
    static let sidebarSelection = ThemeSelection.color { theme in
        (theme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.09 * theme.emphasis)
    }

    /// The width of surface borders: wider in the High Contrast theme.
    static func borderWidth(for appearance: NSAppearance) -> CGFloat {
        ThemeSelection.shared.theme(for: appearance).borderWidth
    }

    /// The user's messages sit on a quiet card, so the agents' replies carry the color.
    static let userBubble = dynamic(.labelColor, alpha: 0.06)
    static let codeBackground = dynamic(.labelColor, alpha: 0.06)
    static let cardBackground = dynamic(.labelColor, alpha: 0.04)
    static var success: NSColor { .systemGreen }
    static var failure: NSColor { .systemRed }
    static var warning: NSColor { .systemOrange }
    static let addition = dynamic(.systemGreen, alpha: 0.16)
    static let deletion = dynamic(.systemRed, alpha: 0.16)
    /// The outline of a card that waits for the user.
    static let waitingStroke = dynamic(.systemOrange, alpha: 0.45)
    static let failureFill = dynamic(.systemRed, alpha: 0.07)
    static let failureStroke = dynamic(.systemRed, alpha: 0.3)
    /// Glass tints of the banners above the composer.
    static let approvalTint = dynamic(.systemOrange, alpha: 0.1)
    static let questionTint = ThemeSelection.color { theme in
        (theme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.03 * theme.emphasis)
    }
    static let dropTint = ThemeSelection.color { theme in
        (theme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.06 * theme.emphasis)
    }
    /// Selected text: the theme's accent laid over whatever is behind it, in place of the system's blue.
    nonisolated static let textSelection = ThemeSelection.color { theme in
        theme.accent.withAlphaComponent(theme.isDark ? 0.38 : 0.26)
    }
    /// Selected text in a view that isn't taking keystrokes.
    nonisolated static let inactiveTextSelection = ThemeSelection.color { theme in
        theme.accent.withAlphaComponent(theme.isDark ? 0.2 : 0.14)
    }
    /// The theme's accent, for the caret.
    static let accent = ThemeSelection.color { $0.accent }
    /// The selection drawn opaque over `background`, for views that can't blend a translucent one.
    static func opaqueTextSelection(over background: NSColor) -> NSColor {
        ThemeSelection.color { theme in
            let base = background
            var color = base
            NSAppearance(named: theme.isDark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                color = base.usingColorSpace(.sRGB)?.blended(withFraction: theme.isDark ? 0.38 : 0.26, of: theme.accent) ?? base
            }
            return color
        }
    }
    /// @-mentions of files in the composer: the text color, a step quieter than the words around them.
    static let mention = ThemeSelection.color { theme in
        (theme.ink ?? .labelColor).withAlphaComponent(0.7)
    }
    static let tableHeaderFill = dynamic(.labelColor, alpha: 0.04)

    /// `withAlphaComponent` resolves a dynamic color once, for whatever appearance is current, so colors
    /// kept on views or layers would go stale after a light/dark switch. This one re-resolves per appearance.
    static func dynamic(_ base: NSColor, alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var color = base
            appearance.performAsCurrentDrawingAppearance { color = base.withAlphaComponent(alpha) }
            return color
        }
    }

    /// Each agent's color, used for its rail in the transcript and wherever it is named. Close to the agent's own
    /// brand color, deeper in light mode and lighter in dark mode so both read on the window.
    static func color(for provider: ProviderKind) -> NSColor {
        switch provider {
        case .claude: agentColors.claude
        case .codex: agentColors.codex
        case .cursor: agentColors.cursor
        case .grok: agentColors.grok
        case .opencode: agentColors.opencode
        case .antigravity: agentColors.antigravity
        }
    }

    private static let agentColors = (
        claude: color(light: 0xC2603D, dark: 0xE08A6B),
        codex: color(light: 0x0E8A6A, dark: 0x3CC79A),
        cursor: color(light: 0x5A5FD6, dark: 0x9A9EFF),
        grok: color(light: 0x6B7077, dark: 0xA9AEB4),
        opencode: color(light: 0xB7700C, dark: 0xE9B04E),
        antigravity: color(light: 0x2F6BDB, dark: 0x6FA3FF)
    )

    /// A color with one sRGB value for light mode and one for dark mode.
    static func color(light: UInt32, dark: UInt32) -> NSColor {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
        }
    }

    /// The agent's own mark. Codex, Cursor, Grok and OpenCode have one-color marks, drawn as templates so they take
    /// the color of the text around them; Claude's and Antigravity's keep their colors.
    static func logo(for provider: ProviderKind) -> NSImage {
        let image = NSImage(named: logoName(for: provider)) ?? NSImage()
        image.accessibilityDescription = provider.displayName
        return image
    }

    /// The logo's name in the asset catalog, for SwiftUI.
    static func logoName(for provider: ProviderKind) -> String {
        switch provider {
        case .claude: "AgentClaude"
        case .codex: "AgentCodex"
        case .cursor: "AgentCursor"
        case .grok: "AgentGrok"
        case .opencode: "AgentOpenCode"
        case .antigravity: "AgentAntigravity"
        }
    }

    /// The logo at `size` points, for menus and other places that draw images at their own size.
    static func logo(for provider: ProviderKind, size: CGFloat) -> NSImage {
        let source = logo(for: provider)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = source.isTemplate
        image.accessibilityDescription = source.accessibilityDescription
        return image
    }

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}
