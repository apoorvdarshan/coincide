import Foundation
import Testing

@testable import CoincideKit

/// Runs against the real, signed-in Grok CLI. Opt in with `COINCIDE_LIVE_TESTS=1` (through
/// `TEST_RUNNER_COINCIDE_LIVE_TESTS=1` for xcodebuild); `COINCIDE_LIVE_DIR` picks the parent of
/// the scratch folders. Prompts are tiny because they use the user's own subscription.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_TESTS"] == "1"), .serialized)
struct ACPLiveTests {
    private struct Agent {
        let session: ACPSession
        let log: ACPEventLog
        let launch: AgentLaunch
    }

    private func makeAgent(resume: String? = nil, accessMode: AccessMode = .fullAccess, directory: URL? = nil) async throws -> Agent {
        let executable = try #require(await ShellEnvironment.shared.which("grok"), "grok is not on PATH")
        let parent = ProcessInfo.processInfo.environment["COINCIDE_LIVE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let folder = directory ?? parent.appendingPathComponent("acp-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let launch = AgentLaunch(
            provider: .grok, executable: executable, environment: await ShellEnvironment.shared.environment(),
            workingDirectory: folder, resumeSessionID: resume,
            selection: ModelSelection(provider: .grok, modelID: GrokFlavor.defaultModelID), accessMode: accessMode,
            interactionMode: .build)
        let session = ACPSession(launch: launch, flavor: GrokFlavor())
        let log = ACPEventLog()
        log.attach(session)
        try await session.start()
        return Agent(session: session, log: log, launch: launch)
    }

    private func turn(
        _ agent: Agent, _ text: String, accessMode: AccessMode = .fullAccess, mode: InteractionMode = .build
    ) async throws -> String {
        let finished = agent.log.completions.count
        try await agent.session.send(
            AgentTurnInput(
                text: text, selection: ModelSelection(provider: .grok, modelID: GrokFlavor.defaultModelID), accessMode: accessMode,
                interactionMode: mode))
        await acpWaitUntil("the turn to finish", timeout: .seconds(180)) { agent.log.completions.count > finished }
        return Self.replyText(agent.log.events)
    }

    private static func replyText(_ events: [AgentEvent]) -> String {
        var texts: [String: String] = [:]
        var order: [String] = []
        for event in events {
            switch event {
            case .assistantTextDelta(let id, let delta):
                if texts[id] == nil { order.append(id) }
                texts[id, default: ""] += delta
            case .assistantText(let id, let text):
                if texts[id] == nil { order.append(id) }
                texts[id] = text
            default: break
            }
        }
        return order.compactMap { texts[$0] }.joined(separator: "\n")
    }

    @Test func turnsKeepTheirContext() async throws {
        let agent = try await makeAgent()
        defer { agent.session.shutdown() }
        let first = try await turn(agent, "Reply with exactly: pong")
        #expect(first.lowercased().contains("pong"))
        #expect(agent.log.completions == [.completed])

        agent.log.removeAll()
        let second = try await turn(agent, "What exact word did you just reply with? Answer with that word only.")
        #expect(second.lowercased().contains("pong"))
    }

    @Test func resumesASavedSession() async throws {
        let agent = try await makeAgent()
        _ = try await turn(agent, "Remember the word walnut. Reply with exactly: ok")
        let id = try #require(agent.session.sessionID)
        agent.session.shutdown()

        let resumed = try await makeAgent(resume: id, directory: agent.launch.workingDirectory)
        defer { resumed.session.shutdown() }
        #expect(resumed.session.sessionID == id)
        let reply = try await turn(resumed, "Which word did I ask you to remember? Reply with that word only.")
        #expect(reply.lowercased().contains("walnut"))
    }

    @Test func approvalsRoundTrip() async throws {
        let agent = try await makeAgent(accessMode: .approval)
        defer { agent.session.shutdown() }
        try await agent.session.send(
            AgentTurnInput(
                text: "Run this shell command and show its output: echo coincide-ok",
                selection: ModelSelection(provider: .grok, modelID: GrokFlavor.defaultModelID), accessMode: .approval,
                interactionMode: .build))
        await acpWaitUntil("an approval", timeout: .seconds(180)) { !agent.log.approvals.isEmpty || !agent.log.completions.isEmpty }
        let approval = try #require(agent.log.approvals.first)
        let allow = try #require(approval.options.first { $0.kind == .allowOnce })
        agent.session.respond(to: approval.id, optionID: allow.id)
        await acpWaitUntil("the turn to finish", timeout: .seconds(180)) { !agent.log.completions.isEmpty }
        #expect(agent.log.completions == [.completed])
        let outputs = agent.log.events.compactMap { event -> String? in
            if case .toolCompleted(_, _, let output) = event { return output }
            return nil
        }
        #expect(outputs.contains { $0.contains("coincide-ok") } || Self.replyText(agent.log.events).contains("coincide-ok"))
    }

    @Test func planModeProducesAPlan() async throws {
        let agent = try await makeAgent()
        defer { agent.session.shutdown() }
        let reply = try await turn(agent, "Plan how to add a README.md to this empty folder. Keep it to three steps.", mode: .plan)
        let planned = agent.log.events.contains { if case .plan = $0 { true } else { false } }
        #expect(planned || !reply.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: agent.launch.workingDirectory.appendingPathComponent("README.md").path))
    }

    @Test func interruptStopsTheTurn() async throws {
        let agent = try await makeAgent()
        defer { agent.session.shutdown() }
        try await agent.session.send(
            AgentTurnInput(
                text: "Count from 1 to 300, one number per line, with no other text.",
                selection: ModelSelection(provider: .grok, modelID: GrokFlavor.defaultModelID), accessMode: .fullAccess,
                interactionMode: .build))
        await acpWaitUntil("output", timeout: .seconds(180)) { !Self.replyText(agent.log.events).isEmpty || !agent.log.completions.isEmpty }
        agent.session.interrupt()
        await acpWaitUntil("the interrupted turn", timeout: .seconds(30)) { !agent.log.completions.isEmpty }
        try await Task.sleep(for: .seconds(1))
        #expect(agent.log.completions.count == 1)
        #expect(agent.log.completions.first == .interrupted || agent.log.completions.first == .completed)
    }
}
