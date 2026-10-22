import Foundation

extension GitHubPullRequestCheckoutService {
    /// Seal execution and transport policy without unrelated branches' tracking,
    /// user identity or presentation settings. Values are hashed, never persisted.
    func policyConfigurationDigest(_ local: GitHubPullRequestLocal) async throws -> String {
        let pattern = #"^(core\.|extensions\.|worktree\.|protocol\.|url\.|http\.|https\.|ssh\.|credential\.|filter\.|submodule\.|fetch\.|transfer\.|pack\.|index\.|feature\.|include\.|includeif\.|safe\.)"#
        let result = try await git(["config", "--null", "--show-origin", "--get-regexp", pattern], local: local, allowFailure: true)
        guard result.status == 0 || result.status == 1 else { throw GitHubPullRequestCheckoutError(.staleReview) }
        return GitHubPullRequestService.digest(result.output)
    }
    func repositoryFingerprint(_ local: GitHubPullRequestLocal, baseRemote: GitHubPullRequestCheckoutRemote,
                               headRemote: GitHubPullRequestCheckoutRemote?) async throws -> String {
        guard try local.baseRepository() == request.reference.repository else { throw GitHubPullRequestCheckoutError(.staleReview) }
        let selected = [baseRemote] + (headRemote.map { [$0] } ?? [])
        for remote in selected {
            let current = try await configuration("remote." + remote.name + ".url", local: local)
            guard current == remote.configurationURL || (current == nil && remote.needsCreation) else { throw GitHubPullRequestCheckoutError(.staleReview) }
        }
        struct Proof: Encodable {
            let paths: [String]
            let identities: [GitWorktreeNodeIdentity]
            let pointers: [String]
            let policy: String
            let remotes: [GitHubPullRequestCheckoutRemote]
        }
        let proof = Proof(paths: [local.workspace.path, local.repository.path, local.admin.path, local.common.path],
            identities: [local.workspace.identity, local.repository.identity, local.admin.identity, local.common.identity],
            pointers: [local.pointer, local.commonPointer, local.backlink].map { GitHubPullRequestService.digest($0 ?? Data()) },
            policy: try await policyConfigurationDigest(local), remotes: selected)
        return GitHubPullRequestService.digest(try encode(proof))
    }
    func destinationFingerprint(_ local: GitHubPullRequestLocal, plan: GitHubPullRequestCheckoutPlan) async throws -> String {
        try await destinationFingerprint(local, baseRemote: plan.baseRemote, headRemote: plan.headRemote)
    }
    func destinationFingerprint(_ local: GitHubPullRequestLocal, baseRemote: GitHubPullRequestCheckoutRemote,
                                headRemote: GitHubPullRequestCheckoutRemote?) async throws -> String {
        struct Proof: Encodable {
            let repository: String
            let head: String?
            let branch: String?
            let upstreamRemote: String?
            let upstreamBranch: String?
            let pushOverride: String?
        }
        return GitHubPullRequestService.digest(try encode(Proof(repository: try await repositoryFingerprint(local, baseRemote: baseRemote, headRemote: headRemote),
            head: local.head, branch: local.branch, upstreamRemote: local.upstreamRemote,
            upstreamBranch: local.upstreamBranch, pushOverride: local.pushOverride)))
    }
}
