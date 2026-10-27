import Foundation

// STUB: replaced by the real opencode provider.
public final class OpenCodeProvider: AgentProvider {
    public let kind: ProviderKind = .opencode
    public let executableNames = ["opencode"]
    public let setupHint = "Install OpenCode and run `opencode auth login`."

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
