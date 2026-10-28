import Foundation

/// The pull request workspace, ported from T3 Code: the open pull requests of a thread's repository, one pull
/// request's description and checks, merging, marking ready for review, and checking one out in a worktree of its
/// own. Everything goes through the GitHub CLI (`gh`) with the user's own sign-in, as creating pull requests does.
@MainActor
public final class PullRequestService {
    public static let shared = PullRequestService(git: .shared)

    /// Whether a folder's pull requests can be listed, and if not, why.
    public enum Availability: Sendable, Equatable {
        case ready
        case notRepository
        /// The repository has no remote to list pull requests from.
        case noRemote
        /// The remote is on another host, such as GitLab, named here.
        case unsupportedHost(String)
        /// `gh` is missing or signed out.
        case needsGitHubCLI
    }

    /// What preparing a pull request's worktree made: where it is, and whether it already existed.
    public struct Worktree: Sendable, Equatable {
        public var path: String
        public var branch: String
        /// The branch was already checked out in a worktree, which is used as it is.
        public var reused: Bool
    }

    /// Shown when `gh` is missing or signed out.
    public nonisolated static var setupMessage: String {
        String(localized: "Install the GitHub CLI (gh) and run “gh auth login” to see this repository’s pull requests.")
    }

    /// Open pull requests per list are capped here; `gh` pages through GitHub's results up to it.
    public nonisolated static let listLimit = 100

    private let git: GitService
    private var lists: [String: (value: [PullRequestSummary], date: Date)] = [:]
    private var listTasks: [String: Task<[PullRequestSummary], Error>] = [:]
    private var mergeMethodCache: [String: (value: [PullRequestMergeMethod], date: Date)] = [:]

    public init(git: GitService) {
        self.git = git
    }

    /// Whether `cwd`'s pull requests can be listed: a GitHub repository (or one on a host Coincide doesn't know,
    /// which `gh` may still serve) with `gh` signed in.
    public func availability(_ cwd: URL) async -> Availability {
        guard await git.isRepository(cwd) else { return .notRepository }
        guard let host = await git.sourceControlHost(cwd) else { return .noRemote }
        guard host.kind == .github || host.kind == .unknown else { return .unsupportedHost(host.displayName) }
        guard await git.isChangeRequestToolReady(.gh, for: host, in: cwd) else { return .needsGitHubCLI }
        return .ready
    }

    /// The last list read for `filter` in `cwd`, however old, for showing at once while a fresh one loads.
    public func cachedPullRequests(_ filter: PullRequestFilter, in cwd: URL) -> [PullRequestSummary]? {
        lists[listKey(filter, cwd)]?.value
    }

    /// The open pull requests matching `filter`, newest first. A list read less than `maxAge` seconds ago is
    /// reused, and concurrent reads of the same list share one `gh` run.
    public func pullRequests(_ filter: PullRequestFilter, in cwd: URL, maxAge: TimeInterval = 30) async throws
        -> [PullRequestSummary]
    {
        let key = listKey(filter, cwd)
        if let cached = lists[key], Date().timeIntervalSince(cached.date) < maxAge { return cached.value }
        if let running = listTasks[key] { return try await running.value }
        let task = Task { try await Self.list(filter, in: cwd) }
        listTasks[key] = task
        defer { if listTasks[key] == task { listTasks[key] = nil } }
        let value = try await task.value
        lists[key] = (value, Date())
        return value
    }

    /// One pull request with its description and checks.
    public func pullRequest(_ number: Int, in cwd: URL) async throws -> PullRequestDetail {
        let output = try await Self.run(
            PullRequestCommands.view(number), in: cwd, failure: String(localized: "Could not load pull request #\(number)."))
        guard let detail = PullRequestJSON.detail(output) else {
            throw GitError(String(localized: "Could not read pull request #\(number)."))
        }
        return detail
    }

    /// The merge methods the repository allows, cached for ten minutes. All three when its settings can't be read,
    /// leaving `gh` to refuse one the repository doesn't allow.
    public func mergeMethods(in cwd: URL) async -> [PullRequestMergeMethod] {
        let key = cwd.standardizedFileURL.path
        if let cached = mergeMethodCache[key], Date().timeIntervalSince(cached.date) < 600 { return cached.value }
        guard let result = await GitCLI.gh(PullRequestCommands.mergeSettings, in: cwd, timeout: 20), result.succeeded
        else { return PullRequestMergeMethod.allCases }
        let methods = PullRequestJSON.mergeMethods(result.stdout)
        mergeMethodCache[key] = (methods, Date())
        return methods
    }

    /// Merges the pull request on GitHub with `method`. Its branch stays, local and remote.
    public func merge(_ number: Int, method: PullRequestMergeMethod, in cwd: URL) async throws {
        defer { forgetLists() }
        try await Self.run(
            PullRequestCommands.merge(number, method: method), in: cwd,
            failure: String(localized: "Could not merge pull request #\(number)."), timeout: 120)
    }

    /// Takes a draft pull request out of draft, asking for reviews.
    public func markReady(_ number: Int, in cwd: URL) async throws {
        defer { forgetLists() }
        try await Self.run(
            PullRequestCommands.ready(number), in: cwd,
            failure: String(localized: "Could not mark pull request #\(number) ready for review."))
    }

    /// A worktree on the pull request's branch, for a thread of its own (T3 Code's "Checkout pull request" in a
    /// worktree). A worktree that already has the branch checked out is used as it is; the project folder having it
    /// is an error, since git checks a branch out in one place only. Otherwise a new worktree is made detached, and
    /// `gh pr checkout` puts the branch in it: `gh` knows how to fetch a fork's branch and set it up to push back.
    public func prepareWorktree(for pullRequest: PullRequestSummary, in project: URL, branchPrefix: String) async throws
        -> Worktree
    {
        guard let checkout = await GitOps.repositoryRoot(project) else {
            throw GitError(String(localized: "This folder is not a Git repository."))
        }
        let root = await git.mainWorktree(of: checkout) ?? checkout
        let branch = PullRequestCheckout.localBranch(for: pullRequest, prefix: branchPrefix)
        if let existing = try await GitOps.worktrees(root).first(where: { $0.branch == branch }) {
            guard !existing.isMain else {
                throw GitError(
                    String(localized: "Pull request #\(pullRequest.number)’s branch is checked out in the project folder."),
                    detail: String(
                        localized: "Switch the project folder to another branch, or start a thread in the project folder instead."))
            }
            return Worktree(path: existing.path, branch: branch, reused: true)
        }
        guard await GitCLI.ghExecutable() != nil else { throw GitError(Self.setupMessage) }

        let path = try git.newWorktreePath(repositoryName: root.lastPathComponent, branch: branch)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await GitCLI.checked(
            String(localized: "Could not create the worktree."), ["worktree", "add", "--detach", "--", path.path], in: root,
            timeout: 300)
        let submodules = FileManager.default.fileExists(atPath: path.appendingPathComponent(".gitmodules").path)
        let result = await GitCLI.gh(
            PullRequestCommands.checkout(pullRequest.number, branch: branch, submodules: submodules), in: path, timeout: 600)
        guard let result, result.succeeded else {
            // Nothing was made in it yet, so it goes without asking.
            try? await GitOps.removeWorktree(path, in: root, force: true)
            let action = String(localized: "Could not check out pull request #\(pullRequest.number).")
            throw result.map { GitError.failed(action, $0) } ?? GitError(Self.setupMessage)
        }
        // The branch diff compares against the pull request's base rather than guessing one.
        if await GitOps.configValue(BranchNames.mergeBaseConfigKey(branch), in: root) == nil {
            _ = await GitCLI.git(["config", BranchNames.mergeBaseConfigKey(branch), pullRequest.baseBranch], in: root)
        }
        git.notifyChange(root)
        return Worktree(path: path.path, branch: branch, reused: false)
    }

    // MARK: Running gh

    private func listKey(_ filter: PullRequestFilter, _ cwd: URL) -> String {
        "\(cwd.standardizedFileURL.path)\u{0}\(filter.rawValue)"
    }

    /// Merging or readying a pull request changes what the lists show.
    private func forgetLists() {
        lists.removeAll()
    }

    @concurrent private nonisolated static func list(_ filter: PullRequestFilter, in cwd: URL) async throws
        -> [PullRequestSummary]
    {
        let output = try await run(
            PullRequestCommands.list(filter, limit: listLimit), in: cwd,
            failure: String(localized: "Could not load the pull requests."))
        guard let list = PullRequestJSON.list(output) else {
            throw GitError(String(localized: "Could not read the pull requests."))
        }
        return list
    }

    /// Runs `gh`, returning what it printed, or throwing `failure` with `gh`'s own explanation.
    @discardableResult
    @concurrent private nonisolated static func run(
        _ arguments: [String], in cwd: URL, failure: String, timeout: TimeInterval = 60
    ) async throws -> String {
        guard let result = await GitCLI.gh(arguments, in: cwd, timeout: timeout) else { throw GitError(setupMessage) }
        guard result.succeeded else { throw GitError.failed(failure, result) }
        return result.stdout
    }
}
