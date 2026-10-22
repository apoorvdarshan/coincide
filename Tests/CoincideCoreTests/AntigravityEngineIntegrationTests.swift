import Foundation
import Testing
@testable import CoincideCore

/// Actual production native factory, real private stdio, exact file delegation,
/// SQLite and replay. No Antigravity executable/account/model is contacted.
@Test(.timeLimit(.minutes(1)))
func antigravityEngineCapturedFIFOFileGuardNativeStopAndReopenWithoutReplay() async throws {
    let fixture = try AntigravityFixture(options: ["holdCancel": .bool(true), "delegateFiles": .bool(true)])
    let databaseURL = fixture.root.appendingPathComponent("workspace.sqlite")
    let engine = try WorkspaceEngine(url: databaseURL, providerFactory: { try ProviderSessions.make(for: $0, antigravityStateRoot: fixture.state) }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        let project = WorkspaceProject(path: fixture.root.path)
        var thread = CodingThread(project: project)
        thread.provider = .antigravity; thread.antigravityConfiguration = fixture.configuration; thread.permission = .supervised; thread.checkpointPolicy = .disabled
        try await engine.dispatch(.addProject(project)); try await engine.dispatch(.createThread(thread))
        try await engine.dispatch(.submit(threadID: thread.id, text: "First generated native prompt"))
        try await antigravityEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return current?.messages.contains { $0.text == "Native 日本語 reply" } == true && FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("delegated.txt").path)
        }
        let state = await engine.current().snapshot, first = try #require(state.threads.first { $0.id == thread.id })
        let firstID = try #require(first.activeRun?.id)
        #expect(first.providerThreadID != nil && first.activeRun?.nativeTurnID == nil)
        try await engine.dispatch(.editThread(thread.id, .model("selected")))
        try await engine.dispatch(.editThread(thread.id, .permission(.fullAccess)))
        try await engine.dispatch(.submit(threadID: thread.id, text: "Captured queued native prompt"))
        try await engine.dispatch(.editThread(thread.id, .model("native-default")))
        try await engine.dispatch(.editThread(thread.id, .permission(.supervised)))
        let held = await engine.current().snapshot.threads.first { $0.id == thread.id }
        #expect(held?.activeRun?.id == firstID && held?.queuedTurns.count == 1)
        try fixture.signal("finish")
        try await antigravityEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return (try? fixture.rows("prompt").count) == 2 && current?.activeRun?.id != nil && current?.activeRun?.id != firstID
        }
        let prompts = try fixture.rows("prompt"), requests = try fixture.rows("request")
        #expect(prompts.map { $0["model"].string } == ["native-default", "selected"])
        #expect(prompts.map { $0["mode"].string } == ["default", "yolo"])
        #expect(prompts[0]["sessionID"] == prompts[1]["sessionID"])
        #expect(requests.contains { $0["method"] == .string("session/resume") })
        let running = await engine.current().snapshot.threads.first { $0.id == thread.id }
        #expect(running?.activeRun?.configuration.antigravityConfiguration?.model == "selected")
        #expect(running?.antigravityConfiguration?.model == "native-default" && running?.permission == .supervised)
        try await engine.dispatch(.interrupt(threadID: thread.id))
        try await antigravityEventually { try fixture.rows("cancel").count == 1 }
        let beforeTerminal = await engine.current().snapshot.threads.first { $0.id == thread.id }
        #expect(beforeTerminal?.activeRun != nil)
        try fixture.signal("cancelled")
        try await antigravityEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return current?.activeRun == nil && current?.state == .interrupted
        }
        await engine.shutdown(); try await antigravityEventually { fixture.stopped }
        let finalState = await engine.current().snapshot, final = try #require(finalState.threads.first { $0.id == thread.id })
        let database = try WorkspaceDatabase(url: databaseURL), rebuilt = try await database.rebuildProjection().snapshot
        let saved = try #require(rebuilt.threads.first { $0.id == thread.id })
        #expect(final.runHistory?.map(\.status) == [.completed, .interrupted])
        #expect(saved.messages == final.messages && saved.runHistory == final.runHistory && saved.antigravityConfiguration == final.antigravityConfiguration)
        let reopened = try WorkspaceEngine(url: databaseURL, providerFactory: { try ProviderSessions.make(for: $0, antigravityStateRoot: fixture.state) }, identityResolver: { _ in nil })
        _ = try await reopened.load(); await reopened.shutdown()
        let after = try fixture.rows("prompt"); #expect(after.count == 2 && fixture.stopped)
        try fixture.remove()
    } catch { await engine.shutdown(); try? fixture.remove(); throw error }
}
