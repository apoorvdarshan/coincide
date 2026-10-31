import CoincideRemoteKit
import SwiftUI

/// Over the composer, as on the Mac (`ComposerUsageBanner`): the thread's agent has nearly or wholly used a limit
/// window. The Mac words it and decides when it shows; the phone offers the same "Resume at Reset" or "Cancel
/// Auto-Resume", "Details" (Settings › Usage) and dismissing it. `UsageWarningPolling` reads it again when the thread
/// opens, when a turn starts or ends, and every minute while the thread is on screen.
struct UsageWarningBanner: View {
    let model: ThreadModel
    @Binding var warning: RemoteUsageWarning?
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @State private var isBusy = false

    private static let warningColor = Color.orange

    var body: some View {
        if let warning {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "gauge.with.needle")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Self.warningColor)
                        .accessibilityHidden(true)
                    Text(warning.text)
                        .font(.footnote)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { act(.dismiss, warning) } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.secondaryInk)
                            .frame(width: 32, height: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, -6)
                    .padding(.trailing, -6)
                    .accessibilityLabel(Text("Dismiss"))
                }
                ProgressView(value: min(max(warning.fraction, 0), 1))
                    .tint(Self.warningColor)
                    .accessibilityHidden(true)
                HStack(spacing: 8) {
                    if warning.resumesAt != nil {
                        Button("Cancel Auto-Resume") { act(.cancelResume, warning) }
                            .buttonStyle(.glass)
                    } else if warning.canResumeAtReset {
                        Button("Resume at Reset") { act(.resumeAtReset, warning) }
                            .buttonStyle(.glass)
                            .accessibilityHint(Text("Continue this thread on its own once the limit resets."))
                    }
                    Button("Details") {
                        navigator.settingsPane = .mac("usage")
                        navigator.tab = .settings
                    }
                    .buttonStyle(.glass)
                    .accessibilityHint(Text("Show every usage limit and when it resets"))
                }
                .font(.footnote)
                .disabled(isBusy || !client.isConnected)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Self.warningColor.opacity(0.35), lineWidth: max(theme.borderWidth, 1)))
            .transition(.opacity)
        }
    }

    private func act(_ action: RemoteUsageWarningCommand.Action, _ shown: RemoteUsageWarning) {
        if action == .dismiss { withAnimation { warning = nil } }
        isBusy = true
        Task {
            if let notice = await client.usageWarning(action, key: shown.key, in: model.id) { warning = notice.usageWarning }
            isBusy = false
        }
    }
}

/// Keeps a thread's usage-limit banner current: when the thread opens, when a turn starts or ends, and every minute.
struct UsageWarningPolling: ViewModifier {
    let model: ThreadModel
    @Binding var warning: RemoteUsageWarning?
    @Environment(RemoteClient.self) private var client

    func body(content: Content) -> some View {
        content.task(id: "\(model.id)|\(model.turn.isRunning)") {
            while !Task.isCancelled {
                if let notice = await client.composerNotice(model.id) { warning = notice.usageWarning }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}
