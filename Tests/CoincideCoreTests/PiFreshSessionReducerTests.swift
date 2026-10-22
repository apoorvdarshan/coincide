import Foundation
import Testing
@testable import CoincideCore

private struct PiFreshReducerFixture {
    let intent: PiFreshSessionIntent
    let thread: CodingThread
    let consumerID: UUID
    let revision: PiHistoryFileRevision
    let now: Date

    init(proven: Bool = false, status: ThreadRunStatus = .unknown) throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000); self.now = now
        let project = WorkspaceProject(path: "/fixture/pi-fresh-workspace"), instanceID = UUID()
        let runtime = try PiRuntimeConfiguration(instanceID: instanceID, executable: "/usr/bin/true", requestedExecutable: "pi",
            workspacePath: project.path, homeDirectory: "/fixture/pi-home", agentDirectory: "/fixture/pi-home/.pi/agent",
            agentDirectorySelection: .defaultHome(homeDirectory: "/fixture/pi-home"))
        let configuration = PiConfiguration(instanceID: instanceID, executable: "pi", runtime: runtime)
        let file = "/fixture/pi-sessions/exact-empty-target.jsonl"
        let intent = try PiFreshSessionIntent(id: UUID(), operationID: UUID(), runtimeIdentity: configuration.runtimeIdentity,
            nativeSessionFile: file, sourceNativeSessionFile: "/fixture/pi-sessions/original-source.jsonl",
            originalNativeSessionID: "before-missing-file-reopen", sourceInventoryDigest: String(repeating: "a", count: 64),
            semanticDigest: String(repeating: "b", count: 64))
        self.intent = intent
        var source = CodingThread(project: project); source.provider = .pi; source.piConfiguration = configuration
        source.providerThreadID = file; source.piFreshSessionIntent = intent
        source.draft = "Latest unsent draft 工作 مرحباً 😀"; source.checkpointPolicy = .disabled
        source.queuedTurns = [.init(id: UUID(), text: "Paused immutable FIFO input", configuration: .init(thread: source), createdAt: now)]
        source.queuePaused = true
        let consumerID = UUID(); self.consumerID = consumerID; source.piFreshConsumerRunID = consumerID
        var captured = ProviderConfiguration(thread: source); captured.piFreshSessionIntent = intent
        let run = ActiveRun(id: consumerID, configuration: captured, startedAt: now)
        var record = ThreadRunRecord(run: run, origin: .user, userMessageID: "explicit-consumer-input")
        record.status = status; record.endedAt = now; record.endReason = .providerFailure; record.messageAttributionVersion = 1
        let baseline = try PiRuntimeEntryObservation(nativeSessionFile: file, nativeSessionID: "actual-reopened-native-id", leafID: nil, entries: [])
        let opening = try PiHistoryInputEvidence(clientMessageID: "explicit-consumer-input",
            inputDigest: PiHistoryInputEvidence.digest(.init(text: "Only this explicit input")), kind: .opening)
        let preparation = try PiRunHistoryPreparation(runID: consumerID, runtimeIdentity: configuration.runtimeIdentity,
            observedVersion: "0.80.5", openingInput: opening, baseline: baseline, freshIntentID: intent.id, freshEmptyObservation: baseline)
        let revision = try Self.fileRevision(file: file, workspace: project.path, sessionID: baseline.nativeSessionID); self.revision = revision
        if proven {
            let graph = try Self.graph(workspace: project.path, sessionID: baseline.nativeSessionID)
            let final = try PiRuntimeEntryObservation(nativeSessionFile: file, nativeSessionID: baseline.nativeSessionID,
                leafID: graph.leafID, entries: graph.entries.map(PiHistoryEntryDescriptor.init))
            var input = opening; input.nativeUserEntryID = "owned-native-user"
            record.pi = try .init(preparation: preparation, inputs: [input], finalObservation: final,
                openingUserEntryID: "owned-native-user", nativeUserEntryIDs: ["owned-native-user"], captureStatus: .proven,
                terminalStatus: status == .completed ? .completed : .failed, persistedFileRevision: revision)
        } else { record.pi = try .init(preparation: preparation) }
        var message = ChatMessage(id: "explicit-consumer-input", role: .user, text: "Only this explicit input")
        message.runReference = .init(threadID: source.id, runID: consumerID)
        source.messages = [message]; source.runHistory = [record]; source.state = .failed
        thread = source
    }
    static func graph(workspace: String, sessionID: String) throws -> PiHistoryGraph {
        let stamp = "2026-10-23T00:00:00.000Z"
        let header: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(sessionID),
            "cwd": .string(workspace), "timestamp": .string(stamp)])
        let user: JSONValue = .object(["type": .string("message"), "id": .string("owned-native-user"), "parentId": .null,
            "timestamp": .string(stamp), "message": .object(["role": .string("user"), "content": .string("Only this explicit input")])])
        let answer: JSONValue = .object(["type": .string("message"), "id": .string("owned-native-answer"), "parentId": .string("owned-native-user"),
            "timestamp": .string(stamp), "message": .object(["role": .string("assistant"), "content": .string("Native answer")])])
        return try .init(header: header, entries: [user, answer], leafID: "owned-native-answer")
    }
    static func fileRevision(file: String, workspace: String, sessionID: String) throws -> PiHistoryFileRevision {
        let graph = try graph(workspace: workspace, sessionID: sessionID)
        return try .init(.init(filePath: file, graph: graph, byteDigest: String(repeating: "c", count: 64), byteCount: 800, device: 1, inode: 2))
    }
    func replacingPreparation(_ source: PiRunHistoryEvidence, freshID: UUID?, runtime: PiRuntimeIdentity? = nil) throws -> PiRunHistoryEvidence {
        let prior = source.preparation
        let preparation = try PiRunHistoryPreparation(id: prior.id, runID: prior.runID, runtimeIdentity: runtime ?? prior.runtimeIdentity,
            observedVersion: prior.observedVersion, openingInput: prior.openingInput, baseline: prior.baseline, freshIntentID: freshID,
            freshEmptyObservation: freshID == nil ? nil : prior.freshEmptyObservation)
        return try .init(preparation: preparation, inputs: source.inputs, finalObservation: source.finalObservation,
            openingUserEntryID: source.openingUserEntryID, nativeUserEntryIDs: source.nativeUserEntryIDs,
            captureStatus: source.captureStatus, terminalStatus: source.terminalStatus, persistedFileRevision: source.persistedFileRevision)
    }
}

@Test func piFreshExplicitUnwrittenAcknowledgementKeepsUnknownAuditAndQueuePausedWithoutReplayingInput() throws {
    let fixture = try PiFreshReducerFixture(), original = fixture.thread
    var thread = original
    try thread.resolvePiFreshSession(intent: fixture.intent, consumerRunID: fixture.consumerID, inspection: .unwritten, now: fixture.now)
    #expect(thread.piFreshSessionIntent == fixture.intent && thread.piFreshConsumerRunID == nil)
    #expect(thread.queuePaused && thread.queuedTurns == original.queuedTurns)
    #expect(thread.draft == original.draft && thread.messages == original.messages && thread.runHistory == original.runHistory)
    #expect(thread.runHistory?.first?.status == .unknown && thread.runHistory?.first?.turnIDs.isEmpty == true)
    #expect(thread.piFreshContextResolutions == [.init(intentID: fixture.intent.id, consumerRunID: fixture.consumerID,
        resolvedAt: fixture.now, outcome: .unwritten)])
    let once = thread
    #expect(throws: WorkspaceCommandError.self) {
        try thread.resolvePiFreshSession(intent: fixture.intent, consumerRunID: fixture.consumerID, inspection: .unwritten, now: fixture.now)
    }
    #expect(thread == once)
}

@Test func piFreshPersistedResolutionUsesActualReopenedIdentityAndRetainsFailedRunRatherThanClaimingSuccess() throws {
    let fixture = try PiFreshReducerFixture(proven: true, status: .failed), original = fixture.thread
    #expect(fixture.revision.sessionID != fixture.intent.originalNativeSessionID)
    var thread = original
    try thread.resolvePiFreshSession(intent: fixture.intent, consumerRunID: fixture.consumerID,
        inspection: .persisted(fixture.revision), now: fixture.now)
    #expect(thread.piFreshSessionIntent == nil && thread.piFreshConsumerRunID == nil && thread.queuePaused)
    #expect(thread.piFreshContextResolutions?.last?.outcome == .persisted(fixture.revision))
    #expect(thread.runHistory == original.runHistory && thread.runHistory?.first?.status == .failed)
    #expect(thread.messages == original.messages && thread.queuedTurns == original.queuedTurns && thread.draft == original.draft)
    #expect(thread.activeRun == nil && thread.runtimeRequests.isEmpty)
}

@Test(arguments: ["running", "wrongIntent", "wrongConsumer", "unavailable", "wrongPath", "foreignSession", "foreignFreshID", "foreignRuntime", "foreignInput", "alreadyResolved"])
func piFreshResolutionRejectsStaleOrForeignEvidenceBeforeMutatingAnyConversation(kind: String) throws {
    let fixture = try PiFreshReducerFixture(proven: true, status: .failed)
    var thread = fixture.thread, expectedIntent = fixture.intent, consumer = fixture.consumerID
    var inspection: PiFreshSessionInspection = .persisted(fixture.revision)
    switch kind {
    case "running":
        thread.activeRun = .init(id: consumer, configuration: thread.runHistory![0].configuration, startedAt: fixture.now)
        thread.state = .running
    case "wrongIntent":
        expectedIntent = try .init(id: UUID(), operationID: fixture.intent.operationID, runtimeIdentity: fixture.intent.runtimeIdentity,
            nativeSessionFile: fixture.intent.nativeSessionFile, sourceNativeSessionFile: fixture.intent.sourceNativeSessionFile,
            originalNativeSessionID: fixture.intent.originalNativeSessionID, sourceInventoryDigest: fixture.intent.sourceInventoryDigest,
            semanticDigest: fixture.intent.semanticDigest)
    case "wrongConsumer": consumer = UUID()
    case "unavailable": inspection = .unavailable
    case "wrongPath": inspection = .persisted(try PiFreshReducerFixture.fileRevision(file: "/fixture/foreign.jsonl", workspace: thread.workspacePath, sessionID: fixture.revision.sessionID))
    case "foreignSession": inspection = .persisted(try PiFreshReducerFixture.fileRevision(file: fixture.revision.filePath, workspace: thread.workspacePath, sessionID: "foreign-native-id"))
    case "foreignFreshID":
        let captured = thread.runHistory![0].pi!
        thread.runHistory?[0].pi = try fixture.replacingPreparation(captured, freshID: UUID())
    case "foreignRuntime":
        let prior = try #require(thread.piConfiguration), runtime = try #require(prior.runtime)
        let changed = try PiRuntimeConfiguration(instanceID: UUID(), executable: runtime.executable, requestedExecutable: runtime.requestedExecutable,
            workspacePath: runtime.workspacePath, registeredWorkspacePath: runtime.registeredWorkspacePath, homeDirectory: runtime.homeDirectory,
            agentDirectory: runtime.agentDirectory, agentDirectorySelection: runtime.agentDirectorySelection)
        let identity = PiRuntimeIdentity(instanceID: changed.instanceID, executable: changed.requestedExecutable, runtime: changed)
        let captured = thread.runHistory![0].pi!
        thread.runHistory?[0].pi = try fixture.replacingPreparation(captured, freshID: fixture.intent.id, runtime: identity)
    case "foreignInput": thread.runHistory?[0].userMessageID = "a-different-local-input"
    default:
        thread.piFreshContextResolutions = [.init(intentID: fixture.intent.id, consumerRunID: consumer, resolvedAt: fixture.now, outcome: .unwritten)]
    }
    let unchanged = thread
    #expect(throws: (any Error).self) {
        try thread.resolvePiFreshSession(intent: expectedIntent, consumerRunID: consumer, inspection: inspection, now: fixture.now)
    }
    #expect(thread == unchanged)
}

@Test(arguments: ["matching", "missing", "foreign", "unexpected"])
func piFreshPreparationBindsOnlyItsDurablySelectedIntentAndActualConsumerBeforeAnyNativeInput(kind: String) throws {
    let fixture = try PiFreshReducerFixture(), original = fixture.thread
    var thread = original, captured = thread.runHistory![0].configuration
    let prior = try #require(thread.runHistory?[0].pi?.preparation)
    if kind == "unexpected" {
        thread.piFreshSessionIntent = nil; thread.piFreshConsumerRunID = nil; captured.piFreshSessionIntent = nil
    }
    thread.runHistory?[0].status = .running; thread.runHistory?[0].endedAt = nil; thread.runHistory?[0].endReason = nil
    thread.runHistory?[0].pi = nil; thread.runHistory?[0].configuration = captured
    thread.activeRun = .init(id: fixture.consumerID, configuration: captured, startedAt: fixture.now); thread.state = .running
    let suppliedID = kind == "missing" ? nil : kind == "foreign" ? UUID() : fixture.intent.id
    let preparation = try PiRunHistoryPreparation(id: prior.id, runID: prior.runID, runtimeIdentity: prior.runtimeIdentity,
        observedVersion: prior.observedVersion, openingInput: prior.openingInput, baseline: prior.baseline, freshIntentID: suppliedID,
        freshEmptyObservation: suppliedID == nil ? nil : prior.freshEmptyObservation)
    let before = thread
    if kind == "matching" {
        try thread.preparePiRunHistory(preparation)
        #expect(thread.runHistory?.first?.pi?.preparation.freshIntentID == fixture.intent.id)
        #expect(thread.runHistory?.first?.pi?.nativeSessionID != fixture.intent.originalNativeSessionID)
        #expect(thread.piFreshSessionIntent == fixture.intent && thread.piFreshConsumerRunID == fixture.consumerID)
        #expect(thread.draft == before.draft && thread.queuedTurns == before.queuedTurns && thread.activeRun == before.activeRun)
    } else {
        #expect(throws: (any Error).self) { try thread.preparePiRunHistory(preparation) }
        #expect(thread == before)
    }
}

@Test(arguments: [ThreadRunStatus.completed, .failed, .unknown])
func piFreshOnlyProvenCompletedTurnAutomaticallyReleasesItsIntentWithoutChangingQueuedCaptures(status: ThreadRunStatus) throws {
    let fixture = try PiFreshReducerFixture(proven: status != .unknown, status: status)
    var thread = fixture.thread
    try thread.completeProvenPiFreshSession(now: fixture.now)
    if status == .completed {
        #expect(thread.piFreshSessionIntent == nil && thread.piFreshConsumerRunID == nil)
        #expect(thread.piFreshContextResolutions?.count == 1)
        try thread.completeProvenPiFreshSession(now: fixture.now)
        #expect(thread.piFreshContextResolutions?.count == 1)
    } else {
        #expect(thread.piFreshSessionIntent == fixture.intent && thread.piFreshConsumerRunID == fixture.consumerID)
        #expect(thread.piFreshContextResolutions == nil)
    }
    #expect(thread.queuedTurns == fixture.thread.queuedTurns && thread.messages == fixture.thread.messages && thread.draft == fixture.thread.draft)
    #expect(thread.runHistory == fixture.thread.runHistory)
}
