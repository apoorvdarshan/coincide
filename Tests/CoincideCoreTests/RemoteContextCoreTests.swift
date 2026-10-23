import Foundation
import Testing
@testable import CoincideCore

private struct RemoteContextCoreFixture {
    let core: ContextTransferCoreFixture
    let workspace: RemoteWorkspaceService
    let service: RemoteContextService
    let target: RemoteWorkspaceTarget
    static func make() async throws -> Self {
        let core = try await ContextTransferCoreFixture.make()
        let source = try await core.source(), environment = UUID()
        try FileManager.default.createDirectory(at: core.root.appendingPathComponent("Host"),
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let workspace = try RemoteWorkspaceService(environmentID: environment, engine: core.engine,
            dataDirectory: core.root.appendingPathComponent("Host"))
        let target = try await workspace.bindHistoryTarget(.init(environmentID: environment, projectID: source.projectID,
            threadID: source.id, configuration: .init(thread: source)))
        let service = RemoteContextService(environmentID: environment, engine: core.engine, workspace: workspace) { _, source in
            var configuration = source.configuration
            configuration.provider = .opencode; configuration.nativeThreadID = nil; configuration.model = ""
            configuration.openCodeConfiguration = .init(executable: "/offline-context-peer")
            return configuration
        }
        return .init(core: core, workspace: workspace, service: service, target: target)
    }
    func review() async throws -> RemoteContextReview {
        try await service.review(.init(target: target, intent: .fork(.init(provider: .opencode))))
    }
    func command(_ review: RemoteContextReview, id: UUID = UUID()) -> RemoteEnvironmentCommandRequest {
        .init(environmentID: target.environmentID, id: id,
            command: .contextTransfer(target: target, action: .begin(reviewID: review.id, digest: review.digest, title: nil)))
    }
    func close() async { await service.close(); await workspace.close(); await core.close() }
}

@Test(.timeLimit(.minutes(1)))
func remoteContextAcceptanceUsesOnlyHostProofOriginalOuterUUIDAndDefersAllProviderInput() async throws {
    let f = try await RemoteContextCoreFixture.make()
    do {
        let review = try await f.review(), request = f.command(review)
        #expect(review.id != request.id && review.value.strategy == .portableContext)
        #expect(review.value.targetThreadID != f.target.threadID)
        let prepared = try await f.service.prepare(request.command)
        guard case .contextTransfer(let captured) = prepared else { throw CoincideError("Missing host context preparation") }
        try await f.service.validatePreparation(captured)
        let receipt = try await f.core.engine.dispatchRemoteEnvironment(request, preparation: prepared)
        #expect(receipt.commandID == request.id && receipt.rejection == nil)
        #expect(try await f.core.engine.dispatchRemoteEnvironment(request, preparation: .refused) == receipt)
        #expect(try await WorkspaceDatabase(url: f.core.database).receipt(review.id) == nil)
        #expect(await f.core.peer.inputs.isEmpty)
        let transfer = try #require(await f.core.engine.current().snapshot.contextTransfer(review.id))
        #expect(transfer.status == .pending && transfer.delivery == nil)
        #expect(await f.core.engine.current().snapshot.threads.first { $0.id == review.value.targetThreadID }?.messages.isEmpty == true)
        _ = try await f.core.engine.dispatch(.submit(threadID: review.value.targetThreadID, text: "Explicit remote target input"))
        try await contextTransferEventually { await f.core.engine.current().snapshot.contextTransfer(review.id)?.status == .consumed }
        #expect(await f.core.peer.inputs.count == 1)
        #expect(await f.core.peer.inputs.first?.text == "Explicit remote target input")
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["configuration", "discard", "digest", "physicalRoot"])
func remoteContextPreparedAcceptanceCannotOutliveExactReviewConfigurationOrPhysicalRoots(change: String) async throws {
    let f = try await RemoteContextCoreFixture.make()
    var moved: URL?
    do {
        let review = try await f.review(), request = f.command(review)
        let prepared = try await f.service.prepare(request.command)
        switch change {
        case "configuration": _ = try await f.core.engine.dispatch(.editThread(f.target.threadID, .model("Changed host selection")))
        case "discard": #expect(try await f.service.discard(.init(target: f.target, reviewID: review.id, digest: review.digest)).discarded)
        case "physicalRoot":
            let replacement = f.core.root.appendingPathExtension("moved"); moved = replacement
            try FileManager.default.moveItem(at: f.core.root, to: replacement)
            try FileManager.default.createDirectory(at: f.core.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        default: break
        }
        if change == "physicalRoot", case .contextTransfer(let captured) = prepared {
            await #expect(throws: RemoteWorkspaceFailure(.staleRoot)) { try await f.service.validatePreparation(captured) }
        } else {
            let altered = change == "digest" ? RemoteEnvironmentCommandRequest(environmentID: f.target.environmentID,
                command: .contextTransfer(target: f.target, action: .begin(reviewID: review.id, digest: String(repeating: "0", count: 64), title: nil))) : request
            let receipt = try await f.core.engine.dispatchRemoteEnvironment(altered, preparation: prepared)
            #expect(receipt.rejection != nil)
        }
        #expect(await f.core.peer.inputs.isEmpty)
        #expect(await f.core.engine.current().snapshot.contextTransfers?.isEmpty != false)
        if let moved { try FileManager.default.removeItem(at: f.core.root); try FileManager.default.moveItem(at: moved, to: f.core.root) }
    } catch {
        if let moved { try? FileManager.default.removeItem(at: f.core.root); try? FileManager.default.moveItem(at: moved, to: f.core.root) }
        await f.close(); throw error
    }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteContextLeaseUsesFullTargetExactQueryAndArchivesOnlySelectedPrefixWithoutSending() async throws {
    let f = try await RemoteContextCoreFixture.make()
    do {
        let review = try await f.service.review(.init(target: f.target, sourcePoint: .run(f.core.runs[0]), intent: .fork(.init(provider: .opencode))))
        let request = RemoteContextReadRequest(target: f.target, query: .messages(binding: review.binding, cursor: nil))
        let result = try await f.service.read(request)
        #expect(try await f.service.read(request) == result)
        guard case .messages(let page) = result.value else { throw CoincideError("Missing context archive page") }
        #expect(page.items.contains { $0.text.preview == "Source prompt 1" })
        #expect(!page.items.contains { $0.text.preview == "Source prompt 2" })
        var changed = f.target.configuration; changed.model = "Changed viewer"
        let foreign = RemoteWorkspaceTarget(environmentID: f.target.environmentID, projectID: f.target.projectID,
            threadID: f.target.threadID, configuration: changed, rootID: f.target.rootID)
        await #expect(throws: RemoteContextFailure(.staleReview)) {
            _ = try await f.service.read(.init(target: foreign, query: .messages(binding: review.binding, cursor: nil)))
        }
        _ = try await f.service.read(.init(target: f.target, query: .release(binding: review.binding)))
        await #expect(throws: RemoteContextFailure(.staleReview)) { _ = try await f.service.read(request) }
        #expect(await f.core.peer.inputs.isEmpty)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteContextHandoffKeepsSameAppThreadAndMergeBackRequiresActualBoundParent() async throws {
    let f = try await RemoteContextCoreFixture.make()
    do {
        let fork = try await f.review(), forkCommand = f.command(fork)
        #expect(try await f.core.engine.dispatchRemoteEnvironment(forkCommand,
            preparation: f.service.prepare(forkCommand.command)).rejection == nil)
        let childID = fork.value.targetThreadID, inputID = UUID()
        _ = try await f.core.engine.dispatch(.submit(threadID: childID, text: "Only this child delta merges back"), id: inputID)
        try await contextTransferEventually { await f.core.engine.current().snapshot.threads.first { $0.id == childID }?.activeRun == nil }
        let child = try #require(await f.core.engine.current().snapshot.threads.first { $0.id == childID })
        let childTarget = try await f.workspace.bindHistoryTarget(.init(environmentID: f.target.environmentID,
            projectID: child.projectID, threadID: childID, configuration: .init(thread: child)))
        await #expect(throws: RemoteContextFailure(.invalidTarget)) {
            _ = try await f.service.review(.init(target: childTarget, sourcePoint: .run(inputID), intent: .mergeBack(expectedParent: childTarget)))
        }
        let merge = try await f.service.review(.init(target: childTarget, sourcePoint: .run(inputID), intent: .mergeBack(expectedParent: f.target)))
        #expect(merge.value.kind == .mergeBack && merge.value.strategy == .forkDeltaContext && merge.value.targetThreadID == f.target.threadID)
        let request = RemoteEnvironmentCommandRequest(environmentID: f.target.environmentID,
            command: .contextTransfer(target: childTarget, action: .begin(reviewID: merge.id, digest: merge.digest, title: nil)))
        #expect(try await f.core.engine.dispatchRemoteEnvironment(request, preparation: f.service.prepare(request.command)).rejection == nil)
        #expect(await f.core.peer.inputs.count == 1)
        let archived = try #require(await f.core.engine.current().snapshot.contextTransfer(merge.id))
        #expect(archived.review.messages.contains { $0.text == "Only this child delta merges back" })
        #expect(!archived.review.messages.contains { $0.text == "Source prompt 1" })
        let handoff = try await f.service.review(.init(target: f.target, sourcePoint: .run(f.core.runs[2]), intent: .providerHandoff(.init(provider: .opencode))))
        #expect(handoff.value.kind == .providerHandoff && handoff.value.targetThreadID == f.target.threadID)
        let handoffCommand = f.command(handoff)
        #expect(try await f.core.engine.dispatchRemoteEnvironment(handoffCommand, preparation: f.service.prepare(handoffCommand.command)).rejection == nil)
        #expect(await f.core.engine.current().snapshot.threads.count == 2)
        #expect(await f.core.peer.inputs.count == 1)
        #expect(await f.core.engine.current().snapshot.contextTransfer(handoff.id)?.review.messages.contains { $0.text == "Only this child delta merges back" } == true)
        #expect(await f.core.engine.current().snapshot.threads.first { $0.id == f.target.threadID }?.provider == .opencode)
        #expect(await f.core.engine.current().snapshot.threads.first { $0.id == f.target.threadID }?.draft == "Keep source composer")
    } catch { await f.close(); throw error }; await f.close()
}
