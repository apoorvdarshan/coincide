import Foundation
import Testing
@testable import CoincideCore

private struct RemoteCheckpointCoreFixture {
    let root: URL, database: URL
    let target: RemoteWorkspaceTarget
    let runID: UUID, attemptID: UUID
    let engine: WorkspaceEngine
    let workspace: RemoteWorkspaceService
    let service: RemoteCheckpointService
    let peer: RestoreEnginePeer
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("coincide-remote-checkpoint-core-\(UUID().uuidString)")
        var owned: WorkspaceEngine?
        do {
            for name in ["Main", "Checkout", "Host"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let project = WorkspaceProject(path: root.appendingPathComponent("Main").path)
            var thread = CodingThread(project: project, model: "Offline checkpoint fixture")
            thread.workspacePath = root.appendingPathComponent("Checkout").path; thread.checkpointPolicy = .automatic
            thread.draft = "Keep current draft"; thread.providerThreadID = "offline-native-thread"
            let now = Date(), runID = UUID(), attemptID = UUID()
            let run = ActiveRun(id: runID, configuration: .init(thread: thread), startedAt: now, nativeTurnID: "offline-turn")
            var record = ThreadRunRecord(run: run, origin: .user, userMessageID: "checkpoint-user")
            record.status = .completed; record.endReason = .providerCompleted; record.endedAt = now; record.messageAttributionVersion = 1
            var attempt = ThreadRunCheckpointAttempt(id: attemptID, workspacePath: thread.workspacePath, phase: .ready, now: now)
            let plan = try CheckpointRestoreFixture.plan(id: attemptID, path: thread.workspacePath)
            attempt.plan = plan; attempt.receipt = try .init(plan: plan, commit: String(repeating: "c", count: 40), tree: String(repeating: "d", count: 40))
            record.checkpoints = .init(baseline: attempt, providerReleased: true); thread.runHistory = [record]
            var message = ChatMessage(id: "checkpoint-user", role: .user, text: "Retain transcript")
            message.runReference = .init(threadID: thread.id, runID: runID); thread.messages = [message]
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            let database = root.appendingPathComponent("workspace.sqlite"), peer = RestoreEnginePeer()
            try await WorkspaceDatabase(url: database).save(snapshot, event: "fixture")
            let engine = try WorkspaceEngine(url: database, providerFactory: { _ in throw CoincideError("Checkpoint control must not launch a provider") },
                identityResolver: { _ in nil }, checkpointFactory: { _ in peer })
            owned = engine; _ = try await engine.load()
            let id = UUID(), workspace = try RemoteWorkspaceService(environmentID: id, engine: engine, dataDirectory: root.appendingPathComponent("Host"))
            let target = try await workspace.bind(.init(environmentID: id, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread)))
            let service = RemoteCheckpointService(environmentID: id, engine: engine, workspace: workspace)
            return .init(root: root, database: database, target: target, runID: runID, attemptID: attemptID, engine: engine, workspace: workspace, service: service, peer: peer)
        } catch { await owned?.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func review() async throws -> RemoteCheckpointReview {
        try await service.review(.init(target: target, runID: runID, stage: .baseline, attemptID: attemptID))
    }
    func request(_ action: RemoteCheckpointAction, target captured: RemoteWorkspaceTarget? = nil) -> RemoteEnvironmentCommandRequest {
        .init(environmentID: target.environmentID, command: .checkpoint(target: captured ?? target, action: action))
    }
    func perform(_ request: RemoteEnvironmentCommandRequest) async throws -> WorkspaceCommandReceipt {
        if let existing = try await engine.remoteEnvironmentReceipt(request) { return existing }
        let preparation = try await service.prepare(request.command)
        if case .checkpoint(let prepared) = preparation { try await workspace.admitCheckpointScope(prepared.scope) }
        return try await engine.dispatchRemoteEnvironment(request, preparation: preparation)
    }
    func close() async { await peer.release(); await service.close(); await workspace.close(); await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}
private func remoteCheckpointEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Checkpoint fixture did not reach its durable state") }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func remoteCheckpointOriginalUUIDAndInspectionRecoverWithoutRepeatingNativeRestore(mutated: Bool) async throws {
    let f = try await RemoteCheckpointCoreFixture.make()
    do {
        await f.peer.configure(mutated ? .uncertainAfter : .uncertainBefore)
        let review = try await f.review(), request = f.request(.beginRestore(reviewID: review.id, digest: review.digest))
        let receipt = try await f.perform(request)
        #expect(receipt.commandID == request.id && request.id != review.id && receipt.rejection == nil)
        try await remoteCheckpointEventually { await f.engine.current().snapshot.checkpointRestoreOperation(review.id)?.phase == .unconfirmed }
        #expect(try await WorkspaceDatabase(url: f.database).receipt(review.id) == nil)
        #expect(try await f.perform(request) == receipt)
        #expect(await f.peer.calls == [review.id])
        let inspect = f.request(.inspectRestore(operationID: review.id)), inspected = try await f.perform(inspect)
        #expect(inspected.commandID == inspect.id && inspected.rejection == nil)
        #expect(try await f.perform(inspect) == inspected)
        #expect(await f.engine.current().snapshot.checkpointRestoreOperation(review.id)?.phase == (mutated ? .applied : .failed))
        #expect(await f.peer.calls == [review.id])
        #expect(await f.engine.current().snapshot.threads[0].draft == "Keep current draft")
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["configuration", "policy", "discard", "digest"])
func remoteCheckpointPreparedRestoreRejectsStaleAuthorityBeforeAnyWrite(change: String) async throws {
    let f = try await RemoteCheckpointCoreFixture.make()
    do {
        let review = try await f.review(), request = f.request(.beginRestore(reviewID: review.id, digest: review.digest))
        let preparation = try await f.service.prepare(request.command)
        var dispatched = request
        switch change {
        case "configuration": _ = try await f.engine.dispatch(.editThread(f.target.threadID, .model("Changed model")))
        case "policy": _ = try await f.engine.dispatch(.editThread(f.target.threadID, .checkpointPolicy(.disabled)))
        case "discard": _ = try await f.service.discard(.init(target: f.target, reviewID: review.id, digest: review.digest))
        default: dispatched = f.request(.beginRestore(reviewID: review.id, digest: String(repeating: "0", count: 64)))
        }
        let receipt = try await f.engine.dispatchRemoteEnvironment(dispatched, preparation: preparation)
        #expect(receipt.rejection != nil)
        #expect(try await f.engine.remoteEnvironmentReceipt(dispatched) == receipt)
        #expect(await f.peer.calls.isEmpty)
        _ = try await f.service.discard(.init(target: f.target, reviewID: review.id, digest: review.digest))
        #expect(await f.peer.discarded == [review.id])
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteCheckpointMissingRootAcknowledgementIsMetadataOnlyAndPreservesRecoveryScratch() async throws {
    let f = try await RemoteCheckpointCoreFixture.make()
    do {
        await f.peer.configure(.uncertainBefore)
        let review = try await f.review()
        _ = try await f.perform(f.request(.beginRestore(reviewID: review.id, digest: review.digest)))
        try await remoteCheckpointEventually { await f.engine.current().snapshot.checkpointRestoreOperation(review.id)?.phase == .unconfirmed }
        let before = await f.peer.inspections
        try FileManager.default.removeItem(atPath: f.target.workspacePath)
        let unbound = RemoteWorkspaceTarget(environmentID: f.target.environmentID, projectID: f.target.projectID, threadID: f.target.threadID, configuration: f.target.configuration)
        let request = f.request(.acknowledgeRestore(operationID: review.id), target: unbound)
        #expect(try await f.perform(request).rejection == nil)
        #expect(await f.engine.current().snapshot.checkpointRestoreOperation(review.id)?.acknowledgedAt != nil)
        #expect(await f.peer.inspections == before)
        #expect(await f.peer.calls == [review.id])
        #expect(await f.peer.discarded.isEmpty)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteCheckpointInventoryIsReadOnlyAndUnacceptedReviewCloseDisposesExactScratch() async throws {
    let f = try await RemoteCheckpointCoreFixture.make()
    do {
        let read = try await f.service.read(.init(target: f.target, query: .inventory))
        guard case .inventory(let inventory) = read.value else { throw CoincideError("Missing checkpoint inventory") }
        #expect(inventory.policy == .automatic && inventory.runs.count == 1)
        #expect(inventory.runs[0].baseline.id == f.attemptID && inventory.runs[0].restoreUnavailableReasons.isEmpty)
        #expect(await f.peer.reviewed.isEmpty)
        let review = try await f.review()
        await f.service.close(); await f.service.close()
        #expect(await f.peer.discarded == [review.id])
        #expect(await f.peer.calls.isEmpty)
    } catch { await f.close(); throw error }
    await f.close()
}

private actor RemoteCheckpointCloseObservation {
    private(set) var finished = false
    func finish() { finished = true }
}

@Test(.timeLimit(.minutes(1)))
func remoteCheckpointCloseWaitsForLateNativeReviewDisposalWithoutPublishingItsCache() async throws {
    let f = try await RemoteCheckpointCoreFixture.make(), gate = RestoreEngineGate()
    let observation = RemoteCheckpointCloseObservation()
    await f.peer.holdReview(gate)
    let review = Task { try await f.review() }
    do {
        try await remoteCheckpointEventually { await gate.entered }
        let nativeIDs = await f.peer.reviewed
        #expect(nativeIDs.count == 1)
        let close = Task { await f.service.close(); await observation.finish() }
        // Observe the closed Engine generation, proving close reached its drain
        // while the native reader still owns the gated sealed review.
        try await remoteCheckpointEventually {
            do { _ = try await f.engine.readRemoteCheckpoint(.init(target: f.target, query: .inventory)); return false }
            catch let error as RemoteCheckpointFailure { return error.kind == .unavailable }
        }
        #expect(await observation.finished == false)
        #expect(await f.peer.discarded.isEmpty)
        await gate.release()
        await #expect(throws: RemoteCheckpointFailure(.unavailable)) { _ = try await review.value }
        await close.value
        #expect(await observation.finished)
        #expect(await f.peer.discarded == nativeIDs)
        #expect(await f.peer.calls.isEmpty)
        #expect(await f.engine.current().snapshot.checkpointRestoreOperations?.isEmpty ?? true)
    } catch { await gate.release(); _ = try? await review.value; await f.close(); throw error }
    await f.close()
}
