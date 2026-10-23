import CoincideCore
import Foundation
import Observation

enum ContextTransferFormKind: String, CaseIterable, Identifiable {
    case fork, providerHandoff, mergeBack
    var id: Self { self }
    var title: String { switch self { case .fork: "Fork Context"; case .providerHandoff: "Switch Provider with Context"; case .mergeBack: "Merge Context Back" } }
}
struct ContextTransferSourceOption: Identifiable {
    let id: String
    let title: String
}
struct ContextTransferWorkspaceOption: Identifiable {
    let id: String
    let title: String
    let path: String
}
struct ContextTransferNativeTransport: Sendable {
    var review: @Sendable (ContextTransferReviewRequest) async throws -> ContextTransferReview
    var discard: @Sendable (UUID, String) async -> Void
    var accept: @Sendable (UUID, String, String?) async throws -> WorkspaceCommandReceipt
}

/// Retained independently of sheet visibility. It owns native review lifetimes,
/// and never writes composer text or attachments to prepare a transfer.
@MainActor @Observable
final class ContextTransferStore {
    typealias Destination = @MainActor (ContextTransferFormKind, ProviderKind, String, String, PermissionMode, UUID?) throws -> ProviderConfiguration
    private(set) var sourceThread: CodingThread?
    private(set) var snapshot = WorkspaceSnapshot()
    private(set) var review: ContextTransferReview?
    private(set) var isReviewing = false
    private(set) var isAccepting = false
    private(set) var errorMessage: String?
    private(set) var acceptedID: UUID?
    var kind = ContextTransferFormKind.fork { didSet { if kind != oldValue { invalidate() } } }
    var sourceID = "latest" { didSet { if sourceID != oldValue { invalidate() } } }
    var workspaceID = "" { didSet { if workspaceID != oldValue { invalidate() } } }
    var provider = ProviderKind.codex { didSet { if provider != oldValue { model = ""; invalidate() } } }
    var agentID: UUID? { didSet { if agentID != oldValue { invalidate() } } }
    var model = "" { didSet { if !model.utf8.elementsEqual(oldValue.utf8) { invalidate() } } }
    var permission = PermissionMode.supervised { didSet { if permission != oldValue { invalidate() } } }
    var title = ""
    @ObservationIgnored private var transport: ContextTransferNativeTransport?
    @ObservationIgnored private var destination: Destination?
    @ObservationIgnored private var canReview: @MainActor () -> Bool = { false }
    @ObservationIgnored private var canAccept: @MainActor (ContextTransferReview) -> Bool = { _ in false }
    @ObservationIgnored private var open: @MainActor (UUID) -> Void = { _ in }
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var readID = UUID()
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var sourceKey: Data?
    @ObservationIgnored private var reviews: [UUID: ContextTransferReview] = [:]
    @ObservationIgnored private var attempted: Set<UUID> = []
    @ObservationIgnored private var reads: [UUID: Task<ContextTransferReview, any Error>] = [:]
    @ObservationIgnored private var cleanup: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeReviewCalls = 0
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    init() { }
    var sourceOptions: [ContextTransferSourceOption] {
        var result: [ContextTransferSourceOption] = [.init(id: "latest", title: "Latest stable completed observation")]
        for run in (sourceThread?.runHistory ?? []).reversed() where run.removedByHistoryOperationID == nil && run.status.isTerminal && run.status != .unknown && run.messageAttributionVersion != nil {
            result.append(.init(id: "run-" + run.id.uuidString, title: "Run · \(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(run.status.rawValue)"))
            if let attempt = run.checkpoints?.postRun, attempt.phase == .ready, attempt.receipt != nil {
                result.append(.init(id: "checkpoint-" + attempt.id.uuidString, title: "After-run checkpoint · \(attempt.updatedAt.formatted(date: .abbreviated, time: .shortened))"))
            }
        }
        return result
    }
    var workspaceOptions: [ContextTransferWorkspaceOption] {
        guard let sourceThread else { return [] }
        var seen = Set<Data>(), result: [ContextTransferWorkspaceOption] = []
        let roots = snapshot.projects.filter { $0.id == sourceThread.projectID }.map { ($0.name, $0.path) }
        let worktrees = snapshot.threads.filter { $0.projectID == sourceThread.projectID && snapshot.workspaceReady(for: $0) }.map { ($0.title, $0.workspacePath) }
        for (name, path) in [("Current conversation", sourceThread.workspacePath)] + roots + worktrees {
            let bytes = Data(path.utf8)
            if seen.insert(bytes).inserted { result.append(.init(id: bytes.base64EncodedString(), title: name, path: path)) }
        }
        return result
    }
    var parent: CodingThread? { sourceThread?.contextTransferLineage.flatMap { lineage in snapshot.threads.first { $0.id == lineage.parentThreadID } } }
    var canPrepare: Bool { !closed && !isReviewing && !isAccepting && transport != nil && sourceThread != nil && canReview() && sourceOptions.contains { $0.id == sourceID } && (kind != .mergeBack || parent != nil) }
    var canConfirm: Bool {
        guard !closed, !isReviewing, !isAccepting, let review, !attempted.contains(review.id), canAccept(review) else { return false }
        return review.kind != .fork || (!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count <= 4_096 && !title.contains("\0"))
    }
    var transfers: [ContextTransfer] { snapshot.contextTransfers?.filter { $0.sourceThreadID == sourceThread?.id || $0.targetThreadID == sourceThread?.id } ?? [] }
    func update(sourceThreadID: UUID, snapshot: WorkspaceSnapshot, transport: ContextTransferNativeTransport?, destination: @escaping Destination,
                canReview: @escaping @MainActor () -> Bool, canAccept: @escaping @MainActor (ContextTransferReview) -> Bool,
                open: @escaping @MainActor (UUID) -> Void) {
        guard !closed else { return }
        let source = snapshot.threads.first { $0.id == sourceThreadID }
        let key = source.flatMap { try? ContextTransferProtocol.payload(ProviderConfiguration(thread: $0)) }
        if sourceThread?.id != sourceThreadID || sourceKey != key { invalidate(); generation = UUID() }
        self.snapshot = snapshot; sourceThread = source; sourceKey = key; self.transport = transport; self.destination = destination
        self.canReview = canReview; self.canAccept = canAccept; self.open = open
        if !configured, let source {
            configured = true; provider = source.provider; agentID = source.acpAgent?.id; model = source.model; permission = source.permission
            workspaceID = Data(source.workspacePath.utf8).base64EncodedString()
        }
    }
    @discardableResult func prepare() async -> UUID? {
        guard canPrepare, let source = sourceThread,
              let destination, let transport else { return nil }
        invalidate(); isReviewing = true; errorMessage = nil
        let owner = generation, token = UUID(); readID = token; activeReviewCalls += 1
        defer {
            if readID == token { isReviewing = false }
            activeReviewCalls -= 1
            if activeReviewCalls == 0 { let values = waiters; waiters = []; values.forEach { $0.resume() } }
        }
        do {
            let point: ContextTransferSourcePoint
            if sourceID == "latest" { point = .latestStable }
            else if sourceID.hasPrefix("run-"), let id = UUID(uuidString: String(sourceID.dropFirst(4))) { point = .run(id) }
            else if sourceID.hasPrefix("checkpoint-"), let id = UUID(uuidString: String(sourceID.dropFirst(11))),
                    let run = source.runHistory?.first(where: { $0.checkpoints?.postRun?.id == id }), let attempt = run.checkpoints?.postRun {
                point = .checkpoint(runID: run.id, attemptID: id, digest: try ContextTransferProtocol.digest(attempt))
            } else { throw ContextTransferError.invalidSource }
            let intent: ContextTransferIntent
            switch kind {
            case .mergeBack:
                guard let parent else { throw ContextTransferError.invalidSource }
                intent = .mergeBack(targetConfiguration: .init(thread: parent))
            case .fork:
                guard let workspace = workspaceOptions.first(where: { $0.id == workspaceID }) else { throw ContextTransferError.invalidSource }
                intent = .fork(destination: try destination(kind, provider, workspace.path, model, permission, agentID))
            case .providerHandoff:
                intent = .providerHandoff(destination: try destination(kind, provider, source.workspacePath, model, permission, agentID))
            }
            let request = ContextTransferReviewRequest(sourceThreadID: source.id, expectedConfiguration: .init(thread: source), sourcePoint: point, intent: intent)
            let task = Task { try await transport.review(request) }; reads[token] = task
            defer { reads.removeValue(forKey: token) }
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard ContextTransferProtocol.same(value.request, request), value.sourcePoint.threadID == source.id else { await transport.discard(value.id, value.digest); throw ContextTransferError.staleReview }
            guard !Task.isCancelled, generation == owner, readID == token, !closed, canReview() else { scheduleDiscard(value, transport: transport); return nil }
            review = value; reviews[value.id] = value; acceptedID = nil
            if title.isEmpty { title = value.title }
            return value.id
        } catch is CancellationError { }
        catch { if generation == owner, readID == token { errorMessage = (error as? ContextTransferError)?.localizedDescription ?? "The source or destination changed. Review the context again before creating a transfer." } }
        return nil
    }
    @discardableResult func accept() async -> Bool {
        guard canConfirm, let review, let transport else { return false }
        let owner = generation; isAccepting = true; attempted.insert(review.id)
        defer { isAccepting = false }
        do {
            let receipt = try await transport.accept(review.id, review.digest, review.kind == .fork ? title : nil)
            guard receipt.rejection == nil else { throw CoincideError(receipt.rejection!) }
            acceptedID = review.id
            if generation == owner { clear(id: review.id); open(review.targetThreadID) }
            return true
        } catch {
            if generation == owner { errorMessage = "The transfer was refused or its result is unconfirmed. Inspect its saved state; it will not be repeated automatically." }
            return false
        }
    }
    func clear(id: UUID?) {
        guard let id, let value = reviews.removeValue(forKey: id) else { return }
        if review?.id == id { review = nil }; attempted.remove(id)
        if let transport { scheduleDiscard(value, transport: transport) }
    }
    func invalidate() { readID = UUID(); isReviewing = false; for task in reads.values { task.cancel() }; for id in Array(reviews.keys) { clear(id: id) } }
    func openThread(_ id: UUID) { if snapshot.threads.contains(where: { $0.id == id }) { open(id) } }
    private func scheduleDiscard(_ review: ContextTransferReview, transport: ContextTransferNativeTransport) {
        guard cleanup[review.id] == nil else { return }
        cleanup[review.id] = Task { [weak self] in await transport.discard(review.id, review.digest); self?.cleanup.removeValue(forKey: review.id) }
    }
    func shutdown() async {
        closed = true; invalidate(); generation = UUID()
        for task in reads.values { task.cancel() }
        for task in Array(reads.values) { _ = await task.result }
        if activeReviewCalls > 0 { await withCheckedContinuation { waiters.append($0) } }
        while !cleanup.isEmpty { for task in Array(cleanup.values) { await task.value } }
        transport = nil
    }
    func cancelShutdown() { closed = false }
}
