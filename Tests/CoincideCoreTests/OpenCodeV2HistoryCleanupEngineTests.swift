import Foundation
import Testing
@testable import CoincideCore

private final class OpenCodeHistoryCleanupFactoryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private actor OpenCodeHistoryCleanupPeer {
    let workspace: String
    let identity: OpenCodeRuntimeIdentity
    let closeGate = HistoryEngineGate()
    private var sourceSession: UUID?
    private var messages: [OpenCodeV2HistoryMessage] = []
    private(set) var sends = 0
    private(set) var reads = 0
    private(set) var mutations = 0
    init(workspace: String, identity: OpenCodeRuntimeIdentity) { self.workspace = workspace; self.identity = identity }
    func sent(sessionID: UUID, runID: UUID) throws -> String {
        sourceSession = sessionID; sends += 1
        let input = OpenCodeV2HistoryRunInput.openingMessageID(instanceID: identity.instanceID, runID: runID)
        messages = [try .init(id: input, kind: .user, contentDigest: String(repeating: "1", count: 64)),
                    try .init(id: "msg_source_reply", kind: .assistant, contentDigest: String(repeating: "2", count: 64))]
        return input
    }
    func snapshot() throws -> OpenCodeV2HistorySnapshot {
        reads += 1
        return try .init(reference: .init(provider: .opencode, nativeThreadID: "ses_cleanup_source"),
                         runtimeIdentity: identity, workspacePath: workspace, messages: messages)
    }
    func fork(_ review: OpenCodeV2HistoryReviewEvidence) throws -> ProviderConversationSnapshot {
        mutations += 1
        let retained = Array(messages.prefix(review.retainedMessageCount))
        let copied = try retained.enumerated().map { index, item in
            try OpenCodeV2HistoryMessage(id: "msg_cleanup_fork_\(index)", kind: item.kind,
                                         contentDigest: item.contentDigest, isSettled: item.isSettled, idleOutcome: item.idleOutcome)
        }
        let boundary: ProviderHistoryBoundary
        if review.boundary == .head { boundary = .throughMessage(try #require(messages.last).id) }
        else { boundary = review.boundary }
        let observed = try OpenCodeV2HistorySnapshot(reference: .init(provider: .opencode, nativeThreadID: "ses_cleanup_fork"),
            runtimeIdentity: identity, workspacePath: workspace, messages: copied,
            fork: .init(sourceSessionID: "ses_cleanup_source", boundary: boundary))
        return try .init(reference: observed.reference, workspacePath: workspace, historyMode: .messageOrdered, openCodeV2: observed)
    }
    func close(_ sessionID: UUID) async {
        if sourceSession == sessionID { await closeGate.wait() }
    }
}

private actor OpenCodeHistoryCleanupSession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let peer: OpenCodeHistoryCleanupPeer
    private let id = UUID()
    init(peer: OpenCodeHistoryCleanupPeer) { self.peer = peer; (events, continuation) = AsyncStream.makeStream() }
    func models() async throws -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) async throws {
        let runID = try #require(thread.activeRun).id
        let input = try await peer.sent(sessionID: id, runID: runID)
        for event in [ProviderEvent.thread("ses_cleanup_source"), .turn(input),
                      .message(.init(id: "cleanup-local-reply", role: .assistant, text: "Completed offline reply")), .completed(.idle)] {
            continuation.yield(.context(runID: runID, event: event))
        }
    }
    func openCodeV2HistorySnapshot(threadID: String) async throws -> OpenCodeV2HistorySnapshot {
        guard threadID == "ses_cleanup_source" else { throw ProviderHistoryError(.invalidRequest) }
        return try await peer.snapshot()
    }
    func applyOpenCodeV2History(review: OpenCodeV2HistoryReviewEvidence, kind: ConversationHistoryKind,
                              configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot {
        guard kind == .forkAfterRun else { throw ProviderHistoryError(.unsupported) }
        return try await peer.fork(review)
    }
    func interrupt() async throws {}
    func respond(_ request: ApprovalRequest, allow: Bool) async throws {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {}
    func close() async { await peer.close(id); continuation.finish() }
}

@Test(.timeLimit(.minutes(1)))
func openCodeV2HistoryWaitsForArchivedExactSourceCloseBeforeReviewOrMutation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-opencode-history-close-" + UUID().uuidString)
        .standardizedFileURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = WorkspaceProject(path: root.path), configuration = OpenCodeConfiguration(executable: "/fixture/opencode")
    var source = CodingThread(project: project); source.provider = .opencode; source.openCodeConfiguration = configuration
    source.checkpointPolicy = .disabled
    let sourceID = source.id, peer = OpenCodeHistoryCleanupPeer(workspace: root.path, identity: configuration.runtimeIdentity)
    let factories = OpenCodeHistoryCleanupFactoryCount()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in
        factories.increment(); return OpenCodeHistoryCleanupSession(peer: peer)
    }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        try await engine.dispatch(.addProjectWithThread(project: project, thread: source))
        try await engine.dispatch(.submit(threadID: sourceID, text: "Original offline input"))
        try await historyEngineEventually {
            guard let current = await engine.current().snapshot.threads.first(where: { $0.id == sourceID }) else { return false }
            return !current.isBusy && current.runHistory?.first?.status == .completed
        }
        try await engine.dispatch(.editThread(sourceID, .draft("Latest retained draft 😀")))
        let before = try #require(await engine.current().snapshot.threads.first { $0.id == sourceID })
        let runID = try #require(before.runHistory?.first).id
        #expect(factories.value == 1)
        try await engine.dispatch(.editThread(sourceID, .archived(true)))
        let gate = await peer.closeGate
        try await historyEngineEventually { await gate.entered }
        try await engine.dispatch(.editThread(sourceID, .archived(false)))
        await #expect(throws: ProviderHistoryError.self) {
            try await engine.reviewConversationHistory(threadID: sourceID, runID: runID, kind: .forkAfterRun)
        }
        #expect(factories.value == 1)
        #expect(await peer.reads == 0)
        #expect(await peer.mutations == 0)
        #expect(await engine.current().snapshot.conversationHistoryOperations == nil)
        await gate.release()
        await engine.awaitProjectRemovalCleanup(projectID: project.id)
        let review = try await engine.reviewConversationHistory(threadID: sourceID, runID: runID, kind: .forkAfterRun)
        #expect(factories.value == 2)
        #expect(await peer.reads == 1)
        try await engine.beginConversationHistory(review)
        try await historyEngineEventually {
            await engine.current().snapshot.conversationHistoryOperation(review.id)?.phase == .applied
        }
        let snapshot = await engine.current().snapshot
        let retained = try #require(snapshot.threads.first { $0.id == sourceID })
        let target = try #require(snapshot.threads.first { $0.id == review.targetThreadID })
        #expect(retained.messages == before.messages && retained.runHistory == before.runHistory && retained.draft == before.draft)
        #expect(retained.providerThreadID == before.providerThreadID && retained.openCodeConfiguration == before.openCodeConfiguration)
        #expect(target.visibleMessages == review.prefix && target.draft.isEmpty && target.providerThreadID == "ses_cleanup_fork")
        #expect(await peer.sends == 1)
        #expect(await peer.mutations == 1)
        try WorkspaceJournal.validate(snapshot)
        await engine.shutdown()
    } catch {
        await peer.closeGate.release()
        await engine.shutdown(); throw error
    }
}
