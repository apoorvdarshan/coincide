import Darwin
import Foundation

public struct EditorRecoveryError: Error, Sendable, Equatable, LocalizedError {
    public enum Kind: Sendable, Equatable { case unsafeStorage, invalidData, capacity, changed }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .unsafeStorage: "Editor recovery could not access its private storage safely. Existing recovery data was preserved."
        case .invalidData: "The saved editor recovery data is invalid. Existing recovery data was preserved."
        case .capacity: "Editor recovery is full. Save or explicitly discard a recovered draft before adding more."
        case .changed: "Another editor changed this recovery draft. Its saved text was preserved."
        }
    }
}

/// Remote paths are opaque bytes. A host root identity is never replaced with
/// a client-side path resolution or a newly bound root without explicit review.
public enum EditorRecoveryScope: Codable, Sendable, Equatable {
    case native(workspacePath: String)
    case remote(environmentID: UUID, projectID: UUID, threadID: UUID, workspacePath: String, rootID: UUID)
    public var workspacePath: String {
        switch self { case .native(let path), .remote(_, _, _, let path, _): path }
    }
    public func matchesNative(_ path: String) -> Bool {
        if case .native(let saved) = self { return saved.utf8.elementsEqual(path.utf8) }; return false
    }
    public func matchesRemote(_ target: RemoteWorkspaceTarget, includingOtherRoots: Bool = false) -> Bool {
        guard case .remote(let environment, let project, let thread, let path, let root) = self else { return false }
        return environment == target.environmentID && project == target.projectID && thread == target.threadID &&
            path.utf8.elementsEqual(target.workspacePath.utf8) && (includingOtherRoots || root == target.rootID)
    }
}

public struct EditorRecoveryRecord: Codable, Sendable, Equatable, Identifiable {
    struct NativeRevision: Codable, Sendable, Equatable {
        let rootDevice: UInt64, rootInode: UInt64, device: UInt64, inode: UInt64
        let path: String, digest: Data
        init(_ value: WorkspaceFileRevision) {
            rootDevice = value.rootDevice; rootInode = value.rootInode; device = value.device; inode = value.inode
            path = value.path; digest = value.digest
        }
        var value: WorkspaceFileRevision { .init(rootDevice: rootDevice, rootInode: rootInode,
            device: device, inode: inode, path: path, digest: digest) }
    }
    public let id: UUID
    public let version: UUID
    public let scope: EditorRecoveryScope
    public let relativePath: String
    public let contents: String
    public let original: String
    public let remoteRevision: UUID?
    public let remoteOperationID: UUID?
    public let updatedAt: Date
    private let nativeRevision: NativeRevision?

    public static func native(workspacePath: String, document: WorkspaceTextDocument, contents: String,
                              id: UUID = UUID()) throws -> Self {
        guard let revision = document.revision, !document.truncated, document.exists else { throw EditorRecoveryError(.invalidData) }
        let value = Self(id: id, version: UUID(), scope: .native(workspacePath: workspacePath), relativePath: document.relativePath,
            contents: contents, original: document.contents, remoteRevision: nil, remoteOperationID: nil, updatedAt: Date(), nativeRevision: .init(revision))
        try value.validate(); return value
    }
    public static func remote(target: RemoteWorkspaceTarget, document: RemoteWorkspaceDocument, contents: String,
                              id: UUID = UUID(), operationID: UUID? = nil) throws -> Self {
        guard let root = target.rootID, let revision = document.revision, !document.truncated, document.exists else { throw EditorRecoveryError(.invalidData) }
        let value = Self(id: id, version: UUID(), scope: .remote(environmentID: target.environmentID, projectID: target.projectID,
            threadID: target.threadID, workspacePath: target.workspacePath, rootID: root), relativePath: document.relativePath,
            contents: contents, original: document.contents, remoteRevision: revision, remoteOperationID: operationID, updatedAt: Date(), nativeRevision: nil)
        try value.validate(); return value
    }
    public var nativeDocument: WorkspaceTextDocument? {
        guard case .native = scope, let nativeRevision else { return nil }
        return .init(relativePath: relativePath, contents: original, byteLength: original.utf8.count,
            truncated: false, exists: true, revision: nativeRevision.value)
    }
    public var remoteDocument: RemoteWorkspaceDocument? {
        guard case .remote = scope, let remoteRevision else { return nil }
        return .init(relativePath: relativePath, contents: original, byteLength: original.utf8.count,
            truncated: false, exists: true, revision: remoteRevision)
    }
    public func matchesNativeRoot(_ document: WorkspaceTextDocument) -> Bool {
        guard let saved = nativeRevision, let current = document.revision else { return false }
        return saved.rootDevice == current.rootDevice && saved.rootInode == current.rootInode
    }
    func validate() throws {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard scope.workspacePath.hasPrefix("/"), scope.workspacePath.utf8.count <= 16_384,
              !scope.workspacePath.contains("\0"), !relativePath.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }),
              !relativePath.contains("\0"), relativePath.utf8.count <= 16_384,
              contents.utf8.count <= EditorRecoveryJournal.maximumTextBytes, original.utf8.count <= EditorRecoveryJournal.maximumTextBytes,
              updatedAt.timeIntervalSince1970.isFinite else { throw EditorRecoveryError(.invalidData) }
        switch scope {
        case .native:
            guard let revision = nativeRevision, remoteRevision == nil, remoteOperationID == nil, revision.path.utf8.elementsEqual(relativePath.utf8),
                  revision.digest.count == 32 else { throw EditorRecoveryError(.invalidData) }
        case .remote: guard nativeRevision == nil, remoteRevision != nil else { throw EditorRecoveryError(.invalidData) }
        }
    }
}

/// One private bounded journal, with atomic durable replacement and a lock
/// shared by windows/processes. A token prevents an old save/discard completion
/// from deleting a newer edit. Only local draft bytes are written here.
public struct EditorRecoveryJournal: Sendable {
    public static let maximumTextBytes = 2_000_000
    public static let maximumRecords = 32
    public static let maximumStoredBytes = 32 * 1_024 * 1_024
    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Coincide/EditorRecovery", isDirectory: true) }
    public let root: URL
    private let maximumRecords: Int
    private let maximumBytes: Int
    private struct Document: Codable { var version = 1; var records: [EditorRecoveryRecord] }
    public init(root: URL = Self.defaultRoot, maximumRecords: Int = Self.maximumRecords, maximumBytes: Int = Self.maximumStoredBytes) {
        self.root = root; self.maximumRecords = min(max(1, maximumRecords), Self.maximumRecords)
        self.maximumBytes = min(max(1, maximumBytes), Self.maximumStoredBytes)
    }
    public func load() throws -> [EditorRecoveryRecord] { try locked(create: false) { try read($0) } }
    public func save(_ record: EditorRecoveryRecord, expectedVersion: UUID?) throws {
        try record.validate()
        try locked(create: true) { fd in
            var records = try read(fd)
            if let operation = record.remoteOperationID {
                guard !records.contains(where: { $0.id != record.id && $0.remoteOperationID == operation }) else { throw EditorRecoveryError(.changed) }
            }
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                guard records[index].version == expectedVersion,
                      try Self.bytes(records[index].scope) == Self.bytes(record.scope),
                      records[index].relativePath.utf8.elementsEqual(record.relativePath.utf8) else { throw EditorRecoveryError(.changed) }
                records[index] = record
            } else {
                guard expectedVersion == nil else { throw EditorRecoveryError(.changed) }
                guard records.count < maximumRecords else { throw EditorRecoveryError(.capacity) }
                records.append(record)
            }
            try write(records, directory: fd)
        }
    }
    public func remove(id: UUID, expectedVersion: UUID) throws {
        try locked(create: false) { fd in
            var records = try read(fd)
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            guard records[index].version == expectedVersion else { throw EditorRecoveryError(.changed) }
            records.remove(at: index); try write(records, directory: fd)
        }
    }
    private static func bytes<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private func read(_ directory: Int32?) throws -> [EditorRecoveryRecord] {
        guard let directory else { return [] }
        let fd = openat(directory, "editor-drafts.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return [] }
        guard fd >= 0 else { throw EditorRecoveryError(.unsafeStorage) }; defer { Darwin.close(fd) }
        var info = stat()
        guard Self.safe(fd), fstat(fd, &info) == 0, info.st_size >= 0, info.st_size <= maximumBytes else { throw EditorRecoveryError(.unsafeStorage) }
        var data = Data(count: Int(info.st_size)), offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR { continue }; guard count > 0 else { throw EditorRecoveryError(.unsafeStorage) }; offset += count
        }
        var after = stat()
        guard fstat(fd, &after) == 0, info.st_size == after.st_size, info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw EditorRecoveryError(.unsafeStorage) }
        do {
            let value = try JSONDecoder().decode(Document.self, from: data)
            guard value.version == 1, value.records.count <= maximumRecords,
                  Set(value.records.map(\.id)).count == value.records.count else { throw EditorRecoveryError(.invalidData) }
            try value.records.forEach { try $0.validate() }; return value.records
        } catch { throw error as? EditorRecoveryError ?? EditorRecoveryError(.invalidData) }
    }
    private func write(_ records: [EditorRecoveryRecord], directory: Int32?) throws {
        guard let directory else { throw EditorRecoveryError(.unsafeStorage) }
        let bytes = try Self.bytes(Document(records: records)); guard bytes.count <= maximumBytes else { throw EditorRecoveryError(.capacity) }
        let name = ".editor-atomic-" + UUID().uuidString
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw EditorRecoveryError(.unsafeStorage) }
        defer { Darwin.close(fd); _ = unlinkat(directory, name, 0) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR { continue }; guard count > 0 else { throw EditorRecoveryError(.unsafeStorage) }; offset += count
        }
        guard fsync(fd) == 0, renameat(directory, name, directory, "editor-drafts.json") == 0, fsync(directory) == 0 else { throw EditorRecoveryError(.unsafeStorage) }
    }
    private func locked<T>(create: Bool, _ body: (Int32?) throws -> T) throws -> T {
        guard root.isFileURL, !root.path.contains("\0") else { throw EditorRecoveryError(.unsafeStorage) }
        if create { do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { throw EditorRecoveryError(.unsafeStorage) } }
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0, errno == ENOENT, !create { return try body(nil) }
        guard directory >= 0 else { throw EditorRecoveryError(.unsafeStorage) }; defer { Darwin.close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw EditorRecoveryError(.unsafeStorage) }
        let lock = openat(directory, ".editor-recovery.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw EditorRecoveryError(.unsafeStorage) }; defer { Darwin.close(lock) }
        guard Self.safe(lock), flock(lock, LOCK_EX) == 0 else { throw EditorRecoveryError(.unsafeStorage) }
        defer { _ = flock(lock, LOCK_UN) }; return try body(directory)
    }
    private static func safe(_ fd: Int32) -> Bool {
        var info = stat(); return fstat(fd, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_mode & 0o077 == 0
    }
}
