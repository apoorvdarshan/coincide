import Foundation

/// A symbolic link an instruction file goes through, as `CLAUDE.md → AGENTS.md`.
public struct InstructionLink: Hashable, Sendable {
    /// The link's own text, relative or absolute, as `ls -l` shows it.
    public var destination: String
    /// Whether the file the link chain ends at is missing.
    public var isBroken: Bool

    public nonisolated init(destination: String, isBroken: Bool) {
        self.destination = destination
        self.isBroken = isBroken
    }
}

/// Path helpers for instruction files: symbolic links are followed by hand, so a link is never mistaken for the file
/// it points to and is never replaced by one.
public enum InstructionPaths {
    /// Whether anything, a dangling link included, sits at `url`.
    public nonisolated static func itemExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    public nonisolated static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Whether `url` is a regular file, following links.
    public nonisolated static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    public nonisolated static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// `url` with every symbolic link resolved (`realpath`), also when its last components do not exist yet, so two
    /// spellings of one place compare equal.
    public nonisolated static func canonical(_ url: URL) -> URL {
        var base = url.standardizedFileURL
        var missing: [String] = []
        while true {
            if let resolved = realpath(base.path, nil) {
                defer { free(resolved) }
                let path = missing.reversed().reduce(String(cString: resolved)) { ($0 == "/" ? "" : $0) + "/" + $1 }
                return URL(fileURLWithPath: path)
            }
            guard base.path != "/", !base.path.isEmpty else { return url.standardizedFileURL }
            missing.append(base.lastPathComponent)
            base = base.deletingLastPathComponent()
        }
    }

    /// The file `url` stands for after following its links, and the first link when it is one. A dangling link
    /// resolves to the path it ends at, which is where saving would create the file.
    public nonisolated static func resolve(_ url: URL) -> (url: URL, link: InstructionLink?) {
        let manager = FileManager.default
        guard isSymbolicLink(url), let first = try? manager.destinationOfSymbolicLink(atPath: url.path) else {
            return (canonical(url), nil)
        }
        var current = url
        var hops = 0
        while hops < 40, isSymbolicLink(current), let destination = try? manager.destinationOfSymbolicLink(atPath: current.path) {
            let directory = canonical(current.deletingLastPathComponent())
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination) : directory.appendingPathComponent(destination)
            current = current.standardizedFileURL
            hops += 1
        }
        let resolved = canonical(current)
        let broken = hops >= 40 || !manager.fileExists(atPath: resolved.path)
        return (resolved, InstructionLink(destination: first, isBroken: broken))
    }

    /// `target` relative to `directory`, for a relative symbolic link placed in `directory`. The folders are resolved
    /// first, since the system resolves a relative link from the folder that physically holds it; `target` itself is
    /// kept, so a link to a link stays one.
    public nonisolated static func relativePath(to target: URL, from directory: URL) -> String {
        let from = canonical(directory).pathComponents
        let to = canonical(target.deletingLastPathComponent()).appendingPathComponent(target.lastPathComponent).pathComponents
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        let rest = Array(to[common...])
        return (ups + rest).joined(separator: "/")
    }

    /// The path with the home folder shown as `~`.
    public nonisolated static func abbreviated(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    /// A free name next to `url` for a backup of it: `CLAUDE.md.coincide-backup-20261029-161500`.
    public nonisolated static func backupURL(for url: URL, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.lastPathComponent + ".coincide-backup-" + formatter.string(from: date)
        let directory = url.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent(base)
        var counter = 2
        while itemExists(candidate) {
            candidate = directory.appendingPathComponent("\(base)-\(counter)")
            counter += 1
        }
        return candidate
    }
}
