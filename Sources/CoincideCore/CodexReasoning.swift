import Foundation

public enum CodexModelSelectionSource: String, Codable, Sendable { case explicitModel, cliDefault }

/// A read-only observation of CLI defaults for one checkout. Selecting it captures
/// concrete execution values; it never relies on sticky native omission semantics.
public struct CodexDefaultModelSelection: Codable, Sendable, Equatable {
    public let workspacePath: String
    public let model: String
    public let reasoningEffort: String?
    public let catalogModel: ProviderModel?
    public init(workspacePath: String, model: String, reasoningEffort: String?, catalogModel: ProviderModel? = nil) throws {
        self.workspacePath = workspacePath; self.model = model; self.reasoningEffort = reasoningEffort; self.catalogModel = catalogModel
        try validate()
    }
    public func validate() throws {
        try ProviderHistoryValidation.path(workspacePath); try CodexReasoningValidation.id(model, limit: 4_096)
        if let reasoningEffort { try CodexReasoningValidation.id(reasoningEffort, limit: 256) }
        if let catalogModel {
            try catalogModel.validateCodexReasoning()
            guard catalogModel.id == model,
                  catalogModel.reasoningEfforts.isEmpty || reasoningEffort.map({ value in catalogModel.reasoningEfforts.contains { $0.id == value } }) == true else {
                throw WorkspaceCommandError("The CLI default model or reasoning effort changed. Refresh defaults and try again.")
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case workspacePath, model, reasoningEffort, catalogModel }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(workspacePath: values.decode(String.self, forKey: .workspacePath), model: values.decode(String.self, forKey: .model),
            reasoningEffort: values.decodeIfPresent(String.self, forKey: .reasoningEffort), catalogModel: values.decodeIfPresent(ProviderModel.self, forKey: .catalogModel))
    }
}

extension ProviderModel {
    /// Pinned T3 policy: only the exact Astra wire family has the Medium override.
    /// Future or unavailable effort IDs are never synthesized into the catalog.
    public var codexDefaultReasoningEffort: String? {
        let family = id.hasPrefix("openai.") ? String(id.dropFirst("openai.".count)) : id
        if family == "gpt-6-astra", reasoningEfforts.contains(where: { $0.id == "medium" }) { return "medium" }
        return defaultReasoningEffort.flatMap { value in reasoningEfforts.contains(where: { $0.id == value }) ? value : nil }
    }
    func validateCodexReasoning() throws {
        try CodexReasoningValidation.id(id, limit: 4_096)
        guard reasoningEfforts.count <= 64, Set(reasoningEfforts.map(\.id)).count == reasoningEfforts.count else { throw WorkspaceCommandError("The model's advertised reasoning options changed. Refresh models and try again.") }
        for option in reasoningEfforts { try CodexReasoningValidation.id(option.id, limit: 256) }
        if let defaultReasoningEffort { try CodexReasoningValidation.id(defaultReasoningEffort, limit: 256) }
    }
}

extension CodingThread {
    public func codexReasoningPreference(for model: ProviderModel) -> String? {
        codexReasoningPreferences?[model.id].flatMap { value in model.reasoningEfforts.contains(where: { $0.id == value }) ? value : nil }
    }
    mutating func selectCodexModel(_ model: ProviderModel) throws {
        guard provider == .codex else { throw WorkspaceCommandError("Choose a Codex conversation before selecting its model.") }
        try model.validateCodexReasoning()
        let resolved = codexReasoningPreference(for: model) ?? model.codexDefaultReasoningEffort
        guard model.reasoningEfforts.isEmpty || resolved != nil else { throw WorkspaceCommandError("This model has no advertised default reasoning effort. Refresh models and try again.") }
        self.model = model.id; reasoningEffort = resolved; codexModelSelectionSource = .explicitModel
    }
    mutating func selectCodexReasoning(model: ProviderModel, effort: String?) throws {
        guard provider == .codex, self.model == model.id else { throw WorkspaceCommandError("The selected Codex model changed. Choose its current reasoning options again.") }
        try model.validateCodexReasoning()
        guard !model.reasoningEfforts.isEmpty else { throw WorkspaceCommandError("This model does not advertise reasoning controls.") }
        let resolved = effort ?? model.codexDefaultReasoningEffort
        guard let resolved, model.reasoningEfforts.contains(where: { $0.id == resolved }) else { throw WorkspaceCommandError("This reasoning effort is not advertised for the selected model.") }
        if let effort {
            guard codexReasoningPreferences?[model.id] != nil || (codexReasoningPreferences?.count ?? 0) < 128 else { throw WorkspaceCommandError("Too many saved model reasoning preferences. Choose Model Default for an unused model first.") }
            if codexReasoningPreferences == nil { codexReasoningPreferences = [:] }
            codexReasoningPreferences?[model.id] = effort
        } else {
            codexReasoningPreferences?.removeValue(forKey: model.id)
            if codexReasoningPreferences?.isEmpty == true { codexReasoningPreferences = nil }
        }
        reasoningEffort = resolved
    }
    mutating func selectCodexDefaultModel(_ selection: CodexDefaultModelSelection) throws {
        guard provider == .codex, workspacePath == selection.workspacePath else { throw WorkspaceCommandError("This conversation's checkout or provider changed. Read its CLI defaults again.") }
        try selection.validate()
        model = selection.model
        reasoningEffort = selection.catalogModel.flatMap { codexReasoningPreference(for: $0) } ?? selection.reasoningEffort
        codexModelSelectionSource = .cliDefault
    }
}

enum CodexReasoningValidation {
    static func id(_ value: String, limit: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= limit,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw WorkspaceCommandError("The model or reasoning selection is invalid. Refresh models and try again.") }
    }
    static func configuration(_ configuration: ProviderConfiguration) throws {
        if let effort = configuration.reasoningEffort {
            try id(effort, limit: 256)
            guard configuration.provider == .codex else { throw CoincideError("Reasoning effort belongs to a different provider.") }
        }
    }
    static func thread(_ thread: CodingThread) throws {
        if let effort = thread.reasoningEffort { try id(effort, limit: 256) }
        guard (thread.codexReasoningPreferences?.count ?? 0) <= 128,
              thread.codexModelSelectionSource == nil || (thread.provider == .codex && !thread.model.isEmpty) else { throw CoincideError("The Codex reasoning preferences are invalid.") }
        for (model, effort) in thread.codexReasoningPreferences ?? [:] { try id(model, limit: 4_096); try id(effort, limit: 256) }
    }
}
