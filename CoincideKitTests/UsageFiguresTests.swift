import Foundation
import Testing

@testable import CoincideKit

/// The amounts providers report besides their percentage windows, read from synthetic answers only (no real
/// responses, keys or account identifiers).
struct UsageFiguresTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Claude

    @Test func claudeExtraUsageIsInCentsWithTheSpendRowsReset() throws {
        let usage = try #require(
            JSONValue.parse(
                #"""
                {"rate_limits_available":true,"rate_limits":{
                  "five_hour":{"utilization":10,"resets_at":null},
                  "extra_usage":{"is_enabled":true,"monthly_limit":50000,"used_credits":27140,"utilization":54,"currency":"usd"},
                  "limits":[{"kind":"session","group":"session","percent":10,"resets_at":null},
                            {"kind":"spend","group":"monthly","percent":54,"resets_at":"2026-11-01T00:00:00.000Z","is_active":true}],
                  "spend":{"enabled":true,"used":{"amount_minor":2500,"currency":"USD","exponent":2},"limit":{"amount_minor":10000,"currency":"USD","exponent":2}},
                  "iguana_necktie":{"utilization":40,"resets_at":"2026-11-05T07:59:00+00:00","limit_dollars":250},
                  "unnamed_bucket":{"utilization":5,"limit_dollars":10},
                  "wattle_ember":{"label":"Routines","limit_dollars":20,"used_dollars":4.5,"remaining_dollars":15.5,"resets_at":"2026-11-02T00:00:00Z"}}}
                """#))
        let figures = ClaudeUsageLimits.figures(fromUsage: usage)
        #expect(figures.map(\.id) == ["extra_usage", "spend", "iguana_necktie", "wattle_ember"])
        let extra = figures[0]
        #expect(extra.unit == .currency("USD"))
        #expect(extra.used == 271.4 && extra.limit == 500)
        #expect(extra.resetsAt == ClaudeUsageLimits.date(fromISO: "2026-11-01T00:00:00Z"))
        #expect(figures[1].used == 25 && figures[1].limit == 100)
        // Promotional credits expire rather than reset; without amounts, the used share comes from the utilization.
        #expect(figures[2].label == "Cloud credits" && figures[2].used == 100 && figures[2].limit == 250)
        #expect(figures[2].resetsAt == nil && figures[2].expiresAt != nil)
        #expect(figures[3].label == "Routines" && figures[3].remaining == 15.5 && figures[3].resetsAt != nil)
    }

    @Test func claudeExtraUsageOffOrUncappedSaysSo() throws {
        let off = try #require(
            JSONValue.parse(#"{"rate_limits_available":true,"rate_limits":{"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null}}}"#))
        let figure = try #require(ClaudeUsageLimits.figures(fromUsage: off).first)
        #expect(figure.detail == "Off" && figure.used == nil && figure.limit == nil)
        let uncapped = try #require(
            JSONValue.parse(#"{"rate_limits_available":true,"rate_limits":{"extra_usage":{"is_enabled":true,"monthly_limit":null,"used_credits":1234}}}"#))
        let open = try #require(ClaudeUsageLimits.figures(fromUsage: uncapped).first)
        #expect(open.used == 12.34 && open.limit == nil && open.detail == "No cap")
        // An API key reports nothing; the yen has no minor unit.
        #expect(ClaudeUsageLimits.figures(fromUsage: ["rate_limits_available": false, "rate_limits": nil]).isEmpty)
        #expect(ClaudeUsageLimits.minorUnitScale("JPY") == 1)
        #expect(ClaudeUsageLimits.minorUnitScale("USD") == 100)
    }

    // MARK: Codex

    @Test func codexCreditLimitResetCreditsAndWorkspaceNotes() throws {
        let read = try #require(
            JSONValue.parse(
                #"""
                {"rateLimits":{"limitId":"codex","planType":"business","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1800003600},
                  "credits":{"hasCredits":true,"unlimited":false,"balance":"40"},
                  "individualLimit":{"limit":"500","used":"125.5","remainingPercent":75,"resetsAt":1802592000},
                  "rateLimitReachedType":"workspace_member_credits_depleted"},
                 "rateLimitResetCredits":{"availableCount":2,"credits":[
                   {"id":"a","grantedAt":1799000000,"resetType":"codexRateLimits","status":"available","expiresAt":1801000000},
                   {"id":"b","grantedAt":1799000000,"resetType":"codexRateLimits","status":"available","expiresAt":1800500000},
                   {"id":"c","grantedAt":1799000000,"resetType":"codexRateLimits","status":"redeemed","expiresAt":1800100000}]}}
                """#))
        let limits = CodexUsageLimits.limits(fromRead: read, at: now)
        #expect(limits.figures.map(\.id) == ["individual", "reset_credits"])
        #expect(limits.figures[0].used == 125.5 && limits.figures[0].limit == 500 && limits.figures[0].unit == .credits)
        #expect(limits.figures[0].resetsAt == Date(timeIntervalSince1970: 1_802_592_000))
        #expect(limits.figures[1].remaining == 2)
        #expect(limits.figures[1].expiresAt == Date(timeIntervalSince1970: 1_800_500_000))
        #expect(limits.notes == ["The workspace is out of credits."])
        // Nothing extra for a plain plan.
        let plain = try #require(JSONValue.parse(#"{"rateLimits":{"primary":{"usedPercent":1}},"rateLimitResetCredits":{"availableCount":0}}"#))
        #expect(CodexUsageLimits.limits(fromRead: plain, at: now).figures.isEmpty)
        #expect(CodexUsageLimits.notes(fromRead: try #require(JSONValue.parse(#"{"rateLimits":{"spendControlReached":true}}"#))).count == 1)
    }

    // MARK: Cursor

    @Test func cursorIncludedAndOnDemandAreCents() throws {
        let response = try #require(
            JSONValue.parse(
                #"{"billingCycleEnd":"1789876386000","planUsage":{"totalPercentUsed":40,"includedSpend":800,"limit":2000,"remaining":1200},"spendLimitUsage":{"individualUsed":350,"individualLimit":5000,"individualRemaining":4650,"limitType":"user"}}"#))
        let figures = CursorUsageLimits.figures(fromResponse: response)
        #expect(figures.map(\.id) == ["included", "on_demand"])
        #expect(figures[0].used == 8 && figures[0].limit == 20 && figures[0].remaining == 12)
        #expect(figures[1].used == 3.5 && figures[1].limit == 50)
        #expect(figures.allSatisfy { $0.resetsAt == Date(timeIntervalSince1970: 1_789_876_386) })
        // No on-demand limit: what was used, with no limit.
        let unlimited = CursorUsageLimits.figures(fromResponse: ["spendLimitUsage": ["individualUsed": 100, "individualLimit": 0]])
        #expect(unlimited.first?.used == 1 && unlimited.first?.limit == nil)
        #expect(CursorUsageLimits.figures(fromResponse: ["planUsage": ["totalPercentUsed": 5]]).isEmpty)
    }

    // MARK: API keys

    @Test func servicesFollowTheKeysVariable() {
        #expect(APIKeyUsage.service(forVariable: "ANTHROPIC_API_KEY") == .anthropic)
        #expect(APIKeyUsage.service(forVariable: "OPENROUTER_API_KEY") == .openRouter)
        #expect(APIKeyUsage.service(forVariable: "GOOGLE_GENERATIVE_AI_API_KEY") == .gemini)
        #expect(APIKeyUsage.service(forVariable: "GROQ_API_KEY") == nil)
        #expect(APIKeyUsage.service(forVariable: nil) == nil)
        for service in [APIKeyUsage.Service.anthropic, .openAI, .xAI, .gemini, .openCodeZen] {
            #expect(!APIKeyUsage.notes(for: service).isEmpty)
        }
    }

    @Test func keysWithoutAUsageEndpointGetNotesWithoutTheNetwork() async throws {
        let stub = UsageFetchStub.unused()
        let outcome = try #require(await APIKeyUsage.read(variable: "ANTHROPIC_API_KEY", key: "sk-test", fetch: stub.fetch, now: now))
        let limits = try #require(outcome.limits)
        #expect(limits.figures.isEmpty && limits.notes == APIKeyUsage.notes(for: .anthropic))
        #expect(await APIKeyUsage.read(variable: "MISTRAL_API_KEY", key: "k", fetch: stub.fetch) == nil)
        #expect(stub.requests.isEmpty)
    }

    @Test func openRouterReadsTheKeyAndCreditsWithTheKeyInTheHeader() async throws {
        let stub = UsageFetchStub { request in
            if request.url?.path == "/api/v1/key" {
                return UsageFetchStub.json([
                    "data": [
                        "label": "sk-or-v1-abc...xyz", "limit": 20, "limit_remaining": 12.4, "limit_reset": "monthly", "usage": 31.5,
                        "usage_daily": 0.5, "usage_weekly": 2.25, "usage_monthly": 7.6, "is_free_tier": false,
                    ]
                ])
            }
            return UsageFetchStub.json(["data": ["total_credits": 50, "total_usage": 31.5]])
        }
        let outcome = await APIKeyUsage.readOpenRouter(key: "sk-or-test", fetch: stub.fetch, timeout: .seconds(5), now: now)
        let limits = try #require(outcome.limits)
        #expect(limits.figures.map(\.id) == ["credits", "key_limit", "usage_daily", "usage_weekly", "usage_monthly", "usage"])
        #expect(limits.figures[0].left == 18.5)
        #expect(limits.figures[1].remaining == 12.4 && limits.figures[1].limit == 20)
        #expect(limits.figures[1].resetsAt == APIKeyUsage.nextUTCBoundary("monthly", after: now))
        #expect(limits.notes.isEmpty)
        #expect(stub.tokens == ["sk-or-test", "sk-or-test"])
        #expect(stub.requests.allSatisfy { !($0.url?.absoluteString.contains("sk-or-test") ?? true) })
    }

    @Test func openRouterWithoutAManagementKeyStillReadsTheKey() async throws {
        let stub = UsageFetchStub { request in
            request.url?.path == "/api/v1/key"
                ? UsageFetchStub.json(["data": ["limit": nil, "usage": 1]])
                : (403, #"{"error":{"message":"Only management keys can perform this operation"}}"#)
        }
        let limits = try #require(await APIKeyUsage.readOpenRouter(key: "k", fetch: stub.fetch, timeout: .seconds(5), now: now).limits)
        #expect(limits.figures.map(\.id) == ["key_limit", "usage"])
        #expect(limits.figures[0].detail == "No limit")
        #expect(limits.notes.count == 1)
        let refused = UsageFetchStub { _ in (401, "{}") }
        #expect(await APIKeyUsage.readOpenRouter(key: "k", fetch: refused.fetch, timeout: .seconds(5), now: now) == .failed)
    }

    @Test func utcPeriodsStartAtMidnightAndOnMonday() throws {
        // 2027-01-15 08:00 UTC, a Friday.
        let friday = Date(timeIntervalSince1970: 1_799_971_200 + 8 * 3_600)
        #expect(APIKeyUsage.nextUTCBoundary("daily", after: friday) == Date(timeIntervalSince1970: 1_799_971_200 + 86_400))
        #expect(APIKeyUsage.nextUTCBoundary("weekly", after: friday) == Date(timeIntervalSince1970: 1_799_971_200 + 3 * 86_400))
        #expect(APIKeyUsage.nextUTCBoundary("monthly", after: friday) == ClaudeUsageLimits.date(fromISO: "2027-02-01T00:00:00Z"))
        #expect(APIKeyUsage.nextUTCBoundary("never", after: friday) == nil)
    }

    @Test func anthropicRateLimitHeadersBecomeFigures() {
        let figures = APIKeyUsage.anthropicRateLimitFigures([
            "Anthropic-RateLimit-Requests-Limit": "50", "anthropic-ratelimit-requests-remaining": "49",
            "anthropic-ratelimit-requests-reset": "2027-01-15T08:00:12Z", "anthropic-ratelimit-input-tokens-limit": "30000",
            "anthropic-ratelimit-input-tokens-remaining": "29000", "request-id": "req_test",
        ])
        #expect(figures.map(\.id) == ["ratelimit_requests", "ratelimit_input-tokens"])
        #expect(figures[0].limit == 50 && figures[0].remaining == 49 && figures[0].unit == .requests)
        #expect(figures[0].resetsAt == ClaudeUsageLimits.date(fromISO: "2027-01-15T08:00:12Z"))
        #expect(figures[1].resetsAt == nil && figures[1].unit == .tokens)
        #expect(APIKeyUsage.anthropicRateLimitFigures(["content-type": "application/json"]).isEmpty)
    }

    @Test func theAnthropicProbeSendsOneTokenWithTheKeyInAHeader() async throws {
        final class Sent: @unchecked Sendable { var request: URLRequest? }
        let sent = Sent()
        let outcome = await APIKeyUsage.probeAnthropicRateLimits(
            key: "sk-ant-test",
            fetch: { request in
                sent.request = request
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["anthropic-ratelimit-requests-limit": "50", "anthropic-ratelimit-requests-remaining": "48"])!
                return (Data("{}".utf8), response)
            }, now: now)
        #expect(outcome.limits?.figures.first?.remaining == 48)
        let request = try #require(sent.request)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.url?.absoluteString.contains("sk-ant-test") == false)
        let body = try #require(request.httpBody.flatMap { JSONValue.parse($0) })
        #expect(body["max_tokens"]?.number == 1)
        // No headers (a refused key): a failed read, not empty limits.
        let refused = await APIKeyUsage.probeAnthropicRateLimits(
            key: "k", fetch: { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: [:])!) })
        #expect(refused == .failed)
    }

    // MARK: Model

    @Test func figuresStartOverAtTheirResetAndAddingKeepsBoth() {
        let figure = UsageFigure(id: "f", label: "F", unit: .currency("USD"), used: 4, limit: 10, resetsAt: now.addingTimeInterval(-1))
        #expect(figure.usedPercent == 40 && figure.left == 6)
        let reset = figure.current(at: now)
        #expect(reset.used == 0 && reset.resetsAt == nil && reset.limit == 10)
        let base = UsageLimits(windows: [], checkedAt: now, figures: [figure], notes: ["a"])
        let extra = UsageLimits(
            windows: [], checkedAt: now.addingTimeInterval(5),
            figures: [UsageFigure(id: "f", label: "F", unit: .credits, used: 1), UsageFigure(id: "g", label: "G", unit: .count, remaining: 2)],
            notes: ["a", "b"])
        let merged = base.adding(extra)
        #expect(merged.figures.map(\.id) == ["f", "g"] && merged.figures[0].unit == .credits)
        #expect(merged.notes == ["a", "b"])
        #expect(merged.checkedAt == now.addingTimeInterval(5))
        #expect(UsageLimits(windows: [], checkedAt: now).isEmpty && !merged.isEmpty)
        let windows = UsageLimits(windows: [UsageLimitWindow(id: "w", kind: .weekly, label: "W", usedPercent: 3)], checkedAt: now, figures: [figure])
        #expect(windows.current(at: now).figures.first?.used == 0)
    }

    // MARK: Logs of API-key accounts

    @Test func loggedSessionsOfAThreadsAccountCountForThatAccount() {
        let request = LoggedRequest(date: now, model: "claude-haiku-4-5", tokens: TokenTotals(input: 10, output: 5), promptTokens: 10)
        let sessions = [
            LoggedSession(provider: .claude, accountID: ProviderAccount.defaultID, sessionID: "keyed", originator: nil, requests: [request]),
            LoggedSession(provider: .claude, accountID: ProviderAccount.defaultID, sessionID: "plain", originator: nil, requests: [request]),
        ]
        let project = UUID()
        let events = UsageEvents.fromLogs(
            sessions,
            owners: [.claude: ["keyed": .init(projectID: project, accountID: "api"), "plain": .init(projectID: project, accountID: ProviderAccount.defaultID)]])
        #expect(events.map(\.accountID) == ["api", ProviderAccount.defaultID])
        #expect(events.allSatisfy { $0.isFromCoincide })
    }

    @Test func threadSummariesKnowTheirSessionsAccounts() {
        var thread = ChatThread(projectID: UUID(), selection: ModelSelection(provider: .claude, modelID: "default"))
        #expect(ThreadSummary(thread).nativeSessionAccounts == nil)
        thread.sessions[.claude] = ProviderSessionRef(sessionID: "s", seenItemCount: 0, accountID: "api")
        thread.sessions[.codex] = ProviderSessionRef(sessionID: "c", seenItemCount: 0)
        #expect(ThreadSummary(thread).nativeSessionAccounts == [.claude: "api"])
    }
}
