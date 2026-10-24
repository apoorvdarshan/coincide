import Foundation

/// Native app-server collaboration modes, independent of permission/sandbox.
/// The existing agentModeID is already captured by ProviderConfiguration.
public enum CodexInteractionMode: String, Sendable, Codable, CaseIterable {
    case `default`, plan
    public static func selected(in configuration: ProviderConfiguration) throws -> Self? {
        guard configuration.provider == .codex else { throw invalid() }
        guard let value = configuration.agentModeID else { return nil }
        guard let mode = Self(rawValue: value) else { throw invalid() }
        return mode
    }
    public static func invalid() -> CoincideError {
        .init("Choose Default or Plan for this Codex input. The saved mode is unsupported.")
    }
    func wire(model: String, effort: String?) throws -> JSONValue {
        guard MCPProtocol.text(model, maximum: 4_096), !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoincideError("Refresh the Codex CLI default model before selecting an interaction mode.")
        }
        // Native turn/start specifies null as the built-in instructions for
        // the selected mode. Keep mode explicit; do not inject an app prompt.
        var settings: [String: JSONValue] = ["model": .string(model), "developer_instructions": .null]
        if let effort {
            guard MCPProtocol.text(effort, maximum: 256), !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CoincideError("The selected Codex reasoning effort is invalid.")
            }
            settings["reasoning_effort"] = .string(effort)
        }
        return .object(["mode": .string(rawValue), "settings": .object(settings)])
    }
}
