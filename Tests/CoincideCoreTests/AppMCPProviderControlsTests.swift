import Foundation
import Testing
@testable import CoincideCore

@Test func appMCPProviderControlsAdvertiseNativeDefaultsBooleanTypesAndOwnedRestrictions() throws {
    var thread = CodingThread(project: .init(path: "/private/offline-controls"), model: "native-model")
    let codex = ProviderModel(id: thread.model, name: "Native", reasoningEfforts: [.init(id: "high", description: "High")], defaultReasoningEffort: "high",
        codexServiceTiers: [.init(id: "priority", name: "Priority", description: "Native", isDefault: true)])
    let rows = AppMCPProviderModelOptions.descriptors(codex, configuration: .init(thread: thread))
    #expect(rows.first { $0["id"] == .string("serviceTier") }?["default"] == .string("priority"))
    #expect(rows.first { $0["id"] == .string("serviceTier") }?["values"] == .array([.string("default"), .string("priority")]))
    #expect(rows.first { $0["id"] == .string("fastMode") }?["values"] == .array([.bool(true), .bool(false)]))
    thread.codexRuntimeConfiguration = .init(homeDirectory: "/private/owned-home", authenticationMode: .ownedChatGPT)
    let owned = AppMCPProviderModelOptions.descriptors(codex, configuration: .init(thread: thread))
    #expect(owned.map { $0["id"] } == [.string("reasoningEffort")])
    thread.provider = .claude; thread.codexRuntimeConfiguration = nil
    let claude = ProviderModel(id: "alias", name: "Native Claude", reasoningEfforts: [.init(id: "max", description: "Max")],
        claudeCapabilities: .init(resolvedModel: "canonical", supportsFastMode: true, supportsThinking: true, contextWindows: ["200k", "1m"]))
    let controls = AppMCPProviderModelOptions.descriptors(claude, configuration: .init(thread: thread))
    #expect(Set(controls.compactMap { $0["id"].string }) == ["effort", "fastMode", "thinking", "contextWindow"])
    #expect(AppMCPProviderModelOptions.rows([claude], id: "canonical", provider: .claude) == [claude])
    let exact = ProviderModel(id: "canonical", name: "Exact native row")
    #expect(AppMCPProviderModelOptions.rows([claude, exact], id: "canonical", provider: .claude) == [exact])
    #expect(AppMCPProviderModelOptions.descriptors(.init(id: "legacy", name: "No capabilities"), configuration: .init(thread: thread)).isEmpty)
}

@Test func appMCPProviderControlsMergeInheritedCaptureWithoutExposingPrivateRuntimeFieldsAndRefuseUnsupportedValues() throws {
    var thread = CodingThread(project: .init(path: "/private/offline-controls"), model: "native-model"); thread.provider = .claude
    thread.agentConfiguration = try ClaudeModelControl.setting(.init(effort: "max", fastMode: true), in: ["private-setting": .string("MUST-NOT-BE-EXPORTED")])
    let original = ProviderConfiguration(thread: thread), captured = try AppMCPProviderModelOptions.captured(original)
    #expect(captured == ["effort": .string("max"), "fastMode": .bool(true)])
    #expect(AppMCPProviderModelOptions.merged(captured, overrides: nil) == captured)
    #expect(AppMCPProviderModelOptions.merged(captured, overrides: [:]).isEmpty)
    let merged = AppMCPProviderModelOptions.merged(captured, overrides: ["fastMode": .bool(false)])
    let row = ProviderModel(id: thread.model, name: "Native", reasoningEfforts: [.init(id: "max", description: "Max")], claudeCapabilities: .init(supportsFastMode: true))
    #expect(try AppMCPProviderModelOptions.claude(merged, model: row) == .init(effort: "max", fastMode: false))
    #expect(throws: AppMCPError(.invalidRequest)) { _ = try AppMCPProviderModelOptions.claude(["thinking": .bool(true)], model: row) }
    #expect(throws: AppMCPError(.invalidRequest)) { _ = try AppMCPProviderModelOptions.claude(["fastMode": .number(1)], model: row) }
    #expect(throws: AppMCPError(.unsupported)) { _ = try AppMCPProviderModelOptions.claude(["serviceTier": .string("priority")], model: row) }
    #expect(ProviderConfiguration(thread: thread) == original)
    thread.provider = .codex; thread.agentConfiguration = nil
    let model = ProviderModel(id: thread.model, name: "Native", codexServiceTiers: [.init(id: "priority", name: "Priority", description: "Native")])
    #expect(try AppMCPProviderModelOptions.codexTier(["serviceTier": .string("default"), "fastMode": .bool(true)], model: model, configuration: .init(thread: thread)) == "default")
    #expect(try AppMCPProviderModelOptions.codexTier(["fastMode": .bool(true)], model: model, configuration: .init(thread: thread)) == "fast")
    #expect(throws: AppMCPError(.invalidRequest)) { _ = try AppMCPProviderModelOptions.codexTier(["serviceTier": .string("missing")], model: model, configuration: .init(thread: thread)) }
    #expect(throws: AppMCPError(.invalidRequest)) { _ = try AppMCPProviderModelOptions.codexTier(["fastMode": .bool(false)], model: .init(id: thread.model, name: "No tiers"), configuration: .init(thread: thread)) }
}

@Test func appMCPProviderControlsCodexCatalogUsesNativeTierPrecedenceLegacyFallbackAndBackwardCompatibleDefaults() throws {
    let native: JSONValue = .object(["model": .string("wire"), "serviceTiers": .array([.object(["id": .string("priority"), "name": .string("Priority"), "description": .string("Native")])]),
        "additionalSpeedTiers": .array([.string("fast")]), "defaultServiceTier": .string("priority")])
    let current = try CodexModelCatalogEntry(native).model
    #expect(current.codexServiceTiers?.map(\.id) == ["priority"] && current.codexServiceTiers?.first?.isDefault == true)
    var legacy = try #require(native.object); legacy["serviceTiers"] = .array([]); legacy["additionalSpeedTiers"] = .array([.string("fast"), .string("ultrafast")]); legacy["defaultServiceTier"] = .string("ultrafast")
    let fallback = try CodexModelCatalogEntry(.object(legacy)).model
    #expect(fallback.codexServiceTiers?.map(\.id) == ["fast", "ultrafast"] && fallback.codexServiceTiers?.last?.isDefault == true)
    legacy["defaultServiceTier"] = .string("not-advertised")
    let unmatchedDefault = try CodexModelCatalogEntry(.object(legacy)).model
    #expect(unmatchedDefault.codexServiceTiers?.allSatisfy { !$0.isDefault } == true)
    for bad in [JSONValue.array([.string("fast"), .string("fast")]), .array(Array(repeating: .string("fast"), count: 65)), .string("fast")] {
        legacy["additionalSpeedTiers"] = bad
        #expect(throws: (any Error).self) { _ = try CodexModelCatalogEntry(.object(legacy)) }
    }
    let old = Data(#"{"id":"fast","name":"Fast","description":"Legacy metadata"}"#.utf8)
    #expect(try JSONDecoder().decode(CodexModelServiceTier.self, from: old).isDefault == false)
}
