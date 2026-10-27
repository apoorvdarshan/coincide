import Foundation

// STUB: replaced by the real pi provider.
public final class PiProvider: AgentProvider {
    public let kind: ProviderKind = .pi
    public let executableNames = ["pi"]
    public let setupHint = "Install Pi and sign in."

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
