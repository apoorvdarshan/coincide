import Foundation

public enum ProviderApprovalResponse: Codable, Sendable, Equatable {
    case decision(Bool)
    case answers([String: String])
}

public struct ProviderConfiguration: Codable, Sendable, Equatable {
    public var provider: ProviderKind
    public var workspacePath: String
    public var nativeThreadID: String?
    public var model: String
    public var permission: PermissionMode
    public init(thread: CodingThread) {
        provider = thread.provider; workspacePath = thread.workspacePath
        nativeThreadID = thread.providerThreadID; model = thread.model; permission = thread.permission
    }
}

/// Process-bound actions are never replayed automatically after losing their runtime.
public enum WorkspaceEffectRequest: Codable, Sendable, Equatable {
    case providerStart(threadID: UUID, runID: UUID, configuration: ProviderConfiguration, prompt: String)
    case providerInterrupt(threadID: UUID, runID: UUID)
    case providerRespond(threadID: UUID, runID: UUID, request: ApprovalRequest, response: ProviderApprovalResponse)
    public var threadID: UUID {
        switch self {
        case .providerStart(let id, _, _, _), .providerInterrupt(let id, _), .providerRespond(let id, _, _, _): id
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
