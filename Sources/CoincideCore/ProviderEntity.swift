import CryptoKit
import Foundation

/// Provider IDs are opaque and only unique within an entity type and session.
public struct ProviderEntityKey: Codable, Hashable, Sendable {
    public var sessionID: String
    public var type: String
    public var id: String
    public init(sessionID: String, type: String, id: String) { self.sessionID = sessionID; self.type = type; self.id = id }
    public var messageID: String {
        let bytes = (try? JSONEncoder().encode([sessionID, type, id])) ?? Data()
        return "entity-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ProviderEntity: Codable, Equatable, Sendable {
    public var key: ProviderEntityKey
    public var fields: JSONValue
    /// Chunk metadata belongs to the chunk, never to the entity's `_meta` patch.
    /// Unknown top-level chunk fields are retained here too.
    public var chunkAnnotations: [JSONValue]?
    public var envelopeAnnotations: [JSONValue]?
    public init(key: ProviderEntityKey, fields: JSONValue = .object([:])) { self.key = key; self.fields = fields }
    public var role: MessageRole {
        switch key.type { case "user_message": .user; case "agent_message": .assistant; case "agent_thought": .reasoning; default: .tool }
    }
    public var text: String {
        switch key.type {
        case "user_message", "agent_message", "agent_thought": return Self.contentText(fields["content"].array ?? [])
        case "tool_call":
            let header = [fields["title"].string ?? "Tool", fields["status"].string].compactMap { $0 }.joined(separator: " · ")
            let content = (fields["content"].array ?? []).map { item -> String in
                if item["type"].string == "content" { return Self.contentText([item["content"]]) }
                if item["type"].string == "diff" { return item["patch"]["text"].string ?? item.pretty }
                if item["type"].string == "terminal" { return "Terminal: \(item["terminalId"].string ?? "")" }
                return item.pretty
            }.joined(separator: "\n")
            return [header, content].filter { !$0.isEmpty }.joined(separator: "\n")
        case "terminal":
            let data = Data(base64Encoded: fields["output"]["data"].string ?? "") ?? Data()
            return [fields["command"].string ?? "Terminal", String(decoding: data, as: UTF8.self)].joined(separator: "\n")
        case "plan":
            if let entries = fields["entries"].array {
                return entries.map { "- [\($0["status"].string == "completed" ? "x" : " ")] \($0["content"].string ?? "")" }.joined(separator: "\n")
            }
            return fields["content"].string ?? fields.pretty
        case "compaction": return "Context compaction · \(fields["status"].string ?? "in_progress")\n" + Self.contentText(fields["summary"].array ?? [])
        default: return fields.pretty
        }
    }
    private static func contentText(_ content: [JSONValue]) -> String {
        content.map { block in
            if let text = block["text"].string, block["type"].string == "text" { return text }
            if let text = block["resource"]["text"].string, block["type"].string == "resource" { return text }
            if block["type"].string == "resource_link" { return block["name"].string ?? block["uri"].string ?? "Resource" }
            return "[\(block["type"].string ?? "Unknown") content]"
        }.joined()
    }
}

public enum ProviderEntityUpdate: Codable, Equatable, Sendable {
    case patch(ProviderEntityKey, JSONValue, envelope: JSONValue? = nil)
    case content(ProviderEntityKey, field: String, value: JSONValue, annotation: JSONValue?)
    case terminalBytes(ProviderEntityKey, data: Data, annotation: JSONValue?)
    public var key: ProviderEntityKey {
        switch self { case .patch(let key, _, _), .content(let key, _, _, _), .terminalBytes(let key, _, _): key }
    }
    public func apply(to previous: ProviderEntity?) throws -> ProviderEntity {
        guard previous == nil || previous?.key == key else { throw CoincideError("A provider update targeted a different entity.") }
        var entity = previous ?? ProviderEntity(key: key), fields = entity.fields.object ?? [:]
        if previous == nil {
            if key.type == "tool_call" { fields["status"] = .string("pending") }
            if key.type == "compaction" { fields["status"] = .string("in_progress") }
        }
        switch self {
        case .patch(_, let patch, let envelope):
            guard let patch = patch.object else { throw CoincideError("A provider entity patch must be an object.") }
            if key.type == "terminal", let output = patch["output"], output != .null {
                guard let data = output["data"].string, Data(base64Encoded: data) != nil else { throw CoincideError("The agent terminal snapshot is not valid base64.") }
            }
            if let envelope { if entity.envelopeAnnotations == nil { entity.envelopeAnnotations = [] }; entity.envelopeAnnotations?.append(envelope) }
            for (name, value) in patch {
                if name == "_meta", let metadata = value.object {
                    var merged = fields[name]?.object ?? [:]
                    for (key, value) in metadata { if value == .null { merged.removeValue(forKey: key) } else { merged[key] = value } }
                    fields[name] = .object(merged)
                } else if value == .null { fields.removeValue(forKey: name) }
                else { fields[name] = value }
            }
            // A replacement invalidates chunk annotations for that content field.
            for field in ["content", "summary", "output"] where patch[field] != nil {
                entity.chunkAnnotations?.removeAll { $0["field"].string == field }
            }
        case .content(_, let field, let value, let annotation):
            var content = fields[field]?.array ?? []
            if let annotation { entity.annotate(annotation, field: field, offset: content.count) }
            content.append(value); fields[field] = .array(content)
        case .terminalBytes(_, let data, let annotation):
            var output = fields["output"]?.object ?? [:]
            var bytes = Data(base64Encoded: output["data"]?.string ?? "") ?? Data()
            if let annotation { entity.annotate(annotation, field: "output", offset: bytes.count) }
            bytes.append(data); output["data"] = .string(bytes.base64EncodedString()); fields["output"] = .object(output)
        }
        if entity.chunkAnnotations?.isEmpty == true { entity.chunkAnnotations = nil }
        entity.fields = .object(fields); return entity
    }
    /// Only ACP v2 entity variants enter this reducer. Activity/configuration and
    /// live notices have separate lifecycles and must be handled by the adapter.
    public static func acp(_ update: JSONValue, sessionID: String, unknownID: UUID = UUID()) throws -> Self {
        guard var fields = update.object, let variant = fields["sessionUpdate"]?.string else { throw CoincideError("Invalid ACP session update.") }
        let type: String, idField: String
        switch variant {
        case "user_message", "user_message_chunk": type = "user_message"; idField = "messageId"
        case "agent_message", "agent_message_chunk": type = "agent_message"; idField = "messageId"
        case "agent_thought", "agent_thought_chunk": type = "agent_thought"; idField = "messageId"
        case "tool_call_update", "tool_call_content_chunk": type = "tool_call"; idField = "toolCallId"
        case "terminal_update", "terminal_output_chunk": type = "terminal"; idField = "terminalId"
        case "compaction_update", "compaction_summary_chunk": type = "compaction"; idField = "compactionId"
        case "plan_update":
            guard let plan = fields["plan"], let id = plan["planId"].string else { throw CoincideError("The agent plan has no identity.") }
            fields.removeValue(forKey: "plan"); fields.removeValue(forKey: "sessionUpdate")
            return .patch(.init(sessionID: sessionID, type: "plan", id: id), plan, envelope: fields.isEmpty ? nil : .object(fields))
        default:
            // Future variants retain the complete raw payload, including its tag.
            return .patch(.init(sessionID: sessionID, type: "unknown", id: unknownID.uuidString), update)
        }
        guard let id = fields[idField]?.string, !id.isEmpty else { throw CoincideError("The agent entity has no identity.") }
        let key = ProviderEntityKey(sessionID: sessionID, type: type, id: id)
        fields.removeValue(forKey: "sessionUpdate"); fields.removeValue(forKey: idField)
        if variant.hasSuffix("_chunk") {
            let field = variant == "compaction_summary_chunk" ? "summary" : "content"
            if variant == "terminal_output_chunk" {
                guard let encoded = fields.removeValue(forKey: "data")?.string, let data = Data(base64Encoded: encoded) else { throw CoincideError("The agent terminal chunk is not valid base64.") }
                return .terminalBytes(key, data: data, annotation: fields.isEmpty ? nil : .object(fields))
            }
            guard let content = fields.removeValue(forKey: "content"), content.object != nil else { throw CoincideError("The agent content chunk is invalid.") }
            return .content(key, field: field, value: content, annotation: fields.isEmpty ? nil : .object(fields))
        }
        return .patch(key, .object(fields))
    }
}

private extension ProviderEntity {
    mutating func annotate(_ value: JSONValue, field: String, offset: Int) {
        if chunkAnnotations == nil { chunkAnnotations = [] }
        chunkAnnotations?.append(.object(["field": .string(field), "offset": .number(Double(offset)), "value": value]))
    }
}
