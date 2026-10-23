import Foundation
import Testing
@testable import CoincideCore

@Test(.timeLimit(.minutes(1)))
func appMCPRuntimeLeaseFollowsCapturedQueuePermissionsAndRevokesBeforeChangedSuccessor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-mcp-lease-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project, model: "fixture-model")
    thread.checkpointPolicy = .disabled; thread.permission = .supervised
    let first = AppMCPLeasePeer(), successor = AppMCPLeasePeer(), threadID = thread.id
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), appMCPEnabled: true,
        providerFactory: { captured in
            guard captured.id == threadID, let run = captured.activeRun else { return AppMCPLeasePeer() }
            return run.configuration.permission == .supervised ? first : successor
        }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        _ = try await engine.dispatch(.addProject(project))
        _ = try await engine.dispatch(.createThread(thread))
        _ = try await engine.dispatch(.submit(threadID: threadID, text: "First explicit input"))
        try await appMCPLeaseEventually {
            let count = await first.sent.count, current = await engine.current()
            return count == 1 && current.snapshot.threads.first { $0.id == threadID }?.activeRun?.nativeTurnID != nil
        }
        let original = try await engine.appMCPContext(threadID: threadID)
        let credential = try #require(await first.connection)
        _ = try await engine.dispatch(.submit(threadID: threadID, text: "Queued before permission change"))
        _ = try await engine.dispatch(.editThread(threadID, .permission(.fullAccess)))
        let captured = try await engine.appMCPContext(threadID: threadID)
        #expect(captured.scope == original.scope && captured.configuration.permission == .supervised)
        await first.finish()
        try await appMCPLeaseEventually {
            let count = await first.sent.count, current = await engine.current()
            return count == 2 && current.snapshot.threads.first { $0.id == threadID }?.activeRun?.nativeTurnID != nil
        }
        let queued = try await engine.appMCPContext(threadID: threadID)
        #expect(queued.scope.sessionID == original.scope.sessionID && queued.configuration.permission == .supervised)
        #expect(await first.configureCount == 1)
        #expect(await first.sent.map(\.permission) == [.supervised, .supervised])
        await first.finish()
        try await appMCPLeaseEventually { await engine.current().snapshot.threads.first { $0.id == threadID }?.activeRun == nil }
        _ = try await engine.dispatch(.submit(threadID: threadID, text: "Explicit successor with new permission"))
        try await appMCPLeaseEventually {
            let count = await successor.sent.count, current = await engine.current()
            return count == 1 && current.snapshot.threads.first { $0.id == threadID }?.activeRun?.nativeTurnID != nil
        }
        let changed = try await engine.appMCPContext(threadID: threadID)
        #expect(changed.scope.sessionID != original.scope.sessionID && changed.scope.permission == .fullAccess)
        let closed = await first.closeCount, configured = await successor.configureCount
        #expect(closed == 1 && configured == 1)
        #expect(await successor.sent.map(\.permission) == [.fullAccess])
        var request = URLRequest(url: credential.endpoint)
        request.httpMethod = "POST"; request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 401)
        #expect(await engine.current().error == nil)
        await engine.shutdown(); try FileManager.default.removeItem(at: root)
    } catch { await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
}

private actor AppMCPLeasePeer: ProviderSession {
    nonisolated let supportsAppMCP = true
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private(set) var connection: AppMCPConnection?
    private(set) var configureCount = 0, closeCount = 0
    private(set) var sent: [ProviderConfiguration] = []
    private var runID: UUID?
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func configureAppMCP(_ connection: AppMCPConnection) { self.connection = connection; configureCount += 1 }
    func models() -> [ProviderModel] { [.init(id: "fixture-model", name: "Synthetic")] }
    func send(text: String, thread: CodingThread) {
        guard let run = thread.activeRun else { return }
        runID = run.id; sent.append(run.configuration)
        continuation.yield(.context(runID: run.id, event: .thread("native-lease-session")))
        continuation.yield(.context(runID: run.id, event: .turn("native-turn-" + run.id.uuidString)))
    }
    func finish() { if let runID { continuation.yield(.context(runID: runID, event: .completed(.idle))) } }
    func interrupt() { if let runID { continuation.yield(.context(runID: runID, event: .completed(.interrupted))) } }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { closeCount += 1; continuation.finish() }
}

private func appMCPLeaseEventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The app tool lease fixture did not reach the expected run.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
