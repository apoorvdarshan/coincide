import Foundation

/// A dialog a Pi extension raised with `extension_ui_request`.
///
/// `confirm` becomes an approval, `input` and `editor` become approvals with a text field, and `select` becomes a
/// question. Coincide's own extension raises a `confirm` for every tool call that needs approval.
struct PiDialog {
    enum Method: String {
        case confirm, select, input, editor
    }

    enum Presentation: Equatable {
        case approval(ApprovalRequest)
        case question(UserInputRequest)
    }

    static let allowID = "allow"
    static let allowAlwaysID = "allow_always"
    static let denyID = "deny"
    static let submitID = "submit"
    static let cancelID = "cancel"
    /// Pi accepts an empty string as a `select` choice; it needs a visible label.
    static let emptyChoiceLabel = String(localized: "(empty)")
    /// Pi answers a dialog itself when its timeout passes; nothing legitimate waits longer than a day.
    static let longestTimeoutMilliseconds: Double = 86_400_000

    let id: String
    let method: Method
    let presentation: Presentation
    /// For confirmations "Always allow" can remember: the tool call's subject, or the dialog's text.
    let rememberKey: String?
    /// How long until Pi answers the dialog itself with its default.
    let timeout: Duration?
    /// The tool call a Coincide approval guards.
    let toolCallID: String?
    /// The editor's prefilled text, sent back unchanged when no text arrives with the answer.
    private let prefill: String?
    /// `select` choices: the label shown and the value Pi gets back.
    private let choices: [(label: String, value: String)]

    /// Nil for fire-and-forget requests (`notify`, `setStatus`, `setWidget`, …) and malformed ones.
    init?(_ record: JSONValue, tool: (String) -> PiTurnMapper.Tool?) {
        guard let id = record["id"]?.string, let method = record["method"]?.string.flatMap(Method.init) else { return nil }
        self.id = id
        self.method = method
        let rawTitle = record["title"]?.string ?? ""
        let message = PiText.nonEmpty(record["message"]?.string)
        var rememberKey: String?
        var toolCallID: String?
        var prefill: String?
        var choices: [(label: String, value: String)] = []
        switch method {
        case .confirm:
            if let marker = record["message"]?.string.flatMap(JSONValue.parse), marker["coincide"]?.string == PiExtension.approvalMarker,
                let callID = marker["toolCallId"]?.string
            {
                let known = tool(callID)
                let name = known?.name ?? marker["toolName"]?.string ?? "tool"
                let info = known?.info ?? PiTools.info(id: callID, name: name, args: known?.args)
                presentation = .approval(
                    ApprovalRequest(
                        id: id, category: info.category, title: info.title, detail: info.detail,
                        options: ApprovalRequest.standardOptions, toolCallID: callID))
                rememberKey = "tool\u{0}" + PiTools.approvalKey(name: name, args: known?.args)
                toolCallID = callID
            } else {
                let (title, rest) = Self.headline(rawTitle, fallback: String(localized: "Pi asks for confirmation"))
                presentation = .approval(
                    ApprovalRequest(
                        id: id, category: .other, title: title, detail: Self.joined(rest, message),
                        options: ApprovalRequest.standardOptions))
                rememberKey = "confirm\u{0}\(rawTitle)\u{0}\(record["message"]?.string ?? "")"
            }
        case .input:
            let (title, rest) = Self.headline(rawTitle, fallback: String(localized: "Pi asks for input"))
            presentation = .approval(
                ApprovalRequest(
                    id: id, category: .other, title: title, detail: Self.joined(rest, message),
                    options: [
                        ApprovalOption(id: Self.submitID, label: String(localized: "Submit"), kind: .allowOnce),
                        ApprovalOption(id: Self.cancelID, label: String(localized: "Cancel"), kind: .cancel),
                    ],
                    textInput: TextInputSpec(placeholder: PiText.nonEmpty(record["placeholder"]?.string))))
        case .editor:
            let (title, rest) = Self.headline(rawTitle, fallback: String(localized: "Pi asks you to edit text"))
            prefill = record["prefill"]?.string
            presentation = .approval(
                ApprovalRequest(
                    id: id, category: .other, title: title, detail: Self.joined(rest, message),
                    options: [
                        ApprovalOption(id: Self.submitID, label: String(localized: "Save"), kind: .allowOnce),
                        ApprovalOption(id: Self.cancelID, label: String(localized: "Cancel"), kind: .cancel),
                    ],
                    textInput: TextInputSpec(initialText: prefill, isMultiline: true)))
        case .select:
            var labels = Set<String>()
            for value in (record["options"]?.array ?? []).compactMap(\.string) {
                let label = value.isEmpty ? Self.emptyChoiceLabel : value
                guard labels.insert(label).inserted else { continue }
                choices.append((label, value))
            }
            let prompt = PiText.nonEmpty(rawTitle) ?? message ?? String(localized: "Pi asks you to choose")
            let question = UserQuestion(
                id: id, prompt: prompt, options: choices.map { UserQuestion.Option(label: $0.label) },
                allowsMultipleSelection: false, allowsFreeText: false)
            presentation = .question(UserInputRequest(id: id, questions: [question]))
        }
        self.rememberKey = rememberKey
        self.toolCallID = toolCallID
        self.prefill = prefill
        self.choices = choices
        // Pi treats a zero timeout as none and a negative one as already expired.
        timeout = record["timeout"]?.number.flatMap { milliseconds -> Duration? in
            guard milliseconds.isFinite, milliseconds != 0 else { return nil }
            return .milliseconds(min(max(0, milliseconds), Self.longestTimeoutMilliseconds))
        }
    }

    var approval: ApprovalRequest? {
        if case .approval(let request) = presentation { return request }
        return nil
    }

    var question: UserInputRequest? {
        if case .question(let request) = presentation { return request }
        return nil
    }

    /// The `extension_ui_response` for an approval option and the text typed with it. Anything unknown dismisses the dialog.
    func response(optionID: String, text: String?) -> JSONValue {
        switch (method, optionID) {
        case (.confirm, Self.allowID), (.confirm, Self.allowAlwaysID):
            return reply(["confirmed": true])
        case (.confirm, Self.denyID):
            return reply(["confirmed": false])
        case (.input, Self.submitID):
            return reply(["value": .string(text ?? "")])
        case (.editor, Self.submitID):
            return reply(["value": .string(text ?? prefill ?? "")])
        default:
            return cancellation
        }
    }

    /// The `extension_ui_response` for the answer to a `select`; no answer, or one that is not a choice, dismisses it.
    func response(answers: [String: [String]]) -> JSONValue {
        guard let answer = answers[id]?.first ?? answers.values.first?.first else { return cancellation }
        guard let choice = choices.first(where: { $0.value == answer }) ?? choices.first(where: { $0.label == answer }) else {
            return cancellation
        }
        return reply(["value": .string(choice.value)])
    }

    /// Dismisses the dialog: Pi hands the extension `undefined` (or `false` for a confirmation).
    var cancellation: JSONValue { reply(["cancelled": true]) }

    /// Whether the option refuses the dialog, which blocks the tool call it guards.
    func declines(_ optionID: String) -> Bool {
        switch method {
        case .confirm: optionID != Self.allowID && optionID != Self.allowAlwaysID
        case .input, .editor: optionID != Self.submitID
        case .select: false
        }
    }

    private func reply(_ fields: [String: JSONValue]) -> JSONValue {
        var fields = fields
        fields["type"] = "extension_ui_response"
        fields["id"] = .string(id)
        return .object(fields)
    }

    /// A dialog title's first line for the approval's title, and the rest for its detail.
    private static func headline(_ title: String, fallback: String) -> (title: String, rest: String?) {
        guard let trimmed = PiText.nonEmpty(title) else { return (fallback, nil) }
        let summary = PiText.summary(trimmed, limit: 120)
        return (summary, summary == trimmed ? nil : trimmed)
    }

    private static func joined(_ parts: String?...) -> String? {
        let text = parts.compactMap { $0 }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }
}
