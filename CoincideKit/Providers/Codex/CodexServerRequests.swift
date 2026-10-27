import Foundation

/// A request from the app server shown to the user, with the JSON-RPC result each choice sends back.
struct CodexApproval {
    var request: ApprovalRequest
    var responses: [String: JSONValue]
    /// Sent when the turn is stopped before the user answers.
    var cancelResponse: JSONValue
    /// For `item/tool/requestUserInput`, the question this approval answers; `responses` are its answers.
    var questionID: String?
}

/// What to do with a request the app server sent.
enum CodexServerRequestAction {
    case approval(CodexApproval)
    /// Multiple-choice questions, one approval each. `answered` holds questions that cannot be shown
    /// (free text, secrets) with empty answers, and `notices` repeats them for the user. With no
    /// approvals, the answer is sent right away.
    case questions([CodexApproval], answered: [String: JSONValue], notices: [String])
    case respond(JSONValue)
    case reject(String)
}

/// Maps server-to-client requests (approvals, questions, MCP elicitations) to prompts and answers,
/// following T3 Code's handling.
enum CodexServerRequests {
    static func action(
        method: String, params: JSONValue, approvalID: String, presentation: CodexPresentation,
        fileChanges: [JSONValue]?
    ) -> CodexServerRequestAction {
        switch method {
        case "item/commandExecution/requestApproval":
            return .approval(commandApproval(params, id: approvalID))
        case "item/fileChange/requestApproval":
            return .approval(fileChangeApproval(params, id: approvalID, presentation: presentation, changes: fileChanges))
        case "item/permissions/requestApproval":
            return .approval(permissionsApproval(params, id: approvalID, presentation: presentation))
        case "execCommandApproval":
            return .approval(legacyCommandApproval(params, id: approvalID))
        case "applyPatchApproval":
            return .approval(legacyPatchApproval(params, id: approvalID, presentation: presentation))
        case "item/tool/requestUserInput":
            return questions(params, id: approvalID)
        case "mcpServer/elicitation/request":
            return elicitation(params, id: approvalID)
        case "item/tool/call":
            // Coincide registers no dynamic tools.
            return .respond([
                "contentItems": [["type": "inputText", "text": "Coincide does not provide this tool."]], "success": false,
            ])
        case "currentTime/read":
            return .respond(["currentTimeAt": .number(Date().timeIntervalSince1970.rounded(.down))])
        default:
            return .reject("Coincide does not handle \(method).")
        }
    }

    // MARK: Commands and file changes

    static func commandApproval(_ params: JSONValue, id: String) -> CodexApproval {
        let command = CodexPresentation.displayCommand(
            params["command"]?.string ?? "", actions: params["commandActions"]?.array ?? [])
        let title: String
        if let host = params.at("networkApprovalContext.host")?.string {
            title = String(localized: "Allow network access to \(host)")
        } else if params["kind"]?.string == "writeStdin" {
            title = String(localized: "Send input to `\(CodexPresentation.shortened(command))`")
        } else {
            title = CodexPresentation.runTitle(command)
        }
        let decisions = params["availableDecisions"]?.array ?? ["accept", "acceptForSession", "decline", "cancel"]
        var options: [ApprovalOption] = []
        var responses: [String: JSONValue] = [:]
        for (index, decision) in decisions.enumerated() {
            guard let option = commandOption(decision, index: index), responses[option.id] == nil else { continue }
            options.append(option)
            responses[option.id] = ["decision": decision]
        }
        let cancel: JSONValue = decisions.contains("cancel") || !decisions.contains("decline") ? "cancel" : "decline"
        return CodexApproval(
            request: ApprovalRequest(
                id: id, category: .command, title: title,
                detail: joined([command, params["reason"]?.string]), options: options,
                toolCallID: params["itemId"]?.string),
            responses: responses, cancelResponse: ["decision": cancel])
    }

    /// One choice of `availableDecisions`; amendments remember the answer in Codex's own rules.
    static func commandOption(_ decision: JSONValue, index: Int) -> ApprovalOption? {
        switch decision.string {
        case "accept":
            return ApprovalOption(id: "accept", label: String(localized: "Allow"), kind: .allowOnce)
        case "acceptForSession":
            return ApprovalOption(
                id: "acceptForSession", label: String(localized: "Allow for this session"), kind: .allowAlways)
        case "decline":
            return ApprovalOption(id: "decline", label: String(localized: "Deny"), kind: .deny)
        case "cancel":
            return ApprovalOption(id: "cancel", label: String(localized: "Deny and stop"), kind: .cancel)
        default:
            break
        }
        if let prefix = decision.at("acceptWithExecpolicyAmendment.execpolicy_amendment")?.array?.compactMap(\.string) {
            let command = CodexPresentation.shortened(prefix.joined(separator: " "))
            return ApprovalOption(
                id: "acceptWithExecpolicyAmendment", label: String(localized: "Always allow `\(command)`"),
                kind: .allowAlways)
        }
        if let amendment = decision.at("applyNetworkPolicyAmendment.network_policy_amendment"),
            let host = amendment["host"]?.string
        {
            let id = "network-\(index)"
            return amendment["action"]?.string == "deny"
                ? ApprovalOption(id: id, label: String(localized: "Always block \(host)"), kind: .deny)
                : ApprovalOption(id: id, label: String(localized: "Always allow \(host)"), kind: .allowAlways)
        }
        return nil
    }

    static func fileChangeApproval(
        _ params: JSONValue, id: String, presentation: CodexPresentation, changes: [JSONValue]?
    ) -> CodexApproval {
        let grantRoot = params["grantRoot"]?.string
        let title =
            if let changes, !changes.isEmpty {
                presentation.fileChangeTitle(changes)
            } else if let grantRoot {
                String(localized: "Allow writing to \(presentation.relativePath(grantRoot))")
            } else {
                String(localized: "Edit files")
            }
        let decisions: [(String, String, ApprovalOption.Kind)] = [
            ("accept", String(localized: "Allow"), .allowOnce),
            ("acceptForSession", String(localized: "Allow for this session"), .allowAlways),
            ("decline", String(localized: "Deny"), .deny),
            ("cancel", String(localized: "Deny and stop"), .cancel),
        ]
        return CodexApproval(
            request: ApprovalRequest(
                id: id, category: .fileChange, title: title,
                detail: joined([params["reason"]?.string, changes.flatMap { presentation.unifiedDiff($0) }]),
                options: decisions.map { ApprovalOption(id: $0.0, label: $0.1, kind: $0.2) },
                toolCallID: params["itemId"]?.string),
            responses: Dictionary(uniqueKeysWithValues: decisions.map { ($0.0, ["decision": .string($0.0)]) }),
            cancelResponse: ["decision": "cancel"])
    }

    static func permissionsApproval(_ params: JSONValue, id: String, presentation: CodexPresentation) -> CodexApproval {
        let requested = params["permissions"] ?? [:]
        let write = requested.at("fileSystem.write")?.array?.compactMap(\.string) ?? []
        let read = requested.at("fileSystem.read")?.array?.compactMap(\.string) ?? []
        let paths = { (list: [String]) in list.map(presentation.relativePath).joined(separator: ", ") }
        let (title, category): (String, ToolCategory) =
            if !write.isEmpty {
                (String(localized: "Allow writing to \(paths(write))"), .fileChange)
            } else if !read.isEmpty {
                (String(localized: "Allow reading \(paths(read))"), .read)
            } else if requested.at("network.enabled")?.bool == true {
                (String(localized: "Allow network access"), .web)
            } else {
                (String(localized: "Grant additional permissions"), .command)
            }
        var granted: [String: JSONValue] = [:]
        for key in ["fileSystem", "network"] {
            if let value = requested[key], !value.isNull { granted[key] = value }
        }
        let deny: JSONValue = ["permissions": [:], "scope": "turn"]
        return CodexApproval(
            request: ApprovalRequest(
                id: id, category: category, title: title, detail: params["reason"]?.string,
                options: [
                    ApprovalOption(id: "turn", label: String(localized: "Allow"), kind: .allowOnce),
                    ApprovalOption(id: "session", label: String(localized: "Allow for this session"), kind: .allowAlways),
                    ApprovalOption(id: "deny", label: String(localized: "Deny"), kind: .deny),
                ], toolCallID: params["itemId"]?.string),
            responses: [
                "turn": ["permissions": .object(granted), "scope": "turn"],
                "session": ["permissions": .object(granted), "scope": "session"],
                "deny": deny,
            ],
            cancelResponse: deny)
    }

    // MARK: Legacy approvals

    /// `ReviewDecision` choices of the v1 approval requests.
    private static let reviewDecisions: [(String, String, ApprovalOption.Kind, JSONValue)] = [
        ("approved", String(localized: "Allow"), .allowOnce, "approved"),
        ("approved_for_session", String(localized: "Allow for this session"), .allowAlways, "approved_for_session"),
        ("denied", String(localized: "Deny"), .deny, ["denied": ["rejection": "The user declined the request."]]),
        ("abort", String(localized: "Deny and stop"), .cancel, "abort"),
    ]

    private static func legacyApproval(
        id: String, category: ToolCategory, title: String, detail: String?, toolCallID: String?
    ) -> CodexApproval {
        CodexApproval(
            request: ApprovalRequest(
                id: id, category: category, title: title, detail: detail,
                options: reviewDecisions.map { ApprovalOption(id: $0.0, label: $0.1, kind: $0.2) }, toolCallID: toolCallID),
            responses: Dictionary(uniqueKeysWithValues: reviewDecisions.map { ($0.0, ["decision": $0.3]) }),
            cancelResponse: ["decision": "abort"])
    }

    static func legacyCommandApproval(_ params: JSONValue, id: String) -> CodexApproval {
        let argv = params["command"]?.array?.compactMap(\.string) ?? []
        let command =
            argv.count == 3 && ["-lc", "-c"].contains(argv[1])
            ? argv[2] : argv.joined(separator: " ")
        return legacyApproval(
            id: id, category: .command, title: CodexPresentation.runTitle(command),
            detail: joined([command, params["reason"]?.string]), toolCallID: params["callId"]?.string)
    }

    static func legacyPatchApproval(_ params: JSONValue, id: String, presentation: CodexPresentation) -> CodexApproval {
        let changes = params["fileChanges"]?.object ?? [:]
        let title =
            changes.count == 1
            ? String(localized: "Edit \(presentation.relativePath(changes.keys.first ?? ""))")
            : String(localized: "Edit \(changes.count) files")
        return legacyApproval(
            id: id, category: .fileChange, title: title,
            detail: joined([params["reason"]?.string, presentation.unifiedDiff(legacyChanges: changes)]),
            toolCallID: params["callId"]?.string)
    }

    // MARK: Questions

    /// `request_user_input`: each multiple-choice question becomes an approval whose options are the answers.
    static func questions(_ params: JSONValue, id: String) -> CodexServerRequestAction {
        var approvals: [CodexApproval] = []
        var answered: [String: JSONValue] = [:]
        var notices: [String] = []
        let skipped: JSONValue = ["answers": []]
        for (index, question) in (params["questions"]?.array ?? []).enumerated() {
            guard let questionID = question["id"]?.string else { continue }
            let text = question["question"]?.string ?? ""
            let choices = (question["options"]?.array ?? []).compactMap { option -> (String, String?)? in
                option["label"]?.string.map { ($0, option["description"]?.string) }
            }
            guard !choices.isEmpty, question["isSecret"]?.bool != true else {
                answered[questionID] = skipped
                if !text.isEmpty { notices.append(String(localized: "Codex asked: \(text)")) }
                continue
            }
            var options: [ApprovalOption] = []
            var responses: [String: JSONValue] = [:]
            for (choiceIndex, choice) in choices.enumerated() {
                let optionID = "option-\(choiceIndex)"
                options.append(ApprovalOption(id: optionID, label: choice.0, kind: .allowOnce))
                responses[optionID] = ["answers": [.string(choice.0)]]
            }
            options.append(ApprovalOption(id: "skip", label: String(localized: "Skip"), kind: .cancel))
            responses["skip"] = skipped
            let header = question["header"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            let descriptions = choices.compactMap { choice in choice.1.flatMap { $0.isEmpty ? nil : "\(choice.0): \($0)" } }
            approvals.append(
                CodexApproval(
                    request: ApprovalRequest(
                        id: "\(id)/\(index)", category: .other,
                        title: header ?? String(localized: "Codex has a question"),
                        detail: joined([text, descriptions.isEmpty ? nil : descriptions.joined(separator: "\n")]),
                        options: options, toolCallID: params["itemId"]?.string),
                    responses: responses, cancelResponse: skipped, questionID: questionID))
        }
        return .questions(approvals, answered: answered, notices: notices)
    }

    // MARK: MCP elicitations

    /// Approve-style MCP forms (connector permission prompts) become approvals; anything Coincide cannot
    /// fill in is declined, as in T3 Code.
    static func elicitation(_ params: JSONValue, id: String) -> CodexServerRequestAction {
        let decline: JSONValue = ["action": "decline", "content": .null, "_meta": .null]
        guard let accept = elicitationResponse(params, persist: nil) else { return .respond(decline) }
        var options = [ApprovalOption(id: "accept", label: String(localized: "Allow"), kind: .allowOnce)]
        var responses: [String: JSONValue] = ["accept": accept]
        let persistLabels = [
            "session": String(localized: "Allow for this session"), "always": String(localized: "Always allow"),
        ]
        let offered = elicitationPersistence(params)
        for persist in ["session", "always"] where offered.contains(persist) {
            guard let response = elicitationResponse(params, persist: persist), let label = persistLabels[persist]
            else { continue }
            options.append(ApprovalOption(id: persist, label: label, kind: .allowAlways))
            responses[persist] = response
        }
        options.append(ApprovalOption(id: "decline", label: String(localized: "Deny"), kind: .deny))
        options.append(ApprovalOption(id: "cancel", label: String(localized: "Deny and stop"), kind: .cancel))
        responses["decline"] = decline
        responses["cancel"] = ["action": "cancel", "content": .null, "_meta": .null]
        let message = params["message"]?.string ?? ""
        let server = params["serverName"]?.string ?? "MCP"
        let title =
            message.isEmpty ? String(localized: "\(server) asks for permission") : CodexPresentation.shortened(message)
        return .approval(
            CodexApproval(
                request: ApprovalRequest(
                    id: id, category: .mcp, title: title, detail: joined([message, server]), options: options),
                responses: responses, cancelResponse: responses["cancel"] ?? decline))
    }

    /// The accept answer for a form, choosing approve-like values (or the `persist` scope) and defaults;
    /// nil when a required field cannot be filled in or the mode is not a form.
    static func elicitationResponse(_ params: JSONValue, persist: String?) -> JSONValue? {
        guard ["form", "openai/form", "openaiForm"].contains(params["mode"]?.string ?? "") else { return nil }
        let schema = params["requestedSchema"]
        let properties = schema?["properties"]?.object ?? [:]
        var content: [String: JSONValue] = [:]
        for (key, field) in properties {
            let values = fieldValues(field)
            let chosen = values.first { value in
                if let persist { return persistence(value) == persist }
                return persistence(value) == nil
                    && value.range(of: "once|accept|approve|allow", options: [.regularExpression, .caseInsensitive]) != nil
            }
            if let chosen {
                content[key] = .string(chosen)
            } else if field["type"]?.string == "boolean", isPersistenceField(key, field) {
                content[key] = .bool(persist == "always")
            } else if let value = field["default"], !value.isNull {
                content[key] = value
            }
        }
        let required = schema?["required"]?.array?.compactMap(\.string) ?? []
        guard required.allSatisfy({ content[$0] != nil }) else { return nil }
        return [
            "action": "accept", "content": .object(content),
            "_meta": persist.map { ["persist": .string($0)] } ?? .null,
        ]
    }

    /// The persistence scopes ("session", "always") the form or its metadata offers.
    static func elicitationPersistence(_ params: JSONValue) -> Set<String> {
        var scopes = Set<String>()
        let meta = params["_meta"]
        let persist = meta?["persist"]
        let persistValues = persist?.array?.compactMap(\.string) ?? persist?.string.map { [$0] } ?? []
        for value in persistValues {
            if let scope = persistence(value) { scopes.insert(scope) }
        }
        if meta?["allowPersistentApproval"]?.bool == true { scopes.insert("always") }
        for (key, field) in params.at("requestedSchema.properties")?.object ?? [:] {
            for value in fieldValues(field) {
                if let scope = persistence(value) { scopes.insert(scope) }
            }
            if field["type"]?.string == "boolean", isPersistenceField(key, field) { scopes.insert("always") }
        }
        return scopes
    }

    private static func fieldValues(_ field: JSONValue) -> [String] {
        if let oneOf = field["oneOf"]?.array { return oneOf.compactMap { $0["const"]?.string } }
        return field["enum"]?.array?.compactMap(\.string) ?? []
    }

    private static func persistence(_ value: String?) -> String? {
        guard let value = value?.lowercased() else { return nil }
        if value.contains("session") { return "session" }
        if ["always", "permanent", "forever", "persistent"].contains(where: { value.contains($0) }) { return "always" }
        return nil
    }

    private static func isPersistenceField(_ key: String, _ field: JSONValue) -> Bool {
        persistence(key) != nil || key.lowercased() == "persist" || persistence(field["title"]?.string) != nil
            || persistence(field["description"]?.string) != nil
    }

    private static func joined(_ parts: [String?]) -> String? {
        let text = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }
}
