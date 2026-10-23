import CoincideCore
import Foundation
import Observation

@MainActor @Observable
final class RemoteGitInspectorStore {
    let session: RemoteWorkspaceInspectorSession
    private(set) var snapshot: GitSnapshot?
    private(set) var branches: [GitBranch] = []
    private(set) var remotes: [String] = []
    private(set) var diff = ""
    private(set) var isRefreshing = false
    private(set) var isLoadingDiff = false
    var selected: String?
    var staged = false
    var commitMessage = ""
    var statusError: String?
    var operationError: String?
    @ObservationIgnored var hasDirtyFiles: @MainActor () -> Bool = { false }
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var diffID = UUID()

    init(session: RemoteWorkspaceInspectorSession) { self.session = session }
    var files: [ChangedFile] { snapshot?.changes ?? [] }
    var canMutate: Bool { session.canMutate && !isRefreshing }
    var canChangeWorkingTree: Bool { canMutate && !hasDirtyFiles() }
    var upstreamRemote: String? {
        guard let upstream = snapshot?.upstream else { return nil }
        return remotes.sorted { $0.count > $1.count }.first { upstream.hasPrefix($0 + "/") }
    }
    var upstreamBranch: String? {
        guard let remote = upstreamRemote, let upstream = snapshot?.upstream else { return nil }
        return String(upstream.dropFirst(remote.count + 1))
    }

    func refresh() async {
        guard session.canRead else { return }
        let owner = UUID(); refreshID = owner; isRefreshing = true
        defer { if refreshID == owner { isRefreshing = false } }
        do {
            async let status = session.read(.gitStatus)
            async let branchList = session.read(.gitBranches)
            async let remoteList = session.read(.gitRemotes)
            let values = try await (status, branchList, remoteList)
            guard refreshID == owner, !Task.isCancelled else { return }
            guard case .git(let value) = values.0, case .branches(let branches) = values.1, case .remotes(let remotes) = values.2 else {
                throw RemoteWorkspaceFailure(.invalidRequest)
            }
            snapshot = value; self.branches = branches; self.remotes = remotes; statusError = nil
            if let selected, !files.contains(where: { $0.path.utf8.elementsEqual(selected.utf8) }) { self.selected = nil }
            await loadDiff()
        } catch is CancellationError { }
        catch { if refreshID == owner { statusError = RemoteWorkspaceInspectorSession.safeMessage(error) } }
    }

    func loadDiff() async {
        guard session.canRead else { return }
        let owner = UUID(); diffID = owner; isLoadingDiff = true
        let selection = selected, wantsStaged = staged
        defer { if diffID == owner { isLoadingDiff = false } }
        do {
            let file = files.first { candidate in selection.map { candidate.path.utf8.elementsEqual($0.utf8) } ?? false }
            guard selection == nil || file != nil else { diff = ""; return }
            guard case .diff(let value) = try await session.read(.gitDiff(file: file, staged: wantsStaged)) else {
                throw RemoteWorkspaceFailure(.invalidRequest)
            }
            guard diffID == owner, selection.map({ Data($0.utf8) }) == selected.map({ Data($0.utf8) }), wantsStaged == staged, !Task.isCancelled else { return }
            diff = value
        } catch is CancellationError { }
        catch { if diffID == owner { operationError = RemoteWorkspaceInspectorSession.safeMessage(error) } }
    }

    func initialize(branch: String) async { guard canChangeWorkingTree else { return }; await session.perform(.gitInitialize(branch: branch)) }
    func stage(_ paths: [String]) async { guard canMutate else { return }; await session.perform(.gitStage(paths: paths)) }
    func unstage(_ paths: [String]) async { guard canMutate else { return }; await session.perform(.gitUnstage(paths: paths)) }
    func commit() async {
        guard canMutate, !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await session.perform(.gitCommit(message: commitMessage))
    }
    func checkout(_ branch: String) async { guard canChangeWorkingTree else { return }; await session.perform(.gitCheckout(branch: branch)) }
    func createBranch(_ branch: String, tracking: String?) async {
        guard canChangeWorkingTree else { return }; await session.perform(.gitCreateBranch(branch: branch, tracking: tracking))
    }
    func fetch(_ remote: String) async { guard canMutate else { return }; await session.perform(.gitFetch(remote: remote)) }
    func pull() async {
        guard canChangeWorkingTree, let snapshot, !snapshot.isDetached, !snapshot.isUnborn, snapshot.upstream != nil else { return }
        await session.perform(.gitPull(branch: snapshot.branch))
    }
    func push(remote: String, branch: String, setUpstream: Bool) async {
        guard canMutate, let snapshot, !snapshot.isDetached, !snapshot.isUnborn else { return }
        await session.perform(.gitPush(branch: snapshot.branch, remote: remote, remoteBranch: branch, setUpstream: setUpstream))
    }

    func operationFinished(_ request: RemoteWorkspaceMutationRequest, operation: RemoteWorkspaceOperation) {
        guard operation.state == .finished else { return }
        if operation.failure == nil, case .gitCommit(let sent) = request.mutation, commitMessage.utf8.elementsEqual(sent.utf8) { commitMessage = "" }
        if let failure = operation.failure { operationError = failure.localizedDescription }
        Task { await refresh() }
    }
}
