import Foundation
import Testing
@testable import CoincideCore

func temporaryWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func databasePersistsProjectionAndEventAcrossConnections() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite")
    let first = try WorkspaceDatabase(url: url)
    var snapshot = WorkspaceSnapshot()
    let project = WorkspaceProject(path: root.path); snapshot.projects = [project]
    var thread = CodingThread(project: project); thread.messages = [.init(role: .user, text: "Keep 🌍 and quotes '")]
    snapshot.threads = [thread]
    try await first.save(snapshot, event: "thread.created")
    let second = try WorkspaceDatabase(url: url)
    #expect(try await second.load() == snapshot)
    #expect(try await second.eventCount() == 1)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
        #expect(try FileManager.default.attributesOfItem(atPath: url.path + suffix)[.posixPermissions] as? Int == 0o600)
    }
}

@Test func restartMarksOnlyActiveTurnsInterrupted() {
    var snapshot = WorkspaceSnapshot()
    let project = WorkspaceProject(path: "/tmp")
    for state in [ThreadState.running, .awaitingApproval, .idle, .failed] {
        var thread = CodingThread(project: project); thread.state = state; snapshot.threads.append(thread)
    }
    snapshot.recoverInterruptedWork()
    #expect(snapshot.threads.map(\.state) == [.interrupted, .interrupted, .idle, .failed])
    #expect(snapshot.threads[0].messages.count == 1)
    snapshot.recoverInterruptedWork(); #expect(snapshot.threads[0].messages.count == 1)
}

@Test func fileTraversalSymlinkEscapeAndConflictAreRejected() throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let outside = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: outside) }
    let files = WorkspaceFiles(root: root)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    #expect(throws: (any Error).self) { try files.resolve("../secret") }
    #expect(throws: (any Error).self) { try files.resolve("escape/secret") }
    #expect(throws: (any Error).self) { try files.resolve("/etc/passwd") }
    try "original".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try files.write("file.txt", text: "edited", expectedContents: "original")
    #expect(try files.read("file.txt") == "edited")
    #expect(throws: (any Error).self) { try files.write("file.txt", text: "overwrite", expectedContents: "original") }
    #expect(try files.read("file.txt") == "edited")
}

@Test func nulDelimitedGitStatusPreservesRenameAndNewlines() throws {
    let value = Data("R  new name.txt\0old name.txt\0?? a\nb.txt\0 M quotes\".swift\0".utf8)
    let files = try GitService.parseStatus(value)
    #expect(files.count == 3)
    #expect(files[0].path == "new name.txt"); #expect(files[0].previousPath == "old name.txt")
    #expect(files[1].path == "a\nb.txt"); #expect(files[1].isUntracked)
    #expect(files[2].worktreeStatus == "M")
}

@Test func gitWorktreeStageCommitAndDiffUseRealRepository() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let worktree = root.appendingPathComponent("separate tree")
    for args in [["init", "-b", "main"], ["config", "user.name", "Coincide Test"], ["config", "user.email", "test@example.invalid"]] {
        let result = try await CommandRunner.run("git", args, cwd: root); #expect(result.status == 0)
    }
    let git = GitService(root: root)
    try "first\n".write(to: root.appendingPathComponent("name with spaces.txt"), atomically: true, encoding: .utf8)
    try await git.stage(["name with spaces.txt"]); try await git.commit(message: "initial")
    try "second\n".write(to: root.appendingPathComponent("name with spaces.txt"), atomically: true, encoding: .utf8)
    let status = try await git.status(); #expect(status.branch == "main"); #expect(status.changes.count == 1)
    #expect(try await git.diff(file: status.changes[0]).contains("+second"))
    try await git.stage(["name with spaces.txt"])
    #expect(try await git.status().changes[0].isStaged)
    try await git.unstage(["name with spaces.txt"])
    #expect(try await git.status().changes[0].isStaged == false)
    try await git.createWorktree(at: worktree, branch: "coincide/test")
    #expect(try await GitService(root: worktree).status().branch == "coincide/test")
    #expect(try await git.branches().contains("coincide/test"))
    #expect(try String(contentsOf: worktree.appendingPathComponent("name with spaces.txt"), encoding: .utf8) == "first\n")
}
