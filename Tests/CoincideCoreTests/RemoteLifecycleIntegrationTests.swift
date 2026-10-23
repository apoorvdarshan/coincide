import Foundation
import Testing
@testable import CoincideCore

@Test(.timeLimit(.minutes(1)))
func remoteLifecycleNativeHelperSnoozeWakeSettleAndResumeKeepFilesDraftsAndProviderIdle() async throws {
    let f = try await RemoteHistoryNativeFixture.make()
    let client = RemoteEnvironmentClient(factory: { try f.connection() }, expectedEnvironmentID: f.environmentID)
    do {
        _ = try await client.connectProjection()
        let target = try await f.target(client), before = try await f.durable()
        let contents = try Data(contentsOf: f.workspace.appendingPathComponent("tracked.txt"))
        let read = try await client.readLifecycle(.init(environmentID: f.environmentID, target: target))
        let capture = try #require(read.thread?.capture), until = Date().addingTimeInterval(3_600)
        let snooze = RemoteEnvironmentCommand.lifecycle(capture: capture, action: .snooze(until: until)), snoozeID = UUID()
        let snoozed = try await client.command(snooze, id: snoozeID).receipt
        #expect(snoozed.commandID == snoozeID && snoozed.rejection == nil)
        #expect(try await client.receipt(for: snooze, id: snoozeID).receipt == snoozed)
        let sleeping = try await client.readLifecycle(.init(environmentID: f.environmentID, target: target))
        #expect(sleeping.thread?.lifecycle?.snoozedUntil == until)
        let wakeCapture = try #require(sleeping.thread?.capture)
        #expect(try await client.command(.lifecycle(capture: wakeCapture, action: .wake)).receipt.rejection == nil)
        let awake = try await client.readLifecycle(.init(environmentID: f.environmentID, target: target))
        #expect(awake.thread?.lifecycle?.snoozedUntil == nil)
        let settleCapture = try #require(awake.thread?.capture), settleID = UUID()
        let settle = RemoteEnvironmentCommand.lifecycle(capture: settleCapture, action: .settleWithoutScript)
        #expect(try await client.command(settle, id: settleID).receipt.rejection == nil)
        let settled = try await client.readLifecycle(.init(environmentID: f.environmentID, target: target))
        #expect(settled.thread?.settlementID == settleID && settled.thread?.settlementPhase == .settled)
        let resumeCapture = try #require(settled.thread?.capture)
        #expect(try await client.command(.lifecycle(capture: resumeCapture, action: .resume(generationID: settleID))).receipt.rejection == nil)
        try await remoteHistoryEventually { try await f.durable().threads.first?.settlement == nil }
        let after = try await f.durable(), original = try #require(before.threads.first), current = try #require(after.threads.first)
        #expect(current.draft == original.draft && current.messages == original.messages && current.queuedTurns == original.queuedTurns)
        #expect(current.activeRun == nil && current.settlement == nil)
        #expect(try Data(contentsOf: f.workspace.appendingPathComponent("tracked.txt")) == contents)
        let codex = try f.rows("codex-wire.jsonl"), claude = try f.rows("claude-wire.jsonl")
        #expect(codex.isEmpty && claude.isEmpty)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteLifecycleNativeLostReplyRecoversOriginalReceiptAfterHostRestartWithoutReplaying() async throws {
    let f = try await RemoteHistoryNativeFixture.make(), id = UUID()
    let factory = LifecycleNativeConnections(fixture: f, droppedID: id)
    let client = RemoteEnvironmentClient(factory: { try factory.make() }, expectedEnvironmentID: f.environmentID)
    do {
        _ = try await client.connectProjection()
        let target = try await f.target(client)
        let read = try await client.readLifecycle(.init(environmentID: f.environmentID, target: target))
        let capture = try #require(read.thread?.capture)
        let command = RemoteEnvironmentCommand.lifecycle(capture: capture, action: .snooze(until: Date().addingTimeInterval(3_600)))
        await #expect(throws: (any Error).self) { try await client.command(command, id: id) }
        _ = try await client.reconnectProjection()
        let recovered = try #require(await client.receipt(for: command, id: id).receipt)
        #expect(recovered.commandID == id && recovered.rejection == nil)
        let before = try await f.durable()
        await #expect(throws: (any Error).self) { try await client.command(command, id: id) }
        let after = try await f.durable()
        #expect(before == after && after.threads.first?.workspaceLifecycle?.snoozedUntil != nil)
        let codex = try f.rows("codex-wire.jsonl"), claude = try f.rows("claude-wire.jsonl")
        #expect(codex.isEmpty && claude.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("lifecycle-dropped-receipt.json").path))
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["configuration", "physicalRoot", "hostClaim"])
func remoteLifecycleNativeStaleScopeProducesDurableRejectionWithoutSendingOrChangingFiles(change: String) async throws {
    let f = try await RemoteHistoryNativeFixture.make()
    let client = RemoteEnvironmentClient(factory: { try f.connection() }, expectedEnvironmentID: f.environmentID)
    do {
        _ = try await client.connectProjection()
        let target = try await f.target(client)
        let read = try await client.readLifecycle(.init(environmentID: f.environmentID, target: target))
        let capture = try #require(read.thread?.capture)
        switch change {
        case "configuration":
            #expect(try await client.command(.editThread(threadID: target.threadID, edit: .model("Changed explicit model"),
                expectedConfiguration: target.configuration)).receipt.rejection == nil)
        case "physicalRoot":
            try FileManager.default.moveItem(at: f.workspace, to: f.root.appendingPathComponent("retained-original-worktree"))
            try FileManager.default.createDirectory(at: f.workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        default: _ = try await client.reconnectProjection()
        }
        let command = RemoteEnvironmentCommand.lifecycle(capture: capture, action: .settleWithoutScript), id = UUID()
        let result = try await client.command(command, id: id)
        #expect(result.receipt.commandID == id && result.receipt.rejection != nil)
        #expect(try await client.receipt(for: command, id: id).receipt == result.receipt)
        let saved = try await f.durable()
        #expect(saved.threads.first?.settlement == nil && saved.threads.first?.activeRun == nil)
        let codex = try f.rows("codex-wire.jsonl"), claude = try f.rows("claude-wire.jsonl")
        #expect(codex.isEmpty && claude.isEmpty)
        if change == "physicalRoot" {
            #expect(try Data(contentsOf: f.root.appendingPathComponent("retained-original-worktree/tracked.txt")) == Data("Current working bytes\n".utf8))
        }
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

private final class LifecycleNativeConnections: @unchecked Sendable {
    let fixture: RemoteHistoryNativeFixture, droppedID: UUID
    private let lock = NSLock()
    private var first = true
    init(fixture: RemoteHistoryNativeFixture, droppedID: UUID) { self.fixture = fixture; self.droppedID = droppedID }
    func make() throws -> JSONRPCConnection {
        try lock.withLock {
            if first {
                first = false
                let peer = try #require(Bundle.module.url(forResource: "remote_lifecycle_proxy", withExtension: "py", subdirectory: "Fixtures"))
                return try .init(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [peer.path, fixture.root.path, droppedID.uuidString, fixture.host.path] + fixture.arguments,
                    cwd: fixture.root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                    environment: fixture.environment, drainProcessOnClose: true)
            }
            return try fixture.connection()
        }
    }
}
