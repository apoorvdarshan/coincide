import CryptoKit
import Darwin
import Foundation

struct AntigravityInstalledFile: Codable, Sendable, Equatable {
    let device: UInt64, inode: UInt64, bytes: Int64
    let modifiedSeconds: Int64, modifiedNanoseconds: Int64, changedSeconds: Int64, changedNanoseconds: Int64
    let digest: String
    init(_ value: stat, digest: String) {
        device = UInt64(truncatingIfNeeded: value.st_dev); inode = value.st_ino; bytes = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec); self.digest = digest
    }
    func matches(_ value: stat) -> Bool { Self(value, digest: digest) == self }
}

/// Retained descriptors are used for publication/removal. A replaced directory
/// cannot redirect cleanup to a later user-created path.
final class AntigravityInstallDirectory: @unchecked Sendable {
    let anchor: GitWorktreeDirectory
    var url: URL { URL(fileURLWithPath: anchor.path, isDirectory: true) }
    var fd: Int32 { anchor.fd }
    init(_ url: URL) throws {
        anchor = try GitWorktreeDirectory(path: url.path)
        var value = stat()
        guard fstat(anchor.fd, &value) == 0, value.st_uid == geteuid() else { throw AntigravityInstallationError(.ownershipLost) }
    }
    init(child: String, parent: AntigravityInstallDirectory) throws {
        try Self.name(child); anchor = try GitWorktreeDirectory(child: child, parent: parent.anchor)
        var value = stat()
        guard fstat(anchor.fd, &value) == 0, value.st_uid == geteuid() else { throw AntigravityInstallationError(.ownershipLost) }
    }
    func validate() throws { try anchor.validate() }
    func exists(_ name: String) throws -> Bool { try Self.name(name); return try anchor.exists(name) }
    func create(_ name: String) throws -> AntigravityInstallDirectory {
        try Self.name(name); try validate()
        guard mkdirat(fd, name, 0o700) == 0 else { throw AntigravityInstallationError(.publicationFailed) }
        return try .init(child: name, parent: self)
    }
    func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try Self.name(name)
        guard let data = try anchor.read(name, maximum: 8_192) else { throw AntigravityInstallationError(.invalidRecord) }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw AntigravityInstallationError(.invalidRecord) }
    }
    func readSealed<T: Decodable>(_ type: T.Type, _ name: String) throws -> (value: T, proof: AntigravityInstalledFile) {
        try Self.name(name)
        guard let data = try anchor.read(name, maximum: 8_192) else { throw AntigravityInstallationError(.invalidRecord) }
        let proof = try installedFile(name, bytes: Int64(data.count), seal: true, executable: false)
        guard proof.digest == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() else { throw AntigravityInstallationError(.ownershipLost) }
        do { return (try JSONDecoder().decode(type, from: data), proof) }
        catch { throw AntigravityInstallationError(.invalidRecord) }
    }
    func write<T: Encodable>(_ value: T, _ name: String) throws {
        try Self.name(name); let data = try JSONEncoder().encode(value)
        guard data.count <= 8_192 else { throw AntigravityInstallationError(.invalidRecord) }
        try anchor.writeExclusive(data, name: name)
    }
    /// No cancellation check after the pointer rename: activation is committed.
    func replace<T: Encodable>(_ value: T, _ name: String) throws {
        try Self.name(name); try validate()
        let temporary = ".pointer-" + UUID().uuidString.lowercased()
        try write(value, temporary)
        defer { _ = unlinkat(fd, temporary, 0) }
        try validate()
        guard renameat(fd, temporary, fd, name) == 0 else { throw AntigravityInstallationError(.publicationFailed) }
        _ = fsync(fd)
    }
    func list() throws -> [String] {
        try validate()
        // openat rather than dup gives this enumeration an independent offset.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; throw AntigravityInstallationError(.ownershipLost) }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) } }
            guard let name else { throw AntigravityInstallationError(.ownershipLost) }
            if name == "." || name == ".." { continue }
            guard result.count < 8_192 else { throw AntigravityInstallationError(.invalidRecord) }; result.append(name)
        }
        try validate(); return result
    }
    func installedFile(_ name: String, bytes: Int64, seal: Bool, proof: AntigravityInstalledFile? = nil, executable: Bool = true) throws -> AntigravityInstalledFile {
        try Self.name(name); try validate()
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw AntigravityInstallationError(.invalidRecord) }; defer { Darwin.close(file) }
        var before = stat(), named = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(), before.st_size == bytes,
              (!executable || before.st_mode & 0o111 != 0), proof == nil || proof?.matches(before) == true else { throw AntigravityInstallationError(.invalidRecord) }
        var digest = proof?.digest ?? "", total: Int64 = 0
        if seal {
            var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try Task.checkCancellation()
                let count = Darwin.read(file, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw AntigravityInstallationError(.invalidRecord) }; if count == 0 { break }
                total += Int64(count); guard total <= bytes else { throw AntigravityInstallationError(.invalidRecord) }
                hash.update(data: Data(buffer.prefix(count)))
            }
            guard total == bytes else { throw AntigravityInstallationError(.invalidRecord) }
            digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var after = stat()
        guard digest.count == 64, fstat(file, &after) == 0, fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              AntigravityInstalledFile(before, digest: digest).matches(after), AntigravityInstalledFile(after, digest: digest).matches(named) else { throw AntigravityInstallationError(.ownershipLost) }
        try validate(); return .init(after, digest: digest)
    }
    func publish(_ child: AntigravityInstallDirectory, from parent: AntigravityInstallDirectory, as name: String) throws {
        try Self.name(name); try validate(); try parent.validate(); try child.validate()
        guard renameatx_np(parent.fd, child.url.lastPathComponent, fd, name, UInt32(RENAME_EXCL)) == 0 else { throw AntigravityInstallationError(.publicationFailed) }
        _ = fsync(fd)
    }
    func remove(_ child: AntigravityInstallDirectory) throws {
        try validate(); try child.validate()
        guard child.url.deletingLastPathComponent().path == url.path else { throw AntigravityInstallationError(.ownershipLost) }
        var remaining = 16_384
        try Self.empty(child.fd, depth: 0, remaining: &remaining)
        try validate(); try child.validate()
        guard unlinkat(fd, child.url.lastPathComponent, AT_REMOVEDIR) == 0 else { throw AntigravityInstallationError(.ownershipLost) }
    }
    func removeEmpty(_ child: AntigravityInstallDirectory) throws {
        try validate(); try child.validate()
        guard child.url.deletingLastPathComponent().path == url.path,
              unlinkat(fd, child.url.lastPathComponent, AT_REMOVEDIR) == 0 else { throw AntigravityInstallationError(.ownershipLost) }
    }
    private static func empty(_ fd: Int32, depth: Int, remaining: inout Int) throws {
        guard depth < 64 else { throw AntigravityInstallationError(.ownershipLost) }
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; throw AntigravityInstallationError(.ownershipLost) }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) } }
            guard let name else { throw AntigravityInstallationError(.ownershipLost) }; if name == "." || name == ".." { continue }
            remaining -= 1; guard remaining >= 0 else { throw AntigravityInstallationError(.ownershipLost) }
            var value = stat(); guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw AntigravityInstallationError(.ownershipLost) }
            if value.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard child >= 0 else { throw AntigravityInstallationError(.ownershipLost) }
                do {
                    var opened = stat(); guard fstat(child, &opened) == 0, opened.st_ino == value.st_ino, opened.st_dev == value.st_dev else { throw AntigravityInstallationError(.ownershipLost) }
                    try empty(child, depth: depth + 1, remaining: &remaining)
                    var final = stat(); guard fstatat(fd, name, &final, AT_SYMLINK_NOFOLLOW) == 0, final.st_ino == opened.st_ino, final.st_dev == opened.st_dev,
                        unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw AntigravityInstallationError(.ownershipLost) }
                    Darwin.close(child)
                } catch { Darwin.close(child); throw error }
            } else {
                // Unlink a link itself; never traverse provider-created redirects.
                guard unlinkat(fd, name, 0) == 0 else { throw AntigravityInstallationError(.ownershipLost) }
            }
        }
    }
    static func name(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw AntigravityInstallationError(.invalidRecord) }
    }
}

final class AntigravityInstallationLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32
    init(_ directory: AntigravityInstallDirectory, name: String, shared: Bool, create: Bool = false) throws {
        try directory.validate(); try AntigravityInstallDirectory.name(name)
        descriptor = openat(directory.fd, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        guard descriptor >= 0 else { throw AntigravityInstallationError(.ownershipLost) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size == 0, value.st_uid == geteuid() else {
            Darwin.close(descriptor); descriptor = -1; throw AntigravityInstallationError(.ownershipLost)
        }
        guard flock(descriptor, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1; throw AntigravityInstallationError(.busy)
        }
    }
    func release() { mutex.withLock { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 } } }
    deinit { release() }
}
