import Foundation

public enum RemoteEnvironmentProtocol {
    public static let version = 1
    public static let maximumFrameBytes = 16 * 1_024 * 1_024
    public static let maximumRequestBytes = 1 * 1_024 * 1_024
    /// A native 2 MB text file may require six JSON bytes per input byte.
    public static let maximumWorkspaceRequestBytes = 14 * 1_024 * 1_024
    public static let maximumQueuedRequestBytes = 32 * 1_024 * 1_024
    public static let maximumPendingRequests = 32
    public static let describeMethod = "remoteEnvironment.describe"
    public static let snapshotMethod = "remoteEnvironment.snapshot"
    public static let commandMethod = "remoteEnvironment.command"
    public static let receiptMethod = "remoteEnvironment.receipt"
    public static let subscribeMethod = "remoteEnvironment.subscribe"
    public static let closeMethod = "remoteEnvironment.close"
    public static let snapshotNotification = "remoteEnvironment.snapshotChanged"
    public static let workspaceBindMethod = "remoteEnvironment.workspace.bind"
    public static let workspaceReadMethod = "remoteEnvironment.workspace.read"
    public static let workspaceBeginMethod = "remoteEnvironment.workspace.begin"
    public static let workspaceOperationMethod = "remoteEnvironment.workspace.operation"
    public static let workspaceCancelMethod = "remoteEnvironment.workspace.cancel"
    public static let terminalOpenMethod = "remoteEnvironment.terminal.open"
    public static let terminalAttachMethod = "remoteEnvironment.terminal.attach"
    public static let terminalReadMethod = "remoteEnvironment.terminal.read"
    public static let terminalWriteMethod = "remoteEnvironment.terminal.write"
    public static let terminalInputReceiptMethod = "remoteEnvironment.terminal.inputReceipt"
    public static let terminalResizeMethod = "remoteEnvironment.terminal.resize"
    public static let terminalCloseMethod = "remoteEnvironment.terminal.close"
    public static let terminalListMethod = "remoteEnvironment.terminal.list"
    public static let worktreeCatalogMethod = "remoteEnvironment.worktree.catalog"
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= maximumFrameBytes else { throw RemoteEnvironmentError(.limitExceeded) }
        return try JSONDecoder().decode(JSONValue.self, from: bytes)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= maximumFrameBytes else { throw RemoteEnvironmentError(.limitExceeded) }
        do { return try JSONDecoder().decode(type, from: bytes) }
        catch { throw RemoteEnvironmentError(.invalidRequest) }
    }
    static func payload(_ request: RemoteEnvironmentCommandRequest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(request)
        guard bytes.count <= maximumRequestBytes else { throw RemoteEnvironmentError(.limitExceeded) }
        return bytes
    }
}

public struct RemoteEnvironmentCapabilities: Codable, Sendable, Equatable {
    public let providers: [ProviderKind]
    public let supportsCommandReceipts: Bool
    public let supportsSubscriptions: Bool
    public let supportsProjectRegistration: Bool
    public let supportsConversationCreation: Bool
    public let supportsExactRunStop: Bool
    public let supportsRequestResponses: Bool
    public let persistentDaemon: Bool
    public let supportsWorkspaceFilesAndGit: Bool
    public let supportsRemoteTerminal: Bool
    public let supportsRemoteWorktrees: Bool
    public let supportsRemoteAttachments: Bool
    public let supportsRemotePullRequests: Bool
    public init(providers: [ProviderKind] = [.codex, .claude], supportsRemoteTerminal: Bool = false) {
        self.providers = providers; supportsCommandReceipts = true; supportsSubscriptions = true
        supportsProjectRegistration = true; supportsConversationCreation = true
        supportsExactRunStop = true; supportsRequestResponses = true; persistentDaemon = false
        supportsWorkspaceFilesAndGit = true
        self.supportsRemoteTerminal = supportsRemoteTerminal
        supportsRemoteWorktrees = true
        supportsRemoteAttachments = true
        supportsRemotePullRequests = true
    }
    private enum CodingKeys: String, CodingKey {
        case providers, supportsCommandReceipts, supportsSubscriptions, supportsProjectRegistration, supportsConversationCreation
        case supportsExactRunStop, supportsRequestResponses, persistentDaemon, supportsWorkspaceFilesAndGit, supportsRemoteTerminal, supportsRemoteWorktrees, supportsRemoteAttachments, supportsRemotePullRequests
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        providers = try values.decode([ProviderKind].self, forKey: .providers)
        supportsCommandReceipts = try values.decode(Bool.self, forKey: .supportsCommandReceipts)
        supportsSubscriptions = try values.decode(Bool.self, forKey: .supportsSubscriptions)
        supportsProjectRegistration = try values.decode(Bool.self, forKey: .supportsProjectRegistration)
        supportsConversationCreation = try values.decode(Bool.self, forKey: .supportsConversationCreation)
        supportsExactRunStop = try values.decode(Bool.self, forKey: .supportsExactRunStop)
        supportsRequestResponses = try values.decode(Bool.self, forKey: .supportsRequestResponses)
        persistentDaemon = try values.decode(Bool.self, forKey: .persistentDaemon)
        supportsWorkspaceFilesAndGit = try values.decodeIfPresent(Bool.self, forKey: .supportsWorkspaceFilesAndGit) ?? false
        supportsRemoteTerminal = try values.decodeIfPresent(Bool.self, forKey: .supportsRemoteTerminal) ?? false
        supportsRemoteWorktrees = try values.decodeIfPresent(Bool.self, forKey: .supportsRemoteWorktrees) ?? false
        supportsRemoteAttachments = try values.decodeIfPresent(Bool.self, forKey: .supportsRemoteAttachments) ?? false
        supportsRemotePullRequests = try values.decodeIfPresent(Bool.self, forKey: .supportsRemotePullRequests) ?? false
    }
}
public struct RemoteEnvironmentDescriptor: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public let protocolVersion: Int
    public let label: String
    public let capabilities: RemoteEnvironmentCapabilities
    public init(environmentID: UUID, protocolVersion: Int = RemoteEnvironmentProtocol.version, label: String,
                capabilities: RemoteEnvironmentCapabilities = .init()) {
        self.environmentID = environmentID; self.protocolVersion = protocolVersion
        self.label = label; self.capabilities = capabilities
    }
}
public struct RemoteEnvironmentSnapshotRequest: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public let afterSequence: Int64?
    public init(environmentID: UUID, afterSequence: Int64? = nil) { self.environmentID = environmentID; self.afterSequence = afterSequence }
}
public struct RemoteEnvironmentSnapshot: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public let sequence: Int64
    public let workspace: WorkspaceSnapshot
    public init(environmentID: UUID, sequence: Int64, workspace: WorkspaceSnapshot) {
        self.environmentID = environmentID; self.sequence = sequence; self.workspace = workspace
    }
}
public enum RemoteEnvironmentThreadEdit: Codable, Sendable, Equatable {
    case draft(String), title(String), model(String), permission(PermissionMode)
}
/// A closed client command surface. Native launch paths, internal effects and
/// provider events can never be supplied by a remote command.
public indirect enum RemoteEnvironmentCommand: Codable, Sendable, Equatable {
    case addProject(id: UUID, path: String, title: String?)
    case createThread(id: UUID, projectID: UUID, provider: ProviderKind, title: String, model: String, permission: PermissionMode)
    case editThread(threadID: UUID, edit: RemoteEnvironmentThreadEdit, expectedConfiguration: ProviderConfiguration)
    case submit(threadID: UUID, text: String, expectedConfiguration: ProviderConfiguration)
    case submitWithAttachments(target: RemoteAttachmentTarget, text: String, expectedConfiguration: ProviderConfiguration, expectedDraftAttachments: [ChatAttachment], uploadedAttachmentIDs: [UUID])
    case pullRequest(target: RemoteWorkspaceTarget, action: RemotePullRequestAction)
    case stop(threadID: UUID, runID: UUID, runtimeID: UUID)
    case respond(threadID: UUID, runID: UUID?, runtimeID: UUID, request: ApprovalRequest, response: ProviderApprovalResponse)
    case resumeQueue(threadID: UUID, expectedConfiguration: ProviderConfiguration)
    case prepareWorktree(target: RemoteWorkspaceTarget, sourceRootID: UUID, expectedAttemptID: UUID?, selection: GitWorktreeSelection, submodules: ProjectWorktreeSubmoduleMode)
    case retryWorktree(target: RemoteWorkspaceTarget, attemptID: UUID)
    case cancelWorktree(target: RemoteWorkspaceTarget, attemptID: UUID)
    case inspectWorktree(target: RemoteWorkspaceTarget, attemptID: UUID)
}
public struct RemoteEnvironmentCommandRequest: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public let id: UUID
    public let command: RemoteEnvironmentCommand
    public init(environmentID: UUID, id: UUID = UUID(), command: RemoteEnvironmentCommand) {
        self.environmentID = environmentID; self.id = id; self.command = command
    }
}
public struct RemoteEnvironmentCommandResult: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public let receipt: WorkspaceCommandReceipt
    public init(environmentID: UUID, receipt: WorkspaceCommandReceipt) { self.environmentID = environmentID; self.receipt = receipt }
}
public struct RemoteEnvironmentReceiptResult: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public let receipt: WorkspaceCommandReceipt?
    public init(environmentID: UUID, receipt: WorkspaceCommandReceipt?) { self.environmentID = environmentID; self.receipt = receipt }
}
public struct RemoteEnvironmentError: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Codable, Sendable { case invalidRequest, wrongEnvironment, unavailable, limitExceeded, identityInvalid, unsupported, commandCollision }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidRequest: "The remote workspace request is invalid."
        case .wrongEnvironment: "This connection reaches a different Coincide environment."
        case .unavailable: "The remote workspace is unavailable."
        case .limitExceeded: "The remote workspace exceeded a protocol limit."
        case .identityInvalid: "The remote environment identity is missing, corrupt, or unsafe."
        case .unsupported: "This remote workspace operation is unsupported."
        case .commandCollision: "The command identity is already bound to a different request."
        }
    }
}

public struct RemoteEnvironmentCloseResult: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public init(environmentID: UUID) { self.environmentID = environmentID }
}
