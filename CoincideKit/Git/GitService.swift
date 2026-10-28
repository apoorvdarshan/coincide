import Foundation

/// Everything Coincide does with git: status, branches, worktrees, diffs, commits, pushes and
/// pull requests. Work runs off the main actor; results come back here.
@MainActor
public final class GitService {
    public static let shared = GitService()

    /// Posted after Coincide changes a repository (commit, checkout, push, worktree…).
    /// userInfo["path"]: String, the folder the change was made in.
    public static let repositoryDidChangeNotification = Notification.Name("coincide.git.repositoryDidChange")

    /// Folder that new worktrees go in, one subfolder per repository.
    public var worktreesRoot: URL
    private var statusTasks: [String: Task<GitStatus, Error>] = [:]
    private var pullRequestCache: [String: (value: GitPullRequest?, date: Date)] = [:]
    private var gitHubReadyCache: [String: (value: Bool, date: Date)] = [:]
    private var toolReadyCache: [String: (value: Bool, date: Date)] = [:]
    private var hostCache: [String: (value: SourceControlHost?, date: Date)] = [:]
    /// What `glab` and `tea` sign-ins made of host names no name identifies, by host.
    private var refinedHostCache: [String: (kind: SourceControlKind, name: String, date: Date)] = [:]
    /// Set by tests: false treats every host CLI as missing or signed out, so nothing reaches a real host.
    var hostToolsOverride: Bool?

    public init(worktreesRoot: URL = GitService.worktreesDirectory) {
        self.worktreesRoot = worktreesRoot
    }

    // MARK: Repository

    /// The git executable to run, or nil when no usable git is installed. Skips the `/usr/bin/git`
    /// shim while the developer tools are missing, since running it brings up their install dialog.
    public nonisolated static func gitExecutable() async -> URL? {
        await GitCLI.gitExecutable()
    }

    public func isRepository(_ url: URL) async -> Bool {
        await GitOps.repositoryRoot(url) != nil
    }

    /// Top of the work tree containing `url`.
    public func repositoryRoot(_ url: URL) async -> URL? {
        await GitOps.repositoryRoot(url)
    }

    public func initializeRepository(_ url: URL) async throws {
        try await GitCLI.checked(String(localized: "Could not initialize a Git repository."), ["init"], in: url)
        notifyChange(url)
    }

    /// Current status. Concurrent requests for the same folder share one read.
    public func status(_ cwd: URL) async throws -> GitStatus {
        let key = cwd.standardizedFileURL.path
        if let running = statusTasks[key] { return try await running.value }
        let task = Task { try await GitOps.status(cwd) }
        statusTasks[key] = task
        defer { if statusTasks[key] == task { statusTasks[key] = nil } }
        return try await task.value
    }

    // MARK: Branches

    /// Local and remote-tracking branches: current first, then the default branch, then by recency.
    public func branches(_ cwd: URL) async throws -> GitBranchList {
        try await GitOps.branches(cwd)
    }

    /// Checks out `branch`; a remote branch gets (or reuses) a local tracking branch.
    /// Returns the branch checked out afterwards, nil when HEAD ended up detached.
    @discardableResult
    public func checkout(_ branch: String, in cwd: URL) async throws -> String? {
        defer { notifyChange(cwd) }
        return try await GitOps.checkout(branch, in: cwd)
    }

    /// Creates a branch from HEAD (whitespace in the name becomes hyphens) and checks it out.
    @discardableResult
    public func createBranch(_ name: String, in cwd: URL, checkout: Bool = true) async throws -> String {
        defer { notifyChange(cwd) }
        return try await GitOps.createBranch(name, in: cwd, checkout: checkout)
    }

    /// Renames a branch, picking a free `-1`, `-2`… variant unless `exactName` is set.
    @discardableResult
    public func renameBranch(_ old: String, to new: String, in cwd: URL, exactName: Bool = false) async throws -> String {
        defer { notifyChange(cwd) }
        return try await GitOps.renameBranch(old, to: new, in: cwd, exactName: exactName)
    }

    // MARK: Worktrees

    public func worktrees(_ cwd: URL) async throws -> [GitWorktree] {
        try await GitOps.worktrees(cwd)
    }

    /// Where Coincide puts the worktrees it creates.
    public nonisolated static var worktreesDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["COINCIDE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("worktrees", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".coincide/worktrees", isDirectory: true)
    }

    /// Creates a worktree on a new branch started from `baseRef` (HEAD when nil).
    public func createWorktree(in repository: URL, branch: String, baseRef: String?, path: URL? = nil) async throws
        -> GitWorktree
    {
        guard let root = await GitOps.repositoryRoot(repository) else {
            throw GitError(String(localized: "This folder is not a Git repository."))
        }
        if path == nil { try Self.prepareWorktreesRoot(worktreesRoot) }
        let destination = path ?? uniqueWorktreePath(repositoryName: root.lastPathComponent, branch: branch)
        let worktree = try await GitOps.createWorktree(
            in: root, branch: branch, baseRef: baseRef, path: destination, recordBase: baseRef)
        notifyChange(root)
        return worktree
    }

    /// Creates a worktree for a thread on a temporary branch named with `prefix`. The branch is
    /// renamed after the thread's first message (see `nameWorktreeBranch`).
    public func createThreadWorktree(projectPath: URL, baseBranch: String?, prefix: String) async throws -> GitWorktree {
        guard let root = await GitOps.repositoryRoot(projectPath) else {
            throw GitError(String(localized: "This folder is not a Git repository."))
        }
        var branch = BranchNames.temporaryWorktreeBranch(prefix: prefix)
        // An existing branch named like the prefix blocks nested refs such as `prefix/abc`.
        if prefix.hasSuffix("/"), await GitOps.refExists("refs/heads/\(prefix.dropLast())", in: root) {
            branch = BranchNames.flattenedTemporaryBranch(branch, prefix: prefix)
        }
        return try await createWorktree(in: root, branch: branch, baseRef: baseBranch)
    }

    /// Removes a worktree. Without `force`, git refuses when it has changes.
    public func removeWorktree(_ path: URL, in repository: URL, force: Bool = false) async throws {
        try await GitOps.removeWorktree(path, in: repository, force: force)
        notifyChange(repository)
    }

    /// Removes a worktree Coincide created for a thread that never used it: only when it has no
    /// changes and its temporary branch has no commits of its own. Returns whether it was removed.
    @discardableResult
    public func discardUnusedWorktree(_ path: URL, branch: String?, prefix: String) async -> Bool {
        guard let worktreeRoot = await GitOps.repositoryRoot(path),
            let status = try? await GitOps.status(worktreeRoot), status.isRepository, !status.hasChanges,
            let repository = await mainWorktree(of: worktreeRoot)
        else { return false }
        do {
            try await GitOps.removeWorktree(worktreeRoot, in: repository, force: false)
        } catch {
            return false
        }
        if let branch, BranchNames.isTemporaryWorktreeBranch(branch, prefix: prefix),
            await GitOps.uniqueCommitCount(branch, in: repository) == 0
        {
            _ = await GitCLI.git(["branch", "-D", "--", branch], in: repository)
        }
        notifyChange(repository)
        return true
    }

    /// The main checkout of the repository `worktree` belongs to.
    public func mainWorktree(of worktree: URL) async -> URL? {
        guard let list = try? await GitOps.worktrees(worktree), let main = list.first(where: \.isMain) else {
            return nil
        }
        return URL(fileURLWithPath: main.path, isDirectory: true)
    }

    /// Renames a thread's temporary worktree branch after what the thread is about.
    /// Returns the new name, or nil when the branch was not temporary.
    public func nameWorktreeBranch(_ branch: String, in worktree: URL, message: String, prefix: String) async throws
        -> String?
    {
        guard BranchNames.isTemporaryWorktreeBranch(branch, prefix: prefix) else { return nil }
        // A flattened `prefix-<token>` branch keeps the flat form, since nested refs are blocked.
        let namePrefix = branch.hasPrefix(prefix) ? prefix : String(branch.dropLast(8))
        let name = BranchNames.descriptiveBranch(for: message, prefix: namePrefix)
        return try await renameBranch(branch, to: name, in: worktree)
    }

    /// Home folders are readable by the `staff` group, which every local account belongs to, so the
    /// folder holding checkouts (of repositories that may be private) is kept owner-only.
    private nonisolated static func prepareWorktreesRoot(_ url: URL) throws {
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        // The attributes also apply to parent folders created here, such as ~/.coincide.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: ownerOnly)
        // Tighten a root an earlier version created as 0755. Best effort, so a root on an odd volume
        // or owned by someone else does not block creating the worktree.
        try? FileManager.default.setAttributes(ownerOnly, ofItemAtPath: url.path)
    }

    private func uniqueWorktreePath(repositoryName: String, branch: String) -> URL {
        let folder = worktreesRoot.appendingPathComponent(repositoryName, isDirectory: true)
        let name = branch.replacingOccurrences(of: "/", with: "-")
        var candidate = folder.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    // MARK: Diffs

    /// Uncommitted changes against HEAD, untracked files included.
    public func workingTreeDiff(_ cwd: URL, ignoreWhitespace: Bool = false) async throws -> GitDiff {
        try await GitOps.diff(cwd, base: .head, ignoreWhitespace: ignoreWhitespace)
    }

    /// Everything on the current branch since it left its base branch, committed or not.
    public func branchDiff(_ cwd: URL, ignoreWhitespace: Bool = false) async throws -> GitDiff {
        try await GitOps.diff(cwd, base: .branch, ignoreWhitespace: ignoreWhitespace)
    }

    /// Parses a unified diff into files and hunks, off the main actor.
    public nonisolated static func parseDiff(_ patch: String, files: [ChangedFile] = []) async -> GitDiff {
        await parseOffMain(patch, files: files)
    }

    /// Counts come from the patch itself, so they follow options such as ignoring whitespace.
    /// `files` fills in entries a truncated patch is missing.
    @concurrent private nonisolated static func parseOffMain(_ patch: String, files: [ChangedFile]) async -> GitDiff {
        var diff = GitOps.assemble(patch: patch, stats: [])
        guard diff.isTruncated else { return diff }
        let parsed = Set(diff.files.map(\.path))
        for file in files where !parsed.contains(file.path) {
            diff.files.append(
                FileDiff(
                    path: file.path, oldPath: file.oldPath, status: file.status, additions: file.additions,
                    deletions: file.deletions))
        }
        diff.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return diff
    }

    // MARK: Commit, push, pull

    /// Stages `paths` (everything when nil) and commits with `subject` and optional `body`.
    public func commit(subject: String, body: String = "", paths: [String]? = nil, in cwd: URL) async throws
        -> GitCommit
    {
        defer { notifyChange(cwd) }
        return try await GitOps.commit(subject: subject, body: body, paths: paths, in: cwd)
    }

    /// Stages `paths` (everything when nil).
    public func stage(_ paths: [String]? = nil, in cwd: URL) async throws {
        defer { notifyChange(cwd) }
        try await GitOps.stage(paths, in: cwd)
    }

    /// Pushes the current branch, setting its upstream when it has none.
    public func push(_ cwd: URL) async throws -> GitPushResult {
        defer {
            pullRequestCache.removeAll()
            notifyChange(cwd)
        }
        return try await GitOps.push(cwd)
    }

    /// Fast-forwards the current branch from its upstream.
    public func pull(_ cwd: URL) async throws -> GitPullResult {
        defer { notifyChange(cwd) }
        return try await GitOps.pull(cwd)
    }

    // MARK: Pull requests

    /// Whether `gh` is installed and signed in, so pull requests can be looked up and created.
    public func isGitHubCLIReady(_ cwd: URL) async -> Bool {
        let key = cwd.standardizedFileURL.path
        if let cached = gitHubReadyCache[key], Date().timeIntervalSince(cached.date) < 300 { return cached.value }
        let ready = await GitHubCLI.isReady(cwd)
        gitHubReadyCache[key] = (ready, Date())
        return ready
    }

    /// Whether `tool` is installed and signed in to `host`, cached for five minutes. `gh` is asked
    /// about as `isGitHubCLIReady` asks.
    public func isChangeRequestToolReady(_ tool: ChangeRequestTool, for host: SourceControlHost?, in cwd: URL) async
        -> Bool
    {
        if let hostToolsOverride { return hostToolsOverride }
        if tool == .gh { return await isGitHubCLIReady(cwd) }
        let key = [tool.rawValue, host?.remote.host ?? "", cwd.standardizedFileURL.path].joined(separator: "\u{0}")
        if let cached = toolReadyCache[key], Date().timeIntervalSince(cached.date) < 300 { return cached.value }
        let ready = await ChangeRequestCLI.isReady(tool, host: host, in: cwd)
        toolReadyCache[key] = (ready, Date())
        return ready
    }

    /// The host of the remote `branch` tracks, else of `origin` (or the first remote), cached for a
    /// minute. Nil without a remote, or for one that names no host, such as a local path. A host no
    /// name identifies becomes GitLab or Forgejo when `glab` or `tea` is signed in to it.
    public func sourceControlHost(_ cwd: URL, branch: String? = nil) async -> SourceControlHost? {
        let key = "\(cwd.standardizedFileURL.path)\u{0}\(branch ?? "")"
        if let cached = hostCache[key], Date().timeIntervalSince(cached.date) < 60 { return cached.value }
        var host = await GitOps.remoteHost(cwd, branch: branch)
        if let unknown = host, unknown.kind == .unknown, hostToolsOverride != false {
            let hostKey = unknown.remote.host
            if let cached = refinedHostCache[hostKey], Date().timeIntervalSince(cached.date) < 300 {
                host = SourceControlHost(kind: cached.kind, name: cached.name, remote: unknown.remote)
            } else {
                let refined = await ChangeRequestCLI.refine(unknown, in: cwd)
                refinedHostCache[hostKey] = (refined.kind, refined.name, Date())
                host = refined
            }
        }
        hostCache[key] = (host, Date())
        return host
    }

    /// The open pull (or merge) request for `branch`, cached for a minute, read with the host's own
    /// CLI: `gh` for GitHub, as before, and for hosts Coincide doesn't know; `glab`, `az` or `tea` for
    /// GitLab, Azure DevOps and Forgejo. Nil when that CLI is missing or signed out, or the host has none.
    public func openPullRequest(for branch: String, in cwd: URL, refresh: Bool = false) async -> GitPullRequest? {
        let key = pullRequestKey(branch, cwd)
        if !refresh, let cached = pullRequestCache[key], Date().timeIntervalSince(cached.date) < 60 {
            return cached.value
        }
        let host = await sourceControlHost(cwd, branch: branch)
        guard let tool = (host?.kind ?? .unknown).tool, await isChangeRequestToolReady(tool, for: host, in: cwd)
        else { return nil }
        let pullRequest = await ChangeRequestCLI.openChangeRequest(for: branch, tool: tool, host: host, in: cwd)
        pullRequestCache[key] = (pullRequest, Date())
        return pullRequest
    }

    /// Opens a pull (or merge) request with the host's CLI: `gh pr create` for GitHub.
    public func createPullRequest(title: String, body: String, base: String, head: String, in cwd: URL) async throws
        -> GitPullRequest
    {
        defer {
            pullRequestCache.removeAll()
            notifyChange(cwd)
        }
        let host = await sourceControlHost(cwd, branch: head)
        guard let tool = (host?.kind ?? .unknown).tool else {
            throw GitError(String(localized: "Create the pull request on \(host?.displayName ?? "") instead."))
        }
        if tool != .gh, await !isChangeRequestToolReady(tool, for: host, in: cwd) { throw GitError(tool.setupMessage) }
        return try await ChangeRequestCLI.create(
            title: title, body: body, base: base, head: head, tool: tool, host: host, in: cwd)
    }

    /// Remembers the change request just created for `branch`, so the next status shows it.
    func rememberPullRequest(_ pullRequest: GitPullRequest, for branch: String, in cwd: URL) {
        pullRequestCache[pullRequestKey(branch, cwd)] = (pullRequest, Date())
    }

    private func pullRequestKey(_ branch: String, _ cwd: URL) -> String {
        "\(cwd.standardizedFileURL.path)\u{0}\(branch)"
    }

    // MARK: Notifications

    func notifyChange(_ url: URL) {
        NotificationCenter.default.post(
            name: Self.repositoryDidChangeNotification, object: self, userInfo: ["path": url.standardizedFileURL.path])
    }
}
