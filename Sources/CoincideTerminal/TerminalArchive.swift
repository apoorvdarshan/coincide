import CoincideCore
import Darwin
import Foundation

/// A cold terminal snapshot contains display text and identity, never a command
/// to replay or a process identifier to reconnect to.
public struct TerminalTabArchive: Codable, Equatable, Sendable {
    public let id: UUID
    public let threadID: UUID
    public let workspacePath: String
    public let directory: String
    public let title: String
    public let text: String
    public let isCommand: Bool
    public let exitCode: Int32?
    public init(id: UUID, threadID: UUID, workspacePath: String, directory: String,
                title: String, text: String, isCommand: Bool, exitCode: Int32?) {
        self.id = id; self.threadID = threadID; self.workspacePath = workspacePath
        self.directory = directory; self.title = String(Self.displayText(title).prefix(120))
        self.text = Self.displayText(text); self.isCommand = isCommand; self.exitCode = exitCode
    }
    public static let textByteLimit = 262_144
    public static func displayText(_ text: String) -> String {
        // Terminal output is restored as inert text. In particular, OSC/CSI,
        // clipboard writes, queries and device replies must never be replayed.
        var bytes = Array(text.utf8.suffix(textByteLimit))
        while let first = bytes.first, first & 0xc0 == 0x80 { bytes.removeFirst() }
        return String(String(decoding: bytes, as: UTF8.self).unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        })
    }
}

public struct TerminalWindowArchive: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public var tabs: [TerminalTabArchive]
    public var selection: [UUID: UUID]
    public var panelVisible: Bool
    public init(id: UUID = UUID(), tabs: [TerminalTabArchive] = [], selection: [UUID: UUID] = [:], panelVisible: Bool = false) {
        version = 1; self.id = id; self.tabs = tabs; self.selection = selection; self.panelVisible = panelVisible
    }
    public func validate() throws {
        guard version == 1, tabs.count <= 32, selection.count <= 32,
              Set(tabs.map(\.id)).count == tabs.count,
              tabs.allSatisfy({ $0.workspacePath.hasPrefix("/") && $0.directory.hasPrefix("/") &&
                  $0.workspacePath.utf8.count <= 16_384 && $0.directory.utf8.count <= 16_384 &&
                  !$0.workspacePath.contains("\0") && !$0.directory.contains("\0") &&
                  $0.title.count <= 120 && $0.text.utf8.count <= TerminalTabArchive.textByteLimit &&
                  $0.text == TerminalTabArchive.displayText($0.text) }),
              selection.allSatisfy({ key, value in tabs.contains { $0.threadID == key && $0.id == value } }) else {
            throw CoincideError("Saved terminals could not be read. The saved file was preserved.")
        }
    }
}

/// Serializes private per-window files and claims each saved window only once.
/// WorkspaceEngine supplies the exclusive app/database lifetime above this actor.
public actor TerminalArchiveStore {
    private let root: URL
    private var claimed: Set<UUID> = []
    private let byteLimit = 20 * 1_024 * 1_024
    public init(root: URL) { self.root = root }

    public func claim() throws -> TerminalWindowArchive {
        let fd = try directory(); defer { Darwin.close(fd) }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        guard files.count <= 128 else { throw CoincideError("Too many saved terminal windows. Existing files were preserved.") }
        let ordered = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a == b ? $0.lastPathComponent < $1.lastPathComponent : a > b
        }
        for file in ordered {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !claimed.contains(id) else { continue }
            let archive = try read(file.lastPathComponent, directory: fd)
            guard archive.id == id else { throw CoincideError("Saved terminal identity does not match its file.") }
            claimed.insert(id); return archive
        }
        let archive = TerminalWindowArchive(); claimed.insert(archive.id); return archive
    }

    public func save(_ archive: TerminalWindowArchive) throws {
        guard claimed.contains(archive.id) else { throw CoincideError("The terminal window is no longer owned by this app.") }
        try archive.validate()
        let data = try JSONEncoder().encode(archive)
        guard data.count <= byteLimit else { throw CoincideError("Saved terminal output exceeds its size limit.") }
        let fd = try directory(); defer { Darwin.close(fd) }
        let name = archive.id.uuidString.lowercased() + ".json"
        if archive.tabs.isEmpty {
            if unlinkat(fd, name, 0) != 0 && errno != ENOENT { throw failure() }
            _ = fsync(fd); return
        }
        let temporary = ".write-" + UUID().uuidString
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw failure() }
        defer { Darwin.close(file); _ = unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }; offset += count
            }
        }
        guard fsync(file) == 0, renameat(fd, temporary, fd, name) == 0, fsync(fd) == 0 else { throw failure() }
    }

    public func release(_ id: UUID) { claimed.remove(id) }

    private func directory() throws -> Int32 {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw failure() }
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw failure() }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == getuid(), value.st_mode & 0o077 == 0 else {
            Darwin.close(fd); throw failure()
        }
        return fd
    }
    private func read(_ name: String, directory: Int32) throws -> TerminalWindowArchive {
        let fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }; defer { Darwin.close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == getuid(), value.st_mode & 0o077 == 0,
              value.st_size > 0, value.st_size <= byteLimit else { throw failure() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count <= byteLimit {
            let count = Darwin.read(fd, &buffer, min(buffer.count, byteLimit + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure() }; if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= byteLimit else { throw failure() }
        let archive = try JSONDecoder().decode(TerminalWindowArchive.self, from: data)
        try archive.validate(); return archive
    }
    private func failure() -> CoincideError { .init("Terminal history could not be saved or read safely. Existing saved output was preserved.") }
}
