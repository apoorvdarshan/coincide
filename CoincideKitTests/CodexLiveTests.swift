import Foundation
import Testing

@testable import CoincideKit

/// Runs the installed Codex CLI with the user's own sign-in, so every turn uses their subscription:
/// prompts are tiny and the cheapest model is used. Opt in with `COINCIDE_LIVE_TESTS=1`
/// (`TEST_RUNNER_COINCIDE_LIVE_TESTS=1` through xcodebuild). `COINCIDE_LIVE_DIR` sets the scratch folder.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_TESTS"] == "1"))
struct CodexLiveTests {
    private static let model = "gpt-6-luna"
    private static let effort = "low"

    @MainActor
    private final class Recorder {
        var events: [AgentEvent] = []
        var answersQuestions = false

        func completions(since start: Int) -> [TurnOutcome] {
            events[start...].compactMap { event -> TurnOutcome? in
                guard case .turnCompleted(let outcome) = event else { return nil }
                return outcome
            }
        }

        /// Assistant text of the events after `start`, streamed deltas replaced by final texts.
        func assistantText(since start: Int) -> String {
            var order: [String] = []
            var texts: [String: String] = [:]
            for event in events[start...] {
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
    }

    private struct TimedOut: Error {}

    private func waitUntil(_ timeout: Duration = .seconds(180), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func sessionIDs(_ recorder: Recorder) -> [String] {
        recorder.events.compactMap { event -> String? in
            guard case .sessionStarted(let id) = event else { return nil }
            return id
        }
    }

    private func workingDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["COINCIDE_LIVE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("coincide-live", isDirectory: true)
        let directory = base.appendingPathComponent("codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSession(
        in directory: URL, resume: String? = nil, access: AccessMode = .fullAccess, mode: InteractionMode = .build
    ) async throws -> (CodexSession, Recorder) {
        let found = await ShellEnvironment.shared.which("codex")
        let executable = try #require(found, "codex is not on PATH")
        let environment = await ShellEnvironment.shared.environment()
        let launch = AgentLaunch(
            provider: .codex, executable: executable, environment: environment,
            workingDirectory: directory, resumeSessionID: resume,
            selection: ModelSelection(provider: .codex, modelID: Self.model, effort: Self.effort), accessMode: access,
            interactionMode: mode)
        let session = CodexSession(launch: launch)
        let recorder = Recorder()
        session.onEvent = { [weak session] event in
            recorder.events.append(event)
            // Plan mode may ask questions; pick the first answer so the turn can finish.
            if recorder.answersQuestions, case .approvalRequested(let request) = event, let option = request.options.first {
                session?.respond(to: request.id, optionID: option.id)
            }
        }
        try await session.start()
        return (session, recorder)
    }

    private func input(_ text: String, access: AccessMode = .fullAccess, mode: InteractionMode = .build) -> AgentTurnInput {
        AgentTurnInput(
            text: text, selection: ModelSelection(provider: .codex, modelID: Self.model, effort: Self.effort),
            accessMode: access, interactionMode: mode)
    }

    /// Sends a turn and waits for its single completion.
    private func run(
        _ session: CodexSession, _ recorder: Recorder, _ input: AgentTurnInput
    ) async throws -> (TurnOutcome, String) {
        let start = recorder.events.count
        try await session.send(input)
        try await waitUntil { !recorder.completions(since: start).isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        let completions = recorder.completions(since: start)
        #expect(completions.count == 1)
        return (completions[0], recorder.assistantText(since: start))
    }

    @Test func detectsTheSignedInCLIAndItsModels() async throws {
        let provider = CodexProvider()
        let executable = await ShellEnvironment.shared.which("codex")
        let environment = await ShellEnvironment.shared.environment()
        let status = await provider.detect(executable: executable, environment: environment)
        #expect(status.state == .ready)
        #expect(status.version != nil)
        #expect(status.account != nil)
        let models = await provider.models(status: status, environment: environment)
        #expect(models.contains { $0.modelID == Self.model })
        #expect(models.allSatisfy { !$0.efforts.isEmpty && $0.provider == .codex })
    }

    @Test func turnsKeepContextAndResumeAfterRestart() async throws {
        let directory = try workingDirectory()
        let (first, recorder) = try await makeSession(in: directory)
        let threadID = try #require(first.sessionID)
        #expect(sessionIDs(recorder) == [threadID])

        let (outcome, reply) = try await run(first, recorder, input("Reply with exactly: pong"))
        #expect(outcome == .completed)
        #expect(reply.lowercased().contains("pong"))
        #expect(recorder.events.contains { if case .usage(let usage) = $0 { usage.contextWindow != nil } else { false } })

        let (secondOutcome, secondReply) = try await run(
            first, recorder, input("What single word did you just reply with? Reply with only that word."))
        #expect(secondOutcome == .completed)
        #expect(secondReply.lowercased().contains("pong"))
        first.shutdown()

        let (resumed, resumedRecorder) = try await makeSession(in: directory, resume: threadID)
        #expect(resumed.sessionID == threadID)
        // Resuming reports the same thread (and may report its last usage first).
        #expect(sessionIDs(resumedRecorder) == [threadID])
        let (thirdOutcome, thirdReply) = try await run(
            resumed, resumedRecorder,
            input("What word did you reply with at the start of this conversation? Reply with only that word."))
        #expect(thirdOutcome == .completed)
        #expect(thirdReply.lowercased().contains("pong"))
        resumed.shutdown()
    }

    @Test func approvalRoundTrip() async throws {
        let directory = try workingDirectory()
        let (session, recorder) = try await makeSession(in: directory, access: .approval)
        defer { session.shutdown() }
        let start = recorder.events.count
        try await session.send(input("Run this shell command and nothing else: echo coincide-ok", access: .approval))
        var approval: ApprovalRequest?
        try await waitUntil {
            approval = recorder.events[start...].lazy.compactMap { event -> ApprovalRequest? in
                guard case .approvalRequested(let request) = event else { return nil }
                return request
            }.first
            return approval != nil || !recorder.completions(since: start).isEmpty
        }
        let request = try #require(approval, "Codex finished without asking for approval")
        #expect(request.category == .command)
        #expect(request.title.contains("coincide-ok"))
        let allow = try #require(request.options.first { $0.kind == .allowOnce })
        session.respond(to: request.id, optionID: allow.id)
        try await waitUntil { !recorder.completions(since: start).isEmpty }
        #expect(recorder.completions(since: start) == [.completed])
        let output = recorder.events[start...].compactMap { event -> String? in
            switch event {
            case .toolOutput(_, let delta): delta
            case .toolCompleted(_, _, let output): output
            default: nil
            }
        }.joined()
        #expect(output.contains("coincide-ok"))
    }

    @Test func planModeProducesAPlan() async throws {
        let directory = try workingDirectory()
        let (session, recorder) = try await makeSession(in: directory, mode: .plan)
        defer { session.shutdown() }
        recorder.answersQuestions = true
        let start = recorder.events.count
        let prompt = """
            Plan how to add a one-line README.md to this empty folder. \
            Do not ask me any questions; keep the plan to two short steps.
            """
        let (outcome, _) = try await run(session, recorder, input(prompt, mode: .plan))
        #expect(outcome == .completed)
        let plan = recorder.events[start...].compactMap { event -> String? in
            guard case .plan(let text) = event else { return nil }
            return text
        }.last
        #expect(plan?.isEmpty == false)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true)
    }

    @Test func interruptEndsTheTurnOnce() async throws {
        let directory = try workingDirectory()
        let (session, recorder) = try await makeSession(in: directory)
        defer { session.shutdown() }
        let start = recorder.events.count
        try await session.send(input("Write the numbers from 1 to 400 separated by spaces. Do not use any tools."))
        try await waitUntil {
            recorder.events[start...].contains { if case .assistantTextDelta = $0 { true } else { false } }
                || !recorder.completions(since: start).isEmpty
        }
        session.interrupt()
        try await waitUntil(.seconds(30)) { !recorder.completions(since: start).isEmpty }
        try await Task.sleep(for: .seconds(1))
        #expect(recorder.completions(since: start) == [.interrupted])
    }
}
