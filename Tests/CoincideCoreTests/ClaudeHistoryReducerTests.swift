import Foundation
import Testing
@testable import CoincideCore

private struct ClaudeHistoryReducerFixture {
    var base: ConversationHistoryFilesFixture
    let sessionID = UUID().uuidString.lowercased()
    let assistants = (0..<3).map { _ in UUID().uuidString.lowercased() }
    var source: ClaudeHistorySnapshot
    var thread: CodingThread { base.thread }

    init() throws {
        var base = try ConversationHistoryFilesFixture(), thread = base.thread
        let runtime = ClaudeRuntimeConfiguration(executable: "/fixture/claude", configurationDirectory: "/fixture/private-claude", workspacePath: thread.workspacePath)
        thread.provider = .claude; thread.providerThreadID = sessionID; thread.claudeRuntimeConfiguration = runtime
        var records: [JSONValue] = [], parent: String?
        for index in thread.runHistory!.indices {
            let runID = thread.runHistory![index].id
            var configuration = ProviderConfiguration(thread: thread); configuration.nativeThreadID = index == 0 ? nil : sessionID
            thread.runHistory?[index].configuration = configuration; thread.runHistory?[index].providerThreadID = sessionID
            thread.runHistory?[index].turnIDs = [] // Native envelope UUIDs are not provider turns.
            var evidence = try ClaudeRunHistoryEvidence(runID: runID, runtimeIdentity: runtime.runtimeIdentity, nativeSessionID: sessionID)
            try evidence.observe(nativeSessionID: sessionID, inputIDs: [evidence.openingInputID], rootAssistantMessageID: assistants[index]); try evidence.finish(.completed)
            thread.runHistory?[index].claude = evidence
            let user = Self.record(id: evidence.openingInputID, parent: parent, kind: "user", text: "Original prompt \(index)", session: sessionID)
            let reply = Self.record(id: assistants[index], parent: evidence.openingInputID, kind: "assistant", text: "Original reply \(index)", session: sessionID)
            records += [user, reply]; parent = assistants[index]
        }
        base.snapshot.threads[0] = thread; self.base = base
        source = try Self.snapshot(records, runtime: runtime, sessionID: sessionID, digest: "a")
    }
    static func record(id: String, parent: String?, kind: String, text: String, session: String) -> JSONValue {
        .object(["type": .string(kind), "uuid": .string(id), "sessionId": .string(session), "parentUuid": parent.map(JSONValue.string) ?? .null,
                 "isSidechain": .bool(false), "message": .object(["role": .string(kind), "content": .string(text)])])
    }
    static func revision(_ digest: String) throws -> ClaudeTranscriptRevision {
        try JSONDecoder().decode(ClaudeTranscriptRevision.self, from: JSONEncoder().encode(JSONValue.object([
            "device": .number(1), "inode": .number(2), "byteCount": .number(1_024), "modifiedSeconds": .number(1), "modifiedNanoseconds": .number(0),
            "changedSeconds": .number(1), "changedNanoseconds": .number(0), "digest": .string(String(repeating: digest, count: 64))])))
    }
    static func snapshot(_ values: [JSONValue], runtime: ClaudeRuntimeConfiguration, sessionID: String, digest: String) throws -> ClaudeHistorySnapshot {
        try .init(reference: .init(provider: .claude, nativeThreadID: sessionID), runtimeIdentity: runtime.runtimeIdentity,
            sourceLocation: .init(configurationDirectory: runtime.configurationDirectory, workspacePath: runtime.workspacePath,
                                  projectDirectoryName: runtime.projectKey, sessionID: sessionID), sourceRevision: revision(digest),
            records: values.map { try .init($0) }, selectedMessages: values.map { try .init($0, projected: true) },
            selectedChainIDs: values.compactMap { $0["uuid"].string })
    }
    func review(_ kind: ConversationHistoryKind = .rewindBeforeRun, index: Int = 1, files: Bool = false, recall: Bool = false) throws -> ConversationHistoryReview {
        let selected = base.runs[index], record = thread.runHistory![index]
        let evidence = try ClaudeHistoryReviewEvidence.make(source: source, snapshot: base.snapshot, thread: thread, runID: selected, kind: kind)
        let prefix = try thread.transcriptPrefix(runID: selected, boundary: kind == .forkAfterRun ? .afterRun : .beforeRun), prefixIDs = Set(prefix.map(\.id))
        let id = UUID()
        func make(_ fileReview: ConversationHistoryFilesReview?) throws -> ConversationHistoryReview {
            try .init(id: id, kind: kind, reviewedAt: base.now, sourceThreadID: thread.id, projectID: thread.projectID,
                runID: selected, sourceIncarnation: base.incarnation, sourceConfiguration: .init(thread: thread), targetConfiguration: record.configuration,
                sourceReference: source.reference, reviewedHeadTurnID: nil, boundary: evidence.boundary.providerBoundary, expectedResultHeadTurnID: nil,
                prefix: prefix, removedRunIDs: kind == .rewindBeforeRun ? thread.activeHistoryRuns.dropFirst(index).map(\.id) : [],
                removedMessageIDs: kind == .rewindBeforeRun ? thread.visibleMessages.filter { !prefixIDs.contains($0.id) }.map(\.id) : [],
                sourceFingerprint: base.snapshot.historySourceFingerprint(threadID: thread.id), targetThreadID: kind == .forkAfterRun ? UUID() : nil,
                suggestedTitle: "Verified Claude context", files: fileReview, recallPromptOnSuccess: recall ? true : nil, claude: evidence)
        }
        let keep = try make(nil)
        guard files else { return keep }
        guard case .available(let target) = try base.snapshot.conversationHistoryFileTarget(for: keep) else { throw CoincideError("The synthetic Claude file target is unavailable.") }
        let git = try GitCheckpointRestoreReview(targetReceipt: target.receipt, currentPlan: CheckpointRestoreFixture.plan(path: thread.workspacePath),
            reviewedAt: base.now, manifestDigest: String(repeating: "e", count: 64), affectedPaths: ["tracked.swift"])
        return try make(.init(id: git.id, target: target, sourceFingerprint: base.snapshot.checkpointRestoreSourceFingerprint(threadID: thread.id), gitReview: git))
    }
    func rewindResult(_ review: ConversationHistoryReview, selectionID: UUID? = nil) throws -> ProviderConversationSnapshot {
        let evidence = try #require(review.claude), selection: ClaudeResumeSelection
        switch evidence.boundary {
        case .throughMessage(let cursor):
            selection = try .init(id: selectionID ?? review.id, nativeSessionID: sessionID, cursor: cursor,
                discardedInputID: evidence.inputs.first(where: { $0.runID == review.runID })?.openingInputID, kind: .resumeAt,
                reviewedLocation: source.sourceLocation, reviewedRevision: source.sourceRevision)
        case .freshSession(let reserved): selection = try .init(id: selectionID ?? review.id, nativeSessionID: reserved, kind: .freshSession)
        }
        let result = ClaudeHistoryResult.contextSelected(source: source, selection: selection)
        return try .init(reference: result.reference, workspacePath: thread.workspacePath, historyMode: .nativeTranscript, claude: result)
    }
    func forkResult(_ review: ConversationHistoryReview) throws -> (ClaudeTranscriptPublication, ProviderConversationSnapshot) {
        let evidence = try #require(review.claude), runtime = try #require(thread.claudeRuntimeConfiguration), targetID = UUID().uuidString.lowercased()
        let retained = Array(source.selectedMessages.prefix(evidence.retainedMessageIDs.count))
        var mapping: [String: String] = [:], native: [JSONValue] = [], parent: String?
        for (index, message) in retained.enumerated() {
            let id = UUID().uuidString.lowercased(); mapping[message.id!] = id
            native.append(Self.record(id: id, parent: parent, kind: message.kind, text: "Original \(message.kind == "user" ? "prompt" : "reply") \(index / 2)", session: targetID)); parent = id
        }
        let target = try Self.snapshot(native, runtime: runtime, sessionID: targetID, digest: "b")
        let publication = try ClaudeTranscriptPublication(source: #require(source.sourceLocation), sourceRevision: #require(source.sourceRevision),
            target: #require(target.sourceLocation), targetDigest: #require(target.sourceRevision).digest, targetByteCount: 1_024,
            upToMessageID: evidence.retainedMessageIDs.last, sourceToForkMessageIDs: mapping, headMessageID: parent)
        let inherited = try ClaudeInheritedHead(runtimeIdentity: runtime.runtimeIdentity, nativeSessionID: targetID, cursor: #require(parent))
        let result = ClaudeHistoryResult.fork(snapshot: target, publication: publication, inheritedHead: inherited)
        return (publication, try .init(reference: target.reference, workspacePath: thread.workspacePath, historyMode: .nativeTranscript, claude: result))
    }
}

@Test(arguments: [0, 1])
func claudeHistoryReducerDefersContextPreservesSettingsAndValidatesFilesBeforeExactlyOnceRecall(index: Int) throws {
    var fixture = try ClaudeHistoryReducerFixture()
    let review = try fixture.review(index: index, files: true, recall: true), before = fixture.thread, result = try fixture.rewindResult(review)
    #expect(fixture.base.snapshot.conversationHistoryUnavailableReason(threadID: before.id, runID: review.runID, kind: .rewindBeforeRun) == nil)
    try fixture.base.accept(review); try fixture.base.dispatchProvider(review)
    try fixture.base.finishProvider(review, result: .conversationHistoryConfirmed(result))
    let operation = try fixture.base.operation(review)
    #expect(operation.phase == .applied && operation.files?.phase == .accepted)
    #expect(fixture.thread.claudeResumeSelection == result.claude?.selection && fixture.thread.claudeResumeConsumerRunID == nil)
    #expect(fixture.thread.draft == before.draft && fixture.thread.model == before.model && fixture.thread.permission == before.permission)
    #expect(fixture.thread.runHistory?.map(\.providerThreadID) == before.runHistory?.map(\.providerThreadID))
    #expect(fixture.thread.runHistory?.allSatisfy({ $0.turnIDs.isEmpty }) == true)
    try fixture.base.snapshot.validateConversationHistoryFilesSource(operationID: review.id)
    for change in ["native", "selection", "model"] {
        var changed = fixture.base.snapshot
        if change == "native" { changed.threads[0].providerThreadID = UUID().uuidString.lowercased() }
        else if change == "selection" { changed.threads[0].claudeResumeSelection = nil }
        else { changed.threads[0].model = "Unreviewed model" }
        let fingerprint = try changed.checkpointRestoreSourceFingerprint(threadID: before.id)
        changed.conversationHistoryOperations?[0].files?.postHistorySourceFingerprint = fingerprint
        #expect(throws: (any Error).self) { try changed.validateConversationHistoryFilesSource(operationID: review.id) }
    }
    #expect(throws: WorkspaceCommandError.self) { try fixture.base.command(.client(.recallConversationHistoryPrompt(operationID: review.id))) }
    try fixture.base.dispatchFiles(review); try fixture.base.finishFiles(review)
    try fixture.base.command(.client(.editThread(before.id, .draft("Latest typing after context selected"))))
    try fixture.base.command(.client(.recallConversationHistoryPrompt(operationID: review.id)))
    #expect(fixture.thread.draft == "Latest typing after context selected\n\nOriginal prompt \(index)")
    #expect(fixture.base.snapshot.isClaudeResumeSelectionPending(operationID: review.id))
    #expect(try !fixture.base.operation(review).locksSource)
    let once = fixture.base.snapshot
    try fixture.base.command(.client(.recallConversationHistoryPrompt(operationID: review.id)))
    #expect(fixture.base.snapshot == once && fixture.thread.activeRun == nil && fixture.thread.queuedTurns.isEmpty)
    try WorkspaceJournal.validate(fixture.base.snapshot)
}

@Test func claudeHistoryReducerRequiresExactJournaledForkReservationBeforeTargetAdoptionAndRecoversReadOnly() throws {
    var fixture = try ClaudeHistoryReducerFixture()
    let review = try fixture.review(.forkAfterRun), prepared = try fixture.forkResult(review), before = fixture.thread
    let publication = prepared.0, result = prepared.1
    try fixture.base.accept(review); try fixture.base.dispatchProvider(review)
    try fixture.base.finishProvider(review, result: .conversationHistoryConfirmed(result))
    #expect(try fixture.base.operation(review).phase == .unconfirmed)
    #expect(fixture.base.snapshot.threads.count == 1 && fixture.thread == before)
    // A lost response before the reservation cannot claim an arbitrary target.
    var unreconciled = WorkspaceDecision(snapshot: fixture.base.snapshot)
    #expect(throws: (any Error).self) { try unreconciled.reconcileConversationHistory(operationID: review.id, result: .applied(result), now: fixture.base.now) }

    var fresh = try ClaudeHistoryReducerFixture()
    let freshReview = try fresh.review(.forkAfterRun)
    let exact = try fresh.forkResult(freshReview)
    try fresh.base.accept(freshReview); try fresh.base.dispatchProvider(freshReview)
    try fresh.base.command(.conversationHistoryClaudeForkReserved(operationID: freshReview.id, publication: exact.0, incarnation: fresh.base.incarnation))
    #expect(fresh.base.snapshot.threads.count == 1)
    try fresh.base.finishProvider(freshReview, result: .conversationHistoryUnconfirmed)
    #expect(fresh.base.snapshot.canInspectConversationHistory(operationID: freshReview.id))
    let reopened = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(fresh.base.snapshot))
    fresh.base.snapshot = reopened
    try fresh.base.command(.conversationHistoryReconciled(operationID: freshReview.id, incarnation: UUID(), result: .applied(exact.1)))
    let child = try #require(fresh.base.snapshot.threads.first(where: { $0.id == freshReview.targetThreadID }))
    #expect(child.providerThreadID == exact.1.reference.nativeThreadID && child.claudeInheritedHead == exact.1.claude?.inheritedHead)
    #expect(child.claudeRuntimeConfiguration == freshReview.targetConfiguration.claudeRuntimeConfiguration)
    #expect(child.claudeResumeSelection == nil && child.claudeResumeConsumerRunID == nil && child.draft.isEmpty && child.runHistory == nil)
    #expect(child.messages == freshReview.prefix && fresh.thread.draft == before.draft)
    #expect(publication.target.sessionID != exact.0.target.sessionID)
    try WorkspaceJournal.validate(fresh.base.snapshot)
    var tampered = fresh.base.snapshot
    let childIndex = try #require(tampered.threads.firstIndex(where: { $0.id == child.id }))
    tampered.threads[childIndex].claudeInheritedHead = nil
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(tampered) }
}

@Test func claudeHistoryReducerReservesPhysicalSourceAndCandidateAcrossLauncherAliasesAndRejectsWrongSelectionReceipt() throws {
    var fixture = try ClaudeHistoryReducerFixture()
    let review = try fixture.review(index: 0)
    try fixture.base.accept(review); try fixture.base.dispatchProvider(review)
    let wrong = try fixture.rewindResult(review, selectionID: UUID())
    try fixture.base.finishProvider(review, result: .conversationHistoryConfirmed(wrong))
    #expect(try fixture.base.operation(review).phase == .unconfirmed)
    #expect(fixture.thread.claudeResumeSelection == nil)
    var alias = fixture.thread; alias.id = UUID(); alias.messages = []; alias.runHistory = nil
    alias.claudeRuntimeConfiguration = .init(executable: "/fixture/other-claude-alias", configurationDirectory: "/fixture/private-claude", workspacePath: alias.workspacePath)
    #expect(fixture.base.snapshot.isClaudeHistoryScopeLocked(configuration: .init(thread: alias), nativeThreadID: fixture.sessionID))
    #expect(throws: WorkspaceCommandError.self) { try fixture.base.command(.client(.createThread(alias))) }
    guard case .freshClaudeSession(let reserved) = review.boundary else { Issue.record("Expected a reserved fresh context."); return }
    alias.providerThreadID = reserved
    #expect(fixture.base.snapshot.isClaudeHistoryScopeLocked(configuration: .init(thread: alias), nativeThreadID: reserved))
    #expect(throws: WorkspaceCommandError.self) { try fixture.base.command(.client(.createThread(alias))) }
    try fixture.base.command(.client(.editThread(fixture.thread.id, .draft("Local typing remains available"))))
    #expect(fixture.thread.draft == "Local typing remains available")
}

@Test func claudeHistoryReducerRestartInspectsDeferredRewindWithoutPublicationOrReplayingNativeWork() throws {
    var fixture = try ClaudeHistoryReducerFixture()
    let review = try fixture.review(index: 1), exact = try fixture.rewindResult(review)
    try fixture.base.accept(review); try fixture.base.dispatchProvider(review)
    try fixture.base.finishProvider(review, result: .conversationHistoryUnconfirmed)
    #expect(fixture.base.snapshot.canInspectConversationHistory(operationID: review.id))
    #expect(try fixture.base.operation(review).claudeForkPublication == nil)
    let persisted = try JSONEncoder().encode(fixture.base.snapshot)
    fixture.base.snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: persisted)
    let before = fixture.thread, decision = try fixture.base.command(.conversationHistoryReconciled(operationID: review.id, incarnation: UUID(), result: .applied(exact)))
    #expect(decision.effects.isEmpty && fixture.thread.providerThreadID == before.providerThreadID)
    #expect(fixture.thread.claudeResumeSelection == exact.claude?.selection && fixture.thread.activeRun == nil)
    #expect(fixture.thread.draft == before.draft && fixture.thread.runHistory?.map(\.providerThreadID) == before.runHistory?.map(\.providerThreadID))
    #expect(try fixture.base.operation(review).phase == .applied)
    try WorkspaceJournal.validate(fixture.base.snapshot)
}
