import Foundation

/// Grok Build (`grok agent stdio`), mirroring T3 Code's Grok provider and the message shapes in
/// its recorded Grok 1.0.x sessions.
struct GrokFlavor: ACPAgentFlavor {
    nonisolated static let defaultModelID = "grok-build"
    nonisolated static let apiKeyVariable = "XAI_API_KEY"
    /// Only this allow-always choice is scoped to the session; the others persist project grants.
    nonisolated static let sessionEditsOptionID = "allow-edits-session"

    /// Reads the plan's allowance; tests replace it so they never read real credentials or reach xAI.
    var usage = GrokUsageLimits.Reader.live

    var provider: ProviderKind { .grok }

    /// Explicit flags override Grok's config, so ask-for-approval threads cannot inherit always-approve.
    func arguments(for accessMode: AccessMode) -> [String] {
        switch accessMode {
        case .fullAccess: ["agent", "--always-approve", "stdio"]
        case .approval: ["--permission-mode", "default", "agent", "stdio"]
        }
    }

    /// The launch arguments carry the access mode.
    var accessModeNeedsRestart: Bool { true }
    /// `extension` makes Grok prompt for approvals without persisting command grants.
    var initializeMeta: JSONValue? { ["clientType": "extension"] }
    /// Grok writes the initialize result only after loading settings and skills, which can take 15 seconds.
    var initializeTimeout: TimeInterval { 90 }

    func authMethodID(environment: [String: String]) -> String? {
        environment[Self.apiKeyVariable]?.trimmingCharacters(in: .whitespaces).isEmpty == false ? "xai.api_key" : "cached_token"
    }

    var defaultModelID: String { Self.defaultModelID }
    var defaultModelName: String { String(localized: "Grok Build") }
    /// Grok answers `initialize` with protocol version 1 and switches models (with
    /// `_meta.reasoningEffort`) through `session/set_model`, as recorded with Grok 1.0.44.
    var selectsModelsWithSetModel: Bool { true }
    /// Grok processes image blocks even though it advertises `promptCapabilities.image: false`.
    var supportsImagePrompts: Bool { true }

    /// Grok echoes the id when the turn completes.
    func promptMeta(promptID: String) -> JSONValue? { ["promptId": .string(promptID), "requestId": .string(promptID)] }

    /// A cancelled Grok prompt can keep stale work (and `task_already_running`) alive, so Stop
    /// ends the process and the next turn reloads the session.
    var interruptStyle: ACPInterruptStyle { .terminate }
    /// Ctrl-C semantics stop stale background wakes until the next real user turn.
    var cancelMeta: JSONValue? { ["cancelTrigger": "ctrl_c"] }

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

    func extensionRequest(method: String, params: JSONValue) -> ACPExtensionAction? {
        switch XAI.method(method) {
        case "exit_plan_mode":
            // Coincide shows the plan itself, so Grok's own approval gate is abandoned.
            return .capturePlan(markdown: XAI.exitPlanMarkdown(params), placeholder: XAI.emptyPlan, response: XAI.exitPlanResponse)
        case "ask_user_question":
            return .ask(XAI.questionSet(params))
        default:
            return nil
        }
    }

    func extensionEvents(method: String, params: JSONValue) -> [ACPExtensionEvent] {
        var events: [ACPExtensionEvent] = []
        if let completion = XAI.promptCompletion(method: method, params: params) {
            events.append(
                .promptCompleted(
                    promptID: completion.promptID, stopReason: XAI.stopReason(completion.stopReason),
                    failure: XAI.failure(completion), usage: XAI.usage(completion.usage)))
        } else if let completion = XAI.backgroundCompletion(method: method, params: params), let promptID = completion.promptID {
            events.append(
                .backgroundPromptCompleted(
                    promptID: promptID, stopReason: XAI.stopReason(completion.stopReason), failure: XAI.failure(completion)))
        }
        switch XAI.method(method) {
        case "models/update":
            if let state = ACPModelState(json: params) { events.append(.modelState(state)) }
        case "session_notification", "session/update":
            let update = params["update"]
            if update?["sessionUpdate"]?.string == "model_changed", let model = update?["model_id"]?.string {
                events.append(.modelChanged(id: model, effort: update?["reasoning_effort"]?.string))
            }
        default:
            break
        }
        return events
    }

    /// Background command and subagent wakes run as Grok's own `task-completed-…` prompts.
    func isBackgroundUpdate(meta: JSONValue?) -> Bool {
        meta?["promptId"]?.string?.hasPrefix(XAI.backgroundPromptPrefix) == true
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

    /// Grok keeps the plan it proposes in `~/.grok/sessions/…/plan.md`.
    func planDocument(in toolCall: ACPToolCallState) -> String? {
        let input = toolCall.rawInput
        if let path = input?["file_path"]?.string ?? input?["path"]?.string, XAI.isPlanPath(path),
            let content = input?["content"]?.string
        {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for entry in toolCall.content {
            if case .diff(let path, _, let text) = entry, XAI.isPlanPath(path) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
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

    /// `grok --version`, then `grok models` for the sign-in state and model ids, as T3 Code does.
    /// Neither starts the agent.
    func probe(executable: URL, environment: [String: String]) async -> ACPProbe {
        let probeEnvironment = GrokCLI.probeEnvironment(environment)
        let cache = GrokCLI.cachedModels(environment)
        let offline = GrokCLI.modelOptions(listed: [], cache: cache)
        let started = Date()
        let versionRun = await ProcessRunner.run(executable, ["--version"], environment: probeEnvironment, timeout: 5)
        let version = GrokCLI.version(from: versionRun.stdout + "\n" + versionRun.stderr)
        guard versionRun.succeeded else {
            // ProcessRunner stops a process that outlives its timeout with SIGTERM.
            let timedOut = versionRun.status == SIGTERM && Date().timeIntervalSince(started) >= 5
            return ACPProbe(
                status: ProviderStatus(
                    state: .error, version: version, executable: executable,
                    message: timedOut
                        ? String(localized: "Grok CLI is installed but timed out while running `grok --version`.")
                        : String(localized: "Grok CLI is installed but failed to run.")),
                models: offline)
        }
        let usesAPIKey = environment[Self.apiKeyVariable]?.trimmingCharacters(in: .whitespaces).isEmpty == false
        var listing = await GrokCLI.listModels(executable, probeEnvironment)
        // An expired token prints the logged-out line while the CLI refreshes it; ask once more.
        if listing?.authenticated == false, !usesAPIKey, let recheck = await GrokCLI.listModels(executable, probeEnvironment),
            recheck.authenticated != nil
        {
            listing = recheck
        }
        let models = GrokCLI.modelOptions(listed: listing?.models ?? [], cache: cache)
        if usesAPIKey {
            return ACPProbe(
                status: ProviderStatus(state: .ready, version: version, executable: executable, account: String(localized: "xAI API key")),
                models: models)
        }
        if listing?.authenticated == false {
            return ACPProbe(
                status: ProviderStatus(
                    state: .notAuthenticated, version: version, executable: executable,
                    message: String(localized: "Grok CLI is installed but not logged in. Run `grok login`.")),
                models: models)
        }
        let authURL = GrokCLI.home(environment).appendingPathComponent("auth.json")
        let email = FileManager.default.contents(atPath: authURL.path).flatMap(GrokCLI.accountEmail(authJSON:))
        let account = email ?? (listing?.authenticated == true ? String(localized: "Grok account") : nil)
        return ACPProbe(
            status: ProviderStatus(state: .ready, version: version, executable: executable, account: account), models: models)
    }

    func offlineModels(environment: [String: String]) -> [ModelOption] {
        GrokCLI.modelOptions(listed: [], cache: GrokCLI.cachedModels(environment))
    }

    /// The grok.com subscription's allowance from xAI's billing endpoint (see `GrokUsageLimits`).
    func usageLimits(environment: [String: String]) async -> UsageLimitsOutcome? {
        await usage.read(environment: environment)
    }
}

/// Grok's `x.ai/*` additions to ACP. Method names arrive with or without the `_` extension prefix.
enum XAI {
    nonisolated static let rateLimitedCode = -32003
    nonisolated static let backgroundPromptPrefix = "task-completed-"
    nonisolated static let emptyPlan = "# No plan written yet\n\n(The agent exited plan mode without writing a plan.)"

    struct PromptCompletion: Sendable, Hashable {
        var promptID: String?
        var stopReason: String?
        var agentResult: String?
        var usage: JSONValue?
    }

    /// The method name without its `_` prefix and `x.ai/` namespace, or nil for other vendors.
    nonisolated static func method(_ name: String) -> String? {
        let bare = name.hasPrefix("_") ? String(name.dropFirst()) : name
        return bare.hasPrefix("x.ai/") ? String(bare.dropFirst(5)) : nil
    }

    /// Grok can report the end of a turn before (or instead of) the prompt response, either as
    /// `x.ai/session/prompt_complete` or as a `turn_completed` session notification.
    nonisolated static func promptCompletion(method name: String, params: JSONValue) -> PromptCompletion? {
        switch method(name) {
        case "session/prompt_complete":
            let promptID = params["promptId"]?.string.flatMap(ACPToolCallState.nonEmpty)
            guard promptID?.hasPrefix(backgroundPromptPrefix) != true else { return nil }
            return PromptCompletion(
                promptID: promptID, stopReason: params["stopReason"]?.string, agentResult: params["agentResult"]?.string,
                usage: nil)
        case "session_notification", "session/update":
            // Prompt identity is required so background completions never end the user's turn.
            guard let update = params["update"], update["sessionUpdate"]?.string == "turn_completed",
                let promptID = (update["prompt_id"]?.string ?? update["promptId"]?.string).flatMap(ACPToolCallState.nonEmpty),
                !promptID.hasPrefix(backgroundPromptPrefix)
            else { return nil }
            return PromptCompletion(
                promptID: promptID, stopReason: update["stop_reason"]?.string ?? update["stopReason"]?.string,
                agentResult: update["agent_result"]?.string, usage: update["usage"])
        default:
            return nil
        }
    }

    /// The end of a background wake (`task-completed-…`), which `promptCompletion` leaves out.
    nonisolated static func backgroundCompletion(method name: String, params: JSONValue) -> PromptCompletion? {
        switch method(name) {
        case "session/prompt_complete":
            guard let promptID = params["promptId"]?.string, promptID.hasPrefix(backgroundPromptPrefix) else { return nil }
            return PromptCompletion(
                promptID: promptID, stopReason: params["stopReason"]?.string, agentResult: params["agentResult"]?.string,
                usage: nil)
        case "session_notification", "session/update":
            guard let update = params["update"], update["sessionUpdate"]?.string == "turn_completed",
                let promptID = update["prompt_id"]?.string ?? update["promptId"]?.string,
                promptID.hasPrefix(backgroundPromptPrefix)
            else { return nil }
            return PromptCompletion(
                promptID: promptID, stopReason: update["stop_reason"]?.string ?? update["stopReason"]?.string,
                agentResult: update["agent_result"]?.string, usage: update["usage"])
        default:
            return nil
        }
    }

    /// Grok's stop reasons beyond ACP's (`rate_limit`, `error`) end the turn as failed instead.
    nonisolated static func stopReason(_ value: String?) -> String {
        switch value {
        case "cancelled", "end_turn", "max_tokens", "max_turn_requests", "refusal": value ?? "end_turn"
        default: "end_turn"
        }
    }

    nonisolated static func failure(_ completion: PromptCompletion) -> String? {
        switch completion.stopReason {
        case "rate_limit": String(localized: "Grok usage limit reached. Try again later.")
        case "error":
            completion.agentResult.flatMap(ACPToolCallState.nonEmpty) ?? String(localized: "Grok ended the turn with an error.")
        default: nil
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

    private struct Question {
        struct Option {
            var label: String
            var description: String?
            var preview: String?
        }

        var id: String
        var text: String
        var options: [Option]
        var multiSelect: Bool
    }

    /// `ask_user_question` as Coincide questions. The reply follows T3 Code: answers keyed by the
    /// question text, typed answers sent as `Other` with the text in `annotations[...].notes`.
    @MainActor
    static func questionSet(_ params: JSONValue) -> ACPQuestionSet {
        var ids = Set<String>()
        let questions = (unwrap(params)["questions"]?.array ?? []).enumerated().compactMap { index, question -> Question? in
            guard let text = question["question"]?.string.flatMap(ACPToolCallState.nonEmpty) else { return nil }
            var id = question["id"]?.string.flatMap(ACPToolCallState.nonEmpty) ?? text
            if !ids.insert(id).inserted { id += "#\(index)" }
            let options = (question["options"]?.array ?? []).compactMap { option -> Question.Option? in
                guard let label = option["label"]?.string, !label.isEmpty else { return nil }
                return Question.Option(
                    label: label, description: option["description"]?.string.flatMap(ACPToolCallState.nonEmpty),
                    preview: option["preview"]?.string.flatMap(ACPToolCallState.nonEmpty))
            }
            return Question(id: id, text: text, options: options, multiSelect: question["multiSelect"]?.bool == true)
        }
        let asked = questions.map { question in
            UserQuestion(
                id: question.id, prompt: question.text,
                options: question.options.isEmpty
                    ? [UserQuestion.Option(label: String(localized: "OK"), detail: String(localized: "Continue"))]
                    : question.options.map { UserQuestion.Option(label: $0.label, detail: $0.description) },
                allowsMultipleSelection: question.multiSelect, allowsFreeText: true)
        }
        return ACPQuestionSet(questions: asked) { answers in
            guard let answers else { return ["outcome": "cancelled"] }
            var selections: [String: JSONValue] = [:]
            var annotations: [String: JSONValue] = [:]
            for question in questions {
                let values = (answers[question.id] ?? answers[question.text] ?? []).compactMap(ACPToolCallState.nonEmpty)
                guard !values.isEmpty else { continue }
                let chosen = values.compactMap { value in question.options.first { $0.label == value } }
                let notes = values.filter { value in !question.options.contains { $0.label == value } }
                let labels = chosen.isEmpty ? ["Other"] : chosen.map(\.label)
                selections[question.text] = .array(labels.map(JSONValue.string))
                var annotation: [String: JSONValue] = [:]
                if !question.multiSelect, let preview = chosen.lazy.compactMap(\.preview).first { annotation["preview"] = .string(preview) }
                if !notes.isEmpty { annotation["notes"] = .string(notes.joined(separator: "\n")) }
                if !annotation.isEmpty { annotations[question.text] = .object(annotation) }
            }
            var reply: [String: JSONValue] = ["outcome": "accepted", "answers": .object(selections)]
            if !annotations.isEmpty { reply["annotations"] = .object(annotations) }
            return .object(reply)
        }
    }

    /// Token counts from `turn_completed`; cost arrives in ticks of 1e-10 USD.
    nonisolated static func usage(_ value: JSONValue?) -> TokenUsage? {
        guard let value, value.object != nil else { return nil }
        let ticks = value["costUsdTicks"]?.number.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let usage = TokenUsage(
            outputTokens: value["outputTokens"]?.acpInt, cachedInputTokens: value["cachedReadTokens"]?.acpInt,
            costUSD: ticks.map { $0 / 10_000_000_000 })
        return usage == TokenUsage() ? nil : usage
    }

    /// A plan document under `<home>/.grok/sessions/` (or `$GROK_HOME/sessions/`), without `..`.
    nonisolated static func isPlanPath(_ path: String) -> Bool {
        let path = path.trimmingCharacters(in: .whitespaces)
        guard path.hasSuffix("/plan.md"), !path.split(separator: "/").contains("..") else { return false }
        var prefixes = [FileManager.default.homeDirectoryForCurrentUser.path + "/.grok/sessions/", "~/.grok/sessions/"]
        if let custom = ProcessInfo.processInfo.environment["GROK_HOME"].flatMap(ACPToolCallState.nonEmpty) {
            prefixes.append((custom as NSString).expandingTildeInPath + "/sessions/")
        }
        if prefixes.contains(where: { path.hasPrefix($0) && path.count > $0.count + "plan.md".count }) { return true }
        return path.range(of: #"^/(Users|home)/[^/]+/\.grok/sessions/([^/]+/)+plan\.md$"#, options: .regularExpression) != nil
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

    /// Keeps probes from starting Grok's self-updater.
    nonisolated static func probeEnvironment(_ environment: [String: String]) -> [String: String] {
        var environment = environment
        environment["GROK_DISABLE_AUTOUPDATER"] = "1"
        return environment
    }

    /// `grok models` reports the sign-in state and model ids without starting the agent.
    /// Only a clean exit is parsed; failures print help text that is not a model list.
    nonisolated static func listModels(_ executable: URL, _ environment: [String: String]) async -> ModelsOutput? {
        let run = await ProcessRunner.run(executable, ["models"], environment: environment, timeout: 10)
        guard run.succeeded else { return nil }
        return parseModels(run.stdout + "\n" + run.stderr)
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

    nonisolated static func cachedModels(_ environment: [String: String]) -> [String: CachedModel] {
        let url = home(environment).appendingPathComponent("models_cache.json")
        return FileManager.default.contents(atPath: url.path).map(parseModelsCache) ?? [:]
    }

    /// Only catalog details are read; entries also hold credentials, which are never touched.
    nonisolated static func parseModelsCache(_ data: Data) -> [String: CachedModel] {
        guard let json = JSONValue.parse(data), let models = json["models"]?.object else { return [:] }
        var result: [String: CachedModel] = [:]
        for (id, entry) in models {
            let info = entry["info"] ?? entry
            guard info["hidden"]?.bool != true else { continue }
            let meta: JSONValue = [
                "supportsReasoningEffort": info["supports_reasoning_effort"] ?? .bool(true),
                "reasoningEffort": info["reasoning_effort"] ?? .null,
                "reasoningEfforts": info["reasoning_efforts"] ?? [],
            ]
            let efforts = ACPModels.metaEfforts(meta)
            result[id] = CachedModel(
                id: id, name: info["name"]?.string ?? displayName(id), efforts: efforts.values,
                defaultEffort: efforts.preferred, contextWindow: info["context_window"]?.acpInt)
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
