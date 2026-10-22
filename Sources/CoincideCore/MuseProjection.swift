import Foundation

/// One exact native session/original-run view. Native revisions replace full
/// snapshots; cursors are opaque and never used to discard another method.
struct MuseProjection {
    let scope: String
    private struct Item { var revision: Int; var fields: JSONValue }
    private var items: [String: Item] = [:]
    private var bytes = 0
    init(scope: String) { self.scope = scope }
    mutating func apply(method: String, params: JSONValue) throws -> [ProviderEntityUpdate] {
        if method == "item/delta" {
            let id = try identifier(params["itemId"])
            guard var item = items[id], item.fields["status"].string == "inProgress" else { return [] } // Owner/live snapshot is required.
            guard let delta = params["delta"].string, delta.utf8.count <= 1_048_576 else { throw MuseProjection.failure() }
            let field = params["field"].string ?? "text"
            var object = item.fields.object ?? [:]
            if ["text", "output", "visibleOutput"].contains(field) { object[field] = .string((object[field]?.string ?? "") + delta) }
            else if field.hasPrefix("summary."), let index = Int(field.dropFirst(8)), (0..<256).contains(index) {
                var summary = object["summary"]?.array ?? []
                while summary.count <= index { summary.append(.string("")) }
                summary[index] = .string((summary[index].string ?? "") + delta); object["summary"] = .array(summary)
            } else { return [] }
            let value = JSONValue.object(object)
            try budget(previous: item.fields, next: value)
            item.fields = value; items[id] = item
            return presentation(id, value)
        }
        guard ["item/started", "item/updated", "item/completed"].contains(method) else { return [] }
        let value = params["item"], id = try identifier(value["itemId"])
        guard case .number(let raw) = value["revision"], let revision = Int(exactly: raw), revision > 0 else { throw Self.failure() }
        if let previous = items[id], previous.revision >= revision { return [] }
        guard items[id] != nil || items.count < 4_096 else { throw Self.failure() }
        // Retain only actual display/lifecycle fields, never raw provider config,
        // credentials, arbitrary MCP metadata, or opaque error bodies.
        let known = Set(["kind", "status", "text", "summary", "output", "visibleOutput", "tool", "args", "title", "fallbackText", "objective", "role", "result", "failureKind", "childSessionId", "subagentId", "children", "truncated"])
        if let args = value["args"].string, args.utf8.count > 1_048_576 { throw Self.failure() }
        var selected = (value.object ?? [:]).filter { known.contains($0.key) }
        if let children = selected["children"]?.array {
            guard children.count <= 256 else { throw Self.failure() }
            let previous = items[id]?.fields["children"].array ?? []
            selected["children"] = .array(children.map { child in
                var fields = child.object ?? [:]
                if fields["label"] == nil, let old = previous.first(where: { $0["childId"] == child["childId"] }), old["label"] != .null { fields["label"] = old["label"] }
                return .object(fields)
            })
        }
        let sanitized = JSONValue.object(selected)
        try budget(previous: items[id]?.fields, next: sanitized)
        items[id] = .init(revision: revision, fields: sanitized)
        return presentation(id, sanitized)
    }
    private func presentation(_ id: String, _ value: JSONValue) -> [ProviderEntityUpdate] {
        let kind = value["kind"].string ?? "unknown"
        if kind == "userMessage" || kind == "reminderChild" { return [] }
        let type = kind == "agentMessage" ? "agent_message" : kind == "reasoning" ? "agent_thought" : "tool_call"
        var fields: [String: JSONValue] = ["_meta": .object(["museKind": .string(kind)])]
        let status = value["status"].string ?? "unknown"
        let children = value["children"].array ?? []
        let failed = value["failureKind"] != .null || children.contains { $0["failureKind"] != .null || $0["status"].string == "failed" }
        fields["status"] = .string(status == "inProgress" ? "in_progress" : failed || status == "failed" ? "failed" : status == "completed" ? "completed" : status == "cancelled" ? "cancelled" : "unknown")
        var text = value["text"].string ?? value["visibleOutput"].string ?? value["output"].string ??
            value["result"]["text"].string ?? value["result"]["summary"].string ?? value["summary"].array?.compactMap(\.string).joined(separator: "\n") ?? value["fallbackText"].string ?? value["objective"].string ?? ""
        if !children.isEmpty {
            let details = children.map { child in [child["label"].string ?? child["childId"].string ?? "Child", child["failureKind"] != .null ? "failed" : child["status"].string ?? "unknown"].joined(separator: " · ") }.joined(separator: "\n")
            text = [text, details].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if type == "tool_call" {
            fields["title"] = .string(value["title"].string ?? value["tool"].string ?? value["role"].string ?? kind)
            if let args = value["args"].string { fields["rawInput"] = (try? JSONDecoder().decode(JSONValue.self, from: Data(args.utf8))) ?? .string(args) }
            fields["content"] = .array([.object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string(text)])])])
        } else { fields["content"] = .array([.object(["type": .string("text"), "text": .string(text)])]) }
        if value["truncated"] == .bool(true) { fields["_meta"] = .object(["museKind": .string(kind), "truncated": .bool(true)]) }
        return [.patch(.init(sessionID: scope, type: type, id: id), .object(fields))]
    }
    private mutating func budget(previous: JSONValue?, next: JSONValue) throws {
        let old = try previous.map { try JSONEncoder().encode($0).count } ?? 0
        let size = try JSONEncoder().encode(next).count, total = bytes - old + size
        guard total <= 16 * 1_024 * 1_024 else { throw Self.failure() }; bytes = total
    }
    private func identifier(_ value: JSONValue) throws -> String {
        guard let text = value.string, !text.isEmpty, text.utf8.count <= 4_096, !text.contains("\u{0}") else { throw Self.failure() }; return text
    }
    static func failure() -> CoincideError { .init("The Muse stream could not be verified. Reopen the connection before continuing.") }
}
