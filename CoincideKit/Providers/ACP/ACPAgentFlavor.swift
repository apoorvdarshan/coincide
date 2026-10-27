import Foundation

/// What differs between ACP agents on top of the shared session: how to launch the CLI, how it
/// signs in, which choices its approvals offer, and the extensions it adds to the protocol.
/// Every requirement has a default, so an agent that follows the spec only names its provider.
@MainActor
public protocol ACPAgentFlavor {
    var provider: ProviderKind { get }
    /// Arguments that start the agent's ACP server over stdio.
    func arguments(for accessMode: AccessMode) -> [String]
    func environment(_ base: [String: String], executable: URL) -> [String: String]
    var clientCapabilities: ACPClientCapabilities { get }
    var initializeMeta: JSONValue? { get }
    var initializeTimeout: TimeInterval { get }
    /// The method to pass to `authenticate`, eagerly or when the agent answers `auth_required`.
    func authMethodID(environment: [String: String]) -> String?
    var authenticatesEagerly: Bool { get }
    /// Allow time for a browser sign-in the agent starts by itself.
    var authenticateTimeout: TimeInterval { get }
    /// Reopen sessions with `session/resume` (no history replay) when the agent offers both.
    var prefersResume: Bool { get }
    var cancelMeta: JSONValue? { get }
    /// Start a new process after the user stops a turn, for agents that keep stale work otherwise.
    var restartsAfterInterrupt: Bool { get }
    /// The launch arguments encode the access mode, so changing it needs a new process.
    var accessModeNeedsRestart: Bool { get }
    /// The session mode that grants `accessMode`, for agents whose permission level is a mode.
    func sessionMode(for accessMode: AccessMode) -> String?
    /// The model id that keeps the session's current model. It is never sent to the agent.
    var defaultModelID: String { get }
    var defaultModelName: String { get }
    /// Reject models the session does not list instead of letting the agent decide.
    var requiresListedModel: Bool { get }
    /// The agent's slash command for a planning turn, used when it has no plan session mode.
    var planCommand: String? { get }
    /// Send images even when the agent does not advertise image prompts.
    var acceptsImages: Bool { get }
    /// Grok's `x.ai/*` extensions: prompt completion, plan capture and questions.
    var usesXAIExtensions: Bool { get }
    /// Give each process its own temporary folder and delete it when the process ends.
    var usesPrivateTemporaryDirectory: Bool { get }
    func approvalOptions(for request: ACPPermissionRequest) -> [ApprovalOption]
    /// Permission requests whose options are answers to a question rather than approvals.
    func isQuestion(_ request: ACPPermissionRequest) -> Bool
    func normalize(_ toolCall: inout ACPToolCallState)
    func models(initialize: ACPInitializeResult?, setup: ACPSessionSetup) -> [ModelOption]
    func message(for error: Error) -> String
    /// A notice for a non-JSON line the agent printed on stdout, such as a sign-in link.
    func notice(forUnparsedLine line: String) -> String?
}

extension ACPAgentFlavor {
    public func arguments(for accessMode: AccessMode) -> [String] { [] }
    public func environment(_ base: [String: String], executable: URL) -> [String: String] { base }
    public var clientCapabilities: ACPClientCapabilities { ACPClientCapabilities() }
    public var initializeMeta: JSONValue? { nil }
    public var initializeTimeout: TimeInterval { 60 }
    public func authMethodID(environment: [String: String]) -> String? { nil }
    public var authenticatesEagerly: Bool { false }
    public var authenticateTimeout: TimeInterval { 300 }
    public var prefersResume: Bool { false }
    public var cancelMeta: JSONValue? { nil }
    public var restartsAfterInterrupt: Bool { false }
    public var accessModeNeedsRestart: Bool { false }
    public func sessionMode(for accessMode: AccessMode) -> String? { nil }
    public var defaultModelID: String { "default" }
    public var defaultModelName: String { String(localized: "Default") }
    public var requiresListedModel: Bool { false }
    public var planCommand: String? { nil }
    public var acceptsImages: Bool { false }
    public var usesXAIExtensions: Bool { false }
    public var usesPrivateTemporaryDirectory: Bool { false }

    /// The agent's own choices, in its order, plus Cancel.
    public func approvalOptions(for request: ACPPermissionRequest) -> [ApprovalOption] {
        request.options.compactMap { option in
            guard let kind = option.kind else { return nil }
            return ApprovalOption(id: option.id, label: option.name, kind: ACPApprovals.kind(kind))
        } + [ACPApprovals.cancelOption]
    }

    public func isQuestion(_ request: ACPPermissionRequest) -> Bool { false }
    public func normalize(_ toolCall: inout ACPToolCallState) {}

    public func models(initialize: ACPInitializeResult?, setup: ACPSessionSetup) -> [ModelOption] {
        ACPModels.options(
            provider: provider, setup: setup, initialize: initialize, defaultModelID: defaultModelID,
            defaultModelName: defaultModelName, supportsImages: acceptsImages || initialize?.promptImage == true)
    }

    public func message(for error: Error) -> String {
        if let error = error as? ACPError, error.code == ACPError.authRequired {
            return String(localized: "\(provider.displayName) needs you to sign in before it can continue.")
        }
        return error.localizedDescription
    }

    public func notice(forUnparsedLine line: String) -> String? { nil }
}

/// Shared mapping between ACP permission options and Coincide approval choices.
public enum ACPApprovals {
    /// Id of the Cancel choice Coincide adds to every approval; it answers `cancelled`.
    public nonisolated static let cancelOptionID = "coincide.cancel"

    public nonisolated static var cancelOption: ApprovalOption {
        ApprovalOption(id: cancelOptionID, label: String(localized: "Cancel"), kind: .cancel)
    }

    public nonisolated static func kind(_ kind: ACPPermissionOption.Kind) -> ApprovalOption.Kind {
        switch kind {
        case .allowOnce: .allowOnce
        case .allowAlways: .allowAlways
        case .rejectOnce, .rejectAlways: .deny
        }
    }
}

/// Builds the model picker entries from what an ACP session reports.
public enum ACPModels {
    private nonisolated static let effortRank = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// The session's models after a pseudo entry that keeps the current model. Efforts come from
    /// the model's `_meta.reasoningEfforts` (Grok) or, for the current model, the reasoning option.
    public nonisolated static func options(
        provider: ProviderKind, setup: ACPSessionSetup, initialize: ACPInitializeResult?, defaultModelID: String,
        defaultModelName: String, supportsImages: Bool
    ) -> [ModelOption] {
        let state = setup.models ?? initialize?.modelState
        let reasoning = setup.reasoningOption
        var entries: [(id: String, name: String, meta: JSONValue?)] = []
        if let option = setup.modelOption {
            entries = option.choices.map { choice in
                (choice.value, choice.name, state?.availableModels.first { $0.modelID == choice.value }?.meta)
            }
        } else if let state {
            entries = state.availableModels.map { ($0.modelID, $0.name, $0.meta) }
        }
        let current = setup.currentModelID
        var seen = Set<String>()
        var models: [ModelOption] = []
        for entry in entries where !entry.id.isEmpty && entry.id != defaultModelID && seen.insert(entry.id).inserted {
            var efforts = metaEfforts(entry.meta)
            var defaultEffort = efforts.preferred
            if efforts.values.isEmpty, entry.id == current, let reasoning {
                efforts.values = sortedEfforts(reasoning.choices.map(\.value))
                defaultEffort = reasoning.currentValue
            }
            models.append(
                ModelOption(
                    provider: provider, modelID: entry.id, displayName: entry.name.isEmpty ? entry.id : entry.name,
                    efforts: efforts.values, defaultEffort: defaultEffort,
                    contextWindow: entry.meta?["totalContextTokens"]?.int ?? entry.meta?["contextWindow"]?.int,
                    supportsImages: supportsImages))
        }
        guard !models.isEmpty else { return [] }
        let name = current.flatMap { id in models.first { $0.modelID == id }?.displayName }
        let pseudo = ModelOption(
            provider: provider, modelID: defaultModelID,
            displayName: name.map { "\(defaultModelName) (\($0))" } ?? defaultModelName, supportsImages: supportsImages)
        return [pseudo] + models
    }

    /// Grok's `{"supportsReasoningEffort":true,"reasoningEffort":"high","reasoningEfforts":[{"value":"high","default":true}]}`.
    nonisolated static func metaEfforts(_ meta: JSONValue?) -> (values: [String], preferred: String?) {
        guard let meta, meta["supportsReasoningEffort"]?.bool != false, let entries = meta["reasoningEfforts"]?.array else {
            return ([], nil)
        }
        var values: [String] = []
        var marked: String?
        for entry in entries {
            guard let value = [entry["value"]?.string, entry["id"]?.string].compactMap(\.self).first(where: isEffortToken),
                !values.contains(value)
            else { continue }
            values.append(value)
            if marked == nil, entry["default"]?.bool == true || entry["isDefault"]?.bool == true { marked = value }
        }
        let current = meta["reasoningEffort"]?.string.flatMap { values.contains($0) ? $0 : nil }
        return (sortedEfforts(values), current ?? marked)
    }

    /// Orders efforts from least to most reasoning; unknown names keep their place at the end.
    nonisolated static func sortedEfforts(_ values: [String]) -> [String] {
        values.enumerated().sorted { lhs, rhs in
            let left = effortRank.firstIndex(of: lhs.element.lowercased()) ?? effortRank.count + lhs.offset
            let right = effortRank.firstIndex(of: rhs.element.lowercased()) ?? effortRank.count + rhs.offset
            return left < right
        }.map(\.element)
    }

    nonisolated static func isEffortToken(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"#, options: .regularExpression) != nil
    }
}
