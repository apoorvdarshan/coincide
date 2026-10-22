import Foundation
import Testing
@testable import CoincideCore

private actor CodexLeaseGate {
    private(set) var entered = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { released = true; let owned = waiters; waiters = []; owned.forEach { $0.resume() } }
}
private actor CodexLeaseResult {
    private(set) var returned = false
    func mark() { returned = true }
}

/// Closing and the operation are independently gated: a closed process is not
/// proof that a cancellation-resistant owned credential/metadata job has joined.
private actor CodexLeasePeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private let path: String
    private let readGate: CodexLeaseGate?
    private let closeGate: CodexLeaseGate?
    private let completes: Bool
    private var runID: UUID?
    private(set) var reads: [String] = []
    private(set) var prompts: [String] = []
    private(set) var closes = 0
    private(set) var interrupts = 0
    private(set) var closeFinished = false
    init(path: String, readGate: CodexLeaseGate? = nil, closeGate: CodexLeaseGate? = nil, completes: Bool = false) {
        self.path = path; self.readGate = readGate; self.closeGate = closeGate; self.completes = completes
        (events, sink) = AsyncStream.makeStream()
    }
    private func read(_ name: String) async { reads.append(name); await readGate?.wait() }
    func models() async -> [ProviderModel] { await read("models"); return [.init(id: "lease-model", name: "Offline model")] }
    func codexAccountSnapshot() async -> CodexAccountSnapshot {
        await read("account")
        return .init(identity: .init(kind: .chatgpt, requiresOpenAIAuth: true, email: "ephemeral-lease-label@example.invalid"), usage: .unsupported)
    }
    func codexDefaultModelSelection() async throws -> CodexDefaultModelSelection {
        await read("defaults")
        return try .init(workspacePath: path, model: "lease-model", reasoningEffort: nil,
                         catalogModel: .init(id: "lease-model", name: "Offline model"))
    }
    func historyCapabilities(threadID: String) async throws -> ProviderHistoryCapabilities {
        await read("history")
        return .init(reference: try .init(provider: .codex, nativeThreadID: threadID), historyMode: .paginated,
                     canRead: true, canForkHead: true, canForkFromTurn: true, canRevertBeforeTurn: true)
    }
    func conversationSnapshot(threadID: String) throws -> ProviderConversationSnapshot {
        try .init(reference: .init(provider: .codex, nativeThreadID: threadID), workspacePath: path,
                  historyMode: .paginated, headTurnID: "lease-recorded-turn")
    }
    func historyPage(threadID: String, cursor: String?, limit: Int) throws -> ProviderHistoryPage {
        try .init(reference: .init(provider: .codex, nativeThreadID: threadID),
                  turns: [.init(id: "lease-recorded-turn", status: .completed)], nextCursor: nil)
    }
    func send(text: String, thread: CodingThread) {
        prompts.append(text); runID = thread.activeRun?.id
        guard let runID else { return }
        sink.yield(.context(runID: runID, event: .thread("native-lease-\(thread.id.uuidString)")))
        sink.yield(.context(runID: runID, event: .turn("turn-\(runID.uuidString)")))
        if completes { sink.yield(.context(runID: runID, event: .completed(.idle))) }
    }
    func interrupt() {
        interrupts += 1
        if let runID { sink.yield(.context(runID: runID, event: .completed(.interrupted))) }
    }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() async {
        closes += 1; await closeGate?.wait(); closeFinished = true; sink.finish()
    }
}

private final class CodexLeaseFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [CodingThread] = []
    private let metadata: CodexLeasePeer
    private let live: [UUID: CodexLeasePeer]
    init(metadata: CodexLeasePeer, live: [UUID: CodexLeasePeer] = [:]) { self.metadata = metadata; self.live = live }
    var launches: [CodingThread] { lock.withLock { captured } }
    func make(_ thread: CodingThread) -> any ProviderSession {
        lock.withLock { captured.append(thread) }
        return thread.activeRun.flatMap { _ in live[thread.id] } ?? metadata
    }
}

private struct CodexLeaseFixture: Sendable {
    let root: URL
    let database: URL
    let project: WorkspaceProject
    let configuration: CodexRuntimeConfiguration
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-codex-auth-lease-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = root.appendingPathComponent("workspace.sqlite"); project = .init(path: root.path)
        configuration = .init(instanceID: UUID(), selection: .custom, executable: "/fixture/offline/codex",
            homeDirectory: root.appendingPathComponent("Shared Home").path, authenticationMode: .ownedChatGPT,
            accountBinding: .init(profileID: UUID(), generation: UUID()))
    }
    func ownedThread() -> CodingThread {
        var thread = CodingThread(project: project); thread.codexRuntimeConfiguration = configuration
        thread.checkpointPolicy = .disabled; thread.draft = "Unsent draft survives the account change"
        return thread
    }
    func snapshot(_ threads: [CodingThread]) -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = threads; return snapshot
    }
    func engine(snapshot: WorkspaceSnapshot, factory: CodexLeaseFactory, checkpoint: (any RunCheckpointSession)? = nil) async throws -> WorkspaceEngine {
        try await WorkspaceDatabase(url: database).save(snapshot, event: "codex.auth.lease.fixture")
        let engine = try WorkspaceEngine(url: database, providerFactory: { factory.make($0) }, identityResolver: { _ in nil },
            checkpointFactory: { root in if let checkpoint { return checkpoint }; return GitCheckpointService(root: root) })
        _ = try await engine.load(); return engine
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func codexLeaseEventually(file: StaticString = #fileID, line: UInt = #line,
                                  _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("Codex auth lease fixture timed out at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func codexLeaseRejects(_ action: () async throws -> Void) async {
    do { try await action(); Issue.record("A held Codex account lease admitted provider work.") }
    catch { #expect(error is WorkspaceCommandError || error is CancellationError || error is ProviderHistoryError || error is CodexAccountError) }
}
private func codexLeaseRecorded(_ fixture: CodexLeaseFixture) throws -> (WorkspaceSnapshot, UUID) {
    let source = fixture.ownedThread(), runID = UUID(), runtimeID = UUID()
    var snapshot = fixture.snapshot([source])
    let commands: [EngineCommand] = [
        .client(.submit(threadID: source.id, text: "Recorded owned input")),
        .runtimeOpened(threadID: source.id, runID: runID, runtimeID: runtimeID),
        .provider(threadID: source.id, runtimeID: runtimeID, event: .thread("lease-recorded-native")),
        .provider(threadID: source.id, runtimeID: runtimeID, event: .turn("lease-recorded-turn")),
        .provider(threadID: source.id, runtimeID: runtimeID, event: .delta(id: "recorded-reply", role: .assistant, text: "Offline recorded reply")),
        .provider(threadID: source.id, runtimeID: runtimeID, event: .completed(.idle))
    ]
    for (index, command) in commands.enumerated() {
        snapshot = try WorkspaceDecision.make(command, id: index == 0 ? runID : UUID(), snapshot: snapshot, now: .now).snapshot
    }
    snapshot.threads[0].runtimeID = nil; snapshot.threads[0].draft = source.draft
    try WorkspaceJournal.validate(snapshot); return (snapshot, runID)
}

@Test(.timeLimit(.minutes(1)), arguments: ["account", "models", "defaults", "history"])
func codexAuthenticationLeaseJoinsBothNativeCloseAndCancellationResistantMetadataOperation(kind: String) async throws {
    let fixture = try CodexLeaseFixture(), readGate = CodexLeaseGate(), closeGate = CodexLeaseGate(), result = CodexLeaseResult()
    let (saved, runID) = try codexLeaseRecorded(fixture), thread = saved.threads[0]
    let peer = CodexLeasePeer(path: fixture.project.path, readGate: readGate, closeGate: closeGate)
    let factory = CodexLeaseFactory(metadata: peer), engine = try await fixture.engine(snapshot: saved, factory: factory)
    let read = Task<Void, any Error> {
        switch kind {
        case "account": _ = try await engine.codexAccountSnapshot(configuration: fixture.configuration)
        case "models": _ = try await engine.models(provider: .codex, codexRuntimeConfiguration: fixture.configuration)
        case "defaults": _ = try await engine.reviewCodexDefaultModel(threadID: thread.id)
        default: _ = try await engine.reviewConversationHistory(threadID: thread.id, runID: runID, kind: .forkAfterRun)
        }
    }
    do { try await codexLeaseEventually { await readGate.entered == 1 } }
    catch { await readGate.release(); await closeGate.release(); _ = await read.result; await engine.shutdown(); fixture.remove(); throw error }
    let change = Task { let lease = try await engine.beginCodexAuthentication(configuration: fixture.configuration); await result.mark(); return lease }
    do {
        try await codexLeaseEventually { await closeGate.entered == 1 }
        #expect(await result.returned == false)
        await closeGate.release(); try await codexLeaseEventually { await peer.closeFinished }
        try await engine.dispatch(.editThread(thread.id, .draft("Draft remains editable while the old metadata operation drains")))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await result.returned == false)
        await readGate.release()
        let lease = try await change.value
        do { try await read.value; Issue.record("Retired metadata published after the account lease.") }
        catch { #expect(error is CancellationError || error is ProviderHistoryError) }
        #expect(await peer.closes == 1)
        #expect(factory.launches.count == 1)
        let current = await engine.current()
        #expect(current.error == nil && current.snapshot.threads[0].draft.contains("remains editable"))
        await engine.endCodexAuthentication(leaseID: lease)
    } catch {
        await readGate.release(); await closeGate.release(); _ = await read.result
        if case .success(let lease) = await change.result { await engine.endCodexAuthentication(leaseID: lease) }
        await engine.shutdown(); fixture.remove(); throw error
    }
    await engine.shutdown(); fixture.remove()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codexAuthenticationLeasePreservesPausedQueueCapturesAndDraftsAcrossAccountPublicationAndReopen(signOut: Bool) async throws {
    let fixture = try CodexLeaseFixture()
    var owned = fixture.ownedThread(); owned.queuePaused = true
    owned.queuedTurns = [.init(id: UUID(), text: "Captured old-account FIFO", configuration: .init(thread: owned), createdAt: .now, checkpointPolicy: .disabled)]
    let originalQueue = owned.queuedTurns
    var cli = CodingThread(project: fixture.project); cli.checkpointPolicy = .disabled
    let cliPeer = CodexLeasePeer(path: fixture.project.path), metadata = CodexLeasePeer(path: fixture.project.path)
    let factory = CodexLeaseFactory(metadata: metadata, live: [cli.id: cliPeer])
    let engine = try await fixture.engine(snapshot: fixture.snapshot([owned, cli]), factory: factory)
    let lease = try await engine.beginCodexAuthentication(configuration: fixture.configuration)
    let rejectedID = UUID(), newerDraft = "Latest draft typed while authentication is held"
    let newBinding: CodexAccountBinding? = signOut ? nil : .init(profileID: UUID(), generation: UUID())
    do {
        await codexLeaseRejects { _ = try await engine.dispatch(.submit(threadID: owned.id, text: "Rejected input must not consume the draft"), id: rejectedID) }
        await codexLeaseRejects { _ = try await engine.dispatch(.resumeQueue(threadID: owned.id)) }
        try await engine.dispatch(.editThread(owned.id, .draft(newerDraft)))
        try await engine.dispatch(.editThread(owned.id, .pinned(true)))
        try await engine.dispatch(.interrupt(threadID: owned.id))
        try await engine.dispatch(.submit(threadID: cli.id, text: "Unrelated CLI input remains available"))
        try await codexLeaseEventually { await cliPeer.prompts.count == 1 }
        try await codexLeaseEventually { await engine.current().snapshot.threads.first(where: { $0.id == cli.id })?.activeRun?.nativeTurnID != nil }
        try await engine.dispatch(.interrupt(threadID: cli.id))
        try await codexLeaseEventually { await cliPeer.interrupts == 1 }
        try await engine.applyCodexAccountBinding(instanceID: fixture.configuration.instanceID, binding: newBinding, leaseID: lease)
        let state = await engine.current(), held = try #require(state.snapshot.threads.first { $0.id == owned.id })
        let other = try #require(state.snapshot.threads.first { $0.id == cli.id })
        #expect(state.error == nil && held.draft == newerDraft && held.isPinned && held.queuePaused && held.activeRun == nil)
        #expect(held.queuedTurns == originalQueue && held.codexRuntimeConfiguration == fixture.configuration.replacingAccountBinding(newBinding))
        #expect(other.codexRuntimeConfiguration == nil && other.runHistory?.first?.configuration.codexRuntimeConfiguration == nil)
        await engine.endCodexAuthentication(leaseID: lease)
        await codexLeaseRejects { _ = try await engine.dispatch(.submit(threadID: owned.id, text: "Rejected input must not consume the draft"), id: rejectedID) }
        await codexLeaseRejects { _ = try await engine.dispatch(.resumeQueue(threadID: owned.id)) }
        #expect(factory.launches.filter { $0.activeRun != nil }.count == 1)
    } catch { await engine.endCodexAuthentication(leaseID: lease); await engine.shutdown(); fixture.remove(); throw error }
    await engine.shutdown()
    let reopenedPeer = CodexLeasePeer(path: fixture.project.path)
    let reopenedFactory = CodexLeaseFactory(metadata: reopenedPeer)
    let reopened = try WorkspaceEngine(url: fixture.database, providerFactory: { reopenedFactory.make($0) }, identityResolver: { _ in nil })
    do {
        let snapshot = try await reopened.load(), restored = try #require(snapshot.threads.first { $0.id == owned.id })
        #expect(restored.queuedTurns == originalQueue && restored.queuePaused && restored.draft == newerDraft && restored.isPinned)
        #expect(restored.codexRuntimeConfiguration == fixture.configuration.replacingAccountBinding(newBinding))
        await codexLeaseRejects { _ = try await reopened.dispatch(.resumeQueue(threadID: owned.id)) }
        #expect(reopenedFactory.launches.isEmpty)
        if signOut {
            await codexLeaseRejects { _ = try await reopened.dispatch(.submit(threadID: owned.id, text: "Unsigned owned input")) }
            #expect(reopenedFactory.launches.isEmpty)
        } else {
            let explicitRunID = UUID()
            try await reopened.dispatch(.submit(threadID: owned.id, text: "New explicitly accepted account capture"), id: explicitRunID)
            let current = await reopened.current()
            let latest = try #require(current.snapshot.threads.first { $0.id == owned.id })
            // An explicit new submission may start while an older FIFO stays
            // paused. It must use the new account without replaying that FIFO.
            #expect(latest.queuedTurns == originalQueue && latest.queuePaused)
            #expect(latest.activeRun?.id == explicitRunID && latest.activeRun?.configuration.codexRuntimeBinding?.accountBinding == newBinding)
            try await codexLeaseEventually { await reopenedPeer.prompts == ["New explicitly accepted account capture"] }
            #expect(reopenedFactory.launches.count == 1 && reopenedFactory.launches.first?.activeRun?.id == explicitRunID)
        }
    } catch { await reopened.shutdown(); fixture.remove(); throw error }
    await reopened.shutdown(); fixture.remove()
}

@Test(.timeLimit(.minutes(1)))
func codexAuthenticationLeaseFencesMetadataHistoryAndReviewedDefaultAdmissionWithoutAnyLateFactory() async throws {
    let fixture = try CodexLeaseFixture(), (saved, runID) = try codexLeaseRecorded(fixture), thread = saved.threads[0]
    let metadata = CodexLeasePeer(path: fixture.project.path), factory = CodexLeaseFactory(metadata: metadata)
    let engine = try await fixture.engine(snapshot: saved, factory: factory)
    do {
        let selection = try await engine.reviewCodexDefaultModel(threadID: thread.id)
        let initialLaunches = factory.launches.count
        #expect(initialLaunches == 1)
        let lease = try await engine.beginCodexAuthentication(configuration: fixture.configuration)
        do {
            await codexLeaseRejects { _ = try await engine.models(provider: .codex, codexRuntimeConfiguration: fixture.configuration) }
            await codexLeaseRejects { _ = try await engine.codexAccountSnapshot(configuration: fixture.configuration) }
            await codexLeaseRejects { _ = try await engine.models(thread: thread) }
            await codexLeaseRejects { _ = try await engine.reviewCodexDefaultModel(threadID: thread.id) }
            await codexLeaseRejects { _ = try await engine.reviewConversationHistory(threadID: thread.id, runID: runID, kind: .rewindBeforeRun) }
            await codexLeaseRejects { _ = try await engine.dispatch(.editThread(thread.id, .codexDefaultModel(selection))) }
            #expect(factory.launches.count == initialLaunches)
            #expect(await metadata.reads == ["defaults"])
            try await engine.applyCodexAccountBinding(instanceID: fixture.configuration.instanceID, binding: .init(profileID: UUID(), generation: UUID()), leaseID: lease)
            await engine.endCodexAuthentication(leaseID: lease)
            await codexLeaseRejects { _ = try await engine.dispatch(.editThread(thread.id, .codexDefaultModel(selection))) }
        } catch { await engine.endCodexAuthentication(leaseID: lease); throw error }
        #expect(await engine.current().error == nil)
    } catch { await engine.shutdown(); fixture.remove(); throw error }
    await engine.shutdown(); fixture.remove()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codexAuthenticationLeaseFindsRetargetedOrDeletedMetadataAlreadyInClosingCleanup(removeOwner: Bool) async throws {
    let fixture = try CodexLeaseFixture(), thread = fixture.ownedThread(), gate = CodexLeaseGate(), result = CodexLeaseResult()
    let probeProject = WorkspaceProject(path: fixture.root.appendingPathComponent("Lease Probe").path)
    var probe = fixture.ownedThread(); probe.projectID = probeProject.id; probe.workspacePath = probeProject.path
    var saved = fixture.snapshot([thread, probe]); saved.projects.append(probeProject)
    let metadata = CodexLeasePeer(path: fixture.project.path, closeGate: gate), replacement = CodexLeasePeer(path: fixture.project.path)
    let factory = CodexLeaseFactory(metadata: metadata, live: [thread.id: replacement])
    let engine = try await fixture.engine(snapshot: saved, factory: factory)
    let read = Task { try await engine.models(thread: thread) }
    do { try await codexLeaseEventually { await gate.entered == 1 } }
    catch { await gate.release(); _ = await read.result; await engine.shutdown(); fixture.remove(); throw error }
    do {
        if removeOwner {
            try await engine.dispatch(.removeProject(projectID: fixture.project.id, expectedThreadIDs: [thread.id]))
        } else {
            try await engine.dispatch(.editThread(thread.id, .provider(.claude)))
        }
    } catch { await gate.release(); _ = await read.result; await engine.shutdown(); fixture.remove(); throw error }
    let previous = await engine.current().sequence
    let change = Task { let lease = try await engine.beginCodexAuthentication(configuration: fixture.configuration); await result.mark(); return lease }
    do {
        // This still-present owned header must be durably paused. It proves
        // reservation progressed even though the old actor's own header was
        // retargeted or deleted and its close lives only in retained cleanup.
        try await codexLeaseEventually {
            let current = await engine.current()
            return current.sequence > previous && current.snapshot.threads.first(where: { $0.id == probe.id })?.queuePaused == true
        }
        #expect(await result.returned == false)
        if !removeOwner {
            try await engine.dispatch(.editThread(thread.id, .draft("Retargeted provider can still draft while the old close drains")))
            try await engine.dispatch(.submit(threadID: thread.id, text: "New provider remains independent of the closing Codex actor"))
            try await codexLeaseEventually { await replacement.prompts.count == 1 }
        }
        await gate.release()
        let lease = try await change.value
        _ = await read.result
        #expect(await metadata.closes == 1)
        let state = await engine.current()
        #expect(state.error == nil)
        #expect(state.snapshot.threads.first(where: { $0.id == probe.id })?.queuePaused == true)
        #expect(removeOwner ? !state.snapshot.projects.contains(where: { $0.id == fixture.project.id }) : state.snapshot.threads.first(where: { $0.id == thread.id })?.provider == .claude)
        await engine.endCodexAuthentication(leaseID: lease)
    } catch {
        await gate.release(); _ = await read.result
        if case .success(let lease) = await change.result { await engine.endCodexAuthentication(leaseID: lease) }
        await engine.shutdown(); fixture.remove(); throw error
    }
    await engine.shutdown(); fixture.remove()
}

@Test(.timeLimit(.minutes(1)))
func codexAuthenticationLeaseDrainsBothActiveAndIdleActorsAfterFutureModelChanges() async throws {
    let fixture = try CodexLeaseFixture(), active = fixture.ownedThread(), idle = fixture.ownedThread()
    let activeGate = CodexLeaseGate(), idleGate = CodexLeaseGate(), result = CodexLeaseResult()
    let activePeer = CodexLeasePeer(path: fixture.project.path, closeGate: activeGate)
    let idlePeer = CodexLeasePeer(path: fixture.project.path, closeGate: idleGate, completes: true)
    let factory = CodexLeaseFactory(metadata: CodexLeasePeer(path: fixture.project.path), live: [active.id: activePeer, idle.id: idlePeer])
    let engine = try await fixture.engine(snapshot: fixture.snapshot([active, idle]), factory: factory)
    do {
        try await engine.dispatch(.submit(threadID: active.id, text: "Owned active turn"))
        try await engine.dispatch(.submit(threadID: idle.id, text: "Owned idle session"))
        try await codexLeaseEventually {
            let snapshot = await engine.current().snapshot
            return snapshot.threads.first(where: { $0.id == active.id })?.activeRun?.nativeTurnID != nil &&
                snapshot.threads.first(where: { $0.id == idle.id })?.runHistory?.last?.status == .completed
        }
        try await engine.dispatch(.editThread(active.id, .model("future-model")))
        try await engine.dispatch(.editThread(idle.id, .model("other-future-model")))
    } catch { await activeGate.release(); await idleGate.release(); await engine.shutdown(); fixture.remove(); throw error }
    let change = Task { let lease = try await engine.beginCodexAuthentication(configuration: fixture.configuration); await result.mark(); return lease }
    do {
        try await codexLeaseEventually {
            let active = await activeGate.entered, idle = await idleGate.entered
            return active == 1 && idle == 1
        }
        let state = await engine.current().snapshot
        #expect(state.threads.first(where: { $0.id == active.id })?.runHistory?.last?.status == .interrupted)
        #expect(state.threads.first(where: { $0.id == idle.id })?.runHistory?.last?.status == .completed)
        #expect(state.threads.allSatisfy { $0.activeRun == nil && $0.runtimeID == nil && $0.queuePaused })
        await activeGate.release(); try await codexLeaseEventually { await activePeer.closeFinished }
        try await Task.sleep(for: .milliseconds(20)); #expect(await result.returned == false)
        await idleGate.release(); let lease = try await change.value
        let activeCloses = await activePeer.closes, idleCloses = await idlePeer.closes
        #expect(activeCloses == 1 && idleCloses == 1)
        await engine.endCodexAuthentication(leaseID: lease)
        #expect(factory.launches.filter { $0.activeRun != nil }.count == 2)
    } catch {
        await activeGate.release(); await idleGate.release()
        if case .success(let lease) = await change.result { await engine.endCodexAuthentication(leaseID: lease) }
        await engine.shutdown(); fixture.remove(); throw error
    }
    await engine.shutdown(); fixture.remove()
}

private actor CodexLeaseCheckpoint: RunCheckpointSession {
    private(set) var preparing = false
    private(set) var captures = 0
    private let gate: CodexLeaseGate
    init(gate: CodexLeaseGate) { self.gate = gate }
    func prepare(id: UUID) async throws -> GitCheckpointPlan { preparing = true; await gate.wait(); throw CancellationError() }
    func capture(_ plan: GitCheckpointPlan) throws -> GitCheckpointReceipt { captures += 1; throw CancellationError() }
    func inspect(_ plan: GitCheckpointPlan) -> GitCheckpointInspection { .incomplete }
    func finalizeScratch(_ receipt: GitCheckpointReceipt) -> GitCheckpointScratchResult { .preserved }
}

@Test(.timeLimit(.minutes(1)))
func codexAuthenticationLeaseJoinsHeldCheckpointStartWithoutLaunchingOrReplayingProviderWork() async throws {
    let fixture = try CodexLeaseFixture(), gate = CodexLeaseGate(), checkpoint = CodexLeaseCheckpoint(gate: gate), result = CodexLeaseResult()
    var thread = fixture.ownedThread(); thread.checkpointPolicy = .automatic
    let factory = CodexLeaseFactory(metadata: CodexLeasePeer(path: fixture.project.path))
    let engine = try await fixture.engine(snapshot: fixture.snapshot([thread]), factory: factory, checkpoint: checkpoint)
    do {
        try await engine.dispatch(.submit(threadID: thread.id, text: "Do not dispatch before the original baseline completes"))
        try await codexLeaseEventually { await checkpoint.preparing }
    } catch { await gate.release(); await engine.shutdown(); fixture.remove(); throw error }
    let change = Task { let lease = try await engine.beginCodexAuthentication(configuration: fixture.configuration); await result.mark(); return lease }
    do {
        try await codexLeaseEventually { await engine.current().snapshot.threads[0].activeRun == nil }
        let held = await engine.current().snapshot.threads[0], record = try #require(held.runHistory?.last)
        #expect(record.status == .interrupted && record.stopRequested && record.checkpoints?.providerReleased == false)
        #expect(record.checkpoints?.pendingStart == nil && record.checkpoints?.baseline.phase == .interrupted)
        #expect(record.checkpoints?.postRun?.unavailableReason == .providerNotStarted)
        try await engine.dispatch(.editThread(thread.id, .draft("A newer draft while the old baseline still drains")))
        try await Task.sleep(for: .milliseconds(20)); #expect(await result.returned == false)
        await gate.release(); let lease = try await change.value
        try await engine.applyCodexAccountBinding(instanceID: fixture.configuration.instanceID, binding: .init(profileID: UUID(), generation: UUID()), leaseID: lease)
        await engine.endCodexAuthentication(leaseID: lease)
        let captures = await checkpoint.captures
        #expect(factory.launches.isEmpty && captures == 0)
        let replay = try await WorkspaceDatabase(url: fixture.database).rebuildProjection().snapshot
        #expect(replay.threads[0].activeRun == nil && replay.threads[0].runHistory?.last?.checkpoints?.pendingStart == nil)
        #expect(replay.threads[0].draft.contains("newer draft") && replay.threads[0].queuePaused)
    } catch {
        await gate.release()
        if case .success(let lease) = await change.result { await engine.endCodexAuthentication(leaseID: lease) }
        await engine.shutdown(); fixture.remove(); throw error
    }
    await engine.shutdown(); fixture.remove()
}
