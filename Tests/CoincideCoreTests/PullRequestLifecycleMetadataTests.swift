import Foundation
import Testing
@testable import CoincideCore

private let lifecyclePRUpdatedAt = Date(timeIntervalSince1970: 1_700_100_000)
private func lifecyclePRSummary(state: GitHubPullRequestState, closedAt: Date? = nil, mergedAt: Date? = nil) throws -> GitHubPullRequestSummary {
    try .init(reference: .init(repository: .init(owner: "owned-fixture", name: "repository"), number: 42),
        title: "Lifecycle terminal-date fixture", url: "https://github.com/owned-fixture/repository/pull/42", state: state,
        headBranch: "feature/topic", baseBranch: "main", headCommit: String(repeating: "a", count: 40),
        baseCommit: String(repeating: "b", count: 40), updatedAt: lifecyclePRUpdatedAt, closedAt: closedAt, mergedAt: mergedAt)
}
private func lifecyclePRNativeRow(state: String) -> [String: Any] {
    ["number": 42, "title": "Lifecycle terminal-date fixture", "url": "https://github.com/owned-fixture/repository/pull/42",
     "state": state, "isDraft": false, "headRefName": "feature/topic", "baseRefName": "main",
     "headRefOid": String(repeating: "a", count: 40), "baseRefOid": String(repeating: "b", count: 40),
     "isCrossRepository": false, "updatedAt": "2023-11-16T02:00:00Z"]
}

@Test(arguments: [GitHubPullRequestState.open, .closed, .merged])
func pullRequestLifecycleMetadataLegacyMissingDatesStayUnknownAndCodecRemainsFlat(state: GitHubPullRequestState) throws {
    let original = try lifecyclePRSummary(state: state)
    let data = try JSONEncoder().encode(original)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let flat = try #require(object)
    #expect(flat["closedAt"] == nil && flat["mergedAt"] == nil)
    #expect(flat["terminalDates"] == nil && flat["storage"] == nil)
    #expect(flat["title"] as? String == original.title && flat["state"] as? String == state.rawValue)
    let decoded = try JSONDecoder().decode(GitHubPullRequestSummary.self, from: data)
    #expect(decoded == original && decoded.closedAt == nil && decoded.mergedAt == nil)
    #expect(decoded.updatedAt == lifecyclePRUpdatedAt, "Unknown terminal dates must not be invented from updatedAt.")
    var explicitNulls = flat; explicitNulls["closedAt"] = NSNull(); explicitNulls["mergedAt"] = NSNull()
    let withNulls = try JSONSerialization.data(withJSONObject: explicitNulls)
    #expect(try JSONDecoder().decode(GitHubPullRequestSummary.self, from: withNulls) == original)
}

@Test(arguments: [false, true])
func pullRequestLifecycleMetadataNativeClosedAndMergedDatesSurviveRoundTrip(merged: Bool) throws {
    let repository = try GitHubRepository(owner: "owned-fixture", name: "repository")
    let terminal = Date(timeIntervalSince1970: 1_700_000_000.125)
    var native = lifecyclePRNativeRow(state: merged ? "MERGED" : "CLOSED")
    native["closedAt"] = "2023-11-14T22:13:20.125Z"
    if merged { native["mergedAt"] = "2023-11-14T22:13:20.125Z" }
    else { native["mergedAt"] = NSNull() }
    let parsed = try GitHubPullRequestJSON.summary(native, repository: repository)
    #expect(parsed.state == (merged ? .merged : .closed) && parsed.closedAt == terminal)
    #expect(parsed.mergedAt == (merged ? terminal : nil))
    #expect(parsed.closedAt != parsed.updatedAt)
    let encoded = try JSONEncoder().encode(parsed)
    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    let flat = try #require(object)
    #expect(flat["closedAt"] is NSNumber && flat["terminalDates"] == nil)
    #expect((flat["mergedAt"] != nil) == merged)
    #expect(try JSONDecoder().decode(GitHubPullRequestSummary.self, from: encoded) == parsed)
    let fields = GitHubPullRequestJSON.fields.split(separator: ",")
    #expect(fields.filter { $0 == "closedAt" }.count == 1 && fields.filter { $0 == "mergedAt" }.count == 1)
}

@Test func pullRequestLifecycleMetadataRejectsMalformedNativeDatesAndNonfiniteCapturedDates() throws {
    let repository = try GitHubRepository(owner: "owned-fixture", name: "repository")
    let invalid: [Any] = ["not-a-date", "", 1_700_000_000, true, ["unexpected"], ["unexpected": "object"]]
    for key in ["closedAt", "mergedAt"] {
        for value in invalid {
            var native = lifecyclePRNativeRow(state: "MERGED"); native[key] = value
            #expect(throws: GitHubPullRequestError.self) { _ = try GitHubPullRequestJSON.summary(native, repository: repository) }
        }
    }
    for interval in [Double.nan, .infinity, -.infinity] {
        #expect(throws: GitHubPullRequestError.self) {
            _ = try lifecyclePRSummary(state: .closed, closedAt: Date(timeIntervalSince1970: interval))
        }
        #expect(throws: GitHubPullRequestError.self) {
            _ = try lifecyclePRSummary(state: .merged, mergedAt: Date(timeIntervalSince1970: interval))
        }
    }
    let valid = try lifecyclePRSummary(state: .merged, mergedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let encoded = try JSONEncoder().encode(valid)
    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    var malformed = try #require(object); malformed["mergedAt"] = "unexpected-date-codec"
    let malformedData = try JSONSerialization.data(withJSONObject: malformed)
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(GitHubPullRequestSummary.self, from: malformedData) }
}

@Test func pullRequestLifecycleMetadataRejectsOpenTerminalClaimsAndClosedMergeClaimsOnNativeAndStoredReads() throws {
    let terminal = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(throws: GitHubPullRequestError.self) { _ = try lifecyclePRSummary(state: .open, closedAt: terminal) }
    #expect(throws: GitHubPullRequestError.self) { _ = try lifecyclePRSummary(state: .open, mergedAt: terminal) }
    #expect(throws: GitHubPullRequestError.self) { _ = try lifecyclePRSummary(state: .closed, mergedAt: terminal) }
    let repository = try GitHubRepository(owner: "owned-fixture", name: "repository")
    for state in ["OPEN", "CLOSED"] {
        var native = lifecyclePRNativeRow(state: state); native["mergedAt"] = "2023-11-14T22:13:20Z"
        #expect(throws: GitHubPullRequestError.self) { _ = try GitHubPullRequestJSON.summary(native, repository: repository) }
    }
    var openWithClosedAt = lifecyclePRNativeRow(state: "OPEN"); openWithClosedAt["closedAt"] = "2023-11-14T22:13:20Z"
    #expect(throws: GitHubPullRequestError.self) { _ = try GitHubPullRequestJSON.summary(openWithClosedAt, repository: repository) }
    let merged = try lifecyclePRSummary(state: .merged, closedAt: terminal, mergedAt: terminal)
    let encoded = try JSONEncoder().encode(merged)
    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    let flat = try #require(object)
    for state in ["open", "closed"] {
        var forged = flat; forged["state"] = state
        let data = try JSONSerialization.data(withJSONObject: forged)
        #expect(throws: GitHubPullRequestError.self) { _ = try JSONDecoder().decode(GitHubPullRequestSummary.self, from: data) }
    }
}
