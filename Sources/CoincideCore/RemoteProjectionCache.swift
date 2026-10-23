import Foundation

/// These views contain only display DTOs and explicitly referenced public
/// documents. No native history evidence or WorkspaceSnapshot is retained.
final class RemoteProjectionView {
    struct Position { let query: String; let offset: Int }
    let binding: RemoteProjectionBinding
    let projects: [RemoteProjectSummary]
    let threads: [RemoteThreadSummary]
    let detail: RemoteThreadDetail?
    let messages: [RemoteMessageSummary]
    let runs: [RemoteRunSummary]
    let operations: [RemoteOperationSummary]
    let contents: [UUID: Data]
    let references: [UUID: RemoteProjectionContentReference]
    var byteCount: Int
    var cursors: [UUID: Position] = [:]
    var cursorIDs: [String: UUID] = [:]
    init(binding: RemoteProjectionBinding, source: RemoteProjectionSource) {
        self.binding = binding; projects = source.projects; threads = source.threads; detail = source.detail
        messages = source.messages; runs = source.runs; operations = source.operations
        contents = source.contents; references = source.references; byteCount = source.byteCount
    }
    func offset(cursor: UUID?, query: String) throws -> Int {
        guard let cursor else { return 0 }
        guard let position = cursors[cursor], position.query == query else { throw RemoteProjectionFailure(.staleCursor) }
        return position.offset
    }
}

final class RemoteProjectionCache {
    private var views: [UUID: RemoteProjectionView] = [:]
    private var order: [UUID] = []
    private(set) var byteCount = 0
    func reserveBuild(_ bytes: Int) throws {
        guard bytes >= 0, bytes <= RemoteProjectionProtocol.maximumCacheBytes else { throw RemoteProjectionFailure(.limitExceeded) }
        while byteCount + bytes > RemoteProjectionProtocol.maximumCacheBytes {
            guard let oldest = order.first else { throw RemoteProjectionFailure(.limitExceeded) }
            remove(oldest)
        }
    }
    func insert(_ view: RemoteProjectionView) throws {
        try reserveBuild(view.byteCount)
        while views.count >= RemoteProjectionProtocol.maximumViews, let oldest = order.first { remove(oldest) }
        views[view.binding.viewID] = view; order.append(view.binding.viewID); byteCount += view.byteCount
    }
    func view(_ binding: RemoteProjectionBinding) throws -> RemoteProjectionView {
        guard let view = views[binding.viewID], view.binding == binding else { throw RemoteProjectionFailure(.staleView) }
        order.removeAll { $0 == binding.viewID }; order.append(binding.viewID)
        return view
    }
    func cursor(_ view: RemoteProjectionView, query: String, offset: Int) throws -> UUID {
        let key = query + "|" + String(offset)
        if let existing = view.cursorIDs[key] { return existing }
        guard view.cursors.count < 16_384 else { throw RemoteProjectionFailure(.limitExceeded) }
        let cost = query.utf8.count + 128
        guard byteCount + cost <= RemoteProjectionProtocol.maximumCacheBytes else { throw RemoteProjectionFailure(.limitExceeded) }
        let id = UUID(); view.cursors[id] = .init(query: query, offset: offset); view.cursorIDs[key] = id
        view.byteCount += cost; byteCount += cost; return id
    }
    @discardableResult func release(_ binding: RemoteProjectionBinding) throws -> Bool {
        guard let view = views[binding.viewID] else { return false }
        guard view.binding == binding else { throw RemoteProjectionFailure(.staleView) }
        remove(binding.viewID); return true
    }
    private func remove(_ id: UUID) {
        if let view = views.removeValue(forKey: id) { byteCount -= view.byteCount }
        order.removeAll { $0 == id }
    }
    func close() { views = [:]; order = []; byteCount = 0 }
}
