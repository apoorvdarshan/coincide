import Foundation

/// OpenCode forms (its question tool, and prompts from plugins) asked as Coincide questions.
enum OpenCodeQuestions {
    /// A form field and how its answer goes back to OpenCode.
    struct Field: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case text
            case choice
            case multipleChoice
            case boolean
            case number
            case integer
        }

        struct Option: Hashable, Sendable {
            var label: String
            var value: String
        }

        var key: String
        var kind: Kind
        var options: [Option]
    }

    /// The questions of a `Form.Info`, or nil when the form has a field Coincide cannot ask: a link to
    /// open, a hidden field, or one that depends on another answer.
    nonisolated static func parse(_ form: JSONValue) -> (request: UserInputRequest, fields: [Field])? {
        guard let id = form["id"]?.string, let rawFields = form["fields"]?.array, !rawFields.isEmpty else { return nil }
        var questions: [UserQuestion] = []
        var fields: [Field] = []
        for (index, raw) in rawFields.enumerated() {
            guard let key = raw["key"]?.string, let type = raw["type"]?.string, raw["hidden"]?.bool != true,
                (raw["when"]?.array ?? []).isEmpty
            else { return nil }
            let title = nonEmpty(raw["title"]?.string)
            let description = nonEmpty(raw["description"]?.string)
            let choices = (raw["options"]?.array ?? []).compactMap(option)
            let custom = raw["custom"]?.bool == true

            let field: Field
            let allowsFreeText: Bool
            switch type {
            case "string":
                field = Field(key: key, kind: choices.isEmpty ? .text : .choice, options: choices.map(\.option))
                allowsFreeText = custom || choices.isEmpty
            case "multiselect":
                field = Field(key: key, kind: .multipleChoice, options: choices.map(\.option))
                allowsFreeText = custom || choices.isEmpty
            case "boolean":
                let options = [
                    Field.Option(label: String(localized: "Yes"), value: "true"),
                    Field.Option(label: String(localized: "No"), value: "false"),
                ]
                field = Field(key: key, kind: .boolean, options: options)
                allowsFreeText = false
            case "number", "integer":
                field = Field(key: key, kind: type == "integer" ? .integer : .number, options: [])
                allowsFreeText = true
            default:
                return nil
            }
            let options =
                field.kind == .boolean
                ? field.options.map { UserQuestion.Option(label: $0.label) }
                : choices.map { UserQuestion.Option(label: $0.option.label, detail: $0.detail) }
            questions.append(
                UserQuestion(
                    id: key, header: description == nil ? nil : title,
                    prompt: description ?? title ?? String(localized: "Question \(index + 1)"), options: options,
                    allowsMultipleSelection: field.kind == .multipleChoice, allowsFreeText: allowsFreeText))
            fields.append(field)
        }
        let request = UserInputRequest(id: id, title: nonEmpty(form["title"]?.string), questions: questions)
        return (request, fields)
    }

    /// The `Form.Answer` for the user's answers (question id → chosen labels or typed text). Chosen labels
    /// become their option values; questions left unanswered, or answered with text the field cannot take,
    /// are left out.
    nonisolated static func answer(_ answers: [String: [String]], fields: [Field]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for field in fields {
            let values = (answers[field.key] ?? []).compactMap(nonEmpty).map { answer in
                field.options.first { $0.label == answer }?.value ?? answer
            }
            guard let first = values.first else { continue }
            switch field.kind {
            case .text, .choice:
                result[field.key] = .string(values.joined(separator: ", "))
            case .multipleChoice:
                result[field.key] = .array(values.map(JSONValue.string))
            case .boolean:
                switch first.lowercased() {
                case "true", "yes": result[field.key] = .bool(true)
                case "false", "no": result[field.key] = .bool(false)
                default: break
                }
            case .number, .integer:
                guard let number = Double(first), number.isFinite, field.kind == .number || number.rounded() == number
                else { continue }
                result[field.key] = .number(number)
            }
        }
        return result
    }

    private nonisolated static func option(_ json: JSONValue) -> (option: Field.Option, detail: String?)? {
        guard let value = json["value"]?.string else { return nil }
        let label = nonEmpty(json["label"]?.string) ?? value
        let description = nonEmpty(json["description"]?.string)
        // The question tool often repeats the label as its description.
        let detail = description.flatMap { $0.caseInsensitiveCompare(label) == .orderedSame ? nil : $0 }
        return (Field.Option(label: label, value: value), detail)
    }

    private nonisolated static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
