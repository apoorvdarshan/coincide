import AppKit
import CoincideKit

/// Opens pull request pages through `SafeLinks`, so nothing but a web page ever opens from them.
enum ChangeRequestLinks {
    /// A pull or merge request the host's CLI reported, over https (or http, for a server without TLS).
    static func openChangeRequest(_ url: URL, from window: NSWindow?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host?.isEmpty == false
        else {
            NSSound.beep()
            return
        }
        SafeLinks.openExternal(url, from: window)
    }

    /// A host page Coincide built for creating one, such as GitLab's new merge request page: https only.
    static func openPage(_ url: URL, from window: NSWindow?) {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            NSSound.beep()
            return
        }
        SafeLinks.openExternal(url, from: window)
    }
}

extension ChangeRequestTerm {
    /// "View Pull Request #12" or "View Merge Request !12".
    func viewTitle(_ number: Int) -> String {
        switch self {
        case .pullRequest: String(localized: "View Pull Request #\(number)")
        case .mergeRequest: String(localized: "View Merge Request !\(number)")
        }
    }

    /// The follow-up button after a pull request was created or found.
    var viewButtonTitle: String {
        switch self {
        case .pullRequest: String(localized: "View PR")
        case .mergeRequest: String(localized: "View MR")
        }
    }

    var createMenuTitle: String {
        switch self {
        case .pullRequest: String(localized: "Create Pull Request")
        case .mergeRequest: String(localized: "Create Merge Request")
        }
    }

    /// Tooltip line for the branch: "Pull request #12: Fix the parser".
    func summary(_ number: Int, title: String) -> String {
        switch self {
        case .pullRequest: String(localized: "Pull request #\(number): \(title)")
        case .mergeRequest: String(localized: "Merge request !\(number): \(title)")
        }
    }

    var detachedHeadNote: String {
        switch self {
        case .pullRequest: String(localized: "Check out a branch to push or open a pull request.")
        case .mergeRequest: String(localized: "Check out a branch to push or open a merge request.")
        }
    }

    func defaultBranchQuestion(commits: Bool) -> String {
        switch (self, commits) {
        case (.pullRequest, true): String(localized: "Commit, push and open a pull request from the default branch?")
        case (.pullRequest, false): String(localized: "Push and open a pull request from the default branch?")
        case (.mergeRequest, true): String(localized: "Commit, push and open a merge request from the default branch?")
        case (.mergeRequest, false): String(localized: "Push and open a merge request from the default branch?")
        }
    }
}
