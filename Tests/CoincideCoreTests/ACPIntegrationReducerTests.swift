import Foundation
import Testing
@testable import CoincideCore

private func integrationFixture(_ profile: ACPIntegration) -> RunHistoryFixture {
    var f = RunHistoryFixture(), agent = profile.configuration()
    agent.name = "Captured integration"
    f.snapshot.acpAgents = [agent]
    f.snapshot.threads[0].provider = .acp; f.snapshot.threads[0].acpAgent = agent; f.snapshot.threads[0].model = ""
    return f
}

@Test func copilotBackgroundEntitiesRetainTheirOriginalRunAcrossNextRunAndBaselineGate() async throws {
    var f = integrationFixture(.copilot); let first = UUID(), second = UUID()
    try f.submit("First", id: first); try f.connect(); try f.event(.thread("root-session"))
    let firstKey = ProviderEntityKey(sessionID: "child-session", type: "agent_message", id: "first")
    try f.event(.runEntity(runID: first, update: .content(firstKey, field: "content", value: .object(["type": .string("text"), "text": .string("Before ")]), annotation: nil)))
    f.snapshot.threads[0].checkpointPolicy = .automatic
    try f.submit("Second", id: second)
    try f.event(.completed(.idle), runID: first)
    #expect(f.thread.activeRun?.id == second)
    #expect(f.thread.runHistory?.last?.checkpoints?.providerReleased == false)
    let secondKey = ProviderEntityKey(sessionID: "child-session", type: "agent_message", id: "later")
    try f.event(.runEntity(runID: first, update: .content(firstKey, field: "content", value: .object(["type": .string("text"), "text": .string("after")]), annotation: nil)))
    try f.event(.runEntity(runID: first, update: .content(secondKey, field: "content", value: .object(["type": .string("text"), "text": .string("New child message")]), annotation: nil)))
    let children = f.thread.messages.filter { $0.providerEntity != nil }
    #expect(children.count == 2 && children[0].text == "Before after")
    #expect(children.allSatisfy { $0.runReference == .init(threadID: f.threadID, runID: first) })
    let saved = f.snapshot
    try f.event(.runEntity(runID: second, update: .patch(firstKey, .object(["content": .array([])]))))
    try f.event(.runEntity(runID: UUID(), update: .patch(firstKey, .object(["content": .array([])]))))
    try f.command(.provider(threadID: f.threadID, runtimeID: UUID(), event: .runEntity(runID: first, update: .patch(firstKey, .object([:])))))
    #expect(f.snapshot == saved)
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    _ = try await database.commit(f.snapshot, event: "owned-child", commandID: UUID())
    #expect(try await database.rebuildProjection().snapshot == f.snapshot)
}

@Test(arguments: ["session", "provider", "profile", "unreleased"])
func copilotOwnedEntitiesCannotReopenIneligibleRuns(_ mutation: String) throws {
    var f = integrationFixture(.copilot); let first = UUID()
    try f.submit("First", id: first); try f.connect(); try f.event(.thread("root-session"))
    try f.event(.completed(.idle), runID: first)
    switch mutation {
    case "session": f.snapshot.threads[0].providerThreadID = "another-session"
    case "provider": f.snapshot.threads[0].runHistory?[0].configuration.provider = .codex
    case "profile": f.snapshot.threads[0].runHistory?[0].configuration.acpAgent?.integration = nil
    default:
        let baseline = ThreadRunCheckpointAttempt(workspacePath: f.thread.workspacePath, now: f.date)
        f.snapshot.threads[0].runHistory?[0].checkpoints = .init(baseline: baseline, providerReleased: false)
    }
    let before = f.snapshot
    try f.event(.runEntity(runID: first, update: .patch(.init(sessionID: "child", type: "agent_message", id: "id"), .object([:]))))
    #expect(f.snapshot == before)
}

@Test func cursorSelectionCommandsKeepAllIDsInTheirDurableProviderEffect() throws {
    var f = integrationFixture(.cursor); try f.submit("First"); try f.connect()
    let request = ApprovalRequest(id: .string("local-id"), method: CursorACPMethod.question,
        params: CursorACPQuestionRequest(toolCallID: "tool", questions: [.init(id: "q", prompt: "Choose", options: [.init(id: "b", label: "same"), .init(id: "a", label: "same")], allowMultiple: true)]).parameters)
    try f.event(.approval(request))
    #expect(throws: (any Error).self) { try f.command(.client(.respond(threadID: f.threadID, requestID: request.id, response: .answers(["q": "same"])))) }
    #expect(throws: (any Error).self) { try f.command(.client(.respond(threadID: f.threadID, requestID: request.id, response: .selections(["q": ["invented"]])))) }
    let decision = try f.command(.client(.respond(threadID: f.threadID, requestID: request.id, response: .selections(["q": ["a", "b"]]))))
    let effect = try #require(decision.effects.first)
    #expect(try JSONDecoder().decode(PendingWorkspaceEffect.self, from: JSONEncoder().encode(effect)) == effect)
    guard case .providerRespond(_, _, let captured, .selections(let ids)) = effect.request else { Issue.record("Selectable answers lost their typed effect."); return }
    #expect(captured == request && ids == ["q": ["a", "b"]])
    #expect(f.thread.runtimeRequests.first?.responding == true)
}

@Test func acpEngineConnectionCheckUsesNeutralOwnedSessionWithoutJournalChanges() async throws {
    let fixture = try #require(Bundle.module.url(forResource: "cursor_acp_server", withExtension: "py", subdirectory: "Fixtures"))
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let audit = root.appendingPathComponent("methods"), agent = ACPIntegration.cursor.configuration()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { thread in
        #expect(thread.provider == .acp && thread.acpAgent == agent && thread.activeRun == nil && thread.providerThreadID == nil)
        #expect(thread.workspacePath == FileManager.default.homeDirectoryForCurrentUser.path)
        return try ACPSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture.path, "initialize", audit.path], cwd: root, integration: .cursor)
    }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load(); let before = await engine.current()
        let observed = try await engine.acpConnectionInfo(agent: agent)
        #expect(observed.agentName == "fixture-cursor")
        let after = await engine.current()
        #expect(after.snapshot == before.snapshot && after.sequence == before.sequence)
        #expect(try String(contentsOf: audit, encoding: .utf8) == "initialize\n")
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}
