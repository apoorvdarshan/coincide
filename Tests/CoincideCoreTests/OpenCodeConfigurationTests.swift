import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private struct NativeOpenCodeConfigurationFixture {
    var snapshot = WorkspaceSnapshot()
    let runtimeID = UUID()
    var threadID: UUID { snapshot.threads[0].id }
    var thread: CodingThread { snapshot.threads[0] }
    init(path: String = "/tmp/coincide-native-opencode-configuration") throws {
        let project = WorkspaceProject(path: path)
        var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
        snapshot.projects = [project]; snapshot.threads = [thread]
        try edit(.provider(.opencode))
    }
    @discardableResult mutating func apply(_ command: EngineCommand) throws -> WorkspaceDecision {
        let result = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: Date())
        snapshot = result.snapshot; return result
    }
    @discardableResult mutating func edit(_ edit: ThreadEdit) throws -> WorkspaceDecision { try apply(.client(.editThread(threadID, edit))) }
    mutating func start() throws {
        try apply(.client(.submit(threadID: threadID, text: "Native configuration first input")))
        let run = try #require(thread.activeRun)
        try apply(.runtimeOpened(threadID: threadID, runID: run.id, runtimeID: runtimeID))
        try apply(.provider(threadID: threadID, runtimeID: runtimeID, event: .thread("ses_native_config")))
    }
}

private func nativeOpenCodeModel(_ provider: String = "provider/a", _ model: String = "model/b") -> ProviderModel {
    let wire = OpenCodeModelSelection(providerID: provider, id: model)
    return .init(id: wire.catalogID, name: "Native advertised model", openCodeSelection: wire, openCodeVariants: ["balanced", "deep"])
}

@Test func nativeOpenCodeConfigurationPreservesOpaqueWireIDsAndDistinctRuntimeIdentity() throws {
    let a = OpenCodeModelSelection(providerID: "a/b", id: "c", variant: "deep"), b = OpenCodeModelSelection(providerID: "a", id: "b/c")
    #expect(a.catalogID != b.catalogID)
    #expect(a.catalogID == OpenCodeModelSelection(providerID: "a/b", id: "c").catalogID)
    let configuration = OpenCodeConfiguration(model: a, agentID: "native-agent-id")
    let changed = configuration.selecting(model: b).selecting(agentID: "plan")
    #expect(configuration.runtimeIdentity == changed.runtimeIdentity)
    #expect(configuration.runtimeIdentity != OpenCodeConfiguration(model: a).runtimeIdentity)
    #expect(configuration.model == a && changed.model == b && configuration.agentID == "native-agent-id")
    #expect(try JSONDecoder().decode(OpenCodeConfiguration.self, from: JSONEncoder().encode(configuration)) == configuration)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(OpenCodeConfiguration.self, from: Data(#"{"instanceID":"BFA04E9F-AFE1-4B33-ACD1-219B0D9A09A7","generation":"v3","executable":"opencode","agentID":"build"}"#.utf8)) }
}

@Test(arguments: ["", " ", "opencode\nserve", "../opencode", "./opencode", "https://example.test/opencode", "TOKEN=value", "opencode serve"])
func nativeOpenCodeConfigurationRejectsInvalidInvocationWithoutExposingIt(_ executable: String) throws {
    let configuration = OpenCodeConfiguration(executable: executable)
    do { try configuration.validate(); Issue.record("Invalid native invocation accepted") }
    catch { #expect(error.localizedDescription == OpenCodeConfiguration.invalid().localizedDescription) }
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(OpenCodeConfiguration())) as? [String: Any])
    object["executable"] = executable
    #expect(throws: (any Error).self) { try JSONDecoder().decode(OpenCodeConfiguration.self, from: JSONSerialization.data(withJSONObject: object)) }
}

@Test func nativeOpenCodeQueueCapturesModelVariantAgentAndPermissionAcrossFutureHeaderEdits() throws {
    var f = try NativeOpenCodeConfigurationFixture(); let a = nativeOpenCodeModel(), b = nativeOpenCodeModel("other", "other/model")
    try f.edit(.openCodeModel(a)); try f.edit(.openCodeVariant(model: a, variant: "deep")); try f.start()
    let running = try #require(f.thread.activeRun), original = f.thread.openCodeConfiguration
    try f.edit(.openCodeModel(b)); try f.edit(.openCodeAgent("plan")); try f.edit(.permission(.autoAcceptEdits))
    try f.apply(.client(.submit(threadID: f.threadID, text: "Captured native queue input")))
    let captured = try #require(f.thread.queuedTurns.first)
    try f.edit(.openCodeModel(a)); try f.edit(.openCodeAgent("build")); try f.edit(.permission(.supervised))
    #expect(f.thread.activeRun == running && running.configuration.openCodeConfiguration == original)
    #expect(captured.configuration.openCodeConfiguration?.model == b.openCodeSelection)
    #expect(captured.configuration.openCodeConfiguration?.agentID == "plan" && captured.configuration.permission == .autoAcceptEdits)
    #expect(captured.configuration.reasoningEffort == nil && captured.configuration.acpAgent == nil)
    let finished = try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .completed(.idle)))
    #expect(f.thread.activeRun?.id == captured.id)
    #expect(f.thread.activeRun?.configuration.openCodeConfiguration == captured.configuration.openCodeConfiguration)
    #expect(f.thread.openCodeConfiguration?.model == a.openCodeSelection && f.thread.openCodeConfiguration?.agentID == "build")
    #expect(finished.effects.contains { if case .providerStart(_, let id, let configuration, _, _) = $0.request { return id == captured.id && configuration.openCodeConfiguration == captured.configuration.openCodeConfiguration }; return false })
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func nativeOpenCodeSelectionsRejectUntypedModelsStaleVariantsAndMixedProviderConfiguration() throws {
    var f = try NativeOpenCodeConfigurationFixture(); let model = nativeOpenCodeModel()
    try f.edit(.openCodeModel(model)); let before = f.snapshot
    #expect(throws: (any Error).self) { try f.edit(.model("provider/a/model/b")) }
    #expect(throws: (any Error).self) { try f.edit(.openCodeVariant(model: model, variant: "not-advertised")) }
    #expect(throws: (any Error).self) { try f.edit(.openCodeModel(.init(id: "guessed", name: "Missing wire IDs"))) }
    #expect(f.snapshot == before)
    var invalid = f.snapshot; invalid.threads[0].model = "wrong-menu-key"
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(invalid) }
    invalid = f.snapshot; invalid.threads[0].provider = .claude
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(invalid) }
    try f.edit(.openCodeModel(nil)); #expect(f.thread.model.isEmpty && f.thread.openCodeConfiguration?.model == nil)
    try f.edit(.provider(.claude)); #expect(f.thread.openCodeConfiguration == nil && f.thread.acpAgent == nil)
}

@Test(arguments: [25, 26, 27, 28, 29, 30, 31])
func nativeOpenCodeStorage32MigratesPriorVersionsReopensAndKeepsACPConversationsUnchanged(_ priorVersion: Int) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("native-configuration.sqlite")
    var raw: OpaquePointer?; #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    #expect(sqlite3_exec(raw, "PRAGMA user_version=\(priorVersion)", nil, nil, nil) == SQLITE_OK); sqlite3_close(raw)
    var f = try NativeOpenCodeConfigurationFixture(path: root.path); try f.edit(.openCodeModel(nativeOpenCodeModel())); try f.start()
    var acp = CodingThread(project: f.snapshot.projects[0]); acp.provider = .acp
    acp.acpAgent = .init(name: "Existing OpenCode ACP", executable: "opencode", arguments: ["acp"])
    acp.acpAgent?.experimentalV2 = true
    f.snapshot.acpAgents = [acp.acpAgent!]; f.snapshot.threads.append(acp)
    let database = try WorkspaceDatabase(url: url)
    _ = try await database.commit(f.snapshot, event: "native.opencode.fixture", commandID: UUID())
    let reopened = try await WorkspaceDatabase(url: url).load()
    #expect(reopened == f.snapshot && reopened.threads[1] == acp)
    #expect(try await database.rebuildProjection().snapshot == f.snapshot)
    #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    var statement: OpaquePointer?; #expect(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 37)
    sqlite3_finalize(statement); sqlite3_close(raw)
    #expect(try JSONDecoder().decode(CodingThread.self, from: JSONEncoder().encode(acp)).openCodeConfiguration == nil)
}

@Test func nativeOpenCodeOriginalRunEntitiesRemainWithTheirOwnerAfterAnotherRunStarts() throws {
    var f = try NativeOpenCodeConfigurationFixture(); try f.start(); let owner = try #require(f.thread.activeRun?.id)
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .completed(.idle)))
    try f.apply(.client(.submit(threadID: f.threadID, text: "Another foreground native input")))
    let key = ProviderEntityKey(sessionID: "ses_owned_child", type: "agent_message", id: "msg_child_block")
    let update = ProviderEntityUpdate.patch(key, .object(["content": .array([.object(["type": .string("text"), "text": .string("Late child output")])])]))
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .runEntity(runID: owner, update: update)))
    #expect(f.thread.messages.last?.runReference?.runID == owner && f.thread.activeRun?.id != owner)
    let count = f.thread.messages.count
    try f.apply(.provider(threadID: f.threadID, runtimeID: UUID(), event: .runEntity(runID: owner, update: update)))
    #expect(f.thread.messages.count == count)
    var record = try #require(f.snapshot.threads[0].runHistory?.first)
    record.configuration.openCodeConfiguration = OpenCodeConfiguration()
    f.snapshot.threads[0].runHistory?[0] = record
    let unrelated = ProviderEntityUpdate.patch(.init(sessionID: "ses_other", type: "agent_message", id: "msg_other"), .object(["content": .array([])]))
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .runEntity(runID: owner, update: unrelated)))
    #expect(f.thread.messages.count == count)
}

@Test func nativeOpenCodeReducerPreservesTypedFormAnswersAndPermissionScopes() throws {
    var f = try NativeOpenCodeConfigurationFixture(); try f.start()
    let form = try OpenCodeV2Protocol.form(.object(["id": .string("frm_config"), "sessionID": .string("ses_native_config"), "title": .string("Choose"),
        "fields": .array([.object(["key": .string("choice"), "type": .string("multiselect"), "required": .bool(true),
            "options": .array([.object(["value": .string("native-a"), "label": .string("Same label")]), .object(["value": .string("native-b"), "label": .string("Same label")])])])])]))
    let request = form.approval(localID: .string("local-form-config"))
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .approval(request)))
    let before = f.snapshot
    #expect(throws: (any Error).self) { try f.apply(.client(.respond(threadID: f.threadID, requestID: request.id, response: .selections(["choice": ["Same label"]])))) }
    #expect(f.snapshot == before)
    let result = try f.apply(.client(.respond(threadID: f.threadID, requestID: request.id, response: .selections(["choice": ["native-b", "native-a"]]))))
    #expect(result.effects.contains { if case .providerRespond(_, _, let captured, .selections(let values)) = $0.request { return captured == request && values["choice"] == ["native-b", "native-a"] }; return false })
    var cancelled = try NativeOpenCodeConfigurationFixture(); try cancelled.start()
    try cancelled.apply(.provider(threadID: cancelled.threadID, runtimeID: cancelled.runtimeID, event: .approval(request)))
    #expect(try cancelled.apply(.client(.respond(threadID: cancelled.threadID, requestID: request.id, response: .decision(false)))).effects.count == 1)
    let permission = try OpenCodeV2Protocol.permission(.object(["id": .string("per_config"), "sessionID": .string("ses_native_config"), "action": .string("shell"), "resources": .array([.string("printf test")]), "save": .array([.string("printf test")])]))
        .approval(localID: .string("local-permission-config"))
    #expect(permission.title.contains("shell") && permission.detail == "printf test")
    #expect(permission.params["options"].array?.first(where: { $0["optionId"] == .string("always") })?["name"].string?.contains("workspace") == true)
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .approval(permission)))
    #expect(try f.apply(.client(.respond(threadID: f.threadID, requestID: permission.id, response: .option("once")))).effects.count == 1)
}

@Test(arguments: [ThreadState.idle, .failed])
func nativeOpenCodeCompletedRootPreservesOwnedBackgroundRequestsAndHealthyRuntime(_ state: ThreadState) throws {
    var f = try NativeOpenCodeConfigurationFixture(); try f.start()
    let owner = try #require(f.thread.activeRun?.id)
    let permission = try OpenCodeV2Protocol.permission(.object(["id": .string("per_background"), "sessionID": .string("ses_child"),
        "action": .string("shell"), "resources": .array([.string("printf child")]), "save": .array([])]))
        .approval(localID: .string("background-request"))
    let foreground = ApprovalRequest(id: .string("foreground-request"), method: "opencode/permission", params: .object([:]))
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .approval(foreground)))
    try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .sessionApproval(permission)))
    let result = try f.apply(.provider(threadID: f.threadID, runtimeID: f.runtimeID, event: .context(runID: owner, event: .completed(state))))
    #expect(result.closeRuntimes.isEmpty && f.thread.runtimeID == f.runtimeID)
    #expect(f.thread.runtimeRequests.map(\.id) == [permission.id] && f.thread.activeRun == nil)
    #expect(f.thread.queuePaused == (state == .failed))
    let response = try f.apply(.client(.respond(threadID: f.threadID, requestID: permission.id, response: .decision(true))))
    #expect(response.effects.contains { if case .providerSessionRespond(_, let runtimeID, let request, _) = $0.request { return runtimeID == f.runtimeID && request == permission }; return false })
    #expect(f.thread.runHistory?.first?.status == (state == .failed ? .failed : .completed))
}
