import Foundation

struct RemoteContextPreparation: Codable, Sendable {
    enum Action: Codable, Sendable {
        case review(ContextTransferReview, title: String?, scratchAllocation: ScratchWorkspaceAllocation? = nil)
        case abandon(deliveryID: UUID, ids: [UUID])
    }
    let target: RemoteWorkspaceTarget
    let digest: String?
    let action: Action
    var requiresBoundRoot: Bool { if case .review = action { true } else { false } }
}
enum RemoteContextAdmission {
    static func commands(_ request: RemoteEnvironmentCommandRequest, preparation: RemoteEnvironmentPreparation,
                         snapshot: WorkspaceSnapshot) throws -> [EngineCommand] {
        guard case .contextTransfer(let target, let action) = request.command,
              case .contextTransfer(let prepared) = preparation, target.environmentID == request.environmentID,
              ContextTransferProtocol.same(target, prepared.target),
              let thread = snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              !thread.isArchived, ContextTransferProtocol.same(ProviderConfiguration(thread: thread), target.configuration) else { throw RemoteEnvironmentAdmission.stale() }
        switch (action, prepared.action) {
        case (.begin(let id, let digest, let title), .review(let review, let capturedTitle, let allocation)):
            guard id == review.id, digest == prepared.digest, ContextTransferProtocol.same(title, capturedTitle),
                  review.request.sourceThreadID == thread.id,
                  ContextTransferProtocol.same(review.sourceConfiguration, target.configuration) else { throw RemoteEnvironmentAdmission.stale() }
            return [.contextTransferAccepted(review: review, title: title, scratchAllocation: allocation)]
        case (.useFreshContext(let id, let ids), .abandon(let savedID, let savedIDs)):
            guard id == savedID, ids == savedIDs else { throw RemoteEnvironmentAdmission.stale() }
            return [.client(.abandonContextTransfer(threadID: thread.id, deliveryID: id, expectedTransferIDs: ids))]
        default: throw RemoteEnvironmentAdmission.stale()
        }
    }
}

private final class RemoteContextLease {
    let bytes: RemoteHistoryLease
    let nativeReview: ContextTransferReview?
    var inventory: [RemoteContextTransferSummary] = []
    var messages: [RemoteContextMessage] = []
    private let anchors: [WorkspaceFileRoot]
    init(target: RemoteWorkspaceTarget, binding: RemoteHistoryBinding, nativeReview: ContextTransferReview? = nil) throws {
        self.nativeReview = nativeReview
        bytes = try .init(target: target, binding: binding, proofBytes: nativeReview.map { try ContextTransferProtocol.payload($0).count } ?? 0)
        var roots: [WorkspaceFileRoot] = [], paths = Set<Data>()
        if let nativeReview {
            for path in [target.workspacePath, nativeReview.targetConfiguration.workspacePath] where paths.insert(Data(path.utf8)).inserted {
                roots.append(try WorkspaceFileRoot(root: URL(fileURLWithPath: path)))
            }
        }
        anchors = roots
    }
    func validateAnchors() throws { for anchor in anchors { try anchor.validate() } }
    func message(_ value: ContextHandoffMessage) throws -> RemoteContextMessage {
        let result = try RemoteContextMessage(id: value.id, runID: value.runID, role: value.role, kind: value.kind, text: bytes.text(value.text))
        try bytes.account(RemoteContextProtocol.payload(result).count); return result
    }
    func page<Item: Codable & Sendable & Equatable>(_ rows: [Item], cursor: UUID?, query: String,
        wrap: (RemoteHistoryPage<Item>) -> RemoteContextValue) throws -> RemoteContextReadResult {
        let offset = try bytes.offset(cursor, query: query), binding = bytes.binding
        guard offset <= rows.count else { throw RemoteContextFailure(.staleCursor) }
        let placeholder = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        func result(_ count: Int, cursor: UUID?) -> RemoteContextReadResult {
            .init(target: bytes.target, value: wrap(.init(binding: binding, offset: offset, items: Array(rows[offset..<(offset + count)]),
                totalCount: rows.count, nextCursor: cursor, complete: offset + count == rows.count)))
        }
        var low = rows.count == offset ? 0 : 1, high = min(256, rows.count - offset), best: Int?
        while low <= high {
            let count = low + (high - low) / 2
            if try RemoteContextProtocol.payload(result(count, cursor: offset + count == rows.count ? nil : placeholder)).count <= RemoteContextProtocol.maximumResultBytes {
                best = count; low = count + 1
            } else { high = count - 1 }
        }
        guard let count = best else { throw RemoteContextFailure(.limitExceeded) }
        return result(count, cursor: offset + count == rows.count ? nil : try bytes.cursor(query: query, offset: offset + count))
    }
}

actor RemoteContextService {
    typealias DestinationResolver = @Sendable (RemoteContextDestination, RemoteWorkspaceTarget) async throws -> ProviderConfiguration
    private let environmentID: UUID
    private let hostID = UUID()
    private let engine: WorkspaceEngine
    private let workspace: RemoteWorkspaceService
    private let resolve: DestinationResolver
    private var leases: [UUID: RemoteContextLease] = [:]
    private var order: [UUID] = []
    private var cleanup: [UUID: Task<Void, Never>] = [:]
    private var closing = false
    private var operations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closeTask: Task<Void, Never>?
    init(environmentID: UUID, engine: WorkspaceEngine, workspace: RemoteWorkspaceService, resolve: @escaping DestinationResolver) {
        self.environmentID = environmentID; self.engine = engine; self.workspace = workspace; self.resolve = resolve
    }
    private func begin() throws { guard !closing else { throw RemoteContextFailure(.unavailable) }; operations += 1 }
    private func finish() {
        operations -= 1
        if operations == 0 { let waiting = waiters; waiters = []; waiting.forEach { $0.resume() } }
    }
    private func validate(_ target: RemoteWorkspaceTarget, requireRoot: Bool = false) async throws {
        guard target.environmentID == environmentID else { throw RemoteContextFailure(.invalidTarget) }
        guard !closing else { throw RemoteContextFailure(.unavailable) }
        try await workspace.validateHistoryTarget(target, allowLocked: true, requireRoot: requireRoot)
        guard !closing else { throw RemoteContextFailure(.unavailable) }
    }
    private func binding(_ target: RemoteWorkspaceTarget, id: UUID, digest: String) -> RemoteHistoryBinding {
        .init(environmentID: environmentID, hostID: hostID, leaseID: UUID(), threadID: target.threadID, objectID: id, digest: digest)
    }
    private func remove(_ id: UUID) {
        guard let value = leases.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        if let review = value.nativeReview {
            let token = UUID(), engine = engine
            cleanup[token] = Task {
                await engine.discardContextTransferReview(id: review.id, digest: review.digest)
                self.cleanup.removeValue(forKey: token)
            }
        }
    }
    private func publish(_ value: RemoteContextLease) throws {
        guard !closing, value.bytes.bytes <= RemoteProjectionProtocol.maximumCacheBytes else { throw RemoteContextFailure(.limitExceeded) }
        while leases.count >= 8 || leases.values.reduce(value.bytes.bytes, { $0 + $1.bytes.bytes }) > RemoteProjectionProtocol.maximumCacheBytes {
            guard let oldest = order.first else { throw RemoteContextFailure(.limitExceeded) }; remove(oldest)
        }
        leases[value.bytes.binding.leaseID] = value; order.append(value.bytes.binding.leaseID)
    }
    private func lease(_ binding: RemoteHistoryBinding, target: RemoteWorkspaceTarget) throws -> RemoteContextLease {
        guard binding.environmentID == environmentID, binding.hostID == hostID,
              let value = leases[binding.leaseID], value.bytes.binding == binding,
              ContextTransferProtocol.same(value.bytes.target, target) else { throw RemoteContextFailure(.staleReview) }
        order.removeAll { $0 == binding.leaseID }; order.append(binding.leaseID)
        value.bytes.maximumBytes = RemoteProjectionProtocol.maximumCacheBytes - leases.values.filter { $0 !== value }.reduce(0) { $0 + $1.bytes.bytes }
        return value
    }
    func review(_ request: RemoteContextReviewRequest) async throws -> RemoteContextReview {
        try begin(); defer { finish() }
        var native: ContextTransferReview?
        do {
            try await validate(request.target, requireRoot: true)
            if leases.count >= 8, let oldest = order.first { remove(oldest) }
            for task in Array(cleanup.values) { await task.value }
            let intent: ContextTransferIntent
            switch request.intent {
            case .fork(let destination): intent = .fork(destination: try await resolve(destination, request.target))
            case .providerHandoff(let destination): intent = .providerHandoff(destination: try await resolve(destination, request.target))
            case .mergeBack(let parent):
                try await validate(parent, requireRoot: true)
                let current = await engine.current().snapshot
                guard current.threads.first(where: { $0.id == request.target.threadID })?.contextTransferLineage?.parentThreadID == parent.threadID,
                      parent.projectID == request.target.projectID else { throw RemoteContextFailure(.invalidTarget) }
                intent = .mergeBack(targetConfiguration: parent.configuration)
            }
            let value = try await engine.reviewContextTransfer(request: .init(sourceThreadID: request.target.threadID,
                expectedConfiguration: request.target.configuration, sourcePoint: request.sourcePoint, intent: intent)); native = value
            try await validate(request.target, requireRoot: true)
            struct Bound: Encodable { let target: RemoteWorkspaceTarget; let id: UUID; let digest: String }
            let digest = try ContextTransferProtocol.digest(Bound(target: request.target, id: value.id, digest: value.digest))
            let lease = try RemoteContextLease(target: request.target, binding: binding(request.target, id: value.id, digest: digest), nativeReview: value)
            lease.messages = try value.messages.map { try lease.message($0) }
            let coverage = ContextHandoffCoverage(transferID: value.id, sourceThreadID: value.request.sourceThreadID,
                sourceRunID: value.sourcePoint.runID, sourceMessageID: value.messages.last?.id, strategy: value.strategy.rawValue)
            let preview = value.strategy == .nativeFork ? nil : try ContextHandoffService.select(messages: value.messages, coverage: coverage)
            let summary = try RemoteContextReviewSummary(kind: value.kind, strategy: value.strategy, sourcePoint: value.sourcePoint,
                basePoint: value.basePoint, targetThreadID: value.targetThreadID, projectID: value.projectID,
                title: lease.bytes.text(value.title), sourceConfiguration: lease.bytes.json(value.sourceConfiguration, kind: .configuration),
                targetConfiguration: lease.bytes.json(value.targetConfiguration, kind: .configuration), archiveItemCount: value.messages.count,
                archiveByteCount: ContextTransferProtocol.payload(value.messages).count,
                previewSelection: preview.map { try lease.bytes.json($0, kind: .text) },
                warnings: [lease.bytes.text("Review preview uses an empty next input. The actual bounded context selection and retrieval availability are captured with your next explicit input; no message is sent now.")])
            let result = RemoteContextReview(id: value.id, digest: digest, target: request.target, binding: lease.bytes.binding, value: summary)
            try lease.bytes.account(RemoteContextProtocol.payload(result).count)
            guard try RemoteContextProtocol.payload(result).count <= RemoteContextProtocol.maximumResultBytes else { throw RemoteContextFailure(.limitExceeded) }
            try publish(lease); return result
        } catch {
            if let native { await engine.discardContextTransferReview(id: native.id, digest: native.digest) }
            throw safe(error)
        }
    }
    private func summary(_ value: ContextTransfer, lease: RemoteContextLease) throws -> RemoteContextTransferSummary {
        try .init(id: value.id, commandID: value.commandID, sourceThreadID: value.sourceThreadID, targetThreadID: value.targetThreadID,
            sourcePoint: value.review.sourcePoint, basePoint: value.review.basePoint, kind: value.review.kind,
            strategy: value.review.strategy, status: value.status, targetRunID: value.targetRunID, updatedAt: value.updatedAt,
            error: value.error.map { try lease.bytes.text($0) }, deliveryID: value.delivery?.id, deliveryStatus: value.delivery?.status,
            selection: value.delivery.map { try lease.bytes.json($0.selection, kind: .text) }, archivedItemCount: value.review.messages.count)
    }
    func read(_ request: RemoteContextReadRequest) async throws -> RemoteContextReadResult {
        try begin(); defer { finish() }
        do {
            guard request.target.environmentID == environmentID else { throw RemoteContextFailure(.invalidTarget) }
            let result: RemoteContextReadResult
            switch request.query {
            case .inventory:
                try await validate(request.target)
                let current = await engine.current().snapshot
                guard let thread = current.threads.first(where: { $0.id == request.target.threadID }) else { throw RemoteContextFailure(.invalidTarget) }
                let transfers = (current.contextTransfers ?? []).filter { $0.sourceThreadID == thread.id || $0.targetThreadID == thread.id }
                struct Identity: Encodable { let id: UUID; let reviewDigest: String; let status: ContextTransferStatus; let runID: UUID?; let updatedAt: Date }
                let digest = try ContextTransferProtocol.digest(transfers.map {
                    Identity(id: $0.id, reviewDigest: $0.review.digest, status: $0.status, runID: $0.targetRunID, updatedAt: $0.updatedAt)
                })
                let view = try RemoteContextLease(target: request.target, binding: binding(request.target, id: thread.id, digest: digest))
                var inventory: [RemoteContextTransferSummary] = []
                for transfer in transfers.reversed() { inventory.append(try summary(transfer, lease: view)) }
                view.inventory = inventory
                try view.bytes.account(RemoteContextProtocol.payload(view.inventory).count)
                let uncertain = transfers.first { $0.targetThreadID == thread.id && $0.status == .uncertain && $0.abandonedAt == nil }?.delivery
                let pageResult = try view.page(view.inventory, cursor: nil, query: "transfers", wrap: RemoteContextValue.transfers)
                guard case .transfers(let page) = pageResult.value else { throw RemoteContextFailure(.operationFailed) }
                result = .init(target: request.target, value: .inventory(.init(binding: view.bytes.binding, lineage: thread.contextTransferLineage,
                    pendingCount: transfers.filter { $0.targetThreadID == thread.id && $0.status == .pending }.count,
                    uncertain: uncertain.map { .init(deliveryID: $0.id, transferIDs: $0.transferIDs, canUseFreshContext: !thread.isBusy && thread.runtimeRequests.isEmpty) }, transfers: page)))
                try publish(view)
            case .transfer(let id):
                try await validate(request.target)
                let current = await engine.current().snapshot
                guard let transfer = current.contextTransfers?.first(where: { $0.id == id && ($0.sourceThreadID == request.target.threadID || $0.targetThreadID == request.target.threadID) }) else { throw RemoteContextFailure(.invalidTarget) }
                let view = try RemoteContextLease(target: request.target, binding: binding(request.target, id: id, digest: ContextTransferProtocol.digest(transfer)))
                view.messages = try transfer.review.messages.map { try view.message($0) }
                result = .init(target: request.target, value: .transfer(binding: view.bytes.binding, summary: try summary(transfer, lease: view)))
                try publish(view)
            case .transfers(let binding, let cursor):
                let view = try lease(binding, target: request.target)
                result = try view.page(view.inventory, cursor: cursor, query: "transfers", wrap: RemoteContextValue.transfers)
            case .messages(let binding, let cursor):
                let view = try lease(binding, target: request.target)
                result = try view.page(view.messages, cursor: cursor, query: "messages", wrap: RemoteContextValue.messages)
            case .content(let binding, let reference, let offset, let cursor):
                let view = try lease(binding, target: request.target), key = "content|\(reference.id)"
                guard view.bytes.references[reference.id] == reference, let bytes = view.bytes.contents[reference.id],
                      offset == (try view.bytes.offset(cursor, query: key)), offset >= 0, offset <= bytes.count else { throw RemoteContextFailure(.staleCursor) }
                let data = Data(bytes.dropFirst(offset).prefix(RemoteProjectionProtocol.maximumContentChunkBytes)), end = offset + data.count
                let next = end == bytes.count ? nil : try view.bytes.cursor(query: key, offset: end)
                result = .init(target: request.target, value: .content(.init(binding: binding, reference: reference, offset: offset, data: data, nextCursor: next, complete: next == nil)))
            case .release(let binding):
                guard binding.hostID == hostID, binding.environmentID == environmentID else { throw RemoteContextFailure(.staleReview) }
                if leases[binding.leaseID] == nil { result = .init(target: request.target, value: .released(false)) }
                else { _ = try lease(binding, target: request.target); remove(binding.leaseID); result = .init(target: request.target, value: .released(true)) }
                for task in Array(cleanup.values) { await task.value }
            }
            guard !closing, try RemoteContextProtocol.payload(result).count <= RemoteContextProtocol.maximumResultBytes else { throw RemoteContextFailure(.limitExceeded) }
            return result
        } catch { throw safe(error) }
    }
    func prepare(_ command: RemoteEnvironmentCommand, commandID: UUID? = nil, originalPayload: Data? = nil) async throws -> RemoteEnvironmentPreparation {
        try begin(); defer { finish() }
        guard case .contextTransfer(let target, let action) = command else { throw RemoteContextFailure(.invalidRequest) }
        do {
            try await validate(target, requireRoot: action.requiresBoundRoot)
            switch action {
            case .begin(let id, let digest, let title):
                guard let saved = leases.values.first(where: { $0.nativeReview?.id == id && $0.bytes.binding.digest == digest && ContextTransferProtocol.same($0.bytes.target, target) }),
                      let native = saved.nativeReview else { throw RemoteContextFailure(.staleReview) }
                let current = try await engine.prepareContextTransferAcceptance(reviewID: id, digest: native.digest)
                try saved.validateAnchors()
                let allocation: ScratchWorkspaceAllocation?
                if let commandID {
                    allocation = try await engine.prepareScratchContextTransfer(current, commandID: commandID)
                    if allocation != nil {
                        guard let originalPayload else { throw RemoteContextFailure(.invalidRequest) }
                        try await engine.recordScratchContextTransfer(allocation, commandID: commandID, originalPayload: originalPayload)
                    }
                } else { allocation = nil }
                return .contextTransfer(.init(target: target, digest: digest, action: .review(current, title: title, scratchAllocation: allocation)))
            case .useFreshContext(let id, let ids):
                guard !ids.isEmpty, ids.count <= 32, Set(ids).count == ids.count else { throw RemoteContextFailure(.invalidRequest) }
                return .contextTransfer(.init(target: target, digest: nil, action: .abandon(deliveryID: id, ids: ids)))
            }
        } catch { throw safe(error) }
    }
    func validatePreparation(_ prepared: RemoteContextPreparation) async throws {
        try await validate(prepared.target, requireRoot: prepared.requiresBoundRoot)
        if case .review(let review, _, _) = prepared.action {
            guard let saved = leases.values.first(where: { $0.nativeReview?.id == review.id && $0.bytes.binding.digest == prepared.digest && ContextTransferProtocol.same($0.bytes.target, prepared.target) }) else { throw RemoteContextFailure(.staleReview) }
            try saved.validateAnchors()
        }
    }
    func discard(_ request: RemoteContextDiscardRequest) async throws -> RemoteContextDiscardResult {
        try begin(); defer { finish() }
        guard request.target.environmentID == environmentID else { throw RemoteContextFailure(.invalidTarget) }
        let owned = leases.values.filter { $0.nativeReview?.id == request.reviewID && $0.bytes.binding.digest == request.digest && ContextTransferProtocol.same($0.bytes.target, request.target) }
        for value in owned { remove(value.bytes.binding.leaseID) }
        for task in Array(cleanup.values) { await task.value }
        return .init(request: request, discarded: !owned.isEmpty)
    }
    func close() async {
        if let closeTask { await closeTask.value; return }
        closing = true
        let task = Task {
            await self.engine.closeContextTransfers()
            if self.operations > 0 { await withCheckedContinuation { self.waiters.append($0) } }
            for id in Array(self.leases.keys) { self.remove(id) }
            for task in Array(self.cleanup.values) { await task.value }
        }
        closeTask = task; await task.value
    }
    private func safe(_ error: Error) -> RemoteContextFailure {
        if closing { return .init(.unavailable) }
        if let error = error as? RemoteContextFailure { return error }
        if let error = error as? ContextTransferError {
            switch error { case .staleReview: return .init(.staleReview); case .limit: return .init(.limitExceeded)
            case .unavailable: return .init(.busy); case .invalidSource: return .init(.invalidTarget); case .uncertain: return .init(.operationFailed) }
        }
        if let error = error as? RemoteWorkspaceFailure {
            switch error.kind { case .busy: return .init(.busy); case .limitExceeded: return .init(.limitExceeded)
            case .unavailable, .interrupted: return .init(.unavailable); default: return .init(.invalidTarget) }
        }
        return .init(error is CancellationError ? .unavailable : .operationFailed)
    }
}
