import Foundation
import Testing
@testable import CoincideCore

@discardableResult private func gitTest(_ root: URL, _ args: [String]) async throws -> String {
    let result = try await CommandRunner.run("git", ["-C", root.path] + args)
    guard result.status == 0 else { throw CoincideError("Fixture Git failed: " + String(decoding: result.error, as: UTF8.self)) }
    return result.text.trimmingCharacters(in: .newlines)
}
private func configureTestGit(_ root: URL) async throws {
    for (key, value) in [("user.name", "Coincide Test"), ("user.email", "test@example.invalid"), ("commit.gpgSign", "false"), ("tag.gpgSign", "false"), ("core.hooksPath", root.appendingPathComponent(".git/no-hooks").path)] {
        try await gitTest(root, ["config", "--local", key, value])
    }
}
private func writeGitFile(_ root: URL, _ name: String, _ value: String) throws {
    try value.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
private func gitCommit(_ root: URL, _ name: String, _ value: String) async throws {
    try writeGitFile(root, name, value)
    let git = GitService(root: root); try await git.stage([name]); try await git.commit(message: "Change " + name)
}

@Test func nativeGitInitializesAnUnbornBranchAndUnstagesModifiedInitialFilesWithoutLosingBytes() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let git = GitService(root: root)
    try await git.initialize(branch: "native/start")
    try await configureTestGit(root)
    var status = try await git.status()
    #expect(status.branch == "native/start" && status.isUnborn && !status.isDetached && status.isClean)
    #expect(status.ahead == nil && status.behind == nil && status.upstream == nil)
    let literal = ":(glob)*.txt"
    try writeGitFile(root, literal, "staged version\n"); try writeGitFile(root, "unrelated.txt", "leave unstaged\n")
    try await git.stage([literal])
    #expect(try await git.status().changes.first { $0.path == literal }?.isStaged == true)
    #expect(try await git.status().changes.first { $0.path == "unrelated.txt" }?.isUntracked == true)
    try writeGitFile(root, literal, "latest bytes\n")
    try await git.unstage([literal])
    #expect(try String(contentsOf: root.appendingPathComponent(literal), encoding: .utf8) == "latest bytes\n")
    #expect(try await git.status().changes.allSatisfy(\.isUntracked))
    try await git.stage([literal]); try await git.commit(message: "First native commit\n\nLiteral $(not-a-shell) and `text`.")
    status = try await git.status()
    #expect(!status.isUnborn && status.branch == "native/start" && status.changes.map(\.path) == ["unrelated.txt"])
    await #expect(throws: (any Error).self) { try await git.initialize() }
    #expect(try await git.status().branch == "native/start")
}

@Test func gitRepositoryRelativePathsWorkFromNestedProjectsIncludingRenamesAndNewlines() async throws {
    let parent = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("repository\n")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let git = GitService(root: root); try await git.initialize(); try await configureTestGit(root)
    try await gitCommit(root, "original name\n.txt", "one\n")
    let nested = root.appendingPathComponent("nested project")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let nestedGit = GitService(root: nested)
    try await gitTest(root, ["mv", "--", "original name\n.txt", "renamed \"file\"\n.txt"])
    var snapshot = try await nestedGit.status()
    #expect(snapshot.repositoryRoot.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
    #expect(snapshot.changes.count == 1 && snapshot.changes[0].previousPath == "original name\n.txt")
    #expect(snapshot.changes[0].path == "renamed \"file\"\n.txt")
    #expect(try await nestedGit.diff(file: snapshot.changes[0], staged: true).contains("rename to"))
    try await nestedGit.unstage(["original name\n.txt", "renamed \"file\"\n.txt"])
    snapshot = try await nestedGit.status()
    #expect(snapshot.changes.contains { $0.path == "renamed \"file\"\n.txt" && $0.isUntracked })
    #expect(try await nestedGit.diff(file: snapshot.changes.first { $0.isUntracked }).contains("+one"))
    try await nestedGit.stage(snapshot.changes.map(\.path))
    try await nestedGit.commit(message: "Native nested rename")
    #expect(try await git.status().isClean)
    for path in ["../outside.txt", "/etc/passwd", "nested project/../../outside", "bad\0path"] {
        await #expect(throws: (any Error).self) { try await nestedGit.stage([path]) }
    }
}

@Test func gitSnapshotParsesConflictSubmoduleTrackingAndFutureHeaders() throws {
    let input = "# branch.oid abcdef0123456789\0# branch.head feature/name\0# branch.upstream origin/main\0# branch.ab +12 -34\0# future.extension ignored\0" +
        "1 .M S.MU 160000 160000 160000 aaaa bbbb sub module\0" +
        "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflicted\nname\0" +
        "2 R. N... 100644 100644 100644 aaaa bbbb R100 new\tname\0old\tname\0? untracked\nfile\0"
    let snapshot = try GitService.parseSnapshot(Data(input.utf8), root: URL(fileURLWithPath: "/tmp"))
    #expect(snapshot.branch == "feature/name" && snapshot.upstream == "origin/main" && snapshot.ahead == 12 && snapshot.behind == 34)
    #expect(snapshot.hasConflicts && snapshot.changes.count == 4)
    #expect(snapshot.changes[0].worktreeStatus == "M" && snapshot.changes[1].isConflicted && !snapshot.changes[1].isStaged)
    #expect(snapshot.changes[2].previousPath == "old\tname")
    for invalid in ["", "# branch.head main\0", "# branch.oid (initial)\0", "# branch.oid aaa\0# branch.head main\0# branch.ab +1 -bad\0", "# branch.oid aaa\0# branch.head main\02 R. missing\0"] {
        #expect(throws: (any Error).self) { try GitService.parseSnapshot(Data(invalid.utf8), root: URL(fileURLWithPath: "/tmp")) }
    }
}

@Test func nativeBranchSwitchingPreservesEditsRejectsOptionsAndShowsDetachedHead() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let git = GitService(root: root); try await git.initialize(); try await configureTestGit(root)
    try await gitCommit(root, "file.txt", "main\n")
    try await gitTest(root, ["config", "branch.autoSetupMerge", "always"])
    try await git.createBranch("feature/native")
    #expect(try await git.upstream(for: "feature/native") == nil)
    try await gitCommit(root, "file.txt", "feature\n")
    try await git.checkout(branch: "main")
    try writeGitFile(root, "file.txt", "uncommitted\n")
    await #expect(throws: (any Error).self) { try await git.checkout(branch: "feature/native") }
    #expect(try await git.status().branch == "main")
    #expect(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8) == "uncommitted\n")
    for invalid in ["--force", "-", "bad..name", "@{-1}", "branch\nname"] {
        await #expect(throws: (any Error).self) { try await git.createBranch(invalid) }
    }
    #expect(try await git.branches().sorted() == ["feature/native", "main"])
    try await gitTest(root, ["checkout", "--detach", "HEAD"])
    let detached = try await git.status()
    #expect(detached.isDetached && !detached.isUnborn && detached.branch == "HEAD" && detached.displayBranch.hasPrefix("Detached at "))
    await #expect(throws: (any Error).self) { try await git.pull(branch: "main") }
}

private struct GitRemoteFixture {
    let root: URL, remote: URL, first: URL, second: URL
    static func create() async throws -> Self {
        let root = try temporaryWorkspace()
        do {
            let remote = root.appendingPathComponent("remote.git"), first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
            try await gitTest(root, ["init", "--bare", "--initial-branch=main", remote.path])
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            try await GitService(root: first).initialize(); try await configureTestGit(first)
            try await gitCommit(first, "readme.txt", "initial\n")
            try await gitTest(first, ["remote", "add", "origin", remote.path])
            try await GitService(root: first).push(branch: "main", remote: "origin", remoteBranch: "main", setUpstream: true)
            try await gitTest(root, ["clone", "--", remote.path, second.path]); try await configureTestGit(second)
            return .init(root: root, remote: remote, first: first, second: second)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
}

@Test func nativeFetchPullPushAndTrackingWorkWithRealLocalRemotesAndDivergenceIsPreserved() async throws {
    let fixture = try await GitRemoteFixture.create(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = GitService(root: fixture.first), second = GitService(root: fixture.second)
    #expect(try await first.status().upstream == "origin/main")
    #expect(try await first.upstream(for: "main") == .init(remote: "origin", branch: "main"))
    try await gitCommit(fixture.second, "readme.txt", "remote update\n")
    try await second.push(branch: "main", remote: "origin", remoteBranch: "main", setUpstream: false)
    try await first.fetch(remote: "origin")
    let behind = try await first.status(); #expect(behind.ahead == 0 && behind.behind == 1)
    for (key, value) in [("pull.rebase", "true"), ("pull.squash", "true"), ("rebase.autoStash", "true"), ("merge.autoStash", "true")] { try await gitTest(fixture.first, ["config", key, value]) }
    try await first.pull(branch: "main")
    #expect(try String(contentsOf: fixture.first.appendingPathComponent("readme.txt"), encoding: .utf8) == "remote update\n")
    let current = try await first.status(); #expect(current.ahead == 0 && current.behind == 0)
    try writeGitFile(fixture.first, "local unsaved.txt", "preserve")
    await #expect(throws: (any Error).self) { try await first.pull(branch: "main") }
    #expect(try String(contentsOf: fixture.first.appendingPathComponent("local unsaved.txt"), encoding: .utf8) == "preserve")
    try await gitCommit(fixture.first, "local unsaved.txt", "local commit\n")
    try await gitCommit(fixture.second, "other.txt", "remote diverged\n")
    try await second.push(branch: "main", remote: "origin", remoteBranch: "main", setUpstream: false)
    let before = try await gitTest(fixture.first, ["rev-parse", "HEAD"])
    await #expect(throws: (any Error).self) { try await first.pull(branch: "main") }
    #expect(try await gitTest(fixture.first, ["rev-parse", "HEAD"]) == before)
    let diverged = try await first.status(); #expect(diverged.ahead == 1 && diverged.behind == 1)
    let remoteBefore = try await gitTest(fixture.remote, ["rev-parse", "main"])
    await #expect(throws: (any Error).self) { try await first.push(branch: "main", remote: "origin", remoteBranch: "main", setUpstream: false) }
    #expect(try await gitTest(fixture.remote, ["rev-parse", "main"]) == remoteBefore)
    try await second.createBranch("remote/topic")
    try await gitCommit(fixture.second, "topic.txt", "topic\n")
    try await second.push(branch: "remote/topic", remote: "origin", remoteBranch: "remote/topic", setUpstream: true)
    try await first.fetch(remote: "origin")
    let branch = try #require(try await first.branchDetails().first { $0.ref == "refs/remotes/origin/remote/topic" })
    #expect(branch.isRemote && branch.name == "origin/remote/topic")
    #expect(try await first.branchDetails().allSatisfy { $0.ref != "refs/remotes/origin/HEAD" })
    try await first.createBranch("local/topic", tracking: branch.ref)
    let tracking = try await first.status(); #expect(tracking.branch == "local/topic" && tracking.upstream == "origin/remote/topic")
    await #expect(throws: (any Error).self) { try await first.push(branch: "main", remote: "origin", remoteBranch: "main", setUpstream: false) }
}

@Test func nativePushIgnoresMirrorForceMatchingAndTagPropagationConfiguration() async throws {
    let fixture = try await GitRemoteFixture.create(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let git = GitService(root: fixture.first)
    try await git.createBranch("only-this")
    try await gitCommit(fixture.first, "only.txt", "publish\n")
    try await gitTest(fixture.first, ["branch", "unrelated"])
    try await gitTest(fixture.first, ["tag", "-a", "private-tag", "-m", "not requested"])
    for (key, value) in [("remote.origin.mirror", "true"), ("remote.origin.push", "+refs/heads/*:refs/heads/*"), ("push.default", "matching"), ("push.followTags", "true")] { try await gitTest(fixture.first, ["config", key, value]) }
    try await git.push(branch: "only-this", remote: "origin", remoteBranch: "published", setUpstream: true)
    let refs = try await gitTest(fixture.remote, ["for-each-ref", "--format=%(refname)"])
    #expect(refs.split(separator: "\n").sorted() == ["refs/heads/main", "refs/heads/published"])
    #expect(try await git.upstream(for: "only-this") == .init(remote: "origin", branch: "published"))
    // Explicit non-force also rejects replacing an existing, unrelated destination commit.
    try await GitService(root: fixture.second).createBranch("divergent")
    try await gitCommit(fixture.second, "second.txt", "different\n")
    try await gitTest(fixture.second, ["push", "--force", "--", "origin", "refs/heads/divergent:refs/heads/published"])
    let remoteBefore = try await gitTest(fixture.remote, ["rev-parse", "published"])
    await #expect(throws: (any Error).self) { try await git.push(branch: "only-this", remote: "origin", remoteBranch: "published", setUpstream: false) }
    #expect(try await gitTest(fixture.remote, ["rev-parse", "published"]) == remoteBefore)
}

@Test func gitNetworkErrorsRemoveCredentialsFromRemoteURLs() {
    let message = "fatal: unable to access 'https://username:secret-value@example.invalid/repo.git?access_token=secret-query#private': failed\nssh://git:password@example.invalid/repo"
    let result = GitService.redactURLs(message)
    #expect(result.contains("https://example.invalid/repo.git") && result.contains("ssh://example.invalid/repo"))
    for secret in ["username", "secret-value", "access_token", "secret-query", "private", "password"] { #expect(!result.contains(secret)) }
}

@Test func realGitConflictsStayVisibleUntilAResolutionIsStaged() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let git = GitService(root: root); try await git.initialize(); try await configureTestGit(root)
    try await gitCommit(root, "conflict.txt", "base\n")
    try await git.createBranch("other"); try await gitCommit(root, "conflict.txt", "other\n")
    try await git.checkout(branch: "main"); try await gitCommit(root, "conflict.txt", "main\n")
    let merge = try await CommandRunner.run("git", ["-C", root.path, "merge", "--no-edit", "other"])
    #expect(merge.status != 0)
    let conflicted = try await git.status()
    #expect(conflicted.hasConflicts && conflicted.changes.count == 1 && conflicted.changes[0].status == "UU" && !conflicted.changes[0].isStaged)
    await #expect(throws: (any Error).self) { try await git.commit(message: "Must not commit unresolved conflict") }
    try writeGitFile(root, "conflict.txt", "resolved\n"); try await git.stage(["conflict.txt"])
    #expect(try await git.status().hasConflicts == false)
    try await git.commit(message: "Native conflict resolution")
    #expect(try await git.status().isClean)
}

@Test func nativePushHonorsPrePushHooksAndCancellationDoesNotPublish() async throws {
    let fixture = try await GitRemoteFixture.create(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let hooks = fixture.root.appendingPathComponent("hooks"), marker = fixture.root.appendingPathComponent("hook-started")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    try await gitTest(fixture.first, ["config", "core.hooksPath", hooks.path])
    let hook = hooks.appendingPathComponent("pre-push")
    try "#!/bin/sh\nprintf 'blocked by native test hook' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let git = GitService(root: fixture.first)
    try await git.createBranch("hooked")
    await #expect(throws: (any Error).self) { try await git.push(branch: "hooked", remote: "origin", remoteBranch: "hooked", setUpstream: true) }
    #expect(try await git.upstream(for: "hooked") == nil)
    try "#!/bin/sh\nprintf 'ready' > '\(marker.path)'\nexec /usr/bin/perl -e 'sleep 10'\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let task = Task { try await git.push(branch: "hooked", remote: "origin", remoteBranch: "hooked", setUpstream: true) }
    let deadline = ContinuousClock.now + .seconds(5)
    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(FileManager.default.fileExists(atPath: marker.path))
    let start = ContinuousClock.now; task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ContinuousClock.now - start < .seconds(3))
    #expect(try await gitTest(fixture.remote, ["for-each-ref", "--format=%(refname)"]) == "refs/heads/main")
    #expect(try await git.upstream(for: "hooked") == nil)
}

private actor GitGateLog {
    var entries: [String] = []
    func add(_ value: String) { entries.append(value) }
}
@Test func gitMutationQueueSerializesWorkAndCancellationNeverRunsAWaitingOperation() async throws {
    let gate = GitOperationGate(), log = GitGateLog()
    let (started, startedSink) = AsyncStream<Void>.makeStream(), (release, releaseSink) = AsyncStream<Void>.makeStream()
    let first = Task {
        try await gate.perform(key: "repository") {
            await log.add("first started"); startedSink.yield(())
            for await _ in release { break }
            await log.add("first finished")
        }
    }
    for await _ in started { break }
    let cancelled = Task { try await gate.perform(key: "repository") { await log.add("cancelled operation ran") } }
    let next = Task { try await gate.perform(key: "repository") { await log.add("next ran") } }
    // Another repository does not wait on the first repository's lock.
    try await gate.perform(key: "different repository") { await log.add("independent ran") }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await log.entries == ["first started", "independent ran"])
    releaseSink.yield(()); try await first.value; try await next.value
    #expect(await log.entries == ["first started", "independent ran", "first finished", "next ran"])
    startedSink.finish(); releaseSink.finish()
    try await gate.perform(key: "repository") { await log.add("lock released") }
    #expect(await log.entries.last == "lock released")
}

@Test func remoteNamesContainingEqualsStayLiteralAndMissingUpstreamCountsRemainUnknown() async throws {
    let fixture = try await GitRemoteFixture.create(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let git = GitService(root: fixture.first), remote = "mirror=destination"
    try await gitTest(fixture.first, ["remote", "add", remote, fixture.remote.path])
    try await gitTest(fixture.first, ["config", "remote.\(remote).mirror", "true"])
    try await git.push(branch: "main", remote: remote, remoteBranch: "native=branch", setUpstream: true)
    #expect(try await git.upstream(for: "main") == .init(remote: remote, branch: "native=branch"))
    try await gitTest(fixture.first, ["update-ref", "-d", "refs/remotes/\(remote)/native=branch"])
    let snapshot = try await git.status()
    #expect(snapshot.upstream == remote + "/native=branch" && snapshot.ahead == nil && snapshot.behind == nil)
}
