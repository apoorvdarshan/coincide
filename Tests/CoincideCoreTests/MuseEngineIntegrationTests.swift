import Foundation
import Testing
@testable import CoincideCore

/// Historical native adapter, a private real stdio MSP process and SQLite.
/// The synthetic server never loads Muse, signs in, or invokes a model.
@Test(.timeLimit(.minutes(1)))
func museEngineNativeMSPRunsCapturedFIFOAndExactStopWithDurableReopen() async throws {
    let fixture = try MuseSessionFixture(options: ["newProfileContract": .bool(true), "holdInterruptTerminal": .bool(true)])
    let databaseURL = fixture.root.appendingPathComponent("workspace.sqlite")
    let engine = try WorkspaceEngine(url: databaseURL, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
    let sentinel = fixture.root.appendingPathComponent("source.txt")
    try Data("Preserved source\n".utf8).write(to: sentinel)
    do {
        let project = WorkspaceProject(path: fixture.root.path)
        var thread = CodingThread(project: project)
        thread.provider = .muse; thread.museConfiguration = .init(executable: fixture.executable.path)
        thread.permission = .supervised; thread.checkpointPolicy = .disabled
        try await saveLegacyProviderFixture(project: project, threads: [thread], at: databaseURL)
        _ = try await engine.load()
        try await engine.dispatch(.submit(threadID: thread.id, text: "First generated MSP prompt"))
        try await museEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return current?.activeRun?.nativeTurnID != nil && current?.messages.contains { $0.role == .assistant && $0.text == "Exact 日本語\u{2028}answer" } == true
        }
        let firstState = await engine.current().snapshot
        let first = try #require(firstState.threads.first { $0.id == thread.id }), firstID = try #require(first.activeRun?.id)
        #expect(first.state == .running && first.activeRun?.nativeTurnID != nil)
        let selected = MuseModelSelection(modelID: "selected-model")
        let efforts = [ProviderReasoningEffortOption(id: "low", description: "Low"), .init(id: "high", description: "High")]
        let model = ProviderModel(id: selected.catalogID, name: "Selected", reasoningEfforts: efforts, defaultReasoningEffort: "high",
            museSelection: selected, museReasoningEfforts: efforts, museDefaultReasoningEffort: "high")
        try await engine.dispatch(.editThread(thread.id, .museModel(model)))
        try await engine.dispatch(.editThread(thread.id, .museReasoning(model: model, effort: "high")))
        try await engine.dispatch(.editThread(thread.id, .permission(.fullAccess)))
        try await engine.dispatch(.submit(threadID: thread.id, text: "Second captured MSP FIFO"))
        try await engine.dispatch(.editThread(thread.id, .museReasoning(model: model, effort: "low")))
        try await engine.dispatch(.editThread(thread.id, .permission(.supervised)))
        let held = await engine.current().snapshot.threads.first { $0.id == thread.id }
        #expect(held?.activeRun?.id == firstID && held?.queuedTurns.map(\.text) == ["Second captured MSP FIFO"])
        let before = try fixture.rows("prompt"); #expect(before.count == 1)
        // Real session idle and turn/completed reuse a cursor; both methods
        // must reach the actor so the captured FIFO can advance exactly once.
        try fixture.signal("finish")
        try await museEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return (try? fixture.rows("prompt").count) == 2 && current?.activeRun?.id != nil && current?.activeRun?.id != firstID && current?.activeRun?.nativeTurnID != nil && current?.messages.filter { $0.role == .assistant }.count == 2
        }
        let runningState = await engine.current().snapshot
        let running = try #require(runningState.threads.first { $0.id == thread.id })
        #expect(running.queuedTurns.isEmpty)
        #expect(running.activeRun?.configuration.museConfiguration?.reasoningEffort == "high" && running.activeRun?.configuration.permission == .fullAccess)
        #expect(running.museConfiguration?.reasoningEffort == "low" && running.permission == .supervised)
        let prompts = try fixture.rows("prompt"), processes = try fixture.rows("process")
        #expect(prompts.map { $0["model"].string } == ["native-default", "selected-model"])
        #expect(prompts.map { $0["effort"].string } == ["low", "high"])
        #expect(prompts.map { $0["profile"].string } == [":ask-me", ":unrestricted"])
        #expect(processes.count == 2 && processes.allSatisfy { $0["directoryVerified"] == .bool(true) })
        #expect(processes[1]["arguments"].array?.contains(.string("--disable-sandbox")) == true)
        let requests = try fixture.rows("request"), resumes = requests.filter { $0["method"] == .string("session/resume") }
        #expect(resumes.count == 1 && resumes[0]["params"]["sessionId"].string == first.providerThreadID)
        #expect(resumes[0]["params"]["permissionProfile"] == .string(":unrestricted"))
        try await engine.dispatch(.interrupt(threadID: thread.id))
        try await museEventually { try fixture.rows("interrupt").count == 1 }
        let beforeTerminal = await engine.current().snapshot.threads.first { $0.id == thread.id }
        #expect(beforeTerminal?.activeRun?.id == running.activeRun?.id)
        try fixture.signal("cancelled")
        try await museEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return current?.activeRun == nil && current?.state == .interrupted
        }
        await engine.shutdown(); try await museEventually { fixture.parentsStopped }
        let finalState = await engine.current().snapshot
        let final = try #require(finalState.threads.first { $0.id == thread.id })
        #expect(final.queuePaused && final.runHistory?.map(\.status) == [.completed, .interrupted])
        #expect(final.messages.filter { $0.role == .user }.map(\.text) == ["First generated MSP prompt", "Second captured MSP FIFO"])
        #expect(try Data(contentsOf: sentinel) == Data("Preserved source\n".utf8))
        let database = try WorkspaceDatabase(url: databaseURL), replayed = try await database.rebuildProjection().snapshot
        let saved = try #require(replayed.threads.first { $0.id == thread.id })
        #expect(saved.messages == final.messages && saved.runHistory == final.runHistory && saved.museConfiguration == final.museConfiguration)
        let reopened = try WorkspaceEngine(url: databaseURL, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
        _ = try await reopened.load(); await reopened.shutdown()
        let after = try fixture.rows("prompt"); #expect(after.count == 2 && fixture.parentsStopped)
        try fixture.removeIfStopped()
    } catch { await engine.shutdown(); try? fixture.removeIfStopped(); throw error }
}
