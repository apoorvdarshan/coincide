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
    public init(key: ProviderEntityKey, fields: JSONValue = .object([:])) { self.key = key; self.fields = fields }
    public var role: MessageRole { .tool }
    public var text: String {
        switch key.type {
        case "tool_call":
            let header = [fields["title"].string ?? "Tool", fields["status"].string].compactMap { $0 }.joined(separator: " · ")
            let content = (fields["content"].array ?? []).map { item -> String in
                if item["type"].string == "content" { return Self.contentText([item["content"]]) }
                if item["type"].string == "diff" { return item["patch"]["text"].string ?? item.pretty }
                if item["type"].string == "terminal" { return "Terminal: \(item["terminalId"].string ?? "")" }
                return item.pretty
            }.joined(separator: "\n")
            return [header, content].filter { !$0.isEmpty }.joined(separator: "\n")
        case "plan":
            if let entries = fields["entries"].array {
                return entries.map { "- [\($0["status"].string == "completed" ? "x" : " ")] \($0["content"].string ?? "")" }.joined(separator: "\n")
            }
            return fields["content"].string ?? fields.pretty
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
    case patch(ProviderEntityKey, JSONValue)
    public var key: ProviderEntityKey {
        switch self { case .patch(let key, _): key }
    }
    public func apply(to previous: ProviderEntity?) throws -> ProviderEntity {
        guard previous == nil || previous?.key == key else { throw CoincideError("A provider update targeted a different entity.") }
        var entity = previous ?? ProviderEntity(key: key), fields = entity.fields.object ?? [:]
        if previous == nil, key.type == "tool_call" { fields["status"] = .string("pending") }
        switch self {
        case .patch(_, let patch):
            guard let patch = patch.object else { throw CoincideError("A provider entity patch must be an object.") }
            for (name, value) in patch {
                if name == "_meta", let metadata = value.object {
                    var merged = fields[name]?.object ?? [:]
                    for (key, value) in metadata { if value == .null { merged.removeValue(forKey: key) } else { merged[key] = value } }
                    fields[name] = .object(merged)
                } else if value == .null { fields.removeValue(forKey: name) }
                else { fields[name] = value }
            }
        }
        entity.fields = .object(fields); return entity
    }
}
