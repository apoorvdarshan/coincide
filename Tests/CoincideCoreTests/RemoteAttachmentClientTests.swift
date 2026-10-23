import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct AttachmentClientPeerState: Codable {
    let descriptor: RemoteEnvironmentDescriptor
    let snapshot: RemoteEnvironmentSnapshot
    let upload: RemoteAttachmentUpload
    let download: RemoteAttachmentDownloadResult
    let commandID: UUID
    let mode: String
}
/// This peer has only synthetic protocol metadata and four private bytes. It
/// cannot access a native workspace, provider, credential or network endpoint.
private struct AttachmentClientPeer: Sendable {
    let root: URL, script: URL
    let upload: RemoteAttachmentUploadRequest, reference: ChatAttachment
    let command: RemoteEnvironmentCommand, commandID: UUID
    init(mode: String) throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("coincide-attachment-client-\(UUID())").resolvingSymlinksInPath()
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        script = root.appendingPathComponent("metadata-peer.py")
        let environment = UUID(), project = WorkspaceProject(path: "/private-offline-remote"), thread = CodingThread(project: project)
        let target = RemoteAttachmentTarget(environmentID: environment, projectID: project.id, threadID: thread.id)
        let bytes = Data("safe".utf8), digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        upload = .init(target: target, name: "note é.bin", byteCount: bytes.count, digest: digest)
        reference = .init(id: UUID(), name: upload.name, mimeType: "application/octet-stream", byteCount: bytes.count, digest: digest, fileExtension: "bin")
        commandID = UUID()
        command = .submitWithAttachments(target: target, text: "", expectedConfiguration: .init(thread: thread),
            expectedDraftAttachments: [], uploadedAttachmentIDs: [reference.id])
        var workspace = WorkspaceSnapshot(); workspace.projects = [project]; workspace.threads = [thread]
        let state = AttachmentClientPeerState(descriptor: .init(environmentID: environment, label: "Private attachment metadata peer"),
            snapshot: .init(environmentID: environment, sequence: 10, workspace: workspace),
            upload: .init(request: upload, state: .ready, receivedChunks: [0], attachment: reference),
            download: .init(target: target, attachment: reference, offset: 0, data: bytes, eof: true), commandID: commandID, mode: mode)
        let stateURL = root.appendingPathComponent("state.json")
        try JSONEncoder().encode(state).write(to: stateURL)
        try Self.source.write(to: script, atomically: false, encoding: .utf8)
        for file in [stateURL, script] { try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    }
    func client() -> RemoteEnvironmentClient {
        RemoteEnvironmentClient(factory: {
            try JSONRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, root.path],
                cwd: root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], drainProcessOnClose: true)
        }, expectedEnvironmentID: upload.target.environmentID)
    }
    func count(_ method: String) throws -> Int {
        try Data(contentsOf: root.appendingPathComponent("methods.jsonl")).split(separator: 10)
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }.filter { $0["method"].string == method }.count
    }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        await client.close()
        let pids = try String(contentsOf: root.appendingPathComponent("peer-pids.txt"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        for pid in pids { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
        try FileManager.default.removeItem(at: root)
    }
    func retained() { print("Private attachment metadata fixture retained at \(root.path)") }
    private static let source = #"""
import base64,copy,json,os,sys,unicodedata
from pathlib import Path
root=Path(sys.argv[1]);os.umask(0o077)
assert root.name.startswith('coincide-attachment-client-') and os.stat(root).st_mode & 0o077 == 0
with (root/'peer-pids.txt').open('a') as out:out.write(str(os.getpid())+'\n')
state=json.loads((root/'state.json').read_text());mode=state['mode'];different='00000000-0000-0000-0000-000000000001'
if mode=='old-helper':
    state['descriptor']['capabilities'].pop('supportsRemoteAttachments',None)
    state['descriptor']['capabilities'].pop('supportsRemotePromptSteering',None)
    state['descriptor']['capabilities'].pop('supportsRemoteThreadActions',None)
    state['descriptor']['capabilities'].pop('supportsRemoteQueueManagement',None)
for line in sys.stdin:
    frame=json.loads(line);method=frame['method']
    # Log method names only. Inline bytes, authored text and frames are omitted.
    with (root/'methods.jsonl').open('a') as out:out.write(json.dumps({'method':method})+'\n')
    if method=='remoteEnvironment.describe':result=state['descriptor']
    elif method in ('remoteEnvironment.subscribe','remoteEnvironment.snapshot'):result=state['snapshot']
    elif method=='remoteEnvironment.close':
        result={'environmentID':state['descriptor']['environmentID']}
        print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True);break
    elif method=='remoteEnvironment.receipt':result={'environmentID':state['descriptor']['environmentID'],'receipt':None}
    elif method=='remoteEnvironment.command':
        assert mode in ('drop-submit','bad-submit')
        if mode=='drop-submit':break
        result={'environmentID':state['descriptor']['environmentID'],'receipt':{'commandID':different,'sequence':11,'eventCount':1,'acceptedAt':1}}
    elif method=='remoteEnvironment.attachment.download':
        result=copy.deepcopy(state['download'])
        if mode=='download-environment':result['target']['environmentID']=different
        elif mode=='download-thread':result['target']['threadID']=different
        elif mode=='download-id':result['attachment']['id']=different
        elif mode=='download-offset':result['offset']=1
        elif mode=='download-short':result['data']=base64.b64encode(b'saf').decode()
        elif mode=='download-long':result['data']=base64.b64encode(b'safer').decode()
        elif mode=='download-eof':result['eof']=False
        elif mode=='download-metadata':result['attachment']['byteCount']=-1
        elif mode=='download-digest':result['data']=base64.b64encode(b'evil').decode()
    elif method.startswith('remoteEnvironment.attachment.'):
        if mode=='typed-error' and method=='remoteEnvironment.attachment.begin':
            print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'error':{'code':-32003,'message':'PRIVATE_UNTRUSTED_MESSAGE','data':{'kind':'integrity','privateDetail':'PRIVATE_UNTRUSTED_MESSAGE'}}}),flush=True);continue
        result=copy.deepcopy(state['upload'])
        if mode=='environment':result['request']['target']['environmentID']=different
        elif mode=='project':result['request']['target']['projectID']=different
        elif mode=='thread':result['request']['target']['threadID']=different
        elif mode=='id':result['request']['id']=different
        elif mode=='name-bytes':
            original=result['request']['name'];changed=unicodedata.normalize('NFD',original)
            assert changed.encode()!=original.encode() and unicodedata.normalize('NFC',changed)==unicodedata.normalize('NFC',original)
            result['request']['name']=changed
        elif mode=='size':result['request']['byteCount']=5
        elif mode=='digest':result['request']['digest']='0'*64
        elif mode=='duplicate-chunks':result['receivedChunks']=[0,0]
        elif mode=='chunk-range':result['receivedChunks']=[1]
        elif mode=='ready-no-reference':result.pop('attachment',None)
        elif mode=='ready-failure':result['failure']={'kind':'integrity'}
        elif mode=='receiving-reference':result['state']='receiving'
        elif mode in ('finalize-receiving','append-unconfirmed'):
            result['state']='receiving';result['receivedChunks']=[];result.pop('attachment',None)
        elif mode=='cancel-ready':pass
        elif mode=='decode':result={}
    else:raise AssertionError('Unexpected private attachment metadata method')
    print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True)
"""#
}

@Test(.timeLimit(.minutes(1)), arguments: ["environment", "project", "thread", "id", "name-bytes", "size", "digest",
    "duplicate-chunks", "chunk-range", "ready-no-reference", "ready-failure", "receiving-reference", "decode"])
func remoteAttachmentClientDetachesWrongScopeExactDescriptorAndImpossibleUploadState(mode: String) async throws {
    let peer = try AttachmentClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect(); let snapshot = await client.currentSnapshot()
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.attachmentUploadStatus(peer.upload) }
        #expect(await !client.isConnected())
        #expect(await client.currentSnapshot() == snapshot)
        #expect(try peer.count(RemoteAttachmentProtocol.statusMethod) == 1)
        #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 0)
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["download-environment", "download-thread", "download-id", "download-offset", "download-short",
    "download-long", "download-eof", "download-metadata", "download-digest"])
func remoteAttachmentClientDetachesWrongDownloadScopeRangeLengthAndFullContentDigest(mode: String) async throws {
    let peer = try AttachmentClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) {
            _ = try await client.downloadAttachment(.init(target: peer.upload.target, attachmentID: peer.reference.id, offset: 0))
        }
        #expect(await !client.isConnected())
        #expect(try peer.count(RemoteAttachmentProtocol.downloadMethod) == 1)
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["finalize-receiving", "append-unconfirmed", "cancel-ready"])
func remoteAttachmentClientRequiresMethodSpecificAcknowledgments(mode: String) async throws {
    let peer = try AttachmentClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) {
            switch mode {
            case "finalize-receiving": _ = try await client.finalizeAttachmentUpload(peer.upload)
            case "append-unconfirmed": _ = try await client.appendAttachmentChunk(.init(upload: peer.upload, index: 0, data: Data("safe".utf8), digest: peer.upload.digest))
            default: _ = try await client.cancelAttachmentUpload(peer.upload)
            }
        }
        #expect(await !client.isConnected())
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteAttachmentClientOlderCapabilityRefusesEveryTransferAndSubmitBeforeAnyRPC() async throws {
    let peer = try AttachmentClientPeer(mode: "old-helper"), client = peer.client()
    do {
        _ = try await client.connect()
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.beginAttachmentUpload(peer.upload) }
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.attachmentUploadStatus(peer.upload) }
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.finalizeAttachmentUpload(peer.upload) }
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.cancelAttachmentUpload(peer.upload) }
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) {
            _ = try await client.appendAttachmentChunk(.init(upload: peer.upload, index: 0, data: Data("safe".utf8), digest: peer.upload.digest))
        }
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) {
            _ = try await client.downloadAttachment(.init(target: peer.upload.target, attachmentID: peer.reference.id, offset: 0))
        }
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.command(peer.command) }
        for method in [RemoteAttachmentProtocol.beginMethod, RemoteAttachmentProtocol.statusMethod, RemoteAttachmentProtocol.appendMethod,
            RemoteAttachmentProtocol.finalizeMethod, RemoteAttachmentProtocol.cancelMethod, RemoteAttachmentProtocol.downloadMethod, RemoteEnvironmentProtocol.commandMethod] {
            #expect(try peer.count(method) == 0)
        }
        #expect(await client.isConnected())
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteAttachmentClientTypedFailureOmitsRawWireMessageAndKeepsConnectionAvailableForStatus() async throws {
    let peer = try AttachmentClientPeer(mode: "typed-error"), client = peer.client()
    do {
        _ = try await client.connect()
        await #expect(throws: RemoteAttachmentFailure(.integrity)) { _ = try await client.beginAttachmentUpload(peer.upload) }
        #expect(!RemoteAttachmentFailure(.integrity).localizedDescription.contains("PRIVATE_UNTRUSTED_MESSAGE"))
        #expect(await client.isConnected())
        #expect(try await client.attachmentUploadStatus(peer.upload)?.attachment == peer.reference)
        #expect(try peer.count(RemoteAttachmentProtocol.beginMethod) == 1 && peer.count(RemoteAttachmentProtocol.statusMethod) == 1)
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["drop-submit", "bad-submit"])
func remoteAttachmentClientUnknownSubmitRetainsExactPendingIdentityAndNilReceiptNeverAllowsReplay(mode: String) async throws {
    let peer = try AttachmentClientPeer(mode: mode), client = peer.client(), connectionID = UUID()
    let pending = RemoteEnvironmentPendingStore(root: peer.root.appendingPathComponent("Pending"))
    let intent = RemoteEnvironmentPendingCommand(connectionID: connectionID, environmentID: peer.upload.target.environmentID,
        id: peer.commandID, command: peer.command)
    do {
        try await pending.save(intent); _ = try await client.connect()
        await #expect(throws: RemoteEnvironmentClientError(.commandUncertain, commandID: peer.commandID)) { _ = try await client.command(peer.command, id: peer.commandID) }
        #expect(await !client.isConnected())
        #expect(try await pending.load(connectionID: connectionID) == intent)
        _ = try await client.reconnect()
        #expect(try await client.receipt(for: peer.command, id: peer.commandID).receipt == nil)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: peer.commandID)) { _ = try await client.command(peer.command, id: peer.commandID) }
        #expect(try await pending.load(connectionID: connectionID) == intent)
        #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 1 && peer.count(RemoteEnvironmentProtocol.receiptMethod) == 1)
        #expect(try peer.count(RemoteAttachmentProtocol.beginMethod) == 0 && peer.count(RemoteAttachmentProtocol.finalizeMethod) == 0)
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteSteeringOldHelperCapabilityRefusesReadAndWriteWithoutAnRPCOrSubmitFallback() async throws {
    let peer = try AttachmentClientPeer(mode: "old-helper"), client = peer.client()
    do {
        _ = try await client.connect()
        let target = RemoteWorkspaceTarget(environmentID: peer.upload.target.environmentID, projectID: peer.upload.target.projectID,
            threadID: peer.upload.target.threadID, configuration: .init(thread: CodingThread(project: WorkspaceProject(path: "/private-offline-remote"))))
        let capture = RemoteSteeringCapture(binding: .init(environmentID: target.environmentID, hostID: UUID(), viewID: UUID(), threadID: target.threadID, digest: String(repeating: "a", count: 64)),
            threadCreatedAt: .now, projectCreatedAt: nil, runID: UUID(), runtimeID: UUID(), activeConfigurationDigest: String(repeating: "b", count: 64))
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.readSteering(.init(target: target)) }
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.command(.promptSteering(target: target, action: .steerQueued(capture: capture, queuedID: UUID(), digest: String(repeating: "c", count: 64)))) }
        #expect(try peer.count(RemoteSteeringProtocol.readMethod) == 0)
        #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 0)
        #expect(await client.isConnected())
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteThreadAndQueueControlsOlderHelperRefusesWithoutAnyMutationOrReadRPC() async throws {
    let peer = try AttachmentClientPeer(mode: "old-helper"), client = peer.client()
    do {
        _ = try await client.connect()
        let project = WorkspaceProject(path: "/private/offline-metadata"), thread = CodingThread(project: project)
        let environment = peer.upload.target.environmentID
        let binding = RemoteThreadActionBinding(environmentID: environment, hostID: UUID(), leaseID: UUID(), digest: String(repeating: "a", count: 64))
        let target = RemoteWorkspaceTarget(environmentID: environment, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread))
        let capture = RemoteThreadActionCapture(id: UUID(), binding: binding, target: target, threadCreatedAt: thread.createdAt, projectCreatedAt: project.createdAt,
            runID: nil, runtimeID: nil, expectedPinned: false, expectedArchived: false, digest: String(repeating: "b", count: 64))
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.readThreadActions(.init(environmentID: environment, target: target)) }
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.command(.threadAction(.setPinned(capture: capture, value: true)), undoOwner: binding) }
        let queueCapture = RemoteSteeringCapture(binding: .init(environmentID: environment, hostID: UUID(), viewID: UUID(), threadID: thread.id, digest: String(repeating: "c", count: 64)),
            threadCreatedAt: thread.createdAt, projectCreatedAt: project.createdAt, runID: nil, runtimeID: nil, activeConfigurationDigest: nil, queueRevision: String(repeating: "d", count: 64))
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.command(.promptSteering(target: target, action: .removeQueued(capture: queueCapture, queuedID: UUID(), digest: String(repeating: "e", count: 64)))) }
        #expect(try peer.count(RemoteThreadActionsProtocol.readMethod) == 0)
        #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 0)
        #expect(await client.isConnected())
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test func remoteUndoOwnerAndQueueRevisionOmitNilAndPreserveLegacyOriginalReceiptPayloadBytes() throws {
    let environment = UUID(), project = WorkspaceProject(path: "/private/offline-legacy-payload"), thread = CodingThread(project: project)
    let legacy = RemoteEnvironmentCommandRequest(environmentID: environment, command: .submit(threadID: thread.id, text: "Original literal input e\u{301}\u{327}", expectedConfiguration: .init(thread: thread)))
    let bytes = try RemoteEnvironmentProtocol.payload(legacy)
    let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(json["undoOwner"] == nil)
    #expect(try RemoteEnvironmentProtocol.payload(JSONDecoder().decode(RemoteEnvironmentCommandRequest.self, from: bytes)) == bytes)
    let pending = RemoteEnvironmentPendingCommand(connectionID: UUID(), environmentID: environment, id: legacy.id, command: legacy.command)
    let persisted = try JSONEncoder().encode(pending), restored = try JSONDecoder().decode(RemoteEnvironmentPendingCommand.self, from: persisted)
    #expect(try RemoteEnvironmentProtocol.payload(restored.request) == bytes)
    let owner = RemoteThreadActionBinding(environmentID: environment, hostID: UUID(), leaseID: UUID(), digest: String(repeating: "f", count: 64))
    let owned = RemoteEnvironmentPendingCommand(connectionID: UUID(), environmentID: environment, id: legacy.id, command: legacy.command, undoOwner: owner)
    let ownedRestored = try JSONDecoder().decode(RemoteEnvironmentPendingCommand.self, from: JSONEncoder().encode(owned))
    #expect(ownedRestored.undoOwner == owner)
    #expect(try RemoteEnvironmentProtocol.payload(ownedRestored.request) == RemoteEnvironmentProtocol.payload(owned.request))
    let capture = RemoteSteeringCapture(binding: .init(environmentID: environment, hostID: UUID(), viewID: UUID(), threadID: thread.id, digest: String(repeating: "a", count: 64)),
        threadCreatedAt: thread.createdAt, projectCreatedAt: project.createdAt, runID: nil, runtimeID: nil, activeConfigurationDigest: nil)
    let captureJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(capture)) as? [String: Any])
    #expect(captureJSON["queueRevision"] == nil)
}
