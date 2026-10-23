import CryptoKit
import Darwin
import Foundation

/// Descriptor-bound readonly traversal. No symlink beneath a captured provider
/// home is followed, and a replaced ancestor cannot retarget an import read.
final class AgentSessionDirectory: @unchecked Sendable {
    let path: String, fd: Int32, identity: GitWorktreeNodeIdentity
    init(path: String) throws {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        fd = open(self.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AgentSessionImportError.unavailable }
        var value = stat(); guard fstat(fd, &value) == 0 else { Darwin.close(fd); throw AgentSessionImportError.unavailable }
        identity = .init(device: UInt64(truncatingIfNeeded: value.st_dev), inode: value.st_ino)
    }
    private init(path: String, fd: Int32) throws {
        self.path = path; self.fd = fd
        var value = stat(); guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { Darwin.close(fd); throw AgentSessionImportError.unavailable }
        identity = .init(device: UInt64(truncatingIfNeeded: value.st_dev), inode: value.st_ino)
    }
    deinit { Darwin.close(fd) }
    func validate() throws {
        var owned = stat(), current = stat()
        guard fstat(fd, &owned) == 0, lstat(path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
              owned.st_dev == current.st_dev, owned.st_ino == current.st_ino else { throw AgentSessionImportError.changed }
    }
    func directory(_ component: String) throws -> AgentSessionDirectory {
        try validate(); try Self.component(component)
        let child = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw AgentSessionImportError.unavailable }
        let result = try AgentSessionDirectory(path: path + "/" + component, fd: child)
        try validate(); return result
    }
    func names(limit: Int = 20_000) throws -> [String] {
        try validate(); let copied = dup(fd); guard copied >= 0 else { throw AgentSessionImportError.unavailable }
        guard let stream = fdopendir(copied) else { Darwin.close(copied); throw AgentSessionImportError.unavailable }
        defer { closedir(stream) }; rewinddir(stream); var result: [String] = []
        while let entry = readdir(stream) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) } }
            guard let name, name != ".", name != ".." else { continue }
            guard result.count < limit else { throw AgentSessionImportError.limit }
            result.append(name)
        }
        try validate(); return result.sorted()
    }
    func file(_ component: String) throws -> AgentSessionFile {
        try validate(); try Self.component(component)
        let child = openat(fd, component, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw AgentSessionImportError.unavailable }
        return try AgentSessionFile(directory: self, name: component, fd: child)
    }
    private static func component(_ value: String) throws { guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\0") else { throw AgentSessionImportError.invalidRequest } }
}
final class AgentSessionFile: @unchecked Sendable {
    let directory: AgentSessionDirectory, name: String, fd: Int32
    let initial: stat
    var path: String { directory.path + "/" + name }
    var size: UInt64 { UInt64(initial.st_size) }
    var modified: Date { Date(timeIntervalSince1970: Double(initial.st_mtimespec.tv_sec) + Double(initial.st_mtimespec.tv_nsec) / 1_000_000_000) }
    init(directory: AgentSessionDirectory, name: String, fd: Int32) throws {
        self.directory = directory; self.name = name; self.fd = fd
        var value = stat(); guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { Darwin.close(fd); throw AgentSessionImportError.unavailable }
        initial = value
    }
    deinit { Darwin.close(fd) }
    func validate() throws {
        try directory.validate(); var value = stat(), named = stat()
        guard fstat(fd, &value) == 0, fstatat(directory.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(initial, value), Self.same(initial, named) else { throw AgentSessionImportError.changed }
    }
    func readMetadata(maximumBytes: Int = 1_048_576) throws -> String {
        try validate()
        guard size <= UInt64(maximumBytes), lseek(fd, 0, SEEK_SET) == 0 else { throw AgentSessionImportError.limit }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while result.count < Int(size) {
            try Task.checkCancellation()
            let amount = Darwin.read(fd, &buffer, min(buffer.count, Int(size) - result.count))
            if amount < 0 { if errno == EINTR { continue }; throw AgentSessionImportError.unavailable }
            guard amount > 0 else { throw AgentSessionImportError.changed }
            result.append(contentsOf: buffer.prefix(amount))
        }
        try validate()
        guard let text = String(data: result, encoding: .utf8), !text.contains("\0") else { throw AgentSessionImportError.unavailable }
        return text
    }
    func read(profile: AgentSessionProfile, maximumBytes: UInt64, maximumRecords: Int, maximumSelectedBytes: Int, metadataOnly: Bool = false) throws -> (records: [JSONValue], count: Int, digest: String, bytes: UInt64, readOperations: Int) {
        try validate(); guard lseek(fd, 0, SEEK_SET) == 0 else { throw AgentSessionImportError.unavailable }
        let selector = AgentSessionJSONSelector(maximumSelectedBytes: maximumSelectedBytes, metadataOnly: metadataOnly)
        var records: [JSONValue] = [], count = 0, selected = 0, readBytes: UInt64 = 0, hash = SHA256(), hasLine = false
        var buffer = [UInt8](repeating: 0, count: metadataOnly ? 8_192 : 65_536), readOperations = 0
        var finishedMetadata = false
        while readBytes < maximumBytes && !finishedMetadata {
            try Task.checkCancellation()
            let wanted = min(buffer.count, Int(min(UInt64(buffer.count), maximumBytes - readBytes)))
            let amount = Darwin.read(fd, &buffer, wanted)
            readOperations += 1
            if amount < 0 { if errno == EINTR { continue }; throw AgentSessionImportError.unavailable }
            if amount == 0 { break }
            let data = Data(buffer.prefix(amount)); hash.update(data: data); readBytes += UInt64(amount)
            for byte in data {
                if byte == 10 {
                    count += 1; guard count <= maximumRecords else { throw AgentSessionImportError.limit }
                    if let row = try selector.finishLine(), row.object != nil {
                        selected += try AgentSessionImportProtocol.payload(row).count
                        guard selected <= maximumSelectedBytes else { throw AgentSessionImportError.limit }
                        records.append(row)
                        if metadataOnly, AgentSessionTranscriptParser.workspace(records, source: profile.source) != nil || records.contains(where: { $0["type"].string == "session_meta" && ($0["payload"]["source"].object?["subagent"] != nil || $0["payload"]["source"].object?["subAgent"] != nil) }) { finishedMetadata = true; hasLine = false; break }
                    }
                    hasLine = false
                } else { hasLine = true; try selector.feed(byte) }
            }
        }
        if hasLine && readBytes == size {
            count += 1; guard count <= maximumRecords else { throw AgentSessionImportError.limit }
            if let row = try selector.finishLine(), row.object != nil {
                selected += try AgentSessionImportProtocol.payload(row).count
                guard selected <= maximumSelectedBytes else { throw AgentSessionImportError.limit }
                records.append(row)
            }
        }
        try validate()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return (records, count, digest, readBytes, readOperations)
    }
    func source(profile: AgentSessionProfile, nativeID: String, digest: String) -> AgentSessionImportSource {
        .init(provider: profile.source, providerInstanceID: profile.id, providerSessionID: nativeID, filePath: path, size: size,
            device: UInt64(truncatingIfNeeded: initial.st_dev), inode: initial.st_ino,
            modificationNanoseconds: Self.nanoseconds(initial.st_mtimespec), birthNanoseconds: Self.nanoseconds(initial.st_birthtimespec),
            digest: digest, changeNanoseconds: Self.nanoseconds(initial.st_ctimespec))
    }
    static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT && lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec &&
            lhs.st_birthtimespec.tv_sec == rhs.st_birthtimespec.tv_sec && lhs.st_birthtimespec.tv_nsec == rhs.st_birthtimespec.tv_nsec
    }
    static func nanoseconds(_ value: timespec) -> Int64 { Int64(clamping: value.tv_sec) &* 1_000_000_000 &+ Int64(value.tv_nsec) }
}
