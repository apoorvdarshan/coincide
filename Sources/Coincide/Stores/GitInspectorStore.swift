import CoincideCore
import Foundation
import Observation

private struct GitInspectorRead: Sendable {
    var snapshot: GitSnapshot
    var branches: [GitBranch]
    var remotes: [String]
    var upstream: GitUpstream?
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
    var staged = false
    var diff = ""
    var commitMessage = ""
    var isLoadingDiff = false
    private var refreshID = UUID()
    private var diffID = UUID()
    private var operationTask: Task<Void, Never>?
    private var readTask: Task<GitInspectorRead, any Error>?
    private var diffTask: Task<String, any Error>?
    private var closed = false
    var isBusy: Bool { closed || isRefreshing || operationName != nil }
    var files: [ChangedFile] { snapshot?.changes ?? [] }

    init(path: String, networkTimeout: Duration = .seconds(120)) { git = .init(root: URL(fileURLWithPath: path), networkTimeout: networkTimeout) }

    func refresh() async {
        guard !closed, operationName == nil else { return }
        await reload()
    }
    private func reload() async {
        guard !closed else { return }
        let id = UUID(); refreshID = id; isRefreshing = true
        defer { if refreshID == id { isRefreshing = false; readTask = nil } }
        readTask?.cancel()
        let git = git
        let task = Task {
            let value = try await git.status()
            async let branches = git.branchDetails()
            async let remotes = git.remotes()
            let upstream = value.isDetached || value.isUnborn ? nil : try await git.upstream(for: value.branch)
            return try await GitInspectorRead(snapshot: value, branches: branches, remotes: remotes, upstream: upstream)
        }
        readTask = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard refreshID == id, !closed, !Task.isCancelled else { return }
            snapshot = result.snapshot; branches = result.branches; remotes = result.remotes; upstream = result.upstream; statusError = nil
            if let selected, !files.contains(where: { $0.path == selected }) { self.selected = nil }
            await loadDiff()
        } catch is CancellationError { }
        catch {
            guard refreshID == id, !closed, !Task.isCancelled else { return }
            snapshot = nil; branches = []; remotes = []; upstream = nil; diff = ""; statusError = error.localizedDescription
        }
    }
    func loadDiff() async {
        guard !closed else { return }
        let id = UUID(); diffID = id; isLoadingDiff = true
        defer { if diffID == id { isLoadingDiff = false; diffTask = nil } }
        diffTask?.cancel()
        let selection = selected, wantsStaged = staged
        do {
            let file = files.first { $0.path == selection }
            // A selected path can disappear during a refresh; never substitute the whole diff for it.
            guard selection == nil || file != nil else { diff = ""; return }
            let git = git, task = Task { try await git.diff(file: file, staged: wantsStaged) }; diffTask = task
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard diffID == id, !closed, selection == selected, wantsStaged == staged, !Task.isCancelled else { return }
            diff = value
        } catch is CancellationError { }
        catch { if diffID == id, !closed, !Task.isCancelled { diff = ""; operationError = error.localizedDescription } }
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
    func cancel() { operationTask?.cancel() }
    func waitForOperation() async { await operationTask?.value }
    func prepareForShutdown() { closed = true; operationTask?.cancel(); readTask?.cancel(); diffTask?.cancel() }
    func shutdown() async {
        prepareForShutdown()
        await operationTask?.value; _ = try? await readTask?.value; _ = try? await diffTask?.value
    }

    private func perform(_ name: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        operationName = name; operationError = nil; refreshID = UUID(); diffID = UUID()
        operationTask = Task {
            do { try await operation() }
            catch is CancellationError { operationError = "Cancelled. Git may already have applied changes; the repository has been refreshed." }
            catch { operationError = error.localizedDescription }
            // A cancelled task must still reload the actual result, especially after a remote push.
            if !closed { let refresh = Task { await self.reload() }; await refresh.value }
            operationName = nil; operationTask = nil
        }
    }
}
