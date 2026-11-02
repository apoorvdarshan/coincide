import CoincideRemoteKit
import StoreKit
import SwiftUI

/// Unlock Coincide: what the app does, the Coincide Pro plans at the App Store's prices for this account, and the terms
/// Apple asks for, in the theme's colors. Yearly, with its free trial, is picked first.
///
/// A sheet that closes (`ProGate` shows it for an action that needs Coincide Pro, once after the first pairing, and from
/// the Connect screen), and Settings' Coincide Pro pane, which says what's active once it's on.
struct PaywallView: View {
    enum Mode {
        /// Over the app, with a close button.
        case sheet
        /// Settings › Coincide Pro.
        case pane
    }

    var mode = Mode.pane
    /// Closes the sheet (`PaywallPresenter`).
    var close: () -> Void = {}
    @Environment(ProStore.self) private var store
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selected = ProPlan.Kind.annual
    @State private var managing = false
    @State private var alert: ProStore.Message?

    private var selectedPlan: ProPlan? { store.plans.first { $0.kind == selected } ?? store.plans.first }
    private var isSheet: Bool { mode == .sheet }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if store.isPro { activeCard }
                highlights
                if !store.isPro { plans }
                Text("Coincide for Mac is free and open source. Coincide Pro unlocks the iPhone and iPad app.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryInk)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                terms
                links
            }
            .frame(maxWidth: 600)
            .padding(.horizontal, 20)
            .padding(.top, isSheet ? 28 : 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.sidebar.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !store.isPro, selectedPlan != nil { purchaseBar }
        }
        .navigationTitle(Text(verbatim: mode == .pane ? "Coincide Pro" : ""))
        .navigationBarTitleDisplayMode(.inline)
        // As a sheet, a close button over the content instead of a bar, so the plans fit on the first screen.
        .toolbarVisibility(isSheet ? .hidden : .automatic, for: .navigationBar)
        .overlay(alignment: .topTrailing) {
            if isSheet {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(.top, 12)
                .padding(.trailing, 16)
                .accessibilityLabel(Text("Close"))
            }
        }
        .task {
            await store.loadOfferings()
            await store.refresh()
        }
        .onChange(of: store.plans.map(\.kind)) { _, kinds in
            if !kinds.contains(selected), let first = kinds.first { selected = first }
        }
        .manageSubscriptionsSheet(isPresented: $managing)
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert?.text ?? "")
        }
    }

    // MARK: Header and highlights

    private var header: some View {
        VStack(spacing: 6) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(theme.border, lineWidth: theme.borderWidth))
                .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.15), radius: 16, y: 6)
                .accessibilityHidden(true)
                .padding(.bottom, 2)
            Text(verbatim: "COINCIDE PRO")
                .font(.caption.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(theme.onControl)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.control, in: .capsule)
                .accessibilityLabel(Text(verbatim: "Coincide Pro"))
            Text(store.isPro ? String(localized: "Coincide Is Unlocked") : String(localized: "Unlock Coincide"))
                .font(.title.bold())
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(store.isPro
                ? String(localized: "Thank you for supporting Coincide!")
                : String(localized: "Drive the coding agents on your Mac from your iPhone and iPad."))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.secondaryInk)
        }
    }

    /// What the app does, compact enough that the plans show on the first screen: tiles two by two.
    private var highlights: some View {
        let all = CoincideHighlight.allCases
        let rows = stride(from: 0, to: all.count, by: 2).map { Array(all[$0..<min($0 + 2, all.count)]) }
        return VStack(spacing: 8) {
            ForEach(rows, id: \.first) { row in
                HStack(spacing: 8) {
                    ForEach(row) { item in highlightTile(item) }
                }
            }
        }
    }

    private func highlightTile(_ item: CoincideHighlight) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 10) {
            item.tile(size: 28)
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.ink)
                // Room for longer languages' names (German's lock screen alerts take three lines).
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if store.isPro {
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                    .accessibilityLabel(Text("Included"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(theme.surface, in: shape)
        .overlay(shape.strokeBorder(theme.border, lineWidth: theme.borderWidth))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(item.detail))
    }

    // MARK: Plans

    @ViewBuilder private var plans: some View {
        if store.plans.isEmpty {
            switch store.loading {
            case .failed(let reason):
                VStack(spacing: 10) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Try Again") { Task { await store.loadOfferings() } }
                        .buttonStyle(.glass)
                        .foregroundStyle(theme.ink)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            default:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading prices…").font(.callout).foregroundStyle(theme.secondaryInk)
                }
                .frame(maxWidth: .infinity, minHeight: 88)
            }
        } else if sizeClass == .regular {
            // Side by side where there's room, falling back to rows when large text doesn't fit.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(store.plans) { plan in planButton(plan) { PlanCard(plan: plan, isSelected: plan.kind == selected) } }
                }
                planRows
            }
        } else {
            planRows
        }
    }

    private var planRows: some View {
        VStack(spacing: 10) {
            ForEach(store.plans) { plan in planButton(plan) { PlanRow(plan: plan, isSelected: plan.kind == selected) } }
        }
    }

    private func planButton<Label: View>(_ plan: ProPlan, @ViewBuilder label: () -> Label) -> some View {
        Button {
            withAnimation(.snappy) { selected = plan.kind }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(plan.kind == selected ? .isSelected : [])
        .disabled(store.busy != nil)
    }

    /// The selected plan's price as it will be charged, and the button that buys it, kept on screen at the bottom.
    private var purchaseBar: some View {
        VStack(spacing: 8) {
            if let plan = selectedPlan {
                Text(PaywallText.charge(plan))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.secondaryInk)
                    .multilineTextAlignment(.center)
                Button {
                    buy(plan)
                } label: {
                    Group {
                        if store.busy == plan.id {
                            ProgressView().tint(theme.onAccent)
                        } else {
                            Text(PaywallText.action(plan)).font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(PurchaseButtonStyle())
                .disabled(store.busy != nil)
            }
        }
        .frame(maxWidth: 600)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(theme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: theme.borderWidth) }
    }

    private func buy(_ plan: ProPlan) {
        Task {
            let bought = await store.purchase(plan)
            alert = store.takeMessage()
            guard bought, store.isPro else { return }
            client.notice = String(localized: "Coincide is unlocked. Thank you for supporting Coincide!")
            if isSheet { close() }
        }
    }

    // MARK: Pro on

    private var activeCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Coincide Pro is active").font(.headline).foregroundStyle(theme.ink)
                Text(PaywallText.status(store.access)).font(.footnote).foregroundStyle(theme.secondaryInk)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.border, lineWidth: theme.borderWidth))
        .accessibilityElement(children: .combine)
    }

    // MARK: Terms and links

    private var terms: some View {
        Text(
            "Payment is charged to your Apple Account when you confirm the purchase, or when a free trial ends. Subscriptions renew automatically at the same price unless cancelled at least 24 hours before the end of the current period, and renewal is charged within the 24 hours before it ends. Cancel anytime with Manage Subscription or in your Apple Account’s subscription settings. Lifetime is a one-time purchase."
        )
        .font(.caption)
        .foregroundStyle(theme.tertiaryInk)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var links: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                linkButton(String(localized: "Restore Purchases"), busy: store.busy == "restore") {
                    Task {
                        await store.restore()
                        alert = store.takeMessage()
                    }
                }
                .disabled(store.busy != nil || !store.isAvailable)
                separator
                linkButton(String(localized: "Manage Subscription")) { managing = true }
            }
            HStack(spacing: 4) {
                linkButton(String(localized: "Privacy Policy")) { openURL(CoincideLinks.privacyPolicy) }
                separator
                linkButton(String(localized: "Terms of Use")) { openURL(CoincideLinks.termsOfService) }
            }
        }
        .font(.footnote.weight(.medium))
    }

    private var separator: some View {
        Text(verbatim: "·").foregroundStyle(theme.tertiaryInk).accessibilityHidden(true)
    }

    private func linkButton(_ title: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini) }
                Text(title)
            }
            .foregroundStyle(theme.secondaryInk)
            .padding(.horizontal, 6)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A plan as a row, on a phone: the plan and what it costs over time, its price at the end.
private struct PlanRow: View {
    let plan: ProPlan
    let isSelected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? theme.control : theme.tertiaryInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plan.kind.title).font(.headline).foregroundStyle(theme.ink)
                    if let badge = PaywallText.badge(plan) { StatusBadge(text: badge, color: .green) }
                }
                ForEach(PaywallText.details(plan), id: \.self) { line in
                    Text(line).font(.footnote).foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: plan.price).font(.headline.monospacedDigit()).foregroundStyle(theme.ink)
                Text(PaywallText.period(plan.kind)).font(.caption).foregroundStyle(theme.secondaryInk)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .planBackground(isSelected: isSelected, theme: theme)
        .accessibilityElement(children: .combine)
    }
}

/// A plan as a card, side by side with the others where the window is wide.
private struct PlanCard: View {
    let plan: ProPlan
    let isSelected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(plan.kind.title).font(.headline).foregroundStyle(theme.ink)
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? theme.control : theme.tertiaryInk)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: plan.price).font(.title2.bold().monospacedDigit()).foregroundStyle(theme.ink)
                Text(PaywallText.period(plan.kind)).font(.footnote).foregroundStyle(theme.secondaryInk)
            }
            if let badge = PaywallText.badge(plan) { StatusBadge(text: badge, color: .green) }
            ForEach(PaywallText.details(plan), id: \.self) { line in
                Text(line).font(.footnote).foregroundStyle(theme.secondaryInk)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .planBackground(isSelected: isSelected, theme: theme)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A plan's card: the theme's surface, outlined in its control color while picked.
    fileprivate func planBackground(isSelected: Bool, theme: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return background(isSelected ? theme.selection : theme.surface, in: shape)
            .overlay(shape.strokeBorder(isSelected ? theme.control : theme.border, lineWidth: isSelected ? 2 : theme.borderWidth))
            .contentShape(shape)
    }
}

/// The words around a plan's prices. Every price is the App Store's own string for this account's storefront.
enum PaywallText {
    static func period(_ kind: ProPlan.Kind) -> String {
        switch kind {
        case .annual: String(localized: "per year")
        case .monthly: String(localized: "per month")
        case .lifetime: String(localized: "one time")
        }
    }

    static func badge(_ plan: ProPlan) -> String? {
        switch plan.kind {
        case .annual: plan.savings.map { String(localized: "Save \($0)%") } ?? String(localized: "Best Value")
        case .monthly, .lifetime: nil
        }
    }

    /// The lines under a plan's name: Yearly's trial and price per month, what Monthly and Lifetime are.
    static func details(_ plan: ProPlan) -> [String] {
        switch plan.kind {
        case .annual:
            var lines: [String] = []
            if plan.trial != nil { lines.append(trial(plan)) }
            if let perMonth = plan.pricePerMonth { lines.append(String(localized: "Just \(perMonth)/month")) }
            return lines
        case .monthly: return [String(localized: "Cancel anytime")]
        case .lifetime: return [String(localized: "Pay once, keep Pro forever")]
        }
    }

    /// "7-day free trial, then $19.99/year".
    static func trial(_ plan: ProPlan) -> String {
        if let days = plan.trial?.days { return String(localized: "\(days)-day free trial, then \(plan.price)/year") }
        return String(localized: "Free trial, then \(plan.price)/year")
    }

    /// What the button will charge, above it.
    static func charge(_ plan: ProPlan) -> String {
        switch plan.kind {
        case .annual: plan.trial != nil ? trial(plan) : String(localized: "\(plan.price)/year, renews automatically")
        case .monthly: String(localized: "\(plan.price)/month, renews automatically")
        case .lifetime: String(localized: "\(plan.price) once, no subscription")
        }
    }

    static func action(_ plan: ProPlan) -> String {
        switch plan.kind {
        case .annual where plan.trial != nil: String(localized: "Start Free Trial")
        case .annual, .monthly: String(localized: "Subscribe")
        case .lifetime: String(localized: "Buy Lifetime")
        }
    }

    /// What's active, for the Pro pane.
    static func status(_ access: ProAccess?) -> String {
        guard let access else { return String(localized: "Thank you for supporting Coincide!") }
        guard let expiresAt = access.expiresAt else { return String(localized: "Lifetime: yours to keep. Thank you!") }
        let date = expiresAt.formatted(date: .abbreviated, time: .omitted)
        if access.isTrial { return String(localized: "Free trial until \(date)") }
        let plan = access.plan?.title ?? "Coincide Pro"
        return access.willRenew ? String(localized: "\(plan), renews \(date)") : String(localized: "\(plan), ends \(date)")
    }
}


/// The main things Coincide does from a phone, as the paywall lists them.
enum CoincideHighlight: String, CaseIterable, Identifiable {
    case live, prompts, approvals, git, alerts, voice, bots, macs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: String(localized: "Live Threads")
        case .prompts: String(localized: "Prompts and Steering")
        case .approvals: String(localized: "Approvals")
        case .git: String(localized: "Diffs and Git")
        case .alerts: String(localized: "Lock Screen Alerts")
        case .voice: String(localized: "Dictation and Photos")
        case .bots: String(localized: "Bots and Schedules")
        case .macs: String(localized: "All Your Macs")
        }
    }

    var detail: String {
        switch self {
        case .live: String(localized: "Watch every agent work as it happens.")
        case .prompts: String(localized: "Start threads, steer an agent or queue a follow-up.")
        case .approvals: String(localized: "Approve commands and answer an agent’s questions.")
        case .git: String(localized: "Review changes, commit, push and open pull requests.")
        case .alerts: String(localized: "Know when an agent finishes or needs you, even while locked.")
        case .voice: String(localized: "Speak your prompts and attach photos and files.")
        case .bots: String(localized: "Talk to your bots and manage scheduled tasks.")
        case .macs: String(localized: "Pair every Mac and switch between them.")
        }
    }

    private var symbol: String {
        switch self {
        case .live: "bubble.left.and.text.bubble.right.fill"
        case .prompts: "paperplane.fill"
        case .approvals: "checkmark.shield.fill"
        case .git: "arrow.triangle.pull"
        case .alerts: "bell.badge.fill"
        case .voice: "mic.fill"
        case .bots: "coincide.bot.fill"
        case .macs: "laptopcomputer.and.iphone"
        }
    }

    /// The tile's color, by `MacSettingsLabel.color` name.
    private var color: String {
        switch self {
        case .live: "blue"
        case .prompts: "indigo"
        case .approvals: "orange"
        case .git: "purple"
        case .alerts: "red"
        case .voice: "pink"
        case .bots: "teal"
        case .macs: "gray"
        }
    }

    /// A colored tile, as Settings draws its panes'.
    func tile(size: CGFloat) -> some View {
        Group {
            if self == .bots {
                // The bot character's own symbol in the asset catalog.
                Image(symbol)
            } else {
                Image(systemName: symbol)
            }
        }
        .font(.system(size: size * 0.48, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(MacSettingsLabel.color(color).gradient))
        .accessibilityHidden(true)
    }
}

/// The buy button: solid in the theme's accent, with the text color that reads best on it, so it never looks disabled
/// on a dark theme the way a translucent glass button can.
private struct PurchaseButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(theme.onAccent)
            .background(theme.accent, in: .capsule)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(.capsule)
    }
}
