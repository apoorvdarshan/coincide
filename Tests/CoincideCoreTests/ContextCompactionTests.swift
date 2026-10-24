import Foundation
import Testing
@testable import CoincideCore

private struct CompactionFixture {
    var snapshot = WorkspaceSnapshot()
    let incarnation = UUID(), runtimeID = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var id: UUID { snapshot.threads[0].id }
    init() {
        let project = WorkspaceProject(path: "/tmp/coincide-offline-compaction")
        var thread = CodingThread(project: project, model: "captured-model")
        thread.createdAt = now; thread.updatedAt = now; thread.runtimeID = runtimeID
        thread.providerThreadID = "owned-native-session"; thread.draft = "Unsent draft"
        thread.checkpointPolicy = .disabled
        thread.messages = [.init(role: .user, text: "Original question"), .init(role: .assistant, text: "Original public answer")]
        snapshot.projects = [project]; snapshot.threads = [thread]
    }
    func operation() -> ContextCompactionOperation {
        .init(thread: snapshot.threads[0], incarnation: incarnation, runtimeID: runtimeID, now: now)
    }
    @discardableResult mutating func apply(_ command: EngineCommand) throws -> WorkspaceDecision {
        let result = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: now)
        snapshot = result.snapshot; return result
    }
}

@Test func contextCompactionDurableAcceptanceDoesNotInventTurnOrCompletionAndLocksSettings() throws {
    var f = CompactionFixture(); let original = f.snapshot.threads[0], operation = f.operation()
    let accepted = try f.apply(.contextCompactionAccepted(operation))
    #expect(accepted.effects == [.init(id: operation.id, request: .contextCompaction(threadID: f.id, operationID: operation.id))])
    #expect(f.snapshot.contextCompaction(threadID: f.id)?.phase == .pending)
    #expect(f.snapshot.threads[0].isBusy && !f.snapshot.providerReady(for: f.snapshot.threads[0]))
    #expect(f.snapshot.threads[0].messages == original.messages && f.snapshot.threads[0].runHistory == original.runHistory)
    #expect(f.snapshot.threads[0].draft == original.draft && f.snapshot.threads[0].activeRun == nil)
    for command in [WorkspaceCommand.submit(threadID: f.id, text: "must not queue"), .editThread(f.id, .model("changed")), .editThread(f.id, .provider(.claude)), .resumeQueue(threadID: f.id)] {
        #expect(throws: WorkspaceCommandError.self) { try f.apply(.client(command)) }
    }
    try f.apply(.client(.editThread(f.id, .draft("New unsent draft"))))
    try f.apply(.contextCompactionDispatching(threadID: f.id, operationID: operation.id, incarnation: f.incarnation))
    #expect(f.snapshot.contextCompaction(threadID: f.id)?.phase == .running)
    try f.apply(.provider(threadID: f.id, runtimeID: f.runtimeID, event: .message(.init(role: .assistant, text: "private provider summary"))))
    try f.apply(.provider(threadID: f.id, runtimeID: f.runtimeID, event: .completed(.idle)))
    #expect(f.snapshot.contextCompaction(threadID: f.id)?.phase == .running)
    #expect(f.snapshot.threads[0].messages == original.messages)
    try f.apply(.effectResult(.contextCompaction(threadID: f.id, operationID: operation.id), .succeeded))
    #expect(f.snapshot.contextCompaction(threadID: f.id)?.phase == .completed)
    #expect(f.snapshot.threads[0].contextCompactionID == nil && !f.snapshot.threads[0].isBusy)
    #expect(f.snapshot.threads[0].runtimeID == f.runtimeID && f.snapshot.threads[0].draft == "New unsent draft")
    #expect(f.snapshot.threads[0].messages == original.messages && f.snapshot.threads[0].runHistory == original.runHistory)
    let completed = f.snapshot
    try f.apply(.effectResult(.contextCompaction(threadID: f.id, operationID: operation.id), .failed("late private failure")))
    #expect(f.snapshot == completed)
}

@Test(arguments: [false, true])
func contextCompactionCancellationAndRestartAreConservativeWithoutTranscriptMutation(dispatched: Bool) throws {
    var f = CompactionFixture(); let operation = f.operation(), original = f.snapshot.threads[0]
    try f.apply(.contextCompactionAccepted(operation))
    if dispatched { try f.apply(.contextCompactionDispatching(threadID: f.id, operationID: operation.id, incarnation: f.incarnation)) }
    let saved = f.snapshot
    let cancelled = try f.apply(.client(.interrupt(threadID: f.id)))
    #expect(cancelled.closeRuntimes == [f.id])
    #expect(f.snapshot.contextCompaction(threadID: f.id)?.phase == (dispatched ? .unconfirmed : .failed))
    #expect(f.snapshot.threads[0].runtimeID == nil && f.snapshot.threads[0].contextCompactionID == nil)
    #expect(f.snapshot.threads[0].messages == original.messages && f.snapshot.threads[0].draft == original.draft)
    try f.apply(.effectResult(.contextCompaction(threadID: f.id, operationID: operation.id), .succeeded))
    #expect(f.snapshot.contextCompaction(threadID: f.id)?.phase != .completed)
    var recovered = saved; recovered.recoverInterruptedWork()
    #expect(recovered.contextCompaction(threadID: f.id)?.phase == (dispatched ? .unconfirmed : .failed))
    #expect(recovered.threads[0].contextCompactionID == nil && recovered.threads[0].runtimeID == nil)
    #expect(recovered.threads[0].messages == original.messages && recovered.threads[0].draft == original.draft)
    try WorkspaceJournal.validate(recovered)
    var replay = saved
    for event in try WorkspaceJournal.changes(from: saved, to: recovered) { try event.apply(to: &replay) }
    #expect(replay == recovered)
    #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(recovered)) == recovered)
}

@Test func contextCompactionRejectsUnboundQueuedStaleOrDuplicateOperationsAndFencesOldCallbacks() throws {
    var f = CompactionFixture(); let operation = f.operation()
    var unbound = f.snapshot; unbound.threads[0].runtimeID = nil
    #expect(unbound.contextCompactionUnavailableReason(threadID: f.id) != nil)
    var queued = f.snapshot
    queued.threads[0].queuedTurns = [.init(id: UUID(), text: "waiting", configuration: .init(thread: f.snapshot.threads[0]), createdAt: f.now)]
    #expect(queued.contextCompactionUnavailableReason(threadID: f.id) != nil)
    f.snapshot.threads[0].model = "changed after confirmation"
    #expect(throws: WorkspaceCommandError.self) { try f.apply(.contextCompactionAccepted(operation)) }
    f.snapshot.threads[0].model = operation.configuration.model
    try f.apply(.contextCompactionAccepted(operation))
    #expect(throws: WorkspaceCommandError.self) { try f.apply(.contextCompactionAccepted(operation)) }
    #expect(throws: WorkspaceCommandError.self) { try f.apply(.contextCompactionDispatching(threadID: f.id, operationID: operation.id, incarnation: UUID())) }
    #expect(throws: WorkspaceCommandError.self) { try f.apply(.contextCompactionCancelled(threadID: f.id, operationID: UUID())) }
    #expect(throws: WorkspaceCommandError.self) { try f.apply(.client(.interruptFromAppMCP(threadID: f.id, expectedRunID: nil, expectedRuntimeID: f.runtimeID))) }
    try f.apply(.contextCompactionCancelled(threadID: f.id, operationID: operation.id))
    f.snapshot.threads[0].runtimeID = f.runtimeID
    let successor = f.operation(); try f.apply(.contextCompactionAccepted(successor))
    let before = f.snapshot
    try f.apply(.effectResult(.contextCompaction(threadID: f.id, operationID: operation.id), .succeeded))
    #expect(f.snapshot == before)
    let projectID = f.snapshot.projects[0].id, threadID = f.id
    try f.apply(.client(.removeProject(projectID: projectID, expectedThreadIDs: [threadID])))
    #expect(f.snapshot.threads.isEmpty && f.snapshot.contextCompactionOperations?.isEmpty == true)
    try f.apply(.effectResult(.contextCompaction(threadID: threadID, operationID: successor.id), .succeeded))
    #expect(f.snapshot.threads.isEmpty)
}

@Test func contextCompactionLedgerRejectsForgedBusyOwnershipAndSanitizesUnknownErrors() throws {
    var f = CompactionFixture(); let operation = f.operation()
    f.snapshot.threads[0].contextCompactionID = UUID()
    #expect(throws: CoincideError.self) { try WorkspaceJournal.validate(f.snapshot) }
    f.snapshot.threads[0].contextCompactionID = nil
    try f.apply(.contextCompactionAccepted(operation))
    var corrupt = f.snapshot; corrupt.threads[0].runtimeID = UUID()
    #expect(throws: CoincideError.self) { try WorkspaceJournal.validate(corrupt) }
    try f.apply(.contextCompactionDispatching(threadID: f.id, operationID: operation.id, incarnation: f.incarnation))
    try f.apply(.effectResult(.contextCompaction(threadID: f.id, operationID: operation.id), .failed("credential and private summary must not persist")))
    #expect(f.snapshot.contextCompaction(threadID: f.id)?.phase == .unconfirmed)
    #expect(f.snapshot.contextCompaction(threadID: f.id)?.error == ProviderContextCompactionError(.unconfirmed).localizedDescription)
}

private actor CompactionEnginePeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let output: AsyncStream<ProviderEvent>.Continuation
    private var waiter: CheckedContinuation<Void, any Error>?
    private var released = false
    private(set) var starts: [String] = [], compacted: [UUID] = [], closed = false
    var probe: (@Sendable () async throws -> Void)?
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; output = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) {
        starts.append(text)
        guard let run = thread.activeRun?.id else { return }
        output.yield(.context(runID: run, event: .thread("owned-native-session")))
        output.yield(.context(runID: run, event: .turn("opening-turn")))
        output.yield(.context(runID: run, event: .message(.init(role: .assistant, text: "Public reply"))))
        output.yield(.context(runID: run, event: .completed(.idle)))
    }
    func setProbe(_ value: @escaping @Sendable () async throws -> Void) { probe = value }
    func compactContext(thread: CodingThread, operationID: UUID) async throws -> ProviderContextCompactionReceipt {
        compacted.append(operationID); try await probe?()
        output.yield(.message(.init(role: .assistant, text: "Never publish provider summary")))
        if closed { throw ProviderContextCompactionError(.unconfirmed) }
        if !released { try await withCheckedThrowingContinuation { waiter = $0 } }
        return .init(provider: thread.provider, nativeThreadID: thread.providerThreadID!)
    }
    func finish() { released = true; waiter?.resume(); waiter = nil }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { closed = true; waiter?.resume(throwing: ProviderContextCompactionError(.unconfirmed)); waiter = nil; output.finish() }
}

private func compactionEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Compaction did not reach its owned boundary") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func contextCompactionEngineUsesOnlyExistingRuntimePersistsBeforeRPCAndCancelsExactOperation(cancel: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-compaction-engine-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("workspace.sqlite"), project = WorkspaceProject(path: directory.path)
    var thread = CodingThread(project: project, model: "fixture-model"); thread.checkpointPolicy = .disabled
    var seed = WorkspaceSnapshot(); seed.projects = [project]; seed.threads = [thread]
    try await WorkspaceDatabase(url: url).save(seed, event: "fixture")
    let peer = CompactionEnginePeer(), engine = try WorkspaceEngine(url: url, providerFactory: { _ in peer }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        await #expect(throws: WorkspaceCommandError.self) { try await engine.compactContext(threadID: thread.id, expectedConfiguration: .init(thread: thread), expectedRuntimeID: UUID()) }
        #expect(await peer.starts.isEmpty)
        #expect(await peer.compacted.isEmpty)
        _ = try await engine.dispatch(.submit(threadID: thread.id, text: "Opening input"))
        try await compactionEventually { let current = await engine.current().snapshot.threads[0]; return current.providerThreadID != nil && current.activeRun == nil }
        let bound = try #require(await engine.current().snapshot.threads.first), runtimeID = try #require(bound.runtimeID)
        await peer.setProbe {
            let database = try WorkspaceDatabase(url: url), saved = try await database.load()
            #expect(saved.contextCompaction(threadID: bound.id)?.phase == .running)
            #expect(try await database.effects().filter { if case .contextCompaction = $0.request { true } else { false } }.count == 1)
        }
        _ = try await engine.compactContext(threadID: thread.id, expectedConfiguration: .init(thread: bound), expectedRuntimeID: runtimeID)
        try await compactionEventually { await peer.compacted.count == 1 }
        let operation = try #require(await engine.current().snapshot.contextCompaction(threadID: thread.id))
        #expect(operation.phase == .running)
        await #expect(throws: WorkspaceCommandError.self) { try await engine.cancelContextCompaction(threadID: thread.id, operationID: UUID()) }
        if cancel { _ = try await engine.cancelContextCompaction(threadID: thread.id, operationID: operation.id) }
        else { await peer.finish() }
        try await compactionEventually { await engine.current().snapshot.contextCompaction(threadID: thread.id)?.phase == (cancel ? .unconfirmed : .completed) }
        let current = await engine.current().snapshot
        #expect(current.threads[0].messages == bound.messages && current.threads[0].runHistory == bound.runHistory)
        #expect(await peer.starts == ["Opening input"])
        #expect(await peer.compacted == [operation.id])
        if cancel { try await compactionEventually { await peer.closed } }
        let audit = try WorkspaceDatabase(url: url)
        try await compactionEventually {
            let effects = try await audit.effects().filter { $0.id == operation.id }
            return effects.count == 1 && effects[0].status == (cancel ? .cancelled : .succeeded)
        }
        let finishedEffects = try await audit.effects()
        #expect(!finishedEffects.contains { $0.status == .pending || $0.status == .running })
        #expect(await engine.current().error == nil)
        await engine.shutdown()
        // A completion must not retire/cancel its own already-settled executor.
        #expect(try await audit.effects().first(where: { $0.id == operation.id })?.status == (cancel ? .cancelled : .succeeded))
        let reopened = try WorkspaceEngine(url: url, providerFactory: { _ in throw CoincideError("Recovery must never start a provider") }, identityResolver: { _ in nil })
        _ = try await reopened.load()
        #expect(await reopened.current().snapshot.contextCompaction(threadID: thread.id)?.phase == (cancel ? .unconfirmed : .completed))
        #expect(await reopened.current().snapshot.threads[0].messages == bound.messages)
        await reopened.shutdown()
    } catch { await peer.close(); await engine.shutdown(); try? FileManager.default.removeItem(at: directory); throw error }
    try? FileManager.default.removeItem(at: directory)
}


@Test func contextCompactionPhaseErrorsAreConsistentAndWallClockReversalKeepsLedgerValid() throws {
    var f = CompactionFixture(); let operation = f.operation()
    try f.apply(.contextCompactionAccepted(operation))
    let pending = f.snapshot
    for phase in [ContextCompactionPhase.pending, .running, .completed] {
        var invalid = pending
        invalid.contextCompactionOperations?[0].phase = phase
        invalid.contextCompactionOperations?[0].error = ProviderContextCompactionError(.failed).localizedDescription
        invalid.threads[0].contextCompactionID = phase == .completed ? nil : operation.id
        #expect(throws: CoincideError.self) { try WorkspaceJournal.validate(invalid) }
    }
    for phase in [ContextCompactionPhase.failed, .unconfirmed] {
        var invalid = pending
        invalid.contextCompactionOperations?[0].phase = phase
        invalid.threads[0].contextCompactionID = nil
        #expect(throws: CoincideError.self) { try WorkspaceJournal.validate(invalid) }
        invalid.contextCompactionOperations?[0].error = ProviderContextCompactionError(phase == .failed ? .unconfirmed : .failed).localizedDescription
        #expect(throws: CoincideError.self) { try WorkspaceJournal.validate(invalid) }
    }
    let earlier = operation.createdAt.addingTimeInterval(-120)
    let dispatched = try WorkspaceDecision.make(.contextCompactionDispatching(threadID: f.id, operationID: operation.id, incarnation: f.incarnation), id: UUID(), snapshot: pending, now: earlier)
    #expect(dispatched.snapshot.contextCompaction(threadID: f.id)?.updatedAt == operation.createdAt)
    let finished = try WorkspaceDecision.make(.effectResult(.contextCompaction(threadID: f.id, operationID: operation.id), .succeeded), id: UUID(), snapshot: dispatched.snapshot, now: earlier)
    #expect(finished.snapshot.contextCompaction(threadID: f.id)?.phase == .completed)
    #expect(finished.snapshot.contextCompaction(threadID: f.id)?.updatedAt == operation.createdAt)
    try WorkspaceJournal.validate(finished.snapshot)
}
