import Foundation

public struct ChangedFile: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Codable {
        case added
        case modified
        case deleted
        case renamed
        case untracked
    }

    public var path: String
    public var oldPath: String?
    public var status: Status
    public var additions: Int
    public var deletions: Int

    public nonisolated init(path: String, oldPath: String? = nil, status: Status, additions: Int = 0, deletions: Int = 0) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

/// The working tree snapshots taken around one turn.
public struct TurnCheckpoint: Sendable, Hashable, Codable {
    public var userItemID: UUID
    /// Folder the snapshots cover: the thread's worktree or project folder.
    public var cwd: String
    /// Snapshot commit taken before the turn ran.
    public var before: String?
    public var beforeAt: Date?
    /// Snapshot commit taken when the turn ended.
    public var after: String?
    public var afterAt: Date?
    /// What the turn changed, once both snapshots exist.
    public var files: [ChangedFile]

    public nonisolated init(
        userItemID: UUID, cwd: String, before: String? = nil, beforeAt: Date? = nil, after: String? = nil,
        afterAt: Date? = nil, files: [ChangedFile] = []
    ) {
        self.userItemID = userItemID
        self.cwd = cwd
        self.before = before
        self.beforeAt = beforeAt
        self.after = after
        self.afterAt = afterAt
        self.files = files
    }

    public nonisolated var isComplete: Bool { before != nil && after != nil }
}

public enum CheckpointError: LocalizedError, Sendable {
    case unavailable
    case workspaceMissing
    case sharedWorkspace

    public nonisolated var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "There is no checkpoint for this turn.")
        case .workspaceMissing: String(localized: "The folder this turn ran in no longer exists.")
        case .sharedWorkspace:
            String(
                localized:
                    "Another thread has worked in this folder since this turn, so restoring files would undo its changes too. Rewind the conversation without restoring files instead."
            )
        }
    }
}

/// Snapshots the working tree around each turn so a turn's changes can be shown and reverted.
///
/// Mirrors T3 Code: each snapshot is a commit built in a temporary index (so the user's index,
/// branches and stash are never touched) with HEAD as its parent, kept alive by a hidden ref
/// under `refs/coincide/checkpoints/<thread>/<turn>/`.
@MainActor
public final class CheckpointService {
    /// Uses `AppStore.shared`, connected on first need so merely referencing the service has no side effects.
    public static let shared = CheckpointService(
        directory: AppStore.defaultDirectory.appendingPathComponent("checkpoints", isDirectory: true),
        storeProvider: { AppStore.shared })

    private let directory: URL?
    private let storeProvider: (@MainActor () -> AppStore)?
    private var connectedStore: AppStore?
    private var threads: [UUID: [TurnCheckpoint]] = [:]
    private var workspaceQueues: [String: Task<Void, Never>] = [:]
    private var storeObservation: ObservationToken?
    private var pruneScheduled = false

    /// `store` is consulted for restore safety and notified when a turn's changes are ready.
    /// Checkpoint indexes are saved under `directory` (by default the store's `checkpoints` folder);
    /// with neither, they are kept in memory only.
    public convenience init(store: AppStore? = nil, directory: URL? = nil) {
        var provider: (@MainActor () -> AppStore)?
        if let store { provider = { store } }
        self.init(
            directory: directory ?? store?.directory.appendingPathComponent("checkpoints", isDirectory: true),
            storeProvider: provider)
    }

    private init(directory: URL?, storeProvider: (@MainActor () -> AppStore)?) {
        self.directory = directory
        self.storeProvider = storeProvider
    }

    /// The store, observed from the first time it is needed.
    private func store() -> AppStore? {
        if let connectedStore { return connectedStore }
        guard let store = storeProvider?() else { return nil }
        connectedStore = store
        storeObservation = store.observe { [weak self] change in
            if change == .threadList { self?.schedulePrune() }
        }
        schedulePrune()
        return store
    }

    // MARK: Capture

    /// Records the working tree before a turn starts.
    public func captureBeforeTurn(threadID: UUID, userItemID: UUID, cwd: URL) async {
        let ref = Self.ref(threadID: threadID, userItemID: userItemID, phase: "before")
        guard let commit = try? await serialized(cwd, { try await CheckpointGit.capture(cwd: cwd, ref: ref) }) else {
            return
        }
        update(threadID) { turns in
            let checkpoint = TurnCheckpoint(userItemID: userItemID, cwd: cwd.path, before: commit, beforeAt: Date())
            if let index = turns.firstIndex(where: { $0.userItemID == userItemID }) {
                turns[index] = checkpoint
            } else {
                turns.append(checkpoint)
            }
        }
        await forgetTurnsMissingFromTranscript(threadID, keeping: userItemID)
    }

    /// Records the working tree after a turn ends and works out what the turn changed.
    public func captureAfterTurn(threadID: UUID, userItemID: UUID, cwd: URL) async {
        guard let checkpoint = checkpoint(threadID: threadID, userItemID: userItemID), let before = checkpoint.before
        else { return }
        let workspace = URL(fileURLWithPath: checkpoint.cwd)
        let ref = Self.ref(threadID: threadID, userItemID: userItemID, phase: "after")
        struct Captured: Sendable {
            var commit: String
            var files: [ChangedFile]
        }
        let captured = try? await serialized(workspace) {
            let commit = try await CheckpointGit.capture(cwd: workspace, ref: ref)
            let files = await CheckpointGit.changedFiles(cwd: workspace, from: before, to: commit)
            return Captured(commit: commit, files: files)
        }
        guard let captured else { return }
        update(threadID) { turns in
            guard let index = turns.firstIndex(where: { $0.userItemID == userItemID }) else { return }
            turns[index].after = captured.commit
            turns[index].afterAt = Date()
            turns[index].files = captured.files
        }
        store()?.notify(.runState(threadID))
    }

    // MARK: Queries

    /// Every turn of the thread that has a checkpoint, oldest first. Turns cut from the transcript
    /// (edit and resend, rewind) are left out.
    public func checkpoints(threadID: UUID) -> [TurnCheckpoint] {
        let all = turns(threadID)
        guard let thread = store()?.thread(threadID) else { return all }
        let userItems = Set(thread.items.lazy.filter { $0.kind == .user }.map(\.id))
        return all.filter { userItems.contains($0.userItemID) }
    }

    public func checkpoint(threadID: UUID, userItemID: UUID) -> TurnCheckpoint? {
        turns(threadID).first { $0.userItemID == userItemID }
    }

    /// Files the turn changed, once both snapshots exist.
    public func changedFiles(threadID: UUID, userItemID: UUID) -> [ChangedFile] {
        checkpoint(threadID: threadID, userItemID: userItemID)?.files ?? []
    }

    /// Unified diff of the turn's changes.
    public func turnDiff(threadID: UUID, userItemID: UUID) async -> String? {
        await turnDiff(threadID: threadID, userItemID: userItemID, ignoreWhitespace: false)
    }

    /// Unified diff of the turn's changes. While the turn is still running, its changes so far.
    public func turnDiff(threadID: UUID, userItemID: UUID, ignoreWhitespace: Bool) async -> String? {
        guard let checkpoint = checkpoint(threadID: threadID, userItemID: userItemID), let before = checkpoint.before
        else { return nil }
        let cwd = URL(fileURLWithPath: checkpoint.cwd)
        // A finished turn's diff covers only the files it wrote, leaving out what a pull brought in.
        var paths = checkpoint.isComplete ? checkpoint.files.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) } : nil
        if paths?.isEmpty == true { return "" }
        if (paths?.count ?? 0) > 2_000 { paths = nil }
        let target: String
        if let after = checkpoint.after {
            target = after
        } else {
            guard let tree = try? await serialized(cwd, { try await CheckpointGit.capture(cwd: cwd, ref: nil) })
            else { return nil }
            target = tree
        }
        return try? await CheckpointGit.diff(
            cwd: cwd, from: before, to: target, numstat: false, ignoreWhitespace: ignoreWhitespace, paths: paths)
    }

    /// Whether the working tree can be restored to how it was before the turn.
    public func canRestore(threadID: UUID, userItemID: UUID) -> Bool {
        guard let checkpoint = checkpoint(threadID: threadID, userItemID: userItemID), checkpoint.before != nil,
            FileManager.default.fileExists(atPath: checkpoint.cwd)
        else { return false }
        return isRestoreIsolated(threadID: threadID, cwd: checkpoint.cwd, since: checkpoint.beforeAt ?? .distantPast)
    }

    // MARK: Restore

    /// Restores the working tree to how it was before the turn started. Checkpoints of this and
    /// later turns are discarded, since the history they describe no longer exists.
    public func restore(threadID: UUID, toBefore userItemID: UUID) async throws {
        guard let checkpoint = checkpoint(threadID: threadID, userItemID: userItemID), let before = checkpoint.before
        else { throw CheckpointError.unavailable }
        guard FileManager.default.fileExists(atPath: checkpoint.cwd) else { throw CheckpointError.workspaceMissing }
        guard isRestoreIsolated(threadID: threadID, cwd: checkpoint.cwd, since: checkpoint.beforeAt ?? .distantPast)
        else { throw CheckpointError.sharedWorkspace }
        let cwd = URL(fileURLWithPath: checkpoint.cwd)
        try await serialized(cwd) { try await CheckpointGit.restore(cwd: cwd, commit: before) }

        let all = turns(threadID)
        if let index = all.firstIndex(where: { $0.userItemID == userItemID }) {
            let stale = Array(all[index...])
            update(threadID) { $0.removeSubrange(index...) }
            await deleteRefs(threadID: threadID, of: stale)
        }
        NotificationCenter.default.post(
            name: GitService.repositoryDidChangeNotification, object: nil, userInfo: ["path": cwd.standardizedFileURL.path])
        store()?.notify(.runState(threadID))
    }

    /// Restoring rewrites the whole folder, so it is refused when another thread has worked in the
    /// same folder (or one inside or around it) since the snapshot was taken.
    private func isRestoreIsolated(threadID: UUID, cwd: String, since: Date) -> Bool {
        guard let store = store() else { return true }
        let target = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        for other in store.threads.values where other.id != threadID && other.updatedAt > since {
            guard let folder = store.workingDirectory(for: other.id)?.resolvingSymlinksInPath().standardizedFileURL.path
            else { continue }
            if Self.contains(target, folder) || Self.contains(folder, target) { return false }
        }
        return true
    }

    private static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    // MARK: Cleanup

    /// Removes a thread's checkpoints and their refs.
    public func deleteCheckpoints(threadID: UUID) async {
        let stale = turns(threadID)
        threads[threadID] = nil
        if let file = fileURL(threadID) { try? FileManager.default.removeItem(at: file) }
        await deleteRefs(threadID: threadID, of: stale)
    }

    private func deleteRefs(threadID: UUID, of checkpoints: [TurnCheckpoint]) async {
        for (cwd, group) in Dictionary(grouping: checkpoints, by: \.cwd) {
            let refs = group.flatMap { checkpoint in
                ["before", "after"].map { Self.ref(threadID: threadID, userItemID: checkpoint.userItemID, phase: $0) }
            }
            await CheckpointGit.deleteRefs(cwd: URL(fileURLWithPath: cwd), refs: refs)
        }
    }

    private func schedulePrune() {
        guard !pruneScheduled else { return }
        pruneScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pruneScheduled = false
                Task { await self.pruneDeletedThreads() }
            }
        }
    }

    private func pruneDeletedThreads() async {
        guard let store = store() else { return }
        var known = Set(threads.keys)
        if let directory, let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for file in files where file.hasSuffix(".json") {
                if let id = UUID(uuidString: String(file.dropLast(5))) { known.insert(id) }
            }
        }
        for threadID in known where store.thread(threadID) == nil {
            await deleteCheckpoints(threadID: threadID)
        }
    }

    /// Drops checkpoints of turns cut from the transcript. This waits for the next turn rather than
    /// reacting to the cut itself, so a rewind can still restore files after truncating.
    private func forgetTurnsMissingFromTranscript(_ threadID: UUID, keeping current: UUID) async {
        guard let thread = store()?.thread(threadID) else { return }
        let existing = Set(thread.items.lazy.filter { $0.kind == .user }.map(\.id))
        let stale = turns(threadID).filter { $0.userItemID != current && !existing.contains($0.userItemID) }
        guard !stale.isEmpty else { return }
        let staleIDs = Set(stale.map(\.userItemID))
        update(threadID) { $0.removeAll { staleIDs.contains($0.userItemID) } }
        await deleteRefs(threadID: threadID, of: stale)
    }

    // MARK: Storage

    nonisolated static func ref(threadID: UUID, userItemID: UUID, phase: String) -> String {
        "refs/coincide/checkpoints/\(threadID.uuidString.lowercased())/\(userItemID.uuidString.lowercased())/\(phase)"
    }

    private func turns(_ threadID: UUID) -> [TurnCheckpoint] {
        if let cached = threads[threadID] { return cached }
        var loaded: [TurnCheckpoint] = []
        if let file = fileURL(threadID), let data = try? Data(contentsOf: file),
            let decoded = try? Self.decoder.decode([TurnCheckpoint].self, from: data)
        {
            loaded = decoded
        }
        threads[threadID] = loaded
        return loaded
    }

    private func update(_ threadID: UUID, _ mutate: (inout [TurnCheckpoint]) -> Void) {
        var value = turns(threadID)
        mutate(&value)
        threads[threadID] = value
        guard let file = fileURL(threadID) else { return }
        do {
            if value.isEmpty {
                try? FileManager.default.removeItem(at: file)
                return
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(value).write(to: file, options: .atomic)
        } catch {
            NSLog("Coincide: failed to save checkpoints for \(threadID): \(error)")
        }
    }

    private func fileURL(_ threadID: UUID) -> URL? {
        directory?.appendingPathComponent("\(threadID.uuidString).json")
    }

    /// Runs git work for one folder at a time, in call order.
    private func serialized<T: Sendable>(_ cwd: URL, _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let key = cwd.standardizedFileURL.path
        let previous = workspaceQueues[key]
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await body()
        }
        let tail = Task { @MainActor in _ = try? await task.value }
        workspaceQueues[key] = tail
        defer { if workspaceQueues[key] == tail { workspaceQueues[key] = nil } }
        return try await task.value
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The git plumbing behind checkpoints, ported from T3 Code's `GitVcsDriver.checkpoints`.
enum CheckpointGit {
    private static let author = [
        "GIT_AUTHOR_NAME": "Coincide", "GIT_AUTHOR_EMAIL": "coincide@users.noreply.github.com",
        "GIT_COMMITTER_NAME": "Coincide", "GIT_COMMITTER_EMAIL": "coincide@users.noreply.github.com",
    ]
    /// A scratch split index could expire shared index files the real index still uses.
    private static let indexConfig = [
        "-c", "core.fsmonitor=false", "-c", "sparse.expectFilesOutsideOfPatterns=false", "-c", "core.splitIndex=false",
        "-c", "splitIndex.sharedIndexExpire=never",
    ]
    private static let fullFsync = "core.fsyncMethod=fsync"
    private static let batchFsync = "core.fsyncMethod=batch"
    private static let writeoutOnlyFsync = "core.fsyncMethod=writeout-only"
    /// Flush objects and refs before publishing them, so a crash cannot leave empty refs.
    /// `fsync` is set first because git versions without `batch` ignore it.
    private static let durableWrite = ["-c", "core.fsync=objects,reference", "-c", fullFsync, "-c", batchFsync]

    /// Runs a checkpoint step. Lock races are retried twice; network volumes that reject
    /// F_FULLFSYNC are retried with writeout-only syncing.
    private static func run(
        _ arguments: [String], in cwd: URL, environment: [String: String] = [:], input: String? = nil
    ) async -> ProcessRunner.Result {
        var arguments = arguments
        var result = await GitCLI.git(arguments, in: cwd, environment: environment, input: input, timeout: 300)
        var retries = 0
        while !result.succeeded {
            if arguments.contains(fullFsync) || arguments.contains(batchFsync), canRetryFullFsync(result.stderr) {
                arguments = arguments.map { $0 == fullFsync || $0 == batchFsync ? writeoutOnlyFsync : $0 }
            } else if retries < 2, isTransient(result.stderr) {
                retries += 1
                try? await Task.sleep(for: .milliseconds(75))
            } else {
                break
            }
            result = await GitCLI.git(arguments, in: cwd, environment: environment, input: input, timeout: 300)
        }
        return result
    }

    private static func isTransient(_ stderr: String) -> Bool {
        stderr.range(of: #"unable to create [^\n]*\.lock['"]?: file exists"#, options: [.regularExpression, .caseInsensitive])
            != nil
            || stderr.range(
                of: #"(?:unable to stat|lstat\(|error: open\()[^\n]+: no such file or directory"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func canRetryFullFsync(_ stderr: String) -> Bool {
        stderr.range(of: #"fsync error on [^\r\n]+: operation not supported"#, options: [.regularExpression, .caseInsensitive])
            != nil
            || stderr.range(of: #"cannot update ref [^\r\n]+: couldn't write '[^\r\n]+\.lock'"#, options: .regularExpression)
                != nil
    }

    @discardableResult
    private static func checked(
        _ arguments: [String], in cwd: URL, environment: [String: String] = [:], input: String? = nil
    ) async throws -> String {
        let result = await run(arguments, in: cwd, environment: environment, input: input)
        guard result.succeeded else { throw GitError.failed(String(localized: "Could not save a checkpoint."), result) }
        return result.stdout
    }

    /// Snapshots the folder's working tree (tracked and untracked, minus ignored files) into a
    /// commit pointed to by `ref`. With no ref, returns just the tree without recording anything.
    @concurrent static func capture(cwd: URL, ref: String?) async throws -> String {
        // Git prints the common dir relative to the physical cwd, which can differ from a symlink.
        var commonDir = try await checked(["rev-parse", "--git-common-dir"], in: cwd)
            .trimmingCharacters(in: .newlines)
        if !commonDir.hasPrefix("/") {
            commonDir = cwd.resolvingSymlinksInPath().appendingPathComponent(commonDir).standardizedFileURL.path
        }
        let index = URL(fileURLWithPath: commonDir).appendingPathComponent("coincide-checkpoint-index-\(UUID().uuidString)")
        let lock = URL(fileURLWithPath: index.path + ".lock")
        let environment = author.merging(["GIT_INDEX_FILE": index.path]) { $1 }
        defer {
            try? FileManager.default.removeItem(at: index)
            try? FileManager.default.removeItem(at: lock)
        }

        let headExists = await GitCLI.git(["rev-parse", "--verify", "HEAD"], in: cwd).succeeded
        var sparse = await GitCLI.git(["config", "--bool", "core.sparseCheckout"], in: cwd).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        if sparse {
            let help = await GitCLI.git(["add", "-h"], in: cwd)
            sparse = (help.stdout + help.stderr).range(of: #"--(\[no-\])?sparse\b"#, options: .regularExpression) != nil
        }
        if headExists, !(await seedIndexFromRealIndex(cwd: cwd, index: index, environment: environment, sparse: sparse))
        {
            if sparse {
                let cone = await GitCLI.git(["config", "--bool", "core.sparseCheckoutCone"], in: cwd).stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Rebuilding a non-cone sparse index loses its exclusions and would record false deletions.
                guard cone == "true" else {
                    throw GitError(
                        String(localized: "Could not save a checkpoint."),
                        detail: "Cannot rebuild a checkpoint index for non-cone sparse checkout.")
                }
            }
            try? FileManager.default.removeItem(at: index)
            try? FileManager.default.removeItem(at: lock)
            try await checked(
                indexConfig + (sparse ? ["-c", "index.sparse=true", "read-tree", "--reset", "HEAD"] : ["read-tree", "HEAD"]),
                in: cwd, environment: environment)
        }

        let workspaceIgnored = await isIgnored(cwd)
        if workspaceIgnored {
            // HEAD lacks staged-only paths. Seed this folder's staged additions from the real index.
            let additions = await GitCLI.git(
                [
                    "-c", "core.quotePath=true", "diff", "--cached", "--raw", "--no-abbrev", "--no-renames",
                    "--no-relative", "--ignore-submodules=none", "--no-color", "--no-ext-diff", "--no-textconv",
                    "--ita-visible-in-index", "--diff-filter=A", "--", ".",
                ], in: cwd)
            if !additions.stdout.isEmpty {
                let info = additions.stdout.replacingOccurrences(
                    of: #"(?m)^:000000 ([0-7]{6}) 0+ ([0-9a-f]+) A\t"#, with: "$1 $2\t", options: .regularExpression)
                try await checked(
                    indexConfig + ["-c", "index.sparse=false", "update-index", "--index-info"], in: cwd,
                    environment: environment, input: info)
            }
            let tracked = await GitCLI.git(indexConfig + ["ls-files", "--cached", "-z", "--", "."], in: cwd, environment: environment)
            guard !tracked.stdout.isEmpty else {
                throw GitError(
                    String(localized: "Could not save a checkpoint."),
                    detail: "The workspace directory is ignored by its Git repository.")
            }
        }

        func stage(_ exclusions: [String]) async -> ProcessRunner.Result {
            // `add -A` rejects ignored directories even when they contain tracked files.
            await run(
                indexConfig + durableWrite + ["add"] + (sparse ? ["--sparse"] : [])
                    + [workspaceIgnored ? "-u" : "-A", "--", "."] + exclusions, in: cwd, environment: environment)
        }
        var staged = await stage([])
        if !staged.succeeded {
            // Git cannot stage nested repositories without a commit; look for them only after staging fails.
            let untracked = await GitCLI.git(
                ["ls-files", "--others", "--exclude-standard", "-z", "--", "."], in: cwd, environment: environment)
            let candidates = GitParse.nulFields(untracked.stdout).filter { $0.hasSuffix("/") }
            var exclusions: [String] = []
            if candidates.count <= 1_000 {
                for entry in candidates {
                    let nested = cwd.appendingPathComponent(entry, isDirectory: true)
                    guard FileManager.default.fileExists(atPath: nested.appendingPathComponent(".git").path) else { continue }
                    if !(await GitCLI.git(["rev-parse", "--verify", "HEAD"], in: nested).succeeded) {
                        exclusions.append(":(exclude,literal)\(entry)")
                    }
                }
            }
            if !exclusions.isEmpty { staged = await stage(exclusions) }
            guard staged.succeeded else { throw GitError.failed(String(localized: "Could not save a checkpoint."), staged) }
        }

        let tree = try await checked(indexConfig + durableWrite + ["write-tree"], in: cwd, environment: environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tree.isEmpty else {
            throw GitError(String(localized: "Could not save a checkpoint."), detail: "git write-tree returned no tree.")
        }
        guard let ref else { return tree }
        // HEAD is the parent so a later diff can tell how HEAD moved between checkpoints. Snapshots
        // never leave the machine, so they are not signed even when the user signs commits.
        let commit = try await checked(
            durableWrite + ["commit-tree", "--no-gpg-sign", tree] + (headExists ? ["-p", "HEAD"] : [])
                + ["-m", "coincide checkpoint ref=\(ref)"],
            in: cwd, environment: environment
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commit.isEmpty else {
            throw GitError(String(localized: "Could not save a checkpoint."), detail: "git commit-tree returned no commit.")
        }
        try await checked(durableWrite + ["update-ref", ref, commit], in: cwd)
        return commit
    }

    /// Starts the scratch index from a copy of the real one, so `git add` can reuse its stat
    /// cache instead of hashing every file. Returns false when the copy cannot be used.
    private static func seedIndexFromRealIndex(cwd: URL, index: URL, environment: [String: String], sparse: Bool) async
        -> Bool
    {
        let realIndex = await GitCLI.git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: cwd)
        let path = realIndex.stdout.trimmingCharacters(in: .newlines)
        guard realIndex.succeeded, !path.isEmpty,
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return false }
        // Stay below the source timestamp, preserving git's racy-clean check.
        let seconds = floor(modified.timeIntervalSince1970 - 0.001)
        guard seconds > 0, (try? FileManager.default.copyItem(atPath: path, toPath: index.path)) != nil else { return false }
        guard await run(indexConfig + ["read-tree", "--reset", "HEAD"], in: cwd, environment: environment).succeeded else {
            return false
        }
        // read-tree can rewrite the index, so restore its racy timestamp afterwards.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: index.path)

        // Assume-unchanged (lowercase tags) and stray skip-worktree entries need a fresh index.
        let listing = await GitCLI.git(
            indexConfig + ["ls-files", "--full-name", "--sparse", "-v", "-z"], in: cwd, environment: environment, timeout: 120)
        guard listing.succeeded else { return false }
        var skipped: [String] = []
        for record in listing.stdout.split(separator: "\0") {
            guard let tag = record.first else { continue }
            if tag.isLowercase, tag.isLetter { return false }
            if tag == "S" {
                guard sparse else { return false }
                if !record.hasSuffix("/") { skipped.append(String(record.dropFirst(2))) }
            }
        }
        if !skipped.isEmpty {
            let selected = await GitCLI.git(
                indexConfig + ["sparse-checkout", "check-rules", "-z"], in: cwd, environment: environment,
                input: skipped.joined(separator: "\0") + "\0")
            if !selected.stdout.isEmpty { return false }
        }
        return true
    }

    /// Whether the folder itself is ignored by its repository (a tracked folder inside an ignored one).
    private static func isIgnored(_ cwd: URL) async -> Bool {
        let prefix = await GitCLI.git(["rev-parse", "--show-prefix"], in: cwd).stdout.trimmingCharacters(in: .newlines)
        guard !prefix.isEmpty else { return false }
        let result = await GitCLI.git(["check-ignore", "--no-index", "-z", "--stdin"], in: cwd, input: ".\0")
        return result.status == 0 && GitParse.nulFields(result.stdout).contains(".")
    }

    /// Restores the folder to `commit`: tracked files are reset, files the snapshot did not have
    /// are removed (ignored files stay), and the index is reset to HEAD for the folder.
    @concurrent static func restore(cwd: URL, commit: String) async throws {
        let failure = String(localized: "Could not restore the checkpoint.")
        let tracked = await GitCLI.git(["ls-files", "--cached", "--with-tree=\(commit)", "-z", "--", "."], in: cwd)
        guard tracked.succeeded else { throw GitError.failed(failure, tracked) }
        // With an empty index and snapshot, `git restore` has nothing for its pathspec to match.
        if !tracked.stdout.isEmpty {
            let restored = await run(["restore", "--source", commit, "--worktree", "--staged", "--", "."], in: cwd)
            guard restored.succeeded else { throw GitError.failed(failure, restored) }
        }
        // Restoring away the last tracked file can remove a nested folder.
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let cleaned = await GitCLI.git(["clean", "-fd", "--", "."], in: cwd, timeout: 300)
        if !cleaned.succeeded {
            // git can remove every child, then fail trying to remove './' itself.
            let emptied =
                cleaned.status == 1
                && cleaned.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    .range(of: #"^warning: failed to remove \./: [^\n]+$"#, options: .regularExpression) != nil
                && ((try? FileManager.default.contentsOfDirectory(atPath: cwd.path))?.isEmpty ?? false)
            guard emptied else { throw GitError.failed(failure, cleaned) }
        }
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        if await GitCLI.git(["rev-parse", "--verify", "HEAD"], in: cwd).succeeded {
            let reset = await run(["reset", "--quiet", "--", "."], in: cwd)
            guard reset.succeeded else { throw GitError.failed(failure, reset) }
        }
    }

    /// Patch or `-z` numstat between two snapshots (or snapshot trees), limited to this folder
    /// and optionally to `paths` (repository-relative).
    @concurrent static func diff(
        cwd: URL, from: String, to: String, numstat: Bool, ignoreWhitespace: Bool, paths: [String]? = nil
    ) async throws -> String {
        var arguments = GitOps.diffArguments(ignoreWhitespace: ignoreWhitespace, minimal: false)
        arguments += numstat ? ["--numstat", "-z"] : ["--patch"]
        arguments += [from, to, "--"]
        if let paths {
            arguments += paths.map { ":(top,literal)\($0)" }
        } else {
            arguments.append(".")
        }
        let result = await GitCLI.git(arguments, in: cwd, timeout: 120)
        guard result.succeeded else { throw GitError.failed(String(localized: "Could not read the turn's changes."), result) }
        return result.stdout
    }

    /// What changed between two snapshots, leaving out files that only came from git itself
    /// (a pull, merge or rebase that moved HEAD during the turn).
    @concurrent static func changedFiles(cwd: URL, from: String, to: String) async -> [ChangedFile] {
        async let numstatOutput = try? diff(cwd: cwd, from: from, to: to, numstat: true, ignoreWhitespace: false)
        async let statusOutput = GitCLI.git(
            ["diff", "--name-status", "-z", "--find-renames", "--no-ext-diff", from, to, "--", "."], in: cwd)
        async let authored = authoredPaths(cwd: cwd, from: from, to: to)
        let stats = GitParse.numstat(await numstatOutput ?? "")
        var statuses: [String: ChangedFile.Status] = [:]
        let fields = GitParse.nulFields(await statusOutput.stdout)
        var index = 0
        while index < fields.count {
            let code = fields[index].first ?? "M"
            if code == "R" || code == "C", index + 2 < fields.count {
                statuses[fields[index + 2]] = code == "R" ? .renamed : .added
                index += 3
            } else if index + 1 < fields.count {
                statuses[fields[index + 1]] = code == "A" ? .added : code == "D" ? .deleted : .modified
                index += 2
            } else {
                break
            }
        }
        let authoredPaths = await authored
        return stats.compactMap { stat in
            if let authoredPaths, !authoredPaths.contains(stat.path),
                stat.oldPath.map({ !authoredPaths.contains($0) }) ?? true
            {
                return nil
            }
            return ChangedFile(
                path: stat.path, oldPath: stat.oldPath, status: statuses[stat.path] ?? .modified,
                additions: stat.additions, deletions: stat.deletions)
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Paths the turn itself could have written, or nil when HEAD did not move (then every
    /// changed path belongs to the turn).
    static func authoredPaths(cwd: URL, from: String, to: String) async -> Set<String>? {
        let heads = await GitCLI.git(["log", "--no-walk=unsorted", "--format=%P %ct", "\(from)^{commit}", "\(to)^{commit}"], in: cwd)
        guard heads.succeeded else { return nil }
        let lines = heads.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        let fromFields = lines.first?.split(separator: " ", omittingEmptySubsequences: false) ?? []
        let toFields = lines.count > 1 ? lines[1].split(separator: " ", omittingEmptySubsequences: false) : []
        let startHead = fromFields.first.map(String.init) ?? ""
        let capturedAt = fromFields.count > 1 ? String(fromFields[1]) : ""
        let endHead = toFields.first.map(String.init) ?? ""
        guard !startHead.isEmpty, !endHead.isEmpty, startHead != endHead else { return nil }

        func list(_ arguments: [String]) async -> [String]? {
            let result = await GitCLI.git(arguments + ["--name-only", "-z", "--no-renames", "--no-ext-diff"], in: cwd, timeout: 60)
            return result.succeeded ? GitParse.nulFields(result.stdout) : nil
        }
        // Remerge diffs keep conflict fixes while leaving out clean upstream changes.
        async let startChanges = list(["diff", startHead, "\(from)^{commit}"])
        async let endChanges = list(["diff", endHead, "\(to)^{commit}"])
        async let rewound = list(["log", "--format=", "--diff-merges=remerge", "\(endHead)..\(startHead)"])
        async let committed = list([
            "log", "--format=", "--diff-merges=remerge", "--since=@\(capturedAt)", "\(startHead)..\(endHead)",
        ])
        guard let a = await startChanges, let b = await endChanges, let c = await rewound, let d = await committed else {
            return nil
        }
        return Set(a + b + c + d)
    }

    static func deleteRefs(cwd: URL, refs: [String]) async {
        guard FileManager.default.fileExists(atPath: cwd.path), !refs.isEmpty else { return }
        let input = refs.map { "delete \($0)\n" }.joined()
        _ = await GitCLI.git(["update-ref", "--stdin"], in: cwd, input: input)
    }
}
