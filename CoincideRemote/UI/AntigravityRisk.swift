import SwiftUI

/// Antigravity's account risk, as the Mac shows it in Settings › Antigravity: Google's Antigravity terms forbid
/// reaching the service with third-party tools, and Google has suspended accounts for it. The phone shows the same
/// notice and glyph wherever Antigravity appears, keyed by its provider id, so it needs nothing new from the Mac.
enum AntigravityRisk {
    static let providerID = "antigravity"
    /// The Mac's Settings page for Antigravity (`RemoteSettingsCatalog`).
    static let pageID = "provider.antigravity"
    static let termsURL = URL(string: "https://antigravity.google/terms")!

    static func applies(toProvider id: String?) -> Bool { id == providerID }

    static func applies(toPage id: String?) -> Bool { id == pageID }

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

    /// The one line beside Antigravity in a picker.
    static var short: String { String(localized: "May break Google’s Antigravity terms") }

    static var glyphLabel: String { String(localized: "Antigravity account risk") }
}

/// The caution card: the warning triangle on a soft tile, the notice, and Google's terms. `compact` leaves out the
/// heading and the API-key note, for a row under a picker.
struct AntigravityRiskNotice: View {
    var compact = false
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 30

    var body: some View {
        if compact {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AntigravityRiskGlyph()
                VStack(alignment: .leading, spacing: 6) {
                    Text(AntigravityRisk.notice)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    termsLink
                }
            }
            .padding(.vertical, 2)
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: tile * 0.5, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: tile, height: tile)
                    .background(RoundedRectangle(cornerRadius: tile * 0.28, style: .continuous).fill(Color.orange.opacity(0.16)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(AntigravityRisk.title)
                        .font(.headline)
                        .foregroundStyle(theme.ink)
                    Text(AntigravityRisk.notice)
                        .font(.subheadline)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AntigravityRisk.apiKeyNote)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    termsLink.padding(.top, 2)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var termsLink: some View {
        Link(destination: AntigravityRisk.termsURL) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                Text(AntigravityRisk.readTerms)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(theme.ink)
        }
    }
}

/// The small warning triangle beside Antigravity's name.
struct AntigravityRiskGlyph: View {
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 12

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color.orange)
            .accessibilityLabel(Text(AntigravityRisk.glyphLabel))
    }
}
