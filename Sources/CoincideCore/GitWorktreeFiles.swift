import Darwin
import Foundation

func worktreeIdentity(_ value: stat) -> GitWorktreeNodeIdentity {
    .init(device: UInt64(truncatingIfNeeded: value.st_dev), inode: value.st_ino)
}
func worktreeFileFailure(_ message: String = "The worktree filesystem operation failed.") -> GitWorktreeError { .init(.ownershipLost, message) }
private func worktreeFD(_ value: Int32) throws -> Int32 {
    guard value >= 0 else { throw worktreeFileFailure() }
    if value > STDERR_FILENO { return value }
    let copy = fcntl(value, F_DUPFD_CLOEXEC, STDERR_FILENO + 1); Darwin.close(value)
    guard copy >= 0 else { throw worktreeFileFailure() }; return copy
}

final class GitWorktreeDirectory: @unchecked Sendable {
    let path: String
    let fd: Int32
    let identity: GitWorktreeNodeIdentity
    init(path: String) throws {
        try WorktreeValidation.path(path)
        var named = stat()
        guard lstat(path, &named) == 0, named.st_mode & S_IFMT == S_IFDIR else { throw worktreeFileFailure("A worktree folder is missing, replaced, or inaccessible.") }
        let opened = try worktreeFD(Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        var value = stat()
        guard fstat(opened, &value) == 0, worktreeIdentity(value) == worktreeIdentity(named) else { Darwin.close(opened); throw worktreeFileFailure() }
        self.path = path; fd = opened; identity = worktreeIdentity(value)
    }
    init(child name: String, parent: GitWorktreeDirectory) throws {
        try parent.validate()
        let opened = try worktreeFD(openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        var value = stat(), named = stat()
        guard fstat(opened, &value) == 0, fstatat(parent.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              value.st_mode & S_IFMT == S_IFDIR, worktreeIdentity(value) == worktreeIdentity(named) else { Darwin.close(opened); throw worktreeFileFailure() }
        path = URL(fileURLWithPath: parent.path).appendingPathComponent(name).path; fd = opened; identity = worktreeIdentity(value)
    }
    deinit { Darwin.close(fd) }
    func validate(expected: GitWorktreeNodeIdentity? = nil) throws {
        var named = stat(), opened = stat()
        guard lstat(path, &named) == 0, fstat(fd, &opened) == 0, named.st_mode & S_IFMT == S_IFDIR,
              worktreeIdentity(named) == identity, worktreeIdentity(opened) == identity, expected == nil || expected == identity else {
            throw worktreeFileFailure("A worktree folder was moved or replaced. Existing branches and files were preserved.")
        }
    }
    func exists(_ name: String) throws -> Bool {
        var value = stat()
        if fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw worktreeFileFailure() }; return false
    }
    func claimDirectory(_ name: String) throws -> GitWorktreeDirectory {
        try validate(); try Task.checkCancellation()
        guard mkdirat(fd, name, 0o700) == 0 else {
            if errno == EEXIST { throw GitWorktreeError(.destinationExists, "The worktree destination already exists. Its files were preserved; choose a new attempt or an explicitly registered worktree.") }
            throw worktreeFileFailure("The managed worktree destination could not be created.")
        }
        _ = fsync(fd)
        return try .init(child: name, parent: self)
    }
    func read(_ name: String, maximum: Int = 131_072) throws -> Data? {
        try validate()
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw GitWorktreeError(.metadataCorrupt, "Worktree ownership metadata cannot be read safely. Existing files were preserved.") }
        defer { Darwin.close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0, before.st_size <= maximum else {
            throw GitWorktreeError(.metadataCorrupt, "Worktree ownership metadata is invalid. Existing files were preserved.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: min(maximum + 1, 65_536))
        while data.count <= maximum {
            try Task.checkCancellation()
            let count = Darwin.read(file, &buffer, min(buffer.count, maximum + 1 - data.count))
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw worktreeFileFailure() }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), named = stat()
        guard data.count <= maximum, fstat(file, &after) == 0, fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              worktreeIdentity(before) == worktreeIdentity(after), worktreeIdentity(named) == worktreeIdentity(after),
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw worktreeFileFailure("Worktree ownership metadata changed while it was read.") }
        try validate(); return data
    }
    func writeExclusive(_ data: Data, name: String) throws {
        guard data.count <= 131_072 else { throw GitWorktreeError(.metadataCorrupt, "Worktree ownership metadata exceeds its size limit.") }
        try validate(); try Task.checkCancellation()
        let temporary = ".coincide-worktree-write-" + UUID().uuidString
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw worktreeFileFailure() }
        var owned = stat(); _ = fstat(file, &owned)
        var promoted = false
        defer {
            Darwin.close(file)
            if !promoted {
                var named = stat()
                if fstatat(fd, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0, worktreeIdentity(named) == worktreeIdentity(owned) { _ = unlinkat(fd, temporary, 0) }
            }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                if count < 0 { if errno == EINTR { continue }; throw worktreeFileFailure() }
                guard count > 0 else { throw worktreeFileFailure() }; offset += count
            }
        }
        guard fsync(file) == 0 else { throw worktreeFileFailure() }
        try validate(); try Task.checkCancellation()
        guard renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL)) == 0 else {
            throw GitWorktreeError(.destinationExists, "Worktree ownership metadata already exists. No existing file was replaced.")
        }
        promoted = true
        guard fsync(fd) == 0 else { throw worktreeFileFailure("The worktree ownership record could not be made durable.") }
    }
    func lock(_ name: String) throws -> GitWorktreeLock {
        try validate()
        let file = openat(fd, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw worktreeFileFailure() }
        var value = stat()
        guard fstat(file, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size == 0 else {
            Darwin.close(file); throw GitWorktreeError(.metadataCorrupt, "The worktree attempt lock is not an empty regular file. It was preserved.")
        }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(file); throw GitWorktreeError(.busy, "This worktree attempt is already running.") }
        return .init(fd: file)
    }
}

final class GitWorktreeLock: @unchecked Sendable {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
    deinit { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
}

struct GitWorktreeOwnership: Codable, Sendable {
    let plan: GitWorktreePlan
    let destinationIdentity: GitWorktreeNodeIdentity
    static func filename(_ id: UUID) -> String { ".coincide-worktree-" + id.uuidString + ".json" }
    static func lockname(_ id: UUID) -> String { ".coincide-worktree-" + id.uuidString + ".lock" }
}

struct GitWorktreeCompletion: Codable, Sendable {
    let ownership: GitWorktreeOwnership
    let result: GitWorktreeResult
    let gitDirectoryPath: String
    let gitDirectoryIdentity: GitWorktreeNodeIdentity
    static func filename(_ id: UUID) -> String { ".coincide-worktree-" + id.uuidString + ".complete.json" }
}
