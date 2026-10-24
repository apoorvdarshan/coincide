import CryptoKit
import Darwin
import Foundation

struct CodexInstalledFile: Codable, Sendable, Equatable {
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
final class CodexInstallStorage: @unchecked Sendable {
    let anchor: GitWorktreeDirectory
    var url: URL { URL(fileURLWithPath: anchor.path, isDirectory: true) }
    var fd: Int32 { anchor.fd }
    init(_ url: URL) throws {
        anchor = try GitWorktreeDirectory(path: url.path)
        var value = stat()
        guard fstat(anchor.fd, &value) == 0, value.st_uid == geteuid() else { throw CodexInstallationError(.ownershipLost) }
    }
    init(child: String, parent: CodexInstallStorage) throws {
        try Self.name(child); anchor = try GitWorktreeDirectory(child: child, parent: parent.anchor)
        var value = stat()
        guard fstat(anchor.fd, &value) == 0, value.st_uid == geteuid() else { throw CodexInstallationError(.ownershipLost) }
    }
    func validate() throws { try anchor.validate() }
    func exists(_ name: String) throws -> Bool { try Self.name(name); return try anchor.exists(name) }
    func create(_ name: String) throws -> CodexInstallStorage {
        try Self.name(name); try validate()
        guard mkdirat(fd, name, 0o700) == 0 else { throw CodexInstallationError(.ownershipLost) }
        return try .init(child: name, parent: self)
    }
    func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try Self.name(name)
        guard let data = try anchor.read(name, maximum: 8_192) else { throw CodexInstallationError(.invalidRecord) }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw CodexInstallationError(.invalidRecord) }
    }
    func readSealed<T: Decodable>(_ type: T.Type, _ name: String) throws -> (value: T, proof: CodexInstalledFile) {
        try Self.name(name)
        guard let data = try anchor.read(name, maximum: 8_192) else { throw CodexInstallationError(.invalidRecord) }
        let proof = try installedFile(name, bytes: Int64(data.count), seal: true, executable: false)
        guard proof.digest == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() else { throw CodexInstallationError(.ownershipLost) }
        do { return (try JSONDecoder().decode(type, from: data), proof) }
        catch { throw CodexInstallationError(.invalidRecord) }
    }
    func write<T: Encodable>(_ value: T, _ name: String) throws {
        try Self.name(name); let data = try JSONEncoder().encode(value)
        guard data.count <= 8_192 else { throw CodexInstallationError(.invalidRecord) }
        try anchor.writeExclusive(data, name: name)
    }
    /// No cancellation check after the pointer rename: activation is committed.
    func replace<T: Encodable>(_ value: T, _ name: String) throws {
        try Self.name(name); try validate()
        let temporary = ".pointer-" + UUID().uuidString.lowercased()
        try write(value, temporary)
        defer { _ = unlinkat(fd, temporary, 0) }
        try validate()
        guard renameat(fd, temporary, fd, name) == 0 else { throw CodexInstallationError(.ownershipLost) }
        _ = fsync(fd)
    }
    func list() throws -> [String] {
        try validate()
        // openat rather than dup gives this enumeration an independent offset.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; throw CodexInstallationError(.ownershipLost) }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) } }
            guard let name else { throw CodexInstallationError(.ownershipLost) }
            if name == "." || name == ".." { continue }
            guard result.count < 8_192 else { throw CodexInstallationError(.invalidRecord) }; result.append(name)
        }
        try validate(); return result
    }
    func installedFile(_ name: String, bytes: Int64, seal: Bool, proof: CodexInstalledFile? = nil, executable: Bool = true) throws -> CodexInstalledFile {
        try Self.name(name); try validate()
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw CodexInstallationError(.invalidRecord) }; defer { Darwin.close(file) }
        var before = stat(), named = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(), before.st_size == bytes,
              (!executable || before.st_mode & 0o111 != 0), proof == nil || proof?.matches(before) == true else { throw CodexInstallationError(.invalidRecord) }
        var digest = proof?.digest ?? "", total: Int64 = 0
        if seal {
            var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try Task.checkCancellation()
                let count = Darwin.read(file, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw CodexInstallationError(.invalidRecord) }; if count == 0 { break }
                total += Int64(count); guard total <= bytes else { throw CodexInstallationError(.invalidRecord) }
                hash.update(data: Data(buffer.prefix(count)))
            }
            guard total == bytes else { throw CodexInstallationError(.invalidRecord) }
            digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var after = stat()
        guard digest.count == 64, fstat(file, &after) == 0, fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              CodexInstalledFile(before, digest: digest).matches(after), CodexInstalledFile(after, digest: digest).matches(named) else { throw CodexInstallationError(.ownershipLost) }
        try validate(); return .init(after, digest: digest)
    }
    func publish(_ child: CodexInstallStorage, from parent: CodexInstallStorage, as name: String) throws {
        try Self.name(name); try validate(); try parent.validate(); try child.validate()
        guard renameatx_np(parent.fd, child.url.lastPathComponent, fd, name, UInt32(RENAME_EXCL)) == 0 else { throw CodexInstallationError(.ownershipLost) }
        _ = fsync(fd)
    }
    func remove(_ child: CodexInstallStorage) throws {
        try validate(); try child.validate()
        guard child.url.deletingLastPathComponent().path == url.path else { throw CodexInstallationError(.ownershipLost) }
        var remaining = 16_384
        try Self.empty(child.fd, depth: 0, remaining: &remaining)
        try validate(); try child.validate()
        guard unlinkat(fd, child.url.lastPathComponent, AT_REMOVEDIR) == 0 else { throw CodexInstallationError(.ownershipLost) }
    }
    func removeEmpty(_ child: CodexInstallStorage) throws {
        try validate(); try child.validate()
        guard child.url.deletingLastPathComponent().path == url.path,
              unlinkat(fd, child.url.lastPathComponent, AT_REMOVEDIR) == 0 else { throw CodexInstallationError(.ownershipLost) }
    }
    private static func empty(_ fd: Int32, depth: Int, remaining: inout Int) throws {
        guard depth < 64 else { throw CodexInstallationError(.ownershipLost) }
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; throw CodexInstallationError(.ownershipLost) }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) } }
            guard let name else { throw CodexInstallationError(.ownershipLost) }; if name == "." || name == ".." { continue }
            remaining -= 1; guard remaining >= 0 else { throw CodexInstallationError(.ownershipLost) }
            var value = stat(); guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw CodexInstallationError(.ownershipLost) }
            if value.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard child >= 0 else { throw CodexInstallationError(.ownershipLost) }
                do {
                    var opened = stat(); guard fstat(child, &opened) == 0, opened.st_ino == value.st_ino, opened.st_dev == value.st_dev else { throw CodexInstallationError(.ownershipLost) }
                    try empty(child, depth: depth + 1, remaining: &remaining)
                    var final = stat(); guard fstatat(fd, name, &final, AT_SYMLINK_NOFOLLOW) == 0, final.st_ino == opened.st_ino, final.st_dev == opened.st_dev,
                        unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw CodexInstallationError(.ownershipLost) }
                    Darwin.close(child)
                } catch { Darwin.close(child); throw error }
            } else {
                // Unlink a link itself; never traverse provider-created redirects.
                guard unlinkat(fd, name, 0) == 0 else { throw CodexInstallationError(.ownershipLost) }
            }
        }
    }
    static func name(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw CodexInstallationError(.invalidRecord) }
    }
}

final class CodexInstallStorageLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32
    init(_ directory: CodexInstallStorage, name: String, shared: Bool, create: Bool = false) throws {
        try directory.validate(); try CodexInstallStorage.name(name)
        descriptor = openat(directory.fd, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        guard descriptor >= 0 else { throw CodexInstallationError(.ownershipLost) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size == 0, value.st_uid == geteuid() else {
            Darwin.close(descriptor); descriptor = -1; throw CodexInstallationError(.ownershipLost)
        }
        guard flock(descriptor, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1; throw CodexInstallationError(.busy)
        }
    }
    func release() { mutex.withLock { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 } } }
    deinit { release() }
}

/// Wraps the descriptor operations so every failure is a Codex installation
/// error. Package inventory below is Codex-specific and includes all resources.
final class CodexInstallDirectory: @unchecked Sendable {
    let storage: CodexInstallStorage
    var url: URL { storage.url }
    var fd: Int32 { storage.fd }
    init(_ url: URL) throws { storage = try Self.convert { try CodexInstallStorage(url) } }
    init(child: String, parent: CodexInstallDirectory) throws { storage = try Self.convert { try CodexInstallStorage(child: child, parent: parent.storage) } }
    private init(_ storage: CodexInstallStorage) { self.storage = storage }
    static func convert<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as CodexInstallationError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw CodexInstallationError(.ownershipLost) }
    }
    func validate() throws { try Self.convert { try storage.validate() } }
    func exists(_ name: String) throws -> Bool { try Self.convert { try storage.exists(name) } }
    func create(_ name: String) throws -> CodexInstallDirectory { try Self.convert { .init(try storage.create(name)) } }
    func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T { try Self.convert { try storage.read(type, name) } }
    func readSealed<T: Decodable>(_ type: T.Type, _ name: String) throws -> (value: T, proof: CodexInstalledFile) { try Self.convert { try storage.readSealed(type, name) } }
    func write<T: Encodable>(_ value: T, _ name: String) throws { try Self.convert { try storage.write(value, name) } }
    func replace<T: Encodable>(_ value: T, _ name: String) throws { try Self.convert { try storage.replace(value, name) } }
    func list() throws -> [String] { try Self.convert { try storage.list() } }
    func file(_ name: String, bytes: Int64, seal: Bool, proof: CodexInstalledFile? = nil, executable: Bool = false) throws -> CodexInstalledFile {
        try Self.convert { try storage.installedFile(name, bytes: bytes, seal: seal, proof: proof, executable: executable) }
    }
    func publish(_ child: CodexInstallDirectory, from parent: CodexInstallDirectory, as name: String) throws {
        try Self.convert { try storage.publish(child.storage, from: parent.storage, as: name) }
    }
    func remove(_ child: CodexInstallDirectory) throws { try Self.convert { try storage.remove(child.storage) } }
    func removeEmpty(_ child: CodexInstallDirectory) throws { try Self.convert { try storage.removeEmpty(child.storage) } }
    func writeInventory(_ value: CodexPackageInventory) throws -> CodexInstalledFile {
        let data = try JSONEncoder().encode(value)
        guard !data.isEmpty, data.count <= 16_777_216 else { throw CodexInstallationError(.invalidRecord) }
        try validate()
        let name = CodexPackageInventory.filename
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw CodexInstallationError(.ownershipLost) }; defer { Darwin.close(file) }
        try data.withUnsafeBytes { bytes in
            var at = 0
            while at < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: at), min(65_536, bytes.count - at))
                if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw CodexInstallationError(.ownershipLost) }; at += count
            }
        }
        guard fsync(file) == 0 else { throw CodexInstallationError(.ownershipLost) }
        return try self.file(name, bytes: Int64(data.count), seal: true)
    }
    func readInventory(proof: CodexInstalledFile) throws -> CodexPackageInventory {
        guard proof.bytes > 0, proof.bytes <= 16_777_216 else { throw CodexInstallationError(.invalidRecord) }
        _ = try file(CodexPackageInventory.filename, bytes: proof.bytes, seal: false, proof: proof)
        guard let data = try Self.convert({ try storage.anchor.read(CodexPackageInventory.filename, maximum: 16_777_216) }),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == proof.digest else { throw CodexInstallationError(.invalidRecord) }
        _ = try file(CodexPackageInventory.filename, bytes: proof.bytes, seal: false, proof: proof)
        do { return try JSONDecoder().decode(CodexPackageInventory.self, from: data) } catch { throw CodexInstallationError(.invalidRecord) }
    }
}

final class CodexInstallLock: @unchecked Sendable {
    private let storage: CodexInstallStorageLock
    init(_ directory: CodexInstallDirectory, name: String, shared: Bool, create: Bool = false) throws {
        storage = try CodexInstallDirectory.convert { try .init(directory.storage, name: name, shared: shared, create: create) }
    }
    func release() { storage.release() }
}

struct CodexPackageInventory: Codable, Sendable {
    static let filename = ".coincide-package-inventory.json"
    static let completion = ".install-complete.json"
    struct Entry: Codable, Sendable, Equatable {
        let path: String
        let directory: GitWorktreeNodeIdentity?
        let file: CodexInstalledFile?
    }
    let entries: [Entry]
    static func seal(_ root: CodexInstallDirectory, release: CodexManagedRelease) throws -> Self {
        let entries = try scan(root, release: release, expected: nil)
        return .init(entries: entries)
    }
    func validate(_ root: CodexInstallDirectory, release: CodexManagedRelease) throws {
        guard entries.count <= 10_000, Set(entries.map(\.path)).count == entries.count else { throw CodexInstallationError(.invalidRecord) }
        let observed = try Self.scan(root, release: release, expected: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) }))
        guard observed == entries else { throw CodexInstallationError(.invalidRecord) }
    }
    func validateForRemoval(_ root: CodexInstallDirectory) throws {
        guard entries.count <= 10_000, Set(entries.map(\.path)).count == entries.count else { throw CodexInstallationError(.invalidRecord) }
        let expected = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        var count = 0
        func visit(_ directory: CodexInstallDirectory, prefix: String, depth: Int) throws {
            guard depth <= 32 else { throw CodexInstallationError(.ownershipLost) }
            for name in try directory.list() {
                count += 1; guard count <= 10_002 else { throw CodexInstallationError(.ownershipLost) }
                var value = stat(); guard fstatat(directory.fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw CodexInstallationError(.ownershipLost) }
                if prefix.isEmpty && [Self.filename, Self.completion].contains(name) {
                    guard value.st_mode & S_IFMT == S_IFREG else { throw CodexInstallationError(.ownershipLost) }; continue
                }
                let path = prefix + name
                guard let entry = expected[path] else { throw CodexInstallationError(.ownershipLost) }
                if value.st_mode & S_IFMT == S_IFDIR {
                    let child = try CodexInstallDirectory(child: name, parent: directory)
                    guard entry.directory == child.storage.anchor.identity else { throw CodexInstallationError(.ownershipLost) }
                    try visit(child, prefix: path + "/", depth: depth + 1)
                } else { guard entry.file != nil, value.st_mode & S_IFMT == S_IFREG else { throw CodexInstallationError(.ownershipLost) } }
            }
        }
        try visit(root, prefix: "", depth: 0)
    }
    private static func scan(_ root: CodexInstallDirectory, release: CodexManagedRelease, expected: [String: Entry]?) throws -> [Entry] {
        var entries: [Entry] = [], total: Int64 = 0
        func visit(_ folder: CodexInstallDirectory, prefix: String, depth: Int) throws {
            guard depth <= 32 else { throw CodexInstallationError(.invalidRecord) }
            for name in try folder.list().sorted() {
                if prefix.isEmpty && [filename, completion].contains(name) {
                    guard expected != nil else { throw CodexInstallationError(.invalidRecord) }; continue
                }
                try Task.checkCancellation()
                let path = prefix + name
                guard entries.count < 10_000, path.utf8.count <= 4_096, !name.contains(":"), !name.contains("\\"), !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw CodexInstallationError(.invalidRecord) }
                var node = stat(); guard fstatat(folder.fd, name, &node, AT_SYMLINK_NOFOLLOW) == 0 else { throw CodexInstallationError(.ownershipLost) }
                if node.st_mode & S_IFMT == S_IFDIR {
                    let child = try CodexInstallDirectory(child: name, parent: folder), identity = child.storage.anchor.identity
                    if let expected { guard expected[path]?.directory == identity, expected[path]?.file == nil else { throw CodexInstallationError(.invalidRecord) } }
                    entries.append(.init(path: path, directory: identity, file: nil)); try visit(child, prefix: path + "/", depth: depth + 1)
                } else {
                    guard node.st_mode & S_IFMT == S_IFREG, node.st_size >= 0, node.st_size <= 4_294_967_296 else { throw CodexInstallationError(.invalidRecord) }
                    total += node.st_size; guard total <= 8_589_934_592 else { throw CodexInstallationError(.invalidRecord) }
                    let required = release.requiredExecutablePaths.contains(path)
                    if required { guard node.st_size > 0 else { throw CodexInstallationError(.invalidRecord) } }
                    if let expected { guard expected[path]?.file != nil, expected[path]?.directory == nil else { throw CodexInstallationError(.invalidRecord) } }
                    let proof = try folder.file(name, bytes: node.st_size, seal: expected == nil, proof: expected?[path]?.file, executable: required)
                    entries.append(.init(path: path, directory: nil, file: proof))
                }
            }
            try folder.validate()
        }
        try visit(root, prefix: "", depth: 0)
        let paths = Set(entries.filter { $0.file != nil }.map(\.path))
        guard Set(release.requiredExecutablePaths + ["codex-package.json"]).isSubset(of: paths),
              let manifest = try root.storage.anchor.read("codex-package.json", maximum: 8_192),
              let value = try? JSONDecoder().decode(JSONValue.self, from: manifest), value["layoutVersion"] == .number(1),
              value["version"] == .string(release.version), value["target"] == .string(release.target),
              value["entrypoint"] == .string("bin/" + release.executableName) else { throw CodexInstallationError(.invalidRecord) }
        return entries
    }
}
