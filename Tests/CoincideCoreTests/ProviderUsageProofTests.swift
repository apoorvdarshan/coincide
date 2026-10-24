import Foundation
import Testing
@testable import CoincideCore

private struct ProviderUsageProofFixture {
    var base: CheckpointRestoreFixture
    let sessionID = UUID().uuidString.lowercased()
    let runtime: ClaudeRuntimeConfiguration
    let source: ClaudeHistorySnapshot
    var snapshot: WorkspaceSnapshot { get { base.snapshot } set { base.snapshot = newValue } }
    var thread: CodingThread { snapshot.threads[0] }
    init() throws {
        var base = try CheckpointRestoreFixture(provider: .claude), thread = base.snapshot.threads[0]
        let runtime = ClaudeRuntimeConfiguration(executable: "/fixture/unused-claude", configurationDirectory: "/fixture/private-claude", workspacePath: thread.workspacePath)
        thread.providerThreadID = sessionID; thread.claudeRuntimeConfiguration = runtime
        var configuration = ProviderConfiguration(thread: thread); configuration.nativeThreadID = nil
        let assistantID = UUID().uuidString.lowercased()
        let evidence = try Self.evidence(runID: base.runID, runtime: runtime, sessionID: sessionID, assistantID: assistantID)
        thread.runHistory?[0].configuration = configuration; thread.runHistory?[0].providerThreadID = sessionID
        thread.runHistory?[0].turnIDs = [] // Native envelope UUIDs are not provider turns.
        thread.runHistory?[0].claude = evidence
        base.snapshot.threads[0] = thread; self.base = base; self.runtime = runtime
        let records = [Self.record(id: evidence.openingInputID, parent: nil, kind: "user", text: "Retain the transcript", session: sessionID),
                       Self.record(id: assistantID, parent: evidence.openingInputID, kind: "assistant", text: "Retained reply", session: sessionID)]
        source = try .init(reference: .init(provider: .claude, nativeThreadID: sessionID), runtimeIdentity: runtime.runtimeIdentity,
            sourceLocation: .init(configurationDirectory: runtime.configurationDirectory, workspacePath: runtime.workspacePath,
                                  projectDirectoryName: runtime.projectKey, sessionID: sessionID), sourceRevision: Self.revision(),
            records: records.map { try .init($0) }, selectedMessages: records.map { try .init($0, projected: true) },
            selectedChainIDs: records.compactMap { $0["uuid"].string })
        try WorkspaceJournal.validate(base.snapshot)
    }
    static func evidence(runID: UUID, runtime: ClaudeRuntimeConfiguration, sessionID: String, assistantID: String) throws -> ClaudeRunHistoryEvidence {
        var evidence = try ClaudeRunHistoryEvidence(runID: runID, runtimeIdentity: runtime.runtimeIdentity, nativeSessionID: sessionID)
        try evidence.observe(nativeSessionID: sessionID, inputIDs: [evidence.openingInputID], rootAssistantMessageID: assistantID)
        try evidence.finish(.completed); return evidence
    }
    static func record(id: String, parent: String?, kind: String, text: String, session: String) -> JSONValue {
        .object(["type": .string(kind), "uuid": .string(id), "sessionId": .string(session), "parentUuid": parent.map(JSONValue.string) ?? .null,
                 "isSidechain": .bool(false), "message": .object(["role": .string(kind), "content": .string(text)])])
    }
    static func revision() throws -> ClaudeTranscriptRevision {
        try JSONDecoder().decode(ClaudeTranscriptRevision.self, from: JSONEncoder().encode(JSONValue.object([
            "device": .number(1), "inode": .number(2), "byteCount": .number(1_024), "modifiedSeconds": .number(1), "modifiedNanoseconds": .number(0),
            "changedSeconds": .number(1), "changedNanoseconds": .number(0), "digest": .string(String(repeating: "a", count: 64))])))
    }
    var point: ContextTransferResolvedPoint { .init(threadID: base.threadID, runID: base.runID) }
    func fingerprints() throws -> [String] {
        try [snapshot.historySourceFingerprint(threadID: base.threadID), snapshot.checkpointRestoreSourceFingerprint(threadID: base.threadID),
             snapshot.contextTransferFingerprint(thread, point: point)]
    }
    mutating func addUsage(revision: Int64 = 1) throws {
        let value = ProviderUsageUpdate.claude(try .init(runID: base.runID, revision: revision,
            turn: .init(usageStatus: .complete, inputTokens: Int(revision) * 17, cachedInputTokens: 3, cacheCreationTokens: 4,
                outputTokens: 7, reasoningTokens: 2), observedAt: base.now))
        base.snapshot.threads[0].runHistory?[0].providerUsage = value
        try WorkspaceJournal.validate(base.snapshot)
    }
    func historyReview() throws -> ConversationHistoryReview {
        let evidence = try ClaudeHistoryReviewEvidence.make(source: source, snapshot: snapshot, thread: thread, runID: base.runID, kind: .forkAfterRun)
        return try .init(kind: .forkAfterRun, reviewedAt: base.now, sourceThreadID: base.threadID, projectID: thread.projectID,
            runID: base.runID, sourceIncarnation: base.incarnation, sourceConfiguration: .init(thread: thread),
            targetConfiguration: try #require(thread.runHistory?.first?.configuration), sourceReference: source.reference,
            reviewedHeadTurnID: nil, boundary: evidence.boundary.providerBoundary, expectedResultHeadTurnID: nil,
            prefix: thread.transcriptPrefix(runID: base.runID, boundary: .afterRun), removedRunIDs: [], removedMessageIDs: [],
            sourceFingerprint: snapshot.historySourceFingerprint(threadID: base.threadID), targetThreadID: UUID(),
            suggestedTitle: "Reviewed accounting-independent fork", claude: evidence)
    }
    func contextReview() throws -> ContextTransferReview {
        var destination = ProviderConfiguration(thread: thread)
        destination.provider = .codex; destination.nativeThreadID = nil; destination.claudeRuntimeConfiguration = nil
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

@Test func providerUsageNeverChangesNativeHistoryFilesystemOrFrozenContextAuthority() throws {
    var f = try ProviderUsageProofFixture()
    let original = try f.fingerprints(), restore = try f.base.review(), context = try f.contextReview(), history = try f.historyReview()
    for revision in [Int64(1), Int64(2)] {
        try f.addUsage(revision: revision)
        #expect(try f.fingerprints() == original)
        try f.snapshot.validateCheckpointRestoreSource(restore)
        try f.snapshot.validateContextTransferReview(context)
        try f.snapshot.validateConversationHistorySource(history)
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
    case "native-boundary":
        let evidence = try ProviderUsageProofFixture.evidence(runID: f.base.runID, runtime: f.runtime,
            sessionID: f.sessionID, assistantID: UUID().uuidString.lowercased())
        f.base.snapshot.threads[0].runHistory?[0].claude = evidence
    case "model": f.base.snapshot.threads[0].model = "different-model"
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
