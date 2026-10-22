import Foundation
import Testing
@testable import CoincideCore

private func v1Value(_ raw: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) }
private func v1HTTP(_ value: JSONValue, status: Int = 200) throws -> OpenCodeHTTPResponse {
    .init(status: status, headers: ["content-type": "application/json"], body: try JSONEncoder().encode(value))
}
private func v1Event(_ type: String, _ properties: JSONValue) throws -> OpenCodeV1Event? {
    let data = try JSONEncoder().encode(JSONValue.object(["type": .string(type), "properties": properties]))
    return try OpenCodeV1Protocol.decode(.init(event: "message", data: String(decoding: data, as: UTF8.self), id: nil, retryMilliseconds: nil))
}
private func v1TextPart(_ text: String, id: String = "part-one", message: String = "msg-one", ended: Bool = false,
                        ignored: Bool = false, synthetic: Bool = false) throws -> OpenCodeV1Part {
    try OpenCodeV1Protocol.part(.object(["id": .string(id), "messageID": .string(message), "sessionID": .string("ses-root"),
        "type": .string("text"), "text": .string(text), "ignored": .bool(ignored), "synthetic": .bool(synthetic),
        "time": .object(["start": .number(1), "end": ended ? .number(2) : .null])]))
}

@Test func nativeOpenCodeV1ProtocolKeepsGenerationOneSessionAndStatusShapes() throws {
    let session = try v1Value(#"{"id":"ses-root","directory":"/workspace/工作","parentID":null,"permission":[{"permission":"edit","pattern":"*","action":"ask"}],"privateConfig":{"authorization":"synthetic-private-value"}}"#)
    let info = try OpenCodeV1Protocol.session(v1HTTP(session), expectedID: "ses-root", directory: "/workspace/工作")
    #expect(info.id == "ses-root" && info.parentID == nil && info.permissions?.first?.action == "ask")
    #expect(throws: (any Error).self) { try OpenCodeV1Protocol.session(v1HTTP(session), expectedID: "another", directory: "/workspace/工作") }
    #expect(throws: (any Error).self) { try OpenCodeV1Protocol.session(v1HTTP(session), directory: "/different") }
    let statuses = try OpenCodeV1Protocol.statuses(v1HTTP(v1Value(#"{"ses-root":{"type":"busy"},"ses-child":{"type":"retry","attempt":1,"next":50,"message":"Wait"}}"#)))
    #expect(statuses["ses-root"] == .busy && statuses["ses-child"] == .retry)
    #expect(throws: (any Error).self) { try OpenCodeV1Protocol.statuses(v1HTTP(v1Value(#"{"ses-root":{"type":"future"}}"#))) }
    #expect(throws: (any Error).self) { try OpenCodeV1Protocol.session(.init(status: 200, headers: ["content-type": "text/html"], body: Data("<html/>".utf8)), directory: "/workspace") }
}

@Test func nativeOpenCodeV1ProtocolRejectsContradictoryOwnersAndMalformedCriticalEvents() throws {
    let properties = try v1Value(#"{"sessionID":"ses-root","info":{"id":"msg-native","sessionID":"ses-other","role":"assistant","parentID":"msg-user","time":{"created":1}}}"#)
    #expect(throws: (any Error).self) { try v1Event("message.updated", properties) }
    #expect(throws: (any Error).self) { try v1Event("session.idle", .object([:])) }
    #expect(try v1Event("server.heartbeat", .object([:])) == nil)
    let decodedError = try v1Event("session.error", v1Value(#"{"error":{"name":"ProviderAuthError","data":{"message":"synthetic-private-value"}}}"#))
    let error = try #require(decodedError)
    #expect(error.sessionID == nil && error.errorName == "ProviderAuthError")
    let decodedDelta = try v1Event("message.part.delta", v1Value(#"{"sessionID":"ses-root","messageID":"msg-one","partID":"part-one","field":"text","delta":" 工作 🌍 "}"#))
    let event = try #require(decodedDelta)
    #expect(event.delta == " 工作 🌍 " && event.messageID == "msg-one")
}

@Test func nativeOpenCodeV1ProtocolRequiresSnapshotPartAndAssistantParentIdentity() throws {
    let value = try v1Value(#"[{"info":{"id":"msg-a","sessionID":"ses-root","role":"assistant","parentID":"msg-u","time":{"created":1,"completed":2}},"parts":[{"id":"part-a","messageID":"msg-a","sessionID":"ses-root","type":"text","text":"native text"}]}]"#)
    let messages = try OpenCodeV1Protocol.messages(v1HTTP(value), sessionID: "ses-root")
    #expect(messages.first?.info.parentID == "msg-u" && messages.first?.info.completed == true)
    #expect(messages.first?.parts.first?.text == "native text")
    #expect(throws: (any Error).self) { try OpenCodeV1Protocol.messages(v1HTTP(value), sessionID: "another") }
    #expect(throws: (any Error).self) { try OpenCodeV1Protocol.message(v1Value(#"{"id":"msg-a","sessionID":"ses-root","role":"assistant","time":{"created":1}}"#)) }
}

@Test func nativeOpenCodeV1QuestionsPreserveOrderedExactLabelsAndCustomMultiplicity() throws {
    let question = try OpenCodeV1Protocol.question(v1Value(#"{"id":"que-native","sessionID":"ses-root","questions":[{"question":"Pick exact labels","header":"First","options":[{"label":"A/B","description":"Slash"},{"label":"A B","description":"Space"}],"multiple":true,"custom":false},{"question":"Explain","header":"Second","options":[]}]}"#))
    #expect(question.questions.map(\.key) == ["question-0", "question-1"])
    let body = try question.answerBody(selections: ["question-0": ["A B", "A/B"], "question-1": [" custom 工作 🌍 "]])
    #expect(body["answers"] == .array([.array([.string("A B"), .string("A/B")]), .array([.string(" custom 工作 🌍 ")])]))
    #expect(try OpenCodeV1Question.presentation(question.approval(localID: .string("local"))) == question)
    #expect(throws: (any Error).self) { try question.answerBody(selections: ["question-0": ["unknown"], "question-1": ["answer"]]) }
    #expect(throws: (any Error).self) { try question.answerBody(selections: ["question-0": ["A/B", "A/B"], "question-1": ["answer"]]) }
    #expect(throws: (any Error).self) { try question.answerBody(selections: ["question-0": ["A/B"]]) }
}

@Test func nativeOpenCodeV1PermissionScopesRequireActualNativeRememberPatterns() throws {
    let value = try v1Value(#"{"id":"per-native","sessionID":"ses-root","permission":"bash","patterns":["git status"],"always":[]}"#)
    let request = try OpenCodeV1Protocol.permission(value)
    #expect(request.approval(localID: .number(1)).params["options"].array?.compactMap { $0["optionId"].string } == ["once", "reject"])
    #expect(try request.replyBody(decision: .once)["reply"] == .string("once"))
    let persistent = try OpenCodeV1Protocol.permission(v1Value(#"{"id":"per-native","sessionID":"ses-root","permission":"bash","patterns":["git status"],"always":["git *"],"metadata":{"headers":"synthetic-private-value"}}"#))
    #expect(persistent.approval(localID: .number(1)).params["options"].array?.count == 4)
}

@Test func nativeOpenCodeV1ProjectionReplacesSnapshotsAppendsDeltasAndScopesRemoval() throws {
    var projection = OpenCodeV1Projection(instanceID: UUID(), sessionID: "ses-root")
    var entity: ProviderEntity?
    for update in try projection.apply(.init(kind: .partUpdated, sessionID: "ses-root", part: v1TextPart("first 🌍"))) { entity = try update.apply(to: entity) }
    for update in try projection.apply(.init(kind: .partDelta, sessionID: "ses-root", messageID: "msg-one", partID: "part-one", delta: " + next", field: "text")) { entity = try update.apply(to: entity) }
    #expect(entity?.text == "first 🌍 + next")
    for update in try projection.apply(.init(kind: .partUpdated, sessionID: "ses-root", part: v1TextPart(" authoritative ", ended: true))) { entity = try update.apply(to: entity) }
    #expect(entity?.text == " authoritative ")
    #expect(try projection.apply(.init(kind: .partDelta, sessionID: "ses-root", messageID: "msg-one", partID: "part-one", delta: "stale", field: "text")).isEmpty)
    #expect(throws: (any Error).self) { try projection.apply(.init(kind: .partRemoved, sessionID: "ses-root", messageID: "wrong", partID: "part-one")) }
    for update in try projection.apply(.init(kind: .partRemoved, sessionID: "ses-root", messageID: "msg-one", partID: "part-one")) { entity = try update.apply(to: entity) }
    #expect(entity?.text == "" && entity?.fields["_meta"]["opencode"]["removed"] == .bool(true))
}

@Test func nativeOpenCodeV1ProjectionBoundsRetainedBytesInsteadOfQuadraticSnapshotTraffic() throws {
    var projection = OpenCodeV1Projection(instanceID: UUID(), sessionID: "ses-root")
    let text = String(repeating: "x", count: 131_072)
    // More than16MiB passes over the wire, but only128KiB is retained.
    for _ in 0..<140 { _ = try projection.apply(.init(kind: .partUpdated, sessionID: "ses-root", part: v1TextPart(text))) }
    #expect(throws: (any Error).self) { try projection.apply(.init(kind: .partUpdated, sessionID: "another", part: v1TextPart(text))) }
}

@Test(arguments: ["ignored", "synthetic"])
func nativeOpenCodeV1HiddenPartsStaySuppressedAcrossStreamedDeltas(_ flag: String) throws {
    var projection = OpenCodeV1Projection(instanceID: UUID(), sessionID: "ses-root")
    var entity: ProviderEntity?
    let hidden = try v1TextPart("hidden snapshot", ignored: flag == "ignored", synthetic: flag == "synthetic")
    for update in try projection.apply(.init(kind: .partUpdated, sessionID: "ses-root", part: hidden)) { entity = try update.apply(to: entity) }
    #expect(entity?.text == "")
    let hiddenDelta = try projection.apply(.init(kind: .partDelta, sessionID: "ses-root", messageID: "msg-one",
        partID: "part-one", delta: "hidden delta", field: "text"))
    #expect(hiddenDelta.isEmpty && entity?.text == "")
    // A later authoritative visible snapshot clears suppression without replaying hidden bytes.
    for update in try projection.apply(.init(kind: .partUpdated, sessionID: "ses-root", part: v1TextPart("visible snapshot"))) { entity = try update.apply(to: entity) }
    for update in try projection.apply(.init(kind: .partDelta, sessionID: "ses-root", messageID: "msg-one",
        partID: "part-one", delta: " + visible delta", field: "text")) { entity = try update.apply(to: entity) }
    #expect(entity?.text == "visible snapshot + visible delta")
}

@Test func nativeOpenCodeV1TaskAliasesAndChildSettlementCannotFinishItsSibling() throws {
    let raw = try v1Value(#"{"id":"part-task","messageID":"msg-one","sessionID":"ses-root","type":"tool","tool":"task","callID":"call-one","state":{"status":"completed","input":{"description":"Work","authorization":"synthetic-private-value"},"output":"Launched","metadata":{"sessionID":"ses-child"},"title":"Task"}}"#)
    let part = try OpenCodeV1Protocol.part(raw)
    #expect(part.tool?.childSessionID == "ses-child" && part.tool?.input["authorization"] == .null)
    var projection = OpenCodeV1Projection(instanceID: UUID(), sessionID: "ses-root")
    let updates = try projection.apply(.init(kind: .partUpdated, sessionID: "ses-root", part: part))
    let update = try #require(updates.first)
    let entity = try update.apply(to: nil)
    #expect(entity.fields["status"] == .string("in_progress") && projection.isTaskCall(messageID: "msg-one", callID: "call-one"))
    #expect(throws: (any Error).self) { try projection.childCompleted(messageID: "msg-one", callID: "call-one", childSessionID: "sibling", outcome: .completed) }
    let settlements = try projection.childCompleted(messageID: "msg-one", callID: "call-one", childSessionID: "ses-child", outcome: .failed)
    let settled = try #require(settlements.first)
    #expect(try settled.apply(to: entity).fields["status"] == .string("failed"))
}
