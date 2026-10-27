import Foundation

/// Working tree state of a repository, as `git status --porcelain=2` reports it.
public struct GitStatus: Sendable, Hashable {
    public var isRepository: Bool
    /// Top of the work tree the status was read from.
    public var rootPath: String?
    /// Checked-out branch; nil while HEAD is detached.
    public var branch: String?
    /// HEAD commit; nil before the first commit.
    public var headOID: String?
    /// Upstream such as `origin/main`.
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    /// Commits on this branch that its base branch does not have.
    public var aheadOfDefault: Int
    public var defaultBranch: String?
    public var isDefaultBranch: Bool
    /// Whether the repository has a remote to push to.
    public var hasRemote: Bool
    public var files: [ChangedFile]
    public var conflictedPaths: [String]

    public nonisolated init(
        isRepository: Bool, rootPath: String? = nil, branch: String? = nil, headOID: String? = nil,
        upstream: String? = nil, ahead: Int = 0, behind: Int = 0, aheadOfDefault: Int = 0, defaultBranch: String? = nil,
        isDefaultBranch: Bool = false, hasRemote: Bool = false, files: [ChangedFile] = [], conflictedPaths: [String] = []
    ) {
        self.isRepository = isRepository
        self.rootPath = rootPath
        self.branch = branch
        self.headOID = headOID
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.aheadOfDefault = aheadOfDefault
        self.defaultBranch = defaultBranch
        self.isDefaultBranch = isDefaultBranch
        self.hasRemote = hasRemote
        self.files = files
        self.conflictedPaths = conflictedPaths
    }

    public nonisolated static let notRepository = GitStatus(isRepository: false)

    public nonisolated var hasChanges: Bool { !files.isEmpty }
    public nonisolated var hasUpstream: Bool { upstream != nil }
    public nonisolated var insertions: Int { files.reduce(0) { $0 + $1.additions } }
    public nonisolated var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

/// A local or remote-tracking branch.
public struct GitBranch: Sendable, Hashable, Identifiable {
    /// `main` for a local branch, `origin/main` for a remote-tracking one.
    public var name: String
    public var isRemote: Bool
    public var remoteName: String?
    public var isCurrent: Bool
    public var isDefault: Bool
    public var upstream: String?
    /// Work tree that has this branch checked out, other than the one being asked about.
    public var worktreePath: String?
    public var lastCommitDate: Date?

    public nonisolated init(
        name: String, isRemote: Bool = false, remoteName: String? = nil, isCurrent: Bool = false, isDefault: Bool = false,
        upstream: String? = nil, worktreePath: String? = nil, lastCommitDate: Date? = nil
    ) {
        self.name = name
        self.isRemote = isRemote
        self.remoteName = remoteName
        self.isCurrent = isCurrent
        self.isDefault = isDefault
        self.upstream = upstream
        self.worktreePath = worktreePath
        self.lastCommitDate = lastCommitDate
    }

    public nonisolated var id: String { (isRemote ? "remote/" : "local/") + name }

    /// The local branch name a checkout of this branch creates or uses.
    public nonisolated var localName: String {
        guard isRemote else { return name }
        if let remoteName, name.hasPrefix(remoteName + "/") { return String(name.dropFirst(remoteName.count + 1)) }
        return BranchNames.localName(fromRemoteRef: name)
    }
}

public struct GitBranchList: Sendable, Hashable {
    public var isRepository: Bool
    /// Current branch first, then the default branch, then by most recent commit.
    public var branches: [GitBranch]
    public var currentBranch: String?
    public var defaultBranch: String?
    public var hasRemote: Bool

    public nonisolated init(
        isRepository: Bool, branches: [GitBranch] = [], currentBranch: String? = nil, defaultBranch: String? = nil,
        hasRemote: Bool = false
    ) {
        self.isRepository = isRepository
        self.branches = branches
        self.currentBranch = currentBranch
        self.defaultBranch = defaultBranch
        self.hasRemote = hasRemote
    }

    public nonisolated var local: [GitBranch] { branches.filter { !$0.isRemote } }
    public nonisolated var remote: [GitBranch] { branches.filter(\.isRemote) }
}

public struct GitWorktree: Sendable, Hashable, Identifiable {
    public var path: String
    public var branch: String?
    public var head: String?
    public var isMain: Bool
    public var isPrunable: Bool
    public var isLocked: Bool

    public nonisolated init(
        path: String, branch: String? = nil, head: String? = nil, isMain: Bool = false, isPrunable: Bool = false,
        isLocked: Bool = false
    ) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.isPrunable = isPrunable
        self.isLocked = isLocked
    }

    public nonisolated var id: String { path }
}

public struct GitCommit: Sendable, Hashable {
    public var sha: String
    public var subject: String

    public nonisolated init(sha: String, subject: String) {
        self.sha = sha
        self.subject = subject
    }

    public nonisolated var shortSHA: String { String(sha.prefix(7)) }
}

public struct GitPushResult: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        case pushed
        case upToDate
    }

    public var outcome: Outcome
    public var branch: String
    /// Where the branch was pushed, such as `origin/feature`.
    public var upstream: String?
    public var setUpstream: Bool

    public nonisolated init(outcome: Outcome, branch: String, upstream: String? = nil, setUpstream: Bool = false) {
        self.outcome = outcome
        self.branch = branch
        self.upstream = upstream
        self.setUpstream = setUpstream
    }
}

public enum GitPullResult: Sendable, Hashable {
    case pulled
    case upToDate
}

public struct GitPullRequest: Sendable, Hashable, Codable {
    public enum State: String, Sendable, Codable {
        case open = "OPEN"
        case closed = "CLOSED"
        case merged = "MERGED"
    }

    public var number: Int
    public var url: String
    public var title: String
    public var state: State
    public var baseBranch: String
    public var headBranch: String
    public var isDraft: Bool

    public nonisolated init(
        number: Int, url: String, title: String, state: State, baseBranch: String, headBranch: String,
        isDraft: Bool = false
    ) {
        self.number = number
        self.url = url
        self.title = title
        self.state = state
        self.baseBranch = baseBranch
        self.headBranch = headBranch
        self.isDraft = isDraft
    }

    enum CodingKeys: String, CodingKey {
        case number
        case url
        case title
        case state
        case baseBranch = "baseRefName"
        case headBranch = "headRefName"
        case isDraft
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        state = (try? container.decode(State.self, forKey: .state)) ?? .open
        baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch) ?? ""
        headBranch = try container.decodeIfPresent(String.self, forKey: .headBranch) ?? ""
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
    }
}

/// A parsed unified diff for one file.
public struct FileDiff: Sendable, Hashable, Identifiable {
    public var path: String
    public var oldPath: String?
    public var status: ChangedFile.Status
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool
    /// Mode change, such as `100644 → 100755`, when there is one.
    public var modeChange: String?
    public var hunks: [DiffHunk]

    public nonisolated init(
        path: String, oldPath: String? = nil, status: ChangedFile.Status, additions: Int = 0, deletions: Int = 0,
        isBinary: Bool = false, modeChange: String? = nil, hunks: [DiffHunk] = []
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.modeChange = modeChange
        self.hunks = hunks
    }

    public nonisolated var id: String { path }
    public nonisolated var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }

    public nonisolated var changedFile: ChangedFile {
        ChangedFile(path: path, oldPath: oldPath, status: status, additions: additions, deletions: deletions)
    }
}

public struct DiffHunk: Sendable, Hashable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Text after the second `@@`, usually the enclosing function.
    public var section: String
    public var lines: [DiffLine]

    public nonisolated init(
        oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String = "", lines: [DiffLine] = []
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }

    public nonisolated var header: String {
        let range = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        return section.isEmpty ? range : "\(range) \(section)"
    }
}

public struct DiffLine: Sendable, Hashable {
    public enum Kind: UInt8, Sendable {
        case context
        case addition
        case deletion
        /// `\ No newline at end of file`.
        case noNewline
    }

    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?

    public nonisolated init(kind: Kind, text: String, oldLine: Int? = nil, newLine: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

/// Changes in one scope (working tree, branch or turn), with the patch split per file.
public struct GitDiff: Sendable, Hashable {
    public var files: [FileDiff]
    /// True when the patch was cut short and some files lack hunks.
    public var isTruncated: Bool
    /// Label for what the changes are compared against, such as `HEAD` or `main`.
    public var baseLabel: String?

    public nonisolated init(files: [FileDiff] = [], isTruncated: Bool = false, baseLabel: String? = nil) {
        self.files = files
        self.isTruncated = isTruncated
        self.baseLabel = baseLabel
    }

    public nonisolated static let empty = GitDiff()

    public nonisolated var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public nonisolated var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}
