import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private struct CodexRuntimeConfigurationFixture {
    var snapshot = WorkspaceSnapshot()
    let runtimeID = UUID()
    var thread: CodingThread { snapshot.threads[0] }
    init(path: String = "/tmp/coincide-codex-runtime-configuration") {
        let project = WorkspaceProject(path: path)
        var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
        snapshot.projects = [project]; snapshot.threads = [thread]
    }
    @discardableResult mutating func command(_ command: EngineCommand) throws -> WorkspaceDecision {
        let result = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: .now)
        snapshot = result.snapshot; return result
    }
    @discardableResult mutating func edit(_ edit: ThreadEdit) throws -> WorkspaceDecision {
        try command(.client(.editThread(thread.id, edit)))
    }
    mutating func start() throws {
        try command(.client(.submit(threadID: thread.id, text: "Captured native Codex input")))
        let run = try #require(thread.activeRun)
        try command(.runtimeOpened(threadID: thread.id, runID: run.id, runtimeID: runtimeID))
        try command(.provider(threadID: thread.id, runtimeID: runtimeID, event: .thread("native-codex-thread")))
    }
}

@Test(arguments: ["", " ", "codex --unsafe", "./codex", "../codex", "https://example.invalid/codex", "TOKEN=value", "codex\n--unsafe"])
func codexRuntimeRejectsNonliteralExecutableWithoutEchoingIt(_ executable: String) throws {
    do { try CodexRuntimeConfiguration(selection: .custom, executable: executable).validate(); Issue.record("Invalid Codex executable accepted") }
    catch { #expect(error.localizedDescription == CodexRuntimeConfiguration.invalid().localizedDescription) }
}

@Test func codexRuntimeHomeAndSelectionRemainExplicitWithoutChangingTheParentEnvironment() throws {
    let config = CodexRuntimeConfiguration(selection: .custom, executable: "/literal/Codex Tool/codex", homeDirectory: "/literal/Chosen Home")
    try config.validate()
    let parent = ["CODEX_HOME": "/literal/original", "PATH": "/literal/path", "UNRELATED": "retained"]
    let captured = try CodexRuntimeEnvironment.make(configuration: config, base: parent)
    #expect(captured["CODEX_HOME"] == config.homeDirectory && captured["UNRELATED"] == "retained")
    #expect(parent["CODEX_HOME"] == "/literal/original")
    #expect(try CodexRuntimeEnvironment.make(configuration: .init(), base: parent) == parent)
    for home in ["", "~/codex", "relative/home", "/literal/../changed", "/home\nchanged"] {
        #expect(throws: (any Error).self) { try CodexRuntimeConfiguration(homeDirectory: home).validate() }
    }
    for selection in [CodexRuntimeSelection.existingCLI, .managed] {
        #expect(throws: (any Error).self) { try CodexRuntimeConfiguration(selection: selection, executable: "/custom/codex").validate() }
    }
}

@Test func codexRuntimeLegacyDecodeKeepsInheritedHomeAndNonCodexCapturesAreRejected() throws {
    let f = CodexRuntimeConfigurationFixture(), data = try JSONEncoder().encode(f.thread)
    let fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(fields["codexRuntimeConfiguration"] == nil)
    let decoded = try JSONDecoder().decode(CodingThread.self, from: data)
    #expect(decoded.codexRuntimeConfiguration == nil && ProviderConfiguration(thread: decoded).codexRuntimeBinding == CodexRuntimeConfiguration())
    var mixed = f.snapshot; mixed.threads[0].provider = .claude; mixed.threads[0].codexRuntimeConfiguration = .init()
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(mixed) }
}

@Test func codexRuntimeChangesRequireAnEmptyUnboundConversationAndClearOldModelChoices() throws {
    var f = CodexRuntimeConfigurationFixture()
    try f.edit(.model("old-model"))
    let configuration = CodexRuntimeConfiguration(selection: .custom, executable: "/literal/custom-codex", homeDirectory: "/literal/home")
    let changed = try f.edit(.codexRuntimeConfiguration(configuration))
    #expect(f.thread.codexRuntimeConfiguration == configuration && f.thread.model.isEmpty && changed.closeRuntimes.contains(f.thread.id))
    f.snapshot.threads[0].providerThreadID = "existing-native-id"
    #expect(throws: (any Error).self) { try f.edit(.codexRuntimeConfiguration(.init(selection: .managed))) }
    f.snapshot.threads[0].providerThreadID = nil
    try f.edit(.provider(.claude)); #expect(f.thread.codexRuntimeConfiguration == nil)
}

@Test func codexRuntimeStorage32KeepsCapturedHomeAcrossFIFOReopenAndJournalReplay() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("runtime.sqlite")
    var raw: OpaquePointer?; #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    #expect(sqlite3_exec(raw, "PRAGMA user_version=31", nil, nil, nil) == SQLITE_OK); sqlite3_close(raw)
    var f = CodexRuntimeConfigurationFixture(path: root.path)
    let captured = CodexRuntimeConfiguration(selection: .managed, homeDirectory: root.appendingPathComponent("chosen-home").path)
    try f.edit(.codexRuntimeConfiguration(captured)); try f.edit(.model("first-model")); try f.start()
    let active = try #require(f.thread.activeRun)
    try f.edit(.model("queued-model")); try f.edit(.permission(.fullAccess))
    try f.command(.client(.submit(threadID: f.thread.id, text: "Queued native input")))
    let queued = try #require(f.thread.queuedTurns.first)
    #expect(active.configuration.codexRuntimeConfiguration == captured && active.configuration.model == "first-model")
    #expect(queued.configuration.codexRuntimeConfiguration == captured && queued.configuration.model == "queued-model")
    #expect(throws: (any Error).self) { try f.edit(.codexRuntimeConfiguration(.init())) }
    let database = try WorkspaceDatabase(url: url)
    _ = try await database.commit(f.snapshot, event: "codex.runtime.capture", commandID: UUID())
    #expect(try await WorkspaceDatabase(url: url).load() == f.snapshot)
    #expect(try await database.rebuildProjection().snapshot == f.snapshot)
    try f.command(.provider(threadID: f.thread.id, runtimeID: f.runtimeID, event: .completed(.idle)))
    #expect(f.thread.activeRun?.id == queued.id && f.thread.activeRun?.configuration.codexRuntimeConfiguration == captured)
    #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    var statement: OpaquePointer?; #expect(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 32)
    sqlite3_finalize(statement); sqlite3_close(raw)
}

@Test func codexRuntimeHistoryReviewCannotForkANativeIDIntoAnotherHome() throws {
    var source = CodingThread(project: .init(path: "/literal/workspace")); source.providerThreadID = "native-source"
    source.codexRuntimeConfiguration = .init(homeDirectory: "/literal/home-a")
    let configuration = ProviderConfiguration(thread: source)
    func review(_ target: ProviderConfiguration) throws -> ConversationHistoryReview {
        try .init(kind: .forkAfterRun, sourceThreadID: source.id, projectID: source.projectID, runID: UUID(), sourceIncarnation: UUID(),
            sourceConfiguration: configuration, targetConfiguration: target, sourceReference: .init(provider: .codex, nativeThreadID: "native-source"),
            reviewedHeadTurnID: "turn-a", boundary: .throughTurn("turn-a"), expectedResultHeadTurnID: "turn-a", prefix: [],
            removedRunIDs: [], removedMessageIDs: [], sourceFingerprint: String(repeating: "a", count: 64), targetThreadID: UUID(), suggestedTitle: "Native fork")
    }
    _ = try review(configuration)
    var other = configuration; other.codexRuntimeConfiguration = .init(homeDirectory: "/literal/home-b")
    #expect(throws: (any Error).self) { try review(other) }
}
