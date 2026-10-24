import Foundation
import Testing
@testable import CoincideCore

private func entityUpdate(_ fields: [String: JSONValue], type: String = "plan", id: String = "same", session: String = "session") -> ProviderEntityUpdate {
    .patch(.init(sessionID: session, type: type, id: id), .object(fields))
}

@Test func entityPatchesApplyReplacementClearAndMetadataPatchesInOrder() throws {
    var entity = try entityUpdate(["content": .string("A"),
        "_meta": .object(["keep": .number(1), "nested": .object(["old": .bool(true)])])]).apply(to: nil)
    #expect(entity.text == "A")
    entity = try entityUpdate(["_meta": .object(["keep": .null, "nested": .object(["new": .bool(true)])]), "future": .string("kept")]).apply(to: entity)
    #expect(entity.text == "A" && entity.fields["future"] == .string("kept"))
    #expect(entity.fields["_meta"]["keep"] == .null && entity.fields["_meta"]["nested"]["old"] == .null)
    #expect(entity.fields["_meta"]["nested"]["new"] == .bool(true))
    entity = try entityUpdate(["content": .string("C")]).apply(to: entity)
    #expect(entity.text == "C")
    entity = try entityUpdate(["content": .null, "_meta": .null]).apply(to: entity)
    #expect(entity.fields.object?["content"] == nil && entity.fields.object?["_meta"] == nil)
}

@Test func nativeEntityIdentityIncludesSessionAndTypeAndPreservesOpaqueIDs() throws {
    let id = "same / opaque \0 🌍"
    let keys = ["agent_message", "agent_thought", "user_message", "tool_call", "terminal", "plan"].map { ProviderEntityKey(sessionID: "one", type: $0, id: id) }
    #expect(Set(keys).count == 6 && Set(keys.map(\.messageID)).count == 6)
    #expect(keys[0].messageID != ProviderEntityKey(sessionID: "two", type: "agent_message", id: id).messageID)
    #expect(try JSONDecoder().decode(ProviderEntityKey.self, from: JSONEncoder().encode(keys[0])) == keys[0])
}

@Test func toolEntityUpsertsClearFieldsAndReplaceStreamedContent() throws {
    var tool = try entityUpdate(["title": .string("Read"), "status": .string("pending"), "name": .string("read_file"),
        "rawInput": .object(["path": .string("file")])], type: "tool_call").apply(to: nil)
    tool = try entityUpdate(["content": .array([.object(["type": .string("content"),
        "content": .object(["type": .string("text"), "text": .string("streamed")])])])], type: "tool_call").apply(to: tool)
    #expect(tool.text == "Read · pending\nstreamed")
    tool = try entityUpdate(["name": .null, "rawInput": .null, "content": .array([]), "status": .string("completed")], type: "tool_call").apply(to: tool)
    #expect(tool.fields.object?["name"] == nil && tool.fields.object?["rawInput"] == nil)
    #expect(tool.text == "Read · completed" && tool.fields["content"] == .array([]))
}

private func entitySnapshot() -> (WorkspaceSnapshot, UUID, UUID) {
    let project = WorkspaceProject(path: FileManager.default.temporaryDirectory.path), runtimeID = UUID()
    var thread = CodingThread(project: project); thread.runtimeID = runtimeID
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    return (snapshot, thread.id, runtimeID)
}
private func receiveEntity(_ event: ProviderEvent, snapshot: WorkspaceSnapshot, thread: UUID, runtime: UUID) throws -> WorkspaceSnapshot {
    try WorkspaceDecision.make(.provider(threadID: thread, runtimeID: runtime, event: event), id: UUID(), snapshot: snapshot, now: Date()).snapshot
}

@Test func entityUpdatesPersistWhileIdleAndReplayWithoutDroppingMetadataOnlyChanges() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    let (base, threadID, runtimeID) = entitySnapshot()
    var snapshot = try receiveEntity(.entity(entityUpdate(["content": .string("same")], id: "id")), snapshot: base, thread: threadID, runtime: runtimeID)
    #expect(snapshot.threads[0].state == .idle && snapshot.threads[0].activeRun == nil)
    _ = try await database.commit(snapshot, event: "fixture", commandID: UUID())
    let previous = snapshot
    snapshot = try receiveEntity(.entity(entityUpdate(["_meta": .object(["new": .bool(true)])], id: "id")), snapshot: snapshot, thread: threadID, runtime: runtimeID)
    let changes = try WorkspaceJournal.changes(from: previous, to: snapshot)
    #expect(changes.contains { if case .messageUpserted = $0 { true } else { false } })
    #expect(!changes.contains { if case .messageTextAppended = $0 { true } else { false } })
    _ = try await database.commit(snapshot, event: "fixture", commandID: UUID())
    #expect(try await database.rebuildProjection().snapshot == snapshot)
    let stale = try receiveEntity(.entity(entityUpdate(["content": .string("stale")], id: "id")), snapshot: snapshot, thread: threadID, runtime: UUID())
    #expect(stale == snapshot)
}
