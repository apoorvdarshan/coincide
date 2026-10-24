import Foundation
import Testing
@testable import CoincideCore

private let usageProjectionNow = Date(timeIntervalSince1970: 1_700_000_000)
private func usageProjectionSnapshot(path: String, large: Bool = false, reported: Bool = true) throws -> WorkspaceSnapshot {
    let project = WorkspaceProject(path: path)
    var thread = CodingThread(project: project, model: "captured-past-model"); thread.provider = .claude
    thread.checkpointPolicy = .disabled
    thread.workspaceLifecycle = .init(snoozedUntil: usageProjectionNow.addingTimeInterval(3_600), snoozedAt: usageProjectionNow)
    let runID = UUID()
    var record = ThreadRunRecord(run: .init(id: runID, configuration: .init(thread: thread), startedAt: usageProjectionNow), origin: .legacy)
    record.status = .completed; record.endedAt = usageProjectionNow; record.endReason = .providerCompleted
    if reported {
        let models: [ClaudeModelUsage]
        if large {
            // Each public model string stays within512 UTF8 bytes. Escaping
            // makes the full, valid typed report exceed one projection page.
            models = try (0..<128).map { index in
                try .init(model: "model-\(index)-" + String(repeating: "\"\\", count: 245), inputTokens: index + 1,
                    outputTokens: 10, estimatedCostUSD: 0.0001,
                    canonicalModel: String(repeating: "\"\\", count: 250), provider: String(repeating: "\"\\", count: 250))
            }
        } else { models = [try .init(model: "native-model", inputTokens: 400, outputTokens: 75, estimatedCostUSD: 0.12)] }
        let session = try ClaudeSessionUsage(estimatedCostUSD: 0.12, models: models, modelUsageAvailable: true, observedAt: usageProjectionNow)
        record.providerUsage = .claude(try .init(runID: runID, revision: 3,
            turn: .init(usageStatus: .complete, inputTokens: 150, cachedInputTokens: 20, cacheCreationTokens: 30, outputTokens: 10),
            session: session, observedAt: usageProjectionNow))
        let passive = try ClaudeUsageSnapshot(revision: 4, session: session,
            rateLimits: [.init(window: .fiveHour, status: .allowedWarning, utilization: 0.8)], status: .requesting, statusObserved: true,
            observedAt: usageProjectionNow)
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(passive))
        thread.providerMetadata = .object(["claudeUsage": json])
    }
    thread.runHistory = [record]; thread.model = "future-header-model"; thread.permission = .fullAccess
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    return snapshot
}
private func usageProjectionSource(_ snapshot: WorkspaceSnapshot) throws -> RemoteProjectionSource {
    try RemoteProjectionProjector.build(.init(snapshot: snapshot, sequence: 1), scope: .thread(snapshot.threads[0].id), reserve: { bytes in
        guard bytes <= RemoteProjectionProtocol.maximumCacheBytes else { throw RemoteProjectionFailure(.limitExceeded) }
    })
}

@Test func providerUsageRemoteProjectionLegacyCodecOmitsOptionalUsageAndPreservesLifecycleFields() throws {
    let snapshot = try usageProjectionSnapshot(path: "/private/usage-projection-legacy", reported: false)
    let source = try usageProjectionSource(snapshot), detail = try #require(source.detail), run = try #require(source.runs.first)
    let runData = try RemoteProjectionProtocol.payload(run), detailData = try RemoteProjectionProtocol.payload(detail)
    let runObject = try JSONSerialization.jsonObject(with: runData) as? [String: Any]
    let detailObject = try JSONSerialization.jsonObject(with: detailData) as? [String: Any]
    #expect(runObject?["providerUsage"] == nil && runObject?["providerUsageContent"] == nil)
    #expect(detailObject?["liveProviderUsage"] == nil && detailObject?["liveProviderUsageContent"] == nil)
    let decodedRun = try JSONDecoder().decode(RemoteRunSummary.self, from: runData)
    let decodedDetail = try JSONDecoder().decode(RemoteThreadDetail.self, from: detailData)
    #expect(decodedRun == run && decodedRun.providerUsage == nil && decodedRun.providerUsageContent == nil)
    #expect(decodedDetail == detail && decodedDetail.liveProviderUsage == nil && decodedDetail.liveProviderUsageContent == nil)
    #expect(decodedDetail.workspaceLifecycle == snapshot.threads[0].workspaceLifecycle)
    let request = RemoteProjectionOpenRequest(environmentID: UUID(), scope: .thread(snapshot.threads[0].id), clientSupportsLifecycleControls: true)
    let encodedRequest = try RemoteProjectionProtocol.payload(request)
    #expect(try JSONDecoder().decode(RemoteProjectionOpenRequest.self, from: encodedRequest).clientSupportsLifecycleControls == true)
}

@Test func providerUsageRemoteProjectionUsesCapturedRunOwnerAndKeepsPassiveCurrentUsageSeparate() throws {
    var snapshot = try usageProjectionSnapshot(path: "/private/usage-projection-captured")
    let source = try usageProjectionSource(snapshot), run = try #require(source.runs.first), detail = try #require(source.detail)
    #expect(run.provider == .claude && run.model.preview == "captured-past-model" && run.permission == .supervised)
    #expect(run.providerUsage == snapshot.threads[0].runHistory?[0].providerUsage && run.providerUsageContent == nil)
    #expect(detail.liveProviderUsage == snapshot.threads[0].liveProviderUsage && detail.liveProviderUsageContent == nil)
    guard let recordedUsage = run.providerUsage, let liveUsage = detail.liveProviderUsage,
          case .claude(let recorded) = recordedUsage, case .claude(let passive) = liveUsage else {
        Issue.record("Both typed observations should remain available independently"); return
    }
    #expect(recorded.runID == run.id && recorded.turn?.inputTokens == 150)
    #expect(passive.runID == nil && passive.turn == nil && passive.rateLimits.first?.utilization == 0.8)
    snapshot.threads[0].provider = .codex
    let changedHeader = try usageProjectionSource(snapshot)
    #expect(changedHeader.runs.first?.provider == .claude && changedHeader.runs.first?.providerUsage == run.providerUsage)
    #expect(changedHeader.detail?.liveProviderUsage == nil, "A previous Claude meter cannot attach to a different current provider.")
}

@Test(.timeLimit(.minutes(1))) func providerUsageRemoteProjectionLargeTypedDocumentsStayBoundedLeasedAndByteExact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-usage-projection-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = try usageProjectionSnapshot(path: root.path, large: true)
    try WorkspaceJournal.validate(snapshot)
    let originalRun = try #require(snapshot.threads[0].runHistory?.first?.providerUsage)
    let originalLive = try #require(snapshot.threads[0].liveProviderUsage)
    let expectedRun = try RemoteProjectionProtocol.payload(originalRun), expectedLive = try RemoteProjectionProtocol.payload(originalLive)
    #expect(expectedRun.count > RemoteProjectionProtocol.maximumPageBytes && expectedLive.count > RemoteProjectionProtocol.maximumPageBytes)
    let source = try usageProjectionSource(snapshot), projectedRun = try #require(source.runs.first), projectedDetail = try #require(source.detail)
    #expect(projectedRun.providerUsage == nil && projectedDetail.liveProviderUsage == nil)
    let runReference = try #require(projectedRun.providerUsageContent), liveReference = try #require(projectedDetail.liveProviderUsageContent)
    #expect(runReference.kind == .providerUsage && liveReference.kind == .providerUsage)
    #expect(source.contents[runReference.id] == expectedRun && source.contents[liveReference.id] == expectedLive)
    #expect(try RemoteProjectionProtocol.payload(projectedRun).count < 16_384)
    #expect(try RemoteProjectionProtocol.payload(projectedDetail).count < 16_384)

    let database = root.appendingPathComponent("workspace.sqlite")
    try await WorkspaceDatabase(url: database).save(snapshot, event: "usage.projection.fixture")
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in throw CoincideError("Usage browsing cannot launch a provider") }, identityResolver: { _ in nil })
    let service = RemoteProjectionService(environmentID: UUID(), engine: engine)
    do {
        let environment = service.environmentID
        let threadID = snapshot.threads[0].id
        let binding = try await service.open(.init(environmentID: environment, scope: .thread(threadID)))
        let runs = try await service.runs(.init(binding: binding, threadID: threadID))
        let detail = try await service.thread(.init(binding: binding, threadID: threadID))
        #expect(try RemoteProjectionProtocol.payload(runs).count <= RemoteProjectionProtocol.maximumResultBytes)
        #expect(try RemoteProjectionProtocol.payload(detail).count <= RemoteProjectionProtocol.maximumResultBytes)
        let leasedRun = try #require(runs.items.first?.providerUsageContent), leasedLive = try #require(detail.thread.liveProviderUsageContent)
        for (reference, expected) in [(leasedRun, expectedRun), (leasedLive, expectedLive)] {
            var bytes = Data(), cursor: UUID?
            repeat {
                let page = try await service.content(.init(binding: binding, reference: reference, offset: bytes.count, cursor: cursor))
                #expect(page.binding == binding && page.reference == reference && page.offset == bytes.count)
                #expect(try RemoteProjectionProtocol.payload(page).count <= RemoteProjectionProtocol.maximumResultBytes)
                bytes.append(page.data); cursor = page.nextCursor
            } while cursor != nil
            #expect(bytes == expected && bytes.count == reference.totalBytes && RemoteProjectionProtocol.digest(bytes) == reference.digest)
            let decoded = try JSONDecoder().decode(ProviderUsageUpdate.self, from: bytes)
            #expect(decoded == (reference == leasedRun ? originalRun : originalLive))
        }
        _ = try await service.release(.init(binding: binding))
        await #expect(throws: RemoteProjectionFailure(.staleView)) { _ = try await service.content(.init(binding: binding, reference: leasedRun)) }
    } catch { await service.close(); await engine.shutdown(); throw error }
    await service.close(); await engine.shutdown()
}
