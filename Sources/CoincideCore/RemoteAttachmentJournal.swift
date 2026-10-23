import CryptoKit
import Darwin
import Foundation

/// Only transfer descriptors, chunk digests, native references and lifecycle
/// metadata are journaled. Chunk bytes live in private immutable staging files.
final class RemoteAttachmentJournal {
    struct Entry: Codable {
        var upload: RemoteAttachmentUpload
        let attachmentID: UUID
        var digests: [Int: String]
        var candidate: ChatAttachment? = nil
    }
    private struct Document: Codable { let version: Int; let entries: [Entry] }
    let directory: GitWorktreeDirectory
    private var entries: [UUID: Entry] = [:]
    init(dataDirectory: URL) throws {
        let root = dataDirectory.appendingPathComponent("RemoteAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw RemoteAttachmentFailure(.unavailable) }
        directory = try .init(path: root.path)
        if let bytes = try read("uploads.json", maximum: 32 * 1_024 * 1_024) {
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.version == 1, document.entries.count <= 8_192, Set(document.entries.map { $0.upload.id }).count == document.entries.count else { throw RemoteAttachmentFailure(.unavailable) }
            for var entry in document.entries {
                try Self.validate(entry.upload.request)
                let count = Self.chunkCount(entry.upload.request)
                guard entry.digests.count <= count, entry.digests.allSatisfy({ (0..<count).contains($0.key) && Self.validDigest($0.value) }),
                      Set(entry.upload.receivedChunks) == Set(entry.digests.keys) || [.ready, .claimed, .cancelled].contains(entry.upload.state),
                      entry.upload.attachment == nil || entry.upload.attachment?.id == entry.attachmentID else { throw RemoteAttachmentFailure(.unavailable) }
                if entry.upload.state == .finalizing { entry.upload.state = .uncertain; entry.upload.failure = .init(.uncertain) }
                entries[entry.upload.id] = entry
            }
            try persist()
        }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func payload(_ request: RemoteAttachmentUploadRequest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(request)
    }
    static func validate(_ request: RemoteAttachmentUploadRequest) throws {
        guard (0...AttachmentLimits.fileBytes).contains(request.byteCount), !request.name.isEmpty, request.name.utf8.count <= 1_024,
              !request.name.contains("\0"), validDigest(request.digest) else { throw RemoteAttachmentFailure(.invalidRequest) }
    }
    static func chunkCount(_ request: RemoteAttachmentUploadRequest) -> Int { (request.byteCount + RemoteAttachmentProtocol.maximumChunkBytes - 1) / RemoteAttachmentProtocol.maximumChunkBytes }
    func lookup(_ request: RemoteAttachmentUploadRequest) throws -> Entry? {
        guard let value = entries[request.id] else { return nil }
        guard try Self.payload(value.upload.request) == Self.payload(request) else { throw RemoteAttachmentFailure(.collision) }
        return value
    }
    func insert(_ request: RemoteAttachmentUploadRequest) throws -> Entry {
        try Self.validate(request)
        if let old = try lookup(request) { return old }
        guard entries.count < 8_192,
              entries.values.filter({ ![.ready, .claimed, .cancelled].contains($0.upload.state) }).reduce(Int64(0), { $0 + Int64($1.upload.request.byteCount) }) + Int64(request.byteCount) <= 512 * 1_024 * 1_024 else { throw RemoteAttachmentFailure(.limitExceeded) }
        var space = statfs()
        guard fstatfs(directory.fd, &space) == 0,
              UInt64(space.f_bavail) * UInt64(space.f_bsize) >= UInt64(request.byteCount) + 256 * 1_024 * 1_024 else { throw RemoteAttachmentFailure(.limitExceeded) }
        let value = Entry(upload: .init(request: request, state: .receiving), attachmentID: UUID(), digests: [:])
        try store(value); return value
    }
    func store(_ value: Entry) throws {
        let old = entries[value.upload.id]; entries[value.upload.id] = value
        do { try persist() } catch { entries[value.upload.id] = old; throw error }
    }
    func append(_ request: RemoteAttachmentChunkRequest) throws -> Entry {
        guard var value = try lookup(request.upload) else { throw RemoteAttachmentFailure(.notFound) }
        guard [.receiving, .uncertain].contains(value.upload.state) else { throw RemoteAttachmentFailure(value.upload.state == .cancelled ? .cancelled : .busy) }
        let count = Self.chunkCount(request.upload), size = RemoteAttachmentProtocol.maximumChunkBytes
        guard (0..<count).contains(request.index), request.data.count == min(size, request.upload.byteCount - request.index * size),
              Self.validDigest(request.digest), Self.digest(request.data) == request.digest else { throw RemoteAttachmentFailure(.integrity) }
        if let known = value.digests[request.index], known != request.digest { throw RemoteAttachmentFailure(.collision) }
        let name = chunk(request.upload.id, request.index)
        if let old = try read(name, maximum: size) {
            guard old == request.data else { throw RemoteAttachmentFailure(.collision) }
        } else { try write(request.data, name: name, exclusive: true) }
        value.digests[request.index] = request.digest; value.upload.receivedChunks = value.digests.keys.sorted()
        value.upload.state = .receiving; value.upload.failure = nil; try store(value); return value
    }
    func assemble(_ value: Entry) throws -> URL {
        let count = Self.chunkCount(value.upload.request)
        guard value.digests.count == count else { throw RemoteAttachmentFailure(.integrity) }
        let name = value.upload.id.uuidString + ".assembled", temporary = ".assemble-" + UUID().uuidString
        let fd = openat(directory.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemoteAttachmentFailure(.unavailable) }
        defer { Darwin.close(fd); _ = unlinkat(directory.fd, temporary, 0) }
        var hash = SHA256(), total = 0
        for index in 0..<count {
            try Task.checkCancellation()
            guard let bytes = try read(chunk(value.upload.id, index), maximum: RemoteAttachmentProtocol.maximumChunkBytes),
                  Self.digest(bytes) == value.digests[index] else { throw RemoteAttachmentFailure(.integrity) }
            hash.update(data: bytes); total += bytes.count; try writeAll(bytes, fd: fd)
        }
        guard total == value.upload.request.byteCount,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == value.upload.request.digest else { throw RemoteAttachmentFailure(.integrity) }
        try directory.validate()
        guard fsync(fd) == 0, renameat(directory.fd, temporary, directory.fd, name) == 0, fsync(directory.fd) == 0 else { throw RemoteAttachmentFailure(.unavailable) }
        return URL(fileURLWithPath: directory.path).appendingPathComponent(name)
    }
    func clearStaging(_ value: Entry) throws {
        try directory.validate()
        for name in (0..<Self.chunkCount(value.upload.request)).map({ chunk(value.upload.id, $0) }) + [value.upload.id.uuidString + ".assembled"] {
            var info = stat()
            if fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw RemoteAttachmentFailure(.integrity) }
                guard unlinkat(directory.fd, name, 0) == 0 else { throw RemoteAttachmentFailure(.unavailable) }
            } else if errno != ENOENT { throw RemoteAttachmentFailure(.unavailable) }
        }
        guard fsync(directory.fd) == 0 else { throw RemoteAttachmentFailure(.unavailable) }
    }
    private func chunk(_ id: UUID, _ index: Int) -> String { id.uuidString + "." + String(index) + ".chunk" }
    private func persist() throws {
        let bytes = try JSONEncoder().encode(Document(version: 1, entries: entries.values.sorted { $0.upload.id.uuidString < $1.upload.id.uuidString }))
        guard bytes.count <= 32 * 1_024 * 1_024 else { throw RemoteAttachmentFailure(.limitExceeded) }
        try write(bytes, name: "uploads.json", exclusive: false)
    }
    private func read(_ name: String, maximum: Int) throws -> Data? {
        try directory.validate()
        let fd = openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw RemoteAttachmentFailure(.unavailable) }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= maximum else { throw RemoteAttachmentFailure(.integrity) }
        var bytes = Data(count: Int(info.st_size)), position = 0
        while position < bytes.count {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: position), $0.count - position) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw RemoteAttachmentFailure(.integrity) }; position += count
        }
        try directory.validate(); return bytes
    }
    private func write(_ bytes: Data, name: String, exclusive: Bool) throws {
        try directory.validate()
        let temporary = ".upload-write-" + UUID().uuidString
        let fd = openat(directory.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemoteAttachmentFailure(.unavailable) }
        defer { Darwin.close(fd); _ = unlinkat(directory.fd, temporary, 0) }
        try writeAll(bytes, fd: fd); try directory.validate()
        guard fsync(fd) == 0 else { throw RemoteAttachmentFailure(.unavailable) }
        let status = exclusive ? renameatx_np(directory.fd, temporary, directory.fd, name, UInt32(RENAME_EXCL)) : renameat(directory.fd, temporary, directory.fd, name)
        guard status == 0, fsync(directory.fd) == 0 else { throw RemoteAttachmentFailure(.unavailable) }
    }
    private func writeAll(_ bytes: Data, fd: Int32) throws {
        var position = 0
        while position < bytes.count {
            try Task.checkCancellation()
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: position), $0.count - position) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw RemoteAttachmentFailure(.unavailable) }; position += count
        }
    }
}
