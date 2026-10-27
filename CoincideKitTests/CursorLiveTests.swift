import Foundation
import Testing

@testable import CoincideKit

/// Runs the real `cursor-agent` with the signed-in account. Opt in with `COINCIDE_LIVE_TESTS=1`
/// (for xcodebuild, `TEST_RUNNER_COINCIDE_LIVE_TESTS=1`). Each test works in a fresh folder under
/// `COINCIDE_LIVE_DIR` (or the temporary directory) and uses tiny prompts. Only the model test picks a
/// model; it checks that the user's Cursor default stays as it was.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_TESTS"] == "1"))
struct CursorLiveTests {
    @Test func conversationKeepsContextAndResumes() async throws {
        let directory = try Self.directory("conversation")
        let first = try await LiveCursorSession(directory: directory)
        let sessionID = try #require(first.session.sessionID)

        let pong = try await first.turn("Reply with exactly: pong")
        #expect(pong.outcome == .completed)
        #expect(pong.reply.lowercased().contains("pong"))

        let recall = try await first.turn("Which single word did you just reply with? Reply with only that word.")
        #expect(recall.outcome == .completed)
        #expect(recall.reply.lowercased().contains("pong"))
        first.session.shutdown()

        let resumed = try await LiveCursorSession(directory: directory, resume: sessionID)
        #expect(resumed.session.sessionID == sessionID)
        #expect(!resumed.events.contains { if case .notice = $0 { true } else { false } })
        let again = try await resumed.turn("Which single word did you reply with first in this chat? Reply with only that word.")
        #expect(again.outcome == .completed)
        #expect(again.reply.lowercased().contains("pong"))
        resumed.session.shutdown()
    }

    @Test func approvalRoundTrip() async throws {
        let live = try await LiveCursorSession(directory: try Self.directory("approval"), accessMode: .approval)
        var approvals = 0
        let result = try await live.turn(
            "Run this shell command: echo coincide-ok\nThen reply with exactly: done", accessMode: .approval
        ) { event, session in
            guard case .approvalRequested(let request) = event,
                let allow = request.options.first(where: { $0.kind == .allowOnce })
            else { return }
            approvals += 1
            session.respond(to: request.id, optionID: allow.id)
        }
        #expect(approvals >= 1)
        #expect(result.outcome == .completed)
        #expect(result.events.contains { event in
            if case .toolCompleted(_, .completed, let output) = event { return output?.contains("coincide-ok") == true }
            return false
        })
        live.session.shutdown()
    }

    @Test func planModeProposesAPlan() async throws {
        let directory = try Self.directory("plan")
        let live = try await LiveCursorSession(directory: directory)
        let result = try await live.turn(
            "Make a plan with at most two steps for adding a NOTES.md file. Do not implement it.", mode: .plan)
        #expect(result.outcome == .completed)
        #expect(result.events.contains { if case .plan(let text) = $0 { !text.isEmpty } else { false } })
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("NOTES.md").path))
        live.session.shutdown()
    }

    @Test func interruptEndsTheTurnOnce() async throws {
        let live = try await LiveCursorSession(directory: try Self.directory("interrupt"))
        var interrupted = false
        let started = Date()
        let result = try await live.turn("Count from 1 to 400, one number per line.") { event, session in
            let streaming: Bool =
                switch event {
                case .assistantTextDelta, .reasoningDelta, .toolStarted: true
                default: false
                }
            if !interrupted, streaming || Date().timeIntervalSince(started) > 4 {
                interrupted = true
                session.interrupt()
            }
        }
        #expect(interrupted)
        #expect(result.outcome == .interrupted)
        try await Task.sleep(for: .seconds(2))
        #expect(live.completions == [.interrupted])
        live.session.shutdown()
    }

    @Test func choosingAModelLeavesTheCursorDefaultAlone() async throws {
        let environment = await ShellEnvironment.shared.environment()
        let configFile = CursorModelSettings.configFileURL(environment: environment)
        let before = try Self.modelSettings(in: configFile)
        let userModel = CursorModelSettings.modelID(in: before)

        // Any model of the account other than the one the user's Cursor CLI is set to.
        let provider = CursorProvider()
        let executable = try #require(await ShellEnvironment.shared.which("cursor-agent"))
        let status = await provider.detect(executable: executable, environment: environment)
        let models = await provider.models(status: status, environment: environment)
        let other = try #require(
            models.first { $0.modelID != CursorModels.defaultModelID && $0.modelID != userModel }?.modelID)

        let live = try await LiveCursorSession(directory: try Self.directory("model"))
        let result = try await live.turn("Reply with exactly: ok", modelID: other)
        #expect(result.outcome == .completed)
        #expect(result.events.contains(.modelResolved(other)))
        live.session.shutdown()

        let after = try Self.modelSettings(in: configFile)
        #expect(NSDictionary(dictionary: after).isEqual(to: before))
        #expect(CursorModelSettings.modelID(in: after) == userModel)
    }

    /// The model keys of Cursor's settings file.
    private static func modelSettings(in file: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: file)) as? [String: Any] ?? [:]
        return object.filter { CursorModelSettings.keys.contains($0.key) }
    }

    private static func directory(_ name: String) throws -> URL {
        let base = ProcessInfo.processInfo.environment["COINCIDE_LIVE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A started `CursorSession` that records its events.
@MainActor
final class LiveCursorSession {
    struct TurnResult {
        var outcome: TurnOutcome
        var events: [AgentEvent]

        /// The final text of every assistant item of the turn.
        var reply: String {
            events.compactMap { if case .assistantText(_, let text) = $0 { text } else { nil } }.joined(separator: "\n")
        }
    }

    let session: CursorSession
    private(set) var events: [AgentEvent] = []
    private var observer: ((AgentEvent, CursorSession) -> Void)?

    var completions: [TurnOutcome] {
        events.compactMap { if case .turnCompleted(let outcome) = $0 { outcome } else { nil } }
    }

    init(directory: URL, accessMode: AccessMode = .fullAccess, resume: String? = nil) async throws {
        let executable = try #require(await ShellEnvironment.shared.which("cursor-agent"))
        let launch = AgentLaunch(
            provider: .cursor, executable: executable, environment: await ShellEnvironment.shared.environment(),
            workingDirectory: directory, resumeSessionID: resume,
            selection: ModelSelection(provider: .cursor, modelID: CursorModels.defaultModelID), accessMode: accessMode,
            interactionMode: .build)
        session = CursorSession(launch: launch)
        session.onEvent = { [weak self] event in
            guard let self else { return }
            self.events.append(event)
            self.observer?(event, self.session)
        }
        try await session.start()
    }

    /// Sends one message and waits for its `.turnCompleted`, calling `observe` for each event on the way.
    func turn(
        _ text: String, modelID: String = CursorModels.defaultModelID, accessMode: AccessMode = .fullAccess,
        mode: InteractionMode = .build, timeout: Duration = .seconds(180),
        observe: ((AgentEvent, CursorSession) -> Void)? = nil
    ) async throws -> TurnResult {
        let start = events.count
        observer = observe
        defer { observer = nil }
        try await session.send(
            AgentTurnInput(
                text: text, selection: ModelSelection(provider: .cursor, modelID: modelID), accessMode: accessMode,
                interactionMode: mode))
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let turnEvents = Array(events[start...])
            if let outcome = turnEvents.lazy.compactMap({ if case .turnCompleted(let outcome) = $0 { outcome } else { nil } }).first {
                return TurnResult(outcome: outcome, events: turnEvents)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        session.interrupt()
        throw AgentError.timeout("the Cursor turn")
    }
}
