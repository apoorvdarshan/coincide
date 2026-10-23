import Foundation
import Testing
@testable import CoincideCore

@Test func grokACPLaunchModesOverrideInheritedPolicyWithoutInventingAcceptEdits() throws {
    #expect(GrokACP.arguments(runtimeMode: .approvalRequired) == ["--permission-mode", "default", "agent", "stdio"])
    #expect(GrokACP.arguments(runtimeMode: .auto) == ["--permission-mode", "auto", "agent", "stdio"])
    #expect(GrokACP.arguments(runtimeMode: .fullAccess) == ["agent", "--always-approve", "stdio"])
    #expect(try GrokACP.arguments(permission: .supervised) == ACPIntegration.grok.arguments)
    #expect(try GrokACP.runtimeMode(permission: .auto) == .auto)
    #expect(try GrokACP.arguments(permission: .auto) == ["--permission-mode", "auto", "agent", "stdio"])
    #expect(throws: (any Error).self) { try GrokACP.arguments(permission: .autoAcceptEdits) }
    #expect(ACPIntegration.grok.executable == "grok" && ACPIntegration.grok.signInCommand == "grok login")
    #expect(GrokACP.initializeMetadata == .object(["clientType": .string("extension")]))
    #expect(GrokACP.cancellationMetadata == .object(["cancelTrigger": .string("ctrl_c")]))
}

private func grokQuestion(_ multiple: Bool = false) -> JSONValue {
    .object(["sessionId": .string("root"), "toolCallId": .string("ask"), "mode": .string("plan"), "questions": .array([
        .object(["id": .string("choice"), "question": .string("Native text?"), "multiSelect": .bool(multiple), "options": .array([
            .object(["id": .string("opaque-A"), "label": .string("Label A"), "preview": .string("# Preview A")]),
            .object(["id": .string("opaque-B"), "label": .string("Label B"), "preview": .string("# Preview B")])])])]),
        "unknownCredential": .string("synthetic-private")])
}

@Test func grokACPQuestionsPreserveNativeLabelsPreviewsAndCustomNotesTogether() throws {
    let question = try GrokACPQuestionRequest(params: .object(["method": .string("_x.ai/ask_user_question"), "params": grokQuestion()]))
    #expect(question.sessionID == "root" && question.toolCallID == "ask")
    #expect(!question.parameters.pretty.contains("synthetic-private"))
    #expect(try GrokACPQuestionRequest(params: question.parameters) == question)
    let response = try question.response(selections: ["choice": ["opaque-B"]], notes: ["choice": "  Extra guidance\n"])
    #expect(response["answers"]["Native text?"] == .array([.string("Label B")]))
    #expect(response["annotations"]["Native text?"] == .object(["preview": .string("# Preview B"), "notes": .string("  Extra guidance\n")]))
    let custom = try question.response(selections: [:], notes: ["choice": "My own answer"])
    #expect(custom["answers"]["Native text?"] == .array([.string("Other")]))
    #expect(custom["annotations"]["Native text?"]["notes"] == .string("My own answer"))
    let multiple = try GrokACPQuestionRequest(params: grokQuestion(true))
    let choices = try multiple.response(selections: ["choice": ["opaque-B", "opaque-A"]], notes: ["choice": "Both"])
    #expect(choices["answers"]["Native text?"] == .array([.string("Label A"), .string("Label B")]))
    #expect(choices["annotations"]["Native text?"]["preview"] == .null)
    #expect(throws: (any Error).self) { try question.response(selections: ["choice": ["invented"]]) }
    #expect(throws: (any Error).self) { try question.response(selections: ["choice": ["opaque-A", "opaque-B"]]) }
    #expect(throws: (any Error).self) { try question.response(selections: [:], notes: ["unknown": "No"]) }
}

private func grokNotice(_ fields: [String: JSONValue], prompt: String? = nil) -> JSONValue {
    var value: [String: JSONValue] = ["sessionId": .string("root"), "update": .object(fields)]
    if let prompt { value["_meta"] = .object(["promptId": .string(prompt)]) }; return .object(value)
}
private func grokComplete(_ prompt: String?, session: String = "root", reason: String = "end_turn") -> JSONValue {
    var value: [String: JSONValue] = ["sessionId": .string(session), "stopReason": .string(reason), "agentResult": .string("synthetic-private")]
    if let prompt { value["promptId"] = .string(prompt) }; return .object(value)
}

@Test func grokACPCompletionRequiresExactPromptSessionAndNeverAdoptsTaskWake() throws {
    var bridge = GrokACPBridge(); let run = UUID()
    try bridge.beginRun(sessionID: "root", runID: run, promptID: "current")
    for params in [grokComplete(nil), grokComplete("foreign"), grokComplete("current", session: "foreign"), grokComplete("task-completed-current")] {
        #expect(try bridge.consume(method: "_x.ai/session/prompt_complete", params: params).completion == nil)
    }
    let complete = try bridge.consume(method: "_x.ai/session_notification", params: grokNotice([
        "sessionUpdate": .string("turn_completed"), "prompt_id": .string("current"), "stop_reason": .string("end_turn")]))
    #expect(complete.completion?.promptID == "current")
    #expect(complete.completion?.response == .object(["stopReason": .string("end_turn")]))
    bridge.finishRun(promptID: "current")
    try bridge.beginRun(sessionID: "root", runID: UUID(), promptID: "next")
    #expect(try bridge.consume(method: "x.ai/session/prompt_complete", params: grokComplete("current")).completion == nil)
}

@Test func grokACPBackgroundCompletionDefersForegroundAndPersistentMonitorKeepsOriginalOwner() throws {
    var bridge = GrokACPBridge(); let first = UUID(), second = UUID()
    try bridge.beginRun(sessionID: "root", runID: first, promptID: "first")
    let started = try bridge.consume(method: "session/update", params: grokNotice([
        "sessionUpdate": .string("tool_call"), "toolCallId": .string("shell"), "title": .string("Bash"), "status": .string("completed"),
        "rawInput": .object(["command": .string("printf synthetic"), "headers": .object(["Authorization": .string("synthetic-private")])]),
        "rawOutput": .object(["type": .string("BackgroundTaskStarted"), "task_id": .string("shell-native")])], prompt: "first"))
    let initialUpdate = try #require(started.updates.first)
    var shell = try initialUpdate.update.apply(to: nil)
    #expect(shell.fields["status"] == .string("in_progress"))
    #expect(!shell.fields.pretty.contains("synthetic-private"))
    #expect(try bridge.consume(method: "_x.ai/session/prompt_complete", params: grokComplete("first")).completion == nil)
    let ended = try bridge.consume(method: "_x.ai/task_completed", params: grokNotice([
        "task_id": .string("shell-native"), "task_snapshot": .object(["task_id": .string("shell-native"), "output": .string("Result"), "exit_code": .number(1)])]))
    #expect(ended.completion?.promptID == "first")
    let terminalUpdate = try #require(ended.updates.first)
    shell = try terminalUpdate.update.apply(to: shell)
    #expect(shell.fields["status"] == .string("failed") && shell.text.contains("Result"))
    bridge.finishRun(promptID: "first")
    try bridge.beginRun(sessionID: "root", runID: second, promptID: "second")
    let monitor = try bridge.consume(method: "session/update", params: grokNotice([
        "sessionUpdate": .string("tool_call"), "toolCallId": .string("monitor"), "title": .string("Monitor"), "status": .string("completed"),
        "rawOutput": .object(["type": .string("Monitor"), "taskId": .string("persistent"), "persistent": .bool(true)])], prompt: "second"))
    #expect(monitor.updates.first?.runID == second)
    #expect(try bridge.acceptCompletion(promptID: "second", stopReason: "end_turn") != nil)
    bridge.finishRun(promptID: "second")
    try bridge.beginRun(sessionID: "root", runID: UUID(), promptID: "third")
    let late = try bridge.consume(method: "x.ai/task_completed", params: grokNotice([
        "task_id": .string("persistent"), "task_snapshot": .object(["exit_code": .number(0), "output": .string("Old monitor")])]))
    #expect(late.updates.first?.runID == second && late.completion == nil)
}

@Test func grokACPChildSessionsRequireAnExactSpawnLinkAndCannotFinishTheParent() throws {
    var bridge = GrokACPBridge(); let run = UUID(), child = "12345678-1234-1234-1234-123456789abc"
    try bridge.beginRun(sessionID: "root", runID: run, promptID: "root-prompt")
    let spawn = try bridge.consume(method: "session/update", params: grokNotice([
        "sessionUpdate": .string("tool_call"), "toolCallId": .string("spawn"), "title": .string("spawn_subagent"), "status": .string("completed"),
        "rawInput": .object(["prompt": .string("Synthetic child"), "subagent_type": .string("explore")]),
        "rawOutput": .string("Subagent started in background\nsubagent_id: \(child)")], prompt: "root-prompt"))
    #expect(spawn.updates.first?.runID == run)
    let chunk: JSONValue = .object(["sessionId": .string(child), "update": .object(["sessionUpdate": .string("agent_message_chunk"),
        "content": .object(["type": .string("text"), "text": .string("Child output")])])])
    let childOutput = try bridge.consume(method: "session/update", params: chunk)
    #expect(childOutput.updates.first?.runID == run && childOutput.updates.first?.update.key.sessionID == child)
    #expect(try bridge.consume(method: "_x.ai/session/prompt_complete", params: grokComplete("root-prompt", session: child)).completion == nil)
    let terminal = try bridge.consume(method: "_x.ai/session_notification", params: grokNotice([
        "sessionUpdate": .string("subagent_finished"), "child_session_id": .string(child), "status": .string("cancelled"), "error": .string("synthetic-private")]))
    #expect(terminal.completion == nil)
    let update = try #require(terminal.updates.first)
    let entity = try update.update.apply(to: nil)
    #expect(entity.fields["status"] == .string("interrupted"))
    #expect(entity.fields["_meta"]["x.ai"]["childSessionID"] == .string(child))
    #expect(!entity.fields.pretty.contains("synthetic-private"))
}

@Test func grokACPObservedTextBudgetBelongsToItsOriginalRunRatherThanTheEntireChat() throws {
    var bridge = GrokACPBridge()
    let text = String(repeating: "x", count: 131_072)
    for prompt in ["first", "second"] {
        try bridge.beginRun(sessionID: "root", runID: UUID(), promptID: prompt)
        for _ in 0..<20 {
            _ = try bridge.consume(method: "session/update", params: grokNotice(["sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string(text)])], prompt: prompt))
        }
        bridge.finishRun(promptID: prompt)
    }
}

private actor GrokACPRecord {
    var completions: [ThreadState] = []
    var requests: [ApprovalRequest] = []
    var entities: [ProviderEntityKey: ProviderEntity] = [:]
    var owners: [UUID] = []
    var notices: [String] = []
    var configurations: [JSONValue] = []
    var rejectedInputs: [String] = []
    var foregroundErrors: [JSONValue] = []
    var closed = false
    func receive(_ scoped: ProviderEvent) throws {
        let event: ProviderEvent = if case .context(_, let inner) = scoped { inner } else { scoped }
        switch event {
        case .completed(let state): completions.append(state)
        case .activity(let activity) where activity.finishesRun && activity.state == .idle:
            if let error = activity.error { foregroundErrors.append(error) }
            completions.append(activity.stopReason == .string("cancelled") ? .interrupted : ["error", "rate_limit"].contains(activity.stopReason?.string ?? "") ? .failed : .idle)
        case .approval(let request), .sessionApproval(let request): requests.append(request)
        case .entity(let update): entities[update.key] = try update.apply(to: entities[update.key])
        case .runEntity(let owner, let update): owners.append(owner); entities[update.key] = try update.apply(to: entities[update.key])
        case .message(let message):
            notices.append(message.text)
            if let entity = message.providerEntity { entities[entity.key] = entity }
        case .configuration(let value): configurations.append(value)
        case .submissionFailed(_, let reason): rejectedInputs.append(reason)
        case .failure(let text): notices.append(text)
        case .connectionClosed: closed = true
        default: break
        }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["completion", "snake", "rpc", "fallback", "background", "question", "permission", "deferred", "plan", "cancel", "error", "rate_limit"])
func grokACPV1UsesRealStdioExtensionsAndKeepsOriginalBackgroundOwnership(_ flow: String) async throws {
    try await withGrokActor(flow: flow, requestedVersion: flow == "fallback" ? 2 : 1, negotiatedVersion: 1)
}

@Test(.timeLimit(.minutes(1)), arguments: ["completion", "snake", "background", "question", "permission", "deferred", "deferred-idle", "plan", "cancel", "error", "rate_limit", "rpc-reject"])
func grokACPV2UsesExactExtensionsAndDoesNotFinishOnInsertion(_ flow: String) async throws {
    try await withGrokActor(flow: flow, requestedVersion: 2, negotiatedVersion: 2)
}

private func withGrokActor(flow: String, requestedVersion: Int, negotiatedVersion: Int) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let peer = try #require(Bundle.module.url(forResource: "grok_acp_server", withExtension: "py", subdirectory: "Fixtures"))
    let session: any ProviderSession = if requestedVersion == 1 {
        try ACPSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [peer.path, flow, String(negotiatedVersion)], cwd: root, integration: .grok, grokRuntimeMode: .approvalRequired)
    } else {
        try ACP2Session(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [peer.path, flow, String(negotiatedVersion)], cwd: root, integration: .grok, grokRuntimeMode: .approvalRequired)
    }
    let record = GrokACPRecord()
    let reader = Task { for await event in session.events { try await record.receive(event) } }
    do {
        var first = CodingThread(project: .init(path: root.path)); first.permission = .supervised
        let firstRun = UUID(); first.activeRun = .init(id: firstRun, configuration: .init(thread: first), startedAt: Date())
        try await session.send(text: "Synthetic first", thread: first)
        if ["question", "permission", "deferred", "deferred-idle"].contains(flow) {
            try await grokEventually { await record.requests.count == 1 }
            let requests = await record.requests
            let request = try #require(requests.first)
            #expect(!request.params.pretty.contains("synthetic-private"))
            #expect(await record.completions.isEmpty)
            if flow == "deferred-idle" {
                let heldThread = first
                await #expect(throws: (any Error).self) { try await session.send(text: "Must remain queued behind background settlement", thread: heldThread) }
                #expect(await record.completions.isEmpty)
            }
            if flow == "question" {
                #expect(request.id != .string("reused-native-question"))
                try await session.selectAnswers(request, selections: ["choice": ["opaque"]], notes: ["choice": "Additional native notes"])
            } else {
                #expect(request.params["options"].array?.contains { $0["optionId"] == .string("always-workspace") } == false)
                try await session.respond(request, allow: true)
            }
        } else if flow == "cancel" {
            try await grokEventually { await record.entities.values.contains { $0.text.contains("owned-1") } }
            try await session.interrupt()
            #expect(try String(contentsOf: root.appendingPathComponent("cancel-proof"), encoding: .utf8) == "exact")
        }
        try await grokEventually { await record.completions.count == 1 }
        let completions = await record.completions
        #expect(completions == [flow == "cancel" ? .interrupted : ["error", "rate_limit", "rpc-reject"].contains(flow) ? .failed : .idle])
        if flow == "plan" {
            let entities = await record.entities
            let plan = try #require(entities.values.first { $0.key.type == "plan" && $0.fields["content"] == .string("# Synthetic proposal") })
            var message = ChatMessage(role: .tool, text: "# Synthetic proposal"); message.providerEntity = plan
            let card = TranscriptToolPresentation.card(for: message)
            #expect(card.kind == .plan && card.plan == "# Synthetic proposal")
        }
        if flow == "rpc-reject" {
            #expect(await record.rejectedInputs == ["Grok could not complete this turn."])
            #expect(await record.foregroundErrors == [.object(["message": .string("Grok could not complete this turn.")])])
            #expect(!(await record.rejectedInputs).joined().contains("synthetic-private"))
            #expect(!(await record.foregroundErrors).map(\.pretty).joined().contains("synthetic-private"))
        }
        if flow == "completion" {
            // A correlated terminal clears foreground bookkeeping. With no
            // pending permission/background work, Stop must not close an idle
            // connection just because the earlier state_update was running.
            await #expect(throws: (any Error).self) { try await session.interrupt() }
        }
        if flow == "background" {
            var second = first; second.providerThreadID = "grok-synthetic"
            second.activeRun = .init(id: UUID(), configuration: .init(thread: second), startedAt: Date())
            try await session.send(text: "Synthetic second", thread: second)
            try await grokEventually { await record.completions.count == 2 }
            let entities = await record.entities
            let monitor = try #require(entities.values.first { $0.fields["_meta"]["x.ai"]["taskID"] == .string("monitor-native") })
            #expect(monitor.fields["status"] == .string("completed") && monitor.text.contains("old monitor finished"))
            #expect(await record.owners.contains(firstRun))
            #expect(entities.values.contains { $0.text.contains("second remains owned") })
        }
        #expect(!(await record.notices).joined().contains("synthetic-private-upstream-body"))
        #expect(!(await record.configurations).map(\.pretty).joined().contains("synthetic-private-upstream-body"))
        await session.close(); try await reader.value
        let methods = try String(contentsOf: root.appendingPathComponent("audit-methods"), encoding: .utf8).split(separator: "\n")
        #expect(methods.filter { $0 == "authenticate" }.count == 1)
    } catch { await session.close(); _ = try? await reader.value; throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [1, 2, 3])
func grokACPInitializeOnlyDoesNotAuthenticateAndCoalescedSessionReadsAuthenticateExactlyOnce(_ protocolChoice: Int) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let peer = try #require(Bundle.module.url(forResource: "grok_acp_server", withExtension: "py", subdirectory: "Fixtures"))
    let version = protocolChoice == 2 ? 2 : 1
    let session: any ProviderSession = if protocolChoice == 1 {
        try ACPSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [peer.path, "metadata", String(version)], cwd: root, integration: .grok)
    } else {
        try ACP2Session(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [peer.path, "metadata", String(version)], cwd: root, integration: .grok)
    }
    do {
        _ = try await session.acpConnectionInfo()
        #expect(try String(contentsOf: root.appendingPathComponent("audit-methods"), encoding: .utf8) == "initialize\n")
        async let first = session.models()
        async let second = session.models()
        _ = try await (first, second)
        await session.close()
        let methods = try String(contentsOf: root.appendingPathComponent("audit-methods"), encoding: .utf8).split(separator: "\n")
        #expect(methods.filter { $0 == "initialize" }.count == 1)
        #expect(methods.filter { $0 == "authenticate" }.count == 1)
        #expect(methods.filter { $0 == "session/new" }.count == 1)
        #expect(!methods.contains("session/prompt"))
    } catch { await session.close(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [1, 2])
func grokACPRejectedExistingSignInNeverCreatesSessionOrRetriesAuthentication(_ version: Int) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let peer = try #require(Bundle.module.url(forResource: "grok_acp_server", withExtension: "py", subdirectory: "Fixtures"))
    let session: any ProviderSession = if version == 1 {
        try ACPSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [peer.path, "auth-reject", String(version)], cwd: root, integration: .grok)
    } else {
        try ACP2Session(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [peer.path, "auth-reject", String(version)], cwd: root, integration: .grok)
    }
    do {
        for _ in 0..<2 {
            do { _ = try await session.models(); Issue.record("Synthetic rejected sign-in created a session.") }
            catch { #expect(!error.localizedDescription.contains("synthetic-private")) }
        }
        await session.close()
        let methods = try String(contentsOf: root.appendingPathComponent("audit-methods"), encoding: .utf8).split(separator: "\n")
        #expect(methods.filter { $0 == "authenticate" }.count == 1)
        #expect(!methods.contains("session/new") && !methods.contains("session/prompt"))
    } catch { await session.close(); throw error }
}

private func grokEventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The synthetic Grok ACP fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
