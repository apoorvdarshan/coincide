import Foundation
import Testing
@testable import CoincideCore

private struct PiHistoryJournalFixture {
    var snapshot = WorkspaceSnapshot()
    let incarnation = UUID()
    let runtimeID = UUID()
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let openingText = "Prospective Pi input 工作"
    let runtime: PiRuntimeConfiguration
    var thread: CodingThread { snapshot.threads[0] }
    var other: CodingThread { snapshot.threads[1] }
    var runID: UUID { thread.runHistory![0].id }
    var nativeFile: String { thread.workspacePath + "/native-owned.jsonl" }

    init(legacy: Bool = false) throws {
        let project = WorkspaceProject(path: "/tmp/coincide-pi-history-journal")
        let instance = UUID()
        runtime = try PiRuntimeConfiguration(instanceID: instance, executable: "/never-executed/pi",
            requestedExecutable: "pi-journal-fixture", workspacePath: project.path,
            homeDirectory: "/private/pi-journal-home", agentDirectory: "/private/pi-journal-agent",
            agentDirectorySelection: .explicitDirectory(environmentPath: "/private/pi-journal-agent"))
        var owner = CodingThread(project: project)
        owner.provider = .pi; owner.checkpointPolicy = .disabled
        owner.piConfiguration = .init(instanceID: instance, executable: runtime.requestedExecutable,
            model: .init(provider: "fixture-provider", modelID: "captured-model"), thinkingLevel: "high",
            runtime: legacy ? nil : runtime)
        owner.model = owner.piConfiguration?.model?.catalogID ?? ""
        var unrelated = CodingThread(project: project)
        unrelated.checkpointPolicy = .disabled; unrelated.draft = "Independent draft"
        snapshot.projects = [project]; snapshot.threads = [owner, unrelated]
        try apply(.client(.submit(threadID: owner.id, text: openingText)))
        try apply(.runtimeOpened(threadID: thread.id, runID: runID, runtimeID: runtimeID))
    }

    @discardableResult mutating func apply(_ command: EngineCommand) throws -> WorkspaceDecision {
        let decision = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: now)
        snapshot = decision.snapshot
        return decision
    }

    func preparation(runID: UUID? = nil, clientID: String? = nil,
                     runtime: PiRuntimeConfiguration? = nil, nativeFile: String? = nil) throws -> PiRunHistoryPreparation {
        let selected = runtime ?? self.runtime
        let openingClientID = try #require(thread.runHistory?.first?.userMessageID)
        let input = try PiHistoryInputEvidence(clientMessageID: clientID ?? openingClientID,
            inputDigest: PiHistoryInputEvidence.digest(.init(text: openingText)), kind: .opening)
        let baseline = try PiRuntimeEntryObservation(nativeSessionFile: nativeFile ?? self.nativeFile,
            nativeSessionID: "pi-journal-native-session", leafID: nil, entries: [])
        return try .init(runID: runID ?? self.runID,
            runtimeIdentity: .init(instanceID: selected.instanceID, executable: selected.requestedExecutable, runtime: selected),
            observedVersion: "0.80.5", openingInput: input, baseline: baseline)
    }

    func marker(_ preparation: PiRunHistoryPreparation, runtimeID: UUID? = nil) -> EngineCommand {
        .piRunHistoryPrepared(threadID: thread.id, runtimeID: runtimeID ?? self.runtimeID,
            preparation: preparation, incarnation: incarnation)
    }

    /// Expected stale ownership is a rejected command or a harmless no-op. It
    /// must never escape as a graph error that the Engine treats as corruption.
    mutating func rejectOrIgnore(_ command: EngineCommand) throws {
        let before = snapshot
        do {
            let ignored = try apply(command)
            #expect(snapshot == before)
            #expect(ignored.effects.isEmpty && ignored.closeRuntimes.isEmpty)
        } catch is WorkspaceCommandError {
            #expect(snapshot == before)
        } catch {
            Issue.record("Expected Pi marker rejection escaped the command error boundary: \(type(of: error)).")
            throw error
        }
        try WorkspaceJournal.validate(snapshot)
    }

    mutating func prepare() throws -> PiRunHistoryPreparation {
        let proof = try preparation()
        try apply(marker(proof))
        return proof
    }

    mutating func acceptSteering() throws -> PromptSteeringOperation {
        let run = try #require(thread.activeRun)
        let input = QueuedTurn(id: UUID(), text: "Owned follow-up λ", configuration: run.configuration,
            createdAt: now, checkpointPolicy: .disabled)
        let operation = PromptSteeringOperation(threadID: thread.id, projectID: thread.projectID,
            sourceIncarnation: incarnation, runtimeID: runtimeID, runID: run.id,
            nativeThreadID: try #require(thread.providerThreadID), target: .adapterRun(run.id),
            input: input, messageID: "user-" + input.id.uuidString, configuration: run.configuration, createdAt: now)
        try apply(.promptSteeringAccepted(operation))
        try apply(.promptSteeringDispatching(operationID: operation.id, incarnation: incarnation))
        return operation
    }

    func terminal(_ preparation: PiRunHistoryPreparation) throws -> PiRunHistoryEvidence {
        let user: JSONValue = .object(["type": .string("message"), "id": .string("owned-user-entry"),
            "parentId": .null, "timestamp": .string("2026-10-23T00:00:00.000Z"),
            "message": .object(["role": .string("user"), "content": .string(openingText)])])
        let assistant: JSONValue = .object(["type": .string("message"), "id": .string("owned-assistant-entry"),
            "parentId": .string("owned-user-entry"), "timestamp": .string("2026-10-23T00:00:01.000Z"),
            "message": .object(["role": .string("assistant"), "content": .string("Observed answer")])])
        let final = try PiRuntimeEntryObservation(nativeSessionFile: preparation.nativeSessionFile,
            nativeSessionID: preparation.nativeSessionID, leafID: "owned-assistant-entry",
            entries: [user, assistant].map { PiHistoryEntryDescriptor(try PiHistoryEntry(raw: $0)) })
        var input = preparation.openingInput; input.nativeUserEntryID = "owned-user-entry"
        return try .init(preparation: preparation, inputs: [input], finalObservation: final,
            openingUserEntryID: "owned-user-entry", nativeUserEntryIDs: ["owned-user-entry"],
            captureStatus: .proven, terminalStatus: .completed)
    }
}

private func alteredPiJournalValue<T: Codable>(_ value: T, _ change: (inout [String: Any]) throws -> Void) throws -> T {
    let bytes = try JSONEncoder().encode(value)
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    try change(&object)
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

@Test(arguments: ["stop", "completed", "runtime-replaced"])
func piHistoryJournalRejectsDelayedPreparationWithoutChangingStoppedOrSuccessorOwnership(_ boundary: String) throws {
    var f = try PiHistoryJournalFixture()
    let proof = try f.preparation(), otherBefore = f.other
    switch boundary {
    case "stop": try f.apply(.client(.interrupt(threadID: f.thread.id)))
    case "completed": try f.apply(.provider(threadID: f.thread.id, runtimeID: f.runtimeID, event: .completed(.idle)))
    default: try f.apply(.runtimeOpened(threadID: f.thread.id, runID: f.runID, runtimeID: UUID()))
    }
    try f.rejectOrIgnore(f.marker(proof))
    #expect(f.thread.runHistory?.first?.pi == nil && f.other == otherBefore)
    #expect(f.thread.activeRun?.nativeTurnID == nil && f.thread.runHistory?.first?.turnIDs.isEmpty == true)
    try f.apply(.client(.submit(threadID: f.other.id, text: "Unrelated conversation still accepts work")))
    #expect(f.other.activeRun != nil)
}

@Test(arguments: ["run", "runtime", "client", "native-file", "decoded-invalid-version"])
func piHistoryJournalRefusesForeignPreparationThenAcceptsTheExactOriginalOwner(_ kind: String) throws {
    var f = try PiHistoryJournalFixture()
    try f.apply(.provider(threadID: f.thread.id, runtimeID: f.runtimeID, event: .thread(f.nativeFile)))
    let expected = try f.preparation()
    let foreign: PiRunHistoryPreparation
    switch kind {
    case "run": foreign = try f.preparation(runID: UUID())
    case "client": foreign = try f.preparation(clientID: "foreign-client-row")
    case "native-file": foreign = try f.preparation(nativeFile: f.thread.workspacePath + "/foreign.jsonl")
    case "runtime":
        let other = try PiRuntimeConfiguration(instanceID: f.runtime.instanceID, executable: f.runtime.executable,
            requestedExecutable: f.runtime.requestedExecutable, workspacePath: f.runtime.workspacePath,
            registeredWorkspacePath: f.runtime.registeredWorkspacePath, homeDirectory: f.runtime.homeDirectory,
            agentDirectory: "/private/foreign-pi-agent",
            agentDirectorySelection: .explicitDirectory(environmentPath: "/private/foreign-pi-agent"))
        foreign = try f.preparation(runtime: other)
    default: foreign = try alteredPiJournalValue(expected) { $0["observedVersion"] = "0.79.0" }
    }
    try f.rejectOrIgnore(f.marker(foreign))
    #expect(f.thread.runHistory?.first?.pi == nil)
    let accepted = try f.apply(f.marker(expected))
    #expect(accepted.effects.isEmpty)
    #expect(f.thread.runHistory?.first?.pi?.preparation == expected)
    #expect(f.thread.providerThreadID == expected.nativeSessionFile)
    #expect(f.thread.activeRun?.nativeTurnID == nil && f.thread.runHistory?.first?.turnIDs.isEmpty == true)
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func piHistoryJournalAtomicCapturePreservesLegacyActiveAndQueuedValuesAcrossPersistence() throws {
    var f = try PiHistoryJournalFixture(legacy: true)
    try f.apply(.client(.submit(threadID: f.thread.id, text: "Previously captured legacy FIFO")))
    let active = try #require(f.thread.activeRun), legacy = try #require(f.thread.queuedTurns.first)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let originalQueuedBytes = try encoder.encode(legacy)
    let nextID = UUID()
    let decision = try WorkspaceDecision.make(.client(.submitCapturedPi(threadID: f.thread.id,
        text: "New namespace-captured input", configuration: f.runtime)), id: nextID, snapshot: f.snapshot, now: f.now)
    f.snapshot = decision.snapshot
    #expect(f.thread.activeRun == active && active.configuration.piConfiguration?.runtime == nil)
    #expect(f.thread.queuedTurns.count == 2 && f.thread.queuedTurns[0] == legacy)
    #expect(try encoder.encode(f.thread.queuedTurns[0]) == originalQueuedBytes)
    let captured = f.thread.queuedTurns[1]
    #expect(captured.id == nextID && captured.configuration.piConfiguration?.runtime == f.runtime)
    #expect(captured.configuration.piConfiguration?.instanceID == legacy.configuration.piConfiguration?.instanceID)
    #expect(captured.configuration.piConfiguration?.executable == legacy.configuration.piConfiguration?.executable)
    #expect(captured.configuration.piConfiguration?.model == legacy.configuration.piConfiguration?.model)
    #expect(captured.configuration.piConfiguration?.thinkingLevel == "high" && decision.effects.isEmpty)
    let reopened = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoder.encode(f.snapshot))
    try WorkspaceJournal.validate(reopened)
    #expect(reopened.threads[0].queuedTurns == [legacy, captured])
    #expect(reopened.threads[0].activeRun == active && reopened.threads[0].runHistory?.first?.pi == nil)
}

@Test(arguments: ["completed", "stop", "operation-failed", "incarnation", "runtime-replaced", "foreign-client"])
func piHistoryJournalRejectsLateSteeringMarkersWithoutExtendingAnExpiredRun(_ boundary: String) throws {
    var f = try PiHistoryJournalFixture()
    let proof = try f.prepare(), operation = try f.acceptSteering()
    let input = try PiHistoryInputEvidence.steering(clientMessageID: boundary == "foreign-client" ? "foreign-input" : operation.messageID,
        input: .init(text: operation.input.text))
    switch boundary {
    case "completed": try f.apply(.provider(threadID: f.thread.id, runtimeID: f.runtimeID, event: .completed(.idle)))
    case "stop": try f.apply(.client(.interrupt(threadID: f.thread.id)))
    case "operation-failed":
        try f.apply(.promptSteeringEffectResult(.promptSteering(threadID: f.thread.id, operationID: operation.id),
            .failed(PromptSteeringOperation.failureMessage), incarnation: f.incarnation))
    case "runtime-replaced": try f.apply(.runtimeOpened(threadID: f.thread.id, runID: f.runID, runtimeID: UUID()))
    default: break
    }
    try f.rejectOrIgnore(.piSteeringInputPrepared(operationID: operation.id, input: input,
        incarnation: boundary == "incarnation" ? UUID() : f.incarnation))
    #expect(f.thread.runHistory?.first?.pi?.inputs == [proof.openingInput])
    #expect(f.thread.messages.filter { $0.id == operation.messageID }.count == 1)
    #expect(f.thread.runHistory?.first?.turnIDs.isEmpty == true)
}

@Test(arguments: ["foreign-run", "foreign-client", "foreign-file", "malformed-inventory"])
func piHistoryJournalContainsForgedTerminalProofToItsRunAndKeepsOtherThreadsUsable(_ kind: String) throws {
    var f = try PiHistoryJournalFixture()
    let proof = try f.prepare(), valid = try f.terminal(proof), otherBefore = f.other
    let observed = try WorkspaceDecision.make(.provider(threadID: f.thread.id, runtimeID: f.runtimeID,
        event: .context(runID: f.runID, event: .piHistoryEvidence(valid))), id: UUID(), snapshot: f.snapshot, now: f.now)
    #expect(observed.snapshot.threads[0].runHistory?.first?.pi == valid)
    #expect(observed.snapshot.threads[0].activeRun?.id == f.runID)
    #expect(observed.snapshot.threads[0].runHistory?.first?.status == .running)
    let completed = try WorkspaceDecision.make(.provider(threadID: f.thread.id, runtimeID: f.runtimeID,
        event: .context(runID: f.runID, event: .completed(.idle))), id: UUID(), snapshot: observed.snapshot, now: f.now)
    #expect(completed.snapshot.threads[0].activeRun == nil)
    #expect(completed.snapshot.threads[0].runHistory?.first?.status == .completed)
    #expect(completed.snapshot.threads[0].runHistory?.first?.pi == valid)
    let forged = try alteredPiJournalValue(valid) { object in
        if kind == "malformed-inventory" {
            var observation = try #require(object["finalObservation"] as? [String: Any])
            observation["inventoryDigest"] = String(repeating: "0", count: 64)
            object["finalObservation"] = observation
        } else {
            var preparation = try #require(object["preparation"] as? [String: Any])
            if kind == "foreign-run" { preparation["runID"] = UUID().uuidString }
            else if kind == "foreign-client" {
                var opening = try #require(preparation["openingInput"] as? [String: Any])
                opening["clientMessageID"] = "unowned-native-client"
                preparation["openingInput"] = opening
                var inputs = try #require(object["inputs"] as? [[String: Any]])
                inputs[0]["clientMessageID"] = "unowned-native-client"; object["inputs"] = inputs
            } else {
                let file = f.thread.workspacePath + "/unowned-native.jsonl"
                preparation["nativeSessionFile"] = file
                var baseline = try #require(preparation["baseline"] as? [String: Any])
                baseline["nativeSessionFile"] = file; preparation["baseline"] = baseline
                var final = try #require(object["finalObservation"] as? [String: Any])
                final["nativeSessionFile"] = file; object["finalObservation"] = final
            }
            object["preparation"] = preparation
        }
    }
    let closed = try f.apply(.provider(threadID: f.thread.id, runtimeID: f.runtimeID,
        event: .context(runID: f.runID, event: .piHistoryEvidence(forged))))
    #expect(f.thread.activeRun == nil && f.thread.runtimeID == nil && f.thread.queuePaused)
    #expect(f.thread.state == .failed && f.thread.runHistory?.first?.status == .failed)
    #expect(f.thread.runHistory?.first?.endReason == .connectionLost)
    #expect(f.thread.runHistory?.first?.pi?.captureStatus == .prepared)
    #expect(closed.closeRuntimes == [f.thread.id] && f.other == otherBefore)
    try f.apply(.client(.submit(threadID: f.other.id, text: "Independent work after rejected proof")))
    #expect(f.other.activeRun != nil && f.other.messages.last?.text == "Independent work after rejected proof")
    try WorkspaceJournal.validate(f.snapshot)
}

@Test(arguments: ["removed-binding", "replaced-binding", "blank-other-provider", "valid-same-runtime"])
func piHistoryJournalWorkspaceRebindRejectsStaleTypedCaptureWithoutBlockingUnrelatedWork(_ scenario: String) throws {
    var f = try PiHistoryJournalFixture()
    let project = f.snapshot.projects[0]
    var blank = CodingThread(project: project)
    blank.checkpointPolicy = .disabled; blank.draft = "Keep this latest unsent workspace draft"
    let selectedModel = PiModelSelection(provider: "fixture-provider", modelID: "captured-model")
    if scenario != "blank-other-provider" {
        blank.provider = .pi; blank.model = selectedModel.catalogID
        var captured: PiRuntimeConfiguration? = f.runtime
        if scenario == "removed-binding" { captured = nil }
        if scenario == "replaced-binding" {
            captured = try PiRuntimeConfiguration(instanceID: UUID(), executable: f.runtime.executable,
                requestedExecutable: f.runtime.requestedExecutable, workspacePath: f.runtime.workspacePath,
                registeredWorkspacePath: f.runtime.registeredWorkspacePath, homeDirectory: f.runtime.homeDirectory,
                agentDirectory: "/private/replacement-pi-agent",
                agentDirectorySelection: .explicitDirectory(environmentPath: "/private/replacement-pi-agent"))
        }
        blank.piConfiguration = .init(instanceID: captured?.instanceID ?? f.runtime.instanceID,
            executable: f.runtime.requestedExecutable, model: selectedModel, thinkingLevel: "high", runtime: captured)
    }
    f.snapshot.threads[0] = blank
    try WorkspaceJournal.validate(f.snapshot)
    let destination = project.path + "/Different Checkout 工作"
    let oldCapture = try f.runtime.replacingWorkspace(destination, physicalPath: destination)
    let command = EngineCommand.client(.editThread(blank.id, .piWorkspace(oldCapture)))
    let before = f.snapshot
    if scenario == "valid-same-runtime" {
        let saved = try f.apply(command)
        #expect(f.thread.workspacePath == destination && f.thread.piConfiguration?.runtime == oldCapture)
        #expect(f.thread.piConfiguration?.instanceID == f.runtime.instanceID)
        #expect(f.thread.piConfiguration?.model == selectedModel && f.thread.piConfiguration?.thinkingLevel == "high")
        #expect(f.thread.piConfiguration?.executable == f.runtime.requestedExecutable)
        #expect(f.thread.draft == blank.draft && f.thread.messages.isEmpty && f.thread.queuedTurns.isEmpty)
        #expect(saved.effects.isEmpty && saved.closeRuntimes == [blank.id])
        #expect(f.other == before.threads[1])
    } else {
        #expect(throws: WorkspaceCommandError.self) { try f.apply(command) }
        #expect(f.snapshot == before)
    }
    try f.apply(.client(.submit(threadID: f.other.id, text: "Independent work after typed workspace admission")))
    #expect(f.other.activeRun != nil)
    #expect(f.thread.draft == blank.draft && f.thread.messages.isEmpty)
    try WorkspaceJournal.validate(f.snapshot)
}
