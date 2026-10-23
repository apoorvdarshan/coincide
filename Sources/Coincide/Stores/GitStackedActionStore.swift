import CoincideCore
import Foundation
import Observation

/// Runs T3's stacked Commit / Push / Create PR as one reviewed sequence. Local Git steps share the
/// inspector's single exclusive operation; PR creation then reuses the durable reviewed engine path
/// and only proceeds when the reviewed head is exactly the commit this run pushed.
@MainActor @Observable
final class GitStackedActionStore {
    enum Phase: String, CaseIterable, Identifiable {
        case featureBranch, stage, commit, push, pullRequest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .featureBranch: String(localized: "Create feature branch")
            case .stage: String(localized: "Stage selected files")
            case .commit: String(localized: "Commit")
            case .push: String(localized: "Push")
            case .pullRequest: String(localized: "Create pull request")
            }
        }
    }
    enum PhaseState: Equatable { case pending, running, done, failed }
    struct Plan: Equatable {
        var action: GitStackedAction
        var featureBranch: String? = nil
        /// Files to commit. Empty commits the staged index as it is.
        var paths: [String] = []
        var commitMessage = ""
        var remote: String? = nil
        var remoteBranch: String? = nil
        var pullRequestTitle = ""
        var pullRequestBody = ""
        var pullRequestBase: String? = nil
        var pullRequestDraft = false
        var phases: [Phase] {
            var result: [Phase] = []
            if featureBranch != nil { result.append(.featureBranch) }
            if action.includesCommit { if !paths.isEmpty { result.append(.stage) }; result.append(.commit) }
            if action.includesPush { result.append(.push) }
            if action.includesPullRequest { result.append(.pullRequest) }
            return result
        }
    }
    enum Outcome: Equatable {
        case finished(String)
        case failed(String)
        case cancelled
        /// The pushed head no longer matches; creation needs the normal reviewed sheet.
        case needsPullRequestReview(String)
    }

    let inspector: GitInspectorStore
    let pullRequests: PullRequestStore
    var messageGenerator: (any GitCommitMessageGenerating)?
    private(set) var plan: Plan?
    private(set) var states: [Phase: PhaseState] = [:]
    private(set) var isRunning = false
    private(set) var outcome: Outcome?
    private(set) var lastOutput: String?
    private(set) var phaseStartedAt: Date?
    private(set) var pullRequest: GitHubPullRequestSummary?
    private(set) var isGenerating = false
    private(set) var generationError: String?
    private var cancelled = false
    private var task: Task<Void, Never>?
    /// How long to wait for the durable engine to settle a dispatched creation before handing off.
    var creationWait: Duration = .seconds(120)

    init(inspector: GitInspectorStore, pullRequests: PullRequestStore, messageGenerator: (any GitCommitMessageGenerating)? = nil) {
        self.inspector = inspector; self.pullRequests = pullRequests; self.messageGenerator = messageGenerator
    }

    var currentPhase: Phase? { plan?.phases.first { states[$0] == .running } }

    /// Fills an editable message only; nothing is committed until the person starts the action.
    func generateMessage(paths: [String]) async -> String? {
        guard let messageGenerator, let snapshot = inspector.snapshot, !isGenerating else { return nil }
        isGenerating = true; generationError = nil
        defer { isGenerating = false }
        do {
            return try await messageGenerator.commitMessage(for: .init(repositoryPath: snapshot.repositoryRoot.path, branch: snapshot.branch, paths: paths))
        } catch { generationError = error.localizedDescription; return nil }
    }

    @discardableResult
    func run(_ plan: Plan) -> Bool {
        guard !isRunning, !inspector.isBusy else { return false }
        self.plan = plan; outcome = nil; lastOutput = nil; pullRequest = nil; cancelled = false
        states = Dictionary(uniqueKeysWithValues: plan.phases.map { ($0, PhaseState.pending) })
        isRunning = true
        task = Task { [weak self] in
            await self?.execute(plan)
            self?.isRunning = false; self?.task = nil
        }
        return true
    }
    func cancel() {
        guard isRunning else { return }
        cancelled = true
        if inspector.operationName != nil { inspector.cancel() }
    }
    func waitForCompletion() async { await task?.value }
    func reset() { guard !isRunning else { return }; plan = nil; states = [:]; outcome = nil; lastOutput = nil; pullRequest = nil }

    private func mark(_ phase: Phase, _ state: PhaseState) {
        states[phase] = state
        if state == .running { phaseStartedAt = Date(); lastOutput = nil }
    }
    private func report(_ line: String) {
        guard isRunning else { return }
        lastOutput = line; inspector.updateOperation(detail: line)
    }

    @MainActor private final class LocalResult { var pushedHead: String?; var failure: String? }

    private func execute(_ plan: Plan) async {
        let result = LocalResult()
        let git = inspector.git
        let snapshot = inspector.snapshot
        let selected = Set(plan.paths)
        let stagedElsewhere = snapshot?.changes.contains { $0.isStaged && !selected.contains($0.path) } ?? false
        let commitPaths = plan.paths + (snapshot?.changes.filter { selected.contains($0.path) }.compactMap(\.previousPath) ?? [])
        let local = inspector.runExclusive(String(localized: "Starting source control action…")) { [weak self] in
            guard let self else { return }
            var phase: Phase?
            do {
                if let feature = plan.featureBranch {
                    phase = .featureBranch; self.mark(.featureBranch, .running); self.inspector.updateOperation(name: String(localized: "Creating \(feature)…"), detail: nil)
                    try await git.createBranch(feature); self.mark(.featureBranch, .done)
                }
                if plan.action.includesCommit {
                    if !plan.paths.isEmpty {
                        phase = .stage; self.mark(.stage, .running); self.inspector.updateOperation(name: String(localized: "Staging…"), detail: nil)
                        try await git.stage(plan.paths); self.mark(.stage, .done)
                    }
                    try self.checkCancelled()
                    phase = .commit; self.mark(.commit, .running); self.inspector.updateOperation(name: String(localized: "Committing… (running hooks)"), detail: nil)
                    try await git.commit(message: plan.commitMessage, only: !plan.paths.isEmpty && stagedElsewhere ? commitPaths : nil) { line in
                        Task { @MainActor in self.report(line) }
                    }
                    self.mark(.commit, .done)
                }
                if plan.action.includesPush {
                    try self.checkCancelled()
                    phase = .push; self.mark(.push, .running)
                    let status = try await git.status()
                    guard !status.isDetached, !status.isUnborn, let head = status.head else { throw CoincideError("Switch to a branch with a commit before pushing.") }
                    let upstream = try await git.upstream(for: status.branch)
                    let remotes = try await git.remotes()
                    guard let remote = upstream?.remote ?? plan.remote ?? (remotes.contains("origin") ? "origin" : remotes.first) else { throw CoincideError("Add a Git remote before pushing.") }
                    let destination = upstream?.branch ?? plan.remoteBranch ?? status.branch
                    self.inspector.updateOperation(name: String(localized: "Pushing to \(remote)/\(destination)…"), detail: nil)
                    try await git.push(branch: status.branch, remote: remote, remoteBranch: destination, setUpstream: upstream == nil)
                    result.pushedHead = head; self.mark(.push, .done)
                }
            } catch {
                if let phase { self.mark(phase, .failed) }
                result.failure = error is CancellationError ? nil : error.localizedDescription
                if error is CancellationError { self.cancelled = true }
                throw error
            }
        }
        guard let local else { outcome = .failed(String(localized: "Another source control action is running.")); return }
        await local.value
        if cancelled { outcome = .cancelled; return }
        if let failure = result.failure { outcome = .failed(failure); return }
        let pushedHead = result.pushedHead
        guard plan.action.includesPullRequest else {
            outcome = .finished(plan.action.includesPush ? String(localized: "Pushed \(pushedHead.map { String($0.prefix(10)) } ?? "")") : String(localized: "Committed"))
            return
        }
        mark(.pullRequest, .running)
        await pullRequests.refresh()
        if let existing = pullRequests.context?.existingPullRequest {
            pullRequest = existing; mark(.pullRequest, .done)
            outcome = .finished(String(localized: "Opened existing pull request #\(existing.reference.number)")); return
        }
        do {
            let review = try await pullRequests.prepareCreation(title: plan.pullRequestTitle, body: plan.pullRequestBody, baseBranch: plan.pullRequestBase, isDraft: plan.pullRequestDraft)
            guard review.context.headCommit == pushedHead, review.context.upstream?.commit == pushedHead,
                  review.title == plan.pullRequestTitle, review.body == plan.pullRequestBody,
                  review.isDraft == plan.pullRequestDraft, plan.pullRequestBase.map({ $0 == review.baseBranch }) ?? true else {
                await pullRequests.discardReview(review.id); mark(.pullRequest, .failed)
                outcome = .needsPullRequestReview(String(localized: "The published branch no longer matches the commit this action pushed. Review the pull request before creating it.")); return
            }
            if cancelled { await pullRequests.discardReview(review.id); mark(.pullRequest, .failed); outcome = .cancelled; return }
            try await pullRequests.create(review)
            let deadline = ContinuousClock.now + creationWait
            while pullRequests.operation?.id == review.id, pullRequests.operation?.isWorking == true, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let operation = pullRequests.operation, operation.id == review.id else {
                mark(.pullRequest, .failed); outcome = .needsPullRequestReview(String(localized: "Open Pull Requests to inspect this creation.")); return
            }
            switch operation.result {
            case .created(let detail):
                pullRequest = detail.summary; mark(.pullRequest, .done); outcome = .finished(String(localized: "Created pull request #\(detail.summary.reference.number)"))
            case .openedExisting(let detail):
                pullRequest = detail.summary; mark(.pullRequest, .done); outcome = .finished(String(localized: "Opened existing pull request #\(detail.summary.reference.number)"))
            case nil:
                mark(.pullRequest, operation.isWorking ? .running : .failed)
                outcome = operation.isWorking ? .finished(String(localized: "Pull request creation is still in progress. Open Pull Requests to follow it."))
                    : .needsPullRequestReview(operation.error ?? PullRequestCreationOperation.unconfirmedMessage)
            }
        } catch is CancellationError {
            mark(.pullRequest, .failed); outcome = .cancelled
        } catch let error as GitHubPullRequestError where [.notPublished, .staleReview].contains(error.kind) {
            mark(.pullRequest, .failed)
            outcome = .needsPullRequestReview(String(localized: "The published branch no longer matches the commit this action pushed. Review the pull request before creating it."))
        } catch {
            mark(.pullRequest, .failed); outcome = .failed(PullRequestPresentation.error(error))
        }
    }
    private func checkCancelled() throws { if cancelled { throw CancellationError() } }
}
