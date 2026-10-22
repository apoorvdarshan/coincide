import Darwin
import Foundation

public enum GitCheckpointScratchResult: String, Codable, Sendable, Equatable {
    case removed, alreadyRemoved, preserved
}

extension GitCheckpointService {
    /// Releases only the sealed temporary index and private Git administration files.
    /// Checkpoint objects, refs, plans and completion receipts are retained. Unknown,
    /// replaced or modified scratch is preserved rather than recursively removed.
    public func finalizeScratch(_ receipt: GitCheckpointReceipt) async throws -> GitCheckpointScratchResult {
        try receipt.validate(); try Task.checkCancellation()
        return try await GitOperationGate.shared.perform(key: receipt.plan.commonDirectoryPath) {
            do {
                guard receipt.scratchManifestDigest != nil,
                      try await inspect(receipt.plan) == .ready(receipt) else { return .preserved }
                return try CheckpointScratch.remove(receipt)
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); return .preserved }
        }
    }
}

/// This manifest is hashed into the durable receipt. Changing the manifest cannot
/// grant ownership of a changed file while retaining the caller's original receipt.
enum CheckpointScratch {
    static let manifestName = "scratch.json"
    static let startedName = "scratch-started.json"
    static let completedName = "scratch-complete.json"
    static let rootFiles: Set<String> = ["HEAD", "config", "global-attributes", "global-exclude"]
    static let infoFiles: Set<String> = ["attributes", "exclude", "sparse-checkout"]
    static let directoryNames: Set<String> = ["git", "git/info", "git/objects", "git/refs"]

    struct Manifest: Codable, Sendable {
        let version: Int
        let planID: UUID
        let commit: String
        let tree: String
        let metadataIdentity: GitWorktreeNodeIdentity
        let index: GitCheckpointIndexRevision
        let directories: [String: GitWorktreeNodeIdentity]
        let files: [String: GitCheckpointIndexRevision]
    }
    struct Marker: Codable, Sendable, Equatable {
        let planID: UUID
        let commit: String
        let manifestDigest: String
    }

    static func seal(plan: GitCheckpointPlan, commit: String, tree: String,
                     metadata: GitWorktreeDirectory, admin: GitWorktreeDirectory) throws -> String {
        try Task.checkCancellation(); try metadata.validate(); try admin.validate(expected: plan.gitDirectoryIdentity)
        let git = try GitWorktreeDirectory(child: "git", parent: metadata)
        let info = try GitWorktreeDirectory(child: "info", parent: git)
        let objects = try GitWorktreeDirectory(child: "objects", parent: git)
        let refs = try GitWorktreeDirectory(child: "refs", parent: git)
        guard let index = try CheckpointFiles.index(admin, name: CheckpointFiles.indexName(plan.id)),
              try !admin.exists(CheckpointFiles.indexName(plan.id) + ".lock"),
              try names(git) == rootFiles.union(["info", "objects", "refs"]),
              try names(info).isSubset(of: infoFiles), try names(objects).isEmpty, try names(refs).isEmpty else {
            throw GitCheckpointError(.ownershipLost)
        }
        var files = [String: GitCheckpointIndexRevision]()
        for name in rootFiles.sorted() {
            guard let revision = try CheckpointFiles.index(git, name: name, maximum: 131_072) else { throw GitCheckpointError(.ownershipLost) }
            files["git/" + name] = revision
        }
        for name in infoFiles.sorted() {
            if let revision = try CheckpointFiles.index(info, name: name, maximum: 131_072) { files["git/info/" + name] = revision }
        }
        let manifest = Manifest(version: 1, planID: plan.id, commit: commit, tree: tree, metadataIdentity: metadata.identity,
            index: index, directories: ["git": git.identity, "git/info": info.identity, "git/objects": objects.identity, "git/refs": refs.identity], files: files)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try metadata.writeExclusive(data, name: manifestName)
        return CheckpointFiles.digest(data)
    }

    static func remove(_ receipt: GitCheckpointReceipt) throws -> GitCheckpointScratchResult {
        let plan = receipt.plan
        guard let digest = receipt.scratchManifestDigest else { return .preserved }
        let common = try GitWorktreeDirectory(path: plan.commonDirectoryPath)
        let admin = try GitWorktreeDirectory(path: plan.gitDirectoryPath)
        try common.validate(expected: plan.commonDirectoryIdentity); try admin.validate(expected: plan.gitDirectoryIdentity)
        let metadata = try GitWorktreeDirectory(child: CheckpointFiles.metadataName(plan.id), parent: common)
        guard let bytes = try metadata.read(manifestName), CheckpointFiles.digest(bytes) == digest,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes),
              valid(manifest, receipt: receipt), manifest.metadataIdentity == metadata.identity else { return .preserved }
        let marker = Marker(planID: plan.id, commit: receipt.commit, manifestDigest: digest)
        let completed = try readMarker(completedName, metadata: metadata)
        if let completed {
            guard completed == marker, try absentScratch(plan, admin: admin, metadata: metadata) else { return .preserved }
            return .alreadyRemoved
        }
        let started = try readMarker(startedName, metadata: metadata)
        guard started == nil || started == marker else { return .preserved }
        let partial = started != nil

        // Verify the whole remaining tree before deleting anything. A previous durable
        // start marker permits only missing known entries, never changed or new entries.
        let directories = try openDirectories(manifest, metadata: metadata, partial: partial)
        try verifyTree(manifest, directories: directories, partial: partial)
        let indexName = CheckpointFiles.indexName(plan.id)
        guard try !admin.exists(indexName + ".lock") else { return .preserved }
        let index = try CheckpointFiles.index(admin, name: indexName)
        guard index == manifest.index || (partial && index == nil) else { return .preserved }
        if started == nil { try metadata.writeExclusive(JSONEncoder().encode(marker), name: startedName) }

        for path in manifest.files.keys.sorted() {
            let parts = split(path)
            guard let parent = directories[parts.parent] else { continue }
            try removeFile(parts.name, parent: parent, revision: manifest.files[path]!, partial: partial)
        }
        for name in ["info", "objects", "refs"] {
            if let child = directories["git/" + name], let git = directories["git"] {
                try removeDirectory(name, child: child, parent: git)
            }
        }
        if let git = directories["git"] { try removeDirectory("git", child: git, parent: metadata) }
        try removeFile(indexName, parent: admin, revision: manifest.index, partial: partial)
        guard try absentScratch(plan, admin: admin, metadata: metadata),
              try metadata.read(manifestName) == bytes else { return .preserved }
        try metadata.writeExclusive(JSONEncoder().encode(marker), name: completedName)
        return .removed
    }

    private static func valid(_ manifest: Manifest, receipt: GitCheckpointReceipt) -> Bool {
        let allowedFiles = Set(rootFiles.map { "git/" + $0 }).union(infoFiles.map { "git/info/" + $0 })
        let requiredFiles = Set(rootFiles.map { "git/" + $0 })
        let actualFiles = Set(manifest.files.keys)
        return manifest.version == 1 && manifest.planID == receipt.plan.id && manifest.commit == receipt.commit && manifest.tree == receipt.tree
            && Set(manifest.directories.keys) == directoryNames && requiredFiles.isSubset(of: actualFiles) && actualFiles.isSubset(of: allowedFiles)
            && manifest.directories.values.allSatisfy { $0.inode != 0 }
            && validRevision(manifest.index, maximum: CheckpointFiles.maximumIndexBytes)
            && manifest.files.values.allSatisfy { validRevision($0, maximum: 131_072) }
    }
    private static func validRevision(_ revision: GitCheckpointIndexRevision, maximum: Int) -> Bool {
        revision.identity.inode != 0 && (0...Int64(maximum)).contains(revision.byteLength)
            && (0..<1_000_000_000).contains(revision.modifiedNanoseconds) && CheckpointValidation.digest(revision.digest)
    }
    private static func readMarker(_ name: String, metadata: GitWorktreeDirectory) throws -> Marker? {
        guard let bytes = try metadata.read(name) else { return nil }
        guard let marker = try? JSONDecoder().decode(Marker.self, from: bytes) else { throw GitCheckpointError(.metadataInvalid) }
        return marker
    }
    private static func absentScratch(_ plan: GitCheckpointPlan, admin: GitWorktreeDirectory, metadata: GitWorktreeDirectory) throws -> Bool {
        try admin.validate(expected: plan.gitDirectoryIdentity); try metadata.validate()
        return try !admin.exists(CheckpointFiles.indexName(plan.id)) && !admin.exists(CheckpointFiles.indexName(plan.id) + ".lock") && !metadata.exists("git")
    }
    private static func openDirectories(_ manifest: Manifest, metadata: GitWorktreeDirectory, partial: Bool) throws -> [String: GitWorktreeDirectory] {
        var directories = [String: GitWorktreeDirectory]()
        for path in ["git", "git/info", "git/objects", "git/refs"] {
            let parts = split(path)
            guard let parent = parts.parent.isEmpty ? metadata : directories[parts.parent] else {
                guard partial else { throw GitCheckpointError(.ownershipLost) }; continue
            }
            if try !parent.exists(parts.name) {
                guard partial else { throw GitCheckpointError(.ownershipLost) }; continue
            }
            let child = try GitWorktreeDirectory(child: parts.name, parent: parent)
            try child.validate(expected: manifest.directories[path])
            directories[path] = child
        }
        return directories
    }
    private static func verifyTree(_ manifest: Manifest, directories: [String: GitWorktreeDirectory], partial: Bool) throws {
        for (path, directory) in directories {
            let expectedFiles = Set(manifest.files.keys.compactMap { split($0).parent == path ? split($0).name : nil })
            let expectedDirectories = Set(manifest.directories.keys.compactMap { split($0).parent == path ? split($0).name : nil })
            let actual = try names(directory)
            guard actual.isSubset(of: expectedFiles.union(expectedDirectories)), partial || actual == expectedFiles.union(expectedDirectories) else {
                throw GitCheckpointError(.ownershipLost)
            }
        }
        for (path, revision) in manifest.files {
            let parts = split(path)
            guard let parent = directories[parts.parent] else { continue }
            let current = try CheckpointFiles.index(parent, name: parts.name, maximum: 131_072)
            guard current == revision || (partial && current == nil) else { throw GitCheckpointError(.ownershipLost) }
        }
    }
    private static func removeFile(_ name: String, parent: GitWorktreeDirectory, revision: GitCheckpointIndexRevision, partial: Bool) throws {
        try Task.checkCancellation(); try parent.validate()
        let current = try CheckpointFiles.index(parent, name: name)
        if partial && current == nil { return }
        guard current == revision else { throw GitCheckpointError(.ownershipLost) }
        var named = stat()
        guard fstatat(parent.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0, worktreeIdentity(named) == revision.identity,
              unlinkat(parent.fd, name, 0) == 0, fsync(parent.fd) == 0 else { throw GitCheckpointError(.ownershipLost) }
        try parent.validate()
    }
    private static func removeDirectory(_ name: String, child: GitWorktreeDirectory, parent: GitWorktreeDirectory) throws {
        try Task.checkCancellation(); try parent.validate(); try child.validate()
        var named = stat()
        guard try names(child).isEmpty, fstatat(parent.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              worktreeIdentity(named) == child.identity, unlinkat(parent.fd, name, AT_REMOVEDIR) == 0,
              fsync(parent.fd) == 0 else { throw GitCheckpointError(.ownershipLost) }
        try parent.validate()
    }
    private static func split(_ path: String) -> (parent: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }
    private static func names(_ directory: GitWorktreeDirectory) throws -> Set<String> {
        try directory.validate(); try Task.checkCancellation()
        let copy = fcntl(directory.fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard copy >= 0 else { throw GitCheckpointError(.ownershipLost) }
        guard let stream = fdopendir(copy) else { close(copy); throw GitCheckpointError(.ownershipLost) }
        defer { closedir(stream) }
        // dup shares the directory offset, so rewind before every bounded enumeration.
        rewinddir(stream)
        var result = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw GitCheckpointError(.ownershipLost) }; break
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingCString: $0) }
            }
            guard let name, !name.contains("/"), !name.isEmpty else { throw GitCheckpointError(.ownershipLost) }
            if name == "." || name == ".." { continue }
            guard result.count < 32, result.insert(name).inserted else { throw GitCheckpointError(.ownershipLost) }
        }
        try directory.validate(); return result
    }
}
