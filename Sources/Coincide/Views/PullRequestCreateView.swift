import CoincideCore
import SwiftUI

struct PullRequestCreateView: View {
    let model: PullRequestStore
    let back: () -> Void
    let requestPush: () -> Void
    @State private var title = ""
    @State private var description = ""
    @State private var baseBranch = ""
    @State private var isDraft = false
    @State private var review: GitHubPullRequestCreateReview?
    @State private var error: String?
    @State private var preparationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.operation?.isWorking == true || (model.operation?.phase == .unconfirmed && model.operation?.acknowledgedAt == nil) ||
                (model.operation?.result != nil && review?.id == model.operation?.id) {
                ScrollView { PullRequestOperationView(model: model, viewResult: back).padding(20) }
            } else {
                PullRequestCreateContent(context: model.context, review: review, title: $title, description: $description,
                    baseBranch: $baseBranch, isDraft: $isDraft, busy: model.isBusy, canPrepare: model.canCreate,
                    error: error ?? model.actionError, edit: clearReview, prepare: prepare, create: create, requestPush: requestPush)
            }
        }
        .onAppear { if baseBranch.isEmpty { baseBranch = model.context?.defaultBranch ?? "" } }
        .onChange(of: model.context?.sourceFingerprint) {
            if baseBranch.isEmpty { baseBranch = model.context?.defaultBranch ?? "" }
            if let review, review.context.sourceFingerprint != model.context?.sourceFingerprint, !model.isAccepting {
                clearReview(); error = String(localized: "The checkout or published branch changed. Review this request again before creating it.")
            }
        }
        .onChange(of: model.operation?.phase) {
            if let operation = model.operation, operation.phase == .failed, operation.id == review?.id {
                clearReview(); error = operation.error
            }
        }
        .onDisappear {
            preparationTask?.cancel()
            if let review { Task { await model.discardReview(review.id) } }
        }
    }
    private func clearReview() {
        if let review { Task { await model.discardReview(review.id) } }
        review = nil; error = nil
    }
    private func prepare() {
        guard !model.isBusy else { return }
        error = nil
        let capturedTitle = title, capturedDescription = description, capturedBase = baseBranch, capturedDraft = isDraft
        preparationTask = Task {
            defer { preparationTask = nil }
            do {
                let value = try await model.prepareCreation(title: capturedTitle, body: capturedDescription, baseBranch: capturedBase, isDraft: capturedDraft)
                guard !Task.isCancelled else { await model.discardReview(value.id); return }
                guard title == capturedTitle, description == capturedDescription, baseBranch == capturedBase, isDraft == capturedDraft else {
                    await model.discardReview(value.id)
                    error = String(localized: "The request changed while it was being checked. Review your latest text again.")
                    return
                }
                review = value
            } catch is CancellationError { }
            catch { self.error = PullRequestPresentation.error(error) }
        }
    }
    private func create() {
        guard let review, !model.isBusy else { return }
        error = nil
        Task {
            do { try await model.create(review) }
            catch is CancellationError { }
            catch { self.error = PullRequestPresentation.error(error) }
        }
    }
}

struct PullRequestCreateContent: View {
    let context: GitHubPullRequestContext?
    let review: GitHubPullRequestCreateReview?
    @Binding var title: String
    @Binding var description: String
    @Binding var baseBranch: String
    @Binding var isDraft: Bool
    let busy: Bool
    let canPrepare: Bool
    let error: String?
    let edit: () -> Void
    let prepare: () -> Void
    let create: () -> Void
    let requestPush: () -> Void
    private var captured: GitHubPullRequestContext? { review?.context ?? context }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text(review == nil ? "New Pull Request" : "Review Pull Request").font(.title2)
                    Text("Only committed changes in the published branch are included. Creation does not commit, push or send a conversation message.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let captured {
                        VStack(alignment: .leading, spacing: 7) {
                            LabeledContent("Repository", value: captured.repository.nameWithOwner)
                            LabeledContent("Head", value: PullRequestPresentation.head(captured))
                            if captured.branch != captured.upstream?.branch, let localBranch = captured.branch {
                                LabeledContent("Local branch", value: localBranch)
                            }
                            if let commit = captured.headCommit { LabeledContent("Head commit") { Text(commit).font(.caption.monospaced()).textSelection(.enabled) } }
                            Text(captured.workspacePath).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.font(.callout)
                        if let existing = captured.existingPullRequest {
                            Text("An open pull request already exists for this branch.").font(.callout)
                            if let url = PullRequestPresentation.url(existing) { Link("Open Existing Pull Request", destination: url) }
                        } else if let message = captured.readiness.message {
                            Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if [.unpublished, .unpushedCommits].contains(captured.readiness) {
                                Button("Push Branch…", action: requestPush).disabled(busy).accessibilityIdentifier("pull-request-push-required")
                            }
                        }
                    }
                    Divider()
                    if let review {
                        LabeledContent("Base", value: review.baseBranch)
                        LabeledContent("Base commit") { Text(review.baseCommit).font(.caption.monospaced()).textSelection(.enabled) }
                        LabeledContent("State", value: review.isDraft ? String(localized: "Draft") : String(localized: "Ready for review"))
                        Text(review.title).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pull-request-reviewed-title")
                        Text(review.body.isEmpty ? String(localized: "No description") : review.body)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pull-request-reviewed-body")
                        Text("GitHub will be checked again for an existing pull request before creation. If the published branch or base changes, review again.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Base branch").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                TextField("Base branch", text: $baseBranch).accessibilityIdentifier("pull-request-base")
                                if let context, !context.baseBranches.isEmpty {
                                    Menu("Branches") { ForEach(context.baseBranches, id: \.self) { branch in Button(branch) { baseBranch = branch } } }
                                        .fixedSize().accessibilityLabel("Choose base branch")
                                }
                            }
                            if context?.baseBranchesTruncated == true { Text("The branch list is limited. Enter an exact base branch if it is not listed.").font(.caption).foregroundStyle(.secondary) }
                        }
                        TextField("Pull request title", text: $title, axis: .vertical).lineLimit(1...3)
                            .accessibilityIdentifier("pull-request-title")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Description").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $description).font(.body).frame(minHeight: 110, idealHeight: 180, maxHeight: 240)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                                .accessibilityIdentifier("pull-request-body")
                        }
                        Toggle("Create as draft", isOn: $isDraft).accessibilityIdentifier("pull-request-draft")
                    }
                    if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                    if review != nil, !canPrepare, !busy {
                        Text("Creation is unavailable while this workspace is busy, held, or already has an open pull request. Return to the list or refresh before continuing.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(20).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }.textFieldStyle(.roundedBorder)
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                if review != nil { Button("Edit", action: edit).disabled(busy).accessibilityIdentifier("pull-request-edit-review") }
                Button(review == nil ? "Review Request…" : "Create Pull Request", action: review == nil ? prepare : create)
                    .disabled(busy || !canPrepare || (review == nil && (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseBranch.isEmpty)))
                    .accessibilityIdentifier("pull-request-create")
            }.padding(16)
        }
    }
}
