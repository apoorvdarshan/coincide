import CryptoKit
import Foundation

public enum RemotePullRequestProtocol {
    public static let bindMethod = "remoteEnvironment.pullRequest.bind"
    public static let readMethod = "remoteEnvironment.pullRequest.read"
    public static let reviewMethod = "remoteEnvironment.pullRequest.review"
    public static let discardMethod = "remoteEnvironment.pullRequest.discard"
    public static func payload<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func digest(target: RemoteWorkspaceTarget, value: RemotePullRequestReviewValue) throws -> String {
        struct Binding: Encodable { let target: RemoteWorkspaceTarget; let value: RemotePullRequestReviewValue }
        return SHA256.hash(data: try payload(Binding(target: target, value: value))).map { String(format: "%02x", $0) }.joined()
    }
}
public enum RemotePullRequestQuery: Codable, Sendable, Equatable {
    case context
    case list(GitHubPullRequestListQuery)
    case detail(GitHubPullRequestReference)
    case resolve(String)
}
public struct RemotePullRequestReadRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let query: RemotePullRequestQuery
    public init(target: RemoteWorkspaceTarget, query: RemotePullRequestQuery) { self.target = target; self.query = query }
}
public enum RemotePullRequestValue: Codable, Sendable, Equatable {
    case context(GitHubPullRequestContext), page(GitHubPullRequestPage), detail(GitHubPullRequestDetail)
}
public struct RemotePullRequestReadResult: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let value: RemotePullRequestValue
    public init(target: RemoteWorkspaceTarget, value: RemotePullRequestValue) { self.target = target; self.value = value }
}
public enum RemotePullRequestIntent: Codable, Sendable, Equatable {
    case create(title: String, body: String, baseBranch: String?, isDraft: Bool)
    case checkout(reference: GitHubPullRequestReference, mode: GitHubPullRequestCheckoutMode, submodules: ProjectWorktreeSubmoduleMode, title: String?)
}
public struct RemotePullRequestReviewRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let intent: RemotePullRequestIntent
    public init(target: RemoteWorkspaceTarget, intent: RemotePullRequestIntent) { self.target = target; self.intent = intent }
}
public enum RemotePullRequestReviewValue: Codable, Sendable, Equatable {
    case creation(GitHubPullRequestCreateReview), checkout(PullRequestCheckoutReview)
    public var id: UUID { switch self { case .creation(let review): review.id; case .checkout(let review): review.id } }
}
public struct RemotePullRequestReview: Codable, Sendable, Equatable, Identifiable {
    public let target: RemoteWorkspaceTarget
    public let id: UUID
    public let digest: String
    public let value: RemotePullRequestReviewValue
    public init(target: RemoteWorkspaceTarget, value: RemotePullRequestReviewValue) throws {
        self.target = target; self.value = value; id = value.id
        digest = try RemotePullRequestProtocol.digest(target: target, value: value)
    }
}
public struct RemotePullRequestDiscardRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let reviewID: UUID
    public let digest: String
    public init(target: RemoteWorkspaceTarget, reviewID: UUID, digest: String) {
        self.target = target; self.reviewID = reviewID; self.digest = digest
    }
}
public struct RemotePullRequestDiscardResult: Codable, Sendable, Equatable {
    public let request: RemotePullRequestDiscardRequest
    public let discarded: Bool
    public init(request: RemotePullRequestDiscardRequest, discarded: Bool) { self.request = request; self.discarded = discarded }
}
public enum RemotePullRequestAction: Codable, Sendable, Equatable {
    case begin(reviewID: UUID, digest: String)
    case inspectCreation(operationID: UUID)
    case acknowledgeCreation(operationID: UUID)
    case inspectCheckout(operationID: UUID)
    case cancelCheckout(operationID: UUID)
    case acknowledgeCheckout(operationID: UUID)
    public var requiresBoundRoot: Bool {
        switch self { case .begin, .inspectCreation, .inspectCheckout: true; case .acknowledgeCreation, .acknowledgeCheckout, .cancelCheckout: false }
    }
}
public struct RemotePullRequestFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Codable, Sendable {
        case invalidRequest, invalidTarget, staleReview, unavailable, busy, limitExceeded
        case missingCLI, unauthenticated, accessDenied, rateLimited, operationFailed
    }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidRequest: "The remote pull request operation is invalid."
        case .invalidTarget: "The remote conversation or checkout changed. Refresh before continuing."
        case .staleReview: "This pull request review changed or expired. Review it again before continuing."
        case .unavailable: "Remote pull requests are unavailable."
        case .busy: "Another operation owns this remote checkout."
        case .limitExceeded: "The remote pull request operation exceeded its limit."
        case .missingCLI: "Install GitHub CLI on the remote Mac to use pull requests."
        case .unauthenticated: "Sign in to GitHub CLI on the remote Mac, then refresh."
        case .accessDenied: "The remote GitHub account cannot access this repository."
        case .rateLimited: "GitHub rate limited the remote account. Try refreshing later."
        case .operationFailed: "The remote pull request operation failed. Review its saved result before continuing."
        }
    }
}
