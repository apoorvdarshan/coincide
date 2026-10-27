import Darwin
import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct ProcessTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private let home = FileManager.default.temporaryDirectory

    private func eventually(timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func lineProcess(_ script: String) -> LineProcess {
        LineProcess(executable: shell, arguments: ["-c", script], workingDirectory: home, environment: ["PATH": "/usr/bin:/bin"])
    }

    @Test func linesArriveInOrderAndTheExitComesLast() async throws {
        let process = lineProcess(#"i=0; while [ $i -lt 2000 ]; do echo "line $i"; i=$((i+1)); done; printf 'no newline'"#)
        var lines: [String] = []
        var exit: Int32?
        var linesAtExit = 0
        process.onLine = { lines.append($0) }
        process.onExit = { status, _ in
            exit = status
            linesAtExit = lines.count
        }
        try process.start()
        #expect(await eventually { exit != nil })
        #expect(exit == 0)
        #expect(lines.count == 2001)
        #expect(linesAtExit == 2001)
        #expect(lines.first == "line 0")
        #expect(lines[1999] == "line 1999")
        #expect(lines.last == "no newline")
    }

    @Test func veryLongLinesArriveWhole() async throws {
        let process = lineProcess("head -c 3000000 /dev/zero | tr '\\0' a; echo; echo next")
        var lines: [String] = []
        var exited = false
        process.onLine = { lines.append($0) }
        process.onExit = { _, _ in exited = true }
        try process.start()
        #expect(await eventually { exited })
        #expect(lines.map(\.utf8.count) == [3_000_000, 4])
    }

    @Test func writesDoNotWaitForASlowReader() async throws {
        // The child reads nothing for a second, far longer than a pipe buffer takes to fill.
        let process = lineProcess("sleep 1; cat")
        var lines: [String] = []
        var exited = false
        process.onLine = { lines.append($0) }
        process.onExit = { _, _ in exited = true }
        try process.start()
        let big = String(repeating: "x", count: 2_000_000)
        let started = Date()
        process.write(big)
        process.write("after")
        process.closeInput()
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(await eventually { exited })
        #expect(lines.map(\.utf8.count) == [2_000_000, 5])
    }

    @Test func writingToAProcessThatExitedIsHarmless() async throws {
        let process = lineProcess("exit 3")
        var status: Int32?
        process.onExit = { code, _ in status = code }
        try process.start()
        #expect(await eventually { status != nil })
        process.write(String(repeating: "y", count: 500_000))
        process.closeInput()
        #expect(status == 3)
    }

    @Test func terminateStopsWhatTheProcessStarted() async throws {
        let process = lineProcess("sleep 60 & echo $!; wait")
        var child: pid_t?
        var exited = false
        process.onLine = { child = pid_t($0) }
        process.onExit = { _, _ in exited = true }
        try process.start()
        #expect(await eventually { child != nil })
        let sleeper = try #require(child.flatMap(ProcessTree.identity(of:)))
        #expect(ChildProcesses.shared.trackedProcesses.contains { $0.pid == process.processIdentifier })
        process.terminate()
        #expect(await eventually { exited })
        #expect(await eventually { !ProcessTree.isAlive(sleeper) })
        #expect(!ChildProcesses.shared.trackedProcesses.contains { $0.pid == process.processIdentifier })
    }

    @Test func stderrKeepsCharactersSplitAcrossChunks() {
        let text = "héllo ✓"
        let bytes = Data(text.utf8)
        // Cut inside "✓" (three bytes).
        let (first, carry) = LineProcess.decodeUTF8(bytes.prefix(bytes.count - 1))
        #expect(first == "héllo ")
        #expect(carry.count == 2)
        let (rest, none) = LineProcess.decodeUTF8(carry + bytes.suffix(1))
        #expect(rest == "✓")
        #expect(none.isEmpty)
        #expect(LineProcess.decodeUTF8(Data()).text == "")
    }

    // MARK: Children

    @Test func quittingStopsTrackedProcessesAndWhatTheyStarted() async throws {
        let ledger = home.appendingPathComponent("coincide-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ledger) }
        let children = ChildProcesses(ledger: ledger)
        let process = Process()
        process.executableURL = shell
        // Ignores SIGTERM, so only the kill after the timeout stops it.
        process.arguments = ["-c", "trap '' TERM; sleep 60 & wait"]
        try process.run()
        children.track(process.processIdentifier)
        let root = try #require(ProcessTree.identity(of: process.processIdentifier))
        #expect(await eventually { !ProcessTree.descendants(of: root.pid).isEmpty })
        let sleeper = try #require(ProcessTree.descendants(of: root.pid).first)
        #expect(FileManager.default.fileExists(atPath: ledger.appendingPathComponent("\(root.pid).json").path))
        let started = Date()
        children.terminateAllAndWait(timeout: 0.5)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(await eventually { !ProcessTree.isAlive(root) && !ProcessTree.isAlive(sleeper) })
        #expect(children.trackedProcesses.isEmpty)
    }

    @Test func aLaunchAfterACrashStopsTheChildrenItLeftBehind() async throws {
        let ledger = home.appendingPathComponent("coincide-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ledger) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        let orphan = try #require(ProcessTree.identity(of: process.processIdentifier))
        let live = ProcessTree.identity(of: getpid())!
        func entry(owner: ProcessIdentity) -> Data {
            Data(
                #"{"process":{"pid":\#(orphan.pid),"startTime":\#(orphan.startTime)},"owner":{"pid":\#(owner.pid),"startTime":\#(owner.startTime)}}"#
                    .utf8)
        }
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        let file = ledger.appendingPathComponent("\(orphan.pid).json")

        // A child of a Coincide that is still running is left alone.
        try entry(owner: live).write(to: file)
        ChildProcesses(ledger: ledger).sweepOrphans()
        #expect(ProcessTree.isAlive(orphan))

        // One whose owner is gone (the pid now belongs to another process, or none) is stopped.
        try entry(owner: ProcessIdentity(pid: live.pid, startTime: live.startTime - 1)).write(to: file)
        ChildProcesses(ledger: ledger).sweepOrphans()
        #expect(await eventually { !process.isRunning })
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Running commands

    @Test func aCommandThatIgnoresTheTimeoutIsKilled() async {
        let started = Date()
        let result = await ProcessRunner.run(shell, ["-c", "trap '' TERM; echo begun; sleep 30"], timeout: 0.3)
        #expect(Date().timeIntervalSince(started) < 8)
        #expect(result.stdout == "begun\n")
        #expect(result.stderr.contains("The command timed out."))
        #expect(!result.succeeded)
    }

    @Test func aHelperHoldingTheOutputIsNotWaitedOn() async {
        let started = Date()
        let result = await ProcessRunner.run(shell, ["-c", "(sleep 6 &); echo done"], timeout: 20)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(result.stdout == "done\n")
        #expect(result.succeeded)
    }

    @Test func inputIsWrittenWithoutBlocking() async {
        let input = String(repeating: "z", count: 1_000_000) + "\n"
        let result = await ProcessRunner.run(shell, ["-c", "sleep 0.5; wc -c"], timeout: 20, input: input)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1000001")
    }
}
