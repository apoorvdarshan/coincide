import Foundation
import Testing
@testable import CoincideCore

private actor ReasoningEvents {
    private(set) var completions = 0
    func append(_ event: ProviderEvent) {
        if case .context(_, let inner) = event { append(inner); return }
        if case .completed = event { completions += 1 }
    }
}

private func reasoningEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The offline reasoning fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func reasoningCatalogModel(_ id: String = "wire-model", isDefault: Bool = true) -> JSONValue {
    .object(["id": .string("catalog-" + id), "model": .string(id), "isDefault": .bool(isDefault),
             "defaultReasoningEffort": .string("medium"), "supportedReasoningEfforts": .array([
                .object(["reasoningEffort": .string("medium"), "description": .string("Model default")]),
                .object(["reasoningEffort": .string("high"), "description": .string("Deeper reasoning")])])])
}

@Test(.timeLimit(.minutes(1)), arguments: ["fresh", "resumed", "legacy"])
func codexReasoningNormalTurnsSendCapturedEffortAndDetailedSummariesWithoutThreadOverrides(kind: String) async throws {
    try await withCatalogPeer([:]) { peer in
        var thread = CodingThread(project: .init(path: peer.root.path), model: "explicit-wire-model")
        thread.reasoningEffort = kind == "legacy" ? nil : "future-super-effort"
        if kind == "resumed" { thread.providerThreadID = "existing-native-thread" }
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
        try await peer.session.send(text: "A captured normal turn", thread: thread)
        let frames = try peer.frames()
        let start = try #require(frames.first { $0["method"] == .string(kind == "resumed" ? "thread/resume" : "thread/start") })
        let turn = try #require(frames.first { $0["method"] == .string("turn/start") })
        #expect(start["params"]["effort"] == .null && start["params"]["reasoningEffort"] == .null)
        #expect(start["params"]["config"] == .null)
        #expect(turn["params"]["effort"] == (kind == "legacy" ? .null : .string("future-super-effort")))
        #expect(turn["params"]["summary"] == .string("detailed"))
        #expect(turn["params"]["model"] == .string("explicit-wire-model"))
        #expect(turn["params"]["reasoningEffort"] == .null && turn["params"]["reasoning_effort"] == .null)
        #expect(frames.allSatisfy { !($0["method"].string ?? "").contains("write") })
    }
}

@Test(.timeLimit(.minutes(1)))
func codexReasoningModelDefaultResetIsExplicitOnTheNextTurnWhileSteeringKeepsTheActiveEffort() async throws {
    let options: [String: JSONValue] = ["cliConfig": .object(["model": .string("wire-model"), "model_reasoning_effort": .null]),
        "pages": .object(["": .object(["data": .array([reasoningCatalogModel()])])])]
    try await withCatalogPeer(options) { peer in
        let observed = ReasoningEvents(), stream = peer.session.events
        let reader = Task { for await event in stream { await observed.append(event) } }
        do {
            var active = CodingThread(project: .init(path: peer.root.path), model: "wire-model")
            active.reasoningEffort = "high"
            active.activeRun = .init(id: UUID(), configuration: .init(thread: active), startedAt: .now)
            try await peer.session.send(text: "Initial high-effort input", thread: active)
            active.providerThreadID = "catalog-thread"; active.activeRun?.nativeTurnID = "catalog-turn-1"
            let defaults = try await peer.session.codexDefaultModelSelection()
            var future = active; future.model = defaults.model; future.reasoningEffort = defaults.reasoningEffort
            #expect(defaults.model == "wire-model" && defaults.reasoningEffort == "medium")
            do {
                _ = try await peer.session.steer(input: .init(text: "Must not change the live effort"), thread: future,
                    expectedTurnID: "catalog-turn-1", clientMessageID: "user-\(UUID())")
                Issue.record("Future effort was silently applied to the active turn.")
            } catch let error as ProviderSteeringError { #expect(error.kind == .staleTarget) }
            let receipt = try await peer.session.steer(input: .init(text: "Use the running high-effort settings"), thread: active,
                expectedTurnID: "catalog-turn-1", clientMessageID: "user-\(UUID())")
            #expect(receipt.turnID == "catalog-turn-1" && receipt.delivery == .acknowledged)
            try await peer.session.interrupt()
            try await reasoningEventually { await observed.completions == 1 }
            future.activeRun = .init(id: UUID(), configuration: .init(thread: future), startedAt: .now)
            try await peer.session.send(text: "Explicit model-default medium input", thread: future)
            let frames = try peer.frames(), turns = frames.filter { $0["method"] == .string("turn/start") }
            let steers = frames.filter { $0["method"] == .string("turn/steer") }
            #expect(turns.count == 2 && turns.map { $0["params"]["effort"] } == [.string("high"), .string("medium")])
            #expect(turns.allSatisfy { $0["params"]["summary"] == .string("detailed") })
            #expect(steers.count == 1)
            let steeringKeys = Set(try #require(steers.first?["params"].object).keys)
            #expect(steeringKeys == Set(["threadId", "expectedTurnId", "clientUserMessageId", "input"]))
            #expect(frames.filter { $0["method"] == .string("thread/start") }.count == 1)
            #expect(!frames.contains { $0["method"] == .string("thread/resume") })
            await peer.session.close(); reader.cancel(); await reader.value
        } catch { await peer.session.close(); reader.cancel(); await reader.value; throw error }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["configured", "configuredUnknownProfile", "catalog", "customConfigured", "astra", "noEfforts"])
func codexDefaultModelReadResolvesCwdConfigurationBeforeAdvertisedFallback(kind: String) async throws {
    var configuredModel: JSONValue = .string("wire-model"), configuredEffort: JSONValue = .null
    var row = reasoningCatalogModel()
    var expectedModel = "wire-model", expectedEffort: String? = "medium"
    if kind == "configured" || kind == "configuredUnknownProfile" { configuredEffort = .string("high"); expectedEffort = "high" }
    if kind == "catalog" { configuredModel = .null }
    if kind == "customConfigured" {
        configuredModel = .string("custom-wire"); configuredEffort = .string("future-custom-effort")
        expectedModel = "custom-wire"; expectedEffort = "future-custom-effort"
    }
    if kind == "astra" {
        var astra = try #require(reasoningCatalogModel("gpt-6-astra").object)
        astra["defaultReasoningEffort"] = .string("high")
        row = .object(astra); configuredModel = .string("gpt-6-astra"); expectedModel = "gpt-6-astra"
    }
    if kind == "noEfforts" {
        row = .object(["model": .string("wire-model"), "supportedReasoningEfforts": .array([])])
        expectedEffort = nil
    }
    var options: [String: JSONValue] = ["cliConfig": .object(["model": configuredModel, "model_reasoning_effort": configuredEffort,
                                                           "unrelated_private_setting": .string("synthetic-private-token")]),
                                      "pages": .object(["": .object(["data": .array([row])])])]
    if kind == "configuredUnknownProfile" { options["userAgent"] = .string("codex/9.0.0") }
    try await withCatalogPeer(options) { peer in
        let selected = try await peer.session.codexDefaultModelSelection()
        #expect(selected.model == expectedModel && selected.reasoningEffort == expectedEffort)
        #expect(selected.workspacePath == WorkspaceProject(path: peer.root.path).path)
        #expect((selected.catalogModel == nil) == (kind == "customConfigured"))
        let frames = try peer.frames(), reads = frames.filter { $0["method"] == .string("config/read") }
        #expect(reads.count == 2)
        #expect(reads.allSatisfy { $0["params"]["cwd"] == .string(selected.workspacePath) && $0["params"]["includeLayers"] == .bool(false) })
        #expect(frames.allSatisfy { ["initialize", "initialized", "config/read", "model/list"].contains($0["method"].string ?? "") })
        let encoded = String(decoding: try JSONEncoder().encode(selected), as: UTF8.self)
        #expect(!encoded.contains("synthetic-private-token") && !encoded.contains("unrelated_private_setting"))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["ambiguousDefaults", "missingDefault", "unreviewedFallback", "unknownModelNoEffort", "unsupportedEffort", "changedConfig", "changedProvider", "malformedConfig", "configRPC"])
func codexDefaultModelReadRefusesUnprovenOrChangingDefaultsWithoutMutation(kind: String) async throws {
    var settings: JSONValue = .object(["model": .string("wire-model"), "model_reasoning_effort": .null])
    var rows = [reasoningCatalogModel()]
    var options: [String: JSONValue] = [:]
    if kind == "ambiguousDefaults" { settings = .object(["model": .null]); rows.append(reasoningCatalogModel("second-wire")) }
    if kind == "missingDefault" { settings = .object(["model": .null]); rows = [reasoningCatalogModel(isDefault: false)] }
    if kind == "unreviewedFallback" { settings = .object(["model": .null]); options["userAgent"] = .string("codex/9.0.0") }
    if kind == "unknownModelNoEffort" { settings = .object(["model": .string("unadvertised-wire"), "model_reasoning_effort": .null]) }
    if kind == "unsupportedEffort" { settings = .object(["model": .string("wire-model"), "model_reasoning_effort": .string("not-advertised")]) }
    if kind == "changedConfig" { options["changedCliConfig"] = .object(["model": .string("wire-model"), "model_reasoning_effort": .string("high")]) }
    if kind == "changedProvider" {
        settings = .object(["model": .string("wire-model"), "model_reasoning_effort": .null, "model_provider": .string("first-provider")])
        options["changedCliConfig"] = .object(["model": .string("wire-model"), "model_reasoning_effort": .null, "model_provider": .string("second-provider")])
    }
    if kind == "malformedConfig" { settings = .string("synthetic-private-token") }
    if kind == "configRPC" { options["configReadError"] = .bool(true) }
    options["cliConfig"] = settings; options["pages"] = .object(["": .object(["data": .array(rows)])])
    try await withCatalogPeer(options) { peer in
        do { _ = try await peer.session.codexDefaultModelSelection(); Issue.record("Unproven defaults were accepted.") }
        catch is CancellationError { throw CoincideError("Invalid defaults were classified as caller cancellation.") }
        catch { #expect(error.localizedDescription == "The Codex CLI default model could not be resolved safely. Refresh defaults and try again.") }
        #expect(try peer.frames().allSatisfy { ["initialize", "initialized", "config/read", "model/list"].contains($0["method"].string ?? "") })
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["", " ", "high\nlow", String(repeating: "x", count: 257)])
func codexReasoningMalformedCapturedEffortFailsBeforeStartingProviderConversation(effort: String) async throws {
    try await withCatalogPeer([:]) { peer in
        var thread = CodingThread(project: .init(path: peer.root.path), model: "wire-model")
        thread.reasoningEffort = effort
        do { try await peer.session.send(text: "An invalid captured setting", thread: thread); Issue.record("The invalid effort was accepted.") }
        catch { #expect(error.localizedDescription == "The selected Codex reasoning effort is invalid.") }
        let frames = try peer.frames()
        #expect(frames.isEmpty)
    }
}
