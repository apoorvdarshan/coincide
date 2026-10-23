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

private extension V1ProvenanceFixture {
    mutating func addFirstRunSteering() throws {
        let configuration = try #require(thread.runHistory?.first?.configuration)
        let input = QueuedTurn(id: UUID(), text: "Steering within the first execution", configuration: configuration, createdAt: .now)
        var operation = PromptSteeringOperation(threadID: thread.id, projectID: thread.projectID,
            sourceIncarnation: incarnation, runtimeID: UUID(), runID: runIDs[0], nativeThreadID: observed.reference.nativeThreadID,
            nativeTurnID: "msg_100", input: input, messageID: "steering-authored-first", configuration: configuration, phase: .delivered)
        operation.receipt = try .init(turnID: "msg_100")
        try operation.validate()
        snapshot.promptSteerings = [operation]
        var row = ChatMessage(id: operation.messageID, role: .user, text: input.text)
        row.promptSteeringID = operation.id; row.runReference = .init(threadID: thread.id, runID: runIDs[0])
        row.providerEntity = .init(key: .init(sessionID: observed.reference.nativeThreadID, type: "user_message", id: "msg_150"))
        snapshot.threads[0].messages.insert(row, at: 2)
        var messages = observed.messages
        messages.insert(contentsOf: [try .init(id: "msg_150", role: .user, partIDs: ["prt_steer"], contentDigest: String(repeating: "3", count: 64)),
            try .init(id: "msg_160", role: .assistant, parentID: "msg_150", partIDs: ["prt_steer_reply"], contentDigest: String(repeating: "4", count: 64))], at: 2)
        observed = try .init(reference: observed.reference, runtimeIdentity: observed.runtimeIdentity,
            workspacePath: observed.workspacePath, projectID: observed.projectID, sessionDigest: observed.sessionDigest, messages: messages)
    }
}

@Test func openCodeV1SteeringHistoryKeepsInputsInsideOriginalPhysicalRunAndThroughClone() throws {
    var f = try V1ProvenanceFixture()
    try f.addFirstRunSteering()
    let first = try OpenCodeV1HistoryReviewEvidence.make(source: f.observed, snapshot: f.snapshot,
        thread: f.thread, runID: f.runIDs[0], kind: .forkAfterRun)
    #expect(first.retainedMessageCount == 4)
    #expect(first.inputs[0].steeringMessageIDs == ["msg_150"])
    #expect(f.thread.runHistory?.first?.turnIDs == ["msg_100"])
    let rewind = try f.review(index: 2)
    try f.adopt(rewind, nativeID: "ses_steer_clone")
    let mapped = try OpenCodeV1HistoryReviewEvidence.make(source: f.observed, snapshot: f.snapshot,
        thread: f.thread, runID: f.runIDs[0], kind: .forkAfterRun)
    #expect(mapped.retainedMessageCount == 4)
    #expect(mapped.inputs[0].steeringMessageIDs == [f.observed.messages[2].id])
    #expect(mapped.inputs[0].originalMessageID == "msg_100")
    let changed = try f.changing(f.observed, messageAt: 2)
    #expect(throws: ProviderHistoryError.self) {
        try OpenCodeV1HistoryReviewEvidence.make(source: changed, snapshot: f.snapshot,
            thread: f.thread, runID: f.runIDs[0], kind: .forkAfterRun)
    }
}

@Test(arguments: ["missing-association", "foreign-session", "wrong-run", "failed-audit", "wrong-target"])
func openCodeV1SteeringHistoryRequiresExactAuthoredNativeOwnership(fault: String) throws {
    var f = try V1ProvenanceFixture()
    try f.addFirstRunSteering()
    let index = try #require(f.snapshot.threads[0].messages.firstIndex { $0.id == "steering-authored-first" })
    switch fault {
    case "missing-association": f.snapshot.threads[0].messages[index].providerEntity = nil
    case "foreign-session": f.snapshot.threads[0].messages[index].providerEntity?.key.sessionID = "ses_foreign"
    case "wrong-run": f.snapshot.threads[0].messages[index].runReference = .init(threadID: f.thread.id, runID: f.runIDs[1])
    case "failed-audit":
        f.snapshot.promptSteerings?[0].phase = .failed
        f.snapshot.promptSteerings?[0].receipt = nil
        f.snapshot.promptSteerings?[0].error = PromptSteeringOperation.failureMessage
    default:
        let configuration = try #require(f.thread.runHistory?.first?.configuration)
        var operation = PromptSteeringOperation(threadID: f.thread.id, projectID: f.thread.projectID,
            sourceIncarnation: f.incarnation, runtimeID: UUID(), runID: f.runIDs[0], nativeThreadID: f.observed.reference.nativeThreadID,
            nativeTurnID: "msg_200", input: .init(id: UUID(), text: "Wrong target", configuration: configuration, createdAt: .now),
            messageID: "steering-authored-first", configuration: configuration, phase: .delivered)
        operation.receipt = try .init(turnID: "msg_200"); f.snapshot.promptSteerings = [operation]
    }
    #expect(throws: ProviderHistoryError.self) {
        try OpenCodeV1HistoryReviewEvidence.make(source: f.observed, snapshot: f.snapshot,
            thread: f.thread, runID: f.runIDs[0], kind: .forkAfterRun)
    }
}

@Test func openCodeV1SteeringHistoryRejectsCrossRunOwnershipAndKeepsLegacyEncoding() throws {
    var f = try V1ProvenanceFixture()
    try f.addFirstRunSteering()
    let evidence = try OpenCodeV1HistoryReviewEvidence.make(source: f.observed, snapshot: f.snapshot,
        thread: f.thread, runID: f.runIDs[0], kind: .forkAfterRun)
    var inputs = evidence.inputs
    inputs[0] = .init(runID: inputs[0].runID, originalReference: inputs[0].originalReference,
        originalMessageID: inputs[0].originalMessageID, openingMessageID: inputs[0].openingMessageID, steeringMessageIDs: ["msg_200"])
    #expect(throws: ProviderHistoryError.self) {
        try OpenCodeV1HistoryReviewEvidence(source: evidence.source, boundary: evidence.boundary,
            retainedMessageCount: evidence.retainedMessageCount, selectedOpeningMessageID: evidence.selectedOpeningMessageID, inputs: inputs)
    }
    let legacy = OpenCodeV1HistoryRunInput(runID: UUID(), originalReference: f.observed.reference,
        originalMessageID: "msg_100", openingMessageID: "msg_100")
    let encoded = try JSONEncoder().encode(legacy)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["steeringMessageIDs"] == nil)
    #expect(try JSONDecoder().decode(OpenCodeV1HistoryRunInput.self, from: encoded) == legacy)
}
