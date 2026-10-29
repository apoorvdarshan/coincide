import AppKit
import CoincideKit
import SwiftUI

/// How usage figures read wherever Coincide shows them: Settings › Usage, the menu bar item and the composer's meter.
enum UsageFormat {
    /// "1.2M", "845K", "312".
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    /// "1,234,567 tokens", for tooltips.
    static func exactTokens(_ count: Int) -> String {
        String(localized: "\(count.formatted()) tokens")
    }

    /// The cost to the cent's hundredth, for tooltips, or why there is none.
    static func exactCost(_ totals: UsageTotals) -> String {
        guard totals.hasPricedTokens else { return String(localized: "No list price for these models") }
        let cost = totals.cost.formatted(.currency(code: "USD").precision(.fractionLength(4)))
        return totals.isFullyPriced
            ? String(localized: "≈ \(cost) at API list prices")
            : String(localized: "≈ \(cost) at API list prices, without \(UsageFormat.tokens(totals.unpricedTokens)) unpriced tokens")
    }

    /// "12%".
    static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(share < 0.1 && share > 0 ? 1 : 0)))
    }

    /// "$12.34", "<$0.01" for a cost that rounds to nothing.
    static func cost(_ dollars: Double) -> String {
        if dollars > 0 && dollars < 0.01 { return String(localized: "<\(0.01.formatted(.currency(code: "USD")))") }
        return dollars.formatted(.currency(code: "USD").precision(.fractionLength(dollars >= 1000 ? 0 : 2)))
    }

    /// The cost of `totals`, or "—" when none of its tokens has a known price.
    static func cost(of totals: UsageTotals) -> String {
        totals.hasPricedTokens ? cost(totals.cost) : "—"
    }

    /// "62% used".
    static func used(_ window: UsageLimitWindow) -> String {
        String(localized: "\(Int(window.usedPercent.rounded()))% used")
    }

    /// When the window resets, both ways: "resets in 2h 14m · Mon 9:00". Nil without a reset time.
    static func reset(_ window: UsageLimitWindow, now: Date) -> String? {
        guard let resetsAt = window.resetsAt, let countdown = window.resetDescription(at: now) else { return nil }
        return countdown + " · " + resetTime(resetsAt, now: now)
    }

    /// "9:00", "Mon 9:00" within the week, "Nov 3, 9:00" after.
    static func resetTime(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if date.timeIntervalSince(now) < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func pace(_ window: UsageLimitWindow, now: Date) -> String? {
        switch window.pace(at: now) {
        case .ahead?: String(localized: "Ahead of pace")
        case .onPace?: String(localized: "On pace")
        case .under?: String(localized: "Under pace")
        case nil: nil
        }
    }

    /// A plan's name as the provider wrote it, made readable: "pro" → "Pro", "edu_plus" → "Edu Plus".
    static func plan(_ plan: String) -> String {
        plan.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The credits line: "Credits: 1,250", "Unlimited credits", "No credits".
    static func credits(_ credits: UsageCredits) -> String {
        if !credits.unlimited, let balance = balance(credits) { return String(localized: "Credits: \(balance)") }
        return creditsValue(credits)
    }

    /// The credits for a row already labeled Credits: "1,250", "Unlimited credits", "No credits".
    static func creditsValue(_ credits: UsageCredits) -> String {
        if credits.unlimited { return String(localized: "Unlimited credits") }
        if let balance = balance(credits) { return balance }
        return credits.hasCredits ? String(localized: "Credits available") : String(localized: "No credits")
    }

    private static func balance(_ credits: UsageCredits) -> String? {
        credits.balance.map { balance in Double(balance).map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? balance }
    }

    /// The color of a window's bar: the provider's, turning orange near the limit and red at it.
    static func color(_ window: UsageLimitWindow, provider: ProviderKind) -> NSColor {
        ComposerUsageDetails.color(for: window, provider: provider)
    }

    /// The account's name for headers: "Claude Code", or "Claude Code · Work" when the provider has several.
    static func title(_ account: UsageInsights.AccountLimits) -> String {
        account.showsAccountName && !account.account.isDefault
            ? "\(account.provider.displayName) · \(account.account.name)" : account.provider.displayName
    }

    /// Why an account shows no limits: it is not set up, its check failed, or the provider reports none for it.
    static func unavailable(_ account: UsageInsights.AccountLimits, settings: AppSettings) -> String {
        switch account.status.state {
        case .notInstalled:
            return String(localized: "Not installed.")
        case .notAuthenticated:
            return String(localized: "Not signed in.")
        case .unknown:
            return String(localized: "Not checked yet.")
        case .error:
            return account.status.message ?? String(localized: "The last check failed.")
        case .ready:
            break
        }
        switch account.provider {
        case .cursor where account.account.isDefault && !settings.cursorKeychainUsageEnabled:
            return String(localized: "Turn on “Show account usage” in Settings › Cursor to read the plan’s limits.")
        case .claude, .codex:
            return String(localized: "No plan limits reported. Accounts that use an API key have none.")
        default:
            return String(localized: "Not available: \(account.provider.displayName) reports no plan limits for this account.")
        }
    }
}

/// A window's bar in SwiftUI, drawn like the composer's meter: a thin rounded track filled with what is used in the
/// provider's color, with a mark where even spending across the window would be.
struct UsageWindowBar: View {
    let window: UsageLimitWindow
    let provider: ProviderKind
    var now = Date()
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                Capsule()
                    .fill(Color(nsColor: UsageFormat.color(window, provider: provider)))
                    .frame(width: window.usedPercent > 0 ? max(height, width * window.usedPercent / 100) : 0)
                if let elapsed = window.elapsedShare(at: now) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(nsColor: Theme.ink))
                        .frame(width: 2, height: height + 4)
                        .offset(x: min(max(0, width * elapsed - 1), width - 2))
                }
            }
            .frame(height: height + 4)
        }
        .frame(height: height + 4)
        .accessibilityHidden(true)
    }
}

/// One limit window: its name and how much is used over the bar, then when it resets and the pace.
struct UsageWindowRow: View {
    let window: UsageLimitWindow
    let provider: ProviderKind
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                Spacer(minLength: 8)
                Text(UsageFormat.used(window))
                    .monospacedDigit()
                    .foregroundStyle(window.isNearLimit ? Color(nsColor: UsageFormat.color(window, provider: provider)) : .primary)
            }
            UsageWindowBar(window: window, provider: provider, now: now)
            let details = [UsageFormat.reset(window, now: now), UsageFormat.pace(window, now: now)].compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ([window.label, UsageFormat.used(window)] + [UsageFormat.reset(window, now: now), UsageFormat.pace(window, now: now)]
                .compactMap { $0 }).joined(separator: ", "))
        .help(window.elapsedShare(at: now) != nil ? String(localized: "The mark shows where even spending across the window would be.") : "")
    }
}

/// Where Settings › Usage opens: the provider a click (in the menu bar, say) asked for.
@MainActor
enum UsageNavigation {
    static var requestedProvider: ProviderKind?

    /// Opens Settings › Usage, showing `provider` when given.
    static func show(provider: ProviderKind? = nil) {
        requestedProvider = provider
        NotificationCenter.default.post(name: requestNotification, object: nil)
        AppEvents.showSettings(section: .usage)
    }

    static let requestNotification = Notification.Name("Coincide.showUsageProvider")
}
