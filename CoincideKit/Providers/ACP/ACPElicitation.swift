import Foundation

/// Turns a form elicitation into Coincide questions and the user's answers back into the
/// form's content. Each schema property becomes one question: enums and booleans become
/// choices, arrays of enums allow several, and plain strings and numbers take typed text.
enum ACPElicitationForm {
    private struct Field {
        enum Kind {
            case text
            case number(integer: Bool)
            case boolean
            case choice
            case choices
        }

        var key: String
        var kind: Kind
        /// Label shown to the user, and the value sent back.
        var options: [Choice]
        var question: UserQuestion
    }

    /// Questions for a form elicitation, or nil when it has nothing Coincide can ask.
    @MainActor
    static func questionSet(_ request: ACPElicitationRequest) -> ACPQuestionSet? {
        guard request.mode == "form", let schema = request.schema, let properties = schema["properties"]?.object,
            !properties.isEmpty
        else { return nil }
        // JSON objects lose their order here; ask required fields first, the rest alphabetically.
        let required = (schema["required"]?.array ?? []).compactMap(\.string).filter { properties[$0] != nil }
        let keys = required + properties.keys.filter { !required.contains($0) }.sorted()
        let fields = keys.compactMap { field($0, properties[$0] ?? .null, message: request.message) }
        guard !fields.isEmpty else { return nil }
        let title = ACPToolCallState.nonEmpty(request.message)
        return ACPQuestionSet(title: title, questions: fields.map(\.question)) { answers in
            guard let answers else { return ["action": "cancel"] }
            var content: [String: JSONValue] = [:]
            for field in fields {
                if let value = value(for: field, answers[field.key] ?? []) { content[field.key] = value }
            }
            return ["action": "accept", "content": .object(content)]
        }
    }

    private static func field(_ key: String, _ property: JSONValue, message: String) -> Field? {
        let type = property["type"]?.string ?? "string"
        let title = property["title"]?.string.flatMap(ACPToolCallState.nonEmpty)
        let prompt =
            property["description"]?.string.flatMap(ACPToolCallState.nonEmpty) ?? title ?? ACPToolCallState.nonEmpty(message)
            ?? key
        let kind: Field.Kind
        var options: [Choice] = []
        switch type {
        case "boolean":
            kind = .boolean
            options = [Choice(label: String(localized: "Yes"), value: "true"), Choice(label: String(localized: "No"), value: "false")]
        case "number", "integer":
            kind = .number(integer: type == "integer")
        case "array":
            kind = .choices
            options = choices(property["items"] ?? .null)
            guard !options.isEmpty else { return nil }
        case "string":
            options = choices(property)
            kind = options.isEmpty ? .text : .choice
        default:
            return nil
        }
        let question = UserQuestion(
            id: key, header: title, prompt: prompt,
            options: options.map { UserQuestion.Option(label: $0.label, detail: $0.detail) },
            allowsMultipleSelection: { if case .choices = kind { true } else { false } }(), allowsFreeText: options.isEmpty)
        return Field(key: key, kind: kind, options: options, question: question)
    }

    private struct Choice {
        var label: String
        var value: String
        var detail: String?
    }

    /// `enum` values, or `oneOf`/`anyOf` entries with `const` and `title`.
    private static func choices(_ schema: JSONValue) -> [Choice] {
        if let values = schema["enum"]?.array?.compactMap(\.string), !values.isEmpty {
            return values.map { Choice(label: $0, value: $0) }
        }
        return (schema["oneOf"]?.array ?? schema["anyOf"]?.array ?? []).compactMap { entry in
            guard let value = entry["const"]?.string else { return nil }
            return Choice(
                label: entry["title"]?.string.flatMap(ACPToolCallState.nonEmpty) ?? value, value: value,
                detail: entry["description"]?.string.flatMap(ACPToolCallState.nonEmpty))
        }
    }

    private static func value(for field: Field, _ answers: [String]) -> JSONValue? {
        let answers = answers.compactMap(ACPToolCallState.nonEmpty)
        func mapped(_ answer: String) -> String {
            field.options.first { $0.label == answer }?.value ?? field.options.first { $0.value == answer }?.value ?? answer
        }
        switch field.kind {
        case .text:
            return answers.first.map(JSONValue.string)
        case .choice:
            return answers.first.map { .string(mapped($0)) }
        case .choices:
            return answers.isEmpty ? nil : .array(answers.map { .string(mapped($0)) })
        case .boolean:
            guard let answer = answers.first.map(mapped)?.lowercased() else { return nil }
            if ["true", "yes", "y", "1"].contains(answer) { return .bool(true) }
            if ["false", "no", "n", "0"].contains(answer) { return .bool(false) }
            return nil
        case .number(let integer):
            guard let answer = answers.first, let number = Double(answer.replacingOccurrences(of: ",", with: ".")),
                number.isFinite
            else { return nil }
            if integer {
                guard number.rounded() == number else { return nil }
                return .number(number)
            }
            return .number(number)
        }
    }
}
