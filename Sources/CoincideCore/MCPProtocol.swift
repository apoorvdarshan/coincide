import Foundation

/// The compatibility profiles used by the pinned provider bridge. This is not
/// the stateless 2026 MCP protocol, which has a different initialization model.
public enum MCPProtocol {
    public static let supportedVersions = ["2025-06-18", "2025-11-25"]
    public static let maximumBodyBytes = 1_048_576

    static func decode(_ data: Data) throws -> JSONValue {
        guard !data.isEmpty, data.count <= maximumBodyBytes else { throw MCPError(.limitExceeded) }
        // Bound nesting before the recursive JSON decoder sees untrusted input.
        var depth = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 { depth += 1; guard depth <= 32 else { throw MCPError(.limitExceeded) } }
            else if byte == 125 || byte == 93 { depth -= 1; guard depth >= 0 else { throw MCPError(.invalidRequest) } }
        }
        guard depth == 0, !inString, let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw MCPError(.invalidRequest) }
        try validateJSON(value)
        return value
    }

    static func validateJSON(_ value: JSONValue) throws {
        var pending: [(JSONValue, Int)] = [(value, 0)], count = 0, bytes = 0
        while let (item, depth) = pending.popLast() {
            count += 1
            guard count <= 20_000, depth <= 32 else { throw MCPError(.limitExceeded) }
            switch item {
            case .object(let fields):
                for (key, child) in fields { bytes += key.utf8.count; pending.append((child, depth + 1)) }
            case .array(let values): for child in values { pending.append((child, depth + 1)) }
            case .string(let text): bytes += text.utf8.count
            case .number(let number): guard number.isFinite else { throw MCPError(.invalidRequest) }
            case .bool, .null: break
            }
            guard bytes <= maximumBodyBytes else { throw MCPError(.limitExceeded) }
        }
    }

    static func encode(_ value: JSONValue) throws -> Data {
        try validateJSON(value)
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBodyBytes else { throw MCPError(.limitExceeded) }
        return data
    }

    static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
    static func failure(id: JSONValue = .null, error: MCPError) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .number(Double(error.code)), "message": .string(error.description)])])
    }
    static func text(_ value: String, maximum: Int, empty: Bool = false) -> Bool {
        (empty || !value.isEmpty) && value.utf8.count <= maximum && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
}

public struct MCPError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    public enum Kind: String, Sendable { case invalidConfiguration, unauthorized, invalidRequest, notReady, methodNotFound, invalidParams, unavailable, cancelled, timedOut, limitExceeded, internalFailure }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var description: String {
        switch kind {
        case .invalidConfiguration: "The app tool connection is not configured correctly."
        case .unauthorized: "The app tool credential is unavailable or expired."
        case .invalidRequest: "The app tool request is not valid."
        case .notReady: "The app tool connection has not initialized."
        case .methodNotFound: "The app tool method is not supported."
        case .invalidParams: "The app tool arguments are not valid."
        case .unavailable: "The app tool is not available in this session."
        case .cancelled: "The app tool request was cancelled."
        case .timedOut: "The app tool request timed out."
        case .limitExceeded: "The app tool request exceeded its limit."
        case .internalFailure: "The app tool request could not be completed."
        }
    }
    public var errorDescription: String? { description }
    var code: Int {
        switch kind {
        case .invalidRequest, .limitExceeded: -32600
        case .methodNotFound: -32601
        case .invalidParams: -32602
        case .cancelled: -32800
        case .notReady, .unavailable, .unauthorized: -32000
        case .timedOut: -32001
        case .invalidConfiguration, .internalFailure: -32603
        }
    }
}

public enum MCPCapability: String, Sendable, Hashable, CaseIterable {
    case orchestration, worktree, pullRequests = "pull-requests", preview, device
}

/// Provider-session authority, deliberately independent of any one turn. The
/// Engine resolves and rechecks current run ownership at each app invocation.
public struct MCPInvocationScope: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let sessionID: UUID
    public let threadID: UUID
    public let projectID: UUID
    public let provider: ProviderKind
    public let runtimeID: UUID
    public let incarnation: UUID
    public let providerInstanceID: UUID
    public let workspacePath: String
    public let permission: PermissionMode
    public let capabilities: Set<MCPCapability>
    public init(sessionID: UUID = UUID(), threadID: UUID, projectID: UUID, provider: ProviderKind,
                runtimeID: UUID, incarnation: UUID, providerInstanceID: UUID, workspacePath: String,
                permission: PermissionMode, capabilities: Set<MCPCapability>) {
        self.sessionID = sessionID; self.threadID = threadID; self.projectID = projectID; self.provider = provider
        self.runtimeID = runtimeID; self.incarnation = incarnation; self.providerInstanceID = providerInstanceID
        self.workspacePath = workspacePath; self.permission = permission; self.capabilities = capabilities
    }
    public func validate() throws {
        guard workspacePath.hasPrefix("/"), MCPProtocol.text(workspacePath, maximum: 4_096) else { throw MCPError(.invalidConfiguration) }
    }
    public var description: String { "MCPInvocationScope(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}

public struct MCPToolDefinition: Sendable, Equatable {
    public let name: String
    public let title: String?
    public let description: String
    public let inputSchema: JSONValue
    public let capability: MCPCapability
    public let readOnly: Bool
    public init(name: String, title: String? = nil, description: String, inputSchema: JSONValue,
                capability: MCPCapability, readOnly: Bool) {
        self.name = name; self.title = title; self.description = description; self.inputSchema = inputSchema
        self.capability = capability; self.readOnly = readOnly
    }
    public func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 128,
              name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              MCPProtocol.text(description, maximum: 8_192, empty: true),
              title.map({ MCPProtocol.text($0, maximum: 256) }) ?? true,
              inputSchema.object != nil, inputSchema["type"].string == "object" else { throw MCPError(.invalidConfiguration) }
        try MCPProtocol.validateJSON(inputSchema)
    }
    var json: JSONValue {
        var value: [String: JSONValue] = ["name": .string(name), "description": .string(description), "inputSchema": inputSchema,
            "annotations": .object(["readOnlyHint": .bool(readOnly), "openWorldHint": .bool(false)])]
        if let title { value["title"] = .string(title) }
        return .object(value)
    }
}

public struct MCPInvocation: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let scope: MCPInvocationScope
    public let requestID: JSONValue
    public let toolName: String
    public let arguments: JSONValue
    public init(scope: MCPInvocationScope, requestID: JSONValue, toolName: String, arguments: JSONValue) {
        self.scope = scope; self.requestID = requestID; self.toolName = toolName; self.arguments = arguments
    }
    public var description: String { "MCPInvocation(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}

public struct MCPToolResult: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let content: [String]
    public let structuredContent: JSONValue?
    public let isError: Bool
    public init(content: [String], structuredContent: JSONValue? = nil, isError: Bool = false) {
        self.content = content; self.structuredContent = structuredContent; self.isError = isError
    }
    var json: JSONValue {
        var result: [String: JSONValue] = ["content": .array(content.map { .object(["type": .string("text"), "text": .string($0)]) }), "isError": .bool(isError)]
        if let structuredContent { result["structuredContent"] = structuredContent }
        return .object(result)
    }
    public var description: String { "MCPToolResult(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}

enum MCPRequestID: Hashable, Sendable {
    case text(String), integer(Int64)
    init(_ value: JSONValue) throws {
        switch value {
        case .string(let value) where MCPProtocol.text(value, maximum: 128): self = .text(value)
        case .number(let value) where value.isFinite && value.rounded() == value && abs(value) <= 9_007_199_254_740_991: self = .integer(Int64(value))
        default: throw MCPError(.invalidRequest)
        }
    }
}
