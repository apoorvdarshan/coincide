import Darwin
import Foundation
import Testing
@testable import CoincideCore

func nativeCodexRuntimeEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The offline Codex runtime boundary was not observed.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private final class CodexRuntimeWriterGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false, released = false, finished = false
    var didEnter: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    var didClose: Bool { condition.lock(); defer { condition.unlock() }; return finished }
    func payload() -> Data {
        condition.lock(); entered = true; condition.broadcast()
        while !released { condition.wait() }
        condition.unlock(); return Data("A complete owned frame\n".utf8)
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func closed() { condition.lock(); finished = true; condition.unlock() }
}

@Test func codexRuntimeProcessDrainWaitsForAnAlreadyAdmittedNativeWriterAfterChildExit() async throws {
    let channel = try ProcessChannel(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
    let gate = CodexRuntimeWriterGate(), pid = channel.processIdentifier
    let writing = Task { try await channel.writePayload { gate.payload() } }
    var closing: Task<Int32, Never>?
    do {
        try await nativeCodexRuntimeEventually { gate.didEnter }
        let closer = Task { let code = await channel.stopAndDrain(); gate.closed(); return code }; closing = closer
        try await nativeCodexRuntimeEventually { kill(pid, 0) == -1 && errno == ESRCH }
        #expect(!gate.didClose, "A managed binary lease must not end while an admitted native writer is still owned.")
        gate.release()
        await #expect(throws: (any Error).self) { try await writing.value }
        _ = await closer.value
        #expect(gate.didClose && kill(pid, 0) == -1 && errno == ESRCH)
    } catch {
        gate.release(); _ = try? await writing.value; _ = await closing?.value; _ = await channel.stopAndDrain(); throw error
    }
}
