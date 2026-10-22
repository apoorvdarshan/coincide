import Foundation

extension GitHubPullRequestCheckoutService {
    func fetchHead(_ plan: GitHubPullRequestCheckoutPlan, local: GitHubPullRequestLocal, protocols: String) async throws {
        let destination = Self.headRef(plan.id)
        var fetched = false
        if let remote = plan.headRemote {
            try validateTransport(remote)
            let result = try await git(["fetch", "--quiet", "--no-tags", "--no-prune", "--no-recurse-submodules", "--no-write-fetch-head", "--", remote.url,
                "refs/heads/" + plan.pullRequest.headBranch + ":" + destination], local: local, protocols: protocols, allowFailure: true)
            fetched = result.status == 0
        }
        if !fetched {
            try Task.checkCancellation(); try validateTransport(plan.baseRemote)
            guard try await optionalCommit(destination, local: local) == nil else { throw GitHubPullRequestCheckoutError(.incomplete) }
            _ = try await git(["fetch", "--quiet", "--no-tags", "--no-prune", "--no-recurse-submodules", "--no-write-fetch-head", "--", plan.baseRemote.url,
                "refs/pull/" + String(plan.pullRequest.reference.number) + "/head:" + destination], local: local, protocols: protocols)
        }
        guard try await optionalCommit(destination, local: local) == plan.requestedHeadCommit else { throw GitHubPullRequestCheckoutError(.staleReview) }
    }
    func retainPrevious(_ commit: String, plan: GitHubPullRequestCheckoutPlan, local: GitHubPullRequestLocal) async throws {
        _ = try await git(["update-ref", Self.previousRef(plan.id), commit, ""], local: local)
    }
    func materializeBranch(_ plan: GitHubPullRequestCheckoutPlan, local: GitHubPullRequestLocal) async throws {
        let inventory = try await worktrees(source: plan.repositoryPath).inventory()
        guard !inventory.worktrees.contains(where: { $0.branch == plan.requestedBranch && !$0.isBare }) else { throw GitHubPullRequestCheckoutError(.branchInUse) }
        let current = try await optionalCommit("refs/heads/" + plan.requestedBranch, local: local)
        guard current == plan.existingBranchCommit else { throw GitHubPullRequestCheckoutError(.staleReview) }
        if current == plan.requestedHeadCommit { return }
        if let current {
            let ancestor = try await git(["merge-base", "--is-ancestor", current, plan.requestedHeadCommit], local: local, allowFailure: true)
            let remoteName = try await configuration("branch." + plan.requestedBranch + ".remote", local: local)
            let merge = try await configuration("branch." + plan.requestedBranch + ".merge", local: local)
            let knownHead = plan.pullRequest.headRepository.map { repository in
                local.remotes.first { $0.name == remoteName }?.repository == repository
                    && merge == "refs/heads/" + plan.pullRequest.headBranch
            } ?? false
            guard ancestor.status == 0 || (knownHead && current == plan.proof.previousUpstreamCommit) else { throw GitHubPullRequestCheckoutError(.branchCollision) }
            try await retainPrevious(current, plan: plan, local: local)
            guard try await optionalCommit("refs/heads/" + plan.requestedBranch, local: local) == current else { throw GitHubPullRequestCheckoutError(.staleReview) }
            // update-ref's expected-old argument preserves an external advance
            // after our read. Recheck registered worktrees around the CAS; Git
            // provides no atomic ref-and-worktree-registration transaction.
            let beforeUpdate = try await worktrees(source: plan.repositoryPath).inventory()
            guard !beforeUpdate.worktrees.contains(where: { $0.branch == plan.requestedBranch && !$0.isBare }) else { throw GitHubPullRequestCheckoutError(.branchInUse) }
            let update = try await git(["update-ref", "--no-deref", "refs/heads/" + plan.requestedBranch, plan.requestedHeadCommit, current], local: local, allowFailure: true)
            guard update.status == 0 else { throw GitHubPullRequestCheckoutError(.staleReview) }
            let afterUpdate = try await worktrees(source: plan.repositoryPath).inventory()
            guard !afterUpdate.worktrees.contains(where: { $0.branch == plan.requestedBranch && !$0.isBare }) else { throw GitHubPullRequestCheckoutError(.branchInUse) }
        } else {
            _ = try await git(["branch", "--no-track", "--", plan.requestedBranch, plan.requestedHeadCommit], local: local)
        }
    }
    func refresh(_ plan: GitHubPullRequestCheckoutPlan, local: GitHubPullRequestLocal, allowRewrite: Bool) async throws -> Bool {
        guard let head = try await optionalCommit("HEAD", local: local) else { throw GitHubPullRequestCheckoutError(.invalidResponse) }
        if head == plan.requestedHeadCommit { return false }
        guard try await status(local).isEmpty else {
            if allowRewrite { return false }; throw GitHubPullRequestCheckoutError(.dirtyCheckout)
        }
        let ancestor = try await git(["merge-base", "--is-ancestor", head, plan.requestedHeadCommit], local: local, allowFailure: true)
        // The sealed destination proof includes this old upstream mapping. A
        // branch tracking another repository or ref is not PR-owned merely
        // because its HEAD equals that unrelated upstream's previous commit.
        let exactUpstream: Bool
        if let repository = plan.pullRequest.headRepository, let remote = local.upstreamRemote {
            exactUpstream = local.upstreamBranch == plan.pullRequest.headBranch
                && local.remotes.first(where: { $0.name == remote })?.repository == repository
        } else { exactUpstream = false }
        let canRewrite = allowRewrite && exactUpstream && head == plan.proof.previousUpstreamCommit
        if ancestor.status != 0 && !canRewrite {
            if allowRewrite { return false }
            // A branch already containing the PR is safely kept ahead; divergence
            // is a failed checkout, never an implicit hard reset.
            let ahead = try await git(["merge-base", "--is-ancestor", plan.requestedHeadCommit, head], local: local, allowFailure: true)
            if ahead.status == 0 { return false }
            throw GitHubPullRequestCheckoutError(.branchCollision)
        }
        try await protectUntracked(commit: plan.requestedHeadCommit, local: local)
        if ancestor.status != 0 { try await retainPrevious(head, plan: plan, local: local) }
        let arguments = ancestor.status == 0
            ? ["-c", "merge.autostash=false", "merge", "--ff-only", "--no-autostash", "--no-edit", "--no-overwrite-ignore", plan.requestedHeadCommit]
            : ["-c", "submodule.recurse=false", "reset", "--merge", plan.requestedHeadCommit]
        let result = try await git(arguments, local: local, allowFailure: true)
        if result.status != 0 {
            if allowRewrite { return false }; throw GitHubPullRequestCheckoutError(.commandFailed)
        }
        guard try await optionalCommit("HEAD", local: local) == plan.requestedHeadCommit else { throw GitHubPullRequestCheckoutError(.staleReview) }
        return true
    }
    func configureTracking(_ plan: GitHubPullRequestCheckoutPlan, local: GitHubPullRequestLocal, protocols: String) async throws -> Bool {
        guard let remote = plan.headRemote else { return false }
        do {
            try validateTransport(remote)
            // The local file override is a fixture transport only. Persist the
            // verified host/repository URL, never that override or any credentials.
            if let url = try await configuration("remote." + remote.name + ".url", local: local) {
                guard try GitHubPullRequestService.remoteRepository(url) == remote.repository else { return false }
            } else {
                guard remote.needsCreation else { return false }
                _ = try await git(["remote", "add", "--", remote.name, remote.configurationURL], local: local)
            }
            _ = try await git(["fetch", "--quiet", "--no-tags", "--no-prune", "--no-recurse-submodules", "--no-write-fetch-head", "--", remote.url,
                "+refs/heads/" + plan.pullRequest.headBranch + ":refs/remotes/" + remote.name + "/" + plan.pullRequest.headBranch], local: local, protocols: protocols)
            guard try await optionalCommit("refs/remotes/" + remote.name + "/" + plan.pullRequest.headBranch, local: local) == plan.requestedHeadCommit else { return false }
            _ = try await git(["branch", "--set-upstream-to=" + remote.name + "/" + plan.pullRequest.headBranch, "--", plan.requestedBranch], local: local)
            return true
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return false }
    }
}
