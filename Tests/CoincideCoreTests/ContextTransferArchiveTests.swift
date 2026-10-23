import Foundation
import Testing
@testable import CoincideCore

@Test func contextTransferDeliveryProofStorageKeepsRunCopiesBoundedIndependentAndFlatCodable() throws {
    let transfer = UUID(), run = UUID(), source = UUID()
    let selection = try ContextHandoffService.select(messages: [.init(id: "saved-public-item", role: "assistant", kind: "text", text: "Exact immutable context")], coverage: .init(transferID: transfer, sourceThreadID: source, strategy: "portableContext"))
    let native = try ProviderConversationSnapshot(reference: .init(provider: .codex, nativeThreadID: "verified-native-original"), workspacePath: "/tmp", historyMode: .paginated, headTurnID: "native-turn")
    let original = ContextTransferDelivery(id: UUID(), runID: run, transferIDs: [transfer], selection: selection, status: .dispatching,
        nativeResult: native, authoredText: "Literal input", eligibleItemIDs: ["saved-public-item"])
    var changed = original; changed.status = .uncertain; changed.authoredText = "Changed independent copy"; changed.nativeResult = nil
    #expect(original.status == .dispatching && original.authoredText == "Literal input" && original.nativeResult == native)
    #expect(changed.status == .uncertain && changed.nativeResult == nil)
    let bytes = try ContextTransferProtocol.payload(original), json = try JSONDecoder().decode(JSONValue.self, from: bytes)
    #expect(json["id"].string == original.id.uuidString && json["storage"] == .null)
    #expect(try JSONDecoder().decode(ContextTransferDelivery.self, from: bytes) == original)
    // Delivery is nested in every active/queued/archived run. Keeping this
    // transport wrapper small prevents async-worker validator stack overflow.
    #expect(MemoryLayout<ContextTransferDelivery>.size <= 32)
}

@Test func contextTransferArchiveContainsOnlyPublicSemanticActivityAndNeverPrivateReasoningApprovalOrAttachmentBytes() async throws {
    let f = try await ContextTransferCoreFixture.make()
    do {
        var snapshot = await f.engine.current().snapshot
        let index = try #require(snapshot.threads.firstIndex { $0.id == f.sourceID }), runID = f.runs[0]
        func row(_ id: String, role: MessageRole, text: String, entity: ProviderEntity? = nil) -> ChatMessage {
            var message = ChatMessage(id: id, role: role, text: text); message.runReference = .init(threadID: f.sourceID, runID: runID); message.providerEntity = entity; return message
        }
        let privateEntity = ProviderEntity(key: .init(sessionID: "private", type: "approval", id: "private-request"), fields: .object(["authorization": .string("NEVER_APPROVAL_TOKEN"), "session": .string("NEVER_SESSION_PAYLOAD")]))
        let tool = ProviderEntity(key: .init(sessionID: "public", type: "tool_call", id: "public-call"), fields: .object([
            "title": .string("Read selected source"), "status": .string("completed"), "privateNativeState": .string("NEVER_NATIVE_INTERNAL"),
            "content": .array([.object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string("Public tool result")])]),
                .object(["type": .string("native_request"), "payload": .string("NEVER_UNKNOWN_CONTENT")])])]))
        snapshot.threads[index].messages += [row("private-reason", role: .reasoning, text: "NEVER_REASONING_BODY"),
            row("private-approval", role: .tool, text: "NEVER_PRIVATE_RENDERED", entity: privateEntity),
            row("public-tool", role: .tool, text: "NEVER_RAW_ENTITY_RENDERED", entity: tool)]
        let attachment = ChatAttachment(id: UUID(), name: "reviewed.txt", mimeType: "text/plain", byteCount: 100, digest: String(repeating: "d", count: 64), fileExtension: "txt")
        snapshot.threads[index].messages[0].attachments = [attachment]
        let point = try snapshot.contextTransferSource(threadID: f.sourceID, point: .run(runID))
        let archive = try snapshot.contextTransferMessages(thread: snapshot.threads[index], through: point, ownRunsOnly: false)
        let text = archive.map(\.text).joined(separator: "\n")
        #expect(text.contains("Public tool result") && text.contains("Read selected source"))
        #expect(text.contains("reviewed.txt") && text.contains("File bytes are not replayed"))
        #expect(!text.contains("NEVER_"))
        #expect(!archive.contains { $0.role == "reasoning" || $0.kind == "approval" })
        #expect(archive.contains { $0.kind == "runOutcome" && $0.text.contains("checkpoint: ready") })
    } catch { await f.close(); throw error }; await f.close()
}
