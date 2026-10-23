import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private struct RemoteStoreFixtureState: Codable {
    var descriptor: RemoteEnvironmentDescriptor
    var snapshot: RemoteEnvironmentSnapshot
    var mode = "normal"
}
private final class RemoteStoreFixture: @unchecked Sendable {
    let root: URL, stateURL: URL, wire: URL, script: URL
    let connection: RemoteEnvironmentConnection
    let threadID: UUID
    private let lock = NSLock()
    private var count = 0
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        stateURL = root.appendingPathComponent("state.json"); wire = root.appendingPathComponent("wire.jsonl")
        script = root.appendingPathComponent("peer.py")
        let environmentID = UUID(), project = WorkspaceProject(path: "/remote-only/project")
        let thread = CodingThread(project: project); threadID = thread.id
        connection = .init(name: "Offline remote", configuration: .init(target: "offline-alias",
            helperPath: "/remote-only/CoincideEnvironment", dataDirectory: "/remote-only/data"), environmentID: environmentID)
        var workspace = WorkspaceSnapshot(); workspace.projects = [project]; workspace.threads = [thread]
        try JSONEncoder().encode(RemoteStoreFixtureState(descriptor: .init(environmentID: environmentID, label: "Offline remote"),
            snapshot: .init(environmentID: environmentID, sequence: 10, workspace: workspace))).write(to: stateURL)
        try Self.peer.write(to: script, atomically: false, encoding: .utf8)
        for file in [stateURL, script] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        try RemoteEnvironmentRegistry.save([connection], rootURL: root)
    }
    func factory(_ configuration: SSHRemoteEnvironmentConfiguration, _ expected: UUID?) throws -> RemoteEnvironmentClient {
        lock.withLock { count += 1 }
        return RemoteEnvironmentClient(factory: { [self] in
            try JSONRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, root.path],
                cwd: root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], drainProcessOnClose: true)
        }, expectedEnvironmentID: expected)
    }
    var launches: Int { lock.withLock { count } }
    func update(mode: String? = nil, sequence: Int64? = nil) throws {
        var value = try JSONDecoder().decode(RemoteStoreFixtureState.self, from: Data(contentsOf: stateURL))
        if let mode { value.mode = mode }
        if let sequence { value.snapshot = .init(environmentID: value.snapshot.environmentID, sequence: sequence, workspace: value.snapshot.workspace) }
        try JSONEncoder().encode(value).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    func commands() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: wire.path) else { return [] }
        return try Data(contentsOf: wire).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
            .filter { $0["method"].string == RemoteEnvironmentProtocol.commandMethod }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    private static let peer = #"""
import json, os, sys, time
from pathlib import Path
root=Path(sys.argv[1])
assert root.name.startswith('coincide-remote-store-') and os.stat(root).st_mode & 0o077 == 0
for line in sys.stdin:
    frame=json.loads(line)
    with (root/'wire.jsonl').open('a') as wire: wire.write(json.dumps(frame)+'\n')
    state=json.loads((root/'state.json').read_text())
    method=frame['method']; params=frame.get('params', {})
    environment=state['descriptor']['environmentID']
    if method == 'remoteEnvironment.describe': result=state['descriptor']
    elif method in ('remoteEnvironment.subscribe', 'remoteEnvironment.snapshot'):
        assert params['environmentID']==environment
        result=state['snapshot']
    elif method == 'remoteEnvironment.command':
        assert params['environmentID']==environment
        (root/'last-command.json').write_text(json.dumps(params))
        if state['mode']=='drop-command': sys.exit(0)
        result={'environmentID':environment,'receipt':{'commandID':params['id'],'sequence':10,'eventCount':0,'acceptedAt':0}}
    elif method == 'remoteEnvironment.receipt':
        original=json.loads((root/'last-command.json').read_text())
        assert original==params
        receipt=None if state['mode']=='receipt-missing' else {'commandID':params['id'],'sequence':10,'eventCount':0,'acceptedAt':0}
        result={'environmentID':environment,'receipt':receipt}
    elif method == 'remoteEnvironment.close':
        if state['mode']=='hold-close':
            (root/'close-entered').touch()
            while not (root/'release-close').exists(): time.sleep(.005)
        print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':{'environmentID':environment}}),flush=True)
        break
    else: raise AssertionError('Unexpected remote store fixture method')
    print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True)
    if method=='remoteEnvironment.subscribe' and state['mode']=='disconnect-after-subscribe':
        # A valid subscribe response may already be waking the Store while this
        # invalid notification retires the exact connection. It must stay dead.
        invalid=dict(state['snapshot']); invalid['environmentID']='00000000-0000-0000-0000-000000000001'
        print(json.dumps({'jsonrpc':'2.0','method':'remoteEnvironment.snapshotChanged','params':invalid}),flush=True)
"""#
}

@MainActor private func remoteStoreEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private remote store fixture did not reach its owned boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteStoreReopensExactPendingReceiptWithoutReplayingAndPreservesNewerDisconnectedDraft() async throws {
    let f = try RemoteStoreFixture(); defer { f.remove() }
    let first = RemoteWorkspaceStore(root: f.root, clientFactory: { try f.factory($0, $1) })
    var reopened: RemoteWorkspaceStore?
    do {
        await first.load(); await first.connect(f.connection)
        #expect(first.isConnected && first.selectedThreadID == f.threadID)
        let original = "Original uncertain Caf\u{00e9}", newer = "Original uncertain Cafe\u{0301}"
        first.setDraft(original, threadID: f.threadID)
        try f.update(mode: "drop-command")
        await first.submit()
        let pending = try #require(first.pending)
        #expect(first.draft == original && !first.canWrite)
        first.setDraft(newer, threadID: f.threadID)
        await first.shutdown()
        #expect(!first.hasUnsavedDrafts)
        try f.update(mode: "receipt-missing")
        let next = RemoteWorkspaceStore(root: f.root, clientFactory: { try f.factory($0, $1) }); reopened = next
        await next.load(); await next.connect(f.connection)
        #expect(next.isConnected && next.pending == pending && Array(next.draft.utf8) == Array(newer.utf8))
        #expect(try f.commands().count == 1)
        await next.checkPendingResult()
        #expect(next.pending == pending && !next.canWrite && Array(next.draft.utf8) == Array(newer.utf8))
        try f.update(mode: "normal")
        await next.checkPendingResult()
        #expect(next.pending == nil && next.canWrite && Array(next.draft.utf8) == Array(newer.utf8))
        #expect(try f.commands().count == 1)
        await next.shutdown()
        let saved = try await RemoteEnvironmentDraftStore(root: f.root.appendingPathComponent("Drafts")).load(environmentID: f.connection.environmentID)
        #expect(saved[f.threadID].map { Array($0.utf8) } == Array(newer.utf8))
    } catch { await first.shutdown(); await reopened?.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteStoreDisconnectCancelsAConnectAwaitingOldOwnedProcessClose() async throws {
    let f = try RemoteStoreFixture(); defer { f.remove() }
    let store = RemoteWorkspaceStore(root: f.root, clientFactory: { try f.factory($0, $1) })
    var connecting: Task<Void, Never>?
    do {
        await store.load(); await store.connect(f.connection)
        #expect(store.isConnected && f.launches == 1)
        try f.update(mode: "hold-close")
        connecting = Task { await store.connect(f.connection) }
        try await remoteStoreEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("close-entered").path) }
        await store.disconnect()
        try Data().write(to: f.root.appendingPathComponent("release-close"))
        await connecting?.value
        #expect(!store.isConnected && f.launches == 1)
        await store.shutdown()
    } catch {
        try? Data().write(to: f.root.appendingPathComponent("release-close"))
        await connecting?.value; await store.shutdown(); throw error
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteStoreCarriesExactEnvironmentSequenceFloorAcrossReplacementClients() async throws {
    let f = try RemoteStoreFixture(); defer { f.remove() }
    let store = RemoteWorkspaceStore(root: f.root, clientFactory: { try f.factory($0, $1) })
    do {
        await store.load(); await store.connect(f.connection)
        #expect(store.isConnected && store.snapshot?.sequence == 10)
        try f.update(sequence: 9); await store.reconnect()
        #expect(!store.isConnected && !store.canWrite && store.errorMessage == RemoteEnvironmentClientError(.sequenceRegression).localizedDescription)
        #expect(try f.commands().isEmpty)
        try f.update(sequence: 11); await store.reconnect()
        #expect(store.isConnected && store.snapshot?.sequence == 11)
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteStoreUnsolicitedDisconnectDuringSubscribeCannotRepublishWriteAccessAndAllowsExplicitReconnect() async throws {
    let f = try RemoteStoreFixture(); defer { f.remove() }
    let store = RemoteWorkspaceStore(root: f.root, clientFactory: { try f.factory($0, $1) })
    do {
        try f.update(mode: "disconnect-after-subscribe")
        await store.load(); await store.connect(f.connection)
        try await remoteStoreEventually { !store.isConnected && (store.notice != nil || store.errorMessage != nil) }
        #expect(!store.canWrite && f.launches == 1)
        #expect(try f.commands().isEmpty)
        try f.update(mode: "normal")
        await store.reconnect()
        #expect(store.isConnected && store.canWrite && f.launches == 2)
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteStoreDrainsQueuedDraftsRejectsShutdownEditsAndExposesPreservedPersistenceFailure() async throws {
    let f = try RemoteStoreFixture(); defer { f.remove() }
    let store = RemoteWorkspaceStore(root: f.root, clientFactory: { try f.factory($0, $1) })
    do {
        await store.load(); await store.connect(f.connection)
        for index in 0..<20 { store.setDraft("Latest queued draft \(index)", threadID: f.threadID) }
        await store.disconnect()
        let draftsRoot = f.root.appendingPathComponent("Drafts"), saved = try await RemoteEnvironmentDraftStore(root: draftsRoot).load(environmentID: f.connection.environmentID)
        #expect(saved[f.threadID] == "Latest queued draft 19" && !store.hasUnsavedDrafts)
        let file = draftsRoot.appendingPathComponent("drafts-" + f.connection.environmentID.uuidString.lowercased() + ".json")
        let corrupt = Data("private-corrupt-draft-store".utf8); try corrupt.write(to: file)
        store.setDraft("Keep this window's unsaved text", threadID: f.threadID)
        await store.shutdown()
        #expect(store.hasUnsavedDrafts && store.draft == "Keep this window's unsaved text")
        store.setDraft("Late edit must be ignored", threadID: f.threadID)
        #expect(store.draft == "Keep this window's unsaved text")
        #expect(try Data(contentsOf: file) == corrupt)
        store.cancelShutdown()
        store.setDraft("Editable after cancelled Quit", threadID: f.threadID)
        await store.shutdown()
        #expect(store.draft == "Editable after cancelled Quit" && store.hasUnsavedDrafts)
        #expect(try Data(contentsOf: file) == corrupt)
    } catch { await store.shutdown(); throw error }
}
