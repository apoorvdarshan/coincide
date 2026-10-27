import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct GitServiceTests {
    private let git = GitService(worktreesRoot: try! TestRepository.makeDirectory("worktrees"))

    @Test func detectsRepositories() async throws {
        let repository = try await TestRepository.make()
        let plain = try TestRepository.makeDirectory("plain")
        #expect(await git.isRepository(repository.url))
        #expect(await !git.isRepository(plain))
        #expect(try await git.status(plain) == .notRepository)
        try repository.write("Sources/App.swift", "let x = 1\n")
        #expect(await git.repositoryRoot(repository.url.appendingPathComponent("Sources"))?.path == repository.url.path)
    }

    @Test func statusReportsBranchAndChangedFiles() async throws {
        let repository = try await TestRepository.make()
        try repository.write("README.md", "hello\nworld\nagain\n")
        try repository.write("notes.txt", "draft\n")
        try repository.write("staged.txt", "one\ntwo\n")
        try await repository.git("add", "staged.txt")

        let status = try await git.status(repository.url)
        #expect(status.isRepository)
        #expect(status.branch == "main")
        #expect(status.rootPath == repository.url.path)
        #expect(!status.hasUpstream && !status.hasRemote)
        #expect(status.isDefaultBranch)
        let files = Dictionary(uniqueKeysWithValues: status.files.map { ($0.path, $0) })
        #expect(files["README.md"]?.status == .modified)
        #expect(files["README.md"]?.additions == 2)
        #expect(files["notes.txt"]?.status == .untracked)
        #expect(files["notes.txt"]?.additions == 1)
        #expect(files["staged.txt"]?.status == .added)
        #expect(files["staged.txt"]?.additions == 2)
    }

    @Test func createsAndChecksOutBranches() async throws {
        let repository = try await TestRepository.make()
        let created = try await git.createBranch("my feature", in: repository.url)
        #expect(created == "my-feature")
        var list = try await git.branches(repository.url)
        #expect(list.currentBranch == "my-feature")
        #expect(list.branches.first?.name == "my-feature")
        #expect(list.branches.first?.isCurrent == true)
        #expect(list.local.map(\.name).contains("main"))

        #expect(try await git.checkout("main", in: repository.url) == "main")
        list = try await git.branches(repository.url)
        #expect(list.branches.first?.name == "main")

        await #expect(throws: GitError.self) { try await git.createBranch("bad..name", in: repository.url) }
        await #expect(throws: GitError.self) { try await git.checkout("does-not-exist", in: repository.url) }
    }

    @Test func checksOutRemoteBranchesThroughTrackingBranches() async throws {
        let remote = try await TestRepository.make()
        try await remote.git("branch", "topic")
        let repository = try await TestRepository.make()
        try await repository.git("remote", "add", "origin", remote.url.path)
        try await repository.git("fetch", "-q", "origin")

        let list = try await git.branches(repository.url)
        #expect(list.remote.map(\.name).contains("origin/topic"))
        // origin/main is hidden because a local main exists.
        #expect(!list.remote.map(\.name).contains("origin/main"))

        #expect(try await git.checkout("origin/topic", in: repository.url) == "topic")
        let status = try await git.status(repository.url)
        #expect(status.upstream == "origin/topic")
    }

    @Test func renamesBranchesToAFreeName() async throws {
        let repository = try await TestRepository.make()
        try await repository.git("branch", "taken")
        try await repository.git("branch", "old")
        #expect(try await git.renameBranch("old", to: "taken", in: repository.url) == "taken-1")
    }

    @Test func worktreeLifecycle() async throws {
        let repository = try await TestRepository.make()
        let worktree = try await git.createThreadWorktree(
            projectPath: repository.url, baseBranch: "main", prefix: "coincide/")
        let branch = try #require(worktree.branch)
        #expect(BranchNames.isTemporaryWorktreeBranch(branch, prefix: "coincide/"))
        #expect(FileManager.default.fileExists(atPath: worktree.path + "/README.md"))
        #expect(worktree.path.hasPrefix(git.worktreesRoot.path))

        let worktrees = try await git.worktrees(repository.url)
        #expect(worktrees.count == 2)
        #expect(worktrees.first?.isMain == true)
        #expect(worktrees.contains { $0.branch == branch })
        let branches = try await git.branches(repository.url)
        #expect(branches.local.first { $0.name == branch }?.worktreePath != nil)
        #expect(try await repository.git("config", "--get", BranchNames.mergeBaseConfigKey(branch)).hasPrefix("main"))

        let worktreeURL = URL(fileURLWithPath: worktree.path)
        #expect(await git.mainWorktree(of: worktreeURL)?.path == repository.url.path)
        let renamed = try await git.nameWorktreeBranch(
            branch, in: worktreeURL, message: "Please fix the login redirect bug", prefix: "coincide/")
        #expect(renamed == "coincide/fix-login-redirect-bug")
        #expect(try await git.status(worktreeURL).branch == "coincide/fix-login-redirect-bug")
        #expect(try await git.nameWorktreeBranch("main", in: worktreeURL, message: "x", prefix: "coincide/") == nil)

        try await git.removeWorktree(worktreeURL, in: repository.url)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func keepsTheWorktreesFolderOwnerOnly() async throws {
        let repository = try await TestRepository.make()
        func mode(_ url: URL) throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        }

        // A new folder, and the parent folder created with it.
        let data = try TestRepository.makeDirectory("data").appendingPathComponent(".coincide", isDirectory: true)
        let fresh = GitService(worktreesRoot: data.appendingPathComponent("worktrees", isDirectory: true))
        _ = try await fresh.createThreadWorktree(projectPath: repository.url, baseBranch: nil, prefix: "coincide/")
        #expect(try mode(fresh.worktreesRoot) == 0o700)
        #expect(try mode(data) == 0o700)

        // A folder an earlier version created readable by everyone.
        let existing = try TestRepository.makeDirectory("worktrees")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: existing.path)
        let older = GitService(worktreesRoot: existing)
        _ = try await older.createThreadWorktree(projectPath: repository.url, baseBranch: nil, prefix: "coincide/")
        #expect(try mode(existing) == 0o700)
    }

    @Test func discardsOnlyUnusedWorktrees() async throws {
        let repository = try await TestRepository.make()
        let unused = try await git.createThreadWorktree(projectPath: repository.url, baseBranch: nil, prefix: "coincide/")
        #expect(await git.discardUnusedWorktree(URL(fileURLWithPath: unused.path), branch: unused.branch, prefix: "coincide/"))
        #expect(!FileManager.default.fileExists(atPath: unused.path))
        let branches = try await git.branches(repository.url)
        #expect(!branches.local.contains { $0.name == unused.branch })

        let edited = try await git.createThreadWorktree(projectPath: repository.url, baseBranch: nil, prefix: "coincide/")
        try "changed\n".write(toFile: edited.path + "/README.md", atomically: true, encoding: .utf8)
        #expect(await !git.discardUnusedWorktree(URL(fileURLWithPath: edited.path), branch: edited.branch, prefix: "coincide/"))
        #expect(FileManager.default.fileExists(atPath: edited.path))
    }

    @Test func workingTreeDiffIncludesUntrackedFilesWithoutTouchingTheIndex() async throws {
        let repository = try await TestRepository.make()
        try repository.write("README.md", "hello\nchanged\n")
        try repository.write("docs/notes file.txt", "one\ntwo\nthree\n")

        let diff = try await git.workingTreeDiff(repository.url)
        #expect(diff.files.map(\.path) == ["docs/notes file.txt", "README.md"])
        let notes = try #require(diff.files.first { $0.path == "docs/notes file.txt" })
        #expect(notes.status == .untracked)
        #expect(notes.additions == 3)
        #expect(notes.hunks.first?.lines.map(\.text) == ["one", "two", "three"])
        let readme = try #require(diff.files.first { $0.path == "README.md" })
        #expect(readme.status == .modified)
        #expect(readme.additions == 1 && readme.deletions == 0)
        let added = try #require(readme.hunks.first?.lines.first { $0.kind == .addition })
        #expect(added.text == "changed" && added.newLine == 2)

        #expect(try await repository.git("diff", "--cached", "--name-only").isEmpty)
        #expect(try await repository.git("status", "--porcelain").contains("?? docs/"))
    }

    @Test func workingTreeDiffReadsAtMostTheCappedPatch() async throws {
        let repository = try await TestRepository.make()
        // Untracked files holding more text than the patch limit: about 10 MB of patch.
        let line = String(repeating: "x", count: 99) + "\n"
        for index in 0..<5 {
            try repository.write("part\(index).txt", String(repeating: line, count: 20_000))
        }
        try repository.write("README.md", "hello\nchanged\n")

        let diff = try await git.workingTreeDiff(repository.url)
        #expect(diff.isTruncated)
        #expect(
            Set(diff.files.map(\.path)) == ["README.md", "part0.txt", "part1.txt", "part2.txt", "part3.txt", "part4.txt"])
        #expect(diff.files.first { $0.path == "README.md" }?.hunks.isEmpty == false)
        let first = try #require(diff.files.first { $0.path == "part0.txt" })
        #expect(first.status == .untracked && first.hunks.first?.lines.count == 20_000)
        // Past the limit, files keep their counts but have no hunks.
        let last = try #require(diff.files.first { $0.path == "part4.txt" })
        #expect(last.hunks.isEmpty && last.additions == 20_000)
    }

    @Test func diffsAnUnbornRepository() async throws {
        let repository = try await TestRepository.make(commit: false)
        try repository.write("first.txt", "a\nb\n")
        let diff = try await git.workingTreeDiff(repository.url)
        #expect(diff.files.count == 1)
        #expect(diff.files.first?.additions == 2)
        let status = try await git.status(repository.url)
        #expect(status.branch == "main" && status.headOID == nil)
    }

    @Test func branchDiffCoversCommitsSinceTheBase() async throws {
        let repository = try await TestRepository.make()
        try await repository.git("checkout", "-q", "-b", "feature")
        try repository.write("feature.txt", "new\n")
        try await repository.git("add", ".")
        try await repository.git("commit", "-q", "-m", "Add feature")
        try repository.write("README.md", "hello\nmore\n")

        let diff = try await git.branchDiff(repository.url)
        #expect(Set(diff.files.map(\.path)) == ["feature.txt", "README.md"])
        #expect(diff.baseLabel == "main")
        let status = try await git.status(repository.url)
        #expect(status.ahead == 1 && status.aheadOfDefault == 1 && !status.isDefaultBranch)
    }

    @Test func commitsOnlyTheSelectedFiles() async throws {
        let repository = try await TestRepository.make()
        try repository.write("a.txt", "a\n")
        try repository.write("b.txt", "b\n")
        let commit = try await git.commit(subject: "Add a", body: "Just a.", paths: ["a.txt"], in: repository.url)
        #expect(commit.subject == "Add a")
        #expect(commit.sha.count == 40)
        #expect(try await repository.git("log", "-1", "--format=%s%n%b").contains("Just a."))
        let status = try await git.status(repository.url)
        #expect(status.files.map(\.path) == ["b.txt"])
    }

    @Test func pushPublishesTheBranchWithAnUpstream() async throws {
        let remote = try TestRepository.makeDirectory("remote.git")
        let repository = try await TestRepository.make()
        try await repository.git(["init", "-q", "--bare", remote.path], in: repository.url)
        try await repository.git("remote", "add", "origin", remote.path)

        let first = try await git.push(repository.url)
        #expect(first.outcome == .pushed && first.setUpstream)
        #expect(first.upstream == "origin/main")
        var status = try await git.status(repository.url)
        #expect(status.upstream == "origin/main" && status.ahead == 0)
        #expect(try await git.push(repository.url).outcome == .upToDate)

        try repository.write("README.md", "hello\nagain\n")
        _ = try await git.commit(subject: "Update readme", in: repository.url)
        status = try await git.status(repository.url)
        #expect(status.ahead == 1)
        #expect(try await git.push(repository.url).outcome == .pushed)
        #expect(try await git.status(repository.url).ahead == 0)
    }

    @Test func stackedCommitWritesAMessageWithoutAnAgent() async throws {
        let repository = try await TestRepository.make()
        try repository.write("README.md", "hello\nthere\n")
        var labels: [String] = []
        let result = try await git.run(GitActionRequest(action: .commit), in: repository.url) { labels.append($0) }
        #expect(result.commit?.subject == "Update README.md")
        #expect(result.title.hasPrefix("Committed"))
        #expect(result.followUp == .run(.push))
        #expect(labels.contains("Committing…"))

        try repository.write("x.txt", "x\n")
        let custom = try await git.run(
            GitActionRequest(action: .commit, commitMessage: "Add x\n\nWith a body."), in: repository.url)
        #expect(custom.commit?.subject == "Add x")
        #expect(try await repository.git("log", "-1", "--format=%b").contains("With a body."))
    }

    @Test func featureBranchStepNamesTheBranchAfterTheChange() async throws {
        let repository = try await TestRepository.make()
        try repository.write("parser.swift", "struct Parser {}\n")
        let result = try await git.run(
            GitActionRequest(action: .commit, commitMessage: "Add parser", featureBranch: true), in: repository.url)
        #expect(result.createdBranch == "feature/add-parser")
        #expect(try await git.status(repository.url).branch == "feature/add-parser")
        await #expect(throws: GitError.self) {
            try await git.run(GitActionRequest(action: .push, featureBranch: true), in: repository.url)
        }
    }
}

struct GitQuickActionTests {
    private func status(
        branch: String? = "feature", changes: Bool = false, upstream: String? = "origin/feature", ahead: Int = 0,
        behind: Int = 0, aheadOfDefault: Int = 0, isDefault: Bool = false, hasRemote: Bool = true
    ) -> GitStatus {
        GitStatus(
            isRepository: true, branch: branch, upstream: upstream, ahead: ahead, behind: behind,
            aheadOfDefault: aheadOfDefault, isDefaultBranch: isDefault, hasRemote: hasRemote,
            files: changes ? [ChangedFile(path: "a", status: .modified)] : [])
    }

    @Test func changesOnAFeatureBranchCommitPushAndOpenAPullRequest() {
        #expect(GitQuickAction.resolve(status: status(changes: true), isBusy: false, hasOpenPullRequest: false).kind == .run(.commitPushPR))
        #expect(GitQuickAction.resolve(status: status(changes: true), isBusy: false, hasOpenPullRequest: true).kind == .run(.commitPush))
        #expect(GitQuickAction.resolve(status: status(changes: true, isDefault: true), isBusy: false, hasOpenPullRequest: false).kind == .run(.commitPush))
        #expect(GitQuickAction.resolve(status: status(changes: true, upstream: nil, hasRemote: false), isBusy: false, hasOpenPullRequest: false).kind == .run(.commit))
    }

    @Test func cleanBranchesPushPullOrWait() {
        let ahead = GitQuickAction.resolve(status: status(ahead: 2), isBusy: false, hasOpenPullRequest: false)
        #expect(ahead.kind == .run(.createPR) && ahead.title == "Push & Create PR")
        #expect(GitQuickAction.resolve(status: status(ahead: 2), isBusy: false, hasOpenPullRequest: true).kind == .run(.push))
        #expect(GitQuickAction.resolve(status: status(behind: 1), isBusy: false, hasOpenPullRequest: false).kind == .pull)
        let diverged = GitQuickAction.resolve(status: status(ahead: 1, behind: 1), isBusy: false, hasOpenPullRequest: false)
        #expect(!diverged.isEnabled)
        #expect(GitQuickAction.resolve(status: status(aheadOfDefault: 3), isBusy: false, hasOpenPullRequest: false).kind == .run(.createPR))
        #expect(!GitQuickAction.resolve(status: status(), isBusy: false, hasOpenPullRequest: false).isEnabled)
        #expect(!GitQuickAction.resolve(status: status(branch: nil, changes: true), isBusy: false, hasOpenPullRequest: false).isEnabled)
        #expect(!GitQuickAction.resolve(status: status(changes: true), isBusy: true, hasOpenPullRequest: false).isEnabled)
    }

    @Test func defaultBranchPushesAskFirst() {
        #expect(GitQuickAction.requiresDefaultBranchConfirmation(.commitPush, isDefaultBranch: true))
        #expect(!GitQuickAction.requiresDefaultBranchConfirmation(.commit, isDefaultBranch: true))
        #expect(!GitQuickAction.requiresDefaultBranchConfirmation(.push, isDefaultBranch: false))
    }

    @Test func menuAvailability() {
        let available = GitActionAvailability.resolve(status: status(changes: true, ahead: 1, aheadOfDefault: 1), isBusy: false, hasOpenPullRequest: false)
        #expect(available.canCommit && available.canPush && available.canCreatePR && available.showsRemoteActions)
        let behind = GitActionAvailability.resolve(status: status(ahead: 1, behind: 1), isBusy: false, hasOpenPullRequest: false)
        #expect(!behind.canPush && !behind.canCreatePR)
        let local = GitActionAvailability.resolve(status: status(upstream: nil, hasRemote: false), isBusy: false, hasOpenPullRequest: false)
        #expect(!local.showsRemoteActions)
    }
}
