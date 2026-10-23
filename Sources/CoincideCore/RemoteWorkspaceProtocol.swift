import Foundation

/// Configuration is carried for source compatibility; only its workspace path
/// identifies the file/Git target. Model and permission changes keep the editor.
public struct RemoteWorkspaceTarget: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public let projectID: UUID
    public let threadID: UUID
    public let configuration: ProviderConfiguration
    public let rootID: UUID?
    public var workspacePath: String { configuration.workspacePath }
    public init(environmentID: UUID, projectID: UUID, threadID: UUID, configuration: ProviderConfiguration, rootID: UUID? = nil) {
        self.environmentID = environmentID; self.projectID = projectID; self.threadID = threadID
        self.configuration = configuration; self.rootID = rootID
    }
}
public enum RemoteWorkspaceQuery: Codable, Sendable, Equatable {
    case list(directoryPath: String)
    case searchPaths(query: String, limit: Int)
    case searchContents(query: String, limit: Int, caseSensitive: Bool, wholeWord: Bool, useRegex: Bool)
    case readFile(path: String, allowMissing: Bool, maxBytes: Int)
    case gitStatus
    case gitDiff(file: ChangedFile?, staged: Bool)
    case gitBranches
    case gitRemotes
}
public struct RemoteWorkspaceReadRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let query: RemoteWorkspaceQuery
    public init(target: RemoteWorkspaceTarget, query: RemoteWorkspaceQuery) { self.target = target; self.query = query }
}
public struct RemoteWorkspaceDocument: Codable, Sendable, Equatable {
    public let relativePath: String
    public let contents: String
    public let byteLength: Int
    public let truncated: Bool
    public let exists: Bool
    /// Opaque host-issued revision; never accepts a client-authored inode/hash.
    public let revision: UUID?
    public init(relativePath: String, contents: String, byteLength: Int, truncated: Bool, exists: Bool, revision: UUID?) {
        self.relativePath = relativePath; self.contents = contents; self.byteLength = byteLength
        self.truncated = truncated; self.exists = exists; self.revision = revision
    }
}
public enum RemoteWorkspaceValue: Codable, Sendable, Equatable {
    case entries(WorkspaceEntryPage), contents(WorkspaceContentSearchResult), document(RemoteWorkspaceDocument)
    case git(GitSnapshot), diff(String), branches([GitBranch]), remotes([String]), done
}
public struct RemoteWorkspaceReadResult: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let value: RemoteWorkspaceValue
    public init(target: RemoteWorkspaceTarget, value: RemoteWorkspaceValue) { self.target = target; self.value = value }
}
public enum RemoteWorkspaceMutation: Codable, Sendable, Equatable {
    case createFile(path: String, contents: String)
    case saveFile(path: String, contents: String, revision: UUID)
    case gitInitialize(branch: String)
    case gitStage(paths: [String]), gitUnstage(paths: [String])
    case gitCommit(message: String)
    case gitCheckout(branch: String)
    case gitCreateBranch(branch: String, tracking: String?)
    case gitFetch(remote: String)
    case gitPull(branch: String)
    case gitPush(branch: String, remote: String, remoteBranch: String, setUpstream: Bool)
}
public struct RemoteWorkspaceMutationRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let target: RemoteWorkspaceTarget
    public let mutation: RemoteWorkspaceMutation
    public init(id: UUID = UUID(), target: RemoteWorkspaceTarget, mutation: RemoteWorkspaceMutation) {
        self.id = id; self.target = target; self.mutation = mutation
    }
}
public struct RemoteWorkspaceFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Codable, Sendable { case invalidTarget, staleRoot, invalidRequest, conflict, unavailable, interrupted, operationFailed, busy, limitExceeded, commandCollision }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidTarget: "The remote workspace target changed or is unavailable."
        case .staleRoot: "The remote workspace folder changed. Reopen it before continuing."
        case .invalidRequest: "The remote workspace operation is invalid."
        case .conflict: "The remote file changed. Reload it before saving."
        case .unavailable: "The remote workspace service is unavailable."
        case .interrupted: "The operation was interrupted. Inspect its result; it will not be repeated."
        case .operationFailed: "The remote operation failed. Inspect the files or Git status before continuing."
        case .busy: "Another operation owns this remote workspace."
        case .limitExceeded: "The remote workspace operation exceeded a limit."
        case .commandCollision: "This operation identity is bound to a different exact request."
        }
    }
}
public struct RemoteWorkspaceOperation: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case accepted, running, finished, uncertain }
    public let request: RemoteWorkspaceMutationRequest
    public let payloadDigest: String
    public var state: State
    public var result: RemoteWorkspaceValue?
    public var failure: RemoteWorkspaceFailure?
    public let createdAt: Date
    public var updatedAt: Date
    public var id: UUID { request.id }
    public var target: RemoteWorkspaceTarget { request.target }
}
