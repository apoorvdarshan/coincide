import CoincideCore
import Foundation
import Observation

/// Shared by checkout path, rather than by the sheet or current selection.
/// Reads are replaceable; creation belongs to the durable workspace engine.
@MainActor @Observable
final class PullRequestStore {
    let path: String
    private(set) var context: GitHubPullRequestContext?
    private(set) var page: GitHubPullRequestPage?
    private(set) var selected: GitHubPullRequestReference?
    private(set) var detail: GitHubPullRequestDetail?
    private(set) var operation: PullRequestCreationOperation?
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
        guard !isBusy, operation?.locksSource != true, let context,
              context.existingPullRequest == nil, canMutate() else { return false }
        return context.readiness == .ready || context.readiness == .defaultBranch
    }
    var isMutating: Bool { isAccepting || operation?.isWorking == true }
    var mutationPaths: [String] {
        if let acceptingReview { return [acceptingReview.context.repositoryPath, acceptingReview.context.commonDirectoryPath] }
        return operation?.isWorking == true ? operation!.scopePaths : []
    }

    private let session: any GitHubPullRequestSession
    private let engine: WorkspaceEngine?
    private let owner: @MainActor () -> UUID?
    private let canRead: @MainActor () -> Bool
    private let canMutate: @MainActor () -> Bool
    private let updateWorkspace: @MainActor (WorkspaceUpdate) -> Void
    private var closed = false
    private var contextGeneration = UUID()
    private var listGeneration = UUID()
    private var detailGeneration = UUID()
    private var reviewGeneration = UUID()
    private var contextTask: Task<GitHubPullRequestContext, any Error>?
    private var listTask: Task<GitHubPullRequestPage, any Error>?
    private var detailTask: Task<GitHubPullRequestDetail, any Error>?
    private var reviewTask: Task<GitHubPullRequestCreateReview, any Error>?
    private var acceptanceTask: Task<WorkspaceCommandReceipt, any Error>?
    private var acceptingReview: GitHubPullRequestCreateReview?
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
         updateWorkspace: @escaping @MainActor (WorkspaceUpdate) -> Void) {
        self.path = Self.canonical(path); self.session = session; self.engine = engine
        self.owner = owner; self.canRead = canRead; self.canMutate = canMutate; self.updateWorkspace = updateWorkspace
    }

    func apply(_ snapshot: WorkspaceSnapshot) {
        let previous = operation
        let projectID = owner()
        operation = snapshot.pullRequestCreations?.last {
            $0.projectID == projectID && Self.canonical($0.review.context.workspacePath) == path
        }
        guard !closed, let operation, operation.id != previous?.id || operation.phase != previous?.phase else { return }
        switch operation.result {
        case .created(let result), .openedExisting(let result):
            selected = result.summary.reference; detail = result; detailError = nil
            if !operation.isWorking {
                postOperationTask?.cancel()
                postOperationTask = Task { [weak self] in await self?.refresh() }
            }
        case nil: break
        }
    }

    func refresh() async {
        guard !closed, canRead() else { return }
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
        guard !closed, canRead(), let repository = context?.repository else { return }
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
        guard !closed, canRead(), context?.repository == reference.repository else { return }
        selected = reference
        await readDetail { try await $0.detail(reference) }
    }
    func resolve(_ reference: String) async {
        guard !closed, canRead(), context != nil else { return }
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
        guard !closed, !isBusy, operation?.locksSource != true, canMutate(), let engine, let projectID = owner() else { throw CancellationError() }
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
        guard !closed, !isAccepting, canMutate(), let engine, let projectID = owner(),
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
        if let error = error as? WorkspaceCommandError { return error.localizedDescription }
        if error is CancellationError { return String(localized: "Cancelled. Refresh to inspect the current pull request state.") }
        return String(localized: "The pull request operation could not finish. Refresh and check the current repository state.")
    }
}
