import Foundation
import Darwin
import Testing
@testable import CoincideCore

@discardableResult private func reviewGit(_ root: URL, _ args: [String]) async throws -> String {
    let result = try await CommandRunner.run("git", ["-C", root.path] + args)
    guard result.status == 0 else { throw CoincideError("Fixture Git failed: " + String(decoding: result.error, as: UTF8.self)) }
    return result.text.trimmingCharacters(in: .newlines)
}
private func reviewWrite(_ root: URL, _ name: String, _ value: String) throws {
    let file = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try value.write(to: file, atomically: true, encoding: .utf8)
}
private func reviewCommit(_ root: URL, _ name: String, _ value: String, message: String? = nil) async throws {
    try reviewWrite(root, name, value)
    try await reviewGit(root, ["add", "--", name]); try await reviewGit(root, ["commit", "-q", "-m", message ?? "Change " + name])
}

/// A local bare remote plus two clones; nothing leaves the temporary directory.
struct GitReviewRemoteFixture {
    let root: URL, remote: URL, first: URL, second: URL, hooks: URL
    static func create() async throws -> Self {
        let root = try temporaryWorkspace()
        do {
            let remote = root.appendingPathComponent("remote.git"), first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
            let hooks = root.appendingPathComponent("hooks")
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            try await reviewGit(root, ["init", "--bare", "--initial-branch=main", remote.path])
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            try await reviewGit(first, ["init", "--initial-branch=main"])
            for repository in [first] { try await configure(repository, hooks: hooks) }
            try await reviewCommit(first, "readme.txt", "initial\n")
            try await reviewGit(first, ["remote", "add", "origin", remote.path])
            try await reviewGit(first, ["push", "-q", "--set-upstream", "origin", "main"])
            try await reviewGit(first, ["remote", "set-head", "origin", "main"])
            try await reviewGit(root, ["clone", "-q", "--", remote.path, second.path]); try await configure(second, hooks: hooks)
            return .init(root: root, remote: remote, first: first, second: second, hooks: hooks)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    static func configure(_ repository: URL, hooks: URL) async throws {
        for (key, value) in [("user.name", "Coincide Test"), ("user.email", "test@example.invalid"), ("commit.gpgSign", "false"), ("tag.gpgSign", "false"), ("core.hooksPath", hooks.path)] {
            try await reviewGit(repository, ["config", "--local", key, value])
        }
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1))) func branchDiffIncludesCommittedUncommittedAndUntrackedWorkSinceTheMergeBase() async throws {
    let f = try await GitReviewRemoteFixture.create(); defer { f.cleanup() }
    let git = GitService(root: f.first)
    try await git.createBranch("feature/review")
    try await reviewCommit(f.first, "feature.swift", "let feature = 1\n")
    try reviewWrite(f.first, "readme.txt", "initial\nedited but uncommitted\n")
    try reviewWrite(f.first, "notes/new file.md", "untracked\n")
    // A commit only on the base must not appear in the branch review.
    try await reviewCommit(f.second, "base-only.txt", "base\n")
    try await reviewGit(f.second, ["push", "-q", "origin", "main"])
    try await git.fetch(remote: "origin")
    let diff = try await git.branchDiff(baseRef: "origin/main")
    let parsed = UnifiedDiff.parse(diff.patch, truncated: diff.truncated)
    #expect(Set(parsed.files.map(\.path)) == ["feature.swift", "readme.txt", "notes/new file.md"])
    #expect(parsed.files.first { $0.path == "notes/new file.md" }?.status == .added)
    #expect(!diff.truncated && diff.omittedUntracked.isEmpty && diff.baseRef == "origin/main")
    let currentHead = try await reviewGit(f.first, ["rev-parse", "HEAD"])
    #expect(diff.mergeBase != diff.baseCommit && diff.headCommit == currentHead)
    // A local base gives the same work; whitespace-only edits can be hidden.
    try reviewWrite(f.first, "readme.txt", "initial   \nedited but uncommitted\n")
    let strict = UnifiedDiff.parse(try await git.branchDiff(baseRef: "main").patch)
    let relaxed = UnifiedDiff.parse(try await git.branchDiff(baseRef: "main", ignoreWhitespace: true).patch)
    #expect(strict.files.first { $0.path == "readme.txt" }?.deletions == 1)
    #expect(relaxed.files.first { $0.path == "readme.txt" }?.deletions == 0 && relaxed.files.first { $0.path == "readme.txt" }?.additions == 1)
    // Bounded output and rejected references.
    let tiny = try await git.branchDiff(baseRef: "main", maxBytes: 1_024)
    #expect(tiny.patch.utf8.count <= 1_024)
    try reviewWrite(f.first, "large.txt", String(repeating: "line of text\n", count: 400))
    let bounded = try await git.branchDiff(baseRef: "main", maxBytes: 2_048)
    #expect(bounded.truncated && bounded.patch.utf8.count <= 2_048)
    for invalid in ["--output=/tmp/x", "", "missing-branch", "main\nother"] {
        await #expect(throws: (any Error).self) { _ = try await git.branchDiff(baseRef: invalid) }
    }
}

@Test(.timeLimit(.minutes(1))) func defaultBranchCommitCountCatalogAndSingleBranchFetchUseExplicitRefs() async throws {
    let f = try await GitReviewRemoteFixture.create(); defer { f.cleanup() }
    let git = GitService(root: f.first)
    #expect(try await git.defaultBranch() == GitDefaultBranch(name: "main", remoteRef: "refs/remotes/origin/main"))
    try await git.createBranch("feature/catalog")
    try await reviewCommit(f.first, "a.txt", "a\n"); try await reviewCommit(f.first, "b.txt", "b\n")
    #expect(try await git.commitCount(from: "refs/remotes/origin/main") == 2)
    #expect(try await git.commitCount(from: "no-such-ref") == nil)
    let worktree = f.root.appendingPathComponent("linked")
    try await reviewGit(f.first, ["worktree", "add", "-q", "-b", "elsewhere", worktree.path])
    let catalog = try await git.branchCatalog()
    #expect(catalog.current?.name == "feature/catalog" && catalog.defaultBranch?.name == "main")
    let elsewhere = try #require(catalog.locals.first { $0.name == "elsewhere" })
    #expect(catalog.otherWorktree(for: elsewhere).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == worktree.resolvingSymlinksInPath().path)
    #expect(catalog.otherWorktree(for: try #require(catalog.current)) == nil)
    let remote = try #require(catalog.remotes.first { $0.name == "origin/main" })
    #expect(remote.remote == "origin" && remote.localName == "main" && remote.committedAt != nil)
    #expect(!catalog.entries.contains { $0.ref == "refs/remotes/origin/HEAD" })
    let ranked = GitBranchSearch.rank(catalog.entries, query: "cat", defaultBranch: "main")
    #expect(ranked.first?.name == "feature/catalog")
    #expect(GitBranchSearch.rank(catalog.entries, query: "", defaultBranch: "main").prefix(2).map(\.name) == ["feature/catalog", "main"])
    #expect(GitBranchSearch.rank(catalog.entries, query: "zzz").isEmpty)
    // Start from remote: only the named branch is fetched into its tracking ref.
    try await reviewCommit(f.second, "remote.txt", "remote\n")
    try await reviewGit(f.second, ["push", "-q", "origin", "main"])
    try await reviewGit(f.second, ["push", "-q", "origin", "main:other"])
    let fetched = try await git.fetch(remote: "origin", branch: "main")
    #expect(fetched == (try await reviewGit(f.second, ["rev-parse", "HEAD"])))
    #expect(try await reviewGit(f.first, ["rev-parse", "refs/remotes/origin/main"]) == fetched)
    #expect(try await reviewGit(f.first, ["for-each-ref", "refs/remotes/origin/other"]).isEmpty)
    await #expect(throws: (any Error).self) { try await git.fetch(remote: "--upload-pack=x", branch: "main") }
    await #expect(throws: (any Error).self) { try await git.fetch(remote: "origin", branch: "..bad") }
}

@Test(.timeLimit(.minutes(1))) func streamingCommitDeliversSanitizedHookOutputAndCommitsOnlyTheChosenPaths() async throws {
    let f = try await GitReviewRemoteFixture.create(); defer { f.cleanup() }
    let hook = f.hooks.appendingPathComponent("pre-commit")
    try "#!/bin/sh\nprintf '\\033[32mlint ok\\033[0m https://user:secret@example.invalid/x\\n' >&2\necho 'hook stdout line'\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let git = GitService(root: f.first)
    try reviewWrite(f.first, "chosen.txt", "chosen\n"); try reviewWrite(f.first, "other.txt", "other\n")
    try await git.stage(["chosen.txt", "other.txt"])
    final class Lines: @unchecked Sendable { let lock = NSLock(); var values: [String] = []; func add(_ v: String) { lock.lock(); values.append(v); lock.unlock() } }
    let lines = Lines()
    let head = try await git.commit(message: "Only chosen\n\nBody", only: ["chosen.txt"]) { lines.add($0) }
    #expect(head == (try await reviewGit(f.first, ["rev-parse", "HEAD"])))
    #expect(try await reviewGit(f.first, ["show", "--name-only", "--format=", "HEAD"]) == "chosen.txt")
    #expect(try await git.status().changes.first { $0.path == "other.txt" }?.isStaged == true)
    #expect(lines.values.contains("hook stdout line") || lines.values.contains { $0.contains("hook stdout line") })
    let lint = try #require(lines.values.first { $0.contains("lint ok") })
    #expect(!lint.contains("\u{1B}") && !lint.contains("secret") && !lint.contains("user:"))
    try "#!/bin/sh\necho 'refusing commit' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
    do { _ = try await git.commit(message: "Blocked", onOutput: { _ in }); Issue.record("A failing hook must stop the commit.") }
    catch { #expect(error.localizedDescription.contains("refusing commit")) }
    await #expect(throws: (any Error).self) { _ = try await git.commit(message: "  ", onOutput: { _ in }) }
    await #expect(throws: (any Error).self) { _ = try await git.commit(message: "x", only: ["../escape"], onOutput: { _ in }) }
}

private actor GitStreamDrainObservation {
    private(set) var finished = false
    func finish() { finished = true }
}
private func gitStreamDrainWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private Git stream drain boundary was not reached.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["limit", "timeout", "cancel", "input-error"])
func streamingGitKeepsItsOperationScopeUntilTheExactChildAndReadersDrain(mode: String) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("private-git-peer.py"), pidFile = root.appendingPathComponent("pid")
    let release = root.appendingPathComponent("release"), terminating = root.appendingPathComponent("terminating")
    try #"""
    import os, pathlib, signal, sys, time
    root = pathlib.Path(sys.argv[1])
    mode = sys.argv[2]
    def stopping(*_):
        (root / "terminating").write_text("received")
    signal.signal(signal.SIGTERM, stopping)
    if mode == "input-error":
        os.close(0)
    (root / "pid").write_text(str(os.getpid()))
    if mode == "limit":
        os.write(1, b"x" * 4096)
    while not (root / "release").exists():
        time.sleep(0.01)
    os.write(1, b"drained-final-output\n")
    """#.write(to: script, atomically: true, encoding: .utf8)
    let observation = GitStreamDrainObservation()
    let input = mode == "input-error" ? Data(repeating: 120, count: 8_388_608) : nil
    let task = Task { () -> Result<GitStreamingCommand.Result, any Error> in
        let result: Result<GitStreamingCommand.Result, any Error>
        do {
            result = .success(try await GitOperationGate.shared.perform(key: root.path) {
                try await GitStreamingCommand.run(arguments: [script.path, root.path, mode], environment: ["PATH": "/usr/bin:/bin"],
                    input: input, timeout: mode == "timeout" ? .seconds(1) : .seconds(20), maxOutput: 1_024,
                    executable: URL(fileURLWithPath: "/usr/bin/python3"))
            })
        } catch { result = .failure(error) }
        await observation.finish()
        return result
    }
    var successor: Task<Bool, any Error>?
    do {
        try await gitStreamDrainWait { FileManager.default.fileExists(atPath: pidFile.path) }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(Int32(pidText))
        if mode == "cancel" { task.cancel() }
        try await gitStreamDrainWait { FileManager.default.fileExists(atPath: terminating.path) }
        #expect(await observation.finished == false, "Sending TERM cannot release the operation before native exit and pipe drainage.")
        successor = Task {
            try await GitOperationGate.shared.perform(key: root.path) {
                kill(pid, 0) == -1 && errno == ESRCH
            }
        }
        try Data().write(to: release)
        let result = await task.value
        switch result {
        case .success(let value): #expect(mode == "limit" && value.truncated)
        case .failure(let error):
            #expect(mode != "limit")
            if mode == "cancel" { #expect(error is CancellationError) }
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        let successorObservedDrain = try await successor?.value
        #expect(successorObservedDrain == true, "The next mutation in the same scope must observe the old owned child already gone.")
    } catch {
        try? Data().write(to: release)
        task.cancel(); _ = await task.value; _ = try? await successor?.value
        throw error
    }
}
