import Foundation
import CryptoKit
import Testing
@testable import CoincideCore

private struct SteeringFixture {
    var snapshot = WorkspaceSnapshot()
    let incarnation = UUID(), runtimeID = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var threadID: UUID { snapshot.threads[0].id }
    var runID: UUID { snapshot.threads[0].runHistory![0].id }
    init(path: String = "/tmp/coincide-steering-checkout") throws {
        let project = WorkspaceProject(path: path)
        var thread = CodingThread(project: project, model: "Captured active model")
        thread.checkpointPolicy = .disabled
        snapshot.projects = [project]; snapshot.threads = [thread]
        try apply(.client(.submit(threadID: thread.id, text: "Opening input")))
        try apply(.runtimeOpened(threadID: thread.id, runID: runID, runtimeID: runtimeID))
        try apply(.provider(threadID: thread.id, runtimeID: runtimeID, event: .thread("native-source")))
        try apply(.provider(threadID: thread.id, runtimeID: runtimeID, event: .turn("native-turn")))
        snapshot.threads[0].draft = "Steering input"
    }
    @discardableResult mutating func apply(_ command: EngineCommand) throws -> WorkspaceDecision {
        let decision = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: now)
        snapshot = decision.snapshot; return decision
    }
    func operation(queued: QueuedTurn? = nil) -> PromptSteeringOperation {
        let thread = snapshot.threads[0], run = thread.activeRun!
        let input = queued ?? QueuedTurn(id: UUID(), text: thread.draft, configuration: run.configuration, createdAt: now, checkpointPolicy: .disabled)
        return .init(threadID: thread.id, projectID: thread.projectID, sourceIncarnation: incarnation, runtimeID: runtimeID,
            runID: run.id, nativeThreadID: thread.providerThreadID!, nativeTurnID: run.nativeTurnID!, input: input,
            messageID: "user-\(input.id.uuidString)", queuedID: queued?.id, configuration: run.configuration, createdAt: now)
    }
    var request: WorkspaceEffectRequest { .promptSteering(threadID: threadID, operationID: snapshot.promptSteerings!.last!.id) }
}

@Test(arguments: [ProviderSteeringDelivery.acknowledged, .submitted])
func promptSteeringAcceptanceOutboxLateReceiptAndOriginalRunRemainOneFact(delivery: ProviderSteeringDelivery) throws {
    var f = try SteeringFixture()
    let original = f.snapshot.threads[0], operation = f.operation()
    let accepted = try f.apply(.promptSteeringAccepted(operation))
    #expect(accepted.effects == [.init(id: operation.effectID, request: f.request)])
    #expect(f.snapshot.threads[0].draft.isEmpty)
    #expect(f.snapshot.threads[0].activeRun == original.activeRun && f.snapshot.threads[0].runHistory == original.runHistory)
    try f.apply(.promptSteeringDispatching(operationID: operation.id, incarnation: f.incarnation))
    try f.apply(.client(.submit(threadID: f.threadID, text: "FIFO after steering")))
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .completed(.idle)))
    #expect(f.snapshot.threads[0].activeRun == nil && f.snapshot.threads[0].queuedTurns.count == 1)
    let receipt = try ProviderSteeringReceipt(turnID: operation.nativeTurnID, delivery: delivery)
    let result = try f.apply(.promptSteeringEffectResult(f.request, .promptSteeringDelivered(receipt), incarnation: f.incarnation))
    #expect(f.snapshot.promptSteering(operation.id)?.phase == .delivered)
    #expect(f.snapshot.threads[0].activeRun?.id != operation.runID)
    #expect(f.snapshot.threads[0].messages.filter { $0.id == operation.messageID }.count == 1)
    #expect(f.snapshot.threads[0].messages.first { $0.id == operation.messageID }?.runReference?.runID == operation.runID)
    #expect(f.snapshot.threads[0].runHistory?.first?.turnIDs == [operation.nativeTurnID])
    #expect(result.effects.count == 1)
    let duplicate = try f.apply(.promptSteeringEffectResult(f.request, .promptSteeringDelivered(receipt), incarnation: f.incarnation))
    #expect(duplicate.effects.isEmpty)
}

@Test(arguments: [false, true])
func promptSteeringProvenUnsentCompletionMovesExactlyOneRowIntoCapturedFollowup(stop: Bool) throws {
    var f = try SteeringFixture()
    let operation = f.operation()
    try f.apply(.promptSteeringAccepted(operation))
    try f.apply(.client(.submit(threadID: f.threadID, text: "Remaining FIFO")))
    if stop { try f.apply(.client(.interrupt(threadID: f.threadID))) }
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .completed(.idle)))
    let before = f.snapshot.threads[0].messages.first { $0.id == operation.messageID }
    let decision = try f.apply(.promptSteeringEffectResult(f.request, .promptSteeringUnsentCompleted, incarnation: f.incarnation))
    let thread = f.snapshot.threads[0]
    #expect(thread.messages.filter { $0.id == operation.messageID }.count == 1)
    if stop {
        #expect(f.snapshot.promptSteering(operation.id)?.phase == .failed)
        #expect(thread.activeRun == nil && thread.queuedTurns.map(\.text) == ["Remaining FIFO"])
        #expect(decision.effects.isEmpty)
    } else {
        #expect(f.snapshot.promptSteering(operation.id)?.phase == .queued)
        #expect(thread.activeRun?.id == operation.fallbackRunID)
        #expect(thread.messages.last?.id == operation.messageID && thread.messages.last?.createdAt == before?.createdAt)
        #expect(thread.messages.last?.runReference?.runID == operation.fallbackRunID)
        #expect(thread.queuedTurns.map(\.text) == ["Remaining FIFO"])
        #expect(thread.runHistory?.last?.userMessageID == operation.messageID)
        #expect(decision.effects.count == 1)
    }
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func promptSteeringPromotionRetainsExactQueueIdentityAttachmentsAndCurrentDraft() throws {
    var f = try SteeringFixture()
    try f.apply(.client(.submit(threadID: f.threadID, text: "Earlier FIFO")))
    try f.apply(.client(.submit(threadID: f.threadID, text: "Promote exact input")))
    let selectedAttachment = ChatAttachment(id: UUID(), name: "queued.txt", mimeType: "text/plain", byteCount: 4, digest: String(repeating: "a", count: 64), fileExtension: "txt")
    let draftAttachment = ChatAttachment(id: UUID(), name: "newer.txt", mimeType: "text/plain", byteCount: 4, digest: String(repeating: "b", count: 64), fileExtension: "txt")
    let selectedIndex = f.snapshot.threads[0].queuedTurns.count - 1
    f.snapshot.threads[0].queuedTurns[selectedIndex].attachments = [selectedAttachment]
    let selected = f.snapshot.threads[0].queuedTurns[selectedIndex]
    f.snapshot.threads[0].draft = "Unsent newer draft"; f.snapshot.threads[0].draftAttachments = [draftAttachment]
    let operation = f.operation(queued: selected)
    try f.apply(.promptSteeringAccepted(operation))
    #expect(f.snapshot.promptSteering(operation.id)?.input == selected)
    #expect(f.snapshot.threads[0].draft == "Unsent newer draft" && f.snapshot.threads[0].draftAttachments == [draftAttachment])
    #expect(f.snapshot.threads[0].messages.first { $0.id == operation.messageID }?.attachments == [selectedAttachment])
    #expect(f.snapshot.threads[0].queuedTurns.map(\.text) == ["Earlier FIFO"])
    var incompatible = try SteeringFixture()
    try incompatible.apply(.client(.submit(threadID: incompatible.threadID, text: "Future settings")))
    incompatible.snapshot.threads[0].queuedTurns[0].configuration.model = "Different queued model"
    let unavailable = incompatible.snapshot.promptSteeringTargetReason(threadID: incompatible.threadID, queuedID: incompatible.snapshot.threads[0].queuedTurns[0].id)
    #expect(unavailable?.contains("different captured settings") == true)
}

@Test(arguments: [PromptSteeringPhase.accepted, .dispatching])
func promptSteeringRestartNeverReplaysAndUnknownAcknowledgementDoesNotInventReceipt(phase: PromptSteeringPhase) throws {
    var f = try SteeringFixture(); let operation = f.operation()
    try f.apply(.promptSteeringAccepted(operation))
    if phase == .dispatching { try f.apply(.promptSteeringDispatching(operationID: operation.id, incarnation: f.incarnation)) }
    try f.apply(.client(.submit(threadID: f.threadID, text: "Retained FIFO")))
    var recovered = f.snapshot; recovered.recoverInterruptedWork()
    try WorkspaceJournal.validate(recovered)
    #expect(recovered.promptSteering(operation.id)?.phase == (phase == .accepted ? .failed : .unconfirmed))
    #expect(recovered.promptSteering(operation.id)?.receipt == nil)
    #expect(recovered.threads[0].activeRun == nil && recovered.threads[0].queuePaused)
    if phase == .dispatching {
        let decision = try WorkspaceDecision.make(.client(.acknowledgePromptSteering(operationID: operation.id)), id: UUID(), snapshot: recovered, now: f.now)
        #expect(decision.effects.isEmpty && decision.snapshot.threads[0].queuedTurns.count == 1)
        #expect(decision.snapshot.promptSteering(operation.id)?.receipt == nil && decision.snapshot.promptSteering(operation.id)?.phase == .unconfirmed)
        #expect(!decision.snapshot.isPromptSteeringHoldingQueue(threadID: f.threadID))
    }
    let events = try WorkspaceJournal.changes(from: f.snapshot, to: recovered)
    var replay = f.snapshot; for event in events { try event.apply(to: &replay) }
    #expect(replay == recovered)
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(recovered))
    #expect(decoded == recovered)
}

@Test func promptSteeringHistoryUsesNativeAcknowledgementAndKeepsFailedRowsOnlyInSourceAudit() throws {
    for result in [EffectResult.failed("Rejected"), .promptSteeringUnconfirmed,
                   .promptSteeringDelivered(try .init(turnID: "native-turn")),
                   .promptSteeringDelivered(try .init(turnID: "native-turn", delivery: .submitted))] {
        var f = try SteeringFixture(); let operation = f.operation()
        try f.apply(.promptSteeringAccepted(operation))
        try f.apply(.promptSteeringDispatching(operationID: operation.id, incarnation: f.incarnation))
        try f.apply(.promptSteeringEffectResult(f.request, result, incarnation: f.incarnation))
        try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .completed(.idle)))
        let raw = try f.snapshot.threads[0].transcriptPrefix(runID: f.runID, boundary: .afterRun)
        let value = f.snapshot.promptSteering(operation.id)!
        if value.phase == .failed {
            #expect(try f.snapshot.verifiedForkPrefix(raw).allSatisfy { $0.id != operation.messageID })
            #expect(raw.contains { $0.id == operation.messageID })
        } else if value.receipt?.delivery == .acknowledged {
            #expect(try f.snapshot.verifiedForkPrefix(raw).contains { $0.id == operation.messageID })
        } else {
            #expect(throws: WorkspaceCommandError.self) { try f.snapshot.verifiedForkPrefix(raw) }
        }
        let before = try f.snapshot.threads[0].transcriptPrefix(runID: f.runID, boundary: .beforeRun)
        #expect(!f.snapshot.hasUnverifiedSteering(in: before))
    }
}

private actor SteeringEnginePeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?, turnID: String?
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var capabilityRequests = 0
    private var capabilityGate: RestoreEngineGate?
    private var gatedCapabilityRequest: Int?
    let uncertain: Bool
    var probe: (@Sendable () async throws -> Void)?
    private(set) var starts: [String] = [], calls: [CodingThread] = []
    init(uncertain: Bool = false) { self.uncertain = uncertain; let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) { runID = thread.activeRun?.id; turnID = "turn-\(starts.count)"; starts.append(text); emit(.thread("native-source")); emit(.turn(turnID!)) }
    func steeringCapabilities() async -> ProviderSteeringCapabilities {
        capabilityRequests += 1
        if capabilityRequests == gatedCapabilityRequest, let capabilityGate { await capabilityGate.wait() }
        return .init(supportsActiveSteering: runID != nil)
    }
    func holdWorkerCapability(_ gate: RestoreEngineGate) { capabilityGate = gate; gatedCapabilityRequest = capabilityRequests + 2 }
    func requestApproval() { emit(.approval(.init(id: .string("approval"), method: "item/commandExecution/requestApproval", params: .object([:])))) }
    func configure(probe: @escaping @Sendable () async throws -> Void) { self.probe = probe }
    func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) async throws -> ProviderSteeringReceipt {
        calls.append(thread); try await probe?()
        if !released { await withCheckedContinuation { waiter = $0 } }
        if uncertain { throw ProviderSteeringError(.outcomeUncertain) }
        return try .init(turnID: expectedTurnID)
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func finish() { emit(.completed(.idle)); runID = nil; turnID = nil }
    private func emit(_ event: ProviderEvent) { if let runID { continuation.yield(.context(runID: runID, event: event)) } }
    func interrupt() { emit(.completed(.interrupted)); runID = nil; turnID = nil }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { release(); continuation.finish() }
}

private func steeringEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Steering did not reach its owned durable boundary") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func promptSteeringEnginePersistsDispatchBeforeRPCAndLateOutcomeNeverDuplicatesInput(uncertain: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-steering-engine-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("workspace.sqlite"), project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project, model: "Original captured settings"); thread.checkpointPolicy = .disabled
    var seed = WorkspaceSnapshot(); seed.projects = [project]; seed.threads = [thread]
    try await WorkspaceDatabase(url: url).save(seed, event: "fixture")
    let peer = SteeringEnginePeer(uncertain: uncertain)
    let engine = try WorkspaceEngine(url: url, providerFactory: { _ in peer }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load(); _ = try await engine.dispatch(.submit(threadID: thread.id, text: "Opening input"))
        try await steeringEventually { await engine.current().snapshot.threads[0].activeRun?.nativeTurnID != nil }
        let runID = try #require(await engine.current().snapshot.threads[0].activeRun?.id)
        await peer.configure {
            let database = try WorkspaceDatabase(url: url), saved = try await database.load()
            #expect(saved.promptSteerings?.last?.phase == .dispatching)
            let effects = try await database.effects()
            #expect(effects.filter { $0.request.promptSteeringOperationID != nil }.count == 1)
        }
        _ = try await engine.dispatch(.editThread(thread.id, .model("Future settings")))
        _ = try await engine.steerPrompt(threadID: thread.id, text: "Additional same-turn input", expectedRunID: runID)
        try await steeringEventually { await peer.calls.count == 1 }
        #expect(await peer.calls[0].model == thread.model)
        #expect(await peer.calls[0].providerThreadID == "native-source")
        #expect(await peer.calls[0].activeRun?.configuration.nativeThreadID == nil)
        _ = try await engine.dispatch(.submit(threadID: thread.id, text: "Remaining FIFO"))
        await peer.finish()
        try await steeringEventually { await engine.current().snapshot.threads[0].activeRun == nil }
        #expect(await peer.starts == ["Opening input"])
        await peer.release()
        try await steeringEventually { await engine.current().snapshot.promptSteerings?.last?.phase == (uncertain ? .unconfirmed : .delivered) }
        let current = await engine.current().snapshot, operation = try #require(current.promptSteerings?.last)
        #expect(current.threads[0].messages.filter { $0.promptSteeringID == operation.id }.count == 1)
        if uncertain {
            #expect(await peer.starts == ["Opening input"])
            await engine.shutdown()
            let replacement = SteeringEnginePeer(), reopened = try WorkspaceEngine(url: url, providerFactory: { _ in replacement }, identityResolver: { _ in nil })
            do {
                _ = try await reopened.load()
                #expect(await replacement.starts.isEmpty)
                #expect(await reopened.current().snapshot.promptSteering(operation.id)?.phase == .unconfirmed)
                _ = try await reopened.dispatch(.acknowledgePromptSteering(operationID: operation.id))
                #expect(await replacement.starts.isEmpty)
                _ = try await reopened.dispatch(.resumeQueue(threadID: thread.id))
                try await steeringEventually { await replacement.starts.count == 1 }
                #expect(await replacement.starts == ["Remaining FIFO"])
                #expect(await reopened.current().snapshot.promptSteering(operation.id)?.receipt == nil)
                await replacement.finish()
                try await steeringEventually { await reopened.current().snapshot.threads[0].activeRun == nil }
                await reopened.drainCommands()
                let replay = try await WorkspaceDatabase(url: url).rebuildProjection().snapshot
                #expect(replay == (await reopened.current().snapshot))
                await reopened.shutdown()
            } catch { await reopened.shutdown(); throw error }
        } else {
            try await steeringEventually { await peer.starts.count == 2 }
            #expect(await peer.starts == ["Opening input", "Remaining FIFO"])
            await peer.finish()
            try await steeringEventually { await engine.current().snapshot.threads[0].activeRun == nil }
            await engine.drainCommands()
            let persisted = try await WorkspaceDatabase(url: url).rebuildProjection().snapshot
            #expect(persisted == (await engine.current().snapshot))
        }
        try WorkspaceJournal.validate(await engine.current().snapshot)
        await engine.shutdown()
    } catch { await peer.release(); await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    try? FileManager.default.removeItem(at: root)
}

@Test func promptSteeringCapabilityRevisionChangesOnlyForTheExactLiveRuntimeAndRun() throws {
    var f = try SteeringFixture()
    let originalCount = f.snapshot.threads[0].messages.count
    try f.apply(.provider(threadID: f.threadID, runtimeID: UUID(), event: .steeringCapabilitiesChanged))
    #expect(f.snapshot.threads[0].steeringCapabilityRevision == nil)
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .context(runID: UUID(), event: .steeringCapabilitiesChanged)))
    #expect(f.snapshot.threads[0].steeringCapabilityRevision == nil)
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .steeringCapabilitiesChanged))
    #expect(f.snapshot.threads[0].steeringCapabilityRevision == 1 && f.snapshot.threads[0].messages.count == originalCount)
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .delta(id: "reply", role: .assistant, text: "A token")))
    #expect(f.snapshot.threads[0].steeringCapabilityRevision == 1)
    f.snapshot.threads[0].steeringCapabilityRevision = .max
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .steeringCapabilitiesChanged))
    #expect(f.snapshot.threads[0].steeringCapabilityRevision == 0)
    let encoded = try JSONEncoder().encode(f.snapshot)
    #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded).threads[0].steeringCapabilityRevision == 0)
    f.snapshot.recoverInterruptedWork()
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .steeringCapabilitiesChanged))
    #expect(f.snapshot.threads[0].steeringCapabilityRevision == 0)
}

@Test func promptSteeringRejectsMalformedAuditAndKeepsReservedInputIdentity() throws {
    var f = try SteeringFixture(); let operation = f.operation()
    try f.apply(.promptSteeringAccepted(operation))
    var malformed = operation; malformed.phase = .delivered
    #expect(throws: (any Error).self) { try malformed.validate() }
    var orphaned = f.snapshot; orphaned.promptSteerings = nil
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(orphaned) }
    var collision = CodingThread(project: f.snapshot.projects[0], model: "New thread")
    collision.id = operation.fallbackRunID
    #expect(throws: WorkspaceCommandError.self) {
        try WorkspaceDecision.make(.client(.createThread(collision)), id: UUID(), snapshot: f.snapshot, now: f.now)
    }
    let original = f.snapshot
    var other = f; other.snapshot.threads[0].draft = "Another valid steering input"
    let duplicate = other.operation()
    #expect(throws: WorkspaceCommandError.self) { try f.apply(.promptSteeringAccepted(duplicate)) }
    #expect(f.snapshot == original)
}

private extension SteeringFixture {
    func historyReview(_ kind: ConversationHistoryKind) throws -> ConversationHistoryReview {
        let thread = snapshot.threads[0], record = thread.runHistory![0]
        let raw = try thread.transcriptPrefix(runID: record.id, boundary: kind == .forkAfterRun ? .afterRun : .beforeRun)
        let prefix = kind == .forkAfterRun ? try snapshot.verifiedForkPrefix(raw) : raw
        return try .init(kind: kind, reviewedAt: now, sourceThreadID: thread.id, projectID: thread.projectID,
            runID: record.id, sourceIncarnation: incarnation, sourceConfiguration: .init(thread: thread),
            targetConfiguration: record.configuration, sourceReference: .init(provider: .codex, nativeThreadID: "native-source"),
            reviewedHeadTurnID: "native-turn", boundary: kind == .forkAfterRun ? .throughTurn("native-turn") : .beforeTurn("native-turn"),
            expectedResultHeadTurnID: kind == .forkAfterRun ? "native-turn" : nil, prefix: prefix,
            removedRunIDs: kind == .forkAfterRun ? [] : [record.id], removedMessageIDs: kind == .forkAfterRun ? [] : thread.visibleMessages.map(\.id),
            sourceFingerprint: snapshot.historySourceFingerprint(threadID: thread.id), targetThreadID: kind == .forkAfterRun ? UUID() : nil,
            suggestedTitle: "Acknowledged steering fork")
    }
}

@Test(arguments: [false, true])
func promptSteeringTerminalAuditDoesNotInvalidateLostHistoryReceiptAcrossShutdownAndRecovery(unknown: Bool) throws {
    var f = try SteeringFixture(); let operation = f.operation()
    try f.apply(.promptSteeringAccepted(operation))
    try f.apply(.promptSteeringDispatching(operationID: operation.id, incarnation: f.incarnation))
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .completed(.idle)))
    #expect(!f.snapshot.canReviewConversationHistory(threadID: f.threadID))
    let outcome: EffectResult = unknown ? .promptSteeringUnconfirmed : .promptSteeringDelivered(try .init(turnID: "native-turn"))
    try f.apply(.promptSteeringEffectResult(f.request, outcome, incarnation: f.incarnation))
    let review = try f.historyReview(.rewindBeforeRun)
    try f.apply(.conversationHistoryAccepted(review: review, title: nil))
    try f.apply(.conversationHistoryDispatching(threadID: f.threadID, operationID: review.id, incarnation: f.incarnation))
    let originalSteering = f.snapshot.promptSteering(operation.id)
    try f.apply(.pauseQueues)
    f.snapshot.recoverInterruptedWork()
    #expect(f.snapshot.promptSteering(operation.id) == originalSteering)
    #expect(try f.snapshot.historySourceFingerprint(threadID: f.threadID) == review.sourceFingerprint)
    let result = try ProviderConversationSnapshot(reference: review.sourceReference, workspacePath: review.targetConfiguration.workspacePath,
        historyMode: .paginated, headTurnID: nil)
    try f.apply(.conversationHistoryReconciled(operationID: review.id, incarnation: UUID(), result: .applied(result)))
    #expect(f.snapshot.conversationHistoryOperation(review.id)?.phase == .applied)
    #expect(f.snapshot.threads[0].visibleMessages.isEmpty)
    #expect(f.snapshot.threads[0].messages.first { $0.id == operation.messageID }?.removedByHistoryOperationID == review.id)
    f.snapshot.recoverInterruptedWork(); try WorkspaceJournal.validate(f.snapshot)
}

@Test(.timeLimit(.minutes(1)))
func promptSteeringAcknowledgedForkKeepsItsInheritedDeliveryAuditAfterSourceRemovalAndSQLiteReopen() async throws {
    var f = try SteeringFixture(); let operation = f.operation()
    try f.apply(.promptSteeringAccepted(operation)); try f.apply(.promptSteeringDispatching(operationID: operation.id, incarnation: f.incarnation))
    try f.apply(.promptSteeringEffectResult(f.request, .promptSteeringDelivered(try .init(turnID: "native-turn")), incarnation: f.incarnation))
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .completed(.idle)))
    let review = try f.historyReview(.forkAfterRun)
    try f.apply(.conversationHistoryAccepted(review: review, title: nil))
    try f.apply(.conversationHistoryDispatching(threadID: f.threadID, operationID: review.id, incarnation: f.incarnation))
    let result = try ProviderConversationSnapshot(reference: .init(provider: .codex, nativeThreadID: "native-fork"), workspacePath: review.targetConfiguration.workspacePath,
        historyMode: .paginated, headTurnID: "native-turn")
    try f.apply(.conversationHistoryEffectResult(.conversationHistory(threadID: f.threadID, operationID: review.id), .conversationHistoryConfirmed(result), incarnation: f.incarnation))
    let sourceID = f.threadID
    f.snapshot.threads.removeAll { $0.id == sourceID }
    try WorkspaceJournal.validate(f.snapshot)
    #expect(f.snapshot.threads[0].messages.first { $0.id == operation.messageID }?.promptSteeringID == operation.id)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-steering-fork-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("workspace.sqlite")
    try await WorkspaceDatabase(url: url).save(f.snapshot, event: "retained.fork.audit")
    let engine = try WorkspaceEngine(url: url, providerFactory: { _ in throw CoincideError("Reopen must not start a provider") }, identityResolver: { _ in nil })
    do {
        let reopened = try await engine.load(); try WorkspaceJournal.validate(reopened)
        #expect(reopened.threads[0].messages == review.prefix)
        #expect(reopened.promptSteering(operation.id)?.receipt?.delivery == .acknowledged)
        #expect(reopened.conversationHistoryOperation(review.id)?.phase == .applied)
        await engine.shutdown()
    } catch { await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    try? FileManager.default.removeItem(at: root)
}

@Test func promptSteeringProviderEchoCannotEraseOrForgeLocalInputAudit() throws {
    var f = try SteeringFixture(); let operation = f.operation()
    try f.apply(.promptSteeringAccepted(operation))
    let original = f.snapshot.threads[0].messages.last!
    var echo = ChatMessage(id: original.id, role: .assistant, text: "Provider replacement differs")
    echo.promptSteeringID = UUID(); echo.runReference = nil
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .message(echo)))
    #expect(f.snapshot.threads[0].messages.last == original)
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .delta(id: original.id, role: .user, text: "Unexpected echo delta")))
    #expect(f.snapshot.threads[0].messages.last == original)
    var newRow = ChatMessage(id: "provider-row", role: .assistant, text: "New provider row")
    newRow.promptSteeringID = operation.id
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .message(newRow)))
    #expect(f.snapshot.threads[0].messages.last?.promptSteeringID == nil)
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func promptSteeringRemovalRetainsAnHonestUnconfirmedAuditWithoutWorkingOrFallbackState() throws {
    var f = try SteeringFixture(); let operation = f.operation()
    try f.apply(.promptSteeringAccepted(operation)); try f.apply(.promptSteeringDispatching(operationID: operation.id, incarnation: f.incarnation))
    try f.apply(.client(.removeProject(projectID: operation.projectID, expectedThreadIDs: [f.threadID])))
    #expect(f.snapshot.threads.isEmpty && f.snapshot.projects.isEmpty)
    #expect(f.snapshot.promptSteering(operation.id)?.phase == .unconfirmed)
    #expect(f.snapshot.promptSteering(operation.id)?.isWorking == false && f.snapshot.promptSteering(operation.id)?.fallbackAllowed == false)
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func promptSteeringAbsentProofPreservesThePriorHistoryFingerprintEncoding() throws {
    let f = try SteeringFixture(), thread = f.snapshot.threads[0]
    struct LegacySource: Encodable {
        let id: UUID, projectID: UUID
        let configuration: ProviderConfiguration
        let messages: [ChatMessage]
        let records: [ThreadRunRecord]
        let checkpointPolicy: RunCheckpointPolicy?
        let activeRun: ActiveRun?
        let queuedTurns: [QueuedTurn]
        let runtimeRequests: [RuntimeRequest]
        let preparation: ThreadWorkspacePreparation?
        let settlement: ThreadSettlement?
        let archived: Bool, queuePaused: Bool
    }
    let records = thread.activeHistoryRuns.map { value in var value = value; value.checkpoints = nil; return value }
    let legacy = LegacySource(id: thread.id, projectID: thread.projectID, configuration: .init(thread: thread), messages: thread.visibleMessages,
        records: records, checkpointPolicy: thread.checkpointPolicy, activeRun: thread.activeRun, queuedTurns: thread.queuedTurns,
        runtimeRequests: thread.runtimeRequests, preparation: thread.workspacePreparation, settlement: thread.settlement,
        archived: thread.isArchived, queuePaused: thread.queuePaused)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let expected = SHA256.hash(data: try encoder.encode(legacy)).map { String(format: "%02x", $0) }.joined()
    #expect(try f.snapshot.historySourceFingerprint(threadID: thread.id) == expected)
}

@Test(.timeLimit(.minutes(1)))
func promptSteeringApprovalArrivingDuringWorkerPreflightPreventsRPCWithoutAnsweringIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-steering-approval-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("workspace.sqlite"), project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project, model: "Captured settings"); thread.checkpointPolicy = .disabled
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    try await WorkspaceDatabase(url: url).save(snapshot, event: "fixture")
    let peer = SteeringEnginePeer(), gate = RestoreEngineGate()
    let engine = try WorkspaceEngine(url: url, providerFactory: { _ in peer }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load(); _ = try await engine.dispatch(.submit(threadID: thread.id, text: "Opening input"))
        try await steeringEventually { await engine.current().snapshot.threads[0].activeRun?.nativeTurnID != nil }
        let runID = try #require(await engine.current().snapshot.threads[0].activeRun?.id)
        await peer.holdWorkerCapability(gate)
        _ = try await engine.steerPrompt(threadID: thread.id, text: "Wait for the approval", expectedRunID: runID)
        try await steeringEventually { await gate.entered }
        await peer.requestApproval()
        try await steeringEventually { await engine.current().snapshot.threads[0].runtimeRequests.count == 1 }
        await gate.release()
        try await steeringEventually { await engine.current().snapshot.promptSteerings?.last?.phase == .failed }
        #expect(await peer.calls.isEmpty)
        let current = await engine.current().snapshot
        #expect(current.threads[0].runtimeRequests.count == 1 && current.threads[0].runtimeRequests[0].responding == false)
        #expect(current.threads[0].activeRun?.id == runID && current.threads[0].state == .awaitingApproval)
        await engine.shutdown()
    } catch { await gate.release(); await peer.release(); await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    try? FileManager.default.removeItem(at: root)
}

@Test(arguments: [false, true])
func promptSteeringUnknownPausesFIFOAndAcknowledgementRequiresExplicitResume(parentCompletesFirst: Bool) throws {
    var f = try SteeringFixture(); let operation = f.operation()
    try f.apply(.promptSteeringAccepted(operation)); try f.apply(.promptSteeringDispatching(operationID: operation.id, incarnation: f.incarnation))
    if parentCompletesFirst { try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .completed(.idle))) }
    try f.apply(.promptSteeringEffectResult(f.request, .promptSteeringUnconfirmed, incarnation: f.incarnation))
    #expect(f.snapshot.threads[0].queuePaused)
    try f.apply(.client(.submit(threadID: f.threadID, text: "Held first FIFO input")))
    #expect(f.snapshot.threads[0].queuePaused)
    try f.apply(.client(.submit(threadID: f.threadID, text: "Held second FIFO input")))
    let ack = try f.apply(.client(.acknowledgePromptSteering(operationID: operation.id)))
    #expect(ack.effects.isEmpty && !f.snapshot.isPromptSteeringHoldingQueue(threadID: f.threadID))
    #expect(f.snapshot.threads[0].queuePaused && f.snapshot.promptSteering(operation.id)?.receipt == nil)
    if !parentCompletesFirst { try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .completed(.idle))) }
    #expect(f.snapshot.threads[0].activeRun == nil)
    #expect(f.snapshot.threads[0].queuedTurns.map(\.text) == ["Held first FIFO input", "Held second FIFO input"])
    let firstID = f.snapshot.threads[0].queuedTurns[0].id
    let resumed = try f.apply(.client(.resumeQueue(threadID: f.threadID)))
    #expect(resumed.effects.count == 1 && f.snapshot.threads[0].activeRun?.id == firstID)
    #expect(f.snapshot.threads[0].queuedTurns.map(\.text) == ["Held second FIFO input"])
    #expect(f.snapshot.threads[0].messages.filter { $0.id == operation.messageID }.count == 1)
    #expect(f.snapshot.promptSteering(operation.id)?.phase == .unconfirmed)
}

@Test(.timeLimit(.minutes(1)))
func promptSteeringDatabaseRequiresTheExactAcceptedOperationEffectAndDeduplicatesIt() async throws {
    var f = try SteeringFixture(); let before = f.snapshot, operation = f.operation()
    let decision = try f.apply(.promptSteeringAccepted(operation))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-steering-outbox-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    try await database.save(before, event: "fixture")
    var malformed = decision.effects[0]; malformed.id = UUID()
    await #expect(throws: CoincideError.self) {
        try await database.commit(decision.snapshot, event: "steering.accepted", commandID: UUID(), effects: [malformed])
    }
    #expect(try await database.load() == before)
    #expect(try await database.effects().isEmpty)
    let commandID = UUID()
    let receipt = try await database.commit(decision.snapshot, event: "steering.accepted", commandID: commandID, effects: decision.effects)
    let duplicate = try await database.commit(decision.snapshot, event: "steering.accepted", commandID: commandID, effects: decision.effects)
    #expect(receipt == duplicate)
    let effects = try await database.effects()
    #expect(effects.count == 1 && effects[0].id == operation.effectID && effects[0].request == f.request)
    #expect(try await database.load().promptSteering(operation.id)?.phase == .accepted)
    #expect(try await database.rebuildProjection().snapshot == decision.snapshot)
}
