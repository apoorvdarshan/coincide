import Foundation

public enum GitHubPullRequestCheckoutMode: String, Codable, Sendable { case local, worktree }
public enum GitHubPullRequestCheckoutPolicy: String, Codable, Sendable { case refresh, inspectOnly }
public enum GitHubPullRequestCheckoutDisposition: String, Codable, Sendable {
    case local, createWorktree, reuseWorktree, reuseUnrelatedWorktree
}

public struct GitHubPullRequestCheckoutRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let sourcePath: String
    public let destinationRoot: String
    public let reference: GitHubPullRequestReference
    public let mode: GitHubPullRequestCheckoutMode
    public let submodules: ProjectWorktreeSubmoduleMode
    public let policy: GitHubPullRequestCheckoutPolicy
    public init(id: UUID = UUID(), sourcePath: String, destinationRoot: String,
                reference: GitHubPullRequestReference, mode: GitHubPullRequestCheckoutMode,
                submodules: ProjectWorktreeSubmoduleMode = .none, policy: GitHubPullRequestCheckoutPolicy = .refresh) {
        self.id = id; self.sourcePath = sourcePath; self.destinationRoot = destinationRoot
        self.reference = reference; self.mode = mode; self.submodules = submodules; self.policy = policy
    }
    private enum CodingKeys: String, CodingKey { case id, sourcePath, destinationRoot, reference, mode, submodules, policy }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); sourcePath = try values.decode(String.self, forKey: .sourcePath)
        destinationRoot = try values.decode(String.self, forKey: .destinationRoot); reference = try values.decode(GitHubPullRequestReference.self, forKey: .reference)
        mode = try values.decode(GitHubPullRequestCheckoutMode.self, forKey: .mode)
        submodules = try values.decode(ProjectWorktreeSubmoduleMode.self, forKey: .submodules)
        policy = try values.decodeIfPresent(GitHubPullRequestCheckoutPolicy.self, forKey: .policy) ?? .refresh
    }
    public func validate() throws {
        try WorktreeValidation.path(sourcePath); try WorktreeValidation.path(destinationRoot); try reference.validate()
        guard mode == .worktree || (submodules == .none && policy == .refresh) else { throw GitHubPullRequestCheckoutError(.invalidRequest) }
    }
}

/// Digests bind bounded read-only Git observations; no inherited environment or credentials are stored.
public struct GitHubPullRequestCheckoutProof: Codable, Sendable, Equatable {
    public let sourceIdentity: GitWorktreeNodeIdentity
    public let repositoryIdentity: GitWorktreeNodeIdentity
    public let gitDirectoryPath: String
    public let gitDirectoryIdentity: GitWorktreeNodeIdentity
    public let commonDirectoryIdentity: GitWorktreeNodeIdentity
    public let sourceFingerprint: String
    public let configurationDigest: String
    /// Stable source ownership/configuration proof; excludes active checkout HEAD and bytes.
    public let repositoryFingerprint: String?
    public let indexDigest: String?
    public let statusDigest: String
    public let headCommit: String?
    public let branch: String?
    public let destinationIdentity: GitWorktreeNodeIdentity?
    public let destinationGitDirectoryPath: String?
    public let destinationGitDirectoryIdentity: GitWorktreeNodeIdentity?
    public let destinationFingerprint: String?
    public let destinationConfigurationDigest: String?
    public let destinationStatusDigest: String?
    public let destinationIndexDigest: String?
    public let destinationHeadCommit: String?
    public let destinationBranch: String?
    public let previousUpstreamCommit: String?
    public init(sourceIdentity: GitWorktreeNodeIdentity, repositoryIdentity: GitWorktreeNodeIdentity,
                gitDirectoryPath: String, gitDirectoryIdentity: GitWorktreeNodeIdentity,
                commonDirectoryIdentity: GitWorktreeNodeIdentity, sourceFingerprint: String,
                indexDigest: String? = nil, statusDigest: String, configurationDigest: String? = nil, headCommit: String? = nil, branch: String? = nil,
                destinationIdentity: GitWorktreeNodeIdentity? = nil, destinationGitDirectoryPath: String? = nil,
                destinationGitDirectoryIdentity: GitWorktreeNodeIdentity? = nil, destinationStatusDigest: String? = nil,
                destinationIndexDigest: String? = nil, destinationHeadCommit: String? = nil,
                destinationBranch: String? = nil, previousUpstreamCommit: String? = nil,
                destinationFingerprint: String? = nil, destinationConfigurationDigest: String? = nil,
                repositoryFingerprint: String? = nil) {
        self.sourceIdentity = sourceIdentity; self.repositoryIdentity = repositoryIdentity
        self.gitDirectoryPath = gitDirectoryPath; self.gitDirectoryIdentity = gitDirectoryIdentity
        self.commonDirectoryIdentity = commonDirectoryIdentity; self.sourceFingerprint = sourceFingerprint
        self.configurationDigest = configurationDigest ?? sourceFingerprint
        self.repositoryFingerprint = repositoryFingerprint
        self.indexDigest = indexDigest; self.statusDigest = statusDigest; self.headCommit = headCommit; self.branch = branch
        self.destinationIdentity = destinationIdentity; self.destinationGitDirectoryPath = destinationGitDirectoryPath
        self.destinationGitDirectoryIdentity = destinationGitDirectoryIdentity; self.destinationStatusDigest = destinationStatusDigest
        self.destinationFingerprint = destinationFingerprint; self.destinationConfigurationDigest = destinationConfigurationDigest
        self.destinationIndexDigest = destinationIndexDigest; self.destinationHeadCommit = destinationHeadCommit
        self.destinationBranch = destinationBranch; self.previousUpstreamCommit = previousUpstreamCommit
    }
    func validate() throws {
        try WorktreeValidation.path(gitDirectoryPath)
        for path in [destinationGitDirectoryPath].compactMap({ $0 }) { try WorktreeValidation.path(path) }
        guard [sourceFingerprint, statusDigest, configurationDigest].allSatisfy(CheckpointValidation.digest),
              [indexDigest, destinationStatusDigest, destinationIndexDigest, destinationFingerprint, destinationConfigurationDigest, repositoryFingerprint].compactMap({ $0 }).allSatisfy(CheckpointValidation.digest),
              [headCommit, destinationHeadCommit, previousUpstreamCommit].compactMap({ $0 }).allSatisfy(GitHubValidation.object),
              [branch, destinationBranch].compactMap({ $0 }).allSatisfy(GitHubValidation.branch) else { throw GitHubPullRequestCheckoutError(.invalidRequest) }
    }
}

public struct GitHubPullRequestCheckoutRemote: Codable, Sendable, Equatable {
    public let name: String
    public let url: String
    public let repository: GitHubRepository
    public let needsCreation: Bool
    public let configurationURL: String
    public init(name: String, url: String, repository: GitHubRepository, needsCreation: Bool, configurationURL: String? = nil) throws {
        self.name = name; self.url = url; self.repository = repository; self.needsCreation = needsCreation
        self.configurationURL = configurationURL ?? (url.hasPrefix("file:") ? "https://" + repository.selector + ".git" : url); try validate()
    }
    func validate() throws {
        try repository.validate()
        let local = URLComponents(string: url).map { $0.scheme == "file" && ($0.host == nil || $0.host == "") && $0.user == nil && $0.password == nil && $0.query == nil && $0.fragment == nil } ?? false
        let matches = local ? true : try GitHubPullRequestService.remoteRepository(url) == repository
        let configured = try GitHubPullRequestService.remoteRepository(configurationURL) == repository
        guard GitHubValidation.refToken(name), matches, configured else { throw GitHubPullRequestCheckoutError(.invalidRequest) }
    }
}

public struct GitHubPullRequestCheckoutPlan: Codable, Sendable, Equatable, Identifiable {
    public let request: GitHubPullRequestCheckoutRequest
    public let sourcePath: String
    public let repositoryPath: String
    public let commonDirectoryPath: String
    public let destinationPath: String
    public let pullRequest: GitHubPullRequestSummary
    public let requestedBranch: String
    public let requestedHeadCommit: String
    public let disposition: GitHubPullRequestCheckoutDisposition
    public let proof: GitHubPullRequestCheckoutProof
    public let baseRemote: GitHubPullRequestCheckoutRemote
    public let headRemote: GitHubPullRequestCheckoutRemote?
    public let existingBranchCommit: String?
    public let destinationParentIdentity: GitWorktreeNodeIdentity
    public var id: UUID { request.id }
    public var scopePaths: [String] { [repositoryPath, commonDirectoryPath, destinationPath] }
    public var isReadOnly: Bool { request.policy == .inspectOnly || disposition == .reuseUnrelatedWorktree }
    public var affectedWorkspacePaths: [String] { isReadOnly ? [] : [destinationPath] }
    public var coordinationPaths: [String] { isReadOnly ? [] : [commonDirectoryPath] }
    public init(request: GitHubPullRequestCheckoutRequest, sourcePath: String, repositoryPath: String,
                commonDirectoryPath: String, destinationPath: String, pullRequest: GitHubPullRequestSummary,
                requestedBranch: String, requestedHeadCommit: String, disposition: GitHubPullRequestCheckoutDisposition,
                proof: GitHubPullRequestCheckoutProof, baseRemote: GitHubPullRequestCheckoutRemote,
                headRemote: GitHubPullRequestCheckoutRemote? = nil, existingBranchCommit: String? = nil,
                destinationParentIdentity: GitWorktreeNodeIdentity) throws {
        self.request = request; self.sourcePath = sourcePath; self.repositoryPath = repositoryPath
        self.commonDirectoryPath = commonDirectoryPath; self.destinationPath = destinationPath; self.pullRequest = pullRequest
        self.requestedBranch = requestedBranch; self.requestedHeadCommit = requestedHeadCommit; self.disposition = disposition
        self.proof = proof; self.baseRemote = baseRemote; self.headRemote = headRemote; self.existingBranchCommit = existingBranchCommit
        self.destinationParentIdentity = destinationParentIdentity; try validate()
    }
    public func validate() throws {
        try request.validate(); try pullRequest.validate(); try proof.validate(); try baseRemote.validate(); try headRemote?.validate()
        for path in [sourcePath, repositoryPath, commonDirectoryPath, destinationPath] { try WorktreeValidation.path(path) }
        guard sourcePath == repositoryPath || sourcePath.hasPrefix(repositoryPath + "/"),
              pullRequest.reference == request.reference, pullRequest.headCommit == requestedHeadCommit,
              GitHubValidation.object(requestedHeadCommit), GitHubValidation.branch(requestedBranch),
              existingBranchCommit.map(GitHubValidation.object) ?? true,
              baseRemote.repository == pullRequest.reference.repository,
              headRemote.map({ $0.repository == pullRequest.headRepository }) ?? true,
              (request.mode == .local ? disposition == .local && destinationPath == repositoryPath : disposition != .local) else {
            throw GitHubPullRequestCheckoutError(.invalidRequest)
        }
        if disposition == .createWorktree {
            guard destinationPath == request.destinationRoot + "/" + id.uuidString, proof.destinationIdentity == nil else { throw GitHubPullRequestCheckoutError(.invalidRequest) }
        } else if disposition != .local {
            guard proof.destinationIdentity != nil, proof.destinationGitDirectoryIdentity != nil,
                  proof.destinationGitDirectoryPath != nil, proof.destinationHeadCommit != nil,
                  proof.destinationBranch != nil, proof.destinationStatusDigest != nil,
                  proof.destinationFingerprint != nil, proof.destinationConfigurationDigest != nil else { throw GitHubPullRequestCheckoutError(.invalidRequest) }
        }
        if request.policy == .inspectOnly {
            guard request.mode == .worktree, disposition == .reuseWorktree || disposition == .reuseUnrelatedWorktree else { throw GitHubPullRequestCheckoutError(.invalidRequest) }
        }
    }
}

public struct GitHubPullRequestCheckoutResult: Codable, Sendable, Equatable {
    public static let trackingWarning = "The checkout is available, but its pull request upstream could not be configured. Inspect tracking in Terminal before pushing."
    public static let offHeadWarning = "Local commits or workspace changes were preserved. This checkout is not confirmed at the pull request's reviewed commit."
    public let destinationPath: String
    public let branch: String
    public let headCommit: String
    public let isOnPullRequestHead: Bool
    public let created: Bool
    public let reused: Bool
    public let moved: Bool
    public let warnings: [String]
    public let worktreePlan: GitWorktreePlan?
    public let worktreeResult: GitWorktreeResult?
    public var actualBranch: String { branch }
    public var actualHeadCommit: String { headCommit }
    public var isOnHead: Bool { isOnPullRequestHead }
    public var childPlan: GitWorktreePlan? { worktreePlan }
    public var childResult: GitWorktreeResult? { worktreeResult }
    public init(destinationPath: String, branch: String, headCommit: String, isOnPullRequestHead: Bool,
                created: Bool, reused: Bool, moved: Bool, warnings: [String] = [],
                worktreePlan: GitWorktreePlan? = nil, worktreeResult: GitWorktreeResult? = nil) {
        self.destinationPath = destinationPath; self.branch = branch; self.headCommit = headCommit
        self.isOnPullRequestHead = isOnPullRequestHead; self.created = created; self.reused = reused; self.moved = moved
        self.warnings = warnings; self.worktreePlan = worktreePlan; self.worktreeResult = worktreeResult
    }
    public func validate() throws {
        try WorktreeValidation.path(destinationPath); try WorktreeValidation.branch(branch); try WorktreeValidation.commit(headCommit)
        guard !(created && reused), warnings.count <= 3, Set(warnings).count == warnings.count,
              warnings.allSatisfy({ [Self.trackingWarning, Self.offHeadWarning, GitWorktreeResult.submoduleFailureWarning].contains($0) }),
              (worktreePlan == nil) == (worktreeResult == nil) else { throw GitHubPullRequestCheckoutError(.invalidResponse) }
        if let plan = worktreePlan, let result = worktreeResult {
            try plan.validate(); try result.validate()
            guard plan.destinationPath == destinationPath, result.destinationPath == destinationPath,
                  result.branch == branch, result.headCommit == headCommit, plan.baseCommit == headCommit else { throw GitHubPullRequestCheckoutError(.invalidResponse) }
        }
    }
    public func validate(plan: GitHubPullRequestCheckoutPlan) throws {
        try validate(); try plan.validate()
        guard destinationPath == plan.destinationPath,
              !isOnPullRequestHead || headCommit == plan.requestedHeadCommit,
              plan.disposition != .reuseUnrelatedWorktree || !isOnPullRequestHead,
              !plan.isReadOnly || (!created && reused && !moved),
              (plan.request.mode == .local ? worktreePlan == nil && !created && !reused : worktreePlan != nil) else {
            throw GitHubPullRequestCheckoutError(.invalidResponse)
        }
        if let child = worktreePlan {
            guard child.id == plan.id, child.sourcePath == plan.repositoryPath,
                  child.commonDirectoryPath == plan.commonDirectoryPath,
                  child.request.sourcePath == plan.repositoryPath,
                  created == (plan.disposition == .createWorktree), reused != created,
                  child.request.submodules == (created ? plan.request.submodules : .none) else { throw GitHubPullRequestCheckoutError(.invalidResponse) }
        }
    }
}

public enum GitHubPullRequestCheckoutInspection: Codable, Sendable, Equatable {
    case completed(GitHubPullRequestCheckoutResult), unconfirmed
}
public protocol GitHubPullRequestCheckoutSession: Sendable {
    func prepare() async throws -> GitHubPullRequestCheckoutPlan
    func run(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutResult
    func inspectCompletion(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutInspection
}
public struct GitHubPullRequestCheckoutError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable { case invalidRequest, invalidResponse, staleReview, dirtyCheckout, branchInUse, branchCollision, unsupportedRemote, incomplete, commandFailed, timedOut, outputLimit }
    public let kind: Kind
    public let mayHaveChanged: Bool
    public var mayHaveMutated: Bool { mayHaveChanged }
    public init(_ kind: Kind, mayHaveChanged: Bool = false) { self.kind = kind; self.mayHaveChanged = mayHaveChanged }
    public var errorDescription: String? {
        if mayHaveChanged { return "Pull request checkout did not finish with verifiable completion. Git may have changed refs, tracking or checkout files. Existing data was preserved; inspect the attempt before proceeding. No operation was replayed." }
        switch kind {
        case .invalidRequest: return "The pull request checkout request is invalid."
        case .invalidResponse: return "The pull request checkout evidence is incomplete or inconsistent."
        case .staleReview: return "The repository, pull request or selected checkout changed. Review the current state again."
        case .dirtyCheckout: return "Commit or stash tracked changes before checking out here, or use a separate worktree."
        case .branchInUse: return "The pull request branch is already checked out in the source checkout. Choose Local, or switch that checkout to another branch first."
        case .branchCollision: return "An existing local branch cannot be proven to belong to this pull request. It was preserved."
        case .unsupportedRemote: return "The pull request's exact repository and a supported fetch transport could not be verified."
        case .incomplete: return "This pull request attempt has incomplete data. Preserve it and inspect its state; no operation was repeated."
        case .commandFailed: return "Git could not prepare this pull request checkout."
        case .timedOut: return "Preparing the pull request checkout timed out."
        case .outputLimit: return "Pull request checkout data exceeded its bounded size limit."
        }
    }
}
