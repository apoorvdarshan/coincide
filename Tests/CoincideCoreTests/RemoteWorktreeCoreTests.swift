import Foundation
import Testing
@testable import CoincideCore

private actor RemoteWorktreeEnginePeer: WorkspaceWorktreeSession {
    let request: GitWorktreeRequest
    private var evidence = false
    private(set) var prepares = 0
    private(set) var runs = 0
    private(set) var inspections = 0
    init(_ request: GitWorktreeRequest) { self.request = request }
    func plan() throws -> GitWorktreePlan {
        let identity = request.expectedSourceIdentity ?? GitWorktreeNodeIdentity(device: 1, inode: 42)
        let branch: String
        switch request.selection { case .createBranch(let name, _), .existingBranch(let name): branch = name
        case .reuse: branch = "main" }
        return try .init(request: request, sourcePath: request.sourcePath, commonDirectoryPath: request.sourcePath + "/.git",
            sourceIdentity: identity, commonDirectoryIdentity: identity, destinationParentIdentity: identity,
            branch: branch, baseCommit: String(repeating: "a", count: 40))
    }
    func prepare() throws -> GitWorktreePlan { prepares += 1; return try plan() }
    func run(_ plan: GitWorktreePlan) throws -> GitWorktreeResult {
        runs += 1; throw CoincideError("The controlled native worktree fixture stopped before publication.")
    }
    func inspectCompletion(_ plan: GitWorktreePlan) -> GitWorktreeResult? {
        inspections += 1
        return evidence ? .init(destinationPath: plan.destinationPath, headCommit: plan.baseCommit, branch: plan.branch) : nil
    }
    func publishEvidence() { evidence = true }
}
private final class RemoteWorktreeEnginePeers: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [UUID: RemoteWorktreeEnginePeer] = [:]
    private var providerStarts = 0
    func peer(_ request: GitWorktreeRequest) -> RemoteWorktreeEnginePeer {
        lock.withLock {
            if let peer = peers[request.id] { return peer }
            let peer = RemoteWorktreeEnginePeer(request); peers[request.id] = peer; return peer
        }
    }
    func provider(_ thread: CodingThread) throws -> any ProviderSession {
        lock.withLock { providerStarts += 1 }
        throw CoincideError("No provider execution is authorized by this worktree fixture.")
    }
    var starts: Int { lock.withLock { providerStarts } }
    var count: Int { lock.withLock { peers.count } }
}
private struct RemoteWorktreeEngineFixture {
    let root: URL, engine: WorkspaceEngine, peers: RemoteWorktreeEnginePeers
    let project: WorkspaceProject, initial: CodingThread, environmentID: UUID
    func thread() async throws -> CodingThread { try #require(await engine.current().snapshot.threads.first { $0.id == initial.id }) }
    func target() async throws -> RemoteWorkspaceTarget {
        .init(environmentID: environmentID, projectID: project.id, threadID: initial.id,
            configuration: .init(thread: try await thread()))
    }
    func request() async throws -> RemoteEnvironmentCommandRequest {
        .init(environmentID: environmentID, command: .prepareWorktree(target: try await target(), sourceRootID: UUID(), expectedAttemptID: nil,
            selection: .createBranch(name: "remote-owned", baseRef: "HEAD"), submodules: .recursive))
    }
    func dispatch(_ request: RemoteEnvironmentCommandRequest) async throws -> WorkspaceCommandReceipt {
        let identity: GitWorktreeNodeIdentity?
        if case .prepareWorktree = request.command { identity = try GitWorktreeDirectory(path: project.path).identity }
        else { identity = nil }
        let prepared = try await engine.prepareRemoteWorktree(request.command, expectedSourceIdentity: identity)
        return try await engine.dispatchRemoteEnvironment(request, preparation: prepared)
    }
    func failed() async throws -> ThreadWorkspacePreparation {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await thread().workspacePreparation?.phase != .failed {
            guard ContinuousClock.now < deadline else { throw CoincideError("The controlled worktree fixture did not stop.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(try await thread().workspacePreparation)
    }
}
private func withRemoteWorktreeEngine(_ body: (RemoteWorktreeEngineFixture) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-worktree-core-\(UUID())")
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let peers = RemoteWorktreeEnginePeers()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { try peers.provider($0) },
        identityResolver: { _ in nil }, worktreeFactory: { peers.peer($0) })
    let project = WorkspaceProject(path: source.path)
    var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
    do {
        try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        try await body(.init(root: root, engine: engine, peers: peers, project: project, initial: thread, environmentID: UUID()))
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteWorktreeOriginalCommandIdentityOwnsOneNativeAttemptAndNeverEnablesSetup() async throws {
    try await withRemoteWorktreeEngine { f in
        let request = try await f.request(), receipt = try await f.dispatch(request)
        #expect(receipt.rejection == nil)
        let state = try await f.failed()
        #expect(state.request.submodules == .recursive && state.setup == nil)
        #expect(state.request.destinationRoot == f.engine.worktreesRoot.path && state.request.sourcePath == f.project.path)
        #expect(state.request.expectedSourceIdentity == (try GitWorktreeDirectory(path: f.project.path)).identity)
        #expect(state.id != request.id && state.destinationPath != f.project.path)
        #expect(try await f.engine.dispatchRemoteEnvironment(request, preparation: .refused) == receipt)
        #expect(try await f.engine.remoteEnvironmentReceipt(request) == receipt)
        #expect(f.peers.count == 1 && f.peers.starts == 0)
        let changed = RemoteEnvironmentCommandRequest(environmentID: f.environmentID, id: request.id,
            command: .cancelWorktree(target: try await f.target(), attemptID: state.id))
        await #expect(throws: WorkspaceCommitError.commandIDCollision) { try await f.engine.remoteEnvironmentReceipt(changed) }
        let projected = try await WorkspaceDatabase(url: f.root.appendingPathComponent("workspace.sqlite")).rebuildProjection().snapshot
        #expect(projected == (await f.engine.current()).snapshot)
    }
}

@Test(.timeLimit(.minutes(1)))
func remoteWorktreePreparedRetryRechecksAttemptAndConfigurationInTheCommitQueue() async throws {
    try await withRemoteWorktreeEngine { f in
        _ = try await f.dispatch(try await f.request())
        let old = try await f.failed()
        let request = RemoteEnvironmentCommandRequest(environmentID: f.environmentID,
            command: .retryWorktree(target: try await f.target(), attemptID: old.id))
        let prepared = try await f.engine.prepareRemoteWorktree(request.command)
        try await f.engine.dispatch(.editThread(f.initial.id, .model("changed-after-inspection")))
        let stale = try await f.engine.dispatchRemoteEnvironment(request, preparation: prepared)
        #expect(stale.rejection != nil && f.peers.count == 1)
        #expect(try await f.thread().workspacePreparation?.id == old.id)
        let fresh = RemoteEnvironmentCommandRequest(environmentID: f.environmentID,
            command: .retryWorktree(target: try await f.target(), attemptID: old.id))
        #expect(try await f.dispatch(fresh).rejection == nil)
        let next = try await f.failed()
        #expect(next.id != old.id && next.destinationPath != old.destinationPath)
        #expect(next.request.expectedSourceIdentity == old.request.expectedSourceIdentity)
        #expect(next.previousAttempts.map(\.request.id) == [old.id] && f.peers.starts == 0)
        let cancelOld = RemoteEnvironmentCommandRequest(environmentID: f.environmentID,
            command: .cancelWorktree(target: try await f.target(), attemptID: old.id))
        #expect(try await f.engine.dispatchRemoteEnvironment(cancelOld, preparation: .none).rejection != nil)
    }
}

@Test(.timeLimit(.minutes(1)))
func remoteWorktreeInspectionUsesNativePublicationEvidenceAndNeverResumesQueuedInput() async throws {
    try await withRemoteWorktreeEngine { f in
        _ = try await f.dispatch(try await f.request())
        let state = try await f.failed()
        try await f.engine.dispatch(.submit(threadID: f.initial.id, text: "Held until explicit readiness and queue resume"))
        let noEvidence = RemoteEnvironmentCommandRequest(environmentID: f.environmentID,
            command: .inspectWorktree(target: try await f.target(), attemptID: state.id))
        #expect(try await f.dispatch(noEvidence).rejection == nil)
        #expect(try await f.thread().workspacePreparation?.phase == .failed)
        await f.peers.peer(state.request).publishEvidence()
        let inspect = RemoteEnvironmentCommandRequest(environmentID: f.environmentID,
            command: .inspectWorktree(target: try await f.target(), attemptID: state.id))
        #expect(try await f.dispatch(inspect).rejection == nil)
        let current = try await f.thread()
        #expect(current.workspacePreparation?.isReady == true && current.workspacePreparation?.id == state.id)
        #expect(current.queuePaused && current.queuedTurns.count == 1 && current.messages.isEmpty && current.activeRun == nil)
        #expect(f.peers.starts == 0 && f.peers.count == 1)
    }
}

@Test
func remoteWorktreeAtomicTargetGuardRejectsCanonicallyEquivalentDifferentPathBytes() throws {
    let project = WorkspaceProject(path: "/fixture/remote-worktree"), environmentID = UUID()
    var thread = CodingThread(project: project); thread.workspacePath = "/fixture/\u{00e9}"
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    var configuration = ProviderConfiguration(thread: thread); configuration.workspacePath = "/fixture/e\u{0301}"
    let target = RemoteWorkspaceTarget(environmentID: environmentID, projectID: project.id, threadID: thread.id, configuration: configuration)
    #expect(throws: WorkspaceCommandError.self) { try RemoteEnvironmentAdmission.worktreeTarget(target, environmentID: environmentID, snapshot: snapshot) }
}

@Test
func remoteWorktreeCapabilitiesDecodeOlderHelpersWithoutAdvertisingWorktreeCommands() throws {
    let current = try RemoteEnvironmentProtocol.encode(RemoteEnvironmentCapabilities())
    #expect(try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCapabilities.self, from: current).supportsRemoteWorktrees)
    var old = try #require(current.object); old.removeValue(forKey: "supportsRemoteWorktrees")
    let decoded = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCapabilities.self, from: .object(old))
    #expect(!decoded.supportsRemoteWorktrees)
}

@Test(.timeLimit(.minutes(1)))
func remoteWorktreeNativePlannerRejectsSourceReplacementAfterAdmissionBeforeReadingGit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-worktree-identity-\(UUID())").resolvingSymlinksInPath()
    let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("managed")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = try GitWorktreeDirectory(path: source.path).identity
    let request = GitWorktreeRequest(sourcePath: source.path, destinationRoot: destination.path,
        selection: .createBranch(name: "never-created", baseRef: "HEAD"), expectedSourceIdentity: identity)
    try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("original-source"))
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    do {
        _ = try await GitWorktreeService(request: request).prepare()
        Issue.record("A replaced source cannot enter native Git planning.")
    } catch let error as GitWorktreeError { #expect(error.failure == .ownershipLost) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    let encoded = try RemoteEnvironmentProtocol.encode(request)
    var legacy = try #require(encoded.object); legacy.removeValue(forKey: "expectedSourceIdentity")
    #expect(try RemoteEnvironmentProtocol.decode(GitWorktreeRequest.self, from: .object(legacy)).expectedSourceIdentity == nil)
}
