import Foundation
import Testing
@testable import CoincideCore

private struct V1ProvenanceFixture {
    var snapshot = WorkspaceSnapshot()
    var observed: OpenCodeV1HistorySnapshot
    let runIDs = (0..<3).map { _ in UUID() }
    let incarnation = UUID()
    var thread: CodingThread { snapshot.threads[0] }

    init() throws {
        let project = WorkspaceProject(path: "/fixture/v1-user-provenance")
        var thread = CodingThread(project: project)
        thread.provider = .opencode
        thread.openCodeConfiguration = .init(generation: .v1, executable: "/fixture/opencode")
        thread.providerThreadID = "ses_provenance_a"
        thread.checkpointPolicy = .disabled
        var native: [OpenCodeV1HistoryMessage] = []
        for (index, id) in runIDs.enumerated() {
            let input = "msg_\((index + 1) * 100)", reply = "msg_\((index + 1) * 100 + 10)"
            let run = ActiveRun(id: id, configuration: .init(thread: thread), startedAt: .now, nativeTurnID: input)
            var record = ThreadRunRecord(run: run, origin: .user, userMessageID: "user-\(id)")
            record.status = .completed; record.endedAt = .now; record.endReason = .providerCompleted
            record.messageAttributionVersion = 1
            if thread.runHistory == nil { thread.runHistory = [] }; thread.runHistory?.append(record)
            var user = ChatMessage(id: "user-\(id)", role: .user, text: "Input \(index)")
            user.runReference = .init(threadID: thread.id, runID: id)
            var assistant = ChatMessage(id: "reply-\(id)", role: .assistant, text: "Reply \(index)")
            assistant.runReference = user.runReference; thread.messages += [user, assistant]
            native += [try .init(id: input, role: .user, partIDs: ["prt_input_\(index)"], contentDigest: String(repeating: "1", count: 64)),
                       try .init(id: reply, role: .assistant, parentID: input, partIDs: ["prt_reply_\(index)"], contentDigest: String(repeating: "2", count: 64))]
        }
        observed = try .init(reference: .init(provider: .opencode, nativeThreadID: "ses_provenance_a"),
            runtimeIdentity: thread.openCodeConfiguration!.runtimeIdentity, workspacePath: project.path,
            projectID: "provenance-project", sessionDigest: String(repeating: "a", count: 64), messages: native)
        snapshot.projects = [project]; snapshot.threads = [thread]
    }

    func review(index: Int, source: OpenCodeV1HistorySnapshot? = nil,
                replacingEvidence: OpenCodeV1HistoryReviewEvidence? = nil) throws -> ConversationHistoryReview {
        let runID = runIDs[index], source = source ?? observed
        let record = try #require(thread.runHistory?.first { $0.id == runID })
        let evidence = try replacingEvidence ?? OpenCodeV1HistoryReviewEvidence.make(source: source, snapshot: snapshot,
            thread: thread, runID: runID, kind: .rewindBeforeRun)
        let prefix = try thread.transcriptPrefix(runID: runID, boundary: .beforeRun)
        let first = try #require(thread.activeHistoryRuns.firstIndex { $0.id == runID }), prefixIDs = Set(prefix.map(\.id))
        return try .init(kind: .rewindBeforeRun, sourceThreadID: thread.id, projectID: thread.projectID,
            runID: runID, sourceIncarnation: incarnation, sourceConfiguration: .init(thread: thread), targetConfiguration: record.configuration,
            sourceReference: source.reference, reviewedHeadTurnID: nil, boundary: evidence.boundary, expectedResultHeadTurnID: nil,
            prefix: prefix, removedRunIDs: thread.activeHistoryRuns.dropFirst(first).map(\.id),
            removedMessageIDs: thread.visibleMessages.filter { !prefixIDs.contains($0.id) }.map(\.id),
            sourceFingerprint: snapshot.historySourceFingerprint(threadID: thread.id), targetThreadID: nil,
            suggestedTitle: "Native user provenance", openCodeV1: evidence)
    }

    mutating func adopt(_ review: ConversationHistoryReview, nativeID: String) throws {
        let proof = try #require(review.openCodeV1)
        let prefix = Array(proof.source.messages.prefix(proof.retainedMessageCount))
        let ids = Dictionary(uniqueKeysWithValues: prefix.enumerated().map { ($0.element.id, "msg_\(nativeID)_\($0.offset)") })
        let copied = try prefix.enumerated().map { index, message in
            try OpenCodeV1HistoryMessage(id: #require(ids[message.id]), role: message.role,
                parentID: message.parentID.flatMap { ids[$0] }, partIDs: message.partIDs.enumerated().map { "prt_\(nativeID)_\(index)_\($0.offset)" },
                contentDigest: message.contentDigest, isSettled: message.isSettled, isInternalUserInput: message.isInternalUserInput)
        }
        let result = try OpenCodeV1HistorySnapshot(reference: .init(provider: .opencode, nativeThreadID: nativeID),
            runtimeIdentity: proof.source.runtimeIdentity, workspacePath: proof.source.workspacePath,
            projectID: proof.source.projectID, workspaceID: proof.source.workspaceID,
            sessionDigest: String(repeating: "b", count: 64), messages: copied)
        let candidate = try OpenCodeV1HistoryCandidate(reference: result.reference, sourceInventoryDigest: proof.source.inventoryDigest,
            runtimeIdentity: result.runtimeIdentity, workspacePath: result.workspacePath, boundary: proof.boundary)
        let operation = ConversationHistoryOperation(review: review, phase: .applied,
            result: try .init(reference: result.reference, workspacePath: result.workspacePath, historyMode: .messageOrdered, openCodeV1: result),
            openCodeV1Candidate: candidate)
        try operation.validate()
        if snapshot.conversationHistoryOperations == nil { snapshot.conversationHistoryOperations = [] }
        snapshot.conversationHistoryOperations?.append(operation)
        var updated = thread
        for i in updated.messages.indices where review.removedMessageIDs.contains(updated.messages[i].id) {
            updated.messages[i].removedByHistoryOperationID = review.id
        }
        for i in (updated.runHistory ?? []).indices where review.removedRunIDs.contains(updated.runHistory![i].id) {
            updated.runHistory?[i].removedByHistoryOperationID = review.id
        }
        updated.providerThreadID = nativeID; snapshot.threads[0] = updated; observed = result
    }

    func changing(_ source: OpenCodeV1HistorySnapshot, messageAt index: Int, parts: Bool = false) throws -> OpenCodeV1HistorySnapshot {
        var messages = source.messages
        let original = messages[index]
        messages[index] = try .init(id: original.id, role: original.role, parentID: original.parentID,
            partIDs: parts ? ["prt_changed_native_user"] : original.partIDs,
            contentDigest: parts ? original.contentDigest : String(repeating: "f", count: 64),
            isSettled: original.isSettled, isInternalUserInput: original.isInternalUserInput)
        return try .init(reference: source.reference, runtimeIdentity: source.runtimeIdentity,
            workspacePath: source.workspacePath, projectID: source.projectID, workspaceID: source.workspaceID,
            sessionDigest: String(repeating: "c", count: 64), messages: messages)
    }
}

@Test(arguments: [false, true])
func openCodeV1HistoryEvidenceRejectsChangedCurrentNativeUserDespiteRetainedID(parts: Bool) throws {
    var fixture = try V1ProvenanceFixture()
    let first = try fixture.review(index: 2)
    try fixture.adopt(first, nativeID: "ses_provenance_b")
    let altered = try fixture.changing(fixture.observed, messageAt: 0, parts: parts)
    #expect(throws: ProviderHistoryError.self) {
        try OpenCodeV1HistoryReviewEvidence.make(source: altered, snapshot: fixture.snapshot,
            thread: fixture.thread, runID: fixture.runIDs[0], kind: .forkAfterRun)
    }
}

@Test(arguments: [false, true])
func openCodeV1HistoryEvidenceRejectsForgedIntermediateNativeUserCopyLedger(parts: Bool) throws {
    var fixture = try V1ProvenanceFixture()
    let first = try fixture.review(index: 2)
    try fixture.adopt(first, nativeID: "ses_provenance_b")
    let legitimate = try #require(fixture.review(index: 1).openCodeV1)
    let altered = try fixture.changing(fixture.observed, messageAt: 0, parts: parts)
    let forged = try OpenCodeV1HistoryReviewEvidence(source: altered, boundary: legitimate.boundary,
        retainedMessageCount: legitimate.retainedMessageCount, selectedOpeningMessageID: legitimate.selectedOpeningMessageID,
        inputs: legitimate.inputs)
    let second = try fixture.review(index: 1, source: altered, replacingEvidence: forged)
    try fixture.adopt(second, nativeID: "ses_provenance_c")
    #expect(throws: ProviderHistoryError.self) { try OpenCodeV1HistoryReviewEvidence.validateAdoptionLedger(in: fixture.snapshot) }
}

@Test func openCodeV1HistoryEvidenceAllowsAssistantPruningWhilePreservingNativeUserProvenance() throws {
    var fixture = try V1ProvenanceFixture()
    let first = try fixture.review(index: 2)
    try fixture.adopt(first, nativeID: "ses_provenance_b")
    let prunedB = try fixture.changing(fixture.observed, messageAt: 1)
    let second = try fixture.review(index: 1, source: prunedB)
    try fixture.adopt(second, nativeID: "ses_provenance_c")
    try OpenCodeV1HistoryReviewEvidence.validateAdoptionLedger(in: fixture.snapshot)
    let prunedC = try fixture.changing(fixture.observed, messageAt: 1)
    let final = try OpenCodeV1HistoryReviewEvidence.make(source: prunedC, snapshot: fixture.snapshot,
        thread: fixture.thread, runID: fixture.runIDs[0], kind: .forkAfterRun)
    #expect(final.inputs.first?.originalReference.nativeThreadID == "ses_provenance_a")
    #expect(final.inputs.first?.openingMessageID == prunedC.messages[0].id)
}

@Test func openCodeV1HistoryEvidenceLimitDoesNotRejectLargeUnrelatedCodexAudit() throws {
    let project = WorkspaceProject(path: "/fixture/legacy-codex-history-audit")
    var thread = CodingThread(project: project)
    thread.provider = .codex; thread.providerThreadID = "legacy-codex-session"
    let configuration = ProviderConfiguration(thread: thread)
    let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000), incarnation = UUID()
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    snapshot.conversationHistoryOperations = try (0...10_000).map { _ in
        let review = try ConversationHistoryReview(kind: .forkAfterRun, reviewedAt: reviewedAt,
            sourceThreadID: thread.id, projectID: project.id, runID: UUID(), sourceIncarnation: incarnation,
            sourceConfiguration: configuration, targetConfiguration: configuration,
            sourceReference: .init(provider: .codex, nativeThreadID: "legacy-codex-session"),
            reviewedHeadTurnID: "legacy-turn", boundary: .throughTurn("legacy-turn"), expectedResultHeadTurnID: "legacy-turn",
            prefix: [], removedRunIDs: [], removedMessageIDs: [], sourceFingerprint: String(repeating: "a", count: 64),
            targetThreadID: UUID(), suggestedTitle: "Preserved Codex audit")
        let operation = ConversationHistoryOperation(review: review, phase: .failed,
            error: ConversationHistoryOperation.failureMessage)
        try operation.validate()
        return operation
    }
    #expect(snapshot.conversationHistoryOperations?.count == 10_001)
    // Only the V1 ledger's unrelated-record contract is under test here; this
    // bounded helper must leave legacy Codex audit capacity to its own validator.
    try OpenCodeV1HistoryReviewEvidence.validateAdoptionLedger(in: snapshot)
}
