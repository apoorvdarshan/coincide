import Foundation

/// Connection-local evidence about proof-free host leases; never native authority.
struct RemoteSteeringClientState {
    struct Cursor { let binding: RemoteSteeringBinding; let kind: RemoteSteeringPageKind; let offset: Int, total: Int }
    var targets: [UUID: RemoteWorkspaceTarget] = [:]
    var captures: [UUID: RemoteSteeringCapture] = [:]
    var references: [UUID: [UUID: RemoteSteeringContentReference]] = [:]
    var cursors: [UUID: Cursor] = [:]
    var replies: [String: String] = [:]
    mutating func release(_ id: UUID) {
        targets.removeValue(forKey: id); captures.removeValue(forKey: id); references.removeValue(forKey: id)
        cursors = cursors.filter { $0.value.binding.viewID != id }
        replies = replies.filter { !$0.key.hasPrefix(id.uuidString + ":") }
    }
    func check(_ binding: RemoteSteeringBinding, target: RemoteWorkspaceTarget) throws {
        guard captures[binding.viewID]?.binding == binding, let original = targets[binding.viewID], RemoteLifecycleProtocol.same(original, target) else { throw RemoteEnvironmentClientError(.invalidResponse) }
    }
    mutating func accept(_ page: RemoteSteeringPage, target: RemoteWorkspaceTarget, offset: Int, total: Int? = nil) throws {
        let binding = page.capture.binding, count = page.kind == .queue ? page.items.count : page.operations.count
        guard captures[binding.viewID] == page.capture, page.offset == offset, page.totalCount >= 0,
              total == nil || page.totalCount == total, page.offset >= 0, page.offset <= page.totalCount, count <= page.totalCount - page.offset,
              page.complete == (page.offset + count == page.totalCount), page.complete == (page.nextCursor == nil),
              page.complete || count > 0, page.kind == .queue ? page.operations.isEmpty : page.items.isEmpty else { throw RemoteEnvironmentClientError(.invalidResponse) }
        try check(binding, target: target)
        var seen: Set<UUID> = []
        for row in page.items {
            guard seen.insert(row.id).inserted, RemoteLifecycleProtocol.validDigest(row.digest), row.preview.utf8.count <= 512,
                  row.attachmentCount >= 0, row.attachmentCount <= 100, row.model.utf8.count <= 128,
                  row.reason.map({ $0.utf8.count <= 2_048 }) ?? true else { throw RemoteEnvironmentClientError(.invalidResponse) }
            try register(row.text, binding: binding, kind: .text); try register(row.attachments, binding: binding, kind: .attachments)
        }
        seen = []
        for row in page.operations {
            guard seen.insert(row.id).inserted, RemoteLifecycleProtocol.validDigest(row.digest), row.preview.utf8.count <= 512,
                  row.error.map({ $0.utf8.count <= 2_048 }) ?? true else { throw RemoteEnvironmentClientError(.invalidResponse) }
            try register(row.text, binding: binding, kind: .text); try register(row.attachments, binding: binding, kind: .attachments)
        }
        if let cursor = page.nextCursor {
            let claim = Cursor(binding: binding, kind: page.kind, offset: offset + count, total: page.totalCount)
            if let old = cursors[cursor] { guard old.binding == claim.binding, old.kind == claim.kind, old.offset == claim.offset, old.total == claim.total else { throw RemoteEnvironmentClientError(.invalidResponse) } }
            cursors[cursor] = claim
        }
    }
    private mutating func register(_ reference: RemoteSteeringContentReference, binding: RemoteSteeringBinding, kind: RemoteSteeringContentReference.Kind) throws {
        guard reference.kind == kind, reference.totalBytes >= 0, reference.totalBytes <= RemoteProjectionProtocol.maximumCacheBytes,
              RemoteLifecycleProtocol.validDigest(reference.digest) else { throw RemoteEnvironmentClientError(.invalidResponse) }
        if let old = references[binding.viewID]?[reference.id], old != reference { throw RemoteEnvironmentClientError(.invalidResponse) }
        references[binding.viewID, default: [:]][reference.id] = reference
    }
    mutating func immutable<T: Encodable>(_ value: T, key: String) throws {
        let digest = try RemoteSteeringProtocol.digest(value)
        if let previous = replies[key], previous != digest { throw RemoteEnvironmentClientError(.invalidResponse) }
        guard replies.count < 32_768 || replies[key] != nil else { throw RemoteEnvironmentClientError(.limitExceeded) }
        replies[key] = digest
    }
}
