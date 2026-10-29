import Foundation

/// Why syncing a master file failed. Each case is a sentence for the user.
public enum InstructionSyncError: LocalizedError, Equatable, Sendable {
    case iCloudUnavailable
    /// The file is in iCloud Drive but not on this Mac yet; a download was started.
    case notDownloaded(String)
    case notRepository(String)
    case noRemote
    case gitHubCLIMissing
    case gitHubSignedOut
    /// The repository has commits to push that touch more than the instruction files.
    case otherChanges([String])
    case conflict(String)
    case failed(String)

    public nonisolated var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            String(localized: "iCloud Drive isn't available. Sign in to iCloud and turn on iCloud Drive in System Settings, then try again.")
        case .notDownloaded(let name):
            String(localized: "\(name) is in iCloud Drive but not on this Mac yet. Coincide started downloading it; try again in a moment.")
        case .notRepository(let path): String(localized: "\(path) isn't a Git repository.")
        case .noRemote: String(localized: "The repository has no remote to push to or pull from.")
        case .gitHubCLIMissing: String(localized: "The GitHub CLI (gh) isn't installed. Install it with Homebrew: brew install gh")
        case .gitHubSignedOut: String(localized: "The GitHub CLI isn't signed in. Run gh auth login in Terminal, then try again.")
        case .otherChanges(let files):
            String(localized: "The repository has unpushed changes besides the instructions (\(files.joined(separator: ", "))). Coincide only pushes instruction files, so push those yourself.")
        case .conflict(let detail):
            String(localized: "The remote's copy conflicts with yours. Nothing was overwritten; resolve it in the repository. \(detail)")
        case .failed(let message): message
        }
    }
}

/// The master file's iCloud Drive home: `Coincide/Instructions/<name>.md` in the user's iCloud Drive, where Coincide on
/// the user's other Macs finds the same file.
public struct InstructionCloud: Sendable, Hashable {
    /// iCloud Drive's local folder.
    public var root: URL

    public nonisolated init(root: URL) {
        self.root = root
    }

    public nonisolated static var standard: InstructionCloud {
        InstructionCloud(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true))
    }

    /// Whether iCloud Drive is set up: its folder exists only while the user is signed in with iCloud Drive on.
    public nonisolated var isAvailable: Bool { InstructionPaths.isDirectory(root) }

    public nonisolated var folder: URL { root.appendingPathComponent("Coincide/Instructions", isDirectory: true) }

    /// The file for a master named `name` ("Global", or a project's name).
    public nonisolated func file(named name: String) -> URL {
        folder.appendingPathComponent(InstructionCloud.safeName(name) + ".md")
    }

    /// `name` without characters that don't belong in a file name.
    public nonisolated static func safeName(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return result.isEmpty ? "Instructions" : result
    }

    public enum FileState: Equatable, Sendable {
        case current
        /// In iCloud Drive but evicted from this Mac.
        case notDownloaded
        case missing
    }

    /// Whether `url` is on this Mac. An evicted file leaves a `.<name>.icloud` placeholder, or reports a download
    /// status other than current.
    public nonisolated static func state(of url: URL) -> FileState {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if !InstructionPaths.itemExists(url) {
            return InstructionPaths.itemExists(placeholder) ? .notDownloaded : .missing
        }
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
            values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus, status != .current
        {
            return .notDownloaded
        }
        return .current
    }

    /// Asks iCloud Drive to bring an evicted file down.
    public nonisolated static func startDownloading(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}

/// What moving the master to a synced place did.
public struct InstructionMoveReport: Equatable, Sendable {
    /// A copy of the local master as it was before the move.
    public var backup: URL?
    /// The synced place already had a file (from another Mac), which is now the master.
    public var adoptedExisting: Bool
}

/// Moves a master to a synced place and back, keeping every agent's link working.
public enum InstructionMasterMove {
    /// Makes `destination` the master. The local master's text is copied there unless a file is already there, in
    /// which case that file wins (it came from another Mac). Either way a backup of the local master is kept beside
    /// it; the local master becomes a link to `destination` and the targets are pointed straight at it.
    public nonisolated static func move(master: URL, to destination: URL, targets: [MasterTarget]) throws -> InstructionMoveReport {
        switch InstructionCloud.state(of: destination) {
        case .notDownloaded:
            InstructionCloud.startDownloading(destination)
            throw InstructionSyncError.notDownloaded(destination.lastPathComponent)
        case .current, .missing:
            break
        }
        let local = try InstructionFileStore.read(master)
        var adopted = false
        if InstructionPaths.isRegularFile(destination) {
            adopted = (try InstructionFileStore.read(destination).text) != local.text
        } else {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try InstructionFileStore.writeAtomically(Data(local.text.utf8), to: destination, name: destination.lastPathComponent)
        }
        var backup: URL?
        if local.fingerprint != nil {
            let url = InstructionPaths.backupURL(for: master)
            try InstructionFileStore.writeAtomically(Data(local.text.utf8), to: url, name: url.lastPathComponent)
            backup = url
        }
        if InstructionPaths.itemExists(master) {
            guard unlink(master.path) == 0 else { throw InstructionSyncError.failed(String(cString: strerror(errno))) }
        }
        try FileManager.default.createSymbolicLink(atPath: master.path, withDestinationPath: destination.path)
        InstructionMaster.relink(targets, from: master, to: destination)
        return InstructionMoveReport(backup: backup, adoptedExisting: adopted)
    }

    /// Brings the master back from `synced` to the regular file `local`, holding the synced text, and points the
    /// targets at it. The synced file stays where it is.
    public nonisolated static func restore(from synced: URL, to local: URL, targets: [MasterTarget]) throws {
        if InstructionCloud.state(of: synced) == .notDownloaded {
            InstructionCloud.startDownloading(synced)
            throw InstructionSyncError.notDownloaded(synced.lastPathComponent)
        }
        let text = try InstructionFileStore.read(synced).text
        if InstructionPaths.isSymbolicLink(local) {
            guard unlink(local.path) == 0 else { throw InstructionSyncError.failed(String(cString: strerror(errno))) }
        }
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InstructionFileStore.writeAtomically(Data(text.utf8), to: local, name: local.lastPathComponent)
        InstructionMaster.relink(targets, from: synced, to: local)
    }
}

/// A Git repository whose work tree holds master files. Coincide commits only those files, never force-pushes, and
/// refuses to push commits that touch anything else.
public struct InstructionGitRepository: Sendable, Hashable {
    public var url: URL

    public nonisolated init(url: URL) {
        self.url = url
    }

    /// What `sync` did.
    public enum SyncOutcome: Equatable, Sendable {
        case upToDate
        case pulled
        case pushed
        case pulledAndPushed
    }

    /// The repository at `url`, which must be the top of a work tree.
    public nonisolated static func open(_ url: URL) async throws -> InstructionGitRepository {
        let result = await GitCLI.git(["rev-parse", "--show-toplevel"], in: url)
        let top = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !top.isEmpty,
            InstructionPaths.canonical(URL(fileURLWithPath: top)) == InstructionPaths.canonical(url)
        else { throw InstructionSyncError.notRepository(InstructionPaths.abbreviated(url)) }
        return InstructionGitRepository(url: url)
    }

    /// The master file for `name` in the work tree.
    public nonisolated func file(named name: String) -> URL {
        url.appendingPathComponent(InstructionCloud.safeName(name) + ".md")
    }

    nonisolated func relative(_ file: URL) -> String {
        InstructionDiscovery.relative(InstructionPaths.canonical(file), to: InstructionPaths.canonical(url))
    }

    nonisolated func run(_ action: String, _ arguments: [String], timeout: TimeInterval = 60) async throws -> String {
        let result = await GitCLI.git(arguments, in: url, timeout: timeout)
        guard result.succeeded else {
            let error = GitError.failed(action, result)
            throw InstructionSyncError.failed([error.message, error.detail].compactMap(\.self).joined(separator: "\n"))
        }
        return result.stdout
    }

    /// Commits `file` alone, with `Update <name>`, when it changed. Other staged or unstaged changes in the
    /// repository are left out. Returns whether it committed.
    @discardableResult
    public nonisolated func commit(_ file: URL, message: String? = nil) async throws -> Bool {
        let path = relative(file)
        try await run(String(localized: "Couldn't add the file to Git."), ["add", "--", path])
        let staged = await GitCLI.git(["diff", "--cached", "--quiet", "--", path], in: url)
        guard staged.status == 1 else { return false }
        try await run(
            String(localized: "Couldn't commit the instructions."),
            ["commit", "--only", "-m", message ?? "Update \(file.lastPathComponent)", "--", path])
        return true
    }

    /// Files changed by local commits the remote doesn't have yet.
    nonisolated func unpushedFiles(upstream: String?) async throws -> [String] {
        let range = upstream.map { ["\($0)..HEAD"] } ?? ["HEAD", "--not", "--remotes"]
        let output = try await run(String(localized: "Couldn't read the repository's history."), ["log", "--name-only", "--format="] + range)
        return Array(Set(output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty })).sorted()
    }

    /// Pulls and pushes: fast-forwards to the remote, rebases local instruction commits onto it when both moved
    /// (stopping with `.conflict` and leaving everything as it was when they clash), and pushes local commits that
    /// only touch `allowedFiles` (paths in the repository). Never force-pushes.
    public nonisolated func sync(allowedFiles: [String]) async throws -> SyncOutcome {
        let remotes = try await run(String(localized: "Couldn't read the repository's remotes."), ["remote"])
        guard let remote = remotes.split(whereSeparator: \.isNewline).first.map(String.init) else { throw InstructionSyncError.noRemote }
        try await run(String(localized: "Couldn't fetch from the remote."), ["fetch", "--quiet", remote], timeout: 120)
        let upstreamResult = await GitCLI.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: url)
        let upstream = upstreamResult.succeeded ? upstreamResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        var pulled = false
        if let upstream {
            let counts = try await run(
                String(localized: "Couldn't compare with the remote."), ["rev-list", "--left-right", "--count", "HEAD...\(upstream)"])
            let numbers = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            let ahead = numbers.first ?? 0
            let behind = numbers.count > 1 ? numbers[1] : 0
            if behind > 0, ahead == 0 {
                try await run(String(localized: "Couldn't pull from the remote."), ["merge", "--ff-only", upstream])
                pulled = true
            } else if behind > 0 {
                let rebase = await GitCLI.git(["rebase", upstream], in: url, timeout: 60)
                if !rebase.succeeded {
                    _ = await GitCLI.git(["rebase", "--abort"], in: url)
                    let detail = rebase.stdout.split(whereSeparator: \.isNewline).filter { $0.contains("CONFLICT") }.joined(separator: "\n")
                    throw InstructionSyncError.conflict(detail)
                }
                pulled = true
            }
        }
        let unpushed = try await unpushedFiles(upstream: upstream)
        guard !unpushed.isEmpty else { return pulled ? .pulled : .upToDate }
        let others = unpushed.filter { !allowedFiles.contains($0) }
        guard others.isEmpty else { throw InstructionSyncError.otherChanges(others) }
        let push = upstream == nil ? ["push", "--set-upstream", remote, "HEAD"] : ["push", remote, "HEAD"]
        let result = await GitCLI.git(push, in: url, timeout: 120)
        guard result.succeeded else {
            if result.stderr.contains("[rejected]") || result.stderr.contains("non-fast-forward") {
                throw InstructionSyncError.conflict(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw InstructionSyncError.failed(GitError.failed(String(localized: "Couldn't push to the remote."), result).detail ?? "")
        }
        return pulled ? .pulledAndPushed : .pushed
    }

    // MARK: GitHub

    /// The default name for a new instructions repository.
    public nonisolated static let defaultGitHubName = "coincide-instructions"

    /// `gh repo create` for a new repository from `folder`. Always private.
    public nonisolated static func gitHubCreateArguments(name: String, folder: URL) -> [String] {
        ["repo", "create", name, "--private", "--source", folder.path, "--remote", "origin", "--push"]
    }

    /// Whether gh is installed and signed in.
    public nonisolated static func gitHubStatus() async -> InstructionSyncError? {
        guard let result = await GitCLI.gh(["auth", "status"], in: FileManager.default.homeDirectoryForCurrentUser, timeout: 20) else {
            return .gitHubCLIMissing
        }
        return result.succeeded ? nil : .gitHubSignedOut
    }

    /// Creates a private GitHub repository `name` from a new local repository in `folder` holding `text` as `fileName`,
    /// and pushes it. Only call this when the user asked for it.
    public nonisolated static func createOnGitHub(name: String, folder: URL, fileName: String, text: String) async throws -> InstructionGitRepository {
        if let problem = await gitHubStatus() { throw problem }
        guard !InstructionPaths.itemExists(folder) else { throw InstructionFileError.alreadyExists(InstructionPaths.abbreviated(folder)) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let repository = InstructionGitRepository(url: folder)
        try await repository.run(String(localized: "Couldn't create the repository."), ["init", "--quiet"])
        let file = folder.appendingPathComponent(fileName)
        try InstructionFileStore.writeAtomically(Data(text.utf8), to: file, name: fileName)
        try await repository.commit(file, message: "Add \(fileName)")
        guard let result = await GitCLI.gh(gitHubCreateArguments(name: name, folder: folder), in: folder, timeout: 120) else {
            throw InstructionSyncError.gitHubCLIMissing
        }
        guard result.succeeded else { throw InstructionSyncError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return repository
    }
}
