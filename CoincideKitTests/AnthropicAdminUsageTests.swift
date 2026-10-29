import Foundation
import Testing

@testable import CoincideKit

/// Anthropic's Admin API usage and cost reports, read with synthetic answers shaped like the documented ones
/// (platform.claude.com, Usage and Cost API). Nothing here reaches the network.
struct AnthropicAdminUsageTests {
    /// Wednesday 15 October 2025, 14:00 UTC.
    private let now = ClaudeUsageLimits.date(fromISO: "2025-10-15T14:00:00Z")!
    private let adminKey = "sk-ant-admin01-test"
    private let apiKey = "fake-test-key-R2D-example-igAA"

    private func usageBucket(_ day: String, _ results: [JSONValue]) -> JSONValue {
        .object([
            "starting_at": .string("2025-10-\(day)T00:00:00Z"), "ending_at": .string("2025-10-\(day)T23:59:59Z"),
            "results": .array(results),
        ])
    }

    private func usageRow(_ model: String, input: Double, output: Double, read: Double = 0, write5m: Double = 0, write1h: Double = 0) -> JSONValue {
        .object([
            "uncached_input_tokens": .number(input), "output_tokens": .number(output), "cache_read_input_tokens": .number(read),
            "cache_creation": .object(["ephemeral_5m_input_tokens": .number(write5m), "ephemeral_1h_input_tokens": .number(write1h)]),
            "model": .string(model), "api_key_id": .null, "workspace_id": .null,
        ])
    }

    private func costRow(_ cents: String, model: String?, currency: String = "USD") -> JSONValue {
        .object([
            "amount": .string(cents), "currency": .string(currency), "model": model.map(JSONValue.string) ?? .null,
            "description": .string("Usage"), "cost_type": .string("tokens"),
        ])
    }

    private func page(_ data: [JSONValue], next: String? = nil) -> Data {
        Data(
            JSONValue.object(["data": .array(data), "has_more": .bool(next != nil), "next_page": next.map(JSONValue.string) ?? .null])
                .compactJSON.utf8)
    }

    private var keyList: Data {
        Data(
            JSONValue.object([
                "data": .array([
                    .object(["id": .string("apikey_mine"), "name": .string("Coincide"), "partial_key_hint": .string("fake-test-key-R2D...igAA"), "status": .string("active")]),
                    .object(["id": .string("apikey_other"), "name": .string("CI"), "partial_key_hint": .string("fake-test-key-Zzz...q1B2"), "status": .string("active")]),
                ]),
                "has_more": .bool(false), "first_id": .string("apikey_mine"), "last_id": .string("apikey_other"),
            ]).compactJSON.utf8)
    }

    private func respond(_ request: URLRequest, _ status: Int, _ body: Data) -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }

    // MARK: Requests

    @Test func requestsCarryTheKeyInAHeaderAndTheDocumentedQuery() throws {
        let start = AnthropicAdminUsage.monthStart(now)
        let request = AnthropicAdminUsage.request(
            "usage_report/messages", query: AnthropicAdminUsage.usageQuery(from: start, apiKeyID: "apikey_mine", page: "page_2"),
            adminKey: adminKey, timeout: 10)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == adminKey)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let url = try #require(request.url)
        #expect(!url.absoluteString.contains(adminKey))
        #expect(url.path == "/v1/organizations/usage_report/messages")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(value("starting_at") == "2025-10-01T00:00:00Z")
        #expect(value("bucket_width") == "1d" && value("limit") == "31")
        #expect(value("group_by[]") == "model" && value("api_key_ids[]") == "apikey_mine" && value("page") == "page_2")
        let cost = AnthropicAdminUsage.request("cost_report", query: AnthropicAdminUsage.costQuery(from: start, page: nil), adminKey: adminKey, timeout: 10)
        #expect(cost.url?.path == "/v1/organizations/cost_report")
        #expect(cost.url?.query?.contains("group_by%5B%5D=description") == true || cost.url?.query?.contains("group_by[]=description") == true)
    }

    // MARK: Matching the account's key

    @Test func theAccountsKeyMatchesOnlyAUniqueHint() throws {
        let keys = try #require(JSONValue.parse(keyList)?["data"]?.array)
        #expect(AnthropicAdminUsage.matchingKey(apiKey, in: keys)?.id == "apikey_mine")
        #expect(AnthropicAdminUsage.matchingKey(apiKey, in: keys)?.name == "Coincide")
        #expect(AnthropicAdminUsage.matchingKey("fake-test-key-Nope-xxxx", in: keys) == nil)
        // Two keys fitting the same hint: tokens stay the organization's rather than guess.
        let twins = keys + [.object(["id": .string("apikey_twin"), "partial_key_hint": .string("fake-test-key-R2D...igAA")])]
        #expect(AnthropicAdminUsage.matchingKey(apiKey, in: twins) == nil)
        // A hint too short to tell keys apart is no match.
        let vague: [JSONValue] = [.object(["id": .string("apikey_vague"), "partial_key_hint": .string("sk...AA")])]
        #expect(AnthropicAdminUsage.matchingKey(apiKey, in: vague) == nil)
    }

    // MARK: Parsing

    @Test func reportsSumTodayTheMonthAndEachModel() throws {
        let usage = [
            usageBucket("01", [usageRow("claude-opus-5-5", input: 1_000, output: 500, read: 2_000, write5m: 100, write1h: 50)]),
            usageBucket("14", []),
            usageBucket(
                "15",
                [usageRow("claude-opus-5-5", input: 10, output: 20), usageRow("claude-haiku-5-5", input: 300, output: 40, read: 60)]),
            // A bucket from before the month (a page that reached back) doesn't count.
            .object(["starting_at": .string("2025-09-30T00:00:00Z"), "results": .array([usageRow("claude-opus-5-5", input: 9_999, output: 9_999)])]),
        ]
        let cost = [
            usageBucket("01", [costRow("1234.5", model: "claude-opus-5-5"), costRow("100", model: nil)]),
            usageBucket("15", [costRow("250", model: "claude-haiku-5-5"), costRow("999", model: "claude-opus-5-5", currency: "EUR")]),
        ]
        let report = AnthropicAdminUsage.report(usage: usage, cost: cost, scope: .organization, now: now)
        #expect(report.tokensToday == AnthropicAdminUsage.Tokens(uncachedInput: 310, cacheRead: 60, cacheCreation: 0, output: 60))
        #expect(report.tokensThisMonth.total == 1_000 + 500 + 2_000 + 150 + 30 + 400)
        #expect(report.tokensThisMonth.cacheCreation == 150)
        // Cents to dollars; a currency other than USD is left out rather than mixed in.
        #expect(abs(try #require(report.costToday) - 2.5) < 0.000_1)
        #expect(abs(try #require(report.costThisMonth) - 15.845) < 0.000_1)
        #expect(report.models.map(\.model) == ["claude-opus-5-5", "claude-haiku-5-5"])
        #expect(report.models[0].tokens.total == 3_680)
        #expect(abs((report.models[0].cost ?? 0) - 12.345) < 0.000_1)
        #expect(abs((report.models[1].cost ?? 0) - 2.5) < 0.000_1)
        // Without a cost report there is no spend, rather than $0.
        let tokensOnly = AnthropicAdminUsage.report(usage: usage, cost: nil, scope: .organization, now: now)
        #expect(tokensOnly.costToday == nil && tokensOnly.costThisMonth == nil)
        #expect(tokensOnly.models.allSatisfy { $0.cost == nil })
    }

    @Test func figuresNameWhoseUsageTheyAre() throws {
        var report = AnthropicAdminUsage.Report(tokenScope: .apiKey(name: "Coincide"), checkedAt: now)
        report.costToday = 2.5
        report.costThisMonth = 15.85
        report.tokensToday = AnthropicAdminUsage.Tokens(uncachedInput: 100, output: 20)
        let figures = AnthropicAdminUsage.figures(report)
        #expect(figures.map(\.id) == ["admin_cost_today", "admin_cost_month", "admin_tokens_today", "admin_tokens_month"])
        #expect(figures[0].used == 2.5 && figures[0].detail == "Organization" && figures[0].unit == .currency("USD"))
        #expect(figures[0].resetsAt == ClaudeUsageLimits.date(fromISO: "2025-10-16T00:00:00Z"))
        #expect(figures[1].resetsAt == ClaudeUsageLimits.date(fromISO: "2025-11-01T00:00:00Z"))
        #expect(figures[2].used == 120 && figures[2].detail == "Key “Coincide”" && figures[2].limit == nil)
        // No cost report, no spend figures.
        let noCost = AnthropicAdminUsage.figures(AnthropicAdminUsage.Report(tokenScope: .organization, checkedAt: now))
        #expect(noCost.map(\.id) == ["admin_tokens_today", "admin_tokens_month"])
        #expect(noCost[0].detail == "Organization")
    }

    // MARK: Reading

    @Test func aReadNarrowsTokensToTheKeyAndFollowsPages() async throws {
        final class Log: @unchecked Sendable {
            var requests: [URLRequest] = []
            let lock = NSLock()
            func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        }
        let log = Log()
        let usageFirst = page([usageBucket("14", [usageRow("claude-opus-5-5", input: 5, output: 5)])], next: "page_2")
        let usageSecond = page([usageBucket("15", [usageRow("claude-opus-5-5", input: 7, output: 3)])])
        let costPage = page([usageBucket("15", [costRow("300", model: "claude-opus-5-5")])])
        let keys = keyList
        let outcome = await AnthropicAdminUsage.read(
            adminKey: adminKey, apiKey: apiKey,
            fetch: { request in
                log.add(request)
                let path = request.url!.path
                if path.hasSuffix("/api_keys") { return self.respond(request, 200, keys) }
                if path.hasSuffix("/usage_report/messages") {
                    return self.respond(request, 200, request.url!.query!.contains("page=page_2") ? usageSecond : usageFirst)
                }
                if path.hasSuffix("/cost_report") { return self.respond(request, 200, costPage) }
                return self.respond(request, 404, Data())
            }, now: now)
        guard case .report(let report) = outcome else {
            Issue.record("Expected a report, got \(outcome)")
            return
        }
        #expect(report.tokenScope == .apiKey(name: "Coincide"))
        #expect(report.tokensThisMonth.total == 20 && report.tokensToday.total == 10)
        #expect(report.costToday == 3)
        let usageRequests = log.requests.filter { $0.url!.path.hasSuffix("/usage_report/messages") }
        #expect(usageRequests.count == 2)
        #expect(usageRequests.allSatisfy { $0.url!.query!.contains("apikey_mine") })
        // The key goes only in the header of every request, never in a URL.
        #expect(log.requests.allSatisfy { $0.value(forHTTPHeaderField: "x-api-key") == self.adminKey })
        #expect(log.requests.allSatisfy { !$0.url!.absoluteString.contains(self.adminKey) && !$0.url!.absoluteString.contains(self.apiKey) })
    }

    @Test func anUnreadableKeyListOrCostReportStillReadsWhatItCan() async {
        let usage = page([usageBucket("15", [usageRow("claude-opus-5-5", input: 1, output: 1)])])
        let outcome = await AnthropicAdminUsage.read(
            adminKey: adminKey, apiKey: apiKey,
            fetch: { request in
                let path = request.url!.path
                if path.hasSuffix("/usage_report/messages") {
                    // Without the key list, usage is not narrowed to a key.
                    #expect(!request.url!.query!.contains("api_key_ids"))
                    return self.respond(request, 200, usage)
                }
                return self.respond(request, 500, Data())
            }, now: now)
        guard case .report(let report) = outcome else {
            Issue.record("Expected a report, got \(outcome)")
            return
        }
        #expect(report.tokenScope == .organization)
        #expect(report.costThisMonth == nil)
        #expect(report.tokensToday.total == 2)
    }

    @Test func refusedKeysSaySoAndOtherFailuresAreFailures() async {
        func read(_ status: Int) async -> AnthropicAdminUsage.Outcome {
            await AnthropicAdminUsage.read(
                adminKey: adminKey, apiKey: nil, fetch: { request in self.respond(request, status, Data("{}".utf8)) }, now: now)
        }
        #expect(await read(401) == .unauthorized)
        #expect(await read(403) == .forbidden)
        #expect(await read(500) == .failed)
        #expect(AnthropicAdminUsage.problem(.unauthorized)?.contains("Admin API key") == true)
        #expect(AnthropicAdminUsage.problem(.report(AnthropicAdminUsage.Report(tokenScope: .organization, checkedAt: now))) == nil)
        // A 200 that isn't JSON is a failure, not an empty month.
        let garbage = await AnthropicAdminUsage.read(
            adminKey: adminKey, apiKey: nil, fetch: { request in self.respond(request, 200, Data("<html>".utf8)) }, now: now)
        #expect(garbage == .failed)
    }

    @Test func theTakersOfAnAdminKeyAreAnthropicAPIKeyAccounts() {
        var account = ProviderAccount(id: "key", provider: .claude, name: "API", auth: .apiKey)
        account.apiKeyVariable = "ANTHROPIC_API_KEY"
        #expect(UsageInsights.takesAdminKey(account))
        #expect(!UsageInsights.takesAdminKey(.defaultAccount(for: .claude)))
        let login = ProviderAccount(id: "login", provider: .claude, name: "Work", auth: .login)
        #expect(!UsageInsights.takesAdminKey(login))
    }
}
