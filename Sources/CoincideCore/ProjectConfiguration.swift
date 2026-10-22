import Foundation

public enum ProjectThreadEnvironmentMode: String, Codable, CaseIterable, Sendable { case local, worktree }
public enum ProjectWorktreeSubmoduleMode: String, Codable, CaseIterable, Sendable {
    case recursive, topLevel = "top-level", none
}

/// Checked-in T3 configuration, imported as data. Optional role/preview settings do not authorize execution.
public struct ProjectConfiguration: Codable, Sendable, Equatable {
    public let schemaURL: String?
    public let iconPath: String?
    public let defaultThreadEnvMode: ProjectThreadEnvironmentMode?
    public let worktreeSubmodules: ProjectWorktreeSubmoduleMode?
    public let scripts: [ProjectScript]

    public init(schemaURL: String? = nil, iconPath: String? = nil,
                defaultThreadEnvMode: ProjectThreadEnvironmentMode? = nil,
                worktreeSubmodules: ProjectWorktreeSubmoduleMode? = nil,
                scripts: [ProjectScript] = []) throws {
        self.schemaURL = schemaURL; self.iconPath = iconPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultThreadEnvMode = defaultThreadEnvMode; self.worktreeSubmodules = worktreeSubmodules; self.scripts = scripts
        try validate()
    }
    public func validate() throws {
        guard scripts.count <= 50,
              schemaURL.map({ $0.utf8.count <= ProjectConfigurationService.maximumBytes && !$0.contains("\0") }) ?? true,
              iconPath.map({ ProjectConfigurationValidation.nonempty($0) && $0.utf16.count <= 512 }) ?? true else {
            throw ProjectConfigurationError(.invalidConfiguration)
        }
        for script in scripts { try script.validate() }
    }
    /// JSON with line/block comments and trailing commas, matching the pinned T3 parser.
    /// Unknown fields are ignored; known fields retain strict types and reject explicit null.
    public static func parse(_ contents: String) throws -> Self {
        guard contents.utf8.count <= ProjectConfigurationService.maximumBytes else { throw ProjectConfigurationError(.tooLarge) }
        try Task.checkCancellation()
        let data = try ProjectConfigurationJSON.normalized(contents)
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ProjectConfigurationError(.invalidConfiguration) }
    }
    private enum CodingKeys: String, CodingKey {
        case schemaURL = "$schema", iconPath, defaultThreadEnvMode, worktreeSubmodules, scripts
    }
    public init(from decoder: any Decoder) throws {
        do {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(schemaURL: c.contains(.schemaURL) ? c.decode(String.self, forKey: .schemaURL) : nil,
                          iconPath: c.contains(.iconPath) ? c.decode(String.self, forKey: .iconPath) : nil,
                          defaultThreadEnvMode: c.contains(.defaultThreadEnvMode) ? c.decode(ProjectThreadEnvironmentMode.self, forKey: .defaultThreadEnvMode) : nil,
                          worktreeSubmodules: c.contains(.worktreeSubmodules) ? c.decode(ProjectWorktreeSubmoduleMode.self, forKey: .worktreeSubmodules) : nil,
                          scripts: c.contains(.scripts) ? c.decode([ProjectScript].self, forKey: .scripts) : [])
        } catch { throw ProjectConfigurationError(.invalidConfiguration) }
    }
}

public struct ProjectConfigurationDocument: Sendable, Equatable {
    public let configuration: ProjectConfiguration?
    public let revision: WorkspaceFileRevision?
    public let exists: Bool
    public let warning: String?
    public init(configuration: ProjectConfiguration?, revision: WorkspaceFileRevision?, exists: Bool, warning: String? = nil) {
        self.configuration = configuration; self.revision = revision; self.exists = exists; self.warning = warning
    }
}

public enum ProjectConfigurationService {
    public static let fileName = "t3.json"
    public static let maximumBytes = 262_144
    /// Missing/invalid files are ordinary discovery results. Cancellation and lost root/session
    /// ownership still throw so callers cannot mistake a retired workspace for an empty config.
    public static func load(using service: WorkspaceFileService) async throws -> ProjectConfigurationDocument {
        try Task.checkCancellation()
        let document: WorkspaceTextDocument
        do { document = try await service.readFile(relativePath: fileName, allowMissing: true, maxBytes: maximumBytes) }
        catch is CancellationError { throw CancellationError() }
        catch let error as WorkspaceFileError {
            try Task.checkCancellation()
            if [.closed, .rootMissing, .rootNotDirectory, .rootReplaced].contains(error.failure) { throw error }
            return .init(configuration: nil, revision: nil, exists: true, warning: "t3.json could not be read as a supported project configuration.")
        }
        try Task.checkCancellation()
        guard document.exists else { return .init(configuration: nil, revision: nil, exists: false) }
        guard !document.truncated, document.revision != nil else {
            return .init(configuration: nil, revision: nil, exists: true, warning: ProjectConfigurationError(.tooLarge).localizedDescription)
        }
        do {
            let configuration = try ProjectConfiguration.parse(document.contents)
            try Task.checkCancellation()
            return .init(configuration: configuration, revision: document.revision, exists: true)
        } catch is CancellationError { throw CancellationError() }
        catch { return .init(configuration: nil, revision: document.revision, exists: true, warning: ProjectConfigurationError(.invalidConfiguration).localizedDescription) }
    }
}

public struct ProjectConfigurationError: Error, LocalizedError, Sendable, Equatable {
    public enum Failure: String, Sendable, Equatable { case invalidConfiguration, tooLarge, invalidInvocation }
    public let failure: Failure
    public init(_ failure: Failure) { self.failure = failure }
    public var errorDescription: String? {
        switch failure {
        case .invalidConfiguration: "t3.json is not a supported project configuration. Check its field types and script declarations."
        case .tooLarge: "t3.json exceeds the 256 KB configuration limit."
        case .invalidInvocation: "Project scripts require local project and checkout folders."
        }
    }
}

enum ProjectConfigurationValidation {
    static func nonempty(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= ProjectConfigurationService.maximumBytes && !value.contains("\0")
    }
}
