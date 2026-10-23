import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Actual native helper/codec/SQLite with private local Git and an explicit
/// offline provider. The only Git origin is a bare directory inside this root.
private struct RemoteWorktreeFixture: Sendable {
    let root: URL, source: URL, data: URL, host: URL, provider: URL, proxy: URL
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.appendingPathComponent("home").path,
         "LANG": "en_US.UTF-8", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ALLOW_PROTOCOL": "file", "GIT_TERMINAL_PROMPT": "0",
         "GCM_INTERACTIVE": "Never", "GIT_AUTHOR_NAME": "Private worktree", "GIT_COMMITTER_NAME": "Private worktree",
         "GIT_AUTHOR_EMAIL": "worktree@example.invalid", "GIT_COMMITTER_EMAIL": "worktree@example.invalid"]
    }
    var arguments: [String] {
        ["--stdio", "--data-directory", data.path, "--codex-executable", provider.path,
         "--codex-home", root.appendingPathComponent("codex-home").path]
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func make() async throws -> Self {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("coincide-remote-worktree-\(UUID())").resolvingSymlinksInPath()
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let source = root.appendingPathComponent("source"), data = root.appendingPathComponent("data")
            for folder in [source, data, root.appendingPathComponent("home"), root.appendingPathComponent("codex-home")] {
                try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let providerPeer = try #require(Bundle.module.url(forResource: "remote_worktree_provider", withExtension: "py", subdirectory: "Fixtures"))
            let proxy = try #require(Bundle.module.url(forResource: "remote_worktree_proxy", withExtension: "py", subdirectory: "Fixtures"))
            #if DEBUG
            let configuration = "debug"
            #else
            let configuration = "release"
            #endif
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let helper = checkout.appendingPathComponent(".build/\(configuration)/CoincideEnvironment").resolvingSymlinksInPath()
            guard manager.isExecutableFile(atPath: helper.path) else { throw CoincideError("Build the matching native helper before remote worktree acceptance.") }
            let host = root.appendingPathComponent("native-host"), provider = root.appendingPathComponent("offline-codex")
            for (file, contents) in [
                (host, "#!/bin/sh\numask 077\nprintf '%s\\n' \"$$\" >> \(quote(root.appendingPathComponent("host-pids.txt").path))\nexec \(quote(helper.path)) \"$@\"\n"),
                (provider, "#!/bin/sh\nexec /usr/bin/python3 \(quote(providerPeer.path)) \(quote(root.path)) \"$@\"\n")
            ] {
                try contents.write(to: file, atomically: false, encoding: .utf8)
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            }
            let f = Self(root: root, source: source, data: data, host: host, provider: provider, proxy: proxy)
            _ = try await f.git(["init", "--initial-branch=main"])
            _ = try await f.git(["config", "user.name", "Private worktree"])
            _ = try await f.git(["config", "user.email", "worktree@example.invalid"])
            _ = try await f.git(["config", "commit.gpgsign", "false"])
            try Data("Committed source\n".utf8).write(to: source.appendingPathComponent("README.md"))
            _ = try await f.git(["add", "--", "README.md"]); _ = try await f.git(["commit", "-m", "Private baseline"])
            _ = try await f.git(["branch", "existing-local"])
            _ = try await f.git(["clone", "--bare", "--", source.path, root.appendingPathComponent("origin.git").path], at: root)
            _ = try await f.git(["remote", "add", "origin", root.appendingPathComponent("origin.git").path])
            try Data("Uncommitted source stays exact\n".utf8).write(to: source.appendingPathComponent("README.md"))
            try Data("Private untracked bytes\n".utf8).write(to: source.appendingPathComponent("untracked.txt"))
            return f
        } catch { try? manager.removeItem(at: root); throw error }
    }
    @discardableResult func git(_ args: [String], at: URL? = nil) async throws -> String {
        let result = try await CommandRunner.run("/usr/bin/git", ["--literal-pathspecs", "-C", (at ?? source).path] + args,
            timeout: .seconds(10), environment: environment)
        guard result.status == 0 else { throw CoincideError("Private local Git fixture failed: " + String(decoding: result.error, as: UTF8.self)) }
        return result.text.trimmingCharacters(in: .newlines)
    }
    func connection(droppedID: UUID? = nil) throws -> JSONRPCConnection {
        if let droppedID {
            return try .init(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [proxy.path, root.path, droppedID.uuidString, host.path] + arguments,
                cwd: root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                environment: environment, drainProcessOnClose: true)
        }
        return try .init(executable: host, arguments: arguments, cwd: root, dialect: .jsonRPC2,
            maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes, environment: environment, drainProcessOnClose: true)
    }
    func rows(_ file: String) throws -> [JSONValue] {
        let path = root.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try Data(contentsOf: path).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func launches() throws -> [JSONValue] { try rows("provider-wire.jsonl").filter { $0["kind"].string == "launch" } }
    func register(_ client: RemoteEnvironmentClient, projectID: UUID? = nil) async throws -> RemoteWorkspaceTarget {
        let descriptor = try await client.discover(); try await client.trust(environmentID: descriptor.environmentID)
        _ = try await client.connect()
        let project = projectID ?? UUID(), thread = UUID()
        if projectID == nil {
            #expect(try await client.command(.addProject(id: project, path: source.path, title: "Private remote Git")).receipt.rejection == nil)
        }
        #expect(try await client.command(.createThread(id: thread, projectID: project, provider: .codex,
            title: "Remote worktree", model: "remote-worktree-offline", permission: .supervised)).receipt.rejection == nil)
        let current = try await remoteWorktreeThread(client, id: thread)
        return try await client.bindWorkspace(.init(environmentID: descriptor.environmentID, projectID: project,
            threadID: thread, configuration: .init(thread: current)))
    }
    func installHeldHook(name: String = "post-checkout") throws {
        let hooks = source.appendingPathComponent(".git/hooks")
        let hook = hooks.appendingPathComponent(name)
        let program = #"""
import json, os, signal, sys, time
from pathlib import Path
root=Path(sys.argv[1]);os.umask(0o077)
signal.signal(signal.SIGTERM,lambda *_:sys.exit(130))
row={'pid':os.getpid(),'gitPID':os.getppid(),'cwd':os.getcwd()}
with (root/'hook-entries.jsonl').open('a') as out:out.write(json.dumps(row)+'\n')
end=time.monotonic()+20
while (root/'hold-hook').exists() and not (root/'release-hook').exists() and time.monotonic()<end:time.sleep(.005)
assert not (root/'hold-hook').exists() or (root/'release-hook').exists()
"""#
        let peer = root.appendingPathComponent("held-hook.py")
        try program.write(to: peer, atomically: false, encoding: .utf8)
        try "#!/bin/sh\nexec /usr/bin/python3 \(Self.quote(peer.path)) \(Self.quote(root.path))\n".write(to: hook, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = FileManager.default.createFile(atPath: root.appendingPathComponent("hold-hook").path, contents: Data(), attributes: [.posixPermissions: 0o600])
    }
    func releaseHook() {
        _ = FileManager.default.createFile(atPath: root.appendingPathComponent("release-hook").path, contents: Data(), attributes: [.posixPermissions: 0o600])
        try? FileManager.default.removeItem(at: root.appendingPathComponent("hold-hook"))
    }
    func expectDrained() async throws {
        var pids: [Int32] = []
        for name in ["host-pids.txt", "proxy-pids.txt"] {
            let path = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) {
                pids += try String(contentsOf: path, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
            }
        }
        for row in try rows("hook-entries.jsonl") {
            for key in ["pid", "gitPID"] { if case .number(let value) = row[key], let pid = Int32(exactly: value) { pids.append(pid) } }
        }
        for row in try launches() { if case .number(let value) = row["pid"], let pid = Int32(exactly: value) { pids.append(pid) } }
        let ownedPIDs = pids
        try await remoteWorktreeEventually { ownedPIDs.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
    }
    func remove() throws { try FileManager.default.removeItem(at: root) }
    func retainFailure() { print("Private native remote worktree fixture retained at \(root.path)") }
}
private final class RemoteWorktreeConnections: @unchecked Sendable {
    let fixture: RemoteWorktreeFixture, droppedID: UUID?
    private let lock = NSLock()
    private var count = 0
    init(_ fixture: RemoteWorktreeFixture, droppedID: UUID? = nil) { self.fixture = fixture; self.droppedID = droppedID }
    func make() throws -> JSONRPCConnection {
        let drop = lock.withLock { defer { count += 1 }; return count == 0 ? droppedID : nil }
        return try fixture.connection(droppedID: drop)
    }
}
private func remoteWorktreeEventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(12)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private native worktree did not reach its owned acceptance boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func remoteWorktreeThread(_ client: RemoteEnvironmentClient, id: UUID) async throws -> CodingThread {
    try #require(await client.snapshot().workspace.threads.first { $0.id == id })
}
private func remoteWorktreeRecoveryTarget(_ thread: CodingThread, environmentID: UUID) -> RemoteWorkspaceTarget {
    .init(environmentID: environmentID, projectID: thread.projectID, threadID: thread.id, configuration: .init(thread: thread))
}
private func remoteWorktreePrepare(_ client: RemoteEnvironmentClient, target: RemoteWorkspaceTarget,
                                   selection: GitWorktreeSelection) async throws -> RemoteEnvironmentCommand {
    let catalog = try await client.worktreeCatalog(target: target)
    return .prepareWorktree(target: target, sourceRootID: catalog.sourceRootID, expectedAttemptID: catalog.attemptID,
        selection: selection, submodules: .none)
}

@Test(.timeLimit(.minutes(1)))
func remoteWorktreeNativeHostCreatesBranchesReusesRegisteredCheckoutAndPreservesDirtySource() async throws {
    let f = try await RemoteWorktreeFixture.make(), connections = RemoteWorktreeConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let first = try await f.register(client), originalHead = try await f.git(["rev-parse", "HEAD"])
        let originalStatus = try await f.git(["status", "--porcelain=v1", "-z"])
        let catalog = try await client.worktreeCatalog(target: first)
        #expect(catalog.target == first && catalog.branches.contains { $0.name == "existing-local" })
        #expect(try await client.command(.prepareWorktree(target: first, sourceRootID: catalog.sourceRootID,
            expectedAttemptID: catalog.attemptID, selection: .createBranch(name: "new-remote", baseRef: "HEAD"), submodules: .none)).receipt.rejection == nil)
        try await remoteWorktreeEventually { try await remoteWorktreeThread(client, id: first.threadID).workspacePreparation?.isReady == true }
        let created = try #require(try await remoteWorktreeThread(client, id: first.threadID).workspacePreparation)
        #expect(created.result?.branch == "new-remote" && created.result?.headCommit == originalHead && created.setup == nil)
        let destination = URL(fileURLWithPath: created.destinationPath)
        #expect(try Data(contentsOf: destination.appendingPathComponent("README.md")) == Data("Committed source\n".utf8))
        let second = try await f.register(client, projectID: first.projectID)
        #expect(try await client.command(try await remoteWorktreePrepare(client, target: second,
            selection: .existingBranch(name: "existing-local"))).receipt.rejection == nil)
        try await remoteWorktreeEventually { try await remoteWorktreeThread(client, id: second.threadID).workspacePreparation?.isReady == true }
        #expect(try await remoteWorktreeThread(client, id: second.threadID).workspacePreparation?.result?.branch == "existing-local")
        let third = try await f.register(client, projectID: first.projectID)
        let registered = try await client.worktreeCatalog(target: third)
        #expect(registered.worktrees.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() })
        #expect(try await client.command(.prepareWorktree(target: third, sourceRootID: registered.sourceRootID,
            expectedAttemptID: registered.attemptID, selection: .reuse(path: created.destinationPath), submodules: .none)).receipt.rejection == nil)
        try await remoteWorktreeEventually { try await remoteWorktreeThread(client, id: third.threadID).workspacePreparation?.isReady == true }
        #expect(try await remoteWorktreeThread(client, id: third.threadID).workspacePath == created.destinationPath)
        #expect(try await f.git(["rev-parse", "HEAD"]) == originalHead)
        #expect(try await f.git(["symbolic-ref", "--short", "HEAD"]) == "main")
        #expect(try await f.git(["status", "--porcelain=v1", "-z"]) == originalStatus)
        #expect(try Data(contentsOf: f.source.appendingPathComponent("README.md")) == Data("Uncommitted source stays exact\n".utf8))
        #expect(try Data(contentsOf: f.source.appendingPathComponent("untracked.txt")) == Data("Private untracked bytes\n".utf8))
        #expect(try await f.git(["rev-parse", "HEAD"], at: f.root.appendingPathComponent("origin.git")) == originalHead)
        #expect(try f.launches().isEmpty)
        await client.close(); try await f.expectDrained(); try f.remove()
    } catch { f.releaseHook(); await client.close(); f.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteWorktreeNativeHostHoldsQueuedInputAndFileToolsUntilReadyThenRunsExactlyOnce() async throws {
    let f = try await RemoteWorktreeFixture.make(), client = RemoteEnvironmentClient(factory: { try f.connection() })
    do {
        try f.installHeldHook()
        let target = try await f.register(client)
        let sourceOwner = try await f.register(client, projectID: target.projectID)
        #expect(try await client.command(try await remoteWorktreePrepare(client, target: target,
            selection: .createBranch(name: "queued-remote", baseRef: "HEAD"))).receipt.rejection == nil)
        try await remoteWorktreeEventually { try !f.rows("hook-entries.jsonl").isEmpty }
        let waiting = try await remoteWorktreeThread(client, id: target.threadID), state = try #require(waiting.workspacePreparation)
        #expect(state.phase == .preparing && !state.isReady && state.plan != nil)
        #expect(try f.launches().isEmpty)
        let pendingTarget = remoteWorktreeRecoveryTarget(waiting, environmentID: target.environmentID)
        await #expect(throws: (any Error).self) { _ = try await client.bindWorkspace(pendingTarget) }
        let wrongRoot = RemoteWorkspaceTarget(environmentID: target.environmentID, projectID: target.projectID,
            threadID: target.threadID, configuration: .init(thread: waiting), rootID: target.rootID)
        let denied = try await client.beginWorkspaceOperation(.init(target: wrongRoot, mutation: .createFile(path: "must-not-create.txt", contents: "not ready")))
        #expect(denied.failure != nil)
        let sourceDenied = try await client.beginWorkspaceOperation(.init(target: sourceOwner,
            mutation: .createFile(path: "must-not-touch-source.txt", contents: "source is also reserved")))
        #expect(sourceDenied.failure?.kind == .busy)
        #expect(!FileManager.default.fileExists(atPath: f.source.appendingPathComponent("must-not-touch-source.txt").path))
        #expect(try await client.command(.submit(threadID: waiting.id, text: "Remote worktree queued input", expectedConfiguration: .init(thread: waiting))).receipt.rejection == nil)
        let queued = try await remoteWorktreeThread(client, id: target.threadID)
        #expect(queued.messages.isEmpty && queued.activeRun == nil && queued.queuedTurns.count == 1)
        #expect(queued.queuedTurns.first?.configuration.workspacePath == state.destinationPath)
        #expect(try f.launches().isEmpty)
        try state.destinationPath.write(to: f.root.appendingPathComponent("expected-provider-workspace"), atomically: false, encoding: .utf8)
        f.releaseHook()
        try await remoteWorktreeEventually {
            let thread = try await remoteWorktreeThread(client, id: target.threadID)
            return thread.workspacePreparation?.isReady == true && thread.activeRun == nil && thread.queuedTurns.isEmpty
                && thread.messages.contains { $0.role == .assistant && $0.text == "READY_WORKTREE_✓" }
        }
        let final = try await remoteWorktreeThread(client, id: target.threadID)
        #expect(final.messages.filter { $0.role == .user && $0.text == "Remote worktree queued input" }.count == 1)
        #expect(try f.rows("provider-wire.jsonl").filter { $0["kind"].string == "turn" }.count == 1)
        #expect(try f.launches().count == 1)
        #expect(!FileManager.default.fileExists(atPath: state.destinationPath + "/must-not-create.txt"))
        #expect(try Data(contentsOf: f.source.appendingPathComponent("README.md")) == Data("Uncommitted source stays exact\n".utf8))
        await client.close(); try await f.expectDrained(); try f.remove()
    } catch { f.releaseHook(); await client.close(); f.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteWorktreeNativeHostCancelInspectAndRetryPreserveRegisteredPartialCheckout() async throws {
    let f = try await RemoteWorktreeFixture.make(), client = RemoteEnvironmentClient(factory: { try f.connection() })
    do {
        try f.installHeldHook()
        let target = try await f.register(client)
        #expect(try await client.command(try await remoteWorktreePrepare(client, target: target,
            selection: .createBranch(name: "cancelled-remote", baseRef: "HEAD"))).receipt.rejection == nil)
        try await remoteWorktreeEventually { try !f.rows("hook-entries.jsonl").isEmpty }
        let preparing = try await remoteWorktreeThread(client, id: target.threadID), attempt = try #require(preparing.workspacePreparation)
        let recovery = remoteWorktreeRecoveryTarget(preparing, environmentID: target.environmentID), cancelID = UUID()
        let command = RemoteEnvironmentCommand.cancelWorktree(target: recovery, attemptID: attempt.id)
        let receipt = try await client.command(command, id: cancelID)
        #expect(receipt.receipt.rejection == nil)
        try await remoteWorktreeEventually { try await remoteWorktreeThread(client, id: target.threadID).workspacePreparation?.phase == .cancelled }
        let cancelledJobs = try f.rows("hook-entries.jsonl").flatMap { row in
            ["pid", "gitPID"].compactMap { key -> Int32? in
                guard case .number(let value) = row[key] else { return nil }
                return Int32(exactly: value)
            }
        }
        try await remoteWorktreeEventually { cancelledJobs.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        #expect(try await client.receipt(for: command, id: cancelID).receipt == receipt.receipt)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: cancelID)) { _ = try await client.command(command, id: cancelID) }
        let partial = URL(fileURLWithPath: attempt.destinationPath), bytes = try Data(contentsOf: partial.appendingPathComponent("README.md"))
        #expect(try await f.git(["rev-parse", "--abbrev-ref", "HEAD"], at: partial) == "cancelled-remote")
        let stopped = try await remoteWorktreeThread(client, id: target.threadID)
        let stoppedTarget = remoteWorktreeRecoveryTarget(stopped, environmentID: target.environmentID)
        #expect(try await client.command(.inspectWorktree(target: stoppedTarget, attemptID: attempt.id)).receipt.rejection == nil)
        #expect(try await remoteWorktreeThread(client, id: target.threadID).workspacePreparation?.id == attempt.id)
        #expect(try await client.command(.retryWorktree(target: stoppedTarget, attemptID: attempt.id)).receipt.rejection == nil)
        try await remoteWorktreeEventually {
            let next = try await remoteWorktreeThread(client, id: target.threadID).workspacePreparation
            return next?.id != attempt.id && next?.phase == .failed
        }
        let retried = try #require(try await remoteWorktreeThread(client, id: target.threadID).workspacePreparation)
        #expect(retried.destinationPath != attempt.destinationPath && retried.previousAttempts.contains { $0.request.id == attempt.id })
        #expect(try Data(contentsOf: partial.appendingPathComponent("README.md")) == bytes)
        #expect(try f.rows("hook-entries.jsonl").count == 1)
        // Recovery catalogs bind the original source even when this new failed
        // destination was never created. An explicit reuse is a fresh command.
        let failed = try await remoteWorktreeThread(client, id: target.threadID)
        let failedTarget = remoteWorktreeRecoveryTarget(failed, environmentID: target.environmentID)
        let catalog = try await client.worktreeCatalog(target: failedTarget)
        #expect(catalog.attemptID == retried.id && catalog.sourcePath == f.source.path)
        f.releaseHook()
        #expect(try await client.command(.prepareWorktree(target: failedTarget, sourceRootID: catalog.sourceRootID,
            expectedAttemptID: catalog.attemptID, selection: .reuse(path: attempt.destinationPath), submodules: .none)).receipt.rejection == nil)
        try await remoteWorktreeEventually { try await remoteWorktreeThread(client, id: target.threadID).workspacePreparation?.isReady == true }
        #expect(try await remoteWorktreeThread(client, id: target.threadID).workspacePath == attempt.destinationPath)
        #expect(try f.rows("hook-entries.jsonl").count == 1)
        #expect(try f.launches().isEmpty)
        f.releaseHook(); await client.close(); try await f.expectDrained(); try f.remove()
    } catch { f.releaseHook(); await client.close(); f.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteWorktreeNativeHostLostPrepareReplyRecoversExactReceiptAndNeverReplaysGit() async throws {
    let f = try await RemoteWorktreeFixture.make(), commandID = UUID(), connections = RemoteWorktreeConnections(f, droppedID: commandID)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        try f.installHeldHook()
        let target = try await f.register(client)
        let command = try await remoteWorktreePrepare(client, target: target, selection: .createBranch(name: "lost-reply-remote", baseRef: "HEAD"))
        await #expect(throws: RemoteEnvironmentClientError(.commandUncertain, commandID: commandID)) { _ = try await client.command(command, id: commandID) }
        let reply = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: f.root.appendingPathComponent("dropped-worktree-reply.json")))
        let committed = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCommandResult.self, from: reply["result"])
        #expect(committed.receipt.commandID == commandID && committed.receipt.rejection == nil)
        #expect(try f.rows("hook-entries.jsonl").count == 1)
        let database = try WorkspaceDatabase(url: f.data.appendingPathComponent("workspace.sqlite"))
        let before = try #require(await database.load().threads.first { $0.id == target.threadID }?.workspacePreparation)
        _ = try await client.reconnect()
        let recovered = try #require(try await remoteWorktreeThread(client, id: target.threadID).workspacePreparation)
        #expect(recovered.id == before.id && recovered.request == before.request)
        #expect(!recovered.isRunning && !recovered.isReady)
        #expect(try await client.receipt(for: command, id: commandID).receipt == committed.receipt)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: commandID)) { _ = try await client.command(command, id: commandID) }
        #expect(try f.rows("hook-entries.jsonl").count == 1 && f.launches().isEmpty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: before.destinationPath).appendingPathComponent("README.md")) == Data("Committed source\n".utf8))
        f.releaseHook(); await client.close(); try await f.expectDrained(); try f.remove()
    } catch { f.releaseHook(); await client.close(); f.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteWorktreeNativeHostRefusesAReplacedBoundSourceBeforeChangingEitherRepository() async throws {
    let f = try await RemoteWorktreeFixture.make(), client = RemoteEnvironmentClient(factory: { try f.connection() })
    do {
        let target = try await f.register(client), moved = f.root.appendingPathComponent("original-source")
        let catalog = try await client.worktreeCatalog(target: target)
        try FileManager.default.moveItem(at: f.source, to: moved)
        try FileManager.default.createDirectory(at: f.source, withIntermediateDirectories: false)
        try Data("Replacement stays exact\n".utf8).write(to: f.source.appendingPathComponent("replacement.txt"))
        _ = try await f.git(["init", "--initial-branch=main"])
        _ = try await f.git(["add", "--", "replacement.txt"])
        _ = try await f.git(["commit", "-m", "Independent replacement baseline"])
        await #expect(throws: (any Error).self) { _ = try await client.worktreeCatalog(target: target) }
        let command = RemoteEnvironmentCommand.prepareWorktree(target: target, sourceRootID: catalog.sourceRootID,
            expectedAttemptID: catalog.attemptID, selection: .createBranch(name: "must-never-exist", baseRef: "HEAD"), submodules: .none)
        let rejected = try await client.command(command)
        #expect(rejected.receipt.rejection != nil)
        #expect(try Data(contentsOf: f.source.appendingPathComponent("replacement.txt")) == Data("Replacement stays exact\n".utf8))
        #expect(try Data(contentsOf: moved.appendingPathComponent("README.md")) == Data("Uncommitted source stays exact\n".utf8))
        #expect(try await f.git(["branch", "--list", "must-never-exist"]) == "")
        #expect(try await f.git(["branch", "--list", "must-never-exist"], at: moved) == "")
        #expect(try await remoteWorktreeThread(client, id: target.threadID).workspacePreparation == nil)
        #expect(try f.launches().isEmpty)
        await client.close(); try await f.expectDrained(); try f.remove()
    } catch { f.releaseHook(); await client.close(); f.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func remoteWorktreeNativeHostRefusesPreparationWhileFileMutationOwnsSourceOrReusedDestination(reuseDestination: Bool) async throws {
    let f = try await RemoteWorktreeFixture.make(), client = RemoteEnvironmentClient(factory: { try f.connection() })
    do {
        let original = try await f.register(client)
        let mutationTarget: RemoteWorkspaceTarget, prepareTarget: RemoteWorkspaceTarget, selection: GitWorktreeSelection
        if reuseDestination {
            #expect(try await client.command(try await remoteWorktreePrepare(client, target: original,
                selection: .createBranch(name: "busy-reused-destination", baseRef: "HEAD"))).receipt.rejection == nil)
            try await remoteWorktreeEventually { try await remoteWorktreeThread(client, id: original.threadID).workspacePreparation?.isReady == true }
            let ready = try await remoteWorktreeThread(client, id: original.threadID)
            mutationTarget = try await client.bindWorkspace(remoteWorktreeRecoveryTarget(ready, environmentID: original.environmentID))
            prepareTarget = try await f.register(client, projectID: original.projectID)
            selection = .reuse(path: ready.workspacePath)
        } else {
            mutationTarget = original; prepareTarget = original
            selection = .createBranch(name: "must-not-enter-busy-source", baseRef: "HEAD")
        }
        let catalog = try await client.worktreeCatalog(target: prepareTarget)
        try f.installHeldHook(name: "pre-commit")
        let checkout = URL(fileURLWithPath: mutationTarget.workspacePath), head = try await f.git(["rev-parse", "HEAD"], at: checkout)
        let contents = Data("Keep the held file mutation bytes\n".utf8)
        try contents.write(to: checkout.appendingPathComponent("README.md"))
        _ = try await f.git(["add", "--", "README.md"], at: checkout)
        let mutation = RemoteWorkspaceMutationRequest(target: mutationTarget, mutation: .gitCommit(message: "Private held mutation"))
        _ = try await client.beginWorkspaceOperation(mutation)
        try await remoteWorktreeEventually { try !f.rows("hook-entries.jsonl").isEmpty }
        let refused = try await client.command(.prepareWorktree(target: prepareTarget, sourceRootID: catalog.sourceRootID,
            expectedAttemptID: catalog.attemptID, selection: selection, submodules: .none))
        #expect(refused.receipt.rejection != nil)
        #expect(try await remoteWorktreeThread(client, id: prepareTarget.threadID).workspacePreparation == nil)
        let cancelled = try #require(await client.cancelWorkspaceOperation(mutation))
        #expect(cancelled.state == .uncertain && cancelled.failure?.kind == .interrupted)
        let hook = try #require(f.rows("hook-entries.jsonl").first)
        guard case .number(let rawGitPID) = hook["gitPID"], let gitPID = Int32(exactly: rawGitPID) else {
            throw CoincideError("The private held Git fixture did not record its owner.")
        }
        #expect(kill(gitPID, 0) == -1 && errno == ESRCH)
        // GitService joins its exact Git child. Release this independently
        // owned hook without claiming a general descendant-drain guarantee.
        f.releaseHook()
        #expect(try await f.git(["rev-parse", "HEAD"], at: checkout) == head)
        #expect(try Data(contentsOf: checkout.appendingPathComponent("README.md")) == contents)
        #expect(try f.launches().isEmpty)
        await client.close(); try await f.expectDrained(); try f.remove()
    } catch { f.releaseHook(); await client.close(); f.retainFailure(); throw error }
}
