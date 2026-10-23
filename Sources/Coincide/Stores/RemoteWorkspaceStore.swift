import CoincideCore
import Foundation
import Observation

struct RemoteWorkspaceConnection {
    var id: UUID
    var name: String
    var configuration: SSHRemoteEnvironmentConfiguration
    var environmentID: UUID?
    init(id: UUID = UUID(), name: String, configuration: SSHRemoteEnvironmentConfiguration, environmentID: UUID? = nil) {
        self.id = id; self.name = name; self.configuration = configuration; self.environmentID = environmentID
    }
    init(_ saved: RemoteEnvironmentConnection) {
        self.init(id: saved.id, name: saved.name, configuration: saved.configuration, environmentID: saved.environmentID)
    }
}

/// Remote snapshots never enter WorkspaceStore: their paths and runtime IDs
/// belong to the remote machine, including when a local path happens to match.
@MainActor @Observable
final class RemoteWorkspaceStore {
    typealias ClientFactory = @Sendable (SSHRemoteEnvironmentConfiguration, UUID?) throws -> RemoteEnvironmentClient
    static let sceneID = "remote-workspaces"
    private(set) var connections: [RemoteEnvironmentConnection] = []
    private(set) var connection: RemoteWorkspaceConnection?
    private(set) var descriptor: RemoteEnvironmentDescriptor?
    private(set) var snapshot: RemoteEnvironmentSnapshot?
    private(set) var pending: RemoteEnvironmentPendingCommand?
    private(set) var drafts: [UUID: String] = [:]
    private(set) var isConnected = false
    private(set) var isWorking = false
    private(set) var needsTrust = false
    private(set) var isLoaded = false
    private(set) var draftsSaving = false
    private(set) var draftPersistenceFailed = false
    let inspector: RemoteWorkspaceInspectorStore
    let terminals = RemoteTerminalStore()
    let worktrees = RemoteWorktreeStore()
    let attachments: RemoteAttachmentsStore
    let pullRequests: RemotePullRequestStore
    let checkpoints = RemoteCheckpointStore()
    let history = RemoteHistoryStore()
    let projection = RemoteProjectionStore()
    private(set) var usesProjection = false
    private(set) var isPreparingSubmission = false
    var inspectorVisible = true
    var terminalsVisible = false
    var selectedThreadID: UUID?
    var selectedProjectID: UUID?
    var errorMessage: String?
    var notice: String?

    @ObservationIgnored private let registryRoot: URL
    @ObservationIgnored private let pendingStore: RemoteEnvironmentPendingStore
    @ObservationIgnored private let draftStore: RemoteEnvironmentDraftStore
    @ObservationIgnored private let clientFactory: ClientFactory
    @ObservationIgnored private var client: RemoteEnvironmentClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var draftWrites: Task<Bool, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var draftRevision = 0
    @ObservationIgnored private var minimumSequences: [UUID: Int64] = [:]

    init(root: URL, clientFactory: @escaping ClientFactory = { try SSHRemoteEnvironment.makeClient(configuration: $0, expectedEnvironmentID: $1) }) {
        registryRoot = root
        self.clientFactory = clientFactory
        pendingStore = .init(root: root.appendingPathComponent("Pending", isDirectory: true))
        draftStore = .init(root: root.appendingPathComponent("Drafts", isDirectory: true))
        inspector = .init(pendingStore: .init(root: root.appendingPathComponent("WorkspaceOperations", isDirectory: true)))
        attachments = .init(root: root.appendingPathComponent("Attachments", isDirectory: true))
        pullRequests = .init(root: root.appendingPathComponent("PullRequestDrafts", isDirectory: true))
    }

    var projects: [WorkspaceProject] { snapshot?.workspace.projects ?? [] }
    var threads: [CodingThread] { snapshot?.workspace.threads.filter { !$0.isArchived } ?? [] }
    var selectedThread: CodingThread? { threads.first { $0.id == selectedThreadID } }
    var canWrite: Bool { isConnected && !isWorking && !isPreparingSubmission && pending == nil && !stopping }
    var draft: String { selectedThreadID.map { drafts[$0] ?? (usesProjection ? projection.control?.draft : selectedThread?.draft) ?? "" } ?? "" }
    var selectedConfiguration: ProviderConfiguration? {
        if usesProjection { return projection.control?.detail.summary.id == selectedThreadID ? projection.control?.configuration : nil }
        return selectedThread.map(ProviderConfiguration.init(thread:))
    }
    var selectedThreadExists: Bool { usesProjection ? projection.control?.detail.summary.id == selectedThreadID : selectedThread != nil }
    var selectedSequence: Int64? { usesProjection ? projection.control?.binding.sequence : snapshot?.sequence }
    var selectedWorkspacePath: String { selectedConfiguration?.workspacePath ?? "" }
    var hostDraftAttachments: [ChatAttachment] { usesProjection ? (projection.control?.detail.summary.id == selectedThreadID ? projection.control?.attachments ?? [] : []) : selectedThread?.draftAttachments ?? [] }
    var hasUnsavedDrafts: Bool { draftsSaving || draftPersistenceFailed || attachments.hasUnsavedDrafts || pullRequests.hasUnsavedDrafts }
    var hasUnsavedWorkspaceEdits: Bool { inspector.hasUnsavedEdits }
    struct PullRequestSelection: Hashable {
        let environmentID: UUID?, threadID: UUID?, sequence: Int64?
        let configuration: Data
        let generation: Int
        let connected: Bool, supported: Bool, canWrite: Bool, canMutate: Bool
    }
    var pullRequestTarget: RemoteWorkspaceTarget? {
        if usesProjection { return projection.control?.detail.summary.id == selectedThreadID ? projection.control?.target : nil }
        guard let environmentID = connection?.environmentID, let thread = selectedThread else { return nil }
        return .init(environmentID: environmentID, projectID: thread.projectID, threadID: thread.id, configuration: .init(thread: thread))
    }
    var pullRequestSelection: PullRequestSelection {
        .init(environmentID: connection?.environmentID, threadID: selectedThreadID, sequence: selectedSequence,
            configuration: selectedConfiguration.flatMap { try? RemotePullRequestProtocol.payload($0) } ?? Data(),
            generation: generation, connected: isConnected, supported: descriptor?.capabilities.supportsRemotePullRequests == true,
            canWrite: canWrite, canMutate: inspectorSelection.canMutate && !hasDirtyPullRequestSource)
    }
    private var hasDirtyPullRequestSource: Bool {
        guard let target = pullRequestTarget else { return true }
        return inspector.retainedEditors.contains { model in
            model.session.target.environmentID == target.environmentID && Self.remotePathsOverlap(model.session.target.workspacePath, target.workspacePath)
        }
    }
    func updatePullRequests() async {
        guard !stopping else { pullRequests.disconnect(); checkpoints.disconnect(); history.disconnect(); return }
        if usesProjection {
            await pullRequests.selectProjected(target: pullRequestTarget, client: isConnected ? client : nil,
                operations: projection.currentOperations, supported: descriptor?.capabilities.supportsRemotePullRequests == true,
                canWrite: canWrite, canMutate: pullRequestSelection.canMutate,
                perform: { [weak self] in await self?.perform($0) ?? false }, openConversation: { [weak self] in self?.selectThread($0) })
            return
        }
        await pullRequests.select(target: pullRequestTarget, client: isConnected ? client : nil,
            snapshot: snapshot?.workspace ?? .init(), supported: descriptor?.capabilities.supportsRemotePullRequests == true,
            canWrite: canWrite, canMutate: pullRequestSelection.canMutate,
            perform: { [weak self] command in await self?.perform(command) ?? false },
            openConversation: { [weak self] id in self?.selectThread(id) })
    }
    var checkpointSelection: PullRequestSelection {
        .init(environmentID: connection?.environmentID, threadID: selectedThreadID, sequence: selectedSequence,
            configuration: selectedConfiguration.flatMap { try? RemoteCheckpointProtocol.payload($0) } ?? Data(),
            generation: generation, connected: isConnected, supported: descriptor?.capabilities.supportsRemoteCheckpoints == true,
            canWrite: canWrite, canMutate: inspectorSelection.canMutate && !hasDirtyPullRequestSource)
    }
    func updateCheckpoints() async {
        guard !stopping else { checkpoints.disconnect(); return }
        if usesProjection {
            await checkpoints.selectProjected(target: pullRequestTarget, projection: projection, client: isConnected ? client : nil,
                supported: descriptor?.capabilities.supportsRemoteCheckpoints == true, canWrite: canWrite,
                canMutate: checkpointSelection.canMutate, perform: { [weak self] in await self?.perform($0) ?? false },
                canRestore: { [weak self] in self?.checkpointFilesStillAllowed(paths: [$0.gitReview.currentPlan.repositoryPath, $0.gitReview.currentPlan.commonDirectoryPath]) ?? false })
            return
        }
        await checkpoints.select(target: pullRequestTarget, thread: selectedThread, snapshot: snapshot?.workspace ?? .init(),
            client: isConnected ? client : nil, supported: descriptor?.capabilities.supportsRemoteCheckpoints == true,
            canWrite: canWrite, canMutate: checkpointSelection.canMutate,
            perform: { [weak self] command in await self?.perform(command) ?? false },
            canRestore: { [weak self] review in self?.checkpointFilesStillAllowed(paths: [review.gitReview.currentPlan.repositoryPath, review.gitReview.currentPlan.commonDirectoryPath]) ?? false })
    }
    var historySelection: PullRequestSelection {
        .init(environmentID: connection?.environmentID, threadID: selectedThreadID, sequence: selectedSequence,
            configuration: selectedConfiguration.flatMap { try? RemoteHistoryProtocol.payload($0) } ?? Data(),
            generation: generation, connected: isConnected,
            supported: usesProjection && descriptor?.capabilities.supportsRemoteHistory == true,
            canWrite: canWrite, canMutate: checkpointSelection.canMutate)
    }
    func updateHistory() async {
        guard !stopping else { history.disconnect(); return }
        await history.select(target: pullRequestTarget, projection: projection, client: isConnected ? client : nil,
            supported: usesProjection && descriptor?.capabilities.supportsRemoteHistory == true, canWrite: canWrite,
            canRestoreFiles: { [weak self] in self?.checkpointFilesStillAllowed(paths: $0) ?? false },
            perform: { [weak self] in await self?.perform($0) ?? false },
            openConversation: { [weak self] in self?.selectThread($0) })
    }
    private func historyCommandStillAllowed(_ command: RemoteEnvironmentCommand) -> Bool {
        guard case .history(let target, let action) = command else { return true }
        guard isConnected, !stopping, usesProjection, descriptor?.capabilities.supportsRemoteHistory == true,
              let current = pullRequestTarget, target.rootID != nil || !action.requiresBoundRoot,
              current.environmentID == target.environmentID, current.projectID == target.projectID, current.threadID == target.threadID,
              (try? RemoteHistoryProtocol.payload(current.configuration)) == (try? RemoteHistoryProtocol.payload(target.configuration)) else { return false }
        if case .begin(let id, let digest, _) = action {
            guard let review = history.review(id: id), review.digest == digest,
                  (try? RemoteHistoryProtocol.payload(review.target)) == (try? RemoteHistoryProtocol.payload(target)) else { return false }
            return checkpointFilesStillAllowed(paths: review.value.mutatingPaths + review.value.coordinationPaths)
        }
        if case .clearMaintenance(let id, let reviewID, let digest) = action {
            guard let claim = history.current?.operationViews[id]?.maintenanceClaim else { return false }
            return claim.id == reviewID && claim.digest == digest
        }
        return true
    }
    private func checkpointFilesStillAllowed(paths: [String]) -> Bool {
        guard let environment = connection?.environmentID, isConnected, !stopping else { return false }
        guard !inspector.retainedEditors.contains(where: { editor in
            editor.session.target.environmentID == environment && paths.contains { Self.remotePathsOverlap(editor.session.target.workspacePath, $0) }
        }) else { return false }
        return !terminals.workspaces.contains { workspace in
            workspace.target.environmentID == environment && paths.contains { Self.remotePathsOverlap(workspace.target.workspacePath, $0) } &&
                terminals.hasLiveTerminals(in: workspace.target)
        }
    }
    private func checkpointCommandStillAllowed(_ command: RemoteEnvironmentCommand) -> Bool {
        guard case .checkpoint(let target, let action) = command else { return true }
        guard isConnected, !stopping, descriptor?.capabilities.supportsRemoteCheckpoints == true,
              let current = pullRequestTarget, target.rootID != nil || !action.requiresBoundRoot,
              current.environmentID == target.environmentID, current.projectID == target.projectID, current.threadID == target.threadID,
              (try? RemoteCheckpointProtocol.payload(current.configuration)) == (try? RemoteCheckpointProtocol.payload(target.configuration)) else { return false }
        switch action {
        case .beginRestore(let id, let digest):
            guard let review = checkpoints.review(id: id), review.digest == digest,
                  (try? RemoteCheckpointProtocol.payload(review.target)) == (try? RemoteCheckpointProtocol.payload(target)) else { return false }
            return checkpointFilesStillAllowed(paths: [review.value.gitReview.currentPlan.repositoryPath, review.value.gitReview.currentPlan.commonDirectoryPath])
        case .retryPostRun, .continuePostRun:
            return checkpointFilesStillAllowed(paths: [target.workspacePath])
        case .inspectRestore, .acknowledgeRestore: return true
        }
    }
    func showPullRequestChanges() async {
        inspectorVisible = true
        if inspector.canReturnToCurrent { await inspector.returnToCurrent() }
        else { await updateInspector() }
        inspector.selected?.tab = "Changes"
    }
    var attachmentTarget: RemoteAttachmentTarget? {
        guard let target = pullRequestTarget else { return nil }
        return .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID)
    }
    struct AttachmentSelection: Hashable {
        let environmentID: UUID?, threadID: UUID?, sequence: Int64?
        let generation: Int
        let connected: Bool, supported: Bool
    }
    var attachmentSelection: AttachmentSelection {
        .init(environmentID: connection?.environmentID, threadID: selectedThreadID, sequence: selectedSequence,
            generation: generation, connected: isConnected, supported: descriptor?.capabilities.supportsRemoteAttachments == true)
    }
    func updateAttachments() async {
        guard !stopping else { attachments.disconnect(); return }
        await attachments.select(target: attachmentTarget, client: isConnected ? client : nil,
            hostDraftAttachments: hostDraftAttachments, supported: descriptor?.capabilities.supportsRemoteAttachments == true)
    }
    var draftExceedsLocalLimit: Bool { draft.utf16.count > 120_000 }
    func replaceOversizedDraft() { if let id = selectedThreadID, draftExceedsLocalLimit { setDraft("", threadID: id) } }
    var canSubmit: Bool {
        !draftExceedsLocalLimit && canWrite && (!usesProjection || (selectedThreadExists && projection.control?.detail.submit.allowed == true)) && !attachments.isLoading && !attachments.isImporting && !attachments.isUploading &&
            (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.hasAttachments || !hostDraftAttachments.isEmpty)
    }
    struct InspectorSelection: Hashable {
        let environmentID: UUID?, threadID: UUID?, path: Data
        let generation: Int
        let connected: Bool, canMutate: Bool
    }
    var inspectorSelection: InspectorSelection {
        if usesProjection {
            let target = pullRequestTarget
            return .init(environmentID: connection?.environmentID, threadID: selectedThreadID, path: Data(selectedWorkspacePath.utf8),
                generation: generation, connected: isConnected,
                canMutate: canWrite && projection.control?.detail.mutateFiles.allowed == true && target.map { !terminals.hasLiveTerminals(in: $0) } == true)
        }
        let thread = selectedThread
        let available = thread.map { snapshot?.workspace.workspaceReady(for: $0) == true } ?? false
        let busy = thread.map { selected in threads.contains {
            $0.workspacePath.utf8.elementsEqual(selected.workspacePath.utf8) &&
                ($0.isBusy || !$0.runtimeRequests.isEmpty || !$0.queuedTurns.isEmpty || $0.settlement != nil)
        } } ?? true
        let terminalBusy = thread.flatMap { selected in
            connection?.environmentID.map { environmentID in
                terminals.hasLiveTerminals(in: .init(environmentID: environmentID, projectID: selected.projectID,
                    threadID: selected.id, configuration: .init(thread: selected)))
            }
        } ?? false
        return .init(environmentID: connection?.environmentID, threadID: thread?.id,
            path: Data((thread?.workspacePath ?? "").utf8), generation: generation,
            connected: isConnected, canMutate: canWrite && available && !busy && !terminalBusy)
    }
    func updateInspector() async {
        guard !stopping, let target = pullRequestTarget else { inspector.clearSelection(); return }
        await inspector.select(target: target,
            client: isConnected ? client : nil, canMutate: inspectorSelection.canMutate)
    }
    struct TerminalSelection: Hashable {
        let environmentID: UUID?, threadID: UUID?, path: Data
        let generation: Int
        let connected: Bool, ready: Bool
    }
    var terminalSelection: TerminalSelection {
        .init(environmentID: connection?.environmentID, threadID: selectedThreadID,
            path: Data(selectedWorkspacePath.utf8), generation: generation,
            connected: isConnected,
            ready: usesProjection ? projection.control?.detail.openTerminal.allowed == true : selectedThread.map { snapshot?.workspace.workspaceReady(for: $0) == true } ?? false)
    }
    func updateTerminals() async {
        guard !stopping, let target = pullRequestTarget else { terminals.clearSelection(); return }
        // Selecting a workspace still being prepared disables new opens there,
        // while other threads keep their existing terminal transport and tabs.
        let supported = descriptor?.capabilities.supportsRemoteTerminal == true
        await terminals.select(target: terminalSelection.ready && supported ? target : nil, client: isConnected ? client : nil)
    }
    struct WorktreeSelection: Hashable {
        let environmentID: UUID?, threadID: UUID?, sequence: Int64?
        let generation: Int
        let connected: Bool, supported: Bool, canWrite: Bool, canChange: Bool
    }
    var canChangeRemoteWorkspace: Bool {
        guard canWrite, let current = pullRequestTarget else { return false }
        return workspaceChangeStillAllowed(current)
    }
    private func workspaceChangeStillAllowed(_ current: RemoteWorkspaceTarget) -> Bool {
        guard isConnected, !stopping, !inspector.hasUnsavedEdits,
              connection?.environmentID == current.environmentID,
              let selected = pullRequestTarget, selected.threadID == current.threadID, selected.projectID == current.projectID,
              selected.configuration == current.configuration,
              selected.workspacePath.utf8.elementsEqual(current.workspacePath.utf8) else { return false }
        if terminals.hasLiveTerminals(in: current) { return false }
        let sourcePath = usesProjection ? projection.control?.detail.preparation.flatMap { $0.canRetry ? $0.sourcePath : nil } : selectedThread?.workspacePreparation.flatMap { $0.canRetry ? $0.request.sourcePath : nil }
        if let sourcePath {
            var source = current.configuration; source.workspacePath = sourcePath
            if terminals.hasLiveTerminals(in: .init(environmentID: current.environmentID, projectID: current.projectID,
                threadID: current.threadID, configuration: source)) { return false }
        }
        return true
    }
    var worktreeSelection: WorktreeSelection {
        .init(environmentID: connection?.environmentID, threadID: selectedThreadID, sequence: selectedSequence,
            generation: generation, connected: isConnected, supported: descriptor?.capabilities.supportsRemoteWorktrees == true,
            canWrite: canWrite, canChange: canChangeRemoteWorkspace)
    }
    func updateWorktrees() {
        if usesProjection {
            worktrees.updateProjected(target: pullRequestTarget, detail: projection.control?.detail, client: isConnected ? client : nil,
                supported: descriptor?.capabilities.supportsRemoteWorktrees == true, canWrite: canWrite,
                canChangeWorkspace: canChangeRemoteWorkspace, perform: { [weak self] in await self?.perform($0) ?? false })
            return
        }
        worktrees.update(environmentID: connection?.environmentID, thread: selectedThread, client: isConnected ? client : nil,
            supported: descriptor?.capabilities.supportsRemoteWorktrees == true, canWrite: canWrite,
            canChangeWorkspace: canChangeRemoteWorkspace, perform: { [weak self] command in
                guard let self else { return false }
                return await self.perform(command)
            })
    }

    func load() async {
        guard !isLoaded else { return }
        isLoaded = true
        let root = registryRoot
        do { connections = try await Task.detached { try RemoteEnvironmentRegistry.load(rootURL: root) }.value }
        catch { errorMessage = "Saved remote connections could not be read. Existing files were preserved." }
    }

    func connect(_ selected: RemoteEnvironmentConnection) async {
        await connect(RemoteWorkspaceConnection(selected))
    }

    func connect(_ selected: RemoteWorkspaceConnection) async {
        guard !isWorking, !isPreparingSubmission, !stopping else { return }
        isWorking = true; defer { isWorking = false }
        generation += 1; let owner = generation
        await disconnectTransport(owner: owner)
        guard generation == owner, !stopping, !draftPersistenceFailed else { return }
        connection = selected; descriptor = nil; snapshot = nil; usesProjection = false; drafts = [:]
        let retained = Set(connections.map(\.environmentID) + [selected.environmentID].compactMap { $0 })
        minimumSequences = minimumSequences.filter { retained.contains($0.key) }
        selectedThreadID = nil; selectedProjectID = nil
        errorMessage = nil; notice = nil; pending = nil
        do {
            let next = try clientFactory(selected.configuration, selected.environmentID)
            client = next
            eventTask = Task { [weak self] in
                for await event in next.events {
                    guard let self, self.generation == owner, !self.stopping else { return }
                    self.receive(event)
                }
            }
            let found = try await next.discover()
            guard generation == owner, !stopping else { return }
            descriptor = found
            if selected.environmentID == nil { needsTrust = true; return }
            try await finishConnecting(next, owner: owner)
        } catch {
            guard generation == owner else { return }
            errorMessage = error.localizedDescription
            await client?.close(); isConnected = false
        }
    }

    func trustDiscoveredEnvironment() async {
        guard needsTrust, !isWorking, !stopping, var selected = connection,
              let descriptor, let client else { return }
        isWorking = true; defer { isWorking = false }
        let owner = generation
        do {
            try await client.trust(environmentID: descriptor.environmentID)
            selected.environmentID = descriptor.environmentID
            var saved = connections.filter { $0.id != selected.id }
            saved.append(.init(id: selected.id, name: selected.name, configuration: selected.configuration, environmentID: descriptor.environmentID))
            try await saveConnections(saved)
            guard generation == owner, !stopping else { return }
            connections = saved; connection = selected; needsTrust = false
            try await finishConnecting(client, owner: owner)
        } catch { errorMessage = error.localizedDescription }
    }

    private func finishConnecting(_ next: RemoteEnvironmentClient, owner: Int) async throws {
        guard let selected = connection, let environmentID = selected.environmentID else {
            throw CoincideError("Confirm the remote environment before connecting.")
        }
        let savedDrafts = try await draftStore.load(environmentID: environmentID)
        let savedPending = try await pendingStore.load(connectionID: selected.id)
        guard generation == owner, !stopping else { return }
        guard savedPending == nil || savedPending?.environmentID == environmentID else {
            throw CoincideError("The saved request belongs to a different environment. Its file was preserved.")
        }
        if let floor = minimumSequences[environmentID] { try await next.requireMinimumSequence(floor, environmentID: environmentID) }
        guard generation == owner, !stopping else { return }
        drafts = savedDrafts; pending = savedPending
        draftPersistenceFailed = false; needsTrust = false
        if descriptor?.capabilities.supportsBoundedProjections == true {
            let binding = try await next.connectProjection()
            guard generation == owner, !stopping else { return }
            usesProjection = true; isConnected = true
            try await projection.connect(client: next, binding: binding, changed: { [weak self] in self?.projectionChanged() })
            guard generation == owner, !stopping, isConnected else { return }
            selectedProjectID = projection.projects.first?.id
            selectThread(projection.threads.first?.id)
        } else {
            let value = try await next.connect()
            guard generation == owner, !stopping else { return }
            isConnected = true; accept(value)
        }
        if savedPending != nil { notice = "A previous request has no confirmed result. Check its result before sending more work." }
    }

    func reconnect() async {
        guard let selected = connection else { return }
        await connect(selected)
    }

    func disconnect() async {
        generation += 1
        await disconnectTransport(owner: generation)
    }

    private func disconnectTransport(owner: Int) async {
        isConnected = false; needsTrust = false
        projection.disconnect()
        inspector.disconnect()
        terminals.disconnect()
        worktrees.disconnect()
        attachments.disconnect()
        pullRequests.disconnect(); checkpoints.disconnect(); history.disconnect()
        let old = client; client = nil
        eventTask?.cancel(); eventTask = nil
        await old?.close()
        await drainDrafts(owner: owner)
    }

    func shutdown() async {
        stopping = true
        await disconnect()
        await inspector.shutdown()
        await terminals.shutdown()
        await worktrees.shutdown()
        await attachments.shutdown()
        await pullRequests.shutdown()
        await checkpoints.shutdown()
        await history.shutdown()
    }

    func cancelShutdown() { stopping = false; inspector.cancelShutdown(); terminals.cancelShutdown(); worktrees.cancelShutdown(); attachments.cancelShutdown(); pullRequests.cancelShutdown(); checkpoints.cancelShutdown(); history.cancelShutdown() }

    func forget(_ selected: RemoteEnvironmentConnection) async {
        guard !isWorking, connection?.id != selected.id || !isConnected else { return }
        isWorking = true; defer { isWorking = false }
        do {
            guard try await pendingStore.load(connectionID: selected.id) == nil else {
                throw CoincideError("Inspect or dismiss the connection's unconfirmed request before forgetting it.")
            }
            let retained = connections.filter { $0.id != selected.id }
            try await saveConnections(retained); connections = retained
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveConnections(_ value: [RemoteEnvironmentConnection]) async throws {
        let root = registryRoot
        try await Task.detached { try RemoteEnvironmentRegistry.save(value, rootURL: root) }.value
    }

    func selectThread(_ id: UUID?) {
        if selectedThreadID != id { inspector.clearSelection(); terminals.clearSelection(); attachments.clearSelection(); pullRequests.clearSelection(); checkpoints.clearSelection(); history.clearSelection() }
        selectedThreadID = id
        if usesProjection {
            projection.beginSelection(id)
            Task { [weak self] in guard let self, self.selectedThreadID == id else { return }; await self.projection.select(id) }
        }
        if let thread = selectedThread { selectedProjectID = thread.projectID }
        updateWorktrees()
    }

    func setDraft(_ text: String, threadID: UUID) {
        guard !stopping, (usesProjection ? projection.control?.detail.summary.id == threadID : snapshot?.workspace.threads.contains(where: { $0.id == threadID }) == true) else { return }
        guard text.utf16.count <= 120_000 else {
            errorMessage = "The draft exceeds the local limit of 120,000 UTF-16 characters. Your previous text was kept. Copy the larger text and replace it with a shorter local draft before sending."
            return
        }
        drafts[threadID] = text
        saveDrafts()
    }

    private func saveDrafts() {
        guard let environmentID = connection?.environmentID else { return }
        draftRevision += 1; draftsSaving = true
        let previous = draftWrites, value = drafts, revision = draftRevision
        let owner = generation
        draftWrites = Task { [weak self, draftStore] in
            _ = await previous?.value
            do {
                let latest = self?.connection?.environmentID == environmentID ? self?.drafts ?? value : value
                try await draftStore.save(environmentID: environmentID, drafts: latest)
                if self?.generation == owner, self?.connection?.environmentID == environmentID, self?.draftRevision == revision {
                    self?.draftPersistenceFailed = false; self?.draftsSaving = false
                }
                return true
            } catch {
                if self?.generation == owner, self?.connection?.environmentID == environmentID, self?.draftRevision == revision {
                    self?.draftPersistenceFailed = true
                    self?.draftsSaving = false
                    self?.errorMessage = "The remote draft could not be saved on this Mac. Keep this window open and copy your text before closing it."
                }
                return false
            }
        }
    }

    private func drainDrafts(owner: Int) async {
        while let task = draftWrites {
            let revision = draftRevision, saved = await task.value
            guard generation == owner else { return }
            if draftRevision == revision {
                draftsSaving = false; draftPersistenceFailed = !saved
                if !saved { errorMessage = "The remote draft could not be saved on this Mac. Keep this window open and copy your text before closing it." }
                return
            }
        }
    }

    @discardableResult
    func perform(_ command: RemoteEnvironmentCommand) async -> Bool {
        guard canWrite, let client, let connection, let environmentID = connection.environmentID else { return false }
        guard attachmentSubmissionStillAllowed(command) else {
            errorMessage = "The selected conversation or its attachments changed. Review the draft before sending again."; return false
        }
        guard pullRequestCommandStillAllowed(command), checkpointCommandStillAllowed(command), historyCommandStillAllowed(command) else {
            errorMessage = "The remote review or its affected checkout changed. Save edits, close affected terminals, and review it again."; return false
        }
        let changingWorkspace: RemoteWorkspaceTarget?
        switch command {
        case .prepareWorktree(let target, _, _, _, _), .retryWorktree(let target, _):
            changingWorkspace = target
            guard workspaceChangeStillAllowed(target) else {
                errorMessage = "Save or discard remote file edits and close this workspace's terminal tabs before changing its checkout."
                return false
            }
        default: changingWorkspace = nil
        }
        if case .history(let target, .recallPrompt) = command, drafts[target.threadID] == nil {
            guard selectedThreadID == target.threadID else { return false }
            setDraft(draft, threadID: target.threadID)
        }
        isWorking = true; defer { isWorking = false }
        errorMessage = nil; notice = nil
        let owner = generation
        await drainDrafts(owner: owner)
        guard generation == owner, !stopping, !draftPersistenceFailed else { return false }
        guard attachmentSubmissionStillAllowed(command) else {
            errorMessage = "The selected conversation or its attachments changed. Your draft was kept."; return false
        }
        guard pullRequestCommandStillAllowed(command), checkpointCommandStillAllowed(command), historyCommandStillAllowed(command) else {
            errorMessage = "The remote review or its affected checkout changed. Your draft was kept."; return false
        }
        if let changingWorkspace, !workspaceChangeStillAllowed(changingWorkspace) {
            errorMessage = "The workspace or its retained edits changed. Review them before choosing the checkout again."
            return false
        }
        let request = RemoteEnvironmentPendingCommand(connectionID: connection.id, environmentID: environmentID,
            id: UUID(), command: command)
        do {
            try await pendingStore.save(request)
            guard generation == owner, !stopping else { return false }
            pending = request
            if !pullRequestCommandStillAllowed(command) || !checkpointCommandStillAllowed(command) || !historyCommandStillAllowed(command) {
                try await pendingStore.remove(connectionID: request.connectionID, commandID: request.id)
                pending = nil
                errorMessage = "The remote review or its affected checkout changed. Your draft was kept."
                return false
            }
            if !attachmentSubmissionStillAllowed(command) {
                try await pendingStore.remove(connectionID: request.connectionID, commandID: request.id)
                pending = nil
                errorMessage = "The selected conversation or its attachments changed. Your draft was kept."
                return false
            }
            if let changingWorkspace, !workspaceChangeStillAllowed(changingWorkspace) {
                // This identity has never reached the transport. Remove only
                // its exact local record; preserve every draft and editor.
                try await pendingStore.remove(connectionID: request.connectionID, commandID: request.id)
                guard generation == owner else { return false }
                pending = nil
                errorMessage = "The workspace or its retained edits changed before sending. Review them and choose the checkout again."
                return false
            }
            let result = try await client.command(command, id: request.id)
            guard generation == owner else { return false }
            try await finish(request, receipt: result.receipt)
            await refreshAfterCommand(client: client, owner: owner)
            return result.receipt.rejection == nil
        } catch {
            guard generation == owner else { return false }
            errorMessage = error.localizedDescription
            if pending != nil { notice = "The request's result is unconfirmed. It will not be sent again automatically." }
            return false
        }
    }

    private func attachmentSubmissionStillAllowed(_ command: RemoteEnvironmentCommand) -> Bool {
        guard case .submitWithAttachments(let target, _, let configuration, let expected, _) = command else { return true }
        guard isConnected, !stopping, attachmentTarget == target, selectedConfiguration == configuration else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(hostDraftAttachments)) == (try? encoder.encode(expected))
    }
    private func pullRequestCommandStillAllowed(_ command: RemoteEnvironmentCommand) -> Bool {
        guard case .pullRequest(let target, let action) = command else { return true }
        guard isConnected, !stopping, let current = pullRequestTarget, target.rootID != nil || !action.requiresBoundRoot,
              current.environmentID == target.environmentID, current.projectID == target.projectID, current.threadID == target.threadID,
              (try? RemotePullRequestProtocol.payload(current.configuration)) == (try? RemotePullRequestProtocol.payload(target.configuration)) else { return false }
        guard case .begin(let id, let digest) = action else { return true }
        guard let review = pullRequests.review(id: id), review.digest == digest,
              (try? RemotePullRequestProtocol.payload(review.target)) == (try? RemotePullRequestProtocol.payload(target)) else { return false }
        let paths: [String]
        switch review.value {
        case .creation(let creation): paths = [creation.context.repositoryPath, creation.context.commonDirectoryPath]
        case .checkout(let checkout): paths = checkout.plan.affectedWorkspacePaths
        }
        guard !inspector.retainedEditors.contains(where: { model in
            model.session.target.environmentID == target.environmentID && paths.contains { Self.remotePathsOverlap(model.session.target.workspacePath, $0) }
        }) else { return false }
        return !terminals.workspaces.contains { workspace in
            workspace.target.environmentID == target.environmentID && paths.contains { Self.remotePathsOverlap(workspace.target.workspacePath, $0) } &&
                terminals.hasLiveTerminals(in: workspace.target)
        }
    }
    private static func remotePathsOverlap(_ first: String, _ second: String) -> Bool {
        func bytes(_ value: String) -> [UInt8] {
            var result = Array(value.utf8)
            while result.count > 1, result.last == 47 { result.removeLast() }
            return result
        }
        let a = bytes(first), b = bytes(second)
        return a == b || a == [47] || b == [47] || a.starts(with: b + [47]) || b.starts(with: a + [47])
    }

    func checkPendingResult() async {
        guard isConnected, !isWorking, let client, let pending else { return }
        isWorking = true; defer { isWorking = false }
        let owner = generation
        do {
            let result = try await client.receipt(for: pending.command, id: pending.id)
            guard generation == owner else { return }
            if let receipt = result.receipt {
                try await finish(pending, receipt: receipt)
                await refreshAfterCommand(client: client, owner: owner)
            } else { notice = "No committed receipt is available. Inspect the remote conversation before dismissing this request; it has not been repeated." }
        } catch { if generation == owner { errorMessage = error.localizedDescription } }
    }

    func dismissPending() async {
        guard !isWorking, let pending else { return }
        isWorking = true; defer { isWorking = false }
        do {
            try await pendingStore.archive(connectionID: pending.connectionID, commandID: pending.id)
            self.pending = nil; notice = "The unconfirmed request was kept in local history. Nothing was repeated."
        } catch { errorMessage = error.localizedDescription }
    }

    private func finish(_ request: RemoteEnvironmentPendingCommand, receipt: WorkspaceCommandReceipt) async throws {
        guard receipt.commandID == request.id else { throw CoincideError("The remote receipt belongs to a different request.") }
        let owner = generation
        if receipt.rejection == nil, case .history(let target, .recallPrompt(let operationID)) = request.command {
            try await finishHistoryRecall(request, target: target, operationID: operationID, owner: owner)
            guard generation == owner else { throw CancellationError() }
        }
        let submitted: (UUID, String)?
        switch request.command {
        case .submit(let id, let text, _): submitted = (id, text)
        case .submitWithAttachments(let target, let text, _, _, let uploaded):
            submitted = (target.threadID, text)
            if receipt.rejection == nil {
                guard await attachments.acknowledge(target: target, uploadedAttachmentIDs: uploaded) else {
                    throw CoincideError("The accepted request's attachment draft could not be saved. Check its result again after saving is available.")
                }
            }
        default: submitted = nil
        }
        if receipt.rejection == nil, let (threadID, text) = submitted,
           let currentDraft = drafts[threadID], currentDraft.utf8.elementsEqual(text.utf8) {
            drafts[threadID] = ""; saveDrafts(); await drainDrafts(owner: generation)
            guard !draftPersistenceFailed else { throw CoincideError("The accepted request's updated draft could not be saved.") }
        }
        try await pendingStore.remove(connectionID: request.connectionID, commandID: request.id)
        pending = nil; notice = nil
        if let rejection = receipt.rejection { errorMessage = rejection }
    }

    private func finishHistoryRecall(_ request: RemoteEnvironmentPendingCommand, target: RemoteWorkspaceTarget,
                                     operationID: UUID, owner: Int) async throws {
        guard let client, connection?.environmentID == target.environmentID else { throw CancellationError() }
        let result = try await client.readHistory(.init(target: target, query: .recall(operationID: operationID)))
        guard generation == owner, case .recall(let recall) = result.value else { throw CancellationError() }
        let text: String
        if let content = recall.text.content {
            let bytes = try await client.historyDocument(content, binding: recall.binding, target: target, maximumBytes: 4 * 1_024 * 1_024)
            guard let decoded = String(data: bytes, encoding: .utf8) else { throw RemoteEnvironmentClientError(.invalidResponse) }
            text = decoded
        } else { text = recall.text.preview }
        let attachmentBytes = try await client.historyDocument(recall.attachments, binding: recall.binding, target: target)
        let recalledAttachments = try JSONDecoder().decode([ChatAttachment].self, from: attachmentBytes)
        try AttachmentLimits.validate(recalledAttachments)
        guard generation == owner else { throw CancellationError() }
        await drainDrafts(owner: owner)
        guard generation == owner, !draftPersistenceFailed else { throw CoincideError("Save the local draft before recovering this recalled prompt.") }
        let previous = draftWrites
        draftRevision += 1; let revision = draftRevision
        draftsSaving = true
        let write = Task { [weak self, draftStore] in
            _ = await previous?.value
            guard let self, self.connection?.environmentID == target.environmentID else { return false }
            do {
                let before = self.drafts
                let merged = try await draftStore.mergeHistoryRecall(environmentID: target.environmentID, threadID: target.threadID,
                    commandID: request.id, operationID: operationID, text: text, attachmentDigest: recall.attachments.digest, expectedDrafts: before)
                if self.connection?.environmentID == target.environmentID, merged.appended {
                    if self.draftRevision == revision { self.drafts = merged.drafts }
                    else if !text.isEmpty {
                        let current = self.drafts[target.threadID] ?? ""
                        self.drafts[target.threadID] = current.isEmpty ? text : current + "\n\n" + text
                    }
                }
                if self.draftRevision == revision { self.draftsSaving = false; self.draftPersistenceFailed = false }
                return true
            } catch {
                self.draftPersistenceFailed = true; self.draftsSaving = false
                self.errorMessage = "The recalled prompt could not be merged into the saved local draft. Its confirmed request is retained; check the result again after saving is available."
                return false
            }
        }
        draftWrites = write
        guard await write.value else { throw CoincideError("The recalled prompt remains pending local draft preservation.") }
        await drainDrafts(owner: owner)
        guard generation == owner, !draftPersistenceFailed else { throw CancellationError() }
        _ = try? await client.readHistory(.init(target: target, query: .release(binding: recall.binding)))
    }

    func submit() async {
        guard canSubmit, let configuration = selectedConfiguration, let target = attachmentTarget else { return }
        let threadID = target.threadID
        // Materialize a server-provided draft locally before recording the send.
        let text = draft; setDraft(text, threadID: threadID)
        let owner = generation
        if descriptor?.capabilities.supportsRemoteAttachments == true {
            isPreparingSubmission = true
            defer { isPreparingSubmission = false }
            await updateAttachments()
            guard let prepared = await attachments.prepareSubmission(), generation == owner, !stopping,
                  attachmentTarget == target, prepared.target == target,
                  selectedConfiguration == configuration else { return }
            isPreparingSubmission = false
            _ = await perform(.submitWithAttachments(target: target, text: text, expectedConfiguration: configuration,
                expectedDraftAttachments: prepared.expectedDraftAttachments, uploadedAttachmentIDs: prepared.uploadedAttachmentIDs))
        } else {
            guard hostDraftAttachments.isEmpty, !attachments.hasAttachments else {
                errorMessage = "Update the remote helper before sending this conversation's attachments."; return
            }
            _ = await perform(.submit(threadID: threadID, text: text, expectedConfiguration: configuration))
        }
    }

    func stop(_ thread: CodingThread) async {
        guard let run = thread.activeRun, let runtimeID = thread.runtimeID else { return }
        _ = await perform(.stop(threadID: thread.id, runID: run.id, runtimeID: runtimeID))
    }

    func respond(_ request: ApprovalRequest, thread: CodingThread, response: ProviderApprovalResponse) async {
        guard let runtimeID = thread.runtimeID else { return }
        _ = await perform(.respond(threadID: thread.id, runID: thread.activeRun?.id, runtimeID: runtimeID,
            request: request, response: response))
    }

    private func receive(_ event: RemoteEnvironmentClientEvent) {
        switch event {
        case .descriptor(let value): descriptor = value
        case .snapshot(let value): if isConnected, !usesProjection { accept(value) }
        case .projectionChanged(let value): if isConnected, usesProjection { projection.invalidate(value) }
        case .disconnected(let message):
            // A subscribe reply may already be resuming finishConnecting. Fence
            // that continuation before it can publish a disconnected client.
            generation += 1
            isConnected = false; projection.disconnect(); inspector.disconnect(); terminals.disconnect(); worktrees.disconnect(); attachments.disconnect(); pullRequests.disconnect(); checkpoints.disconnect(); history.disconnect(); notice = message.localizedDescription
            if isWorking { errorMessage = message.localizedDescription }
        }
    }

    private func accept(_ value: RemoteEnvironmentSnapshot) {
        guard value.environmentID == connection?.environmentID,
              snapshot.map({ $0.environmentID != value.environmentID || value.sequence >= $0.sequence }) ?? true else { return }
        let previousSelection = inspectorSelection
        snapshot = value
        minimumSequences[value.environmentID] = max(minimumSequences[value.environmentID] ?? 0, value.sequence)
        if !threads.contains(where: { $0.id == selectedThreadID }) { selectedThreadID = threads.first?.id }
        if let selectedThread { selectedProjectID = selectedThread.projectID }
        else if !projects.contains(where: { $0.id == selectedProjectID }) { selectedProjectID = projects.first?.id }
        let nextSelection = inspectorSelection
        if previousSelection.environmentID != nextSelection.environmentID || previousSelection.threadID != nextSelection.threadID || previousSelection.path != nextSelection.path {
            inspector.clearSelection(); terminals.clearSelection()
            if previousSelection.environmentID != nextSelection.environmentID || previousSelection.threadID != nextSelection.threadID { attachments.clearSelection() }
            pullRequests.clearSelection(); checkpoints.clearSelection(); history.clearSelection()
        }
        updateWorktrees()
    }
    private func projectionChanged() {
        guard usesProjection, isConnected else { return }
        if let environment = connection?.environmentID {
            let observed = [projection.catalogBinding, projection.control?.binding, projection.browseBinding].compactMap { $0 }
                .filter { $0.environmentID == environment }.map(\.sequence).max() ?? 0
            minimumSequences[environment] = max(minimumSequences[environment] ?? 0, observed)
        }
        if let control = projection.control, control.detail.summary.id == selectedThreadID {
            selectedProjectID = control.detail.summary.projectID
        }
        updateWorktrees()
    }
    private func refreshAfterCommand(client: RemoteEnvironmentClient, owner: Int) async {
        guard generation == owner, !stopping, isConnected else { return }
        if usesProjection { await projection.refreshLatest() }
        else if let value = try? await client.snapshot(), generation == owner { accept(value) }
    }
    func stopProjected() async {
        guard let control = projection.control, let run = control.detail.activeRun, let runtimeID = control.detail.runtimeID else { return }
        _ = await perform(.stop(threadID: control.detail.summary.id, runID: run.id, runtimeID: runtimeID))
    }
    func respondProjected(_ request: ApprovalRequest, response: ProviderApprovalResponse) async {
        guard let control = projection.control, let runtimeID = control.detail.runtimeID,
              control.requests.contains(where: { $0.request == request }) else { return }
        _ = await perform(.respond(threadID: control.detail.summary.id, runID: control.detail.activeRun?.id,
            runtimeID: runtimeID, request: request, response: response))
    }

}
