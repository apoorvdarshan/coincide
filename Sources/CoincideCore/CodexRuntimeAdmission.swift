import CryptoKit
import Darwin
import Foundation

public enum CodexRuntimeAdmissionError: Error, Sendable, Equatable, LocalizedError {
    case busy, invalidScope, ownershipLost, released, cancelled, io
    public var errorDescription: String? {
        switch self {
        case .busy: "Another app-owned Codex runtime or account operation is using this connection. Close it before continuing."
        case .invalidScope: "The owned Codex runtime scope is invalid."
        case .ownershipLost: "Codex runtime admission ownership changed. Existing state was preserved."
        case .released: "This Codex runtime admission has already been released."
        case .cancelled: "Codex runtime admission was cancelled."
        case .io: "Codex runtime admission could not be acquired."
        }
    }
}

/// Separate from rotating-credential flock. All compliant native children hold
/// instance SH until their actual process/reader drain. Account mutation takes
/// instance EX only AFTER local Engine reservation/drain, before vault access.
/// This never stops another process: a held external lease yields bounded busy.
public enum CodexRuntimeAdmission {
    public static func acquireRuntime(instanceID: UUID, root: URL = CodexAccountVault.defaultLockRoot,
                                      timeout: Duration = .seconds(2)) async throws -> CodexRuntimeAdmissionLease {
        try await acquire(instanceID: instanceID, root: root, timeout: timeout, mutation: false)
    }
    public static func acquireMutation(instanceID: UUID, root: URL = CodexAccountVault.defaultLockRoot,
                                       timeout: Duration = .seconds(2)) async throws -> CodexRuntimeAdmissionLease {
        try await acquire(instanceID: instanceID, root: root, timeout: timeout, mutation: true)
    }
    private static func acquire(instanceID: UUID, root: URL, timeout: Duration, mutation: Bool) async throws -> CodexRuntimeAdmissionLease {
        let deadline = ContinuousClock.now + min(max(timeout, .zero), .seconds(40))
        do {
            let directory = try CodexAdmissionDirectory.open(root)
            let scope = CodexAdmissionScope(instanceID: instanceID, generation: nil, sharedPath: nil, overlayPath: nil)
            let gate = try CodexAdmissionGate(directory: directory, basename: instanceID.uuidString.lowercased() + ".runtime", scope: scope)
            try await gate.acquire(exclusive: mutation, deadline: deadline)
            return .init(instanceID: instanceID, directory: directory, gate: gate, mutation: mutation)
        } catch is CancellationError { throw CodexRuntimeAdmissionError.cancelled }
        catch let error as CodexRuntimeAdmissionError { throw error }
        catch { throw CodexRuntimeAdmissionError.io }
    }
}

/// This object is one independently owned lease. Transferring ownership must
/// transfer the object; releasing a separate access lease cannot unlock it.
/// release is idempotent. An in-flight preparation retains its own descriptor
/// borrow until completion, so releasing its owner cannot expose a live repair.
public final class CodexRuntimeAdmissionLease: @unchecked Sendable {
    public let instanceID: UUID
    private let directory: CodexAdmissionDirectory
    private let mutation: Bool
    private let lock = NSLock()
    private var instance: CodexAdmissionGate?
    private var home: CodexAdmissionGate?
    private var prepared: CodexHomeLayout.Prepared?
    private var homeScope: CodexAdmissionScope?
    private var preparing: UUID?
    private var waitingForHome = false
    private var released = false

    fileprivate init(instanceID: UUID, directory: CodexAdmissionDirectory, gate: CodexAdmissionGate, mutation: Bool) {
        self.instanceID = instanceID; self.directory = directory; instance = gate; self.mutation = mutation
    }
    deinit { release() }
    public func release() {
        var retired = lock.withLock { () -> (CodexAdmissionGate?, CodexAdmissionGate?) in
            guard !released else { return (nil, nil) }
            released = true
            let retired = (home, instance); home = nil; instance = nil; prepared = nil; homeScope = nil
            return retired
        }
        // Release home before instance, outside the bookkeeping lock.
        withExtendedLifetime(retired.1) { retired.0 = nil }; retired.1 = nil
    }
    public func validate() throws {
        let gates = try lock.withLock { () throws -> (CodexAdmissionGate, CodexAdmissionGate?) in
            guard !released, let instance else { throw CodexRuntimeAdmissionError.released }
            return (instance, home)
        }
        try gates.0.validate(); try gates.1?.validate()
    }
    var hasPendingHomePreparation: Bool { lock.withLock { waitingForHome } }

    /// Prepares exactly one home for this runtime lease. Failed attempts may be
    /// retried explicitly; a successful preparation remains held until release.
    public func prepareHome(generation: UUID, sharedHome: URL, overlayHome: URL,
                            cached: CodexHomeLayout.Prepared? = nil, timeout: Duration = .seconds(2)) async throws -> CodexHomeLayout.Prepared {
        let operation = UUID()
        let borrowed = try lock.withLock { () throws -> CodexAdmissionGate in
            guard !released, let instance else { throw CodexRuntimeAdmissionError.released }
            guard !mutation, preparing == nil, home == nil else { throw CodexRuntimeAdmissionError.invalidScope }
            preparing = operation; return instance
        }
        defer { lock.withLock { if preparing == operation { preparing = nil; waitingForHome = false } }; withExtendedLifetime(borrowed) {} }
        do {
            try Task.checkCancellation(); try borrowed.validate(); try validate()
            let sharedPath = try CodexHomeLayout.resolvedPathForAdmission(sharedHome), overlayPath = try CodexHomeLayout.resolvedPathForAdmission(overlayHome)
            let scope = CodexAdmissionScope(instanceID: instanceID, generation: generation, sharedPath: sharedPath, overlayPath: overlayPath)
            let homeKey = SHA256.hash(data: Data(sharedPath.utf8)).map { String(format: "%02x", $0) }.joined()
            let gate = try CodexAdmissionGate(directory: directory,
                basename: instanceID.uuidString.lowercased() + "." + generation.uuidString.lowercased() + "." + homeKey + ".home", scope: scope)
            let deadline = ContinuousClock.now + min(max(timeout, .zero), .seconds(40))
            let canPrepare = try gate.tryAcquire(exclusive: true)
            let layout: CodexHomeLayout.Prepared
            if canPrepare {
                try Task.checkCancellation(); try validate(); try borrowed.validate()
                layout = try CodexHomeLayout.prepare(sharedHome: sharedHome, overlayHome: overlayHome)
                try Task.checkCancellation(); try validate(); try gate.validate()
                // BSD flock conversions may release/reacquire. If another EX
                // wins, fail rather than publishing an unprotected layout.
                guard try gate.tryAcquire(exclusive: false) else { throw CodexRuntimeAdmissionError.busy }
                try CodexHomeLayout.validate(layout)
            } else {
                try await gate.acquire(exclusive: false, deadline: deadline, onBlocked: {
                    self.lock.withLock { if self.preparing == operation { self.waitingForHome = true } }
                })
                try Task.checkCancellation(); try validate(); try borrowed.validate()
                if let cached {
                    guard try CodexHomeLayout.resolvedPathForAdmission(cached.sharedHome) == sharedPath,
                          try CodexHomeLayout.resolvedPathForAdmission(cached.effectiveHome) == overlayPath else { throw CodexRuntimeAdmissionError.invalidScope }
                    try CodexHomeLayout.validate(cached); layout = cached
                } else {
                    layout = try CodexHomeLayout.inspect(sharedHome: sharedHome, overlayHome: overlayHome)
                }
            }
            try Task.checkCancellation(); try borrowed.validate(); try gate.validate()
            try lock.withLock {
                guard !released, instance === borrowed, preparing == operation else { throw CodexRuntimeAdmissionError.released }
                home = gate; prepared = layout; homeScope = scope
            }
            return layout
        } catch is CancellationError { throw CodexRuntimeAdmissionError.cancelled }
        catch let error as CodexRuntimeAdmissionError { throw error }
        catch let error as CodexHomeLayoutError { throw error }
        catch { throw CodexRuntimeAdmissionError.io }
    }
}

fileprivate struct CodexAdmissionScope: Codable, Equatable {
    let instanceID: UUID
    let generation: UUID?
    let sharedPath: String?
    let overlayPath: String?
}

fileprivate final class CodexAdmissionGate: @unchecked Sendable {
    private struct Receipt: Codable, Equatable {
        let version: Int
        let root: GitWorktreeNodeIdentity
        let gate: GitWorktreeNodeIdentity
        let scope: CodexAdmissionScope
    }
    private struct OverlayBinding: Codable, Equatable {
        let version: Int
        let root: GitWorktreeNodeIdentity
        let scope: CodexAdmissionScope
    }
    private let directory: CodexAdmissionDirectory
    private let basename: String
    private let fd: Int32
    private let identity: GitWorktreeNodeIdentity
    private let receiptIdentity: GitWorktreeNodeIdentity
    private let receiptBytes: Data
    private let overlayBinding: (name: String, identity: GitWorktreeNodeIdentity, bytes: Data)?
    init(directory: CodexAdmissionDirectory, basename: String, scope: CodexAdmissionScope) throws {
        try directory.validate()
        let opened = openat(directory.fd, basename + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard opened >= 0 else { throw CodexRuntimeAdmissionError.ownershipLost }
        var value = stat()
        guard fstat(opened, &value) == 0, Self.privateEmpty(value) else { Darwin.close(opened); throw CodexRuntimeAdmissionError.ownershipLost }
        let identity = worktreeIdentity(value)
        do {
            let expected = Receipt(version: 1, root: directory.identity, gate: identity, scope: scope)
            let encoded = try JSONEncoder().encode(expected)
            try directory.writeIfAbsent(encoded, name: basename + ".json")
            let observed = try directory.read(basename + ".json")
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: observed.data), receipt == expected else { throw CodexRuntimeAdmissionError.ownershipLost }
            let overlayBinding: (name: String, identity: GitWorktreeNodeIdentity, bytes: Data)?
            if let overlay = scope.overlayPath {
                // Bind an actual physical overlay to one instance/generation,
                // so a different namespace cannot evade its existing home SH.
                let key = SHA256.hash(data: Data(overlay.utf8)).map { String(format: "%02x", $0) }.joined()
                let name = "overlay-" + key + ".json"
                let expected = OverlayBinding(version: 1, root: directory.identity, scope: scope)
                try directory.writeIfAbsent(JSONEncoder().encode(expected), name: name)
                let observed = try directory.read(name)
                guard let decoded = try? JSONDecoder().decode(OverlayBinding.self, from: observed.data), decoded == expected else { throw CodexRuntimeAdmissionError.ownershipLost }
                overlayBinding = (name, observed.identity, observed.data)
            } else { overlayBinding = nil }
            self.directory = directory; self.basename = basename; fd = opened; self.identity = identity
            receiptIdentity = observed.identity; receiptBytes = observed.data; self.overlayBinding = overlayBinding
        } catch { Darwin.close(opened); throw error }
        try validate()
    }
    deinit { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
    private static func privateEmpty(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1 && value.st_mode & 0o077 == 0 && value.st_size == 0
    }
    func validate() throws {
        try directory.validate()
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, fstatat(directory.fd, basename + ".lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.privateEmpty(opened), Self.privateEmpty(named), worktreeIdentity(opened) == identity, worktreeIdentity(named) == identity else { throw CodexRuntimeAdmissionError.ownershipLost }
        let receipt = try directory.read(basename + ".json")
        guard receipt.identity == receiptIdentity, receipt.data == receiptBytes else { throw CodexRuntimeAdmissionError.ownershipLost }
        if let overlayBinding {
            let observed = try directory.read(overlayBinding.name)
            guard observed.identity == overlayBinding.identity, observed.data == overlayBinding.bytes else { throw CodexRuntimeAdmissionError.ownershipLost }
        }
    }
    func tryAcquire(exclusive: Bool) throws -> Bool {
        try validate(); try Task.checkCancellation()
        if flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 { try validate(); return true }
        guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else { throw CodexRuntimeAdmissionError.io }; return false
    }
    func acquire(exclusive: Bool, deadline: ContinuousClock.Instant, onBlocked: (@Sendable () -> Void)? = nil) async throws {
        while true {
            if try tryAcquire(exclusive: exclusive) { return }
            onBlocked?()
            guard ContinuousClock.now < deadline else { throw CodexRuntimeAdmissionError.busy }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

fileprivate final class CodexAdmissionDirectory: @unchecked Sendable {
    let fd: Int32
    let path: String
    let identity: GitWorktreeNodeIdentity
    private let parent: CodexAdmissionDirectory?
    private let name: String?
    private init(parent: CodexAdmissionDirectory?, name: String?) throws {
        let opened: Int32
        if let parent, let name {
            try parent.validate()
            opened = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        } else { opened = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard opened >= 0 else { throw CodexRuntimeAdmissionError.ownershipLost }
        var value = stat(), named = stat()
        let located = parent.map { fstatat($0.fd, name!, &named, AT_SYMLINK_NOFOLLOW) } ?? lstat("/", &named)
        guard located == 0, fstat(opened, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
              worktreeIdentity(value) == worktreeIdentity(named) else { Darwin.close(opened); throw CodexRuntimeAdmissionError.ownershipLost }
        self.parent = parent; self.name = name; fd = opened; identity = worktreeIdentity(value)
        path = parent.map { ($0.path == "/" ? "" : $0.path) + "/" + name! } ?? "/"
    }
    deinit { Darwin.close(fd) }
    static func open(_ root: URL) throws -> CodexAdmissionDirectory {
        let path = try CodexHomeLayout.resolvedPathForAdmission(root)
        var directory = try CodexAdmissionDirectory(parent: nil, name: nil)
        for name in path.split(separator: "/").map(String.init) {
            try Task.checkCancellation(); try directory.validate()
            var value = stat()
            if fstatat(directory.fd, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw CodexRuntimeAdmissionError.io }
                if mkdirat(directory.fd, name, 0o700) == 0 { guard fsync(directory.fd) == 0 else { throw CodexRuntimeAdmissionError.io } }
                else if errno != EEXIST { throw CodexRuntimeAdmissionError.io }
            }
            directory = try CodexAdmissionDirectory(parent: directory, name: name)
        }
        try directory.validatePrivate(); return directory
    }
    func validate() throws {
        try parent?.validate()
        var named = stat(), opened = stat()
        let located = parent.map { fstatat($0.fd, name!, &named, AT_SYMLINK_NOFOLLOW) } ?? lstat("/", &named)
        guard located == 0, fstat(fd, &opened) == 0, named.st_mode & S_IFMT == S_IFDIR,
              worktreeIdentity(named) == identity, worktreeIdentity(opened) == identity else { throw CodexRuntimeAdmissionError.ownershipLost }
    }
    private func validatePrivate() throws {
        try validate(); var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else { throw CodexRuntimeAdmissionError.ownershipLost }
    }
    func read(_ name: String) throws -> (data: Data, identity: GitWorktreeNodeIdentity) {
        try validatePrivate()
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw CodexRuntimeAdmissionError.ownershipLost }; defer { Darwin.close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o077 == 0, before.st_size > 0, before.st_size <= 16_384 else { throw CodexRuntimeAdmissionError.ownershipLost }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_385)
        while result.count <= 16_384 {
            try Task.checkCancellation()
            let count = Darwin.read(file, &buffer, buffer.count - result.count)
            if count == 0 { break }; if count < 0 { if errno == EINTR { continue }; throw CodexRuntimeAdmissionError.io }
            result.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), named = stat()
        guard fstat(file, &after) == 0, fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              worktreeIdentity(before) == worktreeIdentity(after), worktreeIdentity(named) == worktreeIdentity(before),
              result.count == Int(before.st_size), after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw CodexRuntimeAdmissionError.ownershipLost }
        try validatePrivate(); return (result, worktreeIdentity(before))
    }
    func writeIfAbsent(_ data: Data, name: String) throws {
        try validatePrivate(); try Task.checkCancellation()
        guard data.count > 0, data.count <= 16_384 else { throw CodexRuntimeAdmissionError.invalidScope }
        var existing = stat()
        if fstatat(fd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 { return }
        guard errno == ENOENT else { throw CodexRuntimeAdmissionError.io }
        let temporary = ".coincide-codex-admission-" + UUID().uuidString
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw CodexRuntimeAdmissionError.io }
        var owned = stat(); guard fstat(file, &owned) == 0 else { Darwin.close(file); throw CodexRuntimeAdmissionError.io }
        defer {
            Darwin.close(file)
            var named = stat()
            if fstatat(fd, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0, worktreeIdentity(named) == worktreeIdentity(owned) { _ = unlinkat(fd, temporary, 0) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw CodexRuntimeAdmissionError.io }
                guard count > 0 else { throw CodexRuntimeAdmissionError.io }; offset += count
            }
        }
        guard fsync(file) == 0 else { throw CodexRuntimeAdmissionError.io }; try validatePrivate()
        if renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL)) != 0, errno != EEXIST { throw CodexRuntimeAdmissionError.ownershipLost }
        guard fsync(fd) == 0 else { throw CodexRuntimeAdmissionError.io }
    }
}
