import Foundation
import Testing
@testable import CoincideCore

actor PullRequestCheckoutEnginePeer {
    enum Mode: Sendable { case completed, uncertain, rejected, malformed }
    let seed: PullRequestCheckoutFixture
    private var mode = Mode.completed
    private var gate: RestoreEngineGate?
    private var probe: (@Sendable () async throws -> Void)?
    private var inspection = GitHubPullRequestCheckoutInspection.unconfirmed
    private var reuse = false
    private(set) var preparedPolicies: [GitHubPullRequestCheckoutPolicy] = []
    private(set) var writes: [UUID] = []
    private(set) var inspections = 0
    init(seed: PullRequestCheckoutFixture) { self.seed = seed }
    func configure(_ mode: Mode, gate: RestoreEngineGate? = nil, reuse: Bool = false, probe: (@Sendable () async throws -> Void)? = nil) { self.mode = mode; self.gate = gate; self.reuse = reuse; self.probe = probe }
    func setInspection(_ value: GitHubPullRequestCheckoutInspection) { inspection = value }
    func prepare(_ request: GitHubPullRequestCheckoutRequest) throws -> GitHubPullRequestCheckoutPlan {
        preparedPolicies.append(request.policy); return try seed.plan(request, reuse: reuse)
    }
    func run(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutResult {
        writes.append(plan.id); try await probe?()
        if let gate { await gate.wait() }; try Task.checkCancellation()
        switch mode {
        case .completed: return try seed.result(plan)
        case .uncertain: throw GitHubPullRequestCheckoutError(.commandFailed, mayHaveChanged: true)
        case .rejected: throw GitHubPullRequestCheckoutError(.staleReview)
        case .malformed: return .init(destinationPath: plan.destinationPath, branch: plan.requestedBranch,
            headCommit: String(repeating: "c", count: 40), isOnPullRequestHead: true, created: false, reused: false, moved: true)
        }
    }
    func inspect(_ plan: GitHubPullRequestCheckoutPlan) -> GitHubPullRequestCheckoutInspection { inspections += 1; return inspection }
}

struct PullRequestCheckoutEngineSession: GitHubPullRequestCheckoutSession {
    let request: GitHubPullRequestCheckoutRequest
    let peer: PullRequestCheckoutEnginePeer
    func prepare() async throws -> GitHubPullRequestCheckoutPlan { try await peer.prepare(request) }
    func run(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutResult { try await peer.run(plan) }
    func inspectCompletion(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutInspection { await peer.inspect(plan) }
}

private struct PullRequestCheckoutEngineFixture {
    let root: URL
    let database: URL
    let seed: PullRequestCheckoutFixture
    let peer: PullRequestCheckoutEnginePeer
    let engine: WorkspaceEngine
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-checkout-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = root.appendingPathComponent("workspace.sqlite")
        seed = PullRequestCheckoutFixture(path: root.appendingPathComponent("checkout").path); peer = PullRequestCheckoutEnginePeer(seed: seed)
        try await WorkspaceDatabase(url: database).save(seed.snapshot, event: "seed")
        engine = try Self.make(database, peer: peer); _ = try await engine.load()
    }
    static func make(_ database: URL, peer: PullRequestCheckoutEnginePeer) throws -> WorkspaceEngine {
        try .init(url: database, providerFactory: { _ in throw CoincideError("PR checkout never sends provider input") }, identityResolver: { _ in nil },
            pullRequestCheckoutFactory: { PullRequestCheckoutEngineSession(request: $0, peer: peer) })
    }
    func review() async throws -> PullRequestCheckoutReview {
        var configuration = ProviderConfiguration(thread: seed.snapshot.threads[0]); configuration.nativeThreadID = "Never inherit this provider session"
        return try await engine.reviewPullRequestCheckout(projectID: seed.projectID, workspacePath: seed.snapshot.projects[0].path,
            reference: seed.request().reference, mode: .local, configuration: configuration, checkpointPolicy: .disabled)
    }
    func cleanup() async { await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

private func checkoutEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("PR checkout did not reach its durable boundary") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func pullRequestCheckoutEngineCommitsDispatchBeforeOneWriteAndMaterializesOnlyObservedSuccess() async throws {
    let f = try await PullRequestCheckoutEngineFixture(), gate = RestoreEngineGate()
    do {
        let review = try await f.review(), database = f.database
        #expect(review.targetConfiguration.nativeThreadID == nil && review.targetConfiguration.workspacePath == review.plan.destinationPath)
        await f.peer.configure(.completed, gate: gate, probe: {
            let snapshot = try await WorkspaceDatabase(url: database).load()
            #expect(snapshot.pullRequestCheckout(review.id)?.phase == .dispatching)
            #expect(!snapshot.threads.contains { $0.id == review.targetThreadID })
            #expect(try await WorkspaceDatabase(url: database).effects().count == 1)
        })
        async let first = f.engine.beginPullRequestCheckout(review: review)
        async let second = f.engine.beginPullRequestCheckout(review: review)
        let receipts = try await (first, second); #expect(receipts.0 == receipts.1)
        try await checkoutEventually { await gate.entered }
        await f.engine.discardPullRequestCheckoutReview(reviewID: review.id)
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.dispatch(.submit(threadID: f.seed.threadID, text: "No implicit prompt")) }
        _ = try await f.engine.dispatch(.editThread(f.seed.threadID, .draft("Draft typed during checkout")))
        #expect(await f.engine.current().snapshot.threads.count == 1)
        await gate.release()
        try await checkoutEventually { await f.engine.current().snapshot.pullRequestCheckout(review.id)?.phase == .completed }
        let snapshot = await f.engine.current().snapshot, target = try #require(snapshot.threads.first { $0.id == review.targetThreadID })
        #expect(target.messages.isEmpty && target.queuedTurns.isEmpty && target.draft.isEmpty && target.providerThreadID == nil)
        #expect(target.provider == .claude && target.permission == .fullAccess && target.checkpointPolicy == .disabled)
        #expect(snapshot.threads.first { $0.id == f.seed.threadID }?.draft == "Draft typed during checkout")
        _ = try await f.engine.beginPullRequestCheckout(review: review)
        #expect(await f.peer.writes == [review.plan.id])
        #expect(try await WorkspaceDatabase(url: database).rebuildProjection().snapshot == snapshot)
    } catch { await gate.release(); await f.cleanup(); throw error }
    await f.cleanup()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func pullRequestCheckoutEngineRestartOnlyInspectsUnknownAndAcknowledgementCreatesNoConversation(found: Bool) async throws {
    let f = try await PullRequestCheckoutEngineFixture()
    do {
        await f.peer.configure(.uncertain); let review = try await f.review()
        _ = try await f.engine.beginPullRequestCheckout(review: review)
        try await checkoutEventually { await f.engine.current().snapshot.pullRequestCheckout(review.id)?.phase == .unconfirmed }
        await f.engine.shutdown()
        let reopened = try PullRequestCheckoutEngineFixture.make(f.database, peer: f.peer)
        do {
            _ = try await reopened.load()
            #expect(await f.peer.writes == [review.plan.id])
            if found { await f.peer.setInspection(.completed(try f.seed.result(review.plan))) }
            _ = try await reopened.inspectPullRequestCheckout(operationID: review.id)
            let snapshot = await reopened.current().snapshot
            if found {
                #expect(snapshot.pullRequestCheckout(review.id)?.phase == .completed)
                #expect(snapshot.threads.contains { $0.id == review.targetThreadID })
            } else {
                #expect(snapshot.pullRequestCheckout(review.id)?.phase == .unconfirmed && snapshot.threads.count == 1)
                _ = try await reopened.dispatch(.acknowledgePullRequestCheckout(operationID: review.id))
                let acknowledged = await reopened.current().snapshot
                #expect(acknowledged.threads.count == 1 && !acknowledged.isPullRequestCheckoutLocked(threadID: f.seed.threadID))
            }
            #expect(await f.peer.writes == [review.plan.id])
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func pullRequestCheckoutEngineReviewTokenRejectsTamperingAndKnownFailureDoesNotCreateTarget() async throws {
    let f = try await PullRequestCheckoutEngineFixture()
    do {
        let review = try await f.review()
        let changed = try PullRequestCheckoutReview(id: review.id, reviewedAt: review.reviewedAt, projectID: review.projectID,
            projectPath: review.projectPath, registeredWorkspacePath: review.registeredWorkspacePath, sourceIncarnation: review.sourceIncarnation,
            targetThreadID: review.targetThreadID, targetConfiguration: review.targetConfiguration, checkpointPolicy: review.checkpointPolicy,
            title: "Changed target settings", reviewSetup: review.reviewSetup, plan: review.plan)
        await #expect(throws: (any Error).self) { try await f.engine.beginPullRequestCheckout(review: changed) }
        await f.engine.discardPullRequestCheckoutReview(reviewID: review.id)
        await #expect(throws: (any Error).self) { try await f.engine.beginPullRequestCheckout(review: review) }
        #expect(await f.peer.writes.isEmpty)
        let valid = try await f.review(); await f.peer.configure(.rejected)
        _ = try await f.engine.beginPullRequestCheckout(review: valid)
        try await checkoutEventually { await f.engine.current().snapshot.pullRequestCheckout(valid.id)?.phase == .failed }
        let current = await f.engine.current().snapshot
        #expect(current.threads.count == 1 && !current.isPullRequestCheckoutLocked(threadID: f.seed.threadID))
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func pullRequestCheckoutEngineCancelDrainsAttemptAndKeepsPossibleMutationHeldUntilExplicitAcknowledgement() async throws {
    let f = try await PullRequestCheckoutEngineFixture(), gate = RestoreEngineGate()
    do {
        let review = try await f.review(); await f.peer.configure(.completed, gate: gate)
        _ = try await f.engine.beginPullRequestCheckout(review: review)
        try await checkoutEventually { await gate.entered }
        _ = try await f.engine.cancelPullRequestCheckout(operationID: review.id)
        #expect(await f.engine.current().snapshot.pullRequestCheckout(review.id)?.cancelRequested == true)
        await gate.release()
        try await checkoutEventually { await f.engine.current().snapshot.pullRequestCheckout(review.id)?.phase == .unconfirmed }
        let held = await f.engine.current().snapshot
        #expect(held.threads.count == 1 && held.isPullRequestCheckoutLocked(threadID: f.seed.threadID))
        _ = try await f.engine.dispatch(.acknowledgePullRequestCheckout(operationID: review.id))
        #expect(await f.engine.current().snapshot.threads.count == 1)
        #expect(await f.peer.writes == [review.plan.id])
    } catch { await gate.release(); await f.cleanup(); throw error }
    await f.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func pullRequestCheckoutEngineMalformedPostWriteResultRemainsUnconfirmedEvenWhenValidationErrorClaimsNoMutation() async throws {
    let f = try await PullRequestCheckoutEngineFixture()
    do {
        let review = try await f.review(); await f.peer.configure(.malformed)
        _ = try await f.engine.beginPullRequestCheckout(review: review)
        try await checkoutEventually { await f.engine.current().snapshot.pullRequestCheckout(review.id)?.phase == .unconfirmed }
        let current = await f.engine.current().snapshot
        #expect(current.threads.count == 1 && current.isPullRequestCheckoutLocked(threadID: f.seed.threadID))
        #expect(current.pullRequestCheckout(review.id)?.result == nil)
        #expect(await f.peer.writes == [review.plan.id])
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}
