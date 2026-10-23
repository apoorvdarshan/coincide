import Foundation
import Testing
@testable import CoincideCore

private func claudeControlRow(_ id: String = "opus", resolved: String? = "claude-opus-4-6",
                             efforts: [String] = ["low", "medium", "high", "max"], fast: Bool = true) -> JSONValue {
    var value: [String: JSONValue] = ["value": .string(id), "displayName": .string("Native model"),
        "supportsEffort": .bool(!efforts.isEmpty), "supportedEffortLevels": .array(efforts.map(JSONValue.string)),
        "supportsFastMode": .bool(fast), "description": .string("Native description\nSecond line")]
    if let resolved { value["resolvedModel"] = .string(resolved) }
    return .object(value)
}

@Test func claudeModelControlCatalogUsesNativeCapabilitiesAndPinnedAliasesWithoutAddingModels() throws {
    let models = try ClaudeModelCatalog.models(.array([claudeControlRow(), claudeControlRow("pool", resolved: nil, efforts: ["high", "max"], fast: false)]))
    #expect(models.map(\.id) == ["opus", "pool"])
    #expect(models[0].reasoningEfforts.map(\.id) == ["low", "medium", "high", "max", "ultrathink"])
    #expect(models[0].defaultReasoningEffort == "high")
    #expect(models[0].claudeCapabilities?.contextWindows == ["200k", "1m"])
    #expect(models[0].claudeCapabilities?.supportsFastMode == true)
    #expect(models[1].reasoningEfforts.map(\.id) == ["high", "max"] && models[1].defaultReasoningEffort == nil)
    let legacy = try ClaudeModelCatalog.models(.array([.object(["value": .string("legacy"), "displayName": .string("Legacy")])]))
    #expect(legacy == [.init(id: "legacy", name: "Legacy")])
    let unknownNativeVersion = try ClaudeModelCatalog.models(.array([claudeControlRow("new", resolved: "claude-opus-5-5")]))
    #expect(unknownNativeVersion.count == 1)
    let oldNativeVersion = try ClaudeModelCatalog.models(.array([claudeControlRow("new", resolved: "claude-opus-5-5")]), version: "2.1.279")
    #expect(oldNativeVersion.isEmpty)
    let flat = try JSONSerialization.jsonObject(with: JSONEncoder().encode(models[0].claudeCapabilities)) as? [String: Any]
    #expect(flat?["storage"] == nil && flat?["supportsFastMode"] as? Bool == true)
}

@Test func claudeModelControlCatalogRejectsMalformedDuplicateAndUnboundedClaims() throws {
    let healthy = claudeControlRow()
    var conflicting = healthy.object!; conflicting["supportsFastMode"] = .bool(false)
    var invalidEffort = healthy.object!; invalidEffort["supportedEffortLevels"] = .array([.string("high"), .string("high")])
    var invalidCapability = healthy.object!; invalidCapability["supportsEffort"] = .string("true")
    for value in [JSONValue.object([:]), .array([healthy, .object(conflicting)]), .array([.object(invalidEffort)]),
                  .array([.object(invalidCapability)]), .array(Array(repeating: healthy, count: 2_049))] {
        #expect(throws: CoincideError.self) { _ = try ClaudeModelCatalog.models(value) }
    }
    #expect(try ClaudeModelCatalog.models(.array([healthy, healthy])).count == 1)
}

@Test func claudeModelControlClosedCapturePreservesOtherProviderFieldsAndRequiresFreshDefaults() throws {
    var thread = CodingThread(project: .init(path: "/private/controlled")); thread.provider = .claude
    let original: [String: JSONValue] = ["unrelated": .string("literal")]
    let selected = ClaudeModelOptions(effort: "max", fastMode: true, thinking: false, contextWindow: "1m")
    thread.agentConfiguration = try ClaudeModelControl.setting(selected, in: original)
    let configuration = ProviderConfiguration(thread: thread)
    #expect(try ClaudeModelControl.options(in: configuration) == selected)
    #expect(configuration.agentConfiguration?["unrelated"] == .string("literal"))
    let flat = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as? [String: Any]
    #expect(flat?["effort"] as? String == "max" && flat?["storage"] == nil)
    var next = configuration
    next.agentConfiguration = try ClaudeModelControl.setting(.init(fastMode: false, thinking: false), in: original)
    #expect(ClaudeModelControl.requiresNewSession(previous: configuration, next: next))
    next.agentConfiguration = try ClaudeModelControl.setting(.init(effort: "high", fastMode: false, thinking: false), in: original)
    #expect(!ClaudeModelControl.requiresNewSession(previous: configuration, next: next))
    next.agentConfiguration = try ClaudeModelControl.setting(.init(effort: "max", thinking: true), in: original)
    #expect(ClaudeModelControl.requiresNewSession(previous: configuration, next: next))
    #expect(try ClaudeModelControl.setting(.init(), in: thread.agentConfiguration) == original)
    let invalidObjects: [[String: JSONValue]] = [["effort": .string("unknown")], ["fastMode": .number(1)], ["thinking": .null], ["serviceTier": .string("priority")], ["effort": .string(" high ")]]
    for object in invalidObjects {
        var bad = configuration; bad.agentConfiguration = [ClaudeModelControl.configurationKey: .object(object)]
        #expect(throws: CoincideError.self) { _ = try ClaudeModelControl.options(in: bad) }
    }
    var foreign = configuration; foreign.provider = .codex
    #expect(throws: CoincideError.self) { _ = try ClaudeModelControl.options(in: foreign) }
}

@Test func claudeModelControlCompilationUsesExactMappedEffortContextAndNativeBooleanSupport() throws {
    let models = try ClaudeModelCatalog.models(.array([
        claudeControlRow(), claudeControlRow("sonnet", resolved: "claude-sonnet-4-6", efforts: ["low", "high"], fast: false),
        claudeControlRow("new-opus", resolved: "claude-opus-5", efforts: ["high", "xhigh", "max"]),
        claudeControlRow("older-opus", resolved: "claude-opus-4-7", efforts: ["low", "high", "max"])
    ]))
    let opus = try ClaudeModelCatalog.compile(model: "opus", options: .init(effort: "max", fastMode: true, contextWindow: "1m"), models: models)
    #expect(opus.model == "opus[1m]" && opus.effort == "max")
    #expect(opus.flagSettings == .object(["effortLevel": .string("max"), "fastMode": .bool(true), "ultracode": .null]))
    let sonnet = try ClaudeModelCatalog.compile(model: "sonnet", options: .init(effort: "max"), models: models)
    #expect(sonnet.effort == "high")
    let old = try ClaudeModelCatalog.compile(model: "older-opus", options: .init(effort: "xhigh"), models: models)
    #expect(old.effort == "max")
    let ultra = try ClaudeModelCatalog.compile(model: "new-opus", options: .init(effort: "ultracode"), models: models)
    #expect(ultra.effort == "xhigh" && ultra.flagSettings["ultracode"] == .bool(true))
    let prompt = try ClaudeModelCatalog.compile(model: "sonnet", options: .init(effort: "ultrathink"), models: models)
    #expect(prompt.effort == "high" && prompt.promptEffort == "ultrathink")
    #expect(throws: CoincideError.self) { _ = try ClaudeModelCatalog.compile(model: "sonnet", options: .init(fastMode: false), models: models) }
    #expect(throws: CoincideError.self) { _ = try ClaudeModelCatalog.compile(model: "not-advertised", options: .init(effort: "high"), models: models) }
    #expect(throws: CoincideError.self) { _ = try ClaudeModelCatalog.compile(model: "opus", options: .init(effort: "ultracode"), models: models) }
}

private struct ClaudeControlsFixture: Sendable {
    let root: URL
    let executable: URL
    let runtime: ClaudeRuntimeConfiguration
    init(_ scenario: String) throws {
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-controls-\(UUID())")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        root = URL(fileURLWithPath: try ClaudeRuntimeValidation.physical(created.path, allowMissing: false))
        executable = root.appendingPathComponent("claude-peer.py")
        let source = try #require(Bundle.module.url(forResource: "claude_model_controls", withExtension: "py", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data(scenario.utf8).write(to: root.appendingPathComponent("scenario"))
        let home = root.appendingPathComponent("private-config", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        runtime = .init(executable: executable.path, configurationDirectory: home.path, workspacePath: root.path,
            configurationDirectorySelection: .explicitDirectory(environmentPath: home.path))
    }
    func thread(options: ClaudeModelOptions = .init(), model: String = "opus") throws -> CodingThread {
        var result = CodingThread(project: .init(path: root.path)); result.provider = .claude; result.model = model
        result.claudeRuntimeConfiguration = runtime
        result.agentConfiguration = try ClaudeModelControl.setting(options, in: nil)
        result.activeRun = .init(id: UUID(), configuration: .init(thread: result), startedAt: Date())
        return result
    }
    func frames() throws -> [JSONValue] {
        try Data(contentsOf: root.appendingPathComponent("wire.jsonl")).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
}

private actor ClaudeControlsObservation {
    var completions = 0
    var values: [ProviderEvent] = []
    func append(_ value: ProviderEvent) {
        if case .context(_, let inner) = value { append(inner); return }
        values.append(value); if case .completed = value { completions += 1 }
    }
}
private func withClaudeControls(_ scenario: String = "normal", options: ClaudeModelOptions = .init(),
                               _ body: (ClaudeControlsFixture, ClaudeSession, ClaudeControlsObservation) async throws -> Void) async throws {
    let f = try ClaudeControlsFixture(scenario)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let session = try ClaudeSession(executable: f.executable, cwd: f.root, configuration: f.runtime, modelOptions: options)
    let observation = ClaudeControlsObservation()
    let reader = Task { for await value in session.events { await observation.append(value) } }
    do { try await body(f, session, observation); await session.close(); await reader.value }
    catch { await session.close(); await reader.value; throw error }
}
private func claudeControlEventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await condition()) {
        if ContinuousClock.now >= deadline { throw CoincideError("The private model-control peer did not reach the expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1))) func claudeModelControlStdioCapturesActiveSettingsAndRestoresNativeFastDefaultsOnNextTurn() async throws {
    try await withClaudeControls { f, session, observed in
        let selected = ClaudeModelOptions(effort: "max", fastMode: true, contextWindow: "1m")
        var thread = try f.thread(options: selected)
        // Future header edits cannot alter an already captured input.
        thread.model = "sonnet"; thread.agentConfiguration = try ClaudeModelControl.setting(.init(effort: "low"), in: nil)
        try await session.send(text: "  authored 工作 e\u{301}\n ", thread: thread)
        try await claudeControlEventually { await observed.completions == 1 }
        let first = try f.frames()
        #expect(first.filter { $0["request"]["subtype"] == .string("set_model") }.last?["request"]["model"] == .string("opus[1m]"))
        #expect(first.filter { $0["request"]["subtype"] == .string("apply_flag_settings") }.last?["request"]["settings"] == .object(["effortLevel": .string("max"), "fastMode": .bool(true), "ultracode": .null]))
        #expect(first.last?["message"]["content"] == .string("  authored 工作 e\u{301}\n "))
        let second = try f.thread(options: .init(effort: "high"))
        try await session.send(text: "Second explicit input", thread: second)
        try await claudeControlEventually { await observed.completions == 2 }
        let all = try f.frames(), settings = all.filter { $0["request"]["subtype"] == .string("apply_flag_settings") }
        #expect(settings.count == 2 && settings.last?["request"]["settings"]["fastMode"] == .null)
        #expect(all.filter { $0["type"] == .string("user") }.count == 2)
        let events = await observed.values
        #expect(events.contains { if case .configuration(let value) = $0 { value["claudeModelControl"]["fastModeState"] == .string("cooldown") && value["claudeModelControl"]["fastModeDisabledReason"] == .string("network_error") } else { false } })
        await #expect(throws: CoincideError.self) { try await session.send(text: "No implicit effort reset", thread: f.thread()) }
        #expect(try f.frames().filter { $0["type"] == .string("user") }.count == 2)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) func claudeModelControlThinkingIsAnActualLaunchFlagAndNeverChangesOnLiveInput(thinking: Bool) async throws {
    try await withClaudeControls(options: .init(thinking: thinking)) { f, session, observed in
        let thread = try f.thread(options: .init(thinking: thinking), model: "haiku")
        try await session.send(text: "Explicit thinking selection", thread: thread)
        try await claudeControlEventually { await observed.completions == 1 }
        let argv = try JSONDecoder().decode([String].self, from: Data(contentsOf: f.root.appendingPathComponent("argv.json")))
        let index = try #require(argv.firstIndex(of: "--thinking"))
        #expect(argv[index + 1] == (thinking ? "adaptive" : "disabled"))
        await #expect(throws: CoincideError.self) { try await session.send(text: "Must use a fresh process", thread: f.thread(options: .init(thinking: !thinking), model: "haiku")) }
        #expect(try f.frames().filter { $0["type"] == .string("user") }.count == 1)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["missing-capabilities", "reject-flags", "drop-flags"]) func claudeModelControlUnsupportedOrUncertainControlsNeverSubmitInput(scenario: String) async throws {
    try await withClaudeControls(scenario) { f, session, _ in
        do { try await session.send(text: "Must remain unsent", thread: f.thread(options: .init(effort: "high", fastMode: true))); Issue.record("Unsupported model controls were accepted") }
        catch { #expect(!error.localizedDescription.contains("PRIVATE-NATIVE-ERROR-MUST-NOT-LEAK")) }
        let frames = try f.frames()
        #expect(!frames.contains { $0["type"] == .string("user") })
    }
}

@Test(.timeLimit(.minutes(1))) func claudeModelControlCloseDrainsHeldSettingsAndPreventsLateInput() async throws {
    try await withClaudeControls("held-flags") { f, session, _ in
        let thread = try f.thread(options: .init(effort: "high"))
        let sending = Task { try await session.send(text: "Held input must remain unsent", thread: thread) }
        try await claudeControlEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("flags-entered").path) }
        await session.close()
        await #expect(throws: (any Error).self) { try await sending.value }
        let frames = try f.frames()
        #expect(!frames.contains { $0["type"] == .string("user") })
    }
}

@Test(.timeLimit(.minutes(1))) func claudeModelControlPromptEffortKeepsContextImagesAndNativeSkillFinalBlockSeparate() async throws {
    try await withClaudeControls { f, session, observed in
        let skills = f.root.appendingPathComponent("private-config/skills/review", isDirectory: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try Data("---\ndescription: private controlled skill\n---\nPRIVATE-SKILL-BODY".utf8).write(to: skills.appendingPathComponent("SKILL.md"))
        let thread = try f.thread(options: .init(effort: "ultrathink"))
        let transfer = UUID(), selection = try ContextHandoffService.select(messages: [.init(id: "old", role: "assistant", kind: "text", text: "Saved historical text")], coverage: .init(transferID: transfer, sourceThreadID: UUID(), strategy: "portableContext"))
        let literal = "  Please $review literal 工作 e\u{301}\n "
        let input = ProviderInput(text: literal, images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))], historicalContext: .init(deliveryID: UUID(), transferIDs: [transfer], selection: selection))
        try await session.send(input: input, thread: thread)
        try await claudeControlEventually { await observed.completions == 1 }
        let frames = try f.frames(), user = try #require(frames.first { $0["type"] == .string("user") })
        let blocks = try #require(user["message"]["content"].array)
        #expect(blocks.first?["text"] == .string(selection.renderedText))
        #expect(blocks.contains { $0["text"].string?.hasPrefix("Ultrathink:\nPlease /review") == true })
        #expect(blocks.last?["text"] == .string("/review literal 工作 e\u{301}"))
        #expect(blocks.contains { $0["type"] == .string("image") && $0["source"]["data"] == .string("AQID") })
        let runID = try #require(thread.activeRun?.id)
        #expect(user["uuid"] == .string(ClaudeInputIdentity.opening(runID: runID)))
        #expect(!user.pretty.contains("PRIVATE-SKILL-BODY"))
        #expect(input.text.utf8.elementsEqual(literal.utf8) && input.historicalContext?.selection == selection)
        let direct = ProviderInput(text: "  /plugin:review  exact\n ")
        #expect(ClaudeModelControl.input(direct, promptEffort: "ultrathink") == direct)
    }
}

@Test(.timeLimit(.minutes(1))) func claudeModelControlSteeringUsesCapturedPromptEffortAndCannotApplyFutureHeaderSettings() async throws {
    try await withClaudeControls("steering") { f, session, observed in
        var thread = try f.thread(options: .init(effort: "ultrathink"))
        let runID = try #require(thread.activeRun?.id), opening = ClaudeInputIdentity.opening(runID: runID)
        try await session.send(text: "First authored input", thread: thread)
        try await claudeControlEventually { await observed.values.contains { if case .turn = $0 { true } else { false } } }
        let events = await observed.values
        let native = try #require(events.compactMap { if case .thread(let id) = $0 { id } else { nil } }.last)
        thread.providerThreadID = native; thread.activeRun?.nativeTurnID = opening
        thread.agentConfiguration = try ClaudeModelControl.setting(.init(effort: "low", fastMode: true), in: nil)
        await #expect(throws: ProviderSteeringError.self) { _ = try await session.steer(input: .init(text: "Wrong future settings"), thread: thread, expectedTurnID: opening, clientMessageID: "wrong") }
        thread.agentConfiguration = try ClaudeModelControl.setting(.init(effort: "ultrathink"), in: nil)
        let receipt = try await session.steer(input: .init(text: "  Exact steered Ω\n "), thread: thread, expectedTurnID: opening, clientMessageID: "controlled-steer")
        #expect(receipt.turnID == opening)
        try await claudeControlEventually { await observed.completions == 1 }
        let frames = try f.frames(), users = frames.filter { $0["type"] == .string("user") }
        #expect(users.count == 2 && users.last?["message"]["content"] == .string("Ultrathink:\nExact steered Ω"))
        #expect(users.last?["priority"] == .string("now"))
        #expect(frames.filter { $0["request"]["subtype"] == .string("apply_flag_settings") }.count == 1)
        #expect(frames.filter { $0["request"]["subtype"] == .string("set_model") }.count == 1)
    }
}
