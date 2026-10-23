import Foundation

public enum WorkspaceEntryKind: String, Codable, Sendable, Equatable { case file, directory }
public struct WorkspaceEntry: Codable, Identifiable, Sendable, Equatable {
    public let path: String
    public let kind: WorkspaceEntryKind
    public let ignored: Bool?
    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var isDirectory: Bool { kind == .directory }
    public init(path: String, kind: WorkspaceEntryKind, ignored: Bool? = nil) { self.path = path; self.kind = kind; self.ignored = ignored }
}
public struct WorkspaceEntryPage: Codable, Sendable, Equatable {
    public let entries: [WorkspaceEntry]
    public let truncated: Bool
    public init(entries: [WorkspaceEntry], truncated: Bool) { self.entries = entries; self.truncated = truncated }
}
/// Existing regular-file or directory metadata, without reading the file's contents.
public struct WorkspaceFileMetadata: Sendable, Equatable {
    public let relativePath: String
    public let resolvedURL: URL
    public let kind: WorkspaceEntryKind
    public let byteLength: Int
}
public struct WorkspaceIgnoredFile: Sendable, Equatable {
    public let path: String
    public let byteLength: Int
    public init(path: String, byteLength: Int) { self.path = path; self.byteLength = byteLength }
}
public struct WorkspaceIgnoredFilePage: Sendable, Equatable {
    public let files: [WorkspaceIgnoredFile]
    public let truncated: Bool
    public init(files: [WorkspaceIgnoredFile], truncated: Bool) { self.files = files; self.truncated = truncated }
}
/// A revision belongs to one regular file and its complete bytes. It cannot be manufactured by a caller.
public struct WorkspaceFileRevision: Sendable, Equatable {
    let rootDevice: UInt64, rootInode: UInt64, device: UInt64, inode: UInt64
    let path: String, digest: Data
}
public enum WorkspaceFileWriteCondition: Sendable, Equatable { case missing, matching(WorkspaceFileRevision) }
public struct WorkspaceTextDocument: Sendable, Equatable {
    public let relativePath: String
    public let contents: String
    public let byteLength: Int
    public let truncated: Bool
    public let exists: Bool
    public let revision: WorkspaceFileRevision?
    public init(relativePath: String, contents: String, byteLength: Int, truncated: Bool, exists: Bool, revision: WorkspaceFileRevision?) {
        self.relativePath = relativePath; self.contents = contents; self.byteLength = byteLength
        self.truncated = truncated; self.exists = exists; self.revision = revision
    }
}
public struct WorkspaceFileInvalidation: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable { case externalChange, mutation, refresh, rootUnavailable }
    public let generation: UInt64
    public let reason: Reason
    public init(generation: UInt64, reason: Reason) { self.generation = generation; self.reason = reason }
}
public struct WorkspaceFileError: Error, LocalizedError, Sendable, Equatable {
    public enum Failure: String, Sendable, Equatable {
        case rootMissing, rootNotDirectory, rootReplaced, invalidPath, pathOutsideRoot, gitMetadata, notFile
        case missing, binary, invalidUTF8, conflict, permissionDenied, operationFailed, timedOut, closed, invalidQuery
    }
    public let failure: Failure
    public let message: String
    public var errorDescription: String? { message }
    public init(_ failure: Failure, _ message: String) { self.failure = failure; self.message = message }
}

/// Local filesystem operations only. The caller owns registration/readiness and editor-lock policy.
/// Directory/path search ranking is native and does not reproduce fff's learned ranking.
public actor WorkspaceFileService {
    public nonisolated let root: URL
    private let anchor: Task<WorkspaceFileRoot, any Error>
    private let git: WorkspaceFileGit
    private let contentSearchLimits: WorkspaceContentSearchLimits
    private struct Job: Sendable { let cancel: @Sendable () -> Void; let drain: Task<Void, Never> }
    private var jobs: [UUID: Job] = [:]
    private var closed = false
    private var closeTask: Task<Void, Never>?
    private var watcher: WorkspaceNativeFileWatcher?
    private var watcherTask: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<WorkspaceFileInvalidation>.Continuation] = [:]
    private var generation: UInt64 = 0

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        let folder = self.root
        anchor = Task.detached { try WorkspaceFileRoot(root: folder) }
        git = .init(environment: nil, executable: nil)
        contentSearchLimits = .init()
    }
    init(root: URL, environment: [String: String], gitExecutable: URL? = nil,
         contentSearchLimits: WorkspaceContentSearchLimits = .init()) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        let folder = self.root
        anchor = Task.detached { try WorkspaceFileRoot(root: folder) }
        git = .init(environment: environment, executable: gitExecutable)
        self.contentSearchLimits = contentSearchLimits
    }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable (WorkspaceFileRoot, WorkspaceFileGit) async throws -> T) async throws -> T {
        guard !closed else { throw WorkspaceFileError(.closed, "This workspace file session is closed.") }
        try Task.checkCancellation()
        let id = UUID(), anchor = anchor, git = git
        let task = Task.detached {
            let folder = try await anchor.value
            try Task.checkCancellation(); try folder.validate()
            let result = try await operation(folder, git)
            try folder.validate(); return result
        }
        let drain = Task { _ = try? await task.value }
        jobs[id] = .init(cancel: { task.cancel() }, drain: drain)
        defer { jobs.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                guard !closed else { throw CancellationError() }
                try Task.checkCancellation(); return result
            } catch { try Task.checkCancellation(); throw error }
        } onCancel: { task.cancel() }
    }
    public func listEntries(directoryPath: String = "") async throws -> WorkspaceEntryPage {
        try await perform { folder, git in
            let page = try folder.list(directoryPath)
            let ignored = try await git.ignored(page.entries.map(\.path), root: folder, includeTracked: false)
            return .init(entries: page.entries.map { .init(path: $0.path, kind: $0.kind, ignored: ignored.contains($0.path) ? true : nil) }, truncated: page.truncated)
        }
    }
    public func searchEntries(query: String, limit: Int = 100, kind: WorkspaceEntryKind? = nil, imageOnly: Bool = false) async throws -> WorkspaceEntryPage {
        guard query.utf16.count <= 256, (1...200).contains(limit), !query.contains("\0") else {
            throw WorkspaceFileError(.invalidQuery, "Use a search of at most 256 characters and a result limit from 1 to 200.")
        }
        return try await perform { folder, git in
            var query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while let first = query.first, "@./".contains(first) { query.removeFirst() }
            let deadline = ContinuousClock.now + .seconds(15)
            let page = try await WorkspaceFileWalker.entries(root: folder, git: git, deadline: deadline)
            var truncated = page.truncated, matches: [(Int, WorkspaceEntry)] = []
            for entry in page.entries {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { truncated = true; break }
                if imageOnly ? (entry.kind != .file || !Self.isImage(entry.path)) : (kind != nil && entry.kind != kind) { continue }
                guard let score = Self.score(entry.path, query: query) else { continue }
                matches.append((score, entry))
                matches.sort { $0.0 == $1.0 ? $0.1.path < $1.1.path : $0.0 < $1.0 }
                if matches.count > limit { truncated = true; matches.removeLast() }
            }
            return .init(entries: matches.map(\.1), truncated: truncated)
        }
    }
    public func searchContents(query: String, limit: Int = 500, caseSensitive: Bool = false,
                               wholeWord: Bool = false, useRegex: Bool = false) async throws -> WorkspaceContentSearchResult {
        guard !query.isEmpty, query.utf16.count <= 256, !query.contains("\0"), (1...500).contains(limit) else {
            throw WorkspaceFileError(.invalidQuery, "Use a nonempty search of at most 256 characters and a result limit from 1 to 500.")
        }
        let limits = contentSearchLimits
        return try await perform { folder, git in
            try await WorkspaceContentSearch.search(root: folder, git: git, query: query, limit: limit,
                caseSensitive: caseSensitive, wholeWord: wholeWord, useRegex: useRegex, limits: limits)
        }
    }
    public func listIgnoredFiles() async throws -> WorkspaceIgnoredFilePage {
        try await perform { folder, git in try await git.inventory(root: folder) }
    }
    public func metadata(relativePath: String = "") async throws -> WorkspaceFileMetadata {
        try await perform { folder, _ in try folder.metadata(relativePath) }
    }
    public func readFile(relativePath: String, allowMissing: Bool = false, maxBytes: Int = 1_048_576) async throws -> WorkspaceTextDocument {
        guard (1...2_000_000).contains(maxBytes) else { throw WorkspaceFileError(.invalidQuery, "File previews must be between 1 byte and 2 MB.") }
        return try await perform { folder, _ in try folder.read(relativePath, allowMissing: allowMissing, maxBytes: maxBytes) }
    }
    public func writeFile(relativePath: String, contents: String, expected: WorkspaceFileWriteCondition) async throws -> WorkspaceTextDocument {
        let result = try await perform { folder, _ in try folder.write(relativePath, contents: contents, expected: expected) }
        invalidate(.mutation); return result
    }
    /// Complete bounded bytes from the same descriptor anchor used by text reads.
    public func readBinary(relativePath: String, maxBytes: Int = 1_048_576) async throws -> Data {
        guard (1...2_000_000).contains(maxBytes) else { throw WorkspaceFileError(.invalidQuery, "Binary previews must be between 1 byte and 2 MB.") }
        return try await perform { folder, _ in try folder.readBinary(relativePath, maxBytes: maxBytes) }
    }
    public func invalidations() async -> AsyncStream<WorkspaceFileInvalidation> {
        let pair = AsyncStream<WorkspaceFileInvalidation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !closed else { pair.continuation.finish(); return pair.stream }
        let id = UUID(); listeners[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        if watcherTask == nil {
            watcherTask = Task { [weak self] in
                guard let self else { return }; await self.installWatcher()
            }
        }
        await watcherTask?.value
        return pair.stream
    }
    private func installWatcher() async {
        do {
            let folder = try await anchor.value; try folder.validate()
            guard !closed, !Task.isCancelled else { return }
            watcher = try .init(path: root.path) { [weak self] unavailable in
                Task { await self?.watchChanged(unavailable: unavailable) }
            }
        } catch { if !closed { invalidate(.rootUnavailable) } }
    }
    private func watchChanged(unavailable: Bool) {
        guard !closed else { return }
        invalidate(unavailable ? .rootUnavailable : .externalChange)
    }
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
    private func invalidate(_ reason: WorkspaceFileInvalidation.Reason) {
        guard !closed else { return }
        generation &+= 1
        for listener in listeners.values { listener.yield(.init(generation: generation, reason: reason)) }
    }
    public func refresh() async { invalidate(.refresh) }
    public func close() async {
        if let closeTask { await closeTask.value; return }
        closed = true; watcherTask?.cancel()
        for listener in listeners.values { listener.finish() }; listeners = [:]
        let jobs = Array(jobs.values), watcherTask = watcherTask, anchor = anchor
        for job in jobs { job.cancel() }
        let task = Task {
            await watcherTask?.value
            if let watcher = self.watcher { await watcher.close(); self.watcher = nil }
            for job in jobs { await job.drain.value }
            if let folder = try? await anchor.value { folder.close() }
        }
        closeTask = task; await task.value
    }
    private static func isImage(_ path: String) -> Bool {
        ["avif", "gif", "ico", "icns", "jpeg", "jpg", "png", "svg", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
    private static func score(_ path: String, query: String) -> Int? {
        if query.isEmpty { return 0 }
        let value = path.lowercased(), name = URL(fileURLWithPath: value).lastPathComponent
        if name == query { return 0 }; if name.hasPrefix(query) { return 100 + name.count - query.count }
        if value.contains(query) { return 300 + value.count - query.count }
        var remaining = query[...], gaps = 0
        for character in value {
            if character == remaining.first { remaining.removeFirst(); if remaining.isEmpty { return 600 + gaps } }
            else { gaps += 1 }
        }
        return nil
    }
}
