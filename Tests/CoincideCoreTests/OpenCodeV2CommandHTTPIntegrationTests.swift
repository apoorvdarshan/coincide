import Darwin
import Foundation
import Testing
@testable import CoincideCore

private let commandTCPInput = "/inspect literal 工作 $native-review-id\nsecond line"
private let commandTCPSuccessor = "queued normal $native-review-id 工作"

/// Real loopback HTTP/SSE, default provider factory and SQLite reducer. The
/// executable is this test's private synthetic peer, never an installed agent.
@Test(.timeLimit(.minutes(1)), arguments: ["success", "terminal-before-ack"])
func openCodeV2CommandHTTPIntegrationBindsOnlyTheObservedNativeRootBeforeCapturedFIFOAndNeverFallsBackToPrompt(mode: String) async throws {
    let fixture = try CommandTCPFixture(mode: mode)
    let engine = try WorkspaceEngine(url: fixture.database, identityResolver: { _ in nil })
    do {
        let thread = try await fixture.register(in: engine)
        _ = try await engine.dispatch(.submit(threadID: thread.id, text: commandTCPInput))
        try await commandTCPEventually("held native command POST") { fixture.has("command-posted") }
        let initial = try #require((await engine.current()).snapshot.threads.first { $0.id == thread.id })
        let originalRunID = try #require(initial.activeRun?.id)
        #expect(initial.activeRun?.nativeTurnID == nil && initial.runHistory?.first?.turnIDs.isEmpty == true)
        try await fixture.enqueueSuccessor(in: engine, threadID: thread.id)
        if mode == "success" {
            try fixture.release("release-command-response")
            try await commandTCPEventually("HTTP204 without root input") { fixture.has("command-acknowledged") }
            let acknowledged = try #require((await engine.current()).snapshot.threads.first { $0.id == thread.id })
            #expect(acknowledged.activeRun?.id == originalRunID && acknowledged.activeRun?.nativeTurnID == nil)
            #expect(acknowledged.queuedTurns.map(\.text) == [commandTCPSuccessor])
            #expect(try fixture.rows("prompt").isEmpty, "HTTP204 alone cannot admit a fabricated input or start the queue.")
        }
        try fixture.release("release-command-inbox")
        try await commandTCPEventually("actual native command root and ended step") {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return fixture.has("step-ended-1") && current?.activeRun?.nativeTurnID == "msg_native_command_root" &&
                current?.messages.contains { $0.role == .assistant && $0.text == " authoritative first 工作 🌍 " } == true
        }
        let held = try #require((await engine.current()).snapshot.threads.first { $0.id == thread.id })
        #expect(held.activeRun?.id == originalRunID && held.queuedTurns.map(\.text) == [commandTCPSuccessor])
        #expect(held.activeRun?.configuration.openCodeConfiguration?.model?.variant == "balanced")
        #expect(held.activeRun?.configuration.openCodeConfiguration?.agentID == "build")
        #expect(held.openCodeConfiguration?.model?.variant == "balanced" && held.openCodeConfiguration?.agentID == "build")
        #expect(held.runHistory?.first?.turnIDs == ["msg_native_command_root"])
        #expect(held.runHistory?.first?.userMessageID != "msg_native_command_root")
        #expect(try fixture.rows("prompt").isEmpty, "An ended step cannot complete the native execution.")
        try fixture.release("release-first")
        if mode == "terminal-before-ack" {
            // A late tool snapshot follows the native terminal on the same SSE
            // stream. Its durable projection proves the terminal was consumed
            // while the command callback is still held, without a timing sleep.
            try await commandTCPEventually("native terminal projected before callback acknowledgement") {
                let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
                return current?.messages.contains { $0.providerEntity?.fields["status"] == .string("completed") &&
                    $0.text.contains("Native terminal before callback acknowledgement") } == true
            }
            let awaitingCallback = try #require((await engine.current()).snapshot.threads.first { $0.id == thread.id })
            let promptsBeforeAcknowledgement = try fixture.rows("prompt")
            #expect(awaitingCallback.activeRun?.id == originalRunID && awaitingCallback.queuedTurns.map(\.text) == [commandTCPSuccessor])
            #expect(awaitingCallback.runHistory?.first?.status != .completed)
            #expect(!fixture.has("command-acknowledged") && promptsBeforeAcknowledgement.isEmpty,
                "Native terminal alone cannot release a queued successor before the command callback and root inventory proof.")
            try fixture.release("release-command-response")
        }
        try await commandTCPEventually("captured normal successor completion") {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return current?.activeRun == nil && current?.runHistory?.count == 2 && current?.runHistory?.allSatisfy { $0.status == .completed } == true
        }
        let complete = try #require((await engine.current()).snapshot.threads.first { $0.id == thread.id })
        #expect(complete.queuedTurns.isEmpty && complete.messages.filter { $0.role == .user }.map(\.text) == [commandTCPInput, commandTCPSuccessor])
        #expect(complete.runHistory?.map { $0.configuration.openCodeConfiguration?.model?.variant } == ["balanced", "fast"])
        #expect(complete.runHistory?.map { $0.configuration.openCodeConfiguration?.agentID } == ["build", "plan"])
        #expect(complete.runHistory?.first?.turnIDs == ["msg_native_command_root"])
        let command = try #require(fixture.rows("command").first)
        #expect(try fixture.rows("command").count == 1)
        #expect(command["body"] == .object(["name": .string("inspect"), "text": .string("literal 工作 $native-review-id\nsecond line"),
                                           "delivery": .string("queue"), "skills": .array([.object(["id": .string("native-review-id")])])]))
        #expect(command["model"]["variant"] == .string("balanced") && command["agent"] == .string("build"))
        let prompt = try #require(fixture.rows("prompt").first)
        #expect(try fixture.rows("prompt").count == 1 && prompt["text"] == .string(commandTCPSuccessor))
        #expect(prompt["skills"] == .array([.object(["id": .string("native-review-id")])]))
        #expect(prompt["model"]["variant"] == .string("fast") && prompt["agent"] == .string("plan"))
        #expect(prompt["resume"] == .bool(true) && prompt["inputID"] != .string("msg_native_command_root"))
        #expect(try fixture.rows("command-history-before").count == 1)
        #expect(try fixture.rows("command-history-after").count == 1)
        #expect(try fixture.rows("command-inbox-after").count == 1)
        #expect(try fixture.rows("create").count == 1)
        await engine.shutdown()
        try await commandTCPEventually("owned native process exit") { fixture.processStopped && fixture.has("closed-after-eof") }
        let replay = try await WorkspaceDatabase(url: fixture.database).rebuildProjection().snapshot
        let saved = try #require(replay.threads.first { $0.id == thread.id })
        #expect(saved.messages == complete.messages && saved.runHistory == complete.runHistory && saved.queuedTurns.isEmpty)
        #expect(try fixture.rows("request").allSatisfy { $0["authenticated"] == .bool(true) })
        #expect(try fixture.rows("fixture-handler-failed").isEmpty)
        try fixture.remove()
    } catch { await fixture.failure(engine: engine); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["ambiguous-root", "dropped-no-root"])
func openCodeV2CommandHTTPIntegrationUnownedOrLostRootHoldsFIFOAcrossRestartWithoutRetryOrPromptFallback(mode: String) async throws {
    let fixture = try CommandTCPFixture(mode: mode)
    let engine = try WorkspaceEngine(url: fixture.database, identityResolver: { _ in nil })
    do {
        let thread = try await fixture.register(in: engine)
        _ = try await engine.dispatch(.submit(threadID: thread.id, text: commandTCPInput))
        try await commandTCPEventually("held command before queue admission") { fixture.has("command-posted") }
        try await fixture.enqueueSuccessor(in: engine, threadID: thread.id)
        try fixture.release("release-command-response"); try fixture.release("release-command-inbox")
        try await commandTCPEventually("uncertain command ownership closes exact runtime") {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return current?.activeRun == nil && current?.queuePaused == true && current?.runHistory?.first?.endReason == .connectionLost
        }
        let stopped = try #require((await engine.current()).snapshot.threads.first { $0.id == thread.id })
        #expect(stopped.runHistory?.count == 1 && stopped.runHistory?.first?.status == .failed)
        #expect(stopped.queuedTurns.map(\.text) == [commandTCPSuccessor])
        #expect(stopped.queuedTurns.first?.configuration.openCodeConfiguration?.model?.variant == "fast")
        #expect(stopped.queuedTurns.first?.configuration.openCodeConfiguration?.agentID == "plan")
        #expect(stopped.messages.filter { $0.role == .user }.map(\.text) == [commandTCPInput])
        #expect(!stopped.messages.contains { $0.role == .assistant })
        let commandsBeforeRestart = try fixture.rows("command"), promptsBeforeRestart = try fixture.rows("prompt")
        #expect(commandsBeforeRestart.count == 1 && promptsBeforeRestart.isEmpty)
        if mode == "dropped-no-root" { #expect(stopped.runHistory?.first?.turnIDs.isEmpty == true) }
        await engine.shutdown()
        try await commandTCPEventually("uncertain native process drain") { fixture.processStopped }
        let reopened = try WorkspaceEngine(url: fixture.database, identityResolver: { _ in nil })
        do {
            let loaded = try await reopened.load()
            let durable = try #require(loaded.threads.first { $0.id == thread.id })
            #expect(durable.queuedTurns == stopped.queuedTurns && durable.queuePaused && durable.activeRun == nil)
            #expect(durable.runHistory == stopped.runHistory)
            let commandsAfterRestart = try fixture.rows("command"), promptsAfterRestart = try fixture.rows("prompt")
            #expect(commandsAfterRestart.count == 1 && promptsAfterRestart.isEmpty)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
        #expect(try fixture.rows("fixture-handler-failed").isEmpty)
        try fixture.remove()
    } catch { await fixture.failure(engine: engine); throw error }
}

private struct CommandTCPFixture: Sendable {
    let root: URL, workspace: URL, database: URL, executable: URL
    init(mode: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-opencode-command-http-" + UUID().uuidString).resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("checkout's 工作 & space"); database = root.appendingPathComponent("workspace.sqlite")
        executable = root.appendingPathComponent("native-command-peer")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        for (name, value) in [
            ("fixture-directory.json", JSONValue.object(["directory": .string(workspace.standardizedFileURL.resolvingSymlinksInPath().path)])),
            ("fixture-mode.json", .object(["mode": .string(mode)]))] {
            try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(name).path)
        }
        let source = try #require(Bundle.module.url(forResource: "opencode_v2_commands_http", withExtension: "py", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func register(in engine: WorkspaceEngine) async throws -> CodingThread {
        _ = try await engine.load()
        let project = WorkspaceProject(path: workspace.path)
        let model = OpenCodeModelSelection(providerID: "synthetic", id: "wire-model", variant: "balanced")
        var thread = CodingThread(project: project)
        thread.provider = .opencode; thread.model = model.catalogID; thread.checkpointPolicy = .disabled
        thread.openCodeConfiguration = .init(executable: executable.path, model: model, agentID: "build")
        _ = try await engine.dispatch(.addProject(project)); _ = try await engine.dispatch(.createThread(thread))
        return thread
    }
    func enqueueSuccessor(in engine: WorkspaceEngine, threadID: UUID) async throws {
        let model = OpenCodeModelSelection(providerID: "synthetic", id: "wire-model")
        let row = ProviderModel(id: model.catalogID, name: "Synthetic model", openCodeSelection: model, openCodeVariants: ["balanced", "fast"])
        _ = try await engine.dispatch(.editThread(threadID, .openCodeVariant(model: row, variant: "fast")))
        _ = try await engine.dispatch(.editThread(threadID, .openCodeAgent("plan")))
        _ = try await engine.dispatch(.submit(threadID: threadID, text: commandTCPSuccessor))
        _ = try await engine.dispatch(.editThread(threadID, .openCodeVariant(model: row, variant: "balanced")))
        _ = try await engine.dispatch(.editThread(threadID, .openCodeAgent("build")))
    }
    func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func rows(_ kind: String) throws -> [JSONValue] {
        guard has("wire.jsonl") else { return [] }
        let data = try Data(contentsOf: root.appendingPathComponent("wire.jsonl"))
        guard let end = data.lastIndex(of: 10) else { return [] }
        return try data[...end].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }.filter { $0["kind"] == .string(kind) }
    }
    func release(_ name: String) throws {
        try Data().write(to: root.appendingPathComponent(name), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(name).path)
    }
    var processStopped: Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("process.json")),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .number(let raw) = value["pid"], raw > 0, raw < Double(Int32.max) else { return false }
        return Darwin.kill(Int32(raw), 0) == -1 && errno == ESRCH
    }
    func remove() throws {
        guard !has("process.json") || processStopped else { throw CoincideError("The owned native command peer has not exited; its fixture was preserved.") }
        try FileManager.default.removeItem(at: root)
    }
    func failure(engine: WorkspaceEngine) async {
        await engine.shutdown()
        let target = root.deletingLastPathComponent().appendingPathComponent("coincide-command-http-failure-" + UUID().uuidString)
        if (try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil {
            for name in ["wire.jsonl", "process.json", "command-posted", "command-acknowledged", "closed-after-eof"] where has(name) {
                if let handle = try? FileHandle(forReadingFrom: root.appendingPathComponent(name)) {
                    let data = try? handle.read(upToCount: 131_072); try? handle.close()
                    if let data { try? data.write(to: target.appendingPathComponent(name)); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.appendingPathComponent(name).path) }
                }
            }
            print("Private synthetic command HTTP evidence: \(target.path)")
        }
        try? remove()
    }
}
private func commandTCPEventually(_ boundary: String, _ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private command HTTP fixture did not reach \(boundary).") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
