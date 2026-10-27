import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CoincideKit

/// Frames recorded from Claude Code 2.1.308 in stream-json mode, trimmed of bulky fields.
enum ClaudeFixture {
    static let cwd = "/private/tmp/claude-probe/cwd"

    static let initFrame = #"""
        {"type":"system","subtype":"init","cwd":"/private/tmp/claude-probe/cwd","session_id":"29718ecd-ee07-4e0c-9590-9666442ec28f","tools":["Task","AskUserQuestion","Bash","Edit","ExitPlanMode","Read","Write"],"mcp_servers":[],"model":"claude-haiku-5-5","permissionMode":"default","claude_code_version":"2.1.308","capabilities":["interrupt_receipt_v1","interrupt_cancel_queued_v1","msg_lifecycle_v1"],"uuid":"63f5ecf1-03a9-40a6-b292-914b7de1cea9"}
        """#

    /// "Reply with exactly: pong"
    static let pongTurn = [
        #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-haiku-5-5","id":"msg_011CgSG2mzQXcubAcqMv7eaV","type":"message","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":40428,"cache_read_input_tokens":12702,"output_tokens":1}}},"session_id":"29718ecd-ee07-4e0c-9590-9666442ec28f","parent_tool_use_id":null,"thinking_display":"updates"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"29718ecd-ee07-4e0c-9590-9666442ec28f","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"p"}},"session_id":"29718ecd-ee07-4e0c-9590-9666442ec28f","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ong"}},"session_id":"29718ecd-ee07-4e0c-9590-9666442ec28f","parent_tool_use_id":null}"#,
        #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011CgSG2mzQXcubAcqMv7eaV","type":"message","role":"assistant","content":[{"type":"text","text":"pong"}],"stop_reason":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":40428,"cache_read_input_tokens":12702,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"29718ecd-ee07-4e0c-9590-9666442ec28f","uuid":"0d11b786-b34c-4030-a09c-4f84ea058f30"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"session_id":"29718ecd-ee07-4e0c-9590-9666442ec28f","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":2,"cache_creation_input_tokens":40428,"cache_read_input_tokens":12702,"output_tokens":4,"output_tokens_details":{"thinking_tokens":0}}},"session_id":"29718ecd-ee07-4e0c-9590-9666442ec28f","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"message_stop"},"session_id":"29718ecd-ee07-4e0c-9590-9666442ec28f","parent_tool_use_id":null}"#,
    ]

    static let pongResult = #"""
        {"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","num_turns":1,"result":"pong","session_id":"29718ecd-ee07-4e0c-9590-9666442ec28f","total_cost_usd":0.00833972,"modelUsage":{"claude-haiku-5-5":{"costUSD":0.00833972,"contextWindow":1000000}}}
        """#

    static let bashStart = #"""
        {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_017UX8e11oohShjRZSvwtYyW","name":"Bash","input":{},"caller":{"type":"direct"}}},"session_id":"d370472f-cc81-4dbd-ba9b-062e13fe4c62","parent_tool_use_id":null}
        """#
    static let messageStart = #"""
        {"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-haiku-5-5","id":"msg_011CgSG3zm8xictzUX1uFaQM","type":"message","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":37844,"cache_read_input_tokens":15329,"output_tokens":20}}},"session_id":"d370472f-cc81-4dbd-ba9b-062e13fe4c62","parent_tool_use_id":null}
        """#
    static let bashSnapshot = #"""
        {"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011CgSG3zm8xictzUX1uFaQM","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_017UX8e11oohShjRZSvwtYyW","name":"Bash","input":{"command":"echo coincide-ok","description":"Print coincide-ok"},"caller":{"type":"direct"}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":37844,"cache_read_input_tokens":15329,"output_tokens":20}},"parent_tool_use_id":null,"session_id":"d370472f-cc81-4dbd-ba9b-062e13fe4c62","uuid":"1a768b10-3f5b-459c-bb9b-c4c73318e055"}
        """#
    static let bashResult = #"""
        {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_017UX8e11oohShjRZSvwtYyW","type":"tool_result","content":"coincide-ok","is_error":false}]},"parent_tool_use_id":null,"session_id":"d370472f-cc81-4dbd-ba9b-062e13fe4c62","tool_use_result":{"stdout":"coincide-ok","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false},"tool_result_meta":[{"id":"toolu_017UX8e11oohShjRZSvwtYyW","permission_decision":{"decision":"accept","source":"config","reason_type":"subcommandResults"}}]}
        """#
    static let writeStart = #"""
        {"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01CaUWXCpaTwngG18dp2F7vn","name":"Write","input":{},"caller":{"type":"direct"}}},"session_id":"d370472f-cc81-4dbd-ba9b-062e13fe4c62","parent_tool_use_id":null}
        """#
    static let writeInputDelta = #"""
        {"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"file_path\": \"/private/tmp/claude-probe/cwd/note.txt\", \"conte"}},"session_id":"d370472f-cc81-4dbd-ba9b-062e13fe4c62","parent_tool_use_id":null}
        """#
    static let writeSnapshot = #"""
        {"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011CgSG3zm8xictzUX1uFaQM","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01CaUWXCpaTwngG18dp2F7vn","name":"Write","input":{"file_path":"/private/tmp/claude-probe/cwd/note.txt","content":"hello\n"},"caller":{"type":"direct"}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":37844,"cache_read_input_tokens":15329,"output_tokens":20}},"parent_tool_use_id":null,"session_id":"d370472f-cc81-4dbd-ba9b-062e13fe4c62","uuid":"5d6233d7-5e49-41aa-8236-a16305b83d20"}
        """#
    static let writePermission = #"""
        {"type":"control_request","request_id":"8c01462d-ad80-4555-a9e4-1b50e7524438","request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write","input":{"file_path":"/private/tmp/claude-probe/cwd/note.txt","content":"hello\n"},"description":"note.txt","permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],"tool_use_id":"toolu_01CaUWXCpaTwngG18dp2F7vn"}}
        """#
    static let writeResult = #"""
        {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01CaUWXCpaTwngG18dp2F7vn","type":"tool_result","content":"File created successfully at: /private/tmp/claude-probe/cwd/note.txt"}]},"parent_tool_use_id":null,"session_id":"d370472f-cc81-4dbd-ba9b-062e13fe4c62","tool_use_result":{"type":"create","filePath":"/private/tmp/claude-probe/cwd/note.txt","content":"hello\n","structuredPatch":[],"originalFile":null,"userModified":false},"tool_result_meta":[{"id":"toolu_01CaUWXCpaTwngG18dp2F7vn","permission_decision":{"decision":"accept","source":"user_temporary"}}]}
        """#
    static let writeRejected = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.","is_error":true,"tool_use_id":"toolu_01CaUWXCpaTwngG18dp2F7vn"}]},"parent_tool_use_id":null,"session_id":"d370472f-cc81-4dbd-ba9b-062e13fe4c62","tool_use_result":"User rejected tool use","tool_result_meta":[{"id":"toolu_01CaUWXCpaTwngG18dp2F7vn","non_execution_kind":"user-rejected"}]}
        """#
    static let cancelWritePermission = #"{"type":"control_cancel_request","request_id":"8c01462d-ad80-4555-a9e4-1b50e7524438"}"#

    static let interruptedResult = #"""
        {"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","num_turns":2,"errors":["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null"],"session_id":"ae70d927-be86-4823-813d-7af6b918dc91","total_cost_usd":0.0001278,"modelUsage":{"claude-haiku-5-5":{"costUSD":0.0001278,"contextWindow":1000000}}}
        """#

    static let missingConversationResult = #"""
        {"type":"result","subtype":"error_during_execution","duration_ms":0,"is_error":true,"num_turns":0,"stop_reason":null,"session_id":"23ace05f-68cb-41ed-96e9-fc4b637bc343","total_cost_usd":0,"modelUsage":{},"permission_denials":[],"errors":["No conversation found with session ID: 23ace05f-68cb-41ed-96e9-fc4b637bc343"]}
        """#

    /// Summarized thinking followed by the answer.
    static let thinkingTurn = [
        #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-haiku-5-5","id":"msg_011CgSGYiXPHBrzhV5n1JyzY","type":"message","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":37846,"cache_read_input_tokens":15329,"output_tokens":3}}},"parent_tool_use_id":null,"thinking_display":"summarized"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}},"parent_tool_use_id":null,"thinking_display":"summarized"}"#,
        #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":1,"estimated_tokens_delta":1}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The image shown is a sol","estimated_tokens":null}},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"id red square.","estimated_tokens":null}},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"CAQS8wYKEAgTGAI4AUIIdGhpbmtpbmc"}},"parent_tool_use_id":null}"#,
        #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011CgSGYiXPHBrzhV5n1JyzY","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"The image shown is a solid red square.","signature":"CAQS8wYKEAgTGAI4AUIIdGhpbmtpbmc"}]},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Red."}},"parent_tool_use_id":null}"#,
        #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011CgSGYiXPHBrzhV5n1JyzY","type":"message","role":"assistant","content":[{"type":"text","text":"Red."}]},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":1},"parent_tool_use_id":null}"#,
    ]

    static let exitPlanSnapshot = #"""
        {"type":"assistant","message":{"model":"claude-sonnet-5-5","id":"msg_011CgSGVEDxgwrVpPbdHw5Df","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_0193ob6RgN4YiV3GvaZMyYra","name":"ExitPlanMode","input":{"plan":"# Plan: add hello.txt\n\n## Steps\n1. Create `hello.txt` containing `hi`.\n2. Read it back.\n","planFilePath":"/Users/me/.claude/plans/plan-how-you-would-modular-galaxy.md"},"caller":{"type":"direct"}}]},"parent_tool_use_id":null,"session_id":"de8f0fb4-c483-43ec-8c3d-bf7300901c53"}
        """#
    static let exitPlanPermission = #"""
        {"type":"control_request","request_id":"b6663086-074f-400b-8c9a-5f7013dd5b76","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","display_name":"ExitPlanMode","input":{"plan":"# Plan: add hello.txt\n\n## Steps\n1. Create `hello.txt` containing `hi`.\n2. Read it back.\n","planFilePath":"/Users/me/.claude/plans/plan-how-you-would-modular-galaxy.md"},"tool_use_id":"toolu_0193ob6RgN4YiV3GvaZMyYra","requires_user_interaction":true}}
        """#

    static let questionPermission = #"""
        {"type":"control_request","request_id":"5e1f0c2a-7d3b-4c55-9a51-2b3f4e5d6c7a","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","display_name":"AskUserQuestion","input":{"questions":[{"question":"Which database should the app use?","header":"Database","options":[{"label":"SQLite","description":"File-based, no server"},{"label":"Postgres","description":"Full server"}],"multiSelect":false},{"question":"Which checks should run?","header":"Checks","options":[{"label":"Unit tests"},{"label":"Lint"}],"multiSelect":true}]},"tool_use_id":"toolu_01QsAskUserQuestionAbc","requires_user_interaction":true}}
        """#

    static let todoSnapshot = #"""
        {"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_01TodoWrite","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01Todo","name":"TodoWrite","input":{"todos":[{"content":"Read the config loader","status":"completed","activeForm":"Reading the config loader"},{"content":"Fix the parsing bug","status":"in_progress","activeForm":"Fixing the parsing bug"},{"content":"Run the tests","status":"pending","activeForm":"Running the tests"}]}}]},"parent_tool_use_id":null}
        """#

    /// T3's subagent fixture: an Agent call whose subagent reads a file.
    static let agentTurn = [
        #"{"type":"assistant","message":{"model":"claude-sonnet-4-6","id":"msg_01Agent","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_0113VSWTCamvp1adXDZrK5NG","name":"Agent","input":{"description":"Read tsconfig.json","prompt":"Read the file `tsconfig.json` in the current working directory and return its full contents.","subagent_type":"general-purpose"}}]},"parent_tool_use_id":null}"#,
        #"{"type":"system","subtype":"task_started","task_id":"a3d3213ffad1bd057","tool_use_id":"toolu_0113VSWTCamvp1adXDZrK5NG","description":"Read tsconfig.json","task_type":"local_agent","session_id":"64676197-7fbc-467e-aeac-eae812bfce63"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Read the file `tsconfig.json` in the current working directory and return its full contents."}]},"parent_tool_use_id":"toolu_0113VSWTCamvp1adXDZrK5NG"}"#,
        #"{"type":"assistant","message":{"model":"claude-sonnet-4-6","id":"msg_01Sub","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01SubRead","name":"Read","input":{"file_path":"/private/tmp/claude-probe/cwd/tsconfig.json"}}]},"parent_tool_use_id":"toolu_0113VSWTCamvp1adXDZrK5NG"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01SubRead","content":"1\t{\"compilerOptions\":{\"strict\":true}}"}]},"parent_tool_use_id":"toolu_0113VSWTCamvp1adXDZrK5NG"}"#,
        #"{"type":"system","subtype":"task_notification","task_id":"a3d3213ffad1bd057","tool_use_id":"toolu_0113VSWTCamvp1adXDZrK5NG","status":"completed","output_file":"","summary":"Read tsconfig.json"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_0113VSWTCamvp1adXDZrK5NG","content":[{"type":"text","text":"Here are the full contents of `tsconfig.json`."},{"type":"text","text":"agentId: a3d3213ffad1bd057"}]}]},"parent_tool_use_id":null,"tool_use_result":{"status":"completed","agentId":"a3d3213ffad1bd057","agentType":"general-purpose","content":[{"type":"text","text":"Here are the full contents of `tsconfig.json`."}],"totalDurationMs":5186,"totalToolUseCount":1}}"#,
    ]

    static let mcpSnapshot = #"""
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","id":"msg_01Mcp","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01CqVNFCESeShHVUiLMLPsCg","name":"mcp__claude_ai_Firecrawl__firecrawl_scrape","input":{"url":"https://example.com","formats":["markdown"]}}]},"parent_tool_use_id":null,"tool_use_meta":[{"id":"toolu_01CqVNFCESeShHVUiLMLPsCg","display_name":"Firecrawl scrape","server_display_name":"Firecrawl"}]}
        """#

    static let webSearchTurn = [
        #"{"type":"assistant","message":{"model":"claude-sonnet-4-6","id":"msg_01Web","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01WebSearch","name":"WebSearch","input":{"query":"FIFA World Cup 2026 ticket pricing"}}]},"parent_tool_use_id":null}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01WebSearch","type":"tool_result","content":"Web search results for query: \"FIFA World Cup 2026 ticket pricing\""}]},"parent_tool_use_id":null,"tool_use_result":{"query":"FIFA World Cup 2026 ticket pricing","results":[{"tool_use_id":"srvtoolu_01PoQ","content":[{"title":"Tickets - FIFA World Cup 2026","url":"https://www.fifa.com/tickets"},{"title":"Fans slam FIFA's pricing","url":"https://www.foxla.com/news/world-cup"}]},"Summary text"],"durationSeconds":4.2}}"#,
    ]

    static func editSnapshot(path: String) -> String {
        #"{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_01Edit","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01Edit","name":"Edit","input":{"replace_all":false,"file_path":"PATH","old_string":"let b = 2","new_string":"let b = 3"}}]},"parent_tool_use_id":null}"#
            .replacingOccurrences(of: "PATH", with: path)
    }

    static func editResult(path: String) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01Edit","type":"tool_result","content":"The file PATH has been updated successfully."}]},"parent_tool_use_id":null,"tool_use_result":{"filePath":"PATH","oldString":"let b = 2","newString":"let b = 3","originalFile":"let a = 1\nlet b = 2\nlet c = 4\n","structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":3,"lines":[" let a = 1","-let b = 2","+let b = 3"," let c = 4"]}],"userModified":false,"replaceAll":false}}"#
            .replacingOccurrences(of: "PATH", with: path)
    }

    /// The `models` of an `initialize` response from 2.1.308 on a Max plan (abridged).
    static let initializeModels: JSONValue = JSONValue.parse(
        #"""
        [{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","description":"Opus 5.5 · Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true},
         {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5","description":"For complex work and everyday tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},
         {"value":"haiku","resolvedModel":"claude-haiku-5-5","displayName":"Haiku 5.5","description":"Fastest for quick answers","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},
         {"value":"claude-haiku-4-5-20251001","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5","description":"Fastest for quick answers","supportsThinkingOff":true},
         {"value":"claude-opus-4-6","resolvedModel":"claude-opus-4-6","displayName":"Opus 4.6","description":"Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","max"]},
         {"value":"claude-new-7","resolvedModel":"claude-new-7","displayName":"New 7","description":"Not in the catalog","supportsEffort":true,"supportedEffortLevels":["low","high"]}]
        """#)!

    static func controlRequest(_ id: String, _ request: JSONValue) -> String {
        JSONValue.object(["type": "control_request", "request_id": .string(id), "request": request]).compactJSON
    }

    static func lifecycle(_ uuid: String, _ state: String) -> String {
        JSONValue.object(["type": "command_lifecycle", "command_uuid": .string(uuid), "state": .string(state)]).compactJSON
    }
}

private func mapLines(_ lines: [String], into mapper: inout ClaudeEventMapper) -> [AgentEvent] {
    lines.flatMap { line in mapper.map(JSONValue.parse(line)!) }
}

private func testMapper() -> ClaudeEventMapper {
    var mapper = ClaudeEventMapper(workingDirectory: ClaudeFixture.cwd, contextWindow: 1_000_000)
    mapper.fileContents = { _ in nil }
    return mapper
}

// MARK: - Mapper

struct ClaudeMapperTests {
    @Test func streamsTextThenSettlesItWithTheSnapshot() {
        var mapper = testMapper()
        let events = mapLines([ClaudeFixture.initFrame] + ClaudeFixture.pongTurn + [ClaudeFixture.pongResult], into: &mapper)
        let item = "msg_011CgSG2mzQXcubAcqMv7eaV:text:0"
        let text = events.filter {
            switch $0 {
            case .assistantTextDelta, .assistantText: true
            default: false
            }
        }
        #expect(
            text == [
                .assistantTextDelta(itemID: item, delta: "p"), .assistantTextDelta(itemID: item, delta: "ong"),
                .assistantText(itemID: item, text: "pong"),
            ])
        #expect(events.first == .modelResolved("claude-haiku-5-5"))
        #expect(mapper.sessionID == "29718ecd-ee07-4e0c-9590-9666442ec28f")
        #expect(mapper.capabilities.contains("msg_lifecycle_v1"))
    }

    @Test func reportsContextUsageAndTurnCost() {
        var mapper = testMapper()
        let usage = mapLines(ClaudeFixture.pongTurn + [ClaudeFixture.pongResult], into: &mapper).compactMap { event -> TokenUsage? in
            if case .usage(let value) = event { return value }
            return nil
        }
        #expect(usage.first == TokenUsage(inputTokens: 53_132, outputTokens: 1, cachedInputTokens: 12_702, contextWindow: 1_000_000))
        #expect(usage.dropFirst().first?.outputTokens == 4)
        #expect(usage.last == TokenUsage(contextWindow: 1_000_000, costUSD: 0.00833972))
    }

    @Test func costKeepsCountingAcrossProcessRestarts() {
        var mapper = testMapper()
        _ = mapLines([ClaudeFixture.pongResult], into: &mapper)
        mapper.processRestarted()
        let events = mapLines([ClaudeFixture.pongResult], into: &mapper)
        #expect(events.last == .usage(TokenUsage(contextWindow: 1_000_000, costUSD: 2 * 0.00833972)))
    }

    @Test func commandAndFileToolsStartRefineAndComplete() {
        var mapper = testMapper()
        let events = mapLines(
            [
                ClaudeFixture.messageStart, ClaudeFixture.bashStart, ClaudeFixture.bashSnapshot, ClaudeFixture.writeStart,
                ClaudeFixture.bashResult, ClaudeFixture.writeInputDelta, ClaudeFixture.writeSnapshot, ClaudeFixture.writeResult,
            ], into: &mapper
        ).filter {
            if case .usage = $0 { return false }
            if case .modelResolved = $0 { return false }
            return true
        }
        let bash = "toolu_017UX8e11oohShjRZSvwtYyW"
        let write = "toolu_01CaUWXCpaTwngG18dp2F7vn"
        let creation = "--- /dev/null\n+++ note.txt\n@@ -0,0 +1,1 @@\n+hello"
        #expect(
            events == [
                .toolStarted(ToolCallInfo(id: bash, category: .command, title: "Run command")),
                .toolUpdated(ToolCallInfo(id: bash, category: .command, title: "Run `echo coincide-ok`", detail: "echo coincide-ok")),
                .toolStarted(ToolCallInfo(id: write, category: .fileChange, title: "Write file")),
                .toolCompleted(id: bash, status: .completed, output: "coincide-ok"),
                .toolUpdated(ToolCallInfo(id: write, category: .fileChange, title: "Write note.txt")),
                .toolUpdated(ToolCallInfo(id: write, category: .fileChange, title: "Write note.txt", detail: creation)),
                .toolCompleted(id: write, status: .completed, output: "File created successfully at: /private/tmp/claude-probe/cwd/note.txt"),
            ])
    }

    @Test func rejectedToolIsDeclined() {
        var mapper = testMapper()
        let events = mapLines([ClaudeFixture.writeSnapshot, ClaudeFixture.writeRejected], into: &mapper)
        guard case .toolCompleted(_, let status, let output)? = events.last else {
            Issue.record("expected a completed tool")
            return
        }
        #expect(status == .declined)
        #expect(output?.hasPrefix("The user doesn't want to proceed") == true)
    }

    @Test func failedCommandKeepsTheExitCode() {
        var mapper = testMapper()
        let start = #"{"type":"assistant","message":{"id":"msg_x","content":[{"type":"tool_use","id":"toolu_fail","name":"Bash","input":{"command":"swift test"}}]},"parent_tool_use_id":null}"#
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_fail","content":"Exit code 1\nerror: no tests found","is_error":true}]},"parent_tool_use_id":null,"tool_use_result":{"stdout":"","stderr":"error: no tests found","interrupted":false}}"#
        let events = mapLines([start, result], into: &mapper)
        #expect(events.last == .toolCompleted(id: "toolu_fail", status: .failed, output: "Exit code 1\nerror: no tests found"))
    }

    @Test func editDiffUsesFileLineNumbersThenTheExactPatch() {
        var mapper = testMapper()
        let path = ClaudeFixture.cwd + "/Sources/Math.swift"
        mapper.fileContents = { $0 == path ? "let a = 1\nlet b = 2\nlet c = 4\n" : nil }
        let events = mapLines([ClaudeFixture.editSnapshot(path: path), ClaudeFixture.editResult(path: path)], into: &mapper)
            .filter { if case .modelResolved = $0 { false } else { true } }
        #expect(
            events.first
                == .toolStarted(
                    ToolCallInfo(
                        id: "toolu_01Edit", category: .fileChange, title: "Edit Sources/Math.swift",
                        detail: "--- Sources/Math.swift\n+++ Sources/Math.swift\n@@ -2,1 +2,1 @@\n-let b = 2\n+let b = 3")))
        #expect(
            events.dropFirst().first
                == .toolUpdated(
                    ToolCallInfo(
                        id: "toolu_01Edit", category: .fileChange, title: "Edit Sources/Math.swift",
                        detail: "--- Sources/Math.swift\n+++ Sources/Math.swift\n@@ -1,3 +1,3 @@\n let a = 1\n-let b = 2\n+let b = 3\n let c = 4")))
        guard case .toolCompleted(_, .completed, _)? = events.last else {
            Issue.record("expected the edit to complete")
            return
        }
    }

    @Test func thinkingStreamsAsReasoning() {
        var mapper = testMapper()
        let events = mapLines(ClaudeFixture.thinkingTurn, into: &mapper).filter {
            if case .usage = $0 { return false }
            if case .modelResolved = $0 { return false }
            return true
        }
        let thinking = "msg_011CgSGYiXPHBrzhV5n1JyzY:thinking:0"
        let text = "msg_011CgSGYiXPHBrzhV5n1JyzY:text:0"
        #expect(
            events == [
                .reasoningDelta(itemID: thinking, delta: "The image shown is a sol"),
                .reasoningDelta(itemID: thinking, delta: "id red square."),
                .reasoningText(itemID: thinking, text: "The image shown is a solid red square."),
                .assistantTextDelta(itemID: text, delta: "Red."),
                .assistantText(itemID: text, text: "Red."),
            ])
    }

    @Test func secondThinkingBlockBeforeAToolIsAlsoShownAsAnUpdate() {
        var mapper = testMapper()
        let frames = [
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_u","content":[{"type":"thinking","thinking":"Planning the fix."}]},"parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_u","content":[{"type":"thinking","thinking":"I'll run the tests first."}]},"parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_u","content":[{"type":"tool_use","id":"toolu_t","name":"Bash","input":{"command":"swift test"}}]},"parent_tool_use_id":null}"#,
        ]
        let events = mapLines(frames, into: &mapper)
        #expect(events.contains(.assistantText(itemID: "msg_u:thinking:1:update", text: "I'll run the tests first.")))
        #expect(!events.contains(.assistantText(itemID: "msg_u:thinking:0:update", text: "Planning the fix.")))
        #expect(ClaudeEventMapper.writesUpdatesAsThinking("claude-fable-5-1"))
        #expect(!ClaudeEventMapper.writesUpdatesAsThinking("claude-opus-4-8"))
        #expect(!ClaudeEventMapper.writesUpdatesAsThinking("claude-opus-5"))
    }

    @Test func todoWriteBecomesThePlan() {
        var mapper = testMapper()
        let events = mapLines([ClaudeFixture.todoSnapshot], into: &mapper)
        #expect(events.last == .plan(text: "- [x] Read the config loader\n- [ ] **Fix the parsing bug**\n- [ ] Run the tests"))
        #expect(!events.contains { if case .toolStarted = $0 { return true } else { return false } })
    }

    @Test func taskToolsMaintainThePlan() {
        var mapper = testMapper()
        let frames = [
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"TaskCreate","input":{"subject":"Write the parser"}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Task #1 created successfully: Write the parser"}]},"parent_tool_use_id":null,"tool_use_result":{"task":{"id":"1","subject":"Write the parser"}}}"#,
            #"{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"TaskCreate","input":{"subject":"Add tests"}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"Task #2 created successfully: Add tests"}]},"parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"t3","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"Updated task #1 status"}]},"parent_tool_use_id":null,"tool_use_result":{"success":true,"taskId":"1"}}"#,
        ]
        let plans = mapLines(frames, into: &mapper).compactMap { event -> String? in
            if case .plan(let text) = event { return text }
            return nil
        }
        #expect(plans == ["- [ ] Write the parser", "- [ ] Write the parser\n- [ ] Add tests", "- [x] Write the parser\n- [ ] Add tests"])
    }

    @Test func subagentWorkShowsOnTheAgentItem() {
        var mapper = testMapper()
        let events = mapLines(ClaudeFixture.agentTurn, into: &mapper)
        let agent = "toolu_0113VSWTCamvp1adXDZrK5NG"
        #expect(
            events == [
                .modelResolved("claude-sonnet-4-6"),
                .toolStarted(
                    ToolCallInfo(
                        id: agent, category: .task, title: "Agent: Read tsconfig.json",
                        detail: "Read the file `tsconfig.json` in the current working directory and return its full contents.")),
                .toolOutput(id: agent, delta: "→ Read tsconfig.json\n"),
                .toolCompleted(id: agent, status: .completed, output: "Here are the full contents of `tsconfig.json`."),
            ])
    }

    @Test func mcpToolsUseTheirServerAndToolNames() {
        var mapper = testMapper()
        let events = mapLines([ClaudeFixture.mcpSnapshot], into: &mapper)
        guard case .toolStarted(let info)? = events.last else {
            Issue.record("expected an MCP tool")
            return
        }
        #expect(info.category == .mcp)
        #expect(info.title == "Firecrawl: Firecrawl scrape")
        #expect(info.detail?.contains("\"url\" : \"https://example.com\"") == true)
        let parts = ClaudeTools.mcpParts("mcp__plugin_github_github__create_issue")
        #expect(parts.server == "github" && parts.tool == "create_issue")
    }

    @Test func webSearchListsItsResults() {
        var mapper = testMapper()
        let events = mapLines(ClaudeFixture.webSearchTurn, into: &mapper)
        #expect(
            events.last
                == .toolCompleted(
                    id: "toolu_01WebSearch", status: .completed,
                    output: "- [Tickets - FIFA World Cup 2026](https://www.fifa.com/tickets)\n- [Fans slam FIFA's pricing](https://www.foxla.com/news/world-cup)"))
    }

    @Test func apiErrorsAreNotReplies() {
        var mapper = testMapper()
        let frame = #"{"type":"assistant","message":{"model":"<synthetic>","id":"msg_err","content":[{"type":"text","text":"Invalid API key · Please run /login"}]},"parent_tool_use_id":null,"error":"authentication_failed"}"#
        #expect(mapLines([frame], into: &mapper).isEmpty)
        #expect(mapper.assistantError == ClaudeEventMapper.AssistantError(kind: "authentication_failed", text: "Invalid API key · Please run /login"))
        mapper.beginTurn()
        #expect(mapper.assistantError == nil)
    }

    @Test func systemFramesBecomeNotices() {
        var mapper = testMapper()
        let frames = [
            #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":180000}}"#,
            #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":1000,"error_status":529,"error":"overloaded"}"#,
            #"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":2000,"error_status":529,"error":"overloaded"}"#,
            #"{"type":"system","subtype":"informational","content":"\u001b[33mUserPromptSubmit hook blocked the prompt\u001b[0m","level":"warning"}"#,
            #"{"type":"system","subtype":"informational","content":"debug only","level":"info"}"#,
            #"{"type":"system","subtype":"local_command_output","content":"Total cost: $0.01","uuid":"cmd-1"}"#,
            #"{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}"#,
        ]
        let events = mapLines(frames, into: &mapper)
        #expect(
            events == [
                .notice("Context compacted"), .notice("Claude API overloaded; retrying…"),
                .notice("UserPromptSubmit hook blocked the prompt"), .assistantText(itemID: "cmd-1", text: "Total cost: $0.01"),
            ])
    }

    @Test func ignoresSubagentStreamsAndPlumbingTools() {
        var mapper = testMapper()
        let frames = [
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_sub","usage":{"input_tokens":5,"output_tokens":1}}},"parent_tool_use_id":"toolu_agent"}"#,
            #"{"type":"assistant","message":{"id":"msg_ts","content":[{"type":"tool_use","id":"toolu_ts","name":"ToolSearch","input":{"query":"select:ExitPlanMode","max_results":1}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_ts","content":[{"type":"tool_reference","tool_name":"ExitPlanMode"}]}]},"parent_tool_use_id":null}"#,
        ]
        #expect(mapLines(frames, into: &mapper).isEmpty)
    }

    @Test func longToolInputsAreNotCollected() {
        var mapper = testMapper()
        _ = mapLines([ClaudeFixture.messageStart, ClaudeFixture.writeStart], into: &mapper)
        let opening = #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"content\": \""}},"parent_tool_use_id":null}"#
        _ = mapLines([opening], into: &mapper)
        let chunk = String(repeating: "x", count: 200)
        let delta = JSONValue.parse(
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\#(chunk)"}},"parent_tool_use_id":null}"#)!
        // A 4 MB Write streams in thousands of deltas; collecting them all would take quadratic time.
        let elapsed = ContinuousClock().measure {
            for _ in 0..<20_000 { _ = mapper.map(delta) }
        }
        #expect(elapsed < .seconds(2))
        let events = mapLines([ClaudeFixture.writeSnapshot], into: &mapper)
        #expect(events.contains { if case .toolUpdated(let info) = $0 { info.title == "Write note.txt" } else { false } })
    }

    @Test func costKeepsCountingWhenClaudesTotalStartsOver() {
        var mapper = testMapper()
        func result(_ cost: String) -> String {
            ClaudeFixture.pongResult.replacingOccurrences(of: #""total_cost_usd":0.00833972"#, with: #""total_cost_usd":"# + cost)
        }
        let first = 0.00833972
        _ = mapLines([ClaudeFixture.pongResult], into: &mapper)
        // A zeroed total (a crashed turn) is ignored; a smaller one started over; /clear starts over too.
        #expect(mapLines([result("0")], into: &mapper).last == .usage(TokenUsage(contextWindow: 1_000_000, costUSD: first)))
        #expect(mapLines([result("0.001")], into: &mapper).last == .usage(TokenUsage(contextWindow: 1_000_000, costUSD: first + 0.001)))
        let reset = #"{"type":"conversation_reset","new_conversation_id":"7d3c2b1a-0000-4000-8000-000000000002","uuid":"u","session_id":"s"}"#
        #expect(
            mapLines([reset, result("0.002")], into: &mapper).last
                == .usage(TokenUsage(contextWindow: 1_000_000, costUSD: first + 0.001 + 0.002)))
    }

    @Test func tracksPermissionModeAndBackgroundWork() {
        var mapper = testMapper()
        _ = mapLines(
            [
                ClaudeFixture.initFrame, #"{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}"#,
                #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1","task_type":"local_bash","description":"npm run dev"},{"task_id":"m1","task_type":"monitor","description":"watch","ambient":true}]}"#,
            ], into: &mapper)
        #expect(mapper.permissionMode == "acceptEdits")
        #expect(mapper.backgroundTasks == ["b1": "npm run dev"])
        mapper.processRestarted()
        #expect(mapper.permissionMode == nil && mapper.backgroundTasks.isEmpty)
    }

    @Test func partialInputTitlesAToolEarly() {
        #expect(
            ClaudeTools.partialStringField("file_path", in: #"{"file_path": "/tmp/a \"b\".txt", "conte"#) == "/tmp/a \"b\".txt")
        #expect(ClaudeTools.partialStringField("file_path", in: #"{"file_path": "/tmp/unfinished"#) == nil)
        #expect(ClaudeTools.partialStringField("command", in: #"{"description":"x","command" : "ls -la""#) == "ls -la")
    }
}

// MARK: - Outcomes

struct ClaudeOutcomeTests {
    private func outcome(_ json: String, interrupt: Bool = false, error: ClaudeEventMapper.AssistantError? = nil) -> TurnOutcome {
        ClaudeEventMapper.outcome(of: JSONValue.parse(json)!, interruptRequested: interrupt, assistantError: error)
    }

    @Test func successCompletes() {
        #expect(outcome(ClaudeFixture.pongResult) == .completed)
    }

    @Test func abortsAndRequestedInterruptsAreInterrupted() {
        #expect(outcome(ClaudeFixture.interruptedResult) == .interrupted)
        #expect(outcome(ClaudeFixture.pongResult, interrupt: true) == .interrupted)
        #expect(outcome(#"{"type":"result","subtype":"error_during_execution","errors":["Request was interrupted"]}"#) == .interrupted)
    }

    @Test func apiFailuresExplainThemselves() {
        #expect(
            outcome(#"{"type":"result","subtype":"success","is_error":true,"api_error_status":529,"result":"API Error"}"#)
                == .failed("The Claude API is overloaded (529). Try again shortly."))
        #expect(
            outcome(#"{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","result":"API Error: 500 Internal server error"}"#)
                == .failed("API Error: 500 Internal server error"))
        #expect(
            outcome(#"{"type":"result","subtype":"success","is_error":false,"terminal_reason":"prompt_too_long","result":""}"#)
                == .failed("Claude stopped: the prompt exceeds the model's context window. Run /compact or start a new thread."))
        #expect(
            outcome(#"{"type":"result","subtype":"error_max_turns","errors":[]}"#)
                == .failed("Claude stopped after reaching the maximum number of turns."))
    }

    @Test func signedOutTurnsSayHowToSignIn() {
        let error = ClaudeEventMapper.AssistantError(kind: "authentication_failed", text: "Invalid API key · Please run /login")
        #expect(
            outcome(#"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}"#, error: error)
                == .failed("Claude Code is not signed in. Run `claude auth login` in Terminal, then try again."))
    }

    @Test func errorResultsUseTheirListedError() {
        #expect(outcome(ClaudeFixture.missingConversationResult) == .failed("No conversation found with session ID: 23ace05f-68cb-41ed-96e9-fc4b637bc343"))
    }

    @Test func usageLimitsKeepClaudesOwnExplanation() {
        let limit = ClaudeEventMapper.AssistantError(kind: "rate_limit", text: "You've hit your limit · resets 5pm (Asia/Kolkata)")
        #expect(
            outcome(
                #"{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","result":"You've hit your limit · resets 5pm (Asia/Kolkata)"}"#,
                error: limit) == .failed("You've hit your limit · resets 5pm (Asia/Kolkata)"))
        #expect(
            outcome(#"{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"x"}"#, error: limit)
                == .failed("You've hit your limit · resets 5pm (Asia/Kolkata)"))
        // A 403 is labelled authentication_failed, but signing in again would not help.
        let forbidden = ClaudeEventMapper.AssistantError(kind: "authentication_failed", text: "API Error: 403 Claude Code is disabled for this organization")
        #expect(
            outcome(
                #"{"type":"result","subtype":"success","is_error":true,"api_error_status":403,"result":"API Error: 403 Claude Code is disabled for this organization"}"#,
                error: forbidden) == .failed("API Error: 403 Claude Code is disabled for this organization"))
    }

    @Test func onlyCleanSuccessesCarryAReply() {
        #expect(ClaudeEventMapper.replyText(of: JSONValue.parse(ClaudeFixture.pongResult)!) == "pong")
        #expect(ClaudeEventMapper.replyText(of: JSONValue.parse(ClaudeFixture.interruptedResult)!) == nil)
        #expect(
            ClaudeEventMapper.replyText(
                of: JSONValue.parse(#"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 500"}"#)!) == nil)
        #expect(
            ClaudeEventMapper.replyText(
                of: JSONValue.parse(#"{"type":"result","subtype":"success","is_error":false,"terminal_reason":"prompt_too_long","result":"x"}"#)!)
                == nil)
    }
}

// MARK: - Models

struct ClaudeCatalogTests {
    @Test func discoveredModelsCarryT3Options() throws {
        let models = ClaudeModelCatalog.models(fromInitialize: try #require(ClaudeFixture.initializeModels.array))
        #expect(models.map(\.modelID) == ["default", "opus", "haiku", "claude-haiku-4-5-20251001", "claude-opus-4-6", "claude-new-7"])
        #expect(models[0].displayName == "Default (Opus 5.5)")
        #expect(models[0].efforts == ["low", "medium", "high", "xhigh", "max", "ultracode", "ultrathink"])
        #expect(models[0].defaultEffort == "medium")
        #expect(models[0].contextWindow == 1_000_000)
        #expect(models[2].efforts == ["low", "medium", "high", "xhigh", "max", "ultrathink"])
        #expect(models[3].efforts.isEmpty && models[3].contextWindow == 200_000)
        #expect(models[4].efforts == ["low", "medium", "high", "max", "ultrathink"])
        #expect(models[5].efforts == ["low", "high"] && models[5].defaultEffort == nil && models[5].contextWindow == nil)
        #expect(models.allSatisfy { $0.provider == .claude && $0.supportsImages })
    }

    @Test func fallbackListFollowsTheInstalledVersion() {
        let current = ClaudeModelCatalog.fallbackModels(version: "2.1.308").map(\.modelID)
        #expect(current.prefix(5) == ["default", "opus", "sonnet", "fable", "haiku"])
        #expect(current.contains("claude-opus-4-7"))
        let old = ClaudeModelCatalog.fallbackModels(version: "2.1.260").map(\.modelID)
        #expect(old.contains("fable") && !old.contains("opus") && !old.contains("haiku"))
        #expect(
            ClaudeModelCatalog.upgradeMessage(version: "2.1.260")
                == "Claude Code v2.1.260 is too old for Opus 5.5. Upgrade to v2.1.280 or newer to use it.")
        #expect(ClaudeModelCatalog.upgradeMessage(version: "2.1.308") == nil)
    }

    @Test func effortsResolveLikeT3() {
        typealias Plan = ClaudeModelCatalog.EffortPlan
        #expect(ClaudeModelCatalog.effortPlan(modelID: "opus", resolvedModel: nil, effort: nil) == Plan(cliEffort: "medium"))
        #expect(ClaudeModelCatalog.effortPlan(modelID: "opus", resolvedModel: nil, effort: "ultracode") == Plan(cliEffort: "xhigh", ultracode: true))
        #expect(ClaudeModelCatalog.effortPlan(modelID: "sonnet", resolvedModel: nil, effort: "ultrathink") == Plan(ultrathink: true))
        #expect(ClaudeModelCatalog.effortPlan(modelID: "claude-opus-4-7", resolvedModel: nil, effort: "xhigh") == Plan(cliEffort: "max"))
        #expect(ClaudeModelCatalog.effortPlan(modelID: "claude-sonnet-4-6", resolvedModel: nil, effort: "max") == Plan(cliEffort: "high"))
        #expect(ClaudeModelCatalog.effortPlan(modelID: "default", resolvedModel: "claude-opus-5-5", effort: "bogus") == Plan(cliEffort: "medium"))
        #expect(ClaudeModelCatalog.effortPlan(modelID: "default", resolvedModel: nil, effort: "high") == Plan(cliEffort: "high"))
        #expect(ClaudeModelCatalog.effortPlan(modelID: "claude-haiku-4-5", resolvedModel: nil, effort: "high") == Plan())
    }

    @Test func launchModelsFollowAliasesAndContextSuffixes() {
        #expect(ClaudeModelCatalog.launchModel(for: "default") == nil)
        #expect(ClaudeModelCatalog.launchModel(for: "opus") == "opus")
        #expect(ClaudeModelCatalog.launchModel(for: "claude-opus-4-6") == "claude-opus-4-6[1m]")
        #expect(ClaudeModelCatalog.launchModel(for: "claude-sonnet-4-6[1m]") == "claude-sonnet-4-6[1m]")
        #expect(ClaudeModelCatalog.launchModel(for: "claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(ClaudeModelCatalog.launchModel(for: "my-custom-model") == "my-custom-model")
        #expect(ClaudeModelCatalog.contextWindow(modelID: "claude-sonnet-4-6[1m]", resolvedModel: nil) == 1_000_000)
    }

    @Test func ultrathinkPrefixesPromptsButNotSlashCommands() {
        #expect(ClaudeModelCatalog.applyUltrathink(to: "fix the bug") == "Ultrathink:\nfix the bug")
        #expect(ClaudeModelCatalog.applyUltrathink(to: "/compact keep errors") == "/compact keep errors")
        #expect(ClaudeModelCatalog.applyUltrathink(to: "Ultrathink:\nalready") == "Ultrathink:\nalready")
    }

    @Test func versions() {
        #expect(ClaudeModelCatalog.parseVersion("2.1.308 (Claude Code)\n") == "2.1.308")
        #expect(ClaudeModelCatalog.compareVersions("2.1.308", "2.1.280") == 1)
        #expect(ClaudeModelCatalog.compareVersions("2.1.9", "2.1.10") == -1)
        #expect(ClaudeModelCatalog.compareVersions("2.1", "2.1.0") == 0)
    }
}

// MARK: - Sign-in

struct ClaudeAuthTests {
    @Test func parsesAuthStatus() {
        let json = JSONValue.parse(
            #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"user@example.com","orgId":"7c4a","orgName":"Org","subscriptionType":"max"}"#)!
        #expect(ClaudeAuth.parseStatus(json) == ClaudeAuth.Status(loggedIn: true, account: "user@example.com (Max)"))
        let signedOut = JSONValue.parse(#"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#)!
        #expect(ClaudeAuth.parseStatus(signedOut)?.loggedIn == false)
        let key = JSONValue.parse(#"{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","apiKeySource":"ANTHROPIC_API_KEY"}"#)!
        #expect(ClaudeAuth.parseStatus(key)?.account == "API key")
        let bedrock = JSONValue.parse(#"{"loggedIn":true,"authMethod":"third_party","apiProvider":"bedrock"}"#)!
        #expect(ClaudeAuth.parseStatus(bedrock)?.account == "Amazon Bedrock")
        #expect(ClaudeAuth.parseStatus(JSONValue.parse(#"{"error":"unknown command"}"#)!) == nil)
    }

    @Test func readsTheInitializeAccountLikeT3() {
        let account = JSONValue.parse(#"{"email":"user@example.com","organization":"Org","subscriptionType":"Claude Max","apiProvider":"firstParty"}"#)!
        #expect(ClaudeAuth.status(fromAccount: account) == ClaudeAuth.Status(loggedIn: true, account: "user@example.com (Max)"))
        #expect(ClaudeAuth.status(fromAccount: JSONValue.parse(#"{"tokenSource":"none","apiKeySource":"none"}"#)!).loggedIn == false)
        #expect(ClaudeAuth.status(fromAccount: JSONValue.parse(#"{"apiProvider":"vertex"}"#)!).loggedIn)
    }

    @Test func labelsPlans() {
        #expect(ClaudeAuth.subscriptionLabel("claude_max_20x_subscription") == "Max 20x")
        #expect(ClaudeAuth.subscriptionLabel("pro") == "Pro")
        #expect(ClaudeAuth.subscriptionLabel("enterprise_plus") == "Enterprise Plus")
        #expect(ClaudeAuth.subscriptionLabel("") == nil)
    }

    @Test func customEndpointsCountAsSignedIn() {
        #expect(ClaudeAuth.usesCustomEndpoint(["ANTHROPIC_BASE_URL": "https://gateway.example.com/v1"]))
        #expect(!ClaudeAuth.usesCustomEndpoint(["ANTHROPIC_BASE_URL": "https://api.anthropic.com"]))
        #expect(!ClaudeAuth.usesCustomEndpoint([:]))
    }

    @Test func probeKeepsHooksAndMCPServersOff() {
        let arguments = ClaudeCapabilitiesProbe.arguments(managedMCPConfig: false)
        #expect(arguments.contains("--no-session-persistence") && arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains(#"{"disableAllHooks":true}"#))
        #expect(!ClaudeCapabilitiesProbe.arguments(managedMCPConfig: true).contains("--strict-mcp-config"))
    }
}

// MARK: - Permissions and presentation

struct ClaudePermissionTests {
    private let request = JSONValue.parse(ClaudeFixture.writePermission)!["request"]!

    @Test func approvalsDescribeTheTool() {
        let approval = ClaudePermissions.approval(
            requestID: "8c01462d-ad80-4555-a9e4-1b50e7524438", request: request, workingDirectory: ClaudeFixture.cwd,
            fileContents: { _ in nil })
        #expect(approval.title == "Write note.txt")
        #expect(approval.category == .fileChange)
        #expect(approval.detail == "--- /dev/null\n+++ note.txt\n@@ -0,0 +1,1 @@\n+hello")
        #expect(approval.toolCallID == "toolu_01CaUWXCpaTwngG18dp2F7vn")
        #expect(approval.options.map(\.kind) == [.allowOnce, .allowAlways, .deny, .cancel])
        #expect(approval.textInput?.placeholder == "Tell Claude what to do instead (optional)")

        var narrow = request
        if case .object(var object) = narrow {
            object["suppress_always_allow_rule"] = true
            object["decision_reason"] = "\u{1B}[1mThis command writes outside the project\u{1B}[0m"
            narrow = .object(object)
        }
        let restricted = ClaudePermissions.approval(requestID: "r", request: narrow, workingDirectory: ClaudeFixture.cwd, fileContents: { _ in nil })
        #expect(!restricted.options.contains { $0.kind == .allowAlways })
        #expect(restricted.detail?.hasPrefix("This command writes outside the project\n\n") == true)

        var blocked = request
        if case .object(var object) = blocked {
            object["blocked_path"] = .string(ClaudeFixture.cwd + "/note.txt")
            blocked = .object(object)
        }
        let pathAsk = ClaudePermissions.approval(requestID: "b", request: blocked, workingDirectory: ClaudeFixture.cwd, fileContents: { _ in nil })
        #expect(pathAsk.detail?.hasPrefix("Needs access to note.txt\n\n") == true)
    }

    @Test func answersFollowT3() {
        let allow = ClaudePermissions.response(optionID: ClaudePermissions.allowID, request: request)
        #expect(allow["behavior"] == "allow")
        #expect(allow["updatedInput"] == request["input"])
        #expect(allow["toolUseID"] == "toolu_01CaUWXCpaTwngG18dp2F7vn")
        #expect(allow["updatedPermissions"] == nil)

        let session = ClaudePermissions.response(optionID: ClaudePermissions.allowForSessionID, request: request)
        #expect(session["updatedPermissions"] == [["type": "setMode", "mode": "acceptEdits", "destination": "session"]])

        let deny = ClaudePermissions.response(optionID: ClaudePermissions.denyID, request: request)
        #expect(deny["behavior"] == "deny" && deny["interrupt"] == nil)
        #expect(deny["message"] == "User declined tool execution.")
        let stop = ClaudePermissions.response(optionID: ClaudePermissions.stopID, request: request)
        #expect(stop["behavior"] == "deny" && stop["interrupt"] == true)

        let bash: JSONValue = ["tool_name": "Bash", "input": ["command": "make"], "tool_use_id": "toolu_b"]
        #expect(
            ClaudePermissions.response(optionID: ClaudePermissions.allowForSessionID, request: bash)["updatedPermissions"]
                == [["type": "addRules", "rules": [["toolName": "Bash"]], "behavior": "allow", "destination": "session"]])
    }

    @Test func feedbackIsWhatClaudeReadsWhenDenied() {
        let deny = ClaudePermissions.response(optionID: ClaudePermissions.denyID, request: request, feedback: "  Put it in docs/ instead \n")
        // Framed as Claude Code frames a rejection note, so Claude reads it as the user's words, not tool output.
        #expect(deny["message"]?.string == ClaudePermissions.rejectionNotePrefix + "Put it in docs/ instead")
        #expect(ClaudePermissions.rejectionNotePrefix.hasSuffix("To tell you how to proceed, the user said:\n"))
        let blank = ClaudePermissions.response(optionID: ClaudePermissions.stopID, request: request, feedback: "  ")
        #expect(blank["message"] == "User cancelled tool execution.")
        let allow = ClaudePermissions.response(optionID: ClaudePermissions.allowID, request: request, feedback: "ignored")
        #expect(allow["message"] == nil)

        let plan = JSONValue.parse(ClaudeFixture.exitPlanPermission)!["request"]!
        #expect(ClaudePermissions.planResponse(optionID: ClaudePermissions.allowID, request: plan, feedback: nil)["behavior"] == "allow")
        #expect(
            ClaudePermissions.planResponse(optionID: ClaudePermissions.denyID, request: plan, feedback: "Add tests")["message"]?.string
                == ClaudePermissions.rejectionNotePrefix + "Add tests")
        #expect(ClaudePermissions.planApproval(requestID: "p", request: plan).textInput?.isMultiline == true)
    }

    @Test func questionsBecomeAUserInputRequest() throws {
        let request = try #require(JSONValue.parse(ClaudeFixture.questionPermission)?["request"])
        let input = try #require(ClaudePermissions.userInput(requestID: "q", input: request["input"]!))
        #expect(input.id == "q")
        #expect(input.title == "Claude Code has 2 questions")
        #expect(
            input.questions == [
                UserQuestion(
                    id: "Which database should the app use?", header: "Database", prompt: "Which database should the app use?",
                    options: [.init(label: "SQLite", detail: "File-based, no server"), .init(label: "Postgres", detail: "Full server")]),
                UserQuestion(
                    id: "Which checks should run?", header: "Checks", prompt: "Which checks should run?",
                    options: [.init(label: "Unit tests"), .init(label: "Lint")], allowsMultipleSelection: true),
            ])
        #expect(ClaudePermissions.userInput(requestID: "q", input: ["questions": [["question": "  "]]]) == nil)
    }

    @Test func answersGoBackKeyedByQuestion() throws {
        let request = try #require(JSONValue.parse(ClaudeFixture.questionPermission)?["request"])
        let answered = ClaudePermissions.answersResponse(
            request,
            answers: ["Which database should the app use?": ["Use DuckDB instead"], "Which checks should run?": ["Unit tests", " Lint ", ""]])
        #expect(answered["behavior"] == "allow")
        #expect(answered["toolUseID"] == "toolu_01QsAskUserQuestionAbc")
        #expect(answered.at("updatedInput.questions") == request.at("input.questions"))
        #expect(
            answered.at("updatedInput.answers")
                == ["Which database should the app use?": "Use DuckDB instead", "Which checks should run?": "Unit tests, Lint"])

        let dismissed = ClaudePermissions.answersResponse(request, answers: [:])
        #expect(dismissed["behavior"] == "deny")
        #expect(dismissed["message"] == "The user dismissed the questions without answering.")
        #expect(ClaudePermissions.answersResponse(request, answers: ["Which checks should run?": [" "]])["behavior"] == "deny")
    }

    @Test func alwaysAllowNeverSkipsMoreThanEdits() {
        let request: JSONValue = [
            "tool_name": "Bash", "input": ["command": "make"], "tool_use_id": "toolu_b",
            "permission_suggestions": [
                ["type": "setMode", "mode": "bypassPermissions", "destination": "session"],
                ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "make:*"]], "behavior": "allow", "destination": "localSettings"],
            ],
        ]
        #expect(
            ClaudePermissions.response(optionID: ClaudePermissions.allowForSessionID, request: request)["updatedPermissions"]
                == [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "make:*"]], "behavior": "allow", "destination": "session"]])
        let autoOnly: JSONValue = [
            "tool_name": "Bash", "input": [:], "tool_use_id": "toolu_b",
            "permission_suggestions": [["type": "setMode", "mode": "auto", "destination": "session"]],
        ]
        #expect(
            ClaudePermissions.response(optionID: ClaudePermissions.allowForSessionID, request: autoOnly)["updatedPermissions"]
                == [["type": "addRules", "rules": [["toolName": "Bash"]], "behavior": "allow", "destination": "session"]])
    }

    @Test func elicitationFormsBecomeQuestions() throws {
        let request = try #require(
            JSONValue.parse(
                #"""
                {"subtype":"elicitation","mcp_server_name":"github","message":"Create the issue?","requested_schema":{"type":"object","properties":{"title":{"type":"string","title":"Title","description":"Issue title"},"priority":{"type":"string","enum":["p1","p2"],"enumNames":["Urgent","Normal"]},"count":{"type":"integer","title":"Count"},"notify":{"type":"boolean","title":"Notify"},"labels":{"type":"array","items":{"anyOf":[{"const":"bug","title":"Bug"},{"const":"ui","title":"UI"}]}}},"required":["title","priority"]}}
                """#))
        let input = try #require(ClaudePermissions.elicitation(requestID: "e1", request: request))
        #expect(input.id == "e1" && input.title == "Create the issue?")
        #expect(input.questions.map(\.id) == ["title", "priority", "count", "labels", "notify"])
        #expect(input.questions[0] == UserQuestion(id: "title", header: "Title", prompt: "Issue title"))
        #expect(input.questions[1].options.map(\.label) == ["Urgent", "Normal"] && !input.questions[1].allowsFreeText)
        #expect(input.questions[3].allowsMultipleSelection && input.questions[3].options.map(\.label) == ["Bug", "UI"])
        #expect(input.questions[4].options.map(\.label) == ["Yes", "No"])

        let answers = ["title": [" Crash on launch "], "priority": ["Urgent"], "count": ["3"], "notify": ["No"], "labels": ["Bug", "UI"]]
        #expect(
            ClaudePermissions.elicitationResponse(request, answers: answers)
                == ["action": "accept", "content": ["title": "Crash on launch", "priority": "p1", "count": 3, "notify": false, "labels": ["bug", "ui"]]])
        #expect(ClaudePermissions.elicitationResponse(request, answers: [:]) == ["action": "cancel"])
        // A number that is not one is left out, so the server asks again.
        #expect(ClaudePermissions.elicitationResponse(request, answers: ["title": ["x"], "count": ["2.5"]]).at("content.count") == nil)
    }

    @Test func elicitationLinksAndConfirmations() throws {
        let link: JSONValue = [
            "subtype": "elicitation", "mcp_server_name": "linear", "mode": "url", "url": "https://linear.app/oauth",
            "message": "Sign in to Linear.",
        ]
        let input = try #require(ClaudePermissions.elicitation(requestID: "e2", request: link))
        #expect(input.questions.first?.prompt == "Sign in to Linear.\n\nOpen this link and finish there, then continue:\nhttps://linear.app/oauth")
        #expect(ClaudePermissions.elicitationResponse(link, answers: ["confirm": ["Continue"]]) == ["action": "accept"])
        #expect(ClaudePermissions.elicitationResponse(link, answers: ["confirm": ["Decline"]]) == ["action": "decline"])

        let confirm: JSONValue = [
            "subtype": "elicitation", "mcp_server_name": "db", "message": "Drop the table?",
            "requested_schema": ["type": "object", "properties": [:]],
        ]
        #expect(try #require(ClaudePermissions.elicitation(requestID: "e3", request: confirm)).questions.first?.prompt == "Drop the table?")
        #expect(ClaudePermissions.elicitationResponse(confirm, answers: ["confirm": ["Continue"]]) == ["action": "accept", "content": [:]])

        let nested: JSONValue = [
            "subtype": "elicitation", "mcp_server_name": "x", "message": "Address?",
            "requested_schema": ["type": "object", "properties": ["address": ["type": "object"]]],
        ]
        #expect(ClaudePermissions.elicitation(requestID: "e4", request: nested) == nil)
        #expect(ClaudePermissions.elicitation(requestID: "e5", request: ["subtype": "elicitation", "message": "Token?"]) == nil)
    }
}

struct ClaudeToolPresentationTests {
    private func title(_ name: String, _ input: JSONValue) -> String {
        ClaudeTools.info(id: "t", name: name, input: input, workingDirectory: "/repo", fileContents: { _ in nil }).title
    }

    @Test func titlesNameWhatHappens() {
        #expect(title("Bash", ["command": "npm test\nnpm run lint"]) == "Run `npm test …`")
        #expect(title("Bash", ["command": "npm run dev", "run_in_background": true]) == "Run `npm run dev` in the background")
        #expect(title("Read", ["file_path": "/repo/Sources/App.swift", "offset": 10, "limit": 20]) == "Read Sources/App.swift (lines 10–29)")
        #expect(title("Grep", ["pattern": "TODO", "path": "/repo/Sources"]) == "Search for `TODO` in Sources")
        #expect(title("Glob", ["pattern": "**/*.swift"]) == "Find files matching `**/*.swift`")
        #expect(title("WebFetch", ["url": "https://example.com", "prompt": "Summarize"]) == "Fetch https://example.com")
        #expect(title("Task", ["description": "Find config", "prompt": "…", "subagent_type": "Explore"]) == "Explore: Find config")
        #expect(title("Skill", ["skill": "frontend-design"]) == "Skill: frontend-design")
        #expect(title("TaskStop", ["task_id": "af44d5c14aa3ce867"]) == "Stop task af44d5c14aa3ce867")
        #expect(title("Monitor", ["command": "sleep 8 && echo MONITOR_DONE", "description": "Background monitor test"]) == "Monitor `sleep 8 && echo MONITOR_DONE`")
        #expect(title("SomethingNew", ["x": 1]) == "SomethingNew")
        #expect(ClaudeTools.category(for: "MultiEdit") == .fileChange)
        #expect(ClaudeTools.category(for: "mcp__github__create_issue") == .mcp)
    }

    @Test func pathsAreShownRelativeToTheProject() {
        #expect(ClaudeTools.displayPath("/repo/a/b.swift", relativeTo: "/repo") == "a/b.swift")
        #expect(ClaudeTools.displayPath("/elsewhere/b.swift", relativeTo: "/repo") == "/elsewhere/b.swift")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ClaudeTools.displayPath(home + "/notes.md", relativeTo: "/repo") == "~/notes.md")
    }

    @Test func multiEditDiffsEveryChange() {
        let input: JSONValue = [
            "file_path": "/repo/a.txt",
            "edits": [["old_string": "one", "new_string": "uno"], ["old_string": "three", "new_string": "tres"]],
        ]
        let info = ClaudeTools.info(
            id: "t", name: "MultiEdit", input: input, workingDirectory: "/repo", fileContents: { _ in "one\ntwo\nthree\n" })
        #expect(info.detail == "--- a.txt\n+++ a.txt\n@@ -1,1 +1,1 @@\n-one\n+uno\n@@ -3,1 +3,1 @@\n-three\n+tres")
    }

    @Test func utf8SplitAcrossReadsStaysWhole() {
        var stream = UTF8Stream()
        let bytes = Array("café ✓".utf8)
        let first = stream.decode(Data(bytes[..<4]))
        let second = stream.decode(Data(bytes[4...]))
        #expect(first == "caf")
        #expect(second == "é ✓")
    }

    @Test func imagesAreDetectedAndConverted() throws {
        let png = try #require(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        #expect(ClaudeAttachments.mediaType(of: png) == "image/png")
        #expect(ClaudeAttachments.encodable(png)?.data == png)

        let context = try #require(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let tiff = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(ClaudeAttachments.mediaType(of: tiff as Data) == nil)
        #expect(ClaudeAttachments.encodable(tiff as Data)?.mediaType == "image/png")
        #expect(ClaudeAttachments.encodable(Data("not an image".utf8)) == nil)

        // Wider than Claude takes once a conversation holds many images: scaled down, even though it is a small PNG.
        let wideContext = try #require(
            CGContext(
                data: nil, width: 2_600, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let wide = NSMutableData()
        let wideDestination = try #require(CGImageDestinationCreateWithData(wide, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(wideDestination, try #require(wideContext.makeImage()), nil)
        #expect(CGImageDestinationFinalize(wideDestination))
        let scaled = try #require(ClaudeAttachments.encodable(wide as Data))
        let scaledSource = try #require(CGImageSourceCreateWithData(scaled.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(scaledSource, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? Int) == ClaudeAttachments.maxPixelSize)
    }
}

@MainActor
struct ClaudeTaskOutputTailTests {
    @Test func streamsATaskFileAsItGrows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-tail-\(UUID().uuidString)")
        let tasks = root.appendingPathComponent("-tmp-project/session-1/tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = tasks.appendingPathComponent("b1.output")
        try Data("\u{1B}[32mstream line 1\u{1B}[0m\n".utf8).write(to: file)

        let chunks = Box<[String]>([])
        let tail = ClaudeTaskOutputTail(root: root, sessionID: "session-1", taskID: "b1") { chunks.value.append($0) }
        tail.start()
        defer { tail.cancel() }
        try await waitUntil { chunks.value.joined() == "stream line 1\n" }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("stream line 2\n".utf8))
        try handle.close()
        try await waitUntil { chunks.value.joined() == "stream line 1\nstream line 2\n" }
        #expect(ClaudeTaskOutputTail.root(environment: ["CLAUDE_CODE_TMPDIR": "/var/tmp"]).path == "/var/tmp/claude-\(getuid())")
    }
}

// MARK: - Session

@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for a condition")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Plays Claude Code's side of the protocol from scripted replies.
@MainActor
private final class FakeClaudeTransport: ClaudeTransport {
    enum Reply {
        case success(JSONValue)
        case error(String)
        /// Leaves the request unanswered.
        case ignore
    }

    typealias Replies = @MainActor (FakeClaudeTransport, JSONValue) -> Reply

    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    let config: ClaudeLaunchConfig
    private let replies: Replies
    private(set) var written: [JSONValue] = []
    private(set) var inputClosed = false
    private(set) var terminated = false
    /// Whether `terminate()` ends the process on its own; when false a test calls `exit` itself.
    var exitsWhenTerminated = true

    init(config: ClaudeLaunchConfig, replies: Replies? = nil) {
        self.config = config
        self.replies = replies ?? { transport, request in transport.defaultReply(request) }
    }

    var controlRequests: [JSONValue] { written.filter { $0["type"] == "control_request" }.compactMap { $0["request"] } }
    var controlResponses: [JSONValue] { written.filter { $0["type"] == "control_response" }.compactMap { $0["response"] } }
    var userMessages: [JSONValue] { written.filter { $0["type"] == "user" } }

    func defaultReply(_ request: JSONValue) -> Reply {
        switch request["subtype"]?.string {
        case "initialize"?:
            .success([
                "models": ClaudeFixture.initializeModels, "account": ["email": "user@example.com", "subscriptionType": "Claude Max"],
                "claude_code_version": "2.1.308", "current_permission_mode": .string(config.permissionMode),
            ])
        case "set_model"?: .success(["model": request["model"] ?? .null])
        case "set_permission_mode"?: .success(["mode": request["mode"] ?? .null])
        case "interrupt"?: .success(["still_queued": []])
        default: .success(.null)
        }
    }

    func start() throws {}

    func write(_ line: String) {
        guard let frame = JSONValue.parse(line) else { return }
        written.append(frame)
        guard frame["type"] == "control_request", let id = frame["request_id"]?.string, let request = frame["request"] else { return }
        let response: JSONValue
        switch replies(self, request) {
        case .success(let payload):
            response = ["type": "control_response", "response": ["subtype": "success", "request_id": .string(id), "response": payload]]
        case .error(let message):
            response = ["type": "control_response", "response": ["subtype": "error", "request_id": .string(id), "error": .string(message)]]
        case .ignore:
            return
        }
        later { $0.onLine?(response.compactJSON) }
    }

    /// Delivers frames as Claude Code would print them.
    func emit(_ lines: [String]) {
        for line in lines { onLine?(line) }
    }

    /// Answers the last control request of `subtype`, for requests left unanswered.
    func answer(_ subtype: String, with payload: JSONValue) {
        guard let request = written.last(where: { $0["type"] == "control_request" && $0.at("request.subtype")?.string == subtype }),
            let id = request["request_id"]
        else { return }
        let response: JSONValue = ["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": payload]]
        onLine?(response.compactJSON)
    }

    func exit(status: Int32, stderr: String) {
        onExit?(status, stderr)
    }

    func later(_ action: @escaping @MainActor (FakeClaudeTransport) -> Void) {
        Task { @MainActor in action(self) }
    }

    func closeInput() { inputClosed = true }

    func terminate() {
        guard !terminated else { return }
        terminated = true
        if exitsWhenTerminated { later { $0.onExit?(143, "") } }
    }
}

@MainActor
struct ClaudeSessionTests {
    private let events = Box<[AgentEvent]>([])
    private let transports = Box<[FakeClaudeTransport]>([])

    private func makeSession(
        model: String = "haiku", effort: String? = "low", access: AccessMode = .approval, interaction: InteractionMode = .build,
        resume: String? = nil, replies: (@MainActor (Int, FakeClaudeTransport, JSONValue) -> FakeClaudeTransport.Reply?)? = nil
    ) -> ClaudeSession {
        let launch = AgentLaunch(
            provider: .claude, executable: URL(fileURLWithPath: "/usr/bin/false"), environment: [:],
            workingDirectory: URL(fileURLWithPath: ClaudeFixture.cwd), resumeSessionID: resume,
            selection: ModelSelection(provider: .claude, modelID: model, effort: effort), accessMode: access,
            interactionMode: interaction)
        let transports = self.transports
        let session = ClaudeSession(launch: launch) { config in
            let index = transports.value.count
            let transport = FakeClaudeTransport(config: config) { transport, request in
                replies?(index, transport, request) ?? transport.defaultReply(request)
            }
            transports.value.append(transport)
            return transport
        }
        let events = self.events
        session.onEvent = { events.value.append($0) }
        return session
    }

    private var transport: FakeClaudeTransport { transports.value.last! }

    private func input(
        _ text: String = "Reply with exactly: pong", model: String = "haiku", effort: String? = "low", access: AccessMode = .approval,
        interaction: InteractionMode = .build, images: [String] = [], recap: String? = nil, newSessionRecap: String? = nil
    ) -> AgentTurnInput {
        AgentTurnInput(
            message: text, handoffRecap: recap, newSessionRecap: newSessionRecap ?? recap, imagePaths: images,
            selection: ModelSelection(provider: .claude, modelID: model, effort: effort), accessMode: access,
            interactionMode: interaction)
    }

    private var completions: [TurnOutcome] {
        events.value.compactMap { event in
            if case .turnCompleted(let outcome) = event { return outcome }
            return nil
        }
    }

    /// Sends a turn and lets Claude start it.
    private func startTurn(_ session: ClaudeSession, _ turn: AgentTurnInput? = nil) async throws -> String {
        try await session.send(turn ?? input())
        let uuid = try #require(transport.userMessages.last?["uuid"]?.string)
        transport.emit([ClaudeFixture.lifecycle(uuid, "queued"), ClaudeFixture.lifecycle(uuid, "started"), ClaudeFixture.initFrame])
        return uuid
    }

    @Test func startHandshakesAndReportsTheSession() async throws {
        let session = makeSession()
        try await session.start()
        let config = transport.config
        guard case .fresh(let id) = config.identity else {
            Issue.record("expected a fresh session")
            return
        }
        #expect(session.sessionID == id)
        #expect(events.value.contains(.sessionStarted(id: id)))
        #expect(events.value.contains { if case .modelsDiscovered(let models) = $0 { return models.count == 6 } else { return false } })
        let arguments = config.arguments
        #expect(arguments.starts(with: ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json", "--include-partial-messages"]))
        #expect(arguments.contains("--session-id=\(id)"))
        for pair in [["--permission-mode", "default"], ["--model", "haiku"], ["--effort", "low"], ["--permission-prompt-tool", "stdio"]] {
            #expect(arguments.indices.contains { arguments[$0...].starts(with: pair) }, "missing \(pair)")
        }
        // Approval mode never gets a process that could switch into bypassing prompts.
        #expect(!arguments.contains("--allow-dangerously-skip-permissions"))
        let initialize = try #require(transport.controlRequests.first)
        #expect(initialize["subtype"] == "initialize")
        #expect(initialize["appendSystemPrompt"]?.string?.contains("Coincide") == true)
    }

    @Test func launchEnvironmentDropsParentSessionMarkers() {
        let environment = ClaudeLaunchConfig.environment([
            "PATH": "/opt/homebrew/bin:/usr/bin", "CLAUDE_CODE_TMPDIR": "/var/tmp", "ANTHROPIC_BASE_URL": "https://example.com",
            "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "parent", "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/cc.sock", "CLAUDE_CODE_MESSAGING_TOKEN": "token", "CLAUDE_EFFORT": "max",
        ])
        #expect(environment == ["PATH": "/opt/homebrew/bin:/usr/bin", "CLAUDE_CODE_TMPDIR": "/var/tmp", "ANTHROPIC_BASE_URL": "https://example.com"])
    }

    @Test func resumeUsesTheSavedSession() async throws {
        let session = makeSession(resume: "29718ecd-ee07-4e0c-9590-9666442ec28f")
        try await session.start()
        #expect(transport.config.identity == .resume("29718ecd-ee07-4e0c-9590-9666442ec28f"))
        #expect(transport.config.arguments.contains("--resume=29718ecd-ee07-4e0c-9590-9666442ec28f"))
        #expect(events.value.contains(.sessionStarted(id: "29718ecd-ee07-4e0c-9590-9666442ec28f")))
    }

    @Test func missingConversationStartsFresh() async throws {
        let session = makeSession(resume: "23ace05f-68cb-41ed-96e9-fc4b637bc343") { index, transport, request in
            guard index == 0, request["subtype"] == "initialize" else { return nil }
            transport.later { transport in
                transport.emit([ClaudeFixture.missingConversationResult])
                transport.exit(status: 1, stderr: "No conversation found with session ID: 23ace05f-68cb-41ed-96e9-fc4b637bc343\n")
            }
            return .ignore
        }
        try await session.start()
        #expect(transports.value.count == 2)
        guard case .fresh(let id) = transport.config.identity else {
            Issue.record("expected a fresh session after the failed resume")
            return
        }
        #expect(id != "23ace05f-68cb-41ed-96e9-fc4b637bc343")
        #expect(session.sessionID == id)
        #expect(events.value.contains(.sessionStarted(id: id)))
    }

    @Test func startFailureExplainsWhy() async throws {
        let session = makeSession { _, transport, request in
            guard request["subtype"] == "initialize" else { return nil }
            transport.later { $0.exit(status: 1, stderr: "Error: Invalid model: bogus\n") }
            return .ignore
        }
        do {
            try await session.start()
            Issue.record("expected the start to fail")
        } catch {
            #expect(error.localizedDescription == "Claude Code exited while starting: Error: Invalid model: bogus")
        }
        #expect(session.sessionID == nil)
    }

    @Test func turnStreamsAndCompletesOnItsResult() async throws {
        let session = makeSession()
        try await session.start()
        let uuid = try await startTurn(session)
        let message = try #require(transport.userMessages.last)
        #expect(message["message"] == ["role": "user", "content": "Reply with exactly: pong"])
        #expect(message["parent_tool_use_id"] == .null)
        #expect(uuid.count == 36)

        transport.emit(ClaudeFixture.pongTurn + [ClaudeFixture.pongResult, ClaudeFixture.lifecycle(uuid, "completed")])
        #expect(events.value.contains(.assistantText(itemID: "msg_011CgSG2mzQXcubAcqMv7eaV:text:0", text: "pong")))
        #expect(completions == [.completed])
        #expect(events.value.last == .turnCompleted(.completed))
    }

    @Test func aResultBeforeOurMessageStartsBelongsToClaudesOwnTurn() async throws {
        let session = makeSession()
        try await session.start()
        transport.emit([ClaudeFixture.initFrame])
        try await session.send(input())
        let uuid = try #require(transport.userMessages.last?["uuid"]?.string)
        // A background task finished and Claude answered it while our message waited in its queue.
        transport.emit([ClaudeFixture.lifecycle(uuid, "queued")] + ClaudeFixture.pongTurn + [ClaudeFixture.pongResult])
        #expect(completions.isEmpty)
        transport.emit([ClaudeFixture.lifecycle(uuid, "started")] + ClaudeFixture.pongTurn + [ClaudeFixture.pongResult])
        #expect(completions == [.completed])
    }

    @Test func resultsNameTheMessagesTheyAnswer() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        let uuid = try #require(transport.userMessages.last?["uuid"]?.string)
        let other = "8e9021e7-0000-4000-8000-000000000001"
        func result(_ fields: String) -> String {
            #"{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","result":"done","total_cost_usd":0.01"#
                + fields + "}"
        }
        // Claude answered finished background work while our message waited.
        transport.emit([
            ClaudeFixture.lifecycle(uuid, "queued"), result(#","origin":{"kind":"task-notification"}"#),
            result(#","user_message_uuid":"\#(other)","user_message_uuids":["\#(other)"]"#),
        ])
        #expect(completions.isEmpty)
        // Then it folded our message into a turn of its own, whose result names both.
        transport.emit([
            ClaudeFixture.lifecycle(uuid, "started"),
            result(#","user_message_uuid":"\#(uuid)","user_message_uuids":["\#(other)","\#(uuid)"]"#),
            ClaudeFixture.lifecycle(uuid, "completed"),
        ])
        #expect(completions == [.completed])
    }

    @Test func aTurnClaudeStartsByItselfIsReportedAsOne() async throws {
        let session = makeSession()
        try await session.start()
        transport.emit([ClaudeFixture.initFrame])
        // Background work finished between turns and Claude answers it.
        transport.emit(ClaudeFixture.pongTurn + [ClaudeFixture.pongResult])
        #expect(events.value.filter { if case .agentTurnStarted = $0 { true } else { false } } == [.agentTurnStarted(note: "Claude Code continued on its own.")])
        #expect(completions == [.completed])

        // Stopping one sends an interrupt; its result ends it as interrupted.
        transport.emit(Array(ClaudeFixture.pongTurn.prefix(2)))
        session.interrupt()
        try await waitUntil { transport.controlRequests.last?["subtype"] == "interrupt" }
        transport.emit([ClaudeFixture.interruptedResult])
        #expect(completions == [.completed, .interrupted])

        // The result of a turn of ours that ended before its result does not end anything else.
        _ = try await startTurn(session)
        session.interrupt()
        let uuid = try #require(transport.userMessages.last?["uuid"]?.string)
        transport.emit([ClaudeFixture.lifecycle(uuid, "cancelled")])
        #expect(completions == [.completed, .interrupted, .interrupted])
        transport.emit(Array(ClaudeFixture.pongTurn.prefix(2)) + [ClaudeFixture.interruptedResult])
        #expect(completions == [.completed, .interrupted, .interrupted])
        #expect(events.value.filter { if case .agentTurnStarted = $0 { true } else { false } }.count == 2)
    }

    @Test func aMessageClaudeNeverStartsFailsTheTurn() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        let uuid = try #require(transport.userMessages.last?["uuid"]?.string)
        transport.emit([ClaudeFixture.lifecycle(uuid, "queued"), ClaudeFixture.lifecycle(uuid, "completed")])
        #expect(completions == [.failed("Claude Code accepted the message but never started working on it.")])
    }

    @Test func aResultCarryingTheOnlyOutputBecomesTheReply() async throws {
        let session = makeSession()
        try await session.start()
        _ = try await startTurn(session, input("/compact"))
        transport.emit([
            #"{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","result":"Not enough messages to compact.","uuid":"r1","total_cost_usd":0}"#
        ])
        #expect(events.value.suffix(2) == [.assistantText(itemID: "r1:result", text: "Not enough messages to compact."), .turnCompleted(.completed)])
        // A turn that showed its reply does not repeat the result's copy of it.
        _ = try await startTurn(session)
        let start = events.value.count
        transport.emit(ClaudeFixture.pongTurn + [ClaudeFixture.pongResult])
        #expect(events.value[start...].filter { if case .assistantText = $0 { true } else { false } }.count == 1)
    }

    @Test func approvalRoundTrip() async throws {
        let session = makeSession()
        try await session.start()
        _ = try await startTurn(session)
        transport.emit([ClaudeFixture.messageStart, ClaudeFixture.writeStart, ClaudeFixture.writeSnapshot, ClaudeFixture.writePermission])
        guard case .approvalRequested(let approval)? = events.value.last else {
            Issue.record("expected an approval request")
            return
        }
        #expect(approval.id == "8c01462d-ad80-4555-a9e4-1b50e7524438")
        #expect(approval.title == "Write note.txt")
        session.respond(to: approval.id, optionID: ClaudePermissions.allowID)
        let response = try #require(transport.controlResponses.last)
        #expect(response["subtype"] == "success")
        #expect(response["request_id"] == "8c01462d-ad80-4555-a9e4-1b50e7524438")
        #expect(response.at("response.behavior") == "allow")
        #expect(response.at("response.updatedInput") == ["file_path": "/private/tmp/claude-probe/cwd/note.txt", "content": "hello\n"])
        // A second answer for the same request is ignored.
        session.respond(to: approval.id, optionID: ClaudePermissions.denyID)
        #expect(transport.controlResponses.count == 1)
    }

    @Test func withdrawnApprovalIsResolved() async throws {
        let session = makeSession()
        try await session.start()
        _ = try await startTurn(session)
        transport.emit([ClaudeFixture.writeSnapshot, ClaudeFixture.writePermission, ClaudeFixture.cancelWritePermission])
        #expect(events.value.last == .approvalResolved(id: "8c01462d-ad80-4555-a9e4-1b50e7524438"))
        session.respond(to: "8c01462d-ad80-4555-a9e4-1b50e7524438", optionID: ClaudePermissions.allowID)
        #expect(transport.controlResponses.isEmpty)
    }

    @Test func interruptEndsTheTurnOnce() async throws {
        let session = makeSession()
        session.interruptGracePeriod = .milliseconds(200)
        try await session.start()
        _ = try await startTurn(session)
        transport.emit(Array(ClaudeFixture.pongTurn.prefix(3)))
        session.interrupt()
        session.interrupt()
        try await waitUntil { transport.controlRequests.contains { $0["subtype"] == "interrupt" } }
        let interrupt = try #require(transport.controlRequests.last)
        #expect(interrupt == ["subtype": "interrupt", "cancel_queued": true])
        transport.emit([ClaudeFixture.interruptedResult])
        try await Task.sleep(for: .milliseconds(300))
        #expect(completions == [.interrupted])
        #expect(!transport.terminated)
    }

    @Test func interruptDropsAMessageClaudeHadNotStarted() async throws {
        let session = makeSession { _, transport, request in
            guard request["subtype"] == "interrupt", let uuid = transport.userMessages.last?["uuid"] else { return nil }
            return .success(["still_queued": [], "cancelled": [uuid]])
        }
        try await session.start()
        try await session.send(input())
        try await waitUntil { !transport.userMessages.isEmpty }
        session.interrupt()
        try await waitUntil { !completions.isEmpty }
        #expect(completions == [.interrupted])
    }

    @Test func unansweredInterruptStopsTheProcess() async throws {
        let session = makeSession { _, _, request in request["subtype"] == "interrupt" ? .ignore : nil }
        session.interruptGracePeriod = .milliseconds(50)
        try await session.start()
        let stuck = transport
        _ = try await startTurn(session)
        session.interrupt()
        try await waitUntil { events.value.contains(.sessionExited(error: nil)) }
        #expect(completions == [.interrupted])
        #expect(stuck.terminated)

        // Its late output is ignored, and the next message resumes the conversation in a new process.
        stuck.emit([ClaudeFixture.pongResult])
        #expect(completions == [.interrupted])
        try await session.send(input())
        #expect(transports.value.count == 2)
        #expect(transport.config.identity == .resume(try #require(session.sessionID)))
        #expect(transport.userMessages.count == 1)
    }

    @Test func interruptWhilePreparingNeverSendsTheMessage() async throws {
        let session = makeSession { _, _, request in request["subtype"] == "set_model" ? .ignore : nil }
        try await session.start()
        let turn = input(model: "opus")
        let sending = Task { try await session.send(turn) }
        try await waitUntil { transport.controlRequests.contains { $0["subtype"] == "set_model" } }
        session.interrupt()
        transport.answer("set_model", with: ["model": "claude-opus-5-5"])
        try await sending.value
        #expect(transport.userMessages.isEmpty)
        #expect(completions == [.interrupted])
    }

    @Test func perTurnChangesUseControlRequests() async throws {
        let session = makeSession(access: .fullAccess, interaction: .plan)
        try await session.start()
        #expect(transport.config.arguments.contains("--allow-dangerously-skip-permissions"))
        try await session.send(input(model: "opus", effort: "ultracode", access: .fullAccess))
        let requests = transport.controlRequests.dropFirst().map { $0 }
        #expect(
            requests == [
                ["subtype": "set_model", "model": "opus"],
                ["subtype": "apply_flag_settings", "settings": ["effortLevel": "xhigh", "ultracode": true]],
                ["subtype": "set_permission_mode", "mode": "bypassPermissions"],
            ])
        #expect(transport.written.last?["type"] == "user")
        let uuid = try #require(transport.userMessages.last?["uuid"]?.string)
        transport.emit([ClaudeFixture.lifecycle(uuid, "started"), ClaudeFixture.pongResult])

        try await session.send(input(model: "default", effort: "ultracode", access: .fullAccess, interaction: .plan))
        #expect(transport.controlRequests.suffix(2) == [["subtype": "set_model", "model": "default"], ["subtype": "set_permission_mode", "mode": "plan"]])
        #expect(transports.value.count == 1)
    }

    @Test func fullAccessComesOnlyWithAProcessStartedForIt() async throws {
        let session = makeSession()
        try await session.start()
        let asking = transport
        // Approval mode cannot switch to bypassing prompts, so full access starts a process allowed to.
        try await session.send(input(access: .fullAccess))
        #expect(transports.value.count == 2 && asking.terminated)
        #expect(transport.config.permissionMode == "bypassPermissions")
        #expect(transport.config.arguments.contains("--allow-dangerously-skip-permissions"))
        #expect(!asking.controlRequests.contains { $0["subtype"] == "set_permission_mode" })
        let uuid = try #require(transport.userMessages.last?["uuid"]?.string)
        transport.emit([ClaudeFixture.lifecycle(uuid, "started"), ClaudeFixture.pongResult])

        // Leaving full access leaves that process too; its background work is reported as stopped.
        transport.emit([
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1","task_type":"local_bash","description":"npm run dev"},{"task_id":"w1","task_type":"monitor","description":"watch","ambient":true}]}"#
        ])
        let id = try #require(session.sessionID)
        try await session.send(input(access: .approval))
        #expect(transports.value.count == 3)
        #expect(transport.config.identity == .resume(id))
        #expect(transport.config.permissionMode == "default")
        #expect(!transport.config.arguments.contains("--allow-dangerously-skip-permissions"))
        #expect(
            events.value.contains(.notice("Claude Code restarted to apply the new settings, which stopped its background work: npm run dev.")))
        #expect(!events.value.contains { if case .sessionExited = $0 { return true } else { return false } })
    }

    @Test func ultrathinkAsksInThePrompt() async throws {
        let session = makeSession(model: "sonnet", effort: "ultrathink")
        try await session.start()
        #expect(!transport.config.arguments.contains("--effort"))
        try await session.send(input("fix the bug", model: "sonnet", effort: "ultrathink"))
        #expect(transport.userMessages.last?.at("message.content") == "Ultrathink:\nfix the bug")
    }

    @Test func clearingTheEffortRelaunchesOnTheSameConversation() async throws {
        let session = makeSession(model: "haiku", effort: "medium")
        try await session.start()
        let first = transport
        let uuid = try await startTurn(session, input(effort: "medium"))
        #expect(first.controlRequests.count == 1)
        transport.emit([ClaudeFixture.pongResult, ClaudeFixture.lifecycle(uuid, "completed")])
        let id = try #require(session.sessionID)

        try await session.send(input(model: "claude-haiku-4-5", effort: nil))
        #expect(first.terminated && first.inputClosed)
        #expect(transports.value.count == 2)
        #expect(transport.config.identity == .resume(id))
        #expect(transport.config.model == "claude-haiku-4-5")
        #expect(!transport.config.arguments.contains("--effort"))
        #expect(transport.userMessages.count == 1)
        #expect(!events.value.contains { if case .sessionExited = $0 { return true } else { return false } })
    }

    @Test func refusedModelSwitchRelaunches() async throws {
        let session = makeSession { _, _, request in
            request["subtype"] == "set_model" ? .error("Model 'claude-new-7' not found") : nil
        }
        try await session.start()
        try await session.send(input(model: "claude-new-7", effort: "high"))
        #expect(transports.value.count == 2)
        #expect(transport.config.model == "claude-new-7")
        #expect(transport.config.identity == transports.value[0].config.identity)
    }

    @Test func refusedPermissionSwitchRelaunchesInThatMode() async throws {
        let session = makeSession(access: .fullAccess, interaction: .plan) { index, _, request in
            index == 0 && request["subtype"] == "set_permission_mode" ? .error("Cannot switch to bypassPermissions") : nil
        }
        try await session.start()
        try await session.send(input(access: .fullAccess))
        #expect(transports.value.count == 2)
        #expect(transport.config.permissionMode == "bypassPermissions")
        #expect(transport.config.identity == transports.value[0].config.identity)
        #expect(!events.value.contains { if case .notice = $0 { return true } else { return false } })
    }

    @Test func planModeClaudeReportsIsLeftForBuildTurns() async throws {
        let session = makeSession()
        try await session.start()
        let uuid = try await startTurn(session)
        // Claude entered plan mode through a settings change the tools did not show; its status says so.
        transport.emit([
            #"{"type":"system","subtype":"status","status":null,"permissionMode":"plan"}"#, ClaudeFixture.pongResult,
            ClaudeFixture.lifecycle(uuid, "completed"),
        ])
        try await session.send(input())
        #expect(transport.controlRequests.last == ["subtype": "set_permission_mode", "mode": "default"])
        // Accepting edits after "Always allow" is the user's choice and stays.
        let next = try #require(transport.userMessages.last?["uuid"]?.string)
        transport.emit([
            ClaudeFixture.lifecycle(next, "started"), #"{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}"#,
            ClaudeFixture.pongResult,
        ])
        let count = transport.controlRequests.count
        try await session.send(input())
        #expect(transport.controlRequests.count == count)
    }

    @Test func freshSessionAfterALostConversationKeepsItsID() async throws {
        let lost = "29718ecd-ee07-4e0c-9590-9666442ec28f"
        let session = makeSession(effort: "medium", resume: lost) { index, transport, request in
            guard index == 1, request["subtype"] == "initialize" else { return nil }
            transport.later { transport in
                transport.emit([ClaudeFixture.missingConversationResult])
                transport.exit(status: 1, stderr: "No conversation found with session ID: \(lost)\n")
            }
            return .ignore
        }
        try await session.start()
        transport.emit([ClaudeFixture.initFrame])
        // Dropping the effort takes a new process, and by then the saved conversation is gone.
        let recap = "<conversation_handoff>\nthe whole thread\n</conversation_handoff>\n\nThe user's new message:"
        try await session.send(input(model: "claude-haiku-4-5", effort: nil, recap: nil, newSessionRecap: recap))
        #expect(transports.value.count == 3)
        let fresh = try #require(session.sessionID)
        #expect(fresh != lost)
        #expect(transport.config.identity == .fresh(fresh))
        #expect(events.value.contains(.sessionStarted(id: fresh)))
        // The new conversation has seen nothing, so it gets the recap of the whole thread.
        #expect(transport.userMessages.last?.at("message.content")?.string == recap + "\n\nReply with exactly: pong")
        #expect(
            events.value.contains(
                .notice("Claude Code could not find this thread's saved conversation, so it started a new one with a recap of the earlier messages.")))
        #expect(!events.value.contains { if case .usage(let usage) = $0 { return usage.costUSD == 0 } else { return false } })

        // Frames sent before the new process reports its id must not switch back to the lost one.
        transport.emit([#"{"type":"system","subtype":"status","status":"requesting"}"#])
        #expect(session.sessionID == fresh)
        #expect(!events.value.contains { if case .sessionContinued = $0 { return true } else { return false } })
    }

    @Test func clearingTheConversationContinuesTheSession() async throws {
        let session = makeSession()
        try await session.start()
        let reset = #"{"type":"conversation_reset","new_conversation_id":"7d3c2b1a-0000-4000-8000-000000000001","uuid":"u1","session_id":"x"}"#
        transport.emit([reset])
        #expect(events.value.last == .sessionContinued(id: "7d3c2b1a-0000-4000-8000-000000000001"))
        #expect(session.sessionID == "7d3c2b1a-0000-4000-8000-000000000001")
    }

    @Test func planModeCapturesThePlanAndStops() async throws {
        let session = makeSession(interaction: .plan)
        try await session.start()
        #expect(transport.config.permissionMode == "plan")
        _ = try await startTurn(session, input(interaction: .plan))
        transport.emit([ClaudeFixture.exitPlanSnapshot, ClaudeFixture.exitPlanPermission])
        let plan = "# Plan: add hello.txt\n\n## Steps\n1. Create `hello.txt` containing `hi`.\n2. Read it back."
        #expect(events.value.contains(.plan(text: plan)))
        #expect(!events.value.contains { if case .approvalRequested = $0 { return true } else { return false } })
        let response = try #require(transport.controlResponses.last)
        #expect(response.at("response.behavior") == "deny")
        #expect(response.at("response.message")?.string == ClaudePermissions.planCapturedMessage)

        // The next build turn leaves plan mode.
        transport.emit([ClaudeFixture.pongResult])
        try await session.send(input())
        #expect(transport.controlRequests.last == ["subtype": "set_permission_mode", "mode": "default"])
    }

    @Test func leavingPlanModeClaudeEnteredItselfIsApproved() async throws {
        let session = makeSession()
        try await session.start()
        _ = try await startTurn(session)
        transport.emit([ClaudeFixture.exitPlanSnapshot, ClaudeFixture.exitPlanPermission])
        guard case .approvalRequested(let approval)? = events.value.last else {
            Issue.record("expected a plan approval")
            return
        }
        #expect(approval.options.map(\.label) == ["Implement", "Keep planning"])
        session.respond(to: approval.id, optionID: ClaudePermissions.allowID)
        #expect(transport.controlResponses.last?.at("response.behavior") == "allow")
    }

    @Test func deniedApprovalCarriesTheUsersNote() async throws {
        let session = makeSession()
        try await session.start()
        _ = try await startTurn(session)
        transport.emit([ClaudeFixture.writeSnapshot, ClaudeFixture.writePermission])
        session.respond(to: "8c01462d-ad80-4555-a9e4-1b50e7524438", optionID: ClaudePermissions.denyID, text: "Write it to notes/ instead")
        let response = try #require(transport.controlResponses.last)
        #expect(response.at("response.behavior") == "deny")
        #expect(response.at("response.message")?.string == ClaudePermissions.rejectionNotePrefix + "Write it to notes/ instead")
    }

    @Test func questionsAreAnsweredTogether() async throws {
        let session = makeSession()
        try await session.start()
        _ = try await startTurn(session)
        transport.emit([ClaudeFixture.questionPermission])
        let requestID = "5e1f0c2a-7d3b-4c55-9a51-2b3f4e5d6c7a"
        guard case .userInputRequested(let request)? = events.value.last else {
            Issue.record("expected questions")
            return
        }
        #expect(request.id == requestID)
        #expect(request.questions.map(\.id) == ["Which database should the app use?", "Which checks should run?"])
        #expect(!events.value.contains { if case .approvalRequested = $0 { return true } else { return false } })

        // Approvals and questions are answered through their own calls.
        session.respond(to: requestID, optionID: ClaudePermissions.allowID)
        #expect(transport.controlResponses.isEmpty)
        session.answer(
            userInput: requestID,
            answers: ["Which database should the app use?": ["Postgres"], "Which checks should run?": ["Unit tests", "Lint"]])
        let response = try #require(transport.controlResponses.last)
        #expect(response["request_id"] == .string(requestID))
        #expect(response.at("response.behavior") == "allow")
        #expect(
            response.at("response.updatedInput.answers")
                == ["Which database should the app use?": "Postgres", "Which checks should run?": "Unit tests, Lint"])
        session.answer(userInput: requestID, answers: [:])
        #expect(transport.controlResponses.count == 1)
    }

    @Test func dismissedQuestionsAreDeniedAndWithdrawnOnesResolved() async throws {
        let session = makeSession()
        try await session.start()
        _ = try await startTurn(session)
        transport.emit([ClaudeFixture.questionPermission])
        session.answer(userInput: "5e1f0c2a-7d3b-4c55-9a51-2b3f4e5d6c7a", answers: [:])
        #expect(transport.controlResponses.last?.at("response.behavior") == "deny")

        let second = ClaudeFixture.questionPermission.replacingOccurrences(of: "5e1f0c2a-7d3b-4c55-9a51-2b3f4e5d6c7a", with: "q2")
        transport.emit([second, #"{"type":"control_cancel_request","request_id":"q2"}"#])
        #expect(events.value.last == .userInputResolved(id: "q2"))
        session.answer(userInput: "q2", answers: ["Which checks should run?": ["Lint"]])
        #expect(transport.controlResponses.count == 1)
    }

    @Test func crashFailsTheTurnAndEndsTheSession() async throws {
        let session = makeSession()
        try await session.start()
        _ = try await startTurn(session)
        transport.exit(status: 1, stderr: "panic: something broke\n")
        #expect(completions == [.failed("Claude Code exited with status 1.\npanic: something broke")])
        #expect(events.value.last == .sessionExited(error: "Claude Code exited with status 1.\npanic: something broke"))
        // Should the runner still send on it, the session restarts on its conversation.
        try await session.send(input())
        #expect(transports.value.count == 2)
        #expect(transport.config.identity == .resume(try #require(session.sessionID)))
    }

    @Test func imagesAreSentAsContentBlocks() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-\(UUID().uuidString).png")
        try #require(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
        ).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let session = makeSession()
        try await session.start()
        try await session.send(input("/review What color?", images: [path.path, "/nonexistent/missing.heic"]))
        let content = try #require(transport.userMessages.last?.at("message.content")?.array)
        // A slash command or skill runs only when it starts the last text block, so the text goes last.
        #expect(content.first?.at("source.media_type") == "image/png")
        #expect(content.last == ["type": "text", "text": "/review What color?"])
        #expect(content.count == 2)
        #expect(events.value.contains(.notice("Couldn't attach missing.heic.")))

        let uuid = try #require(transport.userMessages.last?["uuid"]?.string)
        transport.emit([ClaudeFixture.lifecycle(uuid, "started"), ClaudeFixture.pongResult])
        try await session.send(input("", images: [path.path]))
        #expect(transport.userMessages.last?.at("message.content")?.array?.map { $0["type"] } == ["image"])
    }

    @Test func aCommandAfterARecapStartsTheLastTextBlock() async throws {
        let thread = ChatThread(
            projectID: UUID(), selection: ModelSelection(provider: .claude, modelID: "sonnet"),
            items: [
                TranscriptItem(kind: .user, text: "Fix the build"),
                TranscriptItem(kind: .assistant, text: "Fixed it.", provider: .codex),
            ])
        let recap = try #require(Handoff.recap(thread: thread, provider: .claude))
        #expect(recap.hasPrefix("<conversation_handoff>") && recap.hasSuffix(":"))
        #expect(ClaudeSession.promptTexts(message: "/review the diff", recap: recap, ultrathink: false) == [recap, "/review the diff"])
        #expect(
            ClaudeSession.promptTexts(message: "review the diff", recap: recap, ultrathink: false)
                == [Handoff.prompt(for: "review the diff", thread: thread, provider: .claude)])
        #expect(ClaudeSession.promptTexts(message: "/review the diff", recap: nil, ultrathink: false) == ["/review the diff"])

        let session = makeSession(model: "sonnet", effort: "ultrathink")
        try await session.start()
        try await session.send(input("/review the diff", model: "sonnet", effort: "ultrathink", recap: recap))
        let content = try #require(transport.userMessages.last?.at("message.content")?.array)
        // Ultrathink is a request to the model, not to a command.
        #expect(content == [["type": "text", "text": .string(recap)], ["type": "text", "text": "/review the diff"]])
    }

    @Test func userMessagesAreMarkedAsTypedByAPerson() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        let message = try #require(transport.userMessages.last)
        #expect(message["origin"] == ["kind": "human"])
        #expect(message["message"] == ["role": "user", "content": "Reply with exactly: pong"])
    }

    @Test func refusedFullAccessFallsBackToAutoMode() async throws {
        let session = makeSession(access: .fullAccess) { _, _, request in
            guard request["subtype"] == "initialize" else { return nil }
            return .success(["models": ClaudeFixture.initializeModels, "current_permission_mode": "default"])
        }
        try await session.start()
        #expect(transport.controlRequests.last == ["subtype": "set_permission_mode", "mode": "auto"])
        #expect(events.value.contains(.notice("Claude Code's settings don't allow full access, so it decides approvals itself (auto mode).")))
    }

    @Test func aTakenFreshIDIsResumed() async throws {
        let session = makeSession { index, transport, request in
            guard index == 1, request["subtype"] == "initialize" else { return nil }
            transport.later { $0.exit(status: 1, stderr: "Error: Session ID \($0.config.sessionID) is already in use.\n") }
            return .ignore
        }
        try await session.start()
        let id = try #require(session.sessionID)
        // Full access before the first message restarts on the same fresh id, which Claude had saved after all.
        try await session.send(input(access: .fullAccess))
        #expect(transports.value.count == 3)
        #expect(transport.config.identity == .resume(id))
        #expect(session.sessionID == id)
        #expect(transport.userMessages.count == 1)
    }

    @Test func shutdownDuringARestartStartsNothing() async throws {
        let session = makeSession()
        try await session.start()
        let first = transport
        first.exitsWhenTerminated = false
        let sending = Task { try await session.send(input(access: .fullAccess)) }
        try await waitUntil { first.terminated }
        session.shutdown()
        first.exit(status: 143, stderr: "")
        await #expect(throws: (any Error).self) { try await sending.value }
        try await Task.sleep(for: .milliseconds(20))
        #expect(transports.value.count == 1)
        #expect(events.value.allSatisfy { if case .turnCompleted = $0 { false } else { true } })
    }

    @Test func subagentApprovalsDescribeTheCallWithoutAToolItem() async throws {
        let session = makeSession()
        try await session.start()
        _ = try await startTurn(session)
        transport.emit([
            ClaudeFixture.controlRequest(
                "p1",
                [
                    "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "rm -rf build"], "tool_use_id": "toolu_sub",
                    "agent_id": "a1",
                ])
        ])
        #expect(!events.value.contains { if case .toolStarted = $0 { true } else { false } })
        guard case .approvalRequested(let approval)? = events.value.last else {
            Issue.record("expected an approval")
            return
        }
        #expect(approval.title == "Run `rm -rf build`")
    }

    @Test func elicitationsAreAskedAndAnswered() async throws {
        let session = makeSession()
        try await session.start()
        let form: JSONValue = [
            "subtype": "elicitation", "mcp_server_name": "github", "message": "Your GitHub handle?",
            "requested_schema": ["type": "object", "properties": ["handle": ["type": "string"]], "required": ["handle"]],
        ]
        transport.emit([ClaudeFixture.controlRequest("e1", form)])
        guard case .userInputRequested(let request)? = events.value.last else {
            Issue.record("expected questions")
            return
        }
        #expect(request.questions.map(\.prompt) == ["Your GitHub handle?"])
        session.answer(userInput: "e1", answers: ["handle": ["octocat"]])
        #expect(
            transport.controlResponses.last
                == ["subtype": "success", "request_id": "e1", "response": ["action": "accept", "content": ["handle": "octocat"]]])

        transport.emit([ClaudeFixture.controlRequest("e2", form), #"{"type":"control_cancel_request","request_id":"e2"}"#])
        #expect(events.value.last == .userInputResolved(id: "e2"))
        session.answer(userInput: "e2", answers: ["handle": ["late"]])
        #expect(transport.controlResponses.count == 1)
    }

    @Test func otherControlRequestsAreAnswered() async throws {
        let session = makeSession()
        try await session.start()
        transport.emit([
            ClaudeFixture.controlRequest("e1", ["subtype": "elicitation", "mcp_server_name": "github", "message": "Token?"]),
            ClaudeFixture.controlRequest("h1", ["subtype": "hook_callback", "callback_id": "hook_0"]),
        ])
        #expect(transport.controlResponses.first == ["subtype": "success", "request_id": "e1", "response": ["action": "decline"]])
        #expect(transport.controlResponses.last?["subtype"] == "error")
    }

    @Test func shutdownStopsEverything() async throws {
        let session = makeSession()
        try await session.start()
        _ = try await startTurn(session)
        let count = events.value.count
        session.shutdown()
        #expect(transport.terminated && transport.inputClosed)
        transport.emit(ClaudeFixture.pongTurn)
        try await Task.sleep(for: .milliseconds(20))
        #expect(events.value.count == count)
    }
}
