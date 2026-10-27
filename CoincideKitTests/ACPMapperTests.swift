import Foundation
import Testing

@testable import CoincideKit

/// Fixtures follow the shapes Grok 1.0.x and Antigravity's ACP server send, as captured in
/// T3 Code's tests and Grok's session logs.
@MainActor
struct ACPMapperTests {
    private let cwd = URL(fileURLWithPath: "/Users/me/proj")

    private func update(_ json: String) -> ACPSessionUpdate {
        ACPSessionUpdate(json: JSONValue.parse(json) ?? .null)
    }

    private func map(_ mapper: inout ACPEventMapper, _ json: String, flavor: ACPAgentFlavor = GrokFlavor()) -> [AgentEvent] {
        mapper.map(update(json), flavor: flavor, terminals: nil)
    }

    private func startedCategory(_ events: [AgentEvent]) -> ToolCategory? {
        guard case .toolStarted(let info) = events.first else { return nil }
        return info.category
    }

    // MARK: Schema

    @Test func parsesAntigravityInitializeWithV1Shape() throws {
        let json = try #require(
            JSONValue.parse(
                """
                {"protocolVersion":2,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true,"audio":true,"embeddedContext":true},
                "mcpCapabilities":{"http":true,"sse":true},"sessionCapabilities":{"list":{},"resume":{}},"auth":{"logout":{}}},
                "authMethods":[{"id":"oauth-personal","name":"Log in with Google","description":"Log in with your Google account"},
                {"id":"gemini-api-key","name":"Gemini API key"}],
                "agentInfo":{"name":"antigravity-acp","title":"Google Antigravity","version":"agy_acp_server_1.1.1"}}
                """))
        let result = ACPInitializeResult(json: json)
        // Version 2 with the v1 shape is still v1 on the wire.
        #expect(result.generation == 1)
        #expect(result.protocolVersion == 2)
        #expect(result.loadSession && result.resumeSession && result.promptImage)
        #expect(!result.closeSession)
        #expect(result.canLogout)
        #expect(result.authMethods.map(\.id) == ["oauth-personal", "gemini-api-key"])
        #expect(result.agentInfo?.version == "agy_acp_server_1.1.1")
        #expect(result.authMethod(preferring: "oauth-personal")?.id == "oauth-personal")
        #expect(result.authMethod(preferring: "oauth-business") == nil)
        #expect(result.authMethod(preferring: nil)?.id == "oauth-personal")
    }

    /// Grok 1.0.44's answer, as T3 Code recorded it.
    @Test func parsesRecordedGrokInitialize() throws {
        let json = try #require(
            JSONValue.parse(
                #"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":true},"mcpCapabilities":{"http":true,"sse":true},"sessionCapabilities":{"list":{},"resume":{},"close":{}},"auth":{}},"authMethods":[{"id":"cached_token","name":"cached_token","description":"Cached token from ~/.grok/auth.json"},{"id":"grok.com","name":"Grok","description":"Sign in with Grok"}],"_meta":{"defaultAuthMethodId":"cached_token"}}"#
            ))
        let result = ACPInitializeResult(json: json)
        #expect(result.generation == 1)
        #expect(result.loadSession && result.resumeSession && result.closeSession && !result.promptImage)
        #expect(!result.canLogout)
        #expect(result.authMethod(preferring: "cached_token")?.id == "cached_token")
    }

    @Test func parsesV2InitializeShape() throws {
        let json = try #require(
            JSONValue.parse(
                #"{"protocolVersion":2,"info":{"name":"agent","version":"2.0"},"capabilities":{"session":{"prompt":{"image":{}}}},"authMethods":[{"type":"agent","methodId":"login","name":"Login"}]}"#
            ))
        let result = ACPInitializeResult(json: json)
        #expect(result.generation == 2)
        #expect(result.loadSession && result.promptImage && !result.promptAudio)
        #expect(result.authMethods.first?.id == "login")
        #expect(result.agentInfo?.name == "agent")
    }

    @Test func parsesGrokModelStateFromInitializeMeta() throws {
        let json = try #require(JSONValue.parse(Self.grokInitialize))
        let state = try #require(ACPInitializeResult(json: json).modelState)
        #expect(state.currentModelID == "grok-4.7")
        #expect(state.availableModels.map(\.modelID) == ["grok-4.7", "grok-4.6"])
    }

    @Test func parsesConfigOptionsIncludingGroups() throws {
        let json = try #require(
            JSONValue.parse(
                """
                {"sessionId":"s","configOptions":[
                {"id":"model","name":"Model","category":"model","type":"select","currentValue":"b",
                 "options":[{"group":"fast","name":"Fast","options":[{"value":"a","name":"A"}]},{"value":"b","name":"B","description":"Bee"}]},
                {"id":"reasoning_effort","name":"Effort","category":"thought_level","type":"select","currentValue":"high","options":[{"value":"low","name":"Low"},{"value":"high","name":"High"}]},
                {"id":"thinking","name":"Thinking","type":"boolean","currentValue":true}]}
                """))
        let setup = ACPSessionSetup(json: json)
        #expect(setup.sessionID == "s")
        #expect(setup.modelOption?.choices.map(\.value) == ["a", "b"])
        #expect(setup.currentModelID == "b")
        #expect(setup.reasoningOption?.id == "reasoning_effort")
        #expect(setup.configOptions.last?.value == .boolean(true))
        #expect(setup.effectiveModes == nil)
    }

    @Test func modesComeFromModeConfigOption() throws {
        let json = try #require(
            JSONValue.parse(
                #"{"sessionId":"s","configOptions":[{"configId":"mode","name":"Mode","category":"mode","type":"select","currentValue":"default","options":[{"value":"default","name":"Default"},{"value":"yolo","name":"YOLO"}]}]}"#
            ))
        let modes = try #require(ACPSessionSetup(json: json).effectiveModes)
        #expect(modes.currentModeID == "default")
        #expect(modes.availableModes.map(\.id) == ["default", "yolo"])
    }

    @Test func parsesPermissionRequestsFromBothVersions() throws {
        let v1 = try #require(
            JSONValue.parse(
                """
                {"sessionId":"s","toolCall":{"toolCallId":"call-9","title":"rm -rf build","kind":"execute","rawInput":{"command":"rm -rf build"}},
                "options":[{"optionId":"allow-once","name":"Allow","kind":"allow_once"},{"optionId":"allow-always","name":"Always","kind":"allow_always"},
                {"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}
                """))
        let request = try #require(ACPPermissionRequest(params: v1, requestID: "1"))
        #expect(request.toolCall.id == "call-9")
        #expect(request.option(.allowOnce)?.id == "allow-once")
        #expect(request.option(.rejectAlways) == nil)

        let v2 = try #require(
            JSONValue.parse(
                #"{"sessionId":"s","title":"Run ls?","subject":{"type":"command","command":"ls"},"options":[{"optionId":"y","name":"Yes","kind":"allow_once"}]}"#
            ))
        let subject = try #require(ACPPermissionRequest(params: v2, requestID: "42"))
        #expect(subject.toolCall.id == "42")
        #expect(subject.toolCall.kind == "execute")
        #expect(subject.title == "Run ls?")
    }

    // MARK: Text

    @Test func messagesAndThoughtsBecomeSegmentsAroundTools() {
        var mapper = ACPEventMapper(workingDirectory: cwd)
        mapper.beginTurn()
        var events = map(&mapper, #"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Looking at the code"}}"#)
        events += map(&mapper, #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Let me "}}"#)
        events += map(&mapper, #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"check."}}"#)
        events += map(&mapper, #"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read file","kind":"read","rawInput":{"path":"/Users/me/proj/README.md"}}"#)
        events += map(&mapper, #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."}}"#)
        events += mapper.closeSegments()

        let readInfo = ToolCallInfo(id: "t1", category: .read, title: "Read README.md", detail: "/Users/me/proj/README.md")
        #expect(
            events == [
                .reasoningDelta(itemID: "reasoning-1-1", delta: "Looking at the code"),
                .reasoningText(itemID: "reasoning-1-1", text: "Looking at the code"),
                .assistantTextDelta(itemID: "assistant-1-2", delta: "Let me "),
                .assistantTextDelta(itemID: "assistant-1-2", delta: "check."),
                .assistantText(itemID: "assistant-1-2", text: "Let me check."),
                .toolStarted(readInfo),
                .assistantTextDelta(itemID: "assistant-1-3", delta: "Done."),
                .assistantText(itemID: "assistant-1-3", text: "Done."),
            ])
    }

    @Test func leadingWhitespaceChunksDoNotOpenSegments() {
        var mapper = ACPEventMapper(workingDirectory: cwd)
        mapper.beginTurn()
        #expect(map(&mapper, #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\n\n"}}"#).isEmpty)
        #expect(map(&mapper, #"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"hi"}}"#).isEmpty)
        #expect(mapper.closeSegments().isEmpty)
    }

    @Test func newMessageIDsStartNewSegments() {
        var mapper = ACPEventMapper(workingDirectory: cwd)
        mapper.beginTurn()
        _ = map(&mapper, #"{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"One"}}"#)
        let events = map(&mapper, #"{"sessionUpdate":"agent_message_chunk","messageId":"m2","content":{"type":"text","text":"Two"}}"#)
        #expect(
            events == [
                .assistantText(itemID: "assistant-1-1", text: "One"), .assistantTextDelta(itemID: "assistant-1-2", delta: "Two"),
            ])
    }

    // MARK: Tools

    @Test func grokSearchToolLifecycle() {
        var mapper = ACPEventMapper(workingDirectory: cwd)
        mapper.beginTurn()
        let started = map(
            &mapper,
            #"{"sessionUpdate":"tool_call","toolCallId":"call-1","title":"grep","rawInput":{"pattern":"TODO","path":"/Users/me/proj/Sources","glob":"*.swift"},"_meta":{"x.ai/tool":{"version":1,"name":"grep","kind":"search","namespace":"grok_build","label":"Grep","read_only":true}}}"#
        )
        guard case .toolStarted(let info) = started.first else {
            Issue.record("Expected a started tool, got \(started)")
            return
        }
        #expect(info.category == .search)
        #expect(info.title == "Search “TODO” in Sources")
        #expect(info.detail?.contains("\"glob\" : \"*.swift\"") == true)

        let refined = map(
            &mapper,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"call-1","kind":"search","title":"grep","locations":[{"path":"/Users/me/proj/Sources"}],"rawInput":{"pattern":"TODO","path":"/Users/me/proj/Sources","glob":"*.swift","-i":false,"variant":"Grep"},"_meta":{"x.ai/tool":{"name":"grep","kind":"search"}}}"#
        )
        guard case .toolUpdated(let updated) = refined.first else {
            Issue.record("Expected an update, got \(refined)")
            return
        }
        #expect(updated.detail?.contains("\"variant\" : \"Grep\"") == true)

        // Grok sends stdout as UTF-8 bytes and a short summary as content.
        let bytes = Array("Sources/A.swift:3:// TODO\n".utf8).map { String($0) }.joined(separator: ",")
        let done = map(
            &mapper,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed","rawOutput":{"type":"GrepSearch","stdout":["#
                + bytes
                + #"],"stderr":[],"exit_code":0,"match_count":1},"content":[{"type":"content","content":{"type":"text","text":"Found 1 match"}}]}"#
        )
        #expect(done == [.toolCompleted(id: "call-1", status: .completed, output: "Found 1 match")])
    }

    @Test func rawOutputBytesAndWrappersBecomeText() {
        let bytes = JSONValue.array(Array("hello\n".utf8).map { .number(Double($0)) })
        #expect(ACPToolCallState.rawOutputText(["stdout": bytes, "stderr": []]) == "hello\n")
        #expect(ACPToolCallState.rawOutputText(["type": "ReadFile", "FileContent": ["content": "line 1", "total_lines": 1]]) == "line 1")
        #expect(ACPToolCallState.rawOutputText(["type": "ListDir", "Content": ["content": "a/\nb/"]]) == "a/\nb/")
        #expect(ACPToolCallState.rawOutputText("plain") == "plain")
        #expect(ACPToolCallState.rawOutputText(["exit_code": 0]) == nil)
    }

    @Test func commandOutputStreamsThenCompletesWithExitCode() {
        var mapper = ACPEventMapper(workingDirectory: cwd)
        mapper.beginTurn()
        let flavor = ACPPlainFlavor()
        let started = map(
            &mapper,
            #"{"sessionUpdate":"tool_call","toolCallId":"run-1","title":"`swift test`","kind":"execute","status":"in_progress","rawInput":{"command":["swift","test"]}}"#,
            flavor: flavor)
        #expect(started == [.toolStarted(ToolCallInfo(id: "run-1", category: .command, title: "Run `swift test`", detail: "swift test"))])
        let first = map(
            &mapper,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"run-1","content":[{"type":"content","content":{"type":"text","text":"Building\n"}}]}"#,
            flavor: flavor)
        let second = map(
            &mapper,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"run-1","content":[{"type":"content","content":{"type":"text","text":"Building\nTesting\n"}}]}"#,
            flavor: flavor)
        #expect(first == [.toolOutput(id: "run-1", delta: "Building\n")])
        #expect(second == [.toolOutput(id: "run-1", delta: "Testing\n")])
        let done = map(
            &mapper,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"run-1","status":"failed","rawOutput":{"exit_code":1},"content":[{"type":"content","content":{"type":"text","text":"Building\nTesting\nFailed\n"}}]}"#,
            flavor: flavor)
        #expect(done == [.toolCompleted(id: "run-1", status: .failed, output: "Building\nTesting\nFailed\n\nExit code 1")])
    }

    @Test func fileEditsCarryAUnifiedDiff() {
        var mapper = ACPEventMapper(workingDirectory: cwd)
        mapper.beginTurn()
        let events = map(
            &mapper,
            #"{"sessionUpdate":"tool_call","toolCallId":"edit-1","title":"Edit App.swift","kind":"edit","status":"pending","locations":[{"path":"/Users/me/proj/App.swift"}],"content":[{"type":"diff","path":"/Users/me/proj/App.swift","oldText":"let a = 1\nlet b = 2\n","newText":"let a = 1\nlet b = 3\n"}]}"#,
            flavor: ACPPlainFlavor())
        let diff = "--- a/App.swift\n+++ b/App.swift\n@@ -1,2 +1,2 @@\n let a = 1\n-let b = 2\n+let b = 3"
        #expect(events == [.toolStarted(ToolCallInfo(id: "edit-1", category: .fileChange, title: "Edit App.swift", detail: diff))])

        let created = map(
            &mapper,
            #"{"sessionUpdate":"tool_call","toolCallId":"edit-2","title":"Write","kind":"edit","content":[{"type":"diff","path":"/Users/me/proj/New.swift","oldText":null,"newText":"print(1)\n"}]}"#,
            flavor: ACPPlainFlavor())
        let newFile = "--- /dev/null\n+++ b/New.swift\n@@ -0,0 +1,1 @@\n+print(1)"
        #expect(created == [.toolStarted(ToolCallInfo(id: "edit-2", category: .fileChange, title: "Create New.swift", detail: newFile))])
    }

    @Test func v2ContentChunksPatchesAndPlansAreMapped() {
        var mapper = ACPEventMapper(workingDirectory: cwd)
        mapper.beginTurn()
        let flavor = ACPPlainFlavor()
        let started = map(
            &mapper,
            #"{"sessionUpdate":"tool_call","toolCallId":"p1","title":"Apply patch","kind":"edit","content":[{"type":"diff","changes":[{"operation":"add","path":"/Users/me/proj/New.swift"}],"patch":{"format":"git_patch","text":"diff --git a/New.swift b/New.swift"}}]}"#,
            flavor: flavor)
        #expect(
            started == [
                .toolStarted(ToolCallInfo(id: "p1", category: .fileChange, title: "Create New.swift", detail: "diff --git a/New.swift b/New.swift"))
            ])

        _ = map(&mapper, #"{"sessionUpdate":"tool_call","toolCallId":"r1","title":"Run","kind":"execute","rawInput":{"command":"make"}}"#, flavor: flavor)
        let chunk = map(
            &mapper, #"{"sessionUpdate":"tool_call_content_chunk","toolCallId":"r1","content":{"type":"content","content":{"type":"text","text":"built\n"}}}"#,
            flavor: flavor)
        #expect(chunk == [.toolOutput(id: "r1", delta: "built\n")])

        let markdown = map(
            &mapper, ##"{"sessionUpdate":"plan_update","plan":{"planId":"p","type":"markdown","content":"# Steps\n1. Build"}}"##, flavor: flavor)
        #expect(markdown == [.plan(text: "# Steps\n1. Build")])
        // The same plan is not reported twice.
        #expect(map(&mapper, ##"{"sessionUpdate":"plan_update","plan":{"planId":"p","type":"markdown","content":"# Steps\n1. Build"}}"##, flavor: flavor).isEmpty)
    }

    @Test func elicitationRequestsParseBothScopes() throws {
        let session = ACPElicitationRequest(
            params: ["sessionId": "s", "toolCallId": "t", "mode": "form", "message": "Pick", "requestedSchema": ["type": "object"]])
        #expect(session.sessionID == "s" && session.toolCallID == "t" && session.mode == "form")
        let scoped = ACPElicitationRequest(params: ["requestId": 3, "mode": "url", "message": "Sign in", "elicitationId": "e1", "url": "https://x"])
        #expect(scoped.sessionID == nil && scoped.elicitationID == "e1" && scoped.url == "https://x")
    }

    @Test func antigravityCommandFieldsAndSubagents() {
        var mapper = ACPEventMapper(workingDirectory: cwd)
        mapper.beginTurn()
        let flavor = AntigravityFlavor()
        let started = map(
            &mapper,
            #"{"sessionUpdate":"tool_call","toolCallId":"ag-1","title":"Running run_command","status":"in_progress","rawInput":{"CommandLine":"npm test","Cwd":"/Users/me/proj"}}"#,
            flavor: flavor)
        #expect(started == [.toolStarted(ToolCallInfo(id: "ag-1", category: .command, title: "Run `npm test`", detail: "npm test"))])
        let done = map(
            &mapper,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"ag-1","status":"completed","rawOutput":{"combinedOutput":"ok\n","exitCode":0}}"#,
            flavor: flavor)
        #expect(done == [.toolCompleted(id: "ag-1", status: .completed, output: "ok\n")])

        let subagent = map(
            &mapper, #"{"sessionUpdate":"tool_call","toolCallId":"ag-2","title":"Running start_subagent","kind":"other"}"#, flavor: flavor)
        #expect(startedCategory(subagent) == .task)
        let mcp = map(
            &mapper,
            #"{"sessionUpdate":"tool_call","toolCallId":"ag-3","title":"Running start_subagent","_meta":{"is_mcp_tool_call":true}}"#,
            flavor: flavor)
        #expect(startedCategory(mcp) == .mcp)
    }

    @Test func mcpAndTodoToolsAreRecognized() {
        var mcp = ACPToolCallState(ACPToolCallUpdate(id: "m", title: "mcp__github__create_issue", rawInput: ["title": "Bug"]))
        GrokFlavor().normalize(&mcp)
        #expect(mcp.info(relativeTo: cwd).title == "github: create_issue")
        #expect(mcp.resolvedCategory == .mcp)

        var todo = ACPToolCallState(ACPToolCallUpdate(id: "t", title: "todo_write", meta: ["x.ai/tool": ["name": "todo_write"]]))
        GrokFlavor().normalize(&todo)
        #expect(todo.resolvedCategory == .todo)
    }

    @Test func grokGenericTitlesFallBackToTheInput() {
        var call = ACPToolCallState(ACPToolCallUpdate(id: "g", title: "tool", rawInput: ["description": "Run the linter"]))
        GrokFlavor().normalize(&call)
        #expect(call.title == "Run the linter")

        var bash = ACPToolCallState(
            ACPToolCallUpdate(id: "b", title: "run_terminal_command", kind: "execute", status: "completed", rawInput: ["command": "make"],
                rawOutput: ["type": "bash", "exit_code": 2, "stdout": "boom"]))
        GrokFlavor().normalize(&bash)
        #expect(bash.status == .failed)
    }

    @Test func toolIDsCanBeReusedInALaterTurn() {
        var mapper = ACPEventMapper(workingDirectory: cwd)
        mapper.beginTurn()
        let first = map(&mapper, #"{"sessionUpdate":"tool_call","toolCallId":"t","title":"ls","kind":"execute","rawInput":{"command":"ls"}}"#)
        mapper.beginTurn()
        let second = map(&mapper, #"{"sessionUpdate":"tool_call","toolCallId":"t","title":"ls","kind":"execute","rawInput":{"command":"ls"}}"#)
        #expect(startedCategory(first) == .command)
        #expect(startedCategory(second) == .command)
    }

    @Test func elicitationNumbersMustBeFinite() throws {
        let request = ACPElicitationRequest(
            params: ["sessionId": "s", "mode": "form", "message": "How many?", "requestedSchema": ["type": "object", "properties": ["count": ["type": "number"]]]])
        let questions = try #require(ACPElicitationForm.questionSet(request))
        #expect(questions.respond(["count": ["1e999"]]) == ["action": "accept", "content": [:]])
        #expect(questions.respond(["count": ["2,5"]]) == ["action": "accept", "content": ["count": 2.5]])
        #expect(questions.respond(nil) == ["action": "cancel"])
    }

    @Test func declinedToolsCompleteAsDeclined() {
        var mapper = ACPEventMapper(workingDirectory: cwd)
        mapper.beginTurn()
        _ = map(&mapper, #"{"sessionUpdate":"tool_call","toolCallId":"x","title":"rm","kind":"execute","rawInput":{"command":"rm -rf /"}}"#)
        #expect(mapper.markDeclined("x") == [.toolCompleted(id: "x", status: .declined, output: nil)])
        // The agent's own failure report does not overwrite the decline.
        #expect(map(&mapper, #"{"sessionUpdate":"tool_call_update","toolCallId":"x","status":"failed"}"#).isEmpty)
    }

    @Test func rawInputIsKeptWhenUpdatesResendAnEmptyObject() {
        var state = ACPToolCallState(ACPToolCallUpdate(id: "r", kind: "read", rawInput: ["path": "/a"]))
        state.merge(ACPToolCallUpdate(id: "r", status: "in_progress", rawInput: [:]))
        #expect(state.rawInput == ["path": "/a"])
        #expect(state.status == .inProgress)
    }

    // MARK: Plans and models

    @Test func plansBecomeChecklists() {
        var mapper = ACPEventMapper(workingDirectory: cwd)
        mapper.beginTurn()
        let events = map(
            &mapper,
            #"{"sessionUpdate":"plan","entries":[{"content":"Read code","status":"completed","priority":"high"},{"content":"Write tests","status":"in_progress","priority":"medium"},{"content":"Ship","status":"pending","priority":"low"}]}"#
        )
        #expect(events == [.plan(text: "- [x] Read code\n- [ ] **Write tests**\n- [ ] Ship")])
    }

    @Test func todoToolsAlsoReportThePlan() {
        var mapper = ACPEventMapper(workingDirectory: cwd)
        mapper.beginTurn()
        let events = map(
            &mapper,
            #"{"sessionUpdate":"tool_call","toolCallId":"todo-1","title":"todo_write","rawInput":{"todos":[{"id":"1","content":"Inspect","status":"completed"},{"id":"2","content":"Fix","status":"in-progress"},{"id":"3","content":"Test"}]},"_meta":{"x.ai/tool":{"name":"todo_write","kind":"other"}}}"#
        )
        #expect(events.count == 2)
        #expect(events.last == .plan(text: "- [x] Inspect\n- [ ] **Fix**\n- [ ] Test"))
        // An unchanged list is not reported again.
        let repeated = map(&mapper, #"{"sessionUpdate":"tool_call_update","toolCallId":"todo-1","status":"completed"}"#)
        #expect(!repeated.contains { if case .plan = $0 { true } else { false } })
    }

    @Test func grokModelsKeepTheDefaultFirstWithEffortsInIncreasingOrder() throws {
        let initialize = ACPInitializeResult(json: try #require(JSONValue.parse(Self.grokInitialize)))
        let models = GrokFlavor().models(initialize: initialize, setup: ACPSessionSetup())
        #expect(models.map(\.modelID) == ["grok-build", "grok-4.7", "grok-4.6"])
        #expect(models[0].displayName == "Grok Build (Grok 4.7)")
        #expect(models[1].efforts == ["low", "medium", "high", "xhigh"])
        #expect(models[1].defaultEffort == "high")
        #expect(models[1].contextWindow == 500_000)
        #expect(models[2].efforts.isEmpty)

        // Once the session reports its current model, the default entry names it.
        let setup = ACPSessionSetup(
            json: ["sessionId": "s", "models": ["currentModelId": "grok-4.6", "availableModels": [["modelId": "grok-4.6", "name": "Grok 4.6"]]]])
        #expect(GrokFlavor().models(initialize: nil, setup: setup).first?.displayName == "Grok Build (Grok 4.6)")
    }

    @Test func configOptionModelsGetEffortsFromTheReasoningOption() throws {
        let setup = ACPSessionSetup(
            json: try #require(
                JSONValue.parse(
                    """
                    {"sessionId":"s","configOptions":[
                    {"id":"model","name":"Model","category":"model","type":"select","currentValue":"gemini-pro","options":[{"value":"gemini-pro","name":"Gemini Pro"},{"value":"gemini-flash","name":"Gemini Flash"}]},
                    {"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"medium","options":[{"value":"high","name":"High"},{"value":"low","name":"Low"},{"value":"medium","name":"Medium"}]}]}
                    """)))
        let models = AntigravityFlavor().models(initialize: nil, setup: setup)
        #expect(models.map(\.modelID) == ["antigravity-default", "gemini-pro", "gemini-flash"])
        #expect(models[0].displayName == "Default (Gemini Pro)")
        #expect(models[1].efforts == ["low", "medium", "high"])
        #expect(models[1].defaultEffort == "medium")
        #expect(models[2].efforts.isEmpty)
    }

    @Test func effortTokensAreValidated() {
        #expect(ACPModels.isEffortToken("xhigh"))
        #expect(ACPModels.isEffortToken("deep-2"))
        #expect(!ACPModels.isEffortToken("not a token"))
        #expect(!ACPModels.isEffortToken(""))
        #expect(ACPModels.sortedEfforts(["high", "custom", "low", "max"]) == ["low", "high", "max", "custom"])
    }

    // MARK: Diffs

    @Test func diffsSplitDistantChangesIntoHunks() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var newLines = (1...20).map { "line \($0)" }
        newLines[1] = "LINE 2"
        newLines[17] = "LINE 18"
        let diff = UnifiedDiff.make(path: "a.txt", old: old, new: newLines.joined(separator: "\n") + "\n")
        #expect(
            diff == """
                --- a/a.txt
                +++ b/a.txt
                @@ -1,5 +1,5 @@
                 line 1
                -line 2
                +LINE 2
                 line 3
                 line 4
                 line 5
                @@ -15,6 +15,6 @@
                 line 15
                 line 16
                 line 17
                -line 18
                +LINE 18
                 line 19
                 line 20
                """)
        #expect(UnifiedDiff.make(path: "a.txt", old: old, new: old).isEmpty)
    }

    @Test func diffsSplitCRLFFilesIntoLines() throws {
        // "\r\n" is one Character, so a CRLF file used to diff as a single line.
        let diff = UnifiedDiff.make(path: "w.txt", old: "a\r\nb\r\nc\r\n", new: "a\r\nB\r\nc\r\n", context: 1)
        #expect(diff == "--- a/w.txt\n+++ b/w.txt\n@@ -1,3 +1,3 @@\n a\r\n-b\r\n+B\r\n c\r")
        let hunk = try #require(DiffParser.parse("diff --git a/w.txt b/w.txt\n" + diff).first?.hunks.first)
        #expect(hunk.lines.map(\.kind) == [.context, .deletion, .addition, .context])
        #expect(hunk.lines.map(\.text) == ["a", "b", "B", "c"])
    }

    @Test func diffsHandleInsertionsAndDeletions() {
        let diff = UnifiedDiff.make(path: "b.txt", old: "a\nb\nc\n", new: "a\nc\nd\n")
        #expect(diff == "--- a/b.txt\n+++ b/b.txt\n@@ -1,3 +1,3 @@\n a\n-b\n c\n+d")
    }

    static let grokInitialize = """
        {"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false,"embeddedContext":true}},
        "authMethods":[{"id":"cached_token","name":"Grok account"},{"id":"xai.api_key","name":"xAI API key"}],
        "agentInfo":{"name":"grok","version":"1.0.67"},
        "_meta":{"modelState":{"currentModelId":"grok-4.7","availableModels":[
        {"modelId":"grok-4.7","name":"Grok 4.7","_meta":{"totalContextTokens":500000,"contextWindows":[256000,500000],"supportsReasoningEffort":true,"reasoningEffort":"high",
         "reasoningEfforts":[{"id":"xhigh","value":"xhigh","label":"Extra High","default":false},{"id":"high","value":"high","label":"High","default":true},
         {"id":"medium","value":"medium","label":"Medium","default":false},{"id":"low","value":"low","label":"Low","default":false}]}},
        {"modelId":"grok-4.6","name":"Grok 4.6","_meta":{"supportsReasoningEffort":false,"reasoningEfforts":[{"value":"high","default":true}]}}]},
        "availableCommands":[{"name":"compact","description":"Compress history"}]}}
        """
}
