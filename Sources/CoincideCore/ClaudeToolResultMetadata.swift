import Foundation

/// A small projection of fields actually present on a native tool_result.
/// Missing is_error stays missing; merely receiving a result proves no success.
enum ClaudeToolResultMetadata {
    static let entityType = "claude_tool_result"
    static func entity(block: JSONValue, sessionID: String?, parent: String?) -> ProviderEntity? {
        guard let id = block["tool_use_id"].string, valid(id), let sessionID, valid(sessionID) else { return nil }
        var fields: [String: JSONValue] = [:]
        if case .bool = block["is_error"] { fields["is_error"] = block["is_error"] }
        if let status = block["status"].string, valid(status, maximum: 256) { fields["status"] = .string(status) }
        if let parent, valid(parent) { fields["parent_tool_use_id"] = .string(parent) }
        return .init(key: .init(sessionID: sessionID, type: entityType, id: id), fields: .object(fields))
    }
    static func matches(_ message: ChatMessage, rootOnly: Bool = false) -> Bool {
        matches(message.providerEntity, messageID: message.id, rootOnly: rootOnly)
    }
    static func matches(_ value: ProviderEntity?, messageID: String, rootOnly: Bool = false) -> Bool {
        guard let entity = value, entity.key.type == entityType,
              valid(entity.key.id), valid(entity.key.sessionID),
              messageID.utf8.elementsEqual(("result-" + entity.key.id).utf8) else { return false }
        return !rootOnly || entity.fields["parent_tool_use_id"] == .null
    }
    static func outcome(_ message: ChatMessage) -> TranscriptToolStatus? {
        guard matches(message), let entity = message.providerEntity else { return nil }
        let fields = entity.fields
        switch fields["status"].string {
        case "declined", "denied", "rejected": return .declined
        case "cancelled", "canceled", "interrupted": return .cancelled
        case "failed", "error": return .failed
        default: break
        }
        if fields["is_error"] == .bool(true) {
            return isExplicitDecline(message.text) ? .declined : .failed
        }
        if fields["is_error"] == .bool(false) { return .completed }
        switch fields["status"].string {
        case "completed", "success": return .completed
        default: return nil
        }
    }
    static func isExplicitDecline(_ text: String) -> Bool {
        // Exact app/pinned-adapter denial messages, never a substring search.
        switch wrappedError(text) ?? text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Declined by the user in Coincide.", "User declined tool execution.": true
        default: false
        }
    }
    static func wrappedError(_ text: String) -> String? {
        guard text.utf8.count <= 2 * 1_048_576 else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let open = "<tool_use_error>", close = "</tool_use_error>"
        guard value.hasPrefix(open), value.hasSuffix(close) else { return nil }
        let body = String(value.dropFirst(open.count).dropLast(close.count))
        guard !body.contains(open), !body.contains(close) else { return nil }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func valid(_ value: String, maximum: Int = 4_096) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && !value.contains("\0")
    }
}
