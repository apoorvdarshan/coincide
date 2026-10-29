import Foundation
import Testing
@testable import CoincideKit

/// The highest balance Coincide has seen for each bare balance (one with no total), which its bar measures against.
@MainActor
struct UsageBalanceMarksTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("balance-marks-\(UUID())")
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theFirstSightingIsTheMark() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let marks = UsageBalanceMarks(directory: directory)
        #expect(marks.mark(.codex, account: "default", figure: UsageBalanceMarks.creditsID) == nil)
        let mark = marks.observe(40_120, provider: .codex, account: "default", figure: UsageBalanceMarks.creditsID, at: start)
        #expect(mark == UsageBalanceMark(highest: 40_120, seenAt: start))
    }

    @Test func spendingKeepsTheMarkAndATopUpStartsANewOne() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let marks = UsageBalanceMarks(directory: directory)
        let id = UsageBalanceMarks.creditsID
        marks.observe(40_120, provider: .codex, account: "default", figure: id, at: start)
        let spent = try #require(
            marks.observe(39_547.01, provider: .codex, account: "default", figure: id, at: start.addingTimeInterval(3_600)))
        #expect(spent.highest == 40_120 && spent.seenAt == start && spent.last == 39_547.01)
        // The same balance again keeps the mark.
        let same = try #require(marks.observe(39_547.01, provider: .codex, account: "default", figure: id, at: start.addingTimeInterval(7_200)))
        #expect(same.highest == 40_120 && same.seenAt == start)
        let toppedUp = start.addingTimeInterval(86_400)
        let topUp = try #require(marks.observe(50_000, provider: .codex, account: "default", figure: id, at: toppedUp))
        #expect(topUp == UsageBalanceMark(highest: 50_000, seenAt: toppedUp))
        // A top-up that leaves the balance under the old mark starts a new one too: what was spent since the old mark
        // would no longer be the mark less the balance.
        marks.observe(10, provider: .codex, account: "default", figure: id, at: toppedUp.addingTimeInterval(60))
        let partial = toppedUp.addingTimeInterval(120)
        #expect(marks.observe(30, provider: .codex, account: "default", figure: id, at: partial) == UsageBalanceMark(highest: 30, seenAt: partial))
    }

    @Test func theMarkFollowsTheLastSighting() {
        let mark = UsageBalanceMark(highest: 100, seenAt: start, last: 90)
        let later = start.addingTimeInterval(60)
        #expect(UsageBalanceMark.updated(mark, balance: 80, at: later) == UsageBalanceMark(highest: 100, seenAt: start, last: 80))
        #expect(UsageBalanceMark.updated(mark, balance: 90, at: later) == mark)
        #expect(UsageBalanceMark.updated(mark, balance: 95, at: later) == UsageBalanceMark(highest: 95, seenAt: later))
        #expect(UsageBalanceMark.updated(mark, balance: 120, at: later) == UsageBalanceMark(highest: 120, seenAt: later))
        #expect(UsageBalanceMark.updated(nil, balance: -5, at: later) == UsageBalanceMark(highest: -5, seenAt: later))
        #expect(UsageBalanceMark.updated(UsageBalanceMark(highest: .nan, seenAt: start), balance: 3, at: later).highest == 3)
    }

    @Test func eachAccountAndFigureKeepsItsOwnMark() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let marks = UsageBalanceMarks(directory: directory)
        let id = UsageBalanceMarks.creditsID
        marks.observe(100, provider: .codex, account: "default", figure: id, at: start)
        marks.observe(500, provider: .codex, account: "work", figure: id, at: start)
        marks.observe(7, provider: .claude, account: "default", figure: id, at: start)
        marks.observe(9, provider: .codex, account: "default", figure: "balance", at: start)
        marks.observe(50, provider: .codex, account: "work", figure: id, at: start.addingTimeInterval(60))
        #expect(marks.mark(.codex, account: "default", figure: id)?.highest == 100)
        #expect(marks.mark(.codex, account: "work", figure: id)?.highest == 500)
        #expect(marks.mark(.claude, account: "default", figure: id)?.highest == 7)
        #expect(marks.mark(.codex, account: "default", figure: "balance")?.highest == 9)
    }

    @Test func marksSurviveAReloadAndUnreadableOnesStartOver() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let marks = UsageBalanceMarks(directory: directory)
        marks.observe(40_120, provider: .codex, account: "default", figure: UsageBalanceMarks.creditsID, at: start)
        marks.observe(39_000, provider: .codex, account: "default", figure: UsageBalanceMarks.creditsID, at: start.addingTimeInterval(60))
        marks.flush()
        let reopened = UsageBalanceMarks(directory: directory)
        #expect(
            reopened.mark(.codex, account: "default", figure: UsageBalanceMarks.creditsID)
                == UsageBalanceMark(highest: 40_120, seenAt: start, last: 39_000))
        let text = try String(contentsOf: directory.appendingPathComponent("usage-balance-marks.json"), encoding: .utf8)
        #expect(text.contains("codex/default#@credits"))

        // A file from before `last` was kept reads it as the mark.
        let older = #"{"codex/default#@credits":{"highest":5,"seenAt":"2026-10-29T00:00:00Z"}}"#
        try Data(older.utf8).write(to: directory.appendingPathComponent("usage-balance-marks.json"))
        #expect(UsageBalanceMarks(directory: directory).mark(.codex, account: "default", figure: UsageBalanceMarks.creditsID)?.last == 5)

        try Data("{not json".utf8).write(to: directory.appendingPathComponent("usage-balance-marks.json"))
        #expect(UsageBalanceMarks(directory: directory).marks.isEmpty)
    }

    @Test func onlyBalancesWithoutATotalAreTracked() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let limits = UsageLimits(
            windows: [], checkedAt: start, credits: UsageCredits(hasCredits: true, unlimited: false, balance: " 39547.01 "),
            figures: [
                UsageFigure(id: "balance", label: "Balance", unit: .currency("USD"), remaining: 12.5),
                UsageFigure(id: "grant", label: "Grant", unit: .credits, remaining: 300),
                UsageFigure(id: "key_limit", label: "Key credit limit", unit: .currency("USD"), limit: 20, remaining: 5),
                UsageFigure(id: "usage", label: "Spent in total", unit: .currency("USD"), used: 3),
                UsageFigure(id: "reset_credits", label: "Limit resets available", unit: .count, remaining: 2),
                UsageFigure(id: "ratelimit_requests", label: "Requests", unit: .requests, remaining: 48),
                UsageFigure(id: "off", label: "Extra usage", unit: .currency("USD"), detail: "Off"),
            ])
        #expect(UsageBalanceMarks.bareBalances(limits).map(\.id) == [UsageBalanceMarks.creditsID, "balance", "grant"])
        let marks = UsageBalanceMarks(directory: directory)
        let seen = marks.observe(limits, provider: .codex, account: "default", at: start)
        #expect(seen[UsageBalanceMarks.creditsID]?.highest == 39_547.01)
        #expect(seen["balance"]?.highest == 12.5)
        #expect(seen["grant"]?.highest == 300)
        #expect(seen.count == 3)

        for credits in [
            UsageCredits(hasCredits: true, unlimited: true, balance: "10"), UsageCredits(hasCredits: true, unlimited: false),
            UsageCredits(hasCredits: true, unlimited: false, balance: "lots"), UsageCredits(hasCredits: true, unlimited: false, balance: "inf"),
        ] {
            #expect(UsageBalanceMarks.bareBalances(UsageLimits(windows: [], checkedAt: start, credits: credits)).isEmpty)
        }
    }

    @Test func aNonFiniteBalanceLeavesTheMarkAlone() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let marks = UsageBalanceMarks(directory: directory)
        marks.observe(10, provider: .codex, account: "default", figure: "balance", at: start)
        #expect(marks.observe(.infinity, provider: .codex, account: "default", figure: "balance", at: start)?.highest == 10)
        #expect(marks.observe(.nan, provider: .codex, account: "other", figure: "balance", at: start) == nil)
    }
}
