import CryptoKit
import Foundation

public enum RunCheckpointRestorePhase: String, Codable, Sendable { case accepted, dispatching, applied, failed, unconfirmed }

/// Immutable admission evidence. The Git service owns the file manifest and all writes.
public struct RunCheckpointRestoreReview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let reviewedAt: Date
    public let threadID: UUID
    public let projectID: UUID
    public let runID: UUID
    public let stage: RunCheckpointStage
    public let attemptID: UUID
    public let sourceIncarnation: UUID
    public let sourceFingerprint: String
    public let checkpoint: ThreadRunCheckpointAttempt
    public let gitReview: GitCheckpointRestoreReview
    public var workspacePath: String { checkpoint.workspacePath }
    public init(id: UUID = UUID(), reviewedAt: Date = Date(), threadID: UUID, projectID: UUID, runID: UUID,
                stage: RunCheckpointStage, attemptID: UUID, sourceIncarnation: UUID, sourceFingerprint: String,
                checkpoint: ThreadRunCheckpointAttempt, gitReview: GitCheckpointRestoreReview) throws {
        self.id = id; self.reviewedAt = reviewedAt; self.threadID = threadID; self.projectID = projectID
        self.runID = runID; self.stage = stage; self.attemptID = attemptID; self.sourceIncarnation = sourceIncarnation
        self.sourceFingerprint = sourceFingerprint; self.checkpoint = checkpoint; self.gitReview = gitReview
        try validate()
    }
    public func validate() throws {
        try checkpoint.validate(workspacePath: workspacePath); try gitReview.validate()
        guard reviewedAt.timeIntervalSince1970.isFinite, CheckpointValidation.digest(sourceFingerprint),
              checkpoint.id == attemptID, checkpoint.phase == .ready,
              checkpoint.receipt == gitReview.targetReceipt, gitReview.id == id,
              gitReview.currentPlan.workspacePath == workspacePath,
              id != threadID, id != projectID, id != runID, id != attemptID else {
            throw CoincideError("The checkpoint restoration review has inconsistent ownership or evidence.")
        }
    }
}

public struct RunCheckpointRestoreOperation: Codable, Sendable, Equatable, Identifiable {
    public let review: RunCheckpointRestoreReview
    public var phase: RunCheckpointRestorePhase
    public var updatedAt: Date
    public var result: GitCheckpointRestoreReceipt?
    public var error: String?
    public var acknowledgedAt: Date?
    public var id: UUID { review.id }
    public var isPending: Bool { phase == .accepted || phase == .dispatching }
    public var locksSource: Bool { isPending || (phase == .unconfirmed && acknowledgedAt == nil) }
    public static let failureMessage = "Workspace restoration did not start. Review the current files before trying again."
    public static let unconfirmedMessage = "Workspace files may have changed. Inspect the saved restoration evidence or explicitly keep the current files; restoration was not repeated."
    public static let unchangedMessage = "Inspection confirmed that this restoration did not start. Current files were kept."
    public init(review: RunCheckpointRestoreReview, phase: RunCheckpointRestorePhase = .accepted, updatedAt: Date? = nil,
                result: GitCheckpointRestoreReceipt? = nil, error: String? = nil, acknowledgedAt: Date? = nil) {
        self.review = review; self.phase = phase; self.updatedAt = updatedAt ?? review.reviewedAt
        self.result = result; self.error = error; self.acknowledgedAt = acknowledgedAt
    }
    public func validate() throws {
        try review.validate()
        guard updatedAt.timeIntervalSince1970.isFinite, (phase == .applied) == (result != nil),
              acknowledgedAt.map({ phase == .unconfirmed && $0.timeIntervalSince1970.isFinite }) ?? true,
              error.map({ [Self.failureMessage, Self.unconfirmedMessage, Self.unchangedMessage].contains($0) }) ?? true else {
            throw CoincideError("The checkpoint restoration operation has inconsistent state.")
        }
        switch phase {
        case .accepted, .dispatching, .applied:
            guard error == nil, acknowledgedAt == nil else { throw CoincideError("A pending or applied restoration cannot contain failure evidence.") }
        case .failed:
            guard error == Self.failureMessage || error == Self.unchangedMessage, acknowledgedAt == nil else { throw CoincideError("A failed restoration must retain its fixed outcome explanation.") }
        case .unconfirmed:
            guard error == Self.unconfirmedMessage else { throw CoincideError("An unconfirmed restoration must retain its partial-write warning.") }
        }
        if let result { try result.validate(); guard result.review == review.gitReview else { throw CoincideError("The restoration result belongs to another reviewed manifest.") } }
    }
}

extension CodingThread {
    /// An old post-run observation remains selectable by its own exact attempt ID.
    public func runCheckpoint(runID: UUID, stage: RunCheckpointStage, expectedAttemptID: UUID) -> ThreadRunCheckpointAttempt? {
        guard let checkpoints = runHistory?.first(where: { $0.id == runID })?.checkpoints else { return nil }
        let attempts = stage == .baseline ? [checkpoints.baseline] : checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])
        return attempts.first { $0.id == expectedAttemptID }
    }
    var checkpointRestoreScopePaths: [String] {
        [workspacePath] + (runHistory ?? []).flatMap { record -> [String] in
            guard let checkpoints = record.checkpoints else { return [] }
            return ([checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])).flatMap { attempt in
                [attempt.workspacePath] + (attempt.plan.map { [$0.workspacePath, $0.repositoryPath] } ?? [])
            }
        }
    }
}

extension WorkspaceSnapshot {
    public func checkpointRestoreOperation(_ id: UUID) -> RunCheckpointRestoreOperation? { checkpointRestoreOperations?.first { $0.id == id } }
    public func isCheckpointRestoreLocked(path: String, excludingOperationID: UUID? = nil) -> Bool {
        (checkpointRestoreOperations ?? []).contains { operation in
            operation.id != excludingOperationID && operation.locksSource && Self.checkpointRestorePathsOverlap(path, operation.review.gitReview.currentPlan.repositoryPath)
        } || (conversationHistoryOperations ?? []).contains { operation in
            operation.id != excludingOperationID && operation.locksFiles && operation.files.map { Self.checkpointRestorePathsOverlap(path, $0.review.gitReview.currentPlan.repositoryPath) } == true
        }
    }
    public func isCheckpointRestoreLocked(threadID: UUID, excludingOperationID: UUID? = nil) -> Bool {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return false }
        return (checkpointRestoreOperations ?? []).contains { operation in
            operation.id != excludingOperationID && operation.locksSource && (operation.review.threadID == threadID || thread.checkpointRestoreScopePaths.contains {
                Self.checkpointRestorePathsOverlap($0, operation.review.gitReview.currentPlan.repositoryPath)
            })
        } || (conversationHistoryOperations ?? []).contains { operation in
            guard operation.id != excludingOperationID, operation.locksFiles, let files = operation.files else { return false }
            return operation.review.sourceThreadID == threadID || thread.checkpointRestoreScopePaths.contains { Self.checkpointRestorePathsOverlap($0, files.review.gitReview.currentPlan.repositoryPath) }
        }
    }
    static func checkpointRestorePathsOverlap(_ first: String, _ second: String) -> Bool {
        let a = URL(fileURLWithPath: first).standardizedFileURL.resolvingSymlinksInPath().path
        let b = URL(fileURLWithPath: second).standardizedFileURL.resolvingSymlinksInPath().path
        return a == b || a == "/" || b == "/" || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
    public func canReviewCheckpointRestore(threadID: UUID, excludingOperationID: UUID? = nil) -> Bool {
        guard let thread = threads.first(where: { $0.id == threadID }), !thread.isArchived, !thread.isBusy,
              thread.queuedTurns.isEmpty, thread.runtimeRequests.isEmpty,
              thread.settlement == nil, workspaceReady(for: thread), !isPullRequestCheckoutLocked(threadID: threadID), !isPullRequestCreationLocked(threadID: threadID), !isConversationHistoryLocked(threadID: threadID, excludingOperationID: excludingOperationID),
              !isCheckpointRestoreLocked(threadID: threadID, excludingOperationID: excludingOperationID),
              !(checkpointRestoreOperations ?? []).contains(where: { $0.id != excludingOperationID && $0.locksSource &&
                  (Self.checkpointRestorePathsOverlap(thread.workspacePath, $0.review.gitReview.currentPlan.repositoryPath) || $0.review.threadID == threadID) }),
              let project = projects.first(where: { $0.id == thread.projectID }),
              !Self.checkpointRestorePathsEqual(thread.workspacePath, project.path) else { return false }
        if thread.runHistory?.contains(where: { record in
            guard let checkpoints = record.checkpoints else { return false }
            return ([checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])).contains { $0.phase.isRunning }
        }) == true { return false }
        guard !threads.contains(where: { other in other.id != threadID && other.checkpointRestoreScopePaths.contains {
            Self.checkpointRestorePathsOverlap($0, thread.workspacePath)
        } }) else { return false }
        return thread.workspacePreparation?.setup.map { [.succeeded, .skipped].contains($0.phase) } ?? true
    }
    private static func checkpointRestorePathsEqual(_ first: String, _ second: String) -> Bool {
        URL(fileURLWithPath: first).standardizedFileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: second).standardizedFileURL.resolvingSymlinksInPath().path
    }
    public func checkpointRestoreUnavailableReason(threadID: UUID, runID: UUID, stage: RunCheckpointStage, expectedAttemptID: UUID) -> String? {
        guard canReviewCheckpointRestore(threadID: threadID), let thread = threads.first(where: { $0.id == threadID }) else {
            return "Finish current work and use an isolated conversation worktree with no other conversation or saved checkpoint sharing its files."
        }
        guard let record = thread.runHistory?.first(where: { $0.id == runID }), record.status.isTerminal,
              let attempt = thread.runCheckpoint(runID: runID, stage: stage, expectedAttemptID: expectedAttemptID),
              attempt.phase == .ready, let receipt = attempt.receipt, attempt.workspacePath == thread.workspacePath,
              receipt.plan.workspacePath == thread.workspacePath,
              let project = projects.first(where: { $0.id == thread.projectID }),
              !Self.checkpointRestorePathsEqual(receipt.plan.repositoryPath, project.path) else { return "This exact checkpoint is unavailable or belongs to another isolated workspace." }
        return nil
    }
    public func checkpointRestoreSourceFingerprint(threadID: UUID) throws -> String {
        guard var thread = threads.first(where: { $0.id == threadID }), let project = projects.first(where: { $0.id == thread.projectID }) else { throw WorkspaceCommandError("This conversation or project is unavailable.") }
        thread.title = ""; thread.draft = ""; thread.draftAttachments = []; thread.isPinned = false
        thread.updatedAt = .init(timeIntervalSince1970: 0); thread.runtimeID = nil
        thread.providerMetadata = nil; thread.providerActivity = nil
        struct Source: Encodable { let thread: CodingThread; let projectID: UUID; let projectPath: String; let clone: ProjectCloneState? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(Source(thread: thread, projectID: project.id, projectPath: project.path, clone: project.clone)))
            .map { String(format: "%02x", $0) }.joined()
    }
    func validateCheckpointRestoreSource(_ review: RunCheckpointRestoreReview, excludingOperationID: UUID? = nil) throws {
        try review.validate()
        guard canReviewCheckpointRestore(threadID: review.threadID, excludingOperationID: excludingOperationID),
              let thread = threads.first(where: { $0.id == review.threadID && $0.projectID == review.projectID }),
              let record = thread.runHistory?.first(where: { $0.id == review.runID }), record.status.isTerminal,
              thread.workspacePath == review.workspacePath,
              let project = projects.first(where: { $0.id == review.projectID }),
              !Self.checkpointRestorePathsEqual(review.gitReview.currentPlan.repositoryPath, project.path),
              thread.runCheckpoint(runID: review.runID, stage: review.stage, expectedAttemptID: review.attemptID) == review.checkpoint,
              try checkpointRestoreSourceFingerprint(threadID: thread.id) == review.sourceFingerprint,
              !threads.contains(where: { other in other.id != thread.id && other.checkpointRestoreScopePaths.contains {
                  Self.checkpointRestorePathsOverlap($0, review.gitReview.currentPlan.repositoryPath)
              } }) else { throw WorkspaceCommandError("The conversation, checkpoint or workspace ownership changed. Review restoration again.") }
    }
    func validateCheckpointRestores() throws {
        let operations = checkpointRestoreOperations ?? []
        var reserved = Set(threads.map(\.id) + projects.map(\.id) + (conversationHistoryOperations ?? []).flatMap { [$0.id] + ($0.review.targetThreadID.map { [$0] } ?? []) + ($0.review.files.map { [$0.id] } ?? []) })
        for project in projects { if let clone = project.clone { reserved.formUnion((clone.previousPlans + [clone.plan]).map(\.id)) } }
        for thread in threads {
            reserved.formUnion(thread.queuedTurns.map(\.id)); if let run = thread.activeRun { reserved.insert(run.id) }
            for record in thread.runHistory ?? [] {
                reserved.insert(record.id)
                if let checkpoints = record.checkpoints { reserved.formUnion(([checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])).map(\.id)) }
            }
            if let preparation = thread.workspacePreparation {
                reserved.formUnion(preparation.previousAttempts.map { $0.request.id } + [preparation.id])
                for script in preparation.previousAttempts.compactMap(\.setup) + (preparation.setup.map { [$0] } ?? []) { reserved.formUnion(script.previousPlans.map(\.id) + [script.id]) }
            }
            if let settlement = thread.settlement {
                reserved.insert(settlement.id)
                if let script = settlement.script { reserved.formUnion(script.previousPlans.map(\.id) + [script.id]) }
            }
        }
        guard Set(operations.map(\.id)).count == operations.count, Set(operations.map(\.id)).isDisjoint(with: reserved) else { throw CoincideError("Checkpoint restoration identities must be unique and reserved.") }
        for operation in operations {
            try operation.validate()
            if operation.locksSource {
                guard let thread = threads.first(where: { $0.id == operation.review.threadID && $0.projectID == operation.review.projectID && $0.workspacePath == operation.review.workspacePath }),
                      thread.runCheckpoint(runID: operation.review.runID, stage: operation.review.stage, expectedAttemptID: operation.review.attemptID) == operation.review.checkpoint,
                      try checkpointRestoreSourceFingerprint(threadID: thread.id) == operation.review.sourceFingerprint else { throw CoincideError("A pending restoration lost its source or retained checkpoint audit.") }
            }
        }
        for (i, operation) in operations.enumerated() where operation.locksSource {
            let path = operation.review.gitReview.currentPlan.repositoryPath
            guard !operations.dropFirst(i + 1).contains(where: { other in
                let otherPath = other.review.gitReview.currentPlan.repositoryPath
                return other.locksSource && (path == otherPath || path.hasPrefix(otherPath + "/") || otherPath.hasPrefix(path + "/"))
            }) else { throw CoincideError("Pending restorations cannot share workspace files.") }
        }
    }
}

extension WorkspaceDecision {
    func validateCheckpointRestoreLocks(_ command: WorkspaceCommand) throws {
        let created: CodingThread?
        switch command { case .createThread(let thread), .addProjectWithThread(_, let thread), .startProjectClone(_, let thread): created = thread; default: created = nil }
        if let created, (snapshot.checkpointRestoreOperations ?? []).contains(where: { $0.id == created.id }) || (snapshot.conversationHistoryOperations ?? []).contains(where: { $0.review.files?.id == created.id }) { throw WorkspaceCommandError("This identity is reserved by a checkpoint restoration.") }
        if let created, created.checkpointRestoreScopePaths.contains(where: { snapshot.isCheckpointRestoreLocked(path: $0) }) { throw WorkspaceCommandError("This workspace is locked by a checkpoint restoration.") }
        switch command {
        case .addProject(let project), .addProjectWithThread(let project, _), .startProjectClone(let project, _):
            guard !snapshot.isCheckpointRestoreLocked(path: project.path), !(snapshot.checkpointRestoreOperations ?? []).contains(where: { $0.id == project.id }), !(snapshot.conversationHistoryOperations ?? []).contains(where: { $0.review.files?.id == project.id }) else { throw WorkspaceCommandError("This project overlaps a pending checkpoint restoration.") }
        case .editThread(let id, let edit):
            switch edit {
            case .draft, .pinned, .title: return
            case .workspacePath(let path): guard !snapshot.isCheckpointRestoreLocked(path: path) else { throw WorkspaceCommandError("The destination is locked by a checkpoint restoration.") }
            default: break
            }
            try requireCheckpointRestoreUnlocked([id])
        case .removeProject(let id, _), .retryProjectClone(let id, _), .cancelProjectClone(let id):
            guard let project = snapshot.projects.first(where: { $0.id == id }) else { return }
            guard !snapshot.isCheckpointRestoreLocked(path: project.path) else { throw WorkspaceCommandError("This project is locked by a checkpoint restoration.") }
            try requireCheckpointRestoreUnlocked(snapshot.threads.filter { $0.projectID == id }.map(\.id))
        case .removeProjectGroup(_, let projects, _):
            guard !projects.contains(where: { snapshot.isCheckpointRestoreLocked(path: $0.path) }) else { throw WorkspaceCommandError("This group overlaps a checkpoint restoration.") }
            try requireCheckpointRestoreUnlocked(snapshot.threads.filter { thread in projects.contains { $0.id == thread.projectID } }.map(\.id))
        case .submit(let id, _), .interrupt(let id), .respond(let id, _, _), .resumeQueue(let id), .removeQueued(let id, _), .editQueued(let id, _),
             .settleThread(let id, _, _), .resumeThread(let id, _), .cancelWorktreePreparation(let id), .approveProjectScript(let id, _, _),
             .stopProjectScript(let id, _), .skipProjectScript(let id, _), .retryProjectScript(let id, _), .retryPostRunCheckpoint(let id, _, _),
             .continueAfterPostRunCheckpoint(let id, _, _): try requireCheckpointRestoreUnlocked([id])
        case .saveACPAgent(let agent): try requireCheckpointRestoreUnlocked(snapshot.threads.filter { $0.acpAgent?.id == agent.id }.map(\.id))
        case .removeACPAgent(let id): try requireCheckpointRestoreUnlocked(snapshot.threads.filter { $0.acpAgent?.id == id }.map(\.id))
        default: break
        }
    }
    private func requireCheckpointRestoreUnlocked(_ threadIDs: [UUID]) throws {
        guard !threadIDs.contains(where: { snapshot.isCheckpointRestoreLocked(threadID: $0) }) else { throw WorkspaceCommandError("Inspect the pending restoration or explicitly keep the current files before changing this workspace.") }
    }
    mutating func acceptCheckpointRestore(_ review: RunCheckpointRestoreReview, now: Date) throws {
        guard !snapshot.pullRequestCheckoutReservedIDs.union(snapshot.promptSteeringReservedIDs).contains(review.id) else { throw WorkspaceCommandError("This restoration identity is reserved by a pull request checkout.") }
        guard snapshot.checkpointRestoreOperation(review.id) == nil else { throw WorkspaceCommandError("This restoration identity was already used. Review again.") }
        try snapshot.validateCheckpointRestoreSource(review)
        let operation = RunCheckpointRestoreOperation(review: review, updatedAt: now); try operation.validate()
        if snapshot.checkpointRestoreOperations == nil { snapshot.checkpointRestoreOperations = [] }
        snapshot.checkpointRestoreOperations!.append(operation)
        try snapshot.validateCheckpointRestores()
        effects.append(.init(id: review.id, request: .checkpointRestore(threadID: review.threadID, operationID: review.id)))
    }
    mutating func dispatchCheckpointRestore(threadID: UUID, operationID: UUID, incarnation: UUID, now: Date) throws {
        guard let i = snapshot.checkpointRestoreOperations?.firstIndex(where: { $0.id == operationID }), let operation = snapshot.checkpointRestoreOperations?[i],
              operation.phase == .accepted, operation.review.threadID == threadID, operation.review.sourceIncarnation == incarnation else { return }
        try snapshot.validateCheckpointRestoreSource(operation.review, excludingOperationID: operationID)
        snapshot.checkpointRestoreOperations?[i].phase = .dispatching; snapshot.checkpointRestoreOperations?[i].updatedAt = now
    }
    mutating func finishCheckpointRestore(_ request: WorkspaceEffectRequest, result: EffectResult, incarnation: UUID, now: Date) {
        guard case .checkpointRestore(let threadID, let operationID) = request,
              let i = snapshot.checkpointRestoreOperations?.firstIndex(where: { $0.id == operationID }), var operation = snapshot.checkpointRestoreOperations?[i],
              operation.isPending, operation.review.threadID == threadID, operation.review.sourceIncarnation == incarnation else { return }
        switch result {
        case .checkpointRestoreConfirmed(let receipt):
            guard operation.phase == .dispatching else { return }
            do {
                try snapshot.validateCheckpointRestoreSource(operation.review, excludingOperationID: operationID)
                operation.phase = .applied; operation.result = receipt; operation.error = nil; try operation.validate()
            } catch { operation.phase = .unconfirmed; operation.result = nil; operation.error = RunCheckpointRestoreOperation.unconfirmedMessage }
        case .failed:
            operation.phase = .failed; operation.error = RunCheckpointRestoreOperation.failureMessage
        case .cancelled, .stopped, .checkpointRestoreUnconfirmed:
            operation.phase = operation.phase == .accepted ? .failed : .unconfirmed
            operation.error = operation.phase == .failed ? RunCheckpointRestoreOperation.failureMessage : RunCheckpointRestoreOperation.unconfirmedMessage
        default: return
        }
        operation.updatedAt = now; snapshot.checkpointRestoreOperations?[i] = operation
    }
    mutating func inspectCheckpointRestore(operationID: UUID, incarnation: UUID, result: GitCheckpointRestoreInspection, now: Date) throws {
        guard let i = snapshot.checkpointRestoreOperations?.firstIndex(where: { $0.id == operationID }), var operation = snapshot.checkpointRestoreOperations?[i],
              operation.phase == .unconfirmed, operation.acknowledgedAt == nil else { throw WorkspaceCommandError("Only the current unconfirmed restoration can be inspected.") }
        // A fresh engine incarnation may inspect a restored durable operation. The
        // engine binds this command to its current read; the original write token
        // is deliberately never reused for another filesystem mutation.
        _ = incarnation
        try snapshot.validateCheckpointRestoreSource(operation.review, excludingOperationID: operationID)
        switch result {
        case .ready(let receipt): operation.phase = .applied; operation.result = receipt; operation.error = nil
        case .notStarted: operation.phase = .failed; operation.error = RunCheckpointRestoreOperation.unchangedMessage
        case .interrupted: operation.error = RunCheckpointRestoreOperation.unconfirmedMessage
        }
        operation.updatedAt = now; try operation.validate(); snapshot.checkpointRestoreOperations?[i] = operation
    }
    mutating func acknowledgeCheckpointRestore(operationID: UUID, now: Date) throws {
        guard let i = snapshot.checkpointRestoreOperations?.firstIndex(where: { $0.id == operationID }), let operation = snapshot.checkpointRestoreOperations?[i],
              operation.phase == .unconfirmed else { throw WorkspaceCommandError("Only an unconfirmed restoration can keep its current files.") }
        if operation.acknowledgedAt != nil { return }
        snapshot.checkpointRestoreOperations?[i].acknowledgedAt = now; snapshot.checkpointRestoreOperations?[i].updatedAt = now
    }
}
