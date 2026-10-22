import Foundation
import Testing
@testable import CoincideCore

@Suite struct OpenCodeV2ProtocolTests {
    @Test func sessionResponseVerifiesExactIDDirectoryAndNarrowRulesWithoutPrivateConfig() throws {
        let body: JSONValue = .object(["data": .object([
            "id": .string("ses_root"), "location": .object(["directory": .string("/tmp/native project")]),
            "agent": .string("build"), "model": .object(["providerID": .string("provider"), "id": .string("wire-model"), "variant": .string("deep")]),
            "permissions": .array([.object(["action": .string("shell"), "resource": .string("*"), "effect": .string("ask")])]),
            "outcome": .string("succeeded"), "time": .object(["idle": .number(1234)]), "revert": .object([:]),
            "metadata": .object(["authorization": .string("fixture-private-config")])])])
        let response = try protocolResponse(body)
        let session = try OpenCodeV2Protocol.session(response, expectedID: "ses_root", directory: "/tmp/native project")
        #expect(session.id == "ses_root" && session.agentID == "build" && session.parentID == nil)
        #expect(session.model == .init(providerID: "provider", id: "wire-model", variant: "deep"))
        #expect(session.permissions?.first?.effect == .ask && session.outcome == "succeeded" && session.idleMilliseconds == 1234 && session.hasRevert)
        #expect(!String(reflecting: session).contains("fixture-private-config"))
        #expect(throws: OpenCodeV2ProtocolError.invalidOwner) { try OpenCodeV2Protocol.session(response, expectedID: "ses_other", directory: "/tmp/native project") }
        #expect(throws: OpenCodeV2ProtocolError.invalidOwner) { try OpenCodeV2Protocol.session(response, directory: "/tmp/other") }
    }

    @Test func promptAdmissionBindsExactSessionInputAndTypeWithoutInventingCompletionOrPayloadEquality() throws {
        let body: JSONValue = .object(["data": .object([
            "id": .string("msg_owned"), "sessionID": .string("ses_root"), "type": .string("user"), "delivery": .string("steer"),
            "payload": .object(["text": .string("Plugin transformed native text"), "metadata": .object(["headers": .string("fixture-private")])])])])
        let response = try protocolResponse(body)
        let admission = try OpenCodeV2Protocol.admission(response, sessionID: "ses_root", inputID: "msg_owned")
        #expect(admission.id == "msg_owned" && admission.delivery == "steer" && admission.text == "Plugin transformed native text")
        #expect(!String(reflecting: admission).contains("fixture-private"))
        #expect(throws: OpenCodeV2ProtocolError.invalidOwner) { try OpenCodeV2Protocol.admission(response, sessionID: "ses_other", inputID: "msg_owned") }
        #expect(throws: OpenCodeV2ProtocolError.invalidOwner) { try OpenCodeV2Protocol.admission(response, sessionID: "ses_root", inputID: "msg_other") }
    }

    @Test func activeMapIsGlobalAndOnlyAnActualRunningEntryProvesActivity() throws {
        let response = try protocolResponse(.object(["data": .object(["ses_root": .object(["type": .string("running")]), "ses_unowned": .object(["type": .string("running")])])]))
        #expect(try OpenCodeV2Protocol.activeSessions(response) == ["ses_root", "ses_unowned"])
        #expect(try OpenCodeV2Protocol.activeSessions(protocolResponse(.object(["data": .object([:])]))) == [])
        let invalid = try protocolResponse(.object(["data": .object(["ses_root": .object(["type": .string("idle")])])]))
        #expect(throws: OpenCodeV2ProtocolError.invalidResponse) {
            try OpenCodeV2Protocol.activeSessions(invalid)
        }
    }

    @Test func unknownEventsAreSkippedAndUnownedGlobalFormsAreNeverAdopted() throws {
        #expect(try OpenCodeV2Protocol.decode(protocolEvent("rpc.completed", data: ["private": .string("fixture-private")], seq: nil)) == nil)
        #expect(try OpenCodeV2Protocol.decode(protocolEvent("form.created", data: ["form": .object(["sessionID": .string("global")])], seq: nil)) == nil)
        #expect(try OpenCodeV2Protocol.decode(protocolEvent("form.cancelled", sessionID: "global", data: ["id": .string("frm_global")], seq: nil)) == nil)
    }

    @Test func criticalStartAndTerminalKeepMinimumEvidenceForNewerPayloadWithoutLeakingFailure() throws {
        var raw: [String: JSONValue] = ["type": .string("session.execution.failed"), "data": .object([
            "sessionID": .string("ses_root"), "error": .object(["newSchema": .string("fixture-private-error")])]),
            "durable": .object(["aggregateID": .string("ses_root"), "seq": .number(41), "version": .number(7)])]
        let first = try OpenCodeV2Protocol.decode(sse(raw))
        var decoded = try #require(first)
        #expect(decoded.kind == .executionFailed && decoded.sessionID == "ses_root" && decoded.durable?.seq == 41)
        #expect(!decoded.requiresReconciliation && decoded.id == nil && decoded.failureMessage == "The native OpenCode execution failed.")
        #expect(!String(reflecting: decoded).contains("fixture-private-error"))
        raw.removeValue(forKey: "durable")
        let second = try OpenCodeV2Protocol.decode(sse(raw))
        decoded = try #require(second)
        #expect(decoded.requiresReconciliation)
        raw["data"] = .object([:])
        #expect(throws: OpenCodeV2ProtocolError.invalidOwner) { try OpenCodeV2Protocol.decode(sse(raw)) }
    }

    @Test func eventDurabilityCannotCrossNativeSessionsOrAcceptFractionalSequence() throws {
        let cross: [String: JSONValue] = ["id": .string("evt_cross"), "created": .number(1), "type": .string("session.execution.started"),
            "data": .object(["sessionID": .string("ses_root")]), "durable": .object(["aggregateID": .string("ses_child"), "seq": .number(1), "version": .number(1)])]
        #expect(throws: OpenCodeV2ProtocolError.invalidOwner) { try OpenCodeV2Protocol.decode(sse(cross)) }
        var fractional = cross
        fractional["durable"] = .object(["aggregateID": .string("ses_root"), "seq": .number(1.5), "version": .number(1)])
        #expect(try OpenCodeV2Protocol.decode(sse(fractional))?.requiresReconciliation == true)
    }

    @Test func textKeysUseAssistantOrdinalAndExactWhitespaceForDeltasAndFullSnapshots() throws {
        let wire = try protocolEvent("session.reasoning.delta", data: [
            "assistantMessageID": .string("msg_assistant"), "ordinal": .number(3), "delta": .string("  漢字 🌍\n")], seq: nil)
        let decoded = try OpenCodeV2Protocol.decode(wire)
        let delta = try #require(decoded)
        #expect(delta.kind == .reasoningDelta && delta.assistantMessageID == "msg_assistant" && delta.ordinal == 3 && delta.text == "  漢字 🌍\n")
        #expect(throws: OpenCodeV2ProtocolError.invalidEvent) {
            try OpenCodeV2Protocol.decode(protocolEvent("session.text.delta", data: ["assistantMessageID": .string("msg_assistant"), "ordinal": .number(-1), "delta": .string("x")], seq: nil))
        }
    }

    @Test func permissionScopeAndRejectMessageRemainExplicitWithoutRawMetadata() throws {
        let permission = try OpenCodeV2Protocol.permission(.object([
            "id": .string("per_native"), "sessionID": .string("ses_root"), "action": .string("shell"),
            "resources": .array([.string("printf 'hello'")]), "save": .array([.string("printf *")]),
            "source": .object(["type": .string("tool"), "messageID": .string("msg_assistant"), "id": .string("call_1")]),
            "metadata": .object(["token": .string("fixture-private")])]))
        let request = permission.approval(localID: .string("opaque-local"))
        #expect(request.id == .string("opaque-local") && request.method == "opencode/permission")
        #expect(request.params["options"].array?[1]["name"].string?.contains("workspace") == true)
        #expect(try permission.replyBody(decision: .reject) == .object(["decision": .string("reject")]))
        #expect(try permission.replyBody(decision: .reject, message: "Declined, continue without retry") != permission.replyBody(decision: .reject))
        #expect(!String(reflecting: request).contains("fixture-private"))
    }

    @Test func formsPreserveWireValuesMultiselectDefaultsAndNativeUTF16LengthConstraints() throws {
        let form = try OpenCodeV2Protocol.form(protocolForm([
            .object(["key": .string("choice"), "type": .string("string"), "required": .bool(true), "options": .array([
                .object(["value": .string("wire-a"), "label": .string("Human label")])])]),
            .object(["key": .string("many"), "type": .string("multiselect"), "required": .bool(true), "minItems": .number(1), "maxItems": .number(2), "options": .array([
                .object(["value": .string("x"), "label": .string("X")]), .object(["value": .string("y"), "label": .string("Y")])])]),
            .object(["key": .string("emoji"), "type": .string("string"), "minLength": .number(2), "maxLength": .number(2), "default": .string("🌍")])]))
        let answer = try form.answerBody(selections: ["choice": ["wire-a"], "many": ["x", "y"]])
        #expect(answer["answer"]["choice"] == .string("wire-a") && answer["answer"]["many"] == .array([.string("x"), .string("y")]))
        #expect(answer["answer"]["emoji"] == .string("🌍"))
        #expect(throws: OpenCodeV2ProtocolError.invalidAnswer) { try form.answerBody(selections: ["choice": ["Human label"], "many": ["x"]]) }
        #expect(throws: OpenCodeV2ProtocolError.invalidAnswer) { try form.answerBody(selections: ["choice": ["wire-a"], "many": ["x", "x"]]) }
        #expect(throws: OpenCodeV2ProtocolError.invalidAnswer) { try form.answerBody(selections: ["choice": ["wire-a"], "many": []]) }
        #expect(throws: OpenCodeV2ProtocolError.invalidAnswer) { try form.answerBody(selections: ["choice": ["wire-a"], "many": ["x"], "unknown": ["injected"]]) }
    }

    @Test func unsupportedNativeFormsAreVisibleAndNeverFabricateAnswersOrOpenURLs() throws {
        let fields: [JSONValue] = [
            .object(["key": .string("field"), "type": .string("external"), "url": .string("https://private.invalid/?token=fixture-private")]),
            .object(["key": .string("field"), "type": .string("number"), "default": .object(["token": .string("fixture-private")])]),
            .object(["key": .string("field"), "type": .string("string"), "hidden": .bool(true)]),
            .object(["key": .string("field"), "type": .string("string"), "when": .array([.object(["key": .string("previous")])])]),
            .object(["key": .string("field"), "type": .string("string"), "pattern": .string("fixture-private-pattern")])
        ]
        for field in fields {
            let form = try OpenCodeV2Protocol.form(protocolForm([field]))
            #expect(form.unsupportedReason != nil)
            #expect(throws: OpenCodeV2ProtocolError.unsupportedForm) { try form.answerBody(answers: ["field": "value"]) }
            let request = form.approval(localID: .string("local"))
            #expect(request.params["unsupportedReason"].string != nil && !String(reflecting: request).contains("fixture-private"))
        }
    }

    @Test func normalizedFormPresentationRoundTripsValidationAndRejectsForgedShape() throws {
        let form = try OpenCodeV2Protocol.form(protocolForm([.object([
            "key": .string("pick"), "type": .string("string"), "required": .bool(true), "options": .array([
                .object(["value": .string("wire"), "label": .string("Label")])])])]))
        let request = form.approval(localID: .string("opaque")), presentation = try OpenCodeV2Form.presentation(request)
        #expect(presentation.id == "frm_presentation" && presentation.sessionID == "ses_presentation")
        #expect(try presentation.answerBody(answers: ["pick": "wire"]) == form.answerBody(answers: ["pick": "wire"]))
        #expect(throws: OpenCodeV2ProtocolError.invalidAnswer) { try presentation.answerBody(answers: ["pick": "Label"]) }
        var forged = request, params = try #require(request.params.object)
        params["nativeRawPayload"] = .object(["private": .string("fixture-private")]); forged.params = .object(params)
        #expect(throws: OpenCodeV2ProtocolError.unsupportedForm) { try OpenCodeV2Form.presentation(forged) }
    }

    @Test func responseAndEventBoundsRejectHTMLAndOversizedWireWithoutRawErrorEcho() throws {
        #expect(throws: OpenCodeV2ProtocolError.invalidResponse) {
            try OpenCodeV2Protocol.session(.init(status: 200, headers: ["content-type": "text/html"], body: Data("fixture-private-body".utf8)), directory: "/tmp/project")
        }
        #expect(throws: OpenCodeProtocolError.unauthorized) {
            try OpenCodeV2Protocol.activeSessions(.init(status: 401, headers: [:], body: Data("fixture-private-body".utf8)))
        }
        #expect(throws: OpenCodeV2ProtocolError.invalidEvent) {
            try OpenCodeV2Protocol.decode(.init(event: "message", data: String(repeating: "x", count: 1_048_577), id: nil, retryMilliseconds: nil))
        }
    }
}

private func protocolResponse(_ value: JSONValue) throws -> OpenCodeHTTPResponse {
    .init(status: 200, headers: ["content-type": "application/json"], body: try JSONEncoder().encode(value))
}
private func protocolEvent(_ type: String, sessionID: String = "ses_root", data: [String: JSONValue], seq: Int? = 1) throws -> OpenCodeSSEEvent {
    var fields = data; fields["sessionID"] = .string(sessionID)
    var value: [String: JSONValue] = ["id": .string("evt_fixture"), "created": .number(1700000000000), "type": .string(type), "data": .object(fields)]
    if let seq { value["durable"] = .object(["aggregateID": .string(sessionID), "seq": .number(Double(seq)), "version": .number(1)]) }
    return try sse(value)
}
private func sse(_ value: [String: JSONValue]) throws -> OpenCodeSSEEvent {
    .init(event: "message", data: String(decoding: try JSONEncoder().encode(JSONValue.object(value)), as: UTF8.self), id: nil, retryMilliseconds: nil)
}
private func protocolForm(_ fields: [JSONValue]) -> JSONValue {
    .object(["id": .string("frm_native"), "sessionID": .string("ses_root"), "title": .string("Native form"), "fields": .array(fields)])
}
