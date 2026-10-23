import Foundation
import Testing
@testable import CoincideCore

private final class AgentSessionImportLaunchProbe: @unchecked Sendable {
    private let lock = NSLock(); private var launches = 0
    var count: Int { lock.withLock { launches } }
    func make() throws -> any ProviderSession { lock.withLock { launches += 1 }; throw CoincideError("Filesystem session import must not launch a provider") }
}
private struct AgentSessionImportEngineFixture {
    let files: AgentSessionImportFixture, project: WorkspaceProject, database: URL, engine: WorkspaceEngine
    let probe: AgentSessionImportLaunchProbe
    static func make(_ sources: [AgentSessionSource] = [.codex]) async throws -> Self {
        let files = try AgentSessionImportFixture.make(), host = files.root.appendingPathComponent("Host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for source in sources { let file = try files.install(source); try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: file.path) }
        let database = host.appendingPathComponent("workspace.sqlite"), probe = AgentSessionImportLaunchProbe()
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in try probe.make() }, identityResolver: { _ in nil })
        do {
            _ = try await engine.load(); let project = WorkspaceProject(path: files.workspace.path)
            _ = try await engine.dispatch(.addProject(project))
            return .init(files: files, project: project, database: database, engine: engine, probe: probe)
        } catch { await engine.shutdown(); files.cleanup(); throw error }
    }
    func page() async throws -> (AgentSessionScanResult, AgentSessionImportPage) {
        let scan = try await engine.scanAgentSessions(profiles: files.profiles)
        return (scan, try await engine.prepareAgentSessionImport(scanID: scan.id, projectID: project.id, expectedWorkspaceRoot: project.path))
    }
    func reopen() throws -> WorkspaceEngine { try .init(url: database, providerFactory: { _ in try probe.make() }, identityResolver: { _ in nil }) }
    func close() async { await engine.shutdown(); files.cleanup() }
}

@Test(.timeLimit(.minutes(1)), arguments: AgentSessionSource.allCases)
func agentSessionEngineOriginalCompactReceiptSurvivesReleaseRestartAndNewerUserEditsWithoutProviderLaunch(source: AgentSessionSource) async throws {
    let f = try await AgentSessionImportEngineFixture.make([source])
    do {
        let (scan, page) = try await f.page(), review = try #require(page.reviews.first), command = UUID()
        let native = try Data(contentsOf: URL(fileURLWithPath: review.sources[0].filePath))
        let receipt = try await f.engine.acceptAgentSessionImport(reviewID: review.id, digest: review.digest, commandID: command)
        let imported = await f.engine.current(), thread = try #require(imported.snapshot.threads.first)
        #expect(thread.messages.map(\.text) == review.transcript.messages.map(\.text) && thread.isSettled)
        #expect(f.probe.count == 0 && imported.snapshot.agentSessionImports?.first?.modified == false)
        await f.engine.releaseAgentSessionScan(scan.id)
        #expect(try await f.engine.acceptAgentSessionImport(reviewID: review.id, digest: review.digest, commandID: command) == receipt)
        _ = try await f.engine.dispatch(.editThread(thread.id, .title("User-owned title Ω")))
        #expect(await f.engine.current().snapshot.agentSessionImports?.first?.modified == true)
        await #expect(throws: WorkspaceCommitError.commandIDCollision) {
            _ = try await f.engine.agentSessionImportReceipt(reviewID: review.id, digest: String(repeating: "0", count: 64), commandID: command)
        }
        await f.engine.shutdown()
        let reopened = try f.reopen()
        do {
            _ = try await reopened.load()
            let before = await reopened.current()
            #expect(try await reopened.agentSessionImportReceipt(reviewID: review.id, digest: review.digest, commandID: command) == receipt)
            #expect(try await reopened.acceptAgentSessionImport(reviewID: review.id, digest: review.digest, commandID: command) == receipt)
            let after = await reopened.current()
            #expect(before.snapshot == after.snapshot && before.sequence == after.sequence)
            #expect(after.snapshot.threads.first?.title == "User-owned title Ω" && f.probe.count == 0)
            #expect(try Data(contentsOf: URL(fileURLWithPath: review.sources[0].filePath)) == native)
            let database = try WorkspaceDatabase(url: f.database)
            #expect(try await database.effects(commandID: command).isEmpty)
            let journal = try await database.journal(limit: 1_000)
            #expect(journal.contains { if case .agentSessionImportsReplaced = $0.event { true } else { false } })
        } catch { await reopened.shutdown(); throw error }; await reopened.shutdown()
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)))
func agentSessionEngineAbsentReceiptFencePreventsLateOriginalImportAndDoesNotReplayNativeInput() async throws {
    let f = try await AgentSessionImportEngineFixture.make()
    do {
        let (_, page) = try await f.page(), review = try #require(page.reviews.first), command = UUID()
        #expect(try await f.engine.agentSessionImportReceipt(reviewID: review.id, digest: review.digest, commandID: command) == nil)
        let fence = try #require(try await f.engine.agentSessionImportReceipt(reviewID: review.id, digest: review.digest, commandID: command, resolvingAbsent: true))
        #expect(fence.rejection != nil)
        #expect(try await f.engine.acceptAgentSessionImport(reviewID: review.id, digest: review.digest, commandID: command) == fence)
        #expect(await f.engine.current().snapshot.threads.isEmpty)
        #expect(f.probe.count == 0)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["source-file", "physical-workspace", "released-scan"])
func agentSessionEngineRefusesStaleImportLeaseWithoutChangingNativeHistoryOrPoisoningEngine(change: String) async throws {
    let f = try await AgentSessionImportEngineFixture.make()
    do {
        let (scan, page) = try await f.page(), review = try #require(page.reviews.first), command = UUID()
        if change == "source-file" {
            let file = URL(fileURLWithPath: review.sources[0].filePath)
            var bytes = try Data(contentsOf: file); bytes.append(contentsOf: "\n".utf8); try bytes.write(to: file)
        } else if change == "physical-workspace" {
            try FileManager.default.moveItem(at: f.files.workspace, to: f.files.root.appendingPathComponent("PreviousWorkspace"))
            try FileManager.default.createDirectory(at: f.files.workspace, withIntermediateDirectories: true)
        } else { await f.engine.releaseAgentSessionScan(scan.id) }
        await #expect(throws: AgentSessionImportError.self) { _ = try await f.engine.acceptAgentSessionImport(reviewID: review.id, digest: review.digest, commandID: command) }
        let fence = try #require(try await f.engine.agentSessionImportReceipt(reviewID: review.id, digest: review.digest, commandID: command, resolvingAbsent: true))
        #expect(fence.rejection != nil)
        _ = try await f.engine.dispatch(.renameProject(projectID: f.project.id, title: "Engine remains usable"))
        let current = await f.engine.current()
        #expect(current.error == nil && current.snapshot.threads.isEmpty && f.probe.count == 0)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)))
func agentSessionEnginePagedImportPinsCompletedSourceSetAndRetainsBothNativeProviderProfiles() async throws {
    let f = try await AgentSessionImportEngineFixture.make([.codex, .claudeAgent])
    do {
        let (scan, first) = try await f.page(), cursor = try #require(first.nextCursor), a = try #require(first.reviews.first)
        _ = try await f.engine.acceptAgentSessionImport(reviewID: a.id, digest: a.digest)
        let second = try await f.engine.prepareAgentSessionImport(scanID: scan.id, projectID: f.project.id, expectedWorkspaceRoot: f.project.path, cursor: cursor)
        let b = try #require(second.reviews.first)
        _ = try await f.engine.acceptAgentSessionImport(reviewID: b.id, digest: b.digest)
        let current = await f.engine.current()
        #expect(second.complete && current.snapshot.threads.count == 2 && current.snapshot.agentSessionImports?.count == 2)
        #expect(Set(current.snapshot.threads.map(\.provider)) == Set([.codex, .claude]) && f.probe.count == 0)
        let rescanned = try await f.engine.scanAgentSessions(profiles: f.files.profiles)
        let unchanged = try await f.engine.prepareAgentSessionImport(scanID: rescanned.id, projectID: f.project.id, expectedWorkspaceRoot: f.project.path)
        #expect(unchanged.reviews.isEmpty && unchanged.alreadyImported.count == 2 && unchanged.complete)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)))
func agentSessionEngineUpdatedNativeUnicodeBytesSurviveJournalRebuildWithExactImportFingerprint() async throws {
    let f = try await AgentSessionImportEngineFixture.make()
    do {
        let path = f.files.codex.appendingPathComponent("sessions/2026/10/23/rollout-fixture.jsonl")
        let original = try String(contentsOf: path, encoding: .utf8)
        let decomposed = "Cafe\u{301}", composed = "Caf\u{e9}"
        try Data(original.replacingOccurrences(of: "Inspect the captured project", with: decomposed).utf8).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: path.path)
        let (_, first) = try await f.page(), a = try #require(first.reviews.first)
        _ = try await f.engine.acceptAgentSessionImport(reviewID: a.id, digest: a.digest)
        let old = try #require(await f.engine.current().snapshot.threads.first)
        #expect(old.messages[0].text.utf8.elementsEqual(decomposed.utf8))
        try Data(original.replacingOccurrences(of: "Inspect the captured project", with: composed).utf8).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-15)], ofItemAtPath: path.path)
        let (_, second) = try await f.page(), b = try #require(second.reviews.first)
        _ = try await f.engine.acceptAgentSessionImport(reviewID: b.id, digest: b.digest)
        let update = await f.engine.current(), current = try #require(update.snapshot.threads.first)
        #expect(current.messages[0].text == old.messages[0].text)
        #expect(current.messages[0].text.utf8.elementsEqual(composed.utf8))
        let database = try WorkspaceDatabase(url: f.database), rebuilt = try await database.rebuildProjection()
        let replayed = try #require(rebuilt.snapshot.threads.first)
        #expect(replayed.messages[0].text.utf8.elementsEqual(composed.utf8))
        #expect(try AgentSessionImportProtocol.digest(replayed) == update.snapshot.agentSessionImports?.first?.originalContentFingerprint)
        #expect(rebuilt.snapshot.agentSessionImports?.first?.modified == false && f.probe.count == 0)
    } catch { await f.close(); throw error }; await f.close()
}
