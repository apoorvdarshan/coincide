import Darwin
import Foundation

public typealias AntigravityFileAccessGuard = @Sendable (_ workspace: URL, _ writing: Bool) async throws -> Void

/// The native server asks for file contents only after its own permission
/// decision. Containment and Coincide's workspace locks are checked separately.
public actor AntigravityClientFiles {
    public static let maximumBytes = 8 * 1_024 * 1_024
    private let folder: WorkspaceFileRoot
    private let root: URL
    private let accessGuard: AntigravityFileAccessGuard
    private struct Job: Sendable { let cancel: @Sendable () -> Void; let drain: Task<Void, Never> }
    private var jobs: [UUID: Job] = [:]
    private var closed = false
    private var closeTask: Task<Void, Never>?
    public init(root: URL, accessGuard: @escaping AntigravityFileAccessGuard) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); folder = try .init(root: self.root); self.accessGuard = accessGuard
    }
    private func relative(_ params: JSONValue) throws -> String {
        let path = try AntigravityProtocol.string(params["path"], maximum: 16_384)
        guard path.hasPrefix("/") else { throw AntigravityProtocol.failure() }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.hasPrefix(root.path + "/") else { throw AntigravityProtocol.failure() }
        return String(candidate.dropFirst(root.path.count + 1))
    }
    private func perform<T: Sendable>(writing: Bool, _ operation: @escaping @Sendable (WorkspaceFileRoot) throws -> T) async throws -> T {
        guard !closed else { throw AntigravityProtocol.failure() }
        try Task.checkCancellation(); try await accessGuard(root, writing)
        guard !closed else { throw AntigravityProtocol.failure() }
        let id = UUID(), folder = folder
        let task = Task.detached { try Task.checkCancellation(); try folder.validate(); return try operation(folder) }
        jobs[id] = .init(cancel: { task.cancel() }, drain: Task { _ = await task.result })
        defer { jobs.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let result = try await task.value; guard !closed else { throw AntigravityProtocol.failure() }; try Task.checkCancellation(); return result
        } onCancel: { task.cancel() }
    }
    public func read(params: JSONValue) async throws -> JSONValue {
        let path = try relative(params)
        func integer(_ value: JSONValue, minimum: Int) throws -> Int? {
            if value == .null { return nil }
            guard case .number(let raw) = value, let result = Int(exactly: raw), result >= minimum else { throw AntigravityProtocol.failure() }; return result
        }
        let line = try integer(params["line"], minimum: 1), limit = try integer(params["limit"], minimum: 0)
        return try await perform(writing: false) { folder in
            let document = try folder.read(path, allowMissing: false, maxBytes: Self.maximumBytes)
            guard !document.truncated else { throw AntigravityProtocol.failure() }
            if line == nil, limit == nil { return .object(["content": .string(document.contents)]) }
            let rows = document.contents.components(separatedBy: "\n"), start = min(rows.count, (line ?? 1) - 1)
            let count = min(limit ?? rows.count, rows.count - start)
            return .object(["content": .string(rows[start..<(start + count)].joined(separator: "\n"))])
        }
    }
    public func write(params: JSONValue) async throws -> JSONValue {
        let path = try relative(params), contents = try AntigravityProtocol.string(params["content"], maximum: Self.maximumBytes, empty: true)
        return try await perform(writing: true) { folder in
            let before = try folder.read(path, allowMissing: true, maxBytes: Self.maximumBytes)
            guard !before.truncated else { throw AntigravityProtocol.failure() }
            let expected: WorkspaceFileWriteCondition
            if before.exists { guard let revision = before.revision else { throw AntigravityProtocol.failure() }; expected = .matching(revision) }
            else { expected = .missing }
            _ = try folder.write(path, contents: contents, expected: expected, maxBytes: Self.maximumBytes, allowGitMetadata: true)
            return .object([:])
        }
    }
    public func close() async {
        if let closeTask { await closeTask.value; return }
        closed = true; let pending = Array(jobs.values), folder = folder
        for job in pending { job.cancel() }
        let task = Task { for job in pending { await job.drain.value }; folder.close() }
        closeTask = task; await task.value
    }

    /// Remove only the disposable native session whose UUIDv4 and metadata name
    /// its exact task-created cwd. Call after the native process has drained.
    static func cleanupDisposableSession(stateDirectory: URL, sessionID: String?, cwd: URL) {
        guard let sessionID, let uuid = UUID(uuidString: sessionID), (uuid.uuid.6 >> 4) == 4,
              sessionID == uuid.uuidString.lowercased() || sessionID == uuid.uuidString,
              let anchor = try? WorkspaceFileRoot(root: stateDirectory) else { return }
        defer { anchor.close() }
        let base = "antigravity-acp/conversations/" + sessionID
        guard let document = try? anchor.read(base + ".meta", allowMissing: false, maxBytes: 65_536), !document.truncated, document.revision?.path == base + ".meta",
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(document.contents.utf8)), value["cwd"] == .string(cwd.path) else { return }
        // Names are native UUIDs with no separators; all deletion is relative to
        // pinned directory descriptors, and symlinks/special files are refused.
        func openDirectory(_ parent: Int32, _ name: String) -> Int32 { openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        let native = openDirectory(anchor.fd, "antigravity-acp"); guard native >= 0 else { return }; defer { Darwin.close(native) }
        let conversations = openDirectory(native, "conversations"); guard conversations >= 0 else { return }; defer { Darwin.close(conversations) }
        guard (try? anchor.validate()) != nil else { return }
        for suffix in [".db", ".db-wal", ".db-shm", ".db-journal"] {
            var info = stat(); let name = sessionID + suffix
            if fstatat(conversations, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, unlinkat(conversations, name, 0) == 0 else { return }
            } else if errno != ENOENT { return }
        }
        let brain = openDirectory(native, "brain")
        if brain >= 0 {
            defer { Darwin.close(brain) }
            var remaining = 4_096
            guard removeOwnedTree(parent: brain, name: sessionID, depth: 0, remaining: &remaining) else { return }
        } else if errno != ENOENT { return }
        _ = unlinkat(conversations, sessionID + ".meta", 0)
    }
    private static func removeOwnedTree(parent: Int32, name: String, depth: Int, remaining: inout Int) -> Bool {
        guard depth < 32, remaining > 0 else { return false }; remaining -= 1
        var node = stat()
        if fstatat(parent, name, &node, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT }
        if node.st_mode & S_IFMT == S_IFREG { return unlinkat(parent, name, 0) == 0 }
        guard node.st_mode & S_IFMT == S_IFDIR else { return false }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }; defer { Darwin.close(fd) }
        var opened = stat(); guard fstat(fd, &opened) == 0, opened.st_ino == node.st_ino, opened.st_dev == node.st_dev else { return false }
        let copy = dup(fd); guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; return false }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let child = withUnsafePointer(to: entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) } }
            guard let child else { return false }; if child == "." || child == ".." { continue }
            guard removeOwnedTree(parent: fd, name: child, depth: depth + 1, remaining: &remaining) else { return false }
        }
        var final = stat()
        guard fstatat(parent, name, &final, AT_SYMLINK_NOFOLLOW) == 0, final.st_ino == opened.st_ino, final.st_dev == opened.st_dev else { return false }
        return unlinkat(parent, name, AT_REMOVEDIR) == 0
    }
}
