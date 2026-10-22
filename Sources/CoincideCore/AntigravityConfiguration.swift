import Foundation

public enum AntigravityRuntimeSelection: String, Codable, CaseIterable, Sendable, Identifiable {
    case managed, external
    public var id: Self { self }
    public var name: String { self == .managed ? "Managed by Coincide" : "Custom installation" }
}

public enum AntigravityAuthMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case oauthPersonal = "oauth-personal", oauthBusiness = "oauth-business"
    case geminiAPIKey = "gemini-api-key", agentPlatform = "agent-platform"
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .oauthPersonal: "Google account"
        case .oauthBusiness: "Gemini Enterprise"
        case .geminiAPIKey: "Gemini API key"
        case .agentPlatform: "Agent Platform"
        }
    }
    public var usesBrowser: Bool { self == .oauthPersonal || self == .oauthBusiness }
}

/// Captured configuration contains no credential or authorization URL. A fresh
/// generation stages explicit account changes apart from an existing profile.
public struct AntigravityConfiguration: Codable, Sendable, Equatable, Hashable {
    public static let defaultInstanceID = UUID(uuidString: "7E1D4B73-FF1A-46C6-9CF8-2FD183DBBE3D")!
    public static let initialAuthGeneration = UUID(uuidString: "D4069014-BAAE-4989-8D1C-152F29596C6C")!
    public let instanceID: UUID
    public let runtimeSelection: AntigravityRuntimeSelection
    public let executable: String
    public let harnessPath: String?
    public let authMethod: AntigravityAuthMethod
    public let gcpProject: String?
    public let gcpLocation: String?
    public let authGeneration: UUID
    public let model: String?

    public init(instanceID: UUID = Self.defaultInstanceID, runtimeSelection: AntigravityRuntimeSelection = .external, executable: String = "agy_acp_server.par",
                harnessPath: String? = nil, authMethod: AntigravityAuthMethod = .oauthPersonal,
                gcpProject: String? = nil, gcpLocation: String? = nil,
                authGeneration: UUID = Self.initialAuthGeneration, model: String? = nil) {
        self.instanceID = instanceID; self.runtimeSelection = runtimeSelection; self.executable = executable; self.harnessPath = harnessPath
        self.authMethod = authMethod; self.gcpProject = gcpProject; self.gcpLocation = gcpLocation
        self.authGeneration = authGeneration; self.model = model
    }
    public var runtimeIdentity: AntigravityRuntimeIdentity {
        .init(instanceID: instanceID, runtimeSelection: runtimeSelection, executable: executable, harnessPath: harnessPath, authMethod: authMethod,
              gcpProject: gcpProject, gcpLocation: gcpLocation, authGeneration: authGeneration)
    }
    public func selecting(model: String?) -> Self {
        .init(instanceID: instanceID, runtimeSelection: runtimeSelection, executable: executable, harnessPath: harnessPath, authMethod: authMethod,
              gcpProject: gcpProject, gcpLocation: gcpLocation, authGeneration: authGeneration, model: model)
    }
    public func validate() throws {
        if runtimeSelection == .managed {
            guard executable == "agy_acp_server.par", harnessPath == nil else { throw Self.invalid() }
        }
        try Self.invocation(executable)
        if let harnessPath { try Self.invocation(harnessPath) }
        if let model { try Self.identifier(model, maximum: 4_096) }
        for value in [gcpProject, gcpLocation].compactMap({ $0 }) {
            try Self.identifier(value, maximum: 256)
            guard value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0) }) else { throw Self.invalid() }
        }
        if authMethod == .oauthBusiness { guard gcpProject != nil, gcpLocation != nil else { throw Self.invalid() } }
        if (gcpProject == nil) != (gcpLocation == nil) { throw Self.invalid() }
    }
    static func identifier(_ value: String, maximum: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw invalid() }
    }
    private static func invocation(_ value: String) throws {
        try identifier(value, maximum: 16_384)
        guard !value.contains("://"), !value.contains("="), value.hasPrefix("/") || !value.contains("/") else { throw invalid() }
        if value.hasPrefix("/") {
            guard URL(fileURLWithPath: value).standardizedFileURL.path == value else { throw invalid() }
        } else { guard !value.contains(where: \.isWhitespace), value != ".", value != ".." else { throw invalid() } }
    }
    public static func invalid() -> CoincideError {
        .init("The Antigravity configuration is invalid. Check its runtime, account method and selected model.")
    }
    private enum CodingKeys: String, CodingKey { case instanceID, runtimeSelection, executable, harnessPath, authMethod, gcpProject, gcpLocation, authGeneration, model }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(instanceID: try values.decode(UUID.self, forKey: .instanceID), runtimeSelection: try values.decodeIfPresent(AntigravityRuntimeSelection.self, forKey: .runtimeSelection) ?? .external,
                  executable: try values.decode(String.self, forKey: .executable),
                  harnessPath: try values.decodeIfPresent(String.self, forKey: .harnessPath), authMethod: try values.decode(AntigravityAuthMethod.self, forKey: .authMethod),
                  gcpProject: try values.decodeIfPresent(String.self, forKey: .gcpProject), gcpLocation: try values.decodeIfPresent(String.self, forKey: .gcpLocation),
                  authGeneration: try values.decode(UUID.self, forKey: .authGeneration), model: try values.decodeIfPresent(String.self, forKey: .model))
        try validate()
    }
}

public struct AntigravityRuntimeIdentity: Sendable, Equatable, Hashable {
    public let instanceID: UUID
    public let runtimeSelection: AntigravityRuntimeSelection
    public let executable: String
    public let harnessPath: String?
    public let authMethod: AntigravityAuthMethod
    public let gcpProject: String?
    public let gcpLocation: String?
    public let authGeneration: UUID
}
public struct AntigravityRuntimeBinding: Sendable, Equatable {
    public let identity: AntigravityRuntimeIdentity
    public let permission: PermissionMode
}

extension ProviderConfiguration {
    public var antigravityRuntimeBinding: AntigravityRuntimeBinding? {
        guard provider == .antigravity, let native = antigravityConfiguration else { return nil }
        return .init(identity: native.runtimeIdentity, permission: permission)
    }
}
enum AntigravityConfigurationValidation {
    static func configuration(_ value: ProviderConfiguration) throws {
        if value.provider == .antigravity {
            guard let native = value.antigravityConfiguration, value.model == (native.model ?? "") else { throw AntigravityConfiguration.invalid() }
            try native.validate()
            if let id = value.nativeThreadID { try AntigravityConfiguration.identifier(id, maximum: 4_096) }
        } else if value.antigravityConfiguration != nil { throw AntigravityConfiguration.invalid() }
    }
}
extension CodingThread {
    mutating func selectAntigravityModel(_ model: String?) throws {
        guard provider == .antigravity, let native = antigravityConfiguration else { throw AntigravityConfiguration.invalid() }
        let changed = native.selecting(model: model); try changed.validate()
        antigravityConfiguration = changed; self.model = model ?? ""
    }
}

extension PermissionMode {
    public var antigravityTitle: String {
        switch self {
        case .supervised: "Ask"
        case .auto: "Auto"
        case .autoAcceptEdits: "Auto-accept edits"
        case .fullAccess: "Always approve"
        }
    }
}
