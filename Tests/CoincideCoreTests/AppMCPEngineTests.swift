import Foundation
import Testing
@testable import CoincideCore

@Test(.timeLimit(.minutes(1))) func appMCPEngineExplicitQueuePreservesComposerCapturedFIFOAndRetryIdentityAcrossReopen() async throws {
    let fixture = try await AppMCPFacadeFixture.make()
    do {
        let attachment = ChatAttachment(id: UUID(), name: "draft.txt", mimeType: "text/plain", byteCount: 4, digest: String(repeating: "a", count: 64), fileExtension: "txt")
        _ = try await fixture.engine.dispatch(.editThread(fixture.threadID, .draft("Latest user draft 工作")))
        _ = try await fixture.engine.dispatch(.addAttachments(threadID: fixture.threadID, attachments: [attachment]))
        let literal = "  Queued by tool 😀\n$HOME remains literal  "
        let first = try await fixture.perform(.send(threadID: fixture.threadID, message: literal, mode: .queue, clientRequestID: "stable-first"))
        let repeated = try await fixture.perform(.send(threadID: fixture.threadID, message: literal, mode: .queue, clientRequestID: "stable-first"))
        #expect(first["runId"] == repeated["runId"] && first["messageId"] == repeated["messageId"])
        _ = try await fixture.engine.dispatch(.editThread(fixture.threadID, .model("future-model")))
        _ = try await fixture.perform(.send(threadID: fixture.threadID, message: "Second captured input", mode: .queue, clientRequestID: "stable-second"))
        let before = try #require((await fixture.engine.current()).snapshot.threads.first { $0.id == fixture.threadID })
        #expect(before.queuedTurns.count == 2 && before.queuedTurns[0].text == literal)
        #expect(before.queuedTurns.map(\.configuration.model) == ["wire-model", "future-model"])
        #expect(before.queuedTurns.allSatisfy { $0.attachments?.isEmpty != false })
        let firstID = before.queuedTurns[0].id, secondID = before.queuedTurns[1].id
        _ = try await fixture.perform(.editQueued(threadID: fixture.threadID, queuedRunID: firstID, text: "Edited literal 工作"))
        _ = try await fixture.perform(.reorderQueued(threadID: fixture.threadID, queuedRunID: secondID, beforeRunID: firstID))
        await #expect(throws: (any Error).self) {
            _ = try await fixture.perform(.send(threadID: fixture.threadID, message: "Changed request body", mode: .queue, clientRequestID: "stable-first"))
        }
        let after = try #require((await fixture.engine.current()).snapshot.threads.first { $0.id == fixture.threadID })
        #expect(after.draft == "Latest user draft 工作" && after.draftAttachments == [attachment])
        #expect(after.queuedTurns.map(\.id) == [secondID, firstID])
        #expect(after.queuedTurns.map(\.configuration) == [before.queuedTurns[1].configuration, before.queuedTurns[0].configuration])
        #expect(after.queuedTurns.last?.text == "Edited literal 工作" && after.activeRun?.id == fixture.runID)
        let sends = await fixture.peer.sentTexts
        #expect(sends == ["Opening native run"], "Queue tooling cannot start a second provider turn.")
        let health = await fixture.engine.current()
        #expect(health.error == nil)
        await fixture.engine.shutdown()
        let reopened = try WorkspaceEngine(url: fixture.database, providerFactory: { _ in throw AppMCPError(.unavailable) }, identityResolver: { _ in nil })
        do {
            let saved = try await reopened.load()
            let thread = try #require(saved.threads.first { $0.id == fixture.threadID })
            #expect(thread.queuedTurns == after.queuedTurns && thread.queuePaused && thread.activeRun == nil)
            #expect(thread.draft == after.draft && thread.draftAttachments == after.draftAttachments)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
        try fixture.remove()
    } catch { await fixture.close(); throw error }
}

@Test(.timeLimit(.minutes(1))) func appMCPEngineBatchCreationRetainsCapturedParentAuditRetriesAndBlankIndependentLaunch() async throws {
    let fixture = try await AppMCPFacadeFixture.make()
    do {
        _ = try await fixture.engine.dispatch(.editThread(fixture.threadID, .draft("Source draft must remain")))
        _ = try await fixture.engine.dispatch(.editThread(fixture.threadID, .model("future-header-model")))
        let requests: [AppMCPThreadCreation] = [.init(title: "Blank child 工作"), .init(title: "Explicit worker", prompt: "Only explicit child prompt")]
        let result = try await fixture.perform(.createThreads(requests, clientRequestID: "stable-batch"))
        let retried = try await fixture.perform(.createThreads(requests, clientRequestID: "stable-batch"))
        let created = try #require(result["threads"].array), again = try #require(retried["threads"].array)
        #expect(created.map { $0["threadId"] } == again.map { $0["threadId"] } && created.count == 2)
        let ids = Set(created.compactMap { $0["threadId"].string.flatMap(UUID.init(uuidString:)) })
        let snapshot = await fixture.engine.current().snapshot
        let children = snapshot.threads.filter { ids.contains($0.id) }
        #expect(snapshot.threads.count == 3 && children.count == 2)
        #expect(children.allSatisfy { $0.model == "wire-model" && $0.workspacePath == fixture.workspace.path })
        #expect(children.allSatisfy { $0.createdByAppMCP == .init(sessionID: fixture.scope.sessionID, threadID: fixture.threadID, runID: fixture.runID) })
        let blank = try #require(children.first { $0.title == "Blank child 工作" })
        #expect(blank.messages.isEmpty && blank.draft.isEmpty && blank.activeRun == nil && blank.queuedTurns.isEmpty && blank.providerThreadID == nil)
        let worker = try #require(children.first { $0.title == "Explicit worker" })
        #expect(worker.messages.filter { $0.role == .user }.map(\.text) == ["Only explicit child prompt"])
        #expect(snapshot.threads.first { $0.id == fixture.threadID }?.draft == "Source draft must remain")
        let launch = AppMCPThreadLaunch(projectID: fixture.projectID, creation: .init(title: "Independent top-level"))
        let launched = try await fixture.perform(.launchThread(launch))
        let targetID = try #require(launched["threadId"].string.flatMap(UUID.init(uuidString:)))
        let independent = try #require((await fixture.engine.current()).snapshot.threads.first { $0.id == targetID })
        #expect(independent.createdByAppMCP == nil && independent.messages.isEmpty && independent.draft.isEmpty && independent.activeRun == nil)
        #expect(independent.workspacePath == fixture.workspace.path)
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@Test(.timeLimit(.minutes(1))) func appMCPEngineHeldCatalogCannotApplyOldModelChoicesAfterRuntimeBindingChanges() async throws {
    let fixture = try await AppMCPFacadeFixture.make()
    do {
        let launched = try await fixture.perform(.launchThread(.init(projectID: fixture.projectID, creation: .init(title: "Idle catalog target"))))
        let targetID = try #require(launched["threadId"].string.flatMap(UUID.init(uuidString:)))
        let context = try await fixture.engine.appMCPContext(threadID: fixture.threadID)
        let gate = fixture.models
        await gate.holdNextRead()
        let selection = AppMCPModelSelection(instanceID: fixture.scope.providerInstanceID, model: "wire-model", options: ["reasoningEffort": .string("high")])
        let task = Task {
            try await fixture.engine.performScopedAppMCP(.configureThread(threadID: targetID, selection: selection), context: context)
        }
        try await appMCPFacadeEventually { await gate.isHeld }
        let changed = CodexRuntimeConfiguration(selection: .custom, executable: "/synthetic/other-codex", homeDirectory: "/synthetic/other-home")
        _ = try await fixture.engine.dispatch(.editThread(targetID, .codexRuntimeConfiguration(changed)))
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        let snapshot = await fixture.engine.current().snapshot
        let thread = try #require(snapshot.threads.first { $0.id == targetID })
        #expect(thread.codexRuntimeConfiguration == changed && thread.reasoningEffort == nil)
        let source = try #require(snapshot.threads.first { $0.id == fixture.threadID })
        #expect(source.activeRun?.configuration.codexRuntimeConfiguration == nil && source.activeRun?.id == fixture.runID)
        let closes = await fixture.peer.closeCount
        #expect(closes == 0, "Metadata scope retirement cannot close the original active stream.")
        let health = await fixture.engine.current()
        #expect(health.error == nil)
        await fixture.close()
    } catch { await fixture.models.release(); await fixture.close(); throw error }
}

@Test func appMCPIndependentSteeringPreservesDraftAttachmentsAndLegacyWireDefaultsWhileKeepingOneOriginalRun() throws {
    var snapshot = WorkspaceSnapshot()
    let project = WorkspaceProject(path: "/synthetic-independent-steering")
    var thread = CodingThread(project: project, model: "wire-model"); thread.checkpointPolicy = .disabled
    snapshot.projects = [project]; snapshot.threads = [thread]
    let now = Date(timeIntervalSince1970: 1_700_000_000), runtimeID = UUID(), incarnation = UUID()
    func reduce(_ command: EngineCommand, snapshot: WorkspaceSnapshot) throws -> WorkspaceSnapshot {
        try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: now).snapshot
    }
    snapshot = try reduce(.client(.submit(threadID: thread.id, text: "Opening run")), snapshot: snapshot)
    let runID = try #require(snapshot.threads[0].activeRun?.id)
    snapshot = try reduce(.runtimeOpened(threadID: thread.id, runID: runID, runtimeID: runtimeID), snapshot: snapshot)
    snapshot = try reduce(.provider(threadID: thread.id, runtimeID: runtimeID, event: .thread("native-session")), snapshot: snapshot)
    snapshot = try reduce(.provider(threadID: thread.id, runtimeID: runtimeID, event: .turn("native-turn")), snapshot: snapshot)
    let attachment = ChatAttachment(id: UUID(), name: "user.txt", mimeType: "text/plain", byteCount: 4, digest: String(repeating: "b", count: 64), fileExtension: "txt")
    snapshot.threads[0].draft = "Independent tool literal 工作"; snapshot.threads[0].draftAttachments = [attachment]
    thread = snapshot.threads[0]
    let run = try #require(thread.activeRun)
    let input = QueuedTurn(id: UUID(), text: thread.draft, configuration: run.configuration, createdAt: now, checkpointPolicy: .disabled)
    var operation = PromptSteeringOperation(threadID: thread.id, projectID: thread.projectID, sourceIncarnation: incarnation, runtimeID: runtimeID,
        runID: run.id, nativeThreadID: "native-session", nativeTurnID: "native-turn", input: input, messageID: "user-\(input.id)",
        configuration: run.configuration, createdAt: now, preservesComposer: true)
    let accepted = try reduce(.promptSteeringAccepted(operation), snapshot: snapshot)
    #expect(accepted.threads[0].draft == thread.draft && accepted.threads[0].draftAttachments == [attachment])
    #expect(accepted.threads[0].activeRun == run && accepted.threads[0].messages.last?.text == input.text && accepted.threads[0].messages.last?.attachments == nil)
    #expect(accepted.promptSteerings?.first?.preservesComposer == true)
    try WorkspaceJournal.validate(accepted)
    operation.preservesComposer = nil
    let legacy = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(operation))
    #expect(legacy.object?["preservesComposer"] == nil)
    #expect(throws: (any Error).self) { _ = try reduce(.promptSteeringAccepted(operation), snapshot: snapshot) }
}

private struct AppMCPFacadeFixture: Sendable {
    let root: URL, workspace: URL, database: URL
    let engine: WorkspaceEngine
    let peer: AppMCPFacadePeer
    let models: AppMCPFacadeModels
    let projectID: UUID, threadID: UUID, runID: UUID
    let scope: MCPInvocationScope
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-app-mcp-facade-" + UUID().uuidString).resolvingSymlinksInPath()
        let workspace = root.appendingPathComponent("Source"), database = root.appendingPathComponent("workspace.sqlite")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let project = WorkspaceProject(path: workspace.path)
        var thread = CodingThread(project: project, model: "wire-model"); thread.checkpointPolicy = .disabled
        let parentID = thread.id, peer = AppMCPFacadePeer(), models = AppMCPFacadeModels()
        let engine = try WorkspaceEngine(url: database, appMCPEnabled: true, providerFactory: { captured in
            if captured.id == parentID, captured.activeRun != nil { return peer }
            return AppMCPFacadePeer(models: models)
        }, identityResolver: { _ in nil })
        do {
            _ = try await engine.load(); _ = try await engine.dispatch(.addProject(project)); _ = try await engine.dispatch(.createThread(thread))
            _ = try await engine.dispatch(.submit(threadID: parentID, text: "Opening native run"))
            try await appMCPFacadeEventually {
                let current = await engine.current().snapshot.threads.first { $0.id == parentID }
                let configured = await peer.isConfigured
                return current?.activeRun?.nativeTurnID == "native-turn" && configured
            }
            let context = try await engine.appMCPContext(threadID: parentID)
            return .init(root: root, workspace: workspace, database: database, engine: engine, peer: peer, models: models,
                projectID: project.id, threadID: parentID, runID: try #require(context.runID), scope: context.scope)
        } catch { await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func perform(_ action: AppMCPAction) async throws -> JSONValue {
        let context = try await engine.appMCPContext(threadID: threadID)
        return try await engine.performScopedAppMCP(action, context: context)
    }
    func remove() throws { try FileManager.default.removeItem(at: root) }
    func close() async { await models.release(); await engine.shutdown(); try? remove() }
}
private actor AppMCPFacadePeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    nonisolated let supportsAppMCP = true
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let modelsSource: AppMCPFacadeModels?
    private var configured = false
    private(set) var sentTexts: [String] = []
    private(set) var closeCount = 0
    init(models: AppMCPFacadeModels? = nil) {
        let stream = AsyncStream<ProviderEvent>.makeStream(); events = stream.stream; continuation = stream.continuation; modelsSource = models
    }
    var isConfigured: Bool { configured }
    func configureAppMCP(_ connection: AppMCPConnection) { configured = true }
    func models() async -> [ProviderModel] { await modelsSource?.read() ?? [.init(id: "wire-model", name: "Synthetic model")] }
    func send(text: String, thread: CodingThread) {
        sentTexts.append(text)
        guard let runID = thread.activeRun?.id else { return }
        continuation.yield(.context(runID: runID, event: .thread("native-session")))
        continuation.yield(.context(runID: runID, event: .turn("native-turn")))
    }
    func interrupt() { continuation.yield(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) { continuation.yield(.approvalDismissed(request.id)) }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { continuation.yield(.approvalDismissed(request.id)) }
    func close() { closeCount += 1; continuation.finish() }
}
private actor AppMCPFacadeModels {
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isHeld: Bool { continuation != nil }
    func holdNextRead() { hold = true }
    func read() async -> [ProviderModel] {
        if hold { hold = false; await withCheckedContinuation { continuation = $0 } }
        return [.init(id: "wire-model", name: "Synthetic model", reasoningEfforts: [.init(id: "high", description: "High")])]
    }
    func release() { continuation?.resume(); continuation = nil }
}
private func appMCPFacadeEventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw AppMCPError(.unavailable) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
