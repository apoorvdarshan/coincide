import Darwin
import Foundation
import Testing
@testable import CoincideCore

@Test func contextHandoffMuseKeepsDisplayTextLiteralAndSuppliesHistoricalBlocks() async throws {
    try await withMuse { peer in
        let input = try contextHandoffTestInput()
        try await peer.session.send(input: input, thread: peer.thread())
        try await museEventually { try peer.fixture.rows("prompt").count == 1 }
        let prompts = try peer.fixture.rows("prompt"), requests = try peer.fixture.rows("request")
        let prompt = try #require(prompts.first), request = try #require(requests.first { $0["method"] == .string("turn/start") })
        #expect(prompt["input"].array?.compactMap { $0["text"].string } == (try input.providerTextBlocks()))
        #expect(request["params"]["displayText"] == .string(input.text))
    }
}

actor MuseObserved {
    var completions: [(UUID?, ThreadState)] = []
    var failures: [String] = []
    var requests: [ApprovalRequest] = []
    var dismissed: [JSONValue] = []
    var turns: [UUID: String] = [:]
    var sessions: [String] = []
    var returnedStops = 0
    var entities: [ProviderEntityKey: ProviderEntity] = [:]
    var entityOwners: [ProviderEntityKey: UUID] = [:]
    func append(_ event: ProviderEvent, owner: UUID? = nil) {
        switch event {
        case .context(let id, let nested): append(nested, owner: id)
        case .runEntity(let id, let update): apply(update, owner: id)
        case .entity(let update): apply(update, owner: owner)
        case .turn(let id): if let owner { turns[owner] = id }
        case .thread(let id): sessions.append(id)
        case .completed(let state): completions.append((owner, state))
        case .failure(let text), .connectionClosed(let text): failures.append(text)
        case .sessionApproval(let request): requests.append(request)
        case .sessionApprovalDismissed(let id): dismissed.append(id)
        default: break
        }
    }
    private func apply(_ update: ProviderEntityUpdate, owner: UUID?) {
        entities[update.key] = try? update.apply(to: entities[update.key]); if let owner { entityOwners[update.key] = owner }
    }
    func stopReturned() { returnedStops += 1 }
}

struct MuseSessionFixture: Sendable {
    let root: URL
    let executable: URL
    let optionsFile: URL
    init(options: [String: JSONValue] = [:], resource: String = "muse_msp_server") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-muse-\(UUID())", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        executable = root.appendingPathComponent("native-muse-peer"); optionsFile = root.appendingPathComponent("options.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = try #require(Bundle.module.url(forResource: resource, withExtension: "py", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try JSONEncoder().encode(JSONValue.object(options)).write(to: optionsFile, options: .atomic)
        try JSONEncoder().encode(JSONValue.object(["directory": .string(root.path)])).write(to: root.appendingPathComponent("canonical-directory.json"), options: .atomic)
    }
    func rows(_ kind: String? = nil) throws -> [JSONValue] {
        let file = root.appendingPathComponent("wire.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let bytes = try Data(contentsOf: file)
        guard let newline = bytes.lastIndex(of: 10) else { return [] }
        let result = try bytes[...newline].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
        return kind.map { name in result.filter { $0["kind"].string == name } } ?? result
    }
    func set(_ name: String, _ value: JSONValue) throws {
        var values = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: optionsFile)).object ?? [:]
        values[name] = value; try JSONEncoder().encode(JSONValue.object(values)).write(to: optionsFile, options: .atomic)
    }
    func signal(_ name: String) throws {
        let process = try #require(rows("process").last { $0["metadata"] == .bool(false) })
        try set("signal", .object(["name": .string(name), "id": .string(UUID().uuidString), "pid": process["pid"]]))
    }
    func seedSession(id: String, profile: String) throws {
        let session: JSONValue = .object(["sessionId": .string(id), "workspaceRoot": .string(root.path), "path": .string(root.path),
            "providerId": .string("meta"), "modelId": .string("native-default"), "activeTurnId": .null,
            "createdAt": .string("2026-10-22T00:00:00Z"), "updatedAt": .string("2026-10-22T00:00:00Z"),
            "forkedFrom": .null, "status": .string("idle"), "turnCount": .number(0),
            "permissionState": .object(["profileId": .string(profile)]), "approvalMode": .object(["mode": .string("promptUnmatched")])])
        try JSONEncoder().encode(JSONValue.object([id: session])).write(to: root.appendingPathComponent("sessions.json"), options: .atomic)
    }
    var parentsStopped: Bool {
        guard let rows = try? rows("process") else { return false }
        return rows.allSatisfy {
            guard case .number(let raw) = $0["pid"], let pid = Int32(exactly: raw), pid > 0 else { return false }
            return kill(pid, 0) == -1 && errno == ESRCH
        }
    }
    func removeIfStopped() throws {
        guard parentsStopped else { throw CoincideError("The generated Muse peer is still alive; its fixture was preserved.") }
        try FileManager.default.removeItem(at: root)
    }
}
private struct MusePeer {
    let fixture: MuseSessionFixture
    let configuration: MuseConfiguration
    let session: MuseSession
    let observed = MuseObserved()
    init(options: [String: JSONValue]) throws {
        fixture = try .init(options: options); configuration = .init(executable: fixture.executable.path)
        session = .init(executable: fixture.executable, cwd: fixture.root, configuration: configuration)
    }
    func thread(model: String? = nil, effort: String? = nil, resume: String? = nil) -> CodingThread {
        var thread = CodingThread(project: .init(path: fixture.root.path))
        thread.provider = .muse; thread.museConfiguration = .init(instanceID: configuration.instanceID, executable: fixture.executable.path,
            model: model.map { .init(modelID: $0) }, reasoningEffort: effort)
        thread.model = thread.museConfiguration?.model?.catalogID ?? ""; thread.providerThreadID = resume
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
        return thread
    }
    func start(_ thread: CodingThread, text: String = "Exact generated input") async throws {
        try await session.send(text: text, thread: thread)
        let id = try #require(thread.activeRun?.id)
        try await museEventually {
            let turn = await observed.turns[id], count = await observed.entities.count
            return turn != nil && count >= 2
        }
    }
}
private func withMuse(_ options: [String: JSONValue] = [:], _ body: (MusePeer) async throws -> Void) async throws {
    let peer = try MusePeer(options: options)
    let consumer = Task { for await event in peer.session.events { await peer.observed.append(event) } }
    do {
        try await body(peer); await peer.session.close(); consumer.cancel(); await consumer.value
        try await museEventually { peer.fixture.parentsStopped }; try peer.fixture.removeIfStopped()
    } catch {
        await peer.session.close(); consumer.cancel(); await consumer.value
        try? peer.fixture.removeIfStopped(); throw error
    }
}
func museEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The task-owned MSP peer did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test func museModelsUseReadOnlyOwnedHostWithoutClaimingLoginOrCreatingSessions() async throws {
    try await withMuse { peer in
        async let first = peer.session.models(), second = peer.session.models()
        let a = try await first, b = try await second
        #expect(a == b && a.count == 2)
        #expect(a[0].museSelection?.modelID == "native-default" && a[0].isDefault)
        #expect(a[1].reasoningEfforts.map(\.id) == ["low", "high"])
        let processes = try peer.fixture.rows("process"), requests = try peer.fixture.rows("request")
        #expect(processes.count == 1 && processes[0]["metadata"] == .bool(true))
        #expect(processes[0]["keyScrubbed"] == .bool(true) && processes[0]["updatesDisabled"] == .bool(true))
        #expect(!requests.contains { ["session/start", "session/resume", "turn/start"].contains($0["method"].string ?? "") })
    }
}

@Test func museACKIdleAndForeignTerminalsNeverAdvanceOwnedRunAndFinalSnapshotsReplaceUTF8Deltas() async throws {
    try await withMuse { peer in
        let thread = peer.thread(); try await peer.start(thread)
        try peer.fixture.signal("foreign"); try await Task.sleep(for: .milliseconds(40))
        let held = await peer.observed.completions; #expect(held.isEmpty)
        try peer.fixture.signal("finish"); try await museEventually { await peer.observed.completions.count == 1 }
        let complete = await peer.observed.completions, entities = await peer.observed.entities
        #expect(complete[0].0 == thread.activeRun?.id && complete[0].1 == .idle)
        #expect(entities.values.contains { $0.text == "Exact 日本語\u{2028}answer" })
        #expect(entities.values.contains { $0.key.type == "tool_call" && $0.text.contains("Exact tool result") })
        #expect(entities.values.contains { $0.fields["rawInput"]["path"] == .string("generated.txt") })
        let sessions = await peer.observed.sessions; #expect(sessions.count == 1 && UUID(uuidString: sessions[0]) != nil)
    }
}

@Test func museTerminalBeforeLostACKAndLateRejectionPreservesHealthySuccessorAndOriginalBackgroundOwner() async throws {
    try await withMuse(["beforeAck": .bool(true), "holdAck": .bool(true), "lateError": .bool(true), "background": .bool(true)]) { peer in
        let first = peer.thread(); try await peer.session.send(text: "First", thread: first)
        try await museEventually { await peer.observed.completions.count == 1 }
        try peer.fixture.set("beforeAck", .bool(false)); try peer.fixture.set("lateError", .bool(false)); try peer.fixture.set("background", .bool(false))
        let second = peer.thread(); try await peer.start(second, text: "Second")
        try peer.fixture.set("holdAck", .bool(false))
        try peer.fixture.signal("childFinish")
        try await museEventually { await peer.observed.entities.values.contains { $0.text.contains("Original child result") } }
        let owners = await peer.observed.entityOwners, entities = await peer.observed.entities
        let child = try #require(entities.values.first { $0.text.contains("Original child result") })
        #expect(owners[child.key] == first.activeRun?.id)
        let failures = await peer.observed.failures; #expect(failures.isEmpty)
        try peer.fixture.signal("finish"); try await museEventually { await peer.observed.completions.count == 2 }
    }
}

@Test func musePrunedTerminalRunCannotCloseHealthySuccessorWhenItsOldCommandIsCancelledOrRepliesLate() async throws {
    try await withMuse(["beforeAck": .bool(true), "holdAck": .bool(true), "lateError": .bool(true)]) { peer in
        let first = peer.thread()
        try await peer.session.send(text: "Terminal before held reply", thread: first)
        try await museEventually { await peer.observed.completions.count == 1 }
        let firstID = try #require(first.activeRun?.id)
        let firstNativeID = try #require(await peer.observed.turns[firstID])
        try peer.fixture.set("beforeAck", .bool(false))
        try peer.fixture.set("lateError", .bool(false))

        // More than two full retained-run windows force the first terminal
        // record to be pruned while its original turn/start is still pending.
        // Pruning cancels only that request, never the current native runtime.
        for number in 0..<34 {
            let next = peer.thread()
            try await peer.start(next, text: "Completed generated run \(number)")
            try peer.fixture.signal("finish")
            try await museEventually { await peer.observed.completions.count == number + 2 }
        }
        let successor = peer.thread()
        try await peer.start(successor, text: "Healthy active successor")
        let before = await peer.observed.failures
        #expect(before.isEmpty)
        try peer.fixture.set("holdAck", .bool(false))
        try await museEventually {
            try peer.fixture.rows("turnReply").contains { $0["commandId"] == .string(firstNativeID) && $0["error"] == .bool(true) }
        }
        // The final terminal follows the recorded late wire reply. A further
        // native read/start round trip proves this actor remains usable.
        try peer.fixture.signal("finish")
        try await museEventually { await peer.observed.completions.count == 36 }
        let last = peer.thread()
        try await peer.start(last, text: "Readback after retired old reply")
        let failures = await peer.observed.failures, completions = await peer.observed.completions
        #expect(failures.isEmpty)
        #expect(completions.last?.0 == successor.activeRun?.id && completions.last?.1 == .idle)
        let prompts = try peer.fixture.rows("prompt")
        #expect(prompts.count == 37)
    }
}

@Test func museCapturedSettingsSurviveFutureHeaderAndDefaultUsesDeclaredCatalogModelAndEffort() async throws {
    try await withMuse { peer in
        var first = peer.thread(model: "selected-model", effort: "high")
        first.museConfiguration = .init(instanceID: UUID(), model: .init(modelID: "never-send"), reasoningEffort: "low")
        first.model = "future"; first.permission = .fullAccess; first.workspacePath = "/future/not-captured"
        try await peer.start(first)
        try peer.fixture.signal("finish"); try await museEventually { await peer.observed.completions.count == 1 }
        try await peer.start(peer.thread(), text: "Default")
        let prompts = try peer.fixture.rows("prompt")
        #expect(prompts.map { $0["model"].string } == ["selected-model", "native-default"])
        #expect(prompts.map { $0["effort"].string } == ["high", "low"])
        #expect(prompts.allSatisfy { $0["profile"] == .string(":ask-me") })
    }
}

@Test(arguments: [false, true])
func museZeroCatalogDefaultsNeverReclassifyAnExplicitOrResumedModelAsNativeDefault(_ freshDefault: Bool) async throws {
    try await withMuse(["noDefault": .bool(true)]) { peer in
        let first = peer.thread(model: freshDefault ? nil : "selected-model")
        try await peer.start(first)
        try peer.fixture.signal("finish"); try await museEventually { await peer.observed.completions.count == 1 }
        if freshDefault {
            // Only a fresh start that actually omitted model provides this
            // native-default baseline. Later explicit selection may reset to it.
            try await peer.start(peer.thread(model: "selected-model"), text: "Explicit")
            try peer.fixture.signal("finish"); try await museEventually { await peer.observed.completions.count == 2 }
            try await peer.start(peer.thread(), text: "Restore proven native default")
            let prompts = try peer.fixture.rows("prompt")
            #expect(prompts.map { $0["model"].string } == ["native-default", "selected-model", "native-default"])
        } else {
            do { try await peer.session.send(text: "Do not pretend explicit A is default", thread: peer.thread()); Issue.record("An explicit baseline was silently treated as Default.") }
            catch { #expect(error.localizedDescription == "Choose a Muse model. The host did not advertise a default for this conversation.") }
            let prompts = try peer.fixture.rows("prompt"), failures = await peer.observed.failures
            #expect(prompts.count == 1 && failures.isEmpty)
        }
    }
}

@Test(arguments: ["missing", "old-broader", "old-matching", "new-override"])
func musePermissionProfileMustBeProvedAndResumeOverrideRequiresKnownContract(_ mode: String) async throws {
    let options: [String: JSONValue] = mode == "missing" ? ["missingProfile": .bool(true)] : ["newProfileContract": .bool(mode == "new-override")]
    try await withMuse(options) { peer in
        let id = "019a0430-0000-7000-8000-000000000001"
        if mode != "missing" { try peer.fixture.seedSession(id: id, profile: mode == "old-matching" ? ":ask-me" : ":unrestricted") }
        let thread = peer.thread(resume: mode == "missing" ? nil : id)
        if mode == "missing" || mode == "old-broader" {
            do { try await peer.session.send(text: "Never under broader authority", thread: thread); Issue.record("Unproven profile was accepted.") }
            catch { #expect(!error.localizedDescription.contains("synthetic-private-token")) }
            let requests = try peer.fixture.rows("request"); #expect(!requests.contains { $0["method"] == .string("turn/start") })
        } else { try await peer.start(thread) }
        let resumes = try peer.fixture.rows("request").filter { $0["method"] == .string("session/resume") }
        if mode != "missing" {
            #expect(resumes.count == 1)
            #expect(resumes[0]["params"]["permissionProfile"] == (mode == "new-override" ? .string(":ask-me") : .null))
        }
    }
}

@Test func museStagedApprovalReplacesLocalTokenAndNativeResolvedBeforeACKCannotResurrectIt() async throws {
    try await withMuse(["interaction": .string("approval"), "staged": .bool(true)]) { peer in
        try await peer.start(peer.thread())
        try await museEventually { await peer.observed.requests.count == 1 }
        let old = try #require(await peer.observed.requests.first)
        try await peer.session.choose(old, optionID: "once")
        try await museEventually { await peer.observed.requests.count == 2 }
        do { try await peer.session.choose(old, optionID: "session"); Issue.record("A stale requirement token was accepted.") } catch {}
        let current = try #require(await peer.observed.requests.last)
        try await peer.session.choose(current, optionID: "session")
        try await museEventually {
            let dismissed = await peer.observed.dismissed.count, requests = await peer.observed.requests.count
            return dismissed == 2 && requests == 2
        }
        let decisions = try peer.fixture.rows("request").filter { $0["method"] == .string("approval/decide") }
        #expect(decisions.map { $0["params"]["requirementId"]["sourceIndex"] } == [.number(0), .number(1)])
        #expect(decisions.map { $0["params"]["choiceId"].string } == ["once", "session"])
        let receipts = try peer.fixture.rows("presentation"); #expect(receipts.contains { $0["id"] == .number(77) && $0["empty"] == .bool(true) })
    }
}

@Test func museQuestionPreservesMultipleSelectionsAndNotesUntilNativeSettlement() async throws {
    try await withMuse(["interaction": .string("question")]) { peer in
        try await peer.start(peer.thread()); try await museEventually { await peer.observed.requests.count == 1 }
        let request = try #require(await peer.observed.requests.first)
        do { try await peer.session.selectAnswers(request, selections: ["approach": ["unoffered"]], notes: [:]); Issue.record("Unoffered answer was sent.") } catch {}
        try await peer.session.selectAnswers(request, selections: ["approach": ["One", "Two"]], notes: ["approach": "Keep exact notes"])
        try await museEventually { await peer.observed.dismissed.contains(request.id) }
        let replies = try peer.fixture.rows("request").filter { $0["method"] == .string("userInput/answer") }
        #expect(replies.count == 1)
        #expect(replies[0]["params"]["answers"].array?.first?["selectedLabels"] == .array([.string("One"), .string("Two")]))
        #expect(replies[0]["params"]["answers"].array?.first?["note"] == .string("Keep exact notes"))
    }
}

@Test(arguments: ["approval", "question"])
func museInteractionACKRetainsRespondingRequestUntilNativeSettlement(_ interaction: String) async throws {
    try await withMuse(["interaction": .string(interaction), "holdInteractionSettlement": .bool(true)]) { peer in
        try await peer.start(peer.thread())
        try await museEventually { await peer.observed.requests.count == 1 }
        let request = try #require(await peer.observed.requests.first)
        if interaction == "approval" { try await peer.session.choose(request, optionID: "once") }
        else { try await peer.session.selectAnswers(request, selections: ["approach": ["One"]]) }
        let afterACK = await peer.observed.dismissed
        #expect(!afterACK.contains(request.id))
        do {
            if interaction == "approval" { try await peer.session.choose(request, optionID: "once") }
            else { try await peer.session.selectAnswers(request, selections: ["approach": ["Two"]]) }
            Issue.record("An acknowledged but unsettled request accepted a duplicate response.")
        } catch {}
        let method = interaction == "approval" ? "approval/decide" : "userInput/answer"
        let responses = try peer.fixture.rows("request").filter { $0["method"] == .string(method) }
        #expect(responses.count == 1)
        try peer.fixture.signal("settle-\(interaction)")
        try await museEventually { await peer.observed.dismissed.contains(request.id) }
        let final = await peer.observed.dismissed, failures = await peer.observed.failures
        #expect(final.filter { $0 == request.id }.count == 1 && failures.isEmpty)
    }
}

@Test func museStopACKDoesNotCompleteUntilExactNativeCancelledTerminal() async throws {
    try await withMuse(["holdInterruptTerminal": .bool(true)]) { peer in
        let thread = peer.thread(); try await peer.start(thread)
        let id = try #require(thread.activeRun?.id), stopping = Task { try await peer.session.interrupt(expectedRunID: id) }
        try await museEventually { try peer.fixture.rows("interrupt").count == 1 }
        let held = await peer.observed.completions; #expect(held.isEmpty)
        try peer.fixture.signal("cancelled"); try await stopping.value
        try await museEventually { await peer.observed.completions.count == 1 }
        let complete = await peer.observed.completions, stops = try peer.fixture.rows("interrupt")
        #expect(complete[0].0 == id && complete[0].1 == .interrupted && stops[0]["exact"] == .bool(true))
    }
}

@Test(arguments: [false, true])
func museStopNativeTerminalWinsHeldOldACKOrErrorAndPreservesHealthySuccessor(_ lateError: Bool) async throws {
    try await withMuse(["interruptBeforeReply": .bool(true), "holdInterruptReply": .bool(true), "interruptLateError": .bool(lateError)]) { peer in
        let first = peer.thread()
        try await peer.start(first)
        let firstID = try #require(first.activeRun?.id)
        let stopping = Task {
            try await peer.session.interrupt(expectedRunID: firstID)
            await peer.observed.stopReturned()
        }
        defer { stopping.cancel() }
        try await museEventually {
            let returned = await peer.observed.returnedStops, completions = await peer.observed.completions.count
            return returned == 1 && completions == 1
        }
        try await stopping.value
        let beforeReply = try peer.fixture.rows("interruptReply")
        #expect(beforeReply.isEmpty)
        let successor = peer.thread()
        try await peer.start(successor, text: "Successor while old Stop reply is held")
        try peer.fixture.set("holdInterruptReply", .bool(false))
        try await museEventually { try peer.fixture.rows("interruptReply").count == 1 }
        try peer.fixture.signal("finish")
        try await museEventually { await peer.observed.completions.count == 2 }
        try await peer.start(peer.thread(), text: "Healthy after old Stop reply")
        let completions = await peer.observed.completions, failures = await peer.observed.failures
        #expect(completions[0].0 == firstID && completions[0].1 == .interrupted)
        #expect(completions[1].0 == successor.activeRun?.id && completions[1].1 == .idle)
        #expect(failures.isEmpty)
        let replies = try peer.fixture.rows("interruptReply")
        #expect(replies[0]["error"] == .bool(lateError))
    }
}

@Test func museStopDuringHeldModelPreparationRetiresUncertainMutationBeforeSuccessor() async throws {
    try await withMuse { peer in
        let first = peer.thread(); try await peer.start(first)
        try peer.fixture.signal("finish"); try await museEventually { await peer.observed.completions.count == 1 }
        try peer.fixture.set("holdModel", .bool(true))
        let sending = Task { try await peer.session.send(text: "Must not post", thread: peer.thread(model: "selected-model", effort: "high")) }
        try await museEventually { try peer.fixture.rows("request").contains { $0["method"] == .string("session/setModel") } }
        do { try await peer.session.interrupt() } catch {}
        do { try await sending.value; Issue.record("Uncertain model change accepted its prompt.") } catch {}
        do { try await peer.session.send(text: "Unsafe successor", thread: peer.thread()); Issue.record("Stopped configuration runtime was reused.") } catch {}
        let requests = try peer.fixture.rows("request")
        #expect(requests.filter { $0["method"] == .string("turn/start") }.count == 1)
    }
}

@Test func museStopWithoutNativeAdmissionEvidenceClosesHostWithoutClaimingCompletion() async throws {
    try await withMuse(["holdAdmission": .bool(true)]) { peer in
        try await peer.session.send(text: "Unknown admission", thread: peer.thread())
        try await museEventually { try peer.fixture.rows("request").contains { $0["method"] == .string("turn/start") } }
        do { try await peer.session.interrupt(); Issue.record("Unknown admission was reported as a confirmed Stop.") } catch {}
        try await museEventually { await !peer.observed.failures.isEmpty }
        let complete = await peer.observed.completions; #expect(complete.isEmpty)
    }
}

@Test(arguments: ["gap", "exit", "flood"])
func museGapEOFAndNotificationOverflowFailClosedWithoutManufacturedCompletion(_ signal: String) async throws {
    try await withMuse { peer in
        try await peer.start(peer.thread()); try peer.fixture.signal(signal)
        var floodAcknowledged = 0
        try await museEventually {
            if signal == "flood" {
                let presented = await peer.observed.requests.count
                if presented > floodAcknowledged {
                    try peer.fixture.set("floodAcknowledged", .number(Double(presented)))
                    floodAcknowledged = presented
                }
            }
            return await !peer.observed.failures.isEmpty
        }
        let completed = await peer.observed.completions; #expect(completed.isEmpty)
        if signal == "flood" {
            let presented = await peer.observed.requests.count
            let floods = try peer.fixture.rows("notificationFlood")
            let flood = try #require(floods.first)
            #expect(presented == 64 && flood["type"] == .string("pending-approval") && flood["count"] == .number(65),
                    "Exactly the bounded pending registry is filled before overflow; consumer speed is not a failure condition.")
        }
        do { try await peer.session.send(text: "No blind replay", thread: peer.thread()); Issue.record("Broken native host was reused.") } catch {}
    }
}
