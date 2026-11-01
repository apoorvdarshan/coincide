import Foundation
import Testing

@testable import CoincideKit

/// Reading chatgpt.com and the Claude Console with the browser sign-in, against recorded-shape synthetic answers (the
/// shapes CodexBar's tests and sources use; no real account data). Nothing here reaches the network.
struct BrowserUsageTests {
    /// 13 October 2026, 00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_849_600)

    final class Log: @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        private let lock = NSLock()
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        var paths: [String] { lock.withLock { requests.map { $0.url!.path } } }
    }

    private static func respond(_ request: URLRequest, _ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }

    /// A fetch that answers by path, logging each request.
    private static func fetch(_ log: Log, _ answers: [String: (Int, String)]) -> UsageLimitsFetch {
        { request in
            log.add(request)
            let answer = answers[request.url!.path] ?? (404, "{}")
            return respond(request, answer.0, answer.1)
        }
    }

    // MARK: Cookies

    @Test func theCookieHeaderHoldsOnlyTheSitesUnexpiredCookies() throws {
        func cookie(_ name: String, _ domain: String, expires: Date? = nil) -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v-\(name)", .domain: domain, .path: "/"]
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)!
        }
        let cookies = [
            cookie("sessionKey", "platform.claude.com"), cookie("shared", ".claude.com"), cookie("chat", "claude.ai"),
            cookie("old", "platform.claude.com", expires: now.addingTimeInterval(-1)), cookie("evil", "notclaude.com"),
        ]
        let header = try #require(BrowserCookieHeader.make(cookies, host: "platform.claude.com", now: now))
        let names = Set(header.split(separator: ";").map { $0.split(separator: "=")[0].trimmingCharacters(in: .whitespaces) })
        #expect(names == ["sessionKey", "shared"])
        #expect(BrowserCookieHeader.make(cookies, host: "chatgpt.com", now: now) == nil)
        #expect(BrowserCookieHeader.contains("a=1; sessionKey=2", name: "sessionKey"))
        #expect(BrowserCookieHeader.contains("__Secure-next-auth.session-token.0=x", name: "__Secure-next-auth.session-token"))
        #expect(!BrowserCookieHeader.contains("notsessionKey=1", name: "sessionKey"))
    }

    // MARK: Claude Console

    private static let chatOrganization = "11111111-1111-4111-8111-111111111111"
    private static let apiOrganization = "22222222-2222-4222-8222-222222222222"
    private static let otherAPIOrganization = "33333333-3333-4333-8333-333333333333"
    private static let organizations = """
        [{"uuid":"\(chatOrganization)","name":"Synthetic Chat Organization","capabilities":["chat","claude_max"]},
         {"uuid":"\(apiOrganization)","name":"Synthetic API Org","capabilities":["api","api_individual"]}]
        """
    private static let credits = """
        {"amount":18725,"currency":"USD","balance":{"money":null,"credits":{"amount_minor":18725,"exponent":2}},
         "tranches":[{"remaining_amount_minor_units":6250,"currency":"USD","expires_at":"2027-05-01T00:00:00Z",
           "granted_amount_minor_units":10000,"program_id":"api_credits","name":null,"id":"fixture-purchase"}],
         "promo_tranches":[{"remaining_amount_minor_units":12475,"currency":"USD","expires_at":"2026-10-28T00:00:00Z",
           "granted_amount_minor_units":20000,"program_id":"subscription_api_credit","name":"API credit (Max 20x)","id":"fixture-promo"},
           {"remaining_amount_minor_units":500,"currency":"USD","expires_at":"2026-10-01T00:00:00Z",
           "granted_amount_minor_units":500,"program_id":"promo","name":"Expired promo","id":"fixture-expired"}]}
        """

    private func consoleAnswers(credits: (Int, String) = (200, credits), spend: (Int, String) = (200, #"{"amount":4321}"#))
        -> [String: (Int, String)]
    {
        [
            "/api/organizations": (200, Self.organizations),
            "/api/organizations/\(Self.apiOrganization)/prepaid/credits": credits,
            "/api/organizations/\(Self.apiOrganization)/current_spend": spend,
        ]
    }

    @Test func theConsoleBalanceMeasuresAgainstItsUnexpiredGrants() async throws {
        let log = Log()
        let outcome = await ClaudeConsoleBilling.read(
            cookie: "sessionKey=sk-test; other=1", fetch: Self.fetch(log, consoleAnswers()), now: now)
        guard case .reading(let reading) = outcome else {
            Issue.record("Expected a reading, got \(outcome)")
            return
        }
        // The chat organization listed first is never asked for billing.
        #expect(
            log.paths == [
                "/api/organizations", "/api/organizations/\(Self.apiOrganization)/prepaid/credits",
                "/api/organizations/\(Self.apiOrganization)/current_spend",
            ])
        // Every request is a GET to platform.claude.com with the cookie in its header, never in the URL.
        #expect(log.requests.allSatisfy { $0.httpMethod == "GET" && $0.url!.host == "platform.claude.com" })
        #expect(log.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "sessionKey=sk-test; other=1" })
        #expect(log.requests.allSatisfy { !$0.url!.absoluteString.contains("sk-test") })
        #expect(reading.identity == "Synthetic API Org")
        let balance = try #require(reading.figures.first { $0.id == "console_balance" })
        #expect(balance.remaining == 187.25)
        // Bought $100 and given $200; the expired grant is left out.
        #expect(balance.limit == 300)
        #expect(balance.unit == .currency("USD"))
        #expect(balance.detail == "Synthetic API Org")
        let grants = reading.figures.filter { $0.id.hasPrefix("console_grant_") }
        #expect(grants.map(\.label) == ["API credit (Max 20x)", "Purchased credit"])
        #expect(grants[0].used == 75.25 && grants[0].limit == 200)
        #expect(grants[0].expiresAt == ClaudeUsageLimits.date(fromISO: "2026-10-28T00:00:00Z"))
        #expect(reading.figures.first { $0.id == "console_spend" }?.used == 43.21)
    }

    @Test func consoleAmountsUseTheReportedExponentAndASingleGrantCarriesItsExpiry() throws {
        let json = try #require(
            JSONValue.parse(
                #"{"amount":187250,"currency":"EUR","balance":{"credits":{"exponent":3}},"promo_tranches":[],"#
                    + #""tranches":[{"granted_amount_minor_units":200000,"remaining_amount_minor_units":187250,"expires_at":null}]}"#))
        let report = try #require(ClaudeConsoleBilling.report(json, organization: nil, now: now))
        #expect(report.balance == 187.25 && report.currency == "EUR")
        let figures = ClaudeConsoleBilling.figures(report)
        #expect(figures.map(\.id) == ["console_balance"])
        #expect(figures[0].limit == 200 && figures[0].expiresAt == nil)
        // Without grants the balance is bare, so Coincide's highest-seen mark measures it.
        let bareJSON = try #require(JSONValue.parse(#"{"amount":500}"#))
        let bare = try #require(ClaudeConsoleBilling.report(bareJSON, organization: nil, now: now))
        #expect(ClaudeConsoleBilling.figures(bare)[0].limit == nil)
        #expect(UsageBalanceMarks.isBareBalance(ClaudeConsoleBilling.figures(bare)[0]))
    }

    @Test func consoleFailuresSayWhy() async {
        func read(_ answers: [String: (Int, String)], cookie: String? = "sessionKey=x") async -> BrowserUsageOutcome {
            await ClaudeConsoleBilling.read(cookie: cookie, fetch: Self.fetch(Log(), answers), now: now)
        }
        // No sign-in cookie: nothing is sent.
        let log = Log()
        #expect(await ClaudeConsoleBilling.read(cookie: "other=1", fetch: Self.fetch(log, [:]), now: now) == .problem(.notSignedIn))
        #expect(await ClaudeConsoleBilling.read(cookie: nil, fetch: Self.fetch(log, [:]), now: now) == .problem(.notSignedIn))
        #expect(log.requests.isEmpty)
        // A refused cookie answers 401 or 403 on the organization list.
        #expect(await read(["/api/organizations": (401, "{}")]) == .problem(.sessionExpired))
        #expect(await read(["/api/organizations": (403, "{}")]) == .problem(.sessionExpired))
        #expect(await read(["/api/organizations": (302, "")]) == .problem(.notSignedIn))
        #expect(await read(["/api/organizations": (429, "")]) == .problem(.rateLimited))
        #expect(await read(["/api/organizations": (503, "")]) == .problem(.unavailable(503)))
        // A challenge page instead of JSON.
        #expect(await read(["/api/organizations": (200, "<html>Just a moment…</html>")]) == .problem(.unrecognized))
        #expect(
            await read(["/api/organizations": (200, #"[{"uuid":"c","capabilities":["chat"]}]"#)]) == .problem(.noAPIOrganization))
        // A member without billing access everywhere.
        #expect(await read(consoleAnswers(credits: (403, "{}"))) == .problem(.forbidden))
        // A balance in a shape Coincide doesn't know.
        #expect(await read(consoleAnswers(credits: (200, #"{"amount":"lots"}"#))) == .problem(.unrecognized))
        let offline = await ClaudeConsoleBilling.read(cookie: "sessionKey=x", fetch: { _ in throw URLError(.notConnectedToInternet) }, now: now)
        #expect(offline == .problem(.offline))
    }

    @Test func aForbiddenOrganizationFallsThroughAndSpendIsOptional() async throws {
        let log = Log()
        let organizations = """
            [{"uuid":"\(Self.apiOrganization)","name":"Member Org","capabilities":["api"]},
             {"uuid":"\(Self.otherAPIOrganization)","name":"Owner Org","capabilities":["api"]}]
            """
        let outcome = await ClaudeConsoleBilling.read(
            cookie: "sessionKey=x",
            fetch: Self.fetch(
                log,
                [
                    "/api/organizations": (200, organizations),
                    "/api/organizations/\(Self.apiOrganization)/prepaid/credits": (403, "{}"),
                    "/api/organizations/\(Self.otherAPIOrganization)/prepaid/credits": (200, Self.credits),
                    "/api/organizations/\(Self.otherAPIOrganization)/current_spend": (500, ""),
                ]), now: now)
        guard case .reading(let reading) = outcome else {
            Issue.record("Expected a reading, got \(outcome)")
            return
        }
        #expect(reading.identity == "Owner Org")
        #expect(!reading.figures.contains { $0.id == "console_spend" })
        #expect(reading.figures.first { $0.id == "console_balance" }?.remaining == 187.25)
    }

    // MARK: OpenCode Console

    private static let workspace = "wrk_01SYNTHETICWORKSPACE000001"
    private static let otherWorkspace = "wrk_01SYNTHETICWORKSPACE000002"
    private static let openCodeCookie = "__Host-console_session=cs-test; other=1"

    /// The billing drawer's answer, in the shape the Console's web app decodes (`BillingStatus` inside it).
    private static func drawer(available: String = #""1240000000""#, extra: String = "") -> String {
        """
        {"admins":[{"name":"Synthetic Admin","avatarUrl":null}],"hasPaymentMethod":true,
         "billing":{"billingMode":"prepaid","mode":"pay-as-you-go","balanceMicroCents":\(available),"creditLimitMicroCents":null,
           "availableMicroCents":\(available),"canPurchaseCredits":true,"canEnableAutoRecharge":true\(extra)},
         "autoRecharge":null,"funded":true,"overdue":false}
        """
    }

    /// A fetch that answers the workspace list, and each workspace's drawer by its `x-org-id` header.
    private static func openCodeFetch(_ log: Log, orgs: (Int, String), drawers: [String: (Int, String)]) -> UsageLimitsFetch {
        { request in
            log.add(request)
            switch request.url!.path {
            case "/console/api/orgs": return respond(request, orgs.0, orgs.1)
            case "/console/api/billing/drawer/status":
                let answer = drawers[request.value(forHTTPHeaderField: "x-org-id") ?? ""] ?? (403, #"{"_tag":"Forbidden"}"#)
                return respond(request, answer.0, answer.1)
            default: return respond(request, 404, "{}")
            }
        }
    }

    private static let oneWorkspace = #"[{"id":"\#(workspace)","name":"Default","avatarUrl":null,"blocked":false}]"#

    @Test func theZenBalanceIsWhatTheBillingDrawerSaysIsLeft() async throws {
        let log = Log()
        let outcome = await OpenCodeConsoleBilling.read(
            cookie: Self.openCodeCookie,
            fetch: Self.openCodeFetch(log, orgs: (200, Self.oneWorkspace), drawers: [Self.workspace: (200, Self.drawer())]), now: now)
        guard case .reading(let reading) = outcome else {
            Issue.record("Expected a reading, got \(outcome)")
            return
        }
        #expect(log.paths == ["/console/api/orgs", "/console/api/billing/drawer/status"])
        // Every request is a GET to opencode.ai with the cookie in its header, never in the URL; the workspace goes in
        // the Console's own header.
        #expect(log.requests.allSatisfy { $0.httpMethod == "GET" && $0.url!.host == "opencode.ai" })
        #expect(log.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == Self.openCodeCookie })
        #expect(log.requests.allSatisfy { !$0.url!.absoluteString.contains("cs-test") && $0.url!.query == nil })
        #expect(log.requests[1].value(forHTTPHeaderField: "x-org-id") == Self.workspace)
        #expect(reading.source == .openCodeConsole)
        #expect(reading.identity == "Default")
        let balance = try #require(reading.figures.first)
        #expect(reading.figures.count == 1)
        #expect(balance.id == "zen_balance_" + Self.workspace)
        #expect(balance.remaining == 12.4)
        #expect(balance.unit == .currency("USD"))
        #expect(balance.detail == nil)
        // A prepaid balance has no total, so Coincide's highest-seen mark measures it.
        #expect(UsageBalanceMarks.isBareBalance(balance))
    }

    @Test func zenAmountsAreMicroCentsAsTextOrNumbers() throws {
        func workspace(_ billing: String) -> OpenCodeConsoleBilling.Workspace? {
            guard let json = JSONValue.parse(#"{"billing":\#(billing)}"#),
                case .workspace(let workspace)? = OpenCodeConsoleBilling.billing(json, id: "wrk_1", name: nil)
            else { return nil }
            return workspace
        }
        #expect(workspace(#"{"availableMicroCents":250000000}"#)?.available == 2.5)
        #expect(workspace(#"{"availableMicroCents":"1"}"#)?.available == 0.000_000_01)
        // A balance below zero (an overshoot) has nothing left.
        #expect(workspace(#"{"availableMicroCents":"-500000000"}"#)?.available == 0)
        // An invoiced workspace measures against its credit limit.
        let invoiced = try #require(
            workspace(#"{"mode":"invoiceable","creditLimitMicroCents":"50000000000","availableMicroCents":"40000000000"}"#))
        #expect(invoiced.creditLimit == 500 && invoiced.available == 400)
        let figure = try #require(OpenCodeConsoleBilling.figures([invoiced]).first)
        #expect(figure.limit == 500 && figure.remaining == 400 && !UsageBalanceMarks.isBareBalance(figure))
        // A pay-as-you-go workspace's limit field is ignored.
        #expect(workspace(#"{"mode":"pay-as-you-go","creditLimitMicroCents":0,"availableMicroCents":"0"}"#)?.creditLimit == nil)
        // Amounts that aren't whole micro-cents aren't amounts.
        for bad in [#""12.5""#, #""lots""#, "1.5", #""""#, "null", #""1e9""#] {
            #expect(OpenCodeConsoleBilling.microCents(JSONValue.parse("[\(bad)]")?.array?.first) == nil, "\(bad)")
        }
        let none = try #require(JSONValue.parse(#"{"billing":null,"funded":false}"#))
        #expect(OpenCodeConsoleBilling.billing(none, id: "wrk_1", name: nil) == .noBilling)
        #expect(OpenCodeConsoleBilling.billing(.array([]), id: "wrk_1", name: nil) == nil)
    }

    @Test func severalWorkspacesEachShowTheirBalanceByName() async throws {
        let orgs = """
            [{"id":"\(Self.workspace)","name":"Personal","avatarUrl":null,"blocked":false},
             {"id":"\(Self.otherWorkspace)","name":"Team","avatarUrl":null,"blocked":false},
             {"id":"wrk_01SYNTHETICWORKSPACE000003","name":"No Access","avatarUrl":null,"blocked":false}]
            """
        let outcome = await OpenCodeConsoleBilling.read(
            cookie: Self.openCodeCookie,
            fetch: Self.openCodeFetch(
                Log(), orgs: (200, orgs),
                drawers: [Self.workspace: (200, Self.drawer()), Self.otherWorkspace: (200, Self.drawer(available: "1200000000"))]),
            now: now)
        guard case .reading(let reading) = outcome else {
            Issue.record("Expected a reading, got \(outcome)")
            return
        }
        // The workspace the member may not see is left out.
        #expect(reading.figures.map(\.detail) == ["Personal", "Team"])
        #expect(reading.figures.map(\.remaining) == [12.4, 12])
        #expect(Set(reading.figures.map(\.id)).count == 2)
    }

    @Test func zenFailuresSayWhy() async {
        func read(orgs: (Int, String) = (200, Self.oneWorkspace), drawer: (Int, String) = (200, Self.drawer())) async
            -> BrowserUsageOutcome
        {
            await OpenCodeConsoleBilling.read(
                cookie: "__Host-console_session=x", fetch: Self.openCodeFetch(Log(), orgs: orgs, drawers: [Self.workspace: drawer]),
                now: now)
        }
        // No sign-in cookie: nothing is sent.
        let log = Log()
        let none = Self.openCodeFetch(log, orgs: (200, Self.oneWorkspace), drawers: [:])
        #expect(await OpenCodeConsoleBilling.read(cookie: "other=1", fetch: none, now: now) == .problem(.notSignedIn))
        #expect(await OpenCodeConsoleBilling.read(cookie: nil, fetch: none, now: now) == .problem(.notSignedIn))
        #expect(log.requests.isEmpty)
        // The Console answers a refused cookie with 401.
        #expect(await read(orgs: (401, #"{"_tag":"Unauthorized"}"#)) == .problem(.sessionExpired))
        #expect(await read(orgs: (429, "")) == .problem(.rateLimited))
        #expect(await read(orgs: (503, "")) == .problem(.unavailable(503)))
        #expect(await read(orgs: (200, "<html>Just a moment…</html>")) == .problem(.unrecognized))
        // An ID that couldn't be a workspace's never goes into a header.
        #expect(await read(orgs: (200, #"[{"id":"wrk_1\r\nX: y","name":"Bad"}]"#)) == .problem(.unrecognized))
        #expect(await read(orgs: (200, "[]")) == .problem(.noBilling))
        #expect(await read(drawer: (200, #"{"billing":null,"funded":false}"#)) == .problem(.noBilling))
        #expect(await read(drawer: (403, #"{"_tag":"Forbidden"}"#)) == .problem(.forbidden))
        #expect(await read(drawer: (200, #"{"billing":{"availableMicroCents":"lots"}}"#)) == .problem(.unrecognized))
        #expect(await read(drawer: (500, "")) == .problem(.unavailable(500)))
        let offline = await OpenCodeConsoleBilling.read(
            cookie: "__Host-console_session=x", fetch: { _ in throw URLError(.notConnectedToInternet) }, now: now)
        #expect(offline == .problem(.offline))
    }

    // MARK: chatgpt.com

    private static let session = #"{"user":{"email":"me@example.com","name":"Me"},"accessToken":"at-test-token","expires":"2026-11-01"}"#

    private static func usage(plan: String, balance: String = "\"572.99\"", extra: String = "") -> String {
        """
        {"account_id":"acct-123","plan_type":"\(plan)","rate_limit":{"primary_window":{"used_percent":12,"reset_at":1791900000,"limit_window_seconds":18000}},
         "credits":{"has_credits":true,"unlimited":false,"balance":\(balance)}\(extra)}
        """
    }

    @Test func chatGPTReadsTheBackendWithTheSessionsToken() async throws {
        let log = Log()
        let usage = Self.usage(plan: "pro", extra: #","individual_limit":{"limit":"5000","used":1250.5,"reset_at":1792000000}"#)
        let outcome = await ChatGPTCodexBilling.read(
            cookie: "__Secure-next-auth.session-token=s", fetch: Self.fetch(log, ["/api/auth/session": (200, Self.session), "/backend-api/wham/usage": (200, usage)]),
            now: now)
        guard case .reading(let reading) = outcome else {
            Issue.record("Expected a reading, got \(outcome)")
            return
        }
        #expect(log.paths == ["/api/auth/session", "/backend-api/wham/usage"])
        let backend = log.requests[1]
        #expect(backend.value(forHTTPHeaderField: "Authorization") == "Bearer at-test-token")
        #expect(log.requests.allSatisfy { $0.url!.host == "chatgpt.com" && $0.httpMethod == "GET" })
        #expect(log.requests.allSatisfy { !$0.url!.absoluteString.contains("at-test-token") })
        #expect(reading.email == "me@example.com" && reading.identity == "me@example.com")
        #expect(reading.credits == UsageCredits(hasCredits: true, unlimited: false, balance: "572.99"))
        let limit = try #require(reading.figures.first { $0.id == "individual" })
        #expect(limit.used == 1250.5 && limit.limit == 5000 && limit.resetsAt == Date(timeIntervalSince1970: 1_792_000_000))
    }

    @Test func aWorkspaceReadsItsMonthlyLimitAndSharedBalance() async throws {
        let log = Log()
        let usage = Self.usage(plan: "team", balance: "null", extra: #","spend_control":{"reached":false}"#)
        let outcome = await ChatGPTCodexBilling.read(
            cookie: "c=1",
            fetch: Self.fetch(
                log,
                [
                    "/api/auth/session": (200, Self.session), "/backend-api/wham/usage": (200, usage),
                    "/backend-api/accounts/acct-123/spend-controls/current-user/monthly-usage":
                        (200, #"{"current_month_usage":"320.5","effective_monthly_limit":{"limit":1000,"enforcement_mode":"hard"}}"#),
                    "/backend-api/accounts/acct-123/remaining_balance": (200, #"{"balance":"9000"}"#),
                ]), now: now)
        guard case .reading(let reading) = outcome else {
            Issue.record("Expected a reading, got \(outcome)")
            return
        }
        #expect(log.requests.dropFirst(2).allSatisfy { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-123" })
        let monthly = try #require(reading.figures.first { $0.id == "monthly_credit_limit" })
        #expect(monthly.used == 320.5 && monthly.limit == 1000)
        #expect(reading.credits?.balance == "9000")
    }

    @Test func personalPlansSkipWorkspaceReadsAndAnUnenforcedLimitIsNone() async {
        let log = Log()
        _ = await ChatGPTCodexBilling.read(
            cookie: "c=1",
            fetch: Self.fetch(
                log, ["/api/auth/session": (200, Self.session), "/backend-api/wham/usage": (200, Self.usage(plan: "plus", extra: #","spend_control":{}"#))]),
            now: now)
        #expect(log.paths == ["/api/auth/session", "/backend-api/wham/usage"])
        let off = JSONValue.parse(#"{"current_month_usage":5,"effective_monthly_limit":{"limit":100,"enforcement_mode":"none"}}"#)!
        #expect(ChatGPTCodexBilling.monthlyLimit(off) == nil)
    }

    @Test func chatGPTFailuresSayWhy() async {
        func read(_ answers: [String: (Int, String)], cookie: String? = "c=1") async -> BrowserUsageOutcome {
            await ChatGPTCodexBilling.read(cookie: cookie, fetch: Self.fetch(Log(), answers), now: now)
        }
        #expect(await read([:], cookie: nil) == .problem(.notSignedIn))
        // Signed out, the session is empty.
        #expect(await read(["/api/auth/session": (200, "{}")]) == .problem(.notSignedIn))
        #expect(await read(["/api/auth/session": (403, "<html>challenge</html>")]) == .problem(.unavailable(403)))
        #expect(await read(["/api/auth/session": (200, "<html>")]) == .problem(.unrecognized))
        #expect(await read(["/api/auth/session": (200, Self.session), "/backend-api/wham/usage": (401, "{}")]) == .problem(.sessionExpired))
        #expect(await read(["/api/auth/session": (200, Self.session), "/backend-api/wham/usage": (200, "[]")]) == .problem(.unrecognized))
    }

    // MARK: Credit history

    @Test func historyRowsReadTheirDatesAndAmounts() {
        let rows = [
            ["Oct 12, 2026", "CLI", "397.205 credits"],
            ["Oct 1, 2026", "GitHub Code Review", "1,250 credits"],
            ["Sep 1, 2026", "CLI", "12,5 Credits"],
            ["Aug 1, 2026", "CLI", "1.250,75 credits"],
            ["Yesterday", "CLI", "5 credits"],
            ["Oct 2, 2026", "CLI"],
        ]
        let uses = ChatGPTCodexBilling.history(rows: rows)
        #expect(uses.map(\.credits) == [397.205, 1250, 12.5, 1250.75])
        #expect(uses.first?.service == "CLI")
        let figure = ChatGPTCodexBilling.historyFigure(uses, now: now)
        // The last 30 days: 12 and 1 October, not September.
        #expect(figure.used == 397.205 + 1250)
        #expect(figure.id == "credit_history" && figure.unit == .credits && figure.limit == nil)
    }

    // MARK: Accounts and merging

    @Test func chatGPTDetailsGoOnlyToTheCodexAccountOfTheSameEmail() {
        let main = ProviderAccount.defaultAccount(for: .codex)
        let work = ProviderAccount(id: "work", provider: .codex, name: "Work")
        let key = ProviderAccount(id: "key", provider: .codex, name: "Key", auth: .apiKey)
        let accounts: [(account: ProviderAccount, label: String?)] = [
            (main, "me@example.com (ChatGPT Pro)"), (work, "me@work.example (ChatGPT Team)"), (key, "OpenAI API key"),
        ]
        #expect(UsageInsights.browserTargets(.chatGPT, accounts: accounts, email: "ME@example.com") == [main.id])
        #expect(UsageInsights.browserTargets(.chatGPT, accounts: accounts, email: "someone@else.example").isEmpty)
        // Labels without an email: one ChatGPT account is taken to be it, two are ambiguous.
        #expect(UsageInsights.browserTargets(.chatGPT, accounts: [(main, "ChatGPT Pro"), (key, nil)], email: "me@example.com") == [main.id])
        #expect(UsageInsights.browserTargets(.chatGPT, accounts: [(main, "ChatGPT Pro"), (work, nil)], email: "me@example.com").isEmpty)
    }

    @Test func consoleDetailsGoToAnthropicKeyAccountsElseTheDefault() {
        let main = ProviderAccount.defaultAccount(for: .claude)
        let key = ProviderAccount(id: "key", provider: .claude, name: "API", auth: .apiKey)
        #expect(UsageInsights.browserTargets(.claudeConsole, accounts: [(main, nil), (key, nil)], email: nil) == [key.id])
        #expect(UsageInsights.browserTargets(.claudeConsole, accounts: [(main, nil)], email: nil) == [main.id])
    }

    @Test func zenDetailsGoToTheDefaultOpenCodeAccountAndZenKeys() {
        let main = ProviderAccount.defaultAccount(for: .opencode)
        let zen = ProviderAccount(id: "zen", provider: .opencode, name: "Zen", auth: .apiKey, apiKeyVariable: "OPENCODE_API_KEY")
        let router = ProviderAccount(id: "router", provider: .opencode, name: "Router", auth: .apiKey, apiKeyVariable: "OPENROUTER_API_KEY")
        let accounts: [(account: ProviderAccount, label: String?)] = [(main, nil), (zen, nil), (router, nil)]
        #expect(UsageInsights.browserTargets(.openCodeConsole, accounts: accounts, email: nil) == [main.id, zen.id])
        #expect(UsageInsights.browserTargets(.openCodeConsole, accounts: [(router, nil)], email: nil).isEmpty)
    }

    @Test func aZenReadingKeepsTheGoWindowsAndAnswersTheKeysNote() throws {
        let go = UsageLimitWindow(id: "go_weekly", kind: .weekly, label: "Go · Weekly", usedPercent: 20, resetsAt: now.addingTimeInterval(86_400))
        let agent = UsageLimits(windows: [go], checkedAt: now, notes: APIKeyUsage.notes(for: .openCodeZen))
        let reading = OpenCodeConsoleBilling.reading(
            [OpenCodeConsoleBilling.Workspace(id: Self.workspace, name: "Default", available: 12.4, creditLimit: nil)], checkedAt: now)
        let merged = try #require(
            UsageInsights.adding(BrowserUsageState(source: .openCodeConsole, reading: reading, checkedAt: now), history: (nil, nil), to: agent, now: now))
        #expect(merged.windows == [go])
        #expect(merged.figures.map(\.remaining) == [12.4])
        #expect(merged.notes.isEmpty)
        // Without a sign-in the account says so and keeps what OpenCode reports.
        let failed = try #require(
            UsageInsights.adding(
                BrowserUsageState(source: .openCodeConsole, problem: .notSignedIn, checkedAt: now), history: (nil, nil), to: nil, now: now))
        #expect(failed.windows.isEmpty && failed.figures.isEmpty)
        #expect(failed.notes == ["Couldn’t read opencode.ai. You aren’t signed in there in Coincide’s browser. Showing Coincide’s own record."])
    }

    @Test func browserFiguresFillInWithoutOverridingTheAgents() throws {
        let reading = BrowserUsageReading(
            source: .chatGPT, checkedAt: now,
            figures: [
                UsageFigure(id: "individual", label: "Credit limit", unit: .credits, used: 1, limit: 10),
                UsageFigure(id: "monthly_credit_limit", label: "Monthly credit limit", unit: .credits, used: 2, limit: 20),
            ], credits: UsageCredits(hasCredits: true, unlimited: false, balance: "50"), email: "me@example.com")
        let agent = UsageLimits(
            windows: [], checkedAt: now, credits: UsageCredits(hasCredits: true, unlimited: false),
            figures: [UsageFigure(id: "individual", label: "Credit limit", unit: .credits, used: 5, limit: 10)])
        let state = BrowserUsageState(source: .chatGPT, reading: reading, checkedAt: now)
        let uses = [ChatGPTCodexBilling.CreditUse(day: now.addingTimeInterval(-86_400), service: "CLI", credits: 7)]
        let merged = try #require(UsageInsights.adding(state, history: (uses, nil), to: agent, now: now))
        #expect(merged.figures.map(\.id) == ["individual", "monthly_credit_limit", "credit_history"])
        // The agent's own figure stays.
        #expect(merged.figures[0].used == 5)
        // The agent reported credits without a balance; the site's balance fills it in.
        #expect(merged.credits?.balance == "50")
        #expect(merged.figures[2].used == 7)
        // A failed history read is noted; the rest still shows.
        let noHistory = try #require(UsageInsights.adding(state, history: (nil, .unrecognized), to: agent, now: now))
        #expect(noHistory.notes.contains { $0.contains("credit history") })
    }

    @Test func aFailedReadKeepsTheAgentsFiguresAndSaysWhy() throws {
        let agent = UsageLimits(windows: [], checkedAt: now, notes: [AnthropicAdminUsage.balanceNote])
        let failed = BrowserUsageState(source: .claudeConsole, problem: .sessionExpired, checkedAt: now)
        let merged = try #require(UsageInsights.adding(failed, history: (nil, nil), to: agent, now: now))
        #expect(merged.figures.isEmpty)
        #expect(merged.notes.last == BrowserUsageProblem.sessionExpired.note(.claudeConsole))
        #expect(merged.notes.last?.hasPrefix("Couldn’t read platform.claude.com. The sign-in has expired.") == true)
        #expect(merged.notes.last?.hasSuffix("Showing Coincide’s own record.") == true)
        // A reading answers the note that the API can't show the balance.
        let reading = BrowserUsageReading(
            source: .claudeConsole, checkedAt: now,
            figures: [UsageFigure(id: "console_balance", label: "Console credits", unit: .currency("USD"), remaining: 5)])
        let read = try #require(
            UsageInsights.adding(BrowserUsageState(source: .claudeConsole, reading: reading, checkedAt: now), history: (nil, nil), to: agent, now: now))
        #expect(!read.notes.contains(AnthropicAdminUsage.balanceNote))
        #expect(read.figures.map(\.id) == ["console_balance"])
    }

    // MARK: Settings

    @Test func theSettingIsOffByDefaultAndSkipsSitesItDoesntKnow() throws {
        #expect(AppSettings().usageBrowserSignIn.isEmpty)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"usageBrowserSignIn":["chatgpt","someday-site"]}"#.utf8))
        #expect(decoded.usageBrowserSignIn == [.chatGPT])
        var settings = AppSettings()
        settings.usageBrowserSignIn = [.claudeConsole]
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(again.usageBrowserSignIn == [.claudeConsole])
    }
}
