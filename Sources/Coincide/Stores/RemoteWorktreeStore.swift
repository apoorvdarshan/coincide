import CoincideCore
import Foundation
import Observation

enum RemoteWorktreeMode: String, CaseIterable, Identifiable {
    case newBranch, existingBranch, registeredWorktree
    var id: Self { self }
    var title: String { switch self { case .newBranch: "New Branch"; case .existingBranch: "Existing Branch"; case .registeredWorktree: "Registered Worktree" } }
}

@MainActor @Observable
final class RemoteWorktreeStore {
    typealias Command = @MainActor (RemoteEnvironmentCommand) async -> Bool
    typealias CatalogLoader = @Sendable (RemoteWorkspaceTarget) async throws -> RemoteWorktreeCatalog
    private(set) var preparation: ThreadWorkspacePreparation?
    private(set) var catalog: RemoteWorktreeCatalog?
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var catalogError: String?
    private(set) var actionError: String?
    private(set) var setupThreadTitle = ""
    private(set) var setupWorkspacePath = ""
    var mode = RemoteWorktreeMode.newBranch
    var branchName = ""
    var baseRef = "HEAD"
    var existingBranch = Data()
    var worktreePath = Data()
    var submodules = ProjectWorktreeSubmoduleMode.none
    @ObservationIgnored private var target: RemoteWorkspaceTarget?
    @ObservationIgnored private var thread: CodingThread?
    @ObservationIgnored private var connected = false
    @ObservationIgnored private var supported = false
    @ObservationIgnored private var writesAllowed = false
    @ObservationIgnored private var workspaceChangeAllowed = false
    @ObservationIgnored private var command: Command?
    @ObservationIgnored private var load: CatalogLoader?
    @ObservationIgnored private var clientIdentity: ObjectIdentifier?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var setupGeneration: UUID?
    @ObservationIgnored private var setupTarget: RemoteWorkspaceTarget?
    @ObservationIgnored private var setupLoader: CatalogLoader?
    @ObservationIgnored private var catalogRead = UUID()
    @ObservationIgnored private var stopping = false

    func update(environmentID: UUID?, thread: CodingThread?, client: RemoteEnvironmentClient?, supported: Bool,
                canWrite: Bool, canChangeWorkspace: Bool, perform: @escaping Command) {
        let next = environmentID.flatMap { environmentID in thread.map { RemoteWorkspaceTarget(environmentID: environmentID,
            projectID: $0.projectID, threadID: $0.id, configuration: .init(thread: $0)) } }
        let identity = client.map(ObjectIdentifier.init)
        let loader: CatalogLoader?
        if let client { loader = { target in try await client.worktreeCatalog(target: target) } }
        else { loader = nil }
        update(target: next, thread: thread, loader: loader,
            connected: client != nil, supported: supported, canWrite: canWrite, canChangeWorkspace: canChangeWorkspace,
            identityChanged: identity != clientIdentity, perform: perform)
        clientIdentity = identity
    }

    /// The test seam is a typed remote catalog loader, never a filesystem path.
    func update(target next: RemoteWorkspaceTarget?, thread: CodingThread?, loader: CatalogLoader?, connected: Bool,
                supported: Bool, canWrite: Bool, canChangeWorkspace: Bool, identityChanged: Bool = false, perform: @escaping Command) {
        guard !stopping else { return }
        let changed = !Self.sameCapture(target, next) || preparation?.id != thread?.workspacePreparation?.id || identityChanged || self.connected != connected
        if changed { generation = UUID(); catalogRead = UUID(); isLoading = false }
        target = next; self.thread = thread; preparation = thread?.workspacePreparation
        self.connected = connected; self.supported = supported; writesAllowed = canWrite
        workspaceChangeAllowed = canChangeWorkspace; command = perform; load = loader
    }

    var canChoose: Bool {
        guard !stopping, supported, connected, writesAllowed, workspaceChangeAllowed, !isWorking,
              let thread, !thread.isArchived, thread.messages.isEmpty, !thread.isBusy, thread.queuedTurns.isEmpty,
              thread.settlement == nil, preparation == nil || preparation?.isReady == true || preparation?.canRetry == true else { return false }
        return target != nil
    }
    var setupIsCurrent: Bool { setupGeneration == generation && setupTarget != nil && !stopping }
    var canPrepare: Bool { canChoose && setupIsCurrent && !isLoading && catalog != nil && catalogError == nil && selection != nil }
    var canCancel: Bool { canAct && preparation?.isRunning == true && preparation?.cancelRequested == false }
    var canRetry: Bool { canAct && workspaceChangeAllowed && preparation?.canRetry == true }
    var canInspect: Bool { canAct && preparation?.canRetry == true && preparation?.plan != nil }
    private var canAct: Bool { !stopping && supported && connected && writesAllowed && !isWorking && target != nil }
    var eligibilityMessage: String? {
        if !supported { return "This remote helper does not support worktree setup. Update the helper to enable it." }
        if !connected { return "Reconnect to choose or recover a worktree on the remote Mac." }
        if !workspaceChangeAllowed { return "Save or discard remote file edits and close live remote terminals before changing this conversation's checkout." }
        if thread?.settlement != nil { return "Resume this conversation before choosing another checkout." }
        if thread?.messages.isEmpty == false || thread?.isBusy == true || thread?.queuedTurns.isEmpty == false { return "Choose a worktree before the first message, with no running or queued turns." }
        if preparation?.isRunning == true { return "Wait for the current preparation or cancel it before choosing another worktree." }
        if !writesAllowed { return "Finish or inspect the current remote request before changing the checkout." }
        return nil
    }
    var localBranches: [GitBranch] { catalog?.branches.filter { !$0.isRemote } ?? [] }
    var reusableWorktrees: [GitWorktree] {
        catalog?.worktrees.filter { !$0.isBare && !$0.isDetached && $0.prunableReason == nil && $0.branch != nil && $0.headCommit != nil } ?? []
    }
    func branchIsCheckedOut(_ name: String) -> Bool {
        catalog?.worktrees.contains { $0.branch?.utf8.elementsEqual(name.utf8) == true } ?? false
    }
    var selection: GitWorktreeSelection? {
        switch mode {
        case .newBranch:
            guard Self.nonempty(branchName, limit: 1_024), Self.nonempty(baseRef, limit: 1_024) else { return nil }
            return .createBranch(name: branchName, baseRef: baseRef)
        case .existingBranch:
            guard let branch = localBranches.first(where: { Data($0.name.utf8) == existingBranch }), !branchIsCheckedOut(branch.name) else { return nil }
            return .existingBranch(name: branch.name)
        case .registeredWorktree:
            guard let worktree = reusableWorktrees.first(where: { Data($0.path.utf8) == worktreePath }) else { return nil }
            return .reuse(path: worktree.path)
        }
    }

    @discardableResult func beginSetup() -> Bool {
        guard canChoose, let target, let thread, let load else { return false }
        if setupTarget?.environmentID != target.environmentID || setupTarget?.threadID != target.threadID {
            mode = .newBranch; branchName = ""; baseRef = "HEAD"; existingBranch = Data(); worktreePath = Data(); submodules = .none
        }
        setupGeneration = generation; setupTarget = target; setupLoader = load
        setupThreadTitle = thread.title; setupWorkspacePath = target.workspacePath
        catalog = nil; catalogError = nil; actionError = nil
        return true
    }

    func loadCatalog() async {
        guard setupIsCurrent, let requested = setupTarget, let loader = setupLoader else { return }
        let owner = generation, read = UUID(); catalogRead = read
        isLoading = true; catalogError = nil
        defer { if catalogRead == read { isLoading = false } }
        do {
            let value = try await loader(requested)
            guard generation == owner, catalogRead == read, setupIsCurrent, !Task.isCancelled else { return }
            guard Self.sameCapture(value.target, requested), value.attemptID == preparation?.id,
                  value.branches.count <= 25_000, value.worktrees.count <= 25_000 else { throw RemoteWorkspaceFailure(.invalidTarget) }
            catalog = value
            if !localBranches.contains(where: { Data($0.name.utf8) == existingBranch }) { existingBranch = Data() }
            if !reusableWorktrees.contains(where: { Data($0.path.utf8) == worktreePath }) { worktreePath = Data() }
        } catch is CancellationError { }
        catch { if generation == owner, catalogRead == read { catalogError = Self.safeMessage(error) } }
    }

    @discardableResult func prepare() async -> Bool {
        guard canPrepare, let catalog, let selection, let command else { return false }
        let captured = RemoteEnvironmentCommand.prepareWorktree(target: catalog.target, sourceRootID: catalog.sourceRootID,
            expectedAttemptID: catalog.attemptID, selection: selection,
            submodules: mode == .registeredWorktree ? .none : submodules)
        return await execute(captured, using: command)
    }
    func retry() async {
        guard canRetry, let target, let attempt = preparation?.id, let command else { return }
        _ = await execute(.retryWorktree(target: target, attemptID: attempt), using: command)
    }
    func cancel() async {
        guard canCancel, let target, let attempt = preparation?.id, let command else { return }
        _ = await execute(.cancelWorktree(target: target, attemptID: attempt), using: command)
    }
    func inspect() async {
        guard canInspect, let target, let attempt = preparation?.id, let command else { return }
        _ = await execute(.inspectWorktree(target: target, attemptID: attempt), using: command)
    }
    private func execute(_ captured: RemoteEnvironmentCommand, using command: Command) async -> Bool {
        isWorking = true; actionError = nil
        defer { isWorking = false }
        // Root persists this exact native command before sending it. A missing
        // response remains in the shared request journal; never retry here.
        return await command(captured)
    }

    func disconnect() {
        generation = UUID(); catalogRead = UUID(); connected = false
        writesAllowed = false; workspaceChangeAllowed = false; clientIdentity = nil
        load = nil; setupLoader = nil; command = nil; isLoading = false
    }
    func shutdown() async { stopping = true; disconnect() }
    func cancelShutdown() { stopping = false }

    private static func sameCapture(_ lhs: RemoteWorkspaceTarget?, _ rhs: RemoteWorkspaceTarget?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard sameWorkspace(lhs, rhs) else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(lhs.configuration)) == (try? encoder.encode(rhs.configuration))
    }
    private static func sameWorkspace(_ lhs: RemoteWorkspaceTarget, _ rhs: RemoteWorkspaceTarget) -> Bool {
        lhs.environmentID == rhs.environmentID && lhs.projectID == rhs.projectID && lhs.threadID == rhs.threadID && lhs.workspacePath.utf8.elementsEqual(rhs.workspacePath.utf8)
    }
    private static func nonempty(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= limit && !value.contains("\0")
    }
    private static func safeMessage(_ error: any Error) -> String {
        if let error = error as? RemoteEnvironmentClientError { return error.localizedDescription }
        if let error = error as? RemoteWorkspaceFailure { return error.localizedDescription }
        return "The remote worktree inventory could not be read. No checkout was changed."
    }
}
