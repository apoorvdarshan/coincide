import CoincideCore
import Foundation
import Observation

/// Merge and state actions for the pull request shown in detail. Every write starts from an
/// explicit review of a fresh state read; uncertain writes are reported and never repeated.
@MainActor @Observable
final class PullRequestActionStore {
    let pullRequests: PullRequestStore
    let session: (any GitHubPullRequestActionSession)?
    private(set) var reference: GitHubPullRequestReference?
    private(set) var state: GitHubPullRequestActionState?
    private(set) var stateError: String?
    private(set) var isLoadingState = false
    private(set) var review: GitHubPullRequestActionReview?
    private(set) var isReviewing = false
    private(set) var isPerforming = false
    private(set) var actionError: String?
    private(set) var lastOutcome: GitHubPullRequestActionOutcome?
    private var generation = UUID()
    private var closed = false
    var isBusy: Bool { isReviewing || isPerforming || pullRequests.isBusy }
    var isAvailable: Bool { session != nil }

    init(pullRequests: PullRequestStore, session: (any GitHubPullRequestActionSession)?) {
        self.pullRequests = pullRequests; self.session = session
    }

    func load(_ reference: GitHubPullRequestReference) async {
        guard let session, !closed, pullRequests.canReadActions else { return }
        if self.reference != reference { state = nil; review = nil; lastOutcome = nil; actionError = nil }
        self.reference = reference
        let id = UUID(); generation = id; isLoadingState = true; stateError = nil
        defer { if generation == id { isLoadingState = false } }
        do {
            let value = try await session.actionState(reference)
            guard generation == id, !closed, self.reference == reference else { return }
            state = value
        } catch is CancellationError { }
        catch { if generation == id, !closed { state = nil; stateError = Self.message(error) } }
    }

    /// Reads fresh state, verifies the action is still offered, and captures the exact head for review.
    func prepare(_ action: GitHubPullRequestAction, removeAgentCredits: Bool) async {
        guard let session, let reference, !isBusy, !closed, pullRequests.canReadActions else { return }
        isReviewing = true; actionError = nil
        defer { isReviewing = false }
        do {
            let value = try await session.reviewAction(action, reference: reference, removeAgentCredits: removeAgentCredits)
            guard !closed, self.reference == reference else { return }
            state = value.state; review = value
        } catch { if !closed { review = nil; actionError = Self.message(error) } }
    }
    func discardReview() { if !isPerforming { review = nil } }

    func perform() async {
        guard let session, let review, !isPerforming, !closed, pullRequests.canReadActions else { return }
        isPerforming = true; actionError = nil
        defer { isPerforming = false }
        do {
            let outcome = try await session.perform(review)
            guard !closed else { return }
            lastOutcome = outcome; self.review = nil
        } catch {
            guard !closed else { return }
            actionError = Self.message(error)
            // A stale review is discarded; the person reviews the fresh state again.
            self.review = nil
        }
        // Always read the actual result, including after an uncertain write.
        let reference = review.state.reference
        await load(reference)
        await pullRequests.select(reference)
        await pullRequests.refresh()
    }
    func dismissOutcome() { lastOutcome = nil; actionError = nil }
    func close() { closed = true; generation = UUID() }

    static func message(_ error: any Error) -> String {
        if let error = error as? GitHubPullRequestActionError { return error.localizedDescription }
        if let error = error as? GitHubPullRequestError { return error.localizedDescription }
        if error is CancellationError { return String(localized: "Cancelled. Refresh to inspect the current pull request state.") }
        return String(localized: "The pull request action could not finish. Refresh and check its current state.")
    }
}

/// Preferences for source-control actions, stored with the app's other native preferences.
enum SourceControlPreferenceKeys {
    static let removeAgentCredits = "sourceControl.removeAgentCreditsWhenMerging"
    static let mergeMethod = "sourceControl.preferredMergeMethod"
    static let fetchInterval = "sourceControl.automaticFetchInterval"
    static let autoPullDefault = "sourceControl.autoPullDefaultBranch"
    static let autoPullOverrides = "sourceControl.autoPullProjectOverrides"
}
