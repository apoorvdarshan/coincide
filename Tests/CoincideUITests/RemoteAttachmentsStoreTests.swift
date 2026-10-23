import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Observation
import Testing
import UniformTypeIdentifiers
@testable import Coincide
@testable import CoincideCore

private actor RemoteAttachmentBoundary {
    private var waiting = false
    private var released = false
    private var body: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        waiting = true; observers.forEach { $0.resume() }; observers = []
        if !released { await withCheckedContinuation { body = $0 } }
    }
    func entered() async { if !waiting { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; body?.resume(); body = nil }
}

private final class RemoteAttachmentObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func signal() { lock.withLock { value = true } }
    var fired: Bool { lock.withLock { value } }
}

private actor RemoteAttachmentPeer {
    private let store: AttachmentStore
    private var records: [UUID: RemoteAttachmentUpload] = [:]
    private var chunks: [UUID: [Int: Data]] = [:]
    private var owners: [UUID: RemoteAttachmentTarget] = [:]
    private var references: [UUID: ChatAttachment] = [:]
    private var begins = 0, appends = 0, finalizes = 0, statuses = 0, cancels = 0, reads = 0
    private var dropFinalize = false
    private var finalizeBoundary: RemoteAttachmentBoundary?
    private var corruptReads = false
    private var chunkSizes: [Int] = []
    init(root: URL) throws { store = try AttachmentStore(root: root) }
    nonisolated var transport: RemoteAttachmentsTransport {
        .init(begin: { try await self.begin($0) }, status: { try await self.status($0) }, append: { try await self.append($0) },
            finalize: { try await self.finalize($0) }, cancel: { try await self.cancel($0) }, download: { try await self.download($0) })
    }
    func setDropFinalize() { dropFinalize = true }
    func setBoundary(_ boundary: RemoteAttachmentBoundary) { finalizeBoundary = boundary }
    func setCorruptReads(_ value: Bool) { corruptReads = value }
    func counts() -> [Int] { [begins, appends, finalizes, statuses, cancels, reads] }
    func sizes() -> [Int] { chunkSizes }
    func seed(_ bytes: Data, name: String, target: RemoteAttachmentTarget) async throws -> ChatAttachment {
        let reference = try await store.importData(bytes, name: name)
        references[reference.id] = reference; owners[reference.id] = target; return reference
    }
    private func begin(_ request: RemoteAttachmentUploadRequest) throws -> RemoteAttachmentUpload {
        begins += 1
        if let existing = records[request.id] { guard same(existing.request, request) else { throw RemoteAttachmentFailure(.collision) }; return existing }
        let value = RemoteAttachmentUpload(request: request, state: .receiving)
        records[request.id] = value; chunks[request.id] = [:]; return value
    }
    private func status(_ request: RemoteAttachmentUploadRequest) throws -> RemoteAttachmentUpload? {
        statuses += 1
        guard let value = records[request.id] else { return nil }
        guard same(value.request, request) else { throw RemoteAttachmentFailure(.collision) }; return value
    }
    private func append(_ request: RemoteAttachmentChunkRequest) throws -> RemoteAttachmentUpload {
        appends += 1; chunkSizes.append(request.data.count)
        guard var value = records[request.upload.id], same(value.request, request.upload), value.state == .receiving,
              request.data.count <= RemoteAttachmentProtocol.maximumChunkBytes, Self.digest(request.data) == request.digest else { throw RemoteAttachmentFailure(.integrity) }
        if let previous = chunks[request.upload.id]?[request.index], previous != request.data { throw RemoteAttachmentFailure(.collision) }
        chunks[request.upload.id, default: [:]][request.index] = request.data
        value.receivedChunks = chunks[request.upload.id, default: [:]].keys.sorted(); records[request.upload.id] = value; return value
    }
    private func finalize(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload {
        finalizes += 1
        guard var value = records[request.id], same(value.request, request) else { throw RemoteAttachmentFailure(.notFound) }
        if value.state == .ready { return value }
        if let boundary = finalizeBoundary { finalizeBoundary = nil; await boundary.pause() }
        // Cancellation can publish while native conversion is awaited. Its
        // terminal result must win over the older finalization continuation.
        guard records[request.id]?.state != .cancelled else { return records[request.id]! }
        let data = chunks[request.id, default: [:]].keys.sorted().reduce(into: Data()) { $0.append(chunks[request.id]![$1]!) }
        guard data.count == request.byteCount, Self.digest(data) == request.digest else { throw RemoteAttachmentFailure(.integrity) }
        let reference = try await seed(data, name: request.name, target: request.target)
        value.state = .ready; value.attachment = reference; records[request.id] = value
        if dropFinalize { dropFinalize = false; throw RemoteAttachmentFailure(.uncertain) }
        return value
    }
    private func cancel(_ request: RemoteAttachmentUploadRequest) throws -> RemoteAttachmentUpload? {
        cancels += 1
        guard var value = records[request.id], same(value.request, request) else { return nil }
        value.state = .cancelled; value.attachment = nil; records[request.id] = value; return value
    }
    private func download(_ request: RemoteAttachmentDownloadRequest) async throws -> RemoteAttachmentDownloadResult {
        reads += 1
        guard owners[request.attachmentID] == request.target, let reference = references[request.attachmentID] else { throw RemoteAttachmentFailure(.invalidTarget) }
        let bytes = try await store.data(for: reference), end = min(bytes.count, request.offset + request.maxBytes)
        var data = bytes.subdata(in: request.offset..<end)
        if corruptReads, !data.isEmpty { data[0] ^= 1 }
        return .init(target: request.target, attachment: reference, offset: request.offset, data: data, eof: end == bytes.count)
    }
    private nonisolated static func digest(_ bytes: Data) -> String { RemoteAttachmentsStore.digest(bytes) }
    private func same<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }
}

@MainActor private struct RemoteAttachmentFixture {
    let root: URL
    let target = RemoteAttachmentTarget(environmentID: UUID(), projectID: UUID(), threadID: UUID())
    let store: RemoteAttachmentsStore
    let peer: RemoteAttachmentPeer
    var clientRoot: URL { root.appendingPathComponent("Client") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-attachments-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        store = .init(root: root.appendingPathComponent("Client")); peer = try .init(root: root.appendingPathComponent("Host"))
    }
    func connect(_ host: [ChatAttachment] = []) async { await store.select(target: target, transport: peer.transport, hostDraftAttachments: host, supported: true) }
    func remove() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@MainActor private func remoteAttachmentsEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned remote attachment fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteAttachmentsNativeImportsPreservePrivateCopiesAcrossSelectionDisconnectAndRestart() async throws {
    let f = try RemoteAttachmentFixture()
    do {
        await f.connect()
        let source = f.root.appendingPathComponent("Original note.txt"), bytes = Data("Original private note".utf8)
        try bytes.write(to: source)
        let provider = NSItemProvider(object: source as NSURL)
        f.store.importAttachments(files: [source, f.root], providers: [provider])
        try await remoteAttachmentsEventually { !f.store.isImporting }
        #expect(f.store.entries.count == 2)
        let references = f.store.entries.map(\.local)
        try FileManager.default.removeItem(at: source)
        for reference in references { #expect(try await f.store.localData(reference) == bytes) }
        let other = RemoteAttachmentTarget(environmentID: f.target.environmentID, projectID: f.target.projectID, threadID: UUID())
        await f.store.select(target: other, transport: f.peer.transport, hostDraftAttachments: [], supported: true)
        #expect(!f.store.hasAttachments && f.store.retainedDrafts.count == 1)
        f.store.disconnect(); await f.store.shutdown()
        let reopened = RemoteAttachmentsStore(root: f.clientRoot)
        await reopened.select(target: f.target, transport: nil, hostDraftAttachments: [], supported: true)
        #expect(reopened.entries.map(\.local) == references && !reopened.hasUnsavedDrafts)
        for reference in references { #expect(try await reopened.localData(reference) == bytes) }
        let counts = await f.peer.counts(); #expect(counts == [0, 0, 0, 0, 0, 0])
        let copies = try FileManager.default.contentsOfDirectory(at: f.clientRoot.appendingPathComponent("Copies"), includingPropertiesForKeys: nil)
        for file in copies { #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600) }
        await reopened.shutdown(); await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteAttachmentsUncertainFinalizeChecksExactIdentityAndAcknowledgementKeepsNewerDraftEntries() async throws {
    let f = try RemoteAttachmentFixture()
    do {
        await f.connect(); await f.store.importData(Data(repeating: 97, count: 1_100_000), name: "captured.bin")
        let entry = try #require(f.store.entries.first)
        await f.peer.setDropFinalize()
        #expect(await f.store.upload(entry.id) == false)
        #expect(entry.requiresCheck && entry.remote?.state == .uncertain)
        let originalRequest = try #require(entry.upload)
        await f.store.shutdown()
        let reopened = RemoteAttachmentsStore(root: f.clientRoot)
        await reopened.select(target: f.target, transport: f.peer.transport, hostDraftAttachments: [], supported: true)
        let restored = try #require(reopened.entries.first)
        #expect(restored.upload == originalRequest && restored.requiresCheck)
        let before = await f.peer.counts()
        #expect(await reopened.prepareSubmission() == nil)
        #expect(await f.peer.counts() == before)
        await reopened.checkUpload(restored.id)
        #expect(restored.isReady && restored.remote?.attachment?.id != restored.local.id)
        let submitted = try #require(await reopened.prepareSubmission())
        await reopened.importData(Data("Keep newer text file".utf8), name: "newer.txt")
        #expect(await reopened.acknowledge(target: f.target, uploadedAttachmentIDs: submitted.uploadedAttachmentIDs))
        #expect(reopened.entries.map { $0.local.name } == ["newer.txt"])
        let counts = await f.peer.counts(), sizes = await f.peer.sizes()
        #expect(counts[0] == 1 && counts[2] == 1 && counts[3] == 1)
        #expect(sizes.count == 5 && sizes.allSatisfy { $0 <= RemoteAttachmentProtocol.maximumChunkBytes })
        await reopened.shutdown(); await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteAttachmentsCapturedSubmissionCannotFollowSelectionAndPreservesLaterImports() async throws {
    let f = try RemoteAttachmentFixture(), boundary = RemoteAttachmentBoundary()
    do {
        await f.connect(); await f.store.importData(Data("Captured".utf8), name: "first.txt")
        await f.peer.setBoundary(boundary)
        let preparation = Task { await f.store.prepareSubmission() }; await boundary.entered()
        await f.store.importData(Data("Later import".utf8), name: "second.txt")
        let next = RemoteAttachmentTarget(environmentID: f.target.environmentID, projectID: f.target.projectID, threadID: UUID())
        await f.store.select(target: next, transport: f.peer.transport, hostDraftAttachments: [], supported: true)
        await boundary.release(); #expect(await preparation.value == nil)
        #expect(f.store.entries.isEmpty)
        await f.connect()
        #expect(f.store.entries.map { $0.local.name } == ["first.txt", "second.txt"])
        #expect(f.store.entries.first?.isReady == true)
        await f.remove()
    } catch { await boundary.release(); await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteAttachmentsCancelDoesNotWaitForOldFinalizeAndLateContinuationCannotReviveCancelledUpload() async throws {
    let f = try RemoteAttachmentFixture(), boundary = RemoteAttachmentBoundary()
    do {
        await f.connect(); await f.store.importData(Data("Private cancellation proof".utf8), name: "cancel.txt")
        let entry = try #require(f.store.entries.first)
        await f.peer.setBoundary(boundary)
        let upload = Task { await f.store.upload(entry.id) }; await boundary.entered()
        await f.store.cancelUpload(entry.id)
        #expect(entry.remote?.state == .cancelled && !entry.requiresCheck && f.store.entries.count == 1)
        await boundary.release(); #expect(await upload.value == false)
        #expect(entry.remote?.state == .cancelled && !entry.requiresCheck)
        let original = entry.upload?.id
        #expect(await f.store.upload(entry.id))
        #expect(entry.upload?.id != original && entry.isReady)
        await f.remove()
    } catch { await boundary.release(); await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteAttachmentsHistoryDownloadsVerifyBytesAndCreateFreshLocalUUIDWithoutResolvingRemoteIDs() async throws {
    let f = try RemoteAttachmentFixture()
    do {
        await f.connect()
        let bytes = Data(repeating: 83, count: RemoteAttachmentProtocol.maximumChunkBytes + 41)
        let reference = try await f.peer.seed(bytes, name: "Remote original.txt", target: f.target)
        let access = f.store.access(target: f.target)
        #expect(try await access.data(reference) == bytes)
        let files = try FileManager.default.contentsOfDirectory(at: f.clientRoot.appendingPathComponent("Copies"), includingPropertiesForKeys: nil)
        #expect(files.count == 1 && !files[0].lastPathComponent.hasPrefix(reference.id.uuidString))
        f.store.disconnect()
        #expect(try await access.data(reference) == bytes)
        await f.connect()
        let uncached = try await f.peer.seed(Data("Uncached across lease".utf8), name: "uncached.txt", target: f.target)
        let oldAccess = f.store.access(target: f.target), before = await f.peer.counts()
        f.store.disconnect(); await f.connect()
        await #expect(throws: CancellationError.self) { try await oldAccess.data(uncached) }
        #expect(await f.peer.counts() == before)
        let wrong = RemoteAttachmentTarget(environmentID: f.target.environmentID, projectID: f.target.projectID, threadID: UUID())
        await #expect(throws: RemoteAttachmentFailure(.invalidTarget)) { try await f.store.access(target: wrong).data(reference) }
        await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteAttachmentsRejectChangedDownloadBytesAndPreserveCorruptPrivateManifest() async throws {
    let f = try RemoteAttachmentFixture()
    do {
        await f.connect()
        let reference = try await f.peer.seed(Data("Immutable host bytes".utf8), name: "remote.txt", target: f.target)
        await f.peer.setCorruptReads(true)
        await #expect(throws: RemoteAttachmentFailure(.integrity)) { try await f.store.access(target: f.target).data(reference) }
        await f.store.importData(Data("Retained draft".utf8), name: "draft.txt"); await f.store.shutdown()
        let manifest = f.clientRoot.appendingPathComponent("Manifests/attachments-" + f.target.environmentID.uuidString.lowercased() + ".json")
        let corrupt = Data("owned corrupt attachment manifest".utf8); try corrupt.write(to: manifest)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        let reopened = RemoteAttachmentsStore(root: f.clientRoot)
        await reopened.select(target: f.target, transport: f.peer.transport, hostDraftAttachments: [], supported: true)
        #expect(reopened.current == nil && reopened.hasUnsavedDrafts && reopened.errorMessage != nil)
        await reopened.importData(Data("Must not replace corrupt data".utf8), name: "new.txt")
        #expect(try Data(contentsOf: manifest) == corrupt)
        await reopened.shutdown(); await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteAttachmentsManifestCASPreservesOtherWriterAndRejectsEscapingNames() async throws {
    let f = try RemoteAttachmentFixture()
    do {
        let first = RemoteAttachmentDraftPersistence(root: f.clientRoot), second = RemoteAttachmentDraftPersistence(root: f.clientRoot)
        _ = try await first.load(environmentID: f.target.environmentID); _ = try await second.load(environmentID: f.target.environmentID)
        let reference = try await first.importData(Data("First manifest writer".utf8), name: "first.txt")
        let record = RemoteAttachmentDraftRecord(target: f.target, entries: [.init(local: reference)])
        try await first.save(environmentID: f.target.environmentID, drafts: [record])
        await #expect(throws: RemoteEnvironmentStorageError(.commandChanged)) {
            try await second.save(environmentID: f.target.environmentID, drafts: [])
        }
        let reopened = RemoteAttachmentDraftPersistence(root: f.clientRoot)
        let restored = try await reopened.load(environmentID: f.target.environmentID)
        #expect(restored.first?.entries.first?.local == reference)
        let documents = RemotePrivateDocumentStore(root: f.clientRoot.appendingPathComponent("Manifests"))
        await #expect(throws: (any Error).self) { try await documents.save(data: Data(), name: "../escape.json", maximum: 1_024, expected: nil) }
        #expect(!FileManager.default.fileExists(atPath: f.clientRoot.appendingPathComponent("escape.json").path))
        await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteAttachmentsImagePasteUsesNativeNormalizationAndRejectsOversizedImportBatchWithoutLosingDraft() async throws {
    let f = try RemoteAttachmentFixture()
    do {
        await f.connect()
        let context = try #require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage()), output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
        let bytes = output as Data, provider = NSItemProvider()
        provider.suggestedName = "Native pasted scan.tiff"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { completion in completion(bytes, nil); return nil }
        f.store.importAttachments(providers: [provider])
        try await remoteAttachmentsEventually { !f.store.isImporting }
        let reference = try #require(f.store.entries.first?.local)
        #expect(reference.mimeType == "image/jpeg" && reference.isImage && reference.fileExtension == "jpg")
        let local = try await f.store.localData(reference)
        #expect(local != bytes && reference.digest == RemoteAttachmentsStore.digest(local))
        f.store.importAttachments(providers: Array(repeating: provider, count: 101))
        #expect(f.store.entries.count == 1 && !f.store.isImporting && f.store.errorMessage != nil)
        let counts = await f.peer.counts(); #expect(counts == [0, 0, 0, 0, 0, 0])
        await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteAttachmentsSameLiveClientRefreshDoesNotCancelFirstSelectedConversationUpload() async throws {
    let f = try RemoteAttachmentFixture()
    let state = f.root.appendingPathComponent("identity-state.json"), script = f.root.appendingPathComponent("identity-peer.py")
    let release = f.root.appendingPathComponent("identity-release")
    let descriptor = RemoteEnvironmentDescriptor(environmentID: f.target.environmentID, label: "Owned attachment identity fixture")
    let configuration = JSONValue.object([
        "descriptor": try RemoteEnvironmentProtocol.encode(descriptor),
        "snapshot": try RemoteEnvironmentProtocol.encode(RemoteEnvironmentSnapshot(environmentID: f.target.environmentID, sequence: 1, workspace: .init())),
        "target": try RemoteEnvironmentProtocol.encode(f.target), "attachmentID": .string(UUID().uuidString)
    ])
    try JSONEncoder().encode(configuration).write(to: state)
    try #"""
import base64, hashlib, json, sys, time
from pathlib import Path
root=Path(sys.argv[1])
state=json.loads((root/'identity-state.json').read_text())
uploads={}
for line in sys.stdin:
    frame=json.loads(line); method=frame['method']; params=frame.get('params',{})
    if method=='remoteEnvironment.describe': result=state['descriptor']
    elif method in ('remoteEnvironment.snapshot','remoteEnvironment.subscribe'): result=state['snapshot']
    elif method=='remoteEnvironment.attachment.begin':
        assert params['target']==state['target']
        uploads[params['id']]={'request':params,'state':'receiving','receivedChunks':[]}
        result=uploads[params['id']]
    elif method=='remoteEnvironment.attachment.append':
        request=params['upload']; data=base64.b64decode(params['data'])
        assert hashlib.sha256(data).hexdigest()==params['digest']
        (root/('identity-chunk-'+str(params['index']))).write_bytes(data)
        result=uploads[request['id']]; result['receivedChunks'].append(params['index'])
    elif method=='remoteEnvironment.attachment.finalize':
        (root/'identity-finalize-entered').touch()
        while not (root/'identity-release').exists(): time.sleep(.005)
        result=uploads[params['id']]
        data=b''.join((root/('identity-chunk-'+str(i))).read_bytes() for i in sorted(result['receivedChunks']))
        assert len(data)==params['byteCount'] and hashlib.sha256(data).hexdigest()==params['digest']
        result['state']='ready'
        result['attachment']={'id':state['attachmentID'],'name':params['name'],'mimeType':'text/plain','byteCount':len(data),'digest':params['digest'],'fileExtension':'txt'}
    elif method=='remoteEnvironment.close':
        print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':{'environmentID':state['descriptor']['environmentID']}}),flush=True)
        break
    else: raise AssertionError('Unexpected owned attachment identity fixture method')
    print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True)
"""#.write(to: script, atomically: false, encoding: .utf8)
    for file in [state, script] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    let fixtureRoot = f.root
    let client = RemoteEnvironmentClient(factory: {
        try JSONRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, fixtureRoot.path], cwd: fixtureRoot,
            dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
            environment: ["PATH": "/usr/bin:/bin", "HOME": fixtureRoot.path], drainProcessOnClose: true)
    }, expectedEnvironmentID: f.target.environmentID)
    var uploading: Task<Bool, Never>?
    do {
        _ = try await client.discover(); _ = try await client.connect()
        await f.store.select(target: f.target, client: client, hostDraftAttachments: [], supported: true)
        await f.store.importData(Data("Exact live client identity".utf8), name: "identity.txt")
        let entry = try #require(f.store.entries.first)
        uploading = Task { await f.store.upload(entry.id) }
        try await remoteAttachmentsEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("identity-finalize-entered").path) }
        await f.store.select(target: f.target, client: client, hostDraftAttachments: [], supported: true)
        #expect(entry.isUploading && !entry.requiresCheck)
        try Data().write(to: release)
        #expect(await uploading?.value == true)
        #expect(entry.isReady && !entry.requiresCheck)
        await client.close(); await f.remove()
    } catch {
        try? Data().write(to: release); _ = await uploading?.value
        await client.close(); await f.remove(); throw error
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteAttachmentsImportAndUploadFlagsInvalidateObservationAtStartAndCompletionWithoutWindows() async throws {
    let f = try RemoteAttachmentFixture(), boundary = RemoteAttachmentBoundary()
    do {
        await f.connect()
        let provider = NSItemProvider(), progress = Progress(totalUnitCount: 1), loading = RemoteAttachmentObservationFlag()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { _ in loading.signal(); return progress }
        let importStarted = RemoteAttachmentObservationFlag()
        withObservationTracking { _ = f.store.isImporting } onChange: { importStarted.signal() }
        f.store.importAttachments(providers: [provider])
        try await remoteAttachmentsEventually { loading.fired }
        #expect(importStarted.fired && f.store.isImporting)
        let importEnded = RemoteAttachmentObservationFlag()
        withObservationTracking { _ = f.store.isImporting } onChange: { importEnded.signal() }
        await f.store.shutdown()
        #expect(importEnded.fired && !f.store.isImporting && progress.isCancelled && !f.store.hasUnsavedDrafts)
        f.store.cancelShutdown(); await f.connect()
        await f.store.importData(Data("Observed bounded upload".utf8), name: "observed.txt")
        let entry = try #require(f.store.entries.first)
        await f.peer.setBoundary(boundary)
        let uploadStarted = RemoteAttachmentObservationFlag()
        withObservationTracking { _ = f.store.isUploading } onChange: { uploadStarted.signal() }
        let upload = Task { await f.store.upload(entry.id) }; await boundary.entered()
        #expect(uploadStarted.fired && f.store.isUploading)
        let uploadEnded = RemoteAttachmentObservationFlag()
        withObservationTracking { _ = f.store.isUploading } onChange: { uploadEnded.signal() }
        await boundary.release(); #expect(await upload.value)
        #expect(uploadEnded.fired && !f.store.isUploading && !f.store.hasUnsavedDrafts)
        await f.remove()
    } catch { await boundary.release(); await f.remove(); throw error }
}
