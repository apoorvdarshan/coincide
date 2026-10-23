import Foundation
import Testing
@testable import CoincideCore

private actor ClaudeUsageSessionEvents {
    private(set) var usage: [UUID: [ClaudeUsageSnapshot]] = [:]
    private(set) var metadata: [JSONValue] = []
    private(set) var completed = 0
    private(set) var terminalOrder: [UUID: [String]] = [:]
    private var lastCompletedRunID: UUID?
    func accept(_ event: ProviderEvent, runID: UUID? = nil) {
        switch event {
        case .context(let id, let child): accept(child, runID: id)
        case .usage(.claude(let value)):
            guard let runID else { Issue.record("Active usage must carry its app run owner"); return }
            usage[runID, default: []].append(value)
            if value.turn?.usageStatus == .complete { terminalOrder[runID, default: []].append("usage.complete") }
        case .configuration(let value):
            metadata.append(value)
            if let lastCompletedRunID, value["claudeUsage"].object != nil,
               value["claudeUsage"]["runID"] == .null, value["claudeUsage"]["turn"] == .null {
                terminalOrder[lastCompletedRunID, default: []].append("passive")
            }
        case .completed:
            completed += 1
            if let runID { lastCompletedRunID = runID; terminalOrder[runID, default: []].append("completed") }
        default: break
        }
    }
}
private func waitClaudeUsageSession(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The offline usage peer did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1))) func claudeUsageStdioOwnsLiveRunsAndKeepsIdleLimitsOutOfCompletedAccountingAndModelLaunchMetadata() async throws {
    let created = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-usage-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let root = URL(fileURLWithPath: try ClaudeRuntimeValidation.physical(created.path, allowMissing: false))
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude-peer.py"), home = root.appendingPathComponent("private-config")
    let resource = try #require(Bundle.module.url(forResource: "claude_usage", withExtension: "py", subdirectory: "Fixtures"))
    try FileManager.default.copyItem(at: resource, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var thread = CodingThread(project: .init(path: root.path)); thread.provider = .claude
    thread.claudeRuntimeConfiguration = try ClaudeRuntimeConfiguration.capture(workspacePath: thread.workspacePath,
        executable: executable.path, configurationDirectory: home.path, launchSettings: .init(autoCompactWindow: 200_000))
    thread.draft = "Preserve the literal unsent draft e\u{301}\n "
    let first = UUID(), second = UUID()
    thread.activeRun = .init(id: first, configuration: .init(thread: thread), startedAt: .now)
    let runtime = try #require(thread.claudeRuntimeConfiguration)
    let session = try ClaudeSession(executable: executable, cwd: URL(fileURLWithPath: thread.workspacePath), configuration: runtime)
    let observed = ClaudeUsageSessionEvents(), reading = Task { for await event in session.events { await observed.accept(event) } }
    do {
        try await session.send(text: "First explicit offline input", thread: thread)
        try await waitClaudeUsageSession { await observed.completed == 1 }
        try await waitClaudeUsageSession {
            let latest = await observed.metadata.last
            return latest?["claudeUsage"]["runID"] == .null && latest?["claudeUsage"]["rateLimits"].array?.count == 1
        }
        let firstUpdates = try #require(await observed.usage[first])
        let firstFinal = try #require(firstUpdates.last)
        #expect(firstFinal.runID == first && firstFinal.turn?.usageStatus == .complete)
        #expect(firstFinal.turn?.inputTokens == 220 && firstFinal.turn?.outputTokens == 20 && firstFinal.turn?.reasoningTokens == 7)
        #expect(firstFinal.turn?.hasSubagents == true && firstFinal.session?.estimatedCostUSD == 0.12)
        #expect(firstUpdates.compactMap(\.context).allSatisfy { $0.usedTokens < 900_000 && $0.maxTokens == nil })
        #expect(firstUpdates.last?.rateLimits.isEmpty == true, "The idle rate event cannot rewrite already emitted per-run accounting.")
        let latest = try #require(await observed.metadata.last)
        #expect(latest["claudeModelControl"]["version"] == .string("2.1.308"))
        #expect(latest["claudeLaunchSettings"]["effectiveAutoCompactWindow"] == .number(200_000))
        let passiveData = try JSONEncoder().encode(latest["claudeUsage"])
        let passive = try JSONDecoder().decode(ClaudeUsageSnapshot.self, from: passiveData)
        #expect(passive.runID == nil && passive.turn == nil && passive.rateLimits.first?.blocked == false)
        thread.activeRun = .init(id: second, configuration: .init(thread: thread), startedAt: .now)
        try await session.send(text: "Second explicit offline input", thread: thread)
        try await waitClaudeUsageSession { await observed.completed == 2 }
        // The peer emits no idle rate/status event after its second result.
        // Completion itself must retain a passive current-session observation.
        try await waitClaudeUsageSession {
            let latest = await observed.metadata.last
            return latest?["claudeUsage"]["runID"] == .null && latest?["claudeUsage"]["turn"] == .null &&
                latest?["claudeUsage"]["session"]["estimatedCostUSD"] == .number(0.19)
        }
        let all = await observed.usage
        #expect(Set(all.keys) == Set([first, second]))
        let secondFinal = try #require(all[second]?.last)
        #expect(secondFinal.runID == second && secondFinal.revision > firstFinal.revision)
        #expect(secondFinal.turn?.inputTokens == 60 && secondFinal.turn?.outputTokens == 7)
        #expect(secondFinal.session?.estimatedCostUSD == 0.19 && secondFinal.session?.models.first?.inputTokens == 600)
        let ordering = await observed.terminalOrder
        #expect(Array((ordering[first] ?? []).prefix(3)) == ["usage.complete", "completed", "passive"])
        #expect(Array((ordering[second] ?? []).prefix(3)) == ["usage.complete", "completed", "passive"])
        for updates in all.values {
            #expect(zip(updates, updates.dropFirst()).allSatisfy { $0.0.revision < $0.1.revision })
            for update in updates { try update.validate() }
        }
        let safeEvents = try JSONEncoder().encode(await observed.metadata)
        #expect(!String(decoding: safeEvents, as: UTF8.self).contains("PRIVATE-MUST-NOT-PERSIST"))
        #expect(thread.draft.utf8.elementsEqual("Preserve the literal unsent draft e\u{301}\n ".utf8))
        let frames = try Data(contentsOf: root.appendingPathComponent("wire.jsonl")).split(separator: 10)
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
        #expect(frames.filter { $0["type"] == .string("user") }.count == 2)
        #expect(!frames.contains { $0["request"]["subtype"] == .string("get_usage") || $0["request"]["subtype"] == .string("get_context_usage") })
        await session.close(); await reading.value
    } catch { await session.close(); await reading.value; throw error }
}
