import Foundation
import Testing
@testable import CoincideCore

private func entityUpdate(_ fields: [String: JSONValue], session: String = "session") throws -> ProviderEntityUpdate {
    try .acp(.object(fields), sessionID: session)
}

@Test func entityMessagesApplyChunksReplacementClearAndMetadataPatchesInOrder() throws {
    var entity = try entityUpdate(["sessionUpdate": .string("agent_message"), "messageId": .string("same"),
        "content": .array([.object(["type": .string("text"), "text": .string("A")])]),
        "_meta": .object(["keep": .number(1), "nested": .object(["old": .bool(true)])])]).apply(to: nil)
    entity = try entityUpdate(["sessionUpdate": .string("agent_message_chunk"), "messageId": .string("same"),
        "content": .object(["type": .string("text"), "text": .string("B")]), "_meta": .object(["chunk": .bool(true)]), "futureChunk": .string("retained")]).apply(to: entity)
    #expect(entity.text == "AB" && entity.fields["content"].array?.count == 2)
    #expect(entity.fields["_meta"]["chunk"] == .null)
    #expect(entity.chunkAnnotations?.first?["value"]["futureChunk"] == .string("retained"))
    entity = try entityUpdate(["sessionUpdate": .string("agent_message"), "messageId": .string("same"),
        "_meta": .object(["keep": .null, "nested": .object(["new": .bool(true)])]), "future": .string("kept")]).apply(to: entity)
    #expect(entity.text == "AB" && entity.fields["future"] == .string("kept"))
    #expect(entity.fields["_meta"]["keep"] == .null && entity.fields["_meta"]["nested"]["old"] == .null)
    #expect(entity.fields["_meta"]["nested"]["new"] == .bool(true))
    entity = try entityUpdate(["sessionUpdate": .string("agent_message"), "messageId": .string("same"),
        "content": .array([.object(["type": .string("text"), "text": .string("C")])])]).apply(to: entity)
    #expect(entity.text == "C" && entity.chunkAnnotations == nil)
    entity = try entityUpdate(["sessionUpdate": .string("agent_message"), "messageId": .string("same"), "content": .null, "_meta": .null]).apply(to: entity)
    #expect(entity.text.isEmpty && entity.fields.object?["content"] == nil && entity.fields.object?["_meta"] == nil)
}

@Test func nativeEntityIdentityIncludesSessionAndTypeAndPreservesOpaqueIDs() throws {
    let id = "same / opaque \0 🌍"
    let keys = ["agent_message", "agent_thought", "user_message", "tool_call", "terminal", "plan"].map { ProviderEntityKey(sessionID: "one", type: $0, id: id) }
    #expect(Set(keys).count == 6 && Set(keys.map(\.messageID)).count == 6)
    #expect(keys[0].messageID != ProviderEntityKey(sessionID: "two", type: "agent_message", id: id).messageID)
    #expect(try JSONDecoder().decode(ProviderEntityKey.self, from: JSONEncoder().encode(keys[0])) == keys[0])
}

@Test func toolEntityUpsertsClearFieldsAndReplaceStreamedContent() throws {
    var tool = try entityUpdate(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("same"),
        "title": .string("Read"), "status": .string("pending"), "name": .string("read_file"), "rawInput": .object(["path": .string("file")])]).apply(to: nil)
    tool = try entityUpdate(["sessionUpdate": .string("tool_call_content_chunk"), "toolCallId": .string("same"),
        "content": .object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string("streamed")])])]).apply(to: tool)
    #expect(tool.text == "Read · pending\nstreamed")
    tool = try entityUpdate(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("same"),
        "name": .null, "rawInput": .null, "content": .array([]), "status": .string("completed")]).apply(to: tool)
    #expect(tool.fields.object?["name"] == nil && tool.fields.object?["rawInput"] == nil)
    #expect(tool.text == "Read · completed" && tool.fields["content"] == .array([]))
}

@Test func terminalEntityDecodesChunksIndependentlyAndReplacesSnapshotsWithoutSplicing() throws {
    let first = Data([0xF0, 0x9F]), second = Data([0x8C, 0x8D])
    var entity = try entityUpdate(["sessionUpdate": .string("terminal_output_chunk"), "terminalId": .string("term"),
        "data": .string(first.base64EncodedString())]).apply(to: nil)
    entity = try entityUpdate(["sessionUpdate": .string("terminal_output_chunk"), "terminalId": .string("term"),
        "data": .string(second.base64EncodedString())]).apply(to: entity)
    #expect(entity.text == "Terminal\n🌍")
    entity = try entityUpdate(["sessionUpdate": .string("terminal_update"), "terminalId": .string("term"),
        "output": .object(["data": .string(Data("new".utf8).base64EncodedString())]), "exitStatus": .object(["exitCode": .number(0)])]).apply(to: entity)
    #expect(entity.text == "Terminal\nnew" && entity.fields["exitStatus"]["exitCode"] == .number(0))
    entity = try entityUpdate(["sessionUpdate": .string("terminal_update"), "terminalId": .string("term"), "output": .null]).apply(to: entity)
    #expect(entity.text == "Terminal\n")
    #expect(throws: (any Error).self) {
        try entityUpdate(["sessionUpdate": .string("terminal_output_chunk"), "terminalId": .string("term"), "data": .string("???")])
    }
    #expect(throws: (any Error).self) {
        try entityUpdate(["sessionUpdate": .string("terminal_update"), "terminalId": .string("term"), "output": .object(["data": .string("???")])]).apply(to: entity)
    }
}

@Test func unknownEntityVariantsContentAndPlanEnvelopeFieldsAreRetained() throws {
    let raw: JSONValue = .object(["sessionUpdate": .string("_future"), "items": .array([.number(1)]), "_meta": .object(["opaque": .bool(true)])])
    let entity = try ProviderEntityUpdate.acp(raw, sessionID: "session").apply(to: nil)
    #expect(entity.fields == raw)
    let plan = try entityUpdate(["sessionUpdate": .string("plan_update"), "futureEnvelope": .string("keep"),
        "plan": .object(["planId": .string("p"), "type": .string("_future_plan"), "content": .string("retained")])]).apply(to: nil)
    #expect(plan.fields["type"] == .string("_future_plan") && plan.envelopeAnnotations?.first?["futureEnvelope"] == .string("keep"))
    let unknownContent: JSONValue = .object(["type": .string("_future_content"), "payload": .object(["a": .number(1)])])
    let message = try entityUpdate(["sessionUpdate": .string("agent_message"), "messageId": .string("m"), "content": .array([unknownContent])]).apply(to: nil)
    #expect(message.fields["content"] == .array([unknownContent]))
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
    var snapshot = try receiveEntity(.entity(entityUpdate(["sessionUpdate": .string("agent_message"), "messageId": .string("id"),
        "content": .array([.object(["type": .string("text"), "text": .string("same")])])])), snapshot: base, thread: threadID, runtime: runtimeID)
    #expect(snapshot.threads[0].state == .idle && snapshot.threads[0].activeRun == nil)
    _ = try await database.commit(snapshot, event: "fixture", commandID: UUID())
    let previous = snapshot
    snapshot = try receiveEntity(.entity(entityUpdate(["sessionUpdate": .string("agent_message"), "messageId": .string("id"),
        "_meta": .object(["new": .bool(true)])])), snapshot: snapshot, thread: threadID, runtime: runtimeID)
    let changes = try WorkspaceJournal.changes(from: previous, to: snapshot)
    #expect(changes.contains { if case .messageUpserted = $0 { true } else { false } })
    #expect(!changes.contains { if case .messageTextAppended = $0 { true } else { false } })
    _ = try await database.commit(snapshot, event: "fixture", commandID: UUID())
    #expect(try await database.rebuildProjection().snapshot == snapshot)
    let stale = try receiveEntity(.entity(entityUpdate(["sessionUpdate": .string("agent_message_chunk"), "messageId": .string("id"),
        "content": .object(["type": .string("text"), "text": .string("stale")])])), snapshot: snapshot, thread: threadID, runtime: UUID())
    #expect(stale == snapshot)
}

@Test(arguments: [false, true]) func userEntityAssociationReconcilesBeforeOrAfterEchoWithoutContentMatching(_ echoFirst: Bool) throws {
    var (snapshot, threadID, runtimeID) = entitySnapshot()
    let clientID = "user-" + UUID().uuidString
    let local = ChatMessage(id: clientID, role: .user, text: "Original user text")
    snapshot.threads[0].messages = [local]
    let update = try entityUpdate(["sessionUpdate": .string("user_message"), "messageId": .string("native-user"),
        "content": .array([.object(["type": .string("text"), "text": .string("Provider representation")])])])
    if echoFirst { snapshot = try receiveEntity(.entity(update), snapshot: snapshot, thread: threadID, runtime: runtimeID) }
    snapshot = try receiveEntity(.associateEntity(update.key, clientMessageID: clientID), snapshot: snapshot, thread: threadID, runtime: runtimeID)
    if !echoFirst { snapshot = try receiveEntity(.entity(update), snapshot: snapshot, thread: threadID, runtime: runtimeID) }
    #expect(snapshot.threads[0].messages.count == 1)
    #expect(snapshot.threads[0].messages[0].text == local.text && snapshot.threads[0].messages[0].createdAt == local.createdAt)
    #expect(snapshot.threads[0].messages[0].providerEntity?.text == "Provider representation")
    let other = try entityUpdate(["sessionUpdate": .string("user_message"), "messageId": .string("other-user"),
        "content": .array([.object(["type": .string("text"), "text": .string("Provider representation")])])])
    snapshot = try receiveEntity(.entity(other), snapshot: snapshot, thread: threadID, runtime: runtimeID)
    #expect(snapshot.threads[0].messages.count == 2)
}
