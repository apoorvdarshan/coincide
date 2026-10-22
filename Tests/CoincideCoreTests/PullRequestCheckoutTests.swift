import CSQLite
import Foundation
import Testing
@testable import CoincideCore

struct PullRequestCheckoutFixture: Sendable {
    var seed: PullRequestCreationFixture
    var snapshot: WorkspaceSnapshot
    var now: Date
    var projectID: UUID { seed.projectID }
    var threadID: UUID { seed.threadID }
    var incarnation: UUID { seed.incarnation }
    init(path: String = "/tmp/coincide-pr-checkout-fixture") {
        seed = PullRequestCreationFixture(path: path); snapshot = seed.snapshot; now = seed.now
        snapshot.threads[0].provider = .claude; snapshot.threads[0].permission = .fullAccess
        snapshot.threads[0].checkpointPolicy = .disabled
    }
    func request(mode: GitHubPullRequestCheckoutMode = .local, policy: GitHubPullRequestCheckoutPolicy = .refresh, number: Int = 31) throws -> GitHubPullRequestCheckoutRequest {
        .init(sourcePath: snapshot.projects[0].path, destinationRoot: snapshot.projects[0].path + "-managed",
              reference: try seed.detail(seed.review(), number: number).summary.reference, mode: mode, policy: policy)
    }
    func plan(_ request: GitHubPullRequestCheckoutRequest, reuse: Bool = false, unrelated: Bool = false, onHead: Bool = false) throws -> GitHubPullRequestCheckoutPlan {
        let node = GitWorktreeNodeIdentity(device: 1, inode: 11), common = GitWorktreeNodeIdentity(device: 1, inode: 12)
        let destination = request.mode == .local ? request.sourcePath : reuse ? request.sourcePath + "-registered" : request.destinationRoot + "/" + request.id.uuidString
        let proof = GitHubPullRequestCheckoutProof(sourceIdentity: node, repositoryIdentity: node,
            gitDirectoryPath: request.sourcePath + "/.git", gitDirectoryIdentity: common, commonDirectoryIdentity: common,
            sourceFingerprint: String(repeating: "e", count: 64), indexDigest: String(repeating: "d", count: 64),
            statusDigest: String(repeating: "f", count: 64), headCommit: String(repeating: "b", count: 40), branch: "main",
            destinationIdentity: reuse ? node : nil, destinationGitDirectoryPath: reuse ? request.sourcePath + "/.git/worktrees/reused" : nil,
            destinationGitDirectoryIdentity: reuse ? node : nil, destinationStatusDigest: reuse ? String(repeating: "f", count: 64) : nil,
            destinationHeadCommit: reuse ? String(repeating: onHead ? "a" : "c", count: 40) : nil, destinationBranch: reuse ? (unrelated ? "main" : "pr/\(request.reference.number)") : nil,
            destinationFingerprint: reuse ? String(repeating: "a", count: 64) : nil,
            destinationConfigurationDigest: reuse ? String(repeating: "b", count: 64) : nil)
        let summary = try seed.detail(seed.review(), number: request.reference.number).summary
        return try .init(request: request, sourcePath: request.sourcePath, repositoryPath: request.sourcePath,
            commonDirectoryPath: request.sourcePath + "/.git", destinationPath: destination, pullRequest: summary,
            requestedBranch: "pr/\(request.reference.number)", requestedHeadCommit: summary.headCommit,
            disposition: request.mode == .local ? .local : reuse ? (unrelated ? .reuseUnrelatedWorktree : .reuseWorktree) : .createWorktree,
            proof: proof, baseRemote: .init(name: "origin", url: "https://github.com/acme/reviewed.git", repository: summary.reference.repository, needsCreation: false),
            destinationParentIdentity: node)
    }
    func review(_ plan: GitHubPullRequestCheckoutPlan, targetID: UUID = UUID()) throws -> PullRequestCheckoutReview {
        var configuration = ProviderConfiguration(thread: snapshot.threads[0]); configuration.workspacePath = plan.destinationPath; configuration.nativeThreadID = nil
        return try .init(reviewedAt: now, projectID: projectID, projectPath: snapshot.projects[0].path,
            registeredWorkspacePath: snapshot.projects[0].path, sourceIncarnation: incarnation, targetThreadID: targetID,
            targetConfiguration: configuration, checkpointPolicy: .disabled, title: "Review PR #31", reviewSetup: true, plan: plan)
    }
    func result(_ plan: GitHubPullRequestCheckoutPlan, offHead: Bool = false, moved: Bool = true) throws -> GitHubPullRequestCheckoutResult {
        let branch = plan.isReadOnly ? plan.proof.destinationBranch! : offHead ? "main" : plan.requestedBranch
        let commit = plan.isReadOnly ? plan.proof.destinationHeadCommit! : offHead ? String(repeating: "c", count: 40) : plan.requestedHeadCommit
        let onHead = plan.disposition != .reuseUnrelatedWorktree && commit == plan.requestedHeadCommit
        if plan.request.mode == .local {
            return .init(destinationPath: plan.destinationPath, branch: branch, headCommit: commit,
                         isOnPullRequestHead: onHead, created: false, reused: false, moved: moved)
        }
        let created = plan.disposition == .createWorktree
        let childRequest = GitWorktreeRequest(id: plan.id, sourcePath: plan.repositoryPath, destinationRoot: plan.request.destinationRoot,
            selection: created ? .createBranch(name: branch, baseRef: commit) : .reuse(path: plan.destinationPath))
        let child = try GitWorktreePlan(request: childRequest, sourcePath: plan.repositoryPath, commonDirectoryPath: plan.commonDirectoryPath,
            sourceIdentity: plan.proof.repositoryIdentity, commonDirectoryIdentity: plan.proof.commonDirectoryIdentity,
            destinationParentIdentity: plan.destinationParentIdentity, branch: branch, baseCommit: commit,
            destinationIdentity: created ? nil : plan.proof.destinationIdentity,
            worktreeGitDirectoryPath: created ? nil : plan.proof.destinationGitDirectoryPath,
            worktreeGitDirectoryIdentity: created ? nil : plan.proof.destinationGitDirectoryIdentity)
        return .init(destinationPath: plan.destinationPath, branch: branch, headCommit: commit, isOnPullRequestHead: onHead,
            created: created, reused: !created, moved: plan.isReadOnly ? false : moved, warnings: onHead ? [] : [GitHubPullRequestCheckoutResult.offHeadWarning],
            worktreePlan: child, worktreeResult: .init(destinationPath: plan.destinationPath, headCommit: commit, branch: branch))
    }
    @discardableResult mutating func command(_ command: EngineCommand) throws -> WorkspaceDecision {
        now.addTimeInterval(1); let decision = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: now); snapshot = decision.snapshot; return decision
    }
    mutating func dispatch(_ operation: PullRequestCheckoutOperation) throws {
        try command(.pullRequestCheckoutDispatching(projectID: projectID, operationID: operation.id, incarnation: incarnation))
    }
    @discardableResult mutating func finish(_ operation: PullRequestCheckoutOperation, _ result: EffectResult) throws -> WorkspaceDecision {
        try command(.pullRequestCheckoutEffectResult(.pullRequestCheckout(projectID: projectID, operationID: operation.id, effectID: operation.effectID), result, incarnation: incarnation))
    }
}

@Test func pullRequestCheckoutAcceptanceReservesOnlyOneIntentAndNeverCreatesOrPromptsAThread() throws {
    var f = PullRequestCheckoutFixture(); let plan = try f.plan(f.request()), review = try f.review(plan), operation = PullRequestCheckoutOperation(review: review), original = f.snapshot
    let decision = try f.command(.pullRequestCheckoutAccepted(operation))
    #expect(f.snapshot.threads == original.threads && f.snapshot.projects == original.projects)
    #expect(decision.effects == [.init(id: operation.effectID, request: .pullRequestCheckout(projectID: f.projectID, operationID: operation.id, effectID: operation.effectID))])
    #expect(f.snapshot.isPullRequestCheckoutLocked(threadID: f.threadID))
    #expect(f.snapshot.isPullRequestCheckoutLocked(path: plan.commonDirectoryPath))
    #expect(!f.snapshot.providerReady(for: f.snapshot.threads[0]))
    try WorkspaceJournal.validate(f.snapshot)
}

@Test(arguments: ["local", "new", "movedReuse", "offHeadReuse", "unchangedReuse"])
func pullRequestCheckoutObservedResultAtomicallyCreatesBlankCapturedTargetAndOnlyNeededSetup(kind: String) throws {
    var f = PullRequestCheckoutFixture()
    let plan = try f.plan(f.request(mode: kind == "local" ? .local : .worktree), reuse: kind.contains("Reuse"), unrelated: kind == "offHeadReuse", onHead: kind == "unchangedReuse")
    let review = try f.review(plan), operation = PullRequestCheckoutOperation(review: review), original = f.snapshot.threads[0]
    try f.command(.pullRequestCheckoutAccepted(operation)); try f.dispatch(operation)
    try f.command(.client(.editThread(f.threadID, .draft("Typing after acceptance"))))
    let result = try f.result(plan, offHead: kind == "offHeadReuse", moved: ["new", "local", "movedReuse"].contains(kind))
    let decision = try f.finish(operation, .pullRequestCheckoutCompleted(result))
    let target = try #require(f.snapshot.threads.first { $0.id == review.targetThreadID })
    #expect(f.snapshot.pullRequestCheckout(operation.id)?.phase == .completed)
    #expect(target.pullRequestCheckoutOperationID == operation.id && target.workspacePath == result.destinationPath)
    #expect(target.provider == original.provider && target.model == original.model && target.permission == original.permission && target.checkpointPolicy == .disabled)
    #expect(target.messages.isEmpty && target.queuedTurns.isEmpty && target.draft.isEmpty && target.draftAttachments.isEmpty)
    #expect(target.providerThreadID == nil && target.runtimeID == nil && target.activeRun == nil && (target.runHistory ?? []).isEmpty)
    #expect(f.snapshot.threads.first { $0.id == f.threadID }?.draft == "Typing after acceptance")
    #expect(!f.snapshot.isPullRequestCheckoutLocked(threadID: f.threadID))
    #expect(decision.effects.count == (["new", "movedReuse"].contains(kind) ? 1 : 0))
    if ["new", "movedReuse"].contains(kind) { #expect(target.workspacePreparation?.setup?.phase == .discovering) }
    if kind == "offHeadReuse" { #expect(result.branch == "main" && !result.isOnPullRequestHead && result.warnings == [GitHubPullRequestCheckoutResult.offHeadWarning]) }
    try WorkspaceJournal.validate(f.snapshot)
    #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(f.snapshot)) == f.snapshot)
}

@Test(arguments: [false, true])
func pullRequestCheckoutRestartNeverReplaysAndUnknownAcknowledgementCreatesNoTarget(dispatched: Bool) throws {
    var f = PullRequestCheckoutFixture(); let operation = PullRequestCheckoutOperation(review: try f.review(f.plan(f.request())))
    try f.command(.pullRequestCheckoutAccepted(operation)); if dispatched { try f.dispatch(operation) }
    f.snapshot.recoverInterruptedWork(); let recovered = try #require(f.snapshot.pullRequestCheckout(operation.id))
    #expect(recovered.phase == (dispatched ? .unconfirmed : .failed))
    #expect(f.snapshot.threads.count == 1 && f.snapshot.threads[0].id == f.threadID)
    if dispatched {
        let inspected = try f.command(.pullRequestCheckoutInspected(operationID: operation.id, incarnation: UUID(), result: .unconfirmed))
        #expect(inspected.effects.isEmpty && f.snapshot.isPullRequestCheckoutLocked(threadID: f.threadID))
        let acknowledged = try f.command(.client(.acknowledgePullRequestCheckout(operationID: operation.id)))
        #expect(acknowledged.effects.isEmpty && !f.snapshot.isPullRequestCheckoutLocked(threadID: f.threadID))
        #expect(f.snapshot.pullRequestCheckout(operation.id)?.acknowledgedAt != nil && f.snapshot.threads.count == 1)
    }
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func pullRequestCheckoutInspectionCreatesExactlyOneTargetWithoutAnotherCheckoutAndRetainsReservedIDs() throws {
    var f = PullRequestCheckoutFixture(); let plan = try f.plan(f.request()), review = try f.review(plan), operation = PullRequestCheckoutOperation(review: review)
    try f.command(.pullRequestCheckoutAccepted(operation)); try f.dispatch(operation); try f.finish(operation, .pullRequestCheckoutUnconfirmed)
    let inspected = try f.command(.pullRequestCheckoutInspected(operationID: operation.id, incarnation: UUID(), result: .completed(try f.result(plan))))
    #expect(inspected.effects.isEmpty && f.snapshot.threads.filter { $0.id == review.targetThreadID }.count == 1)
    #expect(throws: WorkspaceCommandError.self) { try f.command(.pullRequestCheckoutInspected(operationID: operation.id, incarnation: UUID(), result: .completed(try f.result(plan)))) }
    var impostor = CodingThread(project: f.snapshot.projects[0]); impostor.id = operation.id
    #expect(throws: WorkspaceCommandError.self) { try f.command(.client(.createThread(impostor))) }
    try WorkspaceJournal.validate(f.snapshot)
}

@Test(arguments: ["submit", "edit", "newSibling", "newOverlap", "remove", "reservedTarget"])
func pullRequestCheckoutHoldsOnlyAffectedOwnersAndNewOverlappingWriters(action: String) throws {
    var f = PullRequestCheckoutFixture(); let plan = try f.plan(f.request()), review = try f.review(plan), operation = PullRequestCheckoutOperation(review: review)
    var sibling = CodingThread(project: f.snapshot.projects[0]); sibling.workspacePath = plan.destinationPath + "/nested"; sibling.isArchived = true; f.snapshot.threads.append(sibling)
    var unrelated = CodingThread(project: f.snapshot.projects[0]); unrelated.workspacePath += "-cold-sibling"; unrelated.isArchived = true; f.snapshot.threads.append(unrelated)
    try f.command(.pullRequestCheckoutAccepted(operation))
    #expect(f.snapshot.isPullRequestCheckoutLocked(threadID: sibling.id))
    #expect(!f.snapshot.isPullRequestCheckoutLocked(threadID: unrelated.id))
    let command: WorkspaceCommand
    switch action {
    case "submit": command = .submit(threadID: f.threadID, text: "Cannot send")
    case "edit": command = .editThread(sibling.id, .model("Cannot change"))
    case "newSibling": var thread = CodingThread(project: f.snapshot.projects[0]); thread.workspacePath = plan.destinationPath; command = .createThread(thread)
    case "newOverlap": command = .addProject(WorkspaceProject(path: plan.repositoryPath + "/nested"))
    case "remove": command = .removeProject(projectID: f.projectID, expectedThreadIDs: f.snapshot.threads.map(\.id))
    default: var thread = CodingThread(project: WorkspaceProject(path: "/tmp/unrelated")); thread.id = review.targetThreadID; command = .createThread(thread)
    }
    #expect(throws: WorkspaceCommandError.self) { try f.command(.client(command)) }
    try f.command(.client(.editThread(f.threadID, .draft("Still editable"))))
    #expect(f.snapshot.threads[0].draft == "Still editable")
}

@Test func pullRequestCheckoutMalformedCompletionCannotCreateTargetAndCancelKeepsDispatchUncertain() throws {
    var f = PullRequestCheckoutFixture(); let plan = try f.plan(f.request()), operation = PullRequestCheckoutOperation(review: try f.review(plan))
    try f.command(.pullRequestCheckoutAccepted(operation)); try f.dispatch(operation)
    try f.command(.pullRequestCheckoutCancel(operationID: operation.id))
    #expect(f.snapshot.pullRequestCheckout(operation.id)?.cancelRequested == true)
    let forged = GitHubPullRequestCheckoutResult(destinationPath: plan.destinationPath, branch: plan.requestedBranch,
        headCommit: String(repeating: "c", count: 40), isOnPullRequestHead: true, created: false, reused: false, moved: true)
    try f.finish(operation, .pullRequestCheckoutCompleted(forged))
    #expect(f.snapshot.pullRequestCheckout(operation.id)?.phase == .unconfirmed && f.snapshot.threads.count == 1)
    #expect(f.snapshot.pullRequestCheckout(operation.id)?.cancelRequested == false)
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func pullRequestCheckoutNewWorktreeAllowsSourceTurnsQueuesAndProviderEventsWhileOnlyDestinationIsHeld() throws {
    var f = PullRequestCheckoutFixture()
    try f.command(.client(.submit(threadID: f.threadID, text: "Source first turn")))
    try f.command(.client(.submit(threadID: f.threadID, text: "Source queued turn")))
    try f.command(.runtimeOpened(threadID: f.threadID, runID: try #require(f.snapshot.threads[0].activeRun?.id), runtimeID: UUID()))
    let source = f.snapshot.threads[0], runID = try #require(source.activeRun?.id)
    let operation = PullRequestCheckoutOperation(review: try f.review(f.plan(f.request(mode: .worktree))))
    let accepted = try f.command(.pullRequestCheckoutAccepted(operation))
    #expect(f.snapshot.threads[0] == source && accepted.closeRuntimes.isEmpty)
    #expect(!f.snapshot.isPullRequestCheckoutLocked(threadID: f.threadID))
    #expect(!f.snapshot.isPullRequestCheckoutLocked(path: operation.review.plan.repositoryPath))
    #expect(f.snapshot.isPullRequestCheckoutLocked(path: operation.review.plan.destinationPath))
    #expect(f.snapshot.isPullRequestCheckoutCoordinating(path: operation.review.plan.commonDirectoryPath))
    try f.command(.provider(threadID: f.threadID, runtimeID: try #require(source.runtimeID), event: .context(runID: runID, event: .message(.init(role: .assistant, text: "Source remains connected")))))
    #expect(f.snapshot.threads[0].messages.last?.text == "Source remains connected")
    try f.command(.client(.submit(threadID: f.threadID, text: "Another queued source turn")))
    #expect(f.snapshot.threads[0].queuedTurns.map(\.text) == ["Source queued turn", "Another queued source turn"])
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func pullRequestCheckoutUnknownReuseHoldsOnlyItsCheckoutAndKeepsSiblingWorkAvailable() throws {
    var f = PullRequestCheckoutFixture()
    let plan = try f.plan(f.request(mode: .worktree), reuse: true)
    var owner = CodingThread(project: f.snapshot.projects[0]); owner.workspacePath = plan.destinationPath
    f.snapshot.threads.append(owner)
    let operation = PullRequestCheckoutOperation(review: try f.review(plan))
    try f.command(.pullRequestCheckoutAccepted(operation)); try f.dispatch(operation); try f.finish(operation, .pullRequestCheckoutUnconfirmed)
    #expect(f.snapshot.isPullRequestCheckoutLocked(threadID: owner.id))
    #expect(!f.snapshot.isPullRequestCheckoutLocked(threadID: f.threadID))
    try f.command(.client(.submit(threadID: f.threadID, text: "Independent source keeps working")))
    #expect(throws: WorkspaceCommandError.self) { try f.command(.client(.submit(threadID: owner.id, text: "Held target"))) }
    try f.command(.client(.acknowledgePullRequestCheckout(operationID: operation.id)))
    #expect(!f.snapshot.isPullRequestCheckoutLocked(threadID: owner.id))
    #expect(!f.snapshot.threads.contains { $0.id == operation.targetThreadID })
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func pullRequestCheckoutDifferentTargetsShareGitCoordinationButSameBranchCannotBeAcceptedTwice() throws {
    var f = PullRequestCheckoutFixture()
    let first = PullRequestCheckoutOperation(review: try f.review(f.plan(f.request(mode: .worktree))))
    let second = PullRequestCheckoutOperation(review: try f.review(f.plan(f.request(mode: .worktree, number: 32))))
    try f.command(.pullRequestCheckoutAccepted(first)); try f.command(.pullRequestCheckoutAccepted(second))
    #expect(f.snapshot.pullRequestCheckouts?.count == 2)
    #expect(!f.snapshot.isPullRequestCheckoutLocked(threadID: f.threadID))
    let collision = PullRequestCheckoutOperation(review: try f.review(f.plan(f.request(mode: .worktree))))
    #expect(throws: WorkspaceCommandError.self) { try f.command(.pullRequestCheckoutAccepted(collision)) }
    try f.command(.client(.createThread(CodingThread(project: f.snapshot.projects[0]))))
    try WorkspaceJournal.validate(f.snapshot)
}

@Test(arguments: [false, true])
func pullRequestCheckoutReadOnlyReuseNeverHoldsFilesOrReplaysAfterRestart(dispatched: Bool) throws {
    var f = PullRequestCheckoutFixture()
    let plan = try f.plan(f.request(mode: .worktree, policy: .inspectOnly), reuse: true)
    var busy = CodingThread(project: f.snapshot.projects[0]); busy.workspacePath = plan.destinationPath
    f.snapshot.threads.append(busy)
    try f.command(.client(.submit(threadID: busy.id, text: "Busy reused worktree")))
    let operation = PullRequestCheckoutOperation(review: try f.review(plan)), source = f.snapshot.threads
    let accepted = try f.command(.pullRequestCheckoutAccepted(operation))
    #expect(f.snapshot.threads == source && accepted.closeRuntimes.isEmpty)
    #expect(operation.scopePaths.isEmpty && operation.coordinationPaths.isEmpty && !operation.locksSource && operation.retainsProject)
    #expect(!f.snapshot.isPullRequestCheckoutLocked(threadID: busy.id))
    #expect(throws: WorkspaceCommandError.self) { try f.command(.client(.removeProject(projectID: f.projectID, expectedThreadIDs: f.snapshot.threads.map(\.id)))) }
    if dispatched { try f.dispatch(operation) }
    f.snapshot.recoverInterruptedWork()
    #expect(f.snapshot.pullRequestCheckout(operation.id)?.phase == .failed)
    #expect(!f.snapshot.threads.contains { $0.id == operation.targetThreadID })
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func pullRequestCheckoutReadOnlyReuseCannotBypassAnotherUnknownCheckoutHold() throws {
    var f = PullRequestCheckoutFixture()
    let write = PullRequestCheckoutOperation(review: try f.review(f.plan(f.request(mode: .worktree), reuse: true)))
    try f.command(.pullRequestCheckoutAccepted(write)); try f.dispatch(write); try f.finish(write, .pullRequestCheckoutUnconfirmed)
    let observation = PullRequestCheckoutOperation(review: try f.review(f.plan(f.request(mode: .worktree, policy: .inspectOnly), reuse: true)))
    let before = f.snapshot
    #expect(throws: WorkspaceCommandError.self) { try f.command(.pullRequestCheckoutAccepted(observation)) }
    #expect(f.snapshot == before)
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func pullRequestCheckoutJournalOutboxRollBackTogetherAndRebuildWithoutReplaying() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-checkout-db-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: url)
    var f = PullRequestCheckoutFixture(path: root.appendingPathComponent("checkout").path)
    try await database.save(f.snapshot, event: "seed")
    let operation = PullRequestCheckoutOperation(review: try f.review(f.plan(f.request()))), before = try await database.revision()
    let decision = try f.command(.pullRequestCheckoutAccepted(operation))
    var raw: OpaquePointer?; #expect(sqlite3_open(url.path, &raw) == SQLITE_OK); defer { sqlite3_close(raw) }
    #expect(sqlite3_exec(raw, "CREATE TRIGGER reject_checkout_outbox BEFORE INSERT ON workspace_effects BEGIN SELECT RAISE(ABORT,'fixture rollback'); END;", nil, nil, nil) == SQLITE_OK)
    await #expect(throws: (any Error).self) { try await database.commit(decision.snapshot, event: "checkout", commandID: operation.id, effects: decision.effects) }
    let rolledBack = try await database.revision(), rolledBackEffects = try await database.effects()
    #expect(rolledBack == before && rolledBackEffects.isEmpty)
    #expect(sqlite3_exec(raw, "DROP TRIGGER reject_checkout_outbox", nil, nil, nil) == SQLITE_OK)
    let receipt = try await database.commit(decision.snapshot, event: "checkout", commandID: operation.id, effects: decision.effects)
    #expect(try await database.commit(decision.snapshot, event: "checkout", commandID: operation.id, effects: decision.effects) == receipt)
    #expect(try await database.effects().count == 1)
    #expect(try await database.rebuildProjection().snapshot == decision.snapshot)
    _ = try await database.cancelEffectsAfterProcessLoss(); var recovered = try await database.load(); recovered.recoverInterruptedWork()
    #expect(recovered.pullRequestCheckout(operation.id)?.phase == .failed && recovered.threads.count == 1)
    #expect(try await database.claimNextEffect(workerID: UUID()) == nil)
}
