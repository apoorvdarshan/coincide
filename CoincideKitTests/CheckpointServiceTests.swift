import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct CheckpointServiceTests {
    private let threadID = UUID()
    private let turnID = UUID()

    private func makeService(_ store: AppStore? = nil) throws -> (CheckpointService, URL) {
        let directory = try TestRepository.makeDirectory("checkpoints")
        return (CheckpointService(store: store, directory: directory), directory)
    }

    /// A repository with tracked files, a staged edit and an ignored file.
    private func makeRepository() async throws -> TestRepository {
        let repository = try await TestRepository.make()
        try repository.write(".gitignore", "build/\n")
        try repository.write("edit.txt", "one\ntwo\n")
        try repository.write("remove.txt", "bye\n")
        try await repository.git("add", ".")
        try await repository.git("commit", "-q", "-m", "files")
        try repository.write("staged.txt", "staged\n")
        try await repository.git("add", "staged.txt")
        try repository.write("build/cache.bin", "cache\n")
        return repository
    }

    /// What the agent does during the turn.
    private func runTurn(in repository: TestRepository) throws {
        try repository.write("edit.txt", "one\ntwo\nthree\n")
        try repository.write("created.txt", "new\n")
        try repository.delete("remove.txt")
        try repository.write("build/output.bin", "made during the turn\n")
    }

    @Test func capturesATurnWithoutTouchingIndexBranchesOrStash() async throws {
        let repository = try await makeRepository()
        let (checkpoints, _) = try makeService()
        let indexBefore = try await repository.git("ls-files", "--stage")
        let refsBefore = try await repository.git("for-each-ref", "--format=%(refname)", "refs/heads", "refs/tags")

        await checkpoints.captureBeforeTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)
        try runTurn(in: repository)
        await checkpoints.captureAfterTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)

        let files = Dictionary(
            uniqueKeysWithValues: checkpoints.changedFiles(threadID: threadID, userItemID: turnID).map { ($0.path, $0) })
        #expect(Set(files.keys) == ["edit.txt", "created.txt", "remove.txt"])
        #expect(files["edit.txt"]?.status == .modified && files["edit.txt"]?.additions == 1)
        #expect(files["created.txt"]?.status == .added)
        #expect(files["remove.txt"]?.status == .deleted)

        let patch = try #require(await checkpoints.turnDiff(threadID: threadID, userItemID: turnID))
        #expect(patch.contains("+three"))
        #expect(patch.contains("diff --git a/created.txt b/created.txt"))
        #expect(!patch.contains("staged.txt"))

        #expect(try await repository.git("ls-files", "--stage") == indexBefore)
        #expect(try await repository.git("diff", "--cached", "--name-only") == "staged.txt\n")
        #expect(try await repository.git("for-each-ref", "--format=%(refname)", "refs/heads", "refs/tags") == refsBefore)
        #expect(try await repository.git("stash", "list").isEmpty)
        #expect(try await repository.git("status", "--porcelain").contains("?? created.txt"))
        let hidden = try await repository.git("for-each-ref", "--format=%(refname)", "refs/coincide")
        #expect(hidden.contains("/\(turnID.uuidString.lowercased())/before"))
        #expect(hidden.contains("/\(turnID.uuidString.lowercased())/after"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: repository.url.appendingPathComponent(".git").path)
        #expect(!leftovers.contains { $0.hasPrefix("coincide-checkpoint-index") })
    }

    @Test func restoresTheWorkingTreeToBeforeTheTurn() async throws {
        let repository = try await makeRepository()
        let (checkpoints, _) = try makeService()
        await checkpoints.captureBeforeTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)
        try runTurn(in: repository)
        await checkpoints.captureAfterTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)
        #expect(checkpoints.canRestore(threadID: threadID, userItemID: turnID))

        try await checkpoints.restore(threadID: threadID, toBefore: turnID)

        #expect(repository.read("edit.txt") == "one\ntwo\n")
        #expect(repository.read("remove.txt") == "bye\n")
        #expect(!repository.exists("created.txt"))
        #expect(repository.read("staged.txt") == "staged\n")
        // Ignored files are left alone.
        #expect(repository.exists("build/output.bin") && repository.exists("build/cache.bin"))
        #expect(try await repository.git("status", "--porcelain").contains("staged.txt"))
        // The restored turn and anything after it are gone.
        #expect(checkpoints.checkpoint(threadID: threadID, userItemID: turnID) == nil)
        #expect(try await repository.git("for-each-ref", "--format=%(refname)", "refs/coincide").isEmpty)
        #expect(!checkpoints.canRestore(threadID: threadID, userItemID: turnID))
    }

    @Test func showsTheChangesOfARunningTurn() async throws {
        let repository = try await makeRepository()
        let (checkpoints, _) = try makeService()
        await checkpoints.captureBeforeTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)
        #expect(checkpoints.changedFiles(threadID: threadID, userItemID: turnID).isEmpty)
        try repository.write("edit.txt", "one\nTWO\n")
        let patch = try #require(await checkpoints.turnDiff(threadID: threadID, userItemID: turnID))
        #expect(patch.contains("-two") && patch.contains("+TWO"))
    }

    @Test func keepsCheckpointsAcrossLaunches() async throws {
        let repository = try await makeRepository()
        let (checkpoints, directory) = try makeService()
        await checkpoints.captureBeforeTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)
        try runTurn(in: repository)
        await checkpoints.captureAfterTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)

        let reloaded = CheckpointService(directory: directory)
        let checkpoint = try #require(reloaded.checkpoint(threadID: threadID, userItemID: turnID))
        #expect(checkpoint.isComplete)
        #expect(checkpoint.cwd == repository.url.path)
        #expect(reloaded.changedFiles(threadID: threadID, userItemID: turnID).count == 3)
        #expect(await reloaded.turnDiff(threadID: threadID, userItemID: turnID)?.contains("+three") == true)

        await reloaded.deleteCheckpoints(threadID: threadID)
        #expect(reloaded.checkpoints(threadID: threadID).isEmpty)
        #expect(try await repository.git("for-each-ref", "refs/coincide").isEmpty)
    }

    @Test func leavesOutFilesAMergeBroughtIn() async throws {
        let repository = try await makeRepository()
        try await repository.git("checkout", "-q", "-b", "upstream")
        try repository.write("upstream.txt", "from upstream\n")
        try await repository.git("add", "upstream.txt")
        try await repository.git(
            "commit", "-q", "-m", "upstream change",
            environment: ["GIT_COMMITTER_DATE": "2020-01-01T00:00:00Z", "GIT_AUTHOR_DATE": "2020-01-01T00:00:00Z"])
        try await repository.git("checkout", "-q", "main")
        let (checkpoints, _) = try makeService()

        await checkpoints.captureBeforeTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)
        try repository.write("edit.txt", "agent edit\n")
        try await repository.git("merge", "-q", "--ff-only", "upstream")
        await checkpoints.captureAfterTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)

        let paths = checkpoints.changedFiles(threadID: threadID, userItemID: turnID).map(\.path)
        #expect(paths == ["edit.txt"])
        let patch = await checkpoints.turnDiff(threadID: threadID, userItemID: turnID) ?? ""
        #expect(!patch.contains("upstream.txt"))
    }

    @Test func skipsNestedRepositoriesWithoutACommit() async throws {
        let repository = try await makeRepository()
        try await repository.git("init", "-q", "nested")
        try repository.write("nested/inner.txt", "inner\n")
        let (checkpoints, _) = try makeService()
        await checkpoints.captureBeforeTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)
        let checkpoint = try #require(checkpoints.checkpoint(threadID: threadID, userItemID: turnID))
        let before = try #require(checkpoint.before)
        #expect(try await repository.git("ls-tree", "-r", "--name-only", before, "--", "nested").isEmpty)
        #expect(try await repository.git("show", "\(before):staged.txt") == "staged\n")
    }

    @Test func coversOnlyTheProjectFolderInsideARepository() async throws {
        let repository = try await makeRepository()
        try repository.write("app/main.swift", "print(1)\n")
        try await repository.git("add", ".")
        try await repository.git("commit", "-q", "-m", "app")
        let project = repository.url.appendingPathComponent("app")
        let (checkpoints, _) = try makeService()

        await checkpoints.captureBeforeTurn(threadID: threadID, userItemID: turnID, cwd: project)
        try repository.write("app/main.swift", "print(2)\n")
        try repository.write("outside.txt", "not ours\n")
        await checkpoints.captureAfterTurn(threadID: threadID, userItemID: turnID, cwd: project)
        #expect(checkpoints.changedFiles(threadID: threadID, userItemID: turnID).map(\.path) == ["app/main.swift"])

        try await checkpoints.restore(threadID: threadID, toBefore: turnID)
        #expect(repository.read("app/main.swift") == "print(1)\n")
        #expect(repository.read("outside.txt") == "not ours\n")
    }

    @Test func refusesToRestoreOverAnotherThreadsWork() async throws {
        let repository = try await makeRepository()
        let storeDirectory = try TestRepository.makeDirectory("store")
        let store = AppStore(directory: storeDirectory)
        let project = store.addProject(at: repository.url)
        let mine = store.createThread(in: project.id)
        let other = store.createThread(in: project.id)
        let (checkpoints, _) = try makeService(store)
        await checkpoints.captureBeforeTurn(threadID: mine.id, userItemID: turnID, cwd: repository.url)
        #expect(checkpoints.canRestore(threadID: mine.id, userItemID: turnID))

        try await Task.sleep(for: .milliseconds(20))
        store.append(TranscriptItem(kind: .user, text: "edit something"), to: other.id)
        #expect(!checkpoints.canRestore(threadID: mine.id, userItemID: turnID))
        await #expect(throws: CheckpointError.self) { try await checkpoints.restore(threadID: mine.id, toBefore: turnID) }
    }

    @Test func refusesToRestoreWhileAnotherThreadInTheFolderIsRunning() async throws {
        let repository = try await makeRepository()
        let store = AppStore(directory: try TestRepository.makeDirectory("store"))
        let project = store.addProject(at: repository.url)
        let mine = store.createThread(in: project.id)
        // Started its turn (and a long tool) before this turn's snapshot; tool output since then
        // updates its items without touching the thread.
        let other = store.createThread(in: project.id)
        let running = RunningThreads()
        let checkpoints = CheckpointService(
            store: store, directory: try TestRepository.makeDirectory("checkpoints"),
            isThreadRunning: { running.ids.contains($0) })
        await checkpoints.captureBeforeTurn(threadID: mine.id, userItemID: turnID, cwd: repository.url)
        #expect(checkpoints.canRestore(threadID: mine.id, userItemID: turnID))

        running.ids = [other.id]
        #expect(!checkpoints.canRestore(threadID: mine.id, userItemID: turnID))
        await #expect(throws: CheckpointError.self) { try await checkpoints.restore(threadID: mine.id, toBefore: turnID) }
        #expect(checkpoints.checkpoint(threadID: mine.id, userItemID: turnID) != nil)

        // The thread's own turn does not count.
        running.ids = [mine.id]
        #expect(checkpoints.canRestore(threadID: mine.id, userItemID: turnID))
    }

    @Test func workDoneWhileTheSnapshotIsTakenCountsAsAfterIt() async throws {
        let repository = try await makeRepository()
        let store = AppStore(directory: try TestRepository.makeDirectory("store"))
        let project = store.addProject(at: repository.url)
        let mine = store.createThread(in: project.id)
        let other = store.createThread(in: project.id)
        let (checkpoints, _) = try makeService(store)

        let capture = Task { await checkpoints.captureBeforeTurn(threadID: mine.id, userItemID: turnID, cwd: repository.url) }
        try await Task.sleep(for: .milliseconds(20))
        store.append(TranscriptItem(kind: .user, text: "edit something"), to: other.id)
        await capture.value
        #expect(checkpoints.checkpoint(threadID: mine.id, userItemID: turnID)?.before != nil)
        #expect(!checkpoints.canRestore(threadID: mine.id, userItemID: turnID))
    }

    @Test func runningTurnDiffsShareAWaitingCapture() async throws {
        let repository = try await makeRepository()
        let (checkpoints, _) = try makeService()
        await checkpoints.captureBeforeTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)
        try repository.write("edit.txt", "one\nTWO\n")

        let requests = (0..<8).map { _ in Task { await checkpoints.turnDiff(threadID: threadID, userItemID: turnID) } }
        for request in requests {
            #expect(await request.value?.contains("+TWO") == true)
        }
        #expect(checkpoints.liveCapturesStarted <= 2)

        // A later request still sees later changes.
        try repository.write("edit.txt", "one\nTHREE\n")
        #expect(await checkpoints.turnDiff(threadID: threadID, userItemID: turnID)?.contains("+THREE") == true)
    }

    @Test func aCancelledTurnDiffQueuesNoCapture() async throws {
        let repository = try await makeRepository()
        let (checkpoints, _) = try makeService()
        await checkpoints.captureBeforeTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)
        let request = Task { await checkpoints.turnDiff(threadID: threadID, userItemID: turnID) }
        request.cancel()
        #expect(await request.value == nil)
        #expect(checkpoints.liveCapturesStarted == 0)
    }

    @Test func turnDiffsReadAtMostTheCappedPatch() async throws {
        let repository = try await makeRepository()
        let (checkpoints, _) = try makeService()
        await checkpoints.captureBeforeTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)
        // More text than the patch limit: about 10 MB of patch.
        let line = String(repeating: "x", count: 99) + "\n"
        for index in 0..<5 {
            try repository.write("part\(index).txt", String(repeating: line, count: 20_000))
        }
        try repository.write("edit.txt", "one\nTWO\n")
        await checkpoints.captureAfterTurn(threadID: threadID, userItemID: turnID, cwd: repository.url)

        let patch = try #require(await checkpoints.turnDiff(threadID: threadID, userItemID: turnID))
        #expect(patch.utf8.count == GitOps.maxPatchBytes + 1)
        let diff = await GitService.parseDiff(
            patch, files: checkpoints.changedFiles(threadID: threadID, userItemID: turnID))
        #expect(diff.isTruncated)
        #expect(diff.files.contains { $0.path == "edit.txt" && !$0.hunks.isEmpty })
        #expect(diff.files.contains { $0.path == "part0.txt" && !$0.hunks.isEmpty })
        #expect(diff.files.contains { $0.path == "part4.txt" && $0.hunks.isEmpty && $0.additions == 20_000 })
    }

    @Test func forgetsTurnsCutFromTheTranscript() async throws {
        let repository = try await makeRepository()
        let store = AppStore(directory: try TestRepository.makeDirectory("store"))
        let project = store.addProject(at: repository.url)
        let thread = store.createThread(in: project.id)
        let first = store.append(TranscriptItem(kind: .user, text: "first"), to: thread.id)
        let second = store.append(TranscriptItem(kind: .user, text: "second"), to: thread.id)
        let (checkpoints, _) = try makeService(store)
        await checkpoints.captureBeforeTurn(threadID: thread.id, userItemID: first, cwd: repository.url)
        await checkpoints.captureBeforeTurn(threadID: thread.id, userItemID: second, cwd: repository.url)
        #expect(checkpoints.checkpoints(threadID: thread.id).count == 2)

        store.truncate(thread.id, from: second)
        #expect(checkpoints.checkpoints(threadID: thread.id).map(\.userItemID) == [first])
    }

    @Test func ignoresFoldersOutsideGit() async throws {
        let folder = try TestRepository.makeDirectory("plain")
        let (checkpoints, _) = try makeService()
        await checkpoints.captureBeforeTurn(threadID: threadID, userItemID: turnID, cwd: folder)
        #expect(checkpoints.checkpoint(threadID: threadID, userItemID: turnID) == nil)
        #expect(!checkpoints.canRestore(threadID: threadID, userItemID: turnID))
        #expect(await checkpoints.turnDiff(threadID: threadID, userItemID: turnID) == nil)
    }
}

/// The threads a test reports as having a turn running.
@MainActor
private final class RunningThreads {
    var ids: Set<UUID> = []
}
