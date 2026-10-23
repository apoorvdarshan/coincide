import CoincideCore
import SwiftUI

struct RemoteWorktreeSheet: View {
    @Bindable var store: RemoteWorktreeStore
    let onPrepared: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a Remote Worktree").font(.title2)
            Text(store.setupThreadTitle).font(.headline)
            Text(store.setupWorkspacePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Prepare a separate checkout on the remote Mac, or reuse a registered checkout from that repository.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Remote checkout", selection: $store.mode) { ForEach(RemoteWorktreeMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    if let catalog = store.catalog {
                        Text("Repository: \(catalog.sourcePath)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    switch store.mode {
                    case .newBranch:
                        TextField("New branch name", text: $store.branchName).accessibilityIdentifier("remote-worktree-new-branch")
                        HStack {
                            TextField("Base ref or commit on remote Mac", text: $store.baseRef).accessibilityIdentifier("remote-worktree-base-ref")
                            Menu("Available Refs") {
                                Button("HEAD") { store.baseRef = "HEAD" }
                                ForEach(Array((store.catalog?.branches ?? []).enumerated()), id: \.offset) { _, branch in
                                    Button(branch.ref) { store.baseRef = branch.ref }
                                }
                            }.disabled(store.catalog == nil)
                        }
                        Text("The base must already exist on the remote Mac. This action does not fetch.").font(.caption).foregroundStyle(.secondary)
                    case .existingBranch:
                        Picker("Local branch on remote Mac", selection: $store.existingBranch) {
                            Text("Choose a branch").tag(Data())
                            ForEach(Array(store.localBranches.enumerated()), id: \.offset) { _, branch in
                                Text(branch.name + (store.branchIsCheckedOut(branch.name) ? " (already checked out)" : ""))
                                    .tag(Data(branch.name.utf8)).disabled(store.branchIsCheckedOut(branch.name))
                            }
                        }
                        Text("For an already checked-out branch, choose its Registered Worktree instead.").font(.caption).foregroundStyle(.secondary)
                    case .registeredWorktree:
                        Picker("Registered remote checkout", selection: $store.worktreePath) {
                            Text("Choose a checkout").tag(Data())
                            ForEach(Array(store.reusableWorktrees.enumerated()), id: \.offset) { _, worktree in
                                Text("\(worktree.branch ?? "") · \(worktree.path)").tag(Data(worktree.path.utf8))
                            }
                        }
                        if let selected = store.reusableWorktrees.first(where: { Data($0.path.utf8) == store.worktreePath }) {
                            Text(selected.path).font(.caption).textSelection(.enabled)
                            if let head = selected.headCommit { Text("Commit \(head)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Text("Existing edits stay in that remote checkout. The host verifies repository membership before reuse.").font(.caption).foregroundStyle(.secondary)
                    }
                    if store.mode != .registeredWorktree {
                        Picker("Initialize submodules on remote Mac", selection: $store.submodules) {
                            Text("None").tag(ProjectWorktreeSubmoduleMode.none)
                            Text("Top level").tag(ProjectWorktreeSubmoduleMode.topLevel)
                            Text("Recursive").tag(ProjectWorktreeSubmoduleMode.recursive)
                        }
                        Text("Initialization may download repositories using the remote Mac's Git configuration. None leaves submodules empty. A failed initialization preserves the checkout with a warning.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Project setup scripts are not run by this remote action.").font(.caption).foregroundStyle(.secondary)
                    Text("Messages wait for checkout preparation. Cancellation preserves remote files and branches; interrupted Git work may require inspection before retrying.").font(.caption).foregroundStyle(.secondary)
                    if store.isLoading { ProgressView("Reading remote branches and worktrees…").controlSize(.small) }
                    if let error = store.catalogError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if !store.setupIsCurrent {
                        Text("This conversation or connection changed. Close this sheet and choose its current checkout again.").font(.caption).foregroundStyle(.secondary)
                    } else if let message = store.eligibilityMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(maxHeight: 360)
            HStack {
                Button("Refresh") { Task { await store.loadCatalog() } }.disabled(store.isLoading || !store.setupIsCurrent)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(store.mode == .registeredWorktree ? "Use Remote Worktree" : "Prepare Remote Worktree") {
                    Task { if await store.prepare() { onPrepared(); dismiss() } }
                }.keyboardShortcut(.defaultAction).disabled(!store.canPrepare)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 580)
        .task { await store.loadCatalog() }
    }
}
