import Foundation
import Testing
@testable import CoincideCore

private struct RemoteAttachmentCoreFixture {
    let root: URL, engine: WorkspaceEngine, service: RemoteAttachmentService
    let target: RemoteAttachmentTarget
    func thread() async throws -> CodingThread { try #require(await engine.current().snapshot.threads.first { $0.id == target.threadID }) }
    func upload(_ bytes: Data, name: String = "private-note.txt") async throws -> (RemoteAttachmentUploadRequest, ChatAttachment) {
        let request = RemoteAttachmentUploadRequest(target: target, name: name, byteCount: bytes.count, digest: RemoteAttachmentJournal.digest(bytes))
        _ = try await service.begin(request)
        for index in 0..<RemoteAttachmentJournal.chunkCount(request) {
            let start = index * RemoteAttachmentProtocol.maximumChunkBytes
            let part = bytes.subdata(in: start..<min(start + RemoteAttachmentProtocol.maximumChunkBytes, bytes.count))
            _ = try await service.append(.init(upload: request, index: index, data: part, digest: RemoteAttachmentJournal.digest(part)))
        }
        return (request, try #require(try await service.finalize(request).attachment))
    }
}
private func withRemoteAttachmentCore(_ body: (RemoteAttachmentCoreFixture) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-attachment-core-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in
        Issue.record("No provider may run before this controlled workspace becomes ready.")
        throw CoincideError("No provider is authorized by this attachment fixture.")
    }, identityResolver: { _ in nil })
    let project = WorkspaceProject(path: source.path)
    var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
    let preparation = GitWorktreeRequest(sourcePath: source.path, destinationRoot: engine.worktreesRoot.path, selection: .createBranch(name: "held-attachments", baseRef: "HEAD"))
    thread.workspacePreparation = .init(request: preparation); thread.workspacePreparation?.phase = .interrupted
    thread.workspacePath = preparation.destinationPath
    // This is a recovered, interrupted native preparation, not a new-thread
    // registration. Seed its valid durable snapshot before Engine loads it.
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    try await WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite")).save(snapshot, event: "fixture.remote-attachment-held-workspace")
    _ = try await engine.load()
    let target = RemoteAttachmentTarget(environmentID: UUID(), projectID: project.id, threadID: thread.id)
    let service = try RemoteAttachmentService(environmentID: target.environmentID, engine: engine, dataDirectory: root)
    do { try await body(.init(root: root, engine: engine, service: service, target: target)); await service.close(); await engine.shutdown() }
    catch { await service.close(); await engine.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteAttachmentChunksAreImmutableReorderedAndRecoverableWithoutDuplicatePublication() async throws {
    try await withRemoteAttachmentCore { f in
        // Distinct binary chunks avoid accidental legacy image headers. Image
        // sniffing and conversion have their own native-import regression.
        var bytes = Data(repeating: 0xa7, count: RemoteAttachmentProtocol.maximumChunkBytes)
        bytes.append(Data(repeating: 0xc3, count: RemoteAttachmentProtocol.maximumChunkBytes))
        bytes.append(contentsOf: (0..<13).map(UInt8.init))
        let request = RemoteAttachmentUploadRequest(target: f.target, name: "raw.bin", byteCount: bytes.count, digest: RemoteAttachmentJournal.digest(bytes))
        _ = try await f.service.begin(request)
        func chunk(_ index: Int) -> RemoteAttachmentChunkRequest {
            let start = index * RemoteAttachmentProtocol.maximumChunkBytes, data = bytes.subdata(in: start..<min(start + RemoteAttachmentProtocol.maximumChunkBytes, bytes.count))
            return .init(upload: request, index: index, data: data, digest: RemoteAttachmentJournal.digest(data))
        }
        #expect(try await f.service.append(chunk(2)).receivedChunks == [2])
        #expect(try await f.service.append(chunk(2)).receivedChunks == [2])
        let changed = Data(repeating: 99, count: 13)
        await #expect(throws: RemoteAttachmentFailure(.collision)) {
            try await f.service.append(.init(upload: request, index: 2, data: changed, digest: RemoteAttachmentJournal.digest(changed)))
        }
        await f.service.close()
        let reopened = try RemoteAttachmentService(environmentID: f.target.environmentID, engine: f.engine, dataDirectory: f.root)
        do {
            #expect(try await reopened.status(request)?.receivedChunks == [2])
            _ = try await reopened.append(chunk(1)); _ = try await reopened.append(chunk(0))
            let reference = try #require(try await reopened.finalize(request).attachment)
            #expect(try await reopened.finalize(request).attachment == reference)
            #expect(try await f.engine.attachments.data(for: reference) == bytes)
            var downloaded = Data()
            while downloaded.count < bytes.count {
                let page = try await reopened.download(.init(target: f.target, attachmentID: reference.id, offset: downloaded.count))
                #expect(page.attachment == reference && page.data.count <= RemoteAttachmentProtocol.maximumChunkBytes)
                downloaded.append(page.data)
            }
            #expect(downloaded == bytes)
            let cancelled = try #require(try await reopened.cancel(request))
            #expect(cancelled.state == .cancelled && cancelled.attachment == nil)
            #expect(try await reopened.cancel(request)?.state == .cancelled)
            await #expect(throws: RemoteAttachmentFailure(.notFound)) { try await reopened.download(.init(target: f.target, attachmentID: reference.id, offset: 0)) }
            await reopened.close()
        } catch { await reopened.close(); throw error }
    }
}

@Test(.timeLimit(.minutes(1)))
func remoteAttachmentSubmitClaimsExactHostDraftAndUploadedRefsAtomicallyUnderOriginalUUID() async throws {
    try await withRemoteAttachmentCore { f in
        let hostDraft = try await f.engine.attachments.importData(Data("Existing host draft".utf8), name: "caf\u{00e9}.txt")
        try await f.engine.dispatch(.addAttachments(threadID: f.target.threadID, attachments: [hostDraft]))
        let (upload, reference) = try await f.upload(Data("Uploaded owned bytes".utf8))
        let thread = try await f.thread(), configuration = ProviderConfiguration(thread: thread)
        let legacy = RemoteEnvironmentCommandRequest(environmentID: f.target.environmentID,
            command: .submit(threadID: thread.id, text: "Never consume hidden draft refs", expectedConfiguration: configuration))
        #expect(try await f.engine.dispatchRemoteEnvironment(legacy, preparation: .none).rejection != nil)
        #expect(try await f.thread().draftAttachments == [hostDraft])
        let command = RemoteEnvironmentCommand.submitWithAttachments(target: f.target, text: "", expectedConfiguration: configuration,
            expectedDraftAttachments: [hostDraft], uploadedAttachmentIDs: [reference.id])
        var alternate = hostDraft; alternate.name = hostDraft.name.decomposedStringWithCanonicalMapping
        if try RemoteAttachmentProtocol.payload(alternate) == RemoteAttachmentProtocol.payload(hostDraft) { alternate.name = hostDraft.name.precomposedStringWithCanonicalMapping }
        #expect(try RemoteAttachmentProtocol.payload(alternate) != RemoteAttachmentProtocol.payload(hostDraft))
        let altered = RemoteEnvironmentCommand.submitWithAttachments(target: f.target, text: "", expectedConfiguration: configuration,
            expectedDraftAttachments: [alternate], uploadedAttachmentIDs: [reference.id])
        let alteredProof = try await f.engine.prepareRemoteAttachmentSubmission(altered)
        #expect(try await f.engine.dispatchRemoteEnvironment(.init(environmentID: f.target.environmentID, command: altered), preparation: alteredProof).rejection != nil)
        #expect(try await f.thread().draftAttachments == [hostDraft])
        let request = RemoteEnvironmentCommandRequest(environmentID: f.target.environmentID, command: command)
        let captured = try await f.engine.prepareRemoteAttachmentSubmission(command)
        let receipt = try await f.engine.dispatchRemoteEnvironment(request, preparation: captured)
        #expect(receipt.rejection == nil)
        let current = try await f.thread(), queued = try #require(current.queuedTurns.first)
        #expect(queued.id == request.id && queued.attachments == [hostDraft, reference] && queued.text.isEmpty)
        #expect(current.draftAttachments.isEmpty && current.activeRun == nil && current.messages.isEmpty)
        #expect(try await f.engine.remoteAttachmentRecord(f.target, id: reference.id)?.claimedBy == request.id)
        #expect(try await f.engine.dispatchRemoteEnvironment(request, preparation: .refused) == receipt)
        #expect(try await f.thread().queuedTurns.count == 1)
        let reused = RemoteEnvironmentCommand.submitWithAttachments(target: f.target, text: "Do not repeat claimed refs", expectedConfiguration: .init(thread: current),
            expectedDraftAttachments: [], uploadedAttachmentIDs: [reference.id])
        await #expect(throws: RemoteAttachmentFailure(.collision)) { try await f.engine.prepareRemoteAttachmentSubmission(reused) }
        #expect(try await f.engine.dispatchRemoteEnvironment(.init(environmentID: f.target.environmentID, command: reused), preparation: captured).rejection != nil)
        if case .attachments(let proof) = captured {
            let db = try WorkspaceDatabase(url: f.root.appendingPathComponent("workspace.sqlite"))
            let snapshot = (await f.engine.current()).snapshot
            await #expect(throws: WorkspaceCommitError.revisionChanged) {
                try await db.commitWithRemovedEffects(snapshot, event: "never-claim-twice", commandID: UUID(), attachmentClaims: proof.records)
            }
        }
        #expect(try await f.service.cancel(upload)?.state == .claimed)
        #expect(try await f.engine.attachments.data(for: reference) == Data("Uploaded owned bytes".utf8))
        let rebuilt = try await WorkspaceDatabase(url: f.root.appendingPathComponent("workspace.sqlite")).rebuildProjection()
        #expect(rebuilt.snapshot == (await f.engine.current()).snapshot)
    }
}

@Test(.timeLimit(.minutes(1)))
func remoteAttachmentLateRefusalRollsBackDraftMutationAndNeverClaimsCancelledOrForeignRefs() async throws {
    try await withRemoteAttachmentCore { f in
        let (upload, reference) = try await f.upload(Data("Exact ownership".utf8))
        let thread = try await f.thread()
        let command = RemoteEnvironmentCommand.submitWithAttachments(target: f.target, text: "Captured", expectedConfiguration: .init(thread: thread),
            expectedDraftAttachments: [], uploadedAttachmentIDs: [reference.id])
        let prepared = try await f.engine.prepareRemoteAttachmentSubmission(command)
        _ = try await f.service.cancel(upload)
        let request = RemoteEnvironmentCommandRequest(environmentID: f.target.environmentID, command: command)
        #expect(try await f.engine.dispatchRemoteEnvironment(request, preparation: prepared).rejection != nil)
        let current = try await f.thread()
        #expect(current.draftAttachments.isEmpty && current.queuedTurns.isEmpty && current.messages.isEmpty)
        #expect(try await f.engine.remoteAttachmentRecord(f.target, id: reference.id)?.claimedBy == nil)
        let other = RemoteAttachmentTarget(environmentID: f.target.environmentID, projectID: f.target.projectID, threadID: UUID())
        await #expect(throws: RemoteAttachmentFailure(.invalidTarget)) { try await f.service.download(.init(target: other, attachmentID: reference.id, offset: 0)) }
    }
}

@Test(.timeLimit(.minutes(1)))
func remoteAttachmentNativeStableImportConvertsImagesAndRangeReadsRejectSymlinks() async throws {
    try await withRemoteAttachmentCore { f in
        let bytes = try attachmentImageData(), source = f.root.appendingPathComponent("immutable-upload")
        try bytes.write(to: source)
        let id = UUID(), reference = try await f.engine.attachments.importFile(source, name: "misnamed.txt", reservedID: id)
        #expect(reference.id == id && reference.mimeType == "image/png")
        #expect(try await f.engine.attachments.importFile(source, name: "misnamed.txt", reservedID: id) == reference)
        let page = try await f.engine.attachments.read(reference, offset: 0, maximumBytes: 17)
        #expect(page == bytes.prefix(17))
        let owned = try await f.engine.attachments.url(for: reference)
        try FileManager.default.removeItem(at: owned); try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: source)
        await #expect(throws: RemoteAttachmentFailure(.integrity)) { try await f.engine.attachments.read(reference, offset: 0, maximumBytes: 17) }
    }
}
