import CryptoKit
import Darwin
import Foundation

public struct ClaudeTranscriptStoreError: LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable { case invalidLocation, notFound, ambiguous, invalidFile, unsupportedLocation, sourceChanged, collision, unavailable, publicationUncertain }
    public let kind: Kind
    public var mayHavePublished: Bool { kind == .publicationUncertain }
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidLocation: "The exact Claude transcript location is invalid."
        case .notFound: "The exact Claude transcript is unavailable. Relocated and worktree lookup are not inferred."
        case .ambiguous: "More than one explicit Claude project location contains this session."
        case .invalidFile: "The Claude transcript is not a stable, owned, bounded regular file."
        case .unsupportedLocation: "The native transcript does not prove this exact workspace."
        case .sourceChanged: "The reviewed Claude transcript changed. Review its current history again."
        case .collision: "The reserved Claude transcript destination already exists. It was preserved."
        case .unavailable: "The exact Claude transcript could not be accessed safely."
        case .publicationUncertain: "Claude transcript publication could not be confirmed. The exact destination was preserved and was not repeated."
        }
    }
}

public struct ClaudeTranscriptLocation: Codable, Sendable, Equatable {
    public let configurationDirectory: String
    public let workspacePath: String
    public let projectDirectoryName: String
    public let sessionID: String
    public init(configurationDirectory: String, workspacePath: String, projectDirectoryName: String, sessionID: String) throws {
        self.configurationDirectory = configurationDirectory; self.workspacePath = workspacePath
        self.projectDirectoryName = projectDirectoryName; self.sessionID = sessionID
        try validate()
    }
    public func validate() throws {
        try ClaudeTranscriptStoreValidation.path(configurationDirectory); try ClaudeTranscriptStoreValidation.path(workspacePath)
        try ClaudeTranscriptStoreValidation.uuid(sessionID)
        guard !projectDirectoryName.isEmpty, projectDirectoryName.utf8.count <= 256,
              projectDirectoryName.utf8.allSatisfy({ ClaudeTranscriptStoreValidation.asciiAlphanumeric($0) || $0 == 45 || $0 == 95 }) else {
            throw ClaudeTranscriptStoreError(.invalidLocation)
        }
    }
}

public struct ClaudeTranscriptRevision: Codable, Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    public let digest: String
    fileprivate init(_ info: stat, data: Data) {
        device = UInt64(bitPattern: Int64(info.st_dev)); inode = UInt64(info.st_ino); byteCount = Int64(data.count)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        digest = ClaudeTranscriptStoreValidation.digest(data)
    }
    public func validate() throws {
        guard inode != 0, (1...Int64(ClaudeTranscriptStore.maximumBytes)).contains(byteCount),
              (0..<1_000_000_000).contains(modifiedNanoseconds), (0..<1_000_000_000).contains(changedNanoseconds),
              ClaudeTranscriptStoreValidation.isDigest(digest) else { throw ClaudeTranscriptStoreError(.invalidFile) }
    }
}

public struct ClaudeTranscriptSnapshot: Sendable {
    public let location: ClaudeTranscriptLocation
    public let revision: ClaudeTranscriptRevision
    public let transcript: ClaudeTranscript
}

/// Durable reservation/proof metadata. No source or target transcript text is encoded.
/// Every store entry validates decoded values again before opening any location.
public struct ClaudeTranscriptPublication: Codable, Sendable, Equatable {
    public let source: ClaudeTranscriptLocation
    public let sourceRevision: ClaudeTranscriptRevision
    public let target: ClaudeTranscriptLocation
    public let targetDigest: String
    public let targetByteCount: Int64
    public let upToMessageID: String?
    public let sourceToForkMessageIDs: [String: String]
    public let headMessageID: String?
    public init(source: ClaudeTranscriptLocation, sourceRevision: ClaudeTranscriptRevision, target: ClaudeTranscriptLocation,
                targetDigest: String, targetByteCount: Int64, upToMessageID: String?,
                sourceToForkMessageIDs: [String: String], headMessageID: String?) throws {
        self.source = source; self.sourceRevision = sourceRevision; self.target = target
        self.targetDigest = targetDigest; self.targetByteCount = targetByteCount; self.upToMessageID = upToMessageID
        self.sourceToForkMessageIDs = sourceToForkMessageIDs; self.headMessageID = headMessageID
        try validate()
    }
    public func validate() throws {
        try source.validate(); try target.validate(); try sourceRevision.validate()
        if let upToMessageID { try ClaudeTranscriptStoreValidation.uuid(upToMessageID) }
        if let headMessageID { try ClaudeTranscriptStoreValidation.uuid(headMessageID) }
        guard UUID(uuidString: source.sessionID) != UUID(uuidString: target.sessionID),
              source.configurationDirectory == target.configurationDirectory, source.workspacePath == target.workspacePath,
              source.projectDirectoryName == target.projectDirectoryName,
              (1...Int64(ClaudeTranscriptStore.maximumBytes)).contains(targetByteCount),
              ClaudeTranscriptStoreValidation.isDigest(targetDigest), sourceToForkMessageIDs.count <= 20_000,
              Set(sourceToForkMessageIDs.values.compactMap(UUID.init(uuidString:))).count == sourceToForkMessageIDs.count,
              Set(sourceToForkMessageIDs.keys.compactMap(UUID.init(uuidString:))).count == sourceToForkMessageIDs.count else {
            throw ClaudeTranscriptStoreError(.invalidLocation)
        }
        for (source, target) in sourceToForkMessageIDs {
            try ClaudeTranscriptStoreValidation.uuid(source); try ClaudeTranscriptStoreValidation.uuid(target)
        }
    }
}

public struct ClaudeTranscriptForkPlan: Sendable {
    public let publication: ClaudeTranscriptPublication
    fileprivate let bytes: Data
}

public enum ClaudeTranscriptPublicationInspection: Sendable {
    case notStarted
    /// An existing partial, changed or semantically different destination is never removed.
    case incomplete
    case ready(ClaudeTranscriptSnapshot)
}

enum ClaudeTranscriptStoreIOPhase: Sendable { case readOpened, sourceRevalidated, targetCreated }

/// Explicit native filesystem scope. It never launches Git/Claude or scans other
/// projects, homes, accounts or worktrees. Directories must be physical paths.
public struct ClaudeTranscriptStore: Sendable {
    public static let maximumBytes = 16 * 1_024 * 1_024
    public let configurationDirectory: String
    public let workspacePath: String
    private let projectNames: [String]
    private let observer: (@Sendable (ClaudeTranscriptStoreIOPhase) throws -> Void)?

    public init(configurationDirectory: URL, workspace: URL, projectDirectoryName: String? = nil) throws {
        try self.init(configurationDirectory: configurationDirectory, workspace: workspace, projectDirectoryName: projectDirectoryName, observer: nil)
    }
    init(configurationDirectory: URL, workspace: URL, projectDirectoryName: String?,
         observer: (@Sendable (ClaudeTranscriptStoreIOPhase) throws -> Void)?) throws {
        guard configurationDirectory.isFileURL, workspace.isFileURL else { throw ClaudeTranscriptStoreError(.invalidLocation) }
        let root = configurationDirectory.path.precomposedStringWithCanonicalMapping
        try ClaudeTranscriptStoreValidation.path(root)
        self.configurationDirectory = root
        workspacePath = try ClaudeTranscriptStoreValidation.physicalWorkspace(workspace.path)
        let legacy = try Self.projectDirectoryName(forPhysicalWorkspacePath: workspacePath)
        if let projectDirectoryName {
            try ClaudeTranscriptStoreValidation.override(projectDirectoryName)
            projectNames = projectDirectoryName == legacy ? [legacy] : [projectDirectoryName, legacy]
        } else { projectNames = [legacy] }
        self.observer = observer
    }

    /// SDK0.3.276 hashes original NFC path UTF-16 units, not the sanitized key.
    public static func projectDirectoryName(forPhysicalWorkspacePath path: String) throws -> String {
        let path = path.precomposedStringWithCanonicalMapping
        try ClaudeTranscriptStoreValidation.path(path)
        let units = Array(path.utf16)
        let sanitized = String(decoding: units.map { unit -> UInt8 in
            unit < 128 && ClaudeTranscriptStoreValidation.asciiAlphanumeric(UInt8(unit)) ? UInt8(unit) : 45
        }, as: UTF8.self)
        guard sanitized.utf8.count > 200 else { return sanitized }
        var hash: Int32 = 0
        for unit in units { hash = hash &* 31 &+ Int32(unit) }
        return String(sanitized.prefix(200)) + "-" + String(abs(Int64(hash)), radix: 36)
    }

    public func read(sessionID: String) throws -> ClaudeTranscriptSnapshot {
        try ClaudeTranscriptStoreValidation.uuid(sessionID)
        var found: [ClaudeTranscriptSnapshot] = []
        for name in projectNames {
            let location = try ClaudeTranscriptLocation(configurationDirectory: configurationDirectory, workspacePath: workspacePath,
                projectDirectoryName: name, sessionID: sessionID)
            do { found.append(try read(location)) }
            catch let error as ClaudeTranscriptStoreError where error.kind == .notFound { continue }
        }
        guard found.count <= 1 else { throw ClaudeTranscriptStoreError(.ambiguous) }
        guard let snapshot = found.first else { throw ClaudeTranscriptStoreError(.notFound) }
        return snapshot
    }

    public func prepareFork(source: ClaudeTranscriptSnapshot, upToMessageID: String?, targetSessionID: String) throws -> ClaudeTranscriptForkPlan {
        try validate(source.location); try source.revision.validate(); try ClaudeTranscriptStoreValidation.uuid(targetSessionID)
        guard UUID(uuidString: targetSessionID) != UUID(uuidString: source.location.sessionID) else { throw ClaudeTranscriptStoreError(.invalidLocation) }
        let current = try read(source.location)
        guard current.revision == source.revision else { throw ClaudeTranscriptStoreError(.sourceChanged) }
        let fork = try current.transcript.fork(upToMessageID: upToMessageID, targetSessionID: targetSessionID, sourceSessionID: source.location.sessionID)
        try current.transcript.validateFork(fork, upToMessageID: upToMessageID, targetSessionID: targetSessionID, sourceSessionID: source.location.sessionID)
        let bytes = try encode(fork.records)
        let target = try ClaudeTranscriptLocation(configurationDirectory: configurationDirectory, workspacePath: workspacePath,
            projectDirectoryName: source.location.projectDirectoryName, sessionID: targetSessionID)
        let publication = try ClaudeTranscriptPublication(source: source.location, sourceRevision: source.revision,
            target: target, targetDigest: ClaudeTranscriptStoreValidation.digest(bytes), targetByteCount: Int64(bytes.count),
            upToMessageID: upToMessageID, sourceToForkMessageIDs: fork.sourceToForkMessageIDs, headMessageID: fork.headMessageID)
        return .init(publication: publication, bytes: bytes)
    }

    public func publish(_ plan: ClaudeTranscriptForkPlan) throws -> ClaudeTranscriptPublication {
        let publication = plan.publication
        try validate(publication)
        guard Int64(plan.bytes.count) == publication.targetByteCount,
              ClaudeTranscriptStoreValidation.digest(plan.bytes) == publication.targetDigest else { throw ClaudeTranscriptStoreError(.invalidFile) }
        let source = try read(publication.source)
        guard source.revision == publication.sourceRevision else { throw ClaudeTranscriptStoreError(.sourceChanged) }
        try validateTarget(plan.bytes, source: source, publication: publication)
        let parent = try projectDirectory(publication.target)
        try parent.validate(); try observer?(.sourceRevalidated)
        // Re-read after observer/admission work, immediately before exclusive create.
        guard try read(publication.source).revision == publication.sourceRevision else { throw ClaudeTranscriptStoreError(.sourceChanged) }
        try parent.validate(); try Task.checkCancellation()
        let name = publication.target.sessionID + ".jsonl"
        let descriptor = name.withCString { openat(parent.descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600)) }
        guard descriptor >= 0 else { throw ClaudeTranscriptStoreError(errno == EEXIST ? .collision : .unavailable) }
        defer { _ = Darwin.close(descriptor) }
        do {
            guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw ClaudeTranscriptStoreError(.unavailable) }
            try observer?(.targetCreated)
            try plan.bytes.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw ClaudeTranscriptStoreError(.unavailable) }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw ClaudeTranscriptStoreError(.unavailable) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw ClaudeTranscriptStoreError(.invalidFile) }
            try ClaudeTranscriptStoreValidation.file(info)
            guard info.st_size == publication.targetByteCount, info.st_mode & 0o777 == 0o600 else { throw ClaudeTranscriptStoreError(.invalidFile) }
            try parent.validate(); try parent.matches(name: name, info: info)
            guard fsync(parent.descriptor) == 0 else { throw ClaudeTranscriptStoreError(.unavailable) }
            guard try read(publication.source).revision == publication.sourceRevision else { throw ClaudeTranscriptStoreError(.sourceChanged) }
            let target = try read(publication.target)
            guard target.revision.digest == publication.targetDigest, target.revision.byteCount == publication.targetByteCount else { throw ClaudeTranscriptStoreError(.invalidFile) }
            let finalBytes = try readBytes(publication.target).data
            guard Int64(finalBytes.count) == publication.targetByteCount,
                  ClaudeTranscriptStoreValidation.digest(finalBytes) == publication.targetDigest else { throw ClaudeTranscriptStoreError(.invalidFile) }
            try validateTarget(finalBytes, source: source, publication: publication)
            return publication
        } catch { throw ClaudeTranscriptStoreError(.publicationUncertain) }
    }

    public func inspect(_ publication: ClaudeTranscriptPublication) throws -> ClaudeTranscriptPublicationInspection {
        try validate(publication)
        let source = try read(publication.source)
        guard source.revision == publication.sourceRevision else { throw ClaudeTranscriptStoreError(.sourceChanged) }
        let bytes: Data
        do { bytes = try readBytes(publication.target).data }
        catch let error as ClaudeTranscriptStoreError where error.kind == .notFound { return .notStarted }
        catch let error as ClaudeTranscriptStoreError where error.kind == .invalidFile { return .incomplete }
        guard Int64(bytes.count) == publication.targetByteCount, ClaudeTranscriptStoreValidation.digest(bytes) == publication.targetDigest else { return .incomplete }
        do { try validateTarget(bytes, source: source, publication: publication) }
        catch { return .incomplete }
        let target = try read(publication.target)
        guard target.revision.digest == publication.targetDigest, target.revision.byteCount == publication.targetByteCount,
              try read(publication.source).revision == publication.sourceRevision else { throw ClaudeTranscriptStoreError(.sourceChanged) }
        return .ready(target)
    }

    private func validate(_ location: ClaudeTranscriptLocation) throws {
        try location.validate()
        guard location.configurationDirectory == configurationDirectory, location.workspacePath == workspacePath,
              projectNames.contains(location.projectDirectoryName) else { throw ClaudeTranscriptStoreError(.invalidLocation) }
    }
    private func validate(_ publication: ClaudeTranscriptPublication) throws {
        try publication.validate(); try validate(publication.source); try validate(publication.target)
    }
    private func projectDirectory(_ location: ClaudeTranscriptLocation) throws -> ClaudeTranscriptDirectory {
        try validate(location)
        let root = try ClaudeTranscriptDirectory(path: configurationDirectory)
        try root.requireOwner()
        let projects = try ClaudeTranscriptDirectory(name: "projects", parent: root); try projects.requireOwner()
        let project = try ClaudeTranscriptDirectory(name: location.projectDirectoryName, parent: projects); try project.requireOwner()
        return project
    }
    private func read(_ location: ClaudeTranscriptLocation) throws -> ClaudeTranscriptSnapshot {
        let read = try readBytes(location)
        let transcript = try ClaudeTranscript.parse(read.data)
        try validateWorkspace(transcript.records, location: location)
        return .init(location: location, revision: read.revision, transcript: transcript)
    }
    private func readBytes(_ location: ClaudeTranscriptLocation) throws -> (data: Data, revision: ClaudeTranscriptRevision) {
        let parent = try projectDirectory(location), name = location.sessionID + ".jsonl"
        let descriptor = name.withCString { openat(parent.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else { throw ClaudeTranscriptStoreError(errno == ENOENT ? .notFound : .invalidFile) }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw ClaudeTranscriptStoreError(.invalidFile) }
        try ClaudeTranscriptStoreValidation.file(before); try parent.matches(name: name, info: before)
        try observer?(.readOpened)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ClaudeTranscriptStoreError(.invalidFile) }
            if count == 0 { break }
            guard data.count <= Self.maximumBytes - count else { throw ClaudeTranscriptStoreError(.invalidFile) }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, ClaudeTranscriptStoreValidation.same(before, after), after.st_size == data.count else {
            throw ClaudeTranscriptStoreError(.sourceChanged)
        }
        try parent.validate(); try parent.matches(name: name, info: after)
        let revision = ClaudeTranscriptRevision(after, data: data); try revision.validate()
        return (data, revision)
    }
    private func validateWorkspace(_ records: [JSONValue], location: ClaudeTranscriptLocation) throws {
        var initial: String?, relocated: String?, sessionObserved = false
        for record in records {
            if let id = record["sessionId"].string {
                guard UUID(uuidString: id) == UUID(uuidString: location.sessionID) else { throw ClaudeTranscriptStoreError(.invalidFile) }
                sessionObserved = true
            }
            if initial == nil { initial = record["cwd"].string }
            if record["type"].string == "relocated", let value = record["relocatedCwd"].string { relocated = value }
        }
        guard sessionObserved, let observed = relocated ?? initial,
              try ClaudeTranscriptStoreValidation.physicalWorkspace(observed) == workspacePath else {
            throw ClaudeTranscriptStoreError(.unsupportedLocation)
        }
    }
    private func validateTarget(_ data: Data, source: ClaudeTranscriptSnapshot, publication: ClaudeTranscriptPublication) throws {
        let transcript = try ClaudeTranscript.parse(data)
        try validateWorkspace(transcript.records, location: publication.target)
        let fork = ClaudeTranscriptFork(records: transcript.records, sourceToForkMessageIDs: publication.sourceToForkMessageIDs, headMessageID: publication.headMessageID)
        try source.transcript.validateFork(fork, upToMessageID: publication.upToMessageID,
            targetSessionID: publication.target.sessionID, sourceSessionID: publication.source.sessionID)
    }
    private func encode(_ records: [JSONValue]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for record in records {
            let line = try encoder.encode(record)
            guard line.count < Self.maximumBytes, data.count <= Self.maximumBytes - line.count - 1 else { throw ClaudeTranscriptStoreError(.invalidFile) }
            data.append(line); data.append(10)
        }
        guard !data.isEmpty else { throw ClaudeTranscriptStoreError(.invalidFile) }
        return data
    }
}

private enum ClaudeTranscriptStoreValidation {
    static func asciiAlphanumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
    static func uuid(_ value: String) throws {
        guard value.utf8.count == 36, UUID(uuidString: value) != nil else { throw ClaudeTranscriptStoreError(.invalidLocation) }
    }
    static func path(_ value: String) throws {
        guard value.hasPrefix("/"), value != "/", value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              !value.contains("//"), !value.hasSuffix("/") else { throw ClaudeTranscriptStoreError(.invalidLocation) }
    }
    static func override(_ value: String) throws {
        let lowered = value.lowercased()
        let reserved = ["con", "prn", "aux", "nul"] + (0...9).flatMap { ["com\($0)", "lpt\($0)"] }
        guard (1...64).contains(value.utf8.count), !reserved.contains(lowered),
              value.utf8.allSatisfy({ asciiAlphanumeric($0) || $0 == 45 || $0 == 95 }) else { throw ClaudeTranscriptStoreError(.invalidLocation) }
    }
    static func physicalWorkspace(_ path: String) throws -> String {
        try self.path(path)
        guard let pointer = path.withCString({ realpath($0, nil) }) else { throw ClaudeTranscriptStoreError(.unsupportedLocation) }
        defer { free(pointer) }
        let physical = String(cString: pointer).precomposedStringWithCanonicalMapping
        let directory = try ClaudeTranscriptDirectory(path: physical); try directory.validate()
        return physical
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func isDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func file(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              (1...Int64(ClaudeTranscriptStore.maximumBytes)).contains(info.st_size) else { throw ClaudeTranscriptStoreError(.invalidFile) }
    }
    static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}

private final class ClaudeTranscriptDirectory {
    let descriptor: Int32
    private let identity: stat
    private let parent: ClaudeTranscriptDirectory?
    private let name: String?
    init(path: String) throws {
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ClaudeTranscriptStoreError(.unavailable) }
        var current = try ClaudeTranscriptDirectory(descriptor: root, parent: nil, name: nil)
        for component in path.split(separator: "/") { current = try .init(name: String(component), parent: current) }
        descriptor = fcntl(current.descriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw ClaudeTranscriptStoreError(.unavailable) }
        identity = current.identity; parent = current.parent; name = current.name
    }
    convenience init(name: String, parent: ClaudeTranscriptDirectory) throws {
        try parent.validate()
        let descriptor = name.withCString { openat(parent.descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw ClaudeTranscriptStoreError(errno == ENOENT ? .notFound : .invalidFile) }
        try self.init(descriptor: descriptor, parent: parent, name: name)
        try parent.matches(name: name, info: identity)
    }
    private init(descriptor: Int32, parent: ClaudeTranscriptDirectory?, name: String?) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            _ = Darwin.close(descriptor); throw ClaudeTranscriptStoreError(.invalidFile)
        }
        self.descriptor = descriptor; identity = info; self.parent = parent; self.name = name
    }
    func requireOwner() throws { guard identity.st_uid == geteuid() else { throw ClaudeTranscriptStoreError(.invalidFile) } }
    func validate() throws {
        var current = stat()
        guard fstat(descriptor, &current) == 0, current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              current.st_uid == identity.st_uid, current.st_mode & S_IFMT == S_IFDIR else { throw ClaudeTranscriptStoreError(.sourceChanged) }
        if let parent, let name { try parent.validate(); try parent.matches(name: name, info: current) }
    }
    func matches(name: String, info: stat) throws {
        var named = stat()
        guard name.withCString({ fstatat(descriptor, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              named.st_dev == info.st_dev, named.st_ino == info.st_ino, named.st_mode == info.st_mode,
              named.st_uid == info.st_uid, named.st_nlink == info.st_nlink else { throw ClaudeTranscriptStoreError(.sourceChanged) }
        if info.st_mode & S_IFMT == S_IFREG, !ClaudeTranscriptStoreValidation.same(info, named) { throw ClaudeTranscriptStoreError(.sourceChanged) }
    }
    deinit { _ = Darwin.close(descriptor) }
}
