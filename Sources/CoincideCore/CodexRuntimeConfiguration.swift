import Foundation

public enum CodexRuntimeSelection: String, Codable, CaseIterable, Sendable, Identifiable {
    case existingCLI, managed, custom
    public var id: Self { self }
    public var name: String {
        switch self {
        case .existingCLI: String(localized: "Installed CLI")
        case .managed: String(localized: "Managed by Coincide")
        case .custom: String(localized: "Custom executable")
        }
    }
}

/// A binary and home binding contains no credentials. An absent capture keeps
/// the existing CLI behavior; choosing a home does not migrate its contents.
public struct CodexRuntimeConfiguration: Codable, Sendable, Equatable, Hashable {
    public static let defaultInstanceID = UUID(uuidString: "246F9D3D-8651-4B80-B1F8-ADBA2CFDF622")!
    public let instanceID: UUID
    public let selection: CodexRuntimeSelection
    public let executable: String
    public let homeDirectory: String?
    public init(instanceID: UUID = Self.defaultInstanceID, selection: CodexRuntimeSelection = .existingCLI,
                executable: String = "codex", homeDirectory: String? = nil) {
        self.instanceID = instanceID; self.selection = selection
        self.executable = executable; self.homeDirectory = homeDirectory
    }
    public func validate() throws {
        guard selection == .custom || executable == "codex" else { throw Self.invalid() }
        try Self.text(executable)
        guard !executable.contains("://"), !executable.contains("="), executable.hasPrefix("/") || !executable.contains("/") else { throw Self.invalid() }
        if executable.hasPrefix("/") {
            guard URL(fileURLWithPath: executable).standardizedFileURL.path == executable else { throw Self.invalid() }
        } else {
            guard !executable.contains(where: \.isWhitespace), executable != ".", executable != ".." else { throw Self.invalid() }
        }
        if let homeDirectory {
            try Self.text(homeDirectory)
            guard homeDirectory.hasPrefix("/"), URL(fileURLWithPath: homeDirectory).standardizedFileURL.path == homeDirectory else { throw Self.invalid() }
        }
    }
    private static func text(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw invalid() }
    }
    public static func invalid() -> CoincideError {
        .init("The Codex runtime configuration is invalid. Choose a literal executable and an absolute Codex home when needed.")
    }
    private enum CodingKeys: String, CodingKey { case instanceID, selection, executable, homeDirectory }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(instanceID: try fields.decodeIfPresent(UUID.self, forKey: .instanceID) ?? Self.defaultInstanceID,
                  selection: try fields.decodeIfPresent(CodexRuntimeSelection.self, forKey: .selection) ?? .existingCLI,
                  executable: try fields.decodeIfPresent(String.self, forKey: .executable) ?? "codex",
                  homeDirectory: try fields.decodeIfPresent(String.self, forKey: .homeDirectory))
        try validate()
    }
}

extension ProviderConfiguration {
    public var codexRuntimeBinding: CodexRuntimeConfiguration? {
        provider == .codex ? codexRuntimeConfiguration ?? CodexRuntimeConfiguration() : nil
    }
}
enum CodexRuntimeConfigurationValidation {
    static func configuration(_ value: ProviderConfiguration) throws {
        if value.provider == .codex { try value.codexRuntimeConfiguration?.validate() }
        else if value.codexRuntimeConfiguration != nil { throw CodexRuntimeConfiguration.invalid() }
    }
}

enum CodexRuntimeEnvironment {
    static func make(configuration: CodexRuntimeConfiguration, base: [String: String]? = nil) throws -> [String: String] {
        try configuration.validate()
        var environment = base ?? ProcessChannel.environment()
        if let home = configuration.homeDirectory { environment["CODEX_HOME"] = home }
        return environment
    }
}
