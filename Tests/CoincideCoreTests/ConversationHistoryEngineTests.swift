import Foundation
import Testing
@testable import CoincideCore

actor HistoryEngineGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}

actor HistoryEnginePeer {
    enum Reply: Sendable, Equatable { case confirmed, lostAfterMutation, lostBeforeMutation }
    struct Mutation: Sendable {
        let kind: ConversationHistoryKind
        let owner: UUID
        let source: String
        let boundary: ProviderHistoryBoundary
        let inheritedSourceState: Bool
    }
    let workspace: URL
    private var histories: [String: [String]] = ["native-source": ["native-1", "native-2", "native-3"]]
    private(set) var mutations: [Mutation] = []
    private(set) var sends: [String] = []
    private var reply: Reply = .confirmed
    private var gate: HistoryEngineGate?
    private var mutationSession: UUID?
    private var probe: (@Sendable () async throws -> Void)?
    init(workspace: URL) { self.workspace = workspace }
    func configure(reply: Reply = .confirmed, gate: HistoryEngineGate? = nil, probe: (@Sendable () async throws -> Void)? = nil) {
        self.reply = reply; self.gate = gate; self.probe = probe
    }
    func snapshot(_ nativeID: String) throws -> ProviderConversationSnapshot {
        guard let history = histories[nativeID] else { throw ProviderHistoryError(.boundaryUnavailable) }
        return try .init(reference: .init(provider: .codex, nativeThreadID: nativeID), workspacePath: workspace.path,
                         historyMode: .paginated, headTurnID: history.last)
    }
    func page(_ nativeID: String, cursor: String?, limit: Int) throws -> ProviderHistoryPage {
        let snapshot = try snapshot(nativeID), history = Array(histories[nativeID]!.reversed())
        let offset = cursor.flatMap(Int.init) ?? 0
        guard (1...100).contains(limit), offset >= 0, offset <= history.count else { throw ProviderHistoryError(.invalidRequest) }
        let end = min(history.count, offset + limit)
        return try .init(reference: snapshot.reference, turns: history[offset..<end].map { try .init(id: $0, status: .completed) },
                         nextCursor: end < history.count ? String(end) : nil)
    }
    func mutate(kind: ConversationHistoryKind, owner: UUID, session: UUID, source: ProviderConversationReference,
                boundary: ProviderHistoryBoundary, expectedHead: String?, inheritedSourceState: Bool) async throws -> ProviderConversationSnapshot {
        mutationSession = session
        mutations.append(.init(kind: kind, owner: owner, source: source.nativeThreadID, boundary: boundary, inheritedSourceState: inheritedSourceState))
        try await probe?()
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        if reply == .lostBeforeMutation { throw ProviderHistoryError(.outcomeUncertain) }
        guard let history = histories[source.nativeThreadID] else { throw ProviderHistoryError(.boundaryUnavailable) }
        if let expectedHead, history.last != expectedHead { throw ProviderHistoryError(.historyChanged) }
        let selected: [String]
        switch boundary {
        case .head: selected = history
        case .throughTurn(let id):
            guard let index = history.firstIndex(of: id) else { throw ProviderHistoryError(.boundaryUnavailable) }
            selected = Array(history[...index])
        case .beforeTurn(let id):
            guard let index = history.firstIndex(of: id) else { throw ProviderHistoryError(.boundaryUnavailable) }
            selected = Array(history[..<index])
        case .throughClaudeMessage, .freshClaudeSession: throw ProviderHistoryError(.unsupported)
        }
        let target = kind == .forkAfterRun ? "native-fork-" + UUID().uuidString : source.nativeThreadID
        histories[target] = selected
        if reply == .lostAfterMutation { throw ProviderHistoryError(.outcomeUncertain) }
        return try snapshot(target)
    }
    func close(session: UUID) async { if mutationSession == session { await gate?.release() } }
    func sent(nativeID: String?) -> (String, String) {
        let native = nativeID ?? "native-explicit-" + UUID().uuidString
        let turn = "native-explicit-turn-" + UUID().uuidString
        histories[native, default: []].append(turn); sends.append(native)
        return (native, turn)
    }
    func addExternalTurn() { histories["native-source", default: []].append("external-unreviewed-turn") }
}

actor HistoryEngineSession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let peer: HistoryEnginePeer
    private let owner: UUID
    private let inheritedSourceState: Bool
    private let id = UUID()
    private var closed = false
    init(peer: HistoryEnginePeer, thread: CodingThread) {
        self.peer = peer; owner = thread.id
        inheritedSourceState = !thread.messages.isEmpty || thread.runHistory?.isEmpty == false || !thread.draft.isEmpty || thread.runtimeID != nil
        (events, continuation) = AsyncStream.makeStream()
    }
    func models() async throws -> [ProviderModel] { [] }
    func historyCapabilities(threadID: String) async throws -> ProviderHistoryCapabilities {
        let snapshot = try await peer.snapshot(threadID)
        return .init(reference: snapshot.reference, historyMode: .paginated, canRead: true, canForkHead: true,
                     canForkFromTurn: true, canRevertBeforeTurn: true)
    }
    func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot { try await peer.snapshot(threadID) }
    func historyPage(threadID: String, cursor: String?, limit: Int) async throws -> ProviderHistoryPage { try await peer.page(threadID, cursor: cursor, limit: limit) }
    func forkConversation(source: ProviderConversationReference, boundary: ProviderHistoryBoundary, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot {
        try await peer.mutate(kind: .forkAfterRun, owner: owner, session: id, source: source, boundary: boundary, expectedHead: nil, inheritedSourceState: inheritedSourceState)
    }
    func revertConversation(thread: ProviderConversationReference, beforeTurnID: String, expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot {
        try await peer.mutate(kind: .rewindBeforeRun, owner: owner, session: id, source: thread, boundary: .beforeTurn(beforeTurnID), expectedHead: expectedHeadTurnID, inheritedSourceState: inheritedSourceState)
    }
    func send(text: String, thread: CodingThread) async throws {
        guard !closed, let runID = thread.activeRun?.id else { throw CancellationError() }
        let (native, turn) = await peer.sent(nativeID: thread.providerThreadID)
        for event in [ProviderEvent.thread(native), .turn(turn), .message(.init(role: .assistant, text: "Explicit reply")), .completed(.idle)] {
            continuation.yield(.context(runID: runID, event: event))
        }
    }
    func interrupt() async throws {}
    func respond(_ request: ApprovalRequest, allow: Bool) async throws {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {}
    func close() async { closed = true; await peer.close(session: id); continuation.finish() }
}

private struct HistoryEngineFixture {
    let root: URL
    let databaseURL: URL
    let source: CodingThread
    let runIDs: [UUID]
    let peer: HistoryEnginePeer
    let engine: WorkspaceEngine
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-history-engine-\(UUID())", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("workspace.sqlite")
        var f = RunHistoryFixture()
        let project = WorkspaceProject(path: root.path)
        f.snapshot.projects = [project]; f.snapshot.threads[0].projectID = project.id; f.snapshot.threads[0].workspacePath = root.path
        var ids: [UUID] = []
        for index in 1...3 {
            let run = UUID(); ids.append(run)
            try f.submit("Prompt \(index)", id: run)
            if index == 1 { try f.connect(); try f.event(.thread("native-source")) }
            try f.event(.turn("native-\(index)"), runID: run)
            try f.event(.delta(id: "reply-\(index)", role: .assistant, text: "Reply \(index)"), runID: run)
            try f.event(.completed(.idle), runID: run)
        }
        f.snapshot.threads[0].runtimeID = nil; f.snapshot.threads[0].draft = "Unsent source draft"
        source = f.thread; runIDs = ids
        try await WorkspaceDatabase(url: databaseURL).save(f.snapshot, event: "history.fixture")
        let backend = HistoryEnginePeer(workspace: root); peer = backend
        engine = try WorkspaceEngine(url: databaseURL, providerFactory: { HistoryEngineSession(peer: backend, thread: $0) }, identityResolver: { _ in nil })
        _ = try await engine.load()
    }
    func thread() async throws -> CodingThread { try #require(await engine.current().snapshot.threads.first(where: { $0.id == source.id })) }
    func operation(_ id: UUID) async -> ConversationHistoryOperation? { await engine.current().snapshot.conversationHistoryOperations?.first(where: { $0.id == id }) }
    func finish() async { await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

func historyEngineEventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while true {
        if try await condition() { return }
        guard ContinuousClock.now < deadline else { throw CoincideError("Native history engine fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func historyEngineForkJournalsBeforeRPCUsesFreshTargetAndLeavesSourceAndDraftUnchanged() async throws {
    let f = try await HistoryEngineFixture()
    do {
        let original = try await f.thread()
        let review = try await f.engine.reviewConversationHistory(threadID: original.id, runID: f.runIDs[1], kind: .forkAfterRun)
        #expect(review.boundary == .throughTurn("native-2") && review.prefix.count == 4)
        #expect(await f.peer.mutations.isEmpty)
        #expect(await f.peer.sends.isEmpty)
        let gate = HistoryEngineGate(), db = f.databaseURL
        await f.peer.configure(gate: gate, probe: {
            let saved = try await WorkspaceDatabase(url: db).load()
            #expect(saved.conversationHistoryOperations?.first(where: { $0.id == review.id })?.phase == .dispatching)
        })
        async let first = f.engine.beginConversationHistory(review, title: "Chosen fork")
        async let duplicate = f.engine.beginConversationHistory(review, title: "Chosen fork")
        let receipts = try await (first, duplicate)
        #expect(receipts.0.commandID == receipts.1.commandID)
        try await historyEngineEventually { await gate.entered }
        #expect(try await f.thread() == original)
        #expect(await f.operation(review.id)?.phase == .dispatching)
        await gate.release()
        try await historyEngineEventually { await f.operation(review.id)?.phase == .applied }
        let snapshot = await f.engine.current().snapshot
        let target = try #require(snapshot.threads.first(where: { $0.id == review.targetThreadID }))
        #expect(target.title == "Chosen fork" && target.messages == review.prefix && target.draft.isEmpty)
        #expect(target.forkedFromHistoryOperationID == review.id && target.runHistory?.isEmpty != false)
        #expect(target.activeRun == nil && target.queuedTurns.isEmpty && target.runtimeID == nil)
        #expect(try await f.thread() == original)
        let mutations = await f.peer.mutations
        #expect(mutations.count == 1 && mutations[0].owner == target.id && mutations[0].owner != original.id)
        #expect(mutations.first?.inheritedSourceState == false)
        #expect(await f.peer.sends.isEmpty)
        try await f.engine.dispatch(.submit(threadID: target.id, text: "Explicit fork continuation"))
        try await historyEngineEventually { await f.peer.sends.count == 1 }
        #expect(await f.peer.sends.first == target.providerThreadID)
        try await historyEngineEventually {
            let snapshot = await f.engine.current().snapshot
            guard let thread = snapshot.threads.first(where: { $0.id == target.id }) else { return false }
            return !thread.isBusy && thread.heldPostRunCheckpoint == nil && snapshot.providerReady(for: thread)
        }
        try WorkspaceJournal.validate(await f.engine.current().snapshot)
        let rebuilt = try await WorkspaceDatabase(url: db).rebuildProjection().snapshot
        #expect(rebuilt == (await f.engine.current().snapshot))
        await f.finish()
    } catch { await f.finish(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func historyEngineRewindKeepsAuditAndLatestDraftThenRecallsPromptExactlyOnce() async throws {
    let f = try await HistoryEngineFixture()
    do {
        let bytes = Data("User working bytes remain intact.\n".utf8), path = f.root.appendingPathComponent("working.txt")
        try bytes.write(to: path)
        let review = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[1], kind: .rewindBeforeRun)
        #expect(review.boundary == .beforeTurn("native-2") && review.expectedResultHeadTurnID == "native-1")
        try await f.engine.dispatch(.editThread(f.source.id, .draft("Newer unsent draft")))
        try await f.engine.beginConversationHistory(review)
        try await historyEngineEventually { await f.operation(review.id)?.phase == .applied }
        let thread = try await f.thread()
        #expect(thread.messages.count == 6 && thread.visibleMessages.map(\.text) == ["Prompt 1", "Reply 1"])
        #expect(thread.runHistory?.count == 3 && thread.runHistory?.filter({ $0.removedByHistoryOperationID == review.id }).count == 2)
        #expect(thread.draft == "Newer unsent draft" && thread.model == f.source.model && thread.permission == f.source.permission)
        #expect(try Data(contentsOf: path) == bytes)
        #expect(await f.peer.mutations.count == 1)
        #expect(await f.peer.sends.isEmpty)
        try await f.engine.dispatch(.recallConversationHistoryPrompt(operationID: review.id))
        try await f.engine.dispatch(.recallConversationHistoryPrompt(operationID: review.id))
        #expect(try await f.thread().draft == "Newer unsent draft\n\nPrompt 2")
        #expect(await f.operation(review.id)?.recalledAt != nil)
        try WorkspaceJournal.validate(await f.engine.current().snapshot)
        #expect(throws: CoincideError.self) { try thread.transcriptPrefix(runID: f.runIDs[1], boundary: .afterRun) }
        let nextReview = try await f.engine.reviewConversationHistory(threadID: thread.id, runID: f.runIDs[0], kind: .forkAfterRun)
        #expect(nextReview.prefix.map(\.text) == ["Prompt 1", "Reply 1"])
        await f.engine.discardConversationHistoryReview(reviewID: nextReview.id)
        await f.finish()
    } catch { await f.finish(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [true, false])
func historyEngineUnconfirmedRewindReopensWithoutReplayAndReconcilesOnlyObservedResult(mutated: Bool) async throws {
    let f = try await HistoryEngineFixture()
    var reopened: WorkspaceEngine?
    do {
        let review = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[1], kind: .rewindBeforeRun)
        await f.peer.configure(reply: mutated ? .lostAfterMutation : .lostBeforeMutation)
        try await f.engine.beginConversationHistory(review)
        try await historyEngineEventually { await f.operation(review.id)?.phase == .unconfirmed }
        #expect(try await f.thread().visibleMessages.count == 6)
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.dispatch(.submit(threadID: f.source.id, text: "Must remain held")) }
        await f.engine.shutdown()
        let backend = f.peer
        let engine = try WorkspaceEngine(url: f.databaseURL, providerFactory: { HistoryEngineSession(peer: backend, thread: $0) }, identityResolver: { _ in nil })
        reopened = engine; _ = try await engine.load()
        #expect(await f.peer.mutations.count == 1)
        #expect(await f.peer.sends.isEmpty)
        try await engine.reconcileConversationHistory(operationID: review.id)
        let snapshot = await engine.current().snapshot, operation = try #require(snapshot.conversationHistoryOperations?.first)
        #expect(operation.phase == (mutated ? .applied : .failed))
        #expect(snapshot.threads[0].visibleMessages.count == (mutated ? 2 : 6))
        #expect(await f.peer.mutations.count == 1)
        #expect(await f.peer.sends.isEmpty)
        try WorkspaceJournal.validate(snapshot)
        await engine.shutdown(); reopened = nil
        await f.finish()
    } catch { await reopened?.shutdown(); await f.finish(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func historyEngineChangedLocalConfigurationAndExternalNativeHeadCannotApplyOldReview() async throws {
    let f = try await HistoryEngineFixture()
    do {
        let stale = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[1], kind: .forkAfterRun)
        try await f.engine.dispatch(.editThread(f.source.id, .model("A newer model")))
        await #expect(throws: ProviderHistoryError.self) { try await f.engine.beginConversationHistory(stale) }
        #expect(await f.peer.mutations.isEmpty)
        let review = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[1], kind: .rewindBeforeRun)
        await f.peer.addExternalTurn()
        try await f.engine.beginConversationHistory(review)
        try await historyEngineEventually { await f.operation(review.id)?.phase == .failed }
        #expect(try await f.thread().visibleMessages.count == 6)
        #expect(await f.peer.mutations.count == 1)
        #expect(await f.peer.sends.isEmpty)
        await f.finish()
    } catch { await f.finish(); throw error }
}
