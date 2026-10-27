import Foundation

// STUB: replaced by the real claude provider.
public final class ClaudeProvider: AgentProvider {
    public let kind: ProviderKind = .claude
    public let executableNames = ["claude"]
    public let setupHint = "Install Claude Code and run `claude auth login`."

    public init() {}

    public func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        guard let executable else { return ProviderStatus(state: .notInstalled, message: setupHint) }
        return ProviderStatus(state: .ready, executable: executable)
    }

    public func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        [ModelOption(provider: kind, modelID: "default", displayName: "Default")]
    }

    public func makeSession(_ launch: AgentLaunch) -> AgentSession {
        UnimplementedSession(provider: kind)
    }
}
