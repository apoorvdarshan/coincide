import Foundation
import Testing
@testable import CoincideCore

private actor RemoteTerminalMockDriver: RemotePTYDriver {
    nonisolated let events: AsyncStream<RemotePTYEvent>
    private let continuation: AsyncStream<RemotePTYEvent>.Continuation
    private var values: [Data] = []
    private var failedWrites = false
    private var holdingClose = false
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private(set) var closeStarted = false
    private(set) var resizeCount = 0
    init() { (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(8)) }
    func write(_ data: Data) async throws {
        values.append(data)
        if failedWrites { throw RemoteTerminalFailure(.unavailable) }
    }
    func resize(cols: Int, rows: Int) async throws { resizeCount += 1 }
    func hasForegroundCommand() -> Bool { true }
    func close() async {
        if let closeTask { await closeTask.value; return }
        let task = Task { await self.finishClose() }; closeTask = task; await task.value
    }
    private func finishClose() async {
        closeStarted = true
        if holdingClose { await withCheckedContinuation { closeWaiter = $0 } }
        continuation.yield(.exited(code: 0, signal: nil)); continuation.finish()
    }
    func emit(_ event: RemotePTYEvent) { continuation.yield(event) }
    func failWrites() { failedWrites = true }
    func holdClose() { holdingClose = true }
    func releaseClose() { holdingClose = false; closeWaiter?.resume(); closeWaiter = nil }
    var writes: [Data] { values }
}
private actor RemoteTerminalMockFactory {
    private(set) var drivers: [RemoteTerminalMockDriver] = []
    func make(_ launch: RemotePTYLaunch) -> any RemotePTYDriver {
        let driver = RemoteTerminalMockDriver(); drivers.append(driver); return driver
    }
    var count: Int { drivers.count }
}
private struct RemoteTerminalCoreFixture {
    let root: URL, data: URL
    let service: RemoteEnvironmentService
    let target: RemoteWorkspaceTarget
    let factory: RemoteTerminalMockFactory
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-terminal-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let workspace = root.appendingPathComponent("Workspace"), data = root.appendingPathComponent("Host")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let factory = RemoteTerminalMockFactory()
        let service = try RemoteEnvironmentService(dataDirectory: data,
            options: .init(codexExecutable: "/usr/bin/true", codexHome: root.appendingPathComponent("NativeHome").path),
            providerFactory: { _ in throw CoincideError("This terminal fixture must not start a provider.") },
            driverFactory: { await factory.make($0) })
        do {
            let projectID = UUID(), threadID = UUID(), id = service.environmentID
            _ = try await service.command(.init(environmentID: id, command: .addProject(id: projectID, path: workspace.path, title: nil)))
            _ = try await service.command(.init(environmentID: id, command: .createThread(id: threadID, projectID: projectID, provider: .codex, title: "Terminal fixture", model: "", permission: .supervised)))
            let thread = try #require(try await service.snapshot(.init(environmentID: id)).workspace.threads.first)
            let target = try await service.bindWorkspace(.init(environmentID: id, projectID: projectID, threadID: threadID, configuration: .init(thread: thread)))
            return .init(root: root, data: data, service: service, target: target, factory: factory)
        } catch { await service.close(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func close() async { await service.close(); try? FileManager.default.removeItem(at: root) }
    func running(_ reference: RemoteTerminalReference) async throws -> RemoteTerminalSnapshot {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let value = try await service.attachTerminal(reference)
            if value.state == .running { return value }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw CoincideError("The mock terminal did not start.")
    }
}

@Test func remoteTerminalExplicitOpenIsIdempotentAndReadonlyRecoveryNeverSpawns() async throws {
    let fixture = try await RemoteTerminalCoreFixture.make()
    do {
        #expect(await fixture.service.descriptor().capabilities.supportsRemoteTerminal)
        let unknown = RemoteTerminalReference(target: fixture.target, terminalID: UUID(), incarnation: UUID())
        await #expect(throws: RemoteTerminalFailure(.notFound)) { try await fixture.service.attachTerminal(unknown) }
        #expect(await fixture.factory.count == 0)
        let request = RemoteTerminalOpenRequest(target: fixture.target)
        let opened = try await fixture.service.openTerminal(request)
        _ = try await fixture.running(opened.reference)
        #expect(try await fixture.service.openTerminal(request).reference == opened.reference)
        #expect(await fixture.factory.count == 1)
        let changed = RemoteTerminalOpenRequest(id: request.id, target: fixture.target, terminalID: request.terminalID, cols: 91, rows: 24)
        await #expect(throws: RemoteTerminalFailure(.openCollision)) { try await fixture.service.openTerminal(changed) }
        let stale = RemoteTerminalReference(target: fixture.target, terminalID: request.terminalID, incarnation: UUID())
        await #expect(throws: RemoteTerminalFailure(.staleIncarnation)) { try await fixture.service.attachTerminal(stale) }
        await fixture.service.close()
        let probe = RemoteTerminalMockFactory()
        let reopened = try RemoteEnvironmentService(dataDirectory: fixture.data, expectedEnvironmentID: fixture.target.environmentID,
            driverFactory: { await probe.make($0) })
        do {
            let lost = try await reopened.attachTerminal(opened.reference)
            #expect(lost.state == .lost && lost.inputHalted && lost.exitCode == nil && lost.exitSignal == nil)
            let read = try await reopened.readTerminal(.init(reference: opened.reference, afterSequence: 99_999))
            #expect(read.gap && read.data.isEmpty && read.startSequence == 0 && read.nextSequence == 0)
            #expect(try await reopened.openTerminal(request).state == .lost)
            #expect(await probe.count == 0)
            await reopened.close()
        } catch { await reopened.close(); throw error }
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@Test func remoteTerminalBinaryRingHasExplicitGapAndResizePinsExactIncarnation() async throws {
    let fixture = try await RemoteTerminalCoreFixture.make()
    do {
        let opened = try await fixture.service.openTerminal(.init(target: fixture.target))
        _ = try await fixture.running(opened.reference)
        let driver = try #require(await fixture.factory.drivers.first)
        let bytes = Data((0..<600_000).map { UInt8($0 % 256) })
        await driver.emit(.output(bytes))
        let deadline = ContinuousClock.now + .seconds(3)
        while try await fixture.service.attachTerminal(opened.reference).outputSequence < Int64(bytes.count) {
            guard ContinuousClock.now < deadline else { throw CoincideError("The terminal ring did not receive bytes.") }
            try await Task.sleep(for: .milliseconds(2))
        }
        let value = try await fixture.service.readTerminal(.init(reference: opened.reference, maxBytes: 65_536))
        #expect(value.gap && value.startSequence == Int64(bytes.count - RemoteTerminalProtocol.maximumOutputBytes))
        #expect(value.data == bytes.suffix(RemoteTerminalProtocol.maximumOutputBytes).prefix(65_536))
        #expect(value.nextSequence == value.startSequence + Int64(value.data.count))
        let resized = try await fixture.service.resizeTerminal(.init(reference: opened.reference, cols: 101, rows: 33))
        #expect(resized.cols == 101 && resized.rows == 33 && resized.hasForegroundCommand)
        #expect(await driver.resizeCount == 1)
        let denied = try await fixture.service.beginWorkspaceOperation(.init(target: fixture.target, mutation: .createFile(path: "blocked-by-pty", contents: "no")))
        #expect(denied.state == .finished && denied.failure?.kind == .busy)
        let stopped = try await fixture.service.closeTerminal(opened.reference)
        #expect(stopped.state == .exited && stopped.exitCode == 0)
        let allowed = try await fixture.service.beginWorkspaceOperation(.init(target: fixture.target, mutation: .createFile(path: "after-pty", contents: "yes")))
        #expect(allowed.failure == nil)
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@Test func remoteWorktreePreparationRefusesLiveTerminalUntilItsOwnedDriverDrains() async throws {
    let fixture = try await RemoteTerminalCoreFixture.make()
    do {
        let opened = try await fixture.service.openTerminal(.init(target: fixture.target))
        _ = try await fixture.running(opened.reference)
        let driver = try #require(await fixture.factory.drivers.first)
        let command = RemoteEnvironmentCommand.prepareWorktree(target: fixture.target,
            sourceRootID: try #require(fixture.target.rootID), expectedAttemptID: nil,
            selection: .createBranch(name: "private-worktree", baseRef: "HEAD"), submodules: .none)
        let refused = RemoteEnvironmentCommandRequest(environmentID: fixture.target.environmentID, command: command)
        let result = try await fixture.service.command(refused)
        #expect(result.receipt.rejection != nil)
        #expect(try await fixture.service.snapshot(.init(environmentID: fixture.target.environmentID))
            .workspace.threads.first?.workspacePreparation == nil)
        await driver.holdClose()
        let closing = Task { try await fixture.service.closeTerminal(opened.reference) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await driver.closeStarted) {
            guard ContinuousClock.now < deadline else { await driver.releaseClose(); throw CoincideError("The owned terminal did not begin closing.") }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(try await fixture.service.command(.init(environmentID: fixture.target.environmentID, command: command)).receipt.rejection != nil)
        await driver.releaseClose(); _ = try await closing.value
        #expect(try await fixture.service.command(refused).receipt == result.receipt)
        // A new explicit identity is admitted after drain. This fixture is not
        // a Git repository, so only admission is asserted, never Git success.
        #expect(try await fixture.service.command(.init(environmentID: fixture.target.environmentID, command: command)).receipt.rejection == nil)
        await fixture.close()
    } catch {
        if let driver = await fixture.factory.drivers.first { await driver.releaseClose() }
        await fixture.close(); throw error
    }
}

@Test func remoteTerminalInputReceiptsRollWithoutRepeatingBytesOrPersistingRawKeystrokes() async throws {
    let fixture = try await RemoteTerminalCoreFixture.make()
    do {
        let opened = try await fixture.service.openTerminal(.init(target: fixture.target))
        _ = try await fixture.running(opened.reference)
        let driver = try #require(await fixture.factory.drivers.first)
        let bytes = Data("private keyboard fixture Ω".utf8)
        var digest = ""
        for sequence in 1...70 {
            let receipt = try await fixture.service.writeTerminal(.init(reference: opened.reference, sequence: Int64(sequence), data: bytes))
            digest = RemoteTerminalProtocol.chainedInputDigest(previous: digest, sequence: Int64(sequence), digest: RemoteTerminalProtocol.inputDigest(bytes))
            #expect(receipt.state == .delivered && receipt.inputDigest == digest)
        }
        let repeated = try await fixture.service.writeTerminal(.init(reference: opened.reference, sequence: 70, data: bytes))
        let writes = await driver.writes
        #expect(repeated.state == .delivered && writes.count == 70)
        await #expect(throws: RemoteTerminalFailure(.inputExpired)) {
            try await fixture.service.writeTerminal(.init(reference: opened.reference, sequence: 1, data: bytes))
        }
        await #expect(throws: RemoteTerminalFailure(.inputCollision)) {
            try await fixture.service.writeTerminal(.init(reference: opened.reference, sequence: 70, data: Data("different".utf8)))
        }
        await driver.failWrites()
        let uncertain = try await fixture.service.writeTerminal(.init(reference: opened.reference, sequence: 71, data: bytes))
        #expect(uncertain.state == .uncertain)
        await #expect(throws: RemoteTerminalFailure(.inputUncertain)) {
            try await fixture.service.writeTerminal(.init(reference: opened.reference, sequence: 72, data: bytes))
        }
        #expect(try await fixture.service.terminalInputReceipt(.init(reference: opened.reference, sequence: 71, digest: uncertain.digest)) == uncertain)
        _ = try await fixture.service.closeTerminal(opened.reference)
        let saved = try Data(contentsOf: fixture.data.appendingPathComponent("remote-terminal-identities.json"))
        #expect(saved.range(of: bytes) == nil && saved.range(of: Data(digest.utf8)) == nil)
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@Test func remoteTerminalOverflowDuringOwnedClosePreservesFailureAndAwaitsDriverDrain() async throws {
    let fixture = try await RemoteTerminalCoreFixture.make()
    do {
        let opened = try await fixture.service.openTerminal(.init(target: fixture.target))
        _ = try await fixture.running(opened.reference)
        let driver = try #require(await fixture.factory.drivers.first)
        await driver.holdClose()
        let closing = Task { try await fixture.service.closeTerminal(opened.reference) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await driver.closeStarted) {
            guard ContinuousClock.now < deadline else { await driver.releaseClose(); throw CoincideError("Close did not reach the owned driver.") }
            try await Task.sleep(for: .milliseconds(2))
        }
        await driver.emit(.outputOverflow)
        // Polling observes the closing incarnation while the driver still owns it.
        #expect(try await fixture.service.attachTerminal(opened.reference).state == .closing)
        await driver.releaseClose()
        let result = try await closing.value
        #expect(result.state == .failed && result.exitCode == nil && result.exitSignal == nil)
        await fixture.close()
    } catch { await fixture.close(); throw error }
}
