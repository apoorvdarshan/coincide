import AppKit
import CoincideKit
import SwiftUI

/// What Coincide says about Antigravity's account risk (`AntigravityAccountRisk`): short and factual, the same words in
/// Settings, the acknowledgement sheet and the glyphs' tooltips.
enum AntigravityRiskText {
    static var title: String { String(localized: "Antigravity Account Risk") }

    static var notice: String {
        String(
            localized:
                "Using Antigravity through Coincide may break Google’s Antigravity terms, which forbid accessing it with third-party tools. Google has suspended accounts for this, including access to Gemini CLI and Code Assist. Use at your own risk; consider a separate Google account."
        )
    }

    static var apiKeyNote: String {
        String(localized: "Gemini API keys from Google AI Studio or Gemini Enterprise aren’t affected.")
    }

    static var readTerms: String { String(localized: "Read Google’s terms") }

    /// The tooltip of the glyph beside Antigravity in pickers and lists.
    static var glyphHelp: String {
        String(localized: "Using Antigravity through Coincide may break Google’s terms. Details are in Settings › Antigravity.")
    }

    static var glyphLabel: String { String(localized: "Antigravity account risk") }
}

/// The small warning glyph beside Antigravity wherever it's chosen (the model picker, the bot editor). A click opens
/// Settings › Antigravity, where the notice and Google's terms are.
final class AntigravityRiskBadge: NSButton {
    var onOpenSettings: (() -> Void)?

    init(size: CGFloat = 11) {
        super.init(frame: .zero)
        image = Theme.symbol("exclamationmark.triangle.fill", size: size, weight: .semibold)
        imagePosition = .imageOnly
        isBordered = false
        title = ""
        contentTintColor = Theme.warning
        toolTip = AntigravityRiskText.glyphHelp
        setAccessibilityLabel(AntigravityRiskText.glyphLabel)
        setAccessibilityHelp(AntigravityRiskText.glyphHelp)
        target = self
        action = #selector(clicked)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clicked() {
        if let onOpenSettings {
            onOpenSettings()
        } else {
            AppEvents.showSettings(provider: .antigravity)
        }
    }
}

/// The same glyph for SwiftUI lists in Settings, where a click on its row already opens Antigravity's page.
struct AntigravityRiskGlyph: View {
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color(nsColor: Theme.warning))
            .help(Text(AntigravityRiskText.glyphHelp))
            .accessibilityLabel(Text(AntigravityRiskText.glyphLabel))
    }
}
