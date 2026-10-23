import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private struct ConversationHistoryFixture {
    var snapshot: WorkspaceSnapshot
    let threadID: UUID
    let incarnation = UUID()
    let runs: [UUID]
    var now = Date(timeIntervalSince1970: 1_700_100_000)
    var thread: CodingThread { snapshot.threads.first { $0.id == threadID }! }

    init() {
        let project = WorkspaceProject(path: "/tmp/coincide-history-reviewed-workspace")
        var thread = CodingThread(project: project, model: "current-model")
        thread.providerThreadID = "native-source"; thread.permission = .auto
        thread.checkpointPolicy = .disabled; thread.title = "Original source"
        thread.providerMetadata = .object(["source-only": .string("retained metadata")])
        thread.draft = "Unsent source draft"
        thread.draftAttachments = [.init(id: UUID(), name: "unsent.txt", mimeType: "text/plain", byteCount: 4,
                                         digest: String(repeating: "a", count: 64), fileExtension: "txt")]
        runs = (0..<3).map { _ in UUID() }; threadID = thread.id
        for (index, id) in runs.enumerated() {
            var configuration = ProviderConfiguration(thread: thread)
            configuration.model = "captured-model-\(index + 1)"
            configuration.permission = .supervised
            let startedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 10))
            let active = ActiveRun(id: id, configuration: configuration, startedAt: startedAt, nativeTurnID: "native-\(index + 1)")
            let userID = "user-\(id.uuidString)"
            var record = ThreadRunRecord(run: active, origin: .user, userMessageID: userID)
            record.status = .completed; record.endedAt = startedAt.addingTimeInterval(2)
            record.endReason = .providerCompleted; record.messageAttributionVersion = 1
            var checkpoints = ThreadRunCheckpoints(baseline: .init(workspacePath: configuration.workspacePath, phase: .unavailable,
                now: startedAt, unavailableReason: .notRepository), providerReleased: true)
            checkpoints.postRun = .init(workspacePath: configuration.workspacePath, phase: .unavailable,
                now: startedAt.addingTimeInterval(2), unavailableReason: .notRepository)
            record.checkpoints = checkpoints
            if thread.runHistory == nil { thread.runHistory = [] }; thread.runHistory!.append(record)
            var user = ChatMessage(id: userID, role: .user, text: "Prompt \(index + 1)")
            var reply = ChatMessage(id: "reply-\(index + 1)", role: .assistant, text: "Reply \(index + 1)")
            user.createdAt = startedAt; reply.createdAt = startedAt.addingTimeInterval(1)
            user.runReference = .init(threadID: thread.id, runID: id); reply.runReference = user.runReference
            thread.messages += [user, reply]
        }
        snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    }
    @discardableResult mutating func command(_ command: EngineCommand, id: UUID = UUID()) throws -> WorkspaceDecision {
        now.addTimeInterval(1)
        let decision = try WorkspaceDecision.make(command, id: id, snapshot: snapshot, now: now)
        snapshot = decision.snapshot; return decision
    }

    func review(_ kind: ConversationHistoryKind = .forkAfterRun, index: Int = 1, id: UUID = UUID(),
                targetThreadID: UUID? = nil, prefix replacementPrefix: [ChatMessage]? = nil) throws -> ConversationHistoryReview {
        let record = thread.runHistory![index]
        let prefix = try replacementPrefix ?? thread.transcriptPrefix(runID: record.id, boundary: kind == .forkAfterRun ? .afterRun : .beforeRun)
        let removedRuns = kind == .rewindBeforeRun ? Array(runs.dropFirst(index)) : []
        let removedMessages = kind == .rewindBeforeRun ? thread.messages.filter { message in
            message.runReference.map { $0.threadID == threadID && removedRuns.contains($0.runID) } ?? false
        }.map(\.id) : []
        return try .init(id: id, kind: kind, reviewedAt: now, sourceThreadID: threadID, projectID: thread.projectID,
            runID: record.id, sourceIncarnation: incarnation, sourceConfiguration: .init(thread: thread),
            targetConfiguration: record.configuration, sourceReference: .init(provider: .codex, nativeThreadID: "native-source"),
            reviewedHeadTurnID: "native-3", boundary: kind == .forkAfterRun ? .throughTurn("native-\(index + 1)") : .beforeTurn("native-\(index + 1)"),
            expectedResultHeadTurnID: kind == .forkAfterRun ? "native-\(index + 1)" : (index == 0 ? nil : "native-\(index)"),
            prefix: prefix, removedRunIDs: removedRuns, removedMessageIDs: removedMessages,
            sourceFingerprint: snapshot.historySourceFingerprint(threadID: threadID),
            targetThreadID: kind == .forkAfterRun ? (targetThreadID ?? UUID()) : nil, suggestedTitle: "Reviewed fork")
    }

    func result(for review: ConversationHistoryReview) throws -> ProviderConversationSnapshot {
        try .init(reference: .init(provider: .codex, nativeThreadID: review.kind == .forkAfterRun ? "native-fork" : "native-source"),
                  workspacePath: review.targetConfiguration.workspacePath, historyMode: .paginated,
                  headTurnID: review.expectedResultHeadTurnID)
    }

    @discardableResult mutating func accept(_ review: ConversationHistoryReview, title: String? = nil) throws -> WorkspaceDecision {
        try command(.conversationHistoryAccepted(review: review, title: title))
    }

    mutating func dispatch(_ review: ConversationHistoryReview) throws {
        try command(.conversationHistoryDispatching(threadID: threadID, operationID: review.id, incarnation: incarnation))
    }

    @discardableResult mutating func confirm(_ review: ConversationHistoryReview) throws -> WorkspaceDecision {
        try command(.conversationHistoryEffectResult(.conversationHistory(threadID: threadID, operationID: review.id),
                                                     .conversationHistoryConfirmed(result(for: review)), incarnation: incarnation))
    }
}

@Test
func conversationHistoryAcceptancePersistsOnlyReviewedIntentAndAnOutboxAction() throws {
    var fixture = ConversationHistoryFixture(); try WorkspaceJournal.validate(fixture.snapshot)
    let before = fixture.thread, review = try fixture.review()
    #expect(fixture.snapshot.canReviewConversationHistory(threadID: fixture.threadID))
    let decision = try fixture.accept(review, title: "Selected target title")
    #expect(fixture.thread == before)
    #expect(fixture.snapshot.threads.count == 1)
    let operation = try #require(fixture.snapshot.conversationHistoryOperations?.first)
    #expect(operation.id == review.id && operation.review == review && operation.phase == .accepted)
    #expect(operation.targetTitle == "Selected target title")
    #expect(decision.effects.count == 1)
    #expect(decision.effects.first?.request == .conversationHistory(threadID: fixture.threadID, operationID: review.id))
    #expect(fixture.snapshot.isConversationHistoryLocked(threadID: fixture.threadID))
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test(arguments: ["model", "permission", "nativeThread", "workspace", "transcript", "turn"])
func conversationHistoryStaleReviewCannotCreateAnOperationOrAnEffect(change: String) throws {
    var fixture = ConversationHistoryFixture(); let review = try fixture.review(), original = fixture.snapshot
    switch change {
    case "model": fixture.snapshot.threads[0].model = "new-current-model"
    case "permission": fixture.snapshot.threads[0].permission = .fullAccess
    case "nativeThread": fixture.snapshot.threads[0].providerThreadID = "another-native-thread"
    case "workspace": fixture.snapshot.threads[0].workspacePath = "/tmp/another-workspace"
    case "transcript": fixture.snapshot.threads[0].messages[1].text += " changed"
    default: fixture.snapshot.threads[0].runHistory?[1].turnIDs = ["different-native-boundary"]
    }
    let changed = fixture.snapshot
    #expect(throws: WorkspaceCommandError.self) { try fixture.accept(review) }
    #expect(fixture.snapshot == changed)
    #expect(fixture.snapshot.conversationHistoryOperations == nil)
    #expect(original.conversationHistoryOperations == nil)
}

@Test(arguments: ["busy", "queued", "question", "archived", "settled", "postCheckpoint"])
func conversationHistoryAvailabilityAndAcceptanceRequireAnIdleUngatedSource(blocker: String) throws {
    var fixture = ConversationHistoryFixture(); let review = try fixture.review()
    switch blocker {
    case "busy": fixture.snapshot.threads[0].state = .running
    case "queued": fixture.snapshot.threads[0].queuedTurns = [.init(id: UUID(), text: "Queued intent",
        configuration: .init(thread: fixture.thread), createdAt: fixture.now)]
    case "question": fixture.snapshot.threads[0].runtimeRequests = [.init(request: .init(id: .string("question"),
        method: "item/tool/requestUserInput", params: .object(["questions": .array([])])))]
    case "archived": fixture.snapshot.threads[0].isArchived = true
    case "settled": fixture.snapshot.threads[0].settlement = .init(settledAt: fixture.now)
    default:
        var post = ThreadRunCheckpointAttempt(workspacePath: fixture.thread.workspacePath, phase: .failed, now: fixture.now)
        post.error = ThreadRunCheckpointAttempt.failureMessage
        fixture.snapshot.threads[0].runHistory?[2].checkpoints?.postRun = post
    }
    #expect(!fixture.snapshot.canReviewConversationHistory(threadID: fixture.threadID))
    let blocked = fixture.snapshot
    #expect(throws: WorkspaceCommandError.self) { try fixture.accept(review) }
    #expect(fixture.snapshot == blocked && fixture.snapshot.conversationHistoryOperations == nil)
}

@Test
func conversationHistoryDraftPinAndSelectionChangesKeepReviewValidAndSurviveRewind() throws {
    var fixture = ConversationHistoryFixture(); let review = try fixture.review(.rewindBeforeRun)
    let fingerprint = try fixture.snapshot.historySourceFingerprint(threadID: fixture.threadID)
    try fixture.command(.client(.editThread(fixture.threadID, .draft("A newer unsent draft"))))
    try fixture.command(.client(.editThread(fixture.threadID, .pinned(true))))
    try fixture.command(.client(.selectConversation(threadID: fixture.threadID)))
    fixture.snapshot.threads[0].runtimeID = UUID()
    fixture.snapshot.threads[0].runHistory?[0].checkpoints?.baseline.updatedAt.addTimeInterval(1)
    #expect(try fixture.snapshot.historySourceFingerprint(threadID: fixture.threadID) == fingerprint)
    let attachments = fixture.thread.draftAttachments
    try fixture.accept(review); try fixture.dispatch(review); try fixture.confirm(review)
    #expect(fixture.thread.draft == "A newer unsent draft" && fixture.thread.draftAttachments == attachments)
    #expect(fixture.thread.isPinned)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test
func conversationHistoryForkCreatesASeparateCleanThreadWithSelectedConfigurationAndInheritedProvenance() throws {
    var fixture = ConversationHistoryFixture(); let review = try fixture.review(), source = fixture.thread
    try fixture.accept(review, title: "Target fork"); try fixture.dispatch(review)
    let decision = try fixture.confirm(review)
    let target = try #require(fixture.snapshot.threads.first { $0.id == review.targetThreadID })
    #expect(fixture.thread == source)
    #expect(target.id != source.id && target.projectID == source.projectID)
    #expect(target.title == "Target fork" && target.workspacePath == source.workspacePath)
    #expect(target.model == "captured-model-2" && target.permission == .supervised)
    #expect(target.providerThreadID == "native-fork")
    #expect(target.messages == review.prefix)
    #expect(target.messages.allSatisfy { $0.runReference?.threadID == source.id })
    #expect(target.forkedFromHistoryOperationID == review.id)
    #expect(target.runHistory == nil && target.activeRun == nil && target.runtimeID == nil)
    #expect(target.queuedTurns.isEmpty && target.runtimeRequests.isEmpty)
    #expect(target.workspacePreparation == nil && target.settlement == nil)
    #expect(target.draft.isEmpty && target.draftAttachments.isEmpty)
    #expect(target.providerMetadata == nil && target.providerActivity == nil)
    #expect(decision.effects.isEmpty)
    #expect(fixture.snapshot.conversationHistoryOperations?.first?.phase == .applied)
    #expect(!fixture.snapshot.isConversationHistoryLocked(threadID: fixture.threadID))
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test
func conversationHistoryRewindRetainsEveryAuditRecordAndProjectsOnlyActiveMessages() throws {
    var fixture = ConversationHistoryFixture(); let review = try fixture.review(.rewindBeforeRun), before = fixture.thread
    try fixture.accept(review); try fixture.dispatch(review)
    let decision = try fixture.confirm(review)
    #expect(fixture.thread.messages.count == before.messages.count)
    #expect(fixture.thread.runHistory?.count == before.runHistory?.count)
    #expect(fixture.thread.visibleMessages == review.prefix)
    #expect(fixture.thread.messages.map(\.text) == before.messages.map(\.text))
    #expect(fixture.thread.runHistory?.map(\.checkpoints) == before.runHistory?.map(\.checkpoints))
    for record in fixture.thread.runHistory ?? [] {
        #expect(record.removedByHistoryOperationID == (review.removedRunIDs.contains(record.id) ? review.id : nil))
    }
    for message in fixture.thread.messages {
        #expect(message.removedByHistoryOperationID == (review.removedMessageIDs.contains(message.id) ? review.id : nil))
    }
    #expect(fixture.thread.draft == before.draft && fixture.thread.draftAttachments == before.draftAttachments)
    #expect(fixture.thread.providerThreadID == "native-source")
    #expect(decision.effects.isEmpty)
    #expect(try fixture.thread.transcriptPrefix(runID: fixture.runs[0], boundary: .afterRun) == review.prefix)
    #expect(throws: CoincideError.self) { try fixture.thread.transcriptPrefix(runID: fixture.runs[1], boundary: .afterRun) }
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test
func conversationHistoryNewRunsAfterRewindUseTheVisiblePrefixAndKeepRemovedAudit() throws {
    var fixture = ConversationHistoryFixture(); let review = try fixture.review(.rewindBeforeRun)
    try fixture.accept(review); try fixture.dispatch(review); try fixture.confirm(review)
    let runID = UUID(), runtimeID = UUID()
    try fixture.command(.client(.submit(threadID: fixture.threadID, text: "Explicit post-rewind prompt")), id: runID)
    try fixture.command(.runtimeOpened(threadID: fixture.threadID, runID: runID, runtimeID: runtimeID))
    try fixture.command(.provider(threadID: fixture.threadID, runtimeID: runtimeID,
        event: .context(runID: runID, event: .turn("native-after-rewind"))))
    try fixture.command(.provider(threadID: fixture.threadID, runtimeID: runtimeID,
        event: .context(runID: runID, event: .delta(id: "after-rewind-reply", role: .assistant, text: "New visible reply"))))
    try fixture.command(.provider(threadID: fixture.threadID, runtimeID: runtimeID,
        event: .context(runID: runID, event: .completed(.idle))))
    #expect(fixture.thread.runHistory?.count == 4 && fixture.thread.messages.count == 8)
    #expect(fixture.thread.visibleMessages.map(\.text) == ["Prompt 1", "Reply 1", "Explicit post-rewind prompt", "New visible reply"])
    #expect(try fixture.thread.transcriptPrefix(runID: runID, boundary: .afterRun) == fixture.thread.visibleMessages)
    #expect(try fixture.thread.transcriptPrefix(runID: runID, boundary: .beforeRun) == review.prefix)
    #expect(fixture.thread.runHistory?.filter { $0.removedByHistoryOperationID == review.id }.map(\.id) == review.removedRunIDs)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test
func conversationHistoryRewindRemovesHiddenUserActivityFromProjectSortAndKeepsQueueActivity() throws {
    var fixture = ConversationHistoryFixture()
    let sourceProjectID = fixture.thread.projectID
    let competitor = WorkspaceProject(path: "/tmp/coincide-history-sort-competitor")
    var other = CodingThread(project: competitor)
    var message = ChatMessage(id: "competitor-user", role: .user, text: "Competing activity")
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    message.createdAt = base.addingTimeInterval(5); other.messages = [message]
    fixture.snapshot.projects.append(competitor); fixture.snapshot.threads.append(other)
    #expect(fixture.snapshot.orderedProjects.map(\.id) == [sourceProjectID, competitor.id])
    let review = try fixture.review(.rewindBeforeRun), auditDates = fixture.thread.messages.map(\.createdAt)
    try fixture.accept(review); try fixture.dispatch(review); try fixture.confirm(review)
    #expect(fixture.thread.messages.map(\.createdAt) == auditDates)
    #expect(fixture.thread.messages.count == 6 && fixture.thread.visibleMessages.count == 2)
    #expect(fixture.thread.messages.filter { $0.role == .user && $0.removedByHistoryOperationID == review.id }.count == 2)
    #expect(fixture.thread.updatedAt > message.createdAt)
    #expect(fixture.snapshot.orderedProjects.map(\.id) == [competitor.id, sourceProjectID])
    // Accepted queued intent still contributes activity even while explicitly paused.
    fixture.snapshot.threads[0].queuePaused = true
    fixture.snapshot.threads[0].queuedTurns = [.init(id: UUID(), text: "Accepted queued intent",
        configuration: .init(thread: fixture.thread), createdAt: base.addingTimeInterval(30))]
    #expect(fixture.snapshot.orderedProjects.map(\.id) == [sourceProjectID, competitor.id])
    fixture.snapshot.threads[0].queuedTurns[0].createdAt = base.addingTimeInterval(-1)
    #expect(fixture.snapshot.orderedProjects.map(\.id) == [competitor.id, sourceProjectID])
    fixture.snapshot.threads[0].queuedTurns.removeAll()
    #expect(fixture.snapshot.orderedProjects.map(\.id) == [competitor.id, sourceProjectID])
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test
func conversationHistoryRemovedAuditCannotBeReplacedAppendedOrReassociatedByNewRunEvents() throws {
    var fixture = ConversationHistoryFixture()
    func entityUpdate(_ type: String, id: String, text: String) throws -> ProviderEntityUpdate {
        try .acp(.object(["sessionUpdate": .string(type), "messageId": .string(id),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])]), sessionID: "native-source")
    }
    let oldReply = try entityUpdate("agent_message", id: "removed-provider-reply", text: "Reply 2")
    let oldUser = try entityUpdate("user_message", id: "removed-provider-user", text: "Prompt 2")
    fixture.snapshot.threads[0].messages[2].providerEntity = try oldUser.apply(to: nil)
    fixture.snapshot.threads[0].messages[3].providerEntity = try oldReply.apply(to: nil)
    let review = try fixture.review(.rewindBeforeRun)
    try fixture.accept(review); try fixture.dispatch(review); try fixture.confirm(review)
    let removedMessages = fixture.thread.messages.filter { $0.removedByHistoryOperationID != nil }
    let removedRuns = fixture.thread.runHistory!.filter { $0.removedByHistoryOperationID != nil }
    let removedReplyID = fixture.thread.messages[3].id, removedUserID = fixture.thread.messages[2].id
    let runID = UUID(), runtimeID = UUID()
    try fixture.command(.client(.submit(threadID: fixture.threadID, text: "Active post-rewind turn")), id: runID)
    try fixture.command(.runtimeOpened(threadID: fixture.threadID, runID: runID, runtimeID: runtimeID))
    let currentUserID = try #require(fixture.thread.runHistory?.last?.userMessageID)
    let activeEcho = try entityUpdate("user_message", id: "active-provider-echo", text: "Active echo")
    try fixture.command(.provider(threadID: fixture.threadID, runtimeID: runtimeID,
        event: .context(runID: runID, event: .entity(activeEcho))))
    let staleReplacement = ChatMessage(id: removedReplyID, role: .assistant, text: "Stale replacement")
    let staleEvents: [ProviderEvent] = [
        .message(staleReplacement), .delta(id: removedReplyID, role: .assistant, text: " stale append"),
        .entity(try entityUpdate("agent_message", id: "removed-provider-reply", text: "Stale entity replacement")),
        .associateEntity(activeEcho.key, clientMessageID: removedUserID),
        .associateEntity(oldUser.key, clientMessageID: currentUserID)
    ]
    for event in staleEvents {
        try fixture.command(.provider(threadID: fixture.threadID, runtimeID: runtimeID, event: .context(runID: runID, event: event)))
        #expect(fixture.thread.messages.filter { $0.removedByHistoryOperationID != nil } == removedMessages)
        #expect(fixture.thread.runHistory?.filter { $0.removedByHistoryOperationID != nil } == removedRuns)
        #expect(fixture.thread.messages.contains { $0.providerEntity?.key == activeEcho.key && $0.removedByHistoryOperationID == nil })
    }
    var forged = ChatMessage(id: "active-message-with-forged-audit", role: .assistant, text: "Legitimate active text")
    forged.removedByHistoryOperationID = review.id; forged.runReference = .init(threadID: UUID(), runID: UUID())
    try fixture.command(.provider(threadID: fixture.threadID, runtimeID: runtimeID, event: .context(runID: runID, event: .message(forged))))
    let accepted = try #require(fixture.thread.messages.first { $0.id == forged.id })
    #expect(accepted.text == forged.text && accepted.removedByHistoryOperationID == nil)
    #expect(accepted.runReference == .init(threadID: fixture.threadID, runID: runID))
    #expect(fixture.thread.visibleMessages.contains { $0.id == forged.id })
    #expect(fixture.thread.messages.filter { $0.removedByHistoryOperationID != nil } == removedMessages)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test(arguments: ["submit", "queue", "model", "permission", "workspace", "settle", "archive", "remove"])
func conversationHistoryPendingOperationLocksConflictingActionsButAllowsDrafts(action: String) throws {
    var fixture = ConversationHistoryFixture(); let review = try fixture.review(.rewindBeforeRun)
    try fixture.accept(review)
    let command: WorkspaceCommand
    switch action {
    case "submit": command = .submit(threadID: fixture.threadID, text: "Must remain unsent")
    case "queue": command = .resumeQueue(threadID: fixture.threadID)
    case "model": command = .editThread(fixture.threadID, .model("blocked"))
    case "permission": command = .editThread(fixture.threadID, .permission(.fullAccess))
    case "workspace": command = .editThread(fixture.threadID, .workspacePath("/tmp/blocked"))
    case "settle": command = .settleThread(threadID: fixture.threadID, expectedWorkspacePath: fixture.thread.workspacePath, reviewScript: false)
    case "archive": command = .editThread(fixture.threadID, .archived(true))
    default: command = .removeProject(projectID: fixture.thread.projectID, expectedThreadIDs: [fixture.threadID])
    }
    let accepted = fixture.snapshot
    #expect(throws: WorkspaceCommandError.self) { try fixture.command(.client(command)) }
    #expect(fixture.snapshot == accepted)
    let draft = try fixture.command(.client(.editThread(fixture.threadID, .draft("Still editable"))))
    #expect(fixture.thread.draft == "Still editable" && draft.effects.isEmpty)
}

@Test(arguments: ["acceptedFork", "acceptedRewind", "dispatchingFork", "dispatchingRewind"])
func conversationHistoryRestartNeverReplaysAndOnlyUnconfirmedRewindKeepsItsLock(state: String) throws {
    var fixture = ConversationHistoryFixture()
    let rewind = state.hasSuffix("Rewind"), dispatching = state.hasPrefix("dispatching")
    let review = try fixture.review(rewind ? .rewindBeforeRun : .forkAfterRun)
    try fixture.accept(review)
    if dispatching { try fixture.dispatch(review) }
    let messages = fixture.thread.messages
    fixture.snapshot.recoverInterruptedWork()
    let operation = try #require(fixture.snapshot.conversationHistoryOperations?.first)
    #expect(operation.phase == (dispatching ? .unconfirmed : .failed))
    #expect(operation.error == (dispatching ? ConversationHistoryOperation.unconfirmedMessage : ConversationHistoryOperation.failureMessage))
    #expect(fixture.snapshot.isConversationHistoryLocked(threadID: fixture.threadID) == (dispatching && rewind))
    #expect(fixture.thread.messages == messages)
    #expect(fixture.snapshot.threads.count == 1 && fixture.thread.runHistory?.allSatisfy { $0.removedByHistoryOperationID == nil } == true)
    let recovered = fixture.snapshot
    let late = try fixture.confirm(review)
    #expect(late.snapshot == recovered && late.effects.isEmpty)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test
func conversationHistoryCompletionRequiresDispatchAndExactIncarnationAndIsIdempotent() throws {
    var fixture = ConversationHistoryFixture(); let review = try fixture.review()
    let empty = fixture.snapshot
    let unsolicited = try fixture.confirm(review)
    #expect(unsolicited.snapshot == empty && unsolicited.effects.isEmpty)
    try fixture.accept(review)
    let accepted = fixture.snapshot
    try fixture.confirm(review)
    #expect(fixture.snapshot == accepted)
    try fixture.command(.conversationHistoryDispatching(threadID: fixture.threadID, operationID: review.id, incarnation: UUID()))
    #expect(fixture.snapshot == accepted)
    try fixture.dispatch(review)
    let dispatched = fixture.snapshot
    try fixture.command(.conversationHistoryEffectResult(.conversationHistory(threadID: fixture.threadID, operationID: review.id),
        .conversationHistoryConfirmed(fixture.result(for: review)), incarnation: UUID()))
    #expect(fixture.snapshot == dispatched)
    try fixture.confirm(review)
    let applied = fixture.snapshot
    try fixture.confirm(review)
    #expect(fixture.snapshot == applied && fixture.snapshot.threads.count == 2)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test(arguments: [false, true])
func conversationHistoryExplicitReconciliationResolvesOnlyCurrentUnconfirmedRewind(applied: Bool) throws {
    var fixture = ConversationHistoryFixture(); let review = try fixture.review(.rewindBeforeRun)
    try fixture.accept(review); try fixture.dispatch(review)
    try fixture.command(.conversationHistoryEffectResult(.conversationHistory(threadID: fixture.threadID, operationID: review.id),
        .conversationHistoryUnconfirmed, incarnation: fixture.incarnation))
    #expect(fixture.snapshot.isConversationHistoryLocked(threadID: fixture.threadID))
    let result: ConversationHistoryReconciliation = applied ? .applied(try fixture.result(for: review)) : .unchanged
    // A restored operation retains its old review incarnation. The Engine fences
    // the current reconciliation reader; the reducer accepts that fresh token.
    let decision = try fixture.command(.conversationHistoryReconciled(operationID: review.id, incarnation: UUID(), result: result))
    #expect(!fixture.snapshot.isConversationHistoryLocked(threadID: fixture.threadID))
    #expect(fixture.snapshot.conversationHistoryOperations?.first?.phase == (applied ? .applied : .failed))
    if applied { #expect(fixture.thread.visibleMessages == review.prefix) }
    else {
        #expect(fixture.thread.visibleMessages == fixture.thread.messages)
        #expect(fixture.snapshot.conversationHistoryOperations?.first?.error == ConversationHistoryOperation.unchangedMessage)
    }
    #expect(decision.effects.isEmpty)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test(arguments: [false, true])
func conversationHistoryRecallAppendsToLatestDraftAndDeduplicatesAttachmentsOnlyOnce(attachmentOnly: Bool) throws {
    var fixture = ConversationHistoryFixture()
    let existing = fixture.thread.draftAttachments[0]
    let recalled = ChatAttachment(id: UUID(), name: "recalled.txt", mimeType: "text/plain", byteCount: 5,
                                 digest: String(repeating: "b", count: 64), fileExtension: "txt")
    fixture.snapshot.threads[0].messages[2].attachments = [existing, recalled]
    if attachmentOnly { fixture.snapshot.threads[0].messages[2].text = "" }
    let review = try fixture.review(.rewindBeforeRun)
    try fixture.accept(review); try fixture.dispatch(review); try fixture.confirm(review)
    try fixture.command(.client(.editThread(fixture.threadID, .draft("Latest unsent edits"))))
    let decision = try fixture.command(.client(.recallConversationHistoryPrompt(operationID: review.id)))
    #expect(fixture.thread.draft == (attachmentOnly ? "Latest unsent edits" : "Latest unsent edits\n\nPrompt 2"))
    #expect(fixture.thread.draftAttachments == [existing, recalled])
    #expect(fixture.snapshot.conversationHistoryOperations?.first?.recalledAt == fixture.now)
    #expect(decision.effects.isEmpty && fixture.thread.activeRun == nil && fixture.thread.queuedTurns.isEmpty)
    let once = fixture.snapshot
    let repeated = try fixture.command(.client(.recallConversationHistoryPrompt(operationID: review.id)), id: UUID())
    #expect(fixture.snapshot == once && repeated.effects.isEmpty)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test
func conversationHistoryRecallOverLimitLeavesDraftAttachmentsAndRecallEvidenceUnchanged() throws {
    var fixture = ConversationHistoryFixture()
    let recalled = ChatAttachment(id: UUID(), name: "recalled.txt", mimeType: "text/plain", byteCount: 5,
                                 digest: String(repeating: "b", count: 64), fileExtension: "txt")
    fixture.snapshot.threads[0].messages[2].attachments = [recalled]
    let review = try fixture.review(.rewindBeforeRun)
    try fixture.accept(review); try fixture.dispatch(review); try fixture.confirm(review)
    fixture.snapshot.threads[0].draftAttachments = (0..<AttachmentLimits.count).map { index in
        .init(id: UUID(), name: "existing-\(index).txt", mimeType: "text/plain", byteCount: 1,
              digest: String(repeating: "a", count: 64), fileExtension: "txt")
    }
    let before = fixture.snapshot
    #expect(throws: WorkspaceCommandError.self) { try fixture.command(.client(.recallConversationHistoryPrompt(operationID: review.id))) }
    #expect(fixture.snapshot == before)
    #expect(fixture.snapshot.conversationHistoryOperations?.first?.recalledAt == nil)
    #expect(fixture.thread.activeRun == nil && fixture.thread.queuedTurns.isEmpty)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test
func conversationHistoryLegacySnapshotDefaultsDoNotInventAnOperationOrRemoval() throws {
    let fixture = ConversationHistoryFixture()
    let data = try JSONEncoder().encode(fixture.snapshot)
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    #expect(decoded.conversationHistoryOperations == nil)
    #expect(decoded.threads[0].forkedFromHistoryOperationID == nil)
    #expect(decoded.threads[0].messages.allSatisfy { $0.removedByHistoryOperationID == nil })
    #expect(decoded.threads[0].runHistory?.allSatisfy { $0.removedByHistoryOperationID == nil } == true)
    #expect(decoded.threads[0].visibleMessages == decoded.threads[0].messages)
    #expect(decoded == fixture.snapshot)
    try WorkspaceJournal.validate(decoded)
}

@Test(arguments: ["message", "run", "fork", "foreign"])
func conversationHistoryJournalRejectsUnprovenRemovalAndForeignProvenance(kind: String) throws {
    var fixture = ConversationHistoryFixture()
    switch kind {
    case "message": fixture.snapshot.threads[0].messages[0].removedByHistoryOperationID = UUID()
    case "run": fixture.snapshot.threads[0].runHistory?[0].removedByHistoryOperationID = UUID()
    case "fork": fixture.snapshot.threads[0].forkedFromHistoryOperationID = UUID()
    default: fixture.snapshot.threads[0].messages[0].runReference = .init(threadID: UUID(), runID: fixture.runs[0])
    }
    #expect(throws: CoincideError.self) { try WorkspaceJournal.validate(fixture.snapshot) }
}

@Test
func conversationHistoryAppliedForkProvenanceIsValidatedAndAuditSurvivesSourceRemoval() throws {
    var fixture = ConversationHistoryFixture(); let review = try fixture.review()
    try fixture.accept(review); try fixture.dispatch(review); try fixture.confirm(review)
    let applied = fixture.snapshot, targetID = try #require(review.targetThreadID)
    let targetIndex = try #require(fixture.snapshot.threads.firstIndex { $0.id == targetID })
    fixture.snapshot.threads[targetIndex].messages[0].runReference = .init(threadID: fixture.threadID, runID: fixture.runs[2])
    #expect(throws: CoincideError.self) { try WorkspaceJournal.validate(fixture.snapshot) }
    fixture.snapshot = applied
    let sourceID = fixture.threadID
    fixture.snapshot.threads.removeAll { $0.id == sourceID }
    try WorkspaceJournal.validate(fixture.snapshot)
    #expect(fixture.snapshot.conversationHistoryOperations?.first?.review == review)
    #expect(fixture.snapshot.threads.first?.messages == review.prefix)
}

@Test
func conversationHistoryOperationAndTargetIdentitiesCannotBeReused() throws {
    var fixture = ConversationHistoryFixture(); let review = try fixture.review()
    try fixture.accept(review); try fixture.dispatch(review); try fixture.confirm(review)
    let applied = fixture.snapshot
    #expect(throws: WorkspaceCommandError.self) { try fixture.accept(review) }
    #expect(fixture.snapshot == applied)
    let collision = try fixture.review(targetThreadID: review.targetThreadID)
    #expect(throws: WorkspaceCommandError.self) { try fixture.accept(collision) }
    #expect(fixture.snapshot == applied)
    let duplicate = try #require(fixture.snapshot.conversationHistoryOperations?.first)
    fixture.snapshot.conversationHistoryOperations?.append(duplicate)
    #expect(throws: CoincideError.self) { try WorkspaceJournal.validate(fixture.snapshot) }
}

@Test(arguments: ["createTarget", "createOperation", "atomicTarget", "atomicOperation", "cloneTarget", "cloneOperation"])
func conversationHistoryAcceptedForkReservesIdentitiesBeforeEveryThreadCreationAdmission(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-history-admission-\(UUID())", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    var fixture = ConversationHistoryFixture(); let review = try fixture.review()
    try fixture.accept(review)
    let targetID = try #require(review.targetThreadID)
    let reserved = kind.hasSuffix("Operation") ? review.id : targetID
    let command: WorkspaceCommand
    if kind.hasPrefix("create") {
        var thread = CodingThread(project: fixture.snapshot.projects[0]); thread.id = reserved
        command = .createThread(thread)
    } else if kind.hasPrefix("atomic") {
        let project = WorkspaceProject(path: root.appendingPathComponent("another-project").path)
        var thread = CodingThread(project: project); thread.id = reserved
        command = .addProjectWithThread(project: project, thread: thread)
    } else {
        let attempt = UUID()
        let plan = GitClonePlan(id: attempt, source: "https://example.invalid/history-fixture.git",
            destinationPath: root.appendingPathComponent("clone").path,
            stagingPath: root.appendingPathComponent(".coincide-clone-" + attempt.uuidString.lowercased()).path)
        var project = WorkspaceProject(path: plan.destinationPath); project.clone = .init(plan: plan, now: fixture.now)
        var thread = CodingThread(project: project); thread.id = reserved
        command = .startProjectClone(project: project, thread: thread)
    }
    let accepted = fixture.snapshot
    #expect(throws: WorkspaceCommandError.self) { try fixture.command(.client(command)) }
    #expect(fixture.snapshot == accepted)
    #expect(fixture.snapshot.conversationHistoryOperations?.count == 1 && fixture.snapshot.threads.count == 1)
    let unrelated = CodingThread(project: fixture.snapshot.projects[0])
    let decision = try fixture.command(.client(.createThread(unrelated)))
    #expect(decision.effects.isEmpty)
    #expect(fixture.snapshot.threads.contains { $0.id == unrelated.id })
    #expect(fixture.snapshot.conversationHistoryOperations?.first?.phase == .accepted)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test
func conversationHistoryReviewRejectsAnUnboundedTranscriptBeforeAcceptance() throws {
    let fixture = ConversationHistoryFixture()
    var prefix = try fixture.thread.transcriptPrefix(runID: fixture.runs[1], boundary: .afterRun)
    prefix[0].text = String(repeating: "a", count: 4 * 1_024 * 1_024)
    #expect(throws: (any Error).self) { try fixture.review(prefix: prefix) }
}

@Test(arguments: ["fingerprint", "provider", "boundary", "head", "workspace", "removedPrefix"])
func conversationHistoryReviewValidatesDecodedEvidenceBeforeItCanBecomeDurable(change: String) throws {
    let fixture = ConversationHistoryFixture(), review = try fixture.review()
    let encoded = try JSONEncoder().encode(review)
    #expect(try JSONDecoder().decode(ConversationHistoryReview.self, from: encoded) == review)
    var object = try #require(JSONDecoder().decode(JSONValue.self, from: encoded).object)
    switch change {
    case "fingerprint": object["sourceFingerprint"] = .string("not-a-digest")
    case "provider":
        var reference = try #require(object["sourceReference"]?.object)
        reference["provider"] = .string("claude"); object["sourceReference"] = .object(reference)
    case "boundary": object["boundary"] = .object(["kind": .string("head")])
    case "head": object["expectedResultHeadTurnID"] = .string("another-native-head")
    case "workspace":
        var configuration = try #require(object["targetConfiguration"]?.object)
        configuration["workspacePath"] = .string("/tmp/another-workspace"); object["targetConfiguration"] = .object(configuration)
    default:
        var prefix = try #require(object["prefix"]?.array)
        var message = try #require(prefix[0].object)
        message["removedByHistoryOperationID"] = .string(UUID().uuidString)
        prefix[0] = .object(message); object["prefix"] = .array(prefix)
    }
    let invalidData = try JSONEncoder().encode(JSONValue.object(object))
    #expect(throws: (any Error).self) {
        let decoded = try JSONDecoder().decode(ConversationHistoryReview.self, from: invalidData)
        try decoded.validate()
    }
}

@Test
func conversationHistoryJournalReplayRetainsOperationsAndRemovalMarkersWithoutTextAppendLoss() throws {
    var fixture = ConversationHistoryFixture(); let initial = fixture.snapshot
    let review = try fixture.review(.rewindBeforeRun)
    try fixture.accept(review); let accepted = fixture.snapshot
    try fixture.dispatch(review); let dispatched = fixture.snapshot
    try fixture.confirm(review); let applied = fixture.snapshot
    var rebuilt = initial
    for expected in [accepted, dispatched, applied] {
        for event in try WorkspaceJournal.changes(from: rebuilt, to: expected) { try event.apply(to: &rebuilt) }
        try WorkspaceJournal.validate(rebuilt)
        #expect(rebuilt == expected)
    }
    #expect(rebuilt.threads[0].messages.count == initial.threads[0].messages.count)
    #expect(rebuilt.threads[0].visibleMessages == review.prefix)
}

@Test
func conversationHistoryIntentAndOutboxRollbackTogetherAndRebuildAfterCommit() async throws {
    let root = try conversationHistoryTemporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: url)
    var fixture = ConversationHistoryFixture(); let initial = fixture.snapshot
    try await database.save(initial, event: "fixture")
    let count = try await database.journalEventCount(), commandID = UUID(), review = try fixture.review()
    let decision = try fixture.accept(review)
    try conversationHistorySQL(url, "CREATE TRIGGER fail_history BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'fixture rejection'); END")
    await #expect(throws: (any Error).self) {
        try await database.commit(decision.snapshot, event: "conversation.history.accepted", commandID: commandID, effects: decision.effects)
    }
    #expect(try await database.load() == initial)
    #expect(try await database.receipt(commandID) == nil)
    #expect(try await database.effects().isEmpty)
    #expect(try await database.journalEventCount() == count)
    try conversationHistorySQL(url, "DROP TRIGGER fail_history")
    let receipt = try await database.commit(decision.snapshot, event: "conversation.history.accepted", commandID: commandID, effects: decision.effects)
    #expect(receipt.rejection == nil)
    #expect(try await database.effects().map(\.request) == decision.effects.map(\.request))
    try fixture.dispatch(review)
    try await database.save(fixture.snapshot, event: "conversation.history.dispatching")
    try fixture.confirm(review)
    try await database.save(fixture.snapshot, event: "conversation.history.applied")
    #expect(try await database.rebuildProjection().snapshot == fixture.snapshot)
    let restarted = try WorkspaceDatabase(url: url)
    #expect(try await restarted.load() == fixture.snapshot)
    #expect(try await restarted.cancelEffectsAfterProcessLoss().count == 1)
    #expect(try await restarted.claimNextEffect(workerID: UUID()) == nil)
}

private func conversationHistorySQL(_ url: URL, _ statement: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw CoincideError("History fixture database could not open.") }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw CoincideError("History fixture SQL failed.") }
}

private func conversationHistoryTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-history-journal-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Includes a valid, unrelated provider-history proof while recovering another
/// conversation. This exercises the same history-readiness type path as the
/// hosted crash without starting any Git/provider process or changing stacks.
private func recoveredWorktreeHistoryFixture() throws -> (snapshot: WorkspaceSnapshot, threadID: UUID,
    request: GitWorktreeRequest, result: GitWorktreeResult, queued: QueuedTurn, now: Date) {
    var history = ConversationHistoryFixture()
    let review = try history.review()
    _ = try history.accept(review)
    let project = try #require(history.snapshot.projects.first)
    var thread = CodingThread(project: project, model: "recovery-model")
    thread.checkpointPolicy = .disabled
    let request = GitWorktreeRequest(sourcePath: project.path, destinationRoot: "/tmp/coincide-pure-recovery-worktrees",
        selection: .createBranch(name: "reviewed-recovery", baseRef: "HEAD"))
    let identity = GitWorktreeNodeIdentity(device: 1, inode: 42)
    let plan = try GitWorktreePlan(request: request, sourcePath: project.path, commonDirectoryPath: project.path + "/.git",
        sourceIdentity: identity, commonDirectoryIdentity: identity, destinationParentIdentity: identity,
        branch: "reviewed-recovery", baseCommit: String(repeating: "a", count: 40))
    var preparation = ThreadWorkspacePreparation(request: request, now: history.now)
    preparation.plan = plan; preparation.phase = .failed; preparation.error = "Private publication response was lost"
    preparation.endedAt = history.now
    thread.workspacePreparation = preparation; thread.workspacePath = request.destinationPath
    thread.draft = "Newer unsent typing stays separate"
    thread.draftAttachments = [.init(id: UUID(), name: "newer.txt", mimeType: "text/plain", byteCount: 5,
        digest: String(repeating: "b", count: 64), fileExtension: "txt")]
    let queued = QueuedTurn(id: UUID(), text: "Original accepted input", configuration: .init(thread: thread),
        createdAt: history.now, attachments: history.thread.draftAttachments, checkpointPolicy: .disabled)
    thread.queuedTurns = [queued]; thread.queuePaused = true
    history.snapshot.threads.append(thread)
    try WorkspaceJournal.validate(history.snapshot)
    return (history.snapshot, thread.id, request,
        .init(destinationPath: request.destinationPath, headCommit: plan.baseCommit, branch: plan.branch), queued, history.now)
}

@Test func worktreeRecoveredPreservesPausedQueueAndProviderHistoryUntilExplicitResumeWithoutReplay() throws {
    let f = try recoveredWorktreeHistoryFixture()
    let before = try #require(f.snapshot.threads.first(where: { $0.id == f.threadID }))
    let recovery = EngineCommand.worktreeRecovered(threadID: f.threadID, attemptID: f.request.id,
        incarnation: UUID(), result: f.result)
    let recovered = try WorkspaceDecision.make(recovery, id: UUID(), snapshot: f.snapshot, now: f.now)
    let waiting = try #require(recovered.snapshot.threads.first(where: { $0.id == f.threadID }))
    #expect(waiting.workspacePreparation?.isReady == true && waiting.workspacePreparation?.result == f.result)
    #expect(recovered.snapshot.providerReady(for: waiting))
    #expect(waiting.queuePaused && waiting.queuedTurns == [f.queued] && waiting.activeRun == nil && waiting.messages.isEmpty)
    #expect(waiting.draft == before.draft && waiting.draftAttachments == before.draftAttachments)
    #expect(recovered.snapshot.conversationHistoryOperations == f.snapshot.conversationHistoryOperations)
    #expect(recovered.snapshot.threads.filter { $0.id != f.threadID } == f.snapshot.threads.filter { $0.id != f.threadID })
    #expect(recovered.effects.isEmpty)
    let repeated = try WorkspaceDecision.make(recovery, id: UUID(), snapshot: recovered.snapshot, now: f.now.addingTimeInterval(1))
    #expect(repeated.snapshot == recovered.snapshot && repeated.effects.isEmpty)

    let resumed = try WorkspaceDecision.make(.client(.resumeQueue(threadID: f.threadID)), id: UUID(),
        snapshot: recovered.snapshot, now: f.now.addingTimeInterval(2))
    let running = try #require(resumed.snapshot.threads.first(where: { $0.id == f.threadID }))
    #expect(!running.queuePaused && running.queuedTurns.isEmpty && running.activeRun?.id == f.queued.id)
    #expect(running.messages.filter { $0.role == .user }.map(\.text) == [f.queued.text])
    #expect(running.messages.first?.attachments == f.queued.attachments)
    #expect(running.draft == before.draft && running.draftAttachments == before.draftAttachments)
    #expect(resumed.effects.count == 1)
    if case .providerStart(let thread, let run, let configuration, let text, let attachments) = resumed.effects[0].request {
        #expect(thread == f.threadID && run == f.queued.id && configuration == f.queued.configuration)
        #expect(text == f.queued.text && attachments == f.queued.attachments)
    } else { Issue.record("Explicit Resume must admit only the original captured provider input.") }
    let lateRecovery = try WorkspaceDecision.make(recovery, id: UUID(), snapshot: resumed.snapshot, now: f.now.addingTimeInterval(3))
    #expect(lateRecovery.snapshot == resumed.snapshot && lateRecovery.effects.isEmpty)
}

@Test func worktreeRecoveredStillPermitsSubsequentUnpausedNativeTurnsWithOriginalHistoryRetained() throws {
    let f = try recoveredWorktreeHistoryFixture()
    var current = try WorkspaceDecision.make(.worktreeRecovered(threadID: f.threadID, attemptID: f.request.id,
        incarnation: UUID(), result: f.result), id: UUID(), snapshot: f.snapshot, now: f.now).snapshot
    current = try WorkspaceDecision.make(.client(.resumeQueue(threadID: f.threadID)), id: UUID(), snapshot: current, now: f.now).snapshot
    let runtime = UUID()
    current = try WorkspaceDecision.make(.runtimeOpened(threadID: f.threadID, runID: f.queued.id, runtimeID: runtime),
        id: UUID(), snapshot: current, now: f.now).snapshot
    current = try WorkspaceDecision.make(.provider(threadID: f.threadID, runtimeID: runtime,
        event: .context(runID: f.queued.id, event: .completed(.idle))), id: UUID(), snapshot: current,
        now: f.now.addingTimeInterval(1)).snapshot
    let finished = try #require(current.threads.first(where: { $0.id == f.threadID }))
    #expect(finished.activeRun == nil && finished.queuedTurns.isEmpty)
    let nextID = UUID()
    let next = try WorkspaceDecision.make(.client(.submit(threadID: f.threadID, text: "A later explicit input")),
        id: nextID, snapshot: current, now: f.now.addingTimeInterval(2))
    let thread = try #require(next.snapshot.threads.first(where: { $0.id == f.threadID }))
    #expect(thread.activeRun?.id == nextID && !thread.queuePaused && thread.queuedTurns.isEmpty)
    #expect(thread.messages.filter { $0.role == .user }.map(\.text) == [f.queued.text, "A later explicit input"])
    #expect(thread.runHistory?.filter { $0.id == f.queued.id }.count == 1)
    #expect(next.snapshot.conversationHistoryOperations == f.snapshot.conversationHistoryOperations)
    #expect(next.effects.count == 1)
    if case .providerStart(let owner, let run, _, let text, _) = next.effects[0].request {
        #expect(owner == f.threadID && run == nextID && text == "A later explicit input")
    } else { Issue.record("A later explicit input should use normal native admission.") }
}
