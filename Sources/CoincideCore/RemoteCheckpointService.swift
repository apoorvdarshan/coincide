import Foundation

struct RemoteCheckpointScope: Codable, Sendable {
    let mutatingPaths: [String]
    let coordinationPaths: [String]
}
struct RemoteCheckpointPreparation: Codable, Sendable {
    enum Action: Codable, Sendable {
        case restore(RunCheckpointRestoreReview, digest: String)
        case inspect(RunCheckpointRestoreOperation, GitCheckpointRestoreInspection)
        case acknowledge(RunCheckpointRestoreOperation)
        case retry(runID: UUID, attempt: ThreadRunCheckpointAttempt)
        case proceed(runID: UUID, attempt: ThreadRunCheckpointAttempt)
    }
    let target: RemoteWorkspaceTarget
    let incarnation: UUID
    let policy: RunCheckpointPolicy
    let action: Action
    var allowsLockedTarget: Bool { if case .restore = action { false } else { true } }
    var requiresBoundRoot: Bool { if case .acknowledge = action { false } else { true } }
    var scope: RemoteCheckpointScope {
        switch action {
        case .restore(let review, _):
            return .init(mutatingPaths: [review.gitReview.currentPlan.repositoryPath],
                         coordinationPaths: [review.gitReview.currentPlan.commonDirectoryPath])
        case .retry(_, let attempt), .proceed(_, let attempt):
            return .init(mutatingPaths: [target.workspacePath],
                         coordinationPaths: attempt.plan.map { [$0.repositoryPath, $0.commonDirectoryPath] } ?? [])
        default: return .init(mutatingPaths: [], coordinationPaths: [])
        }
    }
}
enum RemoteCheckpointAdmission {
    static func commands(_ request: RemoteEnvironmentCommandRequest, preparation: RemoteEnvironmentPreparation,
                         snapshot: WorkspaceSnapshot) throws -> [EngineCommand] {
        guard case .checkpoint(let target, let action) = request.command, case .checkpoint(let prepared) = preparation,
              target.environmentID == request.environmentID,
              try RemoteCheckpointProtocol.payload(target) == RemoteCheckpointProtocol.payload(prepared.target),
              !action.requiresBoundRoot || target.rootID != nil,
              let thread = snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              !thread.isArchived, thread.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              thread.effectiveCheckpointPolicy == prepared.policy,
              try RemoteCheckpointProtocol.payload(ProviderConfiguration(thread: thread)) == RemoteCheckpointProtocol.payload(target.configuration) else { throw RemoteEnvironmentAdmission.stale() }
        func operation(_ expected: RunCheckpointRestoreOperation) throws {
            guard expected.review.threadID == thread.id, expected.review.projectID == thread.projectID,
                  expected.review.workspacePath.utf8.elementsEqual(thread.workspacePath.utf8),
                  let current = snapshot.checkpointRestoreOperation(expected.id),
                  try RemoteCheckpointProtocol.payload(current) == RemoteCheckpointProtocol.payload(expected) else { throw RemoteEnvironmentAdmission.stale() }
        }
        switch (action, prepared.action) {
        case (.beginRestore(let id, let digest), .restore(let review, let savedDigest)):
            guard id == review.id, digest == savedDigest, review.threadID == thread.id, review.projectID == thread.projectID,
                  review.sourceIncarnation == prepared.incarnation, review.workspacePath.utf8.elementsEqual(thread.workspacePath.utf8) else { throw RemoteEnvironmentAdmission.stale() }
            return [.checkpointRestoreAccepted(review: review)]
        case (.inspectRestore(let id), .inspect(let expected, let result)):
            try operation(expected); guard id == expected.id else { throw RemoteEnvironmentAdmission.stale() }
            return [.checkpointRestoreInspected(operationID: id, incarnation: prepared.incarnation, result: result)]
        case (.acknowledgeRestore(let id), .acknowledge(let expected)):
            try operation(expected); guard id == expected.id else { throw RemoteEnvironmentAdmission.stale() }
            return [.client(.acknowledgeCheckpointRestore(operationID: id))]
        case (.retryPostRun(let runID, let attemptID), .retry(let capturedRun, let attempt)),
             (.continuePostRun(let runID, let attemptID), .proceed(let capturedRun, let attempt)):
            guard runID == capturedRun, attemptID == attempt.id, let held = thread.heldPostRunCheckpoint,
                  held.runID == runID, try RemoteCheckpointProtocol.payload(held.attempt) == RemoteCheckpointProtocol.payload(attempt) else { throw RemoteEnvironmentAdmission.stale() }
            if case .retryPostRun = action { return [.client(.retryPostRunCheckpoint(threadID: thread.id, runID: runID, expectedAttemptID: attemptID))] }
            return [.client(.continueAfterPostRunCheckpoint(threadID: thread.id, runID: runID, expectedAttemptID: attemptID))]
        default: throw RemoteEnvironmentAdmission.stale()
        }
    }
}

actor RemoteCheckpointService {
    private let environmentID: UUID
    private let engine: WorkspaceEngine
    private let workspace: RemoteWorkspaceService
    private var closing = false
    init(environmentID: UUID, engine: WorkspaceEngine, workspace: RemoteWorkspaceService) {
        self.environmentID = environmentID; self.engine = engine; self.workspace = workspace
    }
    private func validate(_ target: RemoteWorkspaceTarget, allowLocked: Bool, requireRoot: Bool = true) async throws {
        guard !closing, target.environmentID == environmentID else { throw RemoteCheckpointFailure(.invalidTarget) }
        try await workspace.validateCheckpointTarget(target, allowLocked: allowLocked, requireRoot: requireRoot)
        guard !closing else { throw RemoteCheckpointFailure(.unavailable) }
    }
    func read(_ request: RemoteCheckpointReadRequest) async throws -> RemoteCheckpointReadResult {
        do {
            try await validate(request.target, allowLocked: true)
            let value = try await engine.readRemoteCheckpoint(request)
            try await validate(request.target, allowLocked: true)
            return .init(target: request.target, value: value)
        } catch { throw Self.safe(error) }
    }
    func review(_ request: RemoteCheckpointReviewRequest) async throws -> RemoteCheckpointReview {
        do {
            try await validate(request.target, allowLocked: false)
            let value = try await engine.reviewRemoteCheckpoint(request)
            do {
                try await validate(request.target, allowLocked: false)
                try await workspace.admitCheckpointScope(.init(mutatingPaths: [value.value.gitReview.currentPlan.repositoryPath],
                    coordinationPaths: [value.value.gitReview.currentPlan.commonDirectoryPath]))
                guard !closing else { throw RemoteCheckpointFailure(.unavailable) }
            }
            catch { _ = await engine.discardRemoteCheckpointReview(.init(target: value.target, reviewID: value.id, digest: value.digest)); throw error }
            return value
        } catch { throw Self.safe(error) }
    }
    func discard(_ request: RemoteCheckpointDiscardRequest) async throws -> RemoteCheckpointDiscardResult {
        guard !closing, request.target.environmentID == environmentID else { throw RemoteCheckpointFailure(.invalidTarget) }
        return .init(request: request, discarded: await engine.discardRemoteCheckpointReview(request))
    }
    func prepare(_ command: RemoteEnvironmentCommand) async throws -> RemoteEnvironmentPreparation {
        guard case .checkpoint(let target, let action) = command else { throw RemoteCheckpointFailure(.invalidRequest) }
        let locked: Bool
        if case .beginRestore = action { locked = false } else { locked = true }
        do {
            try await validate(target, allowLocked: locked, requireRoot: action.requiresBoundRoot)
            let prepared = try await engine.prepareRemoteCheckpoint(command)
            try await validate(target, allowLocked: locked, requireRoot: action.requiresBoundRoot)
            return prepared
        } catch { throw Self.safe(error) }
    }
    func close() async { closing = true; await engine.closeRemoteCheckpoints() }
    private static func safe(_ error: Error) -> RemoteCheckpointFailure {
        if let error = error as? RemoteCheckpointFailure { return error }
        if let error = error as? RemoteWorkspaceFailure {
            switch error.kind { case .busy: return .init(.busy); case .limitExceeded: return .init(.limitExceeded)
            case .unavailable, .interrupted: return .init(.unavailable); default: return .init(.invalidTarget) }
        }
        if let error = error as? GitCheckpointRestoreError {
            switch error.kind { case .staleReview, .invalidReview: return .init(.staleReview)
            case .ownershipLost: return .init(.invalidTarget); case .outputLimit: return .init(.limitExceeded)
            default: return .init(.operationFailed) }
        }
        if let error = error as? GitCheckpointError {
            switch error.kind { case .ownershipLost: return .init(.invalidTarget)
            case .configurationChanged: return .init(.staleReview); case .outputLimit: return .init(.limitExceeded)
            default: return .init(.operationFailed) }
        }
        if error is CancellationError { return .init(.unavailable) }
        return .init(.operationFailed)
    }
}
