import Foundation

/// Vercel's fx (`fx acp`), mirroring T3 Code's fx provider (`packages/provider-fx`) and the message shapes in its
/// recorded fx 0.0.13 sessions.
struct FxFlavor: ACPAgentFlavor {
    /// T3 Code's id for "Default": the model `fx status` reports, never an fx model id.
    nonisolated static let defaultModelID = "default"
    /// fx's `effort` option, which every model shares (T3 Code's Effort control).
    nonisolated static let efforts = ["auto", "low", "medium", "high", "xhigh", "max"]
    /// A thread starts at medium, as in T3 Code.
    nonisolated static let defaultEffort = "medium"
    /// Supervised: fx asks before it changes files or runs commands.
    nonisolated static let supervisedMode = "ask"
    nonisolated static let versionTimeout: TimeInterval = 4

    var provider: ProviderKind { .fx }

    func arguments(for accessMode: AccessMode) -> [String] { ["acp"] }

    /// Both access modes run fx Supervised, as T3 Code runs a thread set to full access: fx has no full access, and
    /// its automatic review (`auto`, `code` before vercel-labs/fx#1189) has no Coincide access mode.
    func sessionMode(for accessMode: AccessMode) -> String? { Self.supervisedMode }
    /// fx 0.0.13 reports `ask` on a new or loaded session but runs its saved default until a client sets the mode.
    var enforcesSessionMode: Bool { true }

    var defaultModelID: String { Self.defaultModelID }
    var defaultEffort: String? { Self.defaultEffort }

    /// The picker keeps the models the probe read (T3 Code offers its snapshot's): a session lists only its backend's
    /// models and knows nothing of the model "Default" stands for.
    func models(initialize: ACPInitializeResult?, setup: ACPSessionSetup) -> [ModelOption] { [] }

    func normalize(_ toolCall: inout ACPToolCallState) {
        FxSubagent.normalize(&toolCall)
    }

    func message(for error: Error) -> String {
        if let error = error as? ACPError, error.code == ACPError.authRequired {
            return String(localized: "fx is not signed in. Run `fx login` in a terminal, then try again.")
        }
        return error.localizedDescription
    }

    /// `fx --version`, then `fx status --json` for the sign-in and default model and `fx models --json` for the
    /// model ids, as T3 Code does. None of them opens an ACP session, which fx would keep under `~/.fx`.
    func probe(executable: URL, environment: [String: String]) async -> ACPProbe {
        let offline = offlineModels(environment: environment)
        let started = Date()
        let versionRun = await ProcessRunner.run(executable, ["--version"], environment: environment, timeout: Self.versionTimeout)
        let version = FxCLI.version(from: versionRun.stdout + "\n" + versionRun.stderr)
        guard versionRun.succeeded else {
            // ProcessRunner stops a process that outlives its timeout with SIGTERM.
            let timedOut = versionRun.status == SIGTERM && Date().timeIntervalSince(started) >= Self.versionTimeout
            return ACPProbe(
                status: ProviderStatus(
                    state: .error, version: version, executable: executable,
                    message: timedOut
                        ? String(localized: "fx is installed but timed out while running `fx --version`.")
                        : String(localized: "fx is installed but failed to run.")),
                models: offline)
        }
        let status = await FxCLI.read(executable, ["status", "--json"], environment: environment).flatMap(FxCLI.parseStatus)
        let listed = await FxCLI.read(executable, ["models", "--json"], environment: environment).flatMap(FxCLI.parseModels)
        let auth = ACPToolCallState.nonEmpty(status?.auth ?? "")
        let defaultModel = ACPToolCallState.nonEmpty(status?.model ?? "")
        let models = FxCLI.modelOptions(defaultModel: defaultModel, listed: listed ?? [])
        let state: ProviderStatus
        if auth == FxCLI.signedOut {
            state = ProviderStatus(
                state: .notAuthenticated, version: version, executable: executable,
                message: String(localized: "fx is installed but not signed in. Run `fx login`."))
        } else if let auth {
            state = ProviderStatus(
                state: .ready, version: version, executable: executable, account: auth,
                message: listed == nil
                    ? String(localized: "fx is installed, but its models could not be listed, so the list may be incomplete.") : nil)
        } else {
            // Output Coincide cannot read is no proof of being signed out.
            state = ProviderStatus(
                state: .ready, version: version, executable: executable,
                message: String(localized: "fx is installed, but its sign-in state could not be read."))
        }
        return ACPProbe(status: state, models: models, defaultModel: defaultModel)
    }

    func offlineModels(environment: [String: String]) -> [ModelOption] {
        FxCLI.modelOptions(defaultModel: nil, listed: [])
    }

    func skills(workingDirectory: URL, environment: [String: String]) async -> [ProviderSkill] {
        await Task.detached { FxSkills.discover(workingDirectory: workingDirectory, environment: environment) }.value
    }
}

/// Reads the installed fx CLI the way T3 Code's `checkFxProviderStatus` does.
enum FxCLI {
    /// What `fx status --json` reports (fx 0.0.13).
    struct Status: Sendable, Hashable {
        /// How fx signs in (`fx login`), or `missing` when it is signed out.
        var auth: String?
        /// The model fx runs when none is chosen.
        var model: String?
    }

    nonisolated static let signedOut = "missing"
    nonisolated static let readTimeout: TimeInterval = 10

    /// The output of a command that exited cleanly; failures print help text, not JSON.
    nonisolated static func read(_ executable: URL, _ arguments: [String], environment: [String: String]) async -> String? {
        let run = await ProcessRunner.run(executable, arguments, environment: environment, timeout: readTimeout)
        return run.succeeded ? run.stdout : nil
    }

    nonisolated static func version(from output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// Nil when the output is not a JSON object.
    nonisolated static func parseStatus(_ output: String) -> Status? {
        guard let json = JSONValue.parse(output), json.object != nil else { return nil }
        return Status(auth: json["auth"]?.string, model: json["model"]?.string)
    }

    /// The ids `fx models --json` lists, or nil when the output is not a JSON object.
    nonisolated static func parseModels(_ output: String) -> [String]? {
        guard let json = JSONValue.parse(output), json.object != nil else { return nil }
        return (json["ids"]?.array ?? []).compactMap { $0.string.flatMap(ACPToolCallState.nonEmpty) }
    }

    /// Picker entries: "Default" (named after the model `fx status` reports) first, then the models `fx models` lists.
    /// Each has fx's effort levels and starts at medium.
    nonisolated static func modelOptions(defaultModel: String?, listed: [String]) -> [ModelOption] {
        let name = String(localized: "Default")
        var options = [
            ModelOption(
                provider: .fx, modelID: FxFlavor.defaultModelID, displayName: defaultModel.map { "\(name) (\($0))" } ?? name,
                efforts: FxFlavor.efforts, defaultEffort: FxFlavor.defaultEffort)
        ]
        var seen: Set<String> = [FxFlavor.defaultModelID]
        for id in listed where seen.insert(id).inserted {
            options.append(
                ModelOption(provider: .fx, modelID: id, displayName: id, efforts: FxFlavor.efforts, defaultEffort: FxFlavor.defaultEffort))
        }
        return options
    }
}

/// fx's `subagent` tool, read as T3 Code's `extractFxSubagentUpdate` does. fx streams nothing from the sub-agent over
/// ACP, so the call shows the sub-agent's task and its reply.
enum FxSubagent {
    struct Request: Sendable, Hashable {
        /// The task of a `run`, or the text of a `message`.
        var prompt: String
        /// The sub-agent a `message` goes to.
        var agent: String?
    }

    struct Outcome: Sendable, Hashable {
        var ok: Bool
        var result: String?
    }

    nonisolated static func normalize(_ toolCall: inout ACPToolCallState) {
        guard toolCall.toolName == "subagent", let request = request(toolCall.rawInput) else { return }
        toolCall.category = .task
        let prompt = ACPToolCallState.truncate(request.prompt, 100)
        toolCall.title = request.agent.map { "\($0): \(prompt)" } ?? prompt
        let text = toolCall.content.lazy.compactMap { entry -> String? in
            if case .content(let block) = entry { return block.displayText }
            return nil
        }.first
        guard let text, let outcome = outcome(text) else { return }
        if !outcome.ok, toolCall.status == .completed { toolCall.status = .failed }
        if let result = outcome.result { toolCall.content = [.content(.text(result))] }
    }

    /// `{"action":"run","task":…}` or `{"action":"message","agent":…,"message":…}`. fx 0.0.14 wraps them in
    /// `request`; later fx sends them flat (vercel-labs/fx@df0878eb).
    nonisolated static func request(_ input: JSONValue?) -> Request? {
        guard let input else { return nil }
        return flatRequest(input) ?? input["request"].flatMap(flatRequest)
    }

    private nonisolated static func flatRequest(_ value: JSONValue) -> Request? {
        switch value["action"]?.string {
        case "run":
            return value["task"]?.string.map { Request(prompt: $0, agent: nil) }
        case "message":
            guard let agent = value["agent"]?.string, let message = value["message"]?.string else { return nil }
            return Request(prompt: message, agent: agent)
        default:
            return nil
        }
    }

    /// fx clips every tool result to 199 bytes, so a long reply arrives as cut-off `{"ok":…,"result":"…` JSON. Keeps
    /// the readable start and marks the cut.
    nonisolated static func outcome(_ text: String) -> Outcome? {
        if let whole = JSONValue.parse(text), let ok = whole["ok"]?.bool, let result = whole["result"],
            result.isNull || result.string != nil
        {
            return Outcome(ok: ok, result: result.string)
        }
        guard let match = text.firstMatch(of: /^\{"ok":(true|false),"result":"((?:[^"\\]|\\.)*)/) else { return nil }
        // An escape the clip cut short, or a surrogate whose pair it cut off, cannot be decoded.
        let escaped = String(match.2)
            .replacing(/\\u[0-9a-fA-F]{0,3}$/, with: "")
            .replacing(/\\u[dD][89abAB][0-9a-fA-F]{2}$/, with: "")
        let cut = text[match.range.upperBound...].first != "\""
        let prefix = JSONValue.parse("\"\(escaped)\"")?.string
        return Outcome(ok: match.1 == "true", result: prefix.map { cut ? $0 + "…" : $0 })
    }
}
