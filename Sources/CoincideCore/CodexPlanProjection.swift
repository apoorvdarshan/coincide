import CryptoKit
import Foundation

/// Typed native plan items and the separate native task-list notification.
/// Keys include the original turn, so a reused item ID cannot replace another run.
struct CodexPlanProjection {
    static let maximumPlanBytes = 2 * 1_048_576
    static let maximumRetainedBytes = 8 * 1_048_576
    static let maximumItems = 256
    private struct Key: Hashable {
        let session: String; let turn: String; let item: String
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.session.utf8.elementsEqual(rhs.session.utf8) && lhs.turn.utf8.elementsEqual(rhs.turn.utf8) && lhs.item.utf8.elementsEqual(rhs.item.utf8)
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(Data(session.utf8)); hasher.combine(Data(turn.utf8)); hasher.combine(Data(item.utf8))
        }
    }
    private struct Item { let initialDigest: Data; var text: String; var completed: Bool; var terminal = false }
    private var items: [Key: Item] = [:]
    private var order: [Key] = []
    private var retainedBytes = 0
    private var todos: [Key: Data] = [:]

    mutating func project(_ method: String, params: JSONValue, sessionID: String) throws -> ProviderEntityUpdate? {
        guard params["threadId"].string?.utf8.elementsEqual(sessionID.utf8) == true, let turn = params["turnId"].string,
              MCPProtocol.text(turn, maximum: 4_096) else { throw invalid() }
        if method == "turn/plan/updated" { return try taskList(params, session: sessionID, turn: turn) }
        let raw = params["item"]
        let id = method == "item/plan/delta" ? params["itemId"].string : raw["id"].string
        guard let id, MCPProtocol.text(id, maximum: 4_096) else { throw invalid() }
        let key = Key(session: sessionID, turn: turn, item: id)
        var value = items[key]
        switch method {
        case "item/started":
            guard raw["type"] == .string("plan"), let text = raw["text"].string, text.utf8.count <= Self.maximumPlanBytes else { throw invalid() }
            if let value {
                guard value.initialDigest == Data(SHA256.hash(data: Data(text.utf8))) else { throw invalid() }
                return nil
            }
            value = .init(initialDigest: Data(SHA256.hash(data: Data(text.utf8))), text: text, completed: false)
        case "item/plan/delta":
            guard let delta = params["delta"].string, var current = value else { throw invalid() }
            // A delayed streamed chunk cannot append behind a final snapshot.
            if current.completed || current.terminal { return nil }
            guard delta.utf8.count <= Self.maximumPlanBytes - current.text.utf8.count else { throw invalid() }
            current.text += delta; value = current
        case "item/completed":
            guard raw["type"] == .string("plan"), let text = raw["text"].string, text.utf8.count <= Self.maximumPlanBytes else { throw invalid() }
            if let value, value.completed {
                guard value.text.utf8.elementsEqual(text.utf8) else { throw invalid() }
                return nil
            }
            value = .init(initialDigest: value?.initialDigest ?? Data(SHA256.hash(data: Data(text.utf8))), text: text, completed: true)
        default: return nil
        }
        guard let value, value.text.utf8.count <= Self.maximumPlanBytes else { throw invalid() }
        let previousBytes = items[key]?.text.utf8.count ?? 0
        try makeRoom(for: key, bytes: value.text.utf8.count - previousBytes)
        if items[key] == nil { order.append(key) }
        retainedBytes += value.text.utf8.count - previousBytes; items[key] = value
        return update(key, value: value)
    }

    mutating func terminal(turnID: String) -> [ProviderEntityUpdate] {
        var updates: [ProviderEntityUpdate] = []
        for key in order where key.turn.utf8.elementsEqual(turnID.utf8) {
            guard var value = items[key], !value.completed, !value.terminal else { continue }
            value.terminal = true; items[key] = value; updates.append(update(key, value: value))
        }
        return updates
    }
    private mutating func makeRoom(for key: Key, bytes: Int) throws {
        while (items[key] == nil && items.count >= Self.maximumItems) || retainedBytes + bytes > Self.maximumRetainedBytes {
            guard let old = order.first(where: { $0 != key && (items[$0]?.completed == true || items[$0]?.terminal == true) }),
                  let removed = items.removeValue(forKey: old) else { throw invalid() }
            retainedBytes -= removed.text.utf8.count; order.removeAll { $0 == old }
        }
    }
    private func update(_ key: Key, value: Item) -> ProviderEntityUpdate {
        .patch(entityKey(key, prefix: "plan"), .object([
            "content": .string(value.text), "status": .string(value.completed ? "completed" : value.terminal ? "unknown" : "in_progress"),
            "nativeItemID": .string(key.item), "nativeTurnID": .string(key.turn), "nativeKind": .string("proposed_plan")
        ]))
    }
    private mutating func taskList(_ params: JSONValue, session: String, turn: String) throws -> ProviderEntityUpdate? {
        guard let raw = params["plan"].array, raw.count <= 512 else { throw invalid() }
        var budget = 1_048_576
        let entries: [JSONValue] = try raw.map { row in
            guard let text = row["step"].string, text.utf8.count <= 65_536,
                  let status = row["status"].string, ["pending", "in_progress", "completed"].contains(status) else { throw invalid() }
            budget -= text.utf8.count + 64; guard budget >= 0 else { throw invalid() }
            return .object(["content": .string(text), "status": .string(status)])
        }
        let key = Key(session: session, turn: turn, item: "turn-plan")
        var fields: [String: JSONValue] = ["entries": .array(entries), "nativeTurnID": .string(turn), "nativeKind": .string("todo_list")]
        if let explanation = params["explanation"].string {
            guard explanation.utf8.count <= 65_536, explanation.utf8.count <= budget else { throw invalid() }
            fields["explanation"] = .string(explanation)
        } else if params["explanation"] != .null { throw invalid() }
        let value = JSONValue.object(fields)
        let digest = try fingerprint(value)
        if todos[key] == digest { return nil }
        if todos[key] == nil, todos.count >= 128 { todos.removeAll(keepingCapacity: true) }
        todos[key] = digest
        return .patch(entityKey(key, prefix: "todo"), value)
    }
    private func fingerprint(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(value)))
    }
    private func entityKey(_ key: Key, prefix: String) -> ProviderEntityKey {
        let framed = [key.session, key.turn, key.item].map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(sessionID: key.session, type: "plan", id: "codex-\(prefix)-\(digest)")
    }
    private func invalid() -> CoincideError { .init("The Codex plan stream exceeded its supported shape or bounded storage limit.") }
}
