import CoincideKit
import Foundation
import Testing

@testable import Coincide

/// How Settings › Usage and the menu bar item word usage figures.
struct UsageFormatTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func windowsReadAsUsedWithBothResetForms() {
        let window = UsageLimitWindow(
            id: "s", kind: .session, label: "Session", usedPercent: 61.6, resetsAt: now.addingTimeInterval(2 * 3_600 + 14 * 60 + 30),
            durationMinutes: 300)
        #expect(UsageFormat.used(window) == "62% used")
        let time = now.addingTimeInterval(2 * 3_600 + 14 * 60 + 30).formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(now, inSameDayAs: now.addingTimeInterval(8_070)) {
            #expect(UsageFormat.reset(window, now: now) == "resets in 2h 14m · \(time)")
        }
        #expect(UsageFormat.reset(UsageLimitWindow(id: "w", kind: .weekly, label: "Weekly", usedPercent: 0), now: now) == nil)
        // A week away names the date, not the weekday.
        let far = now.addingTimeInterval(9 * 86_400)
        #expect(UsageFormat.resetTime(far, now: now) == far.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
    }

    @Test func plansAndCreditsReadNaturally() {
        #expect(UsageFormat.plan("pro") == "Pro")
        #expect(UsageFormat.plan("edu_plus") == "Edu Plus")
        #expect(UsageFormat.credits(UsageCredits(hasCredits: true, unlimited: true)) == "Unlimited credits")
        #expect(UsageFormat.credits(UsageCredits(hasCredits: false, unlimited: false)) == "No credits")
        #expect(UsageFormat.credits(UsageCredits(hasCredits: true, unlimited: false, balance: "12.5")).hasPrefix("Credits: "))
        #expect(UsageFormat.cost(0.004) == "<$0.01")
        #expect(UsageFormat.cost(12.346) == "$12.35")
    }

    @MainActor
    @Test func theMenuBarSummaryNamesWhatItShows() {
        let window = UsageLimitWindow(id: "w", kind: .weekly, label: "Weekly", usedPercent: 71.4, resetsAt: now.addingTimeInterval(3_600))
        let account = UsageInsights.AccountLimits(
            provider: .codex, account: .defaultAccount(for: .codex), showsAccountName: false, status: ProviderStatus(state: .ready),
            limits: UsageLimits(windows: [window], checkedAt: now))
        let reading = MenuBarUsageReading(provider: .codex, account: account, window: window, text: "71%")
        #expect(UsageStatusItem.summary([reading], now: now) == "Coincide usage: Codex weekly limit 71% used, resets in 1h 0m")
        #expect(UsageStatusItem.summary([], now: now) == "Coincide usage: no plan limits reported")
        #expect(UsageStatusItem.gauge(percent: 97) != nil)
        // Logos and text make one template image, so the menu bar tints it.
        let image = UsageStatusItem.image(for: [reading, MenuBarUsageReading(provider: nil, account: account, window: window, text: "71%")])
        #expect(image.isTemplate)
        #expect(image.size.width > UsageStatusItem.image(for: [reading]).size.width)
    }

    @MainActor
    @Test func theMenuBarShowsTheSecondChoiceOnlyWhenItDiffers() {
        let window = UsageLimitWindow(id: "w", kind: .weekly, label: "Weekly", usedPercent: 40)
        let codex = UsageInsights.AccountLimits(
            provider: .codex, account: .defaultAccount(for: .codex), showsAccountName: false, status: ProviderStatus(state: .ready),
            limits: UsageLimits(windows: [window], checkedAt: now))
        var settings = AppSettings()
        settings.menuBarSecondaryUsage = .account(provider: .codex, accountID: ProviderAccount.defaultID, metric: .mostUsed)
        let last = LastActiveAgent(provider: .codex, accountID: nil, date: now)
        #expect(UsageStatusItem.readings(settings: settings, accounts: [codex], lastActive: last).count == 1)
        settings.menuBarSecondaryUsage = .closest
        #expect(UsageStatusItem.readings(settings: settings, accounts: [codex], lastActive: last).map(\.provider) == [.codex, nil])
    }

    @Test func figuresReadAsAmountsOfTheirLimit() {
        let extra = UsageFigure(id: "e", label: "Extra usage", unit: .currency("USD"), used: 271.4, limit: 500)
        #expect(UsageFormat.figureValue(extra) == "$271.40 of $500.00 used")
        let requests = UsageFigure(id: "r", label: "Requests per minute", unit: .requests, limit: 50, remaining: 48)
        #expect(UsageFormat.figureValue(requests) == "48 of 50 requests left")
        #expect(UsageFormat.figureValue(UsageFigure(id: "o", label: "Extra usage", unit: .currency("USD"), detail: "Off")) == "Off")
        #expect(UsageFormat.figureValue(UsageFigure(id: "c", label: "Resets", unit: .count, remaining: 2)) == "2")
        let resetting = UsageFigure(id: "d", label: "Spent today", unit: .currency("USD"), used: 1.5, resetsAt: now.addingTimeInterval(3_600))
        #expect(UsageFormat.figureTiming(resetting, now: now)?.hasPrefix("resets in 1h 0m · ") == true)
        #expect(UsageFormat.figureTiming(extra, now: now) == nil)
    }

    @MainActor
    @Test func menuBarChoicesListEachAccountsWindowsAndBalance() {
        let codex = UsageInsights.AccountLimits(
            provider: .codex, account: .defaultAccount(for: .codex), showsAccountName: false, status: ProviderStatus(state: .ready),
            limits: UsageLimits(
                windows: [UsageLimitWindow(id: "primary", kind: .session, label: "Session", usedPercent: 4)], checkedAt: now,
                credits: UsageCredits(hasCredits: true, unlimited: false, balance: "10")))
        let options = MenuBarUsagePicker.options(accounts: [codex], allowsNone: true, current: nil)
        #expect(options.map(\.value) == [
            nil, .lastActive, .closest,
            .account(provider: .codex, accountID: ProviderAccount.defaultID, metric: .mostUsed),
            .account(provider: .codex, accountID: ProviderAccount.defaultID, metric: .window("primary")),
            .account(provider: .codex, accountID: ProviderAccount.defaultID, metric: .balance),
        ])
        let pinned = MenuBarUsageChoice.account(provider: .claude, accountID: "gone", metric: .mostUsed)
        #expect(MenuBarUsagePicker.options(accounts: [codex], allowsNone: false, current: pinned).last?.value == pinned)
    }
}
