import Foundation
import Testing
@testable import CoincideCore

struct GitHubPRActionFixture: Sendable {
    let git: CheckpointFixture
    let stateURL: URL
    let executable: URL
    let environment: [String: String]
    let head: String
    let credentials: GitHubCredentialOverrides
    var service: GitHubPullRequestActionService {
        .init(base: .init(root: git.repository, environment: environment, gitExecutable: git.git, githubExecutable: executable, credentials: credentials))
    }
    var reference: GitHubPullRequestReference { try! .init(repository: .init(owner: "upstream", name: "project"), number: 42) }
    static func make(sameRepository: Bool = false, _ edit: (inout [String: Any]) -> Void = { _ in }) async throws -> Self {
        let git = try await CheckpointFixture.make()
        do {
            _ = try await git.run(["remote", "add", "origin", "https://github.com/fork/project.git"])
            _ = try await git.run(["remote", "add", "upstream", "https://github.com/upstream/project.git"])
            let stateURL = git.root.appendingPathComponent("gh-actions.json"), executable = git.root.appendingPathComponent("gh-actions")
            let source = try #require(Bundle.module.url(forResource: "github_pull_request_actions", withExtension: "py", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            var environment = git.environment
            for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST", "GH_REPO", "GH_DEBUG", "PYTHONHOME", "PYTHONPATH"] { environment.removeValue(forKey: key) }
            environment["COINCIDE_GH_FIXTURE"] = stateURL.path; environment["PYTHONNOUSERSITE"] = "1"
            environment["GH_CONFIG_DIR"] = git.root.appendingPathComponent("Empty gh config").path
            let head = String(repeating: "a", count: 40)
            var state: [String: Any] = ["baseRepository": "upstream/project", "headRepository": sameRepository ? "upstream/project" : "fork/project",
                                        "headBranch": "feature/topic", "baseBranch": "main", "headCommit": head, "baseCommit": String(repeating: "b", count: 40),
                                        "movedCommit": String(repeating: "c", count: 40), "permissions": ["push": true], "calls": []]
            edit(&state)
            try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
            return .init(git: git, stateURL: stateURL, executable: executable, environment: environment, head: head, credentials: GitHubCredentialOverrides())
        } catch { git.cleanup(); throw error }
    }
    func state() throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]) }
    func change(_ body: (inout [String: Any]) -> Void) throws {
        var value = try state(); body(&value); try JSONSerialization.data(withJSONObject: value).write(to: stateURL)
    }
    func calls() throws -> [[String: Any]] { try state()["calls"] as? [[String: Any]] ?? [] }
    func writes() throws -> [String] {
        let path = stateURL.deletingPathExtension().appendingPathExtension("writes")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map(String.init)
    }
    func call(_ prefix: [String]) throws -> [String: Any]? { try calls().first { ($0["args"] as? [String]).map { Array($0.prefix(prefix.count)) == prefix } ?? false } }
    func cleanup() { git.cleanup() }
}

private func expectActionError(_ kind: GitHubPullRequestActionError.Kind, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("The action unexpectedly succeeded.") }
    catch let error as GitHubPullRequestActionError { #expect(error.kind == kind) }
    catch { Issue.record("Unexpected error \(error)") }
}

@Test(.timeLimit(.minutes(1))) func pullRequestActionStateOffersT3ActionsByStateAndPermission() async throws {
    let f = try await GitHubPRActionFixture.make { $0["runs"] = [["id": 7, "head_sha": String(repeating: "a", count: 40), "head_branch": "feature/topic", "head_repository": ["owner": ["login": "fork"]]],
                                                            ["id": 8, "head_sha": String(repeating: "d", count: 40), "head_branch": "feature/topic", "head_repository": ["owner": ["login": "fork"]]]] }
    defer { f.cleanup() }
    let state = try await f.service.actionState(f.reference)
    #expect(state.state == .open && !state.isDraft && state.isCrossRepository && state.headCommit == f.head && state.permissions.canWrite)
    #expect(state.pendingWorkflowRuns == [7])
    #expect(state.availableActions == [.merge(.merge), .merge(.squash), .merge(.rebase), .enableAutoMerge(.merge), .enableAutoMerge(.squash), .enableAutoMerge(.rebase),
                                       .draft, .approveWorkflows, .close])
    try f.change { $0["isDraft"] = true; $0["mergeStateStatus"] = "BEHIND"; $0["runs"] = [] }
    #expect(try await f.service.actionState(f.reference).availableActions == [.ready, .updateBranch(rebase: false), .updateBranch(rebase: true), .close])
    try f.change { $0["state"] = "MERGED"; $0["isDraft"] = false }
    #expect(try await f.service.actionState(f.reference).availableActions == [.revert])
    try f.change { $0["permissions"] = ["triage": true] ; $0["state"] = "OPEN" }
    let readOnly = try await f.service.actionState(f.reference)
    #expect(readOnly.availableActions.isEmpty)
    await expectActionError(.unavailable) { _ = try await f.service.reviewAction(.merge(.squash), reference: f.reference, removeAgentCredits: false) }
    #expect(try f.writes().isEmpty)
    let unrelated = try GitHubPullRequestReference(repository: .init(owner: "other", name: "repo"), number: 1)
    await #expect(throws: GitHubPullRequestError.self) { _ = try await f.service.actionState(unrelated) }
}

@Test(.timeLimit(.minutes(1))) func pullRequestMergeIsHeadPinnedAndSendsOnlyTheReviewedCleanedBody() async throws {
    let body = "Summary\n\nCo-authored-by: Alice <alice@example.com>\nCo-authored-by: Claude <noreply@anthropic.com>\n"
    let f = try await GitHubPRActionFixture.make { $0["mergeBody"] = body }; defer { f.cleanup() }
    let review = try await f.service.reviewAction(.merge(.squash), reference: f.reference, removeAgentCredits: true)
    #expect(review.mergeBody == "Summary\n\nCo-authored-by: Alice <alice@example.com>" && review.originalMergeBody == body && review.state.headCommit == f.head)
    let outcome = try await f.service.perform(review)
    #expect(outcome.action == .merge(.squash))
    let merge = try #require(try f.call(["pr", "merge"]))
    let args = try #require(merge["args"] as? [String])
    #expect(args == ["pr", "merge", "42", "--repo=github.com/upstream/project", "--squash", "--match-head-commit=" + f.head, "--body-file=-"])
    #expect(!args.contains("--admin") && !args.contains("--delete-branch") && !args.contains("-d"))
    #expect(merge["stdin"] as? String == "Summary\n\nCo-authored-by: Alice <alice@example.com>")
    #expect(try f.writes() == ["merge"])
    // Without cleanup or for rebase no body is sent.
    let plain = try await GitHubPRActionFixture.make(); defer { plain.cleanup() }
    let rebase = try await plain.service.reviewAction(.merge(.rebase), reference: plain.reference, removeAgentCredits: true)
    #expect(rebase.mergeBody == nil)
    _ = try await plain.service.perform(rebase)
    #expect(try #require(try plain.call(["pr", "merge"]))["args"] as? [String] == ["pr", "merge", "42", "--repo=github.com/upstream/project", "--rebase", "--match-head-commit=" + plain.head])
}

@Test(.timeLimit(.minutes(1))) func pullRequestActionsRefuseStaleHeadsAndNeverRepeatUncertainWrites() async throws {
    let moved = try await GitHubPRActionFixture.make(); defer { moved.cleanup() }
    let review = try await moved.service.reviewAction(.merge(.merge), reference: moved.reference, removeAgentCredits: false)
    try moved.change { $0["headCommit"] = String(repeating: "e", count: 40) }
    await expectActionError(.staleReview) { _ = try await moved.service.perform(review) }
    let movedMerge = try moved.call(["pr", "merge"])
    #expect(try moved.writes().isEmpty && movedMerge == nil)

    let rejected = try await GitHubPRActionFixture.make { $0["mergeMode"] = "rejected" }; defer { rejected.cleanup() }
    let first = try await rejected.service.reviewAction(.merge(.squash), reference: rejected.reference, removeAgentCredits: false)
    await expectActionError(.staleReview) { _ = try await rejected.service.perform(first) }

    let uncertain = try await GitHubPRActionFixture.make { $0["mergeMode"] = "uncertain" }; defer { uncertain.cleanup() }
    let second = try await uncertain.service.reviewAction(.merge(.squash), reference: uncertain.reference, removeAgentCredits: false)
    await expectActionError(.uncertain) { _ = try await uncertain.service.perform(second) }
    #expect(try uncertain.calls().filter { ($0["args"] as? [String])?.prefix(2) == ["pr", "merge"] }.count == 1)
    let error = GitHubPullRequestActionError(.uncertain, detail: "lost https://user:secret@example.invalid/?token=abc")
    #expect(!(error.errorDescription ?? "").contains("secret") && !(error.errorDescription ?? "").contains("token=abc"))
}

@Test(.timeLimit(.minutes(1)), arguments: ["baseBranch", "baseCommit", "baseBranchBytes"])
func pullRequestActionsRefuseChangedReviewedBaseWhileTheHeadIsUnchanged(field: String) async throws {
    let f = try await GitHubPRActionFixture.make { if field == "baseBranchBytes" { $0["baseBranch"] = "caf\u{e9}" } }
    defer { f.cleanup() }
    let review = try await f.service.reviewAction(.merge(.squash), reference: f.reference, removeAgentCredits: false)
    try f.change {
        if field == "baseBranchBytes" { $0["baseBranch"] = "cafe\u{301}" }
        else { $0[field] = field == "baseBranch" ? "release" : String(repeating: "d", count: 40) }
    }
    let current = try await f.service.actionState(f.reference)
    #expect(current.headCommit == review.state.headCommit && current.headCommit == f.head)
    if field != "baseCommit" { #expect(!current.baseBranch.utf8.elementsEqual(review.state.baseBranch.utf8)) }
    else { #expect(current.baseCommit != review.state.baseCommit) }
    await expectActionError(.staleReview) { _ = try await f.service.perform(review) }
    #expect(try f.writes().isEmpty && f.call(["pr", "merge"]) == nil)
}

@Test(.timeLimit(.minutes(1))) func pullRequestStateActionsUseExactGhCommands() async throws {
    let f = try await GitHubPRActionFixture.make(sameRepository: true) { $0["allowAutoMerge"] = true }; defer { f.cleanup() }
    _ = try await f.service.perform(try await f.service.reviewAction(.enableAutoMerge(.squash), reference: f.reference, removeAgentCredits: false))
    #expect(try f.call(["pr", "merge"])?["args"] as? [String] == ["pr", "merge", "42", "--repo=github.com/upstream/project", "--auto", "--squash", "--match-head-commit=" + f.head])
    #expect(try await f.service.actionState(f.reference).autoMergeEnabled)
    _ = try await f.service.perform(try await f.service.reviewAction(.disableAutoMerge, reference: f.reference, removeAgentCredits: false))
    _ = try await f.service.perform(try await f.service.reviewAction(.draft, reference: f.reference, removeAgentCredits: false))
    #expect(try await f.service.actionState(f.reference).isDraft)
    _ = try await f.service.perform(try await f.service.reviewAction(.ready, reference: f.reference, removeAgentCredits: false))
    _ = try await f.service.perform(try await f.service.reviewAction(.close, reference: f.reference, removeAgentCredits: false))
    #expect(try await f.service.actionState(f.reference).availableActions == [.reopen, .deleteBranch])
    _ = try await f.service.perform(try await f.service.reviewAction(.reopen, reference: f.reference, removeAgentCredits: false))
    #expect(try f.writes() == ["auto-merge", "disable-auto", "draft", "ready", "close", "reopen"])
    let commands = try f.calls().compactMap { $0["args"] as? [String] }.filter { $0.first == "pr" && $0.count > 1 && $0[1] != "view" }
    #expect(commands.contains(["pr", "ready", "42", "--repo=github.com/upstream/project", "--undo"]))
    #expect(commands.contains(["pr", "close", "42", "--repo=github.com/upstream/project"]))
    #expect(commands.contains(["pr", "merge", "42", "--repo=github.com/upstream/project", "--disable-auto"]))
}

@Test(.timeLimit(.minutes(1))) func pullRequestBranchDeletionRevertUpdateAndWorkflowApprovalVerifyTheReviewedHead() async throws {
    let closed = try await GitHubPRActionFixture.make(sameRepository: true) { $0["state"] = "CLOSED" }; defer { closed.cleanup() }
    let deletion = try await closed.service.reviewAction(.deleteBranch, reference: closed.reference, removeAgentCredits: false)
    try closed.change { $0["refCommit"] = String(repeating: "f", count: 40) }
    await expectActionError(.staleReview) { _ = try await closed.service.perform(deletion) }
    try closed.change { $0["refCommit"] = closed.head }
    _ = try await closed.service.perform(try await closed.service.reviewAction(.deleteBranch, reference: closed.reference, removeAgentCredits: false))
    let refs = try #require(try closed.state()["updateRefs"] as? [String: Any])
    #expect(refs["ref"] as? String == "refs/heads/feature/topic" && refs["before"] as? String == closed.head && refs["id"] as? String == "R_fixture")
    let again = try await closed.service.perform(try await closed.service.reviewAction(.deleteBranch, reference: closed.reference, removeAgentCredits: false))
    let closedWrites = try closed.writes()
    #expect(again.message.contains("already deleted") && closedWrites == ["delete-branch"])

    let open = try await GitHubPRActionFixture.make(sameRepository: true); defer { open.cleanup() }
    await expectActionError(.unavailable) { _ = try await open.service.reviewAction(.deleteBranch, reference: open.reference, removeAgentCredits: false) }

    let merged = try await GitHubPRActionFixture.make { $0["state"] = "MERGED" }; defer { merged.cleanup() }
    let revert = try await merged.service.perform(try await merged.service.reviewAction(.revert, reference: merged.reference, removeAgentCredits: false))
    #expect(revert.revertReference?.number == 43 && revert.revertURL == "https://github.com/upstream/project/pull/43")

    let behind = try await GitHubPRActionFixture.make { $0["mergeStateStatus"] = "BEHIND" }; defer { behind.cleanup() }
    _ = try await behind.service.perform(try await behind.service.reviewAction(.updateBranch(rebase: true), reference: behind.reference, removeAgentCredits: false))
    let update = try #require(try behind.state()["updateBranch"] as? [String: Any])
    #expect(update["oid"] as? String == behind.head && update["method"] as? String == "REBASE" && update["id"] as? String == "PR_kwFixture42")

    let fork = try await GitHubPRActionFixture.make { $0["runs"] = [["id": 7, "head_sha": String(repeating: "a", count: 40), "head_branch": "feature/topic", "head_repository": ["owner": ["login": "fork"]]],
                                                                ["id": 9, "head_sha": String(repeating: "a", count: 40), "head_branch": "other", "head_repository": ["owner": ["login": "fork"]]]] }
    defer { fork.cleanup() }
    let approval = try await fork.service.reviewAction(.approveWorkflows, reference: fork.reference, removeAgentCredits: false)
    #expect(approval.workflowRunIDs == [7])
    let approved = try await fork.service.perform(approval)
    let approvedRuns = try fork.state()["approved"] as? [Int]
    #expect(approved.approvedRuns == 1 && approvedRuns == [7])
    #expect(try fork.call(["api", "--hostname=github.com", "--method=POST"])?["args"] as? [String]
            == ["api", "--hostname=github.com", "--method=POST", "repos/upstream/project/actions/runs/7/approve"])
}

@Test(.timeLimit(.minutes(1))) func savedGitHubTokenReachesGhOnlyThroughTheChildEnvironment() async throws {
    let token = "fixture-synthetic-value-not-a-credential"
    let f = try await GitHubPRActionFixture.make { $0["expectedToken"] = "fixture-synthetic-value-not-a-credential" }; defer { f.cleanup() }
    _ = try await f.service.actionState(f.reference)
    #expect(try f.calls().allSatisfy { $0["hasToken"] as? Bool == false })
    f.credentials.set(token, host: "github.com")
    _ = try await f.service.actionState(f.reference)
    let latest = try f.calls().suffix(2)
    #expect(latest.allSatisfy { $0["tokenMatches"] as? Bool == true && $0["tokenInArgs"] as? Bool == false })
    f.credentials.set(nil, host: "github.com")
    #expect(!f.credentials.hasToken(for: "github.com"))
    #expect(!SourceControlTokenStore.validToken("has space") && !SourceControlTokenStore.validToken("") && SourceControlTokenStore.validToken(token))
    var environment: [String: String] = ["GITHUB_TOKEN": "ambient"]
    let overrides = GitHubCredentialOverrides(); overrides.set(token, host: "enterprise.example.invalid")
    overrides.apply(to: &environment, host: "enterprise.example.invalid")
    #expect(environment["GH_ENTERPRISE_TOKEN"] == token && environment["GH_HOST"] == "enterprise.example.invalid" && environment["GH_TOKEN"] == nil)
}
