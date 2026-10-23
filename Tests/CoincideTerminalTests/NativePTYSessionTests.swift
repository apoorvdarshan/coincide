import CoincideCore
import CoincideTerminal
import Darwin
import Foundation
import Testing

private actor NativePTYCapture {
    private(set) var bytes = Data()
    private(set) var events: [RemotePTYEvent] = []
    func append(_ event: RemotePTYEvent) {
        events.append(event)
        if case .output(let data) = event { bytes.append(data) }
    }
    func contains(_ data: Data) -> Bool { bytes.range(of: data) != nil }
    var ended: Bool { events.contains { if case .exited = $0 { true } else { false } } }
}
private actor NativePTYDrainCapture {
    private(set) var incomplete = false
    private(set) var outputBytes = 0
    func append(_ event: RemotePTYEvent) {
        switch event {
        case .output(let bytes): outputBytes += bytes.count
        case .outputOverflow, .failed: incomplete = true
        case .exited: break
        }
    }
}
private struct NativePTYFixture: Sendable {
    let root: URL, script: URL
    init(_ source: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-pty-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        script = root.appendingPathComponent("bounded-peer.py")
        try source.write(to: script, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
    }
    func session(buffer: Int = 64) throws -> NativePTYSession {
        try .init(directory: root, executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script.path, root.path, "literal ' $(never-executed)"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "NATIVE_PTY_PRIVATE": "literal ' $(never-executed)"],
            cols: 80, rows: 24, maximumBufferedEvents: buffer)
    }
    func remove() throws { try FileManager.default.removeItem(at: root) }
    func retainFailure() { print("Private native PTY fixture retained at \(root.path)") }
}
private func nativePTYEventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned headless PTY did not reach its bounded fixture boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1)))
func nativeHeadlessPTYExchangesExactBinaryUsesWorkspaceResizesAndDrainsFinalExit() async throws {
    let fixture = try NativePTYFixture(#"""
import fcntl, os, signal, struct, sys, termios, tty
signal.alarm(15)
assert all(os.isatty(fd) for fd in (0,1,2))
assert os.path.samefile(os.getcwd(),sys.argv[1])
assert sys.argv[2] == os.environ['NATIVE_PTY_PRIVATE'] == "literal ' $(never-executed)"
assert os.environ['HOME'] == sys.argv[1]
tty.setraw(0)
def exact(count):
    value=b''
    while len(value)<count:
        chunk=os.read(0,count-len(value))
        if not chunk: raise AssertionError('Unexpected input EOF')
        value+=chunk
    return value
os.write(1,('PTY_READY:'+os.getcwd()+'\nUNICODE=日本語🌍\n').encode()+b'BINARY=\x00\xff\x80\x1b\n')
value=exact(4)
os.write(1,b'INPUT='+value+b'\n')
assert exact(1)==b'R'
rows,cols,_,_=struct.unpack('HHHH',fcntl.ioctl(0,termios.TIOCGWINSZ,b'\0'*8))
os.write(1,('SIZE=%d,%d\n'%(rows,cols)).encode())
assert exact(1)==b'X'
os.write(1,b'FINAL_BYTES=\x00\xff\n')
sys.exit(7)
"""#)
    let session = try fixture.session(), capture = NativePTYCapture()
    let reader = Task { for await event in session.events { await capture.append(event) } }
    do {
        let pid = await session.processID(); #expect(pid > 0)
        try await nativePTYEventually { await capture.contains(Data("PTY_READY:".utf8)) }
        let input = Data([0, 255, 65, 10])
        try await session.write(input)
        try await nativePTYEventually { await capture.contains(Data("INPUT=".utf8) + input + Data([10])) }
        try await session.resize(cols: 132, rows: 43)
        try await session.write(Data("R".utf8))
        try await nativePTYEventually { await capture.contains(Data("SIZE=43,132\n".utf8)) }
        try await session.write(Data("X".utf8))
        try await nativePTYEventually { await capture.ended }
        await session.close(); await reader.value
        let bytes = await capture.bytes, events = await capture.events
        #expect(bytes.range(of: Data("UNICODE=日本語🌍\n".utf8)) != nil)
        #expect(bytes.range(of: Data("BINARY=".utf8) + Data([0,255,128,27,10])) != nil)
        #expect(bytes.suffix(15) == Data("FINAL_BYTES=".utf8) + Data([0,255,10]))
        #expect(events.last == .exited(code: 7, signal: nil))
        #expect(!events.contains(.outputOverflow) && !events.contains(.failed))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        await #expect(throws: NativePTYSessionError.notRunning) { try await session.write(Data([1])) }
        try fixture.remove()
    } catch { await session.close(); await reader.value; fixture.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func nativeHeadlessPTYCloseEscalatesAndJoinsItsOwnedShellAndForegroundGroup() async throws {
    let fixture = try NativePTYFixture(#"""
import json, os, signal, sys, time, tty
tty.setraw(0)
for value in (signal.SIGHUP,signal.SIGTERM,signal.SIGTTOU): signal.signal(value,signal.SIG_IGN)
child=os.fork()
if child==0:
    os.setpgid(0,0)
    time.sleep(12)
    sys.exit(0)
os.setpgid(child,child)
os.tcsetpgrp(0,child)
with open(os.path.join(sys.argv[1],'owned-pids.json'),'w') as out:json.dump([os.getpid(),child],out)
os.write(1,b'FOREGROUND_READY\n')
time.sleep(12)
"""#)
    let session = try fixture.session(), capture = NativePTYCapture()
    let reader = Task { for await event in session.events { await capture.append(event) } }
    do {
        try await nativePTYEventually { await capture.contains(Data("FOREGROUND_READY\n".utf8)) }
        #expect(await session.hasForegroundCommand())
        let pids = try JSONDecoder().decode([Int32].self, from: Data(contentsOf: fixture.root.appendingPathComponent("owned-pids.json")))
        #expect(pids.count == 2 && pids.allSatisfy { $0 > 0 })
        await session.close(); await session.close(); await reader.value
        try await nativePTYEventually { pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        #expect(await !session.hasForegroundCommand())
        #expect(await capture.events.last == .exited(code: nil, signal: nil))
        try fixture.remove()
    } catch { await session.close(); await reader.value; fixture.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func nativeHeadlessPTYBoundedOutputOverflowIsExplicitAndClosesWithoutAnUnboundedQueue() async throws {
    let fixture = try NativePTYFixture(#"""
import os, signal, time, tty
signal.alarm(15)
tty.setraw(0)
open(os.path.join(os.environ['HOME'],'ready'),'w').close()
assert os.read(0,1)==b'G'
for _ in range(256):os.write(1,b'x'*16384)
time.sleep(10)
"""#)
    let session = try fixture.session(buffer: 2)
    do {
        let pid = await session.processID(); #expect(pid > 0)
        // No reader is attached until after the bounded queue must overflow.
        // The private readiness marker is written after raw mode is active.
        try await nativePTYEventually { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("ready").path) }
        try await session.write(Data("G".utf8))
        try await nativePTYEventually { kill(pid, 0) == -1 && errno == ESRCH }
        await session.close()
        var events: [RemotePTYEvent] = []
        for await event in session.events { events.append(event) }
        #expect(events.contains(.outputOverflow))
        #expect(events.count <= 2)
        let output = events.reduce(0) { count, event in if case .output(let bytes) = event { count + bytes.count } else { count } }
        #expect(output <= 32_768)
        try fixture.remove()
    } catch { await session.close(); fixture.retainFailure(); throw error }
}

@Test func nativeHeadlessPTYRejectsInvalidLaunchBeforeStartingAnyChild() throws {
    let missing = URL(fileURLWithPath: "/does-not-exist/coincide-native-pty-\(UUID())")
    #expect(throws: NativePTYSessionError.invalidLaunch) {
        try NativePTYSession(directory: missing, executable: URL(fileURLWithPath: "/bin/sh"), arguments: [], environment: [:])
    }
    #expect(throws: NativePTYSessionError.invalidLaunch) {
        try NativePTYSession(directory: FileManager.default.temporaryDirectory, executable: missing, arguments: [], environment: [:])
    }
    #expect(throws: NativePTYSessionError.invalidLaunch) {
        try NativePTYSession(directory: FileManager.default.temporaryDirectory, executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [], environment: [:], cols: 0)
    }
}

@Test(.timeLimit(.minutes(1)))
func nativeHeadlessPTYInheritedWriterHasBoundedDrainAndExplicitSessionUncertainty() async throws {
    let fixture = try NativePTYFixture(#"""
import json, os, signal, sys, time, tty
signal.alarm(10)
tty.setraw(0)
signal.signal(signal.SIGHUP,signal.SIG_IGN)
child=os.fork()
if child==0:
    gate=os.path.join(sys.argv[1],'start-child')
    end=time.monotonic()+6
    while not os.path.exists(gate) and time.monotonic()<end:time.sleep(.001)
    with open(os.path.join(sys.argv[1],'child-ready'),'w') as out:out.write('ready')
    try:
        # Small continuous writes keep a bounded drain active without flooding
        # the driver's event queue before the parent can retire its leader.
        while time.monotonic()<end:os.write(1,b'x')
    except OSError:
        # Darwin can revoke the slave as soon as the leader exits. Keep this
        # independently bounded member observable even when writes get EIO;
        # that is session uncertainty, not evidence of a timed-out byte drain.
        while time.monotonic()<end:time.sleep(.01)
    os._exit(0)
with open(os.path.join(sys.argv[1],'owned-pids.json'),'w') as out:json.dump([os.getpid(),child],out)
assert os.read(0,1)==b'G'
open(os.path.join(sys.argv[1],'start-child'),'w').close()
while not os.path.exists(os.path.join(sys.argv[1],'child-ready')):time.sleep(.001)
os._exit(0)
"""#)
    let session = try fixture.session(buffer: 256), capture = NativePTYDrainCapture()
    let reader = Task { for await event in session.events { await capture.append(event) } }
    do {
        try await nativePTYEventually { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("owned-pids.json").path) }
        let pids = try JSONDecoder().decode([Int32].self, from: Data(contentsOf: fixture.root.appendingPathComponent("owned-pids.json")))
        let leader = await session.processID()
        #expect(pids.count == 2 && pids.first == leader)
        let started = ContinuousClock.now
        try await session.write(Data("G".utf8))
        await reader.value; await session.close()
        #expect(started.duration(to: ContinuousClock.now) < .seconds(3), "Inherited session lifetime must not extend the PTY drain until its six-second fixture deadline.")
        #expect(await capture.incomplete)
        #expect(await capture.outputBytes > 0)
        // This test-created descendant is bounded independently. No claim is
        // made that arbitrary reparented descendants can safely be signalled.
        try await nativePTYEventually { pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        try fixture.remove()
    } catch { await session.close(); await reader.value; fixture.retainFailure(); throw error }
}
