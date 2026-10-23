import Foundation
import Testing
@testable import CoincideCore

private actor ScratchPlanAdapterPeer: ProviderSession {
    struct Input: Sendable { let text: String; let thread: CodingThread }
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private(set) var inputs: [Input] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) {
        inputs.append(.init(text: text, thread: thread))
        guard let runID = thread.activeRun?.id else { return }
        for event in [ProviderEvent.thread("controlled-" + thread.id.uuidString), .turn(runID.uuidString),
                      .message(.init(role: .assistant, text: "Controlled public response")), .completed(.idle)] {
            sink.yield(.context(runID: runID, event: event))
        }
    }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { sink.finish() }
}

private struct ScratchPlanAdapterFixture {
    let root: URL, database: URL
    let allocation: ScratchWorkspaceAllocation
    let source: CodingThread
    let engine: WorkspaceEngine
    let peer: ScratchPlanAdapterPeer
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-scratch-plan-adapter-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            // The fixture obtains an actual private allocator claim. The plan is
            // public transcript presentation, never a native Git/history proof.
            let allocation = try ScratchWorkspaceService(dataRoot: root).prepare(commandID: UUID(), threadID: UUID(), namingText: "Keep original scratch code")
            var source = CodingThread(project: allocation.project, model: "controlled-model")
            source.id = allocation.threadID; source.createdAt = allocation.receipt.createdAt
            source.workspacePath = allocation.workspacePath; source.scratchWorkspace = allocation.receipt
            source.permission = .supervised; source.checkpointPolicy = .disabled; source.agentModeID = "plan"
            source.draft = "  Keep literal source draft e\u{301}\n "
            source.draftAttachments = [.init(id: UUID(), name: "retained.txt", mimeType: "text/plain", byteCount: 1,
                digest: String(repeating: "a", count: 64), fileExtension: "txt")]
            source.providerMetadata = .object(["codexInteractionModes": .object([
                "supported": .bool(true), "profile": .string("codex-0.163"), "modes": .array([.string("default"), .string("plan")])])])
            var plan = ChatMessage(id: "original-completed-plan", role: .tool, text: "# Exact source plan\r\n\r\nKeep code, cafe\u{301} and 🌍.\r\n")
            plan.providerEntity = .init(key: .init(sessionID: "controlled-source", type: "plan", id: "original-plan"),
                fields: .object(["content": .string(plan.text), "nativeKind": .string("proposed_plan"), "status": .string("completed")]))
            source.messages = [plan]
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [allocation.project]; snapshot.threads = [source]
            let database = root.appendingPathComponent("workspace.sqlite")
            try await WorkspaceDatabase(url: database).save(snapshot, event: "fixture.scratch-plan-adapter")
            let peer = ScratchPlanAdapterPeer()
            let engine = try WorkspaceEngine(url: database, providerFactory: { _ in peer }, identityResolver: { _ in nil })
            _ = try await engine.load()
            return .init(root: root, database: database, allocation: allocation, source: source, engine: engine, peer: peer)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func request(destination: UUID = UUID()) -> TranscriptPlanImplementation {
        .init(thread: source, message: source.messages[0], destination: .init(threadID: destination))
    }
    func close() async { await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}
private func scratchAdapterEventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw ScratchWorkspaceError("The controlled scratch adapter boundary was not reached.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func scratchPlanAdapterCreatesRealSameFolderGrantAndRecoversOnlyTheOriginalReceiptAfterRestart() async throws {
    let f = try await ScratchPlanAdapterFixture.make()
    do {
        let destination = UUID(), commandID = UUID(), request = f.request(destination: destination)
        let file = URL(fileURLWithPath: f.allocation.workspacePath).appendingPathComponent("keep-original-code.txt")
        try Data("original code e\u{301}\n".utf8).write(to: file)
        let receipt = try await f.engine.implementTranscriptPlan(request, commandID: commandID)
        try await scratchAdapterEventually { await f.peer.inputs.count == 1 }
        let snapshot = await f.engine.current().snapshot
        let original = try #require(snapshot.threads.first { $0.id == f.source.id })
        let child = try #require(snapshot.threads.first { $0.id == destination })
        let grant = try #require(child.scratchWorkspace)
        #expect(original == f.source && child.workspacePath.utf8.elementsEqual(original.workspacePath.utf8))
        #expect(grant.commandID == commandID && grant.threadID == destination && grant.sharedFrom == f.allocation.receipt.commandID)
        #expect(grant.identity == f.allocation.receipt.identity && grant != f.allocation.receipt)
        #expect(child.transcriptPlanSource?.threadID == original.id && child.agentModeID == "default" && child.permission == original.permission)
        try ScratchWorkspaceService(dataRoot: f.root).validate(thread: child)
        let inputs = await f.peer.inputs, input = try #require(inputs.first)
        #expect(input.thread.id == destination && input.thread.activeRun?.configuration.nativeThreadID == nil)
        #expect(input.text.utf8.elementsEqual(TranscriptPlanText.implementationPrompt(f.source.messages[0].text).utf8))
        #expect(try String(contentsOf: file, encoding: .utf8) == "original code e\u{301}\n")
        let duplicate = try await f.engine.implementTranscriptPlan(request, commandID: commandID)
        #expect(duplicate == receipt)
        var refused = false
        do { _ = try await f.engine.implementTranscriptPlan(f.request(), commandID: commandID) } catch { refused = true }
        #expect(refused)
        await f.engine.shutdown()
        let reopenedPeer = ScratchPlanAdapterPeer()
        let reopened = try WorkspaceEngine(url: f.database, providerFactory: { _ in reopenedPeer }, identityResolver: { _ in nil })
        do {
            let recovered = try await reopened.implementTranscriptPlan(request, commandID: commandID)
            #expect(recovered == receipt)
            let replayInputs = await reopenedPeer.inputs
            #expect(replayInputs.isEmpty)
            let recoveries = try await reopened.scratchWorkspaceRecoveries()
            #expect(recoveries.contains { $0.id == commandID && $0.phase == .accepted })
        } catch { await reopened.shutdown(); throw error }
        await reopened.shutdown()
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(arguments: ["source-draft", "other-destination-grant", "other-command-grant", "physical-replacement"])
func scratchPlanAdapterRefusesStaleCaptureAndForeignGrantWithoutInputOrFolderDeletion(change: String) async throws {
    let f = try await ScratchPlanAdapterFixture.make()
    do {
        let commandID = UUID(), request = f.request()
        let prepared = try await f.engine.prepareTranscriptPlanImplementation(request, commandID: commandID)
        var attempted = prepared
        let service = ScratchWorkspaceService(dataRoot: f.root)
        switch change {
        case "source-draft": _ = try await f.engine.dispatch(.editThread(f.source.id, .draft("newer literal draft")))
        case "other-destination-grant":
            attempted = prepared.usingScratchAllocation(try service.reuse(source: f.allocation.receipt, commandID: UUID(), threadID: UUID()))
        case "other-command-grant":
            attempted = prepared.usingScratchAllocation(try service.reuse(source: f.allocation.receipt, commandID: UUID(), threadID: request.destination!.threadID))
        default:
            try FileManager.default.moveItem(atPath: f.allocation.workspacePath, toPath: f.allocation.workspacePath + "-original-owned")
            try FileManager.default.createDirectory(atPath: f.allocation.workspacePath, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("foreign bytes".utf8).write(to: URL(fileURLWithPath: f.allocation.workspacePath).appendingPathComponent("foreign.txt"))
        }
        var refused = false
        do { _ = try await f.engine.implementTranscriptPlan(attempted, commandID: commandID) } catch { refused = true }
        let inputs = await f.peer.inputs, snapshot = await f.engine.current().snapshot
        #expect(refused && inputs.isEmpty && snapshot.threads.count == 1)
        #expect(FileManager.default.fileExists(atPath: f.allocation.workspacePath))
        if change == "physical-replacement" {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: f.allocation.workspacePath).appendingPathComponent("foreign.txt"))
            #expect(bytes == Data("foreign bytes".utf8))
        }
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func scratchContextForkUsesARealGrantWithoutSubmittingAndKeepsTheSourceComposerThroughRestart() async throws {
    let f = try await ScratchPlanAdapterFixture.make()
    do {
        let runID = UUID()
        for attachment in f.source.draftAttachments {
            _ = try await f.engine.dispatch(.removeAttachment(threadID: f.source.id, attachmentID: attachment.id))
        }
        _ = try await f.engine.dispatch(.submit(threadID: f.source.id, text: "controlled source context"), id: runID)
        try await scratchAdapterEventually { await f.engine.current().snapshot.threads.first { $0.id == f.source.id }?.runHistory?.last?.status == .completed }
        _ = try await f.engine.dispatch(.editThread(f.source.id, .draft("  Newer source draft e\u{301}\n ")))
        _ = try await f.engine.dispatch(.addAttachments(threadID: f.source.id, attachments: f.source.draftAttachments))
        let source = try #require(await f.engine.current().snapshot.threads.first { $0.id == f.source.id })
        var destination = ProviderConfiguration(thread: source); destination.nativeThreadID = nil
        let review = try await f.engine.reviewContextTransfer(.init(sourceThreadID: source.id,
            expectedConfiguration: .init(thread: source), sourcePoint: .run(runID), intent: .fork(destination: destination)))
        let commandID = UUID(), title = "Independent context in the same scratch folder"
        let receipt = try await f.engine.acceptContextTransfer(reviewID: review.id, digest: review.digest, title: title, commandID: commandID)
        let snapshot = await f.engine.current().snapshot
        let child = try #require(snapshot.threads.first { $0.id == review.targetThreadID })
        let original = try #require(snapshot.threads.first { $0.id == source.id })
        let grant = try #require(child.scratchWorkspace)
        #expect(original == source && child.workspacePath.utf8.elementsEqual(source.workspacePath.utf8))
        #expect(grant.commandID == commandID && grant.sharedFrom == f.allocation.receipt.commandID && grant.threadID == child.id)
        #expect(child.contextTransferLineage?.parentThreadID == source.id && child.activeRun == nil && child.queuedTurns.isEmpty)
        #expect(child.messages.isEmpty && child.draft.isEmpty && child.draftAttachments.isEmpty)
        #expect(snapshot.contextTransfers?.first { $0.id == review.id }?.status == .pending)
        try ScratchWorkspaceService(dataRoot: f.root).validate(thread: child)
        let inputs = await f.peer.inputs
        #expect(inputs.count == 1)
        let duplicate = try await f.engine.acceptContextTransfer(reviewID: review.id, digest: review.digest, title: title, commandID: commandID)
        #expect(duplicate == receipt)
        await f.engine.shutdown()
        let reopened = try WorkspaceEngine(url: f.database, providerFactory: { _ in Issue.record("Context acceptance receipt must not start a provider"); return ScratchPlanAdapterPeer() }, identityResolver: { _ in nil })
        do {
            let recovered = try await reopened.acceptContextTransfer(reviewID: review.id, digest: review.digest, title: title, commandID: commandID)
            #expect(recovered == receipt)
        } catch { await reopened.shutdown(); throw error }
        await reopened.shutdown()
    } catch { await f.close(); throw error }
    await f.close()
}
