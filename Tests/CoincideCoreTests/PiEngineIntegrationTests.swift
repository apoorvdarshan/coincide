import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Historical Pi adapter with an explicitly injected private process, real stdio and
/// SQLite/FIFO. This peer never imports Pi or makes a vendor/model request.
@Test(.timeLimit(.minutes(1)))
func piEngineNativeRPCUsesCapturedFIFOReopensForPolicyAndPreservesDurableProjection() async throws {
    let fixture = try PiEngineFixture()
    let engine = try WorkspaceEngine(url: fixture.database, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
    do {
        let project = WorkspaceProject(path: fixture.root.path)
        var thread = CodingThread(project: project)
        let configuration = PiConfiguration(executable: fixture.executable.path)
        thread.provider = .pi; thread.piConfiguration = configuration
        thread.checkpointPolicy = .disabled; thread.permission = .supervised
        try await saveLegacyProviderFixture(project: project, threads: [thread], at: fixture.database)
        _ = try await engine.load()
        try await engine.dispatch(.submit(threadID: thread.id, text: "First exact 工作 input"))
        try await piEngineEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return current?.providerThreadID?.hasSuffix("native-session.jsonl") == true && current?.messages.contains { $0.role == .assistant && $0.text.contains("日本語") } == true
        }
        let firstState = await engine.current().snapshot
        let first = try #require(firstState.threads.first { $0.id == thread.id }), firstRun = try #require(first.activeRun?.id)
        #expect(first.activeRun?.nativeTurnID == nil) // Pi exposes no strong turn ID.
        let selected = PiModelSelection(provider: "other", modelID: "model/with/slash")
        let row = ProviderModel(id: selected.catalogID, name: "Selected native Pi model", piSelection: selected, piThinkingLevels: ["low", "medium", "high"])
        try await engine.dispatch(.editThread(thread.id, .piModel(row)))
        try await engine.dispatch(.editThread(thread.id, .piThinking(model: row, level: "high")))
        try await engine.dispatch(.editThread(thread.id, .permission(.fullAccess)))
        try await engine.dispatch(.submit(threadID: thread.id, text: "Second captured FIFO"))
        try await engine.dispatch(.editThread(thread.id, .piThinking(model: row, level: "low")))
        try await engine.dispatch(.editThread(thread.id, .permission(.supervised)))
        try await fixture.signal("endOnly")
        try await piEngineEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return current?.messages.contains { $0.role == .assistant && $0.text == "日本語\u{2028}exact done" } == true
        }
        let held = await engine.current().snapshot.threads.first { $0.id == thread.id }
        #expect(held?.activeRun?.id == firstRun && held?.queuedTurns.map(\.text) == ["Second captured FIFO"])
        let before = try fixture.frames(); #expect(before.filter { $0["type"].string == "prompt" }.count == 1)
        try await fixture.signal("finish")
        try await piEngineEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return (try? fixture.frames().filter { $0["type"].string == "prompt" }.count) == 2 &&
                current?.activeRun?.id != nil && current?.activeRun?.id != firstRun && current?.queuedTurns.isEmpty == true &&
                current?.messages.filter { $0.role == .assistant }.count == 2
        }
        let currentState = await engine.current().snapshot
        let current = try #require(currentState.threads.first { $0.id == thread.id })
        #expect(current.activeRun?.configuration.piConfiguration?.model == selected)
        #expect(current.activeRun?.configuration.piConfiguration?.thinkingLevel == "high")
        #expect(current.activeRun?.configuration.permission == .fullAccess)
        #expect(current.permission == .supervised && current.piConfiguration?.thinkingLevel == "low")
        let processes = try fixture.processes(), frames = try fixture.frames()
        #expect(processes.map { $0["policy"].string } == ["supervised", "fullAccess"])
        #expect(frames.filter { $0["type"].string == "prompt" }.map { $0["message"].string } == ["First exact 工作 input", "Second captured FIFO"])
        #expect(frames.last { $0["type"].string == "set_model" }?["provider"].string == "other")
        #expect(frames.last { $0["type"].string == "set_thinking_level" }?["level"].string == "high")
        #expect(frames.contains { $0["type"].string == "switch_session" && $0["sessionPath"].string == first.providerThreadID })
        #expect(frames.allSatisfy { $0["method"] == .null && $0["jsonrpc"] == .null })

        // Core addresses Pi Stop by exact app run/runtime ownership rather
        // than fabricating a native turn token. Native abort+idle is real.
        try await engine.dispatch(.interrupt(threadID: thread.id))
        try await piEngineEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return current?.activeRun == nil && current?.state == .interrupted
        }
        let stoppedFrames = try fixture.frames()
        #expect(stoppedFrames.filter { $0["type"].string == "abort" }.count == 1)
        #expect(stoppedFrames.contains { $0["type"].string == "clear_queue" } || stoppedFrames.last?["type"].string == "get_state")
        await engine.shutdown()
        try await piEngineEventually { fixture.allParentsStopped }
        let finalSnapshot = await engine.current().snapshot
        let final = try #require(finalSnapshot.threads.first { $0.id == thread.id })
        #expect(final.queuePaused && final.queuedTurns.isEmpty)
        #expect(final.messages.filter { $0.role == .user }.map(\.text) == ["First exact 工作 input", "Second captured FIFO"])
        #expect(final.runHistory?.map(\.status) == [.completed, .interrupted])
        #expect(final.runHistory?.map { $0.configuration.permission } == [.supervised, .fullAccess])
        #expect(try Data(contentsOf: fixture.sentinel) == Data("Preserved source bytes\n".utf8))
        let database = try WorkspaceDatabase(url: fixture.database), rebuilt = try await database.rebuildProjection().snapshot
        let durable = try #require(rebuilt.threads.first { $0.id == thread.id })
        #expect(durable.messages == final.messages && durable.runHistory == final.runHistory && durable.piConfiguration == final.piConfiguration)
        let reopened = try WorkspaceEngine(url: fixture.database, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
        _ = try await reopened.load(); await reopened.shutdown()
        let afterReopen = try fixture.frames(); #expect(afterReopen.filter { $0["type"].string == "prompt" }.count == 2)
        #expect(fixture.allParentsStopped)
        try fixture.removeIfStopped()
    } catch { await engine.shutdown(); try? fixture.removeIfStopped(); throw error }
}

private struct PiEngineFixture: Sendable {
    let root: URL
    let database: URL
    let executable: URL
    let sentinel: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-engine-\(UUID())", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        database = root.appendingPathComponent("workspace.sqlite"); executable = root.appendingPathComponent("native-pi-peer"); sentinel = root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let source = try #require(Bundle.module.url(forResource: "pi_rpc_server", withExtension: "py", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try Data("{}".utf8).write(to: root.appendingPathComponent("options.json"), options: .atomic)
            try Data("Preserved source bytes\n".utf8).write(to: sentinel)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func frames() throws -> [JSONValue] { try records("wire.jsonl") }
    func processes() throws -> [JSONValue] { try records("processes.jsonl") }
    private func records(_ name: String) throws -> [JSONValue] {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let bytes = try Data(contentsOf: url)
        guard let newline = bytes.lastIndex(of: 10) else { return [] }
        return try bytes[...newline].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func signal(_ name: String) async throws {
        let process = try #require(processes().last)
        let value: JSONValue = .object(["signal": .object(["id": .string(UUID().uuidString), "name": .string(name), "pid": process["pid"]])])
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent("options.json"), options: .atomic)
    }
    var allParentsStopped: Bool {
        guard let rows = try? processes(), !rows.isEmpty else { return false }
        return rows.allSatisfy {
            guard case .number(let value) = $0["pid"], let pid = Int32(exactly: value), pid > 0 else { return false }
            return Darwin.kill(pid, 0) == -1 && errno == ESRCH
        }
    }
    func removeIfStopped() throws {
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("processes.jsonl").path) || allParentsStopped else { throw CoincideError("The task-owned Pi peer is still alive; its fixture was preserved.") }
        try FileManager.default.removeItem(at: root)
    }
}

private func piEngineEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native Pi Engine fixture did not reach the expected boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
