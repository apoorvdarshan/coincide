import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Real helper, production codec, private files/SQLite and local Git. The
/// provider executable is a tripwire and must never be invoked by file tools.
private struct RemoteWorkspaceFixture: Sendable {
    let root: URL, workspace: URL, data: URL, host: URL, unusedProvider: URL
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.appendingPathComponent("home").path,
         "LANG": "en_US.UTF-8", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
         "GIT_AUTHOR_NAME": "Remote transport fixture", "GIT_AUTHOR_EMAIL": "remote-fixture@example.invalid",
         "GIT_COMMITTER_NAME": "Remote transport fixture", "GIT_COMMITTER_EMAIL": "remote-fixture@example.invalid",
         "GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "commit.gpgSign", "GIT_CONFIG_VALUE_0": "false",
         "GIT_CONFIG_KEY_1": "tag.gpgSign", "GIT_CONFIG_VALUE_1": "false", "GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "Never"]
    }
    static func make() async throws -> Self {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("coincide-remote-files-" + UUID().uuidString).resolvingSymlinksInPath()
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let workspace = root.appendingPathComponent("workspace"), data = root.appendingPathComponent("data")
            for folder in [workspace, data, root.appendingPathComponent("home"), root.appendingPathComponent("codex-home")] {
                try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            #if DEBUG
            let configuration = "debug"
            #else
            let configuration = "release"
            #endif
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let helper = checkout.appendingPathComponent(".build/\(configuration)/CoincideEnvironment").resolvingSymlinksInPath()
            guard manager.isExecutableFile(atPath: helper.path) else { throw CoincideError("The matching native environment helper must be built.") }
            let host = root.appendingPathComponent("native-host"), unused = root.appendingPathComponent("unused-provider")
            let hostScript = "#!/bin/sh\numask 077\nprintf '%s\\n' \"$$\" >> \(quote(root.appendingPathComponent("host-pids.txt").path))\nexec \(quote(helper.path)) \"$@\"\n"
            let unusedScript = "#!/bin/sh\numask 077\nprintf unexpected > \(quote(root.appendingPathComponent("unexpected-provider-launch").path))\nexit 78\n"
            for (path, text) in [(host, hostScript), (unused, unusedScript)] {
                try text.write(to: path, atomically: false, encoding: .utf8)
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
            let value = Self(root: root, workspace: workspace, data: data, host: host, unusedProvider: unused)
            try "baseline\n".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            _ = try await value.git(["init", "--initial-branch", "main"])
            _ = try await value.git(["add", "--", "README.md"])
            _ = try await value.git(["commit", "--message", "Private baseline"])
            return value
        } catch { try? manager.removeItem(at: root); throw error }
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func connection() throws -> JSONRPCConnection {
        try .init(executable: host, arguments: ["--stdio", "--data-directory", data.path,
            "--codex-executable", unusedProvider.path, "--codex-home", root.appendingPathComponent("codex-home").path],
            cwd: root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
            environment: environment, drainProcessOnClose: true)
    }
    func client(expected: UUID? = nil) -> RemoteEnvironmentClient {
        RemoteEnvironmentClient(factory: { try self.connection() }, expectedEnvironmentID: expected)
    }
    @discardableResult func git(_ arguments: [String]) async throws -> String {
        let value = try await CommandRunner.run("/usr/bin/git", ["--literal-pathspecs", "-C", workspace.path] + arguments,
            timeout: .seconds(8), environment: environment)
        guard value.status == 0 else { throw CoincideError("The private local Git fixture failed: " + String(decoding: value.error, as: UTF8.self)) }
        return value.text.trimmingCharacters(in: .newlines)
    }
    func register(_ client: RemoteEnvironmentClient) async throws -> RemoteWorkspaceTarget {
        let descriptor = try await client.discover(); try await client.trust(environmentID: descriptor.environmentID)
        _ = try await client.connect()
        let projectID = UUID(), threadID = UUID()
        #expect(try await client.command(.addProject(id: projectID, path: workspace.path, title: "Private remote files")).receipt.rejection == nil)
        #expect(try await client.command(.createThread(id: threadID, projectID: projectID, provider: .codex,
            title: "File tools only", model: "must-not-start", permission: .supervised)).receipt.rejection == nil)
        let snapshot = try await client.snapshot(), thread = try #require(snapshot.workspace.threads.first { $0.id == threadID })
        return try await client.bindWorkspace(.init(environmentID: descriptor.environmentID, projectID: projectID,
            threadID: threadID, configuration: .init(thread: thread)))
    }
    func installHeldCommitHook() async throws {
        let hooks = root.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let body = "#!/bin/sh\numask 077\nprintf '%s\\n' \"$$\" > \(Self.quote(root.appendingPathComponent("hook.pid").path))\nprintf '%s\\n' \"$PPID\" > \(Self.quote(root.appendingPathComponent("git.pid").path))\nprintf 'entered\\n' >> \(Self.quote(root.appendingPathComponent("hook-invocations.txt").path))\ni=0\nwhile [ ! -f \(Self.quote(root.appendingPathComponent("release-hook").path)) ] && [ \"$i\" -lt 1500 ]; do /bin/sleep 0.02; i=$((i+1)); done\n"
        let hook = hooks.appendingPathComponent("pre-commit")
        try body.write(to: hook, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try await git(["config", "core.hooksPath", hooks.path])
    }
    func releaseHook() { _ = FileManager.default.createFile(atPath: root.appendingPathComponent("release-hook").path, contents: Data(), attributes: [.posixPermissions: 0o600]) }
    func expectDrained() async throws {
        let hostPIDs = try String(contentsOf: root.appendingPathComponent("host-pids.txt"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        try await remoteWorkspaceEventually("owned native hosts to drain") { hostPIDs.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-provider-launch").path))
    }
    func retainFailure() { print("Synthetic remote file/Git acceptance retained at \(root.path)") }
    func remove() throws { try FileManager.default.removeItem(at: root) }
}

private func remoteWorkspaceEventually(_ detail: String, _ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(10)
    while try await !predicate() {
        guard ContinuousClock.now < end else { throw CoincideError("Remote file/Git acceptance did not reach: " + detail) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func remoteDocument(_ client: RemoteEnvironmentClient, target: RemoteWorkspaceTarget, path: String, allowMissing: Bool = false) async throws -> RemoteWorkspaceDocument {
    let response = try await client.readWorkspace(.init(target: target, query: .readFile(path: path, allowMissing: allowMissing, maxBytes: 2_000_000)))
    guard case .document(let document) = response.value else { throw CoincideError("Native host returned a different read result.") }
    return document
}
private func remoteGitStatus(_ client: RemoteEnvironmentClient, target: RemoteWorkspaceTarget) async throws -> GitSnapshot {
    let response = try await client.readWorkspace(.init(target: target, query: .gitStatus))
    guard case .git(let status) = response.value else { throw CoincideError("Native host returned a different Git result.") }
    return status
}
private func remoteFinished(_ client: RemoteEnvironmentClient, request: RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation {
    var operation = try await client.beginWorkspaceOperation(request)
    let end = ContinuousClock.now + .seconds(10)
    while operation.state == .accepted || operation.state == .running {
        guard ContinuousClock.now < end else { throw CoincideError("The owned remote mutation did not finish.") }
        try await Task.sleep(for: .milliseconds(10))
        operation = try #require(await client.workspaceOperation(request))
    }
    return operation
}

@Test(.timeLimit(.minutes(1)))
func remoteWorkspaceNativeHostFileRevisionsEscapeAndReplacedRootPreserveExactBytesWithoutReplay() async throws {
    let f = try await RemoteWorkspaceFixture.make(), client = f.client()
    do {
        let target = try await f.register(client)
        #expect(target.rootID != nil)
        let initial = try await remoteDocument(client, target: target, path: "README.md")
        let token = try #require(initial.revision)
        #expect(initial.contents == "baseline\n" && initial.exists && !initial.truncated)
        let text = "Remote 日本語 🌍\n"
        let save = RemoteWorkspaceMutationRequest(target: target, mutation: .saveFile(path: "README.md", contents: text, revision: token))
        let saved = try await remoteFinished(client, request: save)
        #expect(saved.state == .finished && saved.failure == nil && saved.request == save)
        #expect(try await remoteDocument(client, target: target, path: "README.md").contents == text)
        let stale = try await remoteFinished(client, request: .init(target: target, mutation: .saveFile(path: "README.md", contents: "Must not overwrite", revision: token)))
        #expect(stale.failure?.kind == .conflict)
        #expect(try Data(contentsOf: f.workspace.appendingPathComponent("README.md")) == Data(text.utf8))
        let missing = try await remoteDocument(client, target: target, path: "new literal.txt", allowMissing: true)
        #expect(!missing.exists && missing.revision == nil)
        let created = try await remoteFinished(client, request: .init(target: target, mutation: .createFile(path: "new literal.txt", contents: "created once\n")))
        #expect(created.state == .finished && created.failure == nil)
        let outside = f.root.appendingPathComponent("outside.txt"), outsideBytes = Data("OUTSIDE_UNCHANGED".utf8)
        try outsideBytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.workspace.appendingPathComponent("outside-link"), withDestinationURL: outside)
        for path in ["../outside.txt", outside.path, "outside-link", ".git/config"] {
            await #expect(throws: (any Error).self) { _ = try await remoteDocument(client, target: target, path: path) }
        }
        let outsideDirectory = f.root.appendingPathComponent("outside-directory")
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: f.workspace.appendingPathComponent("outside-directory-link"), withDestinationURL: outsideDirectory)
        for path in ["../escaped.txt", outsideDirectory.appendingPathComponent("escaped.txt").path, "outside-directory-link/escaped.txt", ".git/remote-injected"] {
            let denied = try await remoteFinished(client, request: .init(target: target, mutation: .createFile(path: path, contents: "Must stay confined")))
            #expect(denied.failure?.kind == .invalidRequest)
        }
        #expect(try Data(contentsOf: outside) == outsideBytes)
        #expect(!FileManager.default.fileExists(atPath: outsideDirectory.appendingPathComponent("escaped.txt").path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("escaped.txt").path))
        let moved = f.root.appendingPathComponent("original-workspace")
        try FileManager.default.moveItem(at: f.workspace, to: moved)
        try FileManager.default.createDirectory(at: f.workspace, withIntermediateDirectories: false)
        let replacement = Data("REPLACEMENT_UNCHANGED".utf8)
        try replacement.write(to: f.workspace.appendingPathComponent("README.md"))
        await #expect(throws: (any Error).self) { _ = try await remoteDocument(client, target: target, path: "README.md") }
        let replaced = try await remoteFinished(client, request: .init(target: target, mutation: .createFile(path: "unexpected.txt", contents: "Must not reach the replacement")))
        #expect(replaced.failure?.kind == .staleRoot)
        #expect(!FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("unexpected.txt").path))
        let before = try await client.workspaceOperation(save)
        #expect(before == saved, "Receipt lookup must precede stale-root validation and never execute the saved mutation.")
        _ = try await client.reconnect()
        #expect(try await client.workspaceOperation(save) == saved)
        #expect(try Data(contentsOf: moved.appendingPathComponent("README.md")) == Data(text.utf8))
        #expect(try Data(contentsOf: f.workspace.appendingPathComponent("README.md")) == replacement)
        await client.close(); try await f.expectDrained(); try f.remove()
    } catch { await client.close(); f.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteWorkspaceNativeHostStagesCommitsAndReadsExactLocalGitWithoutRepeatingFinishedOperations() async throws {
    let f = try await RemoteWorkspaceFixture.make(), client = f.client()
    do {
        let target = try await f.register(client), originalHead = try await f.git(["rev-parse", "HEAD"])
        let name = "literal 日本語\nfile.txt", contents = "Native remote Git content\n"
        let create = try await remoteFinished(client, request: .init(target: target, mutation: .createFile(path: name, contents: contents)))
        #expect(create.state == .finished && create.failure == nil)
        let changed = try await remoteGitStatus(client, target: target)
        #expect(changed.head == originalHead && changed.changes.contains { $0.path == name && $0.isUntracked })
        let stage = RemoteWorkspaceMutationRequest(target: target, mutation: .gitStage(paths: [name]))
        #expect(try await remoteFinished(client, request: stage).failure == nil)
        let staged = try await remoteGitStatus(client, target: target)
        #expect(staged.changes.contains { $0.path == name && $0.isStaged })
        let diff = try await client.readWorkspace(.init(target: target, query: .gitDiff(file: nil, staged: true)))
        guard case .diff(let patch) = diff.value else { throw CoincideError("Native host did not return the staged diff.") }
        #expect(patch.contains("+Native remote Git content"))
        let commit = RemoteWorkspaceMutationRequest(target: target, mutation: .gitCommit(message: "Explicit remote local commit"))
        let committed = try await remoteFinished(client, request: commit)
        #expect(committed.state == .finished && committed.failure == nil)
        let final = try await remoteGitStatus(client, target: target), head = try #require(final.head)
        #expect(head != originalHead && final.isClean)
        #expect(try await f.git(["show", "HEAD:" + name]) == contents.trimmingCharacters(in: .newlines))
        #expect(try await f.git(["rev-list", "--count", "HEAD"]) == "2")
        _ = try await client.reconnect()
        #expect(try await client.workspaceOperation(commit) == committed)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: commit.id)) {
            _ = try await client.beginWorkspaceOperation(commit)
        }
        let collision = RemoteWorkspaceMutationRequest(id: commit.id, target: target, mutation: .gitCommit(message: "Different exact bytes"))
        await #expect(throws: (any Error).self) { _ = try await client.workspaceOperation(collision) }
        #expect(try await f.git(["rev-parse", "HEAD"]) == head)
        #expect(try await f.git(["rev-list", "--count", "HEAD"]) == "2")
        #expect(try Data(contentsOf: f.workspace.appendingPathComponent(name)) == Data(contents.utf8))
        await client.close()
        // A fresh native host receives an explicit duplicate identity through
        // the production codec, independently of the client's local guard.
        let raw = try f.connection()
        do {
            let original = try RemoteEnvironmentProtocol.decode(RemoteWorkspaceOperation.self,
                from: await raw.request(RemoteEnvironmentProtocol.workspaceBeginMethod, params: RemoteEnvironmentProtocol.encode(commit)))
            #expect(original == committed)
            _ = try await raw.request(RemoteEnvironmentProtocol.closeMethod,
                params: RemoteEnvironmentProtocol.encode(RemoteEnvironmentSnapshotRequest(environmentID: target.environmentID)))
            await raw.close()
        } catch { await raw.close(); throw error }
        #expect(try await f.git(["rev-parse", "HEAD"]) == head)
        #expect(try await f.git(["rev-list", "--count", "HEAD"]) == "2")
        try await f.expectDrained(); try f.remove()
    } catch { await client.close(); f.retainFailure(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func remoteWorkspaceNativeHostCancelAndCloseInterruptHeldGitWithoutLateCommitOrReconnectReplay(closeHost: Bool) async throws {
    let f = try await RemoteWorkspaceFixture.make(), client = f.client()
    var reopened: RemoteEnvironmentClient?
    do {
        try await f.installHeldCommitHook()
        let target = try await f.register(client), before = try await f.git(["rev-parse", "HEAD"])
        try "staged work remains\n".write(to: f.workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        #expect(try await remoteFinished(client, request: .init(target: target, mutation: .gitStage(paths: ["README.md"]))).failure == nil)
        let request = RemoteWorkspaceMutationRequest(target: target, mutation: .gitCommit(message: "Held explicit commit"))
        _ = try await client.beginWorkspaceOperation(request)
        try await remoteWorkspaceEventually("private pre-commit hook entry") { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("hook-invocations.txt").path) }
        let gitPID = try #require(Int32(try String(contentsOf: f.root.appendingPathComponent("git.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let leased = try await client.snapshot(), leasedThread = try #require(leased.workspace.threads.first { $0.id == target.threadID })
        let heldPrompt = "Must not enter a conversation while its file mutation owns the workspace"
        let rejected = try await client.command(.submit(threadID: target.threadID, text: heldPrompt,
            expectedConfiguration: .init(thread: leasedThread)))
        #expect(rejected.receipt.rejection != nil, "The host must durably reject provider admission while the actual Git mutation is running.")
        let after = try await client.snapshot(), unchanged = try #require(after.workspace.threads.first { $0.id == target.threadID })
        #expect(unchanged.activeRun == nil && unchanged.queuedTurns.isEmpty && !unchanged.messages.contains { $0.role == .user && $0.text == heldPrompt })
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("unexpected-provider-launch").path))
        if !closeHost {
            let cancelled = try #require(await client.cancelWorkspaceOperation(request))
            #expect(cancelled.state == .uncertain && cancelled.failure?.kind == .interrupted)
            #expect(kill(gitPID, 0) == -1 && errno == ESRCH,
                    "Cancel acknowledgement must join the exact owned Git process before the connection is closed.")
        }
        await client.close()
        #expect(kill(gitPID, 0) == -1 && errno == ESRCH,
                "An acknowledged host close must leave no owned Git process running.")
        // The transport promises ownership of the exact Git child. Release this
        // explicitly owned bounded hook; no descendant-drain claim is inferred.
        f.releaseHook()
        let hookPID = try #require(Int32(try String(contentsOf: f.root.appendingPathComponent("hook.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await remoteWorkspaceEventually("private hook cleanup") { kill(hookPID, 0) == -1 && errno == ESRCH }
        #expect(try await f.git(["rev-parse", "HEAD"]) == before)
        let next = f.client(expected: target.environmentID); reopened = next; _ = try await next.connect()
        let recovered = try #require(await next.workspaceOperation(request))
        #expect(recovered.state == .uncertain && recovered.failure?.kind == .interrupted)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: request.id)) {
            _ = try await next.beginWorkspaceOperation(request)
        }
        #expect(try await f.git(["rev-list", "--count", "HEAD"]) == "1")
        #expect(try String(contentsOf: f.root.appendingPathComponent("hook-invocations.txt"), encoding: .utf8) == "entered\n")
        #expect(try String(contentsOf: f.workspace.appendingPathComponent("README.md"), encoding: .utf8) == "staged work remains\n")
        await next.close(); try await f.expectDrained(); try f.remove()
    } catch { f.releaseHook(); await reopened?.close(); await client.close(); f.retainFailure(); throw error }
}
