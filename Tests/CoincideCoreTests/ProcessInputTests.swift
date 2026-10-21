import Foundation
import Testing
@testable import CoincideCore

private actor InputTestGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if opened { return }; await withCheckedContinuation { continuation = $0 } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@Test(.timeLimit(.minutes(1))) func largeStdinDoesNotBlockTimeoutOrCancellation() async throws {
    let data = Data(repeating: 65, count: 8 * 1_024 * 1_024)
    for cancel in [false, true] {
        let started = ContinuousClock.now
        let task = Task {
            try await CommandRunner.run("/usr/bin/python3", ["-c", "import time; time.sleep(2)"], input: data,
                                        timeout: cancel ? .seconds(30) : .milliseconds(100))
        }
        if cancel { try await Task.sleep(for: .milliseconds(100)); task.cancel() }
        do { _ = try await task.value; Issue.record("A blocked-input command unexpectedly succeeded") }
        catch { /* A timeout or cancellation must release the caller promptly. */ }
        #expect(started.duration(to: .now) < .seconds(1))
    }
}

@Test(.timeLimit(.minutes(1))) func concurrentProcessWritesStayWholeAndCancelledUnstartedWritesDoNotCloseInput() async throws {
    let channel = try ProcessChannel(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import sys,time; time.sleep(.2); sys.stdout.buffer.write(sys.stdin.buffer.read())"])
    defer { channel.stop() }
    let a = Data(repeating: 65, count: 262_144), b = Data(repeating: 66, count: 262_144)
    let output = Task {
        var bytes = Data()
        for await event in channel.events {
            if case .stdout(let value) = event { bytes.append(value) }
            if case .exited(let status) = event { #expect(status == 0); return bytes }
        }
        throw CoincideError("The input echo peer did not exit")
    }
    async let first: Void = channel.write(a)
    async let second: Void = channel.write(b)
    let gate = InputTestGate()
    let cancelled = Task { await gate.wait(); try await channel.write(Data("discard".utf8)) }
    cancelled.cancel(); await gate.open()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try await first; try await second
    channel.finishInput()
    let received = try await output.value
    #expect(received == a + b || received == b + a)
}

@Test(.timeLimit(.minutes(1))) func rpcTimeoutAndCloseStayResponsiveDuringABlockedLargeWrite() async throws {
    for close in [false, true] {
        let rpc = try JSONRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import time; time.sleep(2)"])
        let started = ContinuousClock.now
        let request = Task { try await rpc.request("large", params: .string(String(repeating: "x", count: 8 * 1_024 * 1_024)), timeout: close ? .seconds(30) : .milliseconds(100)) }
        if close { try await Task.sleep(for: .milliseconds(100)); await rpc.close() }
        do { _ = try await request.value; Issue.record("The blocked RPC unexpectedly succeeded") }
        catch { /* Both paths must cancel input and release the waiter. */ }
        #expect(started.duration(to: .now) < .seconds(1))
        await rpc.close()
    }
}
