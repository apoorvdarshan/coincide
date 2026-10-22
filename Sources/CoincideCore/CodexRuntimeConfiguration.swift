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

public enum CodexAuthenticationMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case cliDefault, ownedChatGPT
    public var id: Self { self }
    public var name: String {
        switch self {
        case .cliDefault: String(localized: "Existing CLI account")
        case .ownedChatGPT: String(localized: "ChatGPT account in Coincide")
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
    public let authenticationMode: CodexAuthenticationMode
    public let accountBinding: CodexAccountBinding?
    public init(instanceID: UUID = Self.defaultInstanceID, selection: CodexRuntimeSelection = .existingCLI,
                executable: String = "codex", homeDirectory: String? = nil,
                authenticationMode: CodexAuthenticationMode = .cliDefault, accountBinding: CodexAccountBinding? = nil) {
        self.instanceID = instanceID; self.selection = selection
        self.executable = executable; self.homeDirectory = homeDirectory
        self.authenticationMode = authenticationMode; self.accountBinding = accountBinding
    }
    public func validate() throws {
        guard selection == .custom || executable == "codex" else { throw Self.invalid() }
        try Self.text(executable)
        guard !executable.contains("://"), !executable.contains("="), executable.hasPrefix("/") || !executable.contains("/") else { throw Self.invalid() }
        if executable.hasPrefix("/") {
            try Self.absolutePath(executable)
        } else {
            guard !executable.contains(where: \.isWhitespace), executable != ".", executable != ".." else { throw Self.invalid() }
        }
        if let homeDirectory {
            try Self.text(homeDirectory)
            try Self.absolutePath(homeDirectory)
        }
        guard authenticationMode != .cliDefault || accountBinding == nil,
              authenticationMode != .ownedChatGPT || homeDirectory != nil else { throw Self.invalid() }
    }
    public func replacingAccountBinding(_ binding: CodexAccountBinding?) -> Self {
        .init(instanceID: instanceID, selection: selection, executable: executable, homeDirectory: homeDirectory,
              authenticationMode: authenticationMode, accountBinding: binding)
    }
    private static func absolutePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path != "/", components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw invalid() }
    }
    private static func text(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw invalid() }
    }
    public static func invalid() -> CoincideError {
        .init("The Codex runtime configuration is invalid. Choose a literal executable and an absolute Codex home when needed.")
    }
    private enum CodingKeys: String, CodingKey { case instanceID, selection, executable, homeDirectory, authenticationMode, accountBinding }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(instanceID: try fields.decodeIfPresent(UUID.self, forKey: .instanceID) ?? Self.defaultInstanceID,
                  selection: try fields.decodeIfPresent(CodexRuntimeSelection.self, forKey: .selection) ?? .existingCLI,
                  executable: try fields.decodeIfPresent(String.self, forKey: .executable) ?? "codex",
                  homeDirectory: try fields.decodeIfPresent(String.self, forKey: .homeDirectory),
                  authenticationMode: try fields.decodeIfPresent(CodexAuthenticationMode.self, forKey: .authenticationMode) ?? .cliDefault,
                  accountBinding: try fields.decodeIfPresent(CodexAccountBinding.self, forKey: .accountBinding))
        try validate()
    }
}

extension ProviderConfiguration {
    public var codexRuntimeBinding: CodexRuntimeConfiguration? {
        provider == .codex ? codexRuntimeConfiguration ?? CodexRuntimeConfiguration() : nil
    }
    var ownedCodexInstanceID: UUID? {
        guard let binding = codexRuntimeBinding, binding.authenticationMode == .ownedChatGPT else { return nil }
        return binding.instanceID
    }
}

extension CodingThread {
    var ownedCodexInstances: Set<UUID> {
        Set(([ProviderConfiguration(thread: self)] + [activeRun?.configuration].compactMap { $0 } + queuedTurns.map(\.configuration)).compactMap(\.ownedCodexInstanceID))
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
