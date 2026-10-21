import CoincideCore
import CoincideTerminal
import Foundation
import Testing
@testable import Coincide

private actor NativeWorktreePeer: WorkspaceWorktreeSession {
    let service: GitWorktreeService
    private var waiter: CheckedContinuation<Void, any Error>?
    private var released = false
    private var cancelled = false
    private(set) var starts = 0
    init(_ request: GitWorktreeRequest) { service = .init(request: request) }
    func prepare() async throws -> GitWorktreePlan { try await service.prepare() }
    func run(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult {
        starts += 1
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else if released { continuation.resume() }
                else { waiter = continuation }
            }
        } onCancel: { Task { await self.cancel() } }
        return try await service.run(plan)
    }
    func inspectCompletion(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult? { try await service.inspectCompletion(plan) }
    func release() { released = true; let value = waiter; waiter = nil; value?.resume() }
    private func cancel() { cancelled = true; let value = waiter; waiter = nil; value?.resume(throwing: CancellationError()) }
}

private struct NativeWorktreeProviderCall: Sendable, Equatable {
    let text: String
    let path: String
    let model: String
    let permission: PermissionMode
}

private actor NativeWorktreeProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var calls: [NativeWorktreeProviderCall] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) {
        runID = thread.activeRun?.id
        calls.append(.init(text: text, path: thread.workspacePath, model: thread.model, permission: thread.permission))
        emit(.thread("native-worktree-\(thread.id)")); emit(.turn(UUID().uuidString))
    }
    func finish() { emit(.completed(.idle)) }
    func interrupt() { emit(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { sink.finish() }
    private func emit(_ event: ProviderEvent) {
        if let runID { sink.yield(.context(runID: runID, event: event)) } else { sink.yield(event) }
    }
}

private final class NativeWorktreeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [UUID: NativeWorktreePeer] = [:]
    let provider = NativeWorktreeProvider()
    func peer(_ request: GitWorktreeRequest) -> NativeWorktreePeer {
        lock.lock(); defer { lock.unlock() }
        if let value = peers[request.id] { return value }
        let value = NativeWorktreePeer(request); peers[request.id] = value; return value
    }
}

private func worktreeUIGit(_ arguments: [String], root: URL) async throws {
    let executable = try #require(ProcessChannel.findExecutable("git"))
    var environment = ProcessChannel.environment()
    for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG_COUNT"] { environment.removeValue(forKey: key) }
    environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    let result = try await CommandRunner.run(executable.path, arguments, cwd: root, environment: environment)
    #expect(result.status == 0)
    guard result.status == 0 else { throw CoincideError("The isolated native worktree Git fixture failed.") }
}

@MainActor private struct WorktreeUIFixture {
    let root: URL
    let source: URL
    let database: URL
    let project: WorkspaceProject
    let thread: CodingThread
    let harness: NativeWorktreeHarness
    let engine: WorkspaceEngine
    let store: WorkspaceStore
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-worktree-ui-" + UUID().uuidString).resolvingSymlinksInPath()
        let source = root.appendingPathComponent("Source checkout")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try await worktreeUIGit(["-c", "init.templateDir=", "init", "--initial-branch=main", "--", source.path], root: root)
        for (key, value) in [("user.name", "Coincide Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            try await worktreeUIGit(["config", "--local", key, value], root: source)
        }
        try Data("Committed base\n".utf8).write(to: source.appendingPathComponent("notes.txt"))
        try await worktreeUIGit(["add", "--", "notes.txt"], root: source)
        try await worktreeUIGit(["commit", "-m", "Fixture base"], root: source)
        try Data("Dirty source kept\n".utf8).write(to: source.appendingPathComponent("notes.txt"))
        try Data("Untracked sentinel\n".utf8).write(to: source.appendingPathComponent("untracked.txt"))
        let project = WorkspaceProject(path: source.path), agent = ACPAgentConfiguration(name: "Native Worktree Fixture", executable: "/usr/bin/true")
        var thread = CodingThread(project: project); thread.provider = .acp; thread.acpAgent = agent; thread.draft = "Keep this unsent draft"
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]; snapshot.acpAgents = [agent]
        let database = root.appendingPathComponent("workspace.sqlite"), persistence = try WorkspaceDatabase(url: database)
        _ = try await persistence.commit(snapshot, event: "fixture", commandID: UUID())
        let harness = NativeWorktreeHarness()
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in harness.provider }, identityResolver: { _ in nil }, worktreeFactory: { harness.peer($0) })
        let store = WorkspaceStore(engine: engine); await store.load()
        return .init(root: root, source: source, database: database, project: project, thread: thread, harness: harness, engine: engine, store: store)
    }
    func cleanup() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
    func checkSource() throws {
        #expect(try String(contentsOf: source.appendingPathComponent("notes.txt"), encoding: .utf8) == "Dirty source kept\n")
        #expect(try String(contentsOf: source.appendingPathComponent("untracked.txt"), encoding: .utf8) == "Untracked sentinel\n")
    }
}

@MainActor private func waitWorktreeUI(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native worktree fixture did not settle.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeWorktreeSetupOptionsAndDurableComposerQueueUseThePreparedCheckoutAndRetainCapturedSettings() async throws {
    let fixture = try await WorktreeUIFixture.make(), store = fixture.store, id = fixture.thread.id
    do {
        #expect(store.worktreesRoot == fixture.root.appendingPathComponent("Worktrees", isDirectory: true))
        let options = try await store.worktreeSetupOptions(for: id)
        #expect(options.branches == ["main"] && options.worktrees.map(\.path) == [fixture.source.path])
        await store.prepareWorktree(for: id, selection: .createBranch(name: "native-feature", baseRef: "HEAD"))
        let request = try #require(store.thread(id)?.workspacePreparation?.request), peer = fixture.harness.peer(request)
        try await waitWorktreeUI { await peer.starts == 1 }
        #expect(!store.isPreparingWorkspace(id) && store.thread(id)?.draft == "Keep this unsent draft")
        #expect(store.thread(id)?.workspacePath == request.destinationPath && !store.canAccessWorkspaceFiles(request.destinationPath))
        store.setModel("first-model", id: id)
        try await waitWorktreeUI { store.thread(id)?.model == "first-model" }
        #expect(await store.submit("First waiting prompt", threadID: id).value)
        store.setModel("second-model", id: id); store.setPermission(.fullAccess, id: id)
        try await waitWorktreeUI { store.thread(id)?.model == "second-model" && store.thread(id)?.permission == .fullAccess }
        #expect(await store.submit("Second waiting prompt", threadID: id).value)
        store.setDraft("Unsent while preparing", id: id)
        #expect(store.thread(id)?.queuedTurns.count == 2 && store.thread(id)?.messages.isEmpty == true)
        #expect(await fixture.harness.provider.calls.isEmpty)
        await peer.release()
        try await waitWorktreeUI { await fixture.harness.provider.calls.count == 1 }
        let first = try #require(await fixture.harness.provider.calls.first)
        #expect(first == .init(text: "First waiting prompt", path: request.destinationPath, model: "first-model", permission: .supervised))
        #expect(store.canAccessWorkspaceFiles(request.destinationPath))
        #expect(try String(contentsOf: URL(fileURLWithPath: request.destinationPath).appendingPathComponent("notes.txt"), encoding: .utf8) == "Committed base\n")
        await fixture.harness.provider.finish()
        try await waitWorktreeUI { await fixture.harness.provider.calls.count == 2 }
        let second = try #require(await fixture.harness.provider.calls.last)
        #expect(second == .init(text: "Second waiting prompt", path: request.destinationPath, model: "second-model", permission: .fullAccess))
        await fixture.harness.provider.finish()
        try await waitWorktreeUI { store.thread(id)?.isBusy == false && store.thread(id)?.queuedTurns.isEmpty == true }
        #expect(store.thread(id)?.draft == "Unsent while preparing")
        try fixture.checkSource()
        await store.shutdown()
        let reopened = WorkspaceStore(databaseURL: fixture.database); await reopened.load()
        #expect(reopened.thread(id)?.workspacePreparation?.isReady == true)
        #expect(reopened.thread(id)?.workspacePath == request.destinationPath && reopened.thread(id)?.draft == "Unsent while preparing")
        await reopened.shutdown()
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeFailedWorktreeSetupCanChooseTheOriginalRegisteredCheckoutWithoutLosingDraftOrLocalFiles() async throws {
    let fixture = try await WorktreeUIFixture.make(), store = fixture.store, id = fixture.thread.id
    do {
        await store.prepareWorktree(for: id, selection: .createBranch(name: "invalid-base-feature", baseRef: "refs/heads/does-not-exist"))
        try await waitWorktreeUI { store.thread(id)?.workspacePreparation?.phase == .failed }
        let failedRequest = try #require(store.thread(id)?.workspacePreparation?.request)
        #expect(store.thread(id)?.draft == "Keep this unsent draft" && !store.canAccessWorkspaceFiles(failedRequest.destinationPath))
        let options = try await store.worktreeSetupOptions(for: id)
        #expect(options.worktrees.map(\.path) == [fixture.source.path])
        await store.prepareWorktree(for: id, selection: .reuse(path: fixture.source.path))
        let request = try #require(store.thread(id)?.workspacePreparation?.request), peer = fixture.harness.peer(request)
        #expect(request.id != failedRequest.id && request.sourcePath == fixture.source.path)
        try await waitWorktreeUI { await peer.starts == 1 }
        await peer.release()
        try await waitWorktreeUI { store.thread(id)?.workspacePreparation?.isReady == true }
        #expect(store.thread(id)?.workspacePath == fixture.source.path && store.thread(id)?.draft == "Keep this unsent draft")
        #expect(store.thread(id)?.workspacePreparation?.previousAttempts.map(\.request.id).contains(failedRequest.id) == true)
        #expect(await fixture.harness.provider.calls.isEmpty)
        try fixture.checkSource()
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeChangingACompletedWorktreeRetainsUnsavedEditorAndRejectsTheNewIntent() async throws {
    let fixture = try await WorktreeUIFixture.make(), store = fixture.store, id = fixture.thread.id
    do {
        await store.prepareWorktree(for: id, selection: .createBranch(name: "dirty-editor-feature", baseRef: "HEAD"))
        let request = try #require(store.thread(id)?.workspacePreparation?.request), peer = fixture.harness.peer(request)
        try await waitWorktreeUI { await peer.starts == 1 }; await peer.release()
        try await waitWorktreeUI { store.thread(id)?.workspacePreparation?.isReady == true }
        let editor = try store.fileBrowser(path: request.destinationPath)
        #expect(await editor.open("notes.txt")); editor.setContents("Unsaved worktree edits")
        #expect(editor.isDirty && store.hasUnsavedFileEdits)
        await store.prepareWorktree(for: id, selection: .createBranch(name: "must-not-replace-editor", baseRef: "HEAD"))
        #expect(store.errorMessage?.contains("Save or discard") == true)
        #expect(store.thread(id)?.workspacePreparation?.id == request.id && store.thread(id)?.workspacePath == request.destinationPath)
        #expect(editor.isDirty && editor.contents == "Unsaved worktree edits" && store.hasUnsavedFileEdits)
        #expect(try store.fileBrowser(path: request.destinationPath) === editor)
        #expect(try String(contentsOf: URL(fileURLWithPath: request.destinationPath).appendingPathComponent("notes.txt"), encoding: .utf8) == "Committed base\n")
        try fixture.checkSource()
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeWorktreeChangeRequiresClosingOnlyThatConversationsTerminalsAcrossEveryWindow() async throws {
    let fixture = try await WorktreeUIFixture.make(), store = fixture.store, id = fixture.thread.id
    let firstWindow = TerminalWorkspaceStore(), secondWindow = TerminalWorkspaceStore(), otherID = UUID()
    store.registerTerminals(firstWindow); store.registerTerminals(secondWindow)
    do {
        let first = try LocalTerminalSession(directory: fixture.source, executable: "/bin/sh", arguments: [])
        let second = try LocalTerminalSession(directory: fixture.source, executable: "/bin/sh", arguments: [])
        let unrelated = try LocalTerminalSession(directory: fixture.source, executable: "/bin/sh", arguments: [])
        firstWindow.sessions[id] = [first]; secondWindow.sessions[id] = [second]; secondWindow.sessions[otherID] = [unrelated]
        await store.prepareWorktree(for: id, selection: .createBranch(name: "terminals-must-close", baseRef: "HEAD"))
        #expect(store.errorMessage?.contains("terminal tabs in every window") == true)
        #expect(store.thread(id)?.workspacePreparation == nil && store.thread(id)?.workspacePath == fixture.source.path)
        #expect(first.lifecycle == .running && second.lifecycle == .running && unrelated.lifecycle == .running)
        let closing = firstWindow.remove(threadIDs: [id]) + secondWindow.remove(threadIDs: [id])
        for session in closing { await session.waitForClose() }
        store.errorMessage = nil
        await store.prepareWorktree(for: id, selection: .createBranch(name: "terminals-must-close", baseRef: "HEAD"))
        let request = try #require(store.thread(id)?.workspacePreparation?.request), peer = fixture.harness.peer(request)
        try await waitWorktreeUI { await peer.starts == 1 }; await peer.release()
        try await waitWorktreeUI { store.thread(id)?.workspacePreparation?.isReady == true }
        #expect(store.errorMessage == nil && firstWindow.sessions[id] == nil && secondWindow.sessions[id] == nil)
        #expect(secondWindow.sessions[otherID]?.first === unrelated && unrelated.lifecycle == .running)
        #expect(store.thread(id)?.workspacePath == request.destinationPath)
        #expect(!store.canOpenTerminal(for: fixture.thread), "A retained terminal action must reject its old conversation cwd even while that source remains registered.")
        #expect(store.canOpenTerminal(for: try #require(store.thread(id))))
        try fixture.checkSource()
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}
