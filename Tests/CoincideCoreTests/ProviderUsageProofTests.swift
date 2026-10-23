import Foundation
import Testing
@testable import CoincideCore

private struct ProviderUsageProofFixture {
    var base: CheckpointRestoreFixture
    var snapshot: WorkspaceSnapshot { get { base.snapshot } set { base.snapshot = newValue } }
    var thread: CodingThread { snapshot.threads[0] }
    init(provider: ProviderKind = .opencode) throws {
        base = try .init(provider: provider)
        if provider == .opencode {
            base.snapshot.threads[0].model = ""
            base.snapshot.threads[0].openCodeConfiguration = .init(executable: "/fixture/unused-opencode")
            base.snapshot.threads[0].providerThreadID = "ses_usage_source"
            let configuration = ProviderConfiguration(thread: base.snapshot.threads[0])
            let opening = OpenCodeV2HistoryRunInput.openingMessageID(
                instanceID: base.snapshot.threads[0].openCodeConfiguration!.instanceID, runID: base.runID)
            base.snapshot.threads[0].runHistory?[0].configuration = configuration
            base.snapshot.threads[0].runHistory?[0].providerThreadID = "ses_usage_source"
            base.snapshot.threads[0].runHistory?[0].turnIDs = [opening]
        }
        try WorkspaceJournal.validate(base.snapshot)
    }
    var point: ContextTransferResolvedPoint { .init(threadID: base.threadID, runID: base.runID) }
    func fingerprints() throws -> [String] {
        try [snapshot.historySourceFingerprint(threadID: base.threadID), snapshot.checkpointRestoreSourceFingerprint(threadID: base.threadID),
             snapshot.contextTransferFingerprint(thread, point: point)]
    }
    mutating func addUsage(revision: Int64 = 1) throws {
        let value: ProviderUsageUpdate
        if thread.provider == .opencode {
            value = .openCode(try .init(usageStatus: .complete, inputTokens: Int(revision) * 17, cachedInputTokens: 3,
                cacheCreationTokens: 4, outputTokens: 7, reasoningTokens: 2))
        } else {
            value = .claude(try .init(runID: base.runID, revision: revision,
                turn: .init(usageStatus: .complete, inputTokens: Int(revision) * 17, cachedInputTokens: 3, cacheCreationTokens: 4,
                    outputTokens: 7, reasoningTokens: 2), observedAt: base.now))
        }
        base.snapshot.threads[0].runHistory?[0].providerUsage = value
        try WorkspaceJournal.validate(base.snapshot)
    }
    func historyReview() throws -> ConversationHistoryReview {
        let input = try #require(thread.runHistory?.first?.turnIDs.first)
        let native = try OpenCodeV2HistorySnapshot(reference: .init(provider: .opencode, nativeThreadID: "ses_usage_source"),
            runtimeIdentity: try #require(thread.openCodeConfiguration?.runtimeIdentity), workspacePath: thread.workspacePath,
            messages: [.init(id: input, kind: .user, contentDigest: String(repeating: "a", count: 64)),
                       .init(id: "msg_usage_assistant", kind: .assistant, contentDigest: String(repeating: "b", count: 64))])
        let evidence = try OpenCodeV2HistoryReviewEvidence.make(source: native, snapshot: snapshot, thread: thread,
            runID: base.runID, kind: .forkAfterRun)
        return try .init(kind: .forkAfterRun, reviewedAt: base.now, sourceThreadID: base.threadID, projectID: thread.projectID,
            runID: base.runID, sourceIncarnation: base.incarnation, sourceConfiguration: .init(thread: thread),
            targetConfiguration: try #require(thread.runHistory?.first?.configuration), sourceReference: native.reference,
            reviewedHeadTurnID: nil, boundary: evidence.boundary, expectedResultHeadTurnID: nil,
            prefix: thread.transcriptPrefix(runID: base.runID, boundary: .afterRun), removedRunIDs: [], removedMessageIDs: [],
            sourceFingerprint: snapshot.historySourceFingerprint(threadID: base.threadID), targetThreadID: UUID(),
            suggestedTitle: "Reviewed accounting-independent fork", openCodeV2: evidence)
    }
    func contextReview() throws -> ContextTransferReview {
        var destination = ProviderConfiguration(thread: thread)
        destination.provider = .codex; destination.nativeThreadID = nil; destination.openCodeConfiguration = nil
        destination.model = ""; destination.reasoningEffort = nil
        let request = ContextTransferReviewRequest(sourceThreadID: base.threadID, expectedConfiguration: .init(thread: thread),
            sourcePoint: .run(base.runID), intent: .fork(destination: destination))
        var review = ContextTransferReview(id: UUID(), digest: "", request: request, sourcePoint: point, basePoint: nil,
            targetThreadID: UUID(), projectID: thread.projectID, sourceConfiguration: .init(thread: thread), targetConfiguration: destination,
            targetProviderBinding: nil, strategy: .portableContext, title: "Portable accounting-independent context",
            messages: try snapshot.contextTransferMessages(thread: thread, through: point, ownRunsOnly: false), nativeReview: nil,
            sourceFingerprint: try snapshot.contextTransferFingerprint(thread, point: point), sourceIncarnation: base.incarnation,
            targetIncarnation: nil, reviewedAt: base.now)
        review.digest = try review.validatedDigest(); return review
    }
}

@Test(arguments: [ProviderKind.opencode, .claude])
func providerUsageNeverChangesNativeHistoryFilesystemOrFrozenContextAuthority(provider: ProviderKind) throws {
    var f = try ProviderUsageProofFixture(provider: provider)
    let original = try f.fingerprints(), restore = try f.base.review(), context = try f.contextReview()
    let history = provider == .opencode ? try f.historyReview() : nil
    for revision in [Int64(1), Int64(2)] {
        try f.addUsage(revision: revision)
        #expect(try f.fingerprints() == original)
        try f.snapshot.validateCheckpointRestoreSource(restore)
        try f.snapshot.validateContextTransferReview(context)
        if let history { try f.snapshot.validateConversationHistorySource(history) }
        let retained = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(f.snapshot))
        #expect(retained.threads[0].runHistory?[0].providerUsage == f.thread.runHistory?[0].providerUsage)
    }
}

@Test(arguments: ["transcript", "native-boundary", "model", "checkpoint"])
func providerUsageProofExclusionRetainsEveryOriginalContentConfigurationAndCheckpointGuard(change: String) throws {
    var f = try ProviderUsageProofFixture(); try f.addUsage()
    let original = try f.fingerprints(), restore = try f.base.review(), context = try f.contextReview(), history = try f.historyReview()
    switch change {
    case "transcript": f.base.snapshot.threads[0].messages[0].text += " changed authored content"
    case "native-boundary": f.base.snapshot.threads[0].runHistory?[0].turnIDs = ["msg_different_native_boundary"]
    case "model":
        let model = OpenCodeModelSelection(providerID: "fixture-provider", id: "different-model")
        let configuration = f.thread.openCodeConfiguration?.selecting(model: model)
        f.base.snapshot.threads[0].openCodeConfiguration = configuration
        f.base.snapshot.threads[0].model = model.catalogID
    default: f.base.snapshot.threads[0].runHistory?[0].checkpoints?.baseline.updatedAt.addTimeInterval(1)
    }
    let changed = try f.fingerprints()
    #expect(changed[1] != original[1] && changed[2] != original[2])
    #expect(throws: WorkspaceCommandError.self) { try f.snapshot.validateCheckpointRestoreSource(restore) }
    #expect(throws: ContextTransferError.staleReview) { try f.snapshot.validateContextTransferReview(context) }
    if change == "checkpoint" {
        // Native transcript authority already excludes filesystem observations.
        #expect(changed[0] == original[0]); try f.snapshot.validateConversationHistorySource(history)
    } else {
        #expect(changed[0] != original[0])
        #expect(throws: WorkspaceCommandError.self) { try f.snapshot.validateConversationHistorySource(history) }
    }
}
