import Foundation

public struct CodexModelServiceTier: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let isDefault: Bool
    public init(id: String, name: String, description: String, isDefault: Bool = false) {
        self.id = id; self.name = name; self.description = description; self.isDefault = isDefault
    }
    private enum CodingKeys: String, CodingKey { case id, name, description, isDefault }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), name: try values.decode(String.self, forKey: .name),
            description: try values.decode(String.self, forKey: .description), isDefault: try values.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false)
    }
}

/// Native service-tier IDs remain open to the model's actual catalogue. Saved
/// options are captured in the existing provider configuration dictionary.
public enum CodexServiceTier {
    public static let configurationKey = "codexModelOptions"
    public static func selected(in configuration: ProviderConfiguration) throws -> String? {
        guard let raw = configuration.agentConfiguration?[configurationKey] else { return nil }
        guard configuration.provider == .codex, let values = raw.object,
              Set(values.keys).isSubset(of: ["serviceTier", "fastMode"]) else { throw invalid() }
        if let value = values["fastMode"], value != .bool(true), value != .bool(false) { throw invalid() }
        let result: String?
        if let value = values["serviceTier"] {
            guard let id = value.string else { throw invalid() }; try validateID(id); result = id
        } else { result = values["fastMode"] == .bool(true) ? "fast" : nil }
        if result != nil, configuration.codexRuntimeBinding?.authenticationMode == .ownedChatGPT {
            throw CoincideError("Service tiers are unavailable for the owned ChatGPT connection. Choose its default speed.")
        }
        return result
    }
    public static func setting(_ id: String?, in values: [String: JSONValue]?) throws -> [String: JSONValue]? {
        if let id { try validateID(id) }
        var result = values ?? [:]
        result[configurationKey] = id.map { .object(["serviceTier": .string($0)]) }
        return result.isEmpty ? nil : result
    }
    public static func validate(_ id: String?, model: ProviderModel) throws {
        guard let id else { return }
        try validateID(id)
        guard let tiers = model.codexServiceTiers, !tiers.isEmpty,
              id == "default" || tiers.contains(where: { $0.id.utf8.elementsEqual(id.utf8) || (id == "fast" && $0.id == "priority") }) else { throw invalid() }
    }
    static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 256,
              !id.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }) else { throw invalid() }
    }
    static func invalid() -> CoincideError { .init("Choose a service tier advertised by the current Codex model.") }
}

extension CodingThread {
    public mutating func selectCodexServiceTier(model: ProviderModel, tier: String?) throws {
        guard provider == .codex, self.model.utf8.elementsEqual(model.id.utf8) else {
            throw WorkspaceCommandError("The selected Codex model changed. Refresh its current service tiers before choosing one.")
        }
        try CodexServiceTier.validate(tier, model: model)
        let settings = try CodexServiceTier.setting(tier, in: agentConfiguration)
        var captured = ProviderConfiguration(thread: self); captured.agentConfiguration = settings
        _ = try CodexServiceTier.selected(in: captured)
        agentConfiguration = settings
    }
}
