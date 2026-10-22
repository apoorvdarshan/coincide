import CSQLite
import Foundation
import Testing
@testable import CoincideCore

struct ConversationHistoryFilesFixture {
    var snapshot: WorkspaceSnapshot
    let incarnation = UUID()
    let threadID: UUID
    let runs: [UUID]
    var now = Date(timeIntervalSince1970: 1_700_400_000)
    var thread: CodingThread { snapshot.threads[0] }
    init() throws {
        let project = WorkspaceProject(path: "/tmp/coincide-combined-main")
        var thread = CodingThread(project: project, model: "current-settings")
        thread.workspacePath = "/tmp/coincide-combined-isolated"; thread.providerThreadID = "combined-native"
        thread.draft = "Unsent latest draft"; thread.checkpointPolicy = .disabled
        threadID = thread.id; runs = (0..<3).map { _ in UUID() }
        for (index, id) in runs.enumerated() {
            var configuration = ProviderConfiguration(thread: thread)
            if index == 0 { configuration.nativeThreadID = nil }
            let started = now.addingTimeInterval(Double(index * 10))
            var record = ThreadRunRecord(run: .init(id: id, configuration: configuration, startedAt: started,
                nativeTurnID: "combined-turn-\(index)"), origin: .user, userMessageID: "user-\(id)")
            record.providerThreadID = thread.providerThreadID; record.status = .completed
            record.endedAt = started.addingTimeInterval(2); record.endReason = .providerCompleted; record.messageAttributionVersion = 1
            let baseline = try Self.attempt(path: thread.workspacePath, date: started)
            let post = try Self.attempt(path: thread.workspacePath, date: started.addingTimeInterval(2))
            record.checkpoints = .init(baseline: baseline, providerReleased: true); record.checkpoints?.postRun = post
            var user = ChatMessage(id: "user-\(id)", role: .user, text: "Original prompt \(index)")
            var reply = ChatMessage(id: "reply-\(id)", role: .assistant, text: "Original reply \(index)")
            user.runReference = .init(threadID: thread.id, runID: id); reply.runReference = user.runReference
            thread.messages += [user, reply]
            if thread.runHistory == nil { thread.runHistory = [] }; thread.runHistory!.append(record)
        }
        snapshot = .init(); snapshot.projects = [project]; snapshot.threads = [thread]
    }
    static func attempt(path: String, date: Date) throws -> ThreadRunCheckpointAttempt {
        let plan = try CheckpointRestoreFixture.plan(path: path)
        var attempt = ThreadRunCheckpointAttempt(id: plan.id, workspacePath: path, phase: .ready, now: date)
        attempt.plan = plan; attempt.receipt = try .init(plan: plan, commit: String(repeating: "c", count: 40),
            tree: String(repeating: "d", count: 40), capturedAt: date)
        return attempt
    }
    func review(index: Int = 1, restoreFiles: Bool = true, recall: Bool? = true, fileID: UUID = UUID(),
                replacingTarget: ConversationHistoryFileTarget? = nil) throws -> ConversationHistoryReview {
        let run = thread.runHistory![index], prefix = try thread.transcriptPrefix(runID: run.id, boundary: .beforeRun)
        let suffix = thread.activeHistoryRuns.dropFirst(index).map(\.id), prefixIDs = Set(prefix.map(\.id))
        let files: ConversationHistoryFilesReview?
        if restoreFiles {
            guard case .available(let resolved) = thread.conversationHistoryFileTarget(beforeRunID: run.id) else { throw CoincideError("Combined fixture target unavailable") }
            let target = replacingTarget ?? resolved
            let git = try GitCheckpointRestoreReview(id: fileID, targetReceipt: target.receipt,
                currentPlan: CheckpointRestoreFixture.plan(path: thread.workspacePath), reviewedAt: now,
                manifestDigest: String(repeating: "e", count: 64), affectedPaths: ["tracked.swift"])
            files = try .init(id: fileID, target: target, sourceFingerprint: snapshot.checkpointRestoreSourceFingerprint(threadID: threadID), gitReview: git)
        } else { files = nil }
        return try .init(kind: .rewindBeforeRun, reviewedAt: now, sourceThreadID: threadID, projectID: thread.projectID,
            runID: run.id, sourceIncarnation: incarnation, sourceConfiguration: .init(thread: thread), targetConfiguration: run.configuration,
            sourceReference: .init(provider: .codex, nativeThreadID: "combined-native"), reviewedHeadTurnID: "combined-turn-2",
            boundary: .beforeTurn("combined-turn-\(index)"), expectedResultHeadTurnID: index == 0 ? nil : "combined-turn-\(index - 1)",
            prefix: prefix, removedRunIDs: Array(suffix), removedMessageIDs: thread.visibleMessages.filter { !prefixIDs.contains($0.id) }.map(\.id),
            sourceFingerprint: snapshot.historySourceFingerprint(threadID: threadID), targetThreadID: nil,
            suggestedTitle: "Combined rewind", files: files, recallPromptOnSuccess: recall)
    }
    func providerResult(_ review: ConversationHistoryReview) throws -> ProviderConversationSnapshot {
        try .init(reference: review.sourceReference, workspacePath: thread.workspacePath, historyMode: .paginated,
            headTurnID: review.expectedResultHeadTurnID)
    }
    func fileReceipt(_ review: ConversationHistoryReview) throws -> GitCheckpointRestoreReceipt {
        try .init(review: #require(review.files).gitReview, completedAt: now, stateDigest: String(repeating: "f", count: 64))
    }
    @discardableResult mutating func command(_ command: EngineCommand) throws -> WorkspaceDecision {
        now.addTimeInterval(1)
        let decision = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: now)
        snapshot = decision.snapshot; return decision
    }
    @discardableResult mutating func accept(_ review: ConversationHistoryReview) throws -> WorkspaceDecision {
        try command(.conversationHistoryAccepted(review: review, title: nil))
    }
    mutating func dispatchProvider(_ review: ConversationHistoryReview) throws {
        try command(.conversationHistoryDispatching(threadID: threadID, operationID: review.id, incarnation: incarnation))
    }
    @discardableResult mutating func finishProvider(_ review: ConversationHistoryReview, result: EffectResult? = nil) throws -> WorkspaceDecision {
        try command(.conversationHistoryEffectResult(.conversationHistory(threadID: threadID, operationID: review.id),
            result ?? .conversationHistoryConfirmed(providerResult(review)), incarnation: incarnation))
    }
    mutating func dispatchFiles(_ review: ConversationHistoryReview) throws {
        try command(.conversationHistoryFilesDispatching(threadID: threadID, operationID: review.id, incarnation: incarnation))
    }
    @discardableResult mutating func finishFiles(_ review: ConversationHistoryReview, result: EffectResult? = nil) throws -> WorkspaceDecision {
        try command(.conversationHistoryFilesEffectResult(.conversationHistoryFiles(threadID: threadID, operationID: review.id,
            fileAttemptID: #require(review.files).id), result ?? .checkpointRestoreConfirmed(fileReceipt(review)), incarnation: incarnation))
    }
    func operation(_ review: ConversationHistoryReview) throws -> ConversationHistoryOperation { try #require(snapshot.conversationHistoryOperation(review.id)) }
}

@Test func conversationHistoryFilesPublishesProviderBoundaryAndExactlyOneDistinctFileIntentAtomically() throws {
    var fixture = try ConversationHistoryFilesFixture(); let review = try fixture.review(), initial = fixture.thread
    let accepted = try fixture.accept(review)
    #expect(accepted.effects.count == 1 && fixture.thread == initial)
    #expect(try fixture.operation(review).files?.phase == .waitingForProvider)
    #expect(fixture.snapshot.isCheckpointRestoreLocked(path: fixture.thread.workspacePath))
    try fixture.dispatchProvider(review)
    let confirmed = try fixture.finishProvider(review), operation = try fixture.operation(review)
    let files = try #require(review.files)
    #expect(operation.phase == .applied && operation.result != nil && operation.files?.phase == .accepted)
    #expect(operation.isWorking && operation.locksSource && operation.locksFiles && !operation.allExternalWorkSucceeded)
    #expect(operation.files?.postHistorySourceFingerprint != operation.files?.review.sourceFingerprint)
    #expect(fixture.thread.visibleMessages == review.prefix && fixture.thread.messages.count == initial.messages.count)
    #expect(confirmed.effects == [.init(id: files.id, request: .conversationHistoryFiles(threadID: fixture.threadID,
        operationID: review.id, fileAttemptID: files.id))])
    #expect(review.files?.id != review.id)
    #expect(fixture.snapshot.checkpointRestoreOperations == nil)
    let late = try fixture.finishProvider(review, result: .conversationHistoryUnconfirmed)
    #expect(late.effects.isEmpty && fixture.snapshot.conversationHistoryOperation(review.id) == operation)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test(arguments: [false, true])
func conversationHistoryRecallWaitsForCompleteExternalSuccessThenAppendsLatestDraftExactlyOnce(restoreFiles: Bool) throws {
    var fixture = try ConversationHistoryFilesFixture(); let review = try fixture.review(restoreFiles: restoreFiles)
    try fixture.accept(review); try fixture.dispatchProvider(review); try fixture.finishProvider(review)
    if restoreFiles {
        let before = fixture.snapshot
        #expect(throws: WorkspaceCommandError.self) { try fixture.command(.client(.recallConversationHistoryPrompt(operationID: review.id))) }
        #expect(fixture.snapshot == before)
        try fixture.dispatchFiles(review); try fixture.finishFiles(review)
    }
    let successful = try fixture.operation(review)
    #expect(successful.allExternalWorkSucceeded && successful.needsPromptRecall && successful.locksSource && !successful.locksFiles)
    #expect(!fixture.snapshot.isCheckpointRestoreLocked(path: fixture.thread.workspacePath))
    #expect(!fixture.snapshot.providerReady(for: fixture.thread))
    #expect(throws: WorkspaceCommandError.self) { try fixture.command(.client(.submit(threadID: fixture.threadID, text: "Too early"))) }
    try fixture.command(.client(.editThread(fixture.threadID, .draft("Saved late typing"))))
    let recalled = try fixture.command(.client(.recallConversationHistoryPrompt(operationID: review.id)))
    #expect(fixture.thread.draft == "Saved late typing\n\nOriginal prompt 1")
    #expect(recalled.effects.isEmpty && fixture.thread.activeRun == nil && fixture.thread.queuedTurns.isEmpty)
    #expect(try !fixture.operation(review).locksSource)
    let once = fixture.snapshot
    try fixture.command(.client(.recallConversationHistoryPrompt(operationID: review.id)))
    #expect(fixture.snapshot == once)
}

@Test func conversationHistoryKeepDraftDismissesOnlyPendingRecallWithoutInventingSuccess() throws {
    var fixture = try ConversationHistoryFilesFixture(); let review = try fixture.review(restoreFiles: false)
    try fixture.accept(review); try fixture.dispatchProvider(review); try fixture.finishProvider(review)
    let draft = fixture.thread.draft
    let dismissed = try fixture.command(.client(.dismissConversationHistoryRecall(operationID: review.id)))
    let operation = try fixture.operation(review)
    #expect(dismissed.effects.isEmpty && fixture.thread.draft == draft)
    #expect(operation.recallDismissedAt != nil && operation.recalledAt == nil && !operation.locksSource)
    #expect(throws: WorkspaceCommandError.self) { try fixture.command(.client(.recallConversationHistoryPrompt(operationID: review.id))) }
}

@Test(arguments: ["failed", "unconfirmed", "stopped"])
func conversationHistoryProviderFailureNeverEmitsOrDispatchesAFileWrite(outcome: String) throws {
    var fixture = try ConversationHistoryFilesFixture(); let review = try fixture.review()
    try fixture.accept(review); try fixture.dispatchProvider(review)
    let before = fixture.thread
    let result: EffectResult = outcome == "failed" ? .failed("redacted") : outcome == "stopped" ? .stopped : .conversationHistoryUnconfirmed
    let decision = try fixture.finishProvider(review, result: result)
    #expect(decision.effects.isEmpty && fixture.thread == before)
    #expect(try !fixture.operation(review).needsPromptRecall)
    let operation = try fixture.operation(review)
    try fixture.dispatchFiles(review)
    #expect(try fixture.operation(review) == operation)
    #expect(fixture.snapshot.isCheckpointRestoreLocked(threadID: fixture.threadID) == (outcome != "failed"))
}

@Test(arguments: ["accepted", "dispatching", "filesAccepted", "filesDispatching", "recall"])
func conversationHistoryFilesRecoveryNeverReplaysAndPreservesTheProviderResult(stage: String) throws {
    var fixture = try ConversationHistoryFilesFixture(); let review = try fixture.review()
    try fixture.accept(review)
    if stage != "accepted" { try fixture.dispatchProvider(review) }
    if stage.hasPrefix("files") || stage == "recall" { try fixture.finishProvider(review) }
    if stage == "filesDispatching" || stage == "recall" { try fixture.dispatchFiles(review) }
    if stage == "recall" { try fixture.finishFiles(review) }
    let originalDraft = fixture.thread.draft, originalPaused = fixture.thread.queuePaused
    fixture.snapshot.recoverInterruptedWork()
    let operation = try fixture.operation(review)
    #expect(!operation.isWorking)
    #expect(fixture.thread.draft == originalDraft && fixture.thread.queuePaused == originalPaused)
    if stage.hasPrefix("files") {
        #expect(operation.phase == .applied && operation.result != nil)
        #expect(operation.files?.phase == (stage == "filesAccepted" ? .failed : .unconfirmed))
        #expect(operation.locksSource && !operation.needsPromptRecall)
    } else if stage == "recall" { #expect(operation.needsPromptRecall && operation.allExternalWorkSucceeded) }
    else { #expect(operation.phase == (stage == "accepted" ? .failed : .unconfirmed)) }
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test func conversationHistoryProviderInspectionCanApplyOnlyHistoryAndNeverStartDelayedFiles() throws {
    var fixture = try ConversationHistoryFilesFixture(); let review = try fixture.review()
    try fixture.accept(review); try fixture.dispatchProvider(review); try fixture.finishProvider(review, result: .conversationHistoryUnconfirmed)
    let decision = try fixture.command(.conversationHistoryReconciled(operationID: review.id, incarnation: UUID(), result: .applied(fixture.providerResult(review))))
    let operation = try fixture.operation(review)
    #expect(decision.effects.isEmpty && operation.phase == .applied && operation.files?.phase == .failed)
    #expect(operation.files?.error == ConversationHistoryFilesState.notStartedMessage)
    #expect(!operation.needsPromptRecall && operation.locksSource)
    #expect(fixture.thread.visibleMessages == review.prefix)
}

@Test(arguments: ["failed", "unconfirmed", "foreignReceipt"])
func conversationHistoryFileFailureRetainsProviderSuccessAndHoldsUntilExplicitKeep(outcome: String) throws {
    var fixture = try ConversationHistoryFilesFixture(); let review = try fixture.review()
    try fixture.accept(review); try fixture.dispatchProvider(review); try fixture.finishProvider(review); try fixture.dispatchFiles(review)
    let result: EffectResult
    if outcome == "failed" { result = .failed("private detail never retained") }
    else if outcome == "foreignReceipt" {
        let git = try GitCheckpointRestoreReview(targetReceipt: #require(review.files).target.receipt,
            currentPlan: CheckpointRestoreFixture.plan(path: fixture.thread.workspacePath), manifestDigest: String(repeating: "e", count: 64))
        result = .checkpointRestoreConfirmed(try .init(review: git, stateDigest: String(repeating: "f", count: 64)))
    } else { result = .checkpointRestoreUnconfirmed }
    let finished = try fixture.finishFiles(review, result: result), operation = try fixture.operation(review)
    #expect(finished.effects.isEmpty && operation.phase == .applied && operation.result != nil)
    #expect(!operation.allExternalWorkSucceeded && !operation.needsPromptRecall && operation.locksFiles && operation.locksSource)
    let source = fixture.thread
    let kept = try fixture.command(.client(.acknowledgeConversationHistoryFiles(operationID: review.id)))
    #expect(kept.effects.isEmpty && fixture.thread == source)
    #expect(try fixture.operation(review).files?.acknowledgedAt != nil)
    #expect(try !fixture.operation(review).locksSource)
    #expect(try !fixture.operation(review).allExternalWorkSucceeded)
    try fixture.command(.client(.editThread(fixture.threadID, .model("Explicit new setting"))))
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test(arguments: ["applied", "notStarted", "interrupted"])
func conversationHistoryFileInspectionUsesExactOwnedEvidenceWithoutNewEffect(outcome: String) throws {
    var fixture = try ConversationHistoryFilesFixture(); let review = try fixture.review()
    try fixture.accept(review); try fixture.dispatchProvider(review); try fixture.finishProvider(review)
    try fixture.dispatchFiles(review); try fixture.finishFiles(review, result: .checkpointRestoreUnconfirmed)
    let source = fixture.thread
    let evidence: GitCheckpointRestoreInspection = outcome == "applied" ? .ready(try fixture.fileReceipt(review)) : outcome == "notStarted" ? .notStarted : .interrupted
    let decision = try fixture.command(.conversationHistoryFilesInspected(operationID: review.id, incarnation: UUID(), result: evidence))
    #expect(decision.effects.isEmpty && fixture.thread == source)
    #expect(try fixture.operation(review).files?.phase == (outcome == "applied" ? .applied : outcome == "notStarted" ? .failed : .unconfirmed))
    #expect(try fixture.operation(review).needsPromptRecall == (outcome == "applied"))
}

@Test(arguments: ["create", "project", "workspace", "checkpoint", "settle", "submit", "model", "archive", "reserved"])
func conversationHistoryFilesLockAllWritersAndNewOverlappingOwners(action: String) throws {
    var fixture = try ConversationHistoryFilesFixture(); let review = try fixture.review(); try fixture.accept(review)
    var other = CodingThread(project: fixture.snapshot.projects[0]); other.workspacePath = fixture.thread.workspacePath + "/nested"
    let command: WorkspaceCommand
    switch action {
    case "create": command = .createThread(other)
    case "project": command = .addProject(.init(path: fixture.thread.workspacePath + "/nested"))
    case "workspace":
        other.workspacePath = "/tmp/coincide-combined-unrelated"; fixture.snapshot.threads.append(other)
        command = .editThread(other.id, .workspacePath(fixture.thread.workspacePath))
    case "checkpoint": command = .retryPostRunCheckpoint(threadID: fixture.threadID, runID: fixture.runs[0], expectedAttemptID: try #require(fixture.thread.runHistory?[0].checkpoints?.postRun).id)
    case "settle": command = .settleThread(threadID: fixture.threadID, expectedWorkspacePath: fixture.thread.workspacePath, reviewScript: false)
    case "submit": command = .submit(threadID: fixture.threadID, text: "Blocked new turn")
    case "model": command = .editThread(fixture.threadID, .model("Blocked config"))
    case "archive": command = .editThread(fixture.threadID, .archived(true))
    default: other.id = try #require(review.files).id; other.workspacePath = "/tmp/coincide-combined-unrelated"; command = .createThread(other)
    }
    let before = fixture.snapshot
    #expect(throws: (any Error).self) { try fixture.command(.client(command)) }
    #expect(fixture.snapshot == before)
    try fixture.command(.client(.editThread(fixture.threadID, .draft("Allowed late draft"))))
    try fixture.command(.client(.editThread(fixture.threadID, .pinned(true))))
    #expect(fixture.thread.draft == "Allowed late draft" && fixture.thread.isPinned)
}

@Test func conversationHistoryFilesRejectsSelectedBaselineAndStaleTargetBeforeProviderIntent() throws {
    var fixture = try ConversationHistoryFilesFixture()
    let baseline = try #require(fixture.thread.runHistory?[1].checkpoints?.baseline)
    let wrong = try ConversationHistoryFileTarget(selectedRunID: fixture.runs[1], checkpointRunID: fixture.runs[1], stage: .baseline,
        attemptID: baseline.id, receipt: #require(baseline.receipt))
    let review = try fixture.review(replacingTarget: wrong), original = fixture.snapshot
    #expect(throws: (any Error).self) { try fixture.accept(review) }
    #expect(fixture.snapshot == original)
    let current = try fixture.review()
    fixture.snapshot.threads[0].runHistory?[0].checkpoints?.postRun?.updatedAt.addTimeInterval(1)
    #expect(throws: (any Error).self) { try fixture.accept(current) }
}

@Test func conversationHistoryFilesPostProviderProjectionRequiresItsExactRetainedAudit() throws {
    var fixture = try ConversationHistoryFilesFixture(); let review = try fixture.review()
    try fixture.accept(review); try fixture.dispatchProvider(review); try fixture.finishProvider(review)
    try fixture.snapshot.validateConversationHistoryFilesSource(operationID: review.id)
    var altered = fixture.snapshot
    altered.threads[0].messages[2].removedByHistoryOperationID = nil
    #expect(throws: (any Error).self) { try altered.validateConversationHistoryFilesSource(operationID: review.id) }
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(altered) }
    var forged = try fixture.operation(review); forged.files?.postHistorySourceFingerprint = String(repeating: "0", count: 64)
    #expect(throws: (any Error).self) { try fixture.snapshot.validateConversationHistoryFilesSource(forged) }
}

@Test func conversationHistoryFilesProviderPublicationAndFileOutboxRollbackAndReplayTogether() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-combined-sql-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: url)
    var fixture = try ConversationHistoryFilesFixture(); let initial = fixture.snapshot, review = try fixture.review()
    try await database.save(initial, event: "fixture")
    let accepted = try fixture.accept(review)
    _ = try await database.commit(accepted.snapshot, event: "history.accepted", commandID: UUID(), effects: accepted.effects)
    try fixture.dispatchProvider(review); try await database.save(fixture.snapshot, event: "history.dispatching")
    let before = fixture.snapshot, confirmed = try fixture.finishProvider(review), commandID = UUID()
    try combinedHistorySQL(url, "CREATE TRIGGER fail_files BEFORE INSERT ON workspace_effects WHEN NEW.id='\(try #require(review.files).id.uuidString)' BEGIN SELECT RAISE(ABORT,'file outbox rejection'); END")
    await #expect(throws: (any Error).self) { try await database.commit(confirmed.snapshot, event: "history.confirmed", commandID: commandID, effects: confirmed.effects) }
    #expect(try await database.load() == before)
    #expect(try await database.receipt(commandID) == nil)
    #expect(try await database.effects().count == 1)
    try combinedHistorySQL(url, "DROP TRIGGER fail_files")
    _ = try await database.commit(confirmed.snapshot, event: "history.confirmed", commandID: commandID, effects: confirmed.effects)
    _ = try await database.commit(confirmed.snapshot, event: "history.confirmed", commandID: commandID, effects: confirmed.effects)
    #expect(try await database.effects().count == 2)
    #expect(try await database.rebuildProjection().snapshot == confirmed.snapshot)
    let reopened = try WorkspaceDatabase(url: url)
    #expect(try await reopened.load() == confirmed.snapshot)
    #expect(try await reopened.cancelEffectsAfterProcessLoss().count == 2)
    #expect(try await reopened.claimNextEffect(workerID: UUID()) == nil)
    var recovered = try await reopened.load(); recovered.recoverInterruptedWork()
    #expect(recovered.conversationHistoryOperation(review.id)?.files?.phase == .failed)
    #expect(recovered.conversationHistoryOperation(review.id)?.phase == .applied)
    try WorkspaceJournal.validate(recovered)
    var replayed = initial
    for event in try WorkspaceJournal.changes(from: initial, to: recovered) { try event.apply(to: &replayed) }
    try WorkspaceJournal.validate(replayed); #expect(replayed == recovered)
}

private func combinedHistorySQL(_ url: URL, _ statement: String) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(url.path, &connection) == SQLITE_OK else { throw CoincideError("Combined fixture database unavailable") }
    defer { sqlite3_close(connection) }
    guard sqlite3_exec(connection, statement, nil, nil, nil) == SQLITE_OK else { throw CoincideError("Combined fixture SQL failed") }
}

@Test(arguments: [false, true])
func conversationHistoryAutoRecallPreflightsMergedAttachmentCapacityBeforeExternalIntent(duplicate: Bool) throws {
    var fixture = try ConversationHistoryFilesFixture()
    let attachments: [ChatAttachment] = (0..<AttachmentLimits.count).map { index in
        .init(id: UUID(), name: "draft-\(index).txt", mimeType: "text/plain", byteCount: 1,
              digest: String(repeating: "a", count: 64), fileExtension: "txt")
    }
    let opening = duplicate ? attachments[0] : ChatAttachment(id: UUID(), name: "opening.txt", mimeType: "text/plain", byteCount: 1,
        digest: String(repeating: "b", count: 64), fileExtension: "txt")
    fixture.snapshot.threads[0].messages[2].attachments = [opening]
    let review = try fixture.review()
    // Draft attachments can change after review; admission must use their newest values.
    fixture.snapshot.threads[0].draftAttachments = attachments
    let before = fixture.snapshot
    if duplicate {
        let accepted = try fixture.accept(review)
        #expect(accepted.effects.count == 1 && fixture.thread == before.threads[0])
    } else {
        #expect(throws: WorkspaceCommandError.self) { try fixture.accept(review) }
        #expect(fixture.snapshot == before && fixture.snapshot.conversationHistoryOperations == nil)
    }
}

@Test(arguments: ["prematureFailure", "prematureAcknowledgement", "missingPostSource", "appliedWaiting"])
func conversationHistoryFilesRejectsMalformedProviderAndFileStageCombinations(change: String) throws {
    var fixture = try ConversationHistoryFilesFixture(); let review = try fixture.review()
    try fixture.accept(review)
    if change == "missingPostSource" || change == "appliedWaiting" {
        try fixture.dispatchProvider(review); try fixture.finishProvider(review)
    }
    var operation = try fixture.operation(review)
    switch change {
    case "prematureFailure":
        operation.files?.phase = .failed; operation.files?.error = ConversationHistoryFilesState.notStartedMessage
    case "prematureAcknowledgement":
        operation.files?.phase = .failed; operation.files?.error = ConversationHistoryFilesState.notStartedMessage
        operation.files?.acknowledgedAt = fixture.now
    case "missingPostSource":
        operation.files?.phase = .failed; operation.files?.error = ConversationHistoryFilesState.notStartedMessage
        operation.files?.acknowledgedAt = fixture.now; operation.files?.postHistorySourceFingerprint = nil
    default:
        operation.files?.phase = .waitingForProvider; operation.files?.postHistorySourceFingerprint = nil
    }
    #expect(throws: (any Error).self) { try operation.validate() }
    fixture.snapshot.conversationHistoryOperations = [operation]
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(fixture.snapshot) }
}
