import Foundation
import Testing
@testable import CoincideCore

private struct HistoryFilesGitSession: RunCheckpointSession {
    let real: RealRestoreSession
    let peer: HistoryEnginePeer
    let databaseURL: URL
    let restoreGate: HistoryEngineGate
    func prepare(id: UUID) async throws -> GitCheckpointPlan { try await real.prepare(id: id) }
    func capture(_ plan: GitCheckpointPlan) async throws -> GitCheckpointReceipt { try await real.capture(plan) }
    func inspect(_ plan: GitCheckpointPlan) async throws -> GitCheckpointInspection { try await real.inspect(plan) }
    func finalizeScratch(_ receipt: GitCheckpointReceipt) async throws -> GitCheckpointScratchResult { try await real.finalizeScratch(receipt) }
    func reviewRestore(target: GitCheckpointReceipt, id: UUID) async throws -> GitCheckpointRestoreReview { try await real.reviewRestore(target: target, id: id) }
    func discardRestoreReview(_ review: GitCheckpointRestoreReview) async throws -> GitCheckpointScratchResult { try await real.discardRestoreReview(review) }
    func inspectRestore(review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreInspection { try await real.inspectRestore(review: review) }
    func restore(review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreReceipt {
        let saved = try await WorkspaceDatabase(url: databaseURL).load()
        let operation = try #require(saved.conversationHistoryOperations?.first { $0.files?.review.id == review.id })
        #expect(operation.phase == .applied && operation.result?.headTurnID == "native-1")
        #expect(operation.files?.phase == .dispatching)
        let native = try await peer.snapshot("native-source")
        #expect(native.headTurnID == "native-1")
        await restoreGate.wait()
        return try await real.restore(review: review)
    }
}

private struct HistoryFilesGitFixture {
    let git: CheckpointFixture
    let worktree: URL
    let databaseURL: URL
    let source: CodingThread
    let runs: [UUID]
    let baselines: [GitCheckpointReceipt]
    let posts: [GitCheckpointReceipt]
    let mainState: CheckpointUserState
    let before: CheckpointUserState
    let peer: HistoryEnginePeer
    let probe: RealRestoreProbe
    let providerGate: HistoryEngineGate
    let restoreGate: HistoryEngineGate
    let engine: WorkspaceEngine
    static let targetBytes = Data("After the first visible provider run\n".utf8)
    static let selectedBaselineBytes = Data("User edits between the first post observation and the selected input\n".utf8)

    static func make() async throws -> Self {
        let git = try await CheckpointFixture.make()
        var opened: WorkspaceEngine?
        do {
            try git.write(".gitignore", "ignored.txt\n")
            try await git.commitAll()
            let requested = git.root.appendingPathComponent("Combined isolated worktree")
            _ = try await git.run(["worktree", "add", "-b", "combined-rewind-fixture", requested.path])
            let worktree = requested.standardizedFileURL.resolvingSymlinksInPath()
            let mainState = try await git.state(), service = git.service(at: worktree)
            let project = WorkspaceProject(path: git.repository.path)
            var thread = CodingThread(project: project, model: "Current retained model")
            thread.workspacePath = worktree.path; thread.providerThreadID = "native-source"
            thread.checkpointPolicy = .disabled; thread.draft = "Original unsent draft"
            var runs: [UUID] = [], baselines: [GitCheckpointReceipt] = [], posts: [GitCheckpointReceipt] = []
            for index in 0..<3 {
                let baselineBytes = index == 1 ? selectedBaselineBytes : Data("Before local provider run \(index + 1)\n".utf8)
                try baselineBytes.write(to: worktree.appendingPathComponent("tracked.txt"))
                let baseline = try await service.capture(service.prepare())
                let postBytes = index == 0 ? targetBytes : Data("After local provider run \(index + 1)\n".utf8)
                try postBytes.write(to: worktree.appendingPathComponent("tracked.txt"))
                let post = try await service.capture(service.prepare())
                let id = UUID(), userID = "combined-user-\(index + 1)"
                var configuration = ProviderConfiguration(thread: thread)
                if index == 0 { configuration.nativeThreadID = nil }
                let active = ActiveRun(id: id, configuration: configuration, startedAt: baseline.capturedAt,
                    nativeTurnID: "native-\(index + 1)")
                var record = ThreadRunRecord(run: active, origin: .user, userMessageID: userID)
                record.providerThreadID = "native-source"; record.status = .completed
                record.endedAt = post.capturedAt; record.endReason = .providerCompleted; record.messageAttributionVersion = 1
                record.checkpoints = .init(baseline: attempt(baseline), providerReleased: true)
                record.checkpoints?.postRun = attempt(post)
                var user = ChatMessage(id: userID, role: .user, text: "Prompt \(index + 1)")
                var reply = ChatMessage(id: "combined-reply-\(index + 1)", role: .assistant, text: "Reply \(index + 1)")
                user.runReference = .init(threadID: thread.id, runID: id); reply.runReference = user.runReference
                thread.messages += [user, reply]
                if thread.runHistory == nil { thread.runHistory = [] }
                thread.runHistory!.append(record); runs.append(id); baselines.append(baseline); posts.append(post)
            }
            try Data("Current staged bytes\n".utf8).write(to: worktree.appendingPathComponent("tracked.txt"))
            _ = try await git.run(["add", "--", "tracked.txt"], at: worktree)
            try Data("Current working bytes\n".utf8).write(to: worktree.appendingPathComponent("tracked.txt"))
            try Data("A new nonignored file to remove\n".utf8).write(to: worktree.appendingPathComponent("new.txt"))
            try Data("An ignored file to preserve\n".utf8).write(to: worktree.appendingPathComponent("ignored.txt"))
            let before = try await git.state(at: worktree), databaseURL = git.root.appendingPathComponent("combined.sqlite")
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            try WorkspaceJournal.validate(snapshot)
            try await WorkspaceDatabase(url: databaseURL).save(snapshot, event: "combined.real.git.fixture")
            let peer = HistoryEnginePeer(workspace: worktree), probe = RealRestoreProbe()
            let providerGate = HistoryEngineGate(), restoreGate = HistoryEngineGate()
            let engine = try makeEngine(git: git, databaseURL: databaseURL, peer: peer, probe: probe, restoreGate: restoreGate)
            opened = engine; _ = try await engine.load()
            return .init(git: git, worktree: worktree, databaseURL: databaseURL, source: thread, runs: runs,
                baselines: baselines, posts: posts, mainState: mainState, before: before, peer: peer,
                probe: probe, providerGate: providerGate, restoreGate: restoreGate, engine: engine)
        } catch { await opened?.shutdown(); git.cleanup(); throw error }
    }
    static func attempt(_ receipt: GitCheckpointReceipt) -> ThreadRunCheckpointAttempt {
        var attempt = ThreadRunCheckpointAttempt(id: receipt.plan.id, workspacePath: receipt.plan.workspacePath,
            phase: .ready, now: receipt.capturedAt)
        attempt.plan = receipt.plan; attempt.receipt = receipt; return attempt
    }
    static func makeEngine(git: CheckpointFixture, databaseURL: URL, peer: HistoryEnginePeer,
                           probe: RealRestoreProbe, restoreGate: HistoryEngineGate) throws -> WorkspaceEngine {
        try .init(url: databaseURL, providerFactory: { HistoryEngineSession(peer: peer, thread: $0) },
            identityResolver: { _ in nil }, checkpointFactory: { root in
                HistoryFilesGitSession(real: .init(service: git.service(at: root), probe: probe), peer: peer,
                    databaseURL: databaseURL, restoreGate: restoreGate)
            })
    }
    func reopen() throws -> WorkspaceEngine {
        try Self.makeEngine(git: git, databaseURL: databaseURL, peer: peer, probe: probe, restoreGate: restoreGate)
    }
    func review() async throws -> ConversationHistoryReview {
        let keep = try await engine.reviewConversationHistory(threadID: source.id, runID: runs[1],
            kind: .rewindBeforeRun, recallPromptOnSuccess: true)
        let combined = try await engine.reviewConversationHistoryRestoringFiles(keep)
        await engine.discardConversationHistoryReview(reviewID: keep.id)
        return combined
    }
    func operation(_ id: UUID) async -> ConversationHistoryOperation? { await engine.current().snapshot.conversationHistoryOperation(id) }
    func finish(reopened: WorkspaceEngine? = nil) async {
        await providerGate.release(); await restoreGate.release()
        await reopened?.shutdown()
        await engine.shutdown(); git.cleanup()
    }
}

@Test(.timeLimit(.minutes(1)))
func conversationHistoryFilesRealGitRestoresPreviousPostOnlyAfterProviderAndRecallsLatestDraftOnce() async throws {
    let f = try await HistoryFilesGitFixture.make()
    var reopened: WorkspaceEngine?
    do {
        let review = try await f.review(), files = try #require(review.files)
        #expect(files.target.stage == .postRun && files.target.checkpointRunID == f.runs[0])
        #expect(files.target.receipt == f.posts[0] && files.target.receipt != f.baselines[1])
        #expect(try await f.git.blob(f.posts[0], "tracked.txt") == HistoryFilesGitFixture.targetBytes)
        #expect(try await f.git.blob(f.baselines[1], "tracked.txt") == HistoryFilesGitFixture.selectedBaselineBytes)
        #expect(try await f.git.state(at: f.worktree) == f.before)
        let db = f.databaseURL, probe = f.probe
        await f.peer.configure(gate: f.providerGate, probe: {
            let persisted = try await WorkspaceDatabase(url: db).load()
            let operation = try #require(persisted.conversationHistoryOperation(review.id))
            #expect(operation.phase == .dispatching && operation.files?.phase == .waitingForProvider)
            #expect(await probe.writes.isEmpty)
        })
        try await f.engine.dispatch(.editThread(f.source.id, .draft("Latest typing after file review")))
        let accepted = try await f.engine.beginConversationHistory(review)
        #expect(try await f.engine.beginConversationHistory(review) == accepted)
        try await historyEngineEventually { await f.providerGate.entered }
        #expect(try await f.git.state(at: f.worktree) == f.before)
        #expect(await f.probe.writes.isEmpty)
        #expect(await f.operation(review.id)?.files?.phase == .waitingForProvider)
        await f.providerGate.release()
        try await historyEngineEventually { await f.restoreGate.entered }
        let providerDone = await f.engine.current().snapshot
        #expect(providerDone.conversationHistoryOperation(review.id)?.phase == .applied)
        #expect(providerDone.threads[0].visibleMessages.map(\.text) == ["Prompt 1", "Reply 1"])
        #expect(try await f.git.state(at: f.worktree) == f.before)
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.dispatch(.recallConversationHistoryPrompt(operationID: review.id)) }
        await f.restoreGate.release()
        try await historyEngineEventually { await f.operation(review.id)?.files?.phase == .applied }
        let awaitingRecall = await f.engine.current().snapshot
        #expect(awaitingRecall.conversationHistoryOperation(review.id)?.needsPromptRecall == true)
        #expect(!awaitingRecall.providerReady(for: awaitingRecall.threads[0]))
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.dispatch(.submit(threadID: f.source.id, text: "Do not send while recall is pending")) }
        #expect(try Data(contentsOf: f.worktree.appendingPathComponent("tracked.txt")) == HistoryFilesGitFixture.targetBytes)
        #expect(!FileManager.default.fileExists(atPath: f.worktree.appendingPathComponent("new.txt").path))
        #expect(try Data(contentsOf: f.worktree.appendingPathComponent("ignored.txt")) == Data("An ignored file to preserve\n".utf8))
        let after = try await f.git.state(at: f.worktree)
        #expect(after.head == f.before.head && after.branches == f.before.branches)
        #expect(try await f.git.run(["diff", "--cached", "--exit-code"], at: f.worktree).status == 0)
        #expect(try await f.git.state() == f.mainState)
        try await f.engine.dispatch(.editThread(f.source.id, .draft("The newest saved draft")))
        try await f.engine.dispatch(.recallConversationHistoryPrompt(operationID: review.id))
        let completed = await f.engine.current().snapshot
        #expect(completed.threads[0].draft == "The newest saved draft\n\nPrompt 2")
        #expect(completed.threads[0].messages.count == 6 && completed.threads[0].runHistory?.count == 3)
        #expect(completed.providerReady(for: completed.threads[0]))
        try await f.engine.dispatch(.recallConversationHistoryPrompt(operationID: review.id))
        #expect(await f.engine.current().snapshot == completed)
        #expect(await f.probe.writes == [files.id])
        #expect(await f.peer.sends.isEmpty)
        #expect(await f.peer.mutations.count == 1)
        try WorkspaceJournal.validate(completed)
        #expect(try await WorkspaceDatabase(url: f.databaseURL).rebuildProjection().snapshot == completed)
        await f.engine.shutdown()
        let next = try f.reopen(); reopened = next
        let restored = try await next.load()
        #expect(restored.conversationHistoryOperation(review.id)?.allExternalWorkSucceeded == true)
        #expect(restored.threads[0].draft == completed.threads[0].draft)
        #expect(try await next.beginConversationHistory(review) == accepted)
        #expect(await f.probe.writes == [files.id])
        #expect(await f.peer.mutations.count == 1)
        #expect(await f.peer.sends.isEmpty)
        #expect(try await f.git.state(at: f.worktree) == after)
        #expect(try await f.git.state() == f.mainState)
        await next.shutdown(); reopened = nil; await f.finish()
    } catch { await f.finish(reopened: reopened); throw error }
}

@Test(.timeLimit(.minutes(1)))
func conversationHistoryFilesRealGitStaleReviewPreventsEvenProviderMutation() async throws {
    let f = try await HistoryFilesGitFixture.make()
    do {
        let review = try await f.review()
        try Data("An external edit after reviewing both systems\n".utf8).write(to: f.worktree.appendingPathComponent("tracked.txt"))
        let edited = try await f.git.state(at: f.worktree)
        try await f.engine.beginConversationHistory(review)
        try await historyEngineEventually { await f.operation(review.id)?.phase == .failed }
        #expect(await f.peer.mutations.isEmpty)
        #expect(await f.peer.sends.isEmpty)
        #expect(await f.probe.writes.isEmpty)
        let saved = await f.engine.current().snapshot
        #expect(saved.threads[0].visibleMessages == f.source.messages)
        #expect(saved.conversationHistoryOperation(review.id)?.files?.phase == .waitingForProvider)
        #expect(try await f.git.state(at: f.worktree) == edited)
        #expect(try await f.git.state() == f.mainState)
        try WorkspaceJournal.validate(saved)
        await f.finish()
    } catch { await f.finish(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [true, false])
func conversationHistoryFilesRealGitLostNativeAcknowledgementNeverStartsFilesOrReplaysOnInspection(mutated: Bool) async throws {
    let f = try await HistoryFilesGitFixture.make()
    var reopened: WorkspaceEngine?
    do {
        let review = try await f.review()
        await f.peer.configure(reply: mutated ? .lostAfterMutation : .lostBeforeMutation)
        try await f.engine.beginConversationHistory(review)
        try await historyEngineEventually { await f.operation(review.id)?.phase == .unconfirmed }
        #expect(await f.probe.writes.isEmpty)
        #expect(try await f.git.state(at: f.worktree) == f.before)
        #expect(await f.engine.current().snapshot.threads[0].visibleMessages.count == 6)
        await f.engine.shutdown()
        let next = try f.reopen(); reopened = next
        let loaded = try await next.load()
        #expect(loaded.conversationHistoryOperation(review.id)?.phase == .unconfirmed)
        #expect(await f.peer.mutations.count == 1)
        #expect(await f.peer.sends.isEmpty)
        try await next.reconcileConversationHistory(operationID: review.id)
        let reconciled = await next.current().snapshot
        let operation = try #require(reconciled.conversationHistoryOperation(review.id))
        #expect(operation.phase == (mutated ? .applied : .failed))
        #expect(reconciled.threads[0].visibleMessages.count == (mutated ? 2 : 6))
        #expect(!operation.allExternalWorkSucceeded && !operation.needsPromptRecall)
        #expect(operation.files?.phase == (mutated ? .failed : .waitingForProvider))
        if mutated {
            #expect(operation.files?.error == ConversationHistoryFilesState.notStartedMessage)
            #expect(operation.locksSource && operation.locksFiles)
            #expect(!reconciled.providerReady(for: reconciled.threads[0]))
        }
        await #expect(throws: WorkspaceCommandError.self) { try await next.inspectConversationHistoryFiles(operationID: review.id) }
        #expect(await f.probe.writes.isEmpty)
        #expect(await f.peer.sends.isEmpty)
        #expect(await f.peer.mutations.count == 1)
        let effects = try await WorkspaceDatabase(url: f.databaseURL).effects()
        #expect(!effects.contains { if case .conversationHistoryFiles = $0.request { return true }; return false })
        #expect(!effects.contains { $0.status == .pending || $0.status == .running })
        #expect(try await f.git.state(at: f.worktree) == f.before)
        #expect(try await f.git.state() == f.mainState)
        try WorkspaceJournal.validate(reconciled)
        await next.shutdown(); reopened = nil; await f.finish()
    } catch { await f.finish(reopened: reopened); throw error }
}
