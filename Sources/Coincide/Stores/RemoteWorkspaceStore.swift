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
    }

    var projects: [WorkspaceProject] { snapshot?.workspace.projects ?? [] }
    var threads: [CodingThread] { snapshot?.workspace.threads.filter { !$0.isArchived } ?? [] }
    var selectedThread: CodingThread? { threads.first { $0.id == selectedThreadID } }
    var canWrite: Bool { isConnected && !isWorking && !isPreparingSubmission && pending == nil && !stopping }
    var draft: String { selectedThread.map { drafts[$0.id] ?? $0.draft } ?? "" }
    var hasUnsavedDrafts: Bool { draftsSaving || draftPersistenceFailed || attachments.hasUnsavedDrafts }
    var hasUnsavedWorkspaceEdits: Bool { inspector.hasUnsavedEdits }
    var attachmentTarget: RemoteAttachmentTarget? {
        guard let environmentID = connection?.environmentID, let thread = selectedThread else { return nil }
        return .init(environmentID: environmentID, projectID: thread.projectID, threadID: thread.id)
    }
    struct AttachmentSelection: Hashable {
        let environmentID: UUID?, threadID: UUID?, sequence: Int64?
        let generation: Int
        let connected: Bool, supported: Bool
    }
    var attachmentSelection: AttachmentSelection {
        .init(environmentID: connection?.environmentID, threadID: selectedThreadID, sequence: snapshot?.sequence,
            generation: generation, connected: isConnected, supported: descriptor?.capabilities.supportsRemoteAttachments == true)
    }
    func updateAttachments() async {
        guard !stopping else { attachments.disconnect(); return }
        await attachments.select(target: attachmentTarget, client: isConnected ? client : nil,
            hostDraftAttachments: selectedThread?.draftAttachments ?? [], supported: descriptor?.capabilities.supportsRemoteAttachments == true)
    }
    var canSubmit: Bool {
        canWrite && !attachments.isLoading && !attachments.isImporting && !attachments.isUploading &&
            (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.hasAttachments || selectedThread?.draftAttachments.isEmpty == false)
    }
    struct InspectorSelection: Hashable {
        let environmentID: UUID?, threadID: UUID?, path: Data
        let generation: Int
        let connected: Bool, canMutate: Bool
    }
    var inspectorSelection: InspectorSelection {
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
        guard !stopping, let environmentID = connection?.environmentID, let thread = selectedThread else {
            inspector.clearSelection(); return
        }
        await inspector.select(environmentID: environmentID, thread: thread,
            client: isConnected ? client : nil, canMutate: inspectorSelection.canMutate)
    }
    struct TerminalSelection: Hashable {
        let environmentID: UUID?, threadID: UUID?, path: Data
        let generation: Int
        let connected: Bool, ready: Bool
    }
    var terminalSelection: TerminalSelection {
        .init(environmentID: connection?.environmentID, threadID: selectedThreadID,
            path: Data((selectedThread?.workspacePath ?? "").utf8), generation: generation,
            connected: isConnected,
            ready: selectedThread.map { snapshot?.workspace.workspaceReady(for: $0) == true } ?? false)
    }
    func updateTerminals() async {
        guard !stopping, let environmentID = connection?.environmentID, let thread = selectedThread else {
            terminals.clearSelection(); return
        }
        let target = RemoteWorkspaceTarget(environmentID: environmentID, projectID: thread.projectID,
            threadID: thread.id, configuration: .init(thread: thread))
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
        guard canWrite,
              let environmentID = connection?.environmentID, let thread = selectedThread else { return false }
        let current = RemoteWorkspaceTarget(environmentID: environmentID, projectID: thread.projectID,
            threadID: thread.id, configuration: .init(thread: thread))
        return workspaceChangeStillAllowed(current)
    }
    private func workspaceChangeStillAllowed(_ current: RemoteWorkspaceTarget) -> Bool {
        guard isConnected, !stopping, !inspector.hasUnsavedEdits,
              connection?.environmentID == current.environmentID,
              let thread = selectedThread, thread.id == current.threadID, thread.projectID == current.projectID,
              ProviderConfiguration(thread: thread) == current.configuration,
              thread.workspacePath.utf8.elementsEqual(current.workspacePath.utf8) else { return false }
        if terminals.hasLiveTerminals(in: current) { return false }
        if let preparation = thread.workspacePreparation, preparation.canRetry {
            var source = current.configuration; source.workspacePath = preparation.request.sourcePath
            if terminals.hasLiveTerminals(in: .init(environmentID: current.environmentID, projectID: thread.projectID,
                threadID: thread.id, configuration: source)) { return false }
        }
        return true
    }
    var worktreeSelection: WorktreeSelection {
        .init(environmentID: connection?.environmentID, threadID: selectedThreadID, sequence: snapshot?.sequence,
            generation: generation, connected: isConnected, supported: descriptor?.capabilities.supportsRemoteWorktrees == true,
            canWrite: canWrite, canChange: canChangeRemoteWorkspace)
    }
    func updateWorktrees() {
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
        connection = selected; descriptor = nil; snapshot = nil; drafts = [:]
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
        let value = try await next.connect()
        guard generation == owner, !stopping else { return }
        drafts = savedDrafts; pending = savedPending
        draftPersistenceFailed = false; needsTrust = false
        isConnected = true; accept(value)
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
        inspector.disconnect()
        terminals.disconnect()
        worktrees.disconnect()
        attachments.disconnect()
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
    }

    func cancelShutdown() { stopping = false; inspector.cancelShutdown(); terminals.cancelShutdown(); worktrees.cancelShutdown(); attachments.cancelShutdown() }

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
        if selectedThreadID != id { inspector.clearSelection(); terminals.clearSelection(); attachments.clearSelection() }
        selectedThreadID = id
        if let thread = selectedThread { selectedProjectID = thread.projectID }
        updateWorktrees()
    }

    func setDraft(_ text: String, threadID: UUID) {
        guard !stopping, text.utf16.count <= 120_000, snapshot?.workspace.threads.contains(where: { $0.id == threadID }) == true else { return }
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
                try await draftStore.save(environmentID: environmentID, drafts: value)
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
        isWorking = true; defer { isWorking = false }
        errorMessage = nil; notice = nil
        let owner = generation
        await drainDrafts(owner: owner)
        guard generation == owner, !stopping, !draftPersistenceFailed else { return false }
        guard attachmentSubmissionStillAllowed(command) else {
            errorMessage = "The selected conversation or its attachments changed. Your draft was kept."; return false
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
            if let value = try? await client.snapshot(), generation == owner { accept(value) }
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
        guard isConnected, !stopping, attachmentTarget == target, let thread = selectedThread,
              ProviderConfiguration(thread: thread) == configuration else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(thread.draftAttachments)) == (try? encoder.encode(expected))
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
                if let value = try? await client.snapshot(), generation == owner { accept(value) }
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

    func submit() async {
        guard canSubmit, let thread = selectedThread, let target = attachmentTarget else { return }
        // Materialize a server-provided draft locally before recording the send.
        let text = draft; setDraft(text, threadID: thread.id)
        let configuration = ProviderConfiguration(thread: thread), owner = generation
        if descriptor?.capabilities.supportsRemoteAttachments == true {
            isPreparingSubmission = true
            defer { isPreparingSubmission = false }
            await updateAttachments()
            guard let prepared = await attachments.prepareSubmission(), generation == owner, !stopping,
                  attachmentTarget == target, prepared.target == target,
                  selectedThread.map({ ProviderConfiguration(thread: $0) == configuration }) == true else { return }
            isPreparingSubmission = false
            _ = await perform(.submitWithAttachments(target: target, text: text, expectedConfiguration: configuration,
                expectedDraftAttachments: prepared.expectedDraftAttachments, uploadedAttachmentIDs: prepared.uploadedAttachmentIDs))
        } else {
            guard thread.draftAttachments.isEmpty, !attachments.hasAttachments else {
                errorMessage = "Update the remote helper before sending this conversation's attachments."; return
            }
            _ = await perform(.submit(threadID: thread.id, text: text, expectedConfiguration: configuration))
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
        case .snapshot(let value): if isConnected { accept(value) }
        case .disconnected(let message):
            // A subscribe reply may already be resuming finishConnecting. Fence
            // that continuation before it can publish a disconnected client.
            generation += 1
            isConnected = false; inspector.disconnect(); terminals.disconnect(); worktrees.disconnect(); attachments.disconnect(); notice = message.localizedDescription
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
        }
        updateWorktrees()
    }
}
