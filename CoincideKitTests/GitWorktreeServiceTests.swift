import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct GitWorktreeServiceTests {
    private struct Fixture {
        let repository: TestRepository
        let store: AppStore
        let git: GitService
        let worktrees: WorktreeService
        let threadID: UUID
    }

    private func makeFixture() async throws -> Fixture {
        let repository = try await TestRepository.make()
        let store = AppStore(directory: try TestRepository.makeDirectory("store"))
        let git = GitService(worktreesRoot: try TestRepository.makeDirectory("worktrees"))
        let project = store.addProject(at: repository.url)
        let thread = store.createThread(in: project.id)
        return Fixture(
            repository: repository, store: store, git: git, worktrees: WorktreeService(store: store, git: git),
            threadID: thread.id)
    }

    /// Waits for an asynchronous effect of a store observation.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func newWorktreeMovesTheThreadAndNamesItsBranchAfterTheFirstMessage() async throws {
        let fixture = try await makeFixture()
        try await fixture.worktrees.useNewWorktree(threadID: fixture.threadID, baseBranch: nil)
        let thread = try #require(fixture.store.thread(fixture.threadID))
        let path = try #require(thread.worktreePath)
        let branch = try #require(thread.branch)
        #expect(BranchNames.isTemporaryWorktreeBranch(branch, prefix: "coincide/"))
        #expect(fixture.worktrees.baseBranch(for: fixture.threadID) == "main")
        #expect(fixture.store.workingDirectory(for: fixture.threadID)?.path == path)
        #expect(!fixture.worktrees.isPreparing(fixture.threadID))

        fixture.store.append(TranscriptItem(kind: .user, text: "Add a dark mode toggle"), to: fixture.threadID)
        try await eventually { fixture.store.thread(fixture.threadID)?.branch != branch }
        #expect(fixture.store.thread(fixture.threadID)?.branch == "coincide/add-dark-mode-toggle")
        #expect(try await fixture.git.status(URL(fileURLWithPath: path)).branch == "coincide/add-dark-mode-toggle")
    }

    @Test func switchingBackRemovesTheUnusedWorktree() async throws {
        let fixture = try await makeFixture()
        try await fixture.worktrees.useNewWorktree(threadID: fixture.threadID, baseBranch: "main")
        let path = try #require(fixture.store.thread(fixture.threadID)?.worktreePath)

        await fixture.worktrees.useProjectCheckout(threadID: fixture.threadID)
        #expect(fixture.store.thread(fixture.threadID)?.worktreePath == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try await fixture.git.worktrees(fixture.repository.url).count == 1)
    }

    @Test func choosingAnotherBaseReplacesTheWorktree() async throws {
        let fixture = try await makeFixture()
        try await fixture.repository.git("branch", "release")
        try await fixture.worktrees.useNewWorktree(threadID: fixture.threadID, baseBranch: "main")
        let first = try #require(fixture.store.thread(fixture.threadID)?.worktreePath)
        try await fixture.worktrees.useNewWorktree(threadID: fixture.threadID, baseBranch: "release")
        let second = try #require(fixture.store.thread(fixture.threadID)?.worktreePath)
        #expect(first != second && !FileManager.default.fileExists(atPath: first))
        #expect(fixture.worktrees.baseBranch(for: fixture.threadID) == "release")
    }

    @Test func deletingTheThreadRemovesItsUnusedWorktree() async throws {
        let fixture = try await makeFixture()
        try await fixture.worktrees.useNewWorktree(threadID: fixture.threadID, baseBranch: nil)
        let path = try #require(fixture.store.thread(fixture.threadID)?.worktreePath)
        fixture.store.deleteThread(fixture.threadID)
        try await eventually { !FileManager.default.fileExists(atPath: path) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func offersAnotherThreadsWorktree() async throws {
        let fixture = try await makeFixture()
        try await fixture.worktrees.useNewWorktree(threadID: fixture.threadID, baseBranch: nil)
        let path = try #require(fixture.store.thread(fixture.threadID)?.worktreePath)
        let project = try #require(fixture.store.thread(fixture.threadID)?.projectID)
        let other = fixture.store.createThread(in: project)
        let previous = try #require(fixture.worktrees.previousWorktree(for: other.id))
        #expect(previous.path == path)

        await fixture.worktrees.useExistingWorktree(threadID: other.id, path: previous.path, branch: previous.branch)
        #expect(fixture.store.thread(other.id)?.worktreePath == path)
    }

    @Test func threadsWithMessagesKeepTheirFolder() async throws {
        let fixture = try await makeFixture()
        fixture.store.append(TranscriptItem(kind: .user, text: "hello"), to: fixture.threadID)
        try await fixture.worktrees.useNewWorktree(threadID: fixture.threadID, baseBranch: nil)
        #expect(fixture.store.thread(fixture.threadID)?.worktreePath == nil)
    }
}
