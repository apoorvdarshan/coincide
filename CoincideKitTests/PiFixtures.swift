import Foundation

@testable import CoincideKit

/// Pi RPC records taken from T3 Code's recorded Pi 1.0 transcripts (provider-pi replay fixtures).
/// System prompts and `agent_end` message lists are shortened; Coincide ignores them.
enum PiFixtures {
    static let deepseek: JSONValue = parse(
        #"{"type":"chat","id":"deepseek/deepseek-v4-flash","name":"DeepSeek: DeepSeek V4 Flash 0423","api":"openai-completions","baseUrl":"https://openrouter.ai/api/v1","provider":"openrouter","reasoning":true,"thinkingLevelMap":{"off":"none","minimal":null,"low":null,"medium":null,"high":"high","xhigh":"xhigh","max":null},"input":["text"],"cost":{"input":0.04186,"output":0.08372,"cacheRead":0.008372,"cacheWrite":0},"contextWindow":1048576,"maxTokens":131072}"#)

    static let sonnet: JSONValue = parse(
        #"{"id":"claude-sonnet-4-5","name":"Claude Sonnet 4.5","api":"anthropic-messages","provider":"anthropic","baseUrl":"https://api.anthropic.com","reasoning":true,"input":["text","image"],"contextWindow":200000,"maxTokens":64000,"cost":{"input":3,"output":15,"cacheRead":0.3,"cacheWrite":3.75}}"#)

    static let sonnetOnOpenRouter: JSONValue = parse(
        #"{"id":"anthropic/claude-sonnet-4.5","name":"Claude Sonnet 4.5","api":"openai-completions","provider":"openrouter","reasoning":true,"input":["text","image"],"contextWindow":1000000}"#)

    static let mini: JSONValue = parse(
        #"{"id":"gpt-4o-mini","name":"GPT-4o mini","api":"openai-responses","provider":"openai","reasoning":false,"input":["text","image"],"contextWindow":128000}"#)

    /// `get_state` of an idle session, as Pi 1.0 reported it.
    static func state(model: JSONValue? = deepseek, sessionFile: String, thinkingLevel: String = "high", streaming: Bool = false)
        -> JSONValue
    {
        var state: [String: JSONValue] = [
            "thinkingLevel": .string(thinkingLevel), "isStreaming": .bool(streaming), "isCompacting": false,
            "steeringMode": "one-at-a-time", "followUpMode": "one-at-a-time", "sessionFile": .string(sessionFile),
            "sessionId": "00000000-0000-4000-8000-000000000002", "autoCompactionEnabled": true, "messageCount": 3,
            "pendingMessageCount": 0,
        ]
        if let model { state["model"] = model }
        return .object(state)
    }

    static let sessionStats: JSONValue = parse(
        #"{"sessionFile":"/pi-sessions/session-1.jsonl","sessionId":"00000000-0000-4000-8000-000000000002","userMessages":1,"assistantMessages":1,"toolCalls":0,"toolResults":0,"totalMessages":3,"tokens":{"input":1786,"output":28,"cacheRead":0,"cacheWrite":0,"total":1814},"cost":0.00007710612,"contextUsage":{"tokens":1814,"contextWindow":1048576,"percent":0.17299652099609375}}"#)

    /// Stats right after a compaction: Pi has no token count until the next response.
    static let statsAfterCompaction: JSONValue = parse(
        #"{"sessionFile":"/pi-sessions/session-1.jsonl","sessionId":"00000000-0000-4000-8000-000000000002","userMessages":3,"assistantMessages":3,"toolCalls":0,"toolResults":0,"totalMessages":7,"tokens":{"input":1950,"output":1079,"cacheRead":4277,"cacheWrite":0,"total":7306},"cost":0.000207767924,"contextUsage":{"tokens":null,"contextWindow":1048576,"percent":null}}"#)

    /// The "simple" scenario: thinking, then the answer "fixture simple ok".
    static let simpleTurn: [String] = [
        #"{"type":"agent_start"}"#,
        #"{"type":"turn_start"}"#,
        #"{"type":"message_start","message":{"role":"system","content":"","timestamp":1790898566303}}"#,
        #"{"type":"message_end","message":{"role":"system","content":"","timestamp":1790898566303}}"#,
        #"{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"Respond with the following text: fixture simple ok"}],"timestamp":1767225600372}}"#,
        #"{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"Respond with the following text: fixture simple ok"}],"timestamp":1767225600372}}"#,
        #"{"type":"message_start","message":{"role":"assistant","content":[],"api":"openai-completions","provider":"openrouter","model":"deepseek/deepseek-v4-flash","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"pending","timestamp":1767225600403}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"thinking_start","contentIndex":0}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"The"}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":" user wants me to respond with"}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":" a specific text: \"fi"}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"xture simple ok\". Let"}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":" me do that."}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_start","contentIndex":1}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"fi"}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"xture simple ok"}}"#,
        #"{"type":"message_update","usage":{"input":1786,"output":28,"cacheRead":0,"cacheWrite":0,"reasoning":22,"totalTokens":1814,"cost":{"input":7.476196e-05,"output":2.34416e-06,"cacheRead":0,"cacheWrite":0,"total":7.710612e-05}},"assistantMessageEvent":{"type":"thinking_end","contentIndex":0,"content":"The user wants me to respond with a specific text: \"fixture simple ok\". Let me do that."}}"#,
        #"{"type":"message_update","usage":{"input":1786,"output":28,"cacheRead":0,"cacheWrite":0,"reasoning":22,"totalTokens":1814,"cost":{"input":7.476196e-05,"output":2.34416e-06,"cacheRead":0,"cacheWrite":0,"total":7.710612e-05}},"assistantMessageEvent":{"type":"text_end","contentIndex":1,"content":"fixture simple ok"}}"#,
        #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The user wants me to respond with a specific text: \"fixture simple ok\". Let me do that.","thinkingSignature":"<signature>"},{"type":"text","text":"fixture simple ok"}],"api":"openai-completions","provider":"openrouter","model":"deepseek/deepseek-v4-flash","usage":{"input":1786,"output":28,"cacheRead":0,"cacheWrite":0,"reasoning":22,"totalTokens":1814,"cost":{"input":7.476196e-05,"output":2.34416e-06,"cacheRead":0,"cacheWrite":0,"total":7.710612e-05}},"stopReason":"stop","timestamp":1767225600403,"responseId":"gen-1790898566-bUc88KtwqdnyLsORQheS","rawStopReason":"stop","thinkingLevel":"high"}}"#,
        #"{"type":"turn_end","message":{"role":"assistant","content":[]},"toolResults":[]}"#,
        #"{"type":"agent_end","messages":[]}"#,
        #"{"type":"agent_settled"}"#,
    ]

    static let interruptedCallID = "call_9726ad99cc114832996228eb"
    static let interruptedCommand = #"node -e "console.log('interrupt fixture tool started'); setTimeout(() => {}, 30000)""#

    /// The "turn_interrupt_mid_tool" scenario up to the moment T3 sent `abort`.
    static let toolTurnBeforeAbort: [String] = [
        #"{"type":"agent_start"}"#,
        #"{"type":"turn_start"}"#,
        #"{"type":"message_start","message":{"role":"assistant","content":[],"api":"openai-completions","provider":"openrouter","model":"deepseek/deepseek-v4-flash","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"pending","timestamp":1767225600401}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"thinking_start","contentIndex":0}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"toolcall_start","contentIndex":1,"id":"call_9726ad99cc114832996228eb","toolName":"bash"}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":1,"delta":"{"}}"#,
        #"{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":1,"delta":"\"command\": \"node -e \\\"consol"}}"#,
        #"{"type":"message_update","usage":{"input":1830,"output":102,"cacheRead":0,"cacheWrite":0,"reasoning":23,"totalTokens":1932,"cost":{"input":7.66038e-05,"output":8.53944e-06,"cacheRead":0,"cacheWrite":0,"total":8.514324e-05}},"assistantMessageEvent":{"type":"thinking_end","contentIndex":0,"content":"The user wants me to run a specific command and wait for it to complete. Let me execute it."}}"#,
        #"{"type":"message_update","usage":{"input":1830,"output":102,"cacheRead":0,"cacheWrite":0,"reasoning":23,"totalTokens":1932,"cost":{"input":7.66038e-05,"output":8.53944e-06,"cacheRead":0,"cacheWrite":0,"total":8.514324e-05}},"assistantMessageEvent":{"type":"toolcall_end","contentIndex":1,"toolCall":{"type":"toolCall","id":"call_9726ad99cc114832996228eb","name":"bash","arguments":{"command":"node -e \"console.log('interrupt fixture tool started'); setTimeout(() => {}, 30000)\"","timeout":35}}}}"#,
        #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The user wants me to run a specific command and wait for it to complete. Let me execute it.","thinkingSignature":"<signature>"},{"type":"toolCall","id":"call_9726ad99cc114832996228eb","name":"bash","arguments":{"command":"node -e \"console.log('interrupt fixture tool started'); setTimeout(() => {}, 30000)\"","timeout":35}}],"api":"openai-completions","provider":"openrouter","model":"deepseek/deepseek-v4-flash","usage":{"input":1830,"output":102,"cacheRead":0,"cacheWrite":0,"reasoning":23,"totalTokens":1932,"cost":{"input":7.66038e-05,"output":8.53944e-06,"cacheRead":0,"cacheWrite":0,"total":8.514324e-05}},"stopReason":"toolUse","timestamp":1767225600401,"responseId":"gen-1790898592-Mzq78XbaTGiNE3YSafgy","rawStopReason":"tool_calls","thinkingLevel":"high"}}"#,
        #"{"type":"tool_execution_start","toolCallId":"call_9726ad99cc114832996228eb","toolName":"bash","args":{"command":"node -e \"console.log('interrupt fixture tool started'); setTimeout(() => {}, 30000)\"","timeout":35}}"#,
        #"{"type":"tool_execution_update","toolCallId":"call_9726ad99cc114832996228eb","toolName":"bash","args":{"command":"node -e \"console.log('interrupt fixture tool started'); setTimeout(() => {}, 30000)\"","timeout":35},"partialResult":{"content":[]}}"#,
    ]

    /// What Pi emitted after T3's `abort` in the same scenario.
    static let toolTurnAfterAbort: [String] = [
        #"{"type":"tool_execution_end","toolCallId":"call_9726ad99cc114832996228eb","toolName":"bash","result":{"content":[{"type":"text","text":"Command aborted"}],"details":{}},"isError":true}"#,
        #"{"type":"message_start","message":{"role":"toolResult","toolCallId":"call_9726ad99cc114832996228eb","toolName":"bash","content":[{"type":"text","text":"Command aborted"}],"details":{},"isError":true,"timestamp":1767225602282}}"#,
        #"{"type":"message_end","message":{"role":"toolResult","toolCallId":"call_9726ad99cc114832996228eb","toolName":"bash","content":[{"type":"text","text":"Command aborted"}],"details":{},"isError":true,"timestamp":1767225602282}}"#,
        #"{"type":"turn_end","message":{"role":"assistant","content":[]},"toolResults":[]}"#,
        #"{"type":"turn_start"}"#,
        #"{"type":"message_start","message":{"role":"assistant","content":[],"api":"openai-completions","provider":"openrouter","model":"deepseek/deepseek-v4-flash","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"error","errorMessage":"This operation was aborted","timestamp":1767225602287,"thinkingLevel":"high"}}"#,
        #"{"type":"message_end","message":{"role":"assistant","content":[],"api":"openai-completions","provider":"openrouter","model":"deepseek/deepseek-v4-flash","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"error","errorMessage":"This operation was aborted","timestamp":1767225602287,"thinkingLevel":"high"}}"#,
        #"{"type":"turn_end","message":{"role":"assistant","content":[]},"toolResults":[]}"#,
        #"{"type":"agent_end","messages":[]}"#,
        #"{"type":"agent_settled"}"#,
    ]

    /// The "thread_rollback_after_stop" scenario's command, which printed a line before it was stopped.
    static let streamedCommand: [String] = [
        #"{"type":"tool_execution_start","toolCallId":"call_8ac3cb4177994abdb9aa1c57","toolName":"bash","args":{"command":"node -e \"console.log('interrupt fixture tool started'); setTimeout(() => {}, 30000)\"","timeout":35}}"#,
        #"{"type":"tool_execution_update","toolCallId":"call_8ac3cb4177994abdb9aa1c57","toolName":"bash","args":{"command":"node -e \"console.log('interrupt fixture tool started'); setTimeout(() => {}, 30000)\"","timeout":35},"partialResult":{"content":[]}}"#,
        #"{"type":"tool_execution_update","toolCallId":"call_8ac3cb4177994abdb9aa1c57","toolName":"bash","args":{"command":"node -e \"console.log('interrupt fixture tool started'); setTimeout(() => {}, 30000)\"","timeout":35},"partialResult":{"content":[{"type":"text","text":"interrupt fixture tool started\n"}],"details":{}}}"#,
        #"{"type":"tool_execution_end","toolCallId":"call_8ac3cb4177994abdb9aa1c57","toolName":"bash","result":{"content":[{"type":"text","text":"interrupt fixture tool started\n\n\nCommand aborted"}],"details":{}},"isError":true}"#,
    ]

    /// The "pi_compaction" scenario's manual `/compact` runs: one Pi refused, one that compacted.
    static let refusedCompaction: [String] = [
        #"{"type":"compaction_start","reason":"manual"}"#,
        #"{"type":"compaction_end","reason":"manual","aborted":false,"willRetry":false,"errorMessage":"Compaction failed: Nothing to compact (session too small)"}"#,
    ]

    static let compaction: [String] = [
        #"{"type":"compaction_start","reason":"manual"}"#,
        ###"{"type":"compaction_end","reason":"manual","result":{"summary":"## Goal\nThe user asked the assistant to remember the opaque marker \"compaction-marker-4Z7Q\".","firstKeptEntryId":"70c802be","tokensBefore":1901,"estimatedTokensAfter":1890,"details":{"readFiles":[],"modifiedFiles":[]}},"aborted":false,"willRetry":false}"###,
    ]

    static func parse(_ line: String) -> JSONValue {
        guard let value = JSONValue.parse(line) else { fatalError("Invalid fixture: \(line)") }
        return value
    }
}

/// Stands in for a `pi --mode rpc` process: records what Coincide writes and replies like Pi.
@MainActor
final class FakePiTransport: PiTransport {
    let arguments: [String]
    let environment: [String: String]
    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    var reply: ((JSONValue) -> JSONValue?)?
    private(set) var isRunning = false
    private(set) var written: [JSONValue] = []
    private(set) var inputClosed = false
    private(set) var terminated = false

    init(arguments: [String], environment: [String: String]) {
        self.arguments = arguments
        self.environment = environment
    }

    func start() throws {
        isRunning = true
    }

    func write(_ line: String) {
        guard isRunning, let record = JSONValue.parse(line) else { return }
        written.append(record)
        if let response = reply?(record) { deliverLater(response) }
    }

    func closeInput() {
        inputClosed = true
        Task { self.exit(status: 0) }
    }

    func terminate() {
        terminated = true
        Task { self.exit(status: 15) }
    }

    /// Pi writing a line on stdout.
    func emit(_ line: String) {
        onLine?(line)
    }

    func emit(_ record: JSONValue) {
        onLine?(record.compactJSON)
    }

    func exit(status: Int32, stderr: String = "") {
        guard isRunning else { return }
        isRunning = false
        onExit?(status, stderr)
    }

    func records(_ type: String) -> [JSONValue] {
        written.filter { $0["type"]?.string == type }
    }

    /// Like a real pipe, responses arrive after the write returns.
    private func deliverLater(_ record: JSONValue) {
        Task { self.emit(record) }
    }
}

/// Pi's side of the conversation: answers commands from its own state, one process at a time.
@MainActor
final class FakePi {
    var transports: [FakePiTransport] = []
    var sessionFile = "/fake/pi/sessions/2026-10-27T10-00-00-000Z_first.jsonl"
    var model: JSONValue? = PiFixtures.deepseek
    var thinkingLevel = "high"
    var models: [JSONValue] = [PiFixtures.deepseek, PiFixtures.sonnet]
    var stats: JSONValue = PiFixtures.sessionStats
    var busy = false
    /// Commands answered with `success: false` and this error.
    var rejections: [String: String] = [:]
    /// Commands left unanswered until `answer(_:)`.
    var held: Set<String> = []
    var promptDisposition = "started"
    var cancelSwitch = false
    /// The model a saved session brings back when `switch_session` loads it.
    var resumedModel: JSONValue?

    var current: FakePiTransport { transports[transports.count - 1] }

    func makeTransport(arguments: [String], environment: [String: String]) -> PiTransport {
        let transport = FakePiTransport(arguments: arguments, environment: environment)
        transport.reply = { [unowned self] record in self.response(to: record) }
        transports.append(transport)
        return transport
    }

    func emit(_ lines: [String]) {
        for line in lines { current.emit(line) }
    }

    func sent(_ type: String) -> [JSONValue] {
        transports.flatMap { $0.records(type) }
    }

    /// Answers a held command (the latest of its type) now.
    func answer(_ type: String, data: JSONValue? = nil) {
        guard let id = current.records(type).last?["id"]?.string else { return }
        var response: [String: JSONValue] = ["type": "response", "id": .string(id), "command": .string(type), "success": true]
        if let data { response["data"] = data }
        current.emit(.object(response))
    }

    private func response(to record: JSONValue) -> JSONValue? {
        guard let type = record["type"]?.string, let id = record["id"]?.string, !held.contains(type) else { return nil }
        var response: [String: JSONValue] = ["type": "response", "id": .string(id), "command": .string(type)]
        if let error = rejections[type] {
            response["success"] = false
            response["error"] = .string(error)
            return .object(response)
        }
        response["success"] = true
        switch type {
        case "get_state":
            response["data"] = PiFixtures.state(model: model, sessionFile: sessionFile, thinkingLevel: thinkingLevel, streaming: busy)
        case "get_available_models":
            response["data"] = ["models": .array(models)]
        case "switch_session":
            if !cancelSwitch, let path = record["sessionPath"]?.string {
                sessionFile = path
                model = resumedModel ?? model
            }
            response["data"] = ["cancelled": .bool(cancelSwitch)]
        case "set_model":
            let chosen = models.first {
                $0["provider"]?.string == record["provider"]?.string && $0["id"]?.string == record["modelId"]?.string
            }
            guard let chosen else {
                response["success"] = false
                response["error"] = .string("Model not found: \(record["provider"]?.string ?? "")/\(record["modelId"]?.string ?? "")")
                return .object(response)
            }
            model = chosen
            response["data"] = chosen
        case "set_thinking_level":
            thinkingLevel = record["level"]?.string ?? thinkingLevel
        case "get_session_stats":
            response["data"] = stats
        case "prompt":
            response["data"] = ["disposition": .string(promptDisposition)]
        case "compact":
            response["data"] = ["summary": "Summary", "tokensBefore": 1901, "estimatedTokensAfter": 1890]
        default:
            break
        }
        return .object(response)
    }
}

/// Collects a session's events.
@MainActor
final class PiEventLog {
    private(set) var events: [AgentEvent] = []

    func record(_ event: AgentEvent) {
        events.append(event)
    }

    var completions: [TurnOutcome] {
        events.compactMap { if case .turnCompleted(let outcome) = $0 { outcome } else { nil } }
    }

    var approvals: [ApprovalRequest] {
        events.compactMap { if case .approvalRequested(let request) = $0 { request } else { nil } }
    }

    var notices: [String] {
        events.compactMap { if case .notice(let text) = $0 { text } else { nil } }
    }
}

/// Waits for an asynchronous condition on the main actor.
@MainActor
func eventually(within timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

/// A scratch folder for one test.
func piScratchDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a Pi session file whose header records `workingDirectory`.
func piSessionFile(in directory: URL, workingDirectory: URL) -> String {
    let url = directory.appendingPathComponent("2026-10-27T09-00-00-000Z_saved.jsonl")
    let header = #"{"type":"session","version":3,"id":"saved","timestamp":"2026-10-27T09:00:00.000Z","cwd":"\#(workingDirectory.path)"}"#
    let message = #"{"type":"message","id":"a1b2c3d4","parentId":null,"timestamp":"2026-10-27T09:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"hello"}],"timestamp":1}}"#
    try? (header + "\n" + message + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url.path
}
