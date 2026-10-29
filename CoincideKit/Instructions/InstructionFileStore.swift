import Foundation

/// Why reading, saving or linking an instruction file failed. Each case is a sentence for the user.
public enum InstructionFileError: LocalizedError, Equatable, Sendable {
    /// Someone else changed the file since it was opened.
    case changedOnDisk(String)
    case notText(String)
    /// The folder the file (or the end of its link) would go in does not exist.
    case folderMissing(String)
    case alreadyExists(String)
    case missing(String)
    case failed(String, String)

    public nonisolated var errorDescription: String? {
        switch self {
        case .changedOnDisk(let name): String(localized: "\(name) changed on disk since you opened it.")
        case .notText(let name): String(localized: "\(name) isn't UTF-8 text, so Coincide can't edit it.")
        case .folderMissing(let path): String(localized: "The folder \(path) doesn't exist.")
        case .alreadyExists(let name): String(localized: "\(name) already exists.")
        case .missing(let name): String(localized: "\(name) doesn't exist.")
        case .failed(let name, let reason): String(localized: "Couldn't write \(name): \(reason)")
        }
    }
}

/// What a file looked like when it was read: its text and enough of its metadata to notice a change.
public struct InstructionSnapshot: Equatable, Sendable {
    public var text: String
    /// Nil when the file did not exist.
    public var fingerprint: Fingerprint?

    public struct Fingerprint: Equatable, Sendable {
        public var modified: Date
        public var size: Int
        public var inode: UInt64
    }

    public nonisolated init(text: String, fingerprint: Fingerprint?) {
        self.text = text
        self.fingerprint = fingerprint
    }
}

/// Reads and writes instruction files. A path that is a symbolic link is read and written through: the file it
/// resolves to is replaced atomically and the link itself is never touched, so `CLAUDE.md → AGENTS.md` stays a link.
public enum InstructionFileStore {
    public nonisolated static func fingerprint(_ url: URL) -> InstructionSnapshot.Fingerprint? {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        return .init(modified: modified, size: Int(info.st_size), inode: UInt64(info.st_ino))
    }

    /// The file's text; an empty snapshot without a fingerprint when it doesn't exist.
    public nonisolated static func read(_ url: URL) throws -> InstructionSnapshot {
        let resolved = InstructionPaths.resolve(url).url
        guard let fingerprint = fingerprint(resolved) else { return InstructionSnapshot(text: "", fingerprint: nil) }
        let data: Data
        do {
            data = try Data(contentsOf: resolved)
        } catch {
            throw InstructionFileError.failed(url.lastPathComponent, error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw InstructionFileError.notText(url.lastPathComponent) }
        return InstructionSnapshot(text: text, fingerprint: fingerprint)
    }

    /// Whether the file is no longer what `snapshot` saw: changed, created or deleted. A file rewritten with the same
    /// text, as some editors do on save, doesn't count.
    public nonisolated static func hasChanged(_ url: URL, since snapshot: InstructionSnapshot) -> Bool {
        let resolved = InstructionPaths.resolve(url).url
        let current = fingerprint(resolved)
        guard current != snapshot.fingerprint else { return false }
        guard current != nil, snapshot.fingerprint != nil else { return true }
        return (try? read(url))?.text != snapshot.text
    }

    /// Saves `text` to the file `url` stands for. With `expecting`, refuses when the file changed since that
    /// snapshot. The text goes to a temporary file beside the resolved file first and then replaces it, keeping its
    /// permissions, so a reader never sees half a file and links to it keep working.
    @discardableResult
    public nonisolated static func write(
        _ text: String, to url: URL, expecting snapshot: InstructionSnapshot? = nil
    ) throws -> InstructionSnapshot {
        if let snapshot, hasChanged(url, since: snapshot) { throw InstructionFileError.changedOnDisk(url.lastPathComponent) }
        let target = InstructionPaths.resolve(url).url
        let folder = target.deletingLastPathComponent()
        guard InstructionPaths.isDirectory(folder) else {
            throw InstructionFileError.folderMissing(InstructionPaths.abbreviated(folder))
        }
        try writeAtomically(Data(text.utf8), to: target, name: url.lastPathComponent)
        return InstructionSnapshot(text: text, fingerprint: fingerprint(target))
    }

    /// Replaces the regular file at `target` (never a link) with `data` through a temporary file in its folder.
    nonisolated static func writeAtomically(_ data: Data, to target: URL, name: String) throws {
        var info = stat()
        let permissions: mode_t = stat(target.path, &info) == 0 ? info.st_mode & 0o7777 : 0o644
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).coincide-\(UUID().uuidString.prefix(8)).tmp")
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            chmod(temporary.path, permissions)
            guard rename(temporary.path, target.path) == 0 else {
                throw InstructionFileError.failed(name, String(cString: strerror(errno)))
            }
        } catch let error as InstructionFileError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw InstructionFileError.failed(name, error.localizedDescription)
        }
    }
}

/// One-step helpers for a project's instruction files.
public enum InstructionHelpers {
    /// What a new `AGENTS.md` starts with.
    public nonisolated static let agentsTemplate = """
        <!-- Instructions for coding agents: Codex, Cursor, Grok Build, OpenCode and Antigravity read this file. \
        Link CLAUDE.md to it so Claude Code reads it too. -->

        """

    /// Creates `AGENTS.md` in `folder` from the template. Refuses when anything, a dangling link included, is there.
    @discardableResult
    public nonisolated static func createAgentsFile(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("AGENTS.md")
        guard !InstructionPaths.itemExists(url) else { throw InstructionFileError.alreadyExists("AGENTS.md") }
        guard InstructionPaths.isDirectory(folder) else {
            throw InstructionFileError.folderMissing(InstructionPaths.abbreviated(folder))
        }
        try InstructionFileStore.writeAtomically(Data(agentsTemplate.utf8), to: url, name: "AGENTS.md")
        return url
    }

    /// Makes `name` (`CLAUDE.md`, `GEMINI.md`) in `folder` a relative link to `target` (`AGENTS.md`) in the same folder.
    /// Only when nothing is at `name` yet and `target` exists; it never replaces a file or a link.
    @discardableResult
    public nonisolated static func link(_ name: String, to target: String = "AGENTS.md", in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        guard !InstructionPaths.itemExists(url) else { throw InstructionFileError.alreadyExists(name) }
        guard InstructionPaths.isRegularFile(folder.appendingPathComponent(target)) else { throw InstructionFileError.missing(target) }
        do {
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        } catch {
            throw InstructionFileError.failed(name, error.localizedDescription)
        }
        return url
    }
}

/// A line-by-line comparison of two texts, for previews.
public enum InstructionDiff {
    public enum Line: Hashable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// `new` against `old`: lines only `old` has are removed, lines only `new` has are added.
    public nonisolated static func lines(from old: String, to new: String) -> [Line] {
        let before = old.components(separatedBy: "\n")
        let after = new.components(separatedBy: "\n")
        let difference = after.difference(from: before)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < before.count || newIndex < after.count {
            if oldIndex < before.count, removed.contains(oldIndex) {
                result.append(.removed(before[oldIndex]))
                oldIndex += 1
            } else if newIndex < after.count, inserted.contains(newIndex) {
                result.append(.added(after[newIndex]))
                newIndex += 1
            } else {
                if newIndex < after.count { result.append(.same(after[newIndex])) }
                oldIndex += 1
                newIndex += 1
            }
        }
        return result
    }
}
