import Foundation
import Testing

@testable import CoincideKit

/// Live runs use the user's own subscriptions, so prompts are tiny. `COINCIDE_LIVE_DIR` picks the
/// parent of the scratch folders (pass variables to xcodebuild as `TEST_RUNNER_<NAME>=…`).
private enum LiveRun {
    static func folder(_ prefix: String) throws -> URL {
        let parent = ProcessInfo.processInfo.environment["COINCIDE_LIVE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let folder = parent.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @MainActor
    static func replyText(_ events: [AgentEvent]) -> String {
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
}

/// Records every line a live agent exchanges, so its wire shapes can be checked afterwards.
@MainActor
private final class ACPRecordingTransport: ACPTransport {
    var onLine: ((String) -> Void)?
    var onStderr: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    private let inner: ACPProcessTransport
    private let log: FileHandle?

    init(inner: ACPProcessTransport, logURL: URL) {
        self.inner = inner
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try? FileHandle(forWritingTo: logURL)
        inner.onLine = { [weak self] line in
            self?.record("<- \(line)")
            self?.onLine?(line)
        }
        inner.onStderr = { [weak self] text in
            self?.record("!! \(text)")
            self?.onStderr?(text)
        }
        inner.onExit = { [weak self] status, tail in
            self?.record("exit \(status)")
            self?.onExit?(status, tail)
        }
    }

    func start() throws { try inner.start() }

    func write(_ line: String) {
        record("-> \(line)")
        inner.write(line)
    }

    func terminate() { inner.terminate() }

    private func record(_ text: String) {
        try? log?.write(contentsOf: Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
    }
}

/// Runs the generic client against Cursor's `cursor-agent acp`. Opt in with
/// `COINCIDE_LIVE_CURSOR_ACP=1`. It never selects a model or mode, because Cursor keeps such
/// choices as the account's defaults, and it never signs in, so no browser opens.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_CURSOR_ACP"] == "1"), .serialized)
struct ACPCursorLiveTests {
    private func launch(_ folder: URL, resume: String? = nil) async throws -> AgentLaunch {
        let executable = try #require(await ShellEnvironment.shared.which("cursor-agent"), "cursor-agent is not on PATH")
        var environment = await ShellEnvironment.shared.environment()
        environment["NO_OPEN_BROWSER"] = "1"
        return AgentLaunch(
            provider: .cursor, executable: executable, environment: environment, workingDirectory: folder,
            resumeSessionID: resume, selection: ModelSelection(provider: .cursor, modelID: "default"), accessMode: .approval,
            interactionMode: .build)
    }

    private func session(_ launch: AgentLaunch, record name: String) -> (ACPSession, ACPEventLog) {
        let flavor = ACPPlainFlavor(kind: .cursor, launchArguments: ["acp"], signsInWhenRequired: false)
        let folder = launch.workingDirectory
        let session = ACPSession(launch: launch, flavor: flavor) { executable, arguments, directory, environment in
            ACPRecordingTransport(
                inner: ACPProcessTransport(executable: executable, arguments: arguments, workingDirectory: directory, environment: environment),
                logURL: folder.appendingPathComponent("\(name).wire.log"))
        }
        let log = ACPEventLog()
        log.attach(session)
        return (session, log)
    }

    @Test func answersAPromptAndReloadsTheSession() async throws {
        let folder = try LiveRun.folder("acp-cursor")
        let (session, log) = session(try await launch(folder), record: "first")
        try await session.start()
        let id = try #require(session.sessionID)
        #expect(log.sessionIDs == [id])

        try await session.send(
            AgentTurnInput(
                text: "Reply with exactly: pong", selection: ModelSelection(provider: .cursor, modelID: "default"),
                accessMode: .approval, interactionMode: .build))
        await acpWaitUntil("the turn", timeout: .seconds(180)) { !log.completions.isEmpty || !log.approvals.isEmpty }
        for approval in log.approvals { session.respond(to: approval.id, optionID: ACPApprovals.cancelOptionID) }
        await acpWaitUntil("the turn", timeout: .seconds(60)) { !log.completions.isEmpty }
        #expect(log.completions == [.completed])
        #expect(LiveRun.replyText(log.events).lowercased().contains("pong"))
        try "\(log.events)".write(to: folder.appendingPathComponent("first.events.txt"), atomically: true, encoding: .utf8)
        session.shutdown()

        // Reopening replays the history, which must not reach the transcript again. No prompt is sent.
        let (reopened, reopenedLog) = self.session(try await launch(folder, resume: id), record: "reload")
        defer { reopened.shutdown() }
        try await reopened.start()
        #expect(reopened.sessionID == id)
        #expect(reopenedLog.sessionIDs == [id] || reopenedLog.events.contains(.sessionContinued(id: reopened.sessionID ?? "")))
        await acpSettle()
        #expect(!reopenedLog.events.contains { if case .assistantTextDelta = $0 { true } else { false } })
        #expect(reopenedLog.notices.isEmpty)
        try "\(reopenedLog.events)".write(to: folder.appendingPathComponent("reload.events.txt"), atomically: true, encoding: .utf8)
    }
}

/// Runs against the real, signed-in Grok CLI. Opt in with `COINCIDE_LIVE_TESTS=1`.
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
        let folder = try directory ?? LiveRun.folder("acp-live")
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
        return LiveRun.replyText(agent.log.events)
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
        #expect(outputs.contains { $0.contains("coincide-ok") } || LiveRun.replyText(agent.log.events).contains("coincide-ok"))
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
        await acpWaitUntil("output", timeout: .seconds(180)) {
            !LiveRun.replyText(agent.log.events).isEmpty || !agent.log.completions.isEmpty
        }
        agent.session.interrupt()
        await acpWaitUntil("the interrupted turn", timeout: .seconds(30)) { !agent.log.completions.isEmpty }
        try await Task.sleep(for: .seconds(1))
        #expect(agent.log.completions.count == 1)
        #expect(agent.log.completions.first == .interrupted || agent.log.completions.first == .completed)
    }
}
