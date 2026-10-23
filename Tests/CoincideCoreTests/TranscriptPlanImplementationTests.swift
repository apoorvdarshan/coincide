import Foundation
import Testing
@testable import CoincideCore

private struct TranscriptPlanFixture {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var snapshot: WorkspaceSnapshot
    let threadID: UUID
    let message: ChatMessage
    init(path: String = "/private/synthetic-transcript-plan") {
        let project = WorkspaceProject(path: path)
        var thread = CodingThread(project: project, model: "captured-model")
        thread.checkpointPolicy = .disabled; thread.permission = .supervised
        var source = ChatMessage(id: "plan-source", role: .tool, text: "# Build café\n\nImplement exact source")
        source.providerEntity = .init(key: .init(sessionID: "native-plan-session", type: "plan", id: "native-plan"),
            fields: .object(["content": .string(source.text)]))
        thread.messages = [source]
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        self.snapshot = snapshot; threadID = thread.id; message = source
    }
    var capture: TranscriptPlanImplementation { .init(thread: snapshot.threads[0], message: message) }
}

private enum TranscriptPlanStaleChange: CaseIterable, Sendable { case textBytes, entity, birth, workspace, draft, attachment, configuration, permission, active, queue, planningMode }

@Test(arguments: TranscriptPlanStaleChange.allCases)
private func transcriptPlanAtomicAcceptanceRefusesStaleSourceAndComposerOwnership(change: TranscriptPlanStaleChange) throws {
    var f = TranscriptPlanFixture()
    let request = f.capture
    switch change {
    case .textBytes:
        f.snapshot.threads[0].messages[0].text = "# Build cafe\u{301}\n\nImplement exact source"
        #expect(f.snapshot.threads[0].messages[0].text == f.message.text)
    case .entity:
        f.snapshot.threads[0].messages[0].providerEntity?.fields = .object(["content": .string("# A newer plan")])
    case .birth: f.snapshot.threads[0].createdAt = f.snapshot.threads[0].createdAt.addingTimeInterval(1)
    case .workspace: f.snapshot.threads[0].workspacePath += "/newer"
    case .draft: f.snapshot.threads[0].draft = "  "
    case .attachment:
        f.snapshot.threads[0].draftAttachments = [.init(id: UUID(), name: "kept.txt", mimeType: "text/plain", byteCount: 1,
            digest: String(repeating: "a", count: 64), fileExtension: "txt")]
    case .configuration: f.snapshot.threads[0].model = "newer-model"
    case .permission: f.snapshot.threads[0].permission = .fullAccess
    case .active:
        let configuration = ProviderConfiguration(thread: f.snapshot.threads[0])
        f.snapshot.threads[0].activeRun = .init(id: UUID(), configuration: configuration, startedAt: f.now)
    case .queue:
        f.snapshot.threads[0].queuedTurns = [.init(id: UUID(), text: "Earlier input", configuration: .init(thread: f.snapshot.threads[0]), createdAt: f.now)]
    case .planningMode:
        f.snapshot.threads[0].agentModeID = "plan"
    }
    let before = f.snapshot
    #expect(throws: WorkspaceCommandError.self) {
        _ = try WorkspaceDecision.make(.transcriptPlanImplementation(request), id: UUID(), snapshot: before, now: f.now)
    }
    #expect(f.snapshot == before)
    #expect(f.snapshot.threads[0].runHistory?.isEmpty ?? true)
}

@Test func transcriptPlanCaptureFlatCodecAndAcceptedInputPreservePermissionAndOriginalSource() throws {
    let f = TranscriptPlanFixture(), id = UUID()
    let request = f.capture
    let data = try JSONEncoder().encode(request)
    let object = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(object["threadID"] == .string(f.threadID.uuidString) && object["storage"] == .null)
    let decoded = try JSONDecoder().decode(TranscriptPlanImplementation.self, from: data)
    #expect(decoded == request)
    let decision = try WorkspaceDecision.make(.transcriptPlanImplementation(decoded), id: id, snapshot: f.snapshot, now: f.now)
    let thread = try #require(decision.snapshot.threads.first)
    #expect(thread.permission == .supervised && thread.draft.isEmpty && thread.draftAttachments.isEmpty)
    #expect(thread.messages.first == f.message)
    let authored = thread.messages.filter { $0.role == .user }
    #expect(authored.count == 1 && authored[0].text.utf8.elementsEqual(TranscriptPlanText.implementationPrompt(f.message.text).utf8))
    #expect(thread.activeRun?.id == id && thread.activeRun?.configuration.model == "captured-model")
}

private actor TranscriptPlanPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private(set) var inputs: [String] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) { inputs.append(text) }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { sink.finish() }
}

@Test(.timeLimit(.minutes(1)))
func transcriptPlanOriginalCommandReceiptSurvivesRestartWithoutResubmittingAnAcceptedPlan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-transcript-plan-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let f = TranscriptPlanFixture(path: root.path), database = root.appendingPathComponent("workspace.sqlite"), id = UUID(), peer = TranscriptPlanPeer()
    try await WorkspaceDatabase(url: database).save(f.snapshot, event: "fixture.transcript-plan")
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in peer }, identityResolver: { _ in nil })
    do {
        let receipt = try await engine.implementTranscriptPlan(f.capture, commandID: id)
        let duplicate = try await engine.implementTranscriptPlan(f.capture, commandID: id)
        #expect(receipt == duplicate && receipt.rejection == nil)
        let deadline = ContinuousClock.now + .seconds(3)
        while await peer.inputs.isEmpty {
            guard ContinuousClock.now < deadline else { throw CoincideError("The controlled plan provider did not receive its accepted input.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await peer.inputs.count == 1)
        await engine.shutdown()
        let restarted = try WorkspaceEngine(url: database, providerFactory: { _ in
            Issue.record("A durable original plan receipt cannot start a provider after restart")
            throw CancellationError()
        }, identityResolver: { _ in nil })
        let recovered = try await restarted.implementTranscriptPlan(f.capture, commandID: id)
        #expect(recovered == receipt)
        let current = await restarted.current()
        #expect(current.snapshot.threads[0].messages.filter { $0.role == .user }.count == 1)
        await restarted.shutdown()
    } catch { await engine.shutdown(); throw error }
}

@Test func transcriptPlanImplementationRefusesUnmarkedLegacyACPOutputAndAmbiguousSourceIDs() {
    var f = TranscriptPlanFixture()
    var legacy = f.message; legacy.providerEntity = nil
    f.snapshot.threads[0].provider = .acp
    f.snapshot.threads[0].messages = [legacy]
    let legacyRequest = TranscriptPlanImplementation(thread: f.snapshot.threads[0], message: legacy)
    #expect(throws: WorkspaceCommandError.self) { _ = try legacyRequest.command(in: f.snapshot) }
    let explicitLookingText = ChatMessage(id: "ordinary-output", role: .tool, text: "ExitPlanMode\n{\"plan\":\"arbitrary output\"}")
    f.snapshot.threads[0].messages = [explicitLookingText]
    let shaped = TranscriptPlanImplementation(thread: f.snapshot.threads[0], message: explicitLookingText)
    #expect(throws: WorkspaceCommandError.self) { _ = try shaped.command(in: f.snapshot) }
    let typed = TranscriptPlanFixture()
    var duplicate = typed.snapshot
    duplicate.threads[0].messages.append(typed.message)
    #expect(throws: WorkspaceCommandError.self) { _ = try typed.capture.command(in: duplicate) }
}
