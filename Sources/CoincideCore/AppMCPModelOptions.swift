import Foundation

enum AppMCPProviderModelOptions {
    static func matches(_ row: ProviderModel, id: String, provider: ProviderKind) -> Bool {
        row.id.utf8.elementsEqual(id.utf8) || row.catalogID?.utf8.elementsEqual(id.utf8) == true ||
            (provider == .claude && row.claudeCapabilities?.resolvedModel?.utf8.elementsEqual(id.utf8) == true)
    }
    static func rows(_ catalog: [ProviderModel], id: String, provider: ProviderKind) -> [ProviderModel] {
        let exact = catalog.filter { $0.id.utf8.elementsEqual(id.utf8) || $0.catalogID?.utf8.elementsEqual(id.utf8) == true }
        return exact.isEmpty ? catalog.filter { matches($0, id: id, provider: provider) } : exact
    }
    static func captured(_ configuration: ProviderConfiguration) throws -> [String: JSONValue] {
        switch configuration.provider {
        case .codex:
            _ = try CodexServiceTier.selected(in: configuration)
            var values = configuration.agentConfiguration?[CodexServiceTier.configurationKey]?.object ?? [:]
            if let effort = configuration.reasoningEffort { values["reasoningEffort"] = .string(effort) }
            return values
        case .claude:
            _ = try ClaudeModelControl.options(in: configuration)
            return configuration.agentConfiguration?[ClaudeModelControl.configurationKey]?.object ?? [:]
        }
    }
    static func merged(_ inherited: [String: JSONValue], overrides: [String: JSONValue]?) -> [String: JSONValue] {
        guard let overrides else { return inherited }
        guard !overrides.isEmpty else { return [:] }
        return inherited.merging(overrides) { _, next in next }
    }
    static func claude(_ options: [String: JSONValue], model: ProviderModel) throws -> ClaudeModelOptions {
        guard Set(options.keys).isSubset(of: ["effort", "fastMode", "thinking", "contextWindow"]) else { throw AppMCPError(.unsupported) }
        do {
            let value = try JSONDecoder().decode(ClaudeModelOptions.self, from: JSONEncoder().encode(JSONValue.object(options)))
            try ClaudeModelControl.validate(value, model: model); return value
        } catch { throw AppMCPError(.invalidRequest) }
    }
    static func codexTier(_ options: [String: JSONValue], model: ProviderModel, configuration: ProviderConfiguration) throws -> String? {
        guard Set(options.keys).isSubset(of: ["reasoningEffort", "serviceTier", "fastMode"]) else { throw AppMCPError(.unsupported) }
        if options["fastMode"] != nil {
            guard configuration.codexRuntimeBinding?.authenticationMode != .ownedChatGPT,
                  model.codexServiceTiers?.contains(where: { $0.id == "fast" || $0.id == "priority" }) == true else { throw AppMCPError(.invalidRequest) }
        }
        var selected = configuration, controls = options
        controls.removeValue(forKey: "reasoningEffort")
        selected.agentConfiguration = controls.isEmpty ? nil : [CodexServiceTier.configurationKey: .object(controls)]
        do { let tier = try CodexServiceTier.selected(in: selected); try CodexServiceTier.validate(tier, model: model); return tier }
        catch { throw AppMCPError(.invalidRequest) }
    }
    static func descriptors(_ model: ProviderModel, configuration: ProviderConfiguration) -> [JSONValue] {
        func select(_ id: String, values: [String], default fallback: String? = nil) -> JSONValue {
            var object: [String: JSONValue] = ["id": .string(id), "type": .string("select"), "values": .array(values.map(JSONValue.string))]
            if let fallback { object["default"] = .string(fallback) }; return .object(object)
        }
        func flag(_ id: String) -> JSONValue { .object(["id": .string(id), "type": .string("boolean"), "values": .array([.bool(true), .bool(false)])]) }
        var result: [JSONValue] = []
        switch configuration.provider {
        case .codex:
            if !model.reasoningEfforts.isEmpty { result.append(select("reasoningEffort", values: model.reasoningEfforts.map(\.id), default: model.codexDefaultReasoningEffort)) }
            if configuration.codexRuntimeBinding?.authenticationMode != .ownedChatGPT, let tiers = model.codexServiceTiers, !tiers.isEmpty {
                result.append(select("serviceTier", values: ["default"] + tiers.map(\.id).filter { $0 != "default" }, default: tiers.first(where: \.isDefault)?.id ?? "default"))
                if tiers.contains(where: { $0.id == "fast" || $0.id == "priority" }) { result.append(flag("fastMode")) }
            }
        case .claude:
            if !model.reasoningEfforts.isEmpty { result.append(select("effort", values: model.reasoningEfforts.map(\.id), default: model.defaultReasoningEffort)) }
            if let capabilities = model.claudeCapabilities {
                if capabilities.supportsFastMode { result.append(flag("fastMode")) }
                if capabilities.supportsThinking { result.append(flag("thinking")) }
                if !capabilities.contextWindows.isEmpty { result.append(select("contextWindow", values: capabilities.contextWindows)) }
            }
        }
        return result
    }
}
