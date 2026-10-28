import AppKit
import CoincideKit

/// How pull request states, checks and reviews look wherever they show: a symbol, its color and what it says, after
/// T3 Code's `pullRequestPresentation`.
struct PullRequestGlyph {
    var symbol: String
    var color: NSColor
    var label: String

    func image(size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage? {
        let image = Theme.symbol(symbol, size: size, weight: weight)
        image?.accessibilityDescription = label
        return image
    }

    /// Open, draft, merged or closed.
    static func state(_ state: GitPullRequest.State, isDraft: Bool) -> PullRequestGlyph {
        switch state {
        case .open where isDraft:
            PullRequestGlyph(symbol: "arrow.triangle.pull", color: .secondaryLabelColor, label: String(localized: "Draft"))
        case .open: PullRequestGlyph(symbol: "arrow.triangle.pull", color: Theme.success, label: String(localized: "Open"))
        case .merged:
            PullRequestGlyph(symbol: "arrow.triangle.merge", color: .systemPurple, label: String(localized: "Merged"))
        case .closed:
            PullRequestGlyph(symbol: "xmark.circle", color: .secondaryLabelColor, label: String(localized: "Closed"))
        }
    }

    static func checks(_ state: PullRequestChecksState) -> PullRequestGlyph {
        switch state {
        case .passing:
            PullRequestGlyph(symbol: "checkmark.circle", color: Theme.success, label: String(localized: "All checks have passed"))
        case .failing:
            PullRequestGlyph(
                symbol: "xmark.circle", color: Theme.failure, label: String(localized: "Some checks were not successful"))
        case .pending:
            PullRequestGlyph(
                symbol: "smallcircle.filled.circle", color: Theme.warning,
                label: String(localized: "Some checks haven’t completed yet"))
        }
    }

    static func review(_ decision: PullRequestReviewDecision) -> PullRequestGlyph {
        switch decision {
        case .approved:
            PullRequestGlyph(symbol: "person.crop.circle.badge.checkmark", color: Theme.success, label: String(localized: "Approved"))
        case .changesRequested:
            PullRequestGlyph(
                symbol: "person.crop.circle.badge.xmark", color: Theme.warning, label: String(localized: "Changes requested"))
        case .reviewRequired:
            PullRequestGlyph(symbol: "person.crop.circle", color: .tertiaryLabelColor, label: String(localized: "Awaiting review"))
        }
    }

    static func check(_ status: PullRequestCheckStatus) -> PullRequestGlyph {
        switch status {
        case .success: PullRequestGlyph(symbol: "checkmark.circle", color: Theme.success, label: String(localized: "Passed"))
        case .failure: PullRequestGlyph(symbol: "xmark.circle", color: Theme.failure, label: String(localized: "Failed"))
        case .cancelled: PullRequestGlyph(symbol: "xmark.circle", color: Theme.failure, label: String(localized: "Cancelled"))
        case .pending:
            PullRequestGlyph(symbol: "smallcircle.filled.circle", color: Theme.warning, label: String(localized: "In progress"))
        case .actionRequired:
            PullRequestGlyph(symbol: "exclamationmark.circle", color: Theme.warning, label: String(localized: "Awaiting approval"))
        case .skipped: PullRequestGlyph(symbol: "slash.circle", color: .tertiaryLabelColor, label: String(localized: "Skipped"))
        case .neutral: PullRequestGlyph(symbol: "circle.dashed", color: .tertiaryLabelColor, label: String(localized: "Neutral"))
        }
    }
}

extension PullRequestFilter {
    var title: String {
        switch self {
        case .open: String(localized: "Open Pull Requests")
        case .mine: String(localized: "My Pull Requests")
        case .reviewRequested: String(localized: "Review Requested")
        }
    }

    var symbolName: String {
        switch self {
        case .open: "arrow.triangle.pull"
        case .mine: "person"
        case .reviewRequested: "eye"
        }
    }
}

extension PullRequestMergeMethod {
    /// The method as GitHub's merge button names it.
    var title: String {
        switch self {
        case .merge: String(localized: "Create a Merge Commit")
        case .squash: String(localized: "Squash and Merge")
        case .rebase: String(localized: "Rebase and Merge")
        }
    }

    /// The confirmation's question for pull request `number`.
    func question(_ number: Int) -> String {
        switch self {
        case .merge: String(localized: "Merge pull request #\(number) with a merge commit?")
        case .squash: String(localized: "Squash and merge pull request #\(number)?")
        case .rebase: String(localized: "Rebase and merge pull request #\(number)?")
        }
    }
}
