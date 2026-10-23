import Foundation
import Testing
@testable import CoincideCore

@Test(.timeLimit(.minutes(1)))
func contextTransferClaudeProfileHandoffClearsPassiveSessionMetersAndPreservesOriginalRecordedUsage() async throws {
    let fm = FileManager.default, now = Date()
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("coincide-context-usage-\(UUID())")
    var owned: WorkspaceEngine?
    do {
        let workspace = root.appendingPathComponent("Workspace")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let project = WorkspaceProject(path: workspace.path)
        var thread = CodingThread(project: project, model: "Private accounting fixture")
        thread.provider = .claude; thread.providerThreadID = UUID().uuidString; thread.checkpointPolicy = .disabled
        thread.draft = "Retain literal unsent draft e\u{301}"
        thread.claudeRuntimeConfiguration = .init(instanceID: UUID(), executable: root.appendingPathComponent("unused-claude").path,
            configurationDirectory: root.appendingPathComponent("old-profile").path, workspacePath: workspace.path)
        let runID = UUID()
        var record = ThreadRunRecord(run: .init(id: runID, configuration: .init(thread: thread), startedAt: now), origin: .user,
            userMessageID: "private-usage-input")
        record.providerThreadID = thread.providerThreadID; record.status = .completed; record.endReason = .providerCompleted
        record.endedAt = now; record.messageAttributionVersion = 1
        let runtime = try #require(thread.claudeRuntimeConfiguration), nativeID = try #require(thread.providerThreadID)
        var evidence = try ClaudeRunHistoryEvidence(runID: runID, runtimeIdentity: runtime.runtimeIdentity, nativeSessionID: nativeID)
        try evidence.observe(nativeSessionID: nativeID, inputIDs: [evidence.openingInputID])
        try evidence.finish(.completed); record.claude = evidence
        let recorded = ProviderUsageUpdate.claude(try .init(runID: runID, revision: 1,
            turn: .init(usageStatus: .complete, inputTokens: 22, outputTokens: 4), observedAt: now))
        record.providerUsage = recorded; thread.runHistory = [record]
        var input = ChatMessage(id: "private-usage-input", role: .user, text: "Retain original accounting owner")
        input.runReference = .init(threadID: thread.id, runID: runID); thread.messages = [input]
        let passive = try ClaudeUsageSnapshot(revision: 4,
            context: .init(source: .nativeReport, model: "old-profile-model", usedTokens: 500, maxTokens: 100_000, observedAt: now),
            session: .init(estimatedCostUSD: 0.12, observedAt: now),
            rateLimits: [.init(window: .fiveHour, status: .allowed, utilization: 0.4)], observedAt: now)
        thread.providerMetadata = .object(["claudeUsage": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(passive)),
                                   "claudeModelControl": .object(["fastModeState": .string("on")])])
        #expect(thread.liveProviderUsage == .claude(passive) && passive.runID == nil)
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        let database = root.appendingPathComponent("workspace.sqlite")
        try await WorkspaceDatabase(url: database).save(snapshot, event: "private-context-usage")
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in throw CoincideError("A reviewed handoff must not launch a provider") }, identityResolver: { _ in nil })
        owned = engine; _ = try await engine.load()
        let source = try #require(await engine.current().snapshot.threads.first)
        #expect(source.liveProviderUsage == .claude(passive))
        var destination = ProviderConfiguration(thread: source); destination.nativeThreadID = nil
        destination.claudeRuntimeConfiguration = .init(instanceID: UUID(), executable: root.appendingPathComponent("unused-claude").path,
            configurationDirectory: root.appendingPathComponent("new-profile").path, workspacePath: workspace.path)
        let review = try await engine.reviewContextTransfer(.init(sourceThreadID: source.id, expectedConfiguration: .init(thread: source),
            sourcePoint: .run(runID), intent: .providerHandoff(destination: destination)))
        let id = UUID(), receipt = try await engine.acceptContextTransfer(reviewID: review.id, digest: review.digest, commandID: id)
        #expect(receipt.commandID == id && receipt.rejection == nil)
        let after = try #require(await engine.current().snapshot.threads.first)
        #expect(after.claudeRuntimeConfiguration == destination.claudeRuntimeConfiguration && after.providerThreadID == nil)
        #expect(after.providerMetadata == nil && after.liveProviderUsage == nil)
        #expect(after.runHistory == source.runHistory && after.runHistory?.first?.providerUsage == recorded)
        #expect(after.messages == source.messages && after.draft == source.draft && after.activeRun == nil && after.queuedTurns.isEmpty)
        await engine.shutdown(); owned = nil
        let saved = try #require(await WorkspaceDatabase(url: database).load().threads.first)
        #expect(saved.providerMetadata == nil && saved.runHistory?.first?.providerUsage == recorded)
        try fm.removeItem(at: root)
    } catch {
        await owned?.shutdown()
        print("Private context usage fixture retained at \(root.path)")
        throw error
    }
}
