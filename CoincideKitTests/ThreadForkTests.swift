import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct ThreadForkTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-fork-\(UUID().uuidString)")

    /// Two finished turns (user, tool, reply), the second answered by Codex.
    private func twoTurns() -> [TranscriptItem] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return [
            TranscriptItem(kind: .user, text: "fix the bug", provider: .claude, modelID: "opus", createdAt: start),
            TranscriptItem(
                kind: .tool, text: "ok", title: "Run `swift test`", category: .command, status: .completed, provider: .claude,
                externalID: "t1", createdAt: start + 1),
            TranscriptItem(kind: .assistant, text: "Fixed in App.swift.", provider: .claude, modelID: "opus", createdAt: start + 2),
            TranscriptItem(
                kind: .user, text: "add tests", provider: .codex, attachments: ["/tmp/shot.png"], createdAt: start + 3),
            TranscriptItem(kind: .assistant, text: "Added AppTests.", provider: .codex, modelID: "gpt", createdAt: start + 4),
        ]
    }

    private func source(_ items: [TranscriptItem]) -> ChatThread {
        ChatThread(
            projectID: UUID(), title: "Login bug", selection: ModelSelection(provider: .codex, modelID: "gpt", effort: "high"),
            accessMode: .approval, interactionMode: .plan, items: items,
            sessions: [
                .claude: ProviderSessionRef(sessionID: "c1", seenItemCount: 3),
                .codex: ProviderSessionRef(sessionID: "x1", seenItemCount: 5),
            ],
            isPinned: true, worktreePath: "/tmp/worktree", branch: "fix/login", draft: "unsent")
    }

    // MARK: Which items a fork copies

    @Test func forkFromATurnCopiesThroughTheEndOfThatTurn() throws {
        let items = twoTurns()
        // From the first turn's message, its tool call or its reply: the same turn.
        for anchor in items[0...2] {
            let slice = try #require(ThreadFork.forkableItems(in: items, through: anchor.id))
            #expect(slice.map(\.id) == items[0...2].map(\.id))
        }
        let last = try #require(ThreadFork.forkableItems(in: items, through: items[3].id))
        #expect(last.map(\.id) == items.map(\.id))
    }

    @Test func forkingTheThreadCopiesEverySettledTurn() throws {
        let items = twoTurns()
        #expect(try #require(ThreadFork.forkableItems(in: items, through: nil)).count == items.count)
        // While the second turn runs, the thread forks from the latest settled turn, as T3's latest_stable.
        let running = try #require(ThreadFork.forkableItems(in: items, through: nil, runningTurnID: items[3].id))
        #expect(running.map(\.id) == items[0...2].map(\.id))
    }

    @Test func aRunningTurnCannotBeForked() {
        let items = twoTurns()
        #expect(ThreadFork.forkableItems(in: items, through: items[4].id, runningTurnID: items[3].id) == nil)
        #expect(ThreadFork.forkableItems(in: items, through: items[3].id, runningTurnID: items[3].id) == nil)
        // An earlier, settled turn still can.
        #expect(ThreadFork.forkableItems(in: items, through: items[2].id, runningTurnID: items[3].id)?.count == 3)
        // The only turn is running: nothing settled to fork.
        #expect(ThreadFork.forkableItems(in: items, through: nil, runningTurnID: items[0].id) == nil)
    }

    @Test func nothingToForkInAnEmptyThreadOrForAnUnknownItem() {
        #expect(ThreadFork.forkableItems(in: [], through: nil) == nil)
        #expect(ThreadFork.forkableItems(in: twoTurns(), through: UUID()) == nil)
        #expect(!ThreadFork.canFork(source([]), through: nil))
        #expect(ThreadFork.canFork(source(twoTurns()), through: nil))
    }

    @Test func aMessageSteeredIntoATurnDoesNotEndIt() throws {
        var items = twoTurns()
        let steer = TranscriptItem(kind: .user, text: "and the README", provider: .claude, steered: true)
        let work = TranscriptItem(kind: .assistant, text: "README updated too.", provider: .claude)
        items.insert(contentsOf: [steer, work], at: 3)
        // From before the steer, from it or after it: the whole first turn, through the work after the steer.
        for anchor in [items[1], steer, work] {
            let slice = try #require(ThreadFork.forkableItems(in: items, through: anchor.id))
            #expect(slice.map(\.id) == items[0...4].map(\.id))
        }
        // The fork keeps the mark, so the message stays inside its turn there too.
        let plan = try #require(ThreadFork.makeFork(of: source(items), through: items[0].id))
        #expect(plan.thread.items.map(\.isSteered) == [false, false, false, true, false])
        // A steer into the running turn is part of it, so it cannot be forked from either.
        #expect(ThreadFork.forkableItems(in: items, through: steer.id, runningTurnID: items[0].id) == nil)
    }

    @Test func turnsAnAgentStartedEndTheTurnBeforeThem() throws {
        var items = twoTurns()
        let notice = TranscriptItem(kind: .notice, text: "Claude Code continued on its own.", provider: .claude)
        let reply = TranscriptItem(kind: .assistant, text: "The background build passed.", provider: .claude)
        items.insert(contentsOf: [notice, reply], at: 3)
        let withOpeners = try #require(ThreadFork.forkableItems(in: items, through: items[0].id, turnOpeners: [notice.id]))
        #expect(withOpeners.map(\.id) == items[0...2].map(\.id))
        // Without knowing the notice opened a turn, its work counts as part of the first turn.
        let without = try #require(ThreadFork.forkableItems(in: items, through: items[0].id))
        #expect(without.map(\.id) == items[0...4].map(\.id))
        // The agent's own turn forks through its end, before the next message.
        let agentTurn = try #require(ThreadFork.forkableItems(in: items, through: reply.id, turnOpeners: [notice.id]))
        #expect(agentTurn.last?.id == reply.id)
    }

    // MARK: The fork

    @Test func forkCopiesTheConversationWithNewIDsAndTheSameSettings() throws {
        var original = source(twoTurns())
        original.modelPreferences = ["claude/default": ProviderModelPreferences(effort: "max", speed: "fast")]
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let plan = try #require(ThreadFork.makeFork(of: original, through: original.items[2].id, now: now))
        let fork = plan.thread

        #expect(fork.id != original.id)
        #expect(fork.projectID == original.projectID)
        #expect(fork.title == "Login bug fork")
        #expect(fork.selection == original.selection)
        #expect(fork.modelPreferences == original.modelPreferences)
        #expect(fork.accessMode == .approval)
        #expect(fork.interactionMode == .plan)
        #expect(fork.worktreePath == "/tmp/worktree" && fork.branch == "fix/login")
        // No native sessions: the next agent gets the whole conversation as a recap.
        #expect(fork.sessions.isEmpty)
        #expect(!fork.isPinned && !fork.isArchived && fork.draft == nil)
        #expect(fork.createdAt == now && fork.updatedAt == now)

        #expect(fork.items.count == 3)
        #expect(Set(fork.items.map(\.id)).isDisjoint(with: original.items.map(\.id)))
        for (copy, item) in zip(fork.items, original.items) {
            #expect(plan.itemIDs[item.id] == copy.id)
            var same = copy
            same.id = item.id
            #expect(same == item)
        }
        #expect(plan.itemIDs.count == 3)

        #expect(plan.lineage.parentThreadID == original.id)
        #expect(plan.lineage.parentTitle == "Login bug")
        #expect(plan.lineage.parentItemID == original.items[2].id)
        #expect(plan.lineage.forkItemID == fork.items.last?.id)
        #expect(plan.lineage.forkedAt == now)
    }

    @Test func promptsLeftOpenEndInTheFork() throws {
        var items = twoTurns()
        items.append(TranscriptItem(kind: .tool, title: "Run `make`", category: .command, status: .running, provider: .codex))
        items.append(TranscriptItem(kind: .approval, title: "Edit file", status: .waiting, provider: .codex))
        items.append(TranscriptItem(kind: .question, status: .waiting, provider: .codex))
        let plan = try #require(ThreadFork.makeFork(of: source(items), through: nil))
        #expect(plan.thread.items.suffix(3).map(\.status) == [.failed, .declined, .declined])
        #expect(plan.thread.items.first?.status == nil)
    }

    @Test func theForksNextAgentHearsTheWholeConversation() throws {
        let plan = try #require(ThreadFork.makeFork(of: source(twoTurns()), through: nil))
        for provider in [ProviderKind.claude, .codex] {
            let recap = try #require(Handoff.recap(thread: plan.thread, provider: provider))
            #expect(recap.contains("fix the bug"))
            #expect(recap.contains("Fixed in App.swift."))
            #expect(recap.contains("Added AppTests."))
        }
    }

    @Test func forkPointFollowsTheCopiedHistory() throws {
        let original = source(twoTurns())
        let plan = try #require(ThreadFork.makeFork(of: original, through: original.items[2].id, now: Date(timeIntervalSince1970: 1_900_000_000)))
        var items = plan.thread.items
        #expect(plan.lineage.forkPoint(in: items) == items[2].id)
        // The fork's own turns come after it.
        items.append(TranscriptItem(kind: .user, text: "try another way", createdAt: Date(timeIntervalSince1970: 1_900_000_100)))
        #expect(plan.lineage.forkPoint(in: items) == items[2].id)
        // Rewound into the copied history: the newest copied item left.
        let rewound = Array(items.prefix(1))
        #expect(plan.lineage.forkPoint(in: rewound) == rewound[0].id)
        #expect(plan.lineage.forkPoint(in: []) == nil)
    }

    // MARK: Store

    @Test func storeAddsTheForkWithItsLineage() throws {
        let store = AppStore(directory: directory)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let sourceID = store.createThread(in: project.id).id
        let original = source(twoTurns())
        store.updateThread(sourceID) { thread in
            thread.title = original.title
            thread.items = original.items
            thread.sessions = original.sessions
            thread.accessMode = .approval
            thread.selection = original.selection
        }
        var changes: [StoreChange] = []
        let token = store.observe { changes.append($0) }

        let plan = try #require(store.forkThread(sourceID, through: original.items[2].id))
        withExtendedLifetime(token) {}
        let fork = try #require(store.thread(plan.thread.id))
        #expect(fork == plan.thread)
        #expect(fork.items.map(\.text) == ["fix the bug", "ok", "Fixed in App.swift."])
        #expect(fork.sessions.isEmpty && fork.accessMode == .approval && fork.selection == original.selection)
        #expect(store.threads(in: project.id).first?.id == fork.id)
        #expect(changes.contains(.threadList))
        #expect(changes.contains(.items(fork.id, changed: [], appended: false)))

        #expect(store.lineage(of: fork.id) == plan.lineage)
        #expect(store.parentThread(of: fork.id)?.id == sourceID)
        #expect(store.lineage(of: sourceID) == nil)
        #expect(store.forks(of: sourceID).map(\.thread.id) == [fork.id])
        // The source is unchanged.
        #expect(store.thread(sourceID)?.items == original.items)
        #expect(store.thread(sourceID)?.sessions == original.sessions)

        // The fork and its lineage are saved.
        store.flush()
        let reloaded = AppStore(directory: directory)
        #expect(reloaded.thread(fork.id)?.items == fork.items)
        #expect(ThreadLineageStore(directory: directory).lineage(of: fork.id) == plan.lineage)
    }

    @Test func forksOfForksKeepTheirOwnParents() throws {
        let store = AppStore(directory: directory)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let rootID = store.createThread(in: project.id).id
        store.updateThread(rootID) {
            $0.title = "Root"
            $0.items = twoTurns()
        }
        let first = try #require(store.forkThread(rootID)).thread
        let second = try #require(store.forkThread(rootID)).thread
        let nested = try #require(store.forkThread(first.id)).thread
        #expect(nested.title == "Root fork fork")
        #expect(store.parentThread(of: nested.id)?.id == first.id)
        #expect(store.forks(of: rootID).map(\.thread.id) == [first.id, second.id])
        #expect(store.forks(of: first.id).map(\.thread.id) == [nested.id])
    }

    @Test func nothingIsAddedWhenThereIsNothingToFork() {
        let store = AppStore(directory: directory)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let empty = store.createThread(in: project.id)
        let count = store.threadSummaries.count
        #expect(store.forkThread(empty.id) == nil)
        #expect(store.forkThread(UUID()) == nil)
        #expect(store.forkThread(empty.id, through: UUID()) == nil)
        #expect(store.threadSummaries.count == count)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("thread-lineage.json").path))
    }

    @Test func lineageOfDeletedForksIsForgottenButDeletedParentsAreStillNamed() throws {
        let store = AppStore(directory: directory)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let sourceID = store.createThread(in: project.id).id
        store.updateThread(sourceID) {
            $0.title = "Parent"
            $0.items = twoTurns()
        }
        let kept = try #require(store.forkThread(sourceID)).thread
        let dropped = try #require(store.forkThread(sourceID)).thread
        store.deleteThread(dropped.id)
        store.deleteThread(sourceID)
        // Forks outlive their parent, and still name it.
        #expect(store.forks(of: sourceID).map(\.thread.id) == [kept.id])
        #expect(store.parentThread(of: kept.id) == nil)
        #expect(store.lineage(of: kept.id)?.parentTitle == "Parent")
        store.flush()

        let reloaded = AppStore(directory: directory)
        let lineages = ThreadLineageStore(directory: directory)
        lineages.prune(keeping: Set(reloaded.threadSummaries.keys))
        #expect(lineages.lineage(of: dropped.id) == nil)
        #expect(lineages.lineage(of: kept.id)?.parentTitle == "Parent")
        #expect(ThreadLineageStore(directory: directory).records.keys.sorted { $0.uuidString < $1.uuidString } == [kept.id])
    }

    @Test func unreadableLineageEntriesAreSkipped() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = UUID()
        let parent = UUID()
        let json = """
            {"\(good.uuidString)":{"parentThreadID":"\(parent.uuidString)","parentTitle":"P","forkedAt":"2026-10-01T10:00:00Z",
              "future":true},
             "\(UUID().uuidString)":{"parentTitle":"no parent"},
             "not-a-uuid":{"parentThreadID":"\(parent.uuidString)"}}
            """
        try Data(json.utf8).write(to: directory.appendingPathComponent("thread-lineage.json"))
        let lineages = ThreadLineageStore(directory: directory)
        #expect(lineages.records.count == 1)
        #expect(lineages.lineage(of: good)?.parentThreadID == parent)
        #expect(lineages.lineage(of: good)?.parentTitle == "P")
        #expect(lineages.lineage(of: good)?.parentItemID == nil)
    }
}
