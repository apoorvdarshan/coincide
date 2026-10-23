import Darwin
import Foundation
import Testing
@testable import CoincideCore

private func defaultWorktreeIntent(_ f: WorktreeFixture, project: WorkspaceProject, thread: CodingThread? = nil, origin: Bool = false) async throws -> DraftWorkspaceIntent {
    let proof = try await TaskIsolationCapture(environment: f.environment, gitExecutable: f.git)
        .capture(parentWorkspacePath: project.path, projectPath: project.path)
    let branch = try await f.run(["symbolic-ref", "--short", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
    return .init(project: project, threadID: thread?.id ?? UUID(), threadCreatedAt: thread?.createdAt ?? Date(), startFromOrigin: origin, submodules: .none, sourceProof: proof, baseBranch: branch)
}
private func defaultWorktreeRequest(_ f: WorktreeFixture, intent: DraftWorkspaceIntent, id: UUID = UUID()) -> GitWorktreeRequest {
    .init(id: DefaultWorktreeIdentity.preparationID(commandID: id), sourcePath: intent.sourcePath, destinationRoot: f.destinations.path,
          selection: .createBranch(name: "coincide/" + id.uuidString.lowercased(), baseRef: "refs/heads/" + intent.baseBranch),
          submodules: intent.submodules, expectedSourceIdentity: intent.sourceProof.sourceIdentity, automaticBase: .init(intent: intent))
}
private func defaultWorktreeEventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private default-worktree fixture did not reach its explicit state.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test func defaultWorktreeAtomicallyQueuesOriginalInputAndReferencesBehindPreparationAndKeepsLegacyLocal() async throws {
    let f = try await WorktreeFixture.make(); defer { f.cleanup() }
    let project = WorkspaceProject(path: f.source.path)
    var thread = CodingThread(project: project, model: "fixture")
    let intent = try await defaultWorktreeIntent(f, project: project, thread: thread)
    thread.draftWorkspaceIntent = intent; thread.draft = "literal /tmp path 🧪"
    let attachment = ChatAttachment(id: UUID(), name: "source.txt", mimeType: "text/plain", byteCount: 16, digest: String(repeating: "a", count: 64), fileExtension: "txt")
    thread.draftAttachments = [attachment]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let id = UUID(), input = DefaultWorktreeInput(thread: thread, intent: intent, text: thread.draft)
    #expect(throws: WorkspaceCommandError.self) {
        try WorkspaceDecision.make(.client(.submit(threadID: thread.id, text: thread.draft)), id: UUID(), snapshot: snapshot, now: Date())
    }
    let request = defaultWorktreeRequest(f, intent: intent, id: id)
    let accepted = try WorkspaceDecision.make(.defaultWorktreeSubmission(input, request), id: id, snapshot: snapshot, now: Date())
    let current = try #require(accepted.snapshot.threads.first)
    #expect(current.workspacePreparation?.id == request.id && current.workspacePath == request.destinationPath)
    #expect(current.draftWorkspaceIntent == nil && current.draft.isEmpty && current.draftAttachments.isEmpty)
    #expect(current.queuedTurns.count == 1 && current.queuedTurns.first?.id == id)
    #expect(current.queuedTurns.first?.text == input.text && current.queuedTurns.first?.attachments == [attachment])
    #expect(current.queuedTurns.first?.configuration.workspacePath == request.destinationPath)
    #expect(current.messages.isEmpty && current.activeRun == nil)
    #expect(accepted.effects.count == 1)
    if case .resolveWorktree(let owner, let captured) = accepted.effects[0].request { #expect(owner == thread.id && captured == request) }
    else { Issue.record("The atomic input escaped the worktree readiness gate.") }
    // The ordinary Local choice is durable and does not manufacture a worktree.
    let local = try WorkspaceDecision.make(.client(.useCurrentCheckout(threadID: thread.id, intentID: intent.id)), id: UUID(), snapshot: snapshot, now: Date())
    #expect(local.snapshot.threads.first?.draftWorkspaceIntent == nil)
    #expect(local.snapshot.threads.first?.draft == thread.draft && local.snapshot.threads.first?.draftAttachments == [attachment])
    let legacy = CodingThread(project: project, model: "fixture")
    var old = snapshot; old.threads = [legacy]
    let localSend = try WorkspaceDecision.make(.client(.submit(threadID: legacy.id, text: "legacy remains Local")), id: UUID(), snapshot: old, now: Date())
    #expect(localSend.snapshot.threads.first?.workspacePreparation == nil)
    let encoded = try JSONEncoder().encode(thread)
    #expect(try JSONDecoder().decode(CodingThread.self, from: encoded).draftWorkspaceIntent == intent)
}

@Test(arguments: ["birth", "project", "configuration", "attachments", "checkpoint", "intent"])
func defaultWorktreeRefusesStaleInputWithoutMovingSourceOrConsumingDraft(mode: String) async throws {
    let f = try await WorktreeFixture.make(); defer { f.cleanup() }
    let project = WorkspaceProject(path: f.source.path)
    var thread = CodingThread(project: project, model: "fixture")
    let intent = try await defaultWorktreeIntent(f, project: project, thread: thread)
    thread.draftWorkspaceIntent = intent; thread.draft = "keep me"
    let input = DefaultWorktreeInput(thread: thread, intent: intent, text: thread.draft), id = UUID()
    switch mode {
    case "birth": thread.createdAt = thread.createdAt.addingTimeInterval(1)
    case "project": thread.projectID = UUID()
    case "configuration": thread.permission = .fullAccess
    case "checkpoint": thread.checkpointPolicy = .disabled
    case "attachments": thread.draftAttachments = [.init(id: UUID(), name: "later.txt", mimeType: "text/plain", byteCount: 16, digest: String(repeating: "b", count: 64), fileExtension: "txt")]
    default: thread.draftWorkspaceIntent = nil
    }
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    #expect(throws: WorkspaceCommandError.self) {
        try WorkspaceDecision.make(.defaultWorktreeSubmission(input, defaultWorktreeRequest(f, intent: intent, id: id)), id: id, snapshot: snapshot, now: Date())
    }
    #expect(snapshot.threads[0].draft == "keep me" && snapshot.threads[0].workspacePreparation == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destinations.path).isEmpty)
}

@Test func defaultWorktreeUsesConfiguredUpstreamFreshCommitAndPreservesDirtySourceAndIndex() async throws {
    let f = try await WorktreeFixture.make(); defer { f.cleanup() }
    _ = try await f.run(["branch", "-m", "product/development"])
    let bare = f.root.appendingPathComponent("private-bare"), writer = f.root.appendingPathComponent("private-writer")
    _ = try await f.run(["init", "--bare", bare.path], at: f.root)
    _ = try await f.run(["remote", "add", "team-source", bare.path])
    _ = try await f.run(["push", "team-source", "HEAD:refs/heads/server-base"])
    _ = try await f.run(["config", "branch.product/development.remote", "team-source"])
    _ = try await f.run(["config", "branch.product/development.merge", "refs/heads/server-base"])
    _ = try await f.run(["clone", "--no-hardlinks", "--branch", "server-base", "--", bare.path, writer.path], at: f.root)
    _ = try await f.run(["config", "user.name", "Private Writer"], at: writer)
    _ = try await f.run(["config", "user.email", "writer@example.invalid"], at: writer)
    _ = try await f.run(["config", "commit.gpgsign", "false"], at: writer)
    try Data("new remote commit\n".utf8).write(to: writer.appendingPathComponent("REMOTE.txt"))
    _ = try await f.run(["add", "--", "REMOTE.txt"], at: writer); _ = try await f.run(["commit", "-m", "Private remote change"], at: writer)
    _ = try await f.run(["push", "origin", "server-base"], at: writer)
    let expected = try await f.run(["rev-parse", "HEAD"], at: writer).text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Upstream remote/merge metadata must work even before a tracking ref exists.
    _ = try await f.run(["update-ref", "-d", "refs/remotes/team-source/server-base"])
    let project = WorkspaceProject(path: f.source.path), intent = try await defaultWorktreeIntent(f, project: project, origin: true)
    try Data("dirty source\n".utf8).write(to: f.source.appendingPathComponent("README.md"))
    try Data("untracked source\n".utf8).write(to: f.source.appendingPathComponent("UNTRACKED.txt"))
    let status = try await f.run(["status", "--porcelain=v1", "-z"]).output
    let index = try await f.run(["ls-files", "--stage", "-z"]).output
    let request = defaultWorktreeRequest(f, intent: intent), service = f.service(request)
    let plan = try await service.prepare()
    #expect(plan.baseCommit == expected && intent.baseBranch == "product/development")
    let result = try await service.run(plan)
    #expect(result.headCommit == expected && result.destinationPath == request.destinationPath)
    #expect(try await f.run(["status", "--porcelain=v1", "-z"]).output == status)
    #expect(try await f.run(["ls-files", "--stage", "-z"]).output == index)
    #expect(try await f.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines) == intent.sourceProof.baseCommit)
    #expect(try Data(contentsOf: URL(fileURLWithPath: request.destinationPath).appendingPathComponent("REMOTE.txt")) == Data("new remote commit\n".utf8))
}

@Test func defaultWorktreeFailedFetchNeverUsesStaleTrackingRefOrCreatesBaseTurn() async throws {
    let f = try await WorktreeFixture.make(); defer { f.cleanup() }
    let bare = f.root.appendingPathComponent("private-bare")
    _ = try await f.run(["init", "--bare", bare.path], at: f.root)
    _ = try await f.run(["remote", "add", "origin", bare.path])
    _ = try await f.run(["push", "origin", "HEAD:refs/heads/server-base"])
    _ = try await f.run(["config", "branch.main.remote", "origin"])
    _ = try await f.run(["config", "branch.main.merge", "refs/heads/server-base"])
    let project = WorkspaceProject(path: f.source.path), intent = try await defaultWorktreeIntent(f, project: project, origin: true)
    _ = try await f.run(["push", "origin", ":refs/heads/server-base"])
    _ = try await f.run(["update-ref", "refs/remotes/origin/server-base", intent.sourceProof.baseCommit])
    let request = defaultWorktreeRequest(f, intent: intent)
    await #expect(throws: GitWorktreeError.self) { try await f.service(request).prepare() }
    #expect(!FileManager.default.fileExists(atPath: request.destinationPath))
    #expect(try await f.run(["rev-parse", "refs/remotes/origin/server-base"]).text.trimmingCharacters(in: .whitespacesAndNewlines) == intent.sourceProof.baseCommit)
}

private actor DefaultWorktreeProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private(set) var inputs: [(ProviderInput, ProviderConfiguration)] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [.init(id: "fixture", name: "Private Fixture")] }
    func send(text: String, thread: CodingThread) { send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) { inputs.append((input, .init(thread: thread))) }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { sink.finish() }
}
private final class DefaultWorktreeProviders: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [DefaultWorktreeProvider] = []
    func make(_ thread: CodingThread) -> any ProviderSession { let value = DefaultWorktreeProvider(); lock.withLock { providers.append(value) }; return value }
    func all() -> [DefaultWorktreeProvider] { lock.withLock { providers } }
    func count() async -> Int { var count = 0; for peer in all() { count += await peer.inputs.count }; return count }
}

@Test func defaultWorktreeNativeEngineRequiresSetupReviewThenSendsOnceAndOriginalReceiptSurvivesRestart() async throws {
    let f = try await WorktreeFixture.make(); defer { f.cleanup() }
    try Data(#"{"scripts":[{"name":"Never run automatically","command":"exit 99","runOnWorktreeCreate":true,"runsAsynchronously":false}]}"#.utf8)
        .write(to: f.source.appendingPathComponent("t3.json"))
    _ = try await f.run(["add", "--", "t3.json"]); _ = try await f.run(["commit", "-m", "Private setup review"])
    let project = WorkspaceProject(path: f.source.path)
    var thread = CodingThread(project: project, model: "fixture")
    let intent = try await defaultWorktreeIntent(f, project: project, thread: thread)
    thread.draftWorkspaceIntent = intent; thread.draft = "original input 🧪"
    let input = DefaultWorktreeInput(thread: thread, intent: intent, text: thread.draft), id = UUID(), peers = DefaultWorktreeProviders()
    let database = f.root.appendingPathComponent("workspace.sqlite")
    func makeEngine() throws -> WorkspaceEngine {
        try WorkspaceEngine(url: database, providerFactory: { peers.make($0) }, identityResolver: { _ in nil },
            worktreeFactory: { f.service($0) }, projectScriptPlanner: { context in
                let files = WorkspaceFileService(root: context.workspacePath)
                do {
                    let plan = try await ProjectScriptExecutionPlan.capture(scriptIndex: 0, using: files,
                        projectRoot: context.projectRoot, shell: URL(fileURLWithPath: "/bin/sh"), id: context.id)
                    await files.close(); return plan
                } catch { await files.close(); throw error }
            }, projectScriptFactory: { _ in throw CoincideError("The private setup must never execute.") })
    }
    let engine = try makeEngine()
    do {
        _ = try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        let receipt = try await engine.dispatch(.submitDefaultWorktree(input), id: id)
        try await defaultWorktreeEventually { await engine.current().snapshot.threads.first?.workspacePreparation?.setup?.phase == .awaitingApproval }
        let waiting = try #require(await engine.current().snapshot.threads.first)
        let beforeSendCount = await peers.count()
        #expect(beforeSendCount == 0 && waiting.messages.isEmpty)
        #expect(waiting.queuedTurns.count == 1 && waiting.queuedTurns.first?.id == id)
        let state = try #require(waiting.workspacePreparation), setup = try #require(state.setup)
        #expect(state.id == DefaultWorktreeIdentity.preparationID(commandID: id) && state.result != nil && setup.plan?.script.command == "exit 99")
        _ = try await engine.dispatch(.skipProjectScript(threadID: thread.id, runID: setup.id))
        try await defaultWorktreeEventually { await peers.count() == 1 }
        let sent = try #require(await engine.current().snapshot.threads.first)
        #expect(sent.activeRun?.id == id && sent.workspacePath == state.destinationPath)
        #expect(sent.messages.filter { $0.role == .user }.map(\.text) == [input.text])
        #expect(try await engine.dispatch(.submitDefaultWorktree(input), id: id) == receipt)
        #expect(await peers.count() == 1)
        await engine.shutdown()
        let reopened = try makeEngine()
        do {
            _ = try await reopened.load()
            #expect(try await reopened.dispatch(.submitDefaultWorktree(input), id: id) == receipt)
            let restored = try #require(await reopened.current().snapshot.threads.first)
            #expect(restored.messages.filter { $0.role == .user }.count == 1 && restored.queuedTurns.isEmpty)
            let countAfterRestart = await peers.count()
            #expect(restored.workspacePreparation?.request.id == DefaultWorktreeIdentity.preparationID(commandID: id) && countAfterRestart == 1)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    } catch { await engine.shutdown(); throw error }
}

private actor DefaultWorktreeCancelledPreparation: WorkspaceWorktreeSession {
    let request: GitWorktreeRequest
    let native: GitWorktreeService
    private var first = true
    private var gate: CheckedContinuation<Void, any Error>?
    private(set) var entered = false
    init(_ request: GitWorktreeRequest, fixture: WorktreeFixture) { self.request = request; native = fixture.service(request) }
    func prepare() async throws -> GitWorktreePlan {
        if first {
            first = false; entered = true
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { gate = $0 }
                try Task.checkCancellation()
            } onCancel: { Task { await self.cancel() } }
        }
        return try await native.prepare()
    }
    private func cancel() { let old = gate; gate = nil; old?.resume(throwing: CancellationError()) }
    func run(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult { try await native.run(plan) }
    func inspectCompletion(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult? { try await native.inspectCompletion(plan) }
}
private final class DefaultWorktreeCancellationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DefaultWorktreeCancelledPreparation?
    let fixture: WorktreeFixture
    init(_ fixture: WorktreeFixture) { self.fixture = fixture }
    func session(_ request: GitWorktreeRequest) -> DefaultWorktreeCancelledPreparation {
        lock.withLock {
            if let value { return value }
            let next = DefaultWorktreeCancelledPreparation(request, fixture: fixture); value = next; return next
        }
    }
    func current() -> DefaultWorktreeCancelledPreparation? { lock.withLock { value } }
}

@Test func defaultWorktreeCancelAndExplicitRetryReuseOriginalFolderAndQueuedInputWithoutBaseFallback() async throws {
    let f = try await WorktreeFixture.make(); defer { f.cleanup() }
    let project = WorkspaceProject(path: f.source.path)
    var thread = CodingThread(project: project, model: "fixture")
    let intent = try await defaultWorktreeIntent(f, project: project, thread: thread)
    thread.draftWorkspaceIntent = intent
    let input = DefaultWorktreeInput(thread: thread, intent: intent, text: "send only after retry"), id = UUID()
    let peers = DefaultWorktreeProviders(), worktrees = DefaultWorktreeCancellationFixture(f)
    let engine = try WorkspaceEngine(url: f.root.appendingPathComponent("workspace.sqlite"), providerFactory: { peers.make($0) },
        identityResolver: { _ in nil }, worktreeFactory: { worktrees.session($0) }, projectScriptPlanner: { _ in nil })
    do {
        _ = try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        let receipt = try await engine.dispatch(.submitDefaultWorktree(input), id: id)
        try await defaultWorktreeEventually { guard let session = worktrees.current() else { return false }; return await session.entered }
        let before = try #require(await engine.current().snapshot.threads.first?.workspacePreparation)
        #expect(try await engine.dispatch(.submitDefaultWorktree(input), id: id) == receipt)
        _ = try await engine.cancelWorktreePreparation(thread.id)
        try await defaultWorktreeEventually { await engine.current().snapshot.threads.first?.workspacePreparation?.phase == .cancelled }
        #expect(await peers.count() == 0)
        let cancelled = try #require(await engine.current().snapshot.threads.first)
        #expect(cancelled.queuedTurns.map(\.id) == [id] && cancelled.messages.isEmpty)
        _ = try await engine.retryWorktreePreparation(thread.id)
        try await defaultWorktreeEventually { await peers.count() == 1 }
        let after = try #require(await engine.current().snapshot.threads.first)
        #expect(after.workspacePreparation?.id == before.id && after.workspacePath == before.destinationPath)
        #expect(after.activeRun?.id == id && after.messages.filter { $0.role == .user }.map(\.text) == [input.text])
        #expect(after.workspacePreparation?.previousAttempts.isEmpty == true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("Worktrees").path)
        #expect(Set(entries) == Set([before.id.uuidString, GitWorktreeOwnership.lockname(before.id), GitWorktreeOwnership.filename(before.id), GitWorktreeCompletion.filename(before.id)]))
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}

@Test(arguments: [false, true])
func defaultWorktreeCapturedPhysicalSourceAndGitAdministrationCannotBeRetargeted(replaceGitOnly: Bool) async throws {
    let f = try await WorktreeFixture.make(); defer { f.cleanup() }
    let project = WorkspaceProject(path: f.source.path), intent = try await defaultWorktreeIntent(f, project: project)
    let request = defaultWorktreeRequest(f, intent: intent)
    if replaceGitOnly {
        try FileManager.default.moveItem(at: f.source.appendingPathComponent(".git"), to: f.root.appendingPathComponent("preserved-original-git"))
        _ = try await f.run(["init", "--initial-branch=replacement"])
    } else {
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("preserved-original-source"))
        try FileManager.default.createDirectory(at: f.source, withIntermediateDirectories: true)
        _ = try await f.run(["init", "--initial-branch=replacement"])
    }
    await #expect(throws: (any Error).self) { try await f.service(request).prepare() }
    #expect(!FileManager.default.fileExists(atPath: request.destinationPath))
}
