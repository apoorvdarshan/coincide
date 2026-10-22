import Darwin
import Foundation
import Testing
@testable import CoincideCore

struct PRCheckoutFixture: Sendable {
    let api: GitHubPRFixture
    let managed: URL
    let baseRemote: URL
    let headRemote: URL
    var source: URL { api.git.repository }
    var environment: [String: String] {
        var value = api.environment; value["GIT_ALLOW_PROTOCOL"] = "file"; return value
    }
    static func make() async throws -> Self {
        let api = try await GitHubPRFixture.make()
        do {
            let managed = api.git.root.appendingPathComponent("Worktrees"), base = api.git.root.appendingPathComponent("Base.git")
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: false)
            _ = try await api.git.run(["init", "--bare", base.path])
            _ = try await api.git.run(["push", base.path, "main:refs/heads/main", "feature/topic:refs/pull/42/head"])
            _ = try await api.git.run(["config", "protocol.file.allow", "always"])
            _ = try await api.git.run(["checkout", "main"])
            return Self(api: api, managed: managed, baseRemote: base, headRemote: api.git.root.appendingPathComponent("Published.git"))
        } catch { api.cleanup(); throw error }
    }
    func service(mode: GitHubPullRequestCheckoutMode = .worktree, id: UUID = UUID(), headRepository: GitHubRepository? = nil, gitExecutable: URL? = nil) throws -> GitHubPullRequestCheckoutService {
        let base = try GitHubRepository(owner: "upstream", name: "project"), head = try headRepository ?? GitHubRepository(owner: "fork", name: "project")
        let request = GitHubPullRequestCheckoutRequest(id: id, sourcePath: source.path, destinationRoot: managed.path,
            reference: try .init(repository: base, number: 42), mode: mode)
        return .init(request: request, environment: environment, gitExecutable: gitExecutable ?? api.git.git, githubExecutable: api.executable,
            transportOverrides: [base: baseRemote, head: headRemote])
    }
    func git(_ args: [String], at path: URL? = nil) async throws -> String {
        try await api.git.run(args, at: path).text.trimmingCharacters(in: .newlines)
    }
    func cleanup() { api.cleanup() }
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestCheckoutRejectsChangedDestinationWorktreeConfigurationBeforeMutation() async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    let service = try f.service(), first = try await service.prepare()
    _ = try await f.git(["config", "extensions.worktreeConfig", "true"])
    let destination = f.api.git.root.appendingPathComponent("Reviewed destination config")
    _ = try await f.git(["worktree", "add", "-b", first.requestedBranch, destination.path, f.api.base])
    _ = try await f.git(["config", "--worktree", "branch." + first.requestedBranch + ".remote", "origin"], at: destination)
    _ = try await f.git(["config", "--worktree", "branch." + first.requestedBranch + ".merge", "refs/heads/feature/topic"], at: destination)
    let plan = try await service.prepare()
    #expect(plan.disposition == .reuseWorktree && plan.proof.destinationFingerprint != nil && plan.proof.destinationConfigurationDigest != nil)
    let originalSource = try await service.metadata.localContext()
    let sourceConfiguration = try await service.configurationDigest(originalSource)
    _ = try await f.git(["config", "--worktree", "branch." + first.requestedBranch + ".merge", "refs/heads/main"], at: destination)
    let currentSource = try await service.metadata.localContext()
    #expect(try await service.configurationDigest(currentSource) == sourceConfiguration)
    let before = try await f.api.git.state(at: destination)
    do { _ = try await service.run(plan); Issue.record("A destination-only tracking change must invalidate its review.") }
    catch let error as GitHubPullRequestCheckoutError { #expect(error.kind == .staleReview && !error.mayHaveChanged) }
    #expect(try await f.api.git.state(at: destination) == before)
    #expect(try await f.git(["config", "--worktree", "--get", "branch." + first.requestedBranch + ".merge"], at: destination) == "refs/heads/main")
    #expect(!FileManager.default.fileExists(atPath: f.source.appendingPathComponent(".git/" + GitHubPullRequestCheckoutService.metadataName(plan.id)).path))
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestCheckoutExpectedOldCASPreservesAnExternalBranchAdvance() async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    let first = try await f.service().prepare(), reference = "refs/heads/" + first.requestedBranch
    _ = try await f.git(["branch", first.requestedBranch, f.api.base])
    let tree = try await f.git(["rev-parse", f.api.base + "^{tree}"])
    let external = try await f.git(["commit-tree", tree, "-p", f.api.base, "-m", "External branch advance retained"])
    let wrapper = f.api.git.root.appendingPathComponent("cas-intercepting-git"), reached = f.api.git.root.appendingPathComponent("cas-external-advance")
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let script = """
    #!/bin/sh
    previous=
    for value do
      if [ "$previous" = '--no-deref' ] && [ "$value" = \(quote(reference)) ]; then
        \(quote(f.api.git.git.path)) \(quote("--git-dir=" + f.source.appendingPathComponent(".git").path)) update-ref \(quote(reference)) \(quote(external)) \(quote(f.api.base)) || exit 71
        printf changed > \(quote(reached.path))
        break
      fi
      previous=$value
    done
    exec \(quote(f.api.git.git.path)) "$@"
    """
    try Data((script + "\n").utf8).write(to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let service = try f.service(gitExecutable: wrapper), plan = try await service.prepare()
    #expect(plan.existingBranchCommit == f.api.base && plan.disposition == .createWorktree)
    do { _ = try await service.run(plan); Issue.record("The stale expected-old update must fail without replacing the external commit.") }
    catch let error as GitHubPullRequestCheckoutError { #expect(error.kind == .staleReview && error.mayHaveChanged) }
    #expect(FileManager.default.fileExists(atPath: reached.path))
    #expect(try await f.git(["rev-parse", reference]) == external)
    #expect(try await f.git(["rev-parse", GitHubPullRequestCheckoutService.previousRef(plan.id)]) == f.api.base)
    #expect(!FileManager.default.fileExists(atPath: plan.destinationPath))
    #expect(try await service.inspectCompletion(plan) == .unconfirmed)
}

private func waitPRCheckout(_ predicate: () throws -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(8)
    while try !predicate() {
        guard ContinuousClock.now < end else { throw CoincideError("The owned pull request checkout fixture did not reach its gate.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [GitHubPullRequestCheckoutMode.local, .worktree])
func githubPullRequestCheckoutReadOnlyStatusPreservesIndexStatCacheAfterSameBytesMtimeChange(mode: GitHubPullRequestCheckoutMode) async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    let standard = try f.service(mode: mode)
    var environment = f.environment
    // Exercise the production argv protection rather than the fixture's usual
    // GIT_OPTIONAL_LOCKS=0 environment default.
    environment["GIT_OPTIONAL_LOCKS"] = "1"
    let service = GitHubPullRequestCheckoutService(request: standard.request, environment: environment,
        gitExecutable: f.api.git.git, githubExecutable: f.api.executable, transportOverrides: standard.transportOverrides)
    let sourceIndex = f.source.appendingPathComponent(".git/index")
    let originalIndex = try Data(contentsOf: sourceIndex)
    func retouch(_ file: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let previous = try #require(attributes[.modificationDate] as? Date)
        try FileManager.default.setAttributes([.modificationDate: previous.addingTimeInterval(5)], ofItemAtPath: file.path)
    }
    try retouch(f.source.appendingPathComponent("tracked.txt"))
    let plan = try await service.prepare()
    #expect(try Data(contentsOf: sourceIndex) == originalIndex)
    let result = try await service.run(plan)
    if mode == .worktree { #expect(try Data(contentsOf: sourceIndex) == originalIndex) }
    let destination = URL(fileURLWithPath: result.destinationPath)
    let destinationAdmin = try await f.api.git.admin(at: destination)
    let destinationIndex = destinationAdmin.appendingPathComponent("index")
    let beforeSourceInspection = try Data(contentsOf: sourceIndex), beforeDestinationInspection = try Data(contentsOf: destinationIndex)
    try retouch(f.source.appendingPathComponent("tracked.txt"))
    try retouch(destination.appendingPathComponent("tracked.txt"))
    #expect(try await service.inspectCompletion(plan) == .completed(result))
    #expect(try Data(contentsOf: sourceIndex) == beforeSourceInspection)
    #expect(try Data(contentsOf: destinationIndex) == beforeDestinationInspection)
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestCheckoutDeletedForkCannotProveAnUnrecognizedUpstreamOwnsADivergedBranch() async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    let service = try f.service(), first = try await service.prepare()
    let tree = try await f.git(["rev-parse", f.api.base + "^{tree}"])
    let old = try await f.git(["commit-tree", tree, "-p", f.api.base, "-m", "Diverged unproven local branch"])
    _ = try await f.git(["branch", first.requestedBranch, old])
    _ = try await f.git(["remote", "add", "unrecognized", f.headRemote.path])
    _ = try await f.git(["config", "branch." + first.requestedBranch + ".remote", "unrecognized"])
    _ = try await f.git(["config", "branch." + first.requestedBranch + ".merge", "refs/heads/feature/topic"])
    _ = try await f.git(["update-ref", "refs/remotes/unrecognized/feature/topic", old])
    try f.api.change { $0["deletedFork"] = true }
    let plan = try await service.prepare(), before = try await f.api.git.state()
    #expect(plan.pullRequest.headRepository == nil && plan.proof.previousUpstreamCommit == old)
    do { _ = try await service.run(plan); Issue.record("Absent repository identities must not prove ownership of a diverged branch.") }
    catch let error as GitHubPullRequestCheckoutError { #expect(error.kind == .branchCollision && error.mayHaveChanged) }
    #expect(try await f.git(["rev-parse", "refs/heads/" + first.requestedBranch]) == old)
    #expect(try await f.api.git.state() == before)
    #expect(try await f.api.git.run(["show-ref", "--verify", "--quiet", GitHubPullRequestCheckoutService.previousRef(plan.id)], succeeds: false).status != 0)
    #expect(!FileManager.default.fileExists(atPath: plan.destinationPath))
    #expect(try await service.inspectCompletion(plan) == .unconfirmed)
}

@Test(.timeLimit(.minutes(1)), arguments: [GitHubPullRequestCheckoutMode.local, .worktree])
func githubPullRequestCheckoutRealGitPinsHeadTrackingAndSealsCompletionWithoutReplay(mode: GitHubPullRequestCheckoutMode) async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    try f.api.git.write("keep-untracked.txt", "Preserve untracked source bytes\n")
    let before = try await f.api.git.state(), service = try f.service(mode: mode), plan = try await service.prepare()
    #expect(try await f.api.git.state() == before)
    #expect(plan.pullRequest.reference.number == 42 && plan.requestedHeadCommit == f.api.head)
    #expect(try await service.inspectCompletion(plan) == .unconfirmed)
    let result = try await service.run(plan)
    try result.validate(plan: plan)
    #expect(result.headCommit == f.api.head && result.isOnPullRequestHead && result.branch == plan.requestedBranch)
    #expect(result.warnings.isEmpty && result.created == (mode == .worktree))
    #expect(try String(contentsOf: URL(fileURLWithPath: result.destinationPath).appendingPathComponent("feature.txt"), encoding: .utf8) == "A committed feature\n")
    #expect(try await f.git(["rev-parse", "--abbrev-ref", "@{upstream}"], at: URL(fileURLWithPath: result.destinationPath)) == "origin/feature/topic")
    #expect(try await service.inspectCompletion(plan) == .completed(result))
    let calls = try f.api.calls().count
    #expect(try await service.run(plan) == result)
    #expect(try f.api.calls().count == calls)
    #expect(try String(contentsOf: f.source.appendingPathComponent("keep-untracked.txt"), encoding: .utf8) == "Preserve untracked source bytes\n")
    if mode == .worktree {
        #expect(result.worktreePlan?.id == plan.id && result.worktreeResult?.headCommit == f.api.head)
        let after = try await f.api.git.state()
        #expect(after.indexFiles == before.indexFiles && after.head == before.head && after.files == before.files)
        #expect(try await f.git(["rev-parse", "main"]) == f.api.base)
    } else { #expect(result.worktreePlan == nil && result.worktreeResult == nil) }
}

@Test(.timeLimit(.minutes(1)), arguments: ["staged", "working", "ignoredCollision", "untrackedCollision"])
func githubPullRequestLocalCheckoutPreservesDirtyAndCollidingUserBytes(kind: String) async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    if kind == "staged" || kind == "working" {
        try f.api.git.write("tracked.txt", "Local tracked edit kept\n")
        if kind == "staged" { _ = try await f.git(["add", "tracked.txt"]) }
    } else {
        if kind == "ignoredCollision" {
            try f.api.git.write(".gitignore", "feature.txt\n"); try await f.api.git.commitAll()
        }
        try f.api.git.write("feature.txt", "User addition must survive\n")
    }
    let before = try await f.api.git.state(), service = try f.service(mode: .local)
    do { _ = try await service.run(service.prepare()); Issue.record("The colliding or dirty checkout must not be overwritten.") }
    catch let error as GitHubPullRequestCheckoutError { #expect(error.kind == .dirtyCheckout) }
    #expect(try await f.api.git.state() == before)
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestForkDefaultBranchUsesOwnerPrefixAndPreservesLocalMain() async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    _ = try await f.git(["push", f.headRemote.path, "feature/topic:refs/heads/main"])
    try f.api.change { $0["branch"] = "main" }
    let service = try f.service(mode: .local), plan = try await service.prepare()
    #expect(plan.requestedBranch == "fork/main")
    let result = try await service.run(plan)
    #expect(result.branch == "fork/main" && result.headCommit == f.api.head)
    #expect(try await f.git(["rev-parse", "refs/heads/main"]) == f.api.base)
    #expect(try await f.git(["rev-parse", "--abbrev-ref", "@{upstream}"]) == "origin/main")
}

@Test(.timeLimit(.minutes(1)), arguments: ["missingHead", "deletedFork"])
func githubPullRequestCheckoutFallsBackToExactBasePullRefWithoutInventingTracking(kind: String) async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    _ = try await f.git(["push", f.headRemote.path, ":refs/heads/feature/topic"])
    if kind == "deletedFork" { try f.api.change { $0["deletedFork"] = true } }
    let service = try f.service(), plan = try await service.prepare(), result = try await service.run(plan)
    #expect(result.headCommit == f.api.head && result.isOnPullRequestHead)
    #expect(result.warnings.contains(GitHubPullRequestCheckoutResult.trackingWarning))
    #expect(try await f.git(["rev-parse", GitHubPullRequestCheckoutService.headRef(plan.id)]) == f.api.head)
    #expect(try await f.git(["rev-parse", "main"]) == f.api.base)
}

@Test(.timeLimit(.minutes(1)), arguments: ["behind", "rewritten", "ownCommit", "dirty", "foreignUpstream", "wrongUpstreamBranch"])
func githubPullRequestReusedWorktreeRefreshesOnlyLosslesslyAndReportsActualHead(kind: String) async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    let service = try f.service(), initialPlan = try await service.prepare()
    var old = f.api.base
    if kind != "behind" {
        _ = try await f.git(["checkout", "-b", "old-pr-head", "main"])
        try f.api.git.write("old.txt", "Previous remote PR head\n"); try await f.api.git.commitAll()
        old = try await f.git(["rev-parse", "HEAD"]); _ = try await f.git(["checkout", "main"])
    }
    let checkout = f.api.git.root.appendingPathComponent("Existing registered PR checkout")
    _ = try await f.git(["worktree", "add", "-b", initialPlan.requestedBranch, checkout.path, old])
    _ = try await f.git(["config", "branch." + initialPlan.requestedBranch + ".remote", "origin"])
    _ = try await f.git(["config", "branch." + initialPlan.requestedBranch + ".merge", "refs/heads/feature/topic"])
    _ = try await f.git(["update-ref", "refs/remotes/origin/feature/topic", old])
    if kind == "foreignUpstream" {
        _ = try await f.git(["config", "branch." + initialPlan.requestedBranch + ".remote", "upstream"])
        _ = try await f.git(["update-ref", "refs/remotes/upstream/feature/topic", old])
    } else if kind == "wrongUpstreamBranch" {
        _ = try await f.git(["config", "branch." + initialPlan.requestedBranch + ".merge", "refs/heads/main"])
        _ = try await f.git(["update-ref", "refs/remotes/origin/main", old])
    }
    if kind == "ownCommit" {
        try Data("Own unpublished commit kept\n".utf8).write(to: checkout.appendingPathComponent("own.txt"))
        _ = try await f.git(["add", "own.txt"], at: checkout); _ = try await f.git(["commit", "-m", "Own fixture commit"], at: checkout)
    } else if kind == "dirty" { try Data("Uncommitted bytes kept\n".utf8).write(to: checkout.appendingPathComponent("dirty.txt")) }
    // Exercise exact registered lookup beyond many similarly named branches.
    for i in 0..<(kind == "behind" ? 105 : 0) { _ = try await f.git(["branch", "a-padding-" + String(i) + "/" + initialPlan.requestedBranch]) }
    let before = try await f.api.git.state(at: checkout), plan = try await service.prepare(), result = try await service.run(plan)
    #expect(plan.disposition == .reuseWorktree && result.reused && !result.created && result.destinationPath == checkout.path)
    if kind == "ownCommit" || kind == "dirty" || kind == "foreignUpstream" || kind == "wrongUpstreamBranch" {
        #expect(!result.isOnPullRequestHead && !result.moved)
        #expect(result.headCommit == plan.proof.destinationHeadCommit)
        #expect(result.warnings.contains(GitHubPullRequestCheckoutResult.offHeadWarning))
        #expect(try await f.api.git.state(at: checkout) == before)
        if kind == "foreignUpstream" || kind == "wrongUpstreamBranch" {
            #expect(plan.proof.previousUpstreamCommit == old)
            #expect(try await f.api.git.run(["show-ref", "--verify", "--quiet", GitHubPullRequestCheckoutService.previousRef(plan.id)], succeeds: false).status != 0)
        }
    } else {
        #expect(result.isOnPullRequestHead && result.moved && result.headCommit == f.api.head)
        if kind == "rewritten" { #expect(try await f.git(["rev-parse", GitHubPullRequestCheckoutService.previousRef(plan.id)]) == old) }
    }
    #expect(result.worktreePlan?.baseCommit == result.headCommit && result.worktreeResult?.headCommit == result.headCommit)
    #expect(try await f.git(["rev-parse", "refs/heads/main"]) == f.api.base)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func githubPullRequestUnrelatedForkHeadAliasKeepsItsBytesRefsAndTrackingUntouched(sameCommit: Bool) async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    _ = try await f.git(["checkout", "-b", "host-work"])
    if sameCommit { _ = try await f.git(["branch", "--force", "main", f.api.head]) }
    let other = f.api.git.root.appendingPathComponent("Existing main checkout")
    _ = try await f.git(["worktree", "add", other.path, "main"])
    _ = try await f.git(["config", "branch.main.remote", "upstream"])
    _ = try await f.git(["config", "branch.main.merge", "refs/heads/main"])
    try Data("Unrelated dirty work preserved\n".utf8).write(to: other.appendingPathComponent("user.txt"))
    try f.api.change { $0["branch"] = "main" }
    let before = try await f.api.git.state(at: other), configuration = try Data(contentsOf: f.source.appendingPathComponent(".git/config"))
    let service = try f.service(), plan = try await service.prepare(), result = try await service.run(plan)
    #expect(plan.disposition == .reuseUnrelatedWorktree && plan.requestedBranch != "main")
    #expect(result.branch == "main" && result.headCommit == (sameCommit ? f.api.head : f.api.base) && !result.isOnPullRequestHead && !result.moved)
    #expect(result.reused && !result.created)
    #expect(try await f.api.git.state(at: other) == before)
    #expect(try Data(contentsOf: f.source.appendingPathComponent(".git/config")) == configuration)
    #expect(try await f.api.git.run(["show-ref", "--verify", "--quiet", GitHubPullRequestCheckoutService.headRef(plan.id)], succeeds: false).status != 0)
}

@Test(.timeLimit(.minutes(1)), arguments: ["head", "remote", "replacement", "destination", "prHead"])
func githubPullRequestCheckoutStaleProofCannotStartGitMutation(kind: String) async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    let service = try f.service(), plan = try await service.prepare()
    switch kind {
    case "head": try f.api.git.write("new.txt", "Changed local commit\n"); try await f.api.git.commitAll()
    case "remote": _ = try await f.git(["remote", "set-url", "origin", "https://github.com/other/project.git"])
    case "replacement":
        let old = f.api.git.root.appendingPathComponent("Original retained repository")
        try FileManager.default.moveItem(at: f.source, to: old); try FileManager.default.copyItem(at: old, to: f.source)
    case "destination": try FileManager.default.createDirectory(atPath: plan.destinationPath, withIntermediateDirectories: false)
    default: try f.api.change { $0["headCommit"] = String(repeating: "f", count: 40) }
    }
    let before = try await f.api.git.state()
    do { _ = try await service.run(plan); Issue.record("A stale pull request plan must fail before mutation.") }
    catch let error as GitHubPullRequestCheckoutError { #expect(!error.mayHaveChanged) }
    #expect(try await f.api.git.state() == before)
    #expect(!FileManager.default.fileExists(atPath: f.source.appendingPathComponent(".git/" + GitHubPullRequestCheckoutService.metadataName(plan.id)).path))
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestCheckoutOwnedGitMustExitBeforeCompletionAndCancellationPreservesAttempts() async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    let service = try f.service(), plan = try await service.prepare()
    let entered = f.api.git.root.appendingPathComponent("post-checkout-entered")
    let hook = f.api.git.root.appendingPathComponent("No hooks/post-checkout")
    let quoted = "'" + entered.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    try Data(("#!/bin/sh\nprintf entered > " + quoted + "\nwhile :; do /bin/sleep 0.05; done\n").utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let operation = Task { try await service.run(plan) }
    do {
        try await waitPRCheckout { FileManager.default.fileExists(atPath: entered.path) }
        #expect(try await service.inspectCompletion(plan) == .unconfirmed)
        operation.cancel()
        do { _ = try await operation.value; Issue.record("The cancelled owned Git must not complete.") }
        catch let error as GitHubPullRequestCheckoutError { #expect(error.mayHaveChanged) }
        #expect(try await service.inspectCompletion(plan) == .unconfirmed)
        #expect(FileManager.default.fileExists(atPath: plan.destinationPath))
        #expect(FileManager.default.fileExists(atPath: f.source.appendingPathComponent(".git/" + GitHubPullRequestCheckoutService.metadataName(plan.id) + "/worktree-plan.json").path))
        do { _ = try await service.run(plan); Issue.record("An interrupted operation must never replay automatically.") }
        catch let error as GitHubPullRequestCheckoutError { #expect(error.mayHaveChanged) }
        #expect(try await f.git(["rev-parse", "main"]) == f.api.base)
    } catch { operation.cancel(); _ = try? await operation.value; throw error }
}
