import Foundation
import Testing

@testable import CoincideKit

/// What the menu bar item shows for each choice, and the last active agent it follows by default. Synthetic accounts
/// only.
struct MenuBarUsageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ id: String, _ kind: UsageLimitWindow.Kind, _ used: Double, resetIn hours: Double = 1) -> UsageLimitWindow {
        UsageLimitWindow(id: id, kind: kind, label: id.capitalized, usedPercent: used, resetsAt: now.addingTimeInterval(hours * 3_600))
    }

    private func account(
        _ provider: ProviderKind, id: String = ProviderAccount.defaultID, windows: [UsageLimitWindow] = [],
        modelWindows: [UsageLimitWindow] = [], credits: UsageCredits? = nil, figures: [UsageFigure] = []
    ) -> UsageInsights.AccountLimits {
        let account =
            id == ProviderAccount.defaultID
            ? ProviderAccount.defaultAccount(for: provider) : ProviderAccount(id: id, provider: provider, name: "Work", auth: .apiKey)
        let limits =
            windows.isEmpty && modelWindows.isEmpty && credits == nil && figures.isEmpty
            ? nil
            : UsageLimits(windows: windows, checkedAt: now, credits: credits, modelWindows: modelWindows, figures: figures)
        return UsageInsights.AccountLimits(
            provider: provider, account: account, showsAccountName: id != ProviderAccount.defaultID, status: ProviderStatus(state: .ready),
            limits: limits)
    }

    private var accounts: [UsageInsights.AccountLimits] {
        [
            account(.claude, windows: [window("five_hour", .session, 30), window("seven_day", .weekly, 52)]),
            account(.codex, windows: [window("primary", .session, 90), window("secondary", .weekly, 10)],
                credits: UsageCredits(hasCredits: true, unlimited: false, balance: "1250")),
            account(.claude, id: "key", figures: [
                UsageFigure(id: "ratelimit_requests", label: "Requests per minute", unit: .requests, limit: 50, remaining: 48),
            ]),
            account(.opencode, id: "router", figures: [
                UsageFigure(id: "key_limit", label: "Key credit limit", unit: .currency("USD"), limit: 20, remaining: 12.4),
            ]),
        ]
    }

    @Test func autoFollowsTheLastActiveAgentAndItsMostUsedWindow() throws {
        let claude = try #require(
            MenuBarUsage.reading(
                for: .lastActive, accounts: accounts, lastActive: LastActiveAgent(provider: .claude, accountID: nil, date: now)))
        #expect(claude.provider == .claude)
        #expect(claude.window?.id == "seven_day")
        #expect(claude.text == MenuBarUsage.percentText(window("x", .weekly, 52)))
        let codex = try #require(
            MenuBarUsage.reading(
                for: .lastActive, accounts: accounts, lastActive: LastActiveAgent(provider: .codex, accountID: ProviderAccount.defaultID, date: now)))
        #expect(codex.provider == .codex && codex.window?.id == "primary")
    }

    @Test(arguments: ProviderKind.allCases)
    func autoShowsTheReportedCreditBalanceWhenThePlanContinuesOnCredits(provider: ProviderKind) throws {
        var session = window("session", .session, 100)
        session.continuesOnCredits = true
        let creditAccount = account(provider, windows: [session, window("weekly", .weekly, 50)],
            credits: UsageCredits(hasCredits: true, unlimited: false, balance: "1250.5"))
        let last = LastActiveAgent(provider: provider, accountID: nil, date: now)
        for mode in [UsageDisplayMode.used, .remaining] {
            let reading = try #require(MenuBarUsage.reading(for: .lastActive, accounts: [creditAccount], lastActive: last, mode: mode))
            #expect(reading.provider == provider)
            #expect(reading.window == nil)
            #expect(reading.credits?.balance == "1250.5")
            #expect(reading.text == "Credits: \(1250.5.formatted(.number.precision(.fractionLength(0...2))))")
        }
        // Fixed window/most-used choices remain exactly what the user pinned.
        for metric in [MenuBarUsageMetric.window("session"), .mostUsed] {
            let pinned = try #require(MenuBarUsage.reading(
                for: .account(provider: provider, accountID: ProviderAccount.defaultID, metric: metric),
                accounts: [creditAccount], lastActive: last))
            #expect(pinned.window?.id == "session")
            #expect(pinned.credits == nil)
        }
    }

    @Test func autoReturnsToThePlanWhenItResetsAndDoesNotGuessThatAvailableCreditsAreInUse() throws {
        var session = window("session", .session, 100)
        session.continuesOnCredits = true
        let codex = account(.codex, windows: [session, window("weekly", .weekly, 50)],
            credits: UsageCredits(hasCredits: true, unlimited: false, balance: "1250.5"))
        let last = LastActiveAgent(provider: .codex, accountID: nil, date: now)
        #expect(MenuBarUsage.reading(for: .lastActive, accounts: [codex], lastActive: last, now: now.addingTimeInterval(3_601))?.credits == nil)
        #expect(MenuBarUsage.reading(for: .lastActive, accounts: [codex], lastActive: last, now: now.addingTimeInterval(3_601))?.window != nil)
        let available = account(.codex, windows: [window("session", .session, 95)],
            credits: UsageCredits(hasCredits: true, unlimited: false, balance: "1250.5"))
        #expect(MenuBarUsage.reading(for: .lastActive, accounts: [available], lastActive: last)?.window?.usedPercent == 95)
        let blocked = account(.codex, windows: [session, window("weekly", .weekly, 100)],
            credits: UsageCredits(hasCredits: true, unlimited: false, balance: "1250.5"))
        #expect(MenuBarUsage.reading(for: .lastActive, accounts: [blocked], lastActive: last)?.credits == nil)
        let modelOnly = account(.codex, windows: [window("session", .session, 50)], modelWindows: [session],
            credits: UsageCredits(hasCredits: true, unlimited: false, balance: "1250.5"))
        #expect(MenuBarUsage.reading(for: .lastActive, accounts: [modelOnly], lastActive: last)?.credits == nil)
        let modelBlocked = account(.codex, windows: [session], modelWindows: [window("model", .weekly, 100)],
            credits: UsageCredits(hasCredits: true, unlimited: false, balance: "1250.5"))
        #expect(MenuBarUsage.reading(for: .lastActive, accounts: [modelBlocked], lastActive: last)?.credits == nil)
    }

    @Test func activeCreditModeDoesNotInventUnknownBalancesAndRecognizesReportedFigures() throws {
        var session = window("session", .session, 100)
        session.continuesOnCredits = true
        let last = LastActiveAgent(provider: .codex, accountID: nil, date: now)
        for balance in [nil, "unknown", "NaN", "infinity"] {
            let missing = account(.codex, windows: [session], credits: UsageCredits(hasCredits: true, unlimited: false, balance: balance))
            let reading = try #require(MenuBarUsage.reading(for: .lastActive, accounts: [missing], lastActive: last))
            #expect(reading.window == nil && reading.credits == nil && reading.figure == nil)
            #expect(reading.text == "Credits")
        }
        let unlimited = account(.codex, windows: [session], credits: UsageCredits(hasCredits: true, unlimited: true))
        #expect(MenuBarUsage.reading(for: .lastActive, accounts: [unlimited], lastActive: last)?.text == "Unlimited credits")
        let namedCredits = UsageFigure(id: "balance", label: "Cloud credits", unit: .credits, remaining: 1250.5)
        let creditFigure = account(.codex, windows: [session], figures: [namedCredits])
        let creditReading = try #require(MenuBarUsage.reading(for: .lastActive, accounts: [creditFigure], lastActive: last))
        #expect(creditReading.figure == namedCredits)
        #expect(creditReading.text == "Cloud credits: \(1250.5.formatted(.number.precision(.fractionLength(0...2))))")
        let monetary = UsageFigure(id: "extra_usage", label: "Extra usage", unit: .currency("USD"), remaining: 12.4)
        let moneyFigure = account(.codex, windows: [session], figures: [monetary])
        let moneyReading = try #require(MenuBarUsage.reading(for: .lastActive, accounts: [moneyFigure], lastActive: last))
        #expect(moneyReading.figure == monetary)
        #expect(moneyReading.text == "Extra usage: \(12.4.formatted(.currency(code: "USD").precision(.fractionLength(2))))")
        let requestQuota = account(.codex, windows: [session], figures: [
            UsageFigure(id: "requests", label: "Requests", unit: .requests, remaining: 20),
        ])
        let unknownBalance = try #require(MenuBarUsage.reading(for: .lastActive, accounts: [requestQuota], lastActive: last))
        #expect(unknownBalance.window == nil && unknownBalance.credits == nil && unknownBalance.figure == nil)
        #expect(unknownBalance.text == "Credits")
    }

    @Test func anActiveUsageDetailDoesNotDependOnTheProviderSessionLanguage() throws {
        var session = window("session", .session, 100)
        session.continuesOnCredits = true
        let extra = UsageFigure(id: "extra_usage", label: "Usage supplémentaire", unit: .currency("EUR"), used: 3, detail: "Sans plafond")
        let promo = UsageFigure(id: "promo", label: "Cloud credits", unit: .currency("EUR"), limit: 100, remaining: 99)
        let source = account(.claude, windows: [session], figures: [extra, promo])
        let reading = try #require(MenuBarUsage.reading(for: .lastActive, accounts: [source],
            lastActive: LastActiveAgent(provider: .claude, accountID: nil, date: now)))
        #expect(reading.figure == extra)
        #expect(reading.text == "Usage supplémentaire · Sans plafond")
    }

    @Test func autoWithAnAccountWithoutWindowsShowsItsBalance() throws {
        let router = try #require(
            MenuBarUsage.reading(for: .lastActive, accounts: accounts, lastActive: LastActiveAgent(provider: .opencode, accountID: "router", date: now)))
        #expect(router.provider == .opencode && router.window == nil)
        #expect(router.figure?.id == "key_limit")
        #expect(router.text == 12.4.formatted(.currency(code: "USD").precision(.fractionLength(2))))
        // Requests per minute are no balance: the logo alone.
        let key = try #require(
            MenuBarUsage.reading(for: .lastActive, accounts: accounts, lastActive: LastActiveAgent(provider: .claude, accountID: "key", date: now)))
        #expect(key.provider == .claude && key.text == nil)
    }

    @Test func autoFallsBackToTheClosestLimit() throws {
        // Nothing ran yet, or the agent's provider is off: the closest limit across all, with the gauge.
        for lastActive in [nil, LastActiveAgent(provider: .cursor, accountID: nil, date: now)] {
            let reading = try #require(MenuBarUsage.reading(for: .lastActive, accounts: accounts, lastActive: lastActive))
            #expect(reading.provider == nil)
            #expect(reading.account?.provider == .codex && reading.window?.id == "primary")
        }
        // A removed account of a provider still on falls back to its default account.
        let removed = try #require(
            MenuBarUsage.reading(for: .lastActive, accounts: accounts, lastActive: LastActiveAgent(provider: .claude, accountID: "gone", date: now)))
        #expect(removed.provider == .claude && removed.account?.account.isDefault == true)
    }

    @Test func closestLimitIsAcrossEveryAccount() throws {
        let reading = try #require(MenuBarUsage.reading(for: .closest, accounts: accounts, lastActive: LastActiveAgent(provider: .claude, accountID: nil, date: now)))
        #expect(reading.provider == nil)
        #expect(reading.account?.provider == .codex)
        #expect(reading.window?.usedPercent == 90)
        #expect(MenuBarUsage.reading(for: .closest, accounts: [], lastActive: nil) == nil)
    }

    @Test func aFixedChoiceShowsItsAccountsFigureWhateverRanLast() throws {
        let lastActive = LastActiveAgent(provider: .codex, accountID: nil, date: now)
        let weekly = try #require(
            MenuBarUsage.reading(
                for: .account(provider: .claude, accountID: ProviderAccount.defaultID, metric: .window("five_hour")), accounts: accounts,
                lastActive: lastActive))
        #expect(weekly.provider == .claude && weekly.window?.id == "five_hour")
        let most = try #require(
            MenuBarUsage.reading(for: .account(provider: .codex, accountID: ProviderAccount.defaultID, metric: .mostUsed), accounts: accounts, lastActive: nil))
        #expect(most.window?.id == "primary")
        let credits = try #require(
            MenuBarUsage.reading(for: .account(provider: .codex, accountID: ProviderAccount.defaultID, metric: .balance), accounts: accounts, lastActive: nil))
        #expect(credits.credits?.balance == "1250")
        #expect(credits.text == 1250.0.formatted(.number.precision(.fractionLength(0...2))))
        // A window the account does not report now shows the logo without text.
        let missing = try #require(
            MenuBarUsage.reading(
                for: .account(provider: .claude, accountID: ProviderAccount.defaultID, metric: .window("monthly_spend")), accounts: accounts,
                lastActive: nil))
        #expect(missing.provider == .claude && missing.window == nil && missing.text == nil)
        // An account that is gone shows the closest limit instead.
        let gone = try #require(
            MenuBarUsage.reading(for: .account(provider: .grok, accountID: "x", metric: .mostUsed), accounts: accounts, lastActive: nil))
        #expect(gone.provider == nil && gone.window?.usedPercent == 90)
    }

    @Test func modelWindowsCountTowardTheMostUsedWindow() {
        let account = account(.codex, windows: [window("primary", .session, 20)], modelWindows: [window("spark/primary", .session, 80)])
        #expect(MenuBarUsage.mostUsedWindow(account)?.id == "spark/primary")
        #expect(MenuBarUsage.allWindows(account).map(\.id) == ["primary", "spark/primary"])
        #expect(!MenuBarUsage.hasBalance(account))
    }

    @Test func showingWhatIsLeftFlipsTheMenuBarText() throws {
        let weekly = window("seven_day", .weekly, 52)
        #expect(MenuBarUsage.percentText(weekly) == 0.52.formatted(.percent.precision(.fractionLength(0))))
        #expect(MenuBarUsage.percentText(weekly, mode: .remaining) == "\(0.48.formatted(.percent.precision(.fractionLength(0)))) left")
        let last = LastActiveAgent(provider: .claude, accountID: nil, date: now)
        let left = try #require(MenuBarUsage.reading(for: .lastActive, accounts: accounts, lastActive: last, mode: .remaining))
        #expect(left.window?.id == "seven_day")
        #expect(left.text == MenuBarUsage.percentText(weekly, mode: .remaining))
        // The closest limit across all is still the most used one; only its wording flips.
        let closest = try #require(MenuBarUsage.reading(for: .closest, accounts: accounts, lastActive: nil, mode: .remaining))
        #expect(closest.window?.id == "primary")
        #expect(closest.text == MenuBarUsage.percentText(window("primary", .session, 90), mode: .remaining))
        // A balance is what is left either way.
        let router = LastActiveAgent(provider: .opencode, accountID: "router", date: now)
        #expect(
            MenuBarUsage.reading(for: .lastActive, accounts: accounts, lastActive: router, mode: .remaining)?.text
                == MenuBarUsage.reading(for: .lastActive, accounts: accounts, lastActive: router, mode: .used)?.text)
    }

    @Test func barsDrainAndThePaceMarkMirrorsWhenShowingWhatIsLeft() throws {
        // A five-hour window with two hours to go: 60% of it has passed.
        let session = UsageLimitWindow(
            id: "s", kind: .session, label: "Session", usedPercent: 70, resetsAt: now.addingTimeInterval(2 * 3_600), durationMinutes: 300)
        #expect(session.shownPercent(.used) == 70 && session.shownPercent(.remaining) == 30)
        #expect(abs(session.barFill(.used) - 0.7) < 0.0001)
        #expect(abs(session.barFill(.remaining) - 0.3) < 0.0001)
        #expect(abs(try #require(session.paceMark(at: now, mode: .used)) - 0.6) < 0.0001)
        #expect(abs(try #require(session.paceMark(at: now, mode: .remaining)) - 0.4) < 0.0001)
        #expect(window("w", .weekly, 10).paceMark(at: now, mode: .remaining) == nil)
    }

    @Test func theDisplayModeDefaultsToUsedAndPersists() throws {
        #expect(AppSettings().usageDisplayMode == .used)
        var settings = AppSettings()
        settings.usageDisplayMode = .remaining
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.usageDisplayMode == .remaining)
        // Settings from before the choice, or with a value this version does not know, read as used.
        let old = try #require(#"{"showsUsageInMenuBar":false}"#.data(using: .utf8))
        #expect(try JSONDecoder().decode(AppSettings.self, from: old).usageDisplayMode == .used)
        let odd = try #require(#"{"usageDisplayMode":"sideways","showsUsageInMenuBar":false}"#.data(using: .utf8))
        let fallback = try JSONDecoder().decode(AppSettings.self, from: odd)
        #expect(fallback.usageDisplayMode == .used)
        #expect(fallback.showsUsageInMenuBar == false)
    }

    @Test func choicesRoundTripThroughSettingsAndDefaultToAuto() throws {
        #expect(AppSettings().menuBarUsage == .lastActive)
        #expect(AppSettings().menuBarSecondaryUsage == nil)
        var settings = AppSettings()
        settings.menuBarUsage = .account(provider: .claude, accountID: "key", metric: .window("seven_day"))
        settings.menuBarSecondaryUsage = .closest
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.menuBarUsage == settings.menuBarUsage)
        #expect(decoded.menuBarSecondaryUsage == .closest)
        // A choice this version cannot read falls back to the default rather than losing the settings.
        let odd = try #require(#"{"menuBarUsage":{"account":{"provider":"someday","accountID":"x","metric":{"mostUsed":{}}}},"showsUsageInMenuBar":false}"#.data(using: .utf8))
        let fallback = try JSONDecoder().decode(AppSettings.self, from: odd)
        #expect(fallback.menuBarUsage == .lastActive)
        #expect(fallback.showsUsageInMenuBar == false)
    }
}

/// The last agent used, kept across launches.
@MainActor
struct LastActiveAgentTests {
    @Test func recordsPersistAndNotifyOnlyOnChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("last-active-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LastActiveAgentStore(directory: directory)
        #expect(store.value == nil)
        final class Count: @unchecked Sendable { var value = 0 }
        let notified = Count()
        let observer = NotificationCenter.default.addObserver(forName: LastActiveAgentStore.didChange, object: store, queue: nil) { _ in
            notified.value += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        store.record(provider: .claude, account: nil, at: first)
        store.record(provider: .claude, account: ProviderAccount.defaultID, at: first.addingTimeInterval(60))
        store.record(provider: .codex, account: "work", at: first.addingTimeInterval(120))
        #expect(notified.value == 2)
        store.flush()
        let reopened = LastActiveAgentStore(directory: directory)
        #expect(reopened.value == LastActiveAgent(provider: .codex, accountID: "work", date: first.addingTimeInterval(120)))
        // A damaged file reads as nothing rather than failing.
        try Data("{".utf8).write(to: directory.appendingPathComponent("last-active-agent.json"))
        #expect(LastActiveAgentStore(directory: directory).value == nil)
    }
}
