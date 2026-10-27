// A copy of `ChangedFile` from CoincideKit/Git/CheckpointService.swift, which GitModels.swift and
// GitParsing.swift need. CheckpointService.swift itself cannot be built here: it depends on the app
// store and the git process runner. Everything from `public struct ChangedFile` to its closing brace
// must match the original exactly; `Fuzz/fuzz.sh check` (run by the Fuzz workflow) fails when it
// drifts. Delete this file once `ChangedFile` moves into GitModels.swift.
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
