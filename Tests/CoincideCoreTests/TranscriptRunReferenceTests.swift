import Foundation
import Testing
@testable import CoincideCore

@Test func transcriptProvenanceTracksAcceptedRunsAndPreservesReferencesAcrossReplacementAndFIFO() throws {
    var f = RunHistoryFixture()
    let first = UUID(), second = UUID()
    try f.submit("First prompt", id: first); try f.connect()
    try f.event(.delta(id: "assistant-one", role: .assistant, text: "Streamed"))
    var replacement = ChatMessage(id: "assistant-one", role: .assistant, text: "Complete first reply")
    replacement.runReference = .init(threadID: UUID(), runID: UUID())
    try f.event(.message(replacement))
    try f.submit("Second prompt", id: second)
    try f.event(.completed(.idle), runID: first)
    try f.event(.delta(id: "assistant-two", role: .assistant, text: "Second reply"), runID: second)
    try f.event(.completed(.idle), runID: second)
    let thread = f.thread
    #expect(thread.runHistory?.allSatisfy { $0.messageAttributionVersion == 1 } == true)
    #expect(thread.messages.prefix(2).allSatisfy { $0.runReference == .init(threadID: thread.id, runID: first) })
    #expect(thread.messages.suffix(2).allSatisfy { $0.runReference == .init(threadID: thread.id, runID: second) })
    #expect(try thread.transcriptPrefix(runID: first, boundary: .afterRun).map(\.text) == ["First prompt", "Complete first reply"])
    #expect(try thread.transcriptPrefix(runID: second, boundary: .beforeRun).map(\.text) == ["First prompt", "Complete first reply"])
    #expect(try thread.transcriptPrefix(runID: first, boundary: .beforeRun).isEmpty)
    #expect(try thread.transcriptPrefix(runID: second, boundary: .afterRun) == thread.messages)
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func transcriptProvenanceIgnoresProviderSuppliedReferencesAndRetainsAssociatedUserIdentity() throws {
    var f = RunHistoryFixture(); let run = UUID()
    try f.submit("Accepted text", id: run); try f.connect()
    var malicious = ChatMessage(id: "new-provider-message", role: .assistant, text: "Provider reply")
    malicious.runReference = .init(threadID: UUID(), runID: UUID())
    try f.event(.message(malicious))
    let update = try ProviderEntityUpdate.acp(.object(["sessionUpdate": .string("user_message"),
        "messageId": .string("user-echo"), "content": .array([.object(["type": .string("text"), "text": .string("Provider echo")])])]), sessionID: "native-session")
    try f.event(.entity(update))
    try f.event(.associateEntity(update.key, clientMessageID: "user-" + run.uuidString))
    #expect(f.thread.messages.count == 2)
    #expect(f.thread.messages.first?.text == "Accepted text")
    #expect(f.thread.messages.allSatisfy { $0.runReference == .init(threadID: f.threadID, runID: run) })
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func transcriptProvenanceRetainsLateEntityUpdatesButRejectsUnattributedSuffixBoundaries() throws {
    var f = RunHistoryFixture(); let run = UUID()
    try f.submit("Prompt", id: run); try f.connect()
    func update(_ id: String, _ text: String) throws -> ProviderEntityUpdate {
        try .acp(.object(["sessionUpdate": .string("agent_message"), "messageId": .string(id),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])]), sessionID: "native-session")
    }
    try f.event(.entity(update("reply", "First reply")))
    try f.event(.completed(.idle), runID: run)
    try f.event(.entity(update("reply", "Late replacement")))
    #expect(f.thread.messages.last?.runReference == .init(threadID: f.threadID, runID: run))
    #expect(try f.thread.transcriptPrefix(runID: run, boundary: .afterRun).last?.text == "Late replacement")
    try f.event(.entity(update("background", "Unattributed later activity")))
    #expect(f.thread.messages.last?.runReference == nil)
    #expect(throws: CoincideError.self) { try f.thread.transcriptPrefix(runID: run, boundary: .afterRun) }
}

@Test func transcriptProvenanceNeverBackfillsLegacyRecordsOrCutsByTimestamp() throws {
    var f = RunHistoryFixture(); let run = UUID()
    try f.submit("Older prompt", id: run); try f.connect(); try f.event(.completed(.idle), runID: run)
    var legacy = f.snapshot
    legacy.threads[0].runHistory?[0].messageAttributionVersion = nil
    legacy.threads[0].messages[0].runReference = nil
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(legacy), decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    #expect(try encoder.encode(decoded) == data)
    #expect(decoded.threads[0].messages.first?.runReference == nil)
    #expect(decoded.threads[0].runHistory?.first?.messageAttributionVersion == nil)
    #expect(throws: CoincideError.self) { try decoded.threads[0].transcriptPrefix(runID: run, boundary: .afterRun) }
    try WorkspaceJournal.validate(decoded)
}

@Test func transcriptProvenanceValidatesLocalReferencesAndCompleteOpeningMessages() throws {
    var f = RunHistoryFixture(); let run = UUID()
    try f.submit("Prompt", id: run)
    var missing = f.snapshot
    missing.threads[0].messages[0].runReference = .init(threadID: f.threadID, runID: UUID())
    #expect(throws: CoincideError.self) { try WorkspaceJournal.validate(missing) }
    var unmarked = f.snapshot; unmarked.threads[0].messages[0].runReference = nil
    #expect(throws: CoincideError.self) { try WorkspaceJournal.validate(unmarked) }
    var future = f.snapshot; future.threads[0].runHistory?[0].messageAttributionVersion = 2
    #expect(throws: CoincideError.self) { try WorkspaceJournal.validate(future) }
}

@Test func transcriptProvenanceRecoveryAttributesOnlyNewInterruptionNoticeAndPreservesJournalReplay() throws {
    var f = RunHistoryFixture(); let run = UUID()
    let initial = f.snapshot
    try f.submit("Interrupted prompt", id: run)
    var recovered = f.snapshot; recovered.recoverInterruptedWork()
    #expect(recovered.threads[0].messages.last?.role == .system)
    #expect(recovered.threads[0].messages.allSatisfy { $0.runReference == .init(threadID: f.threadID, runID: run) })
    let events = try WorkspaceJournal.changes(from: initial, to: recovered)
    var rebuilt = initial
    for event in events { try event.apply(to: &rebuilt) }
    try WorkspaceJournal.validate(rebuilt)
    #expect(rebuilt == recovered)
}

@Test func transcriptProvenancePreservesUnattributedEarlierContextWithoutInventingItsRuns() throws {
    var f = RunHistoryFixture(); let run = UUID()
    let earlier = [ChatMessage(role: .user, text: "Imported earlier prompt"), ChatMessage(role: .assistant, text: "Imported earlier reply")]
    f.snapshot.threads[0].messages = earlier
    try f.submit("New prompt", id: run); try f.connect()
    try f.event(.delta(id: "new-reply", role: .assistant, text: "New reply"))
    try f.event(.completed(.idle), runID: run)
    #expect(try f.thread.transcriptPrefix(runID: run, boundary: .beforeRun) == earlier)
    #expect(try f.thread.transcriptPrefix(runID: run, boundary: .afterRun) == f.thread.messages)
    #expect(f.thread.messages.prefix(2).allSatisfy { $0.runReference == nil })
    #expect(f.thread.runHistory?.count == 1)
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func transcriptProvenanceRejectsInterleavedMessagesInsteadOfDroppingAnotherRun() throws {
    var f = RunHistoryFixture(); let first = UUID(), second = UUID()
    try f.submit("First", id: first); try f.connect()
    try f.event(.delta(id: "first-reply", role: .assistant, text: "First reply"))
    try f.submit("Second", id: second); try f.event(.completed(.idle), runID: first)
    try f.event(.delta(id: "second-reply", role: .assistant, text: "Second reply"), runID: second)
    try f.event(.completed(.idle), runID: second)
    var interleaved = f.thread
    interleaved.messages.swapAt(1, 2)
    #expect(throws: CoincideError.self) { try interleaved.transcriptPrefix(runID: first, boundary: .afterRun) }
    #expect(throws: CoincideError.self) { try interleaved.transcriptPrefix(runID: second, boundary: .beforeRun) }
    #expect(interleaved.messages.count == f.thread.messages.count)
}

@Test func transcriptProvenanceRejectsAnActiveRunAndDoesNotInventAnAgentOpeningUserMessage() throws {
    var f = RunHistoryFixture(); let run = UUID()
    f.snapshot.threads[0].runtimeID = f.runtimeID
    try f.event(.activity(.init(id: run, state: .running)))
    try f.event(.delta(id: "agent-reply", role: .assistant, text: "Agent-initiated reply"))
    #expect(throws: CoincideError.self) { try f.thread.transcriptPrefix(runID: run, boundary: .afterRun) }
    try f.event(.activity(.init(id: run, state: .idle, stopReason: .string("end_turn"))))
    #expect(f.thread.messages.allSatisfy { $0.role != .user })
    #expect(try f.thread.transcriptPrefix(runID: run, boundary: .afterRun) == f.thread.messages)
    #expect(throws: CoincideError.self) { try f.thread.transcriptPrefix(runID: run, boundary: .beforeRun) }
    try WorkspaceJournal.validate(f.snapshot)
}

@Test(arguments: [false, true])
func transcriptProvenanceChangesCannotBeLostThroughTheJournalTextAppendOptimization(appendsText: Bool) throws {
    var f = RunHistoryFixture(); let run = UUID()
    try f.submit("Prompt", id: run); try f.connect()
    try f.event(.delta(id: "reply", role: .assistant, text: "Reply"))
    try f.event(.completed(.idle), runID: run)
    let previous = f.snapshot
    var next = previous
    next.threads[0].messages[1].runReference = nil
    if appendsText { next.threads[0].messages[1].text += " with additional text" }
    let events = try WorkspaceJournal.changes(from: previous, to: next)
    #expect(events.contains {
        if case .messageUpserted(let threadID, let index, let message) = $0 {
            return threadID == f.threadID && index == 1 && message.runReference == nil
        }
        return false
    })
    var rebuilt = previous
    for event in events { try event.apply(to: &rebuilt) }
    try WorkspaceJournal.validate(rebuilt)
    #expect(rebuilt == next)
}
