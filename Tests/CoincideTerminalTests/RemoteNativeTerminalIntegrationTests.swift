import CoincideCore
import CoincideTerminal
import Darwin
import Foundation
import Testing

private func remoteNativeTerminalEventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private remote PTY integration did not reach its expected state.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Production host admission, SQLite and terminal service with the actual
/// headless PTY driver. Only launch policy is replaced by a private non-login
/// Python program; no user shell startup, provider or network is involved.
@Test(.timeLimit(.minutes(1)))
func remoteNativeTerminalServiceOwnsBinaryInputResizeMutationLeaseAndColdNoReplay() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("coincide-remote-native-pty-\(UUID())").resolvingSymlinksInPath()
    try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let workspace = root.appendingPathComponent("workspace"), data = root.appendingPathComponent("host")
    try manager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let program = root.appendingPathComponent("bounded-peer.py")
    try #"""
import fcntl, os, signal, struct, sys, termios, tty
signal.alarm(15)
tty.setraw(0)
with open(os.path.join(sys.argv[1],'owned-pids'),'a') as out:out.write(str(os.getpid())+'\n')
def exact(count):
    data=b''
    while len(data)<count:
        chunk=os.read(0,count-len(data))
        if not chunk:raise AssertionError('Unexpected PTY EOF')
        data+=chunk
    return data
os.write(1,'READY 日本語\n'.encode())
assert exact(4)==b'\x00\xffA\n'
os.write(1,b'ONCE\n')
assert exact(4)==b'EXIT'
rows,cols,_,_=struct.unpack('HHHH',fcntl.ioctl(0,termios.TIOCGWINSZ,b'\0'*8))
assert (rows,cols)==(42,120)
os.write(1,b'RESIZED FINAL\x00\xff\n')
sys.exit(7)
"""#.write(to: program, atomically: false, encoding: .utf8)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: program.path)
    let service = try RemoteEnvironmentService(dataDirectory: data,
        options: .init(codexExecutable: "/usr/bin/true", codexHome: root.appendingPathComponent("codex-home").path),
        providerFactory: { _ in throw CoincideError("This PTY fixture must never start a provider.") },
        driverFactory: { launch in
            try NativePTYSession(directory: URL(fileURLWithPath: launch.directory), executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [program.path, root.path], environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
                cols: launch.cols, rows: launch.rows)
        })
    do {
        let environmentID = service.environmentID, projectID = UUID(), threadID = UUID()
        #expect(await service.descriptor().capabilities.supportsRemoteTerminal)
        #expect(try await service.command(.init(environmentID: environmentID,
            command: .addProject(id: projectID, path: workspace.path, title: nil))).receipt.rejection == nil)
        #expect(try await service.command(.init(environmentID: environmentID, command: .createThread(id: threadID,
            projectID: projectID, provider: .codex, title: "Private PTY", model: "", permission: .supervised))).receipt.rejection == nil)
        let snapshot = try await service.snapshot(.init(environmentID: environmentID))
        let thread = try #require(snapshot.workspace.threads.first)
        let target = try await service.bindWorkspace(.init(environmentID: environmentID, projectID: projectID,
            threadID: threadID, configuration: .init(thread: thread)))
        let open = RemoteTerminalOpenRequest(target: target)
        let terminal = try await service.openTerminal(open), reference = terminal.reference
        try await remoteNativeTerminalEventually {
            let output = try await service.readTerminal(.init(reference: reference))
            return output.snapshot.state == .running && output.data.range(of: Data("READY 日本語\n".utf8)) != nil
        }
        #expect(try await service.openTerminal(open).reference == reference)
        let refused = try await service.beginWorkspaceOperation(.init(target: target, mutation: .createFile(path: "blocked.txt", contents: "not while PTY owns root")))
        #expect(refused.failure?.kind == .busy)
        #expect(!manager.fileExists(atPath: workspace.appendingPathComponent("blocked.txt").path))
        let write = RemoteTerminalInputRequest(reference: reference, sequence: 1, data: Data([0, 255, 65, 10]))
        let receipt = try await service.writeTerminal(write)
        #expect(receipt.state == .delivered)
        #expect(try await service.writeTerminal(write) == receipt)
        #expect(try await service.terminalInputReceipt(.init(reference: reference, sequence: 1,
            digest: RemoteTerminalProtocol.inputDigest(write.data))) == receipt)
        try await remoteNativeTerminalEventually {
            try await service.readTerminal(.init(reference: reference)).data.range(of: Data("ONCE\n".utf8)) != nil
        }
        let resized = try await service.resizeTerminal(.init(reference: reference, cols: 120, rows: 42))
        #expect(resized.cols == 120 && resized.rows == 42)
        #expect(try await service.writeTerminal(.init(reference: reference, sequence: 2, data: Data("EXIT".utf8))).state == .delivered)
        try await remoteNativeTerminalEventually { try await service.attachTerminal(reference).state == .exited }
        let output = try await service.readTerminal(.init(reference: reference))
        #expect(output.snapshot.exitCode == 7)
        let finalBytes = Data("RESIZED FINAL".utf8) + Data([0, 255, 10])
        #expect(output.data.suffix(finalBytes.count) == finalBytes)
        #expect(output.nextSequence == Int64(output.data.count) && !output.gap)
        let closed = try await service.closeTerminal(reference)
        #expect(closed.state == .exited)
        let pids = try String(contentsOf: root.appendingPathComponent("owned-pids"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        #expect(pids.count == 1)
        #expect(pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH })
        let permitted = try await service.beginWorkspaceOperation(.init(target: target, mutation: .createFile(path: "after-close.txt", contents: "allowed")))
        #expect(permitted.failure == nil)
        try await remoteNativeTerminalEventually {
            try await service.workspaceOperation(permitted.request)?.state == .finished
        }
        #expect(try String(contentsOf: workspace.appendingPathComponent("after-close.txt"), encoding: .utf8) == "allowed")
        await service.close()
        let reopened = try RemoteEnvironmentService(dataDirectory: data, expectedEnvironmentID: environmentID,
            providerFactory: { _ in throw CoincideError("No provider after cold restart.") },
            driverFactory: { _ in throw CoincideError("Old terminal identity must never launch again.") })
        do {
            let lost = try await reopened.openTerminal(open)
            #expect(lost.reference == reference && lost.state == .lost && lost.inputHalted)
            let reset = try await reopened.readTerminal(.init(reference: reference, afterSequence: output.nextSequence))
            #expect(reset.gap && reset.data.isEmpty && reset.nextSequence == 0 && reset.snapshot.state == .lost)
            await reopened.close()
        } catch { await reopened.close(); throw error }
        try manager.removeItem(at: root)
    } catch {
        await service.close()
        print("Private remote native PTY fixture retained at \(root.path)")
        throw error
    }
}
