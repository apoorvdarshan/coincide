import Foundation

/// The git operations behind `GitService`. Each runs off the main actor and returns plain values.
enum GitOps {
    /// Keeps untracked-file previews bounded; beyond this the working tree diff omits them.
    static let maxUntrackedFiles = 5_000
    /// Patches beyond this size are cut at a file boundary.
    static let maxPatchBytes = 8 * 1024 * 1024

    // MARK: Repository

    @concurrent static func repositoryRoot(_ cwd: URL) async -> URL? {
        guard FileManager.default.fileExists(atPath: cwd.path) else { return nil }
        let result = await GitCLI.git(["rev-parse", "--show-toplevel"], in: cwd, timeout: 10)
        let path = result.stdout.trimmingCharacters(in: .newlines)
        return result.succeeded && !path.isEmpty ? URL(fileURLWithPath: normalize(path), isDirectory: true) : nil
    }

    /// Git reports physical paths (`/private/var/…`); this spells them the way Foundation and
    /// the store do (`/var/…`), so they compare equal.
    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func refExists(_ ref: String, in cwd: URL) async -> Bool {
        await GitCLI.git(["show-ref", "--verify", "--quiet", ref], in: cwd, timeout: 10).succeeded
    }

    static func configValue(_ key: String, in cwd: URL) async -> String? {
        let result = await GitCLI.git(["config", "--get", key], in: cwd, timeout: 10)
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !value.isEmpty ? value : nil
    }

    static func remoteNames(_ cwd: URL) async -> [String] {
        let result = await GitCLI.git(["remote"], in: cwd, timeout: 10)
        return result.succeeded ? GitParse.lines(result.stdout) : []
    }

    /// `origin` when it exists, otherwise the first remote.
    static func primaryRemote(_ remotes: [String]) -> String? {
        remotes.contains("origin") ? "origin" : remotes.first
    }

    /// The branch `origin/HEAD` points at, such as `main`.
    static func defaultBranch(_ cwd: URL, remote: String = "origin") async -> String? {
        let result = await GitCLI.git(["symbolic-ref", "refs/remotes/\(remote)/HEAD"], in: cwd, timeout: 10)
        let prefix = "refs/remotes/\(remote)/"
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, value.hasPrefix(prefix) else { return nil }
        let name = String(value.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }

    static func headCommit(_ cwd: URL) async -> String? {
        let result = await GitCLI.git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: cwd, timeout: 10)
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !value.isEmpty ? value : nil
    }

    static func currentBranch(_ cwd: URL) async -> String? {
        let result = await GitCLI.git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: cwd, timeout: 10)
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !value.isEmpty ? value : nil
    }

    static func emptyTree(_ cwd: URL) async -> String {
        let result = await GitCLI.git(["hash-object", "-t", "tree", "/dev/null"], in: cwd, timeout: 10)
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !value.isEmpty ? value : GitCLI.emptyTree
    }

    // MARK: Status

    @concurrent static func status(_ cwd: URL) async throws -> GitStatus {
        guard FileManager.default.fileExists(atPath: cwd.path) else { return .notRepository }
        let result = await GitCLI.git(
            ["status", "--porcelain=2", "--branch", "-z"], in: cwd, environment: ["GIT_OPTIONAL_LOCKS": "0"])
        guard result.succeeded else {
            if GitCLI.isNotRepository(result.stderr) { return .notRepository }
            throw GitError.failed(String(localized: "Could not read the Git status."), result)
        }
        let parsed = GitParse.porcelainV2(result.stdout)
        async let numstat = trackedNumstat(cwd, hasHead: parsed.oid != nil)
        async let root = repositoryRoot(cwd)
        async let remotes = remoteNames(cwd)
        async let defaultBranch = defaultBranch(cwd)

        let stats = Dictionary(await numstat.map { ($0.path, $0) }, uniquingKeysWith: { first, second in
            GitParse.Numstat(
                path: first.path, oldPath: first.oldPath ?? second.oldPath, additions: first.additions + second.additions,
                deletions: first.deletions + second.deletions, isBinary: first.isBinary || second.isBinary)
        })
        let files = parsed.entries.map { entry in
            ChangedFile(
                path: entry.path, oldPath: entry.originalPath, status: entry.status,
                additions: stats[entry.path]?.additions ?? 0, deletions: stats[entry.path]?.deletions ?? 0)
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        let remoteList = await remotes
        let defaultName = await defaultBranch
        var status = GitStatus(
            isRepository: true, rootPath: await root?.path, branch: parsed.head, headOID: parsed.oid,
            upstream: parsed.upstream, ahead: parsed.ahead, behind: parsed.behind, defaultBranch: defaultName,
            hasRemote: !remoteList.isEmpty, files: files,
            conflictedPaths: parsed.entries.filter(\.isConflicted).map(\.path))
        if let branch = parsed.head {
            status.isDefaultBranch =
                branch == defaultName || (defaultName == nil && (branch == "main" || branch == "master"))
            if parsed.upstream == nil, parsed.oid != nil {
                // Without an upstream, "ahead" means commits the base branch does not have.
                status.ahead = await aheadOfBase(cwd, branch: branch, defaultBranch: defaultName, remotes: remoteList)
                status.behind = 0
                status.aheadOfDefault = status.isDefaultBranch ? 0 : status.ahead
            } else if !status.isDefaultBranch, parsed.oid != nil {
                status.aheadOfDefault = await aheadOfBase(
                    cwd, branch: branch, defaultBranch: defaultName, remotes: remoteList)
            }
        }
        return status
    }

    /// Line counts for tracked changes, staged or not, without touching the index.
    private static func trackedNumstat(_ cwd: URL, hasHead: Bool) async -> [GitParse.Numstat] {
        if hasHead {
            let result = await GitCLI.git(
                ["diff-index", "-M", "--numstat", "-z", "HEAD", "--"], in: cwd, environment: ["GIT_OPTIONAL_LOCKS": "0"])
            return result.succeeded ? GitParse.numstat(result.stdout) : []
        }
        async let staged = GitCLI.git(["diff", "--cached", "--numstat", "-z"], in: cwd)
        async let unstaged = GitCLI.git(["diff-files", "--numstat", "-z"], in: cwd)
        return GitParse.numstat(await staged.stdout) + GitParse.numstat(await unstaged.stdout)
    }

    struct BaseRef: Sendable, Hashable {
        /// Short name for display and for `gh`, such as `origin/main` or `main`.
        var name: String
        /// Full ref to compare against, such as `refs/remotes/origin/main`.
        var comparisonRef: String
    }

    /// Base branch for a branch without (or ignoring) its upstream: the base recorded when the
    /// worktree was created, then the remote's default branch, then `main` / `master`.
    static func baseRef(
        _ cwd: URL, branch: String, defaultBranch: String?, remotes: [String], allowRemoteOfCurrent: Bool = false
    ) async -> BaseRef? {
        let primary = primaryRemote(remotes)
        let configured = await configValue(BranchNames.mergeBaseConfigKey(branch), in: cwd)
        var candidates: [String] = []
        if let configured { candidates.append(configured) }
        if let defaultBranch { candidates.append(defaultBranch) }
        candidates += ["main", "master"]

        for candidate in candidates {
            var name = candidate
            if name.hasPrefix("refs/heads/") { name = String(name.dropFirst("refs/heads/".count)) }
            if name.hasPrefix("refs/remotes/") { name = String(name.dropFirst("refs/remotes/".count)) }
            if let remote = remotes.first(where: { name.hasPrefix($0 + "/") }) {
                if await refExists("refs/remotes/\(name)", in: cwd) {
                    if name == "\(remote)/\(branch)", !allowRemoteOfCurrent { continue }
                    return BaseRef(name: name, comparisonRef: "refs/remotes/\(name)")
                }
                name = String(name.dropFirst(remote.count + 1))
            }
            guard !name.isEmpty else { continue }
            if name == branch {
                guard allowRemoteOfCurrent, let primary,
                    await refExists("refs/remotes/\(primary)/\(name)", in: cwd)
                else { continue }
                return BaseRef(name: "\(primary)/\(name)", comparisonRef: "refs/remotes/\(primary)/\(name)")
            }
            if let primary, await refExists("refs/remotes/\(primary)/\(name)", in: cwd) {
                return BaseRef(name: "\(primary)/\(name)", comparisonRef: "refs/remotes/\(primary)/\(name)")
            }
            if await refExists("refs/heads/\(name)", in: cwd) {
                return BaseRef(name: name, comparisonRef: "refs/heads/\(name)")
            }
        }
        return nil
    }

    private static func aheadOfBase(_ cwd: URL, branch: String, defaultBranch: String?, remotes: [String]) async -> Int {
        guard let base = await baseRef(cwd, branch: branch, defaultBranch: defaultBranch, remotes: remotes) else {
            return 0
        }
        let result = await GitCLI.git(
            ["rev-list", "--count", "--end-of-options", "\(base.comparisonRef)..HEAD"], in: cwd, timeout: 15)
        return result.succeeded ? max(0, Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) : 0
    }

    // MARK: Branches

    @concurrent static func branches(_ cwd: URL) async throws -> GitBranchList {
        guard let root = await repositoryRoot(cwd) else { return GitBranchList(isRepository: false) }
        async let refsResult = GitCLI.git(
            [
                "for-each-ref", "--format=%(refname)%09%(committerdate:unix)%09%(symref)%09%(upstream:short)",
                "refs/heads", "refs/remotes",
            ], in: root, timeout: 30)
        async let current = currentBranch(root)
        async let defaultName = defaultBranch(root)
        async let worktreeList = GitCLI.git(["worktree", "list", "--porcelain", "-z"], in: root, timeout: 30)
        async let remotes = remoteNames(root)

        let refs = await refsResult
        guard refs.succeeded else { throw GitError.failed(String(localized: "Could not list branches."), refs) }
        let remoteList = await remotes
        let defaultBranch = await defaultName
        let currentName = await current
        var worktreeByBranch: [String: String] = [:]
        for worktree in GitParse.worktrees(await worktreeList.stdout) where !worktree.isPrunable {
            if let branch = worktree.branch, FileManager.default.fileExists(atPath: worktree.path) {
                worktreeByBranch[branch] = normalize(worktree.path)
            }
        }
        let rootPath = root.path

        var local: [GitBranch] = []
        var remote: [GitBranch] = []
        for line in refs.stdout.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, fields[2].isEmpty else { continue }
            let date = Double(fields[1]).map { Date(timeIntervalSince1970: $0) }
            let upstream = fields.count > 3 && !fields[3].isEmpty ? fields[3] : nil
            if fields[0].hasPrefix("refs/heads/") {
                let name = String(fields[0].dropFirst("refs/heads/".count))
                let worktree = worktreeByBranch[name]
                let isCurrent =
                    worktree.map { URL(fileURLWithPath: $0).standardizedFileURL.path == rootPath } ?? (name == currentName)
                local.append(
                    GitBranch(
                        name: name, isCurrent: isCurrent, isDefault: name == defaultBranch, upstream: upstream,
                        worktreePath: worktree, lastCommitDate: date))
            } else if fields[0].hasPrefix("refs/remotes/") {
                let name = String(fields[0].dropFirst("refs/remotes/".count))
                let remoteName = remoteList.filter { name.hasPrefix($0 + "/") }.max { $0.count < $1.count }
                let isDefault = remoteName == "origin" && name == "origin/\(defaultBranch ?? "")"
                remote.append(
                    GitBranch(
                        name: name, isRemote: true, remoteName: remoteName, isDefault: isDefault, lastCommitDate: date))
            }
        }
        let byRecency: (GitBranch, GitBranch) -> Bool = { lhs, rhs in
            let left = lhs.lastCommitDate ?? .distantPast
            let right = rhs.lastCommitDate ?? .distantPast
            return left != right ? left > right : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        // Hide origin branches that already have a local branch of the same name.
        let localNames = Set(local.map(\.name))
        remote = remote.filter { $0.remoteName != "origin" || !localNames.contains($0.localName) }
        let ordered = (local.sorted(by: byRecency) + remote.sorted(by: byRecency)).enumerated().sorted { lhs, rhs in
            func rank(_ branch: GitBranch) -> Int { branch.isCurrent ? 0 : branch.isDefault && !branch.isRemote ? 1 : 2 }
            let left = rank(lhs.element)
            let right = rank(rhs.element)
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
        return GitBranchList(
            isRepository: true, branches: ordered, currentBranch: currentName, defaultBranch: defaultBranch,
            hasRemote: !remoteList.isEmpty)
    }

    /// Checks out a local branch, or a remote branch through a local tracking branch.
    @concurrent static func checkout(_ name: String, in cwd: URL) async throws -> String? {
        guard !name.hasPrefix("-") else { throw GitError(String(localized: "“\(name)” is not a valid branch name.")) }
        async let localExists = refExists("refs/heads/\(name)", in: cwd)
        async let remoteExists = refExists("refs/remotes/\(name)", in: cwd)
        var arguments = ["checkout", name]
        if !(await localExists), await remoteExists {
            let tracking = await GitCLI.git(
                ["for-each-ref", "--format=%(refname:short)%09%(upstream:short)", "refs/heads"], in: cwd)
            var trackingBranch: String?
            for line in tracking.stdout.split(separator: "\n") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                if fields.count == 2, fields[1] == name {
                    trackingBranch = String(fields[0])
                    break
                }
            }
            if let trackingBranch {
                arguments = ["checkout", trackingBranch]
            } else if !(await refExists("refs/heads/\(BranchNames.localName(fromRemoteRef: name))", in: cwd)) {
                arguments = ["checkout", "--track", name]
            }
        }
        // The trailing `--` keeps a stale ref name from turning into a path checkout.
        try await GitCLI.checked(
            String(localized: "Could not switch to “\(name)”."), arguments + ["--"], in: cwd, timeout: 60)
        return await currentBranch(cwd)
    }

    @concurrent static func createBranch(_ rawName: String, in cwd: URL, checkout: Bool) async throws -> String {
        let name = BranchNames.sanitizeNewRefName(rawName)
        try await validateBranchName(name, in: cwd)
        try await GitCLI.checked(String(localized: "Could not create “\(name)”."), ["branch", "--", name], in: cwd)
        if checkout { _ = try await self.checkout(name, in: cwd) }
        return name
    }

    static func validateBranchName(_ name: String, in cwd: URL) async throws {
        let result = await GitCLI.git(["check-ref-format", "--branch", name], in: cwd, timeout: 10)
        guard !name.isEmpty, !name.hasPrefix("-"), result.succeeded else {
            throw GitError(String(localized: "“\(name)” is not a valid branch name."))
        }
    }

    /// Renames a branch, adding `-1`, `-2`… when the name is taken unless `exactName` is set.
    @concurrent static func renameBranch(_ old: String, to new: String, in cwd: URL, exactName: Bool) async throws
        -> String
    {
        guard old != new else { return new }
        try await validateBranchName(new, in: cwd)
        var target = new
        if !exactName, await refExists("refs/heads/\(new)", in: cwd) {
            for suffix in 1...100 {
                target = "\(new)-\(suffix)"
                if !(await refExists("refs/heads/\(target)", in: cwd)) { break }
            }
        }
        try await GitCLI.checked(
            String(localized: "Could not rename “\(old)”."), ["branch", "-m", "--", old, target], in: cwd)
        return target
    }

    // MARK: Worktrees

    @concurrent static func worktrees(_ cwd: URL) async throws -> [GitWorktree] {
        let result = await GitCLI.git(["worktree", "list", "--porcelain", "-z"], in: cwd, timeout: 30)
        guard result.succeeded else { throw GitError.failed(String(localized: "Could not list worktrees."), result) }
        return GitParse.worktrees(result.stdout).map { worktree in
            var worktree = worktree
            worktree.path = normalize(worktree.path)
            return worktree
        }
    }

    @concurrent static func createWorktree(
        in repository: URL, branch: String, baseRef: String?, path: URL, recordBase: String?
    ) async throws -> GitWorktree {
        guard !branch.hasPrefix("-"), !(baseRef?.hasPrefix("-") ?? false) else {
            throw GitError(String(localized: "“\(branch)” is not a valid branch name."))
        }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let workers = await configValue("checkout.workers", in: repository) ?? "0"
        // The base is recorded separately; an upstream is set only when the branch is pushed.
        var arguments = [
            "-c", "checkout.workers=\(workers)", "worktree", "add", "--no-track", "-b", branch, "--", path.path,
        ]
        if let baseRef { arguments.append(baseRef) }
        try await GitCLI.checked(
            String(localized: "Could not create the worktree."), arguments, in: repository, timeout: 300)
        // `worktree add` leaves submodules empty, which can hide project tools or sources.
        if FileManager.default.fileExists(atPath: path.appendingPathComponent(".gitmodules").path) {
            _ = await GitCLI.git(["submodule", "update", "--init", "--recursive"], in: path, timeout: 600)
        }
        if let recordBase, !recordBase.isEmpty {
            _ = await GitCLI.git(["config", BranchNames.mergeBaseConfigKey(branch), recordBase], in: repository)
        }
        return GitWorktree(path: path.path, branch: branch, head: await headCommit(path))
    }

    @concurrent static func removeWorktree(_ path: URL, in repository: URL, force: Bool) async throws {
        // `worktree remove` honors status.showUntrackedFiles=no and would delete untracked files.
        var arguments = ["-c", "status.showUntrackedFiles=normal", "worktree", "remove"]
        if force { arguments.append("--force") }
        arguments += ["--", path.path]
        let result = await GitCLI.git(arguments, in: repository, timeout: 300)
        if result.succeeded { return }
        let missing = result.stderr.lowercased().contains("is not a working tree")
        if missing, !FileManager.default.fileExists(atPath: path.path) {
            _ = await GitCLI.git(["worktree", "prune"], in: repository, timeout: 30)
            return
        }
        throw GitError.failed(String(localized: "Could not remove the worktree."), result)
    }

    /// Commits on `branch` that no other branch has.
    static func uniqueCommitCount(_ branch: String, in cwd: URL) async -> Int? {
        let result = await GitCLI.git(
            ["rev-list", "--count", "refs/heads/\(branch)", "--not", "--exclude=\(branch)", "--branches"], in: cwd)
        return result.succeeded ? Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    // MARK: Diffs

    enum DiffBase: Sendable, Hashable {
        /// Uncommitted changes, including untracked files.
        case head
        /// Everything since the branch left its base, committed or not.
        case branch
    }

    @concurrent static func diff(_ cwd: URL, base: DiffBase, ignoreWhitespace: Bool) async throws -> GitDiff {
        guard let root = await repositoryRoot(cwd) else {
            throw GitError(String(localized: "This folder is not a Git repository."))
        }
        var reference = "HEAD"
        var baseLabel: String? = "HEAD"
        if base == .branch, let branch = await currentBranch(root), await headCommit(root) != nil {
            async let remotes = remoteNames(root)
            async let defaultName = defaultBranch(root)
            if let baseRef = await baseRef(
                root, branch: branch, defaultBranch: await defaultName, remotes: await remotes,
                allowRemoteOfCurrent: true)
            {
                let mergeBase = await GitCLI.git(
                    ["merge-base", "--end-of-options", baseRef.comparisonRef, "HEAD"], in: root)
                let commit = mergeBase.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if mergeBase.succeeded, !commit.isEmpty {
                    reference = commit
                    baseLabel = baseRef.name
                }
            }
        }

        let untrackedResult = await GitCLI.git(["ls-files", "--others", "--exclude-standard", "-z"], in: root)
        let untracked = untrackedResult.succeeded ? GitParse.nulFields(untrackedResult.stdout) : []
        var reviewIndex: URL?
        var environment: [String: String] = [:]
        if !untracked.isEmpty, untracked.count <= maxUntrackedFiles {
            reviewIndex = try await prepareReviewIndex(root: root, untracked: untracked)
            if let reviewIndex { environment["GIT_INDEX_FILE"] = reviewIndex.path }
        }
        defer {
            if let reviewIndex { try? FileManager.default.removeItem(at: reviewIndex) }
        }

        let arguments = diffArguments(ignoreWhitespace: ignoreWhitespace, minimal: true)
        var numstat = await GitCLI.git(arguments + ["--numstat", "-z", reference, "--"], in: root, environment: environment)
        if !numstat.succeeded, reference == "HEAD", GitCLI.isUnbornHead(numstat.stderr) {
            reference = await emptyTree(root)
            numstat = await GitCLI.git(arguments + ["--numstat", "-z", reference, "--"], in: root, environment: environment)
        }
        guard numstat.succeeded else { throw GitError.failed(String(localized: "Could not read the changes."), numstat) }
        let stats = GitParse.numstat(numstat.stdout)
        guard !stats.isEmpty else { return GitDiff(baseLabel: baseLabel) }
        let patch = await GitCLI.git(
            arguments + ["--patch", reference, "--"], in: root, environment: environment, timeout: 120)
        guard patch.succeeded else { throw GitError.failed(String(localized: "Could not read the changes."), patch) }
        var diff = assemble(patch: patch.stdout, stats: stats, untracked: Set(untracked))
        diff.baseLabel = baseLabel
        diff.isTruncated = diff.isTruncated || untracked.count > maxUntrackedFiles
        return diff
    }

    static func diffArguments(ignoreWhitespace: Bool, minimal: Bool) -> [String] {
        var arguments = [
            "-c", "core.quotePath=false", "diff", "--find-renames", "--no-color", "--no-ext-diff", "--no-textconv",
            "--src-prefix=a/", "--dst-prefix=b/",
        ]
        if minimal { arguments.append("--minimal") }
        if ignoreWhitespace { arguments.append("--ignore-all-space") }
        return arguments
    }

    /// Joins a patch with its numstat: counts come from numstat, hunks from the patch.
    static func assemble(patch: String, stats: [GitParse.Numstat], untracked: Set<String> = []) -> GitDiff {
        var text = patch
        var truncated = false
        if text.utf8.count > maxPatchBytes {
            let limit = text.utf8.index(text.utf8.startIndex, offsetBy: maxPatchBytes)
            let head = text[..<limit]
            let cut = head.range(of: "\ndiff --git ", options: .backwards)?.lowerBound ?? limit
            text = String(text[..<cut])
            truncated = true
        }
        var byPath: [String: FileDiff] = [:]
        for file in DiffParser.parse(text) { byPath[file.path] = file }
        var files: [FileDiff] = []
        for stat in stats {
            var file = byPath.removeValue(forKey: stat.path) ?? FileDiff(path: stat.path, status: .modified)
            if file.oldPath == nil { file.oldPath = stat.oldPath }
            if file.oldPath != nil, file.status == .modified { file.status = .renamed }
            file.additions = stat.additions
            file.deletions = stat.deletions
            file.isBinary = file.isBinary || stat.isBinary
            if untracked.contains(stat.path) { file.status = .untracked }
            files.append(file)
        }
        files += byPath.values
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return GitDiff(files: files, isTruncated: truncated)
    }

    /// A throwaway index with untracked files added as intent-to-add, so `git diff` shows them
    /// without changing the user's index.
    private static func prepareReviewIndex(root: URL, untracked: [String]) async throws -> URL? {
        async let deletionsResult = GitCLI.git(
            ["diff", "--cached", "--name-only", "--diff-filter=D", "-z", "HEAD", "--"], in: root)
        async let indexResult = GitCLI.git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: root)
        let stagedDeletions = Set(GitParse.nulFields(await deletionsResult.stdout))
        let paths = untracked.filter { !stagedDeletions.contains($0) }
        guard !paths.isEmpty else { return nil }

        let indexPath = await indexResult.stdout.trimmingCharacters(in: .newlines)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("coincide-review-index-\(UUID().uuidString)")
        let environment = ["GIT_INDEX_FILE": temporary.path]
        let config = ["-c", "core.splitIndex=false", "-c", "splitIndex.sharedIndexExpire=never"]
        if !indexPath.isEmpty, FileManager.default.fileExists(atPath: indexPath) {
            try copyIndex(from: URL(fileURLWithPath: indexPath), to: temporary)
        } else {
            try await GitCLI.checked(
                String(localized: "Could not prepare the diff."), ["read-tree", "--empty"], in: root,
                environment: environment)
        }
        do {
            try await GitCLI.checked(
                String(localized: "Could not prepare the diff."), config + ["update-index", "--no-split-index"],
                in: root, environment: environment)
            try await GitCLI.checked(
                String(localized: "Could not prepare the diff."),
                config + [
                    "-c", "core.preloadIndex=false", "--literal-pathspecs", "add", "--intent-to-add",
                    "--pathspec-from-file=-", "--pathspec-file-nul",
                ], in: root, environment: environment, input: paths.joined(separator: "\0") + "\0", timeout: 60)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return temporary
    }

    /// Copies an index keeping its timestamp (floored to whole seconds) so git's racy-clean
    /// check still works on the copy.
    static func copyIndex(from source: URL, to destination: URL, backdate: Bool = false) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        try FileManager.default.copyItem(at: source, to: destination)
        if let modified = attributes[.modificationDate] as? Date {
            let seconds = floor((modified.timeIntervalSince1970 - (backdate ? 0.001 : 0)))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: max(0, seconds))], ofItemAtPath: destination.path)
        }
    }

    // MARK: Commit

    @concurrent static func stage(_ paths: [String]?, in cwd: URL) async throws {
        if let paths, !paths.isEmpty {
            _ = await GitCLI.git(["reset", "--quiet"], in: cwd)
            // Status paths are repository-relative, while cwd can be a subdirectory.
            try await GitCLI.checked(
                String(localized: "Could not stage the selected files."),
                ["add", "-A", "--"] + paths.map { ":(top,literal)\($0)" }, in: cwd, timeout: 120)
        } else {
            try await GitCLI.checked(String(localized: "Could not stage changes."), ["add", "-A"], in: cwd, timeout: 120)
        }
    }

    @concurrent static func commit(subject: String, body: String, paths: [String]?, in cwd: URL) async throws
        -> GitCommit
    {
        try await stage(paths, in: cwd)
        var arguments = ["commit", "-m", subject]
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty { arguments += ["-m", trimmedBody] }
        // Commit hooks can take a while.
        try await GitCLI.checked(String(localized: "Could not commit."), arguments, in: cwd, timeout: 600)
        let sha = await headCommit(cwd) ?? ""
        return GitCommit(sha: sha, subject: subject)
    }

    struct CommitContext: Sendable {
        var summary: String
        var patch: String
    }

    /// What a commit of `paths` (or everything) would contain, read through a throwaway index.
    @concurrent static func commitContext(paths: [String]?, in cwd: URL, includePatch: Bool) async throws
        -> CommitContext?
    {
        let indexResult = await GitCLI.git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: cwd)
        let indexPath = indexResult.stdout.trimmingCharacters(in: .newlines)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("coincide-commit-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let environment = ["GIT_INDEX_FILE": temporary.path]
        let config = ["-c", "core.splitIndex=false", "-c", "splitIndex.sharedIndexExpire=never"]
        let failure = String(localized: "Could not prepare the commit.")
        if !indexPath.isEmpty, FileManager.default.fileExists(atPath: indexPath) {
            try copyIndex(from: URL(fileURLWithPath: indexPath), to: temporary)
            try await GitCLI.checked(
                failure, config + ["update-index", "--no-split-index"], in: cwd, environment: environment)
        } else {
            try await GitCLI.checked(failure, ["read-tree", "--empty"], in: cwd, environment: environment)
        }
        if let paths, !paths.isEmpty {
            let head = await headCommit(cwd)
            try await GitCLI.checked(
                failure, config + ["read-tree"] + (head == nil ? ["--empty"] : ["HEAD"]), in: cwd,
                environment: environment)
            try await GitCLI.checked(
                failure, config + ["add", "-A", "--"] + paths.map { ":(top,literal)\($0)" }, in: cwd,
                environment: environment, timeout: 120)
        } else {
            try await GitCLI.checked(failure, config + ["add", "-A"], in: cwd, environment: environment, timeout: 120)
        }
        let summary = try await GitCLI.checked(
            failure, ["diff", "--cached", "--name-status"], in: cwd, environment: environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        guard includePatch else { return CommitContext(summary: summary, patch: "") }
        let patch = await GitCLI.git(
            ["diff", "--no-ext-diff", "--cached", "--patch", "--minimal"], in: cwd, environment: environment,
            timeout: 60)
        return CommitContext(summary: summary, patch: TextLimits.limit(patch.stdout, 49_000))
    }

    // MARK: Push and pull

    /// Pushes the current branch, publishing it with an upstream when it has none.
    @concurrent static func push(_ cwd: URL, fallbackBranch: String? = nil) async throws -> GitPushResult {
        let status = try await status(cwd)
        guard let branch = status.branch ?? fallbackBranch else {
            throw GitError(String(localized: "Cannot push from a detached HEAD."))
        }
        let remotes = await remoteNames(cwd)
        if status.ahead == 0, status.behind == 0, let upstream = status.upstream {
            return GitPushResult(outcome: .upToDate, branch: branch, upstream: upstream)
        }
        guard let upstream = status.upstream else {
            guard let remote = await pushRemote(cwd, branch: branch, remotes: remotes) else {
                throw GitError(String(localized: "Cannot push because this repository has no remote."))
            }
            try await GitCLI.checked(
                String(localized: "Could not push “\(branch)”."),
                ["push", "-u", "--", remote, "HEAD:refs/heads/\(branch)"], in: cwd, timeout: 600)
            return GitPushResult(outcome: .pushed, branch: branch, upstream: "\(remote)/\(branch)", setUpstream: true)
        }
        let remoteName = remotes.filter { upstream.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            ?? String(upstream.prefix { $0 != "/" })
        let upstreamBranch = String(upstream.dropFirst(remoteName.count + 1))
        if upstreamBranch != branch {
            // A differently named upstream is the branch's base (a worktree started from origin/main),
            // not where its work belongs. Publish the branch under its own name and keep the base.
            let remote = await pushRemote(cwd, branch: branch, remotes: remotes) ?? remoteName
            if await configValue(BranchNames.mergeBaseConfigKey(branch), in: cwd) == nil {
                _ = await GitCLI.git(["config", BranchNames.mergeBaseConfigKey(branch), upstream], in: cwd)
            }
            try await GitCLI.checked(
                String(localized: "Could not push “\(branch)”."),
                ["push", "-u", "--", remote, "HEAD:refs/heads/\(branch)"], in: cwd, timeout: 600)
            return GitPushResult(outcome: .pushed, branch: branch, upstream: "\(remote)/\(branch)", setUpstream: true)
        }
        try await GitCLI.checked(
            String(localized: "Could not push “\(branch)”."),
            ["push", "--", remoteName, "HEAD:refs/heads/\(upstreamBranch)"], in: cwd, timeout: 600)
        return GitPushResult(outcome: .pushed, branch: branch, upstream: upstream)
    }

    /// `branch.<name>.pushRemote`, then `remote.pushDefault`, then the primary remote.
    static func pushRemote(_ cwd: URL, branch: String, remotes: [String]) async -> String? {
        if let configured = await configValue("branch.\(branch).pushRemote", in: cwd) { return configured }
        if let configured = await configValue("remote.pushDefault", in: cwd) { return configured }
        return primaryRemote(remotes)
    }

    @concurrent static func pull(_ cwd: URL) async throws -> GitPullResult {
        let status = try await status(cwd)
        guard status.branch != nil else { throw GitError(String(localized: "Cannot pull into a detached HEAD.")) }
        guard status.hasUpstream else {
            throw GitError(String(localized: "This branch has no upstream yet. Push it first."))
        }
        let before = await headCommit(cwd)
        try await GitCLI.checked(String(localized: "Could not pull."), ["pull", "--ff-only"], in: cwd, timeout: 300)
        let after = await headCommit(cwd)
        return before != nil && before == after ? .upToDate : .pulled
    }

    struct RangeContext: Sendable {
        var commits: String
        var stat: String
        var patch: String
    }

    /// Commits and changes between `baseRef` and HEAD, for writing a pull request.
    static func rangeContext(_ cwd: URL, baseRef: String) async -> RangeContext {
        async let log = GitCLI.git(["log", "--oneline", "--no-decorate", "--end-of-options", "\(baseRef)..HEAD"], in: cwd)
        async let stat = GitCLI.git(["diff", "--stat", "--end-of-options", "\(baseRef)...HEAD"], in: cwd)
        async let patch = GitCLI.git(
            ["diff", "--no-ext-diff", "--patch", "--minimal", "--end-of-options", "\(baseRef)...HEAD"], in: cwd,
            timeout: 60)
        return RangeContext(
            commits: TextLimits.limit(await log.stdout, 19_000), stat: TextLimits.limit(await stat.stdout, 19_000),
            patch: TextLimits.limit(await patch.stdout, 59_000))
    }
}

enum TextLimits {
    /// Cuts `value` to `maxCharacters`, marking the cut.
    static func limit(_ value: String, _ maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters)) + "\n\n[truncated]"
    }
}

extension BranchNames {
    /// Git config key recording the branch a worktree branch was started from.
    public nonisolated static func mergeBaseConfigKey(_ branch: String) -> String {
        "branch.\(branch).coincide-merge-base"
    }
}
