import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private actor RemoteWorktreeBoundary {
    private var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        isWaiting = true; observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { continuation = $0 }
    }
    func entered() async { if !isWaiting { await withCheckedContinuation { observers.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class RemoteWorktreeFixture {
    let store = RemoteWorktreeStore()
    let environmentID = UUID()
    let sourceRootID = UUID()
    var thread: CodingThread
    var commands: [RemoteEnvironmentCommand] = []
    var accepted = true
    init() { thread = CodingThread(project: WorkspaceProject(path: "/remote-only/source checkout")) }
    var target: RemoteWorkspaceTarget { .init(environmentID: environmentID, projectID: thread.projectID,
        threadID: thread.id, configuration: .init(thread: thread)) }
    func catalog(attemptID: UUID? = nil) -> RemoteWorktreeCatalog {
        .init(target: target, sourcePath: "/remote-only/source checkout", sourceRootID: sourceRootID, attemptID: attemptID,
            branches: [.init(ref: "refs/heads/main", upstream: "origin/main"), .init(ref: "refs/heads/free", upstream: nil),
                .init(ref: "refs/heads/Caf\u{00e9}", upstream: nil), .init(ref: "refs/heads/Cafe\u{0301}", upstream: nil)],
            worktrees: [.init(path: "/remote-only/source checkout", headCommit: String(repeating: "a", count: 40), branch: "main", isBare: false, isDetached: false),
                .init(path: "/remote-only/Caf\u{00e9}", headCommit: String(repeating: "b", count: 40), branch: "Caf\u{00e9}", isBare: false, isDetached: false),
                .init(path: "/remote-only/Cafe\u{0301}", headCommit: String(repeating: "c", count: 40), branch: "Cafe\u{0301}", isBare: false, isDetached: false),
                .init(path: "/remote-only/prunable", headCommit: String(repeating: "a", count: 40), branch: "gone", isBare: false, isDetached: false, prunableReason: "missing")])
    }
    func update(loader: RemoteWorktreeStore.CatalogLoader? = nil, supported: Bool = true,
                canWrite: Bool = true, canChange: Bool = true, connected: Bool = true) {
        let inventory = catalog(attemptID: thread.workspacePreparation?.id)
        store.update(target: target, thread: thread, loader: loader ?? { _ in inventory }, connected: connected,
            supported: supported, canWrite: canWrite, canChangeWorkspace: canChange,
            perform: { [self] command in commands.append(command); return accepted })
    }
    func load() async throws { #expect(store.beginSetup()); await store.loadCatalog(); #expect(store.catalog != nil) }
    func preparation(phase: ThreadWorkspacePreparationPhase) throws -> ThreadWorkspacePreparation {
        let request = GitWorktreeRequest(sourcePath: "/remote-only/source checkout", destinationRoot: "/remote-only/managed",
            selection: .createBranch(name: "attempt", baseRef: "HEAD"))
        let identity = GitWorktreeNodeIdentity(device: 1, inode: 1)
        let plan = try GitWorktreePlan(request: request, sourcePath: request.sourcePath, commonDirectoryPath: request.sourcePath + "/.git",
            sourceIdentity: identity, commonDirectoryIdentity: identity, destinationParentIdentity: identity,
            branch: "attempt", baseCommit: String(repeating: "a", count: 40))
        var preparation = ThreadWorkspacePreparation(request: request); preparation.plan = plan; preparation.phase = phase
        return preparation
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteWorktreeInventoryDispatchesExactNativeSelectionsAndSubmodulesWithoutLocalResolution() async throws {
    let f = RemoteWorktreeFixture(); f.update(); try await f.load()
    #expect(f.store.localBranches.count == 4 && f.store.reusableWorktrees.count == 3)
    f.store.branchName = "new/topic"; f.store.baseRef = "refs/heads/free"; f.store.submodules = .recursive
    #expect(await f.store.prepare())
    guard case .prepareWorktree(let target, let sourceRoot, let attempt, let selection, let submodules) = try #require(f.commands.last) else {
        Issue.record("Expected a native worktree command"); return
    }
    #expect(target == f.target && sourceRoot == f.sourceRootID && attempt == nil)
    #expect(selection == .createBranch(name: "new/topic", baseRef: "refs/heads/free") && submodules == .recursive)
    f.store.mode = .existingBranch; f.store.existingBranch = Data("main".utf8)
    #expect(!f.store.canPrepare)
    f.store.existingBranch = Data("origin/free".utf8); #expect(!f.store.canPrepare)
    f.store.existingBranch = Data("free".utf8); #expect(await f.store.prepare())
    f.store.mode = .registeredWorktree; f.store.worktreePath = Data("/remote-only/Cafe\u{0301}".utf8)
    #expect(await f.store.prepare())
    guard case .prepareWorktree(_, _, _, .reuse(let path), let reuseSubmodules) = try #require(f.commands.last) else {
        Issue.record("Expected registered checkout reuse"); return
    }
    #expect(Data(path.utf8) == Data("/remote-only/Cafe\u{0301}".utf8) && reuseSubmodules == .none)
    #expect(f.commands.count == 3)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteWorktreeCatalogCompletionCannotRebindChangedConfigurationOrConnection() async throws {
    let f = RemoteWorktreeFixture(), boundary = RemoteWorktreeBoundary()
    let captured = f.catalog()
    f.update(loader: { _ in await boundary.pause(); return captured })
    #expect(f.store.beginSetup()); f.store.branchName = "retained branch draft"
    let task = Task { await f.store.loadCatalog() }; await boundary.entered()
    f.thread.model += "-changed"; f.update()
    await boundary.release(); await task.value
    #expect(f.store.catalog == nil && !f.store.setupIsCurrent && !f.store.canPrepare)
    #expect(f.store.branchName == "retained branch draft" && f.commands.isEmpty)
    try await f.load(); f.store.branchName = "safe"; #expect(f.store.canPrepare)
    f.store.disconnect(); #expect(!f.store.canPrepare)
    f.update(); #expect(!f.store.setupIsCurrent && f.commands.isEmpty)
    #expect(f.store.branchName == "safe")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteWorktreeRecoveryUsesMissingDestinationAndExactAttemptWithoutCatalogOrReplay() async throws {
    let f = RemoteWorktreeFixture()
    let preparation = try f.preparation(phase: .interrupted)
    f.thread.workspacePreparation = preparation; f.thread.workspacePath = preparation.destinationPath
    f.accepted = false; f.update(canChange: false)
    #expect(f.store.canInspect && !f.store.canRetry && !f.store.canChoose)
    await f.store.inspect()
    #expect(f.commands == [.inspectWorktree(target: f.target, attemptID: preparation.id)])
    f.update(); #expect(f.store.canChoose && f.store.canRetry)
    await f.store.retry()
    #expect(f.commands.last == .retryWorktree(target: f.target, attemptID: preparation.id))
    #expect(f.commands.count == 2 && f.store.catalog == nil)
    // A root-owned unresolved receipt blocks every subsequent command; no retry
    // is scheduled by the worktree presentation after a false result.
    f.update(canWrite: false); await f.store.retry(); await f.store.inspect()
    #expect(f.commands.count == 2 && !f.store.canChoose)
    f.update(); try await f.load(); f.store.branchName = "replacement"
    #expect(await f.store.prepare() == false)
    guard case .prepareWorktree(let target, let root, let attempt, _, _) = try #require(f.commands.last) else {
        Issue.record("Expected an explicit replacement selection"); return
    }
    #expect(target == f.target && root == f.sourceRootID && attempt == preparation.id)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteWorktreeRunningCancellationAndCapabilityEligibilityStaySeparateFromCheckoutWrites() async throws {
    let f = RemoteWorktreeFixture(); var preparation = try f.preparation(phase: .preparing)
    f.thread.workspacePreparation = preparation; f.thread.workspacePath = preparation.destinationPath
    f.update(canChange: false)
    #expect(f.store.canCancel && !f.store.canChoose && !f.store.canRetry)
    await f.store.cancel()
    #expect(f.commands == [.cancelWorktree(target: f.target, attemptID: preparation.id)])
    preparation.cancelRequested = true; f.thread.workspacePreparation = preparation; f.update()
    #expect(!f.store.canCancel)
    f.update(supported: false); #expect(!f.store.canCancel && !f.store.canInspect && !f.store.canChoose)
    #expect(f.store.eligibilityMessage?.contains("Update the helper") == true)
    f.update(connected: false); #expect(!f.store.canCancel)
    #expect(f.commands.count == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteWorktreeCatalogRejectsStaleAttemptAndPreservesExactUnicodeInventoryIdentity() async throws {
    let f = RemoteWorktreeFixture(); let valid = f.catalog()
    let invalid = RemoteWorktreeCatalog(target: valid.target, sourcePath: valid.sourcePath, sourceRootID: valid.sourceRootID,
        attemptID: UUID(), branches: valid.branches, worktrees: valid.worktrees)
    f.update(loader: { _ in invalid }); #expect(f.store.beginSetup()); await f.store.loadCatalog()
    #expect(f.store.catalog == nil && f.store.catalogError != nil && f.commands.isEmpty)
    f.update(); try await f.load(); f.store.mode = .registeredWorktree
    f.store.worktreePath = Data("/remote-only/Caf\u{00e9}".utf8)
    let composed = try #require(f.store.selection)
    f.store.worktreePath = Data("/remote-only/Cafe\u{0301}".utf8)
    guard case .reuse(let first) = composed, case .reuse(let second) = try #require(f.store.selection) else { Issue.record("Missing exact inventory paths"); return }
    #expect(Data(first.utf8) != Data(second.utf8))
    f.store.worktreePath = Data("/remote-only/prunable".utf8); #expect(f.store.selection == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteWorktreeSubmissionKeepsCapturedTargetAndSelectionWhileRootReconcilesReceipt() async throws {
    let f = RemoteWorktreeFixture(), boundary = RemoteWorktreeBoundary()
    let original = f.target, inventory = f.catalog()
    var sent: [RemoteEnvironmentCommand] = []
    f.store.update(target: original, thread: f.thread, loader: { _ in inventory }, connected: true,
        supported: true, canWrite: true, canChangeWorkspace: true,
        perform: { command in sent.append(command); await boundary.pause(); return false })
    try await f.load(); f.store.branchName = "captured"; f.store.baseRef = "refs/heads/free"; f.store.submodules = .topLevel
    let task = Task { await f.store.prepare() }; await boundary.entered()
    f.store.branchName = "newer text"; f.store.submodules = .recursive
    f.thread.workspacePath = "/remote-only/another workspace"; f.update(canWrite: false)
    #expect(f.store.isWorking && !f.store.canPrepare)
    await boundary.release(); #expect(await task.value == false)
    #expect(sent == [.prepareWorktree(target: original, sourceRootID: f.sourceRootID, expectedAttemptID: nil,
        selection: .createBranch(name: "captured", baseRef: "refs/heads/free"), submodules: .topLevel)])
    #expect(f.store.branchName == "newer text" && !f.store.setupIsCurrent && f.commands.isEmpty)
}
