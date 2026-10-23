import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private struct OwnedConfigurationCapture {
    var snapshot: WorkspaceSnapshot
    let runtimeID = UUID()
    var thread: CodingThread { snapshot.threads[0] }
    init(project: WorkspaceProject, configuration: CodexRuntimeConfiguration) {
        var thread = CodingThread(project: project)
        thread.codexRuntimeConfiguration = configuration; thread.model = "captured-first-model"; thread.checkpointPolicy = .disabled
        thread.draft = "Keep unsent draft 工作 🌍"
        snapshot = .init(); snapshot.projects = [project]; snapshot.threads = [thread]
    }
    mutating func apply(_ command: EngineCommand) throws {
        snapshot = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: Date(timeIntervalSince1970: 1_800_000_000)).snapshot
    }
    mutating func captureTwoTurns() throws {
        try apply(.client(.submit(threadID: thread.id, text: "First captured account input")))
        let run = try #require(thread.activeRun)
        try apply(.runtimeOpened(threadID: thread.id, runID: run.id, runtimeID: runtimeID))
        try apply(.provider(threadID: thread.id, runtimeID: runtimeID, event: .thread("native-owned-configuration-thread")))
        try apply(.client(.editThread(thread.id, .model("captured-queued-model"))))
        try apply(.client(.submit(threadID: thread.id, text: "Queued captured account input")))
        try apply(.client(.editThread(thread.id, .draft("Keep draft after accepted input"))))
    }
}

private func ownedConfigurationSQL(_ url: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CoincideError("The private storage fixture could not open.") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CoincideError("The private storage fixture command failed.") }
}
private func ownedConfigurationSeed32(_ url: URL, payload: Data) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CoincideError("The private migration fixture could not open.") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, "CREATE TABLE workspace(id INTEGER PRIMARY KEY,payload BLOB NOT NULL); PRAGMA user_version=32;", nil, nil, nil) == SQLITE_OK else { throw CoincideError("The private migration fixture could not initialize.") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT INTO workspace(id,payload) VALUES(1,?)", -1, &statement, nil) == SQLITE_OK else { throw CoincideError("The private migration fixture could not bind.") }
    defer { sqlite3_finalize(statement) }
    let bound = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw CoincideError("The private migration fixture could not save.") }
}
private func ownedConfigurationStorageVersion(_ url: URL) throws -> Int32 {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CoincideError("The private storage fixture could not open.") }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { throw CoincideError("The private storage fixture has no version.") }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw CoincideError("The private storage fixture version could not be read.") }
    return sqlite3_column_int(statement, 0)
}
private func ownedConfigurationLegacyJSON(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let fields): return .object(fields.filter { $0.key != "authenticationMode" && $0.key != "accountBinding" }.mapValues(ownedConfigurationLegacyJSON))
    case .array(let values): return .array(values.map(ownedConfigurationLegacyJSON))
    default: return value
    }
}
private func ownedConfigurationContainsPrivateField(_ value: JSONValue) -> Bool {
    switch value {
    case .object(let fields):
        let privateKeys: Set<String> = ["accessToken", "refreshToken", "idToken", "authorizationURL", "clientID", "subject", "email", "credential", "credentials"]
        return !privateKeys.isDisjoint(with: fields.keys) || fields.values.contains(where: ownedConfigurationContainsPrivateField)
    case .array(let values): return values.contains(where: ownedConfigurationContainsPrivateField)
    default: return false
    }
}

@Test func codexOwnedConfigurationLegacyJSONKeepsCLIAuthenticationAndItsExactCapture() throws {
    for text in [#"{}"#, #"{"selection":"managed","homeDirectory":"/literal/legacy-home"}"#,
                 #"{"selection":"custom","executable":"/private/var/literal/codex","homeDirectory":"/private/var/literal/home"}"#] {
        let configuration = try JSONDecoder().decode(CodexRuntimeConfiguration.self, from: Data(text.utf8))
        #expect(configuration.authenticationMode == .cliDefault && configuration.accountBinding == nil)
        #expect(configuration.instanceID == CodexRuntimeConfiguration.defaultInstanceID)
        let roundtrip = try JSONDecoder().decode(CodexRuntimeConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(roundtrip == configuration)
    }
}

@Test func codexOwnedConfigurationRejectsAmbiguousAuthenticationInsteadOfFallingBackToCLI() throws {
    let binding = CodexAccountBinding(profileID: UUID(), generation: UUID())
    let invalid = [CodexRuntimeConfiguration(homeDirectory: "/literal/shared", accountBinding: binding),
                   .init(authenticationMode: .ownedChatGPT, accountBinding: binding),
                   .init(authenticationMode: .ownedChatGPT)]
    for configuration in invalid {
        #expect(throws: (any Error).self) { try configuration.validate() }
        let data = try JSONEncoder().encode(configuration)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CodexRuntimeConfiguration.self, from: data) }
    }
    let future = Data(#"{"authenticationMode":"futureOwnedProfile","homeDirectory":"/literal/shared"}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(CodexRuntimeConfiguration.self, from: future) }
    let unsigned = CodexRuntimeConfiguration(homeDirectory: "/literal/shared", authenticationMode: .ownedChatGPT)
    try unsigned.validate()
    #expect(unsigned.authenticationMode == .ownedChatGPT && unsigned.accountBinding == nil, "An unsigned Settings draft must remain explicitly owned.")
}

@Test func codexOwnedConfigurationRoundtripContainsOnlyOpaqueAccountBindingAndPreservesPhysicalLiteralPaths() throws {
    let binding = CodexAccountBinding(profileID: UUID(), generation: UUID())
    let configuration = CodexRuntimeConfiguration(instanceID: UUID(), selection: .custom, executable: "/private/var/literal tools/codex",
        homeDirectory: "/private/var/literal shared home", authenticationMode: .ownedChatGPT, accountBinding: binding)
    try configuration.validate()
    let bytes = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(CodexRuntimeConfiguration.self, from: bytes)
    #expect(decoded == configuration && decoded.executable == "/private/var/literal tools/codex" && decoded.homeDirectory == "/private/var/literal shared home")
    let object = try JSONDecoder().decode(JSONValue.self, from: bytes)
    #expect(Set(object.object?.keys.map { $0 } ?? []) == Set(["instanceID", "selection", "executable", "homeDirectory", "authenticationMode", "accountBinding"]))
    #expect(Set(object["accountBinding"].object?.keys.map { $0 } ?? []) == Set(["profileID", "generation"]))
    #expect(!ownedConfigurationContainsPrivateField(object))
    let changed = configuration.replacingAccountBinding(.init(profileID: UUID(), generation: UUID()))
    #expect(changed.instanceID == configuration.instanceID && changed.selection == configuration.selection && changed.executable == configuration.executable && changed.homeDirectory == configuration.homeDirectory)
    #expect(changed.authenticationMode == .ownedChatGPT && changed.accountBinding != binding)
}

@Test func codexOwnedConfigurationStorage33Migrates32AndKeepsOldQueueBindingsAcrossAccountPublicationAndReplay() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("owned-auth.sqlite"), project = WorkspaceProject(path: root.path)
    let legacyConfiguration = CodexRuntimeConfiguration(selection: .managed, homeDirectory: "/private/var/literal/legacy-shared")
    var legacy = OwnedConfigurationCapture(project: project, configuration: legacyConfiguration)
    try legacy.captureTwoTurns()
    let encoded = try JSONEncoder().encode(legacy.snapshot)
    let legacyObject = ownedConfigurationLegacyJSON(try JSONDecoder().decode(JSONValue.self, from: encoded))
    let legacyBytes = try JSONEncoder().encode(legacyObject)
    let expectedLegacy = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacyBytes)
    try ownedConfigurationSeed32(url, payload: legacyBytes)
    #expect(try ownedConfigurationStorageVersion(url) == 32)
    let database = try WorkspaceDatabase(url: url)
    let migrated = try await database.load()
    let migratedVersion = try ownedConfigurationStorageVersion(url)
    #expect(migrated == expectedLegacy && migratedVersion == 41)
    #expect(migrated.threads[0].activeRun?.configuration.codexRuntimeConfiguration == legacyConfiguration)
    #expect(migrated.threads[0].queuedTurns.first?.configuration.codexRuntimeConfiguration == legacyConfiguration)
    let instance = UUID(), oldBinding = CodexAccountBinding(profileID: UUID(), generation: UUID()), newBinding = CodexAccountBinding(profileID: UUID(), generation: UUID())
    let owned = CodexRuntimeConfiguration(instanceID: instance, selection: .custom, executable: "/private/var/literal/codex",
        homeDirectory: "/private/var/literal/owned-shared", authenticationMode: .ownedChatGPT, accountBinding: oldBinding)
    var capture = OwnedConfigurationCapture(project: project, configuration: owned)
    try capture.captureTwoTurns()
    let queueBefore = capture.thread.queuedTurns
    try capture.apply(.codexAuthenticationPreparing(instanceID: instance, threadIDs: [capture.thread.id]))
    try capture.apply(.codexAccountConfigured(instanceID: instance, binding: newBinding))
    #expect(capture.thread.queuePaused && capture.thread.activeRun == nil && capture.thread.queuedTurns == queueBefore)
    #expect(capture.thread.codexRuntimeConfiguration?.accountBinding == newBinding)
    #expect(capture.thread.runHistory?.first?.configuration.codexRuntimeConfiguration?.accountBinding == oldBinding)
    capture.snapshot.threads += migrated.threads
    _ = try await database.commit(capture.snapshot, event: "codex.owned.configuration", commandID: UUID())
    let reopened = try WorkspaceDatabase(url: url)
    let restored = try await reopened.load(), replayed = try await reopened.rebuildProjection().snapshot
    #expect(restored == capture.snapshot && replayed == capture.snapshot)
    #expect(restored.threads[0].queuedTurns == queueBefore && restored.threads[0].queuePaused)
    #expect(restored.threads[0].queuedTurns.first?.configuration.codexRuntimeConfiguration?.accountBinding == oldBinding)
    #expect(restored.threads[1] == migrated.threads[0])
    let stored = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(restored))
    #expect(!ownedConfigurationContainsPrivateField(stored))
    let journal = try await reopened.journal()
    for record in journal {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record))
        #expect(!ownedConfigurationContainsPrivateField(value))
    }
}

@Test(arguments: [37, 38, 39, 40, 41]) func codexOwnedConfigurationAcceptsCurrentStorage41AndRefusesFuture42WithoutDowngradingIt(_ priorVersion: Int) throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let current = root.appendingPathComponent("current.sqlite"), future = root.appendingPathComponent("future.sqlite")
    try ownedConfigurationSQL(current, "PRAGMA user_version=\(priorVersion)")
    _ = try WorkspaceDatabase(url: current)
    #expect(try ownedConfigurationStorageVersion(current) == 41)
    try ownedConfigurationSQL(future, "PRAGMA user_version=42")
    #expect(throws: (any Error).self) { try WorkspaceDatabase(url: future) }
    #expect(try ownedConfigurationStorageVersion(future) == 42)
}
