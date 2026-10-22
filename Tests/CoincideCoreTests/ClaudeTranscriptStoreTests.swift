import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct TranscriptStoreFixture: Sendable {
    let root: URL, configuration: URL, workspace: URL, project: URL
    let sourceID = UUID().uuidString, inputID = UUID().uuidString, assistantID = UUID().uuidString
    init() throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-transcript-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let pointer = requested.path.withCString({ realpath($0, nil) }) else { throw CoincideError("The transcript fixture root is unavailable.") }
        root = URL(fileURLWithPath: String(cString: pointer)); free(pointer)
        configuration = root.appendingPathComponent("Private Claude Configuration")
        workspace = root.appendingPathComponent("Workspace 工作 😀")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = try ClaudeTranscriptStore.projectDirectoryName(forPhysicalWorkspacePath: workspace.path)
        project = configuration.appendingPathComponent("projects").appendingPathComponent(key)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    var sourceURL: URL { project.appendingPathComponent(sourceID + ".jsonl") }
    var records: [JSONValue] {
        [ .object(["type": .string("user"), "uuid": .string(inputID), "sessionId": .string(sourceID), "parentUuid": .null,
            "cwd": .string(workspace.path), "isSidechain": .bool(false), "timestamp": .string("2026-10-23T00:00:00.000Z"),
            "message": .object(["role": .string("user"), "content": .string("Exact original input 工作 😀")])]),
          .object(["type": .string("assistant"), "uuid": .string(assistantID), "sessionId": .string(sourceID), "parentUuid": .string(inputID),
            "cwd": .string(workspace.path), "isSidechain": .bool(false), "timestamp": .string("2026-10-23T00:00:01.000Z"),
            "message": .object(["id": .string("api-message-is-not-the-transcript-uuid"), "role": .string("assistant"),
                "content": .array([.object(["type": .string("text"), "text": .string("Native answer")])])])]),
          .object(["type": .string("custom-title"), "sessionId": .string(sourceID), "customTitle": .string("Private native fixture")]) ]
    }
    @discardableResult func write(_ records: [JSONValue]? = nil, to url: URL? = nil) throws -> Data {
        let data = try Self.encode(records ?? self.records)
        try data.write(to: url ?? sourceURL); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: (url ?? sourceURL).path)
        return data
    }
    static func encode(_ records: [JSONValue]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for record in records { data.append(try encoder.encode(record)); data.append(10) }
        return data
    }
    func store(observer: (@Sendable (ClaudeTranscriptStoreIOPhase) throws -> Void)? = nil) throws -> ClaudeTranscriptStore {
        try .init(configurationDirectory: configuration, workspace: workspace, projectDirectoryName: nil, observer: observer)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class TranscriptStoreOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func run(_ body: () throws -> Void) rethrows {
        lock.lock(); let shouldRun = !fired; fired = true; lock.unlock()
        if shouldRun { try body() }
    }
}
private struct TranscriptStoreInjectedFailure: Error { }

@Test func claudeTranscriptStoreReadsPublishesAndInspectsExactReservedTargetWithoutChangingSource() throws {
    let fixture = try TranscriptStoreFixture(); defer { fixture.cleanup() }
    let original = try fixture.write(), store = try fixture.store()
    let source = try store.read(sessionID: fixture.sourceID), targetID = UUID().uuidString
    let plan = try store.prepareFork(source: source, upToMessageID: fixture.assistantID, targetSessionID: targetID)
    if case .notStarted = try store.inspect(plan.publication) {} else { Issue.record("Preparing a fork must not publish a native file.") }
    let encoded = try JSONEncoder().encode(plan.publication)
    let reserved = try JSONDecoder().decode(ClaudeTranscriptPublication.self, from: encoded)
    #expect(reserved == plan.publication)
    let result = try store.publish(plan)
    let restarted = try fixture.store()
    guard case .ready(let target) = try restarted.inspect(reserved) else { throw CoincideError("The exact persisted fork was not verified.") }
    #expect(target.location.sessionID == targetID && target.revision.digest == result.targetDigest)
    #expect(target.transcript.selectedMessages.count == 2)
    #expect(result.sourceToForkMessageIDs[fixture.assistantID] == result.headMessageID)
    #expect(try Data(contentsOf: fixture.sourceURL) == original)
    let targetURL = fixture.project.appendingPathComponent(targetID + ".jsonl")
    let permissions = try FileManager.default.attributesOfItem(atPath: targetURL.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    #expect(throws: ClaudeTranscriptStoreError(.collision)) { try store.publish(plan) }
    #expect(try restarted.read(sessionID: targetID).revision == target.revision)
}

@Test(arguments: ["fileSymlink", "fifo", "hardlink", "directorySymlink", "configurationSymlink", "empty", "oversized"])
func claudeTranscriptStoreRejectsUnsafeNativeFilesAndAnchors(kind: String) throws {
    let fixture = try TranscriptStoreFixture(); defer { fixture.cleanup() }
    try fixture.write()
    var store = try fixture.store()
    switch kind {
    case "fileSymlink":
        let saved = fixture.root.appendingPathComponent("saved.jsonl")
        try FileManager.default.moveItem(at: fixture.sourceURL, to: saved)
        try FileManager.default.createSymbolicLink(at: fixture.sourceURL, withDestinationURL: saved)
    case "fifo":
        try FileManager.default.removeItem(at: fixture.sourceURL)
        #expect(mkfifo(fixture.sourceURL.path, mode_t(0o600)) == 0)
    case "hardlink":
        #expect(link(fixture.sourceURL.path, fixture.root.appendingPathComponent("second-link.jsonl").path) == 0)
    case "directorySymlink":
        let saved = fixture.root.appendingPathComponent("saved-project")
        try FileManager.default.moveItem(at: fixture.project, to: saved)
        try FileManager.default.createSymbolicLink(at: fixture.project, withDestinationURL: saved)
    case "configurationSymlink":
        let alias = fixture.root.appendingPathComponent("configuration-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.configuration)
        store = try .init(configurationDirectory: alias, workspace: fixture.workspace)
    case "empty": try Data().write(to: fixture.sourceURL)
    default:
        let descriptor = open(fixture.sourceURL.path, O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CoincideError("The fixture file could not be opened.") }
        defer { _ = close(descriptor) }
        #expect(ftruncate(descriptor, off_t(ClaudeTranscriptStore.maximumBytes + 1)) == 0)
    }
    #expect(throws: ClaudeTranscriptStoreError.self) { try store.read(sessionID: fixture.sourceID) }
}

@Test(arguments: [false, true])
func claudeTranscriptStoreDetectsSourceOrDirectoryReplacementDuringOwnedRead(directory: Bool) throws {
    let fixture = try TranscriptStoreFixture(); defer { fixture.cleanup() }
    let bytes = try fixture.write(), once = TranscriptStoreOnce()
    let store = try fixture.store { phase in
        guard case .readOpened = phase else { return }
        try once.run {
            if directory {
                try FileManager.default.moveItem(at: fixture.project, to: fixture.root.appendingPathComponent("retained-project"))
                try FileManager.default.createDirectory(at: fixture.project, withIntermediateDirectories: false)
            } else {
                try FileManager.default.moveItem(at: fixture.sourceURL, to: fixture.root.appendingPathComponent("retained-source.jsonl"))
            }
            try bytes.write(to: fixture.sourceURL)
        }
    }
    #expect(throws: ClaudeTranscriptStoreError.self) { try store.read(sessionID: fixture.sourceID) }
}

@Test func claudeTranscriptStoreSourceChangeBeforeExclusiveCreateDoesNotPublish() throws {
    let fixture = try TranscriptStoreFixture(); defer { fixture.cleanup() }
    let original = try fixture.write(), initial = try fixture.store()
    let source = try initial.read(sessionID: fixture.sourceID), targetID = UUID().uuidString
    let plan = try initial.prepareFork(source: source, upToMessageID: fixture.assistantID, targetSessionID: targetID)
    let once = TranscriptStoreOnce()
    let store = try fixture.store { phase in
        guard case .sourceRevalidated = phase else { return }
        try once.run { try (original + Data("\n".utf8)).write(to: fixture.sourceURL) }
    }
    #expect(throws: ClaudeTranscriptStoreError(.sourceChanged)) { try store.publish(plan) }
    #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(targetID + ".jsonl").path))
}

@Test(arguments: [false, true])
func claudeTranscriptStorePreservesPartialOrCompleteTargetAfterUncertainPublication(sourceChanges: Bool) throws {
    let fixture = try TranscriptStoreFixture(); defer { fixture.cleanup() }
    let original = try fixture.write(), store = try fixture.store()
    let source = try store.read(sessionID: fixture.sourceID), targetID = UUID().uuidString
    let plan = try store.prepareFork(source: source, upToMessageID: fixture.assistantID, targetSessionID: targetID)
    let faulting = try fixture.store { phase in
        guard case .targetCreated = phase else { return }
        if sourceChanges { try (original + Data("\n".utf8)).write(to: fixture.sourceURL) }
        else { throw TranscriptStoreInjectedFailure() }
    }
    do { _ = try faulting.publish(plan); Issue.record("The injected publication boundary must remain uncertain.") }
    catch let error as ClaudeTranscriptStoreError { #expect(error.mayHavePublished && error.kind == .publicationUncertain) }
    let target = fixture.project.appendingPathComponent(targetID + ".jsonl")
    #expect(FileManager.default.fileExists(atPath: target.path))
    let preserved = try Data(contentsOf: target)
    if sourceChanges {
        #expect(!preserved.isEmpty)
        #expect(throws: ClaudeTranscriptStoreError(.sourceChanged)) { try store.inspect(plan.publication) }
    } else {
        #expect(preserved.isEmpty)
        if case .incomplete = try store.inspect(plan.publication) {} else { Issue.record("An empty partial target cannot be ready.") }
    }
    #expect(try Data(contentsOf: target) == preserved)
}

@Test func claudeTranscriptStorePreservesForeignCollisionAndRejectsDigestOnlyForgedPublication() throws {
    let fixture = try TranscriptStoreFixture(); defer { fixture.cleanup() }
    try fixture.write(); let store = try fixture.store(), source = try store.read(sessionID: fixture.sourceID)
    let targetID = UUID().uuidString, plan = try store.prepareFork(source: source, upToMessageID: fixture.assistantID, targetSessionID: targetID)
    let targetURL = fixture.project.appendingPathComponent(targetID + ".jsonl"), foreign = Data("foreign bytes\n".utf8)
    try foreign.write(to: targetURL)
    #expect(throws: ClaudeTranscriptStoreError(.collision)) { try store.publish(plan) }
    #expect(try Data(contentsOf: targetURL) == foreign)
    try FileManager.default.removeItem(at: targetURL)
    _ = try store.publish(plan)
    let target = try store.read(sessionID: targetID)
    var records = target.transcript.records
    let index = try #require(records.firstIndex { $0["type"].string == "assistant" })
    var altered = try #require(records[index].object), message = try #require(records[index]["message"].object)
    message["content"] = .array([.object(["type": .string("text"), "text": .string("Unrelated attacker-authored output")])])
    altered["message"] = .object(message); records[index] = .object(altered)
    let bytes = try TranscriptStoreFixture.encode(records); try bytes.write(to: targetURL)
    let forged = try ClaudeTranscriptPublication(source: plan.publication.source, sourceRevision: plan.publication.sourceRevision,
        target: plan.publication.target, targetDigest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
        targetByteCount: Int64(bytes.count), upToMessageID: plan.publication.upToMessageID,
        sourceToForkMessageIDs: plan.publication.sourceToForkMessageIDs, headMessageID: plan.publication.headMessageID)
    if case .incomplete = try store.inspect(forged) {} else { Issue.record("A matching digest cannot replace native semantic copy proof.") }
    #expect(try Data(contentsOf: targetURL) == bytes)
}

@Test func claudeTranscriptStoreExactLocationRejectsAmbiguityForeignWorkspaceAndUnrelatedProjects() throws {
    let fixture = try TranscriptStoreFixture(); defer { fixture.cleanup() }
    let bytes = try fixture.write()
    let explicit = fixture.configuration.appendingPathComponent("projects/explicit-project")
    try FileManager.default.createDirectory(at: explicit, withIntermediateDirectories: true)
    try bytes.write(to: explicit.appendingPathComponent(fixture.sourceID + ".jsonl"))
    let ambiguous = try ClaudeTranscriptStore(configurationDirectory: fixture.configuration, workspace: fixture.workspace, projectDirectoryName: "explicit-project")
    #expect(throws: ClaudeTranscriptStoreError(.ambiguous)) { try ambiguous.read(sessionID: fixture.sourceID) }
    try FileManager.default.removeItem(at: fixture.sourceURL)
    #expect(throws: ClaudeTranscriptStoreError(.notFound)) { try fixture.store().read(sessionID: fixture.sourceID) }
    #expect(try ambiguous.read(sessionID: fixture.sourceID).location.projectDirectoryName == "explicit-project")
    let other = fixture.root.appendingPathComponent("Another physical workspace")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    var records = fixture.records, first = try #require(records[0].object)
    first["cwd"] = .string(other.path); records[0] = .object(first)
    try fixture.write(records)
    #expect(throws: ClaudeTranscriptStoreError(.unsupportedLocation)) { try fixture.store().read(sessionID: fixture.sourceID) }
}

@Test func claudeTranscriptStoreProjectKeysMatchSDKUTF16NFCAndExplicitOverrideValidation() throws {
    #expect(try ClaudeTranscriptStore.projectDirectoryName(forPhysicalWorkspacePath: "/tmp/Hello world/foo.bar") == "-tmp-Hello-world-foo-bar")
    #expect(try ClaudeTranscriptStore.projectDirectoryName(forPhysicalWorkspacePath: "/tmp/é😀") == "-tmp----")
    #expect(try ClaudeTranscriptStore.projectDirectoryName(forPhysicalWorkspacePath: "/tmp/e\u{301}😀") == "-tmp----")
    let boundary = "/" + String(repeating: "a", count: 199)
    #expect(try ClaudeTranscriptStore.projectDirectoryName(forPhysicalWorkspacePath: boundary) == "-" + String(repeating: "a", count: 199))
    let long = try ClaudeTranscriptStore.projectDirectoryName(forPhysicalWorkspacePath: boundary + "a")
    #expect(long == "-" + String(repeating: "a", count: 199) + "-b6ymvl")
    let unicodeLong = "/tmp/" + String(repeating: "é😀", count: 100)
    #expect(try ClaudeTranscriptStore.projectDirectoryName(forPhysicalWorkspacePath: unicodeLong) == "-tmp-" + String(repeating: "-", count: 195) + "-z6uqsn")
    let fixture = try TranscriptStoreFixture(); defer { fixture.cleanup() }
    for invalid in ["../escape", "", "CON", "com0", "Lpt9", "workspace.name", String(repeating: "a", count: 65)] {
        #expect(throws: ClaudeTranscriptStoreError(.invalidLocation)) {
            try ClaudeTranscriptStore(configurationDirectory: fixture.configuration, workspace: fixture.workspace, projectDirectoryName: invalid)
        }
    }
}

@Test(arguments: ["symlink", "fifo", "hardlink"])
func claudeTranscriptStoreInspectionPreservesUnsafeReservedTargets(kind: String) throws {
    let fixture = try TranscriptStoreFixture(); defer { fixture.cleanup() }
    try fixture.write(); let store = try fixture.store(), source = try store.read(sessionID: fixture.sourceID)
    let plan = try store.prepareFork(source: source, upToMessageID: fixture.assistantID, targetSessionID: UUID().uuidString)
    let target = fixture.project.appendingPathComponent(plan.publication.target.sessionID + ".jsonl")
    let foreign = fixture.root.appendingPathComponent("foreign-target-content")
    try Data("Preserve this unrelated file\n".utf8).write(to: foreign)
    switch kind {
    case "symlink": try FileManager.default.createSymbolicLink(at: target, withDestinationURL: foreign)
    case "fifo": #expect(mkfifo(target.path, mode_t(0o600)) == 0)
    default: #expect(link(foreign.path, target.path) == 0)
    }
    if case .incomplete = try store.inspect(plan.publication) {} else { Issue.record("An unsafe existing target cannot prove publication.") }
    #expect(throws: ClaudeTranscriptStoreError(.collision)) { try store.publish(plan) }
    var info = stat()
    #expect(lstat(target.path, &info) == 0)
    #expect(try Data(contentsOf: foreign) == Data("Preserve this unrelated file\n".utf8))
}

@Test func claudeTranscriptStoreDecodedPublicationCannotEscapeBoundScopeOrSmuggleInvalidMap() throws {
    let fixture = try TranscriptStoreFixture(); defer { fixture.cleanup() }
    try fixture.write(); let store = try fixture.store(), source = try store.read(sessionID: fixture.sourceID)
    let plan = try store.prepareFork(source: source, upToMessageID: fixture.assistantID, targetSessionID: UUID().uuidString)
    let encoded = try JSONEncoder().encode(plan.publication)
    var value = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var target = try #require(value["target"] as? [String: Any])
    target["configurationDirectory"] = fixture.root.appendingPathComponent("foreign-config").path; value["target"] = target
    let decoded = try JSONDecoder().decode(ClaudeTranscriptPublication.self, from: JSONSerialization.data(withJSONObject: value))
    #expect(throws: ClaudeTranscriptStoreError.self) { try store.inspect(decoded) }
    value = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    value["sourceToForkMessageIDs"] = ["not-a-uuid": UUID().uuidString]
    let invalidMap = try JSONDecoder().decode(ClaudeTranscriptPublication.self, from: JSONSerialization.data(withJSONObject: value))
    #expect(throws: ClaudeTranscriptStoreError.self) { try store.inspect(invalidMap) }
}
