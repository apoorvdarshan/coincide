import AppKit
import CoincideCore
import SwiftUI

struct GitInspectorView: View {
    let workspace: WorkspaceStore
    @State var model: GitInspectorStore
    @State private var pullRequests: PullRequestStore
    @State private var sheet: GitInspectorSheet?
    @State private var pendingPush = false
    @State private var stacked: GitStackedActionStore
    @AppStorage(DiffViewerDefaults.ignoreWhitespace) private var ignoreWhitespace = false

    init(workspace: WorkspaceStore, path: String) {
        self.workspace = workspace
        let model = workspace.gitInspector(path: path), pullRequests = workspace.pullRequestStore(path: path)
        _model = State(initialValue: model)
        _pullRequests = State(initialValue: pullRequests)
        _stacked = State(initialValue: GitStackedActionStore(inspector: model, pullRequests: pullRequests))
    }
    init(workspace: WorkspaceStore, model: GitInspectorStore) {
        self.workspace = workspace; _model = State(initialValue: model)
        let pullRequests = workspace.pullRequestStore(path: model.git.root.path)
        _pullRequests = State(initialValue: pullRequests)
        _stacked = State(initialValue: GitStackedActionStore(inspector: model, pullRequests: pullRequests))
    }

    private var workspaceBusy: Bool {
        let root = (model.snapshot?.repositoryRoot ?? model.git.root).standardizedFileURL.resolvingSymlinksInPath().path
        return workspace.snapshot.threads.contains { thread in
            guard thread.isBusy else { return false }
            let path = URL(fileURLWithPath: thread.workspacePath).standardizedFileURL.resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root + "/")
        }
    }
    private var mutationsDisabled: Bool { model.isBusy || workspaceBusy || !workspace.canEditWorkspace(model.git.root.path) }
    private var isDefaultBranch: Bool {
        guard let snapshot = model.snapshot, !snapshot.isDetached else { return false }
        return (pullRequests.context?.defaultBranch ?? model.defaultBranch?.name) == snapshot.branch
    }
    private var quickAction: GitQuickAction {
        GitActionResolver.quickAction(model.quickActionStatus(hasOpenPullRequest: pullRequests.context?.existingPullRequest != nil),
                                      isBusy: mutationsDisabled || stacked.isRunning, isDefaultBranch: isDefaultBranch, hasPrimaryRemote: !model.remotes.isEmpty)
    }
    private var menuItems: [GitActionMenuItem] {
        GitActionResolver.menuItems(model.quickActionStatus(hasOpenPullRequest: pullRequests.context?.existingPullRequest != nil),
                                    isBusy: mutationsDisabled || stacked.isRunning, hasPrimaryRemote: !model.remotes.isEmpty)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                GitBranchPickerButton(workspace: workspace, model: model,
                                      disabledReason: mutationsDisabled ? String(localized: "Branches can change after the current workspace action finishes.") : nil) { choice in
                    switch choice {
                    case .checkout(let name): model.checkout(name)
                    case .create(let name): model.createBranch(name)
                    case .track(let entry): sheet = .branch(GitBranch(ref: entry.ref, upstream: entry.upstream))
                    case .pullRequest(let reference): sheet = .pullRequestReference(reference)
                    case .openWorktree(let path): workspace.addProject(at: URL(fileURLWithPath: path))
                    case .base(let name): model.compareBase = name
                    }
                }
                Spacer(minLength: 0)
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh source control").accessibilityLabel("Refresh source control").disabled(model.isBusy)
            }.padding(.horizontal)
            PullRequestBranchCard(model: pullRequests) { reference in
                sheet = .pullRequests(reference)
            }.padding(.horizontal)
            if let snapshot = model.snapshot {
                if let upstream = snapshot.upstream {
                    HStack(spacing: 8) {
                        Text(upstream).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if let ahead = snapshot.ahead, let behind = snapshot.behind {
                            Label(String(ahead), systemImage: "arrow.up").accessibilityLabel("\(ahead) commits ahead")
                            Label(String(behind), systemImage: "arrow.down").accessibilityLabel("\(behind) commits behind")
                        } else { Text("Tracking unavailable") }
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                } else { Text(snapshot.isUnborn ? "No commits yet" : snapshot.isDetached ? "Switch to a branch to pull or push." : "No upstream branch").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal) }
                HStack {
                    Menu("Fetch") { ForEach(model.remotes, id: \.self) { remote in Button(remote) { model.fetch(remote) } } }
                        .disabled(model.isBusy || model.remotes.isEmpty)
                    Button("Pull") { model.pull() }.help("Fast-forward from the tracked upstream")
                        .disabled(mutationsDisabled || !snapshot.isClean || snapshot.isDetached || snapshot.isUnborn || model.upstream == nil)
                    Button("Push…") { sheet = .push }.disabled(mutationsDisabled || snapshot.isDetached || snapshot.isUnborn || snapshot.hasConflicts || model.remotes.isEmpty)
                }.controlSize(.small).padding(.horizontal)
                if workspaceBusy { Text("A coding agent is using this workspace.").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                if snapshot.hasConflicts { Label("Resolve conflicts before committing.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(.horizontal) }
                quickActionBar
                List(model.files, selection: $model.selected) { file in
                    HStack {
                        Text(file.status).font(.system(.caption, design: .monospaced)).foregroundStyle(file.isConflicted ? .orange : .secondary)
                        Text(file.path).lineLimit(1).truncationMode(.middle)
                    }.tag(file.path).accessibilityLabel("\(file.path), \(file.isConflicted ? "conflict" : file.status)")
                        .contextMenu {
                            Button(file.isConflicted ? "Stage Resolution" : "Stage File") { model.stage([file.path]) }.disabled(mutationsDisabled)
                            if file.isStaged { Button("Unstage File") { model.unstage([file.path]) }.disabled(mutationsDisabled) }
                        }
                }.frame(minHeight: 80, maxHeight: 220)
                HStack(spacing: 6) {
                    Picker("Changes", selection: $model.scope) {
                        ForEach(GitInspectorDiffScope.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("git-diff-scope")
                    if model.isLoadingDiff { ProgressView().controlSize(.mini) }
                }.padding(.horizontal)
                if model.scope == .branch { compareBar }
                DiffView(diff: model.parsedDiff, workspacePath: model.git.root.path, store: workspace, ignoreWhitespace: $ignoreWhitespace,
                         focusPath: model.scope == .branch ? model.selected : nil,
                         emptyTitle: model.scope == .branch ? String(localized: "No Branch Changes") : String(localized: "No Changes"),
                         emptyDescription: model.diffDescription ?? (model.scope == .branch ? String(localized: "This branch matches its base.") : String(localized: "No changes in this view.")))
                    .frame(maxHeight: .infinity)
                Divider()
                TextField("Commit message", text: $model.commitMessage, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder).padding(.horizontal)
                HStack {
                    Button("Stage All") { model.stage(model.files.map(\.path)) }.disabled(model.files.isEmpty || mutationsDisabled)
                    Spacer()
                    Button("Commit Staged") { model.commit() }
                        .disabled(!model.files.contains(where: \.isStaged) || snapshot.hasConflicts || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mutationsDisabled)
                }.padding(.horizontal)
            } else if let error = model.statusError {
                ContentUnavailableView("Git Unavailable", systemImage: "folder.badge.questionmark", description: Text(error))
                Button("Initialize Repository…") { sheet = .initialize }.disabled(mutationsDisabled)
            } else if pullRequests.operation?.locksSource == true || pullRequests.checkoutOperation?.locksSource == true {
                ContentUnavailableView("Workspace Held", systemImage: "pause.circle", description: Text("Inspect the pull request operation above before changing this checkout."))
            } else { Spacer(); ProgressView("Reading repository…"); Spacer() }
            if let name = model.operationName {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        ProgressView().controlSize(.small); Text(name).font(.caption).lineLimit(1)
                        if let started = model.operationStartedAt {
                            TimelineView(.periodic(from: started, by: 1)) { context in
                                Text(GitActionResolver.formatElapsed(context.date.timeIntervalSince(started))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(); Button("Cancel") { model.cancel() }.controlSize(.small)
                    }
                    if let detail = model.operationDetail {
                        Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).accessibilityIdentifier("git-operation-detail")
                    }
                }.padding(.horizontal)
            }
            if let error = model.operationError {
                HStack(alignment: .top) {
                    ScrollView(.vertical) { Text(error).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                    Button { model.operationError = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Dismiss Git message")
                }.foregroundStyle(.secondary).padding(.horizontal)
            }
        }.padding(.vertical, 8)
        .task { await model.refresh() }
        .onChange(of: model.selected) { if model.scope != .branch { Task { await model.loadDiff() } } }
        .onChange(of: model.scope) { Task { await model.loadDiff() } }
        .onChange(of: model.compareBase) { if model.scope == .branch { Task { await model.loadDiff() } } }
        .onAppear { model.ignoreWhitespace = ignoreWhitespace }
        .onChange(of: ignoreWhitespace) { model.ignoreWhitespace = ignoreWhitespace; Task { await model.loadDiff() } }
        .onChange(of: workspaceBusy) { if !workspaceBusy { Task { await model.refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.refresh() } }
        .sheet(item: $sheet, onDismiss: {
            if pendingPush { pendingPush = false; sheet = .push }
        }) { kind in
            switch kind {
            case .pullRequests(let reference):
                PullRequestsSheet(model: pullRequests, initialSelection: reference) {
                    pendingPush = true; sheet = nil
                }
            case .pullRequestReference(let query):
                PullRequestsSheet(model: pullRequests, initialReference: query) {
                    pendingPush = true; sheet = nil
                }
            case .stacked(let action):
                GitStackedActionSheet(model: stacked, action: action, blocked: workspaceBusy || !workspace.canEditWorkspace(model.git.root.path)) {
                    sheet = .pullRequests(nil)
                }
            default: GitActionSheet(kind: kind, model: model, blocked: workspaceBusy)
            }
        }
    }
}

extension GitInspectorView {
    @ViewBuilder fileprivate var quickActionBar: some View {
        let quick = quickAction
        HStack(spacing: 6) {
            Button {
                switch quick.kind {
                case .run(let action): sheet = .stacked(action)
                case .pull: model.pull()
                case .publish, .hint: break
                }
            } label: { Label(quick.label, systemImage: quick.kind == .pull ? "arrow.down" : "arrow.up.circle") }
                .disabled(quick.disabled || quick.kind == .publish)
                .help(quick.hint ?? (quick.kind == .publish ? String(localized: "Add a Git remote to publish this repository.") : quick.label))
                .accessibilityIdentifier("git-quick-action")
                .coincidePrimaryAction()
            Menu {
                ForEach(menuItems) { item in
                    Button(item.label + "…") {
                        switch item.id {
                        case .commit: sheet = .stacked(.commit)
                        case .push: sheet = .stacked(.push)
                        case .pullRequest: sheet = .stacked(.createPullRequest)
                        }
                    }.disabled(item.disabled)
                }
            } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More Git actions").accessibilityIdentifier("git-action-menu")
            Spacer(minLength: 0)
            if let hint = quick.hint, quick.disabled, !mutationsDisabled { Text(hint).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }.controlSize(.small).padding(.horizontal)
    }

    @ViewBuilder fileprivate var compareBar: some View {
        HStack(spacing: 6) {
            Text("Comparing \(model.snapshot?.displayBranch ?? "HEAD") against").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Menu(model.compareBase ?? String(localized: "Choose Base")) {
                let locals = model.branches.filter { !$0.isRemote }, remotes = model.branches.filter(\.isRemote)
                Section("Local") { ForEach(locals) { branch in Button(branch.name) { model.compareBase = branch.name } } }
                if !remotes.isEmpty { Section("Remote") { ForEach(remotes) { branch in Button(branch.name) { model.compareBase = branch.name } } } }
            }.menuStyle(.borderlessButton).fixedSize().font(.caption).accessibilityLabel("Comparison base").accessibilityIdentifier("git-compare-base")
            Spacer(minLength: 0)
        }.padding(.horizontal)
    }
}

private enum GitInspectorSheet: Identifiable {
    case initialize, branch(GitBranch?), push, pullRequests(GitHubPullRequestReference?), pullRequestReference(String), stacked(GitStackedAction)
    var id: String {
        switch self {
        case .initialize: "initialize"; case .branch(let branch): "branch:" + (branch?.ref ?? "new"); case .push: "push"
        case .pullRequests(let reference): "pullRequests:" + (reference.map { String($0.number) } ?? "all")
        case .pullRequestReference(let query): "pullRequestReference:" + query
        case .stacked(let action): "stacked:" + action.rawValue
        }
    }
}

private struct GitActionSheet: View {
    let kind: GitInspectorSheet
    var model: GitInspectorStore
    let blocked: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var remote = ""
    @State private var setUpstream = true
    private var title: String { switch kind { case .initialize: "Initialize Repository"; case .branch: "Create and Switch Branch"; case .push: "Push Branch"; default: "Pull Requests" } }
    private var action: String { switch kind { case .initialize: "Initialize"; case .branch: "Create Branch"; case .push: "Push"; default: "Done" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            switch kind {
            case .initialize:
                Text(model.git.root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                TextField("Initial branch", text: $name)
            case .branch(let branch):
                Text(branch.map { "Track \($0.name) with a new local branch." } ?? "Create a branch from the current commit, then switch to it.")
                TextField("Branch name", text: $name)
            case .push:
                Text("Push \(model.snapshot?.branch ?? "") to the selected destination.")
                Picker("Remote", selection: $remote) { ForEach(model.remotes, id: \.self) { Text($0).tag($0) } }
                TextField("Remote branch", text: $name)
                Toggle("Track this upstream for future pulls", isOn: $setUpstream)
            default: EmptyView()
            }
            if blocked { Text("Wait for the coding agent to finish using this workspace.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) {
                    switch kind {
                    case .initialize: model.initialize(branch: name)
                    case .branch(let branch): model.createBranch(name, tracking: branch?.ref)
                    case .push: model.push(remote: remote, branch: name, setUpstream: setUpstream)
                    default: break
                    }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(blocked || model.isBusy || name.isEmpty || (kind.id == "push" && remote.isEmpty))
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 440)
        .onAppear {
            switch kind {
            case .initialize: name = "main"
            case .branch(let branch):
                if let branch {
                    let prefix = model.remotes.sorted { $0.count > $1.count }.first { branch.name.hasPrefix($0 + "/") }
                    name = prefix.map { String(branch.name.dropFirst($0.count + 1)) } ?? branch.name
                }
            case .push:
                remote = model.upstream.flatMap { model.remotes.contains($0.remote) ? $0.remote : nil } ?? (model.remotes.contains("origin") ? "origin" : model.remotes.first ?? "")
                name = model.upstream?.branch ?? model.snapshot?.branch ?? ""
            default: break
            }
        }
    }
}
