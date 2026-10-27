import Foundation
import Testing

@testable import CoincideKit

struct PiModelTests {
    private var inventory: JSONValue { ["models": [PiFixtures.deepseek, PiFixtures.sonnet, PiFixtures.mini]] }

    @Test func catalogListsDefaultThenEveryModelAsProviderSlashID() throws {
        let state = PiFixtures.state(sessionFile: "/s.jsonl")
        let models = try #require(PiModels.catalog(models: inventory, state: state))
        #expect(models.map(\.modelID) == ["default", "openrouter/deepseek/deepseek-v4-flash", "anthropic/claude-sonnet-4-5", "openai/gpt-4o-mini"])
        #expect(models.allSatisfy { $0.provider == .pi })

        let fallback = models[0]
        #expect(fallback.displayName == "Default (DeepSeek: DeepSeek V4 Flash 0423)")
        #expect(fallback.efforts == ["off", "high", "xhigh"])

        let deepseek = models[1]
        #expect(deepseek.displayName == "DeepSeek: DeepSeek V4 Flash 0423")
        #expect(deepseek.contextWindow == 1_048_576)
        #expect(deepseek.supportsImages == false)
        // The recorded map sets minimal/low/medium/max to null and opts in to xhigh.
        #expect(deepseek.efforts == ["off", "high", "xhigh"])
        #expect(deepseek.defaultEffort == "high")

        let sonnet = models[2]
        #expect(sonnet.efforts == ["off", "minimal", "low", "medium", "high"])
        #expect(sonnet.supportsImages)
        #expect(sonnet.defaultEffort == "high")

        #expect(models[3].efforts.isEmpty)
        #expect(models[3].defaultEffort == nil)
    }

    @Test func sameModelFromTwoProvidersIsLabelledWithItsProvider() throws {
        let models = try #require(
            PiModels.catalog(models: ["models": [PiFixtures.sonnet, PiFixtures.sonnetOnOpenRouter, PiFixtures.sonnet]], state: nil))
        #expect(models.map(\.displayName) == ["Default", "Claude Sonnet 4.5 (anthropic)", "Claude Sonnet 4.5 (openrouter)"])
    }

    @Test func malformedInventoryIsNotMistakenForNoModels() {
        // T3 regression #18498: a broken inventory must not read as "signed out".
        #expect(PiModels.catalog(models: [:], state: nil) == nil)
        #expect(PiModels.catalog(models: ["models": [["provider": "anthropic"]]], state: nil) == nil)
        #expect(PiModels.catalog(models: ["models": [PiFixtures.sonnet, ["provider": "openrouter"]]], state: nil) == nil)
        #expect(PiModels.catalog(models: ["models": []], state: nil)?.map(\.modelID) == ["default"])
    }

    @Test func thinkingLevelsClampToTheNearestSupportedOne() {
        let levels = ["off", "high", "xhigh"]
        #expect(PiModels.clamp("high", to: levels) == "high")
        #expect(PiModels.clamp("medium", to: levels) == "high")
        #expect(PiModels.clamp("max", to: levels) == "xhigh")
        #expect(PiModels.clamp("minimal", to: ["off", "low"]) == "low")
        #expect(PiModels.clamp("turbo", to: levels) == nil)
        #expect(PiModels.clamp(nil, to: levels) == nil)
        #expect(PiModels.clamp("high", to: []) == nil)
    }

    @Test func slugsKeepSlashesInsideTheModelID() throws {
        let parsed = try #require(PiModels.parseSlug("openrouter/deepseek/deepseek-v4-flash"))
        #expect(parsed.provider == "openrouter")
        #expect(parsed.modelID == "deepseek/deepseek-v4-flash")
        #expect(PiModels.parseSlug("default") == nil)
        #expect(PiModels.parseSlug("/model") == nil)
        #expect(PiModels.parseSlug("anthropic/") == nil)
        #expect(PiModels.slug(of: PiFixtures.sonnet) == "anthropic/claude-sonnet-4-5")
    }

    @Test func versionsAreReadFromCurrentAndOlderOutput() {
        #expect(PiModels.version(in: "1.4.0\n") == "1.4.0")
        #expect(PiModels.version(in: "pi 0.84.3\n") == "0.84.3")
        #expect(PiModels.version(in: "v0.80.10") == "0.80.10")
        #expect(PiModels.version(in: "command not found") == nil)
    }

    @Test func requiresAgentSettledAndSessionEntries() {
        #expect(PiModels.isSupported(version: "0.80.5"))
        #expect(PiModels.isSupported(version: "0.80.10"))
        #expect(PiModels.isSupported(version: "1.4.0"))
        #expect(!PiModels.isSupported(version: "0.80.4"))
        #expect(!PiModels.isSupported(version: "0.79.10"))
    }

    @Test func providersAreListedOnceInOrder() {
        #expect(PiModels.providers(in: ["models": [PiFixtures.deepseek, PiFixtures.sonnet, PiFixtures.sonnetOnOpenRouter]]) == ["openrouter", "anthropic"])
    }

    @Test func compactCommandMatchesT3() {
        #expect(PiCompactCommand.parse("/compact") == PiCompactCommand())
        #expect(PiCompactCommand.parse("  /compact   ") == PiCompactCommand())
        #expect(PiCompactCommand.parse("/compact keep the opaque marker") == PiCompactCommand(instructions: "keep the opaque marker"))
        #expect(PiCompactCommand.parse("/compaction") == nil)
        #expect(PiCompactCommand.parse("please /compact") == nil)
    }

    @Test func imagesAreSentAsBase64WithTheirType() throws {
        let directory = piScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = directory.appendingPathComponent("shot.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        try bytes.write(to: png)
        let payload = try PiImages.payload([png.path])
        #expect(payload == [["type": "image", "data": .string(bytes.base64EncodedString()), "mimeType": "image/png"]])
        #expect(throws: AgentError.self) { try PiImages.payload([directory.appendingPathComponent("missing.png").path]) }
    }
}

struct PiToolTests {
    @Test func shellCommandsShowTheCommand() {
        let info = PiTools.info(id: "c1", name: "bash", args: ["command": "echo coincide-ok"])
        #expect(info == ToolCallInfo(id: "c1", category: .command, title: "Run `echo coincide-ok`", detail: "echo coincide-ok"))
        let long = PiTools.info(id: "c2", name: "bash", args: ["command": .string(PiFixtures.interruptedCommand)])
        #expect(long.title == "Run `\(PiText.summary(PiFixtures.interruptedCommand))`")
        #expect(long.title.hasSuffix("…`"))
        #expect(PiTools.info(id: "c3", name: "bash", args: nil).title == "Run a command")
    }

    @Test func fileToolsNameTheFile() {
        let edit = PiTools.info(
            id: "e", name: "edit", args: ["path": "a.ts", "edits": [["oldText": "old\n", "newText": "new\nline\n"]]])
        #expect(edit.category == .fileChange)
        #expect(edit.title == "Edit a.ts")
        #expect(edit.detail == "--- a.ts\n+++ a.ts\n@@\n-old\n+new\n+line")
        let legacy = PiTools.info(id: "e", name: "edit", args: ["path": "a.ts", "oldText": "x", "newText": "y"])
        #expect(legacy.detail == "--- a.ts\n+++ a.ts\n@@\n-x\n+y")
        let write = PiTools.info(id: "w", name: "write", args: ["path": "b.ts", "content": "export {};\n"])
        #expect(write == ToolCallInfo(id: "w", category: .fileChange, title: "Write b.ts", detail: "export {};\n"))
        let read = PiTools.info(id: "r", name: "read", args: ["path": "README.md", "offset": 10, "limit": 5])
        #expect(read == ToolCallInfo(id: "r", category: .read, title: "Read README.md", detail: "Lines 10–14"))
    }

    @Test func searchToolsDescribeTheQuery() {
        #expect(PiTools.info(id: "g", name: "grep", args: ["pattern": "TODO", "path": "Sources"]).title == "Search for `TODO` in Sources")
        #expect(PiTools.info(id: "f", name: "find", args: ["pattern": "*.swift"]).title == "Find `*.swift`")
        #expect(PiTools.info(id: "l", name: "ls", args: [:]).title == "List .")
        #expect(PiTools.category(for: "grep") == .search)
        #expect(PiTools.category(for: "ls") == .read)
        #expect(PiTools.category(for: "tool_search") == .search)
    }

    @Test func mcpWebAndOtherTools() {
        let mcp = PiTools.info(id: "m", name: "mcp__radius__list_projects", args: ["limit": 5])
        #expect(mcp.category == .mcp)
        #expect(mcp.title == "radius: list_projects")
        #expect(mcp.detail == "{\n  \"limit\" : 5\n}")
        #expect(PiTools.category(for: "read_mcp_resource") == .mcp)
        #expect(PiTools.info(id: "s", name: "web_search", args: ["query": "swift 6"]).title == "Search the web for `swift 6`")
        #expect(PiTools.category(for: "web_fetch") == .web)
        let custom = PiTools.info(id: "x", name: "deploy", args: [:])
        #expect(custom == ToolCallInfo(id: "x", category: .other, title: "deploy", detail: nil))
        #expect(PiTools.category(for: "subagent") == .task)
        #expect(PiTools.category(for: "todo") == .todo)
    }

    @Test func subagentsShowTheirTaskAndLatestAnswer() {
        let single = PiTools.info(id: "s", name: "subagent", args: ["agent": "scout", "task": "map the repo"])
        #expect(single.title == "Ask scout: map the repo")
        #expect(PiTools.info(id: "p", name: "subagent", args: ["tasks": [["agent": "a", "task": "x"], ["agent": "b", "task": "y"]]]).detail == "a: x\nb: y")
        let details: JSONValue = [
            "results": [
                ["agent": "scout", "task": "map", "exitCode": 0, "messages": [["role": "assistant", "content": [["type": "text", "text": "two files"]]]]],
                ["agent": "worker", "task": "fix", "exitCode": 1, "stderr": "boom", "messages": []],
            ]
        ]
        #expect(PiTools.subagentOutput(details) == "scout:\ntwo files\n\nworker:\nboom")
    }

    @Test func todoListsBecomeChecklists() {
        let result: JSONValue = [
            "details": ["todos": [["id": 1, "text": "write tests", "done": true], ["id": 2, "text": "ship", "done": false]]]
        ]
        #expect(PiTools.todoMarkdown(result) == "- [x] write tests\n- [ ] ship")
        let statuses: JSONValue = ["details": ["todos": [["content": "plan", "status": "in_progress"], ["content": "done", "status": "completed"]]]]
        #expect(PiTools.todoMarkdown(statuses) == "- [ ] **plan**\n- [x] done")
        #expect(PiTools.todoMarkdown(["details": ["todos": []]]) == "No todos.")
        #expect(PiTools.todoMarkdown(["content": []]) == nil)
    }

    @Test func alwaysAllowRemembersTheExactSubject() {
        #expect(PiTools.approvalKey(name: "bash", args: ["command": "npm test"]) == "bash\u{0}npm test")
        #expect(PiTools.approvalKey(name: "edit", args: ["path": "a.ts", "edits": []]) == "edit\u{0}a.ts")
        #expect(PiTools.approvalKey(name: "deploy", args: ["env": "staging"]) == "deploy\u{0}{\"env\":\"staging\"}")
    }
}

struct PiTurnMapperTests {
    private func replay(_ lines: [String], into mapper: inout PiTurnMapper) -> [AgentEvent] {
        lines.flatMap { mapper.handle(PiFixtures.parse($0)) }
    }

    @Test func recordedSimpleTurnStreamsReasoningThenTheAnswer() {
        var mapper = PiTurnMapper()
        mapper.contextWindow = 1_048_576
        mapper.begin(itemPrefix: "t1")
        let events = replay(PiFixtures.simpleTurn, into: &mapper)
        let thinking = "The user wants me to respond with a specific text: \"fixture simple ok\". Let me do that."
        #expect(
            events == [
                .reasoningDelta(itemID: "t1.m1.c0", delta: "The"),
                .reasoningDelta(itemID: "t1.m1.c0", delta: " user wants me to respond with"),
                .reasoningDelta(itemID: "t1.m1.c0", delta: " a specific text: \"fi"),
                .reasoningDelta(itemID: "t1.m1.c0", delta: "xture simple ok\". Let"),
                .reasoningDelta(itemID: "t1.m1.c0", delta: " me do that."),
                .assistantTextDelta(itemID: "t1.m1.c1", delta: "fi"),
                .assistantTextDelta(itemID: "t1.m1.c1", delta: "xture simple ok"),
                .usage(TokenUsage(inputTokens: 1814, outputTokens: 28, cachedInputTokens: 0, contextWindow: 1_048_576)),
                .reasoningText(itemID: "t1.m1.c0", text: thinking),
                .assistantText(itemID: "t1.m1.c1", text: "fixture simple ok"),
            ])
        #expect(mapper.failure == nil)
        #expect(mapper.finish().isEmpty)
    }

    @Test func usageIsReportedPerRequestNotPerToken() {
        var mapper = PiTurnMapper()
        mapper.contextWindow = 200_000
        let update = { (input: Int, output: Int) -> JSONValue in
            [
                "type": "message_update", "usage": ["input": .number(Double(input)), "output": .number(Double(output)), "cacheRead": 0, "cacheWrite": 0, "totalTokens": .number(Double(input + output))],
                "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": "x"],
            ]
        }
        _ = mapper.handle(["type": "message_start", "message": ["role": "assistant", "content": []]])
        #expect(mapper.handle(update(100, 1)).first == .usage(TokenUsage(inputTokens: 101, outputTokens: 1, cachedInputTokens: 0, contextWindow: 200_000)))
        #expect(mapper.handle(update(100, 5)).count == 1)
        let end: JSONValue = [
            "type": "message_end",
            "message": ["role": "assistant", "content": [["type": "text", "text": "xx"]], "usage": ["input": 100, "output": 20, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 120]],
        ]
        #expect(mapper.handle(end).first == .usage(TokenUsage(inputTokens: 120, outputTokens: 20, cachedInputTokens: 0, contextWindow: 200_000)))
    }

    @Test func recordedInterruptedCommandFailsAndKeepsPisError() {
        var mapper = PiTurnMapper()
        mapper.begin(itemPrefix: "t2")
        let before = replay(PiFixtures.toolTurnBeforeAbort, into: &mapper)
        let id = PiFixtures.interruptedCallID
        let started = ToolCallInfo(id: id, category: .command, title: "Run a command")
        let resolved = PiTools.info(id: id, name: "bash", args: ["command": .string(PiFixtures.interruptedCommand), "timeout": 35])
        #expect(before.first == .toolStarted(started))
        #expect(before.contains(.toolUpdated(resolved)))
        #expect(resolved.detail == PiFixtures.interruptedCommand)
        #expect(before.filter { if case .toolStarted = $0 { true } else { false } }.count == 1)

        let after = replay(PiFixtures.toolTurnAfterAbort, into: &mapper)
        #expect(after == [.toolCompleted(id: id, status: .failed, output: "Command aborted")])
        // The session reports the turn as interrupted; the mapper only keeps what Pi said.
        #expect(mapper.failure == "This operation was aborted")
    }

    @Test func recordedCommandOutputStreamsAsDeltas() {
        var mapper = PiTurnMapper()
        mapper.begin(itemPrefix: "t1")
        let events = replay(PiFixtures.streamedCommand, into: &mapper)
        let id = "call_8ac3cb4177994abdb9aa1c57"
        #expect(events.count == 3)
        #expect(events[1] == .toolOutput(id: id, delta: "interrupt fixture tool started\n"))
        #expect(events[2] == .toolCompleted(id: id, status: .failed, output: "interrupt fixture tool started\n\n\nCommand aborted"))
    }

    @Test func cumulativeOutputOnlySendsWhatIsNew() {
        var mapper = PiTurnMapper()
        _ = mapper.handle(["type": "tool_execution_start", "toolCallId": "b", "toolName": "bash", "args": ["command": "make"]])
        let update = { (text: String) -> JSONValue in
            ["type": "tool_execution_update", "toolCallId": "b", "toolName": "bash", "partialResult": ["content": [["type": "text", "text": .string(text)]]]]
        }
        #expect(mapper.handle(update("a")) == [.toolOutput(id: "b", delta: "a")])
        #expect(mapper.handle(update("ab")) == [.toolOutput(id: "b", delta: "b")])
        #expect(mapper.handle(update("ab")).isEmpty)
        // Pi keeps only the tail of long output; once it no longer extends what was shown, wait for the result.
        #expect(mapper.handle(update("xyz")).isEmpty)
        #expect(mapper.handle(update("xyz1")).isEmpty)
        let end: JSONValue = [
            "type": "tool_execution_end", "toolCallId": "b", "toolName": "bash",
            "result": ["content": [["type": "text", "text": "done\n\nCommand exited with code 2"]], "structuredContent": ["exit_code": 2]],
            "isError": true,
        ]
        #expect(mapper.handle(end) == [.toolCompleted(id: "b", status: .failed, output: "done\n\nCommand exited with code 2")])
    }

    @Test func editsReportPisPatchAndWritesTheirContent() {
        // From T3's "persists edit patches and write content on file change items".
        var mapper = PiTurnMapper()
        let patch = "--- a.ts\n+++ a.ts\n@@ -1 +1 @@\n-old\n+new\n"
        let edits: JSONValue = ["path": "a.ts", "edits": [["oldText": "old", "newText": "new"]]]
        #expect(
            mapper.handle(["type": "tool_execution_start", "toolCallId": "call_edit", "toolName": "edit", "args": edits]) == [
                .toolStarted(ToolCallInfo(id: "call_edit", category: .fileChange, title: "Edit a.ts", detail: "--- a.ts\n+++ a.ts\n@@\n-old\n+new"))
            ])
        let end: JSONValue = [
            "type": "tool_execution_end", "toolCallId": "call_edit", "toolName": "edit", "isError": false,
            "result": [
                "content": [["type": "text", "text": "Successfully replaced 1 block(s) in a.ts."]],
                "details": ["diff": "-1 old\n+1 new", "patch": .string(patch), "firstChangedLine": 1],
            ],
        ]
        #expect(
            mapper.handle(end) == [
                .toolUpdated(ToolCallInfo(id: "call_edit", category: .fileChange, title: "Edit a.ts", detail: patch.trimmingCharacters(in: .whitespacesAndNewlines))),
                .toolCompleted(id: "call_edit", status: .completed, output: "Successfully replaced 1 block(s) in a.ts."),
            ])

        _ = mapper.handle(["type": "tool_execution_start", "toolCallId": "call_write", "toolName": "write", "args": ["path": "b.ts", "content": "export {};\n"]])
        let written = mapper.handle([
            "type": "tool_execution_end", "toolCallId": "call_write", "toolName": "write", "isError": false,
            "result": ["content": [["type": "text", "text": "Successfully wrote to b.ts"]]],
        ])
        #expect(written == [.toolCompleted(id: "call_write", status: .completed, output: "Successfully wrote to b.ts")])
        #expect(mapper.tool("call_write")?.info?.detail == "export {};\n")

        _ = mapper.handle(["type": "tool_execution_start", "toolCallId": "call_failed", "toolName": "edit", "args": ["path": "c.ts", "edits": [["oldText": "missing", "newText": "new"]]]])
        let failed = mapper.handle([
            "type": "tool_execution_end", "toolCallId": "call_failed", "toolName": "edit", "isError": true,
            "result": ["content": [["type": "text", "text": "Could not find the text in c.ts."]]],
        ])
        #expect(failed == [.toolCompleted(id: "call_failed", status: .failed, output: "Could not find the text in c.ts.")])
    }

    @Test func refusedToolCallsReadAsDeclined() {
        var mapper = PiTurnMapper()
        _ = mapper.handle(["type": "tool_execution_start", "toolCallId": "d", "toolName": "bash", "args": ["command": "rm -rf build"]])
        mapper.markDeclined("d")
        let declined = mapper.handle([
            "type": "tool_execution_end", "toolCallId": "d", "toolName": "bash", "isError": true,
            "result": ["content": [["type": "text", "text": "The user declined this bash call."]]],
        ])
        #expect(declined == [.toolCompleted(id: "d", status: .declined, output: "The user declined this bash call.")])

        _ = mapper.handle(["type": "tool_execution_start", "toolCallId": "p", "toolName": "write", "args": ["path": "x", "content": ""]])
        let reason = "\(PiExtension.planModeBlockPrefix)write is not available. Use read-only tools, then call propose_plan with your plan."
        let blocked = mapper.handle([
            "type": "tool_execution_end", "toolCallId": "p", "toolName": "write", "isError": true,
            "result": ["content": [["type": "text", "text": .string(reason)]]],
        ])
        #expect(blocked == [.toolCompleted(id: "p", status: .declined, output: reason)])
    }

    @Test func proposedPlanBecomesThePlanNotAToolCall() {
        var mapper = PiTurnMapper()
        let plan = "## Plan\n1. Add the parser\n2. Test it"
        let start: JSONValue = ["type": "tool_execution_start", "toolCallId": "plan", "toolName": "propose_plan", "args": ["plan": .string(plan)]]
        #expect(mapper.handle(start) == [.plan(text: plan)])
        let end: JSONValue = [
            "type": "tool_execution_end", "toolCallId": "plan", "toolName": "propose_plan", "isError": false,
            "result": ["content": [["type": "text", "text": "The plan is in front of the user."]]],
        ]
        #expect(mapper.handle(end).isEmpty)
        #expect(mapper.finish().isEmpty)
    }

    @Test func todoToolUpdatesThePlan() {
        var mapper = PiTurnMapper()
        _ = mapper.handle(["type": "tool_execution_start", "toolCallId": "t", "toolName": "todo", "args": ["action": "add", "text": "ship"]])
        let events = mapper.handle([
            "type": "tool_execution_end", "toolCallId": "t", "toolName": "todo", "isError": false,
            "result": [
                "content": [["type": "text", "text": "Added todo #2: ship"]],
                "details": ["action": "add", "todos": [["id": 1, "text": "test", "done": true], ["id": 2, "text": "ship", "done": false]], "nextId": 3],
            ],
        ])
        #expect(events == [.plan(text: "- [x] test\n- [ ] ship"), .toolCompleted(id: "t", status: .completed, output: "Added todo #2: ship")])
    }

    @Test func subagentProgressAndResultFromT3Fixture() {
        var mapper = PiTurnMapper()
        let running = mapper.handle([
            "type": "tool_execution_update", "toolCallId": "call_sub", "toolName": "subagent",
            "partialResult": [
                "content": [["type": "text", "text": "(running...)"]],
                "details": ["mode": "single", "results": [["agent": "scout", "task": "map the repo", "exitCode": 0, "stderr": "", "messages": [["role": "assistant", "content": [["type": "text", "text": "scanning files"]]]]]]],
            ],
        ])
        #expect(running == [.toolStarted(ToolCallInfo(id: "call_sub", category: .task, title: "Run a subagent")), .toolOutput(id: "call_sub", delta: "scanning files")])
        let done = mapper.handle([
            "type": "tool_execution_end", "toolCallId": "call_sub", "toolName": "subagent", "isError": false,
            "result": [
                "content": [["type": "text", "text": "done"]],
                "details": ["mode": "single", "results": [["agent": "scout", "task": "map the repo", "exitCode": 0, "stopReason": "stop", "stderr": "", "messages": [["role": "assistant", "content": [["type": "text", "text": "repo has one file"]]]]]]],
            ],
        ])
        #expect(done == [.toolCompleted(id: "call_sub", status: .completed, output: "repo has one file")])
    }

    @Test func recordedCompactionsShowAsItems() {
        var mapper = PiTurnMapper()
        mapper.begin(itemPrefix: "t3")
        let refused = replay(PiFixtures.refusedCompaction, into: &mapper)
        #expect(
            refused == [
                .toolStarted(ToolCallInfo(id: "t3.compaction1", category: .other, title: "Compacting context")),
                .toolCompleted(id: "t3.compaction1", status: .failed, output: "Compaction failed: Nothing to compact (session too small)"),
            ])
        let compacted = replay(PiFixtures.compaction, into: &mapper)
        let title = "Compacted context from \(1901.formatted()) to about \(1890.formatted()) tokens"
        #expect(compacted.count == 3)
        #expect(compacted[1] == .toolUpdated(ToolCallInfo(id: "t3.compaction2", category: .other, title: title)))
        if case .toolCompleted(let id, let status, let output) = compacted[2] {
            #expect(id == "t3.compaction2")
            #expect(status == .completed)
            #expect(output?.hasPrefix("## Goal") == true)
        } else {
            Issue.record("Expected the compaction to complete")
        }
        #expect(mapper.sawCompaction)
        #expect(mapper.tokensAfterCompaction == 1890)
    }

    @Test func modelErrorsRetriesAndExtensionsAreReported() {
        var mapper = PiTurnMapper()
        _ = mapper.handle(["type": "message_start", "message": ["role": "assistant", "content": []]])
        _ = mapper.handle(["type": "message_end", "message": ["role": "assistant", "content": [], "stopReason": "error", "errorMessage": "429 rate limited"]])
        #expect(mapper.failure == "429 rate limited")

        let retry = mapper.handle(["type": "auto_retry_start", "attempt": 1, "maxAttempts": 3, "delayMs": 2000, "errorMessage": "529 overloaded"])
        #expect(retry == [.notice("Retrying after a provider error (attempt 1 of 3): 529 overloaded")])
        _ = mapper.handle(["type": "auto_retry_end", "success": true, "attempt": 2])
        #expect(mapper.failure == nil)
        _ = mapper.handle(["type": "auto_retry_end", "success": false, "attempt": 3, "finalError": "529 overloaded"])
        #expect(mapper.failure == "529 overloaded")

        let failure = mapper.handle(["type": "extension_error", "extensionPath": "/Users/me/.pi/agent/extensions/subagent/index.ts", "event": "tool_call", "error": "boom"])
        #expect(failure == [.notice("subagent failed during tool_call.\n\nboom")])
        let shown = mapper.handle(["type": "message_end", "message": ["role": "custom", "customType": "plan-complete", "content": "Plan complete", "display": true]])
        #expect(shown == [.notice("Plan complete")])
        #expect(mapper.handle(["type": "message_end", "message": ["role": "custom", "customType": "x", "content": "hidden", "display": false]]).isEmpty)
    }

    @Test func finishFailsToolsThatNeverReported() {
        var mapper = PiTurnMapper()
        _ = mapper.handle(["type": "message_update", "assistantMessageEvent": ["type": "toolcall_start", "contentIndex": 0, "id": "never", "toolName": "write"]])
        _ = mapper.handle(["type": "compaction_start", "reason": "threshold"])
        #expect(mapper.finish() == [.toolCompleted(id: "never", status: .failed, output: nil), .toolCompleted(id: "t0.compaction1", status: .failed, output: nil)])
        #expect(mapper.finish().isEmpty)
    }
}

struct PiDialogTests {
    private func knownTool(_ id: String) -> PiTurnMapper.Tool? {
        guard id == "call_1" else { return nil }
        let args: JSONValue = ["command": "echo coincide-ok"]
        return PiTurnMapper.Tool(name: "bash", args: args, info: PiTools.info(id: id, name: "bash", args: args))
    }

    @Test func toolApprovalsDescribeTheToolCall() throws {
        let marker = #"{"coincide":"coincide.toolApproval","toolCallId":"call_1","toolName":"bash"}"#
        let record: JSONValue = ["type": "extension_ui_request", "id": "ui-1", "method": "confirm", "title": "Allow bash?", "message": .string(marker)]
        let dialog = try #require(PiDialog(record, tool: knownTool))
        #expect(
            dialog.request
                == ApprovalRequest(
                    id: "ui-1", category: .command, title: "Run `echo coincide-ok`", detail: "echo coincide-ok",
                    options: ApprovalRequest.standardOptions, toolCallID: "call_1"))
        #expect(dialog.rememberKey == "tool\u{0}bash\u{0}echo coincide-ok")
        #expect(dialog.response(for: "allow") == ["type": "extension_ui_response", "id": "ui-1", "confirmed": true])
        #expect(dialog.response(for: "allow_always") == ["type": "extension_ui_response", "id": "ui-1", "confirmed": true])
        #expect(dialog.response(for: "deny") == ["type": "extension_ui_response", "id": "ui-1", "confirmed": false])
        #expect(dialog.declines("deny"))
        #expect(!dialog.declines("allow"))
        #expect(dialog.timeout == nil)
    }

    @Test func otherConfirmationsShowTheirText() throws {
        // From T3's "emits session-start dialogs before a turn exists".
        let record: JSONValue = [
            "type": "extension_ui_request", "id": "ui-trust", "method": "confirm", "title": "Run project extensions?",
            "message": "This project has .pi/extensions.", "timeout": 5000,
        ]
        let dialog = try #require(PiDialog(record) { _ in nil })
        #expect(dialog.request.title == "Run project extensions?")
        #expect(dialog.request.detail == "This project has .pi/extensions.")
        #expect(dialog.request.category == .other)
        #expect(dialog.request.toolCallID == nil)
        #expect(dialog.rememberKey == "confirm\u{0}Run project extensions?\u{0}This project has .pi/extensions.")
        #expect(dialog.timeout == .milliseconds(5000))
    }

    @Test func selectOffersEachChoiceAndKeepsEmptyValues() throws {
        // From T3's "emits a valid empty select option and returns its original value".
        let record: JSONValue = ["type": "extension_ui_request", "id": "ui-select", "method": "select", "title": "Pick a tag", "options": ["stable", ""]]
        let dialog = try #require(PiDialog(record) { _ in nil })
        #expect(dialog.request.options.map(\.label) == ["stable", "Empty value", "Cancel"])
        #expect(dialog.request.options.map(\.kind) == [.allowOnce, .allowOnce, .cancel])
        #expect(dialog.response(for: "option.1") == ["type": "extension_ui_response", "id": "ui-select", "value": ""])
        #expect(dialog.response(for: "cancel") == ["type": "extension_ui_response", "id": "ui-select", "cancelled": true])
        #expect(!dialog.declines("option.0"))
        #expect(dialog.declines("cancel"))
    }

    @Test func inputAndEditorCanBeAnsweredOrDismissed() throws {
        let input = try #require(PiDialog(["id": "i", "method": "input", "title": "Which database?", "placeholder": ""]) { _ in nil })
        #expect(input.response(for: "empty") == ["type": "extension_ui_response", "id": "i", "value": ""])
        #expect(input.request.detail == nil)
        let prefill = "  fix(server): retain full editor content\n"
        let editor = try #require(PiDialog(["id": "e", "method": "editor", "title": "Commit message", "prefill": .string(prefill)]) { _ in nil })
        #expect(editor.request.detail == prefill)
        #expect(editor.response(for: "keep") == ["type": "extension_ui_response", "id": "e", "value": .string(prefill)])
        #expect(editor.response(for: "unknown") == ["type": "extension_ui_response", "id": "e", "cancelled": true])
    }

    @Test func notificationsAreNotDialogs() {
        #expect(PiDialog(["id": "n", "method": "notify", "message": "hi"]) { _ in nil } == nil)
        #expect(PiDialog(["id": "s", "method": "setStatus", "statusKey": "k"]) { _ in nil } == nil)
        #expect(PiDialog(["method": "confirm", "title": "no id"]) { _ in nil } == nil)
        #expect(PiDialog(["id": "x", "method": "select", "options": [], "timeout": -5]) { _ in nil }?.timeout == .zero)
    }
}

struct PiExtensionTests {
    @Test func extensionIsWrittenOnceAndRepairedWhenChanged() throws {
        let directory = piScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try PiExtension.materialize(in: directory)
        #expect(url.lastPathComponent == "coincide-pi-extension.ts")
        #expect(try String(contentsOf: url, encoding: .utf8) == PiExtension.source)
        try "// edited".write(to: url, atomically: true, encoding: .utf8)
        _ = try PiExtension.materialize(in: directory)
        #expect(try String(contentsOf: url, encoding: .utf8) == PiExtension.source)
    }

    @Test func extensionSpeaksTheSameProtocolAsTheSession() {
        let source = PiExtension.source
        #expect(source.contains(#"process.env["COINCIDE_PI_ACCESS"] === "approval""#))
        #expect(source.contains(#"process.env["COINCIDE_PI_PLAN"] === "1""#))
        #expect(source.contains(#"const APPROVAL_MARKER = "coincide.toolApproval";"#))
        #expect(source.contains(#"const PLAN_TOOL = "propose_plan";"#))
        #expect(source.contains(#"const PLAN_BLOCK_PREFIX = "Plan mode is on, so ";"#))
        #expect(source.contains(#"import { Type } from "typebox";"#))
        #expect(!source.contains("\\#("))
    }

    @Test func launchArgumentsAndPolicyEnvironment() {
        #expect(PiLaunch.arguments(extensionPath: "/x.ts", forkingFrom: nil) == ["--mode", "rpc", "--extension", "/x.ts"])
        #expect(PiLaunch.arguments(extensionPath: "/x.ts", forkingFrom: "/s.jsonl") == ["--mode", "rpc", "--fork", "/s.jsonl", "--extension", "/x.ts"])
        let approval = PiLaunch.environment(["PATH": "/bin"], accessMode: .approval, interactionMode: .plan)
        #expect(approval == ["PATH": "/bin", "COINCIDE_PI_ACCESS": "approval", "COINCIDE_PI_PLAN": "1"])
        let full = PiLaunch.environment([:], accessMode: .fullAccess, interactionMode: .build)
        #expect(full == ["COINCIDE_PI_ACCESS": "full", "COINCIDE_PI_PLAN": "0"])
    }

    @Test func resumeFollowsTheSessionFileAndItsFolder() throws {
        let directory = piScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("project")
        let elsewhere = directory.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let file = piSessionFile(in: directory, workingDirectory: project)
        #expect(PiSessionFile.workingDirectory(ofSessionAt: file) == project.path)
        #expect(PiLaunch.resume(nil, workingDirectory: project) == .fresh)
        #expect(PiLaunch.resume(directory.appendingPathComponent("gone.jsonl").path, workingDirectory: project) == .fresh)
        #expect(PiLaunch.resume(file, workingDirectory: project) == .switchTo(file))
        #expect(PiLaunch.resume(file, workingDirectory: elsewhere) == .fork(file))
        #expect(PiSessionFile.samePath("/tmp", "/private/tmp"))
        #expect(!PiSessionFile.samePath(project.path, elsewhere.path))
    }
}

@MainActor
struct PiRPCClientTests {
    @Test func responsesResolveByIDAndEverythingElseIsAnEvent() async throws {
        let transport = FakePiTransport(arguments: [], environment: [:])
        let client = PiRPCClient(transport: transport)
        var events: [JSONValue] = []
        client.onEvent = { events.append($0) }
        try client.start()
        transport.reply = { record in
            ["type": "response", "id": record["id"] ?? .null, "command": "get_state", "success": true, "data": ["sessionFile": "/s.jsonl"]]
        }
        let state = try await client.request(["type": "get_state"], timeout: .seconds(1))
        #expect(state["sessionFile"]?.string == "/s.jsonl")
        #expect(transport.written.first?["id"]?.string == "coincide-1")
        transport.emit(#"{"type":"agent_start"}"#)
        transport.emit("not json")
        #expect(events == [["type": "agent_start"]])
    }

    @Test func rejectionsTimeoutsAndExitsBecomeErrors() async throws {
        let transport = FakePiTransport(arguments: [], environment: [:])
        let client = PiRPCClient(transport: transport)
        try client.start()
        transport.reply = { record in
            ["type": "response", "id": record["id"] ?? .null, "command": "set_model", "success": false, "error": "Model not found: x/y"]
        }
        await #expect(throws: PiRPCError.self) { try await client.request(["type": "set_model"], timeout: .seconds(1)) }
        do {
            _ = try await client.request(["type": "set_model"], timeout: .seconds(1))
        } catch {
            #expect(error.localizedDescription == "Model not found: x/y")
        }

        transport.reply = nil
        do {
            _ = try await client.request(["type": "get_state"], timeout: .milliseconds(20))
            Issue.record("Expected a timeout")
        } catch let error as PiRPCError {
            #expect(error.localizedDescription.contains("get_state"))
        }

        var reason: String?
        client.onExit = { reason = $0 }
        Task { transport.exit(status: 1, stderr: "\u{1B}[31mError: Unknown option --bogus\u{1B}[39m\n") }
        do {
            _ = try await client.request(["type": "get_state"], timeout: nil)
            Issue.record("Expected the exit to fail the request")
        } catch let error as PiRPCError {
            #expect(error.isClosed)
        }
        #expect(reason == "Pi exited with code 1.\nError: Unknown option --bogus")
        #expect(!client.isOpen)
        await #expect(throws: PiRPCError.self) { try await client.request(["type": "get_state"], timeout: nil) }
    }
}
