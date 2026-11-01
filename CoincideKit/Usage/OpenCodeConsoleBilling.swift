import Foundation

/// The OpenCode Zen credit balance of the user's OpenCode Console workspaces, read with their opencode.ai sign-in in
/// Coincide's browser. A Zen key can't read its balance (only the Go plan's windows, `OpenCodeUsageLimits`); the
/// Console shows it in its billing drawer ("$12.40 left").
///
/// The endpoints are the ones the Console's own web app calls, found in its JavaScript (`/console/assets/…`). They are
/// undocumented and answer only the Console's session cookie (`__Host-console_session`) or a bearer token:
/// - `GET /console/api/orgs`: the member's workspaces, `[{id, name, blocked}]`.
/// - `GET /console/api/billing/drawer/status` with header `x-org-id: <workspace>`: the billing drawer for every
///   member, admin or not. Its `billing` (absent for a workspace without a billing account) holds `billingMode`
///   (`prepaid`, `credit`, …), `mode` (`pay-as-you-go` or `invoiceable`), `availableMicroCents` (what requests may
///   still spend: the balance, plus the credit limit of an invoiced workspace) and `creditLimitMicroCents`. Amounts
///   are integer micro-cents, sent as text or numbers; a dollar is 10⁸ of them.
public enum OpenCodeConsoleBilling {
    /// One workspace's billing.
    public struct Workspace: Sendable, Hashable {
        public var id: String
        public var name: String?
        /// What requests may still spend, in dollars; never below zero.
        public var available: Double
        /// An invoiced workspace's agreed credit limit, in dollars; nil for pay as you go.
        public var creditLimit: Double?

        public nonisolated init(id: String, name: String?, available: Double, creditLimit: Double?) {
            self.id = id
            self.name = name
            self.available = available
            self.creditLimit = creditLimit
        }
    }

    nonisolated static let base = URL(string: "https://opencode.ai/console")!
    /// The Console's sign-in cookie: `__Host-` on https, as opencode.ai is; the plain name on a local Console.
    nonisolated static let sessionCookies = ["__Host-console_session", "console_session"]
    nonisolated static let workspaceHeader = "x-org-id"
    /// Workspaces read at most, in the Console's order.
    nonisolated static let maxWorkspaces = 10
    nonisolated static let microCentsPerDollar = 100_000_000.0

    // MARK: Reading

    /// Reads the balance of each workspace with `cookie` (the profile's cookies for opencode.ai).
    nonisolated static func read(cookie: String?, fetch: UsageLimitsFetch, now: Date = Date()) async -> BrowserUsageOutcome {
        guard let cookie, sessionCookies.contains(where: { BrowserCookieHeader.contains(cookie, name: $0) }) else {
            return .problem(.notSignedIn)
        }
        func get(_ path: String, workspace: String? = nil) async -> Result<JSONValue, BrowserUsageProblemError> {
            let headers = workspace.map { [workspaceHeader: $0] } ?? [:]
            return await BrowserUsageHTTP.json(
                BrowserUsageHTTP.get(base.appendingPathComponent(path), cookie: cookie, headers: headers), fetch: fetch)
        }
        let list: JSONValue
        switch await get("api/orgs") {
        case .success(let json): list = json
        // The list doubles as the sign-in check: a refused cookie answers 401.
        case .failure(let error): return .problem(error.problem)
        }
        guard let candidates = workspaces(list) else { return .problem(.unrecognized) }
        guard !candidates.isEmpty else { return .problem(.noBilling) }
        var read: [Workspace] = []
        var forbidden = false
        for candidate in candidates.prefix(maxWorkspaces) {
            switch await get("api/billing/drawer/status", workspace: candidate.id) {
            case .success(let status):
                switch billing(status, id: candidate.id, name: candidate.name) {
                case .workspace(let workspace)?: read.append(workspace)
                // A workspace without a billing account has no balance to show.
                case .noBilling?: break
                case nil: return .problem(.unrecognized)
                }
            case .failure(let error) where error.problem == .forbidden || error.problem == .unavailable(404):
                forbidden = true
            case .failure(let error):
                return .problem(error.problem)
            }
        }
        guard !read.isEmpty else { return .problem(forbidden ? .forbidden : .noBilling) }
        return .reading(reading(read, checkedAt: now))
    }

    // MARK: Parsing

    /// The workspaces in an `api/orgs` answer, in its order; nil when it isn't a list of workspaces.
    nonisolated static func workspaces(_ json: JSONValue) -> [(id: String, name: String?)]? {
        guard let list = json.array else { return nil }
        var result: [(id: String, name: String?)] = []
        for workspace in list {
            guard workspace.object != nil else { return nil }
            // The ID goes into a header: only the Console's plain IDs.
            guard let id = BrowserUsageHTTP.text(workspace["id"]), id.count <= 64,
                id.hasPrefix("wrk_") || id.hasPrefix("org_"),
                id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
            else { return nil }
            result.append((id, BrowserUsageHTTP.text(workspace["name"])))
        }
        return result
    }

    /// What a workspace's `drawer/status` says of its billing.
    enum Billing: Sendable, Hashable {
        case workspace(Workspace)
        /// The workspace has no billing account.
        case noBilling
    }

    /// The billing of a `drawer/status` answer; nil when the answer isn't a drawer status or its amounts aren't amounts.
    nonisolated static func billing(_ status: JSONValue, id: String, name: String?) -> Billing? {
        guard status.object != nil else { return nil }
        guard let billing = status["billing"], !billing.isNull else { return .noBilling }
        guard billing.object != nil, let available = microCents(billing["availableMicroCents"]) else { return nil }
        var creditLimit: Double?
        if let limit = billing["creditLimitMicroCents"], !limit.isNull {
            guard let value = microCents(limit) else { return nil }
            creditLimit = value
        }
        // An invoiced workspace measures against its agreed limit; a prepaid one has only its balance.
        let invoiced = billing["mode"]?.string == "invoiceable" && (creditLimit ?? 0) > 0
        return .workspace(
            Workspace(
                id: id, name: name, available: max(0, available) / microCentsPerDollar,
                creditLimit: invoiced ? creditLimit.map { $0 / microCentsPerDollar } : nil))
    }

    /// An amount in micro-cents: a whole number, sent as a number or as its digits.
    nonisolated static func microCents(_ value: JSONValue?) -> Double? {
        if let number = value?.number, number.isFinite, number.rounded() == number { return number }
        guard var text = value?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.count <= 24 else { return nil }
        let negative = text.hasPrefix("-")
        if negative { text.removeFirst() }
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Double(text) else { return nil }
        return negative ? -number : number
    }

    // MARK: Figures

    /// The figures the workspaces add to an OpenCode account: each one's balance, named by its workspace when there
    /// are several. A prepaid balance has no total, so Coincide measures it against the highest it has seen; an
    /// invoiced workspace's measures against its credit limit.
    public nonisolated static func figures(_ workspaces: [Workspace]) -> [UsageFigure] {
        workspaces.map { workspace in
            UsageFigure(
                id: "zen_balance_" + workspace.id, label: String(localized: "Zen balance"), unit: .currency("USD"),
                limit: workspace.creditLimit, remaining: workspace.available,
                detail: workspaces.count > 1 ? workspace.name : nil)
        }
    }

    nonisolated static func reading(_ workspaces: [Workspace], checkedAt: Date) -> BrowserUsageReading {
        let names = workspaces.compactMap(\.name)
        return BrowserUsageReading(
            source: .openCodeConsole, checkedAt: checkedAt, figures: figures(workspaces),
            identity: names.isEmpty ? nil : names.formatted(.list(type: .and)))
    }
}
