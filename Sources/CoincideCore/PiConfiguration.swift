import CryptoKit
import Foundation

/// Durable Pi selections. Session files, credentials and extension paths are
/// managed by the live adapter rather than stored as launch arguments.
public struct PiConfiguration: Codable, Sendable, Equatable, Hashable {
    public let instanceID: UUID
    public let executable: String
    public let model: PiModelSelection?
    public let thinkingLevel: String?
    public init(instanceID: UUID = UUID(), executable: String = "pi", model: PiModelSelection? = nil, thinkingLevel: String? = nil) {
        self.instanceID = instanceID; self.executable = executable; self.model = model; self.thinkingLevel = thinkingLevel
    }
    public var runtimeIdentity: PiRuntimeIdentity { .init(instanceID: instanceID, executable: executable) }
    public static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    public func validate() throws {
        try Self.identifier(executable, maximum: 16_384)
        guard !executable.contains("://"), !executable.contains("="),
              executable.hasPrefix("/") || !executable.contains("/") else { throw Self.invalid() }
        if executable.hasPrefix("/") {
            guard URL(fileURLWithPath: executable).standardizedFileURL.path == executable else { throw Self.invalid() }
        } else {
            guard !executable.contains(where: \.isWhitespace), executable != ".", executable != ".." else { throw Self.invalid() }
        }
        try model?.validate()
        if let thinkingLevel { guard Self.thinkingLevels.contains(thinkingLevel) else { throw Self.invalid() } }
    }
    public func selecting(model: PiModelSelection?, thinkingLevel: String? = nil) -> Self {
        .init(instanceID: instanceID, executable: executable, model: model, thinkingLevel: thinkingLevel)
    }
    public func selecting(thinkingLevel: String?) -> Self {
        .init(instanceID: instanceID, executable: executable, model: model, thinkingLevel: thinkingLevel)
    }
    static func identifier(_ value: String, maximum: Int = 4_096) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw invalid() }
    }
    static func invalid() -> CoincideError { .init("The Pi configuration is invalid. Refresh its models and choose again.") }
    private enum CodingKeys: String, CodingKey { case instanceID, executable, model, thinkingLevel }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(instanceID: try values.decode(UUID.self, forKey: .instanceID), executable: try values.decode(String.self, forKey: .executable),
            model: try values.decodeIfPresent(PiModelSelection.self, forKey: .model), thinkingLevel: try values.decodeIfPresent(String.self, forKey: .thinkingLevel))
        try validate()
    }
}

public struct PiRuntimeIdentity: Sendable, Equatable, Hashable {
    public let instanceID: UUID
    public let executable: String
}

public struct PiRuntimeBinding: Sendable, Equatable {
    public let identity: PiRuntimeIdentity
    public let permission: PermissionMode
}

extension ProviderConfiguration {
    public var piRuntimeBinding: PiRuntimeBinding? {
        guard provider == .pi, let native = piConfiguration else { return nil }
        return .init(identity: native.runtimeIdentity, permission: permission)
    }
}

public struct PiModelSelection: Codable, Sendable, Equatable, Hashable {
    public let provider: String
    public let modelID: String
    public init(provider: String, modelID: String) { self.provider = provider; self.modelID = modelID }
    public var catalogID: String {
        let data = (try? JSONEncoder().encode([provider, modelID])) ?? Data()
        return "pi-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func validate() throws { try PiConfiguration.identifier(provider); try PiConfiguration.identifier(modelID) }
    private enum CodingKeys: String, CodingKey { case provider, modelID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(provider: try values.decode(String.self, forKey: .provider), modelID: try values.decode(String.self, forKey: .modelID))
        try validate()
    }
}

enum PiConfigurationValidation {
    static func configuration(_ value: ProviderConfiguration) throws {
        if value.provider == .pi {
            guard let native = value.piConfiguration, value.model == (native.model?.catalogID ?? "") else { throw PiConfiguration.invalid() }
            try native.validate()
            if let file = value.nativeThreadID { try ProviderHistoryValidation.path(file) }
        } else if value.piConfiguration != nil { throw PiConfiguration.invalid() }
    }
}

extension CodingThread {
    mutating func selectPiModel(_ row: ProviderModel?) throws {
        guard provider == .pi, let native = piConfiguration else { throw PiConfiguration.invalid() }
        if let row {
            guard let selected = row.piSelection, row.id == selected.catalogID else { throw PiConfiguration.invalid() }
            try selected.validate(); try Self.validatePiThinking(row)
            let retained = native.thinkingLevel.flatMap { row.piThinkingLevels?.contains($0) == true ? $0 : nil }
            piConfiguration = native.selecting(model: selected, thinkingLevel: retained)
        } else { piConfiguration = native.selecting(model: nil) }
        model = piConfiguration?.model?.catalogID ?? ""
    }
    mutating func selectPiThinking(model row: ProviderModel, level: String?) throws {
        guard provider == .pi, let native = piConfiguration, native.model == row.piSelection,
              model == row.id, level == nil || row.piThinkingLevels?.contains(level!) == true else { throw PiConfiguration.invalid() }
        try Self.validatePiThinking(row)
        piConfiguration = native.selecting(thinkingLevel: level)
    }
    private static func validatePiThinking(_ row: ProviderModel) throws {
        let levels = row.piThinkingLevels ?? []
        guard levels.count <= PiConfiguration.thinkingLevels.count, Set(levels).count == levels.count,
              levels.allSatisfy(PiConfiguration.thinkingLevels.contains) else { throw PiConfiguration.invalid() }
    }
}

extension PermissionMode {
    public var piTitle: String {
        switch self { case .supervised, .auto: "Ask"; case .autoAcceptEdits: "Approve edits"; case .fullAccess: "Always approve" }
    }
}
