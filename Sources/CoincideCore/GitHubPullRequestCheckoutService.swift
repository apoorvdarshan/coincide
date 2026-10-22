import Foundation

public struct GitHubPullRequestCheckoutService: GitHubPullRequestCheckoutSession, Sendable {
    public let request: GitHubPullRequestCheckoutRequest
    let environment: [String: String]?
    let gitExecutable: URL?
    let githubExecutable: URL?
    let timeout: Duration
    /// Only isolated tests may substitute local file transports for known repository metadata.
    let transportOverrides: [GitHubRepository: URL]
    public init(request: GitHubPullRequestCheckoutRequest, timeout: Duration = .seconds(120)) {
        self.request = request; self.timeout = timeout; environment = nil; gitExecutable = nil
        githubExecutable = ProcessChannel.findExecutable("gh"); transportOverrides = [:]
    }
    init(request: GitHubPullRequestCheckoutRequest, environment: [String: String], gitExecutable: URL? = nil,
         githubExecutable: URL?, transportOverrides: [GitHubRepository: URL] = [:], timeout: Duration = .seconds(120)) {
        self.request = request; self.environment = environment; self.gitExecutable = gitExecutable
        self.githubExecutable = githubExecutable; self.transportOverrides = transportOverrides; self.timeout = timeout
    }
    var metadata: GitHubPullRequestService {
        if let environment { return .init(root: URL(fileURLWithPath: request.sourcePath), environment: environment, gitExecutable: gitExecutable, githubExecutable: githubExecutable, timeout: timeout) }
        return .init(root: URL(fileURLWithPath: request.sourcePath), timeout: timeout)
    }
    var command: GitWorktreeCommand { .init(environment: environment, executable: gitExecutable) }
    func worktrees(source: String) -> GitWorktreeService {
        if let environment { return .init(source: URL(fileURLWithPath: source), environment: environment, gitExecutable: gitExecutable, timeout: timeout) }
        return .init(source: URL(fileURLWithPath: source), timeout: timeout)
    }
    func worktrees(request: GitWorktreeRequest) -> GitWorktreeService {
        if let environment { return .init(request: request, environment: environment, gitExecutable: gitExecutable, timeout: timeout) }
        return .init(request: request, timeout: timeout)
    }
    public func prepare() async throws -> GitHubPullRequestCheckoutPlan {
        try request.validate(); try Task.checkCancellation()
        let local = try await metadata.localContext()
        guard try local.baseRepository() == request.reference.repository else { throw GitHubPullRequestCheckoutError(.unsupportedRemote) }
        let detail = try await metadata.detail(request.reference), pr = detail.summary
        let baseRemote = try await remote(for: pr.reference.repository, local: local)
        let headRemote = try await pr.headRepository.asyncMap { try await remote(for: $0, local: local) }
        let fork = pr.headRepository.map { $0 != pr.reference.repository } ?? true
        let defaultBranch = try await defaultBranch(local: local)
        let branch = try Self.branch(for: pr, mode: request.mode, defaultBranch: defaultBranch)
        let inventory = try await worktrees(source: local.repository.path).inventory()
        let existing = try await optionalCommit("refs/heads/" + branch, local: local)
        let disposition: GitHubPullRequestCheckoutDisposition
        let destination: String
        var reused: GitHubPullRequestLocal?
        if request.mode == .local {
            guard try await trackedStatus(local).isEmpty else { throw GitHubPullRequestCheckoutError(.dirtyCheckout) }
            if inventory.worktrees.contains(where: { $0.branch == branch && $0.path != local.repository.path && !$0.isBare }) { throw GitHubPullRequestCheckoutError(.branchInUse) }
            disposition = .local; destination = local.repository.path
        } else {
            let exact = inventory.worktrees.first { $0.branch == branch && !$0.isBare }
            let alias = fork ? inventory.worktrees.first { $0.branch == pr.headBranch && !$0.isBare && $0.path != local.repository.path } : nil
            if let match = exact ?? alias {
                guard match.path != local.repository.path, !match.isDetached, match.prunableReason == nil, match.lockedReason == nil else { throw GitHubPullRequestCheckoutError(.branchInUse) }
                destination = match.path
                reused = try await self.local(at: destination)
                guard reused?.common.identity == local.common.identity else { throw GitHubPullRequestCheckoutError(.staleReview) }
                disposition = match.branch == branch ? .reuseWorktree : .reuseUnrelatedWorktree
            } else { disposition = .createWorktree; destination = request.destinationRoot + "/" + request.id.uuidString }
        }
        let readOnly = request.policy == .inspectOnly || disposition == .reuseUnrelatedWorktree
        guard request.policy != .inspectOnly || reused != nil else { throw GitHubPullRequestCheckoutError(.staleReview) }
        let status: Data, index: String?
        if request.mode == .local { status = try await self.status(local); index = try indexDigest(local) }
        else { status = Data(); index = nil }
        let parent = try GitWorktreeDirectory(path: URL(fileURLWithPath: destination).deletingLastPathComponent().path)
        if disposition == .createWorktree, try parent.exists(request.id.uuidString) { throw GitHubPullRequestCheckoutError(.staleReview) }
        let reusedStatus = try await reused.asyncMap { checkout in
            if readOnly { return Data() }; return try await self.status(checkout)
        }
        let reusedConfiguration = try await reused.asyncMap { try await policyConfigurationDigest($0) }
        let reusedFingerprint = try await reused.asyncMap { try await destinationFingerprint($0, baseRemote: baseRemote, headRemote: headRemote) }
        let repositoryProof = try await repositoryFingerprint(local, baseRemote: baseRemote, headRemote: headRemote)
        let sourceProof = try await destinationFingerprint(local, baseRemote: baseRemote, headRemote: headRemote)
        let upstream: String?
        if let reused { upstream = try await optionalCommit("@{upstream}", local: reused) }
        else if existing != nil { upstream = try await optionalCommit(branch + "@{upstream}", local: local) }
        else { upstream = nil }
        let proof = GitHubPullRequestCheckoutProof(sourceIdentity: local.workspace.identity, repositoryIdentity: local.repository.identity,
            gitDirectoryPath: local.admin.path, gitDirectoryIdentity: local.admin.identity, commonDirectoryIdentity: local.common.identity,
            sourceFingerprint: sourceProof, indexDigest: index, statusDigest: GitHubPullRequestService.digest(status), configurationDigest: try await policyConfigurationDigest(local), headCommit: local.head, branch: local.branch,
            destinationIdentity: reused?.repository.identity, destinationGitDirectoryPath: reused?.admin.path, destinationGitDirectoryIdentity: reused?.admin.identity,
            destinationStatusDigest: reusedStatus.map(GitHubPullRequestService.digest), destinationIndexDigest: readOnly ? nil : try reused.flatMap { try indexDigest($0) },
            destinationHeadCommit: reused?.head, destinationBranch: reused?.branch, previousUpstreamCommit: upstream,
            destinationFingerprint: reusedFingerprint, destinationConfigurationDigest: reusedConfiguration, repositoryFingerprint: repositoryProof)
        let current = try await metadata.localContext()
        if request.mode == .local {
            guard try await destinationFingerprint(current, baseRemote: baseRemote, headRemote: headRemote) == proof.sourceFingerprint,
                  try indexDigest(current) == index, try await self.status(current) == status,
                  try await policyConfigurationDigest(current) == proof.configurationDigest else { throw GitHubPullRequestCheckoutError(.staleReview) }
        } else {
            guard try await repositoryFingerprint(current, baseRemote: baseRemote, headRemote: headRemote) == repositoryProof else { throw GitHubPullRequestCheckoutError(.staleReview) }
        }
        return try .init(request: request, sourcePath: local.workspace.path, repositoryPath: local.repository.path,
            commonDirectoryPath: local.common.path, destinationPath: destination, pullRequest: pr, requestedBranch: branch,
            requestedHeadCommit: pr.headCommit, disposition: disposition, proof: proof, baseRemote: baseRemote,
            headRemote: headRemote, existingBranchCommit: existing, destinationParentIdentity: parent.identity)
    }
    public func run(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutResult {
        try validateSession(plan)
        if plan.isReadOnly { return try await observeReadOnlyReuse(plan) }
        return try await GitOperationGate.shared.perform(key: plan.commonDirectoryPath) { try await execute(plan) }
    }
    public func inspectCompletion(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutInspection {
        try validateSession(plan)
        if plan.isReadOnly {
            do { return .completed(try await observeReadOnlyReuse(plan)) }
            catch is CancellationError { throw CancellationError() }
            catch { return .unconfirmed }
        }
        do { return try await inspect(plan) } catch is CancellationError { throw CancellationError() } catch { return .unconfirmed }
    }
    func validateSession(_ plan: GitHubPullRequestCheckoutPlan) throws {
        try request.validate(); try plan.validate(); try Task.checkCancellation()
        guard plan.request == request, GitHubPullRequestService.canonical(request.sourcePath) == plan.sourcePath else { throw GitHubPullRequestCheckoutError(.staleReview) }
    }
    static func branch(for pr: GitHubPullRequestSummary, mode: GitHubPullRequestCheckoutMode, defaultBranch: String) throws -> String {
        let fork = pr.headRepository.map { $0 != pr.reference.repository } ?? true
        let value: String
        if mode == .worktree, fork {
            let key = GitHubPullRequestService.digest(Data(pr.reference.repository.selector.utf8)).prefix(12)
            value = "coincide/pr-" + key + "-" + String(pr.reference.number) + "/" + pr.headBranch
        } else if mode == .local, fork, pr.headBranch == defaultBranch {
            guard let owner = pr.headRepository?.owner else { throw GitHubPullRequestCheckoutError(.unsupportedRemote) }
            value = owner + "/" + pr.headBranch
        } else { value = pr.headBranch }
        guard GitHubValidation.branch(value) else { throw GitHubPullRequestCheckoutError(.invalidRequest) }; return value
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        switch self { case .some(let value): return try await transform(value); case .none: return nil }
    }
}
