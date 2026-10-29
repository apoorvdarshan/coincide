import Foundation
import Testing

@testable import CoincideKit

/// Synthetic Claude Code and Codex logs (never real ones): parsing, the incremental cache, cost estimates, per-account
/// figures and the menu bar's choice of window.
struct UsageInsightsTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-insights-\(UUID())")

    // MARK: Fixtures

    private static func claudeLine(
        id: String, request: String = "req_1", session: String = "s-1", model: String = "claude-opus-5-5", at time: String,
        input: Int = 10, read: Int = 1_000, write: Int = 200, writeLong: Int = 50, output: Int, thinking: Int = 0
    ) -> String {
        """
        {"parentUuid":null,"isSidechain":false,"type":"assistant","timestamp":"\(time)","sessionId":"\(session)","requestId":"\(request)","message":{"id":"\(id)","model":"\(model)","role":"assistant","content":[{"type":"text","text":"usage is \\"fine\\""}],"usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(write),"cache_read_input_tokens":\(read),"output_tokens":\(output),"output_tokens_details":{"thinking_tokens":\(thinking)},"cache_creation":{"ephemeral_5m_input_tokens":\(write - writeLong),"ephemeral_1h_input_tokens":\(writeLong)}}}}
        """
    }

    private static let claudeUserLine = """
        {"type":"user","timestamp":"2026-10-20T10:00:00.000Z","sessionId":"s-1","message":{"role":"user","content":"what is my usage?"}}
        """

    private static func codexMeta(id: String, originator: String, at time: String, forkedFrom: String? = nil) -> String {
        let fork = forkedFrom.map { #","forked_from_id":"\#($0)""# } ?? ""
        return """
            {"timestamp":"\(time)","type":"session_meta","payload":{"id":"\(id)","timestamp":"\(time)","cwd":"/tmp","originator":"\(originator)"\(fork)}}
            """
    }

    private static func codexTurn(model: String, at time: String) -> String {
        #"{"timestamp":"\#(time)","type":"turn_context","payload":{"turn_id":"t","model":"\#(model)"}}"#
    }

    private static func codexCount(at time: String, input: Int, cached: Int, output: Int, reasoning: Int, last: Int) -> String {
        """
        {"timestamp":"\(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(input + output)},"last_token_usage":{"input_tokens":\(last),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\(last)},"model_context_window":272000}}}
        """
    }

    private func write(_ lines: [String], to name: String, trailingNewline: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8).write(to: url)
        return url
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    private func claudeSource(_ account: String = "default", folder: String = "claude") -> UsageLogSource {
        UsageLogSource(provider: .claude, accountID: account, roots: [directory.appendingPathComponent(folder)])
    }

    private func codexSource(_ account: String = "default") -> UsageLogSource {
        UsageLogSource(provider: .codex, accountID: account, roots: [directory.appendingPathComponent("codex")])
    }

    // MARK: Claude Code

    @Test func claudeLinesOfOneResponseCountOnceWithTheirLargestCounts() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try write(
            [
                Self.claudeUserLine,
                // One response logged per content block, its output growing.
                Self.claudeLine(id: "msg_a", at: "2026-10-20T10:00:01.000Z", output: 5),
                Self.claudeLine(id: "msg_a", at: "2026-10-20T10:00:02.500Z", output: 40, thinking: 12),
                Self.claudeLine(id: "msg_b", request: "req_2", at: "2026-10-20T10:01:00.000Z", input: 3, output: 7),
                // Claude Code's own placeholder reply costs nothing.
                Self.claudeLine(id: "msg_c", request: "req_3", model: "<synthetic>", at: "2026-10-20T10:02:00.000Z", output: 0),
                "not json at all",
            ], to: "claude/-Users-me-project/s-1.jsonl")
        // A resumed session's copy of the first response, in another file.
        _ = try write(
            [Self.claudeLine(id: "msg_a", session: "s-2", at: "2026-10-20T11:00:00.000Z", output: 40, thinking: 12)],
            to: "claude/-Users-me-project/s-2.jsonl")
        let scan = UsageLogScanner(cacheFile: directory.appendingPathComponent("cache.plist")).scan([claudeSource()])
        #expect(scan.filesRead == 2)
        let events = UsageEvents.fromLogs(scan.sessions, owners: [:])
        #expect(events.count == 2)
        let first = try #require(events.first { $0.tokens.output == 40 })
        #expect(first.tokens == TokenTotals(input: 10, cacheRead: 1_000, cacheWrite: 200, cacheWriteLong: 50, output: 40, reasoning: 12))
        #expect(first.promptTokens == 1_210)
        #expect(first.model == "claude-opus-5-5")
        #expect(first.date == Date(timeIntervalSince1970: 1_792_490_401))
        #expect(events.allSatisfy { !$0.isFromCoincide })
    }

    @Test func claudeSessionsOfCoincideThreadsCarryTheirProject() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try write([Self.claudeLine(id: "msg_a", session: "mine", at: "2026-10-20T10:00:01.000Z", output: 5)], to: "claude/p/mine.jsonl")
        _ = try write([Self.claudeLine(id: "msg_b", session: "other", at: "2026-10-20T10:00:01.000Z", output: 5)], to: "claude/p/other.jsonl")
        let project = UUID()
        let scan = UsageLogScanner(cacheFile: directory.appendingPathComponent("cache.plist")).scan([claudeSource()])
        let events = UsageEvents.fromLogs(scan.sessions, owners: [.claude: ["mine": .init(projectID: project)]])
        let mine = try #require(events.first { $0.isFromCoincide })
        #expect(mine.projectID == project)
        #expect(events.filter(\.isFromCoincide).count == 1)
    }

    // MARK: Codex

    @Test func codexRequestsAreTheGrowthOfItsRunningTotals() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try write(
            [
                Self.codexMeta(id: "thread-1", originator: "coincide", at: "2026-10-20T09:00:00.000Z"),
                Self.codexTurn(model: "gpt-6.1-sol", at: "2026-10-20T09:00:01.000Z"),
                Self.codexCount(at: "2026-10-20T09:00:05.000Z", input: 1_000, cached: 600, output: 100, reasoning: 40, last: 1_000),
                // Codex repeats unchanged totals.
                Self.codexCount(at: "2026-10-20T09:00:06.000Z", input: 1_000, cached: 600, output: 100, reasoning: 40, last: 1_000),
                Self.codexTurn(model: "gpt-6-luna", at: "2026-10-20T09:01:00.000Z"),
                Self.codexCount(at: "2026-10-20T09:01:05.000Z", input: 3_000, cached: 2_000, output: 250, reasoning: 90, last: 2_000),
            ], to: "codex/2026/10/20/rollout-1.jsonl")
        let scan = UsageLogScanner(cacheFile: directory.appendingPathComponent("cache.plist")).scan([codexSource()])
        let session = try #require(scan.sessions.first)
        #expect(session.sessionID == "thread-1")
        #expect(session.originator == "coincide")
        #expect(session.requests.map(\.model) == ["gpt-6.1-sol", "gpt-6-luna"])
        #expect(session.requests[0].tokens == TokenTotals(input: 400, cacheRead: 600, output: 100, reasoning: 40))
        #expect(session.requests[1].tokens == TokenTotals(input: 600, cacheRead: 1_400, output: 150, reasoning: 50))
        #expect(session.requests[1].promptTokens == 2_000)
        // Codex says Coincide started the session, though no thread holds its id.
        #expect(UsageEvents.fromLogs(scan.sessions, owners: [:]).allSatisfy { $0.isFromCoincide })
    }

    @Test func aForksCopyOfItsParentsHistoryIsNotCountedAgain() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try write(
            [
                Self.codexMeta(id: "fork", originator: "codex-tui", at: "2026-10-20T12:00:00.000Z", forkedFrom: "parent"),
                Self.codexMeta(id: "parent", originator: "codex-tui", at: "2026-10-20T08:00:00.000Z"),
                Self.codexTurn(model: "gpt-6.1-sol", at: "2026-10-20T08:00:01.000Z"),
                Self.codexCount(at: "2026-10-20T08:00:05.000Z", input: 5_000, cached: 0, output: 500, reasoning: 0, last: 5_000),
                Self.codexCount(at: "2026-10-20T12:00:05.000Z", input: 5_400, cached: 0, output: 520, reasoning: 0, last: 400),
            ], to: "codex/rollout-fork.jsonl")
        let scan = UsageLogScanner(cacheFile: directory.appendingPathComponent("cache.plist")).scan([codexSource()])
        let session = try #require(scan.sessions.first)
        #expect(session.sessionID == "fork")
        #expect(session.requests.map(\.tokens) == [TokenTotals(input: 400, output: 20)])
    }

    // MARK: Cache

    @Test func theCacheReadsOnlyWhatWasAppended() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache.plist")
        let log = try write(
            [Self.claudeLine(id: "msg_a", at: "2026-10-20T10:00:01.000Z", output: 5)], to: "claude/p/s-1.jsonl")
        let first = UsageLogScanner(cacheFile: cache).scan([claudeSource()])
        #expect(first.filesRead == 1)
        // Nothing changed: a new scanner reads the cache file, not the log.
        let again = UsageLogScanner(cacheFile: cache).scan([claudeSource()])
        #expect(again.filesRead == 0)
        #expect(again.sessions.flatMap(\.requests).count == 1)

        let before = try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int ?? 0
        let added = Self.claudeLine(id: "msg_b", request: "req_2", at: "2026-10-20T10:05:00.000Z", output: 9)
        try append([added], to: log)
        let scanner = UsageLogScanner(cacheFile: cache)
        let grown = scanner.scan([claudeSource()])
        #expect(grown.filesRead == 1)
        #expect(grown.bytesRead == Int64(added.utf8.count + 1))
        #expect(grown.sessions.flatMap(\.requests).map(\.tokens.output) == [5, 9])
        #expect(before > 0)

        // A line still being written is left for the next scan.
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        let partial = Self.claudeLine(id: "msg_c", request: "req_3", at: "2026-10-20T10:06:00.000Z", output: 2)
        try handle.write(contentsOf: Data(partial.prefix(40).utf8))
        let midLine = scanner.scan([claudeSource()])
        #expect(midLine.sessions.flatMap(\.requests).count == 2)
        try handle.write(contentsOf: Data((partial.dropFirst(40) + "\n").utf8))
        try handle.close()
        #expect(scanner.scan([claudeSource()]).sessions.flatMap(\.requests).map(\.tokens.output) == [5, 9, 2])
    }

    @Test func aRewrittenLogIsReadAgainFromTheStart() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache.plist")
        let scanner = UsageLogScanner(cacheFile: cache)
        _ = try write([Self.claudeLine(id: "msg_a", at: "2026-10-20T10:00:01.000Z", output: 5)], to: "claude/p/s.jsonl")
        _ = scanner.scan([claudeSource()])
        // Replaced by a longer, different log: resuming at the old offset would land mid-line.
        _ = try write(
            [Self.claudeLine(id: "msg_x", at: "2026-10-21T10:00:01.000Z", input: 1_234_567, output: 77)], to: "claude/p/s.jsonl")
        let scan = scanner.scan([claudeSource()])
        #expect(scan.sessions.flatMap(\.requests).map(\.tokens.output) == [77])
        // A removed log leaves the results.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("claude/p/s.jsonl"))
        #expect(scanner.scan([claudeSource()]).sessions.isEmpty)
    }

    // MARK: Accounts

    @Test func accountsKeepTheirOwnFigures() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // The same response id in two accounts' logs is two responses.
        _ = try write([Self.claudeLine(id: "msg_a", at: "2026-10-20T10:00:01.000Z", output: 5)], to: "home/projects/p/s.jsonl")
        _ = try write([Self.claudeLine(id: "msg_a", at: "2026-10-20T10:00:01.000Z", output: 8)], to: "work/projects/p/s.jsonl")
        let sources = [
            UsageLogSource(provider: .claude, accountID: "default", roots: [directory.appendingPathComponent("home/projects")]),
            UsageLogSource(provider: .claude, accountID: "work", roots: [directory.appendingPathComponent("work/projects")]),
        ]
        let scan = UsageLogScanner(cacheFile: directory.appendingPathComponent("cache.plist")).scan(sources)
        let events = UsageEvents.fromLogs(scan.sessions, owners: [:])
        #expect(events.count == 2)
        #expect(events.first { $0.accountID == "work" }?.tokens.output == 8)
        #expect(events.first { $0.accountID == "default" }?.tokens.output == 5)

        let now = Date(timeIntervalSince1970: 1_792_500_000)
        let work = UsageReport.make(events.filter { $0.accountID == "work" }, periodDays: 7, now: now)
        #expect(work.period.tokens.output == 8)
    }

    @Test func turnsCountForProvidersWhoseLogsAreNotRead() {
        let now = Date()
        func record(_ provider: ProviderKind, account: String?, totals: TokenTotals?) -> UsageRecord {
            UsageRecord(
                id: UUID(), threadID: UUID(), projectID: UUID(), provider: provider, accountID: account, modelID: "m",
                startedAt: now.addingTimeInterval(-5), finishedAt: now, outcome: .completed,
                usage: TokenUsage(inputTokens: 50_000, turnTotals: totals))
        }
        let totals = TokenTotals(input: 10, output: 5)
        let events = UsageEvents.fromRecords(
            [
                record(.cursor, account: nil, totals: totals), record(.opencode, account: "zen", totals: totals),
                // Claude's turns are in its logs already; a context snapshot alone is no total.
                record(.claude, account: nil, totals: totals), record(.grok, account: nil, totals: nil),
            ], excluding: UsageInsights.loggedProviders)
        #expect(events.map(\.provider) == [.cursor, .opencode])
        #expect(events.map(\.accountID) == ["default", "zen"])
        #expect(events.allSatisfy { $0.isFromCoincide && $0.tokens == totals })
    }

    @Test func recordsKeepTheirAccountAndTurnTotals() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = UsageRecord(
            id: UUID(), threadID: UUID(), projectID: UUID(), provider: .opencode, accountID: "zen", modelID: "m",
            startedAt: Date(), finishedAt: Date(), outcome: .completed,
            usage: TokenUsage(turnTotals: TokenTotals(input: 3, cacheRead: 4, output: 5)))
        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(UsageRecord.self, from: encoder.encode(record))
        #expect(decoded.accountID == "zen")
        #expect(decoded.usage.turnTotals == TokenTotals(input: 3, cacheRead: 4, output: 5))
        // The default account is stored as nil, as selections store it.
        let fallback = UsageRecord(
            id: UUID(), threadID: UUID(), projectID: UUID(), provider: .cursor, accountID: "default", modelID: nil,
            startedAt: Date(), finishedAt: Date(), outcome: .completed, usage: TokenUsage())
        #expect(fallback.accountID == nil)
    }

    // MARK: Reports

    @Test func reportsSplitTodayTheWeekAndTheMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_792_500_000)  // 2026-10-20 12:40 UTC
        func event(daysAgo: Double, output: Int, provider: ProviderKind = .claude, model: String = "claude-opus-5-5") -> UsageEvent {
            UsageEvent(
                date: now.addingTimeInterval(-daysAgo * 86_400), provider: provider, accountID: "default", model: model,
                tokens: TokenTotals(output: output), isFromCoincide: false)
        }
        let events = [
            event(daysAgo: 0.1, output: 1), event(daysAgo: 3, output: 10), event(daysAgo: 20, output: 100),
            event(daysAgo: 45, output: 1_000), event(daysAgo: 1, output: 7, provider: .cursor, model: "auto"),
        ]
        let report = UsageReport.make(events, periodDays: 90, now: now, calendar: calendar)
        #expect(report.today.tokens.output == 1)
        #expect(report.lastWeek.tokens.output == 18)
        #expect(report.lastMonth.tokens.output == 118)
        #expect(report.period.tokens.output == 1_118)
        // Cursor's "auto" has no list price.
        #expect(report.period.unpricedTokens == 7)
        #expect(report.models.first?.model == "claude-opus-5-5")
        #expect(report.days.count == 5)
        #expect(report.days.first?.day == calendar.startOfDay(for: now.addingTimeInterval(-45 * 86_400)))
    }

    // MARK: Costs

    @Test func costsFollowTheListPrices() throws {
        // Claude Opus 5.5: $4 in, $20 out, $0.20 cache reads, writes at 1.25× and 2× input.
        let opus = try #require(UsagePricing.price(for: "claude-opus-5-5"))
        let tokens = TokenTotals(input: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000, cacheWriteLong: 500_000, output: 1_000_000)
        #expect(abs(opus.cost(of: tokens) - (4 + 0.2 + 0.5 * 5 + 0.5 * 8 + 20)) < 1e-9)
        // Dated, prefixed and dotted ids find their model.
        #expect(UsagePricing.price(for: "claude-sonnet-4-5-20250929") == UsagePricing.price(for: "claude-sonnet-4-5"))
        #expect(UsagePricing.price(for: "anthropic/claude-haiku-4.5") == UsagePricing.price(for: "claude-haiku-4-5"))
        #expect(UsagePricing.price(for: "claude-opus-4-20250514")?.input == 15)
        #expect(UsagePricing.price(for: "claude-opus-4-5")?.input == 5)
        #expect(UsagePricing.price(for: "openai/gpt-5.4-2026-03-05") == UsagePricing.price(for: "gpt-5.4"))
        #expect(UsagePricing.price(for: "auto") == nil)
        #expect(UsagePricing.price(for: "<synthetic>") == nil)

        // Above 272K input, GPT-6.1 Sol bills the whole request at 2× input and 1.5× output.
        let sol = try #require(UsagePricing.price(for: "gpt-6.1-sol"))
        let request = TokenTotals(input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        #expect(abs(sol.cost(of: request) - (2 + 0.1 + 10)) < 1e-9)
        #expect(abs(sol.cost(of: request, longContext: true) - (4 + 0.2 + 15)) < 1e-9)
        let long = UsageEvent(
            date: Date(), provider: .codex, accountID: "default", model: "gpt-6.1-sol", tokens: request, promptTokens: 300_000,
            isFromCoincide: false)
        #expect(abs((long.estimatedCost ?? 0) - (4 + 0.2 + 15)) < 1e-9)
    }

    // MARK: Turn totals

    @Test func acpUsageIsReadWhicheverWayTheAgentCounts() {
        // Everything apart: reasoning joins the output.
        #expect(
            TokenTotals.acp(.object(["inputTokens": 100, "cachedReadTokens": 50, "outputTokens": 20, "thoughtTokens": 5, "totalTokens": 175]))
                == TokenTotals(input: 100, cacheRead: 50, output: 25, reasoning: 5))
        // Input holding the cached tokens, reasoning within the output.
        #expect(
            TokenTotals.acp(.object(["inputTokens": 150, "cachedReadTokens": 50, "outputTokens": 20, "thoughtTokens": 5, "totalTokens": 170]))
                == TokenTotals(input: 100, cacheRead: 50, output: 20, reasoning: 5))
        // Without a total, counts are taken as separate.
        #expect(TokenTotals.acp(.object(["inputTokens": 7, "outputTokens": 3])) == TokenTotals(input: 7, output: 3))
        #expect(TokenTotals.acp(.object([:])) == nil)
        #expect(TokenTotals.openCode(.object(["input": 4, "output": 6, "reasoning": 2, "cache": ["read": 8, "write": 1]]))
            == TokenTotals(input: 4, cacheRead: 8, cacheWrite: 1, output: 8, reasoning: 2))
    }

    // MARK: Limits

    @Test func codexReadsThePlanCreditsAndModelLimits() throws {
        let result = try #require(
            JSONValue.parse(
                """
                {"rateLimits":{"limitId":"codex","primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1800000000}},
                 "rateLimitsByLimitId":{
                   "codex":{"limitId":"codex","planType":"pro","credits":{"hasCredits":true,"unlimited":false,"balance":"1250.5"},
                            "primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1800000000},
                            "secondary":{"usedPercent":12,"windowDurationMins":10080}},
                   "codex-spark":{"limitId":"codex-spark","limitName":"Codex Spark","primary":{"usedPercent":90,"windowDurationMins":300}}}}
                """))
        let limits = CodexUsageLimits.limits(fromRead: result, at: Date(timeIntervalSince1970: 1_799_990_000))
        #expect(limits.windows.map(\.usedPercent) == [40, 12])
        #expect(limits.windows.allSatisfy { $0.continuesOnCredits })
        #expect(limits.plan == "pro")
        #expect(limits.credits == UsageCredits(hasCredits: true, unlimited: false, balance: "1250.5"))
        #expect(limits.modelWindows.map(\.id) == ["codex-spark/primary"])
        #expect(limits.modelWindows.first?.label == "Codex Spark · Session")
        // Model limits never drive the composer's warning.
        #expect(limits.warning == nil)
        // Details survive a report of some windows and a reset.
        let later = limits.applying([UsageLimitWindow(id: "primary", kind: .session, label: "Session", usedPercent: 60)], at: Date())
        #expect(later.plan == "pro" && later.credits != nil && later.modelWindows.count == 1)
        #expect(later.current(at: Date(timeIntervalSince1970: 1_900_000_000)).plan == "pro")
    }

    @MainActor
    @Test func theMenuBarShowsTheWindowClosestToItsLimit() {
        let now = Date()
        func account(_ provider: ProviderKind, _ id: String, _ windows: [UsageLimitWindow], model: [UsageLimitWindow] = [])
            -> UsageInsights.AccountLimits
        {
            UsageInsights.AccountLimits(
                provider: provider, account: ProviderAccount(id: id, provider: provider, name: id), showsAccountName: false,
                status: ProviderStatus(state: .ready),
                limits: UsageLimits(windows: windows, checkedAt: now, modelWindows: model))
        }
        func window(_ id: String, _ used: Double, resetsIn: TimeInterval? = nil) -> UsageLimitWindow {
            UsageLimitWindow(id: id, kind: .session, label: id, usedPercent: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) })
        }
        #expect(UsageInsights.mostConstrained([]) == nil)
        let accounts = [
            account(.claude, "default", [window("session", 40), window("weekly", 71)]),
            account(.codex, "default", [window("session", 12)], model: [window("spark", 88)]),
            account(.codex, "work", [window("session", 88, resetsIn: 7_200)]),
            UsageInsights.AccountLimits(
                provider: .cursor, account: .defaultAccount(for: .cursor), showsAccountName: false,
                status: ProviderStatus(state: .notAuthenticated), limits: nil),
        ]
        let picked = UsageInsights.mostConstrained(accounts)
        // A tie goes to the window that resets last.
        #expect(picked?.window.id == "session")
        #expect(picked?.account.account.id == "work")
        #expect(UsageInsights.mostConstrained(Array(accounts.prefix(2)))?.window.id == "spark")
    }

    @Test func usageSettingsDefaultToOn() throws {
        let defaults = AppSettings()
        #expect(defaults.showsUsageInMenuBar)
        #expect(defaults.usageIncludesOtherSessions)
        // Settings written before these existed read them as on.
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"sendOnReturn":false}"#.utf8))
        #expect(decoded.showsUsageInMenuBar && decoded.usageIncludesOtherSessions)
        var off = defaults
        off.showsUsageInMenuBar = false
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(off))
        #expect(!roundTrip.showsUsageInMenuBar)
    }

    @Test func logTimesAreReadExactly() {
        #expect(UsageLogDates.instant("2026-10-20T10:00:01.250Z") == Date(timeIntervalSince1970: 1_792_490_401.25))
        #expect(UsageLogDates.instant("2026-10-20T10:00:01Z") == Date(timeIntervalSince1970: 1_792_490_401))
        // Other forms go through the general parser.
        #expect(UsageLogDates.instant("2026-10-20T12:00:01+02:00") == Date(timeIntervalSince1970: 1_792_490_401))
        #expect(UsageLogDates.instant("yesterday") == nil)
    }

    @Test func resetCountdownsRoundDown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = UsageLimitWindow(id: "s", kind: .session, label: "Session", usedPercent: 10, resetsAt: now.addingTimeInterval(2 * 3_600 + 14 * 60 + 59))
        #expect(window.resetDescription(at: now) == "resets in 2h 14m")
        #expect(UsageLimitWindow.duration(3 * 86_400 + 5 * 3_600) == "3d 5h")
        #expect(UsageLimitWindow.duration(59) == "0m")
    }
}
