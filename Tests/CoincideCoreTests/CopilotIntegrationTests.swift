import Foundation
import Testing
@testable import CoincideCore

private struct CopilotIntegrationTrace: Sendable {
    var rootText: [UUID: String] = [:]
    var entities: [ProviderEntityKey: ProviderEntity] = [:]
    var owners: [ProviderEntityKey: UUID] = [:]
    var completed: [UUID] = []
    var closed: String?
    var failure: String?
}

private actor CopilotIntegrationRecorder {
    private var trace = CopilotIntegrationTrace()
    func record(_ scoped: ProviderEvent) throws {
        let context: UUID?, event: ProviderEvent
        if case .context(let owner, let nested) = scoped { context = owner; event = nested }
        else { context = nil; event = scoped }
        switch event {
        case .delta(_, let role, let text):
            guard role == .assistant, let context else { return }
            trace.rootText[context, default: ""] += text
        case .runEntity(let owner, let update):
            guard trace.owners[update.key] == nil || trace.owners[update.key] == owner else {
                throw CoincideError("A synthetic child entity changed its captured run owner.")
            }
            trace.entities[update.key] = try update.apply(to: trace.entities[update.key]); trace.owners[update.key] = owner
        case .completed(let state):
            guard let context else { throw CoincideError("A synthetic foreground completion lost its run scope.") }
            #expect(state == .idle); trace.completed.append(context)
        case .connectionClosed(let reason): trace.closed = reason
        case .failure(let reason): trace.failure = reason
        default: break
        }
    }
    func snapshot() -> CopilotIntegrationTrace { trace }
}

private struct CopilotIntegrationFixture {
    let root: URL
    let wire: URL
    let session: ACPSession
    let recorder: CopilotIntegrationRecorder
    let reader: Task<Void, any Error>

    init(mode: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-copilot-integration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.root = root; wire = root.appendingPathComponent("wire.jsonl")
        let peer = try #require(Bundle.module.url(forResource: "copilot_acp_server", withExtension: "py", subdirectory: "Fixtures"))
        let session = try ACPSession(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [peer.path, mode, wire.path], cwd: root, integration: .copilot)
        self.session = session
        let recorder = CopilotIntegrationRecorder(); self.recorder = recorder
        reader = Task { for await event in session.events { try await recorder.record(event) } }
    }
    func thread(runID: UUID) -> CodingThread {
        var thread = CodingThread(project: WorkspaceProject(path: root.path))
        thread.provider = .acp; thread.acpAgent = ACPIntegration.copilot.configuration()
        let configuration = ProviderConfiguration(thread: thread)
        thread.activeRun = .init(id: runID, configuration: configuration, startedAt: .now, nativeTurnID: nil)
        return thread
    }
    func events(until predicate: (CopilotIntegrationTrace) -> Bool) async throws -> CopilotIntegrationTrace {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let trace = await recorder.snapshot()
            if predicate(trace) { return trace }
            if let reason = trace.failure ?? trace.closed { throw CoincideError(reason) }
            guard ContinuousClock.now < deadline else { throw CoincideError("The offline Copilot session did not reach its expected event boundary.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func frames() throws -> [JSONValue] {
        try Data(contentsOf: wire).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func finish() async {
        await session.close(); _ = try? await reader.value
        try? FileManager.default.removeItem(at: root)
    }
}

@Test(.timeLimit(.minutes(1)))
func copilotACPSessionAdvertisesNamedProfileRoutesChildrenAndRetainsOriginalOwnerAcrossTheNextRun() async throws {
    let fixture = try CopilotIntegrationFixture(mode: "ownership"), first = UUID(), second = UUID()
    do {
        try await fixture.session.send(text: "first", thread: fixture.thread(runID: first))
        let initial = try await fixture.events { $0.completed == [first] }
        #expect(initial.rootText[first] == "root first")
        let firstText = initial.entities.values.filter { $0.key.type == "agent_message" }.map(\.text).joined()
        #expect(firstText == "child first café λ")
        #expect(initial.entities.values.contains { $0.key.type == "agent_thought" && $0.text == "child thought first" })
        #expect(initial.entities.values.contains { $0.key.type == "tool_call" && $0.text.contains("Nested child result") })
        let lifecycle = try #require(initial.entities.values.first { $0.key.id == "copilot-child-lifecycle" })
        #expect(lifecycle.fields["status"] == .string("in_progress"), "Completing a background launcher must not complete its child.")
        #expect(Set(initial.owners.values) == [first])

        var thread = fixture.thread(runID: second); thread.providerThreadID = "copilot-integration-root"
        let configuration = ProviderConfiguration(thread: thread)
        thread.activeRun?.configuration = configuration
        try await fixture.session.send(text: "second", thread: thread)
        let final = try await fixture.events { $0.completed == [first, second] }
        #expect(final.rootText == [first: "root first", second: "root second"])
        #expect(Set(final.owners.values) == [first], "A child result during a newer foreground run keeps its original owner.")
        let text = final.entities.values.map(\.text).joined(separator: "\n")
        #expect(text.contains("child late during second run"))
        #expect(!text.contains("DROP unknown child") && !text.contains("DROP finished child"))
        let completed = try #require(final.entities.values.first { $0.key.id == "copilot-child-lifecycle" })
        #expect(completed.fields["status"] == .string("completed"))
        #expect(completed.fields["_meta"]["github.com/copilot"]["parentRunID"].string == first.uuidString)
        let frames = try fixture.frames()
        #expect(frames.filter { $0["method"] == .string("initialize") }.count == 1)
        #expect(frames.filter { $0["method"] == .string("session/new") }.count == 1)
        #expect(frames.filter { $0["method"] == .string("session/prompt") }.count == 2)
        #expect(frames.first?["params"]["clientCapabilities"] == .object(["_meta": CopilotACPBridge.clientCapabilitiesMetadata]))
        await fixture.finish()
    } catch { await fixture.finish(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["missing", "null"])
func copilotACPSessionMissingChildMessageIDsUseBoundedStableFallbackWithoutContaminatingRoot(mode: String) async throws {
    let fixture = try CopilotIntegrationFixture(mode: mode), run = UUID()
    do {
        try await fixture.session.send(text: "first", thread: fixture.thread(runID: run))
        let trace = try await fixture.events { $0.completed == [run] }
        #expect(trace.rootText[run] == "root first")
        let message = try #require(trace.entities.values.first { $0.key.type == "agent_message" })
        #expect(message.text == "child first café λ" && message.key.id.hasPrefix("copilot-\(run)-segment-"))
        #expect(message.key.id.utf8.count < 128 && trace.owners[message.key] == run)
        #expect(trace.closed == nil && trace.failure == nil)
        await fixture.finish()
    } catch { await fixture.finish(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["number", "object", "oversized"])
func copilotACPSessionInvalidChildMessageIDsCloseWithFixedErrorWithoutAForcedUnwrapOrPrivatePayload(mode: String) async throws {
    let fixture = try CopilotIntegrationFixture(mode: mode)
    do {
        try await fixture.session.send(text: "first", thread: fixture.thread(runID: UUID()))
        let trace = try await fixture.events { $0.closed != nil }
        #expect(trace.closed == CopilotACPBridge.failureMessage)
        #expect(trace.failure == nil && trace.completed.isEmpty)
        #expect(trace.entities.values.allSatisfy { $0.key.type != "agent_message" })
        #expect(trace.closed?.contains("synthetic-private-token") == false)
        await fixture.finish()
    } catch { await fixture.finish(); throw error }
}
