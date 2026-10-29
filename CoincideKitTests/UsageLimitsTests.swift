import Foundation
import Testing

@testable import CoincideKit

struct UsageLimitsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        _ id: String, _ used: Double, kind: UsageLimitWindow.Kind = .session, resetsIn: TimeInterval? = nil, minutes: Int? = nil
    ) -> UsageLimitWindow {
        UsageLimitWindow(
            id: id, kind: kind, label: kind == .session ? "Session" : "Weekly", usedPercent: used,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, durationMinutes: minutes)
    }

    @Test func windowsAreOrderedSessionFirstAndPercentagesClamped() {
        let limits = UsageLimits(
            windows: [
                UsageLimitWindow(id: "m", kind: .monthly, label: "Monthly", usedPercent: 140),
                window("w", 30, kind: .weekly), window("s", -5),
                UsageLimitWindow(id: "o", kind: .other, label: "Other", usedPercent: .nan),
            ], checkedAt: now)
        #expect(limits.windows.map(\.id) == ["s", "w", "m", "o"])
        #expect(limits.windows.map(\.usedPercent) == [0, 30, 100, 0])
        #expect(limits.windows.map(\.remainingPercent) == [100, 70, 0, 100])
    }

    @Test func aPartialReportReplacesOnlyTheWindowsItNames() {
        let limits = UsageLimits(
            windows: [window("s", 10, resetsIn: 3_600, minutes: 300), window("w", 50, kind: .weekly)], checkedAt: now)
        // A report without a reset time or length keeps the ones known.
        let updated = limits.applying([window("s", 25)], at: now.addingTimeInterval(30))
        #expect(updated.windows.map(\.usedPercent) == [25, 50])
        #expect(updated.windows[0].resetsAt == now.addingTimeInterval(3_600))
        #expect(updated.windows[0].durationMinutes == 300)
        #expect(updated.checkedAt == now.addingTimeInterval(30))
        // An older report does not move the time back.
        #expect(updated.applying([window("w", 60, kind: .weekly)], at: now).checkedAt == now.addingTimeInterval(30))
    }

    @Test func aWindowWhoseResetPassedStartsOver() {
        let limits = UsageLimits(windows: [window("s", 100, resetsIn: -60), window("w", 80, kind: .weekly, resetsIn: 600)], checkedAt: now)
        let current = limits.current(at: now)
        #expect(current.windows.map(\.usedPercent) == [0, 80])
        #expect(current.windows[0].resetsAt == nil)
        #expect(current.windows[1].resetsAt == now.addingTimeInterval(600))
    }

    @Test func theWarningIsAboutTheLimitThatHoldsWorkUpLongest() {
        let calm = UsageLimits(windows: [window("s", 89), window("w", 40, kind: .weekly)], checkedAt: now)
        #expect(calm.warning == nil)
        let near = UsageLimits(windows: [window("s", 91), window("w", 96, kind: .weekly)], checkedAt: now)
        #expect(near.warning?.id == "w")
        // Every exhausted window must reset before work goes on: the latest reset is the one that counts.
        let reached = UsageLimits(
            windows: [window("s", 100, resetsIn: 600), window("w", 100, kind: .weekly, resetsIn: 86_400)], checkedAt: now)
        #expect(reached.warning?.id == "w")
    }

    @Test func warningsSayHowMuchIsUsedAndWhenItResets() {
        let near = window("w", 92.6, kind: .weekly, resetsIn: 2 * 86_400 + 3 * 3_600 + 59)
        #expect(
            UsageLimits.warningText(for: near, provider: .codex, at: now)
                == "92% of your Codex weekly limit is used. It resets in 2d 3h.")
        let reached = window("s", 100, resetsIn: 90 * 60)
        #expect(
            UsageLimits.warningText(for: reached, provider: .claude, at: now)
                == "Claude Code usage limit reached. The session limit resets in 1h 30m.")
        #expect(UsageLimits.warningText(for: window("s", 100), provider: .claude, at: now) == "Claude Code usage limit reached.")
        // Dismissing lasts until the window resets or reaches its limit.
        #expect(UsageLimits.warningKey(for: near, provider: .codex) != UsageLimits.warningKey(for: window("w", 100, kind: .weekly, resetsIn: 2 * 86_400 + 3 * 3_600 + 59), provider: .codex))
        #expect(UsageLimits.warningKey(for: near, provider: .codex) == UsageLimits.warningKey(for: window("w", 95, kind: .weekly, resetsIn: 2 * 86_400 + 3 * 3_600 + 59), provider: .codex))
    }

    @Test func warningsSayWhatIsLeftWhenUsageShowsWhatIsLeft() {
        let near = window("w", 92.6, kind: .weekly, resetsIn: 2 * 86_400 + 3 * 3_600 + 59)
        #expect(
            UsageLimits.warningText(for: near, provider: .codex, mode: .remaining, at: now)
                == "8% of your Codex weekly limit is left. It resets in 2d 3h.")
        #expect(UsageLimits.warningText(for: window("s", 99.7), provider: .claude, mode: .remaining, at: now) == "1% of your Claude Code session limit is left.")
        // Used and left add up to 100 in the two modes.
        #expect(UsageLimits.warningText(for: window("s", 99.7), provider: .claude, mode: .used, at: now) == "99% of your Claude Code session limit is used.")
        // A reached limit reads the same in both.
        let reached = window("s", 100, resetsIn: 90 * 60)
        #expect(
            UsageLimits.warningText(for: reached, provider: .claude, mode: .remaining, at: now)
                == UsageLimits.warningText(for: reached, provider: .claude, at: now))
    }

    @Test func aLimitPassedOnCreditsWarnsWithoutStoppingWork() {
        var weekly = window("w", 100, kind: .weekly, resetsIn: 5 * 86_400 + 5 * 3_600)
        weekly.continuesOnCredits = true
        #expect(!weekly.blocksWork)
        #expect(
            UsageLimits.warningText(for: weekly, provider: .codex, at: now)
                == "Codex weekly limit reached. Using credits until it resets in 5d 5h.")
        #expect(
            UsageLimits.warningKey(for: weekly, provider: .codex)
                != UsageLimits.warningKey(for: window("w", 100, kind: .weekly, resetsIn: 5 * 86_400 + 5 * 3_600), provider: .codex))
        // A window that stops work is the one to warn about, even if the credit-backed one resets later.
        let limits = UsageLimits(windows: [window("s", 100, resetsIn: 600), weekly], checkedAt: now)
        #expect(limits.warning?.id == "s")
        #expect(UsageLimits(windows: [weekly], checkedAt: now).warning?.id == "w")
    }

    @Test func resetCountdownsRoundDownLikeT3() {
        #expect(UsageLimitWindow.duration(2 * 86_400 + 5 * 3_600 + 1_800) == "2d 5h")
        #expect(UsageLimitWindow.duration(4 * 3_600 + 10 * 60 + 59) == "4h 10m")
        #expect(UsageLimitWindow.duration(12 * 60 + 30) == "12m")
        #expect(UsageLimitWindow.duration(-5) == "0m")
        #expect(window("s", 1, resetsIn: 7_260).resetDescription(at: now) == "resets in 2h 1m")
        #expect(window("s", 1, resetsIn: 30).resetDescription(at: now) == "resets momentarily")
        #expect(window("s", 1, resetsIn: -1).resetDescription(at: now) == "resets now")
        #expect(window("s", 1).resetDescription(at: now) == nil)
    }

    @Test func paceComparesSpendingWithTheTimePassed() {
        // A five-hour window with an hour left: 80% of it has passed.
        let ahead = window("s", 90, resetsIn: 3_600, minutes: 300)
        #expect(ahead.elapsedShare(at: now) == 0.8)
        #expect(ahead.pace(at: now) == .ahead)
        #expect(window("s", 78, resetsIn: 3_600, minutes: 300).pace(at: now) == .onPace)
        #expect(window("s", 40, resetsIn: 3_600, minutes: 300).pace(at: now) == .under)
        // Without a length or reset time there is no pace.
        #expect(window("s", 40, resetsIn: 3_600).pace(at: now) == nil)
        #expect(window("s", 40, minutes: 300).pace(at: now) == nil)
    }

    @Test func theSummaryListsEveryWindow() {
        let limits = UsageLimits(windows: [window("s", 38, resetsIn: 7_500), window("w", 20, kind: .weekly)], checkedAt: now)
        #expect(limits.summary(at: now) == "Session: 62% left, resets in 2h 5m. Weekly: 80% left")
    }
}

// MARK: - Provider usage checks

struct UsageLimitsOutcomeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Blocks the thread, deaf to cancellation, then returns 1.
    private static func block(for seconds: TimeInterval) -> Int {
        Thread.sleep(forTimeInterval: seconds)
        return 1
    }

    @Test func aFailedReadKeepsTheLastLimitsLikeT3() {
        let previous = UsageLimits(
            windows: [UsageLimitWindow(id: "m", kind: .monthly, label: "Monthly", usedPercent: 40)], checkedAt: now)
        let fresh = UsageLimits(
            windows: [UsageLimitWindow(id: "m", kind: .monthly, label: "Monthly", usedPercent: 45)], checkedAt: now)
        #expect(UsageLimitsOutcome.limits(fresh).resolved(after: previous) == fresh)
        #expect(UsageLimitsOutcome.failed.resolved(after: previous) == previous)
        #expect(UsageLimitsOutcome.failed.resolved(after: nil) == nil)
        // A setup without limits (signed out, an API key) drops what an earlier check read.
        #expect(UsageLimitsOutcome.unsupported.resolved(after: previous) == nil)
    }

    @Test func aTimeoutStopsWaitingWithoutWaitingForTheWork() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: UsageLimitsTimeout.self) {
            // Work that ignores cancellation, like a Keychain read waiting on the user.
            try await usageLimitsWithTimeout(.milliseconds(50)) { Self.block(for: 1) }
        }
        #expect(clock.now - start < .milliseconds(900))
        #expect(try await usageLimitsWithTimeout(.seconds(5)) { 7 } == 7)
        await #expect(throws: URLError.self) {
            try await usageLimitsWithTimeout(.seconds(5)) { () async throws -> Int in throw URLError(.timedOut) }
        }
    }

    @Test func aMissingFileReadsAsNothingButOtherFailuresThrow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try readFileIfPresent(directory.appending(path: "missing.json")) == nil)
        #expect(try readFileIfPresent(directory.appending(path: "missing/auth.json")) == nil)
        try Data("{}".utf8).write(to: directory.appending(path: "auth.json"))
        #expect(try readFileIfPresent(directory.appending(path: "auth.json")) == Data("{}".utf8))
        #expect(throws: (any Error).self) { try readFileIfPresent(directory) }
    }
}

/// Answers usage requests in tests and records them, so nothing reaches the network.
final class UsageFetchStub: @unchecked Sendable {
    typealias Answer = @Sendable (URLRequest) throws -> (status: Int, body: String)

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var answer: Answer

    init(_ answer: @escaping Answer) {
        self.answer = answer
    }

    /// Answers every later request with `answer`.
    func answer(with answer: @escaping Answer) {
        lock.withLock { self.answer = answer }
    }

    /// A 200 (or `status`) answer with `value` as its body.
    static func json(_ value: JSONValue, status: Int = 200) -> (status: Int, body: String) {
        (status, value.compactJSON)
    }

    /// A stub that fails the test when anything is requested.
    static func unused() -> UsageFetchStub {
        UsageFetchStub { request in
            Issue.record("unexpected usage request to \(request.url?.absoluteString ?? "")")
            throw URLError(.cancelled)
        }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func requests(endingWith suffix: String) -> [URLRequest] {
        requests.filter { $0.url?.absoluteString.hasSuffix(suffix) == true }
    }

    /// The bearer tokens of the requests, in order.
    var tokens: [String] {
        requests.map { ($0.value(forHTTPHeaderField: "Authorization") ?? "").replacing("Bearer ", with: "") }
    }

    var fetch: UsageLimitsFetch {
        { request in
            let answer = self.lock.withLock {
                self.recorded.append(request)
                return self.answer
            }
            let (status, body) = try answer(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"), statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), response)
        }
    }
}

/// Values tests collect from `@Sendable` closures.
final class UsageTestLog<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) { lock.withLock { stored.append(value) } }

    var values: [Value] { lock.withLock { stored } }
}
