import Foundation

public enum PullRequestCheckoutPhase: String, Codable, Sendable {
    case accepted, dispatching, completed, failed, unconfirmed
}

/// Captured new-conversation settings; no provider identity, prompt or transcript is inherited.
public struct PullRequestCheckoutReview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let reviewedAt: Date
    public let projectID: UUID
    public let projectPath: String
    public let registeredWorkspacePath: String
    public let sourceIncarnation: UUID
    public let targetThreadID: UUID
    public let targetConfiguration: ProviderConfiguration
    public let checkpointPolicy: RunCheckpointPolicy?
    public let title: String
    public let reviewSetup: Bool
    public let plan: GitHubPullRequestCheckoutPlan
    public var capturedReviewSetup: Bool { reviewSetup }
    public init(id: UUID = UUID(), reviewedAt: Date = Date(), projectID: UUID, projectPath: String,
                registeredWorkspacePath: String, sourceIncarnation: UUID, targetThreadID: UUID = UUID(),
                targetConfiguration: ProviderConfiguration, checkpointPolicy: RunCheckpointPolicy? = nil,
                title: String, reviewSetup: Bool = true, plan: GitHubPullRequestCheckoutPlan) throws {
        self.id = id; self.reviewedAt = reviewedAt; self.projectID = projectID; self.projectPath = projectPath
        self.registeredWorkspacePath = registeredWorkspacePath; self.sourceIncarnation = sourceIncarnation
        self.targetThreadID = targetThreadID; self.targetConfiguration = targetConfiguration
        self.checkpointPolicy = checkpointPolicy; self.title = title; self.reviewSetup = reviewSetup; self.plan = plan
        try validate()
    }
    public func validate() throws {
        try plan.validate(); try CheckpointValidation.path(projectPath); try CheckpointValidation.path(registeredWorkspacePath)
        guard Set([id, projectID, targetThreadID, plan.request.id]).count == 4,
              reviewedAt.timeIntervalSince1970.isFinite, plan.request.sourcePath == registeredWorkspacePath, targetConfiguration.nativeThreadID == nil,
              targetConfiguration.workspacePath == plan.destinationPath,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 4_096, !title.contains("\0"),
              targetConfiguration.provider != .acp || targetConfiguration.acpAgent != nil,
              targetConfiguration.agentConfiguration?.values.allSatisfy({ $0.string != nil || $0 == .bool(true) || $0 == .bool(false) }) ?? true,
              try JSONEncoder().encode(targetConfiguration).count <= 1_048_576 else { throw CoincideError("The pull request checkout review has invalid target settings or identities.") }
        try targetConfiguration.acpAgent?.validate()
        try CodexReasoningValidation.configuration(targetConfiguration)
    }
}

public struct PullRequestCheckoutOperation: Codable, Sendable, Equatable, Identifiable {
    public let review: PullRequestCheckoutReview
    public let effectID: UUID
    public var phase: PullRequestCheckoutPhase
    public var updatedAt: Date
    public var result: GitHubPullRequestCheckoutResult?
    public var error: String?
    public var acknowledgedAt: Date?
    public var cancelRequested: Bool
    public var id: UUID { review.id }
    public var projectID: UUID { review.projectID }
    public var targetThreadID: UUID { review.targetThreadID }
    /// Only checkout files this operation can change are held against writers.
    /// Shared Git metadata is coordinated separately and never pauses sibling checkouts.
    public var affectedWorkspacePaths: [String] { review.plan.affectedWorkspacePaths }
    public var scopePaths: [String] { affectedWorkspacePaths }
    public var coordinationPaths: [String] { review.plan.coordinationPaths }
    public var isWorking: Bool { phase == .accepted || phase == .dispatching }
    public var retainsProject: Bool { isWorking || (phase == .unconfirmed && acknowledgedAt == nil) }
    public var locksSource: Bool { !review.plan.isReadOnly && retainsProject }
    public static let failureMessage = "The pull request checkout did not complete. No conversation was created and no operation was replayed. Review the current checkout before trying again."
    public static let unconfirmedMessage = "The checkout may have changed. Inspect the retained attempt or explicitly keep the current files before continuing. No conversation was created and the operation was not repeated."
    public init(review: PullRequestCheckoutReview, effectID: UUID = UUID(), phase: PullRequestCheckoutPhase = .accepted,
                updatedAt: Date? = nil, result: GitHubPullRequestCheckoutResult? = nil, error: String? = nil,
                acknowledgedAt: Date? = nil, cancelRequested: Bool = false) {
        self.review = review; self.effectID = effectID; self.phase = phase; self.updatedAt = updatedAt ?? review.reviewedAt
        self.result = result; self.error = error; self.acknowledgedAt = acknowledgedAt; self.cancelRequested = cancelRequested
    }
    public func validate() throws {
        try review.validate()
        guard ![id, projectID, targetThreadID, review.plan.request.id].contains(effectID), updatedAt.timeIntervalSince1970.isFinite,
              acknowledgedAt.map({ phase == .unconfirmed && $0.timeIntervalSince1970.isFinite }) ?? true,
              !cancelRequested || phase == .dispatching else { throw CoincideError("The pull request checkout has inconsistent ownership.") }
        switch phase {
        case .accepted, .dispatching: guard result == nil, error == nil, acknowledgedAt == nil else { throw CoincideError("A pending checkout contains completion evidence.") }
        case .completed: guard let result, error == nil, acknowledgedAt == nil else { throw CoincideError("A completed checkout lost its result.") }; try validateResult(result)
        case .failed: guard result == nil, error == Self.failureMessage, acknowledgedAt == nil else { throw CoincideError("A failed checkout lost its explanation.") }
        case .unconfirmed: guard result == nil, error == Self.unconfirmedMessage else { throw CoincideError("An uncertain checkout lost its warning.") }
        }
    }
    public func validateResult(_ result: GitHubPullRequestCheckoutResult) throws {
        try result.validate(plan: review.plan)
        guard result.destinationPath == review.plan.destinationPath,
              !result.isOnPullRequestHead || result.headCommit == review.plan.requestedHeadCommit,
              (result.worktreePlan == nil) == (result.worktreeResult == nil) else { throw CoincideError("The checkout result belongs to another reviewed target.") }
        if let plan = result.worktreePlan, let child = result.worktreeResult {
            try plan.validate(); try ThreadWorkspacePreparation.validate(result: child, plan: plan)
            guard plan.request.id == review.plan.request.id, plan.sourcePath == review.plan.repositoryPath,
                  plan.commonDirectoryPath == review.plan.commonDirectoryPath, plan.destinationPath == result.destinationPath,
                  child.branch == result.branch, child.headCommit == result.headCommit else { throw CoincideError("The checkout's managed worktree proof does not match its result.") }
        }
    }
}

extension CodingThread {
    /// Live ownership only: retained history and shared common directories do not
    /// make an unrelated running checkout a writer of this operation's target.
    public var pullRequestCheckoutWorkspacePaths: [String] {
        var paths = [workspacePath] + queuedTurns.map { $0.configuration.workspacePath }
        if let activeRun { paths.append(activeRun.configuration.workspacePath) }
        if let preparation = workspacePreparation, preparation.isRunning {
            paths += [preparation.request.sourcePath, preparation.destinationPath]
        }
        for (_, script) in projectScripts where ![.succeeded, .skipped, .failed, .cancelled, .interrupted].contains(script.phase) {
            paths.append(script.plan?.workspacePath ?? workspacePath)
        }
        for record in runHistory ?? [] {
            guard let checkpoints = record.checkpoints else { continue }
            for attempt in [checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? []) where attempt.phase.isRunning {
                paths += [attempt.workspacePath] + (attempt.plan.map { [$0.repositoryPath] } ?? [])
            }
        }
        return paths
    }
}

extension WorkspaceSnapshot {
    public func pullRequestCheckout(_ id: UUID) -> PullRequestCheckoutOperation? { pullRequestCheckouts?.first { $0.id == id } }
    public func isPullRequestCheckoutLocked(path: String, excludingOperationID: UUID? = nil) -> Bool {
        (pullRequestCheckouts ?? []).contains { $0.id != excludingOperationID && $0.locksSource && $0.scopePaths.contains { Self.checkpointRestorePathsOverlap(path, $0) } }
    }
    /// Git mutation controls use this separately from file/provider admission.
    public func isPullRequestCheckoutCoordinating(path: String, excludingOperationID: UUID? = nil) -> Bool {
        (pullRequestCheckouts ?? []).contains { operation in
            operation.id != excludingOperationID && operation.locksSource && operation.coordinationPaths.contains { Self.checkpointRestorePathsOverlap(path, $0) }
        }
    }
    public func isPullRequestCheckoutLocked(threadID: UUID, excludingOperationID: UUID? = nil) -> Bool {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return false }
        return (pullRequestCheckouts ?? []).contains { operation in
            operation.id != excludingOperationID && operation.locksSource && thread.pullRequestCheckoutWorkspacePaths.contains { path in
                operation.scopePaths.contains { Self.checkpointRestorePathsOverlap(path, $0) }
            }
        }
    }
    func pullRequestCheckoutHasBusyOwners(paths: [String]) -> Bool {
        threads.contains { thread in
            thread.hasPullRequestCreationWork && thread.pullRequestCheckoutWorkspacePaths.contains { path in
                paths.contains { Self.checkpointRestorePathsOverlap(path, $0) }
            }
        }
    }
    func pullRequestCheckoutConflicts(_ first: PullRequestCheckoutOperation, _ second: PullRequestCheckoutOperation) -> Bool {
        guard first.id != second.id, first.retainsProject, second.retainsProject else { return false }
        if first.review.plan.isReadOnly, second.locksSource, second.scopePaths.contains(where: { Self.checkpointRestorePathsOverlap(first.review.plan.destinationPath, $0) }) { return true }
        if second.review.plan.isReadOnly, first.locksSource, first.scopePaths.contains(where: { Self.checkpointRestorePathsOverlap(second.review.plan.destinationPath, $0) }) { return true }
        if first.scopePaths.contains(where: { path in second.scopePaths.contains { Self.checkpointRestorePathsOverlap(path, $0) } }) { return true }
        return !first.review.plan.isReadOnly && !second.review.plan.isReadOnly &&
            first.review.plan.proof.commonDirectoryIdentity == second.review.plan.proof.commonDirectoryIdentity &&
            first.review.plan.commonDirectoryPath == second.review.plan.commonDirectoryPath &&
            first.review.plan.requestedBranch == second.review.plan.requestedBranch
    }
    var pullRequestCheckoutReservedIDs: Set<UUID> {
        Set((pullRequestCheckouts ?? []).flatMap { [$0.id, $0.effectID, $0.targetThreadID, $0.review.plan.request.id] })
    }
    func validatePullRequestCheckoutSource(_ operation: PullRequestCheckoutOperation) throws {
        try operation.validate()
        guard projects.contains(where: { $0.id == operation.projectID && $0.path == operation.review.projectPath && ($0.clone?.isReady ?? true) }),
              ownsPullRequestWorkspace(projectID: operation.projectID, workspacePath: operation.review.registeredWorkspacePath) else { throw WorkspaceCommandError("The checkout's registered project changed. Review it again.") }
    }
    func validatePullRequestCheckoutTarget(_ operation: PullRequestCheckoutOperation) throws {
        let observed = operation.review.plan.destinationPath
        let protected = operation.scopePaths + operation.coordinationPaths + [observed]
        guard !protected.contains(where: { isCheckpointRestoreLocked(path: $0) || isPullRequestCreationLocked(path: $0) }),
              !(pullRequestCheckouts ?? []).contains(where: { pullRequestCheckoutConflicts(operation, $0) }) else {
            throw WorkspaceCommandError("Finish the pending workspace action before checking out a pull request.")
        }
        let owners = threads.filter { thread in thread.pullRequestCheckoutWorkspacePaths.contains { Self.checkpointRestorePathsOverlap(observed, $0) } }
        if operation.review.plan.isReadOnly {
            guard !owners.contains(where: { $0.workspacePreparation?.isRunning == true || $0.settlement?.phase == .resuming || isConversationHistoryLocked(threadID: $0.id) }) else {
                throw WorkspaceCommandError("Finish the target's workspace or history action before observing this checkout.")
            }
        } else {
            guard !owners.contains(where: { $0.hasPullRequestCreationWork || isConversationHistoryLocked(threadID: $0.id) }) else {
                throw WorkspaceCommandError("Finish turns, queues, questions and workspace actions in the affected checkout before changing its files.")
            }
        }
    }
    func validatePullRequestCheckouts() throws {
        let operations = pullRequestCheckouts ?? []
        let ids = operations.flatMap { [$0.id, $0.effectID, $0.targetThreadID, $0.review.plan.request.id] }
        guard Set(ids).count == ids.count else { throw CoincideError("Pull request checkout identities must be uniquely reserved.") }
        var reserved = promptSteeringReservedIDs.union(Set(projects.map(\.id) + (pullRequestCreations ?? []).flatMap { [$0.id, $0.effectID] } +
            (checkpointRestoreOperations ?? []).map(\.id) + (conversationHistoryOperations ?? []).flatMap { [$0.id] + ($0.review.targetThreadID.map { [$0] } ?? []) + ($0.review.files.map { [$0.id] } ?? []) }))
        for project in projects { if let clone = project.clone { reserved.formUnion((clone.previousPlans + [clone.plan]).map(\.id)) } }
        for thread in threads {
            if let origin = thread.pullRequestCheckoutOperationID {
                guard let operation = operations.first(where: { $0.id == origin }), operation.phase == .completed,
                      operation.targetThreadID == thread.id, operation.projectID == thread.projectID else { throw CoincideError("A pull request conversation lost its completed checkout lineage.") }
            } else { reserved.insert(thread.id) }
            reserved.formUnion(thread.queuedTurns.map(\.id)); if let active = thread.activeRun { reserved.insert(active.id) }
            for record in thread.runHistory ?? [] {
                reserved.insert(record.id)
                if let checkpoints = record.checkpoints { reserved.formUnion(([checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])).map(\.id)) }
            }
            if let preparation = thread.workspacePreparation {
                let ownedPlan = operations.first { $0.id == thread.pullRequestCheckoutOperationID && $0.phase == .completed }?.result?.worktreePlan
                let ownedChild = ownedPlan == preparation.plan && ownedPlan?.id == preparation.id
                reserved.formUnion(preparation.previousAttempts.filter { $0.plan != ownedPlan || $0.request.id != ownedPlan?.id }.map { $0.request.id })
                if !ownedChild { reserved.insert(preparation.id) }
                for script in preparation.previousAttempts.compactMap(\.setup) + (preparation.setup.map { [$0] } ?? []) { reserved.formUnion(script.previousPlans.map(\.id) + [script.id]) }
            }
            if let settlement = thread.settlement { reserved.insert(settlement.id); if let script = settlement.script { reserved.formUnion(script.previousPlans.map(\.id) + [script.id]) } }
        }
        guard Set(ids).isDisjoint(with: reserved) else { throw CoincideError("A pull request checkout identity belongs to another operation.") }
        for operation in operations {
            try operation.validate()
            if operation.retainsProject { try validatePullRequestCheckoutSource(operation) }
            if operation.phase != .completed, threads.contains(where: { $0.id == operation.targetThreadID }) { throw CoincideError("An unfinished checkout cannot create a conversation.") }
        }
        let locked = operations.filter(\.retainsProject)
        for (index, operation) in locked.enumerated() {
            guard !locked.dropFirst(index + 1).contains(where: { pullRequestCheckoutConflicts(operation, $0) }) else { throw CoincideError("Pending pull request checkouts cannot change the same target or branch.") }
        }
    }
}

extension WorkspaceDecision {
    func validatePullRequestCheckoutLocks(_ command: WorkspaceCommand) throws {
        let created: CodingThread?
        switch command { case .createThread(let value), .addProjectWithThread(_, let value), .startProjectClone(_, let value): created = value; default: created = nil }
        let reserved = snapshot.pullRequestCheckoutReservedIDs
        if case .retryProjectClone(_, let plan) = command, reserved.contains(plan.id) { throw WorkspaceCommandError("This clone identity is reserved by a pull request checkout.") }
        if let created {
            guard created.pullRequestCheckoutOperationID == nil, !reserved.contains(created.id),
                  !created.pullRequestCheckoutWorkspacePaths.contains(where: { snapshot.isPullRequestCheckoutLocked(path: $0) }) else { throw WorkspaceCommandError("This checkout or conversation identity is held by a pull request checkout.") }
        }
        switch command {
        case .addProject(let project), .addProjectWithThread(let project, _), .startProjectClone(let project, _):
            guard !reserved.contains(project.id), project.clone.map({ !reserved.contains($0.id) }) ?? true,
                  !snapshot.isPullRequestCheckoutLocked(path: project.path) else { throw WorkspaceCommandError("This project overlaps a pending pull request checkout.") }
        case .editThread(let id, let edit):
            switch edit { case .draft, .title, .pinned: return; case .workspacePath(let path): guard !snapshot.isPullRequestCheckoutLocked(path: path) else { throw WorkspaceCommandError("The destination is held by a pull request checkout.") }; default: break }
            try requirePullRequestCheckoutUnlocked([id])
        case .removeProject(let id, _), .retryProjectClone(let id, _), .cancelProjectClone(let id):
            guard let project = snapshot.projects.first(where: { $0.id == id }) else { return }
            guard !snapshot.isPullRequestCheckoutLocked(path: project.path), !(snapshot.pullRequestCheckouts ?? []).contains(where: { $0.projectID == id && $0.retainsProject }) else { throw WorkspaceCommandError("Inspect or acknowledge the pending checkout before removing its project.") }
            try requirePullRequestCheckoutUnlocked(snapshot.threads.filter { $0.projectID == id }.map(\.id))
        case .removeProjectGroup(_, let projects, _):
            guard !projects.contains(where: { member in snapshot.isPullRequestCheckoutLocked(path: member.path) || (snapshot.pullRequestCheckouts ?? []).contains { $0.projectID == member.id && $0.retainsProject } }) else { throw WorkspaceCommandError("This group owns a pending pull request checkout.") }
            try requirePullRequestCheckoutUnlocked(snapshot.threads.filter { thread in projects.contains { $0.id == thread.projectID } }.map(\.id))
        case .submit(let id, _), .interrupt(let id), .respond(let id, _, _), .resumeQueue(let id), .removeQueued(let id, _), .editQueued(let id, _),
             .settleThread(let id, _, _), .resumeThread(let id, _), .cancelWorktreePreparation(let id), .approveProjectScript(let id, _, _), .stopProjectScript(let id, _),
             .skipProjectScript(let id, _), .retryProjectScript(let id, _), .retryPostRunCheckpoint(let id, _, _), .continueAfterPostRunCheckpoint(let id, _, _): try requirePullRequestCheckoutUnlocked([id])
        case .saveACPAgent(let agent): try requirePullRequestCheckoutUnlocked(snapshot.threads.filter { $0.acpAgent?.id == agent.id }.map(\.id))
        case .removeACPAgent(let id): try requirePullRequestCheckoutUnlocked(snapshot.threads.filter { $0.acpAgent?.id == id }.map(\.id))
        default: break
        }
    }
    private func requirePullRequestCheckoutUnlocked(_ ids: [UUID]) throws {
        guard !ids.contains(where: { snapshot.isPullRequestCheckoutLocked(threadID: $0) }) else { throw WorkspaceCommandError("Finish or inspect the pull request checkout before changing this workspace.") }
    }
    mutating func acceptPullRequestCheckout(_ operation: PullRequestCheckoutOperation) throws {
        guard operation.phase == .accepted, snapshot.pullRequestCheckout(operation.id) == nil else { throw WorkspaceCommandError("This checkout intent was already used.") }
        try snapshot.validatePullRequestCheckoutSource(operation)
        try snapshot.validatePullRequestCheckoutTarget(operation)
        if snapshot.pullRequestCheckouts == nil { snapshot.pullRequestCheckouts = [] }; snapshot.pullRequestCheckouts!.append(operation)
        do { try snapshot.validatePullRequestCheckouts() }
        catch { throw WorkspaceCommandError("The checkout uses an identity already reserved by another workspace action.") }
        effects.append(.init(id: operation.effectID, request: .pullRequestCheckout(projectID: operation.projectID, operationID: operation.id, effectID: operation.effectID)))
        for thread in snapshot.threads where thread.pullRequestCheckoutWorkspacePaths.contains(where: { path in
            operation.scopePaths.contains { WorkspaceSnapshot.checkpointRestorePathsOverlap(path, $0) }
        }) { closeRuntimes.insert(thread.id) }
    }
    mutating func dispatchPullRequestCheckout(projectID: UUID, operationID: UUID, incarnation: UUID, now: Date) throws {
        guard let index = snapshot.pullRequestCheckouts?.firstIndex(where: { $0.id == operationID }), let operation = snapshot.pullRequestCheckouts?[index],
              operation.phase == .accepted, operation.projectID == projectID, operation.review.sourceIncarnation == incarnation else { return }
        try snapshot.validatePullRequestCheckoutSource(operation)
        try snapshot.validatePullRequestCheckoutTarget(operation)
        snapshot.pullRequestCheckouts?[index].phase = .dispatching; snapshot.pullRequestCheckouts?[index].updatedAt = now
    }
    mutating func finishPullRequestCheckout(_ request: WorkspaceEffectRequest, result: EffectResult, incarnation: UUID, now: Date) throws {
        guard case .pullRequestCheckout(let projectID, let operationID, let effectID) = request,
              let index = snapshot.pullRequestCheckouts?.firstIndex(where: { $0.id == operationID }), var operation = snapshot.pullRequestCheckouts?[index],
              operation.isWorking, operation.projectID == projectID, operation.effectID == effectID, operation.review.sourceIncarnation == incarnation else { return }
        switch result {
        case .pullRequestCheckoutCompleted(let value):
            guard operation.phase == .dispatching else { return }
            do { try materializePullRequestCheckout(operation, result: value, now: now); operation.phase = .completed; operation.result = value; operation.error = nil }
            catch {
                operation.phase = operation.review.plan.isReadOnly ? .failed : .unconfirmed
                operation.error = operation.review.plan.isReadOnly ? PullRequestCheckoutOperation.failureMessage : PullRequestCheckoutOperation.unconfirmedMessage
            }
        case .failed: operation.phase = .failed; operation.error = PullRequestCheckoutOperation.failureMessage
        case .cancelled, .stopped, .pullRequestCheckoutUnconfirmed:
            operation.phase = operation.phase == .accepted || operation.review.plan.isReadOnly ? .failed : .unconfirmed
            operation.error = operation.phase == .failed ? PullRequestCheckoutOperation.failureMessage : PullRequestCheckoutOperation.unconfirmedMessage
        default: return
        }
        operation.cancelRequested = false; operation.updatedAt = now; snapshot.pullRequestCheckouts?[index] = operation
    }
    private mutating func materializePullRequestCheckout(_ operation: PullRequestCheckoutOperation, result: GitHubPullRequestCheckoutResult, now: Date) throws {
        try operation.validateResult(result)
        try snapshot.validatePullRequestCheckoutTarget(operation)
        guard let project = snapshot.projects.first(where: { $0.id == operation.projectID }), !snapshot.threads.contains(where: { $0.id == operation.targetThreadID }) else { throw CoincideError("The reserved pull request conversation is unavailable.") }
        var target = CodingThread(project: project), configuration = operation.review.targetConfiguration
        configuration.workspacePath = result.destinationPath; configuration.nativeThreadID = nil
        target.id = operation.targetThreadID; target.title = operation.review.title; target.workspacePath = configuration.workspacePath
        target.provider = configuration.provider; target.model = configuration.model; target.reasoningEffort = configuration.reasoningEffort; target.permission = configuration.permission; target.acpAgent = configuration.acpAgent; target.openCodeConfiguration = configuration.openCodeConfiguration; target.piConfiguration = configuration.piConfiguration; target.museConfiguration = configuration.museConfiguration; target.antigravityConfiguration = configuration.antigravityConfiguration
        target.agentModeID = configuration.agentModeID; target.agentConfigValues = configuration.agentConfigValues; target.agentConfiguration = configuration.agentConfiguration
        target.checkpointPolicy = operation.review.checkpointPolicy; target.pullRequestCheckoutOperationID = operation.id
        target.queuePaused = true; target.createdAt = now; target.updatedAt = now
        if let plan = result.worktreePlan, let child = result.worktreeResult {
            var preparation = ThreadWorkspacePreparation(request: plan.request, now: now)
            preparation.plan = plan; preparation.result = child; preparation.phase = .completed; preparation.endedAt = now
            if !operation.review.plan.isReadOnly, operation.review.reviewSetup, (result.created || result.moved), preparation.permitsProjectSetup {
                var setup = ThreadProjectScriptRun(now: now); setup.phase = .discovering; preparation.setup = setup
                effects.append(.init(request: .resolveProjectScript(threadID: target.id, attemptID: preparation.id, runID: setup.id)))
            }
            target.workspacePreparation = preparation
        }
        snapshot.threads.insert(target, at: 0)
    }
    mutating func inspectPullRequestCheckout(operationID: UUID, result: GitHubPullRequestCheckoutInspection, now: Date) throws {
        guard let index = snapshot.pullRequestCheckouts?.firstIndex(where: { $0.id == operationID }), var operation = snapshot.pullRequestCheckouts?[index],
              operation.phase == .unconfirmed, operation.acknowledgedAt == nil else { throw WorkspaceCommandError("Only an uncertain checkout can be inspected.") }
        try snapshot.validatePullRequestCheckoutSource(operation)
        if case .completed(let value) = result {
            do { try materializePullRequestCheckout(operation, result: value, now: now); operation.phase = .completed; operation.result = value; operation.error = nil }
            catch { throw WorkspaceCommandError("The inspected checkout did not match its reserved conversation. Current files remain held.") }
        }
        operation.updatedAt = now; snapshot.pullRequestCheckouts?[index] = operation
    }
    mutating func acknowledgePullRequestCheckout(operationID: UUID, now: Date) throws {
        guard let index = snapshot.pullRequestCheckouts?.firstIndex(where: { $0.id == operationID }), let operation = snapshot.pullRequestCheckouts?[index], operation.phase == .unconfirmed else { throw WorkspaceCommandError("Only an uncertain checkout needs acknowledgement.") }
        if operation.acknowledgedAt == nil { snapshot.pullRequestCheckouts?[index].acknowledgedAt = now; snapshot.pullRequestCheckouts?[index].updatedAt = now }
    }
    mutating func cancelPullRequestCheckout(operationID: UUID, now: Date) throws {
        guard let index = snapshot.pullRequestCheckouts?.firstIndex(where: { $0.id == operationID }), let operation = snapshot.pullRequestCheckouts?[index], operation.isWorking else { throw WorkspaceCommandError("This checkout is no longer running.") }
        if operation.phase == .accepted { snapshot.pullRequestCheckouts?[index].phase = .failed; snapshot.pullRequestCheckouts?[index].error = PullRequestCheckoutOperation.failureMessage }
        else { snapshot.pullRequestCheckouts?[index].cancelRequested = true }
        snapshot.pullRequestCheckouts?[index].updatedAt = now
    }
}
