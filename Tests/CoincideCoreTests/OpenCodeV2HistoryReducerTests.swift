import Foundation
import Testing
@testable import CoincideCore

private struct OpenCodeHistoryReducerFixture {
    var snapshot = WorkspaceSnapshot()
    let incarnation = UUID()
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let runs = (0..<3).map { _ in UUID() }
    var native: OpenCodeV2HistorySnapshot
    var thread: CodingThread { snapshot.threads[0] }
    init() throws {
        let project = WorkspaceProject(path: "/fixture/opencode-history")
        var thread = CodingThread(project: project)
        thread.provider = .opencode; thread.openCodeConfiguration = .init(executable: "/fixture/opencode")
        thread.providerThreadID = "ses_source"; thread.permission = .auto; thread.checkpointPolicy = .disabled
        thread.draft = "Latest unsent draft 😀"; thread.isPinned = true
        let identity = thread.openCodeConfiguration!.runtimeIdentity
        var messages: [OpenCodeV2HistoryMessage] = []
        for (index, runID) in runs.enumerated() {
            var configuration = ProviderConfiguration(thread: thread); configuration.permission = .supervised
            let inputID = OpenCodeV2HistoryRunInput.openingMessageID(instanceID: identity.instanceID, runID: runID)
            let active = ActiveRun(id: runID, configuration: configuration, startedAt: now, nativeTurnID: inputID)
            let userID = "user-\(runID)"
            var record = ThreadRunRecord(run: active, origin: .user, userMessageID: userID)
            record.status = .completed; record.endedAt = now; record.endReason = .providerCompleted; record.messageAttributionVersion = 1
            if thread.runHistory == nil { thread.runHistory = [] }; thread.runHistory?.append(record)
            var user = ChatMessage(id: userID, role: .user, text: "Prompt \(index)")
            var reply = ChatMessage(id: "reply-\(runID)", role: .assistant, text: "Reply \(index)")
            user.runReference = .init(threadID: thread.id, runID: runID); reply.runReference = user.runReference
            thread.messages += [user, reply]
            messages.append(try .init(id: inputID, kind: .user, contentDigest: String(repeating: String(index + 1), count: 64)))
            messages.append(try .init(id: "msg_reply_\(index)", kind: .assistant, contentDigest: String(repeating: String(index + 4), count: 64)))
        }
        native = try .init(reference: .init(provider: .opencode, nativeThreadID: "ses_source"),
                           runtimeIdentity: identity, workspacePath: project.path, messages: messages)
        snapshot.projects = [project]; snapshot.threads = [thread]
    }
    func review(_ kind: ConversationHistoryKind = .rewindBeforeRun, index: Int = 1,
                evidence replacement: OpenCodeV2HistoryReviewEvidence? = nil) throws -> ConversationHistoryReview {
        let evidence = try replacement ?? .make(source: native, snapshot: snapshot, thread: thread, runID: runs[index], kind: kind)
        let prefix = try thread.transcriptPrefix(runID: runs[index], boundary: kind == .forkAfterRun ? .afterRun : .beforeRun)
        let prefixIDs = Set(prefix.map(\.id))
        return try .init(kind: kind, reviewedAt: now, sourceThreadID: thread.id, projectID: thread.projectID,
            runID: runs[index], sourceIncarnation: incarnation, sourceConfiguration: .init(thread: thread),
            targetConfiguration: thread.runHistory![index].configuration, sourceReference: native.reference,
            reviewedHeadTurnID: nil, boundary: evidence.boundary, expectedResultHeadTurnID: nil,
            prefix: prefix, removedRunIDs: kind == .rewindBeforeRun ? Array(runs[index...]) : [],
            removedMessageIDs: kind == .rewindBeforeRun ? thread.visibleMessages.filter { !prefixIDs.contains($0.id) }.map(\.id) : [],
            sourceFingerprint: snapshot.historySourceFingerprint(threadID: thread.id),
            targetThreadID: kind == .forkAfterRun ? UUID() : nil, suggestedTitle: "Native message fork", openCodeV2: evidence)
    }
    @discardableResult mutating func command(_ command: EngineCommand) throws -> WorkspaceDecision {
        now.addTimeInterval(1)
        let decision = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: now)
        snapshot = decision.snapshot; return decision
    }
    mutating func begin(_ review: ConversationHistoryReview, uncertain: Bool = false) throws {
        try command(.conversationHistoryAccepted(review: review, title: nil))
        try command(.conversationHistoryDispatching(threadID: thread.id, operationID: review.id, incarnation: incarnation))
        if uncertain {
            try command(.conversationHistoryEffectResult(.conversationHistory(threadID: thread.id, operationID: review.id),
                .conversationHistoryUnconfirmed, incarnation: incarnation))
        }
    }
    func result(_ review: ConversationHistoryReview) throws -> ProviderConversationSnapshot {
        let evidence = try #require(review.openCodeV2), retained = Array(native.messages.prefix(evidence.retainedMessageCount))
        let forked = review.kind == .forkAfterRun
        let items = try forked ? retained.enumerated().map { index, item in
            try OpenCodeV2HistoryMessage(id: "msg_remapped_\(index)", kind: item.kind, contentDigest: item.contentDigest,
                                        isSettled: item.isSettled, idleOutcome: item.idleOutcome)
        } : retained
        let ancestry: ProviderHistoryBoundary
        if forked, review.boundary == .head {
            ancestry = .throughMessage(try #require(native.messages.last).id)
        } else { ancestry = review.boundary }
        let proof = try OpenCodeV2HistorySnapshot(reference: .init(provider: .opencode, nativeThreadID: forked ? "ses_fork" : "ses_source"),
            runtimeIdentity: native.runtimeIdentity, workspacePath: native.workspacePath, messages: items,
            fork: forked ? .init(sourceSessionID: "ses_source", boundary: ancestry) : nil)
        return try .init(reference: proof.reference, workspacePath: proof.workspacePath, historyMode: .messageOrdered, openCodeV2: proof)
    }
    func staged(_ review: ConversationHistoryReview, files: OpenCodeV2HistoryStage.FilesState = .empty) throws -> OpenCodeV2HistorySnapshot {
        let opening = try #require(review.openCodeV2?.selectedOpeningMessageID)
        return try .init(reference: native.reference, runtimeIdentity: native.runtimeIdentity, workspacePath: native.workspacePath,
                         messages: native.messages, stage: .init(messageID: opening, files: files))
    }
    func cleared(_ expected: OpenCodeV2HistorySnapshot, suffix: String = "clear_done") throws -> OpenCodeV2HistorySnapshot {
        let idle = try OpenCodeV2HistoryMessage(id: "msg_" + suffix, kind: .idle, contentDigest: String(repeating: "e", count: 64), idleOutcome: "succeeded")
        let receipt = try OpenCodeV2HistoryMaintenanceReceipt(priorInventoryDigest: expected.inventoryDigest,
            startEventID: "evt_clear_started", terminalEventID: "evt_" + suffix, idleMessageID: idle.id)
        return try .init(reference: expected.reference, runtimeIdentity: expected.runtimeIdentity, workspacePath: expected.workspacePath,
                         messages: expected.messages + [idle], maintenance: receipt)
    }
    func alias(capture: String = "header") -> CodingThread {
        var alias = CodingThread(project: snapshot.projects[0]); alias.checkpointPolicy = .disabled
        let configuration = ProviderConfiguration(thread: thread)
        if capture == "header" {
            alias.provider = .opencode; alias.openCodeConfiguration = thread.openCodeConfiguration
            alias.providerThreadID = thread.providerThreadID
        } else {
            alias.provider = .claude; alias.providerThreadID = "claude_different_session"
            if capture == "queued" {
                alias.queuedTurns = [.init(id: UUID(), text: "Captured OpenCode input", configuration: configuration, createdAt: now)]
            } else {
                var launch = configuration; launch.nativeThreadID = nil
                let run = ActiveRun(id: UUID(), configuration: launch, startedAt: now)
                alias.activeRun = run; alias.state = .running
                var record = ThreadRunRecord(run: run, origin: .agent)
                record.providerThreadID = thread.providerThreadID; alias.runHistory = [record]
            }
        }
        return alias
    }
}

@Test(arguments: ["create", "project", "clone"])
func openCodeV2HistoryHeldStageRejectsNewNativeSessionAliases(action: String) throws {
    var fixture = try OpenCodeHistoryReducerFixture(); let review = try fixture.review()
    try fixture.begin(review, uncertain: true)
    let alias = fixture.alias(), source = fixture.snapshot
    let command: WorkspaceCommand = switch action {
    case "project": .addProjectWithThread(project: fixture.snapshot.projects[0], thread: alias)
    case "clone": .startProjectClone(project: fixture.snapshot.projects[0], thread: alias)
    default: .createThread(alias)
    }
    var decision = WorkspaceDecision(snapshot: source)
    #expect(throws: WorkspaceCommandError.self) { try decision.validateConversationHistoryLocks(command) }
    #expect(decision.snapshot == source && decision.effects.isEmpty)
    #expect(throws: WorkspaceCommandError.self) { try fixture.command(.client(command)) }
    #expect(fixture.snapshot == source)
    var separate = alias; separate.providerThreadID = "ses_separate"
    try decision.validateConversationHistoryLocks(.createThread(separate))
    separate.providerThreadID = alias.providerThreadID
    separate.openCodeConfiguration = .init(executable: "/fixture/separate-opencode")
    try decision.validateConversationHistoryLocks(.createThread(separate))
    #expect(source.isOpenCodeV2HistoryScopeLocked(configuration: .init(thread: alias), nativeThreadID: alias.providerThreadID))
    #expect(!source.isOpenCodeV2HistoryScopeLocked(configuration: .init(thread: separate), nativeThreadID: separate.providerThreadID))
    #expect(!source.isOpenCodeV2HistoryScopeLocked(configuration: .init(thread: alias), nativeThreadID: alias.providerThreadID, excludingOperationID: review.id))
}

@Test(arguments: ["header", "active", "queued"])
func openCodeV2HistoryHeldScopeBlocksAliasInputAndAutomaticFIFOWhileKeepingDraftPinAndTitle(capture: String) throws {
    var fixture = try OpenCodeHistoryReducerFixture(); let review = try fixture.review()
    try fixture.begin(review, uncertain: true)
    let alias = fixture.alias(capture: capture)
    fixture.snapshot.threads.append(alias)
    let held = fixture.snapshot
    #expect(held.isConversationHistoryLocked(threadID: alias.id) && !held.providerReady(for: alias))
    for command in [WorkspaceCommand.submit(threadID: alias.id, text: "Must remain unsent"), .resumeQueue(threadID: alias.id)] {
        #expect(throws: WorkspaceCommandError.self) { try fixture.command(.client(command)) }
        #expect(fixture.snapshot == held)
    }
    if capture == "queued" {
        var decision = WorkspaceDecision(snapshot: held), candidate = alias
        decision.startNext(in: &candidate, now: fixture.now)
        #expect(candidate == alias && decision.effects.isEmpty && decision.snapshot == held)
    }
    for edit in [ThreadEdit.draft("Latest draft 😀"), .pinned(true), .title("Preserved alias")] {
        let decision = try fixture.command(.client(.editThread(alias.id, edit)))
        #expect(decision.effects.isEmpty)
    }
    let latest = try #require(fixture.snapshot.threads.first { $0.id == alias.id })
    #expect(latest.draft == "Latest draft 😀" && latest.isPinned && latest.title == "Preserved alias")
    #expect(latest.activeRun == alias.activeRun && latest.queuedTurns == alias.queuedTurns)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test(arguments: ["header", "active", "queued"])
func openCodeV2HistoryRejectsOtherCapturedSessionOwnersBeforeAcceptance(capture: String) throws {
    var fixture = try OpenCodeHistoryReducerFixture(); let review = try fixture.review()
    fixture.snapshot.threads.append(fixture.alias(capture: capture))
    let source = fixture.snapshot
    #expect(throws: WorkspaceCommandError.self) { try fixture.command(.conversationHistoryAccepted(review: review, title: nil)) }
    #expect(fixture.snapshot == source && fixture.snapshot.conversationHistoryOperations == nil)
}

@Test(arguments: [ConversationHistoryKind.forkAfterRun, .rewindBeforeRun], [0, 1, 2])
func openCodeV2HistoryReducerAppliesWholeRunCutsAndPreservesSourceDraftSettingsAndAudit(kind: ConversationHistoryKind, index: Int) throws {
    var fixture = try OpenCodeHistoryReducerFixture()
    let source = fixture.thread, review = try fixture.review(kind, index: index)
    #expect(review.reviewedHeadTurnID == nil && review.expectedResultHeadTurnID == nil)
    try fixture.begin(review)
    let result = try fixture.result(review)
    let threadID = source.id
    try fixture.command(.conversationHistoryEffectResult(.conversationHistory(threadID: threadID, operationID: review.id),
        .conversationHistoryConfirmed(result), incarnation: fixture.incarnation))
    #expect(fixture.snapshot.conversationHistoryOperation(review.id)?.phase == .applied)
    if kind == .forkAfterRun {
        #expect(fixture.thread == source)
        let target = try #require(fixture.snapshot.threads.first { $0.id == review.targetThreadID })
        #expect(target.providerThreadID == "ses_fork" && target.visibleMessages == review.prefix)
        #expect(target.permission == .supervised && target.draft.isEmpty && target.runHistory == nil)
        if review.boundary == .head {
            let expectedHead = try #require(fixture.native.messages.last).id
            #expect(result.openCodeV2?.fork?.boundary == .throughMessage(expectedHead))
            #expect(throws: (any Error).self) { try OpenCodeV2HistoryFork(sourceSessionID: "ses_source", boundary: .head) }
        }
    } else {
        #expect(fixture.thread.visibleMessages == review.prefix && fixture.thread.messages.count == source.messages.count)
        #expect(fixture.thread.runHistory?.count == 3 && fixture.thread.activeHistoryRuns.count == index)
        #expect(fixture.thread.draft == source.draft && fixture.thread.permission == .auto && fixture.thread.isPinned)
        #expect(fixture.thread.runHistory?.map(\.turnIDs) == source.runHistory?.map(\.turnIDs))
    }
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test(arguments: ["all", "one", "removedSuffix"])
func openCodeV2HistoryForkRejectsReusedSourceMessageIDsEvenWithCorrectContentAndAncestry(reuse: String) throws {
    var fixture = try OpenCodeHistoryReducerFixture()
    let review = try fixture.review(.forkAfterRun), evidence = try #require(review.openCodeV2)
    let valid = try #require(fixture.result(review).openCodeV2)
    var items = valid.messages
    for index in items.indices where reuse == "all" || index == items.count - 1 {
        let item = items[index]
        let reusedID = reuse == "removedSuffix" ? try #require(fixture.native.messages.last).id : fixture.native.messages[index].id
        items[index] = try .init(id: reusedID, kind: item.kind, contentDigest: item.contentDigest,
                                 isSettled: item.isSettled, idleOutcome: item.idleOutcome)
    }
    let forged = try OpenCodeV2HistorySnapshot(reference: valid.reference, runtimeIdentity: valid.runtimeIdentity,
        workspacePath: valid.workspacePath, messages: items, fork: valid.fork)
    #expect(forged.contentDigest == valid.contentDigest && forged.fork == valid.fork)
    #expect(throws: ProviderHistoryError.self) { try evidence.validateResult(forged, kind: .forkAfterRun) }
    try fixture.begin(review)
    let result = try ProviderConversationSnapshot(reference: forged.reference, workspacePath: forged.workspacePath,
                                                 historyMode: .messageOrdered, openCodeV2: forged)
    try fixture.command(.conversationHistoryEffectResult(.conversationHistory(threadID: fixture.thread.id, operationID: review.id),
        .conversationHistoryConfirmed(result), incarnation: fixture.incarnation))
    #expect(fixture.snapshot.conversationHistoryOperation(review.id)?.phase == .unconfirmed)
    #expect(!fixture.snapshot.threads.contains { $0.id == review.targetThreadID })
}

@Test func openCodeV2HistoryReducerRejectsForgedLocalOwnershipAndNativeTurnShapedReview() throws {
    var fixture = try OpenCodeHistoryReducerFixture()
    let correct = try fixture.review(), source = try #require(correct.openCodeV2)
    var inputs = source.inputs
    inputs[2] = .init(runID: UUID(), openingMessageID: inputs[2].openingMessageID)
    let forged = try OpenCodeV2HistoryReviewEvidence(source: source.source, boundary: source.boundary,
        retainedMessageCount: source.retainedMessageCount, selectedOpeningMessageID: source.selectedOpeningMessageID, inputs: inputs)
    let review = try fixture.review(evidence: forged), unchanged = fixture.snapshot
    #expect(throws: (any Error).self) { try fixture.command(.conversationHistoryAccepted(review: review, title: nil)) }
    #expect(fixture.snapshot == unchanged)
    #expect(throws: (any Error).self) {
        try ConversationHistoryReview(kind: correct.kind, sourceThreadID: correct.sourceThreadID, projectID: correct.projectID,
            runID: correct.runID, sourceIncarnation: correct.sourceIncarnation, sourceConfiguration: correct.sourceConfiguration,
            targetConfiguration: correct.targetConfiguration, sourceReference: correct.sourceReference,
            reviewedHeadTurnID: "msg_not_a_native_turn", boundary: correct.boundary, expectedResultHeadTurnID: nil,
            prefix: correct.prefix, removedRunIDs: correct.removedRunIDs, removedMessageIDs: correct.removedMessageIDs,
            sourceFingerprint: correct.sourceFingerprint, targetThreadID: nil, suggestedTitle: correct.suggestedTitle, openCodeV2: source)
    }
}

@Test func openCodeV2HistoryReducerClearRequiresExactStageAndDoesNotApplyRewindOrRecall() throws {
    var fixture = try OpenCodeHistoryReducerFixture(); let review = try fixture.review()
    let source = fixture.thread
    try fixture.begin(review, uncertain: true)
    let expected = try fixture.staged(review), attempt = ConversationHistoryMaintenanceAttempt(expected: expected, sourceIncarnation: fixture.incarnation, updatedAt: fixture.now)
    var decision = WorkspaceDecision(snapshot: fixture.snapshot)
    try decision.acceptConversationHistoryMaintenance(operationID: review.id, attempt: attempt, now: fixture.now)
    #expect(decision.effects.map(\.request) == [.conversationHistoryMaintenance(threadID: source.id, operationID: review.id, attemptID: attempt.id)])
    #expect(decision.snapshot.isConversationHistoryLocked(threadID: source.id))
    try decision.dispatchConversationHistoryMaintenance(threadID: source.id, operationID: review.id, attemptID: attempt.id,
                                                        incarnation: fixture.incarnation, now: fixture.now)
    let result = try fixture.cleared(expected)
    decision.finishConversationHistoryMaintenance(.conversationHistoryMaintenance(threadID: source.id, operationID: review.id, attemptID: attempt.id),
        result: .conversationHistoryMaintenanceConfirmed(result), incarnation: fixture.incarnation, now: fixture.now)
    let held = try #require(decision.snapshot.conversationHistoryOperation(review.id))
    #expect(held.phase == .unconfirmed && held.maintenance?.phase == .applied && held.locksSource)
    #expect(held.recalledAt == nil && decision.snapshot.threads[0] == source)
    #expect(throws: (any Error).self) { try decision.reconcileConversationHistory(operationID: review.id, result: .unchanged, now: fixture.now) }
    try decision.reconcileConversationHistory(operationID: review.id, result: .openCodeV2Unchanged(result), now: fixture.now)
    #expect(decision.snapshot.conversationHistoryOperation(review.id)?.phase == .failed)
    #expect(!decision.snapshot.isConversationHistoryLocked(threadID: source.id) && decision.snapshot.threads[0] == source)
    try WorkspaceJournal.validate(decision.snapshot)
}

@Test(arguments: [OpenCodeV2HistoryStage.FilesState.absent, .nonempty])
func openCodeV2HistoryReducerRejectsUnreviewedFileBearingOrAbsentStage(files: OpenCodeV2HistoryStage.FilesState) throws {
    var fixture = try OpenCodeHistoryReducerFixture(); let review = try fixture.review()
    try fixture.begin(review, uncertain: true)
    let attempt = ConversationHistoryMaintenanceAttempt(expected: try fixture.staged(review, files: files), sourceIncarnation: fixture.incarnation)
    var decision = WorkspaceDecision(snapshot: fixture.snapshot)
    #expect(throws: (any Error).self) { try decision.acceptConversationHistoryMaintenance(operationID: review.id, attempt: attempt, now: fixture.now) }
    #expect(decision.snapshot == fixture.snapshot && decision.effects.isEmpty)
}

@Test(arguments: [ConversationHistoryMaintenancePhase.accepted, .dispatching])
func openCodeV2HistoryReducerRestartRetainsUnknownClearAndNeverRepeatsIt(phase: ConversationHistoryMaintenancePhase) async throws {
    var fixture = try OpenCodeHistoryReducerFixture(); let review = try fixture.review()
    try fixture.begin(review, uncertain: true)
    let attempt = ConversationHistoryMaintenanceAttempt(expected: try fixture.staged(review), sourceIncarnation: fixture.incarnation, updatedAt: fixture.now)
    var decision = WorkspaceDecision(snapshot: fixture.snapshot)
    try decision.acceptConversationHistoryMaintenance(operationID: review.id, attempt: attempt, now: fixture.now)
    if phase == .dispatching {
        try decision.dispatchConversationHistoryMaintenance(threadID: fixture.thread.id, operationID: review.id,
            attemptID: attempt.id, incarnation: fixture.incarnation, now: fixture.now)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-v2-history-reducer-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    try await database.save(decision.snapshot, event: "offline.v2.history.maintenance")
    var reopened = try await WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite")).load()
    reopened.recoverInterruptedWork()
    let recovered = try #require(reopened.conversationHistoryOperation(review.id))
    #expect(recovered.phase == .unconfirmed && recovered.locksSource && !recovered.isWorking)
    #expect(recovered.maintenance?.phase == (phase == .accepted ? .failed : .unconfirmed))
    #expect(recovered.maintenance?.result == nil && reopened.threads[0] == fixture.thread)
    try WorkspaceJournal.validate(reopened)
}

@Test func openCodeV2HistoryReducerRequiresPersistedExactCleanupReceiptBeforeIgnoringOneIdle() throws {
    var fixture = try OpenCodeHistoryReducerFixture(); let review = try fixture.review()
    try fixture.begin(review, uncertain: true)
    let observed = try fixture.cleared(fixture.staged(review))
    var decision = WorkspaceDecision(snapshot: fixture.snapshot)
    #expect(throws: (any Error).self) {
        try decision.reconcileConversationHistory(operationID: review.id, result: .openCodeV2Unchanged(observed), now: fixture.now)
    }
    #expect(decision.snapshot == fixture.snapshot)
}

@Test func openCodeV2HistoryReducerNewClearAfterRestartUsesItsOwnIncarnationAndRejectsTheOldOwner() throws {
    var fixture = try OpenCodeHistoryReducerFixture(); let review = try fixture.review()
    try fixture.begin(review, uncertain: true)
    fixture.snapshot.recoverInterruptedWork()
    let currentIncarnation = UUID(), expected = try fixture.staged(review)
    let attempt = ConversationHistoryMaintenanceAttempt(expected: expected, sourceIncarnation: currentIncarnation)
    var decision = WorkspaceDecision(snapshot: fixture.snapshot)
    try decision.acceptConversationHistoryMaintenance(operationID: review.id, attempt: attempt, now: fixture.now)
    try decision.dispatchConversationHistoryMaintenance(threadID: fixture.thread.id, operationID: review.id, attemptID: attempt.id,
                                                        incarnation: fixture.incarnation, now: fixture.now)
    #expect(decision.snapshot.conversationHistoryOperation(review.id)?.maintenance?.phase == .accepted)
    try decision.dispatchConversationHistoryMaintenance(threadID: fixture.thread.id, operationID: review.id, attemptID: attempt.id,
                                                        incarnation: currentIncarnation, now: fixture.now)
    #expect(decision.snapshot.conversationHistoryOperation(review.id)?.maintenance?.phase == .dispatching)
    let request = WorkspaceEffectRequest.conversationHistoryMaintenance(threadID: fixture.thread.id, operationID: review.id, attemptID: attempt.id)
    let result = EffectResult.conversationHistoryMaintenanceConfirmed(try fixture.cleared(expected))
    decision.finishConversationHistoryMaintenance(request, result: result, incarnation: fixture.incarnation, now: fixture.now)
    #expect(decision.snapshot.conversationHistoryOperation(review.id)?.maintenance?.phase == .dispatching)
    decision.finishConversationHistoryMaintenance(request, result: result, incarnation: currentIncarnation, now: fixture.now)
    let operation = try #require(decision.snapshot.conversationHistoryOperation(review.id))
    #expect(operation.maintenance?.phase == .applied && operation.phase == .unconfirmed && operation.locksSource)
    #expect(operation.review.sourceIncarnation == fixture.incarnation && operation.maintenance?.sourceIncarnation == currentIncarnation)
    try WorkspaceJournal.validate(decision.snapshot)
}

@Test(arguments: ["missingReceipt", "foreignSession", "changedPrefix"])
func openCodeV2HistoryReducerInvalidClearEvidenceStaysHeldWithoutChangingConversation(change: String) throws {
    var fixture = try OpenCodeHistoryReducerFixture(); let review = try fixture.review()
    try fixture.begin(review, uncertain: true)
    let expected = try fixture.staged(review), attempt = ConversationHistoryMaintenanceAttempt(expected: expected, sourceIncarnation: fixture.incarnation)
    var decision = WorkspaceDecision(snapshot: fixture.snapshot)
    try decision.acceptConversationHistoryMaintenance(operationID: review.id, attempt: attempt, now: fixture.now)
    try decision.dispatchConversationHistoryMaintenance(threadID: fixture.thread.id, operationID: review.id, attemptID: attempt.id,
                                                        incarnation: fixture.incarnation, now: fixture.now)
    let valid = try fixture.cleared(expected)
    let altered: OpenCodeV2HistorySnapshot
    if change == "missingReceipt" {
        altered = try .init(reference: valid.reference, runtimeIdentity: valid.runtimeIdentity, workspacePath: valid.workspacePath, messages: valid.messages)
    } else if change == "foreignSession" {
        altered = try .init(reference: .init(provider: .opencode, nativeThreadID: "ses_foreign"), runtimeIdentity: valid.runtimeIdentity,
                            workspacePath: valid.workspacePath, messages: valid.messages, maintenance: valid.maintenance)
    } else {
        var messages = expected.messages
        messages[1] = try .init(id: messages[1].id, kind: .assistant, contentDigest: String(repeating: "f", count: 64))
        let changed = try OpenCodeV2HistorySnapshot(reference: expected.reference, runtimeIdentity: expected.runtimeIdentity,
            workspacePath: expected.workspacePath, messages: messages, stage: expected.stage)
        altered = try fixture.cleared(changed)
    }
    decision.finishConversationHistoryMaintenance(.conversationHistoryMaintenance(threadID: fixture.thread.id, operationID: review.id, attemptID: attempt.id),
        result: .conversationHistoryMaintenanceConfirmed(altered), incarnation: fixture.incarnation, now: fixture.now)
    let held = try #require(decision.snapshot.conversationHistoryOperation(review.id))
    #expect(held.phase == .unconfirmed && held.maintenance?.phase == .unconfirmed && held.maintenance?.result == nil)
    #expect(held.locksSource && decision.snapshot.threads[0] == fixture.thread)
    try WorkspaceJournal.validate(decision.snapshot)
}

@Test func openCodeV2HistoryReducerNewExplicitClearRetainsPriorAttemptAndIgnoresItsLateReply() throws {
    var fixture = try OpenCodeHistoryReducerFixture(); let review = try fixture.review()
    try fixture.begin(review, uncertain: true)
    let expected = try fixture.staged(review)
    let first = ConversationHistoryMaintenanceAttempt(expected: expected, sourceIncarnation: fixture.incarnation)
    var decision = WorkspaceDecision(snapshot: fixture.snapshot)
    try decision.acceptConversationHistoryMaintenance(operationID: review.id, attempt: first, now: fixture.now)
    try decision.dispatchConversationHistoryMaintenance(threadID: fixture.thread.id, operationID: review.id, attemptID: first.id,
                                                        incarnation: fixture.incarnation, now: fixture.now)
    decision.finishConversationHistoryMaintenance(.conversationHistoryMaintenance(threadID: fixture.thread.id, operationID: review.id, attemptID: first.id),
        result: .conversationHistoryUnconfirmed, incarnation: fixture.incarnation, now: fixture.now)
    let second = ConversationHistoryMaintenanceAttempt(expected: expected, sourceIncarnation: fixture.incarnation)
    try decision.acceptConversationHistoryMaintenance(operationID: review.id, attempt: second, now: fixture.now)
    let beforeLateReply = decision.snapshot
    let lateResult = try fixture.cleared(expected)
    decision.finishConversationHistoryMaintenance(.conversationHistoryMaintenance(threadID: fixture.thread.id, operationID: review.id, attemptID: first.id),
        result: .conversationHistoryMaintenanceConfirmed(lateResult), incarnation: fixture.incarnation, now: fixture.now)
    #expect(decision.snapshot == beforeLateReply)
    let operation = try #require(decision.snapshot.conversationHistoryOperation(review.id))
    #expect(operation.maintenance?.id == second.id && operation.previousMaintenanceAttempts?.map(\.id) == [first.id])
    #expect(operation.previousMaintenanceAttempts?.first?.phase == .unconfirmed && operation.locksSource)
    try WorkspaceJournal.validate(decision.snapshot)
}

@Test func openCodeV2HistoryCodexLegacyReviewAndOperationOmitAllNewEvidenceKeys() throws {
    let json = #"{"boundary":{"kind":"throughTurn","turnID":"turn-1"},"id":"00000000-0000-0000-0000-000000000001","kind":"forkAfterRun","prefix":[],"projectID":"00000000-0000-0000-0000-000000000002","removedMessageIDs":[],"removedRunIDs":[],"reviewedAt":0,"reviewedHeadTurnID":"turn-2","expectedResultHeadTurnID":"turn-1","runID":"00000000-0000-0000-0000-000000000003","sourceConfiguration":{"provider":"codex","workspacePath":"/fixture/legacy","nativeThreadID":"source-native","model":"model","permission":"supervised"},"sourceFingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceIncarnation":"00000000-0000-0000-0000-000000000004","sourceReference":{"provider":"codex","nativeThreadID":"source-native"},"sourceThreadID":"00000000-0000-0000-0000-000000000005","suggestedTitle":"Legacy fork","targetConfiguration":{"provider":"codex","workspacePath":"/fixture/legacy","nativeThreadID":"source-native","model":"model","permission":"supervised"},"targetThreadID":"00000000-0000-0000-0000-000000000006"}"#
    let review = try JSONDecoder().decode(ConversationHistoryReview.self, from: Data(json.utf8))
    try review.validate()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let expectedObject = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let expected = try JSONSerialization.data(withJSONObject: expectedObject, options: [.sortedKeys])
    #expect(try encoder.encode(review) == expected)
    let operation = ConversationHistoryOperation(review: review)
    let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(operation)) as? [String: Any])
    #expect(object["maintenance"] == nil && object["previousMaintenanceAttempts"] == nil)
    #expect(try JSONDecoder().decode(ConversationHistoryOperation.self, from: encoder.encode(operation)) == operation)
}
