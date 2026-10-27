import Foundation

/// A request from the app server shown as an approval, with the JSON-RPC result each choice sends back.
struct CodexApproval {
    var request: ApprovalRequest
    var responses: [String: JSONValue]
    /// Sent when the turn stops or ends before the user answers.
    var cancelResponse: JSONValue
}

/// Questions from the app server (`request_user_input`, MCP forms), and how the answers are sent back.
struct CodexUserInput {
    enum Format: Equatable {
        /// `item/tool/requestUserInput`: `{answers: {questionID: {answers: [String]}}}`.
        case toolAnswers
        /// An MCP elicitation form; the answers become its typed `content`.
        case form([CodexFormField])
    }

    var request: UserInputRequest
    var format: Format

    /// The JSON-RPC result for the user's answers (question id → values). Empty answers mean dismissed.
    func response(to answers: [String: [String]]) -> JSONValue {
        switch format {
        case .toolAnswers:
            var result: [String: JSONValue] = [:]
            for question in request.questions {
                let values = CodexUserInput.cleaned(answers[question.id])
                if !values.isEmpty { result[question.id] = ["answers": .array(values.map { .string($0) })] }
            }
            return ["answers": .object(result)]
        case .form(let fields):
            guard !answers.isEmpty, let content = CodexFormField.content(fields, answers: answers) else {
                return CodexServerRequests.elicitationResult("cancel")
            }
            return ["action": "accept", "content": .object(content), "_meta": .null]
        }
    }

    /// Sent when the user dismisses the questions or the turn stops first.
    var dismissResponse: JSONValue { response(to: [:]) }

    static func cleaned(_ values: [String]?) -> [String] {
        (values ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// One field of an MCP elicitation form, asked as a question.
struct CodexFormField: Equatable {
    enum Kind: Equatable {
        case text
        case number(integer: Bool)
        case boolean
        /// `values` are what the form expects back, `labels` what the user sees, in the same order.
        case choice(values: [String], labels: [String], multiple: Bool)
    }

    var key: String
    var kind: Kind
    var isRequired: Bool
    var defaultValue: JSONValue?

    /// Labels for boolean fields.
    static var yes: String { String(localized: "Yes") }
    static var no: String { String(localized: "No") }

    /// Every field of a form schema: required fields first, then by name, since object order is not kept.
    static func fields(of schema: JSONValue?) -> [CodexFormField] {
        let required = Set(schema?["required"]?.array?.compactMap(\.string) ?? [])
        let properties = schema?["properties"]?.object ?? [:]
        return properties.keys
            .sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }
            .compactMap { key -> CodexFormField? in
                guard let property = properties[key] else { return nil }
                return CodexFormField(
                    key: key, kind: kind(of: property), isRequired: required.contains(key),
                    defaultValue: property["default"].flatMap { $0.isNull ? nil : $0 })
            }
    }

    private static func kind(of property: JSONValue) -> Kind {
        if let options = property["oneOf"]?.array ?? property["anyOf"]?.array {
            let pairs = options.compactMap { option in option["const"]?.string.map { ($0, option["title"]?.string ?? $0) } }
            if !pairs.isEmpty { return .choice(values: pairs.map { $0.0 }, labels: pairs.map { $0.1 }, multiple: false) }
        }
        if let values = property["enum"]?.array?.compactMap(\.string), !values.isEmpty {
            let names = property["enumNames"]?.array?.compactMap(\.string) ?? []
            let labels = values.indices.map { names.indices.contains($0) ? names[$0] : values[$0] }
            return .choice(values: values, labels: labels, multiple: false)
        }
        switch property["type"]?.string {
        case "boolean":
            return .boolean
        case "number":
            return .number(integer: false)
        case "integer":
            return .number(integer: true)
        case "array":
            let items = property["items"]
            if let options = items?["anyOf"]?.array ?? items?["oneOf"]?.array {
                let pairs = options.compactMap { option in
                    option["const"]?.string.map { ($0, option["title"]?.string ?? $0) }
                }
                return .choice(values: pairs.map { $0.0 }, labels: pairs.map { $0.1 }, multiple: true)
            }
            let values = items?["enum"]?.array?.compactMap(\.string) ?? []
            return values.isEmpty ? .text : .choice(values: values, labels: values, multiple: true)
        default:
            return .text
        }
    }

    func question(_ property: JSONValue?) -> UserQuestion {
        let title = property?["title"]?.string.flatMap(CodexPresentation.nonEmpty)
        let description = property?["description"]?.string.flatMap(CodexPresentation.nonEmpty)
        var prompt = description ?? title ?? key
        if let defaultValue, case .choice = kind {
            prompt += " " + String(localized: "(default: \(displayValue(defaultValue)))")
        } else if let defaultValue {
            prompt += " " + String(localized: "(default: \(defaultValue.displayText))")
        } else if !isRequired {
            prompt += " " + String(localized: "(optional)")
        }
        let header = description == nil ? nil : title
        switch kind {
        case .text, .number:
            return UserQuestion(id: key, header: header, prompt: prompt, allowsFreeText: true)
        case .boolean:
            return UserQuestion(
                id: key, header: header, prompt: prompt, options: [.init(label: Self.yes), .init(label: Self.no)],
                allowsFreeText: false)
        case .choice(_, let labels, let multiple):
            return UserQuestion(
                id: key, header: header, prompt: prompt, options: labels.map { .init(label: $0) },
                allowsMultipleSelection: multiple, allowsFreeText: false)
        }
    }

    /// The label shown for a value of this field.
    private func displayValue(_ value: JSONValue) -> String {
        guard case .choice(let values, let labels, _) = kind, let text = value.string,
            let index = values.firstIndex(of: text)
        else { return value.displayText }
        return labels[index]
    }

    /// The typed value for the user's answers, or nil when they gave none that fits.
    func value(_ answers: [String]) -> JSONValue? {
        switch kind {
        case .text:
            return answers.isEmpty ? nil : .string(answers.joined(separator: ", "))
        case .number(let integer):
            guard let text = answers.first, let number = Double(text), number.isFinite else { return nil }
            if integer, number.rounded() != number { return nil }
            return .number(number)
        case .boolean:
            guard let answer = answers.first?.lowercased() else { return nil }
            if [Self.yes.lowercased(), "yes", "true"].contains(answer) { return true }
            if [Self.no.lowercased(), "no", "false"].contains(answer) { return false }
            return nil
        case .choice(let values, let labels, let multiple):
            let chosen = answers.compactMap { answer -> String? in
                if let index = labels.firstIndex(of: answer) { return values[index] }
                return values.contains(answer) ? answer : nil
            }
            if multiple { return chosen.isEmpty ? nil : .array(chosen.map { .string($0) }) }
            return chosen.first.map { .string($0) }
        }
    }

    /// Form content for the answers, falling back to defaults; nil when a required field has no usable answer.
    static func content(_ fields: [CodexFormField], answers: [String: [String]]) -> [String: JSONValue]? {
        var content: [String: JSONValue] = [:]
        for field in fields {
            if let value = field.value(CodexUserInput.cleaned(answers[field.key])) {
                content[field.key] = value
            } else if let defaultValue = field.defaultValue {
                content[field.key] = defaultValue
            } else if field.isRequired {
                return nil
            }
        }
        return content
    }
}

/// What to do with a request the app server sent.
enum CodexServerRequestAction {
    case approval(CodexApproval)
    case userInput(CodexUserInput)
    case respond(JSONValue)
    case reject(String)
}

/// Maps server-to-client requests (approvals, questions, MCP elicitations) to prompts and answers,
/// following T3 Code's handling.
enum CodexServerRequests {
    static func action(
        method: String, params: JSONValue, requestID: String, presentation: CodexPresentation,
        fileChanges: [JSONValue]?
    ) -> CodexServerRequestAction {
        switch method {
        case "item/commandExecution/requestApproval":
            return .approval(commandApproval(params, id: requestID, presentation: presentation))
        case "item/fileChange/requestApproval":
            return .approval(fileChangeApproval(params, id: requestID, presentation: presentation, changes: fileChanges))
        case "item/permissions/requestApproval":
            return .approval(permissionsApproval(params, id: requestID, presentation: presentation))
        case "execCommandApproval":
            return .approval(legacyCommandApproval(params, id: requestID))
        case "applyPatchApproval":
            return .approval(legacyPatchApproval(params, id: requestID, presentation: presentation))
        case "item/tool/requestUserInput":
            guard let input = userInput(params, id: requestID) else { return .respond(["answers": [:]]) }
            return .userInput(input)
        case "mcpServer/elicitation/request":
            return elicitation(params, id: requestID)
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

    static func commandApproval(_ params: JSONValue, id: String, presentation: CodexPresentation) -> CodexApproval {
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
        let extra = permissionLines(params["additionalPermissions"], presentation: presentation)
        return CodexApproval(
            request: ApprovalRequest(
                id: id, category: .command, title: title,
                detail: joined([
                    CodexPresentation.head(command), params["reason"]?.string,
                    extra.isEmpty ? nil : extra.joined(separator: "\n"),
                ]),
                options: options, toolCallID: params["itemId"]?.string),
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
            let command = CodexPresentation.shortened(CodexPresentation.unwrapShell(argv: prefix))
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
        let paths = requestedPaths(requested["fileSystem"], presentation: presentation)
        let (title, category): (String, ToolCategory) =
            if !paths.write.isEmpty {
                (String(localized: "Allow writing to \(paths.write.joined(separator: ", "))"), .fileChange)
            } else if !paths.read.isEmpty {
                (String(localized: "Allow reading \(paths.read.joined(separator: ", "))"), .read)
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
        let lines = permissionLines(requested, presentation: presentation)
        return CodexApproval(
            request: ApprovalRequest(
                id: id, category: category, title: title,
                detail: joined([params["reason"]?.string, lines.count > 1 ? lines.joined(separator: "\n") : nil]),
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

    /// Paths a permission profile asks to read or write, from the legacy lists and the newer `entries`.
    static func requestedPaths(_ fileSystem: JSONValue?, presentation: CodexPresentation)
        -> (read: [String], write: [String])
    {
        var read = fileSystem?["read"]?.array?.compactMap(\.string) ?? []
        var write = fileSystem?["write"]?.array?.compactMap(\.string) ?? []
        for entry in fileSystem?["entries"]?.array ?? [] {
            let path = entry["path"]
            let name =
                path?["path"]?.string ?? path?["pattern"]?.string
                ?? path?.at("value.path")?.string ?? path?.at("value.kind")?.string
            guard let name else { continue }
            switch entry["access"]?.string {
            case "write": write.append(name)
            case "read": read.append(name)
            default: break
            }
        }
        let unique = { (list: [String]) in
            list.map(presentation.relativePath).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        }
        return (unique(read), unique(write))
    }

    /// One line per extra permission a command or permission request asks for.
    static func permissionLines(_ profile: JSONValue?, presentation: CodexPresentation) -> [String] {
        guard let profile, !profile.isNull else { return [] }
        let paths = requestedPaths(profile["fileSystem"], presentation: presentation)
        var lines: [String] = []
        if !paths.write.isEmpty { lines.append(String(localized: "Write access: \(paths.write.joined(separator: ", "))")) }
        if !paths.read.isEmpty { lines.append(String(localized: "Read access: \(paths.read.joined(separator: ", "))")) }
        if profile.at("network.enabled")?.bool == true { lines.append(String(localized: "Network access")) }
        return lines
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
        let command = CodexPresentation.unwrapShell(argv: params["command"]?.array?.compactMap(\.string) ?? [])
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

    /// `request_user_input`: Codex's questions as asked, answered with option labels or typed text.
    static func userInput(_ params: JSONValue, id: String) -> CodexUserInput? {
        let text = { (value: JSONValue?) in value?.string.flatMap(CodexPresentation.nonEmpty) }
        let questions = (params["questions"]?.array ?? []).compactMap { question -> UserQuestion? in
            guard let questionID = question["id"]?.string, !questionID.isEmpty else { return nil }
            let options = (question["options"]?.array ?? []).compactMap { option -> UserQuestion.Option? in
                text(option["label"]).map { UserQuestion.Option(label: $0, detail: text(option["description"])) }
            }
            let header = text(question["header"])
            return UserQuestion(
                id: questionID, header: header, prompt: text(question["question"]) ?? header ?? questionID,
                options: options, allowsMultipleSelection: false,
                allowsFreeText: options.isEmpty || question["isOther"]?.bool == true,
                isSecret: question["isSecret"]?.bool == true)
        }
        guard !questions.isEmpty else { return nil }
        return CodexUserInput(request: UserInputRequest(id: id, questions: questions), format: .toolAnswers)
    }

    // MARK: MCP elicitations

    static func elicitationResult(_ action: String) -> JSONValue {
        ["action": .string(action), "content": .null, "_meta": .null]
    }

    /// Approve-style MCP forms (connector permission prompts) become approvals and forms that need real
    /// answers become questions. URL and verification prompts are declined, as in T3 Code.
    static func elicitation(_ params: JSONValue, id: String) -> CodexServerRequestAction {
        let decline = elicitationResult("decline")
        guard ["form", "openai/form", "openaiForm"].contains(params["mode"]?.string ?? "") else { return .respond(decline) }
        let message = params["message"]?.string.flatMap(CodexPresentation.nonEmpty)
        let server = params["serverName"]?.string.flatMap(CodexPresentation.nonEmpty) ?? "MCP"
        guard let accept = elicitationResponse(params, persist: nil) else {
            let schema = params["requestedSchema"]
            let fields = CodexFormField.fields(of: schema)
            guard !fields.isEmpty else { return .respond(decline) }
            let properties = schema?["properties"]?.object ?? [:]
            let request = UserInputRequest(
                id: id, title: message ?? String(localized: "\(server) needs more information"),
                questions: fields.map { $0.question(properties[$0.key]) })
            return .userInput(CodexUserInput(request: request, format: .form(fields)))
        }
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
        responses["cancel"] = elicitationResult("cancel")
        let title = message.map { CodexPresentation.shortened($0) } ?? String(localized: "\(server) asks for permission")
        return .approval(
            CodexApproval(
                request: ApprovalRequest(
                    id: id, category: .mcp, title: title, detail: joined([message, server]), options: options),
                responses: responses, cancelResponse: elicitationResult("cancel")))
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
