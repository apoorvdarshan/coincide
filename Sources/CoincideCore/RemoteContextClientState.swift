import Foundation
import CryptoKit

struct RemoteContextClientState {
    struct Claim {
        let query: Data, request: Data
        let binding: RemoteHistoryBinding
        let cursor: UUID?
        let offset: Int, total: Int?
    }
    private struct Cursor: Equatable {
        let query: Data, binding: RemoteHistoryBinding
        let offset: Int, total: Int
    }
    private var hostID: UUID?
    private var bindings: [UUID: (RemoteHistoryBinding, Data)] = [:]
    private var cursors: [UUID: Cursor] = [:]
    private var replies: [Data: (UUID, String)] = [:]
    mutating func remember(_ binding: RemoteHistoryBinding, target: RemoteWorkspaceTarget) throws {
        let bytes = try RemoteContextProtocol.payload(target)
        guard binding.environmentID == target.environmentID, binding.threadID == target.threadID,
              CheckpointValidation.digest(binding.digest), hostID == nil || hostID == binding.hostID,
              bindings[binding.leaseID].map({ $0.0 == binding && $0.1 == bytes }) ?? true else { throw RemoteEnvironmentClientError(.invalidResponse) }
        guard bindings[binding.leaseID] != nil || bindings.count < 4_096 else { throw RemoteEnvironmentClientError(.limitExceeded) }
        bindings[binding.leaseID] = (binding, bytes); hostID = binding.hostID
    }
    func require(_ binding: RemoteHistoryBinding, target: RemoteWorkspaceTarget) throws {
        guard binding.hostID == hostID, let saved = bindings[binding.leaseID], saved.0 == binding,
              saved.1 == (try RemoteContextProtocol.payload(target)) else { throw RemoteContextFailure(.staleReview) }
    }
    func claim(_ request: RemoteContextReadRequest, binding: RemoteHistoryBinding, normalized: RemoteContextQuery, cursor: UUID?) throws -> Claim {
        try require(binding, target: request.target)
        let query = Data(SHA256.hash(data: try RemoteContextProtocol.payload(RemoteContextReadRequest(target: request.target, query: normalized))))
        let key = Data(SHA256.hash(data: try RemoteContextProtocol.payload(request)))
        guard replies[key] != nil || replies.count < 4_096 else { throw RemoteEnvironmentClientError(.limitExceeded) }
        if let cursor {
            guard let saved = cursors[cursor], saved.query == query, saved.binding == binding else { throw RemoteContextFailure(.invalidRequest) }
            return .init(query: query, request: key, binding: binding, cursor: cursor, offset: saved.offset, total: saved.total)
        }
        return .init(query: query, request: key, binding: binding, cursor: nil, offset: 0, total: nil)
    }
    mutating func finish<Value: Encodable>(_ value: Value, binding: RemoteHistoryBinding, offset: Int, count: Int,
                                          total: Int, complete: Bool, next: UUID?, claim: Claim) throws {
        guard binding == claim.binding, offset == claim.offset, offset >= 0, total >= 0, offset <= total,
              count >= 0, count <= total - offset, claim.total == nil || claim.total == total,
              complete == (offset + count == total), complete == (next == nil), complete || count > 0,
              next == nil || next != claim.cursor else { throw RemoteEnvironmentClientError(.invalidResponse) }
        let digest = try ContextTransferProtocol.digest(value)
        if let old = replies[claim.request] { guard old.0 == binding.leaseID, old.1 == digest else { throw RemoteEnvironmentClientError(.invalidResponse) } }
        if let next {
            let saved = Cursor(query: claim.query, binding: binding, offset: offset + count, total: total)
            guard cursors[next] == nil || cursors[next] == saved else { throw RemoteEnvironmentClientError(.invalidResponse) }
            guard cursors[next] != nil || cursors.count < 4_096 else { throw RemoteEnvironmentClientError(.limitExceeded) }
            cursors[next] = saved
        }
        replies[claim.request] = (binding.leaseID, digest)
    }
    mutating func release(_ binding: RemoteHistoryBinding) {
        bindings.removeValue(forKey: binding.leaseID)
        cursors = cursors.filter { $0.value.binding.leaseID != binding.leaseID }
        replies = replies.filter { $0.value.0 != binding.leaseID }
    }
    mutating func discard(id: UUID, digest: String) {
        for saved in Array(bindings.values) where saved.0.objectID == id && saved.0.digest == digest { release(saved.0) }
    }
}
