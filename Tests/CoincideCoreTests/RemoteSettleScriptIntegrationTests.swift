import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Real stdio helper, managed process groups, SQLite, and an owned Git worktree.
/// Provider launch paths remain private offline peers and must never be invoked.
private struct RemoteSettleScriptNativeFixture: Sendable {
    let native: RemoteHistoryNativeFixture
    let original: WorkspaceSnapshot
    static func make(command: String) async throws -> Self {
        let native = try await RemoteHistoryNativeFixture.make()
        do {
            let configuration = try ProjectConfiguration(scripts: [.init(name: "Private reviewed cleanup", command: command,
                runOnSettle: true, runsAsynchronously: false)])
            try JSONEncoder().encode(configuration).write(to: native.workspace.appendingPathComponent("t3.json"), options: .atomic)
            let request = GitWorktreeRequest(sourcePath: native.source.path, destinationRoot: native.root.path,
                selection: .reuse(path: native.workspace.path))
            let service = GitWorktreeService(request: request, environment: native.environment, gitExecutable: URL(fileURLWithPath: "/usr/bin/git"))
            let plan = try await service.prepare(), result = try await service.run(plan)
            var preparation = ThreadWorkspacePreparation(request: request)
            preparation.plan = plan; preparation.result = result; preparation.phase = .completed; preparation.endedAt = Date()
            var snapshot = native.snapshot
            snapshot.threads[0].workspacePreparation = preparation
            try WorkspaceJournal.validate(snapshot)
            try await WorkspaceDatabase(url: native.data.appendingPathComponent("workspace.sqlite")).save(snapshot, event: "private-reviewed-script-worktree")
            return .init(native: native, original: snapshot)
        } catch {
            let unused = RemoteEnvironmentClient(factory: { try native.connection() }, expectedEnvironmentID: native.environmentID)
            await native.failed(unused); throw error
        }
    }
    func client() -> RemoteEnvironmentClient {
        .init(factory: { try native.connection() }, expectedEnvironmentID: native.environmentID)
    }
    func discover(_ client: RemoteEnvironmentClient) async throws -> (RemoteWorkspaceTarget, UUID, RemoteProjectScriptState) {
        _ = try await client.connectProjection()
        let descriptor = try #require(await client.currentDescriptor())
        #expect(descriptor.capabilities.supportsReviewedSettleScripts)
        let target = try await native.target(client)
        let lifecycle = try await client.readLifecycle(.init(environmentID: native.environmentID, target: target))
        let capture = try #require(lifecycle.thread?.capture), id = UUID()
        let command = RemoteEnvironmentCommand.lifecycle(capture: capture, action: .settleReviewingScript)
        let receipt = try await client.command(command, id: id).receipt
        #expect(receipt.rejection == nil && receipt.commandID == id)
        try await remoteHistoryEventually { try await native.durable().threads.first?.settlement?.script?.phase == .awaitingApproval }
        let discovered = try await client.readProjectScript(.init(target: target, generationID: id))
        let state = try #require(discovered.script)
        #expect(state.phase == .awaitingApproval && state.canApprove && state.startedAt == nil)
        #expect(state.review?.claim.target == target && state.review?.claim.generationID == id)
        return (target, id, state)
    }
    func expectNoProviderOrDraftChanges() async throws {
        let snapshot = try await native.durable()
        let thread = try #require(snapshot.threads.first { $0.id == native.thread.id })
        #expect(thread.draft == original.threads[0].draft && thread.draftAttachments == original.threads[0].draftAttachments)
        #expect(thread.messages == original.threads[0].messages && thread.runHistory == original.threads[0].runHistory)
        #expect(thread.activeRun == nil && thread.queuedTurns.isEmpty)
        let codex = try native.rows("codex-wire.jsonl"), claude = try native.rows("claude-wire.jsonl")
        #expect(codex.isEmpty && claude.isEmpty)
    }
}

private func remoteSettleScriptRead(_ file: URL) throws -> String {
    guard FileManager.default.fileExists(atPath: file.path) else { return "" }
    return try String(contentsOf: file, encoding: .utf8)
}

private func remoteSettleScriptChildPIDs(_ workspace: URL) throws -> [Int32] {
    try remoteSettleScriptRead(workspace.appendingPathComponent("script-pids.txt")).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
}

@Test(.timeLimit(.minutes(1)))
func remoteSettleScriptNativeDiscoveryApprovalOutputAndRestartPreserveOneExecutionAndAuthoredState() async throws {
    let commandText = "printf 'one\\n' >> executions; printf 'settle-output😀\\n'"
    let f = try await RemoteSettleScriptNativeFixture.make(command: commandText), client = f.client()
    do {
        let (target, generation, state) = try await f.discover(client)
        let review = try #require(state.review)
        #expect(review.command.preview == commandText && review.command.content == nil)
        #expect(review.workspacePath == f.native.workspace.path && review.projectRoot == f.native.source.path)
        let executions = f.native.workspace.appendingPathComponent("executions")
        #expect(!FileManager.default.fileExists(atPath: executions.path), "Remote discovery and review must not execute a repository command.")
        let empty = try await client.projectScriptOutput(.init(reference: state.output))
        #expect(empty.retention == .notStarted && empty.text.isEmpty)
        let approval = RemoteEnvironmentCommand.projectScript(target: target, action: .approve(review.claim)), approvalID = UUID()
        let receipt = try await client.command(approval, id: approvalID).receipt
        #expect(receipt.rejection == nil && receipt.commandID == approvalID)
        try await remoteHistoryEventually { try await f.native.durable().threads.first?.settlement?.script?.phase == .succeeded }
        try await remoteHistoryEventually {
            try await client.projectScriptOutput(.init(reference: state.output)).text.contains("settle-output😀")
        }
        let output = try await client.projectScriptOutput(.init(reference: state.output))
        #expect(output.retention == .retained && output.sequence > empty.sequence && !output.truncated)
        #expect(try await client.receipt(for: approval, id: approvalID).receipt == receipt)
        #expect(try remoteSettleScriptRead(executions) == "one\n")
        _ = try await client.reconnectProjection()
        let reloaded = try await client.readProjectScript(.init(target: target, generationID: generation))
        #expect(reloaded.script?.phase == .succeeded && reloaded.hostID != state.output.hostID)
        let newState = try #require(reloaded.script)
        let unavailable = try await client.projectScriptOutput(.init(reference: newState.output))
        #expect(unavailable.retention == .notRetained && unavailable.text.isEmpty && unavailable.isClosed)
        await #expect(throws: (any Error).self) { try await client.projectScriptOutput(.init(reference: state.output)) }
        let oldClaim = try await client.command(.projectScript(target: target, action: .approve(review.claim))).receipt
        #expect(oldClaim.rejection != nil)
        #expect(try await client.receipt(for: approval, id: approvalID).receipt == receipt)
        #expect(try remoteSettleScriptRead(executions) == "one\n")
        try await f.expectNoProviderOrDraftChanges()
        try await f.native.finish(client)
    } catch { await f.native.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteSettleScriptNativeRestartInterruptsWithoutReplayAndExplicitRetryNeedsNewApprovalThenStopDrains() async throws {
    let commandText = "printf 'one\\n' >> executions; printf '%s\\n' \"$$\" >> script-pids.txt; printf 'waiting😀\\n'; trap '' HUP TERM; /bin/sleep 30 & wait"
    let f = try await RemoteSettleScriptNativeFixture.make(command: commandText), client = f.client()
    do {
        let (target, generation, state) = try await f.discover(client)
        let review = try #require(state.review)
        #expect(try await client.command(.projectScript(target: target, action: .approve(review.claim))).receipt.rejection == nil)
        try await remoteHistoryEventually { try remoteSettleScriptChildPIDs(f.native.workspace).count == 1 }
        let before = try remoteSettleScriptChildPIDs(f.native.workspace)
        #expect(before.count == 1)
        _ = try await client.reconnectProjection()
        try await remoteHistoryEventually { before.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        let interruptedRead = try await client.readProjectScript(.init(target: target, generationID: generation))
        let interrupted = try #require(interruptedRead.script)
        #expect(interrupted.phase == .interrupted && interrupted.canRetry && !interrupted.canApprove)
        #expect(try remoteSettleScriptRead(f.native.workspace.appendingPathComponent("executions")) == "one\n")
        let retry = RemoteEnvironmentCommand.projectScript(target: target, action: .retry(generationID: generation, runID: interrupted.runID))
        #expect(try await client.command(retry).receipt.rejection == nil)
        try await remoteHistoryEventually { try await f.native.durable().threads.first?.settlement?.script?.phase == .awaitingApproval }
        let retryRead = try await client.readProjectScript(.init(target: target, generationID: generation))
        let retryState = try #require(retryRead.script)
        let retryReview = try #require(retryState.review)
        #expect(retryState.runID != state.runID && retryReview.claim.id != review.claim.id)
        #expect(try remoteSettleScriptRead(f.native.workspace.appendingPathComponent("executions")) == "one\n", "Retry must rediscover and review rather than execute automatically.")
        #expect(try await client.command(.projectScript(target: target, action: .approve(retryReview.claim))).receipt.rejection == nil)
        try await remoteHistoryEventually { try remoteSettleScriptChildPIDs(f.native.workspace).count == 2 }
        let pids = try remoteSettleScriptChildPIDs(f.native.workspace)
        let stop = RemoteEnvironmentCommand.projectScript(target: target, action: .stop(generationID: generation, runID: retryState.runID))
        #expect(try await client.command(stop).receipt.rejection == nil)
        try await remoteHistoryEventually { pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        try await remoteHistoryEventually { try await f.native.durable().threads.first?.settlement?.script?.phase == .cancelled }
        #expect(try remoteSettleScriptRead(f.native.workspace.appendingPathComponent("executions")) == "one\none\n")
        let skipped = try await client.command(.projectScript(target: target, action: .skip(generationID: generation, runID: retryState.runID))).receipt
        #expect(skipped.rejection == nil)
        try await remoteHistoryEventually { try await f.native.durable().threads.first?.settlement?.script?.phase == .skipped }
        try await f.expectNoProviderOrDraftChanges()
        try await f.native.finish(client)
    } catch { await f.native.failed(client); throw error }
}

private final class RemoteSettleScriptConnections: @unchecked Sendable {
    let fixture: RemoteHistoryNativeFixture, droppedID: UUID
    private let lock = NSLock()
    private var first = true
    init(fixture: RemoteHistoryNativeFixture, droppedID: UUID) { self.fixture = fixture; self.droppedID = droppedID }
    func make() throws -> JSONRPCConnection {
        try lock.withLock {
            if first {
                first = false
                let proxy = try #require(Bundle.module.url(forResource: "remote_lifecycle_proxy", withExtension: "py", subdirectory: "Fixtures"))
                return try .init(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: [proxy.path, fixture.root.path, droppedID.uuidString, fixture.host.path] + fixture.arguments,
                    cwd: fixture.root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                    environment: fixture.environment, drainProcessOnClose: true)
            }
            return try fixture.connection()
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func remoteSettleScriptNativeLostApprovalReceiptIsRecoveredAfterRestartWithoutResending() async throws {
    let f = try await RemoteSettleScriptNativeFixture.make(command: "printf 'one\\n' >> executions"), approvalID = UUID()
    let connections = RemoteSettleScriptConnections(fixture: f.native, droppedID: approvalID)
    let client = RemoteEnvironmentClient(factory: { try connections.make() }, expectedEnvironmentID: f.native.environmentID)
    do {
        let (target, generation, state) = try await f.discover(client)
        let review = try #require(state.review)
        let approval = RemoteEnvironmentCommand.projectScript(target: target, action: .approve(review.claim))
        await #expect(throws: (any Error).self) { try await client.command(approval, id: approvalID) }
        _ = try await client.reconnectProjection()
        let recovered = try await client.receipt(for: approval, id: approvalID)
        let receipt = try #require(recovered.receipt)
        #expect(receipt.commandID == approvalID && receipt.rejection == nil)
        let executions = try remoteSettleScriptRead(f.native.workspace.appendingPathComponent("executions"))
        #expect(executions == "" || executions == "one\n", "An accepted start may have run before the connection was lost; it is never replayed.")
        let currentRead = try await client.readProjectScript(.init(target: target, generationID: generation))
        let current = try #require(currentRead.script)
        #expect([.interrupted, .succeeded].contains(current.phase))
        await #expect(throws: (any Error).self) { try await client.command(approval, id: approvalID) }
        #expect(try await client.receipt(for: approval, id: approvalID).receipt == receipt)
        #expect(try remoteSettleScriptRead(f.native.workspace.appendingPathComponent("executions")) == executions)
        #expect(FileManager.default.fileExists(atPath: f.native.root.appendingPathComponent("lifecycle-dropped-receipt.json").path))
        try await f.expectNoProviderOrDraftChanges()
        try await f.native.finish(client)
    } catch { await f.native.failed(client); throw error }
}

private func remoteSettleScriptMutation(_ client: RemoteEnvironmentClient, _ request: RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation {
    var operation = try await client.beginWorkspaceOperation(request)
    let end = ContinuousClock.now + .seconds(10)
    while [.accepted, .running].contains(operation.state) {
        guard ContinuousClock.now < end else { throw CoincideError("The private post-drain workspace operation did not finish.") }
        try await Task.sleep(for: .milliseconds(10))
        let observed = try await client.workspaceOperation(request)
        operation = try #require(observed)
    }
    return operation
}

@Test(.timeLimit(.minutes(1)))
func remoteSettleScriptNativeLeaseBlocksFileAndCommonGitWritesUntilExactStopDrains() async throws {
    let commandText = "printf '%s\\n' \"$$\" >> script-pids.txt; printf 'lease-alive😀\\n'; trap '' HUP TERM; /bin/sleep 30 & child=$!; printf '%s\\n' \"$child\" >> script-pids.txt; wait"
    let f = try await RemoteSettleScriptNativeFixture.make(command: commandText), client = f.client()
    do {
        try Data("Sibling unstaged private bytes\n".utf8).write(to: f.native.source.appendingPathComponent("tracked.txt"))
        let (target, generation, state) = try await f.discover(client)
        let siblingID = UUID()
        let created = try await client.command(.createThread(id: siblingID, projectID: target.projectID, provider: .codex,
            title: "Private sibling checkout", model: "history-current", permission: .supervised)).receipt
        #expect(created.rejection == nil)
        let sibling = try await f.native.target(client, threadID: siblingID)
        _ = try await client.readWorkspace(.init(target: sibling, query: .gitStatus))
        let beforeRead = try await client.readWorkspace(.init(target: target, query: .readFile(path: "tracked.txt", allowMissing: false, maxBytes: 4_096)))
        guard case .document(let document) = beforeRead.value else { throw CoincideError("The private native file read returned a different result.") }
        let revision = try #require(document.revision), review = try #require(state.review)
        let beforeFile = try Data(contentsOf: f.native.workspace.appendingPathComponent("tracked.txt"))
        let beforeIndex = try await f.native.git(["show", ":tracked.txt"])
        let siblingIndex = try await f.native.git(["show", ":tracked.txt"], at: f.native.source)
        #expect(try await client.command(.projectScript(target: target, action: .approve(review.claim))).receipt.rejection == nil)
        try await remoteHistoryEventually { try remoteSettleScriptChildPIDs(f.native.workspace).count == 2 }
        try await remoteHistoryEventually { try await f.native.durable().threads.first { $0.id == target.threadID }?.settlement?.script?.phase == .running }
        let pids = try remoteSettleScriptChildPIDs(f.native.workspace)
        #expect(pids.count == 2 && pids.allSatisfy { kill($0, 0) == 0 })
        let mutations: [RemoteWorkspaceMutationRequest] = [
            .init(target: target, mutation: .saveFile(path: "tracked.txt", contents: "Forbidden overlap\n", revision: revision)),
            .init(target: target, mutation: .gitStage(paths: ["tracked.txt"])),
            .init(target: sibling, mutation: .gitStage(paths: ["tracked.txt"]))
        ]
        for request in mutations {
            let refused = try await remoteSettleScriptMutation(client, request)
            #expect(refused.state == .finished && refused.failure?.kind == .busy && refused.result == nil)
            let saved = try await client.workspaceOperation(request)
            #expect(saved == refused)
        }
        #expect(try Data(contentsOf: f.native.workspace.appendingPathComponent("tracked.txt")) == beforeFile)
        #expect(try await f.native.git(["show", ":tracked.txt"]) == beforeIndex)
        #expect(try await f.native.git(["show", ":tracked.txt"], at: f.native.source) == siblingIndex)
        let liveRead = try await client.readProjectScript(.init(target: target, generationID: generation))
        let live = try #require(liveRead.script)
        #expect(live.runID == state.runID && live.canStop && live.phase == .running)
        try await remoteHistoryEventually { try await client.projectScriptOutput(.init(reference: live.output)).text.contains("lease-alive😀") }
        let stopped = try await client.command(.projectScript(target: target, action: .stop(generationID: generation, runID: state.runID))).receipt
        #expect(stopped.rejection == nil)
        try await remoteHistoryEventually { pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        try await remoteHistoryEventually { try await f.native.durable().threads.first { $0.id == target.threadID }?.settlement?.script?.phase == .cancelled }
        let freshRead = try await client.readWorkspace(.init(target: target, query: .readFile(path: "tracked.txt", allowMissing: false, maxBytes: 4_096)))
        guard case .document(let freshDocument) = freshRead.value else { throw CoincideError("The private post-drain file read returned a different result.") }
        let freshRevision = try #require(freshDocument.revision)
        let saved = try await remoteSettleScriptMutation(client, .init(target: target,
            mutation: .saveFile(path: "tracked.txt", contents: "Explicit post-drain bytes\n", revision: freshRevision)))
        #expect(saved.state == .finished && saved.failure == nil)
        let staged = try await remoteSettleScriptMutation(client, .init(target: target, mutation: .gitStage(paths: ["tracked.txt"])))
        #expect(staged.state == .finished && staged.failure == nil)
        #expect(try await f.native.git(["show", ":tracked.txt"]) == "Explicit post-drain bytes")
        let siblingStaged = try await remoteSettleScriptMutation(client, .init(target: sibling, mutation: .gitStage(paths: ["tracked.txt"])))
        #expect(siblingStaged.state == .finished && siblingStaged.failure == nil)
        #expect(try await f.native.git(["show", ":tracked.txt"], at: f.native.source) == "Sibling unstaged private bytes")
        try await f.expectNoProviderOrDraftChanges()
        try await f.native.finish(client)
    } catch { await f.native.failed(client); throw error }
}
