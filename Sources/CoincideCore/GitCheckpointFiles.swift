import CryptoKit
import Darwin
import Foundation

/// Checkpoint-specific reads use the same retained directory anchors as worktree creation.
/// The real index is only read; all writes use a fresh, app-owned alternate index.
enum CheckpointFiles {
    static let maximumIndexBytes = 67_108_864
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func index(_ admin: GitWorktreeDirectory, name: String = "index", maximum: Int = maximumIndexBytes) throws -> GitCheckpointIndexRevision? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              (0...maximumIndexBytes).contains(maximum) else { throw GitCheckpointError(.invalidPlan) }
        try admin.validate()
        let fd = openat(admin.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw GitCheckpointError(.ownershipLost) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximum else { throw GitCheckpointError(.unsupportedConfiguration) }
        var hash = SHA256(), count = 0, buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let read = Darwin.read(fd, &buffer, buffer.count)
            if read == 0 { break }
            if read < 0 { if errno == EINTR { continue }; throw GitCheckpointError(.ownershipLost) }
            count += read
            guard count <= maximum else { throw GitCheckpointError(.outputLimit) }
            hash.update(data: Data(buffer.prefix(read)))
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, fstatat(admin.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              worktreeIdentity(before) == worktreeIdentity(after), worktreeIdentity(after) == worktreeIdentity(named),
              before.st_size == count, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw GitCheckpointError(.configurationChanged)
        }
        try admin.validate()
        return .init(identity: worktreeIdentity(after), byteLength: Int64(count), modifiedSeconds: Int64(after.st_mtimespec.tv_sec),
                     modifiedNanoseconds: Int64(after.st_mtimespec.tv_nsec), digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func emptyIndex(format: String) -> Data {
        var data = Data([0x44, 0x49, 0x52, 0x43, 0, 0, 0, 2, 0, 0, 0, 0])
        if format == "sha256" { data.append(contentsOf: SHA256.hash(data: data)) }
        else { data.append(contentsOf: Insecure.SHA1.hash(data: data)) }
        return data
    }
    static func claimIndex(_ data: Data, name: String, admin: GitWorktreeDirectory) throws {
        guard data.count <= maximumIndexBytes else { throw GitCheckpointError(.outputLimit) }
        try admin.validate(); try Task.checkCancellation()
        let fd = openat(admin.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GitCheckpointError(.refCollision) }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                if count < 0 { if errno == EINTR { continue }; throw GitCheckpointError(.ownershipLost) }
                guard count > 0 else { throw GitCheckpointError(.ownershipLost) }; offset += count
            }
        }
        guard fsync(fd) == 0, fsync(admin.fd) == 0 else { throw GitCheckpointError(.ownershipLost) }
        try admin.validate()
    }
    static func makeRacy(_ name: String, admin: GitWorktreeDirectory, before revision: GitCheckpointIndexRevision) throws {
        guard revision.modifiedSeconds > 1 else { throw GitCheckpointError(.unsupportedConfiguration) }
        try admin.validate()
        let fd = openat(admin.fd, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw GitCheckpointError(.ownershipLost) }; defer { close(fd) }
        var node = stat(), named = stat()
        guard fstat(fd, &node) == 0, node.st_mode & S_IFMT == S_IFREG,
              fstatat(admin.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0, worktreeIdentity(node) == worktreeIdentity(named) else { throw GitCheckpointError(.ownershipLost) }
        var times = [timeval(tv_sec: Int(revision.modifiedSeconds - 1), tv_usec: 0), timeval(tv_sec: Int(revision.modifiedSeconds - 1), tv_usec: 0)]
        guard futimes(fd, &times) == 0 else { throw GitCheckpointError(.ownershipLost) }
        try admin.validate()
    }
    static func input(_ data: Data, metadata: GitWorktreeDirectory) throws -> Int32 {
        let name = "rules-" + UUID().uuidString + ".input"
        try metadata.writeExclusive(data, name: name)
        let fd = openat(metadata.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw GitCheckpointError(.ownershipLost) }
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_size == data.count,
              fstatat(metadata.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0, worktreeIdentity(opened) == worktreeIdentity(named) else {
            close(fd); throw GitCheckpointError(.ownershipLost)
        }
        // The open descriptor retains our input bytes, so no named scratch input needs to remain.
        guard unlinkat(metadata.fd, name, 0) == 0 else { close(fd); throw GitCheckpointError(.ownershipLost) }
        return fd
    }
    static func metadataName(_ id: UUID) -> String { ".coincide-checkpoint-" + id.uuidString }
    static func indexName(_ id: UUID) -> String { metadataName(id) + ".index" }
    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    static func line(_ data: Data) throws -> String {
        guard var value = String(data: data, encoding: .utf8), !value.contains("\0"), value.utf8.count <= 16_384 else { throw GitCheckpointError(.commandFailed) }
        if value.hasSuffix("\n") { value.removeLast() }
        guard !value.isEmpty else { throw GitCheckpointError(.commandFailed) }; return value
    }
    static func names(_ data: Data) throws -> [String] {
        guard data.isEmpty || data.last == 0 else { throw GitCheckpointError(.commandFailed) }
        return try data.split(separator: 0, omittingEmptySubsequences: true).map {
            guard let name = String(data: $0, encoding: .utf8), !name.isEmpty else { throw GitCheckpointError(.unsupportedConfiguration) }
            return name
        }
    }
    static func relative(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !components.contains(where: { $0.lowercased() == ".git" }) else { throw GitCheckpointError(.invalidPlan) }
    }
}
