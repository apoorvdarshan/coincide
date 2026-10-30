import Foundation
import Testing
@testable import CoincideKit

struct ClaudeCreditFallbackTests {
    private func usage(_ fields: String) throws -> JSONValue {
        try #require(JSONValue.parse("{\"rate_limits_available\":true,\"rate_limits\":{\"five_hour\":{\"utilization\":100},\"seven_day\":{\"utilization\":50}," + fields + "}}"))
    }

    @Test func enabledExtraUsageWithBudgetLeftFeedsAutomaticBalanceSelection() throws {
        let data = try usage(#""extra_usage":{"is_enabled":true,"monthly_limit":2000,"used_credits":760,"currency":"USD"}"#)
        let windows = try #require(ClaudeUsageLimits.windows(fromUsage: data))
        #expect(windows.filter { $0.kind == .session || $0.kind == .weekly }.allSatisfy { $0.continuesOnCredits })
        let spendCap = try #require(windows.first(where: { $0.id == "monthly_spend" }))
        #expect(!spendCap.continuesOnCredits)
        let account = UsageInsights.AccountLimits(provider: .claude, account: .defaultAccount(for: .claude), showsAccountName: false,
            status: ProviderStatus(state: .ready), limits: UsageLimits(windows: windows, checkedAt: Date(), figures: ClaudeUsageLimits.figures(fromUsage: data)))
        let reading = try #require(MenuBarUsage.reading(for: .lastActive, accounts: [account],
            lastActive: LastActiveAgent(provider: .claude, accountID: nil, date: Date())))
        #expect(reading.window == nil && reading.figure?.id == "extra_usage")
        #expect(reading.text == "Extra usage: \(12.4.formatted(.currency(code: "USD").precision(.fractionLength(2))))")
    }

    @Test func uncappedExtraUsageShowsItsReportedModeWithoutAnInventedBalance() throws {
        let data = try usage(#""extra_usage":{"is_enabled":true,"monthly_limit":null,"used_credits":760,"currency":"USD"},"iguana_necktie":{"limit_dollars":250,"used_dollars":1}"#)
        let windows = try #require(ClaudeUsageLimits.windows(fromUsage: data))
        let account = UsageInsights.AccountLimits(provider: .claude, account: .defaultAccount(for: .claude), showsAccountName: false,
            status: ProviderStatus(state: .ready), limits: UsageLimits(windows: windows, checkedAt: Date(), figures: ClaudeUsageLimits.figures(fromUsage: data)))
        let reading = try #require(MenuBarUsage.reading(for: .lastActive, accounts: [account],
            lastActive: LastActiveAgent(provider: .claude, accountID: nil, date: Date())))
        #expect(reading.window == nil && reading.credits == nil)
        #expect(reading.figure?.id == "extra_usage" && reading.figure?.left == nil && reading.figure?.limit == nil)
        #expect(reading.text == "Extra usage · No cap")

        let event = try #require(JSONValue.parse(#"{"rate_limit_info":{"isUsingOverage":true,"rateLimitType":"five_hour","utilization":1}}"#))
        let liveOnly = UsageInsights.AccountLimits(provider: .claude, account: .defaultAccount(for: .claude), showsAccountName: false,
            status: ProviderStatus(state: .ready), limits: UsageLimits(windows: ClaudeUsageLimits.windows(fromEvent: event), checkedAt: Date()))
        let liveReading = try #require(MenuBarUsage.reading(for: .lastActive, accounts: [liveOnly],
            lastActive: LastActiveAgent(provider: .claude, accountID: nil, date: Date())))
        #expect(liveReading.text == "Credits")
        #expect(liveReading.window == nil && liveReading.credits == nil && liveReading.figure == nil)
    }

    @Test(arguments: [
        #""extra_usage":{"is_enabled":false,"monthly_limit":2000,"used_credits":760}"#,
        #""extra_usage":{"is_enabled":true,"user_disabled":true,"monthly_limit":2000,"used_credits":760}"#,
        #""extra_usage":{"is_enabled":true,"monthly_limit":2000,"used_credits":2000}"#,
        #""extra_usage":{"is_enabled":true,"monthly_limit":0,"used_credits":0}"#,
        #""extra_usage":{"is_enabled":true,"monthly_limit":2000}"#,
        #""iguana_necktie":{"limit_dollars":250,"used_dollars":1}"#,
        #""spend":{"enabled":true,"used":{"amount_minor":10,"currency":"USD","exponent":2},"limit":{"amount_minor":20,"currency":"EUR","exponent":2}}"#,
    ])
    func disabledExhaustedOrUnknownBudgetDoesNotPromiseCreditFallback(fields: String) throws {
        let windows = try #require(ClaudeUsageLimits.windows(fromUsage: usage(fields)))
        #expect(windows.allSatisfy { !$0.continuesOnCredits })
    }

    @Test func uncappedAndCappedSpendSettingsAreOnlyAppliedToPlanWindows() throws {
        for fields in [
            #""extra_usage":{"is_enabled":true,"monthly_limit":null}"#,
            #""spend":{"enabled":false},"extra_usage":{"is_enabled":true,"monthly_limit":2000,"used_credits":100}"#,
            #""spend":{"enabled":true,"limit":null}"#,
            #""spend":{"enabled":true,"used":{"amount_minor":10,"currency":"USD","exponent":2},"limit":{"amount_minor":20,"currency":"USD","exponent":2}}"#,
        ] {
            let windows = try #require(ClaudeUsageLimits.windows(fromUsage: usage(fields)))
            #expect(windows.filter { $0.id == "five_hour" || $0.id == "seven_day" }.allSatisfy { $0.continuesOnCredits })
            #expect(windows.filter { $0.id == "monthly_spend" }.allSatisfy { !$0.continuesOnCredits })
        }
    }

    @Test func liveEventsOnlyUseExplicitOverageState() throws {
        for using in [true, false] {
            let data = try #require(JSONValue.parse("{\"rate_limit_info\":{\"isUsingOverage\":\(using),\"rateLimitType\":\"five_hour\",\"utilization\":1}}"))
            #expect(ClaudeUsageLimits.windows(fromEvent: data).first?.continuesOnCredits == using)
        }
        let rejected = try #require(JSONValue.parse(#"{"rate_limit_info":{"isUsingOverage":true,"overageStatus":"rejected","overageDisabledReason":"org_level_disabled","rateLimitType":"five_hour","utilization":1}}"#))
        #expect(ClaudeUsageLimits.windows(fromEvent: rejected).first?.continuesOnCredits == false)
    }
}
