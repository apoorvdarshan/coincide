import Foundation
import Testing
@testable import CoincideCore

/// Model discovery owns a real provider connection even though it sends no turn.
/// Its close deliberately ignores cancellation until the test releases it.
private actor RestoreMetadataProvider: ProviderSession {
    nonisolated let events = AsyncStream<ProviderEvent> { $0.finish() }
    let modelsGate = RestoreEngineGate()
    let closeGate = RestoreEngineGate()
    private(set) var closes = 0
    private(set) var sends = 0
    func models() async throws -> [ProviderModel] {
        await modelsGate.wait()
        try Task.checkCancellation()
        return [.init(id: "offline-model", name: "Offline model")]
    }
    func close() async {
        closes += 1
        await closeGate.wait()
        await modelsGate.release()
    }
    func send(text: String, thread: CodingThread) async throws {
        sends += 1
        throw CoincideError("Restoration tests must never start provider work.")
    }
    func interrupt() async throws { throw CoincideError("No provider turn exists.") }
    func respond(_ request: ApprovalRequest, allow: Bool) async throws { throw CoincideError("No provider request exists.") }
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws { throw CoincideError("No provider request exists.") }
    func release() async { await closeGate.release(); await modelsGate.release() }
}

private struct RestoreMetadataFixture {
    let root: URL
    let databaseURL: URL
    let seed: CheckpointRestoreFixture
    let other: CodingThread?
    let provider: RestoreMetadataProvider
    let peer: RestoreEnginePeer
    let engine: WorkspaceEngine
    init(sharedOwner: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-restore-metadata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var seed = try CheckpointRestoreFixture()
            var other: CodingThread?
            if sharedOwner {
                var thread = CodingThread(project: seed.snapshot.projects[0])
                thread.workspacePath = seed.thread.workspacePath
                seed.snapshot.threads.append(thread); other = thread
            }
            let databaseURL = root.appendingPathComponent("workspace.sqlite")
            try await WorkspaceDatabase(url: databaseURL).save(seed.snapshot, event: "restore.metadata.fixture")
            let provider = RestoreMetadataProvider(), peer = RestoreEnginePeer()
            let engine = try WorkspaceEngine(url: databaseURL, providerFactory: { _ in provider },
                identityResolver: { _ in nil }, checkpointFactory: { _ in peer })
            _ = try await engine.load()
            self.root = root; self.databaseURL = databaseURL; self.seed = seed; self.other = other
            self.provider = provider; self.peer = peer; self.engine = engine
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func review() async throws -> RunCheckpointRestoreReview {
        try await engine.reviewCheckpointRestore(threadID: seed.threadID, runID: seed.runID, stage: .baseline, expectedAttemptID: seed.attemptID)
    }
    func finish(models: Task<[ProviderModel], any Error>?) async {
        await provider.release(); await peer.release(); await engine.shutdown()
        _ = await models?.result
        try? FileManager.default.removeItem(at: root)
    }
}

private func restoreMetadataEventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The metadata restoration fixture did not reach its expected gate.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func checkpointRestoreWaitsForItsOwnMetadataConnectionToCloseBeforeDispatchOrWrite() async throws {
    let f = try await RestoreMetadataFixture(sharedOwner: false)
    var models: Task<[ProviderModel], any Error>?
    do {
        let task = Task { try await f.engine.models(thread: f.seed.thread) }; models = task
        try await restoreMetadataEventually { await f.provider.modelsGate.entered }
        let review = try await f.review()
        try await f.engine.beginCheckpointRestore(review)
        try await restoreMetadataEventually { await f.provider.closeGate.entered }

        // Reaching close is authoritative: the restore worker is already running,
        // but may not dispatch or call the filesystem writer through this gate.
        #expect(await f.provider.closes == 1)
        #expect(await f.peer.calls.isEmpty)
        let held = try await WorkspaceDatabase(url: f.databaseURL).load()
        #expect(held.checkpointRestoreOperation(review.id)?.phase == .accepted)
        #expect(held.isCheckpointRestoreLocked(threadID: f.seed.threadID))

        await f.provider.closeGate.release()
        try await restoreMetadataEventually { await f.engine.current().snapshot.checkpointRestoreOperation(review.id)?.phase == .applied }
        let modelsResult = await task.result
        if case .success = modelsResult { Issue.record("A metadata query cannot publish models after restoration takes its connection.") }
        #expect(await f.peer.calls == [review.id])
        #expect(await f.provider.sends == 0)
        #expect(await f.engine.current().snapshot.threads[0] == f.seed.thread)
        await f.finish(models: models)
    } catch { await f.finish(models: models); throw error }
}

@Test(.timeLimit(.minutes(1)))
func checkpointRestoreRejectsAnotherOwnersDetachedClosingMetadataAtItsOldWorkspace() async throws {
    let f = try await RestoreMetadataFixture(sharedOwner: true)
    var models: Task<[ProviderModel], any Error>?
    do {
        let other = try #require(f.other)
        let task = Task { try await f.engine.models(thread: other) }; models = task
        try await restoreMetadataEventually { await f.provider.modelsGate.entered }
        let movedPath = "/tmp/coincide-restore-metadata-unrelated-" + UUID().uuidString
        try await f.engine.dispatch(.editThread(other.id, .workspacePath(movedPath)))
        try await restoreMetadataEventually { await f.provider.closeGate.entered }

        let moved = await f.engine.current().snapshot
        #expect(moved.threads.first(where: { $0.id == other.id })?.workspacePath == movedPath)
        #expect(moved.canReviewCheckpointRestore(threadID: f.seed.threadID), "The retained process cwd, rather than current snapshot ownership, must reject this review.")
        await #expect(throws: WorkspaceCommandError.self) { try await f.review() }
        #expect(await f.peer.calls.isEmpty)
        #expect(await f.engine.current().snapshot.checkpointRestoreOperations == nil)

        await f.provider.closeGate.release()
        // The movement receipt intentionally precedes process I/O. Join that exact
        // project's detached cleanup before expecting its old cwd to be released.
        await f.engine.awaitProjectRemovalCleanup(projectID: f.seed.thread.projectID)
        let modelsResult = await task.result
        if case .success = modelsResult { Issue.record("The model result from the moved workspace must be discarded.") }
        let review = try await f.review()
        try await f.engine.beginCheckpointRestore(review)
        try await restoreMetadataEventually { await f.engine.current().snapshot.checkpointRestoreOperation(review.id)?.phase == .applied }
        #expect(await f.peer.calls == [review.id])
        #expect(await f.provider.sends == 0)
        #expect(await f.provider.closes == 1)
        await f.finish(models: models)
    } catch { await f.finish(models: models); throw error }
}
