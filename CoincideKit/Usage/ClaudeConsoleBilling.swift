import Foundation

/// The Claude Console's prepaid API credit balance, read with the user's platform.claude.com sign-in in Coincide's
/// browser. Anthropic's API (even with an Admin key) doesn't report it; the Console's billing page does.
///
/// The endpoints are the ones the Console's billing page itself uses, as the open-source CodexBar reads them
/// (github.com/steipete/CodexBar, `claudeplatform` provider, docs/claudeplatform.md). They are undocumented:
/// - `GET /api/organizations`: the account's organizations. Only those whose `capabilities` include `api` own Console
///   billing; Claude.ai chat organizations in the same list are skipped.
/// - `GET /api/organizations/{uuid}/prepaid/credits`: the balance (`amount`, in minor units, scaled by
///   `balance.credits.exponent`, 2 when absent) and its grants (`tranches`, bought; `promo_tranches`, such as a Max
///   plan's API credit), each granted and remaining in minor units with an expiry. The first API organization that
///   answers (not 403) is used.
/// - `GET /api/organizations/{uuid}/current_spend`: this month's spend (UTC), optional.
public enum ClaudeConsoleBilling {
    /// One grant of credit: bought, or given (a plan's API credit, a promotion).
    public struct Grant: Sendable, Hashable {
        public var id: String?
        public var name: String?
        public var program: String?
        public var purchased: Bool
        public var granted: Double
        public var remaining: Double
        public var expiresAt: Date?

        public nonisolated init(
            id: String? = nil, name: String? = nil, program: String? = nil, purchased: Bool, granted: Double, remaining: Double,
            expiresAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.program = program
            self.purchased = purchased
            self.granted = granted
            self.remaining = remaining
            self.expiresAt = expiresAt
        }
    }

    public struct Report: Sendable, Hashable {
        public var organization: String?
        public var currency: String
        /// The prepaid balance, in major units (dollars).
        public var balance: Double
        /// Unexpired grants, soonest to expire first.
        public var grants: [Grant]
        /// This month's spend (UTC) in major units, when the Console reported it.
        public var monthSpend: Double?
        public var checkedAt: Date

        public nonisolated init(
            organization: String?, currency: String, balance: Double, grants: [Grant], monthSpend: Double?, checkedAt: Date
        ) {
            self.organization = organization
            self.currency = currency
            self.balance = balance
            self.grants = grants
            self.monthSpend = monthSpend
            self.checkedAt = checkedAt
        }
    }

    nonisolated static let base = URL(string: "https://platform.claude.com")!
    /// The Console's sign-in cookie; without it there is nothing to read.
    nonisolated static let sessionCookie = "sessionKey"

    // MARK: Reading

    /// Reads the balance with `cookie` (the profile's cookies for platform.claude.com).
    nonisolated static func read(cookie: String?, fetch: UsageLimitsFetch, now: Date = Date()) async -> BrowserUsageOutcome {
        guard let cookie, BrowserCookieHeader.contains(cookie, name: sessionCookie) else { return .problem(.notSignedIn) }
        func get(_ path: String) async -> Result<JSONValue, BrowserUsageProblemError> {
            await BrowserUsageHTTP.json(BrowserUsageHTTP.get(base.appendingPathComponent(path), cookie: cookie), fetch: fetch)
        }
        let organizations: JSONValue
        switch await get("api/organizations") {
        case .success(let json): organizations = json
        // The list doubles as the sign-in check: a refused cookie answers 401 or 403.
        case .failure(let error) where error.problem == .forbidden: return .problem(.sessionExpired)
        case .failure(let error): return .problem(error.problem)
        }
        guard let candidates = apiOrganizations(organizations) else { return .problem(.unrecognized) }
        guard !candidates.isEmpty else { return .problem(.noAPIOrganization) }
        for candidate in candidates {
            switch await get("api/organizations/\(candidate.id)/prepaid/credits") {
            case .success(let credits):
                guard var report = report(credits, organization: candidate.name, now: now) else { return .problem(.unrecognized) }
                // Spend is optional: a failed read keeps the balance.
                if case .success(let spend) = await get("api/organizations/\(candidate.id)/current_spend") {
                    report.monthSpend = minor(spend["amount"]).flatMap { $0 >= 0 ? $0 / scale(credits) : nil }
                }
                return .reading(reading(report))
            case .failure(let error) where error.problem == .forbidden:
                continue
            case .failure(let error):
                return .problem(error.problem)
            }
        }
        return .problem(.forbidden)
    }

    // MARK: Parsing

    /// The API organizations in the list, in its order, with their names; nil when it isn't a list of organizations.
    nonisolated static func apiOrganizations(_ json: JSONValue) -> [(id: String, name: String?)]? {
        guard let list = json.array else { return nil }
        var result: [(id: String, name: String?)] = []
        for organization in list {
            guard organization.object != nil else { return nil }
            guard organization["capabilities"]?.array?.contains(.string("api")) == true else { continue }
            // The ID goes into a path: only plain IDs.
            guard let id = BrowserUsageHTTP.text(organization["uuid"]),
                id.count <= 64, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { return nil }
            result.append((id, BrowserUsageHTTP.text(organization["name"])))
        }
        return result
    }

    /// The balance and grants of a `prepaid/credits` answer, in major units; nil when it lacks a balance.
    nonisolated static func report(_ credits: JSONValue, organization: String?, now: Date) -> Report? {
        guard credits.object != nil, let amount = minor(credits["amount"]) else { return nil }
        let currency = BrowserUsageHTTP.text(credits["currency"]) ?? "USD"
        guard currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        let scale = scale(credits)
        var grants: [Grant] = []
        for (field, purchased) in [("promo_tranches", false), ("tranches", true)] {
            for tranche in credits[field]?.array ?? [] {
                guard let granted = minor(tranche["granted_amount_minor_units"]), granted > 0,
                    let remaining = minor(tranche["remaining_amount_minor_units"])
                else { continue }
                let expires = BrowserUsageHTTP.text(tranche["expires_at"]).flatMap(ClaudeUsageLimits.date(fromISO:))
                if let expires, expires <= now { continue }
                grants.append(
                    Grant(
                        id: BrowserUsageHTTP.text(tranche["id"]), name: BrowserUsageHTTP.text(tranche["name"]),
                        program: BrowserUsageHTTP.text(tranche["program_id"]), purchased: purchased, granted: granted / scale,
                        remaining: max(0, remaining) / scale, expiresAt: expires))
            }
        }
        grants.sort { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        return Report(organization: organization, currency: currency, balance: amount / scale, grants: grants, monthSpend: nil, checkedAt: now)
    }

    /// An amount in minor units: a whole number.
    nonisolated static func minor(_ value: JSONValue?) -> Double? {
        guard let number = value?.number, number.isFinite, number.rounded() == number else { return nil }
        return number
    }

    /// What minor units divide by: 10 to the balance's exponent (0–4), 100 when it isn't given.
    nonisolated static func scale(_ credits: JSONValue) -> Double {
        guard let exponent = credits.at("balance.credits.exponent")?.exactInt, (0...4).contains(exponent) else { return 100 }
        return pow(10, Double(exponent))
    }

    // MARK: Figures

    /// The figures the report adds to a Claude account. The balance measures against the credit granted (bought and
    /// given) that hasn't expired, which is what it was drawn from; with no grants listed it is a bare balance, which
    /// Coincide measures against the highest it has seen. With several grants, each one shows too, with its expiry.
    public nonisolated static func figures(_ report: Report) -> [UsageFigure] {
        let unit = UsageFigure.Unit.currency(report.currency)
        let granted = report.grants.reduce(0) { $0 + $1.granted }
        let measured = granted > 0 && granted >= report.balance
        var figures = [
            UsageFigure(
                id: "console_balance", label: String(localized: "Console credits"), unit: unit,
                limit: measured ? granted : nil, remaining: report.balance,
                expiresAt: report.grants.count == 1 ? report.grants[0].expiresAt : nil, detail: report.organization)
        ]
        if report.grants.count > 1 {
            for (index, grant) in report.grants.enumerated() {
                figures.append(
                    UsageFigure(
                        id: "console_grant_" + (grant.id ?? String(index)), label: grantLabel(grant), unit: unit,
                        used: max(0, grant.granted - grant.remaining), limit: grant.granted, expiresAt: grant.expiresAt))
            }
        }
        if let spend = report.monthSpend {
            figures.append(
                UsageFigure(
                    id: "console_spend", label: String(localized: "Console spend"), unit: unit, used: spend,
                    detail: String(localized: "This month (UTC)")))
        }
        return figures
    }

    nonisolated static func grantLabel(_ grant: Grant) -> String {
        if let name = grant.name { return name }
        return grant.purchased ? String(localized: "Purchased credit") : String(localized: "API credit")
    }

    nonisolated static func reading(_ report: Report) -> BrowserUsageReading {
        BrowserUsageReading(source: .claudeConsole, checkedAt: report.checkedAt, figures: figures(report), identity: report.organization)
    }
}
