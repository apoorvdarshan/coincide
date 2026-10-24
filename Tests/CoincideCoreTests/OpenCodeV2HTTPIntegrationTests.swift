import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Exercises an explicit historical adapter, owned child, HTTP/SSE implementation and
/// journal reducer together. The executable is a private synthetic TCP peer;
/// this test never invokes an installed OpenCode executable or a model.
@Test(.timeLimit(.minutes(1)))
func openCodeV2HTTPIntegrationRunsCapturedFIFOThroughEngineAndDrainsItsExactOwnedProcess() async throws {
    let fixture = try OpenCodeV2EngineHTTPFixture()
    let engine: WorkspaceEngine
    do {
        // The app factory rejects retired providers; inject the private native
        // adapter to retain wire, queue, and owned-process regression coverage.
        engine = try WorkspaceEngine(url: fixture.database, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
    } catch {
        try? fixture.removeFilesIfProcessStopped()
        throw error
    }
    do {
        let project = WorkspaceProject(path: fixture.workspace.path)
        var initial = CodingThread(project: project)
        let balanced = OpenCodeModelSelection(providerID: "synthetic", id: "wire-model", variant: "balanced")
        initial.provider = .opencode
        initial.openCodeConfiguration = .init(executable: fixture.executable.path, model: balanced, agentID: "build")
        initial.model = balanced.catalogID
        initial.checkpointPolicy = .disabled
        let threadID = initial.id
        let menuModel = ProviderModel(id: balanced.catalogID, name: "Synthetic TCP model",
            openCodeSelection: .init(providerID: "synthetic", id: "wire-model"), openCodeVariants: ["balanced", "fast"])
        try await saveLegacyProviderFixture(project: project, threads: [initial], at: fixture.database)
        _ = try await engine.load()
        try await engine.dispatch(.submit(threadID: threadID, text: "wire-first 工作 🌍"))

        try await openCodeV2EngineHTTPEventually("first native step and authoritative snapshots") {
            let current = await engine.current().snapshot.threads.first { $0.id == threadID }
            return fixture.hasMarker("step-ended-1") && current?.activeRun?.nativeTurnID != nil &&
                current?.messages.contains { $0.role == .assistant && $0.text == " authoritative first 工作 🌍 " } == true &&
                current?.messages.contains { $0.providerEntity?.fields["status"] == .string("completed") &&
                    $0.text.contains("Synthetic TCP output 1") } == true
        }
        let firstSnapshot = await engine.current().snapshot
        let first = try #require(firstSnapshot.threads.first { $0.id == threadID })
        let firstRun = try #require(first.activeRun?.id)
        #expect(first.state == .running)
        #expect(first.messages.filter { $0.role == .assistant }.map(\.text) == [" authoritative first 工作 🌍 "])
        #expect(!first.messages.contains { $0.text.contains("discarded incremental") })

        // Capture fast/plan for the queued input, then change the visible header
        // back to balanced/build. Neither edit may alter the first native turn.
        try await engine.dispatch(.editThread(threadID, .openCodeVariant(model: menuModel, variant: "fast")))
        try await engine.dispatch(.editThread(threadID, .openCodeAgent("plan")))
        try await engine.dispatch(.submit(threadID: threadID, text: "wire-second FIFO"))
        try await engine.dispatch(.editThread(threadID, .openCodeVariant(model: menuModel, variant: "balanced")))
        try await engine.dispatch(.editThread(threadID, .openCodeAgent("build")))
        let queuedSnapshot = await engine.current().snapshot
        let queued = try #require(queuedSnapshot.threads.first { $0.id == threadID })
        #expect(queued.activeRun?.id == firstRun && queued.state == .running)
        #expect(queued.queuedTurns.map(\.text) == ["wire-second FIFO"])
        #expect(queued.queuedTurns.first?.configuration.openCodeConfiguration?.model?.variant == "fast")
        #expect(queued.queuedTurns.first?.configuration.openCodeConfiguration?.agentID == "plan")
        #expect(queued.openCodeConfiguration?.model?.variant == "balanced")
        #expect(queued.openCodeConfiguration?.agentID == "build")
        #expect(try fixture.rows(kind: "prompt").count == 1)
        // The peer has acknowledged the first prompt and emitted step.ended,
        // yet its execution terminal is still held behind this exact file gate.
        try fixture.releaseFirst()

        try await openCodeV2EngineHTTPEventually("second captured FIFO input") {
            let current = await engine.current().snapshot.threads.first { $0.id == threadID }
            return (try? fixture.rows(kind: "prompt").count) == 2 && fixture.hasMarker("step-ended-2") &&
                current?.activeRun?.id != nil && current?.activeRun?.id != firstRun &&
                current?.messages.contains { $0.role == .assistant && $0.text == " authoritative second FIFO " } == true &&
                current?.messages.contains { $0.providerEntity?.fields["status"] == .string("completed") &&
                    $0.text.contains("Synthetic TCP output 2") } == true
        }
        let secondSnapshot = await engine.current().snapshot
        let runningSecond = try #require(secondSnapshot.threads.first { $0.id == threadID })
        let secondRun = try #require(runningSecond.activeRun)
        #expect(runningSecond.state == .running && runningSecond.queuedTurns.isEmpty)
        #expect(secondRun.configuration.openCodeConfiguration?.model?.variant == "fast")
        #expect(secondRun.configuration.openCodeConfiguration?.agentID == "plan")
        #expect(runningSecond.openCodeConfiguration?.model?.variant == "balanced")
        #expect(runningSecond.openCodeConfiguration?.agentID == "build")

        let prompts = try fixture.rows(kind: "prompt")
        #expect(prompts.map { $0["text"].string } == ["wire-first 工作 🌍", "wire-second FIFO"])
        #expect(prompts.map { $0["model"]["providerID"].string } == ["synthetic", "synthetic"])
        #expect(prompts.map { $0["model"]["id"].string } == ["wire-model", "wire-model"])
        #expect(prompts.map { $0["model"]["variant"].string } == ["balanced", "fast"])
        #expect(prompts.map { $0["agent"].string } == ["build", "plan"])
        #expect(prompts.allSatisfy { $0["delivery"] == .string("queue") && $0["resume"] == .bool(true) && $0["streamWasReady"] == .bool(true) })
        #expect(Set(prompts.compactMap { $0["inputID"].string }).count == 2)
        #expect(Set(prompts.compactMap { $0["sessionID"].string }).count == 1)
        #expect(prompts[1]["permissions"].array?.contains(.object(["action": .string("edit"), "resource": .string("*"), "effect": .string("deny")])) == true)
        #expect(prompts[1]["permissions"].array?.contains(.object(["action": .string("edit"), "resource": .string(fixture.workspace.appendingPathComponent("plan.md").path), "effect": .string("allow")])) == true)
        #expect(try fixture.rows(kind: "create").count == 1)

        // Stop crosses the real DELETE-inbox and POST-interrupt HTTP routes.
        // A delivered inbox cancellation is a no-op; only execution.interrupted
        // settles the second run and pauses the Engine queue.
        try await engine.dispatch(.interrupt(threadID: threadID))
        try await openCodeV2EngineHTTPEventually("owned execution interruption") {
            let current = await engine.current().snapshot.threads.first { $0.id == threadID }
            return current?.state == .interrupted && current?.activeRun == nil
        }
        let stoppedSnapshot = await engine.current().snapshot
        let stopped = try #require(stoppedSnapshot.threads.first { $0.id == threadID })
        #expect(stopped.queuePaused && stopped.queuedTurns.isEmpty)
        #expect(stopped.messages.filter { $0.role == .user }.map(\.text) == ["wire-first 工作 🌍", "wire-second FIFO"])
        #expect(stopped.messages.filter { $0.role == .assistant }.map(\.text) == [" authoritative first 工作 🌍 ", " authoritative second FIFO "])
        let records = try #require(stopped.runHistory)
        #expect(records.count == 2 && records[0].status == .completed && records[1].status == .interrupted)
        #expect(records.map { $0.configuration.openCodeConfiguration?.model?.variant } == ["balanced", "fast"])
        #expect(records.map { $0.configuration.openCodeConfiguration?.agentID } == ["build", "plan"])
        let cancelled = try fixture.rows(kind: "cancel-inbox")
        #expect(cancelled.count == 1 && cancelled[0]["inputID"] == prompts[1]["inputID"] && cancelled[0]["wasDelivered"] == .bool(true))
        #expect(try fixture.rows(kind: "interrupt").filter { $0["interrupted"] == .bool(true) }.count == 1)

        // Concurrent shutdown callers join the same native lifecycle. Stdin EOF,
        // stream closure and disappearance of the exact owned PID are separate
        // proof points; no process-name matching or global process control occurs.
        async let closeOne: Void = engine.shutdown()
        async let closeTwo: Void = engine.shutdown()
        _ = await (closeOne, closeTwo)
        try await openCodeV2EngineHTTPEventually("stdin EOF and owned process exit") { fixture.hasMarker("closed-after-eof") && fixture.processStopped }
        let closed = try fixture.json("closed-after-eof")
        #expect(closed["stdinEOF"] == .bool(true) && closed["streamClosed"] == .bool(true) && closed["httpStopped"] == .bool(true))
        let startup = try fixture.json("process.json")
        #expect(startup["exactArguments"] == .bool(true) && startup["freshCredential"] == .bool(true) && startup["noInheritedService"] == .bool(true))
        #expect(startup["directoryAliasVerified"] == .bool(true))
        #expect(try fixture.rows(kind: "request").allSatisfy { $0["authenticated"] == .bool(true) })
        #expect(try fixture.rows(kind: "catalog-location").allSatisfy { $0["matched"] == .bool(true) })
        #expect(try fixture.rows(kind: "fixture-handler-failed").isEmpty)
        let wire = try String(contentsOf: fixture.root.appendingPathComponent("wire.jsonl"), encoding: .utf8).lowercased()
        #expect(!wire.contains("authorization") && !wire.contains("password") && !wire.contains("http://"))
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.database.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let database = try WorkspaceDatabase(url: fixture.database)
        let replayed = try await database.rebuildProjection().snapshot
        let durable = try #require(replayed.threads.first { $0.id == threadID })
        #expect(durable.messages == stopped.messages && durable.runHistory == stopped.runHistory)
        #expect(durable.openCodeConfiguration == stopped.openCodeConfiguration)
        try fixture.removeFilesIfProcessStopped()
    } catch {
        let failedUpdate = await engine.current()
        await engine.shutdown()
        if let diagnostic = try? fixture.saveFailureDiagnostics(update: failedUpdate) {
            print("Synthetic native OpenCode Engine diagnostics: \(diagnostic.path)")
        }
        // Never remove a fixture whose exact recorded process remains alive.
        try? fixture.removeFilesIfProcessStopped()
        throw error
    }
}

@Test(.timeLimit(.minutes(1)))
func openCodeV2HTTPIntegrationSteeringHoldsTheOriginalEngineRunAcrossExecutionsBeforeCapturedFIFOStarts() async throws {
    let fixture = try OpenCodeV2EngineHTTPFixture(resource: "opencode_v2_steering_http")
    let engine: WorkspaceEngine
    do { engine = try WorkspaceEngine(url: fixture.database, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil }) }
    catch { try? fixture.removeFilesIfProcessStopped(); throw error }
    do {
        let project = WorkspaceProject(path: fixture.workspace.path)
        let balanced = OpenCodeModelSelection(providerID: "synthetic", id: "wire-model", variant: "balanced")
        let menuModel = ProviderModel(id: balanced.catalogID, name: "Synthetic TCP model",
            openCodeSelection: .init(providerID: "synthetic", id: "wire-model"), openCodeVariants: ["balanced", "fast"])
        var initial = CodingThread(project: project)
        initial.provider = .opencode; initial.model = balanced.catalogID; initial.checkpointPolicy = .disabled
        initial.openCodeConfiguration = .init(executable: fixture.executable.path, model: balanced, agentID: "build")
        let threadID = initial.id
        try await saveLegacyProviderFixture(project: project, threads: [initial], at: fixture.database)
        _ = try await engine.load()
        try await engine.dispatch(.submit(threadID: threadID, text: "steering-root 工作 🌍"))
        try await openCodeV2EngineHTTPEventually("the native foreground steering boundary") {
            let thread = await engine.current().snapshot.threads.first { $0.id == threadID }
            return fixture.hasMarker("step-ended-1") && thread?.activeRun?.nativeTurnID != nil &&
                thread?.messages.contains { $0.text == " authoritative first 工作 🌍 " } == true
        }
        let firstUpdate = await engine.current()
        let first = try #require(firstUpdate.snapshot.threads.first { $0.id == threadID })
        let firstRun = try #require(first.activeRun), firstTurn = try #require(firstRun.nativeTurnID)
        let availability = await engine.promptSteeringAvailability(threadID: threadID)
        #expect(availability.canSteer && availability.runID == firstRun.id)
        try await engine.dispatch(.editThread(threadID, .openCodeVariant(model: menuModel, variant: "fast")))
        try await engine.dispatch(.editThread(threadID, .openCodeAgent("plan")))
        try await engine.dispatch(.editThread(threadID, .permission(.fullAccess)))
        try await engine.dispatch(.submit(threadID: threadID, text: "steering-queued FIFO"))
        try await engine.steerPrompt(threadID: threadID, text: "steering-additional input", expectedRunID: firstRun.id)
        try await openCodeV2EngineHTTPEventually("the real native steering admission") {
            let update = await engine.current()
            return update.snapshot.promptSteerings?.last?.phase == .delivered && (try? fixture.rows(kind: "prompt").count) == 2
        }
        try fixture.releaseFirst()
        try await openCodeV2EngineHTTPEventually("delivered steering after the first execution end") {
            let current = await engine.current().snapshot.threads.first { $0.id == threadID }
            return fixture.hasMarker("steer-delivered") && current?.messages.contains { $0.text == " authoritative held steering boundary " } == true
        }
        let heldUpdate = await engine.current()
        let held = try #require(heldUpdate.snapshot.threads.first { $0.id == threadID })
        #expect(held.activeRun?.id == firstRun.id && held.activeRun?.nativeTurnID == firstTurn)
        #expect(held.queuedTurns.map(\.text) == ["steering-queued FIFO"])
        #expect(held.runHistory?.first?.status == .running)
        #expect(try fixture.rows(kind: "prompt").count == 2,
            "Neither HTTP steering acknowledgement nor an ended predecessor execution may start the FIFO successor.")
        #expect(held.activeRun?.configuration.permission == .supervised && held.permission == .fullAccess)
        try fixture.release("release-steered-execution")
        try await openCodeV2EngineHTTPEventually("the completed steering execution and captured FIFO successor") {
            let current = await engine.current().snapshot.threads.first { $0.id == threadID }
            return fixture.hasMarker("step-ended-2") && (try? fixture.rows(kind: "prompt").count) == 3 &&
                current?.activeRun?.id != nil && current?.activeRun?.id != firstRun.id &&
                current?.messages.contains { $0.text == " authoritative steered 工作 🌍 " } == true
        }
        let runningUpdate = await engine.current()
        let running = try #require(runningUpdate.snapshot.threads.first { $0.id == threadID })
        let steeredText = try #require(running.messages.first { $0.text == " authoritative steered 工作 🌍 " })
        #expect(steeredText.runReference?.runID == firstRun.id)
        #expect(running.activeRun?.configuration.openCodeConfiguration?.agentID == "plan")
        #expect(running.activeRun?.configuration.openCodeConfiguration?.model?.variant == "fast")
        #expect(running.activeRun?.configuration.permission == .fullAccess && running.queuedTurns.isEmpty)
        let prompts = try fixture.rows(kind: "prompt")
        #expect(prompts.map { $0["delivery"].string } == ["queue", "steer", "queue"])
        #expect(prompts.map { $0["model"]["variant"].string } == ["balanced", "balanced", "fast"])
        #expect(prompts.map { $0["agent"].string } == ["build", "build", "plan"])
        #expect(prompts[0]["permissions"] == prompts[1]["permissions"])
        #expect(Set(prompts.compactMap { $0["inputID"].string }).count == 3)
        let requests = try fixture.rows(kind: "request")
        #expect(requests.filter { $0["method"] == .string("POST") && $0["path"].string?.hasSuffix("/model") == true }.count == 2)
        #expect(requests.filter { $0["method"] == .string("POST") && $0["path"].string?.hasSuffix("/agent") == true }.count == 2)
        let steering = try #require(runningUpdate.snapshot.promptSteerings?.last)
        #expect(steering.phase == .delivered && steering.receipt?.turnID == firstTurn)
        #expect(steering.configuration == firstRun.configuration)
        try await engine.dispatch(.interrupt(threadID: threadID))
        try await openCodeV2EngineHTTPEventually("the FIFO successor Stop") {
            let current = await engine.current().snapshot.threads.first { $0.id == threadID }
            return current?.activeRun == nil && current?.state == .interrupted
        }
        let finalUpdate = await engine.current()
        let final = try #require(finalUpdate.snapshot.threads.first { $0.id == threadID })
        #expect(final.runHistory?.map(\.status) == [.completed, .interrupted])
        #expect(final.runHistory?.first?.turnIDs == [firstTurn])
        #expect(final.queuePaused && finalUpdate.error == nil)
        await engine.shutdown()
        try await openCodeV2EngineHTTPEventually("the steering peer EOF and exact owned PID drain") {
            fixture.hasMarker("closed-after-eof") && fixture.processStopped
        }
        let closed = try fixture.json("closed-after-eof"), startup = try fixture.json("process.json")
        #expect(closed["stdinEOF"] == .bool(true) && closed["streamClosed"] == .bool(true))
        #expect(startup["exactArguments"] == .bool(true) && startup["freshCredential"] == .bool(true))
        #expect(requests.allSatisfy { $0["authenticated"] == .bool(true) })
        #expect(try fixture.rows(kind: "fixture-handler-failed").isEmpty)
        let wire = try String(contentsOf: fixture.root.appendingPathComponent("wire.jsonl"), encoding: .utf8).lowercased()
        #expect(!wire.contains("authorization") && !wire.contains("password") && !wire.contains("http://"))
        let rebuilt = try await WorkspaceDatabase(url: fixture.database).rebuildProjection().snapshot
        let restored = try #require(rebuilt.threads.first { $0.id == threadID })
        #expect(restored.messages == final.messages && restored.runHistory == final.runHistory)
        try fixture.removeFilesIfProcessStopped()
    } catch {
        let update = await engine.current(); await engine.shutdown()
        if let diagnostics = try? fixture.saveFailureDiagnostics(update: update) { print("Synthetic OpenCode steering diagnostics: \(diagnostics.path)") }
        try? fixture.removeFilesIfProcessStopped(); throw error
    }
}

private struct OpenCodeV2EngineHTTPFixture: Sendable {
    let root: URL
    let workspace: URL
    let database: URL
    let executable: URL

    init(resource: String = "opencode_v2_http_engine") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-opencode-v2-engine-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("checkout's 工作 & space", isDirectory: true)
        database = root.appendingPathComponent("workspace.sqlite")
        executable = root.appendingPathComponent("native-http-peer")
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            // Preserve exactly the path spelling used by the production Swift
            // adapter. Python's filesystem resolution rewrites Darwin /var to
            // /private/var; the peer separately proves both name its own cwd.
            let directoryFile = root.appendingPathComponent("fixture-directory.json")
            let directory: JSONValue = .object(["directory": .string(workspace.standardizedFileURL.resolvingSymlinksInPath().path)])
            try JSONEncoder().encode(directory).write(to: directoryFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directoryFile.path)
            let source = try #require(Bundle.module.url(forResource: resource, withExtension: "py", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func hasMarker(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func json(_ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    func rows(kind: String) throws -> [JSONValue] {
        let data = try Data(contentsOf: root.appendingPathComponent("wire.jsonl"))
        // An append in progress is not a malformed protocol response. Consume
        // only complete JSONL records; the next observation reads its newline.
        guard let newline = data.lastIndex(of: 10) else { return [] }
        return try data[...newline].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
            .filter { $0["kind"] == .string(kind) }
    }
    func releaseFirst() throws {
        try release("release-first")
    }
    func release(_ name: String) throws {
        let path = root.appendingPathComponent(name)
        try Data().write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    var processStopped: Bool {
        guard let value = try? json("process.json"), case .number(let raw) = value["pid"], raw > 0, raw < Double(Int32.max) else { return false }
        return Darwin.kill(Int32(raw), 0) == -1 && errno == ESRCH
    }
    func removeFilesIfProcessStopped() throws {
        guard !hasMarker("process.json") || processStopped else {
            throw CoincideError("The private native HTTP fixture is still alive; its scratch files were preserved.")
        }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    /// Preserve bounded synthetic evidence outside the disposable live fixture.
    /// Never copies SQLite, process environment, HTTP headers or credentials.
    func saveFailureDiagnostics(update: WorkspaceUpdate) throws -> URL {
        let destination = root.deletingLastPathComponent().appendingPathComponent("coincide-opencode-v2-engine-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let threads: [JSONValue] = update.snapshot.threads.prefix(2).map { thread in
            .object([
                "state": .string(thread.state.rawValue), "activeRun": .bool(thread.activeRun != nil),
                "nativeTurnID": thread.activeRun?.nativeTurnID.map(JSONValue.string) ?? .null,
                "runtimeOpen": .bool(thread.runtimeID != nil), "nativeSessionKnown": .bool(thread.providerThreadID != nil),
                "queuePaused": .bool(thread.queuePaused), "queuedInputs": .number(Double(thread.queuedTurns.count)),
                "messages": .array(thread.messages.suffix(12).map { message in
                    .object(["role": .string(message.role.rawValue), "text": .string(Self.safeDiagnosticNotice(message.text)),
                             "entityType": message.providerEntity.map { .string($0.key.type) } ?? .null,
                             "entityStatus": message.providerEntity?.fields["status"] ?? .null])
                })
            ])
        }
        let value: JSONValue = .object(["sequence": .number(Double(update.sequence)),
            "error": update.error.map { .string(Self.safeDiagnosticNotice($0)) } ?? .null,
            "threads": .array(threads), "processStoppedAfterShutdown": .bool(processStopped)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let engineFile = destination.appendingPathComponent("engine.json")
        try encoder.encode(value).write(to: engineFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: engineFile.path)
        for name in ["process.json", "wire.jsonl", "step-ended-1", "step-ended-2", "closed-after-eof"] where hasMarker(name) {
            let handle = try FileHandle(forReadingFrom: root.appendingPathComponent(name))
            let bytes: Data
            do { bytes = try handle.read(upToCount: 131_072) ?? Data(); try handle.close() }
            catch { try? handle.close(); throw error }
            let target = destination.appendingPathComponent(name)
            try bytes.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        return destination
    }

    private static func safeDiagnosticNotice(_ text: String) -> String {
        let value = String(text.prefix(2_048))
        let lower = value.lowercased()
        guard !["authorization", "bearer ", "password", "token=", "http://", "https://", "sk-"].contains(where: lower.contains) else {
            return "<redacted diagnostic notice>"
        }
        return value
    }
}

private func openCodeV2EngineHTTPEventually(_ boundary: String, _ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else {
            throw CoincideError("The private native OpenCode Engine fixture did not reach \(boundary).")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
