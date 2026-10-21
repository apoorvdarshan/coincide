import Foundation
import Testing
@testable import CoincideCore

private func acpFixture(_ mode: String = "normal") throws -> ACPSession {
    let fixture = try #require(Bundle.module.url(forResource: "acp_server", withExtension: "py", subdirectory: "Fixtures"))
    return try ACPSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture.path, mode], cwd: FileManager.default.temporaryDirectory, cancellationTimeout: .milliseconds(100))
}
private func unwrapACP(_ event: ProviderEvent) -> ProviderEvent {
    if case .context(_, let event) = event { return event }; return event
}

@Test(.timeLimit(.minutes(1))) func concurrentACPDiscoveryCreatesOnlyOneSession() async throws {
    let session = try acpFixture()
    do {
        async let first = session.models()
        async let second = session.models()
        let values = try await [first, second]
        #expect(values.count == 2 && values[0] == values[1] && !values[0].isEmpty)
        await session.close()
    } catch { await session.close(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["normal", "resume", "config"])
func acpStreamsModelsModesPermissionsImagesAndResumesWithoutReplayingHistory(_ mode: String) async throws {
    let resume = mode == "resume", session = try acpFixture(mode)
    do {
        if !resume { #expect(try await session.models().map(\.id) == ["default", "fixture"]) }
        let observer = Task {
            var text = "", thought = "", tool = "", permissions = 0, plan = false
            for await scoped in session.events {
                switch unwrapACP(scoped) {
                case .delta(_, let role, let value): if role == .assistant { text += value } else if role == .reasoning { thought += value }
                case .message(let message):
                    if message.id.hasSuffix("tool-tool-1") { tool = message.text }
                    if message.id.hasSuffix("plan") { plan = message.text.contains("Read fixture") }
                case .approval(let request):
                    #expect(request.id == .string("opaque-17")); permissions += 1
                    await #expect(throws: (any Error).self) { try await session.choose(request, optionID: "invented") }
                    try await session.choose(request, optionID: "opaque-once")
                case .completed(let state): #expect(state == .idle); return (text, thought, tool, permissions, plan)
                case .failure(let reason), .connectionClosed(let reason): throw CoincideError(reason)
                default: break
                }
            }
            throw CoincideError("ACP fixture closed before completion")
        }
        var thread = CodingThread(project: WorkspaceProject(path: FileManager.default.temporaryDirectory.path))
        thread.model = "fixture"; thread.agentModeID = "read"
        if resume { thread.providerThreadID = "fixture-session" }
        try await session.send(input: .init(text: "images", images: [.init(mimeType: "image/png", data: Data("image".utf8))]), thread: thread)
        let result = try await observer.value
        #expect(result.0 == "hello 🌍" && result.1 == "Thinking")
        #expect(result.2 == "Read Fixture · completed\nFixture tool result")
        #expect(result.3 == 1 && result.4)
        await session.close()
    } catch { await session.close(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["normal", "ignorecancel"]) func acpPromptDispatchDoesNotWaitForCompletionAndCancelEndsTheTurn(_ mode: String) async throws {
    let session = try acpFixture(mode)
    do {
        let observer = Task {
            for await scoped in session.events {
                switch unwrapACP(scoped) {
                case .completed(let state):
                    #expect(state == .interrupted)
                    if mode != "ignorecancel" { return state }
                case .connectionClosed: if mode == "ignorecancel" { return .interrupted }; throw CoincideError("Unexpected disconnect")
                case .failure(let reason): throw CoincideError(reason)
                default: break
                }
            }; throw CoincideError("ACP fixture closed before cancellation")
        }
        let thread = CodingThread(project: WorkspaceProject(path: FileManager.default.temporaryDirectory.path))
        // The fixture will never complete this prompt until interrupted. Waiting
        // for send to return before cancelling catches an incorrectly held start.
        try await session.send(text: "hang", thread: thread)
        try await session.interrupt()
        #expect(try await observer.value == .interrupted)
        await session.close()
    } catch { await session.close(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["unsupported", "auth", "noimage", "noresume"])
func acpRejectsUnsupportedCapabilitiesAndNeverSilentlyStartsANewSession(_ mode: String) async throws {
    let session = try acpFixture(mode)
    var thread = CodingThread(project: WorkspaceProject(path: FileManager.default.temporaryDirectory.path))
    if mode == "noresume" { thread.providerThreadID = "fixture-session" }
    let images: [ProviderImage] = mode == "noimage" ? [.init(mimeType: "image/png", data: Data("image".utf8))] : []
    await #expect(throws: (any Error).self) { try await session.send(input: .init(text: "images", images: images), thread: thread) }
    await session.close()
}

@Test(.timeLimit(.minutes(1))) func acpInstancesAndCapturedInvocationSurviveJournalRebuildAndRemoval() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    let project = WorkspaceProject(path: root.path)
    let agent = ACPAgentConfiguration(name: "Fixture ACP", executable: "/path with spaces/agent", arguments: ["acp", "literal $(echo unsafe)"])
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]
    var thread = CodingThread(project: project); thread.provider = .acp; thread.acpAgent = agent
    snapshot.threads = [thread]; snapshot.acpAgents = [agent]
    _ = try await database.commit(snapshot, event: "fixture", commandID: UUID())
    snapshot.acpAgents = []
    _ = try await database.commit(snapshot, event: "removed", commandID: UUID())
    let restored = try await database.rebuildProjection().snapshot
    #expect(restored == snapshot && restored.threads[0].acpAgent == agent)
    let captured = ProviderConfiguration(thread: restored.threads[0])
    #expect(captured.acpAgent?.arguments == ["acp", "literal $(echo unsafe)"])
    var invalid = agent; invalid.arguments = ["bad\0argument"]
    #expect(throws: (any Error).self) { try invalid.validate() }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_ACP"] == "1"), .timeLimit(.minutes(2)))
func installedOpenCodeACPHandshakeAndModelDiscovery() async throws {
    let executable = try #require(ProcessChannel.findExecutable("opencode"))
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let session = try ACPSession(executable: executable, arguments: ["acp"], cwd: root)
    do {
        let result = try await session.connect()
        #expect(result["protocolVersion"] == .number(1))
        let models = try await session.models(); #expect(!models.isEmpty)
        await session.close()
    } catch { await session.close(); throw error }
}

private func waitACP(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("ACP runtime fixture timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1))) func nativeACPEngineSettlesStartsWhilePermissionsWaitAndResumesItsSavedSession() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite")
    let fixture = try #require(Bundle.module.url(forResource: "acp_server", withExtension: "py", subdirectory: "Fixtures"))
    let agent = ACPAgentConfiguration(name: "Fixture", executable: "/usr/bin/python3", arguments: [fixture.path, "config"])
    let engine = try WorkspaceEngine(url: url), project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project); thread.provider = .acp; thread.acpAgent = agent; thread.model = "fixture"
    do {
        _ = try await engine.load(); try await engine.dispatch(.addProject(project)); try await engine.dispatch(.saveACPAgent(agent)); try await engine.dispatch(.createThread(thread))
        let first = UUID()
        try await engine.dispatch(.submit(threadID: thread.id, text: "first"), id: first)
        try await waitACP { await engine.current().snapshot.threads[0].runtimeRequests.count == 1 }
        let database = try WorkspaceDatabase(url: url)
        try await waitACP { try await database.effects(commandID: first).first?.status == .succeeded }
        #expect(await engine.current().snapshot.threads[0].state == .awaitingApproval)
        try await engine.dispatch(.submit(threadID: thread.id, text: "second"))
        try await engine.dispatch(.respond(threadID: thread.id, requestID: .string("opaque-17"), response: .option("opaque-once")))
        try await waitACP {
            let current = await engine.current().snapshot.threads[0]
            return current.messages.filter({ $0.role == .user }).count == 2 && current.runtimeRequests.count == 1
        }
        try await engine.dispatch(.respond(threadID: thread.id, requestID: .string("opaque-17"), response: .decision(false)))
        try await waitACP { await engine.current().snapshot.threads[0].state == .idle }
        #expect(await engine.current().snapshot.threads[0].messages.filter({ $0.role == .assistant }).count == 4)
        await engine.shutdown()
        let reopened = try WorkspaceEngine(url: url)
        do {
            let restored = try await reopened.load()
            #expect(restored.acpAgents == [agent] && restored.threads[0].providerThreadID == "fixture-session")
            try await reopened.dispatch(.submit(threadID: thread.id, text: "third"))
            try await waitACP { await reopened.current().snapshot.threads[0].runtimeRequests.count == 1 }
            try await reopened.dispatch(.respond(threadID: thread.id, requestID: .string("opaque-17"), response: .option("opaque-once")))
            try await waitACP { await reopened.current().snapshot.threads[0].state == .idle }
            let completed = await reopened.current().snapshot.threads[0]
            #expect(completed.messages.filter({ $0.role == .user }).count == 3)
            #expect(completed.messages.filter({ $0.role == .assistant }).count == 6)
            #expect(completed.messages.allSatisfy { !$0.text.contains("OLD HISTORY") && !$0.text.contains("OLD USER") })
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    } catch { await engine.shutdown(); throw error }
}

/// Opt-in real provider usage. Sends only a generated marker in an empty workspace.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_ACP_TURN"] == "1"), .timeLimit(.minutes(3)))
func installedOpenCodeCompletesATurnThroughTheNativeEngine() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"))
    do {
        let agent = ACPAgentConfiguration(name: "OpenCode", executable: "opencode", arguments: ["acp"])
        let project = WorkspaceProject(path: root.path), marker = "ACP-\(UUID().uuidString.prefix(8))"
        var thread = CodingThread(project: project); thread.provider = .acp; thread.acpAgent = agent
        thread.model = ProcessInfo.processInfo.environment["COINCIDE_ACP_TEST_MODEL"] ?? ""
        _ = try await engine.load(); try await engine.dispatch(.addProject(project)); try await engine.dispatch(.saveACPAgent(agent)); try await engine.dispatch(.createThread(thread))
        try await engine.dispatch(.submit(threadID: thread.id, text: "Reply with exactly \(marker) and nothing else. Do not use any tools."))
        let deadline = ContinuousClock.now + .seconds(140)
        while true {
            let current = await engine.current(), thread = try #require(current.snapshot.threads.first)
            if let error = current.error { throw CoincideError(error) }
            if thread.state == .idle {
                let answer = thread.messages.filter { $0.role == .assistant }.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(answer == marker); break
            }
            if thread.state == .failed || thread.state == .interrupted {
                throw CoincideError(thread.messages.last(where: { $0.role == .system })?.text ?? "The OpenCode turn did not complete.")
            }
            for pending in thread.runtimeRequests where !pending.responding {
                try await engine.dispatch(.respond(threadID: thread.id, requestID: pending.id, response: .decision(false)))
            }
            guard ContinuousClock.now < deadline else { throw CoincideError("The OpenCode turn timed out.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}
