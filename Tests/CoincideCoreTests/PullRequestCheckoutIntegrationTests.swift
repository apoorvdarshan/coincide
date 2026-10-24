import Foundation
import Testing
@testable import CoincideCore

private actor ProductionCheckoutBridgeProbe {
    let database: URL
    let lostReply: Bool
    private var canInspect = false
    private(set) var writes: [UUID] = []
    init(database: URL, lostReply: Bool) { self.database = database; self.lostReply = lostReply }
    func beforeWrite(_ plan: GitHubPullRequestCheckoutPlan) async throws {
        let saved = try await WorkspaceDatabase(url: database).load()
        let operation = try #require(saved.pullRequestCheckouts?.first { $0.review.plan == plan })
        #expect(operation.phase == .dispatching)
        #expect(!saved.threads.contains { $0.id == operation.targetThreadID })
        let effects = try await WorkspaceDatabase(url: database).effects()
        #expect(effects.count == 1 && effects[0].id == operation.effectID && effects[0].status == .running)
        writes.append(plan.id)
    }
    func enableInspection() { canInspect = true }
    var allowsInspection: Bool { canInspect || !lostReply }
}

private struct ProductionCheckoutBridgeSession: GitHubPullRequestCheckoutSession {
    let service: GitHubPullRequestCheckoutService
    let probe: ProductionCheckoutBridgeProbe
    func prepare() async throws -> GitHubPullRequestCheckoutPlan { try await service.prepare() }
    func run(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutResult {
        try await probe.beforeWrite(plan)
        let result = try await service.run(plan)
        if probe.lostReply { throw GitHubPullRequestCheckoutError(.commandFailed, mayHaveChanged: true) }
        return result
    }
    func inspectCompletion(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutInspection {
        guard await probe.allowsInspection else { return .unconfirmed }
        return try await service.inspectCompletion(plan)
    }
}

private final class CheckoutProviderStartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Test(.timeLimit(.minutes(2)), arguments: [GitHubPullRequestCheckoutMode.local, .worktree], [false, true])
func pullRequestCheckoutProductionServiceThroughEngineKeepsSQLiteIntentAndRecoversOnlyOwnedCompletion(mode: GitHubPullRequestCheckoutMode, lostReply: Bool) async throws {
    let f = try await PRCheckoutFixture.make()
    let database = f.api.git.root.appendingPathComponent("workspace.sqlite")
    let probe = ProductionCheckoutBridgeProbe(database: database, lostReply: lostReply), providers = CheckoutProviderStartCounter()
    var running: WorkspaceEngine?
    do {
        let project = WorkspaceProject(path: f.source.path)
        var source = CodingThread(project: project, model: "Captured native checkout model")
        source.provider = .claude; source.permission = .fullAccess; source.checkpointPolicy = .disabled
        source.providerThreadID = "Retained source provider identity"; source.draft = "Preserve this unsent source draft"
        let run = ActiveRun(id: UUID(), configuration: .init(thread: source), startedAt: Date(), nativeTurnID: "retained-native-turn")
        var record = ThreadRunRecord(run: run, origin: .user, userMessageID: "retained-user")
        record.status = .completed; record.endReason = .providerCompleted; record.endedAt = Date(); record.messageAttributionVersion = 1
        var message = ChatMessage(id: "retained-user", role: .user, text: "Keep this observed conversation history")
        message.runReference = .init(threadID: source.id, runID: run.id)
        source.messages = [message]; source.runHistory = [record]
        let original = source
        var seed = WorkspaceSnapshot(); seed.projects = [project]; seed.threads = [source]
        try await WorkspaceDatabase(url: database).save(seed, event: "checkout.production.fixture")
        let base = try GitHubRepository(owner: "upstream", name: "project"), head = try GitHubRepository(owner: "fork", name: "project")
        func makeEngine() throws -> WorkspaceEngine {
            try .init(url: database, providerFactory: { _ in providers.record(); throw CoincideError("Checkout cannot start a provider.") }, identityResolver: { _ in nil },
                pullRequestCheckoutFactory: { request in
                    let service = GitHubPullRequestCheckoutService(request: request, environment: f.environment,
                        gitExecutable: f.api.git.git, githubExecutable: f.api.executable,
                        transportOverrides: [base: f.baseRemote, head: f.headRemote])
                    return ProductionCheckoutBridgeSession(service: service, probe: probe)
                })
        }
        let first = try makeEngine(); running = first; _ = try await first.load()
        let before = try await f.api.git.state()
        let review = try await first.reviewPullRequestCheckout(projectID: project.id, workspacePath: project.path,
            reference: .init(repository: base, number: 42), mode: mode, configuration: .init(thread: source), checkpointPolicy: .disabled, reviewSetup: false)
        #expect(try await f.api.git.state() == before)
        #expect(review.targetConfiguration.nativeThreadID == nil)
        let accepted = try await first.beginPullRequestCheckout(review: review)
        #expect(try await first.beginPullRequestCheckout(review: review) == accepted)
        let deadline = ContinuousClock.now + .seconds(20)
        while await first.current().snapshot.pullRequestCheckout(review.id)?.isWorking == true {
            guard ContinuousClock.now < deadline else { throw CoincideError("The production checkout did not finish its durable operation.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let settled = await first.current().snapshot
        #expect(settled.pullRequestCheckout(review.id)?.phase == (lostReply ? .unconfirmed : .completed))
        #expect(settled.threads.first { $0.id == source.id } == original)
        if lostReply {
            #expect(settled.threads.count == 1)
            #expect(settled.isPullRequestCheckoutLocked(path: review.plan.destinationPath))
            #expect(settled.isPullRequestCheckoutLocked(threadID: source.id) == (mode == .local))
        }
        let destination = URL(fileURLWithPath: review.plan.destinationPath)
        #expect(try await f.git(["rev-parse", "HEAD"], at: destination) == f.api.head)
        #expect(try String(contentsOf: destination.appendingPathComponent("feature.txt"), encoding: .utf8) == "A committed feature\n")
        if mode == .worktree {
            let current = try await f.api.git.state()
            #expect(current.head == before.head && current.indexFiles == before.indexFiles && current.files == before.files)
        }
        await first.shutdown(); running = nil
        let callsBeforeInspection = try f.api.calls().count
        await probe.enableInspection()
        let reopened = try makeEngine(); running = reopened; _ = try await reopened.load()
        if lostReply {
            let recovered = await reopened.current().snapshot
            #expect(recovered.isPullRequestCheckoutLocked(path: review.plan.destinationPath))
            #expect(recovered.isPullRequestCheckoutLocked(threadID: source.id) == (mode == .local))
            _ = try await reopened.inspectPullRequestCheckout(operationID: review.id)
        }
        let final = await reopened.current().snapshot
        let completed = try #require(final.pullRequestCheckout(review.id)), target = try #require(final.threads.first { $0.id == review.targetThreadID })
        #expect(completed.phase == .completed && completed.result?.headCommit == f.api.head)
        #expect(target.messages.isEmpty && target.queuedTurns.isEmpty && target.draft.isEmpty && target.draftAttachments.isEmpty)
        #expect(target.providerThreadID == nil && target.provider == original.provider && target.model == original.model && target.permission == original.permission)
        #expect(target.pullRequestCheckoutOperationID == review.id && target.workspacePath == review.plan.destinationPath)
        #expect(final.threads.first { $0.id == original.id } == original)
        #expect(try f.api.calls().count == callsBeforeInspection, "Reopen and completion inspection must not contact GitHub.")
        #expect(await probe.writes == [review.plan.id])
        #expect(providers.count == 0)
        let persisted = try await WorkspaceDatabase(url: database).rebuildProjection()
        #expect(persisted.snapshot == final)
        #expect(try await WorkspaceDatabase(url: database).effects().filter { if case .providerStart = $0.request { true } else { false } }.isEmpty)
        await reopened.shutdown(); running = nil
    } catch {
        await running?.shutdown(); f.cleanup(); throw error
    }
    f.cleanup()
}
