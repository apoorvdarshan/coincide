import Foundation

public enum ProviderApprovalResponse: Codable, Sendable, Equatable {
    case decision(Bool)
    case answers([String: String])
    case selections([String: [String]])
    case selectionsWithNotes(selections: [String: [String]], notes: [String: String])
    case option(String)
}

public struct ProviderConfiguration: Codable, Sendable, Equatable {
    public var provider: ProviderKind
    public var workspacePath: String
    public var nativeThreadID: String?
    public var model: String
    public var reasoningEffort: String?
    public var codexRuntimeConfiguration: CodexRuntimeConfiguration?
    public var permission: PermissionMode
    public var acpAgent: ACPAgentConfiguration?
    public var openCodeConfiguration: OpenCodeConfiguration?
    public var piConfiguration: PiConfiguration?
    public var museConfiguration: MuseConfiguration?
    public var antigravityConfiguration: AntigravityConfiguration?
    public var agentModeID: String?
    public var agentConfigValues: [String: String]?
    public var agentConfiguration: [String: JSONValue]?
    public init(thread: CodingThread) {
        provider = thread.provider; workspacePath = thread.workspacePath
        nativeThreadID = thread.providerThreadID; model = thread.model; reasoningEffort = thread.provider == .codex ? thread.reasoningEffort : nil; permission = thread.permission
        codexRuntimeConfiguration = thread.codexRuntimeConfiguration
        acpAgent = thread.acpAgent; openCodeConfiguration = thread.openCodeConfiguration; piConfiguration = thread.piConfiguration; agentModeID = thread.agentModeID
        museConfiguration = thread.museConfiguration
        antigravityConfiguration = thread.antigravityConfiguration
        agentConfigValues = thread.agentConfigValues
        agentConfiguration = thread.agentConfiguration
    }
}

/// Process-bound actions are never replayed automatically after losing their runtime.
public enum WorkspaceEffectRequest: Codable, Sendable, Equatable {
    case providerStart(threadID: UUID, runID: UUID, configuration: ProviderConfiguration, prompt: String, attachments: [ChatAttachment]? = nil)
    case providerInterrupt(threadID: UUID, runID: UUID)
    case providerRespond(threadID: UUID, runID: UUID, request: ApprovalRequest, response: ProviderApprovalResponse)
    case providerSessionRespond(threadID: UUID, runtimeID: UUID, request: ApprovalRequest, response: ProviderApprovalResponse)
    case promptSteering(threadID: UUID, operationID: UUID)
    case projectClone(projectID: UUID, plan: GitClonePlan)
    case resolveWorktree(threadID: UUID, request: GitWorktreeRequest)
    case prepareWorktree(threadID: UUID, plan: GitWorktreePlan)
    case resolveProjectScript(threadID: UUID, attemptID: UUID, runID: UUID)
    case startProjectScript(threadID: UUID, attemptID: UUID, plan: ProjectScriptExecutionPlan)
    case resolveThreadScript(threadID: UUID, owner: ProjectScriptOwner, runID: UUID)
    case startThreadScript(threadID: UUID, owner: ProjectScriptOwner, plan: ProjectScriptExecutionPlan)
    case resolveRunCheckpoint(threadID: UUID, runID: UUID, stage: RunCheckpointStage, attemptID: UUID)
    case captureRunCheckpoint(threadID: UUID, runID: UUID, stage: RunCheckpointStage, plan: GitCheckpointPlan)
    case pullRequestCreation(projectID: UUID, operationID: UUID, effectID: UUID)
    case pullRequestCheckout(projectID: UUID, operationID: UUID, effectID: UUID)
    case conversationHistory(threadID: UUID, operationID: UUID)
    case conversationHistoryMaintenance(threadID: UUID, operationID: UUID, attemptID: UUID)
    case checkpointRestore(threadID: UUID, operationID: UUID)
    case conversationHistoryFiles(threadID: UUID, operationID: UUID, fileAttemptID: UUID)
    public var threadID: UUID? {
        switch self {
        case .projectClone, .pullRequestCreation, .pullRequestCheckout: nil
        case .promptSteering(let id, _), .conversationHistory(let id, _), .checkpointRestore(let id, _), .conversationHistoryFiles(let id, _, _): id
        case .conversationHistoryMaintenance(let id, _, _): id
        case .resolveRunCheckpoint(let id, _, _, _), .captureRunCheckpoint(let id, _, _, _), .resolveThreadScript(let id, _, _), .startThreadScript(let id, _, _), .resolveProjectScript(let id, _, _), .startProjectScript(let id, _, _), .resolveWorktree(let id, _), .prepareWorktree(let id, _), .providerStart(let id, _, _, _, _), .providerInterrupt(let id, _), .providerRespond(let id, _, _, _), .providerSessionRespond(let id, _, _, _): id
        }
    }
    var worktreeAttemptID: UUID? {
        switch self { case .resolveWorktree(_, let request): request.id; case .prepareWorktree(_, let plan): plan.id; default: nil }
    }
    var projectScriptRunID: UUID? {
        switch self { case .resolveProjectScript(_, _, let id), .resolveThreadScript(_, _, let id): id; case .startProjectScript(_, _, let plan), .startThreadScript(_, _, let plan): plan.id; default: nil }
    }
    var projectScriptOwner: ProjectScriptOwner? {
        switch self {
        case .resolveProjectScript(_, let id, _), .startProjectScript(_, let id, _): .setup(attemptID: id)
        case .resolveThreadScript(_, let owner, _), .startThreadScript(_, let owner, _): owner
        default: nil
        }
    }
    var checkpointOwner: (runID: UUID, stage: RunCheckpointStage, attemptID: UUID)? {
        switch self {
        case .resolveRunCheckpoint(_, let runID, let stage, let id): (runID, stage, id)
        case .captureRunCheckpoint(_, let runID, let stage, let plan): (runID, stage, plan.id)
        default: nil
        }
    }
    var pullRequestCreationOperationID: UUID? { if case .pullRequestCreation(_, let id, _) = self { id } else { nil } }
    var promptSteeringOperationID: UUID? { if case .promptSteering(_, let id) = self { id } else { nil } }
    var pullRequestCheckoutOperationID: UUID? { if case .pullRequestCheckout(_, let id, _) = self { id } else { nil } }
    var conversationHistoryOperationID: UUID? { if case .conversationHistory(_, let id) = self { id } else { nil } }
    var conversationHistoryMaintenanceOperationID: UUID? { if case .conversationHistoryMaintenance(_, let id, _) = self { id } else { nil } }
    var conversationHistoryFilesOperationID: UUID? { if case .conversationHistoryFiles(_, let id, _) = self { id } else { nil } }
    var checkpointRestoreOperationID: UUID? { if case .checkpointRestore(_, let id) = self { id } else { nil } }
    public var projectID: UUID? { switch self { case .projectClone(let id, _), .pullRequestCreation(let id, _, _), .pullRequestCheckout(let id, _, _): id; default: nil } }
    public var targetID: UUID {
        switch self {
        case .projectClone(let id, _), .pullRequestCreation(let id, _, _), .pullRequestCheckout(let id, _, _): id
        case .promptSteering(let id, _), .conversationHistory(let id, _), .checkpointRestore(let id, _), .conversationHistoryFiles(let id, _, _): id
        case .conversationHistoryMaintenance(let id, _, _): id
        case .resolveRunCheckpoint(let id, _, _, _), .captureRunCheckpoint(let id, _, _, _), .resolveThreadScript(let id, _, _), .startThreadScript(let id, _, _), .resolveProjectScript(let id, _, _), .startProjectScript(let id, _, _), .resolveWorktree(let id, _), .prepareWorktree(let id, _), .providerStart(let id, _, _, _, _), .providerInterrupt(let id, _), .providerRespond(let id, _, _, _), .providerSessionRespond(let id, _, _, _): id
        }
    }
}

public struct PendingWorkspaceEffect: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var request: WorkspaceEffectRequest
    public init(id: UUID = UUID(), request: WorkspaceEffectRequest) { self.id = id; self.request = request }
}

public enum WorkspaceEffectStatus: String, Codable, Sendable { case pending, running, succeeded, failed, cancelled }

public struct WorkspaceEffect: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var commandID: UUID
    public var request: WorkspaceEffectRequest
    public var status: WorkspaceEffectStatus
    public var attemptCount: Int
    public var leaseOwner: UUID?
    public var leaseExpiresAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastError: String?
}
