import Foundation

/// Codex details from chatgpt.com, read with the user's ChatGPT sign-in in Coincide's browser: what the Codex CLI's
/// rate-limit report leaves out. The endpoints and page are the ones the open-source CodexBar reads
/// (github.com/steipete/CodexBar, `OpenAIDashboardFetcher`, `CodexOAuthUsageFetcher`, docs/codex.md). They are
/// undocumented:
/// - `GET /api/auth/session`: who is signed in (`user.email`) and an `accessToken` for the backend; `{}` when signed out.
/// - `GET /backend-api/wham/usage`: the plan, credits (`credits.balance`), the account ID and the member's credit
///   limit (`individual_limit`, at the top, under `rate_limit` or under `spend_control`).
/// - `GET /backend-api/accounts/{id}/spend-controls/current-user/monthly-usage`: a workspace member's monthly credit
///   limit (`effective_monthly_limit.limit`) and this month's use (`current_month_usage`), read only for workspace
///   plans whose usage names a spend control but no limit.
/// - `GET /backend-api/accounts/{id}/remaining_balance`: a workspace's shared credit balance, read only when the usage
///   says there are credits but gives no balance.
/// - The Codex analytics page (`/codex/cloud/settings/analytics`), whose "Credits usage history" table lists each
///   day's credits by service. There is no JSON endpoint for it that CodexBar knows of, so the app reads the table
///   from the page in a hidden browser (`historyScript`) and `history(rows:)` reads the rows.
///
/// No endpoint or page lists credit purchases, so the credits balance still measures against the highest balance
/// Coincide has seen (`UsageBalanceMarks`).
public enum ChatGPTCodexBilling {
    /// A credit limit: credits used of it, and when it starts over when known.
    public struct CreditLimit: Sendable, Hashable {
        public var used: Double
        public var limit: Double
        public var resetsAt: Date?

        public nonisolated init(used: Double, limit: Double, resetsAt: Date? = nil) {
            self.used = used
            self.limit = limit
            self.resetsAt = resetsAt
        }
    }

    /// What the backend said.
    public struct Report: Sendable, Hashable {
        public var email: String?
        public var accountID: String?
        public var plan: String?
        public var credits: UsageCredits?
        /// The member's credit limit.
        public var creditLimit: CreditLimit?
        /// A workspace member's monthly credit limit, from its spend controls.
        public var monthlyLimit: CreditLimit?
        public var checkedAt: Date

        public nonisolated init(email: String? = nil, accountID: String? = nil, plan: String? = nil, checkedAt: Date) {
            self.email = email
            self.accountID = accountID
            self.plan = plan
            self.checkedAt = checkedAt
        }
    }

    /// One row of the credits usage history: a day's credits for one service ("CLI", "GitHub Code Review").
    public struct CreditUse: Sendable, Hashable {
        public var day: Date
        public var service: String
        public var credits: Double

        public nonisolated init(day: Date, service: String, credits: Double) {
            self.day = day
            self.service = service
            self.credits = credits
        }
    }

    /// What reading the analytics page found.
    public enum HistoryOutcome: Sendable, Hashable {
        case rows([[String]])
        case problem(BrowserUsageProblem)
    }

    nonisolated static let base = URL(string: "https://chatgpt.com")!
    /// Plans of one person, which have no workspace spend controls.
    nonisolated static let personalPlans: Set<String> = ["guest", "free", "go", "plus", "pro"]

    // MARK: Reading

    /// Reads the backend with `cookie` (the profile's cookies for chatgpt.com).
    nonisolated static func read(cookie: String?, fetch: UsageLimitsFetch, now: Date = Date()) async -> BrowserUsageOutcome {
        guard let cookie else { return .problem(.notSignedIn) }
        let session: JSONValue
        switch await BrowserUsageHTTP.json(BrowserUsageHTTP.get(base.appendingPathComponent("api/auth/session"), cookie: cookie), fetch: fetch) {
        case .success(let json): session = json
        // A 403 here is a challenge page in front of the site, not the account's billing.
        case .failure(let error): return .problem(error.problem == .forbidden ? .unavailable(403) : error.problem)
        }
        // Signed out, the session is `{}`.
        guard let token = BrowserUsageHTTP.text(session["accessToken"]),
            token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { return .problem(session.object != nil ? .notSignedIn : .unrecognized) }
        let email = BrowserUsageHTTP.text(session.at("user.email"))
        var headers = ["Authorization": "Bearer \(token)"]

        let usage: JSONValue
        switch await BrowserUsageHTTP.json(
            BrowserUsageHTTP.get(base.appendingPathComponent("backend-api/wham/usage"), cookie: cookie, headers: headers), fetch: fetch)
        {
        case .success(let json): usage = json
        case .failure(let error): return .problem(error.problem == .forbidden ? .sessionExpired : error.problem)
        }
        guard var report = report(usage: usage, email: email, now: now) else { return .problem(.unrecognized) }

        // The optional reads below only add to the report; their failures leave it as it is.
        if let accountID = report.accountID, let encoded = pathComponent(accountID) {
            headers["ChatGPT-Account-Id"] = accountID
            let account = base.appendingPathComponent("backend-api/accounts").appendingPathComponent(encoded)
            if report.creditLimit == nil, usage["spend_control"] != nil || usage["spendControl"] != nil,
                !personalPlans.contains(report.plan ?? "")
            {
                let url = account.appendingPathComponent("spend-controls/current-user/monthly-usage")
                if case .success(let json) = await BrowserUsageHTTP.json(BrowserUsageHTTP.get(url, cookie: cookie, headers: headers), fetch: fetch) {
                    report.monthlyLimit = monthlyLimit(json)
                }
            }
            if let credits = report.credits, credits.hasCredits, !credits.unlimited, credits.balance == nil {
                let url = account.appendingPathComponent("remaining_balance")
                if case .success(let json) = await BrowserUsageHTTP.json(BrowserUsageHTTP.get(url, cookie: cookie, headers: headers), fetch: fetch),
                    let balance = BrowserUsageHTTP.number(json["balance"])
                {
                    report.credits?.balance = plainNumber(max(0, balance))
                }
            }
        }
        return .reading(reading(report))
    }

    // MARK: Parsing

    /// The plan, credits and credit limit of a `wham/usage` answer; nil when it isn't an object.
    nonisolated static func report(usage: JSONValue, email: String?, now: Date) -> Report? {
        guard usage.object != nil else { return nil }
        var report = Report(
            email: email, accountID: BrowserUsageHTTP.text(usage["account_id"] ?? usage["accountId"]),
            plan: BrowserUsageHTTP.text(usage["plan_type"]).flatMap(CodexUsageLimits.plan), checkedAt: now)
        if let credits = usage["credits"], credits.object != nil {
            report.credits = UsageCredits(
                hasCredits: credits["has_credits"]?.bool ?? false, unlimited: credits["unlimited"]?.bool ?? false,
                balance: BrowserUsageHTTP.number(credits["balance"]).map(plainNumber))
        }
        // As CodexBar takes it: the top level first, then the rate limit's, then the spend control's.
        let candidates = [
            usage["individual_limit"], usage["individualLimit"], usage.at("rate_limit.individual_limit"),
            usage.at("spend_control.individual_limit"), usage.at("spendControl.individualLimit"),
        ]
        for candidate in candidates {
            guard let candidate, candidate.object != nil, let limit = BrowserUsageHTTP.number(candidate["limit"]), limit > 0 else { continue }
            let used = BrowserUsageHTTP.number(candidate["used"]) ?? 0
            let reset = BrowserUsageHTTP.number(candidate["resets_at"] ?? candidate["reset_at"] ?? candidate["resetsAt"])
            report.creditLimit = CreditLimit(used: max(0, used), limit: limit, resetsAt: CodexUsageLimits.date(fromEpochSeconds: reset))
            break
        }
        return report
    }

    /// A workspace member's monthly credit limit and this month's use; nil when there is no limit or it isn't enforced.
    nonisolated static func monthlyLimit(_ json: JSONValue) -> CreditLimit? {
        guard let limit = BrowserUsageHTTP.number(json.at("effective_monthly_limit.limit")), limit > 0 else { return nil }
        let mode = json.at("effective_monthly_limit.enforcement_mode")?.string?.lowercased()
        if let mode, ["none", "off", "disabled", "no_limit"].contains(mode) { return nil }
        return CreditLimit(used: max(0, BrowserUsageHTTP.number(json["current_month_usage"]) ?? 0), limit: limit)
    }

    /// A balance as Codex writes it, which `Double(_:)` reads back in any locale: "572.99", "40120".
    nonisolated static func plainNumber(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    /// The account ID as one path component, or nil when it can't be one.
    nonisolated static func pathComponent(_ id: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.subtract(CharacterSet(charactersIn: "/?#%"))
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty else { return nil }
        return encoded
    }

    // MARK: Figures

    /// The figures a report adds to the Codex account. `UsageInsights` adds only those the Codex CLI didn't report.
    public nonisolated static func figures(_ report: Report) -> [UsageFigure] {
        var figures: [UsageFigure] = []
        if let limit = report.creditLimit {
            figures.append(
                UsageFigure(
                    id: "individual", label: String(localized: "Credit limit"), unit: .credits, used: limit.used, limit: limit.limit,
                    resetsAt: limit.resetsAt))
        }
        if let monthly = report.monthlyLimit {
            figures.append(
                UsageFigure(
                    id: "monthly_credit_limit", label: String(localized: "Monthly credit limit"), unit: .credits, used: monthly.used,
                    limit: monthly.limit))
        }
        return figures
    }

    nonisolated static func reading(_ report: Report) -> BrowserUsageReading {
        BrowserUsageReading(
            source: .chatGPT, checkedAt: report.checkedAt, figures: figures(report), credits: report.credits, identity: report.email,
            email: report.email)
    }

    // MARK: Credit history

    /// How many days of history the history figure sums.
    public nonisolated static let historyDays = 30

    /// The rows of the "Credits usage history" table: a date ("Dec 18, 2025"), the service, and the credits
    /// ("397.205 credits"). Rows that don't read are skipped. Newest first.
    public nonisolated static func history(rows: [[String]]) -> [CreditUse] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy"
        return rows.compactMap { row -> CreditUse? in
            guard row.count >= 3, let day = formatter.date(from: row[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                let credits = creditAmount(row[2])
            else { return nil }
            return CreditUse(day: day, service: row[1].trimmingCharacters(in: .whitespacesAndNewlines), credits: credits)
        }
        .sorted { $0.day > $1.day }
    }

    /// The number in a credits cell: "397.205 credits", "1,250 credits", "1.250,5 Credits".
    nonisolated static func creditAmount(_ text: String) -> Double? {
        let spaces = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{00A0}\u{202F}"))
        guard let match = text.firstMatch(of: /[0-9][0-9.,\u{00A0}\u{202F} ]*/) else { return nil }
        var token = String(match.output).unicodeScalars.filter { !spaces.contains($0) }.map(String.init).joined()
        while let last = token.last, last == "." || last == "," { token.removeLast() }
        let hasComma = token.contains(","), hasDot = token.contains(".")
        if hasComma && hasDot {
            // The later mark is the decimal one.
            let decimal: Character = token.lastIndex(of: ",")! > token.lastIndex(of: ".")! ? "," : "."
            token = token.filter { $0 != (decimal == "," ? "." : ",") }.replacingOccurrences(of: ",", with: ".")
        } else if hasComma {
            // "1,250" groups thousands; "12,5" is a decimal comma.
            token = token.contains(/^\d{1,3}(,\d{3})+$/) ? token.replacingOccurrences(of: ",", with: "") : token.replacingOccurrences(of: ",", with: ".")
        }
        return Double(token).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// Credits used over the last `historyDays` days (UTC days, as the table dates them), as a figure.
    public nonisolated static func historyFigure(_ uses: [CreditUse], now: Date) -> UsageFigure {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let since = utc.date(byAdding: .day, value: -(historyDays - 1), to: utc.startOfDay(for: now)) ?? .distantPast
        let total = uses.filter { $0.day >= since && $0.day <= now }.reduce(0) { $0 + $1.credits }
        return UsageFigure(
            id: "credit_history", label: String(localized: "Credits used"), unit: .credits, used: total,
            detail: String(localized: "Last \(historyDays) days, from chatgpt.com"))
    }

    /// Reads the "Credits usage history" table on the analytics page. Returns `{state, rows}`: `signedOut` when the page
    /// asks to sign in, `rows` with the table's cells once it has rows, `empty` when the table is there without any,
    /// `waiting` while the page loads. It scrolls the table into view once, since the page renders it lazily. It only
    /// reads the page; the rows go back to Coincide and nowhere else.
    public nonisolated static let historyScript = """
        (() => {
          const text = (el) => (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim();
          const path = location.pathname || '';
          const signedOut = location.hostname.indexOf('chatgpt.com') < 0 || path.startsWith('/auth')
            || !!document.querySelector('[data-testid="login-button"], form[action*="login"]');
          if (signedOut) return { state: 'signedOut', rows: [] };
          const heading = Array.from(document.querySelectorAll('h1,h2,h3,h4'))
            .find((h) => text(h).toLowerCase() === 'credits usage history');
          if (!heading) {
            if (!window.__coincideScrolled && document.readyState === 'complete') {
              window.__coincideScrolled = true;
              window.scrollTo(0, document.documentElement.scrollHeight);
            }
            return { state: 'waiting', rows: [] };
          }
          const scope = heading.closest('section') || heading.parentElement || document;
          const table = scope.querySelector('table') || scope;
          const rows = Array.from(table.querySelectorAll('tbody tr'))
            .map((tr) => Array.from(tr.querySelectorAll('td')).map(text))
            .filter((cells) => cells.length >= 3);
          if (rows.length === 0 && !window.__coincideScrolledToTable) {
            window.__coincideScrolledToTable = true;
            heading.scrollIntoView({ block: 'start' });
            return { state: 'waiting', rows: [] };
          }
          return { state: rows.length > 0 ? 'rows' : 'empty', rows };
        })()
        """
}
