import CoincideCore
import SwiftUI

struct PullRequestCheckoutView: View {
    let model: PullRequestStore
    let reference: GitHubPullRequestReference
    @State private var mode = GitHubPullRequestCheckoutMode.worktree
    @State private var submodules = ProjectWorktreeSubmoduleMode.none
    @State private var reviewSetup = true
    @State private var review: PullRequestCheckoutReview?
    @State private var error: String?
    @State private var preparationTask: Task<Void, Never>?

    private var summary: GitHubPullRequestSummary? {
        model.detail?.summary.reference == reference ? model.detail?.summary : nil
    }
    private var showingOperation: Bool {
        guard let operation = model.checkoutOperation else { return false }
        return operation.locksSource || (operation.phase == .completed && operation.id == review?.id)
    }
    var body: some View {
        Group {
            if showingOperation {
                ScrollView { PullRequestCheckoutOperationView(model: model).padding(20) }
            } else {
                PullRequestCheckoutContent(reference: reference, summary: summary, review: review,
                    mode: $mode, submodules: $submodules, reviewSetup: $reviewSetup,
                    busy: model.isBusy, canPrepare: model.canCheckout, error: model.actionError ?? error,
                    edit: clearReview, prepare: prepare, checkout: checkout)
            }
        }
        .onChange(of: model.context?.sourceFingerprint) { old, value in
            guard old != nil, old != value, let review, !model.isMutating,
                  model.checkoutOperation?.id != review.id else { return }
            clearReview(); error = String(localized: "The source checkout changed. Review the current checkout again before continuing.")
        }
        .onChange(of: model.checkoutOperation?.phase) {
            guard let operation = model.checkoutOperation, operation.id == review?.id, operation.phase == .failed else { return }
            clearReview(); error = operation.error
        }
        .onChange(of: model.checkoutOperation?.acknowledgedAt) {
            guard model.checkoutOperation?.id == review?.id, model.checkoutOperation?.acknowledgedAt != nil else { return }
            clearReview()
        }
        .onDisappear {
            preparationTask?.cancel()
            if let review { Task { await model.discardCheckoutReview(review.id) } }
        }
    }
    private func clearReview() {
        if let review { Task { await model.discardCheckoutReview(review.id) } }
        review = nil; error = nil
    }
    private func prepare() {
        guard !model.isBusy, model.canCheckout else { return }
        error = nil
        let selectedMode = mode, selectedSubmodules = mode == .local ? .none : submodules
        let selectedSetup = mode == .worktree && reviewSetup
        preparationTask = Task {
            defer { preparationTask = nil }
            do {
                let value = try await model.prepareCheckout(reference: reference, mode: selectedMode,
                    submodules: selectedSubmodules, reviewSetup: selectedSetup)
                guard !Task.isCancelled else { await model.discardCheckoutReview(value.id); return }
                guard mode == selectedMode, (mode == .local ? .none : submodules) == selectedSubmodules,
                      (mode == .worktree && reviewSetup) == selectedSetup else {
                    await model.discardCheckoutReview(value.id)
                    error = String(localized: "The checkout choices changed while being checked. Review the current choices again.")
                    return
                }
                review = value
            } catch is CancellationError { }
            catch { self.error = PullRequestCheckoutPresentation.error(error) }
        }
    }
    private func checkout() {
        guard let review, !model.isBusy, model.canCheckout else { return }
        error = nil
        Task {
            do { try await model.checkout(review) }
            catch is CancellationError { }
            catch { self.error = PullRequestCheckoutPresentation.error(error) }
        }
    }
}

struct PullRequestCheckoutContent: View {
    let reference: GitHubPullRequestReference
    let summary: GitHubPullRequestSummary?
    let review: PullRequestCheckoutReview?
    @Binding var mode: GitHubPullRequestCheckoutMode
    @Binding var submodules: ProjectWorktreeSubmoduleMode
    @Binding var reviewSetup: Bool
    let busy: Bool
    let canPrepare: Bool
    let error: String?
    let edit: () -> Void
    let prepare: () -> Void
    let checkout: () -> Void
    var reportGeometry: ((String, CGRect) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(review == nil ? "Open Pull Request in a Conversation" : "Review Pull Request Checkout")
                        .font(.title2).fixedSize(horizontal: false, vertical: true)
                    Text("#\(reference.number) · \(reference.repository.nameWithOwner)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text((review?.plan.pullRequest ?? summary)?.title ?? "")
                        .font(.headline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text("A new conversation starts empty at the reviewed checkout. Your existing conversation, draft and provider history stay in place. Opening does not send a message.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let review { PullRequestCheckoutReviewContent(review: review) }
                    else {
                        Picker("Checkout location", selection: $mode) {
                            Text("Separate worktree").tag(GitHubPullRequestCheckoutMode.worktree)
                            Text("Local checkout").tag(GitHubPullRequestCheckoutMode.local)
                        }.pickerStyle(.radioGroup).disabled(busy)
                            .accessibilityIdentifier("pull-request-checkout-mode")
                        Text(mode == .worktree
                            ? "Create or reuse a dedicated worktree for this pull request. Existing local commits or edits are preserved; the review identifies the reused checkout."
                            : "Switch the repository's local checkout. This changes the files used by conversations sharing that checkout; commit or stash tracked changes first.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if mode == .worktree {
                            Picker("Initialize submodules", selection: $submodules) {
                                Text("None").tag(ProjectWorktreeSubmoduleMode.none)
                                Text("Top level").tag(ProjectWorktreeSubmoduleMode.topLevel)
                                Text("Recursive").tag(ProjectWorktreeSubmoduleMode.recursive)
                            }.disabled(busy).accessibilityIdentifier("pull-request-checkout-submodules")
                            Text("Initialization may download repositories through your Git configuration. None leaves submodules uninitialized; an initialization failure keeps the checkout with a warning.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Toggle("Review checkout setup script", isOn: $reviewSetup).disabled(busy)
                                .accessibilityIdentifier("pull-request-checkout-review-setup")
                            Text("After a new or moved worktree is ready, review its setup command before running it. An unchanged reused worktree does not rerun setup.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Checkout may fetch the pull request using your existing Git and GitHub sign-in. It does not change the remote pull request.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error {
                        Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if !canPrepare, !busy {
                        Text("This workspace is busy or held by another action. Finish or inspect that action before opening the pull request.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(20).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("pull-request-checkout-review-scroll")
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                if review != nil { Button("Edit", action: edit).disabled(busy).accessibilityIdentifier("pull-request-checkout-edit") }
                Button(action: review == nil ? prepare : checkout) {
                    if review == nil { Text("Review Checkout…") } else { Text("Open New Conversation") }
                }
                    .disabled(busy || !canPrepare).accessibilityIdentifier("pull-request-checkout-confirm")
                    .background { geometry("confirm") }
            }.padding(16)
        }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background { geometry("bounds") }.coordinateSpace(name: "pull-request-checkout-layout")
            .accessibilityIdentifier("pull-request-checkout-form")
    }
    private func geometry(_ region: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("pull-request-checkout-layout"))
            Color.clear.onAppear { reportGeometry?(region, frame) }
                .onChange(of: frame) { _, frame in reportGeometry?(region, frame) }
        }
    }
}

private struct PullRequestCheckoutReviewContent: View {
    let review: PullRequestCheckoutReview
    private var plan: GitHubPullRequestCheckoutPlan { review.plan }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PullRequestCheckoutPresentation.disposition(plan.disposition)).font(.headline)
            LabeledContent("Requested branch") { value(plan.requestedBranch) }
            LabeledContent("Requested head") { value(plan.requestedHeadCommit) }
            LabeledContent("Source checkout") { value(plan.sourcePath) }
            LabeledContent("Destination") { value(plan.destinationPath) }
                .accessibilityIdentifier("pull-request-checkout-destination")
            if let branch = plan.proof.destinationBranch { LabeledContent("Existing branch") { value(branch) } }
            if let head = plan.proof.destinationHeadCommit { LabeledContent("Existing head") { value(head) } }
            if plan.disposition == .reuseUnrelatedWorktree {
                Label("This worktree's local commits and workspace changes will be kept. Its actual checkout may remain different from the pull request's requested head.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pull-request-checkout-reuse-warning")
            }
            if plan.request.mode == .local {
                Text("The local repository checkout will change. Other conversations using that directory will see its checked-out files.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            LabeledContent("Conversation", value: review.title)
            LabeledContent("Provider", value: RunHistoryPresentation.provider(review.targetConfiguration))
            LabeledContent("Model", value: RunHistoryPresentation.model(review.targetConfiguration))
            LabeledContent("Permissions") { Text(LocalizedStringKey(review.targetConfiguration.permission.title)) }
            if RunHistoryPresentation.hasSavedAgentOptions(review.targetConfiguration) {
                Text("Saved agent options").font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Run checkpoints", value: review.checkpointPolicy == .disabled ? String(localized: "Disabled") : String(localized: "Automatic"))
            if plan.request.mode == .worktree {
                LabeledContent("Submodules", value: PullRequestCheckoutPresentation.submodules(plan.request.submodules))
                LabeledContent("Setup review", value: review.reviewSetup ? String(localized: "Review new or moved checkout") : String(localized: "Skipped"))
            }
        }.font(.callout).accessibilityIdentifier("pull-request-checkout-captured-review")
    }
    private func value(_ text: String) -> some View {
        Text(text).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}

enum PullRequestCheckoutPresentation {
    static func disposition(_ value: GitHubPullRequestCheckoutDisposition) -> String {
        switch value {
        case .local: String(localized: "Switch the local checkout")
        case .createWorktree: String(localized: "Create a separate worktree")
        case .reuseWorktree: String(localized: "Reuse the registered worktree")
        case .reuseUnrelatedWorktree: String(localized: "Reuse the existing worktree and keep its changes")
        }
    }
    static func submodules(_ value: ProjectWorktreeSubmoduleMode) -> String {
        switch value {
        case .none: String(localized: "None")
        case .topLevel: String(localized: "Top level")
        case .recursive: String(localized: "Recursive")
        }
    }
    static func error(_ error: any Error) -> String {
        if let error = error as? GitHubPullRequestCheckoutError { return error.localizedDescription }
        return PullRequestPresentation.error(error)
    }
}
