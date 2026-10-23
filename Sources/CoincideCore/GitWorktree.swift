import Foundation

public enum GitWorktreeSelection: Codable, Sendable, Equatable {
    case createBranch(name: String, baseRef: String)
    case existingBranch(name: String)
    case reuse(path: String)
}

public struct GitWorktreeRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let sourcePath: String
    public let destinationRoot: String
    public let selection: GitWorktreeSelection
    public let submodules: ProjectWorktreeSubmoduleMode
    public let expectedSourceIdentity: GitWorktreeNodeIdentity?
    public let automaticBase: GitWorktreeAutomaticBase?
    public init(id: UUID = UUID(), sourcePath: String, destinationRoot: String, selection: GitWorktreeSelection,
                submodules: ProjectWorktreeSubmoduleMode = .none, expectedSourceIdentity: GitWorktreeNodeIdentity? = nil, automaticBase: GitWorktreeAutomaticBase? = nil) {
        self.id = id; self.sourcePath = sourcePath; self.destinationRoot = destinationRoot; self.selection = selection
        self.submodules = submodules
        self.expectedSourceIdentity = expectedSourceIdentity; self.automaticBase = automaticBase
    }
    public var destinationPath: String {
        if case .reuse(let path) = selection { return path }
        return destinationRoot + "/" + id.uuidString
    }
    public func validate() throws {
        try WorktreeValidation.path(sourcePath); try WorktreeValidation.path(destinationRoot)
        if let expectedSourceIdentity, expectedSourceIdentity.inode == 0 { throw WorktreeValidation.invalid("The worktree source identity is invalid.") }
        if let automaticBase {
            try automaticBase.sourceProof.validate(); try WorktreeValidation.branch(automaticBase.branch)
            guard case .createBranch = selection,
                  expectedSourceIdentity == automaticBase.sourceProof.sourceIdentity else {
                throw WorktreeValidation.invalid("The automatic base is not owned by this source checkout.")
            }
        }
        switch selection {
        case .createBranch(let name, let baseRef):
            try WorktreeValidation.branch(name)
            guard !baseRef.isEmpty, baseRef.utf16.count <= 1_024, !baseRef.hasPrefix("-"),
                  !baseRef.contains("://"), !["http:", "https:", "ssh:", "git:", "file:", "ext::"].contains(where: { baseRef.lowercased().hasPrefix($0) }),
                  baseRef.range(of: #"^[^/\s]+@[^/\s:]+:"#, options: .regularExpression) == nil,
                  !baseRef.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else { throw WorktreeValidation.invalid("Choose an explicit local base ref or commit.") }
        case .existingBranch(let name): try WorktreeValidation.branch(name)
        case .reuse(let path):
            try WorktreeValidation.path(path)
            guard submodules == .none else { throw WorktreeValidation.invalid("Registered-worktree reuse does not initialize or change its submodules.") }
        }
    }
    private enum CodingKeys: String, CodingKey { case id, sourcePath, destinationRoot, selection, submodules, expectedSourceIdentity, automaticBase }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), sourcePath: try c.decode(String.self, forKey: .sourcePath),
                  destinationRoot: try c.decode(String.self, forKey: .destinationRoot), selection: try c.decode(GitWorktreeSelection.self, forKey: .selection),
                  submodules: c.contains(.submodules) ? try c.decode(ProjectWorktreeSubmoduleMode.self, forKey: .submodules) : .none,
                  expectedSourceIdentity: try c.decodeIfPresent(GitWorktreeNodeIdentity.self, forKey: .expectedSourceIdentity),
                  automaticBase: try c.decodeIfPresent(GitWorktreeAutomaticBase.self, forKey: .automaticBase))
        try validate()
    }
}

public struct GitWorktreeNodeIdentity: Codable, Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}

public struct GitWorktree: Identifiable, Codable, Sendable, Equatable {
    public let path: String
    public let headCommit: String?
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let lockedReason: String?
    public let prunableReason: String?
    public var id: String { path }
    public init(path: String, headCommit: String?, branch: String?, isBare: Bool, isDetached: Bool,
                lockedReason: String? = nil, prunableReason: String? = nil) {
        self.path = path; self.headCommit = headCommit; self.branch = branch; self.isBare = isBare; self.isDetached = isDetached
        self.lockedReason = lockedReason; self.prunableReason = prunableReason
    }
}

public struct GitWorktreeInventory: Codable, Sendable, Equatable {
    public let sourcePath: String
    public let commonDirectoryPath: String
    public let worktrees: [GitWorktree]
    public init(sourcePath: String, commonDirectoryPath: String, worktrees: [GitWorktree]) {
        self.sourcePath = sourcePath; self.commonDirectoryPath = commonDirectoryPath; self.worktrees = worktrees
    }
}

/// All filesystem identities are captured by read-only planning. New destination identity is
/// claimed durably at execution; explicit reuse instead captures its already registered nodes.
public struct GitWorktreePlan: Codable, Sendable, Equatable {
    public let request: GitWorktreeRequest
    public let sourcePath: String
    public let commonDirectoryPath: String
    public let sourceIdentity: GitWorktreeNodeIdentity
    public let commonDirectoryIdentity: GitWorktreeNodeIdentity
    public let destinationParentIdentity: GitWorktreeNodeIdentity
    public let sourceGitDirectoryPath: String
    public let sourceGitDirectoryIdentity: GitWorktreeNodeIdentity
    public let branch: String
    public let baseCommit: String
    public let destinationIdentity: GitWorktreeNodeIdentity?
    public let worktreeGitDirectoryPath: String?
    public let worktreeGitDirectoryIdentity: GitWorktreeNodeIdentity?
    public var id: UUID { request.id }
    public var destinationPath: String { request.destinationPath }
    public init(request: GitWorktreeRequest, sourcePath: String, commonDirectoryPath: String,
                sourceIdentity: GitWorktreeNodeIdentity, commonDirectoryIdentity: GitWorktreeNodeIdentity,
                destinationParentIdentity: GitWorktreeNodeIdentity, branch: String, baseCommit: String,
                destinationIdentity: GitWorktreeNodeIdentity? = nil, worktreeGitDirectoryPath: String? = nil,
                worktreeGitDirectoryIdentity: GitWorktreeNodeIdentity? = nil,
                sourceGitDirectoryPath: String? = nil, sourceGitDirectoryIdentity: GitWorktreeNodeIdentity? = nil) throws {
        self.request = request; self.sourcePath = sourcePath; self.commonDirectoryPath = commonDirectoryPath
        self.sourceIdentity = sourceIdentity; self.commonDirectoryIdentity = commonDirectoryIdentity
        self.destinationParentIdentity = destinationParentIdentity; self.branch = branch; self.baseCommit = baseCommit
        self.sourceGitDirectoryPath = sourceGitDirectoryPath ?? commonDirectoryPath
        self.sourceGitDirectoryIdentity = sourceGitDirectoryIdentity ?? commonDirectoryIdentity
        self.destinationIdentity = destinationIdentity; self.worktreeGitDirectoryPath = worktreeGitDirectoryPath
        self.worktreeGitDirectoryIdentity = worktreeGitDirectoryIdentity
        try validate()
    }
    public func validate() throws {
        try request.validate(); try WorktreeValidation.path(sourcePath); try WorktreeValidation.path(commonDirectoryPath)
        try WorktreeValidation.path(sourceGitDirectoryPath)
        try WorktreeValidation.branch(branch); try WorktreeValidation.commit(baseCommit)
        guard sourceIdentity.inode != 0, commonDirectoryIdentity.inode != 0, destinationParentIdentity.inode != 0,
              request.expectedSourceIdentity == nil || request.expectedSourceIdentity == sourceIdentity,
              sourceGitDirectoryIdentity.inode != 0,
              sourceGitDirectoryPath == commonDirectoryPath || sourceGitDirectoryPath.hasPrefix(commonDirectoryPath + "/worktrees/") else { throw WorktreeValidation.invalid("The worktree plan is missing filesystem ownership.") }
        switch request.selection {
        case .reuse:
            guard let destinationIdentity, destinationIdentity.inode != 0,
                  let worktreeGitDirectoryPath, let worktreeGitDirectoryIdentity, worktreeGitDirectoryIdentity.inode != 0 else { throw WorktreeValidation.invalid("The registered worktree plan is missing checkout ownership.") }
            try WorktreeValidation.path(worktreeGitDirectoryPath)
        case .createBranch(let name, _), .existingBranch(let name):
            guard branch == name, destinationIdentity == nil, worktreeGitDirectoryPath == nil, worktreeGitDirectoryIdentity == nil else { throw WorktreeValidation.invalid("The worktree plan does not match its requested branch.") }
        }
    }
    private enum CodingKeys: String, CodingKey { case request, sourcePath, commonDirectoryPath, sourceIdentity, commonDirectoryIdentity, destinationParentIdentity, branch, baseCommit, destinationIdentity, worktreeGitDirectoryPath, worktreeGitDirectoryIdentity, sourceGitDirectoryPath, sourceGitDirectoryIdentity }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(request: c.decode(GitWorktreeRequest.self, forKey: .request), sourcePath: c.decode(String.self, forKey: .sourcePath),
                      commonDirectoryPath: c.decode(String.self, forKey: .commonDirectoryPath), sourceIdentity: c.decode(GitWorktreeNodeIdentity.self, forKey: .sourceIdentity),
                      commonDirectoryIdentity: c.decode(GitWorktreeNodeIdentity.self, forKey: .commonDirectoryIdentity), destinationParentIdentity: c.decode(GitWorktreeNodeIdentity.self, forKey: .destinationParentIdentity),
                      branch: c.decode(String.self, forKey: .branch), baseCommit: c.decode(String.self, forKey: .baseCommit), destinationIdentity: c.decodeIfPresent(GitWorktreeNodeIdentity.self, forKey: .destinationIdentity),
                      worktreeGitDirectoryPath: c.decodeIfPresent(String.self, forKey: .worktreeGitDirectoryPath), worktreeGitDirectoryIdentity: c.decodeIfPresent(GitWorktreeNodeIdentity.self, forKey: .worktreeGitDirectoryIdentity),
                      sourceGitDirectoryPath: c.decodeIfPresent(String.self, forKey: .sourceGitDirectoryPath), sourceGitDirectoryIdentity: c.decodeIfPresent(GitWorktreeNodeIdentity.self, forKey: .sourceGitDirectoryIdentity))
    }
}

public struct GitWorktreeResult: Codable, Sendable, Equatable {
    public static let submoduleFailureWarning = "Some submodules could not be initialized. The checkout is available; use Terminal to inspect or finish initialization."
    public let destinationPath: String
    public let headCommit: String
    public let branch: String?
    public let submoduleWarning: String?
    public init(destinationPath: String, headCommit: String, branch: String?, submoduleWarning: String? = nil) {
        self.destinationPath = destinationPath; self.headCommit = headCommit; self.branch = branch; self.submoduleWarning = submoduleWarning
    }
    public func validate() throws {
        try WorktreeValidation.path(destinationPath); try WorktreeValidation.commit(headCommit)
        if let branch { try WorktreeValidation.branch(branch) }
        guard submoduleWarning == nil || submoduleWarning == Self.submoduleFailureWarning else {
            throw WorktreeValidation.invalid("The worktree submodule warning is not a supported generic diagnostic.")
        }
    }
    func hasSameCheckout(as other: Self) -> Bool { destinationPath == other.destinationPath && headCommit == other.headCommit && branch == other.branch }
    private enum CodingKeys: String, CodingKey { case destinationPath, headCommit, branch, submoduleWarning }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(destinationPath: try c.decode(String.self, forKey: .destinationPath), headCommit: try c.decode(String.self, forKey: .headCommit), branch: try c.decodeIfPresent(String.self, forKey: .branch),
                  submoduleWarning: try c.decodeIfPresent(String.self, forKey: .submoduleWarning))
        try validate()
    }
}

public protocol WorkspaceWorktreeSession: Sendable {
    func prepare() async throws -> GitWorktreePlan
    func run(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult
    func inspectCompletion(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult?
}

public struct GitWorktreeError: Error, LocalizedError, Sendable, Equatable {
    public enum Failure: String, Sendable, Equatable { case invalidRequest, notRepository, branchExists, branchMissing, branchInUse, destinationExists, ownershipLost, incomplete, commandFailed, outputLimit, timedOut, metadataCorrupt, busy }
    public let failure: Failure
    public let message: String
    public let existingWorktree: GitWorktree?
    public var errorDescription: String? { message }
    public init(_ failure: Failure, _ message: String, existingWorktree: GitWorktree? = nil) { self.failure = failure; self.message = message; self.existingWorktree = existingWorktree }
}

enum WorktreeValidation {
    static func invalid(_ message: String) -> GitWorktreeError { .init(.invalidRequest, message) }
    static func path(_ value: String) throws {
        // Foundation's standardization also rewrites filesystem aliases such as
        // /private/var to /var. Git legitimately emits either spelling. Check
        // lexical components here; repository ownership is checked using open
        // directory descriptors and device/inode identities in the service.
        guard value.hasPrefix("/"), value != "/", value.utf16.count <= 4_096, !value.contains("\0"),
              value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw invalid("Choose an absolute normalized local worktree path below the filesystem root.") }
    }
    static func commit(_ value: String) throws {
        guard [40, 64].contains(value.count), value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw invalid("The worktree plan needs a resolved local commit.") }
    }
    static func branch(_ value: String) throws {
        let invalidCharacters = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters).union(.newlines)
        guard !value.isEmpty, value.utf16.count <= 1_024, !value.hasPrefix("-"), value != "@", !value.hasPrefix("/"), !value.hasSuffix("/"),
              !value.hasSuffix("."), !value.contains(".."), !value.contains("@{"), !value.contains("//"),
              !value.unicodeScalars.contains(where: { invalidCharacters.contains($0) }),
              value.split(separator: "/").allSatisfy({ !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }) else { throw invalid("Choose a valid local branch name.") }
    }
}
