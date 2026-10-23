import Foundation

/// An advertised wire value, deliberately open to future provider effort IDs.
public struct ProviderReasoningEffortOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let description: String

    public init(id: String, description: String) {
        self.id = id; self.description = description
    }
}

public struct ProviderModel: Codable, Sendable, Equatable, Identifiable {
    /// The value sent as `model` to the provider, which can differ from its catalog ID.
    public var id: String
    public var name: String
    public var reasoningEfforts: [ProviderReasoningEffortOption]
    public var defaultReasoningEffort: String?
    public var isDefault: Bool
    public var catalogID: String?
    public var openCodeSelection: OpenCodeModelSelection?
    public var openCodeVariants: [String]?
    public var piSelection: PiModelSelection?
    public var piThinkingLevels: [String]?
    public var museSelection: MuseModelSelection?
    public var museReasoningEfforts: [ProviderReasoningEffortOption]?
    public var museDefaultReasoningEffort: String?
    public var claudeCapabilities: ClaudeModelCapabilities?
    public var codexServiceTiers: [CodexModelServiceTier]?
    public var codexInteractionModes: [CodexInteractionMode]?

    public init(id: String, name: String, reasoningEfforts: [ProviderReasoningEffortOption] = [],
                defaultReasoningEffort: String? = nil, isDefault: Bool = false, catalogID: String? = nil,
                openCodeSelection: OpenCodeModelSelection? = nil, openCodeVariants: [String]? = nil,
                piSelection: PiModelSelection? = nil, piThinkingLevels: [String]? = nil,
                museSelection: MuseModelSelection? = nil, museReasoningEfforts: [ProviderReasoningEffortOption]? = nil,
                museDefaultReasoningEffort: String? = nil, claudeCapabilities: ClaudeModelCapabilities? = nil,
                codexServiceTiers: [CodexModelServiceTier]? = nil, codexInteractionModes: [CodexInteractionMode]? = nil) {
        self.id = id; self.name = name; self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort; self.isDefault = isDefault; self.catalogID = catalogID
        self.openCodeSelection = openCodeSelection; self.openCodeVariants = openCodeVariants
        self.piSelection = piSelection; self.piThinkingLevels = piThinkingLevels
        self.museSelection = museSelection; self.museReasoningEfforts = museReasoningEfforts
        self.museDefaultReasoningEffort = museDefaultReasoningEffort
        self.claudeCapabilities = claudeCapabilities; self.codexServiceTiers = codexServiceTiers
        self.codexInteractionModes = codexInteractionModes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, reasoningEfforts, defaultReasoningEffort, isDefault, catalogID, openCodeSelection, openCodeVariants, piSelection, piThinkingLevels
        case museSelection, museReasoningEfforts, museDefaultReasoningEffort
        case claudeCapabilities, codexServiceTiers, codexInteractionModes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), name: try values.decode(String.self, forKey: .name),
            reasoningEfforts: try values.decodeIfPresent([ProviderReasoningEffortOption].self, forKey: .reasoningEfforts) ?? [],
            defaultReasoningEffort: try values.decodeIfPresent(String.self, forKey: .defaultReasoningEffort),
            isDefault: try values.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false,
            catalogID: try values.decodeIfPresent(String.self, forKey: .catalogID),
            openCodeSelection: try values.decodeIfPresent(OpenCodeModelSelection.self, forKey: .openCodeSelection),
            openCodeVariants: try values.decodeIfPresent([String].self, forKey: .openCodeVariants),
            piSelection: try values.decodeIfPresent(PiModelSelection.self, forKey: .piSelection),
            piThinkingLevels: try values.decodeIfPresent([String].self, forKey: .piThinkingLevels),
            museSelection: try values.decodeIfPresent(MuseModelSelection.self, forKey: .museSelection),
            museReasoningEfforts: try values.decodeIfPresent([ProviderReasoningEffortOption].self, forKey: .museReasoningEfforts),
            museDefaultReasoningEffort: try values.decodeIfPresent(String.self, forKey: .museDefaultReasoningEffort),
            claudeCapabilities: try values.decodeIfPresent(ClaudeModelCapabilities.self, forKey: .claudeCapabilities),
            codexServiceTiers: try values.decodeIfPresent([CodexModelServiceTier].self, forKey: .codexServiceTiers),
            codexInteractionModes: try values.decodeIfPresent([CodexInteractionMode].self, forKey: .codexInteractionModes))
    }
}

/// Decodes only model-catalog fields; unknown provider fields remain compatible.
/// Failures intentionally contain no provider-supplied values.
struct CodexModelCatalogEntry: Equatable {
    let model: ProviderModel
    let hidden: Bool

    static let failureMessage = "The Codex model catalog could not be read safely. Refresh models and try again."

    init(_ value: JSONValue) throws {
        guard value.object != nil else { throw Self.failure() }
        let catalogID = try Self.string(value["id"], maximum: 4_096)
        guard let wireID = try Self.string(value["model"], maximum: 4_096) ?? catalogID else { throw Self.failure() }
        let name = try Self.string(value["displayName"], maximum: 16_384) ?? wireID
        let defaultEffort = try Self.string(value["defaultReasoningEffort"], maximum: 256)
        let rawEfforts: [JSONValue]
        if value["supportedReasoningEfforts"] == .null { rawEfforts = [] }
        else if let options = value["supportedReasoningEfforts"].array, options.count <= 64 { rawEfforts = options }
        else { throw Self.failure() }
        var efforts: [ProviderReasoningEffortOption] = []
        var seen: [String: ProviderReasoningEffortOption] = [:]
        for raw in rawEfforts {
            guard raw.object != nil,
                  let id = try Self.string(raw["reasoningEffort"], maximum: 256),
                  let description = raw["description"].string, description.utf8.count <= 16_384,
                  !description.unicodeScalars.contains(where: { $0.value == 0 }) else { throw Self.failure() }
            let option = ProviderReasoningEffortOption(id: id, description: description)
            if let previous = seen[id] {
                guard previous == option else { throw Self.failure() }
            } else { seen[id] = option; efforts.append(option) }
        }
        let defaultTier = try Self.string(value["defaultServiceTier"], maximum: 256)
        if let defaultTier { try CodexServiceTier.validateID(defaultTier) }
        var tiers: [CodexModelServiceTier]? = nil
        if value.object?["serviceTiers"] != nil {
            guard let rows = value["serviceTiers"].array, rows.count <= 64 else { throw Self.failure() }
            var seen = Set<String>(), parsed: [CodexModelServiceTier] = []
            for row in rows {
                guard row.object != nil, let id = try Self.string(row["id"], maximum: 256),
                      let name = try Self.string(row["name"], maximum: 4_096),
                      let description = row["description"].string, description.utf8.count <= 16_384,
                      !description.contains("\0"), seen.insert(id).inserted else { throw Self.failure() }
                try CodexServiceTier.validateID(id)
                parsed.append(.init(id: id, name: name, description: description, isDefault: id == defaultTier))
            }
            tiers = parsed
        }
        if tiers?.isEmpty != false, value.object?["additionalSpeedTiers"] != nil {
            guard let legacy = value["additionalSpeedTiers"].array, legacy.count <= 64 else { throw Self.failure() }
            var parsed: [CodexModelServiceTier] = [], seen = Set<String>()
            for row in legacy {
                guard let id = try Self.string(row, maximum: 256), seen.insert(id).inserted else { throw Self.failure() }
                try CodexServiceTier.validateID(id)
                parsed.append(.init(id: id, name: id == "fast" ? "Fast" : id, description: "", isDefault: id == defaultTier))
            }
            tiers = parsed
        }
        if tiers?.isEmpty != false, try Self.boolean(value["supportsFastMode"]) {
            tiers = [.init(id: "fast", name: "Fast", description: "Native fast service tier.", isDefault: defaultTier == "fast")]
        }
        model = .init(id: wireID, name: name, reasoningEfforts: efforts, defaultReasoningEffort: defaultEffort,
                      isDefault: try Self.boolean(value["isDefault"]), catalogID: catalogID, codexServiceTiers: tiers)
        hidden = try Self.boolean(value["hidden"])
    }

    static func failure() -> CoincideError { CoincideError(failureMessage) }

    static func string(_ value: JSONValue, maximum: Int) throws -> String? {
        guard value != .null else { return nil }
        guard let result = value.string, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.utf8.count <= maximum,
              !result.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw failure() }
        return result
    }

    private static func boolean(_ value: JSONValue) throws -> Bool {
        switch value { case .null: return false; case .bool(let result): return result; default: throw failure() }
    }
}
