import Foundation
import Testing
@testable import CoincideCore

private let reasoningA = ProviderModel(id: "gpt-6-astra", name: "Astra", reasoningEfforts: ["low", "medium", "high", "xhigh"].map { .init(id: $0, description: $0) }, defaultReasoningEffort: "xhigh", catalogID: "catalog-astra")
private let reasoningB = ProviderModel(id: "other-wire-model", name: "Other", reasoningEfforts: ["low", "high", "future-effort"].map { .init(id: $0, description: $0) }, defaultReasoningEffort: "low", catalogID: "other-catalog")

private struct ReasoningFixture {
    var snapshot = WorkspaceSnapshot()
    let incarnation = UUID(), runtimeID = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var threadID: UUID { snapshot.threads[0].id }
    init(path: String = "/tmp/coincide-reasoning-checkout") {
        let project = WorkspaceProject(path: path)
        var thread = CodingThread(project: project, model: ""); thread.checkpointPolicy = .disabled
        snapshot.projects = [project]; snapshot.threads = [thread]
    }
    @discardableResult mutating func apply(_ command: EngineCommand) throws -> WorkspaceDecision {
        let decision = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: now)
        snapshot = decision.snapshot; return decision
    }
    @discardableResult mutating func edit(_ edit: ThreadEdit) throws -> WorkspaceDecision { try apply(.client(.editThread(threadID, edit))) }
    mutating func start() throws {
        try apply(.client(.submit(threadID: threadID, text: "Opening input")))
        let runID = snapshot.threads[0].activeRun!.id
        try apply(.runtimeOpened(threadID: threadID, runID: runID, runtimeID: runtimeID))
        try apply(.provider(threadID: threadID, runtimeID: runtimeID, event: .thread("reasoning-native-thread")))
        try apply(.provider(threadID: threadID, runtimeID: runtimeID, event: .turn("reasoning-native-turn")))
    }
}

@Test func codexReasoningPerModelPreferencesResolveConcreteDefaultsAndSurviveModelSwitches() throws {
    var f = ReasoningFixture()
    let selected = try f.edit(.codexModel(reasoningA))
    #expect(selected.effects.isEmpty && f.snapshot.threads[0].model == reasoningA.id)
    #expect(f.snapshot.threads[0].reasoningEffort == "medium" && f.snapshot.threads[0].codexReasoningPreferences == nil)
    try f.edit(.codexReasoning(model: reasoningA, effort: "high"))
    try f.edit(.codexModel(reasoningB))
    #expect(f.snapshot.threads[0].reasoningEffort == "low")
    try f.edit(.codexReasoning(model: reasoningB, effort: "future-effort"))
    try f.edit(.codexModel(reasoningA))
    #expect(f.snapshot.threads[0].reasoningEffort == "high")
    try f.edit(.codexReasoning(model: reasoningA, effort: nil))
    #expect(f.snapshot.threads[0].reasoningEffort == "medium")
    #expect(f.snapshot.threads[0].codexReasoningPreferences == [reasoningB.id: "future-effort"])
    try f.edit(.codexModel(reasoningB))
    #expect(f.snapshot.threads[0].reasoningEffort == "future-effort")
    let encoded = try JSONEncoder().encode(f.snapshot)
    #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded) == f.snapshot)
    try WorkspaceJournal.validate(f.snapshot)
}

@Test(arguments: ["gpt-6-astra", "openai.gpt-6-astra", "gpt-6-astra-preview", "namespace/gpt-6-astra", "other"])
func codexReasoningAstraPolicyUsesOnlyExactReviewedFamilyAndAdvertisedEfforts(model: String) throws {
    var row = reasoningA; row.id = model
    #expect(row.codexDefaultReasoningEffort == (["gpt-6-astra", "openai.gpt-6-astra"].contains(model) ? "medium" : "xhigh"))
    row.reasoningEfforts.removeAll { $0.id == "medium" }
    #expect(row.codexDefaultReasoningEffort == "xhigh")
}

@Test func codexReasoningRejectsStaleModelUnsupportedEffortAndMalformedCatalogAtomically() throws {
    var f = ReasoningFixture(); try f.edit(.codexModel(reasoningA)); let before = f.snapshot
    #expect(throws: WorkspaceCommandError.self) { try f.edit(.codexReasoning(model: reasoningB, effort: "high")) }
    #expect(throws: WorkspaceCommandError.self) { try f.edit(.codexReasoning(model: reasoningA, effort: "unadvertised")) }
    var malformed = reasoningA; malformed.reasoningEfforts.append(malformed.reasoningEfforts[0])
    #expect(throws: WorkspaceCommandError.self) { try f.edit(.codexModel(malformed)) }
    #expect(f.snapshot == before)
    f.snapshot.threads[0].codexReasoningPreferences = [reasoningA.id: "no-longer-advertised"]
    try f.edit(.codexModel(reasoningA))
    #expect(f.snapshot.threads[0].reasoningEffort == "medium")
    #expect(f.snapshot.threads[0].codexReasoningPreference(for: reasoningA) == nil)
}

@Test func codexReasoningCLIDefaultKeepsConfiguredEffortUnlessAnAdvertisedPerModelPreferenceExists() throws {
    var f = ReasoningFixture()
    let selection = try CodexDefaultModelSelection(workspacePath: f.snapshot.threads[0].workspacePath, model: reasoningA.id,
        reasoningEffort: "high", catalogModel: reasoningA)
    try f.edit(.codexDefaultModel(selection))
    #expect(f.snapshot.threads[0].model == reasoningA.id && f.snapshot.threads[0].reasoningEffort == "high")
    #expect(f.snapshot.threads[0].codexModelSelectionSource == .cliDefault && f.snapshot.threads[0].codexReasoningPreferences == nil)
    #expect(f.snapshot.threads[0].reasoningEffort != reasoningA.codexDefaultReasoningEffort)
    try f.edit(.codexReasoning(model: reasoningA, effort: "low")); try f.edit(.codexModel(reasoningB))
    try f.edit(.codexDefaultModel(selection))
    #expect(f.snapshot.threads[0].reasoningEffort == "low" && f.snapshot.threads[0].codexModelSelectionSource == .cliDefault)
    let before = f.snapshot
    let otherWorkspace = try CodexDefaultModelSelection(workspacePath: "/tmp/unrelated-reasoning-checkout", model: reasoningA.id, reasoningEffort: "high", catalogModel: reasoningA)
    #expect(throws: WorkspaceCommandError.self) { try f.edit(.codexDefaultModel(otherWorkspace)) }
    #expect(f.snapshot == before)
}

@Test func codexReasoningCapturesQueueAndSteeringExecutionValuesWithoutChangingActiveOrFutureChoices() throws {
    var f = ReasoningFixture(); try f.edit(.codexModel(reasoningA)); try f.start()
    let active = f.snapshot.threads[0].activeRun!, record = f.snapshot.threads[0].runHistory![0]
    try f.edit(.codexReasoning(model: reasoningA, effort: "high"))
    try f.apply(.client(.submit(threadID: f.threadID, text: "Captured high queue")))
    let queued = f.snapshot.threads[0].queuedTurns[0]
    #expect(queued.configuration.reasoningEffort == "high")
    #expect(f.snapshot.promptSteeringTargetReason(threadID: f.threadID, queuedID: queued.id)?.contains("different captured settings") == true)
    try f.edit(.codexReasoning(model: reasoningA, effort: "low")); try f.edit(.draft("Newest unsent draft"))
    #expect(f.snapshot.threads[0].activeRun == active && f.snapshot.threads[0].runHistory![0] == record)
    let input = QueuedTurn(id: UUID(), text: "Steer original Medium settings", configuration: active.configuration, createdAt: f.now, checkpointPolicy: .disabled)
    let operation = PromptSteeringOperation(threadID: f.threadID, projectID: f.snapshot.projects[0].id, sourceIncarnation: f.incarnation,
        runtimeID: f.runtimeID, runID: active.id, nativeThreadID: "reasoning-native-thread", nativeTurnID: "reasoning-native-turn",
        input: input, messageID: "user-\(input.id.uuidString)", configuration: active.configuration)
    try f.apply(.promptSteeringAccepted(operation)); try f.apply(.promptSteeringDispatching(operationID: operation.id, incarnation: f.incarnation))
    try f.apply(.promptSteeringEffectResult(.promptSteering(threadID: f.threadID, operationID: operation.id), .promptSteeringDelivered(try .init(turnID: operation.nativeTurnID)), incarnation: f.incarnation))
    let completed = try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .completed(.idle)))
    #expect(f.snapshot.promptSteering(operation.id)?.configuration.reasoningEffort == "medium")
    #expect(f.snapshot.threads[0].activeRun?.id == queued.id && f.snapshot.threads[0].activeRun?.configuration.reasoningEffort == "high")
    #expect(f.snapshot.threads[0].reasoningEffort == "low" && f.snapshot.threads[0].draft == "Newest unsent draft")
    #expect(completed.effects.contains { if case .providerStart(_, let id, let config, _, _) = $0.request { return id == queued.id && config.reasoningEffort == "high" }; return false })
}

@Test func codexReasoningLegacyNilAndModelsWithoutAdvertisedEffortsRemainExplicitlyUnspecified() throws {
    var f = ReasoningFixture()
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.snapshot)) as? [String: Any])
    var threads = try #require(object["threads"] as? [[String: Any]])
    for key in ["reasoningEffort", "codexReasoningPreferences", "codexModelSelectionSource"] { threads[0].removeValue(forKey: key) }
    object["threads"] = threads
    f.snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(f.snapshot.threads[0].model.isEmpty && f.snapshot.threads[0].reasoningEffort == nil && f.snapshot.threads[0].codexModelSelectionSource == nil)
    let noOptions = ProviderModel(id: "legacy-no-options", name: "No advertised effort")
    try f.edit(.codexModel(noOptions))
    #expect(f.snapshot.threads[0].reasoningEffort == nil)
    let before = f.snapshot
    #expect(throws: WorkspaceCommandError.self) { try f.edit(.codexReasoning(model: noOptions, effort: nil)) }
    #expect(f.snapshot == before)
    try f.edit(.codexModel(reasoningA)); try f.edit(.model(""))
    #expect(f.snapshot.threads[0].reasoningEffort == nil && f.snapshot.threads[0].codexModelSelectionSource == nil)
}

@Test func codexReasoningPRCheckoutMaterializesCapturedEffortWithoutProviderOrPrompt() throws {
    var f = PullRequestCheckoutFixture()
    f.snapshot.threads[0].provider = .codex
    f.snapshot.threads[0].model = reasoningA.id; f.snapshot.threads[0].reasoningEffort = "high"
    let plan = try f.plan(f.request()), review = try f.review(plan), operation = PullRequestCheckoutOperation(review: review)
    try f.command(.pullRequestCheckoutAccepted(operation))
    try f.command(.pullRequestCheckoutDispatching(projectID: f.projectID, operationID: operation.id, incarnation: f.incarnation))
    let confirmed = try f.command(.pullRequestCheckoutEffectResult(.pullRequestCheckout(projectID: f.projectID, operationID: operation.id, effectID: operation.effectID), .pullRequestCheckoutCompleted(f.result(plan)), incarnation: f.incarnation))
    let target = try #require(f.snapshot.threads.first { $0.id == review.targetThreadID })
    #expect(target.reasoningEffort == "high" && ProviderConfiguration(thread: target).reasoningEffort == "high")
    #expect(target.messages.isEmpty && target.activeRun == nil && target.queuedTurns.isEmpty && confirmed.effects.isEmpty)
}

private actor ReasoningDefaultPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    let selection: CodexDefaultModelSelection
    var gate: RestoreEngineGate?
    private(set) var closes = 0
    private(set) var starts: [ProviderConfiguration] = []
    private(set) var steers: [ProviderConfiguration] = []
    private var runID: UUID?
    let supportsRun: Bool
    init(selection: CodexDefaultModelSelection, gate: RestoreEngineGate?, supportsRun: Bool = false) { self.selection = selection; self.gate = gate; self.supportsRun = supportsRun; let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func models() -> [ProviderModel] { [reasoningA, reasoningB] }
    func codexDefaultModelSelection() async -> CodexDefaultModelSelection { if let gate { await gate.wait() }; return selection }
    func send(text: String, thread: CodingThread) throws {
        guard supportsRun else { throw CoincideError("Reading CLI defaults must not send input") }
        starts.append(.init(thread: thread)); runID = thread.activeRun?.id
        if let runID { continuation.yield(.context(runID: runID, event: .thread("default-active-thread"))); continuation.yield(.context(runID: runID, event: .turn("default-active-turn"))) }
    }
    func steeringCapabilities() -> ProviderSteeringCapabilities { .init(supportsActiveSteering: supportsRun && runID != nil) }
    func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) throws -> ProviderSteeringReceipt {
        guard thread.activeRun?.id == runID else { throw ProviderSteeringError(.staleTarget) }
        steers.append(.init(thread: thread)); return try .init(turnID: expectedTurnID)
    }
    func finish() { if let runID { continuation.yield(.context(runID: runID, event: .completed(.idle))) }; runID = nil }
    func interrupt() { finish() }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() async { closes += 1; if let gate { await gate.release() }; continuation.finish() }
}

private func reasoningEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() { guard ContinuousClock.now < deadline else { throw CoincideError("Reasoning defaults did not reach the owned boundary") }; try await Task.sleep(for: .milliseconds(5)) }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codexReasoningDefaultReadRejectsSourceChangesDuringReadAndBeforeQueuedCommit(changeDuringRead: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-default-read-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let f = ReasoningFixture(path: root.path), url = root.appendingPathComponent("workspace.sqlite"), threadID = f.threadID
    try await WorkspaceDatabase(url: url).save(f.snapshot, event: "fixture")
    let selection = try CodexDefaultModelSelection(workspacePath: root.path, model: reasoningA.id, reasoningEffort: "high", catalogModel: reasoningA)
    let gate = changeDuringRead ? RestoreEngineGate() : nil, peer = ReasoningDefaultPeer(selection: selection, gate: gate)
    let engine = try WorkspaceEngine(url: url, providerFactory: { _ in peer }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        if let gate {
            let read = Task { try await engine.reviewCodexDefaultModel(threadID: threadID) }
            try await reasoningEventually { await gate.entered }
            _ = try await engine.dispatch(.editThread(threadID, .model("Changed while reading")))
            await gate.release()
            await #expect(throws: WorkspaceCommandError.self) { try await read.value }
        } else {
            let reviewed = try await engine.reviewCodexDefaultModel(threadID: threadID)
            _ = try await engine.dispatch(.editThread(threadID, .model("Changed after reading")))
            await #expect(throws: WorkspaceCommandError.self) { try await engine.dispatch(.editThread(threadID, .codexDefaultModel(reviewed))) }
        }
        #expect(await peer.closes == 1)
        #expect(await engine.current().snapshot.threads[0].reasoningEffort == nil)
        #expect(try await WorkspaceDatabase(url: url).effects().isEmpty)
        await engine.shutdown()
    } catch { if let gate { await gate.release() }; await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    try? FileManager.default.removeItem(at: root)
}

@Test(.timeLimit(.minutes(1)))
func codexReasoningDefaultReadBindsCanonicalMetadataToRegisteredAliasAndPersistsConcreteCapture() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-default-alias-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let checkout = root.appendingPathComponent("Checkout"), alias = root.appendingPathComponent("Alias")
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: checkout)
    var f = ReasoningFixture(path: alias.path)
    // New project creation canonicalizes paths. Seed a valid registered alias
    // explicitly to exercise a retained or previously chosen checkout spelling.
    f.snapshot.threads[0].workspacePath = alias.path
    let url = root.appendingPathComponent("workspace.sqlite")
    try await WorkspaceDatabase(url: url).save(f.snapshot, event: "fixture")
    let observed = try CodexDefaultModelSelection(workspacePath: checkout.path, model: reasoningA.id, reasoningEffort: "high", catalogModel: reasoningA)
    let peer = ReasoningDefaultPeer(selection: observed, gate: nil)
    let engine = try WorkspaceEngine(url: url, providerFactory: { _ in peer }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        let selection = try await engine.reviewCodexDefaultModel(threadID: f.threadID)
        #expect(selection.workspacePath == alias.path)
        _ = try await engine.dispatch(.editThread(f.threadID, .codexDefaultModel(selection)))
        let applied = await engine.current().snapshot
        #expect(applied.threads[0].model == reasoningA.id && applied.threads[0].reasoningEffort == "high")
        #expect(applied.threads[0].codexModelSelectionSource == .cliDefault && applied.threads[0].codexReasoningPreferences == nil)
        let replay = try await WorkspaceDatabase(url: url).rebuildProjection().snapshot
        #expect(replay == applied)
        await engine.shutdown()
        let reopened = try WorkspaceEngine(url: url, providerFactory: { _ in throw CoincideError("Reopening must not read CLI defaults") }, identityResolver: { _ in nil })
        let restored = try await reopened.load()
        #expect(restored.threads[0].reasoningEffort == "high" && restored.threads[0].codexModelSelectionSource == .cliDefault)
        await reopened.shutdown()
    } catch { await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    try? FileManager.default.removeItem(at: root)
}

@Test(.timeLimit(.minutes(1)))
func codexReasoningDefaultReadAllowsIndependentParentCompletionWithoutBlockingItsEvents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-default-active-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var f = ReasoningFixture(path: root.path); try f.edit(.codexModel(reasoningA))
    let url = root.appendingPathComponent("workspace.sqlite")
    try await WorkspaceDatabase(url: url).save(f.snapshot, event: "fixture")
    let observed = try CodexDefaultModelSelection(workspacePath: root.path, model: reasoningB.id, reasoningEffort: "low", catalogModel: reasoningB)
    let gate = RestoreEngineGate(), peer = ReasoningDefaultPeer(selection: observed, gate: nil, supportsRun: true)
    let metadata = ReasoningDefaultPeer(selection: observed, gate: gate)
    let engine = try WorkspaceEngine(url: url, providerFactory: { requested in requested.activeRun == nil ? metadata : peer }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load(); _ = try await engine.dispatch(.submit(threadID: f.threadID, text: "Opening active input"))
        try await reasoningEventually { await engine.current().snapshot.threads[0].activeRun?.nativeTurnID != nil }
        let original = try #require(await engine.current().snapshot.threads[0].activeRun)
        let read = Task { [threadID = f.threadID] in try await engine.reviewCodexDefaultModel(threadID: threadID) }
        try await reasoningEventually { await gate.entered }
        await peer.finish()
        try await reasoningEventually { await engine.current().snapshot.threads[0].activeRun == nil }
        await gate.release()
        let selection = try await read.value
        _ = try await engine.dispatch(.editThread(f.threadID, .codexDefaultModel(selection)))
        let thread = await engine.current().snapshot.threads[0]
        #expect(thread.model == reasoningB.id && thread.reasoningEffort == "low")
        #expect(thread.runHistory?.first?.configuration == original.configuration && original.configuration.reasoningEffort == "medium")
        #expect(await peer.closes == 0)
        #expect(await metadata.closes == 1)
        await engine.shutdown()
    } catch { await gate.release(); await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    try? FileManager.default.removeItem(at: root)
}

@Test func codexReasoningForkMaterializesTheSelectedHistoricalEffortAndPreservesFutureSourceChoice() throws {
    var f = ReasoningFixture(); try f.edit(.codexModel(reasoningA)); try f.edit(.codexReasoning(model: reasoningA, effort: "high")); try f.start()
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .completed(.idle)))
    try f.edit(.codexReasoning(model: reasoningA, effort: "low"))
    let source = f.snapshot.threads[0], record = source.runHistory![0]
    let prefix = try source.transcriptPrefix(runID: record.id, boundary: .afterRun)
    let review = try ConversationHistoryReview(kind: .forkAfterRun, sourceThreadID: source.id, projectID: source.projectID,
        runID: record.id, sourceIncarnation: f.incarnation, sourceConfiguration: .init(thread: source), targetConfiguration: record.configuration,
        sourceReference: .init(provider: .codex, nativeThreadID: "reasoning-native-thread"), reviewedHeadTurnID: "reasoning-native-turn",
        boundary: .throughTurn("reasoning-native-turn"), expectedResultHeadTurnID: "reasoning-native-turn", prefix: prefix,
        removedRunIDs: [], removedMessageIDs: [], sourceFingerprint: f.snapshot.historySourceFingerprint(threadID: source.id),
        targetThreadID: UUID(), suggestedTitle: "Captured High fork")
    try f.apply(.conversationHistoryAccepted(review: review, title: nil))
    try f.apply(.conversationHistoryDispatching(threadID: source.id, operationID: review.id, incarnation: f.incarnation))
    let result = try ProviderConversationSnapshot(reference: .init(provider: .codex, nativeThreadID: "new-reasoning-fork"), workspacePath: source.workspacePath,
        historyMode: .paginated, headTurnID: "reasoning-native-turn")
    try f.apply(.conversationHistoryEffectResult(.conversationHistory(threadID: source.id, operationID: review.id), .conversationHistoryConfirmed(result), incarnation: f.incarnation))
    let target = try #require(f.snapshot.threads.first { $0.id == review.targetThreadID })
    #expect(target.reasoningEffort == "high" && ProviderConfiguration(thread: target).reasoningEffort == "high")
    #expect(f.snapshot.threads[0].reasoningEffort == "low" && f.snapshot.threads[0].runHistory?.first?.configuration.reasoningEffort == "high")
    try WorkspaceJournal.validate(f.snapshot)
}

@Test(.timeLimit(.minutes(1)))
func codexReasoningEngineReconstructsCapturedEffortForSteeringAndTheNextQueuedTurn() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-reasoning-facade-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var f = ReasoningFixture(path: root.path); try f.edit(.codexModel(reasoningA))
    let url = root.appendingPathComponent("workspace.sqlite")
    try await WorkspaceDatabase(url: url).save(f.snapshot, event: "fixture")
    let observed = try CodexDefaultModelSelection(workspacePath: root.path, model: reasoningA.id, reasoningEffort: "medium", catalogModel: reasoningA)
    let peer = ReasoningDefaultPeer(selection: observed, gate: nil, supportsRun: true)
    let engine = try WorkspaceEngine(url: url, providerFactory: { _ in peer }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load(); _ = try await engine.dispatch(.submit(threadID: f.threadID, text: "Opening Medium input"))
        try await reasoningEventually { await engine.current().snapshot.threads[0].activeRun?.nativeTurnID != nil }
        let runID = try #require(await engine.current().snapshot.threads[0].activeRun?.id)
        _ = try await engine.dispatch(.editThread(f.threadID, .codexReasoning(model: reasoningA, effort: "high")))
        _ = try await engine.steerPrompt(threadID: f.threadID, text: "Same turn still Medium", expectedRunID: runID)
        try await reasoningEventually { await engine.current().snapshot.promptSteerings?.last?.phase == .delivered }
        let steers = await peer.steers
        #expect(steers.count == 1 && steers.first?.reasoningEffort == "medium")
        _ = try await engine.dispatch(.submit(threadID: f.threadID, text: "Next captured High input"))
        _ = try await engine.dispatch(.editThread(f.threadID, .codexReasoning(model: reasoningA, effort: "low")))
        await peer.finish()
        try await reasoningEventually { await peer.starts.count == 2 }
        let starts = await peer.starts
        #expect(starts.map(\.reasoningEffort) == ["medium", "high"])
        #expect(await engine.current().snapshot.threads[0].reasoningEffort == "low")
        await peer.finish(); await engine.shutdown()
    } catch { await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    try? FileManager.default.removeItem(at: root)
}

@Test(.timeLimit(.minutes(1)))
func codexReasoningCanceledOwnedDefaultReadClosesAndDrainsWithoutStoppingTheActiveRuntime() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-default-cancel-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var f = ReasoningFixture(path: root.path); try f.edit(.codexModel(reasoningA))
    let url = root.appendingPathComponent("workspace.sqlite")
    try await WorkspaceDatabase(url: url).save(f.snapshot, event: "fixture")
    let observed = try CodexDefaultModelSelection(workspacePath: root.path, model: reasoningB.id, reasoningEffort: "low", catalogModel: reasoningB)
    let gate = RestoreEngineGate(), metadata = ReasoningDefaultPeer(selection: observed, gate: gate)
    let runtime = ReasoningDefaultPeer(selection: observed, gate: nil, supportsRun: true)
    let engine = try WorkspaceEngine(url: url, providerFactory: { requested in requested.activeRun == nil ? metadata : runtime }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load(); _ = try await engine.dispatch(.submit(threadID: f.threadID, text: "Active input must keep running"))
        try await reasoningEventually { await engine.current().snapshot.threads[0].activeRun?.nativeTurnID != nil }
        let active = try #require(await engine.current().snapshot.threads[0].activeRun)
        let read = Task { [threadID = f.threadID] in try await engine.reviewCodexDefaultModel(threadID: threadID) }
        try await reasoningEventually { await gate.entered }
        read.cancel()
        // The test never releases the gate: only closing the owned metadata session does.
        try await reasoningEventually { await metadata.closes == 1 }
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(await runtime.closes == 0)
        #expect(await engine.current().snapshot.threads[0].activeRun == active)
        #expect(await engine.current().snapshot.threads[0].model == reasoningA.id)
        await runtime.finish(); await engine.shutdown()
        #expect(await metadata.closes == 1)
    } catch { await gate.release(); await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    try? FileManager.default.removeItem(at: root)
}
