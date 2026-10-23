import Darwin
import Foundation

/// Everything a branch review shows: committed branch work plus uncommitted and untracked edits,
/// measured from the merge base with an explicitly selected local or remote-tracking base.
public struct GitBranchDiff: Sendable, Equatable {
    public let baseRef: String
    public let baseCommit: String
    public let mergeBase: String
    public let headCommit: String
    public let patch: String
    public let truncated: Bool
    public let omittedUntracked: [String]
}

public struct GitDefaultBranch: Sendable, Equatable {
    /// Local branch name, such as `main`.
    public let name: String
    /// The remote-tracking ref Git records as the remote's HEAD, when known.
    public let remoteRef: String?
    public init(name: String, remoteRef: String?) { self.name = name; self.remoteRef = remoteRef }
    /// `origin/main` style label for remote bases.
    public var remoteName: String? { remoteRef.map { String($0.dropFirst("refs/remotes/".count)) } }
}

public struct GitBranchCatalogEntry: Sendable, Equatable, Identifiable {
    public let ref: String
    public let upstream: String?
    /// The registered checkout path when this local branch is checked out in a worktree.
    public let worktreePath: String?
    public let committedAt: Date?
    public let isHead: Bool
    public let remote: String?
    public var id: String { ref }
    public var isRemote: Bool { ref.hasPrefix("refs/remotes/") }
    public var name: String { String(ref.dropFirst(isRemote ? "refs/remotes/".count : "refs/heads/".count)) }
    /// For a remote-tracking branch, the branch name without its remote, e.g. `feature/x`.
    public var localName: String { if let remote, isRemote { return String(name.dropFirst(remote.count + 1)) }; return name }
    public init(ref: String, upstream: String? = nil, worktreePath: String? = nil, committedAt: Date? = nil, isHead: Bool = false, remote: String? = nil) {
        self.ref = ref; self.upstream = upstream; self.worktreePath = worktreePath; self.committedAt = committedAt; self.isHead = isHead; self.remote = remote
    }
}

public struct GitBranchCatalog: Sendable, Equatable {
    public let repositoryRoot: String
    public let entries: [GitBranchCatalogEntry]
    public let defaultBranch: GitDefaultBranch?
    public var current: GitBranchCatalogEntry? { entries.first(where: \.isHead) }
    public var locals: [GitBranchCatalogEntry] { entries.filter { !$0.isRemote } }
    public var remotes: [GitBranchCatalogEntry] { entries.filter(\.isRemote) }
    /// A local branch checked out by a different registered checkout cannot be switched to here.
    public func otherWorktree(for entry: GitBranchCatalogEntry) -> String? {
        guard let path = entry.worktreePath, !entry.isHead else { return nil }
        return Self.canonical(path) == Self.canonical(repositoryRoot) ? nil : path
    }
    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    public init(repositoryRoot: String, entries: [GitBranchCatalogEntry], defaultBranch: GitDefaultBranch?) {
        self.repositoryRoot = repositoryRoot; self.entries = entries; self.defaultBranch = defaultBranch
    }
}

/// Pure ranking for the searchable branch picker.
public enum GitBranchSearch {
    public static func rank(_ entries: [GitBranchCatalogEntry], query: String, defaultBranch: String? = nil) -> [GitBranchCatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func recency(_ a: GitBranchCatalogEntry, _ b: GitBranchCatalogEntry) -> Bool {
            if a.isRemote != b.isRemote { return !a.isRemote }
            let left = a.committedAt ?? .distantPast, right = b.committedAt ?? .distantPast
            return left != right ? left > right : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        if needle.isEmpty {
            func pin(_ entry: GitBranchCatalogEntry) -> Int { entry.isHead ? 0 : (!entry.isRemote && entry.name == defaultBranch) ? 1 : 2 }
            return entries.sorted { pin($0) != pin($1) ? pin($0) < pin($1) : recency($0, $1) }
        }
        func score(_ entry: GitBranchCatalogEntry) -> Int? {
            let names = [entry.name.lowercased(), entry.localName.lowercased()]
            if names.contains(needle) { return 0 }
            if names.contains(where: { $0.hasPrefix(needle) }) { return 1 }
            if names.contains(where: { $0.split(separator: "/").dropFirst().contains { $0.hasPrefix(needle) } }) { return 2 }
            if names.contains(where: { $0.contains(needle) }) { return 3 }
            return nil
        }
        return entries.compactMap { entry in score(entry).map { (entry, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : recency($0.0, $1.0) }.map(\.0)
    }
}

extension GitService {
    /// Compares the merge base of HEAD and `baseRef` with the working tree, then appends
    /// untracked files. Output is bounded; the base is validated and never fetched implicitly.
    public func branchDiff(baseRef: String, ignoreWhitespace: Bool = false, maxBytes: Int = 2_097_152) async throws -> GitBranchDiff {
        guard (1_024...16_777_216).contains(maxBytes) else { throw CoincideError("Choose a smaller comparison size.") }
        try Self.validateRevision(baseRef)
        let repository = try await repositoryRoot()
        guard let base = try await commit(for: baseRef, at: repository) else { throw CoincideError("Choose an existing local or remote branch to compare against.") }
        guard let head = try await commit(for: "HEAD", at: repository) else { throw CoincideError("Commit on this branch before comparing it with a base branch.") }
        let mergeResult = try await run(["merge-base", base, head], at: repository)
        guard mergeResult.status == 0, let mergeBase = String(data: mergeResult.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isObjectID(mergeBase) else { throw CoincideError("This branch shares no history with \(baseRef).") }
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--find-renames"]
        if ignoreWhitespace { args.append("--ignore-all-space") }
        let tracked = try await bounded(args + [mergeBase, "--"], at: repository, maxBytes: maxBytes)
        var patch = tracked.output, truncated = tracked.truncated, omitted: [String] = []
        let untracked = try await status().changes.filter(\.isUntracked).map(\.path)
        for path in untracked {
            guard !truncated else { omitted.append(path); continue }
            var info = stat()
            let file = repository.appendingPathComponent(path)
            guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG || (info.st_mode & S_IFMT) == S_IFLNK, (try? Self.validatePaths([path])) != nil else { omitted.append(path); continue }
            var extra = ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/"]
            if ignoreWhitespace { extra.append("--ignore-all-space") }
            if !patch.isEmpty, !patch.hasSuffix("\n") { patch += "\n" }
            let remaining = maxBytes - patch.utf8.count
            guard remaining > 0 else { truncated = true; omitted.append(path); continue }
            let result = try await bounded(extra + ["--", "/dev/null", path], at: repository, maxBytes: remaining, accepted: [0, 1])
            patch += result.output; truncated = truncated || result.truncated
        }
        return .init(baseRef: baseRef, baseCommit: base, mergeBase: mergeBase, headCommit: head, patch: Self.redactURLs(patch), truncated: truncated, omittedUntracked: omitted)
    }

    /// Fetches exactly one remote branch into its remote-tracking ref, e.g. for "Start from remote".
    /// Returns the fetched commit. Nothing else is fetched, pruned or checked out.
    @discardableResult
    public func fetch(remote: String, branch: String) async throws -> String {
        try await validateBranch(branch)
        return try await mutate { repository in
            try await validateRemote(remote)
            let target = "refs/remotes/\(remote)/\(branch)"
            _ = try await command(["fetch", "--no-recurse-submodules", "--no-prune", "--no-tags", "--", remote, "+refs/heads/\(branch):\(target)"], at: repository, timeout: networkTimeout)
            guard let commit = try await commit(for: target, at: repository) else { throw CoincideError("The remote branch was not fetched.") }
            return commit
        }
    }

    /// `rev-list --count base..head` for validated revisions; nil when either side is missing.
    public func commitCount(from base: String, to head: String = "HEAD") async throws -> Int? {
        try Self.validateRevision(base); try Self.validateRevision(head)
        let repository = try await repositoryRoot()
        guard let from = try await commit(for: base, at: repository), let to = try await commit(for: head, at: repository) else { return nil }
        let value = try await line(["rev-list", "--count", from + ".." + to], at: repository)
        return Int(value)
    }

    /// The remote's recorded HEAD (`refs/remotes/<remote>/HEAD`), falling back to common local names.
    public func defaultBranch(preferredRemote: String? = nil) async throws -> GitDefaultBranch? {
        let repository = try await repositoryRoot()
        let configured = try await remotes()
        var candidates = [preferredRemote, "origin"].compactMap { $0 }.filter(configured.contains)
        candidates += configured.filter { !candidates.contains($0) }
        for remote in candidates {
            let result = try await run(["symbolic-ref", "--quiet", "refs/remotes/\(remote)/HEAD"], at: repository)
            guard result.status == 0, let ref = String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  ref.hasPrefix("refs/remotes/\(remote)/") else { continue }
            let name = String(ref.dropFirst("refs/remotes/\(remote)/".count))
            guard !name.isEmpty, name != "HEAD" else { continue }
            return .init(name: name, remoteRef: ref)
        }
        for name in ["main", "master", "trunk", "develop"] {
            guard try await commit(for: "refs/heads/" + name, at: repository) != nil else { continue }
            let remote = candidates.first.map { "refs/remotes/\($0)/\(name)" }
            let tracked: String?
            if let remote { tracked = try await commit(for: remote, at: repository) != nil ? remote : nil } else { tracked = nil }
            return .init(name: name, remoteRef: tracked)
        }
        return nil
    }

    public func branchCatalog() async throws -> GitBranchCatalog {
        let repository = try await repositoryRoot()
        let remoteNames = try await remotes().sorted { $0.count > $1.count }
        let data = try await command(["for-each-ref", "--format=%(refname)%00%(upstream:short)%00%(symref)%00%(worktreepath)%00%(committerdate:unix)%00%(HEAD)%00",
                                      "refs/heads/", "refs/remotes/"], at: repository)
        var entries: [GitBranchCatalogEntry] = []
        for record in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = record.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 7 else { throw CoincideError("Malformed Git branch list.") }
            guard fields[2].isEmpty else { continue }
            let ref = String(fields[0])
            let remote = ref.hasPrefix("refs/remotes/") ? remoteNames.first { ref.dropFirst("refs/remotes/".count).hasPrefix($0 + "/") } : nil
            entries.append(.init(ref: ref, upstream: fields[1].isEmpty ? nil : String(fields[1]), worktreePath: fields[3].isEmpty ? nil : String(fields[3]),
                                 committedAt: TimeInterval(fields[4]).map(Date.init(timeIntervalSince1970:)), isHead: fields[5] == "*", remote: remote))
        }
        let preferred = try? await upstreamRemote(at: repository)
        return .init(repositoryRoot: repository.path, entries: entries, defaultBranch: try await defaultBranch(preferredRemote: preferred))
    }

    /// Commits the index (or exactly `only` paths after staging them) and streams sanitized hook and
    /// Git output lines while it runs. Returns the new HEAD commit.
    @discardableResult
    public func commit(message: String, only paths: [String]? = nil, timeout: Duration = .seconds(900),
                       onOutput: @escaping @Sendable (String) -> Void) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoincideError("Enter a commit message.") }
        if let paths { guard !paths.isEmpty else { throw CoincideError("Choose at least one file to commit.") }; try Self.validatePaths(paths) }
        return try await mutate { repository in
            var args = ["commit", "-F", "-"]
            if let paths { args += ["--only", "--"] + paths }
            let invocation = invocation(args, at: repository)
            let result = try await GitStreamingCommand.run(arguments: invocation.arguments, environment: invocation.environment,
                                                           input: Data(message.utf8), timeout: timeout, onLine: onOutput)
            try Task.checkCancellation()
            guard result.status == 0 else {
                let detail = Self.redactURLs(String(decoding: result.error.suffix(16_000), as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = Self.redactURLs(String(decoding: result.output.suffix(16_000), as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
                throw CoincideError(!detail.isEmpty ? detail : !fallback.isEmpty ? fallback : "Git commit failed (exit \(result.status)).")
            }
            return try await line(["rev-parse", "--verify", "HEAD^{commit}"], at: repository)
        }
    }

    func upstreamRemote(at repository: URL) async throws -> String? {
        let snapshot = try await status()
        guard !snapshot.isDetached, !snapshot.isUnborn else { return nil }
        return try await upstream(for: snapshot.branch)?.remote
    }
    func commit(for revision: String, at repository: URL) async throws -> String? {
        let result = try await run(["rev-parse", "--verify", "--quiet", "--end-of-options", revision + "^{commit}"], at: repository)
        guard result.status == 0, let value = String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), Self.isObjectID(value) else { return nil }
        return value
    }
    func bounded(_ args: [String], at directory: URL, maxBytes: Int, accepted: Set<Int32> = [0], timeout: Duration = .seconds(120)) async throws -> (output: String, truncated: Bool) {
        let invocation = invocation(args, at: directory)
        let result = try await GitStreamingCommand.run(arguments: invocation.arguments, environment: invocation.environment, input: nil, timeout: timeout, maxOutput: maxBytes)
        try Task.checkCancellation()
        guard result.truncated || accepted.contains(result.status) else {
            let detail = Self.redactURLs(String(decoding: result.error.suffix(16_000), as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CoincideError(detail.isEmpty ? "Git failed (exit \(result.status))." : detail)
        }
        var output = result.output
        if result.truncated { output = output.prefix(maxBytes); while !output.isEmpty, String(data: output, encoding: .utf8) == nil { output.removeLast() } }
        return (String(decoding: output, as: UTF8.self), result.truncated)
    }
    static func validateRevision(_ revision: String) throws {
        guard !revision.isEmpty, revision.utf8.count <= 1_024, !revision.hasPrefix("-"),
              !revision.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw CoincideError("Choose a valid branch or commit.") }
    }
    static func isObjectID(_ value: String) -> Bool { [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

/// Runs one Git child with bounded output and optional live line delivery.
enum GitStreamingCommand {
    struct Result: Sendable { var output: Data; var error: Data; var status: Int32; var truncated: Bool }

    static func run(arguments: [String], environment: [String: String], input: Data?, timeout: Duration,
                    maxOutput: Int = 16 * 1_024 * 1_024, onLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        try Task.checkCancellation()
        guard let git = ProcessChannel.findExecutable("git") else { throw CoincideError("git is not installed or executable.") }
        let channel = try ProcessChannel(executable: git, arguments: arguments, environment: environment)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Result.self) { group in
                group.addTask {
                    var out = Data(), err = Data(), pending = [Data(), Data()]
                    func deliver(_ data: Data, stream: Int) {
                        guard let onLine else { return }
                        pending[stream].append(data)
                        while let index = pending[stream].firstIndex(where: { $0 == 10 || $0 == 13 }) {
                            let line = pending[stream][pending[stream].startIndex..<index]
                            pending[stream] = Data(pending[stream][(index + 1)...])
                            if let text = sanitizedLine(line) { onLine(text) }
                        }
                        if pending[stream].count > 4_096 { if let text = sanitizedLine(pending[stream]) { onLine(text) }; pending[stream] = Data() }
                    }
                    for await event in channel.events {
                        try Task.checkCancellation()
                        switch event {
                        case .stdout(let data):
                            deliver(data, stream: 0); out.append(data)
                            if out.count > maxOutput { channel.stop(); return Result(output: out, error: err, status: -1, truncated: true) }
                        case .stderr(let data):
                            deliver(data, stream: 1)
                            if err.count < 262_144 { err.append(data.prefix(262_144 - err.count)) }
                        case .exited(let status):
                            for stream in 0..<2 where !pending[stream].isEmpty { if let text = sanitizedLine(pending[stream]) { onLine?(text) } }
                            return Result(output: out, error: err, status: status, truncated: false)
                        }
                    }
                    try Task.checkCancellation()
                    throw CoincideError("Git ended without an exit status.")
                }
                group.addTask { try await Task.sleep(for: timeout); channel.stop(); throw CoincideError("Git timed out.") }
                do {
                    if let input { try await channel.write(input) }
                    channel.finishInput()
                    let result = try await group.next()!
                    group.cancelAll(); return result
                } catch { channel.stop(); group.cancelAll(); try Task.checkCancellation(); throw error }
            }
        } onCancel: { channel.stop() }
    }

    /// Removes terminal escapes and control characters, redacts URLs, and bounds length.
    static func sanitizedLine(_ data: Data) -> String? {
        var text = String(decoding: data, as: UTF8.self)
        if let regex = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)?") {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 || $0 == "\t" }))
        text = GitService.redactURLs(text).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }
}
