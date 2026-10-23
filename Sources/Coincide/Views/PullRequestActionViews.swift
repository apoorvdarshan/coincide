import CoincideCore
import SwiftUI

/// Merge, auto-merge, ready/draft, close/reopen, update/delete branch, revert and workflow
/// approval. Choosing an action only opens a confirmation with the exact reviewed head.
struct PullRequestActionBar: View {
    let actions: PullRequestActionStore
    let reference: GitHubPullRequestReference
    @AppStorage(SourceControlPreferenceKeys.removeAgentCredits) private var removeAgentCredits = false
    @AppStorage(SourceControlPreferenceKeys.mergeMethod) private var preferredMethod = GitHubPullRequestMergeMethod.squash.rawValue

    private var available: [GitHubPullRequestAction] { actions.state?.reference == reference ? actions.state?.availableActions ?? [] : [] }
    private var merges: [GitHubPullRequestAction] { available.filter { if case .merge = $0 { true } else { false } } }
    private var autoMerges: [GitHubPullRequestAction] { available.filter { if case .enableAutoMerge = $0 { true } else { false } } }
    private var others: [GitHubPullRequestAction] {
        available.filter { action in
            switch action { case .merge, .enableAutoMerge: false; default: true }
        }
    }
    private var preferredMerge: GitHubPullRequestAction? {
        merges.first { $0.mergeMethod?.rawValue == preferredMethod } ?? merges.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let merge = preferredMerge {
                    Menu {
                        ForEach(merges, id: \.self) { action in Button(action.title) { choose(action) } }
                    } label: { Text("Merge…") } primaryAction: { choose(merge) }
                        .fixedSize().accessibilityIdentifier("pull-request-merge")
                } else if available.contains(.ready) {
                    Button("Ready for Review…") { choose(.ready) }.accessibilityIdentifier("pull-request-ready")
                } else if available.contains(.reopen) {
                    Button("Reopen…") { choose(.reopen) }.accessibilityIdentifier("pull-request-reopen")
                } else if available.contains(.revert) {
                    Button("Revert…") { choose(.revert) }.accessibilityIdentifier("pull-request-revert")
                }
                if !autoMerges.isEmpty || others.count > (available.contains(.ready) || available.contains(.reopen) || available.contains(.revert) ? 1 : 0) {
                    Menu("More") {
                        if !autoMerges.isEmpty {
                            Menu("Enable Auto-Merge") { ForEach(autoMerges, id: \.self) { action in Button(action.mergeMethod?.title ?? action.title) { choose(action) } } }
                        }
                        ForEach(others, id: \.self) { action in
                            Button(action.title + "…", role: action.isDestructive ? .destructive : nil) { choose(action) }
                        }
                    }.fixedSize().accessibilityIdentifier("pull-request-more-actions")
                }
                if actions.isLoadingState || actions.isReviewing || actions.isPerforming { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }.disabled(actions.isBusy)
            if let state = actions.state, state.reference == reference, !state.permissions.canWrite {
                Text("Your GitHub account cannot change this pull request.").font(.caption).foregroundStyle(.secondary)
            }
            if let state = actions.state, state.reference == reference, state.autoMergeEnabled {
                Label("Auto-merge is enabled\(state.autoMergeMethod.map { " (\($0.title))" } ?? "").", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = actions.stateError { Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let outcome = actions.lastOutcome {
                HStack(alignment: .top) {
                    Label(outcome.message, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                    if let url = outcome.revertURL.flatMap(URL.init(string:)) { Link("Open", destination: url).font(.caption) }
                    Spacer(minLength: 0)
                    Button { actions.dismissOutcome() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Dismiss")
                }.accessibilityIdentifier("pull-request-action-outcome")
            }
            if let error = actions.actionError, actions.review == nil {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pull-request-action-error")
            }
        }
        .controlSize(.small)
        .task(id: reference) { await actions.load(reference) }
        .sheet(isPresented: Binding(get: { actions.review != nil }, set: { if !$0 { actions.discardReview() } })) {
            if let review = actions.review { PullRequestActionSheet(actions: actions, review: review, removeAgentCredits: $removeAgentCredits) }
        }
    }

    private func choose(_ action: GitHubPullRequestAction) {
        if let method = action.mergeMethod, case .merge = action { preferredMethod = method.rawValue }
        Task { await actions.prepare(action, removeAgentCredits: removeAgentCredits && action.supportsMergeBody) }
    }
}

struct PullRequestActionSheet: View {
    let actions: PullRequestActionStore
    let review: GitHubPullRequestActionReview
    @Binding var removeAgentCredits: Bool
    @Environment(\.dismiss) private var dismiss
    private var state: GitHubPullRequestActionState { review.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(review.action.title).font(.title2).accessibilityIdentifier("pull-request-action-title")
                Text("#\(state.reference.number) · \(state.title)").font(.callout).lineLimit(2)
                Text(state.reference.repository.nameWithOwner).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Head") { Text((state.headRepository?.nameWithOwner ?? state.reference.repository.nameWithOwner) + ":" + state.headBranch).textSelection(.enabled) }
                    LabeledContent("Head commit") { Text(state.headCommit).font(.caption.monospaced()).textSelection(.enabled).accessibilityIdentifier("pull-request-action-head") }
                    LabeledContent("Base", value: state.baseBranch)
                    if let method = review.action.mergeMethod { LabeledContent("Method", value: method.title) }
                    if let warning = state.warning(for: review.action) {
                        Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if review.action.supportsMergeBody {
                        Toggle("Remove agent credits from the merge commit", isOn: Binding(get: { removeAgentCredits }, set: { value in
                            removeAgentCredits = value
                            Task { await actions.prepare(review.action, removeAgentCredits: value) }
                        })).disabled(actions.isBusy).accessibilityIdentifier("pull-request-remove-agent-credits")
                        if let body = review.mergeBody {
                            DisclosureGroup("Merge commit message") {
                                Text(body.isEmpty ? String(localized: "(empty)") : body).font(.caption.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                            }.accessibilityIdentifier("pull-request-merge-message")
                        } else if removeAgentCredits {
                            Text("No recognized agent credits were found; GitHub's default message is used.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if review.action == .approveWorkflows {
                        Text("\(review.workflowRunIDs.count) workflow runs from this fork are waiting. Approving lets them run with this repository's Actions settings.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = actions.actionError { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if actions.isPerforming { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { actions.discardReview(); dismiss() }.keyboardShortcut(.cancelAction).disabled(actions.isPerforming)
                Button(review.action.title, role: review.action.isDestructive ? .destructive : nil) {
                    Task { await actions.perform(); if actions.review == nil { dismiss() } }
                }.keyboardShortcut(.defaultAction).disabled(actions.isBusy).accessibilityIdentifier("pull-request-action-confirm")
            }.padding(16)
        }
        .frame(minWidth: 360, idealWidth: 480, maxWidth: 600, minHeight: 300, idealHeight: 420)
        .interactiveDismissDisabled(actions.isPerforming)
    }

    private var explanation: String {
        switch review.action {
        case .merge: String(localized: "GitHub merges only if the head is still exactly this commit. Coincide never uses administrator override or deletes your local branch.")
        case .enableAutoMerge: String(localized: "GitHub merges automatically once requirements pass, only for this head commit. A pull request that is already mergeable may merge right away.")
        case .disableAutoMerge: String(localized: "Automatic merging stops; the pull request stays open.")
        case .ready: String(localized: "Reviewers are notified that the pull request is ready.")
        case .draft: String(localized: "The pull request returns to draft; it cannot be merged until marked ready.")
        case .close: String(localized: "The pull request closes without merging. Its branch is kept.")
        case .reopen: String(localized: "The pull request reopens with its existing branch.")
        case .updateBranch(let rebase): rebase ? String(localized: "GitHub rebases the head branch onto the base, only if the head is still this commit.")
            : String(localized: "GitHub merges the base into the head branch, only if the head is still this commit.")
        case .deleteBranch: String(localized: "Deletes the remote head branch only if it still points at this commit. Local branches and checkouts are unchanged.")
        case .revert: String(localized: "GitHub opens a new pull request that reverts this merged change.")
        case .approveWorkflows: String(localized: "Each waiting run is approved only while the fork head is still this commit.")
        }
    }
}
