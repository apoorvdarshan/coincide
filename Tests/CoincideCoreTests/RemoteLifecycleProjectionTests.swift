import Foundation
import Testing
@testable import CoincideCore

@Test func remoteLifecycleProjectionOptionalMetadataAndNegotiationKeepLegacyCodecsCompatible() throws {
    let environmentID = UUID(), request = RemoteProjectionOpenRequest(environmentID: environmentID)
    let legacyBytes = try RemoteProjectionProtocol.payload(request)
    #expect(!String(decoding: legacyBytes, as: UTF8.self).contains("clientSupportsLifecycleControls"))
    #expect(try JSONDecoder().decode(RemoteProjectionOpenRequest.self, from: legacyBytes).clientSupportsLifecycleControls == nil)
    let negotiated = RemoteProjectionOpenRequest(environmentID: environmentID, clientSupportsLifecycleControls: true)
    #expect(try JSONDecoder().decode(RemoteProjectionOpenRequest.self, from: RemoteProjectionProtocol.payload(negotiated)).clientSupportsLifecycleControls == true)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let metadata = ThreadWorkspaceLifecycle(settledOverride: .active, unsettledAt: now,
        snoozedUntil: now.addingTimeInterval(3_600), snoozedAt: now, lastSnoozeWakeAt: now, autoSettleDisabledAt: now)
    let summary = RemoteThreadSummary(id: UUID(), projectID: UUID(), title: .init(preview: "Conversation", complete: true),
        workspacePath: "/tmp/coincide-lifecycle-codec", provider: .codex, providerName: "Codex", model: .init(preview: "model", complete: true),
        permission: .supervised, state: .idle, isPinned: false, isArchived: false, createdAt: now, updatedAt: now,
        messageCount: 0, runCount: 0, queueCount: 0, workspaceLifecycle: metadata, settlementPhase: .resuming)
    let bytes = try RemoteProjectionProtocol.payload(summary)
    #expect(try JSONDecoder().decode(RemoteThreadSummary.self, from: bytes) == summary)
    var old = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    old.removeValue(forKey: "workspaceLifecycle"); old.removeValue(forKey: "settlementPhase")
    let decoded = try JSONDecoder().decode(RemoteThreadSummary.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(decoded.workspaceLifecycle == nil && decoded.settlementPhase == nil)
    #expect(decoded.id == summary.id && decoded.title == summary.title && decoded.workspacePath == summary.workspacePath)
}

private struct LifecycleProjectionFixture {
    let root: URL
    let engine: WorkspaceEngine
    let service: RemoteProjectionService
    let environmentID: UUID
    let snapshot: WorkspaceSnapshot
    var threadID: UUID { snapshot.threads[0].id }
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("coincide-lifecycle-projection-\(UUID())")
        var owned: WorkspaceEngine?
        do {
            let workspace = root.appendingPathComponent("Workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let project = WorkspaceProject(path: workspace.path), now = Date()
            let lifecycle = ThreadWorkspaceLifecycle(snoozedUntil: now.addingTimeInterval(3_600), snoozedAt: now,
                lastSnoozeWakeAt: now.addingTimeInterval(-3_600), autoSettleDisabledAt: now)
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]
            for index in 0..<150 {
                var thread = CodingThread(project: project, model: String(repeating: "m", count: 1_000))
                thread.title = String(repeating: "n", count: 1_000) + String(index); thread.checkpointPolicy = .disabled
                thread.workspaceLifecycle = lifecycle; thread.draft = "Keep exact unsent draft e\u{301}"
                if index > 0 { thread.settlement = .init(settledAt: now) }
                if index == 0 { thread.messages = (0..<600).map { .init(id: "lifecycle-message-\($0)", role: .assistant, text: "Unchanged pinned body \($0)") } }
                snapshot.threads.append(thread)
            }
            let database = root.appendingPathComponent("workspace.sqlite")
            try await WorkspaceDatabase(url: database).save(snapshot, event: "private-lifecycle-projection")
            let engine = try WorkspaceEngine(url: database, providerFactory: { _ in throw CoincideError("Lifecycle projection cannot create a provider") }, identityResolver: { _ in nil })
            owned = engine; _ = try await engine.load()
            let id = UUID(), service = RemoteProjectionService(environmentID: id, engine: engine)
            return .init(root: root, engine: engine, service: service, environmentID: id, snapshot: snapshot)
        } catch { await owned?.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func open(_ scope: RemoteProjectionScope) async throws -> RemoteProjectionBinding {
        try await service.open(.init(environmentID: environmentID, scope: scope))
    }
    func close() async { await service.close(); await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1)))
func remoteLifecycleProjectionCatalogPreservesEveryAttentionFieldInsideEncodedPageBudget() async throws {
    let f = try await LifecycleProjectionFixture.make()
    do {
        let binding = try await f.open(.catalog)
        var cursor: UUID?, rows: [RemoteThreadSummary] = [], pages = 0
        repeat {
            let request = RemoteProjectionCatalogRequest(binding: binding, query: .threads(projectID: nil, includeArchived: true), cursor: cursor)
            guard case .threads(let page) = try await f.service.catalog(request) else { Issue.record("Expected bounded conversation catalog"); break }
            #expect(try RemoteProjectionProtocol.payload(RemoteProjectionCatalogResult.threads(page)).count <= RemoteProjectionProtocol.maximumResultBytes)
            #expect(page.offset == rows.count && page.totalCount == 150)
            rows += page.items; cursor = page.nextCursor; pages += 1
        } while cursor != nil
        #expect(pages > 1 && rows.map(\.id) == f.snapshot.threads.map(\.id))
        for (row, original) in zip(rows, f.snapshot.threads) {
            #expect(row.workspaceLifecycle == original.workspaceLifecycle && row.settlementPhase == original.settlement?.phase)
            let wire = String(decoding: try RemoteProjectionProtocol.payload(row), as: UTF8.self)
            #expect(!wire.contains("sourceFingerprint") && !wire.contains("Incarnation") && !wire.contains("gitDirectoryIdentity"))
        }
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteLifecycleProjectionLatestControlChangesWhileOlderTranscriptAndItsCursorStayPinned() async throws {
    let f = try await LifecycleProjectionFixture.make()
    do {
        let old = try await f.open(.thread(f.threadID))
        let first = try await f.service.messages(.init(binding: old, threadID: f.threadID))
        let cursor = try #require(first.nextCursor)
        let original = try await f.service.thread(.init(binding: old, threadID: f.threadID)).thread
        #expect(original.workspaceLifecycle?.snoozedUntil != nil && original.settlementPhase == nil)
        let woke = try await f.engine.dispatch(.workspaceLifecycle(.wake(threadID: f.threadID)))
        #expect(woke.rejection == nil)
        let awake = try await f.open(.control(f.threadID))
        let fresh = try await f.service.thread(.init(binding: awake, threadID: f.threadID)).thread
        #expect(awake.sequence > old.sequence && fresh.workspaceLifecycle?.snoozedUntil == nil)
        let settled = try await f.engine.settleThread(threadID: f.threadID, expectedWorkspacePath: f.snapshot.projects[0].path, reviewScript: false)
        #expect(settled.rejection == nil)
        let latest = try await f.open(.control(f.threadID))
        let current = try await f.service.thread(.init(binding: latest, threadID: f.threadID)).thread
        #expect(current.settlementPhase == .settled && current.settlementID == settled.commandID)
        #expect(try await f.service.thread(.init(binding: old, threadID: f.threadID)).thread == original)
        #expect(try await f.service.messages(.init(binding: old, threadID: f.threadID)) == first)
        let second = try await f.service.messages(.init(binding: old, threadID: f.threadID, cursor: cursor))
        #expect(second.offset == first.items.count && second.totalCount == 600)
        #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
        let snapshot = await f.engine.current().snapshot
        #expect(snapshot.threads[0].messages == f.snapshot.threads[0].messages && snapshot.threads[0].draft == f.snapshot.threads[0].draft)
    } catch { await f.close(); throw error }
    await f.close()
}
