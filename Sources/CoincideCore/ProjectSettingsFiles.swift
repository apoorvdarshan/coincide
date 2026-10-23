import CryptoKit
import Darwin
import Foundation

/// The complete bytes observed under one settings key; nil means absent.
public struct ProjectSettingsRevision: Sendable, Equatable {
    public let key: String
    public let bytes: Data?
    let device: UInt64?
    let inode: UInt64?
    init(key: String, file: SavedProjectSettingsFile?) {
        self.key = key; bytes = file?.bytes; device = file?.device; inode = file?.inode
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.bytes == rhs.bytes && lhs.device == rhs.device && lhs.inode == rhs.inode
    }
}
struct SavedProjectSettingsFile { let bytes: Data; let device: UInt64; let inode: UInt64 }
public struct ProjectSettingsCapture: Sendable {
    public let keys: [String]
    public let selectedKey: String?
    public let document: ProjectSettingsDocument?
    public let revisions: [ProjectSettingsRevision]
    let rootPath: Data
    let directoryDevice: UInt64?
    let directoryInode: UInt64?
}

/// A private directory lock serializes independent windows/processes. Every
/// replacement validates the original exact bytes; corrupt or foreign-key files
/// are never reset, overwritten or removed as a migration side effect.
public enum ProjectSettingsFiles {
    public static let maximumBytes = 262_144
    static var invalid: CoincideError { CoincideError("The project settings file is not valid. It was left unchanged.") }
    private static var changed: CoincideError { CoincideError("The project settings changed. Reload them before saving; the newer file was preserved.") }
    public static func root(dataRoot: URL) -> URL {
        // Foundation deliberately preserves macOS aliases such as /var. Resolve
        // the configured data location once, before anchoring all later access
        // with O_NOFOLLOW. The data directory may not have been created yet.
        var ancestor = dataRoot
        var missing: [String] = []
        let parts = dataRoot.path.split(separator: "/")
        guard dataRoot.isFileURL, dataRoot.path.hasPrefix("/"), !dataRoot.path.contains("\0"),
              parts.allSatisfy({ $0 != "." && $0 != ".." }) else {
            return dataRoot.appendingPathComponent("ProjectSettings", isDirectory: true)
        }
        while true {
            if let physical = realpath(ancestor.path, nil) {
                defer { free(physical) }
                var resolved = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
                for component in missing.reversed() { resolved.appendPathComponent(component, isDirectory: true) }
                return resolved.appendingPathComponent("ProjectSettings", isDirectory: true)
            }
            guard errno == ENOENT, ancestor.path != "/" else {
                return dataRoot.appendingPathComponent("ProjectSettings", isDirectory: true)
            }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }
    public static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }
    public static func fileURL(root: URL, key: String) -> URL { root.appendingPathComponent(fileName(for: key), isDirectory: false) }

    public static func load(root: URL, keys: [String]) throws -> (key: String, document: ProjectSettingsDocument)? {
        let value = try capture(root: root, keys: keys)
        guard let key = value.selectedKey, let document = value.document else { return nil }
        return (key, document)
    }
    public static func load(root: URL, key: String) throws -> ProjectSettingsDocument? { try capture(root: root, keys: [key]).document }
    public static func capture(root: URL, keys: [String]) throws -> ProjectSettingsCapture {
        try validateKeys(keys)
        return try locked(root: root, create: false) { try capture(keys: keys, directory: $0, root: root) }
    }
    public static func read(fileURL: URL) throws -> ProjectSettingsDocument? {
        guard fileURL.isFileURL, fileURL.lastPathComponent.hasSuffix(".json"), !fileURL.path.contains("\0") else { throw invalid }
        return try locked(root: fileURL.deletingLastPathComponent(), create: false) { directory in
            guard let directory, let bytes = try readBytes(name: fileURL.lastPathComponent, directory: directory) else { return nil }
            return try decode(bytes)
        }
    }

    /// A supplied revision is a CAS, including absent-file creation. Without one,
    /// replacement is explicit but still refuses corrupt and mismatched contents.
    public static func save(_ document: ProjectSettingsDocument, root: URL, expectedRevision: ProjectSettingsRevision? = nil) throws {
        try document.validate()
        try locked(root: root, create: true) { directory in
            guard let directory else { throw invalid }
            let before = try capture(keys: [document.key], directory: directory, root: root)
            if let expectedRevision, expectedRevision != before.revisions[0] { throw changed }
            try verifyRoot(root, directory: directory)
            guard try capture(keys: [document.key], directory: directory, root: root).revisions == before.revisions else { throw changed }
            try write(document, directory: directory)
        }
    }

    /// Applies an edit to the latest document and migrates its valid fallback
    /// under the same lock. An editor may additionally require its captured state.
    @discardableResult
    public static func update(root: URL, keys: [String], expectedCapture: ProjectSettingsCapture? = nil,
                              change: (inout ProjectSettingsDocument) throws -> Void) throws -> ProjectSettingsDocument {
        var document = try updateCaptured(root: root, keys: keys, expectedCapture: expectedCapture, change: change).document ?? .init(key: keys.first ?? "")
        document.key = keys.first ?? document.key
        return document
    }
    /// Returns the committed document and its proof from inside the same lock,
    /// rather than racing a second read against another window's next edit.
    public static func updateCaptured(root: URL, keys: [String], expectedCapture: ProjectSettingsCapture? = nil,
                                      change: (inout ProjectSettingsDocument) throws -> Void) throws -> ProjectSettingsCapture {
        try validateKeys(keys)
        return try locked(root: root, create: true) { directory in
            guard let directory, let primary = keys.first else { throw invalid }
            let before = try capture(keys: keys, directory: directory, root: root)
            if let expectedCapture {
                let sameDirectory = expectedCapture.directoryDevice == before.directoryDevice && expectedCapture.directoryInode == before.directoryInode
                let absentCreation = expectedCapture.directoryInode == nil && before.revisions.allSatisfy { $0.bytes == nil }
                guard expectedCapture.rootPath == before.rootPath, expectedCapture.revisions == before.revisions,
                      sameDirectory || absentCreation else { throw changed }
            }
            var document = before.document ?? .init(key: primary)
            document.key = primary; try change(&document); try document.validate()
            guard document.key.utf8.elementsEqual(primary.utf8) else { throw invalid }
            try verifyRoot(root, directory: directory)
            guard try capture(keys: keys, directory: directory, root: root).revisions == before.revisions else { throw changed }
            try write(document, directory: directory)
            if let fallback = before.selectedKey, !fallback.utf8.elementsEqual(primary.utf8),
               let revision = before.revisions.first(where: { $0.key.utf8.elementsEqual(fallback.utf8) }) {
                let remaining = try readFile(name: fileName(for: fallback), directory: directory)
                guard ProjectSettingsRevision(key: fallback, file: remaining) == revision else { throw changed }
                try verifyRoot(root, directory: directory)
                guard unlinkat(directory, fileName(for: fallback), 0) == 0, fsync(directory) == 0 else { throw invalid }
            }
            return try capture(keys: keys, directory: directory, root: root)
        }
    }

    private static func validateKeys(_ keys: [String]) throws {
        guard !keys.isEmpty, keys.count <= 16, Set(keys.map { Data($0.utf8) }).count == keys.count,
              keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 65_536 && !$0.contains("\0") }) else { throw invalid }
    }
    private static func capture(keys: [String], directory: Int32?, root: URL) throws -> ProjectSettingsCapture {
        var selected: (String, ProjectSettingsDocument)?, revisions: [ProjectSettingsRevision] = []
        for key in keys {
            let file = try directory.flatMap { try readFile(name: fileName(for: key), directory: $0) }
            revisions.append(.init(key: key, file: file))
            if let bytes = file?.bytes {
                let document = try decode(bytes)
                guard document.key.utf8.elementsEqual(key.utf8) else { throw invalid }
                if selected == nil { selected = (key, document) }
            }
        }
        var node = stat()
        if let directory, fstat(directory, &node) != 0 { throw invalid }
        return .init(keys: keys, selectedKey: selected?.0, document: selected?.1, revisions: revisions,
            rootPath: Data(root.path.utf8), directoryDevice: directory.map { _ in UInt64(truncatingIfNeeded: node.st_dev) },
            directoryInode: directory.map { _ in node.st_ino })
    }
    private static func decode(_ bytes: Data) throws -> ProjectSettingsDocument {
        do { return try JSONDecoder().decode(ProjectSettingsDocument.self, from: bytes) }
        catch let error as CoincideError { throw error }
        catch { throw invalid }
    }
    private static func readBytes(name: String, directory: Int32) throws -> Data? {
        try readFile(name: name, directory: directory)?.bytes
    }
    private static func readFile(name: String, directory: Int32) throws -> SavedProjectSettingsFile? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw invalid }; defer { Darwin.close(fd) }
        var before = stat()
        guard safeFile(fd), fstat(fd, &before) == 0, before.st_size > 0, before.st_size <= maximumBytes else { throw invalid }
        var data = Data(count: Int(before.st_size)), offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR { continue }; guard count > 0 else { throw invalid }; offset += count
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              same(before, after), same(after, named), before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw changed }
        return .init(bytes: data, device: UInt64(truncatingIfNeeded: before.st_dev), inode: before.st_ino)
    }
    private static func write(_ document: ProjectSettingsDocument, directory: Int32) throws {
        let name = fileName(for: document.key)
        if document.isEmpty {
            guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else { throw invalid }
            guard fsync(directory) == 0 else { throw invalid }; return
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw CoincideError("These project settings exceed the 256 KB limit.") }
        let temporary = ".settings-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw invalid }; defer { Darwin.close(fd); _ = unlinkat(directory, temporary, 0) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR { continue }; guard count > 0 else { throw invalid }; offset += count
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0, fsync(directory) == 0 else { throw invalid }
    }
    private static func locked<T>(root: URL, create: Bool, _ body: (Int32?) throws -> T) throws -> T {
        let directory = try openDirectory(root, create: create)
        guard let directory else { return try body(nil) }; defer { Darwin.close(directory) }
        let lock = openat(directory, ".project-settings.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw invalid }; defer { Darwin.close(lock) }
        guard safeFile(lock) else { throw invalid }
        let deadline = ContinuousClock.now + .seconds(2)
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else { throw invalid }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw CoincideError("Project settings are busy. Try again after the other edit finishes.") }
            usleep(2_000)
        }
        defer { _ = flock(lock, LOCK_UN) }
        var named = stat(), opened = stat()
        guard fstat(lock, &opened) == 0, fstatat(directory, ".project-settings.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              same(named, opened) else { throw invalid }
        try verifyRoot(root, directory: directory)
        let result = try body(directory)
        try verifyRoot(root, directory: directory)
        return result
    }
    private static func openDirectory(_ root: URL, create: Bool) throws -> Int32? {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0"), root.path != "/" else { throw invalid }
        let components = root.path.split(separator: "/").map(String.init)
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else { throw invalid }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw invalid }
        do {
            for component in components {
                var next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(directory, component, 0o700) == 0 || errno == EEXIST else { throw invalid }
                    next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if next < 0, errno == ENOENT, !create { Darwin.close(directory); return nil }
                guard next >= 0 else { throw invalid }
                Darwin.close(directory); directory = next
            }
            var info = stat()
            guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw invalid }
            return directory
        } catch { Darwin.close(directory); throw error }
    }
    private static func verifyRoot(_ root: URL, directory: Int32) throws {
        guard let current = try openDirectory(root, create: false) else { throw changed }; defer { Darwin.close(current) }
        var held = stat(), named = stat()
        guard fstat(directory, &held) == 0, fstat(current, &named) == 0, same(held, named) else { throw changed }
    }
    private static func safeFile(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
            && info.st_nlink == 1 && info.st_mode & 0o077 == 0
    }
    private static func same(_ lhs: stat, _ rhs: stat) -> Bool { lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino }
}
