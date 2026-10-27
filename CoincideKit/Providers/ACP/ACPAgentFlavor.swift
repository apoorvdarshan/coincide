import Foundation

/// What differs between Agent Client Protocol agents on top of the shared `ACPSession`: how to
/// launch and probe the CLI, how it signs in, which choices its approvals offer, and the
/// extensions it adds to the protocol. Every requirement has a default that follows the spec.
///
/// ## Adding an ACP agent
/// 1. Add a `ProviderKind` case for it (Models.swift) and an `ACPProfile` case that returns it,
///    its executable names and its setup hint.
/// 2. Write a flavor struct that names its `provider` and overrides only what differs, usually
///    `arguments(for:)` (the command that starts its ACP server over stdio) and perhaps
///    `authMethodID(environment:)`, `sessionMode(for:)` or `approvalOptions(for:)`.
/// 3. Return the flavor from `ACPProfile.flavor` and register `ACPProvider(profile:)` in
///    `ProviderRegistry.builtInProviders()`.
///
/// Everything else (handshake, resume, models, effort, plan mode, approvals, questions,
/// elicitations, file system, usage, cancel and crash handling) comes from `ACPSession`.
@MainActor
public protocol ACPAgentFlavor {
    var provider: ProviderKind { get }

    // MARK: Launch

    /// Arguments that start the agent's ACP server over stdio.
    func arguments(for accessMode: AccessMode) -> [String]
    func environment(_ base: [String: String], executable: URL) -> [String: String]
    /// Give each process its own temporary folder and delete it when the process ends.
    var usesPrivateTemporaryDirectory: Bool { get }
    /// The launch arguments encode the access mode, so changing it needs a new process.
    var accessModeNeedsRestart: Bool { get }

    // MARK: Handshake

    var clientCapabilities: ACPClientCapabilities { get }
    var initializeMeta: JSONValue? { get }
    var initializeTimeout: TimeInterval { get }
    /// The method to pass to `authenticate`, eagerly or when the agent answers `auth_required`.
    /// Nil picks the first method the agent completes by itself.
    func authMethodID(environment: [String: String]) -> String?
    /// Sign in before any session call (the method then decides the credential source).
    var authenticatesEagerly: Bool { get }
    /// Sign in and retry once when a session call fails with `auth_required`.
    var authenticatesWhenRequired: Bool { get }
    /// Allow time for a browser sign-in the agent starts by itself.
    var authenticateTimeout: TimeInterval { get }
    /// Reopen sessions with `session/resume` (no history replay) when the agent offers both.
    var prefersResume: Bool { get }

    // MARK: Turns

    /// The session mode that grants `accessMode`, for agents whose permission level is a mode.
    func sessionMode(for accessMode: AccessMode) -> String?
    /// The model id that keeps the session's current model. It is never sent to the agent.
    var defaultModelID: String { get }
    var defaultModelName: String { get }
    /// Reject models the session does not list instead of letting the agent decide.
    var requiresListedModel: Bool { get }
    /// Switch models (and effort, as `_meta.reasoningEffort`) with the legacy `session/set_model`
    /// even when the agent also lists a model config option.
    var selectsModelsWithSetModel: Bool { get }
    /// Send images even when the agent does not advertise image prompts.
    var supportsImagePrompts: Bool { get }
    /// Image types the agent accepts inline; others are only mentioned by path.
    var imageTypes: [String: String] { get }
    /// `_meta` for `session/prompt`; agents that echo a prompt id use it to report completion.
    func promptMeta(promptID: String) -> JSONValue?

    // MARK: Interrupting

    var interruptStyle: ACPInterruptStyle { get }
    var cancelMeta: JSONValue? { get }
    /// How long a `.cancel` interrupt waits for the agent before the process is replaced.
    var cancelTimeout: TimeInterval { get }

    // MARK: Requests from the agent

    func approvalOptions(for request: ACPPermissionRequest) -> [ApprovalOption]
    /// Extra text for an approval, such as a warning the agent attached to one of its choices.
    func approvalNote(for request: ACPPermissionRequest) -> String?
    /// Permission requests whose options are answers to a question rather than approvals.
    func question(for request: ACPPermissionRequest) -> ACPQuestionSet?
    /// Vendor extension requests (`_vendor/method`); nil answers "method not found".
    func extensionRequest(method: String, params: JSONValue) -> ACPExtensionAction?
    /// What a vendor extension notification means for the session.
    func extensionEvents(method: String, params: JSONValue) -> [ACPExtensionEvent]
    /// Session updates (by their `_meta`) that belong to the agent's own background work rather
    /// than the running prompt.
    func isBackgroundUpdate(meta: JSONValue?) -> Bool

    // MARK: Presentation

    func normalize(_ toolCall: inout ACPToolCallState)
    /// The text of a plan document the tool call writes, for agents that keep their plan in a file.
    func planDocument(in toolCall: ACPToolCallState) -> String?
    func models(initialize: ACPInitializeResult?, setup: ACPSessionSetup) -> [ModelOption]
    func message(for error: Error) -> String
    /// A notice for a line the agent printed outside JSON-RPC (stdout or stderr), such as a sign-in link.
    func notice(forOutputLine line: String) -> String?

    // MARK: Detection

    /// Checks installation and sign-in without starting a session, and lists models for the picker.
    func probe(executable: URL, environment: [String: String]) async -> ACPProbe
    /// Models to offer before a probe succeeded, for example when the CLI is missing.
    func offlineModels(environment: [String: String]) -> [ModelOption]
}

/// How `interrupt()` stops a running prompt.
public enum ACPInterruptStyle: Sendable, Hashable {
    /// Send `session/cancel` and wait for the agent to end the prompt (the ACP default).
    case cancel
    /// End the turn at once and stop the process with everything it started; the next turn
    /// reopens the session in a new process.
    case terminate
}

/// What a probe of an installed agent found.
public struct ACPProbe: Sendable {
    public var status: ProviderStatus
    public var models: [ModelOption]

    public nonisolated init(status: ProviderStatus, models: [ModelOption]) {
        self.status = status
        self.models = models
    }
}

/// Questions an agent asks, and how the user's answers become its reply.
public struct ACPQuestionSet {
    public var title: String?
    public var questions: [UserQuestion]
    /// The agent's reply for the answers (question id to labels or typed text);
    /// nil means the user dismissed the questions.
    public var respond: @MainActor ([String: [String]]?) -> JSONValue

    public nonisolated init(
        title: String? = nil, questions: [UserQuestion], respond: @escaping @MainActor ([String: [String]]?) -> JSONValue
    ) {
        self.title = title
        self.questions = questions
        self.respond = respond
    }
}

/// How the session answers a vendor extension request.
public enum ACPExtensionAction {
    case respond(JSONValue)
    /// Shows the agent's proposed plan (or else the latest plan document it wrote, or else
    /// `placeholder`), then answers.
    case capturePlan(markdown: String?, placeholder: String?, response: JSONValue)
    /// Asks the user and answers with `ACPQuestionSet.respond`.
    case ask(ACPQuestionSet)
}

/// What a vendor extension notification tells the session.
public enum ACPExtensionEvent: Sendable, Hashable {
    /// The agent ended a prompt before (or instead of) answering `session/prompt`. A nil prompt id
    /// matches the running prompt; `failure` ends the turn as failed.
    case promptCompleted(promptID: String?, stopReason: String?, failure: String?, usage: TokenUsage?)
    /// A prompt the agent ran by itself (see `isBackgroundUpdate`) ended.
    case backgroundPromptCompleted(promptID: String, stopReason: String?, failure: String?)
    case modelState(ACPModelState)
    case modelChanged(id: String, effort: String?)
}

extension ACPAgentFlavor {
    public func arguments(for accessMode: AccessMode) -> [String] { [] }
    public func environment(_ base: [String: String], executable: URL) -> [String: String] { base }
    public var usesPrivateTemporaryDirectory: Bool { false }
    public var accessModeNeedsRestart: Bool { false }

    public var clientCapabilities: ACPClientCapabilities { ACPClientCapabilities() }
    public var initializeMeta: JSONValue? { nil }
    public var initializeTimeout: TimeInterval { 60 }
    public func authMethodID(environment: [String: String]) -> String? { nil }
    public var authenticatesEagerly: Bool { false }
    public var authenticatesWhenRequired: Bool { true }
    public var authenticateTimeout: TimeInterval { 300 }
    public var prefersResume: Bool { false }

    public func sessionMode(for accessMode: AccessMode) -> String? { nil }
    public var defaultModelID: String { "default" }
    public var defaultModelName: String { String(localized: "Default") }
    public var requiresListedModel: Bool { false }
    public var selectsModelsWithSetModel: Bool { false }
    public var supportsImagePrompts: Bool { false }
    public var imageTypes: [String: String] { ACPPrompt.commonImageTypes }
    public func promptMeta(promptID: String) -> JSONValue? { nil }

    public var interruptStyle: ACPInterruptStyle { .cancel }
    public var cancelMeta: JSONValue? { nil }
    public var cancelTimeout: TimeInterval { 5 }

    /// The agent's own choices, in its order, plus Cancel.
    public func approvalOptions(for request: ACPPermissionRequest) -> [ApprovalOption] {
        request.options.compactMap { option in
            guard let kind = option.kind else { return nil }
            return ApprovalOption(id: option.id, label: option.name, kind: ACPApprovals.kind(kind))
        } + [ACPApprovals.cancelOption]
    }

    public func approvalNote(for request: ACPPermissionRequest) -> String? { nil }
    public func question(for request: ACPPermissionRequest) -> ACPQuestionSet? { nil }
    public func extensionRequest(method: String, params: JSONValue) -> ACPExtensionAction? { nil }
    public func extensionEvents(method: String, params: JSONValue) -> [ACPExtensionEvent] { [] }
    public func isBackgroundUpdate(meta: JSONValue?) -> Bool { false }

    public func normalize(_ toolCall: inout ACPToolCallState) {}
    public func planDocument(in toolCall: ACPToolCallState) -> String? { nil }

    public func models(initialize: ACPInitializeResult?, setup: ACPSessionSetup) -> [ModelOption] {
        ACPModels.options(
            provider: provider, setup: setup, initialize: initialize, defaultModelID: defaultModelID,
            defaultModelName: defaultModelName, supportsImages: supportsImagePrompts || initialize?.promptImage == true)
    }

    public func message(for error: Error) -> String {
        if let error = error as? ACPError, error.code == ACPError.authRequired {
            return String(localized: "\(provider.displayName) needs you to sign in before it can continue.")
        }
        return error.localizedDescription
    }

    public func notice(forOutputLine line: String) -> String? { nil }

    /// Ready without running anything; the session reports the real model list once it starts.
    public func probe(executable: URL, environment: [String: String]) async -> ACPProbe {
        ACPProbe(status: ProviderStatus(state: .ready, executable: executable), models: offlineModels(environment: environment))
    }

    public func offlineModels(environment: [String: String]) -> [ModelOption] {
        [ModelOption(provider: provider, modelID: defaultModelID, displayName: defaultModelName)]
    }
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
        let current = setup.currentModelID ?? state?.currentModelID
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
                    contextWindow: entry.meta?["totalContextTokens"]?.acpInt ?? entry.meta?["contextWindow"]?.acpInt,
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
