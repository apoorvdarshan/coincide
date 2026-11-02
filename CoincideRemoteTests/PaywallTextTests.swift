import Foundation
import Testing

@testable import CoincideRemote

/// The paywall's wording for each plan (`PaywallText`): what the button says and what it will charge, which Apple's
/// review checks against the plan the user picked.
struct PaywallTextTests {
    private let yearly = ProPlan(kind: .annual, price: "$19.99", pricePerMonth: "$1.67", trial: ProPlan.Trial(days: 7), savings: 44)
    private let monthly = ProPlan(kind: .monthly, price: "$2.99")
    private let lifetime = ProPlan(kind: .lifetime, price: "$39.99")

    @Test func theButtonSaysWhatItDoes() {
        #expect(PaywallText.action(yearly) == "Start Free Trial")
        #expect(PaywallText.action(ProPlan(kind: .annual, price: "$19.99")) == "Subscribe")
        #expect(PaywallText.action(monthly) == "Subscribe")
        #expect(PaywallText.action(lifetime) == "Buy Lifetime")
    }

    @Test func theChargeNamesThePriceAndRenewal() {
        #expect(PaywallText.charge(yearly) == "7-day free trial, then $19.99/year")
        #expect(PaywallText.charge(ProPlan(kind: .annual, price: "$19.99")) == "$19.99/year, renews automatically")
        #expect(PaywallText.charge(monthly) == "$2.99/month, renews automatically")
        #expect(PaywallText.charge(lifetime) == "$39.99 once, no subscription")
    }

    /// A trial that isn't counted in days or weeks still says it's free first.
    @Test func aTrialWithoutDaysStillSaysFree() {
        #expect(PaywallText.trial(ProPlan(kind: .annual, price: "$19.99", trial: ProPlan.Trial(days: nil))) == "Free trial, then $19.99/year")
    }

    @Test func onlyYearlyHasABadge() {
        #expect(PaywallText.badge(yearly) == "Save 44%")
        #expect(PaywallText.badge(ProPlan(kind: .annual, price: "$19.99")) == "Best Value")
        #expect(PaywallText.badge(monthly) == nil)
        #expect(PaywallText.badge(lifetime) == nil)
    }

    @Test func theStatusSaysWhatIsActive() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let date = end.formatted(date: .abbreviated, time: .omitted)
        func access(_ plan: ProPlan.Kind, expiresAt: Date?, willRenew: Bool = true, isTrial: Bool = false) -> ProAccess {
            ProAccess(isActive: true, productID: plan.productID, expiresAt: expiresAt, willRenew: willRenew, isTrial: isTrial, checkedAt: end)
        }
        #expect(PaywallText.status(access(.lifetime, expiresAt: nil)) == "Lifetime: yours to keep. Thank you!")
        #expect(PaywallText.status(access(.annual, expiresAt: end, isTrial: true)) == "Free trial until \(date)")
        #expect(PaywallText.status(access(.annual, expiresAt: end)) == "Yearly, renews \(date)")
        #expect(PaywallText.status(access(.monthly, expiresAt: end, willRenew: false)) == "Monthly, ends \(date)")
    }
}
