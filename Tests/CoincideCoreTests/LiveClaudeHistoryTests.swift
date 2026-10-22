import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Opt-in only: four serialized model turns in a newly generated private cwd,
/// using the installed CLI's existing authentication and the production factory.
/// No login, tool approval, native session enumeration or transcript deletion.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_CLAUDE_HISTORY"] == "1"),
      .timeLimit(.minutes(6)))
func installedClaudeNativeHistoryForkAndDeferredRewindThroughEngine() async throws {
    let manager = FileManager.default, testID = UUID()
    let requested = manager.temporaryDirectory.appendingPathComponent("coincide-live-claude-history-" + testID.uuidString)
    try manager.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    guard let pointer = requested.path.withCString({ realpath($0, nil) }) else {
        throw LiveClaudeHistoryFailure("private-root-unavailable")
    }
    let root = URL(fileURLWithPath: String(cString: pointer)); free(pointer)
    let evidenceURL = root.appendingPathComponent("evidence.json")
    var evidence = LiveClaudeHistoryEvidence(testID: testID)
    var engine: WorkspaceEngine?, restarted: WorkspaceEngine?
    let deadline = ContinuousClock.now + .seconds(330)
    do {
        try evidence.save(stage: "private-workspace", to: evidenceURL)
        let workspace = root.appendingPathComponent("generated-workspace")
        try manager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sentinel = workspace.appendingPathComponent("untouched.txt")
        let sentinelBytes = Data("Coincide generated history acceptance sentinel.\n".utf8)
        try sentinelBytes.write(to: sentinel, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel.path)
        // Resolve the installed executable, native configuration and physical
        // namespace once. No other project or native history is enumerated.
        let project = WorkspaceProject(path: workspace.path)
        let runtime = try ClaudeRuntimeConfiguration.capture(workspacePath: project.path)
        let native = try ClaudeTranscriptStore(configurationDirectory: URL(fileURLWithPath: runtime.configurationDirectory),
            workspace: workspace, projectDirectoryName: runtime.projectDirectoryName)
        let service = try ClaudeHistoryService(configuration: runtime)
        let databaseURL = root.appendingPathComponent("workspace.sqlite")
        var source = CodingThread(project: project)
        source.workspacePath = runtime.registeredWorkspacePath
        source.provider = .claude; source.claudeRuntimeConfiguration = runtime
        source.permission = .supervised; source.checkpointPolicy = .disabled
        source.title = "Coincide generated Claude history acceptance"
        // Deliberately leave providerFactory at its production default.
        let current = try WorkspaceEngine(url: databaseURL, identityResolver: { _ in nil })
        engine = current
        _ = try await current.dispatch(.addProjectWithThread(project: project, thread: source))
        let first = "ALPHA_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let second = "BETA_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let noTools = "Do not use tools, delegate, run commands, inspect files, browse, or change files. Reply with only the requested literal answer."
        let firstRunID = UUID(), secondRunID = UUID()
        for (number, runID, label, marker) in [(1, firstRunID, "ALPHA", first), (2, secondRunID, "BETA", second)] {
            try evidence.save(stage: "source-turn-\(number)", to: evidenceURL)
            let prompt = "Remember that the \(label) marker is \(marker). Reply with exactly \(marker). \(noTools)"
            try await liveClaudeHistorySubmit(current, threadID: source.id, runID: runID, prompt: prompt,
                expectedAnswer: marker, deadline: deadline)
            let thread = try liveClaudeHistoryThread(await current.current(), source.id)
            let run = try liveClaudeHistoryValue(thread.runHistory?.first { $0.id == runID }, "source-run-missing")
            try liveClaudeHistoryProof(run, runtime: runtime)
            evidence.runIDs.append(runID); evidence.checks["source-marker-\(number)"] = true
        }
        var before = try liveClaudeHistoryThread(await current.current(), source.id)
        let sourceID = try liveClaudeHistoryValue(before.providerThreadID, "source-native-id-missing")
        evidence.sessionIDs.append(sourceID)
        let firstRun = try liveClaudeHistoryValue(before.runHistory?.first { $0.id == firstRunID }, "first-run-missing")
        let firstRoot = try liveClaudeHistoryValue(firstRun.claude?.finalRootAssistantMessageID, "first-native-root-missing")
        let sourceSnapshot = try native.read(sessionID: sourceID)
        try liveClaudeHistoryNativeHasNoTools(sourceSnapshot)
        let openingIDs = [ClaudeInputIdentity.opening(runID: firstRunID), ClaudeInputIdentity.opening(runID: secondRunID)]
        try liveClaudeHistoryRequire(openingIDs.allSatisfy { id in
            sourceSnapshot.transcript.selectedMessages.contains { $0["uuid"].string == id && $0["type"].string == "user" }
        }, "prospective-inputs-not-native-root-messages")

        try evidence.save(stage: "review-fork", to: evidenceURL)
        let fork = try await current.reviewConversationHistory(threadID: source.id, runID: firstRunID, kind: .forkAfterRun)
        try liveClaudeHistoryRequire(fork.boundary == .throughClaudeMessage(firstRoot) && fork.claude != nil,
            "fork-boundary-not-native-root")
        // The idle CLI flushes metadata during review's owned drain. Capture
        // the fork's exact baseline after that drain, and independently prove
        // the earlier conversation records were retained without modification.
        let reviewedSource = try native.read(sessionID: sourceID)
        try liveClaudeHistoryRequire(reviewedSource.location == fork.claude?.source.sourceLocation &&
            reviewedSource.revision == fork.claude?.source.sourceRevision &&
            reviewedSource.transcript.records.starts(with: sourceSnapshot.transcript.records) &&
            reviewedSource.transcript.selectedMessages == sourceSnapshot.transcript.selectedMessages,
            "owned-drain-changed-conversation-context")
        _ = try await current.beginConversationHistory(fork, title: "Coincide generated Claude fork")
        try await liveClaudeHistoryWait(current, deadline: deadline, seconds: 30) { update in
            try liveClaudeHistoryApplied(update, fork.id)
        }
        let forkUpdate = await current.current()
        let forkOperation = try liveClaudeHistoryValue(forkUpdate.snapshot.conversationHistoryOperation(fork.id), "fork-operation-missing")
        let publication = try liveClaudeHistoryValue(forkOperation.claudeForkPublication, "fork-reservation-missing")
        let targetID = try liveClaudeHistoryValue(fork.targetThreadID, "fork-header-missing")
        let target = try liveClaudeHistoryThread(forkUpdate, targetID)
        try liveClaudeHistoryRequire(target.providerThreadID == publication.target.sessionID && target.providerThreadID != sourceID &&
            target.claudeInheritedHead?.cursor == publication.headMessageID && target.claudeResumeSelection == nil,
            "fork-native-lineage-mismatch")
        try liveClaudeHistoryRequire(publication.sourceToForkMessageIDs[firstRoot] == target.claudeInheritedHead?.cursor &&
            publication.headMessageID != firstRoot && target.messages == fork.prefix, "fork-copy-map-mismatch")
        try liveClaudeHistoryRequire(try native.read(sessionID: sourceID).revision == reviewedSource.revision,
            "fork-changed-native-source")
        try liveClaudeHistoryRequire(try liveClaudeHistoryThread(forkUpdate, source.id) == before, "fork-changed-source-header")
        let copy = try service.snapshot(sessionID: publication.target.sessionID)
        let typedFork = try liveClaudeHistoryValue(fork.claude, "fork-proof-missing")
        let forkResult = try liveClaudeHistoryValue(forkOperation.result?.claude, "fork-result-missing")
        try typedFork.validateResult(forkResult)
        guard case .fork(let resultSnapshot, _, _) = forkResult else { throw LiveClaudeHistoryFailure("fork-result-kind-mismatch") }
        try liveClaudeHistoryRequire(copy == resultSnapshot, "fork-native-copy-readback-mismatch")
        evidence.operationIDs.append(fork.id); evidence.sessionIDs.append(publication.target.sessionID)
        evidence.checks["fork-reserved-remapped-inherited"] = true; evidence.checks["fork-source-unchanged"] = true

        // Neither recall prompt contains either generated value. A copied
        // first prefix must recall ALPHA and cannot recover discarded BETA.
        let recall = "What are the stored ALPHA and BETA marker values in this conversation? Reply exactly ALPHA_VALUE|BETA_VALUE, replacing an absent value with MISSING. Do not infer values from another conversation. \(noTools)"
        let expectedRecall = first + "|MISSING"
        try evidence.save(stage: "explicit-fork-recall", to: evidenceURL)
        let forkRunID = UUID()
        try await liveClaudeHistorySubmit(current, threadID: targetID, runID: forkRunID,
            prompt: recall, expectedAnswer: expectedRecall, deadline: deadline)
        let continuedFork = try liveClaudeHistoryThread(await current.current(), targetID)
        let continuedForkRun = try liveClaudeHistoryValue(continuedFork.runHistory?.first { $0.id == forkRunID }, "fork-run-missing")
        try liveClaudeHistoryProof(continuedForkRun, runtime: runtime)
        try liveClaudeHistoryNativeHasNoTools(native.read(sessionID: publication.target.sessionID))
        evidence.runIDs.append(forkRunID); evidence.checks["explicit-fork-recalled-first-only"] = true

        try evidence.save(stage: "review-deferred-rewind", to: evidenceURL)
        _ = try await current.dispatch(.editThread(source.id, .draft("Unsent generated acceptance draft")))
        before = try liveClaudeHistoryThread(await current.current(), source.id)
        let beforeRewind = try native.read(sessionID: sourceID)
        let rewind = try await current.reviewConversationHistory(threadID: source.id, runID: secondRunID, kind: .rewindBeforeRun)
        try liveClaudeHistoryRequire(rewind.boundary == .throughClaudeMessage(firstRoot), "rewind-boundary-mismatch")
        _ = try await current.beginConversationHistory(rewind)
        try await liveClaudeHistoryWait(current, deadline: deadline, seconds: 30) { update in
            try liveClaudeHistoryApplied(update, rewind.id)
        }
        let rewindUpdate = await current.current(), rewound = try liveClaudeHistoryThread(rewindUpdate, source.id)
        let selection = try liveClaudeHistoryValue(rewound.claudeResumeSelection, "deferred-selection-missing")
        try liveClaudeHistoryRequire(selection.id == rewind.id && selection.kind == .resumeAt && selection.cursor == firstRoot &&
            selection.nativeSessionID == sourceID && selection.discardedInputID == openingIDs[1] && rewound.claudeResumeConsumerRunID == nil,
            "deferred-selection-owner-mismatch")
        try liveClaudeHistoryRequire(rewound.providerThreadID == sourceID && rewound.visibleMessages == rewind.prefix &&
            rewound.draft == before.draft && rewound.model == before.model && rewound.permission == .supervised &&
            rewound.claudeRuntimeConfiguration == runtime && rewound.runHistory?.count == 2, "rewind-changed-audit-settings-or-draft")
        try liveClaudeHistoryRequire(try native.read(sessionID: sourceID).revision == beforeRewind.revision,
            "deferred-rewind-mutated-native-transcript")
        evidence.operationIDs.append(rewind.id); evidence.selectionIDs.append(selection.id)
        evidence.checks["rewind-deferred-native-source-unchanged"] = true

        try evidence.save(stage: "explicit-rewound-recall", to: evidenceURL)
        let successorID = UUID()
        try await liveClaudeHistorySubmit(current, threadID: source.id, runID: successorID,
            prompt: recall, expectedAnswer: expectedRecall, deadline: deadline)
        let consumed = try liveClaudeHistoryThread(await current.current(), source.id)
        let successor = try liveClaudeHistoryValue(consumed.runHistory?.first { $0.id == successorID }, "successor-run-missing")
        try liveClaudeHistoryProof(successor, runtime: runtime)
        try liveClaudeHistoryRequire(successor.configuration.claudeLaunchSelection == selection &&
            consumed.claudeResumeSelection == nil && consumed.claudeResumeConsumerRunID == nil && consumed.providerThreadID == sourceID,
            "explicit-successor-did-not-consume-exact-selection")
        let after = try native.read(sessionID: sourceID)
        try liveClaudeHistoryNativeHasNoTools(after)
        let selectedIDs = Set(after.transcript.selectedMessages.compactMap { $0["uuid"].string })
        try liveClaudeHistoryRequire(selectedIDs.contains(openingIDs[0]) && selectedIDs.contains(ClaudeInputIdentity.opening(runID: successorID)) &&
            !selectedIDs.contains(openingIDs[1]), "native-rewind-selected-context-mismatch")
        evidence.runIDs.append(successorID); evidence.checks["explicit-rewind-recalled-first-only"] = true
        try liveClaudeHistoryWorkspaceUnchanged(workspace, sentinel: sentinel, bytes: sentinelBytes)
        try await liveClaudeHistoryAuditJournal(databaseURL)
        evidence.checks["no-tool-activity-approval-or-workspace-writes"] = true

        try evidence.save(stage: "shutdown-and-sqlite-restart", to: evidenceURL)
        await current.shutdown()
        let saved = try await WorkspaceDatabase(url: databaseURL).load()
        let reopened = try WorkspaceEngine(url: databaseURL, identityResolver: { _ in nil }); restarted = reopened
        let restored = try await reopened.load()
        try liveClaudeHistoryRequire(restored == saved && restored.conversationHistoryOperation(fork.id)?.claudeForkPublication == publication &&
            restored.conversationHistoryOperation(rewind.id)?.result?.claude?.selection == selection,
            "restart-lost-native-history-receipts")
        try WorkspaceJournal.validate(restored)
        await reopened.shutdown(); restarted = nil
        try await liveClaudeHistoryAuditJournal(databaseURL)
        try liveClaudeHistoryWorkspaceUnchanged(workspace, sentinel: sentinel, bytes: sentinelBytes)
        evidence.checks["sqlite-restart-preserved-receipts"] = true
        // Native transcripts and this private generated workspace are retained;
        // this test has no authority to delete Claude application data.
        evidence.checks["native-transcripts-retained"] = true
        try evidence.save(stage: "passed", to: evidenceURL)
    } catch {
        await restarted?.shutdown(); await engine?.shutdown()
        evidence.checks["failed"] = true
        try? evidence.save(stage: evidence.stage, to: evidenceURL)
        let category = (error as? LiveClaudeHistoryFailure)?.description ?? "native-or-storage-boundary-failed"
        throw LiveClaudeHistoryFailure(category + "; private-evidence=" + evidenceURL.path)
    }
    await restarted?.shutdown(); await engine?.shutdown()
}

private struct LiveClaudeHistoryFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Only generated owner IDs, fixed stages and boolean observations are written.
/// Never serializes runtime paths, prompts, provider errors or native payloads.
private struct LiveClaudeHistoryEvidence: Encodable {
    let testID: UUID
    var stage = "created"
    var sessionIDs: [String] = []
    var runIDs: [UUID] = [], operationIDs: [UUID] = [], selectionIDs: [UUID] = []
    var checks: [String: Bool] = [:]
    mutating func save(stage: String, to url: URL) throws {
        self.stage = stage
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw LiveClaudeHistoryFailure("private-evidence-unavailable")
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: encoder.encode(self)); try handle.synchronize()
    }
}

private func liveClaudeHistoryRequire(_ value: Bool, _ reason: String) throws {
    guard value else { throw LiveClaudeHistoryFailure(reason) }
}
private func liveClaudeHistoryValue<T>(_ value: T?, _ reason: String) throws -> T {
    guard let value else { throw LiveClaudeHistoryFailure(reason) }; return value
}
private func liveClaudeHistoryThread(_ update: WorkspaceUpdate, _ id: UUID) throws -> CodingThread {
    try liveClaudeHistoryValue(update.snapshot.threads.first { $0.id == id }, "generated-thread-missing")
}
private func liveClaudeHistoryProof(_ run: ThreadRunRecord, runtime: ClaudeRuntimeConfiguration) throws {
    let proof = try liveClaudeHistoryValue(run.claude, "prospective-native-history-proof-missing")
    try proof.validate()
    try liveClaudeHistoryRequire(run.configuration.claudeRuntimeConfiguration == runtime && run.configuration.permission == .supervised &&
        run.checkpoints == nil && proof.runID == run.id && proof.terminalStatus == .completed &&
        proof.nativeSessionID == run.providerThreadID && proof.observedInputIDs.contains(ClaudeInputIdentity.opening(runID: run.id)) &&
        !proof.rootAssistantMessageIDs.isEmpty, "native-root-input-and-terminal-proof-mismatch")
}
private func liveClaudeHistoryApplied(_ update: WorkspaceUpdate, _ id: UUID) throws -> Bool {
    guard let operation = update.snapshot.conversationHistoryOperation(id) else { return false }
    if [.failed, .unconfirmed].contains(operation.phase) { throw LiveClaudeHistoryFailure("history-operation-not-confirmed") }
    return operation.phase == .applied
}
private func liveClaudeHistoryWait(_ engine: WorkspaceEngine, deadline: ContinuousClock.Instant, seconds: Int,
                                  condition: (WorkspaceUpdate) throws -> Bool) async throws {
    let boundary = min(deadline, ContinuousClock.now + .seconds(seconds))
    while true {
        try Task.checkCancellation()
        let update = await engine.current()
        try liveClaudeHistoryRequire(update.error == nil, "engine-failed")
        for thread in update.snapshot.threads { try liveClaudeHistoryNoActions(thread) }
        if try condition(update) { return }
        guard ContinuousClock.now < boundary else { throw LiveClaudeHistoryFailure("bounded-native-boundary-expired") }
        try await Task.sleep(for: .milliseconds(50))
    }
}
private func liveClaudeHistorySubmit(_ engine: WorkspaceEngine, threadID: UUID, runID: UUID,
                                    prompt: String, expectedAnswer: String, deadline: ContinuousClock.Instant) async throws {
    _ = try await engine.dispatch(.submit(threadID: threadID, text: prompt), id: runID)
    try await liveClaudeHistoryWait(engine, deadline: deadline, seconds: 100) { update in
        let thread = try liveClaudeHistoryThread(update, threadID)
        guard let run = thread.runHistory?.first(where: { $0.id == runID }) else { return false }
        if run.status.isTerminal && run.status != .completed { throw LiveClaudeHistoryFailure("native-turn-not-completed") }
        return run.status == .completed && thread.activeRun == nil && thread.queuedTurns.isEmpty
    }
    let completed = try liveClaudeHistoryThread(await engine.current(), threadID)
    let reply = completed.visibleMessages.filter { $0.role == .assistant && $0.runReference?.threadID == threadID && $0.runReference?.runID == runID }
        .map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    try liveClaudeHistoryRequire(reply == expectedAnswer, "generated-recall-answer-mismatch")
}
private func liveClaudeHistoryNoActions(_ thread: CodingThread) throws {
    try liveClaudeHistoryRequire(thread.runtimeRequests.isEmpty && thread.providerActivity == nil &&
        !thread.messages.contains { $0.role == .tool || $0.providerEntity?.role == .tool }, "unexpected-tool-activity-or-approval")
}
private func liveClaudeHistoryNativeHasNoTools(_ snapshot: ClaudeTranscriptSnapshot) throws {
    for record in snapshot.transcript.records {
        let blocks = record["message"]["content"].array ?? []
        try liveClaudeHistoryRequire(!blocks.contains { ["tool_use", "tool_result", "server_tool_use"].contains($0["type"].string ?? "") },
            "unexpected-native-tool-record")
    }
}
private func liveClaudeHistoryWorkspaceUnchanged(_ workspace: URL, sentinel: URL, bytes: Data) throws {
    try liveClaudeHistoryRequire(try FileManager.default.contentsOfDirectory(atPath: workspace.path) == [sentinel.lastPathComponent] &&
        Data(contentsOf: sentinel) == bytes, "generated-workspace-changed")
}
private func liveClaudeHistoryAuditJournal(_ url: URL) async throws {
    let database = try WorkspaceDatabase(url: url)
    var cursor: Int64 = 0, count = 0
    while true {
        let rows = try await database.journal(after: cursor, limit: 1_000)
        if rows.isEmpty { return }
        count += rows.count
        try liveClaudeHistoryRequire(count <= 20_000, "generated-journal-bound-exceeded")
        for row in rows {
            switch row.event {
            case .imported(let snapshot): for thread in snapshot.threads { try liveClaudeHistoryNoActions(thread) }
            case .threadMetadataUpserted(let thread): try liveClaudeHistoryNoActions(thread)
            case .messageUpserted(_, _, let message):
                try liveClaudeHistoryRequire(message.role != .tool && message.providerEntity?.role != .tool, "unexpected-durable-tool-write")
            default: break
            }
        }
        cursor = rows.last!.sequence
    }
}
