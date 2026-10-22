import Foundation
import Testing
@testable import CoincideCore

private func nestedProviderEvent(_ leaf: ProviderEvent, scopes: [UUID]) -> ProviderEvent {
    var result = leaf
    for id in scopes.reversed() { result = .context(runID: id, event: result) }
    return result
}

@Test(arguments: [1, 2, 64]) func nestedProviderContextCompletesExactlyOneRunAndPreservesFIFO(depth: Int) throws {
    var fixture = RunHistoryFixture()
    let first = UUID(), second = UUID(), third = UUID()
    try fixture.submit("First prompt", id: first); try fixture.connect()
    try fixture.event(.thread("native-session")); try fixture.event(.turn("native-first"), runID: first)
    try fixture.command(.client(.editThread(fixture.threadID, .model("queued-model"))))
    try fixture.command(.client(.editThread(fixture.threadID, .permission(.autoAcceptEdits))))
    try fixture.submit("Second prompt", id: second); try fixture.submit("Third prompt", id: third)
    try fixture.command(.client(.editThread(fixture.threadID, .model("future-model"))))

    var direct = fixture
    let commandID = UUID()
    let expected = try direct.command(.provider(threadID: fixture.threadID, runtimeID: fixture.runtimeID,
                                              event: .completed(.idle)), id: commandID)
    let event = nestedProviderEvent(.completed(.idle), scopes: Array(repeating: first, count: depth))
    let observed = try fixture.command(.provider(threadID: fixture.threadID, runtimeID: fixture.runtimeID,
                                               event: event), id: commandID)
    #expect(observed.snapshot == expected.snapshot)
    #expect(observed.effects == expected.effects && observed.closeRuntimes == expected.closeRuntimes)
    #expect(fixture.thread.activeRun?.id == second && fixture.thread.queuedTurns.map(\.id) == [third])
    let records = try #require(fixture.thread.runHistory)
    #expect(records.map(\.id) == [first, second])
    #expect(records[0].status == .completed && records[0].turnIDs == ["native-first"])
    #expect(records[1].status == .running && records[1].configuration.model == "queued-model")
    #expect(records[1].configuration.permission == .autoAcceptEdits && records[1].configuration.nativeThreadID == "native-session")
    #expect(fixture.thread.messages.filter { $0.id == "user-" + second.uuidString }.count == 1)
    let settled = fixture.snapshot
    let late = try fixture.command(.provider(threadID: fixture.threadID, runtimeID: fixture.runtimeID, event: event))
    #expect(fixture.snapshot == settled && late.effects.isEmpty && late.closeRuntimes.isEmpty)
}

@Test(arguments: [0, 1, 2]) func nestedProviderContextRejectsEveryForeignScopeWithoutPartialMutation(foreignIndex: Int) throws {
    var fixture = RunHistoryFixture()
    let runID = UUID()
    try fixture.submit("Keep active", id: runID); try fixture.connect()
    try fixture.event(.turn("native-active"), runID: runID)
    try fixture.submit("Keep queued")
    var scopes = Array(repeating: runID, count: 3); scopes[foreignIndex] = UUID()
    let before = fixture.snapshot
    let leaves: [ProviderEvent] = [.completed(.idle), .failure("Foreign failure must not close this runtime."), .turn("foreign-turn")]
    for leaf in leaves {
        let event = nestedProviderEvent(leaf, scopes: scopes)
        let decision = try fixture.command(.provider(threadID: fixture.threadID, runtimeID: fixture.runtimeID, event: event))
        #expect(fixture.snapshot == before)
        #expect(decision.effects.isEmpty && decision.closeRuntimes.isEmpty)
    }
}
