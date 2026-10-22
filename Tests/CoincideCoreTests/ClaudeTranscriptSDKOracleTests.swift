import Foundation
import Testing
@testable import CoincideCore

/// Expected values were produced independently by the exact pinned public SDK
/// against synthetic files. CI needs neither Node nor an installed Claude CLI.
@Test
func claudeTranscriptMatchesPinnedSDKReaderAndInclusiveForkOracle() throws {
    let fixture = try #require(Bundle.module.url(forResource: "claude_history_sdk_0_3_276", withExtension: "json", subdirectory: "Fixtures"))
    let oracle = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture))
    #expect(oracle["sdkVersion"] == .string("0.3.276"))
    #expect(oracle["blockedCalls"] == .number(0))
    let cases = try #require(oracle["cases"].array)
    #expect(cases.count == 7)
    for item in cases {
        let name = try #require(item["name"].string)
        let rows = try #require(item["rows"].array)
        var data = Data()
        for row in rows { data.append(try JSONEncoder().encode(row)); data.append(10) }
        let transcript = try ClaudeTranscript.parse(data)
        #expect(transcript.selectedMessages == item["expectedMessages"].array, "SDK reader: \(name)")
        let forked = try transcript.fork(upToMessageID: item["cutoff"].string,
            targetSessionID: "cccccccc-cccc-cccc-cccc-cccccccccccc", sourceSessionID: try #require(item["sessionID"].string))
        #expect(normalizeClaudeOracleFork(forked.records) == item["expectedForkRecords"].array, "SDK inclusive fork: \(name)")
    }
}

/// Random target/message UUIDs and fork-time timestamps differ between runs.
/// Native parent/content/lineage/metadata payloads and record order remain exact.
private func normalizeClaudeOracleFork(_ records: [JSONValue]) -> [JSONValue] {
    let reverse = Dictionary(uniqueKeysWithValues: records.compactMap { record -> (String, String)? in
        guard let uuid = record["uuid"].string, let original = record["forkedFrom"]["messageUuid"].string else { return nil }
        return (uuid, original)
    })
    return records.map { record in
        var object = record.object ?? [:]
        object.removeValue(forKey: "uuid"); object.removeValue(forKey: "timestamp")
        if object["sessionId"] != nil { object["sessionId"] = .string("$target") }
        for key in ["parentUuid", "logicalParentUuid"] {
            if let id = object[key]?.string { object[key] = .string(reverse[id] ?? "$unmapped") }
        }
        if object["type"] == .string("history-suppression") { object.removeValue(forKey: "ts") }
        if var attachment = object["attachment"]?.object {
            if attachment["type"] == .string("queued_command"), let id = attachment["source_uuid"]?.string, let original = reverse[id] {
                attachment["source_uuid"] = .string(original)
            }
            if attachment["type"] == .string("deferred_tools_record"), let announcements = attachment["nameOnlyAnnouncements"]?.array {
                attachment["nameOnlyAnnouncements"] = .array(announcements.map { .string($0.string.flatMap { reverse[$0] } ?? "$unmapped") })
            }
            object["attachment"] = .object(attachment)
        }
        return .object(object)
    }
}
