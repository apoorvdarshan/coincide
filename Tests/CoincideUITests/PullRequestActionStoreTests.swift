import AppKit
import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

actor PullRequestActionPeer: GitHubPullRequestActionSession {
    var state: GitHubPullRequestActionState
    private(set) var performed: [GitHubPullRequestAction] = []
    private(set) var reviews = 0
    var failure: (any Error)?
    init(state: GitHubPullRequestActionState) { self.state = state }
    func setFailure(_ error: (any Error)?) { failure = error }
    func setState(_ value: GitHubPullRequestActionState) { state = value }
    func actionState(_ reference: GitHubPullRequestReference) throws -> GitHubPullRequestActionState { state }
    func reviewAction(_ action: GitHubPullRequestAction, reference: GitHubPullRequestReference, removeAgentCredits: Bool) throws -> GitHubPullRequestActionReview {
        reviews += 1
        guard state.availableActions.contains(action) else { throw GitHubPullRequestActionError(.unavailable) }
        return .init(action: action, state: state, mergeBody: removeAgentCredits && action.supportsMergeBody ? "Cleaned body" : nil, originalMergeBody: removeAgentCredits ? "Original" : nil)
    }
    func perform(_ review: GitHubPullRequestActionReview) throws -> GitHubPullRequestActionOutcome {
        if let failure { self.failure = nil; throw failure }
        guard review.state.headCommit == state.headCommit else { throw GitHubPullRequestActionError(.staleReview) }
        performed.append(review.action)
        return .init(action: review.action, message: "\(review.action.title) finished.")
    }
}

@MainActor private func actionState(merged: Bool = false, canWrite: Bool = true, head: String = String(repeating: "a", count: 40)) throws -> GitHubPullRequestActionState {
    let repository = try GitHubRepository(owner: "fixture", name: "native-pr")
    return try .init(reference: .init(repository: repository, number: 42), nodeID: "PR_fixture", title: "Native pull request", url: "https://github.com/fixture/native-pr/pull/42",
                     state: merged ? .merged : .open, isDraft: false, headBranch: "topic", baseBranch: "main", headCommit: head, headRepository: repository,
                     isCrossRepository: false, mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", permissions: .init(push: canWrite),
                     mergeSettings: .init(allowRebaseMerge: false, allowAutoMerge: true))
}

@MainActor @Test(.timeLimit(.minutes(1))) func pullRequestActionStoreReviewsFreshStateAndRefreshesAfterEveryWrite() async throws {
    let f = try await PullRequestNativeFixture.make()
    do {
        let state = try actionState()
        let peer = PullRequestActionPeer(state: state)
        f.model.actionSession = peer
        let actions = PullRequestActionStore(pullRequests: f.model, session: peer)
        await actions.load(state.reference)
        #expect(actions.state == state && actions.state?.availableActions.prefix(2) == [.merge(.merge), .merge(.squash)])
        #expect(state.warning(for: .merge(.squash))?.contains("Required reviews") == true && state.warning(for: .close) == nil)
        await actions.prepare(.merge(.squash), removeAgentCredits: true)
        #expect(actions.review?.mergeBody == "Cleaned body" && actions.review?.state.headCommit == state.headCommit)
        await actions.perform()
        #expect(actions.lastOutcome?.action == .merge(.squash) && actions.review == nil && actions.actionError == nil)
        #expect(await peer.performed == [.merge(.squash)])
        // The head moves after review: the write is refused and the review discarded, never retried.
        await actions.prepare(.close, removeAgentCredits: false)
        await peer.setState(try actionState(head: String(repeating: "b", count: 40)))
        await actions.perform()
        #expect(actions.actionError?.contains("changed after you reviewed") == true && actions.review == nil && actions.state?.headCommit == String(repeating: "b", count: 40))
        #expect(await peer.performed == [.merge(.squash)])
        // An uncertain outcome is reported and the state is read again.
        await actions.prepare(.close, removeAgentCredits: false)
        await peer.setFailure(GitHubPullRequestActionError(.uncertain))
        await actions.perform()
        let performedAfterUncertain = await peer.performed
        #expect(actions.actionError?.contains("not repeated") == true && performedAfterUncertain == [.merge(.squash)])
        // Read-only accounts get no actions.
        await peer.setState(try actionState(canWrite: false))
        await actions.load(state.reference)
        #expect(actions.state?.availableActions.isEmpty == true)
        await actions.prepare(.close, removeAgentCredits: false)
        #expect(actions.review == nil && actions.actionError != nil)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test func pullRequestActionViewsFitDetailAndConfirmationSheetsInBothAppearances() async throws {
    _ = NSApplication.shared
    let f = try await PullRequestNativeFixture.make()
    do {
        let state = try actionState()
        let peer = PullRequestActionPeer(state: state)
        let actions = PullRequestActionStore(pullRequests: f.model, session: peer)
        await actions.load(state.reference)
        await actions.prepare(.merge(.squash), removeAgentCredits: true)
        let review = try #require(actions.review)
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(340), 600] {
                let bar = NSHostingController(rootView: PullRequestActionBar(actions: actions, reference: state.reference).environment(\.colorScheme, scheme).frame(width: width))
                #expect(bar.sizeThatFits(in: CGSize(width: width, height: 400)).width <= width + 1)
                let sheet = NSHostingController(rootView: PullRequestActionSheet(actions: actions, review: review, removeAgentCredits: .constant(true))
                    .environment(\.colorScheme, scheme).frame(width: max(width, 360)))
                let size = sheet.sizeThatFits(in: CGSize(width: max(width, 360), height: 700))
                #expect(size.width <= max(width, 360) + 1 && size.height <= 701)
            }
        }
    } catch { await f.finish(); throw error }
    await f.finish()
}
