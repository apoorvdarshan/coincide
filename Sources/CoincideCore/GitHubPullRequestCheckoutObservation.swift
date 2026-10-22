import Foundation

extension GitHubPullRequestCheckoutService {
    /// Pure observation of a registered checkout. No fetch, tracking, index,
    /// ownership file or receipt is written, including when inspection repeats.
    func observeReadOnlyReuse(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutResult {
        guard plan.isReadOnly, plan.request.mode == .worktree else { throw GitHubPullRequestCheckoutError(.invalidRequest) }
        for attempt in 0..<3 {
            do {
                let source = try await metadata.localContext()
                try await assertSource(source, plan: plan, original: true)
                let before = try await local(at: plan.destinationPath)
                try validateObservedCheckout(before, plan: plan)
                let request = GitWorktreeRequest(id: plan.id, sourcePath: plan.repositoryPath, destinationRoot: plan.request.destinationRoot,
                    selection: .reuse(path: plan.destinationPath), submodules: .none)
                let service = worktrees(request: request), child = try await service.prepare()
                guard child.destinationIdentity == plan.proof.destinationIdentity,
                      child.worktreeGitDirectoryIdentity == plan.proof.destinationGitDirectoryIdentity,
                      child.branch == plan.proof.destinationBranch else { throw GitHubPullRequestCheckoutError(.staleReview) }
                guard let observed = try await service.inspectCompletion(child) else { throw GitHubPullRequestCheckoutError(.staleReview) }
                let after = try await local(at: plan.destinationPath)
                try validateObservedCheckout(after, plan: plan)
                guard let branch = observed.branch, after.head == observed.headCommit, after.branch == branch else { throw GitHubPullRequestCheckoutError(.staleReview) }
                let finalSource = try await metadata.localContext()
                try await assertSource(finalSource, plan: plan, original: false)
                let onHead = plan.disposition != .reuseUnrelatedWorktree && observed.headCommit == plan.requestedHeadCommit
                let result = GitHubPullRequestCheckoutResult(destinationPath: plan.destinationPath, branch: branch, headCommit: observed.headCommit,
                    isOnPullRequestHead: onHead, created: false, reused: true, moved: false,
                    warnings: onHead ? [] : [GitHubPullRequestCheckoutResult.offHeadWarning], worktreePlan: child, worktreeResult: observed)
                try result.validate(plan: plan); return result
            } catch {
                try Task.checkCancellation()
                if attempt == 2 { throw GitHubPullRequestCheckoutError(.staleReview) }
                await Task.yield()
            }
        }
        throw GitHubPullRequestCheckoutError(.staleReview)
    }
    private func validateObservedCheckout(_ local: GitHubPullRequestLocal, plan: GitHubPullRequestCheckoutPlan) throws {
        try local.repository.validate(expected: plan.proof.destinationIdentity)
        try local.admin.validate(expected: plan.proof.destinationGitDirectoryIdentity)
        try local.common.validate(expected: plan.proof.commonDirectoryIdentity)
        guard local.repository.path == plan.destinationPath, local.admin.path == plan.proof.destinationGitDirectoryPath,
              local.common.path == plan.commonDirectoryPath, local.branch == plan.proof.destinationBranch else { throw GitHubPullRequestCheckoutError(.staleReview) }
    }
}
