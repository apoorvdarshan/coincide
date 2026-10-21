import Foundation
import CSQLite
import Testing
@testable import CoincideCore

@Test func cloneEffectIdentityCollisionRollsBackProjectAndLeavesTheWorkspaceUsable() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    let project = WorkspaceProject(path: root.path), thread = CodingThread(project: project), identity = UUID()
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let old = PendingWorkspaceEffect(id: identity, request: .providerInterrupt(threadID: thread.id, runID: UUID()))
    _ = try await database.commit(snapshot, event: "old.operation", commandID: UUID(), effects: [old])
    let before = try await database.revision()
    let plan = try GitClonePlan.prepare(source: "https://example.invalid/native.git", destination: root.appendingPathComponent("clone"), id: identity)
    var cloning = WorkspaceProject(path: plan.destinationPath); cloning.clone = .init(plan: plan)
    snapshot.projects.append(cloning); snapshot.threads.append(CodingThread(project: cloning))
    let commandID = UUID()
    await #expect(throws: WorkspaceCommitError.self) {
        try await database.commit(snapshot, event: "clone.start", commandID: commandID, effects: [.init(id: identity, request: .projectClone(projectID: cloning.id, plan: plan))])
    }
    #expect(try await database.revision() == before)
    #expect(try await database.receipt(commandID) == nil)
    #expect(try await database.effects().map(\.id) == [identity])
    // An identity collision is a rejected caller operation, not infrastructure failure.
    _ = try await database.commit(before.snapshot, event: "still.usable", commandID: UUID())
}

@Test func projectEffectsMustMatchTheValidatedCloneAttemptBeforeAnyPayloadIsPersisted() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: path)
    let project = WorkspaceProject(path: root.path)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]
    try await database.save(snapshot, event: "project")
    let safe = try GitClonePlan.prepare(source: "https://example.invalid/repo.git", destination: root.appendingPathComponent("clone"))
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(safe)) as? [String: Any])
    let marker = "synthetic-outbox-password-must-not-persist"
    json["source"] = "https://user:\(marker)@example.invalid/repo.git"
    let invalid = try JSONDecoder().decode(GitClonePlan.self, from: JSONSerialization.data(withJSONObject: json))
    await #expect(throws: (any Error).self) {
        try await database.commit(snapshot, event: "invalid.project.effect", commandID: UUID(), effects: [.init(id: invalid.id, request: .projectClone(projectID: project.id, plan: invalid))])
    }
    #expect(try await database.effects().isEmpty)
    for suffix in ["", "-wal"] {
        let file = URL(fileURLWithPath: path.path + suffix)
        if FileManager.default.fileExists(atPath: file.path) { #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(marker)) }
    }
}

@Test func storageSixProjectsMigrateWithoutCloneMetadataOrConversationLoss() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite")
    let project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project); thread.messages = [.init(role: .user, text: "Legacy native conversation 🌍")]; thread.draft = "keep draft"
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let database = try WorkspaceDatabase(url: url); try await database.save(snapshot, event: "legacy")
    var raw: OpaquePointer?
    #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    defer { sqlite3_close(raw) }
    #expect(sqlite3_exec(raw, "PRAGMA user_version=6", nil, nil, nil) == SQLITE_OK)
    let reopened = try WorkspaceDatabase(url: url)
    #expect(try await reopened.load() == snapshot)
    #expect(try await reopened.load().projects[0].clone == nil)
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 9)
    #expect(try await reopened.rebuildProjection().snapshot == snapshot)
}
