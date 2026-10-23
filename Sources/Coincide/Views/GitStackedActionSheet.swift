import CoincideCore
import SwiftUI

/// One review screen for Commit, Commit & Push, and Commit/Push & Create PR, with T3's
/// default-branch confirmation, an optional feature-branch step and live hook progress.
struct GitStackedActionSheet: View {
    let model: GitStackedActionStore
    let action: GitStackedAction
    let blocked: Bool
    let openPullRequests: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var message = ""
    @State private var useFeatureBranch = false
    @State private var featureBranch = ""
    @State private var remote = ""
    @State private var remoteBranch = ""
    @State private var title = ""
    @State private var description = ""
    @State private var base = ""
    @State private var draft = false
    @State private var prepared = false

    private var inspector: GitInspectorStore { model.inspector }
    private var snapshot: GitSnapshot? { inspector.snapshot }
    private var branch: String { snapshot?.branch ?? "" }
    private var defaultBranchName: String? { model.pullRequests.context?.defaultBranch ?? inspector.defaultBranch?.name }
    private var isDefaultBranch: Bool { defaultBranchName == branch && snapshot?.isDetached == false }
    private var needsConfirmation: Bool { GitActionResolver.requiresDefaultBranchConfirmation(action, isDefaultBranch: isDefaultBranch) }
    private var copy: GitDefaultBranchDialogCopy { GitActionResolver.defaultBranchDialogCopy(action, branch: branch, includesCommit: action.includesCommit) }
    private var featureUnavailable: String? { GitActionResolver.featureBranchUnavailableReason(branch: branch, hasChanges: snapshot?.isClean == false) }
    private var showsProgress: Bool { model.isRunning || model.outcome != nil }
    private var headline: String {
        switch action {
        case .commit: String(localized: "Commit")
        case .push: String(localized: "Push")
        case .createPullRequest: String(localized: "Push & Create Pull Request")
        case .commitPush: String(localized: "Commit & Push")
        case .commitPushPullRequest: String(localized: "Commit, Push & Create Pull Request")
        }
    }
    private var canStart: Bool {
        guard !blocked, !model.isRunning, !inspector.isBusy, let snapshot, !snapshot.hasConflicts, !snapshot.isDetached else { return false }
        if action.includesCommit && (selection.isEmpty && !snapshot.changes.contains(where: \.isStaged) || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { return false }
        if useFeatureBranch && featureBranch.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if action.includesPush && (inspector.upstream == nil || useFeatureBranch) && remote.isEmpty { return false }
        if action.includesPush && inspector.upstream == nil && !useFeatureBranch && remoteBranch.isEmpty { return false }
        if action.includesPullRequest && (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || base.isEmpty) { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headline).font(.title2).accessibilityIdentifier("git-stacked-title")
                Text(useFeatureBranch && !featureBranch.isEmpty ? "\(branch) → \(featureBranch)" : branch).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showsProgress { progress } else { form }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 380, idealWidth: 520, maxWidth: 640, minHeight: 360, idealHeight: 560, maxHeight: 760)
        .textFieldStyle(.roundedBorder)
        .interactiveDismissDisabled(model.isRunning)
        .onAppear(perform: prepare)
        .onChange(of: message) { old, new in
            // The PR title follows the commit subject until it is edited separately.
            if title.isEmpty || title == Self.subject(old) { title = Self.subject(new) }
            if !useFeatureBranch { featureBranch = GitActionResolver.autoFeatureBranchName(existing: inspector.branches.filter { !$0.isRemote }.map(\.name),
                                                                                         preferred: GitActionResolver.featureBranchSeed(commitMessage: new)) }
        }
    }

    @ViewBuilder private var form: some View {
        if needsConfirmation {
            VStack(alignment: .leading, spacing: 8) {
                Label(copy.title, systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
                Text(copy.description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Branch", selection: $useFeatureBranch) {
                    Text("Continue on \(branch)").tag(false)
                    Text("Create a feature branch").tag(true)
                }.pickerStyle(.radioGroup).disabled(featureUnavailable != nil).accessibilityIdentifier("git-stacked-feature-choice")
                if useFeatureBranch {
                    TextField("Feature branch", text: $featureBranch).accessibilityIdentifier("git-stacked-feature-branch")
                } else if let featureUnavailable { Text(featureUnavailable).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.padding(12).coincideSurface(cornerRadius: 10)
        }
        if action.includesCommit, let snapshot {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Files").font(.headline)
                    Spacer()
                    Button(selection.count == snapshot.changes.count ? "Select None" : "Select All") {
                        selection = selection.count == snapshot.changes.count ? [] : Set(snapshot.changes.map(\.path))
                    }.controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(snapshot.changes) { file in
                        Toggle(isOn: Binding(get: { selection.contains(file.path) }, set: { if $0 { selection.insert(file.path) } else { selection.remove(file.path) } })) {
                            HStack(spacing: 6) {
                                Text(file.status).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(file.path).lineLimit(1).truncationMode(.middle)
                            }
                        }.toggleStyle(.checkbox).disabled(file.isConflicted).accessibilityIdentifier("git-stacked-file-\(file.path)")
                    }
                }
                Text("Only checked files are committed. Other staged changes stay staged.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Commit message").font(.headline)
                    Spacer()
                    if model.messageGenerator != nil {
                        Button(model.isGenerating ? "Generating…" : "Generate") {
                            Task { if let value = await model.generateMessage(paths: Array(selection).sorted()) { message = value } }
                        }.controlSize(.small).disabled(model.isGenerating).accessibilityIdentifier("git-stacked-generate")
                    }
                }
                TextEditor(text: $message).font(.body).frame(minHeight: 70, idealHeight: 90, maxHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)).accessibilityIdentifier("git-stacked-message")
                    .accessibilityLabel("Commit message")
                if let error = model.generationError { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Git hooks run during the commit; their output appears while they run.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if action.includesPush {
            VStack(alignment: .leading, spacing: 6) {
                Text("Push").font(.headline)
                if let upstream = inspector.upstream, !useFeatureBranch {
                    LabeledContent("Destination", value: "\(upstream.remote)/\(upstream.branch)")
                } else {
                    Picker("Remote", selection: $remote) { ForEach(inspector.remotes, id: \.self) { Text($0).tag($0) } }
                        .accessibilityIdentifier("git-stacked-remote")
                    TextField("Remote branch", text: $remoteBranch).accessibilityIdentifier("git-stacked-remote-branch")
                    Text("The branch is pushed once and set to track this destination. No force push is used.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if action.includesPullRequest {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pull request").font(.headline)
                HStack {
                    TextField("Base branch", text: $base).accessibilityIdentifier("git-stacked-base")
                    if let branches = model.pullRequests.context?.baseBranches, !branches.isEmpty {
                        Menu("Branches") { ForEach(branches, id: \.self) { name in Button(name) { base = name } } }.fixedSize()
                    }
                }
                TextField("Title", text: $title, axis: .vertical).lineLimit(1...3).accessibilityIdentifier("git-stacked-pr-title")
                TextEditor(text: $description).font(.body).frame(minHeight: 70, idealHeight: 100, maxHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)).accessibilityLabel("Pull request description")
                Toggle("Create as draft", isOn: $draft)
                Text("After pushing, GitHub is checked again. The pull request is created only for the exact commit pushed here; otherwise you review it first.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if blocked { Text("Wait for the coding agent or current workspace action to finish.").font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.plan?.phases ?? []) { phase in
                HStack(spacing: 8) {
                    switch model.states[phase] ?? .pending {
                    case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                    case .running: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    Text(phase.title)
                    Spacer()
                    if model.states[phase] == .running, let started = model.phaseStartedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(GitActionResolver.formatElapsed(context.date.timeIntervalSince(started))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityElement(children: .combine).accessibilityIdentifier("git-stacked-phase-\(phase.rawValue)")
            }
            if let line = model.lastOutput, model.isRunning {
                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    .accessibilityIdentifier("git-stacked-output")
            }
            switch model.outcome {
            case .finished(let text)?: Label(text, systemImage: "checkmark.seal").foregroundStyle(.green)
            case .failed(let text)?: Text(text).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            case .cancelled?: Text("Cancelled. Steps that already finished were kept; nothing was repeated.").font(.callout).foregroundStyle(.secondary)
            case .needsPullRequestReview(let text)?: Text(text).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            case nil: EmptyView()
            }
            if let summary = model.pullRequest, let url = PullRequestPresentation.url(summary) {
                Link("Open #\(summary.reference.number) on GitHub", destination: url)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if model.isRunning {
                Spacer()
                Button("Cancel") { model.cancel() }.disabled(model.currentPhase == .pullRequest).accessibilityIdentifier("git-stacked-cancel")
            } else if model.outcome != nil {
                if case .needsPullRequestReview = model.outcome { Button("Review Pull Request…") { dismiss(); openPullRequests() } }
                Spacer()
                Button("Done") { model.reset(); dismiss() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("git-stacked-done")
            } else {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(needsConfirmation && !useFeatureBranch ? copy.continueLabel : headline, action: start)
                    .keyboardShortcut(.defaultAction).disabled(!canStart).coincidePrimaryAction()
                    .accessibilityIdentifier("git-stacked-start")
            }
        }
    }

    private func prepare() {
        guard !prepared, let snapshot else { return }
        prepared = true
        let staged = snapshot.changes.filter(\.isStaged).map(\.path)
        selection = Set(staged.isEmpty ? snapshot.changes.filter { !$0.isConflicted }.map(\.path) : staged)
        message = inspector.commitMessage
        remote = inspector.upstream?.remote ?? (inspector.remotes.contains("origin") ? "origin" : inspector.remotes.first ?? "")
        remoteBranch = inspector.upstream?.branch ?? snapshot.branch
        base = model.pullRequests.context?.defaultBranch ?? inspector.defaultBranch?.name ?? ""
        title = Self.subject(message)
        featureBranch = GitActionResolver.autoFeatureBranchName(existing: inspector.branches.filter { !$0.isRemote }.map(\.name),
                                                                 preferred: GitActionResolver.featureBranchSeed(commitMessage: message))
    }

    static func subject(_ message: String) -> String {
        message.split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private func start() {
        let feature = useFeatureBranch ? featureBranch.trimmingCharacters(in: .whitespaces) : nil
        var plan = GitStackedActionStore.Plan(action: action, featureBranch: feature)
        if action.includesCommit { plan.paths = Array(selection).sorted(); plan.commitMessage = message }
        if action.includesPush, inspector.upstream == nil || feature != nil {
            plan.remote = remote; plan.remoteBranch = feature ?? remoteBranch
        }
        if action.includesPullRequest {
            plan.pullRequestTitle = title.trimmingCharacters(in: .whitespacesAndNewlines); plan.pullRequestBody = description
            plan.pullRequestBase = base; plan.pullRequestDraft = draft
        }
        if model.run(plan), action.includesCommit, inspector.commitMessage == message { inspector.commitMessage = "" }
    }
}
