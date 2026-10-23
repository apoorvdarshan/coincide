import CryptoKit
import Darwin
import Foundation

/// Private, descriptor-bound allocation records live beside user folders,
/// outside every provider workspace. No Git command or setup script is run.
public final class ScratchWorkspaceService: Sendable {
    static let maximumAllocations = 4_096
    static let maximumSubmissionBytes = 2 * 1_048_576
    public let dataRoot: URL
    public var root: URL { dataRoot.appendingPathComponent("Scratch", isDirectory: true) }
    public init(dataRoot: URL) { self.dataRoot = dataRoot.standardizedFileURL.resolvingSymlinksInPath() }
    private struct RootRecord: Codable { let version: Int; let project: WorkspaceProject }
    private struct Intent: Codable {
        let version: Int; let commandID: UUID; let threadID: UUID; let project: ScratchProjectReceipt
        let folderName: String; let namingDigest: String; let createdAt: Date
    }
    static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public static func folderWords(_ text: String) -> String {
        let words = text.lowercased().split { character in
            !character.unicodeScalars.allSatisfy { (97...122).contains($0.value) || (48...57).contains($0.value) }
        }.prefix(5).joined(separator: "-")
        return String(words.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    private static func name(_ prefix: String, _ id: UUID) -> String { prefix + "-" + id.uuidString.lowercased() + ".json" }
    private func withRoot<T>(create: Bool, _ body: (GitWorktreeDirectory, WorkspaceProject) throws -> T) throws -> T? {
        do { return try withVerifiedRoot(create: create, body) }
        catch let error as ScratchWorkspaceError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw ScratchWorkspaceError() }
    }
    /// This boundary handles only private filesystem/codec operations. Missing,
    /// replaced or malformed claims refuse the action without poisoning the
    /// Engine inbox; database commit errors do not pass through this boundary.
    private func withVerifiedRoot<T>(create: Bool, _ body: (GitWorktreeDirectory, WorkspaceProject) throws -> T) throws -> T? {
        let parent = try GitWorktreeDirectory(path: dataRoot.path)
        try Self.owner(parent, privateDirectory: false)
        let lock = try parent.lock(".coincide-scratch.lock")
        defer { withExtendedLifetime(lock) {} }
        var lockInfo = stat()
        guard fstat(lock.fd, &lockInfo) == 0, lockInfo.st_uid == getuid(), lockInfo.st_nlink == 1, lockInfo.st_mode & 0o077 == 0 else { throw ScratchWorkspaceError() }
        if try !parent.exists("Scratch") {
            guard create else { return nil }
            let stagingName = ".coincide-scratch-initializing-" + UUID().uuidString.lowercased()
            let staging = try parent.claimDirectory(stagingName)
            try Self.owner(staging)
            var project = WorkspaceProject(path: root.path)
            project.name = "No project"
            project.scratch = .init(id: UUID(), projectID: project.id, rootPath: root.path, identity: try ScratchDirectoryIdentity(staging), createdAt: Date())
            try staging.writeExclusive(Self.bytes(RootRecord(version: 1, project: project)), name: ".coincide-scratch-project.json")
            try parent.validate()
            guard renameatx_np(parent.fd, stagingName, parent.fd, "Scratch", UInt32(RENAME_EXCL)) == 0, fsync(parent.fd) == 0 else { throw ScratchWorkspaceError() }
        }
        let directory = try GitWorktreeDirectory(child: "Scratch", parent: parent)
        try Self.owner(directory)
        guard let bytes = try Self.read(".coincide-scratch-project.json", in: directory),
              let record = try? JSONDecoder().decode(RootRecord.self, from: bytes), record.version == 1,
              let receipt = record.project.scratch, receipt.validates(record.project), receipt.identity.matches(directory),
              receipt.rootPath.utf8.elementsEqual(root.path.utf8) else { throw ScratchWorkspaceError() }
        return try body(directory, record.project)
    }
    public func prepare(commandID: UUID, threadID: UUID, namingText: String, now: Date = Date()) throws -> ScratchWorkspaceAllocation {
        guard namingText.utf16.count <= 120_000, now.timeIntervalSince1970.isFinite else { throw ScratchWorkspaceError() }
        let namingDigest = Self.digest(Data(namingText.utf8))
        guard let value = try withRoot(create: true, { directory, project in
            guard let projectReceipt = project.scratch else { throw ScratchWorkspaceError() }
            guard try !directory.exists(Self.name("cancelled", commandID)) else { throw ScratchWorkspaceError("This scratch allocation was discarded. Start a new conversation instead.") }
            if let existing = try load(commandID, directory: directory, project: project) {
                guard existing.threadID == threadID, existing.receipt.namingDigest == namingDigest, existing.receipt.sharedFrom == nil else { throw ScratchWorkspaceError("The original scratch request changed. Its folder was preserved.") }
                return existing
            }
            if try directory.exists(Self.name("intent", commandID)) { throw ScratchWorkspaceError("An interrupted scratch allocation was preserved. Inspect its saved allocation before creating another conversation.") }
            guard try Self.names(directory).filter({ $0.hasPrefix("intent-") || $0.hasPrefix("grant-") }).count < Self.maximumAllocations else { throw ScratchWorkspaceError("The private scratch allocation limit was reached. Existing work was preserved.") }
            let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.calendar = Calendar(identifier: .gregorian)
            date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "yyyy-MM-dd"
            let words = Self.folderWords(namingText), id = threadID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let prefix = [date.string(from: now), words].filter { !$0.isEmpty }.joined(separator: "-")
            var chosen: String?
            for attempt in 0..<100 {
                let suffix = attempt == 0 ? String(id.suffix(8)) : attempt == 1 ? id : id + "-" + String(UUID().uuidString.lowercased().prefix(8))
                let name = prefix + "-" + suffix
                if try !directory.exists(name) { chosen = name; break }
            }
            guard let folderName = chosen else { throw ScratchWorkspaceError("A unique scratch folder could not be allocated. Existing work was preserved.") }
            let intent = Intent(version: 1, commandID: commandID, threadID: threadID, project: projectReceipt,
                folderName: folderName, namingDigest: namingDigest, createdAt: now)
            try directory.writeExclusive(Self.bytes(intent), name: Self.name("intent", commandID))
            let folder = try directory.claimDirectory(folderName)
            try Self.owner(folder)
            let receipt = ScratchWorkspaceReceipt(commandID: commandID, threadID: threadID, project: projectReceipt,
                folderName: folderName, identity: try ScratchDirectoryIdentity(folder), namingDigest: namingDigest, createdAt: now)
            let allocation = ScratchWorkspaceAllocation(receipt: receipt, project: project)
            try directory.writeExclusive(Self.bytes(allocation), name: Self.name("allocation", commandID))
            return allocation
        }) else { throw ScratchWorkspaceError() }
        return value
    }
    /// A fresh native context may deliberately share an already-owned folder.
    /// Its distinct grant never authorizes folder removal, even if it is empty.
    func reuse(source: ScratchWorkspaceReceipt, commandID: UUID, threadID: UUID, now: Date = Date()) throws -> ScratchWorkspaceAllocation {
        guard let allocation = try withRoot(create: false, { directory, project in
            try validate(source, directory: directory, project: project)
            guard try !directory.exists(Self.name("cancelled", commandID)) else { throw ScratchWorkspaceError() }
            if let prior = try load(commandID, directory: directory, project: project) {
                guard prior.threadID == threadID, prior.receipt.sharedFrom == (source.sharedFrom ?? source.commandID) else { throw ScratchWorkspaceError() }
                return prior
            }
            guard let root = project.scratch, threadID != source.threadID,
                  try Self.names(directory).filter({ $0.hasPrefix("intent-") || $0.hasPrefix("grant-") }).count < Self.maximumAllocations else { throw ScratchWorkspaceError() }
            let receipt = ScratchWorkspaceReceipt(commandID: commandID, threadID: threadID, project: root,
                folderName: source.folderName, identity: source.identity, namingDigest: source.namingDigest, createdAt: now,
                sharedFrom: source.sharedFrom ?? source.commandID)
            let value = ScratchWorkspaceAllocation(receipt: receipt, project: project)
            try directory.writeExclusive(Self.bytes(value), name: Self.name("grant", commandID))
            return value
        }) else { throw ScratchWorkspaceError() }
        return allocation
    }
    func validate(_ allocation: ScratchWorkspaceAllocation) throws {
        guard try withRoot(create: false, { directory, project in
            guard try load(allocation.receipt.commandID, directory: directory, project: project) == allocation else { throw ScratchWorkspaceError() }
            return true
        }) == true else { throw ScratchWorkspaceError() }
    }
    public func validate(thread: CodingThread) throws {
        guard let receipt = thread.scratchWorkspace else { throw ScratchWorkspaceError() }
        guard try withRoot(create: false, { directory, project in
            guard receipt.validates(thread: thread, project: project) else { throw ScratchWorkspaceError() }
            try validate(receipt, directory: directory, project: project); return true
        }) == true else { throw ScratchWorkspaceError() }
    }
    func recordSubmission(_ creation: ScratchThreadCreation, payload: Data) throws {
        try creation.validate()
        try recordPayload(allocation: creation.allocation, payload: payload)
    }
    /// The receipt fingerprint is the original native/remote outer command,
    /// rather than a second synthetic creation command or a replay convenience.
    func recordPayload(allocation: ScratchWorkspaceAllocation, payload: Data) throws {
        guard payload.count <= Self.maximumSubmissionBytes else { throw ScratchWorkspaceError("The scratch request exceeds its private storage limit.") }
        guard try withRoot(create: false, { directory, project in
            guard try !directory.exists(Self.name("cancelled", allocation.receipt.commandID)),
                  try load(allocation.receipt.commandID, directory: directory, project: project) == allocation else { throw ScratchWorkspaceError() }
            let name = Self.name("submission", allocation.receipt.commandID)
            if let previous = try Self.read(name, in: directory, maximum: Self.maximumSubmissionBytes) {
                guard previous == payload else { throw ScratchWorkspaceError("The original scratch command changed. Its saved request was preserved.") }
            } else { try Self.write(payload, name: name, in: directory) }
            return true
        }) == true else { throw ScratchWorkspaceError() }
    }
    func submission(_ id: UUID) throws -> Data? {
        try withRoot(create: false) { directory, _ in try Self.read(Self.name("submission", id), in: directory, maximum: Self.maximumSubmissionBytes) } ?? nil
    }
    func allocations(limit: Int = 64, offset: Int = 0) throws -> [(UUID, ScratchWorkspaceAllocation?, Bool)] {
        guard (1...256).contains(limit), (0...Self.maximumAllocations).contains(offset) else { throw ScratchWorkspaceError() }
        return try withRoot(create: false) { directory, project in
            let names = try Self.names(directory).sorted()
            let ids = Set(names.compactMap { name -> UUID? in
                guard name.hasPrefix("intent-") || name.hasPrefix("grant-") else { return nil }
                return UUID(uuidString: String(name.dropFirst(name.hasPrefix("intent-") ? 7 : 6).dropLast(5)))
            }).sorted { $0.uuidString < $1.uuidString }.dropFirst(offset).prefix(limit)
            return try ids.map { id in
                let value: ScratchWorkspaceAllocation?
                // Missing/replaced folders remain listed for inspection. Their
                // receipts cannot grant readiness or deletion authority.
                if let bytes = try Self.read(Self.name("allocation", id), in: directory) ?? Self.read(Self.name("grant", id), in: directory) {
                    value = try JSONDecoder().decode(ScratchWorkspaceAllocation.self, from: bytes)
                } else { value = nil }
                return (id, value, try directory.exists(Self.name("cancelled", id)))
            }
        } ?? []
    }
    /// Caller first resolves/rejects the exact original command in the database.
    /// rmdir is the final emptiness check: it cannot remove any user file.
    func discardEmpty(_ id: UUID) throws -> Bool {
        try withRoot(create: false) { directory, project in
            guard let allocation = try load(id, directory: directory, project: project) else { return false }
            let receipt = allocation.receipt
            if receipt.sharedFrom != nil {
                if try !directory.exists(Self.name("cancelled", id)) { try directory.writeExclusive(Data("cancelled\n".utf8), name: Self.name("cancelled", id)) }
                return true
            }
            let folder = try GitWorktreeDirectory(child: receipt.folderName, parent: directory)
            try folder.validate(expected: receipt.identity.node); guard receipt.identity.matches(folder) else { throw ScratchWorkspaceError() }; try Self.owner(folder)
            guard try Self.names(folder).isEmpty else { return false }
            if try !directory.exists(Self.name("cancelled", id)) { try directory.writeExclusive(Data("cancelled\n".utf8), name: Self.name("cancelled", id)) }
            try folder.validate(expected: receipt.identity.node); guard receipt.identity.matches(folder) else { throw ScratchWorkspaceError() }; try directory.validate()
            guard unlinkat(directory.fd, receipt.folderName, AT_REMOVEDIR) == 0 else { return false }
            guard fsync(directory.fd) == 0 else { throw ScratchWorkspaceError() }
            return true
        } ?? false
    }
    private func load(_ id: UUID, directory: GitWorktreeDirectory, project: WorkspaceProject) throws -> ScratchWorkspaceAllocation? {
        guard let bytes = try Self.read(Self.name("allocation", id), in: directory) ?? Self.read(Self.name("grant", id), in: directory) else { return nil }
        let value = try JSONDecoder().decode(ScratchWorkspaceAllocation.self, from: bytes)
        guard value.receipt.commandID == id, value.project.scratch == project.scratch,
              value.project.id == project.id, value.project.path.utf8.elementsEqual(project.path.utf8) else { throw ScratchWorkspaceError() }
        try validate(value.receipt, directory: directory, project: project)
        return value
    }
    private func validate(_ receipt: ScratchWorkspaceReceipt, directory: GitWorktreeDirectory, project: WorkspaceProject, seen: Set<UUID> = []) throws {
        guard seen.count < 32, !seen.contains(receipt.commandID), receipt.project == project.scratch,
              try !directory.exists(Self.name("cancelled", receipt.commandID)),
              receipt.identity.inode != 0, !receipt.folderName.hasPrefix("."),
              receipt.folderName.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }) else { throw ScratchWorkspaceError() }
        let name = Self.name(receipt.sharedFrom == nil ? "allocation" : "grant", receipt.commandID)
        guard let bytes = try Self.read(name, in: directory),
              let value = try? JSONDecoder().decode(ScratchWorkspaceAllocation.self, from: bytes), value.receipt == receipt else { throw ScratchWorkspaceError() }
        if let parent = receipt.sharedFrom {
            guard let bytes = try Self.read(Self.name("allocation", parent), in: directory) ?? Self.read(Self.name("grant", parent), in: directory) else { throw ScratchWorkspaceError() }
            let source = try JSONDecoder().decode(ScratchWorkspaceAllocation.self, from: bytes).receipt
            guard source.folderName == receipt.folderName, source.identity == receipt.identity, source.project == receipt.project else { throw ScratchWorkspaceError() }
            try validate(source, directory: directory, project: project, seen: seen.union([receipt.commandID]))
        }
        let folder = try GitWorktreeDirectory(child: receipt.folderName, parent: directory)
        try folder.validate(expected: receipt.identity.node); guard receipt.identity.matches(folder) else { throw ScratchWorkspaceError() }; try Self.owner(folder)
    }
    private static func owner(_ directory: GitWorktreeDirectory, privateDirectory: Bool = true) throws {
        try directory.validate(); var info = stat()
        guard fstat(directory.fd, &info) == 0, info.st_uid == getuid(), info.st_mode & (privateDirectory ? 0o077 : 0o022) == 0 else { throw ScratchWorkspaceError() }
    }
    private static func read(_ name: String, in directory: GitWorktreeDirectory, maximum: Int = 65_536) throws -> Data? {
        var info = stat()
        if fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return nil }; throw ScratchWorkspaceError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw ScratchWorkspaceError() }
        return try directory.read(name, maximum: maximum)
    }
    private static func write(_ bytes: Data, name: String, in directory: GitWorktreeDirectory) throws {
        try directory.validate()
        let temporary = ".scratch-write-" + UUID().uuidString.lowercased()
        let fd = openat(directory.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ScratchWorkspaceError() }
        var owned = stat(); guard fstat(fd, &owned) == 0 else { Darwin.close(fd); throw ScratchWorkspaceError() }
        var promoted = false
        defer { Darwin.close(fd); if !promoted { var now = stat(); if fstatat(directory.fd, temporary, &now, AT_SYMLINK_NOFOLLOW) == 0, worktreeIdentity(now) == worktreeIdentity(owned) { _ = unlinkat(directory.fd, temporary, 0) } } }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), min(65_536, raw.count - offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ScratchWorkspaceError() }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ScratchWorkspaceError() }; try directory.validate()
        guard renameatx_np(directory.fd, temporary, directory.fd, name, UInt32(RENAME_EXCL)) == 0 else { throw ScratchWorkspaceError() }
        promoted = true; guard fsync(directory.fd) == 0 else { throw ScratchWorkspaceError() }
    }
    private static func names(_ directory: GitWorktreeDirectory) throws -> [String] {
        try directory.validate()
        let copy = dup(directory.fd); guard copy >= 0 else { throw ScratchWorkspaceError() }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw ScratchWorkspaceError() }
        defer { closedir(stream) }
        var result: [String] = []; errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
            if name != ".", name != ".." { result.append(name) }
            guard result.count <= 32_768 else { throw ScratchWorkspaceError("The private scratch directory exceeded its bounded inventory. Existing contents were preserved.") }
            errno = 0
        }
        guard errno == 0 else { throw ScratchWorkspaceError() }; try directory.validate(); return result
    }
}
