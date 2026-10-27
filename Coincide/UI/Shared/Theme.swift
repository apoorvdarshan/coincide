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
    static var userBubble: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.12) }
    static var codeBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }
    static var cardBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.04) }
    static var success: NSColor { .systemGreen }
    static var failure: NSColor { .systemRed }
    static var warning: NSColor { .systemOrange }
    static var addition: NSColor { NSColor.systemGreen.withAlphaComponent(0.16) }
    static var deletion: NSColor { NSColor.systemRed.withAlphaComponent(0.16) }

    static func color(for provider: ProviderKind) -> NSColor {
        switch provider {
        case .claude: NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case .codex: NSColor.labelColor
        case .cursor: NSColor.systemIndigo
        case .grok: NSColor.systemGray
        case .opencode: NSColor.systemTeal
        case .pi: NSColor.systemPurple
        case .antigravity: NSColor.systemBlue
        }
    }

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}
