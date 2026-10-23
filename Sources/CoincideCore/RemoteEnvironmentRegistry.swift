import Darwin
import Foundation

public struct RemoteEnvironmentStorageError: Error, Sendable, Equatable, LocalizedError {
    public enum Kind: Sendable, Equatable { case unsafeFile, corruptFile, limitExceeded, pendingCommandExists, commandChanged }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .unsafeFile: "The private remote connection data could not be accessed safely. Existing files were preserved."
        case .corruptFile: "The saved remote connection data is invalid. Existing files were preserved."
        case .limitExceeded: "The saved remote connection data exceeds its storage limit. Existing files were preserved."
        case .pendingCommandExists: "Check or explicitly abandon the existing uncertain remote command before starting another."
        case .commandChanged: "The saved uncertain remote command changed. It was preserved."
        }
    }
}

/// Nonsecret connection metadata only. Authentication is owned by system SSH.
public struct RemoteEnvironmentConnection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var configuration: SSHRemoteEnvironmentConfiguration
    public var environmentID: UUID
    public var lastConnectedAt: Date?
    public init(id: UUID = UUID(), name: String, configuration: SSHRemoteEnvironmentConfiguration,
                environmentID: UUID, lastConnectedAt: Date? = nil) {
        self.id = id; self.name = name; self.configuration = configuration
        self.environmentID = environmentID; self.lastConnectedAt = lastConnectedAt
    }
    public func validate() throws {
        try configuration.validate()
        do { try SkillValidation.text(name, maximum: 128, empty: false) }
        catch { throw RemoteEnvironmentStorageError(.corruptFile) }
        guard lastConnectedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw RemoteEnvironmentStorageError(.corruptFile) }
    }
}

public enum RemoteEnvironmentRegistry {
    public static let maximumConnections = 32
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Coincide/RemoteEnvironments", isDirectory: true)
    }
    private struct Document: Codable { var version = 1; let connections: [RemoteEnvironmentConnection] }
    public static func load(rootURL: URL = defaultRoot) throws -> [RemoteEnvironmentConnection] {
        try RemotePrivateFiles(root: rootURL).locked(create: false) { files in
            guard let files, let bytes = try files.read("connections.json", maximum: 262_144) else { return [] }
            return try decode(bytes)
        }
    }
    public static func save(_ connections: [RemoteEnvironmentConnection], rootURL: URL = defaultRoot) throws {
        try validate(connections)
        let bytes = try JSONEncoder().encode(Document(connections: connections))
        try RemotePrivateFiles(root: rootURL).locked(create: true) { files in
            guard let files else { throw RemoteEnvironmentStorageError(.unsafeFile) }
            if let prior = try files.read("connections.json", maximum: 262_144) { _ = try decode(prior) }
            try files.write(bytes, name: "connections.json", maximum: 262_144)
        }
    }
    private static func decode(_ bytes: Data) throws -> [RemoteEnvironmentConnection] {
        do {
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.version == 1 else { throw RemoteEnvironmentStorageError(.corruptFile) }
            try validate(document.connections); return document.connections
        } catch { throw error as? RemoteEnvironmentStorageError ?? RemoteEnvironmentStorageError(.corruptFile) }
    }
    private static func validate(_ connections: [RemoteEnvironmentConnection]) throws {
        guard connections.count <= maximumConnections else { throw RemoteEnvironmentStorageError(.limitExceeded) }
        guard Set(connections.map(\.id)).count == connections.count else { throw RemoteEnvironmentStorageError(.corruptFile) }
        for connection in connections { try connection.validate() }
    }
}

/// Exact payload retained privately before any write. A nil receipt never
/// authorizes replay, including after an app or SSH connection restart.
public struct RemoteEnvironmentPendingCommand: Codable, Sendable, Equatable {
    public let connectionID: UUID
    public let environmentID: UUID
    public let id: UUID
    public let command: RemoteEnvironmentCommand
    public init(connectionID: UUID, environmentID: UUID, id: UUID, command: RemoteEnvironmentCommand) {
        self.connectionID = connectionID; self.environmentID = environmentID; self.id = id; self.command = command
    }
    public var request: RemoteEnvironmentCommandRequest { .init(environmentID: environmentID, id: id, command: command) }
}

public actor RemoteEnvironmentPendingStore {
    private let root: URL
    public init(root: URL) { self.root = root }
    public func load(connectionID: UUID) throws -> RemoteEnvironmentPendingCommand? {
        try RemotePrivateFiles(root: root).locked(create: false) { files in
            guard let files else { return nil }
            return try Self.load(connectionID, files: files)
        }
    }
    public func save(_ pending: RemoteEnvironmentPendingCommand) throws {
        let payload = try RemoteEnvironmentProtocol.payload(pending.request)
        try RemotePrivateFiles(root: root).locked(create: true) { files in
            guard let files else { throw RemoteEnvironmentStorageError(.unsafeFile) }
            if let existing = try Self.load(pending.connectionID, files: files) {
                guard try RemoteEnvironmentProtocol.payload(existing.request) == payload else { throw RemoteEnvironmentStorageError(.pendingCommandExists) }
                return
            }
            try files.write(JSONEncoder().encode(pending), name: Self.name(pending.connectionID), maximum: 1_048_832)
        }
    }
    public func remove(connectionID: UUID, commandID: UUID) throws {
        try RemotePrivateFiles(root: root).locked(create: false) { files in
            guard let files, let existing = try Self.load(connectionID, files: files) else { return }
            guard existing.id == commandID else { throw RemoteEnvironmentStorageError(.commandChanged) }
            try files.remove(Self.name(connectionID))
        }
    }
    /// Explicit abandonment retains the exact private request as an audit; it
    /// does not claim cancellation or that an uncertain command never committed.
    public func archive(connectionID: UUID, commandID: UUID) throws {
        try RemotePrivateFiles(root: root).locked(create: false) { files in
            guard let files, let existing = try Self.load(connectionID, files: files) else { return }
            guard existing.id == commandID else { throw RemoteEnvironmentStorageError(.commandChanged) }
            let name = "abandoned-" + connectionID.uuidString.lowercased() + "-" + commandID.uuidString.lowercased() + ".json"
            if let bytes = try files.read(name, maximum: 1_048_832) {
                let archived = try Self.decode(bytes, connectionID: connectionID)
                guard try RemoteEnvironmentProtocol.payload(archived.request) == RemoteEnvironmentProtocol.payload(existing.request) else { throw RemoteEnvironmentStorageError(.commandChanged) }
            } else {
                guard try files.count(prefix: "abandoned-") < 1_024 else { throw RemoteEnvironmentStorageError(.limitExceeded) }
                try files.write(JSONEncoder().encode(existing), name: name, maximum: 1_048_832)
            }
            try files.remove(Self.name(connectionID))
        }
    }
    private static func name(_ id: UUID) -> String { "pending-" + id.uuidString.lowercased() + ".json" }
    private static func load(_ id: UUID, files: RemotePrivateFiles.OpenDirectory) throws -> RemoteEnvironmentPendingCommand? {
        guard let bytes = try files.read(name(id), maximum: 1_048_832) else { return nil }
        return try decode(bytes, connectionID: id)
    }
    private static func decode(_ bytes: Data, connectionID: UUID) throws -> RemoteEnvironmentPendingCommand {
        do {
            let pending = try JSONDecoder().decode(RemoteEnvironmentPendingCommand.self, from: bytes)
            guard pending.connectionID == connectionID else { throw RemoteEnvironmentStorageError(.corruptFile) }
            _ = try RemoteEnvironmentProtocol.payload(pending.request); return pending
        } catch { throw error as? RemoteEnvironmentStorageError ?? RemoteEnvironmentStorageError(.corruptFile) }
    }
}

/// The exact request is saved before a file/Git mutation is transmitted. A
/// missing receipt never permits resending it, including after process restart.
public actor RemoteWorkspacePendingStore {
    private let root: URL
    public init(root: URL) { self.root = root }
    public func load(environmentID: UUID, threadID: UUID) throws -> RemoteWorkspaceMutationRequest? {
        try RemotePrivateFiles(root: root).locked(create: false) { files in
            guard let files else { return nil }
            return try Self.load(environmentID, threadID, files: files)
        }
    }
    public func save(request: RemoteWorkspaceMutationRequest) throws {
        let bytes = try RemoteWorkspaceJournal.payload(request)
        guard request.target.rootID != nil else { throw RemoteEnvironmentStorageError(.corruptFile) }
        try RemotePrivateFiles(root: root).locked(create: true) { files in
            guard let files else { throw RemoteEnvironmentStorageError(.unsafeFile) }
            if let existing = try Self.load(request.target.environmentID, request.target.threadID, files: files) {
                guard try RemoteWorkspaceJournal.payload(existing) == bytes else { throw RemoteEnvironmentStorageError(.pendingCommandExists) }
                return
            }
            guard try files.count(prefix: "pending-") < 64 else { throw RemoteEnvironmentStorageError(.limitExceeded) }
            try files.write(bytes, name: Self.name(request.target.environmentID, request.target.threadID),
                maximum: RemoteEnvironmentProtocol.maximumWorkspaceRequestBytes)
        }
    }
    public func remove(request: RemoteWorkspaceMutationRequest) throws {
        try RemotePrivateFiles(root: root).locked(create: false) { files in
            guard let files, let existing = try Self.load(request.target.environmentID, request.target.threadID, files: files) else { return }
            guard try RemoteWorkspaceJournal.payload(existing) == RemoteWorkspaceJournal.payload(request) else { throw RemoteEnvironmentStorageError(.commandChanged) }
            try files.remove(Self.name(request.target.environmentID, request.target.threadID))
        }
    }
    public func archive(request: RemoteWorkspaceMutationRequest) throws {
        try RemotePrivateFiles(root: root).locked(create: false) { files in
            guard let files, let existing = try Self.load(request.target.environmentID, request.target.threadID, files: files) else { return }
            let bytes = try RemoteWorkspaceJournal.payload(request)
            guard try RemoteWorkspaceJournal.payload(existing) == bytes else { throw RemoteEnvironmentStorageError(.commandChanged) }
            let name = "abandoned-" + request.target.environmentID.uuidString.lowercased() + "-" + request.id.uuidString.lowercased() + ".json"
            if let prior = try files.read(name, maximum: RemoteEnvironmentProtocol.maximumWorkspaceRequestBytes) {
                let archived = try Self.decode(prior, environmentID: request.target.environmentID, threadID: request.target.threadID)
                guard try RemoteWorkspaceJournal.payload(archived) == bytes else { throw RemoteEnvironmentStorageError(.commandChanged) }
            } else {
                guard try files.count(prefix: "abandoned-") < 256 else { throw RemoteEnvironmentStorageError(.limitExceeded) }
                try files.write(bytes, name: name, maximum: RemoteEnvironmentProtocol.maximumWorkspaceRequestBytes)
            }
            try files.remove(Self.name(request.target.environmentID, request.target.threadID))
        }
    }
    private static func name(_ environmentID: UUID, _ threadID: UUID) -> String {
        "pending-" + environmentID.uuidString.lowercased() + "-" + threadID.uuidString.lowercased() + ".json"
    }
    private static func load(_ environmentID: UUID, _ threadID: UUID, files: RemotePrivateFiles.OpenDirectory) throws -> RemoteWorkspaceMutationRequest? {
        guard let bytes = try files.read(name(environmentID, threadID), maximum: RemoteEnvironmentProtocol.maximumWorkspaceRequestBytes) else { return nil }
        return try decode(bytes, environmentID: environmentID, threadID: threadID)
    }
    private static func decode(_ bytes: Data, environmentID: UUID, threadID: UUID) throws -> RemoteWorkspaceMutationRequest {
        do {
            let request = try JSONDecoder().decode(RemoteWorkspaceMutationRequest.self, from: bytes)
            guard request.target.environmentID == environmentID, request.target.threadID == threadID, request.target.rootID != nil else {
                throw RemoteEnvironmentStorageError(.corruptFile)
            }
            _ = try RemoteWorkspaceJournal.payload(request)
            return request
        } catch { throw error as? RemoteEnvironmentStorageError ?? RemoteEnvironmentStorageError(.corruptFile) }
    }
}

public actor RemoteEnvironmentDraftStore {
    private struct RecallMarker: Codable {
        let commandID: UUID, operationID: UUID, threadID: UUID
        let digest: String
    }
    private struct Document: Codable {
        var version = 1
        let environmentID: UUID
        let drafts: [UUID: String]
        let historyRecalls: [UUID: RecallMarker]?
    }
    public struct HistoryRecallResult: Sendable {
        public let drafts: [UUID: String]
        public let appended: Bool
    }
    private let root: URL
    public init(root: URL) { self.root = root }
    public func load(environmentID: UUID) throws -> [UUID: String] {
        try RemotePrivateFiles(root: root).locked(create: false) { files in
            guard let files, let bytes = try files.read(Self.name(environmentID), maximum: 16_777_216) else { return [:] }
            return try Self.decode(bytes, environmentID: environmentID).drafts
        }
    }
    public func save(environmentID: UUID, drafts: [UUID: String]) throws {
        try Self.validate(drafts)
        try RemotePrivateFiles(root: root).locked(create: true) { files in
            guard let files else { throw RemoteEnvironmentStorageError(.unsafeFile) }
            let previous = try files.read(Self.name(environmentID), maximum: 16_777_216).map { try Self.decode($0, environmentID: environmentID) }
            try files.write(JSONEncoder().encode(Document(environmentID: environmentID, drafts: drafts, historyRecalls: previous?.historyRecalls)),
                name: Self.name(environmentID), maximum: 16_777_216)
        }
    }
    /// The prompt merge and its receipt marker share one atomic private write.
    /// A replay after a lost reply observes the marker without appending again.
    public func mergeHistoryRecall(environmentID: UUID, threadID: UUID, commandID: UUID, operationID: UUID,
                                   text: String, attachmentDigest: String, expectedDrafts: [UUID: String]) throws -> HistoryRecallResult {
        try Self.validate(expectedDrafts)
        guard CheckpointValidation.digest(attachmentDigest), text.utf16.count <= 120_000 else { throw RemoteEnvironmentStorageError(.limitExceeded) }
        struct Identity: Encodable { let threadID: UUID; let text: String; let attachmentDigest: String }
        let digest = try RemoteHistoryProtocol.digest(Identity(threadID: threadID, text: text, attachmentDigest: attachmentDigest))
        return try RemotePrivateFiles(root: root).locked(create: true) { files in
            guard let files else { throw RemoteEnvironmentStorageError(.unsafeFile) }
            let old = try files.read(Self.name(environmentID), maximum: 16_777_216).map { try Self.decode($0, environmentID: environmentID) }
            var markers = old?.historyRecalls ?? [:]
            if let marker = markers.values.first(where: { $0.commandID == commandID }),
               marker.operationID != operationID || marker.threadID != threadID || marker.digest != digest {
                throw RemoteEnvironmentStorageError(.commandChanged)
            }
            if let marker = markers[operationID] {
                guard marker.threadID == threadID, marker.digest == digest else { throw RemoteEnvironmentStorageError(.commandChanged) }
                return .init(drafts: old?.drafts ?? [:], appended: false)
            }
            guard markers.count < 4_096 else { throw RemoteEnvironmentStorageError(.limitExceeded) }
            let savedDrafts = old?.drafts ?? [:]
            guard savedDrafts.count == expectedDrafts.count,
                  savedDrafts.allSatisfy({ id, text in expectedDrafts[id].map { text.utf8.elementsEqual($0.utf8) } == true }) else {
                throw RemoteEnvironmentStorageError(.commandChanged)
            }
            var drafts = expectedDrafts
            let current = drafts[threadID] ?? ""
            if !text.isEmpty { drafts[threadID] = current.isEmpty ? text : current + "\n\n" + text }
            try Self.validate(drafts)
            markers[operationID] = .init(commandID: commandID, operationID: operationID, threadID: threadID, digest: digest)
            try files.write(JSONEncoder().encode(Document(environmentID: environmentID, drafts: drafts, historyRecalls: markers)),
                name: Self.name(environmentID), maximum: 16_777_216)
            return .init(drafts: drafts, appended: true)
        }
    }
    private static func name(_ id: UUID) -> String { "drafts-" + id.uuidString.lowercased() + ".json" }
    private static func decode(_ bytes: Data, environmentID: UUID) throws -> Document {
        do {
            let value = try JSONDecoder().decode(Document.self, from: bytes)
            guard value.version == 1, value.environmentID == environmentID else { throw RemoteEnvironmentStorageError(.corruptFile) }
            try validate(value.drafts)
            let markers = value.historyRecalls ?? [:]
            guard markers.count <= 4_096, markers.allSatisfy({ $0.key == $0.value.operationID && CheckpointValidation.digest($0.value.digest) }),
                  Set(markers.values.map(\.commandID)).count == markers.count else { throw RemoteEnvironmentStorageError(.corruptFile) }
            return value
        } catch { throw error as? RemoteEnvironmentStorageError ?? RemoteEnvironmentStorageError(.corruptFile) }
    }
    private static func validate(_ drafts: [UUID: String]) throws {
        guard drafts.count <= 256, drafts.values.allSatisfy({ $0.utf16.count <= 120_000 }) else { throw RemoteEnvironmentStorageError(.limitExceeded) }
    }
}

/// Private bounded documents with byte-exact compare-and-swap. Callers retain
/// the raw bytes they decoded so another window/process cannot lose a draft.
public actor RemotePrivateDocumentStore {
    private let root: URL
    public init(root: URL) { self.root = root }
    public func load(name: String, maximum: Int) throws -> Data? {
        try Self.validate(name, maximum: maximum)
        return try RemotePrivateFiles(root: root).locked(create: false) { files in
            try files?.read(name, maximum: maximum)
        }
    }
    public func save(data: Data, name: String, maximum: Int, expected: Data?) throws {
        try Self.validate(name, maximum: maximum)
        guard data.count <= maximum else { throw RemoteEnvironmentStorageError(.limitExceeded) }
        try RemotePrivateFiles(root: root).locked(create: true) { files in
            guard let files else { throw RemoteEnvironmentStorageError(.unsafeFile) }
            guard try files.read(name, maximum: maximum) == expected else {
                throw RemoteEnvironmentStorageError(.commandChanged)
            }
            try files.write(data, name: name, maximum: maximum)
        }
    }
    public func remove(name: String, expected: Data) throws {
        try Self.validate(name, maximum: 16_777_216)
        try RemotePrivateFiles(root: root).locked(create: false) { files in
            guard let files, try files.read(name, maximum: 16_777_216) == expected else {
                throw RemoteEnvironmentStorageError(.commandChanged)
            }
            try files.remove(name)
        }
    }
    private static func validate(_ name: String, maximum: Int) throws {
        let stem = name.dropLast(5)
        guard maximum > 0, maximum <= 16_777_216 else { throw RemoteEnvironmentStorageError(.limitExceeded) }
        guard name.hasSuffix(".json"), !stem.isEmpty, name.utf8.count <= 160,
              stem.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw RemoteEnvironmentStorageError(.unsafeFile)
        }
    }
}

/// Every operation uses a private owned directory, no-follow regular files and
/// one cross-instance/process advisory lock. Atomic replacements are fsynced;
/// corrupt existing data is decoded by callers before any replacement/removal.
private struct RemotePrivateFiles {
    let root: URL
    func locked<T>(create: Bool, _ body: (OpenDirectory?) throws -> T) throws -> T {
        guard root.isFileURL, !root.path.contains("\0") else { throw RemoteEnvironmentStorageError(.unsafeFile) }
        if create {
            do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw RemoteEnvironmentStorageError(.unsafeFile) }
        }
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0 && errno == ENOENT && !create { return try body(nil) }
        guard directory >= 0 else { throw RemoteEnvironmentStorageError(.unsafeFile) }
        defer { Darwin.close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw RemoteEnvironmentStorageError(.unsafeFile) }
        let lock = openat(directory, ".remote-data.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw RemoteEnvironmentStorageError(.unsafeFile) }
        defer { Darwin.close(lock) }
        guard Self.safe(lock), flock(lock, LOCK_EX) == 0 else { throw RemoteEnvironmentStorageError(.unsafeFile) }
        defer { _ = flock(lock, LOCK_UN) }
        return try body(OpenDirectory(descriptor: directory))
    }
    private static func safe(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
            && info.st_nlink == 1 && info.st_mode & 0o077 == 0
    }
    struct OpenDirectory {
        let descriptor: Int32
        func read(_ name: String, maximum: Int) throws -> Data? {
            let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd < 0 && errno == ENOENT { return nil }
            guard fd >= 0 else { throw RemoteEnvironmentStorageError(.unsafeFile) }
            defer { Darwin.close(fd) }
            var info = stat()
            guard RemotePrivateFiles.safe(fd), fstat(fd, &info) == 0,
                  info.st_size >= 0, info.st_size <= maximum else { throw RemoteEnvironmentStorageError(.unsafeFile) }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RemoteEnvironmentStorageError(.unsafeFile) }; offset += count
            }
            var after = stat()
            guard fstat(fd, &after) == 0, after.st_size == info.st_size,
                  after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
                throw RemoteEnvironmentStorageError(.unsafeFile)
            }
            return Data(bytes)
        }
        func write(_ data: Data, name: String, maximum: Int) throws {
            guard data.count <= maximum else { throw RemoteEnvironmentStorageError(.limitExceeded) }
            let temporary = ".remote-atomic-" + UUID().uuidString
            let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw RemoteEnvironmentStorageError(.unsafeFile) }
            defer { Darwin.close(fd); _ = unlinkat(descriptor, temporary, 0) }
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RemoteEnvironmentStorageError(.unsafeFile) }; offset += count
            }
            guard fsync(fd) == 0, renameat(descriptor, temporary, descriptor, name) == 0, fsync(descriptor) == 0 else {
                throw RemoteEnvironmentStorageError(.unsafeFile)
            }
        }
        func remove(_ name: String) throws {
            guard unlinkat(descriptor, name, 0) == 0, fsync(descriptor) == 0 else { throw RemoteEnvironmentStorageError(.unsafeFile) }
        }
        func count(prefix: String) throws -> Int {
            let copy = dup(descriptor)
            guard copy >= 0 else { throw RemoteEnvironmentStorageError(.unsafeFile) }
            guard let directory = fdopendir(copy) else { Darwin.close(copy); throw RemoteEnvironmentStorageError(.unsafeFile) }
            defer { closedir(directory) }
            var count = 0
            while let entry = readdir(directory) {
                let length = Int(entry.pointee.d_namlen) + 1
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: length) { String(cString: $0) }
                }
                if name.hasPrefix(prefix) { count += 1 }
            }
            return count
        }
    }
}
