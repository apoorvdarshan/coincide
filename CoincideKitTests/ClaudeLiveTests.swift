import Foundation
import Testing

@testable import CoincideKit

/// Real turns against the installed Claude Code, on the user's own subscription, with tiny prompts.
/// Opt in with `COINCIDE_LIVE_TESTS=1` (`TEST_RUNNER_COINCIDE_LIVE_TESTS=1` through xcodebuild);
/// `COINCIDE_LIVE_TEST_DIR` sets where the scratch folder is created.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_TESTS"] == "1"), .serialized, .timeLimit(.minutes(5)))
struct ClaudeLiveTests {
    private static let selection = ModelSelection(provider: .claude, modelID: "haiku", effort: "low")

    /// One fresh folder for the run, so Claude Code records a single project for it.
    private static let directory: URL = {
        let environment = ProcessInfo.processInfo.environment
        let parent = environment["COINCIDE_LIVE_TEST_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = parent.appendingPathComponent("claude-live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    private static func executable() throws -> URL {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for directory in path {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw AgentError.notInstalled(.claude)
    }

    private func makeSession(
        resume: String? = nil, interaction: InteractionMode = .build, recorder: LiveRecorder
    ) throws -> ClaudeSession {
        let launch = AgentLaunch(
            provider: .claude, executable: try Self.executable(), environment: Self.environment,
            workingDirectory: Self.directory, resumeSessionID: resume, selection: Self.selection, accessMode: .approval,
            interactionMode: interaction)
        let session = ClaudeSession(launch: launch)
        session.onEvent = { recorder.events.append($0) }
        return session
    }

    private func input(_ text: String, access: AccessMode = .approval, interaction: InteractionMode = .build) -> AgentTurnInput {
        AgentTurnInput(text: text, selection: Self.selection, accessMode: access, interactionMode: interaction)
    }

    /// Sends a message and waits for its turn to end.
    private func run(
        _ session: ClaudeSession, _ text: String, access: AccessMode = .approval, interaction: InteractionMode = .build,
        recorder: LiveRecorder
    ) async throws -> (outcome: TurnOutcome, reply: String) {
        let start = recorder.events.count
        try await session.send(input(text, access: access, interaction: interaction))
        let outcome = try await recorder.completion(after: start)
        return (outcome, recorder.reply(after: start))
    }

    @Test func detectsTheInstalledCLIAndItsModels() async throws {
        let provider = ClaudeProvider()
        let status = await provider.detect(executable: try Self.executable(), environment: Self.environment)
        #expect(status.state == .ready)
        #expect(status.version != nil)
        #expect(status.account != nil)
        let models = await provider.models(status: status, environment: Self.environment)
        #expect(models.first?.modelID == "default")
        #expect(models.contains { $0.modelID == "haiku" && $0.efforts.contains("low") })
    }

    @Test func turnsKeepContextAndResume() async throws {
        let recorder = LiveRecorder()
        let session = try makeSession(recorder: recorder)
        try await session.start()
        let id = try #require(session.sessionID)
        #expect(recorder.events.contains(.sessionStarted(id: id)))

        let first = try await run(session, "Reply with exactly: pong", recorder: recorder)
        #expect(first.outcome == .completed)
        #expect(first.reply.lowercased().contains("pong"))
        #expect(recorder.events.contains { if case .usage(let usage) = $0 { (usage.inputTokens ?? 0) > 0 } else { false } })

        let second = try await run(
            session, "What single word did you just reply with? Reply with only that word.", recorder: recorder)
        #expect(second.outcome == .completed)
        #expect(second.reply.lowercased().contains("pong"))
        session.shutdown()

        let resumedRecorder = LiveRecorder()
        let resumed = try makeSession(resume: id, recorder: resumedRecorder)
        defer { resumed.shutdown() }
        try await resumed.start()
        #expect(resumed.sessionID == id)
        let third = try await run(
            resumed, "What single word did you reply with first in this conversation? Reply with only that word.",
            recorder: resumedRecorder)
        #expect(third.outcome == .completed)
        #expect(third.reply.lowercased().contains("pong"))
    }

    @Test func approvalRoundTrip() async throws {
        let recorder = LiveRecorder()
        let session = try makeSession(recorder: recorder)
        defer { session.shutdown() }
        try await session.start()
        let target = Self.directory.appendingPathComponent("approval.txt")
        try? FileManager.default.removeItem(at: target)

        let start = recorder.events.count
        try await session.send(
            input("Use the Bash tool to run exactly this command, then reply with: done\necho coincide-ok > approval.txt"))
        let approval = try await recorder.approval(after: start)
        #expect(approval.category == .command)
        #expect(approval.detail?.contains("echo coincide-ok") == true)
        session.respond(to: approval.id, optionID: ClaudePermissions.allowID)

        #expect(try await recorder.completion(after: start) == .completed)
        let written = try String(contentsOf: target, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(written == "coincide-ok")
        #expect(recorder.events[start...].contains { if case .toolCompleted(_, .completed, _) = $0 { true } else { false } })
    }

    @Test func fullAccessRunsWithoutAskingAndApprovalAsksAgain() async throws {
        let recorder = LiveRecorder()
        let session = try makeSession(recorder: recorder)
        defer { session.shutdown() }
        try await session.start()
        let allowed = Self.directory.appendingPathComponent("full.txt")
        let denied = Self.directory.appendingPathComponent("denied.txt")
        try? FileManager.default.removeItem(at: allowed)
        try? FileManager.default.removeItem(at: denied)

        let start = recorder.events.count
        let full = try await run(
            session, "Use the Bash tool to run exactly this command, then reply with: done\necho coincide-full > full.txt",
            access: .fullAccess, recorder: recorder)
        #expect(full.outcome == .completed)
        #expect(!recorder.events[start...].contains { if case .approvalRequested = $0 { true } else { false } })
        #expect((try? String(contentsOf: allowed, encoding: .utf8))?.contains("coincide-full") == true)

        // Back in approval mode the restarted process asks again; denying leaves the file unwritten.
        let next = recorder.events.count
        try await session.send(
            input("Use the Bash tool to run exactly this command, then reply with: done\necho coincide-denied > denied.txt"))
        let approval = try await recorder.approval(after: next)
        #expect(approval.detail?.contains("coincide-denied") == true)
        session.respond(to: approval.id, optionID: ClaudePermissions.denyID, text: "Don't run it. Just reply with: skipped")
        // Should Claude try again anyway, every later ask is denied too.
        var answered: Set<String> = [approval.id]
        try await recorder.wait { events in
            for case .approvalRequested(let request) in events[next...] where !answered.contains(request.id) {
                answered.insert(request.id)
                session.respond(to: request.id, optionID: ClaudePermissions.denyID)
            }
            return !recorder.completions(after: next).isEmpty
        }
        #expect(recorder.completions(after: next) == [.completed])
        #expect(answered.count == 1, "Claude asked again after the user's note")
        #expect(!FileManager.default.fileExists(atPath: denied.path))
    }

    @Test func planModePlansWithoutActing() async throws {
        let recorder = LiveRecorder()
        let session = try makeSession(interaction: .plan, recorder: recorder)
        defer { session.shutdown() }
        try await session.start()
        let result = try await run(
            session,
            "Plan how to add a file hello.txt containing hi to this folder. Two short steps; present the plan right away without exploring.",
            interaction: .plan, recorder: recorder)
        #expect(result.outcome == .completed)
        #expect(recorder.events.contains { if case .plan(let text) = $0 { text.contains("hello.txt") } else { false } })
        #expect(!FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent("hello.txt").path))
    }

    @Test func interruptEndsTheTurnOnce() async throws {
        let recorder = LiveRecorder()
        let session = try makeSession(recorder: recorder)
        defer { session.shutdown() }
        try await session.start()

        let start = recorder.events.count
        try await session.send(input("Count from 1 to 300, one number per line, with no other text."))
        try await recorder.wait {
            $0[start...].contains { event in
                switch event {
                case .assistantTextDelta, .reasoningDelta: true
                default: false
                }
            }
        }
        session.interrupt()
        #expect(try await recorder.completion(after: start) == .interrupted)
        try await Task.sleep(for: .seconds(2))
        #expect(recorder.completions(after: start).count == 1)

        let next = try await run(session, "Reply with exactly: pong", recorder: recorder)
        #expect(next.outcome == .completed)
    }

    @Test func compactingShowsAToolItem() async throws {
        let recorder = LiveRecorder()
        let session = try makeSession(recorder: recorder)
        defer { session.shutdown() }
        try await session.start()
        /// How the compaction items since `start` ended.
        func compactions(after start: Int) -> [ItemStatus] {
            let started = Set(
                recorder.events[start...].compactMap { event -> String? in
                    guard case .toolStarted(let info) = event, info.title == "Compact the conversation" else { return nil }
                    return info.id
                })
            return recorder.events[start...].compactMap { event in
                guard case .toolCompleted(let id, let status, _) = event, started.contains(id) else { return nil }
                return status
            }
        }

        // A conversation with nothing in it has nothing to compact; the item says so, and no reply repeats it.
        var start = recorder.events.count
        let refused = try await run(session, "/compact", recorder: recorder)
        #expect(refused.outcome == .completed)
        #expect(compactions(after: start) == [.failed])
        #expect(refused.reply.isEmpty)

        _ = try await run(session, "Reply with exactly: pong", recorder: recorder)
        start = recorder.events.count
        let compacted = try await run(session, "/compact", recorder: recorder)
        #expect(compacted.outcome == .completed)
        #expect(compactions(after: start) == [.completed])
        #expect(compacted.reply.isEmpty)
        // The context meter drops to what the summary takes.
        #expect(recorder.events[start...].contains { if case .usage(let usage) = $0 { (usage.inputTokens ?? 0) > 0 } else { false } })
    }

    @Test func aLostConversationStartsFreshAndSaysSo() async throws {
        let recorder = LiveRecorder()
        let lost = UUID().uuidString.lowercased()
        let session = try makeSession(resume: lost, recorder: recorder)
        defer { session.shutdown() }
        try await session.start()
        let id = try #require(session.sessionID)
        #expect(id != lost)
        #expect(recorder.events.contains(.sessionStarted(id: id)))
        #expect(recorder.events.contains { if case .notice = $0 { true } else { false } })
    }
}

@MainActor
private final class LiveRecorder {
    var events: [AgentEvent] = []

    func completions(after start: Int) -> [TurnOutcome] {
        events[start...].compactMap { event in
            if case .turnCompleted(let outcome) = event { return outcome }
            return nil
        }
    }

    /// The assistant's final text since `start`, item by item.
    func reply(after start: Int) -> String {
        var order: [String] = []
        var texts: [String: String] = [:]
        for event in events[start...] {
            guard case .assistantText(let id, let text) = event else { continue }
            if texts[id] == nil { order.append(id) }
            texts[id] = text
        }
        return order.compactMap { texts[$0] }.joined(separator: "\n")
    }

    func wait(timeout: Duration = .seconds(180), until condition: ([AgentEvent]) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(events) {
            guard ContinuousClock.now < deadline else {
                // The tail of what happened, to see where the turn stalled.
                for event in events.suffix(40) { print("live event:", String(describing: event).prefix(300)) }
                throw AgentError.timeout("Claude Code")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func completion(after start: Int) async throws -> TurnOutcome {
        try await wait { _ in !self.completions(after: start).isEmpty }
        return completions(after: start)[0]
    }

    func approval(after start: Int) async throws -> ApprovalRequest {
        var found: ApprovalRequest?
        try await wait { events in
            for event in events[start...] {
                if case .approvalRequested(let request) = event {
                    found = request
                    return true
                }
                if case .turnCompleted = event { return true }
            }
            return false
        }
        return try #require(found)
    }
}
