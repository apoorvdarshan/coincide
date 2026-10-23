import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor CommandDrainCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}
private func commandDrainWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private command drain boundary was not reached.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["limit", "timeout", "cancel", "input-error"])
func commandRunnerDoesNotReturnUntilItsExactChildAndReadersDrain(mode: String) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("private-command-peer.py")
    let pidFile = root.appendingPathComponent("pid"), terminating = root.appendingPathComponent("terminating")
    let release = root.appendingPathComponent("release")
    try #"""
    import os, pathlib, signal, sys, time
    root = pathlib.Path(sys.argv[1])
    mode = sys.argv[2]
    def stopping(*_):
        (root / "terminating").write_text("received")
    signal.signal(signal.SIGTERM, stopping)
    pending_pid = root / "pid.pending"
    pending_pid.write_text(str(os.getpid()))
    pending_pid.replace(root / "pid")
    if mode == "input-error":
        os.close(0)
    if mode == "limit":
        os.write(1, b"x" * 4096)
    while not (root / "release").exists():
        time.sleep(0.01)
    os.write(1, b"final-owned-output\n")
    """#.write(to: script, atomically: true, encoding: .utf8)
    let completion = CommandDrainCompletion()
    let input = mode == "input-error" ? Data(repeating: 120, count: 8_388_608) : nil
    let task = Task { () -> Result<CommandResult, any Error> in
        let result: Result<CommandResult, any Error>
        do {
            result = .success(try await CommandRunner.run("/usr/bin/python3", [script.path, root.path, mode],
                input: input, limit: 1_024, timeout: mode == "timeout" ? .seconds(1) : .seconds(20),
                environment: ["PATH": "/usr/bin:/bin"]))
        } catch { result = .failure(error) }
        await completion.finish()
        return result
    }
    do {
        try await commandDrainWait { FileManager.default.fileExists(atPath: pidFile.path) }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(Int32(pidText))
        if mode == "cancel" { task.cancel() }
        try await commandDrainWait { FileManager.default.fileExists(atPath: terminating.path) }
        #expect(await completion.finished == false, "A TERM request is not an owned-child drain receipt.")
        try Data().write(to: release)
        let result = await task.value
        switch result {
        case .success: Issue.record("The stopped command unexpectedly succeeded.")
        case .failure(let error):
            if mode == "cancel" { #expect(error is CancellationError) }
            if mode == "limit" { #expect(error.localizedDescription == "Command output exceeded the limit.") }
            if mode == "timeout" { #expect(error.localizedDescription == "Command timed out.") }
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    } catch {
        try? Data().write(to: release)
        task.cancel(); _ = await task.value
        throw error
    }
}
