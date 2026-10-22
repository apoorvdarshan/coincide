import Foundation
import Testing
@testable import CoincideCore

private struct TypedSteeringFixture {
    var snapshot = WorkspaceSnapshot()
    let incarnation = UUID(), runtimeID = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
    var thread: CodingThread { snapshot.threads[0] }
    var run: ActiveRun { thread.activeRun! }
    init(provider: ProviderKind = .pi, nativeTurn: Bool = false) throws {
        let project = WorkspaceProject(path: "/fixture/typed-steering")
        var thread = CodingThread(project: project); thread.provider = provider; thread.checkpointPolicy = .disabled
        if provider == .pi { thread.piConfiguration = .init(executable: "/fixture/pi") }
        snapshot.projects = [project]; snapshot.threads = [thread]
        try apply(.client(.submit(threadID: thread.id, text: "Original input")))
        let runID = run.id
        try apply(.runtimeOpened(threadID: thread.id, runID: runID, runtimeID: runtimeID))
        try apply(.provider(threadID: thread.id, runtimeID: runtimeID, event: .thread("/fixture/pi-session.jsonl")))
        if nativeTurn { try apply(.provider(threadID: thread.id, runtimeID: runtimeID, event: .turn("native-turn"))) }
        snapshot.threads[0].draft = "Exact Unicode guidance 😀 工作"
    }
    @discardableResult mutating func apply(_ command: EngineCommand) throws -> WorkspaceDecision {
        let decision = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: now)
        snapshot = decision.snapshot; return decision
    }
    func operation(target: ProviderSteeringTarget? = nil) -> PromptSteeringOperation {
        let input = QueuedTurn(id: UUID(), text: thread.draft, configuration: run.configuration, createdAt: now, checkpointPolicy: .disabled)
        return .init(threadID: thread.id, projectID: thread.projectID, sourceIncarnation: incarnation, runtimeID: runtimeID,
            runID: run.id, nativeThreadID: thread.providerThreadID!, target: target ?? .adapterRun(run.id), input: input,
            messageID: "user-" + input.id.uuidString, configuration: run.configuration, createdAt: now)
    }
}
private func typedSteeringEncoder() -> JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }

@Test func typedSteeringReceiptPreservesLegacyNativeBytesAndRejectsMissingAmbiguousOrInvalidTargets() throws {
    let legacy = Data(#"{"delivery":"acknowledged","turnID":"native-turn"}"#.utf8)
    let decoded = try JSONDecoder().decode(ProviderSteeringReceipt.self, from: legacy)
    #expect(decoded.target == .nativeTurn("native-turn") && decoded.adapterRunID == nil)
    #expect(try typedSteeringEncoder().encode(decoded) == legacy)
    let defaultDelivery = try JSONDecoder().decode(ProviderSteeringReceipt.self, from: Data(#"{"turnID":"native-turn"}"#.utf8))
    #expect(defaultDelivery == decoded)
    let runID = UUID(), local = try ProviderSteeringReceipt(target: .adapterRun(runID))
    let localBytes = try typedSteeringEncoder().encode(local)
    let localObject = try JSONDecoder().decode(JSONValue.self, from: localBytes)
    #expect(local.turnID == nil && local.target == .adapterRun(runID) && localObject["turnID"] == .null)
    #expect(try JSONDecoder().decode(ProviderSteeringReceipt.self, from: localBytes) == local)
    for invalid in [JSONValue.object([:]), .object(["turnID": .string("")]),
        .object(["adapterRunID": .string("not-a-uuid")]), .object(["turnID": .string("native"), "adapterRunID": .string(runID.uuidString)])] {
        let bytes = try typedSteeringEncoder().encode(invalid)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ProviderSteeringReceipt.self, from: bytes) }
    }
}

@Test(arguments: ProviderKind.allCases)
func typedSteeringAdapterTargetMatchesOnlyItsPiRunWithoutInventingNativeHistory(provider: ProviderKind) throws {
    var thread = CodingThread(project: WorkspaceProject(path: "/fixture/steering")); thread.provider = provider
    var run = ActiveRun(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
    let target = ProviderSteeringTarget.adapterRun(run.id)
    #expect(target.matches(run: run) == (provider == .pi))
    #expect(!ProviderSteeringTarget.adapterRun(UUID()).matches(run: run))
    run.nativeTurnID = "real-native-turn"
    #expect(!target.matches(run: run))
    #expect(ProviderSteeringTarget.nativeTurn("real-native-turn").matches(run: run))
    #expect(!ProviderSteeringTarget.nativeTurn("").matches(run: run))
}

@Test func typedSteeringPiAcceptanceAndLateReceiptRetainOneRunAndNoNativeTurnIDs() throws {
    var fixture = try TypedSteeringFixture()
    let originalRun = fixture.run, operation = fixture.operation()
    #expect(fixture.snapshot.promptSteeringTargetReason(threadID: fixture.thread.id) == nil)
    let accepted = try fixture.apply(.promptSteeringAccepted(operation))
    let request = WorkspaceEffectRequest.promptSteering(threadID: fixture.thread.id, operationID: operation.id)
    #expect(accepted.effects.map(\.request) == [request])
    try fixture.apply(.promptSteeringDispatching(operationID: operation.id, incarnation: fixture.incarnation))
    try fixture.apply(.client(.submit(threadID: fixture.thread.id, text: "Later FIFO")))
    try fixture.apply(.provider(threadID: fixture.thread.id, runtimeID: fixture.runtimeID,
        event: .context(runID: originalRun.id, event: .completed(.idle))))
    #expect(fixture.thread.activeRun == nil && fixture.thread.queuedTurns.map(\.text) == ["Later FIFO"])
    let receipt = try ProviderSteeringReceipt(target: .adapterRun(originalRun.id))
    try fixture.apply(.promptSteeringEffectResult(request, .promptSteeringDelivered(receipt), incarnation: fixture.incarnation))
    #expect(fixture.snapshot.promptSteering(operation.id)?.target == .adapterRun(originalRun.id))
    #expect(fixture.snapshot.promptSteering(operation.id)?.receipt?.turnID == nil)
    #expect(fixture.thread.runHistory?.first?.turnIDs == [] && fixture.thread.runHistory?.first?.id == originalRun.id)
    #expect(fixture.thread.messages.filter { $0.promptSteeringID == operation.id }.count == 1)
    #expect(fixture.thread.activeRun?.id != originalRun.id && fixture.thread.activeRun?.nativeTurnID == nil)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test func typedSteeringReducerRejectsWrongAdapterRunProviderReceiptAndDispatchAfterTargetChange() throws {
    var fixture = try TypedSteeringFixture()
    let wrongRun = fixture.operation(target: .adapterRun(UUID()))
    #expect(throws: (any Error).self) { try fixture.apply(.promptSteeringAccepted(wrongRun)) }
    var native = try TypedSteeringFixture(provider: .codex)
    #expect(native.snapshot.promptSteeringTargetReason(threadID: native.thread.id) != nil)
    let foreign = native.operation()
    #expect(throws: (any Error).self) { try native.apply(.promptSteeringAccepted(foreign)) }
    let operation = fixture.operation()
    try fixture.apply(.promptSteeringAccepted(operation))
    var changed = fixture
    try changed.apply(.provider(threadID: changed.thread.id, runtimeID: changed.runtimeID, event: .turn("unexpected-native-turn")))
    #expect(throws: (any Error).self) { try changed.apply(.promptSteeringDispatching(operationID: operation.id, incarnation: changed.incarnation)) }
    try fixture.apply(.promptSteeringDispatching(operationID: operation.id, incarnation: fixture.incarnation))
    let request = WorkspaceEffectRequest.promptSteering(threadID: fixture.thread.id, operationID: operation.id)
    for receipt in [try ProviderSteeringReceipt(target: .adapterRun(UUID())), try .init(turnID: "native-turn")] {
        #expect(throws: (any Error).self) { try fixture.apply(.promptSteeringEffectResult(request, .promptSteeringDelivered(receipt), incarnation: fixture.incarnation)) }
    }
    #expect(fixture.snapshot.promptSteering(operation.id)?.phase == .dispatching && fixture.thread.activeRun?.nativeTurnID == nil)
}

@Test func typedSteeringNativeOperationLegacyEncodingRoundTripHasNoNewTargetKeys() throws {
    let fixture = try TypedSteeringFixture(provider: .codex, nativeTurn: true)
    let operation = fixture.operation(target: .nativeTurn("native-turn"))
    let bytes = try typedSteeringEncoder().encode(operation)
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(object["adapterRunID"] == nil && object["target"] == nil && object["nativeTurnID"] as? String == "native-turn")
    let restored = try JSONDecoder().decode(PromptSteeringOperation.self, from: bytes)
    #expect(restored == operation && restored.target == .nativeTurn("native-turn"))
    #expect(try typedSteeringEncoder().encode(restored) == bytes)
    var ambiguous = object; ambiguous["adapterRunID"] = operation.runID.uuidString
    let corrupted = try JSONDecoder().decode(PromptSteeringOperation.self, from: JSONSerialization.data(withJSONObject: ambiguous))
    #expect(corrupted.target == nil)
    #expect(throws: (any Error).self) { try corrupted.validate() }
}

@Test(arguments: [PromptSteeringPhase.accepted, .dispatching])
func typedSteeringPiRestartNeverReplaysAndDatabaseReopenKeepsNativeHistoryEmpty(phase: PromptSteeringPhase) async throws {
    var fixture = try TypedSteeringFixture(); let operation = fixture.operation()
    try fixture.apply(.promptSteeringAccepted(operation))
    if phase == .dispatching { try fixture.apply(.promptSteeringDispatching(operationID: operation.id, incarnation: fixture.incarnation)) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-typed-steering-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: url)
    try await database.save(fixture.snapshot, event: "typed.steering.fixture")
    let reopened = try WorkspaceDatabase(url: url)
    let restored = try await reopened.load()
    #expect(restored.promptSteering(operation.id) == fixture.snapshot.promptSteering(operation.id))
    var recovered = restored; recovered.recoverInterruptedWork()
    #expect(recovered.promptSteering(operation.id)?.phase == (phase == .accepted ? .failed : .unconfirmed))
    #expect(recovered.promptSteering(operation.id)?.receipt == nil && recovered.promptSteering(operation.id)?.adapterRunID == operation.runID)
    #expect(recovered.threads[0].activeRun == nil && recovered.threads[0].runHistory?.first?.turnIDs == [])
    try WorkspaceJournal.validate(recovered)
}
