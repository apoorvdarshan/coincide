import CoincideCore
import Foundation
import Observation

@MainActor @Observable
final class RemoteFileBuffer {
    var document: RemoteWorkspaceDocument
    var contents: String
    var original: String
    var hasExternalChanges = false
    let recovery: EditorRecoveryBuffer
    let recoveryTarget: RemoteWorkspaceTarget?
    var pendingOperationID: UUID?
    var isDirty: Bool { !contents.utf8.elementsEqual(original.utf8) }
    init(_ document: RemoteWorkspaceDocument, target: RemoteWorkspaceTarget? = nil,
         journal: EditorRecoveryJournal? = nil, restored: EditorRecoveryRecord? = nil) {
        self.document = document; contents = document.contents; original = document.contents
        recoveryTarget = target; recovery = .init(journal: journal, restored: restored)
        pendingOperationID = restored?.remoteOperationID
        if let restored { contents = restored.contents; original = restored.original; hasExternalChanges = true }
    }
    func persistRecovery(confirmedSave: Bool = false) {
        guard let target = recoveryTarget else { return }
        do { recovery.replace(confirmedSave && !isDirty ? nil : try .remote(target: target, document: document, contents: contents, id: recovery.id, operationID: pendingOperationID)) }
        catch { recovery.failed(error) }
    }
}

/// Only typed remote RPCs access project data. Buffers remain editable while
/// disconnected and are retained when another file or conversation is selected.
@MainActor @Observable
final class RemoteFileBrowserStore {
    let session: RemoteWorkspaceInspectorSession
    let recoveryJournal: EditorRecoveryJournal?
    private(set) var recoveredDrafts: [EditorRecoveryRecord] = []
    private(set) var recoveryError: String?
    var directory = ""
    var query = ""
    var searchMode = WorkspaceFileSearchMode.paths
    var caseSensitive = false
    var wholeWord = false
    var useRegex = false
    private(set) var entries: [WorkspaceEntry] = []
    private(set) var contentMatches: [WorkspaceContentMatch] = []
    private(set) var truncated = false
    private(set) var regexFallbackError: String?
    private(set) var isLoading = false
    private(set) var isReading = false
    private(set) var isPreparingSave = false
    private(set) var selectedPath: String?
    private(set) var buffers: [Data: RemoteFileBuffer] = [:]
    var listingError: String?
    var operationError: String?
    @ObservationIgnored private var listID = UUID()
    @ObservationIgnored private var readID = UUID()
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var saveOwners: [UUID: UUID] = [:]

    init(session: RemoteWorkspaceInspectorSession, recoveryJournal: EditorRecoveryJournal? = nil) { self.session = session; self.recoveryJournal = recoveryJournal }
    var buffer: RemoteFileBuffer? { selectedPath.flatMap { buffers[Data($0.utf8)] } }
    var document: RemoteWorkspaceDocument? { buffer?.document }
    var contents: String { buffer?.contents ?? "" }
    var isDirty: Bool { buffer?.isDirty ?? false }
    var hasUnsavedEdits: Bool { buffers.values.contains(where: \.isDirty) }
    var openPaths: [String] { buffers.values.map(\.document.relativePath).sorted { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) } }
    var canEdit: Bool { !closed && buffer?.document.truncated == false }
    var recoveredRootChanged: Bool { buffer?.recoveryTarget.map { $0.rootID != session.target.rootID } ?? false }
    var canSave: Bool { !closed && session.canMutate && !recoveredRootChanged && !isPreparingSave && isDirty && document?.revision != nil && document?.truncated == false }
    var searchRequest: WorkspaceFileSearchRequest {
        .init(directory: directory, query: query, mode: searchMode, caseSensitive: caseSensitive, wholeWord: wholeWord, useRegex: useRegex)
    }

    func setContents(_ text: String) {
        guard canEdit, let buffer else { return }
        guard text.utf8.count <= 2_000_000 else { operationError = "Keep remote editor buffers under 2 MB."; return }
        buffer.contents = text; buffer.persistRecovery()
    }
    func refreshRecoveredDrafts() async {
        guard !closed, let journal = recoveryJournal else { return }
        do {
            let values = try await Task.detached { try journal.load() }.value
            guard !closed else { return }
            let openIDs = Set(buffers.values.map { $0.recovery.id })
            recoveredDrafts = values.filter { $0.scope.matchesRemote(session.target, includingOtherRoots: true) && !openIDs.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
            recoveryError = nil
        } catch { recoveryError = error.localizedDescription }
    }
    func discardRecoveredDraft(_ record: EditorRecoveryRecord) async {
        guard let journal = recoveryJournal, record.scope.matchesRemote(session.target, includingOtherRoots: true) else { return }
        do { try await Task.detached { try journal.remove(id: record.id, expectedVersion: record.version) }.value; await refreshRecoveredDrafts() }
        catch { recoveryError = error.localizedDescription }
    }
    func restoreRecoveredDraft(_ record: EditorRecoveryRecord) async {
        guard !closed, let journal = recoveryJournal, record.scope.matchesRemote(session.target, includingOtherRoots: true),
              let document = record.remoteDocument, buffers[Data(record.relativePath.utf8)]?.isDirty != true else { return }
        let key = Data(record.relativePath.utf8)
        if buffers[key] == nil, buffers.count >= 16 { operationError = "Save or discard an open file before restoring another draft."; return }
        if let previous = buffers[key] { await previous.recovery.flush() }
        guard !closed, !Task.isCancelled, buffers[key]?.isDirty != true else { return }
        let target: RemoteWorkspaceTarget
        if case .remote(_, _, _, _, let rootID) = record.scope {
            let current = session.target
            target = .init(environmentID: current.environmentID, projectID: current.projectID, threadID: current.threadID, configuration: current.configuration, rootID: rootID)
        } else { return }
        buffers[key] = .init(document, target: target, journal: journal, restored: record); selectedPath = record.relativePath
        await refreshRecoveredDrafts()
    }
    func flushRecovery() async { for buffer in buffers.values { await buffer.recovery.flush() } }
    func prepareForShutdown() { closed = true; listID = UUID(); readID = UUID(); isLoading = false; isReading = false }
    func cancelShutdown() { closed = false }

    func reloadEntries() async {
        guard !closed, session.canRead else { return }
        let owner = UUID(); listID = owner
        let request = searchRequest
        isLoading = true
        defer { if listID == owner { isLoading = false } }
        do {
            let value: RemoteWorkspaceValue
            if request.mode == .contents {
                if request.query.isEmpty { entries = []; contentMatches = []; truncated = false; return }
                value = try await session.read(.searchContents(query: request.query, limit: 500,
                    caseSensitive: request.caseSensitive, wholeWord: request.wholeWord, useRegex: request.useRegex))
            } else if request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value = try await session.read(.list(directoryPath: request.directory))
            } else { value = try await session.read(.searchPaths(query: request.query, limit: 100)) }
            guard listID == owner, searchRequest == request, !Task.isCancelled else { return }
            switch value {
            case .entries(let page): entries = page.entries; contentMatches = []; truncated = page.truncated; regexFallbackError = nil
            case .contents(let page): entries = []; contentMatches = page.matches; truncated = page.truncated; regexFallbackError = page.regexFallbackError
            default: throw RemoteWorkspaceFailure(.invalidRequest)
            }
            listingError = nil
        } catch is CancellationError { }
        catch { if listID == owner, searchRequest == request { listingError = RemoteWorkspaceInspectorSession.safeMessage(error) } }
    }

    @discardableResult
    func open(_ path: String, reload: Bool = false, discardChanges: Bool = false) async -> Bool {
        guard !closed else { return false }
        let key = Data(path.utf8)
        if let existing = buffers[key], !reload { selectedPath = existing.document.relativePath; return true }
        guard session.canRead else { operationError = "Reconnect to open a remote file. Existing editor buffers are retained."; return false }
        guard buffers[key]?.isDirty != true || discardChanges else { return false }
        let priorText = buffers[key].map { Data($0.contents.utf8) }
        let owner = UUID(); readID = owner; isReading = true
        defer { if readID == owner { isReading = false } }
        do {
            guard case .document(let value) = try await session.read(.readFile(path: path, allowMissing: false, maxBytes: 2_000_000)),
                  value.relativePath.utf8.elementsEqual(path.utf8) else { throw RemoteWorkspaceFailure(.invalidRequest) }
            guard readID == owner, !Task.isCancelled else { return false }
            // A newer edit made while Reload was waiting always wins.
            if let existing = buffers[key], priorText != Data(existing.contents.utf8) { return false }
            if buffers[key] == nil, buffers.count >= 16 {
                guard let unused = buffers.first(where: { !$0.value.isDirty && !$0.value.document.relativePath.utf8.elementsEqual(selectedPath?.utf8 ?? "".utf8) }) else {
                    operationError = "Save or discard an open file before opening another remote editor buffer."; return false
                }
                buffers.removeValue(forKey: unused.key)
            }
            if let existing = buffers[key] {
                if discardChanges { existing.recovery.replace(nil) }
                await existing.recovery.flush()
                guard readID == owner, !Task.isCancelled, priorText == Data(existing.contents.utf8) else { return false }
            }
            buffers[key] = RemoteFileBuffer(value, target: session.target, journal: recoveryJournal); selectedPath = value.relativePath; operationError = nil
            await refreshRecoveredDrafts()
            return true
        } catch is CancellationError { return false }
        catch { if readID == owner { operationError = RemoteWorkspaceInspectorSession.safeMessage(error) }; return false }
    }

    func save() async {
        guard canSave, let buffer else { return }
        let path = buffer.document.relativePath, text = buffer.contents, baseline = Data(buffer.original.utf8)
        isPreparingSave = true; defer { isPreparingSave = false }
        do {
            await buffer.recovery.flush()
            // Revision tokens are intentionally local to the owned host process.
            // Reacquire one after reconnect without discarding the dirty buffer.
            guard case .document(let current) = try await session.read(.readFile(path: path, allowMissing: false, maxBytes: 2_000_000)),
                  current.relativePath.utf8.elementsEqual(path.utf8), !current.truncated, let revision = current.revision,
                  Data(current.contents.utf8) == baseline, Data(buffer.original.utf8) == baseline else {
                buffer.hasExternalChanges = true; throw RemoteWorkspaceFailure(.conflict)
            }
            buffer.document = current; buffer.hasExternalChanges = false; operationError = nil
            await session.perform(.saveFile(path: path, contents: text, revision: revision), beforeBegin: { [weak self, weak buffer] request in
                guard let self, let buffer, self.buffers[Data(path.utf8)] === buffer,
                      let captured = buffer.recoveryTarget, RemoteWorkspaceInspectorSession.sameWorkspace(captured, request.target),
                      captured.rootID == request.target.rootID else { throw RemoteWorkspaceFailure(.staleRoot) }
                self.saveOwners = [request.id: buffer.recovery.id]
                buffer.pendingOperationID = request.id; buffer.persistRecovery()
                await buffer.recovery.flush()
                if buffer.recovery.journal != nil, !buffer.recovery.isDurable { throw EditorRecoveryError(.unsafeStorage) }
            })
        } catch is CancellationError { }
        catch { operationError = RemoteWorkspaceInspectorSession.safeMessage(error) }
    }

    func createFile(path: String, contents: String = "") async {
        guard !closed, session.canMutate else { return }
        await session.perform(.createFile(path: path, contents: contents))
    }

    func discardCurrentEdits() {
        guard !closed, let buffer else { return }
        buffer.contents = buffer.original; buffer.recovery.replace(nil)
    }

    func operationFinished(_ request: RemoteWorkspaceMutationRequest, operation: RemoteWorkspaceOperation) {
        defer { if operation.state == .finished { saveOwners.removeValue(forKey: request.id) } }
        guard operation.state == .finished, operation.failure == nil else { return }
        switch request.mutation {
        case .saveFile(let path, let text, _), .createFile(let path, let text):
            guard case .document(let document) = operation.result,
                  document.relativePath.utf8.elementsEqual(path.utf8), document.contents.utf8.elementsEqual(text.utf8) else {
                operationError = "The remote save result could not be verified. Your editor text was retained."; return
            }
            let key = Data(path.utf8)
            if let existing = buffers[key] {
                guard let captured = existing.recoveryTarget,
                      RemoteWorkspaceInspectorSession.sameWorkspace(captured, request.target), captured.rootID == request.target.rootID,
                      existing.pendingOperationID == request.id,
                      saveOwners[request.id].map({ $0 == existing.recovery.id }) ?? true else {
                    operationError = "The earlier save was confirmed for a different editor draft. Your current recovered text and its baseline were retained."; return
                }
                // Preserve any newer text typed while this save was in flight.
                existing.document = document; existing.original = text; existing.hasExternalChanges = false
                existing.pendingOperationID = nil
                existing.persistRecovery(confirmedSave: true)
            } else if buffers.count < 16 {
                buffers[key] = RemoteFileBuffer(document, target: request.target, journal: recoveryJournal)
                if selectedPath == nil { selectedPath = path }
            }
            operationError = nil
            Task { await flushRecovery(); await refreshRecoveredDrafts(); await reloadEntries() }
        case .gitCheckout, .gitCreateBranch, .gitPull:
            for buffer in buffers.values { buffer.hasExternalChanges = true }
            Task { await reloadEntries() }
        default: break
        }
    }
}
