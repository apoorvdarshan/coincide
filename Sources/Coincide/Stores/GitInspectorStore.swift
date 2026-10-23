import CoincideCore
import Foundation
import Observation

private struct GitInspectorRead: Sendable {
    var snapshot: GitSnapshot
    var branches: [GitBranch]
    var remotes: [String]
    var upstream: GitUpstream?
    var defaultBranch: GitDefaultBranch?
    var aheadOfDefault: Int?
}

/// Which changes the inspector reviews: the working tree, the index, or the whole branch.
enum GitInspectorDiffScope: String, CaseIterable, Identifiable, Sendable {
    case unstaged, staged, branch
    var id: String { rawValue }
    var title: String {
        switch self { case .unstaged: String(localized: "Unstaged"); case .staged: String(localized: "Staged"); case .branch: String(localized: "Branch") }
    }
}

/// UI state is isolated from provider/conversation state. A refresh cannot overwrite a newer
/// selection, and all controls share one in-flight operation even across asynchronous suspension.
@MainActor @Observable
final class GitInspectorStore {
    let git: GitService
    var snapshot: GitSnapshot?
    var branches: [GitBranch] = []
    var remotes: [String] = []
    var upstream: GitUpstream?
    var statusError: String?
    var operationError: String?
    var operationName: String?
    var isRefreshing = false
    var selected: String?
    var scope = GitInspectorDiffScope.unstaged
    /// Kept for existing callers; maps onto the unstaged/staged scopes.
    var staged: Bool {
        get { scope == .staged }
        set { scope = newValue ? .staged : (scope == .staged ? .unstaged : scope) }
    }
    /// The base for branch comparison: a local branch or remote-tracking name such as `origin/main`.
    var compareBase: String?
    var ignoreWhitespace = false
    var diff = ""
    private(set) var parsedDiff = UnifiedDiff()
    private(set) var diffTruncated = false
    private(set) var diffDescription: String?
    private(set) var defaultBranch: GitDefaultBranch?
    private(set) var aheadOfDefault: Int?
    /// The latest sanitized hook or Git output line while a compound action runs.
    private(set) var operationDetail: String?
    private(set) var operationStartedAt: Date?
    private(set) var catalog: GitBranchCatalog?
    private(set) var isLoadingCatalog = false
    private(set) var catalogError: String?
    private var catalogID = UUID()
    private var catalogTask: Task<GitBranchCatalog, any Error>?
    private var catalogReads: [UUID: Task<GitBranchCatalog, any Error>] = [:]
    var commitMessage = ""
    var isLoadingDiff = false
    private var refreshID = UUID()
    private var diffID = UUID()
    private var operationTask: Task<Void, Never>?
    private var readTask: Task<GitInspectorRead, any Error>?
    private var diffTask: Task<(String, UnifiedDiff, Bool, String?), any Error>?
    private var closed = false
    private let canMutate: @MainActor () -> Bool
    private var mutationGeneration = UUID()
    private var mutationSuspended = false
    var isBusy: Bool { closed || mutationSuspended || isRefreshing || operationName != nil || !canMutate() }
    var files: [ChangedFile] { snapshot?.changes ?? [] }

    init(path: String, networkTimeout: Duration = .seconds(120), canMutate: @escaping @MainActor () -> Bool = { true }) {
        git = .init(root: URL(fileURLWithPath: path), networkTimeout: networkTimeout); self.canMutate = canMutate
    }

    func refresh() async {
        guard !closed, !mutationSuspended, operationName == nil, canMutate() else { return }
        await reload()
    }
    private func reload() async {
        guard !closed, canMutate() else { return }
        let id = UUID(); refreshID = id; isRefreshing = true
        defer { if refreshID == id { isRefreshing = false; readTask = nil } }
        readTask?.cancel()
        let git = git
        let task = Task {
            let value = try await git.status()
            async let branches = git.branchDetails()
            async let remotes = git.remotes()
            let upstream = value.isDetached || value.isUnborn ? nil : try await git.upstream(for: value.branch)
            let defaultBranch = try? await git.defaultBranch(preferredRemote: upstream?.remote)
            var aheadOfDefault: Int?
            if let defaultBranch, !value.isDetached, !value.isUnborn {
                aheadOfDefault = try? await git.commitCount(from: defaultBranch.remoteRef ?? "refs/heads/" + defaultBranch.name)
            }
            return try await GitInspectorRead(snapshot: value, branches: branches, remotes: remotes, upstream: upstream,
                                              defaultBranch: defaultBranch, aheadOfDefault: aheadOfDefault)
        }
        readTask = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard refreshID == id, !closed, !Task.isCancelled else { return }
            snapshot = result.snapshot; branches = result.branches; remotes = result.remotes; upstream = result.upstream; statusError = nil
            defaultBranch = result.defaultBranch; aheadOfDefault = result.aheadOfDefault
            if compareBase == nil || !branches.contains(where: { $0.name == compareBase }) { compareBase = defaultCompareBase }
            if let selected, !files.contains(where: { $0.path == selected }) { self.selected = nil }
            await loadDiff()
        } catch is CancellationError { }
        catch {
            guard refreshID == id, !closed, !Task.isCancelled else { return }
            snapshot = nil; branches = []; remotes = []; upstream = nil; diff = ""; parsedDiff = .init(); statusError = error.localizedDescription
            defaultBranch = nil; aheadOfDefault = nil
        }
    }
    /// Read-only branch list for the picker, including worktree ownership and the default branch.
    func loadCatalog() async {
        guard !closed, !mutationSuspended, operationName == nil, canMutate() else { return }
        let id = UUID(); catalogID = id; isLoadingCatalog = true
        catalogTask?.cancel()
        defer {
            catalogReads.removeValue(forKey: id)
            if catalogID == id { isLoadingCatalog = false; catalogTask = nil }
        }
        do {
            let git = git, task = Task { try await git.branchCatalog() }
            catalogTask = task; catalogReads[id] = task
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard catalogID == id, !closed, !mutationSuspended, !Task.isCancelled else { return }
            catalog = value; catalogError = nil
        } catch is CancellationError { }
        catch { if catalogID == id, !closed { catalogError = error.localizedDescription } }
    }
    func loadDiff() async {
        guard !closed, canMutate() else { return }
        let id = UUID(); diffID = id; isLoadingDiff = true
        defer { if diffID == id { isLoadingDiff = false; diffTask = nil } }
        diffTask?.cancel()
        let selection = selected, wantsScope = scope, whitespace = ignoreWhitespace, base = compareBase
        do {
            let file = files.first { $0.path == selection }
            let git = git, task: Task<(String, UnifiedDiff, Bool, String?), any Error>
            if wantsScope == .branch {
                guard let base else { diff = ""; parsedDiff = .init(); diffTruncated = false; diffDescription = String(localized: "Choose a base branch to compare."); return }
                task = Task {
                    let value = try await git.branchDiff(baseRef: base, ignoreWhitespace: whitespace)
                    let note = value.omittedUntracked.isEmpty ? nil : String(localized: "\(value.omittedUntracked.count) untracked files are not shown.")
                    return (value.patch, UnifiedDiff.parse(value.patch, truncated: value.truncated), value.truncated, note)
                }
            } else {
                // A selected path can disappear during a refresh; never substitute the whole diff for it.
                guard selection == nil || file != nil else { diff = ""; parsedDiff = .init(); return }
                task = Task {
                    let text = try await git.diff(file: file, staged: wantsScope == .staged, ignoreWhitespace: whitespace)
                    return (text, UnifiedDiff.parse(text), false, nil)
                }
            }
            diffTask = task
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            // A branch review shows every file; selection only scrolls, so it never invalidates the read.
            guard diffID == id, !closed, wantsScope == .branch || selection == selected, wantsScope == scope, whitespace == ignoreWhitespace, base == compareBase, !Task.isCancelled else { return }
            diff = value.0; parsedDiff = value.1; diffTruncated = value.2; diffDescription = value.3
        } catch is CancellationError { }
        catch {
            guard diffID == id, !closed, !Task.isCancelled else { return }
            diff = ""; parsedDiff = .init(); diffTruncated = false
            if wantsScope == .branch { diffDescription = error.localizedDescription } else { operationError = error.localizedDescription }
        }
    }

    func initialize(branch: String) { perform("Initializing repository…") { try await self.git.initialize(branch: branch) } }
    func stage(_ paths: [String]) { perform("Staging…") { try await self.git.stage(paths) } }
    func unstage(_ paths: [String]) { perform("Unstaging…") { try await self.git.unstage(paths) } }
    func commit() {
        let message = commitMessage
        perform("Committing…") { try await self.git.commit(message: message); if self.commitMessage == message { self.commitMessage = "" } }
    }
    func checkout(_ branch: String) { perform("Switching branch…") { try await self.git.checkout(branch: branch) } }
    func createBranch(_ branch: String, tracking: String? = nil) { perform("Creating branch…") { try await self.git.createBranch(branch, tracking: tracking) } }
    func fetch(_ remote: String) { perform("Fetching \(remote)…") { try await self.git.fetch(remote: remote) } }
    func pull() {
        guard let snapshot else { return }; let branch = snapshot.branch
        perform("Pulling \(branch)…") { try await self.git.pull(branch: branch) }
    }
    func push(remote: String, branch: String, setUpstream: Bool) {
        guard let snapshot else { return }; let localBranch = snapshot.branch
        perform("Pushing to \(remote)/\(branch)…") { try await self.git.push(branch: localBranch, remote: remote, remoteBranch: branch, setUpstream: setUpstream) }
    }
    /// The remote-tracking default (e.g. `origin/main`) when known, else the local default branch.
    var defaultCompareBase: String? {
        if let name = defaultBranch?.remoteName, branches.contains(where: { $0.name == name }) { return name }
        if let name = defaultBranch?.name, branches.contains(where: { $0.name == name && !$0.isRemote }) { return name }
        return nil
    }
    /// The conversation-facing quick-action status, combining local Git with the PR context.
    func quickActionStatus(hasOpenPullRequest: Bool) -> GitQuickActionStatus? {
        guard let snapshot else { return nil }
        return .init(hasBranch: !snapshot.isDetached, hasChanges: !snapshot.isClean, hasOpenPullRequest: hasOpenPullRequest,
                     aheadCount: snapshot.ahead ?? (snapshot.upstream == nil && !snapshot.isUnborn ? (aheadOfDefault ?? 0) : 0), behindCount: snapshot.behind ?? 0,
                     aheadOfDefaultCount: aheadOfDefault, hasUpstream: snapshot.upstream != nil)
    }
    /// Runs a multi-step mutation as this inspector's single exclusive operation. Returns false when busy.
    @discardableResult
    func runExclusive(_ name: String, operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        perform(name, operation: operation)
        return operationTask
    }
    func updateOperation(name: String? = nil, detail: String?) {
        guard operationName != nil else { return }
        if let name { operationName = name }
        operationDetail = detail
    }
    func cancel() { operationTask?.cancel() }
    func waitForOperation() async { await operationTask?.value }
    func suspendForWorkspaceMutation() {
        mutationGeneration = UUID(); mutationSuspended = true
        catalogID = UUID(); isLoadingCatalog = false; for task in catalogReads.values { task.cancel() }
        refreshID = UUID(); diffID = UUID(); readTask?.cancel(); diffTask?.cancel()
        readTask = nil; diffTask = nil; isRefreshing = false; isLoadingDiff = false
    }
    func refreshAfterWorkspaceMutation() async {
        guard !closed, canMutate() else { return }
        await drainCatalogReads()
        let generation = mutationGeneration
        mutationSuspended = true
        defer { if mutationGeneration == generation { mutationSuspended = false } }
        await reload()
    }
    func prepareForShutdown() {
        closed = true; catalogID = UUID(); isLoadingCatalog = false
        operationTask?.cancel(); readTask?.cancel(); diffTask?.cancel()
        for task in catalogReads.values { task.cancel() }
    }
    func shutdown() async {
        prepareForShutdown()
        await operationTask?.value; _ = try? await readTask?.value; _ = try? await diffTask?.value
        await drainCatalogReads()
    }
    private func drainCatalogReads() async {
        while !catalogReads.isEmpty {
            for task in Array(catalogReads.values) { _ = await task.result }
            await Task.yield()
        }
    }

    private func perform(_ name: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        operationName = name; operationError = nil; refreshID = UUID(); diffID = UUID(); operationDetail = nil; operationStartedAt = Date()
        operationTask = Task {
            do { try await operation() }
            catch is CancellationError { operationError = "Cancelled. Git may already have applied changes; the repository has been refreshed." }
            catch { operationError = error.localizedDescription }
            // A cancelled task must still reload the actual result, especially after a remote push.
            if !closed { let refresh = Task { await self.reload() }; await refresh.value }
            operationName = nil; operationTask = nil; operationDetail = nil; operationStartedAt = nil
        }
    }
}
