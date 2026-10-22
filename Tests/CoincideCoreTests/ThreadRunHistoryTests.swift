import Foundation
import Testing
@testable import CoincideCore

struct RunHistoryFixture {
    var snapshot: WorkspaceSnapshot
    let threadID: UUID
    let runtimeID = UUID()
    var date = Date(timeIntervalSince1970: 1_700_000_000)
    var thread: CodingThread { snapshot.threads[0] }
    init() {
        let project = WorkspaceProject(path: FileManager.default.temporaryDirectory.path)
        var thread = CodingThread(project: project); thread.model = "first-model"; thread.checkpointPolicy = .disabled
        threadID = thread.id; snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    }
    @discardableResult mutating func command(_ command: EngineCommand, id: UUID = UUID()) throws -> WorkspaceDecision {
        date.addTimeInterval(1)
        let decision = try WorkspaceDecision.make(command, id: id, snapshot: snapshot, now: date)
        snapshot = decision.snapshot; return decision
    }
    mutating func submit(_ text: String, id: UUID = UUID()) throws {
        try command(.client(.submit(threadID: threadID, text: text)), id: id)
    }
    mutating func connect() throws {
        try command(.runtimeOpened(threadID: threadID, runID: try #require(thread.activeRun?.id), runtimeID: runtimeID))
    }
    mutating func event(_ event: ProviderEvent, runID: UUID? = nil) throws {
        let event = runID.map { ProviderEvent.context(runID: $0, event: event) } ?? event
        try command(.provider(threadID: threadID, runtimeID: runtimeID, event: event))
    }
}

@Test func runHistoryRetainsCapturedQueueSettingsAndCompletedTurnReferences() throws {
    var f = RunHistoryFixture(); let first = UUID(), second = UUID()
    try f.submit("First prompt", id: first); try f.connect()
    try f.event(.thread("provider-session")); try f.event(.turn("native-first"), runID: first)
    try f.command(.client(.editThread(f.threadID, .model("queued-model"))))
    try f.command(.client(.editThread(f.threadID, .permission(.autoAcceptEdits))))
    try f.submit("Queued prompt", id: second)
    try f.command(.client(.editThread(f.threadID, .model("later-model"))))
    #expect(f.thread.runHistory?.count == 1)
    let firstStarted = try #require(f.thread.runHistory?.first?.startedAt)
    try f.event(.completed(.idle), runID: first)
    let records = try #require(f.thread.runHistory)
    #expect(records.count == 2 && records[0].id == first && records[1].id == second)
    #expect(records[0].origin == .user && records[0].status == .completed && records[0].endReason == .providerCompleted)
    #expect(records[0].startedAt == firstStarted && records[0].endedAt == f.date)
    #expect(records[0].configuration.model == "first-model" && records[0].configuration.permission == .supervised)
    #expect(records[0].providerThreadID == "provider-session" && records[0].turnIDs == ["native-first"])
    #expect(records[1].configuration.model == "queued-model" && records[1].configuration.permission == .autoAcceptEdits)
    #expect(records[1].configuration.nativeThreadID == "provider-session" && records[1].status == .running)
    #expect(f.thread.messages.first(where: { $0.id == records[1].userMessageID })?.text == "Queued prompt")
    let unchanged = f.snapshot
    try f.event(.turn("late-first"), runID: first); try f.event(.completed(.failed), runID: first)
    #expect(f.snapshot == unchanged)
    try f.event(.turn("native-second"), runID: second); try f.event(.turn("native-second"), runID: second)
    try f.event(.completed(.idle), runID: second)
    #expect(f.thread.runHistory?.last?.turnIDs == ["native-second"])
    #expect(f.thread.runHistory?.allSatisfy { $0.status == .completed } == true)
}

@Test func runHistoryStopAndForcedRuntimeClosureRemainInterruptedWithoutInventingTurnID() throws {
    var f = RunHistoryFixture(); let id = UUID()
    try f.submit("Stop during startup", id: id); try f.connect()
    try f.command(.client(.interrupt(threadID: f.threadID)))
    #expect(f.thread.runHistory?.first?.stopRequested == true && f.thread.runHistory?.first?.endedAt == nil)
    try f.command(.effectResult(.providerInterrupt(threadID: f.threadID, runID: id), .stopped))
    let record = try #require(f.thread.runHistory?.first)
    #expect(record.status == .interrupted && record.endReason == .forcedStop && record.turnIDs.isEmpty)
    #expect(f.thread.activeRun == nil && f.thread.queuePaused)
    let stopped = f.snapshot; try f.event(.completed(.idle), runID: id)
    #expect(f.snapshot == stopped)
}

@Test func runHistoryApprovalAndAdapterReferencesTrackOnlyObservedChanges() throws {
    var f = RunHistoryFixture(); try f.submit("Needs approval"); try f.connect()
    let request = ApprovalRequest(id: .string("approval"), method: "item/commandExecution/requestApproval", params: .object([:]))
    try f.event(.approval(request))
    #expect(f.thread.runHistory?.first?.status == .awaitingApproval)
    try f.event(.approvalDismissed(request.id))
    #expect(f.thread.runHistory?.first?.status == .running)
    try f.event(.turn("adapter-generation-a")); try f.event(.turn("adapter-generation-b"))
    try f.event(.completed(.idle))
    #expect(f.thread.runHistory?.first?.turnIDs == ["adapter-generation-a", "adapter-generation-b"])
    #expect(f.thread.runHistory?.first?.status == .completed)
}

@Test(arguments: ["start", "failure", "connection", "stopped-completion"]) func runHistoryDistinguishesFailureAndStopSources(_ source: String) throws {
    var f = RunHistoryFixture(); try f.submit("Prompt"); try f.connect()
    let run = try #require(f.thread.activeRun)
    let reason: ThreadRunEndReason
    switch source {
    case "start":
        try f.command(.effectResult(.providerStart(threadID: f.threadID, runID: run.id, configuration: run.configuration, prompt: "Prompt"), .failed("Synthetic start error")))
        reason = .startFailed
    case "failure": try f.event(.failure("Synthetic provider error")); reason = .providerFailure
    case "connection": try f.event(.connectionClosed("Synthetic connection loss")); reason = .connectionLost
    default:
        try f.command(.client(.interrupt(threadID: f.threadID))); try f.event(.completed(.idle)); reason = .providerCompleted
    }
    let record = try #require(f.thread.runHistory?.first)
    #expect(record.endReason == reason && record.endedAt == f.date)
    #expect(record.status == (source == "stopped-completion" ? .interrupted : .failed))
    #expect(f.thread.activeRun == nil && f.thread.queuePaused)
}

@Test(arguments: ["end_turn", "cancelled", "error", "future_reason"]) func runHistoryAgentInitiatedActivityHasNoFakeUserMessage(_ reason: String) throws {
    var f = RunHistoryFixture(); f.snapshot.threads[0].runtimeID = f.runtimeID
    let id = UUID()
    try f.event(.activity(.init(id: id, state: .running)))
    #expect(f.thread.runHistory?.first?.origin == .agent && f.thread.messages.isEmpty)
    #expect(f.thread.runHistory?.first?.userMessageID == nil)
    try f.event(.activity(.init(id: id, state: .requiresAction)))
    #expect(f.thread.runHistory?.first?.status == .awaitingApproval)
    try f.event(.activity(.init(id: id, state: .idle, stopReason: .string(reason))))
    let expected: ThreadRunStatus = reason == "end_turn" ? .completed : reason == "cancelled" ? .interrupted : reason == "error" ? .failed : .unknown
    #expect(f.thread.runHistory?.first?.status == expected && f.thread.runHistory?.first?.providerStopReason == reason)
    #expect(f.thread.runHistory?.first?.endReason == .providerActivity)
    #expect(f.thread.messages.allSatisfy { $0.role != .user })
    let finished = f.snapshot; try f.event(.activity(.init(id: id, state: .running)))
    #expect(f.snapshot == finished)
}

@Test func runHistoryRestartPreservesKnownRunsAndDoesNotBackfillLegacyTranscript() throws {
    var f = RunHistoryFixture()
    f.snapshot.threads[0].messages = [.init(role: .user, text: "Old unknown turn"), .init(role: .assistant, text: "Old reply")]
    let encoded = try JSONEncoder().encode(f.snapshot), decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded)
    #expect(decoded.threads[0].runHistory == nil)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("runHistory"))
    try f.submit("Known turn"); try f.connect(); try f.event(.turn("known-reference"))
    f.snapshot.recoverInterruptedWork()
    let record = try #require(f.thread.runHistory?.first)
    #expect(f.thread.runHistory?.count == 1 && record.status == .interrupted && record.endReason == .applicationClosed)
    #expect(record.origin == .user && record.turnIDs == ["known-reference"] && f.thread.activeRun == nil)
    try WorkspaceJournal.validate(f.snapshot)
    let recovered = f.snapshot; f.snapshot.recoverInterruptedWork(); #expect(f.snapshot == recovered)
    var legacy = decoded
    legacy.threads[0].activeRun = .init(id: UUID(), configuration: .init(thread: legacy.threads[0]), startedAt: f.date)
    legacy.threads[0].state = .running; legacy.recoverInterruptedWork()
    #expect(legacy.threads[0].runHistory?.first?.origin == .legacy && legacy.threads[0].runHistory?.first?.userMessageID == nil)
    try WorkspaceJournal.validate(legacy)
}

@Test func runHistoryRebuildsFromJournalAndRejectsInvalidBoundaries() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("history.sqlite"))
    var f = RunHistoryFixture(); try await database.save(f.snapshot, event: "fixture.initial")
    try f.submit("Remember these settings"); try await database.save(f.snapshot, event: "fixture.started")
    try f.connect(); try f.event(.thread("saved-session")); try f.event(.turn("saved-reference"))
    try await database.save(f.snapshot, event: "fixture.acknowledged")
    try f.event(.completed(.idle)); try await database.save(f.snapshot, event: "fixture.completed")
    #expect(try await database.rebuildProjection().snapshot == f.snapshot)
    #expect(try await WorkspaceDatabase(url: root.appendingPathComponent("history.sqlite")).load() == f.snapshot)
    let valid = f.snapshot
    let duplicate = try #require(f.thread.runHistory?.first)
    f.snapshot.threads[0].runHistory?.append(duplicate)
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(f.snapshot) }
    f.snapshot = valid; f.snapshot.threads[0].runHistory?[0].endedAt = nil
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(f.snapshot) }
    f.snapshot = valid; f.snapshot.threads[0].runHistory?[0].userMessageID = "missing-user"
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(f.snapshot) }
    f.snapshot = valid; f.snapshot.threads[0].runHistory?[0].status = .running; f.snapshot.threads[0].runHistory?[0].endedAt = nil; f.snapshot.threads[0].runHistory?[0].endReason = nil
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(f.snapshot) }
}
