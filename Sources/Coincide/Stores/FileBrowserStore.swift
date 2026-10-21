import CoincideCore
import Foundation
import Observation

/// Shared workspace editor state survives inspector visibility and conversation changes.
@MainActor @Observable
final class FileBrowserStore {
    let workspacePath: String
    let service: WorkspaceFileService
    private weak var workspace: WorkspaceStore?
    private let editorID = UUID()
    var directory = ""
    var query = ""
    private(set) var entries: [WorkspaceEntry] = []
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
    private var readID = UUID()
    private var lastNavigationID: UUID?
    private var listTask: Task<WorkspaceEntryPage, any Error>?
    private var readTask: Task<WorkspaceTextDocument, any Error>?
    private var writeTask: Task<WorkspaceTextDocument, any Error>?
    private var watchTask: Task<Void, Never>?
    private var starting = false
    private var closed = false
    var isDirty: Bool { contents != original }
    var canWrite: Bool { !closed && workspace?.canAccessWorkspaceFiles(workspacePath) == true && document?.revision != nil && document?.truncated == false && !isReading && !isSaving }

    init(workspace: WorkspaceStore, path: String, service: WorkspaceFileService) {
        self.workspace = workspace; workspacePath = path; self.service = service
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
        await reloadEntries()
    }
    func reloadEntries() async {
        guard !closed, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return }
        let id = UUID(); listID = id; isLoading = true; listTask?.cancel()
        let service = service, directory = directory, query = query
        let task = Task {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return try await service.listEntries(directoryPath: directory) }
            return try await service.searchEntries(query: query)
        }
        listTask = task
        defer { if listID == id { isLoading = false; listTask = nil } }
        do {
            let page = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !closed, !Task.isCancelled, listID == id, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return }
            entries = page.entries; truncated = page.truncated; listingError = nil
        } catch is CancellationError { }
        catch { if !closed, !Task.isCancelled, listID == id { entries = []; truncated = false; listingError = error.localizedDescription } }
    }
    func setContents(_ text: String) {
        guard canWrite else { return }
        contents = text; updateDirty()
    }
    @discardableResult func open(_ path: String, navigation: FileNavigation? = nil, discardChanges: Bool = false) async -> Bool {
        guard !closed, !isSaving, workspace?.canAccessWorkspaceFiles(workspacePath) == true, !isDirty || discardChanges else { return false }
        let id = UUID(); readID = id; isReading = true; readTask?.cancel()
        let service = service, task = Task { try await service.readFile(relativePath: path) }
        readTask = task
        defer { if readID == id { isReading = false; readTask = nil } }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !closed, !Task.isCancelled, readID == id, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return false }
            document = value; contents = value.contents; original = value.contents
            self.navigation = navigation; hasExternalChanges = false; operationError = nil; updateDirty()
            return true
        } catch is CancellationError { return false }
        catch { if !closed, !Task.isCancelled, readID == id { operationError = error.localizedDescription }; return false }
    }
    func navigate(_ navigation: FileNavigation) { self.navigation = navigation }
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
        guard !closed, !isSaving, !isReading, !isDirty, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return false }
        return await write(path: path, text: "", condition: .missing)
    }
    @discardableResult private func write(path: String, text: String, condition: WorkspaceFileWriteCondition) async -> Bool {
        guard !closed, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return false }
        isSaving = true
        let service = service, task = Task { try await service.writeFile(relativePath: path, contents: text, expected: condition) }
        writeTask = task
        defer { isSaving = false; writeTask = nil }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !closed, !Task.isCancelled, workspace?.canAccessWorkspaceFiles(workspacePath) == true else { return false }
            document = value; contents = value.contents; original = value.contents
            hasExternalChanges = false; operationError = nil; updateDirty()
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
        _ = await open(document.relativePath, navigation: navigation)
    }
    func refresh() async { await service.refresh(); await reloadEntries() }
    private func updateDirty() { workspace?.setEditorDirty(editorID, workspacePath: workspacePath, dirty: isDirty) }
    func prepareForShutdown() {
        closed = true; listID = UUID(); readID = UUID()
        listTask?.cancel(); readTask?.cancel(); writeTask?.cancel(); watchTask?.cancel()
        workspace?.setEditorDirty(editorID, workspacePath: workspacePath, dirty: false)
    }
    func shutdown() async {
        prepareForShutdown()
        _ = await listTask?.result; _ = await readTask?.result; _ = await writeTask?.result; await watchTask?.value
    }
}
