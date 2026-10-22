import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor ProcessShutdownObservation {
    private(set) var finished = false
    func finish() { finished = true }
}

private func processShutdownWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned shutdown fixture did not reach its expected gate.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func ownedProcessAndRPCShutdownWaitForActualNativeExit(rpc: Bool) async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("coincide-process-shutdown-\(UUID())", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: root) }
    let fixture = try #require(Bundle.module.url(forResource: "process_shutdown", withExtension: "py", subdirectory: "Fixtures"))
    let executable = URL(fileURLWithPath: "/usr/bin/python3")
    let stop: @Sendable () async -> Void
    if rpc {
        let connection = try JSONRPCConnection(executable: executable, arguments: [fixture.path, root.path])
        stop = { await connection.close() }
    } else {
        let channel = try ProcessChannel(executable: executable, arguments: [fixture.path, root.path])
        stop = { _ = await channel.stopAndWait() }
    }
    let observation = ProcessShutdownObservation()
    var closer: Task<Void, Never>?
    do {
        try await processShutdownWait {
            guard let text = try? String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8) else { return false }
            return Int32(text) != nil
        }
        let text = try String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try #require(Int32(text))
        closer = Task { await stop(); await observation.finish() }
        try await processShutdownWait { manager.fileExists(atPath: root.appendingPathComponent("terminating").path) }
        closer?.cancel()
        #expect(await observation.finished == false)
        try Data().write(to: root.appendingPathComponent("release"))
        await closer?.value
        #expect(await observation.finished)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        // Repeated closure observes the saved native exit without starting a process.
        await stop()
    } catch {
        try? Data().write(to: root.appendingPathComponent("release"))
        await stop(); await closer?.value
        throw error
    }
}
