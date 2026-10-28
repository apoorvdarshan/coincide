import Foundation

/// Requests to `codex app-server` and readers for its answers, following the schema that
/// `codex app-server generate-json-schema` prints, and T3 Code's choices where the schema leaves some.
enum CodexProtocol {
    static let clientName = "coincide"

    static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    static func initializeParams(version: String = clientVersion) -> JSONValue {
        [
            "clientInfo": ["name": .string(clientName), "title": "Coincide", "version": .string(version)],
            "capabilities": [
                "experimentalApi": true,
                "requestAttestation": false,
                // Diffs come from the file-change items; the per-turn aggregate would only duplicate them.
                "optOutNotificationMethods": ["turn/diff/updated"],
            ],
        ]
    }

    // MARK: Threads and turns

    /// Settings every thread gets, as in T3 Code.
    static let threadConfig: JSONValue = [
        "tools.update_plan.enabled": true,
        // Codex's 1 s default leaves slow-starting MCP servers out of the first request.
        "mcp_optional_startup_grace_ms": 10_000,
    ]

    static func threadStartParams(cwd: String, model: String?) -> JSONValue {
        var params: [String: JSONValue] = ["cwd": .string(cwd), "config": threadConfig]
        if let model { params["model"] = .string(model) }
        return .object(params)
    }

    static func threadResumeParams(threadID: String, cwd: String, model: String?) -> JSONValue {
        var params = threadStartParams(cwd: cwd, model: model).object ?? [:]
        params["threadId"] = .string(threadID)
        // Coincide keeps its own transcript.
        params["excludeTurns"] = true
        return .object(params)
    }

    /// `turn/start` carries the model, effort, speed, permissions and mode, so every turn applies the latest selection.
    /// `serviceTier` is the speed to ask for (`serviceTier(for:explicit:)`), or nil to leave the thread's as it is.
    static func turnStartParams(
        threadID: String, cwd: String, input: AgentTurnInput, fallbackModel: String?, skills: [String: String] = [:],
        serviceTier: String? = nil
    ) -> JSONValue {
        let model = modelID(input.selection) ?? fallbackModel
        let effort = reasoningEffort(input.selection)
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": userInput(text: input.text, imagePaths: input.imagePaths, skills: skills),
            "cwd": .string(cwd),
            // Catalogs can default summaries to "none"; ask for them on every turn.
            "summary": "detailed",
            "approvalPolicy": approvalPolicy(for: input.accessMode),
            "approvalsReviewer": "user",
            "sandboxPolicy": sandboxPolicy(for: input.accessMode),
        ]
        if let effort { params["effort"] = .string(effort) }
        if let serviceTier { params["serviceTier"] = .string(serviceTier) }
        if let model {
            params["model"] = .string(model)
            // Sent in both modes so leaving Plan mode clears it. Null instructions select Codex's own.
            params["collaborationMode"] = [
                "mode": input.interactionMode == .plan ? "plan" : "default",
                "settings": [
                    "model": .string(model), "reasoning_effort": effort.map { .string($0) } ?? .null,
                    "developer_instructions": .null,
                ],
            ]
        }
        return .object(params)
    }

    /// The text and images, plus a skill item for each `$name` in the text that names one of `skills` (name to
    /// path), as Codex's own composer sends them.
    static func userInput(text: String, imagePaths: [String], skills: [String: String] = [:]) -> JSONValue {
        var items: [JSONValue] = []
        if !text.isEmpty { items.append(["type": "text", "text": .string(text), "text_elements": []]) }
        items += imagePaths.map { ["type": "localImage", "path": .string($0)] }
        for name in mentionedSkills(in: text, known: Set(skills.keys)) {
            if let path = skills[name] { items.append(["type": "skill", "name": .string(name), "path": .string(path)]) }
        }
        return .array(items)
    }

    /// The skills a message names as `$name`, each once, in order.
    static func mentionedSkills(in text: String, known: Set<String>) -> [String] {
        guard !known.isEmpty, text.contains("$") else { return [] }
        let string = text as NSString
        var names: [String] = []
        for match in skillMention.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let name = string.substring(with: match.range(at: 2))
            if known.contains(name), !names.contains(name) { names.append(name) }
        }
        return names
    }

    private static let skillMention = try! NSRegularExpression(
        pattern: #"(^|\s)\$(?=[A-Za-z0-9:_-]*[A-Za-z])([A-Za-z0-9][A-Za-z0-9:_-]*)(?=\s|$)"#)

    /// The enabled skills from `skills/list`, for the folder asked about.
    static func skills(fromList result: JSONValue, cwd: String) -> [ProviderCommand] {
        let entries = result["data"]?.array ?? []
        let entry = entries.first { $0["cwd"]?.string == cwd }
        let skills = entry.map { $0["skills"]?.array ?? [] } ?? entries.flatMap { $0["skills"]?.array ?? [] }
        var seen: Set<String> = []
        return skills.compactMap { skill in
            guard skill["enabled"]?.bool != false, let name = skill["name"]?.string, !name.isEmpty,
                seen.insert(name).inserted
            else { return nil }
            let description =
                skill["shortDescription"]?.string ?? skill.at("interface.shortDescription")?.string ?? skill["description"]?.string
            return ProviderCommand(
                name: name, description: description, kind: .skill, path: skill["path"]?.string, isSlashCommand: false)
        }
    }

    /// Approval mode asks before anything that is not a known-safe read; full access never asks.
    static func approvalPolicy(for mode: AccessMode) -> JSONValue {
        mode == .approval ? "untrusted" : "never"
    }

    static func sandboxPolicy(for mode: AccessMode) -> JSONValue {
        mode == .approval ? ["type": "readOnly"] : ["type": "dangerFullAccess"]
    }

    /// The model id to send, or nil to let Codex use its configured default.
    static func modelID(_ selection: ModelSelection) -> String? {
        let id = selection.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty || id == "default" ? nil : id
    }

    static func reasoningEffort(_ selection: ModelSelection) -> String? {
        if let effort = selection.effort?.trimmingCharacters(in: .whitespaces), !effort.isEmpty { return effort }
        return modelID(selection).flatMap(defaultEffortOverride(for:))
    }

    /// Codex's id for standard speed.
    static let standardServiceTier = "default"

    /// The service tier a turn asks for: the selection's speed, or else nil to leave the thread's as it is. Codex keeps a
    /// tier for the thread's later turns, so once one was asked for, `explicit` asks for standard speed by name.
    static func serviceTier(for selection: ModelSelection, explicit: Bool) -> String? {
        if let speed = selection.speed?.trimmingCharacters(in: .whitespaces), !speed.isEmpty { return speed }
        return explicit ? standardServiceTier : nil
    }

    /// Effort T3 Code uses instead of the catalog default for some models.
    static func defaultEffortOverride(for model: String) -> String? {
        modelFamily(model) == "gpt-6-astra" ? "medium" : nil
    }

    /// Strips the `openai.` prefix Bedrock puts on model ids.
    static func modelFamily(_ model: String) -> String {
        model.hasPrefix("openai.gpt-") ? String(model.dropFirst("openai.".count)) : model
    }

    static func isArchivedError(_ message: String) -> Bool {
        let pattern = #"\bsession \S+ is archived\b|\bcodex unarchive\b"#
        return message.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Models

    /// Picked as the default when the catalog lists them, in this order; otherwise Codex's own default.
    static let preferredDefaultModels = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"]

    /// Shown when the CLI cannot be asked: T3 Code's current Codex models.
    static let builtInModels: [ModelOption] = [
        ModelOption(
            provider: .codex, modelID: "gpt-6-astra", displayName: "GPT-6 Astra",
            efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "medium"),
        ModelOption(
            provider: .codex, modelID: "gpt-6.1-sol", displayName: "GPT-6.1 Sol",
            efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "low"),
        ModelOption(
            provider: .codex, modelID: "gpt-6-luna", displayName: "GPT-6 Luna",
            efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium"),
    ]

    /// Picker models from `model/list` entries (all pages): the default first, then the catalog's order.
    static func models(fromEntries entries: [JSONValue]) -> [ModelOption] {
        var models: [ModelOption] = []
        var catalogDefault: String?
        for entry in entries {
            guard entry["hidden"]?.bool != true, let model = model(from: entry),
                !models.contains(where: { $0.modelID == model.modelID })
            else { continue }
            if entry["isDefault"]?.bool == true, catalogDefault == nil { catalogDefault = model.modelID }
            models.append(model)
        }
        let preferred = preferredDefaultModels.lazy.compactMap { family in
            models.first { modelFamily($0.modelID) == family }?.modelID
        }.first
        guard let defaultID = preferred ?? catalogDefault, let index = models.firstIndex(where: { $0.modelID == defaultID })
        else { return models }
        models.insert(models.remove(at: index), at: 0)
        return models
    }

    static func model(from entry: JSONValue) -> ModelOption? {
        guard let slug = entry["model"]?.string ?? entry["id"]?.string, !slug.isEmpty else { return nil }
        let efforts = (entry["supportedReasoningEfforts"]?.array ?? []).compactMap { $0["reasoningEffort"]?.string }
        let defaultEffort = [defaultEffortOverride(for: slug), entry["defaultReasoningEffort"]?.string]
            .compactMap { $0 }
            .first { efforts.isEmpty || efforts.contains($0) }
        let modalities = entry["inputModalities"]?.array?.compactMap(\.string)
        return ModelOption(
            provider: .codex, modelID: slug, displayName: displayName(entry["displayName"]?.string ?? slug),
            efforts: efforts, defaultEffort: defaultEffort, supportsImages: modalities?.contains("image") ?? true,
            speeds: speeds(from: entry))
    }

    /// T3 Code's notes for tiers, used before the catalog's own.
    private static let serviceTierDetails = ["ultrafast": String(localized: "Even faster, more expensive")]

    /// The faster service tiers a `model/list` entry offers, from `serviceTiers` or, in older catalogs, the ids in
    /// `additionalSpeedTiers`.
    static func speeds(from entry: JSONValue) -> [ModelSpeed] {
        if let tiers = entry["serviceTiers"]?.array, !tiers.isEmpty {
            return tiers.compactMap { tier in
                guard let id = tier["id"]?.string, !id.isEmpty, id != standardServiceTier else { return nil }
                let name = tier["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? id
                let description = tier["description"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                return ModelSpeed(id: id, name: name, detail: serviceTierDetails[id] ?? description)
            }
        }
        return (entry["additionalSpeedTiers"]?.array ?? []).compactMap(\.string)
            .filter { !$0.isEmpty && $0 != standardServiceTier }
            .map { id in ModelSpeed(id: id, name: id == ModelSpeed.fast.id ? ModelSpeed.fast.name : id, detail: serviceTierDetails[id]) }
    }

    /// `gpt-6-luna` → `GPT-6-Luna`; names that are already formatted stay as they are.
    static func displayName(_ name: String) -> String {
        var characters = Array(name.lowercased().hasPrefix("gpt") ? "GPT" + name.dropFirst(3) : name)
        for index in characters.indices.dropFirst()
        where characters[index - 1] == "-" && characters[index].isASCII && characters[index].isLowercase {
            characters[index] = Character(characters[index].uppercased())
        }
        return String(characters)
    }

    // MARK: Account and version

    static func providerStatus(account response: JSONValue, version: String?, executable: URL) -> ProviderStatus {
        let compatibility = versionCompatibility(version)
        if case .unsupported(let message) = compatibility {
            return ProviderStatus(state: .error, version: version, executable: executable, message: message)
        }
        let note: String? =
            switch compatibility {
            case .outdated(let message): message
            default: nil
            }
        if let account = response["account"], !account.isNull {
            return ProviderStatus(
                state: .ready, version: version, executable: executable, account: accountLabel(account), message: note)
        }
        if response["requiresOpenaiAuth"]?.bool == true {
            return ProviderStatus(
                state: .notAuthenticated, version: version, executable: executable,
                message: String(localized: "Codex CLI is not signed in. Run `codex login` and try again."))
        }
        // A custom model provider that needs no OpenAI sign-in.
        return ProviderStatus(state: .ready, version: version, executable: executable, message: note)
    }

    static func accountLabel(_ account: JSONValue) -> String? {
        switch account["type"]?.string {
        case "apiKey":
            return String(localized: "OpenAI API key")
        case "amazonBedrock":
            return "Amazon Bedrock"
        case "chatgpt":
            let email = account["email"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            switch (email, planLabel(account["planType"]?.string)) {
            case let (email?, plan?): return "\(email) (\(plan))"
            case let (email?, nil): return email
            case let (nil, plan?): return plan
            case (nil, nil): return "ChatGPT"
            }
        default:
            return nil
        }
    }

    /// Plan names as T3 Code shows them.
    static func planLabel(_ planType: String?) -> String? {
        switch planType {
        case "free": "ChatGPT Free"
        case "go": "ChatGPT Go"
        case "plus": "ChatGPT Plus"
        case "pro": "ChatGPT Pro 200"
        case "prolite": "ChatGPT Pro 100"
        case "promax": "ChatGPT Pro 500"
        case "self_serve_business_prolite": "ChatGPT Business Premium"
        case "team", "self_serve_business_usage_based", "business": "ChatGPT Business"
        case "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise": "ChatGPT Enterprise"
        case "edu", "edu_plus", "edu_pro": "ChatGPT Edu"
        case "unknown": "ChatGPT"
        default: nil
        }
    }

    /// `coincide/0.164.0 (Mac OS 27.0.1; arm64) …` → `0.164.0`.
    static func version(fromUserAgent userAgent: String) -> String? {
        guard let slash = userAgent.firstIndex(of: "/") else { return nil }
        let version = userAgent[userAgent.index(after: slash)...].prefix { !$0.isWhitespace }
        return version.isEmpty ? nil : String(version)
    }

    /// `codex-cli 0.164.0` → `0.164.0`.
    static func version(fromVersionOutput output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).last { $0.first?.isNumber == true }.map(String.init)
    }

    enum Compatibility: Equatable {
        case supported
        case outdated(String)
        case unsupported(String)
    }

    /// T3 Code's ranges: 0.156 and later work, 0.149–0.155 mostly do, anything older lacks needed protocol.
    static func versionCompatibility(_ version: String?) -> Compatibility {
        guard let version, let parts = semver(version) else { return .supported }
        if parts.lexicographicallyPrecedes([0, 149, 0]) {
            return .unsupported(String(localized: "Codex \(version) is too old. Update the Codex CLI to 0.156 or later."))
        }
        if parts.lexicographicallyPrecedes([0, 156, 0]) {
            return .outdated(String(localized: "Update the Codex CLI to 0.156 or later for full support."))
        }
        return .supported
    }

    private static func semver(_ version: String) -> [Int]? {
        let core = version.drop { $0 == "v" }.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }
}
