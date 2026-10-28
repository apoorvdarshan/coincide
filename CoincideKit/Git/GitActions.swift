import Foundation

/// A commit / push / pull request sequence, run as one action.
public enum GitStackedAction: String, Sendable, CaseIterable {
    case commit
    case commitPush
    case commitPushPR
    case push
    case createPR

    public nonisolated var includesCommit: Bool { self == .commit || self == .commitPush || self == .commitPushPR }

    public nonisolated var title: String {
        switch self {
        case .commit: String(localized: "Commit")
        case .commitPush: String(localized: "Commit & Push")
        case .commitPushPR: String(localized: "Commit, Push & Create PR")
        case .push: String(localized: "Push")
        case .createPR: String(localized: "Create PR")
        }
    }

    /// The title in the host's words: "Create MR" for GitLab.
    public nonisolated func title(for term: ChangeRequestTerm) -> String {
        switch (self, term) {
        case (.commitPushPR, .mergeRequest): String(localized: "Commit, Push & Create MR")
        case (.createPR, .mergeRequest): String(localized: "Create MR")
        default: title
        }
    }
}

public struct GitActionRequest: Sendable {
    public var action: GitStackedAction
    /// The commit message; blank to have the agent write one.
    public var commitMessage: String?
    /// Files to commit; nil for every change.
    public var filePaths: [String]?
    /// Create a feature branch (named after the change) before committing.
    public var featureBranch: Bool
    /// Model that writes commit messages and pull request descriptions.
    public var selection: ModelSelection?
    /// Transcript of the thread that made the change, given to the pull request writer.
    public var threadContext: String?

    public nonisolated init(
        action: GitStackedAction, commitMessage: String? = nil, filePaths: [String]? = nil, featureBranch: Bool = false,
        selection: ModelSelection? = nil, threadContext: String? = nil
    ) {
        self.action = action
        self.commitMessage = commitMessage
        self.filePaths = filePaths
        self.featureBranch = featureBranch
        self.selection = selection
        self.threadContext = threadContext
    }
}

public struct GitActionResult: Sendable, Equatable {
    public enum FollowUp: Sendable, Equatable {
        case run(GitStackedAction)
        case openPullRequest(URL)
        /// The host's page for opening the pull request in the browser, since no signed-in CLI could.
        case openChangeRequestPage(URL)
    }

    public var createdBranch: String?
    public var commit: GitCommit?
    public var push: GitPushResult?
    public var pullRequest: GitPullRequest?
    public var pullRequestCreated: Bool
    /// One-line summary, such as "Pushed 1a2b3c4 to origin/feature".
    public var title: String
    public var detail: String?
    public var followUp: FollowUp?
    /// The host the branch's remote is on, when the action pushed or opened a pull request.
    public var host: SourceControlHost? = nil
    /// The host's page for creating the pull request, when it is to be finished in the browser.
    public var changeRequestPage: URL? = nil

    /// What the host calls pull requests.
    public nonisolated var changeRequestTerm: ChangeRequestTerm { host?.kind.changeRequest ?? .pullRequest }
}

/// What the git action button offers for a status (T3 Code's quick action rules).
public struct GitQuickAction: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case run(GitStackedAction)
        case pull
        /// Nothing to do; the text explains why.
        case hint(String)
    }

    public var title: String
    public var kind: Kind
    public var isEnabled: Bool

    public nonisolated init(title: String, kind: Kind, isEnabled: Bool) {
        self.title = title
        self.kind = kind
        self.isEnabled = isEnabled
    }

    /// `term` is what the repository's host calls pull requests, for titles such as "Create MR".
    public nonisolated static func resolve(
        status: GitStatus?, isBusy: Bool, hasOpenPullRequest: Bool, term: ChangeRequestTerm = .pullRequest
    ) -> GitQuickAction {
        let commit = String(localized: "Commit")
        guard !isBusy else { return GitQuickAction(title: commit, kind: .hint(String(localized: "A Git action is running.")), isEnabled: false) }
        guard let status, status.isRepository else {
            return GitQuickAction(title: commit, kind: .hint(String(localized: "Git status is unavailable.")), isEnabled: false)
        }
        guard status.branch != nil else {
            let hint =
                term == .mergeRequest
                ? String(localized: "Check out a branch before pushing or opening a merge request.")
                : String(localized: "Check out a branch before pushing or opening a pull request.")
            return GitQuickAction(title: commit, kind: .hint(hint), isEnabled: false)
        }
        let pushAndCreate =
            term == .mergeRequest ? String(localized: "Push & Create MR") : String(localized: "Push & Create PR")
        func run(_ action: GitStackedAction, title: String? = nil) -> GitQuickAction {
            GitQuickAction(title: title ?? action.title(for: term), kind: .run(action), isEnabled: true)
        }
        let isAhead = status.ahead > 0
        let isBehind = status.behind > 0
        let isDefault = status.isDefaultBranch
        let upToDate = GitQuickAction(
            title: commit, kind: .hint(String(localized: "The branch is up to date. Nothing to do.")), isEnabled: false)

        if status.hasChanges {
            if !status.hasUpstream, !status.hasRemote { return run(.commit) }
            return run(hasOpenPullRequest || isDefault ? .commitPush : .commitPushPR)
        }
        if !status.hasUpstream {
            guard status.hasRemote else {
                return GitQuickAction(
                    title: commit, kind: .hint(String(localized: "Add a remote to push this repository.")),
                    isEnabled: false)
            }
            guard isAhead else {
                return hasOpenPullRequest
                    ? upToDate
                    : GitQuickAction(
                        title: String(localized: "Push"), kind: .hint(String(localized: "No local commits to push.")),
                        isEnabled: false)
            }
            return run(hasOpenPullRequest || isDefault ? .push : .createPR, title: isDefault || hasOpenPullRequest ? nil : pushAndCreate)
        }
        if isAhead, isBehind {
            return GitQuickAction(
                title: String(localized: "Sync Branch"),
                kind: .hint(String(localized: "The branch has diverged from its upstream. Rebase or merge first.")),
                isEnabled: false)
        }
        if isBehind { return GitQuickAction(title: String(localized: "Pull"), kind: .pull, isEnabled: true) }
        if isAhead {
            return run(hasOpenPullRequest || isDefault ? .push : .createPR, title: isDefault || hasOpenPullRequest ? nil : pushAndCreate)
        }
        if hasOpenPullRequest { return upToDate }
        if status.aheadOfDefault > 0, !isDefault { return run(.createPR) }
        return upToDate
    }

    /// Pushing to (or opening a pull request from) the default branch asks first.
    public nonisolated static func requiresDefaultBranchConfirmation(_ action: GitStackedAction, isDefaultBranch: Bool)
        -> Bool
    {
        isDefaultBranch && action != .commit
    }
}

/// Which of Commit / Push / Create PR the actions menu enables.
public struct GitActionAvailability: Sendable, Equatable {
    public var canCommit: Bool
    public var canPush: Bool
    public var canCreatePR: Bool
    /// False when the repository has no remote: only Commit applies.
    public var showsRemoteActions: Bool

    public nonisolated static func resolve(status: GitStatus?, isBusy: Bool, hasOpenPullRequest: Bool)
        -> GitActionAvailability
    {
        guard let status, status.isRepository else {
            return GitActionAvailability(canCommit: false, canPush: false, canCreatePR: false, showsRemoteActions: false)
        }
        let hasBranch = status.branch != nil
        let isBehind = status.behind > 0
        let canPublish = status.hasRemote && !status.hasUpstream
        let aheadOfBase = status.aheadOfDefault > 0 || status.ahead > 0
        return GitActionAvailability(
            canCommit: !isBusy && status.hasChanges,
            canPush: !isBusy && hasBranch && !isBehind && status.ahead > 0 && (status.hasUpstream || canPublish),
            canCreatePR: !isBusy && hasBranch && !hasOpenPullRequest && aheadOfBase && !isBehind
                && (status.hasUpstream || canPublish),
            showsRemoteActions: status.hasRemote)
    }
}

extension GitService {
    /// Runs a stacked action: optional feature branch, commit, push and pull request, in order.
    /// `progress` receives a short label for each step.
    public func run(
        _ request: GitActionRequest, in cwd: URL, progress: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> GitActionResult {
        defer {
            notifyChange(cwd)
        }
        let initial = try await GitOps.status(cwd)
        guard initial.isRepository else { throw GitError(String(localized: "This folder is not a Git repository.")) }
        let action = request.action
        let wantsCommit = action.includesCommit
        let wantsPush =
            action == .push || action == .commitPush || action == .commitPushPR
            || (action == .createPR && (!initial.hasUpstream || initial.ahead > 0))
        let wantsPR = action == .createPR || action == .commitPushPR
        if request.featureBranch, !wantsCommit {
            throw GitError(String(localized: "A feature branch can only be created when committing."))
        }
        if !request.featureBranch, wantsPush || wantsPR, initial.branch == nil {
            throw GitError(String(localized: "Cannot push from a detached HEAD."))
        }

        var message: GitWriter.CommitMessage?
        var createdBranch: String?
        if request.featureBranch {
            progress(String(localized: "Preparing feature branch…"))
            let custom = GitWriter.customCommitMessage(request.commitMessage)
            guard
                let context = try await GitOps.commitContext(
                    paths: request.filePaths, in: cwd, includePatch: custom == nil)
            else { throw GitError(String(localized: "There are no changes to commit, so a feature branch can't be named.")) }
            let suggestion: GitWriter.CommitMessage
            if let custom {
                suggestion = custom
            } else {
                suggestion = await GitWriter.commitMessage(
                    context: context, branch: initial.branch, includeBranch: true, selection: request.selection, cwd: cwd)
            }
            message = suggestion
            let existing = (try? await GitOps.branches(cwd))?.local.map(\.name) ?? []
            let name = BranchNames.availableFeatureBranchName(suggestion.branch ?? suggestion.subject, existing: existing)
            createdBranch = try await GitOps.createBranch(name, in: cwd, checkout: true)
        }
        let branch = createdBranch ?? initial.branch

        var commit: GitCommit?
        if wantsCommit {
            if message == nil {
                let custom = GitWriter.customCommitMessage(request.commitMessage)
                if custom == nil { progress(String(localized: "Generating commit message…")) }
                if let context = try await GitOps.commitContext(
                    paths: request.filePaths, in: cwd, includePatch: custom == nil)
                {
                    if let custom {
                        message = custom
                    } else {
                        message = await GitWriter.commitMessage(
                            context: context, branch: branch, includeBranch: false, selection: request.selection,
                            cwd: cwd)
                    }
                }
            }
            if let message {
                progress(String(localized: "Committing…"))
                commit = try await GitOps.commit(
                    subject: message.subject, body: message.body, paths: request.filePaths, in: cwd)
            } else if action == .commit {
                throw GitError(String(localized: "There are no changes to commit."))
            }
        }

        var push: GitPushResult?
        if wantsPush {
            progress(String(localized: "Pushing…"))
            push = try await GitOps.push(cwd, fallbackBranch: branch)
        }

        // The host names the pull request step's words ("merge request" on GitLab) and its follow-ups.
        var host: SourceControlHost?
        if wantsPush || wantsPR, let branch {
            host = await sourceControlHost(cwd, branch: branch)
        }
        let term = host?.kind.changeRequest ?? .pullRequest

        var pullRequest: GitPullRequest?
        var pullRequestCreated = false
        var changeRequestPage: URL?
        if wantsPR {
            progress(
                term == .mergeRequest
                    ? String(localized: "Preparing merge request…") : String(localized: "Preparing pull request…"))
            switch try await runPullRequestStep(request, in: cwd, fallbackBranch: branch, host: host, progress: progress) {
            case .existing(let found): pullRequest = found
            case .created(let created):
                pullRequest = created
                pullRequestCreated = true
            case .page(let page): changeRequestPage = page
            }
        }

        var result = GitActionResult(
            createdBranch: createdBranch, commit: commit, push: push, pullRequest: pullRequest,
            pullRequestCreated: pullRequestCreated, title: "", detail: nil, followUp: nil, host: host,
            changeRequestPage: changeRequestPage)
        await summarize(&result, action: action, in: cwd)
        return result
    }

    private enum PullRequestStep {
        /// The branch already had an open pull request.
        case existing(GitPullRequest)
        case created(GitPullRequest)
        /// No signed-in CLI for the host: the page to create it on, in the browser.
        case page(URL)
    }

    /// Finds or creates the branch's pull request with the host's CLI. Without one signed in, GitHub
    /// (and hosts Coincide can't name) still need `gh`, as before; other hosts give their page for
    /// creating one, as they link to it after a push.
    private func runPullRequestStep(
        _ request: GitActionRequest, in cwd: URL, fallbackBranch: String?, host: SourceControlHost?,
        progress: @MainActor (String) -> Void
    ) async throws -> PullRequestStep {
        let term = host?.kind.changeRequest ?? .pullRequest
        let status = try await GitOps.status(cwd)
        guard let branch = status.branch ?? fallbackBranch else {
            throw GitError(
                term == .mergeRequest
                    ? String(localized: "Cannot create a merge request from a detached HEAD.")
                    : String(localized: "Cannot create a pull request from a detached HEAD."))
        }
        guard status.hasUpstream else {
            throw GitError(
                term == .mergeRequest
                    ? String(localized: "This branch has not been pushed. Push it before creating a merge request.")
                    : String(localized: "This branch has not been pushed. Push it before creating a pull request."))
        }
        let kind = host?.kind ?? .unknown
        let tool = kind.tool
        var isReady = false
        if let tool { isReady = await isChangeRequestToolReady(tool, for: host, in: cwd) }
        guard let tool, isReady else {
            guard let host, kind != .github, kind != .unknown else { throw GitError(GitHubCLI.notReadyMessage) }
            let base = await pullRequestBase(cwd, branch: branch, upstream: status.upstream, host: host, tool: nil)
            if let page = host.newChangeRequestURL(base: base, head: branch) ?? host.repositoryURL { return .page(page) }
            throw GitError(
                tool?.setupMessage
                    ?? String(localized: "Coincide can't find this repository’s page on \(host.displayName)."))
        }
        if let existing = await openPullRequest(for: branch, in: cwd, refresh: true) { return .existing(existing) }

        let base = await pullRequestBase(cwd, branch: branch, upstream: status.upstream, host: host, tool: tool)
        let remotes = await GitOps.remoteNames(cwd)
        var rangeBase = base
        if let remote = GitOps.primaryRemote(remotes), await GitOps.refExists("refs/remotes/\(remote)/\(base)", in: cwd) {
            rangeBase = "\(remote)/\(base)"
        }
        progress(
            term == .mergeRequest ? String(localized: "Writing merge request…") : String(localized: "Writing pull request…"))
        let range = await GitOps.rangeContext(cwd, baseRef: rangeBase)
        let content = await GitWriter.pullRequestContent(
            baseBranch: base, headBranch: branch, range: range, threadContext: request.threadContext,
            selection: request.selection, cwd: cwd)
        progress(
            term == .mergeRequest
                ? String(localized: "Creating merge request…") : String(localized: "Creating pull request…"))
        let created = try await ChangeRequestCLI.create(
            title: content.title, body: content.body, base: base, head: branch, tool: tool, host: host, in: cwd)
        rememberPullRequest(created, for: branch, in: cwd)
        return .created(created)
    }

    /// The branch a pull request should target: the recorded base, a differently named upstream,
    /// the repository's default branch (as the host's CLI knows it, else as git does), then `main`.
    private func pullRequestBase(
        _ cwd: URL, branch: String, upstream: String?, host: SourceControlHost?, tool: ChangeRequestTool?
    ) async -> String {
        let remotes = await GitOps.remoteNames(cwd)
        func branchName(_ ref: String) -> String {
            var name = ref
            for prefix in ["refs/heads/", "refs/remotes/"] where name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
            if let remote = remotes.filter({ name.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
                name = String(name.dropFirst(remote.count + 1))
            }
            return name
        }
        if let configured = await GitOps.configValue(BranchNames.mergeBaseConfigKey(branch), in: cwd) {
            let name = branchName(configured)
            if !name.isEmpty, name != branch { return name }
        }
        if let upstream {
            let name = branchName(upstream)
            if !name.isEmpty, name != branch { return name }
        }
        if let tool, let name = await ChangeRequestCLI.defaultBranch(tool: tool, host: host, in: cwd) { return name }
        if let remote = GitOps.primaryRemote(remotes), let name = await GitOps.defaultBranch(cwd, remote: remote) {
            return name
        }
        return "main"
    }

    private func summarize(_ result: inout GitActionResult, action: GitStackedAction, in cwd: URL) async {
        let term = result.changeRequestTerm
        var pushed: String?
        if let push = result.push, push.outcome == .pushed {
            let target = push.upstream ?? push.branch
            pushed =
                result.commit.map { String(localized: "Pushed \($0.shortSHA) to \(target)") }
                ?? String(localized: "Pushed to \(target)")
        }
        if let pullRequest = result.pullRequest {
            switch (term, result.pullRequestCreated) {
            case (.pullRequest, true): result.title = String(localized: "Created PR #\(pullRequest.number)")
            case (.pullRequest, false): result.title = String(localized: "Opened PR #\(pullRequest.number)")
            case (.mergeRequest, true): result.title = String(localized: "Created MR !\(pullRequest.number)")
            case (.mergeRequest, false): result.title = String(localized: "Opened MR !\(pullRequest.number)")
            }
            result.detail = pullRequest.title
        } else if let page = result.changeRequestPage {
            let name = result.host?.displayName ?? ""
            result.title =
                term == .mergeRequest
                ? String(localized: "Create the merge request on \(name)")
                : String(localized: "Create the pull request on \(name)")
            result.detail = pushed
            result.followUp = .openChangeRequestPage(page)
            return
        } else if let pushed {
            result.title = pushed
            result.detail = result.commit?.subject
        } else if let commit = result.commit {
            result.title = String(localized: "Committed \(commit.shortSHA)")
            result.detail = commit.subject
        } else if result.push?.outcome == .upToDate {
            result.title = String(localized: "Already up to date")
        } else {
            result.title = String(localized: "Done")
        }

        if action == .commit, result.commit != nil {
            result.followUp = .run(.push)
            return
        }
        let status = try? await GitOps.status(cwd)
        let isDefault = status?.isDefaultBranch ?? false
        var openPullRequest = result.pullRequest
        if openPullRequest == nil, action == .push || action == .commitPush, result.push?.outcome == .pushed,
            result.createdBranch == nil, !isDefault, let branch = status?.branch
        {
            openPullRequest = await self.openPullRequest(for: branch, in: cwd, refresh: true)
        }
        if let openPullRequest, let url = URL(string: openPullRequest.url), !openPullRequest.url.isEmpty,
            !isDefault || result.pullRequest != nil
        {
            result.followUp = .openPullRequest(url)
        } else if action == .push || action == .commitPush, result.push?.outcome == .pushed, !isDefault {
            result.followUp = .run(.createPR)
        }
    }
}
