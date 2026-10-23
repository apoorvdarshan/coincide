import Foundation
import Testing
@testable import CoincideCore

private actor ClaudeControlEnginePeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private let nativeID: String
    private(set) var inputs: [ProviderConfiguration] = []
    private(set) var closed = false
    init(nativeID: String) { self.nativeID = nativeID; (events, sink) = AsyncStream.makeStream() }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) throws {
        guard !closed, let run = thread.activeRun else { throw CancellationError() }
        inputs.append(run.configuration)
        sink.yield(.context(runID: run.id, event: .thread(nativeID)))
        sink.yield(.context(runID: run.id, event: .message(.init(id: "answer-" + run.id.uuidString, role: .assistant, text: "Offline answer"))))
        sink.yield(.context(runID: run.id, event: .completed(.idle)))
    }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { closed = true; sink.finish() }
}

private final class ClaudeControlEngineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [ClaudeControlEnginePeer] = []
    let nativeID = UUID().uuidString.lowercased()
    var sessions: [ClaudeControlEnginePeer] { lock.withLock { peers } }
    func make(_ thread: CodingThread) -> any ProviderSession {
        let peer = ClaudeControlEnginePeer(nativeID: nativeID)
        lock.withLock { peers.append(peer) }; return peer
    }
}

private func claudeControlEngineWait(_ engine: WorkspaceEngine, completed: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while true {
        let thread = await engine.current().snapshot.threads.first
        if thread?.activeRun == nil, thread?.runHistory?.filter({ $0.status == .completed }).count == completed { return }
        guard ContinuousClock.now < deadline else { throw CoincideError("The offline model-control engine did not finish its captured input.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1))) func claudeModelControlEngineReusesCompatibleEffortAndDrainsBeforeLaunchOnlyOrDefaultReset() async throws {
    let requested = try temporaryWorkspace()
    let root = URL(fileURLWithPath: try ClaudeRuntimeValidation.physical(requested.path, allowMissing: false))
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = ClaudeControlEngineProbe()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { probe.make($0) }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        let project = WorkspaceProject(path: root.path)
        var thread = CodingThread(project: project, model: "owned-model")
        thread.provider = .claude; thread.checkpointPolicy = .disabled
        thread.claudeRuntimeConfiguration = .init(executable: root.appendingPathComponent("never-launched").path,
            configurationDirectory: root.appendingPathComponent("Native").path, workspacePath: root.path, registeredWorkspacePath: project.path)
        thread.agentConfiguration = try ClaudeModelControl.setting(.init(effort: "high", thinking: false), in: nil)
        _ = try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        let row = ProviderModel(id: "owned-model", name: "Native model", reasoningEfforts: [.init(id: "high", description: "High"), .init(id: "max", description: "Maximum")],
            claudeCapabilities: .init(supportsThinking: true))
        let options: [ClaudeModelOptions] = [.init(effort: "high", thinking: false), .init(effort: "max", thinking: false), .init(thinking: false), .init(thinking: true)]
        for (index, selection) in options.enumerated() {
            _ = try await engine.dispatch(.editThread(thread.id, .claudeModelOptions(model: row, options: selection)))
            _ = try await engine.dispatch(.submit(threadID: thread.id, text: "Explicit offline input \(index)"))
            try await claudeControlEngineWait(engine, completed: index + 1)
            #expect(probe.sessions.count == [1, 1, 2, 3][index])
            let peer = try #require(probe.sessions.last)
            let captured = try #require(await peer.inputs.last)
            #expect(try ClaudeModelControl.options(in: captured) == selection)
            #expect(captured.model == "owned-model" && captured.claudeRuntimeConfiguration == thread.claudeRuntimeConfiguration)
            for retired in probe.sessions.dropLast() { #expect(await retired.closed) }
        }
        #expect(await probe.sessions[0].inputs.count == 2)
        #expect(await probe.sessions[1].inputs.count == 1)
        #expect(await probe.sessions[2].inputs.count == 1)
        await engine.shutdown()
        for peer in probe.sessions { #expect(await peer.closed) }
    } catch { await engine.shutdown(); throw error }
}
