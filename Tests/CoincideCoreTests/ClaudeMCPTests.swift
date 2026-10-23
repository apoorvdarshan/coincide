import Darwin
import Foundation
import Testing
@testable import CoincideCore

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func claudeAppMCPRegistrationAcknowledgementGatesConcurrentStartupAndCloseJoinsHeldSetup(closeWhileHeld: Bool) async throws {
    let f = try ClaudeMCPFixture(scenario: "held-ack")
    let session = try f.session()
    let connection = try f.connection()
    #expect(session.supportsAppMCP)
    try await session.configureAppMCP(connection)
    let send = Task { try await session.send(text: "Explicit input after registration", thread: f.thread) }
    let models = Task { try await session.models() }
    do {
        try await claudeMCPEEventually { try f.rows().contains { $0["kind"] == .string("registration-ready") } }
        let held = try f.rows()
        #expect(held.filter { $0["kind"] == .string("initialize") }.count == 1)
        #expect(!held.contains { ["prompt", "set_model", "set_permission_mode", "registration-ack"].contains($0["kind"].string ?? "") })
        if closeWhileHeld {
            async let first: Void = session.close()
            async let second: Void = session.close()
            _ = await (first, second)
            await #expect(throws: (any Error).self) { try await send.value }
            await #expect(throws: (any Error).self) { _ = try await models.value }
            #expect(!(try f.rows()).contains { $0["kind"] == .string("prompt") })
        } else {
            try Data().write(to: f.root.appendingPathComponent("release"))
            try await send.value
            #expect(try await models.value == [.init(id: "fixture-model", name: "Synthetic Claude")])
            try await claudeMCPEEventually { try f.rows().contains { $0["kind"] == .string("prompt") } }
            let rows = try f.rows()
            #expect(rows.filter { $0["kind"] == .string("mcp_set_servers") }.count == 1)
            let ack = try #require(rows.firstIndex { $0["kind"] == .string("registration-ack") })
            let prompt = try #require(rows.firstIndex { $0["kind"] == .string("prompt") })
            #expect(ack < prompt)
            await session.close()
        }
        try f.assertStopped()
        try f.remove()
    } catch { await session.close(); send.cancel(); models.cancel(); _ = try? await send.value; _ = try? await models.value; throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["error-ack", "partial-ack", "removed-ack", "unsupported", "collision", "dynamic", "malformed-status"])
func claudeAppMCPRefusesPartialUnsupportedAndForeignRegistrationWithoutPromptOrCredentialPublication(scenario: String) async throws {
    let f = try ClaudeMCPFixture(scenario: scenario)
    let session = try f.session(), connection = try f.connection()
    let observed = Task { () -> [ProviderEvent] in
        var events: [ProviderEvent] = []
        for await event in session.events { events.append(event) }
        return events
    }
    do {
        try await session.configureAppMCP(connection)
        do {
            try await session.send(text: "Must never reach the native prompt", thread: f.thread)
            Issue.record("A failed native MCP registration admitted a prompt.")
        } catch {
            #expect(error.localizedDescription == "Claude could not configure the app tools. This attempt did not submit a model turn.")
            #expect(!error.localizedDescription.contains(connection.authorizationHeader))
        }
        await session.close()
        let events = await observed.value
        let rendered = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!rendered.contains(connection.authorizationHeader) && !rendered.contains(String(connection.authorizationHeader.dropFirst(7))))
        let rows = try f.rows()
        #expect(!rows.contains { ["prompt", "set_model", "set_permission_mode"].contains($0["kind"].string ?? "") })
        if ["collision", "dynamic", "malformed-status"].contains(scenario) {
            #expect(!rows.contains { $0["kind"] == .string("mcp_set_servers") })
        }
        #expect(!rows.contains { $0["kind"] == .string("peer-failed") })
        try f.assertStopped(); try f.remove()
    } catch { await session.close(); observed.cancel(); _ = await observed.value; throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func claudeMetadataAndLegacyPathsNeverRegisterAppMCPOrCarryCredentials(legacyArguments: Bool) async throws {
    let f = try ClaudeMCPFixture(scenario: "registration")
    let session: ClaudeSession
    if legacyArguments {
        let peer = try #require(Bundle.module.url(forResource: "claude_mcp_server", withExtension: "py", subdirectory: "Fixtures"))
        session = try ClaudeSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: f.workspace,
            arguments: [peer.path, f.root.path])
        #expect(!session.supportsAppMCP)
        await #expect(throws: CoincideError.self) { try await session.configureAppMCP(f.connection()) }
    } else {
        // Captured metadata receives no AppMCPConnection from the Engine.
        session = try f.session()
        #expect(session.supportsAppMCP)
    }
    do {
        #expect(try await session.models().map(\.id) == ["fixture-model"])
        await session.close()
        let rows = try f.rows()
        #expect(rows.filter { $0["kind"] == .string("initialize") }.count == 1)
        #expect(!rows.contains { ["mcp_status", "mcp_set_servers", "prompt"].contains($0["kind"].string ?? "") })
        try f.assertStopped(); try f.remove()
    } catch { await session.close(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["allow", "decline", "full-access"])
func claudeAppMCPActualStdioAndAuthenticatedHTTPRespectApprovalAndReuseSameOwnedRuntime(outcome: String) async throws {
    let f = try ClaudeMCPFixture(scenario: "workflow", permission: outcome == "full-access" ? .fullAccess : .supervised)
    let engine = try WorkspaceEngine(url: f.database, appMCPEnabled: true, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        _ = try await engine.dispatch(.addProjectWithThread(project: f.project, thread: f.thread))
        let firstID = UUID()
        _ = try await engine.dispatch(.submit(threadID: f.thread.id, text: "First explicit native app-tool input"), id: firstID)
        if outcome != "full-access" {
            try await claudeMCPEEventually {
                let thread = await engine.current().snapshot.threads.first { $0.id == f.thread.id }
                let rows = try f.rows()
                return thread?.runtimeRequests.count == 1 && rows.contains { $0["kind"] == .string("read") }
            }
            let pending = try await f.current(engine)
            let approval = try #require(pending.runtimeRequests.first?.request)
            #expect(approval.params["tool_name"] == .string("mcp__coincide__t3_thread_update"))
            #expect(pending.title != f.renamedTitle)
            #expect(!(try f.rows()).contains { $0["kind"] == .string("renamed") })
            _ = try await engine.dispatch(.editThread(f.thread.id, .draft("Concurrent unsent draft 👩🏽‍💻")))
            let receipt = try await engine.dispatch(.respond(threadID: f.thread.id, requestID: approval.id, response: .decision(outcome == "allow")))
            #expect(receipt.rejection == nil)
        }
        let first = try await f.completed(engine, runID: firstID)
        let nativeRuntime = try #require(first.runtimeID)
        #expect(first.title == (outcome == "decline" ? "First explicit native app-tool input" : f.renamedTitle))
        #expect(first.runtimeRequests.isEmpty && first.queuedTurns.isEmpty)
        #expect(first.messages.contains { $0.role == .assistant && $0.text == (outcome == "decline" ? "MCP_DECLINED" : "MCP_FIRST_DONE") })
        if outcome != "full-access" { #expect(first.draft == "Concurrent unsent draft 👩🏽‍💻") }
        let secondID = UUID()
        _ = try await engine.dispatch(.submit(threadID: f.thread.id, text: "Second explicit native read"), id: secondID)
        let second = try await f.completed(engine, runID: secondID)
        #expect(second.runtimeID == nativeRuntime && second.providerThreadID == first.providerThreadID)
        #expect(second.messages.contains { $0.role == .assistant && $0.text == "MCP_SECOND_DONE" })
        #expect(second.runHistory?.count == 2 && second.runHistory?.allSatisfy { $0.status == .completed } == true)
        let rows = try f.rows()
        #expect(rows.filter { $0["kind"] == .string("launch") }.count == 1)
        #expect(rows.filter { $0["kind"] == .string("mcp_set_servers") }.count == 1)
        #expect(rows.filter { $0["kind"] == .string("prompt") }.count == 2)
        #expect(rows.filter { $0["kind"] == .string("read") }.count == 2)
        #expect(rows.filter { $0["kind"] == .string("registration-ready") }.allSatisfy { $0["noSecretOutsideStdin"] == .bool(true) })
        #expect(rows.filter { $0["kind"] == .string("renamed") }.count == (outcome == "decline" ? 0 : 1))
        #expect(rows.contains { $0["kind"] == .string("read") && $0["turn"] == .number(2) && $0["renamed"] == .bool(outcome != "decline") })
        #expect(rows.filter { $0["kind"] == .string("launch") }.allSatisfy { $0["privateEnvironment"] == .bool(true) && $0["secretArgumentsAbsent"] == .bool(true) })
        #expect(!rows.contains { $0["kind"] == .string("peer-failed") })
        let database = try WorkspaceDatabase(url: f.database)
        let journal = try await database.journal(limit: 500)
        let text = String(decoding: try JSONEncoder().encode(journal), as: UTF8.self)
        #expect(!text.contains("Bearer ") && !text.contains("authorizationHeader"))
        let projection = try await database.rebuildProjection().snapshot
        #expect(projection.threads.first { $0.id == f.thread.id }?.runHistory == second.runHistory)
        try WorkspaceJournal.validate(projection)
        await engine.shutdown(); try f.assertStopped()
        let count = try f.rows().count
        let reopened = try WorkspaceEngine(url: f.database, appMCPEnabled: true, identityResolver: { _ in nil })
        do {
            let durable = try await reopened.load()
            #expect(durable.threads.first { $0.id == f.thread.id }?.runHistory == second.runHistory)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
        #expect(try f.rows().count == count)
        try f.remove()
    } catch { await engine.shutdown(); throw error }
}

private struct ClaudeMCPFixture: Sendable {
    let root: URL, workspace: URL, database: URL, executable: URL
    let project: WorkspaceProject
    let thread: CodingThread
    let renamedTitle = "Renamed through supervised Claude app MCP"
    init(scenario: String, permission: PermissionMode = .supervised) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let physical = temporary.path.withCString({ realpath($0, nil) }) else { throw ClaudeRuntimeConfiguration.invalid() }
        root = URL(fileURLWithPath: String(cString: physical)); free(physical)
        workspace = root.appendingPathComponent("Checkout")
        let config = root.appendingPathComponent("Configuration"), home = root.appendingPathComponent("Home")
        for path in [workspace, config, home] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        executable = root.appendingPathComponent("private-claude"); database = root.appendingPathComponent("workspace.sqlite")
        let peer = try #require(Bundle.module.url(forResource: "claude_mcp_server", withExtension: "py", subdirectory: "Fixtures"))
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let wrapper = "#!/bin/sh\nexec /usr/bin/env -i \(quote("HOME=" + home.path)) \(quote("CLAUDE_CONFIG_DIR=" + config.path)) PATH=/usr/bin:/bin /usr/bin/python3 \(quote(peer.path)) \(quote(root.path)) \"$@\"\n"
        try Data(wrapper.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        project = WorkspaceProject(path: workspace.path)
        let runtime = ClaudeRuntimeConfiguration(instanceID: UUID(), executable: executable.path,
            configurationDirectory: config.path, workspacePath: workspace.path, registeredWorkspacePath: project.path)
        var thread = CodingThread(project: project, model: "fixture-model")
        thread.provider = .claude; thread.permission = permission; thread.checkpointPolicy = .disabled
        thread.claudeRuntimeConfiguration = runtime; self.thread = thread
        let settings: JSONValue = .object(["scenario": .string(scenario), "threadID": .string(thread.id.uuidString.lowercased()), "renamedTitle": .string(renamedTitle)])
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"))
    }
    func session() throws -> ClaudeSession {
        try .init(executable: executable, cwd: workspace, configuration: thread.claudeRuntimeConfiguration)
    }
    func connection() throws -> AppMCPConnection {
        try .init(endpoint: URL(string: "http://127.0.0.1:1/mcp")!, authorizationHeader: "Bearer " + String(repeating: "A", count: 43), scopeID: UUID())
    }
    func rows() throws -> [JSONValue] {
        let file = root.appendingPathComponent("audit.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 131_072 else { throw CoincideError("The synthetic Claude MCP audit exceeded its bound.") }
        guard let lastNewline = bytes.lastIndex(of: 10) else { return [] }
        return try bytes[...lastNewline].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func current(_ engine: WorkspaceEngine) async throws -> CodingThread {
        try #require(await engine.current().snapshot.threads.first { $0.id == thread.id })
    }
    func completed(_ engine: WorkspaceEngine, runID: UUID) async throws -> CodingThread {
        try await claudeMCPEEventually {
            let value = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return value?.activeRun == nil && value?.runHistory?.contains { $0.id == runID && $0.status == .completed } == true
        }
        return try await current(engine)
    }
    func assertStopped() throws {
        let launches = try rows().filter { $0["kind"] == .string("launch") }
        #expect(!launches.isEmpty)
        for launch in launches {
            guard case .number(let value) = launch["pid"] else { throw CoincideError("The synthetic Claude peer did not record its owner.") }
            errno = 0
            #expect(Darwin.kill(pid_t(value), 0) == -1 && errno == ESRCH)
        }
    }
    func remove() throws { try FileManager.default.removeItem(at: root) }
}

private func claudeMCPEEventually(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private Claude MCP peer did not reach its owned boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
