import Darwin
import Foundation
import Testing
@testable import CoincideCore

@Test func contextHandoffPiPreparedNativeInputProvesBothAuthoredAndProviderFacingDigests() async throws {
    try await withPiHistory { peer in
        let input = try contextHandoffTestInput(), initial = peer.thread(text: input.text)
        let preparation = try await peer.session.preparePiRun(input: input, thread: initial)
        let contextual = try #require(preparation.openingInput.contextualInput)
        #expect(contextual.authoredDigest == (try PiHistoryInputEvidence.digest(.init(text: input.text))))
        #expect(contextual.nativeDigest == (try PiHistoryInputEvidence.digest(.init(text: input.providerText()))))
        #expect(contextual.authoredDigest != contextual.nativeDigest)
        #expect(try peer.frames().filter { $0["type"] == .string("prompt") }.isEmpty)
        var committed = try peer.committing(preparation, to: initial)
        let context = try #require(input.historicalContext)
        let delivery = ContextTransferDelivery(id: context.deliveryID, runID: preparation.runID, transferIDs: context.transferIDs,
            selection: context.selection, status: .dispatching, runtimeID: nil, nativeThreadID: preparation.nativeSessionFile, error: nil)
        committed.runHistory?[0].contextTransferIDs = context.transferIDs; committed.runHistory?[0].contextDelivery = delivery
        committed.activeRun?.contextTransferIDs = context.transferIDs; committed.activeRun?.contextDelivery = delivery
        try await peer.session.sendPreparedPi(input: input, thread: committed, preparation: preparation)
        try await piHistoryEventually { await peer.observed.started.contains(preparation.runID) }
        try peer.signal("finish")
        try await piHistoryEventually { await peer.observed.completions.count == 1 }
        let proof = try #require(await peer.observed.evidence.first)
        #expect(proof.captureStatus == .proven && proof.inputs.first?.contextualInput == contextual)
        #expect(proof.inputs.first?.inputDigest == contextual.authoredDigest && proof.inputs.first?.nativeInputDigest == contextual.nativeDigest)
        let prompt = try #require(peer.frames().first { $0["type"] == .string("prompt") })
        #expect(prompt["message"] == .string(try input.providerText()))
        #expect(committed.messages[0].text.utf8.elementsEqual(input.text.utf8))
    }
}

private actor PiHistoryEvents {
    var evidence: [PiRunHistoryEvidence] = []
    var completions: [(UUID?, ThreadState)] = []
    var sequence: [String] = []
    var turnIDs: [String] = []
    var failures = 0
    var started = Set<UUID>()
    func terminalOrFailureObserved() -> Bool { !completions.isEmpty || failures > 0 }
    func receive(_ event: ProviderEvent, owner: UUID? = nil) {
        switch event {
        case .context(let id, let nested): receive(nested, owner: id)
        case .piHistoryEvidence(let proof): evidence.append(proof); sequence.append("proof")
        case .completed(let state): completions.append((owner, state)); sequence.append("completed")
        case .turn(let id): turnIDs.append(id)
        case .entity: if let owner { started.insert(owner) }
        case .connectionClosed, .failure: failures += 1
        default: break
        }
    }
}

private struct PiHistoryPeer {
    let root: URL
    let executable: URL
    let configuration: PiConfiguration
    let session: PiSession
    let observed = PiHistoryEvents()
    init(options: [String: JSONValue] = [:]) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-history-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        root = URL(fileURLWithPath: try PiRuntimeConfiguration.physical(folder.path))
        executable = root.appendingPathComponent("pi-peer")
        let fixture = try #require(Bundle.module.url(forResource: "pi_history_rpc_server", withExtension: "py", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try JSONEncoder().encode(JSONValue.object(options)).write(to: root.appendingPathComponent("options.json"), options: .atomic)
        let id = UUID()
        let runtime = try PiRuntimeConfiguration.capture(workspacePath: root.path, executable: executable.path,
            instanceID: id, environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"])
        configuration = .init(instanceID: id, executable: executable.path, runtime: runtime)
        session = .init(executable: executable, cwd: root, configuration: configuration)
    }
    func thread(text: String = "original input", model: PiModelSelection? = nil) -> CodingThread {
        var thread = CodingThread(project: .init(path: root.path))
        thread.workspacePath = root.path; thread.provider = .pi
        thread.piConfiguration = configuration.selecting(model: model); thread.model = model?.catalogID ?? ""
        thread.permission = .supervised; thread.checkpointPolicy = .disabled
        let id = UUID(), messageID = "user-\(id.uuidString.lowercased())"
        thread.activeRun = .init(id: id, configuration: .init(thread: thread), startedAt: .now)
        thread.messages = [.init(id: messageID, role: .user, text: text)]
        thread.beginRunRecord(thread.activeRun!, origin: .user, userMessageID: messageID)
        return thread
    }
    func committing(_ preparation: PiRunHistoryPreparation, to thread: CodingThread) throws -> CodingThread {
        var thread = thread
        thread.providerThreadID = preparation.nativeSessionFile
        thread.runHistory![0].providerThreadID = preparation.nativeSessionFile
        thread.runHistory![0].pi = try .init(preparation: preparation)
        return thread
    }
    func frames() throws -> [JSONValue] {
        let path = root.appendingPathComponent("wire.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let bytes = try Data(contentsOf: path)
        guard let end = bytes.lastIndex(of: 10) else { return [] }
        return try bytes[...end].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func set(_ key: String, _ value: JSONValue) throws {
        let path = root.appendingPathComponent("options.json")
        var object = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: path)).object ?? [:]
        object[key] = value; try JSONEncoder().encode(JSONValue.object(object)).write(to: path, options: .atomic)
    }
    func signal(_ name: String) throws { try set("signal", .object(["id": .string(UUID().uuidString), "name": .string(name)])) }
}

private func withPiHistory(_ options: [String: JSONValue] = [:], _ action: (PiHistoryPeer) async throws -> Void) async throws {
    let peer = try PiHistoryPeer(options: options)
    let reader = Task { for await event in peer.session.events { await peer.observed.receive(event) } }
    do {
        try await action(peer)
        await peer.session.close(); await reader.value
        try assertPiHistoryParentsExited(peer)
        try FileManager.default.removeItem(at: peer.root)
    } catch {
        await peer.session.close(); await reader.value
        try? FileManager.default.removeItem(at: peer.root); throw error
    }
}
private func piHistoryEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(6)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private Pi history peer did not reach its owned boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func assertPiHistoryParentsExited(_ peer: PiHistoryPeer) throws {
    for row in try peer.frames() where row["kind"] == .string("launch") {
        guard case .number(let raw) = row["pid"], let pid = Int32(exactly: raw) else { throw PiHistoryGraphError(.invalidGraph) }
        #expect(kill(pid, 0) != 0 && errno == ESRCH)
    }
}

@Test func piRuntimeImmutableStoragePreservesFlatCodableContentIdentityAndIndependentRebinding() throws {
    let instanceID = UUID()
    let original = try PiRuntimeConfiguration(instanceID: instanceID, executable: "/fixture/bin/pi", requestedExecutable: "pi",
        workspacePath: "/fixture/workspace", registeredWorkspacePath: "/fixture/workspace-alias/", homeDirectory: "/fixture/home",
        agentDirectory: "/fixture/home/.pi/agent", agentDirectorySelection: .defaultHome(homeDirectory: "/fixture/home"))
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    let originalBytes = try encoder.encode(original)
    let originalJSON = try decoder.decode(JSONValue.self, from: originalBytes)
    let expected: [String: JSONValue] = [
        "instanceID": .string(instanceID.uuidString), "requestedExecutable": .string("pi"), "executable": .string("/fixture/bin/pi"),
        "workspacePath": .string("/fixture/workspace"), "registeredWorkspacePath": .string("/fixture/workspace-alias/"),
        "homeDirectory": .string("/fixture/home"), "agentDirectory": .string("/fixture/home/.pi/agent"),
        "agentDirectorySelection": .object(["defaultHome": .object(["homeDirectory": .string("/fixture/home")])]),
        "sessionDirectorySelection": .object(["nativeConfigured": .object([:])]), "profile": .string("settledEntriesV3")
    ]
    #expect(originalJSON == .object(expected)) // The optional session directory stays omitted; no storage wrapper is encoded.
    let independentlyDecoded = try decoder.decode(PiRuntimeConfiguration.self, from: originalBytes)
    #expect(independentlyDecoded == original && Set([original, independentlyDecoded]).count == 1)
    #expect([original: "retained"][independentlyDecoded] == "retained")

    let explicit = try PiRuntimeConfiguration(instanceID: instanceID, executable: original.executable, requestedExecutable: original.requestedExecutable,
        workspacePath: original.workspacePath, registeredWorkspacePath: original.registeredWorkspacePath, homeDirectory: original.homeDirectory,
        agentDirectory: "/fixture/agent-target", agentDirectorySelection: .explicitDirectory(environmentPath: "~/agent-alias/"),
        sessionDirectory: "/fixture/session-target", sessionDirectorySelection: .explicitDirectory(environmentPath: "~/session-alias/"))
    let explicitBytes = try encoder.encode(explicit)
    let explicitJSON = try decoder.decode(JSONValue.self, from: explicitBytes)
    var expectedExplicit = expected
    expectedExplicit["agentDirectory"] = .string("/fixture/agent-target")
    expectedExplicit["agentDirectorySelection"] = .object(["explicitDirectory": .object(["environmentPath": .string("~/agent-alias/")])])
    expectedExplicit["sessionDirectory"] = .string("/fixture/session-target")
    expectedExplicit["sessionDirectorySelection"] = .object(["explicitDirectory": .object(["environmentPath": .string("~/session-alias/")])])
    #expect(explicitJSON == .object(expectedExplicit))
    let explicitDecoded = try decoder.decode(PiRuntimeConfiguration.self, from: explicitBytes)
    #expect(explicitDecoded == explicit && Set([original, explicit, explicitDecoded]).count == 2)
    for (key, value) in [
        "instanceID": JSONValue.string(UUID().uuidString), "requestedExecutable": .string("other-pi"), "executable": .string("/fixture/bin/other-pi"),
        "workspacePath": .string("/fixture/other-workspace"), "registeredWorkspacePath": .string("/fixture/other-alias/"),
        "homeDirectory": .string("/fixture/other-home"), "agentDirectory": .string("/fixture/other-agent"),
        "agentDirectorySelection": .object(["explicitDirectory": .object(["environmentPath": .string("~/other-agent/")])]),
        "sessionDirectory": .string("/fixture/other-session"),
        "sessionDirectorySelection": .object(["explicitDirectory": .object(["environmentPath": .string("~/other-session/")])])
    ] {
        var changedJSON = expectedExplicit; changedJSON[key] = value
        let changedBytes = try encoder.encode(JSONValue.object(changedJSON))
        let changed = try decoder.decode(PiRuntimeConfiguration.self, from: changedBytes)
        #expect(changed != explicit && Set([changed, explicit]).count == 2)
    }
    let retainedCopy = original
    let rebound = try original.replacingWorkspace("/fixture/new-alias/", physicalPath: "/fixture/new-workspace")
    #expect(original == retainedCopy && original.workspacePath == "/fixture/workspace")
    #expect(rebound.workspacePath == "/fixture/new-workspace" && rebound.registeredWorkspacePath == "/fixture/new-alias/")
    #expect(rebound.instanceID == original.instanceID && rebound.agentDirectorySelection == original.agentDirectorySelection)
    #expect(rebound != original && Set([original, retainedCopy, rebound]).count == 2)
}

@Test func piRuntimeCapturePreservesDefaultNamespaceExplicitAliasAndRegisteredWorkspaceWithoutFoundationCanonicalGuess() throws {
    let peer = try PiHistoryPeer(); defer { try? FileManager.default.removeItem(at: peer.root) }
    let runtime = try #require(peer.configuration.runtime)
    let normal = try runtime.environment(from: ["PI_CODING_AGENT_DIR": "/foreign", "PI_CODING_AGENT_SESSION_DIR": "/foreign"])
    #expect(normal["HOME"] == peer.root.path && normal["PI_CODING_AGENT_DIR"] == nil && normal["PI_CODING_AGENT_SESSION_DIR"] == nil)
    let target = peer.root.appendingPathComponent("agent-target"), alias = peer.root.appendingPathComponent("agent-alias")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    let raw = alias.path + "/"
    let explicit = try PiRuntimeConfiguration.capture(workspacePath: peer.root.path, executable: peer.executable.path,
        instanceID: runtime.instanceID, environment: ["HOME": peer.root.path, "PI_CODING_AGENT_DIR": raw])
    #expect(explicit.agentDirectory == (try PiRuntimeConfiguration.physical(target.path)))
    #expect(try explicit.environment(from: [:])["PI_CODING_AGENT_DIR"] == raw)
    #expect(try JSONDecoder().decode(PiRuntimeConfiguration.self, from: JSONEncoder().encode(explicit)) == explicit)
    let rebound = try explicit.replacingWorkspace(peer.root.path, physicalPath: runtime.workspacePath)
    #expect(rebound.agentDirectorySelection == explicit.agentDirectorySelection && rebound.executable == explicit.executable)
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: peer.root)
    #expect(throws: (any Error).self) { try explicit.environment(from: [:]) }
}

@Test func piCapturedPrepareWritesNoPromptUntilDurableProofThenCapturesRealLeafBeforeCompletionWithoutNativeTurnIDs() async throws {
    try await withPiHistory { peer in
        let input = ProviderInput(text: "exact 日本語 opening"), initial = peer.thread(text: "exact 日本語 opening")
        let preparation = try await peer.session.preparePiRun(input: input, thread: initial)
        let before = try peer.frames()
        #expect(before.filter { $0["type"] == .string("prompt") }.isEmpty)
        #expect(preparation.baseline.entries.isEmpty && preparation.baseline.leafID == nil)
        #expect(!FileManager.default.fileExists(atPath: preparation.nativeSessionFile))
        let committed = try peer.committing(preparation, to: initial)
        try await peer.session.sendPreparedPi(input: input, thread: committed, preparation: preparation)
        try await piHistoryEventually { await peer.observed.started.contains(preparation.runID) }
        try peer.signal("endOnly")
        try await piHistoryEventually { try peer.frames().contains { $0["kind"] == .string("signal") && $0["name"] == .string("endOnly") } }
        let held = await peer.observed.completions; #expect(held.isEmpty)
        try peer.signal("finish")
        try await piHistoryEventually { await peer.observed.completions.count == 1 }
        let proofs = await peer.observed.evidence, order = await peer.observed.sequence, turns = await peer.observed.turnIDs
        let proof = try #require(proofs.first)
        #expect(proof.captureStatus == .proven && proof.terminalStatus == .completed)
        #expect(proof.inputs.first?.nativeUserEntryID == proof.openingUserEntryID && proof.nativeUserEntryIDs.count == 1)
        #expect(order == ["proof", "completed"] && turns.isEmpty && committed.activeRun?.nativeTurnID == nil)
        let file = try PiHistoryFileReader().read(filePath: preparation.nativeSessionFile, expectedWorkspacePath: preparation.runtimeIdentity.runtime!.workspacePath)
        #expect(file.graph.leafOrigin == .reloadedFile && file.graph.leafID == proof.finalObservation?.leafID)
        let launches = try peer.frames().filter { $0["kind"] == .string("launch") }
        #expect(launches.count == 2 && launches.first?["versionOnly"] == .bool(true))
        #expect(launches.allSatisfy { $0["homeMatches"] == .bool(true) && $0["agentOverride"] == .bool(false) })
    }
}

@Test func piCapturedSendRequiresCommittedExactInputAndUnchangedLiveLeafBeforeAnyPromptWrite() async throws {
    try await withPiHistory { peer in
        let input = ProviderInput(text: "owned input"), thread = peer.thread(text: "owned input", model: .init(provider: "native", modelID: "other"))
        let preparation = try await peer.session.preparePiRun(input: input, thread: thread)
        await #expect(throws: (any Error).self) { try await peer.session.send(input: input, thread: thread) }
        await #expect(throws: (any Error).self) { try await peer.session.sendPreparedPi(input: input, thread: thread, preparation: preparation) }
        let committed = try peer.committing(preparation, to: thread)
        await #expect(throws: (any Error).self) { try await peer.session.sendPreparedPi(input: .init(text: "changed after commit"), thread: committed, preparation: preparation) }
        #expect(preparation.baseline.leafID != nil)
        try peer.signal("moveLeaf")
        try await piHistoryEventually { try peer.frames().contains { $0["kind"] == .string("signal") && $0["name"] == .string("moveLeaf") } }
        await #expect(throws: (any Error).self) { try await peer.session.sendPreparedPi(input: input, thread: committed, preparation: preparation) }
        let frames = try peer.frames(); #expect(frames.filter { $0["type"] == .string("prompt") }.isEmpty)
    }
}

@Test func piCapturedSteeringRequiresDurableInputDigestAndMapsIdenticalTextWithinOneOwnedRun() async throws {
    try await withPiHistory { peer in
        let input = ProviderInput(text: "identical input"), initial = peer.thread(text: "identical input")
        let preparation = try await peer.session.preparePiRun(input: input, thread: initial)
        var thread = try peer.committing(preparation, to: initial)
        try await peer.session.sendPreparedPi(input: input, thread: thread, preparation: preparation)
        try await piHistoryEventually { await peer.observed.started.contains(preparation.runID) }
        let messageID = "user-steering-\(UUID())", target = ProviderSteeringTarget.adapterRun(preparation.runID)
        await #expect(throws: ProviderSteeringError.self) {
            try await peer.session.steer(input: input, thread: thread, target: target, clientMessageID: messageID)
        }
        let reservation = try await peer.session.preparePiSteering(input: input, thread: thread, target: target, clientMessageID: messageID)
        var proof = try #require(thread.runHistory?[0].pi)
        let steering = try PiHistoryInputEvidence.steering(clientMessageID: messageID, input: input)
        try proof.registerSteering(steering); thread.runHistory![0].pi = proof
        let receipt = try await peer.session.sendPreparedPiSteering(input: input, thread: thread, target: target, clientMessageID: messageID, preparation: reservation)
        #expect(receipt.adapterRunID == preparation.runID && receipt.turnID == nil && receipt.delivery == .acknowledged)
        try peer.signal("finish")
        try await piHistoryEventually { await peer.observed.completions.count == 1 }
        let values = await peer.observed.evidence, evidence = try #require(values.first)
        #expect(evidence.captureStatus == .proven && evidence.inputs.map(\.clientMessageID) == [preparation.openingInput.clientMessageID, messageID])
        #expect(evidence.nativeUserEntryIDs.count == 2 && Set(evidence.nativeUserEntryIDs).count == 2)
        #expect(try proof.merging(evidence) == evidence)
        let later = try PiHistoryInputEvidence.steering(clientMessageID: "later-reserved-input", input: .init(text: "not sent"))
        var newer = proof; try newer.registerSteering(later)
        let partial = try newer.merging(evidence)
        #expect(partial.captureStatus == .unavailable && partial.inputs.count == 3 && partial.inputs.allSatisfy { $0.nativeUserEntryID == nil })
        var wrongOwner = newer
        wrongOwner.inputs[1] = try .init(clientMessageID: "changed-owner", inputDigest: steering.inputDigest, kind: .steering)
        #expect(throws: (any Error).self) { try wrongOwner.merging(evidence) }
        var wrongDigest = newer
        wrongDigest.inputs[1] = try .init(clientMessageID: steering.clientMessageID, inputDigest: String(repeating: "f", count: 64), kind: .steering)
        #expect(throws: (any Error).self) { try wrongDigest.merging(evidence) }
        var wrongOrder = newer; wrongOrder.inputs.swapAt(1, 2)
        #expect(throws: (any Error).self) { try wrongOrder.merging(evidence) }
        let otherPreparation = try PiRunHistoryPreparation(runID: UUID(), runtimeIdentity: preparation.runtimeIdentity,
            observedVersion: preparation.observedVersion, openingInput: preparation.openingInput, baseline: preparation.baseline)
        let other = try PiRunHistoryEvidence(preparation: otherPreparation)
        #expect(throws: (any Error).self) { try other.merging(evidence) }
        let frames = try peer.frames(); #expect(frames.filter { $0["type"] == .string("prompt") }.count == 2)
    }
}

@Test func piCanceledAfterDurableSteeringMarkerStillSettlesOriginalAndRetainsUnprovenInputOwner() async throws {
    try await withPiHistory { peer in
        let input = ProviderInput(text: "original before canceled marker"), initial = peer.thread(text: "original before canceled marker")
        let preparation = try await peer.session.preparePiRun(input: input, thread: initial)
        let thread = try peer.committing(preparation, to: initial)
        try await peer.session.sendPreparedPi(input: input, thread: thread, preparation: preparation)
        try await piHistoryEventually { await peer.observed.started.contains(preparation.runID) }
        let reservation = try await peer.session.preparePiSteering(input: .init(text: "never sent"), thread: thread,
            target: .adapterRun(preparation.runID), clientMessageID: "canceled-durable-owner")
        var durable = try #require(thread.runHistory?[0].pi)
        try durable.registerSteering(reservation.input) // Models the committed marker before cancellation.
        await peer.session.cancelPiSteeringPreparation(reservation)
        try await peer.session.interrupt(expectedRunID: preparation.runID)
        try await piHistoryEventually { await peer.observed.terminalOrFailureObserved() }
        let proofs = await peer.observed.evidence, completions = await peer.observed.completions, failures = await peer.observed.failures
        let order = await peer.observed.sequence
        let observed = try #require(proofs.first), merged = try durable.merging(observed)
        #expect(merged.captureStatus == .unavailable && merged.terminalStatus == .interrupted)
        #expect(merged.inputs.map(\.clientMessageID) == durable.inputs.map(\.clientMessageID) && merged.inputs.allSatisfy { $0.nativeUserEntryID == nil })
        #expect(completions.count == 1 && completions.first?.0 == preparation.runID && failures == 0)
        #expect(proofs.count == 1 && observed.runID == preparation.runID && order == ["proof", "completed"])
        let frames = try peer.frames(); #expect(frames.filter { $0["type"] == .string("prompt") }.count == 1)
    }
}

@Test func piCapturedActualSettledProofCanRetireHeldOpeningACKWithoutInventingAWireReceipt() async throws {
    try await withPiHistory(["holdPromptACK": .bool(true)]) { peer in
        let input = ProviderInput(text: "opening with held response"), initial = peer.thread(text: "opening with held response")
        let preparation = try await peer.session.preparePiRun(input: input, thread: initial)
        let thread = try peer.committing(preparation, to: initial)
        let sending = Task { try await peer.session.sendPreparedPi(input: input, thread: thread, preparation: preparation) }
        do {
            try await piHistoryEventually { try peer.frames().contains { $0["kind"] == .string("gate") && $0["name"] == .string("promptACKHeld") } }
            try peer.signal("finish")
            try await piHistoryEventually { await peer.observed.completions.count == 1 }
            try await sending.value
            let proofs = await peer.observed.evidence
            #expect(proofs.first?.captureStatus == .proven)
            // The gate is still held; only actual owned terminal proof retired send.
            let configuration = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: peer.root.appendingPathComponent("options.json")))
            #expect(configuration["holdPromptACK"] == .bool(true))
        } catch { sending.cancel(); _ = await sending.result; throw error }
    }
}

@Test(arguments: [false, true]) func piSteeringReservationInvalidatesHeldTerminalReadAndPreservesExactRunOrCancelsWithoutWriting(_ cancel: Bool) async throws {
    try await withPiHistory { peer in
        let opening = ProviderInput(text: "opening before held final read"), initial = peer.thread(text: "opening before held final read")
        let preparation = try await peer.session.preparePiRun(input: opening, thread: initial)
        var thread = try peer.committing(preparation, to: initial)
        try await peer.session.sendPreparedPi(input: opening, thread: thread, preparation: preparation)
        try await piHistoryEventually { await peer.observed.started.contains(preparation.runID) }
        try peer.set("holdFinalEntries", .bool(true)); try peer.signal("finish")
        try await piHistoryEventually { try peer.frames().contains { $0["kind"] == .string("gate") && $0["name"] == .string("finalEntriesHeld") } }
        let input = ProviderInput(text: "steer after settled but before owned completion"), messageID = "user-held-\(UUID())"
        let target = ProviderSteeringTarget.adapterRun(preparation.runID)
        let reservation = try await peer.session.preparePiSteering(input: input, thread: thread, target: target, clientMessageID: messageID)
        let held = await peer.observed.completions; #expect(held.isEmpty)
        if cancel { await peer.session.cancelPiSteeringPreparation(reservation) }
        else {
            var proof = try #require(thread.runHistory?[0].pi)
            try proof.registerSteering(reservation.input); thread.runHistory![0].pi = proof
            _ = try await peer.session.sendPreparedPiSteering(input: input, thread: thread, target: target, clientMessageID: messageID, preparation: reservation)
        }
        try peer.set("holdFinalEntries", .bool(false))
        if !cancel { try peer.signal("finish") }
        try await piHistoryEventually { await peer.observed.completions.count == 1 }
        let proofs = await peer.observed.evidence, completions = await peer.observed.completions
        let proof = try #require(proofs.first)
        #expect(proof.captureStatus == .proven && proof.runID == preparation.runID && proof.nativeUserEntryIDs.count == (cancel ? 1 : 2))
        #expect(completions.first?.0 == preparation.runID)
        let frames = try peer.frames(); #expect(frames.filter { $0["type"] == .string("prompt") }.count == (cancel ? 1 : 2))
    }
}

@Test(arguments: [false, true]) func piCapturedRewrittenOrUnownedNativeInputsNeverBecomeStrongRunEvidence(_ unowned: Bool) async throws {
    try await withPiHistory(unowned ? [:] : ["rewriteInput": .bool(true)]) { peer in
        let input = ProviderInput(text: "owned input"), initial = peer.thread(text: "owned input")
        let preparation = try await peer.session.preparePiRun(input: input, thread: initial)
        let thread = try peer.committing(preparation, to: initial)
        try await peer.session.sendPreparedPi(input: input, thread: thread, preparation: preparation)
        if unowned {
            try peer.signal("unownedUser")
            try await piHistoryEventually { try peer.frames().contains { $0["name"] == .string("unownedUser") } }
        }
        try peer.signal("finish")
        try await piHistoryEventually { await peer.observed.completions.count == 1 }
        let values = await peer.observed.evidence, proof = try #require(values.first)
        #expect(proof.captureStatus == .unavailable && proof.nativeUserEntryIDs.isEmpty && proof.inputs.allSatisfy { $0.nativeUserEntryID == nil })
    }
}

@Test func piCapturedStopPublishesExactInterruptedHistoryProofAndAnOldVersionNeverStartsRPC() async throws {
    try await withPiHistory { peer in
        let input = ProviderInput(text: "stop owned input"), initial = peer.thread(text: "stop owned input")
        let preparation = try await peer.session.preparePiRun(input: input, thread: initial)
        let thread = try peer.committing(preparation, to: initial)
        try await peer.session.sendPreparedPi(input: input, thread: thread, preparation: preparation)
        try await piHistoryEventually { await peer.observed.started.contains(preparation.runID) }
        try await peer.session.interrupt(expectedRunID: preparation.runID)
        try await piHistoryEventually { await peer.observed.terminalOrFailureObserved() }
        let evidence = await peer.observed.evidence, completions = await peer.observed.completions
        let order = await peer.observed.sequence, failures = await peer.observed.failures
        #expect(evidence.first?.terminalStatus == .interrupted && completions.count == 1 && completions.first?.1 == .interrupted)
        #expect(evidence.count == 1 && evidence.first?.runID == preparation.runID && completions.first?.0 == preparation.runID && failures == 0)
        #expect(order == ["proof", "completed"])
        let frames = try peer.frames(); #expect(frames.contains { $0["type"] == .string("abort") } && frames.contains { $0["type"] == .string("clear_queue") })
    }
    try await withPiHistory(["version": .string("0.80.3")]) { peer in
        await #expect(throws: (any Error).self) { try await peer.session.preparePiRun(input: .init(text: "no send"), thread: peer.thread()) }
        let frames = try peer.frames(); #expect(frames.count == 1 && frames[0]["versionOnly"] == .bool(true))
    }
}

