import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private actor NativeSteeringProvider: ProviderSession {
    struct Call: Equatable {
        let text: String
        let model: String
        let permission: PermissionMode
        let runID: UUID?
        let turnID: String?
        let clientMessageID: String?
    }
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private var turnID: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var uncertain = false
    private var steeringAllowed = true
    private(set) var starts: [Call] = []
    private(set) var steers: [Call] = []
    private(set) var closes = 0
    init() {
        let pair = AsyncStream<ProviderEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
    }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) { send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) {
        runID = thread.activeRun?.id; turnID = "native-turn-\(starts.count + 1)"
        starts.append(.init(text: input.text, model: thread.model, permission: thread.permission,
            runID: runID, turnID: turnID, clientMessageID: nil))
        emit(.thread("native-steering-thread")); emit(.turn(turnID!))
    }
    func steeringCapabilities() -> ProviderSteeringCapabilities {
        .init(supportsActiveSteering: runID != nil && turnID != nil && steeringAllowed)
    }
    func setSteeringAllowed(_ allowed: Bool) {
        guard steeringAllowed != allowed else { return }
        steeringAllowed = allowed; emit(.steeringCapabilitiesChanged)
    }
    func streamAssistant(_ text: String) { emit(.delta(id: "native-steering-stream", role: .assistant, text: text)) }
    func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String,
               clientMessageID: String) async throws -> ProviderSteeringReceipt {
        guard thread.activeRun?.id == runID, expectedTurnID == turnID else { throw ProviderSteeringError(.staleTarget) }
        steers.append(.init(text: input.text, model: thread.model, permission: thread.permission,
            runID: thread.activeRun?.id, turnID: expectedTurnID, clientMessageID: clientMessageID))
        if !released { await withCheckedContinuation { waiters.append($0) } }
        if uncertain { throw ProviderSteeringError(.outcomeUncertain) }
        return try .init(turnID: expectedTurnID)
    }
    func setUncertain() { uncertain = true }
    func release() {
        released = true
        let current = waiters; waiters = []
        current.forEach { $0.resume() }
    }
    func finish() { emit(.completed(.idle)); runID = nil; turnID = nil }
    private func emit(_ event: ProviderEvent) {
        if let runID { continuation.yield(.context(runID: runID, event: event)) }
    }
    func interrupt() { emit(.completed(.interrupted)); runID = nil; turnID = nil }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { closes += 1; continuation.finish() }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeSteeringCacheRefreshesOnSemanticCapabilityChangesWithoutRefreshingForStreamTokens() async throws {
    let f = try await NativeSteeringFixture.make()
    do {
        try await f.start()
        let originalKey = f.store.promptSteeringKey(threadID: f.threadID)
        await f.provider.setSteeringAllowed(false)
        try await waitNativeSetup { f.store.promptSteeringKey(threadID: f.threadID) != originalKey }
        #expect(f.store.steeringAvailability(threadID: f.threadID) == nil)
        await f.store.refreshPromptSteeringAvailability(threadID: f.threadID)
        #expect(f.store.steeringAvailability(threadID: f.threadID)?.canSteer == false)
        let unavailableKey = f.store.promptSteeringKey(threadID: f.threadID)
        await f.provider.streamAssistant("A normal streaming token")
        try await waitNativeSetup { f.store.thread(f.threadID)?.messages.contains(where: { $0.text == "A normal streaming token" }) == true }
        #expect(f.store.promptSteeringKey(threadID: f.threadID) == unavailableKey)
        #expect(f.store.steeringAvailability(threadID: f.threadID)?.canSteer == false)
        await f.provider.setSteeringAllowed(true)
        try await waitNativeSetup { f.store.promptSteeringKey(threadID: f.threadID) != unavailableKey }
        await f.store.refreshPromptSteeringAvailability(threadID: f.threadID)
        #expect(f.store.steeringAvailability(threadID: f.threadID)?.canSteer == true)
        await f.provider.finish()
        try await waitNativeSetup { f.store.thread(f.threadID)?.activeRun == nil }
        try WorkspaceJournal.validate(f.store.snapshot)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor private struct NativeSteeringFixture {
    let root: URL
    let database: URL
    let threadID: UUID
    let provider: NativeSteeringProvider
    let engine: WorkspaceEngine
    let store: WorkspaceStore
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-steering-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        let checkout = root.appendingPathComponent("Checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("workspace.sqlite"), project = WorkspaceProject(path: checkout.path)
        var thread = CodingThread(project: project, model: "Captured running model")
        thread.provider = .codex; thread.checkpointPolicy = .disabled
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]; snapshot.threads = [thread]
        try await WorkspaceDatabase(url: database).save(snapshot, event: "native.steering.fixture")
        let provider = NativeSteeringProvider()
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in provider }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine, codexInstallation: fixtureCodexInstallation(root: root)); await store.load()
        return .init(root: root, database: database, threadID: thread.id, provider: provider, engine: engine, store: store)
    }
    func start() async throws {
        #expect(await store.submit("Opening input", threadID: threadID).value)
        try await waitNativeSetup { store.thread(threadID)?.activeRun?.nativeTurnID != nil }
        await store.refreshPromptSteeringAvailability(threadID: threadID)
        #expect(store.steeringAvailability(threadID: threadID)?.canSteer == true)
    }
    func cleanup() async {
        await provider.release(); await store.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeSteerSavedActionReadsLatestDraftAndUsesRunningSettingsWithoutStartingANewRun() async throws {
    let f = try await NativeSteeringFixture.make()
    do {
        try await f.start()
        let runID = try #require(f.store.thread(f.threadID)?.activeRun?.id)
        let original = try #require(f.store.thread(f.threadID))
        f.store.setModel("Future queued model", id: f.threadID)
        try await waitNativeSetup { f.store.thread(f.threadID)?.model == "Future queued model" }
        await f.store.refreshPromptSteeringAvailability(threadID: f.threadID)
        f.store.setDraft("A persisted earlier fragment", id: f.threadID)
        try await waitNativeSetup {
            await f.engine.current().snapshot.threads.first(where: { $0.id == f.threadID })?.draft == "A persisted earlier fragment"
        }
        f.store.setDraft("O", id: f.threadID)
        let savedAction = ChatView(store: f.store, threadID: f.threadID).steerCurrentDraft
        let input = "Use the latest complete steering input — preserved Unicode 😀"
        f.store.setDraft(input, id: f.threadID)
        #expect(await savedAction().value)
        try await waitNativeSetup { await f.provider.steers.count == 1 }
        let calls = await f.provider.steers
        #expect(calls.first?.text == input && calls.first?.model == original.activeRun?.configuration.model)
        #expect(calls.first?.permission == original.activeRun?.configuration.permission)
        #expect(calls.first?.runID == runID && calls.first?.turnID == original.activeRun?.nativeTurnID)
        #expect(await f.provider.starts.count == 1 && f.store.thread(f.threadID)?.runHistory?.count == 1)
        let accepted = try #require(f.store.thread(f.threadID))
        #expect(accepted.messages.filter { $0.role == .user }.map(\.text) == ["Opening input", input])
        #expect(accepted.messages.last?.runReference == .init(threadID: f.threadID, runID: runID))
        #expect(accepted.model == "Future queued model" && accepted.queuedTurns.isEmpty)
        #expect(accepted.draft.isEmpty)
        f.store.setDraft("A newer draft while delivery is pending", id: f.threadID)
        await f.provider.release()
        try await waitNativeSetup { f.store.snapshot.promptSteerings?.last?.phase == .delivered }
        #expect(f.store.thread(f.threadID)?.draft == "A newer draft while delivery is pending")
        await f.provider.finish()
        try await waitNativeSetup { f.store.thread(f.threadID)?.activeRun == nil }
        #expect(f.store.thread(f.threadID)?.runHistory?.count == 1 && f.store.thread(f.threadID)?.runHistory?.first?.status == .completed)
        #expect(await f.provider.closes == 0)
        try WorkspaceJournal.validate(f.store.snapshot)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeQueuedSteeringUsesExactQueuedInputKeepsDraftAndAdvancesOnlyTheRemainingFIFO() async throws {
    let f = try await NativeSteeringFixture.make()
    do {
        try await f.start()
        #expect(await f.store.submit("First queued input", threadID: f.threadID).value)
        #expect(await f.store.submit("Promote this exact second input", threadID: f.threadID).value)
        let queued = try #require(f.store.thread(f.threadID)?.queuedTurns.last)
        let firstID = try #require(f.store.thread(f.threadID)?.queuedTurns.first?.id)
        let runID = try #require(f.store.thread(f.threadID)?.activeRun?.id)
        f.store.setDraft("Unrelated unsent composer draft", id: f.threadID)
        await f.store.refreshPromptSteeringAvailability(threadID: f.threadID)
        #expect(await f.store.steerQueued(queued.id, threadID: f.threadID).value)
        try await waitNativeSetup { await f.provider.steers.count == 1 }
        #expect(await f.provider.steers.first?.text == queued.text)
        #expect(f.store.thread(f.threadID)?.queuedTurns.map(\.id) == [firstID])
        #expect(f.store.thread(f.threadID)?.draft == "Unrelated unsent composer draft")
        #expect(f.store.thread(f.threadID)?.messages.last?.runReference?.runID == runID)
        await f.provider.release()
        try await waitNativeSetup { f.store.snapshot.promptSteerings?.last?.phase == .delivered }
        await f.provider.finish()
        try await waitNativeSetup { await f.provider.starts.count == 2 }
        let starts = await f.provider.starts
        #expect(starts.map(\.text) == ["Opening input", "First queued input"])
        #expect(starts.last?.runID == firstID && starts.last?.runID != runID)
        #expect(f.store.thread(f.threadID)?.draft == "Unrelated unsent composer draft")
        await f.provider.finish()
        try await waitNativeSetup { f.store.thread(f.threadID)?.activeRun == nil }
        try WorkspaceJournal.validate(f.store.snapshot)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeUnconfirmedSteeringKeepsItsInputAndQueueUntilExplicitContinueWithoutRepeating() async throws {
    let f = try await NativeSteeringFixture.make()
    do {
        try await f.start()
        #expect(await f.store.submit("Held FIFO input", threadID: f.threadID).value)
        await f.provider.setUncertain()
        f.store.setDraft("Steering input with a lost acknowledgement", id: f.threadID)
        await f.store.refreshPromptSteeringAvailability(threadID: f.threadID)
        #expect(await ChatView(store: f.store, threadID: f.threadID).steerCurrentDraft().value)
        try await waitNativeSetup { await f.provider.steers.count == 1 }
        await f.provider.release()
        try await waitNativeSetup { f.store.snapshot.promptSteerings?.last?.isUnconfirmed == true }
        let operationID = try #require(f.store.snapshot.promptSteerings?.last?.id)
        f.store.setDraft("Latest draft stays while outcome is unknown", id: f.threadID)
        await f.provider.finish()
        try await waitNativeSetup { f.store.thread(f.threadID)?.activeRun == nil }
        #expect(f.store.thread(f.threadID)?.queuePaused == true)
        #expect(await f.provider.starts.count == 1)
        #expect(await f.provider.steers.count == 1)
        await f.store.acknowledgePromptSteering(operationID)
        #expect(f.store.snapshot.promptSteerings?.last?.acknowledgedAt != nil)
        #expect(f.store.snapshot.promptSteerings?.last?.receipt == nil)
        #expect(f.store.thread(f.threadID)?.draft == "Latest draft stays while outcome is unknown")
        #expect(await f.provider.starts.count == 1)
        #expect(await f.provider.steers.count == 1)
        f.store.resumeQueue(f.threadID)
        try await waitNativeSetup { await f.provider.starts.count == 2 }
        #expect(await f.provider.starts.map(\.text) == ["Opening input", "Held FIFO input"])
        #expect(f.store.thread(f.threadID)?.messages.filter { $0.text == "Steering input with a lost acknowledgement" }.count == 1)
        await f.provider.finish()
        try await waitNativeSetup { f.store.thread(f.threadID)?.activeRun == nil }
        try WorkspaceJournal.validate(f.store.snapshot)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeQueuedEditorReplacesTextAndAttachmentsWithoutUnqueueingOrChangingTheLiveComposer() async throws {
    let f = try await NativeSteeringFixture.make()
    do {
        try await f.start()
        #expect(await f.store.submit("Original queued text", threadID: f.threadID).value)
        try await waitNativeSetup { f.store.thread(f.threadID)?.queuedTurns.count == 1 }
        let queued = try #require(f.store.thread(f.threadID)?.queuedTurns.first)
        f.store.setDraft("Still typing a different message e\u{301}\u{327}", id: f.threadID)
        let capturedDraft = try #require(f.store.thread(f.threadID)).draft
        f.store.editQueued(queued.id, threadID: f.threadID)
        let editor = try #require(f.store.queuedInputEditor)
        #expect(f.store.thread(f.threadID)?.queuedTurns.first?.id == queued.id)
        #expect(f.store.thread(f.threadID)?.draft.utf8.elementsEqual(capturedDraft.utf8) == true)
        editor.text = "Queued edit stays in its original position"
        let attachment = try await f.engine.attachments.importData(Data("Private immutable queued attachment".utf8), name: "queued.txt")
        editor.attachments = [attachment]
        var invalid = attachment; invalid.byteCount = -1
        let invalidRequest = QueuedInputReplacement(thread: editor.thread, queued: editor.original, text: "Refuse invalid metadata", attachments: [invalid])
        await #expect(throws: WorkspaceCommandError.self) { _ = try await f.engine.replaceQueuedInput(invalidRequest) }
        // A normal accepted edit after the refusal proves it was not an
        // infrastructure failure that stopped the engine's inbox.
        f.store.saveQueuedInputEditor(editor)
        try await waitNativeSetup { f.store.queuedInputEditor == nil }
        let after = try #require(f.store.thread(f.threadID)), changed = try #require(after.queuedTurns.first)
        #expect(changed.id == queued.id && changed.configuration == queued.configuration)
        #expect(changed.text == editor.text && changed.attachments == [attachment])
        #expect(after.draft.utf8.elementsEqual(capturedDraft.utf8) && after.draftAttachments.isEmpty)
        #expect(await f.provider.starts.count == 1)
        #expect(await f.provider.steers.isEmpty)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}
