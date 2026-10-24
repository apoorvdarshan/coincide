import Foundation

/// Public display bytes only. Native proofs remain in Engine's prepared-review
/// table and durable history ledger; a leased display cannot authorize action.
final class RemoteHistoryLease {
    let target: RemoteWorkspaceTarget
    let binding: RemoteHistoryBinding
    var reviewID: UUID?
    var messages: [RemoteMessageSummary] = []
    var paths: [String] = []
    var contents: [UUID: Data] = [:]
    var references: [UUID: RemoteProjectionContentReference] = [:]
    var bytes = 512
    var maximumBytes = RemoteHistoryProtocol.maximumCacheBytes
    private var documents: [String: UUID] = [:]
    private var positions: [UUID: (String, Int)] = [:]
    private var tokens: [String: UUID] = [:]
    init(target: RemoteWorkspaceTarget, binding: RemoteHistoryBinding, proofBytes: Int = 0) throws {
        self.target = target; self.binding = binding
        try account(proofBytes + RemoteHistoryProtocol.payload(target).count)
    }
    func account(_ count: Int) throws {
        guard count >= 0, bytes <= maximumBytes - count else { throw RemoteHistoryFailure(.limitExceeded) }
        bytes += count; try Task.checkCancellation()
    }
    func document(_ data: Data, kind: RemoteProjectionContentKind) throws -> RemoteProjectionContentReference {
        let digest = RemoteProjectionProtocol.digest(data), key = kind.rawValue + digest
        if let id = documents[key], let reference = references[id] { return reference }
        try account(data.count + 256)
        let result = RemoteProjectionContentReference(id: UUID(), kind: kind, totalBytes: data.count, digest: digest)
        documents[key] = result.id; references[result.id] = result; contents[result.id] = data
        return result
    }
    func json<T: Encodable>(_ value: T, kind: RemoteProjectionContentKind) throws -> RemoteProjectionContentReference {
        try document(RemoteHistoryProtocol.payload(value), kind: kind)
    }
    func text(_ value: String, kind: RemoteProjectionContentKind = .text) throws -> RemoteProjectionText {
        let bytes = Data(value.utf8)
        if bytes.count <= 1_024 { return .init(preview: value, complete: true) }
        var prefix = Data(bytes.prefix(1_024))
        while String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return .init(preview: String(decoding: prefix, as: UTF8.self), complete: false, content: try document(bytes, kind: kind))
    }
    func message(_ value: ChatMessage) throws -> RemoteMessageSummary {
        let result = try RemoteMessageSummary(id: value.id, role: value.role, createdAt: value.createdAt,
            text: text(value.providerEntity?.text ?? value.text),
            attachments: value.attachments.map { try json($0, kind: .attachmentReferences) }, attachmentCount: value.attachments?.count ?? 0,
            runReference: value.runReference, removedByHistoryOperationID: value.removedByHistoryOperationID,
            submissionError: value.submissionError.map { try text($0) }, title: value.providerEntity?.fields["title"].string.map { try text($0) },
            status: value.providerEntity?.fields["status"].string.map { try text($0) })
        try account(RemoteHistoryProtocol.payload(result).count); return result
    }
    func offset(_ cursor: UUID?, query: String) throws -> Int {
        guard let cursor else { return 0 }
        guard let position = positions[cursor], position.0 == query else { throw RemoteHistoryFailure(.staleCursor) }
        return position.1
    }
    func cursor(query: String, offset: Int) throws -> UUID {
        let key = query + "|" + String(offset)
        if let token = tokens[key] { return token }
        guard positions.count < 16_384 else { throw RemoteHistoryFailure(.limitExceeded) }
        try account(query.utf8.count + 128)
        let token = UUID(); positions[token] = (query, offset); tokens[key] = token; return token
    }
    func page<Item: Codable & Sendable & Equatable>(query: String, cursor: UUID?, rows: [Item], reverse: Bool = false,
        wrap: (RemoteHistoryPage<Item>) -> RemoteHistoryValue) throws -> RemoteHistoryReadResult {
        let offset = try offset(cursor, query: query)
        guard offset >= 0, offset <= rows.count else { throw RemoteHistoryFailure(.staleCursor) }
        let placeholder = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        func result(_ count: Int, next: UUID?) -> RemoteHistoryReadResult {
            .init(target: target, value: wrap(.init(binding: binding, offset: offset,
                items: (offset..<(offset + count)).map { rows[reverse ? rows.count - 1 - $0 : $0] }, totalCount: rows.count,
                nextCursor: next, complete: offset + count == rows.count)))
        }
        var low = rows.count == offset ? 0 : 1, high = min(256, rows.count - offset), best: Int?
        if rows.count == offset { best = 0 }
        while low <= high {
            let count = (low + high) / 2
            if try RemoteHistoryProtocol.payload(result(count, next: offset + count == rows.count ? nil : placeholder)).count <= RemoteHistoryProtocol.maximumResultBytes {
                best = count; low = count + 1
            } else { high = count - 1 }
            try Task.checkCancellation()
        }
        guard let count = best else { throw RemoteHistoryFailure(.limitExceeded) }
        let next = offset + count == rows.count ? nil : try self.cursor(query: query, offset: offset + count)
        return result(count, next: next)
    }
}
