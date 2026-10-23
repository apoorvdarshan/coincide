import AppKit
@testable import CoincideCore
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
        guard review.state.headCommit == state.headCommit, review.state.baseBranch == state.baseBranch,
              review.state.baseCommit == state.baseCommit else { throw GitHubPullRequestActionError(.staleReview) }
        performed.append(review.action)
        return .init(action: review.action, message: "\(review.action.title) finished.")
    }
}

@MainActor private func actionState(merged: Bool = false, canWrite: Bool = true, head: String = String(repeating: "a", count: 40),
                                   baseBranch: String = "main", baseCommit: String = String(repeating: "b", count: 40)) throws -> GitHubPullRequestActionState {
    let repository = try GitHubRepository(owner: "fixture", name: "native-pr")
    return try .init(reference: .init(repository: repository, number: 42), nodeID: "PR_fixture", title: "Native pull request", url: "https://github.com/fixture/native-pr/pull/42",
                     state: merged ? .merged : .open, isDraft: false, headBranch: "topic", baseBranch: baseBranch, headCommit: head, baseCommit: baseCommit, headRepository: repository,
                     isCrossRepository: false, mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", permissions: .init(push: canWrite),
                     mergeSettings: .init(allowRebaseMerge: false, allowAutoMerge: true))
}

private actor PullRequestActionUIBoundary {
    private var enteredValue = false, released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        enteredValue = true; observers.forEach { $0.resume() }; observers = []
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func entered() async { if !enteredValue { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

/// Controlled durable boundary for presentation tests. Native process, SQLite
/// deduplication and restart semantics are exercised by the Core Engine tests.
@MainActor private final class PullRequestActionUILedger {
    let peer: PullRequestActionPeer
    let projectID: UUID, threadID: UUID, path: String
    var operations: [PullRequestActionOperation] = []
    var began: [UUID] = [], inspected: [UUID] = [], acknowledged: [UUID] = [], discarded: [UUID] = []
    var beginGate: PullRequestActionUIBoundary?
    var beginWasCancelled = false
    init(peer: PullRequestActionPeer, fixture: PullRequestNativeFixture) {
        self.peer = peer; projectID = fixture.projectID; threadID = fixture.threadID; path = fixture.root.path
    }
    var support: PullRequestStore.ActionSupport {
        .init(prepare: { [self] in try await peer.reviewAction($0, reference: $1, removeAgentCredits: $2) },
              begin: { [self] in try await begin($0) },
              inspect: { [self] in try await inspect($0) },
              acknowledge: { [self] in acknowledge($0) },
              discard: { [self] in discarded.append($0) })
    }
    private func receipt(_ id: UUID, rejection: String? = nil) -> WorkspaceCommandReceipt {
        .init(commandID: id, sequence: Int64(began.count + inspected.count + acknowledged.count), eventCount: rejection == nil ? 1 : 0,
              acceptedAt: Date(timeIntervalSince1970: 1_800_000_000), rejection: rejection)
    }
    private func begin(_ review: GitHubPullRequestActionReview) async throws -> WorkspaceCommandReceipt {
        began.append(review.id)
        if let beginGate { self.beginGate = nil; await beginGate.pause() }
        beginWasCancelled = Task.isCancelled
        do {
            let outcome = try await peer.perform(review)
            operations.append(.init(projectID: projectID, projectPath: path, registeredWorkspacePath: path,
                repositoryPath: path, commonDirectoryPath: path + "/.git", sourceIncarnation: UUID(), sourceThreadID: threadID,
                review: review, phase: .succeeded, outcome: outcome))
            return receipt(review.id)
        } catch let error as GitHubPullRequestActionError where error.kind == .uncertain {
            operations.append(.init(projectID: projectID, projectPath: path, registeredWorkspacePath: path,
                repositoryPath: path, commonDirectoryPath: path + "/.git", sourceIncarnation: UUID(), sourceThreadID: threadID,
                review: review, phase: .unconfirmed, error: PullRequestActionOperation.unconfirmedMessage))
            throw error // The presentation did not receive the original admission result.
        } catch { return receipt(review.id, rejection: error.localizedDescription) }
    }
    private func inspect(_ id: UUID) async throws -> WorkspaceCommandReceipt {
        inspected.append(id)
        if let index = operations.firstIndex(where: { $0.id == id }) {
            let reference = operations[index].review.state.reference
            let state = try await peer.actionState(reference)
            operations[index].inspectedState = state
            operations[index].inspectedAt = Date()
        }
        return receipt(id)
    }
    private func acknowledge(_ id: UUID) -> WorkspaceCommandReceipt {
        acknowledged.append(id)
        if let index = operations.firstIndex(where: { $0.id == id }) { operations[index].acknowledgedAt = Date() }
        return receipt(id)
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func pullRequestActionStoreReviewsFreshStateAndRefreshesAfterEveryWrite() async throws {
    let f = try await PullRequestNativeFixture.make()
    do {
        let state = try actionState()
        let peer = PullRequestActionPeer(state: state)
        f.model.actionSession = peer
        let ledger = PullRequestActionUILedger(peer: peer, fixture: f)
        let actions = PullRequestActionStore(pullRequests: f.model, session: peer, support: ledger.support, operations: { ledger.operations })
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
        let uncertainReview = try #require(actions.review)
        await peer.setFailure(GitHubPullRequestActionError(.uncertain))
        await actions.perform()
        let performedAfterUncertain = await peer.performed
        let uncertainOperation = try #require(actions.operations.first { $0.id == uncertainReview.id })
        #expect(uncertainOperation.phase == .unconfirmed && uncertainOperation.requiresAcknowledgment)
        #expect(uncertainOperation.outcome == nil && uncertainOperation.error == PullRequestActionOperation.unconfirmedMessage)
        #expect(actions.isBusy && actions.actionError != nil && performedAfterUncertain == [.merge(.squash)])
        // Read-only accounts get no actions.
        await peer.setState(try actionState(canWrite: false))
        await actions.load(state.reference)
        #expect(actions.state?.availableActions.isEmpty == true)
        await actions.prepare(.close, removeAgentCredits: false)
        #expect(actions.review == nil && actions.actionError != nil)
        await actions.shutdown()
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test func pullRequestActionViewsFitDetailAndConfirmationSheetsInBothAppearances() async throws {
    _ = NSApplication.shared
    let f = try await PullRequestNativeFixture.make()
    do {
        let state = try actionState()
        let peer = PullRequestActionPeer(state: state)
        let ledger = PullRequestActionUILedger(peer: peer, fixture: f)
        let actions = PullRequestActionStore(pullRequests: f.model, session: peer, support: ledger.support, operations: { ledger.operations })
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
        await actions.shutdown()
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func pullRequestActionPresentationCloseJoinsTheOriginalAcceptedIntentAndReopenReadsItsResult() async throws {
    let f = try await PullRequestNativeFixture.make()
    let peer = PullRequestActionPeer(state: try actionState()), gate = PullRequestActionUIBoundary()
    let ledger = PullRequestActionUILedger(peer: peer, fixture: f); ledger.beginGate = gate
    let actions = PullRequestActionStore(pullRequests: f.model, session: peer, support: ledger.support, operations: { ledger.operations })
    do {
        let state = await peer.state
        await actions.load(state.reference); await actions.prepare(.merge(.squash), removeAgentCredits: false)
        let review = try #require(actions.review)
        let accepted = Task { await actions.perform() }; await gate.entered()
        #expect(actions.isPerforming && ledger.began == [review.id])
        var closed = false
        let close = Task { await actions.shutdown(); closed = true }
        await Task.yield()
        #expect(!closed && !ledger.discarded.contains(review.id))
        accepted.cancel(); await gate.release(); await accepted.value; await close.value
        #expect(closed && !ledger.beginWasCancelled && ledger.began == [review.id])
        #expect(ledger.operations.first?.id == review.id && ledger.operations.first?.phase == .succeeded)
        #expect(await peer.performed == [.merge(.squash)])
        let reopened = PullRequestActionStore(pullRequests: f.model, session: peer, support: ledger.support, operations: { ledger.operations })
        await reopened.load(state.reference)
        #expect(reopened.lastOutcome?.action == .merge(.squash) && reopened.operations.first?.id == review.id)
        await reopened.perform()
        #expect(ledger.began == [review.id])
        await reopened.shutdown()
    } catch { await gate.release(); await actions.shutdown(); await f.finish(); throw error }
    await actions.shutdown(); await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func pullRequestActionUnknownReceiptReopensAsTheSameIntentAndInspectionNeverBeginsItAgain() async throws {
    let f = try await PullRequestNativeFixture.make()
    let peer = PullRequestActionPeer(state: try actionState())
    let ledger = PullRequestActionUILedger(peer: peer, fixture: f)
    let actions = PullRequestActionStore(pullRequests: f.model, session: peer, support: ledger.support, operations: { ledger.operations })
    do {
        let state = await peer.state
        await actions.load(state.reference); await actions.prepare(.close, removeAgentCredits: false)
        let review = try #require(actions.review)
        await peer.setFailure(GitHubPullRequestActionError(.uncertain)); await actions.perform()
        #expect(actions.pendingIsUnconfirmed && ledger.began == [review.id])
        #expect(ledger.operations.first?.phase == .unconfirmed && ledger.operations.first?.requiresAcknowledgment == true)
        let prepared = await peer.reviews
        await actions.prepare(.close, removeAgentCredits: false)
        #expect(await peer.reviews == prepared)
        await actions.shutdown()
        let reopened = PullRequestActionStore(pullRequests: f.model, session: peer, support: ledger.support, operations: { ledger.operations })
        await reopened.load(state.reference); await reopened.prepare(.close, removeAgentCredits: false)
        #expect(reopened.operations.first?.id == review.id && reopened.review == nil && ledger.began == [review.id])
        #expect(await peer.reviews == prepared)
        await reopened.inspect(review.id)
        #expect(ledger.inspected == [review.id] && ledger.began == [review.id])
        #expect(reopened.operations.first?.phase == .unconfirmed && reopened.operations.first?.outcome == nil)
        await reopened.acknowledge(review.id)
        #expect(ledger.acknowledged == [review.id] && reopened.operations.first?.requiresAcknowledgment == false)
        await reopened.prepare(.close, removeAgentCredits: false)
        let fresh = try #require(reopened.review)
        #expect(fresh.id != review.id && ledger.began == [review.id])
        reopened.discardReview(); await reopened.shutdown()
        #expect(ledger.discarded.contains(fresh.id) && !ledger.discarded.contains(review.id))
    } catch { await actions.shutdown(); await f.finish(); throw error }
    await actions.shutdown(); await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["ownership", "root", "collision", "stale", "rejected-receipt", "lost-reply", "cancelled"])
func pullRequestActionKnownAdmissionRefusalAllowsAFreshReviewWhileMissingRepliesNeverReplay(mode: String) async throws {
    let f = try await PullRequestNativeFixture.make()
    let peer = PullRequestActionPeer(state: try actionState())
    let ledger = PullRequestActionUILedger(peer: peer, fixture: f)
    let base = ledger.support
    let support = PullRequestStore.ActionSupport(prepare: base.prepare, begin: { review in
        ledger.began.append(review.id)
        switch mode {
        case "ownership": throw WorkspaceCommandError("The registered workspace changed. Review it again.")
        case "root": throw TaskIsolationError.changedRepository
        case "collision": throw WorkspaceCommitError.commandIDCollision
        case "stale": throw GitHubPullRequestActionError(.staleReview)
        case "rejected-receipt":
            return WorkspaceCommandReceipt(commandID: review.id, sequence: 0, eventCount: 0, acceptedAt: Date(),
                rejection: "The head changed before admission. Review it again.")
        case "cancelled": throw CancellationError()
        default: throw CocoaError(.fileReadUnknown)
        }
    }, inspect: base.inspect, acknowledge: base.acknowledge, discard: base.discard)
    let actions = PullRequestActionStore(pullRequests: f.model, session: peer, support: support, operations: { ledger.operations })
    do {
        let state = await peer.state
        await actions.load(state.reference); await actions.prepare(.close, removeAgentCredits: false)
        let original = try #require(actions.review)
        await actions.perform()
        #expect(ledger.began == [original.id] && actions.review == nil && actions.actionError != nil)
        #expect(await peer.performed.isEmpty)
        let unknown = mode == "lost-reply" || mode == "cancelled"
        #expect(actions.pendingIsUnconfirmed == unknown)
        #expect((actions.unresolvedPending?.id == original.id) == unknown)
        await actions.prepare(.close, removeAgentCredits: false)
        if unknown {
            #expect(actions.review == nil && actions.isBusy)
        } else {
            let fresh = try #require(actions.review)
            #expect(fresh.id != original.id && !actions.isBusy)
            actions.discardReview()
        }
        #expect(ledger.began == [original.id])
        await actions.shutdown()
    } catch { await actions.shutdown(); await f.finish(); throw error }
    await f.finish()
}
