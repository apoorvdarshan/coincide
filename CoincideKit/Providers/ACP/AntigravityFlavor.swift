import Foundation

/// Google's Antigravity ACP agent (`agy_acp_server`), mirroring T3 Code's Antigravity provider.
/// The executable needs its `localharness_external` helper in the same folder. Unlike T3 Code,
/// Coincide runs it with the user's own Gemini profile and lets the agent open its own browser
/// sign-in; the link is shown as a notice as well.
struct AntigravityFlavor: ACPAgentFlavor {
    nonisolated static let defaultModelID = "antigravity-default"
    nonisolated static let harnessName = "localharness_external"
    /// What the agent prints (on stdout or stderr) when it needs a Google sign-in.
    nonisolated static let signInPrefix = "Open the following link to authenticate the ACP server: "
    /// Ambient credentials would switch the agent from the user's Google subscription to billed API access.
    nonisolated static let removedEnvironmentKeys: Set<String> = [
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT",
        "GOOGLE_CLOUD_LOCATION", "GOOGLE_CLOUD_QUOTA_PROJECT", "GOOGLE_GENAI_USE_VERTEXAI", "GCLOUD_PROJECT",
        "CLOUDSDK_CORE_PROJECT", "AGY_ACP_CCPA_PROJECT", "AGY_ACP_ENABLE_OAUTH", "ANTIGRAVITY_HARNESS_PATH",
        "ELECTRON_RUN_AS_NODE",
    ]
    /// The image types Antigravity accepts inline (T3 Code's list).
    nonisolated static let acceptedImageTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "bmp": "image/bmp",
    ]

    var provider: ProviderKind { .antigravity }

    func environment(_ base: [String: String], executable: URL) -> [String: String] {
        // Keys are compared case-insensitively so an alias cannot slip through.
        var environment = base.filter { !Self.removedEnvironmentKeys.contains($0.key.uppercased()) }
        environment["ANTIGRAVITY_HARNESS_PATH"] = Self.harnessURL(for: executable).path
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    /// Each launch unpacks about a gigabyte; a private folder is removed when the process ends.
    var usesPrivateTemporaryDirectory: Bool { true }
    /// The agent asks permission for every write, so serving files only checks the workspace.
    var clientCapabilities: ACPClientCapabilities { ACPClientCapabilities(readTextFile: true, writeTextFile: true) }
    /// The agent is a one-file bundle that unpacks itself on every launch.
    var initializeTimeout: TimeInterval { 180 }
    /// Antigravity picks its credential source from the method, so it signs in before any session call.
    func authMethodID(environment: [String: String]) -> String? { "oauth-personal" }
    var authenticatesEagerly: Bool { true }
    /// Loading replays the whole history slowly; resume does not.
    var prefersResume: Bool { true }

    func sessionMode(for accessMode: AccessMode) -> String? {
        switch accessMode {
        case .fullAccess: "yolo"
        case .approval: "default"
        }
    }

    var defaultModelID: String { Self.defaultModelID }
    /// Google decides which models an account may use; others fail with a clear message.
    var requiresListedModel: Bool { true }
    var supportsImagePrompts: Bool { true }
    var imageTypes: [String: String] { Self.acceptedImageTypes }

    func approvalOptions(for request: ACPPermissionRequest) -> [ApprovalOption] {
        var options: [ApprovalOption] = []
        if let once = request.option(.allowOnce) {
            options.append(ApprovalOption(id: once.id, label: String(localized: "Allow once"), kind: .allowOnce))
        }
        if let always = request.option(.allowAlways) {
            options.append(ApprovalOption(id: always.id, label: String(localized: "Allow for this thread"), kind: .allowAlways))
        }
        if let reject = request.option(.rejectOnce) {
            options.append(ApprovalOption(id: reject.id, label: String(localized: "Deny"), kind: .deny))
        }
        return options + [ACPApprovals.cancelOption]
    }

    /// Shell and web approvals warn about what "Allow for this thread" permits.
    func approvalNote(for request: ACPPermissionRequest) -> String? {
        guard let warning = request.option(.allowAlways)?.meta?["agy.security.warning"] else { return nil }
        guard let text = (warning["message"]?.string ?? warning["title"]?.string).flatMap(ACPToolCallState.nonEmpty) else {
            return nil
        }
        return String(text.prefix(512))
    }

    /// Native questions share the permission method (their tool call ids start with
    /// `interaction_`); their options are answers, not approvals.
    func question(for request: ACPPermissionRequest) -> ACPQuestionSet? {
        let id = request.toolCall.id
        guard id.hasPrefix("interaction_"), !request.options.isEmpty else { return nil }
        var ids = Set<String>()
        for option in request.options {
            guard ACPToolCallState.nonEmpty(option.id) != nil, ids.insert(option.id).inserted else { return nil }
        }
        let options = request.options.map { option in
            (id: option.id, label: String((ACPToolCallState.nonEmpty(option.name) ?? option.id).prefix(512)))
        }
        let question = UserQuestion(
            id: id, prompt: request.toolCall.title.flatMap(ACPToolCallState.nonEmpty) ?? String(localized: "Choose an option."),
            options: options.map { UserQuestion.Option(label: $0.label) }, allowsFreeText: false)
        return ACPQuestionSet(questions: [question]) { answers in
            let value = answers?[id]?.first
            let exact = options.first { $0.id == value }
            let byLabel = options.filter { $0.label == value }
            guard let choice = exact ?? (byLabel.count == 1 ? byLabel.first : nil) else { return ["outcome": ["outcome": "cancelled"]] }
            return ["outcome": ["outcome": "selected", "optionId": .string(choice.id)]]
        }
    }

    func normalize(_ toolCall: inout ACPToolCallState) {
        let input = toolCall.rawInput
        let output = toolCall.rawOutput
        let command = ["CommandLine", "command_line", "commandLine", "command"].lazy
            .compactMap { input?[$0]?.string ?? output?[$0]?.string }
            .compactMap(ACPToolCallState.nonEmpty).first
        if let command {
            toolCall.command = command
            if toolCall.kind == nil { toolCall.kind = "execute" }
        }
        if toolCall.exitCode == nil { toolCall.exitCode = output?["exitCode"]?.acpInt ?? output?["exit_code"]?.acpInt }
        // ACP 1.1.1 reports subagent batches as ordinary tools.
        if toolCall.kind == nil || toolCall.kind == "other",
            ["Running start_subagent", "Run start_subagent?"].contains(toolCall.title ?? "")
        {
            toolCall.category = toolCall.meta?["is_mcp_tool_call"]?.bool == true ? .mcp : .task
        }
    }

    func message(for error: Error) -> String {
        if let error = error as? ACPError {
            if error.code == ACPError.authRequired {
                return String(localized: "Antigravity needs you to sign in with Google. Start the turn again to open the sign-in page.")
            }
            if error.message.contains("SUBSCRIPTION_REQUIRED") || error.localizedDescription.contains("SUBSCRIPTION_REQUIRED") {
                return String(localized: "Google requires an eligible Antigravity subscription for this account.")
            }
        }
        return error.localizedDescription
    }

    func notice(forOutputLine line: String) -> String? {
        guard line.hasPrefix(Self.signInPrefix),
            let url = Self.signInURL(String(line.dropFirst(Self.signInPrefix.count)))
        else { return nil }
        return String(localized: "Antigravity needs you to sign in with Google. Finish signing in in your browser: \(url)")
    }

    /// Only a Google OAuth link that redirects to this Mac is shown, as T3 Code checks it.
    nonisolated static func signInURL(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.count <= 16_384, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            let components = URLComponents(string: text), components.scheme == "https",
            components.host == "accounts.google.com", components.path == "/o/oauth2/v2/auth",
            components.user == nil, components.password == nil, components.fragment == nil
        else { return nil }
        let items = components.queryItems ?? []
        let value = { (name: String) in items.filter { $0.name == name } }
        guard value("state").count == 1, let state = value("state").first?.value, !state.isEmpty, state.count <= 512,
            value("response_type").count == 1, value("response_type").first?.value == "code",
            value("redirect_uri").count == 1, let redirect = value("redirect_uri").first?.value,
            let match = redirect.range(of: #"^http://127\.0\.0\.1:[1-9][0-9]{0,4}/$"#, options: .regularExpression),
            let port = Int(redirect[match].dropFirst("http://127.0.0.1:".count).dropLast()), (1_024...65_535).contains(port)
        else { return nil }
        return text
    }

    /// The agent unpacks about a gigabyte on every launch, so detection never starts it.
    func probe(executable: URL, environment: [String: String]) async -> ACPProbe {
        let models = [ModelOption(provider: .antigravity, modelID: Self.defaultModelID, displayName: defaultModelName)]
        guard FileManager.default.isExecutableFile(atPath: Self.harnessURL(for: executable).path) else {
            return ACPProbe(
                status: ProviderStatus(
                    state: .error, executable: executable,
                    message: String(
                        localized:
                            "Antigravity's \(Self.harnessName) helper is missing next to \(executable.lastPathComponent). Install both files from the same release."
                    )),
                models: models)
        }
        return ACPProbe(
            status: ProviderStatus(
                state: .ready, executable: executable, message: String(localized: "Google sign-in is checked when a session starts.")),
            models: models)
    }

    /// The helper sits next to the real executable, even when PATH points at a symlink.
    nonisolated static func harnessURL(for executable: URL) -> URL {
        executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(harnessName)
    }
}
