import CryptoKit
import Darwin
import Foundation

// Only task-owned shadow/recovery directories are created here. Directory traversal
// never follows symlinks; external links are captured as links, not dereferenced.
struct CheckpointRestoreNode: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case file, directory, link }
    let path: String
    let kind: Kind
    let identity: GitWorktreeNodeIdentity
    let mode: UInt16
    let length: Int64
    let digest: String?
    let link: String?
    let opaque: Bool
    func sameContents(_ other: Self) -> Bool {
        path == other.path && kind == other.kind && mode == other.mode && length == other.length && digest == other.digest && link == other.link && opaque == other.opaque
    }
}

enum CheckpointRestoreFiles {
    static let maximumBytes = 536_870_912
    static let maximumManifest = 67_108_864
    static func name(_ id: UUID) -> String { ".coincide-restore-" + id.uuidString }
    static func encoded<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
    static func write(_ bytes: Data, to directory: GitWorktreeDirectory, name: String) throws {
        guard bytes.count <= maximumManifest else { throw GitCheckpointRestoreError(.outputLimit) }
        try CheckpointFiles.claimIndex(bytes, name: name, admin: directory)
    }
    static func parent(_ root: GitWorktreeDirectory, _ path: String, create: Bool = false) throws -> (GitWorktreeDirectory, String) {
        try CheckpointFiles.relative(path)
        var directory = root
        let parts = path.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            if create, try !directory.exists(part) { directory = try directory.claimDirectory(part) }
            else { directory = try .init(child: part, parent: directory) }
        }
        try directory.validate(); return (directory, parts.last!)
    }
    static func directory(_ root: GitWorktreeDirectory, _ path: String, create: Bool = false) throws -> GitWorktreeDirectory {
        if path.isEmpty { return root }
        let (parent, leaf) = try parent(root, path, create: create)
        if create, try !parent.exists(leaf) { return try parent.claimDirectory(leaf) }
        return try .init(child: leaf, parent: parent)
    }
    static func names(_ directory: GitWorktreeDirectory) throws -> [String] {
        try directory.validate()
        let fd = openat(directory.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0, let stream = fdopendir(fd) else { if fd >= 0 { close(fd) }; throw GitCheckpointRestoreError(.ownershipLost) }
        defer { closedir(stream) }
        var result = [String]()
        while true {
            errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }; break }
            let raw = withUnsafePointer(to: &entry.pointee.d_name) { ptr in ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) } }
            guard let name = raw else { throw GitCheckpointRestoreError(.unsupportedConfiguration) }
            if name != "." && name != ".." { result.append(name) }
            guard result.count <= 100_000 else { throw GitCheckpointRestoreError(.outputLimit) }
        }
        try directory.validate(); return result.sorted()
    }
    static func metadataName(_ name: String) -> Bool {
        var value = String(name.split(separator: ":", omittingEmptySubsequences: false).first ?? "")
        while value.last == "." || value.last == " " { value.removeLast() }
        value = value.uppercased()
        return value == ".GIT" || value == "GIT~1"
    }
    static func nestedRepository(_ directory: GitWorktreeDirectory) throws -> Bool {
        if try names(directory).contains(where: metadataName) { return true }
        return try directory.exists("HEAD") && directory.exists("objects") && directory.exists("refs")
    }
    static func scan(_ root: GitWorktreeDirectory, copyingTo copy: GitWorktreeDirectory? = nil, protectRepositories: Bool = true) throws -> [CheckpointRestoreNode] {
        var nodes = [CheckpointRestoreNode](), bytes = 0, pathBytes = 0
        func visit(_ directory: GitWorktreeDirectory, prefix: String, destination: GitWorktreeDirectory?) throws {
            try Task.checkCancellation()
            for name in try names(directory) {
                // The actual repository administration is separately identity-bound.
                if protectRepositories && prefix.isEmpty && name == ".git" { continue }
                guard !protectRepositories || !metadataName(name) else { throw GitCheckpointRestoreError(.unsupportedConfiguration) }
                let path = prefix + name
                if protectRepositories { try CheckpointFiles.relative(path) }
                else { try ownedRelative(path) }
                pathBytes += path.utf8.count + 1
                guard nodes.count < 100_000, pathBytes <= 4_194_304 else { throw GitCheckpointRestoreError(.outputLimit) }
                var node = stat()
                guard fstatat(directory.fd, name, &node, AT_SYMLINK_NOFOLLOW) == 0,
                      UInt64(truncatingIfNeeded: node.st_dev) == root.identity.device else { throw GitCheckpointRestoreError(.ownershipLost) }
                let mode = UInt16(node.st_mode & 0o7777), identity = worktreeIdentity(node)
                switch node.st_mode & S_IFMT {
                case S_IFDIR:
                    let child = try GitWorktreeDirectory(child: name, parent: directory)
                    let opaque: Bool
                    if protectRepositories { opaque = try nestedRepository(child) } else { opaque = false }
                    nodes.append(.init(path: path, kind: .directory, identity: identity, mode: mode, length: 0, digest: nil, link: nil, opaque: opaque))
                    let copied = try destination?.claimDirectory(name)
                    if let copied { guard fchmod(copied.fd, mode_t(mode)) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) } }
                    if opaque {
                        // A valid inert marker preserves Git clean's nested-repository protection.
                        // No nested metadata, secrets or working bytes are read or copied.
                        if let copied {
                            let marker = try copied.claimDirectory(".git")
                            _ = try marker.claimDirectory("objects"); _ = try marker.claimDirectory("refs")
                            try marker.writeExclusive(Data("ref: refs/heads/coincide-preserved\n".utf8), name: "HEAD")
                        }
                    } else { try visit(child, prefix: path + "/", destination: copied) }
                    try child.validate(expected: identity)
                case S_IFREG:
                    guard node.st_size >= 0, node.st_size <= maximumBytes, bytes <= maximumBytes - Int(node.st_size) else { throw GitCheckpointRestoreError(.outputLimit) }
                    bytes += Int(node.st_size)
                    let digest = try file(directory, name: name, expected: node, destination: destination, mode: mode)
                    nodes.append(.init(path: path, kind: .file, identity: identity, mode: mode, length: Int64(node.st_size), digest: digest, link: nil, opaque: false))
                case S_IFLNK:
                    var buffer = [UInt8](repeating: 0, count: 16_385)
                    let count = readlinkat(directory.fd, name, &buffer, buffer.count)
                    guard count > 0, count < buffer.count, let link = String(bytes: buffer.prefix(count), encoding: .utf8) else { throw GitCheckpointRestoreError(.unsupportedConfiguration) }
                    if let destination { guard symlinkat(link, destination.fd, name) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) } }
                    var final = stat()
                    guard fstatat(directory.fd, name, &final, AT_SYMLINK_NOFOLLOW) == 0, worktreeIdentity(final) == identity else { throw GitCheckpointRestoreError(.ownershipLost) }
                    nodes.append(.init(path: path, kind: .link, identity: identity, mode: mode, length: Int64(count), digest: nil, link: link, opaque: false))
                default: throw GitCheckpointRestoreError(.unsupportedConfiguration)
                }
            }
            try directory.validate()
        }
        try visit(root, prefix: "", destination: copy)
        return nodes.sorted { $0.path < $1.path }
    }
    private static func file(_ directory: GitWorktreeDirectory, name: String, expected: stat,
                             destination: GitWorktreeDirectory?, mode: UInt16) throws -> String {
        let fd = openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw GitCheckpointRestoreError(.ownershipLost) }; defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, worktreeIdentity(opened) == worktreeIdentity(expected) else { throw GitCheckpointRestoreError(.ownershipLost) }
        var out: Int32 = -1
        if let destination {
            out = openat(destination.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard out >= 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
        }
        defer { if out >= 0 { close(out) } }
        var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 65_536), total = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw GitCheckpointRestoreError(.ownershipLost) }
            total += count
            guard total <= expected.st_size else { throw GitCheckpointRestoreError(.staleReview) }
            hasher.update(data: Data(buffer.prefix(count)))
            if out >= 0 {
                try buffer.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < count {
                        let written = Darwin.write(out, raw.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw GitCheckpointRestoreError(.ownershipLost) }; offset += written
                    }
                }
            }
        }
        var final = stat(), named = stat()
        guard fstat(fd, &final) == 0, fstatat(directory.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              worktreeIdentity(final) == worktreeIdentity(expected), worktreeIdentity(named) == worktreeIdentity(expected),
              total == expected.st_size, final.st_size == expected.st_size, final.st_mode == expected.st_mode,
              final.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec, final.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec else { throw GitCheckpointRestoreError(.staleReview) }
        if out >= 0 { guard fchmod(out, mode_t(mode)) == 0, fsync(out) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) } }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func ownedRelative(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw GitCheckpointRestoreError(.metadataInvalid) }
    }
    static func copyNode(_ node: CheckpointRestoreNode, from root: GitWorktreeDirectory, to destination: GitWorktreeDirectory, name: String) throws {
        let (parent, leaf) = try self.parent(root, node.path)
        var info = stat()
        guard fstatat(parent.fd, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0, worktreeIdentity(info) == node.identity else { throw GitCheckpointRestoreError(.staleReview) }
        if node.kind == .file {
            // Copy to a literal task-owned name, keeping the full original hash proof.
            let container = try destination.claimDirectory(name)
            let hash = try file(parent, name: leaf, expected: info, destination: container, mode: node.mode)
            guard hash == node.digest else { throw GitCheckpointRestoreError(.staleReview) }
            guard renameatx_np(container.fd, leaf, destination.fd, name + ".file", UInt32(RENAME_EXCL)) == 0,
                  unlinkat(destination.fd, name, AT_REMOVEDIR) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
        } else if node.kind == .link, let target = node.link {
            guard symlinkat(target, destination.fd, name + ".file") == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
        } else { throw GitCheckpointRestoreError(.unsupportedConfiguration) }
    }
    static func removeOwned(_ nodes: [CheckpointRestoreNode], from root: GitWorktreeDirectory) throws {
        for node in nodes.sorted(by: { $0.path > $1.path }) {
            try Task.checkCancellation(); try ownedRelative(node.path)
            let (parent, leaf) = try ownedParent(root, node.path)
            var info = stat()
            guard fstatat(parent.fd, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0, worktreeIdentity(info) == node.identity,
                  UInt16(info.st_mode & 0o7777) == node.mode else { throw GitCheckpointRestoreError(.ownershipLost) }
            switch node.kind {
            case .directory:
                let child = try GitWorktreeDirectory(child: leaf, parent: parent)
                guard try names(child).isEmpty, unlinkat(parent.fd, leaf, AT_REMOVEDIR) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
            case .file:
                guard info.st_mode & S_IFMT == S_IFREG, info.st_size == node.length,
                      try file(parent, name: leaf, expected: info, destination: nil, mode: node.mode) == node.digest,
                      unlinkat(parent.fd, leaf, 0) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
            case .link:
                var bytes = [UInt8](repeating: 0, count: 16_385)
                let count = readlinkat(parent.fd, leaf, &bytes, bytes.count)
                guard count > 0, count < bytes.count, String(bytes: bytes.prefix(count), encoding: .utf8) == node.link,
                      unlinkat(parent.fd, leaf, 0) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
            }
            guard fsync(parent.fd) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
        }
    }
    private static func ownedParent(_ root: GitWorktreeDirectory, _ path: String) throws -> (GitWorktreeDirectory, String) {
        try ownedRelative(path)
        let parts = path.split(separator: "/").map(String.init)
        var directory = root
        for part in parts.dropLast() { directory = try .init(child: part, parent: directory) }
        return (directory, parts.last!)
    }
    static func sameContents(_ a: [CheckpointRestoreNode], _ b: [CheckpointRestoreNode]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.sameContents($1) }
    }
    static func digest(_ nodes: [CheckpointRestoreNode]) throws -> String { CheckpointFiles.digest(try encoded(nodes)) }
}
