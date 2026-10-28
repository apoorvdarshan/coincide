import Foundation
import Testing

@testable import CoincideKit

struct PullRequestCommandTests {
    @Test func listsOpenPullRequestsForEachFilter() {
        let open = PullRequestCommands.list(.open, limit: 100)
        #expect(open.prefix(6) == ["pr", "list", "--state", "open", "--limit", "100"])
        #expect(open.contains("--json") && !open.contains("--author") && !open.contains("--search"))
        #expect(PullRequestCommands.list(.mine, limit: 5).suffix(2) == ["--author", "@me"])
        #expect(PullRequestCommands.list(.reviewRequested, limit: 5).suffix(2) == ["--search", "review-requested:@me"])
        // The detail asks for everything the list does, plus what only the detail shows.
        #expect(PullRequestCommands.detailFields.hasPrefix(PullRequestCommands.listFields + ","))
        #expect(PullRequestCommands.view(42) == ["pr", "view", "42", "--json", PullRequestCommands.detailFields])
    }

    @Test func actions() {
        #expect(PullRequestCommands.merge(7, method: .squash, headCommit: "abc123") == ["pr", "merge", "7", "--squash", "--match-head-commit", "abc123"])
        #expect(PullRequestCommands.merge(7, method: .merge, headCommit: "abc123") == ["pr", "merge", "7", "--merge", "--match-head-commit", "abc123"])
        #expect(PullRequestCommands.merge(7, method: .rebase, headCommit: "abc123") == ["pr", "merge", "7", "--rebase", "--match-head-commit", "abc123"])
        // The branch is never deleted: a thread's worktree may have it checked out.
        #expect(!PullRequestCommands.merge(7, method: .squash, headCommit: "abc123").contains("--delete-branch"))
        #expect(PullRequestCommands.ready(7) == ["pr", "ready", "7"])
        #expect(PullRequestCommands.checkout(7, branch: "fix", submodules: false) == ["pr", "checkout", "7", "--branch", "fix"])
        #expect(PullRequestCommands.checkout(7, branch: "fix", submodules: true).last == "--recurse-submodules")
    }
}

struct PullRequestJSONTests {
    /// What `gh pr list --json …` printed for a real repository, trimmed, plus a draft from a fork and an entry
    /// missing its branch.
    private let listOutput = """
        [
          {"author":{"id":"U1","is_bot":false,"login":"apoorvdarshan","name":"Apoorv"},"baseRefName":"main",
           "headRefName":"limit-resume","isCrossRepository":false,"isDraft":false,"number":33,"reviewDecision":"",
           "latestReviews":[],"state":"OPEN","title":"Resume threads when a usage limit resets",
           "updatedAt":"2026-10-28T11:27:15Z","url":"https://github.com/apoorvdarshan/coincide/pull/33",
           "statusCheckRollup":[
             {"__typename":"CheckRun","completedAt":"0001-01-01T00:00:00Z","conclusion":"",
              "detailsUrl":"https://github.com/o/r/actions/runs/1/job/2","name":"Build and test",
              "startedAt":"2026-10-28T11:27:22Z","status":"IN_PROGRESS","workflowName":"CI"},
             {"__typename":"CheckRun","completedAt":"2026-10-28T11:28:05Z","conclusion":"SUCCESS",
              "detailsUrl":"https://github.com/o/r/actions/runs/3","name":"Analyze (actions)",
              "startedAt":"2026-10-28T11:27:23Z","status":"COMPLETED","workflowName":"CodeQL"}
           ]},
          {"author":{"login":"contributor"},"baseRefName":"main","headRefName":"main","isCrossRepository":true,
           "isDraft":true,"number":31,"reviewDecision":"REVIEW_REQUIRED",
           "latestReviews":[{"author":{"login":"a"},"state":"APPROVED"}],"state":"OPEN","title":"  Draft from a fork ",
           "updatedAt":"2026-10-27T09:00:00Z","url":"https://github.com/o/r/pull/31","statusCheckRollup":[]},
          {"number":30,"title":"No branch","url":"https://github.com/o/r/pull/30","baseRefName":"main"}
        ]
        """

    @Test func readsTheListAndSkipsEntriesThatDontRead() throws {
        let list = try #require(PullRequestJSON.list(listOutput))
        #expect(list.map(\.number) == [33, 31])
        let first = list[0]
        #expect(first.title == "Resume threads when a usage limit resets")
        #expect(first.author == "apoorvdarshan")
        #expect(first.headBranch == "limit-resume" && first.baseBranch == "main")
        #expect(first.state == .open && !first.isDraft && !first.isCrossRepository)
        #expect(first.reviewDecision == nil)
        // One check still runs.
        #expect(first.checksState == .pending)
        #expect(first.updatedAt == Date(timeIntervalSince1970: 1_793_186_835))

        let draft = list[1]
        #expect(draft.title == "Draft from a fork")
        #expect(draft.isDraft && draft.isCrossRepository)
        // An approval GitHub's branch rules don't require still counts.
        #expect(draft.reviewDecision == .approved)
        #expect(draft.checksState == nil)

        #expect(PullRequestJSON.list("not json") == nil)
        #expect(PullRequestJSON.list("{}") == nil)
        #expect(PullRequestJSON.list("[]") == [])
    }

    @Test func readsTheDetail() throws {
        let output = """
            {"number":12,"title":"Fix the parser","url":"https://github.com/o/r/pull/12","headRefName":"fix",
             "baseRefName":"main","state":"OPEN","isDraft":false,"author":{"login":"me"},"reviewDecision":"CHANGES_REQUESTED",
             "body":"Fixes it.\\n\\n<!-- template -->","mergeable":"CONFLICTING","additions":120,"deletions":30,
             "changedFiles":7,"statusCheckRollup":[
               {"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE","targetUrl":"https://ci.example/1"}]}
            """
        let detail = try #require(PullRequestJSON.detail(output))
        #expect(detail.summary.number == 12 && detail.summary.reviewDecision == .changesRequested)
        #expect(detail.body == "Fixes it.\n\n<!-- template -->")
        #expect(detail.mergeability == .conflicting)
        #expect(detail.additions == 120 && detail.deletions == 30 && detail.changedFiles == 7)
        #expect(detail.checks == [PullRequestCheck(name: "ci/legacy", status: .failure, url: "https://ci.example/1")])
        #expect(detail.summary.checksState == .failing)
        #expect(PullRequestJSON.detail("[]") == nil)
    }

    @Test func checkStatusesFollowGitHubsRunsAndStatuses() {
        func status(_ json: String) -> PullRequestCheckStatus { PullRequestJSON.status(JSONValue.parse(json)!) }
        #expect(status(#"{"status":"QUEUED","conclusion":""}"#) == .pending)
        #expect(status(#"{"status":"COMPLETED","conclusion":"SUCCESS"}"#) == .success)
        #expect(status(#"{"status":"COMPLETED","conclusion":"TIMED_OUT"}"#) == .failure)
        #expect(status(#"{"status":"COMPLETED","conclusion":"STARTUP_FAILURE"}"#) == .failure)
        #expect(status(#"{"status":"COMPLETED","conclusion":"CANCELLED"}"#) == .cancelled)
        #expect(status(#"{"status":"COMPLETED","conclusion":"ACTION_REQUIRED"}"#) == .actionRequired)
        #expect(status(#"{"status":"COMPLETED","conclusion":"SKIPPED"}"#) == .skipped)
        #expect(status(#"{"status":"COMPLETED","conclusion":"STALE"}"#) == .neutral)
        // Commit statuses have only a state.
        #expect(status(#"{"state":"PENDING"}"#) == .pending)
        #expect(status(#"{"state":"EXPECTED"}"#) == .pending)
        #expect(status(#"{"state":"ERROR"}"#) == .failure)
        #expect(status(#"{"state":"SUCCESS"}"#) == .success)
    }

    @Test func rerunsAndOverlappingWorkflowsCountOnce() throws {
        let rollup = try #require(
            JSONValue.parse(
                """
                [
                  {"name":"build","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE",
                   "startedAt":"2026-10-28T10:00:00Z","completedAt":"2026-10-28T10:05:00Z"},
                  {"name":"lint","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS",
                   "completedAt":"2026-10-28T10:01:00Z"},
                  {"name":"build","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS",
                   "startedAt":"2026-10-28T11:00:00Z","completedAt":"2026-10-28T11:05:00Z"},
                  {"name":"test","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS",
                   "completedAt":"2026-10-28T12:00:00Z"},
                  {"name":"test","workflowName":"CI","status":"IN_PROGRESS","conclusion":"",
                   "completedAt":"0001-01-01T00:00:00Z"},
                  {"name":"lint","workflowName":"Nightly","status":"COMPLETED","conclusion":"CANCELLED"},
                  {"status":"COMPLETED","conclusion":"SUCCESS"}
                ]
                """)?.array)
        let checks = PullRequestJSON.checks(rollup)
        // The rerun of build passed; test is running again; lint runs in two workflows, so both are named with theirs.
        // The cancelled one comes first, and the rest keep the order they first appeared in.
        #expect(
            checks == [
                PullRequestCheck(name: "Nightly / lint", status: .cancelled),
                PullRequestCheck(name: "build", status: .success),
                PullRequestCheck(name: "CI / lint", status: .success),
                PullRequestCheck(name: "test", status: .pending),
            ])
        #expect(PullRequestJSON.checksState(PullRequestJSON.statuses(rollup)) == .failing)
    }

    @Test func checksAddUpLikeGitHubsRollup() {
        #expect(PullRequestJSON.checksState([]) == nil)
        #expect(PullRequestJSON.checksState([.skipped, .neutral]) == nil)
        #expect(PullRequestJSON.checksState([.success, .skipped]) == .passing)
        #expect(PullRequestJSON.checksState([.success, .pending]) == .pending)
        #expect(PullRequestJSON.checksState([.success, .actionRequired]) == .pending)
        #expect(PullRequestJSON.checksState([.pending, .cancelled]) == .failing)
    }

    @Test func reviewDecisionsFallBackToTheLatestReviews() {
        func review(_ state: String) -> JSONValue { .object(["state": .string(state)]) }
        #expect(PullRequestJSON.reviewDecision("APPROVED", latestReviews: [review("CHANGES_REQUESTED")]) == .approved)
        #expect(PullRequestJSON.reviewDecision("REVIEW_REQUIRED", latestReviews: []) == .reviewRequired)
        #expect(PullRequestJSON.reviewDecision("REVIEW_REQUIRED", latestReviews: [review("CHANGES_REQUESTED")]) == .changesRequested)
        #expect(PullRequestJSON.reviewDecision("", latestReviews: [review("APPROVED"), review("CHANGES_REQUESTED")]) == .changesRequested)
        #expect(PullRequestJSON.reviewDecision(nil, latestReviews: [review("COMMENTED")]) == nil)
    }

    @Test func mergeMethodsFollowTheRepositorysSettings() {
        #expect(
            PullRequestJSON.mergeMethods(#"{"mergeCommitAllowed":false,"squashMergeAllowed":true,"rebaseMergeAllowed":true}"#)
                == [.squash, .rebase])
        // Unreadable or contradictory settings leave the choice to GitHub.
        #expect(PullRequestJSON.mergeMethods("oops") == PullRequestMergeMethod.allCases)
        #expect(
            PullRequestJSON.mergeMethods(#"{"mergeCommitAllowed":false,"squashMergeAllowed":false,"rebaseMergeAllowed":false}"#)
                == PullRequestMergeMethod.allCases)
    }

    @Test func descriptionsDropTemplateComments() {
        #expect(PullRequestBody.displayMarkdown("<!-- Describe it -->\n## Summary\nFixes it.\n<!--\nchecklist\n-->") == "## Summary\nFixes it.")
        // An unclosed comment hides the rest, as on GitHub.
        #expect(PullRequestBody.displayMarkdown("Text\n<!-- never closed\nmore") == "Text")
        #expect(PullRequestBody.displayMarkdown("  \n") == "")
    }
}

struct PullRequestMentionTests {
    private let pullRequests = [
        PullRequestSummary(
            number: 12, title: "Fix the parser", url: "https://github.com/o/r/pull/12", author: "ana", headBranch: "fix-parser",
            baseBranch: "main", updatedAt: Date(timeIntervalSince1970: 100)),
        PullRequestSummary(
            number: 120, title: "Add a theme", url: "https://github.com/o/r/pull/120", author: "ben", headBranch: "themes",
            baseBranch: "main", updatedAt: Date(timeIntervalSince1970: 300)),
        PullRequestSummary(
            number: 312, title: "Speed up the parser", url: "https://github.com/o/r/pull/312", author: "cy",
            headBranch: "perf", baseBranch: "main", updatedAt: Date(timeIntervalSince1970: 200)),
    ]

    @Test func anEmptyQueryListsTheMostRecentlyUpdatedFirst() {
        #expect(PullRequestMention.matching("", in: pullRequests).map(\.number) == [120, 312, 12])
        #expect(PullRequestMention.matching("", in: pullRequests, limit: 1).map(\.number) == [120])
    }

    @Test func digitsMatchTheNumberExactFirst() {
        #expect(PullRequestMention.matching("12", in: pullRequests).map(\.number) == [12, 120, 312])
        #expect(PullRequestMention.matching("31", in: pullRequests).map(\.number) == [312])
        #expect(PullRequestMention.matching("9", in: pullRequests).isEmpty)
    }

    @Test func wordsMatchTitlesThenBranchesAndAuthors() {
        // "Speed up the parser" contains "parser" as "Fix the parser" does; the more recent comes first.
        #expect(PullRequestMention.matching("parser", in: pullRequests).map(\.number) == [312, 12])
        #expect(PullRequestMention.matching("fix", in: pullRequests).map(\.number) == [12])
        #expect(PullRequestMention.matching("PERF", in: pullRequests).map(\.number) == [312])
        #expect(PullRequestMention.matching("ben", in: pullRequests).map(\.number) == [120])
        #expect(PullRequestMention.matching("thème", in: pullRequests).map(\.number) == [120])
    }

    @Test func mentionsAreWholeHashNumbers() {
        #expect(PullRequestMention.numbers(in: "See #12 and (#7), [#3], not issue#4, #5x, ##6 or #8-9; #12 again.") == [12, 7, 3])
        #expect(PullRequestMention.numbers(in: "#1\n#2") == [1, 2])
        #expect(PullRequestMention.numbers(in: "nothing here") == [])
    }

    @Test func pickedMentionsContainTheirDurableRepositoryLink() {
        #expect(PullRequestMention.markdown(pullRequests[0]) == "[#12](https://github.com/o/r/pull/12)")
        var unsafe = pullRequests[0]
        unsafe.url = "file:///tmp/a"
        #expect(PullRequestMention.markdown(unsafe) == nil)
        unsafe.url = "https://token@example.com/pull/12"
        #expect(PullRequestMention.markdown(unsafe) == nil)
        unsafe.url = "https://example.com/a(b)/pull/12"
        #expect(PullRequestMention.markdown(unsafe) == "[#12](https://example.com/a%28b%29/pull/12)")
    }

    @Test func forksCheckOutOnABranchOfTheirOwn() {
        var pullRequest = pullRequests[0]
        #expect(PullRequestCheckout.localBranch(for: pullRequest, prefix: "coincide/") == "fix-parser")
        pullRequest.isCrossRepository = true
        pullRequest.headBranch = "Main"
        #expect(PullRequestCheckout.localBranch(for: pullRequest, prefix: "coincide/") == "coincide/pr-12/main")
        #expect(PullRequestCheckout.localBranch(for: pullRequest, prefix: "") == "pr-12/main")
        // Never one a thread's worktree would rename after its first message.
        #expect(!BranchNames.isTemporaryWorktreeBranch("coincide/pr-12/main", prefix: "coincide/"))
    }
}

@MainActor
struct PullRequestServiceTests {
    private let git = GitService(worktreesRoot: try! TestRepository.makeDirectory("worktrees"))

    private func summary(_ number: Int, head: String) -> PullRequestSummary {
        PullRequestSummary(number: number, title: "PR", url: "https://github.com/o/r/pull/\(number)", headBranch: head, baseBranch: "main")
    }

    @Test func availabilityExplainsWhatIsMissing() async throws {
        git.hostToolsOverride = false
        let service = PullRequestService(git: git)
        #expect(await service.availability(try TestRepository.makeDirectory("plain")) == .notRepository)
        #expect(await service.availability(try await TestRepository.make().url) == .noRemote)
        // Each its own repository: the host is cached for a minute per folder.
        let gitlab = try await TestRepository.make()
        try await gitlab.git("remote", "add", "origin", "git@gitlab.com:group/project.git")
        #expect(await service.availability(gitlab.url) == .unsupportedHost("GitLab"))
        let github = try await TestRepository.make()
        try await github.git("remote", "add", "origin", "https://github.com/o/r.git")
        // Signed out (as every host tool is here).
        #expect(await service.availability(github.url) == .needsGitHubCLI)
    }

    @Test func aWorktreeThatHasTheBranchIsUsedAsItIs() async throws {
        let repository = try await TestRepository.make()
        let existing = try await git.createWorktree(in: repository.url, branch: "feature", baseRef: nil)
        let service = PullRequestService(git: git)
        let worktree = try await service.prepareWorktree(
            for: summary(5, head: "feature"), in: repository.url, branchPrefix: "coincide/")
        #expect(worktree == PullRequestService.Worktree(path: existing.path, branch: "feature", reused: true))
    }

    @Test func theProjectFoldersOwnBranchIsNotCheckedOutTwice() async throws {
        let repository = try await TestRepository.make()
        let service = PullRequestService(git: git)
        await #expect(throws: GitError.self) {
            try await service.prepareWorktree(for: summary(5, head: "main"), in: repository.url, branchPrefix: "coincide/")
        }
        // Nothing was made for it.
        #expect(try await git.worktrees(repository.url).count == 1)
    }
}


struct PullRequestReviewSafetyTests {
    private var ready: PullRequestDetail {
        PullRequestDetail(
            summary: PullRequestSummary(number: 9, title: "Fix", url: "https://github.com/o/r/pull/9",
                headBranch: "fix", baseBranch: "main", checksState: .passing),
            mergeability: .mergeable, headCommit: String(repeating: "a", count: 40))
    }

    @Test func mergeRequiresAReadyRevision() {
        var detail = ready
        #expect(detail.canMerge)
        detail.headCommit = ""
        #expect(!detail.canMerge)
        detail = ready
        detail.summary.checksState = .pending
        #expect(!detail.canMerge)
        detail.summary.checksState = .failing
        #expect(!detail.canMerge)
        detail = ready
        detail.summary.reviewDecision = .changesRequested
        #expect(!detail.canMerge)
        detail.summary.reviewDecision = .reviewRequired
        #expect(!detail.canMerge)
        detail = ready
        detail.summary.isDraft = true
        #expect(!detail.canMerge)
        detail = ready
        detail.mergeability = .unknown
        #expect(!detail.canMerge)
        detail.mergeability = .conflicting
        #expect(!detail.canMerge)
        detail = ready
        detail.summary.state = .merged
        #expect(!detail.canMerge)
    }

    @Test func reviewRequiresAMessageUnlessApprovingAndUsesJSONInput() throws {
        #expect(!PullRequestReviewEvent.comment.accepts(body: "  "))
        #expect(!PullRequestReviewEvent.requestChanges.accepts(body: "\n"))
        #expect(PullRequestReviewEvent.approve.accepts(body: ""))
        let body = "Line one\n`$(echo not-a-command)` \"quoted\""
        let input = try PullRequestCommands.reviewBody(.requestChanges, body: body, headCommit: ready.headCommit)
        let parsed = try #require(JSONValue.parse(input))
        #expect(parsed["body"]?.string == body)
        #expect(parsed["event"]?.string == "REQUEST_CHANGES")
        #expect(parsed["commit_id"]?.string == ready.headCommit)
        #expect(PullRequestCommands.review(9).suffix(2) == ["--input", "-"])
    }

    @Test func detailsIncludeRevisionAndPublishedReviews() throws {
        let detail = try #require(PullRequestJSON.detail(#"{"number":9,"title":"Fix","url":"https://github.com/o/r/pull/9","headRefName":"fix","baseRefName":"main","headRefOid":"abc123","reviews":[{"author":{"login":"ana"},"state":"APPROVED","body":"Looks good"},{"state":"PENDING","body":"Unsubmitted"}]}"#))
        #expect(detail.headCommit == "abc123")
        #expect(detail.reviews.count == 1)
        #expect(detail.reviews.first?.author == "ana")
        #expect(detail.reviews.first?.body == "Looks good")
    }
}
