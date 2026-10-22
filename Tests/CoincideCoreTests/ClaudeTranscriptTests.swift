import Foundation
import Testing
@testable import CoincideCore

private let claudeTranscriptSource = "11111111-1111-4111-8111-111111111111"
private let claudeTranscriptTarget = "22222222-2222-4222-8222-222222222222"

private func transcriptID(_ value: Int) -> String { String(format: "00000000-0000-4000-8000-%012x", value) }
private func transcriptRecord(_ type: String, _ id: Int, parent: Int? = nil, fields: [String: JSONValue] = [:]) -> JSONValue {
    var object: [String: JSONValue] = ["type": .string(type), "uuid": .string(transcriptID(id)),
        "sessionId": .string(claudeTranscriptSource), "parentUuid": parent.map { .string(transcriptID($0)) } ?? .null,
        "timestamp": .string(String(format: "2026-10-23T00:00:%02d.000Z", id % 60))]
    if type == "user" || type == "assistant" {
        object["message"] = .object(["id": .string("api-\(id)"), "role": .string(type), "content": .string("Text \(id)")])
    }
    object.merge(fields, uniquingKeysWith: { _, right in right }); return .object(object)
}
private func transcriptData(_ records: [JSONValue], finalNewline: Bool = true) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var data = Data()
    for (index, record) in records.enumerated() {
        data.append(try encoder.encode(record))
        if finalNewline || index < records.count - 1 { data.append(10) }
    }
    return data
}
private func transcriptParse(_ records: [JSONValue]) throws -> ClaudeTranscript { try .parse(transcriptData(records)) }
private func transcriptIDs(_ records: [JSONValue]) -> [String] { records.compactMap { $0["uuid"].string } }
private func transcriptPatch(_ record: JSONValue, _ fields: [String: JSONValue]) -> JSONValue {
    var object = record.object!; object.merge(fields, uniquingKeysWith: { _, right in right }); return .object(object)
}
private func transcriptToolResult(_ id: Int, parent: Int) -> JSONValue {
    let block: JSONValue = .object(["type": .string("tool_result"), "tool_use_id": .string("call-\(parent)"),
                                    "content": .string("result \(id)")])
    let message: JSONValue = .object(["role": .string("user"), "content": .array([block])])
    return transcriptRecord("user", id, parent: parent, fields: ["message": message])
}

@Test
func claudeTranscriptReaderSelectsRootChainAndRestoresParallelToolBranches() throws {
    let first = transcriptRecord("assistant", 2, parent: 1, fields: ["message": .object(["id": .string("same-api"), "content": .string("parallel one")])])
    let second = transcriptRecord("assistant", 3, parent: 1, fields: ["message": .object(["id": .string("same-api"), "content": .string("parallel two")])])
    let records = [transcriptRecord("user", 1), first, second,
        transcriptToolResult(4, parent: 2), transcriptToolResult(5, parent: 3), transcriptRecord("assistant", 6, parent: 5),
        transcriptRecord("assistant", 7, fields: ["isSidechain": .bool(true)]),
        transcriptRecord("system", 8, parent: 6, fields: ["subtype": .string("notice")])]
    let parsed = try transcriptParse(records)
    #expect(parsed.records == records)
    #expect(transcriptIDs(parsed.selectedMessages) == [1, 3, 2, 4, 5, 6].map(transcriptID))
    #expect(parsed.selectedMessages.allSatisfy { $0["session_id"].string == claudeTranscriptSource && $0["parent_tool_use_id"] == .null })
    let fork = try parsed.fork(upToMessageID: transcriptID(2), targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
    let native = fork.records.filter { $0["forkedFrom"].object != nil }
    #expect(native.count == 2)
    #expect(native.map { $0["forkedFrom"]["messageUuid"].string } == [transcriptID(1), transcriptID(2)])
    #expect(fork.headMessageID == fork.sourceToForkMessageIDs[transcriptID(2)])
    try parsed.validateFork(fork, upToMessageID: transcriptID(2), targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
}

@Test(arguments: [false, true])
func claudeTranscriptReaderStitchesBothNativeCompactionRepresentations(segment: Bool) throws {
    let metadata: JSONValue = segment
        ? .object(["preservedSegment": .object(["anchorUuid": .string(transcriptID(1)), "headUuid": .string(transcriptID(3)), "tailUuid": .string(transcriptID(4))])])
        : .object(["preservedMessages": .object(["anchorUuid": .string(transcriptID(1)), "uuids": .array([.string(transcriptID(3)), .string(transcriptID(4))])])])
    let boundary = transcriptRecord("system", 5, parent: 1, fields: ["subtype": .string("compact_boundary"), "compactMetadata": metadata])
    let records = [transcriptRecord("user", 1), transcriptRecord("assistant", 2, parent: 1),
        transcriptRecord("user", 3, parent: 2), transcriptRecord("assistant", 4, parent: 3), boundary,
        transcriptRecord("assistant", 6, parent: 1)]
    let parsed = try transcriptParse(records)
    #expect(transcriptIDs(parsed.selectedMessages) == [1, 3, 4, 6].map(transcriptID))
    #expect(parsed.selectedChainRecords.last?["parentUuid"].string == transcriptID(4))
    let fork = try parsed.fork(upToMessageID: nil, targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
    let copiedBoundary = try #require(fork.records.first { $0["subtype"].string == "compact_boundary" })
    // Pinned x9 spreads nested compactMetadata literally; only top-level links remap.
    #expect(copiedBoundary["compactMetadata"] == metadata)
    #expect(parsed.records == records)
    try parsed.validateFork(fork, upToMessageID: nil, targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
}

@Test(arguments: ["none", "messages", "segment"])
func claudeTranscriptDefaultReaderPrecompactThresholdPreservesRawForkInventory(preserved: String) throws {
    var metadata: [String: JSONValue] = [:]
    if preserved == "messages" {
        metadata["preservedMessages"] = .object(["anchorUuid": .string(transcriptID(1)), "uuids": .array([.string(transcriptID(2))])])
    } else if preserved == "segment" {
        metadata["preservedSegment"] = .object(["anchorUuid": .string(transcriptID(1)), "headUuid": .string(transcriptID(2)), "tailUuid": .string(transcriptID(2))])
    }
    var records = [transcriptRecord("user", 1, fields: ["nativePadding": .string(String(repeating: "x", count: 2_600_000))]),
        transcriptRecord("assistant", 2, parent: 1, fields: ["nativePadding": .string("")]),
        transcriptRecord("system", 3, parent: 2, fields: ["subtype": .string("compact_boundary"), "compactMetadata": .object(metadata)]),
        transcriptRecord("user", 4, parent: 3), transcriptRecord("assistant", 5, parent: 4)]
    let initialBytes = try transcriptData(records).count
    let padding = ClaudeTranscript.precompactThresholdBytes - initialBytes
    #expect(padding > 0 && padding < ClaudeTranscript.maximumLineBytes)
    records[1] = transcriptPatch(records[1], ["nativePadding": .string(String(repeating: "y", count: padding))])
    var exact = try transcriptData(records)
    #expect(exact.count == ClaudeTranscript.precompactThresholdBytes)
    let threshold = try ClaudeTranscript.parse(exact)
    #expect(transcriptIDs(threshold.selectedMessages) == [1, 2, 4, 5].map(transcriptID))
    exact.append(32) // Final whitespace changes byte length, never native records.
    let larger = try ClaudeTranscript.parse(exact)
    #expect(larger.records == records)
    let expected = preserved == "none" ? [4, 5] : [1, 2, 4, 5]
    #expect(transcriptIDs(larger.selectedMessages) == expected.map(transcriptID))
    if preserved == "none" {
        #expect(larger.selectedChainRecords.first?["uuid"].string == transcriptID(3))
    }
    let fullFork = try larger.fork(upToMessageID: nil, targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
    #expect(fullFork.records.filter { $0["forkedFrom"].object != nil }.count == records.count)
    #expect(fullFork.headMessageID == fullFork.sourceToForkMessageIDs[transcriptID(5)])
    let oldFork = try larger.fork(upToMessageID: transcriptID(2), targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
    #expect(oldFork.sourceToForkMessageIDs.count == 2)
    #expect(oldFork.headMessageID == oldFork.sourceToForkMessageIDs[transcriptID(2)])
}

@Test(arguments: ["plain", "forwarded", "unanswered", "collision"])
func claudeTranscriptQueuedInputProjectionAndNativeSourceAliasAreDistinct(mode: String) throws {
    var queued: [String: JSONValue] = ["type": .string("queued_command"), "prompt": .string("same text 工作 🌍"),
        "source_uuid": .string(transcriptID(mode == "collision" ? 1 : 11)),
        "origin": .object(["kind": .string("task-notification"), "subkind": .string("completed"), "privateDetail": .string("not projected")])]
    if mode == "forwarded" { queued["forwardedIntent"] = .object(["lineage": .string("native lineage"), "source": .string("typed")]) }
    var records = [transcriptRecord("user", 1), transcriptRecord("assistant", 2, parent: 1),
        transcriptRecord("attachment", 10, parent: 2, fields: ["attachment": .object(queued)])]
    if mode != "unanswered" { records.append(transcriptRecord("assistant", 12, parent: 10)) }
    let parsed = try transcriptParse(records)
    if mode == "plain" {
        let input = try #require(parsed.selectedMessages.first { $0["isQueuedCommand"] == .bool(true) })
        #expect(input["uuid"].string == transcriptID(11))
        #expect(input["message"]["content"].string == "same text 工作 🌍")
        #expect(input["origin"] == .object(["kind": .string("task-notification"), "subkind": .string("completed")]))
        #expect(parsed.selectedChainRecords.contains { $0["uuid"].string == transcriptID(10) })
        #expect(!parsed.selectedChainRecords.contains { $0["uuid"].string == transcriptID(11) })
        let fork = try parsed.fork(upToMessageID: transcriptID(11), targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
        #expect(fork.sourceToForkMessageIDs[transcriptID(10)] != nil)
        #expect(fork.sourceToForkMessageIDs[transcriptID(12)] == nil)
        #expect(fork.headMessageID == fork.sourceToForkMessageIDs[transcriptID(2)])
        try parsed.validateFork(fork, upToMessageID: transcriptID(11), targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
    } else { #expect(!parsed.selectedMessages.contains { $0["isQueuedCommand"] == .bool(true) }) }
}

@Test
func claudeTranscriptSDKHeadAndSelectedChainDoNotProvePostAssistantRawTail() throws {
    let tail = transcriptRecord("attachment", 3, parent: 2, fields: ["attachment": .object([
        "type": .string("structured_output"), "output": .object(["answer": .string("native result")])])])
    let parsed = try transcriptParse([transcriptRecord("user", 1), transcriptRecord("assistant", 2, parent: 1), tail])
    #expect(parsed.records.last?["uuid"].string == transcriptID(3))
    #expect(parsed.selectedChainRecords.last?["uuid"].string == transcriptID(2))
    #expect(parsed.selectedMessages.last?["uuid"].string == transcriptID(2))
    let fork = try parsed.fork(upToMessageID: transcriptID(3), targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
    let copiedTail = try #require(fork.records.first { $0["attachment"]["type"].string == "structured_output" })
    #expect(copiedTail["attachment"] == tail["attachment"])
    #expect(fork.headMessageID != copiedTail["uuid"].string)
}

@Test
func claudeTranscriptForkPreservesPinnedMetadataAndBypassesOmittedProgress() throws {
    let progress = transcriptRecord("progress", 2, parent: 1)
    let assistant = transcriptRecord("assistant", 3, parent: 2, fields: ["logicalParentUuid": .string(transcriptID(2)),
        "teamName": .string("old team"), "agentName": .string("old agent"), "sessionKind": .string("old"),
        "slug": .string("old slug"), "sourceToolAssistantUUID": .string(transcriptID(1)),
        "unknownNativeField": .object(["keep": .bool(true)])])
    let replacements: JSONValue = .array([.object(["uuid": .string(transcriptID(20)), "text": .string("literal future reference")])])
    let records = [transcriptRecord("user", 1), progress, assistant,
        transcriptRecord("system", 4, parent: 3, fields: ["subtype": .string("model_refusal_fallback")]),
        transcriptRecord("attachment", 5, parent: 4, fields: ["attachment": .object(["type": .string("deferred_tools_record"),
            "nameOnlyAnnouncements": .array([.string(transcriptID(1)), .string(transcriptID(99)), .number(1)])])]),
        .object(["type": .string("content-replacement"), "sessionId": .string(claudeTranscriptSource), "replacements": replacements]),
        .object(["type": .string("history-suppression"), "sessionId": .string(claudeTranscriptSource)]),
        .object(["type": .string("atis-latch"), "sessionId": .string(claudeTranscriptSource), "atis": .string("A1!")]),
        .object(["type": .string("relocated"), "sessionId": .string(claudeTranscriptSource), "relocatedCwd": .string("/fixture/native")]),
        .object(["type": .string("custom-title"), "sessionId": .string(claudeTranscriptSource), "customTitle": .string("Native title")]),
        .object(["type": .string("file-history-snapshot"), "snapshot": .object(["mustNotCopy": .bool(true)])])]
    let parsed = try transcriptParse(records)
    let fork = try parsed.fork(upToMessageID: nil, targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
    let copied = try #require(fork.records.first { $0["forkedFrom"]["messageUuid"].string == transcriptID(3) })
    #expect(copied["parentUuid"].string == fork.sourceToForkMessageIDs[transcriptID(1)])
    #expect(copied["logicalParentUuid"].string == fork.sourceToForkMessageIDs[transcriptID(2)])
    #expect(!fork.records.contains { $0["uuid"].string == fork.sourceToForkMessageIDs[transcriptID(2)] })
    #expect(copied["unknownNativeField"] == assistant["unknownNativeField"])
    #expect(["teamName", "agentName", "sessionKind", "slug", "sourceToolAssistantUUID"].allSatisfy { copied.object?[$0] == nil })
    #expect(fork.records.first { $0["type"].string == "content-replacement" }?["replacements"] == replacements)
    #expect(fork.records.first { $0["type"].string == "history-suppression" }?["cause"].string == "fork_inherit")
    #expect(fork.records.first { $0["subtype"].string == "model_refusal_fallback" }?["neutralizedByFork"] == .bool(true))
    #expect(!fork.records.contains { ["progress", "file-history-snapshot"].contains($0["type"].string ?? "") })
    #expect(fork.records.last?["customTitle"].string == "Native title (fork)")
    try parsed.validateFork(fork, upToMessageID: nil, targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
}

@Test(.timeLimit(.minutes(1)))
func claudeTranscriptForkMemoizesSharedProgressAncestryWithoutDroppingValidSiblings() throws {
    var records = [transcriptRecord("user", 1)]
    for id in 2...9_001 { records.append(transcriptRecord("progress", id, parent: id - 1)) }
    for id in 9_002...18_001 { records.append(transcriptRecord("assistant", id, parent: 9_001)) }
    let parsed = try transcriptParse(records)
    let fork = try parsed.fork(upToMessageID: nil, targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
    let copiedAssistants = fork.records.filter { $0["type"].string == "assistant" }
    #expect(copiedAssistants.count == 9_000)
    #expect(fork.sourceToForkMessageIDs.count == 18_001)
    #expect(copiedAssistants.allSatisfy { $0["parentUuid"].string == fork.sourceToForkMessageIDs[transcriptID(1)] })
    #expect(!fork.records.contains { $0["type"].string == "progress" })
    #expect(fork.headMessageID == fork.sourceToForkMessageIDs[transcriptID(18_001)])
    #expect(parsed.records == records)
    try parsed.validateFork(fork, upToMessageID: nil, targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
}

@Test(arguments: ["payload", "extra", "map", "head", "parent", "timestamp"])
func claudeTranscriptForkValidationRejectsSameCountOrForgedPublicationProof(change: String) throws {
    let parsed = try transcriptParse([transcriptRecord("user", 1), transcriptRecord("assistant", 2, parent: 1)])
    let fork = try parsed.fork(upToMessageID: nil, targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource, title: "  Reviewed title  ")
    var records = fork.records, mapping = fork.sourceToForkMessageIDs, head = fork.headMessageID
    switch change {
    case "payload": records[1] = transcriptPatch(records[1], ["message": .object(["content": .string("same count changed content")])])
    case "extra": records.append(.object(["type": .string("private-extra")]))
    case "map": mapping[transcriptID(1)] = transcriptID(90)
    case "head": head = mapping[transcriptID(1)]
    case "parent": records[1] = transcriptPatch(records[1], ["parentUuid": .null])
    case "timestamp": records[0] = transcriptPatch(records[0], ["timestamp": .string("2025-01-01T00:00:00.000Z")])
    default: break
    }
    let altered = ClaudeTranscriptFork(records: records, sourceToForkMessageIDs: mapping, headMessageID: head)
    #expect(throws: ClaudeTranscriptError.self) {
        try parsed.validateFork(altered, upToMessageID: nil, targetSessionID: claudeTranscriptTarget,
                                sourceSessionID: claudeTranscriptSource, title: "Reviewed title")
    }
    try parsed.validateFork(fork, upToMessageID: nil, targetSessionID: claudeTranscriptTarget,
                            sourceSessionID: claudeTranscriptSource, title: "Reviewed title")
}

@Test(arguments: ["duplicate", "cycle", "foreign", "invalidUUID", "wrongShape", "invalidJSON", "invalidUTF8"])
func claudeTranscriptMutationEvidenceExplicitlyRejectsSDKDisplayAmbiguities(change: String) throws {
    var records = [transcriptRecord("user", 1), transcriptRecord("assistant", 2, parent: 1)]
    switch change {
    case "duplicate": records.append(transcriptPatch(records[1], ["message": .object(["content": .string("legitimate-looking later UUID update")])]))
    case "cycle": records[0] = transcriptPatch(records[0], ["parentUuid": .string(transcriptID(2))])
    case "foreign": records[1] = transcriptPatch(records[1], ["sessionId": .string(claudeTranscriptTarget)])
    case "invalidUUID": records[1] = transcriptPatch(records[1], ["uuid": .string("api-message-id-is-not-a-transcript-uuid")])
    case "wrongShape": records[1] = transcriptPatch(records[1], ["parentUuid": .number(1)])
    default: break
    }
    var data = try transcriptData(records)
    if change == "invalidJSON" { data.append(Data("{truncated\n".utf8)) }
    if change == "invalidUTF8" { data.append(contentsOf: [0xff, 10]) }
    #expect(throws: ClaudeTranscriptError.self) { try ClaudeTranscript.parse(data) }
}

@Test(arguments: ["record", "session", "map"])
func claudeTranscriptRejectsCaseOnlyNativeUUIDOwnershipAliases(alias: String) throws {
    let alpha = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let first = transcriptPatch(transcriptRecord("user", 1), ["uuid": .string(alpha)])
    let second = transcriptPatch(transcriptRecord("assistant", 2), ["parentUuid": .string(alpha)])
    if alias == "record" {
        let duplicate = transcriptPatch(second, ["uuid": .string(alpha.uppercased()), "parentUuid": .null])
        #expect(throws: ClaudeTranscriptError(.ambiguous)) { try transcriptParse([first, second, duplicate]) }
    } else if alias == "session" {
        let records = [first, second].map { transcriptPatch($0, ["sessionId": .string(alpha)]) }
        let parsed = try transcriptParse(records)
        #expect(parsed.records == records) // Canonical comparison never rewrites native strings.
        #expect(throws: ClaudeTranscriptError(.invalidBoundary)) {
            try parsed.fork(upToMessageID: nil, targetSessionID: alpha.uppercased(), sourceSessionID: alpha)
        }
    } else {
        let parsed = try transcriptParse([first, second])
        let fork = try parsed.fork(upToMessageID: nil, targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
        var mapping = fork.sourceToForkMessageIDs
        mapping[transcriptID(2)] = mapping[alpha]!.uppercased()
        let altered = ClaudeTranscriptFork(records: fork.records, sourceToForkMessageIDs: mapping, headMessageID: fork.headMessageID)
        #expect(throws: ClaudeTranscriptError(.ambiguous)) {
            try parsed.validateFork(altered, upToMessageID: nil, targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
        }
    }
}

@Test(arguments: ["bytes", "line", "records"])
func claudeTranscriptRejectsBoundedInventoryOverflow(limit: String) throws {
    let data: Data
    switch limit {
    case "bytes": data = Data(repeating: 32, count: ClaudeTranscript.maximumBytes + 1)
    case "line": data = try transcriptData([.object(["type": .string("metadata"), "payload": .string(String(repeating: "x", count: ClaudeTranscript.maximumLineBytes))])])
    default: data = try transcriptData(Array(repeating: .object(["type": .string("metadata")]), count: ClaudeTranscript.maximumRecords + 1))
    }
    #expect(throws: ClaudeTranscriptError(.limitExceeded)) { try ClaudeTranscript.parse(data) }
}

@Test
func claudeTranscriptAcceptsFinalNonNewlineAndRejectsForeignOrUnavailableForkBoundary() throws {
    let records = [transcriptRecord("user", 1), transcriptRecord("assistant", 2, parent: 1)]
    let parsed = try ClaudeTranscript.parse(transcriptData(records, finalNewline: false))
    #expect(parsed.records == records)
    #expect(throws: ClaudeTranscriptError(.invalidBoundary)) {
        try parsed.fork(upToMessageID: transcriptID(99), targetSessionID: claudeTranscriptTarget, sourceSessionID: claudeTranscriptSource)
    }
    #expect(throws: ClaudeTranscriptError(.invalidBoundary)) {
        try parsed.fork(upToMessageID: nil, targetSessionID: claudeTranscriptTarget, sourceSessionID: transcriptID(99))
    }
    #expect(throws: ClaudeTranscriptError(.invalidBoundary)) {
        try parsed.fork(upToMessageID: nil, targetSessionID: claudeTranscriptSource, sourceSessionID: claudeTranscriptSource)
    }
}
