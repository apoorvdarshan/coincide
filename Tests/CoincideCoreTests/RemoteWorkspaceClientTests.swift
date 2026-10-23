import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct WorkspaceClientPeerState: Codable {
    let descriptor: RemoteEnvironmentDescriptor
    let snapshot: RemoteEnvironmentSnapshot
    let read: RemoteWorkspaceReadResult
    let operation: RemoteWorkspaceOperation?
}

/// An owned, offline protocol peer can return decodable but semantically wrong
/// replies. No native workspace or installed provider is available to it.
private struct WorkspaceClientPeer: Sendable {
    let root: URL, script: URL
    let request: RemoteWorkspaceMutationRequest

    init(mode: String) throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("coincide-workspace-client-\(UUID())").resolvingSymlinksInPath()
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        script = root.appendingPathComponent("peer.py")
        let environmentID = UUID(), project = WorkspaceProject(path: "/offline-remote/workspace")
        let thread = CodingThread(project: project)
        let target = RemoteWorkspaceTarget(environmentID: environmentID, projectID: project.id, threadID: thread.id,
            configuration: .init(thread: thread), rootID: UUID())
        request = .init(target: target, mutation: .createFile(path: "draft.txt", contents: "Caf\u{e9}"))
        let good = RemoteWorkspaceDocument(relativePath: "draft.txt", contents: "Caf\u{e9}", byteLength: 5,
            truncated: false, exists: true, revision: UUID())
        let document: RemoteWorkspaceDocument
        switch mode {
        case "read-path", "receipt-path":
            document = .init(relativePath: "different.txt", contents: good.contents, byteLength: good.byteLength,
                truncated: false, exists: true, revision: good.revision)
        case "receipt-text":
            // Canonically equal Swift Strings must still fail exact wire bytes.
            document = .init(relativePath: good.relativePath, contents: "Cafe\u{301}", byteLength: 6,
                truncated: false, exists: true, revision: good.revision)
        case "read-revision", "receipt-revision":
            document = .init(relativePath: good.relativePath, contents: good.contents, byteLength: good.byteLength,
                truncated: false, exists: true, revision: nil)
        default: document = good
        }
        let value: RemoteWorkspaceValue = mode.hasSuffix("type") ? .done : .document(document)
        let operation = RemoteWorkspaceOperation(request: request, payloadDigest: try RemoteWorkspaceJournal.digest(request),
            state: .finished, result: value, failure: nil, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
        var workspace = WorkspaceSnapshot(); workspace.projects = [project]; workspace.threads = [thread]
        let state = WorkspaceClientPeerState(descriptor: .init(environmentID: environmentID, label: "Private invalid-response peer"),
            snapshot: .init(environmentID: environmentID, sequence: 10, workspace: workspace),
            read: .init(target: target, value: value), operation: mode == "nil-receipt" ? nil : operation)
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
        }, expectedEnvironmentID: request.target.environmentID)
    }
    func count(_ method: String) throws -> Int {
        let data = try Data(contentsOf: root.appendingPathComponent("wire.jsonl"))
        return try data.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
            .filter { $0["method"].string == method }.count
    }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        await client.close()
        let pids = try String(contentsOf: root.appendingPathComponent("peer-pids.txt"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        for pid in pids { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
        try FileManager.default.removeItem(at: root)
    }
    func retainFailure() { print("Synthetic workspace client peer retained at \(root.path)") }
    private static let source = #"""
import json, os, sys
from pathlib import Path
root = Path(sys.argv[1])
assert root.name.startswith('coincide-workspace-client-') and os.stat(root).st_mode & 0o077 == 0
with (root/'peer-pids.txt').open('a') as out: out.write(str(os.getpid())+'\n')
state=json.loads((root/'state.json').read_text())
for line in sys.stdin:
    frame=json.loads(line)
    with (root/'wire.jsonl').open('a') as out: out.write(json.dumps(frame)+'\n')
    method=frame['method']
    if method == 'remoteEnvironment.describe': result=state['descriptor']
    elif method in ('remoteEnvironment.subscribe','remoteEnvironment.snapshot'): result=state['snapshot']
    elif method == 'remoteEnvironment.workspace.read': result=state['read']
    elif method in ('remoteEnvironment.workspace.begin','remoteEnvironment.workspace.operation','remoteEnvironment.workspace.cancel'):
        result=state.get('operation')
    elif method == 'remoteEnvironment.close':
        result={'environmentID':state['descriptor']['environmentID']}
        print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True)
        break
    else: raise AssertionError('Unexpected workspace-client method')
    print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True)
"""#
}

@Test(.timeLimit(.minutes(1)), arguments: ["read-type", "read-path", "read-revision"])
func remoteWorkspaceClientDetachesWrongReadTypePathAndMissingRevision(mode: String) async throws {
    let peer = try WorkspaceClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        let before = try #require(await client.currentSnapshot())
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) {
            _ = try await client.readWorkspace(.init(target: peer.request.target,
                query: .readFile(path: "draft.txt", allowMissing: false, maxBytes: 2_000_000)))
        }
        #expect(await !client.isConnected())
        #expect(await client.currentSnapshot() == before)
        #expect(try peer.count(RemoteEnvironmentProtocol.workspaceReadMethod) == 1)
        #expect(try peer.count(RemoteEnvironmentProtocol.workspaceBeginMethod) == 0)
        try await peer.finish(client)
    } catch { await client.close(); peer.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["receipt-type", "receipt-path", "receipt-text", "receipt-revision"])
func remoteWorkspaceClientMalformedFinishedReceiptDetachesAndPreservesExactPendingIntent(mode: String) async throws {
    let peer = try WorkspaceClientPeer(mode: mode), client = peer.client(), pending = RemoteWorkspacePendingStore(root: peer.root)
    do {
        try await pending.save(request: peer.request)
        _ = try await client.connect()
        await #expect(throws: RemoteEnvironmentClientError(.commandUncertain, commandID: peer.request.id)) {
            _ = try await client.beginWorkspaceOperation(peer.request)
        }
        #expect(await !client.isConnected())
        let retained = try #require(await pending.load(environmentID: peer.request.target.environmentID, threadID: peer.request.target.threadID))
        #expect(try RemoteWorkspaceJournal.payload(retained) == RemoteWorkspaceJournal.payload(peer.request))
        _ = try await client.reconnect()
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: peer.request.id)) {
            _ = try await client.beginWorkspaceOperation(peer.request)
        }
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.workspaceOperation(peer.request) }
        #expect(await !client.isConnected())
        #expect(try await pending.load(environmentID: peer.request.target.environmentID, threadID: peer.request.target.threadID) == retained)
        #expect(try peer.count(RemoteEnvironmentProtocol.workspaceBeginMethod) == 1)
        #expect(try peer.count(RemoteEnvironmentProtocol.workspaceOperationMethod) == 1)
        try await peer.finish(client)
    } catch { await client.close(); peer.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteWorkspaceClientNilReceiptSurvivesReconnectWithoutPermissionToReplayOrRemovePending() async throws {
    let peer = try WorkspaceClientPeer(mode: "nil-receipt"), client = peer.client()
    let pending = RemoteWorkspacePendingStore(root: peer.root)
    do {
        try await pending.save(request: peer.request)
        _ = try await client.connect()
        #expect(try await client.workspaceOperation(peer.request) == nil)
        #expect(await client.isConnected())
        _ = try await client.reconnect()
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: peer.request.id)) {
            _ = try await client.beginWorkspaceOperation(peer.request)
        }
        #expect(try await client.workspaceOperation(peer.request) == nil)
        let reopened = RemoteWorkspacePendingStore(root: peer.root)
        let retained = try #require(await reopened.load(environmentID: peer.request.target.environmentID, threadID: peer.request.target.threadID))
        #expect(try RemoteWorkspaceJournal.payload(retained) == RemoteWorkspaceJournal.payload(peer.request))
        #expect(try peer.count(RemoteEnvironmentProtocol.workspaceBeginMethod) == 0)
        #expect(try peer.count(RemoteEnvironmentProtocol.workspaceOperationMethod) == 2)
        try await peer.finish(client)
    } catch { await client.close(); peer.retainFailure(); throw error }
}
