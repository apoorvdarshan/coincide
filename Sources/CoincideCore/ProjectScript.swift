import Foundation

public enum ProjectScriptIcon: String, Codable, CaseIterable, Sendable {
    case play, test, lint, configure, build, debug
}

/// A script declared by t3.json. Flags describe upstream roles; discovery never runs them.
/// File declarations have no persistent ID and may contain duplicate names or commands.
public struct ProjectScript: Codable, Sendable, Equatable {
    public let name: String
    public let command: String
    public let icon: ProjectScriptIcon
    public let runOnWorktreeCreate: Bool
    public let runOnSettle: Bool
    public let runsAsynchronously: Bool
    public let previewURL: String?
    public let autoOpenPreview: Bool

    public init(name: String, command: String, icon: ProjectScriptIcon = .play,
                runOnWorktreeCreate: Bool = false, runOnSettle: Bool = false,
                runsAsynchronously: Bool = true, previewURL: String? = nil,
                autoOpenPreview: Bool = false) throws {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        self.icon = icon; self.runOnWorktreeCreate = runOnWorktreeCreate; self.runOnSettle = runOnSettle
        self.runsAsynchronously = runsAsynchronously
        self.previewURL = previewURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.autoOpenPreview = autoOpenPreview
        try validate()
    }
    public func validate() throws {
        guard ProjectConfigurationValidation.nonempty(name), ProjectConfigurationValidation.nonempty(command),
              previewURL.map(ProjectConfigurationValidation.nonempty) ?? true else {
            throw ProjectConfigurationError(.invalidConfiguration)
        }
    }
    private enum CodingKeys: String, CodingKey {
        case name, command, icon, runOnWorktreeCreate, runOnSettle, autoOpenPreview
        case runsAsynchronously = "async", previewURL = "previewUrl"
    }
    public init(from decoder: any Decoder) throws {
        do {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(name: c.decode(String.self, forKey: .name), command: c.decode(String.self, forKey: .command),
                          icon: c.contains(.icon) ? c.decode(ProjectScriptIcon.self, forKey: .icon) : .play,
                          runOnWorktreeCreate: c.contains(.runOnWorktreeCreate) ? c.decode(Bool.self, forKey: .runOnWorktreeCreate) : false,
                          runOnSettle: c.contains(.runOnSettle) ? c.decode(Bool.self, forKey: .runOnSettle) : false,
                          runsAsynchronously: c.contains(.runsAsynchronously) ? c.decode(Bool.self, forKey: .runsAsynchronously) : true,
                          previewURL: c.contains(.previewURL) ? c.decode(String.self, forKey: .previewURL) : nil,
                          autoOpenPreview: c.contains(.autoOpenPreview) ? c.decode(Bool.self, forKey: .autoOpenPreview) : false)
        } catch { throw ProjectConfigurationError(.invalidConfiguration) }
    }
}

/// Literal launch data only: the caller chooses a shell and explicitly starts an owned terminal.
/// No shell quoting, environment expansion, filesystem discovery, or execution happens here.
public struct ProjectScriptInvocation: Sendable, Equatable {
    public let name: String
    public let command: String
    public let directory: URL
    public let environment: [String: String]

    public init(script: ProjectScript, projectRoot: URL, worktreePath: URL? = nil) throws {
        try script.validate()
        guard Self.isLocal(projectRoot), worktreePath.map(Self.isLocal) ?? true else {
            throw ProjectConfigurationError(.invalidInvocation)
        }
        name = script.name; command = script.command; directory = worktreePath ?? projectRoot
        var environment = ["T3CODE_PROJECT_ROOT": projectRoot.path]
        if let worktreePath { environment["T3CODE_WORKTREE_PATH"] = worktreePath.path }
        self.environment = environment
    }
    private static func isLocal(_ url: URL) -> Bool {
        guard url.isFileURL, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.host == nil || components.host == "" || components.host?.lowercased() == "localhost",
              url.path.hasPrefix("/"), !url.path.contains("\0") else { return false }
        if url.path == "/" { return true }
        return url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
