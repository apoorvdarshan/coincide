import Foundation
import Testing
@testable import CoincideCore

@Suite struct OpenCodeV2ProjectionTests {
    @Test func endedTextReplacesDeltasAndDuplicateOrLateChunksNeverDuplicateAuthoritativeOutput() throws {
        var projection = OpenCodeV2Projection(instanceID: UUID(), sessionID: "ses_root"), entities: [ProviderEntityKey: ProviderEntity] = [:]
        try applyProjection(&projection, &entities, projectionEvent(.textStarted, seq: 1))
        let first = try projectionEvent(.textDelta, text: "Hello ", seq: nil)
        try applyProjection(&projection, &entities, first)
        #expect(try projection.apply(first).isEmpty)
        try applyProjection(&projection, &entities, projectionEvent(.textDelta, text: "🌍", seq: nil))
        #expect(entities.values.first?.text == "Hello 🌍")
        try applyProjection(&projection, &entities, projectionEvent(.textEnded, text: "Authoritative replacement", seq: 4))
        #expect(try projection.apply(projectionEvent(.textDelta, text: "late duplicate", seq: nil)).isEmpty)
        #expect(try projection.apply(projectionEvent(.textEnded, text: "stale snapshot", seq: 3)).isEmpty)
        #expect(entities.count == 1 && entities.values.first?.text == "Authoritative replacement")
    }

    @Test func textReasoningOrdinalAssistantSessionAndInstanceRemainIndependentKeys() throws {
        let instance = UUID()
        var root = OpenCodeV2Projection(instanceID: instance, sessionID: "ses_root"), child = OpenCodeV2Projection(instanceID: instance, sessionID: "ses_child")
        var otherInstance = OpenCodeV2Projection(instanceID: UUID(), sessionID: "ses_root")
        var entities: [ProviderEntityKey: ProviderEntity] = [:]
        try applyProjection(&root, &entities, projectionEvent(.textEnded, text: "same", seq: 1))
        try applyProjection(&root, &entities, projectionEvent(.reasoningEnded, text: "same", seq: 2))
        try applyProjection(&root, &entities, projectionEvent(.textEnded, ordinal: 1, text: "same", seq: 3))
        try applyProjection(&root, &entities, projectionEvent(.textEnded, assistant: "msg_other", text: "same", seq: 4))
        try applyProjection(&child, &entities, projectionEvent(.textEnded, sessionID: "ses_child", text: "same", seq: 1))
        try applyProjection(&otherInstance, &entities, projectionEvent(.textEnded, text: "same", seq: 1))
        #expect(entities.count == 6 && entities.values.filter { $0.role == .reasoning }.count == 1)
        #expect(throws: OpenCodeV2ProtocolError.invalidOwner) { try root.apply(projectionEvent(.textEnded, sessionID: "ses_child", text: "unowned", seq: 2)) }
    }

    @Test func canonicalToolsUseContentArraysAndRedactPrivateConfigBeforePersistence() throws {
        var projection = OpenCodeV2Projection(instanceID: UUID(), sessionID: "ses_root"), entities: [ProviderEntityKey: ProviderEntity] = [:]
        try applyProjection(&projection, &entities, projectionTool(.toolInputStarted, extra: ["name": .string("shell")], seq: 1))
        try applyProjection(&projection, &entities, projectionTool(.toolInputDelta, extra: ["delta": .string("{\"headers\":{\"Authorization\":\"fixture-private\"}")], seq: nil))
        #expect(!String(reflecting: entities).contains("fixture-private"))
        try applyProjection(&projection, &entities, projectionTool(.toolCalled, extra: [
            "input": .object(["command": .string("printf synthetic"), "headers": .object(["Authorization": .string("fixture-private")])]), "executed": .bool(true)], seq: 2))
        try applyProjection(&projection, &entities, projectionTool(.toolSuccess, extra: ["executed": .bool(true), "content": .array([
            .object(["type": .string("text"), "text": .string("Synthetic output")]),
            .object(["type": .string("file"), "uri": .string("https://private.invalid/output?token=fixture-private"), "mime": .string("image/png"), "name": .string("Preview")])]),
            "metadata": .object(["headers": .object(["Authorization": .string("fixture-private")])])], seq: 3, version: 2))
        let entity = try #require(entities.values.first)
        #expect(entity.fields["status"] == .string("completed"))
        #expect(entity.text.contains("Synthetic output") && entity.text.contains("Returned file: Preview"))
        #expect(entity.fields["rawInput"]["command"] == .string("printf synthetic"))
        #expect(entity.fields["rawInput"]["headers"] == .string("<redacted>"))
        #expect(!String(reflecting: entity).contains("fixture-private") && !String(reflecting: entity).contains("private.invalid"))
    }

    @Test func toolFailuresUseFixedSafeTextAndNeverEchoNativePrivateErrorBodies() throws {
        var projection = OpenCodeV2Projection(instanceID: UUID(), sessionID: "ses_root"), entities: [ProviderEntityKey: ProviderEntity] = [:]
        try applyProjection(&projection, &entities, projectionTool(.toolInputStarted, extra: ["name": .string("shell")], seq: 1))
        try applyProjection(&projection, &entities, projectionTool(.toolFailed, extra: ["executed": .bool(true),
            "error": .object(["type": .string("aborted"), "message": .string("fixture-private-error")])], seq: 2, version: 2))
        let entity = try #require(entities.values.first)
        #expect(entity.fields["status"] == .string("interrupted") && entity.text.contains("The native tool was interrupted."))
        #expect(!String(reflecting: entity).contains("fixture-private-error"))
    }

    @Test func backgroundLaunchIsNotChildCompletionAndOnlyTheExactLinkedCallSettles() throws {
        var projection = OpenCodeV2Projection(instanceID: UUID(), sessionID: "ses_root"), entities: [ProviderEntityKey: ProviderEntity] = [:]
        for (index, call) in ["call_a", "call_b"].enumerated() {
            let base = index * 4
            try applyProjection(&projection, &entities, projectionTool(.toolInputStarted, id: call, extra: ["name": .string("subagent")], seq: base + 1))
            try applyProjection(&projection, &entities, projectionTool(.toolCalled, id: call, extra: ["input": .object(["background": .bool(true), "prompt": .string("Synthetic child")]), "executed": .bool(true)], seq: base + 2))
            try applyProjection(&projection, &entities, projectionTool(.toolSuccess, id: call, extra: ["executed": .bool(true),
                "content": .array([.object(["type": .string("text"), "text": .string("Launched")])]),
                "metadata": .object(["sessionID": .string("ses_child_\(call)"), "status": .string("running")])], seq: base + 3, version: 2))
        }
        #expect(entities.values.allSatisfy { $0.fields["status"] == .string("in_progress") })
        #expect(throws: OpenCodeV2ProtocolError.invalidOwner) {
            try projection.childCompleted(assistantMessageID: "msg_assistant", toolID: "call_a", childSessionID: "ses_child_call_b", outcome: .completed)
        }
        let updates = try projection.childCompleted(assistantMessageID: "msg_assistant", toolID: "call_a", childSessionID: "ses_child_call_a", outcome: .completed)
        for update in updates { entities[update.key] = try update.apply(to: entities[update.key]) }
        #expect(entities[projection.toolKey(assistantMessageID: "msg_assistant", id: "call_a")]?.fields["status"] == .string("completed"))
        #expect(entities[projection.toolKey(assistantMessageID: "msg_assistant", id: "call_b")]?.fields["status"] == .string("in_progress"))
        #expect(try projection.apply(projectionTool(.toolSuccess, id: "call_a", extra: ["executed": .bool(true),
            "content": .array([.object(["type": .string("text"), "text": .string("late launch")])]),
            "metadata": .object(["sessionID": .string("ses_child_call_a"), "status": .string("running")])], seq: 10, version: 2)).isEmpty)
    }

    @Test func sameToolCallIDInDifferentAssistantStepsDoesNotCollideAndQuestionsAreSeparateForms() throws {
        var projection = OpenCodeV2Projection(instanceID: UUID(), sessionID: "ses_root")
        let first = try projection.apply(projectionTool(.toolInputStarted, extra: ["name": .string("shell")], seq: 1))
        let second = try projection.apply(projectionTool(.toolInputStarted, assistant: "msg_second", extra: ["name": .string("shell")], seq: 2))
        #expect(first.first?.key != second.first?.key)
        #expect(try projection.apply(projectionTool(.toolInputStarted, id: "question_call", extra: ["name": .string("question")], seq: 3)).isEmpty)
    }

    @Test func stepOrExecutionBoundariesDoNotFabricateTranscriptEntitiesOrProviderCompletion() throws {
        var projection = OpenCodeV2Projection(instanceID: UUID(), sessionID: "ses_root")
        #expect(try projection.apply(projectionEvent(.executionStarted, seq: 1)).isEmpty)
        #expect(try projection.apply(projectionEvent(.stepStreamed, seq: 2)).isEmpty)
        #expect(try projection.apply(projectionEvent(.executionSucceeded, seq: 3)).isEmpty)
        var weak = try projectionEvent(.executionSucceeded, seq: nil)
        weak.requiresReconciliation = true
        #expect(throws: OpenCodeV2ProtocolError.invalidEvent) { try projection.apply(weak) }
    }

    @Test func rawInputMemoryAndNestedPrivateConfigAreBoundedBeforeProjection() throws {
        var projection = OpenCodeV2Projection(instanceID: UUID(), sessionID: "ses_root")
        _ = try projection.apply(projectionTool(.toolInputStarted, extra: ["name": .string("shell")], seq: 1))
        #expect(throws: OpenCodeV2ProtocolError.limitExceeded) {
            try projection.apply(projectionTool(.toolInputDelta, extra: ["delta": .string(String(repeating: "x", count: 65_537))], seq: nil))
        }
        var value: JSONValue = .string("value")
        for _ in 0..<18 { value = .object(["nested": value]) }
        #expect(throws: OpenCodeV2ProtocolError.limitExceeded) { try OpenCodeV2Bounds.safeInput(value) }
    }
}

private func applyProjection(_ projection: inout OpenCodeV2Projection, _ entities: inout [ProviderEntityKey: ProviderEntity], _ event: OpenCodeV2Event) throws {
    for update in try projection.apply(event) { entities[update.key] = try update.apply(to: entities[update.key]) }
}
private func projectionEvent(_ kind: OpenCodeV2Event.Kind, sessionID: String = "ses_root", assistant: String = "msg_assistant",
                             ordinal: Int = 0, text: String = "", seq: Int?) throws -> OpenCodeV2Event {
    var data: [String: JSONValue] = ["sessionID": .string(sessionID), "assistantMessageID": .string(assistant), "ordinal": .number(Double(ordinal))]
    if kind == .textDelta || kind == .reasoningDelta { data["delta"] = .string(text) } else { data["text"] = .string(text) }
    return try decodedProjectionEvent(kind, data: data, sessionID: sessionID, seq: seq)
}
private func projectionTool(_ kind: OpenCodeV2Event.Kind, id: String = "call_1", assistant: String = "msg_assistant", extra: [String: JSONValue], seq: Int?, version: Int = 1) throws -> OpenCodeV2Event {
    var data = extra
    data["sessionID"] = .string("ses_root"); data["assistantMessageID"] = .string(assistant); data["id"] = .string(id)
    return try decodedProjectionEvent(kind, data: data, sessionID: "ses_root", seq: seq, version: version)
}
private func decodedProjectionEvent(_ kind: OpenCodeV2Event.Kind, data: [String: JSONValue], sessionID: String, seq: Int?, version: Int = 1) throws -> OpenCodeV2Event {
    var envelope: [String: JSONValue] = ["id": .string("evt_\(UUID().uuidString)"), "created": .number(1700000000000), "type": .string(kind.rawValue), "data": .object(data)]
    if let seq { envelope["durable"] = .object(["aggregateID": .string(sessionID), "seq": .number(Double(seq)), "version": .number(Double(version))]) }
    let frame = OpenCodeSSEEvent(event: "message", data: String(decoding: try JSONEncoder().encode(JSONValue.object(envelope)), as: UTF8.self), id: nil, retryMilliseconds: nil)
    let decoded = try OpenCodeV2Protocol.decode(frame)
    return try #require(decoded)
}
