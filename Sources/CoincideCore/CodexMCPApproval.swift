import Foundation

/// Codex 0.163's native MCP tool approval is an empty form elicitation.
/// Nonempty forms, URL consent and user verification need separate UI flows.
public struct CodexMCPApproval: Sendable, Equatable {
    public static let method = "mcpServer/elicitation/request"
    public let threadID: String
    public let turnID: String
    public let serverName: String
    public let message: String
    public let toolTitle: String?
    public let toolArguments: JSONValue

    init(params: JSONValue) throws {
        try MCPProtocol.validateJSON(params)
        let schema = params["requestedSchema"], metadata = params["_meta"]
        guard params["mode"] == .string("form"),
              metadata["codex_approval_kind"] == .string("mcp_tool_call"),
              schema["type"] == .string("object"), schema["properties"].object?.isEmpty == true,
              schema["required"] == .null || schema["required"].array == [],
              let fields = schema.object, Set(fields.keys).isSubset(of: ["$schema", "type", "properties", "required"]),
              let threadID = params["threadId"].string, MCPProtocol.text(threadID, maximum: 4_096),
              let turnID = params["turnId"].string, MCPProtocol.text(turnID, maximum: 4_096),
              let server = params["serverName"].string, MCPProtocol.text(server, maximum: 256),
              let message = params["message"].string, !message.isEmpty, message.utf8.count <= 16_384,
              !message.contains("\0") else { throw MCPError(.unavailable) }
        let title = metadata["tool_title"].string
        if let title, !MCPProtocol.text(title, maximum: 512) { throw MCPError(.unavailable) }
        self.threadID = threadID; self.turnID = turnID; serverName = server
        self.message = message; toolTitle = title; toolArguments = metadata["tool_params"]
    }

    public var title: String { toolTitle.map { "Approve " + $0 } ?? "Approve \(serverName) tool" }
    public var detail: String { message + (toolArguments == .null ? "" : "\n\n" + toolArguments.pretty) }

    /// Approval is for this invocation only. Never echo native persistence
    /// options back as a request to change the user's CLI configuration.
    func response(allow: Bool) -> JSONValue {
        .object(["action": .string(allow ? "accept" : "decline"),
                 "content": allow ? .object([:]) : .null, "_meta": .null])
    }
}
