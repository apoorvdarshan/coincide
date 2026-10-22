import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor ClaudeHistoryDrainGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        released = true
        let saved = waiters; waiters = []
        for waiter in saved { waiter.resume() }
    }
}

private final class ClaudeHistoryDrainProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var constructions = 0, reviewReturned = false
    var factoryCount: Int { lock.withLock { constructions } }
    var completedReview: Bool { lock.withLock { reviewReturned } }
    func constructed() { lock.withLock { constructions += 1 } }
    func reviewed() { lock.withLock { reviewReturned = true } }
}

/// Models the observed native shutdown boundary: an idle owned runtime appends
/// metadata to the same transcript inode before its close/drain can complete.
private actor ClaudeHistoryDrainPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private let runtime: ClaudeRuntimeConfiguration
    private let file: URL
    private let gate: ClaudeHistoryDrainGate
    let nativeID = UUID().uuidString.lowercased()
    let assistantID = UUID().uuidString.lowercased()
    private(set) var sends = 0, modelsCalls = 0, closeStarts = 0
    private(set) var closed = false, closeWriteFailed = false
    private var closing = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(runtime: ClaudeRuntimeConfiguration, directory: URL, gate: ClaudeHistoryDrainGate) {
        self.runtime = runtime; self.gate = gate
        file = directory.appendingPathComponent(nativeID + ".jsonl")
        (events, sink) = AsyncStream.makeStream()
    }
    func models() -> [ProviderModel] { modelsCalls += 1; return [] }
    func observations() -> (sends: Int, models: Int, closes: Int, closed: Bool, failed: Bool) {
        (sends, modelsCalls, closeStarts, closed, closeWriteFailed)
    }
    func send(text: String, thread: CodingThread) throws {
        guard sends == 0, !closing, let run = thread.activeRun,
              run.configuration.claudeRuntimeConfiguration == runtime else {
            throw CoincideError("The synthetic Claude drain peer received an unexpected input owner.")
        }
        sends += 1
        let opening = ClaudeInputIdentity.opening(runID: run.id)
        let rows = [record(id: opening, parent: nil, role: "user", text: text),
                    record(id: assistantID, parent: opening, role: "assistant", text: "Owned synthetic answer")]
        var bytes = Data()
        for row in rows { bytes.append(try JSONEncoder().encode(row)); bytes.append(10) }
        try bytes.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var evidence = try ClaudeRunHistoryEvidence(runID: run.id, runtimeIdentity: runtime.runtimeIdentity)
        try evidence.observe(nativeSessionID: nativeID, inputIDs: [opening], rootAssistantMessageID: assistantID)
        try evidence.finish(.completed)
        sink.yield(.context(runID: run.id, event: .thread(nativeID)))
        sink.yield(.context(runID: run.id, event: .turn(opening)))
        sink.yield(.context(runID: run.id, event: .claudeHistoryEvidence(evidence)))
        sink.yield(.context(runID: run.id, event: .message(.init(id: "drain-answer-" + run.id.uuidString,
            role: .assistant, text: "Owned synthetic answer"))))
        sink.yield(.context(runID: run.id, event: .completed(.idle)))
    }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) { Issue.record("History review must not request permission.") }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { Issue.record("History review must not ask a question.") }
    func close() async {
        if closed { return }
        if closing { await withCheckedContinuation { closeWaiters.append($0) }; return }
        closing = true; closeStarts += 1
        await gate.wait()
        do {
            // These records do not change conversational ownership or content.
            // Their bytes must nevertheless be part of the exact reviewed hash.
            let metadata: [JSONValue] = [
                .object(["type": .string("last-prompt"), "sessionId": .string(nativeID),
                    "lastPrompt": .string("Only the explicit synthetic input")]),
                .object(["type": .string("cost-state"), "sessionId": .string(nativeID),
                    "costUSD": .number(0)])
            ]
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            _ = try handle.seekToEnd()
            for row in metadata {
                try handle.write(contentsOf: JSONEncoder().encode(row)); try handle.write(contentsOf: Data([10]))
            }
            try handle.synchronize()
        } catch { closeWriteFailed = true }
        closed = true; sink.finish()
        let saved = closeWaiters; closeWaiters = []
        for waiter in saved { waiter.resume() }
    }
    private func record(id: String, parent: String?, role: String, text: String) -> JSONValue {
        .object(["type": .string(role), "uuid": .string(id), "sessionId": .string(nativeID),
            "parentUuid": parent.map(JSONValue.string) ?? .null, "cwd": .string(runtime.workspacePath),
            "isSidechain": .bool(false), "timestamp": .string("2026-10-23T00:00:00.000Z"),
            "message": .object(["role": .string(role), "content": .string(text)])])
    }
}

private func waitClaudeHistoryDrain(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned Claude history drain did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func claudeHistoryReviewDrainsOwnedIdleRuntimeBeforeCapturingExactNativeRevisionAndForking() async throws {
    let manager = FileManager.default
    let requested = manager.temporaryDirectory.appendingPathComponent("coincide-claude-history-drain-" + UUID().uuidString)
    try manager.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    guard let pointer = requested.path.withCString({ realpath($0, nil) }) else { throw CoincideError("The private history drain fixture is unavailable.") }
    let root = URL(fileURLWithPath: String(cString: pointer)); free(pointer)
    let gate = ClaudeHistoryDrainGate(), probe = ClaudeHistoryDrainProbe()
    var engine: WorkspaceEngine?, reviewTask: Task<ConversationHistoryReview, any Error>?
    do {
        let workspace = root.appendingPathComponent("Workspace 工作 😀")
        try manager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let project = WorkspaceProject(path: workspace.path)
        let runtime = ClaudeRuntimeConfiguration(executable: root.appendingPathComponent("never-executed-claude").path,
            configurationDirectory: root.appendingPathComponent("PrivateClaude").path,
            workspacePath: workspace.path, registeredWorkspacePath: project.path)
        let nativeDirectory = URL(fileURLWithPath: runtime.configurationDirectory).appendingPathComponent("projects")
            .appendingPathComponent(runtime.projectKey)
        try manager.createDirectory(at: nativeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let peer = ClaudeHistoryDrainPeer(runtime: runtime, directory: nativeDirectory, gate: gate)
        let databaseURL = root.appendingPathComponent("workspace.sqlite")
        let current = try WorkspaceEngine(url: databaseURL, providerFactory: { thread in
            #expect(thread.claudeRuntimeConfiguration == runtime)
            probe.constructed(); return peer
        }, identityResolver: { _ in nil })
        engine = current
        var source = CodingThread(project: project)
        source.workspacePath = runtime.registeredWorkspacePath; source.provider = .claude
        source.claudeRuntimeConfiguration = runtime; source.checkpointPolicy = .disabled
        let runID = UUID()
        try await current.dispatch(.addProjectWithThread(project: project, thread: source))
        try await current.dispatch(.submit(threadID: source.id, text: "Only the explicit synthetic input"), id: runID)
        try await waitClaudeHistoryDrain {
            let update = await current.current()
            return update.snapshot.threads.first(where: { $0.id == source.id })?.runHistory?.first(where: { $0.id == runID })?.status == .completed
                && update.snapshot.threads.first(where: { $0.id == source.id })?.activeRun == nil
        }
        let store = try ClaudeTranscriptStore(configurationDirectory: URL(fileURLWithPath: runtime.configurationDirectory), workspace: workspace)
        let nativeID = peer.nativeID, assistantID = peer.assistantID
        let nativeFile = nativeDirectory.appendingPathComponent(nativeID + ".jsonl")
        let old = try store.read(sessionID: nativeID), oldBytes = try Data(contentsOf: nativeFile)
        #expect(old.transcript.records.count == 2 && probe.factoryCount == 1)
        let idlePeer = await peer.observations()
        #expect(idlePeer.closes == 0 && idlePeer.sends == 1)
        let job = Task {
            defer { probe.reviewed() }
            return try await current.reviewConversationHistory(threadID: source.id, runID: runID, kind: .forkAfterRun)
        }
        reviewTask = job
        try await waitClaudeHistoryDrain { await peer.closeStarts == 1 || probe.completedReview }
        let closing = await peer.closeStarts
        #expect(closing == 1 && !probe.completedReview, "Review must await the owned idle actor's complete native flush.")
        guard closing == 1, !probe.completedReview else { throw CoincideError("Claude history was reviewed before its owned idle runtime drained.") }
        #expect(try Data(contentsOf: nativeFile) == oldBytes)
        await gate.release()
        let review = try await job.value
        let flushed = try store.read(sessionID: nativeID), flushedBytes = try Data(contentsOf: nativeFile)
        let closedPeer = await peer.observations()
        #expect(closedPeer.closed && !closedPeer.failed)
        #expect(flushed.revision.inode == old.revision.inode && flushed.revision != old.revision)
        #expect(flushedBytes.count > oldBytes.count && flushedBytes.starts(with: oldBytes))
        #expect(flushed.transcript.records.suffix(2).map { $0["type"].string } == ["last-prompt", "cost-state"])
        #expect(review.claude?.source.sourceRevision == flushed.revision && review.claude?.source.records.count == 4)
        #expect(review.claude?.source.selectedMessageIDs == [ClaudeInputIdentity.opening(runID: runID), assistantID])
        #expect(review.boundary == .throughClaudeMessage(assistantID) && probe.factoryCount == 1)
        try await current.beginConversationHistory(review, title: "Fork after exact idle drain")
        try await waitClaudeHistoryDrain {
            let update = await current.current()
            return update.snapshot.conversationHistoryOperation(review.id)?.isPending == false
        }
        let snapshot = await current.current().snapshot
        let operation = try #require(snapshot.conversationHistoryOperation(review.id))
        let publication = try #require(operation.claudeForkPublication)
        #expect(operation.phase == .applied && operation.result?.claude?.publication == publication)
        #expect(publication.sourceRevision == flushed.revision && publication.upToMessageID == assistantID)
        let target = try #require(snapshot.threads.first { $0.id == review.targetThreadID })
        #expect(target.providerThreadID == publication.target.sessionID && target.claudeInheritedHead?.cursor == publication.headMessageID)
        let preservedBytes = try Data(contentsOf: nativeFile), preserved = try store.read(sessionID: nativeID)
        #expect(preservedBytes == flushedBytes && preserved.revision == flushed.revision)
        let finalPeer = await peer.observations()
        #expect(probe.factoryCount == 1 && finalPeer.sends == 1 && finalPeer.models == 0 && finalPeer.closes == 1)
        let journal = try await WorkspaceDatabase(url: databaseURL).journal(limit: 1_000)
        let versions = journal.compactMap { row -> ConversationHistoryOperation? in
            guard case .conversationHistoryOperationsReplaced(let operations) = row.event else { return nil }
            return operations?.first { $0.id == review.id }
        }
        let reserved = try #require(versions.firstIndex { $0.phase == .dispatching && $0.claudeForkPublication == publication })
        let applied = try #require(versions.firstIndex { $0.phase == .applied })
        #expect(reserved < applied)
        try WorkspaceJournal.validate(snapshot)
        await current.shutdown()
        let drainedPeer = await peer.observations()
        #expect(drainedPeer.closes == 1)
    } catch {
        await gate.release(); reviewTask?.cancel(); _ = try? await reviewTask?.value
        await engine?.shutdown(); try? manager.removeItem(at: root); throw error
    }
    await engine?.shutdown(); try? manager.removeItem(at: root)
}
