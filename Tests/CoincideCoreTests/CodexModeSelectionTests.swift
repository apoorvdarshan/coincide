import Foundation
import Testing
@testable import CoincideCore

private func modeTestRow() -> ProviderModel {
    .init(id: "native-wire-model", name: "Native model", reasoningEfforts: [.init(id: "high", description: "Native effort")],
          defaultReasoningEffort: "high", codexInteractionModes: [.default, .plan])
}
private func modeTestSnapshot() -> WorkspaceSnapshot {
    let project = WorkspaceProject(path: "/private/offline-mode-café")
    var thread = CodingThread(project: project, model: modeTestRow().id)
    thread.draft = "Keep literal e\u{301}\n "; thread.permission = .fullAccess; thread.reasoningEffort = "high"
    thread.checkpointPolicy = .disabled
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]; return snapshot
}

@Test(arguments: ["birth", "project", "workspace-bytes", "model", "effort", "profile", "permission", "mode"])
func codexModeCapturedMenuRefusesStaleConversationWithoutChangingDraftOrPermissions(change: String) throws {
    var snapshot = modeTestSnapshot()
    let row = modeTestRow(), original = snapshot.threads[0], selection = CodexModeSelection(thread: original, mode: .plan, model: row)
    switch change {
    case "birth": snapshot.threads[0].createdAt = original.createdAt.addingTimeInterval(1)
    case "project": snapshot.threads[0].projectID = UUID()
    case "workspace-bytes":
        let decomposed = original.workspacePath.decomposedStringWithCanonicalMapping
        let alternate = original.workspacePath.utf8.elementsEqual(decomposed.utf8) ? original.workspacePath.precomposedStringWithCanonicalMapping : decomposed
        try #require(original.workspacePath == alternate && !original.workspacePath.utf8.elementsEqual(alternate.utf8))
        snapshot.threads[0].workspacePath = alternate
    case "model": snapshot.threads[0].model = "other-model"
    case "effort": snapshot.threads[0].reasoningEffort = "low"
    case "profile": snapshot.threads[0].codexRuntimeConfiguration = .init(homeDirectory: "/private/new-profile")
    case "permission": snapshot.threads[0].permission = .supervised
    default: snapshot.threads[0].agentModeID = "default"
    }
    let before = snapshot
    #expect(!selection.matches(snapshot.threads[0]))
    #expect(throws: WorkspaceCommandError.self) {
        _ = try WorkspaceDecision.make(.client(.editThread(original.id, .codexInteractionMode(selection))), id: UUID(), snapshot: before, now: .now)
    }
    #expect(snapshot == before && snapshot.threads[0].draft.utf8.elementsEqual(original.draft.utf8))
}

@Test func codexModeSelectionUsesNativeProfileCapabilityAndKeepsActiveCapturedModeAndQueue() throws {
    var snapshot = modeTestSnapshot(), thread = snapshot.threads[0]
    let now = Date(), runID = UUID()
    thread.agentModeID = "plan"
    let captured = ProviderConfiguration(thread: thread)
    let run = ActiveRun(id: runID, configuration: captured, startedAt: now)
    thread.activeRun = run; thread.state = .running
    var user = ChatMessage(id: "owned-input", role: .user, text: "Original turn")
    user.createdAt = now; user.runReference = .init(threadID: thread.id, runID: runID)
    thread.messages = [user]
    var record = ThreadRunRecord(run: run, origin: .user, userMessageID: user.id)
    record.messageAttributionVersion = 1
    thread.runHistory = [record]
    thread.queuedTurns = [.init(id: UUID(), text: "Original queue", configuration: captured, createdAt: now)]
    snapshot.threads[0] = thread
    let selection = CodexModeSelection(thread: thread, mode: .default, model: modeTestRow())
    let decision = try WorkspaceDecision.make(.client(.editThread(thread.id, .codexInteractionMode(selection))), id: UUID(), snapshot: snapshot, now: now)
    let changed = try #require(decision.snapshot.threads.first)
    #expect(changed.agentModeID == "default" && changed.permission == .fullAccess)
    #expect(changed.activeRun?.configuration == captured && changed.queuedTurns == thread.queuedTurns)
    #expect(changed.draft.utf8.elementsEqual(thread.draft.utf8) && changed.messages == thread.messages)
    #expect(decision.effects.isEmpty && decision.closeRuntimes.isEmpty)
    let encoded = try JSONEncoder().encode(selection)
    let decoded = try JSONDecoder().decode(CodexModeSelection.self, from: encoded)
    #expect(decoded == selection)
    let object = try JSONDecoder().decode(JSONValue.self, from: encoded)
    #expect(object["storage"] == .null && object["threadID"] == .string(thread.id.uuidString))
}

@Test func codexModeAvailabilityDoesNotInventCapabilitiesFromModelNamesAndLegacyCodecsStayUnavailable() throws {
    let thread = modeTestSnapshot().threads[0]
    #expect(!CodexModeSelection.isAvailable(for: thread))
    let unsupported = ProviderModel(id: thread.model, name: "A known-looking Codex name")
    #expect(!CodexModeSelection.isAvailable(for: thread, model: unsupported))
    let supported = modeTestRow()
    #expect(CodexModeSelection.isAvailable(for: thread, model: supported))
    let legacy = try JSONDecoder().decode(ProviderModel.self, from: Data("{\"id\":\"native-wire-model\",\"name\":\"Legacy\"}".utf8))
    #expect(legacy.codexInteractionModes == nil)
    let roundtrip = try JSONDecoder().decode(ProviderModel.self, from: JSONEncoder().encode(supported))
    #expect(roundtrip.codexInteractionModes == [.default, .plan])
    let selection = CodexModeSelection(thread: thread, mode: .plan)
    var snapshot = modeTestSnapshot(); snapshot.threads = [thread]
    #expect(throws: WorkspaceCommandError.self) { _ = try WorkspaceDecision.make(.client(.editThread(thread.id, .codexInteractionMode(selection))), id: UUID(), snapshot: snapshot, now: .now) }
}
