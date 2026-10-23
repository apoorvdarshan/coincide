import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct RemoteProjectionClientState: Codable {
    let descriptor: RemoteEnvironmentDescriptor
    let snapshot: RemoteEnvironmentSnapshot
    let binding: RemoteProjectionBinding
    let project: RemoteProjectSummary
    let detail: RemoteThreadDetail
    let messages: [RemoteMessageSummary]
    let body: Data
    let reference: RemoteProjectionContentReference
    let configuration: Data
    let mode: String
}
private struct RemoteProjectionClientPeer: Sendable {
    let root: URL, script: URL, environmentID: UUID, threadID: UUID
    let reference: RemoteProjectionContentReference, body: Data
    init(mode: String) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("coincide-projection-client-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        script = root.appendingPathComponent("metadata-peer.py"); environmentID = UUID()
        let project = WorkspaceProject(path: "/var/remote-only/projection-é"), thread = CodingThread(project: project)
        threadID = thread.id
        body = Data("Private body 🌍 e\u{301}\n".utf8)
        reference = .init(id: UUID(), kind: .text, totalBytes: body.count, digest: RemoteProjectionProtocol.digest(body))
        let configuration = try RemoteProjectionProtocol.payload(ProviderConfiguration(thread: thread)), empty = Data("[]".utf8)
        let config = RemoteProjectionContentReference(id: UUID(), kind: .configuration, totalBytes: configuration.count, digest: RemoteProjectionProtocol.digest(configuration))
        let attachments = RemoteProjectionContentReference(id: UUID(), kind: .attachmentReferences, totalBytes: empty.count, digest: RemoteProjectionProtocol.digest(empty))
        let requests = RemoteProjectionContentReference(id: UUID(), kind: .runtimeRequests, totalBytes: empty.count, digest: RemoteProjectionProtocol.digest(empty))
        let summary = RemoteThreadSummary(id: thread.id, projectID: project.id, title: .init(preview: thread.title, complete: true), workspacePath: project.path,
            provider: thread.provider, providerName: "Private peer", model: .init(preview: thread.model, complete: true), permission: thread.permission,
            state: thread.state, isPinned: false, isArchived: false, createdAt: thread.createdAt, updatedAt: thread.updatedAt, messageCount: 2, runCount: 0, queueCount: 0)
        let allowed = RemoteProjectionAvailability(allowed: true)
        let detail = RemoteThreadDetail(summary: summary, configuration: config, draft: .init(preview: "Private draft", complete: true), draftAttachments: attachments,
            runtimeRequests: requests, requestCount: 0, queuePaused: false, checkpointPolicy: .disabled, workspaceReady: true, isBusy: false,
            submit: allowed, resumeQueue: allowed, mutateFiles: allowed, openTerminal: allowed, chooseWorktree: allowed)
        let messages = [
            RemoteMessageSummary(id: "message-1", role: .user, createdAt: Date(timeIntervalSince1970: 1), text: .init(preview: "First private message", complete: true),
                attachmentCount: 0, runReference: .init(threadID: UUID(), runID: UUID())),
            .init(id: "message-2", role: .assistant, createdAt: Date(timeIntervalSince1970: 2), text: .init(preview: "Private", complete: false, content: reference), attachmentCount: 0)
        ]
        var workspace = WorkspaceSnapshot(); workspace.projects = [project]; workspace.threads = [thread]
        let binding = RemoteProjectionBinding(environmentID: environmentID, hostID: UUID(), viewID: UUID(), sequence: 10,
            fingerprint: String(repeating: "a", count: 64), scope: .catalog)
        let state = RemoteProjectionClientState(descriptor: .init(environmentID: environmentID, label: "Private projection peer", capabilities: .init(supportsBoundedProjections: true)),
            snapshot: .init(environmentID: environmentID, sequence: 10, workspace: workspace), binding: binding,
            project: .init(id: project.id, name: .init(preview: project.name, complete: true), workspacePath: project.path),
            detail: detail, messages: messages, body: body, reference: reference, configuration: configuration, mode: mode)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"))
        try Self.source.write(to: script, atomically: false, encoding: .utf8)
        for name in ["state.json", "metadata-peer.py"] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(name).path) }
    }
    func client() -> RemoteEnvironmentClient {
        .init(factory: {
            try .init(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, root.path], cwd: root,
                dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], drainProcessOnClose: true)
        }, expectedEnvironmentID: environmentID)
    }
    func rows() throws -> [JSONValue] {
        try Data(contentsOf: root.appendingPathComponent("methods.jsonl")).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func count(_ method: String) throws -> Int { try rows().filter { $0["method"].string == method }.count }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        await client.close()
        let pids = try String(contentsOf: root.appendingPathComponent("peer-pids.txt"), encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        for pid in pids { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
        try FileManager.default.removeItem(at: root)
    }
    func failed(_ client: RemoteEnvironmentClient) async { await client.close(); print("Private projection metadata fixture retained at \(root.path)") }
    private static let source = #"""
import base64,copy,json,os,sys,uuid
from pathlib import Path
root=Path(sys.argv[1]);os.umask(0o077)
assert root.name.startswith('coincide-projection-client-') and os.stat(root).st_mode & 0o077 == 0
with (root/'peer-pids.txt').open('a') as out:out.write(str(os.getpid())+'\n')
s=json.loads((root/'state.json').read_text());mode=s['mode'];different='00000000-0000-0000-0000-000000000001'
s['binding']['hostID']=str(uuid.uuid4());cursor=str(uuid.uuid4());next_cursor=str(uuid.uuid4());content_cursor=str(uuid.uuid4());opened=0;continuations=0;content_starts=0
if mode in ('old-absent','old-false'):
    if mode=='old-absent':s['descriptor']['capabilities'].pop('supportsBoundedProjections',None)
    else:s['descriptor']['capabilities']['supportsBoundedProjections']=False
def send(frame):print(json.dumps(frame),flush=True)
def binding(params):
    b=copy.deepcopy(s['binding']);b['viewID']=str(uuid.uuid4());b['scope']=copy.deepcopy(params['scope']);b['sequence']=max(10,params.get('minimumSequence') or 0)
    return b
for line in sys.stdin:
    frame=json.loads(line);method=frame['method'];p=frame.get('params',{})
    row={'method':method}
    if method=='remoteEnvironment.projection.open':row['minimumSequence']=p.get('minimumSequence')
    with (root/'methods.jsonl').open('a') as out:out.write(json.dumps(row)+'\n')
    if method=='remoteEnvironment.describe':result=s['descriptor']
    elif method in ('remoteEnvironment.snapshot','remoteEnvironment.subscribe'):result=s['snapshot']
    elif method=='remoteEnvironment.close':
        send({'jsonrpc':'2.0','id':frame['id'],'result':{'environmentID':s['descriptor']['environmentID']}});break
    elif method=='remoteEnvironment.projection.subscribe':result=binding(p)
    elif method=='remoteEnvironment.projection.open':
        result=binding(p);opened+=1
        if mode=='hint-race' and opened==1:
            assert p['minimumSequence']==10
            send({'jsonrpc':'2.0','method':'remoteEnvironment.projection.changed','params':{'environmentID':s['binding']['environmentID'],'hostID':s['binding']['hostID'],'sequence':20}})
        elif mode=='hint-race' and opened==2:assert p['minimumSequence']==20
        if mode=='open-environment':result['environmentID']=different
        elif mode=='open-host':result['hostID']=different
        elif mode=='open-scope':result['scope']={'control':{'_0':s['detail']['summary']['id']}}
        elif mode=='open-regression':result['sequence']=9
        elif mode=='open-digest':result['fingerprint']='not-a-sha256'
    elif method=='remoteEnvironment.projection.thread':
        result={'binding':copy.deepcopy(p['binding']),'thread':copy.deepcopy(s['detail'])}
        if mode=='thread-id':result['thread']['summary']['id']=different
        elif mode=='thread-config-kind':result['thread']['configuration']['kind']='text'
        elif mode=='thread-availability':result['thread']['submit']={'allowed':True,'reason':'Contradictory hold'}
    elif method=='remoteEnvironment.projection.catalog':
        page={'binding':copy.deepcopy(p['binding']),'offset':0,'items':[copy.deepcopy(s['project'])],'totalCount':1,'complete':True}
        result={'projects':{'_0':page}}
        if mode=='catalog-type':result={'threads':{'_0':{'binding':copy.deepcopy(p['binding']),'offset':0,'items':[],'totalCount':0,'complete':True}}}
    elif method=='remoteEnvironment.projection.messages':
        if mode=='drop-page':break
        if mode in ('typed-stale','typed-limit','typed-busy'):
            kind='staleCursor' if mode=='typed-stale' else 'limitExceeded' if mode=='typed-limit' else 'busy'
            send({'jsonrpc':'2.0','id':frame['id'],'error':{'code':-32001 if mode=='typed-busy' else -32006,'message':'PRIVATE_UNTRUSTED_PROJECTION_ERROR','data':{'kind':kind,'private':'PRIVATE_UNTRUSTED_PROJECTION_ERROR'}}});continue
        continuing=p.get('cursor') is not None
        result={'binding':copy.deepcopy(p['binding']),'offset':1 if continuing else 0,'items':[copy.deepcopy(s['messages'][1 if continuing else 0])],'totalCount':2,'complete':continuing}
        if not continuing:result['nextCursor']=cursor
        if mode.startswith('page-binding-'):result['binding'][mode.removeprefix('page-binding-')]=different
        elif mode=='page-duplicate':result['items']*=2;result['complete']=True;result.pop('nextCursor',None)
        elif mode=='page-first-offset':result['offset']=1;result['totalCount']=3
        elif mode=='page-empty':result['items']=[]
        elif mode=='text-missing-content':result['items'][0]['text']={'preview':'Preview','complete':False}
        elif mode=='text-preview-limit':result['items'][0]['text']={'preview':'x'*65537,'complete':True}
        elif mode=='wire-limit':result['items'][0]['text']={'preview':'x'*262144,'complete':True}
        elif mode=='attachment-ref-missing':result['items'][0]['attachmentCount']=1
        if continuing:
            continuations+=1
            if mode=='cursor-overlap':result['offset']=0;result['complete']=False;result['nextCursor']=next_cursor
            elif mode=='cursor-gap':result['offset']=2;result['totalCount']=3
            elif mode=='cursor-total':result['totalCount']=3;result['complete']=False;result['nextCursor']=next_cursor
            elif mode=='cursor-loop':result['totalCount']=3;result['complete']=False;result['nextCursor']=cursor
            elif mode=='cursor-changed-replay' and continuations>1:result['items'][0]['text']={'preview':'Changed immutable page','complete':True}
    elif method=='remoteEnvironment.projection.content':
        if p['reference']['id']==s['reference']['id']:data=base64.b64decode(s['body'])
        elif p['reference']['kind']=='configuration':data=base64.b64decode(s['configuration'])
        else:data=b'[]'
        offset=p['offset'];cut=6 if offset==0 else len(data);chunk=data[offset:cut]
        if offset==0:content_starts+=1
        result={'binding':copy.deepcopy(p['binding']),'reference':copy.deepcopy(p['reference']),'offset':offset,'data':base64.b64encode(chunk).decode(),'complete':cut==len(data)}
        if not result['complete']:result['nextCursor']=content_cursor
        if mode=='content-reference':result['reference']['id']=different
        elif mode=='content-offset':result['offset']+=1
        elif mode=='content-empty':result['data']='';result['complete']=False;result['nextCursor']=content_cursor
        elif mode=='content-digest':result['data']=base64.b64encode(b'x'*len(chunk)).decode()
        elif mode=='content-changed-replay' and content_starts>1:result['data']=base64.b64encode(b'x'*len(chunk)).decode()
        elif mode=='content-loop':
            if offset>0:result['data']=base64.b64encode(data[offset:offset+1]).decode();result['complete']=False;result['nextCursor']=content_cursor
    elif method=='remoteEnvironment.projection.release':
        result={'binding':copy.deepcopy(p['binding']),'released':True}
        if mode=='release-binding':result['binding']['viewID']=different
    else:raise AssertionError('Unexpected private projection metadata method')
    send({'jsonrpc':'2.0','id':frame['id'],'result':result})
"""#
}

@Test(.timeLimit(.minutes(1)), arguments: ["open-environment", "open-host", "open-scope", "open-regression", "open-digest"])
func remoteProjectionClientRejectsWrongOpenIdentityScopeSequenceAndFingerprint(mode: String) async throws {
    let peer = try RemoteProjectionClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connectProjection()
        let expected = RemoteEnvironmentClientError(mode == "open-environment" ? .wrongEnvironment : .invalidResponse)
        await #expect(throws: expected) { _ = try await client.openProjection(scope: .thread(peer.threadID)) }
        #expect(await !client.isConnected()); try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["page-binding-environmentID", "page-binding-hostID", "page-binding-viewID", "page-duplicate", "page-first-offset", "page-empty", "text-missing-content", "text-preview-limit", "wire-limit", "attachment-ref-missing"])
func remoteProjectionClientRejectsWrongPageOwnershipIdentityCountsAndBoundedContentMetadata(mode: String) async throws {
    let peer = try RemoteProjectionClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connectProjection(); let binding = try await client.openProjection(scope: .thread(peer.threadID))
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.projectionMessages(.init(binding: binding, threadID: peer.threadID, newestFirst: false)) }
        #expect(await !client.isConnected()); try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["cursor-overlap", "cursor-gap", "cursor-total", "cursor-loop", "cursor-changed-replay"])
func remoteProjectionClientBindsContinuationToExactOffsetTotalQueryAndImmutablePage(mode: String) async throws {
    let peer = try RemoteProjectionClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connectProjection(); let binding = try await client.openProjection(scope: .thread(peer.threadID))
        let first = try await client.projectionMessages(.init(binding: binding, threadID: peer.threadID, newestFirst: false))
        let request = RemoteProjectionMessagesRequest(binding: binding, threadID: peer.threadID, newestFirst: false, cursor: try #require(first.nextCursor))
        if mode == "cursor-changed-replay" { _ = try await client.projectionMessages(request) }
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.projectionMessages(request) }
        #expect(await !client.isConnected()); try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["content-reference", "content-offset", "content-empty", "content-digest", "content-loop"])
func remoteProjectionClientVerifiesWholeDocumentDigestAndRejectsWrongReferenceGapsStallsAndCycles(mode: String) async throws {
    let peer = try RemoteProjectionClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connectProjection(); let binding = try await client.openProjection(scope: .thread(peer.threadID))
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.projectionDocument(peer.reference, binding: binding) }
        #expect(await !client.isConnected()); try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["valid", "catalog-type", "thread-id", "thread-config-kind", "thread-availability", "release-binding"])
func remoteProjectionClientPreservesInheritedRunProvenanceAndPinsCatalogControlsAndRelease(mode: String) async throws {
    let peer = try RemoteProjectionClientPeer(mode: mode), client = peer.client()
    do {
        let catalog = try await client.connectProjection()
        if mode == "catalog-type" {
            await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.projectionCatalog(.init(binding: catalog, query: .projects)) }
        } else {
            _ = try await client.projectionCatalog(.init(binding: catalog, query: .projects))
            let binding = try await client.openProjection(scope: .thread(peer.threadID))
            if mode.hasPrefix("thread-") {
                await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.projectionThread(.init(binding: binding, threadID: peer.threadID)) }
            } else {
                _ = try await client.projectionThread(.init(binding: binding, threadID: peer.threadID))
                let first = try await client.projectionMessages(.init(binding: binding, threadID: peer.threadID, newestFirst: false))
                #expect(first.items.first?.runReference?.threadID != peer.threadID)
                let countBefore = try peer.count(RemoteProjectionProtocol.messagesMethod)
                await #expect(throws: RemoteProjectionFailure(.invalidRequest)) {
                    _ = try await client.projectionMessages(.init(binding: binding, threadID: peer.threadID, newestFirst: true, cursor: first.nextCursor))
                }
                #expect(try peer.count(RemoteProjectionProtocol.messagesMethod) == countBefore)
                let bytes = try await client.projectionDocument(peer.reference, binding: binding)
                #expect(RemoteProjectionProtocol.digest(bytes) == RemoteProjectionProtocol.digest(peer.body))
                if mode == "release-binding" { await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.projectionRelease(.init(binding: binding)) } }
                else { #expect(try await client.projectionRelease(.init(binding: binding)).released) }
            }
        }
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["old-absent", "old-false", "typed-stale", "typed-limit", "typed-busy", "drop-page"])
func remoteProjectionClientKeepsLegacyFallbackAndSanitizedTypedRefusalsAndNeverReplaysDroppedReads(mode: String) async throws {
    let peer = try RemoteProjectionClientPeer(mode: mode), client = peer.client()
    do {
        if mode.hasPrefix("old-") {
            let legacy = try await client.connect(); #expect(legacy.environmentID == peer.environmentID)
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.connectProjection() }
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.openProjection(scope: .thread(peer.threadID)) }
            #expect(try peer.rows().filter { $0["method"].string?.hasPrefix("remoteEnvironment.projection.") == true }.isEmpty)
            #expect(await client.isConnected())
        } else {
            _ = try await client.connectProjection(); let binding = try await client.openProjection(scope: .thread(peer.threadID))
            if mode == "drop-page" {
                await #expect(throws: RemoteEnvironmentClientError(.disconnected)) { _ = try await client.projectionMessages(.init(binding: binding, threadID: peer.threadID)) }
                _ = try await client.reconnectProjection()
                #expect(try peer.count(RemoteProjectionProtocol.messagesMethod) == 1)
                await #expect(throws: RemoteProjectionFailure(.staleView)) { _ = try await client.projectionMessages(.init(binding: binding, threadID: peer.threadID)) }
            } else {
                do { _ = try await client.projectionMessages(.init(binding: binding, threadID: peer.threadID)); Issue.record("Expected typed projection refusal") }
                catch let error as RemoteProjectionFailure { #expect(error.kind == (mode == "typed-stale" ? .staleCursor : .limitExceeded) && !error.localizedDescription.contains("PRIVATE_")) }
                catch let error as RemoteWorkspaceFailure { #expect(mode == "typed-busy" && error.kind == .busy && !error.localizedDescription.contains("PRIVATE_")) }
                #expect(await client.isConnected())
                _ = try await client.openProjection(scope: .control(peer.threadID))
                _ = try await client.projectionThread(.init(binding: binding, threadID: peer.threadID))
            }
        }
        #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 0)
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteProjectionClientNewHintDoesNotInvalidatePinnedOldPagesOrRaceAnAlreadyStartedOpenFloor() async throws {
    let peer = try RemoteProjectionClientPeer(mode: "hint-race"), client = peer.client()
    do {
        _ = try await client.connectProjection()
        let old = try await client.openProjection(scope: .thread(peer.threadID))
        #expect(old.sequence == 10)
        let deadline = ContinuousClock.now + .seconds(5)
        while await client.currentProjectionSequence() != 20 {
            guard ContinuousClock.now < deadline else { throw CoincideError("Private projection hint was not consumed") }
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = try await client.projectionMessages(.init(binding: old, threadID: peer.threadID))
        let fresh = try await client.openProjection(scope: .control(peer.threadID))
        #expect(fresh.sequence == 20)
        _ = try await client.projectionMessages(.init(binding: old, threadID: peer.threadID))
        #expect(await client.isConnected()); try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["document-byte-budget", "content-offset", "control-transcript"])
func remoteProjectionClientRefusesInvalidLocalBudgetsOffsetsAndControlScopeWithoutSendingReads(mode: String) async throws {
    let peer = try RemoteProjectionClientPeer(mode: "valid"), client = peer.client()
    do {
        _ = try await client.connectProjection()
        let binding = try await client.openProjection(scope: mode == "control-transcript" ? .control(peer.threadID) : .thread(peer.threadID))
        switch mode {
        case "document-byte-budget":
            await #expect(throws: RemoteEnvironmentClientError(.limitExceeded)) {
                _ = try await client.projectionDocument(peer.reference, binding: binding, maximumBytes: peer.reference.totalBytes - 1)
            }
        case "content-offset":
            await #expect(throws: RemoteProjectionFailure(.invalidRequest)) {
                _ = try await client.projectionContent(.init(binding: binding, reference: peer.reference, offset: 1))
            }
        default:
            await #expect(throws: RemoteProjectionFailure(.invalidRequest)) {
                _ = try await client.projectionMessages(.init(binding: binding, threadID: peer.threadID))
            }
        }
        let messages = try peer.count(RemoteProjectionProtocol.messagesMethod), contents = try peer.count(RemoteProjectionProtocol.contentMethod)
        #expect(messages == 0 && contents == 0)
        #expect(await client.isConnected()); try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["valid", "content-changed-replay"])
func remoteProjectionClientRepeatingExactContentReadIsIdempotentAndChangedBytesDetachBeforeAssembly(mode: String) async throws {
    let peer = try RemoteProjectionClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connectProjection(); let binding = try await client.openProjection(scope: .thread(peer.threadID))
        let request = RemoteProjectionContentRequest(binding: binding, reference: peer.reference)
        let first = try await client.projectionContent(request)
        if mode == "valid" {
            #expect(try await client.projectionContent(request) == first)
            let bytes = try await client.projectionDocument(peer.reference, binding: binding)
            #expect(RemoteProjectionProtocol.digest(bytes) == RemoteProjectionProtocol.digest(peer.body))
            #expect(await client.isConnected())
        } else {
            await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.projectionContent(request) }
            #expect(await !client.isConnected())
        }
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}
