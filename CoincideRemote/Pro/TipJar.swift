import CoincideRemoteKit
import SwiftUI

/// Support Coincide: the four tips at the App Store's prices, above Help & Community in Settings, which needs no
/// Coincide Pro. A tip says thank you and unlocks nothing. The list they're in shows the thank-you and any failure
/// (`tipJarPresentations`), since a row's own sheet goes when the row scrolls away.
struct TipJarRows: View {
    @Environment(ProStore.self) private var store
    @Environment(\.theme) private var theme

    /// The header's id, for scrolling to the tips.
    static let id = "tipJar"

    var body: some View {
        SidebarHeader(Text("Support Coincide"))
            .sidebarRow()
            .id(Self.id)
            .task { if store.tips.isEmpty { await store.loadOfferings() } }
        if store.tips.isEmpty {
            SidebarNote(text: note, symbol: store.loading == .loading ? nil : "heart")
                .frame(minHeight: 44)
                .sidebarRow()
        } else {
            ForEach(store.tips) { tip in TipRow(tip: tip) { Task { await store.give(tip) } } }
        }
        Text("Tips are a thank-you for the work on Coincide. They unlock nothing.")
            .font(.footnote)
            .foregroundStyle(theme.tertiaryInk)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .sidebarRow()
    }

    private var note: String {
        switch store.loading {
        case .loading, .idle: String(localized: "Loading tips…")
        case .failed, .loaded: String(localized: "Tips aren’t available right now.")
        }
    }

}

extension View {
    /// The thank-you after a tip and the alert when one fails, for the view holding `TipJarRows`. Only one view on screen
    /// may present them (`isEnabled`).
    func tipJarPresentations(_ store: ProStore, isEnabled: Bool = true) -> some View {
        let thanks = Binding(get: { isEnabled ? store.thanks : nil }, set: { store.thanks = $0 })
        return sheet(item: thanks) { kind in TipThanksView(tip: kind) }
            .alert(
                store.tipMessage?.title ?? "",
                isPresented: Binding(get: { isEnabled && store.tipMessage != nil }, set: { if !$0 { store.tipMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.tipMessage?.text ?? "")
            }
    }
}

/// A tip in the sidebar's look: its tile and name, and its price on a button-like capsule.
private struct TipRow: View {
    let tip: Tip
    let give: () -> Void
    @Environment(ProStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: give) {
            HStack(spacing: 10) {
                SettingsTileLabel(title: tip.kind.title, symbol: tip.kind.symbol, color: tip.kind.color)
                if store.busy == tip.id {
                    ProgressView().controlSize(.small)
                } else {
                    Text(verbatim: tip.price)
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(theme.selection, in: .capsule)
                }
            }
        }
        .buttonStyle(SidebarRowButtonStyle())
        .disabled(store.busy != nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Gives a tip. It unlocks nothing."))
        .sidebarRow()
    }
}

/// After a tip: the bot characters say thank you.
struct TipThanksView: View {
    let tip: TipKind
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: -10) {
                BotAvatarImage(avatar: RemoteBotAvatar(.teddy, .caramel), size: 56)
                BotAvatarImage(avatar: RemoteBotAvatar(.brulee, .rose), size: 76)
                BotAvatarImage(avatar: RemoteBotAvatar(.alien, .mint), size: 56)
            }
            .accessibilityHidden(true)
            Text("Thank You!")
                .font(.title2.bold())
                .foregroundStyle(theme.ink)
            Text(tip.thanks)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.secondaryInk)
            Button {
                dismiss()
            } label: {
                Text("Done").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .prominentButton()
        }
        .padding(24)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.sidebar.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
