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
        let blocked = request["blocked_path"]?.string.map {
            String(localized: "Outside the allowed folders: \(ClaudeTools.displayPath($0, relativeTo: workingDirectory))")
        }
        let detail = [reason, blocked, info.detail].compactMap { $0 }.joined(separator: "\n\n")
        // Like Claude Code's "No, and tell Claude what to do differently", a denial can carry a note.
        return ApprovalRequest(
            id: requestID, category: info.category, title: info.title, detail: detail.isEmpty ? nil : detail,
            options: options(allowForSession: request["suppress_always_allow_rule"]?.bool != true), toolCallID: toolUseID,
            textInput: TextInputSpec(placeholder: String(localized: "Tell Claude what to do instead (optional)")))
    }

    /// The answer for the option the user picked. `feedback` replaces the message Claude reads when denied.
    static func response(optionID: String, request: JSONValue, feedback: String? = nil) -> JSONValue {
        let note = feedback?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return switch optionID {
        case allowID: allow(request, forSession: false)
        case allowForSessionID: allow(request, forSession: true)
        case stopID: deny(request, message: note ?? "User cancelled tool execution.", interrupt: true)
        default: deny(request, message: note ?? "User declined tool execution.", interrupt: false)
        }
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
    private static func sessionRules(_ request: JSONValue) -> [JSONValue] {
        let suggestions = (request["permission_suggestions"]?.array ?? []).compactMap { suggestion -> JSONValue? in
            guard case .object(var rule) = suggestion else { return nil }
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
        let note = feedback?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return deny(request, message: note ?? "The user wants to keep planning.", interrupt: false)
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
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
