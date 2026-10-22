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

    public init(id: String, name: String, reasoningEfforts: [ProviderReasoningEffortOption] = [],
                defaultReasoningEffort: String? = nil, isDefault: Bool = false, catalogID: String? = nil,
                openCodeSelection: OpenCodeModelSelection? = nil, openCodeVariants: [String]? = nil) {
        self.id = id; self.name = name; self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort; self.isDefault = isDefault; self.catalogID = catalogID
        self.openCodeSelection = openCodeSelection; self.openCodeVariants = openCodeVariants
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, reasoningEfforts, defaultReasoningEffort, isDefault, catalogID, openCodeSelection, openCodeVariants
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), name: try values.decode(String.self, forKey: .name),
            reasoningEfforts: try values.decodeIfPresent([ProviderReasoningEffortOption].self, forKey: .reasoningEfforts) ?? [],
            defaultReasoningEffort: try values.decodeIfPresent(String.self, forKey: .defaultReasoningEffort),
            isDefault: try values.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false,
            catalogID: try values.decodeIfPresent(String.self, forKey: .catalogID),
            openCodeSelection: try values.decodeIfPresent(OpenCodeModelSelection.self, forKey: .openCodeSelection),
            openCodeVariants: try values.decodeIfPresent([String].self, forKey: .openCodeVariants))
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
        model = .init(id: wireID, name: name, reasoningEfforts: efforts, defaultReasoningEffort: defaultEffort,
                      isDefault: try Self.boolean(value["isDefault"]), catalogID: catalogID)
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
