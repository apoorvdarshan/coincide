import Foundation
import Testing
@testable import CoincideCore

private final class WorkspaceLifecycleProbe: @unchecked Sendable {
    private let lock = NSLock(); private var providers = 0, github = 0
    var counts: (Int, Int) { lock.withLock { (providers, github) } }
    func provider() throws -> any ProviderSession { lock.withLock { providers += 1 }; throw CoincideError("Lifecycle must never send a provider turn") }
    func pr(_ peer: WorkspaceLifecyclePRPeer) -> any GitHubPullRequestSession { lock.withLock { github += 1 }; return peer }
}
private actor WorkspaceLifecycleGate {
    private var entered = false, released = false
    private var waiters: [CheckedContinuation<Void, Never>] = [], held: CheckedContinuation<Void, Never>?
    func wait() async throws {
        entered = true; let waiters = waiters; self.waiters = []; for waiter in waiters { waiter.resume() }
        await withTaskCancellationHandler { if !released { await withCheckedContinuation { held = $0 } } }
            onCancel: { Task { await self.release() } }
        try Task.checkCancellation()
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; held?.resume(); held = nil }
}
private actor WorkspaceLifecyclePRPeer: GitHubPullRequestSession {
    let review: GitHubPullRequestCreateReview, state: String, gate: WorkspaceLifecycleGate?
    var calls = 0
    init(review: GitHubPullRequestCreateReview, state: String, gate: WorkspaceLifecycleGate? = nil) { self.review = review; self.state = state; self.gate = gate }
    func detail(_ reference: GitHubPullRequestReference) async throws -> GitHubPullRequestDetail {
        calls += 1; try await gate?.wait()
        if state == "read-failure" { throw GitHubPullRequestError(.unauthenticated) }
        let now = Date(), terminal = now.addingTimeInterval(-86_400)
        let summary = try GitHubPullRequestSummary(reference: reference, title: review.title,
            url: "https://github.com/acme/reviewed/pull/31", state: state == "open" ? .open : .merged,
            isDraft: review.isDraft, headBranch: review.context.upstream?.branch ?? "feature/pr", baseBranch: review.baseBranch,
            headCommit: review.context.headCommit!, baseCommit: review.baseCommit, headRepository: review.context.headRepository, updatedAt: now,
            closedAt: state == "open" ? nil : terminal, mergedAt: state == "open" ? nil : terminal)
        return try .init(summary: summary, body: review.body, createdAt: review.reviewedAt)
    }
    func context() throws -> GitHubPullRequestContext {
        let old = review.context, head = state == "changed-head" ? String(repeating: "c", count: 40) : old.headCommit!
        let branch = state == "changed-branch" ? "another-feature" : old.branch!
        let open: GitHubPullRequestSummary?
        if state == "new-open" {
            open = try .init(reference: .init(repository: old.repository, number: 32), title: "A newer open pull request",
                url: "https://github.com/acme/reviewed/pull/32", state: .open, headBranch: branch, baseBranch: old.defaultBranch,
                headCommit: head, baseCommit: review.baseCommit, headRepository: old.headRepository)
        } else { open = nil }
        return try .init(workspacePath: old.workspacePath, repositoryPath: old.repositoryPath, commonDirectoryPath: old.commonDirectoryPath,
            repository: old.repository, headRepository: old.headRepository, branch: branch, headCommit: head,
            upstream: .init(remoteName: "origin", branch: branch, commit: head), defaultBranch: old.defaultBranch, baseBranches: old.baseBranches,
            existingPullRequest: open, readiness: .ready, sourceFingerprint: old.sourceFingerprint)
    }
    func list(query: GitHubPullRequestListQuery) throws -> GitHubPullRequestPage { throw GitHubPullRequestError(.invalidRequest) }
    func resolve(_ reference: String) throws -> GitHubPullRequestDetail { throw GitHubPullRequestError(.invalidRequest) }
    func reviewCreate(title: String, body: String, baseBranch: String?, isDraft: Bool) -> GitHubPullRequestCreateReview { review }
    func create(_ review: GitHubPullRequestCreateReview) throws -> GitHubPullRequestCreateOutcome { throw GitHubPullRequestError(.invalidRequest) }
    func reconcileCreate(_ review: GitHubPullRequestCreateReview) throws -> GitHubPullRequestCreateReconciliation { throw GitHubPullRequestError(.invalidRequest) }
}
private struct WorkspaceLifecycleEngineFixture {
    let root: URL, database: URL, engine: WorkspaceEngine, threadID: UUID
    let probe: WorkspaceLifecycleProbe, peer: WorkspaceLifecyclePRPeer
    static func make(state: String = "unlinked-age", gate: WorkspaceLifecycleGate? = nil) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-lifecycle-engine-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let workspace = root.appendingPathComponent("Checkout"); try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var seed = PullRequestCreationFixture(path: workspace.path), now = Date()
        seed.now = now.addingTimeInterval(-4 * 86_400)
        seed.snapshot.threads[0].createdAt = now.addingTimeInterval(-10 * 86_400); seed.snapshot.threads[0].updatedAt = seed.now
        let review = try seed.review(), probe = WorkspaceLifecycleProbe(), peer = WorkspaceLifecyclePRPeer(review: review, state: state, gate: gate)
        if state != "unlinked-age" {
            let detail = try seed.detail(review)
            let operation = PullRequestCreationOperation(projectID: seed.projectID, projectPath: workspace.path, sourceIncarnation: seed.incarnation,
                review: review, phase: .created, result: .created(detail), sourceThreadID: state == "nil-source" ? nil : seed.threadID)
            seed.snapshot.pullRequestCreations = [operation]
            if state == "historical-then-current" {
                var past = seed; past.now = seed.now.addingTimeInterval(-86_400)
                let oldContext = try GitHubPullRequestContext(workspacePath: workspace.path, repository: review.context.repository,
                    headRepository: review.context.headRepository, branch: "feature/previous", headCommit: String(repeating: "c", count: 40),
                    upstream: .init(remoteName: "origin", branch: "feature/previous", commit: String(repeating: "c", count: 40)),
                    defaultBranch: "main", baseBranches: ["main"], readiness: .ready, sourceFingerprint: String(repeating: "d", count: 64))
                // Include an older review of the SAME reference as well as a
                // different historical PR: neither may replace the new link.
                let oldOperations = try [30, 31].map { number in
                    let oldReview = try GitHubPullRequestCreateReview(reviewedAt: past.now, context: oldContext, title: "Previous reviewed work",
                        body: "Preserved historical review", baseBranch: "main", baseCommit: review.baseCommit, isDraft: true)
                    return PullRequestCreationOperation(projectID: seed.projectID, projectPath: workspace.path, sourceIncarnation: seed.incarnation,
                        review: oldReview, phase: .created, result: .created(try past.detail(oldReview, number: number, headCommit: oldContext.headCommit)), sourceThreadID: seed.threadID)
                }
                seed.snapshot.pullRequestCreations = oldOperations + [operation]
            }
            seed.snapshot.workspaceLifecyclePolicy = .init(afterDays: nil)
        }
        let database = root.appendingPathComponent("workspace.sqlite")
        try await WorkspaceDatabase(url: database).save(seed.snapshot, event: "fixture")
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in try probe.provider() }, identityResolver: { _ in nil }, pullRequestFactory: { _ in probe.pr(peer) })
        do { _ = try await engine.load() } catch { await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
        return .init(root: root, database: database, engine: engine, threadID: seed.threadID, probe: probe, peer: peer)
    }
    func close() async { await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1))) func workspaceLifecycleEngineAgeSweepSettlesWithoutProviderInputOrSetupAndResumeRemainsExplicit() async throws {
    let f = try await WorkspaceLifecycleEngineFixture.make()
    do {
        await f.engine.sweepWorkspaceLifecycle()
        let settled = try #require(await f.engine.current().snapshot.threads.first)
        let generation = try #require(settled.settlement?.id)
        #expect(settled.draft == "Keep this unsent draft" && settled.settlement?.script == nil && settled.activeRun == nil && settled.runHistory == nil)
        #expect(settled.workspaceLifecycle?.settledOverride == .settled && f.probe.counts.0 == 0 && f.probe.counts.1 == 0)
        await f.engine.sweepWorkspaceLifecycle()
        #expect(await f.engine.current().snapshot.threads.first?.settlement?.id == generation)
        let updates = await f.engine.updates(), threadID = f.threadID
        let resumeFinished = Task {
            for await update in updates {
                if update.snapshot.threads.contains(where: { $0.id == threadID && $0.settlement == nil && $0.workspaceLifecycle?.settledOverride == .active }) { return true }
            }
            return false
        }
        defer { resumeFinished.cancel() }
        _ = try await f.engine.dispatch(.resumeThread(threadID: f.threadID, generationID: generation))
        #expect(await resumeFinished.value)
        let resumed = await f.engine.current().snapshot.threads.first
        #expect(resumed?.workspaceLifecycle?.settledOverride == .active && f.probe.counts.0 == 0)
        await f.engine.sweepWorkspaceLifecycle()
        #expect(await f.engine.current().snapshot.threads.first?.settlement == nil)
        let rebuilt = try await WorkspaceDatabase(url: f.database).rebuildProjection()
        #expect(rebuilt.snapshot.threads.first?.workspaceLifecycle?.settledOverride == .active)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["merged", "historical-then-current", "open", "new-open", "changed-branch", "changed-head", "read-failure", "nil-source"])
func workspaceLifecycleEnginePullRequestSweepRequiresExactFreshOwnedBranchHeadAndTerminalTime(state: String) async throws {
    let f = try await WorkspaceLifecycleEngineFixture.make(state: state)
    do {
        await f.engine.sweepWorkspaceLifecycle()
        let thread = try #require(await f.engine.current().snapshot.threads.first)
        #expect((thread.settlement != nil) == (state == "merged" || state == "historical-then-current"))
        #expect(thread.draft == "Keep this unsent draft" && thread.activeRun == nil && f.probe.counts.0 == 0)
        if state == "nil-source" { #expect(f.probe.counts.1 == 0) }
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["draft", "remove-recreate"])
func workspaceLifecycleEngineHeldFreshLookupDoesNotBlockDraftCommandsAndStaleProposalCannotSettle(change: String) async throws {
    let gate = WorkspaceLifecycleGate(), f = try await WorkspaceLifecycleEngineFixture.make(state: "merged", gate: gate)
    let sweep = Task { await f.engine.sweepWorkspaceLifecycle() }
    do {
        await gate.waitUntilEntered()
        if change == "draft" {
            _ = try await f.engine.dispatch(.editThread(f.threadID, .draft("Typed during the held lookup Ω")))
        } else {
            let original = await f.engine.current().snapshot
            let project = try #require(original.projects.first), thread = try #require(original.threads.first)
            _ = try await f.engine.dispatch(.removeProject(projectID: project.id, expectedThreadIDs: [thread.id]))
            _ = try await f.engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        }
        await gate.release(); await sweep.value
        let thread = try #require(await f.engine.current().snapshot.threads.first)
        #expect(thread.settlement == nil && f.probe.counts.0 == 0)
        if change == "draft" { #expect(thread.draft == "Typed during the held lookup Ω") }
    } catch { await gate.release(); await sweep.value; await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func workspaceLifecycleEngineRefusesCopiedAutomaticProposalAndInvalidSettingsWithoutLosingUsableState() async throws {
    let f = try await WorkspaceLifecycleEngineFixture.make()
    do {
        let before = await f.engine.current(), facts = try #require(try before.snapshot.workspaceLifecycleFacts(threadID: f.threadID))
        let copied = try #require(try WorkspaceLifecyclePolicyDecision.proposal(facts: facts, policy: .init(), now: Date()))
        await #expect(throws: WorkspaceCommandError.self) {
            _ = try await f.engine.dispatch(.workspaceLifecycle(.automaticallySettle(copied)), id: copied.id)
        }
        await #expect(throws: WorkspaceLifecycleError.invalidRequest) {
            _ = try await f.engine.dispatch(.setWorkspaceLifecyclePolicy(.init(afterDays: .nan)))
        }
        _ = try await f.engine.dispatch(.editThread(f.threadID, .draft("Still usable after known refusals")))
        let after = await f.engine.current()
        #expect(after.error == nil && after.snapshot.threads.first?.settlement == nil && f.probe.counts.0 == 0)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func workspaceLifecycleEngineShutdownCancelsAndJoinsItsHeldReadonlyPullRequestLookup() async throws {
    let gate = WorkspaceLifecycleGate(), f = try await WorkspaceLifecycleEngineFixture.make(state: "merged", gate: gate)
    let sweep = Task { await f.engine.sweepWorkspaceLifecycle() }
    await gate.waitUntilEntered()
    await f.engine.shutdown(); await sweep.value
    let persisted = try await WorkspaceDatabase(url: f.database).revision().snapshot
    #expect(persisted.threads.first?.settlement == nil && f.probe.counts.0 == 0)
    await f.close()
}
