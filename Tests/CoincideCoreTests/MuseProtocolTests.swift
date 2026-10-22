import Foundation
import Testing
@testable import CoincideCore

private let museS = "019a0000-0000-7000-8000-000000000001"
private let museT = "019a0000-0000-7000-8000-000000000002"

private func museInitializeFixture(fingerprint: String = MuseProtocol.schemaFingerprint, durability: String? = nil) -> JSONValue {
    var value: [String: JSONValue] = ["serverInfo": .object(["name": .string("muse"), "version": .string("synthetic")]), "schema": .object(["version": .number(1), "fingerprint": .string(fingerprint)]), "grantedCapabilities": .array([.string("sessionMcp")]), "experimentalApi": .bool(false)]
    if let durability { value["sessionDurability"] = .string(durability) }; return .object(value)
}

@Test func museMSPHandshakeUsesPinnedFingerprintAsWarningAndKeepsUnknownDurabilityHonest() throws {
    let pinned = try MuseProtocol.initialize(museInitializeFixture())
    #expect(pinned.survivesHostDeath && !pinned.supportsResumePermissionProfile)
    let newer = try MuseProtocol.initialize(museInitializeFixture(fingerprint: MuseProtocol.resumeProfileFingerprint, durability: "ephemeral"))
    #expect(newer.supportsResumePermissionProfile && !newer.survivesHostDeath)
    let unknown = try MuseProtocol.initialize(museInitializeFixture(fingerprint: "sha256:" + String(repeating: "0", count: 64), durability: "future"))
    #expect(!unknown.supportsResumePermissionProfile && !unknown.survivesHostDeath)
    #expect(throws: MuseMSPError.self) { _ = try MuseProtocol.initialize(.object([:])) }
}

@Test func museMSPSessionPermissionProofIsAuthoritativeAndExactIdentityAndRootStayBound() throws {
    func result(_ profile: JSONValue = .string(":ask-me"), id: String = museS, root: String = "/tmp/muse-workspace") -> JSONValue {
        .object(["viewCursor": .string("opaque-head"), "session": .object(["sessionId": .string(id), "workspaceRoot": .string(root), "providerId": .string("meta"), "modelId": .string("native-model"), "activeTurnId": .null, "status": .string("idle"), "permissionState": .object(["profileId": profile]), "approvalMode": .object(["mode": .string("promptUnmatched")])])])
    }
    let info = try MuseProtocol.session(result(), expectedID: museS, workspaceRoot: "/tmp/muse-workspace", requiredProfile: ":ask-me")
    #expect(info.profileID == ":ask-me" && info.approvalMode == "promptUnmatched" && info.activeTurnID == nil)
    for value in [result(.null), result(.string(":unrestricted")), result(id: museT), result(root: "/tmp/muse-other")] {
        #expect(throws: MuseMSPError.self) { _ = try MuseProtocol.session(value, expectedID: museS, workspaceRoot: "/tmp/muse-workspace", requiredProfile: ":ask-me") }
    }
}

@Test func museMSPModelsKeepAdvertisedEffortsSeparateFromPinnedCompatibilityFallback() throws {
    func row(_ id: String, variants: JSONValue, isDefault: Bool = false) -> JSONValue {
        .object(["modelId": .string(id), "displayLabel": .string(id), "providerId": .string("meta"), "isDefault": .bool(isDefault), "variants": variants, "defaultReasoningEffort": .string("high"), "reasoningEffortVariants": .array([.object(["tier": .string("high"), "description": .string("Native high effort")])])])
    }
    let rows = try MuseProtocol.models(.object(["providerId": .string("meta"), "source": .string("fakeCatalog"), "models": .array([
        row("unknown", variants: .string("unknown")), row("declared", variants: .array([.string("off"), .string("high")]), isDefault: true), row("none", variants: .array([]))])]))
    #expect(rows.count == 3 && rows[0].museReasoningEfforts == nil && rows[0].museDefaultReasoningEffort == nil)
    #expect(rows[0].reasoningEfforts.map(\.id) == ["low", "medium", "high", "xhigh", "max"] && rows[0].defaultReasoningEffort == "high")
    #expect(rows[0].reasoningEfforts.allSatisfy { $0.description.contains("fallback") })
    #expect(rows[0].reasoningEfforts.first(where: { $0.id == "high" })?.description == "Compatibility fallback; Muse did not advertise reasoning choices. Native high effort")
    #expect(rows[1].isDefault && rows[1].museSelection?.modelID == "declared" && rows[1].museReasoningEfforts?.map(\.id) == ["high"])
    #expect(rows[1].reasoningEfforts.first?.description == "Native high effort")
    #expect(rows[2].museReasoningEfforts == [] && rows[2].reasoningEfforts.isEmpty)
    #expect(throws: MuseMSPError.self) { _ = try MuseProtocol.models(.object(["providerId": .string("other"), "models": .array([])])) }
    #expect(throws: MuseMSPError.self) { _ = try MuseProtocol.models(.object(["providerId": .string("meta"), "models": .array([row("null", variants: .null)])])) }
}

@Test func museMSPWorkspaceAliasNeedsSameExistingDirectoryIdentityAndPreservesNativeSpelling() throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let actual = root.appendingPathComponent("actual", isDirectory: true), other = root.appendingPathComponent("other", isDirectory: true), alias = root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
    func result(_ native: String) -> JSONValue { .object(["viewCursor": .string("opaque"), "session": .object(["sessionId": .string(museS), "workspaceRoot": .string(native), "status": .string("idle")])]) }
    let parsed = try MuseProtocol.session(result(alias.path), expectedID: museS, workspaceRoot: actual.path)
    #expect(parsed.workspaceRoot == alias.path)
    for native in [other.path, alias.path + "/../actual", actual.path + "/.", "/missing" + actual.path, "relative"] {
        #expect(throws: MuseMSPError.self) { _ = try MuseProtocol.session(result(native), expectedID: museS, workspaceRoot: actual.path) }
    }
}

private func museApprovalFixture() -> JSONValue {
    .object(["sessionId": .string(museS), "approvalId": .string("approval-1"), "turnId": .string(museT), "itemId": .string("tool-1"), "currentRequirementId": .object(["approvalId": .string("approval-1"), "sourceIndex": .number(1)]), "subject": .object(["kind": .string("shell"), "command": .string("printf synthetic"), "toolName": .string("shell"), "access": .string("execute"), "protocol": .string("tcp"), "port": .number(443), "workspaceRoot": .string("/tmp/muse-workspace")]), "availableChoices": .array([
        .object(["choiceId": .string("once"), "decision": .string("approved"), "scope": .string("once"), "label": .string("Allow once")]),
        .object(["choiceId": .string("persistent"), "decision": .string("approvedPolicyAmendment"), "scope": .string("localPersistent"), "label": .string("Always allow this rule"), "rulePreview": .string("shell prefix: printf synthetic")]),
        .object(["choiceId": .string("abort"), "decision": .string("abort"), "scope": .string("once"), "label": .string("Reject")])]), "privateError": .string("synthetic-private")])
}

@Test func museMSPApprovalUsesOfferedChoiceCurrentStageAndNeverRelabelsPersistentAuthority() throws {
    let typed = try MuseApprovalRequest(params: museApprovalFixture())
    let request = typed.approval(localID: .string("local-only"))
    #expect(!request.params.pretty.contains("synthetic-private") && request.method == "muse/approval")
    let presented = try MuseApprovalRequest.presentation(request)
    #expect(presented.choices == typed.choices && presented.choices[1].scope == "localPersistent")
    #expect(presented.choices[1].rulePreview == "shell prefix: printf synthetic")
    #expect(presented.detail.contains("Tool: shell") && presented.detail.contains("Port: 443") && presented.detail.contains("Workspace: /tmp/muse-workspace"))
    let reply = try typed.decisionBody(choiceID: "once")
    #expect(reply["requirementId"]["sourceIndex"] == .number(1) && reply["choiceId"] == .string("once"))
    #expect(try typed.declineBody()["choiceId"] == .string("abort"))
    #expect(throws: MuseMSPError.self) { _ = try typed.decisionBody(choiceID: "invented") }
}

private func museQuestionFixture() -> JSONValue {
    .object(["sessionId": .string(museS), "turnId": .string(museT), "userInputId": .string("question-1"), "itemId": .string("tool-question"), "questions": .array([
        .object(["id": .string("approach"), "header": .string("Approach"), "question": .string("Which approach?"), "selection": .object(["mode": .string("multiple"), "minSelections": .number(1), "maxSelections": .number(2)]), "options": .array([
            .object(["label": .string("Small"), "description": .string("Focused change"), "preview": .object(["content": .string("# Small preview"), "format": .string("markdown")])]),
            .object(["label": .string("Large")])])])]), "headers": .object(["Authorization": .string("synthetic-private")])])
}

@Test func museMSPQuestionsPreserveLabelsNotesAndExactNativePreviewAndCountUTF16Units() throws {
    let typed = try MuseUserInputRequest(params: museQuestionFixture())
    let request = typed.approval(localID: .string("local-question")), presented = try MuseUserInputRequest.presentation(request)
    #expect(presented.questions == typed.questions && presented.questions[0].options[0].preview == "# Small preview")
    #expect(!request.params.pretty.contains("synthetic-private"))
    let reply = try typed.answerBody(selections: ["approach": ["Small", "Large"]], notes: ["approach": "  preserve notes\n"])
    #expect(reply["answers"].array?.first?["selectedLabels"] == .array([.string("Small"), .string("Large")]))
    #expect(reply["answers"].array?.first?["note"] == .string("  preserve notes\n"))
    let custom = try typed.answerBody(selections: [:], notes: ["approach": String(repeating: "🌍", count: 250)])
    #expect(custom["answers"].array?.first?["freeText"].string?.utf16.count == 500)
    for note in [" ", String(repeating: "🌍", count: 251)] { #expect(throws: MuseMSPError.self) { _ = try typed.answerBody(selections: [:], notes: ["approach": note]) } }
    #expect(throws: MuseMSPError.self) { _ = try typed.answerBody(selections: ["approach": ["Small", "Small"]]) }
    #expect(throws: MuseMSPError.self) { _ = try typed.answerBody(selections: ["approach": ["invented"]]) }
    #expect(throws: MuseMSPError.self) { _ = try typed.answerBody(selections: ["wrong": ["Small"]]) }
}

@Test func museMSPFramingSplitsUTF8AcceptsCRLFAndRejectsUnterminatedOrOversizedFrames() throws {
    var parser = MuseMSPFramer(), values: [JSONValue] = []
    let data = Data("\r\n \t\r\n{\"value\":\"工作🌍\"}\r\n".utf8)
    for byte in data { values += try parser.append(Data([byte])) }
    try parser.finish(); #expect(values == [.object(["value": .string("工作🌍")])])
    var partial = MuseMSPFramer(); _ = try partial.append(Data("{}".utf8))
    #expect(throws: MuseMSPError.self) { try partial.finish() }
    var oversized = MuseMSPFramer()
    #expect(throws: MuseMSPError.self) { _ = try oversized.append(Data(repeating: 120, count: MuseProtocol.maximumFrameBytes + 1)) }
    var invalidUTF8 = MuseMSPFramer()
    #expect(throws: MuseMSPError.self) { _ = try invalidUTF8.append(Data([0xff, 10])) }
    var exact = MuseMSPFramer()
    var maximum = Data([34]); maximum.append(Data(repeating: 120, count: MuseProtocol.maximumFrameBytes - 2)); maximum.append(contentsOf: [34, 13])
    #expect(try exact.append(maximum).isEmpty)
    #expect(try exact.append(Data([10])).count == 1)
}

@Test func museMSPUUIDv7MintIsMonotonicDistinctAndCommandAdmissionPreservesActualTurnAuthority() throws {
    let ids = (0..<2_000).map { _ in MuseUUIDv7.make().uuidString.lowercased() }
    #expect(Set(ids).count == ids.count && ids == ids.sorted())
    for id in ids { #expect(try MuseProtocol.identity(.string(id), command: true) == id) }
    let result: JSONValue = .object(["commandId": .string(museT), "turnId": .string(museT), "status": .string("accepted"), "disposition": .string("queued"), "startedNewTurn": .bool(false)])
    #expect(try MuseProtocol.turnAdmission(result, expectedCommandID: museT).disposition == "queued")
    #expect(throws: MuseMSPError.self) { _ = try MuseProtocol.turnAdmission(result, expectedCommandID: museS) }
    #expect(throws: MuseMSPError.self) { _ = try MuseProtocol.identity(.string(UUID().uuidString), command: true) }
}
