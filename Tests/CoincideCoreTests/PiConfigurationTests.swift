import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private func nativePiModel(_ provider: String = "provider/a", _ id: String = "model/b") -> ProviderModel {
    let selected = PiModelSelection(provider: provider, modelID: id)
    return .init(id: selected.catalogID, name: "Advertised Pi", piSelection: selected, piThinkingLevels: ["off", "high", "max"])
}
private struct NativePiConfigurationFixture {
    var snapshot = WorkspaceSnapshot()
    let runtime = UUID()
    var thread: CodingThread { snapshot.threads[0] }
    init(path: String = "/tmp/coincide-pi-config") throws {
        let project = WorkspaceProject(path: path)
        var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
        snapshot.projects = [project]; snapshot.threads = [thread]
        try edit(.provider(.pi))
    }
    @discardableResult mutating func apply(_ command: EngineCommand) throws -> WorkspaceDecision {
        let decision = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: Date())
        snapshot = decision.snapshot; return decision
    }
    @discardableResult mutating func edit(_ edit: ThreadEdit) throws -> WorkspaceDecision { try apply(.client(.editThread(thread.id, edit))) }
    mutating func start() throws {
        try apply(.client(.submit(threadID: thread.id, text: "First native Pi input")))
        let run = try #require(thread.activeRun)
        try apply(.runtimeOpened(threadID: thread.id, runID: run.id, runtimeID: runtime))
        try apply(.provider(threadID: thread.id, runtimeID: runtime, event: .thread("/tmp/pi-captured-native-session.jsonl")))
    }
}

@Test func nativePiCapturesOpaqueModelThinkingAndLaunchPolicyIndependentlyOfFutureHeader() throws {
    var f = try NativePiConfigurationFixture()
    let a = nativePiModel(), b = nativePiModel("other/provider", "other/model")
    try f.edit(.piModel(a)); try f.edit(.piThinking(model: a, level: "high")); try f.start()
    let active = try #require(f.thread.activeRun)
    try f.edit(.piModel(b)); try f.edit(.piThinking(model: b, level: "max")); try f.edit(.permission(.fullAccess))
    try f.apply(.client(.submit(threadID: f.thread.id, text: "Queued native Pi input")))
    let captured = try #require(f.thread.queuedTurns.first)
    try f.edit(.piModel(a)); try f.edit(.permission(.supervised))
    #expect(f.thread.activeRun == active && active.configuration.piConfiguration?.model == a.piSelection)
    #expect(active.configuration.piConfiguration?.thinkingLevel == "high")
    #expect(captured.configuration.piConfiguration?.model == b.piSelection && captured.configuration.piConfiguration?.thinkingLevel == "max")
    #expect(captured.configuration.permissionSummary == "Always approve")
    let finished = try f.apply(.provider(threadID: f.thread.id, runtimeID: f.runtime, event: .completed(.idle)))
    #expect(f.thread.activeRun?.id == captured.id && f.thread.activeRun?.configuration == captured.configuration)
    #expect(f.thread.piConfiguration?.model == a.piSelection && f.thread.permission == .supervised)
    #expect(finished.effects.contains { if case .providerStart(_, let id, let config, _, _) = $0.request { return id == captured.id && config.piConfiguration == captured.configuration.piConfiguration }; return false })
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func nativePiModelIdentityRejectsGuessedKeysUnadvertisedThinkingAndMixedProviders() throws {
    let a = PiModelSelection(provider: "a/b", modelID: "c"), b = PiModelSelection(provider: "a", modelID: "b/c")
    #expect(a.catalogID != b.catalogID)
    var f = try NativePiConfigurationFixture(); let model = nativePiModel()
    try f.edit(.piModel(model)); let before = f.snapshot
    #expect(throws: (any Error).self) { try f.edit(.model("provider/a/model/b")) }
    #expect(throws: (any Error).self) { try f.edit(.piThinking(model: model, level: "not-advertised")) }
    #expect(throws: (any Error).self) { try f.edit(.piModel(.init(id: model.id, name: "Untyped model"))) }
    #expect(f.snapshot == before)
    var invalid = f.snapshot; invalid.threads[0].provider = .claude
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(invalid) }
    let selected = try #require(f.thread.piConfiguration), changed = selected.selecting(thinkingLevel: "high")
    #expect(selected.runtimeIdentity == changed.runtimeIdentity)
    var thread = f.thread; let captured = ProviderConfiguration(thread: thread); thread.permission = .fullAccess
    #expect(captured.piRuntimeBinding != ProviderConfiguration(thread: thread).piRuntimeBinding)
    try f.edit(.provider(.claude)); #expect(f.thread.piConfiguration == nil)
}

@Test(arguments: ["", " ", "pi --mode rpc", "../pi", "./pi", "https://example.test/pi", "TOKEN=value", "pi\n--unsafe"])
func nativePiRejectsInvalidExecutableAndKeepsFailureTextFixed(_ executable: String) throws {
    let value = PiConfiguration(executable: executable)
    do { try value.validate(); Issue.record("Invalid Pi invocation accepted") }
    catch { #expect(error.localizedDescription == PiConfiguration.invalid().localizedDescription) }
}

@Test func nativePiStorage32PreservesQueueSettingsOnReopenAndLegacyProvidersStayUnchanged() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("pi.sqlite")
    var raw: OpaquePointer?; #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    #expect(sqlite3_exec(raw, "PRAGMA user_version=27", nil, nil, nil) == SQLITE_OK); sqlite3_close(raw)
    var f = try NativePiConfigurationFixture(path: root.path)
    let model = nativePiModel(); try f.edit(.piModel(model)); try f.edit(.piThinking(model: model, level: "max")); try f.start()
    try f.apply(.client(.submit(threadID: f.thread.id, text: "Keep queued Pi configuration")))
    let legacy = CodingThread(project: f.snapshot.projects[0]); f.snapshot.threads.append(legacy)
    let db = try WorkspaceDatabase(url: url)
    _ = try await db.commit(f.snapshot, event: "pi.capture.fixture", commandID: UUID())
    #expect(try await WorkspaceDatabase(url: url).load() == f.snapshot)
    #expect(try await db.rebuildProjection().snapshot == f.snapshot)
    #expect(try JSONDecoder().decode(ProviderConfiguration.self, from: JSONEncoder().encode(ProviderConfiguration(thread: legacy))).piConfiguration == nil)
    #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    var statement: OpaquePointer?; #expect(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 43)
    sqlite3_finalize(statement); sqlite3_close(raw)
}

@Test func nativePiExtensionResponsesPreserveEmptyTextAndRejectCrossProviderOrWrongMethod() throws {
    var f = try NativePiConfigurationFixture()
    let local: JSONValue = .string("local-extension"), threadID = f.thread.id
    f.snapshot.threads[0].runtimeID = f.runtime
    let input = ApprovalRequest(id: local, method: "pi/extension", params: .object(["method": .string("input"), "title": .string("Exact native input")]))
    f.snapshot.threads[0].runtimeRequests = [.init(request: input, sessionScoped: true)]
    let result = try f.apply(.client(.respond(threadID: threadID, requestID: local, response: .answers(["value": ""]))))
    #expect(result.effects.contains { if case .providerSessionRespond(_, _, _, .answers(let answer)) = $0.request { return answer == ["value": ""] }; return false })
    f.snapshot.threads[0].runtimeRequests[0].responding = false
    #expect(throws: (any Error).self) { try f.apply(.client(.respond(threadID: threadID, requestID: local, response: .decision(true)))) }
    #expect(throws: (any Error).self) { try f.apply(.client(.respond(threadID: threadID, requestID: local, response: .option("unadvertised")))) }
    f.snapshot.threads[0].provider = .claude; f.snapshot.threads[0].piConfiguration = nil
    #expect(throws: (any Error).self) { try f.apply(.client(.respond(threadID: threadID, requestID: local, response: .answers(["value": ""])))) }
}
