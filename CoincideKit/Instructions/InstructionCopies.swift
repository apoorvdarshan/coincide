import CryptoKit
import Foundation

/// A copy of the master in iCloud Drive, so Coincide on the user's other Macs gets the same instructions. The master
/// itself stays where it is.
public struct InstructionICloudCopy: Codable, Hashable, Sendable {
    /// The copy: `Coincide/Instructions/<name>.md` in iCloud Drive (`InstructionCloud`).
    public var path: String
    /// The text the master and the copy last agreed on, as `InstructionCopySync.digest`. Nil until they first do.
    public var agreed: String?

    public nonisolated init(path: String, agreed: String? = nil) {
        self.path = path
        self.agreed = agreed
    }

    public nonisolated var url: URL { URL(fileURLWithPath: path) }
}

/// A copy of the master in a Git repository's work tree, committed whenever it changes. The master itself stays
/// where it is.
public struct InstructionGitCopy: Codable, Hashable, Sendable {
    /// The repository's work tree.
    public var repository: String
    /// The copy, in the work tree.
    public var path: String
    /// Pushes each commit right away; otherwise commits wait for Sync Now.
    public var pushesAutomatically: Bool
    /// The remote as "owner/name" when it is on GitHub.
    public var gitHubName: String?
    /// The text the master and the copy last agreed on, as `InstructionCopySync.digest`. Nil until they first do.
    public var agreed: String?

    public nonisolated init(repository: String, path: String, pushesAutomatically: Bool = true, gitHubName: String? = nil, agreed: String? = nil) {
        self.repository = repository
        self.path = path
        self.pushesAutomatically = pushesAutomatically
        self.gitHubName = gitHubName
        self.agreed = agreed
    }

    public nonisolated var url: URL { URL(fileURLWithPath: path) }
    public nonisolated var repositoryURL: URL { URL(fileURLWithPath: repository) }
}

/// What syncing one copy did.
public enum InstructionCopyOutcome: Equatable, Sendable {
    case inStep
    /// The master changed here, and the copy now has its text.
    case updatedCopy
    /// The copy changed on another Mac or in the repository, and the master now has its text.
    case updatedMaster
    /// Both changed since they last agreed, or they never agreed: nothing was overwritten, and the user picks one.
    case conflict
    /// iCloud Drive is still bringing the copy down to this Mac.
    case downloading
}

public struct InstructionCopyResult: Equatable, Sendable {
    public var outcome: InstructionCopyOutcome
    /// The text the master and the copy agree on now, as a digest; unchanged when they don't.
    public var agreed: String?
}

/// Which text wins a conflict.
public enum InstructionCopySide: Sendable {
    case master
    case copy
}

/// Keeps copies of a master in step with it. Each copy remembers the text both last had, so a change on either side
/// is carried to the other, and a change on both is left for the user. Nothing is overwritten without that: a missing
/// master is brought back from its copy, never the other way round.
public enum InstructionCopySync {
    public nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What to do, given the master's and the copy's text (nil when missing) and the digest they last agreed on.
    public enum Step: Equatable, Sendable {
        case none
        case updateCopy
        case updateMaster
        case conflict
    }

    public nonisolated static func step(master: String?, copy: String?, agreed: String?) -> Step {
        guard let master else { return copy == nil ? .none : .updateMaster }
        guard let copy else { return .updateCopy }
        if copy == master { return .none }
        if digest(copy) == agreed { return .updateCopy }
        if digest(master) == agreed { return .updateMaster }
        return .conflict
    }

    /// The text of `url`, or nil when nothing is there.
    public nonisolated static func text(of url: URL) throws -> String? {
        let snapshot = try InstructionFileStore.read(url)
        return snapshot.fingerprint == nil ? nil : snapshot.text
    }

    nonisolated static func write(_ text: String, to url: URL) throws {
        let folder = InstructionPaths.resolve(url).url.deletingLastPathComponent()
        if !InstructionPaths.isDirectory(folder) { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try InstructionFileStore.write(text, to: url)
    }

    /// Carries a change from either side to the other.
    nonisolated static func apply(master: URL, copy: URL, agreed: String?) throws -> InstructionCopyResult {
        let masterText = try text(of: master)
        let copyText = try text(of: copy)
        switch step(master: masterText, copy: copyText, agreed: agreed) {
        case .none:
            return InstructionCopyResult(outcome: .inStep, agreed: masterText.map(digest) ?? agreed)
        case .updateCopy:
            let text = masterText ?? ""
            try write(text, to: copy)
            return InstructionCopyResult(outcome: .updatedCopy, agreed: digest(text))
        case .updateMaster:
            let text = copyText ?? ""
            try write(text, to: master)
            return InstructionCopyResult(outcome: .updatedMaster, agreed: digest(text))
        case .conflict:
            return InstructionCopyResult(outcome: .conflict, agreed: agreed)
        }
    }

    /// Brings the master and its iCloud Drive copy in step.
    public nonisolated static func sync(master: URL, iCloudCopy copy: URL, agreed: String?) throws -> InstructionCopyResult {
        if InstructionCloud.state(of: copy) == .notDownloaded {
            InstructionCloud.startDownloading(copy)
            return InstructionCopyResult(outcome: .downloading, agreed: agreed)
        }
        return try apply(master: master, copy: copy, agreed: agreed)
    }

    /// Brings the master and its copy in a repository in step: commits the copy if it was left changed, pulls, carries
    /// a change from either side to the other, commits the copy when it changed, and with `push` pushes. Only the
    /// copy is ever committed; `allowedFiles` (paths in the repository) are the commits that may be pushed.
    public nonisolated static func sync(
        master: URL, gitCopy copy: InstructionGitCopy, allowedFiles: [String], push: Bool
    ) async throws -> InstructionCopyResult {
        let repository = try await InstructionGitRepository.open(copy.repositoryURL)
        if await repository.hasUncommittedChanges(copy.url), InstructionPaths.itemExists(copy.url) {
            try await repository.commit(copy.url)
        }
        try await exchange(repository, allowedFiles: allowedFiles, push: push)
        let result = try apply(master: master, copy: copy.url, agreed: copy.agreed)
        guard result.outcome != .conflict else { return result }
        if InstructionPaths.itemExists(copy.url), try await repository.commit(copy.url), push {
            try await exchange(repository, allowedFiles: allowedFiles, push: true)
        }
        return result
    }

    /// Pulls, and pushes when asked. A repository without a remote only keeps commits on this Mac.
    private nonisolated static func exchange(_ repository: InstructionGitRepository, allowedFiles: [String], push: Bool) async throws {
        do {
            _ = try await repository.sync(allowedFiles: allowedFiles, push: push)
        } catch InstructionSyncError.noRemote {
            return
        }
    }

    /// Ends a conflict by giving both the text of `side`. The text that loses is kept in a backup beside its file;
    /// a repository's history already keeps the copy's. Returns the digest both now agree on.
    @discardableResult
    public nonisolated static func resolve(master: URL, copy: URL, keeping side: InstructionCopySide, backUpCopy: Bool) throws -> String {
        let masterText = try text(of: master)
        let copyText = try text(of: copy)
        let kept = (side == .master ? masterText : copyText) ?? ""
        switch side {
        case .master:
            if backUpCopy, let copyText { try backUp(copyText, of: copy) }
            try write(kept, to: copy)
        case .copy:
            if let masterText { try backUp(masterText, of: master) }
            try write(kept, to: master)
        }
        return digest(kept)
    }

    nonisolated static func backUp(_ text: String, of url: URL) throws {
        let resolved = InstructionPaths.resolve(url).url
        let backup = InstructionPaths.backupURL(for: resolved)
        try InstructionFileStore.writeAtomically(Data(text.utf8), to: backup, name: backup.lastPathComponent)
    }
}

/// Settings from an older Coincide moved the master into iCloud Drive or a repository to sync it. This brings the
/// master back to its own place, links every agent to it again, and keeps the synced file as a copy in step with it.
public enum InstructionCopyMigration {
    public nonisolated static func needsMigration(_ config: InstructionMasterConfig) -> Bool { !config.sync.isOff }

    /// `local` is where the master goes when the settings don't say where it was; `targets` are the agents' files,
    /// found for the moved master.
    public nonisolated static func migrate(
        _ config: InstructionMasterConfig, local: URL, targets: [MasterTarget]
    ) throws -> InstructionMasterConfig {
        guard needsMigration(config) else { return config }
        let synced = config.masterURL
        let home = config.localMasterPath.map(URL.init(fileURLWithPath:)) ?? local
        try InstructionMasterMove.restore(from: synced, to: home, targets: targets)
        let agreed = InstructionCopySync.digest(try InstructionFileStore.read(home).text)
        var updated = config
        switch config.sync {
        case .off:
            break
        case .iCloud:
            updated.iCloud = InstructionICloudCopy(path: synced.path, agreed: agreed)
        case .git(let repository, let pushOnSave):
            updated.git = InstructionGitCopy(repository: repository, path: synced.path, pushesAutomatically: pushOnSave, agreed: agreed)
        }
        updated.masterPath = home.path
        updated.localMasterPath = nil
        updated.sync = .off
        return updated
    }
}
