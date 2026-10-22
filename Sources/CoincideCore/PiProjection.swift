import Foundation

/// Per-run projection: Pi message/content indices are scoped to this prompt,
/// never promoted to native conversation/turn identities.
struct PiProjection {
    let scope: String
    private var message = 0
    private var assistant = false
    private var text: [String: String] = [:]
    private var tools: Set<String> = []
    private var bytes = 0
    init(scope: String) { self.scope = scope }
    mutating func apply(_ frame: JSONValue) throws -> [ProviderEntityUpdate] {
        let type = frame["type"].string
        if type == "message_start" {
            assistant = frame["message"]["role"].string == "assistant"
            if assistant { message += 1 }
            guard message <= 4_096 else { throw CoincideError(PiProtocol.failure) }
            return []
        }
        if type == "message_update" {
            guard assistant, frame["message"]["role"].string != "user" else { return [] }
            let delta = frame["assistantMessageEvent"], kind = delta["type"].string ?? ""
            guard ["text_delta", "thinking_delta", "text_end", "thinking_end"].contains(kind) else { return [] }
            guard case .number(let raw) = delta["contentIndex"], let index = Int(exactly: raw), (0..<4_096).contains(index) else { throw CoincideError(PiProtocol.failure) }
            let thought = kind.hasPrefix("thinking"), key = "m\(message)-\(thought ? "r" : "t")-\(index)"
            let value: String
            if kind.hasSuffix("_delta") {
                guard let chunk = delta["delta"].string else { throw CoincideError(PiProtocol.failure) }
                value = (text[key] ?? "") + chunk
            } else { value = delta["content"].string ?? delta["thinking"].string ?? text[key] ?? "" }
            return [try replace(key: key, value: value, type: thought ? "agent_thought" : "agent_message")]
        }
        if type == "message_end", frame["message"]["role"].string == "assistant" {
            guard assistant else { return [] }; assistant = false
            guard let blocks = frame["message"]["content"].array, blocks.count <= 4_096 else { return [] }
            var updates: [ProviderEntityUpdate] = []
            for (index, block) in blocks.enumerated() {
                let thought = block["type"].string == "thinking"
                guard thought || block["type"].string == "text" else { continue }
                let key = "m\(message)-\(thought ? "r" : "t")-\(index)"
                guard let value = block[thought ? "thinking" : "text"].string else { throw CoincideError(PiProtocol.failure) }
                updates.append(try replace(key: key, value: value, type: thought ? "agent_thought" : "agent_message"))
            }
            return updates
        }
        guard ["tool_execution_start", "tool_execution_update", "tool_execution_end"].contains(type) else { return [] }
        let id = try PiProtocol.id(frame["toolCallId"])
        if type == "tool_execution_start" { guard tools.count < 4_096 else { throw CoincideError(PiProtocol.failure) }; tools.insert(id) }
        guard tools.contains(id) else { return [] }
        var fields: [String: JSONValue] = ["status": .string(type == "tool_execution_end" ? (frame["isError"] == .bool(true) ? "failed" : "completed") : "in_progress")]
        if let name = frame["toolName"].string { guard name.utf8.count <= 1_024 else { throw CoincideError(PiProtocol.failure) }; fields["title"] = .string(name) }
        let result = type == "tool_execution_update" ? frame["partialResult"] : frame["result"]
        if let content = result["content"].array {
            guard content.count <= 256 else { throw CoincideError(PiProtocol.failure) }
            let output = content.filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
            let budgetKey = "tool-\(id)"; try retain(key: budgetKey, value: output)
            fields["content"] = .array([.object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string(output)])])])
        }
        return [.patch(.init(sessionID: scope, type: "tool_call", id: id), .object(fields))]
    }
    private mutating func retain(key: String, value: String) throws {
        let next = bytes - (text[key]?.utf8.count ?? 0) + value.utf8.count
        guard next <= 16 * 1_024 * 1_024, text.count < 16_384 || text[key] != nil else { throw CoincideError(PiProtocol.failure) }
        text[key] = value; bytes = next
    }
    private mutating func replace(key: String, value: String, type: String) throws -> ProviderEntityUpdate {
        try retain(key: key, value: value)
        return .patch(.init(sessionID: scope, type: type, id: key), .object(["content": .array([.object(["type": .string("text"), "text": .string(value)])])]))
    }
}
