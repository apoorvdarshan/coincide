import Foundation
import Testing
@testable import CoincideCore

private final class RemoteScriptProviderTripwire: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var launches: Int { lock.withLock { count } }
    func session() throws -> any ProviderSession {
        lock.withLock { count += 1 }; throw CoincideError("A reviewed cleanup fixture must not launch a provider.")
    }
}

@Test(.timeLimit(.minutes(1)))
func remoteProjectScriptReviewHydratesEveryCommandByteAndOriginalRefusalWinsAfterConfigurationChanges() async throws {
    let git = try await CheckpointFixture.make(), project = WorkspaceProject(path: git.repository.path)
    let request = GitWorktreeRequest(sourcePath: git.repository.path, destinationRoot: git.root.path,
        selection: .createBranch(name: "reviewed-cleanup", baseRef: "HEAD"))
    let worktrees = GitWorktreeService(request: request, environment: git.environment, gitExecutable: git.git)
    let worktreePlan = try await worktrees.prepare(), result = try await worktrees.run(worktreePlan)
    let workspace = URL(fileURLWithPath: result.destinationPath)
    let command = String(repeating: "printf '😀'; ", count: 7_000)
    let configuration = try ProjectConfiguration(scripts: [.init(name: "Full reviewed command", command: command, runOnSettle: true)])
    try JSONEncoder().encode(configuration).write(to: workspace.appendingPathComponent("t3.json"))
    let files = WorkspaceFileService(root: workspace), generation = UUID(), runID = UUID()
    let plan: ProjectScriptExecutionPlan
    do { plan = try await .capture(scriptIndex: 0, using: files, projectRoot: git.repository, shell: URL(fileURLWithPath: "/bin/sh"), id: runID); await files.close() }
    catch { await files.close(); throw error }
    var preparation = ThreadWorkspacePreparation(request: request)
    preparation.plan = worktreePlan; preparation.result = result; preparation.phase = .completed; preparation.endedAt = Date()
    var thread = CodingThread(project: project); thread.workspacePath = workspace.path; thread.workspacePreparation = preparation
    var run = ThreadProjectScriptRun(id: runID); run.plan = plan; run.phase = .awaitingApproval
    thread.settlement = .init(id: generation); thread.settlement?.script = run; thread.queuePaused = true
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let database = git.root.appendingPathComponent("review.sqlite"), probe = RemoteScriptProviderTripwire()
    try await WorkspaceDatabase(url: database).save(snapshot, event: "private-reviewed-script")
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in try probe.session() }, identityResolver: { _ in nil })
    let environment = UUID(), service = RemoteProjectScriptService(environmentID: environment, engine: engine)
    do {
        _ = try await engine.load()
        let target = RemoteWorkspaceTarget(environmentID: environment, projectID: project.id, threadID: thread.id,
            configuration: .init(thread: thread), rootID: UUID())
        let read = try await service.read(.init(target: target, generationID: generation))
        let state = try #require(read.script), review = try #require(state.review), reference = try #require(review.command.content)
        #expect(state.canApprove && review.command.preview.utf8.count <= 8_192 && reference.totalBytes == plan.script.command.utf8.count)
        #expect(try RemoteProjectScriptProtocol.payload(read).count <= RemoteProjectScriptProtocol.maximumResultBytes)
        var received = Data(), offset = 0
        while offset < reference.totalBytes {
            let request = RemoteProjectScriptContentRequest(claim: review.claim, reference: reference, offset: offset, maximumBytes: 1_003)
            let page = try await service.content(request), repeated = try await service.content(request)
            #expect(page == repeated && page.offset == offset && !page.data.isEmpty)
            received.append(page.data); offset += page.data.count
            #expect(page.nextOffset == (page.complete ? nil : offset))
        }
        #expect(received == Data(plan.script.command.utf8) && RemoteProjectionProtocol.digest(received) == reference.digest)
        let forged = RemoteProjectScriptClaim(id: review.claim.id, digest: String(repeating: "f", count: 64), target: target,
            generationID: generation, runID: runID, hostID: review.claim.hostID)
        await #expect(throws: RemoteProjectScriptFailure.self) { try await service.prepare(.projectScript(target: target, action: .approve(forged))) }
        let captured = try await service.prepare(.projectScript(target: target, action: .approve(review.claim)))
        _ = try await engine.dispatch(.editThread(thread.id, .model("Changed after review")))
        let accepted = RemoteEnvironmentCommandRequest(environmentID: environment, command: .projectScript(target: target, action: .approve(review.claim)))
        let refused = try await engine.dispatchRemoteEnvironment(accepted, preparation: captured)
        #expect(refused.rejection != nil && refused.commandID == accepted.id)
        #expect(try await engine.dispatchRemoteEnvironment(accepted, preparation: .none) == refused)
        let final = await engine.current()
        #expect(final.error == nil && final.snapshot.threads[0].settlement?.script?.phase == .awaitingApproval && probe.launches == 0)
    } catch { await service.close(); await engine.shutdown(); throw error }
    await service.close(); await engine.shutdown(); git.cleanup()
}

@Test(.timeLimit(.minutes(1)))
func remoteProjectScriptRecoveryRequiresPrivateIncarnationEvenWhenExactPublicIDsAreRecreatedAndFolderIsMissing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-script-incarnation-" + UUID().uuidString).resolvingSymlinksInPath()
    let workspace = root.appendingPathComponent("Workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let project = WorkspaceProject(path: workspace.path), generation = UUID(), runID = UUID()
    var thread = CodingThread(project: project), run = ThreadProjectScriptRun(id: runID)
    run.phase = .failed; run.error = ThreadProjectScriptRun.settleDiscoveryError
    thread.settlement = .init(id: generation); thread.settlement?.script = run; thread.queuePaused = true
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let database = root.appendingPathComponent("workspace.sqlite"), probe = RemoteScriptProviderTripwire()
    try await WorkspaceDatabase(url: database).save(snapshot, event: "private-rootless-recovery")
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in try probe.session() }, identityResolver: { _ in nil })
    let environment = UUID(), service = RemoteProjectScriptService(environmentID: environment, engine: engine)
    do {
        _ = try await engine.load()
        let target = RemoteWorkspaceTarget(environmentID: environment, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread))
        let action = RemoteProjectScriptAction.skip(generationID: generation, runID: runID)
        let old = try await service.prepare(.projectScript(target: target, action: action))
        _ = try await engine.dispatch(.removeProject(projectID: project.id, expectedThreadIDs: [thread.id]))
        _ = try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        try FileManager.default.removeItem(at: workspace)
        let stale = RemoteEnvironmentCommandRequest(environmentID: environment, command: .projectScript(target: target, action: action))
        #expect(try await engine.dispatchRemoteEnvironment(stale, preparation: old).rejection != nil)
        let current = try await service.read(.init(target: target, generationID: generation))
        #expect(current.script?.canSkip == true && current.script?.canRetry == false)
        let request = RemoteEnvironmentCommandRequest(environmentID: environment, command: .projectScript(target: target, action: action))
        let prepared = try await service.prepare(request.command)
        let receipt = try await engine.dispatchRemoteEnvironment(request, preparation: prepared)
        #expect(receipt.rejection == nil)
        await engine.awaitRemoteProjectScriptCompletion(request)
        #expect(await engine.current().snapshot.threads[0].settlement?.script?.phase == .skipped)
        #expect(probe.launches == 0)
    } catch { await service.close(); await engine.shutdown(); throw error }
    await service.close(); await engine.shutdown(); try FileManager.default.removeItem(at: root)
}
