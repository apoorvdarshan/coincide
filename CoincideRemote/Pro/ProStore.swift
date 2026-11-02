import Foundation
import Observation
import RevenueCat

/// What RevenueCat last confirmed about Coincide Pro on this device, kept so a launch without a connection still
/// unlocks what was bought.
struct ProAccess: Codable, Equatable {
    var isActive: Bool
    var productID: String?
    /// When the subscription ends or renews; nil for Lifetime.
    var expiresAt: Date?
    var willRenew: Bool
    var isTrial: Bool
    var checkedAt: Date

    /// How long past its end date a subscription still counts while no newer answer has arrived, as when the phone has
    /// been offline since: a renewal normally shows up well before then, and the next answer replaces this one.
    static let offlineGrace: TimeInterval = 3 * 24 * 60 * 60

    func grants(at now: Date) -> Bool {
        guard isActive else { return false }
        guard let expiresAt else { return true }
        return now < expiresAt.addingTimeInterval(Self.offlineGrace)
    }

    var plan: ProPlan.Kind? { ProPlan.Kind.allCases.first { $0.productID == productID } }
}

/// One way to buy Coincide Pro, with its prices as the App Store gives them for this account's storefront.
struct ProPlan: Identifiable {
    enum Kind: String, CaseIterable {
        case annual, monthly, lifetime

        var productID: String {
            switch self {
            case .annual: "com.apoorvdarshan.coincide.remote.pro.yearly"
            case .monthly: "com.apoorvdarshan.coincide.remote.pro.monthly"
            case .lifetime: "com.apoorvdarshan.coincide.remote.pro.lifetime"
            }
        }

        var title: String {
            switch self {
            case .annual: String(localized: "Yearly")
            case .monthly: String(localized: "Monthly")
            case .lifetime: String(localized: "Lifetime")
            }
        }
    }

    /// A free trial the account can still start: its length in days, or nil when it isn't counted in days or weeks.
    struct Trial: Equatable {
        var days: Int?
    }

    let kind: Kind
    /// The localized price of one period (or of Lifetime), such as "$19.99".
    let price: String
    /// Yearly's price per month, such as "$1.67".
    var pricePerMonth: String?
    var trial: Trial?
    /// How much less Yearly costs than twelve months, in percent.
    var savings: Int?
    var package: Package?

    var id: String { kind.rawValue }
}

/// A tip: a consumable purchase that says thank you and unlocks nothing.
enum TipKind: String, CaseIterable, Identifiable {
    case commit, diff, greenCI = "greenci", shipIt = "shipit"

    var id: String { rawValue }
    var productID: String { "com.apoorvdarshan.coincide.remote.tip.\(rawValue)" }

    var title: String {
        switch self {
        case .commit: String(localized: "Small Commit")
        case .diff: String(localized: "Clean Diff")
        case .greenCI: String(localized: "Green CI")
        case .shipIt: String(localized: "Ship It")
        }
    }

    var symbol: String {
        switch self {
        case .commit: "smallcircle.filled.circle"
        case .diff: "plus.forwardslash.minus"
        case .greenCI: "checkmark.seal.fill"
        case .shipIt: "paperplane.fill"
        }
    }

    /// The tile's color, by `MacSettingsLabel.color` name.
    var color: String {
        switch self {
        case .commit: "teal"
        case .diff: "blue"
        case .greenCI: "green"
        case .shipIt: "pink"
        }
    }

    var thanks: String {
        switch self {
        case .commit: String(localized: "Your Small Commit made it in. Thank you for supporting Coincide!")
        case .diff: String(localized: "A Clean Diff, merged with gratitude. Thank you for supporting Coincide!")
        case .greenCI: String(localized: "All checks passed. Thank you for keeping Coincide green!")
        case .shipIt: String(localized: "Shipped! Your support keeps Coincide going. Thank you so much!")
        }
    }
}

struct Tip: Identifiable {
    let kind: TipKind
    let price: String
    var package: Package?
    var id: String { kind.rawValue }
}

/// Coincide Pro and tips through RevenueCat, with an anonymous app user ID (no account, no tracking).
///
/// Coincide Pro unlocks every action on the Mac; without it the app can be browsed and each action shows the paywall
/// (`ProGate`). It unlocks only from the `pro` entitlement in a RevenueCat answer that passed its signature check
/// (`EntitlementVerificationMode.informational`), and the last such answer is kept: a refresh that fails, or an answer
/// that fails the check, changes nothing, so known access is never taken away by a bad connection. A real answer
/// without the entitlement (a subscription that expired or was refunded) ends Pro.
@MainActor
@Observable
final class ProStore {
    static let shared = ProStore()

    static let entitlementID = "pro"
    static let tipsOfferingID = "tips"

    enum Loading: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    /// Something to tell the user after a purchase or a restore.
    enum Message: Identifiable, Equatable {
        case pending
        case restored
        case nothingToRestore
        case unconfirmed
        case failed(String)

        var id: String {
            switch self {
            case .pending: "pending"
            case .restored: "restored"
            case .nothingToRestore: "nothing"
            case .unconfirmed: "unconfirmed"
            case .failed(let text): "failed:\(text)"
            }
        }

        var title: String {
            switch self {
            case .pending: String(localized: "Waiting for Approval")
            case .restored: String(localized: "Purchases Restored")
            case .nothingToRestore: String(localized: "Nothing to Restore")
            case .unconfirmed: String(localized: "Purchase Not Confirmed Yet")
            case .failed: String(localized: "Purchase Failed")
            }
        }

        var text: String {
            switch self {
            case .pending:
                String(localized: "The purchase needs approval, such as from Ask to Buy. Coincide unlocks as soon as it’s approved.")
            case .restored: String(localized: "Coincide is unlocked again on this device.")
            case .nothingToRestore:
                String(localized: "This Apple Account has no Coincide Pro purchase. Tips aren’t restored, since they unlock nothing.")
            case .unconfirmed:
                String(localized: "The App Store took the payment, but Coincide couldn’t confirm it yet. Try Restore Purchases in a moment.")
            case .failed(let text): text
            }
        }
    }

    /// Whether RevenueCat is set up: this build has the App Store's public SDK key.
    private(set) var isAvailable = false
    private(set) var access: ProAccess?
    private(set) var plans: [ProPlan] = []
    private(set) var tips: [Tip] = []
    private(set) var loading = Loading.idle
    /// The plan or tip being bought, or "restore".
    private(set) var busy: String?
    /// What the last purchase or restore has to say; the view that started it takes it (`takeMessage()`).
    private(set) var message: Message?
    /// The tip just given, for the thank-you.
    var thanks: TipKind?
    /// Why the last tip didn't go through.
    var tipMessage: Message?

    @ObservationIgnored private var started = false
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let accessKey = "pro.access"

    init() {
        if let data = defaults.data(forKey: Self.accessKey), let saved = try? JSONDecoder().decode(ProAccess.self, from: data) {
            access = saved
        }
    }

    /// Whether actions are unlocked (`ProGate`).
    var isPro: Bool { access?.grants(at: Date()) ?? false }

    /// The App Store public SDK key from Info.plist (`RevenueCatAPIKey`). Only an App Store key (`appl_`) is used, never a
    /// Test Store key (`test_`) or a secret one, so neither can reach a build.
    static var apiKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RevenueCatAPIKey") as? String else { return nil }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.hasPrefix("appl_") && key.count > 10 ? key : nil
    }

    /// Sets up RevenueCat at launch and follows every change of what the account owns.
    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        // Screenshots and UI tests: sample prices, no RevenueCat. The demo from the Connect screen uses the App Store's.
        if DemoData.isLaunchArgument {
            loadDemo()
            return
        }
        #endif
        guard let key = Self.apiKey else { return }
        #if DEBUG
        Purchases.logLevel = .info
        #else
        Purchases.logLevel = .warn
        #endif
        Purchases.configure(
            with: Configuration.Builder(withAPIKey: key)
                .with(storeKitVersion: .storeKit2)
                .with(entitlementVerificationMode: .informational)
                .build())
        isAvailable = true
        // The last answer first (RevenueCat's cache), then every purchase, renewal, expiry or restore.
        Task {
            for await info in Purchases.shared.customerInfoStream { apply(info) }
        }
    }

    /// Asks RevenueCat again; a failure keeps what's known.
    func refresh() async {
        guard isAvailable, Purchases.isConfigured else { return }
        if let info = try? await Purchases.shared.customerInfo() { apply(info) }
    }

    private func apply(_ info: CustomerInfo) {
        // An answer whose signature didn't check out neither unlocks nor takes away.
        guard info.entitlements.verification != .failed else { return }
        let entitlement = info.entitlements[Self.entitlementID]
        if let entitlement, entitlement.verification == .failed { return }
        // A sandbox purchase (TestFlight, a development build) never unlocks an App Store build, nor the reverse.
        let updated = ProAccess(
            isActive: entitlement?.isActiveInCurrentEnvironment ?? false, productID: entitlement?.productIdentifier,
            expiresAt: entitlement?.expirationDate, willRenew: entitlement?.willRenew ?? false,
            isTrial: entitlement?.periodType == .trial, checkedAt: Date())
        access = updated
        defaults.set(try? JSONEncoder().encode(updated), forKey: Self.accessKey)
        if !isPro { PhoneAlerts.shared.proAccessEnded() }
    }

    // MARK: Offerings

    /// The plans (offering `default`) and tips (offering `tips`) with their store prices.
    func loadOfferings() async {
        #if DEBUG
        if DemoData.isLaunchArgument { return }
        #endif
        guard isAvailable, Purchases.isConfigured else {
            loading = .failed(String(localized: "Purchases aren’t available in this build of Coincide."))
            return
        }
        guard loading != .loading else { return }
        if plans.isEmpty || tips.isEmpty { loading = .loading }
        do {
            let offerings = try await Purchases.shared.offerings()
            let pro = offerings.current ?? offerings["default"]
            var built: [ProPlan] = []
            if let annual = pro?.annual {
                built.append(await plan(.annual, annual, monthly: pro?.monthly?.storeProduct))
            }
            if let monthly = pro?.monthly { built.append(await plan(.monthly, monthly, monthly: nil)) }
            if let lifetime = pro?.lifetime { built.append(await plan(.lifetime, lifetime, monthly: nil)) }
            let tipPackages = offerings[Self.tipsOfferingID]?.availablePackages ?? []
            plans = built
            tips = TipKind.allCases.compactMap { kind in
                tipPackages.first { $0.storeProduct.productIdentifier == kind.productID }.map {
                    Tip(kind: kind, price: $0.storeProduct.localizedPriceString, package: $0)
                }
            }
            loading = built.isEmpty && tips.isEmpty
                ? .failed(String(localized: "Coincide Pro isn’t available from the App Store right now. Try again later."))
                : .loaded
        } catch {
            loading = plans.isEmpty && tips.isEmpty ? .failed(Self.describe(error) ?? error.localizedDescription) : .loaded
        }
    }

    private func plan(_ kind: ProPlan.Kind, _ package: Package, monthly: StoreProduct?) async -> ProPlan {
        let product = package.storeProduct
        var plan = ProPlan(kind: kind, price: product.localizedPriceString, package: package)
        if kind == .annual {
            plan.pricePerMonth = product.localizedPricePerMonth
            if let monthly, monthly.currencyCode == product.currencyCode, monthly.price > 0 {
                let twelve = monthly.price * 12
                // Through Double: NSDecimalNumber's intValue is wrong for decimals with long mantissas, as this one has.
                let fraction = NSDecimalNumber(decimal: (twelve - product.price) / twelve).doubleValue
                let percent = Int((fraction * 100).rounded(.down))
                if percent >= 5 { plan.savings = percent }
            }
        }
        // A free trial only when the account can still start it, so the paywall never promises one it won't get.
        if let intro = product.introductoryDiscount, intro.paymentMode == .freeTrial,
            await Purchases.shared.checkTrialOrIntroDiscountEligibility(product: product) == .eligible
        {
            let period = intro.subscriptionPeriod
            let days: Int? =
                switch period.unit {
                case .day: period.value * intro.numberOfPeriods
                case .week: period.value * 7 * intro.numberOfPeriods
                default: nil
                }
            plan.trial = ProPlan.Trial(days: days)
        }
        return plan
    }

    // MARK: Buying

    /// Buys a plan. True once it went through (Pro is then on, or `message` says why not yet).
    @discardableResult
    func purchase(_ plan: ProPlan) async -> Bool {
        guard await buy(plan.package, id: plan.id) else { return false }
        if !isPro { message = .unconfirmed }
        return true
    }

    func give(_ tip: Tip) async {
        if await buy(tip.package, id: tip.id) { thanks = tip.kind } else { tipMessage = takeMessage() }
    }

    private func buy(_ package: Package?, id: String) async -> Bool {
        guard let package, busy == nil, Purchases.isConfigured else { return false }
        busy = id
        defer { busy = nil }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            guard !result.userCancelled else { return false }
            apply(result.customerInfo)
            return true
        } catch {
            if let code = error as? RevenueCat.ErrorCode, code == .paymentPendingError {
                message = .pending
            } else if let text = Self.describe(error) {
                message = .failed(text)
            }
            return false
        }
    }

    /// The message from the purchase or restore that just finished, once.
    func takeMessage() -> Message? {
        defer { message = nil }
        return message
    }

    func restore() async {
        guard isAvailable, busy == nil, Purchases.isConfigured else { return }
        busy = "restore"
        defer { busy = nil }
        do {
            apply(try await Purchases.shared.restorePurchases())
            message = isPro ? .restored : .nothingToRestore
        } catch {
            message = .failed(Self.describe(error) ?? error.localizedDescription)
        }
    }

    /// What to tell the user about a failed purchase; nil when there's nothing to say (they cancelled).
    static func describe(_ error: Error) -> String? {
        guard let code = error as? RevenueCat.ErrorCode else { return error.localizedDescription }
        switch code {
        case .purchaseCancelledError: return nil
        case .networkError, .offlineConnectionError:
            return String(localized: "Couldn’t reach the App Store. Check your internet connection and try again.")
        case .purchaseNotAllowedError:
            return String(localized: "Purchases aren’t allowed on this device. Check Screen Time’s content and privacy restrictions.")
        case .productNotAvailableForPurchaseError, .configurationError:
            return String(localized: "Coincide Pro isn’t available from the App Store right now. Try again later.")
        case .paymentPendingError:
            return Message.pending.text
        default:
            return error.localizedDescription
        }
    }

    // MARK: Screenshots

    #if DEBUG
    /// Sample prices for screenshots (`-CoincideRemoteDemo`). As in the App Store build, browsing is free and actions show
    /// the paywall; `-CoincideRemoteDemoPro` unlocks them.
    private func loadDemo() {
        isAvailable = true
        plans = [
            ProPlan(kind: .annual, price: "$19.99", pricePerMonth: "$1.67", trial: ProPlan.Trial(days: 7), savings: 44),
            ProPlan(kind: .monthly, price: "$2.99"),
            ProPlan(kind: .lifetime, price: "$39.99"),
        ]
        tips = zip(TipKind.allCases, ["$1.99", "$4.99", "$9.99", "$19.99"]).map { Tip(kind: $0, price: $1) }
        loading = .loaded
        access = !DemoData.has("Pro")
            ? nil
            : ProAccess(
                isActive: true, productID: ProPlan.Kind.annual.productID, expiresAt: Date().addingTimeInterval(300 * 24 * 60 * 60),
                willRenew: true, isTrial: false, checkedAt: Date())
        if DemoData.has("TipThanks") { thanks = .greenCI }
    }
    #endif
}
