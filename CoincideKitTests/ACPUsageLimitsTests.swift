import Foundation
import Testing

@testable import CoincideKit

/// Grok Build's plan limits, from T3 Code's `GrokProvider.test.ts` ("Grok usage limits" and `readGrokAccount`).
struct GrokUsageLimitsTests {
    private static let checkedAt = Date(timeIntervalSince1970: 1_789_516_800)
    private static let weeklyPeriod: [String: JSONValue] = [
        "type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-09-11T03:10:30.159171+00:00", "end": "2026-09-18T03:10:30.159171+00:00",
    ]
    private static let current = "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"

    /// A billing answer for the weekly period with `changes`; a nil value leaves that field out.
    private func billing(_ changes: [String: JSONValue?] = [:], base: [String: JSONValue] = GrokUsageLimitsTests.weeklyPeriod) -> JSONValue {
        var period = base
        for (key, value) in changes { period[key] = value }
        return ["config": ["currentPeriod": .object(period)]]
    }

    /// Files by path; any other path does not exist.
    private func files(_ contents: [String: String]) -> @Sendable (URL) throws -> Data? {
        { url in contents[url.path].map { Data($0.utf8) } }
    }

    private func reader(_ files: @escaping @Sendable (URL) throws -> Data?, _ http: UsageFetchStub) -> GrokUsageLimits.Reader {
        GrokUsageLimits.Reader(readFile: files, fetch: http.fetch)
    }

    // MARK: Billing answers

    @Test func showsZeroUsageForCompleteWeeklyAndMonthlyPeriodsWithNoPercentage() throws {
        let weekly = try #require(GrokUsageLimits.windows(fromBilling: billing()))
        #expect(
            weekly == [
                UsageLimitWindow(
                    id: "subscription", kind: .weekly, label: "Weekly", usedPercent: 0,
                    resetsAt: Date(timeIntervalSince1970: 1_789_701_030.159))
            ])
        let monthly = billing([
            "type": "USAGE_PERIOD_TYPE_MONTHLY", "start": "2026-09-01T00:00:00.000Z", "end": "2026-10-01T00:00:00.000Z",
        ])
        #expect(
            GrokUsageLimits.windows(fromBilling: monthly) == [
                UsageLimitWindow(
                    id: "subscription", kind: .monthly, label: "Monthly", usedPercent: 0,
                    resetsAt: Date(timeIntervalSince1970: 1_790_812_800))
            ])
    }

    @Test func keepsIncompleteInvalidUnorderedAndUnknownPeriodsUnreported() {
        let week = Self.weeklyPeriod
        let changes: [[String: JSONValue?]] = [
            ["type": nil], ["type": "USAGE_PERIOD_TYPE_DAILY"], ["start": nil], ["end": nil], ["start": "invalid"],
            ["end": "invalid"], ["start": week["end"]], ["start": week["end"], "end": week["start"]],
            // A start that is not text, which the schema allows.
            ["start": 1_789_000_000],
        ]
        for change in changes {
            #expect(GrokUsageLimits.windows(fromBilling: billing(change)) == [], "\(change)")
        }
        #expect(GrokUsageLimits.windows(fromBilling: ["config": [:]]) == [])
    }

    // regression: T3 #17061 show zero-use Grok billing periods
    @Test func rejectsImpossibleCalendarDatesAtEitherPeriodBoundary() {
        for (start, end) in [
            ("2026-02-30T00:00:00.000Z", "2026-03-09T00:00:00.000Z"), ("2026-02-23T00:00:00.000Z", "2026-02-30T00:00:00.000Z"),
        ] {
            #expect(GrokUsageLimits.windows(fromBilling: billing(["start": .string(start), "end": .string(end)])) == [], "\(start) – \(end)")
        }
    }

    @Test func doesNotInventAnAllowanceOrResetWhenBillingOmitsThem() {
        for response: JSONValue in [[:], ["config": [:]], ["config": ["creditUsagePercent": .number(.nan)]]] {
            #expect(GrokUsageLimits.windows(fromBilling: response) == [])
        }
        #expect(
            GrokUsageLimits.windows(fromBilling: ["config": ["creditUsagePercent": 0]]) == [
                UsageLimitWindow(id: "subscription", kind: .other, label: "Subscription", usedPercent: 0)
            ])
        let over: JSONValue = ["config": ["creditUsagePercent": 120, "currentPeriod": ["type": "USAGE_PERIOD_TYPE_MONTHLY", "end": "invalid"]]]
        #expect(
            GrokUsageLimits.windows(fromBilling: over) == [
                UsageLimitWindow(id: "subscription", kind: .monthly, label: "Monthly", usedPercent: 100)
            ])
    }

    @Test func rejectsAnswersOfAnotherShape() {
        for response: JSONValue in [
            "text", ["config": "x"], ["config": ["creditUsagePercent": "private-value"]], ["config": ["currentPeriod": []]],
            ["config": ["currentPeriod": ["type": 7]]], ["config": ["currentPeriod": ["end": 7]]], ["config": ["creditUsagePercent": nil]],
        ] {
            #expect(GrokUsageLimits.windows(fromBilling: response) == nil, "\(response)")
        }
    }

    // MARK: Reading the account

    @Test func readsTheConfiguredGrokHomeAndPrefersTheCurrentLoginScope() async throws {
        let http = UsageFetchStub { _ in UsageFetchStub.json(["config": ["creditUsagePercent": 37]]) }
        let auth = #"{"\#(Self.current)":{"key":"session-token","auth_mode":"oauth"},"https://accounts.x.ai/sign-in":{"key":"legacy-token"}}"#
        let outcome = await reader(files(["/custom/grok/auth.json": auth]), http)
            .read(environment: ["GROK_HOME": "/custom/grok", "HOME": "/unrelated-home"], at: Self.checkedAt)
        #expect(outcome.limits?.windows.first?.usedPercent == 37)
        #expect(outcome.limits?.checkedAt == Self.checkedAt)
        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(request.timeoutInterval == 10)
    }

    @Test func usesGrokAuthWithoutReadingStoredCredentialsAndAcceptsTheLegacyScope() async {
        let http = UsageFetchStub { _ in UsageFetchStub.json(["config": ["creditUsagePercent": 12]]) }
        let reader = GrokUsageLimits.Reader(
            readFile: { url in
                if url.lastPathComponent == "auth.json" { Issue.record("Read stored credentials") }
                return nil
            }, fetch: http.fetch)
        let outcome = await reader.read(environment: ["GROK_AUTH": #"{"https://accounts.x.ai/sign-in":{"key":"legacy-token"}}"#])
        #expect(outcome.limits?.windows.first?.usedPercent == 12)
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer legacy-token")
    }

    @Test func doesNotUseUnrelatedScopesAPIKeysOrCustomAuthDeployments() async {
        let stored = #"{"https://accounts.x.ai/sign-in":{"key":"stored-account"}}"#
        let environments: [[String: String]] = [
            ["GROK_AUTH": stored, "XAI_API_KEY": "different-api-account"],
            ["GROK_AUTH": #"{"https://other.example":{"key":"unrelated-token"}}"#],
            ["GROK_AUTH": #"{"https://accounts.x.ai/sign-in":{"key":"api-key","auth_mode":"api_key"}}"#],
            ["GROK_AUTH": #"{"https://accounts.x.ai/sign-in":{"key":" "}}"#],
            ["GROK_AUTH": stored, "GROK_OIDC_ISSUER": "https://custom.example"],
            ["GROK_AUTH": stored, "GROK_MODELS_BASE_URL": "https://custom.example/v1"],
            ["GROK_AUTH": stored, "GROK_OAUTH2_PRINCIPAL_TYPE": "Team"],
            ["GROK_AUTH": stored, "GROK_OAUTH2_PRINCIPAL_ID": "team-id"],
            ["GROK_AUTH": stored, "GROK_CONFIG": #"{"auth_provider_command":"custom-auth"}"#],
            ["GROK_AUTH": stored, "GROK_CONFIG_PATH": "/custom-config.toml"],
        ]
        for environment in environments {
            let outcome = await GrokUsageLimits.Reader(readFile: { _ in nil }, fetch: UsageFetchStub.unused().fetch)
                .read(environment: environment.merging(["HOME": "/definitely/not/a/grok-home"]) { $1 })
            #expect(outcome == .unsupported, "\(environment.keys.sorted())")
        }
    }

    @Test func configSectionsThatPickAnotherAccountLeaveTheCheckToTheCLI() async {
        let auth = #"{"\#(Self.current)":{"key":"session-token"}}"#
        for (path, config) in [
            ("/home/me/.grok/config.toml", "model = \"grok-4\"\n[auth]\nprovider = \"custom\""),
            ("/home/me/.grok/managed_config.toml", "  [[ endpoints ]]\nurl = \"https://custom.example\""),
            ("/home/me/.grok/requirements.toml", "\"grok_com_config\" = {}"),
            ("/etc/grok/managed_config.toml", "auth.command = \"custom\""),
            ("/etc/grok/requirements.toml", "'endpoints'.chat = \"https://custom.example\""),
        ] {
            let outcome = await GrokUsageLimits.Reader(
                readFile: files(["/home/me/.grok/auth.json": auth, path: config]), fetch: UsageFetchStub.unused().fetch
            ).read(environment: ["HOME": "/home/me"])
            #expect(outcome == .unsupported, "\(path)")
        }
        // A setting that only mentions auth does not.
        let http = UsageFetchStub { _ in UsageFetchStub.json(["config": ["creditUsagePercent": 1]]) }
        let plain = await reader(
            files(["/home/me/.grok/auth.json": auth, "/home/me/.grok/config.toml": "# auth = \"x\"\nauthor = \"me\""]), http
        ).read(environment: ["HOME": "/home/me"])
        #expect(plain.limits?.windows.count == 1)
    }

    @Test func reportsAMissingLoginAsUnsupportedAndMalformedCredentialsAsAFailure() async {
        let missing = await GrokUsageLimits.Reader(readFile: { _ in nil }, fetch: UsageFetchStub.unused().fetch)
            .read(environment: ["HOME": "/home/me"])
        #expect(missing == .unsupported)
        for contents in ["private-token-invalid-json", #"{"https://accounts.x.ai/sign-in":{"key":42}}"#, #"{"other":"text"}"#] {
            let malformed = await GrokUsageLimits.Reader(readFile: { _ in nil }, fetch: UsageFetchStub.unused().fetch)
                .read(environment: ["GROK_HOME": "/home/me/.grok", "GROK_AUTH": contents])
            #expect(malformed == .failed, "\(contents)")
        }
        // A config file that exists but cannot be read fails the check too.
        let unreadable = await GrokUsageLimits.Reader(
            readFile: { url in
                if url.lastPathComponent == "config.toml" { throw CocoaError(.fileReadNoPermission) }
                return nil
            }, fetch: UsageFetchStub.unused().fetch
        ).read(environment: ["GROK_AUTH": #"{"\#(Self.current)":{"key":"t"}}"#])
        #expect(unreadable == .failed)
    }

    @Test func failsSafelyOnHTTPErrorsAndMalformedBillingAnswers() async {
        for answer in [
            (status: 401, body: "private response"), UsageFetchStub.json(["config": ["creditUsagePercent": "private-value"]]),
            (status: 200, body: "not json"),
        ] {
            let http = UsageFetchStub { _ in answer }
            let outcome = await reader(files([:]), http)
                .read(environment: ["GROK_AUTH": #"{"https://accounts.x.ai/sign-in":{"key":"private-token","email":"someone@example.com"}}"#])
            #expect(outcome == .failed)
        }
        let offline = UsageFetchStub { _ in throw URLError(.notConnectedToInternet) }
        #expect(await reader(files([:]), offline).read(environment: ["GROK_AUTH": #"{"\#(Self.current)":{"key":"t"}}"#]) == .failed)
    }

    @Test func aBillingAnswerThatTakesTooLongFails() async {
        let slow = GrokUsageLimits.Reader(
            readFile: { _ in nil },
            fetch: { request in
                try await Task.sleep(for: .seconds(5))
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await slow.read(environment: ["GROK_AUTH": #"{"\#(Self.current)":{"key":"t"}}"#], timeout: .milliseconds(50))
        #expect(outcome == .failed)
        #expect(clock.now - start < .seconds(2))
    }
}

/// Antigravity's plan quotas, from T3 Code's `antigravityUsageLimits.test.ts`.
@MainActor
struct AntigravityUsageLimitsTests {
    private nonisolated static let summary: JSONValue = [
        "groups": [
            [
                "displayName": "Gemini Models",
                "buckets": [
                    ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.96, "resetTime": "2026-10-12T19:41:43Z"],
                    ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.91, "resetTime": "2026-10-09T16:06:01Z"],
                ],
            ],
            [
                "displayName": "Claude and GPT models",
                "buckets": [
                    ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0, "resetTime": "2026-10-10T15:28:22Z"],
                    ["bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.44, "resetTime": "2026-10-09T16:06:30Z"],
                ],
            ],
        ]
    ]

    private struct Options {
        var summary: JSONValue = AntigravityUsageLimitsTests.summary
        /// Per-host quota summaries; hosts not listed answer `summary`.
        var summaryByHost: [String: JSONValue] = [:]
        var models: JSONValue = ["models": [:]]
        var summaryStatus = 200
        var summaryStatusByHost: [String: Int] = [:]
        var tokenStatus = 200
        var refreshToken: String? = "refresh-a"
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_791_000_000)
    }

    private struct Fixture {
        var probe: AntigravityUsageProbe
        var profile: AntigravityProfile
        var http: UsageFetchStub
        var clock: Clock
        var directory: URL

        func writeToken(_ refreshToken: String) throws {
            let token: JSONValue = [
                "client_id": "client-id", "client_secret": "client-secret", "refresh_token": .string(refreshToken),
                "project_id": "project-id",
            ]
            try Data(token.compactJSON.utf8).write(to: profile.tokenFile)
        }

        var tokenRequests: Int { http.requests(endingWith: "/token").count }
    }

    private func fixture(_ options: Options = Options()) throws -> Fixture {
        let directory = try acpTemporaryDirectory()
        let profile = AntigravityProfile(geminiHome: directory.appendingPathComponent("profile"), userHome: directory)
        try FileManager.default.createDirectory(at: profile.acpDirectory, withIntermediateDirectories: true)
        let http = UsageFetchStub { request in
            let url = request.url?.absoluteString ?? ""
            let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(request.timeoutInterval == 10)
            if url == "https://oauth2.googleapis.com/token" {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
                let form = URLComponents(string: "?" + body)?.queryItems ?? []
                #expect(form.first { $0.name == "grant_type" }?.value == "refresh_token")
                #expect(form.first { $0.name == "client_secret" }?.value == "client-secret")
                return UsageFetchStub.json(["access_token": "access-token", "expires_in": 3600], status: options.tokenStatus)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("antigravity/hub/1.0.0 (aidev_client; os_type=darwin; arch=") == true)
            #expect(JSONValue.parse(body) == ["project": "project-id"])
            let host = request.url?.host() ?? ""
            if url.hasSuffix(":retrieveUserQuotaSummary") {
                return UsageFetchStub.json(
                    options.summaryByHost[host] ?? options.summary, status: options.summaryStatusByHost[host] ?? options.summaryStatus)
            }
            return UsageFetchStub.json(options.models)
        }
        let clock = Clock()
        let probe = AntigravityUsageProbe(fetch: http.fetch, now: { clock.now })
        let fixture = Fixture(probe: probe, profile: profile, http: http, clock: clock, directory: directory)
        if let refreshToken = options.refreshToken { try fixture.writeToken(refreshToken) }
        return fixture
    }

    @Test func reportsSeparateGeminiAndSharedClaudeAndGPTFiveHourAndWeeklyLimits() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let limits = try #require(await fixture.probe.read(fixture.profile).limits)
        #expect(limits.windows.count == 4)
        #expect(limits.checkedAt == fixture.clock.now)
        let byID = Dictionary(uniqueKeysWithValues: limits.windows.map { ($0.id, $0) })
        #expect(abs((byID["gemini-weekly"]?.usedPercent ?? 0) - 4) < 1e-9)
        #expect(abs((byID["gemini-5h"]?.usedPercent ?? 0) - 9) < 1e-9)
        #expect(
            byID["3p-weekly"]
                == UsageLimitWindow(
                    id: "3p-weekly", kind: .weekly, label: "Claude & GPT (shared) · Weekly", usedPercent: 100,
                    resetsAt: Date(timeIntervalSince1970: 1_791_646_102), durationMinutes: 10_080))
        #expect(byID["3p-5h"]?.kind == .session)
        #expect(byID["3p-5h"]?.durationMinutes == 300)
        #expect(byID["3p-5h"]?.label == "Claude & GPT (shared) · 5-hour")
        #expect(abs((byID["3p-5h"]?.usedPercent ?? 0) - 56) < 1e-9)
        // Session windows come first.
        #expect(limits.windows.map(\.kind) == [.session, .session, .weekly, .weekly])

        // The access token is reused; both endpoints are asked each time.
        _ = await fixture.probe.read(fixture.profile)
        #expect(fixture.tokenRequests == 1)
        #expect(fixture.http.requests(endingWith: ":retrieveUserQuotaSummary").count == 4)
        #expect(Set(fixture.http.requests.compactMap { $0.url?.host() }) == [
            "oauth2.googleapis.com", "daily-cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com",
        ])
    }

    @Test func mergesQuotaGroupsThatOnlyOneEndpointReports() async throws {
        var options = Options()
        // The daily endpoint can omit Gemini while the other returns every group.
        options.summaryByHost["daily-cloudcode-pa.googleapis.com"] = [
            "groups": [
                [
                    "displayName": "Claude and GPT models",
                    "buckets": [
                        ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.5],
                        ["bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.3],
                    ],
                ]
            ]
        ]
        let fixture = try fixture(options)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let limits = try #require(await fixture.probe.read(fixture.profile).limits)
        #expect(limits.windows.map(\.id).sorted() == ["3p-5h", "3p-weekly", "gemini-5h", "gemini-weekly"])
        let byID = Dictionary(uniqueKeysWithValues: limits.windows.map { ($0.id, $0) })
        #expect(byID["gemini-weekly"]?.label == "Gemini · Weekly")
        // Each window as the endpoint that used most of it reports it.
        #expect(abs((byID["3p-5h"]?.usedPercent ?? 0) - 70) < 1e-9)
        #expect(byID["3p-5h"]?.resetsAt == nil)
        #expect(byID["3p-weekly"]?.usedPercent == 100)
    }

    @Test func keepsOneEndpointsQuotasWhenTheOtherFails() async throws {
        var options = Options()
        options.summaryStatusByHost["daily-cloudcode-pa.googleapis.com"] = 503
        let fixture = try fixture(options)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(await fixture.probe.read(fixture.profile).limits?.windows.count == 4)
    }

    @Test func rereadsChangedCredentialsAndDropsTheAccessTokenAfterSignOut() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = await fixture.probe.read(fixture.profile)
        try fixture.writeToken("refresh-b")
        _ = await fixture.probe.read(fixture.profile)
        #expect(fixture.tokenRequests == 2)
        try FileManager.default.removeItem(at: fixture.profile.tokenFile)
        #expect(await fixture.probe.read(fixture.profile) == .unsupported)
        try fixture.writeToken("refresh-b")
        _ = await fixture.probe.read(fixture.profile)
        #expect(fixture.tokenRequests == 3)
        fixture.probe.clear()
        _ = await fixture.probe.read(fixture.profile)
        #expect(fixture.tokenRequests == 4)
        // A token is refreshed again a minute before it expires.
        fixture.clock.now = fixture.clock.now.addingTimeInterval(3_600 - 61)
        _ = await fixture.probe.read(fixture.profile)
        #expect(fixture.tokenRequests == 4)
        fixture.clock.now = fixture.clock.now.addingTimeInterval(2)
        _ = await fixture.probe.read(fixture.profile)
        #expect(fixture.tokenRequests == 5)
    }

    @Test func aCheckRunningDuringClearDoesNotKeepItsAccessToken() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = Gate()
        // Holds the refresh answer until the test has cleared the probe.
        let probe = AntigravityUsageProbe(
            fetch: { request in
                let answer = try await fixture.http.fetch(request)
                if request.url?.absoluteString.hasSuffix("/token") == true { await gate.wait() }
                return answer
            }, now: { fixture.clock.now })
        let running = Task { await probe.read(fixture.profile) }
        while fixture.tokenRequests == 0 { try await Task.sleep(for: .milliseconds(5)) }
        probe.clear()
        gate.open()
        #expect(await running.value.limits?.windows.count == 4)
        _ = await probe.read(fixture.profile)
        #expect(fixture.tokenRequests == 2)
    }

    @Test func fallsBackToModelQuotasWithoutInventingAWindowLength() async throws {
        var options = Options()
        options.summaryStatus = 404
        options.models = [
            "models": [
                "gemini-a": ["modelProvider": "MODEL_PROVIDER_GOOGLE", "quotaInfo": ["remainingFraction": 0.8, "resetTime": "2026-10-10T12:00:00Z"]],
                "gemini-b": ["modelProvider": "MODEL_PROVIDER_GOOGLE", "quotaInfo": ["remainingFraction": 0.6, "resetTime": "2026-10-10T12:00:00Z"]],
                "claude-a": ["quotaInfo": ["remainingFraction": 0.2]],
                "other-model": ["quotaInfo": ["remainingFraction": 0.1]],
            ]
        ]
        let fixture = try fixture(options)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let limits = try #require(await fixture.probe.read(fixture.profile).limits)
        #expect(limits.windows.count == 2)
        let gemini = limits.windows.first { $0.id == "gemini-quota" }
        #expect(gemini?.usedPercent == 40)
        #expect(gemini?.label == "Gemini · Reported quota")
        #expect(gemini?.resetsAt == Date(timeIntervalSince1970: 1_791_633_600))
        #expect(limits.windows.first { $0.id == "claude-quota" }.map { abs($0.usedPercent - 80) < 1e-9 } == true)
        #expect(limits.windows.allSatisfy { $0.kind == .other && $0.durationMinutes == nil })
        #expect(fixture.http.requests(endingWith: ":fetchAvailableModels").count == 2)
    }

    @Test func weeklyModelQuotasAreWeekly() throws {
        let windows = try #require(
            AntigravityUsageLimits.windows(fromModels: [
                "models": ["gpt-x": ["modelProvider": "MODEL_PROVIDER_OPENAI", "weeklyQuotaInfo": ["remainingFraction": 0.25]]]
            ]))
        #expect(windows == [UsageLimitWindow(id: "gpt-weekly", kind: .weekly, label: "GPT · Weekly", usedPercent: 75, durationMinutes: 10_080)])
        #expect(AntigravityUsageLimits.windows(fromModels: ["models": ["a": ["quotaInfo": "x"]]]) == nil)
        #expect(AntigravityUsageLimits.windows(fromModels: [:]) == nil)
    }

    @Test func skipsDisabledAndMissingFractionsAndClampsValidPercentages() async throws {
        var options = Options()
        options.summary = [
            "buckets": [
                ["bucketId": "disabled", "remainingFraction": 0, "disabled": true],
                ["bucketId": "missing", "resetTime": "2026-10-10T12:00:00Z"],
                ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 2, "resetTime": "invalid"],
            ]
        ]
        let fixture = try fixture(options)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(
            await fixture.probe.read(fixture.profile).limits?.windows == [
                UsageLimitWindow(id: "gemini-5h", kind: .session, label: "Gemini · 5-hour", usedPercent: 0, durationMinutes: 300)
            ])
    }

    @Test func namesOtherBucketsAfterTheirGroup() throws {
        let windows = try #require(
            AntigravityUsageLimits.windows(fromSummary: [
                "groups": [
                    ["displayName": " Agent ", "buckets": [["bucketId": "agent-daily", "displayName": "Daily", "remainingFraction": 0.5]]],
                    ["buckets": [["bucketId": "plain", "remainingFraction": 1]]],
                ]
            ]))
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        #expect(byID["agent-daily"]?.label == "Agent · Daily")
        #expect(byID["agent-daily"]?.kind == .other)
        #expect(byID["plain"]?.label == "plain · Quota")
        // A bucket of another shape discards the whole answer, as T3's schema does.
        #expect(AntigravityUsageLimits.windows(fromSummary: ["buckets": [["remainingFraction": 1]]]) == nil)
        #expect(AntigravityUsageLimits.windows(fromSummary: ["buckets": [["bucketId": "a", "disabled": "yes"]]]) == nil)
        #expect(AntigravityUsageLimits.windows(fromSummary: ["groups": "x"]) == nil)
    }

    @Test func failsSafelyWhenTheOAuthRefreshFails() async throws {
        var options = Options()
        options.tokenStatus = 401
        let fixture = try fixture(options)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let outcome = await fixture.probe.read(fixture.profile)
        #expect(outcome == .failed)
        #expect(!String(describing: outcome).contains("client-secret"))
        // Nothing is asked for quotas without an access token.
        #expect(fixture.http.requests.count == 1)
    }

    @Test func failsWhenNeitherEndpointReportsQuotas() async throws {
        var options = Options()
        options.summary = ["groups": []]
        let fixture = try fixture(options)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(await fixture.probe.read(fixture.profile) == .failed)
        #expect(fixture.http.requests(endingWith: ":fetchAvailableModels").count == 2)
    }

    @Test func makesNoRequestsForAMissingOrMalformedSignIn() async throws {
        var options = Options()
        options.refreshToken = nil
        let fixture = try fixture(options)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(await fixture.probe.read(fixture.profile) == .unsupported)
        for contents in ["{}", "not json", #"{"client_id":"a","client_secret":"b","refresh_token":""}"#,
            #"{"client_id":"a","client_secret":"b","refresh_token":"c","project_id":7}"#]
        {
            try Data(contents.utf8).write(to: fixture.profile.tokenFile)
            #expect(await fixture.probe.read(fixture.profile) == .failed, "\(contents)")
        }
        #expect(fixture.http.requests.isEmpty)
    }

    @Test func secretsTravelOnlyInTheBodyOrHeaders() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = await fixture.probe.read(fixture.profile)
        for request in fixture.http.requests {
            let url = request.url?.absoluteString ?? ""
            for secret in ["client-secret", "refresh-a", "access-token"] { #expect(!url.contains(secret)) }
        }
        let body = AntigravityUsageLimits.formBody([("a b", "x+y&z=1/é")])
        #expect(String(decoding: body, as: UTF8.self) == "a+b=x%2By%26z%3D1%2F%C3%A9")
        // A project id is sent only when the token names one.
        let request = AntigravityUsageLimits.quotaRequest(endpoint: "https://e.example", operation: "op", accessToken: "t", projectID: "")
        #expect(request.httpBody.flatMap(JSONValue.parse) == [:])
        #expect(request.url?.absoluteString == "https://e.example/v1internal:op")
    }
}

/// The instants usage checks read (`UsageLimitsOutcome.resolved(after:)` is tested with #5's helpers).
struct UsageLimitDatesTests {
    @Test func readsRFC3339InstantsStrictly() {
        #expect(UsageLimitDates.instant("2026-09-18T03:10:30.159171+00:00") == Date(timeIntervalSince1970: 1_789_701_030.159))
        #expect(UsageLimitDates.instant("2024-02-29T23:59:59.999-05:30") == Date(timeIntervalSince1970: 1_709_270_999.999))
        #expect(UsageLimitDates.instant("2026-09-18T24:00Z") == Date(timeIntervalSince1970: 1_789_776_000))
        #expect(UsageLimitDates.instant("2026-10-01T00:00Z") == Date(timeIntervalSince1970: 1_790_812_800))
        #expect(UsageLimitDates.instant("+002026-10-01T00:00:00Z") == Date(timeIntervalSince1970: 1_790_812_800))
        for text in [
            "invalid", " 2026-10-01T00:00:00Z", "2026-10-01T00:00:00Z ", "2026-10-01", "2026-10-01T00:00:00", "2025-02-29T00:00:00Z",
            "2026-04-31T00:00:00Z", "2026-13-01T00:00:00Z", "2026-10-01T24:01Z", "2026-10-01T00:00:00+24:00", "2026-١٠-01T00:00:00Z",
        ] {
            #expect(UsageLimitDates.instant(text) == nil, "\(text)")
        }
    }
}

/// Serves `https://start.invalid/` as a redirect to `https://elsewhere.invalid/` without any network, recording the
/// hosts asked.
final class RedirectingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: [String] = []

    static var hosts: [String] { lock.withLock { asked } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        Self.lock.withLock { Self.asked.append(host) }
        if host == "start.invalid" {
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://elsewhere.invalid/"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://elsewhere.invalid/")!), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        } else {
            client?.urlProtocol(
                self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("followed".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct UsageLimitsHTTPTests {
    @Test func neverFollowsARedirectWithTheToken() async throws {
        let configuration = UsageLimitsHTTP.configuration
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let request = UsageLimitsHTTP.request(URL(string: "https://start.invalid/")!, token: "secret", timeout: 10)
        let (_, response) = try await UsageLimitsHTTP.fetch(configuration: configuration)(request)
        #expect(response.statusCode == 302)
        #expect(!RedirectingURLProtocol.hosts.contains("elsewhere.invalid"))
    }

    @Test func keepsNoCookiesOrCache() {
        let configuration = UsageLimitsHTTP.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }
}

/// How detection and running sessions report Grok's and Antigravity's limits.
@MainActor
struct ACPUsageLimitsReportingTests {
    private static let loggedIn = """
        You are logged in with grok.com.

        Available models:
          * grok-4.6 (default)

        """

    /// A stand-in `grok` that answers `--version` and `models`.
    private func fakeGrok(in directory: URL) throws -> URL {
        let script = directory.appendingPathComponent("grok")
        try """
            #!/bin/sh
            case "$1" in
              --version) echo 'grok 1.0.67'; exit 0 ;;
              models) cat <<'EOF'
            \(Self.loggedIn)
            EOF
              exit 0 ;;
            esac
            exit 3
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Reads files only inside `root`; everything else (such as `/etc/grok`) does not exist.
    private func readInside(_ root: URL) -> @Sendable (URL) throws -> Data? {
        { url in url.path.hasPrefix(root.path + "/") ? try readFileIfPresent(url) : nil }
    }

    @Test func detectionShowsGrokLimitsAndKeepsThemThroughAFailedCheckOfTheSameAccount() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grok = try fakeGrok(in: directory)
        let home = directory.appendingPathComponent("home/.grok")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        func signIn(_ email: String) throws {
            try Data(#"{"https://accounts.x.ai/sign-in":{"auth_mode":"session","email":"\#(email)","key":"session-token"}}"#.utf8)
                .write(to: home.appendingPathComponent("auth.json"))
        }
        try signIn("me@example.com")
        let environment = ["PATH": "/usr/bin:/bin", "HOME": directory.appendingPathComponent("home").path]
        let http = UsageFetchStub { _ in UsageFetchStub.json(["config": ["creditUsagePercent": 37]]) }
        let provider = ACPProvider(profile: .grok) { GrokFlavor(usage: GrokUsageLimits.Reader(readFile: self.readInside(directory), fetch: http.fetch)) }

        let status = await provider.detect(executable: grok, environment: environment)
        #expect(status.state == .ready)
        #expect(status.account == "me@example.com")
        #expect(status.usageLimits?.windows.map(\.usedPercent) == [37])

        http.answer { _ in (503, "") }
        let failed = await provider.detect(executable: grok, environment: environment)
        #expect(failed.usageLimits == status.usageLimits)

        // Another account starts afresh.
        try signIn("other@example.com")
        #expect(await provider.detect(executable: grok, environment: environment).usageLimits == nil)
        http.answer { _ in UsageFetchStub.json(["config": ["creditUsagePercent": 5]]) }
        #expect(await provider.detect(executable: grok, environment: environment).usageLimits?.windows.map(\.usedPercent) == [5])

        // An API key has no plan limits to read, and nothing is asked.
        let requests = http.requests.count
        var withKey = environment
        withKey["XAI_API_KEY"] = "xai-key"
        let keyed = await provider.detect(executable: grok, environment: withKey)
        #expect(keyed.state == .ready)
        #expect(keyed.usageLimits == nil)
        #expect(http.requests.count == requests)
        // Nor does a failure bring back what an earlier sign-in read.
        http.answer { _ in (503, "") }
        #expect(await provider.detect(executable: grok, environment: environment).usageLimits == nil)
    }

    @Test func detectionShowsAntigravityLimitsOnlyWhenSignedIn() async throws {
        let http = UsageFetchStub { request in
            if request.url?.absoluteString.hasSuffix("/token") == true {
                return UsageFetchStub.json(["access_token": "access-token", "expires_in": 3600])
            }
            return UsageFetchStub.json([
                "buckets": [["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.25]]
            ])
        }
        let flavor = try acpAntigravityFlavor(usage: AntigravityUsageProbe(fetch: http.fetch))
        let server = flavor.paths.dataDirectory.appendingPathComponent("bin/agy_acp_server.par")
        try FileManager.default.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
        for file in [server, AntigravityFlavor.harnessURL(for: server)] {
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let provider = ACPProvider(profile: .antigravity) { flavor }

        let signedOut = await provider.detect(executable: server, environment: [:])
        #expect(signedOut.state == .notAuthenticated)
        #expect(signedOut.usageLimits == nil)
        #expect(http.requests.isEmpty)

        try FileManager.default.createDirectory(at: flavor.profile.acpDirectory, withIntermediateDirectories: true)
        try Data(#"{"client_id":"c","client_secret":"s","refresh_token":"r"}"#.utf8).write(to: flavor.profile.tokenFile)
        let ready = await provider.detect(executable: server, environment: [:])
        #expect(ready.state == .ready)
        #expect(
            ready.usageLimits?.windows == [
                UsageLimitWindow(id: "gemini-weekly", kind: .weekly, label: "Gemini · Weekly", usedPercent: 75, durationMinutes: 10_080)
            ])
        // Without a project the quota requests name none.
        #expect(http.requests(endingWith: ":retrieveUserQuotaSummary").allSatisfy { $0.httpBody.flatMap(JSONValue.parse) == [:] })
    }

    @Test func aSessionReportsTheLimitsWhenItStartsAndAtMostEveryFiveMinutes() async throws {
        let agent = ACPFakeAgent()
        let http = UsageFetchStub { _ in UsageFetchStub.json(["config": ["creditUsagePercent": 64]]) }
        let flavor = GrokFlavor(
            usage: GrokUsageLimits.Reader(readFile: { _ in nil }, fetch: http.fetch))
        let launch = acpLaunch(environment: ["GROK_AUTH": #"{"https://accounts.x.ai/sign-in":{"key":"session-token"}}"#])
        let session = ACPSession(launch: launch, flavor: flavor, transport: agent.factory)
        let log = ACPEventLog()
        log.attach(session)
        defer { session.shutdown() }
        try await session.start()
        await acpWaitUntil("usage limits") { log.events.contains { if case .rateLimits = $0 { true } else { false } } }
        let reported = log.events.compactMap { if case .rateLimits(let windows) = $0 { windows } else { nil } }
        #expect(reported == [[UsageLimitWindow(id: "subscription", kind: .other, label: "Subscription", usedPercent: 64)]])

        // A turn moments later does not read them again.
        try await session.send(acpTurn("hi"))
        await acpWaitUntil("prompt") { agent.lastPromptID != nil }
        agent.finishPrompt()
        await acpWaitUntil("turn") { log.completions.count == 1 }
        await acpSettle()
        #expect(http.requests.count == 1)
        #expect(ACPSession.usageLimitsInterval == 5 * 60)
    }

    @Test func aSessionWithoutLimitsToReadReportsNone() async throws {
        let agent = ACPFakeAgent()
        let session = ACPSession(launch: acpLaunch(), flavor: GrokFlavor(usage: .offline), transport: agent.factory)
        let log = ACPEventLog()
        log.attach(session)
        defer { session.shutdown() }
        try await session.start()
        await acpSettle()
        #expect(!log.events.contains { if case .rateLimits = $0 { true } else { false } })
    }
}
