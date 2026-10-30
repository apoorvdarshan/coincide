import Foundation

/// What the menu bar item shows, as the user picked it in its popover or in Settings › Usage.
public enum MenuBarUsageChoice: Codable, Hashable, Sendable {
    /// The agent account the user ran last (`LastActiveAgent`), with its active credit balance or most used limit. The default.
    case lastActive
    /// The limit closest to running out across every account, with a gauge rather than a logo.
    case closest
    /// One account's figure, whatever ran last.
    case account(provider: ProviderKind, accountID: String, metric: MenuBarUsageMetric)
}

/// Which of an account's figures a fixed menu bar choice shows.
public enum MenuBarUsageMetric: Codable, Hashable, Sendable {
    /// The account's most used window (`MenuBarUsage.mostUsedWindow`).
    case mostUsed
    /// One window, by `UsageLimitWindow.id`: a session, weekly, monthly or model's own limit.
    case window(String)
    /// The account's credits balance, or the money left of its first figure with a limit.
    case balance
}

/// What the menu bar item reads now: an account's window or balance, as compact text.
public struct MenuBarUsageReading: Sendable, Hashable {
    /// Nil for the closest limit across all, which shows a gauge instead of a logo.
    public var provider: ProviderKind?
    public var account: UsageInsights.AccountLimits?
    public var window: UsageLimitWindow?
    /// The balance figure shown, for `.balance`.
    public var figure: UsageFigure?
    public var credits: UsageCredits?
    /// "52%" ("48% left" when showing what is left), "$12.40" or "1,250"; nil when the chosen figure is not reported
    /// now.
    public var text: String?

    public nonisolated init(
        provider: ProviderKind?, account: UsageInsights.AccountLimits? = nil, window: UsageLimitWindow? = nil,
        figure: UsageFigure? = nil, credits: UsageCredits? = nil, text: String? = nil
    ) {
        self.provider = provider
        self.account = account
        self.window = window
        self.figure = figure
        self.credits = credits
        self.text = text
    }
}

public enum MenuBarUsage {
    /// What `choice` shows given the accounts and the last agent used, with windows read as `mode` says. A last active
    /// agent whose provider is off (or that never ran) shows the closest limit across all, as does a fixed account that
    /// no longer exists. A balance reads the same either way: it is what is left.
    public nonisolated static func reading(
        for choice: MenuBarUsageChoice, accounts: [UsageInsights.AccountLimits], lastActive: LastActiveAgent?,
        mode: UsageDisplayMode = .used, now: Date = Date()
    ) -> MenuBarUsageReading? {
        let accounts = accounts.map { account in
            var current = account
            current.limits = account.limits?.current(at: now)
            return current
        }
        func text(_ window: UsageLimitWindow) -> String { percentText(window, mode: mode) }
        switch choice {
        case .closest:
            return closest(accounts, mode: mode)
        case .lastActive:
            guard let lastActive, let account = account(lastActive.provider, lastActive.accountID, in: accounts) else {
                return closest(accounts, mode: mode)
            }
            if let reading = activeCreditReading(account) { return reading }
            if let window = mostUsedWindow(account) {
                return MenuBarUsageReading(provider: account.provider, account: account, window: window, text: text(window))
            }
            // An account with no windows (an API key, say) shows its balance when it has one.
            var reading = balanceReading(account)
            reading.provider = account.provider
            return reading
        case .account(let provider, let accountID, let metric):
            guard let account = accounts.first(where: { $0.provider == provider && $0.account.id == accountID }) else {
                return closest(accounts, mode: mode)
            }
            switch metric {
            case .mostUsed:
                let window = mostUsedWindow(account)
                return MenuBarUsageReading(provider: provider, account: account, window: window, text: window.map(text))
            case .window(let id):
                let window = allWindows(account).first { $0.id == id }
                return MenuBarUsageReading(provider: provider, account: account, window: window, text: window.map(text))
            case .balance:
                return balanceReading(account)
            }
        }
    }

    /// The account `id` of `provider`, or its default account when that one is gone.
    nonisolated static func account(
        _ provider: ProviderKind, _ id: String, in accounts: [UsageInsights.AccountLimits]
    ) -> UsageInsights.AccountLimits? {
        accounts.first { $0.provider == provider && $0.account.id == id }
            ?? accounts.first { $0.provider == provider && $0.account.isDefault }
    }

    private nonisolated static func closest(_ accounts: [UsageInsights.AccountLimits], mode: UsageDisplayMode) -> MenuBarUsageReading? {
        guard let constrained = UsageInsights.mostConstrained(accounts) else { return nil }
        return MenuBarUsageReading(
            provider: nil, account: constrained.account, window: constrained.window,
            text: percentText(constrained.window, mode: mode))
    }

    /// The account's windows, main ones first.
    public nonisolated static func allWindows(_ account: UsageInsights.AccountLimits) -> [UsageLimitWindow] {
        (account.limits?.windows ?? []) + (account.limits?.modelWindows ?? [])
    }

    /// The account's most used window, the one closest to stopping it; ties go to the one that resets last.
    public nonisolated static func mostUsedWindow(_ account: UsageInsights.AccountLimits) -> UsageLimitWindow? {
        UsageInsights.mostConstrained([account])?.window
    }

    /// The first monetary or credit figure with a reported or derivable balance. Request/token quotas are not money.
    public nonisolated static func balanceFigure(_ account: UsageInsights.AccountLimits) -> UsageFigure? {
        account.limits?.figures.first { figure in
            guard figure.left != nil else { return false }
            switch figure.unit {
            case .currency, .credits: return true
            default: return false
            }
        }
    }

    /// Credit availability alone does not mean credits are being spent. Follow the provider's exhausted-plan
    /// fallback state, and keep a blocking plan limit visible when work cannot continue past it.
    private nonisolated static func activeCreditReading(_ account: UsageInsights.AccountLimits) -> MenuBarUsageReading? {
        guard let windows = account.limits?.windows, !allWindows(account).contains(where: \.blocksWork),
            windows.contains(where: { $0.isExhausted && $0.continuesOnCredits }) else { return nil }
        func monetary(_ figure: UsageFigure) -> Bool {
            switch figure.unit {
            case .currency, .credits: return true
            default: return false
            }
        }
        // A reported detail names the active mode without pretending there is a balance. Keep its text as
        // reported: a provider session may have supplied it in another app language.
        if account.limits?.credits.map({ $0.unlimited || numericBalance($0) != nil }) != true,
            let figure = account.limits?.figures.first(where: monetary), figure.left == nil,
            let detail = figure.detail?.trimmedNonEmpty, figure.used != nil {
            return MenuBarUsageReading(provider: account.provider, account: account, figure: figure,
                text: "\(figure.label) · \(detail)")
        }
        var reading = balanceReading(account)
        if let value = reading.text {
            if let credits = reading.credits {
                reading.text = credits.unlimited ? String(localized: "Unlimited credits") : String(localized: "Credits: \(value)")
            } else if let figure = reading.figure {
                reading.text = "\(figure.label): \(value)"
            }
        } else if let figure = account.limits?.figures.first(where: monetary) {
            // The mode is known even when the provider does not report a numeric amount.
            reading.text = figure.label
            if figure.used != nil || figure.limit != nil || figure.remaining != nil { reading.figure = figure }
        } else {
            reading.text = String(localized: "Credits")
        }
        return reading
    }

    /// Whether the account has a balance to show.
    public nonisolated static func hasBalance(_ account: UsageInsights.AccountLimits) -> Bool {
        account.limits?.credits.map { $0.unlimited || numericBalance($0) != nil } == true || balanceFigure(account) != nil
    }

    private nonisolated static func balanceReading(_ account: UsageInsights.AccountLimits) -> MenuBarUsageReading {
        var reading = MenuBarUsageReading(provider: account.provider, account: account)
        if let credits = account.limits?.credits, credits.unlimited || numericBalance(credits) != nil {
            reading.credits = credits
            reading.text = credits.unlimited ? "∞" : numericBalance(credits).map { $0.formatted(.number.precision(.fractionLength(0...2))) }
        } else if let figure = balanceFigure(account), let left = figure.left {
            reading.figure = figure
            switch figure.unit {
            case .currency(let code): reading.text = left.formatted(.currency(code: code).precision(.fractionLength(2)))
            case .credits: reading.text = left.formatted(.number.precision(.fractionLength(0...2)))
            default: break
            }
        }
        return reading
    }

    private nonisolated static func numericBalance(_ credits: UsageCredits) -> Double? {
        credits.balance.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0.isFinite ? $0 : nil }
    }

    /// "52%", the share of the window used, or "48% left" when showing what is left. The menu bar has room for little,
    /// so a bare percentage means used and only the other way says so.
    public nonisolated static func percentText(_ window: UsageLimitWindow, mode: UsageDisplayMode = .used) -> String {
        let percent = (Double(window.shownPercent(mode)) / 100).formatted(.percent.precision(.fractionLength(0)))
        return mode == .used ? percent : String(localized: "\(percent) left")
    }
}
