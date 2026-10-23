import CoincideCore
import Foundation
import Observation

/// Reads belong to this presentation; accepted writes belong to the durable workspace engine.
@MainActor @Observable
final class PullRequestActionStore {
    let pullRequests: PullRequestStore
    let session: (any GitHubPullRequestActionSession)?
    private(set) var reference: GitHubPullRequestReference?
    private(set) var state: GitHubPullRequestActionState?
    private(set) var stateError: String?
    private(set) var isLoadingState = false
    private(set) var review: GitHubPullRequestActionReview?
    private(set) var isReviewing = false
    private(set) var isPerforming = false
    private(set) var actionError: String?
    private(set) var pendingReview: GitHubPullRequestActionReview?
    private(set) var pendingIsUnconfirmed = false
    private var generation = UUID()
    private var reviewGeneration = UUID()
    private var stateReadID: UUID?
    private var closed = false
    private var dismissedOutcomes: Set<UUID> = []
    @ObservationIgnored private let supportOverride: PullRequestStore.ActionSupport?
    @ObservationIgnored private let operationsOverride: (@MainActor () -> [PullRequestActionOperation])?
    @ObservationIgnored private var reads: [UUID: OwnedRead] = [:]
    @ObservationIgnored private var controls: [UUID: Task<WorkspaceCommandReceipt, any Error>] = [:]
    @ObservationIgnored private var disposals: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var closeTask: Task<Void, Never>?

    private struct OwnedRead {
        let cancel: @MainActor () -> Void
        let join: @MainActor () async -> Void
    }
    private var support: PullRequestStore.ActionSupport? { supportOverride ?? pullRequests.actionSupport }
    var allOperations: [PullRequestActionOperation] {
        (operationsOverride?() ?? pullRequests.actionOperations)
            .sorted { lhs, rhs in
                if lhs.blocksAction != rhs.blocksAction { return lhs.blocksAction }
                return lhs.updatedAt > rhs.updatedAt
            }
    }
    var operations: [PullRequestActionOperation] { allOperations.filter { $0.review.state.reference == reference } }
    var unresolvedPending: GitHubPullRequestActionReview? {
        guard let pendingReview, !operations.contains(where: { $0.id == pendingReview.id }) else { return nil }
        return pendingReview
    }
    var lastOutcome: GitHubPullRequestActionOutcome? {
        operations.first { $0.phase == .succeeded && !dismissedOutcomes.contains($0.id) }?.outcome
    }
    var isBusy: Bool {
        closed || isReviewing || isPerforming || pullRequests.isBusy || unresolvedPending != nil || operations.contains(where: \.blocksAction)
    }
    var isAvailable: Bool { support != nil || !allOperations.isEmpty }
    var canRecover: Bool { !closed && !isPerforming && support != nil }

    init(pullRequests: PullRequestStore, session: (any GitHubPullRequestActionSession)?,
         support: PullRequestStore.ActionSupport? = nil,
         operations: (@MainActor () -> [PullRequestActionOperation])? = nil) {
        self.pullRequests = pullRequests; self.session = session
        supportOverride = support; operationsOverride = operations
    }

    func load(_ reference: GitHubPullRequestReference) async {
        guard !closed else { return }
        if self.reference != reference {
            generation = UUID(); reviewGeneration = UUID()
            discardReview(); state = nil; actionError = nil
        }
        self.reference = reference
        guard let session, pullRequests.canReadActions else { return }
        if let stateReadID { reads[stateReadID]?.cancel() }
        let id = UUID(); generation = id; isLoadingState = true; stateError = nil
        stateReadID = id
        let task = Task { try await session.actionState(reference) }
        reads[id] = .init(cancel: { task.cancel() }, join: { _ = await task.result })
        defer {
            reads[id] = nil
            if stateReadID == id { stateReadID = nil }
            if generation == id { isLoadingState = false }
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == id, !closed, !Task.isCancelled, self.reference == reference else { return }
            state = value
        } catch is CancellationError { }
        catch { if generation == id, !closed { state = nil; stateError = Self.message(error) } }
    }

    func prepare(_ action: GitHubPullRequestAction, removeAgentCredits: Bool) async {
        guard let support, let reference, !isBusy, pullRequests.canReadActions else { return }
        discardReview()
        let id = UUID(); reviewGeneration = id; isReviewing = true; actionError = nil
        let task = Task { try await support.prepare(action, reference, removeAgentCredits) }
        reads[id] = .init(cancel: { task.cancel() }, join: { _ = await task.result })
        defer { reads[id] = nil; if reviewGeneration == id { isReviewing = false } }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !closed, !Task.isCancelled, reviewGeneration == id, self.reference == reference else {
                dispose(value.id, support: support); return
            }
            state = value.state; review = value
        } catch is CancellationError { }
        catch { if !closed, reviewGeneration == id { review = nil; actionError = Self.message(error) } }
    }

    func discardReview() {
        guard !isPerforming, let review else { return }
        self.review = nil
        if let support { dispose(review.id, support: support) }
    }

    func perform() async {
        guard let support, let review, !isBusy, pullRequests.canReadActions else { return }
        isPerforming = true; actionError = nil; pendingReview = review; pendingIsUnconfirmed = false
        self.review = nil
        let id = review.id
        let task = Task { try await support.begin(review) }
        controls[id] = task
        defer { controls[id] = nil; isPerforming = false }
        do {
            let receipt = try await task.value
            if let rejection = receipt.rejection {
                pendingReview = nil
                if !closed { actionError = rejection }
            }
        } catch {
            if Self.isPreAdmissionRefusal(error) {
                pendingReview = nil
            } else {
                // An absent reply is never permission to send this review again.
                pendingIsUnconfirmed = true
            }
            if !closed { actionError = Self.message(error) }
        }
        if !closed { await refreshCurrentReference(review.state.reference) }
    }

    /// Both recovery actions inspect/acknowledge the original intent; neither sends it again.
    func inspect(_ operationID: UUID) async {
        guard let support, !closed, !isPerforming,
              allOperations.contains(where: { $0.id == operationID && $0.phase == .unconfirmed }) else { return }
        await control(operationID) { try await support.inspect(operationID) }
    }
    func acknowledge(_ operationID: UUID) async {
        guard let support, !closed, !isPerforming,
              allOperations.contains(where: { $0.id == operationID && $0.requiresAcknowledgment }) else { return }
        await control(operationID) { try await support.acknowledge(operationID) }
    }

    private func control(_ id: UUID, _ operation: @escaping @MainActor () async throws -> WorkspaceCommandReceipt) async {
        isPerforming = true; actionError = nil
        let task = Task { try await operation() }; controls[id] = task
        defer { controls[id] = nil; isPerforming = false }
        do { if let rejection = try await task.value.rejection, !closed { actionError = rejection } }
        catch { if !closed { actionError = Self.message(error) } }
        if !closed, let reference { await load(reference) }
    }
    private func refreshCurrentReference(_ reference: GitHubPullRequestReference) async {
        guard !closed, self.reference == reference else { return }
        await load(reference)
        guard !closed, self.reference == reference else { return }
        await pullRequests.select(reference)
        guard !closed, self.reference == reference else { return }
        await pullRequests.refresh()
    }
    func dismissOutcome() {
        dismissedOutcomes.formUnion(operations.filter { $0.phase == .succeeded }.map(\.id)); actionError = nil
    }
    private func dispose(_ id: UUID, support: PullRequestStore.ActionSupport) {
        guard disposals[id] == nil else { return }
        disposals[id] = Task { await support.discard(id); self.disposals[id] = nil }
    }

    func close() {
        guard !closed else { return }
        discardReview(); closed = true; generation = UUID(); reviewGeneration = UUID()
        isLoadingState = false; isReviewing = false
        for read in reads.values { read.cancel() }
        closeTask = Task { await self.drain() }
    }
    func shutdown() async { close(); await closeTask?.value }
    private func drain() async {
        while !reads.isEmpty || !controls.isEmpty || !disposals.isEmpty {
            for read in Array(reads.values) { await read.join() }
            // Accepted controls finish independently of the sheet's lifetime.
            for task in Array(controls.values) { _ = await task.result }
            for (id, task) in Array(disposals) { await task.value; disposals[id] = nil }
            await Task.yield()
        }
    }

    static func message(_ error: any Error) -> String {
        if let error = error as? GitHubPullRequestActionError { return error.localizedDescription }
        if let error = error as? GitHubPullRequestError { return error.localizedDescription }
        if error is CancellationError { return String(localized: "Cancelled. Refresh to inspect the current pull request state.") }
        return String(localized: "The pull request action could not finish. Refresh and check its current state.")
    }

    /// These typed failures are returned by the engine's begin boundary before
    /// dispatch. Arbitrary transport errors and cancellation give no such proof.
    private static func isPreAdmissionRefusal(_ error: any Error) -> Bool {
        if error is WorkspaceCommandError || error is TaskIsolationError { return true }
        if let error = error as? WorkspaceCommitError, case .commandIDCollision = error { return true }
        if let error = error as? GitHubPullRequestActionError { return error.kind != .uncertain }
        return false
    }
}

enum SourceControlPreferenceKeys {
    static let removeAgentCredits = "sourceControl.removeAgentCreditsWhenMerging"
    static let mergeMethod = "sourceControl.preferredMergeMethod"
    static let fetchInterval = "sourceControl.automaticFetchInterval"
    static let autoPullDefault = "sourceControl.autoPullDefaultBranch"
    static let autoPullOverrides = "sourceControl.autoPullProjectOverrides"
}
