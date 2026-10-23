import Foundation

public enum GitHubPullRequestMergeMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    case merge, squash, rebase
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .merge: String(localized: "Create a merge commit")
        case .squash: String(localized: "Squash and merge")
        case .rebase: String(localized: "Rebase and merge")
        }
    }
    var graphQLName: String { rawValue.uppercased() }
}

/// T3's PullRequestAction set. Every write is reviewed against a fresh state read first.
public enum GitHubPullRequestAction: Codable, Sendable, Equatable, Hashable {
    case merge(GitHubPullRequestMergeMethod)
    case enableAutoMerge(GitHubPullRequestMergeMethod)
    case disableAutoMerge
    case ready, draft, close, reopen
    case updateBranch(rebase: Bool)
    case deleteBranch, revert, approveWorkflows

    public var title: String {
        switch self {
        case .merge(let method): method.title
        case .enableAutoMerge(let method): String(localized: "Enable Auto-Merge (\(method.title))")
        case .disableAutoMerge: String(localized: "Disable Auto-Merge")
        case .ready: String(localized: "Mark Ready for Review")
        case .draft: String(localized: "Convert to Draft")
        case .close: String(localized: "Close Pull Request")
        case .reopen: String(localized: "Reopen Pull Request")
        case .updateBranch(let rebase): rebase ? String(localized: "Update Branch by Rebase") : String(localized: "Update Branch with Merge")
        case .deleteBranch: String(localized: "Delete Head Branch")
        case .revert: String(localized: "Create Revert Pull Request")
        case .approveWorkflows: String(localized: "Approve Waiting Workflows")
        }
    }
    public var isDestructive: Bool { [.close, .deleteBranch].contains(self) }
    public var mergeMethod: GitHubPullRequestMergeMethod? {
        switch self { case .merge(let method), .enableAutoMerge(let method): method; default: nil }
    }
    /// Agent-credit cleanup only applies where GitHub writes a merge commit body.
    public var supportsMergeBody: Bool { mergeMethod.map { $0 != .rebase } ?? false }
}

public struct GitHubRepositoryPermissions: Codable, Sendable, Equatable {
    public let admin: Bool, maintain: Bool, push: Bool, triage: Bool
    public var canWrite: Bool { admin || maintain || push }
    public init(admin: Bool = false, maintain: Bool = false, push: Bool = false, triage: Bool = false) {
        self.admin = admin; self.maintain = maintain; self.push = push; self.triage = triage
    }
}

public struct GitHubRepositoryMergeSettings: Codable, Sendable, Equatable {
    public let allowMergeCommit: Bool, allowSquashMerge: Bool, allowRebaseMerge: Bool, allowAutoMerge: Bool
    public var methods: [GitHubPullRequestMergeMethod] {
        [allowMergeCommit ? .merge : nil, allowSquashMerge ? .squash : nil, allowRebaseMerge ? .rebase : nil].compactMap { $0 }
    }
    public init(allowMergeCommit: Bool = true, allowSquashMerge: Bool = true, allowRebaseMerge: Bool = true, allowAutoMerge: Bool = false) {
        self.allowMergeCommit = allowMergeCommit; self.allowSquashMerge = allowSquashMerge; self.allowRebaseMerge = allowRebaseMerge; self.allowAutoMerge = allowAutoMerge
    }
}

public struct GitHubPullRequestActionState: Codable, Sendable, Equatable {
    public let reference: GitHubPullRequestReference
    public let nodeID: String
    public let title: String
    public let url: String
    public let state: GitHubPullRequestState
    public let isDraft: Bool
    public let headBranch: String
    public let baseBranch: String
    public let headCommit: String
    public let baseCommit: String
    public let headRepository: GitHubRepository?
    public let isCrossRepository: Bool
    /// GitHub's `mergeable` (MERGEABLE, CONFLICTING, UNKNOWN).
    public let mergeable: String?
    /// GitHub's `mergeStateStatus` (CLEAN, BLOCKED, BEHIND, DIRTY, DRAFT, HAS_HOOKS, UNSTABLE, UNKNOWN).
    public let mergeStateStatus: String?
    public let autoMergeMethod: GitHubPullRequestMergeMethod?
    public let autoMergeEnabled: Bool
    public let permissions: GitHubRepositoryPermissions
    public let mergeSettings: GitHubRepositoryMergeSettings
    /// Workflow runs waiting for maintainer approval on a fork head; nil when not applicable.
    public let pendingWorkflowRuns: [Int]?

    public init(reference: GitHubPullRequestReference, nodeID: String, title: String, url: String, state: GitHubPullRequestState, isDraft: Bool,
                headBranch: String, baseBranch: String, headCommit: String, baseCommit: String, headRepository: GitHubRepository?, isCrossRepository: Bool,
                mergeable: String? = nil, mergeStateStatus: String? = nil, autoMergeMethod: GitHubPullRequestMergeMethod? = nil, autoMergeEnabled: Bool = false,
                permissions: GitHubRepositoryPermissions, mergeSettings: GitHubRepositoryMergeSettings = .init(), pendingWorkflowRuns: [Int]? = nil) throws {
        self.reference = reference; self.nodeID = nodeID; self.title = title; self.url = url; self.state = state; self.isDraft = isDraft
        self.headBranch = headBranch; self.baseBranch = baseBranch; self.headCommit = headCommit; self.headRepository = headRepository
        self.baseCommit = baseCommit
        self.isCrossRepository = isCrossRepository; self.mergeable = mergeable; self.mergeStateStatus = mergeStateStatus
        self.autoMergeMethod = autoMergeMethod; self.autoMergeEnabled = autoMergeEnabled; self.permissions = permissions
        self.mergeSettings = mergeSettings; self.pendingWorkflowRuns = pendingWorkflowRuns; try validate()
    }
    public func validate() throws {
        try reference.validate(); try headRepository?.validate()
        guard GitHubValidation.text(nodeID, maximum: 256), nodeID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 61, 95].contains($0) }),
              GitHubValidation.text(title, maximum: 4_096), GitHubValidation.pullRequestURL(url, reference: reference),
              GitHubValidation.branch(headBranch), GitHubValidation.branch(baseBranch), GitHubValidation.object(headCommit), GitHubValidation.object(baseCommit),
              [mergeable, mergeStateStatus].allSatisfy({ $0.map { GitHubValidation.text($0, maximum: 64) } ?? true }),
              (pendingWorkflowRuns?.count ?? 0) <= 100, pendingWorkflowRuns?.allSatisfy({ $0 > 0 }) ?? true else { throw GitHubPullRequestError(.invalidResponse) }
    }
    var sameRepositoryHead: Bool { !isCrossRepository && (headRepository == nil || headRepository == reference.repository) }

    /// Actions offered for the current state and the viewer's repository permission, in T3's order.
    public var availableActions: [GitHubPullRequestAction] {
        guard permissions.canWrite else { return [] }
        var actions: [GitHubPullRequestAction] = []
        switch state {
        case .open:
            if !isDraft { actions += mergeSettings.methods.map { .merge($0) } }
            if autoMergeEnabled { actions.append(.disableAutoMerge) }
            else if !isDraft, mergeSettings.allowAutoMerge { actions += mergeSettings.methods.map { .enableAutoMerge($0) } }
            actions.append(isDraft ? .ready : .draft)
            if mergeStateStatus?.uppercased() == "BEHIND" { actions += [.updateBranch(rebase: false), .updateBranch(rebase: true)] }
            if isCrossRepository, pendingWorkflowRuns?.isEmpty == false { actions.append(.approveWorkflows) }
            actions.append(.close)
        case .closed:
            actions.append(.reopen)
            if sameRepositoryHead, headBranch != baseBranch { actions.append(.deleteBranch) }
        case .merged:
            actions.append(.revert)
            if sameRepositoryHead, headBranch != baseBranch { actions.append(.deleteBranch) }
        }
        return actions
    }
    /// A reason shown beside an offered action that GitHub will probably refuse right now.
    public func warning(for action: GitHubPullRequestAction) -> String? {
        guard case .merge = action else { return nil }
        switch (mergeable?.uppercased(), mergeStateStatus?.uppercased()) {
        case ("CONFLICTING", _), (_, "DIRTY"): return String(localized: "This branch has conflicts with the base branch. Resolve them before merging.")
        case (_, "BLOCKED"): return String(localized: "Required reviews or checks are not satisfied. GitHub may refuse this merge; auto-merge waits for them instead.")
        case (_, "BEHIND"): return String(localized: "The head branch is behind its base. GitHub may require updating it first.")
        case (_, "UNSTABLE"): return String(localized: "Some checks are failing or pending.")
        case ("UNKNOWN", _), (_, "UNKNOWN"): return String(localized: "GitHub is still calculating mergeability.")
        default: return nil
        }
    }
}

/// The exact state a person confirmed. `perform` refuses when the fresh state no longer matches.
public struct GitHubPullRequestActionReview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let reviewedAt: Date
    public let action: GitHubPullRequestAction
    public let state: GitHubPullRequestActionState
    /// The cleaned merge body that will be sent, only when cleanup changed GitHub's default.
    public let mergeBody: String?
    public let originalMergeBody: String?
    public let workflowRunIDs: [Int]
    public init(id: UUID = UUID(), reviewedAt: Date = Date(), action: GitHubPullRequestAction, state: GitHubPullRequestActionState,
                mergeBody: String? = nil, originalMergeBody: String? = nil, workflowRunIDs: [Int] = []) {
        self.id = id; self.reviewedAt = reviewedAt; self.action = action; self.state = state
        self.mergeBody = mergeBody; self.originalMergeBody = originalMergeBody; self.workflowRunIDs = workflowRunIDs
    }
    public func validate() throws {
        try state.validate()
        guard reviewedAt.timeIntervalSince1970.isFinite, workflowRunIDs.count <= 100,
              Set(workflowRunIDs).count == workflowRunIDs.count, workflowRunIDs.allSatisfy({ $0 > 0 }),
              (action == .approveWorkflows ? Set(workflowRunIDs).isSubset(of: Set(state.pendingWorkflowRuns ?? [])) : workflowRunIDs.isEmpty) else {
            throw GitHubPullRequestActionError(.refused)
        }
        if let mergeBody {
            guard action.supportsMergeBody, let originalMergeBody,
                  GitHubValidation.text(mergeBody, maximum: 1_048_576, allowEmpty: true, multiline: true),
                  GitHubValidation.text(originalMergeBody, maximum: 1_048_576, allowEmpty: true, multiline: true),
                  PullRequestMergeMessage.removeAgentCredits(originalMergeBody) == mergeBody else {
                throw GitHubPullRequestActionError(.refused)
            }
        } else if originalMergeBody != nil { throw GitHubPullRequestActionError(.refused) }
    }
}

public struct GitHubPullRequestActionOutcome: Codable, Sendable, Equatable {
    public let action: GitHubPullRequestAction
    public let message: String
    public let revertReference: GitHubPullRequestReference?
    public let revertURL: String?
    public let approvedRuns: Int
    public init(action: GitHubPullRequestAction, message: String, revertReference: GitHubPullRequestReference? = nil, revertURL: String? = nil, approvedRuns: Int = 0) {
        self.action = action; self.message = message; self.revertReference = revertReference; self.revertURL = revertURL; self.approvedRuns = approvedRuns
    }
}

public struct GitHubPullRequestActionError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable { case unavailable, staleReview, refused, rejected, uncertain }
    public let kind: Kind
    public let detail: String?
    public init(_ kind: Kind, detail: String? = nil) { self.kind = kind; self.detail = detail.map(Self.sanitize) }
    public var errorDescription: String? {
        let base: String = switch kind {
        case .unavailable: String(localized: "This action is not available for the pull request's current state or your permission.")
        case .staleReview: String(localized: "The pull request changed after you reviewed this action. Review its current state again.")
        case .refused: String(localized: "Coincide refused this action because it could not be verified as safe.")
        case .rejected: String(localized: "GitHub rejected this action.")
        case .uncertain: String(localized: "GitHub may already have applied this action. Refresh its state before another attempt; this request will not be repeated.")
        }
        guard let detail, !detail.isEmpty else { return base }
        return base + "\n" + detail
    }
    static func sanitize(_ text: String) -> String {
        let clean = String(String.UnicodeScalarView(GitService.redactURLs(text).unicodeScalars.filter { $0.value >= 32 && $0.value != 127 || $0 == "\n" }))
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 2_000 ? String(trimmed.prefix(2_000)) + "…" : trimmed
    }
}

public protocol GitHubPullRequestActionSession: Sendable {
    func actionState(_ reference: GitHubPullRequestReference) async throws -> GitHubPullRequestActionState
    func reviewAction(_ action: GitHubPullRequestAction, reference: GitHubPullRequestReference, removeAgentCredits: Bool) async throws -> GitHubPullRequestActionReview
    func perform(_ review: GitHubPullRequestActionReview) async throws -> GitHubPullRequestActionOutcome
}

/// GitHub merge and state actions through the installed `gh`, scoped to the checkout's base
/// repository. Never uses `--admin`, never deletes or switches local branches, and never retries a
/// write whose outcome is unknown.
public struct GitHubPullRequestActionService: GitHubPullRequestActionSession, Sendable {
    let base: GitHubPullRequestService
    public init(base: GitHubPullRequestService) { self.base = base }
    public init(root: URL) { base = .init(root: root) }

    static let stateFields = "id,number,title,url,state,isDraft,headRefName,baseRefName,headRefOid,baseRefOid,headRepository,headRepositoryOwner,isCrossRepository,updatedAt,mergeable,mergeStateStatus,autoMergeRequest"

    public func actionState(_ reference: GitHubPullRequestReference) async throws -> GitHubPullRequestActionState {
        try reference.validate()
        let local = try await base.localContext()
        guard try local.baseRepository() == reference.repository else { throw GitHubPullRequestError(.invalidRequest) }
        return try await readState(reference, local: local)
    }

    public func reviewAction(_ action: GitHubPullRequestAction, reference: GitHubPullRequestReference, removeAgentCredits: Bool) async throws -> GitHubPullRequestActionReview {
        let local = try await base.localContext()
        guard try local.baseRepository() == reference.repository else { throw GitHubPullRequestError(.invalidRequest) }
        let state = try await readState(reference, local: local)
        guard state.availableActions.contains(action) else { throw GitHubPullRequestActionError(.unavailable) }
        var body: String?, original: String?
        if removeAgentCredits, action.supportsMergeBody, let method = action.mergeMethod {
            let message = try await mergeMessage(reference, method: method, local: local)
            guard message.head == state.headCommit else { throw GitHubPullRequestActionError(.staleReview) }
            let cleaned = PullRequestMergeMessage.removeAgentCredits(message.body)
            if cleaned != message.body { body = cleaned; original = message.body }
        }
        let runs = action == .approveWorkflows ? (state.pendingWorkflowRuns ?? []) : []
        return .init(action: action, state: state, mergeBody: body, originalMergeBody: original, workflowRunIDs: runs)
    }

    public func perform(_ review: GitHubPullRequestActionReview) async throws -> GitHubPullRequestActionOutcome {
        try review.validate()
        let reviewed = review.state, reference = reviewed.reference
        let local = try await base.localContext()
        guard try local.baseRepository() == reference.repository else { throw GitHubPullRequestError(.invalidRequest) }
        let current = try await readState(reference, local: local)
        guard current.nodeID == reviewed.nodeID, current.headCommit == reviewed.headCommit,
              current.baseCommit == reviewed.baseCommit, current.baseBranch.utf8.elementsEqual(reviewed.baseBranch.utf8),
              current.state == reviewed.state, current.isDraft == reviewed.isDraft,
              current.autoMergeEnabled == reviewed.autoMergeEnabled, current.headBranch.utf8.elementsEqual(reviewed.headBranch.utf8),
              current.autoMergeMethod == reviewed.autoMergeMethod, current.isCrossRepository == reviewed.isCrossRepository,
              current.headRepository == reviewed.headRepository, current.availableActions.contains(review.action) else { throw GitHubPullRequestActionError(.staleReview) }
        let host = reference.repository.host, selector = reference.repository.selector, number = String(reference.number)
        switch review.action {
        case .merge(let method), .enableAutoMerge(let method):
            var arguments = ["pr", "merge", number, "--repo=" + selector, "--" + method.rawValue, "--match-head-commit=" + reviewed.headCommit]
            if case .enableAutoMerge = review.action { arguments.insert("--auto", at: 4) }
            var input: Data?
            if let body = review.mergeBody, method != .rebase {
                // A head move between review and write would pair this body with other commits.
                let message = try await mergeMessage(reference, method: method, local: local)
                guard message.head == reviewed.headCommit, PullRequestMergeMessage.removeAgentCredits(message.body) == body else { throw GitHubPullRequestActionError(.staleReview) }
                arguments.append("--body-file=-"); input = Data(body.utf8)
            }
            try await write(arguments, local: local, host: host, input: input)
        case .disableAutoMerge: try await write(["pr", "merge", number, "--repo=" + selector, "--disable-auto"], local: local, host: host)
        case .ready: try await write(["pr", "ready", number, "--repo=" + selector], local: local, host: host)
        case .draft: try await write(["pr", "ready", number, "--repo=" + selector, "--undo"], local: local, host: host)
        case .close: try await write(["pr", "close", number, "--repo=" + selector], local: local, host: host)
        case .reopen: try await write(["pr", "reopen", number, "--repo=" + selector], local: local, host: host)
        case .updateBranch(let rebase):
            _ = try await graphQL("mutation($id:ID!,$oid:GitObjectID!,$method:PullRequestBranchUpdateMethod!){updatePullRequestBranch(input:{pullRequestId:$id,expectedHeadOid:$oid,updateMethod:$method}){pullRequest{headRefOid}}}",
                                  variables: ["id": reviewed.nodeID, "oid": reviewed.headCommit, "method": rebase ? "REBASE" : "MERGE"], local: local, host: host, write: true)
        case .deleteBranch:
            guard reviewed.state != .open, reviewed.sameRepositoryHead, reviewed.headBranch != reviewed.baseBranch else { throw GitHubPullRequestActionError(.refused) }
            let repository = reference.repository, ref = "refs/heads/" + reviewed.headBranch
            let data = try await graphQL("query($owner:String!,$name:String!,$ref:String!){repository(owner:$owner,name:$name){id defaultBranchRef{name} ref(qualifiedName:$ref){target{oid}}}}",
                                         variables: ["owner": repository.owner, "name": repository.name, "ref": ref], local: local, host: host, write: false)
            guard let row = (try GitHubPullRequestJSON.object(data)["data"] as? [String: Any])?["repository"] as? [String: Any],
                  let id = row["id"] as? String, GitHubValidation.text(id, maximum: 256) else { throw GitHubPullRequestActionError(.refused) }
            guard let target = row["ref"] as? [String: Any] else {
                return .init(action: review.action, message: String(localized: "The head branch was already deleted."))
            }
            guard let defaultName = (row["defaultBranchRef"] as? [String: Any])?["name"] as? String, defaultName != reviewed.headBranch else { throw GitHubPullRequestActionError(.refused) }
            guard (target["target"] as? [String: Any])?["oid"] as? String == reviewed.headCommit else { throw GitHubPullRequestActionError(.staleReview) }
            _ = try await graphQL("mutation($id:ID!,$ref:GitRefname!,$before:GitObjectID!){updateRefs(input:{repositoryId:$id,refUpdates:[{name:$ref,beforeOid:$before,afterOid:\"0000000000000000000000000000000000000000\"}]}){clientMutationId}}",
                                  variables: ["id": id, "ref": ref, "before": reviewed.headCommit], local: local, host: host, write: true)
        case .revert:
            let data = try await graphQL("mutation($id:ID!){revertPullRequest(input:{pullRequestId:$id}){revertPullRequest{number url}}}",
                                         variables: ["id": reviewed.nodeID], local: local, host: host, write: true)
            let created = ((try? GitHubPullRequestJSON.object(data)["data"] as? [String: Any])?["revertPullRequest"] as? [String: Any])?["revertPullRequest"] as? [String: Any]
            if let number = created?["number"] as? Int, let url = created?["url"] as? String,
               let revert = try? GitHubPullRequestReference(repository: reference.repository, number: number), GitHubValidation.pullRequestURL(url, reference: revert) {
                return .init(action: review.action, message: String(localized: "Created revert pull request #\(number)."), revertReference: revert, revertURL: url)
            }
            throw GitHubPullRequestActionError(.uncertain)
        case .approveWorkflows:
            guard reviewed.isCrossRepository else { throw GitHubPullRequestActionError(.refused) }
            var approved = 0
            for run in review.workflowRunIDs {
                // Each approval re-checks that the fork head is still the reviewed commit.
                let fresh = try await readState(reference, local: local)
                guard fresh.nodeID == reviewed.nodeID, fresh.headCommit == reviewed.headCommit, fresh.baseCommit == reviewed.baseCommit,
                      fresh.baseBranch.utf8.elementsEqual(reviewed.baseBranch.utf8), fresh.headBranch.utf8.elementsEqual(reviewed.headBranch.utf8), fresh.headRepository == reviewed.headRepository else {
                    throw GitHubPullRequestActionError(.staleReview, detail: approved > 0 ? String(localized: "\(approved) workflow runs were approved before the change.") : nil)
                }
                guard fresh.pendingWorkflowRuns?.contains(run) == true else { continue }
                try await write(["api", "--hostname=" + host, "--method=POST", "repos/" + reference.repository.nameWithOwner + "/actions/runs/" + String(run) + "/approve"], local: local, host: host)
                approved += 1
            }
            return .init(action: review.action, message: String(localized: "Approved \(approved) workflow runs."), approvedRuns: approved)
        }
        return .init(action: review.action, message: String(localized: "\(review.action.title) finished."))
    }

    // MARK: Reads

    func readState(_ reference: GitHubPullRequestReference, local: GitHubPullRequestLocal) async throws -> GitHubPullRequestActionState {
        let view = try await base.run(["pr", "view", String(reference.number), "--repo=" + reference.repository.selector, "--json=" + Self.stateFields],
                                      local: local, repository: reference.repository)
        let row = try GitHubPullRequestJSON.object(view.output)
        let summary = try GitHubPullRequestJSON.summary(row, repository: reference.repository)
        guard summary.reference == reference else { throw GitHubPullRequestError(.invalidResponse) }
        let repository = try GitHubPullRequestJSON.object(try await base.run(["api", "--hostname=" + reference.repository.host, "--method=GET", "repos/" + reference.repository.nameWithOwner],
                                                                              local: local, repository: reference.repository).output)
        guard (repository["full_name"] as? String)?.lowercased() == reference.repository.nameWithOwner else { throw GitHubPullRequestError(.invalidResponse) }
        let permissions = repository["permissions"] as? [String: Any] ?? [:]
        func flag(_ row: [String: Any], _ key: String, _ fallback: Bool = false) -> Bool { row[key] as? Bool ?? fallback }
        let auto = row["autoMergeRequest"] as? [String: Any]
        let isCross = row["isCrossRepository"] as? Bool ?? (summary.headRepository != reference.repository)
        var pending: [Int]?
        if isCross, summary.state == .open, let owner = summary.headRepository?.owner {
            pending = try await waitingRuns(reference, head: summary.headCommit, branch: summary.headBranch, owner: owner, local: local)
        }
        return try .init(reference: reference, nodeID: GitHubPullRequestJSON.string(row, "id"), title: summary.title, url: summary.url, state: summary.state,
                         isDraft: summary.isDraft, headBranch: summary.headBranch, baseBranch: summary.baseBranch, headCommit: summary.headCommit, baseCommit: summary.baseCommit,
                         headRepository: summary.headRepository, isCrossRepository: isCross, mergeable: row["mergeable"] as? String,
                         mergeStateStatus: row["mergeStateStatus"] as? String,
                         autoMergeMethod: (auto?["mergeMethod"] as? String).flatMap { GitHubPullRequestMergeMethod(rawValue: $0.lowercased()) }, autoMergeEnabled: auto != nil,
                         permissions: .init(admin: flag(permissions, "admin"), maintain: flag(permissions, "maintain"), push: flag(permissions, "push"), triage: flag(permissions, "triage")),
                         mergeSettings: .init(allowMergeCommit: flag(repository, "allow_merge_commit", true), allowSquashMerge: flag(repository, "allow_squash_merge", true),
                                              allowRebaseMerge: flag(repository, "allow_rebase_merge", true), allowAutoMerge: flag(repository, "allow_auto_merge")),
                         pendingWorkflowRuns: pending)
    }

    private func waitingRuns(_ reference: GitHubPullRequestReference, head: String, branch: String, owner: String, local: GitHubPullRequestLocal) async throws -> [Int] {
        let endpoint = "repos/" + reference.repository.nameWithOwner + "/actions/runs?status=action_required&head_sha=" + head + "&per_page=100"
        let result = try await base.run(["api", "--hostname=" + reference.repository.host, "--method=GET", endpoint], local: local, repository: reference.repository, allowFailure: true)
        // Repositories without Actions or without permission to list runs have nothing to approve here.
        guard result.status == 0 else { return [] }
        let runs = try GitHubPullRequestJSON.object(result.output)["workflow_runs"] as? [[String: Any]] ?? []
        return Array(runs.compactMap { run -> Int? in
            guard let id = run["id"] as? Int, id > 0, run["head_sha"] as? String == head, run["head_branch"] as? String == branch,
                  ((run["head_repository"] as? [String: Any])?["owner"] as? [String: Any])?["login"].flatMap({ ($0 as? String)?.lowercased() }) == owner.lowercased() else { return nil }
            return id
        }.prefix(100))
    }

    private func mergeMessage(_ reference: GitHubPullRequestReference, method: GitHubPullRequestMergeMethod, local: GitHubPullRequestLocal) async throws -> (head: String, body: String) {
        let data = try await graphQL("query($owner:String!,$name:String!,$number:Int!,$method:PullRequestMergeMethod!){repository(owner:$owner,name:$name){pullRequest(number:$number){headRefOid viewerMergeBodyText(mergeType:$method)}}}",
                                     variables: ["owner": reference.repository.owner, "name": reference.repository.name, "method": method.graphQLName],
                                     integers: ["number": reference.number], local: local, host: reference.repository.host, write: false)
        guard let row = ((try GitHubPullRequestJSON.object(data)["data"] as? [String: Any])?["repository"] as? [String: Any])?["pullRequest"] as? [String: Any],
              let head = row["headRefOid"] as? String, GitHubValidation.object(head),
              let body = row["viewerMergeBodyText"] as? String, GitHubValidation.text(body, maximum: 1_048_576, allowEmpty: true, multiline: true) else { throw GitHubPullRequestError(.invalidResponse) }
        return (head, body)
    }

    // MARK: Writes

    private func graphQL(_ query: String, variables: [String: String], integers: [String: Int] = [:], local: GitHubPullRequestLocal, host: String, write: Bool) async throws -> Data {
        var arguments = ["api", "graphql", "--hostname=" + host, "-f", "query=" + query]
        for (key, value) in variables.sorted(by: { $0.key < $1.key }) { arguments += ["-f", key + "=" + value] }
        for (key, value) in integers.sorted(by: { $0.key < $1.key }) { arguments += ["-F", key + "=" + String(value)] }
        if write { return try await self.write(arguments, local: local, host: host, graphQL: true) }
        let result = try await base.run(arguments, local: local, repository: try local.baseRepository())
        if let errors = (try? GitHubPullRequestJSON.object(result.output))?["errors"] as? [[String: Any]], !errors.isEmpty { throw GitHubPullRequestError(.invalidResponse) }
        return result.output
    }

    @discardableResult
    private func write(_ arguments: [String], local: GitHubPullRequestLocal, host: String, input: Data? = nil, graphQL: Bool = false) async throws -> Data {
        try local.validate(); try Task.checkCancellation()
        let result: GitWorktreeCommandResult
        do { result = try await base.command.run(arguments, directory: local.workspace, host: host, input: input) }
        catch let error as GitHubPullRequestError where error.kind == .missingCLI { throw error }
        catch { throw GitHubPullRequestActionError(.uncertain) }
        let errorText = String(decoding: result.errorOutput, as: UTF8.self)
        let outputText = String(decoding: result.output, as: UTF8.self)
        if result.status == 0 {
            guard graphQL else { return result.output }
            if let errors = (try? GitHubPullRequestJSON.object(result.output))?["errors"] as? [[String: Any]], !errors.isEmpty {
                throw GitHubPullRequestActionError(.rejected, detail: errors.compactMap { $0["message"] as? String }.joined(separator: "\n"))
            }
            return result.output
        }
        if outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, GitHubPullRequestService.isAuthenticationFailure(result) { throw GitHubPullRequestError(.unauthenticated) }
        let lower = (errorText + "\n" + outputText).lowercased()
        if lower.contains("head branch was modified") || (lower.contains("head commit") && lower.contains("match")) || lower.contains("expected head") {
            throw GitHubPullRequestActionError(.staleReview, detail: errorText)
        }
        // A response GitHub returned is a definite refusal; anything else (lost connection,
        // signal, unknown exit) may have been applied server-side and is never repeated.
        if lower.contains("http 4") || lower.contains("graphql:") || lower.contains("not mergeable") || lower.contains("is not mergeable") ||
            lower.contains("already") || lower.contains("must be") || lower.contains("not allowed") || lower.contains("cannot") || (lower.contains("could not") && lower.contains("resolve")) {
            throw GitHubPullRequestActionError(.rejected, detail: errorText.isEmpty ? outputText : errorText)
        }
        throw GitHubPullRequestActionError(.uncertain, detail: errorText)
    }
}
