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

    /// The transcript and composer are centered in a column no wider than this.
    static let contentMaxWidth: CGFloat = 820
    static let horizontalPadding: CGFloat = 24
    static let cornerRadius: CGFloat = 10
    static let smallCornerRadius: CGFloat = 6

    static var secondaryText: NSColor { .secondaryLabelColor }
    static var tertiaryText: NSColor { .tertiaryLabelColor }
    static var separator: NSColor { .separatorColor }
    static let userBubble = dynamic(.controlAccentColor, alpha: 0.12)
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
    static let questionTint = dynamic(.controlAccentColor, alpha: 0.08)
    static let dropTint = dynamic(.controlAccentColor, alpha: 0.12)
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

    static func color(for provider: ProviderKind) -> NSColor {
        switch provider {
        case .claude: NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case .codex: NSColor.labelColor
        case .cursor: NSColor.systemIndigo
        case .grok: NSColor.systemGray
        case .opencode: NSColor.systemTeal
        case .antigravity: NSColor.systemBlue
        }
    }

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}
