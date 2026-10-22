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
    private(set) var mutationRequests = 0
    private(set) var preparedPolicies: [GitHubPullRequestCheckoutPolicy] = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var uncertain = false
    private var inspectCompleted = false
    private var reusedDestination: URL?
    private var draining = false
    init(root: URL, repository: GitHubRepository) { self.root = root; self.repository = repository }
    func configureUncertain() { uncertain = true; inspectCompleted = false }
    func revealCompletion() { inspectCompleted = true }
    func reuse(_ path: URL) { reusedDestination = path }
    func release(planID: UUID) {
        let waiter = waiters.removeValue(forKey: planID)
        #expect(waiter != nil, "The held checkout worker must be released by its primitive plan ID.")
        waiter?.resume()
    }
    func release() { let pending = Array(waiters.values); waiters.removeAll(); for waiter in pending { waiter.resume() } }
    func drain() { draining = true; release() }
    func prepare(_ request: GitHubPullRequestCheckoutRequest) throws -> GitHubPullRequestCheckoutPlan {
        preparedPolicies.append(request.policy)
        let identity = GitWorktreeNodeIdentity(device: 1, inode: 2)
        let summary = try GitHubPullRequestSummary(reference: request.reference, title: "Open the reviewed native PR",
            url: "https://github.com/fixture/native-pr/pull/\(request.reference.number)", state: .open, isDraft: false,
            headBranch: request.reference.number == 42 ? "feature/review" : "feature/pr-\(request.reference.number)", baseBranch: "main", headCommit: String(repeating: "a", count: 40),
            baseCommit: String(repeating: "b", count: 40), headRepository: repository, author: "fixture")
        let proof = GitHubPullRequestCheckoutProof(sourceIdentity: identity, repositoryIdentity: identity,
            gitDirectoryPath: root.path + "/.git", gitDirectoryIdentity: identity, commonDirectoryIdentity: identity,
            sourceFingerprint: String(repeating: "c", count: 64), statusDigest: String(repeating: "d", count: 64),
            headCommit: String(repeating: "b", count: 40), branch: "main",
            destinationIdentity: reusedDestination == nil ? nil : identity,
            destinationGitDirectoryPath: reusedDestination == nil ? nil : root.path + "/.git/worktrees/reused",
            destinationGitDirectoryIdentity: reusedDestination == nil ? nil : identity,
            destinationStatusDigest: reusedDestination == nil ? nil : String(repeating: "e", count: 64),
            destinationHeadCommit: reusedDestination == nil ? nil : summary.headCommit,
            destinationBranch: reusedDestination == nil ? nil : summary.headBranch,
            destinationFingerprint: reusedDestination == nil ? nil : String(repeating: "f", count: 64),
            destinationConfigurationDigest: reusedDestination == nil ? nil : String(repeating: "a", count: 64))
        let destination = request.mode == .local ? root.path : reusedDestination?.path ?? request.destinationRoot + "/" + request.id.uuidString
        return try .init(request: request, sourcePath: root.path, repositoryPath: root.path,
            commonDirectoryPath: root.path + "/.git", destinationPath: destination, pullRequest: summary,
            requestedBranch: summary.headBranch, requestedHeadCommit: summary.headCommit,
            disposition: request.mode == .local ? .local : reusedDestination == nil ? .createWorktree : .reuseWorktree, proof: proof,
            baseRemote: .init(name: "origin", url: "https://github.com/fixture/native-pr.git", repository: repository, needsCreation: false),
            destinationParentIdentity: identity)
    }
    func result(_ plan: GitHubPullRequestCheckoutPlan) throws -> GitHubPullRequestCheckoutResult {
        if plan.request.mode == .local {
            return .init(destinationPath: plan.destinationPath, branch: plan.requestedBranch,
                         headCommit: plan.requestedHeadCommit, isOnPullRequestHead: true, created: false, reused: false, moved: true)
        }
        let reused = plan.disposition != .createWorktree
        let request = GitWorktreeRequest(id: plan.id, sourcePath: plan.repositoryPath, destinationRoot: plan.request.destinationRoot,
            selection: reused ? .reuse(path: plan.destinationPath) : .createBranch(name: plan.requestedBranch, baseRef: plan.requestedHeadCommit))
        let child = try GitWorktreePlan(request: request, sourcePath: plan.repositoryPath, commonDirectoryPath: plan.commonDirectoryPath,
            sourceIdentity: plan.proof.repositoryIdentity, commonDirectoryIdentity: plan.proof.commonDirectoryIdentity,
            destinationParentIdentity: plan.destinationParentIdentity, branch: plan.requestedBranch, baseCommit: plan.requestedHeadCommit,
            destinationIdentity: plan.proof.destinationIdentity, worktreeGitDirectoryPath: plan.proof.destinationGitDirectoryPath,
            worktreeGitDirectoryIdentity: plan.proof.destinationGitDirectoryIdentity)
        return .init(destinationPath: plan.destinationPath, branch: plan.requestedBranch, headCommit: plan.requestedHeadCommit,
            isOnPullRequestHead: true, created: !reused, reused: reused, moved: !reused,
            worktreePlan: child, worktreeResult: .init(destinationPath: plan.destinationPath, headCommit: plan.requestedHeadCommit, branch: plan.requestedBranch))
    }
    func run(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutResult {
        writes += 1
        if !plan.isReadOnly { mutationRequests += 1 }
        if !draining {
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters[plan.id] = $0 }
            } onCancel: { Task { await self.observeCancellation() } }
        }
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
    let storage: URL
    let root: URL
    let database: URL
    let project: WorkspaceProject
    let sourceID: UUID
    let coldID: UUID
    let peer: NativeCheckoutPeer
    let reads: PullRequestNativePeer
    let workspace: WorkspaceStore
    let model: PullRequestStore
    static func make(provider: NativeSetupProvider? = nil, reuseCheckout: Bool = false) async throws -> Self {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-checkout-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        let root = storage.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Original checkout bytes\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        let reads = try PullRequestNativePeer(root: root), peer = NativeCheckoutPeer(root: root, repository: reads.repository)
        let project = WorkspaceProject(path: root.path), database = storage.appendingPathComponent("workspace.sqlite")
        var source = CodingThread(project: project)
        source.provider = .claude; source.model = "native-checkout-model"; source.permission = .fullAccess
        source.providerThreadID = "Do not inherit this provider session"; source.checkpointPolicy = .disabled
        source.messages = [.init(role: .user, text: "Retain source history")]; source.draft = "Retain source draft"
        var cold = CodingThread(project: project); cold.workspacePath = storage.appendingPathComponent("Unrelated Cold").path; cold.isArchived = true
        if reuseCheckout {
            let reused = storage.appendingPathComponent("Worktrees").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: reused, withIntermediateDirectories: true)
            try Data("Original reused checkout bytes\n".utf8).write(to: reused.appendingPathComponent("tracked.txt"))
            cold.workspacePath = reused.path; cold.draft = "Retain the existing checkout owner's draft"
            await peer.reuse(reused)
        }
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [source, cold]
        if provider != nil {
            let agent = ACPAgentConfiguration(name: "Native independent checkout provider", executable: "/usr/bin/true")
            source.provider = .acp; source.acpAgent = agent; snapshot.acpAgents = [agent]; snapshot.threads = [source, cold]
        }
        try await WorkspaceDatabase(url: database).save(snapshot, event: "checkout.native.fixture")
        let workspace = try makeWorkspace(database: database, peer: peer, reads: reads, provider: provider)
        await workspace.load(); workspace.selectedThreadID = source.id
        let model = workspace.pullRequestStore(path: root.path); await model.refresh()
        return .init(storage: storage, root: root, database: database, project: project, sourceID: source.id, coldID: cold.id,
                     peer: peer, reads: reads, workspace: workspace, model: model)
    }
    static func makeWorkspace(database: URL, peer: NativeCheckoutPeer, reads: PullRequestNativePeer, provider: NativeSetupProvider? = nil) throws -> WorkspaceStore {
        // PR targets capture the legacy source's future Claude runtime. Keep
        // that read independent of any CLI or account installed on the host.
        let pointer = try #require(realpath(database.deletingLastPathComponent().path, nil))
        let fixtureRoot = URL(fileURLWithPath: String(cString: pointer)); free(pointer)
        let home = fixtureRoot.appendingPathComponent("PrivateClaudeHome", isDirectory: true)
        let configuration = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let launcher = fixtureRoot.appendingPathComponent("claude-never-executed")
        if !FileManager.default.fileExists(atPath: launcher.path) {
            try Data("#!/bin/sh\nexit 99\n".utf8).write(to: launcher, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        }
        let homePath = home.path, configurationPath = configuration.path, launcherPath = launcher.path
        let engine = try WorkspaceEngine(url: database,
            providerFactory: { _ in
                if let provider { return provider }
                throw CoincideError("Checkout must never send a prompt.")
            }, identityResolver: { _ in nil },
            pullRequestFactory: { _ in reads }, pullRequestCheckoutFactory: { NativeCheckoutSession(request: $0, peer: peer) })
        let workspace = WorkspaceStore(engine: engine, claudeRuntimeCapture: { registeredPath in
            let pointer = try #require(realpath(registeredPath, nil))
            let physicalPath = String(cString: pointer); free(pointer)
            let captured = ClaudeRuntimeConfiguration(executable: launcherPath, configurationDirectory: configurationPath,
                workspacePath: physicalPath, registeredWorkspacePath: registeredPath,
                configurationDirectorySelection: .defaultHome(homeDirectory: homePath))
            try captured.validate()
            return captured
        })
        workspace.pullRequestSessionFactory = { _ in reads }; return workspace
    }
    func review(mode: GitHubPullRequestCheckoutMode = .local, number: Int = 42) async throws -> PullRequestCheckoutReview {
        try await model.prepareCheckout(reference: .init(repository: reads.repository, number: number), mode: mode, reviewSetup: false)
    }
    func finish(reopened: WorkspaceStore? = nil) async {
        await reads.releaseContext(); await reads.releaseCreate(); await peer.drain()
        await reopened?.shutdown(); await workspace.shutdown()
        try? FileManager.default.removeItem(at: storage)
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
        #expect(f.workspace.isPullRequestCheckoutLocked(threadID: f.sourceID) == (mode == .local))
        #expect(!f.workspace.isPullRequestCheckoutLocked(threadID: f.coldID))
        #expect(f.workspace.canEditWorkspace(f.root.path) == (mode == .worktree))
        #expect(f.workspace.canOpenTerminal(for: source) == (mode == .worktree))
        #expect(f.workspace.workspaceReady(for: source) == (mode == .worktree))
        #expect(f.workspace.canPresentWorkspaceInspector(for: source))
        #expect(!f.workspace.canEditWorkspace(review.plan.destinationPath))
        if mode == .local { #expect(await f.workspace.submit("Keep this draft", threadID: f.sourceID).value == false) }
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
        #expect(!f.model.canPrepareCheckout(mode: .local) && f.model.canPrepareCheckout(mode: .worktree))
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
        #expect(!f.model.canPrepareCheckout(mode: .local) && f.model.canPrepareCheckout(mode: .worktree))
        await #expect(throws: WorkspaceCommandError.self) { try await f.review() }
        #expect(f.model.actionError?.contains("Close terminals") == true)
        #expect(await f.peer.writes == 0)
        await session.waitForClose()
        #expect(!session.view.process.running && !session.view.process.windingDown)
        try await waitForNativePullRequest { f.model.canPrepareCheckout(mode: .local) }
        #expect(kill(pid, 0) != 0)
        let review = try await f.review(); await f.model.discardCheckoutReview(review.id)
    } catch {
        terminals.closeAll(); await terminal?.waitForClose(); f.workspace.unregisterTerminals(terminals)
        await f.finish(); throw error
    }
    f.workspace.unregisterTerminals(terminals); await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePRCheckoutIndependentWorktreeKeepsSourceProviderEditorAndTerminalWorking() async throws {
    let provider = NativeSetupProvider(), f = try await NativeCheckoutFixture.make(provider: provider)
    let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    f.workspace.registerTerminals(terminals)
    var terminal: LocalTerminalSession?
    do {
        let original = try #require(f.workspace.thread(f.sourceID))
        #expect(await f.workspace.submit("Source provider keeps this turn", threadID: f.sourceID).value)
        try await waitForNativePullRequest { await provider.calls.count == 1 }
        let runID = try #require(f.workspace.thread(f.sourceID)?.activeRun?.id)
        let browser = try f.workspace.fileBrowser(path: f.root.path)
        #expect(await browser.open("tracked.txt")); browser.setContents("Source editor remains unsaved")
        let script = try ProjectScript(name: "Independent source terminal", command: "printf ready > source-terminal-ready; while :; do /bin/sleep 0.05; done")
        let session = try terminals.run(.init(script: script, projectRoot: f.root), for: original); terminal = session
        try await waitForNativePullRequest { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("source-terminal-ready").path) }
        #expect(f.model.canCheckout && f.model.canPrepareCheckout(mode: .worktree))
        #expect(!f.model.canPrepareCheckout(mode: .local))
        let review = try await f.review(mode: .worktree)
        try await f.model.checkout(review)
        try await waitForNativePullRequest { await f.peer.writes == 1 }
        #expect(f.workspace.thread(f.sourceID)?.activeRun?.id == runID)
        #expect(f.workspace.workspaceReady(for: try #require(f.workspace.thread(f.sourceID))))
        #expect(!f.workspace.isPullRequestCheckoutLocked(threadID: f.sourceID))
        #expect(browser.canWrite && browser.isDirty && browser.contents == "Source editor remains unsaved")
        #expect(kill(session.processID, 0) == 0 && terminals.sessions[f.sourceID]?.count == 1)
        browser.setContents("Source editor changed during independent checkout")
        f.workspace.setDraft("Source draft changed while PR worktree prepares", id: f.sourceID)
        await f.peer.release()
        try await waitForNativePullRequest { f.model.checkoutOperation?.phase == .completed }
        let target = try #require(f.workspace.thread(review.targetThreadID))
        #expect(target.messages.isEmpty && target.draft.isEmpty && target.providerThreadID == nil)
        #expect(target.workspacePath != f.root.path && target.workspacePath == review.plan.destinationPath)
        #expect(f.workspace.thread(f.sourceID)?.activeRun?.id == runID)
        #expect(f.workspace.thread(f.sourceID)?.messages.first == original.messages.first)
        #expect(f.workspace.thread(f.sourceID)?.draft == "Source draft changed while PR worktree prepares")
        #expect(browser.canWrite && browser.isDirty && browser.contents == "Source editor changed during independent checkout")
        let calls = await provider.calls
        #expect(kill(session.processID, 0) == 0 && calls.count == 1)
        #expect(try String(contentsOf: f.root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "Original checkout bytes\n")
        await provider.finish()
        try await waitForNativePullRequest { f.workspace.thread(f.sourceID)?.isBusy == false && f.workspace.thread(f.sourceID)?.heldPostRunCheckpoint == nil }
        try WorkspaceJournal.validate(f.workspace.snapshot)
    } catch {
        await provider.finish(); terminals.closeAll(); await terminal?.waitForClose(); f.workspace.unregisterTerminals(terminals)
        await f.finish(); throw error
    }
    terminals.closeAll(); await terminal?.waitForClose(); f.workspace.unregisterTerminals(terminals); await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePRCheckoutBusyRegisteredReuseInspectsWithoutPausingOrDiscardingItsEditor() async throws {
    let f = try await NativeCheckoutFixture.make(reuseCheckout: true)
    do {
        let owner = try #require(f.workspace.thread(f.coldID)), source = try #require(f.workspace.thread(f.sourceID))
        let browser = try f.workspace.fileBrowser(path: owner.workspacePath)
        #expect(await browser.open("tracked.txt")); browser.setContents("Keep the busy registered checkout's unsaved buffer")
        let review = try await f.review(mode: .worktree)
        #expect(review.plan.request.policy == .inspectOnly && review.plan.isReadOnly)
        #expect(await f.peer.preparedPolicies == [.refresh, .inspectOnly])
        #expect(review.plan.destinationPath == owner.workspacePath)
        try await f.model.checkout(review)
        try await waitForNativePullRequest { await f.peer.writes == 1 }
        #expect(f.model.checkoutOperation?.isWorking == true && f.model.checkoutOperation?.locksSource == false)
        #expect(f.workspace.canEditWorkspace(owner.workspacePath) && f.workspace.canEditWorkspace(source.workspacePath))
        #expect(!f.workspace.isPullRequestCheckoutLocked(threadID: owner.id))
        #expect(browser.canWrite && browser.isDirty)
        browser.setContents("Edit survives read-only PR checkout inspection")
        await f.peer.release()
        try await waitForNativePullRequest { f.model.checkoutOperation?.phase == .completed }
        #expect(await f.peer.mutationRequests == 0)
        #expect(browser.canWrite && browser.isDirty && browser.contents == "Edit survives read-only PR checkout inspection")
        #expect(try String(contentsOf: URL(fileURLWithPath: owner.workspacePath).appendingPathComponent("tracked.txt"), encoding: .utf8) == "Original reused checkout bytes\n")
        let target = try #require(f.workspace.thread(review.targetThreadID))
        #expect(target.workspacePath == owner.workspacePath && target.id != owner.id)
        #expect(target.messages.isEmpty && target.draft.isEmpty && target.providerThreadID == nil)
        #expect(f.workspace.thread(owner.id)?.draft == owner.draft && f.workspace.thread(source.id)?.draft == source.draft)
        try WorkspaceJournal.validate(f.workspace.snapshot)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePRCheckoutRetainsMultipleDisjointJobsAndTheirExactTargetsWithoutHoldingSource() async throws {
    let f = try await NativeCheckoutFixture.make()
    do {
        let source = try #require(f.workspace.thread(f.sourceID))
        let first = try await f.review(mode: .worktree)
        try await f.model.checkout(first)
        try await waitForNativePullRequest { await f.peer.writes == 1 }
        #expect(f.model.canPrepareCheckout(mode: .worktree))
        let second = try await f.review(mode: .worktree, number: 73)
        #expect(first.plan.destinationPath != second.plan.destinationPath && first.plan.requestedBranch != second.plan.requestedBranch)
        try await f.model.checkout(second)
        #expect(f.model.checkoutOperations.count == 2)
        #expect(f.workspace.snapshot.pullRequestCheckout(first.id)?.isWorking == true)
        #expect(f.workspace.snapshot.pullRequestCheckout(second.id)?.isWorking == true)
        #expect(f.workspace.canEditWorkspace(source.workspacePath))
        #expect(!f.workspace.canEditWorkspace(first.plan.destinationPath) && !f.workspace.canEditWorkspace(second.plan.destinationPath))
        #expect(!f.workspace.isPullRequestCheckoutLocked(threadID: source.id) && !f.workspace.isPullRequestCheckoutLocked(threadID: f.coldID))
        f.workspace.selectedThreadID = f.coldID
        f.workspace.setDraft("Latest source draft survives both background jobs", id: source.id)
        await f.peer.release(planID: first.plan.id)
        try await waitForNativePullRequest { f.workspace.snapshot.pullRequestCheckout(first.id)?.phase == .completed }
        try await waitForNativePullRequest { await f.peer.writes == 2 }
        await f.peer.release(planID: second.plan.id)
        try await waitForNativePullRequest { f.workspace.snapshot.pullRequestCheckout(second.id)?.phase == .completed }
        for review in [first, second] {
            let target = try #require(f.workspace.thread(review.targetThreadID))
            #expect(target.workspacePath == review.plan.destinationPath && target.pullRequestCheckoutOperationID == review.id)
            #expect(target.messages.isEmpty && target.draft.isEmpty && target.providerThreadID == nil)
        }
        #expect(f.workspace.selectedThreadID == f.coldID)
        #expect(f.workspace.thread(source.id)?.draft == "Latest source draft survives both background jobs")
        #expect(f.workspace.thread(source.id)?.messages == source.messages)
        #expect(await f.peer.writes == 2)
        f.model.openCheckoutConversation(operationID: first.id)
        #expect(f.workspace.selectedThreadID == first.targetThreadID,
                "Opening the older job must select its own confirmed target rather than the latest checkout.")
        try WorkspaceJournal.validate(f.workspace.snapshot)
    } catch { await f.finish(); throw error }
    await f.finish()
}
