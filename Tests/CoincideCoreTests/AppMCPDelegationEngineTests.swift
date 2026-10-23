import Foundation
import Testing
@testable import CoincideCore

private func delegationMCPControlsModel() -> ProviderModel {
    .init(id: "wire-model", name: "Controlled model", reasoningEfforts: [.init(id: "high", description: "High"), .init(id: "low", description: "Low")], defaultReasoningEffort: "low",
        codexServiceTiers: [.init(id: "priority", name: "Priority", description: "Native fixture tier"), .init(id: "ultrafast", name: "Ultrafast", description: "Native fixture tier")])
}

@Test(.timeLimit(.minutes(1))) func appMCPProviderControlsEngineCaptureTaskSpeedAndConfigureFutureOptionsWithoutChangingActiveInputOrDraft() async throws {
    let initial = try CodexServiceTier.setting("priority", in: nil), f = try await DelegationMCPFixture.make(options: initial)
    do {
        _ = try await f.engine.dispatch(.editThread(f.parentID, .codexServiceTier(model: delegationMCPControlsModel(), tier: "ultrafast")))
        let inherited = try await f.task(f.perform(.delegateTask(.init(task: "Captured tier", target: .init(model: "wire-model", options: ["reasoningEffort": .string("high")]), clientRequestID: "tier-capture"))))
        #expect(try CodexServiceTier.selected(in: inherited.request.configuration) == "priority")
        let cleared = try await f.task(f.perform(.delegateTask(.init(task: "Clear tier", target: .init(model: "wire-model", options: [:]), clientRequestID: "tier-clear"))))
        #expect(try CodexServiceTier.selected(in: cleared.request.configuration) == nil)
        await #expect(throws: AppMCPError(.invalidRequest)) { _ = try await f.perform(.delegateTask(.init(task: "Unavailable tier", target: .init(options: ["serviceTier": .string("missing")]), clientRequestID: "bad-tier"))) }
        let launched = try await f.perform(.launchThread(.init(projectID: f.project.id, creation: .init(title: "Control target"))))
        let targetID = try #require(launched["threadId"].string.flatMap(UUID.init(uuidString:)))
        _ = try await f.engine.dispatch(.editThread(targetID, .draft("Retain authored draft 工作\n")))
        _ = try await f.perform(.configureThread(threadID: targetID, selection: .init(model: "wire-model", options: ["serviceTier": .string("ultrafast")])))
        let configured = try #require(await f.engine.current().snapshot.threads.first { $0.id == targetID })
        #expect(configured.reasoningEffort == "high" && configured.draft == "Retain authored draft 工作\n")
        #expect(try CodexServiceTier.selected(in: .init(thread: configured)) == "ultrafast")
        _ = try await f.perform(.configureThread(threadID: targetID, selection: .init(model: "wire-model", options: [:])))
        let reset = try #require(await f.engine.current().snapshot.threads.first { $0.id == targetID })
        #expect(reset.reasoningEffort == "low" && reset.draft == configured.draft)
        #expect(try CodexServiceTier.selected(in: .init(thread: reset)) == nil)
        let parent = try #require(await f.engine.current().snapshot.threads.first { $0.id == f.parentID })
        let active = try #require(parent.activeRun)
        #expect(try CodexServiceTier.selected(in: active.configuration) == "priority")
        #expect(try CodexServiceTier.selected(in: .init(thread: parent)) == "ultrafast")
    } catch { await f.close(); throw error }; await f.close()
}

/// Registers a real Engine-owned app-tool scope, without an installed provider.
/// Reuses the task lane's controlled event/input peer and its bounded waits.
private actor DelegationMCPTestSession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    nonisolated let supportsAppMCP = true
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let peer: DelegatedTaskTestPeer
    private let id: UUID
    private let configuration: ProviderConfiguration
    private let modelProbe: DelegationMCPModelProbe
    init(peer: DelegatedTaskTestPeer, thread: CodingThread, modelProbe: DelegationMCPModelProbe) {
        self.peer = peer; id = thread.id; configuration = .init(thread: thread); self.modelProbe = modelProbe
        (events, continuation) = AsyncStream.makeStream()
    }
    func configureAppMCP(_ connection: AppMCPConnection) { }
    func models() async -> [ProviderModel] {
        await modelProbe.record(configuration)
        return [delegationMCPControlsModel()]
    }
    func send(text: String, thread: CodingThread) async throws { try await send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) async throws { try await peer.receive(input, thread: thread, events: continuation) }
    func interrupt() async { await peer.interrupt(id) }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() async { await peer.closed(id); continuation.finish() }
}
private actor DelegationMCPModelProbe {
    private(set) var captures: [ProviderConfiguration] = []
    func record(_ value: ProviderConfiguration) { captures.append(value) }
}
private struct DelegationMCPFixture: Sendable {
    let root: URL, database: URL
    let engine: WorkspaceEngine, peer: DelegatedTaskTestPeer
    let modelProbe: DelegationMCPModelProbe
    let project: WorkspaceProject, parentID: UUID
    static func make(options: [String: JSONValue]? = nil) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-mcp-delegation-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let database = root.appendingPathComponent("workspace.sqlite"), peer = DelegatedTaskTestPeer(), project = WorkspaceProject(path: root.path), modelProbe = DelegationMCPModelProbe()
        let engine = try WorkspaceEngine(url: database, appMCPEnabled: true,
            providerFactory: { DelegationMCPTestSession(peer: peer, thread: $0, modelProbe: modelProbe) }, identityResolver: { _ in nil })
        do {
            _ = try await engine.load(); var parent = CodingThread(project: project, model: "wire-model")
            parent.checkpointPolicy = .disabled; parent.reasoningEffort = "high"; parent.permission = .supervised
            parent.agentConfiguration = options
            _ = try await engine.dispatch(.addProjectWithThread(project: project, thread: parent))
            _ = try await engine.dispatch(.submit(threadID: parent.id, text: "PRIVATE-PARENT-HISTORY-MUST-NOT-BE-COPIED"))
            try await taskEventually {
                let count = await peer.inputs[parent.id]?.count, turn = await engine.current().snapshot.threads.first(where: { $0.id == parent.id })?.activeRun?.nativeTurnID
                return count == 1 && turn != nil
            }
            _ = try await engine.appMCPContext(threadID: parent.id)
            return .init(root: root, database: database, engine: engine, peer: peer, modelProbe: modelProbe, project: project, parentID: parent.id)
        } catch { await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func perform(_ action: AppMCPAction, context: AppMCPContext? = nil) async throws -> JSONValue {
        let live: AppMCPContext
        if let context { live = context } else { live = try await engine.appMCPContext(threadID: parentID) }
        return try await engine.performScopedAppMCP(action, context: live)
    }
    func task(_ result: JSONValue) async throws -> DelegatedTask {
        let id = try #require(result["taskId"].string.flatMap(UUID.init(uuidString:)))
        return try #require(await engine.current().snapshot.delegatedTasks?.first { $0.id == id })
    }
    func child(_ task: DelegatedTask) async throws -> CodingThread { try #require(await engine.current().snapshot.threads.first { $0.id == task.childThreadID }) }
    func close() async { await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1))) func appMCPDelegationEngineRetriesOriginalIntentOncePreservesParentDraftAndRefusesChangedOrStaleCaller() async throws {
    let f = try await DelegationMCPFixture.make()
    do {
        let context = try await f.engine.appMCPContext(threadID: f.parentID), literal = "  Self-contained task 工作 e\u{301}\n$HOME remains literal  "
        let attachment = ChatAttachment(id: UUID(), name: "unsent.txt", mimeType: "text/plain", byteCount: 4, digest: String(repeating: "a", count: 64), fileExtension: "txt")
        _ = try await f.engine.dispatch(.editThread(f.parentID, .draft("Latest parent draft")))
        _ = try await f.engine.dispatch(.addAttachments(threadID: f.parentID, attachments: [attachment]))
        _ = try await f.engine.dispatch(.editThread(f.parentID, .model("future-header-model")))
        let intent = AppMCPDelegation(task: literal, clientRequestID: "stable-round")
        let first = try await f.perform(.delegateTask(intent)), task = try await f.task(first)
        try await taskEventually { await f.peer.inputs[task.childThreadID]?.count == 1 }
        let again = try await f.perform(.delegateTask(.init(task: literal, timeoutMilliseconds: 1, clientRequestID: "stable-round")))
        #expect(first["taskId"] == again["taskId"] && first["childThreadId"] == again["childThreadId"] && first["childRunId"] == again["childRunId"])
        let child = try await f.child(task), parent = try #require(await f.engine.current().snapshot.threads.first { $0.id == f.parentID })
        #expect(child.model == "wire-model" && child.reasoningEffort == "high" && child.permission == .supervised)
        #expect(child.workspacePath == f.root.path && child.providerThreadID != parent.providerThreadID)
        #expect(child.messages.filter { $0.role == .user }.map(\.text) == [literal] && child.draftAttachments.isEmpty)
        #expect(!child.messages.contains { $0.text.contains("PRIVATE-PARENT-HISTORY-MUST-NOT-BE-COPIED") })
        #expect(parent.draft == "Latest parent draft" && parent.draftAttachments == [attachment] && parent.activeRun?.id == context.runID)
        await #expect(throws: AppMCPError(.invalidRequest)) { _ = try await f.perform(.delegateTask(.init(task: literal + " changed", clientRequestID: "stable-round"))) }
        let inputs = await f.peer.inputs[task.childThreadID]; #expect(inputs == [literal])
        _ = try await f.engine.dispatch(.interrupt(threadID: f.parentID))
        await #expect(throws: AppMCPError(.staleCaller)) { _ = try await f.perform(.delegateTask(.init(task: "Must not run", clientRequestID: "after-stop")), context: context) }
        #expect(await f.engine.current().snapshot.delegatedTasks?.count == 1)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func appMCPDelegationEngineUsesRegisteredProfilesAndDistinguishesInheritedAndExplicitlyClearedOptions() async throws {
    let f = try await DelegationMCPFixture.make()
    do {
        let inherited = try await f.task(f.perform(.delegateTask(.init(task: "Inherited active options", target: .init(model: "wire-model"), clientRequestID: "inherit"))))
        let cleared = try await f.task(f.perform(.delegateTask(.init(task: "Clear active options", target: .init(model: "wire-model", options: [:]), clientRequestID: "clear"))))
        #expect(inherited.request.configuration.reasoningEffort == "high" && cleared.request.configuration.reasoningEffort == nil)
        var profile = CodingThread(project: f.project, model: "wire-model"); profile.checkpointPolicy = .disabled
        let binding = CodexRuntimeConfiguration(instanceID: UUID(), selection: .custom, executable: "/offline/other-codex", homeDirectory: f.root.appendingPathComponent("registered-home").path)
        profile.codexRuntimeConfiguration = binding; profile.reasoningEffort = "low"
        _ = try await f.engine.dispatch(.createThread(profile))
        let capabilities = try await f.perform(.capabilities(search: nil)), providers = try #require(capabilities["providers"].array)
        #expect(capabilities["features"]["appOwnedSubagents"] == .bool(true))
        #expect(providers.count == 2 && providers.allSatisfy { $0["canRunChildTask"] == .bool(true) && $0["canRunCrossProviderChildTask"] == .bool(true) })
        #expect(Set(providers.compactMap { $0["providerInstanceId"].string }) == Set([CodexRuntimeConfiguration.defaultInstanceID.uuidString.lowercased(), binding.instanceID.uuidString.lowercased()]))
        let cross = try await f.task(f.perform(.delegateTask(.init(task: "Exact registered profile", target: .init(instanceID: binding.instanceID, model: "wire-model", options: ["reasoningEffort": .string("high")]), clientRequestID: "registered"))))
        #expect(cross.request.configuration.codexRuntimeConfiguration == binding && cross.request.configuration.reasoningEffort == "high")
        #expect(cross.request.configurationSourceThreadID == profile.id && cross.request.expectedConfigurationSource == ProviderConfiguration(thread: profile))
        #expect(cross.request.configuration.workspacePath == f.root.path && cross.request.configuration.nativeThreadID == nil)
        await #expect(throws: AppMCPError(.notFound)) { _ = try await f.perform(.delegateTask(.init(task: "Unknown profile", target: .init(instanceID: UUID())))) }
        await #expect(throws: AppMCPError(.permissionDenied)) { _ = try await f.perform(.delegateTask(.init(task: "Cannot broaden permission", permission: .fullAccess))) }
        await #expect(throws: AppMCPError(.unsupported)) { _ = try await f.perform(.delegateTask(.init(task: "Cannot inject launch options", target: .init(options: ["executable": .string("/foreign")])))) }
        #expect(await f.engine.current().snapshot.delegatedTasks?.count == 3)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func appMCPDelegationEnginePublishesImmutableOriginalResultWithParentScopedFullContextAfterLaterChildRun() async throws {
    let f = try await DelegationMCPFixture.make()
    do {
        let accepted = try await f.perform(.delegateTask(.init(task: "Capture immutable result", clientRequestID: "result"))), task = try await f.task(accepted)
        try await taskEventually { await f.peer.inputs[task.childThreadID]?.count == 1 }
        let original = "Original result 工作🧪\n" + String(repeating: "q", count: 1_200_000)
        try await f.peer.complete(task.childThreadID, text: original)
        try await taskEventually { await f.engine.current().snapshot.delegatedTasks?.first(where: { $0.id == task.id })?.result != nil }
        let status = try await f.perform(.delegatedTaskStatus(taskID: task.id)), saved = try #require(await f.engine.current().snapshot.delegatedTasks?.first { $0.id == task.id }?.result)
        #expect(status["summaryTruncated"] == .bool(true) && status["summaryTotalBytes"] == .number(Double(original.utf8.count)))
        #expect(status["summary"].string?.utf8.count == 32_768 && status["resultContextTransferId"] == .string(saved.contextTransferID.uuidString.lowercased()))
        let context = try await f.engine.appMCPContext(threadID: f.parentID)
        let arguments: JSONValue = .object(["transferId": .string(saved.contextTransferID.uuidString),
            "itemId": .string("task-result:" + saved.contextTransferID.uuidString.lowercased()), "maxBytesPerItem": .number(65_536)])
        let first = try await f.engine.appMCPContextRead(arguments, context: context)
        #expect(first["archiveDigest"] == .string(saved.digest))
        let tools = AppMCPTools(client: .init(read: { try await f.engine.appMCPView($0) },
            perform: { try await f.engine.performScopedAppMCP($0, context: $1) },
            contextRead: { try await f.engine.appMCPContextRead($0, context: $1) }))
        let wireStatus = await tools.call(name: "task_status", arguments: .object(["taskId": .string(task.id.uuidString)]), context: context)
        #expect(!wireStatus.isError && wireStatus.structuredContent?["summaryTruncated"] == .bool(true))
        #expect(try JSONEncoder().encode(wireStatus.json).count < MCPProtocol.maximumBodyBytes)
        var assembled = Data(), offset = 0, pages = 0
        while true {
            var fields = try #require(arguments.object); fields["textOffset"] = .number(Double(offset))
            let response = await tools.call(name: "t3_context_read", arguments: .object(fields), context: context)
            let byteCount = try JSONEncoder().encode(response.json).count
            #expect(!response.isError && byteCount < MCPProtocol.maximumBodyBytes)
            let row = try #require(response.structuredContent?["items"].array?.first), text = try #require(row["text"].string)
            #expect(row["textOffset"] == .number(Double(offset)))
            assembled.append(contentsOf: text.utf8); pages += 1
            if row["nextTextOffset"] == .null { break }
            guard case .number(let next) = row["nextTextOffset"], next > Double(offset) else { throw CoincideError("Invalid immutable-result continuation") }
            offset = Int(next)
            guard pages < 32 else { throw CoincideError("The bounded immutable-result reader did not finish") }
        }
        #expect(pages > 1 && assembled == Data(original.utf8))
        _ = try await f.engine.dispatch(.submit(threadID: task.childThreadID, text: "Later explicit user round"))
        try await taskEventually { await f.peer.inputs[task.childThreadID]?.count == 2 }
        try await f.peer.complete(task.childThreadID, text: "Later result must remain separate")
        try await taskEventually { await f.engine.current().snapshot.delegatedTasks?.contains(where: { $0.childThreadID == task.childThreadID && $0.isFollowup == true && $0.result != nil }) == true }
        let later = try await f.perform(.delegatedTaskStatus(taskID: task.id))
        #expect(later["summary"] == status["summary"] && later["resultContextTransferId"] == status["resultContextTransferId"])
        #expect(later["latestTerminalSummary"] == .string("Later result must remain separate"))
        let second = try await f.engine.appMCPContextRead(arguments, context: context); #expect(second == first)
        var other = CodingThread(project: f.project, model: "wire-model"); other.checkpointPolicy = .disabled
        _ = try await f.engine.dispatch(.createThread(other)); _ = try await f.engine.dispatch(.submit(threadID: other.id, text: "Unrelated active parent"))
        try await taskEventually { await f.peer.inputs[other.id]?.count == 1 }
        let foreign = try await f.engine.appMCPContext(threadID: other.id)
        await #expect(throws: AppMCPError(.staleCaller)) { _ = try await f.engine.appMCPContextRead(arguments, context: foreign) }
        let source = context.scope
        let contextOnly = AppMCPContext(scope: .init(sessionID: source.sessionID, threadID: source.threadID, projectID: source.projectID, provider: source.provider,
            runtimeID: source.runtimeID, incarnation: source.incarnation, providerInstanceID: source.providerInstanceID, workspacePath: source.workspacePath,
            permission: source.permission, capabilities: [.contextRead]), runID: context.runID, configuration: context.configuration)
        await #expect(throws: AppMCPError(.staleCaller)) { _ = try await f.engine.appMCPContextRead(arguments, context: contextOnly) }
        #expect(await f.engine.current().snapshot.delegatedTasks?.first(where: { $0.id == task.id })?.result == saved)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func appMCPDelegationEngineCatalogUsesTheActiveCapturedModelRatherThanTheFutureParentHeader() async throws {
    let f = try await DelegationMCPFixture.make()
    do {
        let context = try await f.engine.appMCPContext(threadID: f.parentID)
        _ = try await f.engine.dispatch(.editThread(f.parentID, .model("future-header-model")))
        let current = try #require(await f.engine.current().snapshot.threads.first { $0.id == f.parentID })
        #expect(current.model == "future-header-model" && context.configuration.model == "wire-model")
        let before = await f.modelProbe.captures.count
        let result = try await f.perform(.delegateTask(.init(task: "Captured catalog only", target: .init(model: "wire-model", options: ["reasoningEffort": .string("high")]), clientRequestID: "captured-catalog")))
        let task = try await f.task(result), captures = await f.modelProbe.captures
        #expect(captures.count == before + 1)
        let metadata = try #require(captures.last)
        #expect(metadata.model == context.configuration.model && metadata.reasoningEffort == context.configuration.reasoningEffort)
        #expect(metadata.codexRuntimeConfiguration == context.configuration.codexRuntimeConfiguration && metadata.nativeThreadID == nil)
        #expect(task.request.configuration.model == "wire-model" && task.request.configuration.reasoningEffort == "high")
        #expect(await f.engine.current().snapshot.threads.first(where: { $0.id == f.parentID })?.model == "future-header-model")
    } catch { await f.close(); throw error }; await f.close()
}
