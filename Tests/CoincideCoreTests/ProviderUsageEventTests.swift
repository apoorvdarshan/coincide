import Foundation
import Testing
@testable import CoincideCore

private struct UsageEventFixture {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let runtimeID = UUID()
    var snapshot: WorkspaceSnapshot
    let threadID: UUID, runID: UUID
    init(provider: ProviderKind = .claude) throws {
        let project = WorkspaceProject(path: "/tmp/coincide-usage-events")
        var thread = CodingThread(project: project)
        thread.provider = provider; thread.checkpointPolicy = .disabled
        if provider == .opencode { thread.openCodeConfiguration = .init(executable: "/fixture/unused-opencode") }
        var initial = WorkspaceSnapshot(); initial.projects = [project]; initial.threads = [thread]
        let started = try WorkspaceDecision.make(.client(.submit(threadID: thread.id, text: "Controlled usage input")), id: UUID(), snapshot: initial, now: now)
        snapshot = started.snapshot; snapshot.threads[0].runtimeID = runtimeID
        threadID = thread.id; runID = try #require(started.snapshot.threads[0].activeRun?.id)
    }
    mutating func receive(_ event: ProviderEvent, runtime: UUID? = nil) throws {
        snapshot = try WorkspaceDecision.make(.provider(threadID: threadID, runtimeID: runtime ?? runtimeID, event: event),
            id: UUID(), snapshot: snapshot, now: now).snapshot
    }
    func claude(revision: Int64, run: UUID? = nil, cost: Double) throws -> ProviderUsageUpdate {
        .claude(try .init(runID: run ?? runID, revision: revision,
            turn: .init(usageStatus: .complete, inputTokens: Int(revision) * 10, cachedInputTokens: 1,
                cacheCreationTokens: 2, outputTokens: 4, reasoningTokens: nil),
            session: .init(estimatedCostUSD: cost, observedAt: now), observedAt: now))
    }
}

@Test func providerUsageScopedSnapshotsReplaceWithoutSummingAndPersistThroughJournalReplay() async throws {
    var f = try UsageEventFixture()
    let first = try f.claude(revision: 1, cost: 0.01), second = try f.claude(revision: 2, cost: 0.025)
    try f.receive(.context(runID: f.runID, event: .usage(first)))
    try f.receive(.context(runID: f.runID, event: .usage(second)))
    try f.receive(.context(runID: f.runID, event: .usage(first)))
    #expect(f.snapshot.threads[0].runHistory?.first?.providerUsage == second)
    guard case .claude(let observed) = f.snapshot.threads[0].runHistory?.first?.providerUsage else { Issue.record("Missing scoped accounting"); return }
    #expect(observed.session?.estimatedCostUSD == 0.025 && observed.turn?.inputTokens == 20)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-usage-journal-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    _ = try await database.commit(f.snapshot, event: "controlled.usage", commandID: UUID())
    let rebuilt = try await database.rebuildProjection()
    #expect(rebuilt.snapshot.threads[0].runHistory?.first?.providerUsage == second)
    #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(f.snapshot)) == f.snapshot)
}

@Test(arguments: ["unscoped", "wrongRun", "wrongRuntime", "wrongProvider", "wrongSnapshotRun"])
func providerUsageCannotAttributeForeignOrUnscopedAccountingToTheCurrentRun(scenario: String) throws {
    var f = try UsageEventFixture(), event: ProviderEvent
    let originalState = f.snapshot.threads[0].state
    let update = scenario == "wrongProvider" ? ProviderUsageUpdate.openCode(try .init(usageStatus: .unavailable)) :
        try f.claude(revision: 1, run: scenario == "wrongSnapshotRun" ? UUID() : nil, cost: 0)
    if scenario == "unscoped" { event = .usage(update) }
    else { event = .context(runID: scenario == "wrongRun" ? UUID() : f.runID, event: .usage(update)) }
    try f.receive(event, runtime: scenario == "wrongRuntime" ? UUID() : nil)
    #expect(f.snapshot.threads[0].runHistory?.first?.providerUsage == nil)
    #expect(f.snapshot.threads[0].activeRun?.id == f.runID && f.snapshot.threads[0].state == originalState)
}

@Test func providerUsageOldRunCannotChangeACompletedRecordOrTheNextCapturedInput() throws {
    var f = try UsageEventFixture()
    let first = try f.claude(revision: 1, cost: 0.01)
    try f.receive(.context(runID: f.runID, event: .usage(first)))
    try f.receive(.context(runID: f.runID, event: .completed(.idle)))
    f.snapshot = try WorkspaceDecision.make(.client(.submit(threadID: f.threadID, text: "Next controlled input")),
        id: UUID(), snapshot: f.snapshot, now: f.now.addingTimeInterval(1)).snapshot
    let next = try #require(f.snapshot.threads[0].activeRun?.id)
    try f.receive(.context(runID: f.runID, event: .usage(try f.claude(revision: 2, cost: 0.03))))
    #expect(next != f.runID && f.snapshot.threads[0].activeRun?.id == next)
    #expect(f.snapshot.threads[0].runHistory?.first?.providerUsage == first)
    #expect(f.snapshot.threads[0].runHistory?.last?.providerUsage == nil)
}

@Test func providerUsageLegacyMissingKeyAndLivePassiveScopeRemainDistinct() throws {
    var f = try UsageEventFixture()
    var data = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.snapshot.threads[0].runHistory![0])) as? [String: Any])
    #expect(data["providerUsage"] == nil)
    data.removeValue(forKey: "providerUsage")
    #expect(try JSONDecoder().decode(ThreadRunRecord.self, from: JSONSerialization.data(withJSONObject: data)).providerUsage == nil)
    let passive = try ClaudeUsageSnapshot(revision: 2, session: .init(estimatedCostUSD: 0.01, observedAt: f.now), observedAt: f.now)
    f.snapshot.threads[0].providerMetadata = .object(["claudeUsage": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(passive))])
    #expect(f.snapshot.threads[0].liveProviderUsage == .claude(passive))
    let stale = try ClaudeUsageSnapshot(runID: UUID(), revision: 3, observedAt: f.now)
    f.snapshot.threads[0].providerMetadata = .object(["claudeUsage": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(stale))])
    #expect(f.snapshot.threads[0].liveProviderUsage == nil)
}
