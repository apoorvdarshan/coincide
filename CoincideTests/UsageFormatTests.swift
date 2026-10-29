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
    @Test func theMenuBarSummaryNamesTheClosestLimit() {
        let window = UsageLimitWindow(id: "w", kind: .weekly, label: "Weekly", usedPercent: 71.4, resetsAt: now.addingTimeInterval(3_600))
        let account = UsageInsights.AccountLimits(
            provider: .codex, account: .defaultAccount(for: .codex), showsAccountName: false, status: ProviderStatus(state: .ready),
            limits: UsageLimits(windows: [window], checkedAt: now))
        #expect(UsageStatusItem.summary((account, window), now: now) == "Coincide usage: Codex weekly limit 71% used, resets in 1h 0m")
        #expect(UsageStatusItem.summary(nil, now: now) == "Coincide usage: no plan limits reported")
        #expect(UsageStatusItem.gauge(percent: 97) != nil)
    }
}
