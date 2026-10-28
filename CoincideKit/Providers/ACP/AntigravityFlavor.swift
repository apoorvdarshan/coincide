import Foundation

/// Google's Antigravity ACP agent (`agy_acp_server`), mirroring T3 Code's Antigravity provider.
/// The executable needs its `localharness_external` helper in the same folder; Coincide can download
/// both from Google (see `AntigravityRuntime`).
///
/// Like T3 Code, Coincide runs it with a private Google profile under its data folder rather than the
/// user's `~/.gemini` (see `AntigravityProfile`), and with browser launches redirected to Coincide:
/// Google sign-in happens in Settings (`AntigravitySignIn`), never in the middle of a turn. A session
/// that finds the profile signed out ends with a message that says so.
struct AntigravityFlavor: ACPAgentFlavor {
    nonisolated static let defaultModelID = "antigravity-default"
    nonisolated static let harnessName = AntigravityRelease.harnessName
    /// The only sign-in Coincide uses: the user's Google account (subscription), never API billing.
    nonisolated static let authMethodID = "oauth-personal"
    /// What the agent prints (on stdout or stderr) when it needs a Google sign-in.
    nonisolated static let signInPrefix = "Open the following link to authenticate the ACP server: "
    /// The image types Antigravity accepts inline (T3 Code's list).
    nonisolated static let acceptedImageTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "bmp": "image/bmp",
    ]
    /// The models the last Google sign-in found, by profile folder, offered until a session reports its own.
    static var knownModels: [String: [ModelOption]] = [:]

    let paths: AntigravityPaths
    let profile: AntigravityProfile
    /// Leases the downloaded release a launch runs from; nil uses the shared runtime for managed paths.
    let runtime: AntigravityRuntime?

    init(paths: AntigravityPaths = .standard, profile: AntigravityProfile? = nil, runtime: AntigravityRuntime? = nil) {
        self.paths = paths
        self.profile = profile ?? AntigravityProfile(geminiHome: paths.profileDirectory)
        self.runtime = runtime
    }

    var provider: ProviderKind { .antigravity }

    func environment(_ base: [String: String], executable: URL) -> [String: String] {
        profile.environment(base, harness: Self.harnessURL(for: executable))
    }

    /// Prepares the private profile and keeps a downloaded release in place while it runs.
    func prepareLaunch(executable: URL, environment: [String: String]) async throws -> ACPLaunchLease? {
        try await profile.prepare(environment: environment)
        let runtime = runtime ?? (paths.isManaged(executable) ? AntigravityRuntime.shared : nil)
        return runtime?.lease(for: executable)
    }

    /// Each launch unpacks about a gigabyte; a private folder is removed when the process ends.
    var usesPrivateTemporaryDirectory: Bool { true }
    /// The agent asks permission for every write, so serving files only checks the workspace.
    var clientCapabilities: ACPClientCapabilities { ACPClientCapabilities(readTextFile: true, writeTextFile: true) }
    /// The agent is a one-file bundle that unpacks itself on every launch.
    var initializeTimeout: TimeInterval { 180 }
    /// Antigravity picks its credential source from the method, so it signs in before any session call.
    func authMethodID(environment: [String: String]) -> String? { Self.authMethodID }
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
            if error.code == ACPError.authRequired { return AntigravityProfile.signInRequiredMessage }
            if error.message.contains("SUBSCRIPTION_REQUIRED") || error.localizedDescription.contains("SUBSCRIPTION_REQUIRED") {
                return String(localized: "Google requires an eligible Antigravity subscription for this account.")
            }
        }
        return error.localizedDescription
    }

    /// A sign-in link during a session means the profile is signed out. Sign-in only runs from
    /// Settings (T3 Code fails the same way), so the launch ends instead of waiting for a browser.
    func failure(forOutputLine line: String) -> String? {
        guard let text = Self.authorizationText(in: line), AntigravityAuthorization.parse(text) != nil else { return nil }
        return AntigravityProfile.signInRequiredMessage
    }

    /// The link in a line the agent printed itself, or that the profile's browser helper printed for it.
    nonisolated static func authorizationText(in line: String) -> String? {
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        guard line.utf8.count <= AntigravityAuthorization.maxLength + 64 else { return nil }
        for prefix in [signInPrefix, AntigravityProfile.browserMarker] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    /// The agent unpacks about a gigabyte on every launch, so detection never starts it. It checks
    /// the harness, a downloaded release's record, and whether the private profile holds a sign-in.
    func probe(executable: URL, environment: [String: String]) async -> ACPProbe {
        let models = offlineModels(environment: environment)
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
        var version: String?
        if paths.isManaged(executable) {
            do {
                version = try AntigravityInstaller(paths: paths).activeRelease()?.version
            } catch {
                return ACPProbe(
                    status: ProviderStatus(
                        state: .error, executable: executable,
                        message: String(localized: "The downloaded Antigravity runtime is incomplete. Install it again in Settings.")),
                    models: models)
            }
        }
        guard profile.isSignedIn else {
            return ACPProbe(
                status: ProviderStatus(
                    state: .notAuthenticated, version: version, executable: executable,
                    message: String(localized: "Sign in with Google in Settings to use Antigravity.")),
                models: models)
        }
        return ACPProbe(status: ProviderStatus(state: .ready, version: version, executable: executable), models: models)
    }

    func offlineModels(environment: [String: String]) -> [ModelOption] {
        Self.knownModels[profile.geminiHome.path].flatMap { $0.isEmpty ? nil : $0 }
            ?? [ModelOption(provider: .antigravity, modelID: Self.defaultModelID, displayName: defaultModelName)]
    }

    /// The helper sits next to the real executable, even when PATH points at a symlink.
    nonisolated static func harnessURL(for executable: URL) -> URL {
        executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(harnessName)
    }
}
