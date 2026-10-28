import Foundation

/// An ACP agent the user added (T3 Code's `acpRegistry` provider instance): a local command, or an agent installed
/// from the official ACP Registry. It runs as `ProviderKind.acp(id)`. What every provider has (on or off, a custom
/// executable path, custom models, environment variables) stays in `AppSettings.providers` under that kind, so the
/// provider page treats it like any other agent.
public struct ACPAgentConfig: Codable, Hashable, Sendable, Identifiable {
    /// T3 Code's `source` setting.
    public enum Source: String, Codable, Sendable {
        case registry
        case local
    }

    /// The stable instance ID (`isValidID`). Threads keep it in their model selection, so it never changes.
    public var id: String
    public var name: String
    public var source: Source
    /// Local commands: the executable's name on PATH, or its absolute path.
    public var command: String
    /// Local commands: arguments passed exactly as written, without a shell (T3 Code's `commandArgs`).
    public var arguments: [String]
    /// Registry agents: what was installed and how it starts.
    public var registry: ACPRegistryInstall?
    /// The sign-in method a session uses when the agent asks for one (T3 Code's `authMethodId`). Nil picks the first
    /// method the agent completes by itself.
    public var authMethodID: String?

    public nonisolated init(
        id: String, name: String, source: Source, command: String = "", arguments: [String] = [],
        registry: ACPRegistryInstall? = nil, authMethodID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.command = command
        self.arguments = arguments
        self.registry = registry
        self.authMethodID = authMethodID
    }

    /// Only a valid id is required; anything else this version cannot read falls back to a default.
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard Self.isValidID(id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Invalid agent id")
        }
        self.id = id
        name = container.lenient(String.self, forKey: .name) ?? id
        registry = container.lenient(ACPRegistryInstall.self, forKey: .registry)
        source = container.lenient(Source.self, forKey: .source) ?? (registry == nil ? .local : .registry)
        command = container.lenient(String.self, forKey: .command) ?? ""
        arguments = container.lenient([String].self, forKey: .arguments) ?? []
        authMethodID = container.lenient(String.self, forKey: .authMethodID).flatMap(ACPAgentConfig.nonEmpty)
    }

    public nonisolated var kind: ProviderKind { .acp(id) }

    /// The name shown everywhere, or the id when the name is blank.
    public nonisolated var displayName: String { Self.nonEmpty(name) ?? id }

    /// The arguments the agent's executable starts with.
    public nonisolated var launchArguments: [String] {
        switch source {
        case .local: arguments
        case .registry: registry?.arguments ?? []
        }
    }

    /// A local command's executable: a name looked up on PATH, or an absolute path. A relative path would depend on
    /// the thread's folder.
    public nonisolated static func isValidCommand(_ command: String) -> Bool {
        !command.isEmpty && !command.contains("\0") && (command.hasPrefix("/") || command.hasPrefix("~") || !command.contains("/"))
    }

    // MARK: Instance IDs

    /// See `ProviderKind.isValidACPAgentID`.
    public nonisolated static func isValidID(_ id: String) -> Bool { ProviderKind.isValidACPAgentID(id) }

    /// Names a new agent's id must not take: the built-in agents' and the composer's own commands, so `/<id>` always
    /// means this agent.
    nonisolated static let reservedIDs: Set<String> =
        Set(ProviderKind.allCases.map(\.rawValue)).union(["model", "plan", "build", "default", "usage-limits"])

    /// A new instance ID from `base` (a registry agent's id or a name the user typed), unique among `existing`, as T3
    /// Code derives instance IDs: the slug, then `-2`, `-3`… when it is taken.
    public nonisolated static func makeID(from base: String, existing: Set<String>) -> String {
        var slug = ""
        for character in base.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber || character == "." || character == "_" {
                slug.append(character)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while let first = slug.first, !(first.isLetter || first.isNumber) { slug.removeFirst() }
        while slug.hasSuffix("-") || slug.hasSuffix(".") { slug.removeLast() }
        slug = String(slug.prefix(56))
        if slug.isEmpty { slug = "agent" }
        let taken = existing.union(reservedIDs)
        guard taken.contains(slug) else { return slug }
        var suffix = 2
        while taken.contains("\(slug)-\(suffix)") { suffix += 1 }
        return "\(slug)-\(suffix)"
    }

    nonisolated static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// What Coincide installed for a registry agent and how it starts, written when the agent is installed. Sessions
/// launch from this record, so a later registry index never changes what runs until the user updates the agent.
public struct ACPRegistryInstall: Codable, Hashable, Sendable {
    public var agentID: String
    public var version: String
    public var distribution: ACPRegistryDistribution
    /// The executable, relative to the version's folder (`tools/acp/<agent>/<version>/`).
    public var executable: String
    public var arguments: [String]
    /// The registry's environment for the agent, applied over the provider's own (as T3 Code applies it).
    public var environment: [String: String]
    /// A folder, relative to the version's folder, put first on PATH (a package's `bin`).
    public var binDirectory: String?
    /// The archive's SHA-256, when the registry published one and the download matched it.
    public var sha256: String?
    public var website: URL?
    public var repository: URL?
    public var license: String?

    public nonisolated init(
        agentID: String, version: String, distribution: ACPRegistryDistribution, executable: String,
        arguments: [String] = [], environment: [String: String] = [:], binDirectory: String? = nil, sha256: String? = nil,
        website: URL? = nil, repository: URL? = nil, license: String? = nil
    ) {
        self.agentID = agentID
        self.version = version
        self.distribution = distribution
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.binDirectory = binDirectory
        self.sha256 = sha256
        self.website = website
        self.repository = repository
        self.license = license
    }

    /// The agent, version and executable are required, and must be what an install could have written; the links and
    /// license are optional.
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try container.decode(String.self, forKey: .agentID)
        version = try container.decode(String.self, forKey: .version)
        distribution = try container.decode(ACPRegistryDistribution.self, forKey: .distribution)
        executable = try container.decode(String.self, forKey: .executable)
        guard ACPRegistryIndex.isValidAgentID(agentID), ACPRegistryIndex.isValidVersion(version),
            ACPRegistryPaths.relativeComponents(executable) != nil
        else {
            throw DecodingError.dataCorruptedError(forKey: .executable, in: container, debugDescription: "Invalid install record")
        }
        arguments = container.lenient([String].self, forKey: .arguments) ?? []
        environment = container.lenient([String: String].self, forKey: .environment) ?? [:]
        binDirectory = container.lenient(String.self, forKey: .binDirectory).flatMap {
            ACPRegistryPaths.relativeComponents($0) == nil ? nil : $0
        }
        sha256 = container.lenient(String.self, forKey: .sha256)
        website = container.lenient(URL.self, forKey: .website)
        repository = container.lenient(URL.self, forKey: .repository)
        license = container.lenient(String.self, forKey: .license)
    }
}

extension ACPAgentNames {
    /// Adds the agents' names.
    public nonisolated func register(_ agents: [ACPAgentConfig]) {
        register(Dictionary(agents.map { ($0.id, $0.displayName) }, uniquingKeysWith: { _, last in last }))
    }
}
