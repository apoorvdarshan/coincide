import Darwin
import Foundation

/// A process-wide rotation lease. The lock and uncertainty receipts contain no
/// credentials; Keychain remains the only persistent secret destination.
final class CodexCredentialLock: @unchecked Sendable {
    private let anchors: [CodexCredentialDirectory]
    private let directory: CodexCredentialDirectory
    private let descriptor: Int32
    private let name: String
    private let identity: GitWorktreeNodeIdentity
    private let instanceID: UUID
    var rootIdentity: GitWorktreeNodeIdentity { directory.identity }

    static func acquire(root: URL, instanceID: UUID, timeout: Duration = .seconds(40)) async throws -> CodexCredentialLock {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            do { return try .init(root: root, instanceID: instanceID) }
            catch CodexAccountError.busy {
                guard ContinuousClock.now < deadline else { throw CodexAccountError.busy }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
    }
    private init(root: URL, instanceID: UUID) throws {
        let components = root.pathComponents
        guard root.isFileURL, root.host == nil || root.host == "", root.query == nil, root.fragment == nil,
              components.count > 2, components.count <= 128,
              root.path == "/" + components.dropFirst().joined(separator: "/"),
              components.dropFirst().allSatisfy({ $0 != "." && $0 != ".." }) else { throw CodexAccountError.storageUnavailable }
        do {
            var parents = [try CodexCredentialDirectory()]
            for component in root.pathComponents.dropFirst() {
                let parent = parents.last!
                try parent.validate()
                if !(try parent.exists(component)) {
                    if mkdirat(parent.fd, component, 0o700) == 0 {
                        guard fsync(parent.fd) == 0 else { throw CodexAccountError.storageUnavailable }
                    } else if errno != EEXIST { throw CodexAccountError.storageUnavailable }
                }
                parents.append(try CodexCredentialDirectory(child: component, parent: parent))
            }
            let directory = parents.last!
            var info = stat()
            guard fstat(directory.fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw CodexAccountError.storageUnavailable }
            let name = instanceID.uuidString.lowercased() + ".lock"
            let fd = openat(directory.fd, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CodexAccountError.storageUnavailable }
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
                  info.st_size == 0, info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
                Darwin.close(fd); throw CodexAccountError.storageUnavailable
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let failure = errno; Darwin.close(fd)
                if failure == EWOULDBLOCK || failure == EAGAIN { throw CodexAccountError.busy }
                throw CodexAccountError.storageUnavailable
            }
            anchors = parents; self.directory = directory; descriptor = fd
            self.name = name; identity = worktreeIdentity(info); self.instanceID = instanceID
            try validate()
        } catch let error as CodexAccountError { throw error }
        catch { throw CodexAccountError.storageUnavailable }
    }
    deinit { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }

    func validate() throws {
        do {
            for anchor in anchors { try anchor.validate() }
            var opened = stat(), named = stat()
            guard fstat(descriptor, &opened) == 0, fstatat(directory.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  worktreeIdentity(opened) == identity, worktreeIdentity(named) == identity,
                  opened.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG,
                  opened.st_nlink == 1, opened.st_uid == geteuid(), opened.st_size == 0,
                  opened.st_mode & 0o077 == 0 else { throw CodexAccountError.storageUnavailable }
        } catch { throw CodexAccountError.storageUnavailable }
    }
    func isUncertain(_ profileID: UUID) throws -> Bool {
        try validate()
        var info = stat()
        if fstatat(directory.fd, marker(profileID), &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw CodexAccountError.storageUnavailable }; return false
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size == 0, info.st_mode & 0o077 == 0 else { throw CodexAccountError.storageUnavailable }
        return true
    }
    /// Durable before a rotating network request. A crash or failed Keychain
    /// publication must never make another process retry the previous token.
    func markUncertain(_ profileID: UUID) throws {
        let existing = try isUncertain(profileID)
        let flags = O_WRONLY | O_NOFOLLOW | O_CLOEXEC | (existing ? 0 : O_CREAT | O_EXCL)
        let fd = openat(directory.fd, marker(profileID), flags, 0o600)
        guard fd >= 0 else { throw CodexAccountError.storageUnavailable }
        defer { Darwin.close(fd) }
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, fstatat(directory.fd, marker(profileID), &named, AT_SYMLINK_NOFOLLOW) == 0,
              worktreeIdentity(opened) == worktreeIdentity(named), opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == geteuid(), opened.st_nlink == 1, opened.st_size == 0, opened.st_mode & 0o077 == 0,
              fsync(fd) == 0, fsync(directory.fd) == 0 else { throw CodexAccountError.storageUnavailable }
        try validate()
    }
    func clearUncertainty(_ profileID: UUID) throws {
        guard try isUncertain(profileID) else { return }
        // The exact instance lock excludes other compliant coordinators. The
        // no-follow/type/owner checks above preserve foreign entries.
        guard unlinkat(directory.fd, marker(profileID), 0) == 0, fsync(directory.fd) == 0 else { throw CodexAccountError.storageUnavailable }
        try validate()
    }
    private func marker(_ profileID: UUID) -> String {
        instanceID.uuidString.lowercased() + "." + profileID.uuidString.lowercased() + ".uncertain"
    }
}

/// Unlike worktree destinations, a credential lock walk starts at filesystem
/// root. This private type does not weaken worktree path validation.
private final class CodexCredentialDirectory: @unchecked Sendable {
    let fd: Int32
    let path: String
    let identity: GitWorktreeNodeIdentity
    init() throws {
        let fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            if fd >= 0 { Darwin.close(fd) }; throw CodexAccountError.storageUnavailable
        }
        self.fd = fd; path = "/"; identity = worktreeIdentity(info)
    }
    init(child: String, parent: CodexCredentialDirectory) throws {
        guard !child.isEmpty, child != ".", child != "..", !child.contains("/"), !child.contains("\0") else { throw CodexAccountError.storageUnavailable }
        try parent.validate()
        let fd = openat(parent.fd, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var info = stat(), named = stat()
        guard fd >= 0, fstat(fd, &info) == 0, fstatat(parent.fd, child, &named, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFDIR, worktreeIdentity(info) == worktreeIdentity(named) else {
            if fd >= 0 { Darwin.close(fd) }; throw CodexAccountError.storageUnavailable
        }
        self.fd = fd; path = URL(fileURLWithPath: parent.path).appendingPathComponent(child).path
        identity = worktreeIdentity(info)
    }
    deinit { Darwin.close(fd) }
    func validate() throws {
        var named = stat(), opened = stat()
        guard lstat(path, &named) == 0, fstat(fd, &opened) == 0,
              named.st_mode & S_IFMT == S_IFDIR, opened.st_mode & S_IFMT == S_IFDIR,
              worktreeIdentity(named) == identity, worktreeIdentity(opened) == identity else { throw CodexAccountError.storageUnavailable }
    }
    func exists(_ name: String) throws -> Bool {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw CodexAccountError.storageUnavailable }; return false
    }
}
