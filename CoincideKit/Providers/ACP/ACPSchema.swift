import Foundation

// Typed views of the Agent Client Protocol messages Coincide reads and writes. They parse the
// stable v1 wire format and tolerate the v2 preview shapes that some agents already send.

public struct ACPImplementation: Sendable, Hashable {
    public var name: String
    public var title: String?
    public var version: String?

    nonisolated init?(json: JSONValue?) {
        guard let json, let name = json["name"]?.string else { return nil }
        self.name = name
        title = json["title"]?.string
        version = json["version"]?.string
    }
}

public struct ACPAuthMethod: Sendable, Hashable {
    public var id: String
    public var name: String
    public var description: String?
    /// `agent` (or nil) when the agent signs in by itself; `terminal` and `env_var` need the user.
    public var type: String?

    nonisolated init?(json: JSONValue) {
        guard let id = json["id"]?.string ?? json["methodId"]?.string else { return nil }
        self.id = id
        name = json["name"]?.string ?? id
        description = json["description"]?.string
        type = json["type"]?.string
    }
}

public struct ACPClientCapabilities: Sendable, Hashable {
    public var readTextFile: Bool
    public var writeTextFile: Bool
    public var terminal: Bool

    public nonisolated init(readTextFile: Bool = false, writeTextFile: Bool = false, terminal: Bool = false) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
        self.terminal = terminal
    }

    nonisolated var json: JSONValue {
        ["fs": ["readTextFile": .bool(readTextFile), "writeTextFile": .bool(writeTextFile)], "terminal": .bool(terminal)]
    }
}

/// The agent's answer to `initialize`.
public struct ACPInitializeResult: Sendable, Hashable {
    public var protocolVersion: Int
    /// 2 when the agent answered with the v2 preview shape, otherwise 1. Antigravity reports
    /// version 2 with the v1 shape, so the shape decides, not the number.
    public var generation: Int
    public var agentInfo: ACPImplementation?
    public var loadSession: Bool
    public var resumeSession: Bool
    public var promptImage: Bool
    public var promptAudio: Bool
    public var promptEmbeddedContext: Bool
    public var authMethods: [ACPAuthMethod]
    public var meta: JSONValue?

    public nonisolated init(json: JSONValue) {
        protocolVersion = json["protocolVersion"]?.int ?? 1
        authMethods = json["authMethods"]?.array?.compactMap(ACPAuthMethod.init(json:)) ?? []
        meta = json["_meta"]
        if json["info"] != nil || json["capabilities"] != nil {
            generation = 2
            agentInfo = ACPImplementation(json: json["info"])
            let session = json.at("capabilities.session")
            loadSession = session != nil && session?.isNull == false
            resumeSession = loadSession
            let prompt = session?["prompt"]
            promptImage = prompt?["image"].map { !$0.isNull } ?? false
            promptAudio = prompt?["audio"].map { !$0.isNull } ?? false
            promptEmbeddedContext = prompt?["embeddedContext"].map { !$0.isNull } ?? false
        } else {
            generation = 1
            agentInfo = ACPImplementation(json: json["agentInfo"])
            let capabilities = json["agentCapabilities"]
            loadSession = capabilities?["loadSession"]?.bool ?? false
            resumeSession = capabilities?.at("sessionCapabilities.resume").map { !$0.isNull } ?? false
            promptImage = capabilities?.at("promptCapabilities.image")?.bool ?? false
            promptAudio = capabilities?.at("promptCapabilities.audio")?.bool ?? false
            promptEmbeddedContext = capabilities?.at("promptCapabilities.embeddedContext")?.bool ?? false
        }
    }

    /// Grok publishes its model catalog (with per-model `_meta`) on `initialize`.
    public nonisolated var modelState: ACPModelState? { meta?["modelState"].flatMap(ACPModelState.init(json:)) }
}

public struct ACPSessionMode: Sendable, Hashable {
    public var id: String
    public var name: String
    public var description: String?
}

public struct ACPModeState: Sendable, Hashable {
    public var currentModeID: String
    public var availableModes: [ACPSessionMode]

    nonisolated init?(json: JSONValue) {
        guard let current = json["currentModeId"]?.string else { return nil }
        currentModeID = current
        availableModes = json["availableModes"]?.array?.compactMap { mode in
            guard let id = mode["id"]?.string else { return nil }
            return ACPSessionMode(id: id, name: mode["name"]?.string ?? id, description: mode["description"]?.string)
        } ?? []
    }

    nonisolated init(currentModeID: String, availableModes: [ACPSessionMode]) {
        self.currentModeID = currentModeID
        self.availableModes = availableModes
    }
}

/// One entry of the legacy (unstable v1) model list, still used by Grok.
public struct ACPModelInfo: Sendable, Hashable {
    public var modelID: String
    public var name: String
    public var description: String?
    public var meta: JSONValue?
}

public struct ACPModelState: Sendable, Hashable {
    public var currentModelID: String
    public var availableModels: [ACPModelInfo]

    nonisolated init?(json: JSONValue) {
        guard let current = json["currentModelId"]?.string, let models = json["availableModels"]?.array else { return nil }
        currentModelID = current
        availableModels = models.compactMap { model in
            guard let id = model["modelId"]?.string else { return nil }
            return ACPModelInfo(
                modelID: id, name: model["name"]?.string ?? id, description: model["description"]?.string,
                meta: model["_meta"])
        }
    }
}

public struct ACPConfigChoice: Sendable, Hashable {
    public var value: String
    public var name: String
    public var description: String?
}

/// A session configuration option such as the model, mode or reasoning level.
public struct ACPConfigOption: Sendable, Hashable {
    public enum Value: Sendable, Hashable {
        case select(current: String, choices: [ACPConfigChoice])
        case boolean(Bool)
    }

    public var id: String
    public var name: String
    public var category: String?
    public var value: Value

    nonisolated init?(json: JSONValue) {
        guard let id = json["id"]?.string ?? json["configId"]?.string else { return nil }
        self.id = id
        name = json["name"]?.string ?? id
        category = json["category"]?.string
        switch json["type"]?.string {
        case "boolean":
            value = .boolean(json["currentValue"]?.bool ?? false)
        default:
            guard let current = json["currentValue"]?.string else { return nil }
            value = .select(current: current, choices: Self.flattenChoices(json["options"]?.array ?? []))
        }
    }

    public nonisolated var currentValue: String? {
        if case .select(let current, _) = value { return current }
        return nil
    }

    public nonisolated var choices: [ACPConfigChoice] {
        if case .select(_, let choices) = value { return choices }
        return []
    }

    /// Groups nest their choices; flatten them.
    private nonisolated static func flattenChoices(_ entries: [JSONValue]) -> [ACPConfigChoice] {
        entries.flatMap { entry -> [ACPConfigChoice] in
            if let nested = entry["options"]?.array { return flattenChoices(nested) }
            guard let value = entry["value"]?.string else { return [] }
            return [ACPConfigChoice(value: value, name: entry["name"]?.string ?? value, description: entry["description"]?.string)]
        }
    }
}

/// What `session/new`, `session/load` and `session/resume` return.
public struct ACPSessionSetup: Sendable, Hashable {
    public var sessionID: String?
    public var modes: ACPModeState?
    public var models: ACPModelState?
    public var configOptions: [ACPConfigOption]
    public var meta: JSONValue?

    public nonisolated init(json: JSONValue) {
        sessionID = json["sessionId"]?.string
        modes = json["modes"].flatMap(ACPModeState.init(json:))
        models = json["models"].flatMap(ACPModelState.init(json:))
        configOptions = json["configOptions"]?.array?.compactMap(ACPConfigOption.init(json:)) ?? []
        meta = json["_meta"]
    }

    public nonisolated init() {
        configOptions = []
    }

    public nonisolated var modelOption: ACPConfigOption? { option(category: "model", fallbackID: "model") }
    public nonisolated var reasoningOption: ACPConfigOption? {
        option(category: "thought_level", fallbackID: "reasoning_effort")
    }
    public nonisolated var modeOption: ACPConfigOption? { option(category: "mode", fallbackID: "mode") }

    /// Modes from the dedicated field, or from a `mode` config option.
    public nonisolated var effectiveModes: ACPModeState? {
        if let modes { return modes }
        guard let option = modeOption, let current = option.currentValue else { return nil }
        return ACPModeState(
            currentModeID: current,
            availableModes: option.choices.map { ACPSessionMode(id: $0.value, name: $0.name, description: $0.description) })
    }

    public nonisolated var currentModelID: String? { modelOption?.currentValue ?? models?.currentModelID }

    private nonisolated func option(category: String, fallbackID: String) -> ACPConfigOption? {
        configOptions.first { $0.category == category && $0.currentValue != nil }
            ?? configOptions.first { $0.id == fallbackID && $0.currentValue != nil }
    }
}

public enum ACPContentBlock: Sendable, Hashable {
    case text(String)
    case image(mimeType: String, data: String?, uri: String?)
    case audio(mimeType: String, data: String?)
    case resourceLink(uri: String, name: String?, title: String?, description: String?)
    case resource(uri: String?, text: String?, mimeType: String?)
    case unknown(String)

    public nonisolated init(json: JSONValue) {
        switch json["type"]?.string {
        case "text":
            self = .text(json["text"]?.string ?? "")
        case "image":
            self = .image(mimeType: json["mimeType"]?.string ?? "", data: json["data"]?.string, uri: json["uri"]?.string)
        case "audio":
            self = .audio(mimeType: json["mimeType"]?.string ?? "", data: json["data"]?.string)
        case "resource_link":
            self = .resourceLink(
                uri: json["uri"]?.string ?? "", name: json["name"]?.string, title: json["title"]?.string,
                description: json["description"]?.string)
        case "resource":
            let resource = json["resource"]
            self = .resource(uri: resource?["uri"]?.string, text: resource?["text"]?.string, mimeType: resource?["mimeType"]?.string)
        case let type:
            self = .unknown(type ?? "")
        }
    }

    public nonisolated var json: JSONValue {
        switch self {
        case .text(let text):
            return ["type": "text", "text": .string(text)]
        case .image(let mimeType, let data, let uri):
            var object: [String: JSONValue] = ["type": "image", "mimeType": .string(mimeType)]
            if let data { object["data"] = .string(data) }
            if let uri { object["uri"] = .string(uri) }
            return .object(object)
        case .audio(let mimeType, let data):
            return ["type": "audio", "mimeType": .string(mimeType), "data": .string(data ?? "")]
        case .resourceLink(let uri, let name, let title, let description):
            var object: [String: JSONValue] = ["type": "resource_link", "uri": .string(uri), "name": .string(name ?? uri)]
            if let title { object["title"] = .string(title) }
            if let description { object["description"] = .string(description) }
            return .object(object)
        case .resource(let uri, let text, let mimeType):
            var resource: [String: JSONValue] = ["uri": .string(uri ?? "")]
            if let text { resource["text"] = .string(text) }
            if let mimeType { resource["mimeType"] = .string(mimeType) }
            return ["type": "resource", "resource": .object(resource)]
        case .unknown(let type):
            return ["type": .string(type)]
        }
    }

    /// Text to show for the block, or nil when it carries nothing readable.
    public nonisolated var displayText: String? {
        switch self {
        case .text(let text): return text
        case .resourceLink(let uri, let name, let title, let description):
            let label = title ?? name ?? uri
            return description.map { "\(label): \($0)" } ?? label
        case .resource(let uri, let text, _): return text ?? uri
        case .image, .audio, .unknown: return nil
        }
    }
}

public enum ACPToolCallContent: Sendable, Hashable {
    case content(ACPContentBlock)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(id: String)
    case unknown(String)

    public nonisolated init(json: JSONValue) {
        switch json["type"]?.string {
        case "content":
            self = .content(ACPContentBlock(json: json["content"] ?? .null))
        case "diff":
            self = .diff(path: json["path"]?.string ?? "", oldText: json["oldText"]?.string, newText: json["newText"]?.string ?? "")
        case "terminal":
            self = .terminal(id: json["terminalId"]?.string ?? "")
        case let type:
            self = .unknown(type ?? "")
        }
    }
}

/// The fields of a `tool_call` or `tool_call_update`. Only fields present on the wire are set.
public struct ACPToolCallUpdate: Sendable, Hashable {
    public var id: String
    public var title: String?
    public var kind: String?
    public var status: String?
    public var content: [ACPToolCallContent]?
    public var locations: [String]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?
    public var meta: JSONValue?

    public nonisolated init(
        id: String, title: String? = nil, kind: String? = nil, status: String? = nil,
        content: [ACPToolCallContent]? = nil, locations: [String]? = nil, rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil, meta: JSONValue? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.meta = meta
    }

    public nonisolated init?(json: JSONValue) {
        guard let id = json["toolCallId"]?.string, !id.isEmpty else { return nil }
        self.init(
            id: id, title: json["title"]?.string, kind: json["kind"]?.string, status: json["status"]?.string,
            content: json["content"]?.array?.map(ACPToolCallContent.init(json:)),
            locations: json["locations"]?.array?.compactMap { $0["path"]?.string },
            rawInput: json["rawInput"].flatMap { $0.isNull ? nil : $0 },
            rawOutput: json["rawOutput"].flatMap { $0.isNull ? nil : $0 },
            meta: json["_meta"].flatMap { $0.isNull ? nil : $0 })
    }
}

public struct ACPPlanEntry: Sendable, Hashable {
    public var content: String
    /// `pending`, `in_progress` or `completed`.
    public var status: String
}

public struct ACPAvailableCommand: Sendable, Hashable {
    public var name: String
    public var description: String
}

public enum ACPSessionUpdate: Sendable, Hashable {
    case userMessageChunk
    case agentMessageChunk(ACPContentBlock, messageID: String?)
    case agentThoughtChunk(ACPContentBlock, messageID: String?)
    /// A tool call the agent announces for the first time.
    case toolCall(ACPToolCallUpdate)
    case toolCallUpdate(ACPToolCallUpdate)
    case plan([ACPPlanEntry])
    case availableCommands([ACPAvailableCommand])
    case currentMode(String)
    case configOptions([ACPConfigOption])
    /// Tokens in context, the context window, and the cumulative cost when known.
    case usage(used: Int, size: Int, costUSD: Double?)
    /// ACP v2 reports the end of a prompt as a state change.
    case idle(stopReason: String?, error: ACPError?)
    case notice(title: String, description: String?)
    case other(String)

    public nonisolated init(json: JSONValue) {
        let kind = json["sessionUpdate"]?.string ?? ""
        switch kind {
        case "user_message_chunk", "user_message":
            self = .userMessageChunk
        case "agent_message_chunk", "agent_message":
            self = .agentMessageChunk(Self.content(json), messageID: json["messageId"]?.string)
        case "agent_thought_chunk", "agent_thought":
            self = .agentThoughtChunk(Self.content(json), messageID: json["messageId"]?.string)
        case "tool_call":
            self = ACPToolCallUpdate(json: json).map(Self.toolCall) ?? .other(kind)
        case "tool_call_update":
            self = ACPToolCallUpdate(json: json).map(Self.toolCallUpdate) ?? .other(kind)
        case "plan":
            self = .plan(Self.planEntries(json["entries"]?.array ?? []))
        case "plan_update":
            self = .plan(Self.planEntries(json.at("plan.entries")?.array ?? []))
        case "available_commands_update":
            self = .availableCommands(
                json["availableCommands"]?.array?.compactMap { command in
                    command["name"]?.string.map { ACPAvailableCommand(name: $0, description: command["description"]?.string ?? "") }
                } ?? [])
        case "current_mode_update":
            self = .currentMode(json["currentModeId"]?.string ?? "")
        case "config_option_update":
            self = .configOptions(json["configOptions"]?.array?.compactMap(ACPConfigOption.init(json:)) ?? [])
        case "usage_update":
            let cost = json["cost"]
            let usd = cost?["currency"]?.string?.uppercased() == "USD" ? cost?["amount"]?.number : nil
            self = .usage(used: json["used"]?.int ?? 0, size: json["size"]?.int ?? 0, costUSD: usd)
        case "state_update" where json["state"]?.string == "idle":
            self = .idle(stopReason: json["stopReason"]?.string, error: json["error"].flatMap(ACPError.init(json:)))
        case "notice":
            self = .notice(title: json["title"]?.string ?? "", description: json["description"]?.string)
        default:
            self = .other(kind)
        }
    }

    /// v1 chunks carry one block; v2 messages carry a list.
    private nonisolated static func content(_ json: JSONValue) -> ACPContentBlock {
        if let blocks = json["content"]?.array {
            return .text(blocks.compactMap { ACPContentBlock(json: $0).displayText }.joined())
        }
        return ACPContentBlock(json: json["content"] ?? .null)
    }

    private nonisolated static func planEntries(_ entries: [JSONValue]) -> [ACPPlanEntry] {
        entries.compactMap { entry in
            guard let content = entry["content"]?.string else { return nil }
            return ACPPlanEntry(content: content, status: entry["status"]?.string ?? "pending")
        }
    }
}

/// A `session/update` notification.
public struct ACPSessionNotification: Sendable, Hashable {
    public var sessionID: String
    public var update: ACPSessionUpdate
    /// The notification's `_meta` (Grok puts token counts and prompt ids here).
    public var meta: JSONValue?

    public nonisolated init?(params: JSONValue) {
        guard let sessionID = params["sessionId"]?.string, let update = params["update"] else { return nil }
        self.sessionID = sessionID
        self.update = ACPSessionUpdate(json: update)
        meta = params["_meta"]
    }
}

public struct ACPPermissionOption: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case allowOnce = "allow_once"
        case allowAlways = "allow_always"
        case rejectOnce = "reject_once"
        case rejectAlways = "reject_always"
    }

    public var id: String
    public var name: String
    public var kind: Kind?
    public var meta: JSONValue?

    public nonisolated var isAllow: Bool { kind == .allowOnce || kind == .allowAlways }
}

/// A `session/request_permission` request.
public struct ACPPermissionRequest: Sendable, Hashable {
    public var sessionID: String
    public var toolCall: ACPToolCallUpdate
    public var options: [ACPPermissionOption]
    /// v2 requests carry their own title.
    public var title: String?

    public nonisolated init?(params: JSONValue, requestID: String) {
        guard let sessionID = params["sessionId"]?.string else { return nil }
        self.sessionID = sessionID
        title = params["title"]?.string
        if let toolCall = params["toolCall"].flatMap(ACPToolCallUpdate.init(json:)) {
            self.toolCall = toolCall
        } else if let subject = params["subject"] {
            let command = subject["type"]?.string == "command"
            self.toolCall = subject["toolCall"].flatMap(ACPToolCallUpdate.init(json:))
                ?? ACPToolCallUpdate(
                    id: subject["toolCallId"]?.string ?? requestID, title: title, kind: command ? "execute" : "other",
                    rawInput: subject["command"].map { .object(["command": $0]) })
        } else {
            return nil
        }
        options = params["options"]?.array?.compactMap { option in
            guard let id = option["optionId"]?.string else { return nil }
            return ACPPermissionOption(
                id: id, name: option["name"]?.string ?? id, kind: option["kind"]?.string.flatMap(ACPPermissionOption.Kind.init(rawValue:)),
                meta: option["_meta"])
        } ?? []
    }

    public nonisolated func option(_ kind: ACPPermissionOption.Kind) -> ACPPermissionOption? {
        options.first { $0.kind == kind && !$0.id.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// The result of `session/prompt`.
public struct ACPPromptResult: Sendable, Hashable {
    public var stopReason: String
    public var usage: JSONValue?
    public var meta: JSONValue?

    public nonisolated init(stopReason: String, usage: JSONValue? = nil, meta: JSONValue? = nil) {
        self.stopReason = stopReason
        self.usage = usage
        self.meta = meta
    }

    nonisolated init(json: JSONValue) {
        self.init(stopReason: json["stopReason"]?.string ?? "end_turn", usage: json["usage"], meta: json["_meta"])
    }
}
