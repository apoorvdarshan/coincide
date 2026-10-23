import Foundation

/// SDK assistant envelopes carry completed blocks, often one at a time with a
/// local content index of zero. Only stream events carry the native block index.
struct ClaudeMessageBlocks {
    private struct Key: Hashable {
        let parent: String?
        let message: String
    }
    private struct Block {
        let kind: String
        let toolID: String?
        var finalized = false
    }
    private struct Signature: Hashable {
        let kind: String
        let toolID: String?
        init(kind: String, toolID: String?) { self.kind = kind; self.toolID = kind == "tool_use" ? toolID : nil }
    }
    private struct Message {
        var blocks: [Int: Block] = [:]
        var envelopes: Set<String> = []
    }
    private var current: [String: Key] = [:]
    private var messages: [Key: Message] = [:]
    private var blockCount = 0
    private var envelopeCount = 0
    // Per-turn limits, including children. Never evict live identity evidence:
    // an over-limit producer fails instead of silently creating duplicate rows.
    static let maximumMessages = 4_096
    static let maximumBlocks = 16_384

    mutating func beginTurn() {
        // Background child streams may span two explicit root inputs. Keep only
        // their still-open message ownership; completed/root evidence is per turn.
        current = current.filter { $0.value.parent != nil }
        let active = Set(current.values)
        messages = messages.filter { active.contains($0.key) }
        blockCount = messages.values.reduce(0) { $0 + $1.blocks.count }
        envelopeCount = messages.values.reduce(0) { $0 + $1.envelopes.count }
    }

    mutating func start(messageID: String?, parent: String?) throws {
        let key = try key(messageID: messageID, parent: parent)
        try ensureMessage(key)
        current[owner(parent)] = key
    }

    mutating func stop(parent: String?) { current.removeValue(forKey: owner(parent)) }

    mutating func stream(index value: JSONValue, kind: String, toolID: String? = nil, parent: String?) throws -> String? {
        // A child delta without its own start must never inherit the root ID.
        guard let key = current[owner(parent)] else { return nil }
        guard case .number(let number) = value, number.isFinite, number >= 0,
              number <= Double(Self.maximumBlocks), number.rounded() == number else { throw Self.invalid() }
        let index = Int(number)
        try ensureBlock(key, index: index, kind: kind, toolID: toolID)
        guard messages[key]?.blocks[index]?.finalized == false else { return nil }
        return identity(key, index: index, toolID: toolID)
    }

    mutating func final(messageID: String?, content: [JSONValue], envelopeID: String?, parent: String?) throws -> [String]? {
        let key = try key(messageID: messageID, parent: parent)
        try ensureMessage(key)
        if let envelopeID {
            guard Self.valid(envelopeID) else { throw Self.invalid() }
            if messages[key]!.envelopes.contains(envelopeID) { return nil }
            guard envelopeCount < Self.maximumBlocks else { throw Self.invalid() }
            messages[key]!.envelopes.insert(envelopeID); envelopeCount += 1
        }
        guard content.count <= Self.maximumBlocks else { throw Self.invalid() }
        var candidates: [Signature: [Int]] = [:], cursors: [Signature: Int] = [:]
        for index in messages[key]!.blocks.keys.sorted() {
            let known = messages[key]!.blocks[index]!
            if content.count > 1 || !known.finalized {
                candidates[Signature(kind: known.kind, toolID: known.toolID), default: []].append(index)
            }
        }
        var nextIndex = (messages[key]!.blocks.keys.max() ?? -1) + 1
        var result: [String] = []
        for block in content {
            let kind = block["type"].string ?? "unknown", toolID = block["id"].string
            // A multi-block envelope is an aggregate snapshot. Match its ordered
            // occurrences even when a preceding per-block envelope finalized one.
            // Single-block envelopes consume only the next unfinished occurrence;
            // equal text in two separate native blocks must remain two blocks.
            let signature = Signature(kind: kind, toolID: toolID), cursor = cursors[signature, default: 0]
            let index: Int
            if let matching = candidates[signature], cursor < matching.count { index = matching[cursor] }
            else { index = nextIndex; nextIndex += 1 }
            cursors[signature] = cursor + 1
            try ensureBlock(key, index: index, kind: kind, toolID: toolID)
            messages[key]!.blocks[index]!.finalized = true
            result.append(identity(key, index: index, toolID: kind == "tool_use" ? toolID : nil))
        }
        return result
    }

    private mutating func ensureMessage(_ key: Key) throws {
        guard messages[key] == nil else { return }
        guard messages.count < Self.maximumMessages else { throw Self.invalid() }
        messages[key] = Message()
    }
    private mutating func ensureBlock(_ key: Key, index: Int, kind: String, toolID: String?) throws {
        guard !kind.isEmpty, kind.utf8.count <= 256, toolID.map(Self.valid) ?? true else { throw Self.invalid() }
        if let block = messages[key]?.blocks[index] {
            guard block.kind == kind, kind != "tool_use" || block.toolID == toolID else { throw Self.invalid() }
            return
        }
        guard blockCount < Self.maximumBlocks else { throw Self.invalid() }
        messages[key]!.blocks[index] = Block(kind: kind, toolID: toolID); blockCount += 1
    }
    private func key(messageID: String?, parent: String?) throws -> Key {
        let messageID = messageID ?? UUID().uuidString
        guard Self.valid(messageID), parent.map(Self.valid) ?? true else { throw Self.invalid() }
        return Key(parent: parent, message: messageID)
    }
    private func owner(_ parent: String?) -> String { parent.map { "child:" + $0 } ?? "root" }
    private func identity(_ key: Key, index: Int, toolID: String?) -> String {
        if let toolID { return toolID }
        // Keep existing root IDs stable, and isolate a child's same API ID/index.
        let prefix = key.parent.map { "claude-child-\($0.utf8.count):\($0):" } ?? ""
        return "\(prefix)\(key.message)-\(index)"
    }
    private static func valid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 4_096 && !value.contains("\0") }
    private static func invalid() -> CoincideError { .init("Claude sent invalid or excessive message block identities.") }
}
