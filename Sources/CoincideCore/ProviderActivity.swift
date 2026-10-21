import Foundation

public enum ProviderForegroundState: String, Codable, Sendable { case idle, running, requiresAction }
public struct ProviderActivity: Codable, Sendable, Equatable {
    public var id: UUID
    public var state: ProviderForegroundState
    public var stopReason: JSONValue?
    public var error: JSONValue?
    /// Setup snapshots and prompt acceptance are not turn completion.
    public var finishesRun: Bool
    public init(id: UUID, state: ProviderForegroundState, stopReason: JSONValue? = nil, error: JSONValue? = nil, finishesRun: Bool = true) {
        self.id = id; self.state = state; self.stopReason = stopReason; self.error = error; self.finishesRun = finishesRun
    }
}
