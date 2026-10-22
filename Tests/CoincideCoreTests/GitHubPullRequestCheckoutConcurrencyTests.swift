import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor PRCheckoutLiveWrites {
    var count = 0
    func wrote() { count += 1 }
}

private actor PRCheckoutReadProgress {
    private(set) var finished = false
    func finish() { finished = true }
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestInspectOnlyCompletesWhileAnUnrelatedCommonDirectoryMutationIsHeld() async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    let initial = try await f.service().prepare(), target = f.api.git.root.appendingPathComponent("Target beside held mutation")
    _ = try await f.git(["worktree", "add", "-b", initial.requestedBranch, target.path, f.api.base])
    let service = try f.service(policy: .inspectOnly), plan = try await service.prepare()
    let before = try await f.api.git.state(at: target), gate = RestoreEngineGate(), progress = PRCheckoutReadProgress()
    let holder = Task {
        try await GitOperationGate.shared.perform(key: plan.commonDirectoryPath) { await gate.wait() }
    }
    var observation: Task<(GitHubPullRequestCheckoutResult, GitHubPullRequestCheckoutInspection), any Error>?
    do {
        let enteredDeadline = ContinuousClock.now + .seconds(5)
        while !(await gate.entered) {
            guard ContinuousClock.now < enteredDeadline else { throw CoincideError("The owned common-directory mutation did not acquire its gate.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let task = Task {
            do {
                let result = try await service.run(plan), inspection = try await service.inspectCompletion(plan)
                await progress.finish()
                return (result, inspection)
            } catch { await progress.finish(); throw error }
        }
        observation = task
        let observationDeadline = ContinuousClock.now + .seconds(10)
        while !(await progress.finished) {
            guard ContinuousClock.now < observationDeadline else { throw CoincideError("Read-only checkout inspection waited for an unrelated Git mutation.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        // The shared mutation remains held until both observations have finished.
        let (result, inspection) = try await task.value
        #expect(result.reused && !result.created && !result.moved)
        #expect(result.worktreePlan?.baseCommit == result.headCommit && result.worktreeResult?.headCommit == result.headCommit)
        #expect(inspection == .completed(result))
        #expect(try await f.api.git.state(at: target) == before)
        #expect(!FileManager.default.fileExists(atPath: f.source.appendingPathComponent(".git/" + GitHubPullRequestCheckoutService.metadataName(plan.id)).path))
        await gate.release(); try await holder.value
    } catch {
        await gate.release()
        if let observation { observation.cancel(); _ = try? await observation.value }
        holder.cancel(); _ = try? await holder.value
        throw error
    }
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestInspectOnlyDoesNotWaitForLiveTargetFileWritesOrCreateOwnershipMetadata() async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    let initial = try await f.service().prepare(), target = f.api.git.root.appendingPathComponent("Actively written checkout")
    _ = try await f.git(["worktree", "add", "-b", initial.requestedBranch, target.path, f.api.base])
    let service = try f.service(policy: .inspectOnly), plan = try await service.prepare()
    let path = target.appendingPathComponent("tracked.txt"), bytes = Data("Actively written provider bytes\n".utf8)
    try bytes.write(to: path)
    let descriptor = open(path.path, O_WRONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw CoincideError("Could not open the owned fixture writer.") }
    let writes = PRCheckoutLiveWrites()
    let writer = Task {
        defer { close(descriptor) }
        while !Task.isCancelled {
            let count = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress!, $0.count, 0) }
            guard count == bytes.count else { throw CoincideError("The owned fixture writer failed.") }
            await writes.wrote()
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    do {
        let deadline = ContinuousClock.now + .seconds(3)
        while await writes.count == 0 {
            guard ContinuousClock.now < deadline else { throw CoincideError("The owned writer did not start.") }
            try await Task.sleep(for: .milliseconds(2))
        }
        let before = await writes.count, result = try await service.run(plan)
        let after = await writes.count
        #expect(after > before && result.reused && !result.moved)
        #expect(try await service.inspectCompletion(plan) == .completed(result))
        #expect(try Data(contentsOf: path) == bytes)
        #expect(!FileManager.default.fileExists(atPath: f.source.appendingPathComponent(".git/" + GitHubPullRequestCheckoutService.metadataName(plan.id)).path))
        writer.cancel(); _ = try? await writer.value
    } catch { writer.cancel(); _ = try? await writer.value; throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["edit", "commit", "switch"])
func githubPullRequestIndependentWorktreeAllowsSourceProgressBeforeAndAfterCompletion(kind: String) async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    let service = try f.service(), plan = try await service.prepare()
    #expect(plan.affectedWorkspacePaths == [plan.destinationPath] && plan.coordinationPaths == [plan.commonDirectoryPath])
    if kind == "switch" { _ = try await f.git(["checkout", "feature/topic"]) }
    else {
        try f.api.git.write("provider-working.txt", "Source provider progress preserved\n")
        if kind == "commit" { try await f.api.git.commitAll() }
        else { _ = try await f.git(["add", "provider-working.txt"]) }
    }
    // Another independent checkout can add its own tracking without changing
    // this PR's remote or execution policy.
    _ = try await f.git(["config", "branch.another-independent-target.remote", "origin"])
    _ = try await f.git(["config", "branch.another-independent-target.merge", "refs/heads/another-topic"])
    let before = try await f.api.git.state(), result = try await service.run(plan)
    let after = try await f.api.git.state()
    #expect(after.head == before.head && after.indexFiles == before.indexFiles && after.files == before.files)
    #expect(after.staged == before.staged && after.flags == before.flags)
    #expect(result.isOnPullRequestHead && result.headCommit == f.api.head)
    try f.api.git.write("later-provider-progress.txt", "Progress after the independent checkout completed\n")
    try await f.api.git.commitAll()
    _ = try await f.git(["config", "branch.yet-another-target.remote", "upstream"])
    let inspection = try await service.inspectCompletion(plan)
    #expect(inspection == .completed(result))
    #expect(try String(contentsOf: f.source.appendingPathComponent("later-provider-progress.txt"), encoding: .utf8) == "Progress after the independent checkout completed\n")
}

@Test(.timeLimit(.minutes(1)))
func githubPullRequestBusyRegisteredCheckoutIsPureObservationOfItsCurrentHeadAndBytes() async throws {
    let f = try await PRCheckoutFixture.make(); defer { f.cleanup() }
    let initial = try await f.service().prepare(), target = f.api.git.root.appendingPathComponent("Busy registered target")
    _ = try await f.git(["worktree", "add", "-b", initial.requestedBranch, target.path, f.api.base])
    let service = try f.service(policy: .inspectOnly), plan = try await service.prepare()
    #expect(plan.isReadOnly && plan.affectedWorkspacePaths.isEmpty && plan.coordinationPaths.isEmpty)
    // Provider progress after review is observable, rather than a stale-file
    // rejection or permission to fetch/reset this occupied checkout.
    try Data("Live provider commit\n".utf8).write(to: target.appendingPathComponent("live.txt"))
    _ = try await f.git(["add", "live.txt"], at: target)
    _ = try await f.git(["commit", "-m", "Provider progressed after review"], at: target)
    try Data("Current staged edit\n".utf8).write(to: target.appendingPathComponent("tracked.txt"))
    _ = try await f.git(["add", "tracked.txt"], at: target)
    try Data("Current unstaged edit\n".utf8).write(to: target.appendingPathComponent("live.txt"))
    let head = try await f.git(["rev-parse", "HEAD"], at: target), before = try await f.api.git.state(at: target)
    let configuration = try Data(contentsOf: f.source.appendingPathComponent(".git/config"))
    let refs = try await f.git(["for-each-ref", "--format=%(refname) %(objectname)"])
    let managed = try FileManager.default.contentsOfDirectory(atPath: f.managed.path)
    let result = try await service.run(plan)
    #expect(result.reused && !result.created && !result.moved && !result.isOnPullRequestHead)
    #expect(result.headCommit == head && result.worktreePlan?.baseCommit == head && result.worktreeResult?.headCommit == head)
    #expect(try await f.api.git.state(at: target) == before)
    #expect(try Data(contentsOf: f.source.appendingPathComponent(".git/config")) == configuration)
    #expect(try await f.git(["for-each-ref", "--format=%(refname) %(objectname)"]) == refs)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.managed.path) == managed)
    #expect(!FileManager.default.fileExists(atPath: f.source.appendingPathComponent(".git/" + GitHubPullRequestCheckoutService.metadataName(plan.id)).path))
    #expect(try await service.inspectCompletion(plan) == .completed(result))
    #expect(try await f.api.git.state(at: target) == before)
}

@Test
func githubPullRequestCheckoutPolicyDecodesLegacyAndRejectsInspectOnlyCreationOrLocalMutation() throws {
    let repository = try GitHubRepository(owner: "upstream", name: "project")
    let request = GitHubPullRequestCheckoutRequest(sourcePath: "/tmp/source", destinationRoot: "/tmp/worktrees",
        reference: try .init(repository: repository, number: 42), mode: .local, policy: .inspectOnly)
    #expect(throws: (any Error).self) { try request.validate() }
    var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    value.removeValue(forKey: "policy")
    let legacy = try JSONDecoder().decode(GitHubPullRequestCheckoutRequest.self, from: JSONSerialization.data(withJSONObject: value))
    #expect(legacy.policy == .refresh)
    try legacy.validate()
}
