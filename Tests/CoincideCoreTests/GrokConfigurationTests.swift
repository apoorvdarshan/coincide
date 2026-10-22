import Foundation
import Testing
@testable import CoincideCore

@Test func nativeGrokCapturedModeIsIndependentOfGenericEditApprovalAndOtherProviders() throws {
    let project = WorkspaceProject(path: "/tmp/native-grok-settings")
    var thread = CodingThread(project: project); thread.provider = .acp; thread.acpAgent = ACPIntegration.grok.configuration()
    thread.permission = .auto
    let captured = ProviderConfiguration(thread: thread)
    #expect(try captured.resolvedGrokRuntimeMode() == .auto && captured.permissionSummary == "Auto")
    thread.permission = .fullAccess
    #expect(captured.permission == .auto && ProviderConfiguration(thread: thread).effectiveGrokRuntimeMode == .fullAccess)
    #expect(try JSONDecoder().decode(ProviderConfiguration.self, from: JSONEncoder().encode(captured)) == captured)
    thread.permission = .autoAcceptEdits
    #expect(throws: (any Error).self) { try ProviderConfiguration(thread: thread).resolvedGrokRuntimeMode() }
}

@Test func nativeGrokQuestionNotesAreCapturedTogetherAndCannotAnswerAnotherFlavor() throws {
    let project = WorkspaceProject(path: "/tmp/native-grok-question-command")
    var thread = CodingThread(project: project); thread.provider = .acp; thread.acpAgent = ACPIntegration.grok.configuration()
    let runtime = UUID(); thread.runtimeID = runtime
    let params = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"sessionId":"native-grok","toolCallId":"call-question","mode":"default","questions":[{"id":"q","question":"Which?","options":[{"id":"left","label":"Exact native label","preview":"code preview"}]}]}"#.utf8))
    let request = ApprovalRequest(id: .string("local-question"), method: "x.ai/ask_user_question", params: params)
    thread.runtimeRequests = [.init(request: request, sessionScoped: true)]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let response = ProviderApprovalResponse.selectionsWithNotes(selections: ["q": ["left"]], notes: ["q": "Keep these notes"])
    let result = try WorkspaceDecision.make(.client(.respond(threadID: thread.id, requestID: request.id, response: response)), id: UUID(), snapshot: snapshot, now: Date())
    #expect(result.snapshot.threads[0].runtimeRequests[0].responding)
    #expect(result.effects.contains { effect in
        if case .providerSessionRespond(_, let id, let saved, let actual) = effect.request { return id == runtime && saved == request && actual == response }; return false
    })
    #expect(try JSONDecoder().decode(ProviderApprovalResponse.self, from: JSONEncoder().encode(response)) == response)
    snapshot.threads[0].acpAgent = ACPIntegration.cursor.configuration()
    #expect(throws: (any Error).self) { try WorkspaceDecision.make(.client(.respond(threadID: thread.id, requestID: request.id, response: response)), id: UUID(), snapshot: snapshot, now: Date()) }
}

@Test func nativeOpenCodeGenerationCanChangeOnlyBeforeConversationAndReplacesIdentity() throws {
    let project = WorkspaceProject(path: "/tmp/native-opencode-generations")
    var thread = CodingThread(project: project); thread.provider = .opencode; thread.openCodeConfiguration = .init()
    let original = thread.openCodeConfiguration?.runtimeIdentity
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let changed = try WorkspaceDecision.make(.client(.editThread(thread.id, .openCodeGeneration(.v1))), id: UUID(), snapshot: snapshot, now: Date())
    let native = changed.snapshot.threads[0].openCodeConfiguration
    #expect(native?.generation == .v1 && native?.runtimeIdentity != original && changed.closeRuntimes.contains(thread.id))
    snapshot = changed.snapshot; snapshot.threads[0].messages = [.init(role: .user, text: "Already authored")]
    #expect(throws: (any Error).self) { try WorkspaceDecision.make(.client(.editThread(thread.id, .openCodeGeneration(.v2))), id: UUID(), snapshot: snapshot, now: Date()) }
}

@Test func nativeGrokEngineReopensForCapturedQueuedPolicyInsteadOfFutureHeader() async throws {
    let directory = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: directory) }
    let registry = GrokConfigurationSessions()
    let engine = try WorkspaceEngine(url: directory.appendingPathComponent("grok.sqlite"),
        providerFactory: { registry.make($0) }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        let project = WorkspaceProject(path: directory.path), agent = ACPIntegration.grok.configuration()
        var thread = CodingThread(project: project); thread.provider = .acp; thread.acpAgent = agent
        thread.permission = .supervised; thread.checkpointPolicy = .disabled
        try await engine.dispatch(.saveACPAgent(agent)); try await engine.dispatch(.addProject(project)); try await engine.dispatch(.createThread(thread))
        try await engine.dispatch(.submit(threadID: thread.id, text: "Ask first"))
        try await grokConfigurationEventually { let current = await engine.current(); return registry.sessions.count == 1 && current.snapshot.threads[0].activeRun?.nativeTurnID != nil }
        let first = registry.sessions[0]
        try await engine.dispatch(.editThread(thread.id, .grokRuntimeMode(.fullAccess)))
        try await engine.dispatch(.submit(threadID: thread.id, text: "Captured always approve"))
        try await engine.dispatch(.editThread(thread.id, .grokRuntimeMode(.auto)))
        #expect(registry.sessions.count == 1)
        await first.finish()
        try await grokConfigurationEventually { let current = await engine.current(); return registry.sessions.count == 2 && current.snapshot.threads[0].activeRun?.configuration.permission == .fullAccess }
        let second = registry.sessions[1]
        #expect(await first.closed)
        let firstModes = await first.sentModes, secondModes = await second.sentModes
        #expect(firstModes == [.approvalRequired] && secondModes == [.fullAccess])
        let current = await engine.current().snapshot.threads[0]
        #expect(current.permission == PermissionMode.auto && current.activeRun?.configuration.permissionSummary == "Always approve")
        await second.finish()
        try await grokConfigurationEventually { (await engine.current()).snapshot.threads[0].activeRun == nil }
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}

private final class GrokConfigurationSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [GrokConfigurationSession] = []
    var sessions: [GrokConfigurationSession] { lock.withLock { values } }
    func make(_ thread: CodingThread) -> any ProviderSession {
        let session = GrokConfigurationSession()
        lock.withLock { values.append(session) }; return session
    }
}
private actor GrokConfigurationSession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    var sentModes: [GrokACPRuntimeMode] = []
    var closed = false
    init() { (events, continuation) = AsyncStream.makeStream() }
    func models() async throws -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) async throws {
        if let mode = try ProviderConfiguration(thread: thread).resolvedGrokRuntimeMode() { sentModes.append(mode) }
        continuation.yield(.thread("ses-grok-captured-policy")); continuation.yield(.turn("turn-\(UUID().uuidString)"))
    }
    func finish() { continuation.yield(.completed(.idle)) }
    func interrupt() async throws { continuation.yield(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) async throws {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {}
    func close() async { closed = true; continuation.finish() }
}
private func grokConfigurationEventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The synthetic Grok configuration transition did not finish.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
