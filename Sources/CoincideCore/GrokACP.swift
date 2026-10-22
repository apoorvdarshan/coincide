import Foundation

public enum GrokACPRuntimeMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case approvalRequired = "approval-required", auto, fullAccess = "full-access"
    public var id: String { rawValue }
    public var name: String {
        switch self { case .approvalRequired: "Ask"; case .auto: "Auto"; case .fullAccess: "Always approve" }
    }
}

/// The permission classifier is selected at process launch, independently of
/// the ACP planning/model selectors. Credentials remain in the CLI's own store.
public enum GrokACP {
    public static let initializeMetadata: JSONValue = .object(["clientType": .string("extension")])
    public static let cancellationMetadata: JSONValue = .object(["cancelTrigger": .string("ctrl_c")])
    public static let failureMessage = "The Grok integration response could not be verified safely. Reconnect before continuing."
    public static func runtimeMode(permission: PermissionMode) throws -> GrokACPRuntimeMode {
        switch permission {
        case .supervised: .approvalRequired
        case .auto: .auto
        case .fullAccess: .fullAccess
        case .autoAcceptEdits: throw CoincideError("Grok does not support Auto-accept edits. Choose Ask, Auto, or Always approve.")
        }
    }
    public static func arguments(permission: PermissionMode) throws -> [String] { arguments(runtimeMode: try runtimeMode(permission: permission)) }
    public static func arguments(runtimeMode: GrokACPRuntimeMode) -> [String] {
        switch runtimeMode {
        case .approvalRequired: ["--permission-mode", "default", "agent", "stdio"]
        case .auto: ["--permission-mode", "auto", "agent", "stdio"]
        case .fullAccess: ["agent", "--always-approve", "stdio"]
        }
    }
    static func questionMethod(_ method: String) -> Bool { ["x.ai/ask_user_question", "_x.ai/ask_user_question"].contains(method) }
    static func planMethod(_ method: String) -> Bool { ["x.ai/exit_plan_mode", "_x.ai/exit_plan_mode"].contains(method) }
    static func requestBody(_ params: JSONValue) -> JSONValue { params["params"].object == nil ? params : params["params"] }
    static func failure() -> CoincideError { CoincideError(failureMessage) }
    static func sameID(_ first: String, _ second: String) -> Bool { first.utf8.elementsEqual(second.utf8) }
    static func authenticationMethod(_ initialization: JSONValue) throws -> String {
        let hasAPIKey = ProcessInfo.processInfo.environment["XAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let preferred = hasAPIKey ? "xai.api_key" : "cached_token"
        guard initialization["authMethods"].array?.contains(where: { $0["id"] == .string(preferred) }) == true else {
            throw CoincideError("Grok does not advertise the required noninteractive sign-in method. Sign in with grok login and reconnect.")
        }
        return preferred
    }
    static func metadata(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            let allowed: Set<String> = ["sessionId", "protocolVersion", "models", "currentModelId", "availableModels", "modelId", "modes", "currentModeId", "availableModes", "configOptions", "id", "name", "title", "description", "type", "category", "currentValue", "options", "group", "value", "label", "_meta", "reasoningEffort", "reasoningEffortOptions", "totalContextTokens", "availableCommands", "input", "used", "size", "cost", "amount", "currency"]
            return .object(object.filter { allowed.contains($0.key) }.mapValues(metadata))
        case .array(let values): return .array(values.map(metadata))
        default: return value
        }
    }
    static func id(_ value: JSONValue) throws -> String {
        guard let text = try ACPIntegrationValidation.string(value, maximum: 4_096) else { throw failure() }; return text
    }
    static func safe(_ value: JSONValue, depth: Int = 0) throws -> JSONValue {
        guard depth <= 16 else { throw failure() }
        switch value {
        case .object(let fields):
            guard fields.count <= 256 else { throw failure() }
            var result: [String: JSONValue] = [:]
            for (key, value) in fields {
                let lower = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if ["authorization", "headers", "env", "environment", "password", "apikey", "accesstoken", "refreshtoken", "credential", "credentials", "privatekey"].contains(lower) || lower.contains("credential") || lower.contains("secret") {
                    result[key] = .string("<redacted>")
                } else { result[key] = try safe(value, depth: depth + 1) }
            }
            return .object(result)
        case .array(let values):
            guard values.count <= 1_024 else { throw failure() }; return .array(try values.map { try safe($0, depth: depth + 1) })
        case .string(let text): guard text.utf8.count <= 262_144 else { throw failure() }; return value
        default: return value
        }
    }
    /// Only the native edit-session grant is truly scoped to this session.
    /// Other allow_always rows persist workspace grants and are not relabeled.
    static func permission(_ params: JSONValue) throws -> JSONValue {
        try ACPIntegrationValidation.bound(params)
        guard let options = params["options"].array, options.count <= 64 else { throw failure() }
        var result: [String: JSONValue] = ["sessionId": .string(try id(params["sessionId"])), "toolCall": try safe(params["toolCall"])]
        result["options"] = .array(try options.compactMap { option in
            let kind = try id(option["kind"]), optionID = try id(option["optionId"])
            guard ["allow_once", "reject_once"].contains(kind) || (kind == "allow_always" && optionID == "allow-edits-session") else { return nil }
            return .object(["kind": .string(kind), "optionId": .string(optionID),
                "name": .string(kind == "allow_always" ? "Allow all edits this session" : try id(option["name"]))])
        })
        return .object(result)
    }
}

public struct GrokACPQuestionRequest: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let id: String
        public let label: String
        public let description: String?
        public let preview: String?
    }
    public struct Question: Sendable, Equatable {
        public let id: String
        public let question: String
        public let options: [Option]
        public let multiSelect: Bool
    }
    public let sessionID: String
    public let toolCallID: String
    public let mode: String
    public let questions: [Question]
    public static let cancelledResponse: JSONValue = .object(["outcome": .string("cancelled")])

    public init(params: JSONValue) throws {
        try ACPIntegrationValidation.bound(params)
        if params["params"].object != nil { guard let method = params["method"].string, GrokACP.questionMethod(method) else { throw GrokACP.failure() } }
        let value = GrokACP.requestBody(params)
        sessionID = try GrokACP.id(value["sessionId"]); toolCallID = try GrokACP.id(value["toolCallId"])
        mode = try GrokACP.id(value["mode"])
        guard ["default", "plan"].contains(mode), let entries = value["questions"].array, !entries.isEmpty, entries.count <= 32 else { throw GrokACP.failure() }
        var ids = Set<String>(), texts = Set<String>(), parsed: [Question] = []
        for entry in entries {
            guard let prompt = try ACPIntegrationValidation.string(entry["question"], maximum: 16_384, multiline: true),
                  let options = entry["options"].array, options.count <= 128 else { throw GrokACP.failure() }
            let id = try ACPIntegrationValidation.string(entry["id"], maximum: 4_096) ?? prompt
            guard ids.insert(id).inserted, texts.insert(prompt).inserted else { throw GrokACP.failure() }
            if entry["multiSelect"] != .null, entry["multiSelect"] != .bool(true), entry["multiSelect"] != .bool(false) { throw GrokACP.failure() }
            var optionIDs = Set<String>(), labels = Set<String>(), values: [Option] = []
            for (index, option) in options.enumerated() {
                let optionID = try ACPIntegrationValidation.string(option["id"], maximum: 4_096) ?? "option-\(index)"
                let label = try GrokACP.id(option["label"])
                guard optionIDs.insert(optionID).inserted, labels.insert(label).inserted else { throw GrokACP.failure() }
                values.append(.init(id: optionID, label: label,
                    description: try ACPIntegrationValidation.string(option["description"], maximum: 16_384, multiline: true),
                    preview: try ACPIntegrationValidation.string(option["preview"], maximum: 65_536, multiline: true)))
            }
            parsed.append(.init(id: id, question: prompt, options: values, multiSelect: entry["multiSelect"] == .bool(true)))
        }
        questions = parsed
    }
    public var parameters: JSONValue {
        .object(["sessionId": .string(sessionID), "toolCallId": .string(toolCallID), "mode": .string(mode), "questions": .array(questions.map { question in
            .object(["id": .string(question.id), "question": .string(question.question), "multiSelect": .bool(question.multiSelect), "options": .array(question.options.map { option in
                var value: [String: JSONValue] = ["id": .string(option.id), "label": .string(option.label)]
                if let description = option.description { value["description"] = .string(description) }
                if let preview = option.preview { value["preview"] = .string(preview) }
                return .object(value)
            })])
        })])
    }
    public func response(selections: [String: [String]]) throws -> JSONValue {
        try response(selections: selections, notes: [:])
    }
    public func response(selections: [String: [String]], notes: [String: String]) throws -> JSONValue {
        let known = Set(questions.map(\.id))
        guard Set(selections.keys).union(notes.keys) == known else { throw GrokACP.failure() }
        var answers: [String: JSONValue] = [:], annotations: [String: JSONValue] = [:]
        for question in questions {
            let ids = selections[question.id] ?? []
            let note = notes[question.id]
            let hasNote = note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            guard !ids.isEmpty || hasNote, question.multiSelect || ids.count <= 1, Set(ids).count == ids.count,
                  Set(ids).isSubset(of: Set(question.options.map(\.id))) else { throw GrokACP.failure() }
            let options = question.options.filter { ids.contains($0.id) }
            answers[question.question] = .array(options.isEmpty ? [.string("Other")] : options.map { .string($0.label) })
            var annotation: [String: JSONValue] = [:]
            if !question.multiSelect, let preview = options.first?.preview { annotation["preview"] = .string(preview) }
            if let note, hasNote {
                guard note.utf8.count <= 65_536 else { throw GrokACP.failure() }; annotation["notes"] = .string(note)
            }
            if !annotation.isEmpty { annotations[question.question] = .object(annotation) }
        }
        var result: [String: JSONValue] = ["outcome": .string("accepted"), "answers": .object(answers)]
        if !annotations.isEmpty { result["annotations"] = .object(annotations) }; return .object(result)
    }
    public func response(answers: [String: String]) throws -> JSONValue {
        guard Set(answers.keys) == Set(questions.map(\.id)) else { throw GrokACP.failure() }
        var result: [String: JSONValue] = [:], annotations: [String: JSONValue] = [:]
        for question in questions {
            guard !question.multiSelect, let original = answers[question.id] else { throw GrokACP.failure() }
            let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, original.utf8.count <= 65_536 else { throw GrokACP.failure() }
            if let option = question.options.first(where: { $0.label == text }) {
                result[question.question] = .array([.string(option.label)])
                if let preview = option.preview { annotations[question.question] = .object(["preview": .string(preview)]) }
            } else {
                result[question.question] = .array([.string("Other")]); annotations[question.question] = .object(["notes": .string(original)])
            }
        }
        var value: [String: JSONValue] = ["outcome": .string("accepted"), "answers": .object(result)]
        if !annotations.isEmpty { value["annotations"] = .object(annotations) }; return .object(value)
    }
}

public struct GrokACPOwnedUpdate: Sendable {
    public let runID: UUID
    public let update: ProviderEntityUpdate
}

public struct GrokACPCompletion: Sendable, Equatable {
    public let promptID: String
    public let stopReason: String
    public var response: JSONValue { .object(["stopReason": .string(stopReason)]) }
}

public struct GrokACPObservation: Sendable {
    public var updates: [GrokACPOwnedUpdate] = []
    public var completion: GrokACPCompletion?
}

/// A bounded, transport-local bridge. A task retains its original run after a
/// foreground terminal; wake prompts and child terminals never settle a new run.
public struct GrokACPBridge: Sendable {
    private struct Run: Sendable { let session: String; let run: UUID; var finished = false; var segment = 0 }
    private struct Tool: Sendable { let owner: String; let nativeID: String; var value: JSONValue; var taskID: String? }
    private struct Task: Sendable { let owner: String; let key: ProviderEntityKey; let nativeID: String; let childSessionID: String?; let kind: String; let persistent: Bool; var output = ""; var terminal = false; var status = "in_progress" }
    private var runs: [String: Run] = [:]
    private var order: [String] = []
    private var active: String?
    private var tools: [String: Tool] = [:]
    private var tasks: [String: Task] = [:]
    private var childTasks: [String: String] = [:]
    private var pendingCompletion: [String: GrokACPCompletion] = [:]
    private var observedBytes: [String: Int] = [:]
    private var retainedToolBytes: [String: Int] = [:]
    public init() {}

    public mutating func beginRun(sessionID: String, runID: UUID, promptID: String) throws {
        guard active == nil, runs[promptID] == nil else { throw GrokACP.failure() }
        _ = try GrokACP.id(.string(sessionID)); _ = try GrokACP.id(.string(promptID))
        if order.count >= 128 {
            let retained = Set(tasks.values.filter { !$0.terminal }.map(\.owner))
            for id in order where !retained.contains(id) && runs[id]?.finished == true {
                runs.removeValue(forKey: id); observedBytes.removeValue(forKey: id)
                for key in tools.keys.filter({ tools[$0]?.owner == id }) { tools.removeValue(forKey: key); retainedToolBytes.removeValue(forKey: key) }
            }
            order.removeAll { runs[$0] == nil }
        }
        guard runs.count < 256 else { throw GrokACP.failure() }
        runs[promptID] = .init(session: sessionID, run: runID); order.append(promptID); active = promptID
    }
    public mutating func finishRun(promptID: String) {
        runs[promptID]?.finished = true
        // Tool snapshots already live in the durable entity projection. Retain
        // only routing/state fields needed for a late native task mutation.
        for key in tools.keys.filter({ tools[$0]?.owner == promptID }) {
            guard var tool = tools[key] else { continue }
            var fields = tool.value.object ?? [:]
            fields.removeValue(forKey: "content")
            fields["rawInput"] = .object((fields["rawInput"]?.object ?? [:]).filter { ["variant", "persistent", "task_id", "taskId", "task_ids"].contains($0.key) })
            fields["rawOutput"] = .object((fields["rawOutput"]?.object ?? [:]).filter { ["type", "task_id", "taskId", "persistent"].contains($0.key) })
            tool.value = .object(fields); tools[key] = tool
            retainedToolBytes[key] = (try? JSONEncoder().encode(tool.value).count) ?? 0
        }
        pendingCompletion.removeValue(forKey: promptID)
        if active == promptID { active = nil }
    }
    public mutating func reset() { self = .init() }
    public mutating func acceptCompletion(promptID: String, stopReason: String) throws -> GrokACPCompletion? {
        guard promptID == active, runs[promptID]?.finished == false else { return nil }
        guard ["end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled", "error", "rate_limit"].contains(stopReason) else { throw GrokACP.failure() }
        let completion = GrokACPCompletion(promptID: promptID, stopReason: stopReason)
        if stopReason != "cancelled", stopReason != "error", stopReason != "rate_limit",
           tasks.values.contains(where: { $0.owner == promptID && !$0.terminal && !$0.persistent }) {
            pendingCompletion[promptID] = completion; return nil
        }
        pendingCompletion.removeValue(forKey: promptID); return completion
    }
    private mutating func releasedCompletion() throws -> GrokACPCompletion? {
        guard let active, let pending = pendingCompletion[active] else { return nil }
        return try acceptCompletion(promptID: active, stopReason: pending.stopReason)
    }
    private func wireKey(_ session: String, _ id: String) -> String { Data((session + "\0" + id).utf8).base64EncodedString() }
    private func entityKey(_ run: Run, _ type: String, _ id: String, session: String? = nil) -> ProviderEntityKey {
        .init(sessionID: session ?? run.session, type: type, id: "grok:\(run.run):\(id)")
    }
    private mutating func account(_ text: String, owner: String) throws {
        let previous = observedBytes[owner, default: 0]
        guard text.utf8.count <= 4_194_304 - previous else { throw GrokACP.failure() }; observedBytes[owner] = previous + text.utf8.count
    }
    private func prompt(_ params: JSONValue) -> String? {
        params["_meta"]["promptId"].string ?? params["_meta"]["requestId"].string ?? params["update"]["prompt_id"].string ?? params["update"]["promptId"].string
    }
    private func owner(session: String, prompt: String?, tool: String? = nil) -> String? {
        if let child = tasks.values.first(where: { $0.childSessionID.map { GrokACP.sameID($0, session) } == true && !$0.terminal }) {
            return child.owner
        }
        if let prompt {
            if let expected = runs[prompt]?.session, GrokACP.sameID(expected, session) { return prompt }
            for prefix in ["task-completed-", "subagent-completed-"] where prompt.hasPrefix(prefix) {
                let native = String(prompt.dropFirst(prefix.count))
                if let task = tasks[wireKey(session, native)] { return task.owner }
                if let taskID = childTasks[wireKey(session, native)], let task = tasks[taskID] { return task.owner }
            }
            return nil
        }
        if let tool, let known = tools[wireKey(session, tool)] { return known.owner }
        if let active, let expected = runs[active]?.session, GrokACP.sameID(expected, session) { return active }; return nil
    }

    public mutating func consume(method: String, params: JSONValue) throws -> GrokACPObservation {
        try ACPIntegrationValidation.bound(params)
        var result = GrokACPObservation()
        let completionMethods = ["x.ai/session/prompt_complete", "_x.ai/session/prompt_complete"]
        let sessionMethods = ["x.ai/session_notification", "_x.ai/session_notification", "_x.ai/session/update"]
        if completionMethods.contains(method) || (sessionMethods.contains(method) && params["update"]["sessionUpdate"] == .string("turn_completed")) {
            let session = try GrokACP.id(params["sessionId"])
            let id = completionMethods.contains(method) ? params["promptId"].string : prompt(params)
            // Never session-fallback a completion with no exact correlation.
            guard let id, id == active, let expected = runs[id]?.session, GrokACP.sameID(expected, session), runs[id]?.finished == false else { return result }
            let value = completionMethods.contains(method) ? params["stopReason"] : params["update"]["stop_reason"] == .null ? params["update"]["stopReason"] : params["update"]["stop_reason"]
            guard let reason = value.string, ["end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled", "error", "rate_limit"].contains(reason) else { throw GrokACP.failure() }
            result.completion = try acceptCompletion(promptID: id, stopReason: reason); return result
        }
        if ["x.ai/task_backgrounded", "_x.ai/task_backgrounded", "x.ai/task_completed", "_x.ai/task_completed"].contains(method) {
            let session = try GrokACP.id(params["sessionId"]), update = params["update"], snapshot = params["update"]["task_snapshot"]
            let native = try GrokACP.id(snapshot["task_id"] == .null ? update["task_id"] == .null ? update["tool_call_id"] : update["task_id"] : snapshot["task_id"])
            let key = wireKey(session, native)
            guard let task = tasks[key], runs[task.owner]?.session == session else { return result }
            let completed = method.hasSuffix("task_completed")
            let failed = completed && snapshot["exit_code"].grokNumber.map { $0 != 0 } == true
            result.updates = try mutateTask(key, status: completed ? failed ? "failed" : "completed" : "in_progress", output: snapshot["output"].string, replace: true)
            result.completion = try releasedCompletion()
            return result
        }
        if sessionMethods.contains(method), params["update"]["sessionUpdate"] == .string("subagent_finished") {
            let session = try GrokACP.id(params["sessionId"]), update = params["update"]
            let child = try GrokACP.id(update["child_session_id"])
            guard let key = childTasks[wireKey(session, child)], let task = tasks[key], runs[task.owner]?.session == session,
                  let status = update["status"].string, ["completed", "failed", "cancelled"].contains(status) else { return result }
            result.updates = try mutateTask(key, status: status == "cancelled" ? "interrupted" : status,
                output: status == "completed" ? update["output"].string : nil, replace: true)
            result.completion = try releasedCompletion()
            return result
        }
        guard method == "session/update" else { return result }
        let session = try GrokACP.id(params["sessionId"]), update = params["update"], kind = update["sessionUpdate"].string ?? ""
        let nativeTool = update["toolCallId"].string
        guard let owner = owner(session: session, prompt: prompt(params), tool: nativeTool), var run = runs[owner] else { return result }
        if ["tool_call", "tool_call_update"].contains(kind), let nativeTool {
            let lookup = wireKey(session, nativeTool)
            if let known = tools[lookup], known.owner != owner { return result }
            if kind == "tool_call", tools[lookup] == nil { run.segment += 1; runs[owner] = run }
            var fields = tools[lookup]?.value.object ?? [:]
            for (key, value) in update.object ?? [:] where value != .null && ["toolCallId", "title", "kind", "status", "rawInput", "rawOutput", "content"].contains(key) { fields[key] = try GrokACP.safe(value) }
            try account(String(decoding: try JSONEncoder().encode(update), as: UTF8.self), owner: owner)
            guard tools.count < 4_096 || tools[lookup] != nil else { throw GrokACP.failure() }
            var tool = tools[lookup] ?? .init(owner: owner, nativeID: nativeTool, value: .object([:]))
            if let task = tool.taskID.flatMap({ tasks[$0] }), task.terminal { return result }
            tool.value = .object(fields)
            let retained = try JSONEncoder().encode(tool.value).count
            guard retained <= 8_388_608 - retainedToolBytes.values.reduce(0, +) + retainedToolBytes[lookup, default: 0] else { throw GrokACP.failure() }
            retainedToolBytes[lookup] = retained
            let raw = tool.value["rawOutput"], input = tool.value["rawInput"]
            var title = fields["title"]?.string ?? "Grok tool"
            if ["Tool", "Tool call", "Terminal", "Grok tool"].contains(title) { title = input["description"].string ?? input["command"].string ?? input["variant"].string ?? title }
            let isMonitor = raw["type"] == .string("Monitor") || input["variant"].string?.lowercased() == "monitor"
            let background = raw["type"] == .string("BackgroundTaskStarted") || isMonitor
            let output = try outputText(raw, content: fields["content"] ?? .null)
            let child = childID(output)
            let childSpawn = ["task", "spawn_subagent", "cursortask"].contains(title.lowercased()) || ["task", "spawn_subagent", "cursortask"].contains(input["variant"].string?.lowercased() ?? "") || input["subagent_type"] != .null
            let nativeTask = background ? raw["task_id"].string ?? raw["taskId"].string : childSpawn ? child : nil
            let entity = entityKey(run, "tool_call", nativeTool, session: session)
            if let nativeTask {
                let taskKey = wireKey(session, nativeTask)
                if tasks[taskKey] == nil {
                    guard tasks.count < 256 else { throw GrokACP.failure() }
                    tasks[taskKey] = .init(owner: owner, key: entity, nativeID: nativeTask, childSessionID: childSpawn ? child : nil, kind: childSpawn ? "subagent" : isMonitor ? "monitor" : "shell", persistent: input["persistent"] == .bool(true) || raw["persistent"] == .bool(true))
                }
                guard tasks[taskKey]?.owner == owner else { throw GrokACP.failure() }
                tool.taskID = taskKey
                if let child, childSpawn { childTasks[wireKey(session, child)] = taskKey }
            }
            var retainedFields = tool.value.object ?? [:]; retainedFields["title"] = .string(String(title.prefix(4_096)))
            tool.value = .object(retainedFields); tools[lookup] = tool
            var safe: [String: JSONValue] = ["title": .string(String(title.prefix(4_096))), "kind": fields["kind"] ?? .string("other"),
                "status": background || (childSpawn && child != nil) ? .string("in_progress") : fields["status"] ?? .string("pending"),
                "_meta": metadata(run, prompt: owner, task: nativeTask, child: child)]
            if fields["rawInput"] != nil { safe["rawInput"] = try GrokACP.safe(input) }
            if let output { try account(output, owner: owner); safe["content"] = content(output) }
            else if fields["content"] != nil { safe["content"] = try GrokACP.safe(fields["content"]!) }
            if let taskID = tool.taskID, let task = tasks[taskID], task.terminal {
                safe["status"] = .string(task.status)
                if !task.output.isEmpty { safe["content"] = content(task.output) }
            }
            result.updates.append(.init(runID: run.run, update: .patch(entity, .object(safe))))
            if raw["type"] == .string("TaskOutput") || raw["type"] == .string("KillTask") {
                let values = raw["MultiResult"]["results"].array ?? [raw["Result"]]
                for value in values {
                    guard let id = value["task_id"].string, let task = tasks[wireKey(session, id)], runs[task.owner]?.session == session else { continue }
                    let status: String?
                    if raw["type"] == .string("KillTask") { status = fields["status"] == .string("completed") && ["killed", "already_exited"].contains(value["outcome"].string ?? "") ? "interrupted" : nil }
                    else { status = taskStatus(value) }
                    if let status { result.updates += try mutateTask(wireKey(session, id), status: status, output: value["output"].string, replace: true) }
                }
            }
            result.completion = try releasedCompletion()
            return result
        }
        guard owner == active || prompt(params) != nil else { return result }
        if ["agent_message_chunk", "agent_thought_chunk"].contains(kind) {
            guard let text = update["content"]["text"].string, update["content"]["type"] == .string("text") else { return result }
            try account(text, owner: owner)
            let key = entityKey(run, kind == "agent_message_chunk" ? "agent_message" : "agent_thought", "\(run.segment):\(update["messageId"].string ?? "message")", session: session)
            result.updates.append(.init(runID: run.run, update: .content(key, field: "content", value: .object(["type": .string("text"), "text": .string(text)]), annotation: nil)))
        } else if kind == "plan" {
            let key = entityKey(run, "plan", "plan")
            result.updates.append(.init(runID: run.run, update: .patch(key, .object(["entries": try GrokACP.safe(update["entries"]), "_meta": metadata(run, prompt: owner)]))))
        }
        return result
    }
    private func content(_ text: String) -> JSONValue { .array([.object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string(text)])])]) }
    private func metadata(_ run: Run, prompt: String, task: String? = nil, child: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["sessionID": .string(run.session), "runID": .string(run.run.uuidString), "promptID": .string(prompt)]
        if let task { fields["taskID"] = .string(task) }; if let child { fields["childSessionID"] = .string(child) }
        return .object(["x.ai": .object(fields)])
    }
    private mutating func mutateTask(_ key: String, status: String, output: String?, replace: Bool) throws -> [GrokACPOwnedUpdate] {
        guard var task = tasks[key], !task.terminal, let run = runs[task.owner] else { return [] }
        if let output {
            try account(output, owner: task.owner)
            let count = replace ? output.utf8.count : task.output.utf8.count + output.utf8.count
            guard count <= 8_388_608 - tasks.values.reduce(0, { $0 + $1.output.utf8.count }) + task.output.utf8.count else { throw GrokACP.failure() }
            task.output = replace ? output : task.output + output
        }
        task.terminal = status != "in_progress"; task.status = status; tasks[key] = task
        var fields: [String: JSONValue] = ["status": .string(status), "_meta": metadata(run, prompt: task.owner, task: task.nativeID, child: task.childSessionID)]
        if !task.output.isEmpty { fields["content"] = content(task.output) }
        if task.terminal { tasks[key]?.output = "" }
        return [.init(runID: run.run, update: .patch(task.key, .object(fields)))]
    }
    private func taskStatus(_ value: JSONValue) -> String? {
        switch value["status"].string?.lowercased() {
        case "running", "pending": "in_progress"
        case "completed", "success", "succeeded": "completed"
        case "failed", "error": "failed"
        case "stopped", "cancelled", "killed": "interrupted"
        default: value["exit_code"].grokNumber.map { $0 == 0 ? "completed" : "failed" }
        }
    }
    private func outputText(_ raw: JSONValue, content: JSONValue) throws -> String? {
        if let text = raw.string { return text }
        if let text = raw["text"].string ?? raw["output_for_prompt"].string ?? raw["output"].string ?? raw["Result"]["output"].string ?? raw["result"]["output"].string { return text }
        if let bytes = raw["output"].array, bytes.count <= 262_144 {
            let values = bytes.compactMap { value -> UInt8? in guard let number = value.grokNumber else { return nil }; return UInt8(exactly: number) }
            guard values.count == bytes.count, let text = String(bytes: values, encoding: .utf8) else { throw GrokACP.failure() }; return text
        }
        let texts = content.array?.compactMap { $0["content"]["text"].string ?? $0["text"].string } ?? []
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
    private func childID(_ text: String?) -> String? {
        guard let text, let expression = try? NSRegularExpression(pattern: #"(?:Agent ID:|subagent_id:|===\s*Task)\s*([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})"#, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

private extension JSONValue {
    var grokNumber: Double? { if case .number(let value) = self, value.isFinite { value } else { nil } }
}
