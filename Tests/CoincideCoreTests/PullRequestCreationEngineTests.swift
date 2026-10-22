import Foundation
import Testing
@testable import CoincideCore

actor PullRequestCreationPeer: GitHubPullRequestSession {
    enum Mode: Sendable { case created, existing, rejected, uncertain }
    let seed: PullRequestCreationFixture
    private var mode: Mode = .created
    private var gate: RestoreEngineGate?
    private var readGate: RestoreEngineGate?
    private var reconciliation: GitHubPullRequestCreateReconciliation = .notFound
    private var probe: (@Sendable () async throws -> Void)?
    private(set) var calls: [UUID] = []
    private(set) var reconciliations = 0
    init(seed: PullRequestCreationFixture) { self.seed = seed }
    func configure(_ mode: Mode, gate: RestoreEngineGate? = nil, probe: (@Sendable () async throws -> Void)? = nil) {
        self.mode = mode; self.gate = gate; self.probe = probe
    }
    func setReconciliation(_ result: GitHubPullRequestCreateReconciliation) { reconciliation = result }
    func holdReads(_ value: RestoreEngineGate) { readGate = value }
    func context() throws -> GitHubPullRequestContext { try seed.review().context }
    func list(query: GitHubPullRequestListQuery) -> GitHubPullRequestPage { .init(items: [], truncated: false) }
    func detail(_ reference: GitHubPullRequestReference) throws -> GitHubPullRequestDetail { try seed.detail(seed.review()) }
    func resolve(_ reference: String) throws -> GitHubPullRequestDetail { try seed.detail(seed.review()) }
    func reviewCreate(title: String, body: String, baseBranch: String?, isDraft: Bool) async throws -> GitHubPullRequestCreateReview {
        if let readGate { await readGate.wait() }; try Task.checkCancellation()
        let original = try seed.review()
        return try .init(context: original.context, title: title, body: body, baseBranch: baseBranch ?? "main", baseCommit: original.baseCommit, isDraft: isDraft)
    }
    func create(_ review: GitHubPullRequestCreateReview) async throws -> GitHubPullRequestCreateOutcome {
        calls.append(review.id); try await probe?()
        if let gate { await gate.wait() }; try Task.checkCancellation()
        switch mode {
        case .created: return .created(try seed.detail(review))
        case .existing: return .openedExisting(try seed.detail(review))
        case .rejected: throw GitHubPullRequestError(.staleReview)
        case .uncertain: throw GitHubPullRequestError(.outcomeUncertain)
        }
    }
    func reconcileCreate(_ review: GitHubPullRequestCreateReview) -> GitHubPullRequestCreateReconciliation { reconciliations += 1; return reconciliation }
}

private struct PullRequestEngineFixture {
    let directory: URL
    let database: URL
    let seed: PullRequestCreationFixture
    let peer: PullRequestCreationPeer
    let engine: WorkspaceEngine
    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pr-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = directory.appendingPathComponent("workspace.sqlite")
        seed = PullRequestCreationFixture(path: directory.appendingPathComponent("checkout").path)
        peer = PullRequestCreationPeer(seed: seed)
        try await WorkspaceDatabase(url: database).save(seed.snapshot, event: "fixture")
        engine = try Self.make(database, peer: peer); _ = try await engine.load()
    }
    static func make(_ database: URL, peer: PullRequestCreationPeer) throws -> WorkspaceEngine {
        try .init(url: database, providerFactory: { _ in throw CoincideError("PR creation never sends provider input") }, identityResolver: { _ in nil }, pullRequestFactory: { _ in peer })
    }
    func review() async throws -> GitHubPullRequestCreateReview {
        try await engine.reviewPullRequestCreation(projectID: seed.projectID, workspacePath: seed.snapshot.projects[0].path,
            title: "Reviewed title", body: "Reviewed body", baseBranch: "main", isDraft: true)
    }
    func cleanup() async { await engine.shutdown(); try? FileManager.default.removeItem(at: directory) }
}

private func pullRequestEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("PR engine fixture did not reach the durable boundary") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func pullRequestCreationEngineCommitsDispatchBeforeOneExternalRequestAndPreservesDraft() async throws {
    let fixture = try await PullRequestEngineFixture(), gate = RestoreEngineGate()
    do {
        let review = try await fixture.review(), database = fixture.database
        await fixture.peer.configure(.created, gate: gate, probe: {
            let saved = try await WorkspaceDatabase(url: database).load()
            #expect(saved.pullRequestCreation(review.id)?.phase == .dispatching)
            #expect(try await WorkspaceDatabase(url: database).effects().count == 1)
        })
        async let first = fixture.engine.beginPullRequestCreation(projectID: fixture.seed.projectID, review: review)
        async let second = fixture.engine.beginPullRequestCreation(projectID: fixture.seed.projectID, review: review)
        let receipts = try await (first, second); #expect(receipts.0 == receipts.1)
        try await pullRequestEventually { await gate.entered }
        #expect(await fixture.peer.calls == [review.id])
        await fixture.engine.discardPullRequestCreationReview(reviewID: review.id)
        await #expect(throws: WorkspaceCommandError.self) {
            try await fixture.engine.dispatch(.submit(threadID: fixture.seed.threadID, text: "Blocked while GitHub held"))
        }
        let draft = try await fixture.engine.dispatch(.editThread(fixture.seed.threadID, .draft("Latest typing while GitHub held")))
        #expect(draft.rejection == nil)
        await gate.release()
        try await pullRequestEventually { await fixture.engine.current().snapshot.pullRequestCreation(review.id)?.phase == .created }
        let current = await fixture.engine.current().snapshot
        #expect(current.threads[0].draft == "Latest typing while GitHub held")
        #expect(!current.isPullRequestCreationLocked(path: review.context.workspacePath))
        #expect(current.pullRequestCreation(review.id)?.result != nil)
        _ = try await fixture.engine.beginPullRequestCreation(projectID: fixture.seed.projectID, review: review)
        #expect(await fixture.peer.calls == [review.id])
    } catch { await gate.release(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func pullRequestCreationEngineUncertainOutcomeSurvivesRestartAndOnlyReconcilesWithoutAnotherCreate() async throws {
    let fixture = try await PullRequestEngineFixture()
    do {
        await fixture.peer.configure(.uncertain)
        let review = try await fixture.review()
        _ = try await fixture.engine.beginPullRequestCreation(projectID: fixture.seed.projectID, review: review)
        do {
            try await pullRequestEventually { await fixture.engine.current().snapshot.pullRequestCreation(review.id)?.phase == .unconfirmed }
        } catch {
            let update = await fixture.engine.current()
            let operation = update.snapshot.pullRequestCreation(review.id)
            let effects = try await WorkspaceDatabase(url: fixture.database).effects()
            throw CoincideError("Uncertain PR did not settle: phase=\(String(describing: operation?.phase)), warning=\(String(describing: operation?.error)), engineError=\(String(describing: update.error)), calls=\(await fixture.peer.calls.count), effects=\(effects.map { $0.status.rawValue }). Original: \(error.localizedDescription)")
        }
        await fixture.engine.shutdown()
        let reopened = try PullRequestEngineFixture.make(fixture.database, peer: fixture.peer)
        do {
            _ = try await reopened.load()
            #expect(await fixture.peer.calls == [review.id])
            _ = try await reopened.reconcilePullRequestCreation(operationID: review.id)
            let unknown = await reopened.current().snapshot
            #expect(unknown.pullRequestCreation(review.id)?.phase == .unconfirmed)
            #expect(unknown.isPullRequestCreationLocked(path: review.context.workspacePath))
            await fixture.peer.setReconciliation(.found(try fixture.seed.detail(review)))
            _ = try await reopened.reconcilePullRequestCreation(operationID: review.id)
            let found = await reopened.current().snapshot
            #expect(found.pullRequestCreation(review.id)?.phase == .openedExisting)
            #expect(!found.isPullRequestCreationLocked(path: review.context.workspacePath))
            #expect(await fixture.peer.calls == [review.id]); #expect(await fixture.peer.reconciliations == 2)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func pullRequestCreationEngineFullReviewTokenRejectsCallerChangesAndDiscardWithoutWriting() async throws {
    let fixture = try await PullRequestEngineFixture()
    do {
        let review = try await fixture.review()
        let changed = try GitHubPullRequestCreateReview(id: review.id, reviewedAt: review.reviewedAt, context: review.context,
            title: "Changed after immutable review", body: review.body, baseBranch: review.baseBranch, baseCommit: review.baseCommit, isDraft: review.isDraft)
        await #expect(throws: (any Error).self) { try await fixture.engine.beginPullRequestCreation(projectID: fixture.seed.projectID, review: changed) }
        await fixture.engine.discardPullRequestCreationReview(reviewID: review.id)
        await #expect(throws: (any Error).self) { try await fixture.engine.beginPullRequestCreation(projectID: fixture.seed.projectID, review: review) }
        #expect(await fixture.peer.calls.isEmpty)
        #expect(await fixture.engine.current().snapshot.pullRequestCreations == nil)
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func pullRequestCreationEngineKnownPreflightFailureUnlocksWithoutClaimingRemoteSuccess() async throws {
    let fixture = try await PullRequestEngineFixture()
    do {
        await fixture.peer.configure(.rejected); let review = try await fixture.review()
        _ = try await fixture.engine.beginPullRequestCreation(projectID: fixture.seed.projectID, review: review)
        try await pullRequestEventually { await fixture.engine.current().snapshot.pullRequestCreation(review.id)?.phase == .failed }
        let saved = await fixture.engine.current().snapshot
        #expect(saved.pullRequestCreation(review.id)?.result == nil && !saved.isPullRequestCreationLocked(path: review.context.workspacePath))
        #expect(await fixture.peer.calls == [review.id])
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}
