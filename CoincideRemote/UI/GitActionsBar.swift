import CoincideRemoteKit
import SwiftUI

/// Under a thread's uncommitted changes, as the Mac's diff panel shows them: the branch with how far it is ahead or
/// behind, its open pull request, and the git actions it allows (Commit…, Push, Create or View Pull Request, Pull). The
/// Mac runs them; an agent writes a commit message left empty and the pull request from the thread's conversation.
struct GitActionsBar: View {
    let threadID: UUID
    /// Called after an action changed the folder, so the changes above are read again.
    var onChange: () -> Void = {}
    @Environment(RemoteClient.self) private var client
    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme
    @State private var state: RemoteGitState?
    @State private var running: String?
    @State private var result: RemoteGitActionResult?
    @State private var committing = false
    @State private var confirming: Pending?

    /// An action that asks first because it pushes to the default branch.
    struct Pending: Identifiable {
        var action: RemoteGitActionRequest.Action
        var message: String?
        var id: String { action.rawValue }
    }

    var body: some View {
        Group {
            if let state, state.isRepository {
                VStack(alignment: .leading, spacing: 8) {
                    if let result { resultCard(result) }
                    HStack(spacing: 10) {
                        branchLabel(state)
                        Spacer(minLength: 4)
                        if let progress = running ?? state.progress {
                            ProgressView().controlSize(.small)
                            Text(progress).font(.footnote).foregroundStyle(theme.secondaryInk).lineLimit(1)
                        } else {
                            actionsMenu(state)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(theme.surface)
                .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: theme.borderWidth) }
            }
        }
        .task(id: threadID) { await reload() }
        .sheet(isPresented: $committing) {
            if let state {
                CommitSheet(state: state) { action, message, featureBranch in
                    run(action, message: message, featureBranch: featureBranch)
                }
            }
        }
        .confirmationDialog(
            confirmationTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            if let pending = confirming, let state {
                let commits = [.commit, .commitPush, .commitPushPR].contains(pending.action)
                if commits, state.changedFiles > 0 {
                    Button("Use a Feature Branch") { run(pending.action, message: pending.message, featureBranch: true, confirmed: true) }
                }
                Button(commits ? "Continue on \(state.branch ?? "HEAD")" : "Push to \(state.branch ?? "HEAD")") {
                    run(pending.action, message: pending.message, featureBranch: false, confirmed: true)
                }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(
                "This works on “\(state?.branch ?? "HEAD")”. You can continue on this branch, or create a feature branch and run the same action there."
            )
        }
    }

    private var confirmationTitle: String {
        switch confirming?.action {
        case .commitPush: String(localized: "Commit and push to the default branch?")
        case .push: String(localized: "Push to the default branch?")
        default: String(localized: "Open a pull request from the default branch?")
        }
    }

    private func branchLabel(_ state: RemoteGitState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(theme.secondaryInk)
            Text(state.branch ?? String(localized: "(detached HEAD)"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if state.ahead > 0 { Text(verbatim: "↑\(state.ahead)").font(.footnote.monospacedDigit()).foregroundStyle(theme.secondaryInk) }
            if state.behind > 0 { Text(verbatim: "↓\(state.behind)").font(.footnote.monospacedDigit()).foregroundStyle(theme.secondaryInk) }
            if let pullRequest = state.pullRequest, let url = URL(string: pullRequest.url) {
                Button { openURL(url) } label: {
                    Text(verbatim: "#\(pullRequest.number)")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(theme.selection, in: .capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.ink)
                .accessibilityLabel(Text("\(state.changeRequestName) #\(pullRequest.number)"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func actionsMenu(_ state: RemoteGitState) -> some View {
        Menu {
            Button { if ProGate.allows() { committing = true } } label: { Label("Commit…", systemImage: "checkmark.circle") }
                .disabled(!state.canCommit)
            if state.hasRemote {
                Button { run(.push) } label: { Label("Push", systemImage: "arrow.up.circle") }
                    .disabled(!state.canPush)
                if let pullRequest = state.pullRequest, let url = URL(string: pullRequest.url) {
                    Button { openURL(url) } label: {
                        Label("View \(state.changeRequestName) #\(pullRequest.number)", systemImage: "arrow.triangle.pull")
                    }
                } else {
                    Button { run(.createPR) } label: { Label("Create \(state.changeRequestName)", systemImage: "arrow.triangle.pull") }
                        .disabled(!state.canCreatePullRequest)
                }
                Divider()
                Button { run(.pull) } label: { Label("Pull", systemImage: "arrow.down.circle") }
                    .disabled(!state.canPull)
            }
        } label: {
            Label("Git Actions", systemImage: "ellipsis.circle")
                .labelStyle(.titleAndIcon)
                .font(.footnote.weight(.medium))
        }
        .disabled(!client.isConnected)
    }

    private func resultCard(_ result: RemoteGitActionResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.footnote.weight(.medium)).foregroundStyle(theme.ink)
                if let detail = result.detail { Text(detail).font(.caption).foregroundStyle(theme.secondaryInk).lineLimit(3) }
            }
            Spacer(minLength: 4)
            if let link = result.url, let url = URL(string: link) {
                Button("Open") { openURL(url) }.font(.footnote).buttonStyle(.glass)
            }
            Button { self.result = nil } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryInk)
                .accessibilityLabel(Text("Dismiss"))
        }
    }

    private func reload() async {
        state = await client.gitState(threadID)
    }

    /// Runs the action, asking first when it pushes to the default branch on a branch of its own.
    private func run(_ action: RemoteGitActionRequest.Action, message: String? = nil, featureBranch: Bool = false, confirmed: Bool = false) {
        confirming = nil
        if !confirmed, !featureBranch, let state, state.isDefaultBranch, state.confirmsOnDefaultBranch.contains(action.rawValue) {
            confirming = Pending(action: action, message: message)
            return
        }
        running = String(localized: "Starting…")
        result = nil
        Task {
            let outcome = await client.gitAction(
                RemoteGitActionRequest(threadID: threadID, action: action, message: message, featureBranch: featureBranch))
            running = nil
            result = outcome
            await reload()
            onChange()
        }
    }
}

/// "Commit Changes", as the Mac's commit sheet: the branch, a message (empty for the agent to write one), and whether to
/// commit on a new branch; then commit, or commit and push, or commit, push and open a pull request.
struct CommitSheet: View {
    let state: RemoteGitState
    let commit: (RemoteGitActionRequest.Action, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var message = ""
    @State private var newBranch = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        LabeledContent("Branch") {
                            HStack(spacing: 6) {
                                Text(state.branch ?? String(localized: "(detached HEAD)")).lineLimit(1).truncationMode(.middle)
                                if state.isDefaultBranch {
                                    Text("Default branch").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        Toggle("Commit on New Branch", isOn: $newBranch).toggleStyle(ThemedSwitchStyle())
                    } footer: {
                        Text("Commits all \(state.changedFiles) changed files.")
                    }
                    Section("Message") {
                        TextField("Leave empty to generate a message", text: $message, axis: .vertical)
                            .lineLimit(3...10)
                            .accessibilityLabel(Text("Commit message"))
                    }
                    Section {
                        Button("Commit") { finish(.commit) }
                        if state.hasRemote {
                            Button("Commit & Push") { finish(.commitPush) }
                            if state.pullRequest == nil {
                                Button("Commit, Push & Create \(state.changeRequestName)") { finish(.commitPushPR) }
                            }
                        }
                    }
                }
                .themedCards(theme)
            }
            .scrollContentBackground(.hidden)
            .background(theme.isDark ? theme.content : theme.sidebar)
            .navigationTitle("Commit Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func finish(_ action: RemoteGitActionRequest.Action) {
        dismiss()
        commit(action, message, newBranch)
    }
}
