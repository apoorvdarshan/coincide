import CoincideKit
import CoincideRemoteKit
import Foundation

/// Git for Coincide Remote, through the calls the Mac's diff panel and pull request workspace make: a thread's
/// folder's status and its stacked commit, push and pull request actions, and a project's pull requests from GitHub.
extension RemoteStoreAdapter {
    // MARK: A thread's folder

    private func folder(of threadID: UUID) throws -> URL {
        _ = try requireThread(threadID)
        guard let cwd = store.workingDirectory(for: threadID) else {
            throw RemoteError(.notFound, String(localized: "The thread’s folder is no longer there."))
        }
        return cwd
    }

    /// The folder's branch and changes, with the actions the Mac's diff panel would enable now.
    func gitState(_ threadID: UUID) async throws -> RemoteGitState {
        let cwd = try folder(of: threadID)
        let git = GitService.shared
        let status: GitStatus
        do {
            status = try await git.status(cwd)
        } catch {
            return RemoteGitState(isRepository: false)
        }
        guard status.isRepository else { return RemoteGitState(isRepository: false) }
        let host = status.hasRemote ? await git.sourceControlHost(cwd, branch: status.branch) : nil
        var pullRequest: GitPullRequest?
        if let branch = status.branch, status.hasUpstream { pullRequest = await git.openPullRequest(for: branch, in: cwd) }
        let progress = gitProgress[threadID]
        let availability = GitActionAvailability.resolve(status: status, isBusy: progress != nil, hasOpenPullRequest: pullRequest != nil)
        return RemoteGitState(
            isRepository: true, branch: status.branch, isDefaultBranch: status.isDefaultBranch, upstream: status.upstream,
            ahead: status.ahead, behind: status.behind, changedFiles: status.files.count, hasRemote: status.hasRemote,
            canCommit: availability.canCommit, canPush: availability.canPush && availability.showsRemoteActions,
            canCreatePullRequest: availability.canCreatePR && availability.showsRemoteActions,
            canPull: progress == nil && status.hasUpstream && status.behind > 0,
            pullRequest: pullRequest.map(Self.remotePullRequest),
            changeRequestName: (host?.kind.changeRequest ?? .pullRequest).title,
            confirmsOnDefaultBranch: GitStackedAction.allCases.filter {
                GitQuickAction.requiresDefaultBranchConfirmation($0, isDefaultBranch: status.isDefaultBranch)
            }.map(\.rawValue),
            progress: progress)
    }

    nonisolated static func remotePullRequest(_ pullRequest: GitPullRequest) -> RemotePullRequest {
        RemotePullRequest(
            number: pullRequest.number, title: pullRequest.title, url: pullRequest.url, headBranch: pullRequest.headBranch,
            baseBranch: pullRequest.baseBranch, state: state(pullRequest.state))
    }

    nonisolated static func state(_ state: GitPullRequest.State) -> RemotePullRequest.State {
        switch state {
        case .open: .open
        case .merged: .merged
        case .closed: .closed
        }
    }

    /// Runs the action as the Mac's diff panel does: the agent writes a blank commit message and the pull request from
    /// the thread's conversation, and a new branch becomes the thread's. One action per thread at a time.
    func gitAction(_ request: RemoteGitActionRequest) async throws -> RemoteGitActionResult {
        let threadID = request.threadID
        let cwd = try folder(of: threadID)
        guard gitProgress[threadID] == nil else {
            throw RemoteError(.notAllowed, String(localized: "A Git action is already running for this thread."))
        }
        gitProgress[threadID] = String(localized: "Starting…")
        defer { gitProgress[threadID] = nil }
        let git = GitService.shared
        do {
            if request.action == .pull {
                let pulled = try await git.pull(cwd)
                return RemoteGitActionResult(
                    title: pulled == .pulled ? String(localized: "Pulled the latest changes") : String(localized: "Already up to date"))
            }
            guard let action = GitStackedAction(rawValue: request.action.rawValue), let thread = store.thread(threadID) else {
                throw RemoteError(.unsupported, String(localized: "This Mac doesn’t know that action."))
            }
            let message = request.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await git.run(
                GitActionRequest(
                    action: action, commitMessage: message?.isEmpty == false ? message : nil, featureBranch: request.featureBranch,
                    selection: thread.selection, threadContext: Handoff.transcript(thread.items, budget: 16_000)),
                in: cwd
            ) { [weak self] step in self?.gitProgress[threadID] = step }
            if let branch = result.createdBranch { store.updateThread(threadID) { $0.branch = branch } }
            var url = result.pullRequest?.url
            switch result.followUp {
            case .openPullRequest(let page)?, .openChangeRequestPage(let page)?: url = page.absoluteString
            default: break
            }
            return RemoteGitActionResult(title: result.title, detail: result.detail, url: url)
        } catch let error as RemoteError {
            throw error
        } catch let error as GitError {
            throw RemoteError(.failed, [error.message, error.detail].compactMap(\.self).joined(separator: "\n"))
        } catch {
            throw RemoteError(.failed, error.localizedDescription)
        }
    }

    // MARK: Pull requests

    private func repository(of projectID: UUID) throws -> URL {
        guard let project = store.project(projectID), !project.isChats, !project.isBots else {
            throw RemoteError(.notFound, String(localized: "That project no longer exists."))
        }
        return project.url
    }

    /// Why the project's pull requests can't be listed, in the Mac's words, or nil when they can.
    nonisolated static func unavailableText(_ availability: PullRequestService.Availability) -> String? {
        switch availability {
        case .ready: nil
        case .notRepository: String(localized: "Pull requests need a Git repository on GitHub.")
        case .noRemote: String(localized: "Push this repository to GitHub to see its pull requests here.")
        case .unsupportedHost(let host): String(localized: "This repository is on \(host). Coincide lists pull requests from GitHub.")
        case .needsGitHubCLI: PullRequestService.setupMessage
        }
    }

    func pullRequests(_ query: RemotePullRequestQuery) async throws -> RemotePullRequestList {
        let cwd = try repository(of: query.projectID)
        guard let filter = PullRequestFilter(rawValue: query.filter) else {
            throw RemoteError(.badRequest, String(localized: "This Mac doesn’t know that filter."))
        }
        let service = PullRequestService.shared
        if let unavailable = Self.unavailableText(await service.availability(cwd)) {
            return RemotePullRequestList(unavailable: unavailable)
        }
        do {
            return RemotePullRequestList(items: try await service.pullRequests(filter, in: cwd).map(Self.remotePullRequest))
        } catch {
            throw Self.remote(error)
        }
    }

    func pullRequest(_ reference: RemotePullRequestReference) async throws -> RemotePullRequestDetail {
        let cwd = try repository(of: reference.projectID)
        let service = PullRequestService.shared
        do {
            let detail = try await service.pullRequest(reference.number, in: cwd)
            let methods = detail.canMerge ? await service.mergeMethods(in: cwd) : []
            return Self.remoteDetail(detail, mergeMethods: methods)
        } catch {
            throw Self.remote(error)
        }
    }

    /// Merges, reviews, marks ready or checks out the pull request as the Mac's workspace does. A checkout opens a new
    /// thread in a worktree of its own (reusing one that has it), without opening it in the Mac's window.
    func perform(_ command: RemotePullRequestCommand) async throws -> RemoteResult {
        let cwd = try repository(of: command.projectID)
        let service = PullRequestService.shared
        do {
            let detail = try await service.pullRequest(command.number, in: cwd)
            switch command.action {
            case .merge:
                guard let method = command.method.flatMap(PullRequestMergeMethod.init(rawValue:)), detail.canMerge else {
                    throw RemoteError(.notAllowed, String(localized: "This pull request can’t be merged now."))
                }
                try await service.merge(detail, method: method, in: cwd)
            case .review:
                let body = command.body ?? ""
                guard let event = command.event.flatMap(PullRequestReviewEvent.init(rawValue:)), event.accepts(body: body) else {
                    throw RemoteError(.badRequest, String(localized: "Write a comment to send with this review."))
                }
                try await service.review(detail, event: event, body: body, in: cwd)
            case .markReady:
                try await service.markReady(command.number, in: cwd)
            case .checkOut:
                let worktree = try await service.prepareWorktree(
                    for: detail.summary, in: cwd, branchPrefix: store.settings.worktreeBranchPrefix)
                return .thread(try newThread(in: command.projectID, worktree: worktree.path, branch: worktree.branch))
            case .unknown:
                throw RemoteError(.unsupported, String(localized: "This Mac doesn’t know that action."))
            }
            return .pullRequest(try await pullRequest(RemotePullRequestReference(projectID: command.projectID, number: command.number)))
        } catch {
            throw Self.remote(error)
        }
    }

    /// A thread in the worktree, reusing an untouched one there.
    private func newThread(in projectID: UUID, worktree path: String, branch: String) throws -> UUID {
        let defaults = store.newThreadDefaults(in: projectID)
        let selection = registry.usableSelection(preferring: defaults.selection)
        if let empty = store.threads(in: projectID).first(where: {
            $0.itemCount == 0 && !$0.hasDraft && !$0.isArchived && $0.worktreePath == path
        }) {
            return empty.id
        }
        let id = store.createThread(in: projectID, selection: selection).id
        store.updateThread(id) { thread in
            thread.worktreePath = path
            thread.branch = branch
        }
        return id
    }

    nonisolated static func remotePullRequest(_ summary: PullRequestSummary) -> RemotePullRequest {
        RemotePullRequest(
            number: summary.number, title: summary.title, url: summary.url, author: summary.author, headBranch: summary.headBranch,
            baseBranch: summary.baseBranch, state: state(summary.state), isDraft: summary.isDraft,
            checks: summary.checksState.map { RemotePullRequest.Checks(rawValue: $0.rawValue) ?? .unknown },
            review: summary.reviewDecision.map { RemotePullRequest.Review(rawValue: $0.rawValue) ?? .unknown },
            updatedAt: summary.updatedAt)
    }

    nonisolated static func remoteDetail(_ detail: PullRequestDetail, mergeMethods: [PullRequestMergeMethod]) -> RemotePullRequestDetail {
        RemotePullRequestDetail(
            pullRequest: remotePullRequest(detail.summary), body: String(detail.body.prefix(60_000)),
            checks: detail.checks.prefix(200).map { .init(name: $0.name, status: $0.status.rawValue, url: $0.url) },
            mergeability: detail.mergeability.rawValue, additions: detail.additions, deletions: detail.deletions,
            changedFiles: detail.changedFiles,
            reviews: detail.reviews.prefix(100).map { .init(author: $0.author, state: $0.state, body: String($0.body.prefix(8_000))) },
            canMerge: detail.canMerge, mergeMethods: mergeMethods.map(\.rawValue))
    }

    private nonisolated static func remote(_ error: Error) -> RemoteError {
        if let remote = error as? RemoteError { return remote }
        if let git = error as? GitError {
            return RemoteError(.failed, [git.message, git.detail].compactMap(\.self).joined(separator: "\n"))
        }
        return RemoteError(.failed, error.localizedDescription)
    }
}
