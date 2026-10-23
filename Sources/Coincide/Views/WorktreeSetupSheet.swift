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
    let choose: (GitWorktreeSelection, ProjectWorktreeSubmoduleMode, Bool) -> Void
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
    @State private var submodules = ProjectWorktreeSubmoduleMode.none
    @State private var submodulesChosen = false
    @State private var reviewSetup = true
    @State private var options: WorktreeSetupOptions?
    @State private var loadError: String?
    @State private var loading = true
    @State private var catalog: GitBranchCatalog?
    @State private var basePicker = false
    @State private var startFromRemote = false
    @State private var fetching = false
    @State private var fetchError: String?
    private var remoteBase: GitBranchCatalogEntry? { WorktreeBaseResolution.remote(for: baseRef, in: catalog) }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Checkout", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    switch mode {
                    case .newBranch:
                        TextField("New branch name", text: $branchName)
                            .accessibilityIdentifier("worktree-new-branch")
                        HStack {
                            TextField("Base branch or commit", text: $baseRef)
                                .accessibilityIdentifier("worktree-base-ref")
                            Button { basePicker = true } label: { Image(systemName: "list.bullet") }
                                .help("Choose a base branch").accessibilityLabel("Choose base branch").accessibilityIdentifier("worktree-base-picker")
                                .popover(isPresented: $basePicker, arrowEdge: .bottom) {
                                    BranchPickerView(catalog: catalog, loading: catalog == nil && loading, error: nil, title: String(localized: "Choose Base"), baseMode: true) { choice in
                                        if case .base(let name) = choice { baseRef = name }
                                        basePicker = false
                                    }
                                }
                        }
                        if let remote = remoteBase {
                            Toggle("Start from remote (fetch \(remote.name) first)", isOn: $startFromRemote)
                                .accessibilityIdentifier("worktree-start-from-remote")
                        }
                        Text(startFromRemote && remoteBase != nil
                             ? String(localized: "Before preparing, Coincide fetches only \(remoteBase?.name ?? "") and starts from its latest commit. Nothing else is fetched or changed.")
                             : String(localized: "The base must already be available locally. This does not fetch from a remote."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let fetchError { Text(fetchError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
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
                    if mode != .registeredWorktree {
                        Picker("Initialize submodules", selection: Binding(get: { submodules }, set: { submodules = $0; submodulesChosen = true })) {
                            Text("None").tag(ProjectWorktreeSubmoduleMode.none)
                            Text("Top level").tag(ProjectWorktreeSubmoduleMode.topLevel)
                            Text("Recursive").tag(ProjectWorktreeSubmoduleMode.recursive)
                        }.accessibilityIdentifier("worktree-submodules")
                        Text("Initialization may download repositories using your Git configuration. None leaves submodules empty. If initialization fails, the checkout remains available with a warning.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Review checkout setup script", isOn: $reviewSetup)
                        .accessibilityIdentifier("worktree-review-setup")
                    Text("When this project’s actions or t3.json declare a setup script, review its command before running it. Messages wait for your choice. Turning this off skips setup discovery for this checkout.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if loading { ProgressView().controlSize(.small).accessibilityLabel("Loading local worktrees") }
                    if let loadError {
                        Text(loadError).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Messages wait until setup finishes. Cancelling setup keeps queued messages paused and preserves local files and branches; Git may clean its own unfinished checkout.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Save or discard file edits and close this conversation's terminal tabs in every window before changing its checkout.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(maxHeight: 330)
            HStack {
                Button("Refresh") { Task { await loadOptions() } }.disabled(loading)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                if fetching { ProgressView().controlSize(.small) }
                Button(mode == .registeredWorktree ? "Use Worktree" : startFromRemote && remoteBase != nil && mode == .newBranch ? "Fetch & Prepare Worktree" : "Prepare Worktree") {
                    guard let selection else { return }
                    if mode == .newBranch, startFromRemote, let remote = remoteBase { prepareFromRemote(remote) }
                    else { choose(selection, mode == .registeredWorktree ? .none : submodules, reviewSetup) }
                }.keyboardShortcut(.defaultAction).disabled(selection == nil || loading || fetching)
            }
        }
        .padding(24).frame(width: 520)
        .task { await loadOptions() }
        .task { if let value = await store.projectDefaults(threadID: threadID)?.worktreeSubmodules.value, !submodulesChosen { submodules = value } }
    }
    /// The explicit fetch is its own visible step; the worktree then starts from the fetched commit.
    private func prepareFromRemote(_ remote: GitBranchCatalogEntry) {
        guard let path = store.thread(threadID)?.workspacePath, let remoteName = remote.remote else { return }
        fetching = true; fetchError = nil
        let name = branchName, module = submodules, setup = reviewSetup
        Task {
            defer { fetching = false }
            do {
                try await GitService(root: URL(fileURLWithPath: path)).fetch(remote: remoteName, branch: remote.localName)
                choose(.createBranch(name: name, baseRef: remote.ref), module, setup)
            } catch { fetchError = error.localizedDescription }
        }
    }
    private func loadOptions() async {
        loading = true; loadError = nil
        defer { loading = false }
        if let path = store.thread(threadID)?.workspacePath { catalog = try? await GitService(root: URL(fileURLWithPath: path)).branchCatalog() }
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

/// Maps a typed or picked base onto the remote-tracking branch "Start from remote" would fetch.
enum WorktreeBaseResolution {
    static func remote(for base: String, in catalog: GitBranchCatalog?) -> GitBranchCatalogEntry? {
        guard let catalog else { return nil }
        let value = base.trimmingCharacters(in: .whitespaces)
        if let entry = catalog.remotes.first(where: { $0.name == value || $0.ref == value }), entry.remote != nil { return entry }
        if let local = catalog.locals.first(where: { $0.name == value || $0.ref == value }), let upstream = local.upstream {
            return catalog.remotes.first { $0.name == upstream && $0.remote != nil }
        }
        return nil
    }
}
