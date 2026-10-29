import CoincideKit
import Foundation
import Testing

@testable import Coincide

/// How each usage figure becomes a row in the menu bar popover and Settings › Usage, showing what is used or what is
/// left. Synthetic figures shaped like each provider's, nothing read live.
struct UsageRowTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func dollars(_ value: Double) -> String { value.formatted(.currency(code: "USD").precision(.fractionLength(2))) }

    // MARK: Windows

    @Test func aWindowReadsAsUsedOrLeftWithABarThatFillsOrDrains() throws {
        // Two hours into a five-hour window, 62% used: ahead of pace.
        let window = UsageLimitWindow(
            id: "five_hour", kind: .session, label: "Session", usedPercent: 61.6, resetsAt: now.addingTimeInterval(3 * 3_600),
            durationMinutes: 300)
        let used = UsageRow.window(window, mode: .used, now: now)
        #expect(used.title == "Session")
        #expect(used.value == "62% used")
        let usedBar = try #require(used.bar)
        #expect(abs(usedBar.fill - 0.616) < 0.0001)
        #expect(abs(try #require(usedBar.paceMark) - 0.4) < 0.0001)
        #expect(used.level == .normal)
        #expect(used.details.first?.hasPrefix("resets in 3h 0m · ") == true)
        #expect(used.details.last == "Ahead of pace")

        let left = UsageRow.window(window, mode: .remaining, now: now)
        #expect(left.value == "38% left")
        let leftBar = try #require(left.bar)
        #expect(abs(leftBar.fill - 0.384) < 0.0001)
        // The mark mirrors, so the fill still falls short of it when spending runs ahead.
        #expect(abs(try #require(leftBar.paceMark) - 0.6) < 0.0001)
        #expect(leftBar.fill < leftBar.paceMark!)
        #expect(left.details == used.details)
    }

    @Test func aWindowWarnsNearItsLimitInBothModes() {
        let near = UsageLimitWindow(id: "w", kind: .weekly, label: "Weekly", usedPercent: 92)
        #expect(UsageRow.window(near, mode: .used, now: now).level == .near)
        #expect(UsageRow.window(near, mode: .remaining, now: now).level == .near)
        #expect(UsageRow.window(near, mode: .remaining, now: now).value == "8% left")
        let full = UsageLimitWindow(id: "w", kind: .weekly, label: "Weekly", usedPercent: 100)
        #expect(UsageRow.window(full, mode: .remaining, now: now).level == .critical)
        #expect(UsageRow.window(full, mode: .remaining, now: now).bar?.fill == 0)
        // Without the window's length there is no pace mark.
        #expect(UsageRow.window(near, mode: .used, now: now).bar?.paceMark == nil)
    }

    @Test func usedAndLeftAlwaysAddUpToAHundred() {
        let window = UsageLimitWindow(id: "w", kind: .weekly, label: "Weekly", usedPercent: 52.5)
        #expect(window.shownPercent(.used) + window.shownPercent(.remaining) == 100)
    }

    // MARK: Claude

    @Test func claudeExtraUsageMeasuresAgainstItsMonthlyCap() throws {
        let extra = UsageFigure(
            id: "extra_usage", label: "Extra usage", unit: .currency("USD"), used: 271.4, limit: 500, resetsAt: now.addingTimeInterval(3_600))
        let used = UsageRow.figure(extra, mode: .used, now: now)
        #expect(used.value == "\(dollars(271.4)) of \(dollars(500)) used")
        #expect(abs(try #require(used.bar).fill - 0.5428) < 0.0001)
        #expect(used.bar?.paceMark == nil)
        #expect(used.details.first?.hasPrefix("resets in 1h 0m") == true)
        let left = UsageRow.figure(extra, mode: .remaining, now: now)
        #expect(left.value == "\(dollars(228.6)) of \(dollars(500)) left")
        #expect(abs(try #require(left.bar).fill - 0.4572) < 0.0001)
    }

    @Test func claudeCloudCreditsPastTheirLimitTurnRedAndSaySo() throws {
        let cloud = UsageFigure(
            id: "iguana_necktie", label: "Cloud credits", unit: .currency("USD"), used: 250.08, limit: 250,
            expiresAt: now.addingTimeInterval(9 * 86_400))
        let used = UsageRow.figure(cloud, mode: .used, now: now)
        #expect(used.value == "\(dollars(250.08)) of \(dollars(250)) used")
        #expect(used.bar?.fill == 1)
        #expect(used.level == .critical)
        #expect(used.details.contains { $0.hasPrefix("expires ") })
        let left = UsageRow.figure(cloud, mode: .remaining, now: now)
        #expect(left.value == "\(dollars(0)) of \(dollars(250)) left")
        #expect(left.bar?.fill == 0)
        #expect(left.level == .critical)
        #expect(left.details.first == "\(dollars(0.08)) over the limit")
    }

    @Test func claudeExtraUsageWithoutACapOrTurnedOffHasNoBar() {
        let uncapped = UsageFigure(id: "extra_usage", label: "Extra usage", unit: .currency("USD"), used: 12, detail: "No cap")
        for mode in UsageDisplayMode.allCases {
            let row = UsageRow.figure(uncapped, mode: mode, now: now)
            #expect(row.bar == nil)
            #expect(row.value == dollars(12))
            #expect(row.details == ["No cap"])
            #expect(!row.isState)
        }
        let off = UsageRow.figure(UsageFigure(id: "extra_usage", label: "Extra usage", unit: .currency("USD"), detail: "Off"), mode: .used, now: now)
        #expect(off.value == "Off" && off.isState && off.bar == nil && off.details.isEmpty)
    }

    @Test func claudeSpendBudgetAndRateLimitsMeasureAgainstTheirLimits() {
        let spend = UsageFigure(id: "spend", label: "Spend", unit: .currency("USD"), used: 45, limit: 50)
        #expect(UsageRow.figure(spend, mode: .used, now: now).level == .near)
        #expect(UsageRow.figure(spend, mode: .remaining, now: now).value == "\(dollars(5)) of \(dollars(50)) left")
        let requests = UsageFigure(id: "ratelimit_requests", label: "Requests per minute", unit: .requests, limit: 50, remaining: 48)
        #expect(UsageRow.figure(requests, mode: .used, now: now).value == "2 of 50 requests used")
        #expect(UsageRow.figure(requests, mode: .remaining, now: now).value == "48 of 50 requests left")
        #expect(abs((UsageRow.figure(requests, mode: .remaining, now: now).bar?.fill ?? 0) - 0.96) < 0.0001)
    }

    // MARK: Codex

    @Test func codexCreditsAreABalanceWithoutABar() {
        let credits = UsageCredits(hasCredits: true, unlimited: false, balance: "39547.01")
        let used = UsageRow.credits(credits, mode: .used)
        #expect(used.title == "Credits")
        #expect(used.value == 39_547.01.formatted(.number.precision(.fractionLength(0...2))))
        #expect(used.bar == nil && !used.isState)
        #expect(UsageRow.credits(credits, mode: .remaining).value == "\(used.value) left")
        #expect(UsageRow.credits(UsageCredits(hasCredits: true, unlimited: true), mode: .remaining).value == "Unlimited credits")
        let none = UsageRow.credits(UsageCredits(hasCredits: false, unlimited: false), mode: .used)
        #expect(none.value == "No credits" && none.isState)
    }

    @Test func codexCreditLimitAndResetsAvailable() throws {
        let limit = UsageFigure(id: "individual", label: "Credit limit", unit: .credits, used: 400, limit: 1_000)
        #expect(UsageRow.figure(limit, mode: .used, now: now).value == "400 of 1,000 credits used")
        #expect(UsageRow.figure(limit, mode: .remaining, now: now).value == "600 of 1,000 credits left")
        #expect(abs(try #require(UsageRow.figure(limit, mode: .remaining, now: now).bar).fill - 0.6) < 0.0001)
        let resets = UsageFigure(
            id: "reset_credits", label: "Limit resets available", unit: .count, remaining: 2, expiresAt: now.addingTimeInterval(86_400))
        for mode in UsageDisplayMode.allCases {
            let row = UsageRow.figure(resets, mode: mode, now: now)
            #expect(row.value == "2" && row.bar == nil)
            #expect(row.details.first?.hasPrefix("expires ") == true)
        }
    }

    @Test func anAccountsRowsGoWindowsCreditsThenFigures() {
        let limits = UsageLimits(
            windows: [UsageLimitWindow(id: "primary", kind: .session, label: "Session", usedPercent: 10)], checkedAt: now,
            credits: UsageCredits(hasCredits: true, unlimited: false, balance: "5"),
            modelWindows: [UsageLimitWindow(id: "spark", kind: .weekly, label: "Spark", usedPercent: 20)],
            figures: [UsageFigure(id: "individual", label: "Credit limit", unit: .credits, used: 1, limit: 10)])
        #expect(UsageRow.rows(limits, mode: .used, now: now).map(\.title) == ["Session", "Spark", "Credits", "Credit limit"])
    }

    // MARK: OpenRouter

    @Test func openRouterKeyLimitAndSpend() throws {
        let key = UsageFigure(
            id: "key_limit", label: "Key credit limit", unit: .currency("USD"), limit: 20, remaining: 12.4,
            resetsAt: now.addingTimeInterval(7_200))
        let used = UsageRow.figure(key, mode: .used, now: now)
        #expect(used.value == "\(dollars(7.6)) of \(dollars(20)) used")
        #expect(abs(try #require(used.bar).fill - 0.38) < 0.0001)
        #expect(UsageRow.figure(key, mode: .remaining, now: now).value == "\(dollars(12.4)) of \(dollars(20)) left")
        let noLimit = UsageRow.figure(
            UsageFigure(id: "key_limit", label: "Key credit limit", unit: .currency("USD"), detail: "No limit"), mode: .remaining, now: now)
        #expect(noLimit.value == "No limit" && noLimit.isState && noLimit.bar == nil)
        let today = UsageRow.figure(
            UsageFigure(id: "usage_daily", label: "Spent today", unit: .currency("USD"), used: 1.5, resetsAt: now.addingTimeInterval(3_600)),
            mode: .remaining, now: now)
        #expect(today.value == dollars(1.5) && today.bar == nil)
        let account = UsageRow.figure(
            UsageFigure(id: "credits", label: "Account credits", unit: .currency("USD"), used: 30, limit: 40), mode: .remaining, now: now)
        #expect(account.value == "\(dollars(10)) of \(dollars(40)) left")
    }

    // MARK: Cursor

    @Test func cursorIncludedAndOnDemandUsage() {
        let included = UsageFigure(id: "included", label: "Included usage", unit: .currency("USD"), used: 19, limit: 20, remaining: 1)
        let row = UsageRow.figure(included, mode: .remaining, now: now)
        #expect(row.value == "\(dollars(1)) of \(dollars(20)) left")
        #expect(row.level == .critical)
        let onDemand = UsageFigure(id: "on_demand", label: "On-demand usage", unit: .currency("USD"), used: 3.25)
        #expect(UsageRow.figure(onDemand, mode: .used, now: now).bar == nil)
        let capped = UsageFigure(id: "on_demand", label: "On-demand usage", unit: .currency("USD"), used: 3.25, limit: 100, remaining: 96.75)
        #expect(UsageRow.figure(capped, mode: .used, now: now).value == "\(dollars(3.25)) of \(dollars(100)) used")
    }

    // MARK: Closest limit and the menu bar

    @Test func theClosestLimitNamesItsAccount() {
        let window = UsageLimitWindow(id: "seven_day", kind: .weekly, label: "Weekly", usedPercent: 92)
        let account = UsageInsights.AccountLimits(
            provider: .claude, account: .defaultAccount(for: .claude), showsAccountName: false, status: ProviderStatus(state: .ready),
            limits: UsageLimits(windows: [window], checkedAt: now))
        let row = UsageRow.closest(account, window, mode: .remaining, now: now)
        #expect(row.title == "Claude Code · Weekly")
        #expect(row.value == "8% left")
        #expect(row.level == .near)
    }

    @MainActor
    @Test func theMenuBarTitleAndSummaryFollowTheMode() {
        let window = UsageLimitWindow(id: "w", kind: .weekly, label: "Weekly", usedPercent: 52, resetsAt: now.addingTimeInterval(3_600))
        let account = UsageInsights.AccountLimits(
            provider: .codex, account: .defaultAccount(for: .codex), showsAccountName: false, status: ProviderStatus(state: .ready),
            limits: UsageLimits(windows: [window], checkedAt: now))
        var settings = AppSettings()
        settings.menuBarUsage = .account(provider: .codex, accountID: ProviderAccount.defaultID, metric: .mostUsed)
        #expect(UsageStatusItem.readings(settings: settings, accounts: [account], lastActive: nil).first?.text == "52%")
        settings.usageDisplayMode = .remaining
        let readings = UsageStatusItem.readings(settings: settings, accounts: [account], lastActive: nil)
        #expect(readings.first?.text == "48% left")
        #expect(UsageStatusItem.summary(readings, mode: .remaining, now: now) == "Coincide usage: Codex weekly limit 48% left, resets in 1h 0m")
        #expect(UsageStatusItem.summary(readings, mode: .used, now: now) == "Coincide usage: Codex weekly limit 52% used, resets in 1h 0m")
        // The text is wider showing what is left, and the image grows with it.
        let usedImage = UsageStatusItem.image(for: [MenuBarUsageReading(provider: .codex, account: account, window: window, text: "52%")])
        #expect(UsageStatusItem.image(for: readings, mode: .remaining).size.width > usedImage.size.width)
    }

    @Test func theModesHaveNames() {
        #expect(UsageFormat.displayModeName(.used) == "Used")
        #expect(UsageFormat.displayModeName(.remaining) == "Remaining")
    }
}
