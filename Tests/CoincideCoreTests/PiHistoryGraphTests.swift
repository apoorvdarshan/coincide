import Darwin
import Foundation
import Testing
@testable import CoincideCore

private enum PiGraphFixture {
    static let timestamp = "2026-10-23T00:00:00.000Z"
    static func header(workspace: String = "/workspace", id: String = "native-session-1") -> JSONValue {
        .object(["type": .string("session"), "version": .number(3), "id": .string(id),
            "cwd": .string(workspace), "timestamp": .string(timestamp)])
    }
    static func entry(_ id: String, parent: String? = nil, type: String = "message", fields: [String: JSONValue] = [:]) -> JSONValue {
        var row: [String: JSONValue] = ["type": .string(type), "id": .string(id), "parentId": parent.map(JSONValue.string) ?? .null,
            "timestamp": .string(timestamp)]
        for (key, value) in fields { row[key] = value }
        if type == "message", row["message"] == nil { row["message"] = .object(["role": .string("user"), "content": .string("Exact input 工作 😀 e\u{301}")]) }
        return .object(row)
    }
    static func assistant(_ id: String, parent: String?) -> JSONValue {
        entry(id, parent: parent, fields: ["message": .object(["role": .string("assistant"), "provider": .string("test-provider"),
            "model": .string("same-model"), "content": .array([.object(["type": .string("text"), "text": .string("Native answer")])])])])
    }
    static func replacing(_ row: JSONValue, key: String, value: JSONValue?) -> JSONValue {
        var object = row.object ?? [:]; object[key] = value; return .object(object)
    }
    static func data(_ rows: [JSONValue]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for row in rows { data.append(try encoder.encode(row)); data.append(10) }
        return data
    }
    static func graph(_ rows: [JSONValue], leaf: String?) throws -> PiHistoryGraph {
        try .init(header: header(), entries: rows, leafID: leaf)
    }
}

@Test func piHistoryGraphSeparatesAppendInventoryRuntimeLeafAndReloadedLeafWithoutRewritingIDs() throws {
    let rows = [PiGraphFixture.entry("root-user"), PiGraphFixture.assistant("shared-answer", parent: "root-user"),
        PiGraphFixture.entry("active-user", parent: "shared-answer"), PiGraphFixture.assistant("active-answer", parent: "active-user"),
        PiGraphFixture.entry("abandoned-user", parent: "shared-answer"), PiGraphFixture.assistant("abandoned-answer", parent: "abandoned-user")]
    let active = try PiGraphFixture.graph(rows, leaf: "active-answer")
    #expect(active.entries.map(\.id) == ["root-user", "shared-answer", "active-user", "active-answer", "abandoned-user", "abandoned-answer"])
    #expect(active.activeBranch.map(\.id) == ["root-user", "shared-answer", "active-user", "active-answer"])
    #expect(try active.branch(through: "abandoned-answer").map(\.id) == ["root-user", "shared-answer", "abandoned-user", "abandoned-answer"])
    #expect(active.entries.map(\.raw) == rows && active.leafOrigin == .runtime)
    let reloaded = try PiHistoryGraph.parse(PiGraphFixture.data([PiGraphFixture.header()] + rows))
    #expect(reloaded.leafOrigin == .reloadedFile && reloaded.leafID == "abandoned-answer")
    #expect(reloaded.inventoryDigest == active.inventoryDigest)
    #expect(try reloaded.activeBranchDigest != active.activeBranchDigest)
    let reset = try PiGraphFixture.graph(rows, leaf: nil)
    #expect(reset.activeBranch.isEmpty && reset.contextEntries.isEmpty)
    let empty = try PiHistoryGraph.parse(PiGraphFixture.data([PiGraphFixture.header()]))
    #expect(empty.entries.isEmpty && empty.leafID == nil && empty.leafOrigin == .reloadedFile)
}

@Test func piHistoryGraphProjectsLatestActiveCompactionCustomStateAndBranchSummaryExactly() throws {
    let rows = [PiGraphFixture.entry("u1"), PiGraphFixture.assistant("a1", parent: "u1"), PiGraphFixture.entry("u2", parent: "a1"),
        PiGraphFixture.assistant("a2", parent: "u2"),
        PiGraphFixture.entry("c1", parent: "a2", type: "compaction", fields: ["summary": .string("Earlier summary"), "firstKeptEntryId": .string("u2"), "tokensBefore": .number(120)]),
        PiGraphFixture.entry("state", parent: "c1", type: "custom", fields: ["customType": .string("private-extension-state"), "data": .object(["opaque": .string("retained only as native payload")])]),
        PiGraphFixture.entry("custom-message", parent: "state", type: "custom_message", fields: ["customType": .string("extension-note"), "content": .string("Native context note"), "display": .bool(false)]),
        PiGraphFixture.entry("summary", parent: "custom-message", type: "branch_summary", fields: ["summary": .string("Inherited branch"), "fromId": .string("a1")]),
        PiGraphFixture.entry("label", parent: "summary", type: "label", fields: ["targetId": .string("u2"), "label": .string("Retained marker")]),
        PiGraphFixture.entry("info", parent: "label", type: "session_info", fields: ["name": .string("Native title")]),
        PiGraphFixture.entry("u3", parent: "info"),
        PiGraphFixture.entry("c2", parent: "u3", type: "compaction", fields: ["summary": .string("Latest summary"), "firstKeptEntryId": .string("summary"), "tokensBefore": .number(240)]),
        PiGraphFixture.assistant("a3", parent: "c2"),
        PiGraphFixture.entry("abandoned-compaction", parent: "a1", type: "compaction", fields: ["summary": .string("Wrong branch"), "firstKeptEntryId": .string("u1"), "tokensBefore": .number(999)])]
    let first = try PiGraphFixture.graph(rows, leaf: "u3")
    #expect(first.contextEntries.map(\.id) == ["c1", "u2", "a2", "state", "custom-message", "summary", "label", "info", "u3"])
    #expect(first.contextMessageEntries.map(\.id) == ["c1", "u2", "a2", "custom-message", "summary", "u3"])
    #expect(first.contextMessageEntries.filter(\.isUserMessage).map(\.id) == ["u2", "u3"])
    let latest = try PiGraphFixture.graph(rows, leaf: "a3")
    #expect(latest.contextEntries.map(\.id) == ["c2", "summary", "label", "info", "u3", "a3"])
    #expect(latest.contextMessageEntries.map(\.id) == ["c2", "summary", "u3", "a3"])
    #expect(latest.activeBranch.first?.id == "u1")
    #expect(latest.entries.map(\.raw) == rows)
    #expect(try first.contextDigest != latest.contextDigest)
    let offBranchKept = PiGraphFixture.replacing(rows[4], key: "firstKeptEntryId", value: .string("abandoned-compaction"))
    let off = try PiGraphFixture.graph(Array(rows.prefix(4)) + [offBranchKept], leaf: "c1")
    #expect(off.contextEntries.map(\.id) == ["c1"])
    #expect(off.contextMessageEntries.filter(\.isUserMessage).isEmpty)
}

@Test func piHistoryGraphExclusiveUserCutRetainsInheritedContextAndNeverUsesCustomMessagesOrClocks() throws {
    let rows = [PiGraphFixture.entry("inherited-user"), PiGraphFixture.assistant("inherited-answer", parent: "inherited-user"),
        PiGraphFixture.entry("local-user", parent: "inherited-answer"), PiGraphFixture.assistant("local-answer", parent: "local-user"),
        PiGraphFixture.entry("extension", parent: "local-answer", type: "custom_message", fields: ["customType": .string("context"), "content": .string("Not an original input"), "display": .bool(true)]),
        PiGraphFixture.entry("discard-user", parent: "extension"), PiGraphFixture.entry("abandoned", parent: "inherited-answer")]
    let graph = try PiGraphFixture.graph(rows, leaf: "discard-user")
    let prefix = try graph.retainedPrefix(beforeUserEntryID: "local-user")
    #expect(prefix.map(\.id) == ["inherited-user", "inherited-answer"] && prefix.map(\.raw) == Array(rows.prefix(2)))
    #expect(try graph.retainedPrefix(beforeUserEntryID: "discard-user").map(\.id) == ["inherited-user", "inherited-answer", "local-user", "local-answer", "extension"])
    #expect(try graph.retainedPrefix(beforeUserEntryID: "inherited-user").isEmpty)
    #expect(throws: PiHistoryGraphError(.invalidGraph)) { try graph.retainedPrefix(beforeUserEntryID: "extension") }
    #expect(throws: PiHistoryGraphError(.invalidGraph)) { try graph.retainedPrefix(beforeUserEntryID: "abandoned") }
}

@Test func piHistoryGraphProspectiveWindowRequiresAppendProofAndExactAncestorWithoutAttributingAbandonedInputs() throws {
    let initial = [PiGraphFixture.entry("initial"), PiGraphFixture.assistant("baseline", parent: "initial")]
    let before = try PiGraphFixture.graph(initial, leaf: "baseline")
    let rows = initial + [PiGraphFixture.entry("opening", parent: "baseline"), PiGraphFixture.entry("steered-identical-text", parent: "opening"),
        PiGraphFixture.assistant("completed", parent: "steered-identical-text"), PiGraphFixture.entry("abandoned-new-input", parent: "baseline")]
    let after = try PiGraphFixture.graph(rows, leaf: "completed"), window = try after.appendedActiveWindow(since: before)
    #expect(window.entryIDs == ["opening", "steered-identical-text", "completed"])
    #expect(window.userEntryIDs == ["opening", "steered-identical-text"] && window.openingUserEntryID == "opening")
    #expect(window.beforeInventoryDigest == before.inventoryDigest && window.afterInventoryDigest == after.inventoryDigest)
    #expect(window.baselineLeafID == "baseline" && window.leafID == "completed")
    #expect(try PiGraphFixture.graph(rows, leaf: "baseline").appendedActiveWindow(since: before).entryIDs.isEmpty)
    let originalChanged = PiGraphFixture.replacing(initial[0], key: "message", value: .object(["role": .string("user"), "content": .string("Changed old input with unchanged ID")]))
    #expect(throws: PiHistoryGraphError(.invalidWindow)) { try PiGraphFixture.graph([originalChanged] + Array(rows.dropFirst()), leaf: "completed").appendedActiveWindow(since: before) }
    #expect(throws: PiHistoryGraphError(.invalidWindow)) { try PiGraphFixture.graph(rows, leaf: "initial").appendedActiveWindow(since: before) }
    let otherSession = try PiHistoryGraph(header: PiGraphFixture.header(id: "another-session"), entries: rows, leafID: "completed")
    #expect(throws: PiHistoryGraphError(.invalidWindow)) { try otherSession.appendedActiveWindow(since: before) }
    let fileBaseline = try PiHistoryGraph.parse(PiGraphFixture.data([PiGraphFixture.header()] + initial))
    #expect(throws: PiHistoryGraphError(.invalidWindow)) { try after.appendedActiveWindow(since: fileBaseline) }
    let fileAfter = try PiHistoryGraph.parse(PiGraphFixture.data([PiGraphFixture.header()] + rows))
    #expect(throws: PiHistoryGraphError(.invalidWindow)) { try fileAfter.appendedActiveWindow(since: before) }
    let empty = try PiGraphFixture.graph([], leaf: nil)
    let metadata = PiGraphFixture.entry("settings", type: "thinking_level_change", fields: ["thinkingLevel": .string("high")])
    let noInput = try PiGraphFixture.graph([metadata], leaf: "settings").appendedActiveWindow(since: empty)
    #expect(noInput.entryIDs == ["settings"] && noInput.userEntryIDs.isEmpty && noInput.openingUserEntryID == nil)
}

@Test(arguments: ["duplicate", "missing", "cycle", "abandonedCycle", "leaf", "parentType", "missingParent", "unknown", "labelTarget"])
func piHistoryGraphRejectsAmbiguousOrBrokenFullInventories(kind: String) throws {
    let first = PiGraphFixture.entry("first"), second = PiGraphFixture.assistant("second", parent: "first")
    var rows = [first, second], leaf = "second"
    switch kind {
    case "duplicate": rows.append(second)
    case "missing": rows[1] = PiGraphFixture.replacing(second, key: "parentId", value: .string("missing"))
    case "cycle": rows[0] = PiGraphFixture.replacing(first, key: "parentId", value: .string("second"))
    case "abandonedCycle": rows += [PiGraphFixture.entry("orphan-a", parent: "orphan-b"), PiGraphFixture.entry("orphan-b", parent: "orphan-a")]
    case "leaf": leaf = "unknown-leaf"
    case "parentType": rows[1] = PiGraphFixture.replacing(second, key: "parentId", value: .number(1))
    case "missingParent": rows[1] = PiGraphFixture.replacing(second, key: "parentId", value: nil)
    case "unknown": rows.append(PiGraphFixture.entry("future", parent: "second", type: "unknown_future_type"))
    default: rows.append(PiGraphFixture.entry("label", parent: "second", type: "label", fields: ["targetId": .string("missing"), "label": .string("ambiguous")]))
    }
    #expect(throws: PiHistoryGraphError.self) { try PiGraphFixture.graph(rows, leaf: leaf) }
}

@Test func piHistoryGraphStrictReadRefusesMigrationMalformedUTF8AndUnboundedDecodeWhileKeepingOpaquePayload() throws {
    let header = PiGraphFixture.header()
    let unsupported: [JSONValue] = [.null, .number(1), .number(2), .number(4), .string("3")]
    for version in unsupported {
        #expect(throws: PiHistoryGraphError(.unsupportedVersion)) { try PiHistoryGraph.parse(PiGraphFixture.data([PiGraphFixture.replacing(header, key: "version", value: version)])) }
    }
    let invalidHeaders = [PiGraphFixture.replacing(header, key: "id", value: .string("../another-session")),
        PiGraphFixture.replacing(header, key: "cwd", value: .string("relative")), PiGraphFixture.replacing(header, key: "timestamp", value: .string("not-a-clock"))]
    for invalid in invalidHeaders { #expect(throws: PiHistoryGraphError.self) { try PiHistoryGraph.parse(PiGraphFixture.data([invalid])) } }
    let row = PiGraphFixture.entry("u", fields: ["extensionData": .object(["literal": .string("עברית 工作 😀 e\u{301}"), "list": .array([.number(1), .bool(false), .null])])])
    let original = try PiGraphFixture.data([header, row]), parsed = try PiHistoryGraph.parse(original)
    #expect(parsed.entries.first?.raw == row)
    #expect(try PiHistoryGraph.parse(original + Data("\r\n \t\n".utf8)).inventoryDigest == parsed.inventoryDigest)
    #expect(throws: PiHistoryGraphError.self) { try PiHistoryGraph.parse(original + Data([255, 10])) }
    #expect(throws: PiHistoryGraphError.self) { try PiHistoryGraph.parse(original + Data("{malformed}\n".utf8)) }
    let repeatedKey = Data(#"{"type":"session","version":3,"id":"first","\u0069d":"second","cwd":"/workspace","timestamp":"2026-10-23T00:00:00.000Z"}"#.utf8)
    #expect(throws: PiHistoryGraphError(.invalidEntry)) { try PiHistoryGraph.parse(repeatedKey) }
    #expect(throws: PiHistoryGraphError.self) { try PiHistoryGraph.parse(PiGraphFixture.data([header, row, header])) }
    #expect(throws: PiHistoryGraphError(.oversized)) { try PiHistoryGraph.parse(Data(repeating: 32, count: PiHistoryGraph.maximumBytes + 1)) }
    #expect(throws: PiHistoryGraphError(.oversized)) { try PiHistoryGraph.parse(Data(repeating: 32, count: PiHistoryGraph.maximumLineBytes + 1)) }
    #expect(throws: PiHistoryGraphError(.oversized)) {
        try PiGraphFixture.graph(Array(repeating: row, count: PiHistoryGraph.maximumEntries + 1), leaf: "u")
    }
    let deep = Data((String(repeating: "[", count: PiHistoryGraph.maximumDepth + 1) + "0" + String(repeating: "]", count: PiHistoryGraph.maximumDepth + 1)).utf8)
    #expect(throws: PiHistoryGraphError(.oversized)) { try PiHistoryGraph.parse(deep) }
}

@Test(.timeLimit(.minutes(1))) func piHistoryGraphWalksLongNativeParentChainWithoutRecursiveTraversalOrIDReplacement() throws {
    let count = 18_000
    let rows = (0..<count).map { position in
        PiGraphFixture.entry("native-\(position)", parent: position == 0 ? nil : "native-\(position - 1)")
    }
    let graph = try PiGraphFixture.graph(rows, leaf: "native-\(count - 1)")
    #expect(graph.activeBranch.count == count && graph.activeBranch.first?.id == "native-0")
    #expect(graph.activeBranch.last?.raw == rows.last)
    #expect(try graph.retainedPrefix(beforeUserEntryID: "native-\(count - 1)").count == count - 1)
}

private struct PiGraphFileFixture: Sendable {
    let root: String
    let workspace: String
    let directory: String
    var path: String { directory + "/native.jsonl" }
    init() throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-graph-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let pointer = requested.path.withCString({ realpath($0, nil) }) else { throw CoincideError("The Pi graph fixture root is unavailable.") }
        root = String(cString: pointer); free(pointer)
        workspace = root + "/Workspace 工作 😀"; directory = root + "/Native Sessions"
        for path in [workspace, directory] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    }
    func write(_ data: Data? = nil, path: String? = nil) throws -> Data {
        let bytes = try data ?? PiGraphFixture.data([PiGraphFixture.header(workspace: workspace), PiGraphFixture.entry("u"), PiGraphFixture.assistant("a", parent: "u")])
        let target = path ?? self.path
        try bytes.write(to: URL(fileURLWithPath: target)); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
        return bytes
    }
    func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}

@Test func piHistoryFileReaderChecksExactStableHeaderIdentityWithoutWritingOrInferringLiveLeaf() throws {
    let fixture = try PiGraphFileFixture(); defer { fixture.cleanup() }
    let bytes = try fixture.write(), reader = PiHistoryFileReader()
    let snapshot = try reader.read(filePath: fixture.path, expectedWorkspacePath: fixture.workspace, expectedSessionID: "native-session-1")
    #expect(snapshot.graph.header.workspacePath == fixture.workspace && snapshot.graph.header.sessionID == "native-session-1")
    #expect(snapshot.graph.activeBranch.map(\.id) == ["u", "a"] && snapshot.graph.leafOrigin == .reloadedFile)
    #expect(snapshot.byteCount == bytes.count && snapshot.byteDigest.count == 64)
    #expect(try reader.read(filePath: fixture.path, expectedWorkspacePath: fixture.workspace).byteDigest == snapshot.byteDigest)
    #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.path)) == bytes)
    #expect(throws: PiHistoryGraphError(.invalidHeader)) { try reader.read(filePath: fixture.path, expectedWorkspacePath: fixture.workspace, expectedSessionID: "different-native-session") }
    #expect(throws: PiHistoryGraphError(.invalidHeader)) { try reader.read(filePath: fixture.path, expectedWorkspacePath: fixture.directory) }
    #expect(throws: PiHistoryGraphError.self) { try reader.read(filePath: fixture.path + "/../native.jsonl", expectedWorkspacePath: fixture.workspace) }
}

@Test(arguments: ["symlink", "directorySymlink", "fifo", "hardlink", "oversized", "empty"])
func piHistoryFileReaderRefusesUnsafeOrUnboundedNamedFiles(kind: String) throws {
    let fixture = try PiGraphFileFixture(); defer { fixture.cleanup() }
    _ = try fixture.write()
    switch kind {
    case "symlink":
        let target = fixture.root + "/retained.jsonl"
        try FileManager.default.moveItem(atPath: fixture.path, toPath: target)
        try FileManager.default.createSymbolicLink(atPath: fixture.path, withDestinationPath: target)
    case "directorySymlink":
        let retained = fixture.root + "/Retained Sessions"
        try FileManager.default.moveItem(atPath: fixture.directory, toPath: retained)
        try FileManager.default.createSymbolicLink(atPath: fixture.directory, withDestinationPath: retained)
    case "fifo":
        try FileManager.default.removeItem(atPath: fixture.path)
        #expect(mkfifo(fixture.path, mode_t(0o600)) == 0)
    case "hardlink": #expect(link(fixture.path, fixture.root + "/another-link.jsonl") == 0)
    case "empty": _ = try fixture.write(Data())
    default:
        let descriptor = open(fixture.path, O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CoincideError("The exact Pi fixture file is unavailable.") }
        defer { _ = close(descriptor) }
        #expect(ftruncate(descriptor, off_t(PiHistoryGraph.maximumBytes + 1)) == 0)
    }
    #expect(throws: PiHistoryGraphError.self) { try PiHistoryFileReader().read(filePath: fixture.path, expectedWorkspacePath: fixture.workspace) }
}

@Test(arguments: [false, true])
func piHistoryFileReaderDetectsNamedFileOrParentReplacementDuringRead(directory: Bool) throws {
    let fixture = try PiGraphFileFixture(); defer { fixture.cleanup() }
    let bytes = try fixture.write()
    let reader = PiHistoryFileReader { phase in
        guard case .opened = phase else { return }
        if directory {
            try FileManager.default.moveItem(atPath: fixture.directory, toPath: fixture.root + "/Retained Sessions")
            try FileManager.default.createDirectory(atPath: fixture.directory, withIntermediateDirectories: false)
        } else { try FileManager.default.moveItem(atPath: fixture.path, toPath: fixture.root + "/Retained File.jsonl") }
        _ = try fixture.write(bytes)
    }
    #expect(throws: PiHistoryGraphError(.changed)) { try reader.read(filePath: fixture.path, expectedWorkspacePath: fixture.workspace) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.path)) == bytes)
}
