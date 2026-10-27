import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// The find bar's search over a thread: what it finds, in which field, and which match is current.
struct TranscriptFindTests {
    private let user = TranscriptItem(kind: .user, text: "Fix the Login bug")
    private let reply = TranscriptItem(kind: .assistant, text: "**Login** works now. Try login again.")
    private let tool = TranscriptItem(kind: .tool, text: "Login passed", title: "Run tests", detail: "swift test --filter LoginTests", category: .command)
    private let thought = TranscriptItem(kind: .reasoning, text: "Thinking about login")
    private let notice = TranscriptItem(kind: .notice, text: "Switched agents\nsecond line about login")

    private var items: [TranscriptItem] { [user, reply, tool, thought, notice] }

    private func search(
        _ finder: TranscriptFinder, _ query: String, in items: [TranscriptItem]? = nil, revisions: [UUID: Int] = [:],
        showReasoning: Bool = true, keepingCurrent: Bool = false, from start: UUID? = nil, cache: TranscriptTextCache = TranscriptTextCache()
    ) {
        finder.search(
            query, in: items ?? self.items, revisions: revisions, showReasoning: showReasoning, textCache: cache,
            keepingCurrent: keepingCurrent, from: start)
    }

    @Test func matchesFollowTranscriptOrderAndIgnoreCase() {
        let finder = TranscriptFinder()
        search(finder, "login")
        #expect(finder.matches.map(\.itemID) == [user.id, reply.id, reply.id, tool.id, tool.id, thought.id])
        #expect(finder.matches.map(\.field) == [.body, .body, .body, .detail, .detail, .body])
        // Ranges are in the rendered text, without the Markdown syntax.
        #expect(finder.matches[1].range == NSRange(location: 0, length: 5))
        #expect(finder.matches[2].range == NSRange(location: 21, length: 5))
        #expect(finder.currentIndex == 0)
        #expect(!finder.isTruncated)
    }

    @Test func toolTitlesAreSearchedAndNoticesOnlyByTheirFirstLine() {
        let finder = TranscriptFinder()
        search(finder, "run tests")
        #expect(finder.matches.map(\.field) == [.title])
        #expect(finder.matches.first?.range == NSRange(location: 0, length: 9))
        search(finder, "switched")
        #expect(finder.matches.map(\.itemID) == [notice.id])
        search(finder, "second line")
        #expect(finder.matches.isEmpty)
    }

    @Test func hiddenThoughtsAreNotSearched() {
        let finder = TranscriptFinder()
        search(finder, "thinking", showReasoning: false)
        #expect(finder.matches.isEmpty)
        #expect(finder.currentIndex == nil)
        search(finder, "thinking", showReasoning: true)
        #expect(finder.matches.map(\.itemID) == [thought.id])
    }

    @Test func steppingWrapsAroundBothWays() {
        let finder = TranscriptFinder()
        search(finder, "login")
        finder.step(-1)
        #expect(finder.currentIndex == 5)
        finder.step(1)
        #expect(finder.currentIndex == 0)
        finder.step(1)
        finder.step(1)
        #expect(finder.current == finder.matches[2])
        let empty = TranscriptFinder()
        empty.step(1)
        #expect(empty.currentIndex == nil)
    }

    @Test func searchingStartsFromTheFirstItemOnScreen() {
        let finder = TranscriptFinder()
        search(finder, "login", from: tool.id)
        #expect(finder.current?.itemID == tool.id)
        // Past the last match, it wraps to the first.
        search(finder, "login", from: notice.id)
        #expect(finder.currentIndex == 0)
        search(finder, "login", from: UUID())
        #expect(finder.currentIndex == 0)
    }

    @Test func theCurrentMatchStaysWhileOutputStreamsIn() {
        let finder = TranscriptFinder()
        let cache = TranscriptTextCache()
        search(finder, "login", cache: cache)
        finder.step(1)
        finder.step(1)
        let current = finder.current
        #expect(current?.itemID == reply.id)
        // The reply grows; an earlier item gains a match too.
        var grown = items
        grown[1].text += " And login once more."
        grown[0].text = "Login: fix the Login bug"
        search(finder, "login", in: grown, revisions: [reply.id: 1, user.id: 1], keepingCurrent: true, cache: cache)
        #expect(finder.current == current)
        #expect(finder.matches.count == 8)
        // A new query starts over.
        search(finder, "logi", in: grown, revisions: [reply.id: 1, user.id: 1], keepingCurrent: true, cache: cache)
        #expect(finder.currentIndex == 0)
    }

    @Test func aMatchThatWentAwayHandsOverToTheNextOneInItsItem() {
        let finder = TranscriptFinder()
        search(finder, "login")
        finder.step(1)
        finder.step(1)
        #expect(finder.current?.itemID == reply.id)
        var shrunk = items
        shrunk[1].text = "Nothing here"
        search(finder, "login", in: shrunk, revisions: [reply.id: 1], keepingCurrent: true)
        #expect(finder.current?.itemID == tool.id)
    }

    @Test func highlightsBelongToTheirRow() throws {
        let finder = TranscriptFinder()
        search(finder, "login")
        let replyHighlights = try #require(finder.highlights(for: reply.id))
        #expect(replyHighlights.matches.count == 2)
        #expect(replyHighlights.current == nil)
        #expect(replyHighlights.ranges(in: .body) == [NSRange(location: 0, length: 5), NSRange(location: 21, length: 5)])
        #expect(replyHighlights.ranges(in: .title).isEmpty)
        let userHighlights = try #require(finder.highlights(for: user.id))
        #expect(userHighlights.currentRange(in: .body) == NSRange(location: 8, length: 5))
        #expect(userHighlights.currentRange(in: .detail) == nil)
        #expect(finder.highlights(for: notice.id) == nil)
    }

    @Test func queriesAreTrimmedAndCappedAndAnEmptyOneFindsNothing() {
        let finder = TranscriptFinder()
        search(finder, "   login\n")
        #expect(finder.query == "login")
        search(finder, String(repeating: "x", count: 500))
        #expect(finder.query.count == TranscriptFinder.maxQueryLength)
        search(finder, "  ")
        #expect(finder.matches.isEmpty && finder.currentIndex == nil)
        search(finder, "login")
        finder.reset()
        #expect(finder.query.isEmpty && finder.matches.isEmpty && finder.current == nil)
    }

    @Test func manyMatchesStopAtTheLimit() {
        let finder = TranscriptFinder()
        let long = TranscriptItem(kind: .assistant, text: String(repeating: "ab ", count: TranscriptFinder.matchLimit + 10))
        let later = TranscriptItem(kind: .user, text: "ab")
        search(finder, "ab", in: [long, later])
        #expect(finder.matches.count == TranscriptFinder.matchLimit)
        #expect(finder.isTruncated)
        #expect(finder.highlights(for: later.id) == nil)
    }

    @Test func caseIsIgnoredButAccentsAreNot() {
        #expect(TranscriptFinder.ranges(of: "CAFE", in: "cafe Café") == [NSRange(location: 0, length: 4)])
        #expect(TranscriptFinder.ranges(of: "aa", in: "aaaaa") == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
        #expect(TranscriptFinder.ranges(of: "x", in: "") == [])
        #expect(TranscriptFinder.words(of: "log-in, now!") == ["log", "in", "now"])
    }

    @Test func searchableSourcesNameUntitledWork() {
        let untitled = TranscriptItem(kind: .tool, text: "out", detail: "ls", category: .read)
        #expect(TranscriptFindText.sources(of: untitled) == ["Read file", "ls", "out"])
        let approval = TranscriptItem(kind: .approval, detail: "rm -rf build", category: .command)
        #expect(TranscriptFindText.sources(of: approval) == ["Command approval", "rm -rf build"])
        let question = TranscriptItem(kind: .question, questions: UserInputRequest(id: "q", questions: [UserQuestion(id: "a", prompt: "Which database?")]))
        #expect(TranscriptFindText.sources(of: question) == ["Which database?"])
    }

    @Test func labelsHighlightEveryMatchAndTheCurrentOneInYellow() {
        let text = NSAttributedString(string: "one two one")
        let highlighted = TranscriptFindStyle.highlight(
            text, ranges: [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3), NSRange(location: 10, length: 5)],
            current: NSRange(location: 8, length: 3))
        #expect(highlighted.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor === TranscriptFindStyle.match)
        #expect(highlighted.attribute(.backgroundColor, at: 8, effectiveRange: nil) as? NSColor == TranscriptFindStyle.current)
        #expect(highlighted.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor == TranscriptFindStyle.currentText)
        #expect(highlighted.attribute(.backgroundColor, at: 4, effectiveRange: nil) == nil)
        // Nothing to highlight leaves the text as it is.
        #expect(TranscriptFindStyle.highlight(text, ranges: [], current: nil) === text)
    }
}
