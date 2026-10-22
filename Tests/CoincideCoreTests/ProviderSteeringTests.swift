import Foundation
import Testing
@testable import CoincideCore

private actor SteeringObservedEvents {
    private(set) var turnIDs: [String] = []
    private(set) var completions: [ThreadState] = []
    private(set) var failures: [String] = []
    private(set) var runIDs: [UUID] = []
    private(set) var assistantTexts: [String] = []
    private(set) var deltaTexts: [String] = []
    private(set) var capabilityChanges = 0
    func append(_ event: ProviderEvent) {
        if case .context(let id, let child) = event { runIDs.append(id); append(child); return }
        switch event {
        case .turn(let id): if turnIDs.last != id { turnIDs.append(id) }
        case .completed(let state): completions.append(state)
        case .failure(let message): failures.append(message)
        case .message(let message) where message.role == .assistant: assistantTexts.append(message.text)
        case .delta(_, _, let text): deltaTexts.append(text)
        case .steeringCapabilitiesChanged: capabilityChanges += 1
        default: break
        }
    }
}

private struct SteeringPeer {
    let root: URL
    let optionsFile: URL
    let wireFile: URL
    let kind: ProviderKind
    let session: any ProviderSession
    let observed = SteeringObservedEvents()
    init(kind: ProviderKind, options: [String: JSONValue] = [:]) throws {
        self.kind = kind
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-steering-\(UUID())", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        optionsFile = root.appendingPathComponent("options.json"); wireFile = root.appendingPathComponent("wire.jsonl")
        try JSONEncoder().encode(JSONValue.object(options)).write(to: optionsFile, options: .atomic)
        let fixture = try #require(Bundle.module.url(forResource: "provider_steering", withExtension: "py", subdirectory: "Fixtures"))
        let arguments = [fixture.path, kind.rawValue, optionsFile.path, wireFile.path]
        if kind == .codex {
            session = try CodexSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root, arguments: arguments)
        } else {
            session = try ClaudeSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root, arguments: arguments)
        }
    }
    func set(_ key: String, _ value: JSONValue) throws {
        var options = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: optionsFile)).object ?? [:]
        options[key] = value
        try JSONEncoder().encode(JSONValue.object(options)).write(to: optionsFile, options: .atomic)
    }
    func signal(_ name: String) throws { try set("signal", .object(["id": .string(UUID().uuidString), "name": .string(name)])) }
    func frames() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: wireFile.path) else { return [] }
        return try Data(contentsOf: wireFile).split(separator: 10).compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func steers() throws -> [JSONValue] {
        try frames().filter { kind == .codex ? $0["method"] == .string("turn/steer") : $0["type"] == .string("user") && $0["priority"] == .string("now") }
    }
    func starts() throws -> [JSONValue] {
        try frames().filter { kind == .codex ? $0["method"] == .string("turn/start") : $0["type"] == .string("user") && $0["priority"] == .null }
    }
    func start() async throws -> CodingThread {
        var thread = CodingThread(project: WorkspaceProject(path: root.path), model: "captured-model")
        thread.provider = kind; thread.providerThreadID = "native-source"; thread.permission = .supervised
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
        let before = await observed.turnIDs.count
        try await session.send(input: .init(text: "Original captured request"), thread: thread)
        try await steeringEventually { await observed.turnIDs.count > before }
        thread.activeRun?.nativeTurnID = await observed.turnIDs.last
        return thread
    }
}

private func withSteeringPeer(kind: ProviderKind = .codex, options: [String: JSONValue] = [:], _ body: (SteeringPeer) async throws -> Void) async throws {
    let peer = try SteeringPeer(kind: kind, options: options), events = peer.session.events
    let observer = Task { for await event in events { await peer.observed.append(event) } }
    do {
        try await body(peer)
        await peer.session.close(); observer.cancel(); await observer.value
        try FileManager.default.removeItem(at: peer.root)
    } catch {
        await peer.session.close(); observer.cancel(); await observer.value
        try? FileManager.default.removeItem(at: peer.root)
        throw error
    }
}
private func steeringEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned offline steering peer did not reach the expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func steeringError(_ kind: ProviderSteeringError.Kind, _ body: () async throws -> Void) async throws {
    do { try await body(); Issue.record("Expected the steering request to be rejected.") }
    catch let error as ProviderSteeringError {
        #expect(error.kind == kind)
        #expect(!error.localizedDescription.contains("synthetic-private-token"))
        #expect(error.mayHaveBeenDelivered == (kind == .outcomeUncertain))
    }
}
private actor SteeringUnsupportedSession: ProviderSession {
    nonisolated let events = AsyncStream<ProviderEvent> { $0.finish() }
    func models() async throws -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) async throws {}
    func interrupt() async throws {}
    func respond(_ request: ApprovalRequest, allow: Bool) async throws {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {}
    func close() async {}
}

@Test
func providerSteeringReceiptsValidateAndOtherAdaptersDefaultToUnsupported() async throws {
    let receipt = try ProviderSteeringReceipt(turnID: "opaque-native-turn")
    #expect(receipt.delivery == .acknowledged)
    #expect(try JSONDecoder().decode(ProviderSteeringReceipt.self, from: JSONEncoder().encode(receipt)) == receipt)
    for id in ["", " \t", "native\nturn", String(repeating: "x", count: 4_097)] {
        let encoded = try JSONEncoder().encode(JSONValue.object(["turnID": .string(id), "delivery": .string("submitted")]))
        #expect(throws: ProviderSteeringError.self) { try JSONDecoder().decode(ProviderSteeringReceipt.self, from: encoded) }
    }
    let session = SteeringUnsupportedSession(), thread = CodingThread(project: .init(path: "/tmp"))
    let capabilities = await session.steeringCapabilities()
    #expect(!capabilities.supportsActiveSteering)
    try await steeringError(.unsupported) { _ = try await session.steer(input: .init(text: "More guidance"), thread: thread, expectedTurnID: "turn", clientMessageID: "message") }
}

@Test(.timeLimit(.minutes(1)))
func codexSteeringUsesExactActiveTurnAndAttachmentsWithoutReconfiguringOrStartingAnotherRun() async throws {
    try await withSteeringPeer { peer in
        let thread = try await peer.start(), turnID = try #require(thread.activeRun?.nativeTurnID)
        let capability = await peer.session.steeringCapabilities()
        #expect(capability.supportsActiveSteering && !capability.interruptsTools)
        let messageID = UUID().uuidString, input = ProviderInput(text: "Keep 日本語 and exact whitespace  ", images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))])
        let receipt = try await peer.session.steer(input: input, thread: thread, expectedTurnID: turnID, clientMessageID: messageID)
        #expect(receipt.turnID == turnID && receipt.delivery == .acknowledged)
        let frames = try peer.steers(), parameters = try #require(frames.first?["params"].object)
        #expect(frames.count == 1 && Set(parameters.keys) == Set(["threadId", "expectedTurnId", "clientUserMessageId", "input"]))
        #expect(parameters["threadId"] == .string("native-source") && parameters["expectedTurnId"] == .string(turnID))
        #expect(parameters["clientUserMessageId"] == .string(messageID))
        #expect(parameters["input"]?.array?.first?["text"] == .string(input.text))
        #expect(parameters["input"]?.array?.last?["url"] == .string("data:image/png;base64,AQID"))
        #expect(try peer.starts().count == 1)
        try peer.signal("complete")
        try await steeringEventually { await peer.observed.completions.count == 1 }
        let turns = await peer.observed.turnIDs, runs = await peer.observed.runIDs, failures = await peer.observed.failures
        let runID = try #require(thread.activeRun?.id)
        #expect(turns == [turnID] && Set(runs) == Set([runID]) && failures.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [ProviderKind.codex, .claude])
func providerSteeringRejectsChangedRunTurnOrFutureSettingsBeforeWriting(kind: ProviderKind) async throws {
    try await withSteeringPeer(kind: kind) { peer in
        let original = try await peer.start(), turn = try #require(original.activeRun?.nativeTurnID)
        var changed = original; changed.model = "future-model"; changed.permission = .fullAccess
        try await steeringError(.staleTarget) { _ = try await peer.session.steer(input: .init(text: "Different settings"), thread: changed, expectedTurnID: turn, clientMessageID: UUID().uuidString) }
        changed = original; changed.activeRun?.id = UUID()
        try await steeringError(.staleTarget) { _ = try await peer.session.steer(input: .init(text: "Wrong run"), thread: changed, expectedTurnID: turn, clientMessageID: UUID().uuidString) }
        try await steeringError(.staleTarget) { _ = try await peer.session.steer(input: .init(text: "Wrong turn"), thread: original, expectedTurnID: "different-turn", clientMessageID: UUID().uuidString) }
        #expect(try peer.steers().isEmpty)
        try peer.signal("complete")
        try await steeringEventually { await peer.observed.completions.count == 1 }
        try await steeringError(.noActiveTurn) { _ = try await peer.session.steer(input: .init(text: "Finished run"), thread: original, expectedTurnID: turn, clientMessageID: UUID().uuidString) }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["rejected", "unsupported", "internal", "wrongAck"])
func codexSteeringClassifiesRefusalsAndUncertaintyWithoutRetiringTheActiveRun(mode: String) async throws {
    try await withSteeringPeer(options: ["mode": .string(mode)]) { peer in
        let thread = try await peer.start(), turn = try #require(thread.activeRun?.nativeTurnID)
        let kind: ProviderSteeringError.Kind = mode == "rejected" ? .rejected : mode == "unsupported" ? .unsupported : .outcomeUncertain
        try await steeringError(kind) { _ = try await peer.session.steer(input: .init(text: "More guidance"), thread: thread, expectedTurnID: turn, clientMessageID: UUID().uuidString) }
        let capabilities = await peer.session.steeringCapabilities()
        #expect(capabilities.supportsActiveSteering)
        #expect(try peer.steers().count == 1 && peer.starts().count == 1)
        try peer.signal("complete")
        try await steeringEventually { await peer.observed.completions.count == 1 }
        let failures = await peer.observed.failures
        #expect(failures.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func codexSteeringLateAcknowledgementAfterCompletionAndCallerCancellationNeverReinstallsOldTurn() async throws {
    try await withSteeringPeer { peer in
        let thread = try await peer.start(), turn = try #require(thread.activeRun?.nativeTurnID)
        let release = peer.root.appendingPathComponent("release-ack")
        try peer.set("ackRelease", .string(release.path))
        let steering = Task { try await peer.session.steer(input: .init(text: "Accepted guidance"), thread: thread, expectedTurnID: turn, clientMessageID: UUID().uuidString) }
        do {
            try await steeringEventually { try peer.steers().count == 1 }
            steering.cancel()
            try peer.signal("complete")
            try await steeringEventually { await peer.observed.completions.count == 1 }
            try Data().write(to: release)
            let receipt = try await steering.value
            #expect(receipt.turnID == turn && receipt.delivery == .acknowledged)
            let next = try await peer.start(), nextTurn = try #require(next.activeRun?.nativeTurnID)
            #expect(nextTurn != turn)
            try peer.signal("complete")
            try await steeringEventually { await peer.observed.completions.count == 2 }
            let turns = await peer.observed.turnIDs
            #expect(turns == [turn, nextTurn])
        } catch { try? Data().write(to: release); _ = try? await steering.value; throw error }
    }
}

@Test(.timeLimit(.minutes(1)))
func codexSteeringUnknownProfileDoesNotProbeBySubmittingInput() async throws {
    try await withSteeringPeer(options: ["userAgent": .string("codex/9.0.0")]) { peer in
        let thread = try await peer.start(), turn = try #require(thread.activeRun?.nativeTurnID)
        let capabilities = await peer.session.steeringCapabilities()
        #expect(!capabilities.supportsActiveSteering)
        try await steeringError(.unsupported) { _ = try await peer.session.steer(input: .init(text: "Never probe"), thread: thread, expectedTurnID: turn, clientMessageID: UUID().uuidString) }
        #expect(try peer.steers().isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func codexSteeringSerializesFollowupsAndCancelsAnUnsentWaiterWithoutClosingTheLiveStream() async throws {
    try await withSteeringPeer { peer in
        let thread = try await peer.start(), turn = try #require(thread.activeRun?.nativeTurnID)
        let release = peer.root.appendingPathComponent("release-first-steer")
        try peer.set("ackRelease", .string(release.path))
        let first = Task { try await peer.session.steer(input: .init(text: "First steering"), thread: thread, expectedTurnID: turn, clientMessageID: UUID().uuidString) }
        var second: Task<ProviderSteeringReceipt, any Error>?
        do {
            try await steeringEventually { try peer.steers().count == 1 }
            let waiter = Task { try await peer.session.steer(input: .init(text: "Unsent cancelled steering"), thread: thread, expectedTurnID: turn, clientMessageID: UUID().uuidString) }
            second = waiter; waiter.cancel()
            try Data().write(to: release)
            _ = try await first.value
            do { _ = try await waiter.value; Issue.record("A cancelled unsent steering waiter was delivered.") }
            catch is CancellationError {}
            #expect(try peer.steers().count == 1)
            let capabilities = await peer.session.steeringCapabilities()
            #expect(capabilities.supportsActiveSteering)
            try peer.signal("complete")
            try await steeringEventually { await peer.observed.completions.count == 1 }
        } catch {
            try? Data().write(to: release); _ = try? await first.value
            if let second { second.cancel(); _ = try? await second.value }
            throw error
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func claudeSteeringUsesPriorityNowAndKeepsSteeringAbortSegmentsWithinTheSameRun() async throws {
    try await withSteeringPeer(kind: .claude) { peer in
        let thread = try await peer.start(), turn = try #require(thread.activeRun?.nativeTurnID)
        let capability = await peer.session.steeringCapabilities()
        #expect(capability.supportsActiveSteering && capability.interruptsTools)
        let receipt = try await peer.session.steer(input: .init(text: "Keep active settings 日本語", images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))]),
            thread: thread, expectedTurnID: turn, clientMessageID: UUID().uuidString)
        #expect(receipt.turnID == turn && receipt.delivery == .submitted)
        try await steeringEventually { try peer.steers().count == 1 }
        // The later assistant event proves both preceding aborted segments
        // have passed through the actor's ordered event consumer.
        try await steeringEventually { await peer.observed.assistantTexts.contains("After steering 日本語") }
        let after = await peer.session.steeringCapabilities(), completions = await peer.observed.completions
        #expect(after.supportsActiveSteering && completions.isEmpty)
        let frame = try #require(peer.steers().first), controls = try peer.frames().filter { $0["type"] == .string("control_request") }
        #expect(frame["priority"] == .string("now") && frame["parent_tool_use_id"] == .null)
        #expect(frame["message"]["content"].array?.first?["source"]["data"] == .string("AQID"))
        #expect(frame["message"]["content"].array?.last?["text"] == .string("Keep active settings 日本語"))
        #expect(controls.filter { $0["request"]["subtype"] == .string("set_model") }.count == 1)
        #expect(controls.filter { $0["request"]["subtype"] == .string("set_permission_mode") }.count == 1)
        #expect(try peer.starts().count == 1)
        try peer.signal("complete")
        try await steeringEventually { await peer.observed.completions.count == 1 }
        let turns = await peer.observed.turnIDs, runs = await peer.observed.runIDs
        let runID = try #require(thread.activeRun?.id)
        #expect(turns == [turn] && Set(runs) == Set([runID]))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["agent_assistant", "agent_stream", "agent_system"])
func claudeSteeringRefusesActiveAgentsUntilTheirForegroundOwnershipIsReleased(signal: String) async throws {
    try await withSteeringPeer(kind: .claude) { peer in
        let thread = try await peer.start(), turn = try #require(thread.activeRun?.nativeTurnID)
        try peer.signal("token_delta")
        try await steeringEventually { await peer.observed.deltaTexts.count == 1 }
        #expect(await peer.observed.capabilityChanges == 0)
        try peer.signal(signal)
        try await steeringEventually { await peer.observed.capabilityChanges == 1 }
        #expect(!(await peer.session.steeringCapabilities()).supportsActiveSteering)
        try await steeringError(.unsupported) { _ = try await peer.session.steer(input: .init(text: "Do not stop the agent"), thread: thread, expectedTurnID: turn, clientMessageID: UUID().uuidString) }
        #expect(try peer.steers().isEmpty)
        // The system case releases ownership without a transcript/tool message.
        try peer.signal(signal == "agent_system" ? "agent_system_finished" : "agent_finished")
        try await steeringEventually { await peer.observed.capabilityChanges == 2 }
        #expect(await peer.session.steeringCapabilities().supportsActiveSteering)
        try peer.signal("token_delta")
        try await steeringEventually { await peer.observed.deltaTexts.count == 2 }
        #expect(await peer.observed.capabilityChanges == 2)
        _ = try await peer.session.steer(input: .init(text: "Safe direct guidance"), thread: thread, expectedTurnID: turn, clientMessageID: UUID().uuidString)
        try await steeringEventually { try peer.steers().count == 1 }
        try peer.signal("complete")
        try await steeringEventually { await peer.observed.completions.count == 1 }
    }
}

@Test(.timeLimit(.minutes(1)))
func claudeSteeringDoesNotSuppressExplicitStopOrAnAbortWithoutOwnedSteering() async throws {
    for steered in [false, true] {
        let options: [String: JSONValue] = steered ? ["holdSteeringSegmentsUntilInterrupt": .bool(true)] : [:]
        try await withSteeringPeer(kind: .claude, options: options) { peer in
            let thread = try await peer.start(), turn = try #require(thread.activeRun?.nativeTurnID)
            if steered {
                _ = try await peer.session.steer(input: .init(text: "More guidance"), thread: thread, expectedTurnID: turn, clientMessageID: UUID().uuidString)
                try await peer.session.interrupt()
                // Ordered after the two steering abort segments and the Stop
                // result, so duplicate completions cannot escape the assertion.
                try await steeringEventually { await peer.observed.assistantTexts.contains("Offline Stop drain boundary") }
            } else { try peer.signal("abort_streaming") }
            try await steeringEventually { await peer.observed.completions.count == 1 }
            let completions = await peer.observed.completions
            #expect(completions == [steered ? .interrupted : .idle])
            #expect(try peer.steers().count == (steered ? 1 : 0))
            let controls = try peer.frames().filter { $0["type"] == .string("control_request") && $0["request"]["subtype"] == .string("interrupt") }
            #expect(controls.count == (steered ? 1 : 0))
        }
    }
}
