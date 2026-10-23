import Foundation

public enum PullRequestActionPhase: String, Codable, Sendable {
    case accepted, dispatching, succeeded, failed, unconfirmed
}

/// One original review identity, consumed before any remote mutation is dispatched.
public struct PullRequestActionOperation: Codable, Sendable, Equatable, Identifiable {
    public let projectID: UUID
    public let projectPath: String
    public let registeredWorkspacePath: String
    public let repositoryPath: String
    public let commonDirectoryPath: String
    public let sourceIncarnation: UUID
    public let sourceThreadID: UUID?
    public let effectID: UUID
    public let review: GitHubPullRequestActionReview
    public var phase: PullRequestActionPhase
    public var updatedAt: Date
    public var outcome: GitHubPullRequestActionOutcome?
    public var inspectedState: GitHubPullRequestActionState?
    public var inspectedAt: Date?
    public var acknowledgedAt: Date?
    public var error: String?
    public var id: UUID { review.id }
    public var scopePaths: [String] { [repositoryPath, commonDirectoryPath] }
    public var isWorking: Bool { phase == .accepted || phase == .dispatching }
    public var requiresAcknowledgment: Bool { phase == .unconfirmed && acknowledgedAt == nil }
    public var blocksAction: Bool { isWorking || requiresAcknowledgment }
    public static let failureMessage = "The pull request action did not complete. Review its current state; this intent will not be repeated."
    public static let unconfirmedMessage = "GitHub may already have applied this action. Inspect its current state and explicitly acknowledge the unknown outcome before reviewing another action."
    public init(projectID: UUID, projectPath: String, registeredWorkspacePath: String, repositoryPath: String,
                commonDirectoryPath: String, sourceIncarnation: UUID, sourceThreadID: UUID? = nil,
                effectID: UUID = UUID(), review: GitHubPullRequestActionReview, phase: PullRequestActionPhase = .accepted,
                updatedAt: Date? = nil, outcome: GitHubPullRequestActionOutcome? = nil,
                inspectedState: GitHubPullRequestActionState? = nil, inspectedAt: Date? = nil,
                acknowledgedAt: Date? = nil, error: String? = nil) {
        self.projectID = projectID; self.projectPath = projectPath; self.registeredWorkspacePath = registeredWorkspacePath
        self.repositoryPath = repositoryPath; self.commonDirectoryPath = commonDirectoryPath
        self.sourceIncarnation = sourceIncarnation; self.sourceThreadID = sourceThreadID
        self.effectID = effectID; self.review = review; self.phase = phase; self.updatedAt = updatedAt ?? review.reviewedAt
        self.outcome = outcome; self.inspectedState = inspectedState; self.inspectedAt = inspectedAt
        self.acknowledgedAt = acknowledgedAt; self.error = error
    }
    public func validate() throws {
        try review.validate()
        for path in [projectPath, registeredWorkspacePath, repositoryPath, commonDirectoryPath] { try CheckpointValidation.path(path) }
        guard id != effectID, id != projectID, effectID != projectID,
              updatedAt.timeIntervalSince1970.isFinite,
              (inspectedState == nil) == (inspectedAt == nil),
              inspectedAt.map({ $0.timeIntervalSince1970.isFinite && phase == .unconfirmed }) ?? (inspectedState == nil),
              acknowledgedAt.map({ $0.timeIntervalSince1970.isFinite && phase == .unconfirmed }) ?? true else {
            throw CoincideError("The pull request action has inconsistent ownership.")
        }
        if let inspectedState {
            try inspectedState.validate()
            guard phase == .unconfirmed, inspectedAt != nil, inspectedState.reference == review.state.reference else {
                throw CoincideError("The inspection belongs to a different pull request.")
            }
        }
        switch phase {
        case .accepted, .dispatching:
            guard outcome == nil, error == nil, inspectedState == nil, inspectedAt == nil, acknowledgedAt == nil else {
                throw CoincideError("A pending action contains premature completion evidence.")
            }
        case .succeeded:
            guard let outcome, outcome.action == review.action, error == nil, inspectedState == nil, inspectedAt == nil, acknowledgedAt == nil else {
                throw CoincideError("The pull request action has no matching result.")
            }
            guard GitHubValidation.text(outcome.message, maximum: 4_096, allowEmpty: false, multiline: true),
                  outcome.approvedRuns >= 0, outcome.approvedRuns <= 100 else { throw GitHubPullRequestActionError(.refused) }
            if let reference = outcome.revertReference {
                try reference.validate()
                guard review.action == .revert, reference.repository == review.state.reference.repository,
                      let url = outcome.revertURL, GitHubValidation.pullRequestURL(url, reference: reference) else { throw GitHubPullRequestActionError(.refused) }
            } else if outcome.revertURL != nil || review.action == .revert { throw GitHubPullRequestActionError(.refused) }
        case .failed:
            guard outcome == nil, error == Self.failureMessage, inspectedState == nil, inspectedAt == nil, acknowledgedAt == nil else { throw GitHubPullRequestActionError(.refused) }
        case .unconfirmed:
            guard outcome == nil, error == Self.unconfirmedMessage else { throw GitHubPullRequestActionError(.refused) }
        }
    }
}

extension WorkspaceSnapshot {
    public func pullRequestAction(_ id: UUID) -> PullRequestActionOperation? { pullRequestActions?.first { $0.id == id } }
    public func isPullRequestActionWorking(path: String) -> Bool {
        (pullRequestActions ?? []).contains { $0.isWorking && $0.scopePaths.contains { Self.checkpointRestorePathsOverlap(path, $0) } }
    }
    func validatePullRequestActionSource(_ operation: PullRequestActionOperation) throws {
        guard projects.contains(where: { $0.id == operation.projectID && $0.path.utf8.elementsEqual(operation.projectPath.utf8) && ($0.clone?.isReady ?? true) }),
              ownsPullRequestWorkspace(projectID: operation.projectID, workspacePath: operation.registeredWorkspacePath) else {
            throw WorkspaceCommandError("This action's project or registered checkout changed. Review it again.")
        }
    }
    func validatePullRequestActions() throws {
        let operations = pullRequestActions ?? []
        let identities = operations.flatMap { [$0.id, $0.effectID] }
        let reserved = Set(projects.map(\.id) + threads.map(\.id) +
            (pullRequestCreations ?? []).flatMap { [$0.id, $0.effectID] } +
            (pullRequestCheckouts ?? []).flatMap { [$0.id, $0.effectID] })
        guard Set(identities).count == identities.count, Set(identities).isDisjoint(with: reserved) else {
            throw CoincideError("Pull request action identities must be uniquely reserved.")
        }
        for operation in operations {
            try operation.validate()
            if operation.isWorking { try validatePullRequestActionSource(operation) }
        }
        let active = operations.filter(\.blocksAction)
        guard Set(active.map { $0.review.state.reference }).count == active.count else {
            throw CoincideError("Resolve the earlier action before another action on the same pull request.")
        }
    }
}

extension WorkspaceDecision {
    /// Remote state actions do not pause provider input or ordinary file editing.
    /// A live owned CLI still holds its folders against removal/rebinding.
    func guardPullRequestActions(_ command: WorkspaceCommand) throws {
        let working = snapshot.pullRequestActions?.filter(\.isWorking) ?? []
        func held(_ path: String) -> Bool { working.contains { $0.scopePaths.contains { WorkspaceSnapshot.checkpointRestorePathsOverlap(path, $0) } } }
        switch command {
        case .removeProject(let id, _), .cancelProjectClone(let id):
            guard !working.contains(where: { $0.projectID == id }),
                  !snapshot.projects.contains(where: { $0.id == id && held($0.path) }) else { throw WorkspaceCommandError("Wait for the pull request action to stop before removing its checkout.") }
        case .retryProjectClone(let id, let plan):
            guard !working.contains(where: { $0.projectID == id }), !held(plan.destinationPath), !held(plan.stagingPath) else { throw WorkspaceCommandError("Wait for the pull request action to stop before changing its checkout.") }
        case .removeProjectGroup(_, let projects, _):
            guard !projects.contains(where: { project in working.contains { $0.projectID == project.id } || held(project.path) }) else { throw WorkspaceCommandError("Wait for the pull request action to stop before removing this group.") }
        case .editThread(let id, let edit):
            guard let thread = snapshot.threads.first(where: { $0.id == id }) else { return }
            switch edit {
            case .workspacePath(let path):
                guard !held(thread.workspacePath), !held(path) else { throw WorkspaceCommandError("Wait for the pull request action to stop before changing its checkout.") }
            case .claudeWorkspace(let configuration):
                guard !held(thread.workspacePath), !held(configuration.registeredWorkspacePath) else { throw WorkspaceCommandError("Wait for the pull request action to stop before changing its checkout.") }
            case .piWorkspace(let configuration):
                guard !held(thread.workspacePath), !held(configuration.registeredWorkspacePath) else { throw WorkspaceCommandError("Wait for the pull request action to stop before changing its checkout.") }
            default: break
            }
        case .settleThread(let id, let path, _):
            guard !held(path), !snapshot.threads.contains(where: { $0.id == id && held($0.workspacePath) }) else { throw WorkspaceCommandError("Wait for the pull request action to stop before settling its checkout.") }
        case .workspaceLifecycle(.automaticallySettle(let proposal)):
            guard !held(proposal.workspacePath), !snapshot.threads.contains(where: { $0.id == proposal.threadID && held($0.workspacePath) }) else { throw WorkspaceCommandError("Wait for the pull request action to stop before settling its checkout.") }
        default: break
        }
    }
    mutating func acceptPullRequestAction(_ operation: PullRequestActionOperation) throws {
        try operation.validate(); try snapshot.validatePullRequestActionSource(operation)
        guard operation.phase == .accepted, snapshot.pullRequestAction(operation.id) == nil,
              !(snapshot.pullRequestActions ?? []).contains(where: { $0.blocksAction && $0.review.state.reference == operation.review.state.reference }),
              !operation.scopePaths.contains(where: { snapshot.isCheckpointRestoreLocked(path: $0) || snapshot.isPullRequestCreationLocked(path: $0) || snapshot.isPullRequestCheckoutLocked(path: $0) }) else {
            throw WorkspaceCommandError("Inspect and acknowledge the earlier pull request action before continuing.")
        }
        if snapshot.pullRequestActions == nil { snapshot.pullRequestActions = [] }
        snapshot.pullRequestActions!.append(operation)
        try snapshot.validatePullRequestActions()
        effects.append(.init(id: operation.effectID, request: .pullRequestAction(projectID: operation.projectID, operationID: operation.id, effectID: operation.effectID)))
    }
    mutating func dispatchPullRequestAction(projectID: UUID, operationID: UUID, incarnation: UUID, now: Date) throws {
        guard let index = snapshot.pullRequestActions?.firstIndex(where: { $0.id == operationID }),
              let operation = snapshot.pullRequestActions?[index], operation.phase == .accepted,
              operation.projectID == projectID, operation.sourceIncarnation == incarnation else { return }
        try snapshot.validatePullRequestActionSource(operation)
        snapshot.pullRequestActions?[index].phase = .dispatching; snapshot.pullRequestActions?[index].updatedAt = now
    }
    mutating func finishPullRequestAction(_ request: WorkspaceEffectRequest, result: EffectResult, incarnation: UUID, now: Date) {
        guard case .pullRequestAction(let projectID, let operationID, let effectID) = request,
              let index = snapshot.pullRequestActions?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.pullRequestActions?[index], operation.isWorking,
              operation.projectID == projectID, operation.effectID == effectID, operation.sourceIncarnation == incarnation else { return }
        switch result {
        case .pullRequestActionConfirmed(let outcome):
            guard operation.phase == .dispatching else { return }
            operation.phase = .succeeded; operation.outcome = outcome
            if (try? operation.validate()) == nil { operation.phase = .unconfirmed; operation.outcome = nil; operation.error = PullRequestActionOperation.unconfirmedMessage }
        case .failed:
            operation.phase = .failed; operation.error = PullRequestActionOperation.failureMessage
        case .cancelled, .stopped, .pullRequestActionUnconfirmed:
            operation.phase = operation.phase == .accepted ? .failed : .unconfirmed
            operation.error = operation.phase == .failed ? PullRequestActionOperation.failureMessage : PullRequestActionOperation.unconfirmedMessage
        default: return
        }
        operation.updatedAt = now; snapshot.pullRequestActions?[index] = operation
    }
    mutating func inspectPullRequestAction(operationID: UUID, state: GitHubPullRequestActionState, now: Date) throws {
        guard let index = snapshot.pullRequestActions?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.pullRequestActions?[index], operation.phase == .unconfirmed, operation.acknowledgedAt == nil,
              state.reference == operation.review.state.reference else { throw GitHubPullRequestActionError(.staleReview) }
        try state.validate()
        operation.inspectedState = state; operation.inspectedAt = now; operation.updatedAt = now
        try operation.validate(); snapshot.pullRequestActions?[index] = operation
    }
    mutating func acknowledgePullRequestAction(operationID: UUID, now: Date) throws {
        guard let index = snapshot.pullRequestActions?.firstIndex(where: { $0.id == operationID }),
              snapshot.pullRequestActions?[index].phase == .unconfirmed else { throw GitHubPullRequestActionError(.refused) }
        if snapshot.pullRequestActions?[index].acknowledgedAt == nil {
            snapshot.pullRequestActions?[index].acknowledgedAt = now; snapshot.pullRequestActions?[index].updatedAt = now
        }
    }
}
