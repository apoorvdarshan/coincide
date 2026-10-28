import Foundation

// MARK: Models

/// GitHub's verdict on a pull request's reviews (T3 Code's `PullRequestReviewDecision`).
public enum PullRequestReviewDecision: String, Sendable, Hashable {
    case approved
    case changesRequested
    case reviewRequired
}

/// What a pull request's checks add up to (T3 Code's `PullRequestChecksState`).
public enum PullRequestChecksState: String, Sendable, Hashable {
    case passing
    case failing
    case pending
}

/// One check's outcome. GitHub reports check runs as a status and a conclusion, and commit statuses as a single
/// state; both read into this.
public enum PullRequestCheckStatus: String, Sendable, Hashable {
    case success
    case failure
    case cancelled
    case pending
    /// Waiting on someone, such as a workflow run from a fork that a maintainer must approve.
    case actionRequired
    case skipped
    case neutral

    /// Failed checks and cancelled ones both keep a pull request from being ready.
    public nonisolated var isFailure: Bool { self == .failure || self == .cancelled }
}

/// One check run or commit status on a pull request's head commit.
public struct PullRequestCheck: Sendable, Hashable {
    public var name: String
    public var status: PullRequestCheckStatus
    /// The run's page, when GitHub links one.
    public var url: String?

    public nonisolated init(name: String, status: PullRequestCheckStatus, url: String? = nil) {
        self.name = name
        self.status = status
        self.url = url
    }
}

/// Whether GitHub could merge the pull request into its base as it stands.
public enum PullRequestMergeability: String, Sendable, Hashable {
    case mergeable
    case conflicting
    case unknown
}

/// The ways GitHub merges a pull request, as `gh pr merge` names them.
public enum PullRequestMergeMethod: String, Sendable, Hashable, CaseIterable {
    case merge
    case squash
    case rebase
}

public enum PullRequestReviewEvent: String, Sendable, Hashable, CaseIterable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"

    public nonisolated func accepts(body: String) -> Bool {
        self == .approve || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct PullRequestReview: Sendable, Hashable {
    public var author: String
    public var state: String
    public var body: String
}

/// Which open pull requests the list shows (T3 Code's involvement filter).
public enum PullRequestFilter: String, Sendable, Hashable, CaseIterable {
    /// Every open pull request.
    case open
    /// Open pull requests the signed-in user opened.
    case mine
    /// Open pull requests waiting on the signed-in user's review.
    case reviewRequested
}

/// One open pull request in the list: what its row and the `#` picker show.
public struct PullRequestSummary: Sendable, Hashable, Identifiable {
    public var number: Int
    public var title: String
    public var url: String
    /// The author's login; nil for a deleted account.
    public var author: String?
    public var headBranch: String
    public var baseBranch: String
    public var state: GitPullRequest.State
    public var isDraft: Bool
    /// The head branch lives in a fork rather than the repository itself.
    public var isCrossRepository: Bool
    public var reviewDecision: PullRequestReviewDecision?
    /// Nil when the head commit has no checks.
    public var checksState: PullRequestChecksState?
    public var updatedAt: Date?

    public nonisolated var id: Int { number }

    public nonisolated init(
        number: Int, title: String, url: String, author: String? = nil, headBranch: String, baseBranch: String,
        state: GitPullRequest.State = .open, isDraft: Bool = false, isCrossRepository: Bool = false,
        reviewDecision: PullRequestReviewDecision? = nil, checksState: PullRequestChecksState? = nil,
        updatedAt: Date? = nil
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.state = state
        self.isDraft = isDraft
        self.isCrossRepository = isCrossRepository
        self.reviewDecision = reviewDecision
        self.checksState = checksState
        self.updatedAt = updatedAt
    }
}

/// A pull request opened in the detail view: its summary plus the description and every check.
public struct PullRequestDetail: Sendable, Hashable {
    public var summary: PullRequestSummary
    /// The description as written, Markdown.
    public var body: String
    /// Failing checks first, then in GitHub's order.
    public var checks: [PullRequestCheck]
    public var mergeability: PullRequestMergeability
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
    /// The exact revision shown, used to reject a merge if the head changes before confirmation.
    public var headCommit: String
    public var reviews: [PullRequestReview]

    public nonisolated var canMerge: Bool {
        summary.state == .open && !summary.isDraft && !headCommit.isEmpty && mergeability == .mergeable
            && summary.checksState != .failing && summary.checksState != .pending
            && summary.reviewDecision != .changesRequested && summary.reviewDecision != .reviewRequired
    }

    public nonisolated init(
        summary: PullRequestSummary, body: String = "", checks: [PullRequestCheck] = [],
        mergeability: PullRequestMergeability = .unknown, additions: Int? = nil, deletions: Int? = nil,
        changedFiles: Int? = nil, headCommit: String = "", reviews: [PullRequestReview] = []
    ) {
        self.summary = summary
        self.body = body
        self.checks = checks
        self.mergeability = mergeability
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.headCommit = headCommit
        self.reviews = reviews
    }
}

// MARK: Commands

/// The `gh` arguments behind the pull request workspace.
enum PullRequestCommands {
    nonisolated static let listFields = [
        "number", "title", "url", "author", "headRefName", "baseRefName", "state", "isDraft", "isCrossRepository",
        "reviewDecision", "latestReviews", "statusCheckRollup", "updatedAt",
    ].joined(separator: ",")

    nonisolated static let detailFields = listFields + ",body,mergeable,additions,deletions,changedFiles,headRefOid,reviews"

    /// The repository's open pull requests, newest first; `@me` is whoever `gh` is signed in as.
    nonisolated static func list(_ filter: PullRequestFilter, limit: Int) -> [String] {
        var arguments = ["pr", "list", "--state", "open", "--limit", String(limit), "--json", listFields]
        switch filter {
        case .open: break
        case .mine: arguments += ["--author", "@me"]
        case .reviewRequested: arguments += ["--search", "review-requested:@me"]
        }
        return arguments
    }

    nonisolated static func view(_ number: Int) -> [String] {
        ["pr", "view", String(number), "--json", detailFields]
    }

    /// Never deletes the branch: it may be checked out in a worktree a thread runs in.
    nonisolated static func merge(_ number: Int, method: PullRequestMergeMethod, headCommit: String) -> [String] {
        ["pr", "merge", String(number), "--" + method.rawValue, "--match-head-commit", headCommit]
    }

    nonisolated static func review(_ number: Int) -> [String] {
        ["api", "repos/{owner}/{repo}/pulls/\(number)/reviews", "--method", "POST", "--input", "-"]
    }

    nonisolated static func reviewBody(_ event: PullRequestReviewEvent, body: String, headCommit: String) throws -> String {
        let value = ["event": event.rawValue, "body": body, "commit_id": headCommit]
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    nonisolated static func ready(_ number: Int) -> [String] {
        ["pr", "ready", String(number)]
    }

    nonisolated static let mergeSettings = [
        "repo", "view", "--json", "mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed",
    ]

    /// Checks the pull request out as `branch` in the current folder, a new detached worktree. `gh` fetches the head
    /// (from the fork for a cross-repository one) and sets the branch up to push back to it.
    nonisolated static func checkout(_ number: Int, branch: String, submodules: Bool) -> [String] {
        ["pr", "checkout", String(number), "--branch", branch] + (submodules ? ["--recurse-submodules"] : [])
    }
}

// MARK: JSON

/// Reads `gh`'s JSON into the models above (T3 Code's `gitHubPullRequestJson`). Entries that don't read are skipped
/// rather than failing the list.
enum PullRequestJSON {
    nonisolated static func list(_ output: String) -> [PullRequestSummary]? {
        JSONValue.parse(output)?.array?.compactMap(summary)
    }

    nonisolated static func summary(_ value: JSONValue) -> PullRequestSummary? {
        guard let number = value["number"]?.exactInt, number > 0, let title = text(value["title"]),
            let url = text(value["url"]), let head = text(value["headRefName"]), let base = text(value["baseRefName"])
        else { return nil }
        let state: GitPullRequest.State =
            switch value["state"]?.string?.uppercased() {
            case "MERGED": .merged
            case "CLOSED": .closed
            default: .open
            }
        return PullRequestSummary(
            number: number, title: title, url: url, author: text(value.at("author.login")), headBranch: head,
            baseBranch: base, state: state, isDraft: value["isDraft"]?.bool == true,
            isCrossRepository: value["isCrossRepository"]?.bool == true,
            reviewDecision: reviewDecision(value["reviewDecision"]?.string, latestReviews: value["latestReviews"]?.array),
            checksState: checksState(statuses(value["statusCheckRollup"]?.array ?? [])),
            updatedAt: text(value["updatedAt"]).flatMap { try? Date($0, strategy: .iso8601) })
    }

    nonisolated static func detail(_ output: String) -> PullRequestDetail? {
        guard let value = JSONValue.parse(output), let summary = summary(value) else { return nil }
        let mergeability: PullRequestMergeability =
            switch value["mergeable"]?.string?.uppercased() {
            case "MERGEABLE": .mergeable
            case "CONFLICTING": .conflicting
            default: .unknown
            }
        return PullRequestDetail(
            summary: summary, body: value["body"]?.string ?? "", checks: checks(value["statusCheckRollup"]?.array ?? []),
            mergeability: mergeability, additions: value["additions"]?.exactInt, deletions: value["deletions"]?.exactInt,
            changedFiles: value["changedFiles"]?.exactInt, headCommit: text(value["headRefOid"]) ?? "",
            reviews: (value["reviews"]?.array ?? []).compactMap { review in
                guard let state = text(review["state"]), state != "PENDING" else { return nil }
                return PullRequestReview(
                    author: text(review.at("author.login")) ?? "—", state: state, body: review["body"]?.string ?? "")
            })
    }

    /// The methods the repository allows; all three when its settings don't read, so `gh` has the final word.
    nonisolated static func mergeMethods(_ output: String) -> [PullRequestMergeMethod] {
        guard let value = JSONValue.parse(output) else { return PullRequestMergeMethod.allCases }
        let allowed = PullRequestMergeMethod.allCases.filter { method in
            let key =
                switch method {
                case .merge: "mergeCommitAllowed"
                case .squash: "squashMergeAllowed"
                case .rebase: "rebaseMergeAllowed"
                }
            return value[key]?.bool != false
        }
        return allowed.isEmpty ? PullRequestMergeMethod.allCases : allowed
    }

    /// GitHub's `reviewDecision` only counts reviews its branch rules require, so a repository without them reports
    /// none even after an approval; the latest reviews fill in, as in T3 Code.
    nonisolated static func reviewDecision(_ value: String?, latestReviews: [JSONValue]?) -> PullRequestReviewDecision? {
        let summarized: PullRequestReviewDecision? =
            switch value?.trimmingCharacters(in: .whitespaces).uppercased() {
            case "APPROVED": .approved
            case "CHANGES_REQUESTED": .changesRequested
            case "REVIEW_REQUIRED": .reviewRequired
            default: nil
            }
        if summarized == .approved || summarized == .changesRequested { return summarized }
        let states = Set((latestReviews ?? []).compactMap { $0["state"]?.string?.uppercased() })
        if states.contains("CHANGES_REQUESTED") { return .changesRequested }
        if states.contains("APPROVED") { return .approved }
        return summarized
    }

    /// A check run is pending until it completes, then its conclusion counts; a commit status has only its state.
    nonisolated static func status(_ check: JSONValue) -> PullRequestCheckStatus {
        if let status = check["status"]?.string?.uppercased(), !status.isEmpty, status != "COMPLETED" { return .pending }
        let outcome = text(check["conclusion"]) ?? text(check["state"])
        switch outcome?.uppercased() {
        case "SUCCESS": return .success
        case "ACTION_REQUIRED": return .actionRequired
        case "FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE": return .failure
        case "CANCELLED": return .cancelled
        case "SKIPPED": return .skipped
        case "PENDING", "EXPECTED": return .pending
        default: return .neutral
        }
    }

    /// Every check once: a rerun or a check both a push and a pull request workflow run is reported again, so only
    /// the newest run of each workflow's check stays, a running one counting as newest. A name that more than one
    /// workflow uses is shown with its workflow. Failing checks come first, as in T3 Code.
    nonisolated static func checks(_ rollup: [JSONValue]) -> [PullRequestCheck] {
        struct Entry {
            var check: PullRequestCheck
            var workflow: String
            var order: Int
            var at: String
        }
        var newest: [String: Entry] = [:]
        for (order, raw) in rollup.enumerated() {
            guard let name = text(raw["name"]) ?? text(raw["context"]) else { continue }
            let status = status(raw)
            let workflow = text(raw["workflowName"]) ?? ""
            // ISO 8601 times in one format sort as text.
            let at = status == .pending ? "9999" : realTimestamp(raw["completedAt"]) ?? realTimestamp(raw["startedAt"]) ?? ""
            let check = PullRequestCheck(name: name, status: status, url: text(raw["detailsUrl"]) ?? text(raw["targetUrl"]))
            let key = workflow + "\u{0}" + name
            if let kept = newest[key], kept.at > at { continue }
            // A later run keeps the place of the first, so the list doesn't reorder as checks rerun.
            newest[key] = Entry(check: check, workflow: workflow, order: newest[key]?.order ?? order, at: at)
        }
        let survivors = newest.values.sorted { $0.order < $1.order }
        let counts = Dictionary(survivors.map { ($0.check.name, 1) }, uniquingKeysWith: +)
        let named = survivors.map { entry in
            guard !entry.workflow.isEmpty, counts[entry.check.name, default: 0] > 1 else { return entry.check }
            var check = entry.check
            check.name = "\(entry.workflow) / \(check.name)"
            return check
        }
        return named.filter(\.status.isFailure) + named.filter { !$0.status.isFailure }
    }

    /// Every check's status, nameless ones included: they still hold a pull request up.
    nonisolated static func statuses(_ rollup: [JSONValue]) -> [PullRequestCheckStatus] {
        checks(rollup).map(\.status) + rollup.filter { text($0["name"]) == nil && text($0["context"]) == nil }.map(status)
    }

    /// Any failure fails the pull request; otherwise anything unfinished keeps it pending. Checks that were all
    /// skipped or neutral add up to nothing.
    nonisolated static func checksState(_ statuses: [PullRequestCheckStatus]) -> PullRequestChecksState? {
        if statuses.contains(where: \.isFailure) { return .failing }
        if statuses.contains(.pending) || statuses.contains(.actionRequired) { return .pending }
        return statuses.contains(.success) ? .passing : nil
    }

    /// GitHub writes `0001-01-01T00:00:00Z` for a time not reached yet.
    private nonisolated static func realTimestamp(_ value: JSONValue?) -> String? {
        guard let at = text(value), !at.hasPrefix("0001-") else { return nil }
        return at
    }

    private nonisolated static func text(_ value: JSONValue?) -> String? {
        guard let string = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }
        return string
    }
}

// MARK: Descriptions

/// Pull request descriptions as the detail view shows them.
public enum PullRequestBody {
    /// The description without HTML comments, which pull request templates leave behind as instructions to the
    /// author and GitHub never shows.
    public nonisolated static func displayMarkdown(_ body: String) -> String {
        body.replacingOccurrences(of: "<!--[\\s\\S]*?(-->|$)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Mentions

/// Pull requests named in a message as `#123` (T3 Code's `#` picker): the composer's completions, and what the agent
/// is told about the ones the user picked.
public enum PullRequestMention {
    /// The pull requests the `#` picker lists for `query`, the text after `#`. Digits match the number, anything else
    /// the title, branch or author; the closest matches come first, then the most recently updated.
    public nonisolated static func matching(_ query: String, in pullRequests: [PullRequestSummary], limit: Int = 50)
        -> [PullRequestSummary]
    {
        let query = query.trimmingCharacters(in: .whitespaces)
        let isNumber = !query.isEmpty && query.allSatisfy(\.isASCII) && query.allSatisfy(\.isNumber)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let ranked = pullRequests.compactMap { pullRequest -> (rank: Int, pullRequest: PullRequestSummary)? in
            if query.isEmpty { return (0, pullRequest) }
            if isNumber {
                let number = String(pullRequest.number)
                if number == query { return (0, pullRequest) }
                if number.hasPrefix(query) { return (1, pullRequest) }
                return number.contains(query) ? (2, pullRequest) : nil
            }
            if pullRequest.title.range(of: query, options: [options, .anchored]) != nil { return (0, pullRequest) }
            if pullRequest.title.range(of: query, options: options) != nil { return (1, pullRequest) }
            let others = [pullRequest.headBranch, pullRequest.author ?? ""]
            return others.contains { $0.range(of: query, options: options) != nil } ? (2, pullRequest) : nil
        }
        return ranked.sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            let leftDate = left.pullRequest.updatedAt ?? .distantPast
            let rightDate = right.pullRequest.updatedAt ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return left.pullRequest.number > right.pullRequest.number
        }
        .prefix(limit).map(\.pullRequest)
    }

    /// The numbers mentioned as whole `#123` words in `text`, in order of first mention.
    public nonisolated static func numbers(in text: String) -> [Int] {
        let string = text as NSString
        var numbers: [Int] = []
        for match in mentionPattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            guard let number = Int(string.substring(with: match.range(at: 1))), !numbers.contains(number) else { continue }
            numbers.append(number)
        }
        return numbers
    }

    /// `#` and digits after a space, a bracket or the start, and not followed by more of a word.
    private nonisolated static let mentionPattern = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[\s(\[]))#([0-9]{1,9})(?![\p{L}\p{N}_-])"#, options: [.anchorsMatchLines])

    /// A durable reference, kept in the user's message rather than in an in-memory completion cache.
    public nonisolated static func markdown(_ pullRequest: PullRequestSummary) -> String? {
        guard let url = URL(string: pullRequest.url), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http", url.host?.isEmpty == false,
            url.user == nil, url.password == nil
        else { return nil }
        var destination = url.absoluteString
        for (character, escaped) in [("(", "%28"), (")", "%29"), ("<", "%3C"), (">", "%3E"), ("\\", "%5C")] {
            destination = destination.replacingOccurrences(of: character, with: escaped)
        }
        return "[#\(pullRequest.number)](\(destination))"
    }

}

// MARK: Checkout

/// Where a pull request is checked out for a thread of its own.
public enum PullRequestCheckout {
    /// The local branch for the pull request: its own head branch when it lives in this repository, so pushing
    /// updates it; `<prefix>pr-<number>/<head>` for one from a fork, whose branch name could be anything, such as
    /// `main` (T3 Code's `t3code/pr-<number>/<head>`).
    public nonisolated static func localBranch(for pullRequest: PullRequestSummary, prefix: String) -> String {
        guard pullRequest.isCrossRepository else { return pullRequest.headBranch }
        return "\(prefix)pr-\(pullRequest.number)/\(BranchNames.sanitizeFragment(pullRequest.headBranch))"
    }
}
