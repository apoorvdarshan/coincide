import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Production factory, owned parent, native HTTP/SSE, real app MCP and durable
/// reducer. Only OpenCode's child is a synthetic peer; no model is invoked.
@Test(.timeLimit(.minutes(1)), arguments: [OpenCodeGeneration.v1, .v2], [false, true])
func openCodeAppMCPProductionEnginePreservesFIFOStopRedactionAndDurableWrites(generation: OpenCodeGeneration, aliasWorkspace: Bool) async throws {
    let f = try OpenCodeAppMCPFixture(generation: generation, aliasWorkspace: aliasWorkspace)
    let engine = try WorkspaceEngine(url: f.database, appMCPEnabled: true, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        try await engine.dispatch(.addProjectWithThread(project: f.project, thread: f.thread))
        try await engine.dispatch(.submit(threadID: f.thread.id, text: f.firstInput))
        try await openCodeAppMCPEventually {
            let thread = await engine.current().snapshot.threads.first { $0.id == f.thread.id }
            return thread?.title == f.renamedTitle && thread?.messages.contains { $0.text == f.redactedAnswer } == true
        }
        let first = try #require(await engine.current().snapshot.threads.first { $0.id == f.thread.id })
        let firstRun = try #require(first.activeRun?.id)
        #expect(first.state == .running)
        try await engine.dispatch(.submit(threadID: f.thread.id, text: f.secondInput))
        try await engine.dispatch(.editThread(f.thread.id, .draft("Unsent draft preserved 工作")))
        #expect(try f.rows("prompt").count == 1)
        try f.release("release-first")
        try await openCodeAppMCPEventually {
            let thread = await engine.current().snapshot.threads.first { $0.id == f.thread.id }
            return (try? f.rows("mcp-invocation").count) == 2 && thread?.activeRun?.id != nil && thread?.activeRun?.id != firstRun &&
                thread?.messages.filter { $0.text == f.redactedAnswer }.count == 2
        }
        try await engine.dispatch(.interrupt(threadID: f.thread.id))
        try await openCodeAppMCPEventually {
            let thread = await engine.current().snapshot.threads.first { $0.id == f.thread.id }
            return thread?.activeRun == nil && thread?.state == .interrupted
        }
        let final = try #require(await engine.current().snapshot.threads.first { $0.id == f.thread.id })
        #expect(final.title == f.renamedTitle && final.draft == "Unsent draft preserved 工作")
        #expect(final.runHistory?.map(\.status) == [.completed, .interrupted])
        let rows = try f.rows(), registration = try #require(rows.firstIndex { $0["kind"] == .string("mcp-registration") })
        let prompt = try #require(rows.firstIndex { $0["kind"] == .string("prompt") })
        #expect(registration < prompt)
        #expect(try f.rows("mcp-registration").count == 1)
        #expect(try f.rows("mcp-status").count >= 3)
        #expect(try f.rows("mcp-registration").allSatisfy { $0["exactShape"] == .bool(true) && $0["foreignPreserved"] == .bool(true) })
        #expect(try f.rows("mcp-invocation").allSatisfy { $0["readSucceeded"] == .bool(true) && $0["renameSucceeded"] == .bool(true) })
        async let closeOne: Void = engine.shutdown()
        async let closeTwo: Void = engine.shutdown()
        _ = await (closeOne, closeTwo)
        try await openCodeAppMCPEventually { f.stopped }
        #expect(try f.rows("mcp-remove").count == 1)
        #expect(try f.rows("mcp-remove").allSatisfy { $0["foreignPreserved"] == .bool(true) })
        #expect(try f.rows("fixture-handler-failed").isEmpty)
        let database = try WorkspaceDatabase(url: f.database)
        let journal = try await database.journal(limit: 500)
        let encoded = String(decoding: try JSONEncoder().encode(journal), as: UTF8.self)
        #expect(!encoded.contains("Bearer ") && !encoded.contains("authorizationHeader") && !encoded.contains("http_headers"))
        let rebuilt = try await database.rebuildProjection().snapshot
        let persisted = try #require(rebuilt.threads.first { $0.id == f.thread.id })
        #expect(persisted.title == final.title && persisted.draft == final.draft && persisted.messages == final.messages && persisted.runHistory == final.runHistory)
        try f.remove()
    } catch { await engine.shutdown(); try? f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [OpenCodeGeneration.v1, .v2], ["collision", "prefix-collision", "rejected", "failed"])
func openCodeAppMCPRefusesUnverifiedRegistrationWithoutPromptFallback(generation: OpenCodeGeneration, mode: String) async throws {
    let f = try OpenCodeAppMCPFixture(generation: generation, mode: mode)
    let session = f.session()
    let connection = try AppMCPConnection(endpoint: URL(string: "http://127.0.0.1:34567/mcp")!,
        authorizationHeader: "Bearer " + String(repeating: "A", count: 43), scopeID: UUID())
    do {
        try await session.configureAppMCP(connection)
        do {
            try await session.send(text: f.firstInput, thread: f.thread)
            Issue.record("Unverified native app tools admitted an input.")
        } catch {
            #expect(error.localizedDescription == "The native OpenCode app tool connection could not be verified. No input was sent.")
            #expect(!error.localizedDescription.contains(connection.authorizationHeader))
        }
        // A failed registration cannot be converted to an ordinary prompt by retrying.
        await #expect(throws: (any Error).self) { try await session.send(text: f.firstInput, thread: f.thread) }
        await session.close()
        #expect(try f.rows("prompt").isEmpty)
        #expect(try f.rows("mcp-registration").count == (mode.contains("collision") ? 0 : 1))
        #expect(try f.rows("mcp-remove").count == (mode.contains("collision") ? 0 : 1))
        #expect(f.stopped)
        try f.remove()
    } catch { await session.close(); try? f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [OpenCodeGeneration.v1, .v2])
func openCodeAppMCPMetadataDoesNotRegisterTools(generation: OpenCodeGeneration) async throws {
    let f = try OpenCodeAppMCPFixture(generation: generation)
    let session = f.session()
    do {
        #expect(try await session.models().count == 1)
        await session.close()
        #expect(try f.rows("mcp-registration").isEmpty && f.rows("mcp-status").isEmpty && f.rows("prompt").isEmpty)
        try f.remove()
    } catch { await session.close(); try? f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [OpenCodeGeneration.v1, .v2])
func openCodeAppMCPHeldRegistrationCannotRaceStopOrCloseIntoPrompt(generation: OpenCodeGeneration) async throws {
    let f = try OpenCodeAppMCPFixture(generation: generation, mode: "held")
    let session = f.session()
    let connection = try AppMCPConnection(endpoint: URL(string: "http://127.0.0.1:34567/mcp")!,
        authorizationHeader: "Bearer " + String(repeating: "A", count: 43), scopeID: UUID())
    try await session.configureAppMCP(connection)
    let sending = Task { try await session.send(text: f.firstInput, thread: f.thread) }
    do {
        try await openCodeAppMCPEventually { f.exists("registration-entered") }
        try await session.interrupt()
        async let closeOne: Void = session.close()
        async let closeTwo: Void = session.close()
        _ = await (closeOne, closeTwo)
        await #expect(throws: (any Error).self) { try await sending.value }
        #expect(try f.rows("prompt").isEmpty && f.stopped)
        try f.remove()
    } catch { sending.cancel(); try? f.release("release-registration"); await session.close(); _ = await sending.result; try? f.remove(); throw error }
}

private struct OpenCodeAppMCPFixture: Sendable {
    let root: URL, workspace: URL, database: URL, executable: URL
    let generation: OpenCodeGeneration
    let project: WorkspaceProject
    let thread: CodingThread
    let renamedTitle = "OpenCode app tool rename 工作"
    let redactedAnswer = "APP_MCP_READY [private app tool credential] [private app tool credential]"
    var firstInput: String { generation == .v1 ? "wire-v1-first 工作 🌍" : "wire-first 工作 🌍" }
    var secondInput: String { generation == .v1 ? "wire-v1-second FIFO" : "wire-second FIFO" }

    init(generation: OpenCodeGeneration, mode: String = "normal", aliasWorkspace: Bool = false) throws {
        self.generation = generation
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-opencode-app-mcp-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let physicalWorkspace = root.appendingPathComponent("checkout's 工作 & space", isDirectory: true)
        workspace = aliasWorkspace ? root.appendingPathComponent("workspace alias", isDirectory: true) : physicalWorkspace
        do {
            try FileManager.default.createDirectory(at: physicalWorkspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if aliasWorkspace { try FileManager.default.createSymbolicLink(at: workspace, withDestinationURL: physicalWorkspace) }
        } catch { try? FileManager.default.removeItem(at: root); throw error }
        database = root.appendingPathComponent("workspace.sqlite")
        executable = root.appendingPathComponent("native-http-peer")
        project = WorkspaceProject(path: workspace.path)
        var value = CodingThread(project: project)
        value.provider = .opencode
        let model = OpenCodeModelSelection(providerID: "synthetic", id: generation == .v1 ? "wire-model/with-slash" : "wire-model", variant: "balanced")
        value.model = model.catalogID; value.checkpointPolicy = .disabled
        value.openCodeConfiguration = .init(generation: generation, executable: executable.path, model: model, agentID: "build")
        thread = value
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            for (name, data) in [
                ("fixture-directory.json", JSONValue.object(["directory": .string(workspace.standardizedFileURL.resolvingSymlinksInPath().path)])),
                ("fixture-app-mcp.json", .object(["mode": .string(mode), "appThreadID": .string(value.id.uuidString), "renamedTitle": .string(renamedTitle)]))
            ] {
                let path = root.appendingPathComponent(name)
                try JSONEncoder().encode(data).write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
            for name in ["opencode_\(generation.rawValue)_http_engine", "opencode_app_mcp"] {
                let source = try #require(Bundle.module.url(forResource: name, withExtension: "py", subdirectory: "Fixtures"))
                let target = name == "opencode_app_mcp" ? root.appendingPathComponent(name + ".py") : executable
                try FileManager.default.copyItem(at: source, to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            }
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func session() -> any ProviderSession {
        if generation == .v1 { return OpenCodeV1Session(executable: executable, cwd: workspace, configuration: thread.openCodeConfiguration!) }
        return OpenCodeV2Session(executable: executable, cwd: workspace, configuration: thread.openCodeConfiguration!)
    }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func rows(_ kind: String? = nil) throws -> [JSONValue] {
        guard exists("wire.jsonl") else { return [] }
        let data = try Data(contentsOf: root.appendingPathComponent("wire.jsonl"))
        guard let newline = data.lastIndex(of: 10) else { return [] }
        return try data[...newline].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
            .filter { kind == nil || $0["kind"] == .string(kind!) }
    }
    func release(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name), options: .atomic) }
    var stopped: Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("process.json")),
              let info = try? JSONDecoder().decode(JSONValue.self, from: data), case .number(let pid) = info["pid"],
              pid > 0, pid < Double(Int32.max) else { return false }
        return Darwin.kill(Int32(pid), 0) == -1 && errno == ESRCH
    }
    func remove() throws {
        guard !exists("process.json") || stopped else { throw CoincideError("The private OpenCode app-tool fixture is still alive; files were preserved.") }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

private func openCodeAppMCPEventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(12)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private native OpenCode app-tool acceptance boundary was not reached.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
