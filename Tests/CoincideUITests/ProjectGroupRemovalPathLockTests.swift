import CoincideCore
import CSQLite
import Foundation
import Testing
@testable import Coincide

private actor QueuedPathCloseProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var closeStarted = false
    private(set) var closeFinished = false
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) {
        if let runID = thread.activeRun?.id {
            sink.yield(.context(runID: runID, event: .thread("queued-path-fixture")))
            sink.yield(.context(runID: runID, event: .turn(UUID().uuidString)))
        }
    }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() async {
        guard !closeStarted else { return }; closeStarted = true; sink.finish()
        if !released { await withCheckedContinuation { waiter = $0 } }
        closeFinished = true
    }
    func release() { released = true; let saved = waiter; waiter = nil; saved?.resume() }
}

@MainActor private func waitQueuedPath(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The queued worktree/removal fixture did not settle.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func groupedRemovalKeepsANewQueuedWorktreePathLockedAfterItsThreadDisappears() async throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-group-path-lock-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let root = scratch.resolvingSymlinksInPath(); defer { try? FileManager.default.removeItem(at: root) }
    let hooks = root.appendingPathComponent("empty-hooks")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    var projects: [WorkspaceProject] = [], identities: [String: RepositoryIdentity] = [:]
    let remote = try #require(RepositoryIdentity.normalizedRemote("https://example.invalid/Team/Queued.git"))
    let bytes = Data("Preserve checkout and queued worktree bytes.\n".utf8)
    for name in ["A", "B", "Survivor"] {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try bytes.write(to: path.appendingPathComponent("keep.txt"))
        let project = WorkspaceProject(path: path.path); projects.append(project)
        if name != "Survivor" { identities[project.path] = try RepositoryIdentity(remote: remote, remoteName: "origin", rootPath: project.path, projectRelativePath: "") }
    }
    let a = projects[0], b = projects[1], survivor = projects[2]
    var environment = ProcessChannel.environment()
    for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"; environment["GIT_CONFIG_NOSYSTEM"] = "1"
    let repository = URL(fileURLWithPath: b.path)
    let setup = [
        ["init", "--initial-branch=main"], ["config", "core.hooksPath", hooks.path],
        ["config", "commit.gpgSign", "false"], ["config", "user.name", "Coincide Test"],
        ["config", "user.email", "test@example.invalid"], ["add", "--", "keep.txt"], ["commit", "--message", "Fixture"]
    ]
    for arguments in setup {
        let result = try await CommandRunner.run("git", ["-C", b.path] + arguments, cwd: repository, environment: environment)
        #expect(result.status == 0)
        guard result.status == 0 else { throw CoincideError("Could not create the isolated worktree fixture repository.") }
    }
    let threadA = CodingThread(project: a), threadB = CodingThread(project: b)
    let newPath = root.appendingPathComponent("Worktrees").appendingPathComponent(threadB.id.uuidString)
    try FileManager.default.createDirectory(at: newPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await GitService(root: repository).createWorktree(at: newPath, branch: "fixture/queued-removal")
    var survivingThread = CodingThread(project: survivor); survivingThread.workspacePath = newPath.path
    var initial = WorkspaceSnapshot(); initial.projects = projects; initial.threads = [threadA, threadB, survivingThread]
    let databaseURL = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: databaseURL)
    _ = try await database.commit(initial, event: "fixture.queued-path", commandID: UUID())
    let provider = QueuedPathCloseProvider(), resolverValues = identities
    let engine = try WorkspaceEngine(url: databaseURL, providerFactory: { _ in provider }, identityResolver: { resolverValues[$0.path] })
    let store = WorkspaceStore(engine: engine, managedProjectsRoot: root.appendingPathComponent("Projects"))
    await store.load()
    var assignment: Task<WorkspaceCommandReceipt, any Error>?, removal: Task<Void, any Error>?
    var writer: OpaquePointer?, writerLocked = false
    func releaseWriter() {
        if writerLocked { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); writerLocked = false }
    }
    defer { releaseWriter(); if let writer { sqlite3_close(writer) } }
    do {
        try await waitQueuedPath { store.projectGroup(containing: a.id)?.memberProjectIDs.count == 2 }
        try await engine.dispatch(.submit(threadID: threadA.id, text: "Hold removal cleanup"))
        try await waitQueuedPath { store.thread(threadA.id)?.activeRun?.nativeTurnID != nil }
        let group = try #require(store.projectGroup(containing: a.id)), request = try #require(store.projectGroupRemovalRequest(group.key))
        let sharedInspector = store.gitInspector(path: newPath.path)
        guard sqlite3_open_v2(databaseURL.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CoincideError("Could not open the private path-lock fixture writer.")
        }
        sqlite3_busy_timeout(writer, 1_000)
        guard sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw CoincideError("Could not hold the private path-lock fixture writer.")
        }
        writerLocked = true
        // This is the same typed, queued assignment used by createWorktree after Git succeeds.
        // Holding the independent writer prevents it from publishing before removal captures
        // the old workspace; commandTail guarantees the assignment precedes removal preflight.
        assignment = store.setWorkspacePath(newPath.path, threadID: threadB.id)
        #expect(store.thread(threadB.id)?.workspacePath == b.path)
        #expect(FileManager.default.fileExists(atPath: newPath.appendingPathComponent("keep.txt").path))
        removal = Task { try await store.removeProjectGroup(request) }
        try await waitQueuedPath { !store.canEditWorkspace(a.path) && !store.canEditWorkspace(b.path) }
        #expect(store.canEditWorkspace(newPath.path), "The new worktree was outside the originally captured removal path set.")
        releaseWriter()
        _ = try await assignment?.value
        try await waitQueuedPath { await provider.closeStarted && store.thread(threadB.id) == nil }
        #expect(store.snapshot.projects.map(\.id) == [survivor.id] && store.snapshot.threads == [survivingThread])
        #expect(store.gitInspector(path: newPath.path) === sharedInspector)
        for _ in 0..<4 {
            #expect(!store.canEditWorkspace(newPath.path), "The queued workspace path must stay locked after its removed thread stops providing the dynamic owner check.")
            #expect(!store.canEditWorkspace(a.path) && !store.canEditWorkspace(b.path))
            #expect(store.canEditWorkspace(survivor.path))
            await Task.yield()
        }
        #expect(await provider.closeFinished == false)
        let worktreeFile = newPath.appendingPathComponent("keep.txt")
        store.fileNavigation = nil; store.openFile(worktreeFile, line: 1, workspacePath: newPath.path)
        #expect(store.fileNavigation == nil)
        let records = try await database.journal()
        let edit = try #require(records.first { if case .threadMetadataUpserted(let thread) = $0.event { thread.id == threadB.id && thread.workspacePath == newPath.path } else { false } })
        let removed = try #require(records.first { if case .threadRemoved(let id) = $0.event { id == threadB.id } else { false } })
        #expect(edit.sequence < removed.sequence)
        await provider.release(); try await removal?.value
        #expect(await provider.closeFinished && store.canEditWorkspace(newPath.path))
        #expect(store.gitInspector(path: newPath.path) === sharedInspector)
        store.openFile(worktreeFile, line: 2, workspacePath: newPath.path)
        #expect(store.fileNavigation?.workspacePath == newPath.path && store.fileNavigation?.path == "keep.txt")
        for path in projects.map(\.path) + [newPath.path] {
            #expect(try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("keep.txt")) == bytes)
        }
        #expect(store.errorMessage == nil)
        await store.shutdown()
    } catch {
        releaseWriter(); await provider.release()
        _ = await assignment?.result; _ = await removal?.result
        await store.shutdown(); throw error
    }
}
