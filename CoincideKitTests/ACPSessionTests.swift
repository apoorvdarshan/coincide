import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct ACPSessionTests {
    private func makeSession(
        _ agent: ACPFakeAgent, flavor: ACPAgentFlavor = GrokFlavor(), launch: AgentLaunch = acpLaunch()
    ) -> (ACPSession, ACPEventLog) {
        let session = ACPSession(launch: launch, flavor: flavor, transport: agent.factory)
        let log = ACPEventLog()
        log.attach(session)
        return (session, log)
    }

    private func json(_ text: String) -> JSONValue {
        JSONValue.parse(text) ?? .null
    }

    private func permission(_ toolCall: JSONValue, options: [(String, String)] = Self.grokOptions) -> JSONValue {
        [
            "sessionId": "sess-1", "toolCall": toolCall,
            "options": .array(options.map { ["optionId": .string($0.0), "name": .string($0.0), "kind": .string($0.1)] }),
        ]
    }

    private static let grokOptions = [
        ("allow-once", "allow_once"), ("allow-always", "allow_always"), ("reject-once", "reject_once"),
    ]

    // MARK: Handshake

    @Test func startInitializesAndCreatesASession() async throws {
        let agent = ACPFakeAgent()
        agent.initializeResult = json(ACPMapperTests.grokInitialize)
        let launch = acpLaunch()
        let (session, log) = makeSession(agent, launch: launch)
        try await session.start()

        #expect(session.sessionID == "sess-1")
        #expect(log.sessionIDs == ["sess-1"])
        let initialize = try #require(agent.requests("initialize").first)
        #expect(initialize["protocolVersion"] == 1)
        #expect(initialize.at("clientCapabilities.fs.readTextFile") == false)
        #expect(initialize.at("clientCapabilities.terminal") == false)
        #expect(initialize["_meta"] == ["clientType": "extension"])
        #expect(initialize.at("clientInfo.name") == "coincide")
        #expect(agent.requests("session/new").first?["cwd"] == .string(launch.workingDirectory.path))
        #expect(agent.requests("session/new").first?["mcpServers"] == [])
        #expect(agent.transport.arguments == ["--permission-mode", "default", "agent", "stdio"])
        let models = log.events.compactMap { if case .modelsDiscovered(let models) = $0 { models } else { nil } }.first
        #expect(models?.map(\.modelID) == ["grok-build", "grok-4.7", "grok-4.6"])
    }

    @Test func resumeLoadsTheSessionWithoutReplayingIt() async throws {
        let agent = ACPFakeAgent()
        agent.handlers["session/load"] = { id, params in
            #expect(params["sessionId"] == "old-1")
            agent.update(["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "earlier"]], session: "old-1")
            agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "answer"]], session: "old-1")
            agent.update(["sessionUpdate": "tool_call", "toolCallId": "old-tool", "title": "ls", "kind": "execute"], session: "old-1")
            agent.reply(id, [:])
        }
        let (session, log) = makeSession(agent, launch: acpLaunch(resume: "old-1"))
        try await session.start()
        await acpSettle()

        #expect(session.sessionID == "old-1")
        #expect(log.events == [.sessionStarted(id: "old-1")])
        #expect(agent.requests("session/new").isEmpty)
    }

    @Test func failedResumeStartsAFreshSession() async throws {
        let agent = ACPFakeAgent()
        agent.handlers["session/load"] = { id, _ in agent.fail(id, code: -32002, message: "Session not found") }
        let (session, log) = makeSession(agent, launch: acpLaunch(resume: "gone"))
        try await session.start()

        #expect(session.sessionID == "sess-1")
        #expect(log.sessionIDs == ["sess-1"])
        #expect(log.notices.count == 1)
    }

    @Test func authRequiredSignsInAndRetries() async throws {
        let agent = ACPFakeAgent()
        var attempts = 0
        agent.handlers["session/new"] = { id, _ in
            attempts += 1
            if attempts == 1 {
                agent.fail(id, code: ACPError.authRequired, message: "Authentication required")
            } else {
                agent.reply(id, ["sessionId": "sess-1"])
            }
        }
        let (session, _) = makeSession(agent, launch: acpLaunch(environment: ["XAI_API_KEY": "key"]))
        try await session.start()

        #expect(agent.requests("authenticate").first?["methodId"] == "xai.api_key")
        #expect(session.sessionID == "sess-1")
    }

    @Test func failedHandshakeStopsTheProcess() async throws {
        let agent = ACPFakeAgent()
        agent.handlers["session/new"] = { id, _ in agent.fail(id, code: -32603, message: "Internal error") }
        let (session, log) = makeSession(agent)
        await #expect(throws: ACPError.self) { try await session.start() }
        #expect(agent.transport.isTerminated)
        #expect(log.events.isEmpty)
    }

    // MARK: Turns

    @Test func turnStreamsReasoningAndTextThenCompletes() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        log.removeAll()
        try await session.send(acpTurn("Reply with exactly: pong"))

        let prompt = try #require(agent.requests("session/prompt").first)
        #expect(prompt["sessionId"] == "sess-1")
        #expect(prompt["prompt"] == [["type": "text", "text": "Reply with exactly: pong"]])
        #expect(prompt.at("_meta.promptId")?.string?.isEmpty == false)

        agent.update(["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "Reply with exactly: pong"]])
        agent.update(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "Simple."]])
        agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "po"]])
        agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "ng"]])
        agent.finishPrompt()
        await acpWaitUntil { !log.completions.isEmpty }

        #expect(
            log.events == [
                .reasoningDelta(itemID: "reasoning-1-1", delta: "Simple."),
                .reasoningText(itemID: "reasoning-1-1", text: "Simple."),
                .assistantTextDelta(itemID: "assistant-1-2", delta: "po"),
                .assistantTextDelta(itemID: "assistant-1-2", delta: "ng"),
                .assistantText(itemID: "assistant-1-2", text: "pong"),
                .turnCompleted(.completed),
            ])
    }

    @Test func updatesOutsideATurnAreIgnored() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        log.removeAll()
        agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "stray"]])
        agent.update(["sessionUpdate": "usage_update", "used": 5_000, "size": 200_000, "cost": ["amount": 0.25, "currency": "USD"]])
        await acpSettle()
        #expect(log.events == [.usage(TokenUsage(inputTokens: 5_000, contextWindow: 200_000, costUSD: 0.25))])
    }

    @Test func specialStopReasonsAddANotice() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("go"))
        agent.finishPrompt("max_tokens", usage: ["totalTokens": 900, "inputTokens": 800, "outputTokens": 100, "cachedReadTokens": 300])
        await acpWaitUntil { !log.completions.isEmpty }
        #expect(log.completions == [.completed])
        #expect(log.notices.count == 1)
        #expect(log.events.contains(.usage(TokenUsage(outputTokens: 100, cachedInputTokens: 300))))
    }

    @Test func promptErrorsFailTheTurn() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("go"))
        agent.fail(try #require(agent.lastPromptID), code: XAI.rateLimitedCode, message: "rate limited")
        await acpWaitUntil { !log.completions.isEmpty }
        #expect(log.completions == [.failed("Grok usage limit reached. Try again later.")])
    }

    // MARK: Approvals

    @Test func approvalRoundTrip() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("Run: echo coincide-ok"))

        let toolCall: JSONValue = [
            "toolCallId": "call-1", "title": "run_terminal_command", "kind": "execute", "status": "pending",
            "rawInput": ["command": "echo coincide-ok"],
        ]
        agent.update(.object(["sessionUpdate": "tool_call"].merging(toolCall.object ?? [:]) { $1 }))
        agent.ask(7, "session/request_permission", permission(toolCall))
        await acpWaitUntil { !log.approvals.isEmpty }

        let approval = log.approvals[0]
        #expect(approval.title == "Run `echo coincide-ok`")
        #expect(approval.category == .command)
        #expect(approval.toolCallID == "call-1")
        // Grok's allow-always would persist a project grant, so it is not offered.
        #expect(approval.options.map(\.label) == ["Approve", "Decline", "Cancel"])
        #expect(approval.options.map(\.kind) == [.allowOnce, .deny, .cancel])

        session.respond(to: approval.id, optionID: "allow-once")
        #expect(agent.answers[7]?.at("result.outcome") == ["outcome": "selected", "optionId": "allow-once"])

        agent.update([
            "sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "completed",
            "content": [["type": "content", "content": ["type": "text", "text": "coincide-ok\n"]]],
        ])
        agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Done."]])
        agent.finishPrompt()
        await acpWaitUntil { !log.completions.isEmpty }
        #expect(log.events.contains(.toolCompleted(id: "call-1", status: .completed, output: "coincide-ok\n")))
        #expect(log.completions == [.completed])
    }

    @Test func grokOffersSessionWideEditApproval() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("edit"))
        let toolCall: JSONValue = ["toolCallId": "e1", "title": "Edit", "kind": "edit", "locations": [["path": "/tmp/a.swift"]]]
        agent.ask(
            3, "session/request_permission",
            permission(toolCall, options: [("allow-once", "allow_once"), ("allow-edits-session", "allow_always"), ("reject-once", "reject_once")]))
        await acpWaitUntil { !log.approvals.isEmpty }
        #expect(log.approvals[0].options.map(\.label) == ["Approve", "Allow all edits this session", "Decline", "Cancel"])
    }

    @Test func declinedApprovalsMarkTheToolDeclined() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("delete"))
        let toolCall: JSONValue = ["toolCallId": "rm-1", "title": "rm", "kind": "execute", "rawInput": ["command": "rm -rf build"]]
        agent.ask(4, "session/request_permission", permission(toolCall))
        await acpWaitUntil { !log.approvals.isEmpty }

        session.respond(to: log.approvals[0].id, optionID: "reject-once")
        #expect(agent.answers[4]?.at("result.outcome.optionId") == "reject-once")
        #expect(log.events.contains(.toolCompleted(id: "rm-1", status: .declined, output: nil)))

        // Cancel answers `cancelled`.
        agent.ask(5, "session/request_permission", permission(["toolCallId": "rm-2", "kind": "execute", "rawInput": ["command": "rm x"]]))
        await acpWaitUntil { log.approvals.count == 2 }
        session.respond(to: log.approvals[1].id, optionID: ACPApprovals.cancelOptionID)
        #expect(agent.answers[5]?.at("result.outcome") == ["outcome": "cancelled"])
    }

    @Test func fullAccessAnswersPermissionsItself() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent, launch: acpLaunch(accessMode: .fullAccess))
        try await session.start()
        #expect(agent.transport.arguments == ["agent", "--always-approve", "stdio"])
        try await session.send(acpTurn("go", accessMode: .fullAccess))
        agent.ask(8, "session/request_permission", permission(["toolCallId": "c", "kind": "execute", "rawInput": ["command": "make"]]))
        await acpWaitUntil { agent.answers[8] != nil }
        #expect(agent.answers[8]?.at("result.outcome.optionId") == "allow-once")
        #expect(log.approvals.isEmpty)
    }

    @Test func readsNeedNoApproval() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("look"))
        agent.ask(9, "session/request_permission", permission(["toolCallId": "r", "kind": "read", "rawInput": ["path": "/tmp/x"]]))
        await acpWaitUntil { agent.answers[9] != nil }
        #expect(agent.answers[9]?.at("result.outcome.optionId") == "allow-once")
        #expect(log.approvals.isEmpty)
    }

    @Test func agentCanWithdrawAnApproval() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("go"))
        agent.ask(12, "session/request_permission", permission(["toolCallId": "w", "kind": "edit"]))
        await acpWaitUntil { !log.approvals.isEmpty }
        agent.notify("$/cancel_request", ["requestId": 12])
        await acpWaitUntil { log.events.contains(.approvalResolved(id: log.approvals[0].id)) }
    }

    // MARK: Interrupt and crashes

    @Test func interruptCancelsAndRestartsGrok() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("long task"))
        agent.ask(13, "session/request_permission", permission(["toolCallId": "x", "kind": "execute", "rawInput": ["command": "sleep 100"]]))
        await acpWaitUntil { !log.approvals.isEmpty }

        session.interrupt()
        #expect(agent.notifications("session/cancel").first == ["sessionId": "sess-1", "_meta": ["cancelTrigger": "ctrl_c"]])
        #expect(agent.answers[13]?.at("result.outcome") == ["outcome": "cancelled"])
        agent.finishPrompt("cancelled")
        await acpWaitUntil { !log.completions.isEmpty }
        await acpSettle()
        #expect(log.completions == [.interrupted])
        // Grok can keep stale work after a cancel, so the next turn gets a new process.
        #expect(agent.transports[0].isTerminated)

        try await session.send(acpTurn("next"))
        #expect(agent.transports.count == 2)
        #expect(agent.requests("session/load").last?["sessionId"] == "sess-1")
        #expect(agent.requests("session/prompt").count == 2)
    }

    @Test func interruptEndsTheTurnWhenTheAgentNeverConfirms() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor())
        session.cancelTimeout = 0.05
        try await session.start()
        try await session.send(acpTurn("hang"))
        session.interrupt()
        session.interrupt()
        await acpWaitUntil { !log.completions.isEmpty }
        agent.finishPrompt()
        await acpSettle()
        #expect(log.completions == [.interrupted])
        #expect(agent.transports[0].isTerminated)
    }

    @Test func interruptWhileSettingUpTheTurnSkipsThePrompt() async throws {
        let agent = ACPFakeAgent()
        agent.sessionResult = json(
            #"{"sessionId":"sess-1","configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"a","options":[{"value":"a","name":"A"},{"value":"b","name":"B"}]}]}"#
        )
        var pendingSet: JSONValue?
        agent.handlers["session/set_config_option"] = { id, _ in pendingSet = id }
        let (session, log) = makeSession(agent)
        try await session.start()

        async let sent: Void = session.send(acpTurn("hi", model: "b"))
        await acpWaitUntil { pendingSet != nil }
        session.interrupt()
        agent.reply(try #require(pendingSet), [:])
        try await sent

        #expect(log.completions == [.interrupted])
        #expect(agent.requests("session/prompt").isEmpty)
        #expect(!agent.transport.isTerminated)
    }

    @Test func crashDuringATurnFailsItAndReportsTheExit() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("go"))
        agent.transport.exit(status: 101, stderr: "\u{1B}[31mthread 'main' panicked\u{1B}[0m\nboom\n")
        await acpWaitUntil { log.events.contains { if case .sessionExited = $0 { true } else { false } } }

        guard case .failed(let message) = log.completions.first else {
            Issue.record("Expected a failed turn, got \(log.completions)")
            return
        }
        #expect(message.contains("status 101"))
        #expect(message.contains("thread 'main' panicked\nboom"))
        #expect(log.completions.count == 1)
        #expect(log.events.last == .sessionExited(error: message))
    }

    @Test func shutdownStopsTheProcessQuietly() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("go"))
        log.removeAll()
        session.shutdown()
        agent.finishPrompt()
        await acpSettle()
        #expect(agent.transport.isTerminated)
        #expect(log.events.isEmpty)
        await #expect(throws: AgentError.self) { try await session.send(acpTurn("again")) }
    }

    // MARK: Model, effort and modes

    @Test func modelAndEffortUseConfigOptions() async throws {
        let agent = ACPFakeAgent()
        agent.sessionResult = json(
            """
            {"sessionId":"sess-1","configOptions":[
            {"id":"model","name":"Model","category":"model","type":"select","currentValue":"grok-4.7","options":[{"value":"grok-4.7","name":"Grok 4.7"},{"value":"grok-4.6","name":"Grok 4.6"}]},
            {"id":"reasoning_effort","name":"Effort","category":"thought_level","type":"select","currentValue":"high","options":[{"value":"low","name":"Low"},{"value":"high","name":"High"}]}]}
            """)
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("hi", model: "grok-4.6", effort: "low"))

        let calls = agent.requests("session/set_config_option")
        #expect(calls.map { $0["configId"] } == ["model", "reasoning_effort"])
        #expect(calls.map { $0["value"] } == ["grok-4.6", "low"])
        #expect(log.events.contains(.modelResolved("grok-4.6")))

        agent.finishPrompt()
        await acpWaitUntil { !log.completions.isEmpty }
        try await session.send(acpTurn("again", model: "grok-4.6", effort: "low"))
        #expect(agent.requests("session/set_config_option").count == 2)
    }

    @Test func grokLegacyModelSelectionCarriesTheEffort() async throws {
        let agent = ACPFakeAgent()
        agent.sessionResult = [
            "sessionId": "sess-1",
            "models": [
                "currentModelId": "grok-4.7",
                "availableModels": [
                    ["modelId": "grok-4.7", "name": "Grok 4.7", "_meta": ["reasoningEffort": "high"]],
                    ["modelId": "grok-4.6", "name": "Grok 4.6"],
                ],
            ],
        ]
        let (session, log) = makeSession(agent)
        try await session.start()

        try await session.send(acpTurn("one", model: "grok-build"))
        #expect(agent.requests("session/set_model").isEmpty)
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 1 }

        try await session.send(acpTurn("two", model: "grok-4.6", effort: "xhigh"))
        #expect(
            agent.requests("session/set_model").last
                == ["sessionId": "sess-1", "modelId": "grok-4.6", "_meta": ["reasoningEffort": "xhigh"]])
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 2 }

        try await session.send(acpTurn("three", model: "grok-4.6", effort: "xhigh"))
        #expect(agent.requests("session/set_model").count == 1)
    }

    @Test func rejectedModelsFailTheTurnWithAClearMessage() async throws {
        let agent = ACPFakeAgent()
        agent.sessionResult = json(
            #"{"sessionId":"sess-1","configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"a","options":[{"value":"a","name":"A"}]}]}"#
        )
        agent.handlers["session/set_config_option"] = { id, _ in agent.fail(id, code: ACPError.invalidParams, message: "bad model") }
        let (session, _) = makeSession(agent)
        try await session.start()
        do {
            try await session.send(acpTurn("hi", model: "custom-model"))
            Issue.record("Expected the model to be rejected")
        } catch {
            #expect(error.localizedDescription.contains("custom-model"))
        }
    }

    @Test func accessModeChangeRestartsGrokAndResumes() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("one"))
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 1 }

        try await session.send(acpTurn("two", accessMode: .fullAccess))
        #expect(agent.transports.count == 2)
        #expect(agent.transports[0].isTerminated)
        #expect(agent.transport.arguments == ["agent", "--always-approve", "stdio"])
        #expect(agent.requests("session/load").first?["sessionId"] == "sess-1")
        #expect(log.sessionIDs == ["sess-1", "sess-1"])
    }

    @Test func planModeUsesTheAgentsPlanMode() async throws {
        let agent = ACPFakeAgent()
        agent.sessionResult = json(
            """
            {"sessionId":"sess-1","modes":{"currentModeId":"code","availableModes":[{"id":"ask","name":"Ask"},
            {"id":"architect","name":"Architect"},{"id":"code","name":"Code"}]}}
            """)
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor())
        try await session.start()
        try await session.send(acpTurn("design it", interactionMode: .plan))
        #expect(agent.requests("session/set_mode").last?["modeId"] == "architect")
        #expect(agent.requests("session/prompt").last?.at("prompt") == [["type": "text", "text": "design it"]])
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 1 }

        try await session.send(acpTurn("build it"))
        #expect(agent.requests("session/set_mode").last?["modeId"] == "code")
    }

    @Test func planModeFallsBackToThePlanCommandOrAnInstruction() async throws {
        let grok = ACPFakeAgent()
        let (session, log) = makeSession(grok)
        try await session.start()
        try await session.send(acpTurn("add caching", interactionMode: .plan))
        #expect(grok.requests("session/prompt").last?.at("prompt") == [["type": "text", "text": "/plan add caching"]])
        grok.finishPrompt()
        await acpWaitUntil { log.completions.count == 1 }

        let plain = ACPFakeAgent()
        let (other, _) = makeSession(plain, flavor: ACPPlainFlavor())
        try await other.start()
        try await other.send(acpTurn("add caching", interactionMode: .plan))
        let text = plain.requests("session/prompt").last?.at("prompt")?[0]?["text"]?.string
        #expect(text?.hasPrefix("[Plan mode]") == true)
        #expect(text?.hasSuffix("add caching") == true)
    }

    // MARK: Grok extensions

    @Test func grokExitPlanModeCapturesThePlan() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("plan it", interactionMode: .plan))
        agent.ask(
            21, "_x.ai/exit_plan_mode", ["sessionId": "sess-1", "toolCallId": "tc", "planContent": "# Plan\n\n1. Add a cache"])
        await acpWaitUntil { agent.answers[21] != nil }
        #expect(log.events.contains(.plan(text: "# Plan\n\n1. Add a cache")))
        #expect(agent.answers[21]?.at("result.outcome") == "abandoned")
    }

    @Test func grokQuestionsAreAskedOneAtATime() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent, launch: acpLaunch(accessMode: .fullAccess))
        try await session.start()
        try await session.send(acpTurn("set it up", accessMode: .fullAccess))
        agent.ask(
            22, "x.ai/ask_user_question",
            [
                "sessionId": "sess-1", "toolCallId": "q1", "mode": "default",
                "questions": [
                    ["question": "Which database?", "options": [["label": "Postgres"], ["label": "SQLite", "description": "File based"]]],
                    ["question": "Add tests?", "options": [["label": "Yes"], ["label": "No"]]],
                ],
            ])
        await acpWaitUntil { log.approvals.count == 1 }
        #expect(log.approvals[0].title == "Which database?")
        #expect(log.approvals[0].options.map(\.label) == ["Postgres", "SQLite", "Cancel"])
        #expect(log.approvals[0].detail == "File based")

        session.respond(to: log.approvals[0].id, optionID: "SQLite")
        #expect(log.approvals.count == 2)
        session.respond(to: log.approvals[1].id, optionID: "Yes")
        #expect(
            agent.answers[22]?["result"] == ["outcome": "accepted", "answers": ["Which database?": ["SQLite"], "Add tests?": ["Yes"]]])
    }

    @Test func grokTurnCompletedNotificationEndsTheTurnWithUsage() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("go"))
        let promptID = try #require(agent.requests("session/prompt").first?.at("_meta.promptId"))

        agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Done"]], meta: ["totalTokens": 1_200])
        agent.notify(
            "_x.ai/session/update",
            [
                "sessionId": "sess-1",
                "update": [
                    "sessionUpdate": "turn_completed", "prompt_id": promptID, "stop_reason": "end_turn",
                    "usage": ["inputTokens": 1_000, "outputTokens": 50, "cachedReadTokens": 800, "costUsdTicks": 150_000_000],
                ],
            ])
        await acpWaitUntil { !log.completions.isEmpty }
        #expect(log.completions == [.completed])
        #expect(
            log.events.contains(.usage(TokenUsage(inputTokens: 1_200, outputTokens: 50, cachedInputTokens: 800, costUSD: 0.015))))

        // The prompt response that follows does not end the turn twice.
        agent.finishPrompt()
        await acpSettle()
        #expect(log.completions.count == 1)
    }

    @Test func grokRateLimitStopReasonFailsTheTurn() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("go"))
        let promptID = try #require(agent.requests("session/prompt").first?.at("_meta.promptId"))
        agent.notify("x.ai/session/prompt_complete", ["sessionId": "sess-1", "promptId": promptID, "stopReason": "rate_limit"])
        await acpWaitUntil { !log.completions.isEmpty }
        #expect(log.completions == [.failed("Grok usage limit reached. Try again later.")])
    }

    @Test func unknownExtensionRequestsGetMethodNotFound() async throws {
        let agent = ACPFakeAgent()
        let (session, _) = makeSession(agent)
        try await session.start()
        agent.ask(30, "_vendor/do_something", [:])
        agent.ask(31, "fs/read_text_file", ["sessionId": "sess-1", "path": "/etc/hosts"])
        await acpWaitUntil { agent.answers[31] != nil }
        #expect(agent.answers[30]?.at("error.code") == -32601)
        // Grok does not get the client file system.
        #expect(agent.answers[31]?.at("error.code") == -32601)
    }

    // MARK: Antigravity

    @Test func antigravitySignsInFirstResumesAndUsesModes() async throws {
        let agent = ACPFakeAgent()
        agent.initializeResult = json(
            #"{"protocolVersion":2,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true},"sessionCapabilities":{"resume":{}}},"authMethods":[{"id":"oauth-personal","name":"Log in with Google"}]}"#
        )
        agent.loadResult = json(
            """
            {"configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"gemini-high","options":[{"value":"gemini-low","name":"Gemini Low"},{"value":"gemini-high","name":"Gemini High"}]},
            {"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"default","options":[{"value":"default","name":"Default"},{"value":"auto_edit","name":"Auto edit"},{"value":"yolo","name":"YOLO"}]}]}
            """)
        let launch = acpLaunch(
            .antigravity, resume: "ag-1", accessMode: .fullAccess, environment: ["GEMINI_API_KEY": "secret", "PATH": "/usr/bin"])
        let (session, log) = makeSession(agent, flavor: AntigravityFlavor(), launch: launch)
        try await session.start()

        #expect(agent.requests.map(\.method).prefix(3) == ["initialize", "authenticate", "session/resume"])
        #expect(agent.requests("authenticate").first?["methodId"] == "oauth-personal")
        #expect(agent.requests("session/load").isEmpty)
        let environment = agent.transport.environment
        #expect(environment["GEMINI_API_KEY"] == nil)
        #expect(environment["ANTIGRAVITY_HARNESS_PATH"]?.hasSuffix("/localharness_external") == true)
        #expect(environment["TMPDIR"]?.contains("Coincide-antigravity") == true)
        #expect(log.sessionIDs == ["ag-1"])

        try await session.send(acpTurn("hi", .antigravity, model: "antigravity-default", accessMode: .fullAccess))
        #expect(agent.requests("session/set_config_option").first == ["sessionId": "ag-1", "configId": "mode", "value": "yolo"])

        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 1 }
        await #expect(throws: AgentError.self) {
            try await session.send(acpTurn("hi", .antigravity, model: "gemini-ultra", accessMode: .fullAccess))
        }
        session.shutdown()
    }

    @Test func antigravitySignInLinkBecomesANotice() async throws {
        let agent = ACPFakeAgent()
        agent.handlers["authenticate"] = { id, _ in
            agent.transport.deliver(
                "Open the following link to authenticate the ACP server: https://accounts.google.com/o/oauth2/v2/auth?state=abc")
            agent.reply(id, [:])
        }
        let (session, log) = makeSession(agent, flavor: AntigravityFlavor(), launch: acpLaunch(.antigravity))
        try await session.start()
        #expect(log.notices.count == 1)
        #expect(log.notices.first?.contains("https://accounts.google.com/o/oauth2/v2/auth?state=abc") == true)
        session.shutdown()
    }

    @Test func antigravityQuestionsAlwaysAsk() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(
            agent, flavor: AntigravityFlavor(), launch: acpLaunch(.antigravity, accessMode: .fullAccess))
        try await session.start()
        try await session.send(acpTurn("go", .antigravity, accessMode: .fullAccess))
        agent.ask(
            40, "session/request_permission",
            permission(
                ["toolCallId": "interaction_7", "title": "Which file should I start with?"],
                options: [("opt-a", "allow_once"), ("opt-b", "allow_once")]))
        await acpWaitUntil { !log.approvals.isEmpty }
        #expect(log.approvals[0].title == "Which file should I start with?")
        #expect(log.approvals[0].options.map(\.id) == ["opt-a", "opt-b", ACPApprovals.cancelOptionID])
        session.respond(to: log.approvals[0].id, optionID: "opt-b")
        #expect(agent.answers[40]?.at("result.outcome.optionId") == "opt-b")
        #expect(!log.events.contains { if case .toolCompleted = $0 { true } else { false } })
        session.shutdown()
    }

    @Test func antigravityServesFilesInsideTheWorkspace() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "line1\nline2\nline3".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let agent = ACPFakeAgent()
        let (session, _) = makeSession(agent, flavor: AntigravityFlavor(), launch: acpLaunch(.antigravity, directory: directory))
        try await session.start()
        #expect(agent.requests("initialize").first?.at("clientCapabilities.fs.writeTextFile") == true)

        agent.ask(50, "fs/read_text_file", ["sessionId": "sess-1", "path": .string(directory.path + "/notes.txt"), "line": 2, "limit": 1])
        agent.ask(51, "fs/read_text_file", ["sessionId": "sess-1", "path": "/etc/hosts"])
        agent.ask(52, "fs/write_text_file", ["sessionId": "sess-1", "path": .string(directory.path + "/sub/new.txt"), "content": "x"])
        await acpWaitUntil { agent.answers[52] != nil }
        #expect(agent.answers[50]?.at("result.content") == "line2")
        #expect(agent.answers[51]?.at("error.code") == -32602)
        #expect(try String(contentsOf: directory.appendingPathComponent("sub/new.txt"), encoding: .utf8) == "x")
        session.shutdown()
    }

    // MARK: Prompt content

    @Test func imagesAreSentInline() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let agent = ACPFakeAgent()
        let (session, _) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("what is this?", images: [image.path]))
        #expect(
            agent.requests("session/prompt").last?["prompt"]
                == [["type": "text", "text": "what is this?"], ["type": "image", "mimeType": "image/png", "data": "iVBORw=="]])

        // Agents without image prompts get the path instead.
        let plain = ACPFakeAgent()
        let (other, _) = makeSession(plain, flavor: ACPPlainFlavor())
        try await other.start()
        try await other.send(acpTurn("what is this?", images: [image.path]))
        #expect(
            plain.requests("session/prompt").last?["prompt"]
                == [["type": "text", "text": .string("what is this?\n\n[Attached image: \(image.path)]")]])
    }

    @Test func v2AgentsFinishPromptsWithAnIdleUpdate() async throws {
        let agent = ACPFakeAgent()
        agent.initializeResult = json(#"{"protocolVersion":2,"info":{"name":"v2-agent","version":"1"},"capabilities":{"session":{}}}"#)
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor())
        try await session.start()
        try await session.send(acpTurn("hi"))
        agent.finishPrompt()
        await acpSettle()
        #expect(log.completions.isEmpty)
        agent.update(["sessionUpdate": "state_update", "state": "idle", "stopReason": "end_turn"])
        await acpWaitUntil { !log.completions.isEmpty }
        #expect(log.completions == [.completed])
    }

    // MARK: Real process

    /// A tiny ACP agent in shell, so the stdio transport runs end to end.
    @Test func runsARealAgentProcess() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-agent")
        try #"""
            #!/bin/sh
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/^{"id":\([0-9]*\),.*/\1/p')
              case "$line" in
                *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{}}}\n' "$id" ;;
                *'"method":"session/new"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"shell-1"}}\n' "$id" ;;
                *'"method":"session/prompt"'*)
                  printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"shell-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"pong"}}}}\n'
                  printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id" ;;
              esac
            done
            """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let launch = AgentLaunch(
            provider: .grok, executable: script, environment: ["PATH": "/usr/bin:/bin"], workingDirectory: directory,
            resumeSessionID: nil, selection: ModelSelection(provider: .grok, modelID: "default"), accessMode: .fullAccess,
            interactionMode: .build)
        let session = ACPSession(launch: launch, flavor: ACPPlainFlavor())
        let log = ACPEventLog()
        log.attach(session)
        defer { session.shutdown() }

        try await session.start()
        #expect(session.sessionID == "shell-1")
        try await session.send(acpTurn("ping", accessMode: .fullAccess))
        await acpWaitUntil(timeout: .seconds(5)) { !log.completions.isEmpty }
        #expect(log.events.contains(.assistantText(itemID: "assistant-1-1", text: "pong")))
        #expect(log.completions == [.completed])
    }
}
