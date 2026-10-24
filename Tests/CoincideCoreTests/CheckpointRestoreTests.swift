import CSQLite
import Foundation
import Testing
@testable import CoincideCore

struct CheckpointRestoreFixture {
    var snapshot: WorkspaceSnapshot
    let threadID: UUID
    let runID: UUID
    let attemptID: UUID
    let incarnation = UUID()
    var now = Date(timeIntervalSince1970: 1_700_200_000)
    var thread: CodingThread { snapshot.threads.first { $0.id == threadID }! }
    init(provider: ProviderKind = .codex) throws {
        let project = WorkspaceProject(path: "/tmp/coincide-restore-main")
        var thread = CodingThread(project: project, model: "retained model")
        thread.workspacePath = "/tmp/coincide-restore-isolated"; thread.provider = provider
        thread.draft = "Keep the latest draft"; thread.title = "Retain this title"; thread.providerThreadID = "retained-provider-thread"
        threadID = thread.id; runID = UUID(); attemptID = UUID()
        let active = ActiveRun(id: runID, configuration: .init(thread: thread), startedAt: now, nativeTurnID: "retained-turn")
        var record = ThreadRunRecord(run: active, origin: .user, userMessageID: "retained-user")
        record.status = .completed; record.endReason = .providerCompleted; record.endedAt = now; record.messageAttributionVersion = 1
        let plan = try Self.plan(id: attemptID, path: thread.workspacePath)
        var attempt = ThreadRunCheckpointAttempt(id: attemptID, workspacePath: thread.workspacePath, phase: .ready, now: now)
        attempt.plan = plan; attempt.receipt = try .init(plan: plan, commit: String(repeating: "c", count: 40), tree: String(repeating: "d", count: 40), capturedAt: now)
        record.checkpoints = .init(baseline: attempt, providerReleased: true)
        var message = ChatMessage(id: "retained-user", role: .user, text: "Retain the transcript")
        message.runReference = .init(threadID: thread.id, runID: runID)
        thread.messages = [message]; thread.runHistory = [record]
        snapshot = .init(); snapshot.projects = [project]; snapshot.threads = [thread]
    }
    static func plan(id: UUID = UUID(), path: String) throws -> GitCheckpointPlan {
        let identity = GitWorktreeNodeIdentity(device: 1, inode: 42)
        return try .init(id: id, workspacePath: path, repositoryPath: path, gitDirectoryPath: path + "/.git", commonDirectoryPath: path + "/.git",
            workspaceIdentity: identity, repositoryIdentity: identity, gitDirectoryIdentity: identity, commonDirectoryIdentity: identity,
            objectDirectoryIdentity: identity, headCommit: String(repeating: "a", count: 40), configurationDigest: String(repeating: "b", count: 64), indexRevision: nil)
    }
    func review(stage: RunCheckpointStage = .baseline, attemptID selected: UUID? = nil, id: UUID = UUID()) throws -> RunCheckpointRestoreReview {
        let attempt = try #require(thread.runCheckpoint(runID: runID, stage: stage, expectedAttemptID: selected ?? attemptID))
        let receipt = try #require(attempt.receipt)
        let git = try GitCheckpointRestoreReview(id: id, targetReceipt: receipt, currentPlan: Self.plan(path: thread.workspacePath),
            reviewedAt: now, manifestDigest: String(repeating: "e", count: 64), affectedPaths: ["source.swift"], previewPatch: "Synthetic review")
        return try .init(id: id, reviewedAt: now, threadID: threadID, projectID: thread.projectID, runID: runID, stage: stage,
            attemptID: attempt.id, sourceIncarnation: incarnation, sourceFingerprint: snapshot.checkpointRestoreSourceFingerprint(threadID: threadID),
            checkpoint: attempt, gitReview: git)
    }
    func receipt(_ review: RunCheckpointRestoreReview) throws -> GitCheckpointRestoreReceipt {
        try .init(review: review.gitReview, completedAt: now, stateDigest: String(repeating: "f", count: 64))
    }
    @discardableResult mutating func command(_ command: EngineCommand, id: UUID = UUID()) throws -> WorkspaceDecision {
        now.addTimeInterval(1)
        let decision = try WorkspaceDecision.make(command, id: id, snapshot: snapshot, now: now); snapshot = decision.snapshot; return decision
    }
    @discardableResult mutating func accept(_ review: RunCheckpointRestoreReview) throws -> WorkspaceDecision { try command(.checkpointRestoreAccepted(review: review)) }
    mutating func dispatch(_ review: RunCheckpointRestoreReview) throws { try command(.checkpointRestoreDispatching(threadID: threadID, operationID: review.id, incarnation: incarnation)) }
    @discardableResult mutating func finish(_ review: RunCheckpointRestoreReview, _ result: EffectResult) throws -> WorkspaceDecision {
        try command(.checkpointRestoreEffectResult(.checkpointRestore(threadID: threadID, operationID: review.id), result, incarnation: incarnation))
    }
}

@Test(arguments: [ProviderKind.codex, .claude])
func checkpointRestoreUsesTheExactCheckpointAcrossAllProviders(provider: ProviderKind) throws {
    var fixture = try CheckpointRestoreFixture(provider: provider); let review = try fixture.review(), before = fixture.thread
    try fixture.accept(review); try fixture.dispatch(review); try fixture.finish(review, .checkpointRestoreConfirmed(fixture.receipt(review)))
    #expect(fixture.thread == before)
    #expect(fixture.snapshot.checkpointRestoreOperation(review.id)?.phase == .applied)
}

@Test func checkpointRestoreAcceptancePersistsExactIntentAndOneEffectWithoutChangingConversation() throws {
    var fixture = try CheckpointRestoreFixture(); let before = fixture.thread, review = try fixture.review()
    try WorkspaceJournal.validate(fixture.snapshot)
    #expect(fixture.snapshot.checkpointRestoreUnavailableReason(threadID: fixture.threadID, runID: fixture.runID, stage: .baseline, expectedAttemptID: fixture.attemptID) == nil)
    let decision = try fixture.accept(review)
    #expect(fixture.thread == before)
    #expect(fixture.snapshot.checkpointRestoreOperation(review.id)?.review == review)
    #expect(decision.effects == [.init(id: review.id, request: .checkpointRestore(threadID: fixture.threadID, operationID: review.id))])
    #expect(fixture.snapshot.isCheckpointRestoreLocked(threadID: fixture.threadID))
    #expect(!fixture.snapshot.providerReady(for: fixture.thread))
    #expect(fixture.snapshot.isCheckpointRestoreLocked(path: fixture.thread.workspacePath + "/nested"))
    #expect(fixture.snapshot.isCheckpointRestoreLocked(path: "/tmp"))
    #expect(!fixture.snapshot.isCheckpointRestoreLocked(path: fixture.thread.workspacePath + "-sibling"))
}

@Test(arguments: ["model", "provider", "permission", "workspace", "projectRoot", "transcript", "checkpoint"])
func checkpointRestoreStaleReviewRejectsWithoutIntentOrEffects(change: String) throws {
    var fixture = try CheckpointRestoreFixture(); let review = try fixture.review()
    switch change {
    case "model": fixture.snapshot.threads[0].model = "changed"
    case "provider": fixture.snapshot.threads[0].provider = .claude
    case "permission": fixture.snapshot.threads[0].permission = .fullAccess
    case "workspace": fixture.snapshot.threads[0].workspacePath += "-changed"
    case "projectRoot": fixture.snapshot.projects[0].path += "-changed"
    case "transcript": fixture.snapshot.threads[0].messages[0].text += " changed"
    default: fixture.snapshot.threads[0].runHistory?[0].checkpoints?.baseline.updatedAt.addTimeInterval(1)
    }
    #expect(throws: (any Error).self) { try fixture.accept(review) }
    #expect(fixture.snapshot.checkpointRestoreOperations == nil)
}

@Test(arguments: ["busy", "queue", "question", "archive", "settlement", "projectRoot", "shared", "archivedShared", "ancestor", "descendant", "savedCheckpoint"])
func checkpointRestoreAdmissionRejectsWorkAndEveryOtherConversationScope(blocker: String) throws {
    var fixture = try CheckpointRestoreFixture()
    switch blocker {
    case "busy": fixture.snapshot.threads[0].state = .running
    case "queue": fixture.snapshot.threads[0].queuedTurns = [.init(id: UUID(), text: "held", configuration: .init(thread: fixture.thread), createdAt: fixture.now)]
    case "question": fixture.snapshot.threads[0].runtimeRequests = [.init(request: .init(id: .number(1), method: "request", params: .null))]
    case "archive": fixture.snapshot.threads[0].isArchived = true
    case "settlement": fixture.snapshot.threads[0].settlement = .init(id: UUID(), settledAt: fixture.now, reviewScript: false)
    case "projectRoot": fixture.snapshot.projects[0].path = fixture.thread.workspacePath
    default:
        var other = CodingThread(project: fixture.snapshot.projects[0])
        other.workspacePath = blocker == "ancestor" ? "/tmp" : blocker == "descendant" ? fixture.thread.workspacePath + "/nested" : fixture.thread.workspacePath
        if blocker == "archivedShared" { other.isArchived = true }
        if blocker == "savedCheckpoint" {
            other.workspacePath = "/tmp/unrelated-restore-workspace"
            other.runHistory = fixture.thread.runHistory
        }
        fixture.snapshot.threads.append(other)
    }
    #expect(!fixture.snapshot.canReviewCheckpointRestore(threadID: fixture.threadID))
}

@Test func checkpointRestoreAliasesShareTheSameLockAndAdmissionScope() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-restore-alias-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    #expect(WorkspaceSnapshot.checkpointRestorePathsOverlap(real.path, alias.path))
    #expect(WorkspaceSnapshot.checkpointRestorePathsOverlap(real.appendingPathComponent("nested").path, alias.path))
}

@Test func checkpointRestoreOldPostAttemptAndLaterObservationAreRetainedExactly() throws {
    var fixture = try CheckpointRestoreFixture()
    var old = try #require(fixture.thread.runHistory?.first?.checkpoints?.baseline)
    let oldID = UUID(), currentID = UUID()
    let oldPlan = try CheckpointRestoreFixture.plan(id: oldID, path: fixture.thread.workspacePath)
    old = .init(id: oldID, workspacePath: fixture.thread.workspacePath, phase: .ready, now: fixture.now, isLaterObservation: true)
    old.plan = oldPlan; old.receipt = try .init(plan: oldPlan, commit: String(repeating: "1", count: 40), tree: String(repeating: "2", count: 40), capturedAt: fixture.now)
    let current = ThreadRunCheckpointAttempt(id: currentID, workspacePath: fixture.thread.workspacePath, phase: .skipped, now: fixture.now)
    fixture.snapshot.threads[0].runHistory?[0].checkpoints?.previousPostRunAttempts = [old]
    fixture.snapshot.threads[0].runHistory?[0].checkpoints?.postRun = current
    let review = try fixture.review(stage: .postRun, attemptID: oldID)
    #expect(review.checkpoint.isLaterObservation && review.checkpoint.requestedAt == old.requestedAt)
    try fixture.accept(review)
    #expect(fixture.snapshot.checkpointRestoreOperation(review.id)?.review.checkpoint == old)
}

@Test func checkpointRestoreReadyBaselineDoesNotDependOnFailedPostOrReleaseItsQueueHold() throws {
    var fixture = try CheckpointRestoreFixture()
    var post = ThreadRunCheckpointAttempt(workspacePath: fixture.thread.workspacePath, phase: .failed, now: fixture.now, isLaterObservation: true)
    post.error = ThreadRunCheckpointAttempt.failureMessage
    fixture.snapshot.threads[0].runHistory?[0].checkpoints?.postRun = post
    fixture.snapshot.threads[0].queuePaused = true
    let review = try fixture.review(), before = fixture.thread
    #expect(fixture.snapshot.checkpointRestoreUnavailableReason(threadID: fixture.threadID, runID: fixture.runID, stage: .baseline, expectedAttemptID: fixture.attemptID) == nil)
    try fixture.accept(review); try fixture.dispatch(review); try fixture.finish(review, .checkpointRestoreConfirmed(fixture.receipt(review)))
    #expect(fixture.thread == before)
    #expect(fixture.thread.heldPostRunCheckpoint?.attempt == post)
    #expect(!fixture.snapshot.providerReady(for: fixture.thread))
    #expect(fixture.thread.queuePaused)
}

@Test func checkpointRestoreCanUseARewoundRunsRetainedCheckpointAudit() throws {
    var fixture = try CheckpointRestoreFixture()
    let history = try ConversationHistoryReview(kind: .rewindBeforeRun, reviewedAt: fixture.now, sourceThreadID: fixture.threadID,
        projectID: fixture.thread.projectID, runID: fixture.runID, sourceIncarnation: fixture.incarnation,
        sourceConfiguration: .init(thread: fixture.thread), targetConfiguration: fixture.thread.runHistory![0].configuration,
        sourceReference: .init(provider: .codex, nativeThreadID: "retained-provider-thread"), reviewedHeadTurnID: "retained-turn",
        boundary: .beforeTurn("retained-turn"), expectedResultHeadTurnID: nil, prefix: [], removedRunIDs: [fixture.runID],
        removedMessageIDs: ["retained-user"], sourceFingerprint: fixture.snapshot.historySourceFingerprint(threadID: fixture.threadID),
        targetThreadID: nil, suggestedTitle: "Retained source")
    try fixture.command(.conversationHistoryAccepted(review: history, title: nil))
    try fixture.command(.conversationHistoryDispatching(threadID: fixture.threadID, operationID: history.id, incarnation: fixture.incarnation))
    let providerResult = try ProviderConversationSnapshot(reference: history.sourceReference, workspacePath: fixture.thread.workspacePath, historyMode: .paginated, headTurnID: nil)
    try fixture.command(.conversationHistoryEffectResult(.conversationHistory(threadID: fixture.threadID, operationID: history.id), .conversationHistoryConfirmed(providerResult), incarnation: fixture.incarnation))
    #expect(fixture.thread.visibleMessages.isEmpty)
    let review = try fixture.review(), before = fixture.thread
    try fixture.accept(review); try fixture.dispatch(review); try fixture.finish(review, .checkpointRestoreConfirmed(fixture.receipt(review)))
    #expect(fixture.thread == before)
    #expect(fixture.thread.runHistory?[0].removedByHistoryOperationID == history.id)
    #expect(fixture.thread.messages[0].removedByHistoryOperationID == history.id)
}

@Test func checkpointRestoreDispatchRechecksNewSharedOwnershipBeforeAnyWriteMarker() throws {
    var fixture = try CheckpointRestoreFixture(); let review = try fixture.review(); try fixture.accept(review)
    var other = CodingThread(project: fixture.snapshot.projects[0]); other.workspacePath = fixture.thread.workspacePath
    fixture.snapshot.threads.append(other)
    #expect(throws: (any Error).self) { try fixture.dispatch(review) }
    #expect(fixture.snapshot.checkpointRestoreOperation(review.id)?.phase == .accepted)
}

@Test func checkpointRestoreDraftTitlePinAndSelectionChangesRemainValidAndSurviveCompletion() throws {
    var fixture = try CheckpointRestoreFixture(); let review = try fixture.review()
    try fixture.command(.client(.editThread(fixture.threadID, .draft("Newest draft"))))
    try fixture.command(.client(.editThread(fixture.threadID, .title("Newest title"))))
    let snoozedUntil = fixture.now.addingTimeInterval(3_600)
    try fixture.command(.client(.workspaceLifecycle(.snooze(threadID: fixture.threadID, until: snoozedUntil))))
    #expect(fixture.thread.workspaceLifecycle?.snoozedUntil == snoozedUntil)
    try fixture.command(.client(.editThread(fixture.threadID, .pinned(true))))
    #expect(fixture.thread.workspaceLifecycle?.snoozedUntil == nil && fixture.thread.workspaceLifecycle?.snoozedAt == nil)
    #expect(fixture.thread.workspaceLifecycle?.lastSnoozeWakeAt == fixture.now, "A real pin-wake leaves nonempty attention metadata outside file ownership.")
    try fixture.command(.client(.selectConversation(threadID: fixture.threadID)))
    try fixture.accept(review)
    try fixture.command(.client(.editThread(fixture.threadID, .draft("Draft while held"))))
    let before = fixture.thread
    try fixture.dispatch(review); try fixture.finish(review, .checkpointRestoreConfirmed(fixture.receipt(review)))
    #expect(fixture.thread == before)
    #expect(fixture.snapshot.checkpointRestoreOperation(review.id)?.phase == .applied)
    #expect(!fixture.snapshot.isCheckpointRestoreLocked(threadID: fixture.threadID))
}

@Test(arguments: ["submit", "model", "archive", "workspace", "remove", "newThread", "addProject", "addProjectThread", "worktree", "checkpoint", "settle"])
func checkpointRestorePendingLockRejectsExistingAndNewOwners(action: String) throws {
    var fixture = try CheckpointRestoreFixture(); let review = try fixture.review(); try fixture.accept(review)
    let before = fixture.snapshot
    let command: EngineCommand
    switch action {
    case "submit": command = .client(.submit(threadID: fixture.threadID, text: "must not send"))
    case "model": command = .client(.editThread(fixture.threadID, .model("new")))
    case "archive": command = .client(.editThread(fixture.threadID, .archived(true)))
    case "workspace": command = .client(.editThread(fixture.threadID, .workspacePath("/tmp/other")))
    case "remove": command = .client(.removeProject(projectID: fixture.thread.projectID, expectedThreadIDs: [fixture.threadID]))
    case "newThread": var other = CodingThread(project: fixture.snapshot.projects[0]); other.workspacePath = fixture.thread.workspacePath + "/nested"; command = .client(.createThread(other))
    case "addProject": command = .client(.addProject(.init(path: fixture.thread.workspacePath)))
    case "addProjectThread": let project = WorkspaceProject(path: fixture.thread.workspacePath); command = .client(.addProjectWithThread(project: project, thread: .init(project: project)))
    case "checkpoint": command = .client(.retryPostRunCheckpoint(threadID: fixture.threadID, runID: fixture.runID, expectedAttemptID: fixture.attemptID))
    case "worktree": command = .client(.cancelWorktreePreparation(fixture.threadID))
    default: command = .client(.settleThread(threadID: fixture.threadID, expectedWorkspacePath: fixture.thread.workspacePath, reviewScript: false))
    }
    #expect(throws: (any Error).self) { try fixture.command(command) }
    #expect(fixture.snapshot == before)
}

@Test(arguments: [false, true])
func checkpointRestoreRestartNeverReplaysAndKeepsPossiblePartialWritesLocked(dispatched: Bool) throws {
    var fixture = try CheckpointRestoreFixture(); let review = try fixture.review(); try fixture.accept(review)
    if dispatched { try fixture.dispatch(review) }
    let before = fixture.thread
    fixture.snapshot.recoverInterruptedWork()
    let operation = try #require(fixture.snapshot.checkpointRestoreOperation(review.id))
    #expect(operation.phase == (dispatched ? .unconfirmed : .failed))
    #expect(fixture.snapshot.isCheckpointRestoreLocked(threadID: fixture.threadID) == dispatched)
    #expect(fixture.thread == before)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test func checkpointRestoreCompletionNeedsDispatchAndExactWriteIncarnationAndDeduplicates() throws {
    var fixture = try CheckpointRestoreFixture(); let review = try fixture.review(); try fixture.accept(review)
    let accepted = fixture.snapshot
    try fixture.finish(review, .checkpointRestoreConfirmed(fixture.receipt(review)))
    #expect(fixture.snapshot == accepted)
    try fixture.command(.checkpointRestoreDispatching(threadID: fixture.threadID, operationID: review.id, incarnation: UUID()))
    #expect(fixture.snapshot == accepted)
    try fixture.dispatch(review)
    let dispatched = fixture.snapshot
    try fixture.command(.checkpointRestoreEffectResult(.checkpointRestore(threadID: fixture.threadID, operationID: review.id), .checkpointRestoreConfirmed(fixture.receipt(review)), incarnation: UUID()))
    #expect(fixture.snapshot == dispatched)
    try fixture.finish(review, .checkpointRestoreConfirmed(fixture.receipt(review)))
    let applied = fixture.snapshot
    try fixture.finish(review, .checkpointRestoreUnconfirmed)
    #expect(fixture.snapshot == applied)
}

@Test(arguments: ["unchanged", "applied", "partial", "acknowledge"])
func checkpointRestoreInspectionAndExplicitKeepCurrentFilesNeverEmitAnotherWrite(outcome: String) throws {
    var fixture = try CheckpointRestoreFixture(); let review = try fixture.review(); try fixture.accept(review); try fixture.dispatch(review)
    try fixture.finish(review, .checkpointRestoreUnconfirmed)
    let before = fixture.thread
    let decision: WorkspaceDecision
    if outcome == "acknowledge" { decision = try fixture.command(.client(.acknowledgeCheckpointRestore(operationID: review.id))) }
    else {
        let result: GitCheckpointRestoreInspection = outcome == "unchanged" ? .notStarted : outcome == "applied" ? .ready(try fixture.receipt(review)) : .interrupted
        decision = try fixture.command(.checkpointRestoreInspected(operationID: review.id, incarnation: UUID(), result: result))
    }
    #expect(decision.effects.isEmpty && fixture.thread == before)
    #expect(fixture.snapshot.isCheckpointRestoreLocked(threadID: fixture.threadID) == (outcome == "partial"))
    if outcome == "acknowledge" {
        let operation = try #require(fixture.snapshot.checkpointRestoreOperation(review.id))
        #expect(operation.phase == .unconfirmed && operation.acknowledgedAt != nil && operation.result == nil)
        let again = try fixture.command(.client(.acknowledgeCheckpointRestore(operationID: review.id)))
        #expect(again.effects.isEmpty)
    }
}

@Test func checkpointRestoreProviderNotificationsWhileLockedCannotModifyConversation() throws {
    var fixture = try CheckpointRestoreFixture(); let runtimeID = UUID()
    fixture.snapshot.threads[0].runtimeID = runtimeID
    let review = try fixture.review(); try fixture.accept(review)
    let before = fixture.thread
    let events: [ProviderEvent] = [.thread("foreign thread"), .configuration(.object([:])), .failure("late failure")]
    for event in events {
        try fixture.command(.provider(threadID: fixture.threadID, runtimeID: runtimeID, event: event))
    }
    #expect(fixture.thread == before)
}

@Test func checkpointRestoreJournalRejectsForeignCompletionLostAuditAndReservedIdentity() throws {
    var fixture = try CheckpointRestoreFixture(); let review = try fixture.review(); try fixture.accept(review)
    var lost = fixture.snapshot; lost.threads[0].runHistory = []
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(lost) }
    var duplicate = fixture.snapshot
    let duplicateOperation = try #require(duplicate.checkpointRestoreOperations?.first)
    duplicate.checkpointRestoreOperations?.append(duplicateOperation)
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(duplicate) }
    var other = CodingThread(project: fixture.snapshot.projects[0]); other.id = review.id
    #expect(throws: (any Error).self) { try fixture.command(.client(.createThread(other))) }
    try fixture.dispatch(review)
    let foreign = try fixture.review()
    try fixture.finish(review, .checkpointRestoreConfirmed(fixture.receipt(foreign)))
    #expect(fixture.snapshot.checkpointRestoreOperation(review.id)?.phase == .unconfirmed)
    #expect(fixture.snapshot.isCheckpointRestoreLocked(threadID: fixture.threadID))
}

@Test func checkpointRestoreLegacySnapshotAndJournalRoundTripPreserveOnlyOperationChanges() throws {
    var fixture = try CheckpointRestoreFixture(); let initial = fixture.snapshot
    let encoded = try JSONEncoder().encode(initial)
    #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded).checkpointRestoreOperations == nil)
    let review = try fixture.review(); try fixture.accept(review)
    let accepted = fixture.snapshot; try fixture.dispatch(review)
    let dispatched = fixture.snapshot; try fixture.finish(review, .checkpointRestoreConfirmed(fixture.receipt(review)))
    var rebuilt = initial
    for expected in [accepted, dispatched, fixture.snapshot] {
        let events = try WorkspaceJournal.changes(from: rebuilt, to: expected)
        #expect(events.count == 1)
        for event in events { try event.apply(to: &rebuilt) }
        try WorkspaceJournal.validate(rebuilt)
        #expect(rebuilt == expected && rebuilt.threads == initial.threads)
    }
}

@Test func checkpointRestoreIntentAndEffectRollbackTogetherAndNeverReplayAfterRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-restore-database-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: url)
    var fixture = try CheckpointRestoreFixture(); let initial = fixture.snapshot
    try await database.save(initial, event: "fixture")
    let review = try fixture.review(), decision = try fixture.accept(review), commandID = UUID()
    try checkpointRestoreSQL(url, "CREATE TRIGGER fail_restore BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'fixture rejection'); END")
    await #expect(throws: (any Error).self) { try await database.commit(decision.snapshot, event: "checkpoint.restore.accepted", commandID: commandID, effects: decision.effects) }
    #expect(try await database.load() == initial)
    #expect(try await database.receipt(commandID) == nil)
    #expect(try await database.effects().isEmpty)
    try checkpointRestoreSQL(url, "DROP TRIGGER fail_restore")
    _ = try await database.commit(decision.snapshot, event: "checkpoint.restore.accepted", commandID: commandID, effects: decision.effects)
    #expect(try await database.effects().map(\.request) == decision.effects.map(\.request))
    try fixture.dispatch(review); try await database.save(fixture.snapshot, event: "checkpoint.restore.dispatching")
    try fixture.finish(review, .checkpointRestoreUnconfirmed); try await database.save(fixture.snapshot, event: "checkpoint.restore.unconfirmed")
    #expect(try await database.rebuildProjection().snapshot == fixture.snapshot)
    let reopened = try WorkspaceDatabase(url: url)
    #expect(try await reopened.load() == fixture.snapshot)
    #expect(try await reopened.cancelEffectsAfterProcessLoss().count == 1)
    #expect(try await reopened.claimNextEffect(workerID: UUID()) == nil)
}

private func checkpointRestoreSQL(_ url: URL, _ statement: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw CoincideError("Restore fixture database could not open.") }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw CoincideError("Restore fixture database statement failed.") }
}
