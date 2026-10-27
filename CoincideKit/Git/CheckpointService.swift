import Foundation

public struct ChangedFile: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Codable {
        case added
        case modified
        case deleted
        case renamed
        case untracked
    }

    public var path: String
    public var oldPath: String?
    public var status: Status
    public var additions: Int
    public var deletions: Int

    public nonisolated init(path: String, oldPath: String? = nil, status: Status, additions: Int = 0, deletions: Int = 0) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

// STUB: replaced by the real git-backed checkpoints.
/// Snapshots the working tree around each turn so a turn's changes can be shown and reverted.
@MainActor
public final class CheckpointService {
    public static let shared = CheckpointService()

    public init() {}

    /// Records the working tree before a turn starts.
    public func captureBeforeTurn(threadID: UUID, userItemID: UUID, cwd: URL) async {}

    /// Records the working tree after a turn ends.
    public func captureAfterTurn(threadID: UUID, userItemID: UUID, cwd: URL) async {}

    /// Files the turn changed, once both snapshots exist.
    public func changedFiles(threadID: UUID, userItemID: UUID) -> [ChangedFile] { [] }

    /// Unified diff of the turn's changes.
    public func turnDiff(threadID: UUID, userItemID: UUID) async -> String? { nil }

    public func canRestore(threadID: UUID, userItemID: UUID) -> Bool { false }

    /// Restores the working tree to how it was before the turn started.
    public func restore(threadID: UUID, toBefore userItemID: UUID) async throws {}
}
