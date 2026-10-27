import Darwin
import Foundation

/// Moves ACP lines between Coincide and an agent. The default runs the agent CLI as a child
/// process; tests use an in-memory one.
@MainActor
public protocol ACPTransport: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    var onStderr: ((String) -> Void)? { get set }
    var onExit: ((_ status: Int32, _ stderrTail: String) -> Void)? { get set }
    func start() throws
    func write(_ line: String)
    /// Stops the agent and every process it started.
    func terminate()
}

public typealias ACPTransportFactory = @MainActor (
    _ executable: URL, _ arguments: [String], _ workingDirectory: URL, _ environment: [String: String]
) -> ACPTransport

/// Runs the agent with `LineProcess`.
@MainActor
final class ACPProcessTransport: ACPTransport {
    var onLine: ((String) -> Void)?
    var onStderr: ((String) -> Void)?
    var onExit: ((_ status: Int32, _ stderrTail: String) -> Void)?
    private let process: LineProcess

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        process = LineProcess(executable: executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment)
        process.onLine = { [weak self] line in self?.onLine?(line) }
        process.onStderr = { [weak self] text in self?.onStderr?(text) }
        process.onExit = { [weak self] status, tail in self?.onExit?(status, tail) }
    }

    func start() throws { try process.start() }
    func write(_ line: String) { process.write(line) }

    func terminate() {
        guard process.isRunning else { return }
        // Stay alive until the process is gone, so the SIGKILL fallback still runs after the
        // session lets go of this transport. (An exit already on its way is delivered to the
        // previous handler, so this cycle only forms while the process runs.)
        process.onExit = { [self] _, _ in process.onExit = nil }
        // Commands the agent started would outlive it; collect them before they are re-parented.
        ACPProcessTree.terminate(ACPProcessTree.descendants(of: process.processIdentifier))
        process.terminate()
    }
}

/// The processes an agent (or a client terminal) started, so stopping it stops them too.
/// Agents run in Coincide's process group, so a group signal is not an option.
enum ACPProcessTree {
    /// A process and when it started, so a recycled pid is never signalled.
    struct Member: Sendable, Hashable {
        var pid: pid_t
        var startTime: UInt64
    }

    /// Every process below `pid`, children before grandchildren.
    nonisolated static func descendants(of pid: pid_t) -> [Member] {
        guard pid > 0 else { return [] }
        var result: [Member] = []
        var seen: Set<pid_t> = [pid]
        var queue = [pid]
        while let parent = queue.popLast(), result.count < 4_096 {
            for child in childPIDs(of: parent) where child > 0 && seen.insert(child).inserted {
                guard let started = startTime(of: child) else { continue }
                result.append(Member(pid: child, startTime: started))
                queue.append(child)
            }
        }
        return result
    }

    /// Sends SIGTERM now and SIGKILL to whatever is left after `grace` seconds.
    nonisolated static func terminate(_ members: [Member], grace: TimeInterval = 3) {
        guard !members.isEmpty else { return }
        for member in members where isAlive(member) { kill(member.pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            for member in members where isAlive(member) { kill(member.pid, SIGKILL) }
        }
    }

    private nonisolated static func isAlive(_ member: Member) -> Bool {
        startTime(of: member.pid) == member.startTime
    }

    private nonisolated static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    private nonisolated static func childPIDs(of pid: pid_t) -> [pid_t] {
        var capacity = 64
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            // Returns the number of child pids written.
            let count = Int(proc_listchildpids(pid, &buffer, Int32(capacity * MemoryLayout<pid_t>.size)))
            guard count > 0 else { return [] }
            if count < capacity || capacity >= 8_192 { return Array(buffer.prefix(min(count, capacity))) }
            capacity *= 4
        }
    }
}
