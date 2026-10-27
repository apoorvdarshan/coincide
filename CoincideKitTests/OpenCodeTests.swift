import Foundation
import Testing

@testable import CoincideKit

// Fixtures are events and responses recorded from `opencode serve` 2.1.4, trimmed to the fields used.

private let session = "ses_e83fb9e85ffeE5kfr2BtYA7YTz"
private let message = "msg_17c0476ec001nU5NCSNnCHa3rP"

private func parse(_ lines: String) -> [JSONValue] {
    lines.split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
}

private func feed(_ mapper: inout OpenCodeEventMapper, _ lines: String) -> [OpenCodeEventMapper.Effect] {
    parse(lines).flatMap { mapper.handle($0) }
}

private func agentEvents(_ effects: [OpenCodeEventMapper.Effect]) -> [AgentEvent] {
    effects.compactMap { effect in
        if case .event(let event) = effect { return event }
        return nil
    }
}

struct OpenCodeEventMapperTests {
    private let textTurn = """
        {"type":"session.inbox.enqueued","data":{"inboxID":"msg_coincide_1","sessionID":"\(session)","item":{"type":"user","payload":{"text":"Reply with exactly: pong"},"delivery":"steer"}}}
        {"type":"session.execution.started","data":{"sessionID":"\(session)"}}
        {"type":"session.inbox.delivered","data":{"sessionID":"\(session)","inboxID":"msg_coincide_1"}}
        {"type":"session.step.started","data":{"sessionID":"\(session)","agent":"build","model":{"id":"big-pickle","providerID":"opencode","variant":"default"},"assistantMessageID":"\(message)","started":1793082029817}}
        {"type":"session.text.started","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","ordinal":0}}
        {"type":"session.text.delta","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","ordinal":0,"delta":"po"}}
        {"type":"session.text.delta","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","ordinal":0,"delta":"ng"}}
        {"type":"session.text.ended","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","ordinal":0,"text":"pong"}}
        {"type":"session.step.streamed","data":{"sessionID":"\(session)","assistantMessageID":"\(message)"}}
        {"type":"session.step.ended","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","finish":"stop","rawFinish":"stop","cost":0,"tokens":{"input":21671,"output":8,"reasoning":29,"cache":{"read":3,"write":0}}}}
        {"type":"session.usage.updated","data":{"sessionID":"\(session)","cost":0,"tokens":{"input":21671,"output":8,"reasoning":29,"cache":{"read":3,"write":0}}}}
        {"type":"session.execution.succeeded","data":{"sessionID":"\(session)"}}
        """

    @Test func streamsTextAndCompletesTheTurn() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        mapper.contextWindow = 200_000
        mapper.beginTurn(promptID: "msg_coincide_1")
        let events = agentEvents(feed(&mapper, textTurn))
        let item = "\(message):text:0"
        #expect(
            events == [
                .modelResolved("opencode/big-pickle"),
                .assistantTextDelta(itemID: item, delta: "po"),
                .assistantTextDelta(itemID: item, delta: "ng"),
                .assistantText(itemID: item, text: "pong"),
                .usage(TokenUsage(inputTokens: 21_674, outputTokens: 8, cachedInputTokens: 3, contextWindow: 200_000)),
                .turnCompleted(.completed),
            ])
        #expect(mapper.turn == nil)
        #expect(!mapper.executionRunning)
    }

    @Test func ignoresOtherSessions() {
        var mapper = OpenCodeEventMapper(sessionID: "ses_other")
        mapper.beginTurn(promptID: "msg_coincide_1")
        #expect(feed(&mapper, textTurn).isEmpty)
        #expect(mapper.turn != nil)
    }

    @Test func reportsCostWhenTheProviderCharges() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let effects = feed(
            &mapper,
            #"{"type":"session.usage.updated","data":{"sessionID":"\#(session)","cost":0.0123,"tokens":{"input":10,"output":2,"reasoning":0,"cache":{"read":0,"write":0}}}}"#)
        #expect(agentEvents(effects) == [.usage(TokenUsage(costUSD: 0.0123))])
    }

    @Test func streamsReasoning() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let effects = feed(
            &mapper,
            """
            {"type":"session.reasoning.started","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","ordinal":0}}
            {"type":"session.reasoning.delta","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","ordinal":0,"delta":"Thinking"}}
            {"type":"session.reasoning.ended","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","ordinal":0,"text":"Thinking it over"}}
            {"type":"session.text.ended","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","ordinal":1,"text":""}}
            """)
        let item = "\(message):reasoning:0"
        #expect(
            agentEvents(effects) == [
                .reasoningDelta(itemID: item, delta: "Thinking"), .reasoningText(itemID: item, text: "Thinking it over"),
            ])
    }

    @Test func shellCallWithApproval() throws {
        var mapper = OpenCodeEventMapper(sessionID: session)
        mapper.beginTurn(promptID: "msg_coincide_2")
        let tool = "205f257a-8c05-4676-bee5-af109e2f60a4"
        let started = feed(
            &mapper,
            """
            {"type":"session.execution.started","data":{"sessionID":"\(session)"}}
            {"type":"session.inbox.delivered","data":{"sessionID":"\(session)","inboxID":"msg_coincide_2"}}
            {"type":"session.tool.input.started","data":{"sessionID":"\(session)","assistantMessageID":"msg_17c04fbdd001jNNUbLKuiywlZJ","id":"\(tool)","name":"shell"}}
            {"type":"session.tool.input.ended","data":{"sessionID":"\(session)","assistantMessageID":"msg_17c04fbdd001jNNUbLKuiywlZJ","id":"\(tool)","text":"{\\"command\\": \\"echo coincide-ok\\"}"}}
            {"type":"session.tool.called","data":{"sessionID":"\(session)","assistantMessageID":"msg_17c04fbdd001jNNUbLKuiywlZJ","id":"\(tool)","input":{"command":"echo coincide-ok"},"executed":false}}
            {"type":"permission.asked","data":{"id":"per_17c05062e001X77lhYcIwKNTzh","sessionID":"\(session)","action":"shell","resources":["echo coincide-ok"],"save":["echo *"],"source":{"type":"tool","messageID":"msg_17c04fbdd001jNNUbLKuiywlZJ","id":"\(tool)"}}}
            """)
        let events = agentEvents(started)
        #expect(events.count == 3)
        #expect(events[0] == .toolStarted(ToolCallInfo(id: tool, category: .command, title: "Run command")))
        #expect(
            events[1]
                == .toolUpdated(ToolCallInfo(id: tool, category: .command, title: "Run `echo coincide-ok`", detail: "echo coincide-ok")))
        guard case .approvalRequested(let request) = events[2] else {
            Issue.record("Expected an approval request")
            return
        }
        #expect(request.id == "per_17c05062e001X77lhYcIwKNTzh")
        #expect(request.category == .command)
        #expect(request.title == "Run `echo coincide-ok`")
        #expect(request.detail == "echo coincide-ok")
        #expect(request.toolCallID == tool)
        #expect(request.options.map(\.id) == ["once", "session", "reject", "stop"])
        #expect(request.options.map(\.kind) == [.allowOnce, .allowAlways, .deny, .cancel])
        #expect(request.options[1].label == "Allow echo * this session")
        #expect(mapper.pending[request.id]?.kind == .permission(action: "shell", resources: ["echo coincide-ok"], save: ["echo *"]))

        let answered = mapper.resolve(request.id, declined: false)
        #expect(answered?.sessionID == session)
        let finished = feed(
            &mapper,
            """
            {"type":"permission.replied","data":{"sessionID":"\(session)","requestID":"per_17c05062e001X77lhYcIwKNTzh","reply":"once"}}
            {"type":"session.tool.progress","data":{"sessionID":"\(session)","assistantMessageID":"msg_17c04fbdd001jNNUbLKuiywlZJ","id":"\(tool)","metadata":{"shellID":"sh_17c0574990016UNRlXMXfYLA2r"}}}
            {"type":"session.tool.success","data":{"sessionID":"\(session)","assistantMessageID":"msg_17c04fbdd001jNNUbLKuiywlZJ","id":"\(tool)","content":[{"type":"text","text":"coincide-ok\\n"}],"metadata":{"status":"completed","truncated":false,"exit":0},"executed":false}}
            {"type":"session.execution.succeeded","data":{"sessionID":"\(session)"}}
            """)
        #expect(
            finished == [
                .watchShell(toolID: tool, shellID: "sh_17c0574990016UNRlXMXfYLA2r"),
                .unwatchShell(toolID: tool),
                .event(.toolCompleted(id: tool, status: .completed, output: "coincide-ok\n")),
                .event(.turnCompleted(.completed)),
            ])
    }

    @Test func failedCommandReportsItsExitCode() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let effects = feed(
            &mapper,
            """
            {"type":"session.tool.input.started","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"t1","name":"shell"}}
            {"type":"session.tool.success","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"t1","content":[{"type":"text","text":"ls: nope: No such file or directory\\n"}],"metadata":{"status":"completed","truncated":false,"exit":1}}}
            """)
        #expect(
            agentEvents(effects).last
                == .toolCompleted(id: "t1", status: .failed, output: "ls: nope: No such file or directory\nExit code 1"))
    }

    @Test func editShowsTheAppliedDiff() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let tool = "2ab6689f-cc96-4229-b11b-03a6d021b571"
        let patch = "Index: notes.txt\\n===================================================================\\n--- notes.txt\\n+++ notes.txt\\n@@ -1,2 +1,2 @@\\n-hello world\\n+hello coincide\\n second line\\n"
        let effects = feed(
            &mapper,
            """
            {"type":"session.tool.input.started","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"\(tool)","name":"edit"}}
            {"type":"session.tool.called","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"\(tool)","input":{"path":"notes.txt","oldString":"hello world","newString":"hello coincide"},"executed":false}}
            {"type":"session.tool.success","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"\(tool)","content":[{"type":"text","text":"Edited notes.txt (1 replacement)"}],"metadata":{"files":[{"file":"notes.txt","patch":"\(patch)","status":"modified","additions":1,"deletions":1}],"truncated":false},"executed":false}}
            """)
        let events = agentEvents(effects)
        #expect(events.count == 4)
        #expect(
            events[1]
                == .toolUpdated(
                    ToolCallInfo(
                        id: tool, category: .fileChange, title: "Edit notes.txt",
                        detail: "--- a/notes.txt\n+++ b/notes.txt\n@@ -1,1 +1,1 @@\n-hello world\n+hello coincide\n")))
        guard case .toolUpdated(let applied) = events[2] else {
            Issue.record("Expected the applied diff")
            return
        }
        #expect(applied.detail?.contains("@@ -1,2 +1,2 @@\n-hello world\n+hello coincide\n second line") == true)
        #expect(events[3] == .toolCompleted(id: tool, status: .completed, output: "Edited notes.txt (1 replacement)"))
    }

    @Test func editApprovalShowsThePendingDiff() throws {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let effects = feed(
            &mapper,
            #"""
            {"type":"permission.asked","data":{"id":"per_17c119f87001tK3ekNp7azLk5R","sessionID":"ses_e83fb9e85ffeE5kfr2BtYA7YTz","action":"edit","resources":["notes.txt"],"save":["*"],"metadata":{"files":[{"file":"notes.txt","patch":"--- notes.txt\n+++ notes.txt\n@@ -1,2 +1,2 @@\n hello coincide\n-second line\n+second coincide line\n","status":"modified","additions":1,"deletions":1}]},"source":{"type":"tool","messageID":"msg_17c119282001blvLRGHaEqmB6c","id":"6ce1b560-177b-471e-9aa8-4f298cbc0b02"}}}
            """#)
        guard case .approvalRequested(let request) = try #require(agentEvents(effects).first) else {
            Issue.record("Expected an approval request")
            return
        }
        #expect(request.category == .fileChange)
        #expect(request.title == "Edit notes.txt")
        #expect(request.detail?.hasPrefix("--- notes.txt") == true)
        #expect(request.toolCallID == nil)
        #expect(request.options[1].label == "Allow every file edit this session")
    }

    @Test func declinedCallsReportAsDeclined() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let rejected = feed(
            &mapper,
            """
            {"type":"session.tool.input.started","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"t1","name":"shell"}}
            {"type":"session.tool.failed","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"t1","error":{"type":"permission.rejected","message":"The user declined this request."},"executed":false}}
            """)
        #expect(agentEvents(rejected).last == .toolCompleted(id: "t1", status: .declined, output: "The user declined this request."))

        _ = feed(
            &mapper,
            """
            {"type":"session.tool.input.started","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"t2","name":"shell"}}
            {"type":"permission.asked","data":{"id":"per_2","sessionID":"\(session)","action":"shell","resources":["rm -rf build"],"source":{"type":"tool","messageID":"\(message)","id":"t2"}}}
            """)
        _ = mapper.resolve("per_2", declined: true)
        let stopped = feed(
            &mapper,
            #"{"type":"session.tool.failed","data":{"sessionID":"\#(session)","assistantMessageID":"\#(message)","id":"t2","error":{"type":"aborted","message":"The user declined this tool call"},"executed":false}}"#
        )
        #expect(agentEvents(stopped).last == .toolCompleted(id: "t2", status: .declined, output: "The user declined this tool call"))
    }

    @Test func approvalsWithoutSavePatternsOfferNoSessionGrant() throws {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let effects = feed(
            &mapper,
            #"{"type":"permission.asked","data":{"id":"per_3","sessionID":"\#(session)","action":"external_directory","resources":["/etc"]}}"#)
        guard case .approvalRequested(let request) = try #require(agentEvents(effects).first) else {
            Issue.record("Expected an approval request")
            return
        }
        #expect(request.options.map(\.kind) == [.allowOnce, .deny, .cancel])
        #expect(request.title == "Access /etc outside the project")
        #expect(request.category == .read)
    }

    @Test func requestsSettledElsewhereAreResolved() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        _ = feed(&mapper, #"{"type":"permission.asked","data":{"id":"per_4","sessionID":"\#(session)","action":"shell","resources":["make"]}}"#)
        let resolved = feed(
            &mapper, #"{"type":"permission.replied","data":{"sessionID":"\#(session)","requestID":"per_4","reply":"reject"}}"#)
        #expect(agentEvents(resolved) == [.approvalResolved(id: "per_4")])
        #expect(mapper.pending.isEmpty)
        let again = feed(
            &mapper, #"{"type":"permission.replied","data":{"sessionID":"\#(session)","requestID":"per_4","reply":"reject"}}"#)
        #expect(again.isEmpty)
    }

    @Test func failedExecutionFailsTheTurn() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        mapper.beginTurn(promptID: "msg_coincide_3")
        let effects = feed(
            &mapper,
            """
            {"type":"session.execution.started","data":{"sessionID":"\(session)"}}
            {"type":"session.inbox.delivered","data":{"sessionID":"\(session)","inboxID":"msg_coincide_3"}}
            {"type":"session.execution.failed","data":{"sessionID":"\(session)","error":{"type":"provider.no-route","message":"Model unavailable: nope/missing-model"}}}
            """)
        #expect(agentEvents(effects) == [.turnCompleted(.failed("Model unavailable: nope/missing-model"))])
    }

    @Test func interruptedExecutionEndsTheTurnOnce() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        mapper.beginTurn(promptID: "msg_coincide_4")
        _ = feed(
            &mapper,
            """
            {"type":"session.execution.started","data":{"sessionID":"\(session)"}}
            {"type":"session.inbox.delivered","data":{"sessionID":"\(session)","inboxID":"msg_coincide_4"}}
            """)
        mapper.requestInterrupt()
        let effects = feed(
            &mapper,
            """
            {"type":"session.step.failed","data":{"sessionID":"\(session)","assistantMessageID":"msg_17c05eb9d001QoFqQ7D41I3PBX","error":{"type":"aborted","message":"Step interrupted"}}}
            {"type":"session.execution.interrupted","data":{"sessionID":"\(session)","reason":"user"}}
            {"type":"session.execution.succeeded","data":{"sessionID":"\(session)"}}
            """)
        #expect(agentEvents(effects) == [.turnCompleted(.interrupted)])
        #expect(mapper.endTurn(.interrupted) == nil)
    }

    @Test func successAfterAnInterruptRequestCountsAsInterrupted() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        mapper.beginTurn(promptID: "msg_coincide_5")
        _ = feed(&mapper, #"{"type":"session.execution.started","data":{"sessionID":"\#(session)"}}"#)
        mapper.requestInterrupt()
        let effects = feed(&mapper, #"{"type":"session.execution.succeeded","data":{"sessionID":"\#(session)"}}"#)
        #expect(agentEvents(effects) == [.turnCompleted(.interrupted)])
    }

    @Test func anExecutionOpenCodeStartsItselfIsATurnOfItsOwn() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let started = feed(&mapper, #"{"type":"session.execution.started","data":{"sessionID":"\#(session)"}}"#)
        #expect(agentEvents(started) == [.agentTurnStarted(note: "OpenCode started working on its own.")])
        let ended = feed(&mapper, #"{"type":"session.execution.succeeded","data":{"sessionID":"\#(session)"}}"#)
        #expect(agentEvents(ended) == [.turnCompleted(.completed)])

        // Stopped by the user, it ends as interrupted.
        _ = feed(&mapper, #"{"type":"session.execution.started","data":{"sessionID":"\#(session)"}}"#)
        mapper.requestInterrupt()
        let stopped = feed(&mapper, #"{"type":"session.execution.succeeded","data":{"sessionID":"\#(session)"}}"#)
        #expect(agentEvents(stopped) == [.turnCompleted(.interrupted)])

        // An execution that starts while a prompt is being prepared belongs to that prompt.
        mapper.preparingPrompt = true
        #expect(feed(&mapper, #"{"type":"session.execution.started","data":{"sessionID":"\#(session)"}}"#).isEmpty)
        mapper.preparingPrompt = false
        #expect(feed(&mapper, #"{"type":"session.execution.succeeded","data":{"sessionID":"\#(session)"}}"#).isEmpty)
    }

    @Test func anEarlierExecutionEndingDoesNotEndTheTurn() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        _ = feed(&mapper, #"{"type":"session.execution.started","data":{"sessionID":"\#(session)"}}"#)
        mapper.beginTurn(promptID: "msg_coincide_6")
        let early = feed(&mapper, #"{"type":"session.execution.succeeded","data":{"sessionID":"\#(session)"}}"#)
        #expect(early.isEmpty)
        #expect(mapper.turn != nil)
        let effects = feed(
            &mapper,
            """
            {"type":"session.execution.started","data":{"sessionID":"\(session)"}}
            {"type":"session.inbox.delivered","data":{"sessionID":"\(session)","inboxID":"msg_coincide_6"}}
            {"type":"session.execution.succeeded","data":{"sessionID":"\(session)"}}
            """)
        #expect(agentEvents(effects) == [.turnCompleted(.completed)])
    }

    @Test func stoppingAQueuedPromptWithdrawsIt() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        _ = feed(&mapper, #"{"type":"session.execution.started","data":{"sessionID":"\#(session)"}}"#)
        mapper.beginTurn(promptID: "msg_coincide_7")
        mapper.requestInterrupt()
        let effects = feed(
            &mapper, #"{"type":"session.execution.interrupted","data":{"sessionID":"\#(session)","reason":"user"}}"#)
        #expect(effects == [.cancelPrompt(messageID: "msg_coincide_7"), .event(.turnCompleted(.interrupted))])
    }

    @Test func questionsAreAskedAsUserInput() throws {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let effects = feed(
            &mapper,
            """
            {"type":"session.tool.input.started","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"q1","name":"question"}}
            {"type":"session.tool.called","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"q1","input":{"questions":[{"question":"Which color do I prefer?","header":"Color","options":[{"label":"red","description":"Red"},{"label":"blue","description":"Blue"}]}]},"executed":false}}
            {"type":"form.created","data":{"form":{"id":"frm_17c1062a400123JBNpsoIgrJrZ","sessionID":"\(session)","title":"Questions","metadata":{"kind":"question","tool":{"messageID":"\(message)","id":"q1"}},"fields":[{"key":"q0","title":"Color","description":"Which color do I prefer?","type":"string","options":[{"value":"red","label":"red","description":"Red"},{"value":"blue","label":"Blue shade","description":"A calm blue"}],"custom":true}]}}}
            """)
        #expect(
            agentEvents(effects) == [
                .userInputRequested(
                    UserInputRequest(
                        id: "frm_17c1062a400123JBNpsoIgrJrZ", title: "Questions",
                        questions: [
                            UserQuestion(
                                id: "q0", header: "Color", prompt: "Which color do I prefer?",
                                options: [.init(label: "red"), .init(label: "Blue shade", detail: "A calm blue")],
                                allowsMultipleSelection: false, allowsFreeText: true)
                        ]))
            ])
        let field = OpenCodeQuestions.Field(
            key: "q0", kind: .choice, options: [.init(label: "red", value: "red"), .init(label: "Blue shade", value: "blue")])
        #expect(mapper.pending["frm_17c1062a400123JBNpsoIgrJrZ"]?.kind == .form([field]))
        #expect(mapper.pending["frm_17c1062a400123JBNpsoIgrJrZ"]?.toolCallID == "q1")

        let answered = feed(
            &mapper,
            """
            {"type":"form.replied","data":{"id":"frm_17c1062a400123JBNpsoIgrJrZ"}}
            {"type":"session.tool.success","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"q1","content":[{"type":"text","text":"blue"}]}}
            """)
        #expect(agentEvents(answered) == [.userInputResolved(id: "frm_17c1062a400123JBNpsoIgrJrZ")])
        #expect(mapper.pending.isEmpty)
    }

    @Test func answeredQuestionsAreNotResolvedAgain() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        _ = feed(
            &mapper,
            #"{"type":"form.created","data":{"form":{"id":"frm_1","sessionID":"\#(session)","title":"Questions","fields":[{"key":"q0","type":"string","title":"Name"}]}}}"#)
        #expect(mapper.resolve("frm_1", declined: false) != nil)
        #expect(feed(&mapper, #"{"type":"form.replied","data":{"id":"frm_1"}}"#).isEmpty)
    }

    @Test func formsWithLinksOrConditionsAreDeclined() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let effects = feed(
            &mapper,
            """
            {"type":"form.created","data":{"form":{"id":"frm_2","sessionID":"\(session)","title":"Sign in","fields":[{"key":"q0","type":"string","title":"Name"},{"key":"link","type":"external","url":"https://example.com/login"}]}}}
            {"type":"form.created","data":{"form":{"id":"frm_3","sessionID":"\(session)","title":"Setup","fields":[{"key":"a","type":"boolean","title":"Use a proxy?"},{"key":"b","type":"string","title":"Proxy URL","when":[{"key":"a","op":"eq","value":true}]}]}}}
            {"type":"form.created","data":{"form":{"id":"frm_4","sessionID":"ses_unrelated","title":"Other","fields":[{"key":"q0","type":"string"}]}}}
            """)
        #expect(effects == [.declineForm(sessionID: session, formID: "frm_2"), .declineForm(sessionID: session, formID: "frm_3")])
        #expect(mapper.pending.isEmpty)
    }

    @Test func todoListsBecomeThePlan() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let effects = feed(
            &mapper,
            """
            {"type":"session.tool.input.started","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"td","name":"todowrite"}}
            {"type":"session.tool.called","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"td","input":{"todos":[{"content":"Read the code","status":"completed"},{"content":"Write tests","status":"in_progress"},{"content":"Ship it","status":"pending"},{"content":"Old idea","status":"cancelled"}]}}}
            {"type":"session.tool.success","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"td","content":[{"type":"text","text":"Todos updated"}]}}
            """)
        #expect(
            agentEvents(effects) == [
                .plan(text: "- [x] Read the code\n- [ ] **Write tests**\n- [ ] Ship it\n- [x] ~~Old idea~~")
            ])
    }

    @Test func subagentsShowTheirResultAndCanAskForApproval() throws {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let child = "ses_child00000000000000000001"
        let effects = feed(
            &mapper,
            """
            {"type":"session.tool.input.started","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"sa","name":"subagent"}}
            {"type":"session.tool.called","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"sa","input":{"description":"Find the tests","prompt":"List the test files.","agent":"explore"}}}
            {"type":"session.created","data":{"sessionID":"\(child)","parentID":"\(session)","agent":"explore"}}
            {"type":"session.text.delta","data":{"sessionID":"\(child)","assistantMessageID":"msg_child","ordinal":0,"delta":"child text"}}
            {"type":"permission.asked","data":{"id":"per_child","sessionID":"\(child)","action":"shell","resources":["ls Tests"],"save":["ls *"]}}
            {"type":"session.tool.success","data":{"sessionID":"\(session)","assistantMessageID":"\(message)","id":"sa","content":[{"type":"text","text":"<subagent sessionID=\\"\(child)\\" state=\\"completed\\">\\nTests/AppTests.swift\\n</subagent>"}],"metadata":{"sessionID":"\(child)","status":"completed"}}}
            """)
        let events = agentEvents(effects)
        #expect(events.count == 4)
        #expect(
            events[1]
                == .toolUpdated(ToolCallInfo(id: "sa", category: .task, title: "Subagent: Find the tests", detail: "List the test files.")))
        guard case .approvalRequested(let request) = events[2] else {
            Issue.record("Expected the subagent's approval request")
            return
        }
        #expect(request.title == "Run `ls Tests`")
        #expect(mapper.pending["per_child"]?.sessionID == child)
        #expect(events[3] == .toolCompleted(id: "sa", status: .completed, output: "Tests/AppTests.swift"))
        #expect(mapper.children == [child])
    }

    @Test func retriesAreNotedOnce() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        mapper.beginTurn(promptID: "msg_coincide_8")
        let retry = #"{"type":"session.retry.scheduled","data":{"sessionID":"\#(session)","assistantMessageID":"\#(message)","attempt":2,"at":1793082100000,"error":{"type":"provider.rate-limit","message":"Rate limited"}}}"#
        let effects = feed(&mapper, retry + "\n" + retry)
        #expect(agentEvents(effects) == [.notice("OpenCode is retrying the request: Rate limited")])
    }

    @Test func compactionShowsAsAnItem() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        let effects = feed(
            &mapper,
            """
            {"type":"session.compaction.started","data":{"sessionID":"\(session)","reason":"auto"}}
            {"type":"session.compaction.ended","data":{"sessionID":"\(session)","reason":"auto","text":"Summary of the work so far."}}
            """)
        let id = "\(session):compaction:1"
        #expect(
            agentEvents(effects) == [
                .toolStarted(ToolCallInfo(id: id, category: .other, title: "Compacting context")),
                .toolUpdated(ToolCallInfo(id: id, category: .other, title: "Compacted context")),
                .toolCompleted(id: id, status: .completed, output: "Summary of the work so far."),
            ])
    }

    @Test func deletedSessionIsReported() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        #expect(feed(&mapper, #"{"type":"session.deleted","data":{"sessionID":"\#(session)"}}"#) == [.sessionDeleted])
    }

    @Test func backfillSettlesATurnFromHistory() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        mapper.beginTurn(promptID: "msg_coincide_aaaa1111")
        let history = parse(
            """
            {"id":"msg_17c1f132c001n0BEN6q4xk6Ag9","type":"idle","outcome":"succeeded"}
            {"id":"msg_17c1f06c6001VNKYNlZ5YJUuI8","type":"assistant","content":[{"type":"reasoning","text":"Short"},{"type":"text","text":"one"},{"type":"tool","id":"t9","name":"shell","state":{"status":"completed","input":{"command":"pwd"},"content":[{"type":"text","text":"/tmp\\n"}],"metadata":{"exit":0}}}]}
            {"id":"msg_coincide_aaaa1111","type":"user","text":"Reply with exactly: one"}
            {"id":"msg_older","type":"assistant","content":[{"type":"text","text":"older"}]}
            """)
        let id = "msg_17c1f06c6001VNKYNlZ5YJUuI8"
        #expect(
            agentEvents(mapper.backfill(newestFirst: history)) == [
                .reasoningText(itemID: "\(id):reasoning:0", text: "Short"),
                .assistantText(itemID: "\(id):text:0", text: "one"),
                .toolStarted(ToolCallInfo(id: "t9", category: .command, title: "Run `pwd`", detail: "pwd")),
                .toolCompleted(id: "t9", status: .completed, output: "/tmp\n"),
                .turnCompleted(.completed),
            ])
        #expect(mapper.turn == nil)
    }

    @Test func backfillWithoutThePromptEndsAsInterrupted() {
        var mapper = OpenCodeEventMapper(sessionID: session)
        mapper.beginTurn(promptID: "msg_coincide_missing")
        let history = parse(#"{"id":"msg_x","type":"idle","outcome":"succeeded"}"#)
        #expect(agentEvents(mapper.backfill(newestFirst: history)) == [.turnCompleted(.interrupted)])
    }
}

struct OpenCodeCatalogTests {
    private let modelList = parse(
        """
        {"id":"claude-opus-5-5","providerID":"anthropic","family":"claude-opus","name":"Claude Opus 5.5","capabilities":{"tools":true,"input":["text","image","pdf"],"output":["text"]},"variants":[{"id":"max"},{"id":"low"},{"id":"high"},{"id":"medium"},{"id":"xhigh"}],"time":{"released":1790035200000},"status":"active","enabled":true,"limit":{"context":1000000,"output":128000}}
        {"id":"claude-opus-5-5","providerID":"opencode","family":"claude-opus","name":"Claude Opus 5.5","capabilities":{"tools":true,"input":["text","image"],"output":["text"]},"variants":[{"id":"low"},{"id":"medium"},{"id":"high"}],"time":{"released":1790035200000},"status":"active","enabled":true,"limit":{"context":1000000,"output":128000}}
        {"id":"claude-opus-4-8","providerID":"anthropic","family":"claude-opus","name":"Claude Opus 4.8","capabilities":{"tools":true,"input":["text","image"],"output":["text"]},"variants":[{"id":"low"},{"id":"high"}],"time":{"released":1779926400000},"status":"active","enabled":true,"limit":{"context":1000000,"output":64000}}
        {"id":"gpt-6-luna","providerID":"openai","family":"gpt-luna","name":"GPT-6 Luna","capabilities":{"tools":true,"input":["text","image"],"output":["text"]},"variants":[{"id":"none"},{"id":"low"},{"id":"medium"},{"id":"high"}],"time":{"released":1790035200000},"status":"active","enabled":true,"limit":{"context":400000,"input":272000,"output":128000}}
        {"id":"big-pickle","providerID":"opencode","family":"big-pickle","name":"Big Pickle","capabilities":{"tools":true,"input":["text"],"output":["text"]},"variants":[],"time":{"released":1760659200000},"status":"active","enabled":true,"limit":{"context":200000,"input":160000,"output":32000}}
        {"id":"grok-old","providerID":"xai","family":"grok","name":"Grok Old","capabilities":{"tools":true,"input":["text"],"output":["text"]},"variants":[],"time":{"released":1700000000000},"status":"deprecated","enabled":true,"limit":{"context":100000,"output":8000}}
        {"id":"hidden","providerID":"xai","name":"Hidden","capabilities":{"tools":true,"input":["text"],"output":["text"]},"variants":[],"time":{"released":1700000000000},"status":"active","enabled":false,"limit":{"context":100000,"output":8000}}
        """)
    private let providers = parse(
        """
        {"id":"anthropic","name":"Anthropic"}
        {"id":"opencode","name":"Default / OpenCode"}
        {"id":"openai","name":"OpenAI"}
        """)

    @Test func buildsPickerOptions() throws {
        let models = OpenCodeCatalog.models(from: modelList, providers: providers)
        #expect(
            models.map(\.displayName) == [
                "Big Pickle", "Claude Opus 5.5 (Anthropic)", "Claude Opus 5.5 (OpenCode)", "GPT-6 Luna", "Claude Opus 4.8",
                "Grok Old",
            ])
        let opus = try #require(models.first { $0.modelID == "anthropic/claude-opus-5-5" })
        #expect(opus.provider == .opencode)
        #expect(opus.efforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(opus.defaultEffort == "high")
        #expect(opus.contextWindow == 1_000_000)
        #expect(opus.supportsImages)
        let luna = try #require(models.first { $0.modelID == "openai/gpt-6-luna" })
        #expect(luna.defaultEffort == "medium")
        #expect(luna.contextWindow == 272_000)
        let pickle = try #require(models.first { $0.modelID == "opencode/big-pickle" })
        #expect(pickle.efforts.isEmpty)
        #expect(pickle.defaultEffort == nil)
        #expect(!pickle.supportsImages)
        #expect(!models.contains { $0.modelID == "xai/hidden" })
    }

    @Test func defaultEffortsFollowT3() {
        #expect(OpenCodeCatalog.defaultEffort(providerID: "anthropic", efforts: ["low", "high"]) == "high")
        #expect(OpenCodeCatalog.defaultEffort(providerID: "google-vertex", efforts: ["low", "high"]) == "high")
        #expect(OpenCodeCatalog.defaultEffort(providerID: "opencode", efforts: ["low", "high", "max"]) == "high")
        #expect(OpenCodeCatalog.defaultEffort(providerID: "openai", efforts: ["low", "medium"]) == "medium")
        #expect(OpenCodeCatalog.defaultEffort(providerID: "xai", efforts: ["low", "medium"]) == nil)
        #expect(OpenCodeCatalog.defaultEffort(providerID: "xai", efforts: ["high"]) == "high")
    }

    @Test func ordersEfforts() {
        #expect(OpenCodeCatalog.orderedEfforts(["max", "turbo", "none", "high", "minimal"]) == ["none", "minimal", "high", "max", "turbo"])
    }

    @Test func contextWindowsPreferTheInputLimit() {
        let windows = OpenCodeCatalog.contextWindows(from: modelList)
        #expect(windows["openai/gpt-6-luna"] == 272_000)
        #expect(windows["anthropic/claude-opus-5-5"] == 1_000_000)
    }

    @Test func accountListsConnectedIntegrations() {
        let integrations = parse(
            """
            {"id":"anthropic","name":"Anthropic","methods":[],"connections":[{"type":"credential","id":"c1","label":"Anthropic","method":"key"}]}
            {"id":"mcp_1439b8168d0cbac4","name":"cloudflare","methods":[],"connections":[{"type":"credential","id":"c2","label":"cloudflare","method":"oauth"}]}
            {"id":"302ai","name":"302.AI","methods":[],"connections":[]}
            {"id":"openai","name":"OpenAI","methods":[],"connections":[{"type":"credential","id":"c3","label":"OpenAI","method":"oauth"}]}
            """)
        #expect(OpenCodeCatalog.account(fromIntegrations: integrations) == "Anthropic, OpenAI")
        #expect(OpenCodeCatalog.account(fromIntegrations: []) == nil)
    }

    @Test func parsesVersions() {
        #expect(OpenCodeCatalog.parseVersion("opencode v2.1.4\n") == "2.1.4")
        #expect(OpenCodeCatalog.parseVersion("1.14.19") == "1.14.19")
        #expect(OpenCodeCatalog.parseVersion("opencode v2.2.0-beta.1") == "2.2.0-beta.1")
        #expect(OpenCodeCatalog.parseVersion("no version") == nil)
        #expect(OpenCodeCatalog.majorVersion("2.1.4") == 2)
    }

    @Test func providerLabelsDropTheAccount() {
        #expect(OpenCodeCatalog.providerLabel("opencode", names: ["opencode": "Default / OpenCode"]) == "OpenCode")
        #expect(OpenCodeCatalog.providerLabel("xai", names: [:]) == "xai")
    }

    @Test func fallbackModelsUseProviderSlugs() {
        #expect(!OpenCodeCatalog.fallbackModels.isEmpty)
        #expect(OpenCodeCatalog.fallbackModels.allSatisfy { $0.provider == .opencode && $0.modelID.contains("/") })
    }
}

struct OpenCodeQuestionsTests {
    private let form = JSONValue.parse(
        #"""
        {"id":"frm_9","sessionID":"ses_x","title":"Project setup","fields":[
          {"key":"name","type":"string","title":"Name","description":"What should the package be called?"},
          {"key":"license","type":"string","title":"License","options":[{"value":"mit","label":"MIT"},{"value":"apache-2.0","label":"Apache 2.0","description":"Includes a patent grant"}]},
          {"key":"targets","type":"multiselect","title":"Targets","options":[{"value":"ios","label":"iOS"},{"value":"macos","label":"macOS"}],"custom":true},
          {"key":"tests","type":"boolean","title":"Add tests?"},
          {"key":"retries","type":"integer","title":"Retries"},
          {"key":"ratio","type":"number","description":"Sampling ratio"}
        ]}
        """#)!

    @Test func parsesEveryKindOfField() throws {
        let parsed = try #require(OpenCodeQuestions.parse(form))
        #expect(parsed.request.id == "frm_9")
        #expect(parsed.request.title == "Project setup")
        let questions = parsed.request.questions
        #expect(questions.map(\.id) == ["name", "license", "targets", "tests", "retries", "ratio"])
        #expect(questions[0] == UserQuestion(id: "name", header: "Name", prompt: "What should the package be called?"))
        #expect(
            questions[1]
                == UserQuestion(
                    id: "license", prompt: "License",
                    options: [.init(label: "MIT"), .init(label: "Apache 2.0", detail: "Includes a patent grant")],
                    allowsFreeText: false))
        #expect(questions[2].allowsMultipleSelection)
        #expect(questions[2].allowsFreeText)
        #expect(questions[3].options.map(\.label) == ["Yes", "No"])
        #expect(!questions[3].allowsFreeText)
        #expect(questions[4] == UserQuestion(id: "retries", prompt: "Retries"))
        #expect(questions[5] == UserQuestion(id: "ratio", prompt: "Sampling ratio"))
        #expect(parsed.fields.map(\.kind) == [.text, .choice, .multipleChoice, .boolean, .integer, .number])
    }

    @Test func untitledFieldsAreNumbered() throws {
        let form = JSONValue.parse(#"{"id":"frm_1","fields":[{"key":"a","type":"string"},{"key":"b","type":"string"}]}"#)!
        let parsed = try #require(OpenCodeQuestions.parse(form))
        #expect(parsed.request.title == nil)
        #expect(parsed.request.questions.map(\.prompt) == ["Question 1", "Question 2"])
    }

    @Test func answersUseOptionValues() throws {
        let fields = try #require(OpenCodeQuestions.parse(form)).fields
        let answer = OpenCodeQuestions.answer(
            [
                "name": ["  coincide-kit "], "license": ["Apache 2.0"], "targets": ["iOS", "visionOS"], "tests": ["Yes"],
                "retries": ["3"], "ratio": ["0.25"], "unknown": ["x"],
            ], fields: fields)
        #expect(
            answer == [
                "name": "coincide-kit", "license": "apache-2.0", "targets": ["ios", "visionOS"], "tests": true, "retries": 3,
                "ratio": 0.25,
            ])
    }

    @Test func unusableAnswersAreLeftOut() throws {
        let fields = try #require(OpenCodeQuestions.parse(form)).fields
        let answer = OpenCodeQuestions.answer(
            ["name": ["", "  "], "tests": ["maybe"], "retries": ["2.5"], "ratio": ["lots"], "license": ["MIT", "Custom"]],
            fields: fields)
        #expect(answer == ["license": "mit, Custom"])
        #expect(OpenCodeQuestions.answer([:], fields: fields).isEmpty)
        #expect(OpenCodeQuestions.answer(["tests": ["no"]], fields: fields) == ["tests": false])
    }
}

struct OpenCodePermissionsTests {
    private let planPath = OpenCodeRule("edit", "allow", resource: "/Users/me/.opencode/plan/*")

    @Test func fullAccessAllowsEverything() {
        #expect(OpenCodePermissions.rules(accessMode: .fullAccess, plan: false, grants: [], agentPaths: [planPath]) == [OpenCodeRule("*", "allow")])
    }

    @Test func approvalAsksBeforeCommandsAndEdits() {
        let grant = OpenCodeRule("shell", "allow", resource: "echo *")
        #expect(
            OpenCodePermissions.rules(accessMode: .approval, plan: false, grants: [grant], agentPaths: []) == [
                OpenCodeRule("shell", "ask"), OpenCodeRule("edit", "ask"), OpenCodeRule("external_directory", "ask"), grant,
            ])
    }

    @Test func planModeDeniesEditsButKeepsThePlanFolder() {
        #expect(
            OpenCodePermissions.rules(accessMode: .fullAccess, plan: true, grants: [], agentPaths: [planPath]) == [
                OpenCodeRule("*", "allow"), OpenCodeRule("edit", "deny"), planPath,
            ])
    }

    @Test func agentPathsKeepOnlyScopedAllows() {
        let agents = parse(
            #"{"id":"plan","permissions":[{"action":"*","resource":"*","effect":"allow"},{"action":"edit","resource":"*","effect":"deny"},{"action":"edit","resource":"/Users/me/.opencode/plan/*","effect":"allow"},{"action":"read","resource":"*.env","effect":"ask"},{"action":"edit","resource":"/Users/me/.opencode/plan/*","effect":"allow"}]}"#
        )
        #expect(OpenCodePermissions.agentPaths(fromAgents: agents) == ["plan": [planPath]])
    }

    @Test func ruleJSONRoundTrips() {
        let rule = OpenCodeRule("shell", "ask", resource: "git *")
        #expect(OpenCodeRule(json: rule.json) == rule)
        #expect(rule.json.compactJSON == #"{"action":"shell","effect":"ask","resource":"git *"}"#)
    }

    @Test func agentFollowsTheInteractionMode() {
        #expect(OpenCodePermissions.agent(for: .plan) == "plan")
        #expect(OpenCodePermissions.agent(for: .build) == "build")
    }

    @Test func declinedNoteTellsTheAgentNotToRetry() {
        #expect(
            OpenCodePermissions.declinedNote(action: "shell", resources: ["rm -rf build"])
                == "The user declined the shell request (rm -rf build). Do not retry it; continue without it or ask the user how to proceed.")
    }
}

struct OpenCodeToolsTests {
    private func info(_ name: String, _ input: [String: JSONValue]) -> ToolCallInfo {
        OpenCodeTools.info(id: "t", name: name, input: input)
    }

    @Test func titlesAndCategories() {
        #expect(info("read", ["path": "Sources/App.swift"]).title == "Read Sources/App.swift")
        #expect(info("read", ["path": "a.txt", "offset": 10, "limit": 5]).detail == "a.txt, lines 10–14")
        #expect(info("write", ["path": "todo.md", "content": "done\n"]).title == "Write todo.md")
        #expect(info("write", ["path": "todo.md", "content": "done\n"]).detail == "done\n")
        #expect(info("glob", ["pattern": "*.md"]).title == "Find `*.md`")
        #expect(info("grep", ["pattern": "coincide", "path": "Sources"]).title == "Search for `coincide` in Sources")
        #expect(info("grep", ["pattern": "x"]).category == .search)
        #expect(info("webfetch", ["url": "https://example.com"]).title == "Fetch https://example.com")
        #expect(info("websearch", ["query": "swift testing"]).category == .web)
        #expect(info("execute", ["code": "await tools.search({})"]).category == .mcp)
        #expect(info("execute", ["code": "await tools.search({})"]).detail == "await tools.search({})")
        #expect(info("skill", ["id": "pdf"]).title == "Load skill pdf")
        #expect(info("shell", [:]).title == "Run command")
        #expect(info("mystery", ["a": 1]).category == .other)
        let long = String(repeating: "x", count: 120)
        #expect(info("shell", ["command": .string(long + "\nsecond line")]).title.count == 86)
    }

    @Test func patchTitlesNameTheFiles() {
        let patch = "*** Begin Patch\n*** Update File: Sources/A.swift\n@@\n-a\n+b\n*** Add File: Sources/B.swift\n+new\n*** End Patch"
        let call = info("patch", ["patchText": .string(patch)])
        #expect(call.title == "Edit Sources/A.swift, Sources/B.swift")
        #expect(call.category == .fileChange)
        #expect(call.detail == patch)
    }

    @Test func stripsSubagentWrapper() {
        #expect(OpenCodeTools.subagentResult("<subagent sessionID=\"ses_1\" state=\"completed\">\nDone.\n</subagent>") == "Done.")
        #expect(OpenCodeTools.subagentResult("plain") == "plain")
    }

    @Test func diffComesFromMetadata() {
        let metadata = JSONValue.parse(#"{"files":[{"file":"a","patch":"--- a\n+++ a\n"},{"file":"b","patch":"--- b\n+++ b\n"}]}"#)
        #expect(OpenCodeTools.diff(fromMetadata: metadata) == "--- a\n+++ a\n\n--- b\n+++ b\n")
        #expect(OpenCodeTools.diff(fromMetadata: JSONValue.parse(#"{"truncated":false}"#)) == nil)
    }
}

struct OpenCodeWireTests {
    @Test func sseParserSplitsEventsAcrossChunks() {
        var parser = SSEParser()
        var payloads = parser.feed(Data("data: {\"type\":\"server.connected\",\"data\":{}}\n\n: heartbeat\n\nda".utf8))
        #expect(payloads == [#"{"type":"server.connected","data":{}}"#])
        payloads = parser.feed(Data("ta: {\"a\":1}\r\n\r\nevent: x\ndata: line1\ndata: line2\n".utf8))
        #expect(payloads == [#"{"a":1}"#])
        payloads = parser.feed(Data("\n".utf8))
        #expect(payloads == ["line1\nline2"])
    }

    @Test func findsTheListeningURL() {
        #expect(OpenCodeServer.listeningURL(in: "server listening on http://127.0.0.1:59566") == URL(string: "http://127.0.0.1:59566"))
        #expect(OpenCodeServer.listeningURL(in: "[11:47:53.454] INFO (#910): spawning process {") == nil)
    }

    @Test func recognizesALockedDatabase() {
        let locked = OpenCodeServer.startupFailure(status: 1, stdout: "", stderr: "Error: SQLITE_BUSY: database is locked")
        #expect(locked.databaseLocked)
        #expect(locked.message.contains("SQLITE_BUSY"))
        #expect(!OpenCodeServer.startupFailure(status: 1, stdout: "", stderr: "boom").databaseLocked)
    }

    @Test func passwordsAreURLSafe() {
        let password = OpenCodeServer.randomPassword()
        #expect(password.count == 43)
        #expect(password.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(password != OpenCodeServer.randomPassword())
    }

    @Test func requestsCarryBasicAuthAndBracketedLocations() throws {
        let api = OpenCodeAPI(
            baseURL: try #require(URL(string: "http://127.0.0.1:4096")), password: "pässword",
            urlSession: URLSession(configuration: .ephemeral))
        let request = api.urlRequest(
            "POST", "/api/model", query: OpenCodeAPI.location("/Users/me/My Project"), body: ["x": 1])
        #expect(request.url?.absoluteString == "http://127.0.0.1:4096/api/model?location%5Bdirectory%5D=/Users/me/My%20Project")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("opencode:pässword".utf8).base64EncodedString())
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data(#"{"x":1}"#.utf8))
    }

    @Test func idsAreEscapedInPaths() {
        #expect(OpenCodeAPI.segment("ses_e83fb9e85ffeE5kfr2BtYA7YTz") == "ses_e83fb9e85ffeE5kfr2BtYA7YTz")
        #expect(OpenCodeAPI.segment("a/b?c#d e") == "a%2Fb%3Fc%23d%20e")
    }

    @Test func errorsUseTheServerMessage() {
        let error = OpenCodeAPIError(
            status: 404, body: Data(#"{"_tag":"SessionNotFoundError","sessionID":"ses_x","message":"Session not found: ses_x"}"#.utf8))
        #expect(error.isSessionNotFound)
        #expect(error.localizedDescription == "Session not found: ses_x")
        #expect(OpenCodeAPIError(status: 502, body: Data()).message == "The OpenCode server returned HTTP 502.")
    }

    @Test func modelRefsUseProviderSlugsAndVariants() {
        let ref = OpenCodeModelRef(selection: ModelSelection(provider: .opencode, modelID: "anthropic/claude-opus-5-5", effort: "high"))
        #expect(ref == OpenCodeModelRef(providerID: "anthropic", modelID: "claude-opus-5-5", variant: "high"))
        #expect(ref?.json.compactJSON == #"{"id":"claude-opus-5-5","providerID":"anthropic","variant":"high"}"#)
        #expect(OpenCodeModelRef(selection: ModelSelection(provider: .opencode, modelID: "default")) == nil)
        #expect(OpenCodeModelRef(selection: ModelSelection(provider: .opencode, modelID: "openrouter/")) == nil)
        let nested = OpenCodeModelRef(selection: ModelSelection(provider: .opencode, modelID: "openrouter/meta/llama"))
        #expect(nested?.providerID == "openrouter" && nested?.modelID == "meta/llama")
        let reported = OpenCodeModelRef(json: JSONValue.parse(#"{"id":"big-pickle","providerID":"opencode","variant":"default"}"#))
        #expect(OpenCodeModelRef(providerID: "opencode", modelID: "big-pickle").isSameModel(as: reported))
        #expect(!OpenCodeModelRef(providerID: "opencode", modelID: "big-pickle", variant: "high").isSameModel(as: reported))
    }
}

@MainActor
struct OpenCodeSessionHelperTests {
    @Test func promptsListAttachedImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let missing = directory.appendingPathComponent("gone.jpg").path

        let content = OpenCodeSession.promptContent(text: "What is this?", imagePaths: [image.path, missing])
        #expect(
            content.text
                == "What is this?\n\n[Attached image \"shot.png\" is saved at: \(image.path)]\n\n[Attached image \"gone.jpg\" is unavailable: \(missing) was not found.]")
        #expect(content.files == [["uri": .string(image.absoluteString), "name": "shot.png"]])
        #expect(OpenCodeSession.promptContent(text: "", imagePaths: []).text == "")
    }

    @Test func promptIDsAreOpenCodeMessageIDs() {
        let id = OpenCodeSession.newPromptID()
        #expect(id.hasPrefix("msg_coincide_"))
        #expect(id.count == "msg_coincide_".count + 32)
        #expect(id != OpenCodeSession.newPromptID())
    }

    @Test func titlesComeFromTheUsersMessage() {
        #expect(OpenCodeSession.title(threadTitle: nil, message: "Fix the login bug\nmore detail") == "Fix the login bug")
        #expect(OpenCodeSession.title(threadTitle: "Login bug", message: "Now add tests") == "Login bug")
        #expect(OpenCodeSession.title(threadTitle: " ", message: "Now add tests") == "Now add tests")
        #expect(OpenCodeSession.title(threadTitle: nil, message: "   ") == nil)
    }

    @Test func comparesDirectoriesThroughSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.path
        // The temporary directory lives under /var, a symlink to /private/var.
        #expect(path.hasPrefix("/var/") || path.hasPrefix("/private/var/"))
        let other = path.hasPrefix("/private") ? String(path.dropFirst("/private".count)) : "/private" + path
        #expect(OpenCodeSession.sameDirectory(path, other))
        #expect(OpenCodeSession.sameDirectory(path + "/", path))
        #expect(!OpenCodeSession.sameDirectory(path, directory.deletingLastPathComponent().path))
        #expect(OpenCodeSession.sameDirectory("/nonexistent/coincide/a/../b", "/nonexistent/coincide/b"))
    }
}

struct OpenCodeCatalogLoadingTests {
    private let pickle =
        #"{"id":"big-pickle","providerID":"opencode","name":"Big Pickle","variants":[],"enabled":true,"capabilities":{"input":["text"]},"limit":{"context":200000,"input":160000,"output":32000}}"#
    private let sonnet =
        #"{"id":"claude-sonnet-4-5","providerID":"anthropic","name":"Claude Sonnet 4.5","variants":[{"id":"high"},{"id":"max"}],"enabled":true,"capabilities":{"input":["text","image"]},"limit":{"context":200000,"output":64000}}"#

    private func serve(models: [(Int, String)]) -> OpenCodeAPI {
        let host = "opencode-\(UUID().uuidString.lowercased()).test"
        OpenCodeStubProtocol.serve(host: host, path: "/api/model", responses: models)
        OpenCodeStubProtocol.serve(host: host, path: "/api/provider", responses: [(200, #"{"data":[{"id":"anthropic","name":"Anthropic"}]}"#)])
        OpenCodeStubProtocol.serve(
            host: host, path: "/api/integration",
            responses: [(200, #"{"data":[{"id":"anthropic","name":"Anthropic","methods":[],"connections":[{"type":"credential"}]}]}"#)])
        return OpenCodeAPI(baseURL: URL(string: "http://\(host)")!, password: "secret", urlSession: OpenCodeStubProtocol.session())
    }

    @Test func waitsForAColdServerToSettle() async throws {
        let api = serve(models: [
            (503, #"{"_tag":"ServiceUnavailableError","message":"Location plugins did not finish activating"}"#),
            (200, #"{"data":[\#(pickle)]}"#),
            (200, #"{"data":[\#(pickle),\#(sonnet)]}"#),
        ])
        let snapshot = try await OpenCodeCatalog.load(api: api, directory: "/tmp/project")
        #expect(snapshot.models.map(\.modelID) == ["opencode/big-pickle", "anthropic/claude-sonnet-4-5"])
        #expect(snapshot.account == "Anthropic")
        #expect(OpenCodeStubProtocol.requestCount(host: api.baseURL.host() ?? "", path: "/api/model") == 4)
    }

    @Test func authErrorsFailRightAway() async {
        let api = serve(models: [(401, #"{"_tag":"UnauthorizedError","message":"Unauthorized"}"#)])
        await #expect(throws: OpenCodeAPIError.self) { try await OpenCodeCatalog.load(api: api, directory: "/tmp/project") }
        #expect(OpenCodeStubProtocol.requestCount(host: api.baseURL.host() ?? "", path: "/api/model") == 1)
    }
}

/// Answers requests from a queue of canned responses per host and path; the last one repeats.
/// Hosts keep parallel tests apart.
final class OpenCodeStubProtocol: URLProtocol, @unchecked Sendable {
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var responses: [String: [(Int, String)]] = [:]
        var counts: [String: Int] = [:]
    }

    private static let store = Store()

    static func serve(host: String, path: String, responses: [(Int, String)]) {
        store.lock.withLock { store.responses[host + path] = responses }
    }

    static func requestCount(host: String, path: String) -> Int {
        store.lock.withLock { store.counts[host + path] ?? 0 }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = (url.host() ?? "") + url.path()
        let (status, body) = Self.store.lock.withLock { () -> (Int, String) in
            Self.store.counts[key, default: 0] += 1
            guard var queue = Self.store.responses[key], let first = queue.first else { return (404, "{}") }
            if queue.count > 1 { queue.removeFirst() }
            Self.store.responses[key] = queue
            return first
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
