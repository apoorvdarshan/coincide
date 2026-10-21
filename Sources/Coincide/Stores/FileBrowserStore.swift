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
    var isDirty: Bool { contents != original }
    var canWrite: Bool { !closed && workspace?.canAccessWorkspaceFiles(workspacePath) == true && document?.revision != nil && document?.truncated == false && !isReading && !isSaving }

    init(workspace: WorkspaceStore, path: String, service: WorkspaceFileService, documentLoader: DocumentLoader? = nil) {
        self.workspace = workspace; workspacePath = path; self.service = service
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
        await reloadEntries()
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
        contents = text; updateDirty()
    }
    @discardableResult func open(_ path: String, navigation: FileNavigation? = nil, discardChanges: Bool = false) async -> Bool {
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
            document = value; contents = value.contents; original = value.contents
            self.navigation = navigation; hasExternalChanges = false; operationError = nil; updateDirty()
            return true
        } catch is CancellationError { return false }
        catch { if !closed, !Task.isCancelled, readID == id { operationError = error.localizedDescription }; return false }
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
