import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct PullRequestActionEngineFixture: Sendable {
    let native: GitHubPRActionFixture
    let database: URL
    let project: WorkspaceProject
    let thread: CodingThread
    static func make(uncertain: Bool = false, held: Bool = false) async throws -> Self {
        let native = try await GitHubPRActionFixture.make(sameRepository: true) {
            $0["state"] = "MERGED"; $0["holdRevert"] = held
            if uncertain { $0["revertMode"] = "uncertain" }
        }
        do {
            let project = WorkspaceProject(path: native.git.repository.resolvingSymlinksInPath().path)
            var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
            thread.draft = "Retain the exact unsent PR draft e\u{301} 🌍"
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            let database = native.git.root.appendingPathComponent("action-workspace.sqlite")
            try await WorkspaceDatabase(url: database).save(snapshot, event: "pull-request-action.fixture")
            return .init(native: native, database: database, project: project, thread: thread)
        } catch { native.cleanup(); throw error }
    }
    func open() throws -> WorkspaceEngine {
        try WorkspaceEngine(url: database, providerFactory: { _ in
            throw CoincideError("The PR-action fixture must never create a provider session.")
        }, identityResolver: { _ in nil }, pullRequestActionFactory: { _ in native.service })
    }
    func review(_ engine: WorkspaceEngine) async throws -> GitHubPullRequestActionReview {
        try await engine.preparePullRequestAction(projectID: project.id, workspacePath: project.path, action: .revert,
            reference: native.reference, removeAgentCredits: false, sourceThreadID: thread.id)
    }
    var entered: URL { native.stateURL.deletingPathExtension().appendingPathExtension("revert-entered") }
    func release() { try? Data().write(to: native.stateURL.deletingPathExtension().appendingPathExtension("revert-release")) }
}

private func waitForActionEngine(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private PR-action fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func pullRequestActionEngineConcurrentDuplicatesUseOneOriginalReceiptAndExactImmutableResult() async throws {
    let f = try await PullRequestActionEngineFixture.make(); defer { f.release(); f.native.cleanup() }
    let engine = try f.open()
    do {
        _ = try await engine.load()
        await #expect(throws: WorkspaceCommandError.self) {
            _ = try await engine.acknowledgePullRequestAction(operationID: UUID())
        }
        let retainedDraft = f.thread.draft + " after the safe refusal"
        _ = try await engine.dispatch(.editThread(f.thread.id, .draft(retainedDraft)))
        #expect((await engine.current()).error == nil)
        let review = try await f.review(engine)
        async let one = engine.beginPullRequestAction(projectID: f.project.id, review: review)
        async let two = engine.beginPullRequestAction(projectID: f.project.id, review: review)
        let (first, duplicate) = try await (one, two)
        #expect(first == duplicate && first.commandID == review.id && first.rejection == nil)
        try await waitForActionEngine { (await engine.current()).snapshot.pullRequestAction(review.id)?.phase == .succeeded }
        let update = await engine.current(), operation = try #require(update.snapshot.pullRequestAction(review.id))
        #expect(try f.native.writes() == ["revert"])
        #expect(operation.outcome?.action == .revert && operation.outcome?.revertReference?.number == 43)
        #expect(operation.outcome?.revertURL == "https://github.com/upstream/project/pull/43")
        let thread = try #require(update.snapshot.threads.first { $0.id == f.thread.id })
        #expect(thread.draft.utf8.elementsEqual(retainedDraft.utf8) && thread.activeRun == nil && thread.queuedTurns.isEmpty && thread.messages.isEmpty)
        let changed = GitHubPullRequestActionReview(id: review.id, reviewedAt: review.reviewedAt, action: .deleteBranch, state: review.state)
        do {
            _ = try await engine.beginPullRequestAction(projectID: f.project.id, review: changed)
            Issue.record("A different action reused an already committed original review UUID.")
        } catch WorkspaceCommitError.commandIDCollision { }
        catch { Issue.record("Expected an original UUID payload collision, received \(type(of: error)).") }
        #expect(try f.native.writes() == ["revert"])
        try WorkspaceJournal.validate((await engine.current()).snapshot)
    } catch { await engine.shutdown(); throw error }
    await engine.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func pullRequestActionEngineUnknownOrInterruptedWriteSurvivesRestartAndNeverReplays(held: Bool) async throws {
    let f = try await PullRequestActionEngineFixture.make(uncertain: !held, held: held)
    defer { f.release(); f.native.cleanup() }
    var engine = try f.open()
    do {
        _ = try await engine.load()
        let review = try await f.review(engine)
        let original = try await engine.beginPullRequestAction(projectID: f.project.id, review: review)
        #expect(original.commandID == review.id && original.rejection == nil)
        var nativePID: pid_t?
        if held {
            try await waitForActionEngine { FileManager.default.fileExists(atPath: f.entered.path) }
            nativePID = try #require(Int32(String(contentsOf: f.entered, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect((await engine.current()).snapshot.pullRequestAction(review.id)?.phase == .dispatching)
            let head = try Data(contentsOf: URL(fileURLWithPath: f.project.path).appendingPathComponent(".git/HEAD"))
            let tracked = try Data(contentsOf: URL(fileURLWithPath: f.project.path).appendingPathComponent("tracked.txt"))
            await #expect(throws: WorkspaceCommandError.self) {
                _ = try await engine.dispatch(.removeProject(projectID: f.project.id, expectedThreadIDs: [f.thread.id]))
            }
            await #expect(throws: WorkspaceCommandError.self) {
                _ = try await engine.dispatch(.editThread(f.thread.id, .workspacePath(f.native.git.root.appendingPathComponent("replacement").path)))
            }
            let draft = "Editing remains available while the exact PR action is held e\u{301} 🌍"
            _ = try await engine.dispatch(.editThread(f.thread.id, .draft(draft)))
            let current = (await engine.current()).snapshot
            let unchanged = try #require(current.threads.first { $0.id == f.thread.id })
            #expect(current.projects.contains { $0.id == f.project.id } && unchanged.workspacePath.utf8.elementsEqual(f.project.path.utf8))
            #expect(unchanged.draft.utf8.elementsEqual(draft.utf8) && current.pullRequestAction(review.id)?.phase == .dispatching)
            #expect(try Data(contentsOf: URL(fileURLWithPath: f.project.path).appendingPathComponent(".git/HEAD")) == head)
            #expect(try Data(contentsOf: URL(fileURLWithPath: f.project.path).appendingPathComponent("tracked.txt")) == tracked)
        } else {
            try await waitForActionEngine { (await engine.current()).snapshot.pullRequestAction(review.id)?.phase == .unconfirmed }
        }
        #expect(try f.native.writes() == ["revert"])
        await engine.shutdown()
        if let nativePID { #expect(Darwin.kill(nativePID, 0) == -1 && errno == ESRCH, "Shutdown must join the exact private gh child.") }
        engine = try f.open(); _ = try await engine.load()
        let recovered = try #require((await engine.current()).snapshot.pullRequestAction(review.id))
        #expect(recovered.phase == .unconfirmed && recovered.requiresAcknowledgment && recovered.outcome == nil)
        // This simulates recovering a discarded original admission reply. The
        // saved review UUID wins before any retired in-memory review lookup.
        let receipt = try await engine.beginPullRequestAction(projectID: f.project.id, review: review)
        #expect(receipt == original)
        #expect(try f.native.writes() == ["revert"])
        await #expect(throws: (any Error).self) { _ = try await f.review(engine) }
        _ = try await engine.inspectPullRequestAction(operationID: review.id)
        let inspected = try #require((await engine.current()).snapshot.pullRequestAction(review.id))
        #expect(inspected.phase == .unconfirmed && inspected.requiresAcknowledgment && inspected.outcome == nil)
        #expect(inspected.inspectedState?.state == .merged)
        #expect(try f.native.writes() == ["revert"])
        _ = try await engine.acknowledgePullRequestAction(operationID: review.id)
        let acknowledged = try #require((await engine.current()).snapshot.pullRequestAction(review.id))
        #expect(acknowledged.acknowledgedAt != nil && !acknowledged.requiresAcknowledgment)
        let fresh = try await f.review(engine)
        #expect(fresh.id != review.id)
        #expect(try f.native.writes() == ["revert"])
        await engine.discardPullRequestActionReview(reviewID: fresh.id)
        try WorkspaceJournal.validate((await engine.current()).snapshot)
    } catch { f.release(); await engine.shutdown(); throw error }
    f.release(); await engine.shutdown()
}
