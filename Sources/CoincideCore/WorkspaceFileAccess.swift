import CryptoKit
import Darwin
import Foundation

private func fileFailure(_ code: Int32 = errno) -> WorkspaceFileError {
    switch code {
    case ENOENT: .init(.missing, "This workspace path no longer exists.")
    case EACCES, EPERM: .init(.permissionDenied, "This workspace path is not accessible.")
    case ELOOP: .init(.invalidPath, "This workspace path contains an unresolved symbolic link.")
    default: .init(.operationFailed, "The workspace file operation failed.")
    }
}
private func elevatedFileFD(_ fd: Int32) throws -> Int32 {
    guard fd >= 0 else { throw fileFailure() }
    if fd > STDERR_FILENO { return fd }
    let copy = fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1), code = errno
    Darwin.close(fd)
    guard copy >= 0 else { throw fileFailure(code) }; return copy
}
private func sameFile(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
private func regular(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFREG }
private func directory(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFDIR }

final class WorkspaceFileDirectory: @unchecked Sendable {
    let fd: Int32, relative: String
    init(fd: Int32, relative: String) { self.fd = fd; self.relative = relative }
    deinit { Darwin.close(fd) }
}

/// Every traversal starts from an owned descriptor. Symlink targets are interpreted back inside
/// this anchor, rather than handed to an unanchored filesystem operation.
final class WorkspaceFileRoot: @unchecked Sendable {
    let path: String, fd: Int32, device: UInt64, inode: UInt64
    private let lifetime = NSLock()
    private var released = false
    private static let writes = NSLock()
    init(root: URL) throws {
        guard root.isFileURL, root.path != "/" else { throw WorkspaceFileError(.invalidPath, "Choose a local workspace folder below the filesystem root.") }
        path = root.path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { throw WorkspaceFileError(.rootMissing, "The workspace folder no longer exists.") }; throw fileFailure()
        }
        guard directory(info) else { throw WorkspaceFileError(.rootNotDirectory, "The workspace root must be a directory.") }
        fd = try elevatedFileFD(Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        var opened = stat()
        guard fstat(fd, &opened) == 0, sameFile(info, opened) else { Darwin.close(fd); throw WorkspaceFileError(.rootReplaced, "The workspace folder changed while it was opened.") }
        device = UInt64(truncatingIfNeeded: opened.st_dev); inode = opened.st_ino
    }
    deinit { close() }
    func close() { lifetime.lock(); defer { lifetime.unlock() }; if !released { released = true; Darwin.close(fd) } }
    func validate() throws {
        lifetime.lock(); defer { lifetime.unlock() }
        guard !released else { throw WorkspaceFileError(.closed, "This workspace file session is closed.") }
        var named = stat(), opened = stat()
        guard lstat(path, &named) == 0, fstat(fd, &opened) == 0, directory(named), sameFile(named, opened),
              UInt64(truncatingIfNeeded: opened.st_dev) == device, opened.st_ino == inode else {
            throw WorkspaceFileError(.rootReplaced, "The workspace folder was moved or replaced. Reopen it before using its files.")
        }
    }
    private func components(_ relative: String, allowRoot: Bool = false) throws -> [String] {
        guard !relative.hasPrefix("/"), !relative.contains("\0"), relative.utf16.count <= 4_096 else {
            throw WorkspaceFileError(.invalidPath, "Use a path relative to this workspace.")
        }
        let pieces = relative.split(separator: "/").map(String.init)
        guard !pieces.contains("..") else { throw WorkspaceFileError(.pathOutsideRoot, "This path is outside the workspace.") }
        let result = pieces.filter { $0 != "." }
        guard allowRoot || !result.isEmpty else { throw WorkspaceFileError(.invalidPath, "Choose a file inside the workspace.") }
        return result
    }
    private func normalizeLink(_ target: String, parent: [String]) throws -> [String] {
        var pieces: [String]
        if target.hasPrefix("/") {
            guard target == path || target.hasPrefix(path + "/") else { throw WorkspaceFileError(.pathOutsideRoot, "This symbolic link points outside the workspace.") }
            pieces = []; pieces = try appendLink(String(target.dropFirst(path.count)), to: pieces)
        } else { pieces = try appendLink(target, to: parent) }
        return pieces
    }
    private func appendLink(_ value: String, to original: [String]) throws -> [String] {
        var pieces = original
        for item in value.split(separator: "/") {
            if item == "." { continue }
            if item == ".." {
                guard !pieces.isEmpty else { throw WorkspaceFileError(.pathOutsideRoot, "This symbolic link points outside the workspace.") }; pieces.removeLast()
            } else { pieces.append(String(item)) }
        }
        return pieces
    }
    private func parent(_ relative: String, create: Bool = false, denyMetadata: Bool = false, followFinal: Bool = true) throws -> (WorkspaceFileDirectory, String, String) {
        var parts = try components(relative), requiredDepth = 0
        for _ in 0..<40 {
            try Task.checkCancellation(); try validate()
            if denyMetadata { try denyGit(relative, resolved: parts.joined(separator: "/")) }
            var current = WorkspaceFileDirectory(fd: try elevatedFileFD(fcntl(fd, F_DUPFD_CLOEXEC, 3)), relative: "")
            var prefix: [String] = [], restart = false
            for index in parts.indices {
                let name = parts[index]
                var info = stat()
                let status = fstatat(current.fd, name, &info, AT_SYMLINK_NOFOLLOW), code = errno
                if status == 0, info.st_mode & S_IFMT == S_IFLNK, followFinal || index != parts.count - 1 {
                    var bytes = [CChar](repeating: 0, count: 16_385)
                    let count = readlinkat(current.fd, name, &bytes, bytes.count - 1)
                    guard count > 0, count < bytes.count - 1 else { throw fileFailure() }
                    let target = String(decoding: bytes.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    let resolved = try normalizeLink(target, parent: prefix)
                    let remainingRequired = max(0, requiredDepth - index - 1)
                    requiredDepth = resolved.count + remainingRequired
                    parts = resolved + parts.dropFirst(index + 1); restart = true; break
                }
                if status != 0, code != ENOENT { throw fileFailure(code) }
                if status != 0, index < requiredDepth { throw WorkspaceFileError(.invalidPath, "This symbolic link has no accessible target.") }
                if index == parts.count - 1 {
                    return (current, name, (prefix + [name]).joined(separator: "/"))
                }
                if status != 0 {
                    guard create else { throw fileFailure(code) }
                    try Task.checkCancellation()
                    guard mkdirat(current.fd, name, mode_t(0o755)) == 0 || errno == EEXIST else { throw fileFailure() }
                }
                let opened = try elevatedFileFD(openat(current.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
                prefix.append(name); current = .init(fd: opened, relative: prefix.joined(separator: "/"))
            }
            if !restart { break }
        }
        throw WorkspaceFileError(.invalidPath, "This workspace path contains too many symbolic links.")
    }
    private func openDirectory(_ relative: String) throws -> WorkspaceFileDirectory {
        let pieces = try components(relative, allowRoot: true)
        if pieces.isEmpty { return .init(fd: try elevatedFileFD(fcntl(fd, F_DUPFD_CLOEXEC, 3)), relative: "") }
        return try parent((pieces + [".coincide-directory-anchor"]).joined(separator: "/")).0
    }
    private func validate(_ value: WorkspaceFileDirectory) throws {
        try validate()
        let current = try openDirectory(value.relative)
        var original = stat(), named = stat()
        guard fstat(value.fd, &original) == 0, fstat(current.fd, &named) == 0, sameFile(original, named) else {
            throw WorkspaceFileError(.rootReplaced, "The workspace directory changed. Reload before continuing.")
        }
    }
    private static func gitName(_ value: String) -> Bool {
        var name = String(value.split(separator: ":", omittingEmptySubsequences: false).first ?? "")
        while name.last == "." || name.last == " " { name.removeLast() }
        name = name.uppercased()
        return name == ".GIT" || name == "GIT~1"
    }
    private func denyGit(_ relative: String, resolved: String) throws {
        if (path + "/" + relative + "/" + resolved).split(separator: "/").contains(where: { Self.gitName(String($0)) }) {
            throw WorkspaceFileError(.gitMetadata, "The file editor cannot modify Git metadata.")
        }
        var folder = URL(fileURLWithPath: path).appendingPathComponent(resolved).deletingLastPathComponent().path
        while true {
            func node(_ name: String) throws -> stat? {
                var value = stat()
                if lstat(folder + "/" + name, &value) == 0 { return value }
                if errno == ENOENT || errno == ENOTDIR { return nil }; throw fileFailure()
            }
            let head = try node("HEAD"), common = try node("commondir"), objects = try node("objects"), refs = try node("refs")
            if head != nil && (common != nil || (objects != nil && refs != nil)) { throw WorkspaceFileError(.gitMetadata, "The file editor cannot modify Git metadata.") }
            if let git = try node(".git"), regular(git) { break }
            let next = URL(fileURLWithPath: folder).deletingLastPathComponent().path
            if next == folder { break }; folder = next
        }
    }
    func list(_ relative: String, deadline: ContinuousClock.Instant? = nil, limit: Int = 25_000) throws -> WorkspaceEntryPage {
        try validate()
        let dir = try openDirectory(relative)
        guard !dir.relative.split(separator: "/").contains(where: { Self.gitName(String($0)) }) else { throw WorkspaceFileError(.gitMetadata, "Git metadata folders are not shown in the file browser.") }
        // A duplicated directory FD shares its readdir offset with the anchor. Open a new
        // description so repeated listings always start at the beginning.
        let copy = try elevatedFileFD(openat(dir.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw fileFailure() }
        defer { closedir(stream) }
        let maximum = max(1, min(25_000, limit))
        var result: [WorkspaceEntry] = [], truncated = false
        while let entry = readdir(stream) {
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline { truncated = true; break }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) } }
            guard let name, name != ".", name != "..", !Self.gitName(name), !name.hasPrefix(".coincide-save-") else { continue }
            var info = stat()
            guard fstatat(dir.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            guard regular(info) || directory(info) else { continue }
            if result.count == maximum { truncated = true; break }
            result.append(.init(path: relative.isEmpty ? name : relative + "/" + name, kind: directory(info) ? .directory : .file))
        }
        try validate(dir)
        result.sort { $0.kind != $1.kind ? $0.kind == .directory : $0.path < $1.path }
        return .init(entries: result, truncated: truncated)
    }
    func regularSize(_ relative: String) throws -> Int? {
        let (dir, name, _) = try parent(relative, followFinal: false)
        var info = stat()
        guard fstatat(dir.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        try validate(dir); return regular(info) ? Int(info.st_size) : nil
    }
    func metadata(_ relative: String) throws -> WorkspaceFileMetadata {
        try Task.checkCancellation(); try validate()
        let pieces = try components(relative, allowRoot: true)
        if pieces.isEmpty {
            try denyGit("", resolved: ".coincide-metadata-check")
            return .init(relativePath: relative, resolvedURL: URL(fileURLWithPath: path, isDirectory: true), kind: .directory, byteLength: 0)
        }
        let (dir, name, resolved) = try parent(relative, denyMetadata: true)
        try denyGit(relative, resolved: resolved)
        var named = stat()
        guard fstatat(dir.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw fileFailure() }
        guard regular(named) || directory(named) else {
            throw WorkspaceFileError(.notFile, "Only existing regular files and folders can be opened externally.")
        }
        // Special files are rejected before open, and O_NONBLOCK keeps a replacement FIFO
        // from blocking before the descriptor's type and identity can be checked.
        let node = try elevatedFileFD(openat(dir.fd, name, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        defer { Darwin.close(node) }
        var opened = stat(), final = stat()
        guard fstat(node, &opened) == 0, sameFile(named, opened),
              regular(opened) || directory(opened),
              fstatat(dir.fd, name, &final, AT_SYMLINK_NOFOLLOW) == 0, sameFile(final, opened) else {
            throw WorkspaceFileError(.conflict, "This workspace path changed while it was being checked.")
        }
        try validate(dir)
        try denyGit(relative, resolved: directory(opened) ? resolved + "/.coincide-metadata-check" : resolved)
        return .init(relativePath: relative, resolvedURL: URL(fileURLWithPath: path).appendingPathComponent(resolved, isDirectory: directory(opened)),
                     kind: directory(opened) ? .directory : .file, byteLength: regular(opened) ? Int(opened.st_size) : 0)
    }
    func read(_ relative: String, allowMissing: Bool, maxBytes: Int, onRead: (Int) -> Void = { _ in }) throws -> WorkspaceTextDocument {
        let target: (WorkspaceFileDirectory, String, String)
        do { target = try parent(relative) }
        catch let error as WorkspaceFileError where allowMissing && error.failure == .missing {
            try validate()
            return .init(relativePath: relative, contents: "", byteLength: 0, truncated: false, exists: false, revision: nil)
        }
        let (dir, name, resolved) = target
        let opened = openat(dir.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if opened < 0, errno == ENOENT, allowMissing {
            try validate(dir)
            return .init(relativePath: relative, contents: "", byteLength: 0, truncated: false, exists: false, revision: nil)
        }
        let file = try elevatedFileFD(opened); defer { Darwin.close(file) }
        var before = stat(); guard fstat(file, &before) == 0 else { throw fileFailure() }
        guard regular(before) else { throw WorkspaceFileError(.notFile, "This workspace path is not a regular file.") }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: min(65_536, maxBytes))
        while bytes.count < maxBytes {
            try Task.checkCancellation()
            let remaining = min(buffer.count, maxBytes - bytes.count)
            let count = Darwin.read(file, &buffer, remaining)
            if count < 0 { if errno == EINTR { continue }; throw fileFailure() }
            if count == 0 { break }; onRead(count); bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(); guard fstat(file, &after) == 0 else { throw fileFailure() }
        guard sameFile(before, after), before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw WorkspaceFileError(.conflict, "This file changed while it was being read. Reload it.") }
        let truncated = before.st_size > maxBytes
        guard !bytes.contains(0) else { throw WorkspaceFileError(.binary, "This binary file cannot be opened in the text editor.") }
        var text = String(data: bytes, encoding: .utf8)
        if text == nil, truncated, let prefix = Self.completeUTF8Prefix(bytes) {
            bytes = prefix; text = String(data: prefix, encoding: .utf8)
        }
        guard let text else { throw WorkspaceFileError(.invalidUTF8, "This file is not valid UTF-8 text.") }
        try validate(dir)
        let revision: WorkspaceFileRevision? = truncated ? nil : .init(rootDevice: device, rootInode: inode,
            device: UInt64(truncatingIfNeeded: before.st_dev), inode: before.st_ino, path: resolved, digest: Data(SHA256.hash(data: bytes)))
        return .init(relativePath: relative, contents: text, byteLength: Int(before.st_size), truncated: truncated, exists: true, revision: revision)
    }
    private static func completeUTF8Prefix(_ bytes: Data) -> Data? {
        let values = Array(bytes)
        guard !values.isEmpty else { return bytes }
        var start = values.count - 1
        while start > 0, values[start] & 0xc0 == 0x80 { start -= 1 }
        let lead = values[start], count: Int
        switch lead { case 0xc2...0xdf: count = 2; case 0xe0...0xef: count = 3; case 0xf0...0xf4: count = 4; default: return nil }
        let suffix = Array(values[start...])
        guard suffix.count < count, suffix.dropFirst().allSatisfy({ $0 & 0xc0 == 0x80 }) else { return nil }
        if suffix.count > 1 {
            let next = suffix[1]
            if (lead == 0xe0 && next < 0xa0) || (lead == 0xed && next > 0x9f) || (lead == 0xf0 && next < 0x90) || (lead == 0xf4 && next > 0x8f) { return nil }
        }
        let prefix = Data(values.prefix(start))
        return String(data: prefix, encoding: .utf8) == nil ? nil : prefix
    }
    func write(_ relative: String, contents: String, expected: WorkspaceFileWriteCondition, maxBytes: Int = 2_000_000,
               allowGitMetadata: Bool = false) throws -> WorkspaceTextDocument {
        Self.writes.lock(); defer { Self.writes.unlock() }
        try Task.checkCancellation(); try validate()
        let bytes = Data(contents.utf8)
        guard (1...8_388_608).contains(maxBytes), bytes.count <= maxBytes else { throw WorkspaceFileError(.operationFailed, "The text file exceeds this operation's size limit.") }
        guard !bytes.contains(0) else { throw WorkspaceFileError(.binary, "The text editor cannot save binary content.") }
        // Check both named and resolved targets before creating any directory.
        let (dir, name, resolved) = try parent(relative, create: expected == .missing, denyMetadata: !allowGitMetadata)
        if !allowGitMetadata { try denyGit(relative, resolved: resolved) }; try validate(dir)
        var mode = mode_t(0o666)
        func checkExpected() throws {
            switch expected {
            case .missing:
                var value = stat()
                if fstatat(dir.fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { throw WorkspaceFileError(.conflict, "This file already exists. Open it before saving changes.") }
                guard errno == ENOENT else { throw fileFailure() }
            case .matching(let revision):
                let current = try read(relative, allowMissing: false, maxBytes: maxBytes)
                guard current.revision == revision else { throw WorkspaceFileError(.conflict, "The file changed on disk. Reload before saving to preserve those changes.") }
                var value = stat(); guard fstatat(dir.fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0, regular(value) else { throw WorkspaceFileError(.conflict, "The file changed on disk. Reload before saving.") }
                mode = value.st_mode & 0o777
            }
        }
        try checkExpected()
        let temporary = ".coincide-save-" + UUID().uuidString
        let file = try elevatedFileFD(openat(dir.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode))
        var owned = stat(); _ = fstat(file, &owned)
        var promoted = false
        defer {
            Darwin.close(file)
            if !promoted {
                var current = stat()
                if fstatat(dir.fd, temporary, &current, AT_SYMLINK_NOFOLLOW) == 0, sameFile(current, owned) { _ = unlinkat(dir.fd, temporary, 0) }
            }
        }
        if case .matching = expected { guard fchmod(file, mode) == 0 else { throw fileFailure() } }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try Task.checkCancellation()
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), min(65_536, raw.count - offset))
                if count < 0 { if errno == EINTR { continue }; throw fileFailure() }; offset += count
            }
        }
        guard fsync(file) == 0 else { throw fileFailure() }
        try Task.checkCancellation(); try validate(dir)
        if !allowGitMetadata { try denyGit(relative, resolved: resolved) }; try checkExpected()
        let status: Int32
        switch expected {
        case .missing: status = renameatx_np(dir.fd, temporary, dir.fd, name, UInt32(RENAME_EXCL))
        case .matching: status = renameat(dir.fd, temporary, dir.fd, name)
        }
        guard status == 0 else {
            if errno == EEXIST { throw WorkspaceFileError(.conflict, "Another file appeared at this path. Its contents were preserved.") }; throw fileFailure()
        }
        promoted = true
        return try read(relative, allowMissing: false, maxBytes: maxBytes)
    }
}
