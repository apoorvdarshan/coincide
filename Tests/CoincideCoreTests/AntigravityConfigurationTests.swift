import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private struct AntigravityConfigurationFixture {
    var snapshot = WorkspaceSnapshot()
    let runtime = UUID()
    var thread: CodingThread { snapshot.threads[0] }
    init(path: String = "/tmp/coincide-antigravity-configuration") throws {
        let project = WorkspaceProject(path: path)
        var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
        snapshot.projects = [project]; snapshot.threads = [thread]
        try edit(.provider(.antigravity))
    }
    @discardableResult mutating func apply(_ command: EngineCommand) throws -> WorkspaceDecision {
        let decision = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: Date())
        snapshot = decision.snapshot; return decision
    }
    @discardableResult mutating func edit(_ value: ThreadEdit) throws -> WorkspaceDecision {
        try apply(.client(.editThread(thread.id, value)))
    }
    mutating func start() throws {
        try apply(.client(.submit(threadID: thread.id, text: "Captured native input")))
        let run = try #require(thread.activeRun)
        try apply(.runtimeOpened(threadID: thread.id, runID: run.id, runtimeID: runtime))
        try apply(.provider(threadID: thread.id, runtimeID: runtime, event: .thread("native-conversation")))
    }
}

@Test func antigravityCapturesNativeModelModeAndAccountGenerationApartFromFutureChoices() throws {
    var f = try AntigravityConfigurationFixture()
    let original = try #require(f.thread.antigravityConfiguration)
    try f.edit(.model("native/model-a")); try f.start()
    let active = try #require(f.thread.activeRun)
    try f.edit(.model("native/model-b")); try f.edit(.permission(.fullAccess))
    try f.apply(.client(.submit(threadID: f.thread.id, text: "Queued native input")))
    let queued = try #require(f.thread.queuedTurns.first)
    try f.edit(.model("")); try f.edit(.permission(.supervised))
    #expect(f.thread.activeRun == active && active.configuration.model == "native/model-a")
    #expect(queued.configuration.model == "native/model-b" && queued.configuration.permissionSummary == "Always approve")
    #expect(queued.configuration.antigravityConfiguration?.authGeneration == original.authGeneration)
    #expect(queued.configuration.antigravityRuntimeBinding != active.configuration.antigravityRuntimeBinding)
    try f.apply(.provider(threadID: f.thread.id, runtimeID: f.runtime, event: .completed(.idle)))
    #expect(f.thread.activeRun?.id == queued.id && f.thread.activeRun?.configuration == queued.configuration)
    #expect(f.thread.model.isEmpty && f.thread.antigravityConfiguration?.model == nil)
    #expect(original.runtimeIdentity == original.selecting(model: "another").runtimeIdentity)
    try WorkspaceJournal.validate(f.snapshot)
}

@Test(arguments: ["", " ", "agy --unsafe", "./agy", "../agy", "https://example.test/agy", "TOKEN=value", "agy\n--unsafe"])
func antigravityRejectsNonliteralExecutablesWithoutEchoingInput(_ executable: String) throws {
    do { try AntigravityConfiguration(executable: executable).validate(); Issue.record("Invalid native invocation accepted") }
    catch { #expect(error.localizedDescription == AntigravityConfiguration.invalid().localizedDescription) }
}

@Test func antigravityRejectsMixedProviderAndContradictoryCapturedModelsAndAccountFields() throws {
    var f = try AntigravityConfigurationFixture(); try f.edit(.model("native-a"))
    var malformed = f.snapshot; malformed.threads[0].model = "native-b"
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(malformed) }
    malformed = f.snapshot; malformed.threads[0].provider = .claude
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(malformed) }
    for config in [AntigravityConfiguration(authMethod: .oauthBusiness),
                   AntigravityConfiguration(gcpProject: "project-only"),
                   AntigravityConfiguration(gcpProject: "project", gcpLocation: "invalid/location"),
                   AntigravityConfiguration(model: "unsafe\0model")] {
        #expect(throws: (any Error).self) { try config.validate() }
    }
    try AntigravityConfiguration(authMethod: .oauthBusiness, gcpProject: "project-a", gcpLocation: "us-central1").validate()
    try f.edit(.provider(.claude)); #expect(f.thread.antigravityConfiguration == nil)
}

@Test func antigravityQuestionCancelUsesNativeCancellationAndNeverGenericApprovalOrLabels() throws {
    var f = try AntigravityConfigurationFixture()
    let input = try AntigravityPermissionRequest(params: .object([
        "sessionId": .string("native"), "toolCall": .object(["toolCallId": .string("interaction_exact"), "title": .string("Choose one")]),
        "options": .array([.object(["optionId": .string("opaque-1"), "name": .string("First label"), "kind": .string("allow_once")])])
    ]))
    let request = input.approval(localID: .string("local-question"))
    f.snapshot.threads[0].runtimeID = f.runtime
    f.snapshot.threads[0].runtimeRequests = [.init(request: request, sessionScoped: true)]
    let before = f.snapshot
    #expect(throws: (any Error).self) { try f.apply(.client(.respond(threadID: f.thread.id, requestID: request.id, response: .decision(true)))) }
    #expect(throws: (any Error).self) { try f.apply(.client(.respond(threadID: f.thread.id, requestID: request.id, response: .option("First label")))) }
    #expect(f.snapshot == before)
    let cancelled = try f.apply(.client(.respond(threadID: f.thread.id, requestID: request.id, response: .decision(false))))
    #expect(cancelled.effects.contains { if case .providerSessionRespond(_, _, _, .decision(false)) = $0.request { return true }; return false })
    #expect(try input.response(optionID: nil)["outcome"]["outcome"] == .string("cancelled"))
}

@Test func antigravityStorage32PreservesCapturedAccountQueueAndLegacyThreads() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("native.sqlite")
    var raw: OpaquePointer?; #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    #expect(sqlite3_exec(raw, "PRAGMA user_version=29", nil, nil, nil) == SQLITE_OK); sqlite3_close(raw)
    var f = try AntigravityConfigurationFixture(path: root.path)
    let account = AntigravityConfiguration(instanceID: UUID(), executable: "/opt/native/agy_acp_server.par", harnessPath: "/opt/native/localharness_external", authMethod: .agentPlatform, gcpProject: "project-a", gcpLocation: "global", authGeneration: UUID())
    try f.edit(.antigravityConfiguration(account)); try f.edit(.model("native-model")); try f.start()
    try f.apply(.client(.submit(threadID: f.thread.id, text: "Queued configuration survives reopen")))
    let legacy = CodingThread(project: f.snapshot.projects[0]); f.snapshot.threads.append(legacy)
    let database = try WorkspaceDatabase(url: url)
    _ = try await database.commit(f.snapshot, event: "antigravity.fixture.capture", commandID: UUID())
    #expect(try await WorkspaceDatabase(url: url).load() == f.snapshot)
    #expect(try await database.rebuildProjection().snapshot == f.snapshot)
    #expect(try JSONDecoder().decode(CodingThread.self, from: JSONEncoder().encode(legacy)).antigravityConfiguration == nil)
    #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    var statement: OpaquePointer?; #expect(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 33)
    sqlite3_finalize(statement); sqlite3_close(raw)
}

@Test func antigravityPermissionRejectsQuestionResponseShapesBeforeOutboxDispatch() throws {
    var f = try AntigravityConfigurationFixture()
    let input = try AntigravityPermissionRequest(params: .object([
        "sessionId": .string("native"), "toolCall": .object(["toolCallId": .string("actual-tool"), "title": .string("Run command")]),
        "options": .array([.object(["optionId": .string("native-once"), "name": .string("Approve once"), "kind": .string("allow_once")])])
    ]))
    let request = input.approval(localID: .string("local-permission"))
    f.snapshot.threads[0].runtimeID = f.runtime
    f.snapshot.threads[0].runtimeRequests = [.init(request: request, sessionScoped: true)]
    let before = f.snapshot
    let invalid: [ProviderApprovalResponse] = [.answers([:]), .selections([:]), .selectionsWithNotes(selections: [:], notes: [:]), .option("Approve once")]
    for response in invalid {
        #expect(throws: (any Error).self) { try f.apply(.client(.respond(threadID: f.thread.id, requestID: request.id, response: response))) }
        #expect(f.snapshot == before)
    }
    let selected = try f.apply(.client(.respond(threadID: f.thread.id, requestID: request.id, response: .option("native-once"))))
    #expect(selected.effects.contains { if case .providerSessionRespond(_, _, _, .option("native-once")) = $0.request { return true }; return false })
}
