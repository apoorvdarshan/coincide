import Foundation

/// Grok Build (`grok agent stdio`), mirroring T3 Code's Grok provider.
struct GrokFlavor: ACPAgentFlavor {
    nonisolated static let defaultModelID = "grok-build"
    nonisolated static let apiKeyVariable = "XAI_API_KEY"
    /// Only this allow-always choice is scoped to the session; the others persist project grants.
    nonisolated static let sessionEditsOptionID = "allow-edits-session"

    var provider: ProviderKind { .grok }

    /// Explicit flags override Grok's config, so ask-for-approval threads cannot inherit always-approve.
    func arguments(for accessMode: AccessMode) -> [String] {
        switch accessMode {
        case .fullAccess: ["agent", "--always-approve", "stdio"]
        case .approval: ["--permission-mode", "default", "agent", "stdio"]
        }
    }

    /// `extension` makes Grok prompt for approvals without persisting command grants.
    var initializeMeta: JSONValue? { ["clientType": "extension"] }
    /// Grok writes the initialize result only after loading settings and skills, which can take 15 seconds.
    var initializeTimeout: TimeInterval { 90 }

    func authMethodID(environment: [String: String]) -> String? {
        environment[Self.apiKeyVariable]?.trimmingCharacters(in: .whitespaces).isEmpty == false ? "xai.api_key" : "cached_token"
    }

    /// Ctrl-C semantics stop stale background wakes until the next real user turn.
    var cancelMeta: JSONValue? { ["cancelTrigger": "ctrl_c"] }
    /// Grok can keep `task_already_running` after a cancel until its process exits.
    var restartsAfterInterrupt: Bool { true }
    var accessModeNeedsRestart: Bool { true }
    var defaultModelID: String { Self.defaultModelID }
    var defaultModelName: String { String(localized: "Grok Build") }
    /// `/plan <task>` enters Grok's plan mode and starts the turn in one step.
    var planCommand: String? { "plan" }
    /// Grok processes image blocks even though it advertises `promptCapabilities.image: false`.
    var acceptsImages: Bool { true }
    var usesXAIExtensions: Bool { true }

    func approvalOptions(for request: ACPPermissionRequest) -> [ApprovalOption] {
        var options: [ApprovalOption] = []
        if let once = request.option(.allowOnce) {
            options.append(ApprovalOption(id: once.id, label: String(localized: "Approve"), kind: .allowOnce))
        }
        if let session = request.options.first(where: {
            $0.kind == .allowAlways && $0.id.trimmingCharacters(in: .whitespaces) == Self.sessionEditsOptionID
        }) {
            options.append(
                ApprovalOption(id: session.id, label: String(localized: "Allow all edits this session"), kind: .allowAlways))
        }
        if let reject = request.option(.rejectOnce) {
            options.append(ApprovalOption(id: reject.id, label: String(localized: "Decline"), kind: .deny))
        }
        return options + [ACPApprovals.cancelOption]
    }

    func normalize(_ toolCall: inout ACPToolCallState) {
        let tool = toolCall.meta?["x.ai/tool"]
        if toolCall.kind == nil || toolCall.kind == "other", let kind = tool?["kind"]?.string {
            switch kind {
            case "read", "list": toolCall.kind = "read"
            case "search": toolCall.kind = "search"
            case "edit", "write": toolCall.kind = "edit"
            case "delete": toolCall.kind = "delete"
            case "execute", "bash", "shell": toolCall.kind = "execute"
            case "fetch", "web": toolCall.kind = "fetch"
            default: break
            }
        }
        if let title = toolCall.title, ACPToolCallState.isGenericTitle(title) {
            let input = toolCall.rawInput
            toolCall.title = input?["description"]?.string ?? input?["variant"]?.string ?? toolCall.command ?? title
        }
        // A finished bash call succeeded only if its command exited with 0.
        if toolCall.rawOutput?["type"]?.string?.lowercased() == "bash", toolCall.isFinished, let code = toolCall.exitCode {
            toolCall.status = code == 0 ? .completed : .failed
        }
        if toolCall.toolName == "todo_write" { toolCall.category = .todo }
        if ["task", "spawn_subagent"].contains(toolCall.toolName ?? "") { toolCall.category = .task }
    }

    func message(for error: Error) -> String {
        if let error = error as? ACPError {
            if error.code == XAI.rateLimitedCode { return String(localized: "Grok usage limit reached. Try again later.") }
            if error.code == ACPError.authRequired {
                return String(localized: "Grok is not signed in. Run `grok login` in a terminal, then try again.")
            }
        }
        return error.localizedDescription
    }
}

/// Grok's `x.ai/*` additions to ACP. Method names arrive with or without the `_` extension prefix.
enum XAI {
    nonisolated static let rateLimitedCode = -32003
    nonisolated static let emptyPlan = "# No plan written yet\n\n(The agent exited plan mode without writing a plan.)"

    struct PromptCompletion: Sendable, Hashable {
        var promptID: String
        var stopReason: String?
        var agentResult: String?
        var usage: JSONValue?
    }

    struct Question: Sendable, Hashable {
        var text: String
        var options: [String]
        var details: [String]
    }

    /// The method name without its `_` prefix and `x.ai/` namespace, or nil for other vendors.
    nonisolated static func method(_ name: String) -> String? {
        let bare = name.hasPrefix("_") ? String(name.dropFirst()) : name
        return bare.hasPrefix("x.ai/") ? String(bare.dropFirst(5)) : nil
    }

    /// Sent on `session/prompt`; Grok echoes the id when the turn completes.
    nonisolated static func promptMeta(_ promptID: String) -> JSONValue {
        ["promptId": .string(promptID), "requestId": .string(promptID)]
    }

    /// Grok can report the end of a turn before (or instead of) the prompt response, either as
    /// `x.ai/session/prompt_complete` or as a `turn_completed` session notification.
    nonisolated static func promptCompletion(method name: String, params: JSONValue) -> PromptCompletion? {
        switch method(name) {
        case "session/prompt_complete":
            guard let promptID = params["promptId"]?.string, !promptID.isEmpty else { return nil }
            return PromptCompletion(
                promptID: promptID, stopReason: params["stopReason"]?.string, agentResult: params["agentResult"]?.string,
                usage: nil)
        case "session_notification", "session/update":
            guard let update = params["update"], update["sessionUpdate"]?.string == "turn_completed",
                let promptID = update["prompt_id"]?.string ?? update["promptId"]?.string, !promptID.isEmpty,
                !promptID.hasPrefix("task-completed-")
            else { return nil }
            return PromptCompletion(
                promptID: promptID, stopReason: update["stop_reason"]?.string ?? update["stopReason"]?.string,
                agentResult: update["agent_result"]?.string, usage: update["usage"])
        default:
            return nil
        }
    }

    /// Requests may wrap their params as `{"method": …, "params": {…}}`.
    nonisolated static func unwrap(_ params: JSONValue) -> JSONValue {
        if params["method"] != nil, let inner = params["params"] { return inner }
        return params
    }

    nonisolated static func exitPlanMarkdown(_ params: JSONValue) -> String? {
        unwrap(params)["planContent"]?.string.flatMap(ACPToolCallState.nonEmpty)
    }

    /// Coincide shows the captured plan itself, so the native approval gate is abandoned.
    nonisolated static var exitPlanResponse: JSONValue {
        [
            "outcome": "abandoned",
            "feedback":
                "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn.",
        ]
    }

    nonisolated static func questions(_ params: JSONValue) -> [Question] {
        (unwrap(params)["questions"]?.array ?? []).compactMap { question in
            guard let text = question["question"]?.string.flatMap(ACPToolCallState.nonEmpty) else { return nil }
            let options = question["options"]?.array ?? []
            return Question(
                text: text, options: options.compactMap { $0["label"]?.string },
                details: options.compactMap { $0["description"]?.string })
        }
    }

    nonisolated static func toolCallID(_ params: JSONValue) -> String? { unwrap(params)["toolCallId"]?.string }

    /// `{"outcome":"accepted","answers":{"<question>":["<label>"]}}`
    nonisolated static func answers(_ answers: [String: String]) -> JSONValue {
        ["outcome": "accepted", "answers": .object(answers.mapValues { .array([.string($0)]) })]
    }

    /// Token counts from `turn_completed`; cost arrives in ticks of 1e-10 USD.
    nonisolated static func usage(_ value: JSONValue?, contextTokens: Int?, contextWindow: Int?) -> TokenUsage? {
        guard let value, value.object != nil else { return nil }
        let ticks = value["costUsdTicks"]?.number
        return TokenUsage(
            inputTokens: contextTokens, outputTokens: value["outputTokens"]?.int,
            cachedInputTokens: value["cachedReadTokens"]?.int, contextWindow: contextWindow,
            costUSD: ticks.map { $0 / 10_000_000_000 })
    }
}

/// Probes the installed Grok CLI the way T3 Code does: `grok --version`, then `grok models`
/// for the sign-in state and model ids. Neither starts the agent.
enum GrokCLI {
    struct ListedModel: Sendable, Hashable {
        var id: String
        var isDefault: Bool
    }

    struct ModelsOutput: Sendable, Hashable {
        /// Nil when the output says neither way.
        var authenticated: Bool?
        var models: [ListedModel]
    }

    /// Details Grok caches in `~/.grok/models_cache.json` from its model catalog.
    struct CachedModel: Sendable, Hashable {
        var id: String
        var name: String
        var efforts: [String]
        var defaultEffort: String?
        var contextWindow: Int?
    }

    nonisolated static func version(from output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// `grok models` always exits 0; only its text tells whether the user is signed in.
    nonisolated static func parseModels(_ output: String) -> ModelsOutput {
        let authenticated: Bool? =
            output.range(of: "you are logged in", options: .caseInsensitive) != nil
            ? true
            : output.range(of: #"not authenticated|not logged in"#, options: [.regularExpression, .caseInsensitive]) != nil
                ? false : nil
        var models: [ListedModel] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") else { continue }
            let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard let id = rest.split(separator: " ").first.map(String.init), !id.isEmpty,
                !models.contains(where: { $0.id == id })
            else { continue }
            models.append(ListedModel(id: id, isDefault: rest.localizedCaseInsensitiveContains("(default)")))
        }
        return ModelsOutput(authenticated: authenticated, models: models)
    }

    nonisolated static func parseModelsCache(_ data: Data) -> [String: CachedModel] {
        guard let json = JSONValue.parse(data), let models = json["models"]?.object else { return [:] }
        var result: [String: CachedModel] = [:]
        for (id, entry) in models {
            let info = entry["info"] ?? entry
            let meta: JSONValue = [
                "supportsReasoningEffort": info["supports_reasoning_effort"] ?? .bool(true),
                "reasoningEffort": info["reasoning_effort"] ?? .null,
                "reasoningEfforts": info["reasoning_efforts"] ?? [],
            ]
            let efforts = ACPModels.metaEfforts(meta)
            result[id] = CachedModel(
                id: id, name: info["name"]?.string ?? displayName(id), efforts: efforts.values,
                defaultEffort: efforts.preferred, contextWindow: info["context_window"]?.int)
        }
        return result
    }

    /// `grok-4.7`, `grok-4.7-build-fast`, `grok-4.6`: newer versions first, a base id before its variants.
    nonisolated static func newestFirst(_ ids: [String]) -> [String] {
        ids.sorted { lhs, rhs in
            if lhs.hasPrefix(rhs) { return false }
            if rhs.hasPrefix(lhs) { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedDescending
        }
    }

    /// `grok-4.7-build-fast` → `Grok 4.7 build fast`.
    nonisolated static func displayName(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.lowercased() == "grok" ? "Grok" : String($0) }
            .joined(separator: " ")
    }

    nonisolated static func home(_ environment: [String: String]) -> URL {
        if let custom = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".grok", isDirectory: true)
    }

    /// The signed-in account's email from `auth.json`. Only the email is read.
    nonisolated static func accountEmail(authJSON data: Data) -> String? {
        guard let credentials = JSONValue.parse(data)?.object else { return nil }
        let credential =
            credentials["https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"] ?? credentials["https://accounts.x.ai/sign-in"]
        guard credential?["auth_mode"]?.string != "api_key" else { return nil }
        return credential?["email"]?.string.flatMap(ACPToolCallState.nonEmpty)
    }

    /// Picker entries: `grok-build` (named after the CLI's default model) first, then the models
    /// the CLI lists, enriched from the cache.
    nonisolated static func modelOptions(listed: [ListedModel], cache: [String: CachedModel]) -> [ModelOption] {
        let name = String(localized: "Grok Build")
        let current = listed.first(where: \.isDefault).map { cache[$0.id]?.name ?? displayName($0.id) }
        var options = [
            ModelOption(
                provider: .grok, modelID: GrokFlavor.defaultModelID, displayName: current.map { "\(name) (\($0))" } ?? name,
                supportsImages: true)
        ]
        let ids = listed.isEmpty ? newestFirst(Array(cache.keys)) : listed.map(\.id)
        for id in ids where id != GrokFlavor.defaultModelID {
            let cached = cache[id]
            options.append(
                ModelOption(
                    provider: .grok, modelID: id, displayName: cached?.name ?? displayName(id), efforts: cached?.efforts ?? [],
                    defaultEffort: cached?.defaultEffort, contextWindow: cached?.contextWindow, supportsImages: true))
        }
        return options
    }
}
