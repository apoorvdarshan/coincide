import Foundation

/// Projection only: the session actor must first prove user/assistant/child
/// ownership. Native v1 snapshots replace text; deltas append to a known part.
/// Bounds apply to retained content, so repeated whole-part snapshots do not
/// impose a quadratic byte budget on a normal streamed response.
public struct OpenCodeV1Projection: Sendable {
    public enum ChildOutcome: String, Sendable { case completed, failed, interrupted }
    private let instanceID: UUID
    private let sessionID: String
    private let projectionID = UUID()
    private var parts: [String: Item] = [:]
    private var calls: [String: String] = [:]
    private var retainedBytes = 0
    private var updateCount = 0
    private struct Item: Sendable {
        let messageID: String
        let kind: String
        var text = ""
        var bytes = 0
        var ended = false
        var suppressed = false
        var toolName: String?
        var callID: String?
        var childID: String?
        var childTerminal = false
    }
    public init(instanceID: UUID, sessionID: String) { self.instanceID = instanceID; self.sessionID = sessionID }
    public func isTaskCall(messageID: String, callID: String) -> Bool {
        guard let id = calls[callKey(messageID, callID)] else { return false }
        return parts[id]?.toolName == "task"
    }
    public mutating func childCompleted(messageID: String, callID: String, childSessionID: String,
                                        outcome: ChildOutcome) throws -> [ProviderEntityUpdate] {
        guard let id = calls[callKey(messageID, callID)], var item = parts[id], item.toolName == "task",
              item.childID == childSessionID else { throw OpenCodeV1ProtocolError.invalidOwner }
        guard !item.childTerminal else { return [] }
        item.childTerminal = true; item.ended = true; parts[id] = item
        return [.patch(key(item, id: id), .object(["status": .string(outcome.rawValue),
            "_meta": metadata(messageID: messageID, partID: id, childID: childSessionID)]))]
    }
    public mutating func apply(_ event: OpenCodeV1Event) throws -> [ProviderEntityUpdate] {
        guard event.sessionID == sessionID else { throw OpenCodeV1ProtocolError.invalidOwner }
        updateCount += 1
        guard updateCount <= 100_000 else { throw OpenCodeV1ProtocolError.limitExceeded }
        switch event.kind {
        case .partUpdated:
            guard let part = event.part, part.sessionID == sessionID else { throw OpenCodeV1ProtocolError.invalidOwner }
            return try snapshot(part)
        case .partDelta:
            guard event.field == "text" else { return [] }
            guard let id = event.partID, let messageID = event.messageID, event.field == "text",
                  var item = parts[id], item.messageID == messageID,
                  item.kind == "agent_message" || item.kind == "agent_thought", let delta = event.delta else {
                throw OpenCodeV1ProtocolError.invalidOwner
            }
            if item.ended || item.suppressed { return [] }
            let size = delta.utf8.count
            guard item.text.utf8.count <= 4_194_304 - size else { throw OpenCodeV1ProtocolError.limitExceeded }
            try reserve(size, replacing: 0, isNew: false)
            item.text += delta; item.bytes += size; parts[id] = item
            return [.content(key(item, id: id), field: "content",
                value: .object(["type": .string("text"), "text": .string(delta)]), annotation: nil)]
        case .partRemoved:
            guard let id = event.partID, let messageID = event.messageID, let item = parts[id] else { return [] }
            guard item.messageID == messageID else { throw OpenCodeV1ProtocolError.invalidOwner }
            return remove(id, item: item)
        case .messageRemoved:
            guard let messageID = event.messageID else { throw OpenCodeV1ProtocolError.invalidOwner }
            var result: [ProviderEntityUpdate] = []
            for (id, item) in parts.filter({ $0.value.messageID == messageID }) { result += remove(id, item: item) }
            return result
        case .todoUpdated:
            guard let todos = event.todos else { throw OpenCodeV1ProtocolError.invalidResponse }
            let value: JSONValue = .array(todos.map { .object([
                "content": .string($0.content), "status": .string($0.status), "priority": .string($0.priority)
            ]) })
            let id = "todos-\(projectionID.uuidString.lowercased())"
            let old = parts[id]
            let size = try JSONEncoder().encode(value).count
            try reserve(size, replacing: old?.bytes ?? 0, isNew: old == nil)
            parts[id] = .init(messageID: "", kind: "plan", bytes: size)
            return [.patch(key(parts[id]!, id: id), .object(["entries": value, "_meta": metadata()]))]
        case .sessionCompacted:
            let id = "compaction-\(projectionID.uuidString.lowercased())"
            if parts[id] != nil { return [] }
            try reserve(0, replacing: 0, isNew: true)
            let item = Item(messageID: "", kind: "compaction", ended: true); parts[id] = item
            return [.patch(key(item, id: id), .object(["status": .string("completed"),
                "summary": .array([.object(["type": .string("text"), "text": .string("The native conversation was compacted.")])]),
                "_meta": metadata()]))]
        default: return []
        }
    }
    private mutating func snapshot(_ part: OpenCodeV1Part) throws -> [ProviderEntityUpdate] {
        if let old = parts[part.id], old.messageID != part.messageID { throw OpenCodeV1ProtocolError.invalidOwner }
        if part.type == "text" || part.type == "reasoning" {
            let kind = part.type == "text" ? "agent_message" : "agent_thought"
            if let old = parts[part.id], old.kind != kind { throw OpenCodeV1ProtocolError.invalidOwner }
            let text = part.ignored || part.synthetic ? "" : part.text ?? ""
            let old = parts[part.id]
            if old?.ended == true, !part.completed { return [] }
            let size = text.utf8.count
            try reserve(size, replacing: old?.bytes ?? 0, isNew: old == nil)
            var item = Item(messageID: part.messageID, kind: kind, text: text, bytes: size,
                ended: part.completed, suppressed: part.ignored || part.synthetic)
            if old?.ended == true { item.ended = true }
            parts[part.id] = item
            return [.patch(key(item, id: part.id), .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "_meta": metadata(messageID: part.messageID, partID: part.id)
            ]))]
        }
        guard let tool = part.tool else { return [] }
        let old = parts[part.id]
        if let old, old.kind != "tool_call" || old.callID != tool.callID || old.toolName != tool.name {
            throw OpenCodeV1ProtocolError.invalidOwner
        }
        let callKey = callKey(part.messageID, tool.callID)
        if let previousPart = calls[callKey], previousPart != part.id { throw OpenCodeV1ProtocolError.invalidOwner }
        if old?.childTerminal == true { return [] }
        if old?.ended == true, !["completed", "error"].contains(tool.status) { return [] }
        if let child = old?.childID, let incoming = tool.childSessionID, child != incoming { throw OpenCodeV1ProtocolError.invalidOwner }
        let child = tool.childSessionID ?? old?.childID
        let waitingForChild = tool.name == "task" && child != nil && tool.status == "completed"
        let nativeTerminal = ["completed", "error"].contains(tool.status) && !waitingForChild
        let status = waitingForChild || tool.status == "running" ? "in_progress" :
            tool.status == "error" ? "failed" : tool.status
        let output: [JSONValue] = tool.output.map { [.object(["type": .string("content"),
            "content": .object(["type": .string("text"), "text": .string($0)])])] } ?? []
        let patch: JSONValue = .object([
            "title": .string(tool.title ?? tool.name),
            "kind": .string(tool.name == "bash" ? "execute" : ["edit", "write", "apply_patch"].contains(tool.name) ? "edit" : "other"),
            "status": .string(status), "rawInput": tool.input, "content": .array(output),
            "_meta": metadata(messageID: part.messageID, partID: part.id, callID: tool.callID, childID: child)
        ])
        let size = try JSONEncoder().encode(patch).count
        try reserve(size, replacing: old?.bytes ?? 0, isNew: old == nil)
        parts[part.id] = .init(messageID: part.messageID, kind: "tool_call", bytes: size, ended: nativeTerminal,
            toolName: tool.name, callID: tool.callID, childID: child)
        calls[callKey] = part.id
        if tool.name == "question" { return [] }
        return [.patch(key(parts[part.id]!, id: part.id), patch)]
    }
    private mutating func remove(_ id: String, item: Item) -> [ProviderEntityUpdate] {
        retainedBytes -= item.bytes; parts.removeValue(forKey: id)
        if let callID = item.callID { calls.removeValue(forKey: callKey(item.messageID, callID)) }
        return [.patch(key(item, id: id), .object(["content": .array([]), "rawInput": .null,
            "_meta": metadata(messageID: item.messageID, partID: id, removed: true)]))]
    }
    private mutating func reserve(_ incoming: Int, replacing: Int, isNew: Bool) throws {
        guard incoming >= 0, replacing <= retainedBytes, incoming <= 16_777_216 - (retainedBytes - replacing),
              !isNew || parts.count < 4_096 else { throw OpenCodeV1ProtocolError.limitExceeded }
        retainedBytes += incoming - replacing
    }
    private func callKey(_ message: String, _ call: String) -> String { encoded([message, call]) }
    private func key(_ item: Item, id: String) -> ProviderEntityKey {
        .init(sessionID: "opencode1:\(instanceID.uuidString.lowercased()):\(sessionID)",
            type: item.kind, id: encoded([item.messageID, item.callID ?? id]))
    }
    private func encoded(_ values: [String]) -> String { String(decoding: (try? JSONEncoder().encode(values)) ?? Data(), as: UTF8.self) }
    private func metadata(messageID: String? = nil, partID: String? = nil, callID: String? = nil,
                          childID: String? = nil, removed: Bool = false) -> JSONValue {
        var values: [String: JSONValue] = ["generation": .string("1"), "sessionID": .string(sessionID),
            "instanceID": .string(instanceID.uuidString.lowercased())]
        if let messageID { values["messageID"] = .string(messageID) }
        if let partID { values["partID"] = .string(partID) }
        if let callID { values["callID"] = .string(callID) }
        if let childID { values["childSessionID"] = .string(childID) }
        if removed { values["removed"] = .bool(true) }
        return .object(["opencode": .object(values)])
    }
}
