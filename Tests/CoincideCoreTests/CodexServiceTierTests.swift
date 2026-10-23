import Foundation
import Testing
@testable import CoincideCore

private func serviceTierNativeModel(_ id: String = "wire-model", tiers: [String] = ["priority", "ultrafast"]) -> JSONValue {
    .object(["id": .string("catalog-" + id), "model": .string(id), "displayName": .string("Private advertised model"),
        "supportedReasoningEfforts": .array([]), "serviceTiers": .array(tiers.map { tier in
            .object(["id": .string(tier), "name": .string(tier.capitalized), "description": .string("Native advertised tier")])
        })])
}

@Test func codexServiceTierSelectionUsesExactNativeIDsLegacyFastPrecedenceAndAtomicModelGuard() throws {
    let model = try CodexModelCatalogEntry(serviceTierNativeModel()).model
    var thread = CodingThread(project: .init(path: "/private/controlled"), model: model.id)
    thread.draft = "Literal private composer\n "; thread.reasoningEffort = "high"
    thread.agentConfiguration = ["other": .string("Preserved field")]
    try thread.selectCodexServiceTier(model: model, tier: "priority")
    #expect(try CodexServiceTier.selected(in: .init(thread: thread)) == "priority")
    #expect(thread.draft == "Literal private composer\n " && thread.reasoningEffort == "high")
    #expect(thread.agentConfiguration?["other"] == .string("Preserved field"))
    try thread.selectCodexServiceTier(model: model, tier: "default")
    #expect(try CodexServiceTier.selected(in: .init(thread: thread)) == "default")
    try thread.selectCodexServiceTier(model: model, tier: "fast")
    #expect(try CodexServiceTier.selected(in: .init(thread: thread)) == "fast")
    try thread.selectCodexServiceTier(model: model, tier: nil)
    #expect(thread.agentConfiguration == ["other": .string("Preserved field")])
    var captured = ProviderConfiguration(thread: thread)
    captured.agentConfiguration = [CodexServiceTier.configurationKey: .object(["fastMode": .bool(true)])]
    #expect(try CodexServiceTier.selected(in: captured) == "fast")
    captured.agentConfiguration = [CodexServiceTier.configurationKey: .object(["fastMode": .bool(true), "serviceTier": .string("ultrafast")])]
    #expect(try CodexServiceTier.selected(in: captured) == "ultrafast")
    let before = thread
    #expect(throws: (any Error).self) { try thread.selectCodexServiceTier(model: model, tier: "not-advertised") }
    #expect(thread == before)
    var changed = model; changed.id = "other-model"
    #expect(throws: (any Error).self) { try thread.selectCodexServiceTier(model: changed, tier: "priority") }
    #expect(thread == before)
    let invalidValues: [JSONValue] = [.string("priority"), .object(["serviceTier": .string("bad tier")]),
        .object(["fastMode": .number(1)]), .object(["serviceTier": .null]), .object(["launch": .string("untrusted")])]
    for raw in invalidValues {
        captured.agentConfiguration = [CodexServiceTier.configurationKey: raw]
        #expect(throws: CoincideError.self) { _ = try CodexServiceTier.selected(in: captured) }
    }
}

private struct ServiceTierPeer {
    let root: URL
    let session: CodexSession
    let runtime: CodexRuntimeConfiguration?
    init(_ values: [String: JSONValue], owned: Bool = false) throws {
        root = try temporaryWorkspace()
        try JSONEncoder().encode(JSONValue.object(values)).write(to: root.appendingPathComponent("options.json"))
        runtime = owned ? .init(homeDirectory: root.appendingPathComponent("private-owned-home").path, authenticationMode: .ownedChatGPT) : nil
        let source = try #require(Bundle.module.url(forResource: "codex_service_tier", withExtension: "py", subdirectory: "Fixtures"))
        session = try CodexSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root,
            arguments: [source.path, root.path], runtimeConfiguration: runtime)
    }
    func options(_ values: [String: JSONValue]) throws {
        try JSONEncoder().encode(JSONValue.object(values)).write(to: root.appendingPathComponent("options.json"), options: .atomic)
    }
    func frames() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("wire.jsonl").path) else { return [] }
        return try Data(contentsOf: root.appendingPathComponent("wire.jsonl")).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func thread(tier: String? = nil, native: String? = nil) throws -> CodingThread {
        var thread = CodingThread(project: .init(path: root.path), model: "wire-model")
        thread.codexRuntimeConfiguration = runtime; thread.providerThreadID = native
        thread.agentConfiguration = try CodexServiceTier.setting(tier, in: nil)
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
        return thread
    }
}
private actor ServiceTierObservation {
    var completed = 0
    var replies: [String] = []
    func append(_ value: ProviderEvent) {
        if case .context(_, let inner) = value { append(inner); return }
        if case .completed = value { completed += 1 }
        if case .message(let message) = value, message.role == .assistant { replies.append(message.text) }
    }
}
private func withServiceTierPeer(_ options: [String: JSONValue] = ["models": .array([serviceTierNativeModel()])], owned: Bool = false,
                                 _ body: (ServiceTierPeer, ServiceTierObservation) async throws -> Void) async throws {
    let peer = try ServiceTierPeer(options, owned: owned), observed = ServiceTierObservation()
    defer { try? FileManager.default.removeItem(at: peer.root) }
    let reader = Task { for await event in peer.session.events { await observed.append(event) } }
    do { try await body(peer, observed); await peer.session.close(); await reader.value }
    catch { await peer.session.close(); await reader.value; throw error }
}
private func serviceTierEventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private service-tier peer did not reach its expected boundary") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1))) func codexServiceTierOpeningValidatesFreshNativeCatalogAndUsesActiveCapturedSettings() async throws {
    try await withServiceTierPeer { peer, observed in
        var thread = try peer.thread(tier: "priority")
        thread.agentConfiguration = try CodexServiceTier.setting("ultrafast", in: nil); thread.model = "future-header-model"
        try await peer.session.send(text: "  Exact authored e\u{301}\n ", thread: thread)
        try await serviceTierEventually { await observed.completed == 1 }
        let frames = try peer.frames(), modelRead = try #require(frames.firstIndex { $0["method"] == .string("model/list") })
        let threadStart = try #require(frames.firstIndex { $0["method"] == .string("thread/start") })
        #expect(modelRead < threadStart)
        let turn = try #require(frames.first { $0["method"] == .string("turn/start") })
        #expect(turn["params"]["model"] == .string("wire-model") && turn["params"]["serviceTier"] == .string("priority"))
        #expect(turn["params"]["input"].array?.first?["text"] == .string("  Exact authored e\u{301}\n "))
        #expect(await observed.replies == ["priority"])
        try peer.options(["models": .array([serviceTierNativeModel(tiers: ["ultrafast"])])])
        await #expect(throws: CoincideError.self) { try await peer.session.send(text: "Do not fall back when current catalog changes", thread: peer.thread(tier: "priority")) }
        #expect(try peer.frames().filter { $0["method"] == .string("model/list") }.count == 2)
        #expect(try peer.frames().filter { $0["method"] == .string("turn/start") }.count == 1)
    }
}

@Test(.timeLimit(.minutes(1))) func codexServiceTierResetClearsOnlyOwnStickyTierAndExplicitStandardUsesDefaultString() async throws {
    try await withServiceTierPeer { peer, observed in
        try await peer.session.send(text: "Priority", thread: peer.thread(tier: "priority"))
        try await serviceTierEventually { await observed.completed == 1 }
        try await peer.session.send(text: "Use native defaults", thread: peer.thread())
        try await serviceTierEventually { await observed.completed == 2 }
        try await peer.session.send(text: "Explicit standard", thread: peer.thread(tier: "default"))
        try await serviceTierEventually { await observed.completed == 3 }
        let frames = try peer.frames(), turns = frames.filter { $0["method"] == .string("turn/start") }
        #expect(turns.map { $0["params"]["serviceTier"] } == [.string("priority"), .null, .string("default")])
        #expect(turns[1]["params"].object?.keys.contains("serviceTier") == true)
        #expect(frames.filter { $0["method"] == .string("model/list") }.count == 2)
        #expect(await observed.replies == ["priority", "native-config-default", "default"])
    }
}

@Test(.timeLimit(.minutes(1))) func codexServiceTierUnconfiguredDefaultDoesNotReadCatalogOrOverrideNativeCLIChoices() async throws {
    try await withServiceTierPeer(["initialTier": .string("cli-owned-tier")]) { peer, observed in
        try await peer.session.send(text: "Unconfigured default", thread: peer.thread(native: "resumed-cli-conversation"))
        try await serviceTierEventually { await observed.completed == 1 }
        let frames = try peer.frames(), turn = try #require(frames.first { $0["method"] == .string("turn/start") })
        #expect(!frames.contains { $0["method"] == .string("model/list") })
        #expect(turn["params"].object?.keys.contains("serviceTier") == false)
        #expect(await observed.replies == ["cli-owned-tier"])
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["missing", "changed-model", "malformed", "rpc-error"])
func codexServiceTierUnadvertisedOrMalformedFreshMetadataRefusesBeforeNativeConversationOrUserTurn(kind: String) async throws {
    var options: [String: JSONValue] = ["models": .array([serviceTierNativeModel()])]
    if kind == "missing" { options["models"] = .array([serviceTierNativeModel(tiers: [])]) }
    if kind == "changed-model" { options["models"] = .array([serviceTierNativeModel("other-model")]) }
    if kind == "malformed" { options["models"] = .array([serviceTierNativeModel(tiers: ["priority", "priority"])]) }
    if kind == "rpc-error" { options["catalogError"] = .bool(true) }
    try await withServiceTierPeer(options) { peer, _ in
        do { try await peer.session.send(text: "Must remain unsent", thread: peer.thread(tier: "priority")); Issue.record("Unadvertised tier reached a native turn") }
        catch { #expect(!error.localizedDescription.contains("PRIVATE-TIER-ERROR-MUST-NOT-LEAK")) }
        let frames = try peer.frames()
        #expect(!frames.contains { ["thread/start", "thread/resume", "turn/start"].contains($0["method"].string ?? "") })
    }
}

@Test(.timeLimit(.minutes(1))) func codexServiceTierOwnedModeHidesTiersAndRejectsSelectionWithoutSendingOrAccountCalls() async throws {
    try await withServiceTierPeer(owned: true) { peer, observed in
        let models = try await peer.session.models()
        #expect(models.count == 1 && models[0].codexServiceTiers == nil)
        await #expect(throws: CoincideError.self) { try await peer.session.send(text: "Owned mode cannot choose a tier", thread: peer.thread(tier: "priority")) }
        try await peer.session.send(text: "Owned mode default", thread: peer.thread())
        try await serviceTierEventually { await observed.completed == 1 }
        let frames = try peer.frames(), turn = try #require(frames.first { $0["method"] == .string("turn/start") })
        #expect(frames.filter { $0["method"] == .string("model/list") }.count == 1)
        #expect(turn["params"].object?.keys.contains("serviceTier") == false)
        #expect(!frames.contains { ($0["method"].string ?? "").hasPrefix("account/") })
    }
}

@Test(.timeLimit(.minutes(1))) func codexServiceTierCloseDrainsHeldCatalogBeforeAnyUserTurn() async throws {
    try await withServiceTierPeer(["models": .array([serviceTierNativeModel()]), "holdCatalog": .bool(true)]) { peer, _ in
        let thread = try peer.thread(tier: "priority"), sending = Task { try await peer.session.send(text: "Held input", thread: thread) }
        try await serviceTierEventually { FileManager.default.fileExists(atPath: peer.root.appendingPathComponent("catalog-entered").path) }
        await peer.session.close()
        await #expect(throws: (any Error).self) { try await sending.value }
        let frames = try peer.frames()
        #expect(!frames.contains { ["thread/start", "thread/resume", "turn/start"].contains($0["method"].string ?? "") })
    }
}

@Test(.timeLimit(.minutes(1))) func codexServiceTierSteeringKeepsActiveTierAndRejectsFutureHeaderWithoutNewCatalogOrTierOverride() async throws {
    try await withServiceTierPeer(["models": .array([serviceTierNativeModel()]), "keepRunning": .bool(true)]) { peer, observed in
        var thread = try peer.thread(tier: "priority")
        try await peer.session.send(text: "Initial priority turn", thread: thread)
        thread.providerThreadID = "tier-thread"; thread.activeRun?.nativeTurnID = "tier-turn-1"
        var future = thread; future.agentConfiguration = try CodexServiceTier.setting("ultrafast", in: nil)
        await #expect(throws: ProviderSteeringError.self) { _ = try await peer.session.steer(input: .init(text: "Wrong future tier"), thread: future, expectedTurnID: "tier-turn-1", clientMessageID: "future-user") }
        let receipt = try await peer.session.steer(input: .init(text: "Steer with active settings"), thread: thread, expectedTurnID: "tier-turn-1", clientMessageID: "active-user")
        #expect(receipt.turnID == "tier-turn-1")
        let frames = try peer.frames(), steering = try #require(frames.first { $0["method"] == .string("turn/steer") })
        #expect(Set(steering["params"].object?.keys.map { $0 } ?? []) == ["threadId", "expectedTurnId", "clientUserMessageId", "input"])
        #expect(frames.filter { $0["method"] == .string("model/list") }.count == 1)
        try await peer.session.interrupt()
        try await serviceTierEventually { await observed.completed == 1 }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["same-native", "foreign-native", "foreign-runtime"])
func codexServiceTierRestartResetUsesOnlyOwnMatchingTerminalNativeRunProof(scope: String) async throws {
    try await withServiceTierPeer(["models": .array([serviceTierNativeModel()]), "initialTier": .string("priority")]) { peer, observed in
        var thread = try peer.thread(native: "resumed-tier-thread"), prior = try peer.thread(tier: "priority", native: "resumed-tier-thread")
        if scope == "foreign-runtime" { prior.codexRuntimeConfiguration = .init(instanceID: UUID()) }
        let previousRun = ActiveRun(id: UUID(), configuration: .init(thread: prior), startedAt: .now)
        var record = ThreadRunRecord(run: previousRun, origin: .user)
        record.status = .completed; record.providerThreadID = scope == "foreign-native" ? "unrelated-native-thread" : "resumed-tier-thread"
        record.turnIDs = ["prior-owned-turn"]
        let current = try #require(thread.activeRun)
        thread.runHistory = [record, ThreadRunRecord(run: current, origin: .user)]
        try await peer.session.send(text: "Fresh explicit input after restart", thread: thread)
        try await serviceTierEventually { await observed.completed == 1 }
        let frames = try peer.frames(), turn = try #require(frames.first { $0["method"] == .string("turn/start") })
        #expect(turn["params"].object?.keys.contains("serviceTier") == (scope == "same-native"))
        #expect(!frames.contains { $0["method"] == .string("model/list") })
        #expect(await observed.replies == [scope == "same-native" ? "native-config-default" : "priority"])
    }
}
