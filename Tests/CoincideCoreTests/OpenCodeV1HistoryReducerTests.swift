import Foundation
import Testing
@testable import CoincideCore

private struct OpenCodeV1ReducerFixture {
    var snapshot = WorkspaceSnapshot()
    let incarnation = UUID()
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let runs = (0..<3).map { _ in UUID() }
    var native: OpenCodeV1HistorySnapshot
    var thread: CodingThread { snapshot.threads[0] }
    init() throws {
        let project = WorkspaceProject(path: "/fixture/opencode-v1-history")
        var thread = CodingThread(project: project)
        thread.provider = .opencode; thread.openCodeConfiguration = .init(generation: .v1, executable: "/fixture/opencode")
        thread.providerThreadID = "ses_v1_source"; thread.permission = .auto; thread.checkpointPolicy = .disabled
        thread.draft = "Latest unsent draft 工作 😀"; thread.isPinned = true
        var messages: [OpenCodeV1HistoryMessage] = []
        for (index, runID) in runs.enumerated() {
            let inputID = "msg_\((index + 1) * 100)", replyID = "msg_\((index + 1) * 100 + 10)"
            var configuration = ProviderConfiguration(thread: thread); configuration.permission = .supervised
            let active = ActiveRun(id: runID, configuration: configuration, startedAt: now, nativeTurnID: inputID)
            var record = ThreadRunRecord(run: active, origin: .user, userMessageID: "user-\(runID)")
            record.status = .completed; record.endedAt = now; record.endReason = .providerCompleted; record.messageAttributionVersion = 1
            if thread.runHistory == nil { thread.runHistory = [] }; thread.runHistory?.append(record)
            var user = ChatMessage(id: "user-\(runID)", role: .user, text: "Original input \(index)")
            user.runReference = .init(threadID: thread.id, runID: runID)
            var reply = ChatMessage(id: "reply-\(runID)", role: .assistant, text: "Reply \(index)"); reply.runReference = user.runReference
            thread.messages += [user, reply]
            messages += [try .init(id: inputID, role: .user, partIDs: ["prt_source_user_\(index)"], contentDigest: String(repeating: String(index + 1), count: 64)),
                         try .init(id: replyID, role: .assistant, parentID: inputID, partIDs: ["prt_source_reply_\(index)"], contentDigest: String(repeating: String(index + 4), count: 64))]
        }
        native = try .init(reference: .init(provider: .opencode, nativeThreadID: "ses_v1_source"),
            runtimeIdentity: thread.openCodeConfiguration!.runtimeIdentity, workspacePath: project.path,
            projectID: String(repeating: "a", count: 40), sessionDigest: String(repeating: "a", count: 64), messages: messages)
        snapshot.projects = [project]; snapshot.threads = [thread]
    }
    func review(_ kind: ConversationHistoryKind = .rewindBeforeRun, runID: UUID? = nil, recallPromptOnSuccess: Bool = false) throws -> ConversationHistoryReview {
        let runID = runID ?? runs[1]
        let record = try #require(thread.activeHistoryRuns.first { $0.id == runID })
        let evidence = try OpenCodeV1HistoryReviewEvidence.make(source: native, snapshot: snapshot, thread: thread, runID: runID, kind: kind)
        let prefix = try thread.transcriptPrefix(runID: runID, boundary: kind == .forkAfterRun ? .afterRun : .beforeRun)
        let first = try #require(thread.activeHistoryRuns.firstIndex { $0.id == runID }), prefixIDs = Set(prefix.map(\.id))
        return try .init(kind: kind, reviewedAt: now, sourceThreadID: thread.id, projectID: thread.projectID,
            runID: runID, sourceIncarnation: incarnation, sourceConfiguration: .init(thread: thread), targetConfiguration: record.configuration,
            sourceReference: native.reference, reviewedHeadTurnID: nil, boundary: evidence.boundary, expectedResultHeadTurnID: nil,
            prefix: prefix, removedRunIDs: kind == .rewindBeforeRun ? thread.activeHistoryRuns.dropFirst(first).map(\.id) : [],
            removedMessageIDs: kind == .rewindBeforeRun ? thread.visibleMessages.filter { !prefixIDs.contains($0.id) }.map(\.id) : [],
            sourceFingerprint: snapshot.historySourceFingerprint(threadID: thread.id), targetThreadID: kind == .forkAfterRun ? UUID() : nil,
            suggestedTitle: "Verified native v1 copy", recallPromptOnSuccess: recallPromptOnSuccess ? true : nil, openCodeV1: evidence)
    }
    @discardableResult mutating func command(_ command: EngineCommand) throws -> WorkspaceDecision {
        now.addTimeInterval(1)
        let decision = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: now)
        snapshot = decision.snapshot; return decision
    }
    mutating func begin(_ review: ConversationHistoryReview) throws {
        try command(.conversationHistoryAccepted(review: review, title: nil))
        try command(.conversationHistoryDispatching(threadID: thread.id, operationID: review.id, incarnation: incarnation))
    }
    func copy(_ review: ConversationHistoryReview, nativeID: String) throws -> ProviderConversationSnapshot {
        let evidence = try #require(review.openCodeV1), prefix = Array(evidence.source.messages.prefix(evidence.retainedMessageCount))
        let ids = Dictionary(uniqueKeysWithValues: prefix.enumerated().map { ($0.element.id, "msg_\(nativeID)_\(String(format: "%04d", $0.offset))") })
        let messages = try prefix.enumerated().map { index, message in
            try OpenCodeV1HistoryMessage(id: #require(ids[message.id]), role: message.role,
                parentID: message.parentID.flatMap { ids[$0] },
                partIDs: message.partIDs.enumerated().map { "prt_\(nativeID)_\(index)_\($0.offset)" },
                contentDigest: message.contentDigest, isSettled: message.isSettled, isInternalUserInput: message.isInternalUserInput)
        }
        let result = try OpenCodeV1HistorySnapshot(reference: .init(provider: .opencode, nativeThreadID: nativeID),
            runtimeIdentity: native.runtimeIdentity, workspacePath: native.workspacePath, projectID: native.projectID,
            workspaceID: native.workspaceID, sessionDigest: String(repeating: "b", count: 64), messages: messages)
        return try .init(reference: result.reference, workspacePath: result.workspacePath, historyMode: .messageOrdered, openCodeV1: result)
    }
    func candidate(_ review: ConversationHistoryReview, nativeID: String) throws -> OpenCodeV1HistoryCandidate {
        try .init(reference: .init(provider: .opencode, nativeThreadID: nativeID), sourceInventoryDigest: #require(review.openCodeV1).source.inventoryDigest,
                  runtimeIdentity: native.runtimeIdentity, workspacePath: native.workspacePath, boundary: review.boundary)
    }
    mutating func publish(_ review: ConversationHistoryReview, candidate: OpenCodeV1HistoryCandidate) throws {
        var decision = WorkspaceDecision(snapshot: snapshot)
        try decision.recordOpenCodeV1HistoryCandidate(operationID: review.id, candidate: candidate, incarnation: incarnation, now: now)
        snapshot = decision.snapshot
    }
    mutating func finish(_ review: ConversationHistoryReview, result: EffectResult) throws {
        try command(.conversationHistoryEffectResult(.conversationHistory(threadID: thread.id, operationID: review.id), result, incarnation: incarnation))
    }
    mutating func appendCompletedInput() throws -> UUID {
        let runID = UUID(), inputID = "msg_zz_new_\(runID.uuidString)", replyID = inputID + "_reply"
        var thread = thread
        let active = ActiveRun(id: runID, configuration: .init(thread: thread), startedAt: now, nativeTurnID: inputID)
        var record = ThreadRunRecord(run: active, origin: .user, userMessageID: "user-\(runID)")
        record.status = .completed; record.endedAt = now; record.endReason = .providerCompleted; record.messageAttributionVersion = 1
        thread.runHistory?.append(record)
        var user = ChatMessage(id: "user-\(runID)", role: .user, text: "New input on adopted session"); user.runReference = .init(threadID: thread.id, runID: runID)
        var reply = ChatMessage(id: "reply-\(runID)", role: .assistant, text: "New answer"); reply.runReference = user.runReference
        thread.messages += [user, reply]; snapshot.threads[0] = thread
        native = try .init(reference: native.reference, runtimeIdentity: native.runtimeIdentity, workspacePath: native.workspacePath,
            projectID: native.projectID, workspaceID: native.workspaceID, sessionDigest: String(repeating: "c", count: 64), messages: native.messages + [
                .init(id: inputID, role: .user, partIDs: ["prt_\(runID)_input"], contentDigest: String(repeating: "7", count: 64)),
                .init(id: replyID, role: .assistant, parentID: inputID, partIDs: ["prt_\(runID)_reply"], contentDigest: String(repeating: "8", count: 64))])
        return runID
    }
}

@Test(arguments: [ConversationHistoryKind.forkAfterRun, .rewindBeforeRun], [0, 1, 2])
func openCodeV1HistoryReducerPublishesCandidateBeforeAtomicAdoptionAndPreservesAudit(kind: ConversationHistoryKind, index: Int) throws {
    var fixture = try OpenCodeV1ReducerFixture()
    let source = fixture.thread, review = try fixture.review(kind, runID: fixture.runs[index])
    let result = try fixture.copy(review, nativeID: "ses_verified_copy"), candidate = try fixture.candidate(review, nativeID: result.reference.nativeThreadID)
    var premature = WorkspaceDecision(snapshot: fixture.snapshot)
    #expect(throws: (any Error).self) { try premature.recordOpenCodeV1HistoryCandidate(operationID: review.id, candidate: candidate, incarnation: fixture.incarnation, now: fixture.now) }
    try fixture.begin(review)
    try fixture.publish(review, candidate: candidate)
    try fixture.publish(review, candidate: candidate)
    #expect(fixture.thread == source && fixture.snapshot.conversationHistoryOperation(review.id)?.openCodeV1Candidate == candidate)
    try fixture.finish(review, result: .conversationHistoryConfirmed(result))
    let operation = try #require(fixture.snapshot.conversationHistoryOperation(review.id))
    #expect(operation.phase == .applied && operation.openCodeV1Candidate?.reference == result.reference)
    if kind == .rewindBeforeRun {
        #expect(fixture.thread.providerThreadID == result.reference.nativeThreadID && fixture.thread.visibleMessages == review.prefix)
        #expect(fixture.thread.draft == source.draft && fixture.thread.permission == source.permission && fixture.thread.isPinned)
        #expect(fixture.thread.runHistory?.map(\.providerThreadID) == source.runHistory?.map(\.providerThreadID))
        #expect(fixture.thread.runHistory?.map(\.turnIDs) == source.runHistory?.map(\.turnIDs))
    } else {
        #expect(fixture.thread == source)
        let target = try #require(fixture.snapshot.threads.first { $0.id == review.targetThreadID })
        #expect(target.providerThreadID == result.reference.nativeThreadID && target.visibleMessages == review.prefix)
        #expect(target.permission == .supervised && target.draft.isEmpty && target.runHistory == nil)
    }
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test func openCodeV1HistoryReducerRejectsMissingChangedOrForeignCandidateWithoutAdopting() throws {
    var fixture = try OpenCodeV1ReducerFixture(); let review = try fixture.review()
    let source = fixture.thread, result = try fixture.copy(review, nativeID: "ses_unrecorded_copy")
    try fixture.begin(review)
    try fixture.finish(review, result: .conversationHistoryConfirmed(result))
    #expect(fixture.thread == source && fixture.snapshot.conversationHistoryOperation(review.id)?.phase == .unconfirmed)
    var decision = WorkspaceDecision(snapshot: fixture.snapshot)
    #expect(throws: (any Error).self) { try decision.reconcileConversationHistory(operationID: review.id, result: .applied(result), now: fixture.now) }
    #expect(decision.snapshot == fixture.snapshot)
    var second = try OpenCodeV1ReducerFixture(); let secondReview = try second.review()
    try second.begin(secondReview)
    let firstCandidate = try second.candidate(secondReview, nativeID: "ses_first_candidate")
    try second.publish(secondReview, candidate: firstCandidate)
    let before = second.snapshot
    let changedCandidate = try second.candidate(secondReview, nativeID: "ses_second_candidate")
    #expect(throws: (any Error).self) { try second.publish(secondReview, candidate: changedCandidate) }
    #expect(second.snapshot == before)
    var stale = WorkspaceDecision(snapshot: before)
    let owned = try second.candidate(secondReview, nativeID: "ses_first_candidate")
    #expect(throws: (any Error).self) { try stale.recordOpenCodeV1HistoryCandidate(operationID: secondReview.id, candidate: owned, incarnation: UUID(), now: second.now) }
    #expect(stale.snapshot == before)
}

@Test func openCodeV1HistoryRepeatedAdoptionsResolveOriginalRunReferencesWithoutRewritingThem() throws {
    var fixture = try OpenCodeV1ReducerFixture()
    let originalRuns = try #require(fixture.thread.runHistory)
    let first = try fixture.review(runID: fixture.runs[2]), firstResult = try fixture.copy(first, nativeID: "ses_adopted_b")
    let firstCandidate = try fixture.candidate(first, nativeID: firstResult.reference.nativeThreadID)
    try fixture.begin(first); try fixture.publish(first, candidate: firstCandidate)
    try fixture.finish(first, result: .conversationHistoryConfirmed(firstResult)); fixture.native = try #require(firstResult.openCodeV1)
    _ = try fixture.appendCompletedInput()
    let second = try fixture.review(runID: fixture.runs[1]), secondResult = try fixture.copy(second, nativeID: "ses_adopted_c")
    let secondCandidate = try fixture.candidate(second, nativeID: secondResult.reference.nativeThreadID)
    try fixture.begin(second); try fixture.publish(second, candidate: secondCandidate)
    try fixture.finish(second, result: .conversationHistoryConfirmed(secondResult)); fixture.native = try #require(secondResult.openCodeV1)
    _ = try fixture.appendCompletedInput()
    let fork = try fixture.review(.forkAfterRun, runID: fixture.runs[0]), forkResult = try fixture.copy(fork, nativeID: "ses_fork_from_c")
    #expect(fork.openCodeV1?.inputs.first?.originalReference.nativeThreadID == "ses_v1_source")
    #expect(fork.openCodeV1?.inputs.first?.openingMessageID != originalRuns[0].turnIDs.first)
    let beforeFork = fixture.thread
    let forkCandidate = try fixture.candidate(fork, nativeID: forkResult.reference.nativeThreadID)
    try fixture.begin(fork); try fixture.publish(fork, candidate: forkCandidate)
    try fixture.finish(fork, result: .conversationHistoryConfirmed(forkResult))
    #expect(fixture.thread == beforeFork && fixture.thread.providerThreadID == "ses_adopted_c")
    for original in originalRuns {
        let retained = try #require(fixture.thread.runHistory?.first { $0.id == original.id })
        #expect(retained.configuration == original.configuration && retained.providerThreadID == original.providerThreadID && retained.turnIDs == original.turnIDs)
    }
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test(arguments: [false, true])
func openCodeV1HistoryUnknownOutcomeKeepsOriginalOnlyWithFreshExactProofAndWarnsOfOrphan(recordedCandidate: Bool) throws {
    var fixture = try OpenCodeV1ReducerFixture(); let review = try fixture.review(), source = fixture.thread
    try fixture.begin(review)
    if recordedCandidate {
        let candidate = try fixture.candidate(review, nativeID: "ses_possible_orphan")
        try fixture.publish(review, candidate: candidate)
    }
    try fixture.finish(review, result: .conversationHistoryUnconfirmed)
    var decision = WorkspaceDecision(snapshot: fixture.snapshot)
    let altered = try OpenCodeV1HistorySnapshot(reference: fixture.native.reference, runtimeIdentity: fixture.native.runtimeIdentity,
        workspacePath: fixture.native.workspacePath, projectID: fixture.native.projectID,
        sessionDigest: String(repeating: "d", count: 64), messages: fixture.native.messages)
    #expect(throws: (any Error).self) { try decision.reconcileConversationHistory(operationID: review.id, result: .openCodeV1NotAdopted(altered), now: fixture.now) }
    #expect(decision.snapshot == fixture.snapshot)
    try decision.reconcileConversationHistory(operationID: review.id, result: .openCodeV1NotAdopted(fixture.native), now: fixture.now)
    let operation = try #require(decision.snapshot.conversationHistoryOperation(review.id))
    #expect(operation.phase == .failed && operation.error == ConversationHistoryOperation.openCodeV1NotAdoptedMessage)
    #expect(!operation.locksSource && operation.recalledAt == nil && decision.snapshot.threads[0] == source && decision.effects.isEmpty)
    #expect((operation.openCodeV1Candidate != nil) == recordedCandidate)
    try WorkspaceJournal.validate(decision.snapshot)
}

@Test func openCodeV1HistoryCandidateScopeAndHistoricalNativeReferencesAreReservedBeforePolicyWrites() throws {
    var fixture = try OpenCodeV1ReducerFixture(); let first = try fixture.review(runID: fixture.runs[2])
    let result = try fixture.copy(first, nativeID: "ses_reserved_history_b")
    let firstCandidate = try fixture.candidate(first, nativeID: result.reference.nativeThreadID)
    try fixture.begin(first); try fixture.publish(first, candidate: firstCandidate)
    var alias = CodingThread(project: fixture.snapshot.projects[0]); alias.provider = .opencode
    alias.openCodeConfiguration = fixture.thread.openCodeConfiguration; alias.providerThreadID = result.reference.nativeThreadID
    #expect(fixture.snapshot.isOpenCodeHistoryScopeLocked(configuration: .init(thread: alias), nativeThreadID: alias.providerThreadID))
    #expect(!fixture.snapshot.isOpenCodeV2HistoryScopeLocked(configuration: .init(thread: alias), nativeThreadID: alias.providerThreadID))
    let decision = WorkspaceDecision(snapshot: fixture.snapshot)
    #expect(throws: WorkspaceCommandError.self) { try decision.validateConversationHistoryLocks(.createThread(alias)) }
    try fixture.finish(first, result: .conversationHistoryConfirmed(result)); fixture.native = try #require(result.openCodeV1)
    let second = try fixture.review(runID: fixture.runs[1]); try fixture.begin(second)
    let originalID = try #require(first.openCodeV1).source.reference.nativeThreadID
    let reused = try fixture.candidate(second, nativeID: originalID), before = fixture.snapshot
    #expect(throws: (any Error).self) { try fixture.publish(second, candidate: reused) }
    #expect(fixture.snapshot == before && fixture.snapshot.conversationHistoryOperation(second.id)?.openCodeV1Candidate == nil)
}

@Test func openCodeV1HistoryCandidatePersistsAcrossRestartWithoutAdoptionOrReplay() async throws {
    var fixture = try OpenCodeV1ReducerFixture(); let review = try fixture.review()
    try fixture.begin(review); let candidate = try fixture.candidate(review, nativeID: "ses_restart_candidate")
    try fixture.publish(review, candidate: candidate)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-v1-history-reducer-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    try await database.save(fixture.snapshot, event: "offline.v1.history.candidate")
    var reopened = try await WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite")).load()
    reopened.recoverInterruptedWork()
    let operation = try #require(reopened.conversationHistoryOperation(review.id))
    #expect(operation.phase == .unconfirmed && operation.openCodeV1Candidate == candidate && operation.locksSource)
    #expect(reopened.threads[0] == fixture.thread && operation.result == nil)
    try WorkspaceJournal.validate(reopened)
}

@Test func openCodeV1HistoryUnconfirmedForkReservesOnlyItsCandidateAcrossRestartAndProviderAdoption() throws {
    var fixture = try OpenCodeV1ReducerFixture()
    let review = try fixture.review(.forkAfterRun)
    let candidate = try fixture.candidate(review, nativeID: "ses_unconfirmed_fork_candidate")
    try fixture.begin(review); try fixture.publish(review, candidate: candidate)
    fixture.snapshot.recoverInterruptedWork()
    let operation = try #require(fixture.snapshot.conversationHistoryOperation(review.id))
    #expect(operation.phase == .unconfirmed && !operation.locksSource && operation.reservesOpenCodeV1Candidate)
    #expect(!fixture.snapshot.isConversationHistoryLocked(threadID: fixture.thread.id))
    #expect(!fixture.snapshot.isOpenCodeHistoryScopeLocked(configuration: .init(thread: fixture.thread), nativeThreadID: fixture.thread.providerThreadID))
    var alias = CodingThread(project: fixture.snapshot.projects[0])
    alias.provider = .opencode; alias.openCodeConfiguration = fixture.thread.openCodeConfiguration
    alias.providerThreadID = candidate.reference.nativeThreadID; alias.checkpointPolicy = .disabled
    #expect(fixture.snapshot.isOpenCodeHistoryScopeLocked(configuration: .init(thread: alias), nativeThreadID: alias.providerThreadID))
    let decision = WorkspaceDecision(snapshot: fixture.snapshot)
    #expect(throws: WorkspaceCommandError.self) { try decision.validateConversationHistoryLocks(.createThread(alias)) }
    // A previously unbound runtime cannot adopt the reserved native candidate
    // through an unsolicited provider thread event either.
    alias.providerThreadID = nil; alias.runtimeID = UUID()
    let runtimeID = try #require(alias.runtimeID)
    fixture.snapshot.threads.append(alias)
    try fixture.command(.provider(threadID: alias.id, runtimeID: runtimeID, event: .thread(candidate.reference.nativeThreadID)))
    let rejected = try #require(fixture.snapshot.threads.first { $0.id == alias.id })
    #expect(rejected.providerThreadID == nil && rejected.messages.isEmpty)
    #expect(fixture.snapshot.threads[0].providerThreadID == review.sourceReference.nativeThreadID)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test(arguments: [false, true])
func openCodeV1HistoryAppliedRewindReservesAdoptedSessionUntilPromptRecallSettles(dismiss: Bool) throws {
    var fixture = try OpenCodeV1ReducerFixture()
    let review = try fixture.review(recallPromptOnSuccess: true)
    let result = try fixture.copy(review, nativeID: "ses_recall_held_copy")
    let candidate = try fixture.candidate(review, nativeID: result.reference.nativeThreadID)
    try fixture.begin(review); try fixture.publish(review, candidate: candidate)
    try fixture.finish(review, result: .conversationHistoryConfirmed(result))
    let held = try #require(fixture.snapshot.conversationHistoryOperation(review.id))
    #expect(held.phase == .applied && held.needsPromptRecall && held.locksSource && held.reservesOpenCodeV1Candidate)
    #expect(fixture.thread.providerThreadID == candidate.reference.nativeThreadID)
    var alias = CodingThread(project: fixture.snapshot.projects[0])
    alias.provider = .opencode; alias.openCodeConfiguration = fixture.thread.openCodeConfiguration
    alias.providerThreadID = candidate.reference.nativeThreadID; alias.checkpointPolicy = .disabled
    #expect(fixture.snapshot.isOpenCodeHistoryScopeLocked(configuration: .init(thread: alias), nativeThreadID: alias.providerThreadID))
    let heldDecision = WorkspaceDecision(snapshot: fixture.snapshot)
    #expect(throws: WorkspaceCommandError.self) { try heldDecision.validateConversationHistoryLocks(.createThread(alias)) }
    alias.providerThreadID = nil; alias.runtimeID = UUID()
    let rejectedRuntimeID = try #require(alias.runtimeID)
    fixture.snapshot.threads.append(alias)
    try fixture.command(.provider(threadID: alias.id, runtimeID: rejectedRuntimeID, event: .thread(candidate.reference.nativeThreadID)))
    let rejected = try #require(fixture.snapshot.threads.first { $0.id == alias.id })
    #expect(rejected.providerThreadID == nil && rejected.messages.isEmpty)
    if dismiss { try fixture.command(.client(.dismissConversationHistoryRecall(operationID: review.id))) }
    else { try fixture.command(.client(.recallConversationHistoryPrompt(operationID: review.id))) }
    let settled = try #require(fixture.snapshot.conversationHistoryOperation(review.id))
    #expect(settled.phase == .applied && !settled.needsPromptRecall && !settled.locksSource && !settled.reservesOpenCodeV1Candidate)
    #expect(!fixture.snapshot.isOpenCodeHistoryScopeLocked(configuration: .init(thread: alias), nativeThreadID: candidate.reference.nativeThreadID))
    var fresh = alias; fresh.id = UUID(); fresh.providerThreadID = candidate.reference.nativeThreadID; fresh.runtimeID = nil
    try WorkspaceDecision(snapshot: fixture.snapshot).validateConversationHistoryLocks(.createThread(fresh))
    let aliasIndex = try #require(fixture.snapshot.threads.firstIndex { $0.id == alias.id }), acceptedRuntimeID = UUID()
    fixture.snapshot.threads[aliasIndex].runtimeID = acceptedRuntimeID
    try fixture.command(.provider(threadID: alias.id, runtimeID: acceptedRuntimeID, event: .thread(candidate.reference.nativeThreadID)))
    #expect(fixture.snapshot.threads.first { $0.id == alias.id }?.providerThreadID == candidate.reference.nativeThreadID)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test func openCodeV1HistoryAppliedForkReleasesCandidateForItsLegitimateTarget() throws {
    var fixture = try OpenCodeV1ReducerFixture()
    let review = try fixture.review(.forkAfterRun)
    let result = try fixture.copy(review, nativeID: "ses_usable_fork_copy")
    let candidate = try fixture.candidate(review, nativeID: result.reference.nativeThreadID)
    try fixture.begin(review); try fixture.publish(review, candidate: candidate)
    try fixture.finish(review, result: .conversationHistoryConfirmed(result))
    let operation = try #require(fixture.snapshot.conversationHistoryOperation(review.id))
    let targetID = try #require(review.targetThreadID)
    let target = try #require(fixture.snapshot.threads.first { $0.id == targetID })
    #expect(operation.phase == .applied && !operation.locksSource && !operation.reservesOpenCodeV1Candidate)
    #expect(target.providerThreadID == candidate.reference.nativeThreadID && fixture.snapshot.providerReady(for: target))
    let submitted = try fixture.command(.client(.submit(threadID: targetID, text: "Continue verified fork")))
    let active = try #require(fixture.snapshot.threads.first { $0.id == targetID }?.activeRun)
    #expect(submitted.effects.contains { effect in
        if case .providerStart(let threadID, let runID, let configuration, let prompt, _) = effect.request {
            return threadID == targetID && runID == active.id && configuration.nativeThreadID == candidate.reference.nativeThreadID && prompt == "Continue verified fork"
        }
        return false
    })
    let runtimeID = UUID()
    try fixture.command(.runtimeOpened(threadID: targetID, runID: active.id, runtimeID: runtimeID))
    try fixture.command(.provider(threadID: targetID, runtimeID: runtimeID, event: .thread(candidate.reference.nativeThreadID)))
    let running = try #require(fixture.snapshot.threads.first { $0.id == targetID })
    #expect(running.activeRun?.id == active.id && running.runtimeID == runtimeID && running.providerThreadID == candidate.reference.nativeThreadID)
    try WorkspaceJournal.validate(fixture.snapshot)
}
