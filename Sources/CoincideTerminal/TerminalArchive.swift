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
    /// Text plus SGR attributes only (see `TerminalStyledText`); absent in older files.
    public var styledText: String?
    /// The drawer's "Terminal N" number.
    public let ordinal: Int?
    /// Closed at an idle prompt on Settle; restoration does not start a shell automatically.
    public let closedWhileIdle: Bool?
    public init(id: UUID, threadID: UUID, workspacePath: String, directory: String,
                title: String, text: String, isCommand: Bool, exitCode: Int32?,
                styledText: String? = nil, ordinal: Int? = nil, closedWhileIdle: Bool? = nil) {
        self.id = id; self.threadID = threadID; self.workspacePath = workspacePath
        self.directory = directory; self.title = String(Self.displayText(title).prefix(120))
        self.text = Self.displayText(text); self.isCommand = isCommand; self.exitCode = exitCode
        self.styledText = styledText.map { TerminalStyledText.sanitized(TerminalStyledText.bounded($0)) }
        self.ordinal = ordinal.flatMap { (1...999).contains($0) ? $0 : nil }
        self.closedWhileIdle = closedWhileIdle == true ? true : nil
    }
    public static let textByteLimit = 262_144
    public static func displayText(_ text: String) -> String {
        // Terminal output is restored as inert text. In particular, OSC/CSI,
        // clipboard writes, queries and device replies must never be replayed.
        var bytes = Array(text.utf8.suffix(textByteLimit))
        while let first = bytes.first, first & 0xc0 == 0x80 { bytes.removeFirst() }
        // Printable ASCII with newlines and tabs needs no scalar filtering.
        if bytes.allSatisfy({ ($0 >= 0x20 && $0 < 0x7f) || $0 == 0x0a || $0 == 0x09 }) { return String(decoding: bytes, as: UTF8.self) }
        return String(String(decoding: bytes, as: UTF8.self).unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        })
    }
    var isValid: Bool {
        workspacePath.hasPrefix("/") && directory.hasPrefix("/") &&
            workspacePath.utf8.count <= 16_384 && directory.utf8.count <= 16_384 &&
            !workspacePath.contains("\0") && !directory.contains("\0") &&
            title.count <= 120 && text.utf8.count <= Self.textByteLimit && text == Self.displayText(text) &&
            styledText.map { $0.utf8.count <= TerminalStyledText.byteLimit && $0 == TerminalStyledText.sanitized($0) } ?? true &&
            ordinal.map { (1...999).contains($0) } ?? true && closedWhileIdle != false
    }
    /// Approximate encoded size; JSON escapes each control character as six bytes.
    var storageEstimate: Int {
        let styled = styledText.map { $0.utf8.count + $0.unicodeScalars.reduce(0) { $1 == "\u{1b}" ? $0 + 5 : $0 } } ?? 0
        return 512 + workspacePath.utf8.count + directory.utf8.count + text.utf8.count * 2 + styled
    }
}

/// Persisted split group membership for one conversation's tabs.
public struct TerminalGroupArchive: Codable, Equatable, Sendable {
    public let id: UUID
    public let threadID: UUID
    public let sessionIDs: [UUID]
    public let axis: TerminalGroup.Axis
    public init(id: UUID, threadID: UUID, sessionIDs: [UUID], axis: TerminalGroup.Axis) {
        self.id = id; self.threadID = threadID; self.sessionIDs = sessionIDs; self.axis = axis
    }
}

public struct TerminalWindowArchive: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public var tabs: [TerminalTabArchive]
    public var selection: [UUID: UUID]
    /// Legacy window-wide visibility; newer files also record `visibleThreadIDs`.
    public var panelVisible: Bool
    public var visibleThreadIDs: [UUID]?
    public var panelHeights: [UUID: Double]?
    public var groups: [TerminalGroupArchive]?
    public init(id: UUID = UUID(), tabs: [TerminalTabArchive] = [], selection: [UUID: UUID] = [:], panelVisible: Bool = false,
                visibleThreadIDs: [UUID]? = nil, panelHeights: [UUID: Double]? = nil, groups: [TerminalGroupArchive]? = nil) {
        version = 1; self.id = id; self.tabs = tabs; self.selection = selection; self.panelVisible = panelVisible
        self.visibleThreadIDs = visibleThreadIDs; self.panelHeights = panelHeights; self.groups = groups
    }
    public static let panelHeightRange = 120.0...2_000.0
    public static let storageBudget = 16 * 1_024 * 1_024
    public func validate() throws {
        let tabsByID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = (groups ?? []).flatMap(\.sessionIDs)
        guard version == 1, tabs.count <= 32, selection.count <= 32,
              tabsByID.count == tabs.count, tabs.allSatisfy(\.isValid),
              selection.allSatisfy({ key, value in tabs.contains { $0.threadID == key && $0.id == value } }),
              (visibleThreadIDs?.count ?? 0) <= 256, Set(visibleThreadIDs ?? []).count == (visibleThreadIDs?.count ?? 0),
              (panelHeights?.count ?? 0) <= 256,
              (panelHeights ?? [:]).values.allSatisfy({ $0.isFinite && Self.panelHeightRange.contains($0) }),
              (groups?.count ?? 0) <= 32, Set(grouped).count == grouped.count, Set((groups ?? []).map(\.id)).count == (groups?.count ?? 0),
              (groups ?? []).allSatisfy({ group in
                  (1...TerminalThreadLayout.maximumPanesPerGroup).contains(group.sessionIDs.count) &&
                      group.sessionIDs.allSatisfy { tabsByID[$0]?.threadID == group.threadID }
              }) else {
            throw CoincideError("Saved terminals could not be read. The saved file was preserved.")
        }
    }
    /// Drops styled history from the largest tabs until the file fits its budget;
    /// their plain-text output is kept.
    public func boundedForStorage(budget: Int = storageBudget) -> TerminalWindowArchive {
        var archive = self
        var total = archive.tabs.reduce(1_024) { $0 + $1.storageEstimate }
        while total > budget, let index = archive.tabs.indices.filter({ archive.tabs[$0].styledText != nil })
            .max(by: { archive.tabs[$0].storageEstimate < archive.tabs[$1].storageEstimate }) {
            total -= archive.tabs[index].storageEstimate
            archive.tabs[index].styledText = nil
            total += archive.tabs[index].storageEstimate
        }
        return archive
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
        let archive = archive.boundedForStorage()
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
