import Foundation
import Testing
@testable import CoincideCore

@Test
func remoteCheckpointOptionalCreatePolicyPreservesLegacyOriginalReceiptPayloadBytes() throws {
    let request = RemoteEnvironmentCommandRequest(environmentID: UUID(), command: .createThread(id: UUID(), projectID: UUID(),
        provider: .codex, title: "Retained legacy command", model: "", permission: .supervised))
    let encoded = try RemoteEnvironmentProtocol.payload(request)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var command = try #require(object["command"] as? [String: Any])
    var creation = try #require(command["createThread"] as? [String: Any])
    creation.removeValue(forKey: "checkpointPolicy")
    command["createThread"] = creation; object["command"] = command
    let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    let decoded = try JSONDecoder().decode(RemoteEnvironmentCommandRequest.self, from: legacy)
    #expect(decoded == request)
    #expect(try RemoteEnvironmentProtocol.payload(decoded) == legacy)
}

private final class RemoteEnvironmentCoreProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func make(_ thread: CodingThread) throws -> any ProviderSession {
        lock.withLock { count += 1 }
        throw CoincideError("No provider is authorized by this metadata fixture.")
    }
    var starts: Int { lock.withLock { count } }
}
private final class RemoteEnvironmentSubscriptionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func disconnect() { lock.withLock { count += 1 } }
    var disconnects: Int { lock.withLock { count } }
}
private func remoteCoreRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-core-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

@Test func remoteEnvironmentDescriptorPinsIdentityWithoutOpeningWorkspaceOrProvider() async throws {
    let root = try remoteCoreRoot(), data = root.appendingPathComponent("Host")
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = RemoteEnvironmentCoreProbe()
    let service = try RemoteEnvironmentService(dataDirectory: data, label: "Private fixture", providerFactory: { try probe.make($0) })
    let descriptor = await service.descriptor()
    #expect(descriptor.protocolVersion == 1 && descriptor.capabilities.supportsCommandReceipts)
    #expect(!descriptor.capabilities.persistentDaemon)
    #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("workspace.sqlite").path))
    await #expect(throws: RemoteEnvironmentError(.wrongEnvironment)) {
        try await service.snapshot(.init(environmentID: UUID()))
    }
    #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("workspace.sqlite").path))
    #expect(probe.starts == 0)
    await service.close()
    let reopened = try RemoteEnvironmentService(dataDirectory: data, expectedEnvironmentID: descriptor.environmentID)
    #expect(await reopened.descriptor().environmentID == descriptor.environmentID)
    await reopened.close()
    #expect(throws: RemoteEnvironmentError(.wrongEnvironment)) {
        try RemoteEnvironmentService(dataDirectory: data, expectedEnvironmentID: UUID())
    }
}

@Test(arguments: ["corrupt", "public", "symlink", "missing-with-database"])
func remoteEnvironmentIdentityRefusesUnsafeExistingState(fault: String) async throws {
    let root = try remoteCoreRoot(), data = root.appendingPathComponent("Host")
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try RemoteEnvironmentService(dataDirectory: data)
    await service.close()
    let identity = data.appendingPathComponent("environment.json")
    switch fault {
    case "corrupt": try Data("not an identity".utf8).write(to: identity)
    case "public": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: identity.path)
    case "symlink":
        let moved = root.appendingPathComponent("moved-identity.json")
        try FileManager.default.moveItem(at: identity, to: moved)
        try FileManager.default.createSymbolicLink(at: identity, withDestinationURL: moved)
    default:
        try FileManager.default.removeItem(at: identity)
        try Data().write(to: data.appendingPathComponent("workspace.sqlite"))
    }
    #expect(throws: RemoteEnvironmentError(.identityInvalid)) { try RemoteEnvironmentService(dataDirectory: data) }
}

@Test func remoteEnvironmentServiceCapturesHostSettingsAndDurablyBindsAcceptedAndRejectedCommands() async throws {
    let root = try remoteCoreRoot(), data = root.appendingPathComponent("Host"), workspace = root.appendingPathComponent("Workspace")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
    let probe = RemoteEnvironmentCoreProbe()
    let options = RemoteEnvironmentOptions(codexExecutable: "/usr/bin/true", codexHome: root.appendingPathComponent("Native Home").path)
    let service = try RemoteEnvironmentService(dataDirectory: data, options: options, providerFactory: { try probe.make($0) })
    let environmentID = service.environmentID, projectID = UUID(), threadID = UUID()
    let add = RemoteEnvironmentCommandRequest(environmentID: environmentID, command: .addProject(id: projectID, path: workspace.path, title: "Remote project"))
    let accepted = try await service.command(add)
    #expect(accepted.receipt.rejection == nil)
    #expect(try await service.command(add) == accepted)
    let create = RemoteEnvironmentCommandRequest(environmentID: environmentID,
        command: .createThread(id: threadID, projectID: projectID, provider: .codex, title: "Remote conversation", model: "", permission: .auto))
    #expect(try await service.command(create).receipt.rejection == nil)
    let initial = try await service.snapshot(.init(environmentID: environmentID))
    let thread = try #require(initial.workspace.threads.first)
    #expect(thread.codexRuntimeConfiguration?.executable == "/usr/bin/true")
    #expect(thread.codexRuntimeConfiguration?.homeDirectory == options.codexHome)
    #expect(thread.permission == .auto && thread.activeRun == nil)
    let captured = ProviderConfiguration(thread: thread)
    let edit = RemoteEnvironmentCommandRequest(environmentID: environmentID,
        command: .editThread(threadID: threadID, edit: .model("future-model"), expectedConfiguration: captured))
    let edited = try await service.command(edit)
    #expect(edited.receipt.rejection == nil)
    #expect(try await service.command(edit) == edited, "Retry resolves the receipt before stale configuration validation.")
    let stale = RemoteEnvironmentCommandRequest(environmentID: environmentID,
        command: .submit(threadID: threadID, text: "Never execute stale input", expectedConfiguration: captured))
    let refused = try await service.command(stale)
    #expect(refused.receipt.rejection != nil)
    #expect(try await service.receipt(stale).receipt == refused.receipt)
    let missing = root.appendingPathComponent("Not Yet Existing")
    let invalidPath = RemoteEnvironmentCommandRequest(environmentID: environmentID,
        command: .addProject(id: UUID(), path: missing.path, title: nil))
    let rejection = try await service.command(invalidPath)
    #expect(rejection.receipt.rejection != nil && rejection.receipt.rejection?.contains(missing.path) == false)
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
    #expect(try await service.command(invalidPath) == rejection, "A known refused command never executes later under its old ID.")
    let changed = RemoteEnvironmentCommandRequest(environmentID: environmentID, id: add.id,
        command: .addProject(id: projectID, path: workspace.path, title: "Different payload"))
    await #expect(throws: RemoteEnvironmentError(.commandCollision)) { try await service.command(changed) }
    await #expect(throws: RemoteEnvironmentError(.commandCollision)) { try await service.receipt(changed) }
    let last = try await service.snapshot(.init(environmentID: environmentID, afterSequence: initial.sequence))
    #expect(last.environmentID == environmentID && last.sequence >= initial.sequence)
    #expect(last.workspace.projects.count == 1 && last.workspace.threads.first?.model == "future-model")
    #expect(last.workspace.threads.first?.messages.isEmpty == true && probe.starts == 0)
    #expect(try await WorkspaceDatabase(url: data.appendingPathComponent("workspace.sqlite")).rebuildProjection().snapshot == last.workspace)
    await service.close()
    let reopened = try RemoteEnvironmentService(dataDirectory: data, expectedEnvironmentID: environmentID,
        options: options, providerFactory: { try probe.make($0) })
    #expect(try await reopened.receipt(stale).receipt == refused.receipt)
    #expect(try await reopened.command(add) == accepted)
    #expect(probe.starts == 0)
    await reopened.close()
}

@Test func remoteEnvironmentAdmissionFencesChangedRunConfigurationAndExactRequest() throws {
    let project = WorkspaceProject(path: "/fixture/remote-atomic"), runtimeID = UUID(), runID = UUID()
    var thread = CodingThread(project: project)
    thread.checkpointPolicy = .disabled
    thread.activeRun = .init(id: runID, configuration: .init(thread: thread), startedAt: .now)
    thread.runtimeID = runtimeID; thread.state = .running
    let request = ApprovalRequest(id: .number(7), method: "item/commandExecution/requestApproval", params: .object(["command": .string("echo exact")]))
    thread.runtimeRequests = [.init(request: request)]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let environmentID = UUID()
    let stop = RemoteEnvironmentCommandRequest(environmentID: environmentID, command: .stop(threadID: thread.id, runID: runID, runtimeID: runtimeID))
    #expect(try RemoteEnvironmentAdmission.action(stop, preparation: .none, snapshot: snapshot) == .interrupt(threadID: thread.id))
    snapshot.threads[0].activeRun?.id = UUID()
    #expect(throws: WorkspaceCommandError.self) { try RemoteEnvironmentAdmission.action(stop, preparation: .none, snapshot: snapshot) }
    snapshot.threads[0] = thread
    let answer = RemoteEnvironmentCommandRequest(environmentID: environmentID,
        command: .respond(threadID: thread.id, runID: runID, runtimeID: runtimeID, request: request, response: .decision(true)))
    #expect(try RemoteEnvironmentAdmission.action(answer, preparation: .none, snapshot: snapshot) == .respond(threadID: thread.id, requestID: request.id, response: .decision(true)))
    snapshot.threads[0].runtimeRequests[0].request.params = .object(["command": .string("different under same wire ID")])
    #expect(throws: WorkspaceCommandError.self) { try RemoteEnvironmentAdmission.action(answer, preparation: .none, snapshot: snapshot) }
    snapshot.threads[0] = thread
    let edit = RemoteEnvironmentCommandRequest(environmentID: environmentID,
        command: .editThread(threadID: thread.id, edit: .permission(.fullAccess), expectedConfiguration: .init(thread: thread)))
    snapshot.threads[0].model = "changed-before-admission"
    #expect(throws: WorkspaceCommandError.self) { try RemoteEnvironmentAdmission.action(edit, preparation: .none, snapshot: snapshot) }
}

@Test func remoteEnvironmentMissingReceiptAndReconnectNeverPrepareOrResumeQueuedProviderWork() async throws {
    let root = try remoteCoreRoot(), data = root.appendingPathComponent("Host"), workspace = root.appendingPathComponent("Workspace")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
    let initial = try RemoteEnvironmentService(dataDirectory: data)
    let identity = initial.environmentID
    await initial.close()
    let project = WorkspaceProject(path: workspace.path)
    var thread = CodingThread(project: project)
    thread.checkpointPolicy = .disabled
    thread.queuedTurns = [.init(id: UUID(), text: "Retained input must wait for explicit resume", configuration: .init(thread: thread), createdAt: .now)]
    var seed = WorkspaceSnapshot(); seed.projects = [project]; seed.threads = [thread]
    try await WorkspaceDatabase(url: data.appendingPathComponent("workspace.sqlite")).save(seed, event: "queued remote recovery fixture")
    let probe = RemoteEnvironmentCoreProbe()
    let reopened = try RemoteEnvironmentService(dataDirectory: data, expectedEnvironmentID: identity,
        providerFactory: { try probe.make($0) })
    do {
        let request = RemoteEnvironmentCommandRequest(environmentID: identity,
            command: .submit(threadID: thread.id, text: "A receipt lookup is not dispatch", expectedConfiguration: .init(thread: thread)))
        #expect(try await reopened.receipt(request).receipt == nil)
        let recovered = try await reopened.snapshot(.init(environmentID: identity))
        #expect(recovered.workspace.threads[0].queuePaused)
        #expect(recovered.workspace.threads[0].queuedTurns.map(\.text) == thread.queuedTurns.map(\.text))
        #expect(recovered.workspace.threads[0].activeRun == nil && probe.starts == 0)
        await reopened.close()
    } catch { await reopened.close(); throw error }
}

@Test(arguments: ["finished", "send-failure", "cancelled"])
func remoteEnvironmentSubscriptionLossDisconnectsButReplacementCancellationDoesNot(reason: String) async throws {
    let updates = AsyncStream<RemoteEnvironmentSnapshot>.makeStream()
    let sent = AsyncStream<Void>.makeStream()
    let probe = RemoteEnvironmentSubscriptionProbe()
    let task = Task {
        await RemoteEnvironmentStdio.forwardSubscription(updates.stream, send: { _ in
            sent.continuation.yield(())
            if reason == "send-failure" { throw RemoteEnvironmentError(.unavailable) }
        }, disconnect: { probe.disconnect() })
    }
    updates.continuation.yield(.init(environmentID: UUID(), sequence: 1, workspace: .init()))
    var observed = sent.stream.makeAsyncIterator()
    _ = await observed.next()
    if reason == "cancelled" { task.cancel() }
    else if reason == "finished" { updates.continuation.finish() }
    await task.value
    #expect(probe.disconnects == (reason == "cancelled" ? 0 : 1))
    updates.continuation.finish(); sent.continuation.finish()
}
