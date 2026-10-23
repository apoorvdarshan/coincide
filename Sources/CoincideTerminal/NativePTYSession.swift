import CoincideCore
import Darwin
import Foundation
import SwiftTerm

public enum NativePTYSessionError: Error, Sendable, Equatable {
    case invalidLaunch, launchFailed, notRunning, writeFailed, resizeFailed, inputBusy
}

/// A headless SwiftTerm PTY. All delegate and process access shares one serial
/// queue; no terminal view, application object or main actor is created.
public final class NativePTYSession: RemotePTYDriver, LocalProcessDelegate, @unchecked Sendable {
    public let events: AsyncStream<RemotePTYEvent>
    private let continuation: AsyncStream<RemotePTYEvent>.Continuation
    private let queue = DispatchQueue(label: "com.coincide.native-pty.delivery")
    private let closeLock = NSLock()
    private var closeTask: Task<Void, Never>?
    // Confined to queue, including synchronous SwiftTerm delegate callbacks.
    private var process: LocalProcess!
    private var size: winsize
    private var acceptingInput = true
    private var writeInFlight = false
    private var didExit = false
    private var overflowed = false
    private var launchedPID: pid_t = 0
    private var checkedPostLeaderOutput = false
    private var inheritedOutputMayBeIncomplete = false

    /// Production callers supply only a validated workspace and geometry. The
    /// host's default shell and environment cannot be selected by a client.
    public static func defaultShell(_ launch: RemotePTYLaunch) throws -> NativePTYSession {
        let accountShell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
        let shell = accountShell.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        return try .init(directory: URL(fileURLWithPath: launch.directory), executable: URL(fileURLWithPath: shell),
            arguments: ["-l"], environment: ProcessChannel.environment(), cols: launch.cols, rows: launch.rows)
    }

    /// Explicit executable/environment injection is for host-owned launch
    /// policy and isolated tests, and is never a remote protocol argument.
    public init(directory: URL, executable: URL, arguments: [String], environment: [String: String],
                cols: Int = 80, rows: Int = 24, maximumBufferedEvents: Int = 64) throws {
        guard directory.isFileURL, executable.isFileURL, (1...1_000).contains(cols), (1...500).contains(rows),
              (1...256).contains(maximumBufferedEvents), !arguments.contains(where: { $0.contains("\0") }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw NativePTYSessionError.invalidLaunch
        }
        var folder = ObjCBool(false), executableInfo = stat()
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &folder), folder.boolValue,
              FileManager.default.isExecutableFile(atPath: executable.path),
              stat(executable.path, &executableInfo) == 0, executableInfo.st_mode & S_IFMT == S_IFREG else {
            throw NativePTYSessionError.invalidLaunch
        }
        size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        // Each output event is at most 16 KiB. Overflow replaces one queued
        // event with an explicit failure marker and closes the owned process.
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(maximumBufferedEvents))
        process = LocalProcess(delegate: self, dispatchQueue: queue)
        // A descendant may continuously write after its leader exits. Bound
        // that drain and explicitly report its potentially incomplete output.
        process.drainTimeout = 1
        var childEnvironment = environment
        childEnvironment["TERM"] = "xterm-256color"; childEnvironment["COLORTERM"] = "truecolor"
        childEnvironment["PWD"] = directory.path
        let environmentStrings = childEnvironment.map { "\($0.key)=\($0.value)" }
        let result = queue.sync {
            ProcessChannel.withChildLaunch {
                let result = process.startProcessChecked(executable: executable.path, args: arguments,
                    environment: environmentStrings, currentDirectory: directory.path)
                // SwiftTerm's exit monitor uses this same serial queue, so it
                // cannot retire the published PID before this capture.
                if case .success = result { launchedPID = process.shellPid }
                return result
            }
        }
        guard case .success = result else { continuation.finish(); throw NativePTYSessionError.launchFailed }
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { Task { await self?.close() } }
        }
    }

    public func write(_ data: Data) async throws {
        guard data.count <= 65_536 else { throw NativePTYSessionError.writeFailed }
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard acceptingInput, process.running else { result.resume(throwing: NativePTYSessionError.notRunning); return }
                guard !writeInFlight else { result.resume(throwing: NativePTYSessionError.inputBusy); return }
                writeInFlight = true
                process.send(data: Array(data)[...]) { [self] response in
                    queue.async { [self] in
                        writeInFlight = false
                        switch response {
                        case .success(let count) where count == data.count: result.resume()
                        default: result.resume(throwing: NativePTYSessionError.writeFailed)
                        }
                    }
                }
            }
        }
    }
    public func resize(cols: Int, rows: Int) async throws {
        guard (1...1_000).contains(cols), (1...500).contains(rows) else { throw NativePTYSessionError.resizeFailed }
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard acceptingInput, process.running else { result.resume(throwing: NativePTYSessionError.notRunning); return }
                var next = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
                guard process.updateWindowSize(&next) else { result.resume(throwing: NativePTYSessionError.resizeFailed); return }
                size = next; result.resume()
            }
        }
    }
    public func hasForegroundCommand() async -> Bool {
        await withCheckedContinuation { result in
            queue.async { [self] in
                let pid = process.shellPid, fd = process.childfd
                let group = fd >= 0 ? tcgetpgrp(fd) : 0
                result.resume(returning: acceptingInput && process.running && pid > 0 && group > 0 && group != pid)
            }
        }
    }
    public func processID() async -> pid_t {
        await withCheckedContinuation { result in queue.async { [self] in result.resume(returning: process.shellPid) } }
    }
    public func close() async {
        let task = closeLock.withLock {
            if let closeTask { return closeTask }
            let task = Task { [self] in await drainOwnedProcess() }; closeTask = task; return task
        }
        await task.value
    }
    private func drainOwnedProcess() async {
        let owned: (pid_t, pid_t) = await withCheckedContinuation { result in
            queue.async { [self] in
                acceptingInput = false
                let pid = process.shellPid, fd = process.childfd, foreground = fd >= 0 ? tcgetpgrp(fd) : 0
                if pid > 0, foreground > 0, foreground != pid, getsid(foreground) == pid { kill(-foreground, SIGHUP) }
                if pid > 0, getpgid(pid) == pid { kill(-pid, SIGHUP) }
                process.terminate()
                result.resume(returning: (pid, foreground))
            }
        }
        if await isDraining() { try? await Task.sleep(for: .seconds(1)) }
        await withCheckedContinuation { (result: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                let (pid, foreground) = owned
                if pid > 0, foreground > 0, foreground != pid, getsid(foreground) == pid { kill(-foreground, SIGKILL) }
                if pid > 0, process.shellPid == pid, process.running {
                    if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
                }
                result.resume()
            }
        }
        while await isDraining() { try? await Task.sleep(for: .milliseconds(10)) }
        await withCheckedContinuation { (result: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if !didExit && !overflowed { continuation.yield(.failed); continuation.finish() }
                result.resume()
            }
        }
    }
    private func isDraining() async -> Bool {
        await withCheckedContinuation { result in
            queue.async { [self] in result.resume(returning: process.running || process.windingDown || writeInFlight) }
        }
    }
    public func getWindowSize() -> winsize { size }
    public func dataReceived(slice: ArraySlice<UInt8>) {
        guard !overflowed else { return }
        if !checkedPostLeaderOutput, process.shellPid == 0, launchedPID > 0 {
            checkedPostLeaderOutput = true
            inheritedOutputMayBeIncomplete = hasRemainingSessionMember()
        }
        var start = slice.startIndex
        while start < slice.endIndex {
            let end = min(start + 16_384, slice.endIndex)
            if case .dropped = continuation.yield(.output(Data(slice[start..<end]))) {
                overflowed = true; acceptingInput = false
                continuation.yield(.outputOverflow); continuation.finish()
                Task { [self] in await close() }
                return
            }
            start = end
        }
    }
    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        acceptingInput = false; didExit = true
        guard !overflowed else { return }
        if inheritedOutputMayBeIncomplete || hasRemainingSessionMember() {
            continuation.yield(.outputOverflow); continuation.finish(); return
        }
        if case .dropped = continuation.yield(.exited(code: exitCode, signal: nil)) {
            continuation.yield(.outputOverflow)
        }
        continuation.finish()
    }
    public func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        acceptingInput = false; didExit = true
        continuation.yield(.failed); continuation.finish()
    }
    /// Observation only: never signal a reparented process based on PID reuse.
    /// Inherited session output is conservatively marked incomplete even when
    /// the finite drain happened to consume its last currently readable byte.
    private func hasRemainingSessionMember() -> Bool {
        guard launchedPID > 0 else { return false }
        let requested = proc_listallpids(nil, 0)
        guard requested > 0 else { return true }
        let capacity = min(65_536, Int(requested) + 32)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count >= 0, Int(count) < capacity else { return true }
        return pids.prefix(Int(count)).contains { $0 > 0 && $0 != launchedPID && getsid($0) == launchedPID }
    }
}
