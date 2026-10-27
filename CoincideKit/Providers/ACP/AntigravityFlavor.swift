import Foundation

/// Google's Antigravity ACP agent (`agy_acp_server`), mirroring T3 Code's Antigravity provider.
/// The executable needs its `localharness_external` helper in the same folder.
struct AntigravityFlavor: ACPAgentFlavor {
    nonisolated static let defaultModelID = "antigravity-default"
    nonisolated static let harnessName = "localharness_external"
    /// What the agent prints on stdout when it needs a Google sign-in.
    nonisolated static let signInPrefix = "Open the following link to authenticate the ACP server: "
    /// Ambient credentials would switch the agent from the user's Google subscription to billed API access.
    nonisolated static let removedEnvironmentKeys: Set<String> = [
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT",
        "GOOGLE_CLOUD_LOCATION", "GOOGLE_CLOUD_QUOTA_PROJECT", "GOOGLE_GENAI_USE_VERTEXAI", "GCLOUD_PROJECT",
        "CLOUDSDK_CORE_PROJECT", "AGY_ACP_CCPA_PROJECT", "AGY_ACP_ENABLE_OAUTH", "ANTIGRAVITY_HARNESS_PATH",
        "ELECTRON_RUN_AS_NODE",
    ]

    var provider: ProviderKind { .antigravity }

    func environment(_ base: [String: String], executable: URL) -> [String: String] {
        var environment = base.filter { !Self.removedEnvironmentKeys.contains($0.key.uppercased()) }
        environment["ANTIGRAVITY_HARNESS_PATH"] = Self.harnessURL(for: executable).path
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

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
    var requiresListedModel: Bool { true }
    /// Antigravity has no plan session mode; its `/plan` command plans the task instead.
    var planCommand: String? { "plan" }
    var acceptsImages: Bool { true }
    var usesPrivateTemporaryDirectory: Bool { true }

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

    /// Native questions share the permission method; their options are answers, not approvals.
    func isQuestion(_ request: ACPPermissionRequest) -> Bool {
        request.toolCall.id.hasPrefix("interaction_")
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
        if toolCall.exitCode == nil { toolCall.exitCode = output?["exitCode"]?.int ?? output?["exit_code"]?.int }
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
            if error.message.contains("SUBSCRIPTION_REQUIRED") {
                return String(localized: "Google requires an eligible Antigravity subscription for this account.")
            }
        }
        return error.localizedDescription
    }

    func notice(forUnparsedLine line: String) -> String? {
        guard line.hasPrefix(Self.signInPrefix) else { return nil }
        let url = line.dropFirst(Self.signInPrefix.count).trimmingCharacters(in: .whitespaces)
        return String(localized: "Antigravity needs you to sign in with Google. Finish signing in in your browser: \(url)")
    }

    /// The helper sits next to the real executable, even when PATH points at a symlink.
    nonisolated static func harnessURL(for executable: URL) -> URL {
        executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(harnessName)
    }
}
