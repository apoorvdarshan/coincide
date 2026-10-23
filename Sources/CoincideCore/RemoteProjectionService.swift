import Foundation

actor RemoteProjectionService {
    nonisolated let environmentID: UUID
    nonisolated let hostID = UUID()
    private let engine: WorkspaceEngine
    private let cache = RemoteProjectionCache()
    private var closed = false
    init(environmentID: UUID, engine: WorkspaceEngine) { self.environmentID = environmentID; self.engine = engine }
    private func require(_ id: UUID) throws {
        guard id == environmentID else { throw RemoteProjectionFailure(.wrongEnvironment) }
        guard !closed else { throw RemoteProjectionFailure(.unavailable) }
    }
    private func view(_ binding: RemoteProjectionBinding) throws -> RemoteProjectionView {
        try require(binding.environmentID)
        guard binding.hostID == hostID else { throw RemoteProjectionFailure(.staleView) }
        return try cache.view(binding)
    }

    /// Resolve only a host-owned immutable projection document. The client
    /// supplies references, never a native message or an execution request.
    /// The native reducer will revalidate this current source at the original
    /// remote command's durable admission boundary.
    func prepareTranscriptPlanImplementation(target: RemoteWorkspaceTarget, binding: RemoteProjectionBinding,
                                             messageID: String, presentation: RemoteProjectionContentReference) async throws -> TranscriptPlanImplementation {
        try require(target.environmentID)
        let owned = try view(binding)
        guard case .thread(let threadID) = binding.scope, threadID == target.threadID,
              let summary = owned.messages.first(where: { $0.id.utf8.elementsEqual(messageID.utf8) }),
              summary.removedByHistoryOperationID == nil, summary.presentation == presentation,
              presentation.kind == .transcriptPresentation else { throw RemoteProjectionFailure(.invalidRequest) }
        let bytes = try transcriptDocument(presentation, view: owned)
        let displayed = try JSONDecoder().decode(RemoteTranscriptMessagePresentation.self, from: bytes)
        guard displayed.messageID.utf8.elementsEqual(messageID.utf8), displayed.threadID == target.threadID,
              displayed.projectID == target.projectID, displayed.role == summary.role,
              displayed.createdAt == summary.createdAt, displayed.runReference == summary.runReference else {
            throw RemoteProjectionFailure(.invalidRequest)
        }
        let sourceText: String
        if displayed.sourceText.complete {
            guard displayed.sourceText.content == nil else { throw RemoteProjectionFailure(.invalidRequest) }
            sourceText = displayed.sourceText.preview
        } else {
            guard let reference = displayed.sourceText.content, reference.kind == .text,
                  let value = String(data: try transcriptDocument(reference, view: owned), encoding: .utf8) else {
                throw RemoteProjectionFailure(.invalidRequest)
            }
            sourceText = value
        }
        let update = try await engine.captureRemoteProjection()
        try require(target.environmentID); try Task.checkCancellation()
        guard try view(binding) === owned,
              let thread = update.snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              thread.createdAt == displayed.threadCreatedAt,
              thread.workspacePath.utf8.elementsEqual(displayed.workspacePath.utf8),
              try RemoteProjectionProtocol.payload(ProviderConfiguration(thread: thread)) == RemoteProjectionProtocol.payload(target.configuration),
              let message = thread.messages.first(where: { $0.id.utf8.elementsEqual(messageID.utf8) }),
              message.removedByHistoryOperationID == nil, message.role == displayed.role, message.createdAt == displayed.createdAt,
              message.runReference == displayed.runReference, message.promptSteeringID == displayed.promptSteeringID,
              message.text.utf8.elementsEqual(sourceText.utf8),
              try RemoteProjectionProtocol.payload(message.providerEntity) == RemoteProjectionProtocol.payload(displayed.providerEntity) else {
            throw RemoteProjectionFailure(.staleView)
        }
        // Legacy rows without captured launch profiles need a separate native
        // capture review; this display document cannot invent that authority.
        if thread.provider == .claude, thread.claudeRuntimeConfiguration == nil { throw RemoteProjectionFailure(.unavailable) }
        if thread.provider == .pi, thread.piConfiguration?.runtime == nil { throw RemoteProjectionFailure(.unavailable) }
        return .init(thread: thread, message: message)
    }

    private func transcriptDocument(_ reference: RemoteProjectionContentReference, view: RemoteProjectionView) throws -> Data {
        guard view.references[reference.id] == reference, let bytes = view.contents[reference.id],
              bytes.count == reference.totalBytes, RemoteProjectionProtocol.digest(bytes) == reference.digest else {
            throw RemoteProjectionFailure(.invalidRequest)
        }
        return bytes
    }
    func open(_ request: RemoteProjectionOpenRequest) async throws -> RemoteProjectionOpenResult {
        try require(request.environmentID)
        guard request.minimumSequence.map({ $0 >= 0 }) ?? true else { throw RemoteProjectionFailure(.invalidRequest) }
        let update = try await engine.captureRemoteProjection()
        try require(request.environmentID); try Task.checkCancellation()
        guard request.minimumSequence.map({ update.sequence >= $0 }) ?? true else { throw RemoteProjectionFailure(.staleView) }
        let ownedCache = cache
        let source = try RemoteProjectionProjector.build(update, scope: request.scope) { bytes in
            try Task.checkCancellation(); try ownedCache.reserveBuild(bytes)
        }
        try require(request.environmentID); try Task.checkCancellation()
        let binding = RemoteProjectionBinding(environmentID: environmentID, hostID: hostID, viewID: UUID(),
            sequence: update.sequence, fingerprint: source.fingerprint, scope: request.scope)
        let materialized = RemoteProjectionView(binding: binding, source: source)
        try cache.insert(materialized)
        return binding
    }
    private func page<Item: Codable & Sendable & Equatable, Result: Encodable>(view: RemoteProjectionView, cursor: UUID?,
        query: String, total: Int, item: (Int) -> Item, wrap: (RemoteProjectionPage<Item>) -> Result) throws -> Result {
        let offset = try view.offset(cursor: cursor, query: query)
        guard offset >= 0, offset <= total else { throw RemoteProjectionFailure(.staleCursor) }
        let placeholder = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        func result(_ count: Int, next: UUID?) -> Result {
            wrap(.init(binding: view.binding, offset: offset, items: (offset..<(offset + count)).map(item), totalCount: total,
                nextCursor: next, complete: offset + count == total))
        }
        var low = total == offset ? 0 : 1, high = min(256, total - offset), best: Int?
        if total == offset { best = 0 }
        while low <= high {
            try Task.checkCancellation()
            let count = (low + high) / 2
            let candidate = result(count, next: offset + count == total ? nil : placeholder)
            if try RemoteProjectionProtocol.payload(candidate).count <= RemoteProjectionProtocol.maximumResultBytes { best = count; low = count + 1 }
            else { high = count - 1 }
        }
        guard let count = best else { throw RemoteProjectionFailure(.limitExceeded) }
        let next = offset + count == total ? nil : try cache.cursor(view, query: query, offset: offset + count)
        let value = result(count, next: next)
        guard try RemoteProjectionProtocol.payload(value).count <= RemoteProjectionProtocol.maximumResultBytes else { throw RemoteProjectionFailure(.limitExceeded) }
        return value
    }
    func catalog(_ request: RemoteProjectionCatalogRequest) throws -> RemoteProjectionCatalogResult {
        let value = try view(request.binding)
        guard case .catalog = value.binding.scope else { throw RemoteProjectionFailure(.invalidRequest) }
        switch request.query {
        case .projects:
            return try page(view: value, cursor: request.cursor, query: "projects", total: value.projects.count, item: { value.projects[$0] }, wrap: RemoteProjectionCatalogResult.projects)
        case .threads(let project, let archived):
            let rows = value.threads.filter { (project == nil || $0.projectID == project) && (archived || !$0.isArchived) }
            return try page(view: value, cursor: request.cursor, query: "threads|\(project?.uuidString ?? "all")|\(archived)",
                total: rows.count, item: { rows[$0] }, wrap: RemoteProjectionCatalogResult.threads)
        }
    }
    private func threadID(_ view: RemoteProjectionView, requested: UUID, transcript: Bool = false) throws {
        switch view.binding.scope {
        case .thread(let id): guard requested == id else { throw RemoteProjectionFailure(.invalidRequest) }
        case .control(let id): guard requested == id, !transcript else { throw RemoteProjectionFailure(.invalidRequest) }
        case .catalog: throw RemoteProjectionFailure(.invalidRequest)
        }
    }
    func thread(_ request: RemoteProjectionThreadRequest) throws -> RemoteProjectionThreadResult {
        let value = try view(request.binding); try threadID(value, requested: request.threadID)
        guard let detail = value.detail else { throw RemoteProjectionFailure(.notFound) }
        let result = RemoteProjectionThreadResult(binding: value.binding, thread: detail)
        guard try RemoteProjectionProtocol.payload(result).count <= RemoteProjectionProtocol.maximumResultBytes else { throw RemoteProjectionFailure(.limitExceeded) }
        return result
    }
    func messages(_ request: RemoteProjectionMessagesRequest) throws -> RemoteProjectionMessagesResult {
        let value = try view(request.binding); try threadID(value, requested: request.threadID, transcript: true)
        return try page(view: value, cursor: request.cursor, query: "messages|\(request.threadID)|\(request.newestFirst)", total: value.messages.count,
            item: { value.messages[request.newestFirst ? value.messages.count - 1 - $0 : $0] }, wrap: { $0 })
    }
    func runs(_ request: RemoteProjectionRunsRequest) throws -> RemoteProjectionRunsResult {
        let value = try view(request.binding); try threadID(value, requested: request.threadID, transcript: true)
        return try page(view: value, cursor: request.cursor, query: "runs|\(request.threadID)", total: value.runs.count, item: { value.runs[$0] }, wrap: { $0 })
    }
    func operations(_ request: RemoteProjectionOperationsRequest) throws -> RemoteProjectionOperationsResult {
        let value = try view(request.binding)
        let rows: [RemoteOperationSummary]
        switch value.binding.scope {
        case .catalog:
            throw RemoteProjectionFailure(.invalidRequest)
        case .thread(let id), .control(let id):
            guard request.threadID == nil || request.threadID == id else { throw RemoteProjectionFailure(.invalidRequest) }
            rows = value.operations
        }
        return try page(view: value, cursor: request.cursor, query: "operations|\(request.threadID?.uuidString ?? "all")", total: rows.count, item: { rows[$0] }, wrap: { $0 })
    }
    func content(_ request: RemoteProjectionContentRequest) throws -> RemoteProjectionContentResult {
        let value = try view(request.binding), reference = request.reference
        guard value.references[reference.id] == reference, let bytes = value.contents[reference.id], bytes.count == reference.totalBytes else { throw RemoteProjectionFailure(.notFound) }
        let key = "content|\(reference.id)", expected = try value.offset(cursor: request.cursor, query: key)
        guard request.offset == expected, expected >= 0, expected <= bytes.count else { throw RemoteProjectionFailure(.staleCursor) }
        let data = Data(bytes.dropFirst(expected).prefix(RemoteProjectionProtocol.maximumContentChunkBytes)), nextOffset = expected + data.count
        let next = nextOffset == bytes.count ? nil : try cache.cursor(value, query: key, offset: nextOffset)
        let result = RemoteProjectionContentResult(binding: value.binding, reference: reference, offset: expected, data: data, nextCursor: next, complete: next == nil)
        guard try RemoteProjectionProtocol.payload(result).count <= RemoteProjectionProtocol.maximumResultBytes else { throw RemoteProjectionFailure(.limitExceeded) }
        return result
    }
    func release(_ request: RemoteProjectionReleaseRequest) throws -> RemoteProjectionReleaseResult {
        try require(request.binding.environmentID)
        guard request.binding.hostID == hostID else { throw RemoteProjectionFailure(.staleView) }
        return .init(binding: request.binding, released: try cache.release(request.binding))
    }
    func close() { closed = true; cache.close() }
}
