import CSQLite
import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

actor PullRequestNativePeer: GitHubPullRequestSession {
    let root: URL
    let repository: GitHubRepository
    private(set) var creates = 0
    private(set) var inspections = 0
    private(set) var enteredCreate = false
    private(set) var enteredContext = false
    private var existing: GitHubPullRequestDetail?
    private var createWaiter: CheckedContinuation<Void, Never>?
    private var contextWaiter: CheckedContinuation<Void, Never>?
    private var holdContext = false
    private var loseCreateReply = false
    private var hideCreated = false
    private var currentBranch = "topic"
    init(root: URL) throws { self.root = root; repository = try .init(owner: "fixture", name: "native-pr") }
    func context() async throws -> GitHubPullRequestContext {
        let captured = try makeContext()
        if holdContext {
            holdContext = false; enteredContext = true
            await withCheckedContinuation { contextWaiter = $0 }
        }
        return captured
    }
    func configureContextGate() { holdContext = true; enteredContext = false }
    func setBranch(_ value: String) { currentBranch = value }
    func releaseContext() { contextWaiter?.resume(); contextWaiter = nil }
    func configureCreate(lostReply: Bool = false, hidden: Bool = false) { loseCreateReply = lostReply; hideCreated = hidden }
    func releaseCreate() { createWaiter?.resume(); createWaiter = nil }
    func makeContext() throws -> GitHubPullRequestContext {
        try .init(workspacePath: root.path, repository: repository, headRepository: repository,
            branch: currentBranch, headCommit: String(repeating: "a", count: 40),
            upstream: .init(remoteName: "origin", branch: currentBranch, commit: String(repeating: "a", count: 40)),
            defaultBranch: "main", baseBranches: ["main", "develop"], existingPullRequest: hideCreated ? nil : existing?.summary,
            readiness: .ready, sourceFingerprint: String(repeating: currentBranch == "topic" ? "b" : "c", count: 64))
    }
    func list(query: GitHubPullRequestListQuery) throws -> GitHubPullRequestPage {
        try query.validate(); return .init(items: hideCreated ? [] : existing.map { [$0.summary] } ?? [], truncated: false)
    }
    func detail(_ reference: GitHubPullRequestReference) throws -> GitHubPullRequestDetail {
        guard let existing, !hideCreated, existing.summary.reference == reference else { throw GitHubPullRequestError(.invalidResponse) }
        return existing
    }
    func resolve(_ reference: String) throws -> GitHubPullRequestDetail {
        guard let existing, !hideCreated else { throw GitHubPullRequestError(.invalidResponse) }; return existing
    }
    func reviewCreate(title: String, body: String, baseBranch: String?, isDraft: Bool) throws -> GitHubPullRequestCreateReview {
        try .init(context: makeContext(), title: title, body: body, baseBranch: baseBranch ?? "main",
            baseCommit: String(repeating: "d", count: 40), isDraft: isDraft)
    }
    func create(_ review: GitHubPullRequestCreateReview) async throws -> GitHubPullRequestCreateOutcome {
        creates += 1; enteredCreate = true
        await withCheckedContinuation { createWaiter = $0 }
        let reference = try GitHubPullRequestReference(repository: repository, number: 42)
        let summary = try GitHubPullRequestSummary(reference: reference, title: review.title,
            url: "https://github.com/fixture/native-pr/pull/42", state: .open, isDraft: review.isDraft,
            headBranch: review.context.upstream!.branch, baseBranch: review.baseBranch,
            headCommit: review.context.headCommit!, baseCommit: review.baseCommit, headRepository: repository, author: "fixture")
        let result = try GitHubPullRequestDetail(summary: summary, body: review.body, createdAt: Date())
        existing = result
        if loseCreateReply { throw GitHubPullRequestError(.outcomeUncertain) }
        return .created(result)
    }
    func reconcileCreate(_ review: GitHubPullRequestCreateReview) throws -> GitHubPullRequestCreateReconciliation {
        inspections += 1
        if let existing, !hideCreated { return .found(existing) }; return .notFound
    }
}

@MainActor struct PullRequestNativeFixture {
    let root: URL
    let database: URL
    let projectID: UUID
    let threadID: UUID
    let peer: PullRequestNativePeer
    let workspace: WorkspaceStore
    let model: PullRequestStore
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-pr-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("workspace.sqlite"), peer = try PullRequestNativePeer(root: root)
        let project = WorkspaceProject(path: root.path)
        var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled; thread.draft = "Retain this unsent draft"
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        try await WorkspaceDatabase(url: database).save(snapshot, event: "pull-request.native.fixture")
        let workspace = try makeWorkspace(database: database, peer: peer)
        await workspace.load()
        let model = workspace.pullRequestStore(path: root.path); await model.refresh()
        return .init(root: root, database: database, projectID: project.id, threadID: thread.id, peer: peer, workspace: workspace, model: model)
    }
    static func makeWorkspace(database: URL, peer: PullRequestNativePeer) throws -> WorkspaceStore {
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in throw CoincideError("This PR fixture must not send provider input.") },
            identityResolver: { _ in nil }, pullRequestFactory: { _ in peer })
        let workspace = WorkspaceStore(engine: engine); workspace.pullRequestSessionFactory = { _ in peer }
        return workspace
    }
    func review() async throws -> GitHubPullRequestCreateReview {
        try await model.prepareCreation(title: "Native pull request", body: "Preserve Markdown\n\n- Exact body\n", baseBranch: "main", isDraft: true)
    }
    func finish(reopened: WorkspaceStore? = nil) async {
        await peer.releaseContext(); await peer.releaseCreate()
        await reopened?.shutdown(); await workspace.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor func waitForNativePullRequest(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native PR fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePullRequestStoreOwnsAcceptanceAcrossWindowsAndRetainsDraftUntilTheExactResult() async throws {
    let f = try await PullRequestNativeFixture.make()
    var writer: OpaquePointer?, locked = false
    func unlock() { if locked { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); locked = false } }
    defer { unlock(); if let writer { sqlite3_close(writer) } }
    do {
        #expect(f.workspace.pullRequestStore(path: f.root.appendingPathComponent(".").path) === f.model)
        let review = try await f.review()
        #expect(sqlite3_open(f.database.path, &writer) == SQLITE_OK)
        sqlite3_busy_timeout(writer, 5_000)
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK); locked = true
        let accepted = Task { try await f.model.create(review) }
        try await waitForNativePullRequest { f.model.isAccepting }
        #expect(!f.workspace.canEditWorkspace(f.root.path))
        #expect(f.workspace.snapshot.pullRequestCreation(review.id) == nil)
        unlock(); try await accepted.value
        try await waitForNativePullRequest {
            let entered = await f.peer.enteredCreate
            return entered && f.model.operation?.phase == .dispatching
        }
        #expect(f.model.operation?.phase == .dispatching && !f.workspace.canEditWorkspace(f.root.path))
        f.workspace.setDraft("Typed during remote creation", id: f.threadID)
        #expect(await f.workspace.submit("Must remain held", threadID: f.threadID).value == false)
        await f.peer.releaseCreate()
        try await waitForNativePullRequest { f.model.operation?.phase == .created && f.model.detail?.summary.reference.number == 42 }
        #expect(f.model.detail?.body == review.body && f.model.detail?.summary.isDraft == true)
        #expect(f.workspace.thread(f.threadID)?.draft == "Typed during remote creation")
        #expect(f.workspace.canEditWorkspace(f.root.path))
        #expect(await f.peer.creates == 1)
        try WorkspaceJournal.validate(f.workspace.snapshot)
    } catch { unlock(); await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func nativePullRequestStoreUncertainCreationSurvivesRestartAndInspectionNeverCreatesAgain(notFound: Bool) async throws {
    let f = try await PullRequestNativeFixture.make()
    var reopened: WorkspaceStore?
    do {
        await f.peer.configureCreate(lostReply: true, hidden: notFound)
        let review = try await f.review(); try await f.model.create(review)
        try await waitForNativePullRequest { await f.peer.enteredCreate }; await f.peer.releaseCreate()
        try await waitForNativePullRequest { f.model.operation?.phase == .unconfirmed }
        #expect(!f.workspace.canEditWorkspace(f.root.path))
        await f.workspace.shutdown()
        let next = try PullRequestNativeFixture.makeWorkspace(database: f.database, peer: f.peer); reopened = next
        await next.load()
        let model = next.pullRequestStore(path: f.root.path); await model.refresh()
        #expect(model.operation?.phase == .unconfirmed && !model.canCreate)
        #expect(await f.peer.creates == 1)
        try await model.reconcileCreation()
        if notFound {
            #expect(model.operation?.phase == .unconfirmed && model.operation?.error == PullRequestCreationOperation.notFoundMessage)
            #expect(!next.canEditWorkspace(f.root.path))
            try await model.acknowledgeCreation()
            #expect(next.canEditWorkspace(f.root.path) && model.operation?.acknowledgedAt != nil)
        } else {
            try await waitForNativePullRequest { model.operation?.phase == .openedExisting && model.detail?.summary.reference.number == 42 }
            #expect(next.canEditWorkspace(f.root.path))
        }
        #expect(await f.peer.creates == 1)
        #expect(await f.peer.inspections == 1)
        #expect(next.thread(f.threadID)?.draft == "Retain this unsent draft")
        try WorkspaceJournal.validate(next.snapshot)
        await next.shutdown(); reopened = nil
    } catch { await f.finish(reopened: reopened); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePullRequestContextCannotBeReplacedByAnOlderCancelledRead() async throws {
    let f = try await PullRequestNativeFixture.make()
    do {
        await f.peer.configureContextGate()
        let old = Task { await f.model.refresh() }
        try await waitForNativePullRequest { await f.peer.enteredContext }
        await f.peer.setBranch("new-topic")
        await f.model.refresh()
        #expect(f.model.context?.branch == "new-topic")
        await f.peer.releaseContext(); await old.value
        #expect(f.model.context?.branch == "new-topic" && f.model.contextError == nil)
        #expect(await f.peer.creates == 0)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePullRequestShutdownDrainsAnOlderCancelledContextAfterItsReplacementFinishes() async throws {
    let f = try await PullRequestNativeFixture.make()
    var old: Task<Void, Never>?
    var shutdown: Task<Void, Never>?
    var shutdownFinished = false
    do {
        await f.peer.configureContextGate()
        old = Task { await f.model.refresh() }
        try await waitForNativePullRequest { await f.peer.enteredContext }
        await f.peer.setBranch("new-topic")
        await f.model.refresh()
        #expect(f.model.context?.branch == "new-topic" && !f.model.isLoading)

        shutdown = Task {
            await f.model.shutdown()
            shutdownFinished = true
        }
        try await waitForNativePullRequest { f.model.isBusy }
        await Task.yield()
        #expect(!shutdownFinished)

        await f.peer.releaseContext()
        await old?.value
        await shutdown?.value
        #expect(shutdownFinished)
        #expect(f.model.context?.branch == "new-topic" && f.model.contextError == nil)
        #expect(await f.peer.creates == 0)
    } catch {
        await f.peer.releaseContext()
        await old?.value
        await shutdown?.value
        await f.finish()
        throw error
    }
    await f.finish()
}
