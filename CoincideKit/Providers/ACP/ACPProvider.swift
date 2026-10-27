import Foundation

/// Agents that speak the Agent Client Protocol and differ only in how they are launched.
public enum ACPProfile: String, Sendable, CaseIterable {
    case grok
    case antigravity

    public nonisolated var kind: ProviderKind {
        switch self {
        case .grok: .grok
        case .antigravity: .antigravity
        }
    }
}

// STUB: replaced by the real ACP client.
public final class ACPProvider: AgentProvider {
    public let profile: ACPProfile
    public var kind: ProviderKind { profile.kind }
    public var executableNames: [String] { profile == .grok ? ["grok"] : ["agy", "antigravity"] }
    public var setupHint: String {
        profile == .grok ? "Install the Grok Build CLI and run `grok login`." : "Install Antigravity and sign in with Google."
    }

    public init(profile: ACPProfile) {
        self.profile = profile
    }

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
