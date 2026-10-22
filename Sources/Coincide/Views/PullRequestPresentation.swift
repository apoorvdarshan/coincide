import CoincideCore
import Foundation

/// Presentation never treats an unvalidated remote URL as a trusted opener.
enum PullRequestPresentation {
    static func url(_ summary: GitHubPullRequestSummary) -> URL? {
        guard (try? summary.validate()) != nil else { return nil }
        return URL(string: summary.url)
    }
    static func state(_ summary: GitHubPullRequestSummary) -> String {
        switch summary.state {
        case .open: summary.isDraft ? String(localized: "Draft") : String(localized: "Open")
        case .closed: String(localized: "Closed")
        case .merged: String(localized: "Merged")
        }
    }
    static func checks(_ state: GitHubPullRequestChecksState) -> String {
        switch state {
        case .pending: String(localized: "Pending")
        case .success: String(localized: "Passed")
        case .failure: String(localized: "Failed")
        case .unknown: String(localized: "Unknown")
        }
    }
    static func review(_ decision: GitHubPullRequestReviewDecision) -> String {
        switch decision {
        case .approved: String(localized: "Approved")
        case .changesRequested: String(localized: "Changes requested")
        case .reviewRequired: String(localized: "Review required")
        case .unknown: String(localized: "Unknown")
        }
    }
    static func error(_ error: any Error) -> String {
        if let error = error as? GitHubPullRequestError { return error.localizedDescription }
        return String(localized: "This pull request action could not finish. Refresh its current state before continuing.")
    }
    static func head(_ context: GitHubPullRequestContext) -> String {
        guard let branch = context.upstream?.branch ?? context.branch else { return String(localized: "Detached HEAD") }
        return context.headRepository.map { $0.nameWithOwner + ":" + branch } ?? branch
    }
}
