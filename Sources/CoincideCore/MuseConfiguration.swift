import CryptoKit
import Foundation

/// Captured native MSP choices. Credentials and runtime protocol state do not
/// belong in workspace persistence.
public struct MuseConfiguration: Codable, Sendable, Equatable, Hashable {
    public let instanceID: UUID
    public let executable: String
    public let model: MuseModelSelection?
    public let reasoningEffort: String?
    public init(instanceID: UUID = UUID(), executable: String = "muse", model: MuseModelSelection? = nil, reasoningEffort: String? = nil) {
        self.instanceID = instanceID; self.executable = executable; self.model = model; self.reasoningEffort = reasoningEffort
    }
    public var runtimeIdentity: MuseRuntimeIdentity { .init(instanceID: instanceID, executable: executable) }
    public static let reasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
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
        if let reasoningEffort { guard Self.reasoningEfforts.contains(reasoningEffort) else { throw Self.invalid() } }
    }
    public func selecting(model: MuseModelSelection?, reasoningEffort: String? = nil) -> Self {
        .init(instanceID: instanceID, executable: executable, model: model, reasoningEffort: reasoningEffort)
    }
    public func selecting(reasoningEffort: String?) -> Self {
        .init(instanceID: instanceID, executable: executable, model: model, reasoningEffort: reasoningEffort)
    }
    static func identifier(_ value: String, maximum: Int = 4_096) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw invalid() }
    }
    static func invalid() -> CoincideError { .init("The Muse configuration is invalid. Refresh models and choose again.") }
    private enum CodingKeys: String, CodingKey { case instanceID, executable, model, reasoningEffort }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(instanceID: try values.decode(UUID.self, forKey: .instanceID), executable: try values.decode(String.self, forKey: .executable),
            model: try values.decodeIfPresent(MuseModelSelection.self, forKey: .model), reasoningEffort: try values.decodeIfPresent(String.self, forKey: .reasoningEffort))
        try validate()
    }
}

public struct MuseModelSelection: Codable, Sendable, Equatable, Hashable {
    public let providerID: String
    public let modelID: String
    public init(providerID: String = "meta", modelID: String) { self.providerID = providerID; self.modelID = modelID }
    public var catalogID: String {
        let data = (try? JSONEncoder().encode([providerID, modelID])) ?? Data()
        return "muse-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func validate() throws {
        guard providerID == "meta" else { throw MuseConfiguration.invalid() }
        try MuseConfiguration.identifier(modelID)
    }
    private enum CodingKeys: String, CodingKey { case providerID, modelID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(providerID: try values.decode(String.self, forKey: .providerID), modelID: try values.decode(String.self, forKey: .modelID))
        try validate()
    }
}

public struct MuseRuntimeIdentity: Sendable, Equatable, Hashable {
    public let instanceID: UUID
    public let executable: String
}
public struct MuseRuntimeBinding: Sendable, Equatable {
    public let identity: MuseRuntimeIdentity
    public let permission: PermissionMode
}
extension ProviderConfiguration {
    public var museRuntimeBinding: MuseRuntimeBinding? {
        guard provider == .muse, let native = museConfiguration else { return nil }
        return .init(identity: native.runtimeIdentity, permission: permission)
    }
}
enum MuseConfigurationValidation {
    static func configuration(_ value: ProviderConfiguration) throws {
        if value.provider == .muse {
            guard let native = value.museConfiguration, value.model == (native.model?.catalogID ?? ""),
                  value.permission == .supervised || value.permission == .fullAccess else { throw MuseConfiguration.invalid() }
            try native.validate()
            if let id = value.nativeThreadID { guard UUID(uuidString: id) != nil else { throw MuseConfiguration.invalid() } }
        } else if value.museConfiguration != nil { throw MuseConfiguration.invalid() }
    }
}
extension CodingThread {
    mutating func selectMuseModel(_ row: ProviderModel?) throws {
        guard provider == .muse, let native = museConfiguration else { throw MuseConfiguration.invalid() }
        if let row {
            guard let selected = row.museSelection, row.id == selected.catalogID else { throw MuseConfiguration.invalid() }
            try selected.validate(); try Self.validateMuseReasoning(row)
            let retained = native.reasoningEffort.flatMap { effort in row.reasoningEfforts.contains(where: { $0.id == effort }) ? effort : nil }
            museConfiguration = native.selecting(model: selected, reasoningEffort: retained)
        } else { museConfiguration = native.selecting(model: nil) }
        model = museConfiguration?.model?.catalogID ?? ""
    }
    mutating func selectMuseReasoning(model row: ProviderModel, effort: String?) throws {
        guard provider == .muse, let native = museConfiguration, native.model == row.museSelection,
              model == row.id, effort == nil || row.reasoningEfforts.contains(where: { $0.id == effort }) else { throw MuseConfiguration.invalid() }
        try Self.validateMuseReasoning(row)
        museConfiguration = native.selecting(reasoningEffort: effort)
    }
    private static func validateMuseReasoning(_ row: ProviderModel) throws {
        let efforts = row.reasoningEfforts
        guard efforts.count <= MuseConfiguration.reasoningEfforts.count, Set(efforts.map(\.id)).count == efforts.count,
              efforts.allSatisfy({ MuseConfiguration.reasoningEfforts.contains($0.id) }),
              row.defaultReasoningEffort.map({ value in efforts.contains { $0.id == value } }) ?? true,
              row.museReasoningEfforts.map({ $0 == efforts }) ?? true,
              row.museDefaultReasoningEffort.map({ value in efforts.contains { $0.id == value } }) ?? true else { throw MuseConfiguration.invalid() }
    }
}

extension PermissionMode {
    public var museTitle: String {
        switch self { case .supervised: "Ask"; case .fullAccess: "Always approve"; default: "Unavailable Muse permissions" }
    }
}
