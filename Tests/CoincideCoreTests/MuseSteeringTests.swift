import Foundation
import Testing
@testable import CoincideCore

private struct MuseSteeringPeer {
    let fixture: MuseSessionFixture
    let configuration: MuseConfiguration
    let session: MuseSession
    let observed = MuseObserved()
    init(_ options: [String: JSONValue]) throws {
        fixture = try .init(options: options, resource: "muse_steering_server")
        configuration = .init(executable: fixture.executable.path, model: .init(modelID: "native-default"), reasoningEffort: "low")
        session = .init(executable: fixture.executable, cwd: fixture.root, configuration: configuration)
    }
    func thread() -> CodingThread {
        var thread = CodingThread(project: .init(path: fixture.root.path))
        thread.provider = .muse; thread.museConfiguration = configuration; thread.model = configuration.model?.catalogID ?? ""
        thread.permission = .supervised; thread.checkpointPolicy = .disabled
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
        return thread
    }
    func start() async throws -> CodingThread {
        var value = thread(); let runID = try #require(value.activeRun?.id)
        try await session.send(text: "Original Muse foreground input", thread: value)
        try await museEventually {
            let native = await observed.turns[runID], count = await observed.entities.count
            return native != nil && count >= 2
        }
        let sessions = await observed.sessions, native = await observed.turns[runID]
        value.providerThreadID = try #require(sessions.last); value.activeRun?.nativeTurnID = try #require(native)
        return value
    }
}

private func withMuseSteering(_ options: [String: JSONValue] = [:], _ body: (MuseSteeringPeer) async throws -> Void) async throws {
    let peer = try MuseSteeringPeer(options)
    let consumer = Task { for await event in peer.session.events { await peer.observed.append(event) } }
    do {
        try await body(peer); await peer.session.close(); await consumer.value
        try await museEventually { peer.fixture.parentsStopped }; try peer.fixture.removeIfStopped()
    } catch {
        await peer.session.close(); await consumer.value
        try? peer.fixture.removeIfStopped(); throw error
    }
}

@Test(.timeLimit(.minutes(1)))
func museSteeringUsesExactNativeTurnWithoutChangingCapturedControlsAndDeduplicatesOnlyTheSameLocalInput() async throws {
    try await withMuseSteering(["observeSteer": .bool(false)]) { peer in
        let thread = try await peer.start(), native = try #require(thread.activeRun?.nativeTurnID)
        #expect(await peer.session.steeringCapabilities().supportsActiveSteering)
        let receipt = try await peer.session.steer(input: .init(text: "Focus on the 日本語 parser"), thread: thread,
            expectedTurnID: native, clientMessageID: "one-owned-steer")
        #expect(receipt.turnID == native && receipt.delivery == .acknowledged)
        let requests = try peer.fixture.rows("request"), request = try #require(requests.last { $0["method"] == .string("turn/steer") })
        #expect(request["params"]["expectedTurnId"] == .string(native) && request["params"]["sessionId"] == .string(thread.providerThreadID!))
        #expect(request["params"]["input"] == .array([.object(["type": .string("text"), "text": .string("Focus on the 日本語 parser")])]))
        let command = try MuseProtocol.identity(request["params"]["commandId"], command: true)
        #expect(command != native)
        let steerRows = try peer.fixture.rows("steer")
        let wire = try #require(steerRows.last)
        #expect(wire["extraControls"] == .bool(false) && wire["model"] == .string("native-default") && wire["profile"] == .string(":ask-me"))
        #expect(await peer.observed.completions.isEmpty)
        let duplicate = try await peer.session.steer(input: .init(text: "Focus on the 日本語 parser"), thread: thread,
            expectedTurnID: native, clientMessageID: "one-owned-steer")
        #expect(duplicate == receipt)
        await #expect(throws: ProviderSteeringError(.invalidRequest)) {
            try await peer.session.steer(input: .init(text: "Changed input under the old local ID"), thread: thread,
                expectedTurnID: native, clientMessageID: "one-owned-steer")
        }
        #expect(try peer.fixture.rows("steer").count == 1)
        try peer.fixture.signal("finish")
        try await museEventually { await peer.observed.completions.count == 1 }
        let complete = await peer.observed.completions
        #expect(complete.first?.0 == thread.activeRun?.id && complete.first?.1 == .idle)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func museSteeringDurableUserMessageBeatsLostOrLateErrorACKAndKeepsOriginalBackgroundOwnership(dropReply: Bool) async throws {
    try await withMuseSteering(["observeSteer": .bool(true), "holdSteerReply": .bool(true),
        "terminalBeforeSteerReply": .bool(true), "steerLateError": .bool(!dropReply), "dropSteerReply": .bool(dropReply), "background": .bool(true)]) { peer in
        let first = try await peer.start(), native = try #require(first.activeRun?.nativeTurnID)
        let receipt = try await peer.session.steer(input: .init(text: "Observed steering input"), thread: first,
            expectedTurnID: native, clientMessageID: "observed-before-ack")
        #expect(receipt.turnID == native)
        try await museEventually { await peer.observed.completions.count == 1 }
        try peer.fixture.set("background", .bool(false))
        let second = try await peer.start()
        try peer.fixture.set("holdSteerReply", .bool(false)); try peer.fixture.signal("childFinish")
        try await museEventually { await peer.observed.entities.values.contains { $0.text.contains("Original child result") } }
        let entities = await peer.observed.entities, owners = await peer.observed.entityOwners
        let child = try #require(entities.values.first { $0.text.contains("Original child result") })
        #expect(owners[child.key] == first.activeRun?.id)
        #expect(await peer.observed.failures.isEmpty)
        #expect(await peer.observed.completions.count == 1)
        await #expect(throws: MuseMSPError(.invalidInput)) { try await peer.session.interrupt(expectedRunID: first.activeRun!.id) }
        #expect(try peer.fixture.rows("interrupt").isEmpty)
        try peer.fixture.signal("finish"); try await museEventually { await peer.observed.completions.count == 2 }
        let completions = await peer.observed.completions
        #expect(completions.last?.0 == second.activeRun?.id)
        #expect(try peer.fixture.rows("steer").count == 1)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func museSteeringUnobservedOldRejectionOrCancelledWaitCannotInvalidateAnObservedSuccessor(cancelWait: Bool) async throws {
    try await withMuseSteering(["observeSteer": .bool(false), "holdSteerReply": .bool(true),
        "terminalBeforeSteerReply": .bool(true), "steerLateError": .bool(true)]) { peer in
        let first = try await peer.start(), native = try #require(first.activeRun?.nativeTurnID)
        let steering = Task { try await peer.session.steer(input: .init(text: "Unknown old delivery"), thread: first,
            expectedTurnID: native, clientMessageID: "unknown-old") }
        do {
            try await museEventually { await peer.observed.completions.count == 1 }
            _ = try await peer.start()
            if cancelWait { steering.cancel() }
            try peer.fixture.set("holdSteerReply", .bool(false))
            var failure: ProviderSteeringError?
            do { _ = try await steering.value } catch let known as ProviderSteeringError { failure = known }
            #expect(failure == .init(cancelWait ? .outcomeUncertain : .rejected))
            try await museEventually { try !peer.fixture.rows("steerReply").isEmpty }
            #expect(await peer.observed.failures.isEmpty)
            #expect(await peer.observed.completions.count == 1)
            try peer.fixture.signal("finish"); try await museEventually { await peer.observed.completions.count == 2 }
        } catch { steering.cancel(); try? peer.fixture.set("holdSteerReply", .bool(false)); _ = await steering.result; throw error }
    }
}

@Test(.timeLimit(.minutes(1)))
func museSteeringStaleNativeBoundarySessionAndFutureControlsAreRefusedBeforeWrite() async throws {
    try await withMuseSteering { peer in
        let thread = try await peer.start(), native = try #require(thread.activeRun?.nativeTurnID)
        var future = thread
        future.museConfiguration = .init(instanceID: peer.configuration.instanceID, executable: peer.fixture.executable.path,
            model: .init(modelID: "selected-model"), reasoningEffort: "high")
        future.model = future.museConfiguration!.model!.catalogID
        future.permission = .fullAccess
        let changed = future
        for candidate in [thread, changed] {
            let target = candidate.museConfiguration == peer.configuration ? UUID().uuidString : native
            await #expect(throws: ProviderSteeringError(.staleTarget)) {
                try await peer.session.steer(input: .init(text: "Refused stale capture"), thread: candidate,
                    expectedTurnID: target, clientMessageID: "stale-local")
            }
        }
        var foreign = thread; foreign.providerThreadID = UUID().uuidString
        let wrongSession = foreign
        await #expect(throws: ProviderSteeringError(.staleTarget)) {
            try await peer.session.steer(input: .init(text: "Wrong native session"), thread: wrongSession,
                expectedTurnID: native, clientMessageID: "wrong-session")
        }
        #expect(try peer.fixture.rows("steer").isEmpty)
        #expect(await peer.observed.failures.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func museSteeringRemoteRejectionAndWrongTargetACKRemainDistinctAndNeverReplay(wrongACK: Bool) async throws {
    try await withMuseSteering(["observeSteer": .bool(false), "rejectSteer": .bool(!wrongACK), "wrongSteerTurn": .bool(wrongACK)]) { peer in
        let thread = try await peer.start(), native = try #require(thread.activeRun?.nativeTurnID)
        await #expect(throws: ProviderSteeringError(wrongACK ? .outcomeUncertain : .rejected)) {
            try await peer.session.steer(input: .init(text: "One explicit attempt"), thread: thread,
                expectedTurnID: native, clientMessageID: "one-attempt")
        }
        let requests = try peer.fixture.rows("request")
        #expect(requests.filter { $0["method"] == .string("turn/steer") }.count == 1)
        if wrongACK { try await museEventually { await !peer.observed.failures.isEmpty } }
        else {
            #expect(await peer.observed.failures.isEmpty)
            try peer.fixture.signal("finish"); try await museEventually { await peer.observed.completions.count == 1 }
        }
        #expect(await peer.observed.failures.allSatisfy { !$0.contains("synthetic-private-token") })
    }
}

@Test(.timeLimit(.minutes(1)))
func museSteeringStopUsesTheExactNativeTurnAndWaitsForItsRealCancelledTerminal() async throws {
    try await withMuseSteering(["observeSteer": .bool(false), "holdSteerReply": .bool(true), "holdInterruptTerminal": .bool(true)]) { peer in
        let thread = try await peer.start(), native = try #require(thread.activeRun?.nativeTurnID), runID = try #require(thread.activeRun?.id)
        let steering = Task { try await peer.session.steer(input: .init(text: "Pending exact-turn steering"), thread: thread,
            expectedTurnID: native, clientMessageID: "steer-during-stop") }
        var stopping: Task<Void, any Error>?
        do {
            try await museEventually { try peer.fixture.rows("steer").count == 1 }
            let stop = Task { try await peer.session.interrupt(expectedRunID: runID); await peer.observed.stopReturned() }; stopping = stop
            try await museEventually { try peer.fixture.rows("interrupt").count == 1 }
            #expect(await peer.observed.returnedStops == 0)
            #expect(try peer.fixture.rows("interrupt").first?["turnId"] == .string(native))
            #expect(try peer.fixture.rows("interrupt").first?["exact"] == .bool(true))
            try peer.fixture.signal("cancelled"); try await stop.value
            #expect(await peer.observed.returnedStops == 1)
            try peer.fixture.set("holdSteerReply", .bool(false))
            let receipt = try await steering.value
            #expect(receipt.turnID == native)
            let completions = await peer.observed.completions
            #expect(completions.count == 1 && completions[0].0 == runID && completions[0].1 == .interrupted)
        } catch {
            steering.cancel(); stopping?.cancel(); try? peer.fixture.set("holdSteerReply", .bool(false))
            await peer.session.close(); _ = await steering.result; _ = await stopping?.result; throw error
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func museSteeringCloseJoinsPendingCommandsAndNeverReportsUnknownDeliveryAsAccepted() async throws {
    try await withMuseSteering(["observeSteer": .bool(false), "holdSteerReply": .bool(true)]) { peer in
        let thread = try await peer.start(), native = try #require(thread.activeRun?.nativeTurnID)
        let steering = Task { try await peer.session.steer(input: .init(text: "Unknown at close"), thread: thread,
            expectedTurnID: native, clientMessageID: "unknown-at-close") }
        do {
            try await museEventually { try peer.fixture.rows("steer").count == 1 }
            async let one: Void = peer.session.close(), two: Void = peer.session.close()
            _ = await (one, two)
            var failure: ProviderSteeringError?
            do { _ = try await steering.value } catch let error as ProviderSteeringError { failure = error }
            #expect(failure == .init(.outcomeUncertain))
            #expect(peer.fixture.parentsStopped)
            #expect(try peer.fixture.rows("steer").count == 1)
        } catch { steering.cancel(); await peer.session.close(); _ = await steering.result; throw error }
    }
}

@Test(.timeLimit(.minutes(1)))
func museSteeringBoundedLedgerPreservesAcceptedCommandsAndRejectsOverflowBeforeWrite() async throws {
    try await withMuseSteering(["observeSteer": .bool(false)]) { peer in
        let thread = try await peer.start(), native = try #require(thread.activeRun?.nativeTurnID)
        for index in 0..<128 {
            _ = try await peer.session.steer(input: .init(text: "Bounded input \(index)"), thread: thread,
                expectedTurnID: native, clientMessageID: "bounded-\(index)")
        }
        #expect(await peer.session.steeringCapabilities().supportsActiveSteering == false)
        await #expect(throws: ProviderSteeringError(.rejected)) {
            try await peer.session.steer(input: .init(text: "Overflow input"), thread: thread,
                expectedTurnID: native, clientMessageID: "over-limit")
        }
        let records = try peer.fixture.rows("steer")
        #expect(records.count == 128 && Set(records.compactMap { $0["commandId"].string }).count == 128)
        #expect(await peer.observed.failures.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func museSteeringLegacyAdapterEngineKeepsAuthorAttributionAndCapturedFIFOThroughRealNativeTerminalAndStop() async throws {
    let fixture = try MuseSessionFixture(options: ["observeSteer": .bool(true), "holdSteerReply": .bool(true),
        "steerLateError": .bool(true), "background": .bool(true), "holdInterruptTerminal": .bool(true)], resource: "muse_steering_server")
    let database = fixture.root.appendingPathComponent("workspace.sqlite")
    let engine = try WorkspaceEngine(url: database, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
    do {
        let project = WorkspaceProject(path: fixture.root.path)
        var seed = CodingThread(project: project)
        seed.provider = .muse; seed.permission = .supervised; seed.checkpointPolicy = .disabled
        seed.museConfiguration = .init(executable: fixture.executable.path)
        let threadID = seed.id
        try await saveLegacyProviderFixture(project: project, threads: [seed], at: database)
        _ = try await engine.load()
        try await engine.dispatch(.submit(threadID: threadID, text: "Root native Muse input"))
        try await museEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == threadID }
            return current?.activeRun?.nativeTurnID != nil && current?.messages.contains { $0.text == "Exact 日本語\u{2028}answer" } == true
        }
        let firstUpdate = await engine.current()
        let first = try #require(firstUpdate.snapshot.threads.first { $0.id == threadID }), run = try #require(first.activeRun)
        let native = try #require(run.nativeTurnID)
        let selection = MuseModelSelection(modelID: "selected-model")
        let efforts = [ProviderReasoningEffortOption(id: "low", description: "Low"), .init(id: "high", description: "High")]
        let model = ProviderModel(id: selection.catalogID, name: "Selected", reasoningEfforts: efforts, defaultReasoningEffort: "high",
            museSelection: selection, museReasoningEfforts: efforts, museDefaultReasoningEffort: "high")
        try await engine.dispatch(.editThread(threadID, .museModel(model)))
        try await engine.dispatch(.editThread(threadID, .museReasoning(model: model, effort: "high")))
        try await engine.dispatch(.submit(threadID: threadID, text: "Captured queued Muse input"))
        try await engine.dispatch(.editThread(threadID, .museReasoning(model: model, effort: "low")))
        let availability = await engine.promptSteeringAvailability(threadID: threadID)
        #expect(availability.canSteer && availability.runID == run.id)
        try await engine.steerPrompt(threadID: threadID, text: "Author-owned Muse steer 日本語", expectedRunID: run.id)
        try await museEventually {
            let update = await engine.current(), current = update.snapshot.threads.first { $0.id == threadID }
            return update.snapshot.promptSteerings?.last?.phase == .delivered &&
                current?.messages.contains { $0.text == "Steered original output 日本語" } == true
        }
        let heldUpdate = await engine.current()
        let held = try #require(heldUpdate.snapshot.threads.first { $0.id == threadID })
        #expect(held.activeRun?.id == run.id && held.activeRun?.nativeTurnID == native)
        #expect(held.activeRun?.configuration.museConfiguration?.model == nil)
        #expect(held.queuedTurns.map(\.text) == ["Captured queued Muse input"])
        #expect(held.queuedTurns.first?.configuration.museConfiguration?.reasoningEffort == "high")
        #expect(held.museConfiguration?.reasoningEffort == "low")
        #expect(try fixture.rows("prompt").count == 1, "A steering ACK or durable userMessage never completes the original native turn.")
        let operation = try #require(heldUpdate.snapshot.promptSteerings?.last)
        #expect(operation.configuration == run.configuration && operation.receipt?.turnID == native)
        let authored = held.messages.filter { $0.role == .user && $0.text == "Author-owned Muse steer 日本語" }
        #expect(authored.count == 1 && authored.first?.runReference?.runID == run.id && authored.first?.promptSteeringID == operation.id)
        let steerRows = try fixture.rows("steer")
        let nativeSteer = try #require(steerRows.last)
        #expect(nativeSteer["model"] == .string("native-default") && nativeSteer["extraControls"] == .bool(false))
        try fixture.set("background", .bool(false))
        try fixture.signal("finish")
        try await museEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == threadID }
            return (try? fixture.rows("prompt").count) == 2 && current?.activeRun?.id != nil &&
                current?.activeRun?.id != run.id && current?.activeRun?.nativeTurnID != nil
        }
        try fixture.set("holdSteerReply", .bool(false)); try fixture.signal("childFinish")
        try await museEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == threadID }
            return current?.messages.contains { $0.text.contains("Original child result") } == true
        }
        let successorUpdate = await engine.current()
        let successor = try #require(successorUpdate.snapshot.threads.first { $0.id == threadID })
        let child = try #require(successor.messages.first { $0.text.contains("Original child result") })
        #expect(child.runReference?.runID == run.id)
        #expect(successor.activeRun?.configuration.museConfiguration?.reasoningEffort == "high")
        #expect(successor.museConfiguration?.reasoningEffort == "low" && successorUpdate.error == nil)
        let prompts = try fixture.rows("prompt")
        #expect(prompts.map { $0["model"].string } == ["native-default", "selected-model"])
        #expect(prompts.map { $0["effort"].string } == ["low", "high"])
        #expect(try fixture.rows("steer").count == 1)
        try await engine.dispatch(.interrupt(threadID: threadID))
        try await museEventually { try fixture.rows("interrupt").count == 1 }
        let interruptRows = try fixture.rows("interrupt")
        let interrupt = try #require(interruptRows.last)
        #expect(interrupt["turnId"] == .string(successor.activeRun!.nativeTurnID!) && interrupt["exact"] == .bool(true))
        let stopping = await engine.current()
        #expect(stopping.snapshot.threads.first { $0.id == threadID }?.activeRun?.id == successor.activeRun?.id)
        try fixture.signal("cancelled")
        try await museEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == threadID }
            return current?.activeRun == nil && current?.state == .interrupted
        }
        let finalUpdate = await engine.current(), final = try #require(finalUpdate.snapshot.threads.first { $0.id == threadID })
        #expect(final.runHistory?.map(\.status) == [.completed, .interrupted] && final.queuePaused)
        #expect(final.runHistory?.first?.turnIDs == [native])
        #expect(!String(decoding: try JSONEncoder().encode(finalUpdate.snapshot), as: UTF8.self).contains("synthetic-private-token"))
        await engine.shutdown(); try await museEventually { fixture.parentsStopped }
        let replay = try await WorkspaceDatabase(url: database).rebuildProjection().snapshot
        let restored = try #require(replay.threads.first { $0.id == threadID })
        #expect(restored.messages == final.messages && restored.runHistory == final.runHistory)
        #expect(try fixture.rows("prompt").count == 2)
        try fixture.removeIfStopped()
    } catch { await engine.shutdown(); try? fixture.removeIfStopped(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func museSteeringLegacyAdapterEngineUnknownNativeTargetACKKeepsInputUnconfirmedAndPausesFIFOWithoutReplay() async throws {
    let fixture = try MuseSessionFixture(options: ["observeSteer": .bool(false), "wrongSteerTurn": .bool(true)], resource: "muse_steering_server")
    let engine = try WorkspaceEngine(url: fixture.root.appendingPathComponent("workspace.sqlite"), providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
    do {
        let project = WorkspaceProject(path: fixture.root.path)
        var seed = CodingThread(project: project)
        seed.provider = .muse; seed.museConfiguration = .init(executable: fixture.executable.path); seed.checkpointPolicy = .disabled
        let threadID = seed.id
        try await saveLegacyProviderFixture(project: project, threads: [seed], at: fixture.root.appendingPathComponent("workspace.sqlite"))
        _ = try await engine.load()
        try await engine.dispatch(.submit(threadID: threadID, text: "Original before unknown steering"))
        try await museEventually { await engine.current().snapshot.threads.first { $0.id == threadID }?.activeRun?.nativeTurnID != nil }
        let before = await engine.current(), runID = try #require(before.snapshot.threads.first { $0.id == threadID }?.activeRun?.id)
        try await engine.dispatch(.submit(threadID: threadID, text: "Queued input must not be resent"))
        try await engine.steerPrompt(threadID: threadID, text: "Uncertain exact-native target", expectedRunID: runID)
        try await museEventually {
            let update = await engine.current(), thread = update.snapshot.threads.first { $0.id == threadID }
            return update.snapshot.promptSteerings?.last?.phase == .unconfirmed && thread?.queuePaused == true
        }
        let update = await engine.current(), thread = try #require(update.snapshot.threads.first { $0.id == threadID })
        #expect(thread.queuedTurns.map(\.text) == ["Queued input must not be resent"])
        #expect(thread.messages.filter { $0.role == .user && $0.text == "Uncertain exact-native target" }.count == 1)
        #expect(update.error == nil)
        let prompts = try fixture.rows("prompt"), steers = try fixture.rows("steer")
        #expect(prompts.count == 1 && steers.count == 1)
        await engine.shutdown(); try await museEventually { fixture.parentsStopped }; try fixture.removeIfStopped()
    } catch { await engine.shutdown(); try? fixture.removeIfStopped(); throw error }
}
