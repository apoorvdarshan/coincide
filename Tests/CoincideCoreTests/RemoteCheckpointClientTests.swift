import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct RemoteCheckpointClientState: Codable {
    let descriptor: RemoteEnvironmentDescriptor
    let snapshot: RemoteEnvironmentSnapshot
    let target: RemoteWorkspaceTarget
    let inventory: RemoteCheckpointInventory
    let review: RemoteCheckpointReview
    let alternateReview: RemoteCheckpointReview?
    let mode: String
}
/// Synthetic remote metadata; no local filesystem is consulted for remote paths.
private struct RemoteCheckpointClientPeer: Sendable {
    let root: URL, script: URL, target: RemoteWorkspaceTarget
    let runID: UUID, baselineID: UUID, postID: UUID, review: RemoteCheckpointReview
    init(mode: String) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("coincide-checkpoint-client-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        script = root.appendingPathComponent("metadata-peer.py")
        let environment = UUID(), project = WorkspaceProject(path: "/var/remote-checkpoint-only/é"), thread = CodingThread(project: project)
        target = .init(environmentID: environment, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread), rootID: UUID())
        runID = UUID(); baselineID = UUID(); postID = UUID()
        let identity = GitWorktreeNodeIdentity(device: 1, inode: 2), now = Date(timeIntervalSince1970: 1)
        func plan(_ id: UUID) throws -> GitCheckpointPlan {
            try .init(id: id, workspacePath: project.path, repositoryPath: project.path, gitDirectoryPath: project.path + "/.git",
                commonDirectoryPath: project.path + "/.git", workspaceIdentity: identity, repositoryIdentity: identity,
                gitDirectoryIdentity: identity, commonDirectoryIdentity: identity, objectDirectoryIdentity: identity,
                headCommit: String(repeating: "a", count: 40), configurationDigest: String(repeating: "b", count: 64), indexRevision: nil)
        }
        func attempt(_ id: UUID) throws -> ThreadRunCheckpointAttempt {
            let p = try plan(id)
            var a = ThreadRunCheckpointAttempt(id: id, workspacePath: project.path, phase: .ready, now: now)
            a.plan = p; a.receipt = try .init(plan: p, commit: String(repeating: "c", count: 40), tree: String(repeating: "d", count: 40), capturedAt: now)
            return a
        }
        let baseline = try attempt(baselineID), post = try attempt(postID), reviewID = UUID()
        let gitReview = try GitCheckpointRestoreReview(id: reviewID, targetReceipt: try #require(baseline.receipt), currentPlan: plan(UUID()),
            reviewedAt: now, manifestDigest: String(repeating: "e", count: 64), affectedPaths: ["tracked.txt"], previewPatch: "Private preview 🌍\n")
        let native = try RunCheckpointRestoreReview(id: reviewID, reviewedAt: now, threadID: thread.id, projectID: project.id,
            runID: runID, stage: .baseline, attemptID: baselineID, sourceIncarnation: UUID(), sourceFingerprint: String(repeating: "f", count: 64), checkpoint: baseline, gitReview: gitReview)
        review = try .init(target: target, value: native)
        let alternate: RemoteCheckpointReview?
        if ["review-thread", "review-project", "review-run", "review-stage"].contains(mode) {
            let changed = try RunCheckpointRestoreReview(id: native.id, reviewedAt: native.reviewedAt,
                threadID: mode == "review-thread" ? UUID() : native.threadID, projectID: mode == "review-project" ? UUID() : native.projectID,
                runID: mode == "review-run" ? UUID() : native.runID, stage: mode == "review-stage" ? .postRun : native.stage,
                attemptID: native.attemptID, sourceIncarnation: native.sourceIncarnation, sourceFingerprint: native.sourceFingerprint,
                checkpoint: baseline, gitReview: gitReview)
            alternate = try .init(target: target, value: changed)
        } else { alternate = nil }
        var workspace = WorkspaceSnapshot(); workspace.projects = [project]; workspace.threads = [thread]
        let inventory = RemoteCheckpointInventory(policy: .automatic, runs: [.init(id: runID, baseline: baseline, postRun: post,
            previousPostRunAttempts: [], restoreUnavailableReasons: [:])])
        let state = RemoteCheckpointClientState(descriptor: .init(environmentID: environment, label: "Private checkpoint metadata"),
            snapshot: .init(environmentID: environment, sequence: 10, workspace: workspace), target: target,
            inventory: inventory, review: review, alternateReview: alternate, mode: mode)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"))
        try Self.source.write(to: script, atomically: false, encoding: .utf8)
        for name in ["state.json", "metadata-peer.py"] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(name).path) }
    }
    func client() -> RemoteEnvironmentClient {
        RemoteEnvironmentClient(factory: {
            try .init(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, root.path], cwd: root,
                dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], drainProcessOnClose: true)
        }, expectedEnvironmentID: target.environmentID)
    }
    var reviewRequest: RemoteCheckpointReviewRequest { .init(target: target, runID: runID, stage: .baseline, attemptID: baselineID) }
    var diffRequest: RemoteCheckpointReadRequest { .init(target: target, query: .runDiff(runID: runID, baselineAttemptID: baselineID, postRunAttemptID: postID, maxBytes: 32)) }
    func count(_ method: String) throws -> Int {
        let data = try Data(contentsOf: root.appendingPathComponent("methods.jsonl"))
        return try data.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }.filter { $0["method"].string == method }.count
    }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        await client.close()
        let pids = try String(contentsOf: root.appendingPathComponent("peer-pids.txt"), encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        for pid in pids { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
        try FileManager.default.removeItem(at: root)
    }
    func failed(_ client: RemoteEnvironmentClient) async { await client.close(); print("Private checkpoint metadata fixture retained at \(root.path)") }
    private static let source = #"""
import copy,json,os,sys,unicodedata
from pathlib import Path
root=Path(sys.argv[1]);os.umask(0o077)
assert root.name.startswith('coincide-checkpoint-client-') and os.stat(root).st_mode & 0o077 == 0
with (root/'peer-pids.txt').open('a') as out:out.write(str(os.getpid())+'\n')
state=json.loads((root/'state.json').read_text());mode=state['mode'];different='00000000-0000-0000-0000-000000000001'
if mode=='old-helper':state['descriptor']['capabilities'].pop('supportsRemoteCheckpoints',None)
for line in sys.stdin:
    frame=json.loads(line);method=frame['method'];params=frame.get('params',{})
    # Metadata only: never record draft, command body, credentials, or full frame.
    with (root/'methods.jsonl').open('a') as out:out.write(json.dumps({'method':method})+'\n')
    if method=='remoteEnvironment.describe':result=state['descriptor']
    elif method in ('remoteEnvironment.subscribe','remoteEnvironment.snapshot'):result=state['snapshot']
    elif method=='remoteEnvironment.close':
        print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':{'environmentID':state['descriptor']['environmentID']}}),flush=True);break
    elif method=='remoteEnvironment.receipt':result={'environmentID':state['descriptor']['environmentID'],'receipt':None}
    elif method=='remoteEnvironment.command':
        if mode=='drop-begin':break
        assert mode=='bad-begin'
        result={'environmentID':state['descriptor']['environmentID'],'receipt':{'commandID':different,'sequence':11,'eventCount':1,'acceptedAt':1}}
    elif method=='remoteEnvironment.checkpoint.bind':result=copy.deepcopy(state['target'])
    elif method=='remoteEnvironment.checkpoint.read':
        if mode in ('typed-error','busy'):
            code,kind=(-32005,'staleReview') if mode=='typed-error' else (-32001,'busy')
            print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'error':{'code':code,'message':'PRIVATE_UNTRUSTED_CHECKPOINT_ERROR','data':{'kind':kind,'private':'PRIVATE_UNTRUSTED_CHECKPOINT_ERROR'}}}),flush=True);continue
        target=copy.deepcopy(state['target']);query=params['query'];inventory=copy.deepcopy(state['inventory'])
        if 'inventory' in query:value={'inventory':{'_0':inventory}}
        else:
            q=query['runDiff'];value={'diff':{'_0':{'runID':q['runID'],'baselineAttemptID':q['baselineAttemptID'],'postRunAttemptID':q['postRunAttemptID'],'patch':'Private diff 🌍\n','truncated':False}}}
        result={'target':target,'value':value}
        if mode=='read-environment':target['environmentID']=different
        elif mode=='read-thread':target['threadID']=different
        elif mode=='read-root':target['rootID']=different
        elif mode=='read-path-bytes':
            original=target['configuration']['workspacePath'];changed=unicodedata.normalize('NFD',original)
            if changed.encode()==original.encode():changed=unicodedata.normalize('NFC',original)
            assert changed.encode()!=original.encode() and unicodedata.normalize('NFC',changed)==unicodedata.normalize('NFC',original)
            target['configuration']['workspacePath']=changed
        elif mode=='read-type':result['value']={'diff':{'_0':{'runID':different,'baselineAttemptID':different,'postRunAttemptID':different,'patch':'','truncated':False}}}
        elif mode=='inventory-duplicate-run':inventory['runs']*=2
        elif mode=='inventory-duplicate-attempt':inventory['runs'][0]['postRun']=copy.deepcopy(inventory['runs'][0]['baseline'])
        elif mode=='inventory-bad-phase':inventory['runs'][0]['baseline']['receipt']=None
        elif mode=='inventory-bad-reason':inventory['runs'][0]['restoreUnavailableReasons']=[different,'Changed reason']
        elif mode.startswith('diff-'):
            diff=value['diff']['_0']
            if mode=='diff-run':diff['runID']=different
            elif mode=='diff-baseline':diff['baselineAttemptID']=different
            elif mode=='diff-post':diff['postRunAttemptID']=different
            elif mode=='diff-limit':diff['patch']='🌍'*9
    elif method=='remoteEnvironment.checkpoint.review':
        result=copy.deepcopy(state.get('alternateReview') or state['review'])
        if mode=='review-id':result['id']=different
        elif mode=='review-digest':result['digest']='0'*64
        elif mode=='review-root':result['target']['rootID']=different
        elif mode=='review-unsafe-path':result['value']['gitReview']['affectedPaths']=['../escape']
    elif method=='remoteEnvironment.checkpoint.discard':
        result={'request':copy.deepcopy(params),'discarded':True}
        if mode=='discard-binding':result['request']['reviewID']=different
    else:raise AssertionError('Unexpected private checkpoint metadata method')
    print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True)
"""#
}

@Test(.timeLimit(.minutes(1)), arguments: ["read-environment", "read-thread", "read-root", "read-path-bytes", "read-type", "inventory-duplicate-run", "inventory-duplicate-attempt", "inventory-bad-phase", "inventory-bad-reason"])
func remoteCheckpointClientRejectsWrongScopeExactPathBytesAndMalformedAttemptInventory(mode: String) async throws {
    let peer = try RemoteCheckpointClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect(); let before = await client.currentSnapshot()
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.readCheckpoints(.init(target: peer.target, query: .inventory)) }
        #expect(await !client.isConnected()); #expect(await client.currentSnapshot() == before)
        #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 0)
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["diff-run", "diff-baseline", "diff-post", "diff-limit"])
func remoteCheckpointClientPinsDiffToExactRunAttemptsAndUTF8ByteLimit(mode: String) async throws {
    let peer = try RemoteCheckpointClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.readCheckpoints(peer.diffRequest) }
        #expect(await !client.isConnected()); try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["review-thread", "review-project", "review-run", "review-stage", "review-id", "review-digest", "review-root", "review-unsafe-path"])
func remoteCheckpointClientRejectsValidlyRedigestedWrongReviewOwnershipAndUnsafeManifest(mode: String) async throws {
    let peer = try RemoteCheckpointClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.reviewCheckpointRestore(peer.reviewRequest) }
        #expect(await !client.isConnected()); #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 0)
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["valid", "discard-binding"])
func remoteCheckpointClientPreservesRemoteOnlyPathsAndExactReviewDiscardBinding(mode: String) async throws {
    let peer = try RemoteCheckpointClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        #expect(try await client.bindCheckpointWorkspace(peer.target) == peer.target)
        let value = try await client.readCheckpoints(.init(target: peer.target, query: .inventory))
        #expect(value.target.workspacePath.utf8.elementsEqual(peer.target.workspacePath.utf8))
        let review = try await client.reviewCheckpointRestore(peer.reviewRequest)
        let discard = RemoteCheckpointDiscardRequest(target: peer.target, reviewID: review.id, digest: review.digest)
        if mode == "valid" { #expect(try await client.discardCheckpointRestoreReview(discard).discarded) }
        else { await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.discardCheckpointRestoreReview(discard) } }
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["old-helper", "typed-error", "busy"])
func remoteCheckpointClientRefusesOldCapabilitiesWithoutRPCAndKeepsTypedFailuresSanitized(mode: String) async throws {
    let peer = try RemoteCheckpointClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        if mode == "old-helper" {
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.bindCheckpointWorkspace(peer.target) }
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.readCheckpoints(.init(target: peer.target, query: .inventory)) }
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.reviewCheckpointRestore(peer.reviewRequest) }
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.discardCheckpointRestoreReview(.init(target: peer.target, reviewID: peer.review.id, digest: peer.review.digest)) }
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.command(.checkpoint(target: peer.target, action: .beginRestore(reviewID: peer.review.id, digest: peer.review.digest))) }
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.command(.createThread(id: UUID(), projectID: peer.target.projectID, provider: .codex, title: "Private", model: "offline", permission: .supervised, checkpointPolicy: .automatic)) }
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.command(.editThread(threadID: peer.target.threadID, edit: .checkpointPolicy(.automatic, expected: .disabled), expectedConfiguration: peer.target.configuration)) }
            for method in [RemoteCheckpointProtocol.bindMethod, RemoteCheckpointProtocol.readMethod, RemoteCheckpointProtocol.reviewMethod, RemoteCheckpointProtocol.discardMethod, RemoteEnvironmentProtocol.commandMethod] { #expect(try peer.count(method) == 0) }
        } else {
            do { _ = try await client.readCheckpoints(.init(target: peer.target, query: .inventory)); Issue.record("Expected a typed private peer refusal") }
            catch let error as RemoteCheckpointFailure { #expect(mode == "typed-error" && error.kind == .staleReview && !error.localizedDescription.contains("PRIVATE_")) }
            catch let error as RemoteWorkspaceFailure { #expect(mode == "busy" && error.kind == .busy && !error.localizedDescription.contains("PRIVATE_")) }
        }
        #expect(await client.isConnected()); _ = try await client.snapshot()
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["drop-begin", "bad-begin"])
func remoteCheckpointClientNeverReplaysUnknownRestoreAfterReconnectOrMissingReceipt(mode: String) async throws {
    let peer = try RemoteCheckpointClientPeer(mode: mode), client = peer.client(), id = UUID()
    let command = RemoteEnvironmentCommand.checkpoint(target: peer.target, action: .beginRestore(reviewID: peer.review.id, digest: peer.review.digest))
    do {
        _ = try await client.connect()
        await #expect(throws: RemoteEnvironmentClientError(.commandUncertain, commandID: id)) { _ = try await client.command(command, id: id) }
        #expect(await !client.isConnected()); _ = try await client.reconnect()
        #expect(try await client.receipt(for: command, id: id).receipt == nil)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: id)) { _ = try await client.command(command, id: id) }
        #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 1)
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}
