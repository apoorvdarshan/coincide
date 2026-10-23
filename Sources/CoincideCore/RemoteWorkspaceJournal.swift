import CryptoKit
import Darwin
import Foundation

/// Private write-ahead intent journal. An interrupted intent is evidence to
/// inspect, never a job to replay. The owning Engine already holds its runtime lock.
final class RemoteWorkspaceJournal {
    private struct Document: Codable { var version = 1; var operations: [RemoteWorkspaceOperation] }
    private let directory: GitWorktreeDirectory
    private var values: [UUID: RemoteWorkspaceOperation] = [:]
    private let maximumBytes = 64 * 1_024 * 1_024
    init(directory: URL) throws {
        self.directory = try GitWorktreeDirectory(path: directory.path)
        if let bytes = try read() {
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.version == 1, document.operations.count <= 256,
                  Set(document.operations.map(\.id)).count == document.operations.count else { throw RemoteWorkspaceFailure(.unavailable) }
            for var value in document.operations {
                guard value.payloadDigest == (try Self.digest(value.request)) else { throw RemoteWorkspaceFailure(.unavailable) }
                if value.state == .accepted || value.state == .running {
                    value.state = .uncertain; value.failure = .init(.interrupted); value.updatedAt = .now
                }
                values[value.id] = value
            }
            try persist()
        }
    }
    static func payload(_ request: RemoteWorkspaceMutationRequest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(request)
        guard bytes.count <= RemoteEnvironmentProtocol.maximumWorkspaceRequestBytes else { throw RemoteWorkspaceFailure(.limitExceeded) }
        return bytes
    }
    static func digest(_ request: RemoteWorkspaceMutationRequest) throws -> String {
        SHA256.hash(data: try payload(request)).map { String(format: "%02x", $0) }.joined()
    }
    func lookup(_ request: RemoteWorkspaceMutationRequest) throws -> RemoteWorkspaceOperation? {
        guard let value = values[request.id] else { return nil }
        guard value.payloadDigest == (try Self.digest(request)), try Self.payload(value.request) == Self.payload(request) else {
            throw RemoteWorkspaceFailure(.commandCollision)
        }
        return value
    }
    func insert(_ request: RemoteWorkspaceMutationRequest, failure: RemoteWorkspaceFailure? = nil) throws -> RemoteWorkspaceOperation {
        if let existing = try lookup(request) { return existing }
        guard values.count < 256 else { throw RemoteWorkspaceFailure(.limitExceeded) }
        let now = Date()
        let value = RemoteWorkspaceOperation(request: request, payloadDigest: try Self.digest(request),
            state: failure == nil ? .accepted : .finished, result: nil, failure: failure, createdAt: now, updatedAt: now)
        try store(value); return value
    }
    func store(_ value: RemoteWorkspaceOperation) throws {
        let prior = values[value.id]; values[value.id] = value
        do { try persist() } catch { values[value.id] = prior; throw RemoteWorkspaceFailure(.unavailable) }
    }
    private func read() throws -> Data? {
        let fd = openat(directory.fd, "remote-workspace-operations.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw RemoteWorkspaceFailure(.unavailable) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= maximumBytes else {
            throw RemoteWorkspaceFailure(.unavailable)
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw RemoteWorkspaceFailure(.unavailable) }; offset += count
        }
        try directory.validate(); return Data(bytes)
    }
    private func persist() throws {
        try directory.validate()
        let bytes = try JSONEncoder().encode(Document(operations: values.values.sorted { $0.id.uuidString < $1.id.uuidString }))
        guard bytes.count <= maximumBytes else { throw RemoteWorkspaceFailure(.limitExceeded) }
        let name = ".remote-workspace-" + UUID().uuidString
        let fd = openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemoteWorkspaceFailure(.unavailable) }
        defer { Darwin.close(fd); _ = unlinkat(directory.fd, name, 0) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw RemoteWorkspaceFailure(.unavailable) }; offset += count
        }
        guard fsync(fd) == 0 else { throw RemoteWorkspaceFailure(.unavailable) }
        try directory.validate()
        guard renameat(directory.fd, name, directory.fd, "remote-workspace-operations.json") == 0,
              fsync(directory.fd) == 0 else { throw RemoteWorkspaceFailure(.unavailable) }
    }
}
