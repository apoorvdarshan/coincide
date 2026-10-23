import CoincideCore
import Foundation
import Observation

@MainActor struct AgentSessionImportTransport {
    var scan: () async throws -> AgentSessionScanResult
    var prepare: (UUID, AgentSessionProjectCandidate, UUID?) async throws -> AgentSessionImportPage
    var accept: (UUID, String, UUID) async throws -> WorkspaceCommandReceipt
    var receipt: (UUID, String, UUID) async throws -> WorkspaceCommandReceipt?
    var release: (UUID) async -> Void
}

struct AgentSessionImportProgress: Codable, Sendable, Equatable {
    var imported = 0
    var alreadyImported = 0
    var duplicates = 0
    var skipped = 0
    var failed = 0
}
struct AgentSessionPendingImport: Codable, Sendable, Identifiable {
    var id: UUID { commandID }
    let commandID: UUID
    let reviewID: UUID
    let digest: String
    let scanID: UUID
    let projectID: UUID
    let workspacePath: String
    let candidateID: UUID
}
private struct AgentSessionImportDocument: Codable, Sendable {
    var version = 1
    var pending: AgentSessionPendingImport?
    var progress = AgentSessionImportProgress()
    var projectTitle: String?
}
private actor AgentSessionImportPersistence {
    let files: RemotePrivateDocumentStore
    var bytes: Data?
    init(root: URL) { files = .init(root: root) }
    func load() async throws -> AgentSessionImportDocument {
        let data = try await files.load(name: "session-import.json", maximum: 128 * 1_024)
        let document = try data.map { try JSONDecoder().decode(AgentSessionImportDocument.self, from: $0) } ?? .init()
        try validate(document); bytes = data; return document
    }
    func save(_ document: AgentSessionImportDocument) async throws {
        try validate(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try await files.save(data: data, name: "session-import.json", maximum: 128 * 1_024, expected: bytes)
        bytes = data
    }
    private func validate(_ value: AgentSessionImportDocument) throws {
        let counts = value.progress
        guard value.version == 1, [counts.imported, counts.alreadyImported, counts.duplicates, counts.skipped, counts.failed].allSatisfy({ (0...100_000).contains($0) }),
              (value.projectTitle?.utf8.count ?? 0) <= 4_096 else { throw AgentSessionImportError.invalidRequest }
        if let pending = value.pending {
            guard pending.digest.utf8.count == 64, pending.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  pending.workspacePath.hasPrefix("/"), pending.workspacePath.utf8.count <= 4_096,
                  !pending.workspacePath.contains("\0") else { throw AgentSessionImportError.invalidRequest }
        }
    }
}

/// Explicit local-source discovery. Only compact original-ID receipts and
/// progress are persisted; source transcript buffers remain bounded host leases.
@MainActor @Observable
final class AgentSessionImportStore {
    private(set) var scanResult: AgentSessionScanResult?
    var selectedCandidateID: UUID?
    private(set) var progress = AgentSessionImportProgress()
    private(set) var pending: AgentSessionPendingImport?
    private(set) var projectTitle: String?
    private(set) var isLoaded = false
    private(set) var isScanning = false
    private(set) var isImporting = false
    private(set) var isChecking = false
    private(set) var isClosing = false
    private(set) var scanAvailable = false
    private(set) var errorMessage: String?
    private(set) var status = "Scan local Codex and Claude projects to choose a project to import."
    @ObservationIgnored private let persistence: AgentSessionImportPersistence
    @ObservationIgnored private var transport: AgentSessionImportTransport?
    @ObservationIgnored private var document = AgentSessionImportDocument()
    @ObservationIgnored private var read: Task<AgentSessionScanResult, any Error>?
    @ObservationIgnored private var preparation: Task<AgentSessionImportPage, any Error>?
    @ObservationIgnored private var control: Task<WorkspaceCommandReceipt, any Error>?
    @ObservationIgnored private var flow: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var knownCursors: Set<UUID> = []
    @ObservationIgnored private var countedPages: Set<String> = []
    @ObservationIgnored private var loadedTask: Task<Void, Never>?
    var selectedCandidate: AgentSessionProjectCandidate? { scanResult?.candidates.first { $0.id == selectedCandidateID } }
    var isBusy: Bool { isScanning || isImporting || isChecking || isClosing }
    init(root: URL) { persistence = .init(root: root) }
    func bind(_ transport: AgentSessionImportTransport) { self.transport = transport }
    func open() async {
        await cleanup?.value
        guard !Task.isCancelled else { return }
        isClosing = false; stopRequested = false
        await load()
    }
    func load() async {
        if let loadedTask { await loadedTask.value; return }
        guard !isLoaded else { return }
        let task = Task { [self] in
            do { document = try await persistence.load(); publish(); isLoaded = true }
            catch { errorMessage = "The saved import receipt could not be read safely. Its existing file was preserved." }
        }
        loadedTask = task; await task.value; loadedTask = nil
    }
    @discardableResult func scan() -> Task<Void, Never>? {
        guard let transport, isLoaded, !isBusy, pending == nil else { return nil }
        stopRequested = false; isScanning = true; errorMessage = nil; status = "Scanning local project metadata…"
        let old = scanResult?.id
        let task = Task { [self] in
            defer { isScanning = false; flow = nil; read = nil }
            if let old { await transport.release(old) }
            scanResult = nil; scanAvailable = false; selectedCandidateID = nil
            let read = Task { try await transport.scan() }; self.read = read
            do {
                let result = try await read.value
                guard !stopRequested, !Task.isCancelled else { await transport.release(result.id); return }
                guard result.candidates.count <= AgentSessionSource.allCases.count * AgentSessionImportProtocol.maximumDiscoveredTranscripts,
                      Set(result.candidates.map(\.id)).count == result.candidates.count else { throw AgentSessionImportError.invalidRequest }
                scanResult = result; scanAvailable = true; selectedCandidateID = result.candidates.first?.id
                status = result.candidates.isEmpty ? "No readable projects were found in the captured Codex and Claude profiles." : "Choose a project. Import is an explicit action."
                knownCursors = []; countedPages = []
            } catch is CancellationError { status = "Scan cancelled. No conversation was imported." }
            catch { errorMessage = Self.message(error); status = "Scan did not finish." }
        }
        flow = task; return task
    }
    @discardableResult func importSelected() -> Task<Void, Never>? {
        guard let transport, let scan = scanResult, let candidate = selectedCandidate, isLoaded, scanAvailable, !isBusy, pending == nil, !stopRequested else { return nil }
        isImporting = true; errorMessage = nil; projectTitle = candidate.title
        let task = Task { [self] in
            defer { isImporting = false; flow = nil; preparation = nil }
            do {
                var initial = document; initial.progress = .init(); initial.projectTitle = candidate.title
                try await persist(initial); knownCursors = []; countedPages = []
                var cursor: UUID?, projectID: UUID?, accepted = 0, pages = 0
                repeat {
                    try Task.checkCancellation(); guard !stopRequested else { break }
                    pages += 1; guard pages <= AgentSessionImportProtocol.maximumDiscoveredTranscripts + 1 else { throw AgentSessionImportError.limit }
                    status = "Reading the next saved conversation…"
                    let preparation = Task { try await transport.prepare(scan.id, candidate, cursor) }; self.preparation = preparation
                    let page = try await preparation.value; self.preparation = nil
                    guard !stopRequested else { break }
                    guard page.scanID == scan.id, page.reviews.count <= 1, page.skippedCount >= 0,
                          page.alreadyImported.count <= AgentSessionImportProtocol.maximumDiscoveredTranscripts,
                          page.duplicates.count <= AgentSessionImportProtocol.maximumDiscoveredTranscripts,
                          page.complete == (page.nextCursor == nil) else { throw AgentSessionImportError.invalidRequest }
                    if let next = page.nextCursor { guard knownCursors.insert(next).inserted else { throw AgentSessionImportError.invalidRequest } }
                    let key = cursor?.uuidString ?? "first"
                    if countedPages.insert(key).inserted {
                        var next = document
                        next.progress.alreadyImported += page.alreadyImported.count; next.progress.duplicates += page.duplicates.count
                        next.progress.skipped += page.skippedCount; try await persist(next)
                    }
                    for review in page.reviews {
                        guard accepted < AgentSessionImportProtocol.maximumRecentTranscripts, review.scanID == scan.id,
                              review.expectedWorkspaceRoot.utf8.elementsEqual(candidate.path.utf8),
                              projectID == nil || projectID == review.projectID else { throw AgentSessionImportError.invalidRequest }
                        projectID = review.projectID
                        let operation = AgentSessionPendingImport(commandID: UUID(), reviewID: review.id, digest: review.digest,
                            scanID: scan.id, projectID: review.projectID, workspacePath: review.expectedWorkspaceRoot, candidateID: candidate.id)
                        var next = document; next.pending = operation; try await persist(next)
                        guard !stopRequested else { var cancelled = document; cancelled.pending = nil; try await persist(cancelled); break }
                        status = "Importing a reviewed conversation…"
                        let control = Task { try await transport.accept(operation.reviewID, operation.digest, operation.commandID) }; self.control = control
                        let receipt: WorkspaceCommandReceipt
                        do { receipt = try await control.value; self.control = nil }
                        catch { self.control = nil; status = "Import result unconfirmed. Check Result before continuing."; errorMessage = "The original import has not been repeated."; return }
                        guard receipt.commandID == operation.commandID else { throw AgentSessionImportError.invalidRequest }
                        try await settle(receipt, operation: operation)
                        guard receipt.rejection == nil else { status = "This conversation was not imported. Scan again to review the current source."; return }
                        accepted += 1
                    }
                    cursor = page.nextCursor
                    if page.complete { status = "Project import finished."; break }
                } while !stopRequested
                if stopRequested { status = "Import paused. Confirmed histories are kept; no further conversations were started." }
            } catch is CancellationError { status = "Import paused. Confirmed histories are kept." }
            catch { errorMessage = Self.message(error); status = pending == nil ? "Import stopped. Scan again to review the current source." : "Import result unconfirmed. Check Result before continuing." }
        }
        flow = task; return task
    }
    @discardableResult func checkResult() -> Task<Void, Never>? {
        guard let transport, let operation = pending, isLoaded, !isBusy else { return nil }
        stopRequested = false; isChecking = true; errorMessage = nil
        let task = Task { [self] in
            defer { isChecking = false; flow = nil }
            do {
                guard let receipt = try await transport.receipt(operation.reviewID, operation.digest, operation.commandID) else {
                    status = "The original import is still unconfirmed. It has not been repeated."; return
                }
                guard receipt.commandID == operation.commandID else { throw AgentSessionImportError.invalidRequest }
                try await settle(receipt, operation: operation)
                status = receipt.rejection == nil ? "The original import is confirmed. Scan again to continue." : "The original import was not admitted. Scan again to review current sources."
            } catch { errorMessage = "The original import could not be confirmed. Its receipt and command ID were kept." }
        }
        flow = task; return task
    }
    func requestPause() {
        guard cleanup == nil else { return }
        stopRequested = true; isClosing = true
        read?.cancel(); preparation?.cancel()
        cleanup = Task { [self] in
            await flow?.value; _ = await control?.result
            if let scan = scanResult { await transport?.release(scan.id) }
            scanAvailable = false; isClosing = false; cleanup = nil
        }
    }
    func shutdown() async { requestPause(); await cleanup?.value; await loadedTask?.value }
    func cancelShutdown() { stopRequested = false }
    private func settle(_ receipt: WorkspaceCommandReceipt, operation: AgentSessionPendingImport) async throws {
        guard document.pending?.commandID == operation.commandID else { throw AgentSessionImportError.invalidRequest }
        var next = document; next.pending = nil
        if receipt.rejection != nil { next.progress.failed += 1 }
        else if receipt.eventCount == 0 { next.progress.duplicates += 1 }
        else { next.progress.imported += 1 }
        try await persist(next)
    }
    private func persist(_ value: AgentSessionImportDocument) async throws { try await persistence.save(value); document = value; publish() }
    private func publish() { progress = document.progress; pending = document.pending; projectTitle = document.projectTitle }
    private static func message(_ error: any Error) -> String {
        (error as? AgentSessionImportError)?.localizedDescription ?? "The local session import could not finish. Existing conversations and original source files were kept."
    }
}
