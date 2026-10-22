import CryptoKit
import Foundation

/// Durable choices only. Ports, process IDs, environment and credentials stay
/// in the owned runtime and never enter a saved conversation or run.
public struct OpenCodeConfiguration: Codable, Sendable, Equatable, Hashable {
    public let instanceID: UUID
    public let generation: OpenCodeGeneration
    public let executable: String
    public let model: OpenCodeModelSelection?
    public let agentID: String
    public init(instanceID: UUID = UUID(), generation: OpenCodeGeneration = .v2,
                executable: String = "opencode", model: OpenCodeModelSelection? = nil, agentID: String = "build") {
        self.instanceID = instanceID; self.generation = generation; self.executable = executable
        self.model = model; self.agentID = agentID
    }
    public var runtimeIdentity: OpenCodeRuntimeIdentity { .init(instanceID: instanceID, generation: generation, executable: executable) }
    public func validate() throws {
        try Self.identifier(executable, maximum: 16_384)
        guard !executable.contains("://"), !executable.contains("="),
              executable.hasPrefix("/") || !executable.contains("/") else { throw Self.invalid() }
        if executable.hasPrefix("/") {
            guard URL(fileURLWithPath: executable).standardizedFileURL.path == executable else { throw Self.invalid() }
        } else {
            guard !executable.contains(where: { $0.isWhitespace }), executable != ".", executable != ".." else { throw Self.invalid() }
        }
        try Self.identifier(agentID); try model?.validate()
    }
    public func selecting(model: OpenCodeModelSelection?) -> Self {
        .init(instanceID: instanceID, generation: generation, executable: executable, model: model, agentID: agentID)
    }
    public func selecting(agentID: String) -> Self {
        .init(instanceID: instanceID, generation: generation, executable: executable, model: model, agentID: agentID)
    }
    private enum CodingKeys: String, CodingKey { case instanceID, generation, executable, model, agentID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(instanceID: try values.decode(UUID.self, forKey: .instanceID),
                  generation: try values.decode(OpenCodeGeneration.self, forKey: .generation),
                  executable: try values.decode(String.self, forKey: .executable),
                  model: try values.decodeIfPresent(OpenCodeModelSelection.self, forKey: .model),
                  agentID: try values.decode(String.self, forKey: .agentID))
        try validate()
    }
    static func identifier(_ value: String, maximum: Int = 4_096) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw invalid() }
    }
    static func invalid() -> CoincideError { CoincideError("The native OpenCode configuration is invalid. Choose the model and agent again.") }
}

public struct OpenCodeRuntimeIdentity: Codable, Sendable, Equatable, Hashable {
    public let instanceID: UUID
    public let generation: OpenCodeGeneration
    public let executable: String
}

extension OpenCodeModelSelection {
    public func validate() throws {
        try OpenCodeConfiguration.identifier(providerID); try OpenCodeConfiguration.identifier(id)
        if let variant { try OpenCodeConfiguration.identifier(variant) }
    }
    /// A local menu key, never parsed or sent as a wire model identifier.
    public var catalogID: String {
        let data = (try? JSONEncoder().encode([providerID, id])) ?? Data()
        return "opencode-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private enum CodingKeys: String, CodingKey { case providerID, id, variant }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(providerID: try values.decode(String.self, forKey: .providerID), id: try values.decode(String.self, forKey: .id),
                  variant: try values.decodeIfPresent(String.self, forKey: .variant))
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(providerID, forKey: .providerID); try values.encode(id, forKey: .id)
        try values.encodeIfPresent(variant, forKey: .variant)
    }
}

enum OpenCodeConfigurationValidation {
    static func configuration(_ configuration: ProviderConfiguration) throws {
        if configuration.provider == .opencode {
            guard let native = configuration.openCodeConfiguration,
                  configuration.model == (native.model?.catalogID ?? "") else { throw OpenCodeConfiguration.invalid() }
            try native.validate()
        } else if configuration.openCodeConfiguration != nil { throw OpenCodeConfiguration.invalid() }
    }
    static func thread(_ thread: CodingThread) throws {
        try configuration(.init(thread: thread))
        if let active = thread.activeRun { try configuration(active.configuration) }
    }
}

extension CodingThread {
    mutating func selectOpenCodeModel(_ model: ProviderModel?) throws {
        guard provider == .opencode, let native = openCodeConfiguration else { throw OpenCodeConfiguration.invalid() }
        if let model {
            guard let wire = model.openCodeSelection, wire.variant == nil, model.id == wire.catalogID,
                  (model.openCodeVariants?.count ?? 0) <= 256,
                  Set(model.openCodeVariants ?? []).count == (model.openCodeVariants?.count ?? 0) else { throw OpenCodeConfiguration.invalid() }
            try wire.validate()
            for variant in model.openCodeVariants ?? [] { try OpenCodeConfiguration.identifier(variant) }
            openCodeConfiguration = native.selecting(model: wire)
        } else { openCodeConfiguration = native.selecting(model: nil) }
        self.model = openCodeConfiguration?.model?.catalogID ?? ""
    }
    mutating func selectOpenCodeVariant(model: ProviderModel, variant: String?) throws {
        guard provider == .opencode, let native = openCodeConfiguration, let selected = native.model,
              let wire = model.openCodeSelection, wire.variant == nil,
              wire.providerID == selected.providerID, wire.id == selected.id,
              model.id == selected.catalogID, variant == nil || model.openCodeVariants?.contains(variant!) == true else {
            throw WorkspaceCommandError("This variant is not advertised for the selected OpenCode model. Refresh models and try again.")
        }
        let choice = OpenCodeModelSelection(providerID: selected.providerID, id: selected.id, variant: variant)
        try choice.validate(); openCodeConfiguration = native.selecting(model: choice)
    }
}
