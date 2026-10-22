import CryptoKit
import Darwin
import Foundation

typealias CodexInstalledFile = AntigravityInstalledFile

/// Reuses the tested descriptor operations without exposing another provider's
/// errors. Package inventory below is Codex-specific and includes all resources.
final class CodexInstallDirectory: @unchecked Sendable {
    let storage: AntigravityInstallDirectory
    var url: URL { storage.url }
    var fd: Int32 { storage.fd }
    init(_ url: URL) throws { storage = try Self.convert { try AntigravityInstallDirectory(url) } }
    init(child: String, parent: CodexInstallDirectory) throws { storage = try Self.convert { try AntigravityInstallDirectory(child: child, parent: parent.storage) } }
    private init(_ storage: AntigravityInstallDirectory) { self.storage = storage }
    static func convert<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as CodexInstallationError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as AntigravityInstallationError {
            throw CodexInstallationError(error.kind == .busy ? .busy : error.kind == .invalidRecord ? .invalidRecord : .ownershipLost)
        } catch { throw CodexInstallationError(.ownershipLost) }
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
    private let storage: AntigravityInstallationLock
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
