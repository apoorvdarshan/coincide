import Darwin
import Foundation
import Testing
@testable import CoincideCore

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func boundedOwnedProcessOutputFailsInsteadOfLosingBytesOrKeepingAFloodingChildAlive(stderr: Bool) async throws {
    let script = "import os\nwhile True: os.write(\(stderr ? 2 : 1), b'x' * 65536)\n"
    let channel = try ProcessChannel(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], eventBufferLimit: 1)
    let pid = channel.processIdentifier
    do {
        let deadline = ContinuousClock.now + .seconds(8)
        while !channel.outputOverflowed {
            guard ContinuousClock.now < deadline else { throw CoincideError("The bounded process fixture did not report overflow.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = await channel.stopAndWait()
        #expect(pid > 0 && kill(pid, 0) == -1 && errno == ESRCH)
        var retainedEvents = 0, retainedBytes = 0
        for await event in channel.events {
            retainedEvents += 1
            switch event { case .stdout(let data), .stderr(let data): retainedBytes += data.count; case .exited: break }
        }
        #expect(retainedEvents <= 1 && retainedBytes <= 65_536)
        #expect(channel.outputOverflowed)
    } catch { _ = await channel.stopAndWait(); throw error }
}

@Test(.timeLimit(.minutes(1))) func boundedOwnedProcessStillDeliversNormalOutputAndExitAndRejectsInvalidLimits() async throws {
    for limit in [0, 513] {
        #expect(throws: CoincideError.self) {
            try ProcessChannel(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], eventBufferLimit: limit)
        }
    }
    let channel = try ProcessChannel(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                     arguments: ["-c", "import os; os.write(1,b'bounded output')"], eventBufferLimit: 2)
    var output = Data(), status: Int32?
    for await event in channel.events {
        switch event { case .stdout(let data): output.append(data); case .exited(let result): status = result; case .stderr: break }
    }
    #expect(output == Data("bounded output".utf8) && status == 0)
    #expect(!channel.outputOverflowed)
    _ = await channel.stopAndWait()
}

@Test(.timeLimit(.minutes(1))) func ownedProcessCanCloseItsPipeReadersWithoutKillingADescendantHoldingTheWriters() async throws {
    let root = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let pidFile = root.appendingPathComponent("descendant.pid"), release = root.appendingPathComponent("release")
    let script = """
    import os, sys, time
    descendant = os.fork()
    if descendant == 0:
        with open(sys.argv[1], 'w') as file: file.write(str(os.getpid()))
        while not os.path.exists(sys.argv[2]): time.sleep(.01)
        os._exit(0)
    sys.stdin.buffer.read()
    os._exit(0)
    """
    let channel = try ProcessChannel(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                     arguments: ["-c", script, pidFile.path, release.path])
    var descendant: Int32?
    do {
        let deadline = ContinuousClock.now + .seconds(8)
        while descendant == nil {
            if let value = try? String(contentsOf: pidFile, encoding: .utf8) { descendant = Int32(value) }
            guard ContinuousClock.now < deadline else { throw CoincideError("The inherited-pipe fixture did not start.") }
            if descendant == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        let pid = try #require(descendant)
        defer { if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) } }
        #expect(kill(pid, 0) == 0)
        _ = await channel.stopAndDrain()
        #expect(kill(channel.processIdentifier, 0) == -1 && errno == ESRCH)
        // This return proves both parent-side read workers joined even though
        // the unrelated descendant still owns pipe writers and remains alive.
        #expect(kill(pid, 0) == 0)
        try Data().write(to: release)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    } catch {
        try? Data().write(to: release)
        _ = await channel.stopAndDrain()
        if let descendant { _ = kill(descendant, SIGKILL) }
        throw error
    }
}
