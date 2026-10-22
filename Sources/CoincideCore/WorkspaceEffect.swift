import Foundation

public enum ProviderApprovalResponse: Codable, Sendable, Equatable {
    case decision(Bool)
    case answers([String: String])
    case option(String)
}

public struct ProviderConfiguration: Codable, Sendable, Equatable {
    public var provider: ProviderKind
    public var workspacePath: String
    public var nativeThreadID: String?
    public var model: String
    public var permission: PermissionMode
    public var acpAgent: ACPAgentConfiguration?
    public var agentModeID: String?
    public var agentConfigValues: [String: String]?
    public var agentConfiguration: [String: JSONValue]?
    public init(thread: CodingThread) {
        provider = thread.provider; workspacePath = thread.workspacePath
        nativeThreadID = thread.providerThreadID; model = thread.model; permission = thread.permission
        acpAgent = thread.acpAgent; agentModeID = thread.agentModeID
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
    case projectClone(projectID: UUID, plan: GitClonePlan)
    case resolveWorktree(threadID: UUID, request: GitWorktreeRequest)
    case prepareWorktree(threadID: UUID, plan: GitWorktreePlan)
    case resolveProjectScript(threadID: UUID, attemptID: UUID, runID: UUID)
    case startProjectScript(threadID: UUID, attemptID: UUID, plan: ProjectScriptExecutionPlan)
    case resolveThreadScript(threadID: UUID, owner: ProjectScriptOwner, runID: UUID)
    case startThreadScript(threadID: UUID, owner: ProjectScriptOwner, plan: ProjectScriptExecutionPlan)
    public var threadID: UUID? {
        switch self {
        case .projectClone: nil
        case .resolveThreadScript(let id, _, _), .startThreadScript(let id, _, _), .resolveProjectScript(let id, _, _), .startProjectScript(let id, _, _), .resolveWorktree(let id, _), .prepareWorktree(let id, _), .providerStart(let id, _, _, _, _), .providerInterrupt(let id, _), .providerRespond(let id, _, _, _), .providerSessionRespond(let id, _, _, _): id
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
    public var projectID: UUID? { if case .projectClone(let id, _) = self { id } else { nil } }
    public var targetID: UUID {
        switch self {
        case .projectClone(let id, _): id
        case .resolveThreadScript(let id, _, _), .startThreadScript(let id, _, _), .resolveProjectScript(let id, _, _), .startProjectScript(let id, _, _), .resolveWorktree(let id, _), .prepareWorktree(let id, _), .providerStart(let id, _, _, _, _), .providerInterrupt(let id, _), .providerRespond(let id, _, _, _), .providerSessionRespond(let id, _, _, _): id
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
