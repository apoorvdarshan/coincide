import Foundation

public struct ChangedFile: Sendable, Identifiable, Equatable {
    public var path: String
    public var previousPath: String?
    public var indexStatus: Character
    public var worktreeStatus: Character
    public var id: String { path }
    public var isUntracked: Bool { indexStatus == "?" && worktreeStatus == "?" }
    public var isConflicted: Bool { indexStatus == "U" || worktreeStatus == "U" || status == "AA" || status == "DD" }
    public var isStaged: Bool { !isConflicted && indexStatus != " " && indexStatus != "?" }
    public var status: String { String([indexStatus, worktreeStatus]) }
}

public struct GitSnapshot: Sendable, Equatable {
    public var repositoryRoot: URL
    public var branch: String
    public var head: String?
    public var isDetached: Bool
    public var upstream: String?
    /// Nil when the upstream commit is unavailable locally (for example, a deleted remote branch).
    public var ahead: Int?
    public var behind: Int?
    public var changes: [ChangedFile]
    public var isUnborn: Bool { head == nil }
    public var isClean: Bool { changes.isEmpty }
    public var hasConflicts: Bool { changes.contains(where: \.isConflicted) }
    public var displayBranch: String { isDetached ? "Detached at \(head.map { String($0.prefix(10)) } ?? "HEAD")" : branch }
}

public struct GitBranch: Sendable, Identifiable, Equatable {
    public var ref: String
    public var upstream: String?
    public var id: String { ref }
    public var isRemote: Bool { ref.hasPrefix("refs/remotes/") }
    public var name: String { String(ref.dropFirst(isRemote ? "refs/remotes/".count : "refs/heads/".count)) }
}

public struct GitUpstream: Sendable, Equatable {
    public var remote: String
    public var branch: String
}

public struct GitService: Sendable {
    public let root: URL
    public let networkTimeout: Duration
    public init(root: URL, networkTimeout: Duration = .seconds(120)) { self.root = root; self.networkTimeout = networkTimeout }

    public func repositoryRoot() async throws -> URL {
        URL(fileURLWithPath: try await line(["rev-parse", "--path-format=absolute", "--show-toplevel"]))
    }
    public func status() async throws -> GitSnapshot {
        let repository = try await repositoryRoot()
        let data = try await command(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], at: repository)
        return try Self.parseSnapshot(data, root: repository)
    }

    /// Porcelain v2 returns branch identity and changes together, including before the first commit.
    /// NUL records preserve whitespace, quotes, newlines, and rename source/destination paths.
    public static func parseSnapshot(_ data: Data, root: URL) throws -> GitSnapshot {
        guard data.last == 0, String(data: data, encoding: .utf8) != nil else { throw CoincideError("Git status contains an incomplete record or an unsupported filename encoding.") }
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        var branch: String?, head: String?, sawHead = false, upstream: String?, ahead: Int?, behind: Int?
        var files: [ChangedFile] = [], index = 0
        while index < records.count {
            if records[index].isEmpty {
                guard index == records.count - 1 else { throw CoincideError("Malformed empty Git status record.") }
                break
            }
            let record = records[index]; index += 1
            let text = String(decoding: record, as: UTF8.self)
            if text.hasPrefix("# ") {
                if text.hasPrefix("# branch.oid ") {
                    guard !sawHead else { throw CoincideError("Duplicate Git branch header.") }
                    sawHead = true
                    let value = String(text.dropFirst(13))
                    guard value == "(initial)" || (!value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }) else { throw CoincideError("Malformed Git commit header.") }
                    head = value == "(initial)" ? nil : value
                } else if text.hasPrefix("# branch.head ") { branch = String(text.dropFirst(14)) }
                else if text.hasPrefix("# branch.upstream ") { upstream = String(text.dropFirst(18)) }
                else if text.hasPrefix("# branch.ab ") {
                    let fields = text.dropFirst(12).split(separator: " ")
                    guard fields.count == 2, fields[0].first == "+", fields[1].first == "-",
                          let a = Int(fields[0].dropFirst()), let b = Int(fields[1].dropFirst()), a >= 0, b >= 0 else { throw CoincideError("Malformed Git tracking header.") }
                    ahead = a; behind = b
                }
                continue // Future headers are explicitly extensible.
            }
            guard let kind = record.first else { continue }
            if kind == 63 || kind == 33 { // ? untracked / ! ignored
                guard record.count > 2, record[record.startIndex + 1] == 32 else { throw CoincideError("Malformed Git path record.") }
                if kind == 63 { files.append(.init(path: String(decoding: record.dropFirst(2), as: UTF8.self), indexStatus: "?", worktreeStatus: "?")) }
                continue
            }
            let splits: Int
            switch kind { case 49: splits = 8; case 50: splits = 9; case 117: splits = 10; default: throw CoincideError("Unsupported Git status record.") }
            let fields = record.split(separator: 32, maxSplits: splits, omittingEmptySubsequences: false)
            guard fields.count == splits + 1, fields[1].count == 2, !fields.last!.isEmpty else { throw CoincideError("Malformed Git status.") }
            let xy = Array(fields[1])
            func character(_ byte: UInt8) -> Character { byte == 46 ? " " : Character(UnicodeScalar(byte)) }
            var previous: String?
            if kind == 50 {
                guard index < records.count, !records[index].isEmpty else { throw CoincideError("Missing rename source in Git status.") }
                previous = String(decoding: records[index], as: UTF8.self); index += 1
            }
            files.append(.init(path: String(decoding: fields.last!, as: UTF8.self), previousPath: previous,
                               indexStatus: character(xy[0]), worktreeStatus: character(xy[1])))
        }
        guard sawHead, let branch, !branch.isEmpty else { throw CoincideError("Missing Git branch information.") }
        return .init(repositoryRoot: root, branch: branch == "(detached)" ? "HEAD" : branch, head: head,
                     isDetached: branch == "(detached)", upstream: upstream, ahead: ahead, behind: behind, changes: files)
    }

    /// Legacy v1 parser retained for imported status fixtures.
    public static func parseStatus(_ data: Data) throws -> [ChangedFile] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var files: [ChangedFile] = [], i = 0
        while i < fields.count, !fields[i].isEmpty {
            let field = fields[i]; i += 1
            guard field.count >= 4, field[field.startIndex + 2] == 32 else { throw CoincideError("Malformed Git status.") }
            let x = Character(UnicodeScalar(field[field.startIndex])), y = Character(UnicodeScalar(field[field.startIndex + 1]))
            let path = String(decoding: field.dropFirst(3), as: UTF8.self)
            var previous: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                guard i < fields.count, !fields[i].isEmpty else { throw CoincideError("Missing rename source in Git status.") }
                previous = String(decoding: fields[i], as: UTF8.self); i += 1
            }
            files.append(ChangedFile(path: path, previousPath: previous, indexStatus: x, worktreeStatus: y))
        }
        return files
    }

    public func diff(file: ChangedFile? = nil, staged: Bool = false) async throws -> String {
        let repository = try await repositoryRoot()
        if let file, file.isUntracked {
            let url = try WorkspaceFiles(root: repository).resolve(file.path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 2_000_000 else { return "Binary or large untracked file: \(file.path)" }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return "Binary or large untracked file: \(file.path)" }
            return "+++ \(file.path) (untracked)\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        }
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color"]
        if staged { args.append("--cached") }
        args.append("--")
        if let file { try Self.validatePaths([file.path] + (file.previousPath.map { [$0] } ?? [])); args.append(file.path); if let previous = file.previousPath { args.append(previous) } }
        return String(decoding: try await command(args, at: repository), as: UTF8.self)
    }
    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }; try Self.validatePaths(paths)
        try await mutate { repository in
            _ = try await command(["add", "--pathspec-from-file=-", "--pathspec-file-nul"], at: repository, input: Self.pathInput(paths))
        }
    }
    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }; try Self.validatePaths(paths)
        try await mutate { repository in
            let snapshot = try await GitService(root: repository).status()
            // An unborn branch has no HEAD to restore. Removing only index entries leaves all bytes intact.
            let args = snapshot.isUnborn ? ["rm", "--cached", "-f", "-r", "--ignore-unmatch"] : ["restore", "--staged"]
            _ = try await command(args + ["--pathspec-from-file=-", "--pathspec-file-nul"], at: repository, input: Self.pathInput(paths))
        }
    }
    public func commit(message: String) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoincideError("Enter a commit message.") }
        try await mutate { repository in _ = try await command(["commit", "-F", "-"], at: repository, input: Data(message.utf8)) }
    }
    public func initialize(branch: String = "main") async throws {
        let directory = root.standardizedFileURL.resolvingSymlinksInPath()
        try await GitOperationGate.shared.perform(key: directory.path) {
            try await validateBranch(branch)
            let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let existing = try await run(["rev-parse", "--git-dir"], at: directory)
            guard existing.status != 0, !entries.contains(".git") else { throw CoincideError("This folder already belongs to a Git repository.") }
            _ = try await command(["init", "--initial-branch", branch, "--", directory.path], at: directory)
        }
    }
    public func branches() async throws -> [String] { try await branchDetails().filter { !$0.isRemote }.map(\.name) }
    public func branchDetails() async throws -> [GitBranch] {
        let data = try await command(["for-each-ref", "--format=%(refname)%00%(upstream:short)%00%(symref)%00", "refs/heads/", "refs/remotes/"])
        return try String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 4 else { throw CoincideError("Malformed Git branch list.") }
            guard fields[2].isEmpty else { return nil } // symbolic origin/HEAD is not a branch choice
            return .init(ref: String(fields[0]), upstream: fields[1].isEmpty ? nil : String(fields[1]))
        }
    }
    public func remotes() async throws -> [String] {
        String(decoding: try await command(["remote"]), as: UTF8.self).split(separator: "\n").map(String.init)
    }
    public func upstream(for branch: String) async throws -> GitUpstream? {
        try await validateBranch(branch)
        let data = try await command(["for-each-ref", "--format=%(upstream:remotename)%00%(upstream:remoteref)", "refs/heads/" + branch])
        let fields = Self.withoutFinalNewline(String(decoding: data, as: UTF8.self)).split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count == 2, !fields[0].isEmpty, fields[1].hasPrefix("refs/heads/") else { return nil }
        return .init(remote: String(fields[0]), branch: String(fields[1].dropFirst("refs/heads/".count)))
    }
    public func checkout(branch: String) async throws {
        try await validateBranch(branch)
        try await mutate { repository in _ = try await command(["switch", "--no-guess", "--no-recurse-submodules", "--", branch], at: repository) }
    }
    /// Transactional creation: Git does not leave a new branch behind if the switch would lose edits.
    public func createBranch(_ branch: String, tracking remoteRef: String? = nil) async throws {
        try await validateBranch(branch)
        try await mutate { repository in
            var args = ["switch", "--no-recurse-submodules", "--create", branch]
            if let remoteRef {
                guard remoteRef.hasPrefix("refs/remotes/"), try await branchDetails().contains(where: { $0.ref == remoteRef && $0.isRemote }) else { throw CoincideError("Choose an existing remote branch.") }
                args += ["--track=direct", "--", remoteRef]
            } else { args.append("--no-track") }
            _ = try await command(args, at: repository)
        }
    }
    public func fetch(remote: String) async throws {
        try await mutate { repository in
            try await validateRemote(remote)
            _ = try await command(["fetch", "--no-recurse-submodules", "--no-prune", "--", remote], at: repository, timeout: networkTimeout)
        }
    }
    /// No implicit rebase, stash, merge commit, or discard, regardless of the user's pull config.
    public func pull(branch: String) async throws {
        try await mutate { repository in
            let snapshot = try await GitService(root: repository).status()
            guard snapshot.branch == branch, !snapshot.isDetached, !snapshot.isUnborn else { throw CoincideError("The current branch changed. Refresh before pulling.") }
            guard snapshot.isClean else { throw CoincideError("Commit or stash your changes before pulling.") }
            guard let target = try await upstream(for: branch) else { throw CoincideError("This branch has no upstream. Publish it or configure tracking first.") }
            if target.remote != "." { try await validateRemote(target.remote) }
            try await validateBranch(target.branch)
            _ = try await command(["-c", "pull.rebase=false", "-c", "pull.squash=false", "-c", "merge.autostash=false", "pull", "--ff-only", "--no-rebase", "--no-autostash", "--no-recurse-submodules", "--", target.remote, "refs/heads/" + target.branch], at: repository, timeout: networkTimeout)
        }
    }
    /// Pushes exactly one explicitly named local branch, without forced updates, tags, or mirror config.
    /// Git's pre-push hooks and remote branch protection remain active.
    public func push(branch: String, remote: String, remoteBranch: String, setUpstream: Bool) async throws {
        try await validateBranch(branch); try await validateBranch(remoteBranch)
        try await mutate { repository in
            let snapshot = try await GitService(root: repository).status()
            guard snapshot.branch == branch, !snapshot.isDetached, !snapshot.isUnborn else { throw CoincideError("The current branch changed. Refresh before pushing.") }
            guard !snapshot.hasConflicts else { throw CoincideError("Resolve conflicts before pushing.") }
            try await validateRemote(remote)
            var args = ["push", "--porcelain", "--no-force", "--no-mirror", "--no-follow-tags", "--recurse-submodules=no"]
            if setUpstream { args.append("--set-upstream") }
            args += ["--", remote, "refs/heads/\(branch):refs/heads/\(remoteBranch)"]
            _ = try await command(args, at: repository, timeout: networkTimeout, configuration: ["remote.\(remote).mirror": "false"])
        }
    }
    public func createWorktree(at path: URL, branch: String, base: String = "HEAD") async throws {
        try await validateBranch(branch)
        guard !base.isEmpty, !base.hasPrefix("-"), !base.contains("\0") else { throw CoincideError("Invalid base ref.") }
        try await mutate { repository in _ = try await command(["worktree", "add", "-b", branch, "--", path.path, base], at: repository) }
    }

    private func mutate<T: Sendable>(_ operation: @Sendable (URL) async throws -> T) async throws -> T {
        let repository = try await repositoryRoot()
        let common = try await line(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: repository)
        let key = URL(fileURLWithPath: common).standardizedFileURL.resolvingSymlinksInPath().path
        return try await GitOperationGate.shared.perform(key: key) { try await operation(repository) }
    }
    private func validateBranch(_ branch: String) async throws {
        guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.contains("\0"),
              try await line(["check-ref-format", "--branch", branch]) == branch else { throw CoincideError("Enter a valid branch name.") }
    }
    private func validateRemote(_ remote: String) async throws {
        guard !remote.isEmpty, !remote.hasPrefix("-"), try await remotes().contains(remote) else { throw CoincideError("Choose a configured remote.") }
    }
    private static func validatePaths(_ paths: [String]) throws {
        guard paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator: "/").contains("..") }) else { throw CoincideError("Choose paths inside the repository.") }
    }
    private static func pathInput(_ paths: [String]) -> Data { Data((paths.joined(separator: "\0") + "\0").utf8) }
    private static func withoutFinalNewline(_ text: String) -> String { text.hasSuffix("\n") ? String(text.dropLast()) : text }
    private func line(_ args: [String], at directory: URL? = nil) async throws -> String {
        let data = try await command(args, at: directory)
        guard let value = String(data: data, encoding: .utf8) else { throw CoincideError("Git returned an unsupported path encoding.") }
        return Self.withoutFinalNewline(value)
    }
    @discardableResult private func command(_ args: [String], at directory: URL? = nil, input: Data? = nil, timeout: Duration = .seconds(30), configuration: [String: String] = [:]) async throws -> Data {
        let result = try await run(args, at: directory, input: input, timeout: timeout, configuration: configuration)
        try Task.checkCancellation()
        guard result.status == 0 else {
            let detail = Self.redactURLs(String(decoding: result.error, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CoincideError(detail.isEmpty ? "Git failed (exit \(result.status))." : String(detail.prefix(16_000)))
        }
        return result.output
    }
    private func run(_ args: [String], at directory: URL? = nil, input: Data? = nil, timeout: Duration = .seconds(30), configuration: [String: String] = [:]) async throws -> CommandResult {
        var environment = ProcessChannel.environment()
        // Shell Git context must not redirect an operation away from its selected workspace.
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX"] { environment.removeValue(forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GCM_INTERACTIVE"] = "Never"; environment["GIT_MERGE_AUTOEDIT"] = "no"
        environment["LC_ALL"] = "C"
        var overrides: [String] = []
        for (index, key) in configuration.keys.sorted().enumerated() {
            let variable = "COINCIDE_GIT_CONFIG_VALUE_" + String(index)
            environment[variable] = configuration[key]
            // --config-env splits at the last '=', so remote names containing '=' remain literal.
            overrides.append("--config-env=\(key)=\(variable)")
        }
        return try await CommandRunner.run("git", overrides + ["--no-pager", "--no-optional-locks", "--literal-pathspecs", "-c", "color.ui=false", "-C", (directory ?? root).path] + args,
                                           input: input, timeout: timeout, environment: environment)
    }
    /// Remotes may predate Coincide and contain credentials. Never copy their userinfo or query into UI errors.
    public static func redactURLs(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?i)\\b(?:https?|ssh|git|ftps?)://[^\\s<>\\\"']+") else { return text }
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let raw = String(output[range])
            guard var url = URLComponents(string: raw) else { output.replaceSubrange(range, with: "[remote URL]"); continue }
            url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
            output.replaceSubrange(range, with: url.string ?? "[remote URL]")
        }
        return output
    }
}
