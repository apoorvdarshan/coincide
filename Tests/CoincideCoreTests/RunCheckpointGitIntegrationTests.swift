import Foundation
import Testing
@testable import CoincideCore

private actor CheckpointGitProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private(set) var received: [CodingThread] = []
    init() {
        let pair = AsyncStream<ProviderEvent>.makeStream()
        events = pair.stream; sink = pair.continuation
    }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) { received.append(thread) }
    func finish() {
        if let id = received.last?.activeRun?.id { sink.yield(.context(runID: id, event: .completed(.idle))) }
    }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { sink.finish() }
}

private func checkpointGitWait(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(12)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The real Git checkpoint pipeline did not reach its boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1)))
func runCheckpointRealGitPipelineCapturesBeforeProviderAndAfterRunBeforeFIFOThenReopensDiff() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    try fixture.write("tracked.txt", "Staged content\n")
    _ = try await fixture.run(["add", "--", "tracked.txt"])
    try fixture.write("tracked.txt", "Before-run working bytes\n")
    try fixture.write("untracked.txt", "Keep this untracked file\n")
    let beforeUserState = try await fixture.state()
    let database = fixture.root.appendingPathComponent("workspace.sqlite"), provider = CheckpointGitProvider()
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in provider }, identityResolver: { _ in nil },
        checkpointFactory: { fixture.service(at: $0) })
    let project = WorkspaceProject(path: fixture.repository.path), thread = CodingThread(project: project)
    do {
        _ = try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        _ = try await engine.dispatch(.submit(threadID: thread.id, text: "Observe the first run"))
        try await checkpointGitWait { await provider.received.count == 1 }
        let firstDispatch = try #require(await provider.received.first)
        let firstRecord = try #require(firstDispatch.runHistory?.last)
        let baseline = try #require(firstRecord.checkpoints?.baseline.receipt)
        #expect(firstRecord.checkpoints?.providerReleased == true)
        #expect(firstRecord.checkpoints?.baseline.phase == .ready)
        #expect(firstRecord.checkpoints?.baseline.cleanupWarning == nil)
        #expect(try await fixture.blob(baseline, "tracked.txt") == Data("Before-run working bytes\n".utf8))
        #expect(try await fixture.state() == beforeUserState)
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: baseline.plan.gitDirectoryPath)
            .appendingPathComponent(CheckpointFiles.indexName(baseline.plan.id)).path))

        _ = try await engine.dispatch(.editThread(thread.id, .checkpointPolicy(.disabled)))
        _ = try await engine.dispatch(.submit(threadID: thread.id, text: "Run second after the saved observation"))
        try fixture.write("tracked.txt", "After-run working bytes\n")
        let afterUserState = try await fixture.state()
        await provider.finish()
        try await checkpointGitWait { await provider.received.count == 2 }
        let secondDispatch = try #require(await provider.received.last)
        let completed = try #require(secondDispatch.runHistory?.first { $0.id == firstRecord.id })
        let post = try #require(completed.checkpoints?.postRun?.receipt)
        #expect(completed.status == .completed && completed.checkpoints?.postRun?.phase == .ready)
        #expect(completed.checkpoints?.postRun?.cleanupWarning == nil)
        #expect(secondDispatch.runHistory?.last?.checkpoints == nil)
        #expect(try await fixture.blob(post, "tracked.txt") == Data("After-run working bytes\n".utf8))
        #expect(try await fixture.state() == afterUserState)
        let diff = try await engine.runCheckpointDiff(threadID: thread.id, runID: firstRecord.id)
        #expect(diff.patch.contains("-Before-run working bytes"))
        #expect(diff.patch.contains("+After-run working bytes"))
        #expect(!FileManager.default.fileExists(atPath: fixture.attempt(post.plan).appendingPathComponent("git").path))
        await provider.finish()
        try await checkpointGitWait { await engine.current().snapshot.threads.first?.activeRun == nil }
        await engine.shutdown()

        let reopenedProvider = CheckpointGitProvider()
        let reopened = try WorkspaceEngine(url: database, providerFactory: { _ in reopenedProvider }, identityResolver: { _ in nil },
            checkpointFactory: { fixture.service(at: $0) })
        do {
            _ = try await reopened.load()
            #expect(try await reopened.runCheckpointDiff(threadID: thread.id, runID: firstRecord.id) == diff)
            #expect(await reopenedProvider.received.isEmpty)
            #expect(try await fixture.state() == afterUserState)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    } catch { await engine.shutdown(); throw error }
}
