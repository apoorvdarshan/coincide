import Foundation
import Testing

@testable import CoincideKit

/// OpenCode's free models by default, so the tests do not spend the user's subscription.
private let liveModel = ProcessInfo.processInfo.environment["COINCIDE_OPENCODE_LIVE_MODEL"] ?? "opencode/big-pickle"
private let liveVisionModel =
    ProcessInfo.processInfo.environment["COINCIDE_OPENCODE_LIVE_VISION_MODEL"] ?? "opencode/nemotron-3.5-super-vl-free"

/// Runs the installed OpenCode with the user's own login. Opt in with `COINCIDE_LIVE_TESTS=1`
/// (`TEST_RUNNER_COINCIDE_LIVE_TESTS=1` through xcodebuild). Prompts are tiny; the sessions they create
/// are deleted afterwards and the server is stopped.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_TESTS"] == "1"), .serialized)
struct OpenCodeLiveTests {
    @Test func detectsInstallationAndModels() async throws {
        defer { OpenCodeServerPool.shared.shutdownAll() }
        let provider = OpenCodeProvider()
        let environment = await ShellEnvironment.shared.environment()
        let executable = try #require(await ShellEnvironment.shared.which("opencode"))
        let status = await provider.detect(executable: executable, environment: environment)
        #expect(status.state == .ready, "\(status.message ?? "")")
        #expect(status.version?.hasPrefix("2.") == true)
        let models = await provider.models(status: status, environment: environment)
        #expect(models.contains { $0.modelID == liveModel })
        #expect(models.allSatisfy { $0.provider == .opencode && $0.modelID.contains("/") })
    }

    @Test func turnsKeepContextAndResume() async throws {
        try await withLiveOpenCode { live in
            let first = try await live.start()
            let sessionID = try #require(first.session.sessionID)
            #expect(first.recorder.events.first == .sessionStarted(id: sessionID))

            try await first.session.send(live.input("Reply with exactly: pong"))
            #expect(try await first.recorder.turnOutcome() == .completed)
            #expect(first.recorder.assistantText.lowercased().contains("pong"))

            let mark = first.recorder.events.count
            try await first.session.send(
                live.input("Which single word did you reply with in your previous message? Reply with only that word."))
            #expect(try await first.recorder.turnOutcome(after: mark) == .completed)
            #expect(first.recorder.assistantText(after: mark).lowercased().contains("pong"))
            first.session.shutdown()

            let resumed = try await live.start(resuming: sessionID)
            #expect(resumed.recorder.events.first == .sessionStarted(id: sessionID))
            try await resumed.session.send(
                live.input("Which word did you reply with in your first message of this conversation? Reply with only that word."))
            #expect(try await resumed.recorder.turnOutcome() == .completed)
            #expect(resumed.recorder.assistantText.lowercased().contains("pong"))
        }
    }

    @Test func approvalRoundTrip() async throws {
        try await withLiveOpenCode(accessMode: .approval) { live in
            let run = try await live.start()
            try await run.session.send(
                live.input("Run this exact command with your shell tool: echo coincide-ok. Then reply with exactly: done"))
            let request = try await run.recorder.approval()
            #expect(request.category == .command)
            #expect(request.title.contains("echo coincide-ok"))

            // Small models sometimes run the command again; allow every request until the turn ends.
            var answered: Set<String> = []
            var outcome: TurnOutcome?
            let deadline = Date().addingTimeInterval(180)
            while outcome == nil {
                guard Date() < deadline else { throw LiveTestError("The turn did not end: \(run.recorder.events)") }
                for case .approvalRequested(let pending) in run.recorder.events where !answered.contains(pending.id) {
                    answered.insert(pending.id)
                    let allow = try #require(pending.options.first { $0.kind == .allowOnce })
                    run.session.respond(to: pending.id, optionID: allow.id)
                }
                outcome = run.recorder.turnEnds.first
                if outcome == nil { try await Task.sleep(for: .milliseconds(200)) }
            }
            #expect(outcome == .completed)
            let outputs = run.recorder.events.compactMap { event -> String? in
                if case .toolCompleted(_, .completed, let output) = event { return output }
                return nil
            }
            #expect(outputs.contains { $0.contains("coincide-ok") })
        }
    }

    @Test func questionRoundTrip() async throws {
        try await withLiveOpenCode { live in
            let run = try await live.start()
            try await run.session.send(
                live.input(
                    "Use your question tool to ask me which color I prefer, with the options red and blue. After I answer, reply with exactly the color I chose."
                ))
            let event = try await run.recorder.wait { event in
                if case .userInputRequested = event { return true }
                if case .turnCompleted = event { return true }
                return false
            }
            guard case .userInputRequested(let request) = event else {
                throw LiveTestError("The turn ended without a question: \(run.recorder.events)")
            }
            let question = try #require(request.questions.first)
            let blue = try #require(question.options.first { $0.label.lowercased().contains("blue") })
            run.session.answer(userInput: request.id, answers: [question.id: [blue.label]])
            #expect(try await run.recorder.turnOutcome() == .completed)
            // Answered here, so it is not reported as resolved by the agent.
            #expect(!run.recorder.events.contains(.userInputResolved(id: request.id)))
            #expect(run.recorder.assistantText.lowercased().contains("blue"))
        }
    }

    @Test func planModeDoesNotEditFiles() async throws {
        try await withLiveOpenCode(interactionMode: .plan) { live in
            let run = try await live.start()
            let sessionID = try #require(run.session.sessionID)
            #expect(try await live.api().session(sessionID)["agent"]?.string == "plan")

            try await run.session.send(
                live.input("Create a file named plan-check.txt containing hello. Keep your answer under 40 words."))
            #expect(try await run.recorder.turnOutcome() == .completed)
            #expect(!run.recorder.assistantText.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: live.directory.appendingPathComponent("plan-check.txt").path))
        }
    }

    @Test func interruptEndsTheTurnOnce() async throws {
        try await withLiveOpenCode { live in
            let run = try await live.start()
            try await run.session.send(live.input("Write the numbers from one to four hundred as words, one per line."))
            _ = try? await run.recorder.wait(timeout: 60) { event in
                if case .assistantTextDelta = event { return true }
                if case .turnCompleted = event { return true }
                return false
            }
            run.session.interrupt()
            let outcome = try await run.recorder.turnOutcome(timeout: 10)
            #expect(outcome == .interrupted, "Events: \(run.recorder.events)")
            try await Task.sleep(for: .seconds(2))
            #expect(run.recorder.turnEnds.count == 1)

            let mark = run.recorder.events.count
            try await run.session.send(live.input("Reply with exactly: ok"))
            let next = try await run.recorder.turnOutcome(after: mark)
            #expect(next == .completed, "Events: \(run.recorder.events.dropFirst(mark))")
        }
    }

    /// Steers a turn while a command runs: OpenCode takes the message in with `steer` delivery and the turn ends once,
    /// after the agent answered it.
    @Test func steeringRedirectsTheRunningTurn() async throws {
        try await withLiveOpenCode { live in
            let run = try await live.start()
            try await run.session.send(
                live.input("Run this exact command once with your shell tool: sleep 8; echo first. Then reply with exactly: first"))
            _ = try await run.recorder.wait(timeout: 60) { event in
                if case .toolStarted = event { return true }
                if case .turnCompleted = event { return true }
                return false
            }
            try #require(run.recorder.turnEnds.isEmpty, "the turn ended before it could be steered")
            try await run.session.steer(live.input("Change of plan: after the command, reply with exactly: steered"))
            let outcome = try await run.recorder.turnOutcome()
            try await Task.sleep(for: .seconds(2))
            #expect(outcome == .completed, "Events: \(run.recorder.events)")
            #expect(run.recorder.turnEnds == [.completed])
            #expect(run.recorder.assistantText.lowercased().contains("steered"))
            #expect(!run.recorder.events.contains { if case .agentTurnStarted = $0 { true } else { false } })
        }
    }

    @Test func commandOutputStreams() async throws {
        try await withLiveOpenCode { live in
            let run = try await live.start()
            try await run.session.send(
                live.input(
                    "Run this exact command once with your shell tool: for i in 1 2 3 4; do echo tick$i; sleep 1; done. Then reply with exactly: done"
                ))
            #expect(try await run.recorder.turnOutcome() == .completed)
            let events = run.recorder.events
            let completed = try #require(
                events.firstIndex { event in
                    if case .toolCompleted(_, _, let output) = event { return output?.contains("tick4") == true }
                    return false
                })
            guard case .toolCompleted(let toolID, let status, _) = events[completed] else { return }
            #expect(status == .completed)
            let streamed = events[..<completed].contains { event in
                if case .toolOutput(let id, let delta) = event { return id == toolID && delta.contains("tick") }
                return false
            }
            #expect(streamed)
        }
    }

    @Test func imagesReachTheModel() async throws {
        try await withLiveOpenCode(model: liveVisionModel) { live in
            let image = live.directory.appendingPathComponent("swatch.png")
            // A 1×1 red pixel.
            try Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
                .write(to: image)
            let run = try await live.start()
            try await run.session.send(
                live.input("What is the color of the attached image? Reply with one word.", imagePaths: [image.path]))
            #expect(try await run.recorder.turnOutcome() == .completed)
            #expect(run.recorder.assistantText.lowercased().contains("red"))
        }
    }

    @Test func resumingAMissingSessionStartsFresh() async throws {
        try await withLiveOpenCode { live in
            let run = try await live.start(resuming: "ses_coincidemissing0000000000")
            let sessionID = try #require(run.session.sessionID)
            #expect(sessionID != "ses_coincidemissing0000000000")
            #expect(
                run.recorder.events == [
                    .sessionStarted(id: sessionID),
                    .notice("Couldn't resume the earlier OpenCode session, so a new one was started."),
                ])
        }
    }

    @Test func serverExitEndsTheTurnAndSession() async throws {
        try await withLiveOpenCode { live in
            let run = try await live.start()
            try await run.session.send(live.input("Run this exact command with your shell tool: sleep 20"))
            // The turn is surely still running while the command sleeps.
            _ = try await run.recorder.wait { event in
                if case .toolUpdated(let call) = event { return call.detail?.contains("sleep 20") == true }
                return false
            }
            kill(try await live.serverPID(), SIGTERM)
            _ = try await run.recorder.wait(timeout: 30) { event in
                if case .sessionExited = event { return true }
                return false
            }
            let ends = run.recorder.events.suffix(2)
            guard case .turnCompleted(.failed(let reason)) = ends.first, case .sessionExited(let error) = ends.last else {
                throw LiveTestError("Expected the turn to fail before the session ended: \(run.recorder.events)")
            }
            #expect(reason.contains("OpenCode exited unexpectedly"))
            #expect(error == reason)
            #expect(run.recorder.turnEnds.count == 1)
            await #expect(throws: AgentError.self) { try await run.session.send(live.input("Reply with exactly: pong")) }
        }
    }

    private func withLiveOpenCode(
        accessMode: AccessMode = .fullAccess, interactionMode: InteractionMode = .build, model: String = liveModel,
        _ body: (LiveOpenCode) async throws -> Void
    ) async throws {
        let live = try await LiveOpenCode(accessMode: accessMode, interactionMode: interactionMode, model: model)
        do {
            try await body(live)
        } catch {
            await live.finish()
            throw error
        }
        await live.finish()
    }
}

/// One live test's OpenCode sessions in a fresh directory.
@MainActor
private final class LiveOpenCode {
    struct Run {
        let session: AgentSession
        let recorder: EventRecorder
    }

    let directory: URL
    private let executable: URL
    private let environment: [String: String]
    private let accessMode: AccessMode
    private let interactionMode: InteractionMode
    private let selection: ModelSelection
    private var runs: [Run] = []

    init(accessMode: AccessMode, interactionMode: InteractionMode, model: String) async throws {
        let root =
            ProcessInfo.processInfo.environment["COINCIDE_LIVE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("coincide-live")
        directory = root.appendingPathComponent("opencode-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        environment = await ShellEnvironment.shared.environment()
        executable = try #require(await ShellEnvironment.shared.which("opencode"))
        self.accessMode = accessMode
        self.interactionMode = interactionMode
        selection = ModelSelection(provider: .opencode, modelID: model)
    }

    func start(resuming sessionID: String? = nil) async throws -> Run {
        let launch = AgentLaunch(
            provider: .opencode, executable: executable, environment: environment, workingDirectory: directory,
            resumeSessionID: sessionID, selection: selection, accessMode: accessMode, interactionMode: interactionMode)
        let session = OpenCodeProvider().makeSession(launch)
        let recorder = EventRecorder()
        session.onEvent = { [weak recorder] event in recorder?.events.append(event) }
        let run = Run(session: session, recorder: recorder)
        runs.append(run)
        try await session.start()
        return run
    }

    func input(_ text: String, imagePaths: [String] = []) -> AgentTurnInput {
        AgentTurnInput(
            text: text, imagePaths: imagePaths, selection: selection, accessMode: accessMode,
            interactionMode: interactionMode)
    }

    func api() async throws -> OpenCodeAPI {
        let lease = try await OpenCodeServerPool.shared.borrow(executable: executable, environment: environment)
        defer { lease.release() }
        return lease.server.api
    }

    func serverPID() async throws -> Int32 {
        let lease = try await OpenCodeServerPool.shared.borrow(executable: executable, environment: environment)
        defer { lease.release() }
        return lease.server.pid
    }

    /// Shuts the sessions down, deletes them from OpenCode's history and stops the server.
    func finish() async {
        let ids = Set(runs.compactMap(\.session.sessionID))
        for run in runs { run.session.shutdown() }
        if let api = try? await api() {
            for id in ids { try? await api.deleteSession(id) }
        }
        OpenCodeServerPool.shared.shutdownAll()
        try? FileManager.default.removeItem(at: directory)
    }

}

@MainActor
private final class EventRecorder {
    var events: [AgentEvent] = []

    var assistantText: String { assistantText(after: 0) }

    var turnEnds: [TurnOutcome] {
        events.compactMap { event in
            if case .turnCompleted(let outcome) = event { return outcome }
            return nil
        }
    }

    func assistantText(after index: Int) -> String {
        var texts: [String: String] = [:]
        var order: [String] = []
        for event in events.dropFirst(index) {
            switch event {
            case .assistantTextDelta(let id, let delta):
                if texts[id] == nil { order.append(id) }
                texts[id, default: ""] += delta
            case .assistantText(let id, let text):
                if texts[id] == nil { order.append(id) }
                texts[id] = text
            default:
                break
            }
        }
        return order.compactMap { texts[$0] }.joined(separator: "\n")
    }

    func wait(after index: Int = 0, timeout: TimeInterval = 120, for match: (AgentEvent) -> Bool) async throws -> AgentEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = events.dropFirst(index).first(where: match) { return event }
            if let exit = events.dropFirst(index).first(where: { if case .sessionExited = $0 { true } else { false } }) {
                throw LiveTestError("The session ended: \(exit)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LiveTestError("Timed out after \(Int(timeout)) seconds. Events: \(events)")
    }

    func turnOutcome(after index: Int = 0, timeout: TimeInterval = 120) async throws -> TurnOutcome {
        let event = try await wait(after: index, timeout: timeout) { event in
            if case .turnCompleted = event { return true }
            return false
        }
        guard case .turnCompleted(let outcome) = event else { throw LiveTestError("No turn end") }
        return outcome
    }

    func approval(timeout: TimeInterval = 120) async throws -> ApprovalRequest {
        let event = try await wait(timeout: timeout) { event in
            if case .approvalRequested = event { return true }
            if case .turnCompleted = event { return true }
            return false
        }
        guard case .approvalRequested(let request) = event else {
            throw LiveTestError("The turn ended without asking for approval: \(events)")
        }
        return request
    }
}

private struct LiveTestError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
