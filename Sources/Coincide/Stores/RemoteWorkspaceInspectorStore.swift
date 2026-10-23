import CoincideCore
import Foundation
import Observation

private struct RemoteWorkspaceInspectorKey: Hashable {
    let environmentID: UUID
    let threadID: UUID
    // Remote POSIX paths are opaque bytes, never local URLs or normalized paths.
    let path: Data
}

/// Retained by the remote window's store, independent of inspector visibility.
/// Each model owns its editor buffers and exact uncertain operation, while the
/// parent owns the SSH connection and is the only code allowed to close it.
@MainActor @Observable
final class RemoteWorkspaceInspectorStore {
    private(set) var selected: RemoteWorkspaceInspectorModel?
    private(set) var errorMessage: String?
    private(set) var isShowingRetained = false
    private(set) var recoveredDrafts: [EditorRecoveryRecord] = []
    private(set) var recoveryError: String?
    @ObservationIgnored private let pendingStore: RemoteWorkspacePendingStore
    @ObservationIgnored private let recoveryJournal: EditorRecoveryJournal?
    @ObservationIgnored private var models: [RemoteWorkspaceInspectorKey: RemoteWorkspaceInspectorModel] = [:]
    @ObservationIgnored private var selection = UUID()
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var recoveryClients: [UUID: RemoteEnvironmentClient] = [:]
    @ObservationIgnored private var currentKey: RemoteWorkspaceInspectorKey?
    @ObservationIgnored private var currentInput: (target: RemoteWorkspaceTarget, client: RemoteEnvironmentClient?, canMutate: Bool)?

    init(pendingStore: RemoteWorkspacePendingStore, recoveryJournal: EditorRecoveryJournal? = nil) { self.pendingStore = pendingStore; self.recoveryJournal = recoveryJournal }

    var hasUnsavedEdits: Bool { models.values.contains(where: \.hasUnsavedEdits) }
    var retainedEditors: [RemoteWorkspaceInspectorModel] {
        models.values.filter(\.hasUnsavedEdits).sorted { Data($0.session.target.workspacePath.utf8).lexicographicallyPrecedes(Data($1.session.target.workspacePath.utf8)) }
    }
    func refreshRecoveredDrafts() async {
        guard let journal = recoveryJournal else { return }
        do {
            let values = try await Task.detached { try journal.load() }.value
            guard !closed else { return }
            let openIDs = Set(models.values.flatMap { $0.files.buffers.values.map { $0.recovery.id } })
            recoveredDrafts = values.filter { if case .remote = $0.scope { return !openIDs.contains($0.id) }; return false }.sorted { $0.updatedAt > $1.updatedAt }
            recoveryError = nil
        } catch { recoveryError = error.localizedDescription }
    }
    func discardRecoveredDraft(_ record: EditorRecoveryRecord) async {
        guard let journal = recoveryJournal, case .remote = record.scope else { return }
        do { try await Task.detached { try journal.remove(id: record.id, expectedVersion: record.version) }.value; await refreshRecoveredDrafts(); await selected?.files.refreshRecoveredDrafts() }
        catch { recoveryError = error.localizedDescription }
    }

    func select(environmentID: UUID, thread: CodingThread, client: RemoteEnvironmentClient?, canMutate: Bool) async {
        await select(target: .init(environmentID: environmentID, projectID: thread.projectID, threadID: thread.id,
            configuration: .init(thread: thread)), client: client, canMutate: canMutate)
    }
    func select(target: RemoteWorkspaceTarget, client: RemoteEnvironmentClient?, canMutate: Bool) async {
        let environmentID = target.environmentID
        guard !closed else { return }
        let owner = UUID(); selection = owner
        if let client { recoveryClients[environmentID] = client }
        let key = RemoteWorkspaceInspectorKey(environmentID: environmentID, threadID: target.threadID, path: Data(target.workspacePath.utf8))
        let sameCurrentWorkspace = currentKey == key
        currentKey = key; currentInput = (target, client, canMutate)
        if isShowingRetained, sameCurrentWorkspace {
            if let selected, let client, selected.session.target.environmentID == environmentID {
                await selected.session.connectForRecovery(client: client)
            }
            return
        }
        isShowingRetained = false
        let model: RemoteWorkspaceInspectorModel
        if let existing = models[key] { model = existing }
        else {
            if models.count >= 16 {
                guard let unused = models.first(where: { !$0.value.hasUnsavedEdits && $0.value !== selected }) else {
                    errorMessage = "Save or discard an open remote workspace's edits before opening another inspector."; return
                }
                unused.value.session.disconnect(); models.removeValue(forKey: unused.key)
            }
            model = RemoteWorkspaceInspectorModel(target: target, pendingStore: pendingStore, recoveryJournal: recoveryJournal)
            models[key] = model
        }
        if selected !== model { selected?.session.disconnect() }
        selected = model; errorMessage = nil
        await model.files.refreshRecoveredDrafts()
        await refreshRecoveredDrafts()
        guard selection == owner, !closed else { return }
        await model.session.connect(client: client, canMutate: canMutate)
        guard selection == owner, !closed else { return }
    }

    func clearSelection() {
        selection = UUID(); selected?.session.disconnect(); selected = nil
        isShowingRetained = false; currentKey = nil; currentInput = nil
    }

    var canReturnToCurrent: Bool { isShowingRetained && currentInput != nil }
    func returnToCurrent() async {
        guard let input = currentInput else { return }
        isShowingRetained = false
        await select(target: input.target, client: input.client, canMutate: input.canMutate)
    }

    func showRetained(_ model: RemoteWorkspaceInspectorModel) {
        guard !closed, models.values.contains(where: { $0 === model }) else { return }
        selection = UUID(); let owner = selection
        selected?.session.disconnect(); model.session.disconnect(); selected = model; isShowingRetained = true
        if let client = recoveryClients[model.session.target.environmentID] {
            Task {
                guard self.selection == owner, !self.closed else { return }
                await model.session.connectForRecovery(client: client)
            }
        }
    }

    func disconnect() {
        selection = UUID()
        recoveryClients = [:]
        if var input = currentInput { input.client = nil; currentInput = input }
        for model in models.values { model.session.disconnect() }
    }

    func shutdown() async {
        closed = true; selection = UUID(); recoveryClients = [:]
        for model in models.values { model.files.prepareForShutdown() }
        for model in models.values { await model.session.shutdown(); await model.files.flushRecovery() }
    }
    func cancelShutdown() { closed = false; for model in models.values { model.files.cancelShutdown() } }
}

@MainActor @Observable
final class RemoteWorkspaceInspectorModel {
    let id = UUID()
    let session: RemoteWorkspaceInspectorSession
    let files: RemoteFileBrowserStore
    let git: RemoteGitInspectorStore
    var tab = "Files"
    var hasUnsavedEdits: Bool { files.hasUnsavedEdits || !git.commitMessage.isEmpty || session.hasUnresolvedOperation }

    init(target: RemoteWorkspaceTarget, pendingStore: RemoteWorkspacePendingStore, recoveryJournal: EditorRecoveryJournal? = nil) {
        let session = RemoteWorkspaceInspectorSession(target: target, pendingStore: pendingStore)
        self.session = session
        files = RemoteFileBrowserStore(session: session, recoveryJournal: recoveryJournal)
        git = RemoteGitInspectorStore(session: session)
        git.hasDirtyFiles = { [weak files] in files?.hasUnsavedEdits == true }
        session.operationFinished = { [weak files, weak git] request, operation in
            files?.operationFinished(request, operation: operation)
            git?.operationFinished(request, operation: operation)
        }
    }
}
