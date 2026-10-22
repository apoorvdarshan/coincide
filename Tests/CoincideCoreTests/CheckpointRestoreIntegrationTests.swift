import Foundation
import Testing
@testable import CoincideCore

private actor RealRestoreProbe {
    private(set) var writes: [UUID] = []
    func record(_ id: UUID) { writes.append(id) }
}

private struct RealRestoreSession: RunCheckpointSession {
    let service: GitCheckpointService
    let probe: RealRestoreProbe
    func prepare(id: UUID) async throws -> GitCheckpointPlan { try await service.prepare(id: id) }
    func capture(_ plan: GitCheckpointPlan) async throws -> GitCheckpointReceipt { try await service.capture(plan) }
    func inspect(_ plan: GitCheckpointPlan) async throws -> GitCheckpointInspection { try await service.inspect(plan) }
    func finalizeScratch(_ receipt: GitCheckpointReceipt) async throws -> GitCheckpointScratchResult { try await service.finalizeScratch(receipt) }
    func reviewRestore(target: GitCheckpointReceipt, id: UUID) async throws -> GitCheckpointRestoreReview { try await service.reviewRestore(target: target, id: id) }
    func restore(review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreReceipt {
        await probe.record(review.id)
        return try await service.restore(review: review)
    }
    func inspectRestore(review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreInspection { try await service.inspectRestore(review: review) }
    func discardRestoreReview(_ review: GitCheckpointRestoreReview) async throws -> GitCheckpointScratchResult { try await service.discardRestoreReview(review) }
}

@Test(.timeLimit(.minutes(1)))
func checkpointRestoreProductionGitThroughDurableEnginePreservesConversationAndMainCheckout() async throws {
    let f = try await CheckpointFixture.make()
    let worktree = f.root.appendingPathComponent("Isolated worktree")
    let databaseURL = f.root.appendingPathComponent("workspace.sqlite")
    let probe = RealRestoreProbe()
    var engine: WorkspaceEngine?
    do {
        try f.write(".gitignore", "ignored.txt\n")
        try await f.commitAll()
        _ = try await f.run(["worktree", "add", "-b", "restore-fixture", worktree.path])
        let mainState = try await f.state()
        let service = f.service(at: worktree)
        let baseline = try await service.capture(service.prepare())
        let project = WorkspaceProject(path: f.repository.path)
        var thread = CodingThread(project: project, model: "Retained model")
        thread.workspacePath = worktree.path
        thread.providerThreadID = "retained-native-thread"
        thread.draft = "Keep the latest draft"
        let run = ActiveRun(id: UUID(), configuration: .init(thread: thread), startedAt: Date(), nativeTurnID: "retained-native-turn")
        var record = ThreadRunRecord(run: run, origin: .user, userMessageID: "retained-user")
        record.status = .completed; record.endReason = .providerCompleted; record.endedAt = Date(); record.messageAttributionVersion = 1
        var attempt = ThreadRunCheckpointAttempt(id: baseline.plan.id, workspacePath: worktree.path, phase: .ready)
        attempt.plan = baseline.plan; attempt.receipt = baseline
        record.checkpoints = .init(baseline: attempt, providerReleased: true)
        var message = ChatMessage(id: "retained-user", role: .user, text: "Preserve this completed transcript")
        message.runReference = .init(threadID: thread.id, runID: run.id)
        thread.messages = [message]; thread.runHistory = [record]
        var seed = WorkspaceSnapshot(); seed.projects = [project]; seed.threads = [thread]
        try await WorkspaceDatabase(url: databaseURL).save(seed, event: "restore.integration.fixture")
        func makeEngine() throws -> WorkspaceEngine {
            try .init(url: databaseURL,
                      providerFactory: { _ in throw CoincideError("Checkpoint restoration must not launch a provider.") },
                      identityResolver: { _ in nil },
                      checkpointFactory: { root in RealRestoreSession(service: f.service(at: root), probe: probe) })
        }
        let first = try makeEngine(); engine = first
        _ = try await first.load()
        try Data("Later staged bytes\n".utf8).write(to: worktree.appendingPathComponent("tracked.txt"))
        _ = try await f.run(["add", "--", "tracked.txt"], at: worktree)
        try Data("Later working bytes\n".utf8).write(to: worktree.appendingPathComponent("tracked.txt"))
        try Data("Remove this nonignored addition\n".utf8).write(to: worktree.appendingPathComponent("new.txt"))
        try Data("Preserve this ignored addition\n".utf8).write(to: worktree.appendingPathComponent("ignored.txt"))
        let before = try await f.state(at: worktree)
        let cancelled = try await first.reviewCheckpointRestore(threadID: thread.id, runID: run.id, stage: .baseline, expectedAttemptID: attempt.id)
        await first.discardCheckpointRestoreReview(reviewID: cancelled.id)
        #expect(try await f.state(at: worktree) == before)
        #expect(!FileManager.default.fileExists(atPath: worktree.deletingLastPathComponent().appendingPathComponent(".coincide-restore-" + cancelled.id.uuidString + "/shadow").path))
        await #expect(throws: WorkspaceCommandError.self) { try await first.beginCheckpointRestore(cancelled) }
        let review = try await first.reviewCheckpointRestore(threadID: thread.id, runID: run.id, stage: .baseline, expectedAttemptID: attempt.id)
        #expect(try await f.state(at: worktree) == before)
        try await first.dispatch(.editThread(thread.id, .draft("Newest draft after reviewing files")))
        let accepted = try await first.beginCheckpointRestore(review)
        #expect(try await first.beginCheckpointRestore(review) == accepted)
        let deadline = ContinuousClock.now + .seconds(10)
        while (await first.current()).snapshot.checkpointRestoreOperation(review.id)?.isPending == true {
            guard ContinuousClock.now < deadline else { throw CoincideError("The real Git restoration did not finish.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let completed = await first.current().snapshot
        #expect(completed.checkpointRestoreOperation(review.id)?.phase == .applied)
        #expect(await probe.writes == [review.id])
        #expect(try Data(contentsOf: worktree.appendingPathComponent("tracked.txt")) == Data("Committed bytes\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("new.txt").path))
        #expect(try Data(contentsOf: worktree.appendingPathComponent("ignored.txt")) == Data("Preserve this ignored addition\n".utf8))
        #expect(try await f.run(["diff", "--cached", "--exit-code"], at: worktree).status == 0)
        let after = try await f.state(at: worktree)
        #expect(after.head == before.head && after.branches == before.branches)
        #expect(try await f.state() == mainState)
        var expected = thread; expected.draft = "Newest draft after reviewing files"; expected.updatedAt = completed.threads[0].updatedAt
        #expect(completed.threads[0] == expected)
        #expect(try await WorkspaceDatabase(url: databaseURL).rebuildProjection().snapshot == completed)
        await first.shutdown(); engine = nil
        let reopened = try makeEngine(); engine = reopened
        let restored = try await reopened.load()
        #expect(restored.checkpointRestoreOperation(review.id)?.phase == .applied)
        #expect(restored.threads[0] == expected)
        #expect(await probe.writes == [review.id])
        #expect(try await f.state(at: worktree) == after)
        let unused = try await reopened.reviewCheckpointRestore(threadID: thread.id, runID: run.id, stage: .baseline, expectedAttemptID: attempt.id)
        await reopened.shutdown(); engine = nil
        #expect(!FileManager.default.fileExists(atPath: worktree.deletingLastPathComponent().appendingPathComponent(".coincide-restore-" + unused.id.uuidString + "/shadow").path))
        #expect(try await f.state(at: worktree) == after)
        f.cleanup()
    } catch {
        await engine?.shutdown()
        f.cleanup()
        throw error
    }
}
