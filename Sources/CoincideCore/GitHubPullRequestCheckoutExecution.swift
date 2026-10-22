import Foundation

struct GitHubPullRequestCheckoutOwnership: Codable {
    let plan: GitHubPullRequestCheckoutPlan
    let identity: GitWorktreeNodeIdentity
}
struct GitHubPullRequestCheckoutCompletion: Codable {
    let ownership: GitHubPullRequestCheckoutOwnership
    let result: GitHubPullRequestCheckoutResult
    let sourceFingerprint: String
    let sourceStatusDigest: String
    let sourceIndexDigest: String?
    let destinationFingerprint: String
    let destinationStatusDigest: String
    let destinationIndexDigest: String?
    let sourceConfigurationDigest: String
    let destinationConfigurationDigest: String
}

extension GitHubPullRequestCheckoutService {
    static func metadataName(_ id: UUID) -> String { ".coincide-pr-checkout-" + id.uuidString }
    static func headRef(_ id: UUID) -> String { "refs/coincide/pull-requests/" + id.uuidString.lowercased() + "/head" }
    static func previousRef(_ id: UUID) -> String { "refs/coincide/pull-requests/" + id.uuidString.lowercased() + "/before" }
    func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return try encoder.encode(value) }
    func execute(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutResult {
        var mayHaveChanged = false
        do {
            let initial = try await metadata.localContext()
            try await assertSource(initial, plan: plan, original: false)
            if try initial.common.exists(Self.metadataName(plan.id)) {
                if case .completed(let result) = try await inspect(plan) { return result }
                throw GitHubPullRequestCheckoutError(.incomplete, mayHaveChanged: true)
            }
            try await assertSource(initial, plan: plan, original: true)
            let reviewed = try await metadata.detail(plan.request.reference).summary
            guard reviewed.headCommit == plan.requestedHeadCommit, reviewed.headRepository == plan.pullRequest.headRepository,
                  reviewed.headBranch == plan.pullRequest.headBranch else { throw GitHubPullRequestCheckoutError(.staleReview) }
            let parent = try GitWorktreeDirectory(path: URL(fileURLWithPath: plan.destinationPath).deletingLastPathComponent().path)
            try parent.validate(expected: plan.destinationParentIdentity)
            if plan.disposition == .createWorktree, try parent.exists(plan.id.uuidString) { throw GitHubPullRequestCheckoutError(.staleReview) }
            if plan.disposition == .reuseWorktree || plan.disposition == .reuseUnrelatedWorktree {
                let reused = try await self.local(at: plan.destinationPath)
                try await assertReuse(reused, plan: plan)
            }
            guard try await optionalCommit("refs/heads/" + plan.requestedBranch, local: initial) == plan.existingBranchCommit,
                  try await optionalCommit(Self.headRef(plan.id), local: initial) == nil,
                  try await optionalCommit(Self.previousRef(plan.id), local: initial) == nil else { throw GitHubPullRequestCheckoutError(.staleReview) }
            let owned = try initial.common.claimDirectory(Self.metadataName(plan.id))
            let ownership = GitHubPullRequestCheckoutOwnership(plan: plan, identity: owned.identity)
            try owned.writeExclusive(encode(ownership), name: "plan.json")
            let lock = try owned.lock("execution.lock"); defer { withExtendedLifetime(lock) {} }
            try Task.checkCancellation()
            let beforeStart = try await metadata.localContext()
            try await assertSource(beforeStart, plan: plan, original: true)
            try owned.writeExclusive(Data("started\n".utf8), name: "started")
            mayHaveChanged = true
            var warnings: [String] = []
            var childPlan: GitWorktreePlan?, childResult: GitWorktreeResult?
            var moved = false
            if plan.disposition != .reuseUnrelatedWorktree {
                let protocols = try await protocols(local: initial)
                try await fetchHead(plan, local: initial, protocols: protocols)
                let afterFetch = try await metadata.localContext()
                try await assertSource(afterFetch, plan: plan, original: true)
                if plan.disposition == .local {
                    guard try await trackedStatus(initial).isEmpty else { throw GitHubPullRequestCheckoutError(.dirtyCheckout) }
                    try await protectUntracked(commit: plan.requestedHeadCommit, local: initial)
                    if let old = plan.existingBranchCommit { try await protectUntracked(commit: old, local: initial) }
                    if plan.existingBranchCommit == nil {
                        _ = try await git(["switch", "--no-guess", "--no-recurse-submodules", "--no-overwrite-ignore", "--no-track", "--create", plan.requestedBranch, "--", plan.requestedHeadCommit], local: initial)
                    } else {
                        _ = try await git(["switch", "--no-guess", "--no-recurse-submodules", "--no-overwrite-ignore", "--", plan.requestedBranch], local: initial)
                        let switched = try await self.local(at: plan.repositoryPath)
                        moved = try await refresh(plan, local: switched, allowRewrite: false)
                    }
                    let currentHead = try await optionalCommit("HEAD", local: initial)
                    moved = moved || plan.proof.headCommit != currentHead || plan.proof.branch != plan.requestedBranch
                } else if plan.disposition == .reuseWorktree {
                    let checkout = try await local(at: plan.destinationPath)
                    try await assertReuse(checkout, plan: plan)
                    moved = try await refresh(plan, local: checkout, allowRewrite: true)
                } else {
                    try await materializeBranch(plan, local: initial)
                }
                if plan.disposition != .createWorktree {
                    let target = try await local(at: plan.destinationPath)
                    if !(try await configureTracking(plan, local: target, protocols: protocols)) { warnings.append(GitHubPullRequestCheckoutResult.trackingWarning) }
                }
            }
            if plan.request.mode == .worktree {
                let selection: GitWorktreeSelection = plan.disposition == .createWorktree ? .existingBranch(name: plan.requestedBranch) : .reuse(path: plan.destinationPath)
                let request = GitWorktreeRequest(id: plan.id, sourcePath: plan.repositoryPath, destinationRoot: plan.request.destinationRoot,
                    selection: selection, submodules: plan.disposition == .createWorktree ? plan.request.submodules : .none)
                let service = worktrees(request: request), prepared = try await service.prepare()
                guard prepared.destinationPath == plan.destinationPath, prepared.commonDirectoryPath == plan.commonDirectoryPath else { throw GitHubPullRequestCheckoutError(.staleReview) }
                try owned.writeExclusive(encode(prepared), name: "worktree-plan.json")
                childPlan = prepared; childResult = try await service.runHoldingOperationGate(prepared)
                if let warning = childResult?.submoduleWarning { warnings.append(warning) }
                if plan.disposition == .createWorktree {
                    moved = true
                    let checkout = try await local(at: plan.destinationPath)
                    let allowed = try await self.protocols(local: checkout)
                    if !(try await configureTracking(plan, local: checkout, protocols: allowed)), !warnings.contains(GitHubPullRequestCheckoutResult.trackingWarning) { warnings.append(GitHubPullRequestCheckoutResult.trackingWarning) }
                }
            }
            let source = try await metadata.localContext(), checkout = try await local(at: plan.destinationPath)
            try await assertSource(source, plan: plan, original: false)
            guard let head = checkout.head, let branch = checkout.branch else { throw GitHubPullRequestCheckoutError(.invalidResponse) }
            // A bare-name fork alias belongs to another checkout's branch. A
            // coincidentally equal SHA does not make it the reviewed PR branch.
            let onHead = plan.disposition != .reuseUnrelatedWorktree && head == plan.requestedHeadCommit
            if !onHead { warnings.append(GitHubPullRequestCheckoutResult.offHeadWarning) }
            let result = GitHubPullRequestCheckoutResult(destinationPath: plan.destinationPath, branch: branch, headCommit: head,
                isOnPullRequestHead: onHead, created: plan.disposition == .createWorktree,
                reused: plan.request.mode == .worktree && plan.disposition != .createWorktree,
                moved: moved, warnings: warnings, worktreePlan: childPlan, worktreeResult: childResult)
            try result.validate(plan: plan)
            let latest = try await metadata.detail(plan.request.reference).summary
            guard latest.headCommit == plan.requestedHeadCommit, latest.headRepository == plan.pullRequest.headRepository,
                  latest.headBranch == plan.pullRequest.headBranch else { throw GitHubPullRequestCheckoutError(.staleReview) }
            let sourceStatus = try await status(source), destinationStatus = try await status(checkout)
            let sourceConfiguration = try await configurationDigest(source), destinationConfiguration = try await configurationDigest(checkout)
            let completion = try GitHubPullRequestCheckoutCompletion(ownership: ownership, result: result,
                sourceFingerprint: source.proof, sourceStatusDigest: GitHubPullRequestService.digest(sourceStatus), sourceIndexDigest: indexDigest(source),
                destinationFingerprint: checkout.proof, destinationStatusDigest: GitHubPullRequestService.digest(destinationStatus), destinationIndexDigest: indexDigest(checkout),
                sourceConfigurationDigest: sourceConfiguration, destinationConfigurationDigest: destinationConfiguration)
            try Task.checkCancellation(); try owned.validate(expected: ownership.identity)
            try owned.writeExclusive(encode(completion), name: "complete.json")
            guard case .completed(let recorded) = try await inspect(plan), recorded == result else { throw GitHubPullRequestCheckoutError(.incomplete) }
            return result
        } catch {
            if let typed = error as? GitHubPullRequestCheckoutError { throw GitHubPullRequestCheckoutError(typed.kind, mayHaveChanged: mayHaveChanged || typed.mayHaveChanged) }
            if error is CancellationError, !mayHaveChanged { throw CancellationError() }
            throw GitHubPullRequestCheckoutError(.commandFailed, mayHaveChanged: mayHaveChanged)
        }
    }
    func inspect(_ plan: GitHubPullRequestCheckoutPlan) async throws -> GitHubPullRequestCheckoutInspection {
        let source = try await metadata.localContext()
        try await assertSource(source, plan: plan, original: false)
        guard try source.common.exists(Self.metadataName(plan.id)) else { return .unconfirmed }
        let directory = try GitWorktreeDirectory(child: Self.metadataName(plan.id), parent: source.common)
        guard let owned = try directory.read("plan.json"), let data = try directory.read("complete.json") else { return .unconfirmed }
        let ownership = try JSONDecoder().decode(GitHubPullRequestCheckoutOwnership.self, from: owned)
        let completion = try JSONDecoder().decode(GitHubPullRequestCheckoutCompletion.self, from: data)
        guard ownership.plan == plan, ownership.identity == directory.identity,
              completion.ownership.plan == plan, completion.ownership.identity == directory.identity else { return .unconfirmed }
        try completion.result.validate(plan: plan)
        let checkout = try await local(at: plan.destinationPath)
        guard source.proof == completion.sourceFingerprint, checkout.proof == completion.destinationFingerprint,
              try await configurationDigest(source) == completion.sourceConfigurationDigest,
              try await configurationDigest(checkout) == completion.destinationConfigurationDigest,
              try indexDigest(source) == completion.sourceIndexDigest, try indexDigest(checkout) == completion.destinationIndexDigest,
              GitHubPullRequestService.digest(try await status(source)) == completion.sourceStatusDigest,
              GitHubPullRequestService.digest(try await status(checkout)) == completion.destinationStatusDigest,
              checkout.head == completion.result.headCommit, checkout.branch == completion.result.branch else { return .unconfirmed }
        if let child = completion.result.worktreePlan {
            guard try await worktrees(request: child.request).inspectCompletion(child) == completion.result.worktreeResult else { return .unconfirmed }
            guard try directory.read("worktree-plan.json") == encode(child) else { return .unconfirmed }
        }
        try source.validate(); try checkout.validate(); try directory.validate()
        return .completed(completion.result)
    }
}
