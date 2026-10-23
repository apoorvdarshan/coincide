import Foundation
import Testing
@testable import CoincideCore

private struct RemotePullRequestCoreFixture {
    let root: URL, database: URL
    let seed: PullRequestCheckoutFixture
    let creation: PullRequestCreationPeer
    let checkout: PullRequestCheckoutEnginePeer
    let engine: WorkspaceEngine
    let workspace: RemoteWorkspaceService
    let service: RemotePullRequestService
    let target: RemoteWorkspaceTarget
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("coincide-remote-pr-core-\(UUID().uuidString)")
        var ownedEngine: WorkspaceEngine?
        do {
            let path = root.appendingPathComponent("Checkout")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            for name in ["Host", "Terminals"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let seed = PullRequestCheckoutFixture(path: path.path), creation = PullRequestCreationPeer(seed: seed.seed)
            let checkout = PullRequestCheckoutEnginePeer(seed: seed), database = root.appendingPathComponent("workspace.sqlite")
            try await WorkspaceDatabase(url: database).save(seed.snapshot, event: "fixture")
            let engine = try WorkspaceEngine(url: database,
                providerFactory: { _ in throw CoincideError("Remote PR tests never start a provider") }, identityResolver: { _ in nil },
                pullRequestFactory: { _ in creation }, pullRequestCheckoutFactory: { PullRequestCheckoutEngineSession(request: $0, peer: checkout) })
            ownedEngine = engine
            _ = try await engine.load()
            let environmentID = UUID(), workspace = try RemoteWorkspaceService(environmentID: environmentID, engine: engine, dataDirectory: root.appendingPathComponent("Host"))
            let target = try await workspace.bind(.init(environmentID: environmentID, projectID: seed.projectID, threadID: seed.threadID,
                configuration: .init(thread: seed.snapshot.threads[0])))
            let service = RemotePullRequestService(environmentID: environmentID, engine: engine, workspace: workspace)
            return .init(root: root, database: database, seed: seed, creation: creation, checkout: checkout, engine: engine,
                         workspace: workspace, service: service, target: target)
        } catch { await ownedEngine?.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func reviewCreation() async throws -> RemotePullRequestReview {
        try await service.review(.init(target: target, intent: .create(title: "Remote review", body: "Exact reviewed bytes", baseBranch: "main", isDraft: true)))
    }
    func request(_ action: RemotePullRequestAction) -> RemoteEnvironmentCommandRequest {
        .init(environmentID: target.environmentID, command: .pullRequest(target: target, action: action))
    }
    func perform(_ request: RemoteEnvironmentCommandRequest) async throws -> WorkspaceCommandReceipt {
        if let receipt = try await engine.remoteEnvironmentReceipt(request) { return receipt }
        let prepared = try await service.prepare(request.command)
        if case .pullRequest(let captured) = prepared { try await workspace.admitPullRequestScope(captured.scope) }
        let receipt = try await engine.dispatchRemoteEnvironment(request, preparation: prepared)
        if receipt.rejection == nil { await engine.awaitRemotePullRequestCancellation(prepared) }
        return receipt
    }
    func close() async { await service.close(); await workspace.close(); await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}
private func remotePullRequestEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The remote PR fixture did not reach its owned boundary") }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@Test(.timeLimit(.minutes(1)))
func remotePullRequestOriginalCommandOwnsOnlyReceiptAndUncertainRecoveryNeverCreatesAgain() async throws {
    let f = try await RemotePullRequestCoreFixture.make()
    do {
        await f.creation.configure(.uncertain)
        let reviewed = try await f.reviewCreation(), request = f.request(.begin(reviewID: reviewed.id, digest: reviewed.digest))
        let receipt = try await f.perform(request)
        #expect(receipt.commandID == request.id && request.id != reviewed.id && receipt.rejection == nil)
        try await remotePullRequestEventually { await f.engine.current().snapshot.pullRequestCreation(reviewed.id)?.phase == .unconfirmed }
        #expect(try await WorkspaceDatabase(url: f.database).receipt(reviewed.id) == nil)
        #expect(try await f.perform(request) == receipt)
        #expect(await f.creation.calls == [reviewed.id])
        let inspect = f.request(.inspectCreation(operationID: reviewed.id)), inspected = try await f.perform(inspect)
        #expect(inspected.commandID == inspect.id && inspected.rejection == nil)
        #expect(try await f.perform(inspect) == inspected)
        #expect(await f.creation.reconciliations == 1)
        let operation = try #require(await f.engine.current().snapshot.pullRequestCreation(reviewed.id))
        #expect(operation.phase == .unconfirmed && operation.error == PullRequestCreationOperation.notFoundMessage)
        let acknowledge = f.request(.acknowledgeCreation(operationID: reviewed.id))
        #expect(try await f.perform(acknowledge).rejection == nil)
        #expect(await f.engine.current().snapshot.pullRequestCreation(reviewed.id)?.acknowledgedAt != nil)
        #expect(await f.creation.calls == [reviewed.id])
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["configuration", "discard", "digest", "foreign-thread"])
func remotePullRequestPreparedHostReviewRefusesChangedAuthorityAtAtomicAdmission(change: String) async throws {
    let f = try await RemotePullRequestCoreFixture.make()
    do {
        let reviewed = try await f.reviewCreation(), request = f.request(.begin(reviewID: reviewed.id, digest: reviewed.digest))
        let prepared = try await f.service.prepare(request.command)
        var dispatched = request
        switch change {
        case "configuration": _ = try await f.engine.dispatch(.editThread(f.target.threadID, .model("Model changed after review")))
        case "discard": _ = try await f.service.discard(.init(target: f.target, reviewID: reviewed.id, digest: reviewed.digest))
        case "digest": dispatched = f.request(.begin(reviewID: reviewed.id, digest: String(repeating: "0", count: 64)))
        default:
            let other = RemoteWorkspaceTarget(environmentID: f.target.environmentID, projectID: f.target.projectID,
                threadID: UUID(), configuration: f.target.configuration, rootID: f.target.rootID)
            dispatched = .init(environmentID: f.target.environmentID, command: .pullRequest(target: other, action: .begin(reviewID: reviewed.id, digest: reviewed.digest)))
        }
        let receipt = try await f.engine.dispatchRemoteEnvironment(dispatched, preparation: prepared)
        #expect(receipt.rejection != nil)
        #expect(try await f.engine.remoteEnvironmentReceipt(dispatched) == receipt)
        #expect(await f.creation.calls.isEmpty)
        #expect(await f.engine.current().snapshot.pullRequestCreations?.isEmpty ?? true)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func remotePullRequestBrowserRejectsForeignRepositoryWithoutInvalidatingOwnedContext(resolve: Bool) async throws {
    let f = try await RemotePullRequestCoreFixture.make()
    do {
        let foreign = try GitHubPullRequestReference(repository: .init(owner: "other", name: "repository"), number: 31)
        let query: RemotePullRequestQuery = resolve ? .resolve(" \nhttps://github.com/other/repository/pull/31 ") : .detail(foreign)
        await #expect(throws: RemotePullRequestFailure(.invalidRequest)) { try await f.service.read(.init(target: f.target, query: query)) }
        let result = try await f.service.read(.init(target: f.target, query: .context))
        #expect(result.target == f.target)
        guard case .context(let context) = result.value else { throw CoincideError("Missing owned repository context") }
        #expect(context.repository.nameWithOwner == "acme/reviewed")
        #expect(await f.creation.calls.isEmpty)
        #expect(await f.checkout.writes.isEmpty)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remotePullRequestCheckoutCancelJoinsExactOwnedEffectAndCreatesNoConversation() async throws {
    let f = try await RemotePullRequestCoreFixture.make(), gate = RestoreEngineGate()
    do {
        await f.checkout.configure(.completed, gate: gate)
        let reference = try f.seed.request().reference
        let reviewed = try await f.service.review(.init(target: f.target, intent: .checkout(reference: reference, mode: .local, submodules: .none, title: nil)))
        guard case .checkout(let native) = reviewed.value else { throw CoincideError("Missing native checkout review") }
        #expect(!native.reviewSetup && native.targetConfiguration.nativeThreadID == nil)
        _ = try await f.perform(f.request(.begin(reviewID: reviewed.id, digest: reviewed.digest)))
        try await remotePullRequestEventually { await gate.entered }
        try FileManager.default.removeItem(atPath: f.target.workspacePath)
        let unbound = RemoteWorkspaceTarget(environmentID: f.target.environmentID, projectID: f.target.projectID,
            threadID: f.target.threadID, configuration: f.target.configuration)
        let cancel = RemoteEnvironmentCommandRequest(environmentID: f.target.environmentID,
            command: .pullRequest(target: unbound, action: .cancelCheckout(operationID: reviewed.id)))
        let task = Task { try await f.perform(cancel) }
        try await remotePullRequestEventually { await f.engine.current().snapshot.pullRequestCheckout(reviewed.id)?.cancelRequested == true }
        #expect(await f.engine.current().snapshot.threads.count == 1)
        await gate.release()
        let receipt = try await task.value
        #expect(receipt.commandID == cancel.id && receipt.rejection == nil)
        let operation = try #require(await f.engine.current().snapshot.pullRequestCheckout(reviewed.id))
        #expect(operation.phase == .unconfirmed && !operation.isWorking)
        #expect(await f.checkout.writes == [native.plan.id])
        #expect(try await f.perform(cancel) == receipt)
        #expect(await f.engine.current().snapshot.threads.count == 1)
    } catch { await gate.release(); await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remotePullRequestExplicitAcknowledgementReleasesUncertainHoldWithMissingRootAndNoNativeRead() async throws {
    let f = try await RemotePullRequestCoreFixture.make()
    do {
        await f.creation.configure(.uncertain)
        let reviewed = try await f.reviewCreation()
        _ = try await f.perform(f.request(.begin(reviewID: reviewed.id, digest: reviewed.digest)))
        try await remotePullRequestEventually { await f.engine.current().snapshot.pullRequestCreation(reviewed.id)?.phase == .unconfirmed }
        try FileManager.default.removeItem(atPath: f.target.workspacePath)
        let unbound = RemoteWorkspaceTarget(environmentID: f.target.environmentID, projectID: f.target.projectID,
            threadID: f.target.threadID, configuration: f.target.configuration)
        let request = RemoteEnvironmentCommandRequest(environmentID: f.target.environmentID,
            command: .pullRequest(target: unbound, action: .acknowledgeCreation(operationID: reviewed.id)))
        #expect(try await f.perform(request).rejection == nil)
        #expect(await f.engine.current().snapshot.pullRequestCreation(reviewed.id)?.acknowledgedAt != nil)
        #expect(await f.creation.calls == [reviewed.id])
        #expect(await f.creation.reconciliations == 0)
        await #expect(throws: RemotePullRequestFailure.self) {
            try await f.service.prepare(.pullRequest(target: unbound, action: .inspectCreation(operationID: reviewed.id)))
        }
    } catch { await f.close(); throw error }
    await f.close()
}

private actor RemotePullRequestPTY: RemotePTYDriver {
    nonisolated let events: AsyncStream<RemotePTYEvent>
    private let continuation: AsyncStream<RemotePTYEvent>.Continuation
    private let gate: RestoreEngineGate
    init(gate: RestoreEngineGate) { self.gate = gate; (events, continuation) = AsyncStream.makeStream() }
    func write(_ data: Data) throws {}
    func resize(cols: Int, rows: Int) throws {}
    func hasForegroundCommand() -> Bool { false }
    func close() async { await gate.wait(); continuation.yield(.exited(code: 0, signal: nil)); continuation.finish() }
}

@Test(.timeLimit(.minutes(1)))
func remotePullRequestNativeScopeRefusesLivePTYUntilOwnedCloseHasDrained() async throws {
    let f = try await RemotePullRequestCoreFixture.make(), gate = RestoreEngineGate()
    let driver = RemotePullRequestPTY(gate: gate)
    let terminal = try RemoteTerminalService(workspace: f.workspace, factory: { _ in driver }, dataDirectory: f.root.appendingPathComponent("Terminals"))
    do {
        let reviewed = try await f.reviewCreation(), prepared = try await f.service.prepare(f.request(.begin(reviewID: reviewed.id, digest: reviewed.digest)).command)
        guard case .pullRequest(let captured) = prepared else { throw CoincideError("Missing host scope") }
        let opened = try await terminal.open(.init(target: f.target))
        try await remotePullRequestEventually { try await terminal.attach(opened.reference).state == .running }
        await #expect(throws: RemoteWorkspaceFailure(.busy)) { try await f.workspace.admitPullRequestScope(captured.scope) }
        let close = Task { try await terminal.close(opened.reference) }
        try await remotePullRequestEventually { await gate.entered }
        await #expect(throws: RemoteWorkspaceFailure(.busy)) { try await f.workspace.admitPullRequestScope(captured.scope) }
        await gate.release(); _ = try await close.value
        try await f.workspace.admitPullRequestScope(captured.scope)
        #expect(await f.creation.calls.isEmpty)
    } catch { await gate.release(); await terminal.close(); await f.close(); throw error }
    await terminal.close(); await f.close()
}
