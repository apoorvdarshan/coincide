import CoincideKit
import SwiftUI

/// The caution at the top of Settings › Antigravity, shown whether Antigravity is on or off: what Google's terms say,
/// what has happened to accounts, and a link to the terms themselves.
struct AntigravityRiskNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AntigravityRiskSymbol(size: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text(AntigravityRiskText.title)
                    .font(.headline)
                Text(AntigravityRiskText.notice)
                    .foregroundStyle(Color(nsColor: Theme.ink))
                    .fixedSize(horizontal: false, vertical: true)
                Text(AntigravityRiskText.apiKeyNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AntigravityTermsLink()
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// Asked once, before the first Google sign-in or before Antigravity is turned on (`AntigravityRiskGate`). Nothing
/// starts until the user chooses I Understand; Cancel leaves everything as it was.
struct AntigravityRiskSheet: View {
    let gate: AntigravityRiskGate

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                AntigravityRiskSymbol(size: 34)
                Text(AntigravityRiskText.title)
                    .font(.title3.weight(.semibold))
            }
            Text(AntigravityRiskText.notice)
                .foregroundStyle(Color(nsColor: Theme.ink))
                .fixedSize(horizontal: false, vertical: true)
            Text(AntigravityRiskText.apiKeyNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AntigravityTermsLink()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { gate.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("I Understand") { gate.acknowledge() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 440)
        .background(Color(nsColor: Theme.contentBackground))
        .buttonStyle(ThemedButtonStyle())
        .tint(Color(nsColor: Theme.ink))
    }
}

/// The warning triangle on a soft tile of the warning color, as Settings draws its pane icons.
private struct AntigravityRiskSymbol: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color(nsColor: Theme.warning).opacity(0.16))
            .overlay {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.warning))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct AntigravityTermsLink: View {
    var body: some View {
        Link(destination: AntigravityAccountRisk.termsURL) {
            Label(AntigravityRiskText.readTerms, systemImage: "arrow.up.right.square")
        }
        .font(.callout)
        .help(Text(verbatim: AntigravityAccountRisk.termsURL.absoluteString))
    }
}
