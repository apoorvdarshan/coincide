import CoincideCore
import SwiftUI

struct RemoteGitInspectorView: View {
    @Bindable var model: RemoteGitInspectorStore
    @State private var action: RemoteGitAction?
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(model.snapshot?.displayBranch ?? "Remote Git").font(.headline)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.mini) }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh remote Git").disabled(!model.session.canRead)
            }.padding(.horizontal)
            if let snapshot = model.snapshot {
                branchActions(snapshot)
                if model.hasDirtyFiles() { Text("Save or discard remote editor changes before switching branches or pulling.").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                List(selection: Binding<Data?>(get: { model.selected.map { Data($0.utf8) } }, set: { key in
                    model.selected = key.flatMap { key in model.files.first(where: { Data($0.path.utf8) == key })?.path }
                })) {
                    ForEach(Array(model.files.enumerated()), id: \.offset) { _, file in
                    HStack {
                        Text(file.status).font(.system(.caption, design: .monospaced)).foregroundStyle(file.isConflicted ? .orange : .secondary)
                        Text(file.path).lineLimit(1).truncationMode(.middle)
                    }.tag(Data(file.path.utf8)).contextMenu {
                        Button(file.isConflicted ? "Stage Resolution" : "Stage File") { Task { await model.stage([file.path]) } }.disabled(!model.canMutate)
                        Button("Unstage File") { Task { await model.unstage([file.path]) } }.disabled(!file.isStaged || !model.canMutate)
                    }
                    }
                }.frame(minHeight: 90, maxHeight: 210)
                HStack {
                    Toggle("Staged diff", isOn: $model.staged)
                    Spacer()
                    if model.isLoadingDiff { ProgressView().controlSize(.mini) }
                }.font(.caption).padding(.horizontal)
                ScrollView([.horizontal, .vertical]) {
                    Text(model.diff.isEmpty ? "No changes in this view." : model.diff)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
                Divider()
                TextField("Remote commit message", text: $model.commitMessage, axis: .vertical).lineLimit(1...4)
                    .textFieldStyle(.roundedBorder).padding(.horizontal).accessibilityIdentifier("remote-git-commit-message")
                HStack {
                    Button("Stage All") { Task { await model.stage(model.files.map(\.path)) } }.disabled(!model.canMutate || model.files.isEmpty)
                    Spacer()
                    Button("Commit Staged") { Task { await model.commit() } }
                        .disabled(!model.canMutate || snapshot.hasConflicts || !model.files.contains(where: \.isStaged) || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.controlSize(.small).padding(.horizontal)
            } else {
                ContentUnavailableView("Remote Git Unavailable", systemImage: "folder.badge.questionmark",
                    description: Text(model.statusError ?? "Connect to read the remote repository."))
                Button("Initialize Remote Repository…") { action = .initialize }.disabled(!model.canChangeWorkingTree)
            }
            if let error = model.statusError, model.snapshot != nil { message(error) }
            if let error = model.operationError { message(error) }
        }.padding(.vertical, 8)
        .task(id: model.session.isConnected) { if model.session.canRead { await model.refresh() } }
        .onChange(of: model.selected) { Task { await model.loadDiff() } }
        .onChange(of: model.staged) { Task { await model.loadDiff() } }
        .sheet(item: $action) { RemoteGitActionSheet(model: model, action: $0) }
    }

    private func branchActions(_ snapshot: GitSnapshot) -> some View {
        HStack {
            Menu("Branches") {
                ForEach(model.branches) { branch in
                    if branch.isRemote { Button("Track \(branch.name)…") { action = .branch(branch.ref) } }
                    else { Button(branch.name) { Task { await model.checkout(branch.name) } } }
                }
                Divider(); Button("New Branch…") { action = .branch(nil) }
            }.disabled(!model.canChangeWorkingTree || snapshot.isUnborn)
            Menu("Fetch") { ForEach(model.remotes, id: \.self) { remote in Button(remote) { Task { await model.fetch(remote) } } } }
                .disabled(!model.canMutate || model.remotes.isEmpty)
            Button("Pull (FF Only)") { Task { await model.pull() } }
                .disabled(!model.canChangeWorkingTree || snapshot.isDetached || snapshot.isUnborn || snapshot.hasConflicts || snapshot.upstream == nil)
            Button("Push…") { action = .push }
                .disabled(!model.canMutate || snapshot.isDetached || snapshot.isUnborn || snapshot.hasConflicts || model.remotes.isEmpty)
        }.controlSize(.small).padding(.horizontal)
    }
    private func message(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal) }
}

private enum RemoteGitAction: Identifiable {
    case initialize, branch(String?), push
    var id: String { switch self { case .initialize: "initialize"; case .branch(let ref): "branch:" + (ref ?? "new"); case .push: "push" } }
}

private struct RemoteGitActionSheet: View {
    var model: RemoteGitInspectorStore
    let action: RemoteGitAction
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var remote = ""
    @State private var setUpstream = true
    private var title: String { switch action { case .initialize: "Initialize Remote Repository"; case .branch: "Create Remote Branch"; case .push: "Push from Remote Mac" } }
    private var allowed: Bool { if case .push = action { return model.canMutate }; return model.canChangeWorkingTree }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2)
            Text(model.session.target.workspacePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            switch action {
            case .initialize: TextField("Initial branch", text: $name)
            case .branch(let tracking):
                if let tracking { Text("Track \(tracking) in a new local branch on the remote Mac.").font(.callout) }
                TextField("Branch name", text: $name)
            case .push:
                Text("Push \(model.snapshot?.branch ?? "") from the connected Mac to the destination below.")
                Picker("Remote", selection: $remote) { ForEach(model.remotes, id: \.self) { Text($0).tag($0) } }
                TextField("Destination branch", text: $name)
                Toggle("Track this upstream for future pulls", isOn: $setUpstream)
            }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action.id == "push" ? "Push" : action.id == "initialize" ? "Initialize" : "Create and Switch") {
                    let branch = name, destination = remote, tracks = setUpstream
                    Task {
                        switch action {
                        case .initialize: await model.initialize(branch: branch)
                        case .branch(let tracking): await model.createBranch(branch, tracking: tracking)
                        case .push: await model.push(remote: destination, branch: branch, setUpstream: tracks)
                        }
                    }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!allowed || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (action.id == "push" && remote.isEmpty))
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 470)
        .onAppear {
            switch action {
            case .initialize: name = "main"
            case .branch: break
            case .push: remote = model.upstreamRemote ?? model.remotes.first ?? ""; name = model.upstreamBranch ?? model.snapshot?.branch ?? ""
            }
        }
    }
}
