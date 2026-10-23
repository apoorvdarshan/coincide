import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private actor AgentImportStoreGate {
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        waiting = true; observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { continuation = $0 }
    }
    func wait() async { if !waiting { await withCheckedContinuation { observers.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class AgentImportStoreFixture {
    let root: URL
    let candidate: AgentSessionProjectCandidate
    let scanID = UUID(), cursor = UUID()
    let reviews: [AgentSessionImportReview]
    var scanCalls = 0, prepareCalls = 0, releases: [UUID] = []
    var commands: [(UUID, String, UUID)] = []
    var receipts: [UUID: WorkspaceCommandReceipt] = [:]
    var loseReply = false, hideReceipt = false
    var prepareGate: AgentImportStoreGate?, acceptGate: AgentImportStoreGate?
    var acceptedWasCancelled = false
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-agent-import-store-\(UUID())").resolvingSymlinksInPath()
        let project = UUID(), workspace = root.appendingPathComponent("SyntheticProject").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        candidate = .init(id: UUID(), path: workspace, title: "Synthetic Project", projectID: project, sources: [.codex], threadCount: 2,
            lastActiveAt: Date(), alreadyImported: true)
        var registeredProject = WorkspaceProject(path: workspace); registeredProject.id = project
        var thread = CodingThread(project: registeredProject, model: "offline-metadata-only")
        thread.provider = .codex
        let profile = try AgentSessionProfile(configuration: .init(thread: thread), transcriptsRoot: root.appendingPathComponent("PrivateCLI").path)
        let fixtureRoot = root, frozenScanID = scanID
        reviews = (0..<2).map { index in
            let nativeID = "synthetic-session-\(index)", digest = String(repeating: index == 0 ? "a" : "b", count: 64)
            let source = AgentSessionImportSource(provider: .codex, providerInstanceID: profile.id, providerSessionID: nativeID,
                filePath: fixtureRoot.appendingPathComponent("not-read-session-\(index).jsonl").path, size: 123, device: 1, inode: UInt64(index + 2),
                modificationNanoseconds: 100, birthNanoseconds: 100, digest: digest)
            let transcript = AgentSessionTranscript(source: .codex, providerInstanceID: profile.id, providerSessionID: nativeID,
                workspacePath: workspace, title: "Saved history \(index)", model: "offline-metadata-only", createdAt: Date(), updatedAt: Date(),
                messages: [.init(role: .user, text: "Immutable saved source", createdAt: Date())], omittedMessageCount: 0)
            return AgentSessionImportReview(id: UUID(), digest: digest, scanID: frozenScanID, projectID: project, expectedWorkspaceRoot: workspace,
                workspaceIdentity: .init(device: 1, inode: 2), profile: profile, transcript: transcript, sources: [source])
        }
    }
    var transport: AgentSessionImportTransport {
        .init(scan: {
            self.scanCalls += 1
            return .init(id: self.scanID, candidates: [self.candidate], scannedAt: Date(), truncated: false)
        }, prepare: { scan, candidate, cursor in
            self.prepareCalls += 1
            guard scan == self.scanID, candidate.id == self.candidate.id else { throw AgentSessionImportError.invalidRequest }
            if let gate = self.prepareGate { await gate.pause(); self.prepareGate = nil; try Task.checkCancellation() }
            if cursor == nil {
                return .init(scanID: scan, reviews: [self.reviews[0]], alreadyImported: [self.reviews[0].sources[0], self.reviews[1].sources[0]],
                    duplicates: [self.reviews[1].sources[0]], skippedCount: 3, nextCursor: self.cursor, complete: false)
            }
            guard cursor == self.cursor else { throw AgentSessionImportError.staleScan }
            return .init(scanID: scan, reviews: [self.reviews[1]], alreadyImported: [], duplicates: [], skippedCount: 0, nextCursor: nil, complete: true)
        }, accept: { reviewID, digest, commandID in
            self.commands.append((reviewID, digest, commandID))
            if let gate = self.acceptGate { await gate.pause(); self.acceptGate = nil }
            self.acceptedWasCancelled = Task.isCancelled
            guard self.reviews.contains(where: { $0.id == reviewID && $0.digest == digest }) else { throw AgentSessionImportError.changed }
            let receipt = WorkspaceCommandReceipt(commandID: commandID, sequence: Int64(self.commands.count), eventCount: 1, acceptedAt: Date(), rejection: nil)
            self.receipts[commandID] = receipt
            if self.loseReply { self.loseReply = false; throw AgentSessionImportError.unavailable }
            return receipt
        }, receipt: { reviewID, digest, commandID in
            guard self.commands.contains(where: { $0.0 == reviewID && $0.1 == digest && $0.2 == commandID }) else { throw AgentSessionImportError.changed }
            return self.hideReceipt ? nil : self.receipts[commandID]
        }, release: { self.releases.append($0) })
    }
    func store() async -> AgentSessionImportStore {
        let store = AgentSessionImportStore(root: root.appendingPathComponent("ImportState")); store.bind(transport); await store.open(); return store
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func agentSessionImportPanelScansOnlyExplicitlyAndSeriallyImportsBoundedPagesWithExactProgressAndOriginalIDs() async throws {
    let f = try AgentImportStoreFixture(); defer { f.cleanup() }
    let store = await f.store()
    #expect(f.scanCalls == 0 && f.prepareCalls == 0 && f.commands.isEmpty)
    await store.scan()?.value
    #expect(f.scanCalls == 1 && store.selectedCandidate?.id == f.candidate.id)
    await store.importSelected()?.value
    #expect(f.prepareCalls == 2 && f.commands.count == 2)
    #expect(f.commands[0].0 == f.reviews[0].id && f.commands[1].0 == f.reviews[1].id && f.commands[0].2 != f.commands[1].2)
    #expect(store.progress == .init(imported: 2, alreadyImported: 2, duplicates: 1, skipped: 3, failed: 0))
    #expect(store.pending == nil && !store.isBusy)
    // Only the compact receipt/count manifest is read on the next panel open.
    await store.shutdown()
    let reopened = await f.store()
    #expect(f.scanCalls == 1 && f.commands.count == 2 && reopened.progress.imported == 2 && reopened.scanResult == nil)
    await reopened.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func agentSessionImportLostAcceptancePersistsCompactOriginalReceiptAcrossRestartAndNeverReplaysSourceOrImport() async throws {
    let f = try AgentImportStoreFixture(); defer { f.cleanup() }
    let store = await f.store(); await store.scan()?.value; f.loseReply = true
    await store.importSelected()?.value
    let pending = try #require(store.pending), first = try #require(f.commands.first)
    #expect(pending.reviewID == first.0 && pending.digest == first.1 && pending.commandID == first.2)
    #expect(store.progress.imported == 0 && f.prepareCalls == 1 && f.commands.count == 1)
    await store.shutdown()
    let restarted = await f.store()
    #expect(restarted.pending?.commandID == pending.commandID && f.scanCalls == 1 && f.prepareCalls == 1 && f.commands.count == 1)
    f.hideReceipt = true; await restarted.checkResult()?.value
    #expect(restarted.pending?.commandID == pending.commandID && restarted.progress.imported == 0)
    f.hideReceipt = false; await restarted.checkResult()?.value
    #expect(restarted.pending == nil && restarted.progress.imported == 1 && f.commands.count == 1 && f.prepareCalls == 1)
    await restarted.checkResult()?.value
    #expect(restarted.progress.imported == 1 && f.commands.count == 1)
    let manifest = try Data(contentsOf: f.root.appendingPathComponent("ImportState/session-import.json"))
    #expect(!String(decoding: manifest, as: UTF8.self).contains("Immutable saved source"))
    await restarted.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["prepare", "accept"])
func agentSessionImportPanelClosingCancelsOwnedReadsButJoinsAcceptedImportWithoutStartingTheNextPage(boundary: String) async throws {
    let f = try AgentImportStoreFixture(); defer { f.cleanup() }
    let store = await f.store(); await store.scan()?.value
    let gate = AgentImportStoreGate()
    if boundary == "prepare" { f.prepareGate = gate } else { f.acceptGate = gate }
    let importing = try #require(store.importSelected()); await gate.wait()
    store.requestPause(); await Task.yield()
    #expect(f.prepareCalls == 1)
    await gate.release(); await importing.value; await store.shutdown()
    #expect(f.prepareCalls == 1 && !store.scanAvailable && !store.isBusy)
    if boundary == "prepare" { #expect(f.commands.isEmpty && store.progress.imported == 0) }
    else { #expect(!f.acceptedWasCancelled && f.commands.count == 1 && store.progress.imported == 1 && store.pending == nil) }
    #expect(f.releases.contains(f.scanID))
}
