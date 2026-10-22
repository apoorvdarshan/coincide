import Foundation
import Testing
@testable import CoincideCore

private struct GitHubPRFixture: Sendable {
    let git: CheckpointFixture
    let stateURL: URL
    let executable: URL
    let environment: [String: String]
    let head: String
    let base: String
    var service: GitHubPullRequestService {
        .init(root: git.repository, environment: environment, gitExecutable: git.git, githubExecutable: executable)
    }
    static func make() async throws -> Self {
        let git = try await CheckpointFixture.make()
        do {
            let bare = git.root.appendingPathComponent("Published.git")
            _ = try await git.run(["init", "--bare", bare.path])
            _ = try await git.run(["remote", "add", "origin", bare.path])
            _ = try await git.run(["checkout", "-b", "feature/topic"])
            try git.write("feature.txt", "A committed feature\n"); try await git.commitAll()
            _ = try await git.run(["push", "--set-upstream", "origin", "feature/topic"])
            let head = try GitHubPullRequestService.line(await git.run(["rev-parse", "HEAD"]).output)
            let base = try GitHubPullRequestService.line(await git.run(["rev-parse", "main"]).output)
            #expect(try await git.run(["rev-parse", "refs/heads/feature/topic"], at: bare).text.trimmingCharacters(in: .whitespacesAndNewlines) == head)
            // Only fixture setup pushes, exclusively to its task-owned local bare repo.
            // Subsequent metadata names GitHub while the injected CLI never networks.
            _ = try await git.run(["remote", "set-url", "origin", "https://github.com/fork/project.git"])
            _ = try await git.run(["remote", "add", "upstream", "https://github.com/upstream/project.git"])
            let stateURL = git.root.appendingPathComponent("gh-state.json"), executable = git.root.appendingPathComponent("gh-fixture")
            let source = try #require(Bundle.module.url(forResource: "github_pull_requests", withExtension: "py", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            var environment = git.environment
            for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST", "GH_REPO", "GH_DEBUG", "PYTHONHOME", "PYTHONPATH"] { environment.removeValue(forKey: key) }
            environment["COINCIDE_GH_FIXTURE"] = stateURL.path
            environment["PYTHONNOUSERSITE"] = "1"
            environment["GH_CONFIG_DIR"] = git.root.appendingPathComponent("Empty gh config").path
            let result = Self(git: git, stateURL: stateURL, executable: executable, environment: environment, head: head, base: base)
            try result.writeState(["headRepository": "fork/project", "baseRepository": "upstream/project",
                "branch": "feature/topic", "headCommit": head, "baseCommit": base, "published": true,
                "existing": false, "creates": 0, "calls": []])
            return result
        } catch { git.cleanup(); throw error }
    }
    func state() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
    }
    func writeState(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    func change(_ body: (inout [String: Any]) -> Void) throws { var value = try state(); body(&value); try writeState(value) }
    func calls() throws -> [[String: Any]] { try state()["calls"] as? [[String: Any]] ?? [] }
    func createCount() throws -> Int { try state()["creates"] as? Int ?? 0 }
    func review() async throws -> GitHubPullRequestCreateReview { try await service.reviewCreate(title: "Reviewed title", body: "Reviewed body\n\nSecond paragraph", baseBranch: "main", isDraft: false) }
    func cleanup() { git.cleanup() }
}

private func githubPRError(_ kind: GitHubPullRequestError.Kind, _ body: () async throws -> Void) async throws {
    do { try await body(); Issue.record("The invalid fixture operation unexpectedly succeeded.") }
    catch let error as GitHubPullRequestError { #expect(error.kind == kind) }
}
private func githubPREventually(_ predicate: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned GitHub fixture did not reach its controlled boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestContextAndReadsUseExactPublishedForkAndKeepGitStateUnchanged() async throws {
    let f = try await GitHubPRFixture.make(); defer { f.cleanup() }
    let before = try await f.git.state(), context = try await f.service.context()
    #expect(context.readiness == .ready && context.canCreate)
    #expect(context.repository.nameWithOwner == "upstream/project" && context.headRepository?.nameWithOwner == "fork/project")
    #expect(context.upstream?.remoteName == "origin" && context.upstream?.branch == "feature/topic" && context.upstream?.commit == f.head)
    #expect(context.headCommit == f.head && context.baseBranches == ["develop", "main"] && !context.baseBranchesTruncated)
    try f.change { $0["existing"] = true }
    let page = try await f.service.list(query: .init(author: "@me", limit: 1))
    #expect(page.items.count == 1 && page.truncated)
    let reference = try #require(page.items.first?.reference), detail = try await f.service.detail(reference)
    #expect(detail.summary.author == "dependabot[bot]" && detail.summary.headRepository == context.headRepository)
    #expect(detail.checks.first?.url == "https://github.com/upstream/project/actions/runs/1")
    #expect(detail.summary.checksState == .success && detail.summary.reviewDecision == .reviewRequired)
    #expect(try await f.service.resolve("#42") == detail)
    #expect(try await f.service.resolve("https://github.com/upstream/project/pull/42") == detail)
    #expect(try await f.service.resolve("feature/topic") == detail)
    #expect(try await f.git.state() == before)
    #expect(try f.createCount() == 0)
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestCreateUsesLiteralReviewedFieldsAndOnePostAcrossConcurrentAttempts() async throws {
    let f = try await GitHubPRFixture.make(); defer { f.cleanup() }
    let before = try await f.git.state()
    try f.change { $0["foreignSameBranch"] = true }
    let title = "Literal $() `quoted` ; title", body = "Leading paragraph\n\nUnicode 😀 and literal $(touch never-execute)\n"
    let review = try await f.service.reviewCreate(title: title, body: body, baseBranch: "main", isDraft: true)
    #expect(review.baseCommit == f.base && review.context.headCommit == f.head)
    async let first = f.service.create(review)
    async let second = f.service.create(review)
    let outcomes = try await [first, second]
    #expect(outcomes.filter { if case .created = $0 { return true }; return false }.count == 1)
    #expect(outcomes.filter { if case .openedExisting = $0 { return true }; return false }.count == 1)
    #expect(try f.createCount() == 1)
    let post = try #require(try f.calls().first { ($0["args"] as? [String])?.prefix(2) == ["pr", "create"] })
    let args = try #require(post["args"] as? [String])
    #expect(args.contains("--repo=github.com/upstream/project") && args.contains("--head=fork:feature/topic"))
    #expect(args.contains("--base=main") && args.contains("--title=" + title) && args.contains("--draft"))
    #expect(args.contains("--body-file=-") && !args.contains("--dry-run") && !args.contains("--fill"))
    #expect(post["stdin"] as? String == body)
    #expect(!FileManager.default.fileExists(atPath: f.git.repository.appendingPathComponent("never-execute").path))
    #expect(try await f.git.state() == before)
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestExistingExactHeadOpensBeforeAChangedReviewedBaseWithoutPosting() async throws {
    let f = try await GitHubPRFixture.make(); defer { f.cleanup() }
    let review = try await f.review()
    try f.change { $0["existing"] = true; $0["selectedBase"] = "develop"; $0["baseCommit"] = String(repeating: "e", count: 40) }
    let result = try await f.service.create(review)
    guard case .openedExisting(let detail) = result else { Issue.record("An existing exact-head PR must be opened without another POST."); return }
    #expect(detail.summary.baseBranch == "develop" && detail.summary.baseCommit != review.baseCommit)
    #expect(try f.createCount() == 0)
}

@Test(.timeLimit(.minutes(1)), arguments: [true, false])
func githubPullRequestLostCreateReplyOnlyReconcilesReadOnlyWithoutRepeatingPost(mutated: Bool) async throws {
    let f = try await GitHubPRFixture.make(); defer { f.cleanup() }
    let before = try await f.git.state(), review = try await f.review()
    try f.change { $0["createMode"] = mutated ? "lostAfter" : "lostBefore" }
    do { _ = try await f.service.create(review); Issue.record("A lost creation reply must remain uncertain.") }
    catch let error as GitHubPullRequestError { #expect(error.kind == .outcomeUncertain && error.mayHaveCreated) }
    let first = try await f.service.reconcileCreate(review), second = try await f.service.reconcileCreate(review)
    #expect(first == second)
    if mutated {
        guard case .found(let detail) = first else { Issue.record("The exact created PR must be recovered by reads."); return }
        #expect(detail.summary.reference.number == 42)
    } else { #expect(first == .notFound) }
    #expect(try f.createCount() == 1)
    #expect(try await f.git.state() == before)
}

@Test(.timeLimit(.minutes(1)), arguments: ["head", "branch", "remote", "base", "replacement", "forgedReview"])
func githubPullRequestStaleOrForgedReviewCannotPost(change: String) async throws {
    let f = try await GitHubPRFixture.make(); defer { f.cleanup() }
    var review = try await f.review()
    switch change {
    case "head": try f.git.write("another.txt", "Another committed change\n"); try await f.git.commitAll()
    case "branch": _ = try await f.git.run(["checkout", "main"])
    case "remote": _ = try await f.git.run(["remote", "set-url", "origin", "https://github.com/other/project.git"])
    case "base": try f.change { $0["baseCommit"] = String(repeating: "f", count: 40) }
    case "replacement":
        let original = f.git.root.appendingPathComponent("Original retained repository")
        try FileManager.default.moveItem(at: f.git.repository, to: original)
        try FileManager.default.copyItem(at: original, to: f.git.repository)
    default:
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(review)) as? [String: Any])
        var context = try #require(object["context"] as? [String: Any])
        context["repository"] = ["host": "github.com", "owner": "unreviewed", "name": "project"]
        object["context"] = context
        review = try JSONDecoder().decode(GitHubPullRequestCreateReview.self, from: JSONSerialization.data(withJSONObject: object))
    }
    let changed = try await f.git.state()
    do { _ = try await f.service.create(review); Issue.record("Changed checkout or review evidence must fail before POST.") }
    catch let error as GitHubPullRequestError { #expect(!error.mayHaveCreated) }
    #expect(try f.createCount() == 0)
    #expect(try await f.git.state() == changed)
}

@Test(.timeLimit(.minutes(1)), arguments: ["unpublished", "unpushed", "ambiguous", "detached"])
func githubPullRequestContextReturnsActionableReadinessInsteadOfCreating(change: String) async throws {
    let f = try await GitHubPRFixture.make(); defer { f.cleanup() }
    let expected: GitHubPullRequestReadiness
    switch change {
    case "unpublished":
        _ = try await f.git.run(["branch", "--unset-upstream"]); expected = .unpublished
    case "unpushed":
        try f.git.write("unpushed.txt", "Still local\n"); try await f.git.commitAll(); expected = .unpushedCommits
    case "ambiguous":
        _ = try await f.git.run(["config", "remote.origin.pushurl", "https://github.com/another/project.git"]); expected = .ambiguousRemote
    default: _ = try await f.git.run(["checkout", "--detach"]); expected = .detachedHead
    }
    let context = try await f.service.context()
    #expect(context.readiness == expected && !context.canCreate)
    #expect(try f.createCount() == 0)
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestDefaultBranchCanExplicitlyChooseAnotherBase() async throws {
    let f = try await GitHubPRFixture.make(); defer { f.cleanup() }
    _ = try await f.git.run(["checkout", "main"])
    _ = try await f.git.run(["remote", "remove", "upstream"])
    _ = try await f.git.run(["config", "branch.main.remote", "origin"])
    _ = try await f.git.run(["config", "branch.main.merge", "refs/heads/main"])
    try f.change { $0["baseRepository"] = "fork/project"; $0["branch"] = "main"; $0["headCommit"] = f.base }
    let context = try await f.service.context()
    #expect(context.readiness == .defaultBranch)
    let review = try await f.service.reviewCreate(title: "Explicit alternate base", body: "Reviewed", baseBranch: "develop")
    #expect(review.baseBranch == "develop")
    let result = try await f.service.create(review)
    guard case .created(let detail) = result else { Issue.record("A different explicitly selected base is allowed."); return }
    #expect(detail.summary.headBranch == "main" && detail.summary.baseBranch == "develop")
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestUsesPublishedUpstreamBranchRatherThanTheLocalAlias() async throws {
    let f = try await GitHubPRFixture.make(); defer { f.cleanup() }
    let bare = f.git.root.appendingPathComponent("Published.git")
    _ = try await f.git.run(["push", bare.path, "HEAD:refs/heads/published-topic"])
    _ = try await f.git.run(["config", "branch.feature/topic.merge", "refs/heads/published-topic"])
    try f.change { $0["branch"] = "published-topic" }
    let review = try await f.review()
    #expect(review.context.branch == "feature/topic" && review.context.upstream?.branch == "published-topic")
    _ = try await f.service.create(review)
    let post = try #require(try f.calls().first { ($0["args"] as? [String])?.prefix(2) == ["pr", "create"] })
    #expect((post["args"] as? [String])?.contains("--head=fork:published-topic") == true)
    #expect(try f.createCount() == 1)
}

@Test(.timeLimit(.minutes(1)), arguments: ["missing", "unauthenticated", "http401", "http403", "http429", "malformed", "overflow"])
func githubPullRequestFailuresAreBoundedTypedAndNeverExposeCredentialDiagnostics(mode: String) async throws {
    let f = try await GitHubPRFixture.make(); defer { f.cleanup() }
    try f.change { $0["mode"] = mode }
    let expected: GitHubPullRequestError.Kind
    switch mode {
    case "missing": expected = .missingCLI
    case "unauthenticated", "http401": expected = .unauthenticated
    case "http403": expected = .accessDenied
    case "http429": expected = .rateLimited
    case "malformed": expected = .invalidResponse
    default: expected = .outputLimit
    }
    let service = mode == "missing" ? GitHubPullRequestService(root: f.git.repository, environment: f.environment, gitExecutable: f.git.git, githubExecutable: nil) : f.service
    do { _ = try await service.context(); Issue.record("The controlled failing peer must not report a usable context.") }
    catch let error as GitHubPullRequestError {
        #expect(error.kind == expected && !error.mayHaveCreated)
        #expect(!error.localizedDescription.contains("synthetic-secret") && !error.localizedDescription.contains("synthetic-token"))
    }
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestCancellationDrainsOwnedCLIAndChildWithoutTouchingGit() async throws {
    let f = try await GitHubPRFixture.make(); defer { f.cleanup() }
    let before = try await f.git.state()
    try f.change { $0["mode"] = "stalled" }
    let operation = Task { try await f.service.context() }
    do {
        try await githubPREventually { FileManager.default.fileExists(atPath: f.stateURL.deletingPathExtension().appendingPathExtension("entered").path) }
        operation.cancel()
        do { _ = try await operation.value; Issue.record("Cancellation must stop the owned CLI.") }
        catch is CancellationError { }
        #expect(FileManager.default.fileExists(atPath: f.stateURL.deletingPathExtension().appendingPathExtension("parent-stopped").path))
        #expect(FileManager.default.fileExists(atPath: f.stateURL.deletingPathExtension().appendingPathExtension("child-stopped").path))
        #expect(try await f.git.state() == before)
    } catch { operation.cancel(); _ = try? await operation.value; throw error }
}

private func githubPREngineEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The production PR service did not reach its durable Engine boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["created", "lostBefore", "lostAfter"])
func githubPullRequestProductionServiceThroughEngineCommitsBeforeCreateAndReopensWithoutReplay(mode: String) async throws {
    let f = try await GitHubPRFixture.make()
    let database = f.git.root.appendingPathComponent("workspace.sqlite")
    let release = f.git.root.appendingPathComponent("release-owned-create")
    let project = WorkspaceProject(path: f.git.repository.path)
    var thread = CodingThread(project: project, model: "Preserved provider model")
    thread.draft = "Draft before GitHub review"
    var seed = WorkspaceSnapshot(); seed.projects = [project]; seed.threads = [thread]
    var activeEngine: WorkspaceEngine?
    func makeEngine() throws -> WorkspaceEngine {
        try .init(url: database,
            providerFactory: { _ in throw CoincideError("Pull request creation must never start a provider.") },
            identityResolver: { _ in nil },
            pullRequestFactory: { root in
                GitHubPullRequestService(root: root, environment: f.environment,
                    gitExecutable: f.git.git, githubExecutable: f.executable)
            })
    }
    do {
        let before = try await f.git.state()
        try await WorkspaceDatabase(url: database).save(seed, event: "production.github.fixture")
        let first = try makeEngine(); activeEngine = first; _ = try await first.load()
        let review = try await first.reviewPullRequestCreation(projectID: project.id, workspacePath: project.path,
            title: "Durably reviewed title", body: "Durably reviewed body\n\nLiteral 😀 content", baseBranch: "main", isDraft: true)
        try f.change {
            $0["databasePath"] = database.path; $0["operationID"] = review.id.uuidString
            $0["requireDurableDispatch"] = true; $0["createGate"] = release.path; $0["createMode"] = mode
        }
        async let one = first.beginPullRequestCreation(projectID: project.id, review: review)
        async let two = first.beginPullRequestCreation(projectID: project.id, review: review)
        let accepted = try await (one, two)
        #expect(accepted.0 == accepted.1)
        try await githubPREventually { FileManager.default.fileExists(atPath: f.stateURL.deletingPathExtension().appendingPathExtension("create-entered").path) }
        let dispatched = try await WorkspaceDatabase(url: database).load()
        let operation = try #require(dispatched.pullRequestCreation(review.id))
        #expect(operation.phase == .dispatching && operation.review == review)
        let running = try await WorkspaceDatabase(url: database).effects(commandID: review.id)
        #expect(running.count == 1 && running.first?.id == operation.effectID && running.first?.status == .running)
        #expect(try f.state()["durableDispatchObserved"] as? Bool == true)
        await #expect(throws: WorkspaceCommandError.self) {
            try await first.dispatch(.submit(threadID: thread.id, text: "Must remain blocked while GitHub owns the checkout"))
        }
        let latestDraft = "Latest draft typed while the external request is held"
        _ = try await first.dispatch(.editThread(thread.id, .draft(latestDraft)))
        try Data("release\n".utf8).write(to: release)
        let expectedPhase: PullRequestCreationPhase = mode == "created" ? .created : .unconfirmed
        try await githubPREngineEventually { await first.current().snapshot.pullRequestCreation(review.id)?.phase == expectedPhase }
        let completed = await first.current().snapshot
        #expect(completed.threads[0].draft == latestDraft && completed.threads[0].messages.isEmpty)
        #expect(completed.threads[0].runHistory == nil && completed.threads[0].activeRun == nil && completed.threads[0].queuedTurns.isEmpty)
        #expect(completed.threads[0].model == thread.model && completed.threads[0].permission == thread.permission)
        #expect(try f.createCount() == 1)
        #expect(try await f.git.state() == before)
        #expect(try await WorkspaceDatabase(url: database).rebuildProjection().snapshot == completed)
        await first.shutdown(); activeEngine = nil

        let callsBeforeReopen = try f.calls().count
        let reopened = try makeEngine(); activeEngine = reopened
        let restored = try await reopened.load()
        #expect(restored.pullRequestCreation(review.id)?.phase == expectedPhase)
        #expect(restored.threads[0].draft == latestDraft)
        #expect(try f.calls().count == callsBeforeReopen)
        #expect(try await reopened.beginPullRequestCreation(projectID: project.id, review: review) == accepted.0)
        if mode != "created" {
            _ = try await reopened.reconcilePullRequestCreation(operationID: review.id)
            let reconciled = await reopened.current().snapshot
            if mode == "lostAfter" {
                #expect(reconciled.pullRequestCreation(review.id)?.phase == .openedExisting)
                #expect(!reconciled.isPullRequestCreationLocked(path: project.path))
                let outcome = try #require(reconciled.pullRequestCreation(review.id)?.result)
                guard case .openedExisting(let detail) = outcome else { throw CoincideError("The exact PR was not reconciled.") }
                #expect(detail.summary.headCommit == f.head && detail.summary.baseCommit == f.base)
            } else {
                #expect(reconciled.pullRequestCreation(review.id)?.phase == .unconfirmed)
                #expect(reconciled.pullRequestCreation(review.id)?.error == PullRequestCreationOperation.notFoundMessage)
                #expect(reconciled.isPullRequestCreationLocked(path: project.path))
                _ = try await reopened.reconcilePullRequestCreation(operationID: review.id)
            }
        }
        let final = await reopened.current().snapshot
        let effects = try await WorkspaceDatabase(url: database).effects(commandID: review.id)
        #expect(effects.count == 1 && effects.first?.status == .succeeded)
        #expect(try f.createCount() == 1)
        let createCalls = try f.calls().filter { ($0["args"] as? [String])?.prefix(2) == ["pr", "create"] }
        #expect(createCalls.count == 1 && createCalls.first?["stdin"] as? String == review.body)
        #expect(final.threads[0].draft == latestDraft && final.threads[0].messages.isEmpty && final.threads[0].runHistory == nil)
        #expect(try await f.git.state() == before)
        #expect(try await WorkspaceDatabase(url: database).rebuildProjection().snapshot == final)
        await reopened.shutdown(); activeEngine = nil
        f.cleanup()
    } catch {
        try? Data("release\n".utf8).write(to: release)
        await activeEngine?.shutdown()
        f.cleanup()
        throw error
    }
}

@Test func githubPullRequestEnvironmentScopesCredentialsAndDisablesRedirectsWithoutReadingTokens() throws {
    let source = ["GH_TOKEN": "synthetic-cloud", "GH_ENTERPRISE_TOKEN": "synthetic-enterprise", "GH_HOST": "enterprise.example.invalid",
        "GH_REPO": "unreviewed/other", "GH_DEBUG": "api", "GIT_DIR": "/unreviewed", "GIT_CONFIG_PARAMETERS": "unsafe", "SSH_AUTH_SOCK": "/kept-agent"]
    let cloud = GitHubPullRequestCommand.sanitizedEnvironment(source, host: "github.com")
    #expect(cloud["GH_ENTERPRISE_TOKEN"] == nil && cloud["GH_TOKEN"] == "synthetic-cloud")
    #expect(cloud["GH_REPO"] == nil && cloud["GH_DEBUG"] == nil && cloud["GIT_DIR"] == nil && cloud["GIT_CONFIG_PARAMETERS"] == nil)
    #expect(cloud["SSH_AUTH_SOCK"] == source["SSH_AUTH_SOCK"] && cloud["GH_PROMPT_DISABLED"] == "1")
    let enterprise = GitHubPullRequestCommand.sanitizedEnvironment(source, host: "enterprise.example.invalid")
    #expect(enterprise["GH_ENTERPRISE_TOKEN"] == "synthetic-enterprise")
    #expect(throws: (any Error).self) { try GitHubRepository(host: "user:secret@example.invalid", owner: "owner", name: "repo") }
    #expect(throws: (any Error).self) { try GitHubRepository(host: "bad%20host.invalid", owner: "owner", name: "repo") }
}
