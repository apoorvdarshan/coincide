import Foundation

public enum PullRequestCreationPhase: String, Codable, Sendable {
    case accepted, dispatching, created, openedExisting, failed, unconfirmed
}

/// One captured checkout and one non-replayed remote creation intent.
public struct PullRequestCreationOperation: Codable, Sendable, Equatable, Identifiable {
    public let projectID: UUID
    public let projectPath: String
    public let registeredWorkspacePath: String
    public let sourceIncarnation: UUID
    public let effectID: UUID
    public let review: GitHubPullRequestCreateReview
    public var phase: PullRequestCreationPhase
    public var updatedAt: Date
    public var result: GitHubPullRequestCreateOutcome?
    public var error: String?
    public var acknowledgedAt: Date?
    public var id: UUID { review.id }
    public var workspacePath: String { review.context.workspacePath }
    public var scopePaths: [String] { [review.context.repositoryPath, review.context.commonDirectoryPath] }
    public var isWorking: Bool { phase == .accepted || phase == .dispatching }
    public var locksSource: Bool { isWorking || (phase == .unconfirmed && acknowledgedAt == nil) }
    public static let failureMessage = "Pull request creation did not complete. No request was replayed. Refresh the checkout and review again."
    public static let unconfirmedMessage = "The pull request may have been created. Refresh its exact GitHub branch before continuing; creation was not repeated."
    public static let notFoundMessage = "No matching pull request was found. This does not prove the request never reached GitHub. Acknowledge this outcome explicitly before creating another request."
    public init(projectID: UUID, projectPath: String, sourceIncarnation: UUID, effectID: UUID = UUID(),
                review: GitHubPullRequestCreateReview, phase: PullRequestCreationPhase = .accepted,
                registeredWorkspacePath: String? = nil, updatedAt: Date? = nil, result: GitHubPullRequestCreateOutcome? = nil, error: String? = nil, acknowledgedAt: Date? = nil) {
        self.projectID = projectID; self.projectPath = projectPath; self.sourceIncarnation = sourceIncarnation
        self.registeredWorkspacePath = registeredWorkspacePath ?? review.context.workspacePath
        self.effectID = effectID; self.review = review; self.phase = phase; self.updatedAt = updatedAt ?? review.reviewedAt
        self.result = result; self.error = error; self.acknowledgedAt = acknowledgedAt
    }
    public func validate() throws {
        try review.validate(); try CheckpointValidation.path(projectPath); try CheckpointValidation.path(registeredWorkspacePath)
        guard id != effectID, id != projectID, effectID != projectID, updatedAt.timeIntervalSince1970.isFinite,
              acknowledgedAt.map({ phase == .unconfirmed && $0.timeIntervalSince1970.isFinite }) ?? true else { throw CoincideError("The pull request creation has inconsistent ownership.") }
        switch phase {
        case .accepted, .dispatching:
            guard result == nil, error == nil, acknowledgedAt == nil else { throw CoincideError("A pending pull request contains premature completion evidence.") }
        case .created:
            guard case .created(let detail) = result, error == nil, acknowledgedAt == nil else { throw CoincideError("The created pull request has no matching result.") }
            try validateResult(detail, requiresReviewedBase: true)
        case .openedExisting:
            guard case .openedExisting(let detail) = result, error == nil, acknowledgedAt == nil else { throw CoincideError("The existing pull request has no matching result.") }
            try validateResult(detail, requiresReviewedBase: false)
        case .failed:
            guard result == nil, error == Self.failureMessage, acknowledgedAt == nil else { throw CoincideError("The failed pull request lost its outcome.") }
        case .unconfirmed:
            guard result == nil, error == Self.unconfirmedMessage || error == Self.notFoundMessage else { throw CoincideError("The uncertain pull request lost its warning.") }
        }
    }
    func validateResult(_ detail: GitHubPullRequestDetail, requiresReviewedBase: Bool) throws {
        try detail.validate()
        let value = detail.summary, context = review.context
        guard value.reference.repository == context.repository, value.headRepository == context.headRepository,
              value.headBranch == (context.upstream?.branch ?? context.branch), value.headCommit == context.headCommit,
              !requiresReviewedBase || (value.baseBranch == review.baseBranch && value.baseCommit == review.baseCommit) else { throw CoincideError("The pull request result does not match its reviewed repository and commit.") }
    }
}

extension WorkspaceSnapshot {
    public func pullRequestCreation(_ id: UUID) -> PullRequestCreationOperation? { pullRequestCreations?.first { $0.id == id } }
    public func isPullRequestCreationLocked(path: String, excludingOperationID: UUID? = nil) -> Bool {
        (pullRequestCreations ?? []).contains { operation in
            operation.id != excludingOperationID && operation.locksSource && operation.scopePaths.contains { Self.checkpointRestorePathsOverlap(path, $0) }
        }
    }
    public func isPullRequestCreationLocked(threadID: UUID, excludingOperationID: UUID? = nil) -> Bool {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return false }
        if (pullRequestCreations ?? []).contains(where: { $0.id != excludingOperationID && $0.projectID == thread.projectID && $0.locksSource }) { return true }
        return thread.pullRequestCreationScopePaths.contains { isPullRequestCreationLocked(path: $0, excludingOperationID: excludingOperationID) }
    }
    func ownsPullRequestWorkspace(projectID: UUID, workspacePath: String) -> Bool {
        projects.contains { $0.id == projectID && ($0.path == workspacePath || threads.contains {
            $0.projectID == projectID && $0.workspacePath == workspacePath && workspaceReady(for: $0)
        }) }
    }
    func validatePullRequestCreationSource(_ operation: PullRequestCreationOperation) throws {
        try operation.validate()
        guard projects.contains(where: { $0.id == operation.projectID && $0.path == operation.projectPath && ($0.clone?.isReady ?? true) }),
              ownsPullRequestWorkspace(projectID: operation.projectID, workspacePath: operation.registeredWorkspacePath) else {
            throw WorkspaceCommandError("This pull request's project or registered checkout changed. Review it again.")
        }
    }
    func validatePullRequestCreations() throws {
        let operations = pullRequestCreations ?? []
        let identities = operations.flatMap { [$0.id, $0.effectID] }
        var reserved = pullRequestCheckoutReservedIDs.union(Set(projects.map(\.id) + threads.map(\.id) + (checkpointRestoreOperations ?? []).map(\.id) +
            (conversationHistoryOperations ?? []).flatMap { [$0.id] + ($0.review.targetThreadID.map { [$0] } ?? []) + ($0.review.files.map { [$0.id] } ?? []) }))
        for project in projects { if let clone = project.clone { reserved.formUnion((clone.previousPlans + [clone.plan]).map(\.id)) } }
        for thread in threads {
            reserved.formUnion(thread.queuedTurns.map(\.id)); if let active = thread.activeRun { reserved.insert(active.id) }
            for record in thread.runHistory ?? [] {
                reserved.insert(record.id)
                if let checkpoints = record.checkpoints { reserved.formUnion(([checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])).map(\.id)) }
            }
            if let preparation = thread.workspacePreparation {
                reserved.formUnion(preparation.previousAttempts.map { $0.request.id } + [preparation.id])
                for script in preparation.previousAttempts.compactMap(\.setup) + (preparation.setup.map { [$0] } ?? []) { reserved.formUnion(script.previousPlans.map(\.id) + [script.id]) }
            }
            if let settlement = thread.settlement { reserved.insert(settlement.id); if let script = settlement.script { reserved.formUnion(script.previousPlans.map(\.id) + [script.id]) } }
        }
        guard Set(identities).count == identities.count, Set(identities).isDisjoint(with: reserved) else { throw CoincideError("Pull request creation identities must be uniquely reserved.") }
        for operation in operations {
            try operation.validate()
            if operation.locksSource { try validatePullRequestCreationSource(operation) }
        }
        // Pure persisted-path validation. Live canonical ownership is rechecked by the engine.
        let locked = operations.filter(\.locksSource)
        for (index, operation) in locked.enumerated() {
            guard !locked.dropFirst(index + 1).contains(where: { other in operation.scopePaths.contains { path in other.scopePaths.contains { Self.pullRequestPersistedPathsOverlap(path, $0) } } }) else {
                throw CoincideError("Pending pull request creations cannot share checkout or Git metadata ownership.")
            }
        }
    }
    private static func pullRequestPersistedPathsOverlap(_ first: String, _ second: String) -> Bool {
        first == second || first == "/" || second == "/" || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }
}

extension CodingThread {
    var hasPullRequestCreationWork: Bool {
        if isBusy || !queuedTurns.isEmpty || !runtimeRequests.isEmpty || workspacePreparation?.isRunning == true || settlement?.phase == .resuming { return true }
        if projectScripts.contains(where: { ![.succeeded, .skipped, .failed, .cancelled, .interrupted].contains($0.1.phase) }) { return true }
        return (runHistory ?? []).contains { record in
            guard let checkpoints = record.checkpoints else { return false }
            return ([checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])).contains { $0.phase.isRunning }
        }
    }
    var pullRequestCreationScopePaths: [String] {
        checkpointRestoreScopePaths + queuedTurns.map { $0.configuration.workspacePath } +
            (workspacePreparation?.plan.map { [$0.commonDirectoryPath] } ?? []) +
            (runHistory ?? []).flatMap { record -> [String] in
                guard let checkpoints = record.checkpoints else { return [] }
                return ([checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])).compactMap { $0.plan?.commonDirectoryPath }
            }
    }
}

extension WorkspaceDecision {
    func validatePullRequestCreationLocks(_ command: WorkspaceCommand) throws {
        let created: CodingThread?
        switch command { case .createThread(let value), .addProjectWithThread(_, let value), .startProjectClone(_, let value): created = value; default: created = nil }
        let reserved = Set((snapshot.pullRequestCreations ?? []).flatMap { [$0.id, $0.effectID] })
        if let created {
            guard !reserved.contains(created.id), !(snapshot.pullRequestCreations ?? []).contains(where: { $0.projectID == created.projectID && $0.locksSource }), !created.pullRequestCreationScopePaths.contains(where: { snapshot.isPullRequestCreationLocked(path: $0) }) else { throw WorkspaceCommandError("This checkout or identity is held by a pending pull request creation.") }
        }
        switch command {
        case .addProject(let project), .addProjectWithThread(let project, _), .startProjectClone(let project, _):
            guard !reserved.contains(project.id), !snapshot.isPullRequestCreationLocked(path: project.path) else { throw WorkspaceCommandError("This project overlaps a pending pull request creation.") }
        case .editThread(let id, let edit):
            switch edit { case .draft, .title, .pinned: return; case .workspacePath(let path): guard !snapshot.isPullRequestCreationLocked(path: path) else { throw WorkspaceCommandError("The destination is held by pull request creation.") }; default: break }
            try requirePullRequestCreationUnlocked([id])
        case .removeProject(let id, _), .retryProjectClone(let id, _), .cancelProjectClone(let id):
            guard let project = snapshot.projects.first(where: { $0.id == id }) else { return }
            guard !snapshot.isPullRequestCreationLocked(path: project.path), !(snapshot.pullRequestCreations ?? []).contains(where: { $0.projectID == id && $0.locksSource }) else { throw WorkspaceCommandError("Reconcile the pending pull request before removing its project.") }
            try requirePullRequestCreationUnlocked(snapshot.threads.filter { $0.projectID == id }.map(\.id))
        case .removeProjectGroup(_, let projects, _):
            guard !projects.contains(where: { member in snapshot.isPullRequestCreationLocked(path: member.path) || (snapshot.pullRequestCreations ?? []).contains { $0.projectID == member.id && $0.locksSource } }) else { throw WorkspaceCommandError("This group owns a pending pull request creation.") }
            try requirePullRequestCreationUnlocked(snapshot.threads.filter { thread in projects.contains { $0.id == thread.projectID } }.map(\.id))
        case .submit(let id, _), .interrupt(let id), .respond(let id, _, _), .resumeQueue(let id), .removeQueued(let id, _), .editQueued(let id, _),
             .settleThread(let id, _, _), .resumeThread(let id, _), .cancelWorktreePreparation(let id), .approveProjectScript(let id, _, _),
             .stopProjectScript(let id, _), .skipProjectScript(let id, _), .retryProjectScript(let id, _), .retryPostRunCheckpoint(let id, _, _),
             .continueAfterPostRunCheckpoint(let id, _, _): try requirePullRequestCreationUnlocked([id])
        case .saveACPAgent(let agent): try requirePullRequestCreationUnlocked(snapshot.threads.filter { $0.acpAgent?.id == agent.id }.map(\.id))
        case .removeACPAgent(let id): try requirePullRequestCreationUnlocked(snapshot.threads.filter { $0.acpAgent?.id == id }.map(\.id))
        default: break
        }
    }
    private func requirePullRequestCreationUnlocked(_ threadIDs: [UUID]) throws {
        guard !threadIDs.contains(where: { snapshot.isPullRequestCreationLocked(threadID: $0) }) else { throw WorkspaceCommandError("Refresh the uncertain pull request or explicitly acknowledge its outcome before changing this checkout.") }
    }
    mutating func acceptPullRequestCreation(_ operation: PullRequestCreationOperation) throws {
        guard operation.phase == .accepted, snapshot.pullRequestCreation(operation.id) == nil else { throw WorkspaceCommandError("This pull request intent was already used.") }
        try snapshot.validatePullRequestCreationSource(operation)
        guard !operation.scopePaths.contains(where: { snapshot.isCheckpointRestoreLocked(path: $0) || snapshot.isPullRequestCreationLocked(path: $0) || snapshot.isPullRequestCheckoutLocked(path: $0) }) else {
            throw WorkspaceCommandError("Finish the pending file or pull request action before creating another pull request.")
        }
        let owners = snapshot.threads.filter { thread in
            thread.projectID == operation.projectID || thread.pullRequestCreationScopePaths.contains { path in operation.scopePaths.contains { WorkspaceSnapshot.checkpointRestorePathsOverlap(path, $0) } }
        }
        guard !owners.contains(where: { $0.hasPullRequestCreationWork || snapshot.isConversationHistoryLocked(threadID: $0.id) || snapshot.isPullRequestCheckoutLocked(threadID: $0.id) }) else {
            throw WorkspaceCommandError("Finish work, queues and workspace actions before creating a pull request.")
        }
        if snapshot.pullRequestCreations == nil { snapshot.pullRequestCreations = [] }
        snapshot.pullRequestCreations!.append(operation)
        do { try snapshot.validatePullRequestCreations() }
        catch { throw WorkspaceCommandError("This pull request identity is reserved by another workspace action.") }
        effects.append(.init(id: operation.effectID, request: .pullRequestCreation(projectID: operation.projectID, operationID: operation.id, effectID: operation.effectID)))
        for thread in snapshot.threads where snapshot.isPullRequestCreationLocked(threadID: thread.id) { closeRuntimes.insert(thread.id) }
    }
    mutating func dispatchPullRequestCreation(projectID: UUID, operationID: UUID, incarnation: UUID, now: Date) throws {
        guard let index = snapshot.pullRequestCreations?.firstIndex(where: { $0.id == operationID }),
              let operation = snapshot.pullRequestCreations?[index], operation.phase == .accepted,
              operation.projectID == projectID, operation.sourceIncarnation == incarnation else { return }
        try snapshot.validatePullRequestCreationSource(operation)
        snapshot.pullRequestCreations?[index].phase = .dispatching; snapshot.pullRequestCreations?[index].updatedAt = now
    }
    mutating func finishPullRequestCreation(_ request: WorkspaceEffectRequest, result: EffectResult, incarnation: UUID, now: Date) {
        guard case .pullRequestCreation(let projectID, let operationID, let effectID) = request,
              let index = snapshot.pullRequestCreations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.pullRequestCreations?[index], operation.isWorking,
              operation.projectID == projectID, operation.effectID == effectID, operation.sourceIncarnation == incarnation else { return }
        switch result {
        case .pullRequestCreationConfirmed(let outcome):
            guard operation.phase == .dispatching else { return }
            switch outcome { case .created: operation.phase = .created; case .openedExisting: operation.phase = .openedExisting }
            operation.result = outcome; operation.error = nil
            do { try operation.validate() } catch { operation.phase = .unconfirmed; operation.result = nil; operation.error = PullRequestCreationOperation.unconfirmedMessage }
        case .failed:
            operation.phase = .failed; operation.error = PullRequestCreationOperation.failureMessage
        case .cancelled, .stopped, .pullRequestCreationUnconfirmed:
            operation.phase = operation.phase == .accepted ? .failed : .unconfirmed
            operation.error = operation.phase == .failed ? PullRequestCreationOperation.failureMessage : PullRequestCreationOperation.unconfirmedMessage
        default: return
        }
        operation.updatedAt = now; snapshot.pullRequestCreations?[index] = operation
    }
    mutating func reconcilePullRequestCreation(operationID: UUID, result: GitHubPullRequestCreateReconciliation, now: Date) throws {
        guard let index = snapshot.pullRequestCreations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.pullRequestCreations?[index], operation.phase == .unconfirmed, operation.acknowledgedAt == nil else { throw WorkspaceCommandError("Only an uncertain pull request creation can be refreshed.") }
        try snapshot.validatePullRequestCreationSource(operation)
        switch result {
        case .found(let detail):
            try operation.validateResult(detail, requiresReviewedBase: false)
            operation.phase = .openedExisting; operation.result = .openedExisting(detail); operation.error = nil
        case .notFound: operation.error = PullRequestCreationOperation.notFoundMessage
        }
        operation.updatedAt = now; try operation.validate(); snapshot.pullRequestCreations?[index] = operation
    }
    mutating func acknowledgePullRequestCreation(operationID: UUID, now: Date) throws {
        guard let index = snapshot.pullRequestCreations?.firstIndex(where: { $0.id == operationID }),
              let operation = snapshot.pullRequestCreations?[index], operation.phase == .unconfirmed else { throw WorkspaceCommandError("Only an uncertain pull request outcome needs acknowledgement.") }
        if operation.acknowledgedAt != nil { return }
        snapshot.pullRequestCreations?[index].acknowledgedAt = now; snapshot.pullRequestCreations?[index].updatedAt = now
    }
}
