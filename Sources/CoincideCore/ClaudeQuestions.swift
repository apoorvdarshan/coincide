import Foundation

/// The native AskUserQuestion input and answer contract from Claude Agent SDK.
/// Question text and option labels are wire values; never trim or replace them.
public struct ClaudeQuestionRequest: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let label: String
        public let description: String
        public let preview: String?
    }
    public struct Question: Sendable, Equatable {
        public let question: String
        public let header: String
        public let options: [Option]
        public let multiSelect: Bool
    }
    public let questions: [Question]
    public let input: JSONValue

    public init(request: ApprovalRequest) throws {
        guard request.isClaudeQuestion, let fields = request.params["input"].object,
              let values = fields["questions"]?.array, (1...4).contains(values.count) else { throw Self.invalid() }
        try MCPProtocol.validateJSON(request.params)
        input = .object(fields)
        var seen: Set<String> = [], parsed: [Question] = []
        for (index, value) in values.enumerated() {
            guard value.object != nil, let text = value["question"].string, Self.text(text, limit: 16_384),
                  seen.insert(text).inserted, let options = value["options"].array,
                  // Older peers emitted a single option; retain that supported input.
                  (1...4).contains(options.count) else { throw Self.invalid() }
            let header: String
            if let raw = value.object?["header"] {
                guard let title = raw.string, Self.text(title, limit: 512, allowEmpty: true) else { throw Self.invalid() }
                header = title.isEmpty ? "Question \(index + 1)" : title
            } else { header = "Question \(index + 1)" }
            let multiple: Bool
            if let raw = value.object?["multiSelect"] {
                guard case .bool(let flag) = raw else { throw Self.invalid() }; multiple = flag
            } else { multiple = false }
            var labels: Set<String> = [], choices: [Option] = []
            for option in options {
                guard option.object != nil, let label = option["label"].string,
                      Self.text(label, limit: 4_096), labels.insert(label).inserted else { throw Self.invalid() }
                let description = try Self.optionalText(option, key: "description", limit: 16_384) ?? ""
                let preview = try Self.optionalText(option, key: "preview", limit: 65_536)
                choices.append(.init(label: label, description: description, preview: preview))
            }
            parsed.append(.init(question: text, header: header, options: choices, multiSelect: multiple))
        }
        questions = parsed
    }

    /// SDK answers are strings keyed by exact native question text. T3 joins
    /// multiple labels with ", "; custom answers use precisely the same path.
    public func response(selections: [String: [String]], notes: [String: String] = [:]) throws -> JSONValue {
        let keys = Set(questions.map(\.question))
        guard Set(selections.keys) == keys, Self.exactKeys(Array(selections.keys), within: keys),
              Self.exactKeys(Array(notes.keys), within: keys) else { throw Self.invalidAnswers() }
        var answers: [String: String] = [:]
        for question in questions {
            guard let chosen = selections[question.question], !chosen.isEmpty, chosen.count <= 64,
                  question.multiSelect || chosen.count == 1,
                  Set(chosen).count == chosen.count,
                  chosen.allSatisfy({ Self.text($0, limit: 16_384) }) else { throw Self.invalidAnswers() }
            let answer = chosen.joined(separator: ", ")
            guard Self.text(answer, limit: 65_536) else { throw Self.invalidAnswers() }
            answers[question.question] = answer
        }
        return try response(answers: answers, notes: notes)
    }

    /// Retains the existing generic free-text answer API. A multi-select SDK
    /// answer may already be joined, so never split a user's punctuation.
    public func response(answers: [String: String], notes: [String: String] = [:]) throws -> JSONValue {
        let keys = Set(questions.map(\.question))
        guard Set(answers.keys) == keys, Self.exactKeys(Array(answers.keys), within: keys),
              Self.exactKeys(Array(notes.keys), within: keys),
              answers.values.allSatisfy({ Self.text($0, limit: 65_536) }),
              notes.values.allSatisfy({ Self.text($0, limit: 16_384, allowEmpty: true) }) else { throw Self.invalidAnswers() }
        var updated = input.object ?? [:]
        updated["answers"] = .object(answers.mapValues(JSONValue.string))
        if !notes.isEmpty {
            var annotations = updated["annotations"]?.object ?? [:]
            for (key, note) in notes {
                var annotation = annotations[key]?.object ?? [:]
                annotation["notes"] = .string(note); annotations[key] = .object(annotation)
            }
            updated["annotations"] = .object(annotations)
        }
        return .object(["behavior": .string("allow"), "updatedInput": .object(updated)])
    }

    private static func text(_ value: String, limit: Int, allowEmpty: Bool = false) -> Bool {
        value.utf8.count <= limit && !value.contains("\0") && (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private static func optionalText(_ value: JSONValue, key: String, limit: Int) throws -> String? {
        guard let raw = value.object?[key] else { return nil }
        guard let result = raw.string, text(result, limit: limit, allowEmpty: true) else { throw invalid() }
        return result
    }
    private static func exactKeys(_ keys: [String], within expected: Set<String>) -> Bool {
        keys.allSatisfy { key in expected.contains { $0.utf8.elementsEqual(key.utf8) } }
    }
    private static func invalid() -> CoincideError { .init("Claude sent an invalid question request.") }
    private static func invalidAnswers() -> CoincideError { .init("Choose an answer for every Claude question and review your selections.") }
}
