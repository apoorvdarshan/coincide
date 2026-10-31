import Foundation

// Git from the phone, as the Mac's diff panel and pull request workspace offer it: commit, push, pull and open a pull
// request for a thread's folder (`gitState`, `gitAction`), and a project's pull requests (`pullRequests`,
// `pullRequest`, `pullRequestAction`). The Mac runs every command; the phone only sees what it reports. Every request
// here is answered `unsupported` by an older Mac.

/// A pull request the branch has open, or one in a list.
public struct RemotePullRequest: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Hashable, Sendable {
        case open, merged, closed
        case unknown

        public init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// `passing`, `failing`, `pending`; nil when it has no checks.
    public enum Checks: String, Codable, Hashable, Sendable {
        case passing, failing, pending
        case unknown

        public init(from decoder: Decoder) throws {
            self = Checks(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// `approved`, `changesRequested`, `reviewRequired`; nil when no review applies.
    public enum Review: String, Codable, Hashable, Sendable {
        case approved, changesRequested, reviewRequired
        case unknown

        public init(from decoder: Decoder) throws {
            self = Review(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var number: Int
    public var title: String
    public var url: String
    public var author: String?
    public var headBranch: String
    public var baseBranch: String
    public var state: State
    public var isDraft: Bool
    public var checks: Checks?
    public var review: Review?
    public var updatedAt: Date?

    public var id: Int { number }

    public init(
        number: Int, title: String, url: String, author: String? = nil, headBranch: String = "", baseBranch: String = "",
        state: State = .open, isDraft: Bool = false, checks: Checks? = nil, review: Review? = nil, updatedAt: Date? = nil
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.state = state
        self.isDraft = isDraft
        self.checks = checks
        self.review = review
        self.updatedAt = updatedAt
    }
}

/// A thread's folder as the Mac's diff panel sees it, with the git actions it allows now.
public struct RemoteGitState: Codable, Hashable, Sendable {
    public var isRepository: Bool
    /// Nil on a detached HEAD.
    public var branch: String?
    public var isDefaultBranch: Bool
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var changedFiles: Int
    public var hasRemote: Bool
    public var canCommit: Bool
    public var canPush: Bool
    public var canCreatePullRequest: Bool
    public var canPull: Bool
    /// The branch's open pull request.
    public var pullRequest: RemotePullRequest?
    /// What the host calls them: "Pull Request" or "Merge Request", in the Mac's words.
    public var changeRequestName: String
    /// Actions that push to the default branch and so ask first (`commitPush`, `push`, …).
    public var confirmsOnDefaultBranch: [String]
    /// A git action for this folder is running on the Mac: its current step.
    public var progress: String?

    public init(
        isRepository: Bool, branch: String? = nil, isDefaultBranch: Bool = false, upstream: String? = nil, ahead: Int = 0,
        behind: Int = 0, changedFiles: Int = 0, hasRemote: Bool = false, canCommit: Bool = false, canPush: Bool = false,
        canCreatePullRequest: Bool = false, canPull: Bool = false, pullRequest: RemotePullRequest? = nil,
        changeRequestName: String = "Pull Request", confirmsOnDefaultBranch: [String] = [], progress: String? = nil
    ) {
        self.isRepository = isRepository
        self.branch = branch
        self.isDefaultBranch = isDefaultBranch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changedFiles = changedFiles
        self.hasRemote = hasRemote
        self.canCommit = canCommit
        self.canPush = canPush
        self.canCreatePullRequest = canCreatePullRequest
        self.canPull = canPull
        self.pullRequest = pullRequest
        self.changeRequestName = changeRequestName
        self.confirmsOnDefaultBranch = confirmsOnDefaultBranch
        self.progress = progress
    }
}

/// A git action for a thread's folder (`gitAction`).
public struct RemoteGitActionRequest: Codable, Hashable, Sendable {
    /// The Mac's stacked actions (`commit`, `commitPush`, `commitPushPR`, `push`, `createPR`) and `pull`.
    public enum Action: String, Codable, Hashable, Sendable {
        case commit, commitPush, commitPushPR, push, createPR, pull
        case unknown

        public init(from decoder: Decoder) throws {
            self = Action(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var threadID: UUID
    public var action: Action
    /// The commit message; empty for the agent to write one.
    public var message: String?
    /// Commit on a new branch named after the change, rather than the current one.
    public var featureBranch: Bool

    public init(threadID: UUID, action: Action, message: String? = nil, featureBranch: Bool = false) {
        self.threadID = threadID
        self.action = action
        self.message = message
        self.featureBranch = featureBranch
    }
}

/// What a git action did, in the Mac's words ("Pushed 1a2b3c4 to origin/feature").
public struct RemoteGitActionResult: Codable, Hashable, Sendable {
    public var title: String
    public var detail: String?
    /// A page to open: the pull request made, or the host's page for finishing one.
    public var url: String?

    public init(title: String, detail: String? = nil, url: String? = nil) {
        self.title = title
        self.detail = detail
        self.url = url
    }
}

/// A project's pull requests, filtered as the Mac's workspace does (`pullRequests`).
public struct RemotePullRequestQuery: Codable, Hashable, Sendable {
    /// `open`, `mine` or `reviewRequested`.
    public var filter: String
    public var projectID: UUID

    public init(projectID: UUID, filter: String = "open") {
        self.projectID = projectID
        self.filter = filter
    }

    public static let filters = ["open", "mine", "reviewRequested"]
}

/// A project's pull requests, or why there are none to show.
public struct RemotePullRequestList: Codable, Hashable, Sendable {
    public var items: [RemotePullRequest]
    /// Why the project has no pull requests to list ("Install GitHub's command-line tool…"), in the Mac's words.
    public var unavailable: String?

    public init(items: [RemotePullRequest] = [], unavailable: String? = nil) {
        self.items = items
        self.unavailable = unavailable
    }
}

/// One pull request of a project.
public struct RemotePullRequestReference: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var number: Int

    public init(projectID: UUID, number: Int) {
        self.projectID = projectID
        self.number = number
    }
}

/// A pull request with its description, checks and reviews (`pullRequest`).
public struct RemotePullRequestDetail: Codable, Hashable, Sendable {
    public struct Check: Codable, Hashable, Sendable {
        /// `success`, `failure`, `cancelled`, `pending`, `actionRequired`, `skipped`, `neutral`.
        public var status: String
        public var name: String
        public var url: String?

        public init(name: String, status: String, url: String? = nil) {
            self.name = name
            self.status = status
            self.url = url
        }
    }

    public struct Review: Codable, Hashable, Sendable {
        public var author: String
        /// GitHub's state: `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, …
        public var state: String
        public var body: String

        public init(author: String, state: String, body: String = "") {
            self.author = author
            self.state = state
            self.body = body
        }
    }

    public var pullRequest: RemotePullRequest
    public var body: String
    public var checks: [Check]
    /// `mergeable`, `conflicting` or `unknown`.
    public var mergeability: String
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
    public var reviews: [Review]
    public var canMerge: Bool
    /// The merge methods the repository allows (`merge`, `squash`, `rebase`).
    public var mergeMethods: [String]

    public init(
        pullRequest: RemotePullRequest, body: String = "", checks: [Check] = [], mergeability: String = "unknown",
        additions: Int? = nil, deletions: Int? = nil, changedFiles: Int? = nil, reviews: [Review] = [], canMerge: Bool = false,
        mergeMethods: [String] = []
    ) {
        self.pullRequest = pullRequest
        self.body = body
        self.checks = checks
        self.mergeability = mergeability
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.reviews = reviews
        self.canMerge = canMerge
        self.mergeMethods = mergeMethods
    }
}

/// Something done to a pull request (`pullRequestAction`): answers the updated `pullRequest`, or `thread` for
/// `checkOut`.
public struct RemotePullRequestCommand: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Hashable, Sendable {
        /// Merges with `method`.
        case merge
        /// Approves, comments or requests changes (`event`: `APPROVE`, `COMMENT`, `REQUEST_CHANGES`) with `body`.
        case review
        case markReady
        /// Checks the branch out in a new worktree and opens a thread there, as "Check Out in New Thread".
        case checkOut
        case unknown

        public init(from decoder: Decoder) throws {
            self = Action(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var projectID: UUID
    public var number: Int
    public var action: Action
    public var method: String?
    public var event: String?
    public var body: String?

    public init(projectID: UUID, number: Int, action: Action, method: String? = nil, event: String? = nil, body: String? = nil) {
        self.projectID = projectID
        self.number = number
        self.action = action
        self.method = method
        self.event = event
        self.body = body
    }
}
