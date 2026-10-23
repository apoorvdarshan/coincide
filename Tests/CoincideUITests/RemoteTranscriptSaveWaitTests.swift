import CryptoKit
import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private actor TranscriptSaveBoundary {
    private var reached = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        reached = true; observers.forEach { $0.resume() }; observers.removeAll()
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func entered() async { if !reached { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}

private actor TranscriptSaveHost {
    let rootID = UUID()
    let gate: TranscriptSaveBoundary
    let journal: RemoteWorkspacePendingStore
    private(set) var begins: [RemoteWorkspaceMutationRequest] = []
    private(set) var checks: [UUID] = []
    private(set) var cancellations = 0
    private(set) var persistedBeforeBegin = false
    private var operation: RemoteWorkspaceOperation?
    init(gate: TranscriptSaveBoundary, journal: RemoteWorkspacePendingStore) { self.gate = gate; self.journal = journal }
    nonisolated var transport: RemoteWorkspaceInspectorTransport {
        .init(bind: { await self.bind($0) }, read: { _ in throw RemoteWorkspaceFailure(.unavailable) },
            begin: { try await self.begin($0) }, status: { await self.status($0) }, cancel: { await self.cancel($0) })
    }
    private func bind(_ target: RemoteWorkspaceTarget) -> RemoteWorkspaceTarget {
        .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID,
              configuration: target.configuration, rootID: rootID)
    }
    private func begin(_ request: RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation {
        begins.append(request)
        let saved = try await journal.load(environmentID: request.target.environmentID, threadID: request.target.threadID)
        persistedBeforeBegin = saved == request
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(request)).map { String(format: "%02x", $0) }.joined()
        let accepted = RemoteWorkspaceOperation(request: request, payloadDigest: digest, state: .accepted,
            result: nil, failure: nil, createdAt: .now, updatedAt: .now)
        operation = accepted; return accepted
    }
    private func status(_ request: RemoteWorkspaceMutationRequest) async -> RemoteWorkspaceOperation? {
        checks.append(request.id); await gate.pause()
        guard operation?.request == request else { return nil }
        return operation
    }
    private func cancel(_ request: RemoteWorkspaceMutationRequest) -> RemoteWorkspaceOperation? { cancellations += 1; return operation }
    func finish(uncertain: Bool) {
        guard var value = operation else { return }
        value.state = uncertain ? .uncertain : .finished
        value.failure = uncertain ? .init(.interrupted) : nil
        if !uncertain, case .createFile(let path, let contents) = value.request.mutation {
            value.result = .document(.init(relativePath: path, contents: contents, byteLength: contents.utf8.count,
                truncated: false, exists: true, revision: UUID()))
        }
        operation = value
    }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["finished", "uncertain", "cancelled", "disconnected", "wrong-id"])
func remoteTranscriptSaveWaitObservesOnlyTheOriginalAcceptedUUIDWithoutRepeatingOrCancellingIt(mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-transcript-save-wait-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let journal = RemoteWorkspacePendingStore(root: root), gate = TranscriptSaveBoundary()
    let peer = TranscriptSaveHost(gate: gate, journal: journal)
    let project = WorkspaceProject(path: "/remote-only/transcript-save"), thread = CodingThread(project: project)
    let target = RemoteWorkspaceTarget(environmentID: UUID(), projectID: project.id, threadID: thread.id, configuration: .init(thread: thread))
    let session = RemoteWorkspaceInspectorSession(target: target, pendingStore: journal)
    var wait: Task<RemoteWorkspaceOperation?, Never>?
    do {
        await session.connect(transport: peer.transport, canMutate: true)
        let contents = "# Exact original plan\n\ne\u{301} 🌍\n"
        await session.perform(.createFile(path: "plan.md", contents: contents))
        let request = try #require(await peer.begins.first)
        #expect(await peer.persistedBeforeBegin)
        #expect(session.pending?.id == request.id && session.operation?.state == .accepted)
        let requestedID = mode == "wrong-id" ? UUID() : request.id
        let waiting = Task { await session.waitForOperation(id: requestedID) }; wait = waiting
        await gate.entered()
        switch mode {
        case "cancelled": waiting.cancel()
        case "disconnected": session.disconnect()
        case "finished", "uncertain": await peer.finish(uncertain: mode == "uncertain"); await gate.release()
        default: break
        }
        let result = await waiting.value
        if mode == "finished" {
            let completed = try #require(result)
            #expect(completed.request == request && completed.state == .finished && completed.failure == nil)
            guard case .document(let document) = completed.result else { throw CoincideError("The completed original save has no document.") }
            #expect(document.relativePath == "plan.md" && document.contents.utf8.elementsEqual(contents.utf8))
        } else if mode == "uncertain" {
            #expect(result?.request.id == request.id && result?.state == .uncertain && result?.result == nil)
        } else {
            #expect(result == nil, "Cancellation, disconnect and a different UUID never imply completion.")
            let retained = try await journal.load(environmentID: target.environmentID, threadID: target.threadID)
            #expect(retained == request)
        }
        await peer.finish(uncertain: false); await gate.release()
        await session.shutdown()
        #expect(await peer.begins == [request])
        #expect(await peer.cancellations == 0)
        #expect(await peer.checks.allSatisfy { $0 == request.id })
    } catch {
        wait?.cancel(); await gate.release(); await session.shutdown(); _ = await wait?.value
        try? FileManager.default.removeItem(at: root); throw error
    }
    try FileManager.default.removeItem(at: root)
}
