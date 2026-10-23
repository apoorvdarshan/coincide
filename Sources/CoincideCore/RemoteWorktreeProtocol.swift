import Foundation

/// Catalog targets are bound on the host. Paths in this inventory are remote
/// paths and must never be resolved against the client filesystem.
public struct RemoteWorktreeCatalogRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public init(target: RemoteWorkspaceTarget) { self.target = target }
}

public struct RemoteWorktreeCatalog: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let sourcePath: String
    public let sourceRootID: UUID
    public let attemptID: UUID?
    public let branches: [GitBranch]
    public let worktrees: [GitWorktree]
    public init(target: RemoteWorkspaceTarget, sourcePath: String, sourceRootID: UUID, attemptID: UUID?, branches: [GitBranch], worktrees: [GitWorktree]) {
        self.target = target; self.sourcePath = sourcePath; self.sourceRootID = sourceRootID; self.attemptID = attemptID
        self.branches = branches; self.worktrees = worktrees
    }
}

/// These values can only be captured by the native host, never decoded from a
/// remote command. The original external command remains the journal payload.
struct RemoteWorktreePreparation: Codable, Sendable {
    let threadID: UUID
    let incarnation: UUID
    let expectedWorkspacePath: String
    let expectedAttemptID: UUID?
    let request: GitWorktreeRequest?
    let result: GitWorktreeResult?
    let claudeRuntimeConfiguration: ClaudeRuntimeConfiguration?
}

extension RemoteEnvironmentCommand {
    var isWorktreeCommand: Bool {
        switch self { case .prepareWorktree, .retryWorktree, .cancelWorktree, .inspectWorktree: true
        default: false }
    }
    var inspectsWorktreeCompletion: Bool {
        switch self { case .retryWorktree, .inspectWorktree: true
        default: false }
    }
}
