import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct RemotePRClientState: Codable {
    let descriptor: RemoteEnvironmentDescriptor
    let snapshot: RemoteEnvironmentSnapshot
    let target: RemoteWorkspaceTarget
    let context: GitHubPullRequestContext
    let detail: GitHubPullRequestDetail
    let creation: RemotePullRequestReview
    let checkout: RemotePullRequestReview
    let alternateReview: RemotePullRequestReview?
    let mode: String
}
/// Synthetic metadata only. The remote path deliberately cannot be looked up
/// locally; valid responses must preserve its exact spelling and UTF-8 bytes.
private struct RemotePRClientPeer: Sendable {
    let root: URL, script: URL, target: RemoteWorkspaceTarget
    let creation: RemotePullRequestReview, checkout: RemotePullRequestReview
    let reference: GitHubPullRequestReference
    let createIntent = RemotePullRequestIntent.create(title: "Title é", body: "Body é\n", baseBranch: "main", isDraft: false)
    init(mode: String) throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("coincide-pr-client-\(UUID())").resolvingSymlinksInPath()
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        script = root.appendingPathComponent("metadata-peer.py")
        let environment = UUID(), project = WorkspaceProject(path: "/var/remote-only/é")
        var thread = CodingThread(project: project); thread.reasoningEffort = "medium"
        target = .init(environmentID: environment, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread), rootID: UUID())
        let repository = try GitHubRepository(owner: "fixture", name: "remote-pr"), commit = String(repeating: "a", count: 40)
        reference = try .init(repository: repository, number: 42)
        let summary = try GitHubPullRequestSummary(reference: reference, title: "Private metadata", url: "https://github.com/fixture/remote-pr/pull/42",
            state: .open, isDraft: false, headBranch: "feature", baseBranch: "main", headCommit: commit,
            baseCommit: String(repeating: "b", count: 40), headRepository: repository)
        let detail = try GitHubPullRequestDetail(summary: summary, body: "Private description", createdAt: Date(timeIntervalSince1970: 1),
            additions: 1, deletions: 0, changedFiles: 1)
        let context = try GitHubPullRequestContext(workspacePath: project.path, repository: repository, headRepository: repository,
            branch: "feature", headCommit: commit, upstream: .init(remoteName: "origin", branch: "feature", commit: commit),
            defaultBranch: "main", baseBranches: ["main", "develop"], readiness: .ready, sourceFingerprint: String(repeating: "a", count: 64))
        let nativeCreation = try GitHubPullRequestCreateReview(context: context, title: "Title é", body: "Body é\n", baseBranch: "main", baseCommit: String(repeating: "b", count: 40))
        creation = try .init(target: target, value: .creation(nativeCreation))
        let request = GitHubPullRequestCheckoutRequest(sourcePath: project.path, destinationRoot: "/var/remote-worktrees", reference: reference, mode: .local)
        let identity = GitWorktreeNodeIdentity(device: 1, inode: 2)
        let proof = GitHubPullRequestCheckoutProof(sourceIdentity: identity, repositoryIdentity: identity,
            gitDirectoryPath: project.path + "/.git", gitDirectoryIdentity: identity, commonDirectoryIdentity: identity,
            sourceFingerprint: String(repeating: "a", count: 64), statusDigest: String(repeating: "b", count: 64),
            configurationDigest: String(repeating: "c", count: 64), headCommit: commit, branch: "feature")
        let remote = try GitHubPullRequestCheckoutRemote(name: "origin", url: "https://github.com/fixture/remote-pr.git", repository: repository, needsCreation: false)
        let plan = try GitHubPullRequestCheckoutPlan(request: request, sourcePath: project.path, repositoryPath: project.path,
            commonDirectoryPath: project.path + "/.git", destinationPath: project.path, pullRequest: summary,
            requestedBranch: "feature", requestedHeadCommit: commit, disposition: .local, proof: proof, baseRemote: remote, headRemote: remote,
            destinationParentIdentity: identity)
        let nativeCheckout = try PullRequestCheckoutReview(projectID: project.id, projectPath: project.path, registeredWorkspacePath: project.path,
            sourceIncarnation: UUID(), targetConfiguration: target.configuration, title: "Reviewed checkout", reviewSetup: false, plan: plan)
        checkout = try .init(target: target, value: .checkout(nativeCheckout))
        let alternate: RemotePullRequestReview?
        if ["review-title-bytes", "review-body-bytes", "review-base", "review-draft"].contains(mode) {
            let changed = try GitHubPullRequestCreateReview(id: nativeCreation.id, reviewedAt: nativeCreation.reviewedAt, context: context,
                title: mode == "review-title-bytes" ? "Title e\u{301}" : nativeCreation.title,
                body: mode == "review-body-bytes" ? "Body e\u{301}\n" : nativeCreation.body,
                baseBranch: mode == "review-base" ? "develop" : "main", baseCommit: nativeCreation.baseCommit, isDraft: mode == "review-draft")
            alternate = try .init(target: target, value: .creation(changed))
        } else if ["checkout-reasoning", "checkout-model", "checkout-setup"].contains(mode) {
            var configuration = target.configuration
            if mode == "checkout-reasoning" { configuration.reasoningEffort = "high" }
            if mode == "checkout-model" { configuration.model = "changed-model" }
            let changed = try PullRequestCheckoutReview(id: nativeCheckout.id, reviewedAt: nativeCheckout.reviewedAt, projectID: project.id,
                projectPath: project.path, registeredWorkspacePath: project.path, sourceIncarnation: nativeCheckout.sourceIncarnation,
                targetThreadID: nativeCheckout.targetThreadID, targetConfiguration: configuration, title: nativeCheckout.title,
                reviewSetup: mode == "checkout-setup", plan: plan)
            alternate = try .init(target: target, value: .checkout(changed))
        } else { alternate = nil }
        var workspace = WorkspaceSnapshot(); workspace.projects = [project]; workspace.threads = [thread]
        let state = RemotePRClientState(descriptor: .init(environmentID: environment, label: "Private PR metadata peer"),
            snapshot: .init(environmentID: environment, sequence: 10, workspace: workspace), target: target,
            context: context, detail: detail, creation: creation, checkout: checkout, alternateReview: alternate, mode: mode)
        let statePath = root.appendingPathComponent("state.json")
        try JSONEncoder().encode(state).write(to: statePath)
        try Self.source.write(to: script, atomically: false, encoding: .utf8)
        for path in [statePath, script] { try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
    }
    func client() -> RemoteEnvironmentClient {
        RemoteEnvironmentClient(factory: {
            try JSONRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, root.path], cwd: root,
                dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], drainProcessOnClose: true)
        }, expectedEnvironmentID: target.environmentID)
    }
    func count(_ method: String) throws -> Int {
        try Data(contentsOf: root.appendingPathComponent("methods.jsonl")).split(separator: 10)
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }.filter { $0["method"].string == method }.count
    }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        await client.close()
        let pids = try String(contentsOf: root.appendingPathComponent("peer-pids.txt"), encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        for pid in pids { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
        try FileManager.default.removeItem(at: root)
    }
    func retained() { print("Private PR metadata fixture retained at \(root.path)") }
    private static let source = #"""
import copy,json,os,sys,unicodedata
from pathlib import Path
root=Path(sys.argv[1]);os.umask(0o077)
assert root.name.startswith('coincide-pr-client-') and os.stat(root).st_mode & 0o077 == 0
with (root/'peer-pids.txt').open('a') as out:out.write(str(os.getpid())+'\n')
state=json.loads((root/'state.json').read_text());mode=state['mode'];different='00000000-0000-0000-0000-000000000001';receipt_busy_returned=False
if mode=='old-helper':state['descriptor']['capabilities'].pop('supportsRemotePullRequests',None)
for line in sys.stdin:
    frame=json.loads(line);method=frame['method']
    # Record no authored title/body, native metadata, input or full wire frames.
    with (root/'methods.jsonl').open('a') as out:out.write(json.dumps({'method':method})+'\n')
    if method=='remoteEnvironment.describe':result=state['descriptor']
    elif method in ('remoteEnvironment.subscribe','remoteEnvironment.snapshot'):result=state['snapshot']
    elif method=='remoteEnvironment.close':
        result={'environmentID':state['descriptor']['environmentID']}
        print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True);break
    elif method=='remoteEnvironment.receipt':
        if mode=='busy-receipt' and not receipt_busy_returned:
            receipt_busy_returned=True
            print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'error':{'code':-32001,'message':'PRIVATE_UNTRUSTED_CAPACITY_MESSAGE','data':{'kind':'busy'}}}),flush=True);continue
        result={'environmentID':state['descriptor']['environmentID'],'receipt':None}
    elif method=='remoteEnvironment.command':
        if mode=='busy-begin':
            print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'error':{'code':-32001,'message':'PRIVATE_UNTRUSTED_CAPACITY_MESSAGE','data':{'kind':'busy'}}}),flush=True);continue
        assert mode in ('drop-begin','bad-begin')
        if mode=='drop-begin':break
        result={'environmentID':state['descriptor']['environmentID'],'receipt':{'commandID':different,'sequence':11,'eventCount':1,'acceptedAt':1}}
    elif method=='remoteEnvironment.pullRequest.bind':result=copy.deepcopy(state['target'])
    elif method=='remoteEnvironment.pullRequest.read':
        if mode=='typed-error':
            print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'error':{'code':-32004,'message':'PRIVATE_UNTRUSTED_PR_MESSAGE','data':{'kind':'unauthenticated','privateDetail':'PRIVATE_UNTRUSTED_PR_MESSAGE'}}}),flush=True);continue
        query=frame['params']['query'];kind=next(iter(query));target=copy.deepcopy(state['target'])
        if kind=='context':value={'context':{'_0':copy.deepcopy(state['context'])}}
        elif kind=='list':value={'page':{'_0':{'items':[copy.deepcopy(state['detail']['summary'])],'truncated':False}}}
        else:value={'detail':{'_0':copy.deepcopy(state['detail'])}}
        result={'target':target,'value':value}
        if mode=='read-environment':target['environmentID']=different
        elif mode=='read-thread':target['threadID']=different
        elif mode=='read-root':target['rootID']=different
        elif mode=='read-path-bytes':
            original=target['configuration']['workspacePath'];changed=unicodedata.normalize('NFD',original)
            if changed.encode()==original.encode():changed=unicodedata.normalize('NFC',original)
            assert changed.encode()!=original.encode() and unicodedata.normalize('NFC',changed)==unicodedata.normalize('NFC',original)
            target['configuration']['workspacePath']=changed
        elif mode=='read-type':result['value']={'page':{'_0':{'items':[],'truncated':False}}}
        elif mode=='context-path':value['context']['_0']['workspacePath']='/remote/another-path'
        elif mode=='list-duplicate' and kind=='list':value['page']['_0']['items']*=2
        elif mode=='detail-reference' and kind=='detail':value['detail']['_0']['summary']['reference']['number']=43;value['detail']['_0']['summary']['url']='https://github.com/fixture/remote-pr/pull/43'
        elif mode=='detail-url' and kind=='detail':value['detail']['_0']['summary']['url']='https://github.com/another/repo/pull/42'
    elif method=='remoteEnvironment.pullRequest.review':
        checkout='checkout' in frame['params']['intent']
        result=copy.deepcopy(state.get('alternateReview') or state['checkout' if checkout else 'creation'])
        if mode=='review-target':result['target']['rootID']=different
        elif mode=='review-id':result['id']=different
        elif mode=='review-digest':result['digest']='0'*64
    elif method=='remoteEnvironment.pullRequest.discard':
        result={'request':copy.deepcopy(frame['params']),'discarded':True}
        if mode=='discard-binding':result['request']['reviewID']=different
    else:raise AssertionError('Unexpected private PR metadata method')
    print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True)
"""#
}

@Test(.timeLimit(.minutes(1)), arguments: ["read-environment", "read-thread", "read-root", "read-path-bytes", "read-type", "context-path", "list-duplicate", "detail-reference", "detail-url"])
func remotePRClientDetachesWrongReadScopeTypeRepositoryAndExactRemotePathBytes(mode: String) async throws {
    let peer = try RemotePRClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect(); let before = await client.currentSnapshot()
        let query: RemotePullRequestQuery = mode == "list-duplicate" ? .list(.init(limit: 1)) : mode.hasPrefix("detail-") ? .detail(peer.reference) : .context
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.readPullRequests(.init(target: peer.target, query: query)) }
        #expect(await !client.isConnected()); #expect(await client.currentSnapshot() == before)
        #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 0)
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["review-target", "review-id", "review-digest", "review-title-bytes", "review-body-bytes", "review-base", "review-draft"])
func remotePRClientRejectsChangedHostReviewIdentityDigestAndExactAuthoredCreationBytes(mode: String) async throws {
    let peer = try RemotePRClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.reviewPullRequest(.init(target: peer.target, intent: peer.createIntent)) }
        #expect(await !client.isConnected()); #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 0)
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["checkout-reasoning", "checkout-model", "checkout-setup"])
func remotePRClientRejectsValidlyRedigestedCheckoutWithChangedCapturedSettingsOrSetup(mode: String) async throws {
    let peer = try RemotePRClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) {
            _ = try await client.reviewPullRequest(.init(target: peer.target,
                intent: .checkout(reference: peer.reference, mode: .local, submodules: .none, title: "Reviewed checkout")))
        }
        #expect(await !client.isConnected()); #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 0)
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["valid", "discard-binding"])
func remotePRClientKeepsRemoteOnlyPathsVerbatimAndPinsDiscardToTheReviewedIdentity(mode: String) async throws {
    let peer = try RemotePRClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        let bound = try await client.bindPullRequestWorkspace(peer.target)
        #expect(try RemotePullRequestProtocol.payload(bound) == RemotePullRequestProtocol.payload(peer.target))
        let context = try await client.readPullRequests(.init(target: peer.target, query: .context))
        #expect(context.target.configuration.workspacePath.utf8.elementsEqual(peer.target.workspacePath.utf8))
        let review = try await client.reviewPullRequest(.init(target: peer.target, intent: peer.createIntent))
        let discard = RemotePullRequestDiscardRequest(target: peer.target, reviewID: review.id, digest: review.digest)
        if mode == "valid" { #expect(try await client.discardPullRequestReview(discard).discarded) }
        else {
            await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.discardPullRequestReview(discard) }
            #expect(await !client.isConnected())
        }
        #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 0)
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["old-helper", "typed-error"])
func remotePRClientCapabilityRefusalSendsNoPRRPCAndTypedAuthFailureOmitsRawDiagnostics(mode: String) async throws {
    let peer = try RemotePRClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        if mode == "old-helper" {
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.bindPullRequestWorkspace(peer.target) }
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.readPullRequests(.init(target: peer.target, query: .context)) }
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.reviewPullRequest(.init(target: peer.target, intent: peer.createIntent)) }
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.discardPullRequestReview(.init(target: peer.target, reviewID: peer.creation.id, digest: peer.creation.digest)) }
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.command(.pullRequest(target: peer.target, action: .begin(reviewID: peer.creation.id, digest: peer.creation.digest))) }
            for method in [RemotePullRequestProtocol.bindMethod, RemotePullRequestProtocol.readMethod, RemotePullRequestProtocol.reviewMethod, RemotePullRequestProtocol.discardMethod, RemoteEnvironmentProtocol.commandMethod] { #expect(try peer.count(method) == 0) }
        } else {
            await #expect(throws: RemotePullRequestFailure(.unauthenticated)) { _ = try await client.readPullRequests(.init(target: peer.target, query: .context)) }
            #expect(!RemotePullRequestFailure(.unauthenticated).localizedDescription.contains("PRIVATE_UNTRUSTED_PR_MESSAGE"))
        }
        #expect(await client.isConnected())
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["drop-begin", "bad-begin"])
func remotePRClientUnknownBeginKeepsOriginalPendingUUIDAndNilReceiptNeverPermitsReplay(mode: String) async throws {
    let peer = try RemotePRClientPeer(mode: mode), client = peer.client(), id = UUID(), connection = UUID()
    let command = RemoteEnvironmentCommand.pullRequest(target: peer.target, action: .begin(reviewID: peer.creation.id, digest: peer.creation.digest))
    let pending = RemoteEnvironmentPendingStore(root: peer.root.appendingPathComponent("Pending"))
    let intent = RemoteEnvironmentPendingCommand(connectionID: connection, environmentID: peer.target.environmentID, id: id, command: command)
    do {
        try await pending.save(intent); _ = try await client.connect()
        await #expect(throws: RemoteEnvironmentClientError(.commandUncertain, commandID: id)) { _ = try await client.command(command, id: id) }
        #expect(await !client.isConnected()); #expect(try await pending.load(connectionID: connection) == intent)
        _ = try await client.reconnect()
        #expect(try await client.receipt(for: command, id: id).receipt == nil)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: id)) { _ = try await client.command(command, id: id) }
        #expect(try await pending.load(connectionID: connection) == intent)
        #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 1 && peer.count(RemoteEnvironmentProtocol.receiptMethod) == 1)
        #expect(try peer.count(RemotePullRequestProtocol.reviewMethod) == 0)
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remotePRClientBoundedBeginRefusalKeepsOwnedHelperConnectedAndOriginalPendingUUIDUnreplayed() async throws {
    let peer = try RemotePRClientPeer(mode: "busy-begin"), client = peer.client(), id = UUID(), connection = UUID()
    let command = RemoteEnvironmentCommand.pullRequest(target: peer.target, action: .begin(reviewID: peer.creation.id, digest: peer.creation.digest))
    let pending = RemoteEnvironmentPendingStore(root: peer.root.appendingPathComponent("Pending"))
    let intent = RemoteEnvironmentPendingCommand(connectionID: connection, environmentID: peer.target.environmentID, id: id, command: command)
    do {
        try await pending.save(intent); _ = try await client.connect()
        let before = try await client.snapshot()
        await #expect(throws: RemoteEnvironmentClientError(.commandUncertain, commandID: id)) { _ = try await client.command(command, id: id) }
        #expect(await client.isConnected())
        #expect(try await client.snapshot() == before)
        #expect(try await client.receipt(for: command, id: id).receipt == nil)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: id)) { _ = try await client.command(command, id: id) }
        let saved = try #require(await pending.load(connectionID: connection))
        #expect(try RemoteEnvironmentProtocol.payload(saved.request) == RemoteEnvironmentProtocol.payload(intent.request))
        #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 1 && peer.count(RemoteEnvironmentProtocol.receiptMethod) == 1)
        #expect(try peer.count(RemoteEnvironmentProtocol.describeMethod) == 1)
        #expect(try String(contentsOf: peer.root.appendingPathComponent("peer-pids.txt"), encoding: .utf8).split(whereSeparator: \.isNewline).count == 1)
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remotePRClientBoundedReceiptRefusalKeepsOwnedHelperConnectedAndNeverAuthorizesOriginalBegin() async throws {
    let peer = try RemotePRClientPeer(mode: "busy-receipt"), client = peer.client(), id = UUID(), connection = UUID()
    let command = RemoteEnvironmentCommand.pullRequest(target: peer.target, action: .begin(reviewID: peer.creation.id, digest: peer.creation.digest))
    let pending = RemoteEnvironmentPendingStore(root: peer.root.appendingPathComponent("Pending"))
    let intent = RemoteEnvironmentPendingCommand(connectionID: connection, environmentID: peer.target.environmentID, id: id, command: command)
    do {
        try await pending.save(intent); _ = try await client.connect()
        let before = try await client.snapshot()
        await #expect(throws: RemoteWorkspaceFailure(.busy)) { _ = try await client.receipt(for: command, id: id) }
        #expect(await client.isConnected())
        #expect(try await client.snapshot() == before)
        #expect(try await client.receipt(for: command, id: id).receipt == nil)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: id)) { _ = try await client.command(command, id: id) }
        let saved = try #require(await pending.load(connectionID: connection))
        #expect(try RemoteEnvironmentProtocol.payload(saved.request) == RemoteEnvironmentProtocol.payload(intent.request))
        #expect(try peer.count(RemoteEnvironmentProtocol.commandMethod) == 0 && peer.count(RemoteEnvironmentProtocol.receiptMethod) == 2)
        #expect(try peer.count(RemoteEnvironmentProtocol.describeMethod) == 1)
        #expect(try String(contentsOf: peer.root.appendingPathComponent("peer-pids.txt"), encoding: .utf8).split(whereSeparator: \.isNewline).count == 1)
        try await peer.finish(client)
    } catch { await client.close(); peer.retained(); throw error }
}
