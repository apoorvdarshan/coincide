import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor PiSteeringObserved {
    var completed: [(UUID?, ThreadState)] = []
    var failures: [String] = []
    var sessionFiles: [String] = []
    var nativeTurns: [String] = []
    var requests: [ApprovalRequest] = []
    var notices: [String] = []
    var owners = Set<UUID>()
    func append(_ event: ProviderEvent, owner: UUID? = nil) {
        switch event {
        case .context(let id, let inner): append(inner, owner: id)
        case .thread(let id): sessionFiles.append(id)
        case .turn(let id): nativeTurns.append(id)
        case .completed(let state): completed.append((owner, state))
        case .failure(let text), .connectionClosed(let text): failures.append(text)
        case .sessionApproval(let request): requests.append(request)
        case .message(let row): notices.append(row.text)
        case .entity: if let owner { owners.insert(owner) }
        default: break
        }
    }
}

private struct PiSteeringFixture: Sendable {
    let root: URL
    let executable: URL
    let configuration: PiConfiguration
    init(options: [String: JSONValue] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-steering-\(UUID())", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        executable = root.appendingPathComponent("pi-native-peer")
        configuration = .init(executable: executable.path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let source = try #require(Bundle.module.url(forResource: "pi_steering", withExtension: "py", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try JSONEncoder().encode(JSONValue.object(options)).write(to: root.appendingPathComponent("options.json"))
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func thread(model: PiModelSelection? = nil, thinking: String? = nil) -> CodingThread {
        var thread = CodingThread(project: .init(path: root.path))
        thread.provider = .pi; thread.permission = .supervised; thread.checkpointPolicy = .disabled
        thread.piConfiguration = .init(instanceID: configuration.instanceID, executable: executable.path, model: model, thinkingLevel: thinking)
        thread.model = model?.catalogID ?? ""
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
        return thread
    }
    func rows(_ name: String = "wire.jsonl") throws -> [JSONValue] {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let bytes = try Data(contentsOf: url)
        guard let newline = bytes.lastIndex(of: 10) else { return [] }
        return try bytes[...newline].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func set(_ key: String, _ value: JSONValue) throws {
        let url = root.appendingPathComponent("options.json")
        var fields = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).object ?? [:]
        fields[key] = value; try JSONEncoder().encode(JSONValue.object(fields)).write(to: url, options: .atomic)
    }
    func finish() throws {
        let parents = try rows("parents.jsonl")
        let pid = try #require(parents.last?["pid"])
        try set("signal", .object(["id": .string(UUID().uuidString), "name": .string("finish"), "pid": pid]))
    }
    var parentsStopped: Bool {
        guard let parents = try? rows("parents.jsonl") else { return false }
        return parents.allSatisfy {
            guard case .number(let value) = $0["pid"], let pid = Int32(exactly: value), pid > 0 else { return false }
            return Darwin.kill(pid, 0) == -1 && errno == ESRCH
        }
    }
    func remove() throws {
        guard parentsStopped else { throw CoincideError("The task-owned Pi steering process is still alive; its fixture was retained.") }
        try FileManager.default.removeItem(at: root)
    }
}

private func piSteeringEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(6)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native Pi steering fixture did not reach its bounded boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func withPiSteering(_ options: [String: JSONValue] = [:], timeout: Duration = .seconds(5),
                            _ body: (PiSteeringFixture, PiSession, PiSteeringObserved) async throws -> Void) async throws {
    let f = try PiSteeringFixture(options: options)
    let session = PiSession(executable: f.executable, cwd: f.root, configuration: f.configuration,
                            arguments: [f.root.path], steeringTimeout: timeout)
    let observed = PiSteeringObserved()
    let reader = Task { for await event in session.events { await observed.append(event) } }
    do {
        try await body(f, session, observed)
        await session.close(); await reader.value; try f.remove()
    } catch {
        await session.close(); await reader.value; try? f.remove(); throw error
    }
}
private func piSteeringStart(_ f: PiSteeringFixture, _ session: PiSession, _ observed: PiSteeringObserved,
                             thread initial: CodingThread? = nil) async throws -> CodingThread {
    var thread = initial ?? f.thread()
    let runID = try #require(thread.activeRun?.id)
    try await session.send(text: "OPEN", thread: thread)
    try await piSteeringEventually { await observed.owners.contains(runID) }
    thread.providerThreadID = try #require(await observed.sessionFiles.last)
    return thread
}

@Test func piSteeringHasOnlyAnAdapterRunTargetAndSendsExactInputWithoutFutureSettings() async throws {
    try await withPiSteering(["foreignReply": .bool(true)]) { f, session, observed in
        let before = await session.steeringCapabilities()
        #expect(!before.supportsActiveSteering && before.target == nil)
        let absentFrames = try f.rows(); #expect(absentFrames.isEmpty)
        var thread = try await piSteeringStart(f, session, observed, thread: f.thread(model: .init(provider: "captured", modelID: "old"), thinking: "high"))
        let runID = try #require(thread.activeRun?.id)
        let caps = await session.steeringCapabilities()
        #expect(caps.supportsActiveSteering && !caps.interruptsTools && caps.target == .adapterRun(runID))
        let beforeFrames = try f.rows()
        thread.piConfiguration = .init(instanceID: UUID(), model: .init(provider: "future", modelID: "never"), thinkingLevel: "low")
        thread.model = "future-header"; thread.permission = .fullAccess; thread.workspacePath = "/future/workspace"
        let image = ProviderImage(mimeType: "image/png", data: Data([1, 2, 3]))
        let receipt = try await session.steer(input: .init(text: "STEER 日本語\u{2028}exact", images: [image]), thread: thread,
            target: .adapterRun(runID), clientMessageID: "user-\(UUID())")
        #expect(receipt.target == .adapterRun(runID) && receipt.turnID == nil && receipt.delivery == .acknowledged)
        let frames = try f.rows(), sent = try #require(frames.last { $0["type"].string == "prompt" })
        #expect(sent["message"].string == "STEER 日本語\u{2028}exact" && sent["streamingBehavior"].string == "steer")
        #expect(sent["images"] == .array([.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string("AQID")])]))
        #expect(frames.filter { ["set_model", "set_thinking_level", "switch_session"].contains($0["type"].string ?? "") } == beforeFrames.filter { ["set_model", "set_thinking_level", "switch_session"].contains($0["type"].string ?? "") })
        #expect(sent["expectedTurnId"] == .null && sent["clientMessageId"] == .null)
        let nativeTurns = await observed.nativeTurns; #expect(nativeTurns.isEmpty)
        try f.finish(); try await piSteeringEventually { await observed.completed.count == 1 }
        let completions = await observed.completed, owners = await observed.owners
        #expect(completions[0].0 == runID && owners == Set([runID]))
    }
}

@Test(arguments: ["run", "session", "configuration", "stopped", "native"])
func piSteeringStaleReferencesAreRejectedBeforeAnyWireMutation(_ change: String) async throws {
    try await withPiSteering { f, session, observed in
        var thread = try await piSteeringStart(f, session, observed)
        let runID = try #require(thread.activeRun?.id), before = try f.rows()
        var target = ProviderSteeringTarget.adapterRun(runID)
        switch change {
        case "run": target = .adapterRun(UUID())
        case "session": thread.providerThreadID = "/foreign/session.jsonl"
        case "configuration": thread.activeRun?.configuration.permission = .fullAccess
        case "stopped": thread.activeRun?.stopRequested = true
        default: target = .nativeTurn("not-a-native-pi-turn")
        }
        do { _ = try await session.steer(input: .init(text: "STEER stale"), thread: thread, target: target, clientMessageID: UUID().uuidString); Issue.record("An unrelated Pi steering target was accepted.") }
        catch let error as ProviderSteeringError { #expect(error.kind == (change == "native" ? .unsupported : .staleTarget)) }
        let after = try f.rows(); #expect(after == before)
    }
}

@Test func piSteeringNativeRejectionKeepsTheOriginalTurnAliveAndNeverLeaksNativeError() async throws {
    try await withPiSteering(["rejectSteering": .bool(true)]) { f, session, observed in
        let thread = try await piSteeringStart(f, session, observed), runID = try #require(thread.activeRun?.id)
        do { _ = try await session.steer(input: .init(text: "STEER rejected"), thread: thread, target: .adapterRun(runID), clientMessageID: "once"); Issue.record("A rejected input was accepted.") }
        catch let error as ProviderSteeringError { #expect(error.kind == .rejected && !error.localizedDescription.contains("PRIVATE_")) }
        let completed = await observed.completed, failures = await observed.failures
        #expect(completed.isEmpty && failures.isEmpty)
        try f.finish(); try await piSteeringEventually { await observed.completed.count == 1 }
        let final = await observed.completed; #expect(final[0].0 == runID && final[0].1 == .idle)
    }
}

@Test func piSteeringTerminalBeforeACKWaitsForRealAdmissionAndRetainsOriginalReceipt() async throws {
    try await withPiSteering(["terminalBeforeACK": .bool(true), "holdSteeringACK": .bool(true)]) { f, session, observed in
        let first = try await piSteeringStart(f, session, observed), runID = try #require(first.activeRun?.id)
        let steering = Task { try await session.steer(input: .init(text: "STEER held"), thread: first, target: .adapterRun(runID), clientMessageID: "held") }
        do {
            try await piSteeringEventually { await observed.notices.contains("terminal barrier") }
            let before = await observed.completed; #expect(before.isEmpty)
            try f.set("holdSteeringACK", .bool(false))
            try await piSteeringEventually { await observed.completed.count == 1 }
            let second = try await piSteeringStart(f, session, observed)
            let receipt = try await steering.value
            #expect(receipt.adapterRunID == runID && receipt.turnID == nil)
            #expect(second.activeRun?.id != runID)
            let failures = await observed.failures; #expect(failures.isEmpty)
            try f.finish(); try await piSteeringEventually { await observed.completed.count == 2 }
            let rows = try f.rows(); #expect(rows.filter { $0["type"].string == "prompt" }.count == 3)
        } catch { steering.cancel(); await session.close(); _ = await steering.result; throw error }
    }
}

@Test func piSteeringInvalidatesAnAlreadyCapturedIdleProbeAndKeepsContinuationOwned() async throws {
    try await withPiSteering(["startSteeringCycle": .bool(true)]) { f, session, observed in
        let thread = try await piSteeringStart(f, session, observed), runID = try #require(thread.activeRun?.id)
        try f.set("holdIdle", .bool(true)); try f.finish()
        try await piSteeringEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("held-idle").path) }
        let receipt = try await session.steer(input: .init(text: "STEER continue"), thread: thread, target: .adapterRun(runID), clientMessageID: "continue")
        #expect(receipt.adapterRunID == runID)
        try f.set("holdIdle", .bool(false))
        // A response barrier after releasing the old captured snapshot proves
        // that a stale idle result could not complete the newer native cycle.
        _ = try await session.models()
        let before = await observed.completed; #expect(before.isEmpty)
        try f.finish(); try await piSteeringEventually { await observed.completed.count == 1 }
        let final = await observed.completed, owners = await observed.owners
        #expect(final[0].0 == runID && owners == Set([runID]))
    }
}

@Test(arguments: ["timeout", "cancel", "stop", "close"])
func piSteeringUnconfirmedAdmissionNeverReplaysOrReportsAcknowledged(_ action: String) async throws {
    try await withPiSteering(["holdSteeringACK": .bool(true)], timeout: .milliseconds(250)) { f, session, observed in
        let thread = try await piSteeringStart(f, session, observed), runID = try #require(thread.activeRun?.id)
        let steering = Task { try await session.steer(input: .init(text: "STEER uncertain"), thread: thread, target: .adapterRun(runID), clientMessageID: "unknown") }
        do {
            try await piSteeringEventually { try f.rows().contains { $0["message"].string == "STEER uncertain" } }
            switch action {
            case "cancel": steering.cancel()
            case "stop": do { try await session.interrupt(expectedRunID: runID); Issue.record("An unconfirmed prompt was reported stopped.") } catch {}
            case "close": await session.close()
            default: break
            }
            do { _ = try await steering.value; Issue.record("A lost native steering response became an acknowledgement.") }
            catch let error as ProviderSteeringError { #expect(error.kind == .outcomeUncertain) }
            await session.close()
            let rows = try f.rows(); #expect(rows.filter { $0["message"].string == "STEER uncertain" }.count == 1)
            let complete = await observed.completed; #expect(complete.isEmpty)
            #expect(f.parentsStopped)
        } catch { steering.cancel(); await session.close(); _ = await steering.result; throw error }
    }
}

@Test func piSteeringSuccessfulContinuationDoesNotInheritAnEarlierNativeAbort() async throws {
    try await withPiSteering(["startSteeringCycle": .bool(true), "abortedPriorCycle": .bool(true)]) { f, session, observed in
        let thread = try await piSteeringStart(f, session, observed), runID = try #require(thread.activeRun?.id)
        _ = try await session.steer(input: .init(text: "STEER after native abort"), thread: thread, target: .adapterRun(runID), clientMessageID: "continue-abort")
        let before = await observed.completed; #expect(before.isEmpty)
        try f.finish(); try await piSteeringEventually { await observed.completed.count == 1 }
        let after = await observed.completed
        #expect(after[0].0 == runID && after[0].1 == .idle)
    }
}

@Test func piSteeringAdmittedInputRetainsNormalNativeStopAndExtensionDialogs() async throws {
    try await withPiSteering(["uiOnSteer": .bool(true)]) { f, session, observed in
        let thread = try await piSteeringStart(f, session, observed), runID = try #require(thread.activeRun?.id)
        let steering = Task { try await session.steer(input: .init(text: "STEER extension"), thread: thread, target: .adapterRun(runID), clientMessageID: "extension") }
        do {
            try await piSteeringEventually { await observed.requests.count == 1 }
            let request = try #require(await observed.requests.first)
            #expect(request.method == "pi/extension" && request.id != .string("steering-confirm"))
            try await session.respond(request, allow: true)
            let receipt = try await steering.value; #expect(receipt.adapterRunID == runID)
            try await session.interrupt(expectedRunID: runID)
            try await piSteeringEventually { await observed.completed.count == 1 }
            let rows = try f.rows(), completed = await observed.completed
            #expect(rows.contains { $0["type"].string == "abort" })
            #expect(completed[0].0 == runID && completed[0].1 == .interrupted)
            #expect(rows.contains { $0["type"].string == "extension_ui_response" && $0["id"].string == "steering-confirm" && $0["confirmed"] == .bool(true) })
        } catch { steering.cancel(); await session.close(); _ = await steering.result; throw error }
    }
}

@Test func piSteeringCompactUsesNativeCommandAndLocalDeliveryCountIsBoundedWithoutRetry() async throws {
    try await withPiSteering { f, session, observed in
        let thread = try await piSteeringStart(f, session, observed), runID = try #require(thread.activeRun?.id)
        _ = try await session.steer(input: .init(text: " /compact keep the tests "), thread: thread, target: .adapterRun(runID), clientMessageID: "compact")
        let rows = try f.rows(), compact = try #require(rows.last { $0["type"].string == "compact" })
        #expect(compact["customInstructions"].string == "keep the tests" && compact["streamingBehavior"] == .null)
        for index in 1..<64 {
            _ = try await session.steer(input: .init(text: "STEER bounded \(index)"), thread: thread, target: .adapterRun(runID), clientMessageID: "bounded-\(index)")
        }
        for id in ["compact", "over-limit"] {
            do { _ = try await session.steer(input: .init(text: "STEER never retry"), thread: thread, target: .adapterRun(runID), clientMessageID: id); Issue.record("An exhausted/reused local delivery identity was written.") }
            catch let error as ProviderSteeringError { #expect(error.kind == .rejected) }
        }
        let final = try f.rows(); #expect(final.filter { ["prompt", "compact"].contains($0["type"].string ?? "") }.count == 65)
        let caps = await session.steeringCapabilities(); #expect(!caps.supportsActiveSteering)
    }
}

/// The explicit historical fixture launches the Pi actor and literal --mode rpc
/// extension. Native stdio, SQLite, FIFO and recovery share the same path.
@Test(.timeLimit(.minutes(1)))
func piSteeringEngineKeepsOneRunAndCapturedFIFOWithoutInventingNativeTurnsOrReplayingAfterReopen() async throws {
    let f = try PiSteeringFixture(options: ["terminalBeforeACK": .bool(true), "holdSteeringACK": .bool(true)])
    let databaseURL = f.root.appendingPathComponent("workspace.sqlite")
    let engine = try WorkspaceEngine(url: databaseURL, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
    do {
        let project = WorkspaceProject(path: f.root.path)
        var thread = CodingThread(project: project)
        thread.provider = .pi; thread.piConfiguration = f.configuration; thread.checkpointPolicy = .disabled
        try await saveLegacyProviderFixture(project: project, threads: [thread], at: databaseURL)
        _ = try await engine.load()
        try await engine.dispatch(.submit(threadID: thread.id, text: "OPEN"))
        try await piSteeringEventually { await engine.promptSteeringAvailability(threadID: thread.id).canSteer }
        let started = try #require(await engine.current().snapshot.threads.first), runID = try #require(started.activeRun?.id)
        #expect(started.activeRun?.nativeTurnID == nil)
        let selection = PiModelSelection(provider: "future", modelID: "queued")
        let model = ProviderModel(id: selection.catalogID, name: "Queued Pi", piSelection: selection, piThinkingLevels: ["high", "low"])
        try await engine.dispatch(.editThread(thread.id, .piModel(model)))
        try await engine.dispatch(.editThread(thread.id, .piThinking(model: model, level: "high")))
        try await engine.dispatch(.submit(threadID: thread.id, text: "NEXT captured queue"))
        try await engine.dispatch(.editThread(thread.id, .piThinking(model: model, level: "low")))
        _ = try await engine.steerPrompt(threadID: thread.id, text: "STEER exact durable input", expectedRunID: runID)
        try await piSteeringEventually {
            let current = await engine.current().snapshot
            return current.promptSteerings?.first?.phase == .dispatching && current.threads.first?.messages.contains { $0.text == "terminal barrier" } == true
        }
        let held = await engine.current().snapshot
        #expect(held.threads.first?.activeRun?.id == runID && held.threads.first?.queuedTurns.map(\.text) == ["NEXT captured queue"])
        let heldFrames = try f.rows(); #expect(heldFrames.filter { $0["type"].string == "prompt" }.count == 2)
        try f.set("holdSteeringACK", .bool(false))
        try await piSteeringEventually {
            let current = await engine.current().snapshot
            let prompts = try f.rows().filter { $0["type"].string == "prompt" }.count
            return current.promptSteerings?.first?.phase == .delivered && current.threads.first?.activeRun?.id != runID &&
                current.threads.first?.activeRun != nil && prompts == 3 &&
                (current.threads.first?.messages.filter { $0.role == .assistant }.count ?? 0) >= 2
        }
        let after = await engine.current().snapshot
        let operation = try #require(after.promptSteerings?.first), current = try #require(after.threads.first)
        #expect(operation.adapterRunID == runID && operation.nativeTurnID == nil && operation.receipt?.adapterRunID == runID)
        #expect(operation.receipt?.delivery == .acknowledged && operation.configuration.piConfiguration?.model == nil)
        #expect(current.activeRun?.configuration.piConfiguration?.model == selection && current.activeRun?.configuration.piConfiguration?.thinkingLevel == "high")
        #expect(current.piConfiguration?.thinkingLevel == "low" && current.activeRun?.nativeTurnID == nil)
        #expect(current.messages.filter { $0.promptSteeringID == operation.id }.map(\.text) == ["STEER exact durable input"])
        let frames = try f.rows()
        #expect(frames.filter { $0["type"].string == "prompt" }.map { $0["message"].string } == ["OPEN", "STEER exact durable input", "NEXT captured queue"])
        try await engine.dispatch(.interrupt(threadID: thread.id))
        try await piSteeringEventually { await engine.current().snapshot.threads.first?.activeRun == nil }
        await engine.shutdown()
        let saved = await engine.current().snapshot
        #expect(saved.threads.first?.runHistory?.allSatisfy { $0.turnIDs.isEmpty } == true)
        let database = try WorkspaceDatabase(url: databaseURL), rebuilt = try await database.rebuildProjection().snapshot
        #expect(rebuilt.promptSteerings == saved.promptSteerings && rebuilt.threads.first?.messages == saved.threads.first?.messages)
        let beforeReopen = try f.rows()
        let reopened = try WorkspaceEngine(url: databaseURL, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
        _ = try await reopened.load(); await reopened.shutdown()
        let afterReopen = try f.rows(); #expect(afterReopen == beforeReopen)
        #expect(f.parentsStopped)
        try f.remove()
    } catch { await engine.shutdown(); try? f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func piSteeringEngineLostAdmissionPausesFIFOAndReopenNeverRepeatsTheInput() async throws {
    let f = try PiSteeringFixture(options: ["holdSteeringACK": .bool(true)])
    let database = f.root.appendingPathComponent("workspace.sqlite")
    let engine = try WorkspaceEngine(url: database, providerFactory: { thread in
        guard let configuration = thread.piConfiguration else { throw CoincideError("The Pi fixture configuration is missing.") }
        return PiSession(executable: f.executable, cwd: f.root, configuration: configuration, permission: thread.permission,
                         arguments: [f.root.path], steeringTimeout: .milliseconds(250))
    }, identityResolver: { _ in nil })
    do {
        let project = WorkspaceProject(path: f.root.path)
        var thread = CodingThread(project: project)
        thread.provider = .pi; thread.piConfiguration = f.configuration; thread.checkpointPolicy = .disabled
        try await saveLegacyProviderFixture(project: project, threads: [thread], at: database)
        _ = try await engine.load()
        try await engine.dispatch(.submit(threadID: thread.id, text: "OPEN"))
        try await piSteeringEventually { await engine.promptSteeringAvailability(threadID: thread.id).canSteer }
        let runID = try #require(await engine.current().snapshot.threads.first?.activeRun?.id)
        try await engine.dispatch(.submit(threadID: thread.id, text: "NEXT retained"))
        _ = try await engine.steerPrompt(threadID: thread.id, text: "STEER no retry", expectedRunID: runID)
        try await piSteeringEventually { await engine.current().snapshot.promptSteerings?.first?.phase == .unconfirmed }
        await engine.shutdown()
        let saved = await engine.current().snapshot
        let operation = try #require(saved.promptSteerings?.first), current = try #require(saved.threads.first)
        #expect(operation.adapterRunID == runID && operation.nativeTurnID == nil && operation.receipt == nil)
        #expect(current.queuePaused && current.queuedTurns.map(\.text) == ["NEXT retained"])
        #expect(current.messages.filter { $0.promptSteeringID == operation.id }.map(\.text) == ["STEER no retry"])
        let before = try f.rows()
        #expect(before.filter { $0["type"].string == "prompt" }.map { $0["message"].string } == ["OPEN", "STEER no retry"])
        let reopened = try WorkspaceEngine(url: database, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
        _ = try await reopened.load(); await reopened.shutdown()
        let after = try f.rows(); #expect(after == before && f.parentsStopped)
        try f.remove()
    } catch { await engine.shutdown(); try? f.remove(); throw error }
}
