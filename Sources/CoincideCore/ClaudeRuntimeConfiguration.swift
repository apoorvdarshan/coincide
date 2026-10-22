import Darwin
import Foundation

public enum ClaudePrecompactProfile: String, Codable, Sendable, Hashable { case defaultSkipping }

/// Environment presence and raw spelling are part of Claude's credential
/// namespace even when both choices resolve to the same transcript directory.
public enum ClaudeConfigurationDirectorySelection: Codable, Sendable, Hashable {
    case defaultHome(homeDirectory: String)
    case explicitDirectory(environmentPath: String)

    public func validate() throws {
        let path: String
        switch self { case .defaultHome(let value), .explicitDirectory(let value): path = value }
        try ProviderHistoryValidation.path(path)
        guard !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ClaudeRuntimeConfiguration.invalid() }
    }
    var isExplicit: Bool { if case .explicitDirectory = self { true } else { false } }
}

/// A captured launcher and native transcript namespace. Contains no credentials.
/// The optional project name is ONLY the explicit native override, not an auto key.
public struct ClaudeRuntimeConfiguration: Codable, Sendable, Equatable, Hashable {
    public static let defaultInstanceID = UUID(uuidString: "8A119C3F-80A5-4E7A-8C18-78B6235AF25D")!
    public let instanceID: UUID
    public let executable: String
    public let configurationDirectory: String
    public let projectDirectoryName: String?
    public let workspacePath: String
    public let registeredWorkspacePath: String
    public let precompactProfile: ClaudePrecompactProfile
    public let configurationDirectorySelection: ClaudeConfigurationDirectorySelection
    public init(instanceID: UUID = Self.defaultInstanceID, executable: String, configurationDirectory: String,
                projectDirectoryName: String? = nil, workspacePath: String, registeredWorkspacePath: String? = nil,
                precompactProfile: ClaudePrecompactProfile = .defaultSkipping,
                configurationDirectorySelection: ClaudeConfigurationDirectorySelection? = nil) {
        self.instanceID = instanceID; self.executable = executable; self.configurationDirectory = configurationDirectory
        self.projectDirectoryName = projectDirectoryName; self.workspacePath = workspacePath
        self.registeredWorkspacePath = registeredWorkspacePath ?? workspacePath; self.precompactProfile = precompactProfile
        self.configurationDirectorySelection = configurationDirectorySelection ?? .explicitDirectory(environmentPath: configurationDirectory)
    }
    public var projectKey: String { projectDirectoryName ?? ClaudeRuntimeValidation.projectKey(workspacePath) }
    public var projectDirectoryNames: [String] {
        let legacy = ClaudeRuntimeValidation.projectKey(workspacePath)
        return projectKey == legacy ? [legacy] : [projectKey, legacy]
    }
    public var runtimeIdentity: ClaudeRuntimeIdentity { .init(configuration: self) }
    public func replacingWorkspace(_ path: String, physicalPath: String? = nil) throws -> Self {
        let result = Self(instanceID: instanceID, executable: executable, configurationDirectory: configurationDirectory,
            projectDirectoryName: projectDirectoryName, workspacePath: (physicalPath ?? path).precomposedStringWithCanonicalMapping,
            registeredWorkspacePath: path,
            precompactProfile: precompactProfile, configurationDirectorySelection: configurationDirectorySelection)
        try result.validate(); return result
    }
    public func validate() throws {
        try ClaudeRuntimeValidation.path(executable); try ClaudeRuntimeValidation.path(configurationDirectory)
        try ClaudeRuntimeValidation.path(workspacePath)
        try ProviderHistoryValidation.path(registeredWorkspacePath)
        try configurationDirectorySelection.validate()
        guard configurationDirectory == configurationDirectory.precomposedStringWithCanonicalMapping,
              workspacePath == workspacePath.precomposedStringWithCanonicalMapping else { throw Self.invalid() }
        if let projectDirectoryName {
            guard configurationDirectorySelection.isExplicit else { throw Self.invalid() }
            try ClaudeRuntimeValidation.override(projectDirectoryName)
        }
    }
    /// Read-only admission capture. No process, auth check or directory creation.
    /// New queues must receive this value before acceptance, never resolve PATH later.
    public static func capture(workspacePath: String, executable: String = "claude", configurationDirectory: String? = nil,
                               projectDirectoryName: String? = nil,
                               environment: [String: String] = ProcessChannel.environment()) throws -> Self {
        guard environment["CLAUDE_CODE_DISABLE_PRECOMPACT_SKIP"].map({ $0.isEmpty }) ?? true else { throw invalid() }
        guard let selected = ProcessChannel.findExecutable(executable) else { throw CoincideError("The selected Claude executable is unavailable.") }
        let directorySelection: ClaudeConfigurationDirectorySelection
        if let root = configurationDirectory ?? environment["CLAUDE_CONFIG_DIR"] {
            directorySelection = .explicitDirectory(environmentPath: root)
        } else { directorySelection = .defaultHome(homeDirectory: environment["HOME"] ?? NSHomeDirectory()) }
        if !directorySelection.isExplicit, projectDirectoryName != nil { throw invalid() }
        let physicalRoot = try ClaudeRuntimeValidation.configurationDirectory(directorySelection)
        let physicalWorkspace = try ClaudeRuntimeValidation.physical(workspacePath, allowMissing: false)
        let explicit = directorySelection.isExplicit ? projectDirectoryName ?? environment["CLAUDE_CODE_PROJECT_DIR_NAME"] : nil
        let result = Self(executable: selected.path, configurationDirectory: physicalRoot, projectDirectoryName: explicit,
                          workspacePath: physicalWorkspace, registeredWorkspacePath: workspacePath,
                          configurationDirectorySelection: directorySelection)
        try result.validate(); return result
    }
    public static func invalid() -> CoincideError {
        .init("The Claude runtime capture is invalid or uses an unsupported transcript profile. Choose the executable, workspace and Claude configuration again.")
    }
    private enum CodingKeys: String, CodingKey { case instanceID, executable, configurationDirectory, projectDirectoryName, workspacePath, registeredWorkspacePath, precompactProfile, configurationDirectorySelection }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(instanceID: try c.decode(UUID.self, forKey: .instanceID), executable: try c.decode(String.self, forKey: .executable),
            configurationDirectory: try c.decode(String.self, forKey: .configurationDirectory),
            projectDirectoryName: try c.decodeIfPresent(String.self, forKey: .projectDirectoryName),
            workspacePath: try c.decode(String.self, forKey: .workspacePath),
            registeredWorkspacePath: try c.decodeIfPresent(String.self, forKey: .registeredWorkspacePath),
            precompactProfile: try c.decode(ClaudePrecompactProfile.self, forKey: .precompactProfile),
            configurationDirectorySelection: try c.decodeIfPresent(ClaudeConfigurationDirectorySelection.self, forKey: .configurationDirectorySelection))
        try validate()
    }
}

extension ProviderConfiguration {
    public func validateClaudeConfiguration() throws {
        guard provider == .claude else {
            guard claudeRuntimeConfiguration == nil, claudeLaunchSelection == nil else { throw ClaudeRuntimeConfiguration.invalid() }
            return
        }
        if let runtime = claudeRuntimeConfiguration {
            try runtime.validate()
            guard runtime.registeredWorkspacePath == workspacePath else { throw ClaudeRuntimeConfiguration.invalid() }
            try claudeLaunchSelection?.validate(runtime: runtime)
        } else if claudeLaunchSelection != nil { throw ClaudeRuntimeConfiguration.invalid() }
    }
}

public struct ClaudeRuntimeIdentity: Codable, Sendable, Equatable, Hashable {
    public let instanceID: UUID
    public let executable: String
    public let configurationDirectory: String
    public let projectDirectoryName: String?
    public let workspacePath: String
    public let registeredWorkspacePath: String
    public let precompactProfile: ClaudePrecompactProfile
    public let configurationDirectorySelection: ClaudeConfigurationDirectorySelection
    public init(configuration: ClaudeRuntimeConfiguration) {
        instanceID = configuration.instanceID; executable = configuration.executable
        configurationDirectory = configuration.configurationDirectory; projectDirectoryName = configuration.projectDirectoryName
        workspacePath = configuration.workspacePath; registeredWorkspacePath = configuration.registeredWorkspacePath
        precompactProfile = configuration.precompactProfile
        configurationDirectorySelection = configuration.configurationDirectorySelection
    }
    public var projectKey: String { projectDirectoryName ?? ClaudeRuntimeValidation.projectKey(workspacePath) }
    public var projectDirectoryNames: [String] {
        let legacy = ClaudeRuntimeValidation.projectKey(workspacePath)
        return projectKey == legacy ? [legacy] : [projectKey, legacy]
    }
    public func validate() throws {
        try ClaudeRuntimeConfiguration(instanceID: instanceID, executable: executable, configurationDirectory: configurationDirectory,
            projectDirectoryName: projectDirectoryName, workspacePath: workspacePath,
            registeredWorkspacePath: registeredWorkspacePath, precompactProfile: precompactProfile,
            configurationDirectorySelection: configurationDirectorySelection).validate()
    }
    private enum CodingKeys: String, CodingKey { case instanceID, executable, configurationDirectory, projectDirectoryName, workspacePath, registeredWorkspacePath, precompactProfile, configurationDirectorySelection }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let configuration = ClaudeRuntimeConfiguration(instanceID: try c.decode(UUID.self, forKey: .instanceID),
            executable: try c.decode(String.self, forKey: .executable), configurationDirectory: try c.decode(String.self, forKey: .configurationDirectory),
            projectDirectoryName: try c.decodeIfPresent(String.self, forKey: .projectDirectoryName), workspacePath: try c.decode(String.self, forKey: .workspacePath),
            registeredWorkspacePath: try c.decodeIfPresent(String.self, forKey: .registeredWorkspacePath),
            precompactProfile: try c.decode(ClaudePrecompactProfile.self, forKey: .precompactProfile),
            configurationDirectorySelection: try c.decodeIfPresent(ClaudeConfigurationDirectorySelection.self, forKey: .configurationDirectorySelection))
        try configuration.validate(); self.init(configuration: configuration)
    }
}

public struct ClaudeResumeSelection: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case resumeAt, freshSession }
    public let id: UUID
    public let nativeSessionID: String
    public let cursor: String?
    public let discardedInputID: String?
    public let kind: Kind
    public let reviewedLocation: ClaudeTranscriptLocation?
    public let reviewedRevision: ClaudeTranscriptRevision?
    public init(id: UUID = UUID(), nativeSessionID: String, cursor: String? = nil, discardedInputID: String? = nil,
                kind: Kind, reviewedLocation: ClaudeTranscriptLocation? = nil, reviewedRevision: ClaudeTranscriptRevision? = nil) throws {
        self.id = id; self.nativeSessionID = nativeSessionID; self.cursor = cursor; self.discardedInputID = discardedInputID
        self.kind = kind; self.reviewedLocation = reviewedLocation; self.reviewedRevision = reviewedRevision
        try validate()
    }
    public func validate() throws {
        try ClaudeRuntimeValidation.uuid(nativeSessionID)
        if let cursor { try ClaudeRuntimeValidation.uuid(cursor) }
        if let discardedInputID { try ClaudeRuntimeValidation.uuid(discardedInputID) }
        switch kind {
        case .resumeAt:
            guard cursor != nil, let reviewedLocation, let reviewedRevision,
                  UUID(uuidString: reviewedLocation.sessionID) == UUID(uuidString: nativeSessionID) else { throw ClaudeRuntimeConfiguration.invalid() }
            try reviewedLocation.validate(); try reviewedRevision.validate()
        case .freshSession:
            guard cursor == nil, discardedInputID == nil, reviewedLocation == nil, reviewedRevision == nil else { throw ClaudeRuntimeConfiguration.invalid() }
        }
    }
    public func validate(runtime: ClaudeRuntimeConfiguration) throws {
        try validate(); try runtime.validate()
        if let reviewedLocation {
            guard reviewedLocation.configurationDirectory == runtime.configurationDirectory,
                  reviewedLocation.workspacePath == runtime.workspacePath,
                  runtime.projectDirectoryNames.contains(reviewedLocation.projectDirectoryName) else { throw ClaudeRuntimeConfiguration.invalid() }
        }
    }
}

public struct ClaudeInheritedHead: Codable, Sendable, Equatable {
    public let runtimeIdentity: ClaudeRuntimeIdentity
    public let nativeSessionID: String
    public let cursor: String
    public init(runtimeIdentity: ClaudeRuntimeIdentity, nativeSessionID: String, cursor: String) throws {
        self.runtimeIdentity = runtimeIdentity; self.nativeSessionID = nativeSessionID; self.cursor = cursor
        try validate()
    }
    public func validate() throws {
        try runtimeIdentity.validate(); try ClaudeRuntimeValidation.uuid(nativeSessionID); try ClaudeRuntimeValidation.uuid(cursor)
    }
}

enum ClaudeRuntimeValidation {
    static func configurationDirectory(_ selection: ClaudeConfigurationDirectorySelection) throws -> String {
        try selection.validate()
        let raw: String
        switch selection {
        case .defaultHome(let home): raw = home + (home.hasSuffix("/") ? "" : "/") + ".claude"
        case .explicitDirectory(let path): raw = path
        }
        // Only separator normalization is used for physical identity. The raw
        // captured string is retained separately and restored to the child env.
        let normalized = "/" + raw.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        return try physical(normalized, allowMissing: true)
    }
    static func uuid(_ value: String) throws {
        guard value.utf8.count == 36, UUID(uuidString: value) != nil else { throw ClaudeRuntimeConfiguration.invalid() }
    }
    static func path(_ value: String) throws {
        guard value.hasPrefix("/"), value != "/", value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw ClaudeRuntimeConfiguration.invalid() }
    }
    static func override(_ value: String) throws {
        let reserved = ["con", "prn", "aux", "nul"] + (0...9).flatMap { ["com\($0)", "lpt\($0)"] }
        guard (1...64).contains(value.utf8.count), !reserved.contains(value.lowercased()),
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw ClaudeRuntimeConfiguration.invalid() }
    }
    static func projectKey(_ path: String) -> String {
        let units = Array(path.precomposedStringWithCanonicalMapping.utf16)
        let sanitized = String(decoding: units.map { value -> UInt8 in
            value < 128 && ((48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)) ? UInt8(value) : 45
        }, as: UTF8.self)
        guard sanitized.count > 200 else { return sanitized }
        var hash: Int32 = 0; for unit in units { hash = hash &* 31 &+ Int32(unit) }
        return String(sanitized.prefix(200)) + "-" + String(abs(Int64(hash)), radix: 36)
    }
    static func physical(_ value: String, allowMissing: Bool) throws -> String {
        try path(value)
        var existing = value, missing: [String] = []
        while true {
            if let pointer = existing.withCString({ realpath($0, nil) }) {
                let resolved = String(cString: pointer); free(pointer)
                var info = stat()
                guard resolved.withCString({ stat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ClaudeRuntimeConfiguration.invalid() }
                let result = missing.reversed().reduce(resolved) { URL(fileURLWithPath: $0).appendingPathComponent($1).path }.precomposedStringWithCanonicalMapping
                try path(result); return result
            }
            guard allowMissing, errno == ENOENT, existing != "/" else { throw ClaudeRuntimeConfiguration.invalid() }
            let url = URL(fileURLWithPath: existing); missing.append(url.lastPathComponent); existing = url.deletingLastPathComponent().path
        }
    }
}
