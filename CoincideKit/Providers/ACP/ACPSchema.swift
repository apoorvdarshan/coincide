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
    /// A `terminal` method's arguments, added to the agent's own, and environment.
    public var arguments: [String]
    public var environment: [String: String]
    /// The variables an `env_var` method reads, such as an API key.
    public var variables: [String]
    /// Where an `env_var` method's key comes from.
    public var link: URL?

    nonisolated init?(json: JSONValue) {
        guard let id = json["id"]?.string ?? json["methodId"]?.string else { return nil }
        self.id = id
        name = json["name"]?.string ?? id
        description = json["description"]?.string
        type = json["type"]?.string
        arguments = (json["args"]?.array ?? []).compactMap(\.string)
        environment = (json["env"]?.object ?? [:]).compactMapValues(\.string)
        variables = (json["vars"]?.array ?? []).compactMap { $0["name"]?.string ?? $0.string }
        link = json["link"]?.string.flatMap { text in
            URL(string: text).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        }
    }

    /// Whether the agent can complete this method without a terminal or typed credentials.
    public nonisolated var isAgentDriven: Bool { type == nil || type == "agent" }
}

public struct ACPClientCapabilities: Sendable, Hashable {
    public var readTextFile: Bool
    public var writeTextFile: Bool
    public var terminal: Bool
    /// `session/update` notices (rate limits, compaction and similar announcements).
    public var notices: Bool
    /// Form elicitations, shown as questions.
    public var elicitationForms: Bool
    /// URL elicitations, which ask the user to open a page (a browser sign-in in Settings).
    public var elicitationURLs: Bool

    public nonisolated init(
        readTextFile: Bool = false, writeTextFile: Bool = false, terminal: Bool = false, notices: Bool = true,
        elicitationForms: Bool = true, elicitationURLs: Bool = false
    ) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
        self.terminal = terminal
        self.notices = notices
        self.elicitationForms = elicitationForms
        self.elicitationURLs = elicitationURLs
    }

    nonisolated var json: JSONValue {
        var object: [String: JSONValue] = [
            "fs": ["readTextFile": .bool(readTextFile), "writeTextFile": .bool(writeTextFile)],
            "terminal": .bool(terminal),
        ]
        if notices { object["session"] = ["notices": [:]] }
        var elicitation: [String: JSONValue] = [:]
        if elicitationForms { elicitation["form"] = [:] }
        if elicitationURLs { elicitation["url"] = [:] }
        if !elicitation.isEmpty { object["elicitation"] = .object(elicitation) }
        return .object(object)
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
    public var closeSession: Bool
    public var promptImage: Bool
    public var promptAudio: Bool
    public var promptEmbeddedContext: Bool
    /// The agent offers `logout` (`agentCapabilities.auth.logout`).
    public var canLogout: Bool
    public var authMethods: [ACPAuthMethod]
    public var meta: JSONValue?

    public nonisolated init(json: JSONValue) {
        protocolVersion = json["protocolVersion"]?.acpInt ?? 1
        authMethods = json["authMethods"]?.array?.compactMap(ACPAuthMethod.init(json:)) ?? []
        meta = json["_meta"]
        if json["info"] != nil || json["capabilities"] != nil {
            generation = 2
            agentInfo = ACPImplementation(json: json["info"])
            let session = json.at("capabilities.session")
            loadSession = session != nil && session?.isNull == false
            resumeSession = loadSession
            closeSession = loadSession
            let prompt = session?["prompt"]
            promptImage = prompt?["image"].map { !$0.isNull } ?? false
            promptAudio = prompt?["audio"].map { !$0.isNull } ?? false
            promptEmbeddedContext = prompt?["embeddedContext"].map { !$0.isNull } ?? false
            canLogout = json.at("capabilities.auth.logout").map { !$0.isNull && $0.bool != false } ?? false
        } else {
            generation = 1
            agentInfo = ACPImplementation(json: json["agentInfo"])
            let capabilities = json["agentCapabilities"]
            loadSession = capabilities?["loadSession"]?.bool ?? false
            resumeSession = capabilities?.at("sessionCapabilities.resume").map { !$0.isNull } ?? false
            closeSession = capabilities?.at("sessionCapabilities.close").map { !$0.isNull } ?? false
            promptImage = capabilities?.at("promptCapabilities.image")?.bool ?? false
            promptAudio = capabilities?.at("promptCapabilities.audio")?.bool ?? false
            promptEmbeddedContext = capabilities?.at("promptCapabilities.embeddedContext")?.bool ?? false
            canLogout = capabilities?.at("auth.logout").map { !$0.isNull && $0.bool != false } ?? false
        }
    }

    /// Grok publishes its model catalog (with per-model `_meta`) on `initialize`.
    public nonisolated var modelState: ACPModelState? { meta?["modelState"].flatMap(ACPModelState.init(json:)) }

    /// The method to sign in with: with a preferred method, that method if the agent lists it
    /// (nil otherwise, as T3 Code refuses unlisted methods); without one, the first method the
    /// agent completes by itself.
    public nonisolated func authMethod(preferring preferred: String?) -> ACPAuthMethod? {
        if let preferred = preferred.flatMap(ACPToolCallState.nonEmpty) {
            return authMethods.first { $0.id == preferred }
        }
        return authMethods.first(where: \.isAgentDriven)
    }
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

    /// The reasoning effort the current model runs with, from its `_meta` (Grok).
    public nonisolated var currentEffort: String? {
        availableModels.first { $0.modelID == currentModelID }?.meta?["reasoningEffort"]?.string
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

    public nonisolated func offers(_ value: String) -> Bool { choices.contains { $0.value == value } }

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

    /// Select options that change how the agent works rather than what it may do
    /// (`mode` and `collaboration_mode`); plan mode switches each to `plan` or `architect`.
    public nonisolated var modeLikeOptions: [ACPConfigOption] {
        configOptions.filter { ($0.category == "mode" || $0.category == "collaboration_mode") && $0.currentValue != nil }
    }

    /// Modes from the dedicated field, or from a `mode` config option.
    public nonisolated var effectiveModes: ACPModeState? {
        if let modes { return modes }
        guard let option = modeOption, let current = option.currentValue else { return nil }
        return ACPModeState(
            currentModeID: current,
            availableModes: option.choices.map { ACPSessionMode(id: $0.value, name: $0.name, description: $0.description) })
    }

    public nonisolated var currentModelID: String? { modelOption?.currentValue ?? models?.currentModelID }

    /// Updates a select option's current value, keeping its choices.
    public nonisolated mutating func setCurrentValue(_ value: String, ofOption id: String) {
        guard let index = configOptions.firstIndex(where: { $0.id == id }),
            case .select(_, let choices) = configOptions[index].value
        else { return }
        configOptions[index].value = .select(current: value, choices: choices)
    }

    /// The option of `category`, preferring the one whose id is `fallbackID`: an agent may list another option (its
    /// backend, say) in the `model` category ahead of the `model` option itself.
    private nonisolated func option(category: String, fallbackID: String) -> ACPConfigOption? {
        configOptions.first { $0.category == category && $0.id == fallbackID && $0.currentValue != nil }
            ?? configOptions.first { $0.category == category && $0.currentValue != nil }
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

/// The v2 preview's file change: which files changed and, optionally, the patch text.
public struct ACPFilePatch: Sendable, Hashable {
    public struct Change: Sendable, Hashable {
        /// `add`, `delete`, `modify`, `move` or `copy`.
        public var operation: String
        public var path: String
    }

    public var changes: [Change]
    public var text: String?
}

public enum ACPToolCallContent: Sendable, Hashable {
    case content(ACPContentBlock)
    case diff(path: String, oldText: String?, newText: String)
    case patch(ACPFilePatch)
    case terminal(id: String)
    case unknown(String)

    public nonisolated init(json: JSONValue) {
        switch json["type"]?.string {
        case "content":
            self = .content(ACPContentBlock(json: json["content"] ?? .null))
        case "diff" where json["changes"] != nil && json["path"] == nil:
            let changes = (json["changes"]?.array ?? []).compactMap { change -> ACPFilePatch.Change? in
                guard let path = change["path"]?.string else { return nil }
                return ACPFilePatch.Change(operation: change["operation"]?.string ?? "modify", path: path)
            }
            self = .patch(ACPFilePatch(changes: changes, text: json.at("patch.text")?.string))
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
    /// The agent's name for the tool, which some agents send beside the title (`write_file`).
    public var name: String?
    public var title: String?
    public var kind: String?
    public var status: String?
    public var content: [ACPToolCallContent]?
    public var locations: [String]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?
    public var meta: JSONValue?

    public nonisolated init(
        id: String, name: String? = nil, title: String? = nil, kind: String? = nil, status: String? = nil,
        content: [ACPToolCallContent]? = nil, locations: [String]? = nil, rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil, meta: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
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
            id: id, name: json["name"]?.string, title: json["title"]?.string, kind: json["kind"]?.string,
            status: json["status"]?.string, content: json["content"]?.array?.map(ACPToolCallContent.init(json:)),
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
    /// v2: one more piece of a tool call's content.
    case toolCallContentChunk(toolCallID: String, content: ACPToolCallContent)
    case plan([ACPPlanEntry])
    /// v2: a plan written as markdown.
    case planMarkdown(String)
    case availableCommands([ACPAvailableCommand])
    case currentMode(String)
    case configOptions([ACPConfigOption])
    /// Tokens in context, the context window, and the cumulative cost when known.
    case usage(used: Int, size: Int, costUSD: Double?)
    case sessionInfo(title: String?)
    /// v2: the agent compacts its context. `status` is `in_progress`, `completed`, `failed` or `cancelled`.
    case compaction(id: String, status: String, summary: String?)
    /// ACP v2 reports the end of a prompt as a state change.
    case idle(stopReason: String?, error: ACPError?, usage: JSONValue?)
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
        case "tool_call_content_chunk":
            guard let id = json["toolCallId"]?.string, !id.isEmpty, let content = json["content"] else {
                self = .other(kind)
                return
            }
            self = .toolCallContentChunk(toolCallID: id, content: ACPToolCallContent(json: content))
        case "plan":
            self = .plan(Self.planEntries(json["entries"]?.array ?? []))
        case "plan_update":
            if let markdown = json.at("plan.content")?.string, json.at("plan.type")?.string == "markdown" {
                self = .planMarkdown(markdown)
            } else {
                self = .plan(Self.planEntries(json.at("plan.entries")?.array ?? []))
            }
        case "plan_removed":
            self = .plan([])
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
            self = .usage(used: json["used"]?.acpInt ?? 0, size: json["size"]?.acpInt ?? 0, costUSD: usd)
        case "session_info_update":
            self = .sessionInfo(title: json["title"]?.string)
        case "compaction_update":
            let summary = (json["summary"]?.array ?? []).compactMap { ACPContentBlock(json: $0).displayText }.joined(separator: "\n")
            self = .compaction(
                id: json["compactionId"]?.string ?? "", status: json["status"]?.string ?? "in_progress",
                summary: json["error"]?.string ?? (summary.isEmpty ? nil : summary))
        case "compaction_summary_chunk":
            self = .compaction(
                id: json["compactionId"]?.string ?? "", status: "in_progress",
                summary: json["content"].flatMap { ACPContentBlock(json: $0).displayText })
        case "state_update" where json["state"]?.string == "idle":
            self = .idle(
                stopReason: json["stopReason"]?.string, error: json["error"].flatMap(ACPError.init(json:)), usage: json["usage"])
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

    /// History a `session/load` replays; the transcript already has it.
    public nonisolated var isReplay: Bool { meta?["isReplay"]?.bool == true }
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
    /// v2 requests carry their own title and description.
    public var title: String?
    public var description: String?

    public nonisolated init?(params: JSONValue, requestID: String) {
        guard let sessionID = params["sessionId"]?.string else { return nil }
        self.sessionID = sessionID
        title = params["title"]?.string
        description = params["description"]?.string
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

/// An elicitation (`elicitation/create`, or the older `session/elicitation`): the agent asks the
/// user to fill in a small form described by a JSON schema.
public struct ACPElicitationRequest: Sendable, Hashable {
    /// `form` or `url`.
    public var mode: String
    public var message: String
    /// Set for session-scoped requests; request-scoped ones (for example during sign-in) have none.
    public var sessionID: String?
    public var toolCallID: String?
    public var schema: JSONValue?
    public var elicitationID: String?
    public var url: String?

    public nonisolated init(params: JSONValue) {
        mode = params["mode"]?.string ?? "form"
        message = params["message"]?.string ?? ""
        sessionID = params["sessionId"]?.string
        toolCallID = params["toolCallId"]?.string
        schema = params["requestedSchema"]
        elicitationID = params["elicitationId"]?.string
        url = params["url"]?.string
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
