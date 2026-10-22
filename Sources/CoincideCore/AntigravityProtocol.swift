import Foundation

public enum AntigravityProtocol {
    public static let questionMethod = "antigravity/question"
    public static let permissionMethod = "antigravity/permission"
    public static let failureMessage = "The Antigravity response could not be verified. Reconnect before continuing."
    public static func failure() -> CoincideError { .init(failureMessage) }
    static func string(_ value: JSONValue, maximum: Int = 4_096, empty: Bool = false) throws -> String {
        guard let text = value.string, (empty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              text.utf8.count <= maximum, !text.contains("\0") else { throw failure() }; return text
    }
    static func optional(_ value: JSONValue, maximum: Int = 4_096) throws -> String? {
        value == .null ? nil : try string(value, maximum: maximum)
    }
    public static func mode(permission: PermissionMode) -> String {
        switch permission { case .supervised, .auto: "default"; case .autoAcceptEdits: "auto_edit"; case .fullAccess: "yolo" }
    }
    static func validateInitialization(_ value: JSONValue, authMethod: String) throws {
        guard [JSONValue.number(1), .number(2)].contains(value["protocolVersion"]), let auth = value["authMethods"].array, auth.count <= 64,
              auth.contains(where: { $0["id"] == .string(authMethod) }) else { throw failure() }
    }
    static func selectOption(_ setup: JSONValue, category: String) -> JSONValue? {
        setup["configOptions"].array?.first { ($0["id"] == .string(category) || $0["category"] == .string(category)) && $0["type"] == .string("select") }
    }
    static func optionID(_ value: JSONValue) throws -> String { try string(value["id"] == .null ? value["configId"] : value["id"]) }
    static func options(_ value: JSONValue) throws -> [JSONValue] {
        guard let rows = value["options"].array, rows.count <= 2_048 else { throw failure() }
        let flattened = rows.flatMap { $0["options"].array ?? [$0] }
        guard flattened.count <= 2_048 else { throw failure() }; return flattened
    }
    public static func models(_ setup: JSONValue) throws -> [ProviderModel] {
        let config = setup["configOptions"].array?.first { $0["id"] == .string("model") || $0["category"] == .string("model") }
        let rows: [JSONValue], current: String?
        if let config {
            guard config["type"] == .string("select") else { return [] }
            rows = try options(config); current = try optional(config["currentValue"])
        } else {
            rows = setup["models"]["availableModels"].array ?? []
            guard rows.count <= 2_048 else { throw failure() }; current = try optional(setup["models"]["currentModelId"])
        }
        var seen = Set<String>(), result: [ProviderModel] = []
        for row in rows {
            let id = try string(config == nil ? row["modelId"] : row["value"])
            guard seen.insert(id).inserted else { continue }
            let name = row["name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? id
            _ = try string(.string(name))
            result.append(.init(id: id, name: name, isDefault: id == current))
        }
        return result
    }
    static func currentModel(_ setup: JSONValue) -> String? {
        selectOption(setup, category: "model")?["currentValue"].string ?? setup["models"]["currentModelId"].string
    }
    static func currentMode(_ setup: JSONValue) -> String? {
        selectOption(setup, category: "mode")?["currentValue"].string ?? setup["modes"]["currentModeId"].string
    }
    static func metadata(_ value: JSONValue) -> JSONValue {
        let allowed: Set<String> = ["sessionId", "configOptions", "models", "modes", "currentModelId", "currentModeId", "availableModels", "availableModes", "id", "configId", "name", "description", "category", "type", "currentValue", "options", "value"]
        switch value {
        case .object(let fields): return .object(fields.filter { allowed.contains($0.key) }.mapValues(metadata))
        case .array(let rows): return .array(rows.prefix(2_048).map(metadata))
        case .string(let text): return .string(String(text.prefix(16_384)))
        default: return value
        }
    }
}

/// Native interaction_ requests are questions, even though ACP carries them on
/// request_permission. Opaque option IDs are retained independently of labels.
public struct AntigravityPermissionRequest: Sendable, Equatable {
    public struct Option: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let kind: String
        public let securityWarning: String?
    }
    public let sessionID: String
    public let toolCallID: String
    public let title: String
    public let options: [Option]
    public var isQuestion: Bool { toolCallID.hasPrefix("interaction_") }
    public init(params: JSONValue) throws {
        sessionID = try AntigravityProtocol.string(params["sessionId"])
        toolCallID = try AntigravityProtocol.string(params["toolCall"]["toolCallId"])
        title = try AntigravityProtocol.optional(params["toolCall"]["title"], maximum: 8_000) ?? "Antigravity needs a decision"
        guard let values = params["options"].array, !values.isEmpty, values.count <= 64 else { throw AntigravityProtocol.failure() }
        options = try values.map { value in
            let warning = value["_meta"]["agy.security.warning"]
            let text = warning["message"].string ?? warning["title"].string
            if let text { _ = try AntigravityProtocol.string(.string(text), maximum: 16_384, empty: true) }
            return .init(id: try AntigravityProtocol.string(value["optionId"]), name: try AntigravityProtocol.string(value["name"]), kind: try AntigravityProtocol.string(value["kind"]), securityWarning: text.map { String($0.prefix(512)) })
        }
        guard Set(options.map(\.id)).count == options.count else { throw AntigravityProtocol.failure() }
    }
    public func response(optionID: String?) throws -> JSONValue {
        guard let optionID else { return .object(["outcome": .object(["outcome": .string("cancelled")])]) }
        guard options.contains(where: { $0.id == optionID }) else { throw AntigravityProtocol.failure() }
        return .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(optionID)])])
    }
    public func decision(allow: Bool) throws -> JSONValue {
        guard !isQuestion else { throw AntigravityProtocol.failure() }
        let kind = allow ? "allow_once" : "reject_once"
        if let option = options.first(where: { $0.kind == kind }) { return try response(optionID: option.id) }
        guard !allow else { throw AntigravityProtocol.failure() }; return try response(optionID: nil)
    }
    public func answer(answers: [String: String]) throws -> JSONValue {
        guard isQuestion, Set(answers.keys) == [toolCallID], let id = answers[toolCallID] else { throw AntigravityProtocol.failure() }
        return try response(optionID: id)
    }
    public func answer(selections: [String: [String]]) throws -> JSONValue {
        guard isQuestion, Set(selections.keys) == [toolCallID], let ids = selections[toolCallID], ids.count == 1 else { throw AntigravityProtocol.failure() }
        return try response(optionID: ids[0])
    }
    public func approval(localID: JSONValue) -> ApprovalRequest {
        .init(id: localID, method: isQuestion ? AntigravityProtocol.questionMethod : AntigravityProtocol.permissionMethod,
              params: .object(["toolCallID": .string(toolCallID), "title": .string(title), "options": .array(options.map { option in
                  var row: [String: JSONValue] = ["optionId": .string(option.id), "name": .string(option.name), "kind": .string(option.kind)]
                  if let warning = option.securityWarning { row["securityWarning"] = .string(warning) }; return .object(row)
              })]))
    }
    public static func presentation(_ request: ApprovalRequest) throws -> Self {
        guard [AntigravityProtocol.questionMethod, AntigravityProtocol.permissionMethod].contains(request.method),
              let fields = request.params.object, Set(fields.keys) == ["toolCallID", "title", "options"], let rows = fields["options"]?.array else { throw AntigravityProtocol.failure() }
        let normalized = try rows.map { value -> JSONValue in
            guard let row = value.object, Set(row.keys).isSubset(of: ["optionId", "name", "kind", "securityWarning"]) else { throw AntigravityProtocol.failure() }
            var result: [String: JSONValue] = ["optionId": value["optionId"], "name": value["name"], "kind": value["kind"]]
            if value["securityWarning"] != .null { result["_meta"] = .object(["agy.security.warning": .object(["message": value["securityWarning"]])]) }; return .object(result)
        }
        let parsed = try Self(params: .object(["sessionId": .string("presentation"), "toolCall": .object(["toolCallId": request.params["toolCallID"], "title": request.params["title"]]), "options": .array(normalized)]))
        guard parsed.isQuestion == (request.method == AntigravityProtocol.questionMethod) else { throw AntigravityProtocol.failure() }; return parsed
    }
}
