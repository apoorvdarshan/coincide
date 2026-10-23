import CoincideCore
import Foundation
import Observation

struct RemotePullRequestTransport: Sendable {
    var bind: @Sendable (RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget
    var read: @Sendable (RemotePullRequestReadRequest) async throws -> RemotePullRequestReadResult
    var review: @Sendable (RemotePullRequestReviewRequest) async throws -> RemotePullRequestReview
    var discard: @Sendable (RemotePullRequestDiscardRequest) async throws -> RemotePullRequestDiscardResult
    static func live(_ client: RemoteEnvironmentClient) -> Self {
        .init(bind: { try await client.bindPullRequestWorkspace($0) }, read: { try await client.readPullRequests($0) },
            review: { try await client.reviewPullRequest($0) }, discard: { try await client.discardPullRequestReview($0) })
    }
}

private struct RemotePullRequestKey: Hashable { let environmentID: UUID, threadID: UUID; let path: Data }

@MainActor @Observable
final class RemotePullRequestStore {
    typealias Perform = @MainActor (RemoteEnvironmentCommand) async -> Bool
    private(set) var current: RemotePullRequestWorkspace?
    private(set) var errorMessage: String?
    private(set) var pendingWrites = 0
    private var failedDrafts: Set<String> = []
    @ObservationIgnored private let persistence: RemotePullRequestDraftPersistence
    @ObservationIgnored private var models: [RemotePullRequestKey: RemotePullRequestWorkspace] = [:]
    @ObservationIgnored private var selection = UUID()
    @ObservationIgnored private var clientIdentity: ObjectIdentifier?
    @ObservationIgnored private var writes: Task<Bool, Never>?
    @ObservationIgnored private var closed = false
    init(root: URL) { persistence = .init(root: root) }
    var persistenceFailed: Bool { !failedDrafts.isEmpty }
    var hasUnsavedDrafts: Bool { pendingWrites > 0 || persistenceFailed }
    var retainedDrafts: [RemotePullRequestWorkspace] { models.values.filter { $0.draft.fields.hasText }.sorted { $0.id < $1.id } }
    func review(id: UUID) -> RemotePullRequestReview? { models.values.flatMap { [$0.creation, $0.checkout].compactMap { $0 } }.first { $0.id == id } }

    func select(target: RemoteWorkspaceTarget?, client: RemoteEnvironmentClient?, snapshot: WorkspaceSnapshot, supported: Bool,
                canWrite: Bool, canMutate: Bool, perform: @escaping Perform, openConversation: @escaping @MainActor (UUID) -> Void) async {
        let identity = client.map(ObjectIdentifier.init)
        if identity != clientIdentity { disconnect(); clientIdentity = identity }
        await select(target: target, transport: client.map(RemotePullRequestTransport.live), snapshot: snapshot,
            supported: supported, canWrite: canWrite, canMutate: canMutate, perform: perform, openConversation: openConversation)
    }
    func select(target: RemoteWorkspaceTarget?, transport: RemotePullRequestTransport?, snapshot: WorkspaceSnapshot, supported: Bool,
                canWrite: Bool, canMutate: Bool, perform: @escaping Perform, openConversation: @escaping @MainActor (UUID) -> Void) async {
        guard !closed else { return }
        let owner = UUID(); selection = owner
        guard let target else { clearSelection(); return }
        let key = RemotePullRequestKey(environmentID: target.environmentID, threadID: target.threadID, path: Data(target.workspacePath.utf8))
        let model: RemotePullRequestWorkspace
        if let value = models[key] { model = value }
        else {
            do {
                let fields = try await persistence.load(target: target)
                guard selection == owner, !closed else { return }
                model = .init(target: target, draft: .init(fields)); models[key] = model
                failedDrafts.remove(model.id)
                model.draft.edited = { [weak self, weak model] in
                    guard let self, let model, !self.closed else { return }
                    model.draftChanged(); self.save(model)
                }
            } catch { failedDrafts.insert(key.environmentID.uuidString + ":" + key.threadID.uuidString + ":" + key.path.base64EncodedString()); errorMessage = "The saved pull request draft could not be read. Its existing file was preserved."; return }
        }
        if current !== model { current?.disconnect() }
        current = model
        model.update(target: target, transport: transport, snapshot: snapshot, supported: supported,
            canWrite: canWrite && !persistenceFailed, canMutate: canMutate && !persistenceFailed, perform: perform, openConversation: openConversation)
    }
    private func save(_ model: RemotePullRequestWorkspace) {
        let target = model.target, fields = model.draft.fields, previous = writes
        pendingWrites += 1
        let task = Task { [weak self, persistence] in
            defer { self?.pendingWrites -= 1 }
            _ = await previous?.value
            do { try await persistence.save(target: target, fields: fields); self?.failedDrafts.remove(model.id); return true }
            catch { self?.failedDrafts.insert(model.id); self?.errorMessage = "The pull request draft could not be saved on this Mac. Keep this window open and copy its text."; return false }
        }
        writes = task
    }
    func clearSelection() { selection = UUID(); current?.disconnect(); current = nil }
    func disconnect() { selection = UUID(); clientIdentity = nil; for model in models.values { model.disconnect() } }
    func shutdown() async {
        closed = true
        for model in models.values { model.draft.acceptingEdits = false }
        disconnect()
        for model in models.values { await model.drainReads() }
        _ = await writes?.value
    }
    func cancelShutdown() { closed = false; for model in models.values { model.draft.acceptingEdits = true } }
}

@MainActor @Observable
final class RemotePullRequestWorkspace: Identifiable {
    nonisolated let id: String
    private(set) var target: RemoteWorkspaceTarget
    let draft: RemotePullRequestCreateDraft
    private(set) var context: GitHubPullRequestContext?
    private(set) var page: GitHubPullRequestPage?
    private(set) var detail: GitHubPullRequestDetail?
    private(set) var selected: GitHubPullRequestReference?
    private(set) var creation: RemotePullRequestReview?
    private(set) var checkout: RemotePullRequestReview?
    private(set) var operation: PullRequestCreationOperation?
    private(set) var checkoutOperations: [PullRequestCheckoutOperation] = []
    private(set) var isLoading = false
    private(set) var isLoadingList = false
    private(set) var isLoadingDetail = false
    private(set) var isPreparing = false
    private(set) var isActing = false
    private(set) var contextError: String?
    private(set) var listError: String?
    private(set) var detailError: String?
    private(set) var actionError: String?
    private(set) var connected = false
    private(set) var supported = false
    private(set) var writesAllowed = false
    private(set) var mutationsAllowed = false
    var listState = GitHubPullRequestListState.open
    var query = ""
    var referenceText = ""
    @ObservationIgnored private var transport: RemotePullRequestTransport?
    @ObservationIgnored private var command: RemotePullRequestStore.Perform?
    @ObservationIgnored private var open: (@MainActor (UUID) -> Void)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var contextRead = UUID()
    @ObservationIgnored private var listRead = UUID()
    @ObservationIgnored private var detailRead = UUID()
    @ObservationIgnored private var reviewRead = UUID()
    @ObservationIgnored private var creationFields: RemotePullRequestDraftFields?
    private struct OwnedRead { let cancel: @Sendable () -> Void; let drain: Task<Void, Never> }
    @ObservationIgnored private var reads: [UUID: OwnedRead] = [:]
    init(target: RemoteWorkspaceTarget, draft: RemotePullRequestCreateDraft) {
        self.target = target; self.draft = draft
        id = target.environmentID.uuidString + ":" + target.threadID.uuidString + ":" + Data(target.workspacePath.utf8).base64EncodedString()
    }
    var creationReview: GitHubPullRequestCreateReview? { if case .creation(let value) = creation?.value { value } else { nil } }
    var checkoutReview: PullRequestCheckoutReview? { if case .checkout(let value) = checkout?.value { value } else { nil } }
    var isBusy: Bool { isActing || isPreparing || operation?.isWorking == true || checkoutOperations.contains(where: \.isWorking) }
    var canRead: Bool { connected && supported && transport != nil }
    var canCreate: Bool {
        canRead && writesAllowed && mutationsAllowed && !isBusy && operation?.locksSource != true &&
            !checkoutOperations.contains(where: \.retainsProject) && context?.existingPullRequest == nil &&
            (context?.readiness == .ready || context?.readiness == .defaultBranch)
    }
    func canCheckout(_ mode: GitHubPullRequestCheckoutMode) -> Bool {
        canRead && writesAllowed && !isBusy && context != nil && operation?.locksSource != true &&
            (mode == .worktree || mutationsAllowed)
    }
    var canAcceptCheckout: Bool {
        guard let review = checkoutReview else { return false }
        return canCheckout(review.plan.request.mode) && (review.plan.isReadOnly || review.plan.request.mode == .worktree || mutationsAllowed)
    }
    var unavailableMessage: String? {
        if !supported { return "Update CoincideEnvironment on the remote Mac to enable pull requests." }
        if !connected { return "Reconnect to read or act on this remote repository. Draft text stays on this Mac." }
        if !writesAllowed { return "Inspect the current unconfirmed remote request before starting another action." }
        if !mutationsAllowed { return "Finish work that owns this checkout before creating a pull request or switching its files. Separate worktree review remains available." }
        return nil
    }
    func update(target: RemoteWorkspaceTarget, transport: RemotePullRequestTransport?, snapshot: WorkspaceSnapshot,
                supported: Bool, canWrite: Bool, canMutate: Bool, perform: @escaping RemotePullRequestStore.Perform,
                openConversation: @escaping @MainActor (UUID) -> Void) {
        if !Self.sameCapture(self.target, target) { disconnect(); context = nil; page = nil; detail = nil }
        let rootID = target.rootID ?? (Self.sameCapture(self.target, target) ? self.target.rootID : nil)
        self.target = .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID,
            configuration: target.configuration, rootID: rootID)
        self.transport = transport; connected = transport != nil; self.supported = supported
        writesAllowed = canWrite; mutationsAllowed = canMutate; command = perform; open = openConversation
        operation = snapshot.pullRequestCreations?.last { $0.projectID == target.projectID && Self.samePath($0.registeredWorkspacePath, target.workspacePath) }
        checkoutOperations = snapshot.pullRequestCheckouts?.filter { $0.projectID == target.projectID && Self.samePath($0.review.registeredWorkspacePath, target.workspacePath) } ?? []
    }

    func refresh() async {
        guard canRead, let transport else { return }
        let owner = generation, requestID = UUID(); contextRead = requestID; isLoading = true; contextError = nil
        defer { if contextRead == requestID { isLoading = false } }
        let captured = target
        do {
            let bound = try await read { try await transport.bind(captured) }
            guard generation == owner, contextRead == requestID else { return }
            guard Self.sameCapture(bound, captured), bound.rootID != nil else { throw RemotePullRequestFailure(.invalidTarget) }
            let result = try await read { try await transport.read(.init(target: bound, query: .context)) }
            guard generation == owner, contextRead == requestID, Self.same(result.target, bound), case .context(let value) = result.value else { return }
            try value.validate(); guard Self.samePath(value.workspacePath, captured.workspacePath) else { throw RemotePullRequestFailure(.invalidTarget) }
            if context?.sourceFingerprint != value.sourceFingerprint { clearCreation(); clearCheckout() }
            if context?.repository != value.repository { page = nil; detail = nil; selected = nil }
            target = bound; context = value
            if draft.baseBranch.isEmpty { draft.baseBranch = value.defaultBranch }
            await loadList()
        } catch is CancellationError { }
        catch { if generation == owner, contextRead == requestID { contextError = Self.message(error) } }
    }
    func loadList() async {
        guard canRead, let transport, let repository = context?.repository else { return }
        let owner = generation, token = UUID(), captured = target; listRead = token; isLoadingList = true; listError = nil
        let query = GitHubPullRequestListQuery(state: listState, query: query.isEmpty ? nil : query, limit: 50)
        defer { if listRead == token { isLoadingList = false } }
        do {
            try query.validate()
            let result = try await read { try await transport.read(.init(target: captured, query: .list(query))) }
            guard generation == owner, listRead == token, Self.same(result.target, captured), case .page(let value) = result.value else { return }
            guard value.items.count <= query.limit, value.items.allSatisfy({ $0.reference.repository == repository }) else { throw RemotePullRequestFailure(.invalidRequest) }
            for item in value.items { try item.validate() }; page = value
        } catch is CancellationError { }
        catch { if generation == owner, listRead == token { listError = Self.message(error) } }
    }
    func select(_ reference: GitHubPullRequestReference) async {
        guard context?.repository == reference.repository else { return }
        selected = reference; await loadDetail(.detail(reference))
    }
    func resolve() async { await loadDetail(.resolve(referenceText)) }
    private func loadDetail(_ query: RemotePullRequestQuery) async {
        guard canRead, let transport, let repository = context?.repository else { return }
        let owner = generation, token = UUID(), captured = target; detailRead = token; isLoadingDetail = true; detailError = nil
        defer { if detailRead == token { isLoadingDetail = false } }
        do {
            let result = try await read { try await transport.read(.init(target: captured, query: query)) }
            guard generation == owner, detailRead == token, Self.same(result.target, captured), case .detail(let value) = result.value else { return }
            try value.validate(); guard value.summary.reference.repository == repository else { throw RemotePullRequestFailure(.invalidTarget) }
            if selected != value.summary.reference { clearCheckout() }
            selected = value.summary.reference; detail = value
        } catch is CancellationError { }
        catch { if generation == owner, detailRead == token { detailError = Self.message(error) } }
    }
    func prepareCreation() async {
        guard canCreate, let transport else { return }
        let fields = draft.fields, captured = target, owner = generation, token = UUID(); reviewRead = token; isPreparing = true; actionError = nil
        defer { if reviewRead == token { isPreparing = false } }
        do {
            try fields.validate()
            let value = try await read { try await transport.review(.init(target: captured, intent: .create(title: fields.title, body: fields.body,
                baseBranch: fields.baseBranch.isEmpty ? nil : fields.baseBranch, isDraft: fields.isDraft))) }
            try validate(value, target: captured)
            guard generation == owner, reviewRead == token, draft.fields.matches(fields), canRead else { await discard(value, transport: transport); return }
            guard case .creation(let review) = value.value, review.title.utf8.elementsEqual(fields.title.utf8),
                  review.body.utf8.elementsEqual(fields.body.utf8), review.isDraft == fields.isDraft,
                  Self.samePath(review.context.workspacePath, captured.workspacePath), review.context.repository == context?.repository,
                  fields.baseBranch.isEmpty || review.baseBranch.utf8.elementsEqual(fields.baseBranch.utf8) else { throw RemotePullRequestFailure(.staleReview) }
            creation = value; creationFields = fields
        } catch is CancellationError { }
        catch { if generation == owner, reviewRead == token { actionError = Self.message(error) } }
    }
    func create() async {
        guard canCreate, let review = creation, let fields = creationFields, draft.fields.matches(fields) else { return }
        if await execute(.begin(reviewID: review.id, digest: review.digest), target: review.target), creation?.id == review.id {
            creation = nil; creationFields = nil
        }
    }
    func prepareCheckout(reference: GitHubPullRequestReference, mode: GitHubPullRequestCheckoutMode, submodules: ProjectWorktreeSubmoduleMode) async {
        guard canCheckout(mode), let transport, context?.repository == reference.repository else { return }
        let captured = target, owner = generation, token = UUID(); reviewRead = token; isPreparing = true; actionError = nil
        defer { if reviewRead == token { isPreparing = false } }
        do {
            let value = try await read { try await transport.review(.init(target: captured, intent: .checkout(reference: reference, mode: mode,
                submodules: mode == .local ? .none : submodules, title: nil))) }
            try validate(value, target: captured)
            guard generation == owner, reviewRead == token, canRead else { await discard(value, transport: transport); return }
            guard case .checkout(let review) = value.value, review.projectID == captured.projectID,
                  Self.samePath(review.registeredWorkspacePath, captured.workspacePath), review.plan.pullRequest.reference == reference,
                  review.plan.request.mode == mode, review.plan.request.submodules == (mode == .local ? .none : submodules),
                  !review.reviewSetup else { throw RemotePullRequestFailure(.staleReview) }
            checkout = value
        } catch is CancellationError { }
        catch { if generation == owner, reviewRead == token { actionError = Self.message(error) } }
    }
    func beginCheckout() async {
        guard canAcceptCheckout, let review = checkout else { return }
        if await execute(.begin(reviewID: review.id, digest: review.digest), target: review.target), checkout?.id == review.id { checkout = nil }
    }
    func recoverCreation(id: UUID? = nil, acknowledge: Bool = false) async {
        guard let operation, id == nil || id == operation.id, operation.phase == .unconfirmed, operation.acknowledgedAt == nil else { return }
        _ = await execute(acknowledge ? .acknowledgeCreation(operationID: operation.id) : .inspectCreation(operationID: operation.id))
    }
    func recoverCheckout(_ id: UUID, acknowledge: Bool = false) async {
        guard let operation = checkoutOperations.first(where: { $0.id == id }), operation.phase == .unconfirmed, operation.acknowledgedAt == nil else { return }
        _ = await execute(acknowledge ? .acknowledgeCheckout(operationID: id) : .inspectCheckout(operationID: id))
    }
    func cancelCheckout(_ id: UUID) async {
        guard checkoutOperations.contains(where: { $0.id == id && $0.isWorking && !$0.cancelRequested }) else { return }
        _ = await execute(.cancelCheckout(operationID: id))
    }
    func openConversation(_ id: UUID) { if let operation = checkoutOperations.first(where: { $0.id == id && $0.phase == .completed }) { open?(operation.targetThreadID) } }
    private func execute(_ action: RemotePullRequestAction, target: RemoteWorkspaceTarget? = nil) async -> Bool {
        guard canRead, writesAllowed, !isActing, let command, let transport else { return false }
        isActing = true; defer { isActing = false }
        var captured = target ?? self.target
        if captured.rootID == nil, action.requiresBoundRoot {
            let requested = captured, owner = generation
            do {
                let bound = try await read { try await transport.bind(requested) }
                guard owner == generation, Self.sameCapture(bound, requested), bound.rootID != nil else { return false }
                self.target = bound; captured = bound
            } catch { actionError = Self.message(error); return false }
        }
        let result = await command(.pullRequest(target: captured, action: action))
        if !result { actionError = "The remote action was refused or its result is unconfirmed. Check the remote window's saved request before continuing." }
        return result
    }
    func draftChanged() { reviewRead = UUID(); isPreparing = false; clearCreation() }
    func clearCreation() { if let value = creation, let transport { Task { await discard(value, transport: transport) } }; creation = nil; creationFields = nil }
    func clearCheckout() { if let value = checkout, let transport { Task { await discard(value, transport: transport) } }; checkout = nil }
    private func discard(_ value: RemotePullRequestReview, transport: RemotePullRequestTransport) async {
        _ = try? await read { try await transport.discard(.init(target: value.target, reviewID: value.id, digest: value.digest)) }
    }
    private func validate(_ value: RemotePullRequestReview, target: RemoteWorkspaceTarget) throws {
        guard Self.same(value.target, target), value.id == value.value.id,
              value.digest == (try RemotePullRequestProtocol.digest(target: target, value: value.value)) else { throw RemotePullRequestFailure(.staleReview) }
        switch value.value { case .creation(let native): try native.validate(); case .checkout(let native): try native.validate() }
    }
    private func read<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard connected else { throw CancellationError() }
        let id = UUID(), task = Task { try await body() }
        reads[id] = .init(cancel: { task.cancel() }, drain: Task { _ = await task.result })
        defer { reads.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func disconnect() {
        generation = UUID(); contextRead = UUID(); listRead = UUID(); detailRead = UUID(); reviewRead = UUID()
        connected = false; writesAllowed = false; mutationsAllowed = false; transport = nil; command = nil; open = nil
        creation = nil; checkout = nil; creationFields = nil
        isLoading = false; isLoadingList = false; isLoadingDetail = false; isPreparing = false
        for value in reads.values { value.cancel() }
    }
    func drainReads() async { for value in Array(reads.values) { await value.drain.value } }
    private static func samePath(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    private static func sameCapture(_ a: RemoteWorkspaceTarget, _ b: RemoteWorkspaceTarget) -> Bool {
        a.environmentID == b.environmentID && a.projectID == b.projectID && a.threadID == b.threadID &&
            samePath(a.workspacePath, b.workspacePath) && same(a.configuration, b.configuration)
    }
    private static func same<T: Encodable>(_ a: T, _ b: T) -> Bool { (try? RemotePullRequestProtocol.payload(a)) == (try? RemotePullRequestProtocol.payload(b)) }
    private static func message(_ error: any Error) -> String {
        (error as? RemotePullRequestFailure)?.localizedDescription ?? (error as? RemoteEnvironmentClientError)?.localizedDescription ??
            (error as? GitHubPullRequestError)?.localizedDescription ?? "The remote pull request action could not finish. Its original request was not repeated."
    }
}
