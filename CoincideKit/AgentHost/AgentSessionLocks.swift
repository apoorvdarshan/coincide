import CryptoKit
import Darwin
import Foundation

/// Who runs an agent session: the agent host, or the app when agents run in it.
public struct AgentSessionOwner: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable {
        case host
        case app
    }

    public var role: Role
    public var pid: Int32
    /// The owner's `CFBundleVersion`.
    public var build: String
    public var key: AgentSessionKey?
    /// The provider's own session ID, once the owner knows it.
    public var sessionID: String?

    public nonisolated init(role: Role, pid: Int32 = getpid(), build: String, key: AgentSessionKey? = nil, sessionID: String? = nil) {
        self.role = role
        self.pid = pid
        self.build = build
        self.key = key
        self.sessionID = sessionID
    }

}

/// Which process runs each agent session, across the app and the agent host, so one session never runs in two
/// processes: a relaunched app that cannot reach the host must not `--resume` a session the host still runs.
///
/// A lock file per thread's provider session (`thread-<thread>.<provider>.lock`), and one per provider session ID
/// once it is known (`session-<provider>-<hash>.lock`), held with `flock(2)` by the process that runs the session for
/// as long as it does. The kernel lets go of a lock when its process exits, crashes or is killed, so a held lock always
/// means a live owner and a free one means nobody runs the session: resuming it from history is then safe. Each file
/// also says who holds it (`AgentSessionOwner`), for display and so a process never mistakes its own lock for another's.
///
/// Locks belong to an open file, not a process, so two `AgentSessionLocks` in one process exclude each other as two
/// processes would (tests rely on this): "elsewhere" means held through anything but this object. A process uses one.
/// Files are opened close-on-exec, so agent processes never inherit them.
@MainActor
public final class AgentSessionLocks {
    public let directory: URL
    private var isReady = false
    /// The files this object holds the locks of.
    private var heldHere: Set<String> = []

    public enum Acquisition {
        case acquired(AgentSessionLease)
        /// Another live process runs the session. `owner` is nil when its file could not be read.
        case heldElsewhere(AgentSessionOwner?)
        /// The lock folder can't be used (unwritable, say): the caller goes on without a lock rather than fail.
        case unavailable
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `locks` in the agent host's folder, which both the app and the host use.
    public static func shared(in hostDirectory: URL = AgentHostPaths.directory()) -> AgentSessionLocks {
        AgentSessionLocks(directory: hostDirectory.appendingPathComponent("locks", isDirectory: true))
    }

    // MARK: Sessions

    /// Takes the key's lock, and the provider session's when `sessionID` is known (a resumed session), for `owner`.
    public func acquire(_ key: AgentSessionKey, sessionID: String?, owner: AgentSessionOwner) -> Acquisition {
        var owner = owner
        owner.key = key
        owner.sessionID = sessionID
        let keyLock: Int32
        switch take(Self.keyFileName(key), owner: owner) {
        case .taken(let fd): keyLock = fd
        case .held(let other): return .heldElsewhere(other)
        case .failed: return .unavailable
        }
        let lease = AgentSessionLease(locks: self, key: key, owner: owner, keyLock: keyLock)
        if let sessionID, !lease.claim(sessionID: sessionID) {
            let other = holder(of: Self.sessionFileName(key.provider, sessionID))
            lease.release()
            return .heldElsewhere(other)
        }
        return .acquired(lease)
    }

    /// Who runs the key's session in another process, if anyone does.
    public func owner(of key: AgentSessionKey) -> AgentSessionOwner? {
        elsewhere(Self.keyFileName(key))
    }

    /// Who runs the provider session in another process, if anyone does.
    public func owner(ofSession sessionID: String, provider: ProviderKind) -> AgentSessionOwner? {
        elsewhere(Self.sessionFileName(provider, sessionID))
    }

    /// Every session another live process runs, by key.
    public func sessionsRunningElsewhere() -> [AgentSessionKey: AgentSessionOwner] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var result: [AgentSessionKey: AgentSessionOwner] = [:]
        for name in names where name.hasPrefix("thread-") && name.hasSuffix(".lock") {
            let parts = name.dropFirst("thread-".count).dropLast(".lock".count).split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let threadID = UUID(uuidString: String(parts[0])),
                let provider = ProviderKind(rawValue: String(parts[1]))
            else { continue }
            let key = AgentSessionKey(threadID: threadID, provider: provider)
            if let owner = owner(of: key) { result[key] = owner }
        }
        return result
    }

    // MARK: The host

    /// Held by the agent host for as long as it runs, so the app can tell a host that takes these locks is alive
    /// even when it can't reach it. Nil when another host holds it or the folder can't be used.
    public func acquireHostLock(build: String) -> AgentSessionLease? {
        let owner = AgentSessionOwner(role: .host, build: build)
        guard case .taken(let fd) = take(Self.hostFileName, owner: owner) else { return nil }
        return AgentSessionLease(locks: self, key: nil, owner: owner, keyLock: fd)
    }

    /// The running agent host, if it is another process that takes these locks.
    public func runningHost() -> AgentSessionOwner? {
        elsewhere(Self.hostFileName)
    }

    // MARK: Files

    nonisolated static let hostFileName = "host.lock"

    nonisolated static func keyFileName(_ key: AgentSessionKey) -> String { "thread-\(key).lock" }

    /// Session IDs are the provider's, so they are hashed into a safe file name.
    nonisolated static func sessionFileName(_ provider: ProviderKind, _ sessionID: String) -> String {
        let digest = SHA256.hash(data: Data(sessionID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "session-\(provider.rawValue)-\(digest).lock"
    }

    fileprivate enum Take {
        case taken(Int32)
        case held(AgentSessionOwner?)
        case failed
    }

    private func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    private func elsewhere(_ name: String) -> AgentSessionOwner? {
        heldHere.contains(name) ? nil : holder(of: name)
    }

    private func prepareDirectory() -> Bool {
        if isReady { return true }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            isReady = true
        } catch {
            return false
        }
        return true
    }

    /// Opens and exclusively locks the file, writing `owner` into it. A reader checking the lock at that moment
    /// (`holder`) holds it shared for an instant, so a refused lock is tried again shortly before it counts as held.
    fileprivate func take(_ name: String, owner: AgentSessionOwner) -> Take {
        guard prepareDirectory() else { return .failed }
        let path = path(name)
        for attempt in 0..<6 {
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return .failed }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let failure = errno
                close(fd)
                guard failure == EWOULDBLOCK else { return .failed }
                if attempt >= 2 { return .held(holder(of: name)) }
                usleep(20_000)
                continue
            }
            // Its previous holder may have removed the file between our open and lock: then it is a lock on nothing.
            var opened = stat()
            var current = stat()
            guard fstat(fd, &opened) == 0, stat(path, &current) == 0, opened.st_ino == current.st_ino,
                opened.st_dev == current.st_dev
            else {
                close(fd)
                continue
            }
            write(owner, to: fd)
            heldHere.insert(name)
            return .taken(fd)
        }
        return .failed
    }

    fileprivate func write(_ owner: AgentSessionOwner, to fd: Int32) {
        guard let data = try? AgentHostWire.encode(owner) else { return }
        ftruncate(fd, 0)
        _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    }

    /// Who holds the file's lock, or nil when nobody does (or the file doesn't exist). A holder whose file can't be
    /// read yet (it is being written) still counts, as an unknown owner.
    private func holder(of name: String) -> AgentSessionOwner? {
        let path = path(name)
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return (try? AgentHostWire.decode(AgentSessionOwner.self, from: data))
            ?? AgentSessionOwner(role: .host, pid: 0, build: "")
    }

    /// Removes the file while still holding its lock, then lets go: anyone who opened it meanwhile finds it removed.
    fileprivate func release(_ name: String, fd: Int32) {
        heldHere.remove(name)
        unlink(path(name))
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// The locks a process holds for one running session. Let go with `release()` once the session's process is gone;
/// the kernel lets go of them anyway when the process exits.
@MainActor
public final class AgentSessionLease {
    public let key: AgentSessionKey?
    public private(set) var owner: AgentSessionOwner
    private weak var locks: AgentSessionLocks?
    private var keyLock: Int32?
    private var sessionLocks: [String: Int32] = [:]

    fileprivate init(locks: AgentSessionLocks, key: AgentSessionKey?, owner: AgentSessionOwner, keyLock: Int32) {
        self.locks = locks
        self.key = key
        self.owner = owner
        self.keyLock = keyLock
    }

    isolated deinit {
        release()
    }

    public var isHeld: Bool { keyLock != nil }

    /// Also takes the provider session's lock, once the session reported its ID. False when another process runs
    /// that provider session; the key's lock is kept either way.
    @discardableResult
    public func claim(sessionID: String) -> Bool {
        guard let locks, let key, keyLock != nil else { return false }
        let name = AgentSessionLocks.sessionFileName(key.provider, sessionID)
        if sessionLocks[name] != nil { return true }
        owner.sessionID = sessionID
        if let keyLock { locks.write(owner, to: keyLock) }
        guard case .taken(let fd) = locks.take(name, owner: owner) else { return false }
        sessionLocks[name] = fd
        return true
    }

    public func release() {
        guard let keyLock else { return }
        self.keyLock = nil
        let name = key.map(AgentSessionLocks.keyFileName) ?? AgentSessionLocks.hostFileName
        for (session, fd) in sessionLocks { release(session, fd) }
        sessionLocks = [:]
        release(name, keyLock)
    }

    private func release(_ name: String, _ fd: Int32) {
        if let locks {
            locks.release(name, fd: fd)
        } else {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
}
