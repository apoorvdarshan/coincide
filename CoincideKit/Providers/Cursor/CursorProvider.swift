import Foundation

// STUB: replaced by the real cursor provider.
public final class CursorProvider: AgentProvider {
    public let kind: ProviderKind = .cursor
    public let executableNames = ["cursor-agent"]
    public let setupHint = "Install the Cursor CLI and run `cursor-agent login`."

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
