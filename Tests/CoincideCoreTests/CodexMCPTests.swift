import Darwin
import Foundation
import Testing
@testable import CoincideCore

@Test(.timeLimit(.minutes(1)), arguments: ["fresh", "resume", "minimal-status"])
func codexAppMCPStdioOverridePreservesForeignServersAndConfirmsScopedCatalogBeforeCapturedPrompt(kind: String) async throws {
    let f = try CodexMCPFixture(options: ["minimalStatus": .bool(kind == "minimal-status"), "releaseTurn1": .string("gate")])
    try await withCodexMCPPeer(f) { session, connection in
        var thread = f.thread
        if kind == "resume" { thread.providerThreadID = "already-owned-native-thread" }
        thread.reasoningEffort = "high"
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
        // A future header edit cannot change an already accepted turn.
        thread.model = "future-header-model"; thread.reasoningEffort = "low"; thread.permission = .fullAccess
        try await session.configureAppMCP(connection)
        try await session.send(text: "Exact captured input 工作", thread: thread)
        try await codexMCPEEventually { try f.rows().contains { $0["method"] == .string("turn/start") } }
        await #expect(throws: (any Error).self) { try await session.configureAppMCP(connection) }
        let rows = try f.rows(), method = kind == "resume" ? "thread/resume" : "thread/start"
        let registrationIndex = try #require(rows.firstIndex { $0["method"] == .string(method) })
        let initialIndex = try #require(rows.firstIndex { $0["method"] == .string("mcpServerStatus/list") && $0["threadId"] == .null })
        let scopedIndex = try #require(rows.firstIndex { $0["method"] == .string("mcpServerStatus/list") && $0["threadId"] != .null })
        let promptIndex = try #require(rows.firstIndex { $0["method"] == .string("turn/start") })
        #expect(initialIndex < registrationIndex && registrationIndex < scopedIndex && scopedIndex < promptIndex)
        let registration = rows[registrationIndex], prompt = rows[promptIndex]
        #expect(registration["configKeys"] == .array([.string("mcp_optional_startup_grace_ms"), .string("mcp_servers.coincide")]))
        #expect(registration["owned"]["keys"] == .array([.string("http_headers"), .string("tool_timeout_sec"), .string("url")]))
        #expect(registration["owned"]["headerNames"] == .array([.string("Authorization")]))
        #expect(registration["owned"]["toolTimeout"] == .number(3_900) && registration["owned"]["startupGrace"] == .number(10_000))
        #expect(registration["owned"]["headerInArguments"] == .bool(false) && registration["owned"]["headerInEnvironment"] == .bool(false))
        #expect(prompt["model"] == .string("wire-model") && prompt["effort"] == .string("high"))
        #expect(prompt["approvalPolicy"] == PermissionMode.supervised.approvalPolicy)
        #expect(rows.contains { $0["kind"] == .string("foreignServers") && $0["unchanged"] == .bool(true) })
        #expect(!rows.contains { ($0["method"].string ?? "").contains("write") })
        let audit = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
        #expect(!audit.contains(connection.authorizationHeader) && !audit.contains(String(connection.authorizationHeader.dropFirst(7))))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["collision", "registrationError", "statusError", "missingTools", "wrongOrigin"])
func codexAppMCPRegistrationFailureHasNoPromptFallbackAndNoCredentialInErrorsOrEvents(kind: String) async throws {
    let f = try CodexMCPFixture(options: [kind: .bool(true)])
    try await withCodexMCPPeer(f) { session, connection in
        let observed = Task { () -> [ProviderEvent] in
            var values: [ProviderEvent] = []
            for await value in session.events { values.append(value) }
            return values
        }
        try await session.configureAppMCP(connection)
        do {
            try await session.send(text: "Must not reach a native prompt", thread: f.thread)
            Issue.record("An unconfirmed Codex MCP registration admitted a prompt.")
        } catch {
            #expect(error.localizedDescription == "The Codex app tool connection could not be confirmed. No prompt was sent.")
            #expect(!error.localizedDescription.contains(connection.authorizationHeader))
        }
        await session.close()
        let rendered = String(decoding: try JSONEncoder().encode(await observed.value), as: UTF8.self)
        #expect(!rendered.contains(connection.authorizationHeader) && !rendered.contains(String(connection.authorizationHeader.dropFirst(7))))
        let rows = try f.rows()
        #expect(!rows.contains { $0["method"] == .string("turn/start") })
        if kind == "collision" { #expect(!rows.contains { $0["method"] == .string("thread/start") }) }
        #expect(rows.filter { $0["method"] == .string("thread/start") }.count <= 1)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["Registration", "Status"])
func codexAppMCPHeldNativeAcknowledgementCannotRaceCloseIntoPrompt(stage: String) async throws {
    let marker = stage.lowercased() + "Entered"
    let f = try CodexMCPFixture(options: ["release" + stage: .string("gate"), marker: .string("marker")])
    try await withCodexMCPPeer(f) { session, connection in
        try await session.configureAppMCP(connection)
        let pending = Task { try await session.send(text: "Held registration input", thread: f.thread) }
        do {
            try await codexMCPEEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent(marker).path) }
            #expect(!(try f.rows()).contains { $0["method"] == .string("turn/start") })
            async let first: Void = session.close()
            async let second: Void = session.close()
            _ = await (first, second)
            await #expect(throws: (any Error).self) { try await pending.value }
            #expect(!(try f.rows()).contains { $0["method"] == .string("turn/start") })
        } catch { f.releaseAll(); pending.cancel(); await session.close(); _ = try? await pending.value; throw error }
    }
}

@Test(.timeLimit(.minutes(1)))
func codexMetadataWithoutAppMCPNeverRegistersAThreadOrTouchesMCPConfiguration() async throws {
    let f = try CodexMCPFixture()
    let session = try f.session()
    do {
        #expect(try await session.models().map(\.id) == ["wire-model"])
        await session.close()
        let methods = try f.rows().compactMap { $0["method"].string }
        #expect(methods.filter { $0 == "initialize" }.count == 1)
        #expect(methods.allSatisfy { ["initialize", "initialized", "model/list"].contains($0) })
        try f.assertStopped(); try f.remove()
    } catch { await session.close(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], ["command", "elicitation"])
func codexAppMCPProductionFactoryRoutesNativeToolsThroughEngineAndRetainsFIFOApprovalStopAndDurability(decline: Bool, approvalKind: String) async throws {
    let f = try CodexMCPFixture(options: ["invokeTools": .bool(true), "approval": .bool(true), "approvalKind": .string(approvalKind), "lateOriginalTool": .bool(true),
        "readObserved": .string("marker"), "writeObserved": .string("marker"), "turnReady2": .string("marker"),
        "releaseTurn1": .string("gate"), "releaseTurn2": .string("gate")])
    // This is the production factory, native CodexSession, real JSON-RPC pipes,
    // authenticated HTTP server and Engine tool facade. Only the child is fake.
    let engine = try WorkspaceEngine(url: f.database, appMCPEnabled: true, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        _ = try await engine.dispatch(.addProjectWithThread(project: f.project, thread: f.thread))
        let firstID = UUID(), secondID = UUID()
        _ = try await engine.dispatch(.submit(threadID: f.thread.id, text: "Original Codex app-tool input"), id: firstID)
        try await codexMCPEEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == f.thread.id }
            return current?.runtimeRequests.count == 1 && FileManager.default.fileExists(atPath: f.root.appendingPathComponent("readObserved").path)
        }
        let pending = try await f.current(engine)
        let approval = try #require(pending.runtimeRequests.first?.request)
        #expect(approval.method == (approvalKind == "elicitation" ? CodexMCPApproval.method : "item/commandExecution/requestApproval"))
        if approvalKind == "elicitation" {
            #expect(approval.title == "Approve Rename thread" && approval.detail.contains(f.renamedTitle) && !approval.isQuestion)
        }
        #expect(pending.title != f.renamedTitle)
        let originalRuntime = try #require(pending.runtimeID)
        _ = try await engine.dispatch(.editThread(f.thread.id, .model("future-wire-model")))
        _ = try await engine.dispatch(.submit(threadID: f.thread.id, text: "Explicit FIFO successor"), id: secondID)
        _ = try await engine.dispatch(.editThread(f.thread.id, .draft("Latest unsent user draft 👩🏽‍💻")))
        #expect((try await f.current(engine)).queuedTurns.map(\.id) == [secondID])
        let response = try await engine.dispatch(.respond(threadID: f.thread.id, requestID: approval.id, response: .decision(!decline)))
        #expect(response.rejection == nil)
        if !decline {
            try await codexMCPEEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("writeObserved").path) }
            let changed = try await f.current(engine)
            #expect(changed.title == f.renamedTitle && changed.activeRun?.id == firstID)
            #expect((try f.rows()).filter { $0["method"] == .string("turn/start") }.count == 1)
        }
        try f.release("releaseTurn1")
        try await codexMCPEEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == f.thread.id }
            return current?.activeRun?.id == secondID && current?.activeRun?.nativeTurnID == "codex-mcp-turn-2"
                && FileManager.default.fileExists(atPath: f.root.appendingPathComponent("turnReady2").path)
        }
        let second = try await f.current(engine)
        #expect(second.runtimeID == originalRuntime && second.providerThreadID == "codex-mcp-thread")
        #expect(second.title == (decline ? "Original Codex app-tool input" : f.renamedTitle))
        #expect(second.draft == "Latest unsent user draft 👩🏽‍💻" && second.queuedTurns.isEmpty && second.runtimeRequests.isEmpty)
        #expect(second.runHistory?.first { $0.id == firstID }?.status == .completed)
        let read = try #require(second.messages.first { $0.providerEntity?.key.id == "native-mcp-read" })
        #expect(read.runReference == .init(threadID: f.thread.id, runID: firstID))
        #expect(read.providerEntity?.fields["status"] == .string("completed"))
        #expect(read.providerEntity?.fields["rawInput"]["threadId"] == .string(f.thread.id.uuidString.lowercased()))
        // The old native result arrives during the successor. It must not be
        // retagged, and terminal contexts deliberately cannot mutate old output.
        #expect(read.providerEntity?.fields["rawOutput"]["lateOriginal"] == .null)
        _ = try await engine.dispatch(.interrupt(threadID: f.thread.id))
        try await codexMCPEEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == f.thread.id }
            return current?.activeRun == nil && current?.runHistory?.first { $0.id == secondID }?.status == .interrupted
        }
        let settled = try await f.current(engine), rows = try f.rows()
        let prompts = rows.filter { $0["method"] == .string("turn/start") }
        #expect(prompts.map { $0["model"] } == [.string("wire-model"), .string("future-wire-model")])
        #expect(rows.filter { $0["method"] == .string("thread/start") }.count == 1)
        #expect(rows.filter { $0["method"] == .string("mcpServerStatus/list") && $0["threadId"] != .null }.count == 2)
        #expect(rows.filter { $0["method"] == .string("turn/interrupt") }.count == 1)
        #expect(rows.filter { $0["kind"] == .string("mcpCall") && $0["tool"] == .string("t3_thread_update") }.count == (decline ? 0 : 1))
        #expect(!rows.contains { $0["kind"] == .string("flowFailure") })
        let database = try WorkspaceDatabase(url: f.database)
        let journal = try await database.journal(limit: 500)
        let encoded = String(decoding: try JSONEncoder().encode(journal), as: UTF8.self)
        #expect(!encoded.contains("Bearer ") && !encoded.contains("authorizationHeader") && !encoded.contains("http_headers"))
        let rebuilt = try await database.rebuildProjection().snapshot
        #expect(rebuilt.threads.first { $0.id == f.thread.id }?.runHistory == settled.runHistory)
        try WorkspaceJournal.validate(rebuilt)
        await engine.shutdown(); try f.assertStopped()
        let count = try f.rows().count
        let reopened = try WorkspaceEngine(url: f.database, appMCPEnabled: true, identityResolver: { _ in nil })
        do {
            let snapshot = try await reopened.load()
            #expect(snapshot.threads.first { $0.id == f.thread.id }?.runHistory == settled.runHistory)
            #expect(snapshot.threads.first { $0.id == f.thread.id }?.draft == settled.draft)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
        #expect(try f.rows().count == count)
        try f.remove()
    } catch { f.releaseAll(); await engine.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["foreign-thread", "foreign-turn", "missing-turn", "nonempty-form", "url", "foreign-kind"])
func codexAppMCPDeclinesUnsupportedOrUnownedElicitationsWithoutPresentingOrRenaming(shape: String) async throws {
    let f = try CodexMCPFixture(options: ["invokeTools": .bool(true), "approval": .bool(true),
        "approvalKind": .string("elicitation"), "elicitationShape": .string(shape)])
    let engine = try WorkspaceEngine(url: f.database, appMCPEnabled: true, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        _ = try await engine.dispatch(.addProjectWithThread(project: f.project, thread: f.thread))
        let runID = UUID()
        _ = try await engine.dispatch(.submit(threadID: f.thread.id, text: "Explicit synthetic approval test"), id: runID)
        try await codexMCPEEventually {
            let thread = try await f.current(engine)
            #expect(thread.runtimeRequests.isEmpty)
            return thread.runHistory?.first(where: { $0.id == runID })?.status == .completed
        }
        let thread = try await f.current(engine)
        #expect(thread.title != f.renamedTitle && thread.runtimeRequests.isEmpty)
        let rows = try f.rows()
        #expect(rows.contains { $0["kind"] == .string("approvalResponse") && $0["allowed"] == .bool(false) })
        #expect(!rows.contains { $0["kind"] == .string("mcpCall") && $0["tool"] == .string("t3_thread_update") })
        await engine.shutdown(); try f.assertStopped(); try f.remove()
    } catch { await engine.shutdown(); throw error }
}

@Test func codexAppMCPApprovalPreservesPresentationAndNeverEchoesRememberOptions() throws {
    let params: JSONValue = .object(["threadId": .string("native-thread"), "turnId": .string("native-turn"),
        "serverName": .string("coincide"), "mode": .string("form"), "message": .string("Review the exact rename."),
        "requestedSchema": .object(["type": .string("object"), "properties": .object([:])]),
        "_meta": .object(["codex_approval_kind": .string("mcp_tool_call"), "persist": .array([.string("session"), .string("always")]),
            "tool_title": .string("Rename thread"), "tool_params": .object(["title": .string("Exact title 工作")])])])
    let request = ApprovalRequest(id: .number(42), method: CodexMCPApproval.method, params: params)
    let approval = try #require(request.codexMCPApproval)
    #expect(!request.isQuestion && request.title == "Approve Rename thread")
    #expect(request.detail.contains("Review the exact rename.") && request.detail.contains("Exact title 工作"))
    #expect(approval.response(allow: true) == .object(["action": .string("accept"), "content": .object([:]), "_meta": .null]))
    #expect(approval.response(allow: false) == .object(["action": .string("decline"), "content": .null, "_meta": .null]))
    var invalid = try #require(params.object)
    invalid["requestedSchema"] = .object(["type": .string("object"), "properties": .object([:]), "required": .array([.string("answer")])])
    #expect(throws: MCPError.self) { try CodexMCPApproval(params: .object(invalid)) }
    invalid["requestedSchema"] = .object(["type": .string("object"), "properties": .object([:]), "oneOf": .array([])])
    #expect(throws: MCPError.self) { try CodexMCPApproval(params: .object(invalid)) }
}

@Test(.timeLimit(.minutes(1)))
func codexAppMCPApprovalRejectsChangedOrAlreadyAnsweredRequestsBeforeNativeResponse() async throws {
    let f = try CodexMCPFixture(options: ["invokeTools": .bool(true), "approval": .bool(true), "approvalKind": .string("elicitation")])
    try await withCodexMCPPeer(f) { session, connection in
        let observed = CodexMCPApprovalObservation()
        let reader = Task {
            for await event in session.events { await observed.observe(event) }
        }
        do {
            try await session.configureAppMCP(connection)
            var thread = f.thread
            thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
            try await session.send(text: "Explicit synthetic tool decision", thread: thread)
            try await codexMCPEEventually { await observed.request != nil }
            let request = try #require(await observed.request)
            var changed = request
            var params = try #require(changed.params.object)
            params["message"] = .string("A different request using the same native id")
            changed.params = .object(params)
            await #expect(throws: CoincideError.self) { try await session.respond(changed, allow: true) }
            #expect(!(try f.rows()).contains { $0["kind"] == .string("approvalResponse") })
            try await session.respond(request, allow: false)
            await #expect(throws: CoincideError.self) { try await session.respond(request, allow: true) }
            try await codexMCPEEventually { try f.rows().contains { $0["kind"] == .string("approvalResponse") } }
            #expect((try f.rows()).filter { $0["kind"] == .string("approvalResponse") }.count == 1)
            await session.close(); await reader.value
        } catch { await session.close(); await reader.value; throw error }
    }
}

private actor CodexMCPApprovalObservation {
    var request: ApprovalRequest?
    func observe(_ event: ProviderEvent) {
        switch event {
        case .context(_, let child): observe(child)
        case .approval(let value): request = value
        default: break
        }
    }
}

private struct CodexMCPFixture: Sendable {
    let root: URL, workspace: URL, database: URL, executable: URL
    let project: WorkspaceProject
    let thread: CodingThread
    let renamedTitle = "Codex MCP renamed 工作"
    init(options supplied: [String: JSONValue] = [:]) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-codex-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let physical = realpath(temporary.path, nil) else { throw CoincideError("The private Codex MCP fixture path was unavailable.") }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true); free(physical)
        workspace = root.appendingPathComponent("Checkout")
        let home = root.appendingPathComponent("Home"), codexHome = root.appendingPathComponent("CodexHome")
        for path in [workspace, home, codexHome] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        executable = root.appendingPathComponent("private-codex"); database = root.appendingPathComponent("workspace.sqlite")
        let peer = try #require(Bundle.module.url(forResource: "codex_mcp", withExtension: "py", subdirectory: "Fixtures"))
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let wrapper = "#!/bin/sh\nexec /usr/bin/env -i \(quote("HOME=" + home.path)) \(quote("CODEX_HOME=" + codexHome.path)) PATH=/usr/bin:/bin /usr/bin/python3 \(quote(peer.path)) \(quote(root.appendingPathComponent("options.json").path)) \(quote(root.appendingPathComponent("wire.jsonl").path)) \"$@\"\n"
        try Data(wrapper.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        project = WorkspaceProject(path: workspace.path)
        var thread = CodingThread(project: project, model: "wire-model")
        thread.checkpointPolicy = .disabled; thread.permission = .supervised
        thread.codexRuntimeConfiguration = .init(instanceID: UUID(), selection: .custom, executable: executable.path, homeDirectory: codexHome.path)
        self.thread = thread
        var options = supplied
        options["appThreadID"] = .string(thread.id.uuidString.lowercased()); options["cwd"] = .string(thread.workspacePath)
        options["renamedTitle"] = .string(renamedTitle)
        for name in ["releaseRegistration", "releaseStatus", "releaseTurn1", "releaseTurn2", "registrationEntered", "statusEntered", "readObserved", "writeObserved", "turnReady2"] where options[name] != nil {
            options[name] = .string(root.appendingPathComponent(name).path)
        }
        let file = root.appendingPathComponent("options.json")
        try JSONEncoder().encode(options).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func session() throws -> CodexSession {
        try .init(executable: executable, cwd: workspace, runtimeConfiguration: thread.codexRuntimeConfiguration)
    }
    func rows() throws -> [JSONValue] {
        let path = root.appendingPathComponent("wire.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let bytes = try Data(contentsOf: path)
        guard bytes.count <= 1_048_576 else { throw CoincideError("The synthetic Codex MCP wire log exceeded its bound.") }
        guard let last = bytes.lastIndex(of: 10) else { return [] }
        return try bytes[...last].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func release(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name)) }
    func releaseAll() { for name in ["releaseRegistration", "releaseStatus", "releaseTurn1", "releaseTurn2"] { try? release(name) } }
    func current(_ engine: WorkspaceEngine) async throws -> CodingThread {
        try #require(await engine.current().snapshot.threads.first { $0.id == thread.id })
    }
    func assertStopped() throws {
        let rows = try rows()
        try #require(rows.last?["kind"] == .string("closed") && rows.last?["workersDrained"] == .bool(true))
        guard let first = rows.first, case .number(let rawPID) = first["pid"], rawPID > 0, rawPID <= Double(Int32.max), rawPID.rounded() == rawPID else {
            throw CoincideError("The synthetic Codex MCP process identity was unavailable.")
        }
        let pid = pid_t(rawPID)
        errno = 0
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
    func remove() throws { try FileManager.default.removeItem(at: root) }
}

private func withCodexMCPPeer(_ f: CodexMCPFixture,
                            body: (CodexSession, AppMCPConnection) async throws -> Void) async throws {
    let registry = MCPSessionRegistry()
    let scope = MCPInvocationScope(threadID: f.thread.id, projectID: f.project.id, provider: .codex, runtimeID: UUID(), incarnation: UUID(),
        providerInstanceID: try #require(f.thread.codexRuntimeConfiguration?.instanceID), workspacePath: f.workspace.path,
        permission: .supervised, capabilities: [.orchestration])
    let credential = try await registry.issue(scope: scope)
    let tool = MCPToolDefinition(name: "t3_thread_read", description: "Read the offline fixture", inputSchema: .object(["type": .string("object")]), capability: .orchestration, readOnly: true)
    let server = try await MCPHTTPServer.start(registry: registry, tools: [tool]) { _ in .init(content: ["Synthetic read"], structuredContent: .object(["observed": .bool(true)])) }
    let session = try f.session()
    do {
        try await body(session, .init(endpoint: server.endpoint, authorizationHeader: credential.authorizationHeader, scopeID: credential.sessionID))
        await session.close(); await server.close(); await registry.shutdown()
        try f.assertStopped(); try f.remove()
    } catch { f.releaseAll(); await session.close(); await server.close(); await registry.shutdown(); throw error }
}

private func codexMCPEEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The offline Codex MCP peer did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
