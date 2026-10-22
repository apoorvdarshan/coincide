import Foundation
import Testing
@testable import CoincideCore

private actor AntigravityLeaseProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private(set) var prompts: [String] = []
    init() { (events, sink) = AsyncStream.makeStream() }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) { prompts.append(text) }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { sink.finish() }
}

/// Deliberately retains a native capture job after cancellation so the account
/// lease must await the existing cleanup owner. It never creates Git objects.
private actor AntigravityLeaseCheckpoint: RunCheckpointSession {
    private(set) var preparing = false, authReturned = false, captures = 0
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func prepare(id: UUID) async throws -> GitCheckpointPlan {
        preparing = true
        if !released { await withCheckedContinuation { waiter = $0 } }
        throw CancellationError()
    }
    func capture(_ plan: GitCheckpointPlan) throws -> GitCheckpointReceipt { captures += 1; throw CancellationError() }
    func inspect(_ plan: GitCheckpointPlan) -> GitCheckpointInspection { .incomplete }
    func finalizeScratch(_ receipt: GitCheckpointReceipt) -> GitCheckpointScratchResult { .preserved }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func returned() { authReturned = true }
}

@Test func antigravityAuthenticationLeaseRejectsSubmissionAndQueueResumeAtomicallyWithoutChangingIntent() async throws {
    let fixture = try AntigravityFixture(), provider = AntigravityLeaseProvider()
    let engine = try WorkspaceEngine(url: fixture.root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in provider }, identityResolver: { _ in nil })
    do {
        let project = WorkspaceProject(path: fixture.root.path)
        var thread = CodingThread(project: project)
        thread.provider = .antigravity; thread.antigravityConfiguration = fixture.configuration; thread.checkpointPolicy = .disabled
        thread.draft = "Latest unsent account-change draft"; thread.queuePaused = true
        thread.queuedTurns = [.init(id: UUID(), text: "Previously captured FIFO", configuration: .init(thread: thread), createdAt: .now, checkpointPolicy: .disabled)]
        var unrelated = CodingThread(project: project); unrelated.checkpointPolicy = .disabled
        var saved = WorkspaceSnapshot(); saved.projects = [project]; saved.threads = [thread, unrelated]
        let database = try WorkspaceDatabase(url: fixture.root.appendingPathComponent("workspace.sqlite"))
        try await database.save(saved, event: "Existing paused FIFO before account change")
        _ = try await engine.load()
        let lease = try await engine.beginAntigravityAuthentication(instanceID: fixture.configuration.instanceID)
        do {
            let commandID = UUID()
            do { try await engine.dispatch(.submit(threadID: thread.id, text: "Must not consume the draft"), id: commandID); Issue.record("An account lease admitted a new provider start.") }
            catch let error as WorkspaceCommandError { #expect(error.message.contains("account change")) }
            do { try await engine.dispatch(.resumeQueue(threadID: thread.id)); Issue.record("An account lease resumed a captured FIFO.") }
            catch let error as WorkspaceCommandError { #expect(error.message.contains("account change")) }
            let heldState = await engine.current(), held = try #require(heldState.snapshot.threads.first { $0.id == thread.id })
            #expect(held.activeRun == nil && held.draft == thread.draft && held.queuedTurns == thread.queuedTurns && held.queuePaused)
            #expect(heldState.error == nil)
            // Only the same Antigravity instance is leased. Other provider work
            // and ordinary draft edits remain available in the serialized inbox.
            try await engine.dispatch(.editThread(thread.id, .draft("Newer draft while the account dialog is open")))
            try await engine.dispatch(.submit(threadID: unrelated.id, text: "Unrelated provider remains usable"))
            try await antigravityEventually { await provider.prompts == ["Unrelated provider remains usable"] }
            let next = AntigravityConfiguration(instanceID: fixture.configuration.instanceID, executable: fixture.executable.path, authGeneration: UUID())
            try await engine.applyAntigravityAccountConfiguration(next)
            await engine.endAntigravityAuthentication(leaseID: lease)
            // Durable rejection is idempotent: replaying this same command ID
            // after the lease ends cannot turn it into a new native submission.
            do { try await engine.dispatch(.submit(threadID: thread.id, text: "Must not consume the draft"), id: commandID); Issue.record("A rejected submission was replayed after authentication.") }
            catch is WorkspaceCommandError {}
            let finalState = await engine.current(), final = try #require(finalState.snapshot.threads.first { $0.id == thread.id })
            #expect(final.activeRun == nil && final.queuePaused && final.queuedTurns == thread.queuedTurns)
            #expect(final.draft == "Newer draft while the account dialog is open" && final.antigravityConfiguration?.authGeneration == next.authGeneration)
            #expect(finalState.error == nil)
        } catch { await engine.endAntigravityAuthentication(leaseID: lease); throw error }
        await engine.shutdown(); try fixture.remove()
    } catch { await engine.shutdown(); try? fixture.remove(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func antigravityAuthenticationInterruptsHeldBaselineBeforeDrainingAndNeverDispatchesDeferredProviderWork() async throws {
    let fixture = try AntigravityFixture(), checkpoint = AntigravityLeaseCheckpoint(), provider = AntigravityLeaseProvider()
    let databaseURL = fixture.root.appendingPathComponent("workspace.sqlite")
    let engine = try WorkspaceEngine(url: databaseURL, providerFactory: { _ in provider }, identityResolver: { _ in nil }, checkpointFactory: { _ in checkpoint })
    do {
        _ = try await engine.load()
        let project = WorkspaceProject(path: fixture.root.path)
        var thread = CodingThread(project: project); thread.provider = .antigravity; thread.antigravityConfiguration = fixture.configuration
        try await engine.dispatch(.addProject(project)); try await engine.dispatch(.createThread(thread))
        try await engine.dispatch(.submit(threadID: thread.id, text: "Automatic baseline must finish before provider work"))
        try await antigravityEventually { await checkpoint.preparing }
        let beforeState = await engine.current().snapshot, before = try #require(beforeState.threads.first { $0.id == thread.id })
        #expect(before.runHistory?.last?.checkpoints?.pendingStart != nil)
        let change = Task {
            let lease = try await engine.beginAntigravityAuthentication(instanceID: fixture.configuration.instanceID)
            await checkpoint.returned(); return lease
        }
        do {
            try await antigravityEventually {
                let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
                return current?.activeRun == nil && current?.runHistory?.last?.status == .interrupted
            }
            let heldState = await engine.current(), held = try #require(heldState.snapshot.threads.first { $0.id == thread.id })
            let record = try #require(held.runHistory?.last)
            #expect(record.stopRequested && record.checkpoints?.pendingStart == nil && record.checkpoints?.providerReleased == false)
            #expect(record.checkpoints?.baseline.phase == .interrupted && record.checkpoints?.postRun?.unavailableReason == .providerNotStarted)
            let returned = await checkpoint.authReturned; #expect(!returned && heldState.error == nil)
            try await engine.dispatch(.editThread(thread.id, .draft("Draft stays editable while the old capture drains")))
            await checkpoint.release()
            let lease = try await change.value
            let next = AntigravityConfiguration(instanceID: fixture.configuration.instanceID, executable: fixture.executable.path, authGeneration: UUID())
            try await engine.applyAntigravityAccountConfiguration(next)
            await engine.endAntigravityAuthentication(leaseID: lease)
            let prompts = await provider.prompts, captures = await checkpoint.captures
            #expect(prompts.isEmpty && captures == 0)
            let finalState = await engine.current(); #expect(finalState.error == nil)
            let database = try WorkspaceDatabase(url: databaseURL), replay = try await database.rebuildProjection().snapshot
            let restored = try #require(replay.threads.first { $0.id == thread.id })
            #expect(restored.activeRun == nil && restored.runHistory?.last?.checkpoints?.pendingStart == nil)
            #expect(restored.draft == "Draft stays editable while the old capture drains")
        } catch { await checkpoint.release(); _ = await change.result; throw error }
        await engine.shutdown(); try fixture.remove()
    } catch { await checkpoint.release(); await engine.shutdown(); try? fixture.remove(); throw error }
}
