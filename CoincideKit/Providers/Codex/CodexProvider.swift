import Foundation

// STUB: replaced by the real codex provider.
public final class CodexProvider: AgentProvider {
    public let kind: ProviderKind = .codex
    public let executableNames = ["codex"]
    public let setupHint = "Install the Codex CLI and run `codex login`."

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
