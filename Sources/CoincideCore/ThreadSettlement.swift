import Foundation

public enum ProjectScriptRole: String, Codable, Sendable { case setup, settle }
public enum ProjectScriptOwner: Codable, Sendable, Equatable {
    case setup(attemptID: UUID)
    case settlement(generationID: UUID)
    public var role: ProjectScriptRole { if case .setup = self { .setup } else { .settle } }
}
public enum ThreadSettlementPhase: String, Codable, Sendable { case settled, resuming }

/// One explicit settlement generation. Resuming retains its gate until owned jobs drain.
public struct ThreadSettlement: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var settledAt: Date
    public var phase: ThreadSettlementPhase
    public var script: ThreadProjectScriptRun?
    public init(id: UUID = UUID(), settledAt: Date = Date(), reviewScript: Bool = false) {
        self.id = id; self.settledAt = settledAt; phase = .settled
        if reviewScript { script = .init(now: settledAt); script?.phase = .discovering }
    }
    public func validate(thread: CodingThread) throws {
        guard settledAt.timeIntervalSince1970.isFinite, !thread.isBusy else { throw CoincideError("This conversation has inconsistent settlement state.") }
        try script?.validate(workspacePath: thread.workspacePath, role: .settle)
        guard script?.id != id, script?.plan == nil || thread.workspacePreparation?.permitsProjectSetup == true else {
            throw CoincideError("A settle script requires a proven dedicated worktree.")
        }
    }
}

extension CodingThread {
    public var isSettled: Bool { settlement != nil }
    public func projectScript(runID: UUID) -> ThreadProjectScriptRun? {
        if workspacePreparation?.setup?.id == runID { return workspacePreparation?.setup }
        if settlement?.script?.id == runID { return settlement?.script }
        return nil
    }
    public func projectScriptRole(runID: UUID) -> ProjectScriptRole? { projectScriptOwner(runID: runID)?.role }
    public func projectScriptOwner(runID: UUID) -> ProjectScriptOwner? {
        if let preparation = workspacePreparation, preparation.setup?.id == runID { return .setup(attemptID: preparation.id) }
        if let settlement, settlement.script?.id == runID { return .settlement(generationID: settlement.id) }
        return nil
    }
    func projectScript(owner: ProjectScriptOwner) -> ThreadProjectScriptRun? {
        switch owner {
        case .setup(let id): workspacePreparation?.id == id ? workspacePreparation?.setup : nil
        case .settlement(let id): settlement?.id == id ? settlement?.script : nil
        }
    }
    mutating func setProjectScript(_ run: ThreadProjectScriptRun, owner: ProjectScriptOwner) {
        switch owner {
        case .setup(let id): if workspacePreparation?.id == id { workspacePreparation?.setup = run }
        case .settlement(let id): if settlement?.id == id { settlement?.script = run }
        }
    }
    var projectScripts: [(ProjectScriptOwner, ThreadProjectScriptRun)] {
        var result: [(ProjectScriptOwner, ThreadProjectScriptRun)] = []
        if let preparation = workspacePreparation, let run = preparation.setup { result.append((.setup(attemptID: preparation.id), run)) }
        if let settlement, let run = settlement.script { result.append((.settlement(generationID: settlement.id), run)) }
        return result
    }
    mutating func requestSettlementResume(now: Date = Date()) {
        guard settlement != nil, settlement?.phase != .resuming else { return }
        queuePaused = false
        settlement?.phase = .resuming
        if var run = settlement?.script {
            run.phase = .stopping; run.pendingAction = .cancel; run.updatedAt = now
            settlement?.script = run
        }
    }
}

extension WorkspaceSnapshot {
    public func canSettle(threadID: UUID) -> Bool {
        guard !isConversationHistoryLocked(threadID: threadID), let thread = threads.first(where: { $0.id == threadID }), !thread.isArchived, thread.settlement == nil,
              !thread.isBusy, thread.heldPostRunCheckpoint == nil, thread.queuedTurns.isEmpty, thread.runtimeRequests.isEmpty, workspaceReady(for: thread) else { return false }
        return thread.workspacePreparation?.setup.map { [.succeeded, .skipped].contains($0.phase) } ?? true
    }
    func permitsSettleScript(for thread: CodingThread) -> Bool {
        guard thread.workspacePreparation?.isReady == true, thread.workspacePreparation?.permitsProjectSetup == true,
              let project = projects.first(where: { $0.id == thread.projectID }) else { return false }
        return URL(fileURLWithPath: thread.workspacePath).standardizedFileURL.path != URL(fileURLWithPath: project.path).standardizedFileURL.path
    }
    func permitsScriptAction(owner: ProjectScriptOwner, thread: CodingThread) -> Bool {
        guard !thread.isArchived, workspaceReady(for: thread) else { return false }
        switch owner {
        case .setup: return thread.settlement == nil && thread.workspacePreparation?.permitsProjectSetup == true
        case .settlement: return thread.settlement?.phase == .settled && permitsSettleScript(for: thread)
        }
    }
}

extension ProjectScriptOwner {
    func resolveRequest(threadID: UUID, runID: UUID) -> WorkspaceEffectRequest {
        switch self {
        case .setup(let id): .resolveProjectScript(threadID: threadID, attemptID: id, runID: runID)
        case .settlement: .resolveThreadScript(threadID: threadID, owner: self, runID: runID)
        }
    }
    func startRequest(threadID: UUID, plan: ProjectScriptExecutionPlan) -> WorkspaceEffectRequest {
        switch self {
        case .setup(let id): .startProjectScript(threadID: threadID, attemptID: id, plan: plan)
        case .settlement: .startThreadScript(threadID: threadID, owner: self, plan: plan)
        }
    }
}
