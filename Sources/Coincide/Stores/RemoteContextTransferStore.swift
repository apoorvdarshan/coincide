import CoincideCore
import Foundation
import Observation

struct RemoteContextTransferTransport: Sendable {
    var bind: @Sendable (RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget
    var parent: @Sendable (UUID) async throws -> RemoteWorkspaceTarget
    var review: @Sendable (RemoteContextReviewRequest) async throws -> RemoteContextReview
    var read: @Sendable (RemoteContextReadRequest) async throws -> RemoteContextReadResult
    var discard: @Sendable (RemoteContextDiscardRequest) async throws -> RemoteContextDiscardResult
    var document: @Sendable (RemoteProjectionContentReference, RemoteHistoryBinding, RemoteWorkspaceTarget) async throws -> Data
    static func live(_ client: RemoteEnvironmentClient) -> Self {
        .init(bind: { try await client.bindContextWorkspace($0) }, parent: { id in
            let binding = try await client.openProjection(scope: .control(id))
            do {
                let value = try await client.projectionThread(.init(binding: binding, threadID: id))
                let configuration = try JSONDecoder().decode(ProviderConfiguration.self,
                    from: await client.projectionDocument(value.thread.configuration, binding: binding))
                let target = RemoteWorkspaceTarget(environmentID: binding.environmentID, projectID: value.thread.summary.projectID,
                    threadID: id, configuration: configuration)
                let bound = try await client.bindContextWorkspace(target)
                _ = try? await client.projectionRelease(.init(binding: binding)); return bound
            } catch { _ = try? await client.projectionRelease(.init(binding: binding)); throw error }
        }, review: { try await client.reviewContext($0) }, read: { try await client.readContext($0) },
            discard: { try await client.discardContextReview($0) },
            document: { try await client.contextDocument($0, binding: $1, target: $2) })
    }
}
private struct RemoteContextTransferKey: Hashable { let environmentID: UUID, threadID: UUID; let path: Data }

/// One explicit source inventory at a time, bound to the immutable browse view.
@MainActor @Observable
final class RemoteContextSourceCheckpoints {
    private(set) var isLoading = false
    private var values: [RemoteCheckpointAttemptSummary] = []
    private var binding: RemoteProjectionBinding?
    private var run: RemoteRunSummary?
    @ObservationIgnored private var token = UUID()
    func attempts(for run: RemoteRunSummary, binding: RemoteProjectionBinding?) -> [RemoteCheckpointAttemptSummary] {
        if run.checkpointAttemptsComplete { return run.checkpointAttempts }
        return self.binding == binding && self.run.map({ ContextTransferProtocol.same($0, run) }) == true ? values : []
    }
    func contains(_ run: RemoteRunSummary, binding: RemoteProjectionBinding?) -> Bool {
        run.checkpointAttemptsComplete || (self.binding == binding && self.run.map { ContextTransferProtocol.same($0, run) } == true)
    }
    func clear() { token = UUID(); isLoading = false; binding = nil; run = nil; values = [] }
    @discardableResult func load(run: RemoteRunSummary, binding: RemoteProjectionBinding,
        document: @MainActor (RemoteProjectionContentReference, RemoteProjectionBinding) async throws -> Data,
        current: @MainActor () -> (RemoteRunSummary?, RemoteProjectionBinding?)) async throws -> Bool {
        guard !isLoading, !run.checkpointAttemptsComplete, let reference = run.checkpointAttemptsContent,
              reference.kind == .checkpointAttempts, reference.totalBytes <= 32 * 1_024 * 1_024 else { return false }
        let owned = UUID(); token = owned; isLoading = true
        defer { if token == owned { isLoading = false } }
        let data = try await document(reference, binding)
        let loaded = try JSONDecoder().decode([RemoteCheckpointAttemptSummary].self, from: data)
        let latest = current()
        guard token == owned, !Task.isCancelled, latest.1 == binding,
              latest.0.map({ ContextTransferProtocol.same($0, run) }) == true else { return false }
        guard loaded.count == run.checkpointAttemptCount, Set(loaded.map(\.id)).count == loaded.count,
              loaded.allSatisfy({ $0.digest.count == 64 }) else { throw RemoteContextFailure(.invalidRequest) }
        self.binding = binding; self.run = run; values = loaded; return true
    }
}

@MainActor @Observable
final class RemoteContextTransferStore {
    typealias Perform = @MainActor (RemoteEnvironmentCommand) async -> Bool
    private(set) var current: RemoteContextTransferWorkspace?
    @ObservationIgnored private var models: [RemoteContextTransferKey: RemoteContextTransferWorkspace] = [:]
    @ObservationIgnored private var clientIdentity: ObjectIdentifier?
    @ObservationIgnored private var closed = false
    func review(id: UUID) -> RemoteContextReview? { models.values.compactMap { $0.review?.id == id ? $0.review : nil }.first }
    func select(target: RemoteWorkspaceTarget?, projection: RemoteProjectionStore, client: RemoteEnvironmentClient?, supported: Bool,
                providers: [ProviderKind], canWrite: Bool, perform: @escaping Perform, openConversation: @escaping @MainActor (UUID) -> Void) async {
        let identity = client.map(ObjectIdentifier.init)
        if identity != clientIdentity { disconnect(); clientIdentity = identity }
        await select(target: target, projection: projection, transport: client.map(RemoteContextTransferTransport.live), supported: supported,
            providers: providers, canWrite: canWrite, perform: perform, openConversation: openConversation)
    }
    func select(target: RemoteWorkspaceTarget?, projection: RemoteProjectionStore, transport: RemoteContextTransferTransport?, supported: Bool,
                providers: [ProviderKind], canWrite: Bool, perform: @escaping Perform, openConversation: @escaping @MainActor (UUID) -> Void) async {
        guard !closed, let target else { clearSelection(); return }
        let key = RemoteContextTransferKey(environmentID: target.environmentID, threadID: target.threadID, path: Data(target.workspacePath.utf8))
        let model = models[key] ?? RemoteContextTransferWorkspace(target: target); models[key] = model
        if current !== model { current?.disconnect() }; current = model
        model.update(target: target, projection: projection, transport: transport, supported: supported,
            providers: providers, canWrite: canWrite, perform: perform, openConversation: openConversation)
        await model.synchronize()
    }
    func clearSelection() { current?.disconnect(); current = nil }
    func disconnect() { clientIdentity = nil; for model in models.values { model.disconnect() } }
    func shutdown() async { closed = true; disconnect(); for model in models.values { await model.drain() } }
    func cancelShutdown() { closed = false }
}

@MainActor @Observable
final class RemoteContextTransferWorkspace {
    let sourceCheckpoints = RemoteContextSourceCheckpoints()
    private(set) var target: RemoteWorkspaceTarget
    private(set) var projection: RemoteProjectionStore?
    private(set) var review: RemoteContextReview?
    private(set) var sourceConfiguration: ProviderConfiguration?
    private(set) var destinationConfiguration: ProviderConfiguration?
    private(set) var previewSelection: ContextHandoffSelection?
    private(set) var inventory: RemoteContextInventory?
    private(set) var transfers: [RemoteContextTransferSummary] = []
    private(set) var deliverySelections: [UUID: ContextHandoffSelection] = [:]
    private(set) var supported = false
    private(set) var connected = false
    private(set) var writesAllowed = false
    private(set) var isReviewing = false
    private(set) var isAccepting = false
    private(set) var isLoading = false
    private(set) var providers: [ProviderKind] = []
    private(set) var errorMessage: String?
    var title = ""
    var kind = ContextTransferFormKind.fork { didSet { if kind != oldValue { invalidate() } } }
    var sourceID = "latest" { didSet { if sourceID != oldValue { invalidate() } } }
    var workspaceID = "" { didSet { if workspaceID != oldValue { invalidate() } } }
    var provider: ProviderKind { didSet { if provider != oldValue { model = ""; invalidate() } } }
    var model = "" { didSet { if !model.utf8.elementsEqual(oldValue.utf8) { invalidate() } } }
    var permission = PermissionMode.supervised { didSet { if permission != oldValue { invalidate() } } }
    @ObservationIgnored private var transport: RemoteContextTransferTransport?
    @ObservationIgnored private var perform: RemoteContextTransferStore.Perform?
    @ObservationIgnored private var open: (@MainActor (UUID) -> Void)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var reviewRead = UUID()
    @ObservationIgnored private var inventoryRead = UUID()
    @ObservationIgnored private var inventorySequence: Int64?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncDrains: [Task<Void, Never>] = []
    @ObservationIgnored private var leaseTargets: [UUID: RemoteWorkspaceTarget] = [:]
    @ObservationIgnored private var transferCursor: UUID?
    @ObservationIgnored private var transferOffset = 0
    @ObservationIgnored private var attempted: Set<UUID> = []
    @ObservationIgnored private var activeReviewCalls = 0
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var cleanup: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var reads: [UUID: Task<RemoteContextReadResult, any Error>] = [:]
    @ObservationIgnored private var sourceReads: [UUID: Task<Data, any Error>] = [:]
    init(target: RemoteWorkspaceTarget) {
        self.target = target; provider = target.configuration.provider; model = target.configuration.model; permission = target.configuration.permission
        workspaceID = Data(target.workspacePath.utf8).base64EncodedString()
    }
    var canRead: Bool { connected && supported && transport != nil }
    var sourceOptions: [ContextTransferSourceOption] {
        var values: [ContextTransferSourceOption] = [.init(id: "latest", title: "Latest stable completed observation")]
        for run in projection?.runs ?? [] where run.status.isTerminal && run.status != .unknown && run.removedByHistoryOperationID == nil {
            values.append(.init(id: "run-" + run.id.uuidString, title: "Run · \(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(run.status.rawValue)"))
            if let after = sourceCheckpoints.attempts(for: run, binding: projection?.browseBinding).last(where: { $0.stage == .postRun }), after.phase == .ready, after.hasReceipt {
                values.append(.init(id: "checkpoint-" + after.id.uuidString, title: "After-run checkpoint · \(after.updatedAt.formatted(date: .abbreviated, time: .shortened))"))
            }
        }
        return values
    }
    var unloadedSourceRuns: [RemoteRunSummary] {
        (projection?.runs ?? []).filter { $0.status.isTerminal && $0.status != .unknown && $0.removedByHistoryOperationID == nil &&
            $0.checkpointAttemptsContent != nil && !sourceCheckpoints.contains($0, binding: projection?.browseBinding) }
    }
    func loadSourceCheckpoints(runID: UUID) async {
        guard canRead, let projection, let binding = projection.browseBinding,
              let run = projection.runs.first(where: { $0.id == runID }) else { return }
        let owner = generation, id = UUID()
        do {
            _ = try await sourceCheckpoints.load(run: run, binding: binding, document: { [self] reference, binding in
                let task = Task { try await projection.document(reference, binding: binding) }; sourceReads[id] = task
                defer { sourceReads.removeValue(forKey: id) }
                return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            }, current: { [weak self] in
                guard let self, self.generation == owner, self.canRead else { return (nil, nil) }
                return (self.projection?.runs.first { $0.id == runID }, self.projection?.browseBinding)
            })
        } catch is CancellationError { }
        catch { if owner == generation { errorMessage = Self.message(error) } }
    }
    var workspaceOptions: [ContextTransferWorkspaceOption] {
        var values: [ContextTransferWorkspaceOption] = [], seen = Set<Data>()
        let roots = (projection?.projects ?? []).filter { $0.id == target.projectID }.map { ($0.name.preview, $0.workspacePath) }
        // Catalog summaries do not certify workspace readiness. The host reviews
        // any chosen registered sibling before allowing a transfer.
        let siblings = (projection?.threads ?? []).filter { $0.projectID == target.projectID }.map { ($0.title.preview, $0.workspacePath) }
        for (title, path) in [("Current conversation", target.workspacePath)] + roots + siblings {
            let data = Data(path.utf8)
            if seen.insert(data).inserted { values.append(.init(id: data.base64EncodedString(), title: title, path: path)) }
        }
        return values
    }
    var canPrepare: Bool { canRead && writesAllowed && !isReviewing && !isAccepting && sourceOptions.contains { $0.id == sourceID } && (kind != .mergeBack || inventory?.lineage != nil) }
    var canConfirm: Bool {
        guard canRead, writesAllowed, !isReviewing, !isAccepting, let review, !attempted.contains(review.id),
              sourceConfiguration != nil, destinationConfiguration != nil else { return false }
        return review.value.kind != .fork || (!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count <= 4_096 && !title.contains("\0"))
    }
    var canLoadTransfers: Bool { transferCursor != nil && canRead && !isLoading }
    func update(target: RemoteWorkspaceTarget, projection: RemoteProjectionStore, transport: RemoteContextTransferTransport?, supported: Bool,
                providers: [ProviderKind], canWrite: Bool, perform: @escaping RemoteContextTransferStore.Perform,
                openConversation: @escaping @MainActor (UUID) -> Void) {
        let same = Self.sameCapture(self.target, target)
        if !same { disconnect() }
        self.target = .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID,
            configuration: target.configuration, rootID: target.rootID ?? (same ? self.target.rootID : nil))
        self.projection = projection; self.transport = transport; self.supported = supported; connected = transport != nil
        self.providers = providers.contains(target.configuration.provider) ? providers : [target.configuration.provider] + providers
        writesAllowed = canWrite; self.perform = perform; open = openConversation
    }
    func synchronize() async {
        guard canRead else { return }
        if let syncTask { await syncTask.value; return }
        let owner = generation
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == owner { self.syncTask = nil } }
            while self.generation == owner, self.canRead, !Task.isCancelled {
                let sequence = self.projection?.control?.binding.sequence
                if self.inventory != nil, sequence == self.inventorySequence { return }
                let loaded = await self.refreshInventory()
                guard loaded, self.generation == owner, self.inventorySequence != self.projection?.control?.binding.sequence else { return }
            }
        }
        syncTask = task; await task.value
    }
    @discardableResult func refreshInventory() async -> Bool {
        guard canRead, let transport else { return false }
        let owner = generation, token = UUID(), captured = target, sequence = projection?.control?.binding.sequence; inventoryRead = token
        var unused: RemoteHistoryBinding?
        do {
            let result = try await read(.init(target: captured, query: .inventory))
            guard case .inventory(let value) = result.value else { throw RemoteContextFailure(.invalidRequest) }
            unused = value.binding
            try Self.validate(value.transfers, binding: value.binding, offset: 0, retained: [])
            guard owner == generation, inventoryRead == token, !Task.isCancelled else { throw CancellationError() }
            let previous = inventory?.binding
            inventory = value; transfers = value.transfers.items; transferOffset = value.transfers.items.count; transferCursor = value.transfers.nextCursor
            leaseTargets[value.binding.leaseID] = captured; inventorySequence = sequence; unused = nil
            if let previous, previous != value.binding { scheduleRelease(previous, target: leaseTargets[previous.leaseID] ?? captured) }
            errorMessage = nil; return true
        } catch is CancellationError { }
        catch { if owner == generation, inventoryRead == token { errorMessage = Self.message(error) } }
        if let unused { scheduleRelease(unused, target: captured, transport: transport) }
        return false
    }
    func loadMoreTransfers() async {
        guard canLoadTransfers, let binding = inventory?.binding, let cursor = transferCursor else { return }
        let owner = generation, captured = leaseTargets[binding.leaseID] ?? target; isLoading = true
        defer { if owner == generation { isLoading = false } }
        do {
            let result = try await read(.init(target: captured, query: .transfers(binding: binding, cursor: cursor)))
            guard owner == generation, inventory?.binding == binding, case .transfers(let page) = result.value else { return }
            try Self.validate(page, binding: binding, offset: transferOffset, retained: transfers.map(\.id))
            transfers = Array((transfers + page.items).suffix(512)); transferOffset += page.items.count; transferCursor = page.nextCursor
        } catch { if owner == generation, inventory?.binding == binding { errorMessage = Self.message(error) } }
    }
    @discardableResult func prepare() async -> UUID? {
        guard canPrepare, let transport else { return nil }
        invalidate(); isReviewing = true
        let owner = generation, token = UUID(), captured = target
        let chosenKind = kind, chosenProvider = provider, chosenModel = model, chosenPermission = permission
        let chosenPath = chosenKind == .providerHandoff ? captured.workspacePath : workspaceOptions.first(where: { $0.id == workspaceID })?.path
        let lineage = inventory?.lineage
        reviewRead = token; activeReviewCalls += 1
        defer {
            if reviewRead == token { isReviewing = false }
            activeReviewCalls -= 1
            if activeReviewCalls == 0 { let values = waiters; waiters = []; values.forEach { $0.resume() } }
        }
        var returned: RemoteContextReview?
        do {
            let point = try sourcePoint()
            let bound = captured.rootID == nil ? try await transport.bind(captured) : captured
            guard owner == generation, reviewRead == token, !Task.isCancelled else { return nil }
            let intent: RemoteContextIntent
            if chosenKind == .mergeBack {
                guard let lineage else { throw RemoteContextFailure(.invalidTarget) }
                intent = .mergeBack(expectedParent: try await transport.parent(lineage.parentThreadID))
            } else {
                guard let chosenPath else { throw RemoteContextFailure(.invalidTarget) }
                let destination = RemoteContextDestination(provider: chosenProvider, model: chosenModel, permission: chosenPermission, workspacePath: chosenPath)
                intent = chosenKind == .fork ? .fork(destination) : .providerHandoff(destination)
            }
            let value = try await transport.review(.init(target: bound, sourcePoint: point, intent: intent)); returned = value
            guard Self.same(value.target, bound), value.id == value.binding.objectID, value.digest == value.binding.digest,
                  value.value.sourcePoint.threadID == bound.threadID else { throw RemoteContextFailure(.staleReview) }
            let source = try JSONDecoder().decode(ProviderConfiguration.self, from: await transport.document(value.value.sourceConfiguration, value.binding, bound))
            let destination = try JSONDecoder().decode(ProviderConfiguration.self, from: await transport.document(value.value.targetConfiguration, value.binding, bound))
            guard Self.same(source, captured.configuration) else { throw RemoteContextFailure(.staleReview) }
            switch intent {
            case .mergeBack(let parent):
                guard value.value.kind == .mergeBack, value.value.targetThreadID == parent.threadID,
                      Self.same(destination, parent.configuration) else { throw RemoteContextFailure(.staleReview) }
            case .fork, .providerHandoff:
                guard value.value.kind == (chosenKind == .fork ? .fork : .providerHandoff), destination.provider == chosenProvider,
                      destination.model.utf8.elementsEqual(chosenModel.utf8), destination.permission == chosenPermission,
                      destination.workspacePath.utf8.elementsEqual((chosenPath ?? "").utf8),
                      chosenKind != .providerHandoff || value.value.targetThreadID == captured.threadID else { throw RemoteContextFailure(.staleReview) }
            }
            let selection: ContextHandoffSelection?
            if let reference = value.value.previewSelection { selection = try JSONDecoder().decode(ContextHandoffSelection.self, from: await transport.document(reference, value.binding, bound)) }
            else { selection = nil }
            let suggested: String
            if value.value.title.complete { suggested = value.value.title.preview }
            else if let reference = value.value.title.content, let decoded = String(data: try await transport.document(reference, value.binding, bound), encoding: .utf8) { suggested = decoded }
            else { throw RemoteContextFailure(.invalidRequest) }
            guard owner == generation, reviewRead == token, !Task.isCancelled, canRead else { scheduleDiscard(value, transport: transport); return nil }
            target = bound; review = value; sourceConfiguration = source; destinationConfiguration = destination; previewSelection = selection
            leaseTargets[value.binding.leaseID] = bound
            if title.isEmpty { title = suggested }; errorMessage = nil
            return value.id
        } catch is CancellationError { if let returned { scheduleDiscard(returned, transport: transport) } }
        catch { if let returned { scheduleDiscard(returned, transport: transport) }; if owner == generation, reviewRead == token { errorMessage = Self.message(error) } }
        return nil
    }
    private func sourcePoint() throws -> ContextTransferSourcePoint {
        if sourceID == "latest" { return .latestStable }
        if sourceID.hasPrefix("run-"), let id = UUID(uuidString: String(sourceID.dropFirst(4))) { return .run(id) }
        if sourceID.hasPrefix("checkpoint-"), let id = UUID(uuidString: String(sourceID.dropFirst(11))) {
            for run in projection?.runs ?? [] {
                if let attempt = sourceCheckpoints.attempts(for: run, binding: projection?.browseBinding).last(where: { $0.stage == .postRun }),
                   attempt.id == id, attempt.phase == .ready, attempt.hasReceipt { return .checkpoint(runID: run.id, attemptID: id, digest: attempt.digest) }
            }
        }
        throw RemoteContextFailure(.invalidRequest)
    }
    @discardableResult func accept() async -> Bool {
        guard canConfirm, let review, let perform else { return false }
        let owner = generation; attempted.insert(review.id); isAccepting = true
        defer { isAccepting = false }
        let accepted = await perform(.contextTransfer(target: review.target, action: .begin(reviewID: review.id, digest: review.digest,
            title: review.value.kind == .fork ? title : nil)))
        guard owner == generation else { return accepted }
        if accepted { clear(id: review.id); inventorySequence = nil; await synchronize(); open?(review.value.targetThreadID) }
        else { errorMessage = "The transfer was refused or its result is unconfirmed. Check the saved remote request; it will not be repeated automatically." }
        return accepted
    }
    func useFreshContext(_ control: RemoteContextDeliveryControl) async {
        guard canRead, writesAllowed, !isAccepting, control.canUseFreshContext,
              inventory?.uncertain == control, let perform else { return }
        isAccepting = true; defer { isAccepting = false }
        _ = await perform(.contextTransfer(target: target, action: .useFreshContext(deliveryID: control.deliveryID, expectedTransferIDs: control.transferIDs)))
        inventorySequence = nil; await synchronize()
    }
    func openThread(_ id: UUID) { open?(id) }
    func loadSelection(_ transfer: RemoteContextTransferSummary) async {
        guard canRead, let transport else { return }
        let owner = generation, captured = target
        var unused: RemoteHistoryBinding?
        do {
            let result = try await read(.init(target: captured, query: .transfer(id: transfer.id)))
            guard case .transfer(let binding, let summary) = result.value, summary.id == transfer.id else { throw RemoteContextFailure(.invalidRequest) }
            unused = binding
            guard let reference = summary.selection else { scheduleRelease(binding, target: captured, transport: transport); return }
            let selection = try JSONDecoder().decode(ContextHandoffSelection.self, from: await transport.document(reference, binding, captured))
            guard owner == generation, !Task.isCancelled else { throw CancellationError() }
            deliverySelections[transfer.id] = selection
        } catch is CancellationError { }
        catch { if owner == generation { errorMessage = Self.message(error) } }
        if let unused { scheduleRelease(unused, target: captured, transport: transport) }
    }
    func clear(id: UUID?) {
        guard let value = review, id == value.id else { return }
        review = nil; sourceConfiguration = nil; destinationConfiguration = nil; previewSelection = nil; attempted.remove(value.id)
        if let transport { scheduleDiscard(value, transport: transport) }
    }
    func invalidate() { reviewRead = UUID(); isReviewing = false; clear(id: review?.id) }
    func leasedRead(_ query: RemoteContextQuery) async throws -> RemoteContextValue {
        let owner = generation
        let binding: RemoteHistoryBinding?
        switch query { case .transfers(let value, _), .messages(let value, _), .content(let value, _, _, _), .release(let value): binding = value; default: binding = nil }
        let captured = binding.flatMap { leaseTargets[$0.leaseID] } ?? target
        let value = try await read(.init(target: captured, query: query)).value
        guard owner == generation, !Task.isCancelled else { throw CancellationError() }
        return value
    }
    private func read(_ request: RemoteContextReadRequest) async throws -> RemoteContextReadResult {
        guard canRead, let transport else { throw RemoteContextFailure(.unavailable) }
        let id = UUID(), task = Task { try await transport.read(request) }; reads[id] = task
        defer { reads.removeValue(forKey: id) }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard Self.same(value.target, request.target) else { throw RemoteContextFailure(.invalidTarget) }
        return value
    }
    private func scheduleDiscard(_ value: RemoteContextReview, transport: RemoteContextTransferTransport) {
        guard cleanup[value.id] == nil else { return }
        cleanup[value.id] = Task { [weak self] in _ = try? await transport.discard(.init(target: value.target, reviewID: value.id, digest: value.digest)); self?.leaseTargets.removeValue(forKey: value.binding.leaseID); self?.cleanup.removeValue(forKey: value.id) }
    }
    private func scheduleRelease(_ binding: RemoteHistoryBinding, target: RemoteWorkspaceTarget, transport captured: RemoteContextTransferTransport? = nil) {
        guard let transport = captured ?? transport else { return }
        let id = UUID()
        cleanup[id] = Task { [weak self] in _ = try? await transport.read(.init(target: target, query: .release(binding: binding))); self?.leaseTargets.removeValue(forKey: binding.leaseID); self?.cleanup.removeValue(forKey: id) }
    }
    func disconnect() {
        if let syncTask { syncTask.cancel(); syncDrains.append(syncTask); self.syncTask = nil }
        invalidate()
        if let binding = inventory?.binding { scheduleRelease(binding, target: leaseTargets[binding.leaseID] ?? target) }
        generation = UUID(); inventoryRead = UUID(); inventorySequence = nil
        connected = false; writesAllowed = false; transport = nil; perform = nil; open = nil
        inventory = nil; transfers = []; deliverySelections = [:]; leaseTargets = [:]; transferCursor = nil; transferOffset = 0
        isLoading = false; isReviewing = false; isAccepting = false
        target = .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID, configuration: target.configuration)
        for task in reads.values { task.cancel() }
        sourceCheckpoints.clear(); for task in sourceReads.values { task.cancel() }
    }
    func drain() async {
        for task in syncDrains { await task.value }; syncDrains = []
        for task in Array(reads.values) { _ = await task.result }
        for task in Array(sourceReads.values) { _ = await task.result }
        if activeReviewCalls > 0 { await withCheckedContinuation { waiters.append($0) } }
        while !cleanup.isEmpty { for task in Array(cleanup.values) { await task.value } }
    }
    private static func sameCapture(_ a: RemoteWorkspaceTarget, _ b: RemoteWorkspaceTarget) -> Bool {
        a.environmentID == b.environmentID && a.projectID == b.projectID && a.threadID == b.threadID &&
            a.workspacePath.utf8.elementsEqual(b.workspacePath.utf8) && same(a.configuration, b.configuration)
    }
    private static func same<T: Encodable>(_ a: T, _ b: T) -> Bool { ContextTransferProtocol.same(a, b) }
    private static func validate(_ page: RemoteHistoryPage<RemoteContextTransferSummary>, binding: RemoteHistoryBinding, offset: Int, retained: [UUID]) throws {
        guard page.binding == binding, page.offset == offset, offset >= 0, offset <= page.totalCount,
              page.items.count <= page.totalCount - offset, page.complete == (page.nextCursor == nil),
              page.complete == (offset + page.items.count == page.totalCount), page.complete || !page.items.isEmpty,
              Set(page.items.map(\.id)).count == page.items.count, Set(page.items.map(\.id)).isDisjoint(with: retained) else { throw RemoteContextFailure(.staleCursor) }
    }
    private static func message(_ error: any Error) -> String { (error as? RemoteContextFailure)?.localizedDescription ?? (error as? RemoteEnvironmentClientError)?.localizedDescription ?? "The source, destination, or saved context changed. Review it again before creating a transfer." }
}
