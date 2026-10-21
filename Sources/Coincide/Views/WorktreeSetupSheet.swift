import CoincideCore
import SwiftUI

struct WorktreeSetupOptions: Sendable {
    let branches: [String]
    let worktrees: [GitWorktree]
}

struct WorktreeSetupSheet: View {
    let store: WorkspaceStore
    let threadID: UUID
    let cancel: () -> Void
    let choose: (GitWorktreeSelection) -> Void
    private enum Mode: String, CaseIterable, Identifiable {
        case newBranch, existingBranch, registeredWorktree
        var id: Self { self }
        var title: String {
            switch self {
            case .newBranch: String(localized: "New Branch")
            case .existingBranch: String(localized: "Existing Branch")
            case .registeredWorktree: String(localized: "Registered Worktree")
            }
        }
    }
    @State private var mode = Mode.newBranch
    @State private var branchName = ""
    @State private var baseRef = "HEAD"
    @State private var existingBranch = ""
    @State private var worktreePath = ""
    @State private var options: WorktreeSetupOptions?
    @State private var loadError: String?
    @State private var loading = true
    private var selection: GitWorktreeSelection? {
        switch mode {
        case .newBranch:
            guard !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !baseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .createBranch(name: branchName, baseRef: baseRef)
        case .existingBranch:
            guard options?.branches.contains(existingBranch) == true else { return nil }
            return .existingBranch(name: existingBranch)
        case .registeredWorktree:
            guard options?.worktrees.contains(where: { $0.path == worktreePath }) == true else { return nil }
            return .reuse(path: worktreePath)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a Worktree").font(.title2)
            Text("Give this conversation a separate checkout, or use a registered checkout from this repository.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Checkout", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            switch mode {
            case .newBranch:
                TextField("New branch name", text: $branchName)
                    .accessibilityIdentifier("worktree-new-branch")
                TextField("Local base ref or commit", text: $baseRef)
                    .accessibilityIdentifier("worktree-base-ref")
                Text("The base must already be available locally. This does not fetch from a remote.")
                    .font(.caption).foregroundStyle(.secondary)
            case .existingBranch:
                Picker("Local branch", selection: $existingBranch) {
                    Text("Choose a branch").tag("")
                    ForEach(options?.branches ?? [], id: \.self) { Text($0).tag($0) }
                }
                Text("If the branch is already checked out, choose its Registered Worktree instead.")
                    .font(.caption).foregroundStyle(.secondary)
            case .registeredWorktree:
                Picker("Registered checkout", selection: $worktreePath) {
                    Text("Choose a checkout").tag("")
                    ForEach(options?.worktrees ?? []) { worktree in
                        Text("\(worktree.branch ?? "") — \(worktree.path)").tag(worktree.path)
                    }
                }
                if !worktreePath.isEmpty {
                    Text(worktreePath).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Existing edits stay in that checkout. Coincide verifies it still belongs to this repository before using it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loading { ProgressView().controlSize(.small).accessibilityLabel("Loading local worktrees") }
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Messages wait until setup finishes. Cancelling setup keeps queued messages paused and preserves local files and branches; Git may clean its own unfinished checkout.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Save or discard file edits and close this conversation's terminal tabs in every window before changing its checkout.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh") { Task { await loadOptions() } }.disabled(loading)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(mode == .registeredWorktree ? "Use Worktree" : "Prepare Worktree") {
                    if let selection { choose(selection) }
                }.keyboardShortcut(.defaultAction).disabled(selection == nil || loading)
            }
        }
        .padding(24).frame(width: 520)
        .task { await loadOptions() }
    }
    private func loadOptions() async {
        loading = true; loadError = nil
        defer { loading = false }
        do {
            let result = try await store.worktreeSetupOptions(for: threadID)
            try Task.checkCancellation()
            options = result
            if !result.branches.contains(existingBranch) { existingBranch = "" }
            if !result.worktrees.contains(where: { $0.path == worktreePath }) { worktreePath = "" }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { loadError = error.localizedDescription } }
    }
}
