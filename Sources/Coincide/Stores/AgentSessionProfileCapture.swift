import CoincideCore
import Foundation

/// Uses only settings already captured by this app. It never accepts a folder
/// or executable from the import sheet and never starts a provider process.
enum AgentSessionProfileCapture {
    static func profiles(codex: CodexRuntimeConfiguration, captured: [ProviderConfiguration], workspacePath: String,
                         environment: [String: String], claude: @Sendable (String) throws -> ClaudeRuntimeConfiguration) throws -> [AgentSessionProfile] {
        let project = WorkspaceProject(path: workspacePath)
        var defaultCodex = CodingThread(project: project); defaultCodex.codexRuntimeConfiguration = codex
        var candidates = [ProviderConfiguration(thread: defaultCodex)] + captured
        candidates.append(.init(thread: CodingThread(project: project)))
        var defaultClaude = CodingThread(project: project); defaultClaude.provider = .claude
        if let runtime = try? claude(workspacePath) {
            defaultClaude.claudeRuntimeConfiguration = runtime; candidates.append(.init(thread: defaultClaude))
        }
        var seen: Set<UUID> = [], result: [AgentSessionProfile] = []
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        for var configuration in candidates {
            try Task.checkCancellation()
            guard configuration.provider == .codex || configuration.provider == .claude else { continue }
            configuration.nativeThreadID = nil; configuration.claudeLaunchSelection = nil
            let root: String
            if configuration.provider == .codex {
                let runtime = configuration.codexRuntimeConfiguration ?? .init()
                try runtime.validate()
                root = runtime.homeDirectory ?? environment["CODEX_HOME"] ?? URL(fileURLWithPath: home).appendingPathComponent(".codex").path
            } else {
                if configuration.claudeRuntimeConfiguration == nil { configuration.claudeRuntimeConfiguration = try? claude(configuration.workspacePath) }
                guard let runtime = configuration.claudeRuntimeConfiguration else { continue }
                root = runtime.configurationDirectory
            }
            let profile = try AgentSessionProfile(configuration: configuration, transcriptsRoot: root)
            guard seen.insert(profile.id).inserted else { continue }
            result.append(profile)
        }
        guard result.count <= 64 else { throw AgentSessionImportError.limit }
        return result
    }
}
