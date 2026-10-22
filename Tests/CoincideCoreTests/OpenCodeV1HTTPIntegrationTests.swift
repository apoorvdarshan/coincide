import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Real private TCP, production factory/owned process/HTTP/SSE, SQLite and FIFO.
/// The executable is synthetic Python and never loads a vendor or invokes a model.
@Test(.timeLimit(.minutes(1)))
func openCodeV1HTTPIntegrationRunsCapturedFIFOAndDrainsTheExactOwnedParent() async throws {
    let fixture = try V1EngineHTTPFixture()
    let engine: WorkspaceEngine
    do { engine = try WorkspaceEngine(url: fixture.database, identityResolver: { _ in nil }) }
    catch { try? fixture.removeIfStopped(); throw error }
    do {
        _ = try await engine.load()
        let project = WorkspaceProject(path: fixture.workspace.path)
        let balanced = OpenCodeModelSelection(providerID: "synthetic", id: "wire-model/with-slash", variant: "balanced")
        var initial = CodingThread(project: project)
        initial.provider = .opencode
        initial.openCodeConfiguration = .init(generation: .v1, executable: fixture.executable.path, model: balanced, agentID: "build")
        initial.model = balanced.catalogID; initial.checkpointPolicy = .disabled
        let id = initial.id
        let row = ProviderModel(id: balanced.catalogID, name: "Synthetic native 1 model",
            openCodeSelection: .init(providerID: balanced.providerID, id: balanced.id), openCodeVariants: ["balanced", "fast"])
        try await engine.dispatch(.addProject(project))
        try await engine.dispatch(.createThread(initial))
        try await engine.dispatch(.submit(threadID: id, text: "wire-v1-first 工作 🌍"))
        try await v1HTTPEngineEventually("first owned user, assistant and tool") {
            let thread = await engine.current().snapshot.threads.first { $0.id == id }
            return fixture.exists("assistant-completed-1") && thread?.activeRun?.nativeTurnID != nil &&
                thread?.messages.contains { $0.role == .assistant && $0.text == " authoritative first 工作 🌍 " } == true &&
                thread?.messages.contains { $0.providerEntity?.fields["status"] == .string("completed") && $0.text.contains("Synthetic native 1 output 1") } == true
        }
        let firstSnapshot = await engine.current().snapshot
        let first = try #require(firstSnapshot.threads.first { $0.id == id })
        let firstRun = try #require(first.activeRun?.id)
        #expect(first.state == .running)
        #expect(first.providerThreadID == "ses_server_generated_native_1")
        #expect(first.messages.filter { $0.role == .assistant }.map(\.text) == [" authoritative first 工作 🌍 "])

        // Changes to the future header after acceptance must not affect either
        // the current run or this queued input's captured model/agent controls.
        try await engine.dispatch(.editThread(id, .openCodeVariant(model: row, variant: "fast")))
        try await engine.dispatch(.editThread(id, .openCodeAgent("plan")))
        try await engine.dispatch(.submit(threadID: id, text: "wire-v1-second FIFO"))
        try await engine.dispatch(.editThread(id, .openCodeVariant(model: row, variant: "balanced")))
        try await engine.dispatch(.editThread(id, .openCodeAgent("build")))
        let queuedSnapshot = await engine.current().snapshot
        let queued = try #require(queuedSnapshot.threads.first { $0.id == id })
        #expect(queued.activeRun?.id == firstRun)
        #expect(queued.queuedTurns.map(\.text) == ["wire-v1-second FIFO"])
        #expect(queued.queuedTurns.first?.configuration.openCodeConfiguration?.model?.variant == "fast")
        #expect(queued.queuedTurns.first?.configuration.openCodeConfiguration?.agentID == "plan")
        let beforeIdle = try fixture.rows("prompt")
        #expect(beforeIdle.count == 1)
        // Native user echo, assistant completion and HTTP204 have all happened;
        // the authoritative session idle is still withheld by this exact gate.
        try fixture.releaseFirst()
        try await v1HTTPEngineEventually("second captured native prompt") {
            let thread = await engine.current().snapshot.threads.first { $0.id == id }
            return (try? fixture.rows("prompt").count) == 2 && fixture.exists("assistant-completed-2") &&
                thread?.activeRun?.id != nil && thread?.activeRun?.id != firstRun &&
                thread?.messages.contains { $0.role == .assistant && $0.text == " authoritative second FIFO " } == true &&
                thread?.messages.contains { $0.text.contains("Synthetic native 1 output 2") } == true
        }
        let secondSnapshot = await engine.current().snapshot
        let second = try #require(secondSnapshot.threads.first { $0.id == id })
        #expect(second.state == .running && second.queuedTurns.isEmpty)
        #expect(second.activeRun?.configuration.openCodeConfiguration?.model?.variant == "fast")
        #expect(second.activeRun?.configuration.openCodeConfiguration?.agentID == "plan")
        #expect(second.openCodeConfiguration?.model?.variant == "balanced")
        #expect(second.openCodeConfiguration?.agentID == "build")
        let prompts = try fixture.rows("prompt")
        #expect(prompts.map { $0["text"].string } == ["wire-v1-first 工作 🌍", "wire-v1-second FIFO"])
        #expect(prompts.map { $0["variant"].string } == ["balanced", "fast"])
        #expect(prompts.map { $0["agent"].string } == ["build", "plan"])
        #expect(prompts.allSatisfy { $0["model"]["modelID"] == .string(balanced.id) && $0["model"]["providerID"] == .string("synthetic") && $0["streamWasReady"] == .bool(true) })
        #expect(Set(prompts.compactMap { $0["inputID"].string }).count == 2)
        #expect(Set(prompts.compactMap { $0["sessionID"].string }).count == 1)
        let secondRules = try #require(prompts.last?["permissions"].array)
        let planPath = fixture.workspace.appendingPathComponent("plan.md").path
        let outside = secondRules.last { ($0["permission"] == .string("edit") || $0["permission"] == .string("*")) && $0["pattern"] == .string("*") }?["action"]
        let inside = secondRules.last { ($0["permission"] == .string("edit") || $0["permission"] == .string("*")) && ($0["pattern"] == .string("*") || $0["pattern"] == .string(planPath)) }?["action"]
        #expect(outside == .string("deny"))
        #expect(inside == .string("allow"))
        let creates = try fixture.rows("create")
        #expect(creates.count == 1)
        #expect(creates.first?["serverGenerated"] == .bool(true) && creates.first?["noCallerID"] == .bool(true) && creates.first?["noTitle"] == .bool(true))

        // V1 Stop is the real native abort route, not a made-up v2 inbox delete.
        try await engine.dispatch(.interrupt(threadID: id))
        try await v1HTTPEngineEventually("native abort terminal") {
            let thread = await engine.current().snapshot.threads.first { $0.id == id }
            return thread?.state == .interrupted && thread?.activeRun == nil
        }
        let stoppedSnapshot = await engine.current().snapshot
        let stopped = try #require(stoppedSnapshot.threads.first { $0.id == id })
        #expect(stopped.queuePaused)
        #expect(stopped.messages.filter { $0.role == .user }.map(\.text) == ["wire-v1-first 工作 🌍", "wire-v1-second FIFO"])
        let history = try #require(stopped.runHistory)
        #expect(history.map(\.status) == [.completed, .interrupted])
        #expect(history.map { $0.configuration.openCodeConfiguration?.model?.variant } == ["balanced", "fast"])
        let activeAborts = try fixture.rows("abort").filter { $0["wasActive"] == .bool(true) }
        #expect(activeAborts.count == 1)
        #expect(activeAborts.first?["sessionID"] == .string("ses_server_generated_native_1"))

        async let closeOne: Void = engine.shutdown()
        async let closeTwo: Void = engine.shutdown()
        _ = await (closeOne, closeTwo)
        try await v1HTTPEngineEventually("exact owned parent exit") { fixture.stopped && fixture.exists("closed-owned-process") }
        let startup = try fixture.json("process.json"), closed = try fixture.json("closed-owned-process")
        #expect(startup["exactArguments"] == .bool(true) && startup["freshCredential"] == .bool(true) && startup["noInheritedService"] == .bool(true))
        #expect(startup["directoryAliasVerified"] == .bool(true))
        #expect(closed["streamClosed"] == .bool(true) && closed["httpStopped"] == .bool(true))
        let calls = try fixture.rows("request"), handlerFailures = try fixture.rows("fixture-handler-failed")
        #expect(calls.allSatisfy { $0["authenticated"] == .bool(true) && $0["directoryMatched"] == .bool(true) })
        #expect(calls.allSatisfy { $0["method"] != .string("DELETE") && $0["path"].string?.hasPrefix("/api/") != true })
        #expect(handlerFailures.isEmpty)
        let wire = try String(contentsOf: fixture.root.appendingPathComponent("wire.jsonl"), encoding: .utf8).lowercased()
        #expect(!wire.contains("authorization") && !wire.contains("password") && !wire.contains("http://"))
        let database = try WorkspaceDatabase(url: fixture.database)
        let replayed = try await database.rebuildProjection().snapshot
        let durable = try #require(replayed.threads.first { $0.id == id })
        #expect(durable.messages == stopped.messages && durable.runHistory == stopped.runHistory)
        #expect(durable.openCodeConfiguration == stopped.openCodeConfiguration)
        try fixture.removeIfStopped()
    } catch {
        await engine.shutdown()
        try? fixture.removeIfStopped()
        throw error
    }
}

private struct V1EngineHTTPFixture: Sendable {
    let root: URL
    let workspace: URL
    let database: URL
    let executable: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-opencode-v1-engine-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("checkout's 工作 & space", isDirectory: true)
        database = root.appendingPathComponent("workspace.sqlite")
        executable = root.appendingPathComponent("native-v1-http-peer")
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let sidecar = root.appendingPathComponent("fixture-directory.json")
            let value: JSONValue = .object(["directory": .string(workspace.standardizedFileURL.resolvingSymlinksInPath().path)])
            try JSONEncoder().encode(value).write(to: sidecar, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
            let source = try #require(Bundle.module.url(forResource: "opencode_v1_http_engine", withExtension: "py", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func json(_ name: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(name))) }
    func rows(_ kind: String) throws -> [JSONValue] {
        let data = try Data(contentsOf: root.appendingPathComponent("wire.jsonl"))
        guard let end = data.lastIndex(of: 10) else { return [] }
        return try data[...end].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }.filter { $0["kind"] == .string(kind) }
    }
    func releaseFirst() throws {
        let file = root.appendingPathComponent("release-first")
        try Data().write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    var stopped: Bool {
        guard let info = try? json("process.json"), case .number(let raw) = info["pid"], raw > 0, raw <= Double(Int32.max), raw.rounded(.towardZero) == raw else { return false }
        return Darwin.kill(Int32(raw), 0) == -1 && errno == ESRCH
    }
    func removeIfStopped() throws {
        guard !exists("process.json") || stopped else { throw CoincideError("The private native 1 fixture is still alive; its files were preserved.") }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

private func v1HTTPEngineEventually(_ boundary: String, _ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private native OpenCode 1 fixture did not reach \(boundary).") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
