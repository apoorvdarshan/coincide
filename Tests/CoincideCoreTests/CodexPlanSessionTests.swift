import Foundation
import Testing
@testable import CoincideCore

private actor CodexPlanObserved {
    private(set) var completions: [UUID?] = []
    private(set) var failures = 0
    private(set) var metadata: JSONValue = .null
    private(set) var entities: [ProviderEntityKey: ProviderEntity] = [:]
    private(set) var owners: [ProviderEntityKey: UUID] = [:]
    private(set) var revisions: [ProviderEntityKey: Int] = [:]
    func append(_ event: ProviderEvent, owner: UUID? = nil) {
        switch event {
        case .context(let run, let nested): append(nested, owner: run)
        case .entity(let update): apply(update, owner: owner)
        case .runEntity(let run, let update): apply(update, owner: run)
        case .completed: completions.append(owner)
        case .failure, .connectionClosed: failures += 1
        case .configuration(let value): metadata = value
        default: break
        }
    }
    private func apply(_ update: ProviderEntityUpdate, owner: UUID?) {
        entities[update.key] = try? update.apply(to: entities[update.key])
        owners[update.key] = owner; revisions[update.key, default: 0] += 1
    }
}
private struct CodexPlanPeer {
    let root: URL
    let session: CodexSession
    func thread(mode: String? = nil, model: String = "wire-model", native: String? = nil) -> CodingThread {
        var thread = CodingThread(project: .init(path: root.path), model: model)
        thread.agentModeID = mode; thread.reasoningEffort = "high"; thread.providerThreadID = native
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
        return thread
    }
    func set(_ options: [String: JSONValue]) throws {
        try JSONEncoder().encode(JSONValue.object(options)).write(to: root.appendingPathComponent("options.json"), options: .atomic)
    }
    func frames() throws -> [JSONValue] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("wire.jsonl")), let end = data.lastIndex(of: 10) else { return [] }
        return try data[...end].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
}
private func withCodexPlanPeer(_ options: [String: JSONValue] = [:], _ body: (CodexPlanPeer, CodexPlanObserved) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-codex-plan-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    try JSONEncoder().encode(JSONValue.object(options)).write(to: root.appendingPathComponent("options.json"))
    let fixture = try #require(Bundle.module.url(forResource: "codex_plans", withExtension: "py", subdirectory: "Fixtures"))
    let session = try CodexSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root, arguments: [fixture.path, root.path])
    let peer = CodexPlanPeer(root: root, session: session), observed = CodexPlanObserved()
    let reader = Task { for await event in session.events { await observed.append(event) } }
    do { try await body(peer, observed); await session.close(); await reader.value }
    catch { await session.close(); await reader.value; throw error }
}
private func codexPlanEventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private native plan peer did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func codexPlanNativeItemsReplaceDeltasAndRetainOriginalTurnOwnershipAcrossSuccessorRuns() async throws {
    try await withCodexPlanPeer(["holdTurn": .bool(true)]) { peer, observed in
        let first = peer.thread(mode: "plan")
        try await peer.session.send(text: "Original authored input", thread: first)
        try await codexPlanEventually { await observed.entities.count == 2 }
        let initial = await observed.entities
        let plan = try #require(initial.values.first { $0.fields["nativeKind"] == .string("proposed_plan") })
        let todo = try #require(initial.values.first { $0.fields["nativeKind"] == .string("todo_list") })
        #expect(plan.fields["content"].string?.utf8.elementsEqual("# Final e\u{301} plan 1\n\nImplement exact source.\n".utf8) == true)
        #expect(plan.fields["status"] == .string("completed") && todo.fields["content"] == .null && todo.fields["entries"].array?.count == 2)
        let revisions = await observed.revisions
        #expect(revisions[plan.key] == 4, "Start, two deltas and one final snapshot; repeated final and late delta are inert.")
        try await peer.session.interrupt()
        try await codexPlanEventually { await observed.completions.count == 1 }
        let second = peer.thread(mode: "default", native: "plan-thread")
        try await peer.session.send(text: "Explicit implementation input", thread: second)
        try peer.set(["holdTurn": .bool(true), "signal": .string("late-original")])
        try await codexPlanEventually { await observed.entities.values.contains { $0.fields["nativeItemID"] == .string("late-native-item") } }
        let entities = await observed.entities, owners = await observed.owners
        let plans = entities.values.filter { $0.fields["nativeItemID"] == .string("plan-item") }
        #expect(plans.count == 2 && Set(plans.compactMap { owners[$0.key] }) == Set([first.activeRun!.id, second.activeRun!.id]))
        let late = try #require(entities.values.first { $0.fields["nativeItemID"] == .string("late-native-item") })
        #expect(owners[late.key] == first.activeRun?.id)
        #expect(!entities.values.contains { $0.fields["nativeItemID"] == .string("foreign-item") || $0.fields["nativeItemID"] == .string("unowned-item") })
        #expect(await observed.failures == 0)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["orphan-delta", "oversized", "conflicting-final", "oversized-todos"])
func codexPlanMalformedOwnedStreamsFailClosedWithoutCompletingOrReplayingInput(scenario: String) async throws {
    try await withCodexPlanPeer(["scenario": .string(scenario)]) { peer, observed in
        let thread = peer.thread(mode: "plan")
        do { try await peer.session.send(text: "Only one original input", thread: thread) } catch {}
        try await codexPlanEventually { await observed.failures > 0 }
        #expect(await observed.completions.isEmpty)
        do { try await peer.session.send(text: "No implicit replay", thread: peer.thread()); Issue.record("A broken plan stream was reused") } catch {}
        let frames = try peer.frames()
        #expect(frames.filter { $0["method"] == .string("turn/start") }.count == 1)
    }
}

@Test(.timeLimit(.minutes(1)))
func codexPlanModeUsesCapturedModelEffortPermissionAndKeepsContextImagesAndDraftLiteral() async throws {
    try await withCodexPlanPeer(["holdTurn": .bool(true)]) { peer, observed in
        var thread = peer.thread(mode: "plan")
        thread.providerMetadata = .object(["existingSibling": .string("kept")])
        thread.draft = "Unsent composer e\u{301}  \n"
        thread.agentModeID = "default"; thread.model = "future-header-model"; thread.reasoningEffort = "low"; thread.permission = .fullAccess
        var input = try contextHandoffTestInput()
        input.images = [.init(mimeType: "image/png", data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7f8AAAAASUVORK5CYII=")!)]
        try await peer.session.send(input: input, thread: thread)
        let frames = try peer.frames(), start = try #require(frames.first { $0["method"] == .string("turn/start") })
        let mode = start["params"]["collaborationMode"]
        #expect(mode["mode"] == .string("plan") && mode["settings"]["model"] == .string("wire-model") && mode["settings"]["reasoning_effort"] == .string("high"))
        #expect(mode["settings"]["developer_instructions"].string?.contains("<proposed_plan>") == true)
        #expect(mode["settings"]["developer_instructions"].string?.contains(input.text) == false)
        #expect(start["params"]["approvalPolicy"] == PermissionMode.supervised.approvalPolicy)
        #expect(start["params"]["sandboxPolicy"] == PermissionMode.supervised.sandbox(cwd: peer.root.path))
        var text: [String] = []
        for block in start["params"]["input"].array ?? [] where block["type"] == .string("text") {
            if let value = block["text"].string { text.append(value) }
        }
        let expected = try input.providerTextBlocks()
        #expect(text == expected && text.last?.utf8.elementsEqual(input.text.utf8) == true)
        #expect(start["params"]["input"].array?.last?["type"] == .string("image"))
        #expect(thread.draft.utf8.elementsEqual("Unsent composer e\u{301}  \n".utf8))
        try await codexPlanEventually { await observed.metadata["codexInteractionModes"]["supported"] == .bool(true) }
        #expect(await observed.metadata["existingSibling"] == .string("kept"))
        #expect(!frames.contains { $0["method"] == .string("model/list") || $0["method"] == .string("config/read") })
    }
}

@Test(.timeLimit(.minutes(1)))
func codexPlanToExplicitDefaultAndNilResetNeverMutatesTheActiveSteeringModeOrPermissions() async throws {
    try await withCodexPlanPeer(["holdTurn": .bool(true)]) { peer, observed in
        var active = peer.thread(mode: "plan")
        try await peer.session.send(text: "Plan input", thread: active)
        active.providerThreadID = "plan-thread"; active.activeRun?.nativeTurnID = "plan-turn-1"
        active.agentModeID = "default" // future header choice, active capture stays Plan
        do {
            _ = try await peer.session.steer(input: .init(text: "Must not apply the future mode"), thread: active,
                expectedTurnID: "plan-turn-1", clientMessageID: "user-" + UUID().uuidString)
            Issue.record("The future mode was silently applied to an active turn")
        } catch let error as ProviderSteeringError { #expect(error.kind == .staleTarget) }
        active.agentModeID = "plan"
        let steering = try await peer.session.steer(input: .init(text: "Literal steer"), thread: active,
            expectedTurnID: "plan-turn-1", clientMessageID: "user-" + UUID().uuidString)
        #expect(steering.turnID == "plan-turn-1")
        try await peer.session.interrupt()
        try await codexPlanEventually { await observed.completions.count == 1 }
        let next = peer.thread(mode: "default", native: "plan-thread")
        try await peer.session.send(text: "Explicit implementation", thread: next)
        try await peer.session.interrupt()
        try await codexPlanEventually { await observed.completions.count == 2 }
        try await peer.session.send(text: "CLI intent after our own mode", thread: peer.thread(native: "plan-thread"))
        let frames = try peer.frames(), starts = frames.filter { $0["method"] == .string("turn/start") }
        #expect(starts.map { $0["params"]["collaborationMode"]["mode"] } == [.string("plan"), .string("default"), .string("default")])
        #expect(starts.allSatisfy { $0["params"]["approvalPolicy"] == PermissionMode.supervised.approvalPolicy })
        let steers = frames.filter { $0["method"] == .string("turn/steer") }
        #expect(steers.count == 1 && steers[0]["params"]["collaborationMode"] == .null && steers[0]["params"]["model"] == .null)
        #expect(starts[1]["params"]["collaborationMode"]["settings"]["developer_instructions"].string?.contains("# Collaboration Mode: Default") == true)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codexInteractionModeNilBaselineAddsNoRPCOrOverrideWhileExplicitEmptyModelUsesNativeDefaults(explicit: Bool) async throws {
    try await withCodexPlanPeer { peer, observed in
        var thread = peer.thread(mode: explicit ? "plan" : nil, model: "")
        thread.reasoningEffort = nil
        let configuration = ProviderConfiguration(thread: thread); thread.activeRun?.configuration = configuration
        try await peer.session.send(text: "A safe model default input", thread: thread)
        try await codexPlanEventually { await observed.completions.count == 1 }
        let frames = try peer.frames(), start = try #require(frames.first { $0["method"] == .string("turn/start") })
        if explicit {
            #expect(start["params"]["collaborationMode"]["settings"]["model"] == .string("wire-model"))
            #expect(start["params"]["collaborationMode"]["settings"]["reasoning_effort"] == .string("high"))
            #expect(frames.filter { $0["method"] == .string("config/read") }.count == 2)
            #expect(frames.filter { $0["method"] == .string("model/list") }.count == 1)
        } else {
            #expect(start["params"]["collaborationMode"] == .null)
            #expect(!frames.contains { $0["method"] == .string("config/read") || $0["method"] == .string("model/list") })
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func codexInteractionModeUnreviewedProfileRefusesExplicitModeBeforeConversationAndPreservesOrdinaryDefault() async throws {
    try await withCodexPlanPeer(["userAgent": .string("codex/9.0.0")]) { peer, observed in
        do { try await peer.session.send(text: "Unsupported mode", thread: peer.thread(mode: "plan")); Issue.record("An unreviewed mode profile was accepted") }
        catch { #expect(error.localizedDescription.contains("does not support the reviewed Plan")) }
        let refused = try peer.frames()
        #expect(!refused.contains { $0["method"] == .string("thread/start") || $0["method"] == .string("turn/start") })
        try await peer.session.send(text: "Ordinary CLI default", thread: peer.thread())
        try await codexPlanEventually { await observed.completions.count == 1 }
        #expect(await observed.metadata["codexInteractionModes"]["supported"] == .bool(false))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["PLAN", "default ", "custom", "", "plan\n"])
func codexInteractionModeRejectsUnsupportedCapturedIDsWithoutNativeRequests(mode: String) async throws {
    try await withCodexPlanPeer { peer, _ in
        do { try await peer.session.send(text: "Must stay unsent", thread: peer.thread(mode: mode)); Issue.record("An unsupported interaction mode was accepted") }
        catch { #expect(error.localizedDescription == CodexInteractionMode.invalid().localizedDescription) }
        let frames = try peer.frames(); #expect(frames.isEmpty)
    }
}

@Test func codexPlanProjectionUsesExactUTF8ItemKeysAndRefusesActiveStateOverflowWithoutGuessingCompletion() throws {
    var projection = CodexPlanProjection()
    func params(_ id: String, turn: String = "turn", text: String = "") -> JSONValue {
        .object(["threadId": .string("session"), "turnId": .string(turn), "item": .object(["type": .string("plan"), "id": .string(id), "text": .string(text)])])
    }
    let a = try projection.project("item/started", params: params("café"), sessionID: "session")
    let b = try projection.project("item/started", params: params("cafe\u{301}"), sessionID: "session")
    #expect(a?.key != b?.key)
    for index in 2..<CodexPlanProjection.maximumItems {
        _ = try projection.project("item/started", params: params("active-\(index)"), sessionID: "session")
    }
    #expect(throws: CoincideError.self) { _ = try projection.project("item/started", params: params("overflow"), sessionID: "session") }
    let terminal = projection.terminal(turnID: "turn")
    #expect(terminal.count == CodexPlanProjection.maximumItems)
    let entities = try terminal.map { try $0.apply(to: nil) }
    #expect(entities.allSatisfy { $0.fields["status"] == .string("unknown") })
    _ = try projection.project("item/started", params: params("fresh-after-terminal", turn: "next-turn"), sessionID: "session")
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codexInteractionModeModelCatalogCapabilitiesComeFromInitializedNativeProfileWithoutStartingAConversation(supported: Bool) async throws {
    try await withCodexPlanPeer(["userAgent": .string(supported ? "coincide/0.163.0" : "coincide/0.999.0")]) { peer, _ in
        let models = try await peer.session.models()
        #expect(!models.isEmpty)
        if supported { #expect(models.allSatisfy { $0.codexInteractionModes == [.default, .plan] }) }
        else { #expect(models.allSatisfy { $0.codexInteractionModes == nil }) }
        let frames = try peer.frames()
        #expect(frames.filter { $0["method"] == .string("model/list") }.count == 1)
        #expect(!frames.contains { $0["method"] == .string("thread/start") || $0["method"] == .string("thread/resume") || $0["method"] == .string("turn/start") })
    }
}
