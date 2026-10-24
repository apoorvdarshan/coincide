import Darwin
import Foundation
import Testing
@testable import CoincideCore

private let nativePiMCPEnabled = ProcessInfo.processInfo.environment["COINCIDE_NATIVE_PI_PACKAGE_ROOT"] != nil &&
    ProcessInfo.processInfo.environment["COINCIDE_NATIVE_PI_NODE"] != nil

/// Actual pinned Pi hooks, model tool loop, private header-auth MCP and Engine.
/// The only model is a synthetic in-process stream; OS policy permits loopback
/// networking and denies external networking. No installed account is read.
@Test(.enabled(if: nativePiMCPEnabled), .timeLimit(.minutes(1)))
func piNativeMCPToolsReadWithoutApprovalRenameOnlyAfterSupervisedApprovalAndRemainOwnedAcrossNextTurn() async throws {
    let f = try NativePiMCPFixture()
    let engine = try WorkspaceEngine(url: f.database, appMCPEnabled: true, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
    do {
        try await saveLegacyProviderFixture(project: f.project, threads: [f.thread], at: f.database)
        _ = try await engine.load()
        let firstID = UUID()
        let firstInput = "First synthetic app-tool workflow"
        try await engine.dispatch(.submit(threadID: f.thread.id, text: firstInput), id: firstID)
        try await nativeMCPEvenually("mutating tool approval after native read result") {
            let thread = try await f.current(engine)
            let frames = try f.frames()
            return thread.runtimeRequests.count == 1 && frames.contains {
                $0["kind"] == .string("read-result") && $0["users"] == .number(1) && $0["exactThread"] == .bool(true)
            }
        }
        let waiting = try await f.current(engine)
        let approval = try #require(waiting.runtimeRequests.first?.request)
        let typed = try PiExtensionRequest.presentation(approval)
        #expect(typed.method == .confirm && typed.title.contains("mcp__coincide__t3_thread_update"))
        #expect(waiting.activeRun?.id == firstID && waiting.activeRun?.nativeTurnID == nil)
        #expect(waiting.title == firstInput && waiting.title != f.renamedTitle)
        #expect(!(try f.frames()).contains { $0["kind"] == .string("write-result") })
        let firstRuntime = try #require(waiting.runtimeID)
        let decision = try await engine.dispatch(.respond(threadID: f.thread.id, requestID: approval.id, response: .decision(true)))
        #expect(decision.rejection == nil)
        let first = try await f.completed(engine, id: firstID)
        #expect(first.title == f.renamedTitle && first.runtimeRequests.isEmpty)
        let firstRecord = try #require(first.runHistory?.first { $0.id == firstID })
        let firstProof = try #require(firstRecord.pi)
        #expect(firstProof.captureStatus == .proven && firstProof.inputs.count == 1 && firstRecord.turnIDs.isEmpty)
        #expect(firstProof.inputs.first?.bridgeEvidence != nil)
        let firstTools = first.messages.filter { $0.providerEntity?.key.type == "tool_call" }
        #expect(firstTools.count == 2 && firstTools.allSatisfy { $0.runReference == .init(threadID: f.thread.id, runID: firstID) })
        #expect(firstTools.allSatisfy { $0.providerEntity?.fields["status"] == .string("completed") })
        #expect(Set(firstTools.compactMap { $0.providerEntity?.fields["title"].string }) == ["mcp__coincide__t3_thread_read", "mcp__coincide__t3_thread_update"])
        #expect(first.messages.contains { $0.role == .assistant && $0.text == "MCP_NATIVE_FIRST_DONE" })

        let secondID = UUID()
        try await engine.dispatch(.submit(threadID: f.thread.id, text: "Second explicit read of renamed thread"), id: secondID)
        let complete = try await f.completed(engine, id: secondID)
        #expect(complete.runtimeID == firstRuntime && complete.providerThreadID == first.providerThreadID)
        #expect(complete.title == f.renamedTitle && complete.runtimeRequests.isEmpty && complete.queuedTurns.isEmpty)
        #expect(complete.runHistory?.allSatisfy { $0.status == .completed && $0.pi?.captureStatus == .proven && $0.turnIDs.isEmpty } == true)
        let tools = complete.messages.filter { $0.providerEntity?.key.type == "tool_call" }
        #expect(tools.count == 3 && tools.last?.runReference == .init(threadID: f.thread.id, runID: secondID))
        #expect(tools.allSatisfy { $0.providerEntity?.fields["status"] == .string("completed") })
        #expect(complete.messages.contains { $0.role == .assistant && $0.text == "MCP_NATIVE_SECOND_DONE" })
        let frames = try f.frames()
        #expect(frames.filter { $0["kind"] == .string("model") }.count == 5)
        #expect(frames.filter { $0["kind"] == .string("tool-call") }.count == 3)
        #expect(frames.filter { $0["kind"] == .string("tool-result") }.allSatisfy { $0["isError"] == .bool(false) })
        #expect(frames.contains { $0["kind"] == .string("read-result") && $0["users"] == .number(2) && $0["renamed"] == .bool(true) })
        #expect(!frames.contains { $0["kind"] == .string("model-failed") })
        let pids = Set(frames.filter { $0["kind"] == .string("model") }.compactMap { row -> Double? in
            if case .number(let pid) = row["pid"] { return pid }; return nil
        })
        #expect(pids.count == 1)
        #expect(frames.filter { $0["kind"] == .string("session-start") }.allSatisfy { $0["credentialEnvironmentAbsent"] == .bool(true) })
        let database = try WorkspaceDatabase(url: f.database)
        let stored = try await database.load(), rebuilt = try await database.rebuildProjection().snapshot
        #expect(stored.threads.first { $0.id == f.thread.id }?.runHistory == complete.runHistory)
        #expect(rebuilt.threads.first { $0.id == f.thread.id }?.title == f.renamedTitle)
        let journal = try await database.journal(limit: 500)
        #expect(journal.count < 500)
        let journalText = String(decoding: try JSONEncoder().encode(journal), as: UTF8.self)
        #expect(!journalText.contains("authorizationHeader") && !journalText.contains("Bearer "))
        try WorkspaceJournal.validate(stored)
        await engine.shutdown(); try f.assertStopped()
        let count = try f.frames().count
        let reopened = try WorkspaceEngine(url: f.database, appMCPEnabled: true, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
        do {
            let reloaded = try await reopened.load()
            let durable = try #require(reloaded.threads.first { $0.id == f.thread.id })
            #expect(durable.title == complete.title && durable.runHistory == complete.runHistory)
            #expect(durable.activeRun == nil && durable.runtimeRequests.isEmpty)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
        #expect(try f.frames().count == count)
        try f.assertStopped()
        try FileManager.default.removeItem(at: f.root)
    } catch {
        await engine.shutdown()
        Issue.record("Private synthetic native Pi MCP evidence retained at \(f.root.path)")
        throw error
    }
}

private struct NativePiMCPFixture {
    let root: URL, database: URL, launches: URL
    let project: WorkspaceProject
    let thread: CodingThread
    let renamedTitle = "Renamed by supervised native MCP tool"
    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let packagePath = try #require(environment["COINCIDE_NATIVE_PI_PACKAGE_ROOT"])
        let nodePath = try #require(environment["COINCIDE_NATIVE_PI_NODE"])
        let package = URL(fileURLWithPath: packagePath), node = URL(fileURLWithPath: nodePath)
        let manifestData = try Data(contentsOf: package.appendingPathComponent("package.json"))
        guard manifestData.count <= 65_536 else { throw PiHistoryGraphError(.oversized) }
        let manifest = try JSONDecoder().decode(JSONValue.self, from: manifestData)
        guard manifest["name"] == .string("@earendil-works/pi-coding-agent"), manifest["version"] == .string("0.80.5"),
              FileManager.default.isExecutableFile(atPath: node.path), FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
              FileManager.default.fileExists(atPath: package.appendingPathComponent("dist/cli.js").path) else {
            throw CoincideError("The opt-in MCP test requires the exact private Pi0.80.5 package, Node and macOS network policy.")
        }
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-pi-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        root = URL(fileURLWithPath: try PiRuntimeConfiguration.physical(requested.path))
        let cwd = root.appendingPathComponent("Checkout"), home = root.appendingPathComponent("Home")
        let agent = root.appendingPathComponent("Agent"), sessions = root.appendingPathComponent("Sessions"), temporary = root.appendingPathComponent("Tmp")
        database = root.appendingPathComponent("workspace.sqlite"); launches = root.appendingPathComponent("launches.jsonl")
        for directory in [cwd, home, agent, sessions, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let resource = try #require(Bundle.module.url(forResource: "pi_local_mcp_model", withExtension: "ts", subdirectory: "Fixtures"))
        let localModel = root.appendingPathComponent("local-model.ts")
        try FileManager.default.copyItem(at: resource, to: localModel)
        try JSONEncoder().encode(JSONValue.object(["compaction": .object(["enabled": .bool(false)]), "retry": .object(["enabled": .bool(false)])]))
            .write(to: agent.appendingPathComponent("settings.json"))
        FileManager.default.createFile(atPath: launches.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let executable = root.appendingPathComponent("private-pi")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let sandbox = "(version 1) (allow default) (deny network*) (allow network-outbound (remote ip \"localhost:*\"))"
        let launcher = """
        #!/bin/sh
        set -eu
        printf '{"kind":"launch","pid":%s}\\n' "$$" >> \(quote(launches.path))
        exec /usr/bin/env -i \(quote("HOME=" + home.path)) \(quote("TMPDIR=" + temporary.path)) \(quote("PI_CODING_AGENT_DIR=" + agent.path)) \(quote("PI_CODING_AGENT_SESSION_DIR=" + sessions.path)) \(quote("COINCIDE_PI_LOCAL_MCP_ROOT=" + root.path)) PATH=/usr/bin:/bin LANG=en_US.UTF-8 PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 NO_COLOR=1 /usr/bin/sandbox-exec -p \(quote(sandbox)) \(quote(node.path)) \(quote(package.appendingPathComponent("dist/cli.js").path)) "$@" --offline --no-builtin-tools --tools mcp__coincide__t3_thread_read,mcp__coincide__t3_thread_update --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files --extension \(quote(localModel.path)) --provider coincide-mcp-local --model local-tools --thinking off --session-dir \(quote(sessions.path))
        """
        try Data(launcher.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        project = WorkspaceProject(path: cwd.path)
        let id = UUID()
        let runtime = try PiRuntimeConfiguration.capture(workspacePath: project.path, executable: executable.path, instanceID: id,
            environment: ["HOME": home.path, "PI_CODING_AGENT_DIR": agent.path, "PI_CODING_AGENT_SESSION_DIR": sessions.path, "PATH": "/usr/bin:/bin"])
        let model = PiModelSelection(provider: "coincide-mcp-local", modelID: "local-tools")
        var thread = CodingThread(project: project)
        thread.provider = .pi; thread.permission = .supervised; thread.checkpointPolicy = .disabled
        thread.title = "Before native MCP rename"
        thread.piConfiguration = .init(instanceID: id, executable: executable.path, model: model, thinkingLevel: "off", runtime: runtime)
        thread.model = model.catalogID; self.thread = thread
        try JSONEncoder().encode(JSONValue.object(["threadID": .string(thread.id.uuidString.lowercased()), "title": .string(renamedTitle)]))
            .write(to: root.appendingPathComponent("model-config.json"))
    }
    func current(_ engine: WorkspaceEngine) async throws -> CodingThread {
        let snapshot = await engine.current().snapshot
        return try #require(snapshot.threads.first { $0.id == thread.id })
    }
    func completed(_ engine: WorkspaceEngine, id: UUID) async throws -> CodingThread {
        try await nativeMCPEvenually("proven native MCP terminal") {
            let value = try await current(engine)
            return value.activeRun == nil && value.runHistory?.contains { $0.id == id && $0.status == .completed && $0.pi?.captureStatus == .proven } == true
        }
        return try await current(engine)
    }
    func frames() throws -> [JSONValue] { try records(root.appendingPathComponent("model.jsonl")) }
    func assertStopped() throws {
        for record in try records(launches) {
            guard case .number(let value) = record["pid"], let pid = Int32(exactly: value), pid > 0 else { throw PiHistoryGraphError(.invalidEntry) }
            guard kill(pid, 0) == -1 && errno == ESRCH else { throw CoincideError("The exact native MCP acceptance process has not drained.") }
        }
    }
    private func records(_ path: URL) throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        guard data.count <= 1_048_576 else { throw PiHistoryGraphError(.oversized) }
        guard let last = data.lastIndex(of: 10) else { return [] }
        return try data[...last].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
}

private func nativeMCPEvenually(_ boundary: String, _ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(12)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private native Pi MCP test did not reach its " + boundary + " boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
