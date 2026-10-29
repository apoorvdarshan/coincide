import Foundation

/// An agent's request to sign in with a saved login, waiting on the user's answer in the browser panel. Nothing is
/// filled until the user allows it; no answer within the timeout counts as Deny.
@MainActor
public final class LoginApprovalGate {
    public struct Request: Equatable, Sendable {
        public let id: UUID
        public let site: String
        public let item: LoginItem

        public init(id: UUID, site: String, item: LoginItem) {
            self.id = id
            self.site = site
            self.item = item
        }
    }

    public nonisolated static let timeout: TimeInterval = 300
    public private(set) var request: Request?
    public var onChange: (() -> Void)?
    private var continuation: CheckedContinuation<LoginApproval, Never>?

    public init() {}

    public func ask(site: String, item: LoginItem, timeout: TimeInterval = LoginApprovalGate.timeout) async -> LoginApproval {
        answer(.deny)
        let id = UUID()
        request = Request(id: id, site: site, item: item)
        onChange?()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, self.request?.id == id else { return }
            self.answer(.deny)
        }
        return await withCheckedContinuation { continuation in
            if request?.id == id { self.continuation = continuation } else { continuation.resume(returning: .deny) }
        }
    }

    public func answer(_ approval: LoginApproval) {
        guard request != nil || continuation != nil else { return }
        request = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: approval)
        onChange?()
    }
}
