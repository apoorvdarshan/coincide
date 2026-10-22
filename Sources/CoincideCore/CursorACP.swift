import Foundation

public struct CursorACPQuestionOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}
public struct CursorACPQuestion: Sendable, Equatable, Identifiable {
    public let id: String
    public let prompt: String
    public let options: [CursorACPQuestionOption]
    public let allowMultiple: Bool
    public init(id: String, prompt: String, options: [CursorACPQuestionOption], allowMultiple: Bool = false) {
        self.id = id; self.prompt = prompt; self.options = options; self.allowMultiple = allowMultiple
    }
}
public struct CursorACPQuestionRequest: Sendable, Equatable {
    public let toolCallID: String
    public let title: String?
    public let questions: [CursorACPQuestion]
    public init(toolCallID: String, title: String? = nil, questions: [CursorACPQuestion]) {
        self.toolCallID = toolCallID; self.title = title; self.questions = questions
    }
    public init(params: JSONValue) throws {
        try ACPIntegrationValidation.bound(params)
        guard params.object != nil,
              let tool = try ACPIntegrationValidation.string(params["toolCallId"], maximum: 4_096),
              let rows = params["questions"].array, !rows.isEmpty, rows.count <= 32 else { throw ACPIntegrationValidation.failure() }
        toolCallID = tool; title = try ACPIntegrationValidation.string(params["title"], maximum: 1_024)
        var decoded: [CursorACPQuestion] = [], ids: Set<String> = []
        for row in rows {
            guard row.object != nil, let id = try ACPIntegrationValidation.string(row["id"], maximum: 4_096), ids.insert(id).inserted,
                  let prompt = try ACPIntegrationValidation.string(row["prompt"], maximum: 32_768, multiline: true),
                  let options = row["options"].array, !options.isEmpty, options.count <= 64 else { throw ACPIntegrationValidation.failure() }
            var optionIDs: Set<String> = [], choices: [CursorACPQuestionOption] = []
            for option in options {
                guard option.object != nil, let optionID = try ACPIntegrationValidation.string(option["id"], maximum: 4_096), optionIDs.insert(optionID).inserted,
                      let label = try ACPIntegrationValidation.string(option["label"], maximum: 8_192, multiline: true) else { throw ACPIntegrationValidation.failure() }
                choices.append(.init(id: optionID, label: label))
            }
            let multiple: Bool
            switch row["allowMultiple"] { case .null: multiple = false; case .bool(let value): multiple = value; default: throw ACPIntegrationValidation.failure() }
            decoded.append(.init(id: id, prompt: prompt, options: choices, allowMultiple: multiple))
        }
        questions = decoded
    }
    public var parameters: JSONValue {
        var fields: [String: JSONValue] = ["toolCallId": .string(toolCallID), "questions": .array(questions.map { question in
            .object(["id": .string(question.id), "prompt": .string(question.prompt), "allowMultiple": .bool(question.allowMultiple),
                     "options": .array(question.options.map { .object(["id": .string($0.id), "label": .string($0.label)]) })])
        })]
        if let title { fields["title"] = .string(title) }
        return .object(fields)
    }
    public func response(for selections: [String: [String]]) throws -> JSONValue {
        // Revalidate even programmatically constructed/public model values.
        _ = try Self(params: parameters)
        guard Set(selections.keys) == Set(questions.map(\.id)) else { throw ACPIntegrationValidation.failure() }
        var answers: [JSONValue] = []
        for question in questions {
            let ids = selections[question.id] ?? [], selected = Set(ids)
            guard !ids.isEmpty, ids.count == selected.count, question.allowMultiple || ids.count == 1,
                  selected.isSubset(of: Set(question.options.map(\.id))) else { throw ACPIntegrationValidation.failure() }
            // Provider option ordering makes replay deterministic without converting labels.
            answers.append(.object(["questionId": .string(question.id),
                "selectedOptionIds": .array(question.options.filter { selected.contains($0.id) }.map { .string($0.id) })]))
        }
        return .object(["outcome": .object(["outcome": .string("answered"), "answers": .array(answers)])])
    }
}

public enum CursorACPTodoStatus: String, Sendable, Equatable {
    case pending, inProgress = "in_progress", completed, cancelled
}
public struct CursorACPTodo: Sendable, Equatable, Identifiable {
    public let id: String
    public let content: String
    public let status: CursorACPTodoStatus
    public init(id: String, content: String, status: CursorACPTodoStatus) { self.id = id; self.content = content; self.status = status }
    var value: JSONValue { .object(["id": .string(id), "content": .string(content), "status": .string(status.rawValue)]) }
}
public struct CursorACPPlanPhase: Sendable, Equatable {
    public let name: String
    public let todos: [CursorACPTodo]
    public init(name: String, todos: [CursorACPTodo]) { self.name = name; self.todos = todos }
}
public struct CursorACPPlanRequest: Sendable, Equatable {
    public let toolCallID: String
    public let name: String?
    public let overview: String?
    public let plan: String
    public let todos: [CursorACPTodo]
    public let phases: [CursorACPPlanPhase]
    public let isProject: Bool?
    public init(toolCallID: String, name: String? = nil, overview: String? = nil, plan: String,
                todos: [CursorACPTodo] = [], phases: [CursorACPPlanPhase] = [], isProject: Bool? = nil) {
        self.toolCallID = toolCallID; self.name = name; self.overview = overview; self.plan = plan
        self.todos = todos; self.phases = phases; self.isProject = isProject
    }
    public init(params: JSONValue) throws {
        try ACPIntegrationValidation.bound(params)
        guard params.object != nil, let tool = try ACPIntegrationValidation.string(params["toolCallId"], maximum: 4_096),
              let text = try ACPIntegrationValidation.string(params["plan"], maximum: 1_048_576, multiline: true) else { throw ACPIntegrationValidation.failure() }
        toolCallID = tool; plan = text
        name = try ACPIntegrationValidation.string(params["name"], maximum: 1_024)
        overview = try ACPIntegrationValidation.string(params["overview"], maximum: 32_768, multiline: true)
        todos = try Self.decodeTodos(params["todos"])
        if params["phases"] == .null { phases = [] }
        else {
            guard let values = params["phases"].array, values.count <= 64 else { throw ACPIntegrationValidation.failure() }
            phases = try values.map { value in
                guard value.object != nil, let name = try ACPIntegrationValidation.string(value["name"], maximum: 1_024) else { throw ACPIntegrationValidation.failure() }
                return .init(name: name, todos: try Self.decodeTodos(value["todos"]))
            }
        }
        switch params["isProject"] { case .null: isProject = nil; case .bool(let value): isProject = value; default: throw ACPIntegrationValidation.failure() }
    }
    static func decodeTodos(_ value: JSONValue) throws -> [CursorACPTodo] {
        guard let values = value.array, values.count <= 256 else { throw ACPIntegrationValidation.failure() }
        var ids: Set<String> = []
        return try values.map { value in
            guard value.object != nil, let id = try ACPIntegrationValidation.string(value["id"], maximum: 4_096), ids.insert(id).inserted,
                  let content = try ACPIntegrationValidation.string(value["content"], maximum: 16_384, multiline: true),
                  let raw = value["status"].string, let status = CursorACPTodoStatus(rawValue: raw) else { throw ACPIntegrationValidation.failure() }
            return .init(id: id, content: content, status: status)
        }
    }
    public var parameters: JSONValue {
        var value: [String: JSONValue] = ["toolCallId": .string(toolCallID), "plan": .string(plan), "todos": .array(todos.map(\.value)),
            "phases": .array(phases.map { .object(["name": .string($0.name), "todos": .array($0.todos.map(\.value))]) })]
        if let name { value["name"] = .string(name) }; if let overview { value["overview"] = .string(overview) }
        if let isProject { value["isProject"] = .bool(isProject) }; return .object(value)
    }
}

public enum CursorACPMethod {
    public static let question = "_cursor/ask_question"
    public static let plan = "_cursor/create_plan"
    public static func canonical(_ method: String) -> String? {
        switch method {
        case question, "cursor/ask_question": question
        case plan, "cursor/create_plan": plan
        default: nil
        }
    }
    static func outcome(_ outcome: String) -> JSONValue { .object(["outcome": .object(["outcome": .string(outcome)])]) }
}

extension ApprovalRequest {
    public var cursorQuestion: CursorACPQuestionRequest? {
        guard CursorACPMethod.canonical(method) == CursorACPMethod.question else { return nil }
        return try? .init(params: params)
    }
    public var cursorPlan: CursorACPPlanRequest? {
        guard CursorACPMethod.canonical(method) == CursorACPMethod.plan else { return nil }
        return try? .init(params: params)
    }
}
