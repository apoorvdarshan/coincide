import AppKit
import CoincideCore
import SwiftUI

enum BranchPickerChoice: Equatable {
    case checkout(String)
    case track(GitBranchCatalogEntry)
    case create(String)
    case pullRequest(String)
    case openWorktree(String)
    case base(String)
}

/// Pure row model so search, creation and PR detection are testable without a view.
struct BranchPickerRows: Equatable {
    var create: String?
    var pullRequest: String?
    var local: [GitBranchCatalogEntry] = []
    var otherWorktrees: [GitBranchCatalogEntry] = []
    var remote: [GitBranchCatalogEntry] = []

    static func make(catalog: GitBranchCatalog?, query: String, allowsCreate: Bool = true, allowsPullRequest: Bool = true, limit: Int = 200) -> Self {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = Self()
        guard let catalog else { return rows }
        let ranked = GitBranchSearch.rank(catalog.entries, query: trimmed, defaultBranch: catalog.defaultBranch?.name)
        for entry in ranked {
            if entry.isRemote { if rows.remote.count < limit { rows.remote.append(entry) } }
            else if catalog.otherWorktree(for: entry) != nil { if rows.otherWorktrees.count < limit { rows.otherWorktrees.append(entry) } }
            else if rows.local.count < limit { rows.local.append(entry) }
        }
        if allowsPullRequest, let reference = pullRequestReference(trimmed) { rows.pullRequest = reference }
        if allowsCreate, rows.pullRequest == nil, isCreatable(trimmed, existing: catalog.locals.map(\.name)) { rows.create = trimmed }
        return rows
    }

    /// `#12`, `12` or a GitHub pull request URL.
    static func pullRequestReference(_ query: String) -> String? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if !digits.isEmpty, digits.count <= 9, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), Int(digits).map({ $0 > 0 }) == true { return "#" + digits }
        if let url = URLComponents(string: value), url.scheme == "https", url.host != nil {
            let parts = url.path.split(separator: "/")
            if parts.count == 4, parts[2] == "pull", Int(parts[3]).map({ $0 > 0 }) == true { return value }
        }
        return nil
    }

    /// A conservative client check; Git still validates the final name.
    static func isCreatable(_ name: String, existing: [String]) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 250, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."), !name.hasSuffix(".lock"),
              !name.contains(".."), !name.contains("//"), !name.contains("@{"), name != "@", name != "HEAD",
              !name.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || "~^:?*[\\".unicodeScalars.contains($0) }),
              name.split(separator: "/").allSatisfy({ !$0.hasPrefix(".") }) else { return false }
        return !existing.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

struct BranchPickerView: View {
    let catalog: GitBranchCatalog?
    let loading: Bool
    let error: String?
    var title = String(localized: "Switch Branch")
    var baseMode = false
    var allowsCreate = true
    var allowsPullRequest = true
    var disabledReason: String? = nil
    let choose: (BranchPickerChoice) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var rows: BranchPickerRows {
        BranchPickerRows.make(catalog: catalog, query: query, allowsCreate: allowsCreate && !baseMode, allowsPullRequest: allowsPullRequest && !baseMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(baseMode ? "Search branches" : "Search, create a branch, or #PR", text: $query)
                    .textFieldStyle(.plain).focused($focused).onSubmit(submit)
                    .accessibilityIdentifier("branch-picker-search")
                if loading { ProgressView().controlSize(.mini) }
            }.padding(10)
            Divider()
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).padding(10) }
            if let disabledReason { Text(disabledReason).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8) }
            List {
                let rows = rows
                if rows.create != nil || rows.pullRequest != nil {
                    Section {
                        if let name = rows.create {
                            row(systemImage: "plus", title: String(localized: "Create branch “\(name)”"), subtitle: nil, id: "branch-picker-create") { choose(.create(name)) }
                                .disabled(disabledReason != nil)
                        }
                        if let reference = rows.pullRequest {
                            row(systemImage: "arrow.triangle.pull", title: String(localized: "Check out pull request \(reference)"), subtitle: nil, id: "branch-picker-pull-request") { choose(.pullRequest(reference)) }
                        }
                    }
                }
                if !rows.local.isEmpty {
                    Section("Local") {
                        ForEach(rows.local) { entry in
                            row(systemImage: entry.isHead ? "checkmark" : "arrow.triangle.branch", title: entry.name,
                                subtitle: entry.name == catalog?.defaultBranch?.name ? String(localized: "Default") : entry.upstream,
                                id: "branch-picker-local-\(entry.name)") { choose(baseMode ? .base(entry.name) : .checkout(entry.name)) }
                                .disabled(!baseMode && (entry.isHead || disabledReason != nil))
                        }
                    }
                }
                if !rows.otherWorktrees.isEmpty {
                    Section("In Other Worktrees") {
                        ForEach(rows.otherWorktrees) { entry in
                            let path = catalog?.otherWorktree(for: entry) ?? ""
                            row(systemImage: "folder", title: entry.name, subtitle: path, id: "branch-picker-worktree-\(entry.name)") {
                                choose(baseMode ? .base(entry.name) : .openWorktree(path))
                            }.help(baseMode ? String(localized: "Use this branch as the base.") : String(localized: "Checked out in another worktree. Open that checkout as a project."))
                        }
                    }
                }
                if !rows.remote.isEmpty {
                    Section("Remote") {
                        ForEach(rows.remote) { entry in
                            row(systemImage: "cloud", title: entry.name, subtitle: nil, id: "branch-picker-remote-\(entry.name)") {
                                choose(baseMode ? .base(entry.name) : .track(entry))
                            }.disabled(!baseMode && disabledReason != nil)
                        }
                    }
                }
                if catalog != nil, rows.local.isEmpty, rows.remote.isEmpty, rows.otherWorktrees.isEmpty, rows.create == nil, rows.pullRequest == nil {
                    Text("No matching branches").foregroundStyle(.secondary)
                }
            }.listStyle(.inset).frame(minHeight: 160, idealHeight: 320, maxHeight: 420)
        }
        .frame(width: 340)
        .onAppear { focused = true }
        .accessibilityIdentifier("branch-picker")
    }

    private func row(systemImage: String, title: String, subtitle: String?, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 16).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }

    private func submit() {
        let rows = rows
        if let reference = rows.pullRequest { choose(.pullRequest(reference)) }
        else if let first = rows.local.first, first.name.caseInsensitiveCompare(query.trimmingCharacters(in: .whitespaces)) == .orderedSame {
            if baseMode { choose(.base(first.name)) } else if !first.isHead, disabledReason == nil { choose(.checkout(first.name)) }
        } else if let name = rows.create, disabledReason == nil { choose(.create(name)) }
        else if baseMode, let first = rows.local.first ?? rows.remote.first { choose(.base(first.name)) }
    }
}

/// The inspector and conversation header share this searchable, worktree-aware picker.
struct GitBranchPickerButton: View {
    let workspace: WorkspaceStore
    let model: GitInspectorStore
    var compact = false
    var disabledReason: String?
    let choose: (BranchPickerChoice) -> Void
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Label(model.snapshot?.displayBranch ?? String(localized: "Source control"), systemImage: "arrow.triangle.branch")
                .lineLimit(1).truncationMode(.middle)
                .font(compact ? .caption : nil).foregroundStyle(compact ? .secondary : .primary)
        }
        .buttonStyle(.borderless)
        .disabled(model.snapshot == nil)
        .help("Switch, create or search branches")
        .accessibilityLabel("Branch")
        .accessibilityValue(model.snapshot?.displayBranch ?? "")
        .accessibilityIdentifier(compact ? "conversation-branch" : "git-branch-picker")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            BranchPickerView(catalog: model.catalog, loading: model.isLoadingCatalog, error: model.catalogError, disabledReason: disabledReason) { choice in
                presented = false; choose(choice)
            }
            .task { await model.loadCatalog() }
        }
    }
}

/// The branch for the conversation's checkout, shown in the conversation header with the same picker.
struct ConversationBranchChip: View {
    let store: WorkspaceStore
    let thread: CodingThread
    @State private var model: GitInspectorStore?
    @State private var pullRequestQuery: String?

    private var disabledReason: String? {
        guard let model else { return nil }
        if thread.isBusy || !thread.queuedTurns.isEmpty { return String(localized: "Branches can change after this conversation's work finishes.") }
        if model.isBusy || !store.canEditWorkspace(thread.workspacePath) { return String(localized: "Branches can change after the current workspace action finishes.") }
        return nil
    }

    var body: some View {
        Group {
            if let model, model.snapshot != nil {
                GitBranchPickerButton(workspace: store, model: model, compact: true, disabledReason: disabledReason) { choice in
                    switch choice {
                    case .checkout(let name): model.checkout(name)
                    case .create(let name): model.createBranch(name)
                    case .track(let entry): model.createBranch(entry.localName, tracking: entry.ref)
                    case .pullRequest(let reference): pullRequestQuery = reference
                    case .openWorktree(let path): store.addProject(at: URL(fileURLWithPath: path))
                    case .base: break
                    }
                }.fixedSize()
            }
        }
        .task(id: "\(thread.workspacePath)|\(thread.isBusy)") {
            guard store.workspaceReady(for: thread) else { model = nil; return }
            let inspector = store.gitInspector(path: thread.workspacePath); model = inspector
            await inspector.refresh()
        }
        .sheet(isPresented: Binding(get: { pullRequestQuery != nil }, set: { if !$0 { pullRequestQuery = nil } })) {
            if let query = pullRequestQuery {
                PullRequestsSheet(model: store.pullRequestStore(path: thread.workspacePath), initialReference: query, requestPush: { pullRequestQuery = nil })
            }
        }
    }
}
