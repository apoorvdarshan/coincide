import Foundation

/// Flat native ACP snapshots/chunks belong to one original app run. Tool IDs
/// survive foreground completion; start_subagent is a tool, not a guessed child.
struct AntigravityProjection {
    let scope: String
    private var tools: [String: JSONValue] = [:]
    private var text: [String: String] = [:]
    private var segment = 0
    private var lastType: String?
    private var updates = 0
    init(scope: String) { self.scope = scope }
    private static let marker = "[Earlier output truncated]\n\n"
    static func bounded(_ text: String, limit: Int = 8_000) -> String {
        text.count <= limit ? text : marker + String(text.suffix(limit))
    }
    static func sanitized(_ value: JSONValue, depth: Int = 0, remaining: inout Int) -> JSONValue {
        guard depth <= 12, remaining > 0 else { return .null }; remaining -= 1
        switch value {
        case .string(let text): return text.hasPrefix("data:image/") ? .null : .string(bounded(text))
        case .array(let rows): return .array(rows.prefix(256).map { sanitized($0, depth: depth + 1, remaining: &remaining) })
        case .object(let fields):
            var result: [String: JSONValue] = [:]
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                guard remaining > 0 else { break }
                let lower = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if ["apikey", "password", "authorization", "headers", "environment", "env", "credentials", "accesstoken", "refreshtoken", "privatekey"].contains(lower) || lower.contains("secret") { continue }
                if fields["type"] == .string("image"), ["data", "blob"].contains(key) { continue }
                result[key] = sanitized(value, depth: depth + 1, remaining: &remaining)
            }
            return .object(result)
        default: return value
        }
    }
    mutating func apply(_ update: JSONValue) throws -> [ProviderEntityUpdate] {
        updates += 1; guard updates <= 100_000 else { throw AntigravityProtocol.failure() }
        let variant = try AntigravityProtocol.string(update["sessionUpdate"], maximum: 128)
        if ["agent_message_chunk", "agent_thought_chunk"].contains(variant) {
            guard update["content"]["type"] == .string("text") else { return [] }
            let delta = try AntigravityProtocol.string(update["content"]["text"], maximum: 1_048_576, empty: true)
            let type = variant == "agent_message_chunk" ? "agent_message" : "agent_thought"
            if lastType != type { segment += 1 }; lastType = type
            let id = "segment-\(segment)", current = (text[id] ?? "") + delta
            guard current.utf8.count <= 4 * 1_024 * 1_024 else { throw AntigravityProtocol.failure() }; text[id] = current
            try budget()
            return [.patch(.init(sessionID: scope, type: type, id: id), .object(["content": .array([.object(["type": .string("text"), "text": .string(current)])])]))]
        }
        lastType = nil
        if variant == "plan" {
            guard let rows = update["entries"].array, rows.count <= 256 else { throw AntigravityProtocol.failure() }
            var remaining = 512
            return [.patch(.init(sessionID: scope, type: "plan", id: "plan"), .object(["entries": Self.sanitized(.array(rows), remaining: &remaining)]))]
        }
        guard variant == "tool_call" || variant == "tool_call_update" else { return [] }
        let id = try AntigravityProtocol.string(update["toolCallId"])
        guard tools[id] != nil || tools.count < 1_024 else { throw AntigravityProtocol.failure() }
        var fields = tools[id]?.object ?? [:], remaining = 512
        for key in ["title", "kind", "status", "rawInput", "rawOutput", "content", "locations", "_meta"] where update[key] != .null {
            fields[key] = Self.sanitized(update[key], remaining: &remaining)
        }
        let input = fields["rawInput"] ?? .null, output = fields["rawOutput"] ?? .null
        let command = ["CommandLine", "command_line", "commandLine", "command"].compactMap { input[$0].string }.first
            ?? ["commandLine", "command_line"].compactMap { output[$0].string }.first
        let cwd = ["Cwd", "WorkingDirectory", "working_dir", "workingDir", "cwd"].compactMap { input[$0].string }.first
            ?? ["workingDir", "working_dir"].compactMap { output[$0].string }.first
        if let command { fields["command"] = .string(Self.bounded(command)); if fields["kind"] == nil { fields["kind"] = .string("execute") } }
        if let cwd { fields["cwd"] = .string(Self.bounded(cwd)) }
        if let native = output["combinedOutput"].string ?? output["combined_output"].string ?? output.string {
            fields["content"] = .array([.object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string(Self.bounded(native))])])])
        }
        if let code = output.object?["exitCode"] ?? output.object?["exit_code"] { fields["exitCode"] = code }
        let title = fields["title"]?.string ?? "Tool"
        if ["Running start_subagent", "Run start_subagent?"].contains(title), fields["kind"] == nil || fields["kind"] == .string("other") {
            var meta = fields["_meta"]?.object ?? [:]
            meta["antigravityToolKind"] = .string(meta["is_mcp_tool_call"] == .bool(true) ? "mcp" : "subagent")
            fields["_meta"] = .object(meta)
        }
        let result = JSONValue.object(fields); tools[id] = result; try budget()
        return [.patch(.init(sessionID: scope, type: "tool_call", id: id), result)]
    }
    mutating func finish() -> [ProviderEntityUpdate] {
        tools.keys.sorted().compactMap { id in
            guard var fields = tools[id]?.object, fields["_meta"]?["antigravityToolKind"] == .string("subagent"),
                  fields["status"] == .string("in_progress") || fields["status"] == .string("pending") else { return nil }
            fields["status"] = .string("completed"); tools[id] = .object(fields)
            return .patch(.init(sessionID: scope, type: "tool_call", id: id), .object(["status": .string("completed")]))
        }
    }
    private func budget() throws {
        let toolBytes = try JSONEncoder().encode(tools).count, textBytes = text.values.reduce(0) { $0 + $1.utf8.count }
        guard toolBytes + textBytes <= 16 * 1_024 * 1_024 else { throw AntigravityProtocol.failure() }
    }
}
