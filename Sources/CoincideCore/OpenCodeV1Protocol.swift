import Foundation

public enum OpenCodeV1ProtocolError: Error, Sendable, Equatable, LocalizedError {
    case invalidResponse, invalidOwner, wrongDirectory, limitExceeded, invalidAnswer
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "OpenCode 1 returned a response that could not be verified safely."
        case .invalidOwner: "OpenCode 1 returned inconsistent conversation ownership."
        case .wrongDirectory: "OpenCode 1 returned a different workspace."
        case .limitExceeded: "OpenCode 1 returned more conversation data than can be handled safely."
        case .invalidAnswer: "Answer each OpenCode question using its available choices."
        }
    }
}

public struct OpenCodeV1PermissionRule: Sendable, Equatable, Hashable {
    public let permission: String
    public let pattern: String
    public let action: String
    public init(permission: String, pattern: String, action: String) {
        self.permission = permission; self.pattern = pattern; self.action = action
    }
    public var json: JSONValue { .object(["permission": .string(permission), "pattern": .string(pattern), "action": .string(action)]) }
}

public struct OpenCodeV1SessionInfo: Sendable, Equatable {
    public let id: String
    public let directory: String
    public let parentID: String?
    public let permissions: [OpenCodeV1PermissionRule]?
    public let hasRevert: Bool
}

public enum OpenCodeV1Status: String, Sendable, Equatable { case idle, busy, retry }

public struct OpenCodeV1Message: Sendable, Equatable {
    public let id: String
    public let sessionID: String
    public let role: String
    public let parentID: String?
    public let completed: Bool
    public let errorName: String?
}

public struct OpenCodeV1Tool: Sendable, Equatable {
    public let callID: String
    public let name: String
    public let status: String
    public let input: JSONValue
    public let output: String?
    public let title: String?
    public let childSessionID: String?
}

public struct OpenCodeV1Part: Sendable, Equatable {
    public let id: String
    public let sessionID: String
    public let messageID: String
    public let type: String
    public let text: String?
    public let ignored: Bool
    public let synthetic: Bool
    public let completed: Bool
    public let tool: OpenCodeV1Tool?
    public var tokens: OpenCodeStepTokens? = nil
    public var usageInvalid = false
}

public struct OpenCodeV1MessageSnapshot: Sendable, Equatable {
    public let info: OpenCodeV1Message
    public let parts: [OpenCodeV1Part]
}

public struct OpenCodeV1Todo: Sendable, Equatable {
    public let content: String
    public let status: String
    public let priority: String
}

public struct OpenCodeV1Permission: Sendable, Equatable {
    public enum Decision: String, Sendable { case once, always, reject }
    public let id: String
    public let sessionID: String
    public let permission: String
    public let patterns: [String]
    public let always: [String]
    public let toolMessageID: String?
    public let toolCallID: String?
    public func approval(localID: JSONValue) -> ApprovalRequest {
        var choices = [("once", "Approve Once")]
        if !always.isEmpty { choices += [("conversation", "Approve for Conversation"), ("always", "Approve for Workspace")] }
        choices.append(("reject", "Decline"))
        let options = choices.map { id, title in JSONValue.object(["optionId": .string(id), "name": .string(title)]) }
        return .init(id: localID, method: "opencode/permission", params: .object([
            "title": .string("Approve OpenCode \(permission)"),
            "description": .string(patterns.joined(separator: "\n")),
            "options": .array(options)
        ]))
    }
    public func replyBody(decision: Decision, message: String? = nil) throws -> JSONValue {
        var fields: [String: JSONValue] = ["reply": .string(decision.rawValue)]
        if let message { fields["message"] = .string(try OpenCodeV1Protocol.text(message, maximum: 16_384)) }
        return .object(fields)
    }
}

public struct OpenCodeV1Question: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let label: String
        public let description: String
    }
    public struct Question: Sendable, Equatable {
        public let key: String
        public let question: String
        public let header: String
        public let options: [Option]
        public let multiple: Bool
        public let custom: Bool
    }
    public let id: String
    public let sessionID: String
    public let toolMessageID: String?
    public let toolCallID: String?
    public let questions: [Question]

    public func approval(localID: JSONValue) -> ApprovalRequest {
        .init(id: localID, method: "opencode/question", params: .object([
            "id": .string(id), "sessionID": .string(sessionID),
            "questions": .array(questions.map { q in .object([
                "question": .string(q.question), "header": .string(q.header),
                "multiple": .bool(q.multiple), "custom": .bool(q.custom),
                "options": .array(q.options.map { .object(["label": .string($0.label), "description": .string($0.description)]) })
            ]) })
        ]))
    }
    public static func presentation(_ request: ApprovalRequest) throws -> Self {
        guard request.method == "opencode/question" else { throw OpenCodeV1ProtocolError.invalidResponse }
        return try OpenCodeV1Protocol.question(request.params)
    }
    public func answerBody(answers: [String: String]) throws -> JSONValue {
        try answerBody(selections: answers.mapValues { [$0] })
    }
    public func answerBody(selections: [String: [String]]) throws -> JSONValue {
        guard Set(selections.keys).isSubset(of: Set(questions.map(\.key))) else { throw OpenCodeV1ProtocolError.invalidAnswer }
        var ordered: [JSONValue] = []
        for question in questions {
            guard let answers = selections[question.key], !answers.isEmpty, answers.count <= 256,
                  question.multiple || answers.count == 1, Set(answers).count == answers.count else {
                throw OpenCodeV1ProtocolError.invalidAnswer
            }
            let known = Set(question.options.map(\.label))
            for value in answers {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.utf16.count <= 16_384, question.custom || known.contains(value),
                      !value.unicodeScalars.contains(where: { $0.value == 0 }) else { throw OpenCodeV1ProtocolError.invalidAnswer }
            }
            ordered.append(.array(answers.map(JSONValue.string)))
        }
        return .object(["answers": .array(ordered)])
    }
}

public struct OpenCodeV1Event: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case messageUpdated = "message.updated", messageRemoved = "message.removed"
        case partUpdated = "message.part.updated", partRemoved = "message.part.removed", partDelta = "message.part.delta"
        case sessionCreated = "session.created", sessionUpdated = "session.updated", sessionDeleted = "session.deleted"
        case sessionStatus = "session.status", sessionIdle = "session.idle", sessionError = "session.error"
        case permissionAsked = "permission.asked", permissionReplied = "permission.replied"
        case questionAsked = "question.asked", questionReplied = "question.replied", questionRejected = "question.rejected"
        case todoUpdated = "todo.updated", sessionCompacted = "session.compacted"
        case instanceDisposed = "server.instance.disposed", globalDisposed = "global.disposed"
    }
    public let kind: Kind
    public let sessionID: String?
    public let message: OpenCodeV1Message?
    public let part: OpenCodeV1Part?
    public let messageID: String?
    public let partID: String?
    public let delta: String?
    public let field: String?
    public let status: OpenCodeV1Status?
    public let permission: OpenCodeV1Permission?
    public let question: OpenCodeV1Question?
    public let requestID: String?
    public let session: OpenCodeV1SessionInfo?
    public let errorName: String?
    public let todos: [OpenCodeV1Todo]?
    public init(kind: Kind, sessionID: String? = nil, message: OpenCodeV1Message? = nil,
                part: OpenCodeV1Part? = nil, messageID: String? = nil, partID: String? = nil,
                delta: String? = nil, field: String? = nil, status: OpenCodeV1Status? = nil,
                permission: OpenCodeV1Permission? = nil, question: OpenCodeV1Question? = nil,
                requestID: String? = nil, session: OpenCodeV1SessionInfo? = nil,
                errorName: String? = nil, todos: [OpenCodeV1Todo]? = nil) {
        self.kind = kind; self.sessionID = sessionID; self.message = message; self.part = part
        self.messageID = messageID; self.partID = partID; self.delta = delta; self.field = field; self.status = status
        self.permission = permission; self.question = question; self.requestID = requestID; self.session = session
        self.errorName = errorName; self.todos = todos
    }
}

/// OpenCode SERVER 1.x. Its SDK's /v2 export does not mean server generation 2.
/// The directory-bound /event endpoint carries {type,properties}; it has no v2
/// durable sequence/inbox/execution envelope. Unknown payload fields are dropped.
public enum OpenCodeV1Protocol {
    public static func session(_ response: OpenCodeHTTPResponse, expectedID: String? = nil, directory: String) throws -> OpenCodeV1SessionInfo {
        try sessionValue(json(response), expectedID: expectedID, directory: directory)
    }
    public static func statuses(_ response: OpenCodeHTTPResponse) throws -> [String: OpenCodeV1Status] {
        guard let fields = try json(response).object, fields.count <= 4_096 else { throw OpenCodeV1ProtocolError.invalidResponse }
        var result: [String: OpenCodeV1Status] = [:]
        for (id, value) in fields { result[try identifier(.string(id))] = try status(value) }
        return result
    }
    public static func messages(_ response: OpenCodeHTTPResponse, sessionID: String) throws -> [OpenCodeV1MessageSnapshot] {
        guard let entries = try json(response).array, entries.count <= 4_096 else { throw OpenCodeV1ProtocolError.invalidResponse }
        var result: [OpenCodeV1MessageSnapshot] = [], messageIDs = Set<String>(), partIDs = Set<String>()
        for entry in entries {
            let info = try message(entry["info"])
            guard info.sessionID == sessionID, messageIDs.insert(info.id).inserted,
                  let rawParts = entry["parts"].array, rawParts.count <= 4_096 else { throw OpenCodeV1ProtocolError.invalidOwner }
            var parts: [OpenCodeV1Part] = []
            for value in rawParts {
                let part = try part(value)
                guard part.sessionID == sessionID, part.messageID == info.id, partIDs.insert(part.id).inserted else {
                    throw OpenCodeV1ProtocolError.invalidOwner
                }
                parts.append(part)
            }
            result.append(.init(info: info, parts: parts))
        }
        return result
    }
    public static func children(_ response: OpenCodeHTTPResponse, parentID: String, directory: String) throws -> [OpenCodeV1SessionInfo] {
        guard let entries = try json(response).array, entries.count <= 256 else { throw OpenCodeV1ProtocolError.invalidResponse }
        var seen = Set<String>()
        return try entries.map {
            let child = try sessionValue($0, directory: directory)
            guard child.parentID == parentID, seen.insert(child.id).inserted else { throw OpenCodeV1ProtocolError.invalidOwner }
            return child
        }
    }
    public static func permissionRules(_ value: JSONValue) throws -> [OpenCodeV1PermissionRule] {
        guard let values = value.array, values.count <= 1_024 else { throw OpenCodeV1ProtocolError.invalidResponse }
        return try values.map {
            let action = try identifier($0["action"])
            guard ["allow", "deny", "ask"].contains(action) else { throw OpenCodeV1ProtocolError.invalidResponse }
            return .init(permission: try identifier($0["permission"]), pattern: try identifier($0["pattern"], maximum: 16_384), action: action)
        }
    }
    public static func decode(_ frame: OpenCodeSSEEvent) throws -> OpenCodeV1Event? {
        guard frame.data.utf8.count <= 4_194_304,
              let data = frame.data.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw OpenCodeV1ProtocolError.invalidResponse
        }
        try bound(value)
        let type = try identifier(value["type"])
        guard let kind = OpenCodeV1Event.Kind(rawValue: type) else { return nil }
        let properties = value["properties"]
        guard properties.object != nil else { throw OpenCodeV1ProtocolError.invalidResponse }
        if kind == .instanceDisposed || kind == .globalDisposed { return .init(kind: kind) }
        let sid = try optionalIdentifier(properties["sessionID"])
        if kind != .sessionError, sid == nil { throw OpenCodeV1ProtocolError.invalidOwner }
        switch kind {
        case .messageUpdated:
            let info = try message(properties["info"])
            guard info.sessionID == sid else { throw OpenCodeV1ProtocolError.invalidOwner }
            return .init(kind: kind, sessionID: sid, message: info, messageID: info.id)
        case .messageRemoved:
            return .init(kind: kind, sessionID: sid, messageID: try identifier(properties["messageID"]))
        case .partUpdated:
            let value = try part(properties["part"])
            guard value.sessionID == sid else { throw OpenCodeV1ProtocolError.invalidOwner }
            return .init(kind: kind, sessionID: sid, part: value, messageID: value.messageID, partID: value.id)
        case .partDelta:
            return .init(kind: kind, sessionID: sid, messageID: try identifier(properties["messageID"]),
                partID: try identifier(properties["partID"]), delta: try text(properties["delta"], maximum: 1_048_576),
                field: try identifier(properties["field"]))
        case .partRemoved:
            return .init(kind: kind, sessionID: sid, messageID: try identifier(properties["messageID"]), partID: try identifier(properties["partID"]))
        case .sessionCreated, .sessionUpdated, .sessionDeleted:
            let info = try sessionValue(properties["info"])
            guard info.id == sid else { throw OpenCodeV1ProtocolError.invalidOwner }
            return .init(kind: kind, sessionID: sid, session: info)
        case .sessionStatus:
            return .init(kind: kind, sessionID: sid, status: try status(properties["status"]))
        case .sessionError:
            return .init(kind: kind, sessionID: sid, errorName: try errorName(properties["error"]) ?? "UnknownError")
        case .permissionAsked:
            let request = try permission(properties)
            return .init(kind: kind, sessionID: sid, permission: request, requestID: request.id)
        case .questionAsked:
            let request = try question(properties)
            return .init(kind: kind, sessionID: sid, question: request, requestID: request.id)
        case .permissionReplied, .questionReplied, .questionRejected:
            return .init(kind: kind, sessionID: sid, requestID: try identifier(properties["requestID"]))
        case .todoUpdated:
            guard let entries = properties["todos"].array, entries.count <= 1_024 else { throw OpenCodeV1ProtocolError.invalidResponse }
            let todos: [OpenCodeV1Todo] = try entries.map {
                .init(content: try text($0["content"], maximum: 16_384), status: try identifier($0["status"]), priority: try identifier($0["priority"]))
            }
            return .init(kind: kind, sessionID: sid, todos: todos)
        default: return .init(kind: kind, sessionID: sid)
        }
    }
    public static func question(_ value: JSONValue) throws -> OpenCodeV1Question {
        try bound(value)
        guard value.object != nil, let entries = value["questions"].array, !entries.isEmpty, entries.count <= 64 else {
            throw OpenCodeV1ProtocolError.invalidResponse
        }
        let questions: [OpenCodeV1Question.Question] = try entries.enumerated().map { index, item in
            guard item.object != nil, let options = item["options"].array, options.count <= 256 else {
                throw OpenCodeV1ProtocolError.invalidResponse
            }
            var seen = Set<String>()
            let choices: [OpenCodeV1Question.Option] = try options.map {
                let label = try identifier($0["label"], maximum: 16_384)
                guard seen.insert(label).inserted else { throw OpenCodeV1ProtocolError.invalidResponse }
                return .init(label: label, description: try text($0["description"], maximum: 16_384))
            }
            let custom = try bool(item["custom"], default: true)
            guard custom || !choices.isEmpty else { throw OpenCodeV1ProtocolError.invalidResponse }
            return .init(key: "question-\(index)", question: try text(item["question"], maximum: 65_536),
                header: try text(item["header"], maximum: 4_096), options: choices,
                multiple: try bool(item["multiple"], default: false), custom: custom)
        }
        let tool = try toolReference(value["tool"])
        return .init(id: try identifier(value["id"]), sessionID: try identifier(value["sessionID"]),
            toolMessageID: tool?.0, toolCallID: tool?.1, questions: questions)
    }
    public static func permission(_ value: JSONValue) throws -> OpenCodeV1Permission {
        try bound(value)
        let tool = try toolReference(value["tool"])
        return .init(id: try identifier(value["id"]), sessionID: try identifier(value["sessionID"]),
            permission: try identifier(value["permission"]), patterns: try strings(value["patterns"]),
            always: try strings(value["always"]), toolMessageID: tool?.0, toolCallID: tool?.1)
    }
    public static func message(_ value: JSONValue) throws -> OpenCodeV1Message {
        let role = try identifier(value["role"])
        guard ["user", "assistant"].contains(role), value["time"].object != nil,
              validTimestamp(value["time"]["created"]) else { throw OpenCodeV1ProtocolError.invalidResponse }
        let parent = try optionalIdentifier(value["parentID"])
        guard role != "assistant" || parent != nil else { throw OpenCodeV1ProtocolError.invalidOwner }
        let completed = value["time"]["completed"] != .null
        if completed, !validTimestamp(value["time"]["completed"]) { throw OpenCodeV1ProtocolError.invalidResponse }
        return .init(id: try identifier(value["id"]), sessionID: try identifier(value["sessionID"]),
            role: role, parentID: parent, completed: completed, errorName: try errorName(value["error"]))
    }
    public static func part(_ value: JSONValue) throws -> OpenCodeV1Part {
        let type = try identifier(value["type"])
        var text: String?, tool: OpenCodeV1Tool?
        if type == "text" || type == "reasoning" { text = try self.text(value["text"], maximum: 4_194_304) }
        if type == "tool" {
            let state = value["state"], status = try identifier(state["status"])
            guard ["pending", "running", "completed", "error"].contains(status), state["input"].object != nil else {
                throw OpenCodeV1ProtocolError.invalidResponse
            }
            let name = try identifier(value["tool"])
            let input = try safeInput(state["input"])
            let output = status == "completed" ? try self.text(state["output"], maximum: 4_194_304) :
                status == "error" ? "The native tool failed." : nil
            let lowerChild = name == "task" ? try optionalIdentifier(state["metadata"]["sessionId"]) : nil
            let upperChild = name == "task" ? try optionalIdentifier(state["metadata"]["sessionID"]) : nil
            if let lowerChild, let upperChild, lowerChild != upperChild { throw OpenCodeV1ProtocolError.invalidOwner }
            let child = lowerChild ?? upperChild
            tool = .init(callID: try identifier(value["callID"]), name: name, status: status, input: input,
                output: output, title: try optionalText(state["title"], maximum: 16_384), childSessionID: child)
        }
        let ended = value["time"]["end"] != .null
        if ended, !validTimestamp(value["time"]["end"]) { throw OpenCodeV1ProtocolError.invalidResponse }
        var result = OpenCodeV1Part(id: try identifier(value["id"]), sessionID: try identifier(value["sessionID"]),
            messageID: try identifier(value["messageID"]), type: type, text: text,
            ignored: try bool(value["ignored"], default: false), synthetic: try bool(value["synthetic"], default: false),
            completed: ended, tool: tool)
        if type == "step-finish" {
            do { result.tokens = try OpenCodeStepTokens.decode(value["tokens"]) }
            catch { result.usageInvalid = true }
        }
        return result
    }
    private static func sessionValue(_ value: JSONValue, expectedID: String? = nil, directory: String? = nil) throws -> OpenCodeV1SessionInfo {
        let id = try identifier(value["id"]), path = try identifier(value["directory"], maximum: 16_384)
        guard expectedID == nil || id == expectedID else { throw OpenCodeV1ProtocolError.invalidOwner }
        guard path.hasPrefix("/"), directory == nil || path == directory else { throw OpenCodeV1ProtocolError.wrongDirectory }
        let revert = value["revert"]
        if revert != .null { _ = try identifier(revert["messageID"]) }
        return .init(id: id, directory: path, parentID: try optionalIdentifier(value["parentID"]),
            permissions: value["permission"] == .null ? nil : try permissionRules(value["permission"]), hasRevert: revert != .null)
    }
    private static func json(_ response: OpenCodeHTTPResponse) throws -> JSONValue {
        if response.status == 401 || response.status == 403 { throw OpenCodeProtocolError.unauthorized }
        let mime = response.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard response.status == 200, mime == "application/json" || (mime?.hasPrefix("application/") == true && mime?.hasSuffix("+json") == true),
              response.body.count <= 16_777_216, let value = try? JSONDecoder().decode(JSONValue.self, from: response.body) else {
            throw OpenCodeV1ProtocolError.invalidResponse
        }
        try bound(value); return value
    }
    private static func status(_ value: JSONValue) throws -> OpenCodeV1Status {
        guard let result = OpenCodeV1Status(rawValue: try identifier(value["type"])) else { throw OpenCodeV1ProtocolError.invalidResponse }
        if result == .retry {
            guard case .number(let attempt) = value["attempt"], attempt.isFinite, attempt >= 0, attempt.rounded(.towardZero) == attempt,
                  validTimestamp(value["next"]) else { throw OpenCodeV1ProtocolError.invalidResponse }
            _ = try text(value["message"], maximum: 65_536)
        }
        return result
    }
    private static func errorName(_ value: JSONValue) throws -> String? {
        guard value != .null else { return nil }
        let raw = try identifier(value["name"], maximum: 256)
        let names = Set(["ProviderAuthError", "UnknownError", "MessageOutputLengthError", "MessageAbortedError", "StructuredOutputError", "ContextOverflowError", "APIError"])
        return names.contains(raw) ? raw : "UnknownError"
    }
    private static func toolReference(_ value: JSONValue) throws -> (String, String)? {
        guard value != .null else { return nil }
        return (try identifier(value["messageID"]), try identifier(value["callID"]))
    }
    private static func strings(_ value: JSONValue) throws -> [String] {
        guard let entries = value.array, entries.count <= 1_024 else { throw OpenCodeV1ProtocolError.invalidResponse }
        return try entries.map { try identifier($0, maximum: 16_384) }
    }
    private static func bool(_ value: JSONValue, default fallback: Bool) throws -> Bool {
        if value == .null { return fallback }
        guard case .bool(let answer) = value else { throw OpenCodeV1ProtocolError.invalidResponse }
        return answer
    }
    private static func validTimestamp(_ value: JSONValue) -> Bool {
        guard case .number(let number) = value else { return false }
        return number.isFinite && number >= 0
    }
    static func identifier(_ value: JSONValue, maximum: Int = 4_096) throws -> String {
        let value = try text(value, maximum: maximum)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw OpenCodeV1ProtocolError.invalidResponse }
        return value
    }
    private static func optionalIdentifier(_ value: JSONValue) throws -> String? { value == .null ? nil : try identifier(value) }
    private static func optionalText(_ value: JSONValue, maximum: Int) throws -> String? { value == .null ? nil : try text(value, maximum: maximum) }
    static func text(_ value: JSONValue, maximum: Int) throws -> String {
        guard let text = value.string, text.utf8.count <= maximum,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw OpenCodeV1ProtocolError.invalidResponse }
        return text
    }
    static func text(_ value: String, maximum: Int) throws -> String { try text(.string(value), maximum: maximum) }
    private static func safeInput(_ value: JSONValue) throws -> JSONValue {
        try bound(value, maximumBytes: 65_536)
        func clean(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let fields):
                return .object(fields.filter { key, _ in
                    let key = key.lowercased().filter { $0.isLetter || $0.isNumber }
                    return !["authorization", "password", "token", "apikey", "secret", "credential", "environment", "headers"].contains(where: key.contains)
                }.mapValues(clean))
            case .array(let values): return .array(values.map(clean))
            default: return value
            }
        }
        return clean(value)
    }
    private static func bound(_ value: JSONValue, maximumBytes: Int = 16_777_216) throws {
        var pending: [(JSONValue, Int)] = [(value, 0)], bytes = 0, nodes = 0
        while let (value, depth) = pending.popLast() {
            nodes += 1
            guard nodes <= 65_536, depth <= 32 else { throw OpenCodeV1ProtocolError.limitExceeded }
            switch value {
            case .string(let value): bytes += value.utf8.count
            case .array(let values):
                guard values.count <= 4_096 else { throw OpenCodeV1ProtocolError.limitExceeded }
                pending += values.map { ($0, depth + 1) }
            case .object(let fields):
                guard fields.count <= 4_096 else { throw OpenCodeV1ProtocolError.limitExceeded }
                for (key, value) in fields { bytes += key.utf8.count; pending.append((value, depth + 1)) }
            default: bytes += 8
            }
            guard bytes <= maximumBytes, pending.count <= 65_536 else { throw OpenCodeV1ProtocolError.limitExceeded }
        }
    }
}
