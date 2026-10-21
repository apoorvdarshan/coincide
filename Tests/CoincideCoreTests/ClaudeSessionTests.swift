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
    var restored = try JSONDecoder().decode(CodingThread.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored.provider == .codex); #expect(restored.draft.isEmpty)
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
