import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Actual native host + production client/codec + SQLite. The only provider is
/// a private, cwd/home-confined app-server peer; no installed CLI or account runs.
private struct RemoteAcceptanceFixture: Sendable {
    let root: URL, workspace: URL, data: URL, host: URL, provider: URL, proxy: URL
    var arguments: [String] {
        ["--stdio", "--data-directory", data.path, "--label", "Offline native acceptance",
         "--codex-executable", provider.path, "--codex-home", root.appendingPathComponent("codex-home").path]
    }
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.appendingPathComponent("home").path,
         "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
    }
    static func make() throws -> Self {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("coincide-remote-acceptance-" + UUID().uuidString).resolvingSymlinksInPath()
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let workspace = root.appendingPathComponent("workspace"), data = root.appendingPathComponent("data")
            for directory in [workspace, data, root.appendingPathComponent("home"), root.appendingPathComponent("codex-home")] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let peer = try #require(Bundle.module.url(forResource: "remote_environment_provider", withExtension: "py", subdirectory: "Fixtures"))
            let proxy = try #require(Bundle.module.url(forResource: "remote_environment_proxy", withExtension: "py", subdirectory: "Fixtures"))
            #if DEBUG
            let configuration = "debug"
            #else
            let configuration = "release"
            #endif
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let executable = checkout.appendingPathComponent(".build/\(configuration)/CoincideEnvironment")
            guard manager.isExecutableFile(atPath: executable.path) else {
                throw CoincideError("SwiftPM must build the matching native CoincideEnvironment executable dependency.")
            }
            let host = root.appendingPathComponent("native-host"), provider = root.appendingPathComponent("offline-codex")
            let hostScript = "#!/bin/sh\numask 077\nprintf '%s\\n' \"$$\" >> \(quoted(root.appendingPathComponent("host-pids.txt").path))\nexec \(quoted(executable.path)) \"$@\"\n"
            let providerScript = "#!/bin/sh\nexec /usr/bin/python3 \(quoted(peer.path)) \(quoted(root.path)) \"$@\"\n"
            for (url, text) in [(host, hostScript), (provider, providerScript)] {
                try text.write(to: url, atomically: false, encoding: .utf8)
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
            return .init(root: root, workspace: workspace, data: data, host: host, provider: provider, proxy: proxy)
        } catch { try? manager.removeItem(at: root); throw error }
    }
    private static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func connection(proxyMode: String? = nil, droppedID: UUID? = nil) throws -> JSONRPCConnection {
        if let proxyMode {
            return try .init(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [proxy.path, root.path, proxyMode, droppedID?.uuidString ?? "none", host.path] + arguments,
                cwd: root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                environment: environment, drainProcessOnClose: true)
        }
        return try .init(executable: host, arguments: arguments, cwd: root, dialect: .jsonRPC2,
            maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes, environment: environment, drainProcessOnClose: true)
    }
    func rows(_ kind: String) throws -> [JSONValue] {
        let file = root.appendingPathComponent("provider-wire.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try Data(contentsOf: file).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
            .filter { $0["kind"].string == kind }
    }
    func expectDrained() async throws {
        let path = root.appendingPathComponent("host-pids.txt")
        let hosts = try String(contentsOf: path, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        let providers = try rows("launch").compactMap { row -> Int32? in
            guard case .number(let value) = row["pid"] else { return nil }
            return Int32(exactly: value)
        }
        try await remoteAcceptanceEventually("every exact owned host/provider process to exit") {
            (hosts + providers).allSatisfy { kill($0, 0) == -1 && errno == ESRCH }
        }
        #expect(try rows("exit").count == providers.count)
    }
    func remove() throws { try FileManager.default.removeItem(at: root) }
    func retainFailure(_ snapshot: RemoteEnvironmentSnapshot?) {
        if let snapshot, let bytes = try? JSONEncoder().encode(snapshot) {
            _ = FileManager.default.createFile(atPath: root.appendingPathComponent("failed-snapshot.json").path,
                contents: bytes, attributes: [.posixPermissions: 0o600])
        }
        print("Synthetic remote acceptance failure retained at \(root.path)")
    }
}

private final class RemoteAcceptanceConnections: @unchecked Sendable {
    let fixture: RemoteAcceptanceFixture, mode: String
    let droppedID: UUID?
    let proxyLaunch: Int
    private let lock = NSLock()
    private var launches = 0
    init(_ fixture: RemoteAcceptanceFixture, mode: String, droppedID: UUID? = nil, proxyLaunch: Int = 0) {
        self.fixture = fixture; self.mode = mode; self.droppedID = droppedID; self.proxyLaunch = proxyLaunch
    }
    func make() throws -> JSONRPCConnection {
        let proxied = lock.withLock { let selected = launches == proxyLaunch; launches += 1; return selected }
        return try fixture.connection(proxyMode: proxied ? mode : nil, droppedID: droppedID)
    }
}

private actor RemoteAcceptanceEvents {
    private var snapshots: [RemoteEnvironmentSnapshot] = []
    private(set) var refusedSequenceRegression = false
    func consume(_ event: RemoteEnvironmentClientEvent) {
        if case .snapshot(let value) = event { snapshots.append(value) }
        if case .disconnected(let error) = event, error.kind == .sequenceRegression { refusedSequenceRegression = true }
    }
    func streamed(_ text: String, threadID: UUID) -> Bool {
        snapshots.contains { $0.workspace.threads.contains { $0.id == threadID && $0.messages.contains { $0.role == .assistant && $0.text.contains(text) } } }
    }
}

private func remoteAcceptanceEventually(_ detail: String, _ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Native remote acceptance did not reach: " + detail) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func remoteAcceptanceThread(_ client: RemoteEnvironmentClient, _ id: UUID) async throws -> CodingThread {
    let snapshot = await client.currentSnapshot()
    return try #require(snapshot?.workspace.threads.first { $0.id == id })
}
private func remoteAcceptanceCreate(_ client: RemoteEnvironmentClient, fixture: RemoteAcceptanceFixture) async throws -> UUID {
    let project = UUID(), thread = UUID()
    let added = try await client.command(.addProject(id: project, path: fixture.workspace.path, title: "Remote project"))
    #expect(added.receipt.rejection == nil)
    let created = try await client.command(.createThread(id: thread, projectID: project, provider: .codex,
        title: "Remote conversation", model: "remote-offline", permission: .supervised))
    #expect(created.receipt.rejection == nil)
    try await remoteAcceptanceEventually("subscribed conversation creation") {
        await client.currentSnapshot()?.workspace.threads.contains { $0.id == thread } == true
    }
    return thread
}
private func remoteAcceptanceRejected(_ command: RemoteEnvironmentCommand, client: RemoteEnvironmentClient) async throws {
    do { #expect(try await client.command(command).receipt.rejection != nil) }
    catch let error as RemoteEnvironmentClientError { #expect(error.kind == .commandUncertain) }
}

@Test(.timeLimit(.minutes(1)))
func remoteNativeHostStreamsApprovalsExactRunStopAndDurableWorkspaceThroughProductionClient() async throws {
    let fixture = try RemoteAcceptanceFixture.make()
    let connections = RemoteAcceptanceConnections(fixture, mode: "sequence-regression", proxyLaunch: 1)
    let client = RemoteEnvironmentClient(factory: { try connections.make() }), events = RemoteAcceptanceEvents()
    let observer = Task { for await event in client.events { await events.consume(event) } }
    do {
        let descriptor = try await client.discover()
        #expect(descriptor.protocolVersion == 1 && !descriptor.capabilities.persistentDaemon)
        #expect(descriptor.capabilities.providers.contains(.codex) && descriptor.capabilities.supportsExactRunStop)
        await #expect(throws: RemoteEnvironmentClientError(.trustRequired)) { _ = try await client.connect() }
        try await client.trust(environmentID: descriptor.environmentID)
        let initial = try await client.connect()
        #expect(initial.environmentID == descriptor.environmentID && initial.workspace.projects.isEmpty)
        let threadID = try await remoteAcceptanceCreate(client, fixture: fixture)
        let prepared = try await remoteAcceptanceThread(client, threadID)
        let prompt = RemoteEnvironmentCommand.submit(threadID: threadID, text: "Approve this remote prompt", expectedConfiguration: .init(thread: prepared))
        let sent = try await client.command(prompt)
        #expect(sent.receipt.rejection == nil)
        try await remoteAcceptanceEventually("pushed streaming text and exact approval") {
            let thread = await client.currentSnapshot()?.workspace.threads.first { $0.id == threadID }
            let streamed = await events.streamed("REMOTE_STREAM_🌍", threadID: threadID)
            return thread?.runtimeRequests.count == 1 && streamed
        }
        let waiting = try await remoteAcceptanceThread(client, threadID)
        let runID = try #require(waiting.activeRun?.id), runtimeID = try #require(waiting.runtimeID)
        let request = try #require(waiting.runtimeRequests.first?.request)
        #expect(request.id == .string("remote-approval-1"))
        var changed = request; changed.params = .object(["threadId": .string("remote-native-thread"), "command": .string("different command")])
        try await remoteAcceptanceRejected(.respond(threadID: threadID, runID: runID, runtimeID: runtimeID,
            request: changed, response: .decision(true)), client: client)
        #expect(try fixture.rows("approval-response").isEmpty)
        let approved = try await client.command(.respond(threadID: threadID, runID: runID, runtimeID: runtimeID,
            request: request, response: .decision(true)))
        #expect(approved.receipt.rejection == nil)
        try await remoteAcceptanceEventually("one approved completed native turn") {
            let thread = await client.currentSnapshot()?.workspace.threads.first { $0.id == threadID }
            return thread?.activeRun == nil && thread?.runHistory?.first?.status == .completed
        }
        let approvals = try fixture.rows("approval-response")
        #expect(approvals.count == 1 && approvals.first?["frame"]["result"]["decision"] == .string("accept"))
        let completed = try await remoteAcceptanceThread(client, threadID)
        #expect(completed.messages.contains { $0.role == .assistant && $0.text == "REMOTE_STREAM_🌍_APPROVED" })
        let held = try await client.command(.submit(threadID: threadID, text: "Hold for exact remote stop", expectedConfiguration: .init(thread: completed)))
        #expect(held.receipt.rejection == nil)
        try await remoteAcceptanceEventually("second native active turn") {
            let thread = await client.currentSnapshot()?.workspace.threads.first { $0.id == threadID }
            return thread?.activeRun?.nativeTurnID == "remote-turn-2"
        }
        let current = try await remoteAcceptanceThread(client, threadID)
        let currentRun = try #require(current.activeRun?.id), currentRuntime = try #require(current.runtimeID)
        try await remoteAcceptanceRejected(.stop(threadID: threadID, runID: runID, runtimeID: runtimeID), client: client)
        try await remoteAcceptanceRejected(.stop(threadID: threadID, runID: currentRun, runtimeID: UUID()), client: client)
        #expect(try fixture.rows("interrupt").isEmpty)
        let stopID = UUID(), stop = RemoteEnvironmentCommand.stop(threadID: threadID, runID: currentRun, runtimeID: currentRuntime)
        let stopped = try await client.command(stop, id: stopID)
        #expect(stopped.receipt.rejection == nil)
        try await remoteAcceptanceEventually("exact interrupted run") {
            let thread = await client.currentSnapshot()?.workspace.threads.first { $0.id == threadID }
            return thread?.activeRun == nil && thread?.state == .interrupted
        }
        #expect(try fixture.rows("interrupt").map { $0["turnID"].string } == ["remote-turn-2"])
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: stopID)) { _ = try await client.command(stop, id: stopID) }
        #expect(try await client.receipt(for: stop, id: stopID).receipt == stopped.receipt)
        let finished = try await remoteAcceptanceThread(client, threadID)
        let draft = "Remote draft preserved without a new input"
        #expect(try await client.command(.editThread(threadID: threadID, edit: .draft(draft), expectedConfiguration: .init(thread: finished))).receipt.rejection == nil)
        try await remoteAcceptanceEventually("pushed saved remote draft") {
            await client.currentSnapshot()?.workspace.threads.first { $0.id == threadID }?.draft == draft
        }
        let beforeRegression = try #require(await client.currentSnapshot())
        await #expect(throws: (any Error).self) { _ = try await client.reconnect() }
        try await remoteAcceptanceEventually("explicit sequence-regression refusal") { await events.refusedSequenceRegression }
        #expect(await client.currentSnapshot()?.sequence == beforeRegression.sequence)
        let restored = try await client.reconnect()
        let saved = try #require(restored.workspace.threads.first { $0.id == threadID })
        #expect(restored.environmentID == descriptor.environmentID && saved.draft == draft && restored.sequence >= beforeRegression.sequence)
        #expect(saved.runHistory?.map(\.status) == [.completed, .interrupted] && saved.activeRun == nil)
        #expect(try fixture.rows("turn-start").count == 2 && fixture.rows("approval-response").count == 1)
        await client.close(); observer.cancel(); await observer.value
        try await fixture.expectDrained(); try fixture.remove()
    } catch {
        fixture.retainFailure(await client.currentSnapshot())
        await client.close(); observer.cancel(); await observer.value; throw error
    }
}

@Test(.timeLimit(.minutes(1)))
func remoteNativeHostDroppedCommittedReplyReconcilesExactReceiptAndNeverReplaysInputOnReconnect() async throws {
    let fixture = try RemoteAcceptanceFixture.make(), commandID = UUID()
    let connections = RemoteAcceptanceConnections(fixture, mode: "drop-command-response", droppedID: commandID)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let descriptor = try await client.discover(); try await client.trust(environmentID: descriptor.environmentID)
        _ = try await client.connect()
        let threadID = try await remoteAcceptanceCreate(client, fixture: fixture), thread = try await remoteAcceptanceThread(client, threadID)
        let submit = RemoteEnvironmentCommand.submit(threadID: threadID, text: "Remote prompt with dropped reply", expectedConfiguration: .init(thread: thread))
        await #expect(throws: RemoteEnvironmentClientError(.commandUncertain, commandID: commandID)) { _ = try await client.command(submit, id: commandID) }
        let dropped = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture.root.appendingPathComponent("dropped-command-response.json")))
        let committed = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCommandResult.self, from: dropped["result"])
        #expect(committed.receipt.commandID == commandID && committed.receipt.rejection == nil)
        #expect(try fixture.rows("turn-start").count == 1)
        let reconnected = try await client.reconnect()
        let recovered = try #require(reconnected.workspace.threads.first { $0.id == threadID })
        #expect(reconnected.environmentID == descriptor.environmentID)
        #expect(recovered.messages.filter { $0.role == .user && $0.text == "Remote prompt with dropped reply" }.count == 1)
        #expect(recovered.activeRun == nil && recovered.state == .interrupted)
        let receipt = try await client.receipt(for: submit, id: commandID)
        #expect(receipt.environmentID == descriptor.environmentID && receipt.receipt == committed.receipt)
        let changed = RemoteEnvironmentCommand.submit(threadID: threadID, text: "Must never replace the original payload", expectedConfiguration: .init(thread: thread))
        await #expect(throws: (any Error).self) { _ = try await client.receipt(for: changed, id: commandID) }
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: commandID)) { _ = try await client.command(submit, id: commandID) }
        #expect(try fixture.rows("turn-start").count == 1 && fixture.rows("launch").count == 1)
        #expect(try await client.snapshot().workspace.threads.first { $0.id == threadID }?.messages.filter { $0.role == .user }.count == 1)
        await client.close(); try await fixture.expectDrained(); try fixture.remove()
    } catch {
        fixture.retainFailure(await client.currentSnapshot())
        await client.close(); throw error
    }
}

@Test(.timeLimit(.minutes(1)))
func remoteNativeHostAndClientRefuseUntrustedWrongProtocolAndForeignEnvironmentBeforeMutation() async throws {
    let fixture = try RemoteAcceptanceFixture.make()
    let first = RemoteEnvironmentClient(factory: { try fixture.connection() })
    var clients: [RemoteEnvironmentClient] = [first]
    var raw: JSONRPCConnection?
    do {
        let descriptor = try await first.discover()
        let registration = RemoteEnvironmentCommand.addProject(id: UUID(), path: fixture.workspace.path, title: "Must remain absent")
        await #expect(throws: RemoteEnvironmentClientError(.trustRequired)) { _ = try await first.command(registration) }
        await first.close()
        let wrong = RemoteEnvironmentClient(factory: { try fixture.connection() }, expectedEnvironmentID: UUID())
        clients.append(wrong)
        await #expect(throws: RemoteEnvironmentClientError(.wrongEnvironment)) { _ = try await wrong.discover() }
        await wrong.close()
        let proxy = RemoteAcceptanceConnections(fixture, mode: "wrong-protocol")
        let incompatible = RemoteEnvironmentClient(factory: { try proxy.make() }, expectedEnvironmentID: descriptor.environmentID)
        clients.append(incompatible)
        await #expect(throws: RemoteEnvironmentClientError(.unsupported)) { _ = try await incompatible.discover() }
        await incompatible.close()
        #expect(!FileManager.default.fileExists(atPath: fixture.data.appendingPathComponent("workspace.sqlite").path),
                "Untrusted or incompatible discovery must not open the remote workspace database.")
        let connection = try fixture.connection(); raw = connection
        let described = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentDescriptor.self,
            from: await connection.request(RemoteEnvironmentProtocol.describeMethod))
        #expect(described.environmentID == descriptor.environmentID && described.protocolVersion == 1)
        let foreign = RemoteEnvironmentCommandRequest(environmentID: UUID(), command: registration)
        await #expect(throws: JSONRPCRemoteError.self) {
            _ = try await connection.request(RemoteEnvironmentProtocol.commandMethod, params: RemoteEnvironmentProtocol.encode(foreign))
        }
        let valid = RemoteEnvironmentSnapshotRequest(environmentID: descriptor.environmentID)
        let snapshot = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentSnapshot.self,
            from: await connection.request(RemoteEnvironmentProtocol.snapshotMethod, params: RemoteEnvironmentProtocol.encode(valid)))
        #expect(snapshot.environmentID == descriptor.environmentID && snapshot.workspace.projects.isEmpty && snapshot.workspace.threads.isEmpty)
        #expect(try fixture.rows("launch").isEmpty)
        await connection.close(); try await fixture.expectDrained(); try fixture.remove()
    } catch {
        fixture.retainFailure(await first.currentSnapshot())
        for client in clients { await client.close() }; await raw?.close(); throw error
    }
}

/// Actual packaged helper wiring is exercised without ever sending open or
/// input. Discovery and unknown-reference reads cannot start a login shell.
@Test(.timeLimit(.minutes(1)))
func remoteNativeHostTerminalDiscoveryAndUnknownReferenceReadsNeverOpenAShell() async throws {
    let fixture = try RemoteAcceptanceFixture.make(), connection = try fixture.connection()
    let client = RemoteEnvironmentClient(factory: { connection })
    do {
        let descriptor = try await client.discover()
        #expect(descriptor.capabilities.supportsRemoteTerminal,
                "The actual helper must truthfully advertise its injected native PTY driver.")
        try await client.trust(environmentID: descriptor.environmentID)
        _ = try await client.connect()
        let project = WorkspaceProject(path: fixture.workspace.path), thread = CodingThread(project: project)
        let target = RemoteWorkspaceTarget(environmentID: descriptor.environmentID, projectID: project.id, threadID: thread.id,
            configuration: .init(thread: thread), rootID: UUID())
        let unknown = RemoteTerminalReference(target: target, terminalID: UUID(), incarnation: UUID())
        await #expect(throws: RemoteTerminalFailure(.notFound)) { _ = try await client.attachTerminal(unknown) }
        await #expect(throws: RemoteTerminalFailure(.notFound)) { _ = try await client.readTerminal(.init(reference: unknown)) }
        await #expect(throws: RemoteTerminalFailure(.notFound)) {
            _ = try await client.terminalInputReceipt(.init(reference: unknown, sequence: 1,
                digest: RemoteTerminalProtocol.inputDigest(Data([0]))))
        }
        await #expect(throws: RemoteTerminalFailure(.invalidTarget)) { _ = try await client.listTerminals(target) }
        do {
            _ = try await connection.request("remoteEnvironment.terminal.execute", params: .object([:]))
            Issue.record("An unallowlisted terminal execution method must be refused.")
        } catch let error as JSONRPCRemoteError {
            #expect(error.code == -32_000 && error.data["kind"] == .string("unsupported"))
        }
        let unchanged = try await client.snapshot()
        #expect(unchanged.workspace.projects.isEmpty && unchanged.workspace.threads.isEmpty)
        #expect(try fixture.rows("launch").isEmpty)
        // The owned transport closes without a terminal open. Host shutdown
        // must still await the engine/driver service before its exact PID ends.
        await connection.close(); await client.close()
        try await fixture.expectDrained(); try fixture.remove()
    } catch {
        fixture.retainFailure(await client.currentSnapshot())
        await connection.close(); await client.close(); throw error
    }
}
