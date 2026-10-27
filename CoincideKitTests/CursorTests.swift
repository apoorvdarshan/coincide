import Foundation
import Testing

@testable import CoincideKit

/// Lines recorded from `cursor-agent acp` 2026.10.22 (paths shortened to /Users/dev/notes).
enum CursorFixtures {
    static let sessionID = "68a6eb78-54c6-4227-9151-708908518b4f"
    static let shellCallID = "call-6d0deb92-9047-400a-b655-178809fd34b1-0\nfc_bb71d4a0-cbea-905b-ae48-cf66d4bd35e8_0"
    static let projectPath = "/Users/dev/notes"

    static let initializeResult = json(
        #"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"mcpCapabilities":{"http":true,"sse":true},"promptCapabilities":{"audio":false,"embeddedContext":false,"image":true},"sessionCapabilities":{"list":{}}},"authMethods":[{"id":"cursor_login","name":"Cursor Login","description":"Authenticate using existing Cursor login credentials. Run 'agent login' first if not logged in."}]}"#
    )

    static let newSessionResult = json(
        #"{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","modes":{"currentModeId":"agent","availableModes":[{"id":"agent","name":"Agent","description":"Full agent capabilities with tool access"},{"id":"plan","name":"Plan","description":"Read-only mode for planning and designing before implementation"},{"id":"ask","name":"Ask","description":"Q&A mode - no edits or command execution"}]},"models":{"currentModelId":"grok-4.7","availableModels":[{"modelId":"grok-4.7","name":"Grok 4.7"},{"modelId":"grok-4.6","name":"Grok 4.6"},{"modelId":"composer-2.5","name":"Composer 2.5"},{"modelId":"grok-4.5","name":"Grok 4.5"}]},"configOptions":[{"id":"mode","name":"Mode","description":"Controls how the agent executes tasks","category":"mode","type":"select","currentValue":"agent","options":[{"value":"agent","name":"Agent","description":"Full agent capabilities with tool access"},{"value":"plan","name":"Plan","description":"Read-only mode for planning and designing before implementation"},{"value":"ask","name":"Ask","description":"Q&A mode - no edits or command execution"}]},{"id":"model","name":"Model","description":"Controls which model is used for responses","category":"model","type":"select","currentValue":"grok-4.7","options":[{"value":"grok-4.7","name":"Grok 4.7"},{"value":"grok-4.6","name":"Grok 4.6"},{"value":"composer-2.5","name":"Composer 2.5"},{"value":"grok-4.5","name":"Grok 4.5"}]}]}"#
    )

    /// `session/load` answers without `sessionId`.
    static var loadResult: JSONValue {
        guard case .object(var object) = newSessionResult else { return newSessionResult }
        object["sessionId"] = nil
        return .object(object)
    }

    /// What Cursor replays before answering `session/load`.
    static let replay = [
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Reply with exactly: pong"}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"pong"}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"tool_call","toolCallId":"replay-1-1","title":"`echo coincide-ok`","kind":"execute","status":"pending","rawInput":{"command":"echo coincide-ok"}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"tool_call_update","toolCallId":"replay-1-1","status":"completed","rawOutput":{"exitCode":0,"stdout":"coincide-ok\n","stderr":""}}}}"#,
    ]

    /// "Reply with exactly: pong".
    static let pongTurn = [
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"session_info_update","title":"Pong"}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"The"}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":" user"}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":" wants"}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":" me to reply with exactly \"pong\"."}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"pong"}}}}"#,
    ]

    /// "Run this shell command: echo coincide-ok", up to the permission request (approval mode).
    static let shellUntilPermission = [
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"The user wants me to run a shell command."}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"tool_call","toolCallId":"call-6d0deb92-9047-400a-b655-178809fd34b1-0\nfc_bb71d4a0-cbea-905b-ae48-cf66d4bd35e8_0","title":"Terminal","kind":"execute","status":"pending","rawInput":{}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-6d0deb92-9047-400a-b655-178809fd34b1-0\nfc_bb71d4a0-cbea-905b-ae48-cf66d4bd35e8_0","title":"`echo coincide-ok`","rawInput":{"command":"echo coincide-ok"}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-6d0deb92-9047-400a-b655-178809fd34b1-0\nfc_bb71d4a0-cbea-905b-ae48-cf66d4bd35e8_0","status":"in_progress"}}}"#,
    ]

    static let shellPermissionRequest =
        #"{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","toolCall":{"toolCallId":"call-6d0deb92-9047-400a-b655-178809fd34b1-0\nfc_bb71d4a0-cbea-905b-ae48-cf66d4bd35e8_0","title":"`echo coincide-ok`","kind":"execute","status":"pending","content":[{"type":"content","content":{"type":"text","text":"Not in allowlist: echo"}}]},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"allow-always","name":"Allow always","kind":"allow_always"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}"#

    static let shellCompleted = [
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-6d0deb92-9047-400a-b655-178809fd34b1-0\nfc_bb71d4a0-cbea-905b-ae48-cf66d4bd35e8_0","status":"completed","rawOutput":{"exitCode":0,"stdout":"coincide-ok\n","stderr":""}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}}"#,
    ]

    /// A full-access turn that reads, edits and searches a file while keeping a todo list.
    static let editTurn = [
        #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"I'll track the three steps on a todo list."}}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"todo-1","title":"Update TODOs","kind":"other","status":"pending","rawInput":{"_toolName":"updateTodos"}}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"todo-1","title":"Update TODOs: Read existing.txt, Change second line to: changed line, Grep the project for 'changed'","rawInput":{"_toolName":"updateTodos","todos":[{"id":"1","content":"Read existing.txt","status":"TODO_STATUS_IN_PROGRESS","createdAt":"1793082283651","updatedAt":"1793082283651","dependencies":[]},{"id":"2","content":"Change second line to: changed line","status":"TODO_STATUS_PENDING","createdAt":"1793082283651","updatedAt":"1793082283651","dependencies":[]},{"id":"3","content":"Grep the project for 'changed'","status":"TODO_STATUS_PENDING","createdAt":"1793082283651","updatedAt":"1793082283651","dependencies":[]}]}}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"todo-1","status":"in_progress"}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"todo-1","status":"completed"}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"read-1","title":"Read File","kind":"read","status":"pending","rawInput":{}}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"read-1","title":"Read existing.txt","rawInput":{"path":"/Users/dev/notes/existing.txt"},"locations":[{"path":"/Users/dev/notes/existing.txt"}]}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"read-1","status":"in_progress"}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"read-1","status":"completed","rawOutput":{"content":"first line\nsecond line\n"}}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"edit-1","title":"Edit File","kind":"edit","status":"pending","rawInput":{}}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"edit-1","title":"Edit `/Users/dev/notes/existing.txt`","rawInput":{"path":"/Users/dev/notes/existing.txt"},"locations":[{"path":"/Users/dev/notes/existing.txt"}]}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"edit-1","status":"in_progress"}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"edit-1","status":"completed","content":[{"type":"diff","path":"/Users/dev/notes/existing.txt","oldText":"first line\nsecond line\n","newText":"first line\nchanged line\n"}]}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"grep-1","title":"grep","kind":"search","status":"pending","rawInput":{}}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"grep-1","title":"grep \"changed\"","rawInput":{"pattern":"changed","path":"/Users/dev/notes"}}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"grep-1","status":"completed","rawOutput":{"totalMatches":1,"truncated":false}}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"push-1","title":"Terminal","kind":"execute","status":"pending","rawInput":{}}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"push-1","title":"`git push`","rawInput":{"command":"git push"}}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"push-1","status":"completed","rawOutput":{"exitCode":128,"stdout":"","stderr":"fatal: No configured push destination.\n"}}"#,
        #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ok"}}"#,
    ]

    static let updateTodosParams = json(
        #"{"toolCallId":"todo-2","todos":[{"id":"1","content":"Read existing.txt","status":"completed"},{"id":"2","content":"Change second line to: changed line","status":"in_progress"}],"merge":true}"#
    )

    /// Plan mode: the streamed `createPlan` tool, Cursor's step list, then the extension request.
    static let planTurn = [
        #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"I’ll draft a two-step plan."}}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"plan-1","title":"Create Plan","kind":"other","status":"pending","rawInput":{"_toolName":"createPlan"}}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"plan-1","title":"Create Plan: Add CONTRIBUTING.md","rawInput":{"_toolName":"createPlan","name":"Add CONTRIBUTING.md","plan":""}}"#,
        ##"{"sessionUpdate":"tool_call_update","toolCallId":"plan-1","title":"Create Plan: Add CONTRIBUTING.md","rawInput":{"_toolName":"createPlan","name":"Add CONTRIBUTING.md","plan":"# Add CONTRIBUTING.md\n\n1. Create [CONTRIBUTING.md](CONTRIBUTING.md) at the repo root with one line: `Contributions are welcome.`\n2. Leave the file uncommitted; this task only adds the file."}}"##,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"plan-1","status":"in_progress","content":[{"type":"content","content":{"type":"text","text":"Processing plan..."}}]}"#,
        #"{"sessionUpdate":"plan","entries":[{"content":"Create CONTRIBUTING.md with one line of text","priority":"medium","status":"pending"}]}"#,
    ]

    static let createPlanParams = json(
        ##"{"toolCallId":"plan-1","name":"Add CONTRIBUTING.md","overview":"Add a CONTRIBUTING.md file containing a single line of text. No other files change.","plan":"# Add CONTRIBUTING.md\n\n1. Create [CONTRIBUTING.md](CONTRIBUTING.md) at the repo root with one line: `Contributions are welcome.`\n2. Leave the file uncommitted; this task only adds the file.","todos":[{"id":"add-contributing","content":"Create CONTRIBUTING.md with one line of text","status":"pending"}],"isProject":false,"phases":[]}"##
    )

    /// How Cursor asks a question when the client does not implement `cursor/ask_question`.
    static let questionPermission = json(
        #"{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","toolCall":{"toolCallId":"ask-1_q0","title":"Which database?","kind":"other","status":"pending","content":[{"type":"content","content":{"type":"text","text":"Which database should the app use?"}}]},"options":[{"optionId":"postgres","name":"Postgres","kind":"allow_once"},{"optionId":"sqlite","name":"SQLite","kind":"allow_once"},{"optionId":"__ask_question_skip__","name":"Skip","kind":"reject_once"}]}"#
    )

    static let statusSignedIn = """
        {
          "status": "authenticated",
          "isAuthenticated": true,
          "hasAccessToken": true,
          "hasRefreshToken": true,
          "userInfo": {
            "email": "dev@example.com",
            "userId": 1234567,
            "firstName": "Dev",
            "lastName": "Example",
            "createdAt": "2025-01-01T00:00:00.000Z"
          }
        }
        """

    static let statusSignedOut = """
        {
          "status": "unauthenticated",
          "isAuthenticated": false,
          "hasAccessToken": false,
          "hasRefreshToken": false,
          "message": "Not logged in"
        }
        """

    static let about = """
        {
          "cliVersion": "2026.10.22-27dcf5f",
          "latestStatus": "up_to_date",
          "latestVersion": "2026.10.22-27dcf5f",
          "model": "Grok 4.7",
          "subscriptionTier": "Plus",
          "osPlatform": "darwin",
          "osArch": "arm64",
          "userEmail": "dev@example.com",
          "terminalProgram": "ghostty",
          "shell": "zsh",
          "lastRequestId": null
        }
        """

    /// `cursor-agent models`, including the zero-width spaces Cursor puts in some names.
    static let modelsCommand = """
        Available models

        composer-2.5 - Composer 2.5 (default)
        grok-4.7-low - Grok 4.7  Low
        grok-4.7-low-fast - Grok 4.7  Low Fast\u{200B}\u{200B}
        grok-4.7-high - Grok 4.7  High
        cursor-grok-4.6-medium - Grok 4.6 Medium

        Tip: use --model <id> (or /model <id> in interactive mode) to switch. Parameterized models also accept quoted overrides, e.g. --model 'claude-opus-4-8[context=1m,effort=high,fast=false]'.
        """

    /// `cursor/list_available_models` for an account whose models expose parameters.
    static let catalog = json(
        #"{"models":[{"value":"grok-4.7","name":"Grok 4.7","configOptions":[]},{"value":"claude-opus-4-8","name":"Claude Opus 4.8","configOptions":[{"id":"context","name":"Context","category":"model_config","type":"select","currentValue":"200k","options":[{"value":"200k","name":"200K"},{"value":"1m","name":"1M"}]},{"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"high","options":[{"value":"low","name":"Low"},{"value":"medium","name":"Medium"},{"value":"high","name":"High"},{"value":"max","name":"Max"}]},{"id":"fast","name":"Fast","category":"model_config","type":"select","currentValue":"false","options":[{"value":"false","name":"Off"},{"value":"true","name":"On"}]}]}]}"#
    )

    /// The `configOptions` of `newSessionResult` with `model` selected.
    static func configOptions(model: String) -> JSONValue {
        let options = (newSessionResult["configOptions"]?.array ?? []).map { option -> JSONValue in
            guard option["id"] == "model", case .object(var object) = option else { return option }
            object["currentValue"] = .string(model)
            return .object(object)
        }
        return .array(options)
    }

    static func json(_ text: String) -> JSONValue {
        JSONValue.parse(text) ?? .null
    }

    /// The `update` object of a recorded `session/update` line, or the line itself when it is one.
    static func update(_ line: String) -> JSONValue {
        let value = json(line)
        return value["params"]?["update"] ?? value
    }
}

// MARK: - Wire format

struct CursorRPCTests {
    @Test func parsesTheFourMessageShapes() {
        let request = CursorRPCMessage.parse(CursorFixtures.shellPermissionRequest)
        guard case .request(let id, let method, let params) = request else {
            Issue.record("Expected a request, got \(String(describing: request))")
            return
        }
        #expect(id == .number(0))
        #expect(method == "session/request_permission")
        #expect(params["toolCall"]?["kind"]?.string == "execute")

        guard case .notification(let notificationMethod, _) = CursorRPCMessage.parse(CursorFixtures.pongTurn[0]) else {
            Issue.record("Expected a notification")
            return
        }
        #expect(notificationMethod == "session/update")

        let result = CursorRPCMessage.parse(#"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"#)
        #expect(result == .response(id: .number(3), result: .success(["stopReason": "end_turn"])))

        let failure = CursorRPCMessage.parse(
            #"{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Invalid params","data":{"message":"Session \"0000\" not found"}}}"#)
        guard case .response(_, .failure(let error)) = failure else {
            Issue.record("Expected an error response")
            return
        }
        #expect(error.code == CursorRPCError.invalidParams)
        #expect(error.detail == #"Session "0000" not found"#)
        #expect(!error.isAuthRequired)

        #expect(CursorRPCMessage.parse("Debug: loading config") == nil)
    }

    @Test func encodesRequestsAndReplies() {
        let request = CursorRPCMessage.requestLine(id: 7, method: "session/set_mode", params: ["modeId": "plan"])
        #expect(
            CursorRPCMessage.parse(request)
                == .request(id: .number(7), method: "session/set_mode", params: ["modeId": "plan"]))
        let reply = CursorFixtures.json(CursorRPCMessage.resultLine(id: .number(0), ["outcome": ["outcome": "cancelled"]]))
        #expect(reply["id"] == .number(0))
        #expect(reply["result"]?["outcome"]?["outcome"]?.string == "cancelled")
        let error = CursorFixtures.json(CursorRPCMessage.errorLine(id: "x", code: -32601, message: "Method not found"))
        #expect(error["error"]?["code"]?.int == -32601)
    }

    @Test func authErrorsAreRecognized() {
        let error = CursorRPCError(
            code: -32000, message: "Authentication required. Please run 'agent login' first, then call authenticate().")
        #expect(error.isAuthRequired)
    }

    @Test func exitMessageKeepsTheLastStderrLines() {
        let stderr = "\u{1B}[31mwarming up\u{1B}[0m\nCannot use this model: gpt-x. Available models: composer-2.5\n"
        #expect(CursorConnection.exitMessage(status: 1, stderr: stderr).hasSuffix("Cannot use this model: gpt-x. Available models: composer-2.5"))
        #expect(!CursorConnection.exitMessage(status: 1, stderr: stderr).contains("\u{1B}"))
        #expect(CursorConnection.exitMessage(status: 9, stderr: "").contains("9"))
    }
}

// MARK: - Event mapping

struct CursorMapperTests {
    private func mapper() -> CursorEventMapper {
        var mapper = CursorEventMapper(workingDirectory: URL(fileURLWithPath: CursorFixtures.projectPath))
        mapper.beginTurn()
        return mapper
    }

    private func feed(_ lines: [String], into mapper: inout CursorEventMapper) -> [AgentEvent] {
        lines.flatMap { mapper.handle(update: CursorFixtures.update($0)) }
    }

    @Test func reasoningAndTextBecomeSegmentsWithFinalText() {
        var mapper = mapper()
        var events = feed(CursorFixtures.pongTurn, into: &mapper)
        events += mapper.endTurn()
        let thought = #"The user wants me to reply with exactly "pong"."#
        #expect(
            events == [
                .reasoningDelta(itemID: "cursor-1-1", delta: "The"),
                .reasoningDelta(itemID: "cursor-1-1", delta: " user"),
                .reasoningDelta(itemID: "cursor-1-1", delta: " wants"),
                .reasoningDelta(itemID: "cursor-1-1", delta: #" me to reply with exactly "pong"."#),
                .reasoningText(itemID: "cursor-1-1", text: thought),
                .assistantTextDelta(itemID: "cursor-1-2", delta: "pong"),
                .assistantText(itemID: "cursor-1-2", text: "pong"),
            ])
        #expect(mapper.takeFailure() == nil)
    }

    @Test func shellCommandStartsUpdatesAndCompletes() {
        var mapper = mapper()
        let events = feed(CursorFixtures.shellUntilPermission + CursorFixtures.shellCompleted, into: &mapper)
        let id = CursorFixtures.shellCallID
        #expect(events.contains(.toolStarted(ToolCallInfo(id: id, category: .command, title: "Terminal"))))
        #expect(
            events.contains(
                .toolUpdated(
                    ToolCallInfo(id: id, category: .command, title: "Run `echo coincide-ok`", detail: "echo coincide-ok"))))
        #expect(events.contains(.toolCompleted(id: id, status: .completed, output: "coincide-ok\n")))
        // The reasoning before the tool was closed when the tool started.
        let reasoningEnd = events.firstIndex(of: .reasoningText(itemID: "cursor-1-1", text: "The user wants me to run a shell command."))
        let toolStart = events.firstIndex { if case .toolStarted = $0 { true } else { false } }
        #expect(reasoningEnd != nil && toolStart != nil && reasoningEnd! < toolStart!)
        #expect(events.last == .assistantTextDelta(itemID: "cursor-1-2", delta: "done"))
    }

    @Test func fileToolsSearchAndFailedCommands() {
        var mapper = mapper()
        let events = feed(CursorFixtures.editTurn, into: &mapper)

        // Todo tool calls show up as the plan, not as tool items.
        #expect(!events.contains { event in
            if case .toolStarted(let info) = event { return info.id == "todo-1" }
            return false
        })
        #expect(
            events.contains(
                .plan(
                    text: """
                        - [ ] Read existing.txt (in progress)
                        - [ ] Change second line to: changed line
                        - [ ] Grep the project for 'changed'
                        """)))

        #expect(events.contains(.toolStarted(ToolCallInfo(id: "read-1", category: .read, title: "Read File"))))
        #expect(
            events.contains(
                .toolUpdated(
                    ToolCallInfo(
                        id: "read-1", category: .read, title: "Read existing.txt", detail: "/Users/dev/notes/existing.txt"))))
        #expect(events.contains(.toolCompleted(id: "read-1", status: .completed, output: "first line\nsecond line\n")))

        let diff = """
            --- a/existing.txt
            +++ b/existing.txt
            @@ -1,2 +1,2 @@
             first line
            -second line
            +changed line
            """
        #expect(
            events.contains(
                .toolUpdated(ToolCallInfo(id: "edit-1", category: .fileChange, title: "Edit existing.txt", detail: diff))))
        #expect(events.contains(.toolCompleted(id: "edit-1", status: .completed, output: nil)))

        #expect(events.contains(.toolCompleted(id: "grep-1", status: .completed, output: "1 match")))
        let grep = events.compactMap { event -> ToolCallInfo? in
            if case .toolUpdated(let info) = event, info.id == "grep-1" { return info }
            return nil
        }.last
        #expect(grep?.category == .search)
        #expect(grep?.title == #"grep "changed""#)

        #expect(
            events.contains(
                .toolCompleted(
                    id: "push-1", status: .failed, output: "fatal: No configured push destination.\nExit code 128")))
        #expect(events.last == .assistantTextDelta(itemID: "cursor-1-2", delta: "ok"))
    }

    @Test func todoUpdatesMergeIntoTheList() {
        var mapper = mapper()
        _ = feed(CursorFixtures.editTurn, into: &mapper)
        let events = mapper.handleTodos(CursorFixtures.updateTodosParams)
        #expect(
            events == [
                .plan(
                    text: """
                        - [x] Read existing.txt
                        - [ ] Change second line to: changed line (in progress)
                        - [ ] Grep the project for 'changed'
                        """)
            ])
        // The same list again changes nothing.
        #expect(mapper.handleTodos(CursorFixtures.updateTodosParams).isEmpty)
        let replaced = mapper.handleTodos(["todos": [["id": "9", "content": "Ship it", "status": "cancelled"]], "merge": false])
        #expect(replaced == [.plan(text: "- [ ] ~~Ship it~~")])
    }

    @Test func proposedPlanStreamsAndOutranksTheStepList() {
        var mapper = mapper()
        let events = feed(CursorFixtures.planTurn, into: &mapper)
        let plan = CursorFixtures.createPlanParams["plan"]?.string ?? ""
        #expect(events.filter { if case .plan = $0 { true } else { false } } == [.plan(text: plan)])
        #expect(!events.contains { if case .toolStarted = $0 { true } else { false } })
        // The request carries the same plan, so nothing new is reported.
        #expect(mapper.handleCreatePlan(CursorFixtures.createPlanParams).isEmpty)

        var withoutText = CursorEventMapper(workingDirectory: URL(fileURLWithPath: "/"))
        withoutText.beginTurn()
        let assembled = withoutText.handleCreatePlan([
            "name": "Add docs", "overview": "Write the docs.", "plan": "",
            "todos": [["id": "a", "content": "Write README", "status": "pending"]],
        ])
        #expect(assembled == [.plan(text: "# Add docs\n\nWrite the docs.\n\n- [ ] Write README")])
    }

    @Test func stepListWithoutAProposedPlanIsTheChecklist() {
        var mapper = mapper()
        let events = mapper.handle(
            update: CursorFixtures.json(
                #"{"sessionUpdate":"plan","entries":[{"content":"Write tests","priority":"high","status":"completed"},{"content":"Fix bug","priority":"medium","status":"in_progress"}]}"#
            ))
        #expect(events == [.plan(text: "- [x] Write tests\n- [ ] Fix bug (in progress)")])
    }

    @Test func commandApprovalUsesTheToolsTitleAndReason() {
        var mapper = mapper()
        _ = feed(CursorFixtures.shellUntilPermission, into: &mapper)
        let params = CursorFixtures.json(CursorFixtures.shellPermissionRequest)["params"] ?? .null
        let (events, request) = mapper.approval(id: "1:0", params: params)
        #expect(events.isEmpty)
        #expect(request.id == "1:0")
        #expect(request.category == .command)
        #expect(request.title == "Run `echo coincide-ok`")
        #expect(request.detail == "echo coincide-ok\n\nNot in allowlist: echo")
        #expect(request.options.map(\.id) == ["allow-once", "allow-always", "reject-once"])
        #expect(request.options.map(\.kind) == [.allowOnce, .allowAlways, .deny])
        #expect(request.toolCallID == CursorFixtures.shellCallID)
    }

    @Test func questionsArriveAsApprovalsWithTheirAnswers() {
        var mapper = mapper()
        let (_, request) = mapper.approval(id: "1:4", params: CursorFixtures.questionPermission)
        #expect(request.title == "Which database?")
        #expect(request.detail == "Which database should the app use?")
        #expect(request.category == .other)
        #expect(request.toolCallID == nil)
        #expect(request.options.map(\.label) == ["Postgres", "SQLite", "Skip"])
        #expect(request.options.map(\.kind) == [.allowOnce, .allowOnce, .deny])
    }

    @Test func unknownToolPermissionStillReadsWell() {
        var mapper = mapper()
        let params = CursorFixtures.json(
            #"{"toolCall":{"toolCallId":"web_fetch_12","title":"Fetch https://example.com","kind":"fetch","status":"pending"},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}"#
        )
        let (_, request) = mapper.approval(id: "1:1", params: params)
        #expect(request.category == .web)
        #expect(request.title == "Fetch https://example.com")
        #expect(request.toolCallID == "web_fetch_12")
    }

    @Test func declinedToolsCompleteAsDeclined() {
        var mapper = mapper()
        _ = feed(CursorFixtures.shellUntilPermission, into: &mapper)
        mapper.noteDeclined(toolCallID: CursorFixtures.shellCallID)
        let events = mapper.handle(
            update: CursorFixtures.json(
                #"{"sessionUpdate":"tool_call_update","toolCallId":"call-6d0deb92-9047-400a-b655-178809fd34b1-0\nfc_bb71d4a0-cbea-905b-ae48-cf66d4bd35e8_0","status":"completed"}"#
            ))
        #expect(events.last.map { if case .toolCompleted(_, .declined, _) = $0 { true } else { false } } == true)
    }

    @Test func webMcpTaskAndErrorsMapToTheirCategories() {
        var mapper = mapper()
        let events = feed(
            [
                #"{"sessionUpdate":"tool_call","toolCallId":"w1","title":"Web Fetch: https://example.com","kind":"fetch","status":"pending","rawInput":{"url":"https://example.com"}}"#,
                #"{"sessionUpdate":"tool_call","toolCallId":"w2","title":"Web Search: \"swift actors\"","kind":"search","status":"pending","rawInput":{"searchTerm":"swift actors"}}"#,
                #"{"sessionUpdate":"tool_call_update","toolCallId":"w2","status":"completed","rawOutput":{"referenceCount":3}}"#,
                #"{"sessionUpdate":"tool_call","toolCallId":"m1","title":"github: search_issues","kind":"other","status":"pending","rawInput":{"providerIdentifier":"github","toolName":"search_issues","args":{"q":"crash"}}}"#,
                #"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Task: Explore auth","kind":"other","status":"pending","rawInput":{"_toolName":"task","prompt":"Find where tokens are refreshed.","description":"Explore auth","subagentType":"explore"}}"#,
                #"{"sessionUpdate":"tool_call","toolCallId":"g1","title":"Find `*.txt`","kind":"search","status":"pending","rawInput":{"pattern":"*.txt"}}"#,
                #"{"sessionUpdate":"tool_call_update","toolCallId":"g1","status":"completed","rawOutput":{"error":"Path does not exist: /Users/dev/notes/terminals"}}"#,
                #"{"sessionUpdate":"tool_call","toolCallId":"d1","title":"Delete `old.txt`","kind":"delete","status":"pending","rawInput":{"path":"/Users/dev/notes/old.txt"}}"#,
                #"{"sessionUpdate":"tool_call_update","toolCallId":"d1","status":"completed","content":[{"type":"diff","path":"/Users/dev/notes/old.txt","oldText":"bye\n","newText":""}]}"#,
            ], into: &mapper)
        let started = Dictionary(
            events.compactMap { event -> (String, ToolCallInfo)? in
                if case .toolStarted(let info) = event { return (info.id, info) }
                return nil
            }, uniquingKeysWith: { first, _ in first })
        #expect(started["w1"] == ToolCallInfo(id: "w1", category: .web, title: "Web Fetch: https://example.com", detail: "https://example.com"))
        #expect(started["w2"]?.category == .web)
        #expect(started["m1"]?.category == .mcp)
        #expect(started["m1"]?.detail == "{\n  \"q\" : \"crash\"\n}")
        #expect(started["t1"] == ToolCallInfo(id: "t1", category: .task, title: "Task: Explore auth", detail: "Find where tokens are refreshed."))
        #expect(started["g1"]?.category == .search)
        #expect(started["d1"]?.title == "Delete old.txt")
        #expect(events.contains(.toolCompleted(id: "w2", status: .completed, output: "3 results")))
        #expect(events.contains(.toolCompleted(id: "g1", status: .failed, output: "Path does not exist: /Users/dev/notes/terminals")))
        #expect(events.contains(.toolUpdated(ToolCallInfo(id: "d1", category: .fileChange, title: "Delete old.txt", detail: "--- a/old.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-bye"))))
    }

    @Test func newFilesAreCreated() {
        var mapper = mapper()
        let events = feed(
            [
                #"{"sessionUpdate":"tool_call","toolCallId":"e1","title":"Edit File","kind":"edit","status":"pending","rawInput":{"path":"/Users/dev/notes/NOTES.md"}}"#,
                ##"{"sessionUpdate":"tool_call_update","toolCallId":"e1","status":"completed","content":[{"type":"diff","path":"/Users/dev/notes/NOTES.md","oldText":null,"newText":"# Notes\n"}]}"##,
            ], into: &mapper)
        #expect(
            events.contains(
                .toolUpdated(
                    ToolCallInfo(
                        id: "e1", category: .fileChange, title: "Create NOTES.md",
                        detail: "--- /dev/null\n+++ b/NOTES.md\n@@ -0,0 +1 @@\n+# Notes"))))
    }

    @Test func diffHeadersCursorLeavesInRebuiltTextAreDropped() {
        // Recorded from an edit that created a file in approval mode.
        var mapper = mapper()
        let events = feed(
            [
                #"{"sessionUpdate":"tool_call","toolCallId":"new-1","title":"Edit File","kind":"edit","status":"pending","rawInput":{}}"#,
                #"{"sessionUpdate":"tool_call_update","toolCallId":"new-1","title":"Edit `/Users/dev/notes/hello.txt`","rawInput":{"path":"/Users/dev/notes/hello.txt"},"locations":[{"path":"/Users/dev/notes/hello.txt"}]}"#,
                #"{"sessionUpdate":"tool_call_update","toolCallId":"new-1","status":"completed","content":[{"type":"diff","path":"/Users/dev/notes/hello.txt","oldText":"-- /dev/null","newText":"++ b//Users/dev/notes/hello.txt\nhi"}]}"#,
            ], into: &mapper)
        #expect(
            events.contains(
                .toolUpdated(
                    ToolCallInfo(
                        id: "new-1", category: .fileChange, title: "Create hello.txt",
                        detail: "--- /dev/null\n+++ b/hello.txt\n@@ -0,0 +1 @@\n+hi"))))

        let rebuilt = CursorEventMapper.diffSides(old: "-- a/f.txt\nfirst\nsecond", new: "++ b/f.txt\nfirst\nchanged")
        #expect(rebuilt.old == "first\nsecond")
        #expect(rebuilt.new == "first\nchanged")
        let sql = CursorEventMapper.diffSides(old: "-- a/migration comment\nSELECT 1;", new: "SELECT 2;")
        #expect(sql.old == "-- a/migration comment\nSELECT 1;")
    }

    @Test func transportDiagnosticsFailTheTurnButProseDoesNot() {
        let diagnostic = "Error: RetriableError: WritableIterable is closed"
        #expect(CursorEventMapper.transportFailure(in: diagnostic) == diagnostic)
        #expect(CursorEventMapper.transportFailure(in: "\n\nError: ConnectError: [unavailable] transport closed") != nil)
        #expect(CursorEventMapper.transportFailure(in: "\n\n" + diagnostic + "\n    at send (cli.js:1:2)\n") == diagnostic)
        #expect(CursorEventMapper.transportFailure(in: "\n\nUpgrade your plan to continue") == "Upgrade your plan to continue")
        #expect(CursorEventMapper.transportFailure(in: "The error was " + diagnostic) == nil)
        #expect(CursorEventMapper.transportFailure(in: "Error: RetriableError: [internal] Failed to run step") == nil)
        #expect(CursorEventMapper.transportFailure(in: diagnostic + "\nRecovered successfully.") == nil)

        var mapper = mapper()
        _ = mapper.handle(update: ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "\n\nError: ConnectError: [unavailable] transport closed"]])
        #expect(mapper.takeFailure() == "Error: ConnectError: [unavailable] transport closed")
    }

    @Test func usageUpdatesAndPromptUsage() {
        var mapper = mapper()
        let events = mapper.handle(update: ["sessionUpdate": "usage_update", "used": 53_000, "size": 200_000, "cost": ["amount": 0.42, "currency": "USD"]])
        #expect(events == [.usage(TokenUsage(inputTokens: 53_000, contextWindow: 200_000, costUSD: 0.42))])
        // The turn's summed input says nothing about the context in use, so the meter keeps `usage_update`'s.
        #expect(
            CursorEventMapper.promptUsage(["inputTokens": 1_000, "outputTokens": 20, "cachedReadTokens": 500])
                == TokenUsage(outputTokens: 20, cachedInputTokens: 500))
        #expect(CursorEventMapper.promptUsage(["inputTokens": 1_000]) == nil)
        #expect(CursorEventMapper.promptUsage(nil) == nil)
        // Options of unknown kinds are left out, and a request without a way to say no gets Cancel.
        #expect(CursorEventMapper.approvalOption(["optionId": "x", "name": "Maybe", "kind": "reject_politely"]) == nil)
        #expect(CursorEventMapper.approvalOption(["optionId": "x", "name": "Maybe"]) == nil)
        var approvals = mapper
        let (_, request) = approvals.approval(
            id: "r1", params: ["toolCall": ["toolCallId": "t1", "title": "Run"], "options": [["optionId": "go", "name": "Go", "kind": "allow_once"]]])
        #expect(request.options.map(\.kind) == [.allowOnce, .cancel])
    }

    @Test func todoStatusesInEverySpelling() {
        #expect(CursorEventMapper.todoStatus("TODO_STATUS_IN_PROGRESS") == .inProgress)
        #expect(CursorEventMapper.todoStatus("in_progress") == .inProgress)
        #expect(CursorEventMapper.todoStatus("inProgress") == .inProgress)
        #expect(CursorEventMapper.todoStatus("TODO_STATUS_COMPLETED") == .completed)
        #expect(CursorEventMapper.todoStatus("cancelled") == .cancelled)
        #expect(CursorEventMapper.todoStatus(nil) == .pending)
    }

    @Test func longCommandsAreSummarized() {
        #expect(CursorEventMapper.commandSummary("npm   test") == "npm test")
        #expect(CursorEventMapper.commandSummary("git commit -m \"$(cat <<'EOF'\nmsg\nEOF\n)\"") == "git commit -m \"$(cat <<'EOF' …")
        #expect(CursorEventMapper.commandSummary(String(repeating: "a", count: 120)).count == 80)
    }
}

// MARK: - Diffs

struct CursorDiffTests {
    @Test func modifiedLine() {
        #expect(
            CursorDiff.unified(old: "first line\nsecond line\n", new: "first line\nchanged line\n", path: "existing.txt")
                == "--- a/existing.txt\n+++ b/existing.txt\n@@ -1,2 +1,2 @@\n first line\n-second line\n+changed line")
    }

    @Test func newAndDeletedFiles() {
        #expect(CursorDiff.unified(old: nil, new: "a\nb\n", path: "new.txt") == "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+a\n+b")
        #expect(CursorDiff.unified(old: "x\n", new: nil, path: "gone.txt") == "--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-x")
    }

    @Test func insertionIsMinimal() {
        #expect(
            CursorDiff.unified(old: "a\nb\nc\n", new: "a\nb\nx\nc\n", path: "f")
                == "--- a/f\n+++ b/f\n@@ -1,3 +1,4 @@\n a\n b\n+x\n c")
    }

    @Test func distantChangesGetSeparateHunks() {
        let old = (1...20).map { "line \($0)" }
        var new = old
        new[1] = "LINE 2"
        new[17] = "LINE 18"
        let diff = CursorDiff.unified(
            old: old.joined(separator: "\n") + "\n", new: new.joined(separator: "\n") + "\n", path: "f.txt")
        let headers = diff.split(separator: "\n").filter { $0.hasPrefix("@@") }
        #expect(headers == ["@@ -1,5 +1,5 @@", "@@ -15,6 +15,6 @@"])
        #expect(diff.contains("-line 2\n+LINE 2"))
        #expect(diff.contains("-line 18\n+LINE 18"))
    }

    @Test func interleavedChangesStayCorrect() {
        let diff = CursorDiff.unified(old: "a\nb\nc\nd\n", new: "a\nB\nc\nD\ne\n", path: "f")
        #expect(diff == "--- a/f\n+++ b/f\n@@ -1,4 +1,5 @@\n a\n-b\n+B\n c\n-d\n+D\n+e")
    }
}

// MARK: - Models and status

struct CursorModelsTests {
    @Test func catalogCarriesEffortsAndContext() {
        let models = CursorModels.catalog(CursorFixtures.catalog)
        #expect(models.map(\.modelID) == ["grok-4.7", "claude-opus-4-8"])
        #expect(models[0].efforts.isEmpty)
        #expect(models[1].displayName == "Claude Opus 4.8")
        #expect(models[1].efforts == ["low", "medium", "high", "max"])
        #expect(models[1].defaultEffort == "high")
        #expect(models[1].contextWindow == 200_000)
        #expect(models.allSatisfy { $0.provider == .cursor })
    }

    @Test func defaultEntryComesFirstOnce() {
        let models = CursorModels.withDefault(CursorModels.catalog(CursorFixtures.catalog), currentModelName: "Grok 4.7")
        #expect(models.first?.modelID == CursorModels.defaultModelID)
        #expect(models.first?.displayName == "Default (Grok 4.7)")
        let listed = [ModelOption(provider: .cursor, modelID: "default", displayName: "Auto")]
        #expect(CursorModels.withDefault(listed, currentModelName: nil) == listed)
        #expect(CursorModels.withDefault([], currentModelName: nil).first?.displayName == "Default")
    }

    @Test func modelsCommandOutputIsParsed() {
        let models = CursorModels.parseModelsCommand(CursorFixtures.modelsCommand)
        #expect(models.map(\.modelID) == ["composer-2.5", "grok-4.7-low", "grok-4.7-low-fast", "grok-4.7-high", "cursor-grok-4.6-medium"])
        #expect(models.map(\.displayName) == ["Composer 2.5", "Grok 4.7 Low", "Grok 4.7 Low Fast", "Grok 4.7 High", "Grok 4.6 Medium"])
    }

    @Test func contextSizes() {
        #expect(CursorModels.contextWindow("256k") == 256_000)
        #expect(CursorModels.contextWindow("1M") == 1_000_000)
        #expect(CursorModels.contextWindow("200000") == 200_000)
        #expect(CursorModels.contextWindow("big") == nil)
        #expect(CursorModels.contextWindow(modelID: "grok-4.7[context=256k,reasoning_effort=medium,fast=false]") == 256_000)
        #expect(CursorModels.contextWindow(modelID: "composer-2.5[fast=false]") == nil)
        #expect(CursorModels.contextWindow(modelID: "composer-2.5") == nil)
    }

    @Test func configOptionsReadFlatAndGroupedChoices() {
        let option = CursorConfigOption(
            CursorFixtures.json(
                #"{"id":"effort","category":"thought_level","type":"select","currentValue":"low","options":[{"group":"g","name":"G","options":[{"value":"low","name":"Low"},{"value":"high","name":"High"}]}]}"#
            ))
        #expect(option == CursorConfigOption(id: "effort", category: "thought_level", currentValue: "low", values: ["low", "high"]))
        #expect(option?.isThoughtLevel == true)
    }
}

@MainActor
struct CursorProviderTests {
    @Test func statusOutputIsParsed() {
        #expect(CursorAccount.parse(CursorFixtures.statusSignedIn) == CursorAccount(auth: .signedIn, email: "dev@example.com"))
        #expect(CursorAccount.parse(CursorFixtures.statusSignedOut)?.auth == .signedOut)
        #expect(
            CursorAccount.parse(#"{"status": "error", "message": "Status check error: offline"}"#)?.auth
                == .failed("Status check error: offline"))
        #expect(CursorAccount.parse("✓ Logged in as dev@example.com\n")?.email == "dev@example.com")
        #expect(CursorAccount.parse("Not logged in")?.auth == .signedOut)
        #expect(CursorAccount.parse("") == nil)
    }

    @Test func aboutAndVersionAreParsed() {
        let about = CursorAbout.parse(CursorFixtures.about)
        #expect(about == CursorAbout(version: "2026.10.22-27dcf5f", tier: "Plus", email: "dev@example.com", model: "Grok 4.7"))
        #expect(CursorProvider.version(from: "2026.10.22-27dcf5f\n") == "2026.10.22-27dcf5f")
        #expect(CursorProvider.version(from: "v1.2.3") == "1.2.3")
        #expect(CursorProvider.version(from: "") == nil)
        #expect(CursorProvider.accountLabel(email: "dev@example.com", plan: "Plus") == "dev@example.com (Plus)")
        #expect(CursorProvider.accountLabel(email: nil, plan: nil) == nil)
    }

    @Test func missingExecutableIsNotInstalled() async {
        let provider = CursorProvider()
        let status = await provider.detect(executable: nil, environment: [:])
        #expect(status.state == .notInstalled)
        #expect(provider.executableNames == ["cursor-agent"])
    }

    @Test func signedOutProviderOffersTheFallbackModels() async {
        let models = await CursorProvider().models(status: ProviderStatus(state: .notAuthenticated), environment: [:])
        #expect(models.map(\.modelID) == [CursorModels.defaultModelID, "composer-2.5"])
    }

    /// The test process's environment with Cursor's settings in `directory`, away from the real ones.
    private static func environment(configIn directory: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CURSOR_CONFIG_DIR"] = directory.path
        return environment
    }

    /// A stand-in `cursor-agent`: answers the probe subcommands and, for `acp`, the model catalog.
    private func fakeCLI(acpAnswers: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let acp =
            acpAnswers
            ? #"""
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
              case "$line" in
                *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id" ;;
                *'"method":"cursor/list_available_models"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"models":[{"value":"composer-2.5","name":"Composer 2.5","configOptions":[]},{"value":"gpt-5.5","name":"GPT-5.5","configOptions":[{"id":"reasoning","category":"thought_level","type":"select","currentValue":"medium","options":[{"value":"low","name":"Low"},{"value":"medium","name":"Medium"},{"value":"high","name":"High"}]}]}]}}\n' "$id" ;;
              esac
            done
            """#
            : "echo 'acp unavailable' >&2; exit 3"
        let script = #"""
            #!/bin/bash
            case "$1" in
              --version) echo "2026.10.22-test" ;;
              status) printf '%s\n' '{"status":"authenticated","isAuthenticated":true,"userInfo":{"email":"dev@example.com"}}' ;;
              about) printf '%s\n' '{"cliVersion":"2026.10.22-test","model":"Composer 2.5","subscriptionTier":"Pro","userEmail":"dev@example.com"}' ;;
              models) printf 'Available models\n\ncomposer-2.5 - Composer 2.5 (default)\ngrok-4.7-high - Grok 4.7 High\n' ;;
              acp) ACP ;;
            esac
            """#.replacingOccurrences(of: "ACP", with: acp)
        let url = directory.appendingPathComponent("cursor-agent")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func detectsAndDiscoversModelsThroughTheCLI() async throws {
        let executable = try fakeCLI(acpAnswers: true)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let provider = CursorProvider()
        let environment = Self.environment(configIn: executable.deletingLastPathComponent())
        let status = await provider.detect(executable: executable, environment: environment)
        #expect(status.state == .ready)
        #expect(status.version == "2026.10.22-test")
        #expect(status.account == "dev@example.com (Pro)")

        let models = await provider.models(status: status, environment: environment)
        #expect(models.map(\.modelID) == [CursorModels.defaultModelID, "composer-2.5", "gpt-5.5"])
        #expect(models.first?.displayName == "Default (Composer 2.5)")
        #expect(models.last?.efforts == ["low", "medium", "high"])
        #expect(models.last?.defaultEffort == "medium")
    }

    @Test func fallsBackToTheModelsCommand() async throws {
        let executable = try fakeCLI(acpAnswers: false)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let provider = CursorProvider()
        let status = ProviderStatus(state: .ready, executable: executable)
        let models = await provider.models(
            status: status, environment: Self.environment(configIn: executable.deletingLastPathComponent()))
        #expect(models.map(\.modelID) == [CursorModels.defaultModelID, "composer-2.5", "grok-4.7-high"])
    }
}

// MARK: - Session

/// Stands in for `cursor-agent acp`: records what the session writes and answers through `reply`.
@MainActor
final class ScriptedCursorTransport: CursorTransport {
    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    let arguments: [String]
    var sent: [JSONValue] = []
    var isTerminated = false
    /// Lines to send back for each request the session writes.
    var reply: (_ id: JSONValue, _ method: String, _ params: JSONValue) -> [String]

    init(arguments: [String], reply: @escaping (_ id: JSONValue, _ method: String, _ params: JSONValue) -> [String]) {
        self.arguments = arguments
        self.reply = reply
    }

    func start() throws {}

    func send(_ line: String) {
        let message = JSONValue.parse(line) ?? .null
        sent.append(message)
        guard let method = message["method"]?.string, let id = message["id"] else { return }
        for answer in reply(id, method, message["params"] ?? .null) { onLine?(answer) }
    }

    func terminate() { isTerminated = true }

    func deliver(_ lines: [String]) {
        for line in lines { onLine?(line) }
    }

    /// Answers the last request with `method`.
    func answer(_ method: String, with result: JSONValue) {
        guard let id = sent.last(where: { $0["method"]?.string == method && $0["id"] != nil })?["id"] else { return }
        onLine?(CursorRPCMessage.resultLine(id: id, result))
    }

    func methods() -> [String] { sent.compactMap { $0["method"]?.string } }

    func messages(_ method: String) -> [JSONValue] { sent.filter { $0["method"]?.string == method } }
}

@MainActor
final class CursorSessionHarness {
    var transports: [ScriptedCursorTransport] = []
    var events: [AgentEvent] = []
    var newSessionResult = CursorFixtures.newSessionResult
    var newSessionReply: ((JSONValue) -> [String])?
    var configOptionsAfterSet: [String: JSONValue] = [:]
    var loadReply: (JSONValue) -> [String] = { id in
        CursorFixtures.replay + [CursorRPCMessage.resultLine(id: id, CursorFixtures.loadResult)]
    }
    /// Runs before the scripted answer to each request, for example to save a model the way Cursor does.
    var beforeReply: ((_ method: String, _ params: JSONValue) -> Void)?
    /// Stands in for `~/.cursor`, so the tests never touch the real Cursor settings.
    let configDirectory: URL
    private(set) var session: CursorSession!

    init(
        accessMode: AccessMode = .fullAccess, resume: String? = nil, modelID: String = CursorModels.defaultModelID
    ) {
        configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coincide-cursor-config-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let launch = AgentLaunch(
            provider: .cursor, executable: URL(fileURLWithPath: "/usr/bin/false"),
            environment: ["CURSOR_CONFIG_DIR": configDirectory.path],
            workingDirectory: URL(fileURLWithPath: CursorFixtures.projectPath), resumeSessionID: resume,
            selection: ModelSelection(provider: .cursor, modelID: modelID), accessMode: accessMode, interactionMode: .build)
        let settings = CursorModelSettings(fileURL: configDirectory.appendingPathComponent("cli-config.json"))
        session = CursorSession(launch: launch, modelSettings: settings) { [unowned self] arguments in
            let transport = ScriptedCursorTransport(arguments: arguments) { [unowned self] id, method, params in
                self.reply(id: id, method: method, params: params)
            }
            self.transports.append(transport)
            return transport
        }
        session.onEvent = { [unowned self] event in self.events.append(event) }
    }

    deinit {
        try? FileManager.default.removeItem(at: configDirectory)
    }

    var transport: ScriptedCursorTransport { transports[transports.count - 1] }

    var configFile: URL { configDirectory.appendingPathComponent("cli-config.json") }

    /// The Cursor settings file, as a JSON object.
    var config: [String: Any] {
        get {
            guard let data = try? Data(contentsOf: configFile),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return object
        }
        set {
            let data = try? JSONSerialization.data(withJSONObject: newValue, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: configFile)
        }
    }

    /// The model the Cursor settings select.
    var configModel: String? { CursorModelSettings.modelID(in: config) }

    /// Writes Cursor settings that select `model`, as `cursor-agent` keeps them.
    func writeConfig(model: String) {
        config = [
            "version": 1, "approvalMode": "allowlist", "permissions": ["allow": ["Shell(ls)"], "deny": [String]()],
            "hasChangedDefaultModel": true,
            "model": ["modelId": model, "displayModelId": model, "displayName": model, "maxMode": false],
            "selectedModel": ["modelId": model, "parameters": [["id": "fast", "value": "false"]]],
            "modelSelectionHistory": [model],
        ]
    }

    /// Saves `model` as the default, the way `cursor-agent` does on every model change.
    func saveModelLikeCursor(_ model: String) {
        var object = config
        object["model"] = ["modelId": model, "displayModelId": model, "displayName": model, "maxMode": false]
        object["selectedModel"] = ["modelId": model, "parameters": [[String: String]]()]
        object["hasChangedDefaultModel"] = true
        let history = (object["modelSelectionHistory"] as? [String] ?? []).filter { $0 != model }
        object["modelSelectionHistory"] = [model] + history
        config = object
    }

    func input(
        _ text: String = "Reply with exactly: pong", modelID: String = CursorModels.defaultModelID, effort: String? = nil,
        accessMode: AccessMode = .fullAccess, mode: InteractionMode = .build, images: [String] = []
    ) -> AgentTurnInput {
        AgentTurnInput(
            text: text, imagePaths: images, selection: ModelSelection(provider: .cursor, modelID: modelID, effort: effort),
            accessMode: accessMode, interactionMode: mode)
    }

    var completions: [TurnOutcome] {
        events.compactMap { if case .turnCompleted(let outcome) = $0 { outcome } else { nil } }
    }

    /// The questions of the last `.userInputRequested` event.
    var lastQuestion: UserInputRequest? {
        events.lazy.compactMap { if case .userInputRequested(let request) = $0 { request } else { nil } }.last
    }

    /// Replies the session sent to the agent's own requests.
    var replies: [JSONValue] { transport.sent.filter { $0["method"] == nil } }

    private func reply(id: JSONValue, method: String, params: JSONValue) -> [String] {
        beforeReply?(method, params)
        switch method {
        case "initialize":
            return [CursorRPCMessage.resultLine(id: id, CursorFixtures.initializeResult)]
        case "session/new":
            return newSessionReply?(id) ?? [CursorRPCMessage.resultLine(id: id, newSessionResult)]
        case "session/load":
            return loadReply(id)
        case "session/set_mode":
            let update = CursorRPCMessage.notificationLine(
                method: "session/update",
                params: [
                    "sessionId": .string(CursorFixtures.sessionID),
                    "update": ["sessionUpdate": "current_mode_update", "currentModeId": params["modeId"] ?? .null],
                ])
            return [update, CursorRPCMessage.resultLine(id: id, [:])]
        case "session/set_config_option":
            let value = params["value"]?.string ?? ""
            let options =
                configOptionsAfterSet[value]
                ?? (params["configId"] == "model" ? CursorFixtures.configOptions(model: value) : [])
            return [CursorRPCMessage.resultLine(id: id, ["configOptions": options])]
        default:
            return []
        }
    }
}

@MainActor
struct CursorSessionTests {
    @Test func startsAFreshChatThatRunsEverythingInFullAccess() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        #expect(harness.transport.arguments == ["--force", "acp"])
        #expect(harness.transport.methods() == ["initialize", "session/new"])
        let initialize = harness.transport.messages("initialize").first
        #expect(initialize?["params"]?["clientCapabilities"]?["_meta"]?["parameterizedModelPicker"] == true)
        #expect(initialize?["params"]?["clientInfo"]?["name"] == "Coincide")
        #expect(harness.transport.messages("session/new").first?["params"]?["cwd"]?.string == CursorFixtures.projectPath)
        #expect(harness.session.sessionID == CursorFixtures.sessionID)
        #expect(harness.events == [.sessionStarted(id: CursorFixtures.sessionID), .modelResolved("grok-4.7")])
    }

    @Test func approvalModeLaunchesWithoutForce() async throws {
        let harness = CursorSessionHarness(accessMode: .approval)
        try await harness.session.start()
        #expect(harness.transport.arguments == ["acp"])
    }

    @Test func resumingLoadsTheChatAndIgnoresItsReplay() async throws {
        let harness = CursorSessionHarness(resume: CursorFixtures.sessionID)
        try await harness.session.start()
        #expect(harness.transport.methods() == ["initialize", "session/load"])
        #expect(harness.transport.messages("session/load").first?["params"]?["sessionId"]?.string == CursorFixtures.sessionID)
        #expect(harness.events == [.sessionStarted(id: CursorFixtures.sessionID), .modelResolved("grok-4.7")])
    }

    @Test func failedResumeStartsANewChat() async throws {
        let harness = CursorSessionHarness(resume: "00000000-0000-4000-8000-000000000000")
        harness.loadReply = { id in
            [
                #"{"jsonrpc":"2.0","id":\#(id.displayText),"error":{"code":-32602,"message":"Invalid params","data":{"message":"Session \"00000000-0000-4000-8000-000000000000\" not found"}}}"#
            ]
        }
        try await harness.session.start()
        #expect(harness.transport.methods() == ["initialize", "session/load", "session/new"])
        #expect(harness.session.sessionID == CursorFixtures.sessionID)
        #expect(harness.events.contains(.sessionStarted(id: CursorFixtures.sessionID)))
        #expect(harness.events.contains { if case .notice(let text) = $0 { text.contains("not found") } else { false } })
    }

    @Test func notSignedInIsExplained() async {
        let harness = CursorSessionHarness()
        harness.newSessionReply = { id in
            [
                CursorRPCMessage.errorLine(
                    id: id, code: -32000,
                    message: "Authentication required. Please run 'agent login' first, then call authenticate() with methodId 'cursor_login'."
                )
            ]
        }
        do {
            try await harness.session.start()
            Issue.record("Starting without a sign-in should fail")
        } catch {
            #expect(error.localizedDescription.contains("cursor-agent login"))
        }
    }

    @Test func aChatWithoutAnIdIsAProtocolError() async {
        let harness = CursorSessionHarness()
        harness.newSessionResult = ["modes": ["currentModeId": "agent"]]
        await #expect(throws: AgentError.self) { try await harness.session.start() }
    }

    @Test func aTurnStreamsAndCompletesOnce() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        harness.events.removeAll()
        try await harness.session.send(harness.input())
        let prompt = harness.transport.messages("session/prompt").first
        #expect(prompt?["params"]?["sessionId"]?.string == CursorFixtures.sessionID)
        #expect(prompt?["params"]?["prompt"] == [["type": "text", "text": "Reply with exactly: pong"]])
        // Already in agent mode with the CLI's own model: nothing to change first.
        #expect(harness.transport.methods() == ["initialize", "session/new", "session/prompt"])

        harness.transport.deliver(CursorFixtures.pongTurn)
        harness.transport.answer("session/prompt", with: ["stopReason": "end_turn"])
        #expect(harness.events.contains(.assistantTextDelta(itemID: "cursor-1-2", delta: "pong")))
        #expect(harness.events.suffix(2) == [.assistantText(itemID: "cursor-1-2", text: "pong"), .turnCompleted(.completed)])
        #expect(harness.completions == [.completed])

        // Updates after the turn are not part of any turn.
        harness.transport.deliver([CursorFixtures.pongTurn[5]])
        #expect(harness.completions.count == 1)
        #expect(harness.events.last == .turnCompleted(.completed))
    }

    @Test func modelEffortAndPlanModeAreAppliedBeforeThePrompt() async throws {
        let harness = CursorSessionHarness()
        harness.newSessionResult = CursorFixtures.json(
            #"{"sessionId":"s-1","modes":{"currentModeId":"agent","availableModes":[]},"models":{"currentModelId":"composer-2.5","availableModels":[{"modelId":"composer-2.5","name":"Composer 2.5"},{"modelId":"claude-opus-4-8","name":"Claude Opus 4.8"}]},"configOptions":[{"id":"mode","category":"mode","type":"select","currentValue":"agent","options":[{"value":"agent","name":"Agent"},{"value":"plan","name":"Plan"}]},{"id":"model","category":"model","type":"select","currentValue":"composer-2.5","options":[{"value":"composer-2.5","name":"Composer 2.5"},{"value":"claude-opus-4-8","name":"Claude Opus 4.8"}]}]}"#
        )
        let opusOptions =
            #"[{"id":"mode","category":"mode","type":"select","currentValue":"agent","options":[{"value":"agent","name":"Agent"},{"value":"plan","name":"Plan"}]},{"id":"model","category":"model","type":"select","currentValue":"claude-opus-4-8","options":[{"value":"composer-2.5","name":"Composer 2.5"},{"value":"claude-opus-4-8","name":"Claude Opus 4.8"}]},{"id":"context","category":"model_config","type":"select","currentValue":"1m","options":[{"value":"200k","name":"200K"},{"value":"1m","name":"1M"}]},{"id":"effort","category":"thought_level","type":"select","currentValue":"medium","options":[{"value":"low","name":"Low"},{"value":"medium","name":"Medium"},{"value":"high","name":"High"}]}]"#
        let highEffort = opusOptions.replacingOccurrences(of: "\"currentValue\":\"medium\"", with: "\"currentValue\":\"high\"")
        harness.configOptionsAfterSet = [
            "claude-opus-4-8": CursorFixtures.json(opusOptions), "high": CursorFixtures.json(highEffort),
        ]
        try await harness.session.start()
        try await harness.session.send(harness.input(modelID: "claude-opus-4-8", effort: "high", mode: .plan))

        let calls = harness.transport.sent.compactMap { message -> String? in
            guard let method = message["method"]?.string else { return nil }
            let params = message["params"] ?? .null
            switch method {
            case "session/set_config_option": return "\(params["configId"]?.string ?? "")=\(params["value"]?.string ?? "")"
            case "session/set_mode": return "mode=\(params["modeId"]?.string ?? "")"
            default: return method
            }
        }
        #expect(calls == ["initialize", "session/new", "model=claude-opus-4-8", "effort=high", "mode=plan", "session/prompt"])
        #expect(harness.events.contains(.modelResolved("claude-opus-4-8")))

        // The same selection on the next turn changes nothing, and the context size is reported.
        harness.transport.answer("session/prompt", with: ["stopReason": "end_turn"])
        #expect(harness.events.contains(.usage(TokenUsage(contextWindow: 1_000_000))))
        let before = harness.transport.sent.count
        try await harness.session.send(harness.input(modelID: "claude-opus-4-8", effort: "high", mode: .plan))
        #expect(harness.transport.sent.count == before + 1)
        #expect(harness.transport.methods().last == "session/prompt")
    }

    @Test func modelsCursorDoesNotListUseTheLaunchFlag() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input(modelID: "grok-4.7-high"))
        #expect(harness.transports.count == 2)
        #expect(harness.transports[0].isTerminated)
        #expect(harness.transport.arguments == ["--force", "--model", "grok-4.7-high", "acp"])
        // Cursor stores a chat with its first prompt, so there was nothing to reopen yet.
        #expect(harness.transport.methods() == ["initialize", "session/new", "session/prompt"])
        #expect(harness.transport.messages("session/set_config_option").isEmpty)
        #expect(!harness.events.contains { if case .notice = $0 { true } else { false } })

        // The next turn with the same model keeps the process.
        harness.transport.answer("session/prompt", with: ["stopReason": "end_turn"])
        try await harness.session.send(harness.input(modelID: "grok-4.7-high"))
        #expect(harness.transports.count == 2)

        // A listed model is set through the protocol, without another restart.
        harness.transport.answer("session/prompt", with: ["stopReason": "end_turn"])
        try await harness.session.send(harness.input(modelID: "composer-2.5"))
        #expect(harness.transports.count == 2)
        #expect(harness.transport.messages("session/set_config_option").first?["params"]?["value"] == "composer-2.5")
    }

    @Test func approvalsRoundTrip() async throws {
        let harness = CursorSessionHarness(accessMode: .approval)
        try await harness.session.start()
        try await harness.session.send(harness.input("Run this shell command: echo coincide-ok", accessMode: .approval))
        harness.transport.deliver(CursorFixtures.shellUntilPermission + [CursorFixtures.shellPermissionRequest])

        guard case .approvalRequested(let request) = harness.events.last else {
            Issue.record("Expected an approval request, got \(String(describing: harness.events.last))")
            return
        }
        #expect(request.id == "1:0")
        #expect(request.title == "Run `echo coincide-ok`")
        harness.session.respond(to: request.id, optionID: "allow-once")
        let answer = harness.transport.sent.last
        #expect(answer?["id"] == .number(0))
        #expect(answer?["result"] == ["outcome": ["outcome": "selected", "optionId": "allow-once"]])

        // Answering twice does nothing.
        let count = harness.transport.sent.count
        harness.session.respond(to: request.id, optionID: "reject-once")
        #expect(harness.transport.sent.count == count)

        harness.transport.deliver(CursorFixtures.shellCompleted)
        harness.transport.answer("session/prompt", with: ["stopReason": "end_turn"])
        let id = CursorFixtures.shellCallID
        #expect(harness.events.contains(.toolCompleted(id: id, status: .completed, output: "coincide-ok\n")))
        #expect(harness.completions == [.completed])
    }

    @Test func interruptCancelsPendingApprovalsAndEndsOnce() async throws {
        let harness = CursorSessionHarness(accessMode: .approval)
        try await harness.session.start()
        try await harness.session.send(harness.input("Run this shell command: sleep 20", accessMode: .approval))
        harness.transport.deliver(CursorFixtures.shellUntilPermission + [CursorFixtures.shellPermissionRequest])

        harness.session.interrupt()
        #expect(harness.transport.messages("session/cancel").first?["params"]?["sessionId"]?.string == CursorFixtures.sessionID)
        let cancelled = harness.transport.sent.last(where: { $0["result"] != nil })
        #expect(cancelled?["result"] == ["outcome": ["outcome": "cancelled"]])
        harness.session.interrupt()
        #expect(harness.transport.messages("session/cancel").count == 1)

        harness.transport.answer("session/prompt", with: ["stopReason": "cancelled"])
        #expect(harness.completions == [.interrupted])
    }

    @Test func unconfirmedInterruptStillEndsTheTurn() async throws {
        let harness = CursorSessionHarness()
        harness.session.interruptGrace = .milliseconds(20)
        try await harness.session.start()
        try await harness.session.send(harness.input())
        harness.session.interrupt()
        for _ in 0..<100 where harness.completions.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.completions == [.interrupted])
        // A late answer for the abandoned prompt is ignored.
        harness.transport.answer("session/prompt", with: ["stopReason": "cancelled"])
        #expect(harness.completions == [.interrupted])
    }

    @Test func changingAccessModeRestartsAndReloadsTheChat() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input())
        harness.transport.answer("session/prompt", with: ["stopReason": "end_turn"])
        harness.events.removeAll()

        try await harness.session.send(harness.input(accessMode: .approval))
        #expect(harness.transports.count == 2)
        #expect(harness.transports[0].isTerminated)
        #expect(harness.transport.arguments == ["acp"])
        #expect(harness.transport.methods() == ["initialize", "session/load", "session/prompt"])
        // The reloaded chat keeps its id and its replay does not reach the transcript.
        #expect(harness.events == [.sessionStarted(id: CursorFixtures.sessionID), .modelResolved("grok-4.7")])
    }

    @Test func aCrashFailsTheTurnAndEndsTheSession() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input())
        harness.transport.deliver([CursorFixtures.pongTurn[1]])
        harness.transport.onExit?(1, "Error: socket hang up\n")
        #expect(harness.completions == [.failed("Error: socket hang up")])
        #expect(harness.events.last == .sessionExited(error: "Error: socket hang up"))
        #expect(harness.events.contains(.reasoningText(itemID: "cursor-1-1", text: "The")))
    }

    @Test func extensionRequestsAreAnswered() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input(mode: .plan))
        harness.transport.deliver([
            #"{"jsonrpc":"2.0","id":0,"method":"cursor/update_todos","params":{"toolCallId":"t","todos":[{"id":"1","content":"Read the code","status":"in_progress"}],"merge":false}}"#,
            ##"{"jsonrpc":"2.0","id":1,"method":"cursor/create_plan","params":{"toolCallId":"p","name":"Plan","plan":"# Plan\n\n1. Do it"}}"##,
            #"{"jsonrpc":"2.0","id":2,"method":"cursor/ask_question","params":{"toolCallId":"q","questions":[]}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"cursor/task","params":{"toolCallId":"x","description":"Explore"}}"#,
        ])
        let replies = harness.replies
        #expect(replies.map { $0["id"] } == [.number(0), .number(1), .number(2), .number(3)])
        #expect(replies[0]["result"] == [:])
        #expect(replies[1]["result"] == ["outcome": ["outcome": "accepted"]])
        // A question request without questions is skipped right away.
        #expect(replies[2]["result"] == ["outcome": ["outcome": "skipped"]])
        #expect(replies[3]["result"] == [:])
        #expect(harness.events.contains(.plan(text: "- [ ] Read the code (in progress)")))
        #expect(harness.events.contains(.plan(text: "# Plan\n\n1. Do it")))
    }

    @Test func imagesAreSentAsPromptBlocks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)

        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input("What is this?", images: [image.path]))
        let prompt = harness.transport.messages("session/prompt").first?["params"]?["prompt"]
        #expect(
            prompt == [
                ["type": "text", "text": "What is this?"],
                ["type": "image", "mimeType": "image/png", "data": .string(Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())],
            ])

        await #expect(throws: AgentError.self) {
            try await harness.session.send(harness.input("Again", images: [directory.appendingPathComponent("missing.png").path]))
        }
    }

    @Test func aTransportDiagnosticFailsTheTurn() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input())
        harness.transport.deliver([
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\n\nError: ConnectError: [unavailable] transport closed"}}}}"#
        ])
        harness.transport.answer("session/prompt", with: ["stopReason": "end_turn"])
        #expect(harness.completions == [.failed("Error: ConnectError: [unavailable] transport closed")])
    }

    @Test func promptErrorsFailTheTurn() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input())
        let id = harness.transport.messages("session/prompt").first?["id"] ?? .null
        harness.transport.deliver([CursorRPCMessage.errorLine(id: id, code: -32603, message: "Internal error")])
        #expect(harness.completions == [.failed("Internal error")])
    }

    @Test func shutdownStopsEverythingQuietly() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input())
        harness.events.removeAll()
        harness.session.shutdown()
        #expect(harness.transport.isTerminated)
        #expect(harness.transport.messages("session/cancel").count == 1)
        harness.transport.deliver(CursorFixtures.pongTurn)
        #expect(harness.events.isEmpty)
    }
}

// MARK: - Mapper: questions, error reports, long outputs

struct CursorMapperEdgeTests {
    private func mapper() -> CursorEventMapper {
        var mapper = CursorEventMapper(workingDirectory: URL(fileURLWithPath: CursorFixtures.projectPath))
        mapper.beginTurn()
        return mapper
    }

    private func chunk(_ text: String) -> JSONValue {
        ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(text)]]
    }

    @Test func questionsBecomeUserInputWithTheirOptions() {
        var mapper = mapper()
        _ = mapper.handle(update: chunk("Before I start:"))
        let (events, request, questions) = mapper.questions(id: "1:5", params: CursorFixtures.askQuestionParams)
        // The open text closes before the question.
        #expect(events == [.assistantText(itemID: "cursor-1-1", text: "Before I start:")])
        #expect(request.id == "1:5")
        #expect(request.title == "Setup")
        #expect(request.questions.map(\.id) == ["db", "extras", "name"])
        #expect(request.questions[0].prompt == "Which database should the app use?")
        #expect(request.questions[0].options.map(\.label) == ["Postgres", "SQLite", "SQLite (sqlite-wal)"])
        #expect(request.questions[0].allowsMultipleSelection == false)
        // Cursor's answers carry option ids only.
        #expect(request.questions[0].allowsFreeText == false)
        #expect(request.questions[1].allowsMultipleSelection)
        // A question without a prompt borrows the title; one without options takes typed text.
        #expect(request.questions[2].prompt == "Setup")
        #expect(request.questions[2].allowsFreeText)
        #expect(questions[0].options.map(\.id) == ["pg", "sqlite", "sqlite-wal"])
    }

    @Test func answersGoBackAsOptionIDs() {
        let questions = CursorEventMapper().questionsOf(CursorFixtures.askQuestionParams)
        let answered = CursorEventMapper.questionReply(
            questions, answers: ["db": ["SQLite"], "extras": ["Auth", "Billing"], "name": []])
        #expect(
            answered
                == [
                    "outcome": [
                        "outcome": "answered",
                        "answers": [
                            ["questionId": "db", "selectedOptionIds": ["sqlite"]],
                            ["questionId": "extras", "selectedOptionIds": ["auth", "billing"]],
                        ],
                    ]
                ])
        // A single-choice question keeps one answer; option ids are accepted too.
        let single = CursorEventMapper.questionReply(questions, answers: ["db": ["pg", "SQLite"]])
        #expect(single["outcome"]?["answers"] == [["questionId": "db", "selectedOptionIds": ["pg"]]])
        // Dismissed or unanswered questions are skipped.
        #expect(CursorEventMapper.questionReply(questions, answers: [:]) == ["outcome": ["outcome": "skipped"]])
        #expect(CursorEventMapper.questionReply(questions, answers: ["db": ["  "]]) == ["outcome": ["outcome": "skipped"]])
    }

    @Test func typedAnswersReachTheModelAsTheSkipReason() {
        let questions = CursorEventMapper().questionsOf(CursorFixtures.askQuestionParams)
        let reply = CursorEventMapper.questionReply(questions, answers: ["db": ["Postgres"], "name": ["notes-app"]])
        #expect(reply["outcome"]?["outcome"] == "skipped")
        #expect(
            reply["outcome"]?["reason"]?.string
                == "The user replied in their own words:\nWhich database should the app use?: Postgres\nSetup: notes-app")
    }

    @Test func theQuestionToolIsShownAsTheQuestionOnly() {
        var mapper = mapper()
        let events = mapper.handle(
            update: CursorFixtures.json(
                #"{"sessionUpdate":"tool_call","toolCallId":"ask-1","title":"Setup","kind":"think","status":"pending","rawInput":{"_toolName":"askQuestion","title":"Setup","questions":[]}}"#
            ))
        #expect(events.isEmpty)
        let completed = mapper.handle(
            update: CursorFixtures.json(#"{"sessionUpdate":"tool_call_update","toolCallId":"ask-1","status":"completed"}"#))
        #expect(completed.isEmpty)
    }

    @Test func cursorsOwnErrorReportBecomesTheFailure() {
        var mapper = mapper()
        var events = mapper.handle(update: chunk("Let me look."))
        let report = "\n\nError: ConnectError: [resource_exhausted] You've hit your usage limit"
        events += mapper.handle(update: chunk(report))
        // The report is held back instead of streaming into the reply.
        #expect(events == [.assistantTextDelta(itemID: "cursor-1-1", delta: "Let me look.")])
        #expect(mapper.takeFailure() == "Error: ConnectError: [resource_exhausted] You've hit your usage limit")
        #expect(mapper.endTurn() == [.assistantText(itemID: "cursor-1-1", text: "Let me look.")])
    }

    @Test func aHeldReportFollowedByMoreOutputWasText() {
        var mapper = mapper()
        let report = "\n\nError: TypeError: x is undefined"
        var events = mapper.handle(update: chunk(report))
        #expect(events.isEmpty)
        events += mapper.handle(update: chunk(" — that is what the log says."))
        #expect(
            events == [
                .assistantTextDelta(itemID: "cursor-1-1", delta: report),
                .assistantTextDelta(itemID: "cursor-1-1", delta: " — that is what the log says."),
            ])
        #expect(mapper.takeFailure() == nil)

        // Unrelated updates such as the chat title do not release it.
        var titled = self.mapper()
        _ = titled.handle(update: chunk("\n\nUpgrade your plan to continue"))
        #expect(titled.handle(update: ["sessionUpdate": "session_info_update", "title": "Pong"]).isEmpty)
        #expect(titled.takeFailure() == "Upgrade your plan to continue")

        // Without a failure the held text is reported when the turn ends.
        var ending = self.mapper()
        _ = ending.handle(update: chunk("\n\nError: RetriableError: [internal] step failed"))
        #expect(
            ending.endTurn() == [
                .assistantTextDelta(itemID: "cursor-1-1", delta: "\n\nError: RetriableError: [internal] step failed"),
                .assistantText(itemID: "cursor-1-1", text: "\n\nError: RetriableError: [internal] step failed"),
            ])
    }

    @Test func errorReportShapes() {
        #expect(CursorEventMapper.errorReport(in: "\n\nError: RetriableError: closed") == "Error: RetriableError: closed")
        #expect(CursorEventMapper.errorReport(in: "\n\nError: Error: boom") == "Error: Error: boom")
        #expect(
            CursorEventMapper.errorReport(in: "\n\nError: [unauthenticated] Backend rejected authentication. Verify it.")
                == "Error: [unauthenticated] Backend rejected authentication. Verify it.")
        #expect(CursorEventMapper.errorReport(in: "\n\nAdd a payment method to continue") == "Add a payment method to continue")
        // Prose about errors is not a report.
        #expect(CursorEventMapper.errorReport(in: "\n\nError: the build failed because of a typo") == nil)
        #expect(CursorEventMapper.errorReport(in: "Error: ConnectError: [unavailable] closed") == nil)
        #expect(CursorEventMapper.errorReport(in: "\n\nThe error was Error: ConnectError: [unavailable]") == nil)
    }

    @Test func longOutputsAreClipped() {
        var mapper = mapper()
        let log = (1...30_000).map { "line \($0)" }.joined(separator: "\n")
        let file = String(repeating: "x", count: CursorEventMapper.maxTextLength + 500)
        let events = [
            #"{"sessionUpdate":"tool_call","toolCallId":"s","title":"`make`","kind":"execute","status":"pending","rawInput":{"command":"make"}}"#,
            #"{"sessionUpdate":"tool_call","toolCallId":"r","title":"Read big.txt","kind":"read","status":"pending","rawInput":{"path":"/Users/dev/notes/big.txt"}}"#,
        ].flatMap { mapper.handle(update: CursorFixtures.json($0)) }
        #expect(events.count == 2)
        let shell = mapper.handle(
            update: ["sessionUpdate": "tool_call_update", "toolCallId": "s", "status": "completed",
                     "rawOutput": ["exitCode": 0, "stdout": .string(log), "stderr": ""]])
        let read = mapper.handle(
            update: ["sessionUpdate": "tool_call_update", "toolCallId": "r", "status": "completed",
                     "rawOutput": ["content": .string(file)]])
        guard case .toolCompleted(_, .completed, let shellOutput?) = shell.last,
            case .toolCompleted(_, .completed, let readOutput?) = read.last
        else {
            Issue.record("Expected completed tools, got \(shell) \(read)")
            return
        }
        // A log keeps its end, a file its start.
        #expect(shellOutput.hasSuffix("line 30000"))
        #expect(shellOutput.hasPrefix("…"))
        #expect(shellOutput.count < CursorEventMapper.maxTextLength + 100)
        #expect(readOutput.hasPrefix("xxxx"))
        #expect(readOutput.hasSuffix("500 more characters not shown"))
        #expect(CursorEventMapper.clipped("short") == "short")
    }

    @Test func aCommandCursorDidNotRunFails() {
        var mapper = mapper()
        let events = [
            #"{"sessionUpdate":"tool_call","toolCallId":"s","title":"`rm -rf build`","kind":"execute","status":"pending","rawInput":{"command":"rm -rf build"}}"#,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"s","status":"completed"}"#,
            #"{"sessionUpdate":"tool_call","toolCallId":"in","title":"Write to stdin (shell 3)","kind":"execute","status":"pending","rawInput":{"shellId":3,"chars":"y\n"}}"#,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"in","status":"completed","rawOutput":{"success":true}}"#,
        ].flatMap { mapper.handle(update: CursorFixtures.json($0)) }
        #expect(events.contains(.toolCompleted(id: "s", status: .failed, output: nil)))
        #expect(events.contains(.toolCompleted(id: "in", status: .completed, output: "")))
        #expect(events.contains(.toolStarted(ToolCallInfo(id: "in", category: .command, title: "Write to stdin (shell 3)", detail: "{\n  \"chars\" : \"y\\n\",\n  \"shellId\" : 3\n}"))))
    }

    @Test func generatedImagesReportTheirFile() {
        var mapper = mapper()
        _ = mapper.handle(
            update: CursorFixtures.json(
                #"{"sessionUpdate":"tool_call","toolCallId":"img","title":"Generate Image: a cat...","kind":"other","status":"pending","rawInput":{"_toolName":"generateImage","description":"a cat"}}"#
            ))
        let events = mapper.handleGeneratedImage(
            ["toolCallId": "img", "description": "a cat", "filePath": "/Users/dev/notes/assets/cat.png"])
        #expect(events == [.toolCompleted(id: "img", status: .completed, output: "assets/cat.png")])
        #expect(mapper.handleGeneratedImage(["toolCallId": "unknown", "filePath": "/tmp/x.png"]).isEmpty)
    }

    @Test func permissionsForCallsWithoutAToolReadWell() {
        var mapper = mapper()
        func title(_ toolCall: JSONValue) -> String {
            mapper.approval(id: "1:9", params: ["toolCall": toolCall, "options": []]).request.title
        }
        #expect(title(["toolCallId": "a", "title": "Edit `/Users/dev/notes/My Notes/a.txt`", "kind": "edit"]) == "Edit My Notes/a.txt")
        #expect(title(["toolCallId": "b", "title": "Write /Users/dev/notes/new.txt", "kind": "edit"]) == "Create new.txt")
        #expect(title(["toolCallId": "c", "title": "Delete `/Users/dev/notes/old.txt`", "kind": "edit"]) == "Delete old.txt")
        #expect(title(["toolCallId": "d", "title": "`ls -la`", "kind": "execute"]) == "Run `ls -la`")
        #expect(title(["toolCallId": "e", "title": "Web search: swift", "kind": "search"]) == "Web search: swift")
        #expect(title(["toolCallId": "f", "kind": "other"]) == "Permission request")
    }
}

extension CursorEventMapper {
    /// Parses the `questions` of an `ask_question` request.
    init() {
        self.init(workingDirectory: URL(fileURLWithPath: CursorFixtures.projectPath))
    }

    func questionsOf(_ params: JSONValue) -> [Question] {
        let title = params["title"]?.string ?? ""
        return (params["questions"]?.array ?? []).compactMap { Self.question($0, title: title) }
    }
}

extension CursorFixtures {
    /// `cursor/ask_question` as Cursor 2026.10.22's ACP server sends it.
    static let askQuestionParams = json(
        #"{"toolCallId":"ask-1","title":"Setup","questions":[{"id":"db","prompt":"Which database should the app use?","options":[{"id":"pg","label":"Postgres"},{"id":"sqlite","label":"SQLite"},{"id":"sqlite-wal","label":"SQLite"}],"allowMultiple":false},{"id":"extras","prompt":"Which extras?","options":[{"id":"auth","label":"Auth"},{"id":"billing","label":"Billing"}],"allowMultiple":true},{"id":"name","prompt":"","options":[],"allowMultiple":false}]}"#
    )
}

// MARK: - Model settings

@MainActor
struct CursorModelSettingsTests {
    /// A Cursor settings file in a fresh folder.
    private final class ConfigFolder {
        let directory: URL
        var file: URL { directory.appendingPathComponent("cli-config.json") }

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("coincide-cursor-settings-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        var object: [String: Any] {
            get {
                guard let data = try? Data(contentsOf: file) else { return [:] }
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            set {
                let data = try? JSONSerialization.data(withJSONObject: newValue, options: [.prettyPrinted, .sortedKeys])
                try? data?.write(to: file)
            }
        }

        var model: String? { CursorModelSettings.modelID(in: object) }

        func select(_ model: String, history: [String]? = nil) {
            var config = object
            config["model"] = ["modelId": model, "displayName": model]
            config["selectedModel"] = ["modelId": model, "parameters": [["id": "effort", "value": "high"]]]
            config["modelSelectionHistory"] = history ?? [model]
            object = config
        }

        var leftovers: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0 != "cli-config.json" }
        }
    }

    private func userConfig(_ folder: ConfigFolder) {
        folder.object = [
            "version": 1, "approvalMode": "allowlist", "permissions": ["allow": ["Shell(ls)"], "deny": [String]()],
            "privacyCache": ["privacyMode": 2, "updatedAt": 1_793_082_283_651],
            "model": ["modelId": "grok-4.7", "displayName": "Grok 4.7"],
            "selectedModel": ["modelId": "grok-4.7", "parameters": [["id": "reasoning_effort", "value": "medium"]]],
            "modelParameters": ["grok-4.7": [["id": "reasoning_effort", "value": "medium"]]],
            "hasChangedDefaultModel": true, "maxMode": false, "modelSelectionHistory": ["grok-4.7", "composer-2.5"],
        ]
    }

    @Test func theUsersModelComesBackWhileOtherChangesStay() {
        let folder = ConfigFolder()
        userConfig(folder)
        let before = folder.object
        let settings = CursorModelSettings(fileURL: folder.file)
        settings.begin()
        // What `cursor-agent` writes when a session picks another model…
        var changed = folder.object
        changed["selectedModel"] = ["modelId": "composer-2.5", "parameters": [["id": "fast", "value": "false"]]]
        changed["model"] = ["modelId": "composer-2.5", "displayName": "Composer 2.5"]
        changed["modelParameters"] = [
            "grok-4.7": [["id": "reasoning_effort", "value": "medium"]], "composer-2.5": [["id": "fast", "value": "false"]],
        ]
        changed["modelSelectionHistory"] = ["composer-2.5", "grok-4.7"]
        changed["maxModeAutoEnabled"] = false
        // …while something else (an "Always allow") lands in the same file.
        changed["permissions"] = ["allow": ["Shell(ls)", "Shell(echo)"], "deny": [String]()]
        folder.object = changed
        settings.end(touching: ["composer-2.5"])

        let after = folder.object
        for key in CursorModelSettings.keys {
            #expect(NSDictionary(dictionary: [key: after[key] ?? NSNull()]) == NSDictionary(dictionary: [key: before[key] ?? NSNull()]))
        }
        #expect(after["maxModeAutoEnabled"] == nil)
        #expect((after["permissions"] as? [String: Any])?["allow"] as? [String] == ["Shell(ls)", "Shell(echo)"])
        #expect((after["privacyCache"] as? [String: Any])?["updatedAt"] as? Int == 1_793_082_283_651)
        #expect(folder.leftovers.isEmpty)
    }

    @Test func aModelTheUserPickedMeanwhileStays() {
        let folder = ConfigFolder()
        userConfig(folder)
        let settings = CursorModelSettings(fileURL: folder.file)
        settings.begin()
        folder.select("claude-opus-4-8")
        settings.end(touching: ["composer-2.5"])
        #expect(folder.model == "claude-opus-4-8")
    }

    @Test func overlappingOperationsRestoreOnceAtTheEnd() {
        let folder = ConfigFolder()
        userConfig(folder)
        let settings = CursorModelSettings(fileURL: folder.file)
        settings.begin()
        settings.begin()
        folder.select("composer-2.5")
        #expect(settings.userModelID() == "grok-4.7")
        settings.end(touching: ["composer-2.5"])
        #expect(folder.model == "composer-2.5")
        folder.select("grok-4.6")
        settings.end(touching: ["grok-4.6"])
        #expect(folder.model == "grok-4.7")
        #expect(folder.object["modelSelectionHistory"] as? [String] == ["grok-4.7", "composer-2.5"])
        #expect(settings.userModelID() == "grok-4.7")
    }

    @Test func anUntouchedFileIsNotRewritten() throws {
        let folder = ConfigFolder()
        userConfig(folder)
        let before = try Data(contentsOf: folder.file)
        let settings = CursorModelSettings(fileURL: folder.file)
        settings.begin()
        var object = folder.object
        object["privacyCache"] = ["privacyMode": 2, "updatedAt": 1_793_082_299_999]
        folder.object = object
        let touched = try Data(contentsOf: folder.file)
        settings.end(touching: ["grok-4.7"])
        #expect(try Data(contentsOf: folder.file) == touched)
        #expect(touched != before)
    }

    @Test func aFileCursorCreatedLosesOnlyTheModelKeys() {
        let folder = ConfigFolder()
        let settings = CursorModelSettings(fileURL: folder.file)
        settings.begin()
        folder.object = ["version": 1, "approvalMode": "allowlist"]
        folder.select("composer-2.5")
        settings.end(touching: ["composer-2.5"])
        let after = folder.object
        #expect(after["version"] as? Int == 1)
        #expect(after["approvalMode"] as? String == "allowlist")
        #expect(CursorModelSettings.keys.allSatisfy { after[$0] == nil })
    }

    @Test func anUnreadableFileIsLeftAlone() throws {
        let folder = ConfigFolder()
        try Data("{ not json".utf8).write(to: folder.file)
        let settings = CursorModelSettings(fileURL: folder.file)
        settings.begin()
        settings.end(touching: ["composer-2.5"])
        #expect(try String(contentsOf: folder.file, encoding: .utf8) == "{ not json")
        #expect(settings.userModelID() == nil)
    }

    @Test func aSymlinkedFileKeepsItsLink() throws {
        let folder = ConfigFolder()
        let target = folder.directory.appendingPathComponent("dotfiles-cli-config.json")
        userConfig(folder)
        try FileManager.default.moveItem(at: folder.file, to: target)
        try FileManager.default.createSymbolicLink(at: folder.file, withDestinationURL: target)
        let settings = CursorModelSettings(fileURL: folder.file)
        settings.begin()
        folder.select("composer-2.5")
        settings.end(touching: ["composer-2.5"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder.file.path) == target.path)
        #expect(folder.model == "grok-4.7")
    }

    @Test func theFileIsWhereCursorKeepsIt() {
        #expect(
            CursorModelSettings.configFileURL(environment: ["CURSOR_CONFIG_DIR": "/opt/cursor", "HOME": "/Users/dev"]).path
                == "/opt/cursor/cli-config.json")
        #expect(
            CursorModelSettings.configFileURL(environment: ["XDG_CONFIG_HOME": "/Users/dev/.config", "HOME": "/Users/dev"]).path
                == "/Users/dev/.config/cursor/cli-config.json")
        #expect(
            CursorModelSettings.configFileURL(environment: ["CURSOR_CONFIG_DIR": " ", "HOME": "/Users/dev"]).path
                == "/Users/dev/.cursor/cli-config.json")
    }
}

// MARK: - Session: models, questions and failures

@MainActor
struct CursorSessionModelAndQuestionTests {
    @Test func pickingAModelLeavesTheUsersCursorDefaultAlone() async throws {
        let harness = CursorSessionHarness()
        harness.writeConfig(model: "grok-4.7")
        harness.beforeReply = { [unowned harness] method, params in
            if method == "session/set_config_option", params["configId"] == "model", let model = params["value"]?.string {
                harness.saveModelLikeCursor(model)
            }
        }
        try await harness.session.start()
        try await harness.session.send(harness.input(modelID: "composer-2.5"))
        #expect(harness.transport.messages("session/set_config_option").first?["params"]?["value"] == "composer-2.5")
        #expect(harness.events.contains(.modelResolved("composer-2.5")))
        #expect(harness.configModel == "grok-4.7")
        #expect(harness.config["modelSelectionHistory"] as? [String] == ["grok-4.7"])
    }

    @Test func aLaunchFlagModelIsNotKeptAsTheDefaultEither() async throws {
        let harness = CursorSessionHarness()
        harness.writeConfig(model: "grok-4.7")
        harness.beforeReply = { [unowned harness] method, _ in
            // `--model` takes effect when Cursor opens the chat.
            if method == "session/new", harness.transport.arguments.contains("--model") {
                harness.saveModelLikeCursor("grok-4.7-high")
            }
        }
        try await harness.session.start()
        try await harness.session.send(harness.input(modelID: "grok-4.7-high"))
        #expect(harness.transport.arguments.contains("grok-4.7-high"))
        #expect(harness.configModel == "grok-4.7")
    }

    @Test func defaultFollowsTheUsersModelInAReopenedChat() async throws {
        let harness = CursorSessionHarness(resume: CursorFixtures.sessionID)
        harness.writeConfig(model: "grok-4.7")
        // Reopening a chat switches Cursor to the chat's last model and saves it.
        harness.loadReply = { [unowned harness] id in
            harness.saveModelLikeCursor("composer-2.5")
            guard case .object(var result) = CursorFixtures.loadResult else { return [] }
            result["models"] = [
                "currentModelId": "composer-2.5",
                "availableModels": [["modelId": "grok-4.7", "name": "Grok 4.7"], ["modelId": "composer-2.5", "name": "Composer 2.5"]],
            ]
            result["configOptions"] = CursorFixtures.configOptions(model: "composer-2.5")
            return [CursorRPCMessage.resultLine(id: id, .object(result))]
        }
        harness.beforeReply = { [unowned harness] method, params in
            if method == "session/set_config_option", let model = params["value"]?.string { harness.saveModelLikeCursor(model) }
        }
        try await harness.session.start()
        #expect(harness.configModel == "grok-4.7")
        try await harness.session.send(harness.input())
        #expect(harness.transport.messages("session/set_config_option").first?["params"]?["value"] == "grok-4.7")
        #expect(harness.configModel == "grok-4.7")
    }

    @Test func defaultKeepsTheModelWhenItAlreadyMatches() async throws {
        let harness = CursorSessionHarness()
        harness.writeConfig(model: "grok-4.7")
        try await harness.session.start()
        try await harness.session.send(harness.input())
        #expect(harness.transport.messages("session/set_config_option").isEmpty)
    }

    @Test func aChatWithoutPromptsStartsOverInsteadOfReopening() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input(accessMode: .approval))
        #expect(harness.transports.count == 2)
        #expect(harness.transport.methods() == ["initialize", "session/new", "session/prompt"])
        #expect(!harness.events.contains { if case .notice = $0 { true } else { false } })
    }

    @Test func questionsRoundTrip() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input("Set up the app", mode: .plan))
        harness.transport.deliver([
            CursorRPCMessage.requestLine(id: 7, method: "cursor/ask_question", params: CursorFixtures.askQuestionParams)
        ])
        let request = try #require(harness.lastQuestion)
        #expect(request.questions.count == 3)
        #expect(harness.replies.isEmpty)

        harness.session.answer(userInput: request.id, answers: ["db": ["Postgres"], "extras": ["Billing"]])
        #expect(harness.replies.count == 1)
        #expect(harness.replies.first?["id"] == .number(7))
        #expect(
            harness.replies.first?["result"]?["outcome"]
                == [
                    "outcome": "answered",
                    "answers": [
                        ["questionId": "db", "selectedOptionIds": ["pg"]],
                        ["questionId": "extras", "selectedOptionIds": ["billing"]],
                    ],
                ])
        // Answering twice does nothing.
        harness.session.answer(userInput: request.id, answers: [:])
        #expect(harness.replies.count == 1)

        harness.transport.answer("session/prompt", with: ["stopReason": "end_turn"])
        #expect(harness.completions == [.completed])
    }

    @Test func dismissedQuestionsAreSkipped() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input())
        harness.transport.deliver([
            CursorRPCMessage.requestLine(id: 3, method: "cursor/ask_question", params: CursorFixtures.askQuestionParams)
        ])
        let request = try #require(harness.lastQuestion)
        harness.session.answer(userInput: request.id, answers: [:])
        #expect(harness.replies.last?["result"] == ["outcome": ["outcome": "skipped"]])
    }

    @Test func interruptingCancelsWaitingQuestionsAndLateRequests() async throws {
        let harness = CursorSessionHarness(accessMode: .approval)
        try await harness.session.start()
        try await harness.session.send(harness.input(accessMode: .approval))
        harness.transport.deliver([
            CursorRPCMessage.requestLine(id: 3, method: "cursor/ask_question", params: CursorFixtures.askQuestionParams)
        ])
        harness.session.interrupt()
        #expect(harness.replies.last?["id"] == .number(3))
        #expect(harness.replies.last?["result"] == ["outcome": ["outcome": "cancelled"]])

        // A permission request racing the interrupt is cancelled without asking the user.
        let before = harness.events.count
        harness.transport.deliver(CursorFixtures.shellUntilPermission + [CursorFixtures.shellPermissionRequest])
        #expect(!harness.events[before...].contains { if case .approvalRequested = $0 { true } else { false } })
        #expect(harness.replies.last?["id"] == .number(0))
        #expect(harness.replies.last?["result"] == ["outcome": ["outcome": "cancelled"]])

        harness.transport.answer("session/prompt", with: ["stopReason": "cancelled"])
        #expect(harness.completions == [.interrupted])
    }

    @Test func withdrawnRequestsAreResolved() async throws {
        let harness = CursorSessionHarness(accessMode: .approval)
        try await harness.session.start()
        try await harness.session.send(harness.input(accessMode: .approval))
        harness.transport.deliver([
            CursorRPCMessage.requestLine(id: 3, method: "cursor/ask_question", params: CursorFixtures.askQuestionParams)
        ])
        let request = try #require(harness.lastQuestion)
        harness.transport.deliver([CursorRPCMessage.notificationLine(method: "$/cancel_request", params: ["requestId": 3])])
        #expect(harness.events.last == .userInputResolved(id: request.id))
        #expect(harness.replies.last?["error"]?["code"]?.int == CursorRPCError.requestCancelled)
    }

    @Test func approvalsLeftAtTheEndOfATurnAreCancelled() async throws {
        let harness = CursorSessionHarness(accessMode: .approval)
        try await harness.session.start()
        try await harness.session.send(harness.input(accessMode: .approval))
        harness.transport.deliver(CursorFixtures.shellUntilPermission + [CursorFixtures.shellPermissionRequest])
        harness.transport.answer("session/prompt", with: ["stopReason": "end_turn"])
        #expect(harness.replies.last?["result"] == ["outcome": ["outcome": "cancelled"]])
        // Coincide marks the waiting approval declined itself when the turn ends.
        #expect(!harness.events.contains { if case .approvalResolved = $0 { true } else { false } })
        #expect(harness.completions == [.completed])
    }

    @Test func cursorsErrorReportFailsTheTurnWithoutBecomingTheReply() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input())
        harness.transport.deliver([
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Checking."}}}}"#,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\n\nError: ConnectError: [resource_exhausted] Usage limit reached"}}}}"#,
        ])
        harness.transport.answer("session/prompt", with: ["stopReason": "end_turn"])
        #expect(harness.completions == [.failed("Error: ConnectError: [resource_exhausted] Usage limit reached")])
        #expect(harness.events.contains(.assistantText(itemID: "cursor-1-1", text: "Checking.")))
        #expect(!harness.events.contains { event in
            if case .assistantTextDelta(_, let delta) = event { return delta.contains("Usage limit") }
            return false
        })
    }

    @Test func aFailedRestartLeavesNoHalfOpenProcess() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input())
        harness.transport.answer("session/prompt", with: ["stopReason": "end_turn"])

        // The next process cannot open any chat.
        let load = harness.loadReply
        harness.loadReply = { id in [CursorRPCMessage.errorLine(id: id, code: -32603, message: "Failed to load")] }
        harness.newSessionReply = { id in
            [CursorRPCMessage.errorLine(id: id, code: -32603, message: "Failed to initialize session services")]
        }
        await #expect(throws: AgentError.self) { try await harness.session.send(harness.input(accessMode: .approval)) }
        #expect(harness.transports.count == 2)
        #expect(harness.transport.isTerminated)

        // The turn after that starts over with a new process and reopens the chat.
        harness.loadReply = load
        harness.newSessionReply = nil
        try await harness.session.send(harness.input(accessMode: .approval))
        #expect(harness.transports.count == 3)
        #expect(harness.transport.methods() == ["initialize", "session/load", "session/prompt"])
    }

    @Test func aMissingImageFailsBeforeAnyProcessWork() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        await #expect(throws: AgentError.self) {
            try await harness.session.send(harness.input("Look", accessMode: .approval, images: ["/nonexistent/shot.png"]))
        }
        #expect(harness.transports.count == 1)
        #expect(harness.transport.messages("session/prompt").isEmpty)
    }

    @Test func generatedImagesAreReported() async throws {
        let harness = CursorSessionHarness()
        try await harness.session.start()
        try await harness.session.send(harness.input("Draw a cat"))
        harness.transport.deliver([
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"68a6eb78-54c6-4227-9151-708908518b4f","update":{"sessionUpdate":"tool_call","toolCallId":"img","title":"Generate Image: a cat...","kind":"other","status":"pending","rawInput":{"_toolName":"generateImage","description":"a cat"}}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"cursor/generate_image","params":{"toolCallId":"img","description":"a cat","filePath":"/Users/dev/notes/cat.png"}}"#,
        ])
        #expect(harness.events.contains(.toolCompleted(id: "img", status: .completed, output: "cat.png")))
        #expect(harness.replies.last?["result"] == [:])
    }
}
