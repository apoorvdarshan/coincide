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

    /// The credits balance as a number, "1,250.5", when the provider reported one.
    static func creditsBalance(_ credits: UsageCredits) -> String? { balance(credits) }

    private static func balance(_ credits: UsageCredits) -> String? {
        credits.balance.map { balance in Double(balance).map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? balance }
    }

    /// An amount of a figure in its unit: "$12.40", "1,250 credits", "48 requests", "12K tokens".
    static func amount(_ value: Double, _ unit: UsageFigure.Unit) -> String {
        switch unit {
        case .currency(let code):
            return value.formatted(.currency(code: code).precision(.fractionLength(value != 0 && abs(value) < 0.01 ? 4 : 2)))
        case .credits:
            return String(localized: "\(value.formatted(.number.precision(.fractionLength(0...2)))) credits")
        case .requests:
            return String(localized: "\(value.formatted(.number.precision(.fractionLength(0)))) requests")
        case .tokens:
            return String(localized: "\(UsageFormat.tokens(Int(value.rounded()))) tokens")
        case .count:
            return value.formatted(.number.precision(.fractionLength(0)))
        }
    }

    /// An amount without its unit's word, to go before "of 50 requests": "$12.40", "48", "29K".
    static func bareAmount(_ value: Double, _ unit: UsageFigure.Unit) -> String {
        switch unit {
        case .currency: amount(value, unit)
        case .tokens: UsageFormat.tokens(Int(value.rounded()))
        case .credits: value.formatted(.number.precision(.fractionLength(0...2)))
        case .requests, .count: value.formatted(.number.precision(.fractionLength(0)))
        }
    }

    /// What a figure says: "$271.40 of $500.00 used", "48 of 50 requests left", "$3.20", or its state ("Off").
    static func figureValue(_ figure: UsageFigure) -> String {
        if let limit = figure.limit {
            if let used = figure.used {
                return String(localized: "\(bareAmount(used, figure.unit)) of \(amount(limit, figure.unit)) used")
            }
            if let left = figure.left {
                return String(localized: "\(bareAmount(left, figure.unit)) of \(amount(limit, figure.unit)) left")
            }
            return String(localized: "Limit \(amount(limit, figure.unit))")
        }
        if let used = figure.used { return amount(used, figure.unit) }
        if let remaining = figure.remaining {
            return figure.unit == .count ? amount(remaining, figure.unit) : String(localized: "\(amount(remaining, figure.unit)) left")
        }
        return figure.detail ?? "—"
    }

    /// When a figure starts over or runs out: "resets in 2h 14m · Mon 9:00", "expires Nov 3, 9:00". Nil without either.
    static func figureTiming(_ figure: UsageFigure, now: Date) -> String? {
        if let resetsAt = figure.resetsAt, resetsAt > now {
            return String(localized: "resets in \(UsageLimitWindow.duration(resetsAt.timeIntervalSince(now)))") + " · "
                + resetTime(resetsAt, now: now)
        }
        if let expiresAt = figure.expiresAt {
            return String(localized: "expires \(resetTime(expiresAt, now: now))")
        }
        return nil
    }

    /// The figure's extra word when it has amounts too, such as "No cap".
    static func figureDetail(_ figure: UsageFigure) -> String? {
        figure.limit != nil || figure.used != nil || figure.remaining != nil ? figure.detail : nil
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
        if account.account.auth == .apiKey {
            return String(localized: "This API key reports no usage figures. Coincide counts the tokens of turns it runs.")
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

/// One usage row as the menu bar popover and Settings › Usage draw it, for a limit window, a figure or credits: the
/// title with the value on the right, a bar when there is a real total to measure against, and when it resets or
/// expires underneath. Read as `UsageDisplayMode` says: what is used (bars fill up) or what is left (bars drain). The
/// color warns as the limit nears either way. Nothing is estimated: a figure without a total gets no bar.
struct UsageRow: Equatable {
    /// How close the row is to its limit, which colors its bar and value like the composer's meter.
    enum Level: Equatable {
        case normal
        /// At or past the warning level (`UsageLimitWindow.warningPercent`).
        case near
        /// At 95% used, or the limit reached or passed.
        case critical

        /// The level for a share used, 0–1, or past 1 when over the limit.
        init(usedShare: Double) {
            if usedShare >= 0.95 {
                self = .critical
            } else if usedShare * 100 >= UsageLimitWindow.warningPercent {
                self = .near
            } else {
                self = .normal
            }
        }
    }

    struct Bar: Equatable {
        /// How much of the track is filled, 0–1: what is used, or what is left.
        var fill: Double
        /// Where even spending across the period would put the fill, 0–1; nil when the period's length is unknown.
        var paceMark: Double?
    }

    var title: String
    var value: String
    /// The value is a state, such as "Off" or "No limit", rather than an amount.
    var isState = false
    var bar: Bar?
    var level = Level.normal
    /// When it resets or expires, the pace, and any word on its state.
    var details: [String] = []

    var accessibilityLabel: String { ([title, value] + details).joined(separator: ", ") }

    /// A limit window: "62% used" or "38% left", its bar with the pace mark, when it resets and the pace.
    static func window(_ window: UsageLimitWindow, mode: UsageDisplayMode, now: Date) -> UsageRow {
        UsageRow(
            title: window.label, value: UsageFormat.shown(window, mode: mode),
            bar: Bar(fill: window.barFill(mode), paceMark: window.paceMark(at: now, mode: mode)),
            level: window.isExhausted ? .critical : Level(usedShare: window.usedPercent / 100),
            details: [UsageFormat.reset(window, now: now), UsageFormat.pace(window, now: now)].compactMap { $0 })
    }

    /// A figure: with a limit, what is used or left of it over a bar; without one, the amount alone (a balance, a spend
    /// so far) or its state. A figure past its limit fills the bar (or empties it) and turns red.
    static func figure(_ figure: UsageFigure, mode: UsageDisplayMode, now: Date) -> UsageRow {
        var row = UsageRow(title: figure.label, value: UsageFormat.figureValue(figure))
        if let limit = figure.limit, limit > 0, let used = figure.used ?? figure.remaining.map({ limit - $0 }) {
            let share = max(0, used) / limit
            let left = figure.left ?? max(0, limit - used)
            row.value =
                mode == .used
                ? String(localized: "\(UsageFormat.bareAmount(used, figure.unit)) of \(UsageFormat.amount(limit, figure.unit)) used")
                : String(localized: "\(UsageFormat.bareAmount(left, figure.unit)) of \(UsageFormat.amount(limit, figure.unit)) left")
            row.bar = Bar(fill: mode == .used ? min(1, share) : max(0, 1 - share))
            row.level = Level(usedShare: share)
            if mode == .remaining, used > limit {
                row.details.append(String(localized: "\(UsageFormat.amount(used - limit, figure.unit)) over the limit"))
            }
        } else {
            row.isState = figure.limit == nil && figure.used == nil && figure.remaining == nil
        }
        row.details += [UsageFormat.figureDetail(figure), UsageFormat.figureTiming(figure, now: now)].compactMap { $0 }
        return row
    }

    /// Credits the account can spend past its plan, such as Codex's: a balance with no total, so no bar. A balance is
    /// what is left either way; showing what is left says so.
    static func credits(_ credits: UsageCredits, mode: UsageDisplayMode) -> UsageRow {
        var row = UsageRow(title: String(localized: "Credits"), value: UsageFormat.creditsValue(credits))
        if !credits.unlimited, let balance = UsageFormat.creditsBalance(credits) {
            row.value = mode == .used ? balance : String(localized: "\(balance) left")
        } else {
            row.isState = !credits.unlimited
        }
        return row
    }

    /// The closest limit across all accounts, named with its account: "Claude Code · Weekly".
    static func closest(
        _ account: UsageInsights.AccountLimits, _ limit: UsageLimitWindow, mode: UsageDisplayMode, now: Date
    ) -> UsageRow {
        var row = window(limit, mode: mode, now: now)
        row.title = "\(UsageFormat.title(account)) · \(limit.label)"
        return row
    }

    /// Every row of an account, in order: its windows, model windows, credits, then figures.
    static func rows(_ limits: UsageLimits, mode: UsageDisplayMode, now: Date) -> [UsageRow] {
        (limits.windows + limits.modelWindows).map { window($0, mode: mode, now: now) }
            + [limits.credits].compactMap { $0 }.map { credits($0, mode: mode) }
            + limits.figures.map { figure($0, mode: mode, now: now) }
    }
}

extension UsageFormat {
    /// "Used" or "Remaining", for the setting and the popover's switch.
    static func displayModeName(_ mode: UsageDisplayMode) -> String {
        switch mode {
        case .used: String(localized: "Used", comment: "Usage shows what is used of each limit")
        case .remaining: String(localized: "Remaining", comment: "Usage shows what is left of each limit")
        }
    }

    /// "62% used", or "38% left" when showing what is left.
    static func shown(_ window: UsageLimitWindow, mode: UsageDisplayMode) -> String {
        mode == .used ? used(window) : String(localized: "\(window.shownPercent(.remaining))% left")
    }

    /// The color of a row's bar, and of its value once near the limit: the provider's, orange near the limit, red at it.
    static func color(_ level: UsageRow.Level, provider: ProviderKind) -> NSColor {
        switch level {
        case .normal: Theme.color(for: provider)
        case .near: Theme.warning
        case .critical: Theme.failure
        }
    }
}

/// A usage bar, drawn like the composer's meter: a thin rounded track filled in the row's color, with a mark where even
/// spending across the period would put the fill.
struct UsageBar: View {
    let fill: Double
    var paceMark: Double?
    let color: NSColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fill = min(1, max(0, fill))
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                Capsule()
                    .fill(Color(nsColor: color))
                    .frame(width: fill > 0 ? max(height, width * fill) : 0)
                if let paceMark {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(nsColor: Theme.ink))
                        .frame(width: 2, height: height + 4)
                        .offset(x: min(max(0, width * paceMark - 1), width - 2))
                }
            }
            .frame(height: height + 4)
        }
        .frame(height: height + 4)
        .accessibilityHidden(true)
    }
}

/// One `UsageRow`. The title and value share a line when they fit; otherwise the value goes under the title (long
/// amounts, long languages), so nothing is cut off.
struct UsageRowView: View {
    let row: UsageRow
    let provider: ProviderKind
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title.lineLimit(1)
                    Spacer(minLength: 0)
                    value.lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    title.fixedSize(horizontal: false, vertical: true)
                    value.fixedSize(horizontal: false, vertical: true)
                }
            }
            if let bar = row.bar {
                UsageBar(
                    fill: bar.fill, paceMark: bar.paceMark, color: UsageFormat.color(row.level, provider: provider), height: compact ? 4 : 6)
            }
            if !row.details.isEmpty {
                Text(row.details.joined(separator: " · "))
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, compact ? 0 : 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .help(row.bar?.paceMark != nil ? String(localized: "The mark shows where even spending across the window would be.") : "")
    }

    private var title: some View {
        Text(row.title).font(compact ? .caption : .body)
    }

    private var value: some View {
        Text(row.value)
            .font(compact ? .caption.monospacedDigit() : .body.monospacedDigit())
            .foregroundStyle(
                row.isState
                    ? Color.secondary
                    : row.level == .normal ? Color(nsColor: Theme.ink) : Color(nsColor: UsageFormat.color(row.level, provider: provider)))
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
