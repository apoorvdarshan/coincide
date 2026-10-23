import Foundation

public struct GitHubRepository: Codable, Sendable, Equatable, Hashable {
    public let host: String
    public let owner: String
    public let name: String
    public var nameWithOwner: String { owner + "/" + name }
    public var selector: String { host + "/" + nameWithOwner }
    public init(host: String = "github.com", owner: String, name: String) throws {
        self.host = host.lowercased(); self.owner = owner.lowercased(); self.name = name.lowercased(); try validate()
    }
    public func validate() throws {
        guard host == host.lowercased(), host.utf8.count <= 253,
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }) }),
              [owner, name].allSatisfy({ GitHubValidation.segment($0) }), owner != ".", owner != "..", name != ".", name != ".." else { throw GitHubPullRequestError(.invalidRequest) }
    }
    private enum CodingKeys: String, CodingKey { case host, owner, name }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: c.decode(String.self, forKey: .host), owner: c.decode(String.self, forKey: .owner), name: c.decode(String.self, forKey: .name))
    }
}

public struct GitHubPullRequestReference: Codable, Sendable, Equatable, Hashable {
    public let repository: GitHubRepository
    public let number: Int
    public init(repository: GitHubRepository, number: Int) throws { self.repository = repository; self.number = number; try validate() }
    public func validate() throws { try repository.validate(); guard number > 0 else { throw GitHubPullRequestError(.invalidRequest) } }
}
public enum GitHubPullRequestState: String, Codable, Sendable { case open, closed, merged }
public enum GitHubPullRequestListState: String, Codable, Sendable { case open, closed, merged, all }
public enum GitHubPullRequestReviewDecision: String, Codable, Sendable { case approved, changesRequested, reviewRequired, unknown }
public enum GitHubPullRequestChecksState: String, Codable, Sendable { case pending, success, failure, unknown }
public enum GitHubPullRequestReadiness: String, Codable, Sendable {
    case ready, detachedHead, unpublished, unpushedCommits, defaultBranch, ambiguousRemote
    public var message: String? {
        switch self {
        case .ready: nil
        case .detachedHead: "Switch to a local branch before creating a pull request."
        case .unpublished: "Push this branch and set its upstream before creating a pull request."
        case .unpushedCommits: "Push the reviewed local commit before creating a pull request."
        case .defaultBranch: "Choose a feature branch or a different base before creating a pull request."
        case .ambiguousRemote: "The branch's head repository could not be identified unambiguously."
        }
    }
}

public struct GitHubPullRequestSummary: Codable, Sendable, Equatable, Identifiable {
    private struct TerminalDates: Sendable, Equatable { let closedAt: Date?; let mergedAt: Date? }
    private let terminalDates: [TerminalDates]
    public let reference: GitHubPullRequestReference
    public let title: String
    public let url: String
    public let state: GitHubPullRequestState
    public let isDraft: Bool
    public let headBranch: String
    public let baseBranch: String
    public let headCommit: String
    public let baseCommit: String
    public let headRepository: GitHubRepository?
    public let author: String?
    public let updatedAt: Date
    public let reviewDecision: GitHubPullRequestReviewDecision?
    public let checksState: GitHubPullRequestChecksState?
    public var closedAt: Date? { terminalDates[0].closedAt }
    public var mergedAt: Date? { terminalDates[0].mergedAt }
    public var id: GitHubPullRequestReference { reference }
    public init(reference: GitHubPullRequestReference, title: String, url: String, state: GitHubPullRequestState,
                isDraft: Bool = false, headBranch: String, baseBranch: String, headCommit: String, baseCommit: String,
                headRepository: GitHubRepository? = nil, author: String? = nil, updatedAt: Date = Date(),
                reviewDecision: GitHubPullRequestReviewDecision? = nil, checksState: GitHubPullRequestChecksState? = nil,
                closedAt: Date? = nil, mergedAt: Date? = nil) throws {
        terminalDates = [.init(closedAt: closedAt, mergedAt: mergedAt)]
        self.reference = reference; self.title = title; self.url = url; self.state = state; self.isDraft = isDraft
        self.headBranch = headBranch; self.baseBranch = baseBranch; self.headCommit = headCommit; self.baseCommit = baseCommit
        self.headRepository = headRepository; self.author = author; self.updatedAt = updatedAt
        self.reviewDecision = reviewDecision; self.checksState = checksState; try validate()
    }
    public func validate() throws {
        try reference.validate(); try headRepository?.validate()
        guard GitHubValidation.text(title, maximum: 4_096), GitHubValidation.branch(headBranch), GitHubValidation.branch(baseBranch),
              GitHubValidation.object(headCommit), GitHubValidation.object(baseCommit), updatedAt.timeIntervalSince1970.isFinite,
              author.map({ GitHubValidation.text($0, maximum: 256) }) ?? true,
              [closedAt, mergedAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              state != .open || (closedAt == nil && mergedAt == nil), state == .merged || mergedAt == nil,
              GitHubValidation.pullRequestURL(url, reference: reference) else { throw GitHubPullRequestError(.invalidResponse) }
    }
    private enum CodingKeys: String, CodingKey {
        case reference, title, url, state, isDraft, headBranch, baseBranch, headCommit, baseCommit, headRepository, author, updatedAt, reviewDecision, checksState, closedAt, mergedAt
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: c.decode(GitHubPullRequestReference.self, forKey: .reference), title: c.decode(String.self, forKey: .title),
            url: c.decode(String.self, forKey: .url), state: c.decode(GitHubPullRequestState.self, forKey: .state),
            isDraft: c.decode(Bool.self, forKey: .isDraft), headBranch: c.decode(String.self, forKey: .headBranch),
            baseBranch: c.decode(String.self, forKey: .baseBranch), headCommit: c.decode(String.self, forKey: .headCommit),
            baseCommit: c.decode(String.self, forKey: .baseCommit), headRepository: c.decodeIfPresent(GitHubRepository.self, forKey: .headRepository),
            author: c.decodeIfPresent(String.self, forKey: .author), updatedAt: c.decode(Date.self, forKey: .updatedAt),
            reviewDecision: c.decodeIfPresent(GitHubPullRequestReviewDecision.self, forKey: .reviewDecision),
            checksState: c.decodeIfPresent(GitHubPullRequestChecksState.self, forKey: .checksState),
            closedAt: c.decodeIfPresent(Date.self, forKey: .closedAt), mergedAt: c.decodeIfPresent(Date.self, forKey: .mergedAt))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reference, forKey: .reference); try c.encode(title, forKey: .title); try c.encode(url, forKey: .url)
        try c.encode(state, forKey: .state); try c.encode(isDraft, forKey: .isDraft)
        try c.encode(headBranch, forKey: .headBranch); try c.encode(baseBranch, forKey: .baseBranch)
        try c.encode(headCommit, forKey: .headCommit); try c.encode(baseCommit, forKey: .baseCommit)
        try c.encodeIfPresent(headRepository, forKey: .headRepository); try c.encodeIfPresent(author, forKey: .author)
        try c.encode(updatedAt, forKey: .updatedAt); try c.encodeIfPresent(reviewDecision, forKey: .reviewDecision)
        try c.encodeIfPresent(checksState, forKey: .checksState); try c.encodeIfPresent(closedAt, forKey: .closedAt); try c.encodeIfPresent(mergedAt, forKey: .mergedAt)
    }
}

public struct GitHubPullRequestCheck: Codable, Sendable, Equatable {
    public let name: String
    public let state: GitHubPullRequestChecksState
    public let url: String?
    public init(name: String, state: GitHubPullRequestChecksState, url: String? = nil) throws {
        self.name = name; self.state = state; self.url = url
        guard GitHubValidation.text(name, maximum: 4_096), url.map(GitHubValidation.safeWebURL) ?? true else { throw GitHubPullRequestError(.invalidResponse) }
    }
}
public struct GitHubPullRequestDetail: Codable, Sendable, Equatable {
    public let summary: GitHubPullRequestSummary
    public let body: String
    public let createdAt: Date
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    public let checks: [GitHubPullRequestCheck]
    public let reviewers: [String]
    public let labels: [String]
    public init(summary: GitHubPullRequestSummary, body: String, createdAt: Date, additions: Int = 0, deletions: Int = 0,
                changedFiles: Int = 0, checks: [GitHubPullRequestCheck] = [], reviewers: [String] = [], labels: [String] = []) throws {
        self.summary = summary; self.body = body; self.createdAt = createdAt; self.additions = additions; self.deletions = deletions
        self.changedFiles = changedFiles; self.checks = checks; self.reviewers = reviewers; self.labels = labels; try validate()
    }
    public func validate() throws {
        try summary.validate()
        guard GitHubValidation.text(body, maximum: 1_048_576, allowEmpty: true, multiline: true), createdAt.timeIntervalSince1970.isFinite,
              additions >= 0, deletions >= 0, changedFiles >= 0, checks.count <= 1_000, reviewers.count <= 100, labels.count <= 100,
              reviewers.allSatisfy({ GitHubValidation.text($0, maximum: 1_024) }), labels.allSatisfy({ GitHubValidation.text($0, maximum: 1_024) }) else { throw GitHubPullRequestError(.invalidResponse) }
    }
}
public struct GitHubPullRequestUpstream: Codable, Sendable, Equatable {
    public let remoteName: String
    public let branch: String
    /// The published server branch head, not a possibly stale local tracking ref.
    public let commit: String?
    public init(remoteName: String, branch: String, commit: String?) throws {
        self.remoteName = remoteName; self.branch = branch; self.commit = commit
        guard GitHubValidation.refToken(remoteName), GitHubValidation.branch(branch), commit.map(GitHubValidation.object) ?? true else { throw GitHubPullRequestError(.invalidRequest) }
    }
}
public struct GitHubPullRequestContext: Codable, Sendable, Equatable {
    public let workspacePath: String
    public let repositoryPath: String
    public let commonDirectoryPath: String
    public let repository: GitHubRepository
    public let headRepository: GitHubRepository?
    public let branch: String?
    public let headCommit: String?
    public let upstream: GitHubPullRequestUpstream?
    public let defaultBranch: String
    public let baseBranches: [String]
    public let baseBranchesTruncated: Bool
    public let existingPullRequest: GitHubPullRequestSummary?
    public let readiness: GitHubPullRequestReadiness
    public let sourceFingerprint: String
    public var canCreate: Bool { readiness == .ready && existingPullRequest == nil }
    public init(workspacePath: String, repositoryPath: String? = nil, commonDirectoryPath: String? = nil,
                repository: GitHubRepository, headRepository: GitHubRepository?, branch: String?, headCommit: String?,
                upstream: GitHubPullRequestUpstream?, defaultBranch: String, baseBranches: [String], baseBranchesTruncated: Bool = false,
                existingPullRequest: GitHubPullRequestSummary? = nil, readiness: GitHubPullRequestReadiness, sourceFingerprint: String) throws {
        self.workspacePath = workspacePath; self.repositoryPath = repositoryPath ?? workspacePath
        self.commonDirectoryPath = commonDirectoryPath ?? (repositoryPath ?? workspacePath) + "/.git"
        self.repository = repository; self.headRepository = headRepository; self.branch = branch
        self.headCommit = headCommit; self.upstream = upstream; self.defaultBranch = defaultBranch; self.baseBranches = baseBranches
        self.baseBranchesTruncated = baseBranchesTruncated; self.existingPullRequest = existingPullRequest; self.readiness = readiness
        self.sourceFingerprint = sourceFingerprint; try validate()
    }
    public func validate() throws {
        try repository.validate(); try headRepository?.validate(); try existingPullRequest?.validate()
        for path in [workspacePath, repositoryPath, commonDirectoryPath] { try CheckpointValidation.path(path) }
        guard branch.map(GitHubValidation.branch) ?? true, headCommit.map(GitHubValidation.object) ?? true,
              workspacePath == repositoryPath || workspacePath.hasPrefix(repositoryPath + "/"),
              GitHubValidation.branch(defaultBranch), baseBranches.count <= 100, Set(baseBranches).count == baseBranches.count,
              baseBranches.allSatisfy(GitHubValidation.branch), CheckpointValidation.digest(sourceFingerprint),
              existingPullRequest.map({ $0.reference.repository == repository }) ?? true else { throw GitHubPullRequestError(.invalidRequest) }
        if readiness == .ready {
            guard let branch, let headCommit, let headRepository, let upstream,
                  !branch.isEmpty, upstream.commit == headCommit, headRepository.host == repository.host else { throw GitHubPullRequestError(.invalidRequest) }
        }
    }
}

public struct GitHubPullRequestListQuery: Codable, Sendable, Equatable {
    public let state: GitHubPullRequestListState
    public let query: String?
    public let author: String?
    public let baseBranch: String?
    public let headBranch: String?
    public let limit: Int
    public init(state: GitHubPullRequestListState = .open, query: String? = nil, author: String? = nil,
                baseBranch: String? = nil, headBranch: String? = nil, limit: Int = 30) {
        self.state = state; self.query = query; self.author = author; self.baseBranch = baseBranch; self.headBranch = headBranch; self.limit = limit
    }
    public func validate() throws {
        guard (1...100).contains(limit), query.map({ GitHubValidation.text($0, maximum: 1_024) }) ?? true,
              author.map({ GitHubValidation.text($0, maximum: 256) }) ?? true,
              baseBranch.map(GitHubValidation.branch) ?? true, headBranch.map(GitHubValidation.branch) ?? true else { throw GitHubPullRequestError(.invalidRequest) }
    }
}
public struct GitHubPullRequestPage: Codable, Sendable, Equatable {
    public let items: [GitHubPullRequestSummary]
    public let truncated: Bool
    public init(items: [GitHubPullRequestSummary], truncated: Bool) { self.items = items; self.truncated = truncated }
}
public struct GitHubPullRequestCreateReview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let reviewedAt: Date
    public let context: GitHubPullRequestContext
    public let title: String
    public let body: String
    public let baseBranch: String
    public let baseCommit: String
    public let isDraft: Bool
    public init(id: UUID = UUID(), reviewedAt: Date = Date(), context: GitHubPullRequestContext, title: String, body: String,
                baseBranch: String, baseCommit: String, isDraft: Bool = false) throws {
        self.id = id; self.reviewedAt = reviewedAt; self.context = context; self.title = title; self.body = body
        self.baseBranch = baseBranch; self.baseCommit = baseCommit; self.isDraft = isDraft; try validate()
    }
    public func validate() throws {
        try context.validate()
        guard reviewedAt.timeIntervalSince1970.isFinite, GitHubValidation.text(title, maximum: 4_096),
              GitHubValidation.text(body, maximum: 1_048_576, allowEmpty: true, multiline: true),
              GitHubValidation.branch(baseBranch), GitHubValidation.object(baseCommit) else { throw GitHubPullRequestError(.invalidRequest) }
    }
}
public enum GitHubPullRequestCreateOutcome: Codable, Sendable, Equatable { case openedExisting(GitHubPullRequestDetail), created(GitHubPullRequestDetail) }
public enum GitHubPullRequestCreateReconciliation: Codable, Sendable, Equatable { case found(GitHubPullRequestDetail), notFound }

public protocol GitHubPullRequestSession: Sendable {
    func context() async throws -> GitHubPullRequestContext
    func list(query: GitHubPullRequestListQuery) async throws -> GitHubPullRequestPage
    func detail(_ reference: GitHubPullRequestReference) async throws -> GitHubPullRequestDetail
    func resolve(_ reference: String) async throws -> GitHubPullRequestDetail
    func reviewCreate(title: String, body: String, baseBranch: String?, isDraft: Bool) async throws -> GitHubPullRequestCreateReview
    func create(_ review: GitHubPullRequestCreateReview) async throws -> GitHubPullRequestCreateOutcome
    func reconcileCreate(_ review: GitHubPullRequestCreateReview) async throws -> GitHubPullRequestCreateReconciliation
}

public struct GitHubPullRequestError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable { case missingCLI, unauthenticated, accessDenied, rateLimited, notRepository, unsupportedRemote, invalidRequest, invalidResponse, ambiguousRemote, notPublished, staleReview, commandFailed, timedOut, outputLimit, outcomeUncertain }
    public let kind: Kind
    public let mayHaveCreated: Bool
    public init(_ kind: Kind, mayHaveCreated: Bool = false) { self.kind = kind; self.mayHaveCreated = mayHaveCreated || kind == .outcomeUncertain }
    public var errorDescription: String? {
        switch kind {
        case .missingCLI: "Install GitHub CLI and sign in with your existing account to use pull requests."
        case .unauthenticated: "GitHub CLI is not signed in to this repository's host, or its credentials were rejected."
        case .accessDenied: "The current GitHub account does not have permission for this repository operation."
        case .rateLimited: "GitHub is limiting requests. Wait before refreshing or trying again."
        case .notRepository: "Choose an available local Git checkout."
        case .unsupportedRemote: "This checkout has no supported GitHub repository remote."
        case .invalidRequest: "The pull request request or repository reference is invalid."
        case .invalidResponse: "GitHub returned incomplete or inconsistent pull request data."
        case .ambiguousRemote: "The branch's repository or upstream is ambiguous. Select its intended upstream first."
        case .notPublished: "Push the reviewed branch commit and set its upstream before creating a pull request."
        case .staleReview: "The checkout, published head or pull request changed. Review the current state again."
        case .commandFailed: "The GitHub operation failed. Check your account access and repository, then refresh."
        case .timedOut: "The GitHub operation timed out."
        case .outputLimit: "GitHub data exceeded the size limit. Narrow the query and refresh."
        case .outcomeUncertain: "The pull request may have been created. Check GitHub before trying again; creation was not repeated."
        }
    }
}

enum GitHubValidation {
    static func text(_ value: String, maximum: Int, allowEmpty: Bool = false, multiline: Bool = false) -> Bool {
        (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && value.utf8.count <= maximum &&
            !value.unicodeScalars.contains { $0.value == 0 || (!multiline && ($0.value < 32 || $0.value == 127 || CharacterSet.newlines.contains($0))) }
    }
    static func segment(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 100 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) } }
    static func refToken(_ value: String) -> Bool { text(value, maximum: 1_024) && !value.hasPrefix("-") && !value.contains("://") && !value.contains(" ") }
    static func branch(_ value: String) -> Bool {
        refToken(value) && !value.contains("..") && !value.contains("@{") && !value.hasPrefix("/") && !value.hasSuffix("/") &&
            !value.unicodeScalars.contains { " ~^:?*[\\".unicodeScalars.contains($0) } &&
            value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") && !$0.hasSuffix(".") }
    }
    static func object(_ value: String) -> Bool { [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func safeWebURL(_ value: String) -> Bool {
        guard let c = URLComponents(string: value), c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.port == nil,
              !host.contains("@"), !host.contains(":"), !host.contains(where: \.isWhitespace) else { return false }
        return !value.contains("\0")
    }
    static func pullRequestURL(_ value: String, reference: GitHubPullRequestReference) -> Bool {
        guard safeWebURL(value), let c = URLComponents(string: value) else { return false }
        return c.host?.lowercased() == reference.repository.host && c.path.lowercased() == "/" + reference.repository.nameWithOwner + "/pull/" + String(reference.number)
    }
}
