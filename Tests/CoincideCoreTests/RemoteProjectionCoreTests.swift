import Foundation
import Testing
@testable import CoincideCore

private struct RemoteProjectionCoreFixture {
    let root: URL
    let engine: WorkspaceEngine
    let service: RemoteProjectionService
    let environmentID: UUID
    let threadID: UUID
    let giant: String
    let messageIDs: [String]
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("coincide-projection-core-\(UUID().uuidString)")
        var owned: WorkspaceEngine?
        do {
            let workspace = root.appendingPathComponent("Workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let project = WorkspaceProject(path: workspace.path)
            var thread = CodingThread(project: project); thread.title = "Projection fixture"; thread.checkpointPolicy = .disabled
            let giant = String(repeating: "\"\\\n🌍\0", count: 30_000)
            thread.messages = (0..<600).map { ChatMessage(id: "message-\($0)", role: .assistant,
                text: $0 == 0 ? giant : String(repeating: "\($0)-body ", count: 350)) }
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            let database = root.appendingPathComponent("workspace.sqlite")
            try await WorkspaceDatabase(url: database).save(snapshot, event: "fixture")
            let engine = try WorkspaceEngine(url: database, providerFactory: { _ in throw CoincideError("Projection reads must not create a provider") }, identityResolver: { _ in nil })
            owned = engine; _ = try await engine.load()
            let environmentID = UUID(), service = RemoteProjectionService(environmentID: environmentID, engine: engine)
            return .init(root: root, engine: engine, service: service, environmentID: environmentID, threadID: thread.id,
                giant: giant, messageIDs: thread.messages.map(\.id))
        } catch { await owned?.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func binding(_ scope: RemoteProjectionScope) async throws -> RemoteProjectionBinding {
        try await service.open(.init(environmentID: environmentID, scope: scope))
    }
    func close() async { await service.close(); await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1)))
func remoteProjectionAllMessageRowsAndGiantEscapedUTF8ContentRemainBoundedAndExact() async throws {
    let f = try await RemoteProjectionCoreFixture.make()
    do {
        let binding = try await f.binding(.thread(f.threadID))
        var cursor: UUID?, ids: [String] = [], reference: RemoteProjectionContentReference?
        repeat {
            let request = RemoteProjectionMessagesRequest(binding: binding, threadID: f.threadID, newestFirst: false, cursor: cursor)
            let page = try await f.service.messages(request)
            #expect(try await f.service.messages(request) == page)
            #expect(try RemoteProjectionProtocol.payload(page).count <= RemoteProjectionProtocol.maximumResultBytes)
            #expect(page.offset == ids.count && page.totalCount == f.messageIDs.count)
            #expect(page.complete == (page.nextCursor == nil))
            if let first = page.items.first(where: { $0.id == "message-0" }) {
                #expect(!first.text.complete); reference = first.text.content
            }
            ids += page.items.map(\.id); cursor = page.nextCursor
        } while cursor != nil
        #expect(ids == f.messageIDs)
        let content = try #require(reference)
        var bytes = Data(), next: UUID?
        repeat {
            let request = RemoteProjectionContentRequest(binding: binding, reference: content, offset: bytes.count, cursor: next)
            let page = try await f.service.content(request)
            #expect(try await f.service.content(request) == page)
            #expect(try RemoteProjectionProtocol.payload(page).count <= RemoteProjectionProtocol.maximumResultBytes)
            #expect(page.offset == bytes.count && page.reference == content)
            bytes.append(page.data); next = page.nextCursor
        } while next != nil
        #expect(bytes == Data(f.giant.utf8) && bytes.count == content.totalBytes)
        #expect(RemoteProjectionProtocol.digest(bytes) == content.digest)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteProjectionHostRefusesCrossQueryCursorForeignDocumentsOffsetsAndReleasedViews() async throws {
    let f = try await RemoteProjectionCoreFixture.make()
    do {
        let binding = try await f.binding(.thread(f.threadID))
        let page = try await f.service.messages(.init(binding: binding, threadID: f.threadID))
        let cursor = try #require(page.nextCursor)
        await #expect(throws: RemoteProjectionFailure(.staleCursor)) {
            try await f.service.messages(.init(binding: binding, threadID: f.threadID, newestFirst: false, cursor: cursor))
        }
        await #expect(throws: RemoteProjectionFailure(.staleCursor)) { try await f.service.runs(.init(binding: binding, threadID: f.threadID, cursor: cursor)) }
        await #expect(throws: RemoteProjectionFailure(.invalidRequest)) { try await f.service.messages(.init(binding: binding, threadID: UUID(), cursor: cursor)) }
        let detail = try await f.service.thread(.init(binding: binding, threadID: f.threadID)), content = detail.thread.configuration
        await #expect(throws: RemoteProjectionFailure(.staleCursor)) { try await f.service.content(.init(binding: binding, reference: content, offset: 1)) }
        let forged = RemoteProjectionContentReference(id: content.id, kind: content.kind, totalBytes: content.totalBytes, digest: String(repeating: "0", count: 64))
        await #expect(throws: RemoteProjectionFailure(.notFound)) { try await f.service.content(.init(binding: binding, reference: forged)) }
        #expect(try await f.service.release(.init(binding: binding)).released)
        #expect(try await !f.service.release(.init(binding: binding)).released)
        await #expect(throws: RemoteProjectionFailure(.staleView)) { try await f.service.messages(.init(binding: binding, threadID: f.threadID)) }
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteProjectionPinnedThreadSurvivesNewControlRevisionUntilExplicitEightViewEviction() async throws {
    let f = try await RemoteProjectionCoreFixture.make()
    do {
        let old = try await f.binding(.thread(f.threadID))
        let first = try await f.service.messages(.init(binding: old, threadID: f.threadID))
        _ = try await f.engine.dispatch(.editThread(f.threadID, .title("New control title")))
        let control = try await f.binding(.control(f.threadID))
        #expect(control.sequence > old.sequence)
        #expect(try await f.service.thread(.init(binding: control, threadID: f.threadID)).thread.summary.title.preview == "New control title")
        #expect(try await f.service.thread(.init(binding: old, threadID: f.threadID)).thread.summary.title.preview == "Projection fixture")
        #expect(try await f.service.messages(.init(binding: old, threadID: f.threadID)) == first)
        await #expect(throws: RemoteProjectionFailure(.invalidRequest)) { try await f.service.messages(.init(binding: control, threadID: f.threadID)) }
        for _ in 0..<8 { _ = try await f.binding(.control(f.threadID)) }
        await #expect(throws: RemoteProjectionFailure(.staleView)) { try await f.service.thread(.init(binding: old, threadID: f.threadID)) }
        let foreign = RemoteProjectionBinding(environmentID: old.environmentID, hostID: UUID(), viewID: old.viewID,
            sequence: old.sequence, fingerprint: old.fingerprint, scope: old.scope)
        await #expect(throws: RemoteProjectionFailure(.staleView)) { try await f.service.release(.init(binding: foreign)) }
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteProjectionImportedCloneAndHistoricalWorkspaceRunKeepOnlyBoundedDisplayAuthority() async throws {
    let f = try await RemoteProjectionCoreFixture.make()
    do {
        var update = await f.engine.current(), snapshot = update.snapshot
        let id = UUID(), destination = snapshot.projects[0].path
        let plan = GitClonePlan(id: id, source: "https://fixture.invalid/unread-private-source.git", destinationPath: destination,
            stagingPath: URL(fileURLWithPath: destination).deletingLastPathComponent().appendingPathComponent(".coincide-clone-" + id.uuidString.lowercased()).path)
        var clone = ProjectCloneState(plan: plan); clone.phase = .completed
        snapshot.projects[0].clone = clone
        let oldPath = f.root.appendingPathComponent("PreviousWorkspace").path
        var configuration = ProviderConfiguration(thread: snapshot.threads[0]); configuration.workspacePath = oldPath
        var record = ThreadRunRecord(run: .init(id: UUID(), configuration: configuration, startedAt: Date()), origin: .legacy)
        record.status = .completed; record.endReason = .providerCompleted; record.endedAt = Date()
        func savedAttempt() throws -> ThreadRunCheckpointAttempt {
            let id = UUID(), plan = try CheckpointRestoreFixture.plan(id: id, path: oldPath)
            var result = ThreadRunCheckpointAttempt(id: id, workspacePath: oldPath, phase: .ready)
            result.plan = plan; result.receipt = try .init(plan: plan, commit: String(repeating: "c", count: 40), tree: String(repeating: "d", count: 40))
            return result
        }
        record.checkpoints = try .init(baseline: savedAttempt(), providerReleased: true)
        record.checkpoints?.postRun = try savedAttempt()
        snapshot.threads[0].runHistory = [record]
        try WorkspaceJournal.validate(snapshot)
        update = .init(snapshot: snapshot, sequence: update.sequence)
        let source = try RemoteProjectionProjector.build(update, scope: .thread(f.threadID), reserve: { bytes in
            guard bytes <= RemoteProjectionProtocol.maximumCacheBytes else { throw RemoteProjectionFailure(.limitExceeded) }
        })
        let projected = try #require(source.operations.first { $0.kind == .projectClone })
        #expect(projected.id == id && projected.projectID == snapshot.projects[0].id && projected.phase == "completed")
        #expect(projected.updatedAt == clone.updatedAt && projected.workspacePaths == [destination])
        #expect(projected.actions.isEmpty)
        #expect(!String(decoding: try RemoteProjectionProtocol.payload(projected), as: UTF8.self).contains("unread-private-source"))
        let oldRun = try #require(source.runs.first)
        #expect(oldRun.workspacePath == oldPath && oldRun.checkpointAttempts.allSatisfy { $0.workspacePath == oldPath })
        #expect(!oldRun.checkpointDiff.allowed && oldRun.checkpointDiff.reason == "This comparison belongs to another workspace.")
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteProjectionLargeCheckpointPreviewKeepsCurrentDiffPairAndAllHistoricalAttempts() async throws {
    let f = try await RemoteProjectionCoreFixture.make()
    do {
        let update = await f.engine.current()
        var snapshot = update.snapshot
        let configuration = ProviderConfiguration(thread: snapshot.threads[0])
        var record = ThreadRunRecord(run: .init(id: UUID(), configuration: configuration, startedAt: Date()), origin: .legacy)
        record.status = .completed; record.endReason = .providerCompleted; record.endedAt = Date()
        func savedAttempt(later: Bool) throws -> ThreadRunCheckpointAttempt {
            let id = UUID(), plan = try CheckpointRestoreFixture.plan(id: id, path: configuration.workspacePath)
            var result = ThreadRunCheckpointAttempt(id: id, workspacePath: configuration.workspacePath, phase: .ready, isLaterObservation: later)
            result.plan = plan
            result.receipt = try .init(plan: plan, commit: String(repeating: "c", count: 40), tree: String(repeating: "d", count: 40))
            return result
        }
        let baseline = try savedAttempt(later: false), current = try savedAttempt(later: true)
        let previous = (0..<200).map { _ in
            var attempt = ThreadRunCheckpointAttempt(workspacePath: configuration.workspacePath, phase: .failed, isLaterObservation: true)
            attempt.error = ThreadRunCheckpointAttempt.failureMessage
            return attempt
        }
        record.checkpoints = .init(baseline: baseline, providerReleased: true)
        record.checkpoints?.previousPostRunAttempts = previous
        record.checkpoints?.postRun = current
        snapshot.threads[0].runHistory = [record]
        try WorkspaceJournal.validate(snapshot)
        let source = try RemoteProjectionProjector.build(.init(snapshot: snapshot, sequence: update.sequence), scope: .thread(f.threadID), reserve: { bytes in
            guard bytes <= RemoteProjectionProtocol.maximumCacheBytes else { throw RemoteProjectionFailure(.limitExceeded) }
        })
        let projected = try #require(source.runs.first)
        #expect(!projected.checkpointAttemptsComplete && projected.checkpointAttemptCount == 202)
        #expect(projected.checkpointAttempts.map(\.id) == [baseline.id, current.id])
        #expect(projected.checkpointAttempts.map(\.stage) == [.baseline, .postRun])
        #expect(projected.checkpointAttempts.allSatisfy { $0.phase == .ready && $0.workspacePath == configuration.workspacePath })
        #expect(projected.checkpointDiff.allowed && projected.checkpointDiff.reason == nil)
        let reference = try #require(projected.checkpointAttemptsContent)
        let bytes = try #require(source.contents[reference.id])
        #expect(reference.kind == .checkpointAttempts && bytes.count > 32_768)
        #expect(bytes.count == reference.totalBytes && RemoteProjectionProtocol.digest(bytes) == reference.digest)
        let all = try JSONDecoder().decode([RemoteCheckpointAttemptSummary].self, from: bytes)
        #expect(all.map(\.id) == [baseline.id] + previous.map(\.id) + [current.id])
        #expect(all.dropFirst().dropLast().allSatisfy { $0.phase == .failed })
        #expect(try RemoteProjectionProtocol.payload(projected).count <= RemoteProjectionProtocol.maximumResultBytes)
    } catch { await f.close(); throw error }
    await f.close()
}
