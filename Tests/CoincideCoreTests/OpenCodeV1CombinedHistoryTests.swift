import Foundation
import Testing
@testable import CoincideCore

private func combinedV1Fixture() throws -> (ConversationHistoryFilesFixture, ConversationHistoryReview, ProviderConversationSnapshot, OpenCodeV1HistoryCandidate) {
    var fixture = try ConversationHistoryFilesFixture(), thread = fixture.thread
    thread.provider = .opencode; thread.model = ""; thread.openCodeConfiguration = .init(generation: .v1, executable: "/fixture/opencode")
    thread.providerThreadID = "ses_combined_original"
    var native: [OpenCodeV1HistoryMessage] = []
    for index in thread.runHistory!.indices {
        let input = "msg_\((index + 1) * 100)", reply = "msg_\((index + 1) * 100 + 10)"
        thread.runHistory?[index].configuration.provider = .opencode
        thread.runHistory?[index].configuration.model = ""
        thread.runHistory?[index].configuration.openCodeConfiguration = thread.openCodeConfiguration
        thread.runHistory?[index].configuration.nativeThreadID = index == 0 ? nil : thread.providerThreadID
        thread.runHistory?[index].providerThreadID = thread.providerThreadID
        thread.runHistory?[index].turnIDs = [input]
        native += [try .init(id: input, role: .user, partIDs: ["prt_combined_input_\(index)"], contentDigest: String(repeating: "1", count: 64)),
                   try .init(id: reply, role: .assistant, parentID: input, partIDs: ["prt_combined_reply_\(index)"], contentDigest: String(repeating: "2", count: 64))]
    }
    fixture.snapshot.threads[0] = thread
    let source = try OpenCodeV1HistorySnapshot(reference: .init(provider: .opencode, nativeThreadID: "ses_combined_original"),
        runtimeIdentity: thread.openCodeConfiguration!.runtimeIdentity, workspacePath: thread.workspacePath,
        projectID: "combined-project", sessionDigest: String(repeating: "a", count: 64), messages: native)
    let prepared = try combinedV1Review(fixture: fixture, source: source, selected: fixture.runs[1], destination: "ses_combined_adopted")
    return (fixture, prepared.0, prepared.1, prepared.2)
}

private func combinedV1Review(fixture: ConversationHistoryFilesFixture, source: OpenCodeV1HistorySnapshot,
    selected: UUID, destination: String) throws -> (ConversationHistoryReview, ProviderConversationSnapshot, OpenCodeV1HistoryCandidate) {
    let thread = fixture.thread, record = try #require(fixture.thread.runHistory?.first { $0.id == selected })
    let evidence = try OpenCodeV1HistoryReviewEvidence.make(source: source, snapshot: fixture.snapshot,
        thread: thread, runID: selected, kind: .rewindBeforeRun)
    let prefix = try thread.transcriptPrefix(runID: selected, boundary: .beforeRun), prefixIDs = Set(prefix.map(\.id))
    let first = try #require(thread.activeHistoryRuns.firstIndex { $0.id == selected }), reviewID = UUID()
    func make(files: ConversationHistoryFilesReview?) throws -> ConversationHistoryReview {
        try .init(id: reviewID, kind: .rewindBeforeRun, reviewedAt: fixture.now,
            sourceThreadID: thread.id, projectID: thread.projectID, runID: selected, sourceIncarnation: fixture.incarnation,
            sourceConfiguration: .init(thread: thread), targetConfiguration: record.configuration,
            sourceReference: source.reference, reviewedHeadTurnID: nil, boundary: evidence.boundary, expectedResultHeadTurnID: nil,
            prefix: prefix, removedRunIDs: thread.activeHistoryRuns.dropFirst(first).map(\.id),
            removedMessageIDs: thread.visibleMessages.filter { !prefixIDs.contains($0.id) }.map(\.id),
            sourceFingerprint: fixture.snapshot.historySourceFingerprint(threadID: thread.id), targetThreadID: nil,
            suggestedTitle: "Combined native V1 rewind", files: files, recallPromptOnSuccess: true, openCodeV1: evidence)
    }
    let keep = try make(files: nil)
    let target: ConversationHistoryFileTarget
    guard case .available(let resolved) = try fixture.snapshot.conversationHistoryFileTarget(for: keep) else {
        throw CoincideError("The isolated combined V1 fixture has no reviewed checkpoint.")
    }
    target = resolved
    let git = try GitCheckpointRestoreReview(targetReceipt: target.receipt,
        currentPlan: CheckpointRestoreFixture.plan(path: thread.workspacePath), reviewedAt: fixture.now,
        manifestDigest: String(repeating: "e", count: 64), affectedPaths: ["tracked.swift"])
    let files = try ConversationHistoryFilesReview(id: git.id, target: target,
        sourceFingerprint: fixture.snapshot.checkpointRestoreSourceFingerprint(threadID: thread.id), gitReview: git)
    let review = try make(files: files)
    let retained = Array(source.messages.prefix(evidence.retainedMessageCount))
    let ids = Dictionary(uniqueKeysWithValues: retained.enumerated().map { ($0.element.id, "msg_\(destination)_\($0.offset)") })
    let messages = try retained.enumerated().map { index, original in
        try OpenCodeV1HistoryMessage(id: #require(ids[original.id]), role: original.role,
            parentID: original.parentID.flatMap { ids[$0] }, partIDs: original.partIDs.enumerated().map { "prt_\(destination)_\(index)_\($0.offset)" },
            contentDigest: original.contentDigest, isSettled: original.isSettled, isInternalUserInput: original.isInternalUserInput)
    }
    let copied = try OpenCodeV1HistorySnapshot(reference: .init(provider: .opencode, nativeThreadID: destination),
        runtimeIdentity: source.runtimeIdentity, workspacePath: source.workspacePath, projectID: source.projectID,
        sessionDigest: String(repeating: "b", count: 64), messages: messages)
    let result = try ProviderConversationSnapshot(reference: copied.reference, workspacePath: copied.workspacePath,
        historyMode: .messageOrdered, openCodeV1: copied)
    let candidate = try OpenCodeV1HistoryCandidate(reference: copied.reference, sourceInventoryDigest: source.inventoryDigest,
        runtimeIdentity: source.runtimeIdentity, workspacePath: source.workspacePath, boundary: evidence.boundary)
    return (review, result, candidate)
}

@Test func openCodeV1HistoryCombinedFilesValidateAdoptedReferenceAndRecallLatestDraftOnlyAfterRestore() throws {
    let prepared = try combinedV1Fixture()
    var fixture = prepared.0
    let (review, result, candidate) = (prepared.1, prepared.2, prepared.3)
    let original = fixture.thread
    try fixture.accept(review); try fixture.dispatchProvider(review)
    try fixture.command(.conversationHistoryCandidateObserved(operationID: review.id, candidate: candidate, incarnation: fixture.incarnation))
    try fixture.finishProvider(review, result: .conversationHistoryConfirmed(result))
    let providerApplied = try fixture.operation(review)
    #expect(providerApplied.phase == .applied && providerApplied.files?.phase == .accepted)
    #expect(fixture.thread.providerThreadID == result.reference.nativeThreadID)
    #expect(fixture.thread.runHistory?.map(\.providerThreadID) == original.runHistory?.map(\.providerThreadID))
    try fixture.snapshot.validateConversationHistoryFilesSource(operationID: review.id)
    for change in ["oldNativeID", "foreignNativeID", "model", "permission"] {
        var changed = fixture.snapshot
        switch change {
        case "oldNativeID": changed.threads[0].providerThreadID = review.sourceReference.nativeThreadID
        case "foreignNativeID": changed.threads[0].providerThreadID = "ses_foreign"
        case "model": changed.threads[0].model = "Unexpected future model"
        default: changed.threads[0].permission = .auto
        }
        // Keep the independent fingerprint gate satisfied so this specifically
        // proves the exact reviewed configuration cannot be broadened.
        let fingerprint = try changed.checkpointRestoreSourceFingerprint(threadID: fixture.threadID)
        changed.conversationHistoryOperations?[0].files?.postHistorySourceFingerprint = fingerprint
        #expect(throws: WorkspaceCommandError.self) { try changed.validateConversationHistoryFilesSource(operationID: review.id) }
    }
    #expect(throws: WorkspaceCommandError.self) { try fixture.command(.client(.recallConversationHistoryPrompt(operationID: review.id))) }
    try fixture.command(.client(.editThread(fixture.threadID, .draft("Latest typing after native adoption 😀"))))
    try fixture.dispatchFiles(review); try fixture.finishFiles(review)
    let complete = try fixture.operation(review)
    #expect(complete.allExternalWorkSucceeded && complete.needsPromptRecall)
    try fixture.command(.client(.recallConversationHistoryPrompt(operationID: review.id)))
    #expect(fixture.thread.draft == "Latest typing after native adoption 😀\n\nOriginal prompt 1")
    #expect(fixture.thread.providerThreadID == result.reference.nativeThreadID && fixture.thread.activeRun == nil && fixture.thread.queuedTurns.isEmpty)
    let once = fixture.snapshot
    try fixture.command(.client(.recallConversationHistoryPrompt(operationID: review.id)))
    #expect(fixture.snapshot == once)
    try WorkspaceJournal.validate(fixture.snapshot)
}

private struct CombinedV1FirstAdoption {
    var fixture: ConversationHistoryFilesFixture
    let originalReference: ProviderConversationReference
    let result: ProviderConversationSnapshot
}

// Keep construction temporaries out of the later reducer/ledger-validation
// stack. Swift Testing workers have bounded stacks; no behavior is bypassed.
@inline(never)
private func completeFirstV1Adoption() throws -> CombinedV1FirstAdoption {
    let prepared = try combinedV1Fixture()
    var fixture = prepared.0
    let (first, firstResult, firstCandidate) = (prepared.1, prepared.2, prepared.3)
    try fixture.accept(first); try fixture.dispatchProvider(first)
    try fixture.command(.conversationHistoryCandidateObserved(operationID: first.id, candidate: firstCandidate, incarnation: fixture.incarnation))
    try fixture.finishProvider(first, result: .conversationHistoryConfirmed(firstResult))
    try fixture.dispatchFiles(first); try fixture.finishFiles(first)
    try fixture.command(.client(.dismissConversationHistoryRecall(operationID: first.id)))
    return .init(fixture: fixture, originalReference: first.sourceReference, result: firstResult)
}

private struct CombinedV1SecondAdoption {
    var fixture: ConversationHistoryFilesFixture
    let review: ConversationHistoryReview
    let result: ProviderConversationSnapshot
    let candidate: OpenCodeV1HistoryCandidate
    let originalReference: ProviderConversationReference
    let firstAdoptedReference: ProviderConversationReference
}

@inline(never)
private func prepareSecondV1Adoption(_ first: CombinedV1FirstAdoption) throws -> CombinedV1SecondAdoption {
    var fixture = first.fixture
    var thread = fixture.thread
    let newID = UUID(), inputID = "msg_zz_adopted_input", replyID = "msg_zz_adopted_reply"
    let started = fixture.now.addingTimeInterval(100)
    var record = ThreadRunRecord(run: .init(id: newID, configuration: .init(thread: thread), startedAt: started, nativeTurnID: inputID),
        origin: .user, userMessageID: "mixed-user-\(newID)")
    record.status = .completed; record.endedAt = started.addingTimeInterval(2); record.endReason = .providerCompleted
    record.messageAttributionVersion = 1
    record.checkpoints = .init(baseline: try ConversationHistoryFilesFixture.attempt(path: thread.workspacePath, date: started), providerReleased: true)
    record.checkpoints?.postRun = try ConversationHistoryFilesFixture.attempt(path: thread.workspacePath, date: started.addingTimeInterval(2))
    thread.runHistory?.append(record)
    var user = ChatMessage(id: "mixed-user-\(newID)", role: .user, text: "Input on adopted B")
    user.runReference = .init(threadID: thread.id, runID: newID)
    var reply = ChatMessage(id: "mixed-reply-\(newID)", role: .assistant, text: "Reply on adopted B"); reply.runReference = user.runReference
    thread.messages += [user, reply]; fixture.snapshot.threads[0] = thread
    let previousNative = try #require(first.result.openCodeV1)
    let source = try OpenCodeV1HistorySnapshot(reference: previousNative.reference, runtimeIdentity: previousNative.runtimeIdentity,
        workspacePath: previousNative.workspacePath, projectID: previousNative.projectID,
        sessionDigest: String(repeating: "c", count: 64), messages: previousNative.messages + [
            .init(id: inputID, role: .user, partIDs: ["prt_adopted_input"], contentDigest: String(repeating: "3", count: 64)),
            .init(id: replyID, role: .assistant, parentID: inputID, partIDs: ["prt_adopted_reply"], contentDigest: String(repeating: "4", count: 64))])
    // The public legacy resolver keeps its strict native-ID behavior. Only the
    // complete reviewed copy chain authorizes this mixed A/B checkpoint target.
    #expect(thread.conversationHistoryFileTarget(beforeRunID: newID) == .unavailable(.workspaceChanged))
    let (second, secondResult, secondCandidate) = try combinedV1Review(fixture: fixture, source: source,
        selected: newID, destination: "ses_combined_adopted_c")
    let files = try #require(second.files)
    #expect(files.target.checkpointRunID == fixture.runs[0] && files.target.stage == .postRun)
    #expect(second.openCodeV1?.inputs.map(\.originalReference.nativeThreadID) == [first.originalReference.nativeThreadID, first.result.reference.nativeThreadID])
    try fixture.snapshot.validateConversationHistoryFilesReview(second)
    return .init(fixture: fixture, review: second, result: secondResult, candidate: secondCandidate,
                 originalReference: first.originalReference, firstAdoptedReference: first.result.reference)
}

@inline(never)
private func finishSecondV1Adoption(_ prepared: CombinedV1SecondAdoption) throws {
    var fixture = prepared.fixture
    let second = prepared.review, secondResult = prepared.result, secondCandidate = prepared.candidate
    try fixture.accept(second); try fixture.dispatchProvider(second)
    try fixture.command(.conversationHistoryCandidateObserved(operationID: second.id, candidate: secondCandidate, incarnation: fixture.incarnation))
    try fixture.finishProvider(second, result: .conversationHistoryConfirmed(secondResult))
    try fixture.snapshot.validateConversationHistoryFilesSource(operationID: second.id)
    try fixture.dispatchFiles(second); try fixture.finishFiles(second)
    try fixture.command(.client(.editThread(fixture.threadID, .draft("Newest typing on C"))))
    try fixture.command(.client(.recallConversationHistoryPrompt(operationID: second.id)))
    #expect(fixture.thread.draft == "Newest typing on C\n\nInput on adopted B")
    #expect(fixture.thread.providerThreadID == secondResult.reference.nativeThreadID)
    #expect(fixture.thread.runHistory?.first?.providerThreadID == prepared.originalReference.nativeThreadID)
    #expect(fixture.thread.runHistory?.last?.providerThreadID == prepared.firstAdoptedReference.nativeThreadID)
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test func openCodeV1HistoryCombinedFilesRetainExactCheckpointAcrossMixedOriginalAndAdoptedRunOwners() throws {
    let first = try completeFirstV1Adoption()
    let second = try prepareSecondV1Adoption(first)
    try finishSecondV1Adoption(second)
}
