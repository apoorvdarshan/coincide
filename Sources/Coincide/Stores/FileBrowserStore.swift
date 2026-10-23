import CoincideCore
import Foundation
import Observation

enum WorkspaceFileSearchMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case paths, contents
    var id: String { rawValue }
}
struct WorkspaceFileSearchRequest: Hashable, Sendable {
    let directory: String
    let query: String
    let mode: WorkspaceFileSearchMode
    let caseSensitive: Bool
    let wholeWord: Bool
    let useRegex: Bool
}
private enum FileBrowserListing: Sendable {
    case paths(WorkspaceEntryPage)
    case contents(WorkspaceContentSearchResult)
}

/// Shared workspace editor state survives inspector visibility and conversation changes.
@MainActor @Observable
final class FileBrowserStore {
    typealias DocumentLoader = @Sendable (String) async throws -> WorkspaceTextDocument
    let workspacePath: String
    let service: WorkspaceFileService
    private weak var workspace: WorkspaceStore?
    var workspaceStore: WorkspaceStore? { workspace }
    private let loadDocument: DocumentLoader
    private let editorID = UUID()
    let recoveryJournal: EditorRecoveryJournal
    private(set) var recovery: EditorRecoveryBuffer
    private(set) var recoveredDrafts: [EditorRecoveryRecord] = []
    private(set) var recoveryError: String?
    private(set) var recoveredRootUnavailable = false
    var directory = ""
    var query = ""
    var searchMode = WorkspaceFileSearchMode.paths
    var caseSensitive = false
    var wholeWord = false
    var useRegex = false
    var searchRequest: WorkspaceFileSearchRequest { .init(directory: directory, query: query, mode: searchMode, caseSensitive: caseSensitive, wholeWord: wholeWord, useRegex: useRegex) }
    private(set) var entries: [WorkspaceEntry] = []
    private(set) var contentMatches: [WorkspaceContentMatch] = []
    private(set) var regexFallbackError: String?
    private(set) var truncated = false
    private(set) var isLoading = false
    private(set) var isReading = false
    private(set) var isSaving = false
    private(set) var document: WorkspaceTextDocument?
    private(set) var contents = ""
    private(set) var original = ""
    private(set) var hasExternalChanges = false
    var listingError: String?
    var operationError: String?
    var navigation: FileNavigation?
    private var listID = UUID()
    private var publishedSearchRequest: WorkspaceFileSearchRequest?
    private var readID = UUID()
    private var lastNavigationID: UUID?
    private var listTask: Task<FileBrowserListing, any Error>?
    private var readTask: Task<WorkspaceTextDocument, any Error>?
    private var writeTask: Task<WorkspaceTextDocument, any Error>?
    private var watchTask: Task<Void, Never>?
    private var starting = false
    private var closed = false
    private var mutationGeneration = UUID()
    private var mutationSuspended = false
    var isDirty: Bool { !contents.utf8.elementsEqual(original.utf8) }
    var canWrite: Bool { !closed && !recoveredRootUnavailable && !mutationSuspended && workspace?.canAccessWorkspaceFiles(workspacePath) == true && document?.revision != nil && document?.truncated == false && !isReading && !isSaving }

    init(workspace: WorkspaceStore, path: String, service: WorkspaceFileService, documentLoader: DocumentLoader? = nil,
         recoveryJournal: EditorRecoveryJournal? = nil) {
        self.workspace = workspace; workspacePath = path; self.service = service
        let journal = recoveryJournal ?? .init(root: workspace.worktreesRoot.deletingLastPathComponent().appendingPathComponent("EditorRecovery", isDirectory: true))
        self.recoveryJournal = journal; recovery = .init(journal: journal)
        loadDocument = documentLoader ?? { try await service.readFile(relativePath: $0) }
    }
    func start() async {
        guard !closed, !starting, watchTask == nil else { return }
        starting = true; defer { starting = false }
        let stream = await service.invalidations()
        guard !closed, !Task.isCancelled else { return }
        watchTask = Task { [weak self] in
            for await _ in stream {
                guard let self, !self.closed, !Task.isCancelled else { break }
                await self.changedOnDisk()
            }
        }
        await refreshRecoveredDrafts(); await reloadEntries()
    }
    func reloadEntries() async {
        guard !closed, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return }
        let id = UUID(); listID = id; isLoading = true
        let previous = listTask; previous?.cancel()
        let service = service, request = searchRequest
        if publishedSearchRequest != request { entries = []; contentMatches = []; regexFallbackError = nil; listingError = nil; truncated = false }
        defer { if listID == id { isLoading = false; listTask = nil } }
        _ = await previous?.result
        guard !closed, !Task.isCancelled, listID == id, request == searchRequest, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return }
        let task = Task<FileBrowserListing, any Error> {
            if request.mode == .contents {
                if request.query.isEmpty { return .contents(.init(matches: [], truncated: false)) }
                let result = try await service.searchContents(query: request.query, caseSensitive: request.caseSensitive, wholeWord: request.wholeWord, useRegex: request.useRegex)
                return .contents(result)
            }
            if request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let page = try await service.listEntries(directoryPath: request.directory); return .paths(page)
            }
            let page = try await service.searchEntries(query: request.query); return .paths(page)
        }
        listTask = task
        do {
            let page = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !closed, !Task.isCancelled, listID == id, request == searchRequest, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return }
            switch page {
            case .paths(let page): entries = page.entries; contentMatches = []; truncated = page.truncated; regexFallbackError = nil
            case .contents(let page): entries = []; contentMatches = page.matches; truncated = page.truncated; regexFallbackError = page.regexFallbackError
            }
            listingError = nil; publishedSearchRequest = request
        } catch is CancellationError { }
        catch { if !closed, !Task.isCancelled, listID == id, request == searchRequest { entries = []; contentMatches = []; truncated = false; regexFallbackError = nil; listingError = error.localizedDescription } }
    }
    func setContents(_ text: String) {
        guard canWrite else { return }
        guard text.utf8.count <= EditorRecoveryJournal.maximumTextBytes else { operationError = "Keep editor buffers under 2 MB so their unsaved text can be recovered."; return }
        contents = text; updateDirty(); persistRecovery()
    }
    private func persistRecovery() {
        guard let document else { return }
        do { recovery.replace(try .native(workspacePath: workspacePath, document: document, contents: contents, id: recovery.id)) }
        catch { recovery.failed(error) }
    }
    func refreshRecoveredDrafts(excluding recordID: UUID? = nil) async {
        let journal = recoveryJournal
        do {
            let values = try await Task.detached { try journal.load() }.value
            guard !closed else { return }
            recoveredDrafts = values.filter { if case .native = $0.scope { return $0.id != (recordID ?? recovery.id) }; return false }.sorted { $0.updatedAt > $1.updatedAt }
            recoveryError = nil
        } catch { recoveryError = error.localizedDescription }
    }
    func discardRecoveredDraft(_ record: EditorRecoveryRecord) async {
        guard case .native = record.scope else { return }
        let journal = recoveryJournal
        do { try await Task.detached { try journal.remove(id: record.id, expectedVersion: record.version) }.value; await refreshRecoveredDrafts() }
        catch { recoveryError = error.localizedDescription }
    }
    func restoreRecoveredDraft(_ record: EditorRecoveryRecord) async {
        guard !closed, !isDirty, !isSaving, !isReading, record.scope.matchesNative(workspacePath), let saved = record.nativeDocument else { return }
        let owner = UUID(); readID = owner; isReading = true
        defer { if readID == owner { isReading = false } }
        let current = try? await loadDocument(record.relativePath)
        guard !closed, !Task.isCancelled, readID == owner, !isDirty else { return }
        await recovery.flush()
        guard !closed, !Task.isCancelled, readID == owner, !isDirty else { return }
        await refreshRecoveredDrafts(excluding: record.id)
        guard !closed, !Task.isCancelled, readID == owner, !isDirty else { return }
        recovery = .init(journal: recoveryJournal, restored: record)
        document = saved; contents = record.contents; original = record.original; navigation = nil
        recoveredRootUnavailable = current.map { !record.matchesNativeRoot($0) } ?? true
        hasExternalChanges = current?.revision != saved.revision
        operationError = recoveredRootUnavailable ? "The recovered draft belongs to a missing or replaced workspace folder. Its text is available to copy; it cannot be saved into this folder." : nil
        updateDirty()
    }
    func discardCurrentEdits() {
        guard !isSaving, !isReading else { return }
        contents = original; recovery.replace(nil)
        if recoveredRootUnavailable { document = nil; contents = ""; original = ""; recoveredRootUnavailable = false }
        updateDirty()
    }
    @discardableResult func open(_ path: String, navigation: FileNavigation? = nil, discardChanges: Bool = false, clearOnFailure: Bool = false) async -> Bool {
        guard !closed, !isSaving, workspace?.canAccessWorkspaceFiles(workspacePath) == true, !isDirty || discardChanges else { return false }
        let id = UUID(); readID = id; isReading = true
        let previous = readTask; previous?.cancel()
        defer { if readID == id { isReading = false; readTask = nil } }
        _ = await previous?.result
        guard !closed, !Task.isCancelled, readID == id, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return false }
        let loader = loadDocument, task = Task { try await loader(path) }
        readTask = task
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !closed, !Task.isCancelled, readID == id, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return false }
            if discardChanges, isDirty { recovery.replace(nil) }
            await recovery.flush()
            guard !closed, !Task.isCancelled, readID == id else { return false }
            let nextRecovery = EditorRecoveryBuffer(journal: recoveryJournal)
            // Recovery inventory is independent I/O. Complete it before the
            // fresh file is published so observing those bytes also observes
            // settlement of this read and its enclosing mutation refresh.
            await refreshRecoveredDrafts(excluding: nextRecovery.id)
            guard !closed, !Task.isCancelled, readID == id,
                  workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return false }
            recovery = nextRecovery; recoveredRootUnavailable = false
            document = value; contents = value.contents; original = value.contents
            self.navigation = navigation; hasExternalChanges = false; operationError = nil; updateDirty()
            return true
        } catch is CancellationError { return false }
        catch {
            if !closed, !Task.isCancelled, readID == id {
                operationError = error.localizedDescription
                if clearOnFailure, document?.relativePath == path, !isDirty, !isSaving {
                    document = nil; contents = ""; original = ""; self.navigation = nil
                    hasExternalChanges = false; updateDirty()
                }
            }
            return false
        }
    }
    func navigate(_ navigation: FileNavigation) {
        guard !closed, document?.relativePath == navigation.path, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return }
        readID = UUID(); readTask?.cancel(); isReading = false
        self.navigation = navigation
    }
    func consumeNavigation(_ navigation: FileNavigation) -> Bool {
        guard lastNavigationID != navigation.id else { return false }
        lastNavigationID = navigation.id; return true
    }
    func save() async {
        guard canWrite, isDirty, let document, let revision = document.revision else { return }
        let text = contents
        await write(path: document.relativePath, text: text, condition: .matching(revision))
    }
    func createFile(path: String) async -> Bool {
        guard !closed, !mutationSuspended, !isSaving, !isReading, !isDirty, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return false }
        return await write(path: path, text: "", condition: .missing)
    }
    @discardableResult private func write(path: String, text: String, condition: WorkspaceFileWriteCondition) async -> Bool {
        guard !closed, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return false }
        let savingCurrent = document?.relativePath.utf8.elementsEqual(path.utf8) == true
        isSaving = true
        await recovery.flush()
        guard !closed, !Task.isCancelled, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { isSaving = false; return false }
        let service = service, task = Task { try await service.writeFile(relativePath: path, contents: text, expected: condition) }
        writeTask = task
        defer { isSaving = false; writeTask = nil }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !closed, !Task.isCancelled, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return false }
            document = value; contents = value.contents; original = value.contents
            hasExternalChanges = false; operationError = nil; updateDirty()
            if savingCurrent { recovery.replace(nil); await recovery.flush() }
            else { recovery = .init(journal: recoveryJournal) }
            await refreshRecoveredDrafts()
            await reloadEntries()
            return true
        } catch is CancellationError { return false }
        catch { if !closed, !Task.isCancelled { operationError = error.localizedDescription }; return false }
    }
    private func changedOnDisk() async {
        guard !closed, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return }
        await reloadEntries()
        guard let document, !isSaving, !isReading else { return }
        if isDirty { hasExternalChanges = true; return }
        _ = await open(document.relativePath, navigation: navigation, clearOnFailure: true)
    }
    func refresh() async { await service.refresh(); await reloadEntries() }
    /// A durable workspace mutation owns subsequent disk state. Invalidate old
    /// reads before it starts, including results that finish after the lock lifts.
    func suspendForWorkspaceMutation() {
        mutationGeneration = UUID(); mutationSuspended = true
        listID = UUID(); readID = UUID()
        listTask?.cancel(); readTask?.cancel()
        listTask = nil; readTask = nil; isLoading = false; isReading = false
        publishedSearchRequest = nil
    }
    func refreshAfterWorkspaceMutation() async {
        guard !closed, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return }
        let generation = mutationGeneration
        mutationSuspended = true
        defer { if mutationGeneration == generation { mutationSuspended = false } }
        await service.refresh(); await reloadEntries()
        guard !closed, workspace?.canAccessWorkspaceFiles(workspacePath) == true, !isSaving else { return }
        guard !isDirty else { hasExternalChanges = true; return }
        guard let document else { return }
        // Only the current read's actual failure can clear old clean bytes.
        // A cancelled refresh must not erase a newer selection or successful read.
        _ = await open(document.relativePath, navigation: navigation, clearOnFailure: true)
    }
    private func updateDirty() { workspace?.setEditorDirty(editorID, workspacePath: workspacePath, dirty: isDirty) }
    func prepareForShutdown() {
        closed = true; listID = UUID(); readID = UUID()
        listTask?.cancel(); readTask?.cancel(); writeTask?.cancel(); watchTask?.cancel()
        workspace?.setEditorDirty(editorID, workspacePath: workspacePath, dirty: false)
    }
    func shutdown() async {
        prepareForShutdown()
        _ = await listTask?.result; _ = await readTask?.result; _ = await writeTask?.result; await watchTask?.value
        await recovery.flush()
    }
}
