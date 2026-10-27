import CoincideKit
import Foundation

/// A file or folder in a working directory, relative to it.
nonisolated struct ComposerFileEntry: Hashable, Sendable {
    var path: String
    var isDirectory: Bool

    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }
}

/// Lists a working directory's files for @-mentions and ranks them against what the user typed.
/// Uses `git ls-files` (tracked and untracked, honoring .gitignore) and falls back to a directory walk.
final class ComposerFileIndex {
    static let shared = ComposerFileIndex()

    private nonisolated struct IndexedEntry: Sendable {
        var entry: ComposerFileEntry
        var lowercasedPath: String
        var lowercasedName: String
        var depth: Int
    }

    private struct Snapshot {
        var entries: [IndexedEntry]
        var loadedAt: Date
    }

    private nonisolated static let maxEntries = 25_000
    private nonisolated static let skippedFolders: Set<String> = [
        "node_modules", "build", "DerivedData", "Pods", "dist", "target", "__pycache__", "venv",
    ]
    private let maxAge: TimeInterval = 30
    private var snapshots: [String: Snapshot] = [:]
    private var loads: [String: Task<[IndexedEntry], Never>] = [:]

    /// Entries matching `query`, best first. A stale listing is served while a fresh one loads.
    func search(_ query: String, in root: URL, limit: Int = 80) async -> [ComposerFileEntry] {
        let entries = await entries(for: root)
        return await Self.rank(entries, query: query, limit: limit)
    }

    private func entries(for root: URL) async -> [IndexedEntry] {
        let key = root.standardizedFileURL.path
        if let snapshot = snapshots[key] {
            if Date().timeIntervalSince(snapshot.loadedAt) > maxAge { load(key: key, root: root) }
            return snapshot.entries
        }
        return await load(key: key, root: root).value
    }

    @discardableResult
    private func load(key: String, root: URL) -> Task<[IndexedEntry], Never> {
        if let running = loads[key] { return running }
        let task = Task {
            let entries = await Self.list(root)
            snapshots[key] = Snapshot(entries: entries, loadedAt: Date())
            loads[key] = nil
            return entries
        }
        loads[key] = task
        return task
    }

    // MARK: Listing

    @concurrent
    private nonisolated static func list(_ root: URL) async -> [IndexedEntry] {
        let files: [String]
        if let tracked = await gitFiles(root) {
            files = tracked
        } else {
            files = walk(root)
        }
        var folders = Set<String>()
        for file in files {
            var parent = (file as NSString).deletingLastPathComponent
            while !parent.isEmpty, folders.insert(parent).inserted {
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let entries =
            folders.map { ComposerFileEntry(path: $0, isDirectory: true) }
            + files.map { ComposerFileEntry(path: $0, isDirectory: false) }
        return entries.map { entry in
            IndexedEntry(
                entry: entry, lowercasedPath: entry.path.lowercased(), lowercasedName: entry.name.lowercased(),
                depth: entry.path.utf8.reduce(0) { $1 == 0x2F ? $0 + 1 : $0 })
        }
    }

    private nonisolated static func gitFiles(_ root: URL) async -> [String]? {
        guard let git = await GitService.gitExecutable() else { return nil }
        let result = await ProcessRunner.run(
            git, ["-C", root.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"], timeout: 10)
        guard result.succeeded else { return nil }
        // Unmerged files are listed once per stage.
        var seen = Set<String>()
        var files: [String] = []
        for line in result.stdout.split(separator: "\0") where files.count < maxEntries {
            let path = String(line)
            if seen.insert(path).inserted { files.append(path) }
        }
        return files
    }

    /// `/usr/bin/git` is a shim that offers to install the developer tools when they are missing; skip it then.
    private nonisolated static func walk(_ root: URL) -> [String] {
        let prefix = root.standardizedFileURL.path + "/"
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var files: [String] = []
        while let url = enumerator.nextObject() as? URL, files.count < maxEntries {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(prefix) { files.append(String(path.dropFirst(prefix.count))) }
        }
        return files
    }

    // MARK: Ranking

    @concurrent
    private nonisolated static func rank(_ entries: [IndexedEntry], query: String, limit: Int) async -> [ComposerFileEntry] {
        let query = query.lowercased()
        let queryBytes = Array(query.utf8)
        var matches: [(score: Int, entry: IndexedEntry)] = []
        if query.isEmpty {
            matches = entries.filter { $0.depth == 0 }.map { ($0.entry.isDirectory ? 0 : 1, $0) }
        } else {
            for entry in entries {
                if let score = score(entry, query: query, bytes: queryBytes) { matches.append((score, entry)) }
            }
        }
        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.entry.depth != rhs.entry.depth { return lhs.entry.depth < rhs.entry.depth }
            if lhs.entry.lowercasedPath.count != rhs.entry.lowercasedPath.count {
                return lhs.entry.lowercasedPath.count < rhs.entry.lowercasedPath.count
            }
            return lhs.entry.lowercasedPath < rhs.entry.lowercasedPath
        }
        return matches.prefix(limit).map(\.entry.entry)
    }

    /// Lower is better: name matches beat path matches, which beat scattered (fuzzy) matches;
    /// among fuzzy matches, fewer and closer runs of the query win.
    private nonisolated static func score(_ entry: IndexedEntry, query: String, bytes: [UInt8]) -> Int? {
        if entry.lowercasedName == query { return 0 }
        if entry.lowercasedName.hasPrefix(query) { return 1 }
        if entry.lowercasedPath.hasPrefix(query) { return 2 }
        if entry.lowercasedName.contains(query) { return 3 }
        if entry.lowercasedPath.contains(query) { return 4 }
        if let cost = subsequenceCost(bytes, in: entry.lowercasedName) { return 1_000 + cost }
        return subsequenceCost(bytes, in: entry.lowercasedPath).map { 100_000 + $0 }
    }

    /// How scattered the query's bytes are within `text` (runs first, then span), or nil when they
    /// do not all appear in order.
    private nonisolated static func subsequenceCost(_ query: [UInt8], in text: String) -> Int? {
        var text = text
        return text.withUTF8 { haystack in
            var position = 0
            var runs = 0
            var previous = -2
            var first = -1
            for byte in query {
                while position < haystack.count, haystack[position] != byte { position += 1 }
                guard position < haystack.count else { return nil }
                if position != previous + 1 { runs += 1 }
                if first < 0 { first = position }
                previous = position
                position += 1
            }
            return runs * 100 + min(previous - first, 99)
        }
    }
}
