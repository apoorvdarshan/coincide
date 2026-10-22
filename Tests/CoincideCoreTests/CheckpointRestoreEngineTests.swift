import Foundation
import Testing
@testable import CoincideCore

actor RestoreEngineGate {
    private(set) var entered = false
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}

actor RestoreEnginePeer: RunCheckpointSession {
    enum Mode: Sendable, Equatable { case confirmed, uncertainBefore, uncertainAfter, rejected }
    private var mode: Mode = .confirmed
    private var gate: RestoreEngineGate?
    private var reviewGate: RestoreEngineGate?
    private var probe: (@Sendable () async throws -> Void)?
    private(set) var calls: [UUID] = []
    private(set) var inspections = 0
    private(set) var reviewed: [UUID] = []
    private(set) var discarded: [UUID] = []
    private var completion: GitCheckpointRestoreReceipt?
    func configure(_ mode: Mode = .confirmed, gate: RestoreEngineGate? = nil, probe: (@Sendable () async throws -> Void)? = nil) {
        self.mode = mode; self.gate = gate; self.probe = probe
    }
    func release() async { await gate?.release() }
    func holdReview(_ gate: RestoreEngineGate) { reviewGate = gate }
    func prepare(id: UUID) async throws -> GitCheckpointPlan { throw GitCheckpointError(.incomplete) }
    func capture(_ plan: GitCheckpointPlan) async throws -> GitCheckpointReceipt { throw GitCheckpointError(.incomplete) }
    func inspect(_ plan: GitCheckpointPlan) async throws -> GitCheckpointInspection { .missing }
    func finalizeScratch(_ receipt: GitCheckpointReceipt) async throws -> GitCheckpointScratchResult { throw GitCheckpointError(.incomplete) }
    func reviewRestore(target: GitCheckpointReceipt, id: UUID) async throws -> GitCheckpointRestoreReview {
        let review = try GitCheckpointRestoreReview(id: id, targetReceipt: target, currentPlan: CheckpointRestoreFixture.plan(path: target.plan.workspacePath),
                  manifestDigest: String(repeating: "e", count: 64), affectedPaths: ["reviewed.swift"], previewPatch: "Synthetic restore preview")
        reviewed.append(id)
        if let reviewGate { await reviewGate.wait() }
        return review
    }
    func discardRestoreReview(_ review: GitCheckpointRestoreReview) async throws -> GitCheckpointScratchResult {
        try Task.checkCancellation()
        discarded.append(review.id)
        return .removed
    }
    func restore(review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreReceipt {
        calls.append(review.id); try await probe?()
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        if mode == .rejected { throw GitCheckpointRestoreError(.staleReview) }
        if mode == .uncertainBefore { throw GitCheckpointRestoreError(.interrupted, mayHaveMutated: true) }
        let receipt = try GitCheckpointRestoreReceipt(review: review, stateDigest: String(repeating: "f", count: 64))
        completion = receipt
        if mode == .uncertainAfter { throw GitCheckpointRestoreError(.interrupted, mayHaveMutated: true) }
        return receipt
    }
    func inspectRestore(review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreInspection {
        inspections += 1
        if let completion { return .ready(completion) }
        return .notStarted
    }
}

private struct RestoreEngineFixture {
    let root: URL
    let databaseURL: URL
    let seed: CheckpointRestoreFixture
    let peer: RestoreEnginePeer
    let engine: WorkspaceEngine
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-restore-engine-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        databaseURL = root.appendingPathComponent("workspace.sqlite"); seed = try .init()
        try await WorkspaceDatabase(url: databaseURL).save(seed.snapshot, event: "restore.engine.fixture")
        let peer = RestoreEnginePeer(); self.peer = peer
        engine = try Self.makeEngine(url: databaseURL, peer: peer)
        _ = try await engine.load()
    }
    static func makeEngine(url: URL, peer: RestoreEnginePeer) throws -> WorkspaceEngine {
        try WorkspaceEngine(url: url, providerFactory: { _ in throw CoincideError("File restoration must never launch a provider.") },
                            identityResolver: { _ in nil }, checkpointFactory: { _ in peer })
    }
    func review() async throws -> RunCheckpointRestoreReview {
        try await engine.reviewCheckpointRestore(threadID: seed.threadID, runID: seed.runID, stage: .baseline, expectedAttemptID: seed.attemptID)
    }
    func finish() async { await peer.release(); await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

private func restoreEngineEventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The restore engine fixture did not reach its expected gate.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func checkpointRestoreEngineCommitsBeforeOneWriteAndKeepsTheLatestConversationState() async throws {
    let f = try await RestoreEngineFixture()
    do {
        let review = try await f.review(), gate = RestoreEngineGate(), url = f.databaseURL
        await f.peer.configure(gate: gate, probe: {
            let saved = try await WorkspaceDatabase(url: url).load()
            #expect(saved.checkpointRestoreOperation(review.id)?.phase == .dispatching)
        })
        async let first = f.engine.beginCheckpointRestore(review)
        async let second = f.engine.beginCheckpointRestore(review)
        let receipts = try await (first, second)
        #expect(receipts.0 == receipts.1)
        try await restoreEngineEventually { await gate.entered }
        #expect(await f.peer.calls == [review.id])
        await f.engine.discardCheckpointRestoreReview(reviewID: review.id)
        #expect(await f.peer.discarded.isEmpty)
        try await f.engine.dispatch(.editThread(f.seed.threadID, .draft("Newest draft during restoration")))
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.dispatch(.submit(threadID: f.seed.threadID, text: "Must wait")) }
        await gate.release()
        try await restoreEngineEventually { await f.engine.current().snapshot.checkpointRestoreOperation(review.id)?.phase == .applied }
        let snapshot = await f.engine.current().snapshot
        var expected = f.seed.thread; expected.draft = "Newest draft during restoration"
        // Editing the draft may update its timestamp; all substantive state stays.
        expected.updatedAt = snapshot.threads[0].updatedAt
        #expect(snapshot.threads[0] == expected)
        #expect(await f.peer.calls == [review.id])
        #expect(try await WorkspaceDatabase(url: url).rebuildProjection().snapshot == snapshot)
        await f.finish()
    } catch { await f.finish(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["cancel", "archive", "model"])
func checkpointRestoreRejectedReviewDiscardsItsExactUnusedScratchWithoutWriting(change: String) async throws {
    let f = try await RestoreEngineFixture(), gate = RestoreEngineGate()
    var reader: Task<RunCheckpointRestoreReview, any Error>?
    do {
        await f.peer.holdReview(gate)
        let task = Task { try await f.review() }; reader = task
        try await restoreEngineEventually { await gate.entered }
        switch change {
        case "cancel": task.cancel()
        case "archive": try await f.engine.dispatch(.editThread(f.seed.threadID, .archived(true)))
        default: try await f.engine.dispatch(.editThread(f.seed.threadID, .model("Changed during review")))
        }
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        let reviewed = await f.peer.reviewed
        #expect(reviewed.count == 1)
        #expect(await f.peer.discarded == reviewed)
        #expect(await f.peer.calls.isEmpty)
        #expect(await f.engine.current().snapshot.checkpointRestoreOperations == nil)
        await f.finish()
    } catch {
        await gate.release(); _ = await reader?.result; await f.finish(); throw error
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func checkpointRestoreEngineInspectsLostAcknowledgmentAfterRestartWithoutRepeatingWrites(mutated: Bool) async throws {
    let f = try await RestoreEngineFixture(); var reopened: WorkspaceEngine?
    do {
        let review = try await f.review()
        await f.peer.configure(mutated ? .uncertainAfter : .uncertainBefore)
        try await f.engine.beginCheckpointRestore(review)
        try await restoreEngineEventually { await f.engine.current().snapshot.checkpointRestoreOperation(review.id)?.phase == .unconfirmed }
        await f.engine.shutdown()
        let engine = try RestoreEngineFixture.makeEngine(url: f.databaseURL, peer: f.peer); reopened = engine
        _ = try await engine.load()
        #expect(await f.peer.calls == [review.id])
        try await engine.inspectCheckpointRestore(operationID: review.id)
        let snapshot = await engine.current().snapshot
        #expect(snapshot.checkpointRestoreOperation(review.id)?.phase == (mutated ? .applied : .failed))
        #expect(!snapshot.isCheckpointRestoreLocked(threadID: f.seed.threadID))
        #expect(await f.peer.calls == [review.id])
        #expect(await f.peer.inspections == 1)
        #expect(snapshot.threads[0].messages == f.seed.thread.messages && snapshot.threads[0].draft == f.seed.thread.draft)
        await engine.shutdown(); reopened = nil; await f.finish()
    } catch { await reopened?.shutdown(); await f.finish(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func checkpointRestoreEngineRejectsForgedAndStaleReviewsAndRecordsKnownPremutationFailure() async throws {
    let f = try await RestoreEngineFixture()
    do {
        let review = try await f.review()
        let forged = try RunCheckpointRestoreReview(id: review.id, reviewedAt: review.reviewedAt.addingTimeInterval(1),
            threadID: review.threadID, projectID: review.projectID, runID: review.runID, stage: review.stage, attemptID: review.attemptID,
            sourceIncarnation: review.sourceIncarnation, sourceFingerprint: review.sourceFingerprint, checkpoint: review.checkpoint, gitReview: review.gitReview)
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.beginCheckpointRestore(forged) }
        try await f.engine.dispatch(.editThread(f.seed.threadID, .model("A newer model")))
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.beginCheckpointRestore(review) }
        #expect(await f.peer.calls.isEmpty)
        let current = try await f.review()
        await f.peer.configure(.rejected)
        try await f.engine.beginCheckpointRestore(current)
        try await restoreEngineEventually { await f.engine.current().snapshot.checkpointRestoreOperation(current.id)?.phase == .failed }
        #expect(await f.peer.calls == [current.id])
        #expect(!((await f.engine.current()).snapshot.isCheckpointRestoreLocked(threadID: f.seed.threadID)))
        await f.finish()
    } catch { await f.finish(); throw error }
}
