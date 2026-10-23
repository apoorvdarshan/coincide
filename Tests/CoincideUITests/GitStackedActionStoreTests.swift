import AppKit
import CoincideCore
import Foundation
import SwiftUI
import Testing
@testable import Coincide

@discardableResult private func stackedGit(_ root: URL, _ args: [String], succeeds: Bool = true) async throws -> String {
    let result = try await CommandRunner.run("git", ["-C", root.path] + args)
    if succeeds, result.status != 0 { throw CoincideError("Fixture Git failed: " + String(decoding: result.error, as: UTF8.self)) }
    return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A GitHub stand-in whose published head is the local bare remote's tracking ref. It never networks.
actor StackedPullRequestPeer: GitHubPullRequestSession {
    let root: URL
    let repository: GitHubRepository
    private(set) var creates: [GitHubPullRequestCreateReview] = []
    private var existing: GitHubPullRequestDetail?
    private var reportedHead: String?
    init(root: URL) throws { self.root = root; repository = try .init(owner: "fixture", name: "stacked") }
    func reportHead(_ value: String?) { reportedHead = value }
    func markExisting() throws {
        let reference = try GitHubPullRequestReference(repository: repository, number: 7)
        let summary = try GitHubPullRequestSummary(reference: reference, title: "Existing", url: "https://github.com/fixture/stacked/pull/7", state: .open,
            headBranch: "feature/stacked", baseBranch: "main", headCommit: String(repeating: "a", count: 40), baseCommit: String(repeating: "d", count: 40), headRepository: repository)
        existing = try .init(summary: summary, body: "", createdAt: Date())
    }
    func context() async throws -> GitHubPullRequestContext {
        let head = try await stackedGit(root, ["rev-parse", "HEAD"]), branch = try await stackedGit(root, ["symbolic-ref", "--short", "HEAD"])
        let tracked = try await stackedGit(root, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/" + branch], succeeds: false)
        let published = tracked.isEmpty ? nil : (reportedHead ?? tracked)
        let readiness: GitHubPullRequestReadiness = published == nil ? .unpublished : published != head ? .unpushedCommits : branch == "main" ? .defaultBranch : .ready
        return try .init(workspacePath: root.path, repository: repository, headRepository: repository, branch: branch, headCommit: head,
            upstream: try published.map { try .init(remoteName: "origin", branch: branch, commit: $0) }, defaultBranch: "main", baseBranches: ["main"],
            existingPullRequest: existing?.summary, readiness: readiness, sourceFingerprint: head + String(repeating: "0", count: 24))
    }
    func list(query: GitHubPullRequestListQuery) throws -> GitHubPullRequestPage { .init(items: existing.map { [$0.summary] } ?? [], truncated: false) }
    func detail(_ reference: GitHubPullRequestReference) throws -> GitHubPullRequestDetail {
        guard let existing, existing.summary.reference == reference else { throw GitHubPullRequestError(.invalidResponse) }; return existing
    }
    func resolve(_ reference: String) throws -> GitHubPullRequestDetail { guard let existing else { throw GitHubPullRequestError(.invalidResponse) }; return existing }
    func reviewCreate(title: String, body: String, baseBranch: String?, isDraft: Bool) async throws -> GitHubPullRequestCreateReview {
        try .init(context: try await context(), title: title, body: body, baseBranch: baseBranch ?? "main", baseCommit: String(repeating: "d", count: 40), isDraft: isDraft)
    }
    func create(_ review: GitHubPullRequestCreateReview) throws -> GitHubPullRequestCreateOutcome {
        creates.append(review)
        let reference = try GitHubPullRequestReference(repository: repository, number: 42)
        let summary = try GitHubPullRequestSummary(reference: reference, title: review.title, url: "https://github.com/fixture/stacked/pull/42", state: .open,
            isDraft: review.isDraft, headBranch: review.context.upstream!.branch, baseBranch: review.baseBranch, headCommit: review.context.headCommit!,
            baseCommit: review.baseCommit, headRepository: repository, author: "fixture")
        let detail = try GitHubPullRequestDetail(summary: summary, body: review.body, createdAt: Date())
        existing = detail
        return .created(detail)
    }
    func reconcileCreate(_ review: GitHubPullRequestCreateReview) throws -> GitHubPullRequestCreateReconciliation { existing.map { .found($0) } ?? .notFound }
}

@MainActor struct StackedActionFixture {
    let root: URL, repository: URL, remote: URL, hooks: URL
    let peer: StackedPullRequestPeer
    let workspace: WorkspaceStore
    let inspector: GitInspectorStore
    let model: GitStackedActionStore
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-stacked-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        let repository = root.appendingPathComponent("repository"), remote = root.appendingPathComponent("remote.git"), hooks = root.appendingPathComponent("hooks")
        for directory in [repository, hooks] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try await stackedGit(root, ["init", "-q", "--bare", "--initial-branch=main", remote.path])
        try await stackedGit(repository, ["init", "-q", "--initial-branch=main"])
        for (key, value) in [("user.name", "Coincide Test"), ("user.email", "test@example.invalid"), ("commit.gpgSign", "false"), ("core.hooksPath", hooks.path)] {
            try await stackedGit(repository, ["config", "--local", key, value])
        }
        try "initial\n".write(to: repository.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try await stackedGit(repository, ["add", "readme.txt"]); try await stackedGit(repository, ["commit", "-q", "-m", "Initial"])
        try await stackedGit(repository, ["remote", "add", "origin", remote.path])
        try await stackedGit(repository, ["push", "-q", "--set-upstream", "origin", "main"])
        try await stackedGit(repository, ["remote", "set-head", "origin", "main"])
        let peer = try StackedPullRequestPeer(root: repository)
        let database = root.appendingPathComponent("workspace.sqlite")
        let project = WorkspaceProject(path: repository.path)
        var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        try await WorkspaceDatabase(url: database).save(snapshot, event: "stacked.fixture")
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in throw CoincideError("No provider input in this fixture.") },
                                         identityResolver: { _ in nil }, pullRequestFactory: { _ in peer })
        let workspace = WorkspaceStore(engine: engine); workspace.pullRequestSessionFactory = { _ in peer }
        await workspace.load()
        let inspector = workspace.gitInspector(path: repository.path)
        let model = GitStackedActionStore(inspector: inspector, pullRequests: workspace.pullRequestStore(path: repository.path))
        await inspector.refresh()
        return .init(root: root, repository: repository, remote: remote, hooks: hooks, peer: peer, workspace: workspace, inspector: inspector, model: model)
    }
    func write(_ name: String, _ text: String) throws { try text.write(to: repository.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    func hook(_ script: String) throws {
        let url = hooks.appendingPathComponent("pre-commit")
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func run(_ plan: GitStackedActionStore.Plan) async {
        await inspector.refresh()
        #expect(model.run(plan))
        await model.waitForCompletion()
    }
    func finish() async { await workspace.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@MainActor @Test(.timeLimit(.minutes(1))) func stackedCommitPushAndCreateRunsInOrderAndCreatesOnlyForThePushedHead() async throws {
    let f = try await StackedActionFixture.make()
    do {
        try await stackedGit(f.repository, ["switch", "-q", "-c", "feature/stacked"])
        try f.write("chosen.txt", "chosen\n"); try f.write("later.txt", "not in this commit\n")
        try f.hook("echo 'running lint' >&2\n")
        await f.inspector.refresh()
        let status = try #require(f.inspector.quickActionStatus(hasOpenPullRequest: false))
        #expect(GitActionResolver.quickAction(status, isBusy: false, hasPrimaryRemote: true).kind == .run(.commitPushPullRequest))
        var plan = GitStackedActionStore.Plan(action: .commitPushPullRequest)
        plan.paths = ["chosen.txt"]; plan.commitMessage = "Add chosen file"; plan.remote = "origin"; plan.remoteBranch = "feature/stacked"
        plan.pullRequestTitle = "Add chosen file"; plan.pullRequestBody = "Exact body\n"; plan.pullRequestBase = "main"; plan.pullRequestDraft = true
        await f.run(plan)
        #expect(f.model.outcome == .finished("Created pull request #42"))
        #expect(plan.phases.allSatisfy { f.model.states[$0] == .done } && plan.phases == [.stage, .commit, .push, .pullRequest])
        let head = try await stackedGit(f.repository, ["rev-parse", "HEAD"])
        #expect(try await stackedGit(f.remote, ["rev-parse", "refs/heads/feature/stacked"]) == head)
        #expect(try await stackedGit(f.repository, ["show", "--name-only", "--format=", "HEAD"]) == "chosen.txt")
        #expect(try await stackedGit(f.repository, ["rev-parse", "--abbrev-ref", "feature/stacked@{upstream}"]) == "origin/feature/stacked")
        let creates = await f.peer.creates
        #expect(creates.count == 1 && creates[0].context.headCommit == head && creates[0].title == "Add chosen file" && creates[0].body == "Exact body\n" && creates[0].isDraft)
        #expect(f.model.pullRequest?.reference.number == 42 && !f.model.isRunning && f.inspector.operationName == nil)
        #expect(f.inspector.snapshot?.changes.contains { $0.path == "later.txt" } == true)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func cleanDefaultBranchAheadPushesExistingCommitWithoutAnEmptyCommitOrPullRequest(unsetUpstream: Bool) async throws {
    let f = try await StackedActionFixture.make()
    do {
        try f.write("local-only.txt", "The existing local commit is the only thing to publish.\n")
        try await stackedGit(f.repository, ["add", "local-only.txt"])
        try await stackedGit(f.repository, ["commit", "-q", "-m", "Existing local change"])
        if unsetUpstream { try await stackedGit(f.repository, ["branch", "--unset-upstream"]) }
        let head = try await stackedGit(f.repository, ["rev-parse", "HEAD"])
        let count = try await stackedGit(f.repository, ["rev-list", "--count", "HEAD"])
        try f.hook("printf 'unexpected-commit\\n' >> forbidden-commit-receipt\nexit 1\n")
        await f.inspector.refresh()
        let status = try #require(f.inspector.quickActionStatus(hasOpenPullRequest: false))
        let quick = GitActionResolver.quickAction(status, isBusy: false, isDefaultBranch: true, hasPrimaryRemote: true)
        #expect(quick.kind == .run(.push) && !quick.disabled)
        let action = try #require(quick.action)
        #expect(!action.includesCommit && GitActionResolver.requiresDefaultBranchConfirmation(action, isDefaultBranch: true))
        let copy = GitActionResolver.defaultBranchDialogCopy(action, branch: "main", includesCommit: action.includesCommit)
        #expect(copy.title == "Push to the default branch?" && copy.continueLabel == "Push to main")
        var plan = GitStackedActionStore.Plan(action: action)
        plan.remote = "origin"; plan.remoteBranch = "main"
        #expect(plan.phases == [.push] && plan.commitMessage.isEmpty && plan.paths.isEmpty)
        await f.run(plan)
        #expect(f.model.outcome?.isFinished == true && f.model.states[.push] == .done)
        #expect(try await stackedGit(f.remote, ["rev-parse", "refs/heads/main"]) == head)
        #expect(try await stackedGit(f.repository, ["rev-parse", "HEAD"]) == head)
        #expect(try await stackedGit(f.repository, ["rev-list", "--count", "HEAD"]) == count)
        #expect(try await GitService(root: f.repository).status().isClean)
        #expect(!FileManager.default.fileExists(atPath: f.repository.appendingPathComponent("forbidden-commit-receipt").path))
        #expect(await f.peer.creates.isEmpty)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1))) func stackedActionMovesDefaultBranchWorkToAFeatureBranchAndStopsOnFailures() async throws {
    let f = try await StackedActionFixture.make()
    do {
        let mainBefore = try await stackedGit(f.remote, ["rev-parse", "refs/heads/main"])
        try f.write("readme.txt", "initial\nfeature work\n")
        var plan = GitStackedActionStore.Plan(action: .commitPush, featureBranch: "feature/from-main")
        plan.paths = ["readme.txt"]; plan.commitMessage = "Feature from main"; plan.remote = "origin"; plan.remoteBranch = "feature/from-main"
        await f.run(plan)
        #expect(f.model.outcome?.isFinished == true && plan.phases == [.featureBranch, .stage, .commit, .push])
        #expect(try await stackedGit(f.remote, ["rev-parse", "refs/heads/main"]) == mainBefore)
        #expect(try await stackedGit(f.remote, ["rev-parse", "refs/heads/feature/from-main"]) == (try await stackedGit(f.repository, ["rev-parse", "HEAD"])))
        #expect(f.inspector.snapshot?.branch == "feature/from-main")

        // A failing hook stops before pushing; nothing is published or created.
        try f.write("blocked.txt", "blocked\n"); try f.hook("echo 'hook says no' >&2\nexit 1\n")
        var blocked = GitStackedActionStore.Plan(action: .commitPushPullRequest)
        blocked.paths = ["blocked.txt"]; blocked.commitMessage = "Blocked"; blocked.pullRequestTitle = "Blocked"
        await f.run(blocked)
        guard case .failed(let message)? = f.model.outcome else { Issue.record("A hook failure must fail the action."); throw CoincideError("unexpected") }
        #expect(message.contains("hook says no") && f.model.states[.commit] == .failed && f.model.states[.push] == .pending)
        #expect(await f.peer.creates.isEmpty)

        // A push rejection stops before PR creation.
        try f.hook("exit 0\n")
        try await stackedGit(f.repository, ["remote", "set-url", "origin", f.root.appendingPathComponent("missing.git").path])
        var rejected = GitStackedActionStore.Plan(action: .commitPushPullRequest)
        rejected.paths = ["blocked.txt"]; rejected.commitMessage = "Now committed"; rejected.pullRequestTitle = "Rejected"
        await f.run(rejected)
        #expect(f.model.states[.commit] == .done && f.model.states[.push] == .failed && f.model.states[.pullRequest] == .pending)
        #expect(await f.peer.creates.isEmpty)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1))) func stackedActionRefusesAMovedHeadReusesAnExistingPullRequestAndCancelsBetweenPhases() async throws {
    let f = try await StackedActionFixture.make()
    do {
        try await stackedGit(f.repository, ["switch", "-q", "-c", "feature/stacked"])
        try f.write("one.txt", "one\n")
        await f.peer.reportHead(String(repeating: "e", count: 40))
        var plan = GitStackedActionStore.Plan(action: .commitPushPullRequest)
        plan.paths = ["one.txt"]; plan.commitMessage = "One"; plan.remote = "origin"; plan.remoteBranch = "feature/stacked"; plan.pullRequestTitle = "One"
        await f.run(plan)
        guard case .needsPullRequestReview? = f.model.outcome else { Issue.record("A different published head must require review."); throw CoincideError("unexpected") }
        #expect(await f.peer.creates.isEmpty && f.model.states[.push] == .done)

        await f.peer.reportHead(nil); try await f.peer.markExisting()
        var existing = GitStackedActionStore.Plan(action: .createPullRequest); existing.pullRequestTitle = "Again"
        await f.run(existing)
        let noCreates = await f.peer.creates.isEmpty
        #expect(f.model.outcome == .finished("Opened existing pull request #7") && noCreates)

        try f.write("slow.txt", "slow\n")
        let marker = f.root.appendingPathComponent("hook-started")
        try f.hook("printf started > '\(marker.path)'\nexec /usr/bin/perl -e 'sleep 20'\n")
        let remoteBefore = try await stackedGit(f.remote, ["rev-parse", "refs/heads/feature/stacked"])
        var slow = GitStackedActionStore.Plan(action: .commitPushPullRequest)
        slow.paths = ["slow.txt"]; slow.commitMessage = "Slow"; slow.pullRequestTitle = "Slow"
        await f.inspector.refresh()
        #expect(f.model.run(slow))
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(f.model.currentPhase == .commit && f.inspector.operationName != nil)
        f.model.cancel()
        await f.model.waitForCompletion()
        #expect(f.model.outcome == .cancelled && f.model.states[.push] == .pending)
        #expect(try await stackedGit(f.remote, ["rev-parse", "refs/heads/feature/stacked"]) == remoteBefore)
        #expect(await f.peer.creates.isEmpty)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test func stackedActionMessageGeneratorOnlyFillsTheField() async throws {
    struct Generator: GitCommitMessageGenerating {
        func commitMessage(for context: GitCommitMessageContext) async throws -> String { "feat: \(context.paths.joined(separator: ", "))" }
    }
    let f = try await StackedActionFixture.make()
    do {
        try f.write("generated.txt", "x\n"); await f.inspector.refresh()
        f.model.messageGenerator = Generator()
        #expect(await f.model.generateMessage(paths: ["generated.txt"]) == "feat: generated.txt")
        #expect(f.inspector.snapshot?.changes.contains { $0.path == "generated.txt" } == true && f.model.outcome == nil)
        #expect(try await stackedGit(f.repository, ["rev-list", "--count", "HEAD"]) == "1")
    } catch { await f.finish(); throw error }
    await f.finish()
}

extension GitStackedActionStore.Outcome {
    var isFinished: Bool { if case .finished = self { true } else { false } }
}

@MainActor @Test(.timeLimit(.minutes(1))) func stackedActionSheetFitsFormAndProgressInBothAppearances() async throws {
    _ = NSApplication.shared
    let f = try await StackedActionFixture.make()
    do {
        try f.write("readme.txt", "initial\nchanged on main\n"); await f.inspector.refresh()
        func check(_ label: String) async throws {
            for scheme in [ColorScheme.light, .dark] {
                for width in [CGFloat(400), 620] {
                    let view = GitStackedActionSheet(model: f.model, action: .commitPushPullRequest, blocked: false, openPullRequests: { })
                        .environment(\.colorScheme, scheme).frame(width: width, height: 600)
                    let controller = NSHostingController(rootView: view)
                    let size = controller.sizeThatFits(in: CGSize(width: width, height: 600))
                    #expect(size.width <= width + 1 && size.height <= 601, "\(label) \(width)")
                    if ProcessInfo.processInfo.environment["COINCIDE_RENDER_STACKED"] == "1" {
                        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
                        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua); hosting.appearance = window.appearance
                        window.isReleasedWhenClosed = false; window.contentView = hosting; hosting.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
                        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                        let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-stacked-\(label)-\(scheme == .light ? "light" : "dark")-\(Int(width)).png")
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: path); print("Stacked preview: \(path.path)")
                        window.close()
                    }
                }
            }
        }
        try await check("form")
        var plan = GitStackedActionStore.Plan(action: .commit)
        plan.paths = ["readme.txt"]; plan.commitMessage = "Commit on main"
        await f.run(plan)
        #expect(f.model.outcome?.isFinished == true)
        try await check("progress")
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1))) func gitInspectorBranchScopeComparesAgainstTheRemoteDefaultAndKeepsCatalogData() async throws {
    let f = try await StackedActionFixture.make()
    do {
        try await stackedGit(f.repository, ["switch", "-q", "-c", "feature/review"])
        try f.write("feature.txt", "feature\n")
        try await stackedGit(f.repository, ["add", "feature.txt"]); try await stackedGit(f.repository, ["commit", "-q", "-m", "Feature"])
        try f.write("readme.txt", "initial\nuncommitted\n")
        await f.inspector.refresh()
        #expect(f.inspector.defaultBranch == GitDefaultBranch(name: "main", remoteRef: "refs/remotes/origin/main"))
        #expect(f.inspector.compareBase == "origin/main" && f.inspector.aheadOfDefault == 1)
        #expect(f.inspector.quickActionStatus(hasOpenPullRequest: false)?.aheadOfDefaultCount == 1)
        f.inspector.scope = .branch; await f.inspector.loadDiff()
        #expect(Set(f.inspector.parsedDiff.files.map(\.path)) == ["feature.txt", "readme.txt"] && f.inspector.diffDescription == nil)
        f.inspector.selected = "readme.txt"; await f.inspector.loadDiff()
        #expect(f.inspector.parsedDiff.files.count == 2)
        f.inspector.compareBase = "missing-base"; await f.inspector.loadDiff()
        #expect(f.inspector.parsedDiff.isEmpty && f.inspector.diffDescription != nil && f.inspector.operationError == nil)
        f.inspector.scope = .unstaged; f.inspector.selected = nil; f.inspector.ignoreWhitespace = true; await f.inspector.loadDiff()
        #expect(f.inspector.parsedDiff.files.map(\.path) == ["readme.txt"] && !f.inspector.staged)
        f.inspector.staged = true; #expect(f.inspector.scope == .staged)
        await f.inspector.loadCatalog()
        #expect(f.inspector.catalog?.current?.name == "feature/review" && f.inspector.catalog?.remotes.contains { $0.name == "origin/main" } == true)
    } catch { await f.finish(); throw error }
    await f.finish()
}
