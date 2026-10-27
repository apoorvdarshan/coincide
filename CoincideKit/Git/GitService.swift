import Foundation

// STUB: replaced by the real git integration.
@MainActor
public final class GitService {
    public static let shared = GitService()

    public init() {}

    public func isRepository(_ url: URL) async -> Bool { false }
}
