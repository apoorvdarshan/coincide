import Foundation

/// These are the advertised wire identifiers, not a slash-split display label or
/// the upstream `modelID` used inside a provider implementation.
public struct OpenCodeModelSelection: Sendable, Equatable, Hashable {
    public let providerID: String
    public let id: String
    public let variant: String?
    public init(providerID: String, id: String, variant: String? = nil) {
        self.providerID = providerID; self.id = id; self.variant = variant
    }
}

public struct OpenCodeModelDescriptor: Sendable, Equatable {
    public let selection: OpenCodeModelSelection
    public let name: String
    public let variants: [String]
    public let enabled: Bool
    public let input: [String]
    public let output: [String]
    public let tools: Bool?
}

public struct OpenCodeAgentDescriptor: Sendable, Equatable {
    public enum Mode: String, Sendable { case primary, subagent, all }
    public let id: String
    public let name: String
    public let description: String?
    public let mode: Mode
    public let hidden: Bool
}

/// Projects only bounded display and selection fields. Provider request headers,
/// settings, system prompts and unknown values never enter this inventory.
enum OpenCodeCatalog {
    static let maximumModels = 16_384

    static func v2Models(_ value: JSONValue, directory: String) throws -> [OpenCodeModelDescriptor] {
        let entries = try located(value, directory: directory)
        guard let array = entries.array, array.count <= maximumModels else { throw OpenCodeProtocolError.invalidCatalog }
        var seen = Set<OpenCodeModelSelection>(), result: [OpenCodeModelDescriptor] = []
        for entry in array {
            let model = try v2Model(entry)
            guard seen.insert(model.selection).inserted else { throw OpenCodeProtocolError.invalidCatalog }
            result.append(model)
        }
        return result
    }

    static func v2Default(_ value: JSONValue, directory: String) throws -> OpenCodeModelSelection? {
        let entry = try located(value, directory: directory)
        return entry == .null ? nil : try v2Model(entry).selection
    }

    private static func v2Model(_ value: JSONValue) throws -> OpenCodeModelDescriptor {
        guard value.object != nil else { throw OpenCodeProtocolError.invalidCatalog }
        let provider = try string(value["providerID"]), id = try string(value["id"])
        let name = try string(value["name"], maximum: 16_384)
        guard let variants = value["variants"].array, variants.count <= 256 else { throw OpenCodeProtocolError.invalidCatalog }
        var variantIDs: [String] = [], seen = Set<String>()
        for variant in variants {
            let id = try string(variant["id"])
            guard seen.insert(id).inserted else { throw OpenCodeProtocolError.invalidCatalog }
            variantIDs.append(id)
        }
        guard case .bool(let enabled) = value["enabled"],
              case .bool(let tools) = value["capabilities"]["tools"] else { throw OpenCodeProtocolError.invalidCatalog }
        let input = try strings(value["capabilities"]["input"], maximum: 64)
        let output = try strings(value["capabilities"]["output"], maximum: 64)
        return .init(selection: .init(providerID: provider, id: id), name: name,
                     variants: variantIDs, enabled: enabled, input: input, output: output, tools: tools)
    }

    static func v2Agents(_ value: JSONValue, directory: String) throws -> [OpenCodeAgentDescriptor] {
        try agents(located(value, directory: directory), generation: .v2)
    }

    static func v1Models(_ value: JSONValue) throws -> (models: [OpenCodeModelDescriptor], defaults: [OpenCodeModelSelection]) {
        guard let providers = value["all"].array, providers.count <= 512,
              let defaults = value["default"].object, defaults.count <= 512 else { throw OpenCodeProtocolError.invalidCatalog }
        let connected = Set(try strings(value["connected"], maximum: 512))
        var providerIDs = Set<String>(), selections = Set<OpenCodeModelSelection>()
        var result: [OpenCodeModelDescriptor] = []
        for provider in providers {
            let providerID = try string(provider["id"])
            guard providerIDs.insert(providerID).inserted,
                  let models = provider["models"].object, models.count <= maximumModels else { throw OpenCodeProtocolError.invalidCatalog }
            guard connected.contains(providerID) else { continue }
            for (_, value) in models.sorted(by: { $0.key < $1.key }) {
                let selection = OpenCodeModelSelection(providerID: providerID, id: try string(value["id"]))
                guard result.count < maximumModels, selections.insert(selection).inserted else { throw OpenCodeProtocolError.invalidCatalog }
                let variants: [String]
                if value["variants"] == .null { variants = [] }
                else if let raw = value["variants"].object, raw.count <= 256 {
                    variants = try raw.keys.sorted().map { try string(.string($0)) }
                } else { throw OpenCodeProtocolError.invalidCatalog }
                let modalities = value["modalities"]
                let input = modalities["input"] == .null ? [] : try strings(modalities["input"], maximum: 64)
                let output = modalities["output"] == .null ? [] : try strings(modalities["output"], maximum: 64)
                let tools: Bool?
                switch value["toolcall"] { case .null: tools = nil; case .bool(let result): tools = result; default: throw OpenCodeProtocolError.invalidCatalog }
                result.append(.init(selection: selection, name: try string(value["name"], maximum: 16_384),
                                    variants: variants, enabled: true, input: input, output: output, tools: tools))
            }
        }
        // A configured default for a disconnected provider is not a runnable
        // selection. Preserve only advertised connected wire IDs, without inference.
        var selectedDefaults: [OpenCodeModelSelection] = []
        for (provider, model) in defaults.sorted(by: { $0.key < $1.key }) {
            let selection = OpenCodeModelSelection(providerID: try string(.string(provider)), id: try string(model))
            if selections.contains(selection) { selectedDefaults.append(selection) }
        }
        return (result, selectedDefaults)
    }

    static func v1Agents(_ value: JSONValue) throws -> [OpenCodeAgentDescriptor] { try agents(value, generation: .v1) }

    private static func agents(_ value: JSONValue, generation: OpenCodeGeneration) throws -> [OpenCodeAgentDescriptor] {
        guard let entries = value.array, entries.count <= 512 else { throw OpenCodeProtocolError.invalidCatalog }
        var seen = Set<String>(), result: [OpenCodeAgentDescriptor] = []
        for entry in entries {
            let name = try string(entry["name"], maximum: 4_096)
            let id = generation == .v1 ? name : try string(entry["id"])
            guard seen.insert(id).inserted, let mode = OpenCodeAgentDescriptor.Mode(rawValue: try string(entry["mode"])) else {
                throw OpenCodeProtocolError.invalidCatalog
            }
            let hidden: Bool
            switch entry["hidden"] {
            case .bool(let value): hidden = value
            case .null where generation == .v1: hidden = false
            default: throw OpenCodeProtocolError.invalidCatalog
            }
            let description = entry["description"] == .null ? nil : try string(entry["description"], maximum: 16_384, allowNewlines: true)
            result.append(.init(id: id, name: name, description: description, mode: mode, hidden: hidden))
        }
        return result
    }

    static func located(_ value: JSONValue, directory: String) throws -> JSONValue {
        guard value.object != nil else { throw OpenCodeProtocolError.invalidCatalog }
        let returned = try string(value["location"]["directory"], maximum: 16_384)
        guard returned.hasPrefix("/"), returned == directory else {
            throw OpenCodeProtocolError.wrongDirectory
        }
        return value["data"]
    }

    static func string(_ value: JSONValue, maximum: Int = 4_096, allowNewlines: Bool = false) throws -> String {
        guard let string = value.string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              string.utf8.count <= maximum, !string.unicodeScalars.contains(where: {
                  $0.value == 127 || ($0.value < 32 && !(allowNewlines && ($0.value == 10 || $0.value == 9 || $0.value == 13)))
              }) else { throw OpenCodeProtocolError.invalidCatalog }
        return string
    }

    private static func strings(_ value: JSONValue, maximum: Int) throws -> [String] {
        guard let entries = value.array, entries.count <= maximum else { throw OpenCodeProtocolError.invalidCatalog }
        return try entries.map { try string($0) }
    }
}
