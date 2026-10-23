import Foundation
import Testing
@testable import CoincideCore

private func historyDraftRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-history-draft-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
}

@Test func remoteHistoryRecallAtomicallyMergesOnceAcrossRestartAndLaterDraftEdits() async throws {
    let root = try historyDraftRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let environment = UUID(), thread = UUID(), other = UUID(), operation = UUID(), command = UUID()
    let store = RemoteEnvironmentDraftStore(root: root), digest = String(repeating: "a", count: 64)
    let before = [thread: "newer local work 工作 😀", other: "another conversation"]
    try await store.save(environmentID: environment, drafts: before)
    let first = try await store.mergeHistoryRecall(environmentID: environment, threadID: thread, commandID: command,
        operationID: operation, text: "original prompt", attachmentDigest: digest, expectedDrafts: before)
    #expect(first.appended && first.drafts[thread] == "newer local work 工作 😀\n\noriginal prompt")
    #expect(first.drafts[other] == before[other])
    let restarted = RemoteEnvironmentDraftStore(root: root)
    let recovered = try await restarted.mergeHistoryRecall(environmentID: environment, threadID: thread, commandID: command,
        operationID: operation, text: "original prompt", attachmentDigest: digest, expectedDrafts: before)
    #expect(!recovered.appended && recovered.drafts == first.drafts)
    // An intentional later edit, including deleting the recalled text, survives
    // receipt reconciliation and even a second command for the same operation.
    let later = [thread: "deliberately rewritten", other: "new second draft"]
    try await restarted.save(environmentID: environment, drafts: later)
    let repeatResult = try await store.mergeHistoryRecall(environmentID: environment, threadID: thread, commandID: UUID(),
        operationID: operation, text: "original prompt", attachmentDigest: digest, expectedDrafts: later)
    #expect(!repeatResult.appended && repeatResult.drafts == later)
    #expect(try await store.load(environmentID: environment) == later)
    let file = root.appendingPathComponent("drafts-" + environment.uuidString.lowercased() + ".json")
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func remoteHistoryRecallRefusesChangedPayloadOrStaleLocalDraftWithoutWriting() async throws {
    let root = try historyDraftRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let environment = UUID(), thread = UUID(), operation = UUID(), command = UUID()
    let store = RemoteEnvironmentDraftStore(root: root), digest = String(repeating: "b", count: 64)
    try await store.save(environmentID: environment, drafts: [thread: "current"])
    await #expect(throws: RemoteEnvironmentStorageError(.commandChanged)) {
        _ = try await store.mergeHistoryRecall(environmentID: environment, threadID: thread, commandID: command,
            operationID: operation, text: "original", attachmentDigest: digest, expectedDrafts: [thread: "stale"])
    }
    #expect(try await store.load(environmentID: environment) == [thread: "current"])
    _ = try await store.mergeHistoryRecall(environmentID: environment, threadID: thread, commandID: command,
        operationID: operation, text: "original", attachmentDigest: digest, expectedDrafts: [thread: "current"])
    let saved = try await store.load(environmentID: environment)
    for collision in [0, 1, 2] {
        await #expect(throws: RemoteEnvironmentStorageError(.commandChanged)) {
            _ = try await store.mergeHistoryRecall(environmentID: environment, threadID: thread,
                commandID: command, operationID: collision == 0 ? UUID() : operation,
                text: collision == 1 ? "changed" : "original", attachmentDigest: collision == 2 ? String(repeating: "c", count: 64) : digest,
                expectedDrafts: saved)
        }
    }
    #expect(try await store.load(environmentID: environment) == saved)
    let unicodeThread = UUID(), composed = "Caf\u{e9}", decomposed = "Cafe\u{301}"
    #expect(composed == decomposed && !composed.utf8.elementsEqual(decomposed.utf8))
    try await store.save(environmentID: environment, drafts: [thread: "current", unicodeThread: decomposed])
    await #expect(throws: RemoteEnvironmentStorageError(.commandChanged)) {
        _ = try await store.mergeHistoryRecall(environmentID: environment, threadID: thread, commandID: UUID(),
            operationID: UUID(), text: "original", attachmentDigest: digest, expectedDrafts: [thread: "current", unicodeThread: composed])
    }
    let preserved = try await store.load(environmentID: environment)
    #expect(preserved[unicodeThread]?.utf8.elementsEqual(decomposed.utf8) == true)
}

@Test func remoteHistoryRecallLimitFailureRetainsDraftAndDoesNotConsumeReceiptMarker() async throws {
    let root = try historyDraftRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let environment = UUID(), thread = UUID(), operation = UUID(), command = UUID()
    let store = RemoteEnvironmentDraftStore(root: root), digest = String(repeating: "d", count: 64)
    let full = [thread: String(repeating: "x", count: 120_000)]
    try await store.save(environmentID: environment, drafts: full)
    await #expect(throws: RemoteEnvironmentStorageError(.limitExceeded)) {
        _ = try await store.mergeHistoryRecall(environmentID: environment, threadID: thread, commandID: command,
            operationID: operation, text: "recalled", attachmentDigest: digest, expectedDrafts: full)
    }
    #expect(try await store.load(environmentID: environment) == full)
    try await store.save(environmentID: environment, drafts: [thread: "shortened"])
    let recovered = try await store.mergeHistoryRecall(environmentID: environment, threadID: thread, commandID: command,
        operationID: operation, text: "recalled", attachmentDigest: digest, expectedDrafts: [thread: "shortened"])
    #expect(recovered.appended && recovered.drafts[thread] == "shortened\n\nrecalled")
}

@Test func remoteHistoryRecallPreservesLegacyDraftFilesAndRefusesCorruptMarkers() async throws {
    let root = try historyDraftRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let environment = UUID(), thread = UUID(), store = RemoteEnvironmentDraftStore(root: root)
    struct Legacy: Encodable { let version = 1; let environmentID: UUID; let drafts: [UUID: String] }
    let file = root.appendingPathComponent("drafts-" + environment.uuidString.lowercased() + ".json")
    try JSONEncoder().encode(Legacy(environmentID: environment, drafts: [thread: "legacy"])).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #expect(try await store.load(environmentID: environment) == [thread: "legacy"])
    _ = try await store.mergeHistoryRecall(environmentID: environment, threadID: thread, commandID: UUID(),
        operationID: UUID(), text: "", attachmentDigest: String(repeating: "e", count: 64), expectedDrafts: [thread: "legacy"])
    var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    // A malformed ledger cannot be overwritten by a normal draft save.
    document["historyRecalls"] = ["invalid": "marker"]
    let corrupt = try JSONSerialization.data(withJSONObject: document)
    try corrupt.write(to: file)
    await #expect(throws: RemoteEnvironmentStorageError(.corruptFile)) { try await store.save(environmentID: environment, drafts: [:]) }
    #expect(try Data(contentsOf: file) == corrupt)
}
