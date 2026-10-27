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

    private func promptText(_ agent: ACPFakeAgent, _ index: Int = -1) -> String? {
        let prompts = agent.requests("session/prompt")
        guard !prompts.isEmpty else { return nil }
        let prompt = prompts[index < 0 ? prompts.count + index : index]
        return prompt["prompt"]?[0]?["text"]?.string
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
        // Like T3 Code, Coincide takes session notices and form elicitations.
        #expect(initialize.at("clientCapabilities.session.notices") == [:])
        #expect(initialize.at("clientCapabilities.elicitation.form") == [:])
        #expect(initialize["_meta"] == ["clientType": "extension"])
        #expect(initialize.at("clientInfo.name") == "coincide")
        #expect(agent.requests("session/new").first?["cwd"] == .string(launch.workingDirectory.path))
        #expect(agent.requests("session/new").first?["mcpServers"] == [])
        #expect(agent.transport.arguments == ["--permission-mode", "default", "agent", "stdio"])
        #expect(log.events.contains(.modelResolved("grok-4.7")))
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

    @Test func loadEndsOnceTheReplayGoesQuietEvenWithoutAnAnswer() async throws {
        let agent = ACPFakeAgent()
        agent.handlers["session/load"] = { _, _ in
            agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "replayed"]], session: "old-2")
            agent.update(
                [
                    "sessionUpdate": "config_option_update",
                    "configOptions": [
                        [
                            "id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "m1",
                            "options": [["value": "m1", "name": "M1"]],
                        ]
                    ],
                ], session: "old-2")
        }
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor(), launch: acpLaunch(resume: "old-2"))
        session.replayIdleGap = 0.1
        try await session.start()

        #expect(session.sessionID == "old-2")
        #expect(log.sessionIDs == ["old-2"])
        #expect(!log.events.contains { if case .assistantTextDelta = $0 { true } else { false } })
        // Configuration sent during the replay is kept.
        #expect(log.events.contains(.modelResolved("m1")))
    }

    @Test func resumeUnderANewIDContinuesTheSession() async throws {
        let agent = ACPFakeAgent()
        agent.initializeResult = json(#"{"protocolVersion":1,"agentCapabilities":{"loadSession":false,"sessionCapabilities":{"resume":{}}}}"#)
        agent.loadResult = ["sessionId": "forked-1"]
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor(), launch: acpLaunch(resume: "old-3"))
        try await session.start()
        #expect(agent.requests("session/resume").first?["sessionId"] == "old-3")
        #expect(session.sessionID == "forked-1")
        #expect(log.events.contains(.sessionContinued(id: "forked-1")))
        #expect(log.sessionIDs.isEmpty)
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

    @Test func signInUsesOnlyMethodsTheAgentCanRunByItself() async throws {
        // The configured method must be one the agent lists.
        let unlisted = ACPFakeAgent()
        unlisted.initializeResult = json(#"{"protocolVersion":1,"authMethods":[{"id":"cached_token","name":"Cached"}]}"#)
        unlisted.handlers["session/new"] = { id, _ in unlisted.fail(id, code: ACPError.authRequired, message: "Authentication required") }
        let (first, _) = makeSession(unlisted, launch: acpLaunch(environment: ["XAI_API_KEY": "key"]))
        await #expect(throws: ACPError.self) { try await first.start() }
        #expect(unlisted.requests("authenticate").isEmpty)

        // Without a configured method, the first agent-driven one is used; terminal sign-in is skipped.
        let agent = ACPFakeAgent()
        agent.initializeResult = json(
            #"{"protocolVersion":1,"authMethods":[{"id":"cli","name":"CLI","type":"terminal"},{"id":"browser","name":"Browser"}]}"#)
        var attempts = 0
        agent.handlers["session/new"] = { id, _ in
            attempts += 1
            if attempts == 1 { agent.fail(id, code: ACPError.authRequired, message: "Authentication required") } else {
                agent.reply(id, ["sessionId": "sess-1"])
            }
        }
        let (second, _) = makeSession(agent, flavor: ACPPlainFlavor())
        try await second.start()
        #expect(agent.requests("authenticate").map { $0["methodId"] } == ["browser"])

        // Flavors can opt out, so an agent never opens a browser sign-in on its own.
        let quiet = ACPFakeAgent()
        quiet.initializeResult = json(#"{"protocolVersion":1,"authMethods":[{"id":"browser","name":"Browser"}]}"#)
        quiet.handlers["session/new"] = { id, _ in quiet.fail(id, code: ACPError.authRequired, message: "Authentication required") }
        let (third, _) = makeSession(quiet, flavor: ACPPlainFlavor(signsInWhenRequired: false))
        await #expect(throws: ACPError.self) { try await third.start() }
        #expect(quiet.requests("authenticate").isEmpty)
    }

    @Test func failedHandshakeStopsTheProcess() async throws {
        let agent = ACPFakeAgent()
        agent.handlers["session/new"] = { id, _ in agent.fail(id, code: -32603, message: "Internal error") }
        let (session, log) = makeSession(agent)
        await #expect(throws: ACPError.self) { try await session.start() }
        #expect(agent.transport.isTerminated)
        #expect(log.events.isEmpty)
    }

    @Test func configurationSentBeforeTheSessionAnswerIsKept() async throws {
        let agent = ACPFakeAgent()
        agent.handlers["session/new"] = { id, _ in
            agent.update(["sessionUpdate": "current_mode_update", "currentModeId": "yolo"])
            agent.reply(id, json(#"{"sessionId":"sess-1","modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"},{"id":"yolo","name":"YOLO"}]}}"#))
        }
        let (session, _) = makeSession(agent, flavor: AntigravityFlavor(), launch: acpLaunch(.antigravity, accessMode: .fullAccess))
        try await session.start()
        // The agent already reported yolo, so full access needs no mode change.
        try await session.send(acpTurn("go", .antigravity, accessMode: .fullAccess))
        #expect(agent.requests("session/set_mode").isEmpty)
        session.shutdown()
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
        #expect(prompt["prompt"] == [["type": "text", "text": .string(acpInstructed("Reply with exactly: pong"))]])
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

    @Test func interactionModeInstructionsTravelOnceAndOnChange() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor())
        try await session.start()
        let turns: [(String, InteractionMode)] = [
            ("one", .build), ("two", .build), ("three", .plan), ("four", .plan), ("/compact", .build), ("six", .build),
        ]
        for (index, (text, mode)) in turns.enumerated() {
            try await session.send(acpTurn(text, interactionMode: mode))
            agent.finishPrompt()
            await acpWaitUntil { log.completions.count == index + 1 }
        }
        #expect(promptText(agent, 0) == acpInstructed("one"))
        #expect(promptText(agent, 1) == "two")
        #expect(promptText(agent, 2) == acpInstructed("three", .plan))
        #expect(promptText(agent, 2)?.contains("do not edit files") == true)
        #expect(promptText(agent, 3) == "four")
        // Native slash commands stay at the start of the prompt.
        #expect(promptText(agent, 4) == "/compact")
        #expect(promptText(agent, 5) == acpInstructed("six"))
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

    @Test func noticesAndCompactionAreShown() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor())
        try await session.start()
        try await session.send(acpTurn("go"))
        agent.update(["sessionUpdate": "notice", "severity": "warning", "title": "Context almost full", "description": "Compacting soon"])
        agent.update(["sessionUpdate": "compaction_update", "compactionId": "c1", "status": "completed", "summary": [["type": "text", "text": "Summary"]]])
        agent.finishPrompt()
        await acpWaitUntil { !log.completions.isEmpty }
        #expect(log.notices == ["Context almost full\nCompacting soon"])
        #expect(log.events.contains(.toolCompleted(id: "compaction-c1", status: .completed, output: "Summary")))
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

    @Test func permissionsOutsideATurnAreCancelled() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        agent.ask(10, "session/request_permission", permission(["toolCallId": "bg", "kind": "execute", "rawInput": ["command": "ls"]]))
        await acpWaitUntil { agent.answers[10] != nil }
        #expect(agent.answers[10]?.at("result.outcome") == ["outcome": "cancelled"])
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
        // The withdrawn request still gets its answer, as JSON-RPC expects.
        #expect(agent.answers[12]?.at("error.code") == -32800)
    }

    @Test func terminalsNeedACommandApprovalInApprovalMode() async throws {
        let agent = ACPFakeAgent()
        let flavor = ACPPlainFlavor(capabilities: ACPClientCapabilities(terminal: true))
        let (session, log) = makeSession(agent, flavor: flavor, launch: acpLaunch(environment: ["PATH": "/usr/bin:/bin"]))
        defer { session.shutdown() }
        try await session.start()
        #expect(agent.requests("initialize").first?.at("clientCapabilities.terminal") == true)
        try await session.send(acpTurn("run it"))

        agent.ask(60, "terminal/create", ["sessionId": "sess-1", "command": "/bin/echo", "args": ["hi"]])
        await acpWaitUntil { agent.answers[60] != nil }
        #expect(agent.answers[60]?.at("error.code") == -32603)

        agent.ask(
            61, "session/request_permission",
            permission(["toolCallId": "t", "kind": "execute", "rawInput": ["command": "echo hi"]], options: [("ok", "allow_once"), ("no", "reject_once")]))
        await acpWaitUntil { !log.approvals.isEmpty }
        session.respond(to: log.approvals[0].id, optionID: "ok")
        agent.ask(62, "terminal/create", ["sessionId": "sess-1", "command": "/bin/echo", "args": ["hi"]])
        await acpWaitUntil { agent.answers[62] != nil }
        #expect(agent.answers[62]?.at("result.terminalId")?.string?.isEmpty == false)
    }

    // MARK: Questions and elicitations

    @Test func grokQuestionsAreAskedTogether() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent, launch: acpLaunch(accessMode: .fullAccess))
        try await session.start()
        try await session.send(acpTurn("set it up", accessMode: .fullAccess))
        // As recorded from Grok: the params arrive wrapped with their method.
        agent.ask(
            22, "_x.ai/ask_user_question",
            [
                "method": "x.ai/ask_user_question",
                "params": [
                    "sessionId": "sess-1", "toolCallId": "q1", "mode": "default",
                    "questions": [
                        [
                            "id": "db", "question": "Which database?", "multiSelect": nil,
                            "options": [["label": "Postgres"], ["label": "SQLite", "description": "File based", "preview": "sqlite3"]],
                        ],
                        ["question": "Which checks?", "multiSelect": true, "options": [["label": "Lint"], ["label": "Tests"]]],
                        ["question": "Anything else?", "options": []],
                    ],
                ],
            ])
        await acpWaitUntil { !log.questions.isEmpty }
        #expect(log.approvals.isEmpty)
        let request = log.questions[0]
        #expect(request.questions.map(\.id) == ["db", "Which checks?", "Anything else?"])
        #expect(request.questions.map(\.prompt) == ["Which database?", "Which checks?", "Anything else?"])
        #expect(request.questions[0].options.map(\.label) == ["Postgres", "SQLite"])
        #expect(request.questions[0].options[1].detail == "File based")
        #expect(request.questions.map(\.allowsMultipleSelection) == [false, true, false])
        #expect(request.questions[2].options.map(\.label) == ["OK"])

        session.answer(userInput: request.id, answers: ["db": ["SQLite"], "Which checks?": ["Lint", "Tests", "Format too"]])
        #expect(
            agent.answers[22]?["result"]
                == [
                    "outcome": "accepted",
                    "answers": ["Which database?": ["SQLite"], "Which checks?": ["Lint", "Tests"]],
                    "annotations": ["Which database?": ["preview": "sqlite3"], "Which checks?": ["notes": "Format too"]],
                ])
    }

    @Test func dismissedGrokQuestionsAnswerCancelled() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("go"))
        agent.ask(23, "x.ai/ask_user_question", ["sessionId": "sess-1", "toolCallId": "q", "questions": [["question": "Proceed?", "options": [["label": "Yes"]]]]])
        await acpWaitUntil { !log.questions.isEmpty }
        session.answer(userInput: log.questions[0].id, answers: [:])
        #expect(agent.answers[23]?["result"] == ["outcome": "cancelled"])

        // Questions still open when the turn ends are answered and resolved.
        agent.ask(24, "x.ai/ask_user_question", ["sessionId": "sess-1", "toolCallId": "q2", "questions": [["question": "Again?", "options": []]]])
        await acpWaitUntil { log.questions.count == 2 }
        agent.finishPrompt()
        await acpWaitUntil { !log.completions.isEmpty }
        #expect(agent.answers[24]?["result"] == ["outcome": "cancelled"])
        #expect(log.events.contains(.userInputResolved(id: log.questions[1].id)))
    }

    @Test func elicitationFormsBecomeQuestions() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor())
        try await session.start()
        try await session.send(acpTurn("configure"))
        let form: JSONValue = [
            "sessionId": "sess-1", "mode": "form", "message": "Choose the fixture preference.",
            "requestedSchema": [
                "type": "object",
                "properties": [
                    "preference": [
                        "type": "string", "title": "Fixture", "description": "Strict schemas or UI flexibility?",
                        "enum": ["Strict schemas (Recommended)", "UI flexibility"],
                    ],
                    "confirm": ["type": "boolean", "title": "Confirm"],
                    "retries": ["type": "integer", "description": "How many retries?"],
                    "targets": ["type": "array", "items": ["anyOf": [["const": "ios", "title": "iOS"], ["const": "mac", "title": "macOS"]]]],
                    "note": ["type": "string"],
                ],
                "required": ["preference"],
            ],
        ]
        agent.ask(70, "elicitation/create", form)
        await acpWaitUntil { !log.questions.isEmpty }
        let request = log.questions[0]
        #expect(request.title == "Choose the fixture preference.")
        #expect(request.questions.map(\.id) == ["preference", "confirm", "note", "retries", "targets"])
        #expect(request.questions[0].header == "Fixture")
        #expect(request.questions[0].prompt == "Strict schemas or UI flexibility?")
        #expect(request.questions[0].allowsFreeText == false)
        #expect(request.questions[2].allowsFreeText)
        #expect(request.questions[4].allowsMultipleSelection)
        #expect(request.questions[4].options.map(\.label) == ["iOS", "macOS"])

        session.answer(
            userInput: request.id,
            answers: [
                "preference": ["Strict schemas (Recommended)"], "confirm": ["Yes"], "retries": ["3"], "targets": ["macOS", "iOS"],
                "note": ["Keep it short"],
            ])
        #expect(
            agent.answers[70]?["result"]
                == [
                    "action": "accept",
                    "content": [
                        "preference": "Strict schemas (Recommended)", "confirm": true, "retries": 3, "targets": ["mac", "ios"],
                        "note": "Keep it short",
                    ],
                ])

        // The older method nests the action; dismissing cancels.
        agent.ask(71, "session/elicitation", form)
        await acpWaitUntil { log.questions.count == 2 }
        session.answer(userInput: log.questions[1].id, answers: [:])
        #expect(agent.answers[71]?["result"] == ["action": ["action": "cancel"]])

        // URL elicitations are not supported, and nothing is asked outside a turn.
        agent.ask(72, "elicitation/create", ["sessionId": "sess-1", "mode": "url", "message": "Sign in", "elicitationId": "e", "url": "https://example.com"])
        await acpWaitUntil { agent.answers[72] != nil }
        #expect(agent.answers[72]?["result"] == ["action": "decline"])
        agent.finishPrompt()
        await acpWaitUntil { !log.completions.isEmpty }
        agent.ask(73, "elicitation/create", form)
        await acpWaitUntil { agent.answers[73] != nil }
        #expect(agent.answers[73]?["result"] == ["action": "cancel"])
    }

    // MARK: Interrupt and crashes

    @Test func grokStopEndsTheTurnAtOnceAndReloadsNextTime() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("long task"))
        agent.ask(13, "session/request_permission", permission(["toolCallId": "x", "kind": "execute", "rawInput": ["command": "sleep 100"]]))
        await acpWaitUntil { !log.approvals.isEmpty }

        session.interrupt()
        // Like T3 Code, Grok's process is stopped instead of waiting on session/cancel.
        #expect(log.completions == [.interrupted])
        #expect(agent.answers[13]?.at("result.outcome") == ["outcome": "cancelled"])
        #expect(agent.transports[0].isTerminated)
        #expect(agent.notifications("session/cancel").isEmpty)
        session.interrupt()
        await acpSettle()
        #expect(log.completions == [.interrupted])

        try await session.send(acpTurn("next"))
        #expect(agent.transports.count == 2)
        #expect(agent.requests("session/load").last?["sessionId"] == "sess-1")
        #expect(agent.requests("session/prompt").count == 2)
    }

    @Test func cancelInterruptWaitsForTheAgent() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor())
        try await session.start()
        try await session.send(acpTurn("long task"))
        agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Working"]])
        await acpSettle()
        session.interrupt()
        #expect(agent.notifications("session/cancel").first == ["sessionId": "sess-1"])
        #expect(log.completions.isEmpty)
        agent.finishPrompt("cancelled")
        await acpWaitUntil { !log.completions.isEmpty }
        await acpSettle()
        #expect(log.completions == [.interrupted])
        #expect(log.events.contains(.assistantText(itemID: "assistant-1-1", text: "Working")))
        #expect(!agent.transports[0].isTerminated)
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

    @Test func shutdownClosesTheSessionWhenTheAgentSupportsIt() async throws {
        let agent = ACPFakeAgent()
        agent.initializeResult = json(#"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"close":{}}}}"#)
        var closeID: JSONValue?
        agent.handlers["session/close"] = { id, _ in closeID = id }
        let (session, log) = makeSession(agent)
        try await session.start()
        log.removeAll()
        session.shutdown()
        await acpWaitUntil { closeID != nil }
        #expect(agent.requests("session/close").first == ["sessionId": "sess-1"])
        #expect(!agent.transport.isTerminated)
        agent.reply(try #require(closeID), ["_meta": ["x.ai/closeOutcome": "closed"]])
        await acpWaitUntil { agent.transport.isTerminated }
        #expect(log.events.isEmpty)
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
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor())
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

    @Test func grokSelectsModelsWithSetModelAndTheEffortInMeta() async throws {
        let agent = ACPFakeAgent()
        // Grok 1.0.44 lists both the legacy models and config options; T3 Code switches with set_model.
        agent.sessionResult = json(
            """
            {"sessionId":"sess-1","models":{"currentModelId":"grok-4.7","availableModels":[
             {"modelId":"grok-4.7","name":"Grok 4.7","_meta":{"reasoningEffort":"high"}},{"modelId":"grok-4.6","name":"Grok 4.6"}]},
            "configOptions":[
            {"id":"model","name":"Model","category":"model","type":"select","currentValue":"grok-4.7","options":[{"value":"grok-4.7","name":"Grok 4.7"},{"value":"grok-4.6","name":"Grok 4.6"}]},
            {"id":"reasoning_effort","name":"Reasoning Effort","category":"thought_level","type":"select","currentValue":"high","options":[{"value":"xhigh","name":"Extra High"},{"value":"high","name":"High"}]}]}
            """)
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
        #expect(agent.requests("session/set_config_option").isEmpty)
        #expect(log.events.contains(.modelResolved("grok-4.6")))
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 2 }

        try await session.send(acpTurn("three", model: "grok-4.6", effort: "xhigh"))
        #expect(agent.requests("session/set_model").count == 1)
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 3 }

        // A new effort alone keeps the model.
        try await session.send(acpTurn("four", model: "grok-4.6", effort: "high"))
        #expect(agent.requests("session/set_model").last?["modelId"] == "grok-4.6")
        #expect(agent.requests("session/set_model").last?.at("_meta.reasoningEffort") == "high")
    }

    @Test func rejectedModelsFailTheTurnWithAClearMessage() async throws {
        let agent = ACPFakeAgent()
        agent.sessionResult = json(
            #"{"sessionId":"sess-1","configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"a","options":[{"value":"a","name":"A"}]}]}"#
        )
        agent.handlers["session/set_config_option"] = { id, _ in agent.fail(id, code: ACPError.invalidParams, message: "bad model") }
        let (session, _) = makeSession(agent, flavor: ACPPlainFlavor())
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
        // The reloaded session already heard the build-mode instructions.
        #expect(promptText(agent) == "two")
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
        #expect(promptText(agent) == acpInstructed("design it", .plan))
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 1 }

        try await session.send(acpTurn("build it"))
        #expect(agent.requests("session/set_mode").last?["modeId"] == "code")
        #expect(promptText(agent)?.contains("interaction mode: Default") == true)
    }

    @Test func planModeSwitchesModeOptionsAndRestoresThem() async throws {
        let agent = ACPFakeAgent()
        agent.sessionResult = json(
            """
            {"sessionId":"sess-1","configOptions":[
            {"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"agent","options":[{"value":"agent","name":"Agent"},{"value":"plan","name":"Plan"}]},
            {"id":"collab","name":"Collaboration","category":"collaboration_mode","type":"select","currentValue":"default","options":[{"value":"default","name":"Default"},{"value":"plan","name":"Plan"}]}]}
            """)
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor())
        try await session.start()
        try await session.send(acpTurn("plan it", interactionMode: .plan))
        #expect(Set(agent.requests("session/set_config_option").map { "\($0["configId"]?.string ?? "")=\($0["value"]?.string ?? "")" }) == ["mode=plan", "collab=plan"])
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 1 }

        try await session.send(acpTurn("do it"))
        let restored = agent.requests("session/set_config_option").suffix(2).map { "\($0["configId"]?.string ?? "")=\($0["value"]?.string ?? "")" }
        #expect(Set(restored) == ["mode=agent", "collab=default"])
    }

    @Test func leavingPlanModeKeepsTheCurrentAccessMode() async throws {
        let agent = ACPFakeAgent()
        agent.sessionResult = json(
            #"{"sessionId":"sess-1","modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"},{"id":"yolo","name":"YOLO"},{"id":"plan","name":"Plan"}]}}"#
        )
        let flavor = ACPPlainFlavor(modeForAccess: [.fullAccess: "yolo", .approval: "default"])
        let (session, log) = makeSession(agent, flavor: flavor, launch: acpLaunch(accessMode: .fullAccess))
        try await session.start()
        try await session.send(acpTurn("plan it", accessMode: .fullAccess, interactionMode: .plan))
        #expect(agent.requests("session/set_mode").map { $0["modeId"] } == ["plan"])
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 1 }

        // Back to building, now asking for approval: the session must not return to yolo.
        try await session.send(acpTurn("build it", accessMode: .approval))
        #expect(agent.requests("session/set_mode").last?["modeId"] == "default")
        #expect(!agent.requests("session/set_mode").contains { $0["modeId"] == "yolo" })
    }

    @Test func aNewerSendSupersedesOneStillSettingUp() async throws {
        let agent = ACPFakeAgent()
        agent.sessionResult = json(
            #"{"sessionId":"sess-1","configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"a","options":[{"value":"a","name":"A"},{"value":"b","name":"B"}]}]}"#
        )
        var pendingSet: JSONValue?
        agent.handlers["session/set_config_option"] = { id, _ in pendingSet = id }
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor())
        try await session.start()

        // The user stops a turn that is still setting up, the runner gives up on it, and a new
        // message follows. The stopped one must not reach the agent or end the newer turn.
        async let first: Void = session.send(acpTurn("stopped", model: "b"))
        await acpWaitUntil { pendingSet != nil }
        session.interrupt()
        async let second: Void = session.send(acpTurn("current", model: "b"))
        await acpSettle()
        agent.reply(try #require(pendingSet), [:])
        try await first
        try await second

        #expect(log.completions.isEmpty)
        #expect(agent.requests("session/prompt").count == 1)
        #expect(promptText(agent)?.contains("current") == true)
        agent.finishPrompt()
        await acpWaitUntil { !log.completions.isEmpty }
        #expect(log.completions == [.completed])
    }

    @Test func aLateLoadAnswerIsStillApplied() async throws {
        let agent = ACPFakeAgent()
        agent.handlers["session/load"] = { id, _ in
            agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "replayed"]], session: "old-4")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    agent.reply(
                        id,
                        [
                            "configOptions": [
                                [
                                    "id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "late",
                                    "options": [["value": "late", "name": "Late"], ["value": "other", "name": "Other"]],
                                ]
                            ]
                        ])
                }
            }
        }
        let (session, log) = makeSession(agent, flavor: ACPPlainFlavor(), launch: acpLaunch(resume: "old-4"))
        session.replayIdleGap = 0.05
        try await session.start()
        #expect(session.sessionID == "old-4")
        await acpWaitUntil { log.events.contains { if case .modelsDiscovered = $0 { true } else { false } } }
        let models = log.events.compactMap { if case .modelsDiscovered(let models) = $0 { models } else { nil } }.last
        #expect(models?.map(\.modelID) == ["default", "late", "other"])
    }

    @Test func grokPlanModeTravelsAsInstructions() async throws {
        let grok = ACPFakeAgent()
        let (session, _) = makeSession(grok)
        try await session.start()
        try await session.send(acpTurn("add caching", interactionMode: .plan))
        // Grok has no plan mode over ACP, so the turn carries T3 Code's plan instructions.
        #expect(promptText(grok) == acpInstructed("add caching", .plan))
        #expect(grok.requests("session/set_mode").isEmpty)
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

    @Test func grokExitPlanModeFallsBackToThePlanFile() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("plan it", interactionMode: .plan))
        let planPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.grok/sessions/abc/plan.md"
        agent.update([
            "sessionUpdate": "tool_call", "toolCallId": "w", "title": "Write", "kind": "edit", "status": "completed",
            "content": [["type": "diff", "path": .string(planPath), "oldText": nil, "newText": "# Plan from file\n"]],
        ])
        agent.ask(25, "x.ai/exit_plan_mode", ["sessionId": "sess-1", "toolCallId": "tc"])
        await acpWaitUntil { agent.answers[25] != nil }
        #expect(log.events.contains(.plan(text: "# Plan from file")))
    }

    @Test func grokTurnCompletedNotificationEndsTheTurnWithUsage() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("go"))
        let promptID = try #require(agent.requests("session/prompt").first?.at("_meta.promptId"))

        agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Done"]], meta: ["totalTokens": 1_200])
        agent.notify(
            "_x.ai/session_notification",
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

    @Test func grokPromptErrorEndsTheTurnWithTheAgentResult() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("go"))
        let promptID = try #require(agent.requests("session/prompt").first?.at("_meta.promptId"))
        // As recorded from Grok 1.0.44: completion first, then the JSON-RPC error.
        agent.notify(
            "_x.ai/session/prompt_complete",
            ["sessionId": "sess-1", "promptId": promptID, "stopReason": "error", "agentResult": "API error (status 400 Bad Request)"])
        agent.fail(try #require(agent.lastPromptID), code: -32603, message: "Internal error")
        await acpWaitUntil { !log.completions.isEmpty }
        await acpSettle()
        #expect(log.completions == [.failed("API error (status 400 Bad Request)")])
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

    @Test func grokBackgroundWakesStayOutOfTheTurn() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("go"))
        agent.update(
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "background"]],
            meta: ["promptId": "task-completed-7"])
        agent.notify(
            "_x.ai/session_notification",
            ["sessionId": "sess-1", "update": ["sessionUpdate": "turn_completed", "prompt_id": "task-completed-7", "stop_reason": "end_turn"]])
        agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "mine"]])
        agent.finishPrompt()
        await acpWaitUntil { !log.completions.isEmpty }
        #expect(log.completions == [.completed])
        #expect(log.events.contains(.assistantText(itemID: "assistant-1-1", text: "mine")))
        #expect(!log.events.contains { if case .assistantTextDelta(_, "background") = $0 { true } else { false } })
    }

    @Test func grokBackgroundWakeBetweenTurnsIsATurnOfItsOwn() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        try await session.start()
        agent.update(
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "The build finished."]],
            meta: ["promptId": "task-completed-3"])
        await acpWaitUntil { log.events.contains { if case .agentTurnStarted = $0 { true } else { false } } }
        #expect(log.events.contains(.agentTurnStarted(note: "Grok Build continued after background work finished.")))
        #expect(log.events.contains { if case .assistantTextDelta(_, "The build finished.") = $0 { true } else { false } })
        agent.notify(
            "_x.ai/session_notification",
            ["sessionId": "sess-1", "update": ["sessionUpdate": "turn_completed", "prompt_id": "task-completed-3", "stop_reason": "end_turn"]])
        await acpWaitUntil { !log.completions.isEmpty }
        #expect(log.completions == [.completed])

        // Stopping a wake ends it at once; Grok stops by restarting.
        agent.update(
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "again"]],
            meta: ["promptId": "task-completed-4"])
        await acpWaitUntil { log.events.filter { if case .agentTurnStarted = $0 { true } else { false } }.count == 2 }
        session.interrupt()
        #expect(log.completions == [.completed, .interrupted])
        // The next turn of ours is unaffected.
        try await session.send(acpTurn("go"))
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 3 }
        #expect(log.completions == [.completed, .interrupted, .completed])
    }

    @Test func grokModelUpdatesRefreshTheModels() async throws {
        let agent = ACPFakeAgent()
        agent.initializeResult = json(ACPMapperTests.grokInitialize)
        let (session, log) = makeSession(agent)
        try await session.start()
        log.removeAll()
        agent.notify("_x.ai/session_notification", ["sessionId": "sess-1", "update": ["sessionUpdate": "model_changed", "model_id": "grok-4.6", "reasoning_effort": "high"]])
        agent.notify(
            "_x.ai/models/update",
            ["currentModelId": "grok-4.6", "availableModels": [["modelId": "grok-4.6", "name": "Grok 4.6"], ["modelId": "grok-4.5", "name": "Grok 4.5"]]])
        await acpWaitUntil { log.events.contains { if case .modelsDiscovered = $0 { true } else { false } } }
        #expect(log.events.contains(.modelResolved("grok-4.6")))
        let models = log.events.compactMap { if case .modelsDiscovered(let models) = $0 { models } else { nil } }.last
        #expect(models?.map(\.modelID) == ["grok-build", "grok-4.6", "grok-4.5"])
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
        let link =
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=c&redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2F&response_type=code&scope=openid&state=abc"
        let agent = ACPFakeAgent()
        agent.handlers["authenticate"] = { id, _ in
            agent.transport.deliver("Open the following link to authenticate the ACP server: \(link)")
            // A look-alike link is never shown.
            agent.transport.deliver("Open the following link to authenticate the ACP server: https://evil.example.com/o/oauth2/v2/auth?state=x")
            agent.reply(id, [:])
        }
        let (session, log) = makeSession(agent, flavor: AntigravityFlavor(), launch: acpLaunch(.antigravity))
        try await session.start()
        #expect(log.notices.count == 1)
        #expect(log.notices.first?.contains(link) == true)
        session.shutdown()
    }

    @Test func antigravityQuestionsBecomeUserInput() async throws {
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
        await acpWaitUntil { !log.questions.isEmpty }
        #expect(log.approvals.isEmpty)
        let question = try #require(log.questions[0].questions.first)
        #expect(question.id == "interaction_7")
        #expect(question.prompt == "Which file should I start with?")
        #expect(question.options.map(\.label) == ["opt-a", "opt-b"])
        #expect(!question.allowsFreeText)
        session.answer(userInput: log.questions[0].id, answers: ["interaction_7": ["opt-b"]])
        #expect(agent.answers[40]?.at("result.outcome.optionId") == "opt-b")
        #expect(!log.events.contains { if case .toolCompleted = $0 { true } else { false } })
        session.shutdown()
    }

    @Test func antigravityApprovalsShowTheSecurityWarning() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent, flavor: AntigravityFlavor(), launch: acpLaunch(.antigravity))
        try await session.start()
        try await session.send(acpTurn("go", .antigravity))
        agent.ask(
            41, "session/request_permission",
            [
                "sessionId": "sess-1", "toolCall": ["toolCallId": "run-1", "title": "Run ls?", "kind": "execute", "rawInput": ["CommandLine": "ls"]],
                "options": [
                    ["optionId": "once", "name": "Allow", "kind": "allow_once"],
                    ["optionId": "always", "name": "Always", "kind": "allow_always", "_meta": ["agy.security.warning": ["message": "Runs any shell command."]]],
                    ["optionId": "no", "name": "Deny", "kind": "reject_once"],
                ],
            ])
        await acpWaitUntil { !log.approvals.isEmpty }
        #expect(log.approvals[0].options.map(\.label) == ["Allow once", "Allow for this thread", "Deny", "Cancel"])
        #expect(log.approvals[0].detail?.contains("Runs any shell command.") == true)
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

    @Test func imagesAreSentInlineAndNamedByPath() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let text = "what is this?\n\n[Attached image \"shot.png\" is saved at: \(image.path)]"
        let agent = ACPFakeAgent()
        let (session, _) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("what is this?", images: [image.path]))
        #expect(
            agent.requests("session/prompt").last?["prompt"]
                == [["type": "text", "text": .string(acpInstructed(text))], ["type": "image", "mimeType": "image/png", "data": "iVBORw=="]])

        // Agents without image prompts only get the path.
        let plain = ACPFakeAgent()
        let (other, _) = makeSession(plain, flavor: ACPPlainFlavor())
        try await other.start()
        try await other.send(acpTurn("what is this?", images: [image.path]))
        #expect(plain.requests("session/prompt").last?["prompt"] == [["type": "text", "text": .string(acpInstructed(text))]])

        // Antigravity takes PNG, JPEG, WebP and BMP inline, not GIF.
        let gif = directory.appendingPathComponent("anim.gif")
        try Data([0x47, 0x49, 0x46]).write(to: gif)
        #expect(ACPPrompt.imageBlock(gif.path, types: AntigravityFlavor.acceptedImageTypes) == nil)
        #expect(ACPPrompt.imageBlock(gif.path, types: ACPPrompt.commonImageTypes) != nil)
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

    /// Stopping an agent stops the commands it started.
    @Test func stoppingTheProcessStopsItsChildren() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("child.pid")
        let script = directory.appendingPathComponent("spawning-agent")
        try """
            #!/bin/sh
            sleep 60 &
            echo $! > '\(marker.path)'
            while IFS= read -r line; do :; done
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let transport = ACPProcessTransport(
            executable: script, arguments: [], workingDirectory: directory, environment: ["PATH": "/usr/bin:/bin"])
        try transport.start()
        await acpWaitUntil { (try? String(contentsOf: marker, encoding: .utf8))?.isEmpty == false }
        let child = try #require(Int32((try String(contentsOf: marker, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(child, 0) == 0)
        transport.terminate()
        await acpWaitUntil { kill(child, 0) != 0 }
    }
}
