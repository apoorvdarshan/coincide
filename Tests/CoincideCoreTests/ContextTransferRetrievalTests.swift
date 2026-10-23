import Foundation
import Testing
@testable import CoincideCore

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func contextTransferFinalSelectionAdvertisesOnlyActualScopedToolSupportAndPersistsBeforeDelivery(supported: Bool) async throws {
    let f = try await ContextTransferCoreFixture.make(contextTools: true, supportsContextTools: supported, giant: true)
    do {
        let review = try await f.portable()
        _ = try await f.engine.acceptContextTransfer(reviewID: review.id, digest: review.digest)
        let inputID = UUID(); _ = try await f.engine.dispatch(.submit(threadID: review.targetThreadID, text: "Exact literal input"), id: inputID)
        try await contextTransferEventually { await f.engine.current().snapshot.contextTransfer(review.id)?.status == .consumed }
        let input = try #require(await f.peer.inputs.first), context = try #require(input.historicalContext)
        #expect(context.selection.source.retrievalAvailable == supported)
        #expect(!context.selection.omittedIDs.isEmpty)
        #expect(context.selection.coverage.contains("t3_context_read") == supported)
        let transfer = try #require(await f.engine.current().snapshot.contextTransfer(review.id))
        #expect(transfer.delivery?.selection == context.selection && transfer.targetRunID == inputID)
        let omitted = Set(context.selection.omittedIDs)
        #expect(review.messages.contains { omitted.contains($0.id) && $0.text.contains("Archived public large body") })
        let record = try #require(await f.engine.current().snapshot.threads.first { $0.id == review.targetThreadID }?.runHistory?.first)
        #expect(record.contextDelivery?.selection == context.selection && record.contextTransferIDs == [review.id])
        #expect(input.text == "Exact literal input")
        let contextualRuntime = await f.engine.current().snapshot.threads.first { $0.id == review.targetThreadID }?.runtimeID
        _ = try await f.engine.dispatch(.submit(threadID: review.targetThreadID, text: "Ordinary successor"))
        try await contextTransferEventually { await f.peer.inputs.count == 2 }
        let ordinaryRuntime = await f.engine.current().snapshot.threads.first { $0.id == review.targetThreadID }?.runtimeID
        #expect((contextualRuntime != ordinaryRuntime) == supported)
        #expect(await f.peer.inputs.last?.historicalContext == nil)
        #expect(await f.engine.current().snapshot.threads.first { $0.id == review.targetThreadID }?.providerThreadID == "portable-target")
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func contextTransferQueuedOverlapOmitsOnlyPositivelyDeliveredItemsAndRecoversCancelledPredecessor(cancelFirst: Bool) async throws {
    let f = try await ContextTransferCoreFixture.make()
    do {
        let fork = try await f.portable(); _ = try await f.engine.acceptContextTransfer(reviewID: fork.id, digest: fork.digest)
        let firstChildInput = try await f.engine.dispatch(.submit(threadID: fork.targetThreadID, text: "Earlier child delta")).commandID
        try await contextTransferEventually { await f.engine.current().snapshot.contextTransfer(fork.id)?.status == .consumed }
        try await contextTransferEventually { await f.engine.current().snapshot.threads.first(where: { $0.id == fork.targetThreadID })?.runHistory?.first(where: { $0.id == firstChildInput })?.status == .completed }
        var child = try #require(await f.engine.current().snapshot.threads.first { $0.id == fork.targetThreadID }), parent = try await f.source()
        let firstReview = try await f.engine.reviewContextTransfer(.init(sourceThreadID: child.id, expectedConfiguration: .init(thread: child), sourcePoint: .run(firstChildInput), intent: .mergeBack(targetConfiguration: .init(thread: parent))))
        _ = try await f.engine.acceptContextTransfer(reviewID: firstReview.id, digest: firstReview.digest)
        let firstInput = UUID(); _ = try await f.engine.dispatch(.submitFromAppMCP(threadID: parent.id, text: "Reserved first", queueEvenWhenIdle: true), id: firstInput)
        let secondChildInput = try await f.engine.dispatch(.submit(threadID: child.id, text: "Later child delta")).commandID
        try await contextTransferEventually { await f.engine.current().snapshot.threads.first(where: { $0.id == child.id })?.runHistory?.first(where: { $0.id == secondChildInput })?.status == .completed }
        child = try #require(await f.engine.current().snapshot.threads.first { $0.id == child.id })
        let secondReview = try await f.engine.reviewContextTransfer(.init(sourceThreadID: child.id, expectedConfiguration: .init(thread: child), sourcePoint: .run(secondChildInput), intent: .mergeBack(targetConfiguration: .init(thread: parent))))
        _ = try await f.engine.acceptContextTransfer(reviewID: secondReview.id, digest: secondReview.digest)
        let secondInput = UUID(); _ = try await f.engine.dispatch(.submitFromAppMCP(threadID: parent.id, text: "Reserved second", queueEvenWhenIdle: true), id: secondInput)
        var snapshot = await f.engine.current().snapshot
        let parentQueued = try #require(snapshot.threads.first { $0.id == parent.id })
        let capturedSecond = try #require(parentQueued.queuedTurns.first { $0.id == secondInput }?.contextDelivery)
        #expect(capturedSecond.selection.messages.contains { $0.text == "Earlier child delta" })
        func apply(_ command: EngineCommand) throws { snapshot = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: Date()).snapshot }
        if cancelFirst { try apply(.client(.removeQueued(threadID: parent.id, queuedID: firstInput))) }
        try apply(.client(.resumeQueue(threadID: parent.id)))
        if !cancelFirst {
            let first = try #require(snapshot.threads.first { $0.id == parent.id }?.activeRun?.contextDelivery), runtimeID = UUID()
            try apply(.runtimeOpened(threadID: parent.id, runID: firstInput, runtimeID: runtimeID))
            try apply(.contextTransferDispatching(threadID: parent.id, runID: firstInput, deliveryID: first.id, runtimeID: runtimeID))
            try apply(.contextTransferDelivered(threadID: parent.id, runID: firstInput, deliveryID: first.id))
            try apply(.provider(threadID: parent.id, runtimeID: runtimeID, event: .context(runID: firstInput, event: .completed(.idle))))
        }
        let second = try #require(snapshot.threads.first { $0.id == parent.id }?.activeRun?.contextDelivery)
        #expect(second.runID == secondInput)
        let selected = try snapshot.contextSelection(for: second, retrievalAvailable: false)
        #expect(selected.messages.contains { $0.text == "Earlier child delta" } == cancelFirst)
        #expect(selected.messages.contains { $0.text == "Later child delta" })
        #expect(second.transferIDs == [secondReview.id])
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func contextTransferCombinedDeliveryNamesEveryAuthorizedImmutableArchiveAndRetainsBothDeltas() async throws {
    let f = try await ContextTransferCoreFixture.make(contextTools: true)
    do {
        _ = try await f.engine.dispatch(.submit(threadID: f.sourceID, text: "Ordinary parent before contextual merges"))
        try await contextTransferEventually { await f.engine.current().snapshot.threads.first(where: { $0.id == f.sourceID })?.isBusy == false }
        let ordinaryParentRuntime = await f.engine.current().snapshot.threads.first { $0.id == f.sourceID }?.runtimeID
        var merges: [ContextTransferReview] = []
        for number in 1...2 {
            let fork = try await f.portable(); _ = try await f.engine.acceptContextTransfer(reviewID: fork.id, digest: fork.digest)
            let childInput = try await f.engine.dispatch(.submit(threadID: fork.targetThreadID, text: "Child delta \(number)")).commandID
            try await contextTransferEventually { await f.engine.current().snapshot.contextTransfer(fork.id)?.status == .consumed }
            try await contextTransferEventually { await f.engine.current().snapshot.threads.first(where: { $0.id == fork.targetThreadID })?.runHistory?.first(where: { $0.id == childInput })?.status == .completed }
            let child = try #require(await f.engine.current().snapshot.threads.first { $0.id == fork.targetThreadID }), parent = try await f.source()
            let run = childInput
            let merge = try await f.engine.reviewContextTransfer(.init(sourceThreadID: child.id, expectedConfiguration: .init(thread: child), sourcePoint: .run(run), intent: .mergeBack(targetConfiguration: .init(thread: parent))))
            _ = try await f.engine.acceptContextTransfer(reviewID: merge.id, digest: merge.digest); merges.append(merge)
        }
        let ids = merges.map(\.id)
        _ = try await f.engine.dispatch(.submit(threadID: f.sourceID, text: "Use both explicit deltas"))
        try await contextTransferEventually { await f.engine.current().snapshot.contextTransfers?.filter { ids.contains($0.id) && $0.status == .consumed }.count == 2 }
        let input = try #require(await f.peer.inputs.last), context = try #require(input.historicalContext)
        #expect(context.transferIDs == ids && context.selection.source.additionalTransferIDs == Array(ids.dropFirst()))
        #expect(context.selection.source.retrievalAvailable)
        let contextualParentRuntime = await f.engine.current().snapshot.threads.first { $0.id == f.sourceID }?.runtimeID
        #expect(contextualParentRuntime != ordinaryParentRuntime)
        #expect(ids.allSatisfy { context.selection.renderedText.contains($0.uuidString) })
        #expect(context.selection.messages.contains { $0.text == "Child delta 1" })
        #expect(context.selection.messages.contains { $0.text == "Child delta 2" })
        try context.validate()
    } catch { await f.close(); throw error }; await f.close()
}
