import Foundation
import Testing
@testable import CoincideCore

private struct V2Fixture {
    let root: URL
    let gate: URL
    let engine: WorkspaceEngine
    let thread: CodingThread
}
private func withV2(_ mode: String, systemFactory: Bool = false, body: (V2Fixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try #require(Bundle.module.url(forResource: "acp_v2_server", withExtension: "py", subdirectory: "Fixtures"))
    let gate = root.appendingPathComponent("gate"), project = WorkspaceProject(path: root.path)
    var agent = ACPAgentConfiguration(name: "V2 Fixture", executable: "/usr/bin/python3", arguments: [fixture.path, mode, gate.path])
    agent.experimentalV2 = true
    var thread = CodingThread(project: project); thread.provider = .acp; thread.acpAgent = agent
    let factory: WorkspaceEngine.ProviderFactory = { [agent] thread in
        try ACP2Session(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: agent.arguments, cwd: URL(fileURLWithPath: thread.workspacePath),
                        cancellationTimeout: .milliseconds(100), acceptanceTimeout: mode == "lost_ack" ? .milliseconds(250) : .seconds(20))
    }
    let selectedFactory: WorkspaceEngine.ProviderFactory
    if systemFactory { selectedFactory = { thread in try ProviderSessions.make(for: thread) } }
    else { selectedFactory = factory }
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: selectedFactory)
    do {
        _ = try await engine.load(); try await engine.dispatch(.addProject(project)); try await engine.dispatch(.saveACPAgent(agent)); try await engine.dispatch(.createThread(thread))
        try await body(.init(root: root, gate: gate, engine: engine, thread: thread))
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}
private func waitV2(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("ACP v2 fixture timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func approveV2UntilIdle(_ f: V2Fixture, allowPausedQueue: Bool = false) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while true {
        let current = await f.engine.current(), thread = current.snapshot.threads[0]
        if let error = current.error { throw CoincideError(error) }
        if thread.activeRun == nil && thread.state == .idle && thread.heldPostRunCheckpoint == nil &&
           (thread.queuedTurns.isEmpty || (allowPausedQueue && thread.queuePaused)) { return }
        if thread.state == .failed { throw CoincideError(thread.messages.last(where: { $0.role == .system })?.text ?? "The fixture failed") }
        for request in thread.runtimeRequests where !request.responding && request.id.string != "background-request" {
            try await f.engine.dispatch(.respond(threadID: thread.id, requestID: request.id, response: .option("opaque-allow")))
        }
        guard ContinuousClock.now < deadline else { throw CoincideError("The v2 fixture did not complete") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["normal", "echo_after", "early_state"])
func acpV2NativeEnginePreservesEntitiesImageInputBooleanConfigAndUserIdentity(_ mode: String) async throws {
    try await withV2(mode, systemFactory: true) { f in
        try await f.engine.dispatch(.editThread(f.thread.id, .model("fixture")))
        try await f.engine.dispatch(.editThread(f.thread.id, .agentConfiguration(id: "boolean", value: .bool(true))))
        try await f.engine.dispatch(.editThread(f.thread.id, .agentConfiguration(id: "mode", value: .string("plan"))))
        let image = try await f.engine.attachments.importData(attachmentImageData(), name: "image.png")
        try await f.engine.dispatch(.addAttachments(threadID: f.thread.id, attachments: [image]))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Original user text"))
        try await approveV2UntilIdle(f)
        let thread = await f.engine.current().snapshot.threads[0]
        let user = thread.messages.filter { $0.role == .user }, entities = thread.messages.compactMap(\.providerEntity)
        #expect(user.count == 1 && user[0].text == "Original user text" && user[0].attachments == [image])
        #expect(user[0].providerEntity?.key.type == "user_message" && user[0].submissionError == nil)
        #expect(thread.messages.filter { $0.role == .assistant }.map(\.text) == ["hello 🌍"])
        #expect(entities.contains { $0.key.type == "agent_thought" && $0.text == "Thinking" })
        #expect(entities.contains { $0.key.type == "tool_call" && $0.fields["rawOutput"]["saved"] == .bool(true) })
        #expect(entities.contains { $0.key.type == "terminal" && $0.text.contains("🌍") })
        #expect(entities.contains { $0.key.type == "plan" && $0.text.contains("Fixture plan") })
        #expect(entities.contains { $0.key.type == "unknown" && $0.fields["raw"]["preserved"] == .bool(true) })
        #expect(thread.providerActivity?.state == .idle && thread.activeRun == nil && !thread.queuePaused)
        let options = thread.providerMetadata?["configOptions"].array ?? []
        #expect(options.first(where: { $0["configId"].string == "model" })?["currentValue"] == .string("fixture"))
        #expect(options.first(where: { $0["configId"].string == "boolean" })?["currentValue"] == .bool(true))
        #expect(options.first(where: { $0["configId"].string == "mode" })?["currentValue"] == .string("plan"))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["accept_only", "repeat_idle", "idle_before_ack"])
func acpV2AcceptanceInitialIdleAndRepeatedSnapshotsNeverAdvanceTheQueue(_ mode: String) async throws {
    try await withV2(mode) { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first"))
        try await waitV2 { await f.engine.current().snapshot.threads[0].messages.contains { $0.providerEntity?.key.type == "user_message" } }
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "second"))
        let before = await f.engine.current().snapshot.threads[0]
        #expect(before.activeRun != nil && before.queuedTurns.count == 1)
        #expect(before.messages.filter { $0.role == .user && $0.id.hasPrefix("user-") }.count == 1)
        try Data().write(to: f.gate)
        try await approveV2UntilIdle(f)
        let completed = await f.engine.current().snapshot.threads[0]
        #expect(completed.queuedTurns.isEmpty && completed.messages.filter { $0.role == .user }.count == 2)
    }
}

@Test(.timeLimit(.minutes(1))) func acpV2ConcurrentPermissionsKeepRequiresActionUntilTheAgentReportsRunning() async throws {
    try await withV2("concurrent_requests") { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first"))
        try await waitV2 {
            let t = await f.engine.current().snapshot.threads[0]; return t.runtimeRequests.count == 2 && t.state == .awaitingApproval
        }
        let first = try #require(await f.engine.current().snapshot.threads[0].runtimeRequests.first)
        #expect(first.sessionScoped == true && first.request.title == "Read the synthetic fixture?")
        try await f.engine.dispatch(.respond(threadID: f.thread.id, requestID: first.id, response: .option("opaque-allow")))
        try await waitV2 { await f.engine.current().snapshot.threads[0].runtimeRequests.count == 1 }
        #expect(await f.engine.current().snapshot.threads[0].state == .awaitingApproval)
        try await approveV2UntilIdle(f)
    }
}

@Test(.timeLimit(.minutes(1))) func acpV2BackgroundPermissionSurvivesAnotherTurnAndNeverInventsForegroundWork() async throws {
    try await withV2("background") { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first")); try await approveV2UntilIdle(f)
        try Data().write(to: f.gate)
        try await waitV2 { await f.engine.current().snapshot.threads[0].runtimeRequests.contains { $0.id == .string("background-request") } }
        let idle = await f.engine.current().snapshot.threads[0]
        #expect(idle.state == .idle && idle.activeRun == nil)
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "second")); try await approveV2UntilIdle(f)
        #expect(await f.engine.current().snapshot.threads[0].runtimeRequests.contains { $0.id == .string("background-request") })
        try await f.engine.dispatch(.respond(threadID: f.thread.id, requestID: .string("background-request"), response: .option("opaque-allow")))
        try await waitV2 {
            await f.engine.current().snapshot.threads[0].messages.contains { $0.providerEntity?.key.id == "ambient-tool" && $0.providerEntity?.fields["rawOutput"]["saved"] == .string("while idle") }
        }
        let done = await f.engine.current().snapshot.threads[0]
        #expect(done.state == .idle && done.activeRun == nil && done.messages.filter { $0.role == .user }.count == 2)
    }
}

@Test(.timeLimit(.minutes(1))) func acpV2AgentInitiatedActivityDoesNotCreateASyntheticUserMessage() async throws {
    try await withV2("agent_initiated") { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first")); try await approveV2UntilIdle(f)
        let userCount = await f.engine.current().snapshot.threads[0].messages.filter { $0.role == .user }.count
        try Data().write(to: f.gate)
        try await waitV2 { await f.engine.current().snapshot.threads[0].state == .running }
        let active = await f.engine.current().snapshot.threads[0]
        #expect(active.activeRun != nil && active.messages.filter { $0.role == .user }.count == userCount)
        try Data().write(to: URL(fileURLWithPath: f.gate.path + ".finish"))
        try await waitV2 { await f.engine.current().snapshot.threads[0].state == .idle }
        #expect(await f.engine.current().snapshot.threads[0].messages.contains { $0.text == "Agent initiated follow-up" })
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["cancel_before", "cancel_after", "cancel_ignored"])
func acpV2CancelBeforeInsertionAfterAcceptanceAndUnresponsivePeerAreBounded(_ mode: String) async throws {
    try await withV2(mode) { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first"))
        try await waitV2 { await f.engine.current().snapshot.threads[0].activeRun?.nativeTurnID != nil }
        if mode == "cancel_after" { try await waitV2 { await f.engine.current().snapshot.threads[0].messages.contains { $0.id.hasPrefix("user-") && $0.providerEntity != nil } } }
        try await f.engine.dispatch(.interrupt(threadID: f.thread.id))
        try await waitV2 { await f.engine.current().snapshot.threads[0].state == .interrupted }
        let done = await f.engine.current().snapshot.threads[0]
        #expect(done.queuePaused && done.activeRun == nil)
        if mode == "cancel_before" { #expect(done.messages.first(where: { $0.role == .user })?.providerEntity == nil) }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["reject", "hook_failure", "lost_ack"])
func acpV2RejectedAndUnconfirmedSubmissionsRemainVisibleWithoutAutomaticResend(_ mode: String) async throws {
    try await withV2(mode) { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first"))
        try await waitV2 { await f.engine.current().snapshot.threads[0].state == .failed }
        let failed = await f.engine.current().snapshot.threads[0]
        #expect(failed.messages.first(where: { $0.id.hasPrefix("user-") })?.submissionError != nil)
        #expect(failed.messages.first(where: { $0.id.hasPrefix("user-") })?.providerEntity == nil)
        #expect(failed.activeRun == nil && failed.queuePaused)
        #expect(failed.messages.filter { $0.id.hasPrefix("user-") }.count == 1)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["unknown_stop", "max_tokens"]) func acpV2IdleOutcomeAdvancesOnlyForRecognizedCompletions(_ mode: String) async throws {
    try await withV2(mode) { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first"))
        try await waitV2 { await f.engine.current().snapshot.threads[0].runtimeRequests.count == 1 }
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "second")); try await approveV2UntilIdle(f, allowPausedQueue: mode == "unknown_stop")
        let done = await f.engine.current().snapshot.threads[0]
        #expect(done.state == .idle && done.activeRun == nil)
        if mode == "unknown_stop" {
            #expect(done.queuePaused && done.queuedTurns.count == 1)
            #expect(done.providerActivity?.stopReason?.object?["malformed"] == .string("retained"))
        } else { #expect(!done.queuePaused && done.queuedTurns.isEmpty && done.messages.filter { $0.role == .user }.count == 2) }
    }
}

@Test(.timeLimit(.minutes(1))) func acpV2NegotiationFallsBackToV1OnTheSameProcess() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try #require(Bundle.module.url(forResource: "acp_server", withExtension: "py", subdirectory: "Fixtures"))
    let session = try ACP2Session(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture.path, "v2_fallback"], cwd: root)
    do {
        #expect(try await session.connect()["protocolVersion"] == .number(1))
        #expect(try await session.models().map(\.id) == ["default", "fixture"])
        let observer = Task {
            for await scoped in session.events {
                let event: ProviderEvent = if case .context(_, let inner) = scoped { inner } else { scoped }
                switch event {
                case .approval(let request): try await session.respond(request, allow: true)
                case .completed(let state): return state
                case .failure(let reason), .connectionClosed(let reason): throw CoincideError(reason)
                default: break
                }
            }; throw CoincideError("The fallback peer did not finish")
        }
        let thread = CodingThread(project: WorkspaceProject(path: root.path))
        try await session.send(text: "fallback", thread: thread)
        #expect(try await observer.value == .idle)
        await session.close()
    } catch { await session.close(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["normal", "resume_busy"])
func acpV2RestartResumesWithoutReplayAndKeepsTheReportedForegroundSnapshot(_ mode: String) async throws {
    try await withV2(mode, systemFactory: true) { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first")); try await approveV2UntilIdle(f)
        await f.engine.shutdown()
        let url = f.root.appendingPathComponent("workspace.sqlite"), reopened = try WorkspaceEngine(url: url)
        do {
            let snapshot = try await reopened.load()
            #expect(snapshot.threads[0].providerThreadID == "v2-session")
            try await reopened.dispatch(.submit(threadID: f.thread.id, text: "second"))
            let fixture = V2Fixture(root: f.root, gate: f.gate, engine: reopened, thread: f.thread)
            if mode == "resume_busy" {
                try await waitV2 { await reopened.current().snapshot.threads[0].runtimeRequests.contains { $0.id == .string("resume-request") } }
                #expect(await reopened.current().snapshot.threads[0].state == .awaitingApproval)
                try await reopened.dispatch(.respond(threadID: f.thread.id, requestID: .string("resume-request"), response: .option("opaque-allow")))
            }
            try await approveV2UntilIdle(fixture)
            let finished = await reopened.current().snapshot.threads[0]
            #expect(finished.messages.filter { $0.role == .user }.count == 2)
            #expect(finished.messages.filter { $0.role == .assistant }.map(\.text) == ["hello 🌍", "hello 🌍"])
            await reopened.shutdown()
            let database = try WorkspaceDatabase(url: url), current = await reopened.current().snapshot
            #expect(try await database.rebuildProjection().snapshot == current)
        } catch { await reopened.shutdown(); throw error }
    }
}

@Test(.timeLimit(.minutes(1))) func acpV2AcceptanceIsAssociatedBeforeAnImmediatePeerExit() async throws {
    try await withV2("exit_after_ack") { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first"))
        try await waitV2 {
            let t = await f.engine.current().snapshot.threads[0]
            return t.runtimeID == nil && t.activeRun == nil && t.providerThreadID != nil
        }
        let done = await f.engine.current().snapshot.threads[0]
        #expect(done.state == .idle && done.activeRun == nil)
        #expect(done.messages.filter { $0.role == .user }.count == 1)
        #expect(done.messages.first(where: { $0.role == .user })?.providerEntity?.key.type == "user_message")
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_ACP2"] == "1"), .timeLimit(.minutes(3)))
func installedOpenCodeUsesTheVersionNegotiatedOnItsNativeConnection() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"))
    do {
        var agent = ACPAgentConfiguration(name: "OpenCode v2 negotiation", executable: "opencode", arguments: ["acp"])
        agent.experimentalV2 = true
        let project = WorkspaceProject(path: root.path), marker = "ACP2\(Int.random(in: 100_000...999_999))"
        var thread = CodingThread(project: project); thread.provider = .acp; thread.acpAgent = agent
        thread.model = ProcessInfo.processInfo.environment["COINCIDE_ACP_TEST_MODEL"] ?? ""
        _ = try await engine.load(); try await engine.dispatch(.addProject(project)); try await engine.dispatch(.saveACPAgent(agent)); try await engine.dispatch(.createThread(thread))
        try await engine.dispatch(.submit(threadID: thread.id, text: "Reply with exactly \(marker) and nothing else. Do not use any tools."))
        let deadline = ContinuousClock.now + .seconds(140)
        while true {
            let current = await engine.current(), t = current.snapshot.threads[0]
            if let error = current.error { throw CoincideError(error) }
            if t.state == .idle {
                #expect(t.messages.filter { $0.role == .assistant }.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == marker)
                #expect(t.providerMetadata?["protocolVersion"] == .number(1) || t.providerMetadata?["protocolVersion"] == .number(2))
                print("Installed OpenCode negotiated ACP \(t.providerMetadata?["protocolVersion"].pretty ?? "1")")
                break
            }
            if t.state == .failed || t.state == .interrupted { throw CoincideError(t.messages.last(where: { $0.role == .system })?.text ?? "The negotiated provider turn failed") }
            for request in t.runtimeRequests where !request.responding { try await engine.dispatch(.respond(threadID: t.id, requestID: request.id, response: .decision(false))) }
            guard ContinuousClock.now < deadline else { throw CoincideError("The negotiated provider turn timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func acpV2QueuedTurnsKeepTheirCapturedBooleanConfiguration() async throws {
    try await withV2("normal", systemFactory: true) { f in
        try await f.engine.dispatch(.editThread(f.thread.id, .agentConfiguration(id: "boolean", value: .bool(true))))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first"))
        try await waitV2 { await f.engine.current().snapshot.threads[0].runtimeRequests.count == 1 }
        try await f.engine.dispatch(.editThread(f.thread.id, .agentConfiguration(id: "boolean", value: .bool(false))))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "second"))
        try await f.engine.dispatch(.editThread(f.thread.id, .agentConfiguration(id: "boolean", value: .bool(true))))
        try await approveV2UntilIdle(f)
        let tools = await f.engine.current().snapshot.threads[0].messages.compactMap(\.providerEntity).filter { $0.key.type == "tool_call" }
        #expect(tools.map { $0.fields["rawInput"]["boolean"] } == [.bool(true), .bool(false)])
    }
}

@Test(.timeLimit(.minutes(1))) func acpV2StopDuringSessionConfigurationNeverDispatchesThePromptAfterward() async throws {
    try await withV2("cancel_setup") { f in
        try await f.engine.dispatch(.editThread(f.thread.id, .model("fixture")))
        let commandID = UUID()
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "must not reach agent"), id: commandID)
        try await waitV2 { FileManager.default.fileExists(atPath: f.gate.path + ".config") }
        let runID = try #require(await f.engine.current().snapshot.threads[0].activeRun?.id)
        try await f.engine.dispatch(.interrupt(threadID: f.thread.id))
        try await waitV2 { await f.engine.current().snapshot.threads[0].state == .interrupted }
        let database = try WorkspaceDatabase(url: f.root.appendingPathComponent("workspace.sqlite"))
        try await waitV2 {
            try await database.effects().contains { effect in
                guard case .providerStart(let threadID, let effectRunID, _, _, _) = effect.request else { return false }
                return threadID == f.thread.id && effectRunID == runID && effect.status == .cancelled
            }
        }
        await f.engine.shutdown()
        #expect(!FileManager.default.fileExists(atPath: f.gate.path + ".prompt"))
    }
}
