import CSQLite
import CoincideTerminal
import Darwin
import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private actor NativeCheckoutPeer {
    let root: URL
    let repository: GitHubRepository
    private(set) var writes = 0
    private(set) var inspections = 0
    private(set) var cancellationObserved = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var uncertain = false
    private var inspectCompleted = false
    init(root: URL, repository: GitHubRepository) { self.root = root; self.repository = repository }
    func configureUncertain() { uncertain = true; inspectCompleted = false }
    func revealCompletion() { inspectCompleted = true }
    func release() { waiter?.resume(); waiter = nil }
    func prepare(_ request: GitHubPullRequestCheckoutRequest) throws -> GitHubPullRequestCheckoutPlan {
        let identity = GitWorktreeNodeIdentity(device: 1, inode: 2)
        let summary = try GitHubPullRequestSummary(reference: request.reference, title: "Open the reviewed native PR",
            url: "https://github.com/fixture/native-pr/pull/42", state: .open, isDraft: false,
            headBranch: "feature/review", baseBranch: "main", headCommit: String(repeating: "a", count: 40),
            baseCommit: String(repeating: "b", count: 40), headRepository: repository, author: "fixture")
        let proof = GitHubPullRequestCheckoutProof(sourceIdentity: identity, repositoryIdentity: identity,
            gitDirectoryPath: root.path + "/.git", gitDirectoryIdentity: identity, commonDirectoryIdentity: identity,
            sourceFingerprint: String(repeating: "c", count: 64), statusDigest: String(repeating: "d", count: 64),
            headCommit: String(repeating: "b", count: 40), branch: "main")
        let destination = request.mode == .local ? root.path : request.destinationRoot + "/" + request.id.uuidString
        return try .init(request: request, sourcePath: root.path, repositoryPath: root.path,
            commonDirectoryPath: root.path + "/.git", destinationPath: destination, pullRequest: summary,
            requestedBranch: "feature/review", requestedHeadCommit: summary.headCommit,
            disposition: request.mode == .local ? .local : .createWorktree, proof: proof,
            baseRemote: .init(name: "origin", url: "https://github.com/fixture/native-pr.git", repository: repository, needsCreation: false),
            destinationParentIdentity: identity)
    }
    func result(_ plan: GitHubPullRequestCheckoutPlan) throws -> GitHubPullRequestCheckoutResult {
        if plan.request.mode == .local {
            return .init(destinationPath: plan.destinationPath, branch: plan.requestedBranch,
                         headCommit: plan.requestedHeadCommit, isOnPullRequestHead: true, created: false, reused: false, moved: true)
        }
        let request = GitWorktreeRequest(id: plan.id, sourcePath: plan.repositoryPath, destinationRoot: plan.request.destinationRoot,
            selection: .createBranch(name: plan.requestedBranch, baseRef: plan.requestedHeadCommit))
        let child = try GitWorktreePlan(request: request, sourcePath: plan.repositoryPath, commonDirectoryPath: plan.commonDirectoryPath,
            sourceIdentity: plan.proof.repositoryIdentity, commonDirectoryIdentity: plan.proof.commonDirectoryIdentity,
            destinationParentIdentity: plan.destinationParentIdentity, branch: plan.requestedBranch, baseCommit: plan.requestedHeadCommit)
        return .init(destinationPath: plan.destinationPath, branch: plan.requestedBranch, headCommit: plan.requestedHeadCommit,
            isOnPullRequestHead: true, created: true, reused: false, moved: true,
            worktreePlan: child, worktreeResult: .init(destinationPath: plan.destinationPath, headCommit: plan.requestedHeadCommit, branch: plan.requestedBranch))
    }
    func run(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutResult {
        writes += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: { Task { await self.observeCancellation() } }
        try Task.checkCancellation()
        if plan.request.mode == .local { try Data("Reviewed PR bytes\n".utf8).write(to: root.appendingPathComponent("tracked.txt"), options: .atomic) }
        if uncertain { throw GitHubPullRequestCheckoutError(.commandFailed, mayHaveChanged: true) }
        return try result(plan)
    }
    private func observeCancellation() { cancellationObserved = true }
    func inspect(_ plan: GitHubPullRequestCheckoutPlan) throws -> GitHubPullRequestCheckoutInspection {
        inspections += 1
        return inspectCompleted ? .completed(try result(plan)) : .unconfirmed
    }
}

private struct NativeCheckoutSession: GitHubPullRequestCheckoutSession {
    let request: GitHubPullRequestCheckoutRequest
    let peer: NativeCheckoutPeer
    func prepare() async throws -> GitHubPullRequestCheckoutPlan { try await peer.prepare(request) }
    func run(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutResult { try await peer.run(plan) }
    func inspectCompletion(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutInspection { try await peer.inspect(plan) }
}

@MainActor private struct NativeCheckoutFixture {
    let root: URL
    let database: URL
    let project: WorkspaceProject
    let sourceID: UUID
    let coldID: UUID
    let peer: NativeCheckoutPeer
    let reads: PullRequestNativePeer
    let workspace: WorkspaceStore
    let model: PullRequestStore
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-checkout-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Original checkout bytes\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        let reads = try PullRequestNativePeer(root: root), peer = NativeCheckoutPeer(root: root, repository: reads.repository)
        let project = WorkspaceProject(path: root.path), database = root.appendingPathComponent("workspace.sqlite")
        var source = CodingThread(project: project)
        source.provider = .claude; source.model = "native-checkout-model"; source.permission = .fullAccess
        source.providerThreadID = "Do not inherit this provider session"; source.checkpointPolicy = .disabled
        source.messages = [.init(role: .user, text: "Retain source history")]; source.draft = "Retain source draft"
        var cold = CodingThread(project: project); cold.workspacePath = root.path + "-cold"; cold.isArchived = true
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [source, cold]
        try await WorkspaceDatabase(url: database).save(snapshot, event: "checkout.native.fixture")
        let workspace = try makeWorkspace(database: database, peer: peer, reads: reads)
        await workspace.load(); workspace.selectedThreadID = source.id
        let model = workspace.pullRequestStore(path: root.path); await model.refresh()
        return .init(root: root, database: database, project: project, sourceID: source.id, coldID: cold.id,
                     peer: peer, reads: reads, workspace: workspace, model: model)
    }
    static func makeWorkspace(database: URL, peer: NativeCheckoutPeer, reads: PullRequestNativePeer) throws -> WorkspaceStore {
        let engine = try WorkspaceEngine(url: database,
            providerFactory: { _ in throw CoincideError("Checkout must never send a prompt.") }, identityResolver: { _ in nil },
            pullRequestFactory: { _ in reads }, pullRequestCheckoutFactory: { NativeCheckoutSession(request: $0, peer: peer) })
        let workspace = WorkspaceStore(engine: engine); workspace.pullRequestSessionFactory = { _ in reads }; return workspace
    }
    func review(mode: GitHubPullRequestCheckoutMode = .local) async throws -> PullRequestCheckoutReview {
        try await model.prepareCheckout(reference: .init(repository: reads.repository, number: 42), mode: mode, reviewSetup: false)
    }
    func finish(reopened: WorkspaceStore? = nil) async {
        await reads.releaseContext(); await reads.releaseCreate(); await peer.release()
        await reopened?.shutdown(); await workspace.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [GitHubPullRequestCheckoutMode.local, .worktree])
func nativePRCheckoutHoldsAllWindowsBeforeSQLiteAndCreatesOnlyTheConfirmedBlankTarget(mode: GitHubPullRequestCheckoutMode) async throws {
    let f = try await NativeCheckoutFixture.make()
    var writer: OpaquePointer?, locked = false
    func unlock() { if locked { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); locked = false } }
    defer { unlock(); if let writer { sqlite3_close(writer) } }
    do {
        let source = try #require(f.workspace.thread(f.sourceID)), review = try await f.review(mode: mode)
        #expect(f.workspace.pullRequestStore(path: f.root.appendingPathComponent(".").path) === f.model)
        #expect(sqlite3_open(f.database.path, &writer) == SQLITE_OK)
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK); locked = true
        let acceptance = Task { try await f.model.checkout(review) }
        try await waitForNativePullRequest { f.model.isAccepting }
        #expect(f.workspace.snapshot.pullRequestCheckout(review.id) == nil)
        #expect(f.workspace.isPullRequestCheckoutLocked(threadID: f.sourceID))
        #expect(f.workspace.isPullRequestCheckoutLocked(threadID: f.coldID))
        #expect(!f.workspace.canEditWorkspace(f.root.path) && !f.workspace.canOpenTerminal(for: source))
        #expect(!f.workspace.workspaceReady(for: source) && f.workspace.canPresentWorkspaceInspector(for: source))
        #expect(await f.workspace.submit("Keep this draft", threadID: f.sourceID).value == false)
        #expect(f.workspace.thread(f.sourceID)?.draft == source.draft)
        unlock(); try await acceptance.value
        try await waitForNativePullRequest { await f.peer.writes == 1 }
        #expect(f.model.checkoutOperation?.phase == .dispatching && f.workspace.thread(review.targetThreadID) == nil)
        f.workspace.setDraft("Typed during PR checkout", id: f.sourceID)
        await f.peer.release()
        try await waitForNativePullRequest { f.model.checkoutOperation?.phase == .completed }
        let target = try #require(f.workspace.thread(review.targetThreadID))
        #expect(target.messages.isEmpty && target.draft.isEmpty && target.draftAttachments.isEmpty && target.queuedTurns.isEmpty)
        #expect(target.providerThreadID == nil && target.provider == .claude && target.model == source.model && target.permission == .fullAccess)
        #expect(target.workspacePath == review.plan.destinationPath && target.checkpointPolicy == .disabled)
        #expect(target.pullRequestCheckoutOperationID == review.id && f.workspace.selectedThreadID == target.id)
        #expect(f.workspace.thread(f.sourceID)?.messages == source.messages && f.workspace.thread(f.sourceID)?.draft == "Typed during PR checkout")
        #expect(f.workspace.canEditWorkspace(f.root.path) && !f.workspace.isPullRequestCheckoutLocked(threadID: f.coldID))
        #expect(await f.peer.writes == 1)
        try WorkspaceJournal.validate(f.workspace.snapshot)
    } catch { unlock(); await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func nativePRCheckoutUnknownSurvivesRestartAndInspectionNeverRepeatsCheckout(found: Bool) async throws {
    let f = try await NativeCheckoutFixture.make()
    var reopened: WorkspaceStore?
    do {
        await f.peer.configureUncertain()
        let review = try await f.review(); try await f.model.checkout(review)
        try await waitForNativePullRequest { await f.peer.writes == 1 }; await f.peer.release()
        try await waitForNativePullRequest { f.model.checkoutOperation?.phase == .unconfirmed }
        #expect(f.workspace.thread(review.targetThreadID) == nil && !f.workspace.canEditWorkspace(f.root.path))
        await f.workspace.shutdown()
        let next = try NativeCheckoutFixture.makeWorkspace(database: f.database, peer: f.peer, reads: f.reads); reopened = next
        await next.load(); let model = next.pullRequestStore(path: f.root.path)
        #expect(model.checkoutOperation?.phase == .unconfirmed && !model.canCheckout && !next.canEditWorkspace(f.root.path))
        #expect(next.canPresentWorkspaceInspector(for: try #require(next.thread(f.sourceID))))
        if found { await f.peer.revealCompletion() }
        try await model.inspectCheckout()
        if found {
            #expect(next.thread(review.targetThreadID) != nil && model.checkoutOperation?.phase == .completed)
        } else {
            #expect(next.thread(review.targetThreadID) == nil && model.checkoutOperation?.phase == .unconfirmed)
            try await model.acknowledgeCheckout()
            #expect(next.thread(review.targetThreadID) == nil && model.checkoutOperation?.acknowledgedAt != nil)
        }
        #expect(next.canEditWorkspace(f.root.path))
        #expect(await f.peer.writes == 1)
        #expect(next.thread(f.sourceID)?.draft == "Retain source draft")
        try WorkspaceJournal.validate(next.snapshot)
    } catch { await f.finish(reopened: reopened); throw error }
    await f.finish(reopened: reopened)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePRCheckoutDiscardsStaleReadsRefreshesCleanEditorsAndRespectsSelectionChanges() async throws {
    let f = try await NativeCheckoutFixture.make()
    var stale: Task<Void, Never>?, acceptance: Task<Void, any Error>?
    do {
        let browser = try f.workspace.fileBrowser(path: f.root.path)
        #expect(await browser.open("tracked.txt"))
        #expect(browser.contents == "Original checkout bytes\n")
        let review = try await f.review()
        await f.reads.configureContextGate()
        stale = Task { await f.model.refresh() }
        try await waitForNativePullRequest { await f.reads.enteredContext }
        acceptance = Task { try await f.model.checkout(review) }
        try await waitForNativePullRequest { f.model.isAccepting }
        await Task.yield()
        #expect(await f.peer.writes == 0)
        #expect(!browser.canWrite)
        f.workspace.selectedThreadID = f.coldID
        await f.reads.setBranch("feature/review"); await f.reads.releaseContext(); await stale?.value
        try await acceptance?.value
        try await waitForNativePullRequest { await f.peer.writes == 1 }; await f.peer.release()
        try await waitForNativePullRequest {
            f.model.checkoutOperation?.phase == .completed && browser.contents == "Reviewed PR bytes\n" && f.model.context?.branch == "feature/review"
        }
        #expect(f.workspace.selectedThreadID == f.coldID)
        #expect(browser.canWrite && !browser.isDirty)
        f.model.openCheckoutConversation()
        #expect(f.workspace.selectedThreadID == review.targetThreadID)
    } catch { await f.reads.releaseContext(); await stale?.value; _ = await acceptance?.result; await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePRCheckoutRejectsNewUnsavedEditsAfterReviewWithAnActionableMessage() async throws {
    let f = try await NativeCheckoutFixture.make()
    do {
        let review = try await f.review(), browser = try f.workspace.fileBrowser(path: f.root.path)
        #expect(await browser.open("tracked.txt")); browser.setContents("Unsaved editor bytes")
        #expect(!f.model.canCheckout)
        await #expect(throws: WorkspaceCommandError.self) { try await f.model.checkout(review) }
        #expect(f.model.actionError?.contains("Save or discard") == true)
        #expect(browser.contents == "Unsaved editor bytes" && browser.isDirty)
        #expect(await f.peer.writes == 0)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePRCheckoutShutdownDrainsTheOwnedWriterAndReopenPreservesTheUnconfirmedHold() async throws {
    let f = try await NativeCheckoutFixture.make()
    var shutdown: Task<Void, Never>?, reopened: WorkspaceStore?, finished = false
    do {
        let review = try await f.review(); try await f.model.checkout(review)
        try await waitForNativePullRequest { await f.peer.writes == 1 }
        shutdown = Task { await f.workspace.shutdown(); finished = true }
        try await waitForNativePullRequest { await f.peer.cancellationObserved }
        #expect(!finished)
        await f.peer.release(); await shutdown?.value
        #expect(finished)
        let next = try NativeCheckoutFixture.makeWorkspace(database: f.database, peer: f.peer, reads: f.reads); reopened = next
        await next.load()
        #expect(next.snapshot.pullRequestCheckout(review.id)?.phase == .unconfirmed)
        #expect(next.thread(review.targetThreadID) == nil && !next.canEditWorkspace(f.root.path))
        #expect(next.thread(f.sourceID)?.draft == "Retain source draft")
        #expect(await f.peer.writes == 1)
    } catch { await f.peer.release(); await shutdown?.value; await f.finish(reopened: reopened); throw error }
    await f.finish(reopened: reopened)
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func nativePRCheckoutWaitsForRemovedTerminalTabsAndWindowsToDrain(windowClosed: Bool) async throws {
    let f = try await NativeCheckoutFixture.make(), terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    f.workspace.registerTerminals(terminals)
    var terminal: LocalTerminalSession?
    do {
        let source = try #require(f.workspace.thread(f.sourceID))
        let script = try ProjectScript(name: "Owned closing terminal", command: "trap '' HUP TERM; printf ready > terminal-ready; while :; do /bin/sleep 0.05; done")
        let session = try terminals.run(.init(script: script, projectRoot: f.root), for: source); terminal = session
        try await waitForNativePullRequest { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("terminal-ready").path) }
        let pid = session.processID
        if windowClosed { terminals.closeAll(); f.workspace.unregisterTerminals(terminals) }
        else { terminals.close(session, threadID: source.id) }
        #expect(terminals.sessions.values.flatMap { $0 }.isEmpty && kill(pid, 0) == 0)
        #expect(!f.model.canCheckout)
        await #expect(throws: WorkspaceCommandError.self) { try await f.review() }
        #expect(f.model.actionError?.contains("Close terminals") == true)
        #expect(await f.peer.writes == 0)
        await session.waitForClose()
        #expect(!session.view.process.running && !session.view.process.windingDown)
        try await waitForNativePullRequest { f.model.canCheckout }
        #expect(kill(pid, 0) != 0)
        let review = try await f.review(); await f.model.discardCheckoutReview(review.id)
    } catch {
        terminals.closeAll(); await terminal?.waitForClose(); f.workspace.unregisterTerminals(terminals)
        await f.finish(); throw error
    }
    f.workspace.unregisterTerminals(terminals); await f.finish()
}
