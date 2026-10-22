import CoincideCore
import Foundation
import Observation

/// Shared by checkout path, rather than by the sheet or current selection.
/// Reads are replaceable; creation belongs to the durable workspace engine.
@MainActor @Observable
final class PullRequestStore {
    struct CheckoutSupport {
        let configuration: @MainActor () -> (ProviderConfiguration, RunCheckpointPolicy?)?
        let canPrepare: @MainActor (GitHubPullRequestCheckoutMode, GitHubPullRequestCheckoutPlan?, UUID?) -> Bool
        let begin: @MainActor (PullRequestCheckoutReview) async throws -> WorkspaceCommandReceipt
        let open: @MainActor (UUID) -> Void
        var unavailableReason: (@MainActor (GitHubPullRequestCheckoutMode, GitHubPullRequestCheckoutPlan?, UUID?) -> String?)? = nil
        var busyWorktreePaths: @MainActor () -> [String] = { [] }
    }
    let path: String
    private(set) var context: GitHubPullRequestContext?
    private(set) var page: GitHubPullRequestPage?
    private(set) var selected: GitHubPullRequestReference?
    private(set) var detail: GitHubPullRequestDetail?
    private(set) var operation: PullRequestCreationOperation?
    private(set) var checkoutOperation: PullRequestCheckoutOperation?
    private(set) var checkoutOperations: [PullRequestCheckoutOperation] = []
    private(set) var contextError: String?
    private(set) var listError: String?
    private(set) var detailError: String?
    private(set) var actionError: String?
    private(set) var isLoading = false
    private(set) var isLoadingList = false
    private(set) var isLoadingDetail = false
    private(set) var isPreparing = false
    private(set) var isAccepting = false
    private(set) var isInspecting = false
    var isBusy: Bool { closed || isAccepting || isPreparing || isInspecting || operation?.isWorking == true }
    var canCreate: Bool {
        guard !isBusy, operation?.locksSource != true, checkoutOperation?.locksSource != true, let context,
              context.existingPullRequest == nil, canMutate() else { return false }
        return context.readiness == .ready || context.readiness == .defaultBranch
    }
    var canCheckout: Bool {
        canPrepareCheckout(mode: .worktree) || canPrepareCheckout(mode: .local)
    }
    func canPrepareCheckout(mode: GitHubPullRequestCheckoutMode) -> Bool {
        guard !isBusy, operation?.locksSource != true,
              context != nil, let checkoutSupport, checkoutSupport.configuration() != nil else { return false }
        return checkoutSupport.canPrepare(mode, nil, nil)
    }
    func checkoutAdmissionMessage(mode: GitHubPullRequestCheckoutMode) -> String? {
        checkoutSupport?.unavailableReason?(mode, nil, nil)
    }
    var isMutating: Bool { isAccepting || operation?.isWorking == true || checkoutOperations.contains(where: \.isWorking) }
    var acceptingCheckoutID: UUID? { acceptingCheckoutReview?.id }
    var mutationPaths: [String] {
        var paths = checkoutOperations.filter(\.isWorking).flatMap(\.scopePaths)
        if let acceptingCheckoutReview { paths += acceptingCheckoutReview.plan.affectedWorkspacePaths }
        if let acceptingReview { paths += [acceptingReview.context.repositoryPath, acceptingReview.context.commonDirectoryPath] }
        if let operation, operation.isWorking { paths += operation.scopePaths }
        return Array(Set(paths))
    }

    private let session: any GitHubPullRequestSession
    private let engine: WorkspaceEngine?
    private let owner: @MainActor () -> UUID?
    private let canRead: @MainActor () -> Bool
    private let canMutate: @MainActor () -> Bool
    private let updateWorkspace: @MainActor (WorkspaceUpdate) -> Void
    private let checkoutSupport: CheckoutSupport?
    private var closed = false
    private var readsSuspended = false
    private var contextGeneration = UUID()
    private var listGeneration = UUID()
    private var detailGeneration = UUID()
    private var reviewGeneration = UUID()
    private var contextTask: Task<GitHubPullRequestContext, any Error>?
    private var listTask: Task<GitHubPullRequestPage, any Error>?
    private var detailTask: Task<GitHubPullRequestDetail, any Error>?
    private var reviewTask: Task<GitHubPullRequestCreateReview, any Error>?
    private var checkoutReviewTask: Task<PullRequestCheckoutReview, any Error>?
    private var acceptanceTask: Task<WorkspaceCommandReceipt, any Error>?
    private var acceptingReview: GitHubPullRequestCreateReview?
    private var acceptingCheckoutReview: PullRequestCheckoutReview?
    private var inspectionTask: Task<WorkspaceCommandReceipt, any Error>?
    private var postOperationTask: Task<Void, Never>?
    private struct OwnedRead {
        let cancel: @Sendable () -> Void
        let drain: Task<Void, Never>
    }
    private var ownedReads: [UUID: OwnedRead] = [:]
    private var listState = GitHubPullRequestListState.open
    private var listQuery = ""

    init(path: String, session: any GitHubPullRequestSession, engine: WorkspaceEngine?,
         owner: @escaping @MainActor () -> UUID?, canRead: @escaping @MainActor () -> Bool,
         canMutate: @escaping @MainActor () -> Bool,
         updateWorkspace: @escaping @MainActor (WorkspaceUpdate) -> Void,
         checkoutSupport: CheckoutSupport? = nil) {
        self.path = Self.canonical(path); self.session = session; self.engine = engine
        self.owner = owner; self.canRead = canRead; self.canMutate = canMutate; self.updateWorkspace = updateWorkspace
        self.checkoutSupport = checkoutSupport
    }

    func apply(_ snapshot: WorkspaceSnapshot) {
        let previous = operation
        let previousCheckout = checkoutOperation
        let projectID = owner()
        operation = snapshot.pullRequestCreations?.last {
            $0.projectID == projectID && Self.canonical($0.review.context.workspacePath) == path
        }
        checkoutOperations = snapshot.pullRequestCheckouts?.filter {
            $0.review.projectID == projectID && Self.canonical($0.review.plan.sourcePath) == path
        } ?? []
        checkoutOperation = checkoutOperations.last
        guard !closed else { return }
        if let operation, operation.id != previous?.id || operation.phase != previous?.phase {
            switch operation.result {
            case .created(let result), .openedExisting(let result):
                selected = result.summary.reference; detail = result; detailError = nil
                postOperationTask?.cancel()
                postOperationTask = Task { [weak self] in await self?.refresh() }
            case nil: break
            }
        }
        if let checkoutOperation, checkoutOperation.result != nil,
           checkoutOperation.id != previousCheckout?.id || checkoutOperation.phase != previousCheckout?.phase {
            postOperationTask?.cancel()
            postOperationTask = Task { [weak self] in await self?.refresh() }
        }
    }

    func refresh() async {
        guard !closed, !readsSuspended, canRead() else { return }
        let generation = UUID(); contextGeneration = generation; isLoading = true; contextError = nil
        contextTask?.cancel()
        let session = session, task = Task { try await session.context() }; contextTask = task
        ownRead(task, id: generation)
        defer {
            ownedReads.removeValue(forKey: generation)
            if generation == contextGeneration { contextTask = nil; isLoading = false }
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try value.validate()
            guard !closed, !Task.isCancelled, canRead(), generation == contextGeneration,
                  Self.canonical(value.workspacePath) == path else { return }
            let changedRepository = context?.repository != value.repository
            context = value
            if changedRepository {
                listGeneration = UUID(); detailGeneration = UUID(); listTask?.cancel(); detailTask?.cancel()
                page = nil; selected = nil; detail = nil; listError = nil; detailError = nil
            }
            if let current = value.existingPullRequest, selected == nil { selected = current.reference }
            await loadList(state: listState, query: listQuery)
            if let selected { await select(selected) }
        } catch is CancellationError { }
        catch {
            guard !closed, !Task.isCancelled, generation == contextGeneration else { return }
            context = nil; page = nil; detail = nil; selected = nil
            contextError = Self.message(error)
        }
    }

    func loadList(state: GitHubPullRequestListState = .open, query: String = "") async {
        guard !closed, !readsSuspended, canRead(), let repository = context?.repository else { return }
        listState = state; listQuery = query
        let generation = UUID(); listGeneration = generation; isLoadingList = true; listError = nil
        listTask?.cancel()
        let session = session
        let request = GitHubPullRequestListQuery(state: state, query: query.isEmpty ? nil : query, limit: 50)
        let task = Task { try await session.list(query: request) }; listTask = task
        ownRead(task, id: generation)
        defer {
            ownedReads.removeValue(forKey: generation)
            if generation == listGeneration { listTask = nil; isLoadingList = false }
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !closed, !Task.isCancelled, canRead(), generation == listGeneration, context?.repository == repository else { return }
            guard value.items.count <= request.limit, value.items.allSatisfy({ $0.reference.repository == repository }) else {
                throw GitHubPullRequestError(.invalidResponse)
            }
            for item in value.items { try item.validate() }
            page = value
        } catch is CancellationError { }
        catch { if !closed, !Task.isCancelled, generation == listGeneration { page = nil; listError = Self.message(error) } }
    }

    func select(_ reference: GitHubPullRequestReference) async {
        guard !closed, !readsSuspended, canRead(), context?.repository == reference.repository else { return }
        selected = reference
        await readDetail { try await $0.detail(reference) }
    }
    func resolve(_ reference: String) async {
        guard !closed, !readsSuspended, canRead(), context != nil else { return }
        await readDetail { try await $0.resolve(reference) }
    }
    private func readDetail(_ read: @escaping @Sendable (any GitHubPullRequestSession) async throws -> GitHubPullRequestDetail) async {
        guard let repository = context?.repository else { return }
        let generation = UUID(); detailGeneration = generation; isLoadingDetail = true; detailError = nil
        detailTask?.cancel(); detail = nil
        let session = session, task = Task { try await read(session) }; detailTask = task
        ownRead(task, id: generation)
        defer {
            ownedReads.removeValue(forKey: generation)
            if generation == detailGeneration { detailTask = nil; isLoadingDetail = false }
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try value.validate()
            guard !closed, !Task.isCancelled, canRead(), generation == detailGeneration, context?.repository == repository else { return }
            guard value.summary.reference.repository == repository else { throw GitHubPullRequestError(.invalidResponse) }
            selected = value.summary.reference; detail = value
        } catch is CancellationError { }
        catch { if !closed, !Task.isCancelled, generation == detailGeneration { detailError = Self.message(error) } }
    }

    func prepareCreation(title: String, body: String, baseBranch: String?, isDraft: Bool) async throws -> GitHubPullRequestCreateReview {
        guard !closed, !readsSuspended, !isBusy, operation?.locksSource != true, checkoutOperation?.locksSource != true,
              canMutate(), let engine, let projectID = owner() else { throw CancellationError() }
        isPreparing = true; actionError = nil
        let generation = UUID(); reviewGeneration = generation
        let path = path
        let task = Task { try await engine.reviewPullRequestCreation(projectID: projectID, workspacePath: path,
            title: title, body: body, baseBranch: baseBranch, isDraft: isDraft) }
        reviewTask = task
        ownRead(task, id: generation)
        defer {
            ownedReads.removeValue(forKey: generation)
            if generation == reviewGeneration { reviewTask = nil; isPreparing = false }
        }
        do {
            let review = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !closed, !Task.isCancelled, generation == reviewGeneration, owner() == projectID, canMutate(),
                  Self.canonical(review.context.workspacePath) == path else {
                await engine.discardPullRequestCreationReview(reviewID: review.id)
                throw CancellationError()
            }
            return review
        } catch {
            if !closed, !(error is CancellationError), generation == reviewGeneration { actionError = Self.message(error) }
            throw error
        }
    }

    func create(_ review: GitHubPullRequestCreateReview) async throws {
        guard !closed, !isAccepting, checkoutOperation?.locksSource != true, canMutate(), let engine, let projectID = owner(),
              Self.canonical(review.context.workspacePath) == path,
              operation?.locksSource != true || operation?.id == review.id else { throw CancellationError() }
        acceptingReview = review; isAccepting = true; actionError = nil
        let task = Task { try await engine.beginPullRequestCreation(projectID: projectID, review: review) }
        acceptanceTask = task
        defer { acceptanceTask = nil; isAccepting = false; acceptingReview = nil }
        do {
            let receipt = try await task.value
            updateWorkspace(await engine.current())
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        } catch {
            updateWorkspace(await engine.current())
            if !closed { actionError = Self.message(error) }
            throw error
        }
    }

    func reconcileCreation() async throws {
        guard !closed, !isInspecting, canRead(), let engine, let operation, operation.phase == .unconfirmed,
              operation.acknowledgedAt == nil else { throw CancellationError() }
        isInspecting = true; actionError = nil
        let task = Task { try await engine.reconcilePullRequestCreation(operationID: operation.id) }; inspectionTask = task
        defer { inspectionTask = nil; isInspecting = false }
        do {
            let receipt = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            updateWorkspace(await engine.current())
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        } catch { if !closed { actionError = Self.message(error) }; throw error }
    }
    func acknowledgeCreation() async throws {
        guard !closed, !isInspecting, let engine, let operation, operation.phase == .unconfirmed else { throw CancellationError() }
        let receipt = try await engine.dispatch(.acknowledgePullRequestCreation(operationID: operation.id))
        updateWorkspace(await engine.current())
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
    }
    func discardReview(_ id: UUID) async { await engine?.discardPullRequestCreationReview(reviewID: id) }

    func prepareCheckout(reference: GitHubPullRequestReference, mode: GitHubPullRequestCheckoutMode,
                         submodules: ProjectWorktreeSubmoduleMode = .none, reviewSetup: Bool = true) async throws -> PullRequestCheckoutReview {
        guard canPrepareCheckout(mode: mode), let engine, let projectID = owner(), let support = checkoutSupport,
              let captured = support.configuration(), context?.repository == reference.repository else {
            try rejectCheckout(mode: mode, plan: nil, excludingOperationID: nil)
        }
        isPreparing = true; actionError = nil
        let generation = UUID(); reviewGeneration = generation
        let path = path
        let busyWorktreePaths = support.busyWorktreePaths()
        let task = Task { try await engine.reviewPullRequestCheckout(projectID: projectID, workspacePath: path,
            reference: reference, mode: mode, configuration: captured.0, checkpointPolicy: captured.1,
            submodules: submodules, reviewSetup: reviewSetup, busyWorktreePaths: busyWorktreePaths) }
        checkoutReviewTask = task; ownRead(task, id: generation)
        defer {
            ownedReads.removeValue(forKey: generation)
            if generation == reviewGeneration { checkoutReviewTask = nil; isPreparing = false }
        }
        do {
            let review = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !closed, !readsSuspended, !Task.isCancelled, generation == reviewGeneration,
                  owner() == projectID, Self.canonical(review.plan.sourcePath) == path else {
                await engine.discardPullRequestCheckoutReview(reviewID: review.id); throw CancellationError()
            }
            guard support.canPrepare(mode, review.plan, nil) else {
                await engine.discardPullRequestCheckoutReview(reviewID: review.id)
                try rejectCheckout(mode: mode, plan: review.plan, excludingOperationID: nil)
            }
            return review
        } catch {
            if !closed, !(error is CancellationError), generation == reviewGeneration { actionError = Self.message(error) }
            throw error
        }
    }
    func checkout(_ review: PullRequestCheckoutReview) async throws {
        guard !closed, !isBusy, operation?.locksSource != true,
              let support = checkoutSupport, owner() == review.projectID,
              Self.canonical(review.plan.sourcePath) == path, support.canPrepare(review.plan.request.mode, review.plan, review.id) else {
            try rejectCheckout(mode: review.plan.request.mode, plan: review.plan, excludingOperationID: review.id)
        }
        isAccepting = true; acceptingCheckoutReview = review; actionError = nil
        let task = Task { try await support.begin(review) }; acceptanceTask = task
        defer { acceptanceTask = nil; isAccepting = false; acceptingCheckoutReview = nil }
        do {
            let receipt = try await task.value
            if let engine { updateWorkspace(await engine.current()) }
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        } catch {
            if let engine { updateWorkspace(await engine.current()) }
            if !closed { actionError = Self.message(error) }; throw error
        }
    }
    func inspectCheckout(operationID: UUID? = nil) async throws {
        guard !closed, !isInspecting, let engine, let checkoutOperation = checkoutOperation(id: operationID), checkoutOperation.phase == .unconfirmed,
              checkoutOperation.acknowledgedAt == nil else { throw CancellationError() }
        isInspecting = true; actionError = nil
        let task = Task { try await engine.inspectPullRequestCheckout(operationID: checkoutOperation.id) }; inspectionTask = task
        defer { inspectionTask = nil; isInspecting = false }
        do {
            let receipt = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            updateWorkspace(await engine.current())
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        } catch { if !closed { actionError = Self.message(error) }; throw error }
    }
    func cancelCheckout(operationID: UUID? = nil) async throws {
        guard !closed, let engine, let checkoutOperation = checkoutOperation(id: operationID), checkoutOperation.isWorking else { throw CancellationError() }
        let receipt = try await engine.cancelPullRequestCheckout(operationID: checkoutOperation.id)
        updateWorkspace(await engine.current())
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
    }
    func acknowledgeCheckout(operationID: UUID? = nil) async throws {
        guard !closed, !isInspecting, let engine, let checkoutOperation = checkoutOperation(id: operationID), checkoutOperation.phase == .unconfirmed,
              checkoutOperation.acknowledgedAt == nil else { throw CancellationError() }
        let receipt = try await engine.dispatch(.acknowledgePullRequestCheckout(operationID: checkoutOperation.id))
        updateWorkspace(await engine.current())
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
    }
    func discardCheckoutReview(_ id: UUID) async { await engine?.discardPullRequestCheckoutReview(reviewID: id) }
    func openCheckoutConversation(operationID: UUID? = nil) {
        guard let checkoutOperation = checkoutOperation(id: operationID), checkoutOperation.phase == .completed else { return }
        checkoutSupport?.open(checkoutOperation.targetThreadID)
    }
    private func checkoutOperation(id: UUID?) -> PullRequestCheckoutOperation? {
        if let id { return checkoutOperations.first { $0.id == id } }
        return checkoutOperation
    }
    func suspendForWorkspaceMutation() {
        readsSuspended = true; contextGeneration = UUID(); listGeneration = UUID(); detailGeneration = UUID(); reviewGeneration = UUID()
        isLoading = false; isLoadingList = false; isLoadingDetail = false; isPreparing = false; cancelReads(); postOperationTask?.cancel()
    }
    func waitForReads() async { for read in Array(ownedReads.values) { await read.drain.value } }
    func refreshAfterWorkspaceMutation() async { guard !closed else { return }; readsSuspended = false; await refresh() }

    private func rejectCheckout(mode: GitHubPullRequestCheckoutMode, plan: GitHubPullRequestCheckoutPlan?, excludingOperationID: UUID?) throws -> Never {
        if closed { throw CancellationError() }
        let message = checkoutSupport?.unavailableReason?(mode, plan, excludingOperationID) ?? String(localized: "Finish the current workspace action before reviewing this pull request checkout again.")
        actionError = message
        throw WorkspaceCommandError(message)
    }

    private func ownRead<Value: Sendable>(_ task: Task<Value, any Error>, id: UUID) {
        ownedReads[id] = .init(cancel: { task.cancel() }, drain: Task { _ = await task.result })
    }
    func cancelReads() { for read in ownedReads.values { read.cancel() } }
    func prepareForShutdown() {
        closed = true; contextGeneration = UUID(); listGeneration = UUID(); detailGeneration = UUID(); reviewGeneration = UUID()
        cancelReads(); inspectionTask?.cancel(); postOperationTask?.cancel()
    }
    func shutdown() async {
        prepareForShutdown()
        let reads = Array(ownedReads.values)
        for read in reads { await read.drain.value }
        _ = await acceptanceTask?.result; _ = await inspectionTask?.result; await postOperationTask?.value
    }
    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    private static func message(_ error: any Error) -> String {
        if let error = error as? GitHubPullRequestError { return error.localizedDescription }
        if let error = error as? GitHubPullRequestCheckoutError { return error.localizedDescription }
        if let error = error as? WorkspaceCommandError { return error.localizedDescription }
        if error is CancellationError { return String(localized: "Cancelled. Refresh to inspect the current pull request state.") }
        return String(localized: "The pull request operation could not finish. Refresh and check the current repository state.")
    }
}
