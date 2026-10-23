import Darwin
import Foundation

/// A private, versioned identity is separate from the replaceable projection.
enum RemoteEnvironmentIdentity {
    private struct Document: Codable { let version: Int; let environmentID: UUID }
    static func load(dataDirectory: URL, expected: UUID?) throws -> UUID {
        guard dataDirectory.isFileURL, dataDirectory.path.hasPrefix("/"), dataDirectory.path != "/" else {
            throw RemoteEnvironmentError(.identityInvalid)
        }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = stat()
        guard lstat(dataDirectory.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == getuid(), directory.st_mode & 0o077 == 0 else { throw RemoteEnvironmentError(.identityInvalid) }
        let lockPath = dataDirectory.appendingPathComponent("environment-identity.lock").path
        let lock = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard lock >= 0 else { throw RemoteEnvironmentError(.identityInvalid) }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw RemoteEnvironmentError(.identityInvalid) }
        let path = dataDirectory.appendingPathComponent("environment.json")
        let file = Darwin.open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if file >= 0 {
            defer { Darwin.close(file) }
            var info = stat()
            guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_mode & 0o077 == 0, info.st_nlink == 1, (1...512).contains(info.st_size) else { throw RemoteEnvironmentError(.identityInvalid) }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
            let bytes = try handle.read(upToCount: 513) ?? Data()
            guard bytes.count == info.st_size, let document = try? JSONDecoder().decode(Document.self, from: bytes), document.version == 1 else {
                throw RemoteEnvironmentError(.identityInvalid)
            }
            if let expected, expected != document.environmentID { throw RemoteEnvironmentError(.wrongEnvironment) }
            return document.environmentID
        }
        guard errno == ENOENT, expected == nil,
              !FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("workspace.sqlite").path) else {
            throw RemoteEnvironmentError(.identityInvalid)
        }
        let id = UUID(), bytes = try JSONEncoder().encode(Document(version: 1, environmentID: id))
        let temporary = dataDirectory.appendingPathComponent(".environment-\(UUID().uuidString).tmp")
        let output = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard output >= 0 else { throw RemoteEnvironmentError(.identityInvalid) }
        defer { Darwin.close(output); try? FileManager.default.removeItem(at: temporary) }
        let written = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
        guard written == bytes.count, fsync(output) == 0, Darwin.rename(temporary.path, path.path) == 0 else { throw RemoteEnvironmentError(.identityInvalid) }
        let directoryFD = Darwin.open(dataDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw RemoteEnvironmentError(.identityInvalid) }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw RemoteEnvironmentError(.identityInvalid) }
        return id
    }
}
