import Foundation

/// Session-scoped choices. Empty choices deliberately retain the native CLI's
/// settings cascade; no user/project settings file is written by these controls.
public struct ClaudeModelOptions: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        var effort: String?
        var fastMode: Bool?
        var thinking: Bool?
        var contextWindow: String?
    }
    private var storage: [Payload]
    public var effort: String? { get { storage[0].effort } set { storage[0].effort = newValue } }
    public var fastMode: Bool? { get { storage[0].fastMode } set { storage[0].fastMode = newValue } }
    public var thinking: Bool? { get { storage[0].thinking } set { storage[0].thinking = newValue } }
    public var contextWindow: String? { get { storage[0].contextWindow } set { storage[0].contextWindow = newValue } }
    public var isEmpty: Bool { effort == nil && fastMode == nil && thinking == nil && contextWindow == nil }
    public init(effort: String? = nil, fastMode: Bool? = nil, thinking: Bool? = nil, contextWindow: String? = nil) {
        storage = [.init(effort: effort, fastMode: fastMode, thinking: thinking, contextWindow: contextWindow)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)]; try validate() }
    public func encode(to encoder: any Encoder) throws { try validate(); try storage[0].encode(to: encoder) }
    public func validate() throws {
        if let effort, !["low", "medium", "high", "xhigh", "max", "ultrathink", "ultracode"].contains(effort) { throw ClaudeModelControl.invalidOptions() }
        if let contextWindow, !["200k", "1m"].contains(contextWindow) { throw ClaudeModelControl.invalidOptions() }
    }
}

public struct ClaudeModelCapabilities: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let resolvedModel: String?
        let description: String?
        let supportsFastMode: Bool
        let supportsThinking: Bool
        let contextWindows: [String]
        let minimumVersion: String?
    }
    private let storage: [Payload]
    public var resolvedModel: String? { storage[0].resolvedModel }
    public var description: String? { storage[0].description }
    public var supportsFastMode: Bool { storage[0].supportsFastMode }
    public var supportsThinking: Bool { storage[0].supportsThinking }
    public var contextWindows: [String] { storage[0].contextWindows }
    public var minimumVersion: String? { storage[0].minimumVersion }
    public init(resolvedModel: String? = nil, description: String? = nil, supportsFastMode: Bool = false,
                supportsThinking: Bool = false, contextWindows: [String] = [], minimumVersion: String? = nil) {
        storage = [.init(resolvedModel: resolvedModel, description: description, supportsFastMode: supportsFastMode,
            supportsThinking: supportsThinking, contextWindows: contextWindows, minimumVersion: minimumVersion)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

public enum ClaudeModelControl {
    public static let configurationKey = "claudeModelOptions"

    public static func options(in configuration: ProviderConfiguration) throws -> ClaudeModelOptions {
        guard let value = configuration.agentConfiguration?[configurationKey] else { return .init() }
        guard configuration.provider == .claude, let object = value.object,
              Set(object.keys).isSubset(of: ["effort", "fastMode", "thinking", "contextWindow"]) else { throw invalidOptions() }
        func text(_ key: String) throws -> String? {
            guard let value = object[key] else { return nil }
            guard let result = value.string else { throw invalidOptions() }; return result
        }
        func flag(_ key: String) throws -> Bool? {
            guard let value = object[key] else { return nil }
            guard case .bool(let result) = value else { throw invalidOptions() }; return result
        }
        let result = try ClaudeModelOptions(effort: text("effort"), fastMode: flag("fastMode"),
            thinking: flag("thinking"), contextWindow: text("contextWindow"))
        try result.validate(); return result
    }

    public static func setting(_ options: ClaudeModelOptions, in values: [String: JSONValue]?) throws -> [String: JSONValue]? {
        try options.validate()
        var result = values ?? [:], object: [String: JSONValue] = [:]
        if let value = options.effort { object["effort"] = .string(value) }
        if let value = options.fastMode { object["fastMode"] = .bool(value) }
        if let value = options.thinking { object["thinking"] = .bool(value) }
        if let value = options.contextWindow { object["contextWindow"] = .string(value) }
        result[configurationKey] = object.isEmpty ? nil : .object(object)
        return result.isEmpty ? nil : result
    }

    public static func validate(_ options: ClaudeModelOptions, model: ProviderModel) throws {
        _ = try ClaudeModelCatalog.compile(model: model.id, options: options, models: [model])
    }

    public static func requiresNewSession(previous: ProviderConfiguration, next: ProviderConfiguration) -> Bool {
        guard previous.provider == .claude, next.provider == .claude else { return previous.provider != next.provider }
        guard let old = try? options(in: previous), let new = try? options(in: next) else { return true }
        // A flag-layer null effort resets the model default, whereas a fresh
        // process re-reads the user's settings. Thinking is a launch option.
        return old.thinking != new.thinking || (old.effort != nil && new.effort == nil)
    }

    static func invalidOptions() -> CoincideError { .init("The captured Claude model controls are invalid. Choose the model settings again.") }
    static func unsupported() -> CoincideError { .init("This Claude runtime did not advertise the selected model controls. Refresh models and choose supported settings before sending.") }
    static func requiresFreshSession() -> CoincideError { .init("These Claude model settings require a fresh connection to the same conversation. Reconnect before sending.") }

    /// Only a selected prompt effort changes transport text. Authored input,
    /// historical-context blocks and attachment records remain untouched.
    static func input(_ input: ProviderInput, promptEffort: String?) -> ProviderInput {
        guard promptEffort == "ultrathink" else { return input }
        let trimmed = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("Ultrathink:"),
              trimmed.range(of: #"^/[^\s/]+(?:\s|$)"#, options: .regularExpression) == nil else { return input }
        var result = input; result.text = "Ultrathink:\n" + trimmed; return result
    }
}

struct CompiledClaudeModelSelection: Sendable, Equatable {
    let model: String
    let effort: String?
    let promptEffort: String?
    let fastMode: Bool?
    let thinking: Bool?
    let ultracode: Bool
    let options: ClaudeModelOptions
    var flagSettings: JSONValue {
        var values: [String: JSONValue] = ["fastMode": fastMode.map(JSONValue.bool) ?? .null,
            "ultracode": ultracode ? .bool(true) : .null]
        if let effort { values["effortLevel"] = .string(effort) }
        return .object(values)
    }
}
