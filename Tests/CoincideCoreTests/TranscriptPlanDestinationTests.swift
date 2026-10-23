import Foundation
import Testing
@testable import CoincideCore

private struct FreshPlanFixture {
    var snapshot: WorkspaceSnapshot
    let sourceID: UUID
    let messageID = "completed-native-plan"
    init(path: String = "/private/offline-codex-plan-café") {
        let project = WorkspaceProject(path: path)
        var source = CodingThread(project: project, model: "captured-wire-model")
        source.permission = .auto; source.reasoningEffort = "high"; source.agentModeID = "plan"
        source.providerThreadID = "original-native-context"; source.checkpointPolicy = .disabled
        source.providerMetadata = .object(["codexInteractionModes": .object([
            "supported": .bool(true), "profile": .string("codex-0.163"), "modes": .array([.string("default"), .string("plan")])])])
        var message = ChatMessage(id: messageID, role: .tool, text: "# Exact cafe\u{301} plan\r\n\r\nKeep whitespace and 🌍.\r\n")
        message.providerEntity = .init(key: .init(sessionID: "original-native-context", type: "plan", id: "owned-plan"),
            fields: .object(["content": .string(message.text), "nativeKind": .string("proposed_plan"), "status": .string("completed")]))
        source.messages = [message]; sourceID = source.id
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [source]; self.snapshot = snapshot
    }
    var source: CodingThread { snapshot.threads[0] }
    var message: ChatMessage { source.messages[0] }
    func request(destination: UUID? = nil) -> TranscriptPlanImplementation {
        .init(thread: source, message: message, destination: destination.map { .init(threadID: $0) })
    }
}

@Test func transcriptPlanAtomicImplementationLeavesCodexPlanWithExplicitDefaultAndPreservesPermissions() throws {
    let f = FreshPlanFixture(), id = UUID()
    let decision = try WorkspaceDecision.make(.transcriptPlanImplementation(f.request()), id: id, snapshot: f.snapshot, now: .now)
    let current = try #require(decision.snapshot.threads.first)
    #expect(current.agentModeID == "default" && current.activeRun?.configuration.agentModeID == "default")
    #expect(current.permission == .auto && current.activeRun?.configuration.permission == .auto)
    #expect(current.providerThreadID == f.source.providerThreadID && current.messages.first == f.message)
    #expect(current.messages.last?.text.utf8.elementsEqual(TranscriptPlanText.implementationPrompt(f.message.text).utf8) == true)
    #expect(current.transcriptPlanSource == nil)
}

@Test func transcriptPlanNewConversationIsOneAtomicFreshInputAndKeepsLiteralSourceDraftAndAttachments() throws {
    var f = FreshPlanFixture()
    f.snapshot.threads[0].draft = "  Keep this newer-authored draft e\u{301}\n "
    f.snapshot.threads[0].draftAttachments = [.init(id: UUID(), name: "kept.txt", mimeType: "text/plain", byteCount: 1,
        digest: String(repeating: "a", count: 64), fileExtension: "txt")]
    let before = f.source, destination = UUID(), id = UUID(), now = Date()
    let request = f.request(destination: destination)
    let decision = try WorkspaceDecision.make(.transcriptPlanImplementation(request), id: id, snapshot: f.snapshot, now: now)
    let original = try #require(decision.snapshot.threads.first { $0.id == f.sourceID })
    let created = try #require(decision.snapshot.threads.first { $0.id == destination })
    #expect(original == before)
    #expect(created.projectID == before.projectID && created.workspacePath.utf8.elementsEqual(before.workspacePath.utf8))
    #expect(created.provider == before.provider && created.model == before.model && created.permission == before.permission)
    #expect(created.providerThreadID == nil && created.activeRun?.configuration.nativeThreadID == nil)
    #expect(created.agentModeID == "default" && created.activeRun?.configuration.agentModeID == "default")
    #expect(created.draft.isEmpty && created.draftAttachments.isEmpty && created.contextTransferLineage == nil && created.contextProviderBindings == nil)
    #expect(created.messages.count == 1 && created.messages[0].role == .user && created.messages[0].attachments == nil)
    #expect(created.messages[0].text.utf8.elementsEqual(TranscriptPlanText.implementationPrompt(f.message.text).utf8))
    #expect(created.activeRun?.id == id && created.runHistory?.count == 1)
    let link = try #require(created.transcriptPlanSource)
    #expect(link.threadID == before.id && link.threadCreatedAt == before.createdAt && link.messageID == f.message.id && link.messageDigest.count == 64)
    let data = try JSONEncoder().encode(created)
    let reopened = try JSONDecoder().decode(CodingThread.self, from: data)
    #expect(reopened.transcriptPlanSource == link)
    let payload = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(link))
    #expect(payload["storage"] == .null && payload["threadID"] == .string(before.id.uuidString))
    #expect(decision.effects.count == 1)
    let effect = try #require(decision.effects.first)
    if case .providerStart(let threadID, let runID, let configuration, let text, let attachments) = effect.request {
        #expect(threadID == destination && runID == id && configuration.nativeThreadID == nil && configuration.permission == .auto)
        #expect(text.utf8.elementsEqual(TranscriptPlanText.implementationPrompt(f.message.text).utf8) && attachments == nil)
    } else { Issue.record("The original command must create exactly one native input effect") }
}

@Test(arguments: ["draft", "attachment", "birth", "workspace-bytes", "model", "permission", "source", "collision"])
func transcriptPlanNewConversationRefusesChangedSourceWithoutCreatingOrConsumingAnything(change: String) throws {
    var f = FreshPlanFixture()
    f.snapshot.threads[0].draft = "source draft"
    let destination = UUID(), request = f.request(destination: destination)
    switch change {
    case "draft": f.snapshot.threads[0].draft += " newer"
    case "attachment": f.snapshot.threads[0].draftAttachments = [.init(id: UUID(), name: "new.txt", mimeType: "text/plain", byteCount: 1, digest: String(repeating: "b", count: 64), fileExtension: "txt")]
    case "birth": f.snapshot.threads[0].createdAt = f.snapshot.threads[0].createdAt.addingTimeInterval(1)
    case "workspace-bytes":
        let original = f.source.workspacePath, decomposed = original.decomposedStringWithCanonicalMapping
        let alternate = original.utf8.elementsEqual(decomposed.utf8) ? original.precomposedStringWithCanonicalMapping : decomposed
        try #require(original == alternate && !original.utf8.elementsEqual(alternate.utf8))
        f.snapshot.threads[0].workspacePath = alternate
    case "model": f.snapshot.threads[0].model = "newer-model"
    case "permission": f.snapshot.threads[0].permission = .fullAccess
    case "source": f.snapshot.threads[0].messages[0].text += " changed"
    default: var other = CodingThread(project: f.snapshot.projects[0]); other.id = destination; f.snapshot.threads.append(other)
    }
    let before = f.snapshot
    #expect(throws: WorkspaceCommandError.self) { _ = try WorkspaceDecision.make(.transcriptPlanImplementation(request), id: UUID(), snapshot: before, now: .now) }
    #expect(f.snapshot == before)
}

@Test(arguments: ["in_progress", "unknown", "missing"])
func transcriptPlanNativeIncompleteItemsNeverEnableEitherImplementationAction(status: String) throws {
    var f = FreshPlanFixture()
    var fields = f.message.providerEntity?.fields.object ?? [:]
    fields["status"] = status == "missing" ? .null : .string(status)
    f.snapshot.threads[0].messages[0].providerEntity?.fields = .object(fields)
    let card = TranscriptToolPresentation.card(for: f.message)
    #expect(card.kind == .plan && card.status != .completed)
    let same = f.request(), fresh = f.request(destination: UUID())
    #expect(throws: WorkspaceCommandError.self) { _ = try same.command(in: f.snapshot) }
    #expect(throws: WorkspaceCommandError.self) { _ = try fresh.command(in: f.snapshot) }
}

private actor FreshPlanPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private(set) var inputs: [(UUID, String, String?, String?)] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) { inputs.append((thread.id, text, thread.activeRun?.configuration.nativeThreadID, thread.activeRun?.configuration.agentModeID)) }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { sink.finish() }
}

@Test(.timeLimit(.minutes(1)))
func transcriptPlanNewConversationOriginalReceiptSurvivesRestartAndRejectsChangedDestinationWithoutReplay() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-fresh-plan-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    var f = FreshPlanFixture(path: root.path); f.snapshot.threads[0].draft = "Keep literal source e\u{301}\n "
    let database = root.appendingPathComponent("workspace.sqlite"), peer = FreshPlanPeer(), commandID = UUID(), destinationID = UUID()
    let request = f.request(destination: destinationID)
    try await WorkspaceDatabase(url: database).save(f.snapshot, event: "fixture.fresh-plan")
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in peer }, identityResolver: { _ in nil })
    do {
        let receipt = try await engine.implementTranscriptPlan(request, commandID: commandID)
        let duplicate = try await engine.implementTranscriptPlan(request, commandID: commandID)
        #expect(receipt == duplicate && receipt.rejection == nil)
        let deadline = ContinuousClock.now + .seconds(3)
        while await peer.inputs.isEmpty {
            guard ContinuousClock.now < deadline else { throw CoincideError("The private fresh-plan input was not delivered.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let inputs = await peer.inputs
        #expect(inputs.count == 1 && inputs[0].0 == destinationID && inputs[0].2 == nil && inputs[0].3 == "default")
        var collisionRefused = false
        do { _ = try await engine.implementTranscriptPlan(f.request(destination: UUID()), commandID: commandID) } catch { collisionRefused = true }
        #expect(collisionRefused)
        await engine.shutdown()
        let reopened = try WorkspaceEngine(url: database, providerFactory: { _ in Issue.record("Original fresh-plan receipts must not replay"); throw CancellationError() }, identityResolver: { _ in nil })
        do {
            let recovered = try await reopened.implementTranscriptPlan(request, commandID: commandID)
            #expect(recovered == receipt)
            let current = await reopened.current()
            let source = try #require(current.snapshot.threads.first { $0.id == f.sourceID })
            let created = try #require(current.snapshot.threads.first { $0.id == destinationID })
            #expect(source.draft.utf8.elementsEqual(f.source.draft.utf8) && source.messages == f.source.messages)
            #expect(created.messages.filter { $0.role == .user }.count == 1 && created.transcriptPlanSource?.threadID == f.sourceID)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
        #expect(await peer.inputs.count == 1)
    } catch { await engine.shutdown(); throw error }
}
