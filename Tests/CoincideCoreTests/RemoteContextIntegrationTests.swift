import Foundation
import Testing
@testable import CoincideCore

@Test(.timeLimit(.minutes(2)), arguments: [ProviderKind.codex, .claude])
func remoteContextActualHelperNativeForkWaitsForExplicitInputAndResumesExactReservedSession(provider: ProviderKind) async throws {
    let f = try await RemoteHistoryNativeFixture.make(provider: provider), connections = RemoteHistoryNativeConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() }, expectedEnvironmentID: f.environmentID)
    do {
        _ = try await client.connectProjection()
        let target = try await client.bindContextWorkspace(try await f.target(client))
        let sourceBefore = try #require(await f.durable().threads.first { $0.id == f.thread.id })
        let transcriptBefore = try f.transcript.map { try Data(contentsOf: $0) }
        let review = try await client.reviewContext(.init(target: target, sourcePoint: .run(f.runIDs[0]), intent: .fork(.init())))
        #expect(review.value.strategy == .nativeFork)
        let id = UUID(), command = RemoteEnvironmentCommand.contextTransfer(target: target,
            action: .begin(reviewID: review.id, digest: review.digest, title: "Deferred native context"))
        #expect(try await client.command(command, id: id).receipt.rejection == nil)
        #expect(try await client.receipt(for: command, id: id).receipt?.commandID == id)
        #expect(try await client.receipt(for: command, id: review.id).receipt == nil)
        let accepted = try await f.durable(), child = try #require(accepted.threads.first { $0.id == review.value.targetThreadID })
        #expect(child.messages.isEmpty && child.providerThreadID == nil && child.activeRun == nil)
        #expect(accepted.contextTransfer(review.id)?.status == .pending)
        #expect(try f.rows("codex-wire.jsonl", kind: "mutation-request").isEmpty)
        #expect(try f.rows("claude-wire.jsonl", kind: "launch").isEmpty)
        let childTarget = try await f.target(client, threadID: child.id)
        let text = provider == .claude ? "Consume the explicit private history choice" : "Consume the explicit private context fork"
        #expect(try await client.command(.submit(threadID: child.id, text: text, expectedConfiguration: childTarget.configuration)).receipt.rejection == nil)
        try await remoteHistoryEventually { try await f.durable().contextTransfer(review.id)?.status == .consumed }
        let current = try await f.durable(), consumed = try #require(current.contextTransfer(review.id))
        let finalChild = try #require(current.threads.first { $0.id == child.id })
        #expect(consumed.delivery?.selection.messages.isEmpty == true)
        #expect(finalChild.providerThreadID != nil && finalChild.providerThreadID != f.nativeID)
        #expect(finalChild.messages.first { $0.role == .user }?.text == text)
        let sourceAfter = try #require(current.threads.first { $0.id == f.thread.id })
        #expect(sourceAfter.messages == sourceBefore.messages && sourceAfter.runHistory == sourceBefore.runHistory && sourceAfter.draft == sourceBefore.draft)
        if provider == .claude {
            #expect(try f.transcript.map { try Data(contentsOf: $0) } == transcriptBefore)
            let launches = try f.rows("claude-wire.jsonl", kind: "launch")
            #expect(launches.count == 1 && launches[0]["nativeID"].string == finalChild.providerThreadID)
            #expect(try f.rows("claude-wire.jsonl", kind: "input").count == 1)
        } else {
            #expect(try f.rows("codex-wire.jsonl", kind: "mutation-committed").count == 1)
            #expect(try f.rows("codex-wire.jsonl", kind: "context-input").count == 1)
            #expect(try f.json("native-state.json")["threads"]["native-fork"]["turns"].array?.map(\.string) == ["native-1"])
        }
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(2)))
func remoteContextActualHelperLostOuterReplyReconcilesOriginalReceiptWithoutNativeForkOrProviderInput() async throws {
    let f = try await RemoteHistoryNativeFixture.make(), id = UUID(), connections = RemoteHistoryNativeConnections(f, dropped: id)
    let client = RemoteEnvironmentClient(factory: { try connections.make() }, expectedEnvironmentID: f.environmentID)
    do {
        _ = try await client.connectProjection(); let target = try await f.target(client)
        let review = try await client.reviewContext(.init(target: target, sourcePoint: .run(f.runIDs[0]), intent: .fork(.init())))
        let command = RemoteEnvironmentCommand.contextTransfer(target: target, action: .begin(reviewID: review.id, digest: review.digest, title: nil))
        await #expect(throws: RemoteEnvironmentClientError.self) { _ = try await client.command(command, id: id) }
        _ = try await client.reconnectProjection()
        let receipt = try await client.receipt(for: command, id: id)
        #expect(receipt.receipt?.commandID == id && receipt.receipt?.rejection == nil)
        #expect(try await client.receipt(for: command, id: id) == receipt)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: id)) {
            _ = try await client.command(command, id: id)
        }
        #expect(try await f.durable().threads.count == 2)
        #expect(try await f.durable().contextTransfer(review.id)?.status == .pending)
        #expect(try f.rows("codex-wire.jsonl", kind: "mutation-request").isEmpty)
        #expect(try f.rows("codex-wire.jsonl", kind: "context-input").isEmpty)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(2)))
func remoteContextActualHelperPagesHugeImmutableArchiveWithoutExposingNativeProofOrStartingInput() async throws {
    let f = try await RemoteHistoryNativeFixture.make(largePrefix: true, oversized: true), connections = RemoteHistoryNativeConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() }, expectedEnvironmentID: f.environmentID)
    do {
        #expect(try JSONEncoder().encode(f.snapshot).count > RemoteEnvironmentProtocol.maximumFrameBytes)
        _ = try await client.connectProjection(); let target = try await f.target(client)
        let before = try await f.durable()
        let review = try await client.reviewContext(.init(target: target, sourcePoint: .run(f.runIDs[0]), intent: .fork(.init())))
        let encoded = try RemoteContextProtocol.payload(review)
        #expect(encoded.count <= RemoteContextProtocol.maximumResultBytes)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let value = try #require(object["value"] as? [String: Any])
        #expect(value["nativeReview"] == nil && value["sourceFingerprint"] == nil && value["messages"] == nil)
        guard case .messages(let page) = try await client.readContext(.init(target: target, query: .messages(binding: review.binding, cursor: nil))).value else { throw CoincideError("Missing archive") }
        let reply = try #require(page.items.first { $0.role == "assistant" }), reference = try #require(reply.text.content)
        let bytes = try await client.contextDocument(reference, binding: review.binding, target: target)
        #expect(bytes == Data(f.thread.messages[1].text.utf8) && bytes.count > RemoteContextProtocol.maximumResultBytes)
        #expect(try RemoteContextProtocol.payload(await f.durable()) == RemoteContextProtocol.payload(before))
        #expect(try f.rows("codex-wire.jsonl", kind: "mutation-request").isEmpty)
        #expect(try await client.discardContextReview(.init(target: target, reviewID: review.id, digest: review.digest)).discarded)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}
