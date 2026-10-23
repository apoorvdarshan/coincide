import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct RemoteWorktreeClientPeerState: Codable {
    let descriptor: RemoteEnvironmentDescriptor
    let snapshot: RemoteEnvironmentSnapshot
    let catalog: RemoteWorktreeCatalog
    let mode: String
}
private struct RemoteWorktreeClientPeer: Sendable {
    let root: URL, script: URL, catalog: RemoteWorktreeCatalog
    init(mode: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-worktree-client-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        script = root.appendingPathComponent("metadata-only-peer.py")
        let environment = UUID(), project = WorkspaceProject(path: "/offline-only/\u{00e9}"), thread = CodingThread(project: project)
        let target = RemoteWorkspaceTarget(environmentID: environment, projectID: project.id, threadID: thread.id,
            configuration: .init(thread: thread), rootID: UUID())
        catalog = .init(target: target, sourcePath: target.workspacePath, sourceRootID: UUID(), attemptID: nil,
            branches: [.init(ref: "refs/heads/main", upstream: nil)],
            worktrees: [.init(path: target.workspacePath, headCommit: String(repeating: "a", count: 40), branch: "main", isBare: false, isDetached: false)])
        let state = RemoteWorktreeClientPeerState(descriptor: .init(environmentID: environment, label: "Private worktree client peer"),
            snapshot: .init(environmentID: environment, sequence: 1, workspace: .init()), catalog: catalog, mode: mode)
        let stateURL = root.appendingPathComponent("state.json")
        try JSONEncoder().encode(state).write(to: stateURL)
        try Self.source.write(to: script, atomically: false, encoding: .utf8)
        for file in [script, stateURL] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    }
    func client() -> RemoteEnvironmentClient {
        RemoteEnvironmentClient(factory: {
            try JSONRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, root.path], cwd: root,
                dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], drainProcessOnClose: true)
        }, expectedEnvironmentID: catalog.target.environmentID)
    }
    func methods() throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("methods.txt"), encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
    }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        await client.close()
        let pid = try #require(Int32(String(contentsOf: root.appendingPathComponent("pid.txt"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        try FileManager.default.removeItem(at: root)
    }
    private static let source = #"""
import copy,json,os,sys,unicodedata
from pathlib import Path
root=Path(sys.argv[1])
assert root.name.startswith('coincide-worktree-client-') and os.stat(root).st_mode & 0o077 == 0
(root/'pid.txt').write_text(str(os.getpid()))
state=json.loads((root/'state.json').read_text()); mode=state['mode']
if mode=='old-helper':state['descriptor']['capabilities'].pop('supportsRemoteWorktrees',None)
different='00000000-0000-0000-0000-000000000001'
for line in sys.stdin:
    frame=json.loads(line); method=frame['method']
    # Only bounded method names are retained, never command contents or frames.
    with (root/'methods.txt').open('a') as out:out.write(method+'\n')
    if method=='remoteEnvironment.describe':result=state['descriptor']
    elif method in ('remoteEnvironment.subscribe','remoteEnvironment.snapshot'):result=state['snapshot']
    elif method=='remoteEnvironment.worktree.catalog':
        result=copy.deepcopy(state['catalog'])
        if mode=='environment':result['target']['environmentID']=different
        elif mode=='project':result['target']['projectID']=different
        elif mode=='thread':result['target']['threadID']=different
        elif mode=='configuration':result['target']['configuration']['model']='changed-without-review'
        elif mode=='path-bytes':
            original=result['target']['configuration']['workspacePath']
            changed=unicodedata.normalize('NFD',original)
            if changed.encode()==original.encode():changed=unicodedata.normalize('NFC',original)
            assert changed.encode()!=original.encode() and unicodedata.normalize('NFC',changed)==unicodedata.normalize('NFC',original)
            result['target']['configuration']['workspacePath']=changed
        elif mode=='root':result['target']['rootID']=different
        elif mode=='source-path':result['sourcePath']='relative/source'
        elif mode=='source-nul':result['sourcePath']='/invalid\u0000/source'
        elif mode=='remote-branch':result['branches'][0]['ref']='refs/remotes/origin/main'
        elif mode=='branch-control':result['branches'][0]['ref']='refs/heads/bad\nbranch'
        elif mode=='worktree-path':result['worktrees'][0]['path']='/remote/../replacement'
        elif mode=='worktree-commit':result['worktrees'][0]['headCommit']='not-a-commit'
        elif mode=='duplicate-branch':result['branches'].append(copy.deepcopy(result['branches'][0]))
        elif mode=='duplicate-worktree':result['worktrees'].append(copy.deepcopy(result['worktrees'][0]))
        elif mode=='decode':result={}
        elif mode!='valid':raise AssertionError('Unsupported private test mode')
    else:raise AssertionError('No worktree mutation is authorized by this client fixture')
    print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True)
"""#
}

@Test(.timeLimit(.minutes(1)), arguments: ["valid", "environment", "project", "thread", "configuration", "path-bytes", "root",
    "source-path", "source-nul", "remote-branch", "branch-control", "worktree-path", "worktree-commit", "duplicate-branch", "duplicate-worktree", "decode", "old-helper"])
func remoteWorktreeClientPinsCatalogIdentityPathsRefsAndCapabilityBeforeAnyCommand(mode: String) async throws {
    let peer = try RemoteWorktreeClientPeer(mode: mode), client = peer.client()
    do {
        _ = try await client.connect()
        if mode == "old-helper" {
            await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.worktreeCatalog(target: peer.catalog.target) }
            let commands: [RemoteEnvironmentCommand] = [
                .prepareWorktree(target: peer.catalog.target, sourceRootID: peer.catalog.sourceRootID, expectedAttemptID: nil,
                    selection: .createBranch(name: "never-sent", baseRef: "HEAD"), submodules: .none),
                .retryWorktree(target: peer.catalog.target, attemptID: UUID()), .cancelWorktree(target: peer.catalog.target, attemptID: UUID()),
                .inspectWorktree(target: peer.catalog.target, attemptID: UUID())]
            for command in commands { await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await client.command(command) } }
            #expect(try !peer.methods().contains(RemoteEnvironmentProtocol.worktreeCatalogMethod))
            #expect(await client.isConnected())
        } else if mode == "valid" {
            #expect(try await client.worktreeCatalog(target: peer.catalog.target) == peer.catalog)
            #expect(await client.isConnected())
        } else if mode == "path-bytes" {
            await #expect(throws: RemoteEnvironmentClientError(.invalidResponse)) { _ = try await client.worktreeCatalog(target: peer.catalog.target) }
            #expect(await !client.isConnected())
        } else {
            await #expect(throws: (any Error).self) { _ = try await client.worktreeCatalog(target: peer.catalog.target) }
            #expect(await !client.isConnected())
        }
        #expect(try !peer.methods().contains(RemoteEnvironmentProtocol.commandMethod))
        try await peer.finish(client)
    } catch {
        await client.close(); print("Private worktree client fixture retained at \(peer.root.path)"); throw error
    }
}
