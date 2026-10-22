import Foundation

/// An explicit protocol flavor captured with an invocation, never inferred from
/// an agent's mutable display name or an untrusted server implementation name.
public enum ACPIntegration: String, Codable, CaseIterable, Sendable, Identifiable {
    case cursor, copilot, grok
    public var id: String { rawValue }
    public var name: String { switch self { case .cursor: "Cursor"; case .copilot: "GitHub Copilot"; case .grok: "Grok" } }
    public var executable: String { switch self { case .cursor: "agent"; case .copilot: "copilot"; case .grok: "grok" } }
    public var arguments: [String] { switch self { case .cursor: ["acp"]; case .copilot: ["--acp", "--stdio"]; case .grok: GrokACP.arguments(runtimeMode: .approvalRequired) } }
    public var signInCommand: String { switch self { case .cursor: "agent login"; case .copilot: "copilot"; case .grok: "grok login" } }
    public var documentationURL: URL {
        let address: String = switch self { case .cursor: "https://cursor.com/docs/cli/acp"; case .copilot: "https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server"; case .grok: "https://docs.x.ai/build/cli/reference" }
        return URL(string: address)!
    }
    public func configuration(id: UUID = UUID()) -> ACPAgentConfiguration {
        var configuration = ACPAgentConfiguration(id: id, name: name, executable: executable, arguments: arguments)
        configuration.integration = self
        return configuration
    }
    var clientCapabilities: JSONValue {
        if self == .copilot { return .object(["_meta": CopilotACPBridge.clientCapabilitiesMetadata]) }
        return .object([:])
    }
}

/// An initialize-only observation; connection success does not establish login,
/// model entitlement, session creation or support for all optional ACP methods.
public struct ACPConnectionInfo: Sendable, Equatable {
    public let protocolVersion: Int
    public let agentName: String?
    public let agentVersion: String?
    public let supportsResume: Bool
    public let supportsImages: Bool
    public let authenticationMethods: [String]

    public init(_ value: JSONValue) throws {
        try ACPIntegrationValidation.bound(value)
        guard case .number(let version) = value["protocolVersion"], let version = Int(exactly: version), [1, 2].contains(version) else {
            throw ACPIntegrationValidation.failure()
        }
        protocolVersion = version
        let info = version == 1 ? value["agentInfo"] : value["info"]
        if info != .null, info.object == nil { throw ACPIntegrationValidation.failure() }
        agentName = try ACPIntegrationValidation.string(info["name"], maximum: 256)
        agentVersion = try ACPIntegrationValidation.string(info["version"], maximum: 256)
        supportsResume = version == 1 ? value["agentCapabilities"]["loadSession"] == .bool(true) : value["capabilities"]["session"]["resume"].object != nil
        supportsImages = version == 1 ? value["agentCapabilities"]["promptCapabilities"]["image"] == .bool(true) : value["capabilities"]["session"]["prompt"]["image"].object != nil
        if value["authMethods"] == .null { authenticationMethods = [] }
        else {
            guard let methods = value["authMethods"].array, methods.count <= 32 else { throw ACPIntegrationValidation.failure() }
            var names: [String] = [], ids: Set<String> = []
            for method in methods {
                guard method.object != nil, let id = try ACPIntegrationValidation.string(method["id"], maximum: 256), ids.insert(id).inserted else {
                    throw ACPIntegrationValidation.failure()
                }
                names.append(try ACPIntegrationValidation.string(method["name"], maximum: 256) ?? id)
            }
            authenticationMethods = names
        }
    }
}

enum ACPIntegrationValidation {
    static func failure() -> CoincideError { CoincideError("The agent returned an invalid integration response.") }
    static func string(_ value: JSONValue, maximum: Int, multiline: Bool = false) throws -> String? {
        guard value != .null else { return nil }
        guard let text = value.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximum, !text.unicodeScalars.contains(where: { scalar in
                  scalar.value == 0 || scalar.value == 127 || (!multiline && scalar.value < 32)
              }) else { throw failure() }
        return text
    }
    static func bound(_ value: JSONValue) throws {
        var pending: [(JSONValue, Int)] = [(value, 0)], nodes = 0, bytes = 0
        while let (item, depth) = pending.popLast() {
            nodes += 1
            guard nodes <= 16_384, depth <= 32 else { throw failure() }
            switch item {
            case .object(let fields):
                guard fields.count <= 4_096 else { throw failure() }
                for (key, value) in fields { bytes += key.utf8.count; pending.append((value, depth + 1)) }
            case .array(let values):
                guard values.count <= 4_096 else { throw failure() }
                for value in values { pending.append((value, depth + 1)) }
            case .string(let text): bytes += text.utf8.count
            default: bytes += 8
            }
            guard bytes <= 2 * 1_024 * 1_024, pending.count <= 16_384 else { throw failure() }
        }
    }
}
