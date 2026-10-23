import Darwin
import Foundation
import Testing
@testable import CoincideCore

private func workspacePendingRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-workspace-pending-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
}
private func workspacePendingRequest(contents: String = "private draft") -> RemoteWorkspaceMutationRequest {
    let thread = CodingThread(project: .init(path: "/remote/workspace"))
    return .init(target: .init(environmentID: UUID(), projectID: thread.projectID, threadID: thread.id,
        configuration: .init(thread: thread), rootID: UUID()), mutation: .createFile(path: "draft.txt", contents: contents))
}

@Test func remoteWorkspacePendingRetainsExactIntentAcrossRestartAndExplicitArchive() async throws {
    let root = try workspacePendingRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let request = workspacePendingRequest(), store = RemoteWorkspacePendingStore(root: root)
    try await store.save(request: request)
    let restarted = RemoteWorkspacePendingStore(root: root)
    #expect(try await restarted.load(environmentID: request.target.environmentID, threadID: request.target.threadID) == request)
    let changed = RemoteWorkspaceMutationRequest(id: request.id, target: request.target, mutation: .createFile(path: "other", contents: "changed"))
    await #expect(throws: RemoteEnvironmentStorageError(.pendingCommandExists)) { try await restarted.save(request: changed) }
    await #expect(throws: RemoteEnvironmentStorageError(.commandChanged)) { try await restarted.remove(request: changed) }
    await #expect(throws: RemoteEnvironmentStorageError(.commandChanged)) { try await restarted.archive(request: changed) }
    try await restarted.archive(request: request)
    #expect(try await restarted.load(environmentID: request.target.environmentID, threadID: request.target.threadID) == nil)
    let archived = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("abandoned-") })
    #expect(try JSONDecoder().decode(RemoteWorkspaceMutationRequest.self, from: Data(contentsOf: archived)) == request)
    #expect((try FileManager.default.attributesOfItem(atPath: archived.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func remoteWorkspacePendingDoesNotFoldDistinctUnicodePayloadBytes() async throws {
    let root = try workspacePendingRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let request = workspacePendingRequest(contents: "\u{e9}"), store = RemoteWorkspacePendingStore(root: root)
    let different = RemoteWorkspaceMutationRequest(id: request.id, target: request.target, mutation: .createFile(path: "draft.txt", contents: "e\u{301}"))
    #expect(request == different) // Swift String equality folds Unicode; the journal must not.
    try await store.save(request: request)
    await #expect(throws: RemoteEnvironmentStorageError(.pendingCommandExists)) { try await store.save(request: different) }
    await #expect(throws: RemoteEnvironmentStorageError(.commandChanged)) { try await store.remove(request: different) }
    try await store.remove(request: request)
}

@Test func remoteWorkspacePendingPreservesCorruptionAndRefusesSymbolicLinks() async throws {
    let root = try workspacePendingRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let request = workspacePendingRequest(), store = RemoteWorkspacePendingStore(root: root)
    try await store.save(request: request)
    let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("pending-") })
    let corruption = Data("invalid private intent".utf8); try corruption.write(to: file)
    await #expect(throws: RemoteEnvironmentStorageError(.corruptFile)) { try await store.save(request: request) }
    await #expect(throws: RemoteEnvironmentStorageError(.corruptFile)) { try await store.remove(request: request) }
    #expect(try Data(contentsOf: file) == corruption)
    let source = root.appendingPathComponent("preserved")
    try FileManager.default.moveItem(at: file, to: source)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source)
    await #expect(throws: RemoteEnvironmentStorageError(.unsafeFile)) { try await store.load(environmentID: request.target.environmentID, threadID: request.target.threadID) }
    #expect(try Data(contentsOf: source) == corruption)
}

@Test func remoteWorkspacePendingSupportsEscapedTwoMegabyteFileWithoutRelaxingConversationBound() async throws {
    let root = try workspacePendingRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let request = workspacePendingRequest(contents: String(repeating: "\u{1}", count: 2_000_000)), store = RemoteWorkspacePendingStore(root: root)
    #expect(try RemoteWorkspaceJournal.payload(request).count > RemoteEnvironmentProtocol.maximumRequestBytes)
    try await store.save(request: request)
    #expect(try await store.load(environmentID: request.target.environmentID, threadID: request.target.threadID) == request)
    #expect(RemoteEnvironmentProtocol.maximumRequestBytes == 1_048_576)
}
