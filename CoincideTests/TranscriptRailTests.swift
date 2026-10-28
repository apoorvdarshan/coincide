import CoincideKit
import Foundation
import Testing

@testable import Coincide

/// Items in order, each a second after the last.
private struct RailThread {
    var items: [TranscriptItem] = []

    @discardableResult
    mutating func add(_ kind: TranscriptItem.Kind, _ provider: ProviderKind?, status: ItemStatus? = nil) -> UUID {
        let createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + TimeInterval(items.count))
        let item = TranscriptItem(
            kind: kind, text: "text", title: kind == .tool ? "Run" : nil, category: kind == .tool ? .command : nil, status: status,
            provider: provider, createdAt: createdAt, completedAt: status == nil ? nil : createdAt)
        items.append(item)
        return item.id
    }

    func rails(running: ProviderKind? = nil, runningTurn: UUID? = nil) -> (rows: [TranscriptRow], rails: [TranscriptRowID: TranscriptRail]) {
        var builder = TranscriptBuilder(items: items)
        builder.runningTurnID = runningTurn
        builder.runningProvider = running
        let rows = builder.build()
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return (rows, TranscriptRail.rails(for: rows, provider: { byID[$0]?.provider }, runningProvider: running))
    }
}

struct TranscriptRailTests {
    @Test func spacersHaveNoRail() {
        var thread = RailThread()
        thread.add(.user, .claude)
        let (rows, rails) = thread.rails()
        #expect(rails[.header] == nil)
        #expect(rails[.footer] == nil)
        #expect(rows.count == 3)
    }

    @Test func eachTurnRingsTheMessageAndShowsTheAgentWhereItAnswers() {
        var thread = RailThread()
        let user = thread.add(.user, .claude)
        thread.add(.tool, .claude, status: .completed)
        let reply = thread.add(.assistant, .claude, status: .completed)
        let (_, rails) = thread.rails()
        #expect(rails[.item(user)] == TranscriptRail(top: .claude, bottom: .claude, node: .message, continuesUp: false))
        // The folded work's header is where Claude starts answering.
        #expect(rails[.turnHeader(user)]?.node == .agent(.claude))
        #expect(rails[.item(reply)] == TranscriptRail(top: .claude, bottom: .claude, continuesDown: false))
    }

    @Test func aReplyWithoutWorkShowsTheAgentOnItself() {
        var thread = RailThread()
        thread.add(.user, .codex)
        let reply = thread.add(.assistant, .codex, status: .completed)
        let (_, rails) = thread.rails()
        #expect(rails[.item(reply)]?.node == .agent(.codex))
    }

    @Test func theLineBlendsIntoTheNextAgentThroughTheMessageThatSwitchesTo() {
        var thread = RailThread()
        thread.add(.user, .claude)
        let first = thread.add(.assistant, .claude, status: .completed)
        let second = thread.add(.user, .codex)
        let reply = thread.add(.assistant, .codex, status: .completed)
        let third = thread.add(.user, .codex)
        thread.add(.assistant, .codex, status: .completed)
        let (_, rails) = thread.rails()
        #expect(rails[.item(first)]?.bottom == .claude)
        #expect(rails[.item(second)].map { [$0.top, $0.bottom] } == [.claude, .codex])
        #expect(rails[.item(reply)]?.node == .agent(.codex))
        // The same agent again: one color, and its logo still marks where it answers.
        #expect(rails[.item(third)].map { [$0.top, $0.bottom] } == [.codex, .codex])
    }

    @Test func aRunningTurnEndsInTheLiveDot() {
        var thread = RailThread()
        let user = thread.add(.user, .cursor)
        let (rows, rails) = thread.rails(running: .cursor, runningTurn: user)
        #expect(rows.contains { $0.id == .live })
        #expect(rails[.turnHeader(user)]?.node == .agent(.cursor))
        #expect(rails[.live] == TranscriptRail(top: .cursor, bottom: .cursor, node: .live(.cursor), continuesDown: false))
        #expect(rails[.turnHeader(user)]?.continuesDown == true)
    }

    @Test func rowsWithoutAnAgentFollowTheRowBefore() {
        var thread = RailThread()
        thread.add(.user, .opencode)
        let notice = thread.add(.notice, nil)
        let reply = thread.add(.assistant, .opencode, status: .completed)
        let (_, rails) = thread.rails()
        #expect(rails[.item(notice)]?.bottom == .opencode)
        #expect(rails[.item(notice)]?.node == TranscriptRail.Node.none)
        #expect(rails[.item(reply)]?.node == .agent(.opencode))
    }
}
