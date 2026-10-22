import Foundation
import Testing
@testable import CoincideCore

private actor CheckoutConcurrentProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var prompts: [String] = []
    private(set) var closes = 0
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func models() -> [ProviderModel] { [.init(id: "fixture", name: "Fixture")] }
    func send(text: String, thread: CodingThread) {
        runID = thread.activeRun?.id; prompts.append(text)
        emit(.thread("native-" + thread.id.uuidString)); emit(.turn("turn-" + String(prompts.count)))
    }
    private func emit(_ value: ProviderEvent) {
        if let runID { continuation.yield(.context(runID: runID, event: value)) }
    }
    func finish(_ text: String) { emit(.message(.init(role: .assistant, text: text))); emit(.completed(.idle)) }
    func interrupt() { emit(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { closes += 1; continuation.finish() }
}

private final class CheckoutConcurrentProviders: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: CheckoutConcurrentProvider] = [:]
    func make(_ thread: CodingThread) -> any ProviderSession {
        lock.lock(); defer { lock.unlock() }
        if let value = values[thread.id] { return value }
        let value = CheckoutConcurrentProvider(); values[thread.id] = value; return value
    }
    func provider(_ id: UUID) -> CheckoutConcurrentProvider? { lock.lock(); defer { lock.unlock() }; return values[id] }
}

private struct CheckoutConcurrentFixture {
    let root: URL
    let database: URL
    let seed: PullRequestCheckoutFixture
    let targetOwnerID: UUID
    let peer: PullRequestCheckoutEnginePeer
    let providers: CheckoutConcurrentProviders
    let engine: WorkspaceEngine
    init(reuse: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-checkout-concurrency-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = root.appendingPathComponent("workspace.sqlite")
        var fixture = PullRequestCheckoutFixture(path: root.appendingPathComponent("checkout").path)
        var owner = CodingThread(project: fixture.snapshot.projects[0]); owner.workspacePath += "-registered"; owner.checkpointPolicy = .disabled
        targetOwnerID = owner.id; fixture.snapshot.threads.append(owner); seed = fixture
        peer = PullRequestCheckoutEnginePeer(seed: fixture); providers = CheckoutConcurrentProviders()
        await peer.configure(.completed, reuse: reuse)
        try await WorkspaceDatabase(url: database).save(fixture.snapshot, event: "seed")
        let peer = peer, providers = providers
        engine = try WorkspaceEngine(url: database, providerFactory: { providers.make($0) }, identityResolver: { _ in nil },
            pullRequestCheckoutFactory: { PullRequestCheckoutEngineSession(request: $0, peer: peer) })
        _ = try await engine.load()
    }
    func review(mode: GitHubPullRequestCheckoutMode = .worktree, busyPaths: [String] = []) async throws -> PullRequestCheckoutReview {
        try await engine.reviewPullRequestCheckout(projectID: seed.projectID, workspacePath: seed.snapshot.projects[0].path,
            reference: seed.request().reference, mode: mode, configuration: ProviderConfiguration(thread: seed.snapshot.threads[0]),
            checkpointPolicy: .disabled, busyWorktreePaths: busyPaths)
    }
    func cleanup() async { await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

private func checkoutConcurrentEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Concurrent checkout did not reach its durable boundary") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func pullRequestCheckoutNewWorktreeKeepsSourceRuntimeAndQueueAliveDuringDispatchAndUncertainty() async throws {
    let f = try await CheckoutConcurrentFixture(), gate = RestoreEngineGate()
    do {
        _ = try await f.engine.dispatch(.submit(threadID: f.seed.threadID, text: "Source first"))
        try await checkoutConcurrentEventually { await f.providers.provider(f.seed.threadID)?.prompts == ["Source first"] }
        let source = try #require(f.providers.provider(f.seed.threadID))
        _ = try await f.engine.dispatch(.submit(threadID: f.seed.threadID, text: "Source queued"))
        _ = try await f.engine.dispatch(.editThread(f.seed.threadID, .draft("Typed while source runs")))
        await f.peer.configure(.uncertain, gate: gate)
        let review = try await f.review()
        _ = try await f.engine.beginPullRequestCheckout(review: review)
        try await checkoutConcurrentEventually { await gate.entered }
        #expect(await source.closes == 0)
        await source.finish("Source first reply")
        try await checkoutConcurrentEventually { await source.prompts == ["Source first", "Source queued"] }
        await source.finish("Source queued reply")
        try await checkoutConcurrentEventually { await f.engine.current().snapshot.threads.first { $0.id == f.seed.threadID }?.activeRun == nil }
        #expect(await source.closes == 0)
        await gate.release()
        try await checkoutConcurrentEventually { await f.engine.current().snapshot.pullRequestCheckout(review.id)?.phase == .unconfirmed }
        let held = await f.engine.current().snapshot
        #expect(held.isPullRequestCheckoutLocked(path: review.plan.destinationPath))
        #expect(!held.isPullRequestCheckoutLocked(threadID: f.seed.threadID))
        #expect(held.threads.first { $0.id == f.seed.threadID }?.draft == "Typed while source runs")
        #expect(held.threads.first { $0.id == f.seed.threadID }?.runHistory?.map(\.status) == [.completed, .completed])
        _ = try await f.engine.dispatch(.submit(threadID: f.seed.threadID, text: "Source after unknown"))
        try await checkoutConcurrentEventually { await source.prompts.count == 3 }
        await source.finish("Source still connected")
        try await checkoutConcurrentEventually { await f.engine.current().snapshot.threads.first { $0.id == f.seed.threadID }?.activeRun == nil }
        let current = await f.engine.current().snapshot
        #expect(!current.threads.contains { $0.id == review.targetThreadID })
        #expect(await f.peer.writes == [review.plan.id])
        #expect(await source.closes == 0)
        #expect(try await WorkspaceDatabase(url: f.database).rebuildProjection().snapshot == current)
    } catch { await gate.release(); await f.cleanup(); throw error }
    await f.cleanup()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func pullRequestCheckoutBusyReuseObservesWithoutDrainingProviderOrSettingUp(editorHint: Bool) async throws {
    let f = try await CheckoutConcurrentFixture(reuse: true), gate = RestoreEngineGate()
    do {
        if !editorHint {
            _ = try await f.engine.dispatch(.submit(threadID: f.targetOwnerID, text: "Existing target work"))
            try await checkoutConcurrentEventually { await f.providers.provider(f.targetOwnerID)?.prompts.count == 1 }
        }
        let targetPath = f.seed.snapshot.threads[1].workspacePath
        let review = try await f.review(busyPaths: editorHint ? [targetPath + "/document.swift"] : [])
        #expect(review.plan.request.policy == .inspectOnly && review.plan.isReadOnly)
        #expect(await f.peer.preparedPolicies == [.refresh, .inspectOnly])
        await f.peer.configure(.completed, gate: gate, reuse: true)
        _ = try await f.engine.beginPullRequestCheckout(review: review)
        try await checkoutConcurrentEventually { await gate.entered }
        let pending = await f.engine.current().snapshot
        #expect(!pending.isPullRequestCheckoutLocked(threadID: f.targetOwnerID))
        if let provider = f.providers.provider(f.targetOwnerID) {
            #expect(await provider.closes == 0)
            await provider.finish("Existing owner completed while read was pending")
            try await checkoutConcurrentEventually { await f.engine.current().snapshot.threads.first { $0.id == f.targetOwnerID }?.activeRun == nil }
        }
        await gate.release()
        try await checkoutConcurrentEventually { await f.engine.current().snapshot.pullRequestCheckout(review.id)?.phase == .completed }
        let snapshot = await f.engine.current().snapshot, target = try #require(snapshot.threads.first { $0.id == review.targetThreadID })
        #expect(target.messages.isEmpty && target.queuedTurns.isEmpty && target.providerThreadID == nil)
        #expect(target.workspacePreparation?.setup == nil)
        #expect(snapshot.pullRequestCheckout(review.id)?.result?.moved == false)
        #expect(try await WorkspaceDatabase(url: f.database).effects().allSatisfy { if case .resolveProjectScript = $0.request { return false }; return true })
    } catch { await gate.release(); await f.cleanup(); throw error }
    await f.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func pullRequestCheckoutRefreshingReviewRejectsAnOwnerThatBecameBusyBeforeAcceptance() async throws {
    let f = try await CheckoutConcurrentFixture(reuse: true)
    do {
        let review = try await f.review()
        #expect(!review.plan.isReadOnly)
        _ = try await f.engine.dispatch(.submit(threadID: f.targetOwnerID, text: "Work began after review"))
        try await checkoutConcurrentEventually { await f.providers.provider(f.targetOwnerID)?.prompts.count == 1 }
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.beginPullRequestCheckout(review: review) }
        #expect(await f.peer.writes.isEmpty)
        #expect(await f.engine.current().snapshot.pullRequestCheckout(review.id) == nil)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func pullRequestCheckoutReadOnlyFailureCreatesNoTargetOrUnknownHoldEvenIfAdapterReportsPossibleChanges() async throws {
    let f = try await CheckoutConcurrentFixture(reuse: true)
    do {
        let review = try await f.review(busyPaths: [f.seed.snapshot.threads[1].workspacePath])
        await f.peer.configure(.uncertain, reuse: true)
        _ = try await f.engine.beginPullRequestCheckout(review: review)
        try await checkoutConcurrentEventually { await f.engine.current().snapshot.pullRequestCheckout(review.id)?.phase == .failed }
        let snapshot = await f.engine.current().snapshot
        #expect(!snapshot.threads.contains { $0.id == review.targetThreadID })
        #expect(!snapshot.isPullRequestCheckoutLocked(threadID: f.targetOwnerID))
        #expect(snapshot.pullRequestCheckout(review.id)?.retainsProject == false)
        #expect(await f.peer.inspections == 0)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}
