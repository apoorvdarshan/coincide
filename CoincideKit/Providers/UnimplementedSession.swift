import Foundation

/// Placeholder session for providers that are not wired up yet. Every turn fails with a clear message.
public final class UnimplementedSession: AgentSession {
    public let provider: ProviderKind
    public private(set) var sessionID: String?
    public var onEvent: ((AgentEvent) -> Void)?

    public init(provider: ProviderKind) {
        self.provider = provider
    }

    public func start() async throws {}

    public func send(_ input: AgentTurnInput) async throws {
        throw AgentError.providerError(String(localized: "\(provider.displayName) support is not available yet."))
    }

    public func respond(to approvalID: String, optionID: String) {}
    public func interrupt() {}
    public func shutdown() {}
}
