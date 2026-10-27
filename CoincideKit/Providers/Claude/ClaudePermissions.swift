import Foundation

/// Claude Code's `can_use_tool` permission requests as Coincide approvals and questions, and the
/// `PermissionResult` answers sent back, following T3's choices.
enum ClaudePermissions {
    static let allowID = "allow"
    static let allowForSessionID = "allow_session"
    static let denyID = "deny"
    static let stopID = "stop"

    /// What T3 tells Claude after capturing a plan in Plan mode.
    static let planCapturedMessage =
        "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn."

    /// Claude Code's own words before the user's note on a rejected tool call. The SDK passes a denial message
    /// through as the tool result, and a bare note there reads like text the tool produced, which Claude rightly
    /// distrusts.
    static let rejectionNotePrefix =
        "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). To tell you how to proceed, the user said:\n"

    static func options(allowForSession: Bool) -> [ApprovalOption] {
        var options = [ApprovalOption(id: allowID, label: String(localized: "Allow"), kind: .allowOnce)]
        if allowForSession {
            options.append(ApprovalOption(id: allowForSessionID, label: String(localized: "Always allow this session"), kind: .allowAlways))
        }
        options.append(ApprovalOption(id: denyID, label: String(localized: "Deny"), kind: .deny))
        options.append(ApprovalOption(id: stopID, label: String(localized: "Deny and stop"), kind: .cancel))
        return options
    }

    /// An approval for a tool call. `request` is the `can_use_tool` payload.
    static func approval(
        requestID: String, request: JSONValue, workingDirectory: String,
        fileContents: (String) -> String? = ClaudeTools.readSmallFile
    ) -> ApprovalRequest {
        let toolName = request["tool_name"]?.string ?? ""
        let toolUseID = request["tool_use_id"]?.string
        let info = ClaudeTools.info(
            id: toolUseID ?? requestID, name: toolName, input: request["input"] ?? [:], workingDirectory: workingDirectory,
            displayName: request["display_name"]?.string, fileContents: fileContents)
        let reason = ClaudeEventMapper.cleaned(request["decision_reason"]?.string).flatMap { $0 == info.title ? nil : $0 }
        // The path that made Claude Code ask, such as a file a command writes.
        let blocked = request["blocked_path"]?.string.map {
            String(localized: "Needs access to \(ClaudeTools.displayPath($0, relativeTo: workingDirectory))")
        }
        let detail = [reason, blocked, info.detail].compactMap { $0 }.joined(separator: "\n\n")
        // Like Claude Code's "No, and tell Claude what to do differently", a denial can carry a note.
        return ApprovalRequest(
            id: requestID, category: info.category, title: info.title, detail: detail.isEmpty ? nil : detail,
            options: options(allowForSession: request["suppress_always_allow_rule"]?.bool != true), toolCallID: toolUseID,
            textInput: TextInputSpec(placeholder: String(localized: "Tell Claude what to do instead (optional)")))
    }

    /// The answer for the option the user picked. A `feedback` note is what Claude reads when denied.
    static func response(optionID: String, request: JSONValue, feedback: String? = nil) -> JSONValue {
        let note = rejectionNote(feedback)
        return switch optionID {
        case allowID: allow(request, forSession: false)
        case allowForSessionID: allow(request, forSession: true)
        case stopID: deny(request, message: note ?? "User cancelled tool execution.", interrupt: true)
        default: deny(request, message: note ?? "User declined tool execution.", interrupt: false)
        }
    }

    /// The user's note framed the way Claude Code frames it, or nil when there is none.
    static func rejectionNote(_ feedback: String?) -> String? {
        feedback?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { rejectionNotePrefix + $0 }
    }

    static func allow(_ request: JSONValue, forSession: Bool, input: JSONValue? = nil) -> JSONValue {
        var result: [String: JSONValue] = [
            "behavior": "allow", "updatedInput": input ?? request["input"] ?? [:],
            "decisionClassification": forSession ? "user_permanent" : "user_temporary",
        ]
        if let toolUseID = request["tool_use_id"] { result["toolUseID"] = toolUseID }
        if forSession { result["updatedPermissions"] = .array(sessionRules(request)) }
        return .object(result)
    }

    static func deny(_ request: JSONValue, message: String, interrupt: Bool) -> JSONValue {
        var result: [String: JSONValue] = [
            "behavior": "deny", "message": .string(message), "decisionClassification": "user_reject",
        ]
        if let toolUseID = request["tool_use_id"] { result["toolUseID"] = toolUseID }
        if interrupt { result["interrupt"] = true }
        return .object(result)
    }

    /// Claude's own suggestions scoped to this session, or an allow rule for the whole tool.
    /// "Always allow" never switches the session into a mode that skips more prompts than accepting edits.
    private static func sessionRules(_ request: JSONValue) -> [JSONValue] {
        let suggestions = (request["permission_suggestions"]?.array ?? []).compactMap { suggestion -> JSONValue? in
            guard case .object(var rule) = suggestion else { return nil }
            if rule["type"]?.string == "setMode", rule["mode"]?.string != "acceptEdits" { return nil }
            rule["destination"] = "session"
            return .object(rule)
        }
        if !suggestions.isEmpty { return suggestions }
        let toolName = request["tool_name"] ?? ""
        return [["type": "addRules", "rules": [["toolName": toolName]], "behavior": "allow", "destination": "session"]]
    }

    // MARK: Plans

    /// Asks whether to leave plan mode Claude entered on its own and start implementing.
    static func planApproval(requestID: String, request: JSONValue) -> ApprovalRequest {
        ApprovalRequest(
            id: requestID, category: .other, title: String(localized: "Start implementing the plan"),
            detail: ClaudeEventMapper.proposedPlan(request["input"] ?? [:]),
            options: [
                ApprovalOption(id: allowID, label: String(localized: "Implement"), kind: .allowOnce),
                ApprovalOption(id: denyID, label: String(localized: "Keep planning"), kind: .deny),
            ],
            toolCallID: request["tool_use_id"]?.string,
            textInput: TextInputSpec(placeholder: String(localized: "What should change? (optional)"), isMultiline: true))
    }

    static func planResponse(optionID: String, request: JSONValue, feedback: String?) -> JSONValue {
        guard optionID != allowID else { return allow(request, forSession: false) }
        return deny(request, message: rejectionNote(feedback) ?? "The user wants to keep planning.", interrupt: false)
    }

    // MARK: Questions

    /// An AskUserQuestion call as questions for the user. Like T3, each question's id is its text,
    /// which is also how Claude keys the answers.
    static func userInput(requestID: String, input: JSONValue) -> UserInputRequest? {
        var seen = Set<String>()
        let questions = (input["questions"]?.array ?? []).compactMap { value -> UserQuestion? in
            guard let prompt = value["question"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                seen.insert(prompt).inserted
            else { return nil }
            let options = (value["options"]?.array ?? []).compactMap { option -> UserQuestion.Option? in
                guard let label = option["label"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                    return nil
                }
                let detail = option["description"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                return UserQuestion.Option(label: label, detail: detail)
            }
            return UserQuestion(
                id: prompt, header: value["header"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                prompt: prompt, options: options, allowsMultipleSelection: value["multiSelect"]?.bool == true)
        }
        guard !questions.isEmpty else { return nil }
        let title =
            questions.count == 1
            ? String(localized: "Claude Code has a question") : String(localized: "Claude Code has \(questions.count) questions")
        return UserInputRequest(id: requestID, title: title, questions: questions)
    }

    /// The AskUserQuestion answer, as the Agent SDK sends it: the original questions plus each answered
    /// question's text mapped to its answer, several picks joined with ", ". Nothing answered denies.
    static func answersResponse(_ request: JSONValue, answers: [String: [String]]) -> JSONValue {
        var answered: [String: JSONValue] = [:]
        for (question, values) in answers {
            let picks = values.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            if !picks.isEmpty { answered[question] = .string(picks.joined(separator: ", ")) }
        }
        guard !answered.isEmpty else {
            return deny(request, message: "The user dismissed the questions without answering.", interrupt: false)
        }
        let input: JSONValue = ["questions": request.at("input.questions") ?? [], "answers": .object(answered)]
        return allow(request, forSession: false, input: input)
    }

    // MARK: MCP elicitations

    /// The question id of a confirmation (a form without fields, or a link to open).
    static let elicitationConfirmID = "confirm"

    /// One field of an MCP elicitation form and how its answer is encoded.
    private enum ElicitationField {
        case text
        case number(integer: Bool)
        case boolean
        /// Option labels and the values they stand for.
        case choice(labels: [String], values: [JSONValue], multiple: Bool)
    }

    private static var yesLabel: String { String(localized: "Yes") }
    private static var noLabel: String { String(localized: "No") }
    private static var continueLabel: String { String(localized: "Continue") }
    private static var declineLabel: String { String(localized: "Decline") }

    /// An MCP server's request for input as questions: a form whose fields become questions (MCP allows only
    /// flat text, number, boolean and choice fields), or a link the user opens. Nil when a field cannot be asked.
    static func elicitation(requestID: String, request: JSONValue) -> UserInputRequest? {
        let server =
            [request["display_name"]?.string, request["mcp_server_name"]?.string].compactMap { $0?.trimmingCharacters(in: .whitespaces).nilIfEmpty }
            .first ?? String(localized: "An MCP server")
        let message = ClaudeEventMapper.cleaned(request["message"]?.string)
        let title = ClaudeEventMapper.cleaned(request["title"]?.string) ?? String(localized: "\(server) needs your input")
        if request["mode"]?.string == "url" {
            guard let url = request["url"]?.string?.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return nil }
            let prompt = [message, String(localized: "Open this link and finish there, then continue:\n\(url)")]
                .compactMap { $0 }.joined(separator: "\n\n")
            return UserInputRequest(
                id: requestID, title: title,
                questions: [
                    UserQuestion(
                        id: elicitationConfirmID, header: server, prompt: prompt,
                        options: [.init(label: continueLabel), .init(label: declineLabel)], allowsFreeText: false)
                ])
        }
        guard let fields = elicitationFields(request["requested_schema"]) else { return nil }
        if fields.isEmpty {
            return UserInputRequest(
                id: requestID, title: title,
                questions: [
                    UserQuestion(
                        id: elicitationConfirmID, header: server, prompt: message ?? title,
                        options: [.init(label: continueLabel), .init(label: declineLabel)], allowsFreeText: false)
                ])
        }
        let questions = fields.map { field -> UserQuestion in
            let label = field.title ?? field.name
            // A one-field form asks the server's message; larger forms ask each field's own description.
            let prompt = (fields.count == 1 ? message : nil) ?? field.description ?? label
            switch field.kind {
            case .text, .number:
                return UserQuestion(id: field.name, header: label, prompt: prompt)
            case .boolean:
                return UserQuestion(
                    id: field.name, header: label, prompt: prompt, options: [.init(label: yesLabel), .init(label: noLabel)],
                    allowsFreeText: false)
            case .choice(let labels, _, let multiple):
                return UserQuestion(
                    id: field.name, header: label, prompt: prompt, options: labels.map { .init(label: $0) },
                    allowsMultipleSelection: multiple, allowsFreeText: false)
            }
        }
        return UserInputRequest(id: requestID, title: fields.count == 1 ? title : message ?? title, questions: questions)
    }

    /// The elicitation result for the user's answers: `accept` with the form's content, or `decline` / `cancel`.
    static func elicitationResponse(_ request: JSONValue, answers: [String: [String]]) -> JSONValue {
        let picks = answers.mapValues { values in values.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty } }
        guard picks.values.contains(where: { !$0.isEmpty }) else { return ["action": "cancel"] }
        if request["mode"]?.string == "url" {
            return picks[elicitationConfirmID]?.first == continueLabel ? ["action": "accept"] : ["action": "decline"]
        }
        guard let fields = elicitationFields(request["requested_schema"]) else { return ["action": "decline"] }
        if fields.isEmpty {
            return picks[elicitationConfirmID]?.first == continueLabel ? ["action": "accept", "content": [:]] : ["action": "decline"]
        }
        var content: [String: JSONValue] = [:]
        for field in fields {
            guard let values = picks[field.name], let first = values.first else { continue }
            switch field.kind {
            case .text:
                content[field.name] = .string(values.joined(separator: ", "))
            case .number(let integer):
                guard let number = Double(first.replacingOccurrences(of: ",", with: "")), number.isFinite,
                    !integer || number.rounded() == number
                else { continue }
                content[field.name] = .number(number)
            case .boolean:
                content[field.name] = .bool(first == yesLabel)
            case .choice(let labels, let options, let multiple):
                let chosen = values.compactMap { label in labels.firstIndex(of: label).map { options[$0] } }
                if multiple {
                    content[field.name] = .array(chosen)
                } else if let value = chosen.first {
                    content[field.name] = value
                }
            }
        }
        return ["action": "accept", "content": .object(content)]
    }

    private struct ElicitationFormField {
        var name: String
        var title: String?
        var description: String?
        var kind: ElicitationField
    }

    /// The form's fields, required ones first in the server's order, then the rest by name.
    /// Nil without an object schema, since then nothing says what to send.
    private static func elicitationFields(_ schema: JSONValue?) -> [ElicitationFormField]? {
        guard let schema, schema["type"]?.string == "object" else { return nil }
        let properties = schema["properties"]?.object ?? [:]
        let required = (schema["required"]?.array ?? []).compactMap(\.string).filter { properties[$0] != nil }
        let names = required + properties.keys.filter { !required.contains($0) }.sorted()
        var fields: [ElicitationFormField] = []
        for name in names {
            guard let property = properties[name], let kind = elicitationKind(property) else { return nil }
            fields.append(
                ElicitationFormField(
                    name: name, title: ClaudeEventMapper.cleaned(property["title"]?.string),
                    description: ClaudeEventMapper.cleaned(property["description"]?.string), kind: kind))
        }
        return fields
    }

    private static func elicitationKind(_ property: JSONValue) -> ElicitationField? {
        if let choice = elicitationChoices(property) { return .choice(labels: choice.labels, values: choice.values, multiple: false) }
        switch property["type"]?.string {
        case "string"?: return .text
        case "number"?: return .number(integer: false)
        case "integer"?: return .number(integer: true)
        case "boolean"?: return .boolean
        case "array"?:
            guard let items = property["items"], let choice = elicitationChoices(items) else { return nil }
            return .choice(labels: choice.labels, values: choice.values, multiple: true)
        default: return nil
        }
    }

    /// `enum` (with `enumNames`) or `oneOf`/`anyOf` of `const` + `title` choices.
    private static func elicitationChoices(_ schema: JSONValue) -> (labels: [String], values: [JSONValue])? {
        if let values = schema["enum"]?.array, !values.isEmpty {
            let names = schema["enumNames"]?.array?.compactMap(\.string) ?? []
            let labels = values.enumerated().map { index, value in index < names.count ? names[index] : value.displayText }
            return Set(labels).count == labels.count ? (labels, values) : nil
        }
        guard let options = (schema["oneOf"] ?? schema["anyOf"])?.array, !options.isEmpty else { return nil }
        var labels: [String] = []
        var values: [JSONValue] = []
        for option in options {
            guard let value = option["const"] else { return nil }
            labels.append(option["title"]?.string ?? value.displayText)
            values.append(value)
        }
        return Set(labels).count == labels.count ? (labels, values) : nil
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
