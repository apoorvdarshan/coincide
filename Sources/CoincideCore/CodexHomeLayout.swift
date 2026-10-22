import Darwin
import Foundation

public enum CodexHomeLayoutError: Error, Sendable, Equatable, LocalizedError {
    case invalidPath, homeConflict, privateAuthSymlink, entryConflict, ownershipLost, busy, io, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidPath: "Choose clean, absolute local Codex home directories."
        case .homeConflict: "The private Codex home must be separate from the shared home."
        case .privateAuthSymlink: "Private Codex authentication must be a real private file."
        case .entryConflict: "A Codex home entry conflicts with the shared layout. Existing data was preserved."
        case .ownershipLost: "Codex home ownership changed. Existing data was preserved."
        case .busy: "The Codex home is in use by another layout operation."
        case .io: "The Codex home layout could not be prepared."
        case .cancelled: "Codex home preparation was cancelled."
        }
    }
}

/// Materializes T3's shared-history/private-auth layout without reading authentication bytes.
/// The caller must hold its credential/admission gate and drain every runtime using this overlay.
/// The bounded filesystem lock serializes materializers, not native process lifetimes.
public enum CodexHomeLayout {
    public struct Prepared: Sendable, Equatable {
        public let sharedHome: URL
        public let effectiveHome: URL
        public let continuationIdentity: String
        /// Displaced native runtime entries, retained with ownership proof. These are not disposable.
        public let preservedRuntimeEntries: [URL]
        fileprivate let proof: OwnershipProof?
        init(sharedHome: URL, effectiveHome: URL, continuationIdentity: String, preservedRuntimeEntries: [URL]) {
            self.sharedHome = sharedHome; self.effectiveHome = effectiveHome; self.continuationIdentity = continuationIdentity
            self.preservedRuntimeEntries = preservedRuntimeEntries; proof = nil
        }
        fileprivate init(sharedHome: URL, effectiveHome: URL, continuationIdentity: String, preservedRuntimeEntries: [URL], proof: OwnershipProof) {
            self.sharedHome = sharedHome; self.effectiveHome = effectiveHome; self.continuationIdentity = continuationIdentity
            self.preservedRuntimeEntries = preservedRuntimeEntries; self.proof = proof
        }
    }
    fileprivate struct OwnershipProof: Sendable, Equatable {
        let shared: GitWorktreeNodeIdentity
        let overlay: GitWorktreeNodeIdentity
        let receipt: GitWorktreeNodeIdentity
        let receiptBytes: Data
    }

    private static let directories = ["sessions", "archived_sessions", "sqlite", "shell_snapshots", "worktrees", "skills", "plugins", "cache", "logs", "mcp-oauth-locks"]
    private static let excluded: Set<String> = ["auth.json", "models_cache.json", "log", "memories", "tmp", ".DS_Store"]
    private static let runtime: Set<String> = ["mcp-oauth-locks", ".sqlite-maintenance.lock"]
    private static let marker = ".coincide-codex-home-layout.json"
    private static let lockName = ".coincide-codex-home-layout.lock"
    private static let reservedPrefix = ".coincide-codex-home-"

    public static func prepare(sharedHome: URL, overlayHome: URL) throws -> Prepared {
        do { return try materialize(sharedHome: sharedHome, overlayHome: overlayHome) }
        catch let error as CodexHomeLayoutError { throw error }
        catch is CancellationError { throw CodexHomeLayoutError.cancelled }
        catch { throw CodexHomeLayoutError.io }
    }

    /// Checks an existing owned layout without creating directories, locks, links,
    /// caches or receipts. A required repair fails busy while live users hold SH.
    public static func inspect(sharedHome: URL, overlayHome: URL) throws -> Prepared {
        do { return try inspectExisting(sharedHome: sharedHome, overlayHome: overlayHome) }
        catch let error as CodexHomeLayoutError { throw error }
        catch is CancellationError { throw CodexHomeLayoutError.cancelled }
        catch { throw CodexHomeLayoutError.io }
    }
    public static func validate(sharedHome: URL, overlayHome: URL) throws -> Prepared {
        try inspect(sharedHome: sharedHome, overlayHome: overlayHome)
    }
    public static func validate(_ prepared: Prepared) throws {
        guard prepared.proof != nil else { throw CodexHomeLayoutError.ownershipLost }
        let observed = try inspect(sharedHome: prepared.sharedHome, overlayHome: prepared.effectiveHome)
        guard observed == prepared else { throw CodexHomeLayoutError.ownershipLost }
    }
    static func resolvedPathForAdmission(_ url: URL) throws -> String { try canonicalPath(url).path }

    private struct Retained: Codable {
        let directory: String
        let identity: GitWorktreeNodeIdentity
        let name: String
        let entryIdentity: GitWorktreeNodeIdentity
    }
    private struct Receipt: Codable {
        let format: Int
        let owner: UUID
        let sharedPath: String
        let sharedIdentity: GitWorktreeNodeIdentity
        let overlayPath: String
        let overlayIdentity: GitWorktreeNodeIdentity
        var retained: [Retained]
    }

    private static func inspectExisting(sharedHome: URL, overlayHome: URL) throws -> Prepared {
        try Task.checkCancellation()
        let sharedInput = try canonicalPath(sharedHome), overlayInput = try canonicalPath(overlayHome)
        guard sharedInput.identity != nil, overlayInput.identity != nil else { throw CodexHomeLayoutError.busy }
        let shared = try HomeDirectory.openPath(sharedInput.path, create: false), overlay = try HomeDirectory.openPath(overlayInput.path, create: false)
        guard shared.identity == sharedInput.identity, overlay.identity == overlayInput.identity, shared.identity != overlay.identity,
              !shared.path.hasPrefix(overlay.path + "/"), !overlay.path.hasPrefix(shared.path + "/") else { throw CodexHomeLayoutError.ownershipLost }
        try shared.checkHome(privateHome: false); try overlay.checkHome(privateHome: true)
        let lock = try overlay.acquireLock(lockName, shared: true, create: false)
        defer { withExtendedLifetime(lock) {} }
        guard let metadata = try overlay.metadata(marker) else { throw CodexHomeLayoutError.busy }
        try privateRegular(metadata)
        let bytes = try overlay.read(marker, expected: metadata, maximum: 32_768)
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: bytes), receipt.format == 1,
              receipt.sharedPath == shared.path, receipt.overlayPath == overlay.path,
              receipt.sharedIdentity == shared.identity, receipt.overlayIdentity == overlay.identity,
              receipt.retained.count <= 32 else { throw CodexHomeLayoutError.ownershipLost }
        if let auth = try overlay.metadata("auth.json") {
            guard auth.st_mode & S_IFMT != S_IFLNK else { throw CodexHomeLayoutError.privateAuthSymlink }
            try privateRegular(auth, requirePrivateMode: false)
        }
        if let cache = try overlay.metadata("models_cache.json") {
            guard cache.st_mode & S_IFMT != S_IFLNK else { throw CodexHomeLayoutError.busy }
            try privateRegular(cache, requirePrivateMode: false)
        }
        let entries = try shared.entries(), names = Set(directories).union(entries.keys.filter { !excluded.contains($0) })
        guard names.count <= 1_024, !entries.keys.contains(where: { $0.hasPrefix(reservedPrefix) }) else { throw CodexHomeLayoutError.ownershipLost }
        for name in names {
            try Task.checkCancellation()
            guard let sharedEntry = entries[name] else { throw CodexHomeLayoutError.busy }
            if directories.contains(name) {
                var target = stat()
                guard fstatat(shared.fd, name, &target, 0) == 0, target.st_mode & S_IFMT == S_IFDIR else { throw CodexHomeLayoutError.ownershipLost }
            }
            if sharedEntry.st_mode & S_IFMT == S_IFLNK {
                let physical = try physicalPath(shared.path + "/" + name)
                guard physical != overlay.path, !physical.hasPrefix(overlay.path + "/") else { throw CodexHomeLayoutError.homeConflict }
            }
            guard let link = try overlay.metadata(name), link.st_mode & S_IFMT == S_IFLNK else { throw CodexHomeLayoutError.busy }
            guard link.st_uid == geteuid(), try expectedLink(overlay.readLink(name, expected: link), in: overlay.path, shared: shared.path, name: name) else { throw CodexHomeLayoutError.ownershipLost }
        }
        var seen = Set<String>()
        for retained in receipt.retained {
            guard retained.directory.hasPrefix(reservedPrefix + "preserved-"), UUID(uuidString: String(retained.directory.dropFirst((reservedPrefix + "preserved-").count))) != nil,
                  runtime.contains(retained.name), seen.insert(retained.directory).inserted else { throw CodexHomeLayoutError.ownershipLost }
            let folder = try HomeDirectory(child: retained.directory, parent: overlay)
            try folder.checkHome(privateHome: true)
            guard folder.identity == retained.identity else { throw CodexHomeLayoutError.ownershipLost }
            let preserved = try folder.entries()
            guard preserved.count <= 1, preserved.keys.allSatisfy({ $0 == retained.name }) else { throw CodexHomeLayoutError.ownershipLost }
            guard let entry = preserved[retained.name] else { throw CodexHomeLayoutError.busy }
            guard worktreeIdentity(entry) == retained.entryIdentity else { throw CodexHomeLayoutError.ownershipLost }
        }
        try shared.validate(); try overlay.validate()
        guard let final = try overlay.metadata(marker), worktreeIdentity(final) == worktreeIdentity(metadata),
              final.st_size == metadata.st_size, final.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec else { throw CodexHomeLayoutError.ownershipLost }
        return .init(sharedHome: URL(fileURLWithPath: shared.path, isDirectory: true), effectiveHome: URL(fileURLWithPath: overlay.path, isDirectory: true),
                     continuationIdentity: "codex:home:" + shared.path,
                     preservedRuntimeEntries: receipt.retained.map { URL(fileURLWithPath: overlay.path + "/" + $0.directory + "/" + $0.name) },
                     proof: .init(shared: shared.identity, overlay: overlay.identity, receipt: worktreeIdentity(metadata), receiptBytes: bytes))
    }

    private static func materialize(sharedHome: URL, overlayHome: URL) throws -> Prepared {
        let sharedInput = try canonicalPath(sharedHome), overlayInput = try canonicalPath(overlayHome)
        let sharedPath = sharedInput.path, overlayPath = overlayInput.path
        guard sharedPath != overlayPath, !sharedPath.hasPrefix(overlayPath + "/"), !overlayPath.hasPrefix(sharedPath + "/") else { throw CodexHomeLayoutError.homeConflict }
        let shared = try HomeDirectory.openPath(sharedPath), overlay = try HomeDirectory.openPath(overlayPath)
        guard sharedInput.identity == nil || sharedInput.identity == shared.identity,
              overlayInput.identity == nil || overlayInput.identity == overlay.identity else { throw CodexHomeLayoutError.ownershipLost }
        guard shared.identity != overlay.identity else { throw CodexHomeLayoutError.homeConflict }
        try shared.checkHome(privateHome: false); try overlay.checkHome(privateHome: true)
        let lock = try overlay.acquireLock(lockName)
        defer { withExtendedLifetime(lock) {} }
        try Task.checkCancellation()

        var receipt: Receipt
        var receiptIdentity: GitWorktreeNodeIdentity?
        var receiptStamp: stat?
        if let metadata = try overlay.metadata(marker) {
            try privateRegular(metadata)
            let data = try overlay.read(marker, expected: metadata, maximum: 32_768)
            guard let decoded = try? JSONDecoder().decode(Receipt.self, from: data), decoded.format == 1,
                  decoded.sharedPath == sharedPath, decoded.overlayPath == overlayPath,
                  decoded.sharedIdentity == shared.identity, decoded.overlayIdentity == overlay.identity,
                  decoded.retained.count <= 32 else { throw CodexHomeLayoutError.ownershipLost }
            receipt = decoded; receiptIdentity = worktreeIdentity(metadata); receiptStamp = metadata
        } else {
            receipt = Receipt(format: 1, owner: UUID(), sharedPath: sharedPath, sharedIdentity: shared.identity,
                              overlayPath: overlayPath, overlayIdentity: overlay.identity, retained: [])
        }

        // A shared home cannot itself be one of these private, app-owned overlays.
        let before = try shared.entries()
        guard before.count <= 1_024, !before.keys.contains(where: { $0.hasPrefix(reservedPrefix) }) else { throw CodexHomeLayoutError.homeConflict }
        if let auth = try overlay.metadata("auth.json") {
            guard auth.st_mode & S_IFMT != S_IFLNK else { throw CodexHomeLayoutError.privateAuthSymlink }
            try privateRegular(auth, requirePrivateMode: false)
        }
        var cacheLink: String?
        var cacheIdentity: GitWorktreeNodeIdentity?
        if let cache = try overlay.metadata("models_cache.json") {
            if cache.st_mode & S_IFMT == S_IFLNK {
                let target = try overlay.readLink("models_cache.json", expected: cache)
                guard try expectedLink(target, in: overlay.path, shared: shared.path, name: "models_cache.json") else { throw CodexHomeLayoutError.entryConflict }
                cacheLink = target; cacheIdentity = worktreeIdentity(cache)
            } else { try privateRegular(cache, requirePrivateMode: false) }
        }

        let names = Set(directories).union(before.keys.filter { !excluded.contains($0) }).sorted()
        guard names.count <= 1_024 else { throw CodexHomeLayoutError.entryConflict }
        var originalOverlayEntries: [String: GitWorktreeNodeIdentity] = [:]
        for name in names {
            if let value = before[name] {
                if directories.contains(name) {
                    // Preserve legitimate shared symlinks, including linked skills and config.
                    var target = stat()
                    guard fstatat(shared.fd, name, &target, 0) == 0, target.st_mode & S_IFMT == S_IFDIR else { throw CodexHomeLayoutError.entryConflict }
                }
                if value.st_mode & S_IFMT == S_IFLNK {
                    let physical = try physicalPath(shared.path + "/" + name)
                    guard physical != overlay.path, !physical.hasPrefix(overlay.path + "/") else { throw CodexHomeLayoutError.homeConflict }
                }
            }
            guard let value = try overlay.metadata(name) else { continue }
            guard value.st_uid == geteuid() else { throw CodexHomeLayoutError.entryConflict }
            originalOverlayEntries[name] = worktreeIdentity(value)
            if value.st_mode & S_IFMT == S_IFLNK {
                let target = try overlay.readLink(name, expected: value)
                guard try expectedLink(target, in: overlay.path, shared: shared.path, name: name) else { throw CodexHomeLayoutError.entryConflict }
            } else {
                guard runtime.contains(name), value.st_uid == geteuid(),
                      (name == "mcp-oauth-locks" ? value.st_mode & S_IFMT == S_IFDIR : value.st_mode & S_IFMT == S_IFREG),
                      value.st_mode & 0o022 == 0, value.st_mode & S_IFMT != S_IFREG || value.st_nlink == 1 else { throw CodexHomeLayoutError.entryConflict }
            }
        }

        // Validate every retained entry before any new mutation. A recorded move interrupted by
        // a crash is resumed only when its exact original inode is still at the native name.
        var retainedDirectories: [HomeDirectory] = []
        var pendingMoves: [(HomeDirectory, Retained)] = []
        var seen = Set<String>()
        for retained in receipt.retained {
            guard retained.directory.hasPrefix(reservedPrefix + "preserved-"), UUID(uuidString: String(retained.directory.dropFirst((reservedPrefix + "preserved-").count))) != nil,
                  runtime.contains(retained.name), seen.insert(retained.directory).inserted else { throw CodexHomeLayoutError.ownershipLost }
            let folder = try HomeDirectory(child: retained.directory, parent: overlay)
            try folder.checkHome(privateHome: true)
            guard folder.identity == retained.identity else { throw CodexHomeLayoutError.ownershipLost }
            let entries = try folder.entries()
            guard entries.count <= 1, entries.keys.allSatisfy({ $0 == retained.name }) else { throw CodexHomeLayoutError.ownershipLost }
            if let entry = entries[retained.name] {
                guard worktreeIdentity(entry) == retained.entryIdentity else { throw CodexHomeLayoutError.ownershipLost }
            } else {
                guard let original = try overlay.metadata(retained.name), worktreeIdentity(original) == retained.entryIdentity else { throw CodexHomeLayoutError.ownershipLost }
                pendingMoves.append((folder, retained))
            }
            retainedDirectories.append(folder)
        }

        if receiptIdentity == nil {
            receiptIdentity = try overlay.writeReceipt(receipt, name: marker, replacing: nil)
            receiptStamp = try overlay.metadata(marker)
        }
        func proveReceipt() throws {
            try shared.validate(); try overlay.validate()
            guard let value = try overlay.metadata(marker), let stamp = receiptStamp, worktreeIdentity(value) == receiptIdentity,
                  value.st_size == stamp.st_size, value.st_mtimespec.tv_sec == stamp.st_mtimespec.tv_sec,
                  value.st_mtimespec.tv_nsec == stamp.st_mtimespec.tv_nsec else { throw CodexHomeLayoutError.ownershipLost }
            try privateRegular(value)
        }
        for (folder, retained) in pendingMoves {
            try proveReceipt(); try overlay.move(retained.name, expected: retained.entryIdentity, to: folder)
            originalOverlayEntries.removeValue(forKey: retained.name)
        }

        var madeLinks: [(String, GitWorktreeNodeIdentity)] = []
        var madeDirectories: [(String, GitWorktreeNodeIdentity)] = []
        var removedCache = false
        var succeeded = false
        defer {
            if !succeeded {
                // Identity checked, nonrecursive cleanup only. Never remove adopted/native data.
                for (name, identity) in madeLinks.reversed() { overlay.removeIfSame(name, identity: identity, flags: 0) }
                if removedCache, let target = cacheLink, (try? overlay.metadata("models_cache.json")) == nil { _ = symlinkat(target, overlay.fd, "models_cache.json") }
                for (name, identity) in madeDirectories.reversed() { shared.removeIfSame(name, identity: identity, flags: AT_REMOVEDIR) }
            }
        }
        try proveReceipt()
        if cacheLink != nil, let current = try overlay.metadata("models_cache.json") {
            guard current.st_mode & S_IFMT == S_IFLNK, worktreeIdentity(current) == cacheIdentity,
                  try expectedLink(overlay.readLink("models_cache.json", expected: current), in: overlay.path, shared: shared.path, name: "models_cache.json") else { throw CodexHomeLayoutError.ownershipLost }
            guard unlinkat(overlay.fd, "models_cache.json", 0) == 0 else { throw CodexHomeLayoutError.io }
            removedCache = true
        }
        for name in directories where before[name] == nil {
            try proveReceipt(); try Task.checkCancellation()
            guard mkdirat(shared.fd, name, 0o700) == 0 else { throw CodexHomeLayoutError.entryConflict }
            guard let value = try shared.metadata(name) else { throw CodexHomeLayoutError.ownershipLost }
            madeDirectories.append((name, worktreeIdentity(value)))
        }
        for name in names {
            try proveReceipt(); try Task.checkCancellation()
            let observed = try overlay.metadata(name)
            guard observed.map(worktreeIdentity) == originalOverlayEntries[name] else { throw CodexHomeLayoutError.ownershipLost }
            if let value = observed, value.st_mode & S_IFMT != S_IFLNK {
                guard runtime.contains(name), receipt.retained.count < 32 else { throw CodexHomeLayoutError.entryConflict }
                let quarantineName = reservedPrefix + "preserved-" + UUID().uuidString
                let folder = try overlay.createDirectory(quarantineName)
                let retained = Retained(directory: quarantineName, identity: folder.identity, name: name, entryIdentity: worktreeIdentity(value))
                receipt.retained.append(retained)
                do {
                    receiptIdentity = try overlay.writeReceipt(receipt, name: marker, replacing: receiptIdentity)
                    receiptStamp = try overlay.metadata(marker)
                }
                catch { overlay.removeIfSame(quarantineName, identity: folder.identity, flags: AT_REMOVEDIR); throw error }
                retainedDirectories.append(folder)
                try proveReceipt(); try overlay.move(name, expected: retained.entryIdentity, to: folder)
            }
            if let existing = try overlay.metadata(name) {
                guard existing.st_mode & S_IFMT == S_IFLNK,
                      try expectedLink(overlay.readLink(name, expected: existing), in: overlay.path, shared: shared.path, name: name) else { throw CodexHomeLayoutError.ownershipLost }
            } else {
                guard symlinkat(shared.path + "/" + name, overlay.fd, name) == 0 else { throw CodexHomeLayoutError.entryConflict }
                guard let made = try overlay.metadata(name) else { throw CodexHomeLayoutError.ownershipLost }
                madeLinks.append((name, worktreeIdentity(made)))
            }
        }
        let after = try shared.entries()
        guard Set(after.keys.filter { !excluded.contains($0) }) == Set(names) else { throw CodexHomeLayoutError.ownershipLost }
        for (name, value) in before where !excluded.contains(name) {
            guard after[name].map(worktreeIdentity) == worktreeIdentity(value) else { throw CodexHomeLayoutError.ownershipLost }
        }
        try proveReceipt()
        guard fsync(shared.fd) == 0, fsync(overlay.fd) == 0 else { throw CodexHomeLayoutError.io }
        guard let finalReceipt = try overlay.metadata(marker) else { throw CodexHomeLayoutError.ownershipLost }
        let finalReceiptBytes = try overlay.read(marker, expected: finalReceipt, maximum: 32_768)
        succeeded = true
        return Prepared(sharedHome: URL(fileURLWithPath: shared.path, isDirectory: true), effectiveHome: URL(fileURLWithPath: overlay.path, isDirectory: true),
                        continuationIdentity: "codex:home:" + shared.path,
                        preservedRuntimeEntries: receipt.retained.map { URL(fileURLWithPath: overlay.path + "/" + $0.directory + "/" + $0.name) },
                        proof: .init(shared: shared.identity, overlay: overlay.identity, receipt: worktreeIdentity(finalReceipt), receiptBytes: finalReceiptBytes))
    }

    private static func privateRegular(_ value: stat, requirePrivateMode: Bool = true) throws {
        guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(), value.st_nlink == 1,
              !requirePrivateMode || value.st_mode & 0o077 == 0 else { throw CodexHomeLayoutError.entryConflict }
    }
    private static func canonicalPath(_ url: URL) throws -> (path: String, identity: GitWorktreeNodeIdentity?) {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw CodexHomeLayoutError.invalidPath }
        let path = url.path
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CodexHomeLayoutError.invalidPath }
        var named = stat()
        let exists = lstat(path, &named) == 0
        if exists, named.st_mode & S_IFMT == S_IFLNK { throw CodexHomeLayoutError.homeConflict }
        guard exists || errno == ENOENT else { throw CodexHomeLayoutError.io }
        return (try physicalPath(path), exists ? worktreeIdentity(named) : nil)
    }

    private static func physicalPath(_ path: String) throws -> String {
        // Foundation can rewrite /private/var back to /var even after resolving
        // symlinks. Keep Darwin's literal physical result for the no-follow walk.
        var existing = path, suffix: [String] = []
        while true {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                guard let physical = String(validatingCString: resolved), physical.utf8.count <= 4_096 else { throw CodexHomeLayoutError.invalidPath }
                return (physical == "/" && !suffix.isEmpty ? "" : physical) + suffix.reversed().map { "/" + $0 }.joined()
            }
            guard errno == ENOENT else { throw CodexHomeLayoutError.ownershipLost }
            // An unresolved existing symlink is a foreign/dangling redirect,
            // never a missing directory we may create or traverse.
            var value = stat()
            guard lstat(existing, &value) != 0, errno == ENOENT,
                  let separator = existing.lastIndex(of: "/"), existing != "/" else { throw CodexHomeLayoutError.entryConflict }
            let component = String(existing[existing.index(after: separator)...])
            guard !component.isEmpty else { throw CodexHomeLayoutError.invalidPath }
            suffix.append(component)
            existing = separator == existing.startIndex ? "/" : String(existing[..<separator])
        }
    }

    private static func expectedLink(_ target: String, in directory: String, shared: String, name: String) throws -> Bool {
        // Resolve only the parent: the final shared config entry may itself be
        // a legitimate symlink, and the overlay must still link to that entry.
        let fullPath = target.hasPrefix("/") ? target : directory + "/" + target
        guard let separator = fullPath.lastIndex(of: "/"), String(fullPath[fullPath.index(after: separator)...]) == name else { return false }
        let parent = separator == fullPath.startIndex ? "/" : String(fullPath[..<separator])
        return try physicalPath(parent) == shared
    }
}

private final class HomeDirectory {
    let path: String
    let fd: Int32
    let identity: GitWorktreeNodeIdentity
    private let parent: HomeDirectory?
    private let name: String?
    private init(root: Void) throws {
        let opened = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw CodexHomeLayoutError.io }
        var value = stat()
        guard fstat(opened, &value) == 0 else { Darwin.close(opened); throw CodexHomeLayoutError.io }
        path = "/"; fd = opened; identity = worktreeIdentity(value); parent = nil; name = nil
    }
    init(child name: String, parent: HomeDirectory) throws {
        try parent.validate()
        let opened = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { throw CodexHomeLayoutError.ownershipLost }
        var value = stat(), named = stat()
        guard fstat(opened, &value) == 0, fstatat(parent.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              value.st_mode & S_IFMT == S_IFDIR, worktreeIdentity(value) == worktreeIdentity(named) else { Darwin.close(opened); throw CodexHomeLayoutError.ownershipLost }
        self.parent = parent; self.name = name; path = (parent.path == "/" ? "" : parent.path) + "/" + name
        fd = opened; identity = worktreeIdentity(value)
    }
    deinit { Darwin.close(fd) }
    static func openPath(_ path: String, create: Bool = true) throws -> HomeDirectory {
        var directory = try HomeDirectory(root: ())
        for name in path.split(separator: "/").map(String.init) {
            try Task.checkCancellation(); try directory.validate()
            if try directory.metadata(name) == nil {
                guard create else { throw CodexHomeLayoutError.busy }
                guard mkdirat(directory.fd, name, 0o700) == 0 else { throw CodexHomeLayoutError.io }
            }
            directory = try HomeDirectory(child: name, parent: directory)
        }
        return directory
    }
    func validate() throws {
        try parent?.validate()
        var value = stat(), named = stat()
        let result = parent.map { fstatat($0.fd, name!, &named, AT_SYMLINK_NOFOLLOW) } ?? lstat("/", &named)
        guard result == 0, fstat(fd, &value) == 0, named.st_mode & S_IFMT == S_IFDIR,
              worktreeIdentity(value) == identity, worktreeIdentity(named) == identity else { throw CodexHomeLayoutError.ownershipLost }
    }
    func checkHome(privateHome: Bool) throws {
        try validate(); var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == geteuid(), value.st_mode & (privateHome ? 0o077 : 0o022) == 0 else { throw CodexHomeLayoutError.ownershipLost }
    }
    func metadata(_ name: String) throws -> stat? {
        var value = stat()
        if fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
        guard errno == ENOENT else { throw CodexHomeLayoutError.io }; return nil
    }
    func entries() throws -> [String: stat] {
        try validate()
        let opened = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw CodexHomeLayoutError.io }
        guard let stream = fdopendir(opened) else { Darwin.close(opened); throw CodexHomeLayoutError.io }
        defer { closedir(stream) }
        var result: [String: stat] = [:]
        errno = 0
        while let item = readdir(stream) {
            let capacity = Int(item.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &item.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            guard result.count < 1_024, name.utf8.count <= 255,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), let value = try metadata(name) else { throw CodexHomeLayoutError.entryConflict }
            result[name] = value; errno = 0
        }
        guard errno == 0 else { throw CodexHomeLayoutError.io }; return result
    }
    func createDirectory(_ name: String) throws -> HomeDirectory {
        try validate(); try Task.checkCancellation()
        guard mkdirat(fd, name, 0o700) == 0 else { throw CodexHomeLayoutError.io }
        return try HomeDirectory(child: name, parent: self)
    }
    func readLink(_ name: String, expected: stat) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 4_097)
        let count = readlinkat(fd, name, &buffer, buffer.count)
        guard count > 0, count <= 4_096, let value = try metadata(name), worktreeIdentity(value) == worktreeIdentity(expected),
              let target = String(bytes: buffer.prefix(count), encoding: .utf8), !target.contains("\0") else { throw CodexHomeLayoutError.ownershipLost }
        return target
    }
    func read(_ name: String, expected: stat, maximum: Int) throws -> Data {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw CodexHomeLayoutError.ownershipLost }; defer { Darwin.close(file) }
        var value = stat()
        guard fstat(file, &value) == 0, worktreeIdentity(value) == worktreeIdentity(expected), value.st_size > 0, value.st_size <= maximum else { throw CodexHomeLayoutError.ownershipLost }
        var data = Data(), buffer = [UInt8](repeating: 0, count: maximum + 1)
        while data.count <= maximum {
            try Task.checkCancellation()
            let count = Darwin.read(file, &buffer, maximum + 1 - data.count)
            if count == 0 { break }; if count < 0 { if errno == EINTR { continue }; throw CodexHomeLayoutError.io }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard data.count == Int(expected.st_size), fstat(file, &after) == 0, let named = try metadata(name),
              worktreeIdentity(after) == worktreeIdentity(expected), worktreeIdentity(named) == worktreeIdentity(expected),
              after.st_size == expected.st_size, after.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec else { throw CodexHomeLayoutError.ownershipLost }
        return data
    }
    func writeReceipt<T: Encodable>(_ value: T, name: String, replacing: GitWorktreeNodeIdentity?) throws -> GitWorktreeNodeIdentity {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 32_768 else { throw CodexHomeLayoutError.entryConflict }
        try validate(); try Task.checkCancellation()
        let temporary = ".coincide-codex-home-write-" + UUID().uuidString
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw CodexHomeLayoutError.io }
        var owned = stat(); guard fstat(file, &owned) == 0 else { Darwin.close(file); throw CodexHomeLayoutError.io }
        defer { Darwin.close(file); removeIfSame(temporary, identity: worktreeIdentity(owned), flags: 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw CodexHomeLayoutError.io }
                guard count > 0 else { throw CodexHomeLayoutError.io }; offset += count
            }
        }
        guard fsync(file) == 0 else { throw CodexHomeLayoutError.io }
        try validate(); try Task.checkCancellation()
        if let replacing {
            guard let existing = try metadata(name), worktreeIdentity(existing) == replacing else { throw CodexHomeLayoutError.ownershipLost }
            guard renameatx_np(fd, temporary, fd, name, UInt32(RENAME_SWAP)) == 0 else { throw CodexHomeLayoutError.io }
            guard let displaced = try metadata(temporary), worktreeIdentity(displaced) == replacing else {
                // Restore the displaced record only while our newly written record is still named.
                if let current = try? metadata(name), worktreeIdentity(current) == worktreeIdentity(owned) { _ = renameatx_np(fd, temporary, fd, name, UInt32(RENAME_SWAP)) }
                throw CodexHomeLayoutError.ownershipLost
            }
            removeIfSame(temporary, identity: replacing, flags: 0)
        } else {
            guard renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL)) == 0 else { throw CodexHomeLayoutError.ownershipLost }
        }
        guard fsync(fd) == 0 else { throw CodexHomeLayoutError.io }; return worktreeIdentity(owned)
    }
    func move(_ name: String, expected: GitWorktreeNodeIdentity, to destination: HomeDirectory) throws {
        try validate(); try destination.validate(); try Task.checkCancellation()
        guard let original = try metadata(name), worktreeIdentity(original) == expected else { throw CodexHomeLayoutError.ownershipLost }
        // Refuse a cooperating native process's held file lock; the caller must additionally
        // prove process drain because directory locks do not expose a universal liveness test.
        var locked: Int32 = -1
        if original.st_mode & S_IFMT == S_IFREG {
            locked = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard locked >= 0 else { throw CodexHomeLayoutError.ownershipLost }
            if flock(locked, LOCK_EX | LOCK_NB) != 0 { Darwin.close(locked); throw CodexHomeLayoutError.busy }
        }
        defer { if locked >= 0 { _ = flock(locked, LOCK_UN); Darwin.close(locked) } }
        guard renameatx_np(fd, name, destination.fd, name, UInt32(RENAME_EXCL)) == 0,
              let moved = try destination.metadata(name), worktreeIdentity(moved) == expected else { throw CodexHomeLayoutError.ownershipLost }
        guard fsync(fd) == 0, fsync(destination.fd) == 0 else { throw CodexHomeLayoutError.io }
    }
    func removeIfSame(_ name: String, identity: GitWorktreeNodeIdentity, flags: Int32) {
        guard (try? validate()) != nil, let value = try? metadata(name), worktreeIdentity(value) == identity else { return }
        _ = unlinkat(fd, name, flags)
    }
    func acquireLock(_ name: String, shared: Bool = false, create: Bool = true) throws -> HomeLayoutLock {
        try validate()
        let file = openat(fd, name, O_RDWR | (create ? O_CREAT : 0) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        if file < 0, !create, errno == ENOENT { throw CodexHomeLayoutError.busy }
        guard file >= 0 else { throw CodexHomeLayoutError.ownershipLost }
        var value = stat()
        guard fstat(file, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size == 0,
              value.st_uid == geteuid(), value.st_nlink == 1, value.st_mode & 0o077 == 0 else { Darwin.close(file); throw CodexHomeLayoutError.ownershipLost }
        let deadline = ContinuousClock.now + .seconds(1)
        while flock(file, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { Darwin.close(file); throw CodexHomeLayoutError.io }
            if Task.isCancelled { Darwin.close(file); throw CodexHomeLayoutError.cancelled }
            guard ContinuousClock.now < deadline else { Darwin.close(file); throw CodexHomeLayoutError.busy }; usleep(10_000)
        }
        do {
            try validate()
            guard let named = try metadata(name), worktreeIdentity(named) == worktreeIdentity(value) else { throw CodexHomeLayoutError.ownershipLost }
        } catch { _ = flock(file, LOCK_UN); Darwin.close(file); throw error }
        return HomeLayoutLock(fd: file)
    }
}

private final class HomeLayoutLock {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
    deinit { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
}
