import Foundation

/// How T3 Code's Muse provider (`provider-muse`) launches and talks to `muse serve`, for Coincide's threads.
enum MuseProtocol {
    /// Muse's model provider for Meta's models, which every session and model selection names.
    static let providerID = "meta"
    static let clientName = "coincide"

    static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    // MARK: Launching

    /// The variable Muse reads an API key from. One inherited from the login shell is dropped, so Muse uses the
    /// login `muse login` saved; one set in Coincide's settings for Muse still applies (T3's `makeMuseEnvironment`).
    static let apiKeyVariable = "META_API_KEY"

    /// The login shell's environment for Muse: without `META_API_KEY` (in any case), and with Muse's own
    /// auto-update off, since Coincide runs the binary it found.
    nonisolated static func environment(inherited: [String: String]) -> [String: String] {
        var environment = inherited.filter { $0.key.uppercased() != apiKeyVariable }
        environment["MUSE_NO_AUTO_UPDATE"] = "1"
        return environment
    }

    /// How a host process is launched. The access mode changes its flags, so a thread that changes it between turns
    /// gets a new host, which resumes the same Muse session.
    struct HostMode: Equatable {
        var accessMode: AccessMode
        /// Plan mode, which only text generation (commit messages, pull request text) asks Muse for: no shell and no
        /// file writes, as T3 Code's Muse text-generation host. Threads never run Muse in Plan mode (it has none).
        var readOnly: Bool

        init(accessMode: AccessMode, interactionMode: InteractionMode) {
            self.accessMode = accessMode
            readOnly = interactionMode == .plan
        }
    }

    /// `muse serve` flags, as T3's `museServeArgs`: the workspace is trusted, full access turns Muse's sandbox off,
    /// and text generation turns the shell and file writes off.
    static func serveArguments(_ mode: HostMode) -> [String] {
        var arguments = ["serve", "--trust-workspace"]
        if mode.readOnly {
            arguments += ["--disable-shell", "--disable-write"]
        } else if mode.accessMode == .fullAccess {
            arguments.append("--disable-sandbox")
        }
        return arguments
    }

    /// The host that only reads the model catalog and usage: no shell, no writes and no session log (T3's status check).
    static let probeArguments = ["serve", "--disable-shell", "--disable-write", "--no-session-log"]

    static func initializeParams(version: String = clientVersion) -> JSONValue {
        [
            "clientInfo": ["name": .string(clientName), "title": "Coincide", "version": .string(version)],
            // Session MCP servers are how T3 Code lends Muse its own tools; Coincide has none to lend.
            "capabilities": ["requestedCapabilities": []],
        ]
    }

    /// Throws unless `initialize` answered with the protocol envelope Coincide speaks: a schema fingerprint (the SDK's
    /// check) and envelope version 1 (T3's).
    static func checkInitializeResult(_ result: JSONValue) throws {
        guard result.at("schema.fingerprint")?.string != nil, result.at("schema.version")?.int == 1 else {
            throw AgentError.providerError(
                String(localized: "This version of Muse Code speaks a protocol Coincide does not support. Update Muse Code."))
        }
    }

    /// Without asking, or asking for anything no rule allows (T3's `museApprovalMode`).
    static func approvalMode(_ mode: AccessMode) -> String {
        mode == .fullAccess ? "allowAll" : "promptUnmatched"
    }

    /// Chosen explicitly: Muse's default profile may let an AI reviewer decide approvals (T3's `musePermissionProfile`).
    static func permissionProfile(_ mode: AccessMode) -> String {
        mode == .fullAccess ? ":unrestricted" : ":ask-me"
    }

    /// The canonical path Muse requires for workspace roots and approval paths: symlinks resolved, as T3 does with
    /// `realPath` (`/tmp` becomes `/private/tmp`).
    nonisolated static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Turns

    /// The model id to send, or nil to keep the session's model (or, for a new session, Muse's default).
    static func modelID(_ selection: ModelSelection) -> String? {
        let id = selection.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty || id == "default" ? nil : id
    }

    /// Muse's reasoning tiers, in increasing order.
    static let reasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// The selection's effort when Muse knows it; otherwise none, and Muse uses the session's default.
    static func reasoningEffort(_ selection: ModelSelection) -> String? {
        guard let effort = selection.effort?.trimmingCharacters(in: .whitespaces), reasoningEfforts.contains(effort)
        else { return nil }
        return effort
    }

    /// `/compact` summarizes the conversation with `session/compact` (T3's compact slash command).
    static func isCompactCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/compact"
    }

    /// Muse's text for a compaction that did not run, such as `no_compactable_history`.
    static func compactionReason(_ reason: String) -> String {
        switch reason {
        case "no_compactable_history": String(localized: "Muse Code has no conversation to compact yet.")
        default: String(localized: "Muse Code could not compact the conversation (\(reason)).")
        }
    }

    /// Muse lists models an account may not be able to use, and refuses them only when a turn starts. Its message then
    /// gets a hint about what to do, as T3's documentation gives.
    static func explained(_ message: String) -> String {
        guard message.localizedCaseInsensitiveContains("does not exist or you lack access") else { return message }
        return message + "\n\n"
            + String(localized: "Pick another model, or add one your account can use under Models in Muse Code’s settings.")
    }

    static func explained(_ error: Error) -> Error {
        guard case MuseRPCError.server(_, _, let message) = error, explained(message) != message else { return error }
        return AgentError.providerError(explained(message))
    }

    // MARK: Models

    /// Efforts T3 offers when Muse does not say which ones a model has.
    static let fallbackEfforts = ["low", "medium", "high", "xhigh", "max"]
    static let fallbackDefaultEffort = "high"

    /// Picker models from `model/list`, the default first, the rest in Muse's order (newest first). Models of
    /// other providers are left out, as in T3. Nil when the answer is not Meta's catalog.
    static func models(fromList result: JSONValue) -> [ModelOption]? {
        guard result["providerId"]?.string == providerID, let entries = result["models"]?.array else { return nil }
        var models: [ModelOption] = []
        var defaultID: String?
        for entry in entries {
            guard entry["providerId"]?.string == providerID, let id = entry["modelId"]?.string, !id.isEmpty,
                !models.contains(where: { $0.modelID == id })
            else { continue }
            let (efforts, defaultEffort) = efforts(of: entry)
            models.append(
                ModelOption(
                    provider: .muse, modelID: id, displayName: displayName(label: entry["displayLabel"]?.string, modelID: id),
                    efforts: efforts, defaultEffort: defaultEffort))
            if entry["isDefault"]?.bool == true, defaultID == nil { defaultID = id }
        }
        if let defaultID, let index = models.firstIndex(where: { $0.modelID == defaultID }) {
            models.insert(models.remove(at: index), at: 0)
        }
        return models
    }

    /// The efforts a catalog entry reports (only tiers Muse knows) and its default, or T3's fallback when the
    /// entry reports none or `"unknown"`.
    static func efforts(of entry: JSONValue) -> (efforts: [String], defaultEffort: String?) {
        guard let reported = entry["variants"]?.array else {
            return (fallbackEfforts, fallbackDefaultEffort)
        }
        let efforts = reported.compactMap(\.string).filter { reasoningEfforts.contains($0) }
        let preferred = entry["defaultReasoningEffort"]?.string
        return (efforts, efforts.first { $0 == preferred } ?? efforts.first)
    }

    /// Muse's label, or a name made from an id that is its own label: `muse-wonder-1.0` reads `Muse Wonder 1.0`.
    static func displayName(label: String?, modelID: String) -> String {
        let label = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? modelID
        guard label == modelID, label.hasPrefix("muse-") else { return label }
        return label.split(separator: "-").map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: Version and exits

    /// `muse 1.0.3-R2198.1` → `1.0.3-R2198.1`, keeping Muse's release revision (T3's `parseMuseVersion`), or the first
    /// plain `x.y.z`.
    static func version(in output: String) -> String? {
        if let match = output.firstMatch(of: /\b\d+\.\d+\.\d+-R\d+(?:\.\d+)?\b/) { return String(match.output) }
        return output.firstMatch(of: /\bv?(\d+\.\d+\.\d+)\b/).map { String($0.output.1) }
    }

    static func exitMessage(status: Int32, stderr: String) -> String {
        let summary = String(localized: "Muse Code exited unexpectedly (status \(Int(status))).")
        guard let tail = TerminalText.tail(stderr, lines: 3, maxLength: 800) else { return summary }
        return summary + "\n" + tail
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
