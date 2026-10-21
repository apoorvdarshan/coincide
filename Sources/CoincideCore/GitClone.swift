import Foundation
import Darwin

/// A journal-safe clone invocation. Authentication comes from Git's credential helpers or SSH agent,
/// never from the stored source URL. Each attempt owns a distinct hidden sibling directory.
public struct GitClonePlan: Codable, Sendable, Equatable {
    public let id: UUID
    public let source: String
    public let destinationPath: String
    public let stagingPath: String

    public static func prepare(source: String, destination: URL, id: UUID = UUID()) throws -> Self {
        guard !source.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw CoincideError("Repository sources cannot contain control characters.")
        }
        guard destination.isFileURL else { throw CoincideError("Choose a local destination folder.") }
        let requested = destination.standardizedFileURL
        let parent = requested.deletingLastPathComponent().resolvingSymlinksInPath()
        guard try ClonePaths.isDirectory(parent.path), access(parent.path, W_OK) == 0 else {
            throw CoincideError("Choose an existing writable parent folder for the clone.")
        }
        let target = parent.appendingPathComponent(requested.lastPathComponent)
        var normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateSource(normalizedSource)
        if !normalizedSource.contains(":") || ["/", "./", "../", "~/"].contains(where: normalizedSource.hasPrefix) {
            normalizedSource = URL(fileURLWithPath: NSString(string: normalizedSource).expandingTildeInPath).standardizedFileURL.path
        }
        let plan = Self(id: id, source: normalizedSource, destinationPath: target.path,
                        stagingPath: parent.appendingPathComponent(".coincide-clone-" + id.uuidString.lowercased()).path)
        try plan.validate()
        guard try !ClonePaths.exists(plan.destinationPath) else {
            throw CoincideError("The destination already exists. Choose a new folder name; existing folders are never overwritten.")
        }
        guard try !ClonePaths.exists(plan.stagingPath) else { throw CoincideError("This clone attempt already has staging files. Start a new attempt.") }
        return plan
    }

    /// Structural validation intentionally does not require the destination to be absent or accessible:
    /// a persisted successful project remains valid after promotion, unmounting, or later user deletion.
    public func validate() throws {
        try Self.validateSource(source)
        for path in [destinationPath, stagingPath] {
            guard path.hasPrefix("/"), !path.contains(where: { $0.isNewline || $0 == "\0" }),
                  URL(fileURLWithPath: path).standardizedFileURL.path == path else {
                throw CoincideError("The stored clone paths are invalid.")
            }
        }
        let destination = URL(fileURLWithPath: destinationPath)
        guard destinationPath != "/", destination.lastPathComponent != ".git",
              stagingPath == destination.deletingLastPathComponent().appendingPathComponent(".coincide-clone-" + id.uuidString.lowercased()).path,
              stagingPath != destinationPath else { throw CoincideError("The stored clone staging path is invalid.") }
    }

    private static func validateSource(_ source: String) throws {
        let clearlyLocal = ["/", "./", "../", "~/"].contains(where: source.hasPrefix)
        guard !source.isEmpty, source.utf8.count <= 16_384, !source.hasPrefix("-"),
              !source.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              source == source.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.contains("::") || clearlyLocal || source.contains("://") else {
            throw CoincideError("Enter a repository URL or local path, without options or control characters.")
        }
        if source.contains("://") {
            guard let url = URLComponents(string: source), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ssh", "git", "file"].contains(scheme),
                  url.query == nil, url.fragment == nil, url.password == nil,
                  !(source.removingPercentEncoding ?? source).unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw CoincideError("Use an HTTP(S), SSH, Git, file URL, or local path without passwords, query parameters, or fragments.")
            }
            if scheme == "file" {
                guard url.user == nil, url.port == nil, url.host == nil || url.host == "" || url.host == "localhost", url.path.hasPrefix("/") else {
                    throw CoincideError("Use an absolute local file URL without credentials.")
                }
            } else {
                guard let host = url.host, !host.isEmpty, !host.hasPrefix("-"), !host.contains(where: { $0.isWhitespace }), !url.path.isEmpty else {
                    throw CoincideError("Enter a complete repository URL with a host and repository path.")
                }
                guard (scheme == "ssh" || url.user == nil), url.user?.isEmpty != true, url.user?.contains(":") != true,
                      url.user?.hasPrefix("-") != true, (url.port == nil || (1...65_535).contains(url.port!)) else {
                    throw CoincideError("Remove credentials from the URL. Use Git's credential helper or SSH agent.")
                }
            }
        } else if let colon = source.firstIndex(of: ":") {
            // SCP syntax has an optional SSH username, a hostname (or bracketed IPv6 address),
            // and a nonempty path. Relative paths containing ':' must be written as ./path.
            if clearlyLocal { return }
            let prefix = String(source[..<colon]), suffix = String(source[source.index(after: colon)...])
            if source.contains(":["), prefix.contains("[") { throw CoincideError("Use ssh:// for IPv6 repository URLs.") }
            let parts = prefix.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._~-".contains($0)) }) }),
                  !suffix.isEmpty, !suffix.hasPrefix("-"), !suffix.contains("@"), !suffix.contains("?"), !suffix.contains("#") else {
                throw CoincideError("Use a valid SSH repository URL without a password, or an absolute local path.")
            }
        }
    }
}

public struct GitCloneProgress: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable { case connecting, counting, receiving, resolving, checkout }
    public var stage: Stage
    public var percent: Int?
    public var detail: String?
    public var stalled: Bool
    public init(stage: Stage = .connecting, percent: Int? = nil, detail: String? = nil, stalled: Bool = false) {
        self.stage = stage; self.percent = percent; self.detail = detail; self.stalled = stalled
    }
}

public struct GitCloneService: Sendable {
    public let plan: GitClonePlan
    public let stallAfter: Duration
    private let executable: URL?
    private let testEnvironment: [String: String]?
    private let testHooks: GitCloneProcessTestHooks?
    public init(plan: GitClonePlan, stallAfter: Duration = .seconds(20)) {
        self.plan = plan; self.stallAfter = stallAfter; executable = nil; testEnvironment = nil; testHooks = nil
    }
    // Deterministic process/descendant failure fixtures exercise the production spawning path.
    init(plan: GitClonePlan, stallAfter: Duration, executable: URL, environment: [String: String], testHooks: GitCloneProcessTestHooks? = nil) {
        self.plan = plan; self.stallAfter = stallAfter; self.executable = executable; testEnvironment = environment; self.testHooks = testHooks
    }

    public func isCompleted() async throws -> Bool {
        try plan.validate()
        let parent = URL(fileURLWithPath: plan.destinationPath).deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath().path == parent.path else { return false }
        return try completion(at: plan.destinationPath)
    }

    public func run(onProgress: @escaping @Sendable (GitCloneProgress) async -> Void) async throws {
        try plan.validate(); try Task.checkCancellation()
        let lease = try await CloneLeases.shared.acquire(plan.destinationPath)
        do {
            try await execute(onProgress: onProgress)
            await CloneLeases.shared.release(plan.destinationPath, lease: lease)
        } catch {
            await CloneLeases.shared.release(plan.destinationPath, lease: lease); throw error
        }
    }

    private func execute(onProgress: @escaping @Sendable (GitCloneProgress) async -> Void) async throws {
        if try await isCompleted() { return }
        let parent = URL(fileURLWithPath: plan.destinationPath).deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath().path == parent.path, try ClonePaths.isDirectory(parent.path) else {
            throw CoincideError("The clone parent folder changed or is no longer available.")
        }
        let parentAnchor = try CloneDirectory(path: parent.path)
        let staging = URL(fileURLWithPath: plan.stagingPath)
        let destinationName = URL(fileURLWithPath: plan.destinationPath).lastPathComponent, stagingName = staging.lastPathComponent
        guard try !parentAnchor.exists(destinationName) else { throw CoincideError("The destination already exists. The partial clone has been preserved; choose a different folder.") }
        let alreadyStaged = try parentAnchor.exists(stagingName)
        let stagingAnchor: CloneDirectory
        if alreadyStaged {
            stagingAnchor = try parentAnchor.directory(stagingName)
            guard try stagingAnchor.read("plan.json", limit: 65_536) == Self.encode(plan) else {
                throw CoincideError("The staging folder is not owned by this clone attempt. It has been left untouched.")
            }
        } else {
            stagingAnchor = try parentAnchor.createDirectory(stagingName)
            try stagingAnchor.writeNew(Self.encode(plan), name: "plan.json")
        }
        let lockFD = openat(stagingAnchor.fd, "lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lockFD >= 0 else { throw CoincideError("Could not lock this clone's staging folder.") }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        var lockIdentity = stat()
        guard fstat(lockFD, &lockIdentity) == 0, lockIdentity.st_mode & S_IFMT == S_IFREG else { throw CoincideError("The clone lock was replaced by an unsupported file type. It has been preserved.") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw CoincideError("This clone attempt is already running.") }
        let checkoutAnchor: CloneDirectory
        if alreadyStaged {
            guard try stagingAnchor.exists("checkout") else { throw CoincideError("An interrupted clone's staging files were preserved. Retry with a new attempt; they will not be overwritten.") }
            checkoutAnchor = try stagingAnchor.directory("checkout")
            guard try completion(in: checkoutAnchor) else { throw CoincideError("An interrupted clone's staging files were preserved. Retry with a new attempt; they will not be overwritten.") }
            try promote(parent: parentAnchor, staging: stagingAnchor, checkout: checkoutAnchor); return
        }
        // Git accepts an existing empty checkout. Hold its identity and FD before the child starts,
        // then use fchdir + destination '.' so renaming its pathname cannot redirect Git's cwd.
        checkoutAnchor = try stagingAnchor.createDirectory("checkout")
        try verifyAnchors(parent: parentAnchor, staging: stagingAnchor, checkout: checkoutAnchor)
        try Task.checkCancellation()
        guard let git = executable ?? ProcessChannel.findExecutable("git") else { throw CoincideError("Git is not installed or executable.") }
        var environment = testEnvironment ?? ProcessChannel.environment()
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_CURL_VERBOSE"] + environment.keys.filter({ $0.hasPrefix("GIT_TRACE") }) {
            environment.removeValue(forKey: key)
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GCM_INTERACTIVE"] = "Never"
        environment["SSH_ASKPASS"] = "/usr/bin/false"; environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["GIT_ALLOW_PROTOCOL"] = "file:http:https:ssh:git"; environment["GIT_PROTOCOL_FROM_USER"] = "1"
        environment["LC_ALL"] = "C"
        let arguments = ["--no-pager", "--no-optional-locks", "-c", "color.ui=false", "-c", "advice.detachedHead=false",
                         "clone", "--progress", "--no-recurse-submodules", "--", plan.source, "."]
        let process = try CloneProcess(executable: git, arguments: arguments, cwdFD: checkoutAnchor.fd, environment: environment, testHooks: testHooks)
        let progress = CloneProgressTracker(stallAfter: stallAfter, notify: onProgress)
        await withTaskCancellationHandler { await progress.begin() } onCancel: { process.stop() }
        let watcher = Task { await progress.watchForStall() }
        var parser = GitCloneProgressParser()
        do {
            let status = await withTaskCancellationHandler {
                for await event in process.events {
                    process.consumedEvent()
                    switch event {
                    case .stderr(let bytes):
                        await progress.pulse()
                        for update in parser.consume(bytes) { await progress.update(update) }
                    case .stdout, .exited: break
                    }
                }
                // AsyncStream cancellation ends iteration immediately. Still wait for this owned
                // process group and its inherited pipes before returning cancellation to the caller.
                return await process.waitForExit()
            } onCancel: { process.stop() }
            watcher.cancel()
            try Task.checkCancellation()
            for update in parser.finish() { await progress.update(update) }
            guard status == 0 else { throw CoincideError(parser.errorDetail ?? "The repository could not be cloned (Git exit \(status)).") }
            try verifyAnchors(parent: parentAnchor, staging: stagingAnchor, checkout: checkoutAnchor)
            let gitAnchor = try checkoutAnchor.directory(".git"), identity = checkoutAnchor.identity
            let record = CloneCompletion(plan: plan, device: UInt64(truncatingIfNeeded: identity.st_dev), inode: UInt64(identity.st_ino))
            try verifyAnchors(parent: parentAnchor, staging: stagingAnchor, checkout: checkoutAnchor)
            guard gitAnchor.matches(checkoutAnchor, name: ".git") else { throw CoincideError("The clone's Git directory changed. All staging files were preserved.") }
            try gitAnchor.writeNew(Self.encode(record), name: "coincide-clone.json")
            guard gitAnchor.matches(checkoutAnchor, name: ".git") else { throw CoincideError("The clone's Git directory changed. All staging files were preserved.") }
            try Task.checkCancellation()
            try promote(parent: parentAnchor, staging: stagingAnchor, checkout: checkoutAnchor)
            await onProgress(.init(stage: .checkout, percent: 100))
        } catch { watcher.cancel(); process.stop(); _ = await process.waitForExit(); throw error }
        // Retain only the tiny ownership sidecar. No checkout bytes are deleted, even on failure.
        // A crash before promotion is recovered by the completion marker above.
    }

    private func completion(at path: String) throws -> Bool {
        guard try ClonePaths.exists(path), try ClonePaths.isDirectory(path) else { return false }
        return try completion(in: CloneDirectory(path: path))
    }
    private func completion(in directory: CloneDirectory) throws -> Bool {
        guard try directory.exists(".git") else { return false }
        let git = try directory.directory(".git")
        guard try git.exists("coincide-clone.json"), let data = try git.read("coincide-clone.json", limit: 65_536),
              let marker = try? JSONDecoder().decode(CloneCompletion.self, from: data), marker.plan == plan else { return false }
        let identity = directory.identity
        return marker.device == UInt64(truncatingIfNeeded: identity.st_dev) && marker.inode == UInt64(identity.st_ino)
    }
    private func verifyAnchors(parent: CloneDirectory, staging: CloneDirectory, checkout: CloneDirectory) throws {
        let parentPath = URL(fileURLWithPath: plan.destinationPath).deletingLastPathComponent().path
        guard URL(fileURLWithPath: parentPath).resolvingSymlinksInPath().path == parentPath,
              parent.matches(path: parentPath), staging.matches(parent, name: URL(fileURLWithPath: plan.stagingPath).lastPathComponent),
              checkout.matches(staging, name: "checkout") else {
            throw CoincideError("A clone folder was moved or replaced while cloning. The original checkout and replacement have been left untouched.")
        }
    }
    private func promote(parent: CloneDirectory, staging: CloneDirectory, checkout: CloneDirectory) throws {
        try Task.checkCancellation()
        try verifyAnchors(parent: parent, staging: staging, checkout: checkout)
        // Both directories are siblings on the same filesystem. RENAME_EXCL atomically refuses
        // files, empty folders, nonempty folders, and symlinks that appeared after preparation.
        let name = URL(fileURLWithPath: plan.destinationPath).lastPathComponent
        guard renameatx_np(staging.fd, "checkout", parent.fd, name, UInt32(RENAME_EXCL)) == 0 else {
            throw CoincideError(errno == EEXIST || errno == ENOTEMPTY ? "The destination appeared while cloning. It was left untouched; the completed clone remains in staging." : "Could not move the completed clone into place. It remains safely in staging.")
        }
        guard parent.matches(path: URL(fileURLWithPath: plan.destinationPath).deletingLastPathComponent().path),
              checkout.matches(parent, name: name), try completion(in: checkout) else { throw CoincideError("The promoted clone changed before completion could be recorded. Inspect the destination before retrying.") }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
}

private struct CloneCompletion: Codable { let plan: GitClonePlan; let device: UInt64; let inode: UInt64 }

/// Directory capabilities keep all writes attached to the exact directories acquired before Git
/// starts. A namespace replacement cannot redirect openat metadata writes or the child's cwd.
private final class CloneDirectory: @unchecked Sendable {
    let fd: Int32
    let identity: stat
    init(path: String) throws {
        let acquired = try Self.acquire(open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)); fd = acquired.0; identity = acquired.1
    }
    private init(parent: Int32, name: String) throws {
        let acquired = try Self.acquire(openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)); fd = acquired.0; identity = acquired.1
    }
    deinit { close(fd) }
    private static func acquire(_ descriptor: Int32) throws -> (Int32, stat) {
        guard descriptor >= 0 else { throw CoincideError("A clone directory is no longer available or was replaced by a symlink.") }
        let owned: Int32
        if descriptor <= STDERR_FILENO {
            owned = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1); close(descriptor)
            guard owned >= 0 else { throw CoincideError("Could not retain an owned clone directory.") }
        } else { owned = descriptor }
        var info = stat()
        guard fstat(owned, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { close(owned); throw CoincideError("A clone directory could not be inspected.") }
        return (owned, info)
    }
    func directory(_ name: String) throws -> CloneDirectory { try CloneDirectory(parent: fd, name: name) }
    func createDirectory(_ name: String) throws -> CloneDirectory {
        guard mkdirat(fd, name, 0o700) == 0 else { throw CoincideError("Could not create a private clone directory without overwriting an existing path.") }
        return try directory(name)
    }
    func exists(_ name: String) throws -> Bool {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw CoincideError("A clone path could not be inspected.")
    }
    func matches(_ parent: CloneDirectory, name: String) -> Bool {
        var info = stat()
        return fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && Self.same(identity, info)
    }
    func matches(path: String) -> Bool {
        var info = stat(); return lstat(path, &info) == 0 && Self.same(identity, info)
    }
    private static func same(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && second.st_mode & S_IFMT == S_IFDIR
    }
    func read(_ name: String, limit: Int) throws -> Data? {
        let descriptor = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor == -1 && errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw CoincideError("Clone ownership metadata could not be read.") }
        defer { close(descriptor) }
        return try ClonePaths.readDescriptor(descriptor, limit: limit)
    }
    func writeNew(_ data: Data, name: String) throws {
        let temporary = ".coincide-metadata-" + UUID().uuidString.lowercased()
        let descriptor = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CoincideError("Clone ownership metadata could not be created.") }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count } else if count < 0 && errno == EINTR { continue }
                else { throw CoincideError("Clone ownership metadata could not be written.") }
            }
        }
        guard fsync(descriptor) == 0, renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL)) == 0 else {
            throw CoincideError("Clone ownership metadata could not be saved without overwriting an existing file. Staging files were preserved.")
        }
    }
}

private enum ClonePaths {
    static func identity(_ path: String) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw CoincideError("A clone folder is no longer accessible.") }; return info
    }
    static func exists(_ path: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw CoincideError("A clone path could not be inspected.")
    }
    static func isDirectory(_ path: String) throws -> Bool {
        guard try exists(path) else { return false }; return try identity(path).st_mode & S_IFMT == S_IFDIR
    }
    static func readIfPresent(_ url: URL, limit: Int) throws -> Data? { try exists(url.path) ? read(url, limit: limit) : nil }
    static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw CoincideError("Clone ownership metadata could not be read.") }; defer { close(fd) }
        return try readDescriptor(fd, limit: limit)
    }
    static func readDescriptor(_ fd: Int32, limit: Int) throws -> Data {
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else {
            throw CoincideError("Clone ownership metadata is invalid.")
        }
        var bytes = [UInt8](repeating: 0, count: limit + 1), offset = 0
        while offset <= limit {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), limit + 1 - offset) }
            if count > 0 { offset += count } else if count < 0 && errno == EINTR { continue } else if count == 0 { break }
            else { throw CoincideError("Clone ownership metadata could not be read.") }
        }
        guard offset <= limit else { throw CoincideError("Clone ownership metadata exceeded its limit.") }
        return Data(bytes.prefix(offset))
    }
}

private actor CloneLeases {
    static let shared = CloneLeases()
    private var leases: [String: UUID] = [:]
    func acquire(_ path: String) throws -> UUID {
        guard leases[path] == nil else { throw CoincideError("A clone to this destination is already running.") }
        let lease = UUID(); leases[path] = lease; return lease
    }
    func release(_ path: String, lease: UUID) { if leases[path] == lease { leases.removeValue(forKey: path) } }
}

/// Bounded CR/LF parser: progress redraws never accumulate with clone size or duration.
struct GitCloneProgressParser {
    private var pending = Data()
    private var discardingLongLine = false
    private(set) var tail: [String] = []
    private(set) var discardedBytes = 0
    var pendingByteCount: Int { pending.count }
    var errorDetail: String? { tail.isEmpty ? nil : String(tail.joined(separator: " ").prefix(4_096)) }
    mutating func consume(_ bytes: Data) -> [GitCloneProgress] {
        var result: [GitCloneProgress] = []
        for byte in bytes {
            if byte == 10 || byte == 13 {
                if discardingLongLine { discardingLongLine = false; pending.removeAll(keepingCapacity: true); continue }
                if let update = line() { result.append(update) }
            } else {
                if discardingLongLine { discardedBytes += 1; continue }
                pending.append(byte)
                if pending.count > 8_192 { discardedBytes += pending.count; pending.removeAll(keepingCapacity: true); discardingLongLine = true }
            }
        }
        return result
    }
    mutating func finish() -> [GitCloneProgress] { line().map { [$0] } ?? [] }
    private mutating func line() -> GitCloneProgress? {
        let value = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines); pending.removeAll(keepingCapacity: true)
        guard !value.isEmpty else { return nil }
        if let progress = Self.parse(value) { return progress }
        if !value.hasPrefix("Cloning into") {
            tail.append(String(GitService.redactURLs(value).prefix(1_024)))
            if tail.count > 4 { tail.removeFirst(tail.count - 4) }
        }
        return nil
    }
    static func parse(_ line: String) -> GitCloneProgress? {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let stage: GitCloneProgress.Stage
        if ["remote: Enumerating objects", "remote: Counting objects", "remote: Compressing objects", "Counting objects", "Compressing objects"].contains(where: value.hasPrefix) { stage = .counting }
        else if value.hasPrefix("Receiving objects") { stage = .receiving }
        else if value.hasPrefix("Resolving deltas") { stage = .resolving }
        else if value.hasPrefix("Updating files") || value.hasPrefix("Checking out files") { stage = .checkout }
        else { return nil }
        guard let colon = value.firstIndex(of: ":"), let percentIndex = value[colon...].firstIndex(of: "%") else { return .init(stage: stage) }
        let number = value[..<percentIndex].split(whereSeparator: { $0.isWhitespace }).last
        let percent = number.flatMap { Int($0) }.map { max(0, min(100, $0)) }
        var detail: String?
        if let close = value[percentIndex...].firstIndex(of: ")") {
            var rest = value[value.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.hasPrefix(",") { rest.removeFirst(); rest = rest.trimmingCharacters(in: .whitespaces) }
            if rest.hasSuffix(", done.") { rest = String(rest.dropLast(7)) }
            if !rest.isEmpty && rest != "done." { detail = String(GitService.redactURLs(rest).prefix(512)) }
        }
        return .init(stage: stage, percent: percent, detail: detail)
    }
}

private actor CloneProgressTracker {
    let stallAfter: Duration
    let notify: @Sendable (GitCloneProgress) async -> Void
    var current = GitCloneProgress()
    var lastOutput = ContinuousClock.now
    init(stallAfter: Duration, notify: @escaping @Sendable (GitCloneProgress) async -> Void) { self.stallAfter = stallAfter; self.notify = notify }
    func begin() async { await notify(current) }
    func pulse() async {
        lastOutput = .now
        if current.stalled { current.stalled = false; await notify(current) }
    }
    func update(_ progress: GitCloneProgress) async { if progress != current { current = progress; await notify(progress) } }
    func watchForStall() async {
        let interval = max(.milliseconds(10), min(.seconds(1), stallAfter))
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { return }
            if !current.stalled && lastOutput.duration(to: .now) >= stallAfter { current.stalled = true; await notify(current) }
        }
    }
}

/// posix_spawn creates a fresh process group before any Git code executes. Cancellation signals
/// only that group (including Git's SSH/HTTP children), then waits for exit and pipe drainage.
struct GitCloneProcessTestHooks: Sendable {
    let observeExit: @Sendable (pid_t) -> Int32
    let signalGroup: @Sendable (pid_t, Int32) -> Void
}

private final class CloneProcess: @unchecked Sendable {
    let events: AsyncStream<ProcessEvent>
    private let pid: pid_t
    private let lock = NSLock()
    private var status: Int32?
    private var stopping = false
    private var signalAllowed = true
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private let buffer = CloneEventBuffer()
    private let readers = CloneReaderState()
    private let testHooks: GitCloneProcessTestHooks?
    init(executable: URL, arguments: [String], cwdFD: Int32, environment: [String: String], testHooks: GitCloneProcessTestHooks?) throws {
        self.testHooks = testHooks
        // Producers acquire one of sixteen slots before yielding. Dropping arbitrary raw chunks
        // could turn a credential URL into an unrecognizable suffix and bypass URL redaction.
        let (stream, continuation) = AsyncStream<ProcessEvent>.makeStream(); events = stream
        var output = [Int32](repeating: -1, count: 2), errors = [Int32](repeating: -1, count: 2)
        guard pipe(&output) == 0, pipe(&errors) == 0 else {
            for fd in output + errors where fd >= 0 { close(fd) }; throw CoincideError("Could not create Git output pipes.")
        }
        // GUI launches may have closed standard descriptors. Keep pipe descriptors above 2 so
        // later close actions cannot accidentally close a just-duplicated stdout/stderr target.
        for index in output.indices where output[index] <= STDERR_FILENO {
            let elevated = fcntl(output[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard elevated >= 0 else { for fd in output + errors { close(fd) }; throw CoincideError("Could not configure Git output pipes.") }
            close(output[index]); output[index] = elevated
        }
        for index in errors.indices where errors[index] <= STDERR_FILENO {
            let elevated = fcntl(errors[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard elevated >= 0 else { for fd in output + errors { close(fd) }; throw CoincideError("Could not configure Git output pipes.") }
            close(errors[index]); errors[index] = elevated
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        let actionsError = posix_spawn_file_actions_init(&actions), attributesError = posix_spawnattr_init(&attributes)
        guard actionsError == 0, attributesError == 0 else {
            if actionsError == 0 { posix_spawn_file_actions_destroy(&actions) }
            if attributesError == 0 { posix_spawnattr_destroy(&attributes) }
            for fd in output + errors { close(fd) }
            throw CoincideError("Could not configure the owned Git process.")
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for fd in output + errors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var setupErrors = [posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                           posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO),
                           posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)]
        for fd in output + errors { setupErrors.append(posix_spawn_file_actions_addclose(&actions, fd)) }
        setupErrors.append(posix_spawn_file_actions_addfchdir_np(&actions, cwdFD))
        var mask = sigset_t(); sigemptyset(&mask); setupErrors.append(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t(); sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaults, signal) }
        setupErrors.append(posix_spawnattr_setsigdefault(&attributes, &defaults))
        // A fresh session also creates a group with the child's PID and removes the controlling
        // terminal. CLOEXEC_DEFAULT prevents inheriting unrelated SQLite, PTY, or provider handles.
        setupErrors.append(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        guard setupErrors.allSatisfy({ $0 == 0 }) else {
            for fd in output + errors { close(fd) }; throw CoincideError("Could not isolate the owned Git process.")
        }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let env = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + env { free(pointer) } }
        var child: pid_t = 0
        let failure = argv.withUnsafeBufferPointer { argumentBuffer in env.withUnsafeBufferPointer { environmentBuffer in
            posix_spawn(&child, executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: argumentBuffer.baseAddress!), UnsafeMutablePointer(mutating: environmentBuffer.baseAddress!))
        } }
        close(output[1]); close(errors[1])
        guard failure == 0 else { close(output[0]); close(errors[0]); throw CoincideError("Git could not be launched (system error \(failure)).") }
        pid = child; let ownedPID = child
        let drained = DispatchGroup(); drained.enter(); drained.enter()
        let outFD = output[0], errFD = errors[0], eventBuffer = buffer, readerState = readers
        // stdout is not a Git progress channel. Drain it independently so partial stdout lines
        // cannot splice into stderr's progress or user-facing failure detail.
        DispatchQueue.global(qos: .utility).async { Self.drain(outFD, state: readerState) { _ in }; drained.leave() }
        DispatchQueue.global(qos: .utility).async {
            Self.drain(errFD, state: readerState) { bytes in if eventBuffer.reserve() { continuation.yield(.stderr(bytes)) } }
            drained.leave()
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            // Keep the leader waitable until every inherited pipe closes. This reserves its PID
            // while a cancelled SSH/HTTP descendant is being killed; a delayed escalation can
            // never target an unrelated process group that reused a reaped leader's number.
            var information = siginfo_t(), observed: Int32
            repeat { observed = testHooks?.observeExit(ownedPID) ?? waitid(P_PID, id_t(ownedPID), &information, WEXITED | WNOWAIT) } while observed == -1 && errno == EINTR
            if observed == -1 {
                // ECHILD or any unexpected wait error removes proof that this PID still names
                // our child. Disable all signals; closing only our readers cannot affect a reused PID.
                lock.withLock { signalAllowed = false }; eventBuffer.discard(); readerState.shutdown()
            }
            drained.wait()
            lock.lock()
            signalAllowed = false
            var raw: Int32 = 0, result: pid_t = -1
            if observed == 0 { repeat { result = waitpid(ownedPID, &raw, 0) } while result == -1 && errno == EINTR }
            let code: Int32 = result == -1 ? 255 : ((raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f))
            status = code; let pending = waiters; waiters = []; lock.unlock()
            continuation.yield(.exited(code)); continuation.finish()
            for waiter in pending { waiter.resume(returning: code) }
        }
    }
    func waitForExit() async -> Int32 {
        await withCheckedContinuation { waiter in
            let finished = lock.withLock { () -> Int32? in if let status { return status }; waiters.append(waiter); return nil }
            if let finished { waiter.resume(returning: finished) }
        }
    }
    func consumedEvent() { buffer.consumed() }
    func stop() {
        // A cancelled AsyncStream consumer stops pulling immediately. Wake blocked producers
        // and drain/discard subsequent output so shutdown never waits on a full progress queue.
        buffer.discard()
        let shouldStop = lock.withLock { () -> Bool in guard status == nil, !stopping, signalAllowed else { return false }; stopping = true; signalGroup(SIGTERM); return true }
        guard shouldStop else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            lock.withLock { if status == nil, signalAllowed { signalGroup(SIGKILL) } }
            // Even a deliberately detached helper may retain an inherited pipe. Shutdown closes
            // only our read descriptors on their owner threads; it never signals unknown processes.
            readers.shutdown()
        }
    }
    private func signalGroup(_ signal: Int32) {
        if let testHooks { testHooks.signalGroup(pid, signal) } else { _ = kill(-pid, signal) }
    }
    private static func drain(_ fd: Int32, state: CloneReaderState, emit: (Data) -> Void) {
        defer { close(fd) }; var bytes = [UInt8](repeating: 0, count: 65_536)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        while !state.isShutdown {
            var readiness = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&readiness, 1, 100)
            if ready == 0 || (ready == -1 && errno == EINTR) { continue }
            guard ready > 0, !state.isShutdown else { return }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { emit(Data(bytes.prefix(count))) }
            else if count == -1 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            else { return }
        }
    }
}

private final class CloneReaderState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isShutdown: Bool { lock.withLock { stopped } }
    func shutdown() { lock.withLock { stopped = true } }
}

private final class CloneEventBuffer: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending = 0
    private var discarding = false
    func reserve() -> Bool {
        condition.lock(); defer { condition.unlock() }
        while pending >= 16 && !discarding { condition.wait() }
        guard !discarding else { return false }; pending += 1; return true
    }
    func consumed() {
        condition.lock(); pending = max(0, pending - 1); condition.broadcast(); condition.unlock()
    }
    func discard() {
        condition.lock(); discarding = true; pending = 0; condition.broadcast(); condition.unlock()
    }
}
