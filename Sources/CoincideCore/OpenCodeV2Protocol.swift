import Foundation

public enum OpenCodeV2ProtocolError: Error, Sendable, Equatable, LocalizedError {
    case invalidResponse, invalidEvent, invalidOwner, limitExceeded, unsupportedForm, invalidAnswer
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "OpenCode returned an invalid native response."
        case .invalidEvent: "OpenCode returned an invalid native event. Reconciliation is required."
        case .invalidOwner: "The OpenCode observation belongs to a different native owner."
        case .limitExceeded: "The OpenCode native projection exceeded its bounded limit."
        case .unsupportedForm: "This OpenCode form requires controls that are not supported yet."
        case .invalidAnswer: "The answer does not satisfy the native OpenCode form."
        }
    }
}

public struct OpenCodeV2PermissionRule: Sendable, Equatable {
    public enum Effect: String, Sendable { case allow, deny, ask }
    public let action: String
    public let resource: String
    public let effect: Effect
    public var json: JSONValue { .object(["action": .string(action), "resource": .string(resource), "effect": .string(effect.rawValue)]) }
}

public struct OpenCodeV2SessionInfo: Sendable, Equatable {
    public let id: String
    public let parentID: String?
    public let directory: String
    public let agentID: String?
    public let model: OpenCodeModelSelection?
    public let permissions: [OpenCodeV2PermissionRule]?
    public let outcome: String?
    public let idleMilliseconds: Double?
    public let hasRevert: Bool
}

public struct OpenCodeV2InboxAdmission: Sendable, Equatable {
    public let id: String
    public let sessionID: String
    public let type: String
    public let delivery: String
    /// Authored local input remains separate; plugins can transform native text.
    public let text: String?
}

public struct OpenCodeV2Permission: Sendable, Equatable {
    public enum Decision: String, Sendable { case once, always, reject }
    public let id: String
    public let sessionID: String
    public let action: String
    public let resources: [String]
    public let save: [String]
    public let messageID: String?
    public let toolID: String?

    public func approval(localID: JSONValue) -> ApprovalRequest {
        .init(id: localID, method: "opencode/permission", params: .object([
            "title": .string("Allow OpenCode \(action)?"), "action": .string(action),
            "resources": .array(resources.map(JSONValue.string)),
            "description": .string(resources.joined(separator: "\n")),
            "options": .array([
                .object(["optionId": .string("once"), "name": .string("Allow once")]),
                .object(["optionId": .string("always"), "name": .string("Always allow in this workspace")]),
                .object(["optionId": .string("reject"), "name": .string("Decline")])
            ])
        ]))
    }

    public func replyBody(decision: Decision, message: String? = nil) throws -> JSONValue {
        var body: [String: JSONValue] = ["decision": .string(decision.rawValue)]
        if let message { body["message"] = .string(try OpenCodeV2Bounds.text(.string(message), maximum: 16_384, empty: true)) }
        return .object(body)
    }
}

public struct OpenCodeV2Form: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let value: String
        public let label: String
        public let description: String?
    }
    public struct Field: Sendable, Equatable {
        public let key: String
        public let type: String
        public let title: String
        public let description: String?
        public let required: Bool
        public let options: [Option]
        public let allowCustom: Bool
        public let minimumLength: Int?
        public let maximumLength: Int?
        public let minimumItems: Int?
        public let maximumItems: Int?
        public let defaultValue: JSONValue?
    }
    public let id: String
    public let sessionID: String
    public let title: String
    public let fields: [Field]
    public let unsupportedReason: String?

    /// UI-only reconstruction of our narrow presentation. Native routing must
    /// always use the adapter's retained original form, never these placeholders.
    public static func presentation(_ request: ApprovalRequest) throws -> OpenCodeV2Form {
        guard request.method == "opencode/form", let params = request.params.object,
              Set(params.keys).isSubset(of: ["title", "questions", "unsupportedReason"]),
              try JSONEncoder().encode(request.params).count <= 1_048_576,
              let questions = params["questions"]?.array, !questions.isEmpty, questions.count <= 64 else {
            throw OpenCodeV2ProtocolError.unsupportedForm
        }
        var fields: [Field] = [], seen = Set<String>()
        for question in questions {
            guard let object = question.object,
                  Set(object.keys).isSubset(of: ["id", "question", "title", "multiSelect", "required", "allowCustomAnswer", "options", "default", "minLength", "maxLength", "minItems", "maxItems"]),
                  case .bool(let multiple) = question["multiSelect"], case .bool(let required) = question["required"],
                  case .bool(let custom) = question["allowCustomAnswer"], let options = question["options"].array, options.count <= 256 else {
                throw OpenCodeV2ProtocolError.unsupportedForm
            }
            let key = try OpenCodeV2Bounds.text(question["id"])
            guard seen.insert(key).inserted else { throw OpenCodeV2ProtocolError.invalidAnswer }
            var optionValues = Set<String>()
            let projected: [Option] = try options.map { option in
                guard let object = option.object, Set(object.keys).isSubset(of: ["value", "label", "description"]) else {
                    throw OpenCodeV2ProtocolError.unsupportedForm
                }
                let value = try OpenCodeV2Bounds.text(option["value"], maximum: 16_384, empty: true)
                guard optionValues.insert(value).inserted else { throw OpenCodeV2ProtocolError.invalidAnswer }
                return .init(value: value, label: try OpenCodeV2Bounds.text(option["label"], maximum: 16_384, empty: true),
                             description: try OpenCodeV2Bounds.optionalText(option["description"], maximum: 16_384))
            }
            let minLength = try OpenCodeV2Bounds.optionalInteger(question["minLength"]), maxLength = try OpenCodeV2Bounds.optionalInteger(question["maxLength"])
            let minItems = try OpenCodeV2Bounds.optionalInteger(question["minItems"]), maxItems = try OpenCodeV2Bounds.optionalInteger(question["maxItems"])
            guard minLength.map({ maxLength == nil || $0 <= maxLength! }) ?? true,
                  minItems.map({ maxItems == nil || $0 <= maxItems! }) ?? true else { throw OpenCodeV2ProtocolError.invalidAnswer }
            let defaultValue: JSONValue? = question["default"] == .null ? nil : question["default"]
            if let defaultValue {
                if multiple { _ = try OpenCodeV2Bounds.strings(defaultValue, maximum: 256, itemBytes: 65_536) }
                else { _ = try OpenCodeV2Bounds.text(defaultValue, maximum: 65_536, empty: true) }
            }
            fields.append(.init(key: key, type: multiple ? "multiselect" : "string",
                title: try OpenCodeV2Bounds.text(question["title"], maximum: 16_384, empty: true),
                description: try OpenCodeV2Bounds.optionalText(question["question"], maximum: 16_384), required: required,
                options: projected, allowCustom: custom, minimumLength: minLength, maximumLength: maxLength,
                minimumItems: minItems, maximumItems: maxItems, defaultValue: defaultValue))
        }
        return .init(id: "frm_presentation", sessionID: "ses_presentation",
            title: try OpenCodeV2Bounds.text(request.params["title"], maximum: 16_384, empty: true), fields: fields,
            unsupportedReason: try OpenCodeV2Bounds.optionalText(request.params["unsupportedReason"], maximum: 4_096))
    }

    public func approval(localID: JSONValue) -> ApprovalRequest {
        var params: [String: JSONValue] = ["title": .string(title), "questions": .array(fields.map { field in
            var item: [String: JSONValue] = ["id": .string(field.key), "question": .string(field.description ?? field.title),
                "title": .string(field.title), "multiSelect": .bool(field.type == "multiselect"),
                "required": .bool(field.required), "allowCustomAnswer": .bool(field.allowCustom),
                "options": .array(field.options.map { option in
                    .object(["value": .string(option.value), "label": .string(option.label), "description": .string(option.description ?? option.label)])
                })]
            if let value = field.defaultValue { item["default"] = value }
            if let value = field.minimumLength { item["minLength"] = .number(Double(value)) }
            if let value = field.maximumLength { item["maxLength"] = .number(Double(value)) }
            if let value = field.minimumItems { item["minItems"] = .number(Double(value)) }
            if let value = field.maximumItems { item["maxItems"] = .number(Double(value)) }
            return .object(item)
        })]
        if let unsupportedReason { params["unsupportedReason"] = .string(unsupportedReason) }
        return .init(id: localID, method: "opencode/form", params: .object(params))
    }

    public func answerBody(answers: [String: String]) throws -> JSONValue {
        try answerBody(values: answers.mapValues { [$0] })
    }
    public func answerBody(selections: [String: [String]]) throws -> JSONValue {
        try answerBody(values: selections)
    }
    private func answerBody(values: [String: [String]]) throws -> JSONValue {
        guard unsupportedReason == nil else { throw OpenCodeV2ProtocolError.unsupportedForm }
        guard Set(values.keys).isSubset(of: Set(fields.map(\.key))) else { throw OpenCodeV2ProtocolError.invalidAnswer }
        var answer: [String: JSONValue] = [:]
        for field in fields {
            let supplied = values[field.key] ?? field.defaultValue.map { value in
                field.type == "string" ? [value.string ?? ""] : (value.array ?? []).compactMap(\.string)
            }
            guard let supplied else {
                if field.required { throw OpenCodeV2ProtocolError.invalidAnswer }
                continue
            }
            guard supplied.count <= 256, Set(supplied).count == supplied.count,
                  supplied.allSatisfy({ $0.utf8.count <= 65_536 && !$0.contains("\0") }) else { throw OpenCodeV2ProtocolError.invalidAnswer }
            let known = Set(field.options.map(\.value))
            guard field.allowCustom || supplied.allSatisfy(known.contains) else { throw OpenCodeV2ProtocolError.invalidAnswer }
            if field.type == "string" {
                guard supplied.count == 1, let value = supplied.first,
                      field.minimumLength.map({ value.utf16.count >= $0 }) ?? true,
                      field.maximumLength.map({ value.utf16.count <= $0 }) ?? true,
                      !field.required || !value.isEmpty else { throw OpenCodeV2ProtocolError.invalidAnswer }
                answer[field.key] = .string(value)
            } else {
                guard (!field.required || !supplied.isEmpty), field.minimumItems.map({ supplied.count >= $0 }) ?? true,
                      field.maximumItems.map({ supplied.count <= $0 }) ?? true else { throw OpenCodeV2ProtocolError.invalidAnswer }
                answer[field.key] = .array(supplied.map(JSONValue.string))
            }
        }
        let body = JSONValue.object(["answer": .object(answer)])
        guard try JSONEncoder().encode(body).count <= 1_048_576 else { throw OpenCodeV2ProtocolError.invalidAnswer }
        return body
    }
}

public struct OpenCodeV2ToolEvent: Sendable, Equatable {
    public enum Content: Sendable, Equatable { case text(String), file(name: String?, mime: String, uri: String?) }
    public let id: String
    public let name: String?
    public let input: JSONValue?
    public let text: String?
    public let content: [Content]
    public let executed: Bool?
    public let childSessionID: String?
    public let background: Bool?
    public let status: String?
    public let description: String?
    public let prompt: String?
    public let agentID: String?
    public let model: String?
    public let aborted: Bool
}

public struct OpenCodeV2Event: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case executionStarted = "session.execution.started", executionSucceeded = "session.execution.succeeded"
        case executionInterrupted = "session.execution.interrupted", executionFailed = "session.execution.failed"
        case stepStarted = "session.step.started", stepStreamed = "session.step.streamed", stepEnded = "session.step.ended", stepFailed = "session.step.failed"
        case textStarted = "session.text.started", textDelta = "session.text.delta", textEnded = "session.text.ended"
        case reasoningStarted = "session.reasoning.started", reasoningDelta = "session.reasoning.delta", reasoningEnded = "session.reasoning.ended"
        case toolInputStarted = "session.tool.input.started", toolInputDelta = "session.tool.input.delta", toolInputEnded = "session.tool.input.ended"
        case toolCalled = "session.tool.called", toolProgress = "session.tool.progress", toolSuccess = "session.tool.success", toolFailed = "session.tool.failed"
        case inboxEnqueued = "session.inbox.enqueued", inboxDelivered = "session.inbox.delivered", inboxCancelled = "session.inbox.cancelled"
        case permissionAsked = "permission.asked", permissionReplied = "permission.replied"
        case formCreated = "form.created", formReplied = "form.replied", formCancelled = "form.cancelled"
        case sessionCreated = "session.created", sessionDeleted = "session.deleted", sessionMoved = "session.moved"
        case agentSelected = "session.agent.selected", modelSelected = "session.model.selected"
        case compactionStarted = "session.compaction.started", compactionDelta = "session.compaction.delta", compactionEnded = "session.compaction.ended", compactionFailed = "session.compaction.failed"
        case retryScheduled = "session.retry.scheduled", synthetic = "session.synthetic"
    }
    public struct Durable: Sendable, Equatable {
        public let aggregateID: String
        public let seq: Int
        public let version: Int
    }
    public let kind: Kind
    public let sessionID: String
    public var id: String?
    public var created: Double?
    public var durable: Durable?
    public var assistantMessageID: String?
    public var ordinal: Int?
    public var text: String?
    public var tool: OpenCodeV2ToolEvent?
    public var inboxID: String?
    public var inbox: OpenCodeV2InboxAdmission?
    public var permission: OpenCodeV2Permission?
    public var form: OpenCodeV2Form?
    public var requestID: String?
    public var session: OpenCodeV2SessionInfo?
    public var agentID: String?
    public var model: OpenCodeModelSelection?
    public var requiresReconciliation = false
    public var failureMessage: String? { kind == .executionFailed ? "The native OpenCode execution failed." : nil }
}

/// Generation-specific bounded decoders; unknown payloads and private server
/// errors/configuration are never retained in the public projections.
public enum OpenCodeV2Protocol {
    public static func session(_ response: OpenCodeHTTPResponse, expectedID: String? = nil,
                               directory: String) throws -> OpenCodeV2SessionInfo {
        let result = try sessionInfo(json(response)["data"])
        guard expectedID == nil || result.id == expectedID, result.directory == directory else {
            throw OpenCodeV2ProtocolError.invalidOwner
        }
        return result
    }

    public static func admission(_ response: OpenCodeHTTPResponse, sessionID: String,
                                 inputID: String) throws -> OpenCodeV2InboxAdmission {
        let result = try inboxItem(json(response)["data"])
        guard result.sessionID == sessionID, result.id == inputID, result.type == "user" else {
            throw OpenCodeV2ProtocolError.invalidOwner
        }
        return result
    }

    /// Global process activity, not a list of sessions owned by this app.
    public static func activeSessions(_ response: OpenCodeHTTPResponse) throws -> Set<String> {
        guard let active = try json(response)["data"].object, active.count <= 16_384 else { throw OpenCodeV2ProtocolError.invalidResponse }
        var result = Set<String>()
        for (id, value) in active {
            guard value["type"] == .string("running") else { throw OpenCodeV2ProtocolError.invalidResponse }
            result.insert(try OpenCodeV2Bounds.sessionID(.string(id)))
        }
        return result
    }

    public static func inbox(_ response: OpenCodeHTTPResponse, sessionID: String) throws -> [OpenCodeV2InboxAdmission] {
        guard let array = try json(response)["data"].array, array.count <= 4_096 else { throw OpenCodeV2ProtocolError.invalidResponse }
        var seen = Set<String>()
        return try array.map { value in
            let result = try inboxItem(value)
            guard result.sessionID == sessionID, seen.insert(result.id).inserted else { throw OpenCodeV2ProtocolError.invalidOwner }
            return result
        }
    }

    public static func permissionRules(_ value: JSONValue) throws -> [OpenCodeV2PermissionRule] {
        guard let rules = value.array, rules.count <= 1_024 else { throw OpenCodeV2ProtocolError.invalidResponse }
        return try rules.map { value in
            guard let effect = OpenCodeV2PermissionRule.Effect(rawValue: try OpenCodeV2Bounds.text(value["effect"])) else {
                throw OpenCodeV2ProtocolError.invalidResponse
            }
            return .init(action: try OpenCodeV2Bounds.text(value["action"]), resource: try OpenCodeV2Bounds.text(value["resource"], maximum: 16_384), effect: effect)
        }
    }

    public static func permissions(_ response: OpenCodeHTTPResponse, sessionID: String) throws -> [OpenCodeV2Permission] {
        guard let values = try json(response)["data"].array, values.count <= 512 else { throw OpenCodeV2ProtocolError.limitExceeded }
        var seen = Set<String>()
        return try values.map { value in
            let request = try permission(value)
            guard request.sessionID == sessionID, seen.insert(request.id).inserted else { throw OpenCodeV2ProtocolError.invalidOwner }
            return request
        }
    }

    public static func forms(_ response: OpenCodeHTTPResponse, sessionID: String) throws -> [OpenCodeV2Form] {
        guard let values = try json(response)["data"].array, values.count <= 512 else { throw OpenCodeV2ProtocolError.limitExceeded }
        var seen = Set<String>()
        return try values.map { value in
            let request = try form(value)
            guard request.sessionID == sessionID, seen.insert(request.id).inserted else { throw OpenCodeV2ProtocolError.invalidOwner }
            return request
        }
    }

    public static func decode(_ event: OpenCodeSSEEvent) throws -> OpenCodeV2Event? {
        guard event.data.utf8.count <= 1_048_576, let bytes = event.data.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(JSONValue.self, from: bytes), envelope.object != nil else {
            throw OpenCodeV2ProtocolError.invalidEvent
        }
        guard let rawType = envelope["type"].string, rawType.utf8.count <= 256 else { throw OpenCodeV2ProtocolError.invalidEvent }
        guard let kind = OpenCodeV2Event.Kind(rawValue: rawType) else { return nil }
        let data = envelope["data"]
        guard data.object != nil else { throw OpenCodeV2ProtocolError.invalidEvent }
        if kind == .formCreated, data["form"]["sessionID"] == .string("global") { return nil }
        if [.formReplied, .formCancelled].contains(kind), data["sessionID"] == .string("global") { return nil }
        let sessionID = try OpenCodeV2Bounds.sessionID(kind == .formCreated ? data["form"]["sessionID"] : data["sessionID"])
        let critical = [.executionStarted, .executionSucceeded, .executionInterrupted, .executionFailed].contains(kind)
        var result = OpenCodeV2Event(kind: kind, sessionID: sessionID)
        if let id = try? OpenCodeV2Bounds.text(envelope["id"]), id.hasPrefix("evt_") { result.id = id }
        else if !critical { throw OpenCodeV2ProtocolError.invalidEvent }
        result.created = OpenCodeV2Bounds.number(envelope["created"])
        if result.created == nil && !critical { throw OpenCodeV2ProtocolError.invalidEvent }
        if envelope["durable"] != .null {
            let value = envelope["durable"]
            if let aggregate = try? OpenCodeV2Bounds.sessionID(value["aggregateID"]),
               let seq = OpenCodeV2Bounds.integer(value["seq"]), let version = OpenCodeV2Bounds.integer(value["version"]), version > 0 {
                guard aggregate == sessionID else { throw OpenCodeV2ProtocolError.invalidOwner }
                result.durable = .init(aggregateID: aggregate, seq: seq, version: version)
            } else if critical { result.requiresReconciliation = true }
            else { throw OpenCodeV2ProtocolError.invalidEvent }
        } else if !isEphemeral(kind) {
            if critical { result.requiresReconciliation = true }
            else { throw OpenCodeV2ProtocolError.invalidEvent }
        }
        switch kind {
        case .executionStarted, .executionSucceeded, .executionInterrupted, .executionFailed, .sessionDeleted:
            break // New terminal error/reason fields never become raw user-visible payloads.
        case .stepStarted, .stepStreamed, .stepEnded, .stepFailed:
            result.assistantMessageID = try OpenCodeV2Bounds.messageID(data["assistantMessageID"])
            if kind == .stepStarted {
                result.agentID = try OpenCodeV2Bounds.text(data["agent"])
                result.model = try model(data["model"])
            }
        case .textStarted, .textDelta, .textEnded, .reasoningStarted, .reasoningDelta, .reasoningEnded:
            result.assistantMessageID = try OpenCodeV2Bounds.messageID(data["assistantMessageID"])
            guard let ordinal = OpenCodeV2Bounds.integer(data["ordinal"]), ordinal <= 1_000_000 else { throw OpenCodeV2ProtocolError.invalidEvent }
            result.ordinal = ordinal
            if [.textDelta, .reasoningDelta].contains(kind) { result.text = try OpenCodeV2Bounds.text(data["delta"], maximum: 1_048_576, empty: true) }
            if [.textEnded, .reasoningEnded].contains(kind) { result.text = try OpenCodeV2Bounds.text(data["text"], maximum: 1_048_576, empty: true) }
        case .toolInputStarted, .toolInputDelta, .toolInputEnded, .toolCalled, .toolProgress, .toolSuccess, .toolFailed:
            result.assistantMessageID = try OpenCodeV2Bounds.messageID(data["assistantMessageID"])
            result.tool = try tool(data, kind: kind)
        case .inboxEnqueued, .inboxDelivered, .inboxCancelled:
            result.inboxID = try OpenCodeV2Bounds.messageID(data["inboxID"])
            if kind == .inboxEnqueued {
                result.inbox = try inboxItem(data["item"], id: result.inboxID, sessionID: sessionID)
            }
        case .permissionAsked:
            result.permission = try permission(data); result.requestID = result.permission?.id
        case .permissionReplied:
            result.requestID = try OpenCodeV2Bounds.text(data["requestID"])
        case .formCreated:
            result.form = try form(data["form"]); result.requestID = result.form?.id
        case .formReplied, .formCancelled:
            result.requestID = try OpenCodeV2Bounds.text(data["id"])
        case .sessionCreated:
            result.session = try sessionInfo(data, id: sessionID)
        case .sessionMoved:
            let directory = try OpenCodeV2Bounds.directory(data["location"]["directory"])
            result.session = .init(id: sessionID, parentID: nil, directory: directory, agentID: nil,
                                   model: nil, permissions: nil, outcome: nil, idleMilliseconds: nil, hasRevert: false)
        case .agentSelected: result.agentID = try OpenCodeV2Bounds.text(data["agent"])
        case .modelSelected: result.model = try model(data["model"])
        case .compactionDelta, .compactionEnded, .synthetic:
            result.text = try OpenCodeV2Bounds.text(data["text"], maximum: 1_048_576, empty: true)
        case .compactionStarted, .compactionFailed, .retryScheduled: break
        }
        return result
    }

    public static func permission(_ value: JSONValue) throws -> OpenCodeV2Permission {
        let id = try OpenCodeV2Bounds.text(value["id"])
        guard id.hasPrefix("per") else { throw OpenCodeV2ProtocolError.invalidResponse }
        let source = value["source"]
        let hasSource = source != .null
        if hasSource && source["type"] != .string("tool") { throw OpenCodeV2ProtocolError.invalidResponse }
        return .init(id: id, sessionID: try OpenCodeV2Bounds.sessionID(value["sessionID"]),
                     action: try OpenCodeV2Bounds.text(value["action"]),
                     resources: try OpenCodeV2Bounds.strings(value["resources"], maximum: 128, itemBytes: 16_384),
                     save: value["save"] == .null ? [] : try OpenCodeV2Bounds.strings(value["save"], maximum: 128, itemBytes: 16_384),
                     messageID: hasSource ? try OpenCodeV2Bounds.messageID(source["messageID"]) : nil,
                     toolID: hasSource ? try OpenCodeV2Bounds.text(source["id"]) : nil)
    }

    public static func form(_ value: JSONValue) throws -> OpenCodeV2Form {
        let id = try OpenCodeV2Bounds.text(value["id"])
        guard id.hasPrefix("frm_"), let entries = value["fields"].array, !entries.isEmpty, entries.count <= 64 else {
            throw OpenCodeV2ProtocolError.invalidResponse
        }
        let sessionID = try OpenCodeV2Bounds.sessionID(value["sessionID"])
        let title = try OpenCodeV2Bounds.text(value["title"], maximum: 16_384, empty: true)
        var seen = Set<String>(), fields: [OpenCodeV2Form.Field] = [], unsupported: String?
        for entry in entries {
            let key = try OpenCodeV2Bounds.text(entry["key"]), type = try OpenCodeV2Bounds.text(entry["type"])
            guard seen.insert(key).inserted else { throw OpenCodeV2ProtocolError.invalidResponse }
            if !["string", "multiselect"].contains(type) { unsupported = unsupported ?? "This form requires a field type that is not supported yet." }
            if try OpenCodeV2Bounds.optionalBool(entry["hidden"]) == true { unsupported = unsupported ?? "This form contains a hidden field." }
            if entry["when"] != .null {
                guard let when = entry["when"].array else { throw OpenCodeV2ProtocolError.invalidResponse }
                if !when.isEmpty { unsupported = unsupported ?? "This form contains conditional fields." }
            }
            if entry["pattern"] != .null || entry["format"] != .null {
                unsupported = unsupported ?? "This form requires native format or pattern validation that is not supported yet."
            }
            let options: [OpenCodeV2Form.Option]
            if entry["options"] == .null {
                guard type != "multiselect" else { throw OpenCodeV2ProtocolError.invalidResponse }; options = []
            } else {
                guard let array = entry["options"].array, array.count <= 256 else { throw OpenCodeV2ProtocolError.limitExceeded }
                var optionIDs = Set<String>()
                options = try array.map { option in
                    let value = try OpenCodeV2Bounds.text(option["value"], maximum: 16_384, empty: true)
                    guard optionIDs.insert(value).inserted else { throw OpenCodeV2ProtocolError.invalidResponse }
                    return .init(value: value, label: try OpenCodeV2Bounds.text(option["label"], maximum: 16_384, empty: true),
                                 description: try OpenCodeV2Bounds.optionalText(option["description"], maximum: 16_384))
                }
            }
            let minimumLength = try OpenCodeV2Bounds.optionalInteger(entry["minLength"]), maximumLength = try OpenCodeV2Bounds.optionalInteger(entry["maxLength"])
            let minimumItems = try OpenCodeV2Bounds.optionalInteger(entry["minItems"]), maximumItems = try OpenCodeV2Bounds.optionalInteger(entry["maxItems"])
            guard minimumLength.map({ maximumLength == nil || $0 <= maximumLength! }) ?? true,
                  minimumItems.map({ maximumItems == nil || $0 <= maximumItems! }) ?? true else { throw OpenCodeV2ProtocolError.invalidResponse }
            let defaultValue: JSONValue? = ["string", "multiselect"].contains(type) && entry["default"] != .null ? entry["default"] : nil
            if let defaultValue {
                if type == "string" { _ = try OpenCodeV2Bounds.text(defaultValue, maximum: 65_536, empty: true) }
                else if type == "multiselect" { _ = try OpenCodeV2Bounds.strings(defaultValue, maximum: 256, itemBytes: 65_536) }
            }
            fields.append(.init(key: key, type: type,
                title: try OpenCodeV2Bounds.optionalText(entry["title"], maximum: 16_384) ?? key,
                description: try OpenCodeV2Bounds.optionalText(entry["description"], maximum: 16_384),
                required: try OpenCodeV2Bounds.optionalBool(entry["required"]) ?? false, options: options,
                allowCustom: try OpenCodeV2Bounds.optionalBool(entry["custom"]) == true || (type == "string" && entry["options"] == .null),
                minimumLength: minimumLength, maximumLength: maximumLength, minimumItems: minimumItems, maximumItems: maximumItems, defaultValue: defaultValue))
        }
        return .init(id: id, sessionID: sessionID, title: title, fields: fields, unsupportedReason: unsupported)
    }

    private static func sessionInfo(_ value: JSONValue, id suppliedID: String? = nil) throws -> OpenCodeV2SessionInfo {
        guard value.object != nil else { throw OpenCodeV2ProtocolError.invalidResponse }
        let id = try suppliedID.map { try OpenCodeV2Bounds.sessionID(.string($0)) } ?? OpenCodeV2Bounds.sessionID(value["id"])
        let outcome = try OpenCodeV2Bounds.optionalText(value["outcome"])
        guard outcome == nil || ["succeeded", "failed", "interrupted"].contains(outcome!) else { throw OpenCodeV2ProtocolError.invalidResponse }
        return .init(id: id, parentID: value["parentID"] == .null ? nil : try OpenCodeV2Bounds.sessionID(value["parentID"]),
            directory: try OpenCodeV2Bounds.directory(value["location"]["directory"]),
            agentID: try OpenCodeV2Bounds.optionalText(value["agent"]), model: value["model"] == .null ? nil : try model(value["model"]),
            permissions: value["permissions"] == .null ? nil : try permissionRules(value["permissions"]), outcome: outcome,
            idleMilliseconds: value["time"]["idle"] == .null ? nil : try OpenCodeV2Bounds.requiredNumber(value["time"]["idle"]),
            hasRevert: value["revert"] != .null)
    }

    private static func inboxItem(_ value: JSONValue, id: String? = nil, sessionID: String? = nil) throws -> OpenCodeV2InboxAdmission {
        let type = try OpenCodeV2Bounds.text(value["type"]), delivery = try OpenCodeV2Bounds.text(value["delivery"])
        guard ["user", "synthetic", "compaction", "move"].contains(type), ["steer", "queue"].contains(delivery) else { throw OpenCodeV2ProtocolError.invalidResponse }
        return .init(id: try OpenCodeV2Bounds.messageID(id.map(JSONValue.string) ?? value["id"]),
            sessionID: try OpenCodeV2Bounds.sessionID(sessionID.map(JSONValue.string) ?? value["sessionID"]), type: type, delivery: delivery,
            text: ["user", "synthetic"].contains(type) ? try OpenCodeV2Bounds.text(value["payload"]["text"], maximum: 1_048_576, empty: true) : nil)
    }

    private static func model(_ value: JSONValue) throws -> OpenCodeModelSelection {
        .init(providerID: try OpenCodeV2Bounds.text(value["providerID"]), id: try OpenCodeV2Bounds.text(value["id"]),
              variant: try OpenCodeV2Bounds.optionalText(value["variant"]))
    }

    private static func tool(_ value: JSONValue, kind: OpenCodeV2Event.Kind) throws -> OpenCodeV2ToolEvent {
        let id = try OpenCodeV2Bounds.text(value["id"])
        let metadata = value["metadata"], input = value["input"]
        let body: JSONValue?
        if kind == .toolCalled {
            guard input.object != nil else { throw OpenCodeV2ProtocolError.invalidEvent }
            body = try OpenCodeV2Bounds.safeInput(input)
        } else { body = nil }
        var content: [OpenCodeV2ToolEvent.Content] = []
        if value["content"] != .null {
            guard let values = value["content"].array, !values.isEmpty, values.count <= 256 else { throw OpenCodeV2ProtocolError.invalidEvent }
            content = try values.map { item in
                switch item["type"].string {
                case "text": return .text(try OpenCodeV2Bounds.text(item["text"], maximum: 1_048_576, empty: true))
                case "file":
                    let uri = try OpenCodeV2Bounds.text(item["uri"], maximum: 1_048_576)
                    let safe: String?
                    if uri.utf8.count <= 16_384, let url = URLComponents(string: uri), ["file", "https"].contains(url.scheme?.lowercased() ?? ""),
                       url.user == nil, url.password == nil, url.query == nil, url.fragment == nil { safe = uri } else { safe = nil }
                    return .file(name: try OpenCodeV2Bounds.optionalText(item["name"]), mime: try OpenCodeV2Bounds.text(item["mime"]), uri: safe)
                default: throw OpenCodeV2ProtocolError.invalidEvent
                }
            }
        } else if kind == .toolSuccess { throw OpenCodeV2ProtocolError.invalidEvent }
        let executed = try OpenCodeV2Bounds.optionalBool(value["executed"])
        if [.toolCalled, .toolSuccess, .toolFailed].contains(kind), executed == nil { throw OpenCodeV2ProtocolError.invalidEvent }
        return .init(id: id, name: kind == .toolInputStarted ? try OpenCodeV2Bounds.text(value["name"]) : nil,
            input: body, text: [.toolInputDelta, .toolInputEnded].contains(kind) ? try OpenCodeV2Bounds.text(value[kind == .toolInputDelta ? "delta" : "text"], maximum: 1_048_576, empty: true) : nil,
            content: content, executed: executed,
            // Generic MCP tools can use these keys for unrelated values. Only
            // correctly typed native subagent hints participate in ownership.
            childSessionID: try? OpenCodeV2Bounds.sessionID(metadata["sessionID"]),
            background: try? OpenCodeV2Bounds.optionalBool(input["background"]),
            status: try? OpenCodeV2Bounds.optionalText(metadata["status"]), description: try? OpenCodeV2Bounds.optionalText(input["description"], maximum: 16_384),
            prompt: try? OpenCodeV2Bounds.optionalText(input["prompt"], maximum: 65_536), agentID: try? OpenCodeV2Bounds.optionalText(input["agent"]),
            model: try? OpenCodeV2Bounds.optionalText(input["model"]), aborted: value["error"]["type"] == .string("aborted"))
    }

    private static func isEphemeral(_ kind: OpenCodeV2Event.Kind) -> Bool {
        [.textDelta, .reasoningDelta, .toolInputDelta, .toolProgress, .permissionAsked, .permissionReplied,
         .formCreated, .formReplied, .formCancelled, .compactionDelta].contains(kind)
    }

    static func json(_ response: OpenCodeHTTPResponse) throws -> JSONValue {
        if response.status == 401 || response.status == 403 { throw OpenCodeProtocolError.unauthorized }
        if response.status == 503 { throw OpenCodeProtocolError.unavailable }
        let media = response.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (200...299).contains(response.status), response.body.count <= 16_777_216,
              media == "application/json" || (media?.hasPrefix("application/") == true && media?.hasSuffix("+json") == true),
              let result = try? JSONDecoder().decode(JSONValue.self, from: response.body) else { throw OpenCodeV2ProtocolError.invalidResponse }
        return result
    }
}

enum OpenCodeV2Bounds {
    static func text(_ value: JSONValue, maximum: Int = 4_096, empty: Bool = false) throws -> String {
        guard let value = value.string, (empty || !value.isEmpty), value.utf8.count <= maximum,
              !value.contains("\0") else { throw OpenCodeV2ProtocolError.invalidResponse }
        return value
    }
    static func optionalText(_ value: JSONValue, maximum: Int = 4_096) throws -> String? {
        value == .null ? nil : try text(value, maximum: maximum, empty: true)
    }
    static func sessionID(_ value: JSONValue) throws -> String {
        guard let result = try? text(value), result.hasPrefix("ses"), !result.contains("/"), !result.contains("\\"),
              !result.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw OpenCodeV2ProtocolError.invalidOwner }
        return result
    }
    static func messageID(_ value: JSONValue) throws -> String {
        guard let result = try? text(value), result.hasPrefix("msg"), !result.contains("/"), !result.contains("\\"),
              !result.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw OpenCodeV2ProtocolError.invalidOwner }
        return result
    }
    static func directory(_ value: JSONValue) throws -> String {
        let result = try text(value, maximum: 16_384)
        guard result.hasPrefix("/"), URL(fileURLWithPath: result).standardizedFileURL.path == result,
              !result.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw OpenCodeV2ProtocolError.invalidOwner }
        return result
    }
    static func number(_ value: JSONValue) -> Double? {
        guard case .number(let value) = value, value.isFinite, value >= 0, value <= 9_007_199_254_740_991 else { return nil }
        return value
    }
    static func requiredNumber(_ value: JSONValue) throws -> Double {
        guard let value = number(value) else { throw OpenCodeV2ProtocolError.invalidResponse }; return value
    }
    static func integer(_ value: JSONValue) -> Int? {
        guard let value = number(value), value.rounded(.towardZero) == value else { return nil }; return Int(value)
    }
    static func optionalInteger(_ value: JSONValue) throws -> Int? {
        if value == .null { return nil }; guard let result = integer(value) else { throw OpenCodeV2ProtocolError.invalidResponse }; return result
    }
    static func optionalBool(_ value: JSONValue) throws -> Bool? {
        if value == .null { return nil }; guard case .bool(let result) = value else { throw OpenCodeV2ProtocolError.invalidResponse }; return result
    }
    static func strings(_ value: JSONValue, maximum: Int, itemBytes: Int) throws -> [String] {
        guard let values = value.array, values.count <= maximum else { throw OpenCodeV2ProtocolError.limitExceeded }
        return try values.map { try text($0, maximum: itemBytes, empty: true) }
    }
    static func safeInput(_ value: JSONValue) throws -> JSONValue {
        var nodes = 0
        func walk(_ value: JSONValue, depth: Int) throws -> JSONValue {
            nodes += 1
            guard nodes <= 4_096, depth <= 16 else { throw OpenCodeV2ProtocolError.limitExceeded }
            switch value {
            case .object(let object):
                guard object.count <= 256 else { throw OpenCodeV2ProtocolError.limitExceeded }
                var result: [String: JSONValue] = [:]
                for (key, item) in object {
                    let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                    if ["authorization", "headers", "password", "apikey", "token", "accesstoken", "secret", "environment", "env", "system", "config"].contains(normalized) {
                        result[key] = .string("<redacted>")
                    } else { result[key] = try walk(item, depth: depth + 1) }
                }
                return .object(result)
            case .array(let array):
                guard array.count <= 1_024 else { throw OpenCodeV2ProtocolError.limitExceeded }; return .array(try array.map { try walk($0, depth: depth + 1) })
            case .string(let string):
                _ = try text(value, maximum: 65_536, empty: true); return .string(string)
            case .number(let number): guard number.isFinite else { throw OpenCodeV2ProtocolError.invalidResponse }; return value
            default: return value
            }
        }
        let result = try walk(value, depth: 0)
        guard try JSONEncoder().encode(result).count <= 65_536 else { throw OpenCodeV2ProtocolError.limitExceeded }
        return result
    }
}
