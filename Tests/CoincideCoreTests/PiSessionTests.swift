import Foundation
import Testing
@testable import CoincideCore

private actor PiObserved {
    var completions: [(UUID?, ThreadState)] = []
    var failures: [String] = []
    var requests: [ApprovalRequest] = []
    var dismissed: [JSONValue] = []
    var entities: [ProviderEntityKey: ProviderEntity] = [:]
    var owners: [ProviderEntityKey: UUID] = [:]
    var threads: [String] = []
    var turnIDs: [String] = []
    var sendsReturned = 0
    func returned() { sendsReturned += 1 }
    func append(_ event: ProviderEvent, owner: UUID? = nil) {
        switch event {
        case .context(let id, let child): append(child, owner: id)
        case .completed(let state): completions.append((owner, state))
        case .connectionClosed(let text), .failure(let text): failures.append(text)
        case .sessionApproval(let request), .approval(let request): requests.append(request)
        case .sessionApprovalDismissed(let id), .approvalDismissed(let id): dismissed.append(id)
        case .entity(let update):
            entities[update.key] = try? update.apply(to: entities[update.key]); if let owner { owners[update.key] = owner }
        case .thread(let id): threads.append(id)
        case .turn(let id): turnIDs.append(id)
        default: break
        }
    }
}
private struct PiPeer {
    let root: URL
    let optionsFile: URL
    let wireFile: URL
    let session: PiSession
    let config: PiConfiguration
    let observed = PiObserved()
    init(options: [String: JSONValue] = [:], production: Bool = false, requestTimeout: Duration = .seconds(15)) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-peer-\(UUID())", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        optionsFile = root.appendingPathComponent("options.json"); wireFile = root.appendingPathComponent("wire.jsonl")
        try JSONEncoder().encode(JSONValue.object(options)).write(to: optionsFile, options: .atomic)
        let fixture = try #require(Bundle.module.url(forResource: "pi_rpc_server", withExtension: "py", subdirectory: "Fixtures"))
        config = .init()
        if production {
            let peer = root.appendingPathComponent("pi-peer")
            try FileManager.default.copyItem(at: fixture, to: peer)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: peer.path)
            session = .init(executable: peer, cwd: root, configuration: config)
        } else {
            session = .init(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root, configuration: config,
                            arguments: [fixture.path, root.path, optionsFile.path, wireFile.path], requestTimeout: requestTimeout)
        }
    }
    func thread(model: PiModelSelection? = nil, thinking: String? = nil, resume: String? = nil) -> CodingThread {
        var thread = CodingThread(project: .init(path: root.path))
        thread.provider = .pi; thread.piConfiguration = .init(instanceID: config.instanceID, model: model, thinkingLevel: thinking)
        thread.model = model?.catalogID ?? ""; thread.providerThreadID = resume; thread.permission = .supervised
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
        return thread
    }
    func frames() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: wireFile.path) else { return [] }
        let bytes = try Data(contentsOf: wireFile)
        guard let newline = bytes.lastIndex(of: 10) else { return [] }
        return try bytes[...newline].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func set(_ key: String, _ value: JSONValue) throws {
        var current = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: optionsFile)).object ?? [:]
        current[key] = value; try JSONEncoder().encode(JSONValue.object(current)).write(to: optionsFile, options: .atomic)
    }
    func signal(_ name: String) throws { try set("signal", .object(["id": .string(UUID().uuidString), "name": .string(name)])) }
}
private func withPi(_ options: [String: JSONValue] = [:], production: Bool = false, requestTimeout: Duration = .seconds(15), _ body: (PiPeer) async throws -> Void) async throws {
    let peer = try PiPeer(options: options, production: production, requestTimeout: requestTimeout)
    let observer = Task { for await event in peer.session.events { await peer.observed.append(event) } }
    do {
        try await body(peer)
        await peer.session.close(); observer.cancel(); await observer.value
        try FileManager.default.removeItem(at: peer.root)
    } catch {
        await peer.session.close(); observer.cancel(); await observer.value
        try? FileManager.default.removeItem(at: peer.root); throw error
    }
}
private func piEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(6)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned Pi peer did not reach the expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func piObservedStart(_ peer: PiPeer, _ thread: CodingThread) async throws {
    let id = try #require(thread.activeRun?.id)
    try await piEventually { await peer.observed.owners.values.contains(id) }
}

@Test func piNativeModelsUseExactSelectionThinkingAndProductionRPCApprovalHookWithoutSessionMutation() async throws {
    try await withPi(production: true) { peer in
        async let a = peer.session.models(), b = peer.session.models()
        let rows = try await a, other = try await b
        #expect(rows == other && rows.count == 2)
        #expect(rows[0].piSelection == .init(provider: "native", modelID: "baseline"))
        #expect(rows[0].piThinkingLevels == ["off", "low", "medium", "high", "xhigh", "max"])
        #expect(rows[1].piSelection?.modelID == "model/with/slash")
        let frames = try peer.frames(), launch = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: peer.root.appendingPathComponent("launch.json")))
        #expect(frames.allSatisfy { $0["type"].string == "get_available_models" })
        #expect(launch["toolHook"] == .bool(true) && launch["supervised"] == .bool(true))
        #expect(Array(launch["args"].array?.prefix(3) ?? []) == [.string("--mode"), .string("rpc"), .string("--extension")])
        let extensionPath = try #require(launch["args"].array?.last?.string)
        await peer.session.close()
        #expect(!FileManager.default.fileExists(atPath: extensionPath))
    }
}

@Test func piPromptACKAndAgentEndDoNotReleaseUntilNativeSettledIdleWithExactUTF8AndTools() async throws {
    try await withPi(["foreignResponse": .bool(true)]) { peer in
        let thread = peer.thread()
        try await peer.session.send(text: "Exact opening", thread: thread)
        try await piEventually { await peer.observed.entities.count >= 2 }
        try peer.signal("endOnly")
        try await piEventually { await peer.observed.entities.values.contains { $0.text.contains("exact done") } }
        let before = await peer.observed.completions
        #expect(before.isEmpty)
        try peer.signal("foreign")
        try await Task.sleep(for: .milliseconds(30))
        let still = await peer.observed.completions; #expect(still.isEmpty)
        try peer.signal("finish")
        try await piEventually { await peer.observed.completions.count == 1 }
        let complete = await peer.observed.completions, entities = await peer.observed.entities, owners = await peer.observed.owners
        #expect(complete[0].0 == thread.activeRun?.id && complete[0].1 == .idle)
        #expect(entities.values.contains { $0.text == "日本語\u{2028}exact done" })
        #expect(entities.values.contains { $0.key.type == "tool_call" && $0.fields["status"].string == "completed" && $0.text.contains("complete") })
        let owner = try #require(thread.activeRun?.id)
        #expect(Set(owners.values) == Set([owner]))
        let turns = await peer.observed.turnIDs; #expect(turns.isEmpty)
    }
}

@Test func piCapturedSettingsAndSessionFileResumeRestoreNativeBaselineAcrossFutureHeaderChanges() async throws {
    try await withPi { peer in
        _ = try await peer.session.models() // Starts the isolated peer and its real native header.
        let path = peer.root.appendingPathComponent("native-session.jsonl").path
        let selected = PiModelSelection(provider: "other", modelID: "model/with/slash")
        let first = peer.thread(model: selected, thinking: "high", resume: path)
        try await peer.session.send(text: "First", thread: first)
        try await piObservedStart(peer, first)
        try peer.signal("finish"); try await piEventually { await peer.observed.completions.count == 1 }
        let second = peer.thread(resume: path)
        try await peer.session.send(text: "Second", thread: second)
        try await piObservedStart(peer, second)
        let frames = try peer.frames(), models = frames.filter { $0["type"].string == "set_model" }, thinking = frames.filter { $0["type"].string == "set_thinking_level" }
        #expect(models.map { $0["provider"].string } == ["other", "native"])
        #expect(models.map { $0["modelId"].string } == ["model/with/slash", "baseline"])
        #expect(thinking.map { $0["level"].string } == ["high", "medium"])
        #expect(frames.filter { $0["type"].string == "switch_session" }.count == 1)
        #expect(frames.filter { $0["type"].string == "prompt" }.map { $0["message"].string } == ["First", "Second"])
        try await peer.session.interrupt()
    }
}

@Test func piLatePromptACKCannotBlockSuccessorOrAttributeItsOutputToPreviousRun() async throws {
    try await withPi(["beforeAck": .bool(true), "holdAck": .bool(true)]) { peer in
        let first = peer.thread(), sending = Task { try await peer.session.send(text: "First", thread: first) }
        try await piEventually { await peer.observed.completions.count == 1 }
        try peer.set("beforeAck", .bool(false))
        let second = peer.thread()
        try await peer.session.send(text: "Second", thread: second)
        try peer.set("holdAck", .bool(false)); try await sending.value
        try peer.signal("finish"); try await piEventually { await peer.observed.completions.count == 2 }
        let completions = await peer.observed.completions
        #expect(completions.map(\.0) == [first.activeRun?.id, second.activeRun?.id])
        let failures = await peer.observed.failures; #expect(failures.isEmpty)
    }
}

@Test func piDispatchUsesCapturedModelThinkingPermissionAndWorkspaceAfterFutureHeaderEdits() async throws {
    try await withPi { peer in
        var thread = peer.thread(model: .init(provider: "captured", modelID: "original"), thinking: "high")
        let runID = try #require(thread.activeRun?.id)
        thread.piConfiguration = .init(instanceID: UUID(), model: .init(provider: "future", modelID: "never"), thinkingLevel: "low")
        thread.model = "future-header"; thread.permission = .fullAccess; thread.workspacePath = "/not-the-captured-workspace"
        try await peer.session.send(text: "Captured request", thread: thread)
        try await piObservedStart(peer, thread)
        let frames = try peer.frames(), model = try #require(frames.last { $0["type"].string == "set_model" }), thinking = try #require(frames.last { $0["type"].string == "set_thinking_level" })
        #expect(model["provider"].string == "captured" && model["modelId"].string == "original")
        #expect(thinking["level"].string == "high")
        try peer.signal("finish"); try await piEventually { await peer.observed.completions.count == 1 }
        let complete = await peer.observed.completions; #expect(complete[0].0 == runID)
    }
}

@Test(arguments: [false, true]) func piStopDuringModelConfigurationNeverPostsPromptAfterLateReply(_ held: Bool) async throws {
    try await withPi(["holdModel": .bool(held)]) { peer in
        if held {
            let send = Task { try await peer.session.send(text: "Never delivered", thread: peer.thread(model: .init(provider: "other", modelID: "selected"))) }
            try await piEventually { try peer.frames().contains { $0["type"].string == "set_model" } }
            do { try await peer.session.interrupt() } catch {}
            try peer.set("releaseModel", .bool(true))
            do { try await send.value; Issue.record("Cancelled preparation unexpectedly sent a prompt.") } catch {}
            let frames = try peer.frames(); #expect(!frames.contains { $0["type"].string == "prompt" })
            do { try await peer.session.send(text: "Unsafe successor", thread: peer.thread()); Issue.record("A stopped preparation runtime was reused.") } catch {}
        } else {
            try await peer.session.send(text: "Actual turn", thread: peer.thread())
            try await piEventually { await peer.observed.entities.count >= 2 }
            try await peer.session.interrupt()
            try await piEventually { await peer.observed.completions.count == 1 }
            let completions = await peer.observed.completions, frames = try peer.frames()
            #expect(completions[0].1 == .interrupted)
            #expect(frames.contains { $0["type"].string == "abort" })
            #expect(frames.contains { $0["type"].string == "clear_queue" })
        }
    }
}

@Test func piProvenSettledPromptRetiresLostReplyBeforeOldSendCancellationAndSuccessor() async throws {
    try await withPi(["beforeAck": .bool(true), "holdAck": .bool(true)]) { peer in
        let first = peer.thread()
        let sending = Task {
            try await peer.session.send(text: "First exact run", thread: first)
            await peer.observed.returned()
        }
        try await piEventually { await peer.observed.sendsReturned == 1 }
        sending.cancel(); try await sending.value
        try peer.set("beforeAck", .bool(false))
        let second = peer.thread(); try await peer.session.send(text: "Successor", thread: second)
        // The original reply remains held/lost. Its cancellation cannot retire
        // the healthy session after exact native completion has been proved.
        try peer.signal("finish"); try await piEventually { await peer.observed.completions.count == 2 }
        let failures = await peer.observed.failures, frames = try peer.frames()
        #expect(failures.isEmpty)
        #expect(frames.filter { $0["type"].string == "prompt" }.count == 2)
    }
}

@Test func piOldStopHeldReplyNeverClearsOrInterruptsAnObservedSuccessor() async throws {
    try await withPi(["holdAbortAck": .bool(true)]) { peer in
        let first = peer.thread(); try await peer.session.send(text: "First", thread: first)
        try await piEventually { await peer.observed.entities.count >= 2 }
        let stop = Task { try await peer.session.interrupt() }
        try await piEventually { await peer.observed.completions.count == 1 }
        let second = peer.thread(); try await peer.session.send(text: "Successor", thread: second)
        try peer.set("holdAbortAck", .bool(false)); try await stop.value
        try await Task.sleep(for: .milliseconds(30))
        let prior = await peer.observed.completions, frames = try peer.frames()
        #expect(prior.count == 1 && prior[0].1 == .interrupted)
        #expect(frames.filter { $0["type"].string == "abort" }.count == 1)
        #expect(!frames.contains { $0["type"].string == "clear_queue" })
        try peer.signal("finish"); try await piEventually { await peer.observed.completions.count == 2 }
        let complete = await peer.observed.completions; #expect(complete[1].0 == second.activeRun?.id && complete[1].1 == .idle)
    }
}

@Test(arguments: ["stop-state", "settlement-probe"])
func piOwnedReadDeadlineCannotCloseSuccessorAfterIndependentSettledProof(_ heldKind: String) async throws {
    let options: [String: JSONValue] = heldKind == "stop-state"
        ? ["deferAbortSettled": .bool(true)] : ["holdAbortAck": .bool(true)]
    try await withPi(options, requestTimeout: .milliseconds(500)) { peer in
        let first = peer.thread(); try await peer.session.send(text: "Original", thread: first)
        try await piEventually { await peer.observed.entities.count >= 2 }
        // Arm only after registration/preflight. The old reply stays lost for
        // longer than the injected real RPC deadline, not just a queue count.
        try peer.set("holdNextState", .bool(true))
        let stopping = Task { try await peer.session.interrupt() }
        try await piEventually { FileManager.default.fileExists(atPath: peer.root.appendingPathComponent("held-state").path) }
        if heldKind == "stop-state" {
            // Abort ACK/clear_queue happened, then its final state read held.
            // A later authoritative settled event enables an independent read.
            try peer.signal("settled")
        } else {
            // Holding abort ACK means the first read must be the settlement
            // probe. Releasing ACK lets Stop's final read prove actual idle.
            try peer.set("holdAbortAck", .bool(false))
        }
        try await piEventually { await peer.observed.completions.count == 1 }
        try await stopping.value
        let second = peer.thread(); try await peer.session.send(text: "Healthy successor", thread: second)
        try await Task.sleep(for: .milliseconds(750))
        let failures = await peer.observed.failures, before = await peer.observed.completions
        #expect(failures.isEmpty && before.count == 1)
        try peer.signal("finish"); try await piEventually { await peer.observed.completions.count == 2 }
        let complete = await peer.observed.completions, frames = try peer.frames()
        #expect(complete[1].0 == second.activeRun?.id && complete[1].1 == .idle)
        #expect(frames.filter { $0["type"].string == "prompt" }.count == 2)
    }
}

@Test func piStopAfterACKWithoutOwnedAgentStartRetiresRuntimeInsteadOfClaimingInterruption() async throws {
    try await withPi(["holdStart": .bool(true)]) { peer in
        try await peer.session.send(text: "Accepted but not observed running", thread: peer.thread())
        do { try await peer.session.interrupt(); Issue.record("Unobserved admission was treated as a confirmed Stop.") } catch {}
        try await piEventually { await !peer.observed.failures.isEmpty }
        do { try await peer.session.send(text: "No unsafe runtime reuse", thread: peer.thread()); Issue.record("An uncertain runtime accepted a successor.") } catch {}
        let completions = await peer.observed.completions, frames = try peer.frames()
        #expect(completions.isEmpty)
        #expect(frames.filter { $0["type"].string == "prompt" }.count == 1)
        #expect(!frames.contains { $0["type"].string == "abort" })
    }
}

@Test func piSettledIntentSurvivesFollowingCompactionAndFreshIdleProbeWithoutAnotherSettledEvent() async throws {
    try await withPi { peer in
        let thread = peer.thread(); try await peer.session.send(text: "Compact after settlement", thread: thread)
        try await piObservedStart(peer, thread)
        try peer.signal("settledCompaction")
        try await piEventually { await peer.observed.entities.values.contains { $0.text.contains("compaction barrier") } }
        let before = await peer.observed.completions; #expect(before.isEmpty)
        try peer.signal("compactionEnd")
        try await piEventually { await peer.observed.completions.count == 1 }
        let complete = await peer.observed.completions, failure = await peer.observed.failures
        #expect(complete[0].1 == .idle && failure.isEmpty)
    }
}

@Test(arguments: ["confirm", "select", "input", "editor"])
func piExtensionUIUsesOpaqueLocalIDsExactNativeResponsesAndPreservesEmptyInput(_ method: String) async throws {
    try await withPi(["ui": .string(method)]) { peer in
        try await peer.session.send(text: "Needs input", thread: peer.thread())
        try await piEventually { await peer.observed.requests.count == 1 }
        let list = await peer.observed.requests, request = try #require(list.first)
        #expect(request.id != .string("native-ui") && request.method == "pi/extension")
        let typed = try PiExtensionRequest.presentation(request); #expect(typed.method.rawValue == method)
        if method == "confirm" { try await peer.session.respond(request, allow: false) }
        else if method == "select" { try await peer.session.choose(request, optionID: "Two") }
        else { try await peer.session.answer(request, answers: ["value": ""]) }
        // Pipe write completion is not proof that the peer has consumed and
        // logged the response, or that the event observer has seen dismissal.
        try await piEventually {
            let frames = try peer.frames(), dismissed = await peer.observed.dismissed
            return frames.contains { $0["type"].string == "extension_ui_response" } && dismissed == [request.id]
        }
        let frames = try peer.frames(), reply = try #require(frames.last { $0["type"].string == "extension_ui_response" })
        #expect(reply["id"] == .string("native-ui"))
        if method == "confirm" { #expect(reply["confirmed"] == .bool(false)) }
        else { #expect(reply["value"] == .string(method == "select" ? "Two" : "")) }
        do { try await peer.session.respond(request, allow: false); Issue.record("A duplicate extension response was accepted.") } catch {}
        let dismissed = await peer.observed.dismissed; #expect(dismissed == [request.id])
    }
}

@Test(arguments: ["rejectPrompt", "dropReply", "invalid", "exit"])
func piRejectedOrUncertainProtocolNeverResendsAndSanitizesProviderErrors(_ failure: String) async throws {
    let options: [String: JSONValue] = [failure: .bool(true)]
    try await withPi(options) { peer in
        if failure == "invalid" || failure == "exit" {
            try await peer.session.send(text: "One attempt", thread: peer.thread()); try peer.signal(failure)
            try await piEventually { await !peer.observed.failures.isEmpty }
        } else {
            do { try await peer.session.send(text: "One attempt", thread: peer.thread()); Issue.record("The peer failure was not surfaced.") }
            catch { #expect(!error.localizedDescription.contains("synthetic-private-token")) }
        }
        let frames = try peer.frames(); #expect(frames.filter { $0["type"].string == "prompt" }.count == 1)
        let failures = await peer.observed.failures
        #expect(failures.allSatisfy { !$0.contains("synthetic-private-token") })
        let complete = await peer.observed.completions; #expect(complete.isEmpty)
    }
}

@Test func piMissingOrForeignResumeHeaderNeverSwitchesOrCreatesAReplacementConversation() async throws {
    try await withPi { peer in
        do { try await peer.session.send(text: "Must retain history", thread: peer.thread(resume: peer.root.appendingPathComponent("missing.jsonl").path)); Issue.record("Missing resume was accepted.") } catch {}
        let frames = try peer.frames()
        #expect(!frames.contains { ["switch_session", "new_session", "prompt"].contains($0["type"].string ?? "") })
    }
}

@Test func piHealthyModelFailureCompletesFailedWithoutDiscardingRuntimeAndSteeringIsHonestUnsupported() async throws {
    try await withPi { peer in
        let first = peer.thread(); try await peer.session.send(text: "First", thread: first)
        try await piObservedStart(peer, first)
        try peer.signal("failed"); try await piEventually { await peer.observed.completions.count == 1 }
        let complete = await peer.observed.completions; #expect(complete[0].1 == .failed)
        let capabilities = await peer.session.steeringCapabilities(); #expect(!capabilities.supportsActiveSteering)
        try await peer.session.send(text: "Second", thread: peer.thread())
        let failures = await peer.observed.failures; #expect(failures.isEmpty)
    }
}
