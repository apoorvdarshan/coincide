import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct ClaudeResumeConsumerFixture {
    let root: URL
    let threadID: UUID
    let selection: ClaudeResumeSelection
    var snapshot: WorkspaceSnapshot
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-consumer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let pointer = requested.path.withCString({ realpath($0, nil) }) else { throw CoincideError("The private Claude consumer fixture is unavailable.") }
        root = URL(fileURLWithPath: String(cString: pointer)); free(pointer)
        let runtime = ClaudeRuntimeConfiguration(executable: root.appendingPathComponent("never-executed").path,
            configurationDirectory: root.appendingPathComponent("Native").path, workspacePath: root.path)
        let project = WorkspaceProject(path: root.path), native = UUID().uuidString.lowercased()
        var thread = CodingThread(project: project, model: "captured-model")
        thread.workspacePath = root.path
        thread.provider = .claude; thread.providerThreadID = native; thread.claudeRuntimeConfiguration = runtime; thread.checkpointPolicy = .disabled
        thread.draft = "Latest draft 工作 😀"
        let fixtureRoot = root
        var rows: [JSONValue] = [], parent: String?, runIDs: [UUID] = []
        for number in 0..<2 {
            let runID = UUID(), opening = ClaudeInputIdentity.opening(runID: runID), assistant = UUID().uuidString.lowercased()
            runIDs.append(runID)
            func row(_ id: String, role: String, parent: String?) -> JSONValue {
                .object(["type": .string(role), "uuid": .string(id), "sessionId": .string(native), "parentUuid": parent.map(JSONValue.string) ?? .null,
                    "cwd": .string(fixtureRoot.path), "isSidechain": .bool(false), "timestamp": .string("2026-10-23T00:00:00.000Z"),
                    "message": .object(["role": .string(role), "content": .string("Synthetic \(role) \(number)")])])
            }
            rows += [row(opening, role: "user", parent: parent), row(assistant, role: "assistant", parent: opening)]; parent = assistant
            let active = ActiveRun(id: runID, configuration: .init(thread: thread), startedAt: now, nativeTurnID: opening)
            var record = ThreadRunRecord(run: active, origin: .user, userMessageID: "user-" + runID.uuidString)
            record.status = .completed; record.endedAt = now; record.endReason = .providerCompleted; record.messageAttributionVersion = 1
            guard var observed = record.claude else { throw ClaudeRuntimeConfiguration.invalid() }
            try observed.observe(nativeSessionID: native, inputIDs: [opening], rootAssistantMessageID: assistant); try observed.finish(.completed)
            record.claude = observed
            if thread.runHistory == nil { thread.runHistory = [] }; thread.runHistory?.append(record)
            var user = ChatMessage(id: "user-" + runID.uuidString, role: .user, text: "Original \(number)")
            var reply = ChatMessage(id: "reply-" + runID.uuidString, role: .assistant, text: "Reply \(number)")
            user.runReference = .init(threadID: thread.id, runID: runID); reply.runReference = user.runReference
            thread.messages += [user, reply]
        }
        let nativeProject = URL(fileURLWithPath: runtime.configurationDirectory).appendingPathComponent("projects").appendingPathComponent(runtime.projectKey)
        try FileManager.default.createDirectory(at: nativeProject, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var data = Data()
        for row in rows { data.append(try JSONEncoder().encode(row)); data.append(10) }
        let file = nativeProject.appendingPathComponent(native + ".jsonl")
        try data.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var source = WorkspaceSnapshot(); source.projects = [project]; source.threads = [thread]
        let service = try ClaudeHistoryService(configuration: runtime), nativeSource = try service.snapshot(sessionID: native)
        let selectedRun = runIDs[1]
        let evidence = try ClaudeHistoryReviewEvidence.make(source: nativeSource, snapshot: source, thread: thread, runID: selectedRun, kind: .rewindBeforeRun)
        let prefix = try thread.transcriptPrefix(runID: selectedRun, boundary: .beforeRun), prefixIDs = Set(prefix.map(\.id))
        let review = try ConversationHistoryReview(kind: .rewindBeforeRun, sourceThreadID: thread.id, projectID: project.id,
            runID: selectedRun, sourceIncarnation: UUID(), sourceConfiguration: .init(thread: thread), targetConfiguration: .init(thread: thread),
            sourceReference: nativeSource.reference, reviewedHeadTurnID: nil, boundary: evidence.boundary.providerBoundary, expectedResultHeadTurnID: nil,
            prefix: prefix, removedRunIDs: [selectedRun], removedMessageIDs: thread.messages.filter { !prefixIDs.contains($0.id) }.map(\.id),
            sourceFingerprint: try source.historySourceFingerprint(threadID: thread.id), targetThreadID: nil, suggestedTitle: "Saved Claude context", claude: evidence)
        let result = try service.prepareRewind(review: evidence, selectionID: review.id)
        guard let selected = result.selection else { throw ClaudeRuntimeConfiguration.invalid() }; selection = selected
        let providerResult = try ProviderConversationSnapshot(reference: result.reference, workspacePath: result.workspacePath, historyMode: .nativeTranscript, claude: result)
        let accepted = try WorkspaceDecision.make(.conversationHistoryAccepted(review: review, title: nil), id: review.id, snapshot: source, now: now)
        let dispatch = try WorkspaceDecision.make(.conversationHistoryDispatching(threadID: thread.id, operationID: review.id, incarnation: review.sourceIncarnation), id: UUID(), snapshot: accepted.snapshot, now: now)
        let applied = try WorkspaceDecision.make(.conversationHistoryEffectResult(.conversationHistory(threadID: thread.id, operationID: review.id), .conversationHistoryConfirmed(providerResult), incarnation: review.sourceIncarnation), id: UUID(), snapshot: dispatch.snapshot, now: now)
        snapshot = applied.snapshot; threadID = thread.id
        guard snapshot.threads[0].claudeResumeSelection == selection else { throw CoincideError("The offline rewind fixture was not applied.") }
    }
    var thread: CodingThread { snapshot.threads[0] }
    mutating func apply(_ command: EngineCommand, id: UUID = UUID()) throws -> WorkspaceDecision {
        let decision = try WorkspaceDecision.make(command, id: id, snapshot: snapshot, now: now)
        snapshot = decision.snapshot; return decision
    }
    mutating func begin() throws -> (UUID, UUID, WorkspaceDecision) {
        let runID = UUID(), runtimeID = UUID()
        let start = try apply(.client(.submit(threadID: threadID, text: "First explicit input")), id: runID)
        _ = try apply(.runtimeOpened(threadID: threadID, runID: runID, runtimeID: runtimeID))
        return (runID, runtimeID, start)
    }
    mutating func emit(_ event: ProviderEvent, runID: UUID, runtimeID: UUID) throws -> WorkspaceDecision {
        try apply(.provider(threadID: threadID, runtimeID: runtimeID, event: .context(runID: runID, event: event)))
    }
    mutating func complete(runID: UUID, runtimeID: UUID, observedOpening: Bool, state: ThreadState = .idle) throws -> WorkspaceDecision {
        guard var proof = thread.runHistory?.first(where: { $0.id == runID })?.claude else { throw ClaudeRuntimeConfiguration.invalid() }
        try proof.observe(nativeSessionID: selection.nativeSessionID, inputIDs: observedOpening ? [proof.openingInputID] : [])
        try proof.finish(state == .interrupted ? .interrupted : .completed)
        _ = try emit(.claudeHistoryEvidence(proof), runID: runID, runtimeID: runtimeID)
        return try emit(.completed(state), runID: runID, runtimeID: runtimeID)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func claudeResumeConsumerAssignsSelectionOnlyToFirstRunAndNeverQueuedCapture() throws {
    var fixture = try ClaudeResumeConsumerFixture(); defer { fixture.cleanup() }
    let (first, _, start) = try fixture.begin()
    #expect(fixture.thread.claudeResumeConsumerRunID == first && fixture.thread.activeRun?.configuration.claudeLaunchSelection == fixture.selection)
    let startConfiguration = start.effects.compactMap { effect -> ProviderConfiguration? in
        if case .providerStart(_, let id, let value, _, _) = effect.request, id == first { value } else { nil }
    }
    #expect(startConfiguration.count == 1 && startConfiguration.first?.claudeLaunchSelection == fixture.selection)
    let queuedID = UUID()
    _ = try fixture.apply(.client(.editThread(fixture.threadID, .model("future-queued-model"))))
    _ = try fixture.apply(.client(.submit(threadID: fixture.threadID, text: "FIFO successor")), id: queuedID)
    #expect(fixture.thread.activeRun?.id == first && fixture.thread.claudeResumeConsumerRunID == first)
    #expect(fixture.thread.queuedTurns.map(\.id) == [queuedID])
    #expect(fixture.thread.queuedTurns.first?.configuration.claudeLaunchSelection == nil)
    #expect(fixture.thread.queuedTurns.first?.configuration.model == "future-queued-model")
}

@Test(arguments: [false, true])
func claudeResumeConsumerClearsOnlyObservedOpeningBeforeSuccessorAdmission(observedOpening: Bool) throws {
    var fixture = try ClaudeResumeConsumerFixture(); defer { fixture.cleanup() }
    let (runID, runtimeID, _) = try fixture.begin(), successor = UUID()
    _ = try fixture.apply(.client(.submit(threadID: fixture.threadID, text: "Held FIFO successor")), id: successor)
    let terminal = try fixture.complete(runID: runID, runtimeID: runtimeID, observedOpening: observedOpening)
    if observedOpening {
        #expect(fixture.thread.claudeResumeSelection == nil && fixture.thread.claudeResumeConsumerRunID == nil)
        #expect(fixture.thread.activeRun?.id == successor && fixture.thread.queuedTurns.isEmpty)
        #expect(fixture.thread.activeRun?.configuration.claudeLaunchSelection == nil && !fixture.thread.queuePaused)
        let effects = terminal.effects.compactMap { effect -> UUID? in if case .providerStart(_, let id, let value, _, _) = effect.request, value.claudeLaunchSelection == nil { id } else { nil } }
        #expect(effects == [successor])
    } else {
        #expect(fixture.thread.claudeResumeSelection == fixture.selection && fixture.thread.claudeResumeConsumerRunID == runID)
        #expect(fixture.thread.activeRun == nil && fixture.thread.queuePaused && fixture.thread.queuedTurns.map(\.id) == [successor])
        #expect(terminal.effects.isEmpty)
        #expect(fixture.snapshot.claudeResumeSelectionNeedsInspection(threadID: fixture.threadID))
    }
}

@Test(arguments: [false, true])
func claudeResumeConsumerRetainsPendingSelectionAfterFailureOrInterruption(interrupted: Bool) throws {
    var fixture = try ClaudeResumeConsumerFixture(); defer { fixture.cleanup() }
    let (runID, runtimeID, _) = try fixture.begin()
    if interrupted { _ = try fixture.complete(runID: runID, runtimeID: runtimeID, observedOpening: true, state: .interrupted) }
    else { _ = try fixture.emit(.failure("Fixed offline failure"), runID: runID, runtimeID: runtimeID) }
    #expect(fixture.thread.activeRun == nil && fixture.thread.queuePaused)
    #expect(fixture.thread.claudeResumeSelection == fixture.selection && fixture.thread.claudeResumeConsumerRunID == runID)
    #expect(fixture.snapshot.claudeResumeSelectionNeedsInspection(threadID: fixture.threadID))
}

@Test(arguments: [ClaudeResumeInspection.notConsumed, .consumed])
func claudeResumeConsumerInspectionUsesExactAttemptAndKeepsQueuePaused(result: ClaudeResumeInspection) throws {
    var fixture = try ClaudeResumeConsumerFixture(); defer { fixture.cleanup() }
    let (runID, runtimeID, _) = try fixture.begin(), successor = UUID()
    _ = try fixture.apply(.client(.submit(threadID: fixture.threadID, text: "Never automatically replay or release")), id: successor)
    _ = try fixture.complete(runID: runID, runtimeID: runtimeID, observedOpening: false)
    let run = try #require(fixture.thread.runHistory?.first(where: { $0.id == runID }))
    var stale = run; stale.providerStopReason = "Different exact journal snapshot"
    #expect(throws: WorkspaceCommandError.self) {
        _ = try WorkspaceDecision.make(.claudeResumeInspected(threadID: fixture.threadID, incarnation: UUID(), selection: fixture.selection, run: stale, result: result), id: UUID(), snapshot: fixture.snapshot, now: fixture.now)
    }
    _ = try fixture.apply(.claudeResumeInspected(threadID: fixture.threadID, incarnation: UUID(), selection: fixture.selection, run: run, result: result))
    #expect(fixture.thread.claudeResumeConsumerRunID == nil && fixture.thread.queuePaused && fixture.thread.activeRun == nil)
    #expect(fixture.thread.claudeResumeSelection == (result == .consumed ? nil : fixture.selection))
    #expect(fixture.thread.queuedTurns.map(\.id) == [successor])
}
