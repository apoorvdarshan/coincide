import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct TerminalClientPeerState: Codable {
    let descriptor: RemoteEnvironmentDescriptor
    let snapshot: RemoteEnvironmentSnapshot
    let terminal: RemoteTerminalSnapshot
    let mode: String
    let methods: [String: String]
}
private struct TerminalClientPeer: Sendable {
    let root: URL, script: URL
    let reference: RemoteTerminalReference
    init(mode: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-terminal-client-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        script = root.appendingPathComponent("metadata-only-peer.py")
        let environmentID = UUID(), project = WorkspaceProject(path: "/offline-only/terminal-workspace")
        let thread = CodingThread(project: project), configuration = ProviderConfiguration(thread: thread)
        let target = RemoteWorkspaceTarget(environmentID: environmentID, projectID: project.id, threadID: thread.id,
            configuration: configuration, rootID: UUID())
        reference = .init(target: target, terminalID: UUID(), incarnation: UUID())
        let terminal = RemoteTerminalSnapshot(reference: reference, state: .running, cols: 80, rows: 24,
            outputSequence: 3, retainedStartSequence: 0, nextInputSequence: 1, inputDigest: "", inputHalted: false,
            hasForegroundCommand: false, exitCode: nil, exitSignal: nil)
        let methods = ["open": RemoteEnvironmentProtocol.terminalOpenMethod, "attach": RemoteEnvironmentProtocol.terminalAttachMethod,
            "list": RemoteEnvironmentProtocol.terminalListMethod, "read": RemoteEnvironmentProtocol.terminalReadMethod,
            "write": RemoteEnvironmentProtocol.terminalWriteMethod, "receipt": RemoteEnvironmentProtocol.terminalInputReceiptMethod]
        let state = TerminalClientPeerState(descriptor: .init(environmentID: environmentID, label: "Private terminal client peer"),
            snapshot: .init(environmentID: environmentID, sequence: 10, workspace: .init()), terminal: terminal, mode: mode, methods: methods)
        let stateURL = root.appendingPathComponent("state.json")
        try JSONEncoder().encode(state).write(to: stateURL)
        try Self.source.write(to: script, atomically: false, encoding: .utf8)
        for file in [stateURL, script] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    }
    func client() -> RemoteEnvironmentClient {
        RemoteEnvironmentClient(factory: {
            try JSONRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, root.path],
                cwd: root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], drainProcessOnClose: true)
        }, expectedEnvironmentID: reference.target.environmentID)
    }
    func metadata() throws -> [JSONValue] {
        try Data(contentsOf: root.appendingPathComponent("metadata.jsonl")).split(separator: 10)
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func count(_ method: String) throws -> Int { try metadata().filter { $0["method"].string == method }.count }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        await client.close()
        let pids = try String(contentsOf: root.appendingPathComponent("peer-pids.txt"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        for pid in pids { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
        #expect(try metadata().allSatisfy { Set($0.object?.keys.map { $0 } ?? []).isSubset(of: ["method", "sequence"]) })
        try FileManager.default.removeItem(at: root)
    }
    func retainFailure() { print("Private terminal client fixture retained at \(root.path)") }
    private static let source = #"""
import base64, copy, hashlib, json, os, sys
from pathlib import Path
root=Path(sys.argv[1])
assert root.name.startswith('coincide-terminal-client-') and os.stat(root).st_mode & 0o077 == 0
with (root/'peer-pids.txt').open('a') as out:out.write(str(os.getpid())+'\n')
state=json.loads((root/'state.json').read_text()); methods=state['methods']; mode=state['mode']
state['descriptor']['capabilities']['supportsRemoteTerminal']=True
different='00000000-0000-0000-0000-000000000001'
def receipt(params):
    data=base64.b64decode(params['data']) if 'data' in params else None
    digest=hashlib.sha256(data).hexdigest() if data is not None else params['digest']
    sequence=params['sequence']
    return {'reference':copy.deepcopy(state['terminal']['reference']),'sequence':sequence,'digest':digest,
        'byteCount':len(data) if data is not None else 4,
        'inputDigest':hashlib.sha256(('|%d|%s'%(sequence,digest)).encode()).hexdigest(),'state':'delivered'}
for line in sys.stdin:
    frame=json.loads(line); method=frame['method']; params=frame.get('params',{})
    # Never persist raw input, encoded input, digests or full request frames.
    metadata={'method':method}
    if 'sequence' in params:metadata['sequence']=params['sequence']
    with (root/'metadata.jsonl').open('a') as out:out.write(json.dumps(metadata)+'\n')
    if method=='remoteEnvironment.describe':result=state['descriptor']
    elif method in ('remoteEnvironment.subscribe','remoteEnvironment.snapshot'):result=state['snapshot']
    elif method==methods['read']:
        terminal=copy.deepcopy(state['terminal']); start=0; data=b'abc'; gap=False
        if mode=='wrong-incarnation':terminal['reference']['incarnation']=different
        if mode in ('hidden-gap','wrong-gap-start','valid-gap'):
            terminal['outputSequence']=5; terminal['retainedStartSequence']=2; start=2
            gap=mode!='hidden-gap'
            if mode=='wrong-gap-start':start=3;data=b'bc'
        result={'snapshot':terminal,'data':base64.b64encode(data).decode(),'startSequence':start,
            'nextSequence':start+len(data),'gap':gap}
    elif method==methods['write']:
        if mode=='drop-input':sys.exit(0)
        result=receipt(params)
        if mode=='ack-digest':result['digest']='0'*64
        elif mode=='ack-bytes':result['byteCount']+=1
        elif mode=='ack-incarnation':result['reference']['incarnation']=different
        elif mode=='ack-decode':result={}
    elif method==methods['receipt']:
        if mode=='drop-lookup':sys.exit(0)
        result=None if mode=='nil-lookup' else receipt(params)
        if mode=='malformed-lookup':result['reference']['incarnation']=different
    elif method==methods['open']:
        if mode=='drop-open':sys.exit(0)
        result=copy.deepcopy(state['terminal'])
        if mode=='malformed-open':result['reference']['target']['rootID']=different
    elif method==methods['list']:result=[]
    elif method==methods['attach']:result=state['terminal']
    elif method=='remoteEnvironment.close':
        result={'environmentID':state['descriptor']['environmentID']}
        print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True);break
    else:raise AssertionError('Unexpected terminal-client method')
    print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True)
"""#
}

@Test(.timeLimit(.minutes(1)), arguments: ["wrong-incarnation", "hidden-gap", "wrong-gap-start", "valid-gap"])
func remoteTerminalClientRefusesWrongIncarnationAndUndisclosedGapsButPreservesExplicitGap(mode: String) async throws {
    let peer = try TerminalClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        let request = RemoteTerminalReadRequest(reference: peer.reference)
        if mode == "valid-gap" {
            let read = try await client.readTerminal(request)
            #expect(read.gap && read.startSequence == 2 && read.nextSequence == 5 && read.data == Data("abc".utf8))
            #expect(await client.isConnected())
        } else {
            await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.readTerminal(request) }
            #expect(await !client.isConnected())
        }
        #expect(try peer.count(RemoteEnvironmentProtocol.terminalReadMethod) == 1)
        #expect(try peer.count(RemoteEnvironmentProtocol.terminalWriteMethod) == 0)
        try await peer.finish(client)
    } catch { await client.close(); peer.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["drop-input", "ack-digest", "ack-bytes", "ack-incarnation", "ack-decode"])
func remoteTerminalClientUncertainOrMalformedInputAcknowledgmentCannotReplayAcrossReconnect(mode: String) async throws {
    let peer = try TerminalClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        let input = RemoteTerminalInputRequest(reference: peer.reference, sequence: 1, data: Data([0,255,65,66]))
        await #expect(throws: RemoteTerminalFailure(.inputUncertain)) { _ = try await client.writeTerminal(input) }
        #expect(await !client.isConnected())
        _ = try await client.reconnect()
        await #expect(throws: RemoteTerminalFailure(.inputUncertain)) { _ = try await client.writeTerminal(input) }
        await #expect(throws: RemoteTerminalFailure(.inputUncertain)) {
            _ = try await client.writeTerminal(.init(reference: peer.reference, sequence: 2, data: Data([67])))
        }
        let receipt = try #require(await client.terminalInputReceipt(.init(reference: peer.reference, sequence: 1,
            digest: RemoteTerminalProtocol.inputDigest(input.data))))
        #expect(receipt.state == .delivered)
        await #expect(throws: RemoteTerminalFailure(.inputUncertain)) { _ = try await client.writeTerminal(input) }
        #expect(try peer.count(RemoteEnvironmentProtocol.terminalWriteMethod) == 1)
        #expect(try peer.count(RemoteEnvironmentProtocol.terminalInputReceiptMethod) == 1)
        try await peer.finish(client)
    } catch { await client.close(); peer.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["drop-lookup", "malformed-lookup", "nil-lookup"])
func remoteTerminalClientFreshReceiptRecoveryHaltsInputBeforeSuspensionAndNeverReplays(mode: String) async throws {
    let peer = try TerminalClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        let request = RemoteTerminalInputReceiptRequest(reference: peer.reference, sequence: 1, digest: RemoteTerminalProtocol.inputDigest(Data([0,255,65,66])))
        if mode == "nil-lookup" { #expect(try await client.terminalInputReceipt(request) == nil) }
        else {
            await #expect(throws: (any Error).self) { _ = try await client.terminalInputReceipt(request) }
            #expect(await !client.isConnected())
        }
        _ = try await client.reconnect()
        for sequence: Int64 in [1,2] {
            await #expect(throws: RemoteTerminalFailure(.inputUncertain)) {
                _ = try await client.writeTerminal(.init(reference: peer.reference, sequence: sequence, data: Data([88])))
            }
        }
        #expect(try peer.count(RemoteEnvironmentProtocol.terminalWriteMethod) == 0)
        #expect(try peer.count(RemoteEnvironmentProtocol.terminalInputReceiptMethod) == 1)
        try await peer.finish(client)
    } catch { await client.close(); peer.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["drop-open", "malformed-open"])
func remoteTerminalClientUnknownOpenOutcomeIsNotRepeatedByReconnectOrList(mode: String) async throws {
    let peer = try TerminalClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        let request = RemoteTerminalOpenRequest(target: peer.reference.target, terminalID: peer.reference.terminalID)
        await #expect(throws: RemoteEnvironmentClientError(.commandUncertain, commandID: request.id)) { _ = try await client.openTerminal(request) }
        #expect(await !client.isConnected())
        _ = try await client.reconnect()
        #expect(try await client.listTerminals(peer.reference.target).isEmpty)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: request.id)) { _ = try await client.openTerminal(request) }
        #expect(try peer.count(RemoteEnvironmentProtocol.terminalOpenMethod) == 1)
        #expect(try peer.count(RemoteEnvironmentProtocol.terminalWriteMethod) == 0)
        try await peer.finish(client)
    } catch { await client.close(); peer.retainFailure(); throw error }
}
