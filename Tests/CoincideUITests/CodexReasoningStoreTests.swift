import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private let nativeReasoningA = ProviderModel(id: "gpt-6-astra", name: "Advertised Astra",
    reasoningEfforts: ["low", "medium", "high"].map { .init(id: $0, description: "Advertised \($0)") },
    defaultReasoningEffort: "high", isDefault: true)
private let nativeReasoningB = ProviderModel(id: "future-native-model", name: "Future native model",
    reasoningEfforts: ["light", "deep", "experimental-effort"].map { .init(id: $0, description: "Advertised \($0)") },
    defaultReasoningEffort: "light")

private actor NativeReasoningReadGate {
    private var released: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0
    init(held: Bool) { released = !held }
    func enter() async {
        reads += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        released = true
        let pending = waiters; waiters = []
        pending.forEach { $0.resume() }
    }
}

private actor NativeReasoningCatalog {
    private var values = [nativeReasoningA, nativeReasoningB]
    func models() -> [ProviderModel] { values }
    func replace(_ model: ProviderModel) {
        if let index = values.firstIndex(where: { $0.id == model.id }) { values[index] = model }
    }
}

/// Each metadata query gets its own peer so catalog cleanup cannot finish an active event stream.
private actor NativeReasoningMetadata: ProviderSession {
    nonisolated let events = AsyncStream<ProviderEvent> { $0.finish() }
    let selection: CodexDefaultModelSelection
    let gate: NativeReasoningReadGate
    let catalog: NativeReasoningCatalog
    private var readDefaults = false
    init(selection: CodexDefaultModelSelection, gate: NativeReasoningReadGate, catalog: NativeReasoningCatalog) {
        self.selection = selection; self.gate = gate; self.catalog = catalog
    }
    func models() async -> [ProviderModel] { await catalog.models() }
    func codexDefaultModelSelection() async -> CodexDefaultModelSelection {
        readDefaults = true; await gate.enter(); return selection
    }
    func send(text: String, thread: CodingThread) throws { throw CoincideError("A metadata query must not send a provider input.") }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() async { if readDefaults { await gate.release() } }
}

private actor NativeReasoningRuntime: ProviderSession {
    struct Input: Equatable, Sendable { let text: String; let configuration: ProviderConfiguration; let runID: UUID? }
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    let selection: CodexDefaultModelSelection
    let gate: NativeReasoningReadGate
    private var runID: UUID?
    private var turnID: String?
    private(set) var starts: [Input] = []
    private(set) var steers: [Input] = []
    private(set) var interrupts = 0
    private(set) var closes = 0
    init(selection: CodexDefaultModelSelection, gate: NativeReasoningReadGate) {
        self.selection = selection; self.gate = gate
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation
    }
    func models() throws -> [ProviderModel] { throw CoincideError("A neutral model refresh must use its own metadata peer.") }
    func codexDefaultModelSelection() throws -> CodexDefaultModelSelection {
        throw CoincideError("Reading CLI defaults must use a fresh owned metadata session, never the active stream.")
    }
    func send(text: String, thread: CodingThread) {
        runID = thread.activeRun?.id; turnID = "native-reasoning-turn-\(starts.count + 1)"
        starts.append(.init(text: text, configuration: .init(thread: thread), runID: runID))
        emit(.thread("native-reasoning-thread")); emit(.turn(turnID!))
    }
    func steeringCapabilities() -> ProviderSteeringCapabilities { .init(supportsActiveSteering: runID != nil && turnID != nil) }
    func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String,
               clientMessageID: String) throws -> ProviderSteeringReceipt {
        guard thread.activeRun?.id == runID, expectedTurnID == turnID else { throw ProviderSteeringError(.staleTarget) }
        steers.append(.init(text: input.text, configuration: .init(thread: thread), runID: runID))
        return try .init(turnID: expectedTurnID)
    }
    func finish() { emit(.completed(.idle)); runID = nil; turnID = nil }
    func interrupt() { interrupts += 1; emit(.completed(.interrupted)); runID = nil; turnID = nil }
    private func emit(_ event: ProviderEvent) { if let runID { continuation.yield(.context(runID: runID, event: event)) } }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() async { closes += 1; await gate.release(); continuation.finish() }
}

@MainActor private struct NativeReasoningFixture {
    let root: URL
    let database: URL
    let projectID: UUID
    let threadID: UUID
    let gate: NativeReasoningReadGate
    let catalog: NativeReasoningCatalog
    let runtime: NativeReasoningRuntime
    let engine: WorkspaceEngine
    let store: WorkspaceStore
    static func make(held: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-reasoning-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        let checkout = root.appendingPathComponent("Checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try "Keep local reasoning fixture files\n".write(to: checkout.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let project = WorkspaceProject(path: checkout.path), database = root.appendingPathComponent("workspace.sqlite")
        var thread = CodingThread(project: project, model: nativeReasoningA.id)
        thread.reasoningEffort = "medium"; thread.codexModelSelectionSource = .explicitModel
        thread.checkpointPolicy = .disabled
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        try await WorkspaceDatabase(url: database).save(snapshot, event: "native.reasoning.fixture")
        let selection = try CodexDefaultModelSelection(workspacePath: project.path, model: nativeReasoningB.id,
            reasoningEffort: "deep", catalogModel: nativeReasoningB)
        let gate = NativeReasoningReadGate(held: held), catalog = NativeReasoningCatalog()
        let runtime = NativeReasoningRuntime(selection: selection, gate: gate)
        let engine = try WorkspaceEngine(url: database, providerFactory: { requested in
            if requested.activeRun != nil { return runtime }
            return NativeReasoningMetadata(selection: selection, gate: gate, catalog: catalog)
        }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine); await store.load(); await store.refreshModels(provider: .codex)
        return .init(root: root, database: database, projectID: project.id, threadID: thread.id, gate: gate, catalog: catalog,
                     runtime: runtime, engine: engine, store: store)
    }
    func start() async throws {
        // Direct dispatch bypasses only the UI's installed-executable admission, never the runtime factory.
        _ = try await engine.dispatch(.submit(threadID: threadID, text: "Original reasoning input"))
        try await waitNativeReasoning { store.thread(threadID)?.activeRun?.nativeTurnID != nil }
    }
    func cleanup() async { await gate.release(); await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@MainActor private func waitNativeReasoning(file: StaticString = #fileID, line: UInt = #line,
                                          _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native reasoning boundary did not settle at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCodexReasoningPreferencesFollowTheAdvertisedModelAndPersistDefaultReset() async throws {
    let f = try await NativeReasoningFixture.make()
    do {
        #expect(f.store.codexReasoningModel(threadID: f.threadID) == nativeReasoningA)
        #expect(await f.store.useCodexDefaultModel(f.threadID).value)
        #expect(f.store.thread(f.threadID)?.model == nativeReasoningB.id)
        #expect(f.store.thread(f.threadID)?.reasoningEffort == "deep", "CLI defaults must be read, rather than inferred from the catalog's isDefault flag.")
        #expect(f.store.thread(f.threadID)?.codexModelSelectionSource == .cliDefault)
        #expect(await f.store.setCodexReasoningEffort("experimental-effort", model: nativeReasoningB, threadID: f.threadID).value)
        f.store.setModel(nativeReasoningA.id, id: f.threadID)
        try await waitNativeReasoning { f.store.thread(f.threadID)?.model == nativeReasoningA.id }
        #expect(f.store.thread(f.threadID)?.reasoningEffort == "medium")
        #expect(await f.store.setCodexReasoningEffort("high", model: nativeReasoningA, threadID: f.threadID).value)
        f.store.setModel(nativeReasoningB.id, id: f.threadID)
        try await waitNativeReasoning { f.store.thread(f.threadID)?.model == nativeReasoningB.id }
        #expect(f.store.thread(f.threadID)?.reasoningEffort == "experimental-effort")
        f.store.setModel(nativeReasoningA.id, id: f.threadID)
        try await waitNativeReasoning { f.store.thread(f.threadID)?.model == nativeReasoningA.id }
        #expect(f.store.thread(f.threadID)?.reasoningEffort == "high")
        #expect(await f.store.setCodexReasoningEffort(nil, model: nativeReasoningA, threadID: f.threadID).value)
        #expect(f.store.thread(f.threadID)?.reasoningEffort == "medium")
        #expect(f.store.thread(f.threadID)?.codexReasoningPreferences == [nativeReasoningB.id: "experimental-effort"])
        #expect(await f.store.useCodexDefaultModel(f.threadID).value)
        #expect(f.store.thread(f.threadID)?.reasoningEffort == "experimental-effort")
        #expect(await f.runtime.starts.isEmpty)
        let captured = try #require(f.store.thread(f.threadID))
        await f.store.shutdown()
        let reopened = try WorkspaceEngine(url: f.database, providerFactory: { _ in throw CoincideError("Reopening must not read a provider's defaults.") }, identityResolver: { _ in nil })
        let restored = WorkspaceStore(engine: reopened); await restored.load()
        #expect(restored.thread(f.threadID)?.model == captured.model)
        #expect(restored.thread(f.threadID)?.reasoningEffort == captured.reasoningEffort)
        #expect(restored.thread(f.threadID)?.codexReasoningPreferences == captured.codexReasoningPreferences)
        #expect(restored.thread(f.threadID)?.codexModelSelectionSource == .cliDefault)
        #expect(restored.errorMessage == nil)
        await restored.shutdown()
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCodexStaleReasoningMenuUsesCurrentSameIDCatalogAndRejectsRemovedEfforts() async throws {
    let f = try await NativeReasoningFixture.make()
    do {
        f.store.setModel(nativeReasoningB.id, id: f.threadID)
        try await waitNativeReasoning { f.store.thread(f.threadID)?.model == nativeReasoningB.id }
        #expect(await f.store.setCodexReasoningEffort("experimental-effort", model: nativeReasoningB, threadID: f.threadID).value)
        let replacement = ProviderModel(id: nativeReasoningB.id, name: "Refreshed future model",
            reasoningEfforts: ["light", "deep"].map { .init(id: $0, description: "Current \($0)") }, defaultReasoningEffort: "deep")
        await f.catalog.replace(replacement)
        await f.store.refreshModels(provider: .codex)
        #expect(f.store.codexReasoningModel(threadID: f.threadID) == replacement)
        let before = try #require(f.store.thread(f.threadID))
        // The still-open menu holds the old value with the SAME model ID.
        #expect(await f.store.setCodexReasoningEffort("experimental-effort", model: nativeReasoningB, threadID: f.threadID).value == false)
        #expect(f.store.thread(f.threadID) == before, "A removed advertised effort must not change the persisted thread or its saved preferences.")
        #expect(f.store.errorMessage != nil)
        #expect(await f.store.setCodexReasoningEffort(nil, model: nativeReasoningB, threadID: f.threadID).value)
        #expect(f.store.thread(f.threadID)?.reasoningEffort == "deep", "Model Default must resolve the latest catalog row, rather than the stale menu's Light default.")
        #expect(f.store.thread(f.threadID)?.codexReasoningPreferences == nil)
        #expect(await f.runtime.starts.isEmpty)
        try WorkspaceJournal.validate(f.store.snapshot)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCodexPendingDefaultReadDoesNotBlockDraftPinOrStopOnItsActiveStream() async throws {
    let f = try await NativeReasoningFixture.make(held: true)
    do {
        try await f.start()
        let run = try #require(f.store.thread(f.threadID)?.activeRun)
        let pending = f.store.useCodexDefaultModel(f.threadID)
        try await waitNativeReasoning { await f.gate.reads == 1 }
        #expect(f.store.isReadingCodexModelDefaults(f.threadID))
        f.store.setDraft("Keep editing while CLI metadata is delayed", id: f.threadID)
        f.store.togglePin(f.threadID)
        let stopping = Task { await f.store.interrupt(f.threadID) }
        try await waitNativeReasoning {
            await f.runtime.interrupts == 1 && f.store.thread(f.threadID)?.activeRun == nil && f.store.thread(f.threadID)?.isPinned == true
        }
        #expect(f.store.thread(f.threadID)?.draft == "Keep editing while CLI metadata is delayed")
        #expect(f.store.thread(f.threadID)?.runHistory?.first?.configuration == run.configuration)
        #expect(f.store.thread(f.threadID)?.runHistory?.first?.status == .interrupted)
        #expect(await f.runtime.closes == 0, "Owned metadata cleanup must preserve the active provider's reusable stream.")
        await stopping.value
        await f.gate.release()
        #expect(await pending.value)
        #expect(f.store.thread(f.threadID)?.model == nativeReasoningB.id && f.store.thread(f.threadID)?.reasoningEffort == "deep")
        #expect(f.store.thread(f.threadID)?.draft == "Keep editing while CLI metadata is delayed")
        #expect(await f.runtime.starts.count == 1)
        #expect(f.store.errorMessage == nil)
        try WorkspaceJournal.validate(f.store.snapshot)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func nativeCodexDelayedDefaultReadCannotUndoManualSelectionOrResurrectRemovedProject(remove: Bool) async throws {
    let f = try await NativeReasoningFixture.make(held: true)
    do {
        let pending = f.store.useCodexDefaultModel(f.threadID)
        try await waitNativeReasoning { await f.gate.reads == 1 }
        if remove {
            let request = try #require(f.store.projectRemovalRequest(f.projectID))
            try await f.store.removeProject(request)
            #expect(f.store.thread(f.threadID) == nil && f.store.snapshot.projects.isEmpty)
        } else {
            f.store.setModel(nativeReasoningB.id, id: f.threadID)
            try await waitNativeReasoning { f.store.thread(f.threadID)?.model == nativeReasoningB.id }
            #expect(f.store.thread(f.threadID)?.reasoningEffort == "light")
        }
        await f.gate.release()
        #expect(await pending.value == false)
        #expect(f.store.isReadingCodexModelDefaults(f.threadID) == false)
        if remove {
            #expect(f.store.thread(f.threadID) == nil && f.store.snapshot.projects.isEmpty)
            #expect(try String(contentsOf: f.root.appendingPathComponent("Checkout/README.md"), encoding: .utf8) == "Keep local reasoning fixture files\n")
        } else {
            #expect(f.store.thread(f.threadID)?.reasoningEffort == "light")
            #expect(f.store.thread(f.threadID)?.codexModelSelectionSource == .explicitModel)
        }
        #expect(f.store.errorMessage == nil)
        #expect(await f.runtime.starts.isEmpty)
        try WorkspaceJournal.validate(f.store.snapshot)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCodexReasoningQueueAndSteerUseCapturedEffortsWhileFutureChoicesStayEditable() async throws {
    let f = try await NativeReasoningFixture.make()
    do {
        try await f.start()
        let original = try #require(f.store.thread(f.threadID)?.activeRun)
        #expect(await f.store.setCodexReasoningEffort("high", model: nativeReasoningA, threadID: f.threadID).value)
        _ = try await f.engine.dispatch(.submit(threadID: f.threadID, text: "Captured high-effort queued input"))
        try await waitNativeReasoning { f.store.thread(f.threadID)?.queuedTurns.count == 1 }
        let queued = try #require(f.store.thread(f.threadID)?.queuedTurns.first)
        #expect(queued.configuration.reasoningEffort == "high")
        #expect(await f.store.setCodexReasoningEffort("low", model: nativeReasoningA, threadID: f.threadID).value)
        await f.store.refreshModels(provider: .codex)
        #expect(await f.runtime.closes == 0, "Closing a fresh catalog reader must not close the active stream.")
        await f.store.refreshPromptSteeringAvailability(threadID: f.threadID)
        f.store.setDraft("A follow-up for the existing medium-effort run", id: f.threadID)
        #expect(await ChatView(store: f.store, threadID: f.threadID).steerCurrentDraft().value)
        try await waitNativeReasoning { f.store.snapshot.promptSteerings?.last?.phase == .delivered }
        let steered = try #require(await f.runtime.steers.first)
        #expect(steered.configuration.reasoningEffort == "medium" && steered.runID == original.id)
        #expect(f.store.thread(f.threadID)?.reasoningEffort == "low")
        #expect(f.store.thread(f.threadID)?.queuedTurns.first?.configuration.reasoningEffort == "high")
        f.store.setDraft("Latest unsent draft after changing reasoning", id: f.threadID)
        await f.runtime.finish()
        try await waitNativeReasoning { await f.runtime.starts.count == 2 }
        let started = try #require(await f.runtime.starts.last)
        #expect(started.text == queued.text && started.configuration.reasoningEffort == "high" && started.runID == queued.id)
        #expect(f.store.thread(f.threadID)?.reasoningEffort == "low")
        #expect(f.store.thread(f.threadID)?.draft == "Latest unsent draft after changing reasoning")
        await f.runtime.finish()
        try await waitNativeReasoning { f.store.thread(f.threadID)?.activeRun == nil }
        #expect(f.store.thread(f.threadID)?.runHistory?.map { $0.configuration.reasoningEffort } == ["medium", "high"])
        #expect(f.store.errorMessage == nil)
        try WorkspaceJournal.validate(f.store.snapshot)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}
