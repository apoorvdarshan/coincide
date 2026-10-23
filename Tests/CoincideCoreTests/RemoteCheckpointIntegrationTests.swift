import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Native helper, production codec/client, SQLite and isolated local Git. The
/// explicit private provider verifies the durable baseline before writing.
private struct RemoteCheckpointFixture: Sendable {
    let root: URL, source: URL, workspace: URL, data: URL, host: URL, proxy: URL
    var environment: [String: String] {
        ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin", "HOME": root.appendingPathComponent("home").path,
         "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
         "GIT_AUTHOR_NAME": "Private checkpoint", "GIT_AUTHOR_EMAIL": "checkpoint@example.invalid",
         "GIT_COMMITTER_NAME": "Private checkpoint", "GIT_COMMITTER_EMAIL": "checkpoint@example.invalid", "GIT_ALLOW_PROTOCOL": ""]
    }
    var arguments: [String] {
        ["--stdio", "--data-directory", data.path, "--codex-executable", root.appendingPathComponent("offline-codex").path,
         "--codex-home", root.appendingPathComponent("codex-home").path]
    }
    static func make(failPost: Bool = false) async throws -> Self {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("coincide-remote-checkpoint-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let source = root.appendingPathComponent("source"), workspace = root.appendingPathComponent("isolated"), data = root.appendingPathComponent("data")
            for name in ["source", "data", "home", "codex-home", "bin"] {
                try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let peer = try #require(Bundle.module.url(forResource: "remote_checkpoint_provider", withExtension: "py", subdirectory: "Fixtures"))
            let proxy = try #require(Bundle.module.url(forResource: "remote_checkpoint_proxy", withExtension: "py", subdirectory: "Fixtures"))
            #if DEBUG
            let mode = "debug"
            #else
            let mode = "release"
            #endif
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let helper = checkout.appendingPathComponent(".build/\(mode)/CoincideEnvironment").resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: helper.path) else { throw CoincideError("Build the matching native checkpoint helper first.") }
            let host = root.appendingPathComponent("native-host")
            let failure = quote(root.appendingPathComponent("fail-next-write-tree").path)
            let scripts: [(URL, String)] = [
                (host, "#!/bin/sh\numask 077\nprintf '%s\\n' \"$$\" >> \(quote(root.appendingPathComponent("host-pids.txt").path))\nexec \(quote(helper.path)) \"$@\"\n"),
                (root.appendingPathComponent("offline-codex"), "#!/bin/sh\nexec /usr/bin/python3 \(quote(peer.path)) \(quote(root.path)) \"$@\"\n"),
                (root.appendingPathComponent("bin/git"), "#!/bin/sh\ncase \" $* \" in *' write-tree '*) if [ -f \(failure) ]; then /bin/rm \(failure); exit 71; fi;; esac\nexec /usr/bin/git \"$@\"\n")
            ]
            for (path, text) in scripts { try text.write(to: path, atomically: false, encoding: .utf8); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path) }
            let f = Self(root: root, source: source, workspace: workspace, data: data, host: host, proxy: proxy)
            _ = try await f.git(["init", "--initial-branch=main"], at: source)
            _ = try await f.git(["config", "commit.gpgsign", "false"], at: source)
            try Data("Committed source\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
            try Data("ignored.txt\n".utf8).write(to: source.appendingPathComponent(".gitignore"))
            _ = try await f.git(["add", "."], at: source); _ = try await f.git(["commit", "-m", "Private baseline"], at: source)
            _ = try await f.git(["worktree", "add", "-b", "isolated-checkpoint", workspace.path], at: source)
            try Data("Staged before\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt")); _ = try await f.git(["add", "tracked.txt"])
            try Data("Working before 🌍\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
            try Data("Initial untracked\n".utf8).write(to: workspace.appendingPathComponent("initial.txt"))
            try Data("Ignored stays\n".utf8).write(to: workspace.appendingPathComponent("ignored.txt"))
            if failPost { try f.touch("fail-post-run") }
            return f
        } catch { try? fm.removeItem(at: root); throw error }
    }
    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    @discardableResult func git(_ args: [String], at directory: URL? = nil) async throws -> String {
        let result = try await CommandRunner.run("/usr/bin/git", ["--literal-pathspecs", "-C", (directory ?? workspace).path] + args,
            timeout: .seconds(10), environment: environment)
        guard result.status == 0 else { throw CoincideError("Private checkpoint fixture Git failed.") }
        return result.text.trimmingCharacters(in: .newlines)
    }
    func touch(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name)) }
    func rows(_ kind: String) throws -> [JSONValue] {
        let path = root.appendingPathComponent("provider-wire.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try Data(contentsOf: path).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }.filter { $0["kind"].string == kind }
    }
    func connection(dropping: UUID? = nil) throws -> JSONRPCConnection {
        if let dropping {
            return try .init(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [proxy.path, root.path, dropping.uuidString, host.path] + arguments,
                cwd: root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes, environment: environment, drainProcessOnClose: true)
        }
        return try .init(executable: host, arguments: arguments, cwd: root, dialect: .jsonRPC2,
            maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes, environment: environment, drainProcessOnClose: true)
    }
    func register(_ client: RemoteEnvironmentClient) async throws -> RemoteWorkspaceTarget {
        let descriptor = try await client.discover(); try await client.trust(environmentID: descriptor.environmentID); _ = try await client.connect()
        let project = UUID(), thread = UUID()
        #expect(try await client.command(.addProject(id: project, path: source.path, title: "Private checkpoint")).receipt.rejection == nil)
        #expect(try await client.command(.createThread(id: thread, projectID: project, provider: .codex, title: "Private checkpoint source",
            model: "checkpoint-offline", permission: .supervised, checkpointPolicy: .automatic)).receipt.rejection == nil)
        let initial = try await refreshed(client, thread: thread)
        let catalog = try await client.worktreeCatalog(target: initial)
        #expect(try await client.command(.prepareWorktree(target: initial, sourceRootID: catalog.sourceRootID,
            expectedAttemptID: catalog.attemptID, selection: .reuse(path: workspace.path), submodules: .none)).receipt.rejection == nil)
        try await remoteCheckpointEventually {
            let owner = try await remoteCheckpointThread(client, thread)
            return owner.workspacePreparation?.isReady == true && owner.workspacePath.utf8.elementsEqual(workspace.path.utf8)
        }
        return try await refreshed(client, thread: thread)
    }
    func refreshed(_ client: RemoteEnvironmentClient, thread: UUID) async throws -> RemoteWorkspaceTarget {
        let snapshot = try await client.snapshot(), owner = try #require(snapshot.workspace.threads.first { $0.id == thread })
        return try await client.bindCheckpointWorkspace(.init(environmentID: snapshot.environmentID, projectID: owner.projectID,
            threadID: thread, configuration: .init(thread: owner)))
    }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        try touch("complete-first"); await client.close()
        var pids: [Int32] = []
        for name in ["host-pids.txt", "proxy-pids.txt"] {
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { pids += try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) } }
        }
        for row in try rows("launch") { if case .number(let pid) = row["pid"], let exact = Int32(exactly: pid) { pids.append(exact) } }
        let owned = pids
        try await remoteCheckpointEventually { owned.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        #expect(try rows("exit").count == rows("launch").count)
        try FileManager.default.removeItem(at: root)
    }
    func failed(_ client: RemoteEnvironmentClient) async {
        try? touch("complete-first"); await client.close()
        if let state = await client.currentSnapshot(), let bytes = try? JSONEncoder().encode(state) {
            _ = FileManager.default.createFile(atPath: root.appendingPathComponent("failed-snapshot.json").path, contents: bytes, attributes: [.posixPermissions: 0o600])
        }
        print("Private checkpoint native fixture retained at \(root.path)")
    }
}
private final class RemoteCheckpointConnections: @unchecked Sendable {
    let fixture: RemoteCheckpointFixture, dropped: UUID?
    private let lock = NSLock(); private var count = 0
    init(_ fixture: RemoteCheckpointFixture, dropped: UUID? = nil) { self.fixture = fixture; self.dropped = dropped }
    func make() throws -> JSONRPCConnection { try lock.withLock { let id = count == 0 ? dropped : nil; count += 1; return try fixture.connection(dropping: id) } }
}
private func remoteCheckpointEventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(12)
    while try await !predicate() {
        guard ContinuousClock.now < end else { throw CoincideError("Private native checkpoint boundary was not reached.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func remoteCheckpointThread(_ client: RemoteEnvironmentClient, _ id: UUID) async throws -> CodingThread {
    try #require(await client.snapshot().workspace.threads.first { $0.id == id })
}
private func remoteCheckpointInventory(_ client: RemoteEnvironmentClient, _ target: RemoteWorkspaceTarget) async throws -> RemoteCheckpointInventory {
    guard case .inventory(let inventory) = try await client.readCheckpoints(.init(target: target, query: .inventory)).value else { throw CoincideError("Expected native checkpoint inventory.") }
    return inventory
}
private func remoteCheckpointCompleted(_ client: RemoteEnvironmentClient, _ f: RemoteCheckpointFixture, _ initial: RemoteWorkspaceTarget) async throws -> (RemoteWorkspaceTarget, RemoteCheckpointRun) {
    #expect(try await client.command(.submit(threadID: initial.threadID, text: "Capture private files", expectedConfiguration: initial.configuration)).receipt.rejection == nil)
    try await remoteCheckpointEventually { try f.rows("files-written").count == 1 }
    try f.touch("complete-first")
    try await remoteCheckpointEventually {
        let thread = try await remoteCheckpointThread(client, initial.threadID)
        return thread.runHistory?.contains { $0.checkpoints?.postRun?.phase == .ready } == true && thread.activeRun == nil
    }
    let target = try await f.refreshed(client, thread: initial.threadID)
    return (target, try #require(await remoteCheckpointInventory(client, target).runs.first))
}

@Test(.timeLimit(.minutes(1)))
func remoteCheckpointNativeCapturesBeforeProviderAndAfterRunWithBoundedDiffAndDurableInventory() async throws {
    let f = try await RemoteCheckpointFixture.make(), connections = RemoteCheckpointConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let initial = try await f.register(client), head = try await f.git(["rev-parse", "HEAD"]), index = try await f.git(["ls-files", "--stage"])
        let (target, run) = try await remoteCheckpointCompleted(client, f, initial), post = try #require(run.postRun)
        #expect(run.baseline.phase == .ready && post.phase == .ready && run.baseline.id != post.id)
        #expect(try f.rows("baseline-ready").count == 1 && f.rows("turn-start").count == 1)
        let query = RemoteCheckpointQuery.runDiff(runID: run.id, baselineAttemptID: run.baseline.id, postRunAttemptID: post.id, maxBytes: 1_048_576)
        guard case .diff(let diff) = try await client.readCheckpoints(.init(target: target, query: query)).value else { throw CoincideError("Expected native checkpoint diff.") }
        #expect(diff.patch.contains("Working before") && diff.patch.contains("Provider changed") && diff.patch.contains("provider-created.txt") && !diff.truncated)
        guard case .diff(let bounded) = try await client.readCheckpoints(.init(target: target,
            query: .runDiff(runID: run.id, baselineAttemptID: run.baseline.id, postRunAttemptID: post.id, maxBytes: 17))).value else { throw CoincideError("Expected bounded native diff.") }
        #expect(bounded.truncated && bounded.patch.utf8.count <= 17)
        let finalHead = try await f.git(["rev-parse", "HEAD"]), finalIndex = try await f.git(["ls-files", "--stage"])
        #expect(finalHead == head && finalIndex == index)
        #expect(try String(contentsOf: f.source.appendingPathComponent("tracked.txt"), encoding: .utf8) == "Committed source\n")
        _ = try await client.reconnect()
        let reopened = try await f.refreshed(client, thread: target.threadID)
        #expect(try await remoteCheckpointInventory(client, reopened).runs == [run])
        #expect(try f.rows("turn-start").count == 1)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteCheckpointNativeReviewedRestoreRecoversLostOriginalReceiptWithoutRepeatingFilesOrProvider() async throws {
    let f = try await RemoteCheckpointFixture.make(), commandID = UUID(), connections = RemoteCheckpointConnections(f, dropped: commandID)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let initial = try await f.register(client), (target, run) = try await remoteCheckpointCompleted(client, f, initial)
        let threadBefore = try await remoteCheckpointThread(client, target.threadID), head = try await f.git(["rev-parse", "HEAD"])
        let review = try await client.reviewCheckpointRestore(.init(target: target, runID: run.id, stage: .baseline, attemptID: run.baseline.id))
        let command = RemoteEnvironmentCommand.checkpoint(target: target, action: .beginRestore(reviewID: review.id, digest: review.digest))
        await #expect(throws: RemoteEnvironmentClientError(.commandUncertain, commandID: commandID)) { _ = try await client.command(command, id: commandID) }
        #expect(!FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("provider-created.txt").path))
        let restored = try Data(contentsOf: f.workspace.appendingPathComponent("tracked.txt"))
        #expect(restored == Data("Working before 🌍\n".utf8))
        #expect(try String(contentsOf: f.workspace.appendingPathComponent("ignored.txt"), encoding: .utf8) == "Ignored stays\n")
        let stagedAfter = try await f.git(["diff", "--cached"]), headAfter = try await f.git(["rev-parse", "HEAD"])
        #expect(stagedAfter.isEmpty && headAfter == head)
        let attributes = try FileManager.default.attributesOfItem(atPath: f.workspace.appendingPathComponent("tracked.txt").path)
        _ = try await client.reconnect(); let rebound = try await f.refreshed(client, thread: target.threadID)
        let receipt = try #require(await client.receipt(for: command, id: commandID).receipt)
        #expect(receipt.commandID == commandID && receipt.rejection == nil)
        let snapshot = try await client.snapshot(), operation = try #require(snapshot.workspace.checkpointRestoreOperation(review.id))
        #expect(operation.phase == .applied && snapshot.workspace.checkpointRestoreOperations?.count == 1)
        #expect(try Data(contentsOf: f.workspace.appendingPathComponent("tracked.txt")) == restored)
        let after = try FileManager.default.attributesOfItem(atPath: f.workspace.appendingPathComponent("tracked.txt").path)
        #expect((attributes[.systemFileNumber] as? NSNumber) == (after[.systemFileNumber] as? NSNumber))
        #expect((attributes[.modificationDate] as? Date) == (after[.modificationDate] as? Date))
        let threadAfter = try await remoteCheckpointThread(client, rebound.threadID)
        #expect(threadAfter.messages == threadBefore.messages && threadAfter.runHistory == threadBefore.runHistory && threadAfter.draft == threadBefore.draft)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: commandID)) { _ = try await client.command(command, id: commandID) }
        #expect(try f.rows("turn-start").count == 1)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func remoteCheckpointNativeFailedPostCaptureHoldsFIFOUntilExactExplicitRetryOrContinue(retry: Bool) async throws {
    let f = try await RemoteCheckpointFixture.make(failPost: true), connections = RemoteCheckpointConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let initial = try await f.register(client)
        #expect(try await client.command(.submit(threadID: initial.threadID, text: "Capture private files", expectedConfiguration: initial.configuration)).receipt.rejection == nil)
        try await remoteCheckpointEventually { try f.rows("files-written").count == 1 }
        // The peer can record its file writes before the host has consumed
        // its native thread/turn notifications. Capture configuration only
        // after that authoritative adoption, preserving the bind CAS guard.
        try await remoteCheckpointEventually {
            let owner = try await remoteCheckpointThread(client, initial.threadID)
            return owner.providerThreadID != nil && owner.activeRun?.nativeTurnID != nil
        }
        let activeTarget = try await f.refreshed(client, thread: initial.threadID)
        #expect(try await client.command(.editThread(threadID: initial.threadID, edit: .checkpointPolicy(.disabled, expected: .automatic), expectedConfiguration: activeTarget.configuration)).receipt.rejection == nil)
        let target = try await f.refreshed(client, thread: initial.threadID)
        #expect(try await client.command(.submit(threadID: target.threadID, text: "Queued private successor", expectedConfiguration: target.configuration)).receipt.rejection == nil)
        try f.touch("complete-first")
        try await remoteCheckpointEventually { try await remoteCheckpointThread(client, target.threadID).heldPostRunCheckpoint?.attempt.phase == .failed }
        let held = try #require(await remoteCheckpointThread(client, target.threadID).heldPostRunCheckpoint)
        #expect(try f.rows("turn-start").count == 1)
        let wrong = try await client.command(.checkpoint(target: target, action: .continuePostRun(runID: held.runID, attemptID: UUID())))
        let turnsAfterRefusal = try f.rows("turn-start").count
        #expect(wrong.receipt.rejection != nil && turnsAfterRefusal == 1)
        let action: RemoteCheckpointAction = retry ? .retryPostRun(runID: held.runID, attemptID: held.attempt.id) : .continuePostRun(runID: held.runID, attemptID: held.attempt.id)
        #expect(try await client.command(.checkpoint(target: target, action: action)).receipt.rejection == nil)
        try await remoteCheckpointEventually {
            let owner = try await remoteCheckpointThread(client, target.threadID)
            return try f.rows("turn-start").count == 2 && owner.activeRun == nil
        }
        let thread = try await remoteCheckpointThread(client, target.threadID), records = try #require(thread.runHistory)
        #expect(thread.heldPostRunCheckpoint == nil && records.count == 2 && records[1].checkpoints == nil)
        let first = try #require(records.first { $0.id == held.runID }?.checkpoints)
        if retry {
            #expect(first.postRun?.phase == .ready && first.postRun?.isLaterObservation == true && first.postRun?.id != held.attempt.id)
            #expect(first.previousPostRunAttempts.contains { $0.id == held.attempt.id && $0.phase == .failed })
        } else { #expect(first.postRun?.phase == .skipped && first.postRun?.id == held.attempt.id) }
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteCheckpointNativeRejectsStaleAttemptDiscardedReviewChangedConfigurationAndPhysicalRoot() async throws {
    let f = try await RemoteCheckpointFixture.make(), connections = RemoteCheckpointConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let initial = try await f.register(client), (target, run) = try await remoteCheckpointCompleted(client, f, initial)
        await #expect(throws: RemoteCheckpointFailure(.invalidRequest)) { _ = try await client.readCheckpoints(.init(target: target,
            query: .runDiff(runID: run.id, baselineAttemptID: UUID(), postRunAttemptID: try #require(run.postRun).id, maxBytes: 100))) }
        let request = RemoteCheckpointReviewRequest(target: target, runID: run.id, stage: .baseline, attemptID: run.baseline.id)
        let discarded = try await client.reviewCheckpointRestore(request)
        #expect(try await client.discardCheckpointRestoreReview(.init(target: target, reviewID: discarded.id, digest: discarded.digest)).discarded)
        #expect(try await client.command(.checkpoint(target: target, action: .beginRestore(reviewID: discarded.id, digest: discarded.digest))).receipt.rejection != nil)
        let review = try await client.reviewCheckpointRestore(request)
        #expect(try await client.command(.editThread(threadID: target.threadID, edit: .model("changed-offline"), expectedConfiguration: target.configuration)).receipt.rejection == nil)
        #expect(try await client.command(.checkpoint(target: target, action: .beginRestore(reviewID: review.id, digest: review.digest))).receipt.rejection != nil)
        let currentTarget = try await f.refreshed(client, thread: target.threadID)
        _ = try await remoteCheckpointInventory(client, currentTarget)
        let moved = f.root.appendingPathComponent("owned-original-worktree")
        try FileManager.default.moveItem(at: f.workspace, to: moved)
        try FileManager.default.createDirectory(at: f.workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("Replacement preserved\n".utf8).write(to: f.workspace.appendingPathComponent("tracked.txt"))
        await #expect(throws: RemoteCheckpointFailure(.invalidTarget)) { _ = try await client.readCheckpoints(.init(target: currentTarget, query: .inventory)) }
        #expect(try String(contentsOf: f.workspace.appendingPathComponent("tracked.txt"), encoding: .utf8) == "Replacement preserved\n")
        #expect(try String(contentsOf: moved.appendingPathComponent("tracked.txt"), encoding: .utf8) == "Provider changed 🌍\n")
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}
