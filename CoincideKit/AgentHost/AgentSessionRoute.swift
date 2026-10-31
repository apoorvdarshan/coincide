import Darwin
import Foundation

/// What the app does about a thread's session with one provider, given what the agent host and the session locks
/// (`AgentSessionLocks`) say. One rule throughout: a session whose process still runs is attached to, never started
/// again, and a session is resumed from history only once nothing runs it.
public enum AgentSessionRoute: Equatable, Sendable {
    /// The host runs it: take it up and replay what it logged. Never `--resume`, which would start a second process.
    case attach
    /// The host has only its log; its process is gone. Apply the log; the next turn resumes from history.
    case replayLog
    /// The host is connected and runs nothing for the thread: the session starts (or resumes from history) there.
    case startInHost
    /// Agents run in the app (the host is off, or can't be used for a lasting reason) and nobody runs this session.
    case startInApp
    /// The host should answer soon (it is being connected to): wait for it before deciding.
    case waitForHost
    /// Another live process the app can't reach (an agent host it can't talk to yet) runs the session. Neither
    /// start nor resume it, or two processes would answer in one thread; the app reattaches once it reaches it.
    case runningElsewhere

    /// What the app knows of the host.
    public enum Host: Equatable, Sendable {
        /// Connected. The host's view of the session, nil when it has none.
        case connected(AgentHostSessionInfo?)
        /// Being connected to; it should answer within moments.
        case connecting
        /// Not in use: agents run in the app.
        case unavailable
    }

    /// `runningElsewhere` is whether another live process holds the session (`AgentSessionLocks.owner(of:)`, or a
    /// legacy host's unfinished log, `AgentHostLegacyOwnership`).
    public nonisolated static func decide(host: Host, runningElsewhere: Bool) -> AgentSessionRoute {
        switch host {
        case .connected(let info?):
            return info.isLive ? .attach : .replayLog
        case .connected(nil):
            // The host checks the locks itself when asked to start, and refuses a session another process runs.
            return .startInHost
        case .connecting:
            return .waitForHost
        case .unavailable:
            return runningElsewhere ? .runningElsewhere : .startInApp
        }
    }
}

/// Sessions a host that predates `AgentSessionLocks` still runs, judged from its event logs: it never takes the
/// locks, so while a process of it runs, a session whose log has not ended may be live in it. The app can't reach such
/// a host once an update replaced its files (macOS then refuses its code signature), so this is how it avoids
/// resuming those sessions a second time until the host exits.
public enum AgentHostLegacyOwnership {
    /// The keys whose logs in `directory` have not ended: the host wrote no `sessionExited` after their last event.
    @MainActor public static func unfinishedKeys(in directory: URL) -> Set<AgentSessionKey> {
        var keys: Set<AgentSessionKey> = []
        for key in AgentEventLogStore(directory: directory).existingKeys() {
            let url = directory.appendingPathComponent("\(key).jsonl")
            if !hasEnded(eventsFile: url) { keys.insert(key) }
        }
        return keys
    }

    /// Whether the log's last readable event is the session's exit. An empty or missing events file has not ended: the
    /// host removes the log of a session that ended once the app applied everything.
    nonisolated static func hasEnded(eventsFile url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let logged = try? AgentHostWire.decode(LoggedAgentEvent.self, from: Data(line)) else { continue }
            if case .sessionExited = logged.event { return true }
            return false
        }
        return false
    }

    /// The agent host processes of this Coincide (Release or Debug, by bundle ID) that run, other than this process.
    public nonisolated static func runningHostPIDs(bundleID: String = AgentHostIdentity.bundleID) -> [pid_t] {
        let count = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 16)
        let filled = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        let me = getpid()
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { pid in
            guard pid > 0, pid != me, let path = executablePath(of: pid) else { return false }
            return isHostExecutable(path, bundleID: bundleID)
        }
    }

    nonisolated static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `…/CoincideAgentHost.app/Contents/MacOS/CoincideAgentHost` of the bundle ID. The bundle on disk may be a newer
    /// build than the one running (an update replaced it), which still names the same bundle ID.
    nonisolated static func isHostExecutable(_ path: String, bundleID: String) -> Bool {
        let executable = URL(fileURLWithPath: path)
        guard executable.lastPathComponent == "CoincideAgentHost" else { return false }
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app",
            let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
            let identifier = info["CFBundleIdentifier"] as? String
        else { return false }
        return identifier == bundleID
    }
}

/// Which of a thread's sessions run in another process, from the locks and, for a host that predates them, its logs.
@MainActor
public final class AgentSessionOwnership {
    public let locks: AgentSessionLocks
    public let hostDirectory: URL
    /// Lists the agent host processes that run; replaced in tests.
    var runningHosts: () -> [pid_t] = { AgentHostLegacyOwnership.runningHostPIDs() }

    public init(hostDirectory: URL = AgentHostPaths.directory()) {
        self.hostDirectory = hostDirectory
        locks = AgentSessionLocks.shared(in: hostDirectory)
    }

    /// Who runs the key's session elsewhere: a process holding its lock, or a legacy host whose log of it is
    /// unfinished. Nil when nobody does.
    public func ownerElsewhere(of key: AgentSessionKey) -> AgentSessionOwner? {
        if let owner = locks.owner(of: key) { return owner }
        guard let legacy = legacyHost(), AgentHostLegacyOwnership.unfinishedKeys(in: hostDirectory).contains(key) else {
            return nil
        }
        return AgentSessionOwner(role: .host, pid: legacy, build: "", key: key)
    }

    /// Every thread with a session another process runs, for the app's launch: their unfinished items may still finish.
    public func threadsRunningElsewhere() -> Set<UUID> {
        var threads = Set(locks.sessionsRunningElsewhere().keys.map(\.threadID))
        if legacyHost() != nil {
            threads.formUnion(AgentHostLegacyOwnership.unfinishedKeys(in: hostDirectory).map(\.threadID))
        }
        return threads
    }

    /// A running host that doesn't take the locks: one runs, and none holds the host lock.
    private func legacyHost() -> pid_t? {
        guard locks.runningHost() == nil else { return nil }
        return runningHosts().first
    }
}
