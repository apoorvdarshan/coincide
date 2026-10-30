import CoincideKit
import Foundation
import Observation
import Synchronization
import Testing
@testable import Coincide

/// Synthetic settings and balances; changing the display preference requires no provider refresh or global region change.
@MainActor struct NumberFormatRefreshTests {
    @Test func openUsageModelsObserveNumberPreferenceChangesWithoutReloading() {
        let folder = TemporaryDirectory("number-format-refresh")
        let store = AppStore(directory: folder.url)
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        let insights = UsageInsights(store: store, registry: registry, runner: runner)
        let dashboard = UsageDashboardModel(insights: insights, store: store)
        let popover = UsageMenuModel(store: store, insights: insights)
        let dashboardRefresh = Mutex(false)
        let popoverRefresh = Mutex(false)
        withObservationTracking {
            _ = dashboard.numberFormat
            _ = dashboard.settings.numberFormat
        } onChange: {
            dashboardRefresh.withLock { $0 = true }
        }
        withObservationTracking {
            _ = popover.numberFormat
        } onChange: {
            popoverRefresh.withLock { $0 = true }
        }

        store.updateSettings { $0.numberFormat = .international }
        let dashboardChanged = dashboardRefresh.withLock { $0 }
        let popoverChanged = popoverRefresh.withLock { $0 }
        #expect(dashboardChanged)
        #expect(popoverChanged)
        #expect(dashboard.numberFormat == .international)
        #expect(popover.numberFormat == .international)
        #expect(dashboard.settings.numberFormat == .international)
        #expect(!insights.isScanning && !insights.isCheckingLimits)

        store.updateSettings { $0.usageDisplayMode = .remaining }
        #expect(dashboard.displayMode == .remaining && popover.displayMode == .remaining)
        #expect(dashboard.numberFormat == .international && popover.numberFormat == .international)
        store.updateSettings { $0.numberFormat = .system }
        #expect(dashboard.numberFormat == .system && popover.numberFormat == .system)
    }

    @Test func usageFiguresHonorInternationalFormattingWithAnIndianSystemLocale() {
        let india = Locale(identifier: "en_IN")
        let system = NumberFormatting(.system, systemLocale: india)
        let international = NumberFormatting(.international, systemLocale: india)
        #expect(UsageFormat.exactTokens(1_234_567_890, numbers: system) == "1,23,45,67,890 tokens")
        #expect(UsageFormat.exactTokens(1_234_567_890, numbers: international) == "1,234,567,890 tokens")
        #expect(UsageFormat.tokens(1_000_000, numbers: international) == "1M")
        #expect(UsageFormat.amount(1_234_567_890.5, .credits, numbers: international) == "1,234,567,890.5 credits")
        #expect(UsageFormat.amount(1_250_000.5, .currency("USD"), numbers: international) == "$1,250,000.50")
    }

    @Test func menuBarUsesItsInjectedNumberPreferenceForCreditsAndCurrency() throws {
        let now = Date()
        let window = UsageLimitWindow(id: "session", kind: .session, label: "Session", usedPercent: 100, continuesOnCredits: true)
        let credits = UsageInsights.AccountLimits(
            provider: .codex, account: .defaultAccount(for: .codex), showsAccountName: false, status: ProviderStatus(state: .ready),
            limits: UsageLimits(windows: [window], checkedAt: now,
                credits: UsageCredits(hasCredits: true, unlimited: false, balance: "1234567890.5")))
        let currency = UsageInsights.AccountLimits(
            provider: .claude, account: .defaultAccount(for: .claude), showsAccountName: false, status: ProviderStatus(state: .ready),
            limits: UsageLimits(windows: [window], checkedAt: now,
                figures: [UsageFigure(id: "extra_usage", label: "Extra usage", unit: .currency("USD"), remaining: 1_234_567_890.5)]))
        var settings = AppSettings()
        settings.numberFormat = .international
        settings.menuBarUsage = .lastActive
        let creditReading = try #require(UsageStatusItem.readings(settings: settings, accounts: [credits],
            lastActive: LastActiveAgent(provider: .codex, accountID: nil, date: now)).first)
        let currencyReading = try #require(UsageStatusItem.readings(settings: settings, accounts: [currency],
            lastActive: LastActiveAgent(provider: .claude, accountID: nil, date: now)).first)
        #expect(creditReading.text == "Credits: 1,234,567,890.5")
        #expect(currencyReading.text == "Extra usage: $1,234,567,890.50")
    }
}
