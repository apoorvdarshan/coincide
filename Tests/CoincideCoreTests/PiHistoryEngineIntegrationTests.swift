import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct PiPreparedEngineTrace: Sendable {
    var prepares = 0
    var preparedSendInvocations = 0
    var promptWrites = 0
    var legacySends = 0
    var interrupts = 0
    var closes = 0
    var preparation: PiRunHistoryPreparation?
    var beforePrompt: ThreadRunRecord?
    var steeringWrites: [PiHistoryInputEvidence] = []
    var steeringPreparationCalls = 0
    var preparedSteeringSendInvocations = 0
    var unpreparedSteeringCalls = 0
    var steeringReservations: [PiSteeringHistoryPreparation] = []
    var canceledSteeringReservationIDs: [UUID] = []
    var inputsBeforeSteeringReservation: [PiHistoryInputEvidence] = []
    var durableSteeringInputs: [PiHistoryInputEvidence] = []
}

/// A native actor stand-in, not an alternative Engine. Every simulated prompt
/// independently reads SQLite and refuses to write before the exact durable
/// preparation/steering marker has committed. No process or provider is used.
private actor PiPreparedEnginePeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private let databaseURL: URL
    private let runtime: PiRuntimeConfiguration
    private let mode: String
    private let baselineRows: [JSONValue]
    private let baseline: PiRuntimeEntryObservation
    private let nativeFile: URL
    private var trace = PiPreparedEngineTrace()
    private var preparingRunID: UUID?
    private var activeRunID: UUID?
    private var preparedInput: ProviderInput?
    private var steeringProviderInputs: [ProviderInput] = []
    private var holdWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var closed = false
    private var finalEvidence: PiRunHistoryEvidence?
    private var latestObservation: PiRuntimeEntryObservation
    private var latestRows: [JSONValue]
    private var steeringReservation: PiSteeringHistoryPreparation?
    private var steeringReservationWaiter: CheckedContinuation<Void, Never>?
    private var steeringReservationReleased = false

    init(databaseURL: URL, runtime: PiRuntimeConfiguration, nativeDirectory: URL, mode: String) throws {
        self.databaseURL = databaseURL; self.runtime = runtime; self.mode = mode
        (events, sink) = AsyncStream.makeStream()
        let sessionID = "pi-native-" + UUID().uuidString.lowercased()
        nativeFile = nativeDirectory.appendingPathComponent(sessionID + ".jsonl")
        baselineRows = [
            .object(["type": .string("model_change"), "id": .string("baseline-model"), "parentId": .null,
                "timestamp": .string("2026-10-23T00:00:00.000Z"), "provider": .string("fixture"), "modelId": .string("mock-model")]),
            Self.message(id: "baseline-assistant", parent: "baseline-model", role: "assistant", text: "Earlier native context")]
        baseline = try .init(nativeSessionFile: nativeFile.path, nativeSessionID: sessionID,
            leafID: "baseline-assistant", entries: baselineRows.map { PiHistoryEntryDescriptor(try PiHistoryEntry(raw: $0)) })
        latestObservation = baseline; latestRows = baselineRows
        let header: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(sessionID),
            "cwd": .string(runtime.workspacePath), "timestamp": .string("2026-10-23T00:00:00.000Z")])
        var bytes = Data()
        for value in [header] + baselineRows { bytes.append(try JSONEncoder().encode(value)); bytes.append(10) }
        try bytes.write(to: nativeFile, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nativeFile.path)
    }
    func models() -> [ProviderModel] { [] }
    func observations() -> PiPreparedEngineTrace { trace }
    func releasePreparation() { released = true; let saved = holdWaiter; holdWaiter = nil; saved?.resume() }
    func releaseSteeringReservation() {
        steeringReservationReleased = true
        let saved = steeringReservationWaiter; steeringReservationWaiter = nil; saved?.resume()
    }
    func preparePiRun(input: ProviderInput, thread: CodingThread) async throws -> PiRunHistoryPreparation {
        trace.prepares += 1
        guard let run = thread.activeRun, let captured = run.configuration.piConfiguration,
              captured.runtime == runtime,
              let clientID = thread.runHistory?.first(where: { $0.id == run.id })?.userMessageID else {
            throw CoincideError("The fake Pi preparation did not receive its prospective input owner.")
        }
        preparingRunID = run.id
        if activeRunID == nil { finalEvidence = nil }
        let digest = try PiHistoryInputEvidence.digest(mode == "input" ? ProviderInput(text: "Different unsent input") : input)
        let opening = try PiHistoryInputEvidence(clientMessageID: mode == "client" ? "foreign-client-owner" : clientID,
            inputDigest: digest, kind: .opening)
        var identity = captured.runtimeIdentity
        if mode == "runtime" {
            let other = try PiRuntimeConfiguration(instanceID: UUID(), executable: runtime.executable,
                requestedExecutable: runtime.requestedExecutable, workspacePath: runtime.workspacePath,
                registeredWorkspacePath: runtime.registeredWorkspacePath, homeDirectory: runtime.homeDirectory,
                agentDirectory: runtime.agentDirectory, agentDirectorySelection: runtime.agentDirectorySelection)
            identity = .init(instanceID: other.instanceID, executable: other.requestedExecutable, runtime: other)
        }
        let preparation = try PiRunHistoryPreparation(runID: mode == "run" ? UUID() : run.id,
            runtimeIdentity: identity, observedVersion: "0.80.5", openingInput: opening, baseline: latestObservation)
        trace.preparation = preparation
        if mode == "held", !released { await withCheckedContinuation { holdWaiter = $0 } }
        // Deliberately return even if canceled: Engine must fence the late
        // result against Stop/removal/incarnation before entering sendPreparedPi.
        return preparation
    }
    func sendPreparedPi(input: ProviderInput, thread: CodingThread, preparation: PiRunHistoryPreparation) async throws {
        trace.preparedSendInvocations += 1
        let database = try WorkspaceDatabase(url: databaseURL)
        let snapshot = try await database.load()
        guard !closed, let run = thread.activeRun,
              let durable = snapshot.threads.first(where: { $0.id == thread.id }),
              durable.runtimeID != nil, durable.activeRun?.id == run.id,
              durable.activeRun?.stopRequested == false,
              let record = durable.runHistory?.first(where: { $0.id == run.id }),
              record.configuration == run.configuration, record.pi?.preparation == preparation,
              record.pi?.captureStatus == .prepared,
              record.userMessageID == preparation.openingInput.clientMessageID,
              preparation.inputDigest == (try PiHistoryInputEvidence.digest(input)) else {
            throw CoincideError("A fake Pi prompt reached the adapter before its exact SQLite preparation.")
        }
        trace.beforePrompt = record; trace.promptWrites += 1
        activeRunID = run.id; preparedInput = input
        sink.yield(.context(runID: run.id, event: .thread(preparation.nativeSessionFile)))
        sink.yield(.context(runID: run.id, event: .message(.init(id: "pi-prepared-marker-" + run.id.uuidString,
            role: .assistant, text: "Pi prompt admitted after durable preparation"))))
    }
    func send(text: String, thread: CodingThread) {
        trace.legacySends += 1
        guard let run = thread.activeRun else { return }
        activeRunID = run.id
        sink.yield(.context(runID: run.id, event: .thread(nativeFile.path)))
        sink.yield(.context(runID: run.id, event: .message(.init(role: .assistant, text: "Legacy Pi send path"))))
    }
    func steeringCapabilities() -> ProviderSteeringCapabilities {
        guard let activeRunID, !closed, finalEvidence == nil else { return .init() }
        return .init(supportsActiveSteering: true, interruptsTools: false, target: .adapterRun(activeRunID))
    }
    func preparePiSteering(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget,
                           clientMessageID: String) async throws -> PiSteeringHistoryPreparation {
        trace.steeringPreparationCalls += 1
        let expected = try PiHistoryInputEvidence.steering(clientMessageID: clientMessageID, input: input)
        let snapshot = try await WorkspaceDatabase(url: databaseURL).load()
        guard let runID = activeRunID, !closed, finalEvidence == nil, target == .adapterRun(runID),
              let owner = snapshot.threads.first(where: { $0.id == thread.id }), owner.activeRun?.id == runID,
              let evidence = owner.runHistory?.first(where: { $0.id == runID })?.pi,
              evidence.captureStatus == .prepared, !evidence.inputs.contains(expected),
              snapshot.promptSteerings?.contains(where: {
                  $0.runID == runID && $0.messageID == clientMessageID && $0.phase == .accepted
              }) == true else { throw ProviderSteeringError(.staleTarget) }
        trace.inputsBeforeSteeringReservation = evidence.inputs
        if mode == "reservation-refused" { throw ProviderSteeringError(.rejected) }
        if mode == "late-reservation", !steeringReservationReleased {
            await withCheckedContinuation { steeringReservationWaiter = $0 }
        }
        guard !closed, activeRunID == runID, finalEvidence == nil else { throw ProviderSteeringError(.staleTarget) }
        let token = try PiSteeringHistoryPreparation(runID: runID, runPreparationID: evidence.preparation.id,
            runtimeIdentity: evidence.runtimeIdentity, input: expected)
        steeringReservation = token; trace.steeringReservations.append(token)
        return token
    }
    func sendPreparedPiSteering(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget,
                                clientMessageID: String, preparation: PiSteeringHistoryPreparation) async throws -> ProviderSteeringReceipt {
        trace.preparedSteeringSendInvocations += 1
        let expected = try PiHistoryInputEvidence.steering(clientMessageID: clientMessageID, input: input)
        guard steeringReservation == preparation, preparation.input == expected,
              preparation.runID == activeRunID, preparation.runPreparationID == trace.preparation?.id,
              preparation.runtimeIdentity == trace.preparation?.runtimeIdentity else { throw ProviderSteeringError(.staleTarget) }
        let receipt = try await writeSteering(input: input, thread: thread, target: target, clientMessageID: clientMessageID)
        steeringReservation = nil
        return receipt
    }
    func cancelPiSteeringPreparation(_ preparation: PiSteeringHistoryPreparation) {
        trace.canceledSteeringReservationIDs.append(preparation.id)
        if steeringReservation == preparation { steeringReservation = nil }
    }
    func steer(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget,
               clientMessageID: String) throws -> ProviderSteeringReceipt {
        trace.unpreparedSteeringCalls += 1
        throw ProviderSteeringError(.unsupported)
    }
    private func writeSteering(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget,
               clientMessageID: String) async throws -> ProviderSteeringReceipt {
        let expected = try PiHistoryInputEvidence.steering(clientMessageID: clientMessageID, input: input)
        let snapshot = try await WorkspaceDatabase(url: databaseURL).load()
        guard !closed, let runID = activeRunID, target == .adapterRun(runID),
              thread.activeRun?.id == runID,
              let owner = snapshot.threads.first(where: { $0.id == thread.id }), owner.activeRun?.id == runID,
              let record = owner.runHistory?.first(where: { $0.id == runID }),
              let evidence = record.pi, evidence.captureStatus == .prepared, evidence.inputs.contains(expected),
              snapshot.promptSteerings?.contains(where: {
                  $0.runID == runID && $0.messageID == clientMessageID && $0.phase == .dispatching
              }) == true else {
            throw CoincideError("A fake Pi steering write preceded its exact durable input marker.")
        }
        trace.durableSteeringInputs = evidence.inputs
        trace.steeringWrites.append(expected); steeringProviderInputs.append(input)
        return try .init(target: target)
    }
    func publishFinalEvidence() throws -> PiRunHistoryEvidence {
        guard let preparation = trace.preparation, let input = preparedInput, let runID = activeRunID,
              preparation.runID == runID, finalEvidence == nil, !closed else {
            throw CoincideError("The fake Pi final observation has no exact prepared owner.")
        }
        var inputs = [preparation.openingInput] + trace.steeringWrites
        var appended: [JSONValue] = [], parent = preparation.baseline.leafID
        for index in inputs.indices {
            let id = "owned-native-user-\(index + 1)"
            appended.append(Self.message(id: id, parent: parent, role: "user", text: index == 0 ? input.text : steeringProviderInputs[index - 1].text))
            inputs[index].nativeUserEntryID = id; parent = id
        }
        appended.append(Self.message(id: "owned-native-assistant", parent: parent, role: "assistant", text: "Native settled answer"))
        let observation = try PiRuntimeEntryObservation(nativeSessionFile: preparation.nativeSessionFile,
            nativeSessionID: preparation.nativeSessionID, leafID: "owned-native-assistant",
            entries: (latestRows + appended).map { PiHistoryEntryDescriptor(try PiHistoryEntry(raw: $0)) })
        let evidence = try PiRunHistoryEvidence(preparation: preparation, inputs: inputs, finalObservation: observation,
            openingUserEntryID: inputs[0].nativeUserEntryID, nativeUserEntryIDs: inputs.compactMap(\.nativeUserEntryID),
            captureStatus: .proven, terminalStatus: .completed)
        let handle = try FileHandle(forWritingTo: nativeFile); defer { try? handle.close() }
        _ = try handle.seekToEnd()
        for row in appended { try handle.write(contentsOf: JSONEncoder().encode(row)); try handle.write(contentsOf: Data([10])) }
        try handle.synchronize()
        finalEvidence = evidence; latestRows += appended; latestObservation = observation
        sink.yield(.context(runID: runID, event: .piHistoryEvidence(evidence)))
        return evidence
    }
    func finishNative() {
        if let activeRunID { sink.yield(.context(runID: activeRunID, event: .completed(.idle))) }
        activeRunID = nil
    }
    func interrupt() { if let owner = activeRunID ?? preparingRunID { interruptOwned(owner) } }
    func interrupt(expectedRunID: UUID) { interruptOwned(expectedRunID) }
    private func interruptOwned(_ id: UUID) {
        guard id == activeRunID || id == preparingRunID else { return }
        trace.interrupts += 1
        sink.yield(.context(runID: id, event: .completed(.interrupted)))
        activeRunID = nil
    }
    func respond(_ request: ApprovalRequest, allow: Bool) { Issue.record("The fake Pi handshake cannot request approval.") }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { Issue.record("The fake Pi handshake cannot request a question.") }
    func close() {
        guard !closed else { return }
        closed = true; trace.closes += 1; releasePreparation(); releaseSteeringReservation(); sink.finish()
    }
    private static func message(id: String, parent: String?, role: String, text: String) -> JSONValue {
        .object(["type": .string("message"), "id": .string(id), "parentId": parent.map(JSONValue.string) ?? .null,
            "timestamp": .string("2026-10-23T00:00:00.000Z"), "message": .object(["role": .string(role),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])])])])
    }
}

private final class PiPreparedEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let databaseURL: URL
    private let runtime: PiRuntimeConfiguration
    private let directory: URL
    private let firstMode: String
    private var peers: [PiPreparedEnginePeer] = []
    init(databaseURL: URL, runtime: PiRuntimeConfiguration, directory: URL, mode: String) {
        self.databaseURL = databaseURL; self.runtime = runtime; self.directory = directory; firstMode = mode
    }
    func make(_ thread: CodingThread) throws -> any ProviderSession {
        try lock.withLock {
            let peer = try PiPreparedEnginePeer(databaseURL: databaseURL, runtime: runtime, nativeDirectory: directory,
                mode: peers.isEmpty ? firstMode : "normal")
            peers.append(peer); return peer
        }
    }
    var sessions: [PiPreparedEnginePeer] { lock.withLock { peers } }
}

private struct PiPreparedEngineFixture: Sendable {
    let root: URL
    let database: URL
    let runtime: PiRuntimeConfiguration
    let project: WorkspaceProject
    let thread: CodingThread
    let engine: WorkspaceEngine
    let factory: PiPreparedEngineFactory
}

private func withPiPreparedEngine(mode: String = "normal", legacy: Bool = false,
                                   _ body: (PiPreparedEngineFixture) async throws -> Void) async throws {
    let manager = FileManager.default
    let requested = manager.temporaryDirectory.appendingPathComponent("coincide-pi-prepared-engine-" + UUID().uuidString)
    try manager.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    guard let pointer = requested.path.withCString({ realpath($0, nil) }) else { throw CoincideError("The private Pi fixture has no physical root.") }
    let physicalRoot = String(cString: pointer); free(pointer)
    let root = URL(fileURLWithPath: physicalRoot)
    defer { try? manager.removeItem(at: root) }
    let workspace = root.appendingPathComponent("Workspace 工作"), home = root.appendingPathComponent("PrivateHome")
    let agent = root.appendingPathComponent("PrivateAgent"), native = root.appendingPathComponent("NativeSessions")
    for directory in [workspace, home, agent, native] {
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    let instanceID = UUID(), project = WorkspaceProject(path: workspace.path)
    let runtime = try PiRuntimeConfiguration(instanceID: instanceID, executable: physicalRoot + "/never-executed-pi",
        requestedExecutable: "pi-engine-fixture", workspacePath: physicalRoot + "/Workspace 工作", registeredWorkspacePath: project.path,
        homeDirectory: physicalRoot + "/PrivateHome", agentDirectory: physicalRoot + "/PrivateAgent",
        agentDirectorySelection: .explicitDirectory(environmentPath: physicalRoot + "/PrivateAgent"))
    var thread = CodingThread(project: project)
    thread.provider = .pi; thread.checkpointPolicy = .disabled; thread.permission = .supervised
    thread.piConfiguration = .init(instanceID: instanceID, executable: runtime.requestedExecutable, runtime: legacy ? nil : runtime)
    let database = root.appendingPathComponent("workspace.sqlite")
    let factory = PiPreparedEngineFactory(databaseURL: database, runtime: runtime, directory: native, mode: mode)
    let engine = try WorkspaceEngine(url: database, providerFactory: { try factory.make($0) }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        try await body(.init(root: root, database: database, runtime: runtime, project: project, thread: thread, engine: engine, factory: factory))
        for peer in factory.sessions { await peer.releasePreparation(); await peer.releaseSteeringReservation() }
        await engine.shutdown()
    } catch {
        for peer in factory.sessions { await peer.releasePreparation(); await peer.releaseSteeringReservation() }
        await engine.shutdown(); throw error
    }
}

private func piPreparedEngineEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private Pi preparation fixture did not reach its exact boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func piHistoryEngineCommitsExactPreparationBeforePromptAndFinalEvidenceBeforeNativeCompletion() async throws {
    try await withPiPreparedEngine(legacy: true) { f in
        let text = "Only explicit Pi input 工作\nwith an exact second line", runID = UUID()
        try await f.engine.dispatch(.submitCapturedPi(threadID: f.thread.id, text: text, configuration: f.runtime), id: runID)
        try await piPreparedEngineEventually { await f.factory.sessions.first?.observations().promptWrites == 1 }
        let peer = try #require(f.factory.sessions.first), trace = await peer.observations()
        let preparation = try #require(trace.preparation), beforePrompt = try #require(trace.beforePrompt)
        #expect(trace.prepares == 1 && trace.preparedSendInvocations == 1 && trace.legacySends == 0)
        #expect(beforePrompt.pi?.preparation == preparation && beforePrompt.pi?.captureStatus == .prepared)
        #expect(beforePrompt.configuration.piConfiguration?.runtime == f.runtime)
        #expect(preparation.runID == runID && preparation.openingInput.clientMessageID == beforePrompt.userMessageID)
        #expect(preparation.inputDigest == (try PiHistoryInputEvidence.digest(.init(text: text))))
        #expect(preparation.openingInput.nativeUserEntryID == nil && preparation.baseline.entries.count == 2)
        #expect(preparation.baseline.leafID == "baseline-assistant")
        #expect(beforePrompt.turnIDs.isEmpty && beforePrompt.status == .running)
        let durable = try await WorkspaceDatabase(url: f.database).load()
        let active = try #require(durable.threads.first { $0.id == f.thread.id })
        #expect(active.activeRun?.nativeTurnID == nil && active.providerThreadID == preparation.nativeSessionFile)
        #expect(active.piConfiguration?.runtime == f.runtime && active.activeRun?.configuration.piConfiguration?.runtime == f.runtime)
        let final = try await peer.publishFinalEvidence()
        try await piPreparedEngineEventually {
            let update = await f.engine.current()
            return update.snapshot.threads.first?.runHistory?.first?.pi == final
        }
        let observed = await f.engine.current(), held = try #require(observed.snapshot.threads.first)
        #expect(held.activeRun?.id == runID && held.activeRun?.nativeTurnID == nil)
        #expect(held.runHistory?.first?.status == .running && held.runHistory?.first?.pi?.terminalStatus == .completed)
        await peer.finishNative()
        try await piPreparedEngineEventually { await f.engine.current().snapshot.threads.first?.activeRun == nil }
        let finished = await f.engine.current(), record = try #require(finished.snapshot.threads.first?.runHistory?.first)
        #expect(record.status == .completed && record.pi == final && record.turnIDs.isEmpty)
        let journal = try await WorkspaceDatabase(url: f.database).journal(limit: 1_000)
        let preparedSequence = try #require(journal.first { row in
            if case .threadMetadataUpserted(let thread) = row.event { return thread.runHistory?.first?.pi?.captureStatus == .prepared }
            return false
        }?.sequence)
        let promptSequence = try #require(journal.first { row in
            if case .messageUpserted(_, _, let message) = row.event { return message.text == "Pi prompt admitted after durable preparation" }
            return false
        }?.sequence)
        let provenSequence = try #require(journal.first { row in
            if case .threadMetadataUpserted(let thread) = row.event { return thread.runHistory?.first?.pi?.captureStatus == .proven }
            return false
        }?.sequence)
        let terminalSequence = try #require(journal.first { row in
            if case .threadMetadataUpserted(let thread) = row.event { return thread.runHistory?.first?.status == .completed }
            return false
        }?.sequence)
        #expect(preparedSequence < promptSequence && provenSequence < terminalSequence)
        await f.engine.shutdown()
        let database = try WorkspaceDatabase(url: f.database), rebuilt = try await database.rebuildProjection().snapshot
        #expect(rebuilt.threads.first?.runHistory?.first?.pi == final)
        let restarted = try WorkspaceEngine(url: f.database, providerFactory: { _ in
            Issue.record("Restart must not replay a prepared Pi prompt."); throw CoincideError("No provider construction on restart.")
        }, identityResolver: { _ in nil })
        do {
            let restored = try await restarted.load()
            #expect(restored.threads.first?.runHistory?.first?.pi == final)
            #expect(restored.threads.first?.piConfiguration?.runtime == f.runtime)
            #expect(restored.threads.first?.runHistory?.first?.turnIDs.isEmpty == true)
            await restarted.shutdown()
        } catch { await restarted.shutdown(); throw error }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["run", "runtime", "input", "client"])
func piHistoryEngineRejectsForeignPreparationBeforeCallingPreparedSend(_ mismatch: String) async throws {
    try await withPiPreparedEngine(mode: mismatch) { f in
        let runID = UUID()
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Owned exact Pi input"), id: runID)
        try await piPreparedEngineEventually {
            let update = await f.engine.current()
            return update.snapshot.threads.first?.runHistory?.first?.status == .failed && update.snapshot.threads.first?.activeRun == nil
        }
        let peer = try #require(f.factory.sessions.first), trace = await peer.observations()
        #expect(trace.prepares == 1 && trace.preparedSendInvocations == 0 && trace.promptWrites == 0 && trace.legacySends == 0)
        let current = await f.engine.current(), thread = try #require(current.snapshot.threads.first)
        #expect(current.error == nil && thread.runHistory?.first?.pi == nil)
        #expect(thread.runHistory?.first?.turnIDs.isEmpty == true && thread.activeRun == nil)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["stop", "remove-and-recreate"])
func piHistoryEngineRetiresHeldPreparationBeforeAnyPromptAcrossStopAndNewIncarnation(_ action: String) async throws {
    try await withPiPreparedEngine(mode: "held") { f in
        let runID = UUID()
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Held prospective Pi input"), id: runID)
        try await piPreparedEngineEventually { await f.factory.sessions.first?.observations().prepares == 1 }
        let peer = try #require(f.factory.sessions.first)
        let before = await peer.observations(); #expect(before.promptWrites == 0 && before.preparedSendInvocations == 0)
        if action == "stop" {
            try await f.engine.dispatch(.interrupt(threadID: f.thread.id))
            try await piPreparedEngineEventually {
                let current = await f.engine.current().snapshot.threads.first
                return current?.activeRun?.stopRequested == true || current?.activeRun == nil
            }
            await peer.releasePreparation()
            try await piPreparedEngineEventually { await f.engine.current().snapshot.threads.first?.activeRun == nil }
            let current = await f.engine.current().snapshot.threads.first
            #expect(current?.runHistory?.first?.status == .interrupted && current?.runHistory?.first?.pi == nil)
        } else {
            try await f.engine.dispatch(.removeProject(projectID: f.project.id, expectedThreadIDs: [f.thread.id]))
            await peer.releasePreparation()
            await f.engine.awaitProjectRemovalCleanup(projectID: f.project.id)
            try await f.engine.dispatch(.addProjectWithThread(project: f.project, thread: f.thread))
            let freshRun = UUID()
            try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "New incarnation exact Pi input"), id: freshRun)
            try await piPreparedEngineEventually {
                let sessions = f.factory.sessions
                let writes = await sessions.last?.observations().promptWrites
                return sessions.count == 2 && writes == 1
            }
            let second = try #require(f.factory.sessions.last), secondTrace = await second.observations()
            #expect(secondTrace.preparation?.runID == freshRun && secondTrace.preparation?.runID != runID)
            let current = await f.engine.current().snapshot.threads.first
            #expect(current?.runHistory?.count == 1 && current?.runHistory?.first?.id == freshRun)
            #expect(current?.runHistory?.first?.pi?.preparation == secondTrace.preparation)
        }
        let retired = await peer.observations()
        #expect(retired.preparedSendInvocations == 0 && retired.promptWrites == 0 && retired.legacySends == 0)
        let update = await f.engine.current()
        #expect(update.error == nil)
    }
}

@Test(.timeLimit(.minutes(1)))
func piHistoryEngineKeepsLegacyNilRuntimeOnNormalSendWithoutInventedHistory() async throws {
    try await withPiPreparedEngine(legacy: true) { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Legacy Pi caller still works"))
        try await piPreparedEngineEventually { await f.factory.sessions.first?.observations().legacySends == 1 }
        let peer = try #require(f.factory.sessions.first), trace = await peer.observations()
        #expect(trace.prepares == 0 && trace.preparedSendInvocations == 0 && trace.preparation == nil)
        await peer.finishNative()
        try await piPreparedEngineEventually { await f.engine.current().snapshot.threads.first?.activeRun == nil }
        let current = await f.engine.current(), record = try #require(current.snapshot.threads.first?.runHistory?.first)
        #expect(record.status == .completed && record.pi == nil && record.turnIDs.isEmpty)
        #expect(record.configuration.piConfiguration?.runtime == nil && current.error == nil)
    }
}

@Test(.timeLimit(.minutes(1)))
func piHistoryEngineRegistersExactSteeredInputDurablyBeforeAdapterWriteWithoutNativeTurnID() async throws {
    try await withPiPreparedEngine { f in
        let runID = UUID(), followUp = "Additional native 工作 input"
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Original prepared Pi owner"), id: runID)
        try await piPreparedEngineEventually { await f.factory.sessions.first?.observations().promptWrites == 1 }
        let peer = try #require(f.factory.sessions.first)
        _ = try await f.engine.steerPrompt(threadID: f.thread.id, text: followUp, expectedRunID: runID)
        try await piPreparedEngineEventually {
            let trace = await peer.observations(), current = await f.engine.current()
            return trace.steeringWrites.count == 1 && trace.canceledSteeringReservationIDs.count == 1 &&
                current.snapshot.promptSteerings?.first?.phase == .delivered
        }
        let current = await f.engine.current(), operation = try #require(current.snapshot.promptSteerings?.first)
        let trace = await peer.observations(), input = try #require(trace.steeringWrites.first)
        #expect(input.clientMessageID == operation.messageID && input.kind == .steering)
        #expect(input.inputDigest == (try PiHistoryInputEvidence.digest(.init(text: followUp))))
        #expect(trace.durableSteeringInputs.last == input && trace.durableSteeringInputs.count == 2)
        #expect(trace.steeringPreparationCalls == 1 && trace.preparedSteeringSendInvocations == 1 && trace.unpreparedSteeringCalls == 0)
        let reservation = try #require(trace.steeringReservations.first)
        #expect(reservation.runID == runID && reservation.input == input)
        #expect(reservation.runPreparationID == trace.preparation?.id)
        #expect(trace.canceledSteeringReservationIDs == [reservation.id])
        #expect(trace.inputsBeforeSteeringReservation.count == 1 && trace.inputsBeforeSteeringReservation.first?.kind == .opening)
        #expect(operation.target == .adapterRun(runID) && operation.receipt?.turnID == nil)
        #expect(current.snapshot.threads.first?.activeRun?.nativeTurnID == nil)
        #expect(current.snapshot.threads.first?.runHistory?.first?.pi?.inputs.last == input)
        let final = try await peer.publishFinalEvidence()
        try await piPreparedEngineEventually { await f.engine.current().snapshot.threads.first?.runHistory?.first?.pi == final }
        await peer.finishNative()
        try await piPreparedEngineEventually { await f.engine.current().snapshot.threads.first?.activeRun == nil }
        let finished = await f.engine.current(), record = try #require(finished.snapshot.threads.first?.runHistory?.first)
        #expect(record.pi?.nativeUserEntryIDs == ["owned-native-user-1", "owned-native-user-2"])
        let openingMessageID = try #require(record.userMessageID)
        #expect(record.pi?.inputs.map(\.clientMessageID) == [openingMessageID, operation.messageID])
        #expect(record.pi?.captureStatus == .proven && record.status == .completed && record.turnIDs.isEmpty)
        let nativeRows = try Data(contentsOf: URL(fileURLWithPath: final.nativeSessionFile)).split(separator: 10)
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
        let nativeSteer = try #require(nativeRows.first { $0["id"].string == "owned-native-user-2" })
        #expect(nativeSteer["message"]["content"].array?.first?["text"].string == followUp)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["reservation-refused", "late-reservation"])
func piHistoryEngineRefusedReservationNeverMarksTheOriginalRunOrWritesSteeringAndPreservesExactCompletedFallback(_ mode: String) async throws {
    try await withPiPreparedEngine(mode: mode) { f in
        let runID = UUID(), followUp = "Explicit follow-up held before Pi steering reservation"
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Original Pi owner before reservation race"), id: runID)
        try await piPreparedEngineEventually { await f.factory.sessions.first?.observations().promptWrites == 1 }
        let peer = try #require(f.factory.sessions.first)
        _ = try await f.engine.steerPrompt(threadID: f.thread.id, text: followUp, expectedRunID: runID)
        try await piPreparedEngineEventually { await peer.observations().steeringPreparationCalls == 1 }
        if mode == "late-reservation" {
            // This completion wins BEFORE the adapter has granted a steering
            // reservation. No same-run durable input marker may be installed.
            let final = try await peer.publishFinalEvidence()
            try await piPreparedEngineEventually { await f.engine.current().snapshot.threads.first?.runHistory?.first?.pi == final }
            await peer.finishNative()
            try await piPreparedEngineEventually { await f.engine.current().snapshot.threads.first?.activeRun == nil }
            await peer.releaseSteeringReservation()
            try await piPreparedEngineEventually {
                let trace = await peer.observations(), current = await f.engine.current()
                return trace.promptWrites == 2 && current.snapshot.promptSteerings?.first?.phase == .queued
            }
            let update = await f.engine.current(), thread = try #require(update.snapshot.threads.first)
            let currentRun = try #require(thread.activeRun), operation = try #require(update.snapshot.promptSteerings?.first)
            #expect(currentRun.id != runID && currentRun.nativeTurnID == nil)
            #expect(operation.runID == runID && operation.phase == .queued && operation.receipt == nil)
            let newRecord = try #require(thread.runHistory?.first { $0.id == currentRun.id })
            #expect(newRecord.userMessageID == operation.messageID)
            #expect(newRecord.pi?.preparation.openingInput.inputDigest == (try PiHistoryInputEvidence.digest(.init(text: followUp))))
            #expect(newRecord.pi?.preparation.baseline == final.finalObservation)
            #expect(newRecord.pi?.inputs.count == 1 && newRecord.pi?.inputs.first?.kind == .opening)
        } else {
            try await piPreparedEngineEventually { await f.engine.current().snapshot.promptSteerings?.first?.phase == .failed }
            let update = await f.engine.current(), thread = try #require(update.snapshot.threads.first)
            #expect(thread.activeRun?.id == runID && thread.queuedTurns.isEmpty && thread.runHistory?.count == 1)
            // A rejected reservation must not poison the later legitimate final
            // observation with an input the native actor never accepted.
            let final = try await peer.publishFinalEvidence()
            try await piPreparedEngineEventually { await f.engine.current().snapshot.threads.first?.runHistory?.first?.pi == final }
            await peer.finishNative()
            try await piPreparedEngineEventually { await f.engine.current().snapshot.threads.first?.activeRun == nil }
        }
        let trace = await peer.observations(), update = await f.engine.current()
        let original = try #require(update.snapshot.threads.first?.runHistory?.first { $0.id == runID })
        #expect(trace.steeringPreparationCalls == 1 && trace.steeringReservations.isEmpty)
        #expect(trace.preparedSteeringSendInvocations == 0 && trace.steeringWrites.isEmpty && trace.unpreparedSteeringCalls == 0)
        #expect(trace.canceledSteeringReservationIDs.isEmpty)
        #expect(trace.inputsBeforeSteeringReservation.count == 1)
        #expect(original.status == .completed && original.pi?.inputs.count == 1 && original.pi?.inputs.first?.kind == .opening)
        #expect(original.pi?.nativeUserEntryIDs == ["owned-native-user-1"] && original.turnIDs.isEmpty)
        #expect(update.error == nil)
        let journal = try await WorkspaceDatabase(url: f.database).journal(limit: 1_000)
        for row in journal {
            if case .threadMetadataUpserted(let thread) = row.event,
               let observed = thread.runHistory?.first(where: { $0.id == runID })?.pi {
                #expect(observed.inputs.count == 1, "A refused pre-reservation input must never enter the original run's durable proof.")
            }
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func piHistoryEngineRestartPreservesUnsettledPreparationWithoutReplayingOrInventingFinalEvidence() async throws {
    try await withPiPreparedEngine { f in
        let runID = UUID()
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Prepared before deliberate shutdown"), id: runID)
        try await piPreparedEngineEventually { await f.factory.sessions.first?.observations().promptWrites == 1 }
        let peer = try #require(f.factory.sessions.first), observation = await peer.observations()
        let preparation = try #require(observation.preparation)
        let baselineBytes = try Data(contentsOf: URL(fileURLWithPath: preparation.nativeSessionFile))
        // pauseQueues intentionally concerns queued work. Give recovery a real
        // FIFO successor rather than asserting a pause flag on an empty queue.
        let successorID = UUID(), successorText = "Pending Pi successor requires an explicit resume after restart"
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: successorText), id: successorID)
        let beforeShutdown = await f.engine.current()
        let queuedOwner = try #require(beforeShutdown.snapshot.threads.first)
        let queued = try #require(queuedOwner.queuedTurns.first)
        #expect(queuedOwner.activeRun?.id == runID && queuedOwner.queuedTurns.count == 1)
        #expect(queued.id == successorID && queued.text == successorText && queued.configuration.piConfiguration?.runtime == f.runtime)
        #expect(queuedOwner.runHistory?.count == 1 && queuedOwner.runHistory?.first?.pi?.preparation == preparation)
        let beforeClose = await peer.observations()
        #expect(beforeClose.prepares == 1 && beforeClose.promptWrites == 1)
        await f.engine.shutdown()
        let restarted = try WorkspaceEngine(url: f.database, providerFactory: { _ in
            Issue.record("An unsettled Pi preparation must never be replayed on restart."); throw CoincideError("No provider construction on restart.")
        }, identityResolver: { _ in nil })
        do {
            let restored = try await restarted.load(), record = try #require(restored.threads.first?.runHistory?.first)
            #expect(record.id == runID && record.status.isTerminal && record.turnIDs.isEmpty)
            #expect(record.pi?.preparation == preparation && record.pi?.captureStatus == .prepared)
            #expect(record.pi?.inputs == [preparation.openingInput] && record.pi?.finalObservation == nil)
            #expect(record.pi?.nativeUserEntryIDs.isEmpty == true && record.pi?.terminalStatus == nil)
            #expect(restored.threads.first?.activeRun == nil && restored.threads.first?.queuePaused == true)
            #expect(restored.threads.first?.queuedTurns == [queued])
            #expect(restored.threads.first?.runHistory?.count == 1, "Neither the unsettled input nor its queued successor may be replayed during load.")
            await restarted.drainCommands()
            let current = await restarted.current()
            #expect(current.error == nil && current.snapshot.threads.first?.activeRun == nil)
            #expect(current.snapshot.threads.first?.queuedTurns == [queued] && current.snapshot.threads.first?.queuePaused == true)
            #expect(try Data(contentsOf: URL(fileURLWithPath: preparation.nativeSessionFile)) == baselineBytes)
            let trace = await peer.observations(); #expect(trace.prepares == 1 && trace.promptWrites == 1 && trace.closes == 1)
            await restarted.shutdown()
        } catch { await restarted.shutdown(); throw error }
    }
}
