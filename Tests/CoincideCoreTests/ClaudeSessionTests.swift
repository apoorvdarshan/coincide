import Foundation
import Testing
@testable import CoincideCore

private func claudeFixture(_ scenario: String) throws -> ClaudeSession {
    let fixture = Bundle.module.url(forResource: "claude_server", withExtension: "py", subdirectory: "Fixtures")!
    return try ClaudeSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: FileManager.default.temporaryDirectory,
                             arguments: [fixture.path, scenario])
}

private func fixtureThread() -> CodingThread {
    var thread = CodingThread(project: WorkspaceProject(path: FileManager.default.temporaryDirectory.path))
    thread.provider = .claude; thread.model = "fixture-model"
    return thread
}

@Test(.timeLimit(.minutes(1)))
func claudeKeepsRootIdentityAcrossChildEventsAndRepeatedTurns() async throws {
    let session = try claudeFixture("identity")
    let observer = Task {
        var identities: [String] = [], replies: [String] = [], completed = 0
        for await event in session.events {
            switch event {
            case .thread(let id): identities.append(id)
            case .message(let message) where message.role == .assistant: replies.append(message.text)
            case .completed:
                completed += 1
                if completed == 1 { try await session.send(text: "Second explicit input", thread: fixtureThread()) }
                else { return (identities, replies) }
            case .failure(let error): throw CoincideError(error)
            default: break
            }
        }
        throw CoincideError("The root identity peer ended without two root completions.")
    }
    do {
        try await session.send(text: "First explicit input", thread: fixtureThread())
        let (identities, replies) = try await observer.value
        #expect(!identities.isEmpty)
        #expect(Set(identities) == ["claude-session"])
        #expect(replies == ["Hello Claude", "Hello Claude"])
        var retargeted = fixtureThread(); retargeted.providerThreadID = "different-session"
        await #expect(throws: CoincideError.self) { try await session.send(text: "Must not be sent", thread: retargeted) }
        async let firstClose: Void = session.close()
        async let secondClose: Void = session.close()
        _ = await (firstClose, secondClose)
        await #expect(throws: CoincideError.self) { _ = try await session.models() }
        await #expect(throws: CoincideError.self) { try await session.send(text: "Must not restart", thread: fixtureThread()) }
    } catch {
        await session.close(); observer.cancel(); _ = try? await observer.value; throw error
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func claudeConcurrentStartupHasOneOrderedReaderAndCloseJoinsInitialization(closeDuringInitialization: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-startup-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try #require(Bundle.module.url(forResource: "claude_server", withExtension: "py", subdirectory: "Fixtures"))
    let session = try ClaudeSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root,
        arguments: [fixture.path, "held-initialize", root.path])
    let first = Task { try await session.models() }
    let second = Task { try await session.models() }
    let deadline = ContinuousClock.now + .seconds(8)
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) {
        if ContinuousClock.now >= deadline {
            await session.close(); Issue.record("The owned startup peer did not reach initialization."); return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    if closeDuringInitialization {
        async let firstClose: Void = session.close()
        async let secondClose: Void = session.close()
        _ = await (firstClose, secondClose)
        await #expect(throws: (any Error).self) { _ = try await first.value }
        await #expect(throws: (any Error).self) { _ = try await second.value }
    } else {
        try Data().write(to: root.appendingPathComponent("release"))
        do {
            #expect(try await first.value == [ProviderModel(id: "fixture-model", name: "Fixture Model")])
            #expect(try await second.value == [ProviderModel(id: "fixture-model", name: "Fixture Model")])
        } catch { await session.close(); throw error }
        await session.close()
    }
    let frames = try Data(contentsOf: root.appendingPathComponent("wire.jsonl")).split(separator: 10).map {
        try JSONDecoder().decode(JSONValue.self, from: Data($0))
    }
    #expect(frames.filter { $0["request"]["subtype"] == .string("initialize") }.count == 1)
    await #expect(throws: CoincideError.self) { _ = try await session.models() }
}

@Test(.timeLimit(.minutes(1)))
func claudeApprovalsStreamingAndRepeatedTurns() async throws {
    let session = try claudeFixture("approve")
    #expect(try await session.models() == [ProviderModel(id: "fixture-model", name: "Fixture Model")])
    let observer = Task {
        var completed = 0, streamed = "", finalMessages: [String: String] = [:]
        for await event in session.events {
            switch event {
            case .approval(let request): try await session.respond(request, allow: true)
            case .delta(_, _, let text): streamed += text
            case .message(let message): finalMessages[message.id] = message.text
            case .completed:
                completed += 1
                if completed == 1 { try await session.send(text: "Second turn", thread: fixtureThread()) }
                else { return (streamed, finalMessages) }
            case .failure(let error): throw CoincideError(error)
            default: break
            }
        }
        throw CoincideError("Stream ended before both turns completed.")
    }
    try await session.send(text: "First turn", thread: fixtureThread())
    let result = try await observer.value
    #expect(result.0 == "Hello ClaudeHello Claude")
    #expect(result.1 == ["message-1-0": "Hello Claude", "message-2-0": "Hello Claude"])
    await session.close()
}

@Test(.timeLimit(.minutes(1)))
func claudeDeclineAndQuestionsRoundTrip() async throws {
    for scenario in ["deny", "question"] {
        let session = try claudeFixture(scenario)
        let observer = Task {
            var finalText = ""
            for await event in session.events {
                switch event {
                case .approval(let request):
                    if request.isQuestion {
                        #expect(request.questions.first?["id"].string == "Which option?")
                        try await session.answer(request, answers: ["Which option?": "A"])
                    } else { try await session.respond(request, allow: false) }
                case .message(let message): finalText = message.text
                case .completed: return finalText
                case .failure(let error): throw CoincideError(error)
                default: break
                }
            }
            throw CoincideError("Claude fixture did not complete.")
        }
        try await session.send(text: "test", thread: fixtureThread())
        #expect(try await observer.value == (scenario == "deny" ? "Denied" : "Answer received"))
        await session.close()
    }
}

@Test(.timeLimit(.minutes(1)))
func claudeInterruptCancellationAndProviderFailure() async throws {
    for scenario in ["interrupt", "cancel", "error"] {
        let session = try claudeFixture(scenario)
        let observer = Task {
            var dismissed = false
            for await event in session.events {
                switch event {
                case .turn where scenario == "interrupt": try await session.interrupt()
                case .approvalDismissed: dismissed = true
                case .completed(let state):
                    #expect(state == (scenario == "interrupt" ? .interrupted : .idle))
                    #expect(scenario != "cancel" || dismissed)
                    return
                case .failure(let error):
                    #expect(scenario == "error"); #expect(error == "Fixture provider failed"); return
                default: break
                }
            }
            Issue.record("Claude stream ended without a terminal outcome.")
        }
        try await session.send(text: "test", thread: fixtureThread())
        try await observer.value
        await session.close()
    }
}

@Test func legacyCodexThreadsAndProviderDraftsDecode() throws {
    let thread = CodingThread(project: WorkspaceProject(path: "/tmp"))
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(thread)) as? [String: Any])
    json.removeValue(forKey: "provider"); json.removeValue(forKey: "draft")
    for key in ["queuedTurns", "queuePaused", "activeRun", "runtimeID", "runtimeRequests"] { json.removeValue(forKey: key) }
    var restored = try JSONDecoder().decode(CodingThread.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored.provider == .codex); #expect(restored.draft.isEmpty)
    #expect(restored.queuedTurns.isEmpty && !restored.queuePaused && restored.activeRun == nil && restored.runtimeID == nil && restored.runtimeRequests.isEmpty)
    restored.provider = .claude; restored.draft = "Unsent prompt"
    #expect(try JSONDecoder().decode(CodingThread.self, from: JSONEncoder().encode(restored)) == restored)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_CLAUDE"] == "1"), .timeLimit(.minutes(2)))
func installedClaudeHandshakeAndModelDiscovery() async throws {
    let executable = try #require(ProcessChannel.findExecutable("claude"))
    let session = try ClaudeSession(executable: executable, cwd: FileManager.default.temporaryDirectory)
    do {
        let models = try await session.models()
        #expect(!models.isEmpty)
        await session.close()
    } catch { await session.close(); throw error }
}
