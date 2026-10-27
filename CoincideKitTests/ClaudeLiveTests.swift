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

    private func input(
        _ text: String, access: AccessMode = .approval, interaction: InteractionMode = .build, title: String? = nil
    ) -> AgentTurnInput {
        AgentTurnInput(
            message: text, handoffRecap: nil, newSessionRecap: nil, threadTitle: title, selection: Self.selection,
            accessMode: access, interactionMode: interaction)
    }

    /// Sends a message and waits for its turn to end.
    private func run(
        _ session: ClaudeSession, _ text: String, access: AccessMode = .approval, interaction: InteractionMode = .build,
        title: String? = nil, recorder: LiveRecorder
    ) async throws -> (outcome: TurnOutcome, reply: String) {
        let start = recorder.events.count
        try await session.send(input(text, access: access, interaction: interaction, title: title))
        let outcome = try await recorder.completion(after: start)
        return (outcome, recorder.reply(after: start))
    }

    /// Whether Claude Code saved `title` as the conversation's name, in whichever project folder holds its transcript.
    private static func isNamed(_ sessionID: String, _ title: String) async throws -> Bool {
        let root =
            environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let entry = #""customTitle":"\#(title)""#
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            for folder in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                let transcript = try? String(contentsOf: folder.appendingPathComponent("\(sessionID).jsonl"), encoding: .utf8)
                if transcript?.contains(entry) == true { return true }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return false
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

        let first = try await run(session, "Reply with exactly: pong", title: "Coincide live test", recorder: recorder)
        #expect(first.outcome == .completed)
        #expect(first.reply.lowercased().contains("pong"))
        #expect(recorder.events.contains { if case .usage(let usage) = $0 { (usage.inputTokens ?? 0) > 0 } else { false } })
        // The new conversation carries the thread's name in Claude Code's own session list.
        #expect(try await Self.isNamed(id, "Coincide live test"))

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

    @Test func theCheckReadsThePlansUsageLimits() async throws {
        let status = await ClaudeProvider().detect(executable: try Self.executable(), environment: Self.environment)
        try #require(status.state == .ready)
        // Only a subscription has plan limits; an API key reports none.
        guard let limits = status.usageLimits else { return }
        #expect(limits.windows.contains { $0.id == "five_hour" && $0.kind == .session })
        #expect(limits.windows.contains { $0.id == "seven_day" && $0.kind == .weekly })
        #expect(limits.windows.allSatisfy { (0...100).contains($0.usedPercent) })
    }

    /// Steers a turn while Claude streams: Claude stops that reply, takes the steer in and answers it, all in one turn.
    @Test func steeringWhileStreamingRedirectsTheTurn() async throws {
        let recorder = LiveRecorder()
        let session = try makeSession(recorder: recorder)
        defer { session.shutdown() }
        try await session.start()
        let start = recorder.events.count
        try await session.send(input("Write the numbers from 1 to 300 as English words, one per line. Do not use any tools."))
        try await recorder.wait { events in
            events[start...].contains { if case .assistantTextDelta = $0 { true } else { false } }
                || events[start...].contains { if case .turnCompleted = $0 { true } else { false } }
        }
        try #require(recorder.completions(after: start).isEmpty, "the turn ended before it could be steered")
        try await session.steer(input("Stop counting now. Reply with exactly: steered"))
        let outcome = try await recorder.completion(after: start)
        try await Task.sleep(for: .seconds(1))
        #expect(outcome == .completed)
        #expect(recorder.completions(after: start) == [.completed])
        #expect(recorder.reply(after: start).lowercased().hasSuffix("steered"))
        #expect(!recorder.events[start...].contains { if case .agentTurnStarted = $0 { true } else { false } })
        // A subscription reports its limits with the turn.
        #expect(recorder.events.contains { if case .rateLimits(let windows) = $0 { !windows.isEmpty } else { false } })
    }

    /// Steers a turn while a command runs: Claude moves the command aside and answers the steer in the same turn.
    @Test func steeringWhileACommandRunsRedirectsTheTurn() async throws {
        let recorder = LiveRecorder()
        let session = try makeSession(recorder: recorder)
        defer { session.shutdown() }
        try await session.start()
        let start = recorder.events.count
        try await session.send(
            input("Run the shell command `sleep 8; echo done`, then reply with exactly: first", access: .fullAccess))
        try await recorder.wait { events in
            events[start...].contains { if case .toolStarted(let info) = $0 { info.category == .command } else { false } }
                || events[start...].contains { if case .turnCompleted = $0 { true } else { false } }
        }
        try #require(recorder.completions(after: start).isEmpty, "the turn ended before it could be steered")
        try await session.steer(input("Never mind the command. Reply with exactly: steered", access: .fullAccess))
        let outcome = try await recorder.completion(after: start)
        #expect(outcome == .completed)
        #expect(recorder.reply(after: start).lowercased().contains("steered"))
        // The command Claude moved aside may finish afterwards and start a turn of Claude's own; that one is separate.
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
