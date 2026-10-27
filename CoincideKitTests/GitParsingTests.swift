import Foundation
import Testing

@testable import CoincideKit

struct GitParsingTests {
    @Test func parsesPorcelainV2() {
        let output = [
            "# branch.oid 1234567890abcdef", "# branch.head feature/x", "# branch.upstream origin/feature/x",
            "# branch.ab +3 -1", "1 .M N... 100644 100644 100644 aaa bbb Sources/App.swift",
            "1 A. N... 000000 100644 100644 000 ccc new file.txt",
            "2 R. N... 100644 100644 100644 ddd eee R100 Renamed.swift", "Original.swift",
            "u UU N... 100644 100644 100644 100644 f1 f2 f3 conflict.txt", "? notes.md", "",
        ].joined(separator: "\0")
        let status = GitParse.porcelainV2(output)
        #expect(status.oid == "1234567890abcdef")
        #expect(status.head == "feature/x")
        #expect(status.upstream == "origin/feature/x")
        #expect(status.ahead == 3 && status.behind == 1)
        #expect(status.entries.map(\.path) == ["Sources/App.swift", "new file.txt", "Renamed.swift", "conflict.txt", "notes.md"])
        #expect(status.entries.map(\.status) == [.modified, .added, .renamed, .modified, .untracked])
        #expect(status.entries[2].originalPath == "Original.swift")
        #expect(status.entries[3].isConflicted)
    }

    @Test func parsesDetachedAndInitialHeads() {
        let status = GitParse.porcelainV2("# branch.oid (initial)\0# branch.head (detached)\0")
        #expect(status.oid == nil && status.head == nil)
    }

    @Test func parsesNumstatWithRenamesAndBinaries() {
        let output = "3\t1\tSources/App.swift\0" + "0\t0\t\0old name.txt\0new name.txt\0" + "-\t-\timage.png\0"
        let stats = GitParse.numstat(output)
        #expect(stats.map(\.path) == ["Sources/App.swift", "new name.txt", "image.png"])
        #expect(stats[0].additions == 3 && stats[0].deletions == 1)
        #expect(stats[1].oldPath == "old name.txt")
        #expect(stats[2].isBinary)
    }

    @Test func parsesWorktreeList() {
        let output = [
            "worktree /repo", "HEAD abc", "branch refs/heads/main", "",
            "worktree /wt/feature", "HEAD def", "branch refs/heads/coincide/1a2b3c4d", "locked", "",
            "worktree /wt/gone", "HEAD 123", "detached", "prunable gitdir file points to non-existent location", "", "",
        ].joined(separator: "\0")
        let worktrees = GitParse.worktrees(output)
        #expect(worktrees.map(\.path) == ["/repo", "/wt/feature", "/wt/gone"])
        #expect(worktrees[0].isMain && !worktrees[1].isMain)
        #expect(worktrees[1].branch == "coincide/1a2b3c4d" && worktrees[1].isLocked)
        #expect(worktrees[2].branch == nil && worktrees[2].isPrunable)
    }

    @Test func unquotesGitPaths() {
        #expect(GitParse.unquote("plain.txt") == "plain.txt")
        #expect(GitParse.unquote("\"tab\\there.txt\"") == "tab\there.txt")
        #expect(GitParse.unquote("\"caf\\303\\251.txt\"") == "café.txt")
        #expect(GitParse.unquote("\"quote\\\"d\"") == "quote\"d")
    }

    @Test func parsesUnifiedDiffs() {
        let patch = """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 1111111..2222222 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1,4 +1,5 @@ struct App {
             import Foundation
            -let a = 1
            +let a = 2
            +let b = 3

             func run() {}
            diff --git a/new file.txt b/new file.txt
            new file mode 100644
            index 0000000..3333333
            --- /dev/null
            +++ b/new file.txt\t
            @@ -0,0 +1 @@
            +hello
            \\ No newline at end of file
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            index 4444444..0000000
            --- a/gone.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -bye
            diff --git a/old.swift b/new.swift
            similarity index 90%
            rename from old.swift
            rename to new.swift
            diff --git a/logo.png b/logo.png
            index 5555555..6666666 100644
            Binary files a/logo.png and b/logo.png differ
            diff --git a/run.sh b/run.sh
            old mode 100644
            new mode 100755

            """
        let files = DiffParser.parse(patch)
        #expect(files.map(\.path) == ["Sources/App.swift", "new file.txt", "gone.txt", "new.swift", "logo.png", "run.sh"])

        let app = files[0]
        #expect(app.status == .modified)
        #expect(app.additions == 2 && app.deletions == 1)
        let hunk = try! #require(app.hunks.first)
        #expect(hunk.section == "struct App {")
        #expect(hunk.lines.map(\.kind) == [.context, .deletion, .addition, .addition, .context, .context])
        #expect(hunk.lines[1].oldLine == 2 && hunk.lines[1].newLine == nil)
        #expect(hunk.lines[3].newLine == 3)
        #expect(hunk.lines[4].text.isEmpty && hunk.lines[4].oldLine == 3 && hunk.lines[4].newLine == 4)
        #expect(hunk.lines[5].oldLine == 4 && hunk.lines[5].newLine == 5)

        #expect(files[1].status == .added)
        #expect(files[1].hunks.first?.lines.map(\.kind) == [.addition, .noNewline])
        #expect(files[2].status == .deleted && files[2].deletions == 1)
        #expect(files[3].status == .renamed && files[3].oldPath == "old.swift")
        #expect(files[4].isBinary)
        #expect(files[5].modeChange == "100644 → 100755")
    }

    @Test func absurdHunkNumbersAreNotHunkHeaders() {
        // Counting lines from these used to overflow Int and trap.
        #expect(DiffParser.hunkHeader("@@ -9223372036854775807,2 +1,2 @@") == nil)
        #expect(DiffParser.hunkHeader("@@ -1,2 +1,-9223372036854775808 @@") == nil)
        #expect(DiffParser.hunkHeader("@@ -1,-1 +1 @@") == nil)
        #expect(DiffParser.hunkHeader("@@ -2147483647,2147483647 +0,0 @@")?.oldCount == 2_147_483_647)
        for header in ["@@ -9223372036854775807,2 +1,2 @@", "@@ -1,2 +1,-9223372036854775808 @@"] {
            let files = DiffParser.parse("diff --git a/x b/x\n\(header)\n a\n b\n")
            #expect(files.map(\.path) == ["x"])
            #expect(files.first?.hunks.isEmpty == true)
        }
    }

    @Test func assemblesCountsFromNumstat() {
        let patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-x\n+y\n"
        let diff = GitOps.assemble(
            patch: patch,
            stats: [
                GitParse.Numstat(path: "a.txt", additions: 1, deletions: 1, isBinary: false),
                GitParse.Numstat(path: "b.txt", additions: 4, deletions: 0, isBinary: false),
            ], untracked: ["b.txt"])
        #expect(diff.files.map(\.path) == ["a.txt", "b.txt"])
        #expect(diff.files[1].status == .untracked && diff.files[1].hunks.isEmpty)
        #expect(diff.additions == 5 && diff.deletions == 1)
    }
}

struct BranchNamesTests {
    @Test func sanitizesFragments() {
        #expect(BranchNames.sanitizeFragment("  Fix the Login Bug! ") == "fix-the-login-bug")
        #expect(BranchNames.sanitizeFragment("feat//Search__UI") == "feat/search__ui")
        #expect(BranchNames.sanitizeFragment("...") == "update")
        #expect(BranchNames.sanitizeNewRefName(" my new\tbranch ") == "my-new-branch")
        #expect(BranchNames.featureBranchName("Add parser") == "feature/add-parser")
        #expect(BranchNames.featureBranchName("fix/crash") == "fix/crash")
    }

    @Test func picksAFreeFeatureBranchName() {
        #expect(BranchNames.availableFeatureBranchName("Add parser", existing: ["main"]) == "feature/add-parser")
        #expect(
            BranchNames.availableFeatureBranchName("Add parser", existing: ["feature/add-parser", "feature/add-parser-2"])
                == "feature/add-parser-3")
        // A branch called `feature` blocks the `feature/` namespace.
        #expect(BranchNames.availableFeatureBranchName("Add parser", existing: ["feature"]) == "feature-2/add-parser")
    }

    @Test func recognizesTemporaryWorktreeBranches() {
        let branch = BranchNames.temporaryWorktreeBranch(prefix: "coincide/")
        #expect(branch.hasPrefix("coincide/") && branch.count == "coincide/".count + 8)
        #expect(BranchNames.isTemporaryWorktreeBranch(branch, prefix: "coincide/"))
        let flat = BranchNames.flattenedTemporaryBranch(branch, prefix: "coincide/")
        #expect(flat.hasPrefix("coincide-"))
        #expect(BranchNames.isTemporaryWorktreeBranch(flat, prefix: "coincide/"))
        #expect(!BranchNames.isTemporaryWorktreeBranch("coincide/fix-login", prefix: "coincide/"))
        #expect(!BranchNames.isTemporaryWorktreeBranch("main", prefix: "coincide/"))
        #expect(BranchNames.isTemporaryWorktreeBranch("0123abcd", prefix: ""))
    }

    @Test func namesBranchesAfterTheRequest() {
        #expect(BranchNames.descriptiveBranch(for: "Can you add dark mode to settings?", prefix: "coincide/") == "coincide/add-dark-mode-to-settings")
        #expect(BranchNames.descriptiveBranch(for: "🙂", prefix: "wip-") == "wip-update")
        #expect(BranchNames.localName(fromRemoteRef: "origin/feature/x") == "feature/x")
    }
}

@MainActor
struct GitWriterTests {
    @Test func extractsTheLastMatchingJSONObject() {
        let reply = """
            Here you go:
            ```json
            {"subject": "Add parser", "body": "- Parses {braces} in strings"}
            ```
            """
        let json = GitWriter.extractJSON(reply, requiredKeys: ["subject"])
        #expect(json?["subject"]?.string == "Add parser")
        #expect(json?["body"]?.string == "- Parses {braces} in strings")
        #expect(GitWriter.extractJSON("no json here", requiredKeys: ["subject"]) == nil)
        #expect(GitWriter.extractJSON("{\"title\": 1}", requiredKeys: ["title"]) == nil)
    }

    @Test func sanitizesGeneratedMessages() {
        let message = GitWriter.sanitizedCommitMessage(
            subject: "Fix the crash on launch.\nExtra", body: "  - detail  ", branch: " fix/crash ")
        #expect(message.subject == "Fix the crash on launch")
        #expect(message.body == "- detail")
        #expect(message.branch == "fix/crash")
        #expect(GitWriter.sanitizedCommitMessage(subject: "...", body: "", branch: nil).subject == "Update project files")
        #expect(GitWriter.sanitizedCommitMessage(subject: String(repeating: "a", count: 90), body: "", branch: nil).subject.count == 72)
    }

    @Test func fallsBackToAMessageFromTheFileList() {
        #expect(GitWriter.fallbackCommitMessage(summary: "M\tSources/App.swift").subject == "Update App.swift")
        #expect(GitWriter.fallbackCommitMessage(summary: "R100\told.txt\tnew.txt").subject == "Rename old.txt to new.txt")
        let many = GitWriter.fallbackCommitMessage(summary: "A\ta.txt\nA\tb.txt")
        #expect(many.subject == "Add 2 files")
        #expect(many.body == "- Add a.txt\n- Add b.txt")
        #expect(GitWriter.customCommitMessage("  \n ") == nil)
        #expect(GitWriter.customCommitMessage("Subject\n\nBody line")?.body == "Body line")
    }

    @Test func fallsBackToAPullRequestFromCommits() {
        let single = GitWriter.fallbackPullRequest(headBranch: "coincide/fix-login", commits: "abc1234 Fix login redirect\n")
        #expect(single.title == "Fix login redirect")
        #expect(single.body.contains("## Summary\n- Fix login redirect"))
        #expect(single.body.contains("## Testing"))
        let several = GitWriter.fallbackPullRequest(headBranch: "coincide/fix-login", commits: "a1 One\nb2 Two\n")
        #expect(several.title == "Fix login")
    }

    @Test func promptsFollowT3Rules() {
        let prompt = GitWriter.commitPrompt(
            context: GitOps.CommitContext(summary: "M\ta.txt", patch: "+x"), branch: "main", includeBranch: true)
        #expect(prompt.contains("Return a JSON object with keys: subject, body, branch."))
        #expect(prompt.contains("Staged patch:\n+x"))
        let pr = GitWriter.pullRequestPrompt(
            baseBranch: "main", headBranch: "feature", range: GitOps.RangeContext(commits: "a1 One", stat: "", patch: ""),
            threadContext: "User: do it")
        #expect(pr.contains("## Summary") && pr.contains("Thread that produced this change"))
    }
}
