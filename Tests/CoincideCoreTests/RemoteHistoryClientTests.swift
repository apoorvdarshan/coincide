import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct HistoryMetadataState: Codable {
    let descriptor: RemoteEnvironmentDescriptor
    let snapshot: RemoteEnvironmentSnapshot
    let review: RemoteHistoryReview
    let target: RemoteWorkspaceTarget
    let message: RemoteMessageSummary
    let body: Data
    let reference: RemoteProjectionContentReference
    let mode: String
}
private struct HistoryMetadataPeer: Sendable {
    let root: URL, script: URL
    let target: RemoteWorkspaceTarget
    let reviewRequest: RemoteHistoryReviewRequest
    let body: Data
    let reference: RemoteProjectionContentReference
    init(_ mode: String) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("coincide-history-client-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        script = root.appendingPathComponent("peer.py")
        let environment = UUID(), project = WorkspaceProject(path: "/remote/history-metadata"), run = UUID(), id = UUID()
        let thread = CodingThread(project: project)
        target = .init(environmentID: environment, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread), rootID: UUID())
        body = Data(String(repeating: "History 🌍 e\u{301}\n", count: 12_000).utf8)
        reference = .init(id: UUID(), kind: .text, totalBytes: body.count, digest: RemoteProjectionProtocol.digest(body))
        let configData = try RemoteHistoryProtocol.payload(target.configuration)
        let config = RemoteProjectionContentReference(id: UUID(), kind: .configuration, totalBytes: configData.count, digest: RemoteProjectionProtocol.digest(configData))
        let binding = RemoteHistoryBinding(environmentID: environment, hostID: UUID(), leaseID: UUID(), threadID: thread.id, objectID: id, digest: String(repeating: "a", count: 64))
        let review = RemoteHistoryReview(target: target, id: id, digest: binding.digest, binding: binding,
            value: .init(kind: .forkAfterRun, runID: run, reviewedAt: Date(timeIntervalSince1970: 123), provider: thread.provider,
                workspacePath: thread.workspacePath, sourceConfiguration: config, targetConfiguration: config,
                retainedMessageCount: 2, removedMessageCount: 0, removedRunCount: 0, targetThreadID: UUID(),
                suggestedTitle: .init(preview: "Fork", complete: true), files: nil, recallPromptOnSuccess: false,
                restoreFiles: .init(allowed: false, reason: "Fork keeps files")))
        reviewRequest = .init(target: target, runID: run, kind: .forkAfterRun)
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        let state = HistoryMetadataState(descriptor: .init(environmentID: environment, label: "Private history peer", capabilities: .init(supportsRemoteHistory: true)),
            snapshot: .init(environmentID: environment, sequence: 1, workspace: snapshot), review: review, target: target,
            message: .init(id: "history-message", role: .assistant, createdAt: Date(timeIntervalSince1970: 123),
                text: .init(preview: "History", complete: false, content: reference), attachmentCount: 0), body: body, reference: reference, mode: mode)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"))
        try Self.source.write(to: script, atomically: false, encoding: .utf8)
        for name in ["state.json", "peer.py"] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(name).path) }
    }
    func client() -> RemoteEnvironmentClient {
        .init(factory: {
            try .init(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, root.path], cwd: root,
                dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], drainProcessOnClose: true)
        }, expectedEnvironmentID: target.environmentID)
    }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        await client.close()
        let pids = try String(contentsOf: root.appendingPathComponent("pids"), encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        for pid in pids { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
        try FileManager.default.removeItem(at: root)
    }
    func failed(_ client: RemoteEnvironmentClient) async { await client.close(); print("Private history client fixture retained at \(root.path)") }
    static let source = #"""
import base64,copy,json,os,sys,time,uuid
from pathlib import Path
root=Path(sys.argv[1]);os.umask(0o077)
assert root.name.startswith('coincide-history-client-') and os.stat(root).st_mode & 0o077 == 0
with (root/'pids').open('a') as out:out.write(str(os.getpid())+'\n')
s=json.loads((root/'state.json').read_text());mode=s['mode'];different=str(uuid.uuid4());cursor=str(uuid.uuid4());content_cursor=str(uuid.uuid4());starts=0;continuations=0;reviews=0
if mode=='old-absent':s['descriptor']['capabilities'].pop('supportsRemoteHistory',None)
def send(frame):print(json.dumps(frame),flush=True)
for line in sys.stdin:
    f=json.loads(line);m=f['method'];p=f.get('params',{})
    with (root/'methods').open('a') as out:out.write(m+'\n')
    if m=='remoteEnvironment.describe':r=s['descriptor']
    elif m in ('remoteEnvironment.snapshot','remoteEnvironment.subscribe'):r=s['snapshot']
    elif m=='remoteEnvironment.close':
        send({'jsonrpc':'2.0','id':f['id'],'result':{'environmentID':s['target']['environmentID']}});break
    elif m=='remoteEnvironment.history.review':
        r=copy.deepcopy(s['review']);reviews+=1
        if mode=='review-binding-hostID' and reviews>1:r['binding']['hostID']=str(uuid.uuid4())
        elif mode.startswith('review-binding-') and mode!='review-binding-hostID':r['binding'][mode.removeprefix('review-binding-')]=different
        elif mode=='review-target':r['target']['rootID']=different
        elif mode=='review-run':r['value']['runID']=different
        elif mode=='review-config-kind':r['value']['sourceConfiguration']['kind']='text'
        elif mode=='review-count':r['value']['retainedMessageCount']=-1
        elif mode=='review-title':r['value']['suggestedTitle']={'preview':'partial','complete':False}
        elif mode=='review-path':r['value']['mutatingPaths']=['relative']
    elif m=='remoteEnvironment.history.discard':r={'request':p,'discarded':True}
    elif m=='remoteEnvironment.history.read':
        q=p['query'];binding=copy.deepcopy(s['review']['binding'])
        if 'release' in q:r={'target':s['target'],'value':{'released':{'_0':True}}}
        elif 'controls' in q:
            controls={'canInspectClaudeResume':False,'canInspectPiFresh':False}
            if mode=='controls-identities':controls['canInspectClaudeResume']=True
            r={'target':s['target'],'value':{'controls':{'_0':controls}}}
        elif 'prefix' in q:
            if mode=='cancel-read':
                (root/'read-entered').touch();deadline=time.monotonic()+5
                while not (root/'read-release').exists() and time.monotonic()<deadline:time.sleep(.01)
            if mode.startswith('typed-'):
                kind='busy' if mode=='typed-busy' else 'staleReview'
                send({'jsonrpc':'2.0','id':f['id'],'error':{'code':-32007,'message':'PRIVATE_HISTORY_WIRE_ERROR','data':{'kind':kind}}});continue
            params=q['prefix'];following=params.get('cursor') is not None
            page={'binding':binding,'offset':1 if following else 0,'items':[copy.deepcopy(s['message'])],'totalCount':2,'complete':following}
            if following:page['items'][0]['id']='second-message';continuations+=1
            else:page['nextCursor']=cursor
            if mode=='page-binding':page['binding']['leaseID']=different
            elif mode=='page-duplicate':page['items']*=2
            elif mode=='page-empty':page['items']=[]
            elif mode=='page-gap' and following:page['offset']=2;page['totalCount']=3
            elif mode=='page-overlap' and following:page['offset']=0;page['complete']=False;page['nextCursor']=str(uuid.uuid4())
            elif mode=='page-total' and following:page['totalCount']=3;page['complete']=False;page['nextCursor']=str(uuid.uuid4())
            elif mode=='page-loop' and following:page['totalCount']=3;page['complete']=False;page['nextCursor']=cursor
            elif mode=='page-replay' and following and continuations>1:page['items'][0]['text']={'preview':'changed','complete':True}
            elif mode=='page-wire-limit':page['items'][0]['text']={'preview':'x'*262144,'complete':True}
            r={'target':s['target'],'value':{'messages':{'_0':page}}}
        elif 'content' in q:
            params=q['content'];data=base64.b64decode(s['body']);offset=params['offset'];chunk=data[offset:offset+131072]
            if offset==0:starts+=1
            content={'binding':binding,'reference':copy.deepcopy(s['reference']),'offset':offset,'data':base64.b64encode(chunk).decode(),'complete':offset+len(chunk)==len(data)}
            if not content['complete']:content['nextCursor']=content_cursor
            if mode=='content-reference':content['reference']['id']=different
            elif mode=='content-offset':content['offset']+=1
            elif mode=='content-empty':content['data']=''
            elif mode=='content-digest' or (mode=='content-replay' and starts>1):content['data']=base64.b64encode(b'x'*len(chunk)).decode()
            r={'target':s['target'],'value':{'content':{'_0':content}}}
        else:raise AssertionError('Unexpected private query')
    else:raise AssertionError('Unexpected private method')
    send({'jsonrpc':'2.0','id':f['id'],'result':r})
"""#
}

@Test func remoteHistoryClientReadsExactContentAndReleasesOnlyItsLease() async throws {
    let peer = try HistoryMetadataPeer("valid"), client = peer.client()
    do {
        _ = try await client.connect()
        let review = try await client.reviewHistory(peer.reviewRequest)
        let first = try await client.readHistory(.init(target: peer.target, query: .prefix(binding: review.binding, newestFirst: false, cursor: nil)))
        guard case .messages(let page) = first.value else { throw CoincideError("Missing page") }
        #expect(page.offset == 0 && page.items.count == 1 && !page.complete)
        let next = try #require(page.nextCursor)
        let second = try await client.readHistory(.init(target: peer.target, query: .prefix(binding: review.binding, newestFirst: false, cursor: next)))
        guard case .messages(let final) = second.value else { throw CoincideError("Missing final page") }
        #expect(final.offset == 1 && final.complete)
        #expect(try await client.historyDocument(peer.reference, binding: review.binding, target: peer.target) == peer.body)
        _ = try await client.readHistory(.init(target: peer.target, query: .release(binding: review.binding)))
        await #expect(throws: RemoteHistoryFailure(.staleReview)) {
            _ = try await client.readHistory(.init(target: peer.target, query: .prefix(binding: review.binding, newestFirst: false, cursor: nil)))
        }
        #expect(await client.isConnected())
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(arguments: ["review-binding-environmentID", "review-binding-hostID", "review-binding-threadID", "review-binding-objectID", "review-binding-digest", "review-target", "review-run", "review-config-kind", "review-count", "review-title", "review-path"])
func remoteHistoryClientRejectsMismatchedOrIncompleteReview(mode: String) async throws {
    let peer = try HistoryMetadataPeer(mode), client = peer.client()
    do {
        _ = try await client.connect()
        // A first host identity is learned from the first valid lease. A second
        // review must keep that identity; arbitrary initial UUIDs are valid.
        if mode == "review-binding-hostID" { _ = try await client.reviewHistory(peer.reviewRequest) }
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.reviewHistory(peer.reviewRequest) }
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(arguments: ["page-binding", "page-duplicate", "page-empty", "page-gap", "page-overlap", "page-total", "page-loop", "page-replay", "page-wire-limit"])
func remoteHistoryClientRejectsInvalidOrChangingPages(mode: String) async throws {
    let peer = try HistoryMetadataPeer(mode), client = peer.client()
    do {
        _ = try await client.connect(); let review = try await client.reviewHistory(peer.reviewRequest)
        let request = RemoteHistoryReadRequest(target: peer.target, query: .prefix(binding: review.binding, newestFirst: false, cursor: nil))
        if ["page-gap", "page-overlap", "page-total", "page-loop", "page-replay"].contains(mode) {
            let first = try await client.readHistory(request)
            guard case .messages(let page) = first.value else { throw CoincideError("Missing first page") }
            let next = RemoteHistoryReadRequest(target: peer.target, query: .prefix(binding: review.binding, newestFirst: false, cursor: page.nextCursor))
            if mode == "page-replay" { _ = try await client.readHistory(next) }
            await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.readHistory(next) }
        } else { await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.readHistory(request) } }
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(arguments: ["content-reference", "content-offset", "content-empty", "content-digest", "content-replay"])
func remoteHistoryClientRejectsCorruptContentAndImmutableReadChanges(mode: String) async throws {
    let peer = try HistoryMetadataPeer(mode), client = peer.client()
    do {
        _ = try await client.connect(); let review = try await client.reviewHistory(peer.reviewRequest)
        if mode == "content-replay" {
            _ = try await client.readHistory(.init(target: peer.target, query: .content(binding: review.binding, reference: peer.reference, offset: 0, cursor: nil)))
        }
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) {
            _ = try await client.historyDocument(peer.reference, binding: review.binding, target: peer.target)
        }
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test(arguments: ["typed-busy", "typed-stale"])
func remoteHistoryClientKeepsKnownFailuresSanitizedAndConnectionUsable(mode: String) async throws {
    let peer = try HistoryMetadataPeer(mode), client = peer.client()
    do {
        _ = try await client.connect(); let review = try await client.reviewHistory(peer.reviewRequest)
        do { _ = try await client.readHistory(.init(target: peer.target, query: .prefix(binding: review.binding, newestFirst: true, cursor: nil))); Issue.record("Expected typed failure") }
        catch let error as RemoteHistoryFailure { #expect(error.kind == (mode == "typed-busy" ? .busy : .staleReview)); #expect(!error.localizedDescription.contains("PRIVATE_HISTORY_WIRE_ERROR")) }
        #expect(await client.isConnected())
        _ = try await client.snapshot()
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test func remoteHistoryClientRefusesAbsentCapabilityBeforeAnyHistoryRPC() async throws {
    let peer = try HistoryMetadataPeer("old-absent"), client = peer.client()
    do {
        _ = try await client.connect()
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.reviewHistory(peer.reviewRequest) }
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.command(.history(target: peer.target, action: .inspectProvider(operationID: UUID()))) }
        let methods = try String(contentsOf: peer.root.appendingPathComponent("methods"), encoding: .utf8)
        #expect(!methods.contains("remoteEnvironment.history.") && !methods.contains("remoteEnvironment.command"))
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
}

@Test func remoteHistoryClientBindsCursorsToExactQueryAndRequiresCompleteControlIdentities() async throws {
    let peer = try HistoryMetadataPeer("valid"), client = peer.client()
    do {
        _ = try await client.connect(); let review = try await client.reviewHistory(peer.reviewRequest)
        let result = try await client.readHistory(.init(target: peer.target, query: .prefix(binding: review.binding, newestFirst: false, cursor: nil)))
        guard case .messages(let page) = result.value else { throw CoincideError("Missing page") }
        let cursor = try #require(page.nextCursor)
        for change in [0, 1, 2] {
            var configuration = peer.target.configuration
            if change == 0 { configuration.model = "changed-model" }
            let target = RemoteWorkspaceTarget(environmentID: peer.target.environmentID,
                projectID: change == 1 ? UUID() : peer.target.projectID, threadID: peer.target.threadID,
                configuration: configuration, rootID: change == 2 ? UUID() : peer.target.rootID)
            await #expect(throws: RemoteHistoryFailure(.staleReview)) {
                _ = try await client.readHistory(.init(target: target, query: .prefix(binding: review.binding, newestFirst: false, cursor: nil)))
            }
        }
        await #expect(throws: RemoteHistoryFailure(.invalidRequest)) {
            _ = try await client.readHistory(.init(target: peer.target, query: .prefix(binding: review.binding, newestFirst: true, cursor: cursor)))
        }
        await #expect(throws: RemoteHistoryFailure(.invalidRequest)) {
            _ = try await client.readHistory(.init(target: peer.target, query: .paths(binding: review.binding, cursor: cursor)))
        }
        #expect(await client.isConnected())
        try await peer.finish(client)
    } catch { await peer.failed(client); throw error }
    let malformed = try HistoryMetadataPeer("controls-identities"), other = malformed.client()
    do {
        _ = try await other.connect()
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await other.readHistory(.init(target: malformed.target, query: .controls)) }
        try await malformed.finish(other)
    } catch { await malformed.failed(other); throw error }
}

@Test func remoteHistoryCancellingDisplayReadPreservesTheLiveConnectionAndCurrentControls() async throws {
    let peer = try HistoryMetadataPeer("cancel-read"), client = peer.client()
    var reading: Task<RemoteHistoryReadResult, any Error>?
    do {
        _ = try await client.connect(); let review = try await client.reviewHistory(peer.reviewRequest)
        let task = Task { try await client.readHistory(.init(target: peer.target, query: .prefix(binding: review.binding, newestFirst: true, cursor: nil))) }; reading = task
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: peer.root.appendingPathComponent("read-entered").path) {
            guard ContinuousClock.now < deadline else { throw CoincideError("History read did not reach the owned gate") }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await client.isConnected())
        try Data().write(to: peer.root.appendingPathComponent("read-release"))
        _ = try await client.snapshot()
        #expect(await client.isConnected())
        try await peer.finish(client)
    } catch {
        try? Data().write(to: peer.root.appendingPathComponent("read-release")); reading?.cancel(); _ = await reading?.result
        await peer.failed(client); throw error
    }
}
