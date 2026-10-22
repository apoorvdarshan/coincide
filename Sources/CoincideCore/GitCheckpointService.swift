import Darwin
import Foundation

/// Local snapshots of working bytes. The real index, HEAD, branches and checkout are never written.
/// Each attempt owns one alternate index and one exclusive private ref; interrupted attempts are preserved.
public struct GitCheckpointService: Sendable {
    public let root: URL
    private let command: GitWorktreeCommand
    private let timeout: Duration
    public init(root: URL, timeout: Duration = .seconds(60)) {
        self.root = root; self.timeout = timeout; command = .init(environment: Self.environment(ProcessChannel.environment()), executable: nil)
    }
    init(root: URL, environment: [String: String], gitExecutable: URL? = nil, timeout: Duration = .seconds(60)) {
        self.root = root; self.timeout = timeout; command = .init(environment: Self.environment(environment), executable: gitExecutable)
    }
    private static func environment(_ original: [String: String]) -> [String: String] {
        var environment = original
        // Legacy GIT_CONFIG redirects `git config` alone, unlike add/write-tree. Never inspect a
        // different configuration source from the commands that build checkpoint objects.
        environment.removeValue(forKey: "GIT_CONFIG"); return environment
    }
    public func prepare(id: UUID = UUID()) async throws -> GitCheckpointPlan {
        try await translated {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            let context = try await discover(deadline: deadline)
            let configuration = try await configuration(context, deadline: deadline)
            let format = try CheckpointFiles.line(await output(["rev-parse", "--show-object-format"], context, deadline: deadline))
            let head = try await head(context, deadline: deadline)
            let revision = try CheckpointFiles.index(context.admin)
            let plan = try GitCheckpointPlan(id: id, workspacePath: context.workspace.path, repositoryPath: context.repository.path,
                gitDirectoryPath: context.admin.path, commonDirectoryPath: context.common.path,
                workspaceIdentity: context.workspace.identity, repositoryIdentity: context.repository.identity,
                gitDirectoryIdentity: context.admin.identity, commonDirectoryIdentity: context.common.identity, objectDirectoryIdentity: context.objects.identity,
                headCommit: head, objectFormat: format, configurationDigest: configuration.digest, indexRevision: revision)
            guard try !context.common.exists(CheckpointFiles.metadataName(id)), try !context.admin.exists(CheckpointFiles.indexName(id)),
                  try await reference(plan, context, deadline: deadline) == nil else { throw GitCheckpointError(.refCollision) }
            try await validateCurrent(plan, context, deadline: deadline)
            return plan
        }
    }
    public func capture(_ plan: GitCheckpointPlan) async throws -> GitCheckpointReceipt {
        try await translated {
            try validateSession(plan)
            let deadline = ContinuousClock.now.advanced(by: timeout), context = try await discover(deadline: deadline)
            try validate(plan, context)
            return try await GitOperationGate.shared.perform(key: plan.commonDirectoryPath) {
                try await execute(plan, context, deadline: deadline)
            }
        }
    }
    public func inspect(_ plan: GitCheckpointPlan) async throws -> GitCheckpointInspection {
        try await translated {
            try validateSession(plan)
            let deadline = ContinuousClock.now.advanced(by: timeout), context = try await discover(deadline: deadline)
            try validate(plan, context)
            return try await inspect(plan, context, deadline: deadline)
        }
    }
    public func diff(from: GitCheckpointReceipt, to: GitCheckpointReceipt, paths: [String]? = nil,
                     ignoreWhitespace: Bool = false, maxBytes: Int = 1_048_576) async throws -> GitCheckpointDiff {
        try await translated {
            try from.validate(); try to.validate(); try validateSession(from.plan); try validateSession(to.plan)
            guard (1...8_388_608).contains(maxBytes), sameWorkspace(from.plan, to.plan) else { throw GitCheckpointError(.invalidPlan) }
            if let paths { for path in paths { try CheckpointFiles.relative(path) } }
            let deadline = ContinuousClock.now.advanced(by: timeout), context = try await discover(deadline: deadline)
            try validate(from.plan, context); try validate(to.plan, context)
            guard try await inspect(from.plan, context, deadline: deadline) == .ready(from),
                  try await inspect(to.plan, context, deadline: deadline) == .ready(to) else { throw GitCheckpointError(.incomplete) }
            if paths?.isEmpty == true { return .init(patch: "", truncated: false) }
            var args = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--ignore-submodules=all"]
            if ignoreWhitespace { args.append("--ignore-all-space") }
            args += [from.commit, to.commit, "--"] + (paths ?? ["."])
            let result = try await run(args, context, deadline: deadline, maximum: maxBytes, truncated: true)
            guard result.status == 0 || result.stdoutOverflow else { throw GitCheckpointError(.commandFailed) }
            try validate(from.plan, context); try await validateMapping(context, deadline: deadline)
            // Git patches may quote arbitrary byte filenames. Preview is deliberately lossy UTF-8.
            let preview = GitService.redactURLs(String(decoding: result.output, as: UTF8.self))
            // URL sanitization and lossy decoding can change byte counts. Keep the published
            // preview within the caller's cap without emitting an incomplete UTF-8 scalar.
            var bytes = Data(preview.utf8.prefix(maxBytes))
            while !bytes.isEmpty, String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            return .init(patch: String(decoding: bytes, as: UTF8.self), truncated: result.stdoutOverflow || preview.utf8.count > maxBytes)
        }
    }

    private struct Context: Sendable {
        let workspace: GitWorktreeDirectory
        let repository: GitWorktreeDirectory
        let admin: GitWorktreeDirectory
        let common: GitWorktreeDirectory
        let objects: GitWorktreeDirectory
    }
    private struct Configuration: Sendable {
        let digest: String
        let sparse: Bool
        let values: [String: String]
        let files: [String: Data]
    }
    private struct Staging: Sendable { let admin: GitWorktreeDirectory }
    private static let safeOptions = ["--no-lazy-fetch", "--no-replace-objects", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.splitIndex=false",
        "-c", "splitIndex.sharedIndexExpire=never", "-c", "sparse.expectFilesOutsideOfPatterns=false", "-c", "commit.gpgSign=false",
        "-c", "core.fsync=objects,reference", "-c", "core.fsyncMethod=fsync"]
    private func translated<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch is CancellationError { throw CancellationError() }
        catch let error as GitCheckpointError { throw error }
        catch let error as GitWorktreeError {
            switch error.failure {
            case .timedOut: throw GitCheckpointError(.timedOut)
            case .outputLimit: throw GitCheckpointError(.outputLimit)
            case .notRepository: throw GitCheckpointError(.notRepository)
            case .ownershipLost: throw GitCheckpointError(.ownershipLost)
            case .metadataCorrupt: throw GitCheckpointError(.metadataInvalid)
            default: throw GitCheckpointError(.commandFailed)
            }
        }
        catch { try Task.checkCancellation(); throw GitCheckpointError(.commandFailed) }
    }
    private func validateURL() throws {
        guard root.isFileURL, let c = URLComponents(url: root, resolvingAgainstBaseURL: false), c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.host == nil || c.host == "" || c.host?.lowercased() == "localhost" else { throw GitCheckpointError(.invalidPlan) }
    }
    private func validateSession(_ plan: GitCheckpointPlan) throws {
        try validateURL(); try plan.validate(); try Task.checkCancellation()
        guard CheckpointFiles.canonical(root.path) == plan.workspacePath else { throw GitCheckpointError(.ownershipLost) }
    }
    private func validate(_ plan: GitCheckpointPlan, _ c: Context) throws {
        guard c.workspace.path == plan.workspacePath, c.repository.path == plan.repositoryPath,
              c.admin.path == plan.gitDirectoryPath, c.common.path == plan.commonDirectoryPath else { throw GitCheckpointError(.ownershipLost) }
        try c.workspace.validate(expected: plan.workspaceIdentity); try c.repository.validate(expected: plan.repositoryIdentity)
        try c.admin.validate(expected: plan.gitDirectoryIdentity); try c.common.validate(expected: plan.commonDirectoryIdentity)
        try c.objects.validate(expected: plan.objectDirectoryIdentity)
    }
    private func discover(deadline: ContinuousClock.Instant) async throws -> Context {
        try validateURL(); try Task.checkCancellation()
        let workspace = try GitWorktreeDirectory(path: CheckpointFiles.canonical(root.path))
        func discoverPath(_ flag: String) async throws -> String {
            let result = try await command.run(Self.safeOptions + ["rev-parse", "--path-format=absolute", flag], cwdFD: workspace.fd, timeout: remaining(deadline), maximumOutput: 16_385)
            guard result.status == 0 else { throw GitCheckpointError(.notRepository) }
            try workspace.validate(); return CheckpointFiles.canonical(try CheckpointFiles.line(result.output))
        }
        let repository = try GitWorktreeDirectory(path: await discoverPath("--show-toplevel"))
        let common = try GitWorktreeDirectory(path: await discoverPath("--git-common-dir"))
        let admin = try GitWorktreeDirectory(path: await discoverPath("--absolute-git-dir"))
        guard workspace.path == repository.path || workspace.path.hasPrefix(repository.path + "/"),
              admin.path == common.path || admin.path.hasPrefix(common.path + "/worktrees/") else { throw GitCheckpointError(.ownershipLost) }
        let objects = try GitWorktreeDirectory(child: "objects", parent: common)
        let c = Context(workspace: workspace, repository: repository, admin: admin, common: common, objects: objects)
        guard try CheckpointFiles.line(await output(["rev-parse", "--is-inside-work-tree"], c, deadline: deadline)) == "true" else { throw GitCheckpointError(.notRepository) }
        try await validateMapping(c, deadline: deadline); return c
    }
    private func validateMapping(_ c: Context, deadline: ContinuousClock.Instant) async throws {
        for (flag, expected) in [("--show-toplevel", c.repository), ("--git-common-dir", c.common), ("--absolute-git-dir", c.admin)] {
            let result = try await command.run(Self.safeOptions + ["rev-parse", "--path-format=absolute", flag], cwdFD: c.workspace.fd, timeout: remaining(deadline), maximumOutput: 16_385)
            guard result.status == 0, CheckpointFiles.canonical(try CheckpointFiles.line(result.output)) == expected.path else { throw GitCheckpointError(.ownershipLost) }
            try expected.validate()
        }
        if c.admin.path != c.common.path {
            guard let backlink = try c.admin.read("gitdir", maximum: 16_384), let common = try c.admin.read("commondir", maximum: 16_384),
                  CheckpointFiles.canonical(try CheckpointFiles.line(backlink)) == c.repository.path + "/.git" else { throw GitCheckpointError(.ownershipLost) }
            let value = try CheckpointFiles.line(common)
            guard CheckpointFiles.canonical(value.hasPrefix("/") ? value : c.admin.path + "/" + value) == c.common.path else { throw GitCheckpointError(.ownershipLost) }
        }
        try c.workspace.validate(); try c.repository.validate(); try c.common.validate(); try c.admin.validate(); try c.objects.validate()
    }
    private func remaining(_ deadline: ContinuousClock.Instant) throws -> Duration {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw GitCheckpointError(.timedOut) }; return min(remaining, .seconds(30))
    }
    private func run(_ args: [String], _ c: Context, deadline: ContinuousClock.Instant, maximum: Int = 4_194_304,
                     index: String? = nil, truncated: Bool = false, inputFD: Int32? = nil, staging: Staging? = nil) async throws -> GitWorktreeCommandResult {
        try c.workspace.validate(); try c.repository.validate(); try c.admin.validate(); try c.common.validate(); try c.objects.validate()
        try staging?.admin.validate()
        let result = try await command.run(Self.safeOptions + args, cwdFD: c.workspace.fd, timeout: remaining(deadline), maximumOutput: maximum,
            gitDirectory: staging?.admin.path ?? c.admin.path, commonDirectory: staging?.admin.path ?? c.common.path, workTree: c.repository.path,
            checkpointIndexPath: index, allowTruncatedOutput: truncated, trustedInputFD: inputFD,
            checkpointObjectDirectory: staging == nil ? nil : c.objects.path)
        try c.workspace.validate(); try c.repository.validate(); try c.admin.validate(); try c.common.validate(); try c.objects.validate()
        try staging?.admin.validate(); return result
    }
    private func output(_ args: [String], _ c: Context, deadline: ContinuousClock.Instant, maximum: Int = 4_194_304, index: String? = nil, staging: Staging? = nil) async throws -> Data {
        let result = try await run(args, c, deadline: deadline, maximum: maximum, index: index, staging: staging)
        guard result.status == 0 else { throw GitCheckpointError(.commandFailed) }; return result.output
    }
    private func configuration(_ c: Context, deadline: ContinuousClock.Instant) async throws -> Configuration {
        let data = try await output(["config", "--null", "--list"], c, deadline: deadline)
        guard data.isEmpty || data.last == 0 else { throw GitCheckpointError(.commandFailed) }
        var values = [String: String]()
        for entry in data.split(separator: 0) {
            guard let separator = entry.firstIndex(of: 10), let key = String(data: entry[..<separator], encoding: .utf8),
                  let value = String(data: entry[entry.index(after: separator)...], encoding: .utf8) else { throw GitCheckpointError(.unsupportedConfiguration) }
            let lower = key.lowercased()
            if lower.hasPrefix("filter."), (lower.hasSuffix(".clean") || lower.hasSuffix(".process")), !value.isEmpty { throw GitCheckpointError(.unsupportedConfiguration) }
            values[lower] = value
        }
        func enabled(_ key: String) -> Bool { ["true", "yes", "on", "1", ""].contains(values[key]?.lowercased() ?? "false") }
        let sparse = enabled("core.sparsecheckout")
        guard !sparse || enabled("core.sparsecheckoutcone") else { throw GitCheckpointError(.unsupportedConfiguration) }
        var files = [String: Data]()
        for (name, location) in [("attributes", "info/attributes"), ("exclude", "info/exclude"), ("sparse-checkout", "info/sparse-checkout")] {
            if name == "sparse-checkout", !sparse { continue }
            let path = try CheckpointFiles.line(await output(["rev-parse", "--path-format=absolute", "--git-path", location], c, deadline: deadline, maximum: 16_385))
            if let bytes = try configurationFile(path) { files[name] = bytes }
        }
        for (key, name, fallback) in [("core.attributesfile", "global-attributes", "attributes"), ("core.excludesfile", "global-exclude", "ignore")] {
            let configured = try await run(["config", "--path", "--get", key], c, deadline: deadline, maximum: 16_385)
            let path: String
            if configured.status == 0 { path = try CheckpointFiles.line(configured.output) }
            else if configured.status == 1 {
                let environment = command.environment ?? ProcessChannel.environment()
                guard let home = environment["HOME"] else { throw GitCheckpointError(.unsupportedConfiguration) }
                path = (environment["XDG_CONFIG_HOME"] ?? home + "/.config") + "/git/" + fallback
            } else { throw GitCheckpointError(.commandFailed) }
            if let bytes = try configurationFile(path.hasPrefix("/") ? path : c.workspace.path + "/" + path) { files[name] = bytes }
        }
        guard !sparse || files["sparse-checkout"] != nil else { throw GitCheckpointError(.unsupportedConfiguration) }
        var fingerprint = data
        for key in files.keys.sorted() {
            let bytes = files[key]!
            fingerprint.append(contentsOf: ("\0" + key + "\0" + String(bytes.count) + "\0").utf8); fingerprint.append(bytes)
        }
        return .init(digest: CheckpointFiles.digest(fingerprint), sparse: sparse, values: values, files: files)
    }
    private func configurationFile(_ path: String) throws -> Data? {
        let resolved = CheckpointFiles.canonical(path)
        var node = stat()
        if lstat(resolved, &node) != 0 {
            guard errno == ENOENT || errno == ENOTDIR else { throw GitCheckpointError(.ownershipLost) }; return nil
        }
        guard node.st_mode & S_IFMT == S_IFREG else { throw GitCheckpointError(.unsupportedConfiguration) }
        let file = URL(fileURLWithPath: resolved)
        let parent = try GitWorktreeDirectory(path: file.deletingLastPathComponent().path)
        return try parent.read(file.lastPathComponent, maximum: 131_072, allowEmpty: true)
    }
    private func head(_ c: Context, deadline: ContinuousClock.Instant) async throws -> String? {
        let result = try await run(["rev-parse", "--verify", "--end-of-options", "HEAD^{commit}"], c, deadline: deadline, maximum: 128)
        if result.status == 0 { return try CheckpointFiles.line(result.output) }
        let symbolic = try await run(["symbolic-ref", "--quiet", "HEAD"], c, deadline: deadline, maximum: 16_384)
        guard symbolic.status == 0 else { throw GitCheckpointError(.commandFailed) }
        let name = try CheckpointFiles.line(symbolic.output)
        guard name.hasPrefix("refs/heads/") else { throw GitCheckpointError(.commandFailed) }
        let existing = try await run(["show-ref", "--verify", "--quiet", "--", name], c, deadline: deadline, maximum: 128)
        guard existing.status == 1 else { throw GitCheckpointError(.commandFailed) }; return nil
    }
    private func reference(_ plan: GitCheckpointPlan, _ c: Context, deadline: ContinuousClock.Instant) async throws -> String? {
        let result = try await run(["rev-parse", "--verify", "--quiet", "--end-of-options", plan.reference], c, deadline: deadline, maximum: 128)
        if result.status == 1 { return nil }
        guard result.status == 0 else { throw GitCheckpointError(.refCollision) }
        let value = try CheckpointFiles.line(result.output)
        guard CheckpointValidation.object(value, format: plan.objectFormat) else { throw GitCheckpointError(.refCollision) }; return value
    }
    private func validateCurrent(_ plan: GitCheckpointPlan, _ c: Context, deadline: ContinuousClock.Instant) async throws {
        try validate(plan, c); try await validateMapping(c, deadline: deadline)
        let current: Configuration
        do { current = try await configuration(c, deadline: deadline) }
        catch let error as GitCheckpointError where error.kind == .unsupportedConfiguration { throw GitCheckpointError(.configurationChanged) }
        guard try await head(c, deadline: deadline) == plan.headCommit,
              current.digest == plan.configurationDigest,
              try CheckpointFiles.index(c.admin) == plan.indexRevision else { throw GitCheckpointError(.configurationChanged) }
        try validate(plan, c)
    }
    private func sameWorkspace(_ a: GitCheckpointPlan, _ b: GitCheckpointPlan) -> Bool {
        a.workspacePath == b.workspacePath && a.repositoryPath == b.repositoryPath && a.gitDirectoryPath == b.gitDirectoryPath &&
        a.commonDirectoryPath == b.commonDirectoryPath && a.workspaceIdentity == b.workspaceIdentity && a.repositoryIdentity == b.repositoryIdentity &&
        a.gitDirectoryIdentity == b.gitDirectoryIdentity && a.commonDirectoryIdentity == b.commonDirectoryIdentity && a.objectDirectoryIdentity == b.objectDirectoryIdentity && a.objectFormat == b.objectFormat
    }
    private func makeStaging(_ plan: GitCheckpointPlan, configuration: Configuration, metadata: GitWorktreeDirectory) throws -> Staging {
        let admin = try metadata.claimDirectory("git"), info = try admin.claimDirectory("info")
        _ = try admin.claimDirectory("objects"); _ = try admin.claimDirectory("refs")
        try admin.writeExclusive(Data((plan.headCommit.map { $0 + "\n" } ?? "ref: refs/heads/coincide-unborn\n").utf8), name: "HEAD")
        for name in ["attributes", "exclude", "sparse-checkout"] {
            if let bytes = configuration.files[name] { try info.writeExclusive(bytes, name: name) }
        }
        for name in ["global-attributes", "global-exclude"] {
            try admin.writeExclusive(configuration.files[name] ?? Data(), name: name)
        }
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\"" }
        var settings = ["core.repositoryformatversion": plan.objectFormat == "sha256" ? "1" : "0", "core.bare": "false",
            "core.attributesfile": admin.path + "/global-attributes", "core.excludesfile": admin.path + "/global-exclude"]
        let booleanKeys = ["core.filemode", "core.symlinks", "core.ignorecase", "core.precomposeunicode", "core.protecthfs", "core.protectntfs",
            "core.sparsecheckout", "core.sparsecheckoutcone", "index.sparse"]
        for key in booleanKeys {
            guard let value = configuration.values[key]?.lowercased() else { continue }
            if ["true", "yes", "on", "1", ""].contains(value) { settings[key] = "true" }
            else if ["false", "no", "off", "0"].contains(value) { settings[key] = "false" }
            else { throw GitCheckpointError(.unsupportedConfiguration) }
        }
        for (key, allowed) in [("core.autocrlf", ["true", "false", "input"]), ("core.eol", ["lf", "crlf", "native"]), ("core.safecrlf", ["true", "false", "warn"])] {
            if let value = configuration.values[key]?.lowercased() {
                guard allowed.contains(value) else { throw GitCheckpointError(.unsupportedConfiguration) }; settings[key] = value
            }
        }
        if let value = configuration.values["core.checkroundtripencoding"] {
            guard value.utf8.count <= 256, value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_,. ").contains($0) }) else { throw GitCheckpointError(.unsupportedConfiguration) }
            settings["core.checkroundtripencoding"] = value
        }
        if plan.objectFormat == "sha256" { settings["extensions.objectformat"] = "sha256" }
        var text = ""
        for section in ["core", "index", "extensions"] {
            text += "[" + section + "]\n"
            for key in settings.keys.sorted() where key.hasPrefix(section + ".") { text += "\t" + key.dropFirst(section.count + 1) + " = " + quote(settings[key]!) + "\n" }
        }
        try admin.writeExclusive(Data(text.utf8), name: "config")
        return .init(admin: admin)
    }
    private func execute(_ plan: GitCheckpointPlan, _ c: Context, deadline: ContinuousClock.Instant) async throws -> GitCheckpointReceipt {
        switch try await inspect(plan, c, deadline: deadline) {
        case .ready(let receipt): return receipt
        case .incomplete:
            if try !c.common.exists(CheckpointFiles.metadataName(plan.id)) { throw GitCheckpointError(.refCollision) }
            throw GitCheckpointError(.incomplete)
        case .missing: break
        }
        try await validateCurrent(plan, c, deadline: deadline)
        guard try !c.admin.exists(CheckpointFiles.indexName(plan.id)), try !c.admin.exists(CheckpointFiles.indexName(plan.id) + ".lock") else { throw GitCheckpointError(.refCollision) }
        let configuration = try await configuration(c, deadline: deadline)
        let metadata = try c.common.claimDirectory(CheckpointFiles.metadataName(plan.id))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try metadata.writeExclusive(encoder.encode(plan), name: "plan.json")
        let staging = try makeStaging(plan, configuration: configuration, metadata: metadata)
        // A valid empty index is claimed exclusively before Git sees its path. Git may atomically
        // replace this file, but never reads or writes the user's actual index through this env.
        let initialIndex: Data
        if configuration.sparse {
            guard let revision = plan.indexRevision, let data = try c.admin.read("index", maximum: CheckpointFiles.maximumIndexBytes, allowEmpty: true),
                  CheckpointFiles.digest(data) == revision.digest else { throw GitCheckpointError(.configurationChanged) }
            initialIndex = data
        } else { initialIndex = CheckpointFiles.emptyIndex(format: plan.objectFormat) }
        try CheckpointFiles.claimIndex(initialIndex, name: CheckpointFiles.indexName(plan.id), admin: c.admin)
        let indexPath = c.admin.path + "/" + CheckpointFiles.indexName(plan.id)
        var readTree = [String]()
        if configuration.sparse { readTree += ["-c", "index.sparse=true"] }
        readTree += ["read-tree"]
        if let head = plan.headCommit { readTree += configuration.sparse ? ["--reset", head] : [head] }
        else { readTree.append("--empty") }
        _ = try await output(readTree, c, deadline: deadline, index: indexPath, staging: staging)
        // Sparse exclusions are carried from the real index. Its cached stat fields must not
        // hide same-size/same-timestamp working edits after read-tree rewrites the scratch file.
        if configuration.sparse, let revision = plan.indexRevision { try CheckpointFiles.makeRacy(CheckpointFiles.indexName(plan.id), admin: c.admin, before: revision) }
        if configuration.sparse { try await correctSparseFlags(c, metadata: metadata, index: indexPath, staging: staging, deadline: deadline) }
        try metadata.validate(); try await validateCurrent(plan, c, deadline: deadline)

        // New staged files can be ignored even though they are explicitly tracked. Restore their
        // inclusion, then let add read their current working bytes, never their staged contents.
        let additions = try CheckpointFiles.names(await output(["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-renames",
            "--name-only", "--diff-filter=A", "--relative", "--ita-visible-in-index", "-z", "--", "."], c, deadline: deadline))
        var chunk = [String](), size = 0
        func addChunk(_ paths: [String]) async throws {
            guard !paths.isEmpty else { return }
            _ = try await output(["add", "--force"] + (configuration.sparse ? ["--sparse"] : []) + ["--"] + paths, c, deadline: deadline, index: indexPath, staging: staging)
        }
        for path in additions {
            try CheckpointFiles.relative(path)
            var node = stat()
            if lstat(c.workspace.path + "/" + path, &node) != 0 {
                guard errno == ENOENT || errno == ENOTDIR else { throw GitCheckpointError(.ownershipLost) }; continue
            }
            guard node.st_mode & S_IFMT == S_IFREG || node.st_mode & S_IFMT == S_IFLNK || node.st_mode & S_IFMT == S_IFDIR else { throw GitCheckpointError(.unsupportedConfiguration) }
            if size + path.utf8.count > 65_536 || chunk.count == 512 { try await addChunk(chunk); chunk = []; size = 0 }
            chunk.append(path); size += path.utf8.count
        }
        try await addChunk(chunk)
        // check-ignore does not implement Git's literal pathspec magic. This argument is the
        // fixed trusted dot, so disable that global mode for this one classification command.
        let ignored = try await run(["--no-literal-pathspecs", "check-ignore", "--quiet", "--no-index", "--", "."], c, deadline: deadline, staging: staging)
        guard ignored.status == 0 || ignored.status == 1 else { throw GitCheckpointError(.commandFailed) }
        try await validateCurrent(plan, c, deadline: deadline)
        if configuration.sparse, let revision = plan.indexRevision { try CheckpointFiles.makeRacy(CheckpointFiles.indexName(plan.id), admin: c.admin, before: revision) }
        _ = try await output(["add"] + (configuration.sparse ? ["--sparse"] : []) + [ignored.status == 0 ? "-u" : "-A", "--", "."], c, deadline: deadline, index: indexPath, staging: staging)
        let tree = try CheckpointFiles.line(await output(["write-tree"], c, deadline: deadline, index: indexPath, staging: staging))
        guard CheckpointValidation.object(tree, format: plan.objectFormat) else { throw GitCheckpointError(.commandFailed) }
        let message = "Coincide checkpoint " + plan.id.uuidString.lowercased()
        let commit = try CheckpointFiles.line(await output(["commit-tree", tree] + (plan.headCommit.map { ["-p", $0] } ?? []) + ["-m", message], c, deadline: deadline, index: indexPath, staging: staging))
        let receipt = try GitCheckpointReceipt(plan: plan, commit: commit, tree: tree)
        try metadata.validate(); try await validateCurrent(plan, c, deadline: deadline)
        guard try await reference(plan, c, deadline: deadline) == nil else { throw GitCheckpointError(.refCollision) }
        let publication = try await run(["update-ref", plan.reference, commit, String(repeating: "0", count: plan.objectFormat == "sha256" ? 64 : 40)], c, deadline: deadline, index: indexPath)
        guard publication.status == 0 else { throw GitCheckpointError(.refCollision) }
        // Ref publication alone is not a completion receipt. Only the owned, drained successful
        // command path may write complete.json; an orphaned Git process never proves readiness.
        try await validateCurrent(plan, c, deadline: deadline); try metadata.validate(); try Task.checkCancellation()
        try metadata.writeExclusive(encoder.encode(receipt), name: "complete.json")
        guard try await inspect(plan, c, deadline: deadline) == .ready(receipt) else { throw GitCheckpointError(.metadataInvalid) }
        return receipt
    }
    private func correctSparseFlags(_ c: Context, metadata: GitWorktreeDirectory, index: String, staging: Staging, deadline: ContinuousClock.Instant) async throws {
        let data = try await output(["ls-files", "--sparse", "-v", "-z", "--", "."], c, deadline: deadline, index: index, staging: staging)
        let records = try CheckpointFiles.names(data)
        let prefix = c.workspace.path == c.repository.path ? "" : String(c.workspace.path.dropFirst(c.repository.path.count + 1)) + "/"
        var assumed = [String](), skipped = [String]()
        for record in records {
            let bytes = Array(record.utf8)
            guard bytes.count >= 3, bytes[1] == 32 else { throw GitCheckpointError(.unsupportedConfiguration) }
            let path = String(record.dropFirst(2))
            // Collapsed sparse directory entries retain their skip flags and HEAD blobs.
            if path.hasSuffix("/") { continue }
            try CheckpointFiles.relative(path)
            if (97...122).contains(bytes[0]) { assumed.append(path) }
            if bytes[0] == 83 || bytes[0] == 115 { skipped.append(path) }
        }
        func chunks(_ values: [String]) -> [[String]] {
            var result = [[String]](), part = [String](), count = 0
            for path in values {
                let size = path.utf8.count + prefix.utf8.count + 1
                if count + size > 65_536 || part.count == 512 { result.append(part); part = []; count = 0 }
                part.append(path); count += size
            }
            if !part.isEmpty { result.append(part) }; return result
        }
        for part in chunks(assumed) { _ = try await output(["update-index", "--no-assume-unchanged", "--"] + part, c, deadline: deadline, index: index, staging: staging) }
        for part in chunks(skipped) {
            var input = Data()
            for path in part { input.append(contentsOf: (prefix + path).utf8); input.append(0) }
            let fd = try CheckpointFiles.input(input, metadata: metadata)
            let selected: GitWorktreeCommandResult
            do { selected = try await run(["sparse-checkout", "check-rules", "-z"], c, deadline: deadline, index: index, inputFD: fd, staging: staging) }
            catch { close(fd); throw error }
            close(fd)
            guard selected.status == 0 else { throw GitCheckpointError(.unsupportedConfiguration) }
            let included = Set(try CheckpointFiles.names(selected.output))
            let candidates = Set(part.map { prefix + $0 })
            guard included.isSubset(of: candidates) else { throw GitCheckpointError(.unsupportedConfiguration) }
            var clear = [String]()
            for path in part {
                var node = stat()
                let present = lstat(c.workspace.path + "/" + path, &node) == 0
                if !present, errno != ENOENT && errno != ENOTDIR { throw GitCheckpointError(.ownershipLost) }
                if included.contains(prefix + path) || present { clear.append(path) }
            }
            if !clear.isEmpty { _ = try await output(["update-index", "--no-skip-worktree", "--"] + clear, c, deadline: deadline, index: index, staging: staging) }
        }
    }
    private func inspect(_ plan: GitCheckpointPlan, _ c: Context, deadline: ContinuousClock.Instant) async throws -> GitCheckpointInspection {
        try validate(plan, c); try await validateMapping(c, deadline: deadline)
        let ref = try await reference(plan, c, deadline: deadline)
        guard try c.common.exists(CheckpointFiles.metadataName(plan.id)) else { return ref == nil ? .missing : .incomplete }
        let metadata = try GitWorktreeDirectory(child: CheckpointFiles.metadataName(plan.id), parent: c.common)
        guard let bytes = try metadata.read("plan.json"), let recorded = try? JSONDecoder().decode(GitCheckpointPlan.self, from: bytes), recorded == plan else { throw GitCheckpointError(.metadataInvalid) }
        guard let complete = try metadata.read("complete.json") else { return .incomplete }
        guard let receipt = try? JSONDecoder().decode(GitCheckpointReceipt.self, from: complete), receipt.plan == plan else { throw GitCheckpointError(.metadataInvalid) }
        guard let ref else { return .missing }
        guard ref == receipt.commit else { throw GitCheckpointError(.metadataInvalid) }
        let commitType = try await run(["cat-file", "-t", receipt.commit], c, deadline: deadline, maximum: 128)
        guard commitType.status == 0 else { return .missing }
        guard try CheckpointFiles.line(commitType.output) == "commit" else { throw GitCheckpointError(.metadataInvalid) }
        let object = try await run(["cat-file", "-p", receipt.commit], c, deadline: deadline, maximum: 65_536)
        guard object.status == 0, let text = String(data: object.output, encoding: .utf8) else { return .missing }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == Substring("tree " + receipt.tree),
              lines.filter({ $0.hasPrefix("parent ") }).map(String.init) == (plan.headCommit.map { ["parent " + $0] } ?? []),
              text.hasSuffix("\n\nCoincide checkpoint " + plan.id.uuidString.lowercased() + "\n") else { throw GitCheckpointError(.metadataInvalid) }
        let tree = try await run(["cat-file", "-t", receipt.tree], c, deadline: deadline, maximum: 128)
        guard tree.status == 0, try CheckpointFiles.line(tree.output) == "tree" else { return .missing }
        try await validateMapping(c, deadline: deadline)
        guard let finalReference = try await reference(plan, c, deadline: deadline) else { return .missing }
        guard finalReference == receipt.commit, try metadata.read("plan.json") == bytes, try metadata.read("complete.json") == complete else { throw GitCheckpointError(.metadataInvalid) }
        try validate(plan, c); try metadata.validate(); return .ready(receipt)
    }
}
