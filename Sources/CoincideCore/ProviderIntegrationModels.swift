import CryptoKit
import Foundation

public enum ProviderIntegrationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case skills, commands, mcp, plugins, hooks
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .skills: "Skills"
        case .commands: "Commands"
        case .mcp: "MCP servers"
        case .plugins: "Plugins"
        case .hooks: "Hooks"
        }
    }
}

public enum ProviderIntegrationImportMode: String, Codable, Sendable {
    case copied, linked
    public var title: String { self == .copied ? "Independent copy" : "Uses original provider configuration" }
}

/// Display-only metadata. Executable arguments, hooks, environment values and
/// authentication headers are deliberately never part of this representation.
public struct ProviderIntegrationItem: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let provider: ProviderKind
    public let kind: ProviderIntegrationKind
    public let name: String
    /// Optional human-facing manifest label. The native name remains the stable
    /// provider key used by identity, configuration and invocation.
    public var displayName: String?
    public var title: String { displayName ?? name }
    public let summary: String
    public let sourcePath: String
    public let scope: String
    public let enabled: Bool
    public let invocation: String?
    public var importMode: ProviderIntegrationImportMode?
    public var libraryPath: String?
    public var available: Bool
    public var imported: Bool { importMode != nil }

    public init(provider: ProviderKind, kind: ProviderIntegrationKind, name: String, summary: String,
                sourcePath: String, scope: String, enabled: Bool = true, invocation: String? = nil,
                importMode: ProviderIntegrationImportMode? = nil, libraryPath: String? = nil, available: Bool = true,
                displayName: String? = nil) {
        self.id = Self.identity(provider: provider, kind: kind, name: name, sourcePath: sourcePath, scope: scope)
        self.provider = provider; self.kind = kind; self.name = name; self.summary = summary
        self.sourcePath = sourcePath; self.scope = scope; self.enabled = enabled; self.invocation = invocation
        self.importMode = importMode; self.libraryPath = libraryPath; self.available = available
        self.displayName = displayName
    }

    static func identity(provider: ProviderKind, kind: ProviderIntegrationKind, name: String, sourcePath: String, scope: String) -> String {
        let bytes = [provider.rawValue, kind.rawValue, name, sourcePath, scope].map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        guard provider.isSupported, id == Self.identity(provider: provider, kind: kind, name: name, sourcePath: sourcePath, scope: scope),
              sourcePath.hasPrefix("/"), name.utf8.count <= 512, !name.isEmpty, summary.utf8.count <= 16_384,
              scope.utf8.count <= 128, sourcePath.utf8.count <= 4_096,
              ![name, sourcePath, scope].contains(where: { $0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }),
              invocation.map({ $0.utf8.count <= 1_024 && !$0.contains("\0") }) ?? true else {
            throw CoincideError("Integration metadata is invalid. Refresh the provider source and try again.")
        }
        if let displayName {
            guard !displayName.isEmpty, displayName.utf8.count <= 512,
                  !displayName.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw CoincideError("The integration display name is invalid. Refresh its provider source.")
            }
        }
    }
}

public struct ProviderIntegrationIssue: Codable, Identifiable, Sendable, Equatable {
    public let provider: ProviderKind?
    public let sourcePath: String?
    public let message: String
    public var id: String { (provider?.rawValue ?? "library") + ":" + (sourcePath ?? "") + ":" + message }
    public init(provider: ProviderKind? = nil, sourcePath: String? = nil, message: String) {
        self.provider = provider; self.sourcePath = sourcePath; self.message = message
    }
}

public struct ProviderIntegrationScan: Codable, Sendable, Equatable {
    public var items: [ProviderIntegrationItem]
    public var issues: [ProviderIntegrationIssue]
    public let checkedAt: Date
    public init(items: [ProviderIntegrationItem], issues: [ProviderIntegrationIssue] = [], checkedAt: Date = .now) {
        self.items = items; self.issues = issues; self.checkedAt = checkedAt
    }
}

/// Discovery is read-only and does not start a CLI, hooks, MCP processes or a
/// model turn. Linked imports retain provider/runtime/credential inheritance:
/// selecting a different provider home does not migrate or activate them there.
public enum ProviderIntegrationCatalog {
    public static var defaultLibraryRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Coincide/Integrations", isDirectory: true)
    }
}
