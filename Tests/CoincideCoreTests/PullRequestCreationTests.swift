import CSQLite
import Foundation
import Testing
@testable import CoincideCore

struct PullRequestCreationFixture: Sendable {
    var snapshot: WorkspaceSnapshot
    let projectID: UUID
    let threadID: UUID
    let incarnation = UUID()
    var now = Date(timeIntervalSince1970: 1_700_500_000)
    init(path: String = "/tmp/coincide-pr-create-checkout") {
        let project = WorkspaceProject(path: path), thread = CodingThread(project: project, model: "unchanged model")
        projectID = project.id; threadID = thread.id
        snapshot = .init(); snapshot.projects = [project]; snapshot.threads = [thread]
        snapshot.threads[0].draft = "Keep this unsent draft"
    }
    func review(id: UUID = UUID(), path: String? = nil) throws -> GitHubPullRequestCreateReview {
        let path = path ?? snapshot.projects[0].path
        let repo = try GitHubRepository(owner: "acme", name: "reviewed")
        let context = try GitHubPullRequestContext(workspacePath: path, repository: repo, headRepository: repo,
            branch: "feature/pr", headCommit: String(repeating: "a", count: 40),
            upstream: .init(remoteName: "origin", branch: "feature/pr", commit: String(repeating: "a", count: 40)),
            defaultBranch: "main", baseBranches: ["main"], readiness: .ready, sourceFingerprint: String(repeating: "e", count: 64))
        return try .init(id: id, reviewedAt: now, context: context, title: "Reviewed title", body: "Reviewed body\n\nChecks: fixture only",
                         baseBranch: "main", baseCommit: String(repeating: "b", count: 40), isDraft: true)
    }
    func operation(_ review: GitHubPullRequestCreateReview, effectID: UUID = UUID()) -> PullRequestCreationOperation {
        .init(projectID: projectID, projectPath: snapshot.projects[0].path, sourceIncarnation: incarnation, effectID: effectID, review: review)
    }
    func detail(_ review: GitHubPullRequestCreateReview, number: Int = 31, headCommit: String? = nil) throws -> GitHubPullRequestDetail {
        let reference = try GitHubPullRequestReference(repository: review.context.repository, number: number)
        let summary = try GitHubPullRequestSummary(reference: reference, title: review.title,
            url: "https://github.com/acme/reviewed/pull/\(number)", state: .open, isDraft: review.isDraft,
            headBranch: review.context.upstream?.branch ?? "feature/pr", baseBranch: review.baseBranch,
            headCommit: headCommit ?? String(repeating: "a", count: 40), baseCommit: review.baseCommit,
            headRepository: review.context.headRepository, updatedAt: now)
        return try .init(summary: summary, body: review.body, createdAt: now)
    }
    @discardableResult mutating func command(_ command: EngineCommand) throws -> WorkspaceDecision {
        now.addTimeInterval(1)
        let decision = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: now)
        snapshot = decision.snapshot; return decision
    }
    @discardableResult mutating func accept(_ operation: PullRequestCreationOperation) throws -> WorkspaceDecision { try command(.pullRequestCreationAccepted(operation)) }
    mutating func dispatch(_ operation: PullRequestCreationOperation) throws {
        try command(.pullRequestCreationDispatching(projectID: projectID, operationID: operation.id, incarnation: incarnation))
    }
    @discardableResult mutating func finish(_ operation: PullRequestCreationOperation, _ result: EffectResult) throws -> WorkspaceDecision {
        try command(.pullRequestCreationEffectResult(.pullRequestCreation(projectID: projectID, operationID: operation.id, effectID: operation.effectID), result, incarnation: incarnation))
    }
}

@Test func pullRequestCreationAcceptanceReservesOneIntentAndDistinctOutboxWithoutChangingConversation() throws {
    var fixture = PullRequestCreationFixture(); let review = try fixture.review(), operation = fixture.operation(review), source = fixture.snapshot
    let decision = try fixture.accept(operation)
    #expect(decision.effects == [.init(id: operation.effectID, request: .pullRequestCreation(projectID: fixture.projectID, operationID: operation.id, effectID: operation.effectID))])
    #expect(operation.effectID != operation.id && fixture.snapshot.pullRequestCreation(operation.id) == operation)
    #expect(fixture.snapshot.threads == source.threads && fixture.snapshot.projects == source.projects)
    #expect(fixture.snapshot.isPullRequestCreationLocked(threadID: fixture.threadID))
    #expect(fixture.snapshot.isPullRequestCreationLocked(path: review.context.repositoryPath + "/child"))
    #expect(fixture.snapshot.isPullRequestCreationLocked(path: review.context.commonDirectoryPath))
    #expect(!fixture.snapshot.providerReady(for: fixture.snapshot.threads[0]))
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test(arguments: ["created", "existing", "failed", "unconfirmed", "foreignHead"])
func pullRequestCreationOutcomesAreExactAndNeverRewriteDrafts(outcome: String) throws {
    var fixture = PullRequestCreationFixture(); let review = try fixture.review(), operation = fixture.operation(review)
    try fixture.accept(operation); try fixture.dispatch(operation)
    try fixture.command(.client(.editThread(fixture.threadID, .draft("Typed after acceptance"))))
    let result: EffectResult
    switch outcome {
    case "created": result = .pullRequestCreationConfirmed(.created(try fixture.detail(review)))
    case "existing": result = .pullRequestCreationConfirmed(.openedExisting(try fixture.detail(review)))
    case "failed": result = .failed("Never retain private stderr")
    case "foreignHead": result = .pullRequestCreationConfirmed(.created(try fixture.detail(review, headCommit: String(repeating: "c", count: 40))))
    default: result = .pullRequestCreationUnconfirmed
    }
    let finished = try fixture.finish(operation, result), saved = try #require(fixture.snapshot.pullRequestCreation(operation.id))
    #expect(finished.effects.isEmpty && fixture.snapshot.threads[0].draft == "Typed after acceptance")
    #expect(saved.phase == (outcome == "created" ? .created : outcome == "existing" ? .openedExisting : outcome == "failed" ? .failed : .unconfirmed))
    #expect(saved.locksSource == (outcome == "unconfirmed" || outcome == "foreignHead"))
    let final = fixture.snapshot
    try fixture.finish(operation, .pullRequestCreationUnconfirmed)
    #expect(fixture.snapshot == final)
}

@Test(arguments: ["found", "notFound", "acknowledge"])
func pullRequestCreationReconciliationIsReadOnlyAndNotFoundRetainsTheHold(outcome: String) throws {
    var fixture = PullRequestCreationFixture(); let review = try fixture.review(), operation = fixture.operation(review)
    try fixture.accept(operation); try fixture.dispatch(operation); try fixture.finish(operation, .pullRequestCreationUnconfirmed)
    let source = fixture.snapshot.threads
    let decision: WorkspaceDecision
    if outcome == "acknowledge" { decision = try fixture.command(.client(.acknowledgePullRequestCreation(operationID: operation.id))) }
    else { decision = try fixture.command(.pullRequestCreationReconciled(operationID: operation.id, incarnation: UUID(), result: outcome == "found" ? .found(fixture.detail(review)) : .notFound)) }
    #expect(decision.effects.isEmpty && fixture.snapshot.threads == source)
    let saved = try #require(fixture.snapshot.pullRequestCreation(operation.id))
    #expect(saved.locksSource == (outcome == "notFound"))
    if outcome == "notFound" { #expect(saved.phase == .unconfirmed && saved.error == PullRequestCreationOperation.notFoundMessage) }
    if outcome == "acknowledge" { #expect(saved.phase == .unconfirmed && saved.acknowledgedAt != nil && saved.result == nil) }
    if outcome == "found" { #expect(saved.phase == .openedExisting && saved.result != nil) }
}

@Test(arguments: [false, true])
func pullRequestCreationRestartNeverReplaysAcceptedOrDispatchingWork(dispatched: Bool) throws {
    var fixture = PullRequestCreationFixture(); let operation = fixture.operation(try fixture.review())
    try fixture.accept(operation); if dispatched { try fixture.dispatch(operation) }
    let source = fixture.snapshot.threads
    fixture.snapshot.recoverInterruptedWork()
    let saved = try #require(fixture.snapshot.pullRequestCreation(operation.id))
    #expect(saved.phase == (dispatched ? .unconfirmed : .failed))
    #expect(saved.locksSource == dispatched && !saved.isWorking && fixture.snapshot.threads == source)
    try WorkspaceJournal.validate(fixture.snapshot)
    let roundTrip = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(fixture.snapshot))
    #expect(roundTrip == fixture.snapshot)
}

@Test(arguments: ["submit", "archive", "workspace", "remove", "newOwner", "reserved", "project"])
func pullRequestCreationHoldsEveryWriterAndNewOverlappingOwner(action: String) throws {
    var fixture = PullRequestCreationFixture(); let operation = fixture.operation(try fixture.review())
    try fixture.accept(operation)
    let command: WorkspaceCommand
    switch action {
    case "submit": command = .submit(threadID: fixture.threadID, text: "Blocked")
    case "archive": command = .editThread(fixture.threadID, .archived(true))
    case "workspace": command = .editThread(fixture.threadID, .workspacePath("/tmp/coincide-pr-other"))
    case "remove": command = .removeProject(projectID: fixture.projectID, expectedThreadIDs: [fixture.threadID])
    case "project": command = .addProject(.init(path: operation.workspacePath + "/nested"))
    default:
        var other = CodingThread(project: fixture.snapshot.projects[0]); other.workspacePath = action == "reserved" ? "/tmp/coincide-pr-unrelated" : operation.workspacePath + "/nested"
        if action == "reserved" { other.id = operation.effectID }; command = .createThread(other)
    }
    let before = fixture.snapshot
    #expect(throws: WorkspaceCommandError.self) { try fixture.command(.client(command)) }
    #expect(fixture.snapshot == before)
    try fixture.command(.client(.editThread(fixture.threadID, .draft("Allowed draft"))))
    #expect(fixture.snapshot.threads[0].draft == "Allowed draft")
}

@Test func pullRequestCreationLedgerRejectsDuplicateIdentityAndLostRegistration() throws {
    var fixture = PullRequestCreationFixture(); let operation = fixture.operation(try fixture.review()); try fixture.accept(operation)
    var duplicate = fixture.snapshot; duplicate.pullRequestCreations?.append(operation)
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(duplicate) }
    var lost = fixture.snapshot; lost.projects[0].path += "-moved"
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(lost) }
    var reserved = fixture.snapshot; reserved.threads[0].id = operation.effectID
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(reserved) }
}

@Test func pullRequestCreationIntentAndEffectRollbackTogetherAndProjectionReplaysWithoutWriting() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pr-create-sql-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: url)
    var fixture = PullRequestCreationFixture(); let initial = fixture.snapshot, operation = fixture.operation(try fixture.review())
    try await database.save(initial, event: "fixture")
    let accepted = try fixture.accept(operation), commandID = UUID()
    try pullRequestCreationSQL(url, "CREATE TRIGGER fail_pr BEFORE INSERT ON workspace_effects BEGIN SELECT RAISE(ABORT,'fixture'); END")
    await #expect(throws: (any Error).self) { try await database.commit(accepted.snapshot, event: "pr.accepted", commandID: commandID, effects: accepted.effects) }
    #expect(try await database.load() == initial)
    #expect(try await database.effects().isEmpty)
    #expect(try await database.receipt(commandID) == nil)
    try pullRequestCreationSQL(url, "DROP TRIGGER fail_pr")
    _ = try await database.commit(accepted.snapshot, event: "pr.accepted", commandID: commandID, effects: accepted.effects)
    _ = try await database.commit(accepted.snapshot, event: "pr.accepted", commandID: commandID, effects: accepted.effects)
    #expect(try await database.effects().count == 1)
    try fixture.dispatch(operation); try await database.save(fixture.snapshot, event: "pr.dispatching")
    #expect(try await database.rebuildProjection().snapshot == fixture.snapshot)
    let reopened = try WorkspaceDatabase(url: url)
    #expect(try await reopened.cancelEffectsAfterProcessLoss().count == 1)
    #expect(try await reopened.claimNextEffect(workerID: UUID()) == nil)
    var recovered = try await reopened.load(); recovered.recoverInterruptedWork()
    #expect(recovered.pullRequestCreation(operation.id)?.phase == .unconfirmed)
    #expect(recovered.isPullRequestCreationLocked(path: operation.workspacePath))
    var replayed = initial
    for event in try WorkspaceJournal.changes(from: initial, to: recovered) { try event.apply(to: &replayed) }
    #expect(replayed == recovered); try WorkspaceJournal.validate(replayed)
}

private func pullRequestCreationSQL(_ url: URL, _ statement: String) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(url.path, &connection) == SQLITE_OK else { throw CoincideError("PR fixture could not open database") }
    defer { sqlite3_close(connection) }
    guard sqlite3_exec(connection, statement, nil, nil, nil) == SQLITE_OK else { throw CoincideError("PR fixture SQL failed") }
}

@Test func pullRequestCreationHoldsColdSiblingWorktreesAndNewOwnersFromTheSameProject() throws {
    var fixture = PullRequestCreationFixture()
    var sibling = CodingThread(project: fixture.snapshot.projects[0])
    sibling.workspacePath = "/tmp/coincide-pr-cold-sibling"; sibling.isArchived = true
    fixture.snapshot.threads.append(sibling)
    let operation = fixture.operation(try fixture.review()); try fixture.accept(operation)
    #expect(fixture.snapshot.isPullRequestCreationLocked(threadID: sibling.id))
    #expect(!fixture.snapshot.providerReady(for: sibling))
    #expect(throws: WorkspaceCommandError.self) { try fixture.command(.client(.editThread(sibling.id, .archived(false)))) }
    var cold = CodingThread(project: fixture.snapshot.projects[0]); cold.workspacePath = "/tmp/coincide-pr-new-sibling"
    #expect(throws: WorkspaceCommandError.self) { try fixture.command(.client(.createThread(cold))) }
    try fixture.command(.client(.editThread(sibling.id, .draft("Safe archived draft"))))
    #expect(fixture.snapshot.threads[1].draft == "Safe archived draft")
}
