import CoreFoundation
import Foundation

enum GitHubPullRequestJSON {
    static let fields = "number,title,url,state,isDraft,headRefName,baseRefName,headRefOid,baseRefOid,headRepository,headRepositoryOwner,isCrossRepository,author,updatedAt,reviewDecision,statusCheckRollup"
    static let detailFields = fields + ",body,createdAt,additions,deletions,changedFiles,reviewRequests,labels"
    static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitHubPullRequestError(.invalidResponse) }; return result
    }
    static func array(_ data: Data) throws -> [[String: Any]] {
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw GitHubPullRequestError(.invalidResponse) }; return result
    }
    static func string(_ row: [String: Any], _ key: String) throws -> String {
        guard let value = row[key] as? String else { throw GitHubPullRequestError(.invalidResponse) }; return value
    }
    static func date(_ row: [String: Any], _ key: String) throws -> Date {
        let value = try string(row, key), parser = ISO8601DateFormatter()
        if let date = parser.date(from: value) { return date }
        parser.formatOptions.insert(.withFractionalSeconds)
        guard let date = parser.date(from: value) else { throw GitHubPullRequestError(.invalidResponse) }; return date
    }
    static func integer(_ row: [String: Any], _ key: String) throws -> Int {
        guard let value = row[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
              value.doubleValue >= 0, value.doubleValue < Double(Int.max) else { throw GitHubPullRequestError(.invalidResponse) }
        return value.intValue
    }
    static func summary(_ row: [String: Any], repository: GitHubRepository) throws -> GitHubPullRequestSummary {
        let number = try integer(row, "number"), stateText = try string(row, "state").lowercased()
        guard let state = GitHubPullRequestState(rawValue: stateText), let isDraft = row["isDraft"] as? Bool else { throw GitHubPullRequestError(.invalidResponse) }
        let head = row["headRepository"] as? [String: Any]
        let owner = (row["headRepositoryOwner"] as? [String: Any])?["login"] as? String
        let fullName = head?["nameWithOwner"] as? String ?? (owner.flatMap { o in (head?["name"] as? String).map { o + "/" + $0 } })
        let headRepository: GitHubRepository?
        if let fullName {
            let pieces = fullName.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count == 2 else { throw GitHubPullRequestError(.invalidResponse) }
            headRepository = try .init(host: repository.host, owner: String(pieces[0]), name: String(pieces[1]))
        } else { headRepository = row["isCrossRepository"] as? Bool == false ? repository : nil }
        let checks = try checks(row)
        let checkState: GitHubPullRequestChecksState? = checks.isEmpty ? nil :
            (checks.contains { $0.state == .failure } ? .failure : checks.contains { $0.state == .pending } ? .pending : checks.allSatisfy { $0.state == .success } ? .success : .unknown)
        let decision: GitHubPullRequestReviewDecision?
        switch row["reviewDecision"] as? String {
        case "APPROVED": decision = .approved
        case "CHANGES_REQUESTED": decision = .changesRequested
        case "REVIEW_REQUIRED": decision = .reviewRequired
        case "", nil: decision = nil
        default: decision = .unknown
        }
        return try .init(reference: .init(repository: repository, number: number), title: string(row, "title"), url: string(row, "url"),
            state: state, isDraft: isDraft, headBranch: string(row, "headRefName"), baseBranch: string(row, "baseRefName"),
            headCommit: string(row, "headRefOid"), baseCommit: string(row, "baseRefOid"), headRepository: headRepository,
            author: (row["author"] as? [String: Any])?["login"] as? String,
            updatedAt: date(row, "updatedAt"), reviewDecision: decision, checksState: checkState)
    }
    static func detail(_ data: Data, reference: GitHubPullRequestReference) throws -> GitHubPullRequestDetail {
        let row = try object(data), summary = try summary(row, repository: reference.repository)
        guard summary.reference == reference else { throw GitHubPullRequestError(.invalidResponse) }
        return try .init(summary: summary, body: string(row, "body"), createdAt: date(row, "createdAt"),
            additions: integer(row, "additions"), deletions: integer(row, "deletions"), changedFiles: integer(row, "changedFiles"),
            checks: checks(row), reviewers: (row["reviewRequests"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String ?? $0["name"] as? String },
            labels: (row["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
    }
    static func checks(_ row: [String: Any]) throws -> [GitHubPullRequestCheck] {
        guard let values = row["statusCheckRollup"] as? [[String: Any]] else { return [] }
        guard values.count <= 1_000 else { throw GitHubPullRequestError(.invalidResponse) }
        return try values.map { value in
            let name = value["name"] as? String ?? value["context"] as? String ?? "Check"
            let status = (value["status"] as? String ?? value["state"] as? String ?? "").uppercased()
            let conclusion = (value["conclusion"] as? String ?? "").uppercased()
            let state: GitHubPullRequestChecksState
            if ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion) || ["FAILURE", "ERROR"].contains(status) { state = .failure }
            else if ["PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"].contains(status) { state = .pending }
            else if conclusion == "SUCCESS" || status == "SUCCESS" { state = .success }
            else { state = .unknown }
            let rawURL = value["detailsUrl"] as? String ?? value["targetUrl"] as? String
            let url: String?
            if let rawURL, var c = URLComponents(string: rawURL), c.user == nil, c.password == nil {
                c.query = nil; c.fragment = nil
                url = (c.url?.absoluteString).flatMap { GitHubValidation.safeWebURL($0) ? $0 : nil }
            } else { url = nil }
            return try .init(name: name, state: state, url: url)
        }
    }
}
