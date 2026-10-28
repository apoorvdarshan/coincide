import CoincideKit
import Foundation
import Testing

@testable import Coincide

/// A thread's transcript written in order, each item a second after the last.
private struct Transcript {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var items: [TranscriptItem] = []

    @discardableResult
    mutating func add(
        _ kind: TranscriptItem.Kind, _ text: String = "text", status: ItemStatus? = nil, category: ToolCategory? = nil,
        provider: ProviderKind? = nil, model: String? = nil, duration: TimeInterval? = nil, steered: Bool = false
    ) -> UUID {
        let createdAt = Self.start.addingTimeInterval(TimeInterval(items.count))
        let item = TranscriptItem(
            kind: kind, text: text, title: kind == .tool ? "Run" : nil, category: category, status: status, provider: provider,
            modelID: model, steered: steered ? true : nil, createdAt: createdAt,
            completedAt: duration.map { createdAt.addingTimeInterval($0) })
        items.append(item)
        return item.id
    }

    subscript(_ id: UUID) -> TranscriptItem { items.first { $0.id == id }! }
}

/// The rows' kinds and ids, without the spacers at either end.
private func layout(_ rows: [TranscriptRow]) -> [TranscriptRow] {
    rows.filter { if case .spacer = $0.kind { false } else { true } }
}

private func kinds(_ rows: [TranscriptRow]) -> [TranscriptRow.Kind] { layout(rows).map(\.kind) }

struct TranscriptBuilderTests {
    @Test func anEmptyThreadHasNoRows() {
        #expect(TranscriptBuilder(items: []).build().isEmpty)
    }

    @Test func spacersFrameTheRowsAndMakeRoomForTheFindBar() {
        var transcript = Transcript()
        transcript.add(.user)
        let rows = TranscriptBuilder(items: transcript.items, topReserve: 40).build()
        #expect(rows.first?.id == .header)
        #expect(rows.first?.kind == .spacer(height: TranscriptMetrics.edgePadding + 40))
        #expect(rows.last?.id == .footer)
        #expect(rows.last?.kind == .spacer(height: TranscriptMetrics.edgePadding))
    }

    // MARK: Finished turns

    @Test func aFinishedTurnFoldsItsWorkUnderWorkedForAboveTheReply() {
        var transcript = Transcript()
        let user = transcript.add(.user, "Fix it")
        transcript.add(.reasoning, "Thinking", duration: 1)
        transcript.add(.tool, status: .completed, category: .read, duration: 1)
        transcript.add(.assistant, "Looking further")
        transcript.add(.tool, status: .completed, category: .command, duration: 30)
        let reply = transcript.add(.assistant, "Done", provider: .claude, model: "opus")
        let rows = layout(TranscriptBuilder(items: transcript.items).build())
        #expect(rows.map(\.id) == [.item(user), .turnHeader(user), .item(reply)])
        // From the message to the latest end among the turn's items: the command finished 4s + 30s in.
        #expect(rows[1].kind == .turnHeader(.worked(duration: 34, isExpanded: false)))
        #expect(rows[2].kind == .assistant(meta: AssistantMeta(provider: .claude, modelID: "opus")))
    }

    @Test func expandingTheTurnShowsItsWorkGroupedIntoRuns() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        let thought = transcript.add(.reasoning, "Thinking")
        let read = transcript.add(.tool, category: .read)
        let interim = transcript.add(.assistant, "Interim")
        let command = transcript.add(.tool, category: .command)
        let reply = transcript.add(.assistant, "Done", provider: .codex)
        let rows = layout(TranscriptBuilder(items: transcript.items, expanded: [.turnHeader(user)]).build())
        #expect(
            rows.map(\.kind) == [
                .user, .turnHeader(.worked(duration: 5, isExpanded: true)),
                .group(itemIDs: [thought, read], isExpanded: false),
                .assistant(meta: nil),
                .tool(isNested: false),
                .assistant(meta: AssistantMeta(provider: .codex, modelID: nil)),
            ])
        #expect(rows.map(\.id) == [.item(user), .turnHeader(user), .group(thought), .item(interim), .item(command), .item(reply)])
    }

    @Test func anExpandedGroupListsItsCallsNestedBelowIt() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        let first = transcript.add(.tool, category: .read)
        let second = transcript.add(.reasoning, "Hmm")
        transcript.add(.assistant, "Done")
        let rows = layout(TranscriptBuilder(items: transcript.items, expanded: [.turnHeader(user), .group(first)]).build())
        #expect(
            Array(rows.map(\.kind)[2...4]) == [
                .group(itemIDs: [first, second], isExpanded: true), .tool(isNested: true), .reasoning(isNested: true),
            ])
        // Work-log rows followed by more work sit closer together.
        #expect(rows.map(\.continuesWork) == [false, false, true, true, false, false])
    }

    @Test func aTurnThatFailedKeepsAllItsWorkInView() {
        var transcript = Transcript()
        transcript.add(.user)
        transcript.add(.tool, category: .command)
        transcript.add(.assistant, "Partial")
        transcript.add(.error, "Rate limited")
        #expect(kinds(TranscriptBuilder(items: transcript.items).build()) == [.user, .tool(isNested: false), .assistant(meta: nil), .error])
    }

    @Test func workAfterTheReplyStaysOnlyWhenItFailed() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        transcript.add(.tool, status: .completed)
        let reply = transcript.add(.assistant, "Done")
        let failed = transcript.add(.tool, status: .failed)
        transcript.add(.tool, status: .completed)
        let rows = layout(TranscriptBuilder(items: transcript.items).build())
        #expect(rows.map(\.id) == [.item(user), .turnHeader(user), .item(reply), .item(failed)])
    }

    @Test func workAfterTheLastReplyOrWithoutOneIsFolded() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        transcript.add(.tool)
        transcript.add(.assistant, "Interim that ended the turn early")
        transcript.add(.tool)
        let reply = transcript.items[2].id
        // The last reply is the turn's answer, even with work after it.
        #expect(layout(TranscriptBuilder(items: transcript.items).build()).map(\.id) == [.item(user), .turnHeader(user), .item(reply)])

        var stopped = Transcript()
        let message = stopped.add(.user)
        stopped.add(.tool)
        stopped.add(.reasoning, "Thought")
        #expect(layout(TranscriptBuilder(items: stopped.items).build()).map(\.id) == [.item(message), .turnHeader(message)])
    }

    @Test func waitingApprovalsPlansAndQuestionsStayInView() {
        var transcript = Transcript()
        transcript.add(.user)
        transcript.add(.approval, status: .declined)
        let waiting = transcript.add(.approval, status: .waiting)
        let plan = transcript.add(.plan, "1. Step")
        let question = transcript.add(.question)
        transcript.add(.tool)
        let rows = layout(TranscriptBuilder(items: transcript.items).build())
        #expect(rows.compactMap(\.itemID).dropFirst() == [waiting, plan, question])
        #expect(rows.map(\.kind).dropFirst(2) == [.approval, .plan, .question])
    }

    @Test func blankRepliesAndHiddenThoughtsAreLeftOut() {
        var transcript = Transcript()
        transcript.add(.user)
        transcript.add(.reasoning, "Considering")
        transcript.add(.assistant, "  \n")
        transcript.add(.plan, "")
        let shown = kinds(TranscriptBuilder(items: transcript.items, showReasoning: true).build())
        // The turn lasts until its last item, shown or not.
        #expect(shown == [.user, .turnHeader(.worked(duration: 3, isExpanded: false))])
        let hidden = kinds(TranscriptBuilder(items: transcript.items, showReasoning: false).build())
        #expect(hidden == [.user])
    }

    @Test func eachUserMessageOpensItsOwnTurn() {
        var transcript = Transcript()
        let first = transcript.add(.user)
        transcript.add(.tool)
        let firstReply = transcript.add(.assistant, "One")
        let second = transcript.add(.user)
        let secondReply = transcript.add(.assistant, "Two")
        let rows = layout(TranscriptBuilder(items: transcript.items).build())
        #expect(rows.map(\.id) == [.item(first), .turnHeader(first), .item(firstReply), .item(second), .item(secondReply)])
        let builder = TranscriptBuilder(items: transcript.items)
        #expect(builder.turnOpener(of: firstReply) == first)
        #expect(builder.turnOpener(of: secondReply) == second)
        #expect(builder.turnOpener(of: UUID()) == nil)
    }

    @Test func itemsBeforeTheFirstMessageHaveNoTurn() {
        var transcript = Transcript()
        let notice = transcript.add(.notice, "Imported")
        let user = transcript.add(.user)
        let rows = layout(TranscriptBuilder(items: transcript.items).build())
        #expect(rows.map(\.id) == [.item(notice), .item(user)])
        #expect(TranscriptBuilder(items: transcript.items).turnOpener(of: notice) == nil)
    }

    @Test func aNoticeOfATurnTheAgentStartedOpensATurnOfItsOwn() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        let reply = transcript.add(.assistant, "Started a background task")
        let notice = transcript.add(.notice, "Claude Code continued on its own.")
        transcript.add(.tool)
        let followUp = transcript.add(.assistant, "The task finished")
        let plain = layout(TranscriptBuilder(items: transcript.items).build())
        #expect(!plain.contains { $0.id == .turnHeader(notice) })
        let rows = layout(TranscriptBuilder(items: transcript.items, agentTurnIDs: [notice]).build())
        #expect(rows.map(\.id) == [.item(user), .item(reply), .item(notice), .turnHeader(notice), .item(followUp)])
        #expect(rows[2].kind == .notice)
    }

    @Test func changedFilesFollowTheReplyOrEndTheTurn() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        transcript.add(.tool, category: .fileChange)
        let reply = transcript.add(.assistant, "Edited")
        let failed = transcript.add(.tool, status: .failed)
        let rows = layout(TranscriptBuilder(items: transcript.items, changedFiles: [user: 7]).build())
        #expect(rows.map(\.id) == [.item(user), .turnHeader(user), .item(reply), .changedFiles(user), .item(failed)])
        #expect(rows[3].kind == .changedFiles(turnID: user))

        var silent = Transcript()
        let message = silent.add(.user)
        silent.add(.tool, category: .fileChange)
        let silentRows = layout(TranscriptBuilder(items: silent.items, changedFiles: [message: 1]).build())
        #expect(silentRows.last?.id == .changedFiles(message))
        // A new change set gives the row a new revision, so its cached height goes.
        let other = layout(TranscriptBuilder(items: silent.items, changedFiles: [message: 2]).build())
        #expect(other.last?.revision != silentRows.last?.revision)
    }

    // MARK: Steered messages

    @Test func aFinishedTurnFoldsTheWorkAfterASteerUnderContinuedFor() {
        var transcript = Transcript()
        let user = transcript.add(.user, "Fix it")
        let before = transcript.add(.tool, status: .completed, category: .read)
        let steer = transcript.add(.user, "Also the docs", steered: true)
        let after = transcript.add(.tool, status: .completed, category: .command, duration: 10)
        let reply = transcript.add(.assistant, "Done, docs too", provider: .claude)
        func rows(_ expanded: Set<TranscriptRowID> = []) -> [TranscriptRow] {
            layout(TranscriptBuilder(items: transcript.items, expanded: expanded, changedFiles: [user: 3]).build())
        }

        // "Worked for" keeps the whole turn's time, to the command's end 3s + 10s in; the work after the steer folds
        // under its own header, timed from the steer. The changed files follow the turn's final reply.
        let collapsed = rows()
        #expect(
            collapsed.map(\.id) == [
                .item(user), .turnHeader(user), .item(steer), .turnHeader(steer), .item(reply), .changedFiles(user),
            ])
        #expect(
            collapsed.map(\.kind) == [
                .user, .turnHeader(.worked(duration: 13, isExpanded: false)), .user,
                .turnHeader(.continued(duration: 11, isExpanded: false)),
                .assistant(meta: AssistantMeta(provider: .claude, modelID: nil)), .changedFiles(turnID: user),
            ])
        // Each header opens its own part.
        #expect(
            rows([.turnHeader(user)]).map(\.id) == [
                .item(user), .turnHeader(user), .item(before), .item(steer), .turnHeader(steer), .item(reply), .changedFiles(user),
            ])
        #expect(
            rows([.turnHeader(steer)]).map(\.id) == [
                .item(user), .turnHeader(user), .item(steer), .turnHeader(steer), .item(after), .item(reply), .changedFiles(user),
            ])
        #expect(rows([.turnHeader(steer)])[3].kind == .turnHeader(.continued(duration: 11, isExpanded: true)))
        #expect(rows()[3].isExpandable)

        let builder = TranscriptBuilder(items: transcript.items)
        #expect(builder.turnOpener(of: reply) == user)
        #expect(builder.turnOpener(of: steer) == user)
        #expect(builder.foldingHeader(of: before) == .turnHeader(user))
        #expect(builder.foldingHeader(of: after) == .turnHeader(steer))
        #expect(builder.foldingHeader(of: UUID()) == nil)
    }

    @Test func aSteerBeforeAnyOutputLeavesTheTurnInOnePart() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        let steer = transcript.add(.user, "Actually, use the other API", steered: true)
        let tool = transcript.add(.tool, status: .completed)
        let reply = transcript.add(.assistant, "Done")
        let builder = TranscriptBuilder(items: transcript.items)
        #expect(layout(builder.build()).map(\.id) == [.item(user), .turnHeader(user), .item(steer), .item(reply)])
        var open = builder
        open.expanded = [.turnHeader(user)]
        #expect(layout(open.build()).map(\.id) == [.item(user), .turnHeader(user), .item(steer), .item(tool), .item(reply)])
        #expect(builder.foldingHeader(of: tool) == .turnHeader(user))
    }

    @Test func steersBackToBackSplitTheWorkOnceAfterTheLast() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        transcript.add(.tool, status: .completed)
        let first = transcript.add(.user, "One more thing", steered: true)
        let second = transcript.add(.user, "And another", steered: true)
        let tool = transcript.add(.tool, status: .completed)
        let reply = transcript.add(.assistant, "Both done")
        let rows = layout(TranscriptBuilder(items: transcript.items).build())
        #expect(rows.map(\.id) == [.item(user), .turnHeader(user), .item(first), .item(second), .turnHeader(second), .item(reply)])
        #expect(rows[4].kind == .turnHeader(.continued(duration: 2, isExpanded: false)))
        #expect(TranscriptBuilder(items: transcript.items).foldingHeader(of: tool) == .turnHeader(second))
    }

    @Test func aPartWithNothingToFoldHasNoContinuedHeader() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        let interim = transcript.add(.assistant, "Starting")
        let steer = transcript.add(.user, "Keep it short", steered: true)
        let reply = transcript.add(.assistant, "Short answer")
        // The reply before the steer folds under the turn's header; the part after it shows only its reply.
        let rows = layout(TranscriptBuilder(items: transcript.items).build())
        #expect(rows.map(\.id) == [.item(user), .turnHeader(user), .item(steer), .item(reply)])
        let open = layout(TranscriptBuilder(items: transcript.items, expanded: [.turnHeader(user)]).build())
        #expect(open.map(\.id) == [.item(user), .turnHeader(user), .item(interim), .item(steer), .item(reply)])
    }

    @Test func aRunningTurnShowsItsSteersLiveUnderWorking() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        let read = transcript.add(.tool, status: .completed, category: .read)
        let steer = transcript.add(.user, "Also check the tests", steered: true)
        let started = Transcript.start.addingTimeInterval(0.5)
        func rows() -> [TranscriptRow] {
            layout(TranscriptBuilder(items: transcript.items, runningTurnID: user, turnStartedAt: started).build())
        }
        // Right after the steer, the live row says the agent is on it.
        #expect(rows().map(\.id) == [.item(user), .turnHeader(user), .item(read), .item(steer), .live])
        #expect(rows()[1].kind == .turnHeader(.working(startedAt: started)))
        #expect(rows()[3].kind == .user)
        // Work after the steer stays live under "Working for…", with nothing folded.
        let command = transcript.add(.tool, status: .running, category: .command)
        #expect(rows().map(\.id) == [.item(user), .turnHeader(user), .item(read), .item(steer), .item(command)])
        #expect(!rows().contains { if case .turnHeader(.worked) = $0.kind { true } else { false } })
    }

    @Test func aSteeredMessageIsMarkedOnlyWhenItWasSteered() {
        var transcript = Transcript()
        let first = transcript.add(.user)
        transcript.add(.assistant, "One")
        let steer = transcript.add(.user, steered: true)
        let next = transcript.add(.user)
        let builder = TranscriptBuilder(items: transcript.items)
        #expect(builder.opensTurn(transcript[first]) && builder.opensTurn(transcript[next]))
        #expect(!builder.opensTurn(transcript[steer]))
        #expect(builder.turnOpener(of: steer) == first)
    }

    @Test func reusingSettledTurnsWithSteersBuildsWhatAFullBuildDoes() {
        var transcript = Transcript()
        var builder = TranscriptBuilder(items: [])
        var settled: TranscriptSettledRows?

        func step(_ changed: Set<UUID>, sourceLocation: SourceLocation = #_sourceLocation) {
            builder.items = transcript.items
            let reused = builder.build(reusing: &settled, changed: changed)
            #expect(reused == builder.build(), sourceLocation: sourceLocation)
        }

        let user = transcript.add(.user)
        builder.runningTurnID = user
        step([user])
        let tool = transcript.add(.tool, status: .completed)
        step([tool])
        let steer = transcript.add(.user, steered: true)
        step([steer])
        let reply = transcript.add(.assistant, "Done")
        step([reply])
        builder.runningTurnID = nil
        step([])
        let next = transcript.add(.user)
        builder.runningTurnID = next
        step([next])
        builder.expanded = [.turnHeader(steer)]
        step([])
    }

    // MARK: Running turns

    @Test func theRunningTurnShowsItsWorkLiveUnderWorking() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        let read = transcript.add(.tool, status: .completed, category: .read)
        let started = Transcript.start.addingTimeInterval(0.5)
        let rows = layout(TranscriptBuilder(items: transcript.items, runningTurnID: user, turnStartedAt: started).build())
        #expect(rows.map(\.id) == [.item(user), .turnHeader(user), .item(read), .live])
        #expect(rows[1].kind == .turnHeader(.working(startedAt: started)))
        #expect(rows[3].kind == .live(.thinking))
    }

    @Test func theLiveRowStepsAsideWhileSomethingAtTheBottomShowsProgress() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        transcript.add(.tool, status: .running)
        #expect(!layout(TranscriptBuilder(items: transcript.items, runningTurnID: user).build()).contains { $0.id == .live })

        var streaming = Transcript()
        let message = streaming.add(.user)
        streaming.add(.assistant, "Writing…", status: .running)
        #expect(!layout(TranscriptBuilder(items: streaming.items, runningTurnID: message).build()).contains { $0.id == .live })

        var asking = Transcript()
        let request = asking.add(.user)
        asking.add(.approval, status: .waiting)
        #expect(!layout(TranscriptBuilder(items: asking.items, runningTurnID: request).build()).contains { $0.id == .live })

        var grouped = Transcript()
        let opener = grouped.add(.user)
        grouped.add(.tool, status: .running)
        grouped.add(.tool, status: .completed)
        #expect(!layout(TranscriptBuilder(items: grouped.items, runningTurnID: opener).build()).contains { $0.id == .live })
    }

    @Test func aStartingTurnSaysWhichAgentIsStarting() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        let rows = layout(TranscriptBuilder(items: transcript.items, runningTurnID: user, isStarting: true, runningProvider: .cursor).build())
        #expect(rows.last?.kind == .live(.starting(.cursor)))
        #expect(rows[1].kind == .turnHeader(.working(startedAt: Transcript.start)))
    }

    @Test func backgroundWorkShowsOnTheLiveLineOnlyBetweenTurns() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        transcript.add(.assistant)
        var builder = TranscriptBuilder(items: transcript.items)
        builder.backgroundWork = (.claude, ["Audit the port"])
        #expect(layout(builder.build()).last?.kind == .live(.background(.claude, titles: ["Audit the port"])))
        builder.runningTurnID = user
        #expect(!layout(builder.build()).contains { $0.kind == .live(.background(.claude, titles: ["Audit the port"])) })
    }

    @Test func aTurnRunningBeforeAQueuedMessageStillShowsLive() {
        var transcript = Transcript()
        let first = transcript.add(.user)
        let tool = transcript.add(.tool, status: .running)
        let queued = transcript.add(.user)
        let rows = layout(TranscriptBuilder(items: transcript.items, runningTurnID: first).build())
        #expect(rows.map(\.id) == [.item(first), .turnHeader(first), .item(tool), .item(queued), .live])
    }

    // MARK: Revisions

    @Test func revisionsChangeOnlyWithWhatARowDraws() {
        var transcript = Transcript()
        let user = transcript.add(.user)
        let reply = transcript.add(.assistant, "Done")
        let before = TranscriptBuilder(items: transcript.items).build()
        #expect(before == TranscriptBuilder(items: transcript.items).build())
        let after = TranscriptBuilder(items: transcript.items, revisions: [reply: 3]).build()
        let changed = zip(layout(before), layout(after)).filter { $0.revision != $1.revision }.map(\.0.id)
        #expect(changed == [.item(reply)])
        #expect(layout(after).first?.id == .item(user))
    }

    // MARK: Reusing settled turns

    @Test func reusingSettledTurnsBuildsWhatAFullBuildDoes() {
        var transcript = Transcript()
        var builder = TranscriptBuilder(items: [])
        var settled: TranscriptSettledRows?
        var revisions: [UUID: Int] = [:]

        func step(_ changed: Set<UUID>, sourceLocation: SourceLocation = #_sourceLocation) {
            builder.items = transcript.items
            builder.revisions = revisions
            let reused = builder.build(reusing: &settled, changed: changed)
            #expect(reused == builder.build(), sourceLocation: sourceLocation)
        }

        // Three turns stream in, item by item, each running while it does.
        for turn in 0..<3 {
            let user = transcript.add(.user, "Message \(turn)")
            builder.runningTurnID = user
            builder.turnStartedAt = transcript[user].createdAt
            step([user])
            let tool = transcript.add(.tool, status: .running, category: .command)
            step([tool])
            transcript.items[transcript.items.count - 1].status = .completed
            revisions[tool, default: 0] += 1
            step([tool])
            let reply = transcript.add(.assistant, "Answer", status: .running, provider: .claude)
            step([reply])
            transcript.items[transcript.items.count - 1].text += " grows"
            revisions[reply, default: 0] += 1
            step([reply])
            transcript.items[transcript.items.count - 1].status = .completed
            builder.runningTurnID = nil
            step([reply])
        }

        // Changing what an old turn shows: its revision, its expansion, reasoning and changed files.
        let old = transcript.items[1].id
        revisions[old, default: 0] += 1
        step([old])
        builder.expanded = [.turnHeader(transcript.items[0].id)]
        step([])
        builder.showReasoning = false
        step([])
        builder.changedFiles = [transcript.items[0].id: 4]
        step([])
        // Rewinding to the second turn.
        transcript.items.removeLast(6)
        step([])
    }

    @Test func settledTurnsAreNotLaidOutAgainWhileTheLastOneStreams() {
        var transcript = Transcript()
        transcript.add(.user)
        let oldReply = transcript.add(.assistant, "Old")
        let user = transcript.add(.user)
        transcript.add(.assistant, "New", status: .running)
        var settled: TranscriptSettledRows?
        let builder = TranscriptBuilder(items: transcript.items, runningTurnID: user)
        let first = builder.build(reusing: &settled, changed: [])
        // An old item's content changed but nothing reports it: the kept rows are used as they are.
        var stale = builder
        stale.revisions = [oldReply: 9]
        #expect(stale.build(reusing: &settled, changed: []) == first)
        // Once reported, they are built again.
        #expect(stale.build(reusing: &settled, changed: [oldReply]) == stale.build())
    }
}

struct TranscriptLabelsTests {
    private func tools(_ categories: [ToolCategory?]) -> [TranscriptItem] {
        categories.map { TranscriptItem(kind: .tool, category: $0) }
    }

    @Test func thoughtsAloneAreCounted() {
        #expect(TranscriptLabels.summary(of: [TranscriptItem(kind: .reasoning)]) == "Thought")
        #expect(TranscriptLabels.summary(of: Array(repeating: TranscriptItem(kind: .reasoning), count: 3)) == "Thought 3 times")
    }

    @Test func summariesNameTheTwoMostSignificantKindsOfWork() {
        #expect(TranscriptLabels.summary(of: tools([.command, .command, .command, .read, .read])) == "Ran 3 commands and read 2 files")
        #expect(TranscriptLabels.summary(of: tools([.read, .read, .fileChange])) == "Read 2 files and changed 1 file")
        #expect(
            TranscriptLabels.summary(of: tools([.command, .read, .read, .search, nil]))
                == "Ran 1 command, read 2 files, and performed 2 other actions")
        #expect(
            TranscriptLabels.summary(of: tools([.web, .mcp, .todo]))
                == "Searched the web once, called 1 MCP tool, and performed 1 other action")
        #expect(TranscriptLabels.summary(of: tools([.other])) == "Used 1 tool")
        #expect(TranscriptLabels.summary(of: tools([.task, .task]) + [TranscriptItem(kind: .reasoning)]) == "Ran 2 subagents")
    }

    @Test func everyCategoryHasASingularAndPluralPhrase() {
        let phrases: [(ToolCategory, String, String)] = [
            (.command, "Ran 1 command", "Ran 2 commands"), (.fileChange, "Changed 1 file", "Changed 2 files"),
            (.read, "Read 1 file", "Read 2 files"), (.search, "Searched code once", "Searched code 2 times"),
            (.web, "Searched the web once", "Searched the web 2 times"), (.mcp, "Called 1 MCP tool", "Called 2 MCP tools"),
            (.task, "Ran 1 subagent", "Ran 2 subagents"), (.todo, "Updated the plan", "Updated the plan 2 times"),
            (.other, "Used 1 tool", "Used 2 tools"),
        ]
        for (category, one, two) in phrases {
            #expect(TranscriptLabels.phrase(for: category, count: 1) == one)
            #expect(TranscriptLabels.phrase(for: category, count: 2) == two)
        }
    }

    @Test func groupSymbolsFollowTheirCategory() {
        #expect(TranscriptLabels.symbol(for: [TranscriptItem(kind: .reasoning)]) == "brain")
        #expect(TranscriptLabels.symbol(for: tools([.command, .command])) == ToolCategory.command.symbolName)
        #expect(TranscriptLabels.symbol(for: tools([nil])) == ToolCategory.other.symbolName)
        #expect(TranscriptLabels.symbol(for: tools([.command, .read])) == "hammer")
    }

    @Test func durationsReadLikeT3Code() {
        #expect(TranscriptLabels.duration(0) == "0.1s")
        #expect(TranscriptLabels.duration(0.04) == "0.1s")
        #expect(TranscriptLabels.duration(3.14) == "3.1s")
        #expect(TranscriptLabels.duration(9.97) == "9.9s")
        #expect(TranscriptLabels.duration(10) == "10s")
        #expect(TranscriptLabels.duration(59.6) == "1m")
        #expect(TranscriptLabels.duration(133) == "2m 13s")
        #expect(TranscriptLabels.duration(3600) == "1h")
        #expect(TranscriptLabels.duration(3725) == "1h 2m 5s")
        #expect(TranscriptLabels.duration(-5) == "0s")
        #expect(TranscriptLabels.duration(.infinity) == "0s")
        #expect(TranscriptLabels.duration(.nan) == "0s")
    }

    @Test func liveTimersPadMinutesAndSeconds() {
        #expect(TranscriptLabels.elapsed(5.9) == "5s")
        #expect(TranscriptLabels.elapsed(65) == "1m 05s")
        #expect(TranscriptLabels.elapsed(3720) == "1h 02m")
        #expect(TranscriptLabels.elapsed(-3) == "0s")
    }

    @Test func thoughtPreviewsShowTheFirstSentenceOnOneLine() {
        #expect(TranscriptLabels.thoughtPreview("**Planning the fix**\n\nI will read the file.") == "Planning the fix")
        #expect(TranscriptLabels.thoughtPreview("  First sentence. Second one.") == "First sentence.")
        #expect(TranscriptLabels.thoughtPreview("# Heading\nmore   text\nhere") == "Heading more text here")
        #expect(TranscriptLabels.thoughtPreview("Is it `nil`? Maybe") == "Is it nil?")
        #expect(TranscriptLabels.thoughtPreview("Ends with a dot.") == "Ends with a dot.")
        #expect(TranscriptLabels.thoughtPreview("") == "")
    }

    @Test func longThoughtsArePreviewedFromTheirStartOnly() {
        let long = "Line one has words\n" + String(repeating: "x", count: 5000)
        #expect(TranscriptLabels.thoughtPreview(long) == "Line one has words")
    }
}
