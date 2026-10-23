import Foundation

/// Host-derived paths, never accepted from an RPC request. Recovery actions do
/// not acquire a new writer lease or repeat a native mutation.
struct RemotePullRequestScope: Codable, Sendable {
    let mutatingPaths: [String]
    let coordinationPaths: [String]
}

struct RemotePullRequestPreparation: Codable, Sendable {
    enum Action: Codable, Sendable {
        case creation(PullRequestCreationOperation, digest: String)
        case checkout(PullRequestCheckoutOperation, digest: String)
        case inspectCreation(PullRequestCreationOperation, GitHubPullRequestCreateReconciliation)
        case inspectCheckout(PullRequestCheckoutOperation, GitHubPullRequestCheckoutInspection)
        case acknowledgeCreation(PullRequestCreationOperation)
        case acknowledgeCheckout(PullRequestCheckoutOperation)
        case cancelCheckout(PullRequestCheckoutOperation)
    }
    let target: RemoteWorkspaceTarget
    let incarnation: UUID
    let action: Action
    var allowsLockedTarget: Bool {
        switch action { case .creation, .checkout: false; default: true }
    }
    var requiresBoundRoot: Bool {
        switch action { case .creation, .checkout, .inspectCreation, .inspectCheckout: true; default: false }
    }
    var scope: RemotePullRequestScope {
        switch action {
        case .creation(let operation, _):
            return .init(mutatingPaths: operation.scopePaths, coordinationPaths: operation.scopePaths)
        case .checkout(let operation, _):
            return .init(mutatingPaths: operation.affectedWorkspacePaths, coordinationPaths: operation.coordinationPaths)
        default: return .init(mutatingPaths: [], coordinationPaths: [])
        }
    }
}

extension RemoteEnvironmentAdmission {
    static func pullRequestCommands(_ request: RemoteEnvironmentCommandRequest, preparation: RemoteEnvironmentPreparation,
                                    snapshot: WorkspaceSnapshot) throws -> [EngineCommand] {
        guard case .pullRequest(let target, let action) = request.command, case .pullRequest(let prepared) = preparation,
              target.environmentID == request.environmentID,
              try RemotePullRequestProtocol.payload(target) == RemotePullRequestProtocol.payload(prepared.target),
              (!action.requiresBoundRoot || target.rootID != nil), let thread = snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              !thread.isArchived, thread.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              try RemotePullRequestProtocol.payload(ProviderConfiguration(thread: thread)) == RemotePullRequestProtocol.payload(target.configuration) else { throw stale() }
        func creation(_ operation: PullRequestCreationOperation) throws {
            guard operation.projectID == target.projectID, operation.registeredWorkspacePath.utf8.elementsEqual(target.workspacePath.utf8),
                  let current = snapshot.pullRequestCreation(operation.id),
                  try RemotePullRequestProtocol.payload(current) == RemotePullRequestProtocol.payload(operation) else { throw stale() }
        }
        func checkout(_ operation: PullRequestCheckoutOperation) throws {
            guard operation.projectID == target.projectID, operation.review.registeredWorkspacePath.utf8.elementsEqual(target.workspacePath.utf8),
                  let current = snapshot.pullRequestCheckout(operation.id),
                  try RemotePullRequestProtocol.payload(current) == RemotePullRequestProtocol.payload(operation) else { throw stale() }
        }
        switch (action, prepared.action) {
        case (.begin(let id, let digest), .creation(let operation, let savedDigest)):
            guard id == operation.id, digest == savedDigest, operation.projectID == target.projectID,
                  operation.registeredWorkspacePath.utf8.elementsEqual(target.workspacePath.utf8), operation.sourceIncarnation == prepared.incarnation else { throw stale() }
            return [.pullRequestCreationAccepted(operation)]
        case (.begin(let id, let digest), .checkout(let operation, let savedDigest)):
            guard id == operation.id, digest == savedDigest, operation.projectID == target.projectID,
                  operation.review.registeredWorkspacePath.utf8.elementsEqual(target.workspacePath.utf8),
                  operation.review.sourceIncarnation == prepared.incarnation, !operation.review.reviewSetup else { throw stale() }
            return [.pullRequestCheckoutAccepted(operation)]
        case (.inspectCreation(let id), .inspectCreation(let operation, let result)):
            try creation(operation); guard id == operation.id else { throw stale() }
            return [.pullRequestCreationReconciled(operationID: id, incarnation: prepared.incarnation, result: result)]
        case (.inspectCheckout(let id), .inspectCheckout(let operation, let result)):
            try checkout(operation); guard id == operation.id else { throw stale() }
            return [.pullRequestCheckoutInspected(operationID: id, incarnation: prepared.incarnation, result: result)]
        case (.acknowledgeCreation(let id), .acknowledgeCreation(let operation)):
            try creation(operation); guard id == operation.id else { throw stale() }
            return [.client(.acknowledgePullRequestCreation(operationID: id))]
        case (.acknowledgeCheckout(let id), .acknowledgeCheckout(let operation)):
            try checkout(operation); guard id == operation.id else { throw stale() }
            return [.client(.acknowledgePullRequestCheckout(operationID: id))]
        case (.cancelCheckout(let id), .cancelCheckout(let operation)):
            try checkout(operation); guard id == operation.id else { throw stale() }
            return [.pullRequestCheckoutCancel(operationID: id)]
        default: throw stale()
        }
    }
}

/// Browser and review work is tracked by the Engine, so project removal and
/// owned-host shutdown cancel and join native reads. Only the closed command
/// adapter can turn a cached review into a durable native effect.
actor RemotePullRequestService {
    private let environmentID: UUID
    private let engine: WorkspaceEngine
    private let workspace: RemoteWorkspaceService
    private var closing = false
    init(environmentID: UUID, engine: WorkspaceEngine, workspace: RemoteWorkspaceService) {
        self.environmentID = environmentID; self.engine = engine; self.workspace = workspace
    }
    private func validate(_ target: RemoteWorkspaceTarget, allowLocked: Bool = false, requireRoot: Bool = true) async throws {
        guard !closing, target.environmentID == environmentID, !requireRoot || target.rootID != nil else { throw RemotePullRequestFailure(.invalidTarget) }
        try await workspace.validatePullRequestTarget(target, allowLocked: allowLocked, requireRoot: requireRoot)
        guard !closing else { throw RemotePullRequestFailure(.unavailable) }
    }
    func read(_ request: RemotePullRequestReadRequest) async throws -> RemotePullRequestReadResult {
        do {
            try await validate(request.target, allowLocked: true)
            let value = try await engine.readRemotePullRequest(request)
            try await validate(request.target, allowLocked: true)
            return .init(target: request.target, value: value)
        } catch { throw Self.safe(error) }
    }
    func review(_ request: RemotePullRequestReviewRequest) async throws -> RemotePullRequestReview {
        do {
            try await validate(request.target)
            let busy = await workspace.busyPullRequestPaths()
            let value = try await engine.reviewRemotePullRequest(request, busyWorktreePaths: busy)
            do { try await validate(request.target) }
            catch { await engine.discardRemotePullRequestReview(.init(target: value.target, reviewID: value.id, digest: value.digest)); throw error }
            return value
        } catch { throw Self.safe(error) }
    }
    func discard(_ request: RemotePullRequestDiscardRequest) async throws -> RemotePullRequestDiscardResult {
        guard !closing, request.target.environmentID == environmentID else { throw RemotePullRequestFailure(.invalidTarget) }
        return .init(request: request, discarded: await engine.discardRemotePullRequestReview(request))
    }
    func prepare(_ command: RemoteEnvironmentCommand) async throws -> RemoteEnvironmentPreparation {
        guard case .pullRequest(let target, let action) = command else { throw RemotePullRequestFailure(.invalidRequest) }
        do {
            let allowLocked: Bool
            if case .begin = action { allowLocked = false } else { allowLocked = true }
            try await validate(target, allowLocked: allowLocked, requireRoot: action.requiresBoundRoot)
            let prepared = try await engine.prepareRemotePullRequest(command)
            try await validate(target, allowLocked: allowLocked, requireRoot: action.requiresBoundRoot)
            return prepared
        } catch { throw Self.safe(error) }
    }
    func close() async { closing = true; await engine.closeRemotePullRequests() }
    private static func safe(_ error: Error) -> RemotePullRequestFailure {
        if let error = error as? RemotePullRequestFailure { return error }
        if let error = error as? GitHubPullRequestError {
            switch error.kind {
            case .missingCLI: return .init(.missingCLI)
            case .unauthenticated: return .init(.unauthenticated)
            case .accessDenied: return .init(.accessDenied)
            case .rateLimited: return .init(.rateLimited)
            case .staleReview: return .init(.staleReview)
            case .invalidRequest: return .init(.invalidRequest)
            default: return .init(.operationFailed)
            }
        }
        if let error = error as? GitHubPullRequestCheckoutError {
            switch error.kind {
            case .staleReview: return .init(.staleReview)
            case .invalidRequest: return .init(.invalidRequest)
            case .outputLimit: return .init(.limitExceeded)
            case .dirtyCheckout, .branchInUse: return .init(.busy)
            default: return .init(.operationFailed)
            }
        }
        if let error = error as? RemoteWorkspaceFailure {
            switch error.kind {
            case .busy: return .init(.busy)
            case .limitExceeded: return .init(.limitExceeded)
            case .unavailable, .interrupted: return .init(.unavailable)
            default: return .init(.invalidTarget)
            }
        }
        if error is CancellationError { return .init(.unavailable) }
        return .init(.operationFailed)
    }
}
