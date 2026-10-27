import Darwin
import Foundation

/// A process and when it started, so a recycled pid is never signalled.
struct ProcessIdentity: Sendable, Hashable, Codable {
    var pid: pid_t
    /// Microseconds since 1970.
    var startTime: UInt64
}

/// Finding and stopping a process together with everything it started. Agents run in Coincide's
/// process group (Foundation's `Process` cannot give them their own), so stopping one means walking
/// its descendants.
enum ProcessTree {
    /// The running process with this pid, or nil when there is none.
    nonisolated static func identity(of pid: pid_t) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(pid: pid, startTime: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
    }

    nonisolated static func isAlive(_ process: ProcessIdentity) -> Bool {
        identity(of: process.pid) == process
    }

    /// Every process below `pid`, children before grandchildren.
    nonisolated static func descendants(of pid: pid_t) -> [ProcessIdentity] {
        guard pid > 0 else { return [] }
        var result: [ProcessIdentity] = []
        var seen: Set<pid_t> = [pid]
        var queue = [pid]
        while !queue.isEmpty, result.count < 4_096 {
            let parent = queue.removeFirst()
            for child in childPIDs(of: parent) where child > 0 && seen.insert(child).inserted {
                guard let identity = identity(of: child) else { continue }
                result.append(identity)
                queue.append(child)
            }
        }
        return result
    }

    /// Sends SIGTERM to each live process now and SIGKILL to whatever is left after `grace` seconds.
    nonisolated static func terminate(_ processes: [ProcessIdentity], grace: TimeInterval = 3) {
        let alive = processes.filter(isAlive)
        guard !alive.isEmpty else { return }
        for process in alive { kill(process.pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            for process in alive where isAlive(process) { kill(process.pid, SIGKILL) }
        }
    }

    /// Stops a process and everything it started. The descendants are collected first, before the
    /// process can exit and leave them to launchd.
    nonisolated static func terminateTree(_ pid: pid_t, grace: TimeInterval = 3) {
        guard let root = identity(of: pid) else { return }
        terminate([root] + descendants(of: pid), grace: grace)
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

/// The long-lived processes Coincide started (agents, servers, terminals), so none outlives it.
///
/// - Quitting calls `terminateAllAndWait()`, which stops them and everything they started.
/// - Each one is also recorded on disk with its owner, so a launch after a crash stops the ones the
///   crashed Coincide left behind (`sweepOrphans()`).
final class ChildProcesses: @unchecked Sendable {
    static let shared = ChildProcesses(
        ledger: FileManager.default.temporaryDirectory.appendingPathComponent("coincide-children", isDirectory: true))

    private let lock = NSLock()
    private let ledger: URL
    private var tracked: [pid_t: ProcessIdentity] = [:]
    private var installedExitHandler = false
    private var swept = false

    nonisolated init(ledger: URL) {
        self.ledger = ledger
    }

    /// Records a process that has just started.
    nonisolated func track(_ pid: pid_t) {
        sweepOrphansOnce()
        guard let identity = ProcessTree.identity(of: pid) else { return }
        let installHandler = lock.withLock { () -> Bool in
            tracked[pid] = identity
            defer { installedExitHandler = true }
            return !installedExitHandler && self === ChildProcesses.shared
        }
        // A last resort when Coincide exits without quitting normally: ask every child to stop.
        if installHandler { atexit { ChildProcesses.shared.signalAll(SIGTERM) } }
        record(identity)
    }

    /// Forgets a process that has exited.
    nonisolated func forget(_ pid: pid_t) {
        let removed = lock.withLock { tracked.removeValue(forKey: pid) }
        if removed != nil { try? FileManager.default.removeItem(at: entryURL(pid)) }
    }

    nonisolated var trackedProcesses: [ProcessIdentity] { lock.withLock { Array(tracked.values) } }

    /// Stops every tracked process and everything it started, waiting up to `timeout` seconds before
    /// killing what is left. Processes whose input was just closed get a moment to exit by themselves.
    nonisolated func terminateAllAndWait(timeout: TimeInterval = 1.5) {
        let roots = trackedProcesses.filter(ProcessTree.isAlive)
        guard !roots.isEmpty else { return }
        var everything = Set(roots)
        for root in roots { everything.formUnion(ProcessTree.descendants(of: root.pid)) }
        let deadline = Date().addingTimeInterval(timeout)
        func waitForExit(until limit: Date) {
            while everything.contains(where: ProcessTree.isAlive), Date() < limit { usleep(20_000) }
        }
        waitForExit(until: min(deadline, Date().addingTimeInterval(0.25)))
        for process in everything where ProcessTree.isAlive(process) { kill(process.pid, SIGTERM) }
        waitForExit(until: deadline)
        // Anything started meanwhile is killed too.
        for root in roots where ProcessTree.isAlive(root) { everything.formUnion(ProcessTree.descendants(of: root.pid)) }
        for process in everything where ProcessTree.isAlive(process) { kill(process.pid, SIGKILL) }
        for root in roots { forget(root.pid) }
    }

    nonisolated static func terminateAllAndWait(timeout: TimeInterval = 1.5) {
        shared.terminateAllAndWait(timeout: timeout)
    }

    private nonisolated func signalAll(_ signal: Int32) {
        for process in trackedProcesses where ProcessTree.isAlive(process) {
            for child in ProcessTree.descendants(of: process.pid) { kill(child.pid, signal) }
            kill(process.pid, signal)
        }
    }

    // MARK: Ledger

    private struct Entry: Codable {
        var process: ProcessIdentity
        var owner: ProcessIdentity
    }

    private nonisolated func entryURL(_ pid: pid_t) -> URL { ledger.appendingPathComponent("\(pid).json") }

    private nonisolated func record(_ process: ProcessIdentity) {
        guard let owner = ProcessTree.identity(of: getpid()),
            let data = try? JSONEncoder().encode(Entry(process: process, owner: owner))
        else { return }
        try? FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        try? data.write(to: entryURL(process.pid), options: .atomic)
    }

    private nonisolated func sweepOrphansOnce() {
        let first = lock.withLock { () -> Bool in
            defer { swept = true }
            return !swept
        }
        if first { sweepOrphans() }
    }

    /// Stops processes (and what they started) whose Coincide is no longer running.
    nonisolated func sweepOrphans() {
        let files = (try? FileManager.default.contentsOfDirectory(at: ledger, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if ProcessTree.isAlive(entry.owner) { continue }
            if ProcessTree.isAlive(entry.process) { ProcessTree.terminateTree(entry.process.pid) }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
