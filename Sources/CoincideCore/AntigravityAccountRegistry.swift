import Foundation
import Darwin

/// Nonsecret account identity only. Credentials, browser URLs and catalogs never
/// enter this file or the workspace journal.
public enum AntigravityAccountRegistry {
    public enum AccessState: String, Codable, Sendable { case pending, verified, signedOut }
    public struct Record: Codable, Sendable, Equatable {
        public let configuration: AntigravityConfiguration
        public let accessState: AccessState
        public let checkedAt: Date
        public init(configuration: AntigravityConfiguration, accessState: AccessState, checkedAt: Date = Date()) {
            self.configuration = configuration; self.accessState = accessState; self.checkedAt = checkedAt
        }
    }
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Coincide/AntigravitySettings", isDirectory: true)
    }
    public static func load(rootURL: URL) throws -> Record? {
        guard rootURL.isFileURL else { throw failure() }
        let parent = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if parent < 0 && errno == ENOENT { return nil }
        guard parent >= 0 else { throw failure() }; defer { Darwin.close(parent) }
        let fd = openat(parent, "account.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure() }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size >= 0, info.st_size <= 65_536 else { throw failure() }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw failure() }; offset += count
        }
        do { return try JSONDecoder().decode(Record.self, from: Data(bytes)) } catch { throw failure() }
    }
    public static func save(_ record: Record, rootURL: URL) throws {
        do {
            try record.configuration.validate()
            guard rootURL.isFileURL else { throw failure() }
            let manager = FileManager.default
            try manager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var rootInfo = stat()
            guard lstat(rootURL.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
                  rootInfo.st_uid == getuid() else { throw failure() }
            let parent = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw failure() }; defer { Darwin.close(parent) }
            let data = try JSONEncoder().encode(record)
            guard data.count <= 65_536 else { throw failure() }
            let name = ".account-" + UUID().uuidString
            let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw failure() }
            defer { Darwin.close(fd); _ = unlinkat(parent, name, 0) }
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
                if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw failure() }; offset += count
            }
            guard fsync(fd) == 0, renameat(parent, name, parent, "account.json") == 0 else { throw failure() }
        } catch { throw failure() }
    }
    public static func validateKnownGeneration(_ configuration: AntigravityConfiguration, rootURL: URL) throws {
        guard let record = try load(rootURL: rootURL), record.accessState == .verified,
              record.configuration.runtimeIdentity == configuration.runtimeIdentity else {
            throw CoincideError("Sign in to the current Antigravity account in Settings before continuing.")
        }
    }
    private static func failure() -> CoincideError {
        .init("The saved Antigravity account could not be read or updated safely. Check account settings before continuing.")
    }
}
