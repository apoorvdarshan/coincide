import Foundation
import Testing
@testable import CoincideKit

private let importSessionID = "a0000000-0000-0000-0000-000000000001"
private let importSource = URL(fileURLWithPath: "/tmp/synthetic-session.jsonl")
private func jsonl(_ records: [[String: Any]]) throws -> Data {
    var result = Data()
    for record in records { result.append(try JSONSerialization.data(withJSONObject: record)); result.append(10) }
    return result
}
private func claudeRecord(_ id: String, parent: String? = nil, role: String, content: Any) -> [String: Any] {
    var value: [String: Any] = ["uuid": id, "sessionId": importSessionID, "cwd": "/tmp/import-project", "type": role,
        "timestamp": "2026-10-28T10:00:00.123Z", "message": ["role": role, "content": content]]
    if let parent { value["parentUuid"] = parent }
    return value
}
private func codexRecord(_ type: String, _ payload: [String: Any]) -> [String: Any] {
    ["type": type, "timestamp": "2026-10-28T10:00:00Z", "payload": payload]
}
private func codexFixture() throws -> Data {
    try jsonl([
        codexRecord("session_meta", ["id": importSessionID, "cwd": "/tmp/import-project", "git": ["branch": "feature"]]),
        codexRecord("turn_context", ["model": "gpt-test", "approval_policy": "never"]),
        codexRecord("event_msg", ["type": "user_message", "message": "duplicate event"]),
        codexRecord("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fix the importer"]]]),
        codexRecord("response_item", ["type": "function_call", "call_id": "c", "name": "read_file", "arguments": "file.txt"]),
        codexRecord("response_item", ["type": "function_call_output", "call_id": "c", "output": "contents"]),
        codexRecord("response_item", ["type": "message", "role": "assistant", "id": "a", "content": [["type": "output_text", "text": "Fixed it"]]]),
        codexRecord("response_item", ["type": "message", "role": "assistant", "id": "a", "content": [["type": "output_text", "text": "Fixed it"]]]),
        codexRecord("future_event", ["future": ["value": 42]]),
    ])
}

struct CLISessionImportTests {
    @Test func codexUsesCanonicalMessagesAndPairsToolsWithoutDuplicatingEvents() throws {
        let data = try codexFixture()
        let value = try CLISessionImport.parse(data, sourceURL: importSource)
        #expect(value.provider == .codex && value.sessionID == importSessionID)
        #expect(value.directory.path == "/tmp/import-project" && value.modelID == "gpt-test" && value.branch == "feature")
        #expect(value.items.map(\.kind) == [.user, .tool, .assistant])
        #expect(value.items.map(\.text) == ["Fix the importer", "contents", "Fixed it"])
        #expect(value.items[1].status == .completed && value.omittedRecords == 1)
        #expect(value.sourceData == data)
    }

    @Test func claudeImportsLatestAncestryAndRetainsToolResultsAndUnknownSourceBytes() throws {
        var side = claudeRecord("side", parent: "u", role: "assistant", content: "subagent private branch")
        side["isSidechain"] = true
        let data = try jsonl([
            claudeRecord("u", role: "user", content: "root"),
            claudeRecord("old", parent: "u", role: "assistant", content: "old branch"),
            side,
            claudeRecord("new", parent: "u", role: "assistant", content: [
                ["type": "thinking", "thinking": "reason"], ["type": "text", "text": "new branch"],
                ["type": "tool_use", "id": "c", "name": "Read", "input": ["path": "a.swift"]]]),
            claudeRecord("result", parent: "new", role: "user", content: [["type": "tool_result", "tool_use_id": "c", "content": "tool failed", "is_error": true]]),
            claudeRecord("end", parent: "result", role: "assistant", content: [["type": "text", "text": "done"], ["type": "future", "data": "original"]]),
        ])
        let value = try CLISessionImport.parse(data, sourceURL: importSource)
        #expect(value.items.map(\.kind) == [.user, .reasoning, .assistant, .tool, .assistant])
        #expect(value.items.map(\.text) == ["root", "reason", "new branch", "tool failed", "done"])
        #expect(value.items[3].status == .failed && value.omittedRecords == 2)
        #expect(value.sourceData == data)
    }

    @Test func claudeTraversesSystemNodesBetweenMessagesAndRejectsCycles() throws {
        let root = claudeRecord("u", role: "user", content: "root")
        let system: [String: Any] = ["uuid": "s", "parentUuid": "u", "type": "system", "sessionId": importSessionID]
        let reply = claudeRecord("a", parent: "s", role: "assistant", content: "reply")
        let value = try CLISessionImport.parse(jsonl([root, system, reply]), sourceURL: importSource)
        #expect(value.items.map(\.text) == ["root", "reply"])
        #expect(throws: CLISessionImportError.self) {
            try CLISessionImport.parse(jsonl([claudeRecord("u", parent: "a", role: "user", content: "root"), reply,
                ["uuid": "s", "parentUuid": "u", "type": "system"]]), sourceURL: importSource)
        }
    }

    @Test func rollbackDropsOnlyTheRetractedTurnsAndEventOnlyOlderSessionsStillLoad() throws {
        let data = try jsonl([
            codexRecord("session_meta", ["id": importSessionID, "cwd": "/tmp"]),
            codexRecord("event_msg", ["type": "user_message", "message": "keep"]),
            codexRecord("event_msg", ["type": "agent_message", "message": "kept answer"]),
            codexRecord("event_msg", ["type": "user_message", "message": "remove"]),
            codexRecord("event_msg", ["type": "agent_message", "message": "removed answer"]),
            codexRecord("event_msg", ["type": "thread_rolled_back", "num_turns": 1]),
        ])
        #expect(try CLISessionImport.parse(data, sourceURL: importSource).items.map(\.text) == ["keep", "kept answer"])
    }

    @Test func invalidIdentityOversizeAndMalformedSessionsFailWithoutGuessing() throws {
        for records in [
            [codexRecord("session_meta", ["id": "not-a-session", "cwd": "/tmp"])],
            [codexRecord("session_meta", ["id": importSessionID, "cwd": "relative"])],
            [codexRecord("session_meta", ["id": importSessionID, "cwd": "/tmp"]), codexRecord("session_meta", ["id": UUID().uuidString, "cwd": "/tmp"])],
        ] {
            #expect(throws: CLISessionImportError.self) { try CLISessionImport.parse(jsonl(records), sourceURL: importSource) }
        }
        #expect(throws: CLISessionImportError.self) { try CLISessionImport.parse(Data("garbage\n[]\n".utf8), sourceURL: importSource) }
        #expect(throws: CLISessionImportError.self) { try CLISessionImport.parse(Data(repeating: 32, count: CLISessionImport.maximumRecordBytes + 1), sourceURL: importSource) }
        #expect(throws: CLISessionImportError.self) { try CLISessionImport.parse(Data(repeating: 10, count: CLISessionImport.maximumBytes + 1), sourceURL: importSource) }
        #expect(throws: CLISessionImportError.self) {
            try CLISessionImport.parse(Data(String(repeating: "{}\n", count: 100_001).utf8), sourceURL: importSource)
        }
        var partial = try codexFixture()
        partial.append(Data("{truncated".utf8))
        let preview = try CLISessionImport.parse(partial, sourceURL: importSource)
        #expect(preview.omittedRecords == 2 && preview.items.count == 3 && preview.sourceData == partial)
    }

    @Test func hugeTextAndUnfinishedToolsAreExplicitlyMarked() throws {
        let value = try CLISessionImport.parse(jsonl([
            claudeRecord("u", role: "user", content: String(repeating: "x", count: 100_001)),
            claudeRecord("a", parent: "u", role: "assistant", content: [["type": "tool_use", "id": "c", "name": "Read", "input": [:]]]),
        ]), sourceURL: importSource)
        #expect(value.shortenedText && value.items[0].text.count == 100_002)
        #expect(value.items[1].status == .failed && !value.items[1].text.isEmpty)
    }

    @Test func scannerReadsOnlyHistoryRootsSkipsSymlinksAndSubagentsAndHonorsLimits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("subagents"), withIntermediateDirectories: true)
        let data = try codexFixture()
        try data.write(to: directory.appendingPathComponent("one.jsonl"))
        try data.write(to: directory.appendingPathComponent("subagents/hidden.jsonl"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias.jsonl"), withDestinationURL: directory.appendingPathComponent("one.jsonl"))
        let scan = try CLISessionScanner.scan(roots: [.codex: [directory]])
        #expect(scan.candidates.count == 1 && scan.candidates[0].title == "Fix the importer")
        #expect(scan.candidates[0].directory == "/tmp/import-project")
        #expect(try CLISessionScanner.scan(roots: [.codex: [directory]], limit: 0).incomplete)
        #expect(throws: CLISessionImportError.self) { try CLISessionImport.read(directory.appendingPathComponent("alias.jsonl")) }
    }
}

@MainActor
struct CLISessionImportStoreTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-import-\(UUID().uuidString)")

    @Test func explicitImportPersistsIdentitySourceAndHandoffAndDetectsDuplicatesAfterRestartAndRewind() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try codexFixture()
        let preview = try CLISessionImport.parse(data, sourceURL: importSource)
        let store = AppStore(directory: directory)
        #expect(store.threadSummaries.isEmpty)
        let id = try store.importSession(preview)
        store.flush()
        let reopened = AppStore(directory: directory)
        let thread = try #require(reopened.thread(id))
        #expect(thread.accessMode == .approval && thread.items == preview.items)
        #expect(thread.sessions[.codex]?.sessionID == importSessionID && thread.sessions[.codex]?.seenItemCount == preview.items.count)
        #expect(reopened.project(thread.projectID)?.path == "/tmp/import-project")
        #expect(thread.importedSession?.sourcePath == importSource.path)
        #expect(Handoff.missedItems(in: thread, for: .codex).isEmpty)
        #expect(Handoff.recap(thread: thread, provider: .claude)?.contains("Fix the importer") == true)
        #expect(try Data(contentsOf: #require(reopened.importedSourceURL(for: id))) == data)
        #expect(try reopened.importSession(preview) == id && reopened.threadSummaries.count == 1)
        reopened.truncate(id, from: thread.items[1].id)
        #expect(try reopened.importSession(preview) == id)
        reopened.flush()
        #expect(AppStore(directory: directory).threadForSession(provider: .codex, sessionID: importSessionID.uppercased()) == id)
    }

    @Test func existingNativeSessionIsReusedAndRawArchiveFollowsDeleteAndUndo() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let preview = try CLISessionImport.parse(codexFixture(), sourceURL: importSource)
        let project = store.addProject(at: preview.directory)
        let existing = store.createThread(in: project.id)
        store.updateThread(existing.id) { $0.sessions[.codex] = .init(sessionID: importSessionID, seenItemCount: 0); $0.isArchived = true }
        #expect(try store.importSession(preview) == existing.id)
        store.deleteThread(existing.id)
        let id = try store.importSession(preview)
        let archive = try #require(store.importedSourceURL(for: id))
        let snapshot = try #require(try store.deleteThreadForUndo(id))
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(try store.restoreDeletedThread(snapshot))
        #expect(try Data(contentsOf: archive) == preview.sourceData)
        #expect(store.threadForSession(provider: .codex, sessionID: importSessionID) == id)
    }

    @Test func failingArchiveWriteDoesNotPublishAPartialImport() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        try Data("block directory".utf8).write(to: directory.appendingPathComponent("ImportedSessions"))
        let preview = try CLISessionImport.parse(codexFixture(), sourceURL: importSource)
        #expect(throws: (any Error).self) { try store.importSession(preview) }
        #expect(store.projects.isEmpty && store.threadSummaries.isEmpty)
    }

    @Test func undoPreservesArchiveEvenWhenFutureProvenanceCannotBeDecoded() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try codexFixture()
        let store = AppStore(directory: directory)
        let id = try store.importSession(CLISessionImport.parse(data, sourceURL: importSource))
        let archive = try #require(store.importedSourceURL(for: id))
        store.flush()
        let url = directory.appendingPathComponent("threads/\(id.uuidString).json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["importedSession"] = ["provider": "future-provider", "futureData": ["keep": "original"]]
        let future = try JSONSerialization.data(withJSONObject: object)
        try future.write(to: url)
        let reopened = AppStore(directory: directory)
        #expect(reopened.summary(id)?.importedSession == nil)
        let snapshot = try #require(try reopened.deleteThreadForUndo(id))
        reopened.flush()
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(try reopened.restoreDeletedThread(snapshot))
        #expect(try Data(contentsOf: archive) == data)
        #expect(try Data(contentsOf: url) == future)
    }

    @Test func undoDoesNotOverwriteAnExternallyRecreatedThreadFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let id = try store.importSession(CLISessionImport.parse(codexFixture(), sourceURL: importSource))
        let snapshot = try #require(try store.deleteThreadForUndo(id))
        store.flush()
        let url = directory.appendingPathComponent("threads/\(id.uuidString).json")
        let recreated = Data("externally recreated contents".utf8)
        try recreated.write(to: url)
        #expect(throws: CocoaError.self) { try store.restoreDeletedThread(snapshot) }
        #expect(try Data(contentsOf: url) == recreated)
        try FileManager.default.removeItem(at: url)
        #expect(try store.restoreDeletedThread(snapshot))
    }

    @Test func unknownProvenanceFieldsTriggerPreservationWhileKnownFieldsRoundTrip() throws {
        let store = AppStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try store.importSession(CLISessionImport.parse(codexFixture(), sourceURL: importSource))
        let url = directory.appendingPathComponent("threads/\(id.uuidString).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[.checksUnreadContent] = true
        let data = try Data(contentsOf: url)
        #expect(try !decoder.decode(ThreadFile.self, from: data).hasUnreadContent)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var provenance = try #require(object["importedSession"] as? [String: Any])
        provenance["future"] = 1
        object["importedSession"] = provenance
        let future = try JSONSerialization.data(withJSONObject: object)
        #expect(try decoder.decode(ThreadFile.self, from: future).hasUnreadContent)
        #expect(try decoder.decode(ThreadSummaryFile.self, from: data).summary == ThreadSummary(decoder.decode(ThreadFile.self, from: data).thread))
    }
}
