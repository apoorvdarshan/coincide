import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct NativeManagedRuntimeFixture: Sendable {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-managed-native-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func installer(version: String = "1.3.0", protocolVersion: Int = 2, reportedVersion: String? = nil, supportsResume: Bool = true) throws -> AntigravityInstallation {
        let python = try #require(ProcessChannel.findExecutable("python3"))
        let log = Data(root.appendingPathComponent("wire.jsonl").path.utf8).base64EncodedString()
        let peer = "#!" + python.path + "\n" + """
        import base64, json, os, sys
        log = base64.b64decode("\(log)").decode()
        version = "\(version)"
        session = "8bfa9215-af84-4bdb-aad3-f453bd044cea"
        model, mode = "native-default", "default"
        def send(value):
            print(json.dumps(value), flush=True)
        def setup():
            return {"sessionId":session,"configOptions":[
                {"id":"model","category":"model","type":"select","currentValue":model,"options":[{"value":"native-default","name":"Native Default"}]},
                {"id":"mode","category":"mode","type":"select","currentValue":mode,"options":[{"value":x,"name":x} for x in ["default","auto_edit","yolo"]]}]}
        for line in sys.stdin.buffer:
            frame = json.loads(line); method = frame.get("method"); params = frame.get("params",{})
            with open(log, "a") as file:
                file.write(json.dumps({"method":method,"pid":os.getpid(),"version":version})+"\\n")
            value = {}
            if method == "initialize":
                value = {"protocolVersion":\(protocolVersion),"agentInfo":{"name":"antigravity-acp","version":"\(reportedVersion ?? version)"},"agentCapabilities":{"loadSession":True,"sessionCapabilities":\(supportsResume ? "{\"resume\":{}}" : "{}"),"auth":{"logout":{}}},"authMethods":[{"id":"oauth-personal"}]}
            elif method in ("session/new","session/resume"): value = setup()
            elif method == "session/set_config_option":
                if params.get("configId")=="model": model = params["value"]
                if params.get("configId")=="mode": mode = params["value"]
                value = setup()
            elif method == "session/prompt":
                send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":session,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Managed native reply"}}}})
                value = {"stopReason":"end_turn"}
            if "id" in frame: send({"jsonrpc":"2.0","id":frame["id"],"result":value})
        """
        let server = Data(peer.utf8), harness = Data("#!/bin/sh\nexit 0\n".utf8), archive = Data(("synthetic archive " + version + " " + String(protocolVersion)).utf8)
        let release = try AntigravityManagedRelease(version: version, platform: "darwin", architecture: "arm64",
            url: URL(string: "https://example.invalid/native.zip")!, archiveBytes: Int64(archive.count),
            sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
            serverName: "agy_acp_server.par", serverBytes: Int64(server.count), harnessName: "localharness_external", harnessBytes: Int64(harness.count))
        return AntigravityInstallation(rootURL: root.appendingPathComponent("install"), release: release,
            downloader: { _, destination, progress in try archive.write(to: destination, options: .withoutOverwriting); progress(Int64(archive.count)) },
            extractor: { release, _, destination in
                for (name, bytes) in [(release.serverName, server), (release.harnessName, harness)] {
                    let file = destination.appendingPathComponent(name)
                    try bytes.write(to: file, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
                }
            }, diskSpace: { _ in Int64.max })
    }
    func rows() throws -> [JSONValue] {
        let url = root.appendingPathComponent("wire.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Data(contentsOf: url).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func remove() throws {
        for row in try rows() {
            guard case .number(let raw) = row["pid"], let pid = Int32(exactly: raw) else { throw CoincideError("Invalid native fixture PID.") }
            guard kill(pid, 0) == -1, errno == ESRCH else { throw CoincideError("The managed fixture still owns a process; its files were kept.") }
        }
        try FileManager.default.removeItem(at: root)
    }
}
private func awaitNativeManagedInstall(_ service: AntigravityInstallation) async throws {
    let operationID = try service.start()
    try await antigravityEventually { !service.state().phase.isWorking }
    try await service.cancel(operationID: operationID)
    #expect(service.state().phase == .succeeded)
    guard service.state().phase == .succeeded else { throw CoincideError("The synthetic managed runtime did not activate.") }
}

@Test(arguments: [1, 2]) func managedAntigravityVerificationUsesOnlyNativeInitializationAndDrains(_ protocolVersion: Int) async throws {
    let fixture = try NativeManagedRuntimeFixture(), installer = try fixture.installer(protocolVersion: protocolVersion)
    do {
        try await awaitNativeManagedInstall(installer)
        let rows = try fixture.rows(); #expect(rows.count == 1 && rows[0]["method"] == .string("initialize"))
        let pair = try installer.resolve(configuration: .init(runtimeSelection: .managed))
        #expect(pair.executable.deletingLastPathComponent() == pair.harness.deletingLastPathComponent())
        try await installer.cancel(operationID: try #require(installer.state().operationID))
        try installer.remove(); await installer.shutdown(); try fixture.remove()
    } catch { await installer.shutdown(); try? fixture.remove(); throw error }
}

@Test func managedAntigravityLeasePinsOldRuntimeAcrossUpdateAndBlocksRemovalUntilNativeClose() async throws {
    let fixture = try NativeManagedRuntimeFixture(), first = try fixture.installer(), second = try fixture.installer(version: "1.3.1")
    var runtime: AntigravityRuntime?, connection: AntigravityConnection?
    do {
        try await awaitNativeManagedInstall(first)
        let config = AntigravityConfiguration(runtimeSelection: .managed), old = try first.resolve(configuration: config)
        let running = try AntigravityRuntime(executable: old.executable, configuration: config, cwd: fixture.root,
            stateRoot: fixture.root.appendingPathComponent("state"), installation: first)
        runtime = running
        let host = try AntigravityConnection(runtime: running); connection = host
        #expect(try await host.initialize()["agentInfo"]["version"] == .string("1.3.0"))
        try await awaitNativeManagedInstall(second)
        let current = try second.resolve(configuration: config)
        #expect(current != old && running.executablePair == old)
        #expect(FileManager.default.fileExists(atPath: old.executable.path))
        #expect(throws: (any Error).self) { try second.remove() }
        _ = try await host.request("session/list")
        await host.close(); await running.close()
        try second.remove(); await first.shutdown(); await second.shutdown(); try fixture.remove()
    } catch {
        await connection?.close(); await runtime?.close(); await first.shutdown(); await second.shutdown(); try? fixture.remove(); throw error
    }
}

@Test func managedAntigravityProductionFactoryRunsAndReopensWithoutPATHOrPromptReplay() async throws {
    let fixture = try NativeManagedRuntimeFixture(), installer = try fixture.installer()
    let databaseURL = fixture.root.appendingPathComponent("workspace.sqlite")
    let configuration = AntigravityConfiguration(instanceID: UUID(), runtimeSelection: .managed, authGeneration: UUID())
    let engine = try WorkspaceEngine(url: databaseURL,
        providerFactory: { try ProviderSessions.make(for: $0, antigravityStateRoot: fixture.root.appendingPathComponent("state"), antigravityInstallation: installer) },
        identityResolver: { _ in nil })
    do {
        try await awaitNativeManagedInstall(installer)
        try AntigravityAccountRegistry.save(.init(configuration: configuration, accessState: .verified), rootURL: fixture.root.appendingPathComponent("AntigravitySettings"))
        _ = try await engine.load()
        let project = WorkspaceProject(path: fixture.root.path)
        var thread = CodingThread(project: project); thread.provider = .antigravity; thread.antigravityConfiguration = configuration; thread.checkpointPolicy = .disabled
        try await engine.dispatch(.addProject(project)); try await engine.dispatch(.createThread(thread))
        try await engine.dispatch(.submit(threadID: thread.id, text: "Generated managed-runtime input"))
        try await antigravityEventually {
            let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
            return current?.activeRun == nil && current?.messages.contains(where: { $0.text == "Managed native reply" }) == true
        }
        await engine.shutdown()
        let prompts = try fixture.rows().filter { $0["method"] == .string("session/prompt") }; #expect(prompts.count == 1)
        let reopened = try WorkspaceEngine(url: databaseURL,
            providerFactory: { try ProviderSessions.make(for: $0, antigravityStateRoot: fixture.root.appendingPathComponent("state"), antigravityInstallation: installer) }, identityResolver: { _ in nil })
        let state = try await reopened.load(); await reopened.shutdown()
        #expect(state.threads.first?.antigravityConfiguration?.runtimeSelection == .managed)
        #expect(try fixture.rows().filter { $0["method"] == .string("session/prompt") }.count == 1)
        try installer.remove(); await installer.shutdown(); try fixture.remove()
    } catch { await engine.shutdown(); await installer.shutdown(); try? fixture.remove(); throw error }
}

@Test(arguments: ["version", "resume"])
func managedAntigravityNativeVerificationFailurePreservesPreviousActivePair(_ mismatch: String) async throws {
    let fixture = try NativeManagedRuntimeFixture(), first = try fixture.installer()
    let next = try fixture.installer(version: "1.3.1", reportedVersion: mismatch == "version" ? "unexpected-version" : nil,
                                     supportsResume: mismatch != "resume")
    do {
        try await awaitNativeManagedInstall(first)
        let old = try first.resolve(configuration: .init(runtimeSelection: .managed))
        let operationID = try next.start()
        try await antigravityEventually { !next.state().phase.isWorking }
        try await next.cancel(operationID: operationID)
        #expect(next.state().phase == .failed)
        #expect(try next.resolve(configuration: .init(runtimeSelection: .managed)) == old)
        let rows = try fixture.rows()
        #expect(rows.count == 2 && rows.allSatisfy { $0["method"] == .string("initialize") })
        try next.remove(); await next.shutdown(); await first.shutdown(); try fixture.remove()
    } catch { await next.shutdown(); await first.shutdown(); try? fixture.remove(); throw error }
}

@Test func antigravityRuntimeSelectionLegacyDecodeAndManagedModelCopiesStayExplicit() throws {
    let external = AntigravityConfiguration(executable: "/literal/native/server", harnessPath: "/literal/native/harness")
    var fields = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(external)) as? [String: Any])
    fields.removeValue(forKey: "runtimeSelection")
    let legacy = try JSONDecoder().decode(AntigravityConfiguration.self, from: JSONSerialization.data(withJSONObject: fields))
    #expect(legacy == external && legacy.runtimeSelection == .external)
    let managed = AntigravityConfiguration(runtimeSelection: .managed), selected = managed.selecting(model: "native-model")
    #expect(selected.runtimeSelection == .managed && selected.runtimeIdentity == managed.runtimeIdentity)
    #expect(selected.runtimeIdentity != external.runtimeIdentity)
    #expect(throws: (any Error).self) { try AntigravityConfiguration(runtimeSelection: .managed, executable: "/custom/server").validate() }
    #expect(throws: (any Error).self) { try AntigravityConfiguration(runtimeSelection: .managed, harnessPath: "/custom/harness").validate() }
}
