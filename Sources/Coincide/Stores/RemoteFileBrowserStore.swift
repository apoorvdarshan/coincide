import CoincideCore
import Foundation
import Observation

@MainActor @Observable
final class RemoteFileBuffer {
    var document: RemoteWorkspaceDocument
    var contents: String
    var original: String
    var hasExternalChanges = false
    var isDirty: Bool { !contents.utf8.elementsEqual(original.utf8) }
    init(_ document: RemoteWorkspaceDocument) {
        self.document = document; contents = document.contents; original = document.contents
    }
}

/// Only typed remote RPCs access project data. Buffers remain editable while
/// disconnected and are retained when another file or conversation is selected.
@MainActor @Observable
final class RemoteFileBrowserStore {
    let session: RemoteWorkspaceInspectorSession
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

    init(session: RemoteWorkspaceInspectorSession) { self.session = session }
    var buffer: RemoteFileBuffer? { selectedPath.flatMap { buffers[Data($0.utf8)] } }
    var document: RemoteWorkspaceDocument? { buffer?.document }
    var contents: String { buffer?.contents ?? "" }
    var isDirty: Bool { buffer?.isDirty ?? false }
    var hasUnsavedEdits: Bool { buffers.values.contains(where: \.isDirty) }
    var openPaths: [String] { buffers.values.map(\.document.relativePath).sorted { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) } }
    var canEdit: Bool { buffer?.document.truncated == false }
    var canSave: Bool { session.canMutate && !isPreparingSave && isDirty && document?.revision != nil && document?.truncated == false }
    var searchRequest: WorkspaceFileSearchRequest {
        .init(directory: directory, query: query, mode: searchMode, caseSensitive: caseSensitive, wholeWord: wholeWord, useRegex: useRegex)
    }

    func setContents(_ text: String) {
        guard canEdit, let buffer else { return }
        guard text.utf8.count <= 2_000_000 else { operationError = "Keep remote editor buffers under 2 MB."; return }
        buffer.contents = text
    }

    func reloadEntries() async {
        guard session.canRead else { return }
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
            buffers[key] = RemoteFileBuffer(value); selectedPath = value.relativePath; operationError = nil
            return true
        } catch is CancellationError { return false }
        catch { if readID == owner { operationError = RemoteWorkspaceInspectorSession.safeMessage(error) }; return false }
    }

    func save() async {
        guard canSave, let buffer else { return }
        let path = buffer.document.relativePath, text = buffer.contents, baseline = Data(buffer.original.utf8)
        isPreparingSave = true; defer { isPreparingSave = false }
        do {
            // Revision tokens are intentionally local to the owned host process.
            // Reacquire one after reconnect without discarding the dirty buffer.
            guard case .document(let current) = try await session.read(.readFile(path: path, allowMissing: false, maxBytes: 2_000_000)),
                  current.relativePath.utf8.elementsEqual(path.utf8), !current.truncated, let revision = current.revision,
                  Data(current.contents.utf8) == baseline, Data(buffer.original.utf8) == baseline else {
                buffer.hasExternalChanges = true; throw RemoteWorkspaceFailure(.conflict)
            }
            buffer.document = current; buffer.hasExternalChanges = false; operationError = nil
            await session.perform(.saveFile(path: path, contents: text, revision: revision))
        } catch is CancellationError { }
        catch { operationError = RemoteWorkspaceInspectorSession.safeMessage(error) }
    }

    func createFile(path: String, contents: String = "") async {
        guard session.canMutate else { return }
        await session.perform(.createFile(path: path, contents: contents))
    }

    func discardCurrentEdits() {
        guard let buffer else { return }
        buffer.contents = buffer.original
    }

    func operationFinished(_ request: RemoteWorkspaceMutationRequest, operation: RemoteWorkspaceOperation) {
        guard operation.state == .finished, operation.failure == nil else { return }
        switch request.mutation {
        case .saveFile(let path, let text, _), .createFile(let path, let text):
            guard case .document(let document) = operation.result,
                  document.relativePath.utf8.elementsEqual(path.utf8), document.contents.utf8.elementsEqual(text.utf8) else {
                operationError = "The remote save result could not be verified. Your editor text was retained."; return
            }
            let key = Data(path.utf8)
            if let existing = buffers[key] {
                // Preserve any newer text typed while this save was in flight.
                existing.document = document; existing.original = text; existing.hasExternalChanges = false
            } else if buffers.count < 16 {
                buffers[key] = RemoteFileBuffer(document)
                if selectedPath == nil { selectedPath = path }
            }
            operationError = nil
            Task { await reloadEntries() }
        case .gitCheckout, .gitCreateBranch, .gitPull:
            for buffer in buffers.values { buffer.hasExternalChanges = true }
            Task { await reloadEntries() }
        default: break
        }
    }
}
